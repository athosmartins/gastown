#!/usr/bin/env bash
# drain-window-check.selftest.sh — selftest do leitor do DRENO (ga-a2v0bz).
#
# Contexto: o reboot noturno nao acontecia ha 13 noites porque a cidade nunca
# para de trabalhar de madrugada. O desenho: das 23:00 ate o reboot (23:40) a
# cidade DRENA — Pilot, gate, refino e auto-refino param de ADMITIR trabalho
# novo (o que ja esta em voo termina). nightly-reboot.sh grava o sinal;
# quiet-hours-check.sh (_drain_window_*) e o lado leitor que os 5 despachantes
# ja fazem `source`.
#
# O que este teste prova (uma classe, nao so o exemplo):
#   D1  arquivo AUSENTE            -> nao drena, nao e anomalia (0/0)
#   D2  sinal valido e fresco       -> drena (1)
#   D3  FAIL-OPEN: velho (escritor morto), `until` vencido, ou de OUTRO BOOT
#       -> nao drena. O boot-epoch e o ponto central: um reboot invalida o
#       dreno sozinho, sem passo de limpeza pos-boot que possa falhar.
#   D4  ilegivel (lixo, linhas faltando, vazio) -> nao drena E reporta
#       unreadable=1 (terceiro estado visivel, nunca silencio)
#   D5  `kern.boottime` lido por TOKEN EXATO — a armadilha de `usec` (um regex
#       guloso devolve os microssegundos, 4 ordens de grandeza abaixo; ja
#       queimou ram-pressure-monitor e o Guard 4 do nightly)
#   D6  sysctl falha -> nao da pra provar que o sinal e deste boot -> nao drena
#   D7  os 5 despachantes tem o gate do dreno, ANTES do gate de quiet-hours,
#       com texto proprio (nao o do quiet-hours: "retoma as 08h" seria falso),
#       e o Pilot NAO manda push a cada sweep.
#
# Roda contra o quiet-hours-check.sh real, em arquivos temporarios — nunca toca
# ~/.gastown/run/. Exit 0 sse tudo passa.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QHC="$SELF_DIR/quiet-hours-check.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$QHC" ] || { echo "FATAL: quiet-hours-check.sh nao encontrado em $QHC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/drain-window-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)
BOOT=1789579812            # boot-epoch fixo de teste (injetado pela costura)
OTHER_BOOT=1789500000

# run_drain <arquivo> <fn> [args...] — source fresco do arquivo real, com o
# boot-epoch injetado, numa subshell (nada vaza entre cenarios).
run_drain() {
  local f="$1"; shift
  ( DRAIN_WINDOW_FILE="$f"
    DRAIN_WINDOW_BOOT_EPOCH_OVERRIDE="${DRAIN_TEST_BOOT:-$BOOT}"
    # shellcheck disable=SC1090
    source "$QHC"
    "$@" )
}
# write_sig <arquivo> <estado> <written> <boot> <until>
write_sig() { printf '%s\n%s\n%s\n%s\n' "$2" "$3" "$4" "$5" > "$1"; }

# ── D1 ─────────────────────────────────────────────────────────────────────
echo "D1: arquivo ausente -> nao drena e nao e anomalia"
ABS="$WORK/absent.level"
[ "$(run_drain "$ABS" _drain_window_blocks)" = "0" ] && ok "D1 blocks=0" || bad "D1 blocks deveria ser 0"
[ "$(run_drain "$ABS" _drain_window_unreadable)" = "0" ] && ok "D1 unreadable=0 (ausente e o estado normal fora da janela)" || bad "D1 unreadable deveria ser 0"

# ── D2 ─────────────────────────────────────────────────────────────────────
echo "D2: sinal valido e fresco -> drena"
F="$WORK/fresh.level"
write_sig "$F" DRAIN "$NOW" "$BOOT" $(( NOW + 3600 ))
[ "$(run_drain "$F" _drain_window_blocks)" = "1" ] && ok "D2 blocks=1" || bad "D2 blocks deveria ser 1"
[ "$(run_drain "$F" _drain_window_unreadable)" = "0" ] && ok "D2 unreadable=0" || bad "D2 unreadable deveria ser 0"
[ "$(run_drain "$F" _drain_window_state)" = "DRAIN" ] && ok "D2 state=DRAIN (so log)" || bad "D2 state deveria ser DRAIN"
DET="$(run_drain "$F" _drain_window_detail)"
[ -n "$DET" ] && ok "D2 detail nao vazio: $DET" || bad "D2 detail vazio (o log do despachante precisa dele)"

# ── D3 ─────────────────────────────────────────────────────────────────────
echo "D3: fail-open — velho, until vencido, outro boot"
write_sig "$WORK/old.level" DRAIN $(( NOW - 7200 )) "$BOOT" $(( NOW + 3600 ))
[ "$(run_drain "$WORK/old.level" _drain_window_blocks)" = "0" ] && ok "D3a escritor morto (sinal velho) -> nao drena" || bad "D3a sinal velho NAO pode drenar"
write_sig "$WORK/until.level" DRAIN "$NOW" "$BOOT" $(( NOW - 1 ))
[ "$(run_drain "$WORK/until.level" _drain_window_blocks)" = "0" ] && ok "D3b until vencido -> nao drena (teto duro)" || bad "D3b until vencido NAO pode drenar"
write_sig "$WORK/boot.level" DRAIN "$NOW" "$OTHER_BOOT" $(( NOW + 3600 ))
[ "$(run_drain "$WORK/boot.level" _drain_window_blocks)" = "0" ] && ok "D3c sinal de OUTRO boot -> nao drena (o reboot invalida o dreno)" || bad "D3c sinal de outro boot NAO pode drenar"
[ "$(run_drain "$WORK/boot.level" _drain_window_unreadable)" = "0" ] && ok "D3c expirado-por-boot nao e anomalia (unreadable=0)" || bad "D3c unreadable deveria ser 0"
write_sig "$WORK/future.level" DRAIN $(( NOW + 7200 )) "$BOOT" $(( NOW + 9000 ))
[ "$(run_drain "$WORK/future.level" _drain_window_blocks)" = "0" ] && ok "D3d timestamp no futuro (relogio doido) -> nao drena" || bad "D3d timestamp futuro NAO pode drenar"
write_sig "$WORK/open.level" OPEN "$NOW" "$BOOT" $(( NOW + 3600 ))
[ "$(run_drain "$WORK/open.level" _drain_window_blocks)" = "0" ] && ok "D3e estado OPEN -> nao drena" || bad "D3e OPEN NAO pode drenar"
[ "$(run_drain "$WORK/open.level" _drain_window_unreadable)" = "0" ] && ok "D3e OPEN e legivel (unreadable=0)" || bad "D3e unreadable deveria ser 0"

# ── D4 ─────────────────────────────────────────────────────────────────────
echo "D4: ilegivel -> nao drena E unreadable=1 (terceiro estado visivel)"
printf 'DRAIN\nnao-numero\n%s\n%s\n' "$BOOT" $(( NOW + 3600 )) > "$WORK/c1.level"
printf 'DRAIN\n%s\n\n%s\n' "$NOW" $(( NOW + 3600 )) > "$WORK/c2.level"
printf 'DRAIN\n%s\n%s\nabc\n' "$NOW" "$BOOT" > "$WORK/c3.level"
printf 'DRAIN\n%s\n' "$NOW" > "$WORK/c4.level"
: > "$WORK/c5.level"
for c in c1 c2 c3 c4 c5; do
  B="$(run_drain "$WORK/$c.level" _drain_window_blocks)"; U="$(run_drain "$WORK/$c.level" _drain_window_unreadable)"
  if [ "$B" = "0" ] && [ "$U" = "1" ]; then ok "D4 $c: blocks=0 unreadable=1"; else bad "D4 $c: esperado blocks=0 unreadable=1, veio blocks=$B unreadable=$U"; fi
done
# o terceiro estado nao colapsa no estado normal
[ "$(run_drain "$WORK/c1.level" _drain_window_unreadable)" != "$(run_drain "$ABS" _drain_window_unreadable)" ] \
  && ok "D4 ilegivel e ausente sao DISTINGUIVEIS" || bad "D4 ilegivel colapsou em ausente"

# ── D5 ─────────────────────────────────────────────────────────────────────
echo "D5: kern.boottime por token exato (armadilha do usec)"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
# formato REAL do macOS, com usec ao lado de sec
[ "$1" = "-n" ] && [ "$2" = "kern.boottime" ] && { echo '{ sec = 1789579812, usec = 958892 } Wed Sep 16 14:30:12 2026'; exit 0; }
exit 1
EOF
chmod +x "$WORK/bin/sysctl"
GOT="$( PATH="$WORK/bin:$PATH" DRAIN_WINDOW_FILE="$ABS" bash -c 'source "'"$QHC"'"; _drain_window_boot_epoch' )"
[ "$GOT" = "1789579812" ] && ok "D5 boot-epoch = 1789579812 (nao 958892 = usec)" || bad "D5 boot-epoch deveria ser 1789579812, veio '$GOT'"
# ponta a ponta com o sysctl de mentira: sinal gravado com o mesmo boot drena
write_sig "$WORK/real.level" DRAIN "$NOW" 1789579812 $(( NOW + 3600 ))
GOT="$( PATH="$WORK/bin:$PATH" DRAIN_WINDOW_FILE="$WORK/real.level" bash -c 'source "'"$QHC"'"; _drain_window_blocks' )"
[ "$GOT" = "1" ] && ok "D5 sinal do mesmo boot (via sysctl) drena" || bad "D5 sinal do mesmo boot deveria drenar, veio '$GOT'"

# ── D6 ─────────────────────────────────────────────────────────────────────
echo "D6: sysctl falha -> nao da pra provar o boot -> nao drena (fail-open), e avisa"
cat > "$WORK/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
GOT="$( PATH="$WORK/bin:$PATH" DRAIN_WINDOW_FILE="$WORK/real.level" bash -c 'source "'"$QHC"'"; _drain_window_blocks' )"
[ "$GOT" = "0" ] && ok "D6 blocks=0 sem boot-epoch" || bad "D6 sem boot-epoch NAO pode drenar, veio '$GOT'"
GOT="$( PATH="$WORK/bin:$PATH" DRAIN_WINDOW_FILE="$WORK/real.level" bash -c 'source "'"$QHC"'"; _drain_window_unreadable' )"
[ "$GOT" = "1" ] && ok "D6 unreadable=1 (nao-consegui-saber fica visivel)" || bad "D6 unreadable deveria ser 1, veio '$GOT'"

# ── override (costura de teste, mesmo formato do QUIET_HOURS_OVERRIDE) ─────
echo "D8: costura DRAIN_WINDOW_OVERRIDE"
[ "$(DRAIN_WINDOW_OVERRIDE=DRAIN run_drain "$ABS" _drain_window_blocks)" = "1" ] && ok "D8 override=DRAIN forca drenar" || bad "D8 override=DRAIN deveria forcar 1"
[ "$(DRAIN_WINDOW_OVERRIDE=OPEN run_drain "$F" _drain_window_blocks)" = "0" ] && ok "D8 override=OPEN forca abrir mesmo com sinal valido" || bad "D8 override=OPEN deveria forcar 0"

# ── D7 ─────────────────────────────────────────────────────────────────────
echo "D7: os 5 despachantes tem o gate do dreno, antes do quiet-hours, com texto proprio"
for d in pilot-dispatcher.sh quality-gate-dispatcher.sh auto-refino-dispatcher.sh refino-gate-dispatcher.sh context-check-dispatcher.sh; do
  DF="$SELF_DIR/$d"
  [ -f "$DF" ] || { bad "D7 $d nao encontrado"; continue; }
  DL=$(grep -n '"$(_drain_window_blocks)" = "1"' "$DF" | head -1 | cut -d: -f1)
  QL=$(grep -n '"$(_quiet_hours_blocks)" = "1"' "$DF" | head -1 | cut -d: -f1)
  if [ -z "$DL" ]; then bad "D7 $d: sem gate _drain_window_blocks"; continue; fi
  if [ -n "$QL" ] && [ "$DL" -lt "$QL" ]; then ok "D7 $d: gate do dreno (L$DL) vem antes do quiet-hours (L$QL)"; else bad "D7 $d: gate do dreno (L$DL) deveria vir ANTES do quiet-hours (L${QL:-?})"; fi
  # o bloco do dreno (do `if` ate o `fi` mais proximo) nao pode herdar a mentira do quiet-hours
  BLK=$(sed -n "${DL},$((DL+12))p" "$DF" | sed '/^fi$/q')
  if printf '%s' "$BLK" | grep -q -i "00h-08h\|retoma as 08h\|janela noturna"; then bad "D7 $d: texto do dreno reaproveita a mensagem do quiet-hours (00h-08h/08h seria FALSO)"; else ok "D7 $d: texto proprio do dreno"; fi
  printf '%s' "$BLK" | grep -q -i "dreno\|drain" && ok "D7 $d: o log cita dreno/drain" || bad "D7 $d: o log do gate nao cita dreno/drain"
done
# Pilot: sem push a cada sweep (o do quiet-hours diz 'retoma as 08h'), mas grava o pause-state p/ o reconciler
PL=$(grep -n '"$(_drain_window_blocks)" = "1"' "$SELF_DIR/pilot-dispatcher.sh" | head -1 | cut -d: -f1)
if [ -n "$PL" ]; then
  PBLK=$(sed -n "${PL},$((PL+12))p" "$SELF_DIR/pilot-dispatcher.sh" | sed '/^fi$/q')
  printf '%s' "$PBLK" | grep -q "notify " && bad "D7 pilot: o dreno NAO pode mandar push a cada sweep" || ok "D7 pilot: sem push no dreno"
  printf '%s' "$PBLK" | grep -q '_pilot_write_sweep_pause_state 1 "drain-window"' && ok "D7 pilot: grava sweep-pause-state (reconciler nao le como falha)" || bad "D7 pilot: deveria gravar _pilot_write_sweep_pause_state 1 \"drain-window\""
else
  bad "D7 pilot: gate do dreno ausente"
fi

echo ""
echo "drain-window-check selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
