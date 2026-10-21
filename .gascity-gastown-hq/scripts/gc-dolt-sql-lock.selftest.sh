#!/usr/bin/env bash
# gc-dolt-sql-lock.selftest.sh (ga-06wmmp) — teste hermético do patch de engine
# docs/pending-engine-window/ga-06wmmp-gc-dolt-sql-respeita-dolt-lock.patch: `gc dolt sql` com o
# servidor fora não abre o data dir em modo embutido enquanto o dolt.lock está preso.
#
# ## Contents
# - O que cobre · Como roda
#
# O que cobre: o run.sh de antes (cópia de examples/bd/dolt/commands/sql/run.sh do gastownhall/gascity
# main, embutida abaixo) abre o dolt embutido mesmo com o lock preso — é o defeito; com o patch aplicado:
# lock preso → recusa (exit 75) sem chamar o dolt; lock livre, arquivo de lock ausente (e o probe não o
# cria), servidor no ar, flock que falha ao sondar e flock ausente → segue como antes (os dois últimos
# com aviso no stderr); GC_DOLT_LOCK_FILE manda no caminho.
#
# Como roda: `dolt` e (num caso) `flock` são falsos num PATH de scratch; o runtime.sh do pacote é um stub
# que define só o que o trecho patchado lê (DOLT_DATA_DIR, PACK_STATE_DIR, managed_runtime_tcp_reachable).
# O lock é preso pelo próprio teste (fd 9 + flock -n). Zero Dolt de verdade. GC_DOLT_SQL_PATCH aponta
# para outro patch (usado por quem roda mutantes).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${GC_DOLT_SQL_PATCH:-$SCRIPT_DIR/../docs/pending-engine-window/ga-06wmmp-gc-dolt-sql-respeita-dolt-lock.patch}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }
check() { # check <descrição> <comando de teste...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else nope "$d"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REL=examples/bd/dolt/commands/sql
mkdir -p "$WORK/old/$REL" "$WORK/new/$REL" "$WORK/pack/assets/scripts" "$WORK/bin" "$WORK/bin-flock2" \
         "$WORK/data/hq/.dolt" "$WORK/state"

# cópia de gastownhall/gascity main (62 linhas), o arquivo que o patch altera
cat > "$WORK/old/$REL/run.sh" <<'RUNSH'
#!/bin/sh
# gc dolt sql — Open a Dolt SQL shell or run a one-shot query.
#
# Connects to the running Dolt server if available, otherwise opens
# in embedded mode using the first database directory found. Trailing
# arguments are forwarded verbatim to `dolt sql`, so non-interactive
# use is supported via `gc dolt sql -q "QUERY"`.
#
# Environment: GC_CITY_PATH, GC_DOLT_HOST, GC_DOLT_PORT, GC_DOLT_USER,
#              GC_DOLT_PASSWORD (all optional except GC_CITY_PATH)
set -e

: "${GC_DOLT_USER:=root}"
PACK_DIR="${GC_PACK_DIR:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
. "$PACK_DIR/assets/scripts/runtime.sh"
data_dir="$DOLT_DATA_DIR"

# Check if the server is reachable.
is_running() {
  if [ -n "$GC_DOLT_HOST" ]; then
    # Remote server — TCP probe.
    (echo > /dev/tcp/"$GC_DOLT_HOST"/"$GC_DOLT_PORT") 2>/dev/null && return 0
    # Fallback: nc/ncat.
    command -v nc >/dev/null 2>&1 && nc -z "$GC_DOLT_HOST" "$GC_DOLT_PORT" 2>/dev/null && return 0
    return 1
  fi
  managed_runtime_tcp_reachable "$GC_DOLT_PORT"
}

if is_running; then
  # Build connection args.
  args=""
  if [ -n "$GC_DOLT_HOST" ]; then
    host="$GC_DOLT_HOST"
  else
    host="127.0.0.1"
  fi
  args="--host $host --port $GC_DOLT_PORT --user $GC_DOLT_USER --no-tls"
  # Always export DOLT_CLI_PASSWORD so dolt's credential parser skips
  # the TTY password prompt. When GC_DOLT_PASSWORD is empty (the
  # managed-local default — root has no password), an unset env var
  # causes `dolt sql -q "..."` to fail with "inappropriate ioctl for
  # device" under non-interactive callers (CI, scripts, automation).
  # Exporting empty satisfies dolt without changing auth outcomes.
  export DOLT_CLI_PASSWORD="${GC_DOLT_PASSWORD:-}"
  exec dolt $args sql "$@"
else
  # Embedded mode — find first database directory.
  if [ ! -d "$data_dir" ]; then
    echo "gc dolt sql: no dolt server running and no databases found" >&2
    exit 1
  fi
  first_db=""
  for d in "$data_dir"/*/; do
    [ -d "$d/.dolt" ] && first_db="$d" && break
  done
  if [ -z "$first_db" ]; then
    echo "gc dolt sql: no dolt server running and no databases found" >&2
    exit 1
  fi
  exec dolt --data-dir "$data_dir" sql "$@"
fi
RUNSH

cat > "$WORK/pack/assets/scripts/runtime.sh" <<'RTSH'
DOLT_DATA_DIR="$GC_DOLT_DATA_DIR"
PACK_STATE_DIR="${GC_PACK_STATE_DIR:-$GC_CITY_PATH/.gc/runtime/packs/dolt}"
managed_runtime_tcp_reachable() { return "${FAKE_TCP_RC:-1}"; }
RTSH
printf '#!/bin/sh\necho "dolt $*" >> "$DOLT_CALLS"\nexit 0\n' > "$WORK/bin/dolt"
printf '#!/bin/sh\nexit 2\n' > "$WORK/bin-flock2/flock"
chmod +x "$WORK/bin/dolt" "$WORK/bin-flock2/flock"

echo "── o patch ──"
if [ -s "$PATCH" ]; then ok "o patch existe ($(basename "$PATCH"))"; else nope "o patch não existe: $PATCH"; fi
cp "$WORK/old/$REL/run.sh" "$WORK/new/$REL/run.sh"
if [ -s "$PATCH" ] && patch -s -p1 -d "$WORK/new" < "$PATCH" >/dev/null 2>&1; then
  ok "o patch aplica no run.sh de antes"
else
  nope "o patch não aplica no run.sh de antes"
fi
check "o run.sh patchado tem sintaxe sh válida" sh -n "$WORK/new/$REL/run.sh"
check "o patch só mexe no ramo embutido (o run.sh de antes continua com o exec embutido)" \
  grep -q 'exec dolt --data-dir "\$data_dir" sql "\$@"' "$WORK/new/$REL/run.sh"

if ! command -v flock >/dev/null 2>&1; then
  echo "── flock não instalado: os casos que prendem o lock não rodam aqui ──"
  nope "flock precisa estar instalado para prender o lock no teste"
  printf '\ngc-dolt-sql-lock.selftest: %s ok, %s FAIL\n' "$PASS" "$FAIL"
  exit 1
fi

LOCK="$WORK/state/dolt.lock"
OUT="$WORK/out"; ERR="$WORK/err"; CALLS="$WORK/dolt.calls"
# run_sql <run.sh> <PATH do caso> [VAR=valor ...] → RC, $OUT, $ERR, $CALLS
run_sql() {
  local script="$1" pathx="$2"; shift 2
  : > "$CALLS"
  env -i PATH="$pathx" HOME="$WORK" GC_PACK_DIR="$WORK/pack" GC_CITY_PATH="$WORK/city" \
    GC_DOLT_DATA_DIR="$WORK/data" GC_PACK_STATE_DIR="$WORK/state" GC_DOLT_HOST= GC_DOLT_PORT=1 \
    DOLT_CALLS="$CALLS" "$@" /bin/sh "$script" -q 'select 1' > "$OUT" 2> "$ERR"
  RC=$?
}
hold_lock() { exec 9>"$1"; flock -n 9; }
drop_lock() { exec 9>&-; }
calls_empty() { [ ! -s "$CALLS" ]; }
calls_have() { grep -q -- "$1" "$CALLS"; }
err_has() { grep -q -- "$1" "$ERR"; }

OLD="$WORK/old/$REL/run.sh"; NEW="$WORK/new/$REL/run.sh"
BASEP="$WORK/bin:/usr/bin:/bin"

echo "── lock preso, servidor fora ──"
: > "$LOCK"; hold_lock "$LOCK"
run_sql "$OLD" "$BASEP"
check "ANTES do patch: abre o dolt embutido mesmo com o dolt.lock preso (o defeito)" calls_have -- '--data-dir'
run_sql "$NEW" "$BASEP"
check "lock preso: recusa com exit 75" test "$RC" = 75
check "lock preso: o dolt não é chamado" calls_empty
check "lock preso: a mensagem diz o caminho do lock" err_has "$LOCK"
check "lock preso: a mensagem diz que não abriu em modo embutido" err_has 'not opened in embedded mode'

echo "── lock preso, servidor no ar ──"
run_sql "$NEW" "$BASEP" FAKE_TCP_RC=0
check "servidor no ar: segue (exit 0) e usa --host, o patch só vale no ramo embutido" bash -c '[ "$1" = 0 ] && grep -q -- "--host" "$2" && ! grep -q -- "--data-dir" "$2"' _ "$RC" "$CALLS"
drop_lock

echo "── lock livre / ausente ──"
run_sql "$NEW" "$BASEP"
check "lock livre (arquivo existe, ninguém segura): abre embutido, exit 0" bash -c '[ "$1" = 0 ] && grep -q -- "--data-dir $2/data sql -q select 1" "$3"' _ "$RC" "$WORK" "$CALLS"
rm -f "$LOCK"
run_sql "$NEW" "$BASEP"
check "sem arquivo de lock: abre embutido, exit 0" bash -c '[ "$1" = 0 ] && grep -q -- "--data-dir" "$2"' _ "$RC" "$CALLS"
check "sem arquivo de lock: o probe não cria o arquivo" test ! -e "$LOCK"

echo "── não sei dizer ──"
: > "$LOCK"; hold_lock "$LOCK"
run_sql "$NEW" "$WORK/bin-flock2:$WORK/bin"
check "flock que falha ao sondar (exit 2): segue como antes" bash -c '[ "$1" = 0 ] && grep -q -- "--data-dir" "$2"' _ "$RC" "$CALLS"
check "flock que falha ao sondar: avisa no stderr" err_has 'cannot probe the dolt lock'
run_sql "$NEW" "$WORK/bin"
check "sem flock no PATH: segue como antes" bash -c '[ "$1" = 0 ] && grep -q -- "--data-dir" "$2"' _ "$RC" "$CALLS"
check "sem flock no PATH: avisa no stderr" err_has 'flock is not installed'
drop_lock

echo "── GC_DOLT_LOCK_FILE ──"
OTHER="$WORK/other.lock"; : > "$OTHER"; hold_lock "$OTHER"
run_sql "$NEW" "$BASEP" GC_DOLT_LOCK_FILE="$OTHER"
check "GC_DOLT_LOCK_FILE preso: recusa com exit 75 (o caminho padrão está livre)" bash -c '[ "$1" = 75 ] && [ ! -s "$2" ]' _ "$RC" "$CALLS"
drop_lock

printf '\ngc-dolt-sql-lock.selftest: %s ok, %s FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
