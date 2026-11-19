#!/usr/bin/env bash
# pilot-dispatcher.ram-floor.selftest.sh — ga-1p1i5jr.14: o teto de RAM do Pilot (o mini não abre sessão nova com a RAM livre real abaixo do piso)
#
# Contents
#   O que prova · Como roda
#
# O QUE PROVA: (1) o leitor `_pilot_ram_floor` (verbatim do dispatcher): rc 0 só abaixo do piso com a chave `1`; `shadow` lê e nomeia o estado mas nunca age; ilegível (leitura, lib, host) = "unknown" (fail-open, nomeado);
#   chave desligada (padrão, `0`, vazio, palavra desconhecida) e host que não é macOS = "off". (2) a região do gate (verbatim, `set -euo pipefail`): RAM baixa + PILOT_NODE_FIRST=on fora do DRY_RUN = passada SÓ-NÓ (pausa "ram-floor"
#   gravada uma vez, sem sobrescrever a de uma só-nó do disco); senão pausa a varredura e sai com "memory floor" (a tabela do reconciler arquiva qualquer texto com a palavra ram como pressão de RAM); shadow só loga; ok é calado.
#   (3) a ordem no dispatcher. COMO RODA: awk extrai verbatim, a lib é a REAL, uname/sysctl/memory_pressure são fakes no PATH de sandbox. Variáveis: PILOT_DISPATCHER_PATH
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${PILOT_DISPATCHER_PATH:-$SELF_DIR/pilot-dispatcher.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $*"; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
# vazio (a função não existe) → texto vazio e o FATAL abaixo; falhou/ilegível (dispatcher que o awk não lê) → idem, nunca um valor inventado
fn_src() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{"{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER"; }
region() { RA="$1" RB="$2" awk 'f==0 && $0 ~ ENVIRON["RA"] {f=1} f==1 && n>0 && $0 ~ ENVIRON["RB"] {exit} f==1 {print; n++}' "$DISPATCHER"; }
FUNC="$(fn_src _pilot_ram_floor)"; CFG="$(grep -E '^(PILOT_RAM_FLOOR_ENABLED=|PILOT_RAM_LIB=)' "$DISPATCHER")"
GATE="$(region '^_ram_floor_rc=0$' '^# ── ga-a2v0bz: drain window')"
{ [ -n "$FUNC" ] && [ -n "$CFG" ] && [ -n "$GATE" ]; } || { echo "FATAL: ga-1p1i5jr.14 não aplicada (_pilot_ram_floor, a configuração ou a região do gate não achadas em $DISPATCHER)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-ram-floor-selftest.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/fake"
printf '%s\n' '#!/bin/sh' 'cat "$FAKE/uname"' > "$WORK/bin/uname"
printf '%s\n' '#!/bin/sh' 'if [ "$*" = "-n hw.memsize" ]; then echo 17179869184; else exit 2; fi' > "$WORK/bin/sysctl"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "The system has 17179869184 (1048576 pages with a page size of 16384)." "" "System-wide memory free percentage: $(cat "$FAKE/pct")%"' > "$WORK/bin/memory_pressure"
chmod +x "$WORK/bin/uname" "$WORK/bin/sysctl" "$WORK/bin/memory_pressure"
sandbox_path_init "$WORK" sed head cat || exit 2
echo Darwin > "$WORK/fake/uname"; echo 54 > "$WORK/fake/pct"
LIB="$SELF_DIR/scripts/ram-headroom-lib.sh"

cat > "$WORK/reader-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
eval "$CFG"
eval "$FUNC"
rc=0
_pilot_ram_floor || rc=$?
echo "RC=$rc STATE=$PILOT_RAM_FLOOR_STATE DETAIL=$PILOT_RAM_FLOOR_DETAIL NOTE=${PILOT_RAM_FLOOR_NOTE:-}"
EOF
# rd <VAR=val...> — roda o leitor; deixa R_RC R_STATE R_DETAIL R_NOTE (R_SURVIVED=0 se o shell morreu antes de imprimir: o set -e comeu a varredura)
rd() {
  local out; out="$(env CFG="$CFG" FUNC="$FUNC" SANDBOX_PATH="$SANDBOX_PATH" FAKE="$WORK/fake" PILOT_RAM_LIB="$LIB" "$@" bash "$WORK/reader-runner.sh" 2>&1)"
  R_SURVIVED=0; case "$out" in *"RC="*) R_SURVIVED=1 ;; esac
  R_RC="$(printf '%s\n' "$out" | sed -n 's/^RC=\([0-9]*\) .*/\1/p')"; R_STATE="$(printf '%s\n' "$out" | sed -n 's/^RC=[0-9]* STATE=\([a-z]*\) .*/\1/p')"
  R_DETAIL="$(printf '%s\n' "$out" | sed -n 's/.* DETAIL=\(.*\) NOTE=.*/\1/p')"; R_NOTE="$(printf '%s\n' "$out" | sed -n 's/.* NOTE=//p')"
}
rexpect() { # <desc> <rc> <estado> [detalhe]
  if [ "$R_SURVIVED" = 1 ] && [ "$R_RC" = "$2" ] && [ "$R_STATE" = "$3" ] && { [ -z "${4:-}" ] || [ "$R_DETAIL" = "$4" ]; }; then ok
  else bad "$1 — esperado rc=$2 estado=$3 detalhe='${4:-*}'; veio sobreviveu=$R_SURVIVED rc='$R_RC' estado='$R_STATE' detalhe='$R_DETAIL'"; fi
}
ON=PILOT_RAM_FLOOR_ENABLED=1; LOW=PILOT_RAM_AVAIL_OVERRIDE_MB=1500
echo "── (1) o leitor"
rd $ON $LOW;                                  rexpect "ligada + 1500 MB: abaixo do piso" 0 low "ram_free=1500MB floor=2048MB"
rd $ON PILOT_RAM_AVAIL_OVERRIDE_MB=2048;      rexpect "no piso exato: ok (o piso é um mínimo)" 1 ok "ram_free=2048MB floor=2048MB"
rd $ON PILOT_RAM_AVAIL_OVERRIDE_MB=2047;      rexpect "1 MB abaixo: low" 0 low
rd $ON PILOT_RAM_AVAIL_OVERRIDE_MB=9000;      rexpect "folga: ok" 1 ok
rd $ON $LOW RAM_NEW_WORK_MIN_MB=1000;         rexpect "o piso se afina (RAM_NEW_WORK_MIN_MB=1000): 1500 é ok" 1 ok "ram_free=1500MB floor=1000MB"
rd $ON RAM_AVAIL_OVERRIDE_MB=1500;            rexpect "a fixação da própria lib (RAM_AVAIL_OVERRIDE_MB) também vale" 0 low
rd $ON PILOT_RAM_AVAIL_OVERRIDE_MB=abc;       rexpect "leitura ilegível: unknown, rc 1 (fail-open), nunca low" 1 unknown "ram_free=?MB floor=2048MB"
rd PILOT_RAM_FLOOR_ENABLED=shadow $LOW;       rexpect "shadow lê e NOMEIA o estado (low) mas não age: rc 1" 1 low "ram_free=1500MB floor=2048MB"
for v in 0 "" yes true on 01; do rd PILOT_RAM_FLOOR_ENABLED="$v" $LOW; rexpect "chave '$v': desligada, não lê nada" 1 off; done
rd $LOW;                                      rexpect "sem a chave (o padrão do dispatcher): desligada" 1 off
rd $ON $LOW PILOT_RAM_LIB=/nonexistent/lib.sh; rexpect "biblioteca ausente: unknown, rc 1" 1 unknown
case "$R_DETAIL" in *"/nonexistent/lib.sh"*) ok ;; *) bad "o detalhe deve nomear a biblioteca: '$R_DETAIL'" ;; esac
printf '%s\n' 'case $x in a) :;; ;; esac' 'if then fi (' > "$WORK/bad-lib.sh"
rd $ON $LOW PILOT_RAM_LIB="$WORK/bad-lib.sh"; rexpect "biblioteca com erro de sintaxe NÃO derruba a varredura (probe em subshell): unknown" 1 unknown
printf '%s\n' 'RAM_NEW_WORK_MIN_MB=2048' 'ram_host_kind() { printf darwin; }' 'ram_avail_mb() { printf 1; }' 'ram_state_of() { printf banana; }' > "$WORK/junk-lib.sh"
rd $ON PILOT_RAM_LIB="$WORK/junk-lib.sh"; rexpect "uma lib que responde lixo vira unknown, não um estado inventado" 1 unknown
printf '%s\n' 'ram_host_kind() { printf darwin; }' 'ram_avail_mb() { printf 1; }' 'ram_state_of() { printf low; }' > "$WORK/nofloor-lib.sh"
rd $ON PILOT_RAM_LIB="$WORK/nofloor-lib.sh"; rexpect "uma lib sem o piso (mais velha que o leitor): unknown, e o set -u não mata a varredura" 1 unknown
for miss in ram_host_kind ram_avail_mb ram_state_of; do
  printf '%s\n' 'ram_host_kind() { printf darwin; }' 'ram_avail_mb() { printf 1; }' 'ram_state_of() { printf low; }' | grep -v "^$miss" > "$WORK/part-lib.sh"
  rd $ON PILOT_RAM_LIB="$WORK/part-lib.sh"; rexpect "biblioteca sem $miss: unknown" 1 unknown; case "$R_DETAIL" in "library unreadable"*) ok ;; *) bad "sem $miss o detalhe deve dizer que a biblioteca não carrega: '$R_DETAIL'" ;; esac
done
echo Linux > "$WORK/fake/uname"; rd $ON $LOW;  rexpect "host que não é macOS: off (o problema de swapfile é do macOS)" 1 off
rm -f "$WORK/fake/uname"; rd $ON $LOW;          rexpect "uname que falha: unknown, nunca off" 1 unknown
echo Darwin > "$WORK/fake/uname"
rd $ON RAM_HEADROOM_ENABLED=0 $LOW;           rexpect "chave da lib (RAM_HEADROOM_ENABLED=0): tudo ok" 1 ok
case "$R_NOTE" in *RAM_HEADROOM_ENABLED=0*) ok ;; *) bad "a chave da lib tem de aparecer na NOTA: '$R_NOTE'" ;; esac
echo 5 > "$WORK/fake/pct";  rd $ON;           rexpect "ponta a ponta sem fixar: 5% de 16 GB = 819 MB" 0 low "ram_free=819MB floor=2048MB"
echo 54 > "$WORK/fake/pct"; rd $ON;           rexpect "ponta a ponta: 54% = 8847 MB" 1 ok "ram_free=8847MB floor=2048MB"

cat > "$WORK/gate-runner.sh" <<'EOF'
set -euo pipefail
PATH="$SANDBOX_PATH"
log()  { echo "LOG $*"; }
warn() { echo "WARN $*"; }
_pilot_write_sweep_pause_state() { echo "PAUSE_STATE $*" >> "$WORK/pause.calls"; }
eval "$CFG"; eval "$FUNC"
_PILOT_NODE_ONLY="${GT_NODE_ONLY:-0}"; PILOT_NODE_FIRST="${GT_MODE-on}"; DRY_RUN="${GT_DRY:-0}"
eval "$GATE"
echo "REACHED node_only=$_PILOT_NODE_ONLY"
EOF
# gate <VAR=val...> — roda a região; deixa G_REACHED G_NODE_ONLY G_PAUSES (quantas pausas gravadas) G_REASON G_END ("(paused: …)" do fim) e G_OUT
gate() {
  rm -f "$WORK/pause.calls"
  G_OUT="$(env CFG="$CFG" FUNC="$FUNC" GATE="$GATE" SANDBOX_PATH="$SANDBOX_PATH" FAKE="$WORK/fake" WORK="$WORK" PILOT_RAM_LIB="$LIB" "$@" bash "$WORK/gate-runner.sh" 2>&1)"
  G_REACHED=0; case "$G_OUT" in "REACHED "*|*$'\n'"REACHED "*) G_REACHED=1 ;; esac
  G_NODE_ONLY="$(printf '%s\n' "$G_OUT" | sed -n 's/^REACHED node_only=//p')"
  G_PAUSES="$(grep -c '^PAUSE_STATE 1 ram-floor ' "$WORK/pause.calls" 2>/dev/null)"; G_PAUSES="${G_PAUSES:-0}"
  G_END="$(printf '%s\n' "$G_OUT" | sed -n 's/.*Pilot sweep complete: dispatched=0 (paused: \(.*\)) ===.*/\1/p' | head -1)"
}
gexpect() { # <desc> <reached> <node_only> <pausas gravadas> <fim>
  if [ "$G_REACHED" = "$2" ] && [ "$G_NODE_ONLY" = "$3" ] && [ "$G_PAUSES" = "$4" ] && [ "$G_END" = "$5" ]; then ok
  else bad "$1 — esperado reached=$2 node_only='${3:--}' pausas=$4 fim='${5:--}'; veio reached=$G_REACHED node_only='${G_NODE_ONLY:--}' pausas=$G_PAUSES fim='${G_END:--}' :: $(printf '%s' "$G_OUT" | tr '\n' '|' | cut -c1-300)"; fi
}
logged() { printf '%s\n' "$G_OUT" | grep -q -- "$1" && ok || bad "$2 (log sem '$1'): $(printf '%s' "$G_OUT" | tr '\n' '|' | cut -c1-300)"; }
echo "── (2) o gate"
gate $ON $LOW;                      gexpect "RAM baixa + on, fora do DRY_RUN: segue na passada SÓ-NÓ, 1 pausa gravada" 1 1 1 ""
logged "RAM floor: passada só-nó" "a passada só-nó está dita no log"
gate $ON $LOW GT_NODE_ONLY=1;       gexpect "o disco já ligou a só-nó: segue só-nó e NÃO sobrescreve a razão da pausa" 1 1 0 ""
gate $ON $LOW GT_MODE=off;          gexpect "PILOT_NODE_FIRST=off: pausa a varredura inteira e sai" 0 "" 1 "memory floor"
gate $ON $LOW GT_MODE=;             gexpect "PILOT_NODE_FIRST vazio: pausa inteira" 0 "" 1 "memory floor"
gate $ON $LOW GT_DRY=1;             gexpect "DRY_RUN: pausa inteira" 0 "" 1 "memory floor"
gate $ON PILOT_RAM_AVAIL_OVERRIDE_MB=9000; gexpect "RAM com folga: segue, nada gravado" 1 0 0 ""
[ "$(printf '%s\n' "$G_OUT" | grep -c '^LOG\|^WARN')" = 0 ] && ok || bad "ok deve ser silencioso: $G_OUT"
gate $ON PILOT_RAM_AVAIL_OVERRIDE_MB=abc;  gexpect "RAM ilegível: segue (fail-open), nada gravado" 1 0 0 ""
logged "NOT a confirmation that the RAM is fine" "o fail-open diz que não é confirmação"
gate $LOW;                          gexpect "chave desligada (padrão): segue calada" 1 0 0 ""
[ "$(printf '%s\n' "$G_OUT" | grep -c '^LOG\|^WARN')" = 0 ] && ok || bad "desligada deve ser silenciosa: $G_OUT"
gate PILOT_RAM_FLOOR_ENABLED=shadow $LOW;  gexpect "shadow, RAM baixa: NÃO age (segue, não liga a só-nó, nada gravado)" 1 0 0 ""
logged "RAM floor (sombra)" "shadow escreve a leitura no log"; logged "ram_free=1500MB" "shadow diz o número"
gate PILOT_RAM_FLOOR_ENABLED=shadow PILOT_RAM_AVAIL_OVERRIDE_MB=9000; gexpect "shadow, RAM ok: segue" 1 0 0 ""
logged "RAM floor (sombra)" "shadow escreve a leitura também quando está ok (é o que se compara com o memory_pressure à mão)"
gate $ON RAM_HEADROOM_ENABLED=0 $LOW; logged "bent by the environment" "a chave da lib vira aviso"

echo "── (3) a ordem e a forma no dispatcher"
L_DISK="$(grep -n '^_pilot_disk_floor || _disk_floor_rc=\$?$' "$DISPATCHER" | head -1 | cut -d: -f1)"; L_RAM="$(grep -n '^_pilot_ram_floor || _ram_floor_rc=\$?$' "$DISPATCHER" | head -1 | cut -d: -f1)"
L_DRAIN="$(grep -n '^# ── ga-a2v0bz: drain window' "$DISPATCHER" | head -1 | cut -d: -f1)"
if [ -n "$L_DISK" ] && [ -n "$L_RAM" ] && [ -n "$L_DRAIN" ] && [ "$L_DISK" -lt "$L_RAM" ] && [ "$L_RAM" -lt "$L_DRAIN" ]; then ok; else bad "ordem: disk floor (${L_DISK:--}) < RAM floor (${L_RAM:--}) < drain window (${L_DRAIN:--})"; fi
printf '%s\n' "$GATE" | grep -q '^  exit 0$' && ok || bad "o ramo pausado tem de sair com exit 0"
[ "$(sed -n 's/^PILOT_RAM_FLOOR_ENABLED="\${PILOT_RAM_FLOOR_ENABLED:-\(.*\)}"$/\1/p' "$DISPATCHER")" = 0 ] && ok || bad "o padrão da chave tem de ser 0 (nasce desligada: ligar é do Mayor, no plist)"
[ -r "$LIB" ] && printf '%s\n' "$CFG" | grep -q 'scripts/ram-headroom-lib\.sh}"$' && ok || bad "a biblioteca padrão tem de existir ao lado do dispatcher (scripts/ram-headroom-lib.sh)"
grep -q 'PILOT_RAM_FLOOR_ENABLED' "$SELF_DIR/../../../scripts/com.gascity.pilot.plist" && ok || bad "o plist do Pilot tem de trazer a chave (em shadow)"
echo "pilot-dispatcher ram-floor selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
