#!/usr/bin/env bash
# disk-recovery-swap-cut.selftest.sh — testa o degrau de SWAP (ga-yh41v0e) da escada de disco SEM tocar na máquina.
#
# ## Contents
#   Simulado · Seções · Como rodar
#
# SIMULADO  o swap (DR_SWAP_MB_FILE), o relógio (DR_NOW_FILE), o arquivo do amostrador (JSONL escrito pelo teste, com swap subindo), o amostrador (script de mentira que acrescenta o registro que o teste mandou, ou falha),
#   o roster `gc session list --json` (arquivo; o `gc` de mentira muda o estado dele em suspend/wake e DIMINUI o swap a cada suspend, como se a memória voltasse), as transcrições (arquivos com mtime escolhido), o `bd`
#   (in_progress por identidade e por store; falha por modo; aviso no stderr; anexa/escreve na sessão DURANTE a leitura). Nada real é suspenso, lido ou gravado fora de $W.
# SEÇÕES    gatilho (crescimento · absoluto · histórico curto · sem gatilho) · o corte (só candidata permitida; ordem; teto; nunca dolt/daemon/crew/dog/anexada/in_progress/transcrição recente ou desconhecida/estado) ·
#   o log (quem foi cortado, quanto de swap voltou) · a pausa do Pilot (arquivo, validade, leitura de volta, renovação) · TERCEIRO ESTADO (amostrador ausente/velho/corrompido/sem atribuição/roster ilegível: NÃO corta, NÃO
#   pausa, rc 30, avisa) · sem candidata (rc 11) · suspend com rc != 0 e a sessão ativa (rc 20) · suspend NÃO CONFIRMADO (atraso do reconciler, nunca muda, some da lista) · registro no disco antes do settle · releitura
#   imediatamente antes do suspend (anexada, transcrição) · stderr do bd/gc · loja do rig · uma linha, um \n · pausa (validade absurda, mantida) · carência · dry-run · interruptor · trava · retomada (--resume: calmo, não calmo, ilegível, estado ilegível, marca `u`, wake que falha, sessão que sumiu) · variáveis · estática (sem kill -9/pkill -f/Appium)
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

# gc de mentira: suspend → roster ganha state=asleep e o swap CAI (W_SWAP_DROP, padrão 300); wake → active; list → o roster. Modos em $W/mode: suspend.fail, suspend.noop, suspend.lag, suspend.gone, wake.fail, list.fail, list.slow (trava 30 s)
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
  "session wake")    [ -e "$W_MODE/wake.fail" ] && { echo "wake: boom" >&2; exit 1; }
                     setstate "$3" active; exit 0 ;;
  "session list")    [ -e "$W_MODE/list.fail" ] && exit 1
                     [ -e "$W_MODE/list.slow" ] && sleep 30
                     [ -e "$W_MODE/gc.warn" ] && echo "warning: builtin pack differs from the embedded copy" >&2
                     cat "$W_ROSTER" ;;
  *) exit 0 ;;
esac
STUB
# bd de mentira: `bd -C <store> list --status in_progress --assignee <ident> --json --limit 0` → $W/bd/<basename do store>/<ident> (JSON) ou []. Modos: bd.fail (tudo), bd.fail.<ident>, bd.warn (aviso no stderr com rc 0), bd.sleep (cada leitura leva 2 s),
# bd.attach.<ident> (o arquivo diz o id da sessão: ela fica ANEXADA durante esta leitura), bd.touch.<ident> (o arquivo diz a transcrição que passa a ter escrita agora). Cada chamada vai para $W_BDCALLS
cat > "$W/bin/bd" <<'STUB'
#!/bin/bash
store=""; ident=""
while [ $# -gt 0 ]; do case "$1" in -C) store=$2; shift ;; --assignee) ident=$2; shift ;; esac; shift; done
echo "$(basename "$store") $ident" >> "$W_BDCALLS"
[ -e "$W_MODE/bd.fail" ] && { echo "bd: boom" >&2; exit 1; }
[ -e "$W_MODE/bd.fail.$ident" ] && { echo "bd: boom" >&2; exit 1; }
[ -e "$W_MODE/bd.warn" ] && echo "warning: builtin pack differs from the embedded copy" >&2
[ -e "$W_MODE/bd.sleep" ] && sleep 2
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
has "$(cat "$STATEF")" "s=id-1|wa-worker-1|wa-worker|878|$NOW" "registro: o que SUSPENDI (para o --resume)"
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
eq "$(cat "$STATEF" 2>/dev/null | grep -c '^s=')" 0 "suspend que falhou NAO entra no registro (e a rodada so com falha nem grava estado: o arquivo pode nem existir)"
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

section "carencia: rodada em que TODO suspend falhou NAO arma a carencia (a seguinte tenta de novo)"
scenario; : > "$W/mode/suspend.fail"; run --run
eq "$RC" 20 "R1: todo suspend falha, nada cortado: rc 20 (segue sendo dito)"
has "$OUT" "cortou 0" "R1: a linha nao diz que cortou"
hasnt "$(cat "$STATEF" 2>/dev/null)" "last_cut_ts=$NOW" "R1: NAO grava last_cut_ts (nao houve corte: nao ha o que esperar)"
rm -f "$W/mode/suspend.fail"; echo $((NOW+60)) > "$NOWF"; echo 4600 > "$SWAPF"; : > "$CALLS"
run --run
eq "$RC" 0 "R2 (60 s depois, swap 4600, suspend voltou): corta, NAO fica em carencia (rc 0, nao 10)"
hasnt "$OUT" "em carencia" "R2: a linha nao diz carencia"
eq "$(calls | grep -c '^session suspend ')" 2 "R2: tentou suspender de novo e suspendeu as 2"
has "$OUT" "cortou 2 sessao" "R2: a linha diz que cortou"
has "$(cat "$STATEF" 2>/dev/null)" "last_cut_ts=$((NOW+60))" "R2: agora SIM a carencia arma (houve corte)"
echo $((NOW+90)) > "$NOWF"; echo 4600 > "$SWAPF"; : > "$CALLS"; run --run   # o corte de R2 fez o swap cair para 4000; de volta a 4600 o gatilho vale e a carencia (4600 < 4000+768) segura
eq "$RC" 10 "R3 (30 s depois do corte de R2, gatilho valendo): ai sim, em carencia (rc 10)"
eq "$(calls | grep -c 'session suspend')" 0 "R3: em carencia nao suspende"
has "$OUT" "em carencia" "R3: a linha diz carencia"

section "ESTADO ilegivel / valor invalido / linha desconhecida: nao e 'sem estado' (a linha diz; o arquivo antigo e guardado, nunca sobrescrito)"
# seed_state <linha extra ou vazio>: um estado antigo com o registro de 1 sessao suspensa por mim (s=old-1)
seed_state() { printf 'v=1\nlast_cut_ts=%s\nlast_after_swap=3900\ns=old-1|wa-worker-9|wa-worker|700|%s\n%s' "$((NOW-4000))" "$((NOW-4000))" "${1:+$1
}" > "$STATEF"; }
KEPT="$STATEF.ilegivel.$NOW"
scenario; seed_state; run --run
eq "$RC" 0 "controle: estado valido, sem nota: rc 0"
hasnt "$OUT" "ESTADO" "controle: estado valido NAO gera nota na linha"
hasnt "$(logtxt)" "ESTADO" "controle: nem no log"
[ ! -e "$KEPT" ] && ok "controle: estado valido nao e guardado/movido" || nope "controle: estado valido nao e guardado/movido"
has "$(cat "$STATEF")" "s=old-1|wa-worker-9|wa-worker|700|" "controle: o registro antigo segue no estado novo"
has "$(cat "$STATEF")" "s=id-1|wa-worker-1|" "controle: e o registro novo tambem"
scenario; seed_state "last_cut_ts=abc"; run --run
eq "$RC" 0 "valor invalido em last_cut_ts: corta mesmo assim (rc 0)"
eq "$(lines "$OUT")" 1 "valor invalido: stdout = UMA linha"
has "$OUT" "[ESTADO com valor invalido em last_cut_ts]" "valor invalido: a LINHA diz"
has "$(logtxt | grep 'GATILHO:')" "[ESTADO com valor invalido em last_cut_ts]" "valor invalido: o log do GATILHO diz"
has "$OUT" "estado antigo guardado em disk-recovery-swap-cut.state.ilegivel.$NOW" "valor invalido: a linha diz ONDE guardou o antigo"
has "$(cat "$KEPT" 2>/dev/null)" "last_cut_ts=abc" "valor invalido: o arquivo ORIGINAL esta guardado, byte a byte"
has "$(cat "$KEPT" 2>/dev/null)" "s=old-1|wa-worker-9|wa-worker|700|" "valor invalido: com o registro das sessoes suspensas"
has "$(cat "$STATEF")" "s=old-1|wa-worker-9|wa-worker|700|" "valor invalido: o que da para entender (o registro) segue no estado novo"
has "$(cat "$STATEF")" "s=id-1|wa-worker-1|" "valor invalido: o corte desta rodada foi registrado"
hasnt "$(cat "$STATEF")" "last_cut_ts=abc" "valor invalido: o estado novo esta limpo"
has "$(logtxt)" "guardei o original em $KEPT" "valor invalido: o log diz que guardou"
scenario; seed_state "futuro=1"; run --run
eq "$RC" 0 "linha desconhecida: corta (rc 0)"
has "$OUT" "[ESTADO com linha que nao entendo]" "linha desconhecida: a LINHA diz"
has "$(logtxt | grep 'GATILHO:')" "[ESTADO com linha que nao entendo]" "linha desconhecida: o log do GATILHO diz"
has "$(cat "$KEPT" 2>/dev/null)" "futuro=1" "linha desconhecida: o original (com a linha que nao entendi) esta guardado"
hasnt "$(cat "$STATEF")" "futuro=1" "linha desconhecida: o estado novo so tem o que o degrau entende"
scenario; mkdir -p "$STATEF"; echo "s=old-1|wa-worker-9|wa-worker|700|$((NOW-4000))" > "$STATEF/dentro"; run --run
eq "$RC" 0 "estado ilegivel (e um diretorio: ilegivel ate para root): corta (rc 0)"
has "$OUT" "[ESTADO ILEGIVEL: registro de suspensas pode ter se perdido]" "ilegivel: a LINHA diz"
has "$(logtxt | grep 'GATILHO:')" "[ESTADO ILEGIVEL" "ilegivel: o log do GATILHO diz"
has "$(cat "$KEPT/dentro" 2>/dev/null)" "s=old-1|" "ilegivel: o original (com o registro) esta guardado, nao apagado"
[ -f "$STATEF" ] && ok "ilegivel: o estado novo e um arquivo normal" || nope "ilegivel: o estado novo e um arquivo normal"
has "$(cat "$STATEF" 2>/dev/null)" "s=id-1|wa-worker-1|" "ilegivel: o corte desta rodada foi registrado"
if [ "$(id -u)" != 0 ]; then
  scenario; seed_state; chmod 000 "$STATEF"; run --run
  eq "$RC" 0 "estado ilegivel (chmod 000): corta (rc 0)"
  has "$OUT" "[ESTADO ILEGIVEL: registro de suspensas pode ter se perdido]" "chmod 000: a LINHA diz"
  has "$OUT" "estado antigo guardado em disk-recovery-swap-cut.state.ilegivel.$NOW" "chmod 000: a linha diz onde guardou"
  chmod u+r "$KEPT" 2>/dev/null
  has "$(cat "$KEPT" 2>/dev/null)" "s=old-1|wa-worker-9|wa-worker|700|" "chmod 000: o registro antigo esta no arquivo guardado (rename funciona sem ler)"
  scenario; mkdir -p "$W/ro"; printf 'v=1\ns=old-1|wa-worker-9|wa-worker|700|%s\n' "$((NOW-4000))" > "$W/ro/state"; chmod 000 "$W/ro/state"; chmod 555 "$W/ro"
  DR_SWC_STATE="$W/ro/state" run --run
  chmod 755 "$W/ro"; chmod 600 "$W/ro/state"
  eq "$RC" 20 "estado ilegivel e NAO consigo guarda-lo: rc 20, nao grava por cima"
  has "$OUT" "FALHOU em parte" "sem como guardar: a linha diz FALHOU"
  has "$OUT" "NAO gravei o estado: nao consegui guardar o antigo" "sem como guardar: a linha diz que NAO sobrescreveu"
  has "$OUT" "NAO gravei o registro das sessoes suspensas" "sem como guardar: o FALHOU diz que e o registro, nao o suspend"
  hasnt "$OUT" "0 suspend(s) com rc" "sem como guardar: nao finge que foi suspend com rc != 0"
  has "$(cat "$W/ro/state" 2>/dev/null)" "s=old-1|wa-worker-9|wa-worker|700|" "sem como guardar: o arquivo antigo segue INTACTO"
  chmod -R u+rwx "$W/ro"   # o trap do fim apaga $W inteiro
else
  printf 'pulado - estado ilegivel por chmod 000 e por diretorio sem escrita (rodando como root: a permissao nao barra)\n'
fi
scenario; cat "$NEXT" >> "$SAMPLES"; rm -f "$NEXT"; seed_state "last_cut_ts=abc"; run --dry-run
eq "$RC" 10 "dry-run com estado invalido: rc 10"
has "$OUT" "[ESTADO com valor invalido em last_cut_ts]" "dry-run: a linha tambem diz"
[ ! -e "$KEPT" ] && ok "dry-run: o estado NAO e movido" || nope "dry-run: o estado NAO e movido"
has "$(cat "$STATEF")" "last_cut_ts=abc" "dry-run: nem tocado (segue com o valor invalido de antes)"
scenario; seed_state "last_cut_ts=abc"; : > "$W/mode/suspend.fail"; run --run
eq "$RC" 20 "estado invalido numa rodada em que todo suspend falha: rc 20"
has "$OUT" "[ESTADO com valor invalido em last_cut_ts]" "falha total: a linha diz do estado tambem"
has "$(cat "$STATEF")" "last_cut_ts=abc" "falha total: sem corte nao ha gravacao: o estado antigo nem e mexido"
[ ! -e "$KEPT" ] && ok "falha total: e nao e movido (nada foi gravado)" || nope "falha total: e nao e movido (nada foi gravado)"

section "bd/gc travado: o cronometro (bounded) e o orcamento nao seguram a escada"
scenario; unset DR_SWC_SESSIONS_FILE; : > "$W/mode/list.slow"; _t=$SECONDS; DR_SWC_CMD_S=1 run --run; _el=$((SECONDS - _t))
eq "$RC" 30 "gc session list trava (estoura CMD_S=1): SEM LEITURA, rc 30"
has "$OUT" "SEM LEITURA" "list travado: a linha diz SEM LEITURA"
[ "$_el" -le 15 ] && ok "list travado: a rodada terminou em ${_el}s (o gc de mentira dorme 30 s)" || nope "list travado: a rodada terminou em ${_el}s (o gc de mentira dorme 30 s)"
eq "$(calls | grep -c 'session suspend')" 0 "list travado: nenhum suspend"
[ ! -e "$PAUSEF" ] && ok "list travado: nenhuma pausa" || nope "list travado: nenhuma pausa"
scenario; : > "$W/mode/bd.sleep"; DR_SWC_BUDGET_S=1 run --run
eq "$RC" 11 "orcamento de 1 s esgotado pelas leituras de bd (2 s cada): ninguem e verificada, rc 11"
eq "$(calls | grep -c 'session suspend')" 0 "orcamento esgotado: nenhum suspend (nao verificou = nao corta)"
has "$OUT" "por leitura impossivel" "orcamento esgotado: a linha diz que foi por NAO LER"
has "$(logtxt)" "orcamento de 1s esgotado" "orcamento esgotado: o log diz"

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

section "retomada (--resume)"
resume_at() {  # $1 = epoch; acrescenta um registro calmo de 5 s antes e roda --resume
  echo "$1" > "$NOWF"; rec "$SAMPLES" $(($1-5)) 2000 false "wa-worker-9:100000:session"; run --resume
}
scenario; run --run; : > "$CALLS"
echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+300)) 2000 false "wa-worker-9:100000:session"
T=$((NOW+400)); resume_at "$T"
eq "$RC" 10 "1o --resume calmo: marca o inicio da calma, ainda nao age (rc 10)"
[ -e "$PAUSEF" ] && ok "1o --resume: a pausa fica" || nope "1o --resume: a pausa fica"
eq "$(calls | grep -c 'session wake')" 0 "1o --resume: nao religa"
resume_at $((T+150)); eq "$RC" 10 "calma de 150s: ainda espera"
resume_at $((T+300)); eq "$RC" 0 "calma de 300s: apaga a pausa (rc 0)"
[ ! -e "$PAUSEF" ] && ok "pausa apagada" || nope "pausa apagada"
has "$OUT" "pausa do spawn do Pilot apagada" "a linha diz"
eq "$(calls | grep -c 'session wake')" 0 "com 300s ainda nao religa as sessoes"
resume_at $((T+600)); eq "$(calls | grep -c 'session wake')" 0 "com 600s ainda nao religa"
resume_at $((T+900)); eq "$RC" 0 "calma de 900s: religa (rc 0)"
has "$(calls)" "session wake id-1" "religou wa-worker-1 (a que EU suspendi)"
has "$(calls)" "session wake id-2" "religou gate-reviewer-remote-1"
eq "$(calls | grep -c 'session wake')" 2 "so as 2 do registro"
hasnt "$(calls)" "wake id-3" "nao religa o que nao suspendi"
has "$(logtxt)" "RELIGOU wa-worker-1" "log: quem foi religado"
eq "$(grep -c '^s=' "$STATEF")" 0 "registro esvaziado"
resume_at $((T+1000)); eq "$RC" 10 "depois de tudo: nada a retomar (rc 10)"
has "$OUT" "nada a retomar" "a linha diz"
scenario; run --run; : > "$CALLS"; echo 4800 > "$SWAPF"
hi_at() {  # $1 = epoch; swap alto e ESTAVEL: base de 290 s atras (4750) e amostra de 5 s atras (4800) => crescimento LIDO = +50, sem gatilho (4800 < 5120)
  echo "$1" > "$NOWF"; rec "$SAMPLES" $(($1-290)) 4750 false "wa-worker-9:100000:session"; rec "$SAMPLES" $(($1-5)) 4800 false "wa-worker-9:100000:session"; run --resume
}
hi_at $((NOW+400)); eq "$RC" 10 "swap alto (4800 > 5120-1024) e estavel (+50): NAO calmo (1a)"
hi_at $((NOW+1500)); hi_at $((NOW+1900))
eq "$RC" 10 "swap alto (4800 > 5120-1024) e estavel (+50): NAO calmo, mesmo depois de 1500 s"
has "$OUT" "ainda nao esta calmo" "swap alto: a linha diz que nao esta calmo"
[ -e "$PAUSEF" ] && ok "swap alto: a pausa fica" || nope "swap alto: a pausa fica"
eq "$(calls | grep -c 'session wake')" 0 "swap alto: nao religa"
scenario; run --run; : > "$CALLS"; echo 2000 > "$SWAPF"; rm -f "$SAMPLES"
echo $((NOW+1500)) > "$NOWF"; run --resume
eq "$RC" 30 "--resume com amostrador sem leitura: rc 30"
[ -e "$PAUSEF" ] && ok "sem leitura: a pausa fica (a validade vence sozinha)" || nope "sem leitura: a pausa fica"
eq "$(calls | grep -c 'session wake')" 0 "sem leitura: nao religa"
scenario; run --run; : > "$CALLS"; echo 2000 > "$SWAPF"
rec "$SAMPLES" $((NOW+300)) 2000 false "wa-worker-9:100000:session"; T=$((NOW+400))
resume_at "$T"; resume_at $((T+300)); resume_at $((T+600)); : > "$W/mode/wake.fail"; resume_at $((T+900))
eq "$RC" 20 "wake que falha: rc 20"
eq "$(grep -c '^s=' "$STATEF")" 2 "wake falhou: o registro CONTINUA com as 2 (tenta de novo na proxima)"
rm -f "$W/mode/wake.fail"; DR_SWC_MAX_WAKE=1 resume_at $((T+1000))
eq "$(calls | grep -c 'session wake id-1')" 2 "tentou de novo na rodada seguinte (1 por rodada com MAX_WAKE=1)"
eq "$(grep -c '^s=' "$STATEF")" 1 "MAX_WAKE=1: sobrou 1 no registro"
scenario; run --run; : > "$CALLS"; echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+395)) 2000 false "wa-worker-9:100000:session"
echo $((NOW+400)) > "$NOWF"; rm -f "$SAMPLES"; rec "$SAMPLES" $((NOW+398)) 2000 false "wa-worker-9:100000:session"
run --resume
eq "$RC" 10 "historico curto (sem base de crescimento): NAO e calma"
[ -e "$PAUSEF" ] && ok "historico curto: a pausa fica" || nope "historico curto: a pausa fica"
echo $((NOW+720)) > "$NOWF"; rm -f "$SAMPLES"; rec "$SAMPLES" $((NOW+718)) 2000 false "wa-worker-9:100000:session"
run --resume
eq "$RC" 10 "historico curto 320 s depois (ainda sem base): continua sem calma (rc 10)"
[ -e "$PAUSEF" ] && ok "historico curto 320 s depois: a pausa continua (calma = os DOIS lidos)" || nope "historico curto 320 s depois: a pausa continua"
eq "$(calls | grep -c 'session wake')" 0 "historico curto: nao religa"

section "retomada: marca u, sessao que sumiu, ja ativa, roster ilegivel, estado ilegivel, pausa ilegivel, contagem velha, gravacao que falha"
calm_to_wake() {  # depois de scenario + run --run: acende a calma e chega em T+600 (o teste faz o --resume de T+900)
  echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+300)) 2000 false "wa-worker-9:100000:session"
  T=$((NOW+400)); resume_at "$T"; resume_at $((T+300)); resume_at $((T+600))
}
rost_del() { python3 -I -c 'import json, sys
p, i = sys.argv[1:3]
d = json.load(open(p)); d["sessions"] = [s for s in d["sessions"] if s["id"] != i]; json.dump(d, open(p, "w"))' "$ROSTER" "$1"; }
rost_set() { python3 -I -c 'import json, sys
p, i, st = sys.argv[1:4]
d = json.load(open(p))
for s in d["sessions"]:
    if s["id"] == i: s["state"] = st
json.dump(d, open(p, "w"))' "$ROSTER" "$1" "$2"; }
# marca u: o registro tem uma suspensa nao confirmada; religa igual, e a marca VOLTA no registro quando o wake falha
scenario; run --run; : > "$CALLS"
awk '/^s=id-1\|/ { print $0 "|u"; next } { print }' "$STATEF" > "$W/st.new" && mv "$W/st.new" "$STATEF"
calm_to_wake; : > "$W/mode/wake.fail"; resume_at $((T+900))
eq "$RC" 20 "marca u + wake que falha: rc 20"
has "$(cat "$STATEF")" "s=id-1|wa-worker-1|wa-worker|878|$NOW|u" "wake falhou: a marca u volta no registro (nao vira confirmada)"
has "$(calls)" "session wake id-1" "religou tambem a marcada u"
rm -f "$W/mode/wake.fail"; resume_at $((T+1000))
eq "$RC" 0 "marca u: na rodada seguinte o wake passa (rc 0)"
eq "$(grep -c '^s=' "$STATEF")" 0 "marca u: registro esvaziado"
# sessao que sumiu do roster (leitura POSITIVA: o id nao esta na lista): sai do registro sem wake, nao fica rc 20 para sempre
scenario; run --run; : > "$CALLS"; rost_del id-1
calm_to_wake; resume_at $((T+900))
eq "$RC" 0 "sessao que sumiu: rc 0"
hasnt "$(calls)" "session wake id-1" "sumiu: nao tenta o wake dela"
has "$(calls)" "session wake id-2" "sumiu: a outra e religada"
has "$OUT" "wa-worker-1 ja nao existe" "sumiu: a linha diz"
has "$(logtxt)" "nao esta mais no roster" "sumiu: o log diz"
eq "$(grep -c '^s=' "$STATEF")" 0 "sumiu: saiu do registro"
# alguem ja religou (ativa): tambem sai sem wake
scenario; run --run; : > "$CALLS"; rost_set id-1 active
calm_to_wake; resume_at $((T+900))
eq "$RC" 0 "ja ativa: rc 0"
hasnt "$(calls)" "session wake id-1" "ja ativa: nao repete o wake"
has "$(calls)" "session wake id-2" "ja ativa: a outra e religada"
has "$OUT" "wa-worker-1 ja estava ativa" "ja ativa: a linha diz"
eq "$(grep -c '^s=' "$STATEF")" 0 "ja ativa: saiu do registro"
# roster ILEGIVEL e terceiro estado: nao e "sumiu" — nao tira ninguem do registro, tenta o wake (a direcao que devolve a sessao)
scenario; run --run; : > "$CALLS"
calm_to_wake; echo 'lixo' > "$ROSTER"; resume_at $((T+900))
has "$(calls)" "session wake id-1" "roster ilegivel: tenta o wake da 1a (nao a tira do registro por nao ler)"
has "$(calls)" "session wake id-2" "roster ilegivel: tenta o wake da 2a"
hasnt "$OUT" "ja nao existe" "roster ilegivel: NAO diz que sumiu"
# ESTADO com linha que nao entendo: o registro pode estar la e eu nao o leio -> rc 30, nao religa, nao grava, a pausa fica
scenario; run --run; : > "$CALLS"; echo 'lixo=1' >> "$STATEF"; cp "$STATEF" "$W/st.before"
calm_to_wake; resume_at $((T+900))
eq "$RC" 30 "estado com linha desconhecida: --resume rc 30"
has "$OUT" "[ESTADO com linha que nao entendo]" "estado ruim: a linha diz"
eq "$(calls | grep -c 'session wake')" 0 "estado ruim: nao religa"
cmp -s "$STATEF" "$W/st.before" && ok "estado ruim: o arquivo NAO foi regravado" || nope "estado ruim: o arquivo NAO foi regravado"
[ -e "$PAUSEF" ] && ok "estado ruim: a pausa fica (a validade vence sozinha)" || nope "estado ruim: a pausa fica"
# estado ILEGIVEL (e um diretorio: ilegivel ate para root) com o registro dentro: "nao li" NAO e "nada a retomar"
scenario; mkdir -p "$STATEF"; echo "s=old-1|wa-worker-9|wa-worker|700|$((NOW-4000))" > "$STATEF/dentro"; echo $((NOW+400)) > "$NOWF"; run --resume
eq "$RC" 30 "estado ilegivel: --resume rc 30 (e nao 'nada a retomar')"
hasnt "$OUT" "nada a retomar" "estado ilegivel: a linha NAO diz 'nada a retomar'"
has "$OUT" "ESTADO ILEGIVEL" "estado ilegivel: a linha diz"
[ -f "$STATEF/dentro" ] && ok "estado ilegivel: nada foi movido nem apagado" || nope "estado ilegivel: nada foi movido nem apagado"
# pausa ilegivel (o Pilot a ignora): depois da calma e limpa, nao fica para sempre
scenario; run --run; : > "$CALLS"; printf 'lixo\n' > "$PAUSEF"
echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+300)) 2000 false "wa-worker-9:100000:session"; T=$((NOW+400)); resume_at "$T"; resume_at $((T+300))
eq "$RC" 0 "pausa ilegivel: apagada depois de 300 s de calma (rc 0)"
[ ! -e "$PAUSEF" ] && ok "pausa ilegivel: o arquivo sumiu" || nope "pausa ilegivel: o arquivo sumiu"
# o gatilho zera a contagem da retomada (calm_since), com corte e sem corte (carencia)
scenario; printf 'v=1\nlast_cut_ts=0\nlast_after_swap=0\ncalm_since=123\n' > "$STATEF"; run --run
has "$(cat "$STATEF")" "calm_since=0" "o gatilho (com corte) zera a contagem da retomada"
scenario; printf 'v=1\nlast_cut_ts=%s\nlast_after_swap=9000\ncalm_since=123\n' "$((NOW-10))" > "$STATEF"; run --run
# cenario novo = nao ha pausa vigente: a carencia a grava (rc 0 = pausa renovada; rc 10 so quando ja ha pausa vigente, testado na secao da carencia)
eq "$RC" 0 "carencia sem pausa vigente: grava a pausa (rc 0)"
has "$OUT" "em carencia" "carencia: a linha diz carencia"
eq "$(calls | grep -c 'session suspend')" 0 "carencia: nenhum corte"
has "$(cat "$STATEF")" "calm_since=0" "o gatilho (so carencia, sem corte) zera a contagem tambem"
has "$(cat "$STATEF")" "last_cut_ts=$((NOW-10))" "e preserva o resto do estado"
# contagem velha (anterior ao ultimo corte) recomeca: o corte encerra o calmo anterior
scenario; run --run; : > "$CALLS"
awk '/^calm_since=/ { print "calm_since=1"; next } { print }' "$STATEF" > "$W/st.new" && mv "$W/st.new" "$STATEF"
echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+800)) 2000 false "wa-worker-9:100000:session"; resume_at $((NOW+1000))
eq "$RC" 10 "contagem anterior ao corte: recomeca (rc 10), nao religa de imediato"
eq "$(calls | grep -c 'session wake')" 0 "contagem velha: nao religa"
has "$(cat "$STATEF")" "calm_since=$((NOW+1000))" "contagem velha: recomecou agora"
[ -e "$PAUSEF" ] && ok "contagem velha: a pausa fica" || nope "contagem velha: a pausa fica"
# a zeragem / o inicio da contagem que NAO gravam: rc 20 e a linha diz (nunca silencio)
if [ "$(id -u)" != 0 ]; then
  scenario; run --run; : > "$CALLS"; mkdir -p "$W/ro2"; cp "$STATEF" "$W/ro2/state"
  awk '/^calm_since=/ { print "calm_since=777"; next } { print }' "$W/ro2/state" > "$W/ro2/s.n" && mv "$W/ro2/s.n" "$W/ro2/state"; chmod 555 "$W/ro2"
  echo 4800 > "$SWAPF"; DR_SWC_STATE="$W/ro2/state" hi_at $((NOW+1000))
  chmod 755 "$W/ro2"
  eq "$RC" 20 "nao calmo e a zeragem nao grava: rc 20"
  has "$OUT" "nao consegui zerar a contagem" "zeragem que nao grava: a linha diz"
  has "$(cat "$W/ro2/state")" "calm_since=777" "zeragem que nao grava: o arquivo segue como estava"
  scenario; run --run; : > "$CALLS"; mkdir -p "$W/ro3"; cp "$STATEF" "$W/ro3/state"; chmod 555 "$W/ro3"
  echo 2000 > "$SWAPF"; rec "$SAMPLES" $((NOW+800)) 2000 false "wa-worker-9:100000:session"; DR_SWC_STATE="$W/ro3/state" resume_at $((NOW+1000))
  chmod 755 "$W/ro3"
  eq "$RC" 20 "calmo e o inicio da contagem nao grava: rc 20"
  has "$OUT" "nao consegui gravar o inicio da contagem" "inicio que nao grava: a linha diz"
  eq "$(calls | grep -c 'session wake')" 0 "inicio que nao grava: nao religa"
  chmod -R u+rwx "$W/ro2" "$W/ro3"
else
  printf 'pulado - zeragem/inicio de contagem que nao gravam (rodando como root: a permissao nao barra)\n'
fi

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

section "a pegada (ga-1p1i5jr.14): o MEM do top (inclui o comprimido) manda na ordem do corte; RSS so quando o top nao foi lido, e o log diz"
# addtop <arquivo> <nome:mem_kb:cmprs_kb...|null|junk> — poe top_mem no ULTIMO registro do arquivo (o que o amostrador acrescentaria)
addtop() {
  python3 -I - "$@" <<'PY'
import json, sys
p, args = sys.argv[1], sys.argv[2:]
lines = open(p).read().splitlines()
r = json.loads(lines[-1])
if args == ["null"]:
    r["top_mem"] = None
elif args == ["junk"]:
    r["top_mem"] = ["x", [1], ["y", "z", "w"], [7, 1, 1], "wa-worker-1", {"a": 1, "b": 2, "c": 3}, ["wa-worker-2", 5], ["wa-worker-2", 5, 5, 5], ["wa-worker-2", "x", 5], ["wa-worker-2", 5, "x"]]
else:
    r["top_mem"] = [[n, int(m), int(c)] for n, m, c in (a.rsplit(":", 2) for a in args)]
lines[-1] = json.dumps(r)
open(p, "w").write("\n".join(lines) + "\n")
PY
}
# wa-worker-1: o maior RSS (878 MB), pegada pequena. wa-worker-2: RSS 97 MB e a maior pegada (quase tudo comprimido). wa-worker-3: RSS 781 MB, pegada 19 MB (abaixo do minimo)
foot() {
  reset
  export DR_SWC_MAX_CUT=1
  rec "$SAMPLES" $((NOW-290)) 2800 false "wa-worker-1:900000:session" "dolt:3000000:dolt"
  rec "$SAMPLES" $((NOW-130)) 4000 false "wa-worker-1:900000:session" "dolt:3000000:dolt"
  rec "$NEXT" $((NOW-5)) 4500 false "wa-worker-1:900000:session" "wa-worker-2:100000:session" "wa-worker-3:800000:session" "dolt:3000000:dolt"
  sess id-1 wa-worker-1 wa-worker active false false 60
  sess id-2 wa-worker-2 wa-worker active false false 60
  sess id-3 wa-worker-3 wa-worker active false false 60
  mkroster
}
foot; addtop "$NEXT" wa-worker-1:300000:10000 wa-worker-2:1500000:1400000 wa-worker-3:20000:0 dolt:2400000:1400000
run --run
eq "$RC" 0 "com top_mem: agiu"
eq "$(calls | sed -n '/session suspend/p')" "session suspend id-2" "corta a maior PEGADA (wa-worker-2, RSS pequeno), nao o maior RSS"
has "$OUT" "wa-worker-2 1464MB" "a linha nomeia a sessao com a pegada em MB (1500000 KB), nao o RSS"
has "$(logtxt)" "maiores donos de RAM: dolt 2343MB (nunca:dolt, comprimido 1367MB), wa-worker-2 1464MB (candidata, comprimido 1367MB)" "log: ordenado por pegada, com o comprimido AO LADO (nao somado)"
has "$(logtxt)" "ordem do corte por MEM" "log: diz a base da ordem"
hasnt "$(logtxt)" "MANTEM wa-worker-3" "wa-worker-3 (RSS 781 MB, pegada 19 MB) nem e candidata: o minimo vale para a pegada"
hasnt "$(logtxt)" "wa-worker-3 (wa-worker" "wa-worker-3 nao aparece como candidata"
for how in sem-campo null junk; do
  foot
  case "$how" in null|junk) addtop "$NEXT" "$how" ;; esac
  run --run
  eq "$(calls | sed -n '/session suspend/p')" "session suspend id-1" "top_mem $how: cai no RSS (corta wa-worker-1, o maior RSS)"
  has "$(logtxt)" "ordem do corte por RSS" "top_mem $how: o log diz que a base foi o RSS"
  has "$(logtxt)" "top" "top_mem $how: o log diz que o top nao foi lido"
  has "$(logtxt)" "maiores donos de RAM: dolt 2929MB (nunca:dolt), wa-worker-1 878MB (candidata)" "top_mem $how: a lista de maiores donos tem o formato de sempre (RSS, sem comprimido)"
done
foot; addtop "$NEXT" wa-worker-2:1500000:1400000 wa-worker-1:300000:10000 wa-worker-3:20000:0 dolt:2400000:1400000
export DR_SWC_MAX_CUT=3; run --run
eq "$(calls | sed -n '/session suspend/p' | tr '\n' ' ')" "session suspend id-2 session suspend id-1 " "teto 3: corta as duas candidatas pela ordem da pegada (a entrada em qualquer ordem no registro)"
unset DR_SWC_MAX_CUT

printf '\n%s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
