#!/usr/bin/env bash
# pilot-dispatcher.swap-spawn-pause.selftest.sh — ga-yh41v0e (o Pilot respeita a pausa de spawn do degrau de swap)
#
# O degrau de swap da escada de disco (scripts/disk-recovery-swap-cut.sh) corta memória e grava <cidade>/.gc/swap-spawn-pause (4 linhas: PAUSE · época de escrita · época de VALIDADE · razão). Sem o Pilot ler esse
# arquivo, "pausar spawn" não pausava nada: o Pilot seguia abrindo sessão com o swap crescendo no volume do Dolt (16/11: swap 2,8 → 6 GB em ~5 min, disco 1 GB, pânico do kernel).
#
# Contents
#   O que prova · Como roda · Controle negativo
#
# O QUE PROVA: (1) o LEITOR `_pilot_swap_spawn_pause` (verbatim do dispatcher), em três estados que nunca se confundem: arquivo ausente → "absent", rc 1, SILÊNCIO · arquivo válido e dentro da validade → "paused", rc 0 ·
#   vencido, primeira linha errada, validade que não é número, validade absurda (dígitos demais / mais longe que PILOT_SWAP_PAUSE_MAX_AHEAD_S), validade com zero à esquerda ("0900": octal derrubaria a varredura), arquivo
#   vazio, diretório no lugar do arquivo, arquivo sem leitura → "expired"/"unreadable", rc 1 (fail-open) e o estado NOMEADO (nunca "paused" por padrão, nunca "absent"). (2) a região do gate (verbatim, com o leitor real e
#   `set -euo pipefail`): pausado → grava a pausa "swap-spawn-pause" UMA vez, fecha com "(paused: swap spawn pause)" e NÃO chega ao resto da varredura; ausente → chega, sem uma linha de log; vencido/ilegível → chega e DIZ no
#   log que é fail-open. (3) a ORDEM no dispatcher: o gate vem depois do gate de RAM e antes do disk floor, e `exit 0` (varredura inteira pausada, nada despachado).
# COMO RODA: leitor e região extraídos VERBATIM do dispatcher (awk) e executados em shells filhos sob `set -euo pipefail`, com o relógio real e arquivos de verdade num diretório temporário; sem rede, sem gc/bd (PATH de
#   sandbox, selftest-sandbox-path.lib.sh). Contra o dispatcher sem o gate as asserções reprovam uma a uma (a função não existe → FATAL logo no início).
# CONTROLE NEGATIVO: cada guarda desligada numa cópia do dispatcher (SP_NO_MUTANTS=1 pula) tem que reprovar este arquivo.
# Variáveis: PILOT_DISPATCHER_PATH · SP_NO_MUTANTS=1
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); [ -n "${SP_MUTANT:-}" ] || echo "  ✓ $*"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; [ -z "${SP_MUTANT:-}" ] || { echo "RESULT $FAIL/$((PASS+FAIL))"; exit 1; }; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }

# vazio (a função não existe) → texto vazio e o FATAL abaixo; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
# region <início> <fim> — as linhas de [início, fim) VERBATIM (regex em ENVIRON: o awk -v comeria as barras); âncora que não casa → vazio → o FATAL
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
FUNC_SWAP="$(fn_src _pilot_swap_spawn_pause)"
GATE_SRC="$(region '^_swap_pause_rc=0$' '^# ── ga-vln2py: DISK FLOOR')"
CFG_SRC="$(grep -E '^(PILOT_SWAP_PAUSE_MAX_AHEAD_S=|case "\$PILOT_SWAP_PAUSE_MAX_AHEAD_S" in)' "$DISPATCHER")"
{ [ -n "$FUNC_SWAP" ] && [ -n "$GATE_SRC" ] && [ -n "$CFG_SRC" ]; } \
  || { echo "FATAL: ga-yh41v0e não aplicada (_pilot_swap_spawn_pause, a região do gate ou a configuração PILOT_SWAP_PAUSE_MAX_AHEAD_S não achadas em $DISPATCHER)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-swap-pause-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/city/.gc"
sandbox_path_init "$WORK" date sed tr cut cat rm grep dirname mkdir || exit 2
PF="$WORK/city/.gc/swap-spawn-pause"
NOW="$(date +%s)"
# reset renova NOW a cada caso: a rodada leva dezenas de segundos e um NOW velho faria "1 s à frente" já estar vencido
reset() { rm -rf "$PF" "$WORK/pause.calls" 2>/dev/null; chmod u+rwx "$WORK/city/.gc" 2>/dev/null; NOW="$(date +%s)"; }
# pf <linha1> <linha2> <linha3> <linha4> — arquivo no formato do escritor; "-" omite a linha
pf() { : > "$PF"; local l; for l in "$@"; do [ "$l" = "-" ] || printf '%s\n' "$l" >> "$PF"; done; }

# ── (1) o leitor, sozinho ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/reader-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
eval "$CFG_SRC"
PILOT_SWAP_PAUSE_FILE="$PF"
eval "$FUNC_SWAP"
rc=0
_pilot_swap_spawn_pause || rc=$?
echo "RC=$rc"
echo "STATE=$PILOT_SWAP_PAUSE_STATE"
echo "DETAIL=$PILOT_SWAP_PAUSE_DETAIL"
EOF
# rd <VAR=valor...> — roda o leitor e deixa R_RC / R_STATE / R_DETAIL; R_SURVIVED=0 se o shell morreu antes de imprimir (o set -e comeu a varredura)
rd() {
  local out; out="$(env CFG_SRC="$CFG_SRC" FUNC_SWAP="$FUNC_SWAP" SANDBOX_PATH="$SANDBOX_PATH" PF="$PF" "$@" bash "$WORK/reader-runner.sh" 2>&1)"
  R_SURVIVED=0; case "$out" in *"RC="*) R_SURVIVED=1 ;; esac
  R_RC="$(printf '%s\n' "$out" | sed -n 's/^RC=//p')"; R_STATE="$(printf '%s\n' "$out" | sed -n 's/^STATE=//p')"; R_DETAIL="$(printf '%s\n' "$out" | sed -n 's/^DETAIL=//p')"
}
rexpect() { # <desc> <rc> <estado>
  if [ "$R_SURVIVED" = 1 ] && [ "$R_RC" = "$2" ] && [ "$R_STATE" = "$3" ]; then ok "$1 — rc=$R_RC estado=$R_STATE"
  else bad "$1 — esperado rc=$2 estado=$3; veio sobreviveu=$R_SURVIVED rc='$R_RC' estado='$R_STATE' detalhe='$R_DETAIL'"; fi
}
echo "── (1) o leitor: ausente é silêncio; só um arquivo que se prova pausa"
reset; rd;                                                   rexpect "arquivo ausente (o caso normal)" 1 absent
[ -z "$R_DETAIL" ] && ok "ausente não tem detalhe (nada a dizer no log)" || bad "ausente trouxe detalhe '$R_DETAIL'"
reset; pf PAUSE "$NOW" $((NOW + 600)) "swap +1.8GB/5min"; rd; rexpect "pausa válida a 600 s de vencer" 0 paused
case "$R_DETAIL" in *"swap +1.8GB/5min"*) ok "o detalhe leva a razão do escritor (linha 4)" ;; *) bad "detalhe sem a razão: '$R_DETAIL'" ;; esac
reset; pf PAUSE "$NOW" $((NOW + 30)) "x"; rd;                 rexpect "validade 30 s à frente (ainda vale)" 0 paused
reset; pf PAUSE "$NOW" $((NOW + 3600)) "x"; rd;               rexpect "validade no teto exato de PILOT_SWAP_PAUSE_MAX_AHEAD_S (3600)" 0 paused
reset; pf PAUSE "$NOW" $((NOW + 600)) -; rd;                  rexpect "sem a linha da razão (4 linhas é o formato, 3 já basta)" 0 paused
echo "── (1) o que NÃO pausa: vencido, ilegível, absurdo — fail-open com o estado NOMEADO"
reset; pf PAUSE $((NOW - 1000)) $((NOW - 100)) "x"; rd;       rexpect "vencida há 100 s" 1 expired
reset; pf PAUSE "$NOW" "$NOW" "x"; rd;                        rexpect "validade == agora (venceu)" 1 expired
reset; pf OUTRA "$NOW" $((NOW + 600)) "x"; rd;                rexpect "primeira linha não é PAUSE" 1 unreadable
reset; pf PAUSE "$NOW" amanha "x"; rd;                        rexpect "validade que não é número" 1 unreadable
reset; pf PAUSE "$NOW" "" "x"; rd;                            rexpect "validade vazia" 1 unreadable
reset; pf PAUSE "$NOW" -1 "x"; rd;                            rexpect "validade negativa (o '-' não é dígito)" 1 unreadable
reset; pf PAUSE "$NOW" 9999999999999999 "x"; rd;              rexpect "validade com dígitos demais" 1 unreadable
reset; pf PAUSE "$NOW" $((NOW + 3700)) "x"; rd;               rexpect "validade 100 s além do teto: pausa que ninguém renova não vale" 1 unreadable
reset; pf PAUSE "$NOW" $((NOW + 86400)) "x"; rd;              rexpect "validade a 24 h (arquivo esquecido/forjado)" 1 unreadable
reset; pf PAUSE "$NOW" "0$((NOW + 600))" "x"; rd;             rexpect "validade com zero à esquerda NÃO vira octal e derruba a varredura (10#)" 0 paused
reset; pf PAUSE "$NOW" "0900" "x"; rd;                        rexpect "validade '0900' (octal inválido) sobrevive ao set -e e vence" 1 expired
reset; : > "$PF"; rd;                                        rexpect "arquivo vazio" 1 unreadable
reset; printf 'PAUSE\n' > "$PF"; rd;                          rexpect "só a primeira linha" 1 unreadable
reset; mkdir -p "$PF"; rd;                                   rexpect "diretório no lugar do arquivo" 1 unreadable
reset; pf PAUSE "$NOW" $((NOW + 600)) "x"; chmod 000 "$PF"; rd; chmod 600 "$PF"
if [ "$(id -u)" = 0 ]; then ok "(rodando como root: a permissão 000 não barra a leitura — caso pulado)"; else rexpect "arquivo sem permissão de leitura" 1 unreadable; fi
reset; pf PAUSE "$NOW" $((NOW + 600)) "x"; rd PILOT_SWAP_PAUSE_MAX_AHEAD_S=60; rexpect "o teto se configura (60 s): validade a 600 s deixa de valer" 1 unreadable
reset; pf PAUSE "$NOW" $((NOW + 600)) "x"; rd PILOT_SWAP_PAUSE_MAX_AHEAD_S=abc; rexpect "teto que não é número cai no padrão 3600 (não em 0 nem derruba)" 0 paused

# ── (2) a região do gate, com o leitor real ──────────────────────────────────────────────────────────────────────────────────────────────────────
cat > "$WORK/gate-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
log()  { echo "LOG $*"; }
warn() { echo "WARN $*"; }
_pilot_write_sweep_pause_state() { echo "PAUSE_STATE $*" >> "$WORK/pause.calls"; }
eval "$CFG_SRC"
PILOT_SWAP_PAUSE_FILE="$PF"
eval "$FUNC_SWAP"
eval "$GATE_SRC"
echo "REACHED"
EOF
gate() {
  rm -f "$WORK/pause.calls"
  G_OUT="$(env CFG_SRC="$CFG_SRC" FUNC_SWAP="$FUNC_SWAP" GATE_SRC="$GATE_SRC" SANDBOX_PATH="$SANDBOX_PATH" PF="$PF" WORK="$WORK" "$@" bash "$WORK/gate-runner.sh" 2>&1)"; G_RC=$?
  G_REACHED=0; case "$G_OUT" in REACHED|*$'\n'REACHED*) G_REACHED=1 ;; esac
  G_PAUSES="$(grep -c '^PAUSE_STATE 1 swap-spawn-pause ' "$WORK/pause.calls" 2>/dev/null)"; G_PAUSES="${G_PAUSES:-0}"
  G_END="$(printf '%s\n' "$G_OUT" | grep -c 'Pilot sweep complete: dispatched=0 (paused: swap spawn pause)')"
  G_LOGS="$(printf '%s\n' "$G_OUT" | grep -c -i 'swap spawn pause file')"
}
gexpect() { # <desc> <reached> <pausas gravadas> <fim de varredura> <linhas fail-open no log>
  if [ "$G_RC" = 0 ] && [ "$G_REACHED" = "$2" ] && [ "$G_PAUSES" = "$3" ] && [ "$G_END" = "$4" ] && [ "$G_LOGS" = "$5" ]; then ok "$1 — reached=$G_REACHED pausa gravada=$G_PAUSES fim=$G_END log-fail-open=$G_LOGS"
  else bad "$1 — esperado reached=$2 pausas=$3 fim=$4 log=$5 rc=0; veio rc=$G_RC reached=$G_REACHED pausas=$G_PAUSES fim=$G_END log=$G_LOGS :: $(printf '%s' "$G_OUT" | tr '\n' '|' | cut -c1-300)"; fi
}
echo "── (2) o gate: pausado pausa a varredura INTEIRA; o resto segue como sempre"
reset; pf PAUSE "$NOW" $((NOW + 600)) "swap +1.8GB/5min"; gate;  gexpect "pausa válida: grava a pausa, fecha a varredura e NÃO chega ao resto" 0 1 1 0
printf '%s\n' "$G_OUT" | grep -q '^WARN .*Swap spawn pause' && ok "o aviso diz o que pausou (WARN)" || bad "sem WARN do gate"
grep -q '^PAUSE_STATE 1 swap-spawn-pause Swap spawn pause: expires in ' "$WORK/pause.calls" 2>/dev/null && ok "a razão gravada para o painel/reconciler é a constante 'swap-spawn-pause'" || bad "razão gravada diferente de swap-spawn-pause: $(cat "$WORK/pause.calls" 2>/dev/null)"
reset; gate;                                                    gexpect "arquivo ausente: chega ao resto, nenhuma pausa, nenhuma linha de log (silêncio)" 1 0 0 0
reset; pf PAUSE $((NOW - 1000)) $((NOW - 100)) "x"; gate;       gexpect "pausa vencida: chega ao resto (fail-open) e o log DIZ que o arquivo venceu" 1 0 0 1
reset; pf OUTRA "$NOW" $((NOW + 600)) "x"; gate;                gexpect "arquivo corrompido: chega ao resto (fail-open) e o log DIZ" 1 0 0 1
reset; pf PAUSE "$NOW" $((NOW + 999999)) "x"; gate;             gexpect "validade absurda: chega ao resto (fail-open) e o log DIZ" 1 0 0 1
reset; pf PAUSE "$NOW" "0900" "x"; gate;                        gexpect "validade '0900' não derruba a varredura (set -e) — chega ao resto, com a linha de vencido" 1 0 0 1
printf '%s\n' "$G_OUT" | grep -q 'NOT a confirmation that the swap is calm' && ok "o log do fail-open não finge que o swap está calmo" || bad "log do fail-open sem a ressalva"

# ── (3) a ordem e a forma no dispatcher ──────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "── (3) a ordem no dispatcher: depois do gate de RAM, antes do disk floor; e sai (exit 0)"
L_RAM="$(grep -n 'if \[ "\$(_pilot_ram_pressure_blocks)" = "1" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)"
L_SWAP="$(grep -n '^_pilot_swap_spawn_pause || _swap_pause_rc=\$?$' "$DISPATCHER" | head -1 | cut -d: -f1)"
L_DISK="$(grep -n '^# ── ga-vln2py: DISK FLOOR' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$L_RAM" ] && [ -n "$L_SWAP" ] && [ -n "$L_DISK" ] && [ "$L_RAM" -lt "$L_SWAP" ] && [ "$L_SWAP" -lt "$L_DISK" ]; then ok "RAM (linha $L_RAM) < swap (linha $L_SWAP) < disk floor (linha $L_DISK)"
else bad "ordem dos gates errada ou âncora ausente: ram=${L_RAM:--} swap=${L_SWAP:--} disk=${L_DISK:--}"; fi
printf '%s\n' "$GATE_SRC" | grep -q '^  exit 0$' && ok "o ramo pausado sai com exit 0 (varredura inteira pausada, nada despachado)" || bad "o ramo pausado não faz exit 0"
printf '%s\n' "$GATE_SRC" | grep -q '_pilot_write_sweep_pause_state 1 "swap-spawn-pause"' && ok "o ramo pausado grava a pausa para o painel (_pilot_write_sweep_pause_state 1)" || bad "o ramo pausado não grava o estado de pausa"
grep -q '^PILOT_SWAP_PAUSE_FILE="\${PILOT_SWAP_PAUSE_FILE:-\${PILOT_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}/.gc/swap-spawn-pause}"$' "$DISPATCHER" && ok "o arquivo padrão é <cidade>/.gc/swap-spawn-pause (o que o degrau de swap grava)" || bad "caminho padrão do arquivo diferente de <cidade>/.gc/swap-spawn-pause"
# o escritor e o leitor têm que concordar no nome: o degrau de swap grava o mesmo caminho
SWC="$SELF_DIR/../../../scripts/disk-recovery-swap-cut.sh"
if [ -f "$SWC" ]; then
  grep -q 'swap-spawn-pause' "$SWC" && ok "o escritor (disk-recovery-swap-cut.sh) usa o mesmo nome de arquivo" || bad "o escritor não menciona swap-spawn-pause"
else echo "  ~ PULADO (não conta como ok): escritor não encontrado em $SWC (fora de um checkout do HQ, ou ainda não entrou: ga-yh41v0e.2); a concordância do nome do arquivo NÃO foi conferida"; fi

# ── controle negativo: cada guarda desligada numa cópia do dispatcher tem que reprovar este arquivo ────────────────────────────────────────────────
if [ -z "${SP_MUTANT:-}" ] && [ "${SP_NO_MUTANTS:-0}" != 1 ]; then
  echo "── controle negativo: o selftest reprova cada guarda removida"
  M=0; MCAUGHT=0
  mutate() { # <nome> <python-expr: s -> s'>
    local name="$1" expr="$2" f="$WORK/mut-$M.sh" out
    M=$((M+1))
    # eval abaixo: a expressão é um literal escrito neste arquivo (as chamadas de mutate logo abaixo), nunca dado externo
    DISPATCHER_IN="$DISPATCHER" python3 -I - "$f" "$expr" <<'PY' || { bad "mutante '$name': não consegui gerar a cópia"; return; }
import os, sys
out, expr = sys.argv[1], sys.argv[2]
s = open(os.environ["DISPATCHER_IN"], encoding="utf-8").read()
t = eval(expr, {"s": s})
if t == s:
    sys.exit(1)
open(out, "w", encoding="utf-8").write(t)
PY
    out="$(SP_MUTANT=1 PILOT_DISPATCHER_PATH="$f" bash "$SELF_DIR/$(basename "${BASH_SOURCE[0]}")" 2>&1)"
    if [ $? -ne 0 ]; then MCAUGHT=$((MCAUGHT+1)); ok "mutante pego: $name"; else bad "mutante SOBREVIVEU: $name"; fi
  }
  mutate "o leitor trata a validade vencida como pausa"          's.replace("if [ \"$_left\" -le 0 ]; then", "if [ \"$_left\" -le -99999999 ]; then")'
  mutate "o leitor não confere a primeira linha PAUSE"            's.replace("if [ \"$_l1\" != \"PAUSE\" ]; then", "if false; then")'
  mutate "o leitor aceita validade que não é número"              's.replace("case \"$_l3\" in \x27\x27|*[!0-9]*) PILOT_SWAP_PAUSE_DETAIL=\"expiry (line 3) is not a number", "case \"$_l3\" in NEVER) PILOT_SWAP_PAUSE_DETAIL=\"expiry (line 3) is not a number")'
  mutate "o leitor perde o teto de validade à frente"             's.replace("if [ \"$_left\" -gt \"$PILOT_SWAP_PAUSE_MAX_AHEAD_S\" ]; then", "if false; then")'
  mutate "o leitor perde o 10# (octal derruba a varredura)"       's.replace("$(( 10#$_l3 - 10#$_now ))", "$(( _l3 - _now ))")'
  mutate "o leitor trata arquivo ilegível como pausa"             's.replace("PILOT_SWAP_PAUSE_STATE=\"unreadable\"\n    PILOT_SWAP_PAUSE_DETAIL=\"exists but is not a readable regular file: ${_f}\"\n    return 1", "PILOT_SWAP_PAUSE_STATE=\"paused\"\n    PILOT_SWAP_PAUSE_DETAIL=\"x\"\n    return 0")'
  mutate "o gate não sai da varredura (exit 0 some)"              's.replace("  log \"=== Pilot sweep complete: dispatched=0 (paused: swap spawn pause) ===\"\n  exit 0", "  log \"=== Pilot sweep complete: dispatched=0 (paused: swap spawn pause) ===\"")'
  mutate "o gate não grava a pausa para o painel"                 's.replace("  _pilot_write_sweep_pause_state 1 \"swap-spawn-pause\"", "  : \"swap-spawn-pause\"")'
  mutate "o gate cala o fail-open (sem a linha de log)"           's.replace("  log \"Swap spawn pause file ${PILOT_SWAP_PAUSE_STATE}", "  : \"Swap spawn pause file ${PILOT_SWAP_PAUSE_STATE}")'
  mutate "o gate vai para depois do disk floor"                   's.replace("# ── ga-yh41v0e: SWAP SPAWN PAUSE — PAUSE dispatch", "# ── ga-vln2py: DISK FLOOR (mutante) — PAUSE dispatch\n# ── ga-yh41v0e: SWAP SPAWN PAUSE — PAUSE dispatch")'
  echo "── $MCAUGHT/$M mutantes pegos"
  [ "$MCAUGHT" = "$M" ] || bad "nem todo mutante foi pego ($MCAUGHT/$M)"
fi

if [ -n "${SP_MUTANT:-}" ]; then echo "RESULT $FAIL/$((PASS+FAIL))"; [ "$FAIL" = 0 ] && exit 0 || exit 1; fi
echo; echo "Resultado: $PASS ok, $FAIL FAIL"
[ "$FAIL" = 0 ]
