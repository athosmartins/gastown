#!/usr/bin/env bash
# child-priority-janitor.selftest.sh — drives the REAL subprocess path of child-priority-janitor.py (ga-p7hymz).
#
# `child-priority-janitor.py --selftest` swaps every I/O function for a fake (the seams), so it never runs the
# code that actually calls `bd` / `gc` and parses what they print. This test does: it points BD_BIN / GC_BIN /
# NOTIFY_BIN at stub executables in a scratch dir (ZERO calls reach the live city or the real notifier) and
# makes the stubs FAIL — non-zero exit, garbage, empty output, missing binary, timeout — then checks the
# janitor lands in the INERT state: no `bd update`, no comment, and the failure is visible in the log and the
# exit code. "Could not read" must never turn into "no children" (a skipped store) nor into "raised" (an
# unconfirmed write).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JAN="${CHILD_PRIORITY_JANITOR_PATH:-$HERE/child-priority-janitor.py}"
[ -f "$JAN" ] || { echo "FATAL: janitor not found at $JAN"; exit 1; }
command -v python3 >/dev/null || { echo "FATAL: python3 missing"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/cpj-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
CITY="$W/city"; RIG="$W/rig"; mkdir -p "$CITY" "$RIG"
CALLS="$W/calls"; NOTES="$W/notes"; STATE="$W/prio"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -14; }

# ── stubs ──────────────────────────────────────────────────────────────────────
# bd <-C path> <cmd> ...   one parent "p" (P0) and one child "c" whose priority lives in $STATE.
cat > "$W/bd" <<'STUB'
#!/usr/bin/env bash
cmd="$3"; echo "$cmd|$2|$*" >> "$STUB_CALLS"
emit_list() {
  [ "$2" = "$STUB_HQ" ] || { echo '[]'; return; }
  printf '[{"id":"p","title":"pai","issue_type":"feature","status":"open","priority":0,"labels":[]},{"id":"c","title":"fatia","issue_type":"feature","status":"open","priority":%s,"parent":"p","labels":[]}]\n' "$(cat "$STUB_STATE")"
}
case "$cmd" in
  list)
    case "$STUB_LIST_MODE" in
      ok)         emit_list "$@" ;;
      garbage)    echo 'garbage{{{ not json' ;;
      empty)      : ;;
      rc1_empty)  echo '[]'; exit 1 ;;
      rc1_raise)  emit_list "$@"; exit 1 ;;
      slow)       exec sleep 5 ;;
    esac ;;
  show)
    case "$STUB_SHOW_MODE" in
      ok)      printf '[{"id":"c","issue_type":"feature","status":"open","priority":%s,"parent":"p"}]\n' "$(cat "$STUB_STATE")" ;;
      garbage) echo 'garbage{{{ not json' ;;
      rc1)     exit 1 ;;
    esac ;;
  update)
    case "$STUB_UPDATE_MODE" in
      ok)   while [ $# -gt 0 ]; do [ "$1" = "-p" ] && { echo "$2" > "$STUB_STATE"; break; }; shift; done ;;
      rc1)  exit 1 ;;                 # fails, nothing persisted
      lie)  : ;;                      # exits 0, nothing persisted
    esac ;;
  comment) : ;;
esac
exit 0
STUB
# gc rig list --json
cat > "$W/gc" <<'STUB'
#!/usr/bin/env bash
case "$STUB_GC_MODE" in
  ok)      printf '{"rigs":[{"name":"r1","path":"%s"}]}\n' "$STUB_RIG" ;;
  garbage) echo 'garbage{{{ not json' ;;
  rc1)     exit 1 ;;
esac
exit 0
STUB
cat > "$W/notify" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_NOTES"
STUB
chmod +x "$W/bd" "$W/gc" "$W/notify"

reset() {
  echo 2 > "$STATE"; : > "$CALLS"; : > "$NOTES"
  export STUB_LIST_MODE=ok STUB_UPDATE_MODE=ok STUB_SHOW_MODE=ok STUB_GC_MODE=ok
  export JAN_BD="$W/bd" JAN_GC="$W/gc" JAN_DRY=0 JAN_ENABLED=1 JAN_TIMEOUT=20
}
run() {
  OUT=$(GC_CITY_PATH="$CITY" BD_BIN="$JAN_BD" GC_BIN="$JAN_GC" NOTIFY_BIN="$W/notify" \
        CHILD_PRIORITY_JANITOR_LOCK="$W/lock" CHILD_PRIORITY_JANITOR_BD_TIMEOUT="$JAN_TIMEOUT" \
        CHILD_PRIORITY_JANITOR_DRY_RUN="$JAN_DRY" CHILD_PRIORITY_JANITOR_ENABLED="$JAN_ENABLED" \
        STUB_CALLS="$CALLS" STUB_NOTES="$NOTES" STUB_STATE="$STATE" STUB_HQ="$CITY" STUB_RIG="$RIG" \
        python3 "$JAN" 2>&1); RC=$?
}
n_calls() { grep -c "^$1|" "$CALLS" 2>/dev/null || true; }
prio()    { cat "$STATE"; }
has()     { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
case_()   { echo "-- $1"; reset; }

case_ "controle: pai P0, filha P2, tudo responde -> sobe para P0"
run
if [ "$RC" = 0 ] && [ "$(prio)" = 0 ] && [ "$(n_calls update)" = 1 ] && [ "$(n_calls comment)" = 1 ] && has "RAISED" && ! has "DEGRADED"; then
  ok "sobe P2 -> P0, relê, comenta uma vez, rc 0 (e a loja da rig foi listada)"
else nope "controle falhou (rc=$RC prio=$(prio))"; fi
has "store=r1" && ok "gc rig list válido -> a loja r1 entra na varredura" || nope "loja r1 não apareceu"

case_ "gc rig list com lixo no stdout (rc 0)"
STUB_GC_MODE=garbage run
if has "gc rig list parse" && has "DEGRADED stores" && ! has "Traceback"; then ok "JSON ilegível do gc -> modo degradado visível, sem Traceback"; else nope "gc com lixo não foi tratado"; fi
case_ "gc rig list sai com rc 1"
STUB_GC_MODE=rc1 run
if has "gc rig list failed" && has "DEGRADED stores" && ! has "Traceback"; then ok "gc rc 1 -> modo degradado visível"; else nope "gc rc 1 não foi tratado"; fi
case_ "binário gc inexistente"
JAN_GC="$W/nowhere/gc" run
if has "subprocess failed" && has "DEGRADED stores" && ! has "Traceback"; then ok "gc ausente -> aviso e modo degradado, sem Traceback"; else nope "gc ausente derrubou o sweep"; fi

for mode in garbage empty rc1_empty rc1_raise; do
  case_ "bd list: $mode"
  STUB_LIST_MODE=$mode run
  if [ "$(n_calls update)" = 0 ] && [ "$(n_calls comment)" = 0 ] && [ "$(prio)" = 2 ] && [ "$RC" = 1 ] && has "store skipped" && has "unreadable_stores=2"; then
    ok "bd list '$mode' -> loja pulada e contada (NÃO lida como 'sem filhos'), nada escrito, rc 1"
  else nope "bd list '$mode' não ficou inerte (rc=$RC updates=$(n_calls update) prio=$(prio))"; fi
done

case_ "bd list estoura o tempo"
STUB_LIST_MODE=slow JAN_TIMEOUT=1 run
if [ "$(n_calls update)" = 0 ] && [ "$RC" = 1 ] && has "subprocess failed" && has "store skipped"; then ok "timeout do bd -> loja pulada, nada escrito"; else nope "timeout do bd não ficou inerte (rc=$RC)"; fi

case_ "binário bd inexistente"
JAN_BD="$W/nowhere/bd" run
if [ "$RC" = 1 ] && has "subprocess failed" && has "store skipped" && ! has "Traceback"; then ok "bd ausente -> lojas puladas, rc 1, sem Traceback"; else nope "bd ausente (rc=$RC)"; fi

case_ "bd update sai com rc 1 e não grava"
STUB_UPDATE_MODE=rc1 run
if [ "$RC" = 1 ] && [ "$(prio)" = 2 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "raised=0 failed=1" && [ -s "$NOTES" ]; then
  ok "update rc 1 -> não conta como subida, sem comentário, com alarme"
else nope "update rc 1 contou como feito (rc=$RC)"; fi

case_ "bd update diz rc 0 mas não grava"
STUB_UPDATE_MODE=lie run
if [ "$RC" = 1 ] && [ "$(prio)" = 2 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "raised=0 failed=1" && [ -s "$NOTES" ]; then
  ok "update mentiroso (rc 0, nada gravado) -> a releitura pega: falha contada e alarme"
else nope "update mentiroso passou por feito (rc=$RC)"; fi

for mode in garbage rc1; do
  case_ "releitura (bd show) $mode depois de um update que gravou"
  STUB_SHOW_MODE=$mode run
  if [ "$RC" = 1 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "raised=0 failed=1"; then
    ok "show '$mode' -> sem como confirmar, então NÃO conta nem comenta (falha visível)"
  else nope "show '$mode' contou como confirmado (rc=$RC)"; fi
done

case_ "DRY_RUN=1"
JAN_DRY=1 run
if [ "$RC" = 0 ] && [ "$(n_calls update)" = 0 ] && [ "$(n_calls comment)" = 0 ] && [ "$(prio)" = 2 ] && has "DRY_RUN: would raise"; then
  ok "dry-run lista o que subiria e não escreve nada"
else nope "dry-run escreveu ou não listou (rc=$RC)"; fi

case_ "kill-switch CHILD_PRIORITY_JANITOR_ENABLED=0"
JAN_ENABLED=0 run
if [ "$RC" = 0 ] && [ ! -s "$CALLS" ] && has "kill-switch" && has "start enabled=False"; then
  ok "kill-switch -> nenhuma chamada ao bd, linha de batimento escrita, rc 0"
else nope "kill-switch ainda chamou o bd ou não logou (rc=$RC)"; fi

echo
echo "== child-priority-janitor.selftest.sh: $PASS ok, $FAIL falha(s)"
[ "$FAIL" = 0 ]
