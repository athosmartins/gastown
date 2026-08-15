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
#   7. EXCETO se o transcript CONGELADO é porque o TURNO em si é longo, não
#      porque o agente morreu (ga-0xmxt): max-effort thinking / um subagente
#      ativo podem rodar 30min+ como uma unidade só antes do CLI sequer
#      flush-ar uma escrita no transcript — medido ao vivo: uma sessão real
#      mostrou "Wandering… (33m 18s · ↓ 138.6k tokens)" ainda em andamento,
#      já passando o limiar antigo de 1800s. "Pensando há 30min" e "morto há
#      30min" viravam o MESMO sinal, e a própria escalação recomendava
#      kill/shutdown-dance — descartando o raciocínio e o contexto já
#      carregados de um agente vivo. Dois sinais observáveis de FORA, sem
#      depender de escrita no transcript: (a) o pane mostra uma tool call em
#      execução ("Running N shell command(s)…", presente + reticências —
#      distinto de "Ran N shell commands", o resumo passado que todo turno
#      JÁ CONCLUÍDO também deixa no scrollback); (b) o contador de tokens do
#      próprio CLI ("↓ NNk tokens") MUDOU desde a última amostra — subiu OU
#      desceu (gate fix-attempt-2: um reset de contexto ou uma troca pra um
#      contador de SUBAGENTE — ex. "Explore … ↓140.3k tokens" — pode
#      legitimamente BAIXAR o valor lido; queda também é vida, só a IGUALDADE
#      exata prova pane congelado) — ou é a primeira vez que este bead é
#      visto travado (amostra "não-provada" nunca vira veredito de morto,
#      mesma lógica tri-state de transcript_is_advancing() acima). Comparar
#      VALORES em vez de casar texto é o que torna (b) auto-corretivo contra
#      um pane congelado num crash: o número fica EXATAMENTE igual entre
#      amostras, então para de suprimir depois de UMA passada de graça e
#      volta a escalar normalmente — nunca um blind spot permanente. Limiar
#      padrão também subiu de 1800s pra 3600s (mesma medição) como defesa em
#      profundidade, não como o fix em si. Ver
#      pane_shows_active_child_process()/tokens_rising_or_first_sample()
#      abaixo.
#
#   8. RETOMADA AUTOMÁTICA ANTES DE ESCALAR (ga-nrkh92, Athos aprovou
#      2026-08-15: "a cidade deve ACORDAR SOZINHA e avisar depois"): quando
#      TODAS as camadas 1-7 acima confirmam travamento genérico real (não
#      BLOQUEADO-EM-PROMPT — esse caso continua só mail, ver item 6) E há
#      uma sessão viva pra acordar, o daemon NÃO manda mail direto mais —
#      primeiro tenta retomar pelo canal interativo (gc session nudge + tmux
#      send-keys direto no pane, texto e Enter em chamadas separadas — ver
#      send_idle_resume()), registra o estado em RESUMEDIR, e só escala
#      (mail+notify, via o MESMO send_escalation() de sempre) se
#      RESUME_GRACE_SEC se passar SEM o transcript voltar a avançar. Uma
#      sessão genuinamente ausente (sem pane pra acordar) continua indo
#      direto pra escalação, sem essa etapa — comportamento inalterado.
#      Dois cuidados adicionais, medidos ao vivo pelo Mayor no incidente que
#      originou este bead (3 crews nomeadas paradas 7-13h numa noite):
#        (b) NÃO usa %cpu do `ps` pra decidir se está realmente ocioso — é
#            média da vida do processo, não discrimina. Usa TIME acumulado,
#            amostrado 2x com IDLE_CPU_SAMPLE_SEC de intervalo (delta==0 =
#            ocioso confirmado). Ver pane_truly_idle()/pane_cpu_time_secs().
#        (f) Um bead pode declarar metadata "gc.active_window"="HH:MM-HH:MM"
#            (tolera virada de meia-noite) — fora dessa janela, ociosidade é
#            ESPERADA e correta; o daemon não retoma nem escala. Sem essa
#            metadata (o default hoje), a janela nunca se aplica. Ver
#            now_outside_active_window().
#      Ao escalar por falta de resposta, a mensagem prova "trabalho único
#      em risco" via `git cherry origin/main HEAD` (patch-id), NUNCA via
#      ref-não-mergeada — uma branch pode parecer não-mergeada e ainda assim
#      ter todo o conteúdo em main por outro commit/fatia (medido ao vivo no
#      próprio dia deste bead, wa-x92yd). Ver has_unique_work() (critério e).
#
# ANTI-SPAM: uma escalação por bead por janela COOLDOWN_SEC (padrão 3h).
#   Per-bead state: .gc/state/agent-stuck-escalation/<bead-id>
#   Per-bead resume state (ga-nrkh92): .gc/state/agent-idle-resume/<bead-id>
#     (linha 1 = epoch do último nudge de retomada enviado)
#   Quando bead sai do in_progress (fecha ou avança) → GC limpa o estado dele.
#
# Launchd: com.gascity.agent-stuck-escalation (StartInterval 300)
# Log: .gc/logs/agent-stuck-escalation.log
# Kill-switch: .gc/state/agent-stuck-escalation.disabled
# DRY_RUN=1: log/notify apenas, sem mail ao Mayor nem retomada real via tmux
#   (selftest/supervised — send_idle_resume() ainda loga a tentativa)

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
BD="${BD:-bd}"
NOTIFY="${NOTIFY_BIN:-notify}"
TMUX="${TMUX_BIN:-tmux}"     # ga-nrkh92: retomada interativa (send_idle_resume)
GIT="${GIT_BIN:-git}"        # ga-nrkh92: prova de trabalho único (has_unique_work)
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/agent-stuck-escalation.log"
STATE_DIR="$CITY/.gc/state"
ESCDIR="$STATE_DIR/agent-stuck-escalation"
TOKDIR="$STATE_DIR/agent-stuck-escalation-tokens"  # ga-0xmxt: per-bead last-seen token count
RESUMEDIR="$STATE_DIR/agent-idle-resume"  # ga-nrkh92: per-bead last-resume-nudge timestamp

STUCK_AGENT_SEC="${STUCK_AGENT_SEC:-3600}"   # 60min sem update → travado (ga-0xmxt: subiu de 1800s — medido ao vivo um turno de max-effort em 33m18s e ainda rodando, 1800s dava zero margem)
COOLDOWN_SEC="${COOLDOWN_SEC:-10800}"        # 3h antes de re-escalar o mesmo bead
TRANSCRIPT_FRESH_SEC="${TRANSCRIPT_FRESH_SEC:-$STUCK_AGENT_SEC}"  # ga-hehi: transcript escrito há menos disso = avançando
RESUME_GRACE_SEC="${RESUME_GRACE_SEC:-900}"  # ga-nrkh92: prazo após o nudge de retomada, antes de escalar por falta de resposta (~3 ciclos de StartInterval)
IDLE_CPU_SAMPLE_SEC="${IDLE_CPU_SAMPLE_SEC:-5}"  # ga-nrkh92: intervalo entre as 2 amostras de TIME acumulado do pane (pane_truly_idle)
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

mkdir -p "$LOG_DIR" "$STATE_DIR" "$ESCDIR" "$TOKDIR" "$RESUMEDIR"

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

# pane_shows_active_child_process (ga-0xmxt): the transcript-frozen signal
# above conflates "no tool boundary has closed in TRANSCRIPT_FRESH_SEC" with
# "dead" — but a single tool call (a shell command, a subagent) can run well
# past that window as ONE unit, with nothing to flush until it returns. The
# CLI renders its OWN present-tense, in-flight indicator for this
# ("Running 2 shell commands…", captured live from a real gate-reviewer
# session) — distinct from "Ran N shell commands", the PAST-TENSE summary
# every already-completed turn leaves in scrollback (also observed live,
# same session, describing a call that had already finished). Matching only
# the present-tense + ellipsis form is what keeps this from tripping on the
# ubiquitous historical "Ran N shell commands" lines. Restricted to the tail
# of the pane (not the whole 40-line capture) for the same reason
# pane_shows_permission_prompt() is: old scrollback that happens to mention
# "Running" (e.g. an agent's own prose *about* this bug) shouldn't count —
# only what's actually being rendered right now should. Wider tail window
# than pane_shows_permission_prompt() (20 vs 12): a permission dialog is
# always the literal last thing rendered (the CLI is fully blocked on it),
# but a live "Running…" indicator can have a multi-line command preview
# AND a subsequent spinner line after it before the footer chrome.
#
#   0 = CONFIRMED  — pane's tail shows a live "Running…" tool indicator
#   1 = not confirmed (peek failed/empty, or no match)
pane_shows_active_child_process() {
    local sess="$1" peek_out tail_out
    peek_out="$(timeout 15 "$GC" session peek "$sess" --lines 40 2>/dev/null || true)"
    [ -z "$peek_out" ] && return 1
    tail_out="$(printf '%s\n' "$peek_out" | tail -20)"
    printf '%s' "$tail_out" | grep -qE 'Running [0-9]+ shell (command|commands)|Running…|Running\.\.\.'
}

# pane_extract_token_count (ga-0xmxt): reads the CLI's own streaming token
# counter off its live spinner / active-subagent status line — e.g.
# "✽ Wandering… (33m 18s · ↓ 138.6k tokens)" or "◯ Explore  <desc>  3m 49s ·
# ↓ 140.3k tokens" (both captured live from real sessions actively working).
# Prints the bare numeric value (in k) on stdout; the caller decides what to
# do with it — this function only extracts, never judges "active" by
# itself, because a single sample can't distinguish "captured mid-turn" from
# "pane frozen at the last frame before a crash". See
# tokens_rising_or_first_sample() for the stateful comparison that makes
# that distinction. Same tail-20 rationale as pane_shows_active_child_process
# above (avoid matching a stale mention in old scrollback — this exact
# string was, in fact, quoted verbatim in an agent's own prose while
# discussing this bug, confirmed live, so the risk is not hypothetical).
#
#   stdout = numeric token count (k), return 0  — a live counter was found
#   (nothing printed), return 1                 — no counter in the pane's tail
pane_extract_token_count() {
    local sess="$1" peek_out val
    peek_out="$(timeout 15 "$GC" session peek "$sess" --lines 40 2>/dev/null || true)"
    [ -z "$peek_out" ] && return 1
    val="$(printf '%s\n' "$peek_out" | tail -20 | grep -oE '↓[[:space:]]*[0-9]+(\.[0-9]+)?k tokens' | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?')"
    [ -z "$val" ] && return 1
    printf '%s' "$val"
}

# tokens_rising_or_first_sample (ga-0xmxt): persists the last-seen token
# count per bead (mirrors the per-bead escalation-cooldown state file
# pattern already used for $sf, but in its own directory so its lifecycle
# isn't tied to escalation/cooldown bookkeeping) and compares across
# CONSECUTIVE DAEMON PASSES (StartInterval 300s) rather than matching text —
# this is what makes it "separar pensando de morto SEM heurística de tempo"
# (the bug's own framing): a genuinely dead session's last-rendered token
# count never changes between samples, so this signal naturally stops
# suppressing after one grace pass and falls through to the normal
# escalation path — never a permanent blind spot, unlike a pure text match
# on a pane that could stay frozen forever.
#
# DESPITE THE NAME (kept as-is for git-blame continuity across the gate's
# fix-attempt-2 — a rename would touch every call site and comment below for
# no behavior change): this suppresses on ANY observed change, not only a
# rise. Gate fix-attempt-1 compared `current > prev` and treated a DECREASE
# as "not suppress-worthy" — but pane_extract_token_count() reads whichever
# status line is LAST in the pane's tail, and that can legitimately switch
# from the main turn's own counter to an active SUBAGENT's counter (e.g.
# "Explore … ↓140.3k tokens") mid-turn — exactly the scenario this whole fix
# targets. That switch can just as easily read LOWER as higher. A decrease
# still proves the pane re-rendered since the last sample, i.e. the session
# is alive — so it must suppress exactly like a rise does. The ONLY value
# that proves a frozen pane is EQUALITY (current == prev): the renderer
# produced the identical frame twice in a row. Do NOT "fix" the decrease
# case with `>=` instead of `!=` — `>=` would additionally suppress on
# equality, which is the one case that must be allowed to escalate; that
# swaps a false-positive (rare, self-correcting after one grace pass) for a
# false-negative (a truly-stuck session never gets reported again).
#
# "No baseline yet" (first time this bead is seen stuck) suppresses too —
# ONE grace pass, same fail-safe posture as every other tri-state check in
# this file (UNKNOWN transcript, failed session-list query, empty assignee
# all suppress on ambiguity rather than treat "unproven" as "confirmed
# dead"). A truly-dead session with a stale counter visible gets exactly one
# 5-minute grace period, then the flat comparison on the next pass falls
# through to escalate normally — bounded, not indefinite.
#
#   0 = suppress-worthy (first sample, or current != previous — changed in
#       EITHER direction, which is proof of life)
#   1 = not suppress-worthy (current == previous — the one value that proves
#       a flat/frozen pane — or no count given)
tokens_rising_or_first_sample() {
    # Two separate `local` statements, not one (shellcheck SC2318): `tf`'s
    # RHS references `$bead_id`, and a same-statement `local a=X b=$a` does
    # NOT see `a`'s new value while evaluating `b` — it resolves through
    # whatever `$bead_id` already meant in the CALLER's scope. Confirmed
    # live: with a pre-existing caller-scope `bead_id` (exactly this
    # function's own real call site, nested in the per-bead `while read -r
    # bead_id ...` loop) `tf` silently built from the OUTER bead_id instead
    # of this function's `$1` — invisible today only because the caller's
    # `bead_id` always equals `$1` at this exact call site (same loop
    # iteration, no recursion), not because the line was actually correct.
    local bead_id="$1" current="${2:-}"
    local tf="$TOKDIR/$bead_id" prev
    [ -z "$current" ] && return 1
    prev=""
    [ -f "$tf" ] && prev="$(head -1 "$tf" 2>/dev/null || echo "")"
    printf '%s\n' "$current" > "$tf"
    [ -z "$prev" ] && return 0
    # != , not > and NOT >=: any observed change (rise OR fall) is proof of
    # life; only exact equality proves the pane rendered the identical frame
    # twice, i.e. frozen. See the function docstring above (gate
    # fix-attempt-2) for why >= is the wrong fix — it would additionally
    # suppress on equality, the one case that must escalate.
    python3 -c "
import sys
try:
    sys.exit(0 if float('$current') != float('$prev') else 1)
except Exception:
    sys.exit(1)
"
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

    # --include-infra (ga-vm20x, Mayor 07/08): the type:quality-gate-run
    # marker this looks for below is born --ephemeral (INFRA), hidden from
    # `bd list` by default under bd 1.1.0. Without this flag a genuinely
    # running gate review reads as "no run found", so this suppression
    # never fires and a permission-prompt session under active gate review
    # gets falsely escalated as stuck.
    arts="$(timeout 15 "$BD" -C "$CITY" list --include-infra -l "source-bead:$bid" --json 2>/dev/null || true)"
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
          blocked_cmd="$5" age_min="$6" failure_markers="$7" observed_at="$8"
    cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: possível agente BLOQUEADO EM PROMPT DE PERMISSÃO
(evidência coletada às ${observed_at} — NESSE INSTANTE o pane mostrava um
diálogo interativo aberto. Isto é um retrato, não o estado agora: pode já
ter mudado no tempo até você ler este e-mail. RECONFIRME no passo 1 antes
de agir — não assuma que o diálogo ainda está lá).

Bead:      $bead_id — $title
Assignee:  ${assignee_display:-'(não atribuído)'}
Sessão:    $live_session_name
Comando bloqueado (na leitura de ${observed_at}): $blocked_cmd
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Marcadores de falha: $failure_markers

O QUE PODE TER ACONTECIDO: mesmo com bypass de permissões ativo, uma regra
"ask" explícita pode ter exigido confirmação, parando a sessão num diálogo
como:
  "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"

AÇÃO SUGERIDA (o passo 1 decide o resto — não pule pro passo 2 sem reler o pane):
1. gc session peek $live_session_name --lines 40 — releia o pane AGORA, não
   confie só no snapshot acima.
2. SE o diálogo AINDA estiver lá: responda a tecla certa DIRETAMENTE no
   pane (exceção documentada da doutrina de pool — \`gc session nudge\`
   fica em fila atrás do diálogo e só é processado DEPOIS dele, verificado:
   105s+ sem efeito): tmux send-keys -t <pane> '<tecla>' Enter (leia a
   opção CORRETA no prompt relido no passo 1 — não assuma sempre '1').
   SE o diálogo JÁ NÃO estiver lá (a sessão pode ter avançado sozinha, ou
   já foi destravada por outra via): NÃO envie tecla às cegas — sem diálogo
   pendente, nudge é a ferramenta certa e não-destrutiva; use gc session
   nudge normalmente.
3. Depois de destravar via tecla (ramo 2 acima): se esta regra de permissão
   alcança sessões de pool não-supervisionadas, considere virar
   "deny"/"allow" — nunca "ask" (ga-q640n/AC3).

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2 · permission-prompt: ga-iog1v/ga-q640n · reconfirmação: ga-swmbf)
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
    # --include-infra (ga-vm20x, Mayor 07/08): same gap as
    # gate_reviewer_permission_prompt_session above — gate markers are born
    # --ephemeral (INFRA) and hidden from `bd list` by default. Without this
    # flag a bead with a genuinely open gate marker reads as having none, so
    # this helper's whole purpose — suppressing a stall escalation for a
    # bead that's actually fine, just sitting in the gate — never fires,
    # and the caller escalates a false-positive "stuck" report instead.
    arts="$(timeout 15 "$BD" -C "$CITY" list --include-infra -l "source-bead:$bid" --json 2>/dev/null || true)"
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

# now_outside_active_window (ga-nrkh92, critério f): um bead pode declarar,
# via metadata "gc.active_window" = "HH:MM-HH:MM" (hora local da máquina,
# tolera virada de meia-noite), a janela em que sua ociosidade é ESPERADA e
# correta — fora dela, ociosidade NÃO é sinal de travamento e este daemon
# não deve nem tentar retomar nem escalar. Sem essa metadata (o caso default
# hoje — nenhum bead na cidade declara isso ainda), a checagem sempre
# retorna "dentro da janela" (nunca suprime). Concreto: wa-x92yd só pode
# medir aparelho 20:00-07:00; o Mayor mediu, no próprio dia deste bead, que
# acordar um agente assim fora da janela é PIOR que não fazer nada (empurra
# o agente a mexer em aparelho durante campanha real de envio).
#
# Formato inválido (digitado errado) FAIL-OPEN pra "dentro da janela" —
# nunca suprime por um erro de digitação silencioso.
#
#   0 = FORA da janela declarada (ociosidade esperada — não agir)
#   1 = dentro da janela (ou sem janela declarada, ou formato inválido)
now_outside_active_window() {
    local window="$1" start_hm end_hm cur_hm start_min end_min cur_min
    [ -z "$window" ] && return 1
    case "$window" in
        [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;;
        *) return 1 ;;
    esac
    start_hm="${window%-*}"; end_hm="${window#*-}"
    # ga-nrkh92 gate-fix (blocking issue 2): the case pattern above bounds
    # each hour DIGIT independently ([0-2][0-9] accepts 20-29, not just
    # 00-23). A window entirely past 23:59 (e.g. "24:30-25:00") passes that
    # check but cur_min (from the real clock, always 0-1439) can never
    # satisfy the in-window test below — this function would then ALWAYS
    # return "outside", permanently suppressing both resume and escalation
    # for that bead, the opposite of the fail-OPEN contract documented
    # above. Bound the parsed hour values explicitly; fail-open (return 1)
    # on violation, same as any other malformed window.
    if [ "$((10#${start_hm%%:*}))" -gt 23 ] || [ "$((10#${end_hm%%:*}))" -gt 23 ]; then
        return 1
    fi
    start_min=$(( 10#${start_hm%%:*} * 60 + 10#${start_hm##*:} ))
    end_min=$(( 10#${end_hm%%:*} * 60 + 10#${end_hm##*:} ))
    # ga-nrkh92 gate-fix attempt 3: start_min == end_min (e.g. "10:00-10:00",
    # "00:00-00:00") is a degenerate-but-validly-formatted zero-width window —
    # same failure mode as the out-of-range-hour case above, different
    # trigger. The <= branch below requires cur_min >= start_min AND
    # cur_min < end_min, which is unsatisfiable for any cur_min when the two
    # are equal, so the function would silently and permanently return
    # "outside" for every call — the opposite of the fail-OPEN contract
    # documented above. Resolve it the same way as the hour-bound case: fail
    # open.
    if [ "$start_min" -eq "$end_min" ]; then
        return 1
    fi
    cur_hm="$(date +%H:%M)"
    cur_min=$(( 10#${cur_hm%%:*} * 60 + 10#${cur_hm##*:} ))
    if [ "$start_min" -le "$end_min" ]; then
        [ "$cur_min" -ge "$start_min" ] && [ "$cur_min" -lt "$end_min" ] && return 1
        return 0
    else
        # janela cruza meia-noite (ex.: 20:00-07:00)
        { [ "$cur_min" -ge "$start_min" ] || [ "$cur_min" -lt "$end_min" ]; } && return 1
        return 0
    fi
}

# pane_pid_for_session / pane_cpu_time_secs / pane_truly_idle (ga-nrkh92,
# critério b): nenhum comando `gc` expõe o PID do pane de uma sessão
# (levantado — gc session list/peek não trazem PID); resolve via tmux
# diretamente. Usado SÓ pra corroborar ociosidade real antes de mandar uma
# retomada: %cpu do `ps` é MÉDIA da vida do processo — num processo de
# horas, atividade recente desaparece na média (medido ao vivo pelo Mayor:
# os 3 painéis marcavam 0.0% mesmo DEPOIS de retomarem). TIME acumulado,
# amostrado 2x com IDLE_CPU_SAMPLE_SEC de intervalo, é o discriminador que
# funcionou (confirmado: 1-2s de CPU em 25s quando os painéis retomaram).
pane_pid_for_session() {
    local sess="$1" pid
    pid="$(timeout 10 "$TMUX" list-panes -t "$sess" -F '#{pane_pid}' 2>/dev/null | head -1)"
    [ -z "$pid" ] && return 1
    printf '%s' "$pid"
}

# pane_cpu_time_secs (ga-nrkh92 gate-fix, blocking issue 1): returns
# CENTISECONDS (not whole seconds). `ps -o time=` reports M:SS.ss precision
# (confirmed live on this machine — e.g. "0:00.00", "30:13.66") — the
# original version parsed that correctly but then did print(int(secs)),
# throwing the fraction away before the value ever left the function.
# pane_truly_idle()'s own justification cites a real measurement of ~4-8%
# duty cycle for a genuinely-busy pane (1-2s of CPU across a 25s sample);
# at the shipped IDLE_CPU_SAMPLE_SEC default of 5s that predicts only
# ~0.2-0.4s of real accumulated CPU per sample — which the old
# whole-second truncation had a measured 60-80% chance of losing entirely
# (both samples truncating to the same integer second), reading a
# genuinely-working pane as "idle" and firing send_idle_resume()'s tmux
# send-keys into a live session on a false premise. Comparing centiseconds
# instead of truncated seconds needs the real delta to be below 0.01s
# (i.e. no meaningful work happened) before two samples can read equal.
pane_cpu_time_secs() {
    local pid="$1" raw
    raw="$(ps -o time= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [ -z "$raw" ] && return 1
    python3 -c "
parts = '$raw'.split(':')
try:
    parts = [float(p) for p in parts]
except Exception:
    raise SystemExit(1)
secs = 0.0
for p in parts:
    secs = secs * 60 + p
print(int(round(secs * 100)))
" 2>/dev/null
}

#   0 = ocioso CONFIRMADO (TIME idêntico nas 2 amostras)
#   1 = NÃO ocioso CONFIRMADO (TIME mudou entre as 2 amostras)
#   2 = DESCONHECIDO (PID não resolvido via tmux, ou `ps` falhou) — NUNCA
#       deve travar a retomada. Mesma direção tri-state que
#       transcript_is_advancing()/tokens_rising_or_first_sample() já usam
#       neste arquivo (pergunta que falha nunca vira veredito confirmado),
#       mas aplicada ao INVERSO aqui de propósito: quem chama esta função
#       já chegou até este ponto porque 7 camadas anteriores CONFIRMARAM
#       travamento real — este check é só uma corroboração ADICIONAL pro
#       caso de computação silenciosa (critério b do bead), e sua própria
#       falha não pode desfazer um veredito que já estava estabelecido. Se
#       "desconhecido" suprimisse aqui, qualquer falha de resolução de PID
#       (tmux ausente, nome de sessão não-tmux, etc.) desligaria retomada E
#       escalação silenciosamente pra sempre nesse bead — pior que o
#       comportamento de antes desta mudança, que sempre acabava escalando.
pane_truly_idle() {
    local sess="$1" pid t1 t2
    pid="$(pane_pid_for_session "$sess")" || return 2
    t1="$(pane_cpu_time_secs "$pid")" || return 2
    sleep "$IDLE_CPU_SAMPLE_SEC"
    t2="$(pane_cpu_time_secs "$pid")" || return 2
    [ "$t2" -eq "$t1" ] && return 0
    return 1
}

# session_work_dir (ga-nrkh92): resolve session_name -> work_dir a partir do
# MESMO `gc session list --json` já buscado nesta passada (TMP_SESS) — sem
# spawnar `gc` de novo. Usado só por has_unique_work() abaixo.
session_work_dir() {
    local sess="$1"
    [ -n "${TMP_SESS:-}" ] && [ -f "$TMP_SESS" ] || return 1
    python3 - "$TMP_SESS" "$sess" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    target = sys.argv[2]
    for s in (data.get("sessions") or []):
        for field in ("session_name", "name", "alias", "id"):
            if (s.get(field) or "") == target:
                print(s.get("work_dir") or "")
                raise SystemExit(0)
except Exception:
    pass
PY
}

# has_unique_work (ga-nrkh92, critério e — ver memória
# branch-not-merged-is-not-proof-of-pending-work-use-git-cherry): antes de
# alegar "trabalho em risco" numa escalação, prova via patch-id (git
# cherry), NUNCA via ref-não-mergeada — uma branch pode aparecer
# não-mergeada e mesmo assim ter TODO o conteúdo em main via outro
# commit/fatia (medido ao vivo no próprio dia deste bead, wa-x92yd: o
# Mayor citou "branch não mergeada" como prova de risco quando `git cherry`
# devolvia só "-", ou seja, casca vazia). Conta linhas "+" (commit cujo
# patch-id está AUSENTE de origin/main = único); "-" já está em main por
# outro caminho, não conta.
#
# Falha (não é repo git, sem origin/main, timeout, ...) → nada impresso,
# rc=1 — quem chama trata como "não determinado", nunca como "sem risco"
# nem "com risco": omite a alegação, não afirma nenhum dos dois lados.
has_unique_work() {
    local work_dir="$1" out
    [ -n "$work_dir" ] && [ -d "$work_dir" ] || return 1
    out="$(timeout 20 "$GIT" -C "$work_dir" cherry origin/main HEAD 2>/dev/null)" || return 1
    printf '%s\n' "$out" | grep -c '^+' || true
}

# send_idle_resume (ga-nrkh92): tenta acordar uma sessão ociosa pelo canal
# interativo. `gc session nudge` primeiro (canal padrão da cidade — é o que
# o próprio mol-shutdown-dance usa pros seus health-checks) E, também
# (não como fallback condicional: a ÚNICA evidência empírica que este bead
# traz — medida pelo Mayor no mesmo dia, contra os 3 casos reais do
# incidente — é que `tmux send-keys` acordou 3/3; `gc session nudge` nunca
# foi validado para ESTE caso específico de prompt-vazio-limpo, só se sabe
# que ele FALHA quando há um diálogo de permissão bloqueando, caso
# diferente já tratado por pane_shows_permission_prompt acima), injeta
# também via tmux diretamente — texto e Enter em DUAS chamadas SEPARADAS
# (send-keys sem Enter só digita, não envia — ver build_permission_prompt_body
# acima, mesma doutrina). Belt-and-suspenders barato: nudge não tem efeito
# colateral negativo se redundante, e dá rastreamento via
# last_nudge_delivered_at no `gc session list`.
send_idle_resume() {
    local sess="$1" msg="$2"
    timeout 15 "$GC" session nudge "$sess" "$msg" >/dev/null 2>&1 || true
    if timeout 10 "$TMUX" has-session -t "$sess" 2>/dev/null; then
        timeout 10 "$TMUX" send-keys -t "$sess" -- "$msg" 2>/dev/null || true
        timeout 10 "$TMUX" send-keys -t "$sess" Enter 2>/dev/null || true
    fi
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
trap 'rm -f "$TMP_SESS"' EXIT
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
# ga-nrkh92: NÃO apaga $TMP_SESS aqui (mudança do comportamento original) —
# session_work_dir() precisa reconsultar o mesmo JSON mais adiante, na
# escalação por falta de resposta à retomada, pra resolver work_dir sem
# spawnar `gc session list` de novo.
#
# ga-nrkh92 gate-fix (blocking issue, attempt 4): a versão original deste
# comentário dizia "removido no fim do script" — falso pros passes comuns.
# O `rm -f "$TMP_SESS"` que existia so' rodava DEPOIS do loop por bead
# (apos "done <<< $STUCK_ITEMS"), mas o bloco pre-existente e inalterado
# `if [ -z "$STUCK_ITEMS" ]; then ...; exit 0; fi` fica ENTRE a criacao de
# $TMP_SESS e essa limpeza — e sai primeiro. Todo pass sem bead travado (o
# estado saudavel comum, que este daemon de StartInterval=300s bate
# rotineiramente) vazava o arquivo do mktemp, indefinidamente. O
# `trap ... EXIT` logo acima cobre esse caminho e qualquer outro exit
# futuro apos este ponto — sem precisar enumerar cada um a mao.

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
    # ga-nrkh92 (critério f): metadata declarada de janela de operação —
    # sanitizada como title (sem "|"/newline), vazio se ausente/não-string.
    meta = b.get("metadata") or {}
    aw = meta.get("gc.active_window") if isinstance(meta, dict) else None
    active_window = str(aw or "").replace("|", "_").replace("\n", " ")
    print("stuck|%s|%s|%d|%s|%s|%s" % (bead_id, assignee, int(age), title, labels_str, active_window))
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

# GC (ga-0xmxt): same cleanup for the per-bead token-sample state — a bead
# that closes or advances shouldn't leave its last-seen-token-count file
# behind forever.
for tf in "$TOKDIR"/*; do
    [ -f "$tf" ] || continue
    bn="$(basename "$tf")"
    if ! printf '%s' " $ALL_INPROGRESS_IDS " | grep -qF " $bn "; then
        rm -f "$tf"
    fi
done

# GC (ga-nrkh92): same cleanup for the per-bead idle-resume state — a bead
# that closes or advances shouldn't leave a stale "nudged at T" marker
# behind for a future, unrelated stuck episode to misread as already-nudged.
for rf in "$RESUMEDIR"/*; do
    [ -f "$rf" ] || continue
    bn="$(basename "$rf")"
    if ! printf '%s' " $ALL_INPROGRESS_IDS " | grep -qF " $bn "; then
        rm -f "$rf"
    fi
done

if [ -z "$STUCK_ITEMS" ]; then
    log "no stuck beads (all in_progress beads updated within ${STUCK_AGENT_SEC}s)"
    exit 0
fi

# ── Process each stuck bead ───────────────────────────────────────────────────
while IFS='|' read -r bead_id assignee age_secs title labels active_window; do
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
            gate_observed_at="$(date '+%Y-%m-%d %H:%M:%S')"
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
            gate_body="$(build_permission_prompt_body "$bead_id" "$title" "(bead sem assignee — EM GATE; reviewer=$gate_reviewer_sess)" "$gate_reviewer_sess" "$gate_blocked_cmd" "$age_min" "$gate_failure_markers" "$gate_observed_at")"
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
        # ga-nrkh92: se havia um nudge de retomada pendente pra este bead, o
        # transcript voltando a avançar É a prova de que funcionou — limpa o
        # estado pra um episódio de ociosidade FUTURO começar do zero (não
        # pular direto pra "grace esgotado" com um nudged_at velho).
        if [ -f "$RESUMEDIR/$bead_id" ]; then
            log "$bead_id: transcript voltou a avançar após retomada — RESOLVIDO (ga-nrkh92), limpando estado de retomada"
            rm -f "$RESUMEDIR/$bead_id"
        fi
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

    # ga-0xmxt: transcript CONFIRMED frozen + session alive is STILL not
    # proof of a hang when the turn itself is simply LONG — see the header
    # doc (item 7) and the two helper functions above for the full
    # rationale. Two independent, externally-observable signals, checked in
    # order: (a) a tool call is actively in flight; (b) the CLI's streaming
    # token counter is present and CHANGED since the last sample — rose OR
    # fell, since a fall can legitimately happen when the pane's last line
    # switches from the main turn's counter to an active subagent's own
    # counter (gate fix-attempt-2) — or this is the first sample ever taken
    # for this bead — one grace pass.
    if [ "$transcript_state" = "frozen" ] && [ -n "$live_session_name" ]; then
        if pane_shows_active_child_process "$live_session_name"; then
            log "$bead_id: bead.updated_at parado ${age_min}min — transcript de $live_session_name CONGELADO mas pane confirma processo filho ativo (shell/tool em execução) — SUPRIMINDO escalação (fail-safe ga-0xmxt: meio de turno)"
            continue
        fi
        _tok="$(pane_extract_token_count "$live_session_name" 2>/dev/null || true)"
        if [ -n "$_tok" ] && tokens_rising_or_first_sample "$bead_id" "$_tok"; then
            log "$bead_id: bead.updated_at parado ${age_min}min — transcript de $live_session_name CONGELADO mas contador de tokens do pane em ${_tok}k (mudou desde a última amostra — subiu ou desceu —, ou primeira amostra) — SUPRIMINDO escalação (fail-safe ga-0xmxt: meio de turno)"
            continue
        fi
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
    observed_at=""
    if [ "$transcript_state" = "frozen" ] && [ -n "$live_session_name" ] && pane_shows_permission_prompt "$live_session_name"; then
        permission_prompt_detected=1
        observed_at="$(date '+%Y-%m-%d %H:%M:%S')"
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
        # Inalterado (ga-iog1v/ga-q640n): diálogo de permissão tem remédio
        # próprio (1 tecla), já documentado na própria mensagem — não é o
        # caso "ocioso, precisa de retomada" que ga-nrkh92 endereça abaixo.
        log "$bead_id: BLOQUEADO-EM-PROMPT ${age_min}min — assignee=$assignee sess=$sess_status comando=[$blocked_cmd] labels=$labels"
        body="$(build_permission_prompt_body "$bead_id" "$title" "$assignee" "$live_session_name" "$blocked_cmd" "$age_min" "$failure_markers" "$observed_at")"
        send_escalation "$bead_id" "$title" "$labels" "$age_min" "$assignee" "1" "Agente BLOQUEADO EM PROMPT (1 tecla resolve)" "$body" "$sf"
        continue
    fi

    log "$bead_id: STUCK ${age_min}min — assignee=$assignee sess=$sess_status transcript=$transcript_note labels=$labels"

    # ga-nrkh92: sem sessão viva pra retomar (assignee confirmado
    # ausente/morto, não apenas ocioso) — não há pane pra acordar. Escala
    # direto, comportamento IDÊNTICO ao de antes desta mudança.
    if [ -z "$live_session_name" ]; then
        body="$(cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: bead in_progress sem ESCRITA detectada há
${age_min}min. Isto NÃO é confirmação de travamento — pode ser falso
positivo (raciocínio longo, subagente ativo) que os sinais automáticos
disponíveis nesta passada não conseguiram provar nem descartar. CONFIRME
antes de agir.

Bead:      $bead_id — $title
Assignee:  ${assignee:-'(não atribuído)'}
Sem update há: ${age_min} minutos (limiar: $(( STUCK_AGENT_SEC / 60 )) min)
Sessão:    $sess_status
Transcript: $transcript_note
Marcadores de falha: $failure_markers

Nenhuma sessão viva encontrada — não há pane pra tentar retomada automática
(ga-nrkh92); o assignee está ausente/morto, não apenas ocioso.

AÇÃO SUGERIDA (nesta ordem — passo 1 é obrigatório antes de qualquer ação destrutiva):
1. gc session peek ${assignee:-<assignee>} — confirme se realmente travado ou só lento/em turno longo
2. gc bd show $bead_id — veja estado atual do bead
3. SÓ DEPOIS de confirmar no passo 1 que não há atividade real: shutdown-dance (3 nudges via dog pool) ou kill+re-despache. Matar uma sessão ativa descarta o raciocínio e o contexto já carregados.
4. Se misroute: circuit-break (gate:needs-human) e reassinalação ao dono correto
5. Se bead avançou mas updated_at não se moveu: update manual para parar alertas

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2 · falso-positivo de turno longo: ga-0xmxt)
BODY
)"
        send_escalation "$bead_id" "$title" "$labels" "$age_min" "$assignee" "0" "Agente travado" "$body" "$sf"
        continue
    fi

    # ga-nrkh92, critério f: janela de operação declarada — fora dela,
    # ociosidade é esperada e correta. Checado só aqui (ponto em que uma
    # AÇÃO seria tomada), não repetido a cada ciclo de espera. Limitação
    # conhecida e aceita: se a janela FECHAR entre o nudge e o fim do
    # prazo, a re-abertura pode ler um nudged_at velho como "sem resposta"
    # — sem custo real hoje porque nenhum bead na cidade usa esta metadata
    # ainda (levantamento em ga-nrkh92).
    if now_outside_active_window "$active_window"; then
        log "$bead_id: fora da janela de operação declarada ($active_window) — ociosidade esperada, NÃO retomando nem escalando (ga-nrkh92 critério f)"
        continue
    fi

    # ga-nrkh92, critério b: corrobora ociosidade REAL via TIME acumulado do
    # pane antes de mandar qualquer retomada — %cpu não discrimina (é média
    # da vida do processo); TIME sim. As camadas 1-7 acima já cobrem os
    # sinais VISÍVEIS (indicador "Running…", contador de tokens); esta
    # camada cobre o computation silencioso que não deixa nenhum dos dois.
    pane_truly_idle "$live_session_name"
    _pti_rc=$?
    if [ "$_pti_rc" = "1" ]; then
        log "$bead_id: transcript CONGELADO mas TIME acumulado do pane mudou durante amostragem (${IDLE_CPU_SAMPLE_SEC}s) — SUPRIMINDO retomada/escalação (fail-safe ga-nrkh92: %cpu não discrimina, TIME sim)"
        continue
    fi
    # _pti_rc==0 (ocioso confirmado) OU ==2 (PID não resolvido/desconhecido)
    # seguem ambos em frente — ver docstring de pane_truly_idle() acima
    # pro porquê de "desconhecido" NÃO suprimir aqui.

    rf="$RESUMEDIR/$bead_id"
    nudged_at=""
    nudged_session=""
    if [ -f "$rf" ]; then
        nudged_at="$(sed -n '1p' "$rf" 2>/dev/null || echo "")"
        nudged_session="$(sed -n '2p' "$rf" 2>/dev/null || echo "")"
    fi

    # ga-nrkh92 gate-fix (blocking issue 1): $rf is keyed only by bead_id —
    # if this bead was reassigned to a DIFFERENT live session while it
    # stayed in_progress (kill+re-despache, or a pool-slot respawn under a
    # reused name — dog-pool-slot-inherits-prior-incarnation-work), a nudge
    # recorded for the OLD session is not evidence the NEW session was ever
    # nudged. Reading it as such would let the grace clock start before the
    # new session's very first idle observation, escalating immediately
    # without this daemon ever attempting to wake it — silently defeating
    # ga-nrkh92's whole purpose for exactly the beads that already needed
    # one manual intervention. A missing/blank nudged_session (an
    # old-format single-line $rf, e.g. written before this fix) is NOT
    # treated as a mismatch — there is no evidence of reassignment either
    # way, so it falls through to the pre-existing elapsed-time check
    # unchanged.
    if [ -n "$nudged_at" ] && [ -n "$nudged_session" ] && [ "$nudged_session" != "$live_session_name" ]; then
        log "$bead_id: retomada anterior registrada p/ sessao '$nudged_session', atual e '$live_session_name' — bead foi reatribuido; tratando como primeira retomada pra esta sessao (ga-nrkh92 gate-fix, issue 1)"
        nudged_at=""
    fi

    if [ -z "$nudged_at" ]; then
        # Primeira vez vendo este bead ocioso nesta janela (ou reatribuído
        # p/ nova sessão, acima) — tenta acordar pelo canal interativo,
        # ainda NÃO escala.
        resume_msg="[AUTO-RESUME] Ocioso ha ${age_min}min com bead ${bead_id} in_progress. ANTES de agir: rode 'bd show ${bead_id}', releia seus ultimos comentarios e o git log/estado da branch, e reporte em 1-2 linhas onde parou e o que falta — nao refaca se ja estiver completo (aguardando gate/merge conta como completo)."
        # ga-nrkh92: cada ramo loga só o que REALMENTE aconteceu nele — um
        # log incondicional de "RETOMADA enviada" depois do if/else afirmaria
        # envio real mesmo em DRY_RUN, onde send_idle_resume nunca roda
        # (mesma classe de defeito que o self-audit deste gate existe pra
        # pegar: comentário/log prometendo mais do que o código ao lado faz).
        #
        # ga-nrkh92 gate-fix (attempt 5): a mesma disciplina vale pro
        # ARQUIVO de estado, não só pro log — e aqui o preço de errar é
        # maior. Até esta correção, o printf abaixo ficava FORA do
        # if/else, gravando $rf mesmo em DRY_RUN. Um preview (DRY_RUN=1,
        # "sem retomada real via tmux" por doutrina) deixava rastro
        # persistente de um nudge que nunca saiu; um pass REAL seguinte
        # pra esse mesmo bead+sessão lia esse nudged_at como genuíno (o
        # guard de reatribuição não pega isso — mesma sessão, sem
        # mismatch), e ao esgotar RESUME_GRACE_SEC escalava pro Mayor
        # afirmando "o daemon já tentou acordar esta sessão" — falso,
        # nenhuma retomada real foi enviada. Grava $rf só no ramo que
        # realmente tentou (else), como o log já fazia.
        if [ "$DRY_RUN" = "1" ]; then
            log "$bead_id: [DRY_RUN] retomada NÃO enviada de verdade — teria chamado gc session nudge + tmux send-keys pra $live_session_name (ga-nrkh92)"
        else
            send_idle_resume "$live_session_name" "$resume_msg"
            log "$bead_id: RETOMADA enviada a $live_session_name (nudge + tmux send-keys) — aguardando resposta até ${RESUME_GRACE_SEC}s (ga-nrkh92)"
            printf '%s\n%s\n' "$now" "$live_session_name" > "$rf"
        fi
        continue
    fi

    elapsed_since_nudge=$(( now - nudged_at ))
    if [ "$elapsed_since_nudge" -lt "$RESUME_GRACE_SEC" ]; then
        log "$bead_id: retomada enviada há ${elapsed_since_nudge}s — aguardando resposta (prazo ${RESUME_GRACE_SEC}s, ga-nrkh92)"
        continue
    fi

    # Prazo esgotado e o transcript CONTINUA congelado (senão o bloco
    # transcript_state=="advancing" acima já teria suprimido antes de
    # chegar aqui, e limpo este mesmo $rf) — a retomada não funcionou.
    # Escala UMA vez: send_escalation grava $sf, e o cooldown no TOPO do
    # loop (linhas ~979-988) impede reescalar nos próximos ciclos até
    # COOLDOWN_SEC — não precisa de um segundo flag "escalated" aqui.
    unique_note="não determinado (sem acesso ao worktree da sessão)"
    _wd="$(session_work_dir "$live_session_name" 2>/dev/null || true)"
    if [ -n "$_wd" ]; then
        _n="$(has_unique_work "$_wd" 2>/dev/null || true)"
        case "$_n" in
            ''|*[!0-9]*) : ;;  # não determinado — não afirma nenhum dos dois lados (critério e)
            0) unique_note="nenhum — HEAD já está inteiramente em origin/main (git cherry por patch-id, não por ref não-mergeada)" ;;
            *) unique_note="${_n} commit(s) só nesta sessão (git cherry origin/main HEAD) — NÃO estão em origin/main ainda" ;;
        esac
    fi
    body="$(cat <<BODY
CAMADA 2 — ESCALAÇÃO AUTOMÁTICA: agente ocioso não respondeu à retomada
automática (ga-nrkh92).

Bead:      $bead_id — $title
Assignee:  $assignee
Sessão:    $live_session_name
Ocioso há: ${age_min} minutos
Retomada enviada há: $(( elapsed_since_nudge / 60 )) minutos (gc session nudge + tmux send-keys, sem resposta)
Trabalho não mergeado: $unique_note
Marcadores de falha: $failure_markers

O daemon já tentou acordar esta sessão sozinho (canal interativo — nudge +
tecla direta no pane) e ela não reagiu no prazo. Isto é DIFERENTE de um
alerta genérico: já foi dada a chance de responder antes de qualquer
sugestão destrutiva.

AÇÃO SUGERIDA:
1. gc session peek $live_session_name --lines 60 — confira o estado atual do pane
2. Se ainda ocioso: shutdown-dance (3 nudges via dog pool) ou kill+re-despache
3. Se working mas devagar (turno realmente longo que escapou das camadas de supressão): bd comment $bead_id pra reduzir ruído futuro

Limiar configurável via STUCK_AGENT_SEC (atual: ${STUCK_AGENT_SEC}s) · retomada: RESUME_GRACE_SEC (atual: ${RESUME_GRACE_SEC}s).
(Daemon: agent-stuck-escalation · ga-qw3p.2 · retomada automática: ga-nrkh92)
BODY
)"
    send_escalation "$bead_id" "$title" "$labels" "$age_min" "$assignee" "0" "Agente ocioso nao respondeu a retomada" "$body" "$sf"
    # ga-nrkh92 gate-fix (blocking issue 2): $rf ficava intocado apos esta
    # escalacao. Os dois unicos outros pontos que o limpam (GC no topo do
    # pass, e o ramo "transcript voltou a avancar") nunca rodam aqui — se o
    # transcript tivesse voltado a avancar, o bloco correspondente acima ja
    # teria dado `continue` bem antes deste ponto. Sem isso, um bead preso
    # por MAIS de um COOLDOWN_SEC (3h — o proprio cenario que originou este
    # bead: "3 crews travadas 7-13h", 2-4 janelas de cooldown) tinha cada
    # escalacao APOS a primeira pulando send_idle_resume: o cooldown suprime
    # reavaliacao por 3h; quando o bead reaparece, elapsed_since_nudge ja
    # esta horas alem de RESUME_GRACE_SEC, e escala de novo sem NUNCA tentar
    # retomar de novo — revertendo pro comportamento pre-ga-nrkh92 ("so
    # mail") em toda escalacao apos a primeira, o oposto do proposito do
    # bead. Limpar aqui faz a proxima reavaliacao (apos o cooldown) cair de
    # volta no ramo de primeira retomada — cada ciclo de escalacao ganha sua
    # propria tentativa de retomada fresca.
    rm -f "$rf"

done <<< "$STUCK_ITEMS"

log "=== pass complete ==="
exit 0
