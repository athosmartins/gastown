#!/usr/bin/env bash
# agent-stuck-escalation.sh — Camada 2 da hierarquia de escalação autônoma (ga-qw3p.2).
#
# CONTEXTO (épico ga-qw3p):
#   Camada 1 (ga-qw3p.1): roteamento por tópico → crew certo
#   Camada 2 (ESTA):       sem progresso em 30min → Mayor
#   Camada 3 (ga-qw3p.3): Mayor travado → quórum 2-de-3
#   Camada 4 (ga-qw3p.4): quórum falhou → notify 🚨 humano
#
# SINAL DE "TRAVADO" (Athos aprovou o gate original via ga-qw3p.2; ga-hehi
# corrigiu o item 2 — sessão viva nunca provou progresso, ver abaixo):
#   1. updated_at do bead in_progress > STUCK_AGENT_SEC (padrão 1800s/30min)
#   2. E transcript da sessão do assignee CONGELADO (sem escrita há
#      TRANSCRIPT_FRESH_SEC, padrão = STUCK_AGENT_SEC) OU sessão ausente/morta.
#      Transcript AVANÇANDO (escrita recente) SUPRIME a escalação — trabalho
#      longo legítimo (tool calls, streaming) não gera falso-positivo.
#      Ver transcript_is_advancing() abaixo.
#   3. EXCETO se a bead está EM GATE (ga-n937, follow-up do ga-hehi): uma
#      bead em gate:queued/reviewing/passed/merging (ou com um type:quality-
#      gate-marker ABERTO referenciando-a via source-bead:<id>) não tem
#      sessão de builder por design — o builder já terminou e saiu, então o
#      sinal 2 acima cai sempre no ramo "sessão ausente" e escalaria toda
#      vez que a fila do gate passar de STUCK_AGENT_SEC (rotineiro — o
#      próprio gate só considera stall a partir de ~165min). Suprime SEMPRE,
#      exceto gate:needs-fix (ali um fixer DEVE estar trabalhando; travado é
#      stall de verdade). Ver gate_label_present()/bead_has_open_gate_marker().
#   4. EXCETO se o transcript CONGELADO é porque o último turno do assignee
#      terminou AGUARDANDO HUMANO, não travado (wa-y0620): transcript parado
#      é o MESMO sinal que um agente saudável produz depois de perguntar algo
#      e ceder o turno por design — Mayor confirmou 2 falsos-positivos reais
#      assim no mesmo dia (2026-07-20: oracle-wa parado em "Sigo parado
#      aguardando o mockup.", texto puro sem tool call; batista-wa parado
#      numa pergunta aberta). Ação destrutiva (kill/shutdown-dance) nesse
#      caso é dano puro numa sessão sã. Generaliza para o caso de texto puro
#      o sinal que inflight-reclaim-guard.py's session_awaiting_human_input()
#      (ga-nlaa) já usa só para AskUserQuestion. Ver
#      session_awaiting_human_input() abaixo.
#   5. EXCETO se o assignee é uma identidade HUMANA, não um agente (ga-tiwmm):
#      "sessão ausente" é o estado PERMANENTE e ESPERADO pra um humano
#      trabalhando manualmente (e.g. athosmartins@gmail.com) — não é sinal de
#      agente travado. Sem essa exceção, o assignee humano nunca seta
#      live_session_name, então os itens 2-4 acima (todos guardados em `-n
#      "$live_session_name"`) nunca rodam e a execução cai direto na
#      escalação. Concreto: 2026-07-25, três beads de anúncios (wa-6dd0l,
#      wa-utjmz, wa-yevxq) escalaram ao Mayor no limiar de 30min enquanto
#      Athos codava manualmente o dashboard. Ver is_human_assignee() abaixo.
#   6. QUANDO NENHUM dos itens 1-5 suprimiu (a escalação vai disparar do
#      mesmo jeito) MAS o pane confirma um diálogo de permissão aberto
#      (ga-iog1v, AC1+AC2 de ga-q640n): NÃO é uma condição de supressão nova
#      — é a MESMA escalação, só que a mensagem muda de "sem progresso"
#      genérico para BLOQUEADO-EM-PROMPT + comando exato + pane. Motivo:
#      "sem progresso" e "esperando 1 tecla de humano" têm remédios opostos
#      (kill/reclaim vs. responder o prompt), e um pool worker rodou 7h
#      travado num `rm -rf` porque uma regra "ask" sobrepôs o bypass de
#      permissões e as 3 escalações que dispararam nesse intervalo diziam
#      só "sem progresso" — ninguém soube que bastava 1 tecla. Ver
#      pane_shows_permission_prompt() abaixo.
#
# ANTI-SPAM: uma escalação por bead por janela COOLDOWN_SEC (padrão 3h).
#   Per-bead state: .gc/state/agent-stuck-escalation/<bead-id>
#   Quando bead sai do in_progress (fecha ou avança) → GC limpa o estado dele.
#
# Launchd: com.gascity.agent-stuck-escalation (StartInterval 300)
# Log: .gc/logs/agent-stuck-escalation.log
# Kill-switch: .gc/state/agent-stuck-escalation.disabled
# DRY_RUN=1: log/notify apenas, sem mail ao Mayor (selftest/supervised)

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
BD="${BD:-bd}"
NOTIFY="${NOTIFY_BIN:-notify}"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/agent-stuck-escalation.log"
STATE_DIR="$CITY/.gc/state"
ESCDIR="$STATE_DIR/agent-stuck-escalation"

STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-1800}"   # 30min sem update → travado
COOLDOWN_SEC="${COOLDOWN_SEC:-10800}"        # 3h antes de re-escalar o mesmo bead
TRANSCRIPT_FRESH_SEC="${TRANSCRIPT_FRESH_SEC:-$STUCK_AGENT_SEC}"  # ga-hehi: transcript escrito há menos disso = avançando
MAYOR_ADDR="${MAYOR_ADDR:-mayor}"
DRY_RUN="${DRY_RUN:-0}"
# Bead stores to scan (space-separated paths; HQ must be .gascity-gastown-hq, NOT the gt root)
ESCALATION_STORES="${ESCALATION_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"

# ── Escalation router (Layer 1, ga-qw3p.1) ───────────────────────────────────
# Source in library mode to get classify/route functions. Fail-open: if the
# router is absent, all escalations fall back to Mayor (zero regression).
_ROUTER="${CITY}/packs/town-deltas/assets/escalation-router.sh"
_ROUTER_AVAILABLE=0
if [ -f "$_ROUTER" ] && [ -r "$_ROUTER" ]; then
    # shellcheck source=/dev/null
    ESCALATION_CITY="$CITY" . "$_ROUTER" --lib 2>/dev/null && _ROUTER_AVAILABLE=1
fi

# Types to skip — utility/infrastructure beads, not work items
SKIP_TYPES="warrant sling wisp"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$ESCDIR"

if [ "$DRY_RUN" != "1" ]; then
    exec >> "$LOG" 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [agent-stuck] $*"; }

# transcript_is_advancing (ga-hehi; tri-state hardened by ga-4tmc): a live
# session is NOT proof of progress — `gc session list` shows "active"
# whether the agent is busy or genuinely wedged (same finding that shaped
# crew-hang-detector.sh). The real progress signal is the session's
# transcript .jsonl file: it grows on every tool call / message boundary
# while real work happens, and stays byte-still when the agent is truly hung.
#
# TRI-STATE return — not a style choice, a fix. `gc session logs <sess>
# --tail 1 --json` FAILS for crew/dog sessions ("no session file found")
# while still printing a well-formed JSON error envelope ({"ok":false,...}).
# The original boolean version of this function read
# `d.get("transcript_path") or ""` the same way for THAT envelope as for a
# genuine "no transcript" answer — collapsing "the query failed" and "the
# query succeeded with an empty result" into one value (ga-p5q3 root class).
# That turned a command FAILURE into a CONFIRMED-FROZEN verdict and
# escalated kill recommendations against agents nobody actually checked
# (ga-4tmc: thies-wa-gam257 + 3 dog beads, all alive and working).
#
#   0 = ADVANCING — envelope ok:true, transcript_path resolved, file fresh
#   1 = FROZEN    — envelope ok:true, but no path / missing file / stale
#                    mtime: the query SUCCEEDED and found no live progress
#   2 = UNKNOWN   — envelope ok:false, unparseable, or no response at all:
#                    the query itself failed, so nothing was proven either
#                    way. Callers MUST treat this the same as ADVANCING for
#                    escalation purposes (never escalate on an unproven
#                    state) while logging it as distinct from a confirmed
#                    freeze — UNKNOWN must skip, never silently act as if it
#                    were empty.
transcript_is_advancing() {
    local sess="$1" logs_json ok tpath mtime age
    logs_json="$(timeout 15 "$GC" session logs "$sess" --tail 1 --json 2>/dev/null || true)"
    [ -z "$logs_json" ] && return 2
    ok="$(printf '%s' "$logs_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("true" if d.get("ok") else "false")
except Exception:
    print("false")
' 2>/dev/null)"
    [ "$ok" = "true" ] || return 2
    tpath="$(printf '%s' "$logs_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get("transcript_path") or "")
except Exception:
    print("")
' 2>/dev/null)"
    [ -z "$tpath" ] && return 1
    [ -f "$tpath" ] || return 1
    mtime="$(stat -f %m "$tpath" 2>/dev/null || stat -c %Y "$tpath" 2>/dev/null || echo "")"
    [ -z "$mtime" ] && return 1
    age=$(( now - mtime ))
    [ "$age" -lt "$TRANSCRIPT_FRESH_SEC" ] && return 0
    return 1
}

# session_awaiting_human_input (wa-y0620): distinguishes case (a) WEDGED
# real (transcript frozen, agent mid-tool-call or genuinely dead) from case
# (b) AGUARDANDO-HUMANO (transcript frozen because the agent correctly
# ceded its turn and is waiting for the next human/orchestrator message).
# Both produce an IDENTICAL frozen-transcript signal — Mayor confirmed 2
# real false positives the same day were exactly this (2026-07-20:
# oracle-wa's last line was literally "Sigo parado aguardando o mockup." —
# plain text, no tool call; batista-wa's was an open question). Destructive
# action (kill/shutdown-dance) is only correct for (a); killing a healthy
# session mid-wait is pure damage.
#
# Generalizes the sibling primitive of the same name in
# inflight-reclaim-guard.py (ga-nlaa), which detects ONLY the sub-case where
# the agent explicitly invoked the blocking AskUserQuestion tool (via `gc
# session peek` + substring match on rendered pane output). That alone does
# not cover this bug's own primary example — a plain-text status update with
# no tool call at all. (A naive ends-in-"?" check, the bug's own suggested
# fallback, would ALSO miss it: "Sigo parado..." is a declarative sentence,
# not a question.) The structurally correct signal for "turn ended cleanly,
# nothing owed" is the Claude message `stop_reason`, already available from
# the SAME `gc session logs --json` call transcript_is_advancing() above
# makes — no second shell-out needed:
#
#   end_turn, no trailing tool_use  → turn ended on final text BY DESIGN;
#                                      nothing pending, waits for next input.
#   tool_use, trailing block IS the
#   AskUserQuestion tool             → same ga-nlaa signal, read structurally
#                                      instead of via rendered-text substring
#                                      match (more precise: can't false-match
#                                      on the string "AskUserQuestion"
#                                      appearing in unrelated prose, can't
#                                      false-miss on terminal rendering).
#   tool_use, any OTHER tool         → mid-flight, environment owes it a
#                                      tool_result that never arrived — this
#                                      IS the real hang transcript_is_
#                                      advancing already flags; unchanged.
#
# FAIL-OPEN toward escalating (return 1/not-awaiting), same direction as
# bead_has_open_gate_marker: this check only carves out a suppression
# exception, so any read/parse failure must fall through to the existing
# frozen-transcript escalation rather than silently grow into a new blanket
# suppression whenever `gc session logs` flakes.
#
#   0 = AWAITING-HUMAN — confirmed via one of the two signals above.
#   1 = NOT CONFIRMED  — mid-tool-call (other tool), last entry is a
#       user/tool_result, unparseable, or the query failed outright.
session_awaiting_human_input() {
    local sess="$1" logs_json verdict
    logs_json="$(timeout 15 "$GC" session logs "$sess" --tail 5 --json 2>/dev/null || true)"
    [ -z "$logs_json" ] && return 1
    verdict="$(printf '%s' "$logs_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not d.get("ok"):
        print("no"); sys.exit(0)
    entries = [e for e in (d.get("entries") or []) if e.get("type") in ("assistant", "user")]
    if not entries:
        print("no"); sys.exit(0)
    last = entries[-1]
    if last.get("type") != "assistant":
        print("no"); sys.exit(0)
    stop_reason = (last.get("message") or {}).get("stop_reason")
    blocks = last.get("blocks") or []
    lb = blocks[-1] if blocks else {}
    lb_type = lb.get("type")
    if stop_reason == "end_turn" and lb_type != "tool_use":
        print("yes")
    elif stop_reason == "tool_use" and lb_type == "tool_use" and lb.get("name") == "AskUserQuestion":
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
' 2>/dev/null)"
    [ "$verdict" = "yes" ] && return 0
    return 1
}

# pane_shows_permission_prompt (ga-iog1v / AC1 de ga-q640n): a MESMA situação
# de transcript CONGELADO cobre dois casos que session_awaiting_human_input()
# acima não distingue: (a) turno terminou LIMPO (end_turn sem tool pendente,
# ou AskUserQuestion) — já suprimido acima — versus (b) turno terminou num
# tool_use PENDENTE (Bash, Write, etc.) que nunca recebeu tool_result porque
# a CLI está bloqueada num diálogo de confirmação de permissão. (b) hoje cai
# em "NOT CONFIRMED" em session_awaiting_human_input() e escala pelo caminho
# genérico abaixo — o que já FUNCIONA (ga-q640n escalou 3x) mas com uma
# mensagem que não diz a causa, então ninguém agiu por 7 horas.
#
# Lê o PANE RENDERIZADO (não o transcript JSONL — o prompt é chrome de UI da
# CLI, nunca escrito na conversa) via `gc session peek`, procurando a
# assinatura textual estável do diálogo real: "Do you want to proceed?" /
# "requires confirmation". Restringe o grep às ÚLTIMAS linhas do peek (não
# o bloco todo) porque um diálogo REALMENTE aberto e bloqueando é sempre a
# última coisa renderizada (é onde o cursor espera) — texto antigo no
# scrollback que por acaso cite essas frases (ex.: um agente discutindo
# este próprio bug) não fica preso perto do fim quando o transcript está
# congelado há >=TRANSCRIPT_FRESH_SEC.
#
# FAIL-CLOSED de propósito (direção oposta aos outros checks deste arquivo):
# peek ausente/ilegível NUNCA vira "prompt confirmado" — na pior hipótese só
# perde a mensagem diferenciada e cai no caminho genérico que já escalava
# antes desta mudança (nunca suprime, nunca inventa uma escalação nova).
#
#   0 = CONFIRMADO — diálogo de permissão aberto (match estável no final do pane)
#   1 = não confirmado (peek falhou, vazio, ou sem match)
pane_shows_permission_prompt() {
    local sess="$1" peek_out tail_out
    peek_out="$(timeout 15 "$GC" session peek "$sess" --lines 40 2>/dev/null || true)"
    [ -z "$peek_out" ] && return 1
    tail_out="$(printf '%s\n' "$peek_out" | tail -12)"
    printf '%s' "$tail_out" | grep -qE 'Do you want to proceed\?|requires confirmation'
}

# permission_prompt_blocked_command (ga-iog1v / AC2 de ga-q640n): quando
# pane_shows_permission_prompt() confirma o diálogo, busca no MESMO envelope
# que transcript_is_advancing() já consulta (`gc session logs --tail 1
# --json`) o nome da tool + comando do tool_use pendente, pra a mensagem de
# escalação citar o comando EXATO em vez de só dizer "travado". Saída vazia
# em qualquer falha de parse — fail-open pra uma mensagem menos informativa,
# nunca pra um comando fabricado.
permission_prompt_blocked_command() {
    local sess="$1" logs_json
    logs_json="$(timeout 15 "$GC" session logs "$sess" --tail 1 --json 2>/dev/null || true)"
    [ -z "$logs_json" ] && return 1
    printf '%s' "$logs_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if not d.get("ok"):
        sys.exit(1)
    entries = [e for e in (d.get("entries") or []) if e.get("type") == "assistant"]
    if not entries:
        sys.exit(1)
    blocks = entries[-1].get("blocks") or []
    lb = blocks[-1] if blocks else {}
    if lb.get("type") != "tool_use":
        sys.exit(1)
    name = lb.get("name") or "?"
    inp = lb.get("input") or {}
    cmd = inp.get("command") or inp.get("cmd") or json.dumps(inp)[:200]
    print("%s: %s" % (name, cmd))
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# gate_reviewer_permission_prompt_session (ga-lxk26): a bead EM GATE has NO
# builder session by design (ga-n937 below) — bead.assignee is typically
# empty, so every assignee-keyed check in this file (session health,
# transcript tri-state, pane_shows_permission_prompt) never runs for it. But
# the gate itself has a LIVE reviewer session, and THAT session can be the
# one blocked on a permission dialog — this is the actual ga-lxk26 incident
# (Athos, live: "tem uma bead sendo revisada no gate ha mais de 20 minutos...
# eu nem sabia que isso estava pendente em mim" — a gate-reviewer stuck on an
# `rm -rf` confirmation while the ga-n937 suppression below ran every 5min
# and never looked past "EM GATE").
#
# Resolves bead_id -> its OPEN, actively-running gate-run (type:quality-
# gate-run, gate-status:running, source-bead:<id> — the SAME query
# bead_has_open_gate_marker() below already issues, just widened to also
# recognize this other bead type in the same result set) -> that run's
# still-open (non-closed) type:quality-gate-verdict beads -> each verdict's
# .assignee, which IS the reviewer's live session name (set by
# quality-gate-dispatcher.sh's assign_verdict_bead_verified(), read-back
# verified there). Checks pane_shows_permission_prompt() against each
# candidate session in turn; echoes the FIRST confirmed-blocked session name
# and returns 0.
#
# FAIL-CLOSED throughout, same direction as pane_shows_permission_prompt()
# itself: a missing/unreadable run, verdict, assignee, or any query failure
# returns 1 with nothing echoed. This function only ever LIFTS ga-n937's
# suppression on a positive, confirmed signal — never on the absence of one
# — so a caller that gets nothing back here must fall through to the
# existing (safe, already-shipped) in-gate suppression unchanged.
gate_reviewer_permission_prompt_session() {
    local bid="${1:-}" arts run_id verdicts candidates cand
    [ -n "$bid" ] || return 1
    command -v "$BD" >/dev/null 2>&1 || return 1

    arts="$(timeout 15 "$BD" -C "$CITY" list -l "source-bead:$bid" --json 2>/dev/null || true)"
    [ -z "$arts" ] && return 1
    run_id="$(printf '%s' "$arts" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    d = [d]
if not isinstance(d, list):
    sys.exit(0)
for b in d:
    if not isinstance(b, dict):
        continue
    if b.get("status") != "open":
        continue
    labels = b.get("labels") or []
    if "type:quality-gate-run" in labels and "gate-status:running" in labels:
        print(b.get("id") or "")
        break
' 2>/dev/null || true)"
    [ -z "$run_id" ] && return 1

    verdicts="$(timeout 15 "$BD" -C "$CITY" list -l "gate-run:$run_id" --json 2>/dev/null || true)"
    [ -z "$verdicts" ] && return 1
    candidates="$(printf '%s' "$verdicts" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    d = [d]
if not isinstance(d, list):
    sys.exit(0)
for b in d:
    if not isinstance(b, dict):
        continue
    if b.get("status") == "closed":
        continue
    labels = b.get("labels") or []
    if "type:quality-gate-verdict" not in labels:
        continue
    a = b.get("assignee") or ""
    if a:
        print(a)
' 2>/dev/null || true)"
    [ -z "$candidates" ] && return 1

    while IFS= read -r cand; do
        [ -z "$cand" ] && continue
        if pane_shows_permission_prompt "$cand"; then
            printf '%s' "$cand"
            return 0
        fi
    done <<< "$candidates"
    return 1
}

# build_permission_prompt_body / send_escalation (ga-lxk26 factor-out): the
# body template and routing/DRY_RUN/notify/mail/cooldown-write tail for a
# CONFIRMED permission-dialog escalation, used verbatim by both the original
# per-assignee frozen-session path (further below, in the main loop) and the
# new in-gate reviewer-session path above. Factored out so the two call
# sites cannot drift into two different-looking messages for the same "1
# tecla resolve" situation. Neither function changes behavior for the
# existing call site — they're the exact same statements, just callable from
# two places now.
build_permission_prompt_body() {
    local bead_id="$1" title="$2" assignee_display="$3" live_session_name="$4" \
          blocked_cmd="$5" age_min="$6" failure_markers="$7"
    cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: agente BLOQUEADO EM PROMPT DE PERMISSÃO
(NÃO é um stall genérico — o pane confirma um diálogo interativo aberto).

Bead:      $bead_id — $title
Assignee:  ${assignee_display:-'(não atribuído)'}
Sessão:    $live_session_name
Comando bloqueado: $blocked_cmd
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Marcadores de falha: $failure_markers

O QUE ACONTECEU: mesmo com bypass de permissões ativo, uma regra "ask"
explícita ainda exigiu confirmação e a sessão está parada num diálogo como:
  "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"
\`gc session nudge\` NÃO resolve isso — a mensagem fica em fila e só é
processada DEPOIS do diálogo (verificado: 105s+ sem efeito). Não tente
nudge aqui.

AÇÃO SUGERIDA (confirmação antes de agir, resolve em segundos, não é kill):
1. gc session peek $live_session_name --lines 40 — confirme o texto exato do prompt
2. Responda a tecla certa DIRETAMENTE no pane (exceção documentada da
   doutrina de pool — nudge não serve pra isto): tmux send-keys -t <pane>
   '1' Enter (ou a tecla da opção CORRETA — leia o prompt antes, não assuma
   sempre '1')
3. Depois de destravar: se esta regra de permissão alcança sessões de pool
   não-supervisionadas, considere virar "deny"/"allow" — nunca "ask"
   (ga-q640n/AC3).

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2 · permission-prompt: ga-iog1v/ga-q640n)
BODY
}

send_escalation() {
    local bead_id="$1" title="$2" labels="$3" age_min="$4" assignee_for_notify="$5" \
          permission_prompt_detected="$6" mail_subject_prefix="$7" body="$8" sf="$9"

    local _esc_target="$MAYOR_ADDR" _esc_topic=""
    if [ "$_ROUTER_AVAILABLE" = "1" ] && command -v escalation_classify_topic >/dev/null 2>&1; then
        _esc_topic=$(escalation_classify_topic "$title $labels" 2>/dev/null || echo "")
        if [ -n "$_esc_topic" ]; then
            _esc_target=$(escalation_topic_to_crew "$_esc_topic" 2>/dev/null || echo "$MAYOR_ADDR")
        fi
    fi
    log "$bead_id: escalation target=$_esc_target (topic=${_esc_topic:-none})"

    if [ "$DRY_RUN" = "1" ]; then
        log "  [DRY_RUN] would send mail to $_esc_target for $bead_id"
        log "  [DRY_RUN] subject: ${mail_subject_prefix}: $bead_id (${age_min}min sem progresso)"
        printf '%s' "$now" > "$sf"
        return 0
    fi

    if command -v "$NOTIFY" >/dev/null 2>&1; then
        if [ "$permission_prompt_detected" = "1" ]; then
            "$NOTIFY" -t "Agente bloqueado em prompt" -p 5 \
                "$bead_id (${assignee_for_notify:-?}) BLOQUEADO em prompt de permissão — 1 tecla resolve → ${_esc_target}" \
                >/dev/null 2>&1 || true
        else
            "$NOTIFY" -t "Agente travado" -p 4 \
                "$bead_id (${assignee_for_notify:-?}) sem progresso há ${age_min}min — escalando → ${_esc_target}" \
                >/dev/null 2>&1 || true
        fi
    fi

    if timeout 45 "$GC" mail send "$_esc_target" \
            -s "${mail_subject_prefix}: $bead_id — ${age_min}min sem progresso (assignee=${assignee_for_notify:-?})" \
            -m "$body" \
            >/dev/null 2>&1; then
        log "  mail enviado a $_esc_target (topic=${_esc_topic:-none}) para $bead_id"
        printf '%s\n' "$now" > "$sf"
    else
        log "  WARN: gc mail send falhou para $bead_id — notify já disparado"
        printf '%s\n' "$now" > "$sf"
    fi
}

# gate_label_present (ga-n937): true iff the comma-joined label list $1
# carries a gate:* lifecycle label (queued/reviewing/passed/merging/…)
# OTHER than gate:needs-fix or gate:needs-human — mirrors pilot-
# dispatcher.sh's _filter_built "gate:* lifecycle label" predicate exactly,
# including both exemptions: gate:needs-fix means a fixer SHOULD be
# actively working there (a frozen fixer is a real stall — must still
# escalate); gate:needs-human means the gate's own quorum already bounced
# to a human (leave today's failure_markers escalation behavior alone —
# don't newly suppress it).
gate_label_present() {
    local labels_csv="${1:-}" lbl
    local -a lbls=()
    IFS=',' read -ra lbls <<< "$labels_csv"
    # "${lbls[@]:-}" (not "${lbls[@]}"): under `set -u`, expanding a
    # zero-element array with the bare @ form is an unbound-variable error in
    # this bash — the :- fallback keeps an empty/no-label bead from aborting
    # the whole pass (discovered live: it silently killed T2/T9/T14/T15 etc.,
    # every bead with no labels, until this guard was added).
    for lbl in "${lbls[@]:-}"; do
        [ -z "$lbl" ] && continue
        case "$lbl" in
            gate:needs-fix|gate:needs-fix:*|gate:needs-human|gate:needs-human:*)
                ;;
            gate|gate:*)
                return 0
                ;;
        esac
    done
    return 1
}

# bead_has_open_gate_marker (ga-n937): mirrors pilot-dispatcher.sh's
# _beadid_has_open_gate_marker — the canonical "already-built / in-gate"
# primitive (wa-8y45 leak), not reinvented here. True iff an OPEN
# type:quality-gate-marker in the HQ store (CITY) names <bead_id> via
# source-bead:<id>, at ANY gate-status — covers the case where the crew
# branch was already pruned (needs-rebase/error) but the marker still owns
# the bead. Gate artifacts always live in the HQ store regardless of which
# rig the bead belongs to. FAIL-OPEN: no bd, any bd/python error, or an
# empty read → return 1 (no marker) — an unreadable gate query must never
# suppress a real stall.
bead_has_open_gate_marker() {
    local bid="${1:-}" arts hit
    [ -n "$bid" ] || return 1
    command -v "$BD" >/dev/null 2>&1 || return 1
    arts="$(timeout 15 "$BD" -C "$CITY" list -l "source-bead:$bid" --json 2>/dev/null || true)"
    [ -z "$arts" ] && return 1
    hit="$(printf '%s' "$arts" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
if isinstance(d, dict):
    d = [d]
if not isinstance(d, list):
    print(0); sys.exit(0)
n = 0
for b in d:
    if not isinstance(b, dict):
        continue
    if b.get("status") != "open":
        continue
    if "type:quality-gate-marker" in (b.get("labels") or []):
        n += 1
print(n)
' 2>/dev/null || echo 0)"
    case "$hit" in ''|0) return 1 ;; *) return 0 ;; esac
}

# is_human_assignee (ga-tiwmm): an in_progress bead assigned to a HUMAN
# identity (e.g. "athosmartins@gmail.com") has no Gas Town agent
# session-template by construction — "sessão ausente" is not a stall signal
# for a human, it's the PERMANENT expected state while they hand-code a task.
# Before this fix, a human assignee fell straight through every tri-state
# transcript guard below (all gated on `-n "$live_session_name"`, which a
# human assignee never sets — there's no session to find) into escalation,
# paging the Mayor at the STUCK_AGENT_SEC threshold. Concrete: 2026-07-25,
# three anuncios beads (wa-6dd0l, wa-utjmz, wa-yevxq) each escalated at
# 30min while Athos manually built the anuncios dashboard.
#
# Heuristic: Gas Town session names/aliases (dog-ga4zc3, thies-wa-gam257,
# gastown.mayor, batista-ps-xxxxx, ...) are alphanumeric+hyphen+dot and never
# contain "@" (confirmed against the full `gc agent list` template roster);
# a human identity used as a bd assignee is an email address. This only
# suppresses on a CONFIRMED human marker — an assignee without "@" still
# falls through to the existing agent-liveness checks unchanged (T27: a
# genuinely dead non-email assignee still escalates, no regression).
is_human_assignee() {
    case "$1" in
        *@*) return 0 ;;
        *) return 1 ;;
    esac
}

printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/agent-stuck-escalation.startup"

log "=== pass start (PID $$, STUCK=${STUCK_AGENT_SEC}s, COOLDOWN=${COOLDOWN_SEC}s, DRY_RUN=$DRY_RUN) ==="

if [ -f "$STATE_DIR/agent-stuck-escalation.disabled" ]; then
    log "kill-switch active — no-op"
    exit 0
fi

now="$(date +%s)"

# ── Fetch in_progress beads (multi-store: HQ + WA + PS) ──────────────────────
# Collect each store's results into a temp file (separator-delimited) then merge
# in Python. Per-store failures are non-fatal (skipped). Dedup by bead id.
_TMP_PARTS="$(mktemp)"
for _store in $ESCALATION_STORES; do
    [ -d "$_store" ] || continue
    _part="$(timeout 30 "$BD" -C "$_store" list --status in_progress --json 2>/dev/null || true)"
    [ -z "$_part" ] || [ "$_part" = "[]" ] && continue
    printf '%s\n###STORESEP###\n' "$_part" >> "$_TMP_PARTS"
done
BEADS_RAW="$(python3 - "$_TMP_PARTS" <<'PY' || true
import json, sys
seen = {}
parts = open(sys.argv[1]).read().split('###STORESEP###')
for p in parts:
    p = p.strip()
    if not p:
        continue
    try:
        for b in json.loads(p) or []:
            bid = b.get('id', '')
            if bid and bid not in seen:
                seen[bid] = b
    except Exception:
        pass
print(json.dumps(list(seen.values())))
PY
)"
rm -f "$_TMP_PARTS"
if [ -z "$BEADS_RAW" ] || [ "$BEADS_RAW" = "[]" ]; then
    log "no in_progress beads or bd unavailable — healthy, nothing to check"
    # GC state for any leftover state files (all beads closed)
    for sf in "$ESCDIR"/*; do [ -f "$sf" ] && rm -f "$sf"; done
    exit 0
fi

# ── Fetch active session names (for assignee health check) ────────────────────
# ga-2tpd fix (part 1): bead.assignee carries a session's `session_name`
# (e.g. "dog-ga4zc3", "thies-wa-gam257"), NOT its `name`/alias (e.g.
# "gastown.dog-2", "thies-wa") — those differ for every CREW/DOG session.
# Adhoc sessions happen to have name==session_name, which is why matching on
# `name` alone (the old code) passed every selftest fixture while silently
# never matching a real crew/dog assignee — it made the tri-state transcript
# check below (ga-hehi/ga-4tmc) unreachable for exactly the long-running
# agents it exists to protect (confirmed live: this session's own
# name='gastown.dog-2' vs session_name='dog-ga4zc3', the latter being what
# bead assignees actually carry). Index every identifying field per active
# session so the match below succeeds no matter which one the assignee is.
SESS_RAW="$(timeout 20 "$GC" session list --json 2>/dev/null)"
SESS_RC=$?
TMP_SESS="$(mktemp)"
printf '%s' "$SESS_RAW" > "$TMP_SESS"
ACTIVE_SESSIONS="$(python3 - "$TMP_SESS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        raw = fh.read()
    data = json.loads(raw)
    for s in (data.get("sessions") or []):
        if s.get("state") == "active":
            for field in ("session_name", "name", "alias", "id"):
                v = s.get(field) or ""
                if v:
                    print(v)
except Exception:
    sys.exit(1)
PY
)"
PY_RC=$?
rm -f "$TMP_SESS"

# ga-2tpd fix (part 2): a FAILED `session list` query (nonzero exit, empty
# stdout, or unparseable JSON) must never collapse to the same value as a
# query that SUCCEEDED with zero active sessions (ga-p5q3 root class again).
# The old `${SESS_RAW:-{}}` default made a failed call look byte-identical
# to `{"sessions":[]}`, so ACTIVE_SESSIONS went empty either way and every
# assignee read AUSENTE — escalating stuck beads whose session state was
# never actually confirmed. SESSIONS_QUERY_FAILED lets the per-bead loop
# below suppress instead, the same fail-safe shape as transcript_state
# UNKNOWN.
SESSIONS_QUERY_FAILED=0
if [ "$SESS_RC" -ne 0 ] || [ -z "$SESS_RAW" ] || [ "$PY_RC" -ne 0 ]; then
    SESSIONS_QUERY_FAILED=1
fi

# ── Parse stuck beads ─────────────────────────────────────────────────────────
# Output per line: id|assignee|title|age_secs|updated_at|labels
TMP_BEADS="$(mktemp)"
printf '%s' "$BEADS_RAW" > "$TMP_BEADS"
STUCK_LIST="$(python3 - "$TMP_BEADS" "$now" "$STUCK_AGENT_SEC" "$SKIP_TYPES" <<'PY' || true
import json, sys, time, datetime

with open(sys.argv[1]) as fh:
    raw = fh.read().strip()
now = float(sys.argv[2])
threshold = float(sys.argv[3])
skip = set(sys.argv[4].split())

try:
    beads = json.loads(raw)
except json.JSONDecodeError as e:
    try:
        beads = json.loads(raw[:e.pos])
    except Exception:
        sys.exit(0)
except Exception:
    sys.exit(0)

if not isinstance(beads, list):
    sys.exit(0)

def parse_epoch(s):
    if not s:
        return None
    s = s.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            return time.mktime(dt.timetuple())
        return dt.timestamp()
    except Exception:
        return None

CURRENT_IDS = set()
for b in beads:
    if not isinstance(b, dict):
        continue
    bead_id = b.get("id") or ""
    if not bead_id:
        continue
    itype = (b.get("issue_type") or b.get("type") or "").lower()
    if itype in skip:
        continue
    updated = (b.get("updated_at") or b.get("updated") or b.get("updatedAt") or "")
    epoch = parse_epoch(updated)
    if epoch is None:
        continue
    age = now - epoch
    if age < threshold:
        print("ok|%s" % bead_id)  # not stuck, but emit ID for GC step
        continue
    assignee = (b.get("assignee") or b.get("owner") or "")
    title = (b.get("title") or b.get("summary") or "?")[:80].replace("|", "_")
    labels = b.get("labels") or []
    labels_str = ",".join(labels) if isinstance(labels, list) else str(labels)
    print("stuck|%s|%s|%d|%s|%s" % (bead_id, assignee, int(age), title, labels_str))
PY
)"
rm -f "$TMP_BEADS"

# Build set of all current in_progress bead IDs (for GC of state files)
ALL_INPROGRESS_IDS=""
STUCK_ITEMS=""
while IFS= read -r line; do
    [ -z "$line" ] && continue
    kind="${line%%|*}"
    rest="${line#*|}"
    bead_id="${rest%%|*}"
    [ -z "$bead_id" ] && continue
    ALL_INPROGRESS_IDS="$ALL_INPROGRESS_IDS $bead_id"
    if [ "$kind" = "stuck" ]; then
        STUCK_ITEMS="$STUCK_ITEMS
$rest"
    fi
done <<< "$STUCK_LIST"

# GC: remove state files for beads no longer in in_progress
for sf in "$ESCDIR"/*; do
    [ -f "$sf" ] || continue
    bn="$(basename "$sf")"
    if ! printf '%s' " $ALL_INPROGRESS_IDS " | grep -qF " $bn "; then
        log "$bn: no longer in_progress (closed/advanced) — clearing escalation state"
        rm -f "$sf"
    fi
done

if [ -z "$STUCK_ITEMS" ]; then
    log "no stuck beads (all in_progress beads updated within ${STUCK_AGENT_SEC}s)"
    exit 0
fi

# ── Process each stuck bead ───────────────────────────────────────────────────
while IFS='|' read -r bead_id assignee age_secs title labels; do
    [ -z "$bead_id" ] && continue

    age_min=$(( age_secs / 60 ))
    sf="$ESCDIR/$bead_id"

    # Cooldown: skip if already escalated within COOLDOWN_SEC
    if [ -f "$sf" ]; then
        last_esc="$(head -1 "$sf" 2>/dev/null || echo 0)"
        since_esc=$(( now - last_esc ))
        if [ "$since_esc" -lt "$COOLDOWN_SEC" ]; then
            remaining=$(( (COOLDOWN_SEC - since_esc) / 60 ))
            log "$bead_id: stuck ${age_min}min — already escalated ${since_esc}s ago (cooldown ${remaining}min remaining)"
            continue
        fi
    fi

    # In-gate skip (ga-n937 — follow-up to ga-hehi): a bead sitting in the
    # quality gate has NO builder session by design (the builder already
    # finished and exited), so signal 2 above never proves anything for it —
    # it always falls into the "absent session" branch and would escalate
    # every time the gate queue (routinely 29-38min; the gate's own stall
    # threshold is ~165min) exceeds STUCK_AGENT_SEC. Suppress (log-only, no
    # state file — a real stall on a later pass still escalates, undelayed)
    # when: (a) the bead carries a gate:* label (queued/reviewing/passed/
    # merging/…), OR (b) an OPEN type:quality-gate-marker in the HQ store
    # names it via source-bead:<id> (covers the case where the crew branch
    # was already pruned but the marker still owns the bead). EXCEPT
    # gate:needs-fix — there a fixer SHOULD be working; frozen is a real
    # stall and must still escalate.
    if gate_label_present "$labels" || bead_has_open_gate_marker "$bead_id"; then
        # ga-lxk26: BEFORE suppressing, check whether the bead's ACTIVE
        # gate-run has a reviewer session confirmed BLOCKED on a
        # permission-confirmation dialog. The ga-n937 suppression above is
        # correct for "gate queue has no builder" — the defect was
        # suppressing before ever asking whether a human is silently
        # blocking the gate. Escalates with the SAME differentiated
        # BLOQUEADO-EM-PROMPT message the assignee-path below already sends
        # (build_permission_prompt_body/send_escalation), and respects the
        # same COOLDOWN via $sf. Any unconfirmed/unresolvable case (no
        # running gate-run, reviewer working normally, queue simply parked)
        # falls through to the unchanged ga-n937 suppression right below —
        # this check only ever LIFTS suppression on a positive, confirmed
        # signal, never reintroducing the noise ga-n937 killed.
        gate_reviewer_sess="$(gate_reviewer_permission_prompt_session "$bead_id" 2>/dev/null || true)"
        if [ -n "$gate_reviewer_sess" ]; then
            gate_blocked_cmd="$(permission_prompt_blocked_command "$gate_reviewer_sess" 2>/dev/null || true)"
            [ -z "$gate_blocked_cmd" ] && gate_blocked_cmd="(comando não determinado — veja gc session peek $gate_reviewer_sess --lines 40)"
            log "$bead_id: EM GATE mas reviewer $gate_reviewer_sess BLOQUEADO-EM-PROMPT ${age_min}min — NÃO suprimindo (ga-lxk26): comando=[$gate_blocked_cmd]"
            gate_failure_markers=""
            if printf '%s' "$labels" | grep -q "gate:needs-human"; then
                gate_failure_markers="${gate_failure_markers}gate:needs-human "
            fi
            if printf '%s' "$labels" | grep -q "story:blocked"; then
                gate_failure_markers="${gate_failure_markers}story:blocked "
            fi
            [ -z "$gate_failure_markers" ] && gate_failure_markers="nenhum"
            gate_body="$(build_permission_prompt_body "$bead_id" "$title" "(bead sem assignee — EM GATE; reviewer=$gate_reviewer_sess)" "$gate_reviewer_sess" "$gate_blocked_cmd" "$age_min" "$gate_failure_markers")"
            send_escalation "$bead_id" "$title" "$labels" "$age_min" "$gate_reviewer_sess" "1" "Agente BLOQUEADO EM PROMPT (1 tecla resolve)" "$gate_body" "$sf"
            continue
        fi
        log "$bead_id: bead.updated_at parado ${age_min}min mas EM GATE (labels=$labels) — SUPRIMINDO escalação (sem builder por design, ga-n937)"
        continue
    fi

    # Empty/absent assignee on an in_progress bead (ga-79vq): there's no name
    # to check — not a confirmed-dead session, just an INDETERMINATE owner.
    # Before this fix, the session-health block below (gated on `-n
    # "$assignee"`) never ran, so live_session_name and transcript_state both
    # stayed "" — matching neither "advancing" nor "unknown" further down,
    # falling through both guards straight into escalation. Same error-vs-
    # empty conflation this script has fixed before (ga-2tpd, ga-4tmc;
    # ga-p5q3 root class): "don't know who owns this" and "owner confirmed
    # dead" produced the same outcome. Concretely: a bead's assignee can be
    # cleared mid-flight (inflight-reclaim-guard, a raw `bd update`, ...)
    # while the real owner — findable only via crew:<name>/gc.routed_to,
    # which this probe doesn't resolve — keeps working (wa-ka2lm escalated 3x
    # against a live thies-wa-gam257). Suppress on unknown, like the other
    # tri-state fail-safes below.
    if [ -z "$assignee" ]; then
        log "$bead_id: bead.updated_at parado ${age_min}min — assignee vazio/ausente — dono indeterminável (não confirmado morto) — SUPRIMINDO escalação (fail-safe ga-79vq)"
        continue
    fi

    # Human-assigned bead (ga-tiwmm): "sessão ausente" é o estado normal e
    # permanente pra um assignee que nunca ia ter sessão de agente. Precisa
    # rodar ANTES dos guards de SESSIONS_QUERY_FAILED/session-health/
    # transcript abaixo — todos só disparam quando live_session_name está
    # setado, o que um assignee humano nunca faz, então sem este guard a
    # execução cai direto na escalação (era exatamente o bug).
    if is_human_assignee "$assignee"; then
        log "$bead_id: bead.updated_at parado ${age_min}min — assignee=$assignee é identidade humana (sem agent session-template) — SUPRIMINDO escalação (fail-safe ga-tiwmm: trabalho manual humano, não agente travado)"
        continue
    fi

    # ga-2tpd fix (part 2): the session-list query failed this whole pass —
    # this assignee's session state was never actually checked. Suppress
    # rather than fall through to "AUSENTE" (see SESSIONS_QUERY_FAILED note
    # above). Unassigned beads have no session to fail to check, so they
    # are unaffected and keep escalating on updated_at alone.
    if [ "$SESSIONS_QUERY_FAILED" = "1" ] && [ -n "$assignee" ]; then
        log "$bead_id: bead.updated_at parado ${age_min}min — 'gc session list' falhou/vazio nesta passada — estado de sessão de $assignee DESCONHECIDO (não confirmado ausente) — SUPRIMINDO escalação (fail-safe ga-2tpd)"
        continue
    fi

    # Session health check for assignee
    sess_status="ausente/desconhecida"
    live_session_name=""
    if [ -n "$assignee" ]; then
        if printf '%s\n' "$ACTIVE_SESSIONS" | grep -qx "$assignee"; then
            sess_status="ativa (responde ao session list)"
            live_session_name="$assignee"
        else
            # Also try prefix match (gawisp-form)
            base_tmpl="${assignee%%-gawisp*}"
            gawisp_match="$(printf '%s\n' "$ACTIVE_SESSIONS" | grep "^${base_tmpl}" | head -1)"
            if [ -n "$gawisp_match" ]; then
                sess_status="ativa (gawisp-form: $gawisp_match)"
                live_session_name="$gawisp_match"
            else
                sess_status="AUSENTE (nenhuma sessão ativa com nome '$assignee')"
            fi
        fi
    fi

    # Transcript-progress gate (ga-hehi; tri-state hardened by ga-4tmc): a
    # live session alone never proved progress, and a FAILED progress query
    # must never be read as a CONFIRMED freeze (ga-p5q3 root class — error
    # and empty must not collapse to the same value). Only a transcript
    # CONFIRMED frozen (rc=1: query succeeded, no live progress found) falls
    # through to escalate below; both CONFIRMED advancing (rc=0) and UNKNOWN
    # (rc=2: the query itself failed — e.g. crew/dog sessions where `gc
    # session logs` returns an {"ok":false,...} envelope) suppress — log-only,
    # no state file write, so a real freeze on a later pass still escalates
    # normally, undelayed by this suppression.
    transcript_state=""
    if [ -n "$live_session_name" ]; then
        transcript_is_advancing "$live_session_name"
        case "$?" in
            0) transcript_state="advancing" ;;
            1) transcript_state="frozen" ;;
            *) transcript_state="unknown" ;;
        esac
    else
        # ga-v6ols: the batch `gc session list` scan above and this
        # per-session `gc session logs` probe are two INDEPENDENT queries —
        # live evidence showed a session confirmed active by hand (`gc
        # session list`) and a transcript written 6s earlier, yet THIS
        # script's own batch scan the SAME pass logged "sess=AUSENTE" for
        # it. ga-2tpd's SESSIONS_QUERY_FAILED (above) only catches the
        # batch call FAILING outright (nonzero exit/empty/unparseable) —
        # it does not catch the batch call SUCCEEDING with a stale or
        # incomplete list, which is what the evidence points at. Before
        # this fix, "not found in the batch scan" skipped this probe
        # entirely (transcript_state stayed "" here and fell straight
        # through to escalation below).
        #
        # AC1 of ga-v6ols keeps "não-encontrada" (batch-confirmed-absent) a
        # valid, non-suppressing state on its own — only
        # "não-consegui-consultar" (SESSIONS_QUERY_FAILED, above) suppresses
        # by itself; a genuinely-dead assignee with an unreadable transcript
        # must still escalate (AC4 — T15/T27 below lock this in). So this
        # probe only ACTS when it affirmatively CONTRADICTS the batch
        # "not found" verdict: proof of a live/advancing transcript (or,
        # weaker, a resolvable-but-stale one) is new information the batch
        # scan alone didn't have. An inconclusive probe (ok:false — the
        # same "no session file found" shape ga-4tmc found for otherwise-
        # live crew/dog sessions) adds nothing, so it does not override an
        # already-correct default — per AC2 the two signals are still
        # consulted independently either way, this just doesn't let an
        # unproven result overturn a state that was already settled.
        transcript_is_advancing "$assignee"
        case "$?" in
            0)
                transcript_state="advancing"
                live_session_name="$assignee"
                sess_status="$sess_status — checagem direta (gc session logs $assignee) contradiz: transcript ADVANCING (ga-v6ols)"
                ;;
            1)
                transcript_state="frozen"
                live_session_name="$assignee"
                sess_status="$sess_status — checagem direta (gc session logs $assignee): transcript CONGELADO (ga-v6ols)"
                ;;
            *)
                : # inconclusive — no new evidence; "não-encontrada" stands, escalation path below unchanged (AC1/AC4)
                ;;
        esac
    fi

    if [ "$transcript_state" = "advancing" ]; then
        log "$bead_id: bead.updated_at parado ${age_min}min mas transcript de $live_session_name avançando (escrita <${TRANSCRIPT_FRESH_SEC}s) — sess=$sess_status — SUPRIMINDO escalação (trabalho longo legítimo)"
        continue
    fi
    if [ "$transcript_state" = "unknown" ]; then
        log "$bead_id: bead.updated_at parado ${age_min}min — 'gc session logs $live_session_name' falhou (ok:false/sem resposta) — transcript DESCONHECIDO (não confirmado congelado) — SUPRIMINDO escalação (fail-safe ga-4tmc: pergunta que falha nunca vira veredito de vazio)"
        continue
    fi

    # wa-y0620: transcript CONFIRMED frozen + session alive is still not
    # proof of a hang — it is the SAME signal a correctly-blocked agent
    # produces after asking something and ceding the turn by design. See
    # session_awaiting_human_input() above for the full rationale (Mayor
    # confirmed 2 real false positives from exactly this the same day).
    if [ "$transcript_state" = "frozen" ] && session_awaiting_human_input "$live_session_name"; then
        log "$bead_id: bead.updated_at parado ${age_min}min — transcript de $live_session_name CONGELADO mas último turno terminou AGUARDANDO HUMANO (end_turn sem tool_use pendente, ou AskUserQuestion) — SUPRIMINDO escalação (fail-safe wa-y0620: aguardando-humano ≠ travado)"
        continue
    fi

    # pane_shows_permission_prompt (ga-iog1v / AC1+AC2 de ga-q640n): diferente
    # do check acima (que SUPRIME quando o turno terminou limpo), aqui o
    # turno ainda tem um tool_use PENDENTE — a escalação abaixo vai disparar
    # de qualquer forma (nenhum "continue" aqui). O que muda é SÓ a
    # mensagem: se o pane confirma um diálogo de permissão aberto, a
    # mensagem genérica "sem progresso" vira BLOQUEADO-EM-PROMPT + comando
    # exato + pane — porque aqui basta 1 tecla, não um kill/reclaim.
    permission_prompt_detected=0
    blocked_cmd=""
    if [ "$transcript_state" = "frozen" ] && [ -n "$live_session_name" ] && pane_shows_permission_prompt "$live_session_name"; then
        permission_prompt_detected=1
        blocked_cmd="$(permission_prompt_blocked_command "$live_session_name" 2>/dev/null || true)"
        [ -z "$blocked_cmd" ] && blocked_cmd="(comando não determinado — veja gc session peek $live_session_name --lines 40)"
    fi

    transcript_note="n/d (sem sessão viva)"
    [ "$transcript_state" = "frozen" ] && transcript_note="CONGELADO (sem escrita há >=${TRANSCRIPT_FRESH_SEC}s)"

    # Failure markers present?
    failure_markers=""
    if printf '%s' "$labels" | grep -q "gate:needs-human"; then
        failure_markers="${failure_markers}gate:needs-human "
    fi
    if printf '%s' "$labels" | grep -q "story:blocked"; then
        failure_markers="${failure_markers}story:blocked "
    fi
    [ -z "$failure_markers" ] && failure_markers="nenhum"

    if [ "$permission_prompt_detected" = "1" ]; then
        log "$bead_id: BLOQUEADO-EM-PROMPT ${age_min}min — assignee=$assignee sess=$sess_status comando=[$blocked_cmd] labels=$labels"
    else
        log "$bead_id: STUCK ${age_min}min — assignee=$assignee sess=$sess_status transcript=$transcript_note labels=$labels"
    fi

    # Build diagnostic mail body — differenciada (ga-iog1v/AC2) quando um
    # diálogo de confirmação de permissão foi confirmado aberto no pane:
    # NÃO é um stall genérico, precisa de um remédio específico, barato e
    # não-destrutivo (responder o prompt), não o menu de kill/reclaim abaixo.
    mail_subject_prefix="Agente travado"
    if [ "$permission_prompt_detected" = "1" ]; then
        mail_subject_prefix="Agente BLOQUEADO EM PROMPT (1 tecla resolve)"
        body="$(build_permission_prompt_body "$bead_id" "$title" "$assignee" "$live_session_name" "$blocked_cmd" "$age_min" "$failure_markers")"
    else
        body="$(cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: bead in_progress sem progresso detectado.

Bead:      $bead_id — $title
Assignee:  ${assignee:-'(não atribuído)'}
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Sessão:    $sess_status
Transcript: $transcript_note
Marcadores de falha: $failure_markers

AÇÃO SUGERIDA:
1. gc session peek ${assignee:-<assignee>} — confirme se realmente travado ou só lento
2. gc bd show $bead_id — veja estado atual do bead
3. Se travado: shutdown-dance (3 nudges via dog pool) ou kill+re-despache
4. Se misroute: circuit-break (gate:needs-human) e reassinalação ao dono correto
5. Se bead avançou mas updated_at não se moveu: update manual para parar alertas

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2)
BODY
)"
    fi

    send_escalation "$bead_id" "$title" "$labels" "$age_min" "$assignee" "$permission_prompt_detected" "$mail_subject_prefix" "$body" "$sf"

done <<< "$STUCK_ITEMS"

log "=== pass complete ==="
exit 0
