#!/usr/bin/env bash
# disk-recovery-swap-cut.selftest.sh — testa o degrau de SWAP (ga-yh41v0e) da escada de disco SEM tocar na máquina.
#
# ## Contents
#   Simulado · Seções · Como rodar
#
# SIMULADO  o swap (DR_SWAP_MB_FILE), o relógio (DR_NOW_FILE), o arquivo do amostrador (JSONL escrito pelo teste, com swap subindo), o amostrador (script de mentira que acrescenta o registro que o teste mandou, ou falha),
#   o roster `gc session list --json` (arquivo; o `gc` de mentira muda o estado dele em suspend e DIMINUI o swap a cada suspend, como se a memória voltasse), as transcrições (arquivos com mtime escolhido), o `bd`
#   (in_progress por identidade e por store; falha por modo; aviso no stderr; anexa/escreve na sessão DURANTE a leitura). Nada real é suspenso, lido ou gravado fora de $W.
# SEÇÕES    gatilho (crescimento · absoluto · histórico curto · sem gatilho) · o corte (só candidata permitida; ordem; teto; nunca dolt/daemon/crew/dog/anexada/in_progress/transcrição recente ou desconhecida/estado) ·
#   o log (quem foi cortado, quanto de swap voltou) · a pausa do Pilot (arquivo, validade, leitura de volta, renovação) · TERCEIRO ESTADO (amostrador ausente/velho/corrompido/sem atribuição/roster ilegível: NÃO corta, NÃO
#   pausa, rc 30, avisa) · sem candidata (rc 11) · suspend com rc != 0 e a sessão ativa (rc 20) · suspend NÃO CONFIRMADO (atraso do reconciler, nunca muda, some da lista) · registro no disco antes do settle · releitura
#   imediatamente antes do suspend (anexada, transcrição) · stderr do bd/gc · loja do rig · uma linha, um \n · pausa (validade absurda, mantida) · carência · dry-run · interruptor · trava · variáveis · estática (sem kill -9/pkill -f/Appium)
# COMO RODAR  bash scripts/disk-recovery-swap-cut.selftest.sh   ·   outro executável: SWC_ST_SUT=<arquivo>   ·   SWC_ST_FAILFAST=1 sai no 1º FAIL
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SWC_ST_SUT:-$HERE/disk-recovery-swap-cut.sh}"
[ -f "$SUT" ] || { echo "FATAL: degrau não encontrado em $SUT"; exit 1; }
for _v in $(compgen -e | grep '^DR_'); do unset "$_v"; done
W="$(mktemp -d "${TMPDIR:-/tmp}/swc-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
case "$W" in */swc-selftest.??????) ;; *) echo "FATAL: diretório de trabalho estranho: $W"; exit 1 ;; esac
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin"
PASS=0; FAIL=0; OUT=""; ERR=""; RC=0; NOW=1000000
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "$OUT" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | tail -n 8; [ "${SWC_ST_FAILFAST:-0}" = 1 ] && { echo "(FAILFAST) $PASS ok, $FAIL FAIL"; exit 1; }; return 0; }
eq()    { if [ "$1" = "$2" ]; then ok "$3"; else nope "$3 (obtido '$1', esperado '$2')"; fi; }
has()   { case "$1" in *"$2"*) ok "$3" ;; *) nope "$3 (faltou: $2)" ;; esac; }
hasnt() { case "$1" in *"$2"*) nope "$3 (não devia ter: $2)" ;; *) ok "$3" ;; esac; }
section() { printf '\n== %s\n' "$1"; }

C="$W/city"; GCD="$C/.gc"
SWAPF="$W/swap"; NOWF="$W/now"; SAMPLES="$GCD/ram-owner-samples.jsonl"; NEXT="$W/next-rec"; ROSTER="$W/roster.json"; CALLS="$W/gc.calls"; SCALLS="$W/sampler.calls"
LOGF="$GCD/logs/disk-recovery-swap-cut.log"; PAUSEF="$GCD/swap-spawn-pause"; STATEF="$GCD/disk-recovery-swap-cut.state"; PROJ="$W/projects"

# gc de mentira: suspend → roster ganha state=asleep e o swap CAI (W_SWAP_DROP, padrão 300); list → o roster. Modos em $W/mode: suspend.fail, suspend.noop, list.fail
cat > "$W/bin/gc" <<'STUB'
#!/bin/bash
echo "$*" >> "$W_CALLS"
setstate() { python3 -I -c '
import json, sys
p, i, st = sys.argv[1:4]
d = json.load(open(p))
for s in d["sessions"]:
    if s["id"] == i:
        s["state"] = st
json.dump(d, open(p, "w"))
' "$W_ROSTER" "$1" "$2"; }
case "$1 $2" in
  "session suspend") [ -e "$W_MODE/suspend.fail" ] && { echo "suspend: boom" >&2; exit 1; }
                     [ -e "$W_MODE/suspend.noop" ] && exit 0
                     [ -e "$W_MODE/suspend.lag" ] && { ( sleep 1; setstate "$3" asleep ) > /dev/null 2>&1 & exit 0; }   # rc 0 e o estado só muda 1 s depois: o reconciler atrasado
                     [ -e "$W_MODE/suspend.gone" ] && { python3 -I -c '
import json, sys
p, i = sys.argv[1:3]
d = json.load(open(p))
d["sessions"] = [s for s in d["sessions"] if s["id"] != i]
json.dump(d, open(p, "w"))
' "$W_ROSTER" "$3"; exit 0; }
                     setstate "$3" asleep
                     v=$(cat "$W_SWAP"); echo $((v - ${W_SWAP_DROP:-300})) > "$W_SWAP"; exit 0 ;;
  "session list")    [ -e "$W_MODE/list.fail" ] && exit 1
                     [ -e "$W_MODE/gc.warn" ] && echo "warning: builtin pack differs from the embedded copy" >&2
                     cat "$W_ROSTER" ;;
  *) exit 0 ;;
esac
STUB
# bd de mentira: `bd -C <store> list --status in_progress --assignee <ident> --json --limit 0` → $W/bd/<basename do store>/<ident> (JSON) ou []. Modos: bd.fail (tudo), bd.fail.<ident>, bd.warn (aviso no stderr com rc 0),
# bd.attach.<ident> (o arquivo diz o id da sessão: ela fica ANEXADA durante esta leitura), bd.touch.<ident> (o arquivo diz a transcrição que passa a ter escrita agora). Cada chamada vai para $W_BDCALLS
cat > "$W/bin/bd" <<'STUB'
#!/bin/bash
store=""; ident=""
while [ $# -gt 0 ]; do case "$1" in -C) store=$2; shift ;; --assignee) ident=$2; shift ;; esac; shift; done
echo "$(basename "$store") $ident" >> "$W_BDCALLS"
[ -e "$W_MODE/bd.fail" ] && { echo "bd: boom" >&2; exit 1; }
[ -e "$W_MODE/bd.fail.$ident" ] && { echo "bd: boom" >&2; exit 1; }
[ -e "$W_MODE/bd.warn" ] && echo "warning: builtin pack differs from the embedded copy" >&2
[ -e "$W_MODE/bd.touch.$ident" ] && touch "$(cat "$W_MODE/bd.touch.$ident")"
[ -e "$W_MODE/bd.attach.$ident" ] && python3 -I -c '
import json, sys
p, i = sys.argv[1:3]
d = json.load(open(p))
for s in d["sessions"]:
    if s["id"] == i:
        s["attached"] = True
json.dump(d, open(p, "w"))
' "$W_ROSTER" "$(cat "$W_MODE/bd.attach.$ident")"
f="$W_BD/$(basename "$store")/$ident"
if [ -e "$f" ]; then cat "$f"; else echo '[]'; fi
STUB
# amostrador de mentira: acrescenta $W/next-rec ao arquivo (RAM_OWNER_OUT); sem next-rec → falha (rc 1)
cat > "$W/bin/sampler" <<'STUB'
#!/bin/bash
echo "x" >> "$W_SCALLS"
[ -e "$W_NEXT" ] || { echo "sampler: boom" >&2; exit 1; }
cat "$W_NEXT" >> "$RAM_OWNER_OUT"
STUB
chmod +x "$W/bin/gc" "$W/bin/bd" "$W/bin/sampler"
export W_CALLS="$CALLS" W_ROSTER="$ROSTER" W_SWAP="$SWAPF" W_MODE="$W/mode" W_BD="$W/bd" W_NEXT="$NEXT" W_SCALLS="$SCALLS" W_BDCALLS="$W/bd.calls"

reset() {
  rm -rf "$C" "$W/mode" "$W/bd" "$PROJ" "$W/wd" "$ROSTER" "$NEXT" "$W/roster.tsv" "$W/err"
  mkdir -p "$GCD/logs" "$W/mode" "$W/bd/city" "$PROJ"
  : > "$CALLS"; : > "$SCALLS"; : > "$W/roster.tsv"; : > "$W/bd.calls"
  echo "$NOW" > "$NOWF"; echo 4500 > "$SWAPF"
  export DR_CITY="$C" DR_NOW_FILE="$NOWF" DR_SWAP_MB_FILE="$SWAPF" DR_OFF_FILE="$GCD/disk-recovery.off" DR_GC_BIN="$W/bin/gc" DR_SWC_BD_BIN="$W/bin/bd"
  export DR_SWC_SAMPLER_CMD="$W/bin/sampler" DR_SWC_SAMPLES="$SAMPLES" DR_SWC_SESSIONS_FILE="$ROSTER" DR_SWC_PROJECTS_DIR="$PROJ"
  export DR_SWC_LOG="$LOGF" DR_SWC_LOCK="$GCD/disk-recovery-swap-cut.lock" DR_SWC_STATE="$STATEF" DR_SWC_PAUSE_FILE="$PAUSEF"
  export DR_SWC_SETTLE_S=0 DR_SWC_VERIFY_S=0 DR_SWC_CMD_S=10 DR_SWC_SAMPLER_S=10
  unset W_SWAP_DROP
}
# rec <arquivo> <ts> <swap_mb> <lookup_failed true|false> nome:kb:tipo...
rec() {
  local out=$1; shift
  python3 -I - "$@" >> "$out" <<'PY'
import json, sys
ts, swap, lf = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3] == "true"
bo, ok = {}, {}
for a in sys.argv[4:]:
    n, kb, k = a.rsplit(":", 2)
    bo[n] = int(kb); ok[n] = k
print(json.dumps({"ts": ts, "total_rss_kb": sum(bo.values()), "unresolved_kb": 0, "n_procs": 9, "swap_used_mb": swap, "swap_total_mb": 8192.0,
                  "free_pct": 20, "by_owner": bo, "owner_kind": ok, "by_rig": {}, "sessions_lookup_failed": lf}))
PY
}
# sess <id> <nome> <template> <state> <anexada> <closed> <idle_min|-> [alias] [session_name]
sess() { printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "${8:-}" "${9:-}" >> "$W/roster.tsv"; }
mkroster() {
  python3 -I - "$W/roster.tsv" "$ROSTER" "$PROJ" "$NOW" "$W/wd" <<'PY'
import json, os, re, sys
tsv, out, proj, now, wd = sys.argv[1:6]; now = int(now)
rows = []
for ln in open(tsv):
    ln = ln.rstrip("\n")
    if not ln:
        continue
    i, name, tpl, state, att, closed, idle, alias, sname = ln.split("|")
    w = os.path.join(wd, name); key = "key-" + i
    rows.append({"id": i, "name": name, "alias": alias, "template": tpl, "state": state, "attached": att == "true", "closed": closed == "true",
                 "session_name": sname or name, "agent_name": name, "work_dir": w, "session_key": key})
    if idle != "-":
        d = os.path.join(proj, re.sub(r"[^A-Za-z0-9]", "-", w)); os.makedirs(d, exist_ok=True)
        f = os.path.join(d, key + ".jsonl"); open(f, "w").write("{}\n")
        t = now - int(idle) * 60; os.utime(f, (t, t))
json.dump({"sessions": rows, "ok": True}, open(out, "w"))
PY
}
bdwork() { mkdir -p "$W/bd/${1}"; echo '[{"id":"ga-x","status":"in_progress"}]' > "$W/bd/$1/$2"; }
run() {  # run <args...> → OUT (stdout), ERR, RC
  OUT=$(bash "$SUT" "$@" 2>"$W/err"); RC=$?; ERR=$(cat "$W/err" 2>/dev/null)
}
lines() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
calls() { cat "$CALLS" 2>/dev/null; }
logtxt() { cat "$LOGF" 2>/dev/null; }

# O cenário do 16/11: swap 2800 → 4000 → 4500 em 5 min, disco alto (o degrau nem lê o disco). 11 sessões + dolt + daemon
scenario() {
  reset
  rec "$SAMPLES" $((NOW-290)) 2800 false "wa-worker-1:900000:session" "dolt:3000000:dolt"
  rec "$SAMPLES" $((NOW-130)) 4000 false "wa-worker-1:900000:session" "dolt:3000000:dolt"
  rec "$NEXT" $((NOW-5)) 4500 false "wa-worker-1:900000:session" "gate-reviewer-remote-1:600000:session" "wa-worker-2:500000:session" "wa-worker-3:450000:session" \
    "wa-worker-4:400000:session" "wa-worker-5:350000:session" "wa-worker-7:300000:session" "gate-reviewer-remote-2:290000:session" "wa-worker-6:10000:session" \
    "batista-wa:2000000:session" "gastown.dog-1:400000:session" "dolt:3000000:dolt" "whatsapp-daemon:1500000:daemon"
  sess id-1 wa-worker-1 wa-worker active false false 60
  sess id-2 gate-reviewer-remote-1 gate-reviewer-remote active false false 40
  sess id-3 wa-worker-2 wa-worker active false false 5
  sess id-4 wa-worker-3 wa-worker active false false 90 alias-w3
  sess id-5 wa-worker-4 wa-worker active true false 90
  sess id-6 batista-wa batista-wa active false false 999
  sess id-7 gastown.dog-1 gastown.dog active false false 999
  sess id-8 wa-worker-5 wa-worker active false false -
  sess id-9 wa-worker-6 wa-worker active false false 90
  sess id-10 wa-worker-7 wa-worker active false false 90 "" sn-w7
  sess id-11 gate-reviewer-remote-2 gate-reviewer-remote start-pending false false 90
  mkroster
  bdwork city alias-w3
  bdwork city sn-w7
}

# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
section "o corte: swap subindo 2800 -> 4500 com o disco alto"
scenario
run --run
eq "$RC" 0 "rc 0 (agiu)"
eq "$(lines "$OUT")" 1 "stdout = UMA linha"
has "$OUT" "cortou 2 sessao" "a linha diz quantas cortou"
has "$OUT" "wa-worker-1 878MB" "a linha nomeia a maior com o RSS"
has "$OUT" "gate-reviewer-remote-1 585MB" "a linha nomeia a segunda"
has "$OUT" "voltou 600MB" "a linha diz quanto de swap voltou (lido: 4500->3900)"
case "$OUT" in *[!\ -~]*) nope "stdout so ASCII imprimivel" ;; *) ok "stdout so ASCII imprimivel" ;; esac
eq "$(calls | grep -c '^session suspend ')" 2 "exatamente 2 suspend"
has "$(calls)" "session suspend id-1" "suspendeu a maior (wa-worker-1)"
has "$(calls)" "session suspend id-2" "suspendeu a segunda (gate-reviewer-remote-1)"
eq "$(calls | sed -n '/session suspend/p' | head -1)" "session suspend id-1" "ordem: maior RSS primeiro"
eq "$(cat "$SCALLS" | wc -l | tr -d ' ')" 1 "colheu UMA amostra nova do amostrador"
for n in 3 4 5 6 7 8 9 10 11; do hasnt "$(calls)" "suspend id-$n" "NAO suspendeu id-$n"; done
hasnt "$(calls)" "kill" "nenhum kill/close/stop: so suspend"
hasnt "$(calls)" "session close" "nenhum session close"
has "$(logtxt)" "CORTOU wa-worker-1 (wa-worker, 878MB" "log: quem foi cortado"
has "$(logtxt)" "CORTOU gate-reviewer-remote-1" "log: o segundo"
has "$(logtxt)" "GATILHO: " "log: o gatilho"
has "$(logtxt)" "+1700MB em 300s" "log: o crescimento medido (4500 - 2800)"
has "$(logtxt)" "maiores donos de RAM: dolt 2929MB (nunca:dolt)" "log: os maiores donos e o veredito de cada um"
has "$(logtxt)" "MANTEM wa-worker-2" "log: por que manteve (transcricao recente)"
has "$(logtxt)" "transcricao parada ha 5min" "log: os 5 min"
has "$(logtxt)" "MANTEM wa-worker-3 (wa-worker, 439MB): in_progress=1 como=alias-w3" "log: bead in_progress sob o alias"
has "$(logtxt)" "in_progress=1 como=sn-w7" "log: bead in_progress sob o session_name"
has "$(logtxt)" "MANTEM wa-worker-5" "log: sem transcricao = nao sei = mantem"
has "$(logtxt)" "transcricao desconhecida" "log: diz 'desconhecida'"
hasnt "$(logtxt)" "CORTOU wa-worker-6" "RSS abaixo do minimo nao e candidata"
eq "$(cat "$PAUSEF" 2>/dev/null | sed -n 1p)" PAUSE "pausa do Pilot gravada (linha 1)"
eq "$(cat "$PAUSEF" 2>/dev/null | sed -n 2p)" "$NOW" "pausa: epoch da gravacao"
eq "$(cat "$PAUSEF" 2>/dev/null | sed -n 3p)" "$((NOW+900))" "pausa: validade = agora + 900"
has "$(cat "$PAUSEF" 2>/dev/null | sed -n 4p)" "+1700MB em 300s" "pausa: o motivo"
has "$OUT" "pausou o spawn novo do Pilot ate" "a linha diz da pausa"
has "$(cat "$STATEF")" "s=id-1|wa-worker-1|wa-worker|878|$NOW" "registro: o que SUSPENDI (para a retomada, fatia ga-yh41v0e.3)"
has "$(cat "$STATEF")" "s=id-2|gate-reviewer-remote-1|" "registro: o segundo"
eq "$(grep -c '^s=' "$STATEF")" 2 "registro so tem as 2 cortadas"

section "gatilhos: absoluto, historico curto, sem gatilho"
reset; echo 3000 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 2900 false "wa-worker-1:900000:session"; rec "$SAMPLES" $((NOW-100)) 2950 false "wa-worker-1:900000:session"
run --run
eq "$RC" 10 "swap 3000, +100MB: sem gatilho (rc 10)"
has "$OUT" "sem gatilho" "a linha diz 'sem gatilho'"
eq "$(cat "$SCALLS" | wc -l | tr -d ' ')" 0 "sem gatilho: nao colhe amostra (nao gasta nada)"
eq "$(calls | wc -l | tr -d ' ')" 0 "sem gatilho: nenhuma chamada ao gc"
[ ! -e "$PAUSEF" ] && ok "sem gatilho: sem pausa" || nope "sem gatilho: sem pausa"
reset; echo 5300 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 5200 false "wa-worker-1:900000:session"
rec "$SAMPLES" $((NOW-100)) 5250 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 5300 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "absoluto: swap 5300 > 5120 mesmo SEM crescimento (+100) dispara"
has "$(logtxt)" "swap 5300MB > 5120MB" "log: o motivo e o absoluto"
reset; echo 3000 > "$SWAPF"
rec "$SAMPLES" $((NOW-60)) 600 false "wa-worker-1:900000:session"
run --run
eq "$RC" 10 "historico curto + swap 3000 (< 5120): sem gatilho"
has "$(logtxt)" "historico curto: sem base" "log: diz que nao ha base de crescimento (nao finge crescimento zero)"
has "$OUT" "sem base para o crescimento" "a LINHA tambem diz: 'sem gatilho' sem base nao e 'sem crescimento'"
reset; echo 6000 > "$SWAPF"
rec "$SAMPLES" $((NOW-60)) 600 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 6000 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "historico curto + swap 6000 (> 5120): o absoluto dispara sozinho"
reset; echo 3500 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 1900 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 3500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "crescimento exato de +1600 (>= 1536) dispara com swap abaixo do absoluto"
reset; echo 3336 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 1800 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 3336 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "crescimento de EXATAMENTE +1536 (= o limite) dispara: o limite e >=, nao >"
reset; echo 3335 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 1800 false "wa-worker-1:900000:session"
run --run
eq "$RC" 10 "crescimento de +1535 (1 abaixo do limite) NAO dispara"

section "TERCEIRO ESTADO: amostrador sem leitura = nao corta, nao pausa, avisa (rc 30)"
check30() {  # $1 = descrição
  eq "$RC" 30 "$1: rc 30"
  has "$OUT" "SEM LEITURA" "$1: a linha diz SEM LEITURA"
  eq "$(lines "$OUT")" 1 "$1: stdout = UMA linha"
  eq "$(calls | grep -c 'session suspend')" 0 "$1: NENHUM suspend"
  [ ! -e "$PAUSEF" ] && ok "$1: NENHUMA pausa" || nope "$1: NENHUMA pausa"
}
reset; mkroster; run --run; check30 "arquivo do amostrador ausente"
has "$OUT" "ausente" "ausente: a causa na linha"
reset; echo "isto nao e json" > "$SAMPLES"; echo "{lixo" >> "$SAMPLES"; mkroster; run --run; check30 "arquivo corrompido (so lixo)"
reset; rec "$SAMPLES" $((NOW-1000)) 5500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run; check30 "amostrador parado ha 1000s (> 900s)"
has "$OUT" "amostrador parado" "parado: a causa na linha"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-200)) 5500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run; check30 "ultima amostra de 200s (> 120s) e o amostrador FALHA ao colher outra"
has "$OUT" "200s" "200s: a idade na linha"
eq "$(cat "$SCALLS" | wc -l | tr -d ' ')" 1 "tentou colher uma amostra nova"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-100)) 5500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "amostra de 100s (<= 120s) e o amostrador falha: usa a que tem (leitura valida), corta"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 5500 true "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run; check30 "sessions_lookup_failed=true (donos sem atribuicao)"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 5500 false "wa-worker-1:900000:session"; echo "lixo" > "$ROSTER"
run --run; check30 "roster de sessoes ilegivel"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 5500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster; : > "$W/mode/list.fail"
unset DR_SWC_SESSIONS_FILE
run --run; check30 "gc session list falha (rc 1)"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "wa-worker-1:900000:session"; rm -f "$NOWF"
run --run; eq "$RC" 30 "relogio ilegivel: rc 30"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 5200 false "wa-worker-1:900000:session"; echo "lixo" > "$SWAPF"
rec "$NEXT" $((NOW-5)) 5500 false "wa-worker-1:900000:session"; sess id-1 wa-worker-1 wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "vm.swapusage ilegivel: usa o swap da amostra (5500) e age"
has "$(logtxt)" "vm.swapusage ilegivel: usei o swap da amostra" "log: diz que usou a amostra, nao 0"

section "sem candidata (rc 11), suspend sem efeito (rc 20), teto por rodada"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "batista-wa:2000000:session" "dolt:3000000:dolt" "whatsapp-daemon:1500000:daemon"
rec "$NEXT" $((NOW-5)) 5500 false "batista-wa:2000000:session" "dolt:3000000:dolt" "whatsapp-daemon:1500000:daemon" "gastown.dog-1:400000:session" "oracle-wa:300000:session"
sess id-6 batista-wa batista-wa active false false 999; sess id-7 gastown.dog-1 gastown.dog active false false 999; sess id-12 oracle-wa oracle-wa active false false 999; mkroster
run --run
eq "$RC" 11 "so crew/dog/oracle/dolt/daemon: rc 11 (gatilho e NAO ha candidata)"
has "$OUT" "NAO ha sessao de pool ociosa" "a linha diz que nao ha o que cortar"
has "$OUT" "dolt 2929MB" "a linha lista os maiores donos (para o humano)"
hasnt "$OUT" "leitura impossivel" "so crew/dog/dolt (nada lido com erro): a linha NAO diz leitura impossivel"
eq "$(calls | grep -c 'session suspend')" 0 "nenhum suspend (crews, dog, oracle, dolt e daemon sao intocaveis)"
[ -e "$PAUSEF" ] && ok "sem candidata: a PAUSA do spawn do Pilot vale mesmo assim" || nope "sem candidata: a PAUSA do spawn do Pilot vale mesmo assim"
scenario; : > "$W/mode/suspend.noop"; run --run
eq "$RC" 0 "suspend rc 0 que NUNCA muda o estado (nem depois do settle): terceiro estado, nao FALHOU: rc 0"
has "$OUT" "2 suspend(s) pedido(s) SEM confirmacao de estado" "a linha conta os nao confirmados a parte"
has "$OUT" "cortou 0 sessao" "e NAO os conta como cortados"
hasnt "$OUT" "sem efeito" "nao diz 'sem efeito' (nao sei se teve)"
hasnt "$OUT" "FALHOU" "nao diz FALHOU"
has "$(logtxt)" "NAO CONFIRMADO wa-worker-1" "log: nao confirmado na hora"
has "$(logtxt)" "NAO CONFIRMADO apos 0s: wa-worker-1 segue 'active'" "log: a releitura depois do settle tambem nao confirmou"
eq "$(grep -c '^s=.*|u$' "$STATEF" 2>/dev/null)" 2 "registro: as 2 entram marcadas u (acordar uma que nao dormiu e inerte; nao registrar uma que dormiu nao e)"
has "$OUT" "pausou o spawn novo do Pilot" "a pausa do Pilot segue valendo"
scenario; : > "$W/mode/suspend.fail"; run --run
eq "$RC" 20 "gc session suspend com rc 1 e a sessao ainda ativa: FALHOU, rc 20"
has "$OUT" "FALHOU" "a linha diz FALHOU"
has "$(logtxt)" "FALHOU wa-worker-1" "log: qual falhou"
eq "$(grep -c '^s=' "$STATEF" 2>/dev/null)" 0 "suspend que falhou NAO entra no registro"
hasnt "$(logtxt)" "NAO CONFIRMADO" "rc != 0 com a sessao ainda ativa nao e 'nao confirmado'"
scenario; : > "$W/mode/suspend.lag"; DR_SWC_SETTLE_S=4 run --run
eq "$RC" 0 "reconciler atrasado (rc 0, ativa na hora, dorme 1 s depois): rc 0"
has "$OUT" "cortou 2 sessao" "a releitura depois do settle resolve: as 2 contam como cortadas"
hasnt "$OUT" "SEM confirmacao" "nada ficou sem confirmar"
hasnt "$OUT" "FALHOU" "e nao e FALHOU (era o defeito: lag virava 'sem efeito')"
has "$(logtxt)" "NAO CONFIRMADO wa-worker-1" "log: na hora nao deu para confirmar"
has "$(logtxt)" "CONFIRMADO wa-worker-1: estado 'asleep' depois de 4s" "log: confirmado depois do settle"
eq "$(grep -c '^s=' "$STATEF" 2>/dev/null)" 2 "registro: as 2 estao la"
eq "$(grep -c '|u$' "$STATEF" 2>/dev/null)" 0 "registro: confirmadas perdem a marca u"
scenario; : > "$W/mode/suspend.gone"; run --run
eq "$RC" 0 "rc 0 e a sessao SUMIU da lista (gone): nao confirma, irmao do idle-crew-suspender (UNCONFIRMED): rc 0, nao CORTOU"
has "$(logtxt)" "NAO CONFIRMADO wa-worker-1 (wa-worker, 878MB): gc session suspend rc=0, estado 'gone'" "log: estado gone"
eq "$(grep -c '^s=.*|u$' "$STATEF" 2>/dev/null)" 2 "gone: no registro, marcadas u"
scenario; DR_SWC_SETTLE_S=30 bash "$SUT" --run > /dev/null 2>&1 & SP=$!
for _ in $(seq 1 60); do grep -q '^s=id-2|' "$STATEF" 2>/dev/null && break; sleep 0.25; done
has "$(cat "$STATEF" 2>/dev/null)" "s=id-1|wa-worker-1|wa-worker|878|$NOW" "o registro ja esta no disco ANTES do settle (kill do maestro na janela do settle nao perde o que dormiu): a 1a"
has "$(cat "$STATEF" 2>/dev/null)" "s=id-2|gate-reviewer-remote-1|" "o registro ja esta no disco ANTES do settle: a 2a"
kill -TERM "$SP" 2>/dev/null; pkill -TERM -P "$SP" 2>/dev/null; { wait "$SP"; } 2>/dev/null
section "releitura IMEDIATAMENTE antes do suspend (as leituras de bd levam ate 90 s)"
scenario; echo id-1 > "$W/mode/bd.attach.wa-worker-1"; run --run
eq "$RC" 0 "o Athos anexou wa-worker-1 DURANTE as leituras de bd: segue com as outras (rc 0)"
hasnt "$(calls)" "suspend id-1" "a que ficou anexada NAO foi suspensa"
has "$(calls)" "suspend id-2" "a outra foi"
has "$(logtxt)" "MANTEM wa-worker-1 (wa-worker, 878MB): logo antes do suspend leu estado|anexada='active|true'" "log: o que leu e por que manteve"
scenario; echo "$PROJ/$(printf '%s' "$W/wd/wa-worker-1" | sed 's#[^A-Za-z0-9]#-#g')/key-id-1.jsonl" > "$W/mode/bd.touch.wa-worker-1"; run --run
eq "$RC" 0 "wa-worker-1 voltou a ESCREVER durante as leituras de bd: segue com as outras (rc 0)"
hasnt "$(calls)" "suspend id-1" "a que voltou a escrever NAO foi suspensa"
has "$(logtxt)" "transcricao parada ha 0min" "log: a transcricao relida"
scenario; : > "$W/mode/bd.warn"; run --run
eq "$RC" 0 "aviso no STDERR do bd com rc 0 nao estraga o JSON (era: toda leitura virava '?' e rc 11 para sempre)"
has "$OUT" "cortou 2 sessao" "bd com aviso: corta as mesmas 2"
scenario; : > "$W/mode/gc.warn"; unset DR_SWC_SESSIONS_FILE; run --run
eq "$RC" 0 "aviso no stderr do gc session list com rc 0 nao estraga o roster nem a leitura de estado"
has "$OUT" "cortou 2 sessao" "gc com aviso: corta as mesmas 2"
section "loja do rig: bead in_progress so no store do rig (work_dir com /crew/)"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "dolt:3000000:dolt"
rec "$NEXT" $((NOW-5)) 5500 false "rigX/crew/w1:900000:session" "wa-worker-2:800000:session"
sess id-1 rigX/crew/w1 wa-worker active false false 90 rw1; sess id-2 wa-worker-2 wa-worker active false false 90; mkroster
mkdir -p "$W/bd/rigX"; echo '[{"id":"wa-y","status":"in_progress"}]' > "$W/bd/rigX/rw1"
run --run
eq "$RC" 0 "bead so no store do RIG: a sessao e mantida, a outra corta"
hasnt "$(calls)" "suspend id-1" "a sessao com bead no store do rig NAO foi suspensa"
has "$(logtxt)" "MANTEM rigX/crew/w1 (wa-worker, 878MB): in_progress=1 como=rw1 store=rigX" "log: achou no store do rig"
has "$(calls)" "suspend id-2" "a sem bead foi"
rm -f "$W/bd/rigX/rw1"; : > "$W/bd.calls"; : > "$CALLS"; echo 5500 > "$SWAPF"; rm -f "$STATEF" "$PAUSEF"; mkroster; run --run
has "$(calls)" "suspend id-1" "controle: sem o bead no rig, a mesma sessao e suspensa (o teste acima pega o laco que ignora o store do rig)"
scenario; : > "$W/mode/bd.fail"; run --run
eq "$RC" 11 "bd falha em tudo: NINGUEM e candidata (in_progress desconhecido = mantem), rc 11"
has "$OUT" "por leitura impossivel" "a linha diz que as mantidas foram por NAO CONSEGUIR LER, nao por estarem ocupadas"
eq "$(calls | grep -c 'session suspend')" 0 "bd ilegivel: nenhum suspend"
scenario; : > "$W/mode/bd.fail.wa-worker-1"; run --run
eq "$RC" 0 "bd falha so para uma identidade de wa-worker-1: ela e mantida, as outras seguem"
hasnt "$(calls)" "suspend id-1" "wa-worker-1 (bd '?') NAO foi suspensa"
has "$(calls)" "suspend id-2" "gate-reviewer-remote-1 foi"
reset; echo 5500 > "$SWAPF"; rec "$SAMPLES" $((NOW-290)) 2000 false "dolt:3000000:dolt"
rec "$NEXT" $((NOW-5)) 5500 false "w-a:900000:session" "w-b:800000:session" "w-c:700000:session" "w-d:600000:session" "w-e:500000:session"
sess i-a w-a wa-worker active false false 60; sess i-b w-b wa-worker active false false 60; sess i-c w-c wa-worker active false false 60
sess i-d w-d wa-worker active false false 60; sess i-e w-e wa-worker active false false 60; mkroster
run --run
eq "$RC" 0 "5 candidatas: age"
eq "$(calls | grep -c 'session suspend')" 3 "teto de 3 por rodada"
eq "$(calls | grep 'session suspend' | tr '\n' ' ')" "session suspend i-a session suspend i-b session suspend i-c " "as 3 maiores, em ordem de RSS"
has "$(logtxt)" "MANTEM w-d (wa-worker, 585MB): teto de 3 por rodada" "log: o teto"
eq "$(grep -c 'w-d\|w-e' "$W/bd.calls")" 0 "teto: a candidata alem do teto NAO custa leitura de bd (o teto vem antes das leituras)"

section "deny-list: sessao de template de POOL com nome de crew/oracle/dolt NUNCA e cortada (2a camada, alem do template)"
reset; echo 5500 > "$SWAPF"
rec "$SAMPLES" $((NOW-290)) 2000 false "wa-worker-1:900000:session"
rec "$NEXT" $((NOW-5)) 5500 false "crew-wa:900000:session" "wa-worker-2:800000:session" "wa-worker-3:700000:session" "wa-worker-4:600000:session"
sess id-1 crew-wa wa-worker active false false 90
sess id-2 wa-worker-2 wa-worker active false false 90 oracle-alfa
sess id-3 wa-worker-3 wa-worker active false false 90 "" my-dolt-box
sess id-4 wa-worker-4 wa-worker active false false 90
mkroster
run --run
eq "$RC" 0 "deny-list: corta a unica que nao casa (rc 0)"
eq "$(calls | grep -c '^session suspend ')" 1 "deny-list: so 1 suspend"
has "$(calls)" "session suspend id-4" "deny-list: suspendeu a que nao casa com nenhum glob"
hasnt "$(calls)" "suspend id-1" "deny-list: nome *-wa (crew) nao e cortado"
hasnt "$(calls)" "suspend id-2" "deny-list: alias oracle* nao e cortado"
hasnt "$(calls)" "suspend id-3" "deny-list: session_name *dolt* nao e cortado"
eq "$(logtxt | grep -o 'nunca:deny-list' | wc -l | tr -d ' ')" 3 "deny-list: o log diz o veredito das 3"

section "stdout: UMA linha e UM \n; a pausa: validade absurda e pausa mantida"
scenario; bash "$SUT" --run > "$W/raw" 2>/dev/null
eq "$(tr -cd '\n' < "$W/raw" | wc -c | tr -d ' ')" 1 "stdout tem exatamente UM \\n (a captura com \\$(...) esconde o \\n a mais: aqui os bytes sao contados)"
scenario; printf 'PAUSE\n%s\n%s\nx\n' "$NOW" "$((NOW+5000))" > "$PAUSEF"; run --run
eq "$(sed -n 3p "$PAUSEF")" "$((NOW+900))" "pausa com validade a 5000 s (o Pilot ignora > 3600 s): NAO conta como vigente, e regravada"
scenario; printf 'PAUSE\n%s\n%s\nx\n' "$NOW" "$((NOW+500))" > "$PAUSEF"; run --run
eq "$(sed -n 3p "$PAUSEF")" "$((NOW+500))" "pausa com validade a 500 s (>= metade de 900, <= 3600): mantida, nao regravada"
_h=$(date -r "$((NOW+500))" '+%H:%M' 2>/dev/null || date -d "@$((NOW+500))" '+%H:%M')
has "$OUT" "pausou o spawn novo do Pilot ate $_h" "a linha diz a validade REAL da pausa mantida (NOW+500), nao NOW+900"

section "carencia depois de cortar"
scenario; run --run; eq "$RC" 0 "1a rodada corta"
echo $((NOW+60)) > "$NOWF"; echo 4600 > "$SWAPF"; : > "$CALLS"
run --run
eq "$RC" 10 "60 s depois, swap 4600 (< 3900+768): em carencia"
has "$OUT" "em carencia" "a linha diz carencia"
eq "$(calls | grep -c 'session suspend')" 0 "carencia: nao corta de novo"
eq "$(cat "$PAUSEF" | sed -n 3p)" "$((NOW+900))" "carencia: a pausa vigente NAO e regravada (ainda tem mais da metade)"
echo $((NOW+500)) > "$NOWF"; echo 6000 > "$SWAPF"; rec "$SAMPLES" $((NOW+495)) 5900 false "wa-worker-1:900000:session"; : > "$CALLS"
run --run
eq "$RC" 11 "500 s depois, swap 6000, as 2 cortadas dormem e nao ha outra: rc 11"
eq "$(logtxt | grep -c 'PAUSA do spawn do Pilot ate')" 2 "passou da metade da validade: renova a pausa (log: gravou 2 vezes)"
eq "$(cat "$PAUSEF" | sed -n 3p)" "$((NOW+500+900))" "pausa renovada: validade nova = agora + 900"

section "dry-run, interruptor, trava"
scenario; cat "$NEXT" >> "$SAMPLES"; rm -f "$NEXT"
run --dry-run
eq "$RC" 10 "dry-run: rc 10 (nao agiu)"
has "$OUT" "(dry-run)" "dry-run: a linha diz"
has "$OUT" "cortaria 2 sessao" "dry-run: diz o que cortaria"
eq "$(calls | grep -c 'session suspend')" 0 "dry-run: nenhum suspend"
eq "$(cat "$SCALLS" | wc -l | tr -d ' ')" 0 "dry-run: nao colhe amostra"
[ ! -e "$PAUSEF" ] && [ ! -e "$STATEF" ] && [ ! -e "$LOGF" ] && ok "dry-run: nao grava pausa, estado nem log" || nope "dry-run: nao grava pausa, estado nem log"
has "$ERR" "[dry-run]" "dry-run: o detalhe vai para stderr"
scenario; : > "$GCD/disk-recovery.off"; run --run
eq "$RC" 10 "interruptor ligado: rc 10"
eq "$(calls | wc -l | tr -d ' ')" 0 "interruptor: nada e feito"
printf '#!/bin/bash\nsleep 30\n' > "$W/bin/disk-recovery-swap-cut-holder.sh"
scenario; mkdir -p "$GCD/disk-recovery-swap-cut.lock"; bash "$W/bin/disk-recovery-swap-cut-holder.sh" & LP=$!; sleep 0.3; echo "$LP" > "$GCD/disk-recovery-swap-cut.lock/pid"
run --run; kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
eq "$RC" 10 "trava tomada por processo vivo: rc 10 e uma linha, nada e feito"
eq "$(calls | wc -l | tr -d ' ')" 0 "trava: nada e feito"
scenario; mkdir -p "$GCD/disk-recovery-swap-cut.lock"; echo 999999 > "$GCD/disk-recovery-swap-cut.lock/pid"
run --run
eq "$RC" 0 "trava de processo morto e retomada"
[ ! -d "$GCD/disk-recovery-swap-cut.lock" ] && ok "a trava e solta no fim" || nope "a trava e solta no fim"
run --bogus; eq "$RC" 2 "argumento errado: rc 2"

section "variaveis de teste: lixo cai no padrao e e dito"
scenario; DR_SWC_MAX_CUT=abc DR_SWC_GROW_MB=-5 run --run
eq "$RC" 0 "lixo em MAX_CUT/GROW_MB: usa o padrao e age"
has "$(logtxt)" "variavel de configuracao invalida" "log: diz que usou o padrao"
scenario; DR_SWC_MAX_CUT=1 run --run
eq "$(calls | grep -c 'session suspend')" 1 "DR_SWC_MAX_CUT=1: so 1"

section "estatica: o que o degrau nunca faz"
[ -x "$SUT" ] && ok "o degrau tem permissao de execucao (o maestro PULA e avisa o que nao executa)" || nope "o degrau tem permissao de execucao (o maestro PULA e avisa o que nao executa)"
SRC=$(grep -v "^[[:space:]]*#" "$SUT")   # só o código: os comentários citam o que o degrau NÃO faz
hasnt "$SRC" "kill -9" "sem a string kill -9 (o cronometro usa kill -KILL so no PROPRIO filho que estourou o prazo)"
hasnt "$SRC" "pkill -f" "sem pkill -f"
hasnt "$(printf '%s' "$SRC" | tr 'A-Z' 'a-z')" "appium" "nao toca Appium"
hasnt "$SRC" "declare -A" "bash 3.2: sem declare -A"
hasnt "$SRC" "mapfile" "bash 3.2: sem mapfile"
has "$SRC" "gc session suspend" "usa gc session suspend (reversivel)"
hasnt "$SRC" "session kill" "nao mata sessao"
hasnt "$SRC" "session close" "nao fecha sessao"
hasnt "$SRC" "dolt stop" "nao para o Dolt"

printf '\n%s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
