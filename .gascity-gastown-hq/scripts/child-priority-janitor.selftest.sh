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
CITY="$W/city"; RIG="$W/rig"; RIG2="$W/rig2"; mkdir -p "$CITY" "$RIG" "$RIG2"
CALLS="$W/calls"; NOTES="$W/notes"; STATE="$W/prio"; ENVLOG="$W/envlog"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/        | /' | head -14; }

# ── stubs ──────────────────────────────────────────────────────────────────────
# bd <-C path> <cmd> ...   one parent "p" (P0) and one child "c" whose priority lives in $STATE.
cat > "$W/bd" <<'STUB'
#!/usr/bin/env bash
cmd="$3"; echo "$cmd|$2|$*" >> "$STUB_CALLS"
echo "$cmd AUTO_START=${BEADS_DOLT_AUTO_START-<unset>}" >> "$STUB_ENVLOG"
emit_list() {
  [ "$2" = "$STUB_HQ" ] || { echo '[]'; return; }
  printf '[{"id":"p","title":"pai","issue_type":"feature","status":"open","priority":0,"labels":[]},{"id":"c","title":"fatia","issue_type":"feature","status":"open","priority":%s,"parent":"p","labels":[]}]\n' "$(cat "$STUB_STATE")"
}
case "$cmd" in
  list)
    # a store listed in STUB_FAIL_PATHS answers the way a decoy Dolt did (ga-u4z4hwb): rc 1 and the cause on stderr
    case " $STUB_FAIL_PATHS " in *" $2 "*) printf '%s\n' "${STUB_FAIL_ERR-Error: database not found: ${2##*/}}" >&2; exit 1 ;; esac
    case "$STUB_LIST_MODE" in
      ok)         emit_list "$@" ;;
      garbage)    echo 'garbage{{{ not json' ;;
      badutf8)    printf '\200\201\n' ;;
      empty)      : ;;
      rc1_empty)  echo '[]'; exit 1 ;;
      rc1_raise)  emit_list "$@"; exit 1 ;;
      killed)     kill -KILL $$ ;;        # an OOM-killed bd: the parent sees rc -9, which is not 0 and not > 0
      slow)       exec sleep 5 ;;
    esac ;;
  show)
    case "$STUB_SHOW_MODE" in
      ok)      printf '[{"id":"c","issue_type":"feature","status":"open","priority":%s,"parent":"p"}]\n' "$(cat "$STUB_STATE")" ;;
      garbage) echo 'garbage{{{ not json' ;;
      rc1)     echo "Error: show refused" >&2; exit 1 ;;
      rc1_json) printf '[{"id":"c","issue_type":"feature","status":"open","priority":%s,"parent":"p"}]\n' "$(cat "$STUB_STATE")"; exit 1 ;;
    esac ;;
  update)
    case "$STUB_UPDATE_MODE" in
      ok)   while [ $# -gt 0 ]; do [ "$1" = "-p" ] && { echo "$2" > "$STUB_STATE"; break; }; shift; done ;;
      rc1)  echo "Error: update refused" >&2; exit 1 ;;   # fails, nothing persisted
      lie)  : ;;                      # exits 0, nothing persisted
    esac ;;
  comment) [ "$STUB_COMMENT_MODE" = rc1 ] && { echo "Error: comment refused" >&2; exit 1; } ;;
esac
exit 0
STUB
# gc rig list --json
cat > "$W/gc" <<'STUB'
#!/usr/bin/env bash
case "$STUB_GC_MODE" in
  ok)      printf '{"rigs":[{"name":"r1","path":"%s"}]}\n' "$STUB_RIG" ;;
  # `suspended` as `gc rig list --json` reports it (auto-rehome-janitor.py reads the same key); r2 is the active rig
  susp)    printf '{"rigs":[{"name":"r1","path":"%s","suspended":true},{"name":"r2","path":"%s","suspended":false}]}\n' "$STUB_RIG" "$STUB_RIG2" ;;
  suspall) printf '{"rigs":[{"name":"r1","path":"%s","suspended":true},{"name":"r2","path":"%s","suspended":true}]}\n' "$STUB_RIG" "$STUB_RIG2" ;;
  suspstr) printf '{"rigs":[{"name":"r1","path":"%s","suspended":"true"}]}\n' "$STUB_RIG" ;;
  tricky)  printf '{"rigs":["junk",{"name":"hqx","hq":true,"path":"%s"},{"name":"samecity","path":"%s"},{"name":"nopath"},{"name":"nodir","path":"%s/nope"},{"name":"r1","path":"%s"}]}\n' "$STUB_RIG2" "$STUB_HQ" "$STUB_RIG" "$STUB_RIG" ;;
  norigs)  echo '{"rigs":[]}' ;;
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
  echo 2 > "$STATE"; : > "$CALLS"; : > "$NOTES"; : > "$ENVLOG"
  export STUB_LIST_MODE=ok STUB_UPDATE_MODE=ok STUB_SHOW_MODE=ok STUB_GC_MODE=ok STUB_COMMENT_MODE=ok STUB_FAIL_PATHS=
  unset STUB_FAIL_ERR BEADS_DOLT_AUTO_START   # the janitor must be the one that puts AUTO_START in the child's environment
  export JAN_BD="$W/bd" JAN_GC="$W/gc" JAN_DRY=0 JAN_ENABLED=1 JAN_TIMEOUT=20 JAN_LOCK="$W/lock" JAN_MAX=15
}
run() {
  OUT=$(GC_CITY_PATH="$CITY" BD_BIN="$JAN_BD" GC_BIN="$JAN_GC" NOTIFY_BIN="$W/notify" \
        CHILD_PRIORITY_JANITOR_LOCK="$JAN_LOCK" CHILD_PRIORITY_JANITOR_BD_TIMEOUT="$JAN_TIMEOUT" \
        CHILD_PRIORITY_JANITOR_MAX_PER_SWEEP="$JAN_MAX" STUB_RIG2="$RIG2" \
        CHILD_PRIORITY_JANITOR_DRY_RUN="$JAN_DRY" CHILD_PRIORITY_JANITOR_ENABLED="$JAN_ENABLED" \
        STUB_CALLS="$CALLS" STUB_NOTES="$NOTES" STUB_STATE="$STATE" STUB_HQ="$CITY" STUB_RIG="$RIG" STUB_ENVLOG="$ENVLOG" \
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
has "kept=-" && ! has "audit comment failed" && ok "varredura sem nada mantido imprime kept=- e o comentário de auditoria não falha" || nope "kept=- ou aviso de comentário errado"
run
if [ "$RC" = 0 ] && [ "$(n_calls update)" = 1 ] && has "raise=0 kept=already-ok:1"; then ok "segunda varredura sobre o estado corrigido: nada a subir, kept=already-ok:1, rc 0"; else nope "segunda varredura (rc=$RC updates=$(n_calls update))"; fi

case_ "o --selftest embutido (planejador puro + varredura pelas costuras) também passa"
# Este arquivo só dirigia o caminho de subprocesso; o teste unitário que mora no script (skip_reason, plan_raises,
# _prio, _parse_list, run_cycle com as costuras trocadas) nunca rodava aqui, e um mutante no planejador ou nas
# próprias expectativas dele ficava verde (ga-7n003iz).
# vazio → sem a linha 'passed, 0 failed', vermelho; falhou/ilegível → rc != 0 ou uma linha FAIL, vermelho.
OUT=$(python3 "$JAN" --selftest 2>&1); RC=$?
if [ "$RC" = 0 ] && has "passed, 0 failed" && ! has "  FAIL "; then ok "--selftest embutido: rc 0, 0 falhas"; else nope "--selftest embutido não passou (rc=$RC)"; fi

case_ "gc rig list com lixo no stdout (rc 0)"
STUB_GC_MODE=garbage run
if has "gc rig list parse" && has "DEGRADED stores" && ! has "Traceback"; then ok "JSON ilegível do gc -> modo degradado visível, sem Traceback"; else nope "gc com lixo não foi tratado"; fi
case_ "gc rig list sai com rc 1"
STUB_GC_MODE=rc1 run
if has "gc rig list failed" && has "DEGRADED stores" && ! has "Traceback"; then ok "gc rc 1 -> modo degradado visível"; else nope "gc rc 1 não foi tratado"; fi
case_ "gc rig list com entradas esquisitas (texto solto, hq, caminho do city, sem caminho, diretório inexistente)"
STUB_GC_MODE=tricky run
if has "store=r1" && ! has "store=hqx" && ! has "store=samecity" && ! has "store=nopath" && ! has "store=nodir" && ! has "DEGRADED" && ! has "Traceback"; then
  ok "só a rig r1 entra (hq:true, o próprio city, sem caminho, diretório inexistente e texto solto ficam de fora)"
else nope "lista de lojas errada com entradas esquisitas"; fi
case_ "gc rig list sem nenhuma rig além do HQ"
STUB_GC_MODE=norigs run
if has "DEGRADED stores" && ! has "Traceback"; then ok "só o HQ -> lista de lojas indeterminada, modo degradado visível"; else nope "gc sem rigs não caiu no modo degradado"; fi
case_ "binário gc inexistente"
JAN_GC="$W/nowhere/gc" run
if has "subprocess failed" && has "DEGRADED stores" && ! has "Traceback"; then ok "gc ausente -> aviso e modo degradado, sem Traceback"; else nope "gc ausente derrubou o sweep"; fi

for mode in garbage badutf8 empty rc1_empty rc1_raise; do
  case_ "bd list: $mode"
  STUB_LIST_MODE=$mode run
  if [ "$(n_calls update)" = 0 ] && [ "$(n_calls comment)" = 0 ] && [ "$(prio)" = 2 ] && [ "$RC" = 1 ] && has "store skipped" && has "unreadable_stores=2" && { [ "$mode" != badutf8 ] || has "UnicodeDecodeError"; }; then
    ok "bd list '$mode' -> loja pulada e contada (NÃO lida como 'sem filhos'), nada escrito, rc 1"
  else nope "bd list '$mode' não ficou inerte (rc=$RC updates=$(n_calls update) prio=$(prio))"; fi
done

case_ "bd list estoura o tempo"
STUB_LIST_MODE=slow JAN_TIMEOUT=1 run
if [ "$(n_calls update)" = 0 ] && [ "$RC" = 1 ] && has "subprocess failed" && has "store skipped"; then ok "timeout do bd -> loja pulada, nada escrito"; else nope "timeout do bd não ficou inerte (rc=$RC)"; fi

case_ "binário bd inexistente"
JAN_BD="$W/nowhere/bd" run
if [ "$RC" = 1 ] && has "subprocess failed" && has "'list'] (" && has "store skipped" && ! has "Traceback"; then ok "bd ausente -> lojas puladas, rc 1, sem Traceback, o aviso nomeia só as 4 primeiras palavras do comando"; else nope "bd ausente (rc=$RC)"; fi

case_ "bd update sai com rc 1 e não grava"
STUB_UPDATE_MODE=rc1 run
if [ "$RC" = 1 ] && [ "$(prio)" = 2 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "update_ok=False" && has "raised=0 failed=1" && [ -s "$NOTES" ]; then
  ok "update rc 1 -> não conta como subida, sem comentário, com alarme, update_ok=False no log"
else nope "update rc 1 contou como feito (rc=$RC)"; fi

case_ "bd update diz rc 0 mas não grava"
STUB_UPDATE_MODE=lie run
if [ "$RC" = 1 ] && [ "$(prio)" = 2 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "raised=0 failed=1" && [ -s "$NOTES" ]; then
  ok "update mentiroso (rc 0, nada gravado) -> a releitura pega: falha contada e alarme"
else nope "update mentiroso passou por feito (rc=$RC)"; fi

for mode in garbage rc1 rc1_json; do
  case_ "releitura (bd show) $mode depois de um update que gravou"
  STUB_SHOW_MODE=$mode run
  if [ "$RC" = 1 ] && [ "$(n_calls comment)" = 0 ] && has "NOT confirmed" && has "raised=0 failed=1"; then
    ok "show '$mode' -> sem como confirmar, então NÃO conta nem comenta (falha visível)"
  else nope "show '$mode' contou como confirmado (rc=$RC)"; fi
done

# ── ga-u4z4hwb: o motivo da falha no log, rigs suspensas, BEADS_DOLT_AUTO_START ────────────────────────────────
# Em 23/11 23:43, no reboot, um `bd` sob o launchd (sem esta variável) subiu um Dolt isca para três rigs com redirect (gastown, lexbh, marketing); ele
# respondia "database not found" a todo job que lia essas rigs, e o janitor saía 1 com o log dizendo só "failed/unreadable": o motivo estava no stderr do bd.
case_ "BEADS_DOLT_AUTO_START: todo filho bd nasce com 0, mesmo partindo de um ambiente sem a variável"
# vazio → o stub registra '<unset>' (o janitor não passou nada), vermelho; falhou → algum filho com valor diferente de 0, vermelho.
run
if [ "$RC" = 0 ] && [ -s "$ENVLOG" ] && ! grep -qv 'AUTO_START=0$' "$ENVLOG" \
   && grep -q '^list ' "$ENVLOG" && grep -q '^update ' "$ENVLOG" && grep -q '^show ' "$ENVLOG" && grep -q '^comment ' "$ENVLOG"; then
  ok "list, update, show e comment recebem AUTO_START=0 (o bd nunca sobe um Dolt por conta própria a partir daqui)"
else nope "algum filho bd sem AUTO_START=0: $(sort -u "$ENVLOG" | tr '\n' ';')"; fi
case_ "BEADS_DOLT_AUTO_START=1 herdado do ambiente não vence"
BEADS_DOLT_AUTO_START=1 run
if [ "$RC" = 0 ] && [ -s "$ENVLOG" ] && ! grep -qv 'AUTO_START=0$' "$ENVLOG"; then
  ok "ambiente com AUTO_START=1 -> o filho ainda recebe 0 (o janitor força o valor, não usa o que veio)"
else nope "AUTO_START=1 herdado chegou ao bd: $(sort -u "$ENVLOG" | tr '\n' ';')"; fi
case_ "DRY_RUN=1 também roda o bd list: o AUTO_START=0 vale ali também"
JAN_DRY=1 run
if [ "$RC" = 0 ] && [ -s "$ENVLOG" ] && ! grep -qv 'AUTO_START=0$' "$ENVLOG" && grep -q '^list ' "$ENVLOG" && [ "$(n_calls update)" = 0 ]; then
  ok "dry-run: só o list roda (nada é escrito) e já leva AUTO_START=0"
else nope "dry-run sem AUTO_START=0: $(sort -u "$ENVLOG" | tr '\n' ';')"; fi

case_ "loja ATIVA ilegível: o log traz a causa e o rc é 1 mesmo com uma subida feita"
STUB_FAIL_PATHS="$RIG" run
if [ "$RC" = 1 ] && [ "$(prio)" = 0 ] \
   && has "WARN: bd list failed/unreadable in r1 — store skipped (NOT read as 'no children'): bd list rc=1: Error: database not found: rig" \
   && has "raised=1 failed=0 unreadable_stores=1 (active=1 suspended=0)"; then
  ok "r1 ativa falha com 'database not found': a causa está no log, o HQ subiu P2 -> P0 e o rc é 1 (loja não lida nunca vira 'sem filhas', nem com outra loja bem-sucedida)"
else nope "loja ativa ilegível (rc=$RC prio=$(prio))"; fi

case_ "rig SUSPENSA ilegível sozinha: rc 0, motivo no log, o resto da varredura segue"
STUB_GC_MODE=susp STUB_FAIL_PATHS="$RIG" run
if [ "$RC" = 0 ] && [ "$(prio)" = 0 ] \
   && has "WARN: bd list failed/unreadable in r1 (rig SUSPENDED) — store skipped, not counted toward the exit code: bd list rc=1: Error: database not found: rig" \
   && has "unreadable_stores=1 (active=0 suspended=1)" && has "store=r2 open=0"; then
  ok "r1 suspensa falha: aviso com a causa e a marca SUSPENDED, rc 0; o HQ subiu e a r2 (ativa) foi lida"
else nope "rig suspensa ilegível sozinha (rc=$RC prio=$(prio))"; fi

case_ "rig suspensa e rig ativa ilegíveis juntas: a ativa decide, rc 1"
STUB_GC_MODE=susp STUB_FAIL_PATHS="$RIG $RIG2" run
if [ "$RC" = 1 ] && has "unreadable_stores=2 (active=1 suspended=1)" && has "in r1 (rig SUSPENDED)" && has "in r2 — store skipped (NOT read as 'no children')"; then
  ok "r1 suspensa + r2 ativa falham: cada uma com a sua marca no log, rc 1 pela ativa"
else nope "suspensa + ativa ilegíveis (rc=$RC)"; fi

case_ "o HQ ilegível nunca é tratado como suspenso: com todas as rigs suspensas o rc ainda é 1"
STUB_GC_MODE=suspall STUB_FAIL_PATHS="$CITY $RIG $RIG2" run
if [ "$RC" = 1 ] && has "unreadable_stores=3 (active=1 suspended=2)" && has "in hq — store skipped (NOT read as 'no children')"; then
  ok "HQ + 2 rigs suspensas ilegíveis: só o HQ conta como ativo, rc 1"
else nope "HQ ilegível com as rigs suspensas (rc=$RC)"; fi

case_ "\"suspended\": \"true\" (texto, não booleano) não vale como suspensa"
STUB_GC_MODE=suspstr STUB_FAIL_PATHS="$RIG" run
if [ "$RC" = 1 ] && has "unreadable_stores=1 (active=1 suspended=0)" && ! has "SUSPENDED"; then
  ok "só true de verdade isenta: o texto 'true' deixa a rig ativa, rc 1"
else nope "suspended como texto (rc=$RC)"; fi

case_ "rig suspensa LEGÍVEL é varrida como qualquer outra"
STUB_GC_MODE=susp run
if [ "$RC" = 0 ] && has "store=r1 open=0" && has "store=r2 open=0" && has "unreadable_stores=0 (active=0 suspended=0)" && ! has "SUSPENDED"; then
  ok "suspensa não é pulada: a r1 é lida, nenhum aviso, rc 0"
else nope "rig suspensa legível (rc=$RC)"; fi

case_ "a causa no log é uma linha só, espremida e cortada em 300 caracteres"
A=$(printf 'A%.0s' $(seq 250)); B=$(printf 'B%.0s' $(seq 250)); EXP="$A $(printf 'B%.0s' $(seq 49))"
STUB_FAIL_PATHS="$RIG" STUB_FAIL_ERR="$A
$B" run
if has "bd list rc=1: $EXP" && ! has "bd list rc=1: ${EXP}B" && [ "$(printf '%s\n' "$OUT" | grep -c 'unreadable in r1')" = 1 ] && ! printf '%s\n' "$OUT" | grep -q '^B'; then
  ok "stderr de duas linhas e 501 caracteres -> uma linha só com exatamente 300 (250 A, espaço, 49 B)"
else nope "causa não ficou numa linha de 300 caracteres"; fi
case_ "stderr vazio: o log diz '(empty stderr)' em vez de deixar o buraco"
STUB_FAIL_PATHS="$RIG" STUB_FAIL_ERR= run
if has "in r1 — store skipped (NOT read as 'no children'): bd list rc=1: (empty stderr)"; then ok "rc 1 sem stderr -> '(empty stderr)'"; else nope "stderr vazio sem marca"; fi

for spec in "garbage|bd list rc=0 but stdout is not a JSON list: garbage{{{ not json" \
            "empty|bd list rc=0 but stdout is not a JSON list: (empty)" \
            "rc1_empty|bd list rc=1: (empty stderr)" \
            "killed|bd list rc=-9: (empty stderr)" \
            "badutf8|bd list did not run (see the subprocess WARN above)"; do
  mode=${spec%%|*}; want=${spec#*|}
  case_ "bd list '$mode': a causa certa aparece no log"
  STUB_LIST_MODE=$mode run
  if has "store skipped (NOT read as 'no children'): $want"; then ok "'$mode' -> $want"; else nope "'$mode' sem a causa esperada ($want)"; fi
done
case_ "bd list estoura o tempo: a causa diz que não rodou"
STUB_LIST_MODE=slow JAN_TIMEOUT=1 run
if has "store skipped (NOT read as 'no children'): bd list did not run (see the subprocess WARN above)" && has "subprocess failed"; then ok "timeout -> 'did not run' ao lado do aviso do subprocesso"; else nope "timeout sem a causa"; fi

case_ "gc rig list falha (modo degradado): o HQ não-lido vale como ATIVO e o rc é 1"
# Sem a lista de rigs ninguém diz quem está suspenso: o HQ e as lojas de reserva nunca ganham a isenção.
STUB_GC_MODE=rc1 STUB_FAIL_PATHS="$CITY" run
if [ "$RC" = 1 ] && has "DEGRADED stores" && has "in hq — store skipped (NOT read as 'no children')" && has "unreadable_stores=1 (active=1 suspended=0)"; then
  ok "gc rc 1 + HQ ilegível -> modo degradado, HQ ativo, rc 1"
else nope "HQ ilegível em modo degradado (rc=$RC)"; fi

case_ "bd update que falha diz a causa no log"
STUB_UPDATE_MODE=rc1 run
if has "WARN: bd update rc=1: Error: update refused (c)" && [ "$RC" = 1 ]; then ok "update rc 1 -> 'bd update rc=1: Error: update refused (c)'"; else nope "update sem causa (rc=$RC)"; fi
case_ "bd show (a releitura) que falha diz a causa no log"
STUB_SHOW_MODE=rc1 run
if has "WARN: bd show rc=1: Error: show refused (c)" && [ "$RC" = 1 ]; then ok "show rc 1 -> 'bd show rc=1: Error: show refused (c)'"; else nope "show sem causa (rc=$RC)"; fi
case_ "bd comment que falha diz a causa no log"
STUB_COMMENT_MODE=rc1 run
if has "WARN: bd comment rc=1: Error: comment refused (c)" && has "audit comment failed" && [ "$RC" = 0 ]; then ok "comment rc 1 -> a causa vem antes do aviso de auditoria; a subida confirmada vale, rc 0"; else nope "comment sem causa (rc=$RC)"; fi

case_ "DRY_RUN=1"
JAN_DRY=1 run
if [ "$RC" = 0 ] && [ "$(n_calls update)" = 0 ] && [ "$(n_calls comment)" = 0 ] && [ "$(prio)" = 2 ] && has "DRY_RUN: would raise"; then
  ok "dry-run lista o que subiria e não escreve nada"
else nope "dry-run escreveu ou não listou (rc=$RC)"; fi

case_ "bd comment sai com rc 1 depois de uma subida confirmada"
STUB_COMMENT_MODE=rc1 run
if [ "$RC" = 0 ] && [ "$(prio)" = 0 ] && has "RAISED" && has "audit comment failed"; then ok "comentário de auditoria falhou -> a subida vale (confirmada na releitura), o aviso aparece, rc 0"; else nope "comentário com rc 1 (rc=$RC prio=$(prio))"; fi

case_ "teto por varredura: MAX_PER_SWEEP=0 adia a subida e avisa com prioridade 3"
JAN_MAX=0 run
if [ "$RC" = 0 ] && [ "$(n_calls update)" = 0 ] && [ "$(prio)" = 2 ] && has "MAX_PER_SWEEP=0 reached" && grep -q -- "-p 3 child-priority-janitor bateu o teto de 0" "$NOTES"; then
  ok "teto 0 -> nenhuma subida, aviso do teto no notificador com prioridade 3"
else nope "teto por varredura (rc=$RC updates=$(n_calls update))"; fi

case_ "o diretório do lock é um arquivo (o lock não pode ser criado)"
: > "$W/afile"
JAN_LOCK="$W/afile/lock" run
if [ "$RC" = 1 ] && [ ! -s "$CALLS" ] && has "cannot take the lock"; then ok "lock inviável -> rc 1 e nenhuma chamada ao bd (nunca roda sem guarda)"; else nope "lock inviável (rc=$RC)"; fi

case_ "in-process: limites do planejador, costuras de I/O, lock e o contador do próprio --selftest"
# Fora do alcance de qualquer caso: os mutantes que trocam uma FIXTURE ou uma ASSERÇÃO dentro do próprio _selftest embutido (o teste continua verdadeiro para o valor
# trocado: "filha mais urgente não desce" vale com o pai em P2 ou em P3) e o `<` -> `<=` de ptarget em plan_raises (atribui o mesmo valor, 51343d2b3a). O flush=True do
# _log (5847500c1c) NÃO é equivalente: o caso de SIGKILL logo depois do start (o último deste arquivo) o mata; um buffer que ninguém esvaziou só aparece quando o processo morre sem a saída normal.
# vazio → sem a linha 'DONE 0', vermelho; falhou/ilegível → uma linha FAIL ou rc != 0, vermelho.
# EQUIVALENT 51343d2b3a: `<` -> `<=` de ptarget em plan_raises: atribui o mesmo valor
# EQUIVALENT 05d88c954b 093deb0e89 0ff72cbd15 11daa9e4a1 146c3071a3 1547231b81 15ba0348a7 246287f518 250b29933b 251c9d90c3 283f7af2fd 2a2530754f: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
# EQUIVALENT 2e3e4f09e5 36e4b8b9d6 3c85db7649 3cf36ddf6f 3cf633b500 3ffbc9973e 4468e98ace 4f3cc44912 4f6ebd57a5 5178ea198c 5334adbf0e 5b677359c9: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
# EQUIVALENT 5baa42cdce 603669880c 605ff672ef 61d41129e3 688a1ef25f 6b2e22a092 6cce0a0f57 6cfe3d2569 6d323c5a73 730a4e8abc 7457c01d5b 746de8e06a: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
# EQUIVALENT 7693b41cef 78651a9943 7df3cb4781 811019242a 84ed7f8bb4 862d31bda4 965ac0e61d 99582b3abe 9bccec5c2c a12fe42def a2d1a56914 a74224fa12: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
# EQUIVALENT ad726e3038 adf6e09e62 be82125e00 c29ce79692 c5ca9535a2 c864890e75 cdc493dca7 cf732d7e15 cfaf17b7ff cfc8f44760 d73126b390 d7f628797d: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
# EQUIVALENT d8a8edda93 dd32fe1d84 e6990befa5 e728bdf8f8 e780a985bb f0167ff049 f17847c3c6 f2db5ca529 f63fcb95be fa7acce942: TRANSITORIO: mutante de dentro do `_selftest()` embutido (L364-533) que o hq-mutate.py novo ja nao gera (confira com `hq-mutate.py gen`); sai do estado quando o motor varrer o janitor de novo, e entao esta linha pode ser apagada
cat > "$W/blk.py" <<'PY'
import contextlib, fcntl, importlib.util, io, os, sys, tempfile
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("jan", sys.argv[1])
j = importlib.util.module_from_spec(spec)
spec.loader.exec_module(j)
bad = []

def chk(name, got, want):
    if got != want:
        bad.append(name)
        print("FAIL %s: want %r got %r" % (name, want, got))

def quiet(fn, *a):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        try:
            r = fn(*a)
        except Exception as e:
            r = "raised %s" % type(e).__name__
    return r, buf.getvalue()

def rec(i, prio, parent=None):
    d = {"id": i, "issue_type": "task", "status": "open", "priority": prio, "labels": [], "title": "t"}
    if parent is not None:
        d["parent"] = parent
    return d

def chain(n):  # a00 is the leaf, the last bead is the P0 root, every other bead is P4
    return [rec("a%02d" % i, 0 if i == n - 1 else 4, "a%02d" % (i + 1) if i < n - 1 else None) for i in range(n)]

chk("_prio: 0 and 4 are priorities, -1 and 5 are not", [j._prio(v) for v in (-1, 0, 4, 5)], [None, 0, 4, None])
chk("_prio: bool, text and None are not priorities", [j._prio(v) for v in (True, "1", None)], [None, None, None])
chk("a chain 13 levels deep still reaches the root: the leaf is raised",
    "a00" in [c["id"] for c in j.plan_raises(chain(13))[0]], True)
chk("a chain 14 levels deep is cut at MAX_DEPTH: the leaf is left alone",
    "a00" in [c["id"] for c in j.plan_raises(chain(14))[0]], False)
chk("a parent that is '' or not a string is no parent: nothing planned and nothing counted",
    [j.plan_raises([rec("c", 2, p)]) for p in ("", 5)], [([], {}), ([], {})])

seen = []
j._notify_fn = lambda m, p: seen.append((m, p))
j._notify("m")
j._notify_fn = None
chk("_notify without a priority sends 3", seen, [("m", 3)])
calls = []
j._sh = lambda args, timeout: calls.append((args, timeout))
j.DRY_RUN = False
j._notify("hi", 2)
chk("_notify runs the notifier argv with a 15 s timeout",
    calls, [([j.NOTIFY_BIN, "-t", "child-priority-janitor", "-p", "2", "hi"], 15)])

here = tempfile.mkdtemp(prefix="cpj-blk.", dir=sys.argv[2])
j._stores_fn = lambda: None
j._STATIC_FALLBACK_RIG_STORES = [("here", here), ("gone", here + "/nope")]
paths = []
j._sh = lambda args, timeout: paths.append(args[2])
quiet(j.run_cycle)
chk("degraded sweep: HQ plus only the static stores whose directory exists", paths, [j.CITY, here])
paths = []
j._list_fn = lambda p: paths.append(p)
quiet(j.run_cycle)
chk("degraded sweep with the list seam on: every static store is listed", paths, [j.CITY, here, here + "/nope"])
j._list_fn = None
j._stores_fn = None

run_cycle = j.run_cycle
j.ENABLED = True
j.LOCK_PATH = sys.argv[2] + "/blk.lock"
holder = open(j.LOCK_PATH, "w")
fcntl.flock(holder, fcntl.LOCK_EX | fcntl.LOCK_NB)
j.run_cycle = lambda: (_ for _ in ()).throw(AssertionError("swept under a held lock"))
rc, out = quiet(j.main)
chk("lock held by another instance: main returns 0 and does not sweep", (rc, "another instance holds the lock" in out), (0, True))
holder.close()
open(sys.argv[2] + "/blk.afile", "w").close()
j.LOCK_PATH = sys.argv[2] + "/blk.afile/lock"
rc, out = quiet(j.main)
chk("lock cannot be created: main returns 1 and does not sweep", (rc, "cannot take the lock" in out), (1, True))
j.run_cycle = run_cycle

rc, out = quiet(j._selftest)
n_ok = len([l for l in out.splitlines() if l.startswith("  ok   ")])
chk("embedded selftest is green", rc, 0)
chk("its summary counts exactly the ok lines it printed", "%d passed, 0 failed" % n_ok in out, True)
plan_raises = j.plan_raises
j.plan_raises = lambda recs: ([], {})
rc, out = quiet(j._selftest)
n_fail = len([l for l in out.splitlines() if l.startswith("  FAIL ")])
chk("embedded selftest returns 1 when the planner is wrong", rc, 1)
chk("...and counts each failed check", n_fail > 0 and ", %d failed" % n_fail in out, True)
j.plan_raises = plan_raises

print("DONE %d" % len(bad))
PY
OUT=$(python3 "$W/blk.py" "$JAN" "$W" 2>&1); RC=$?
if [ "$RC" = 0 ] && has "DONE 0"; then ok "limites, costuras, lock e contador do --selftest no valor exato"; else nope "bloco in-process (rc=$RC)"; fi

case_ "kill-switch CHILD_PRIORITY_JANITOR_ENABLED=0"
JAN_ENABLED=0 run
if [ "$RC" = 0 ] && [ ! -s "$CALLS" ] && has "kill-switch" && has "start enabled=False"; then
  ok "kill-switch -> nenhuma chamada ao bd, linha de batimento escrita, rc 0"
else nope "kill-switch ainda chamou o bd ou não logou (rc=$RC)"; fi

case_ "SIGKILL logo depois da linha de start: ela já está no .out (o flush=True do _log; o daemon-presence-watchdog lê o .out do launchd como batimento)"
# O gc de mentira mata o PAI (o janitor) com SIGKILL na 1ª chamada, antes de o Python poder esvaziar o buffer do stdout: sem o flush=True do _log a linha de start morre
# junto com o processo (5847500c1c). PYTHONUNBUFFERED fica vazio de propósito: ligado, o buffer não existe e o caso não veria nada.
# vazio → saída sem a linha de start (o buffer morreu com o processo), vermelho; falhou → rc diferente de 137 (o stub não matou o janitor), vermelho.
cat > "$W/gc-kill" <<'STUB'
#!/usr/bin/env bash
[ "$PPID" = "$STUB_HARNESS" ] || kill -KILL "$PPID"
exit 0
STUB
chmod +x "$W/gc-kill"
JAN_GC="$W/gc-kill" PYTHONUNBUFFERED= STUB_HARNESS=$$ run 2>/dev/null
if [ "$RC" = 137 ] && has "[child-priority] start enabled=True" && ! has "sweep done"; then
  ok "gc que mata o janitor (SIGKILL) na 1ª chamada: rc 137 e a linha de start já estava no .out"
else nope "SIGKILL depois do start (rc=$RC): a linha de start sumiu com o buffer, ou o stub não matou o janitor"; fi

echo
echo "== child-priority-janitor.selftest.sh: $PASS ok, $FAIL falha(s)"
[ "$FAIL" = 0 ]
