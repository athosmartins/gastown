#!/bin/bash
# git-loose-repack.selftest.sh (ga-pmu761v) — git-loose-repack.sh, its order file, and the incident it exists for, against REAL throwaway git repos.
#
# ## Contents
#   fixtures · stubs · cases t_* (S1..S23) · order/static checks · mutants (each must make a named case FAIL)
#
# Hermetic: every repo, state file, log, lock, the heavy-guard stub, the notify stub and the git wrapper live under one temp dir. The real repos, state, log, lock and notify are never touched
# (GLR_* seams). Repos hold ~16KB blobs and use a limit of 100 KiB, so the same paths run in seconds that run on GiB in production. The free-disk and swap readings are SCRIPTED per reading
# (GLR_FREE_KIB_CMD / GLR_SWAP_MB_CMD read line N of a file), and the stand-in "repack" waits for a number of readings instead of sleeping — so the watchdog cases do not depend on the clock.
# What is NOT tested here: the first night on the real repos (loose 674 MiB WA, 430 MiB ~/gt) — the bead's "1st night log line" can only be seen after the order has run live.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$HERE/../.." && pwd)"                       # .../packs/town-deltas
CITY_ROOT="$(cd "$PACK/../.." && pwd)"                  # .../.gascity-gastown-hq
SCRIPT_REAL="$HERE/git-loose-repack.sh"
SCRIPT="$SCRIPT_REAL"
LIB="$HERE/jsonl-archive-repack-window-lib.sh"
ORDER="$PACK/orders/git-loose-repack.toml"

# a battery that builds git repos must not start on a disk under the heavy floor (heavy-guard.sh: 75 low / 76 unreadable); a missing guard is a broken tree, loud (127), not skipped
"$CITY_ROOT/scripts/heavy-guard.sh" --check --what "git-loose-repack.selftest.sh" || exit $?

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $1"; }     # a check that did NOT run — counted apart, never a PASS

WORK="$(mktemp -d /tmp/glr-st.XXXXXX)"
# the selftest's OWN temp dir (created above, name checked) — same cleanup the sibling selftests do; fixtures hold .git dirs, which safe-clean refuses by design
trap 'case "$WORK" in /tmp/glr-st.*) chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK" ;; esac' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # a developer's ~/.gitconfig must not change what is tested
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
NC=0; CASE=""; REPOS=""; OUT=""; RC=0; ARGS=""

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# mkrepo <dir> <n>: n commits, each adds one ~16KB incompressible file → n*3 loose objects. Auto-maintenance is OFF for the commits (-c), or git's own sampling would pack a fixture mid-build.
mkrepo() {
  local d="$1" n="$2" i
  git init -q "$d"
  for i in $(seq 1 "$n"); do
    head -c 16000 /dev/urandom > "$d/f$i.bin"
    git -C "$d" add "f$i.bin" && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "c$i"
  done
}
# addcommits <dir> <n>: n more commits with new files → loose objects again
addcommits() {
  local d="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    head -c 16000 /dev/urandom > "$d/g$RANDOM$i.bin"
    git -C "$d" add -A . && git -C "$d" -c maintenance.auto=false -c gc.auto=0 commit -q -m "more $i"
  done
}
loose_kib() { git -C "$1" count-objects -v | awk '/^size:/{print $2}'; }
loose_cnt() { git -C "$1" count-objects -v | awk '/^count:/{print $2}'; }

mkrepo "$WORK/tpl8" 8
mkrepo "$WORK/tpl1" 1
K8="$(loose_kib "$WORK/tpl8")"; K1="$(loose_kib "$WORK/tpl1")"
case "$K8" in ''|*[!0-9]*) echo "FATAL: cannot measure the fixture ($K8)"; exit 2 ;; esac

# ── stubs ────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/hg-stub" <<'EOF'
#!/bin/bash
# stand-in for heavy-guard.sh: logs its arguments, answers by $HG_MODE (pass | 75 | 76 | rc:N), else runs the command after `--`
echo "$*" >> "$GLR_CASE/hg.args"
case "${HG_MODE:-pass}" in
  75|76) echo "heavy-guard stub: refused (${HG_MODE})"; exit "$HG_MODE" ;;
  rc:*) exit "${HG_MODE#rc:}" ;;
esac
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
exec "$@"
EOF
cat > "$WORK/bin/notify-stub" <<'EOF'
#!/bin/bash
# stand-in for the real notify: logs its arguments AND the two env switches its contract turns on, exits $NOTIFY_STUB_RC (default 0); NOTIFY_STUB_STDIN=1 makes it read its stdin to the end
[ "${NOTIFY_STUB_STDIN:-0}" = 1 ] && cat >/dev/null
echo "$* FORCE=${NOTIFY_FORCE_PUSH:-} STRICT=${NOTIFY_STRICT_EXIT:-}" >> "$GLR_CASE/notify.log"
exit "${NOTIFY_STUB_RC:-0}"
EOF
cat > "$WORK/bin/gitw" <<'EOF'
#!/bin/bash
# git wrapper: logs every call, then behaves by $GITW_* switches, else is git
echo "$*" >> "$GLR_CASE/git.args"
verb=""
for a in "$@"; do case "$a" in count-objects|repack) verb="$a"; break ;; esac; done
bump() { local n; n="$(cat "$GLR_CASE/$1.n" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$GLR_CASE/$1.n"; echo "$n"; }
case "$verb" in
  count-objects)
    n="$(bump count)"
    [ "${GITW_STDIN:-0}" = 1 ] && cat >/dev/null     # a git that reads its stdin to the end: it must not be able to eat the script's list of repos
    [ -n "${GITW_COUNT_SLEEP:-}" ] && sleep "$GITW_COUNT_SLEEP"
    [ "${GITW_COUNT_FAIL:-0}" = 1 ] && { echo "fatal: simulated failure" >&2; exit 1; }
    [ -n "${GITW_COUNT_FAIL_NTH:-}" ] && [ "$n" = "$GITW_COUNT_FAIL_NTH" ] && { echo "fatal: simulated failure #$n" >&2; exit 1; }
    [ "${GITW_COUNT_GARBLE:-0}" = 1 ] && { echo "garbage"; exit 0; }
    [ "${GITW_COUNT_EMPTY:-0}" = 1 ] && exit 0
    [ "${GITW_COUNT_PARTIAL:-0}" = 1 ] && { printf 'count: 0\nsize: 0\n'; exit 3; }
    ;;
  repack)
    bump repack >/dev/null
    echo $$ > "$GLR_CASE/wrapper.pid"
    [ -n "${GITW_REPACK_RC:-}" ] && exit "$GITW_REPACK_RC"
    [ "${GITW_REPACK_NOOP:-0}" = 1 ] && exit 0
    if [ -n "${GITW_REPACK_WAIT_POLLS:-}" ]; then     # stay "running" until the script has taken that many free-disk readings (30 s ceiling)
      i=0
      while [ "$i" -lt 300 ]; do
        c="$(cat "$GLR_CASE/free.n" 2>/dev/null || echo 0)"
        [ "$c" -ge "$GITW_REPACK_WAIT_POLLS" ] && break
        sleep 0.1; i=$((i+1))
      done
    fi
    ;;
esac
git "$@"; rc=$?
[ "$verb" = repack ] && echo done > "$GLR_CASE/repack.done"
exit $rc
EOF
cat > "$WORK/bin/seq-reader" <<'EOF'
#!/bin/bash
# prints line N of $GLR_CASE/$1.seq (N = this reading's number, kept in $1.n); beyond the last line it repeats the last one
f="$GLR_CASE/$1.seq"; n="$(cat "$GLR_CASE/$1.n" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$GLR_CASE/$1.n"
line="$(sed -n "${n}p" "$f")"; [ -n "$line" ] || line="$(tail -n 1 "$f")"
printf '%s\n' "$line"
EOF
printf '#!/bin/bash\nexec "%s/seq-reader" free\n' "$WORK/bin" > "$WORK/bin/freecmd"
printf '#!/bin/bash\nexec "%s/seq-reader" swap\n' "$WORK/bin" > "$WORK/bin/swapcmd"
chmod +x "$WORK"/bin/*

# ── harness ──────────────────────────────────────────────────────────────────────────────────────
# newcase: a fresh directory with scripted readings (plenty of disk, little swap) and no state
newcase() {
  NC=$((NC+1)); CASE="$WORK/c$NC"; mkdir -p "$CASE/root" "$CASE/city"
  echo 50000000 > "$CASE/free.seq"; echo 100 > "$CASE/swap.seq"; REPOS=""; ARGS=""
}
# repo8 / repo1: a copy of the fixture as this case's one repo (REPOS)
repo8() { cp -R "$WORK/tpl8" "$CASE/repo"; REPOS="$CASE/repo"; }
repo1() { cp -R "$WORK/tpl1" "$CASE/repo"; REPOS="$CASE/repo"; }

# mkenv: the seams for THIS case (read at call time: CASE, REPOS) in ENVV; envrun [VAR=val ...] runs the script under them, later assignments win
mkenv() {
  ENVV=(GLR_CASE="$CASE" GC_CITY_PATH="$CASE/city" JAW_HOUR=2 JAW_FREE_KIB=50000000
    GLR_ROOT="$CASE/root" GLR_REPOS="$REPOS" GLR_LIMIT_KIB=100 GLR_STATE_DIR="$CASE/state" GLR_LOG="$CASE/log" GLR_LOCK="$CASE/lock"
    GLR_HEAVY_GUARD="$WORK/bin/hg-stub" GLR_NOTIFY="$WORK/bin/notify-stub" GLR_GIT="$WORK/bin/gitw"
    GLR_FREE_KIB_CMD="$WORK/bin/freecmd" GLR_SWAP_MB_CMD="$WORK/bin/swapcmd" GLR_WATCH_SECS=0.2 GLR_TODAY=2026-10-31 HG_MODE=pass)
}
envrun() { mkenv; env "${ENVV[@]}" "$@" /bin/bash "$SCRIPT" ${ARGS:-} < /dev/null; }
run() { OUT="$(envrun "$@" 2>&1)"; RC=$?; }

contains() { printf '%s' "$1" | grep -qF -- "$2"; }
lacks()    { ! contains "$1" "$2"; }
fcontains() { [ -f "$1" ] && grep -qF -- "$2" "$1"; }
flacks()    { ! fcontains "$1" "$2"; }
count_in() { local n; n="$(grep -cF -- "$2" "$1" 2>/dev/null)"; echo "${n:-0}"; }
repack_calls() { count_in "$CASE/git.args" " repack "; }
hg_calls()     { count_in "$CASE/hg.args" "--what"; }
state_of()     { cat "$CASE"/state/* 2>/dev/null | head -n 1; }
notify_titles() { sed -n 's/^-t \(.*\) -p [0-9] .*/\1/p' "$CASE/notify.log" 2>/dev/null | sort -u | wc -l | tr -d ' '; }   # how many DIFFERENT titles notify was called with
# chk <what> <command...> | chk <what> '<condition string>' — PASS when it succeeds (a 2-argument call is evaluated as a shell condition, so && works inside it); the tail of OUT is shown on failure
chk() {
  local d="$1" r; shift
  if [ "$#" -eq 1 ]; then eval "$1"; r=$?; else "$@"; r=$?; fi
  if [ "$r" -eq 0 ]; then ok "$d"; else bad "$d"; echo "      rc=$RC out: $(printf '%s' "$OUT" | tail -4 | cut -c1-400)"; fi
}
rc_is() { [ "$RC" = "$1" ]; }

# ── cases ────────────────────────────────────────────────────────────────────────────────────────
# S1. the limit is STRICT: loose bytes AT the limit are not over it; one byte over repacks; the repack ends with the loose objects packed
t_limit() {
  newcase; repo8; run GLR_LIMIT_KIB="$K8"
  chk "S1 loose == limit ($K8 KiB): not over → no repack, VEREDITO: OK" 'test "$(repack_calls)" = 0 -a "$RC" = 0 && contains "$OUT" "VEREDITO: OK"'
  case "$(state_of)" in *"|below|"*) ok "S1 state file: below" ;; *) bad "S1 state not 'below': $(state_of)" ;; esac
  newcase; repo8; run GLR_LIMIT_KIB=$((K8 + 1000))
  chk "S1 loose under the limit: no repack" test "$(repack_calls)" = 0
  newcase; repo8; local before; before="$(loose_cnt "$CASE/repo")"; run GLR_LIMIT_KIB=$((K8 - 1))
  chk "S1 loose one KiB over the limit: exactly one repack, the loose objects packed (0 after, $before before), VEREDITO: OK, the log line carries before -> after" 'test "$(repack_calls)" = 1 && test "$(loose_cnt "$CASE/repo")" = 0 && contains "$OUT" "VEREDITO: OK" && fcontains "$CASE/log" "loose $before -> 0 objs"'
  case "$(state_of)" in *"|repacked|"*) ok "S1 state file: repacked" ;; *) bad "S1 state not 'repacked': $(state_of)" ;; esac
}

# S2. the repack is the lean, incremental one — and none of the things the bead forbids
t_args() {
  newcase; repo8; run
  local line hgl; line="$(grep ' repack ' "$CASE/git.args" | head -n 1)"; hgl="$(head -n 1 "$CASE/hg.args" 2>/dev/null)"
  chk "S2 the lean flags: pack.threads=1, pack.windowMemory=100m, pack.deltaCacheSize=32m, and repack -d -q (incremental: the loose objects, then drop them)" 'contains "$line" "-c pack.threads=1" && contains "$line" "-c pack.windowMemory=100m" && contains "$line" "-c pack.deltaCacheSize=32m" && contains "$line" "repack -d -q"'
  chk "S2 runs through heavy-guard with the label git-loose-repack, under nice -n 10" 'contains "$hgl" "--what git-loose-repack" && contains "$hgl" "nice -n 10"'
  if printf '%s\n' "$line" | grep -Eq -- '(^| )(-a|-A|-f|-F|-l|--aggressive|--cruft|--unpack-unreachable|gc|prune)( |$)'; then bad "S2 a forbidden flag/command is in the repack line: $line"; else ok "S2 no -a/-A/-f/-F/-l/--aggressive/--cruft/gc/prune in the repack line"; fi
  if grep -Eq -- ' (gc|prune|maintenance)( |$)' "$CASE/git.args"; then bad "S2 git gc/prune/maintenance was called"; else ok "S2 git was never asked for gc, prune or maintenance"; fi
}

# S3. three states: a count that cannot be read is NOT zero — not measured, nothing done, and loud
t_unreadable() {
  local v
  for v in "GITW_COUNT_FAIL=1" "GITW_COUNT_GARBLE=1" "GITW_COUNT_EMPTY=1" "GITW_COUNT_PARTIAL=1" "GITW_COUNT_SLEEP=3 GLR_COUNT_TIMEOUT_S=1"; do
    newcase; repo8
    # shellcheck disable=SC2086
    run $v
    chk "S3 [$v] FALHOU, rc 1, never OK; nothing repacked; the failure notify says 'job falhou'" 'test "$RC" = 1 && contains "$OUT" "VEREDITO: FALHOU" && lacks "$OUT" "VEREDITO: OK" && test "$(repack_calls)" = 0 && fcontains "$CASE/notify.log" "job falhou"'
    case "$(state_of)" in *"|unreadable|"*) ok "S3 [$v] state: unreadable" ;; *) bad "S3 [$v] state not 'unreadable': $(state_of)" ;; esac
    run $v
    chk "S3 [$v] same night, second tick: settled, no second notify, no verdict" 'test "$RC" = 0 -a "$(count_in "$CASE/notify.log" "job falhou")" = 1 && lacks "$OUT" "VEREDITO"'
  done
  newcase; repo8; run GITW_COUNT_FAIL=1 GLR_NOTIFY="$CASE/no-such-notify"
  chk "S3 notify binary missing: the job still fails (rc 1) and the log says it could not notify" 'test "$RC" = 1 && fcontains "$CASE/log" "WARN: notify not executable"'
  newcase; REPOS="$CASE/not-a-repo"; mkdir -p "$REPOS"; run GLR_GIT=git
  chk "S3 a path that is not a git repo (real git, rc 128): unreadable → FALHOU" 'test "$RC" = 1 && contains "$OUT" "unreadable"'
}

# S4. heavy-guard refusing (75 low disk, 76 unreadable disk) is a deferral — not a failure, not an OK — retried in the same night
t_heavyguard() {
  local m
  for m in 75 76; do
    newcase; repo8; run HG_MODE=$m
    chk "S4 heavy-guard rc $m: ADIADO, rc 0, nothing repacked, no failure notify" 'test "$RC" = 0 -a "$(repack_calls)" = 0 && contains "$OUT" "VEREDITO: ADIADO" && lacks "$OUT" "VEREDITO: OK" && flacks "$CASE/notify.log" "job falhou"'
    case "$(state_of)" in *"|deferred-disk|"*) ok "S4 rc $m: state deferred-disk" ;; *) bad "S4 rc $m: state not deferred-disk: $(state_of)" ;; esac
    run HG_MODE=pass
    chk "S4 rc $m: the next tick of the SAME night retries and packs it" 'test "$(hg_calls)" = 2 -a "$(loose_cnt "$CASE/repo")" = 0 && contains "$OUT" "VEREDITO: OK"'
  done
}

# S5. a repack that ends non-zero / is cut: FALHOU, terminal for the night, loud
t_repack_fail() {
  local m
  for m in rc:3 rc:124 rc:137; do
    newcase; repo8; run HG_MODE=$m
    chk "S5 [$m] FALHOU, rc 1, 'job falhou' notify" 'test "$RC" = 1 && contains "$OUT" "VEREDITO: FALHOU" && fcontains "$CASE/notify.log" "job falhou"'
    run HG_MODE=pass
    chk "S5 [$m] settled for the night: the heavy step is not repeated every tick" test "$(hg_calls)" = 1
  done
  newcase; repo8; run GITW_REPACK_RC=2 HG_MODE=pass
  chk "S5 git itself ends 2: failed" contains "$OUT" "status=failed"
}

# S6. the room estimate: free − estimate must stay (CRITICAL+1) GiB over; an unreadable free disk is a deferral, never 'enough'
t_room() {
  local need floor=4194304
  newcase; repo8; need=$(( K8 * 50 / 100 ))
  echo $((floor + need)) > "$CASE/free.seq"; run GLR_LIMIT_KIB=$((K8 - 1))
  chk "S6 free − estimate == the floor exactly: the repack starts" test "$(repack_calls)" = 1
  newcase; repo8; echo $((floor + need - 1)) > "$CASE/free.seq"; run GLR_LIMIT_KIB=$((K8 - 1))
  chk "S6 one KiB under: deferred-disk, nothing started" 'test "$(hg_calls)" = 0 && contains "$OUT" "VEREDITO: ADIADO" && fcontains "$CASE/log" "deferred-disk"'
  newcase; repo8; echo x > "$CASE/free.seq"; run GLR_LIMIT_KIB=$((K8 - 1))
  chk "S6 free disk unreadable: deferred-disk (fail closed), not a repack" 'test "$(hg_calls)" = 0 && fcontains "$CASE/log" "cannot be read"'
}

# S7. the swap gate at the start: ≥ the limit or unreadable defers
t_swap() {
  local v
  for v in 9000 8192 x; do
    newcase; repo8; echo "$v" > "$CASE/swap.seq"; run
    chk "S7 swap reading '$v': deferred-swap, ADIADO, nothing started" 'test "$(hg_calls)" = 0 && contains "$OUT" "VEREDITO: ADIADO" && fcontains "$CASE/log" "deferred-swap"'
  done
  newcase; repo8; echo 8191 > "$CASE/swap.seq"; run
  chk "S7 swap 8191 MB (one under the limit): the repack runs" test "$(repack_calls)" = 1
}

# the watchdog cases: the stand-in repack waits for N readings of the free disk; the scripted readings decide
alive() { kill -0 "$1" 2>/dev/null; }
t_watch_free() {
  newcase; repo8; printf '50000000\n50000000\n2000000\n' > "$CASE/free.seq"
  local t0=$SECONDS; run GITW_REPACK_WAIT_POLLS=8
  chk "S8 free disk falls under Dolt's CRITICAL+1 mid-run: the repack is stopped (interrupted, FALHOU, 'job falhou')" 'contains "$OUT" "status=interrupted" && fcontains "$CASE/notify.log" "job falhou" && test "$RC" = 1'
  chk "S8 …the stand-in repack did not run to its end, is not left running, and was stopped within seconds (not at the wait ceiling)" 'test ! -f "$CASE/repack.done" && ! alive "$(cat "$CASE/wrapper.pid" 2>/dev/null || echo 999999)" && test $((SECONDS - t0)) -lt 25'
}
t_watch_swap() {
  newcase; repo8; printf '100\n100\n100\n1500\n' > "$CASE/swap.seq"
  run GITW_REPACK_WAIT_POLLS=8
  chk "S9 swap grows > 1024 MB since the start: stopped (interrupted), the line says swap, nothing left running (no 'done')" 'contains "$OUT" "status=interrupted" && contains "$OUT" "swap grew" && test ! -f "$CASE/repack.done"'
}
t_watch_unreadable() {
  newcase; repo8; printf '50000000\nx\nx\nx\n' > "$CASE/free.seq"
  run GITW_REPACK_WAIT_POLLS=8
  chk "S10 free disk unreadable 3 polls in a row: stopped (interrupted)" 'contains "$OUT" "status=interrupted" && contains "$OUT" "unreadable"'
}
t_watch_tolerates() {
  newcase; repo8; printf '50000000\nx\n50000000\n' > "$CASE/free.seq"
  run GITW_REPACK_WAIT_POLLS=6
  chk "S10 ONE unreadable poll between good ones does not stop the repack: it ends and packs (OK)" 'contains "$OUT" "VEREDITO: OK" && test "$(loose_cnt "$CASE/repo")" = 0'
}

# S11. the window: closed outside it (silently, no work, no state), the lib decides, an unreadable clock is closed
t_window() {
  local h
  for h in 7 5 abc; do
    newcase; repo8; run JAW_HOUR=$h
    chk "S11 hour '$h': outside the window — rc 0, no work, no log, no state" 'test "$RC" = 0 -a "$(hg_calls)" = 0 -a ! -e "$CASE/log" -a ! -e "$CASE/state" && contains "$OUT" "nothing to do"'
  done
  for h in 0 4; do
    newcase; repo8; run JAW_HOUR=$h
    chk "S11 hour $h: inside the start window — the repack runs" test "$(repack_calls)" = 1
  done
}

# S12. single flight, shared with git-maintenance-runner: a fresh lock = in flight (and left alone), a stale one is reclaimed, our own is released. Three answers, never merged: HELD by a live run (a DIRECTORY younger than
# the stale age: exit 0) / TAKEN / COULD NOT BE TAKEN for any other reason (FALHOU, rc 2, 'job falhou') — nobody holds the lock then (gate-fix 1 of ga-pmu761v).
t_lock() {
  newcase; repo8; mkdir "$CASE/lock"; run
  chk "S12 a fresh lock held by someone else: 'single flight', rc 0, nothing done" 'test "$RC" = 0 -a "$(hg_calls)" = 0 && contains "$OUT" "single flight"'
  chk "S12 …and it is NOT removed (it is not ours)" test -d "$CASE/lock"
  newcase; repo8; mkdir "$CASE/lock"; touch -t 202001010000 "$CASE/lock"; run
  chk "S12 a stale lock (2020) is reclaimed and the work is done" 'test "$(repack_calls)" = 1 && fcontains "$CASE/log" "stale lock"'
  chk "S12 …our lock is released at the end" test ! -d "$CASE/lock"
}
t_lock_failures() {
  newcase; repo8; run GLR_LOCK="$CASE/no-such-dir/lock"
  chk "S12 the lock cannot be created (missing parent): FALHOU, rc 2, nothing done, 'job falhou' sent, verdict in the log — NOT 'single flight'" 'test "$RC" = 2 -a "$(hg_calls)" = 0 && lacks "$OUT" "single flight" && fcontains "$CASE/notify.log" "job falhou" && fcontains "$CASE/log" "VEREDITO: FALHOU"'
  newcase; repo8; : > "$CASE/lock"; run
  chk "S12 a file where the lock directory should be: FALHOU, rc 2, nothing done, the file left alone" 'test "$RC" = 2 -a "$(hg_calls)" = 0 && lacks "$OUT" "single flight" && fcontains "$CASE/notify.log" "job falhou" && test -f "$CASE/lock"'
  newcase; repo8; mkdir "$CASE/lock"; : > "$CASE/lock/x"; touch -t 202001010000 "$CASE/lock"; run
  chk "S12 a stale lock that rmdir cannot remove (it holds a file): FALHOU, rc 2, nothing deleted — the old code said 'contended', rc 0, on every tick" 'test "$RC" = 2 -a "$(hg_calls)" = 0 && lacks "$OUT" "single flight" && fcontains "$CASE/notify.log" "job falhou" && test -f "$CASE/lock/x"'
  newcase; repo8; mkdir "$CASE/lock" "$CASE/fakebin"; printf '#!/bin/bash\nexit 1\n' > "$CASE/fakebin/find"; chmod +x "$CASE/fakebin/find"; run PATH="$CASE/fakebin:$PATH"
  chk "S12 find fails on an existing lock (age unknown): FALHOU, rc 2 — never read as 'fresh = another run holds it'" 'test "$RC" = 2 -a "$(hg_calls)" = 0 && lacks "$OUT" "single flight" && fcontains "$CASE/notify.log" "job falhou"'
  newcase; repo8; mkdir "$CASE/lock" "$CASE/fakebin"; touch -t 202001010000 "$CASE/lock"
  printf '#!/bin/bash\n"%s" "$@"; mkdir "$1"\n' "$(command -v rmdir)" > "$CASE/fakebin/rmdir"; chmod +x "$CASE/fakebin/rmdir"; run PATH="$CASE/fakebin:$PATH"
  chk "S12 a fresh lock appears right after the reclaim (a live run won): 'single flight', rc 0, nothing done, that lock is NOT removed" 'test "$RC" = 0 -a "$(hg_calls)" = 0 && contains "$OUT" "single flight" && test -d "$CASE/lock"'
}

# S13. a repo settled tonight is not looked at again tonight; a new night is a new chance
t_settled() {
  newcase; repo8; run
  addcommits "$CASE/repo" 8; run
  chk "S13 same night, loose again over the limit: settled — no second repack, no verdict line, rc 0" 'test "$(repack_calls)" = 1 -a "$RC" = 0 && lacks "$OUT" "VEREDITO"'
  run GLR_TODAY=2026-11-01
  chk "S13 next night: measured again and packed" 'test "$(repack_calls)" = 2 && contains "$OUT" "VEREDITO: OK"'
}

# S14. deferred for N nights in a row → alarm at the first tick of the night after; never earlier, once per night, reset by a good night
t_streak() {
  newcase; repo8
  run GLR_TODAY=2026-10-29 HG_MODE=75; run GLR_TODAY=2026-10-30 HG_MODE=75; run GLR_TODAY=2026-10-30 HG_MODE=75; run GLR_TODAY=2026-10-31 HG_MODE=75
  chk "S14 three nights deferred, still no alarm on the third night's own tick (2 nights behind it)" flacks "$CASE/notify.log" "noites"
  run GLR_TODAY=2026-11-01 HG_MODE=75; run GLR_TODAY=2026-11-01 HG_MODE=75
  chk "S14 night 4, first tick: ONE alarm (priority 3) after 3 nights deferred, and it says how many nights" 'test "$(count_in "$CASE/notify.log" "noites sem repack")" = 1 && fcontains "$CASE/notify.log" "-p 3" && fcontains "$CASE/notify.log" "3 noites"'
  run GLR_TODAY=2026-11-02 HG_MODE=pass
  chk "S14 the repack finally runs: OK" contains "$OUT" "VEREDITO: OK"
  run GLR_TODAY=2026-11-03 HG_MODE=75
  chk "S14 a good night resets the streak: no new alarm after it (2 alarms in all: nights 4 and 5)" test "$(count_in "$CASE/notify.log" "noites sem repack")" = 2
}

# S15. discovery (dry-run: read-only, ignores the window, takes no lock, writes nothing): root, rigs, crew clones with a real .git dir; not worktrees, dot-dirs, plain dirs
t_discovery() {
  newcase; local r="$CASE/root"
  mkrepo "$r" 1
  mkrepo "$r/rigA" 8; mkrepo "$r/rigB/crew/x" 1
  git -C "$r/rigA" worktree add -q "$r/rigB/crew/wt" -b wtb 2>/dev/null
  mkrepo "$r/.hid" 1; mkdir -p "$r/plain"
  ARGS="--dry-run"; run GLR_REPOS= GLR_ROOT="$r" JAW_HOUR=12; ARGS=""
  chk "S15 listed: the root repo, a rig repo over the limit (REPACK), a crew clone with a real .git dir" 'contains "$OUT" "$CASE/root" && contains "$OUT" "REPACK    $CASE/root/rigA" && contains "$OUT" "$CASE/root/rigB/crew/x"'
  chk "S15 not listed: a git WORKTREE (.git is a file), a dot-directory, a plain directory" 'lacks "$OUT" "crew/wt" && lacks "$OUT" ".hid" && lacks "$OUT" "plain"'
  chk "S15 dry-run: rc 0, nothing repacked, no lock, no state, no log (and the window was closed)" test "$RC" = 0 -a "$(repack_calls)" = 0 -a ! -e "$CASE/state" -a ! -e "$CASE/log" -a ! -e "$CASE/lock"
  ARGS="--dry-run"; run GLR_REPOS= GLR_ROOT="$r" JAW_HOUR=12 GITW_COUNT_FAIL=1; ARGS=""
  chk "S15 dry-run with count-objects failing: UNREADABLE, not 'below'" 'contains "$OUT" "UNREADABLE" && lacks "$OUT" "below "'
}

# S16. after the repack: a count that cannot be read = unverified, one still over the limit = stalled — never OK
t_after() {
  newcase; repo8; run GITW_COUNT_FAIL_NTH=2
  chk "S16 repack ended 0 but the count after fails: unverified, FALHOU, notify" 'contains "$OUT" "status=unverified" && test "$RC" = 1 && fcontains "$CASE/notify.log" "job falhou"'
  newcase; repo8; run GITW_REPACK_NOOP=1
  chk "S16 repack ended 0 and the loose bytes are STILL over the limit: stalled, FALHOU" 'contains "$OUT" "status=stalled" && test "$RC" = 1'
  # the reviewer's probe B, with the real git: UNREACHABLE loose objects are never packed by `repack -d` (no -a, no prune — on purpose), so a repo can end a healthy repack still over the limit
  newcase; repo1; local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do head -c 16000 /dev/urandom | git -C "$CASE/repo" hash-object -w --stdin >/dev/null; done; run
  chk "S16 dangling (unreachable) blobs over the limit survive a healthy repack: stalled, and the message names that likely cause" 'contains "$OUT" "status=stalled" && contains "$OUT" "unreachable" && test "$(repack_calls)" = 1'
}

# S17. time: the run's budget and the window's end bound the repack; no time = deferred-time, never 'plenty'
t_time() {
  newcase; repo8; run GLR_DEADLINE_S=30
  chk "S17 run budget under 60 s: deferred-time, ADIADO, nothing started" 'contains "$OUT" "deferred-time" && contains "$OUT" "VEREDITO: ADIADO" && test "$(hg_calls)" = 0'
  newcase; repo8; run JAW_HOUR=4 JAW_SECS_OF_DAY=17900 GLR_REPACK_TIMEOUT_S=9000 GLR_DEADLINE_S=9000
  chk "S17 04:58:20: the budget is the window's rest (3700 s) less the 300 s margin = 3400 s" fcontains "$CASE/log" "budget 3400s"
  newcase; repo8; run JAW_HOUR=4 JAW_SECS_OF_DAY=21500
  chk "S17 05:58:20 (window ends in 100 s): deferred-time, nothing started" 'contains "$OUT" "deferred-time" && test "$(hg_calls)" = 0'
  newcase; repo8; run JAW_HOUR=4 JAW_SECS_OF_DAY=zz
  chk "S17 time left in the window unreadable: deferred-time (no time), not 'plenty'" 'contains "$OUT" "deferred-time" && test "$(hg_calls)" = 0'
}

# S18. the job cannot run: a failure with rc 2 and 'job falhou' — never a silent 'nothing to do'
t_setup() {
  newcase; repo8; mkdir "$CASE/nolib"; cp "$SCRIPT_REAL" "$CASE/nolib/git-loose-repack.sh"
  local keep="$SCRIPT"; SCRIPT="$CASE/nolib/git-loose-repack.sh"; run; SCRIPT="$keep"
  chk "S18 the window lib cannot be loaded: rc 2, FALHOU, 'job falhou' notify, nothing done" 'test "$RC" = 2 -a "$(hg_calls)" = 0 && contains "$OUT" "VEREDITO: FALHOU" && fcontains "$CASE/notify.log" "job falhou"'
  newcase; repo8; run GLR_LIMIT_KIB=abc
  chk "S18 a setting that is not a number: rc 2 + 'job falhou'" 'test "$RC" = 2 && fcontains "$CASE/notify.log" "job falhou"'
  newcase; repo8; ARGS="--bogus"; run; ARGS=""
  chk "S18 unknown flag: usage, rc 64" test "$RC" = 64
  newcase; REPOS=""; mkdir -p "$CASE/emptyroot"; run GLR_ROOT="$CASE/emptyroot"
  chk "S18 no repo found at all: FALHOU (rc 1) and a notify — 'nothing to do' would hide a broken list" 'test "$RC" = 1 && contains "$OUT" "EMPTY" && fcontains "$CASE/notify.log" "job falhou"'
  newcase; repo8; local slug; slug="$(printf '%s' "$REPOS" | tr '/ ' '__')"; mkdir -p "$CASE/state"; printf 'junk-without-bars\n' > "$CASE/state/$slug"; run
  chk "S18 a corrupt state file: WARN in the log and the repo is treated as new (packed)" 'fcontains "$CASE/log" "WARN: state file" && test "$(repack_calls)" = 1'
}

# S19. a TERM (the order's timeout, a restart) stops the repack in flight, says FALHOU, frees the lock
t_signal() {
  newcase; repo8
  mkenv; env "${ENVV[@]}" GITW_REPACK_WAIT_POLLS=100000 GLR_WATCH_SECS=1 /bin/bash "$SCRIPT" > "$CASE/out" 2>&1 &
  local pid=$! i=0
  while [ ! -f "$CASE/wrapper.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=$?; OUT="$(cat "$CASE/out" 2>/dev/null)"
  chk "S19 TERM while the repack runs: exit 143, the stand-in repack is stopped (not left behind) and the lock is released" 'test "$RC" = 143 && test ! -f "$CASE/repack.done" && ! alive "$(cat "$CASE/wrapper.pid" 2>/dev/null || echo 999999)" && test ! -d "$CASE/lock"'
  chk "S19 …the log says FALHOU / ended by TERM, and 'job falhou' was sent" 'fcontains "$CASE/log" "ended by TERM" && fcontains "$CASE/notify.log" "job falhou"'
}

# S20. the order file and the script agree (interval, timeout vs the script's deadline and the lock's stale age, exec path)
t_order() {
  OUT=""; RC=0
  chk "S20 the order file exists and the script is executable (the order execs it)" 'test -f "$ORDER" -a -x "$SCRIPT_REAL"'
  local trig interval tmo exe dl stale
  trig="$(sed -n 's/^trigger *= *"\(.*\)"/\1/p' "$ORDER")"; interval="$(sed -n 's/^interval *= *"\([0-9]*\)m"/\1/p' "$ORDER")"
  tmo="$(sed -n 's/^timeout *= *"\([0-9]*\)s"/\1/p' "$ORDER")"; exe="$(sed -n 's/^exec *= *"\(.*\)"/\1/p' "$ORDER")"
  dl="$(sed -n 's/^DEADLINE_S="${GLR_DEADLINE_S:-\([0-9]*\)}".*/\1/p' "$SCRIPT_REAL")"; stale="$(sed -n 's/^LOCK_STALE_MIN="${GLR_LOCK_STALE_MIN:-\([0-9]*\)}".*/\1/p' "$SCRIPT_REAL")"
  chk "S20 trigger is cooldown (a cron expression would be read in UTC; the window is local), interval ≤ 30m (got '$interval')" 'test "$trig" = cooldown && test -n "$interval" && test "$interval" -le 30'
  chk "S20 timeout ($tmo s) covers the script's own deadline ($dl s) + 300 s" 'test -n "$tmo" && test -n "$dl" && test "$tmo" -ge $((dl + 300))'
  chk "S20 timeout stays under the shared lock's stale age (${stale} min)" 'test -n "$stale" && test "$tmo" -le $((stale * 60))'
  chk "S20 exec points at this script and the file exists" test "$exe" = '$PACK_DIR/assets/scripts/git-loose-repack.sh' -a -f "$HERE/git-loose-repack.sh"
  chk "S20 the lock is the one git-maintenance-runner.sh takes" grep -q 'LOCK="${GLR_LOCK:-/tmp/git-maintenance-runner.lock}"' "$SCRIPT_REAL"
  if python3 -I -c 'import tomllib' 2>/dev/null; then
    chk "S20 the order file is valid TOML with [order] trigger/interval/timeout/exec" python3 -I -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb"))["order"]; assert all(k in d for k in ("trigger","interval","timeout","exec","description"))' "$ORDER"
  else skip "S20 tomllib not available: the order file's TOML syntax was NOT parsed"; fi
  # drift guard: the CRITICAL class is the guard's own number
  local guard="$CITY_ROOT/scripts/dolt-disk-floor-guard.sh" gdef mine
  mine="$(sed -n 's/^CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-\([0-9]*\)}".*/\1/p' "$SCRIPT_REAL")"
  if [ ! -f "$guard" ]; then skip "S20 $guard is not in this tree — the drift check of the CRITICAL default did NOT run"
  else
    gdef="$(sed -n 's/^FLOOR_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-\([0-9][0-9]*\)}".*/\1/p' "$guard" | head -1)"
    if [ -z "$gdef" ] || [ -z "$mine" ]; then bad "S20 cannot read the CRITICAL default (guard='$gdef' mine='$mine') — the drift check is blind"
    elif [ "$gdef" = "$mine" ]; then ok "S20 drift guard: the Dolt CRITICAL default ($mine GiB) is dolt-disk-floor-guard.sh's own"
    else bad "S20 DRIFT: dolt-disk-floor-guard.sh calls the disk CRITICAL at <= $gdef GiB, this script assumes $mine GiB"; fi
  fi
}

# S21. static: the code (comments aside) never runs the things the bead forbids, and the heavy-guard label stays out of the file-cap class (a pack over 512 MB would be cut by ulimit -f)
t_static() {
  OUT=""; RC=0
  local code; code="$(grep -v '^[[:space:]]*#' "$SCRIPT_REAL")"
  if printf '%s\n' "$code" | grep -Eq -- '--aggressive|--cruft|repack +-[aAfF]|[[:space:]]prune([[:space:]]|$)|git[^|;]* gc( |$)|rm -rf|rm -r '; then bad "S21 the code mentions a forbidden command (--aggressive/--cruft/repack -a/prune/gc/rm -r)"; else ok "S21 no --aggressive, --cruft, repack -a/-A/-f/-F, prune, gc or rm -r in the code"; fi
  local label; label="$(printf '%s\n' "$code" | sed -n 's/.*--what \([a-z-]*\) --.*/\1/p' | head -1)"
  case "$label" in ''|*selftest*|*mutant*|*mutat*) bad "S21 heavy-guard label '$label' is empty or in the file-cap class (selftest/mutant): a big pack would be cut at 512 MB" ;; *) ok "S21 heavy-guard label '$label' is outside the file-cap class" ;; esac
  chk "S21 bash -n" bash -n "$SCRIPT_REAL"
}

# S22. the failure notify must ARRIVE (notify's contract: no STRICT_EXIT = every path that did not push exits 0; no FORCE_PUSH = an unknown source goes to the muted digest; a push whose TITLE equals one sent < 30 min ago is dropped).
t_notify() {
  newcase; repo8; run GITW_COUNT_FAIL=1
  chk "S22 the failure notify carries NOTIFY_FORCE_PUSH=1 and NOTIFY_STRICT_EXIT=1; a push that went out (rc 0) leaves nothing about notify in the log" 'fcontains "$CASE/notify.log" "FORCE=1" && fcontains "$CASE/notify.log" "STRICT=1" && flacks "$CASE/log" "notify"'
  local pair
  for pair in "12:WARN: notify NOT delivered (rc=12)" "10:notify held until 07:00" "11:notify deduplicated"; do
    newcase; repo8; run GITW_COUNT_FAIL=1 NOTIFY_STUB_RC="${pair%%:*}"
    chk "S22 notify exits ${pair%%:*}: the log says '${pair#*:}' and the job's own rc stays 1" 'fcontains "$CASE/log" "${pair#*:}" && test "$RC" = 1'
  done
  newcase; REPOS="$CASE/a $CASE/b"; run GITW_COUNT_FAIL=1
  chk "S22 two repos fail in one tick: two notifies with two DIFFERENT titles (notify's same-title dedup cannot swallow the second), both 'job falhou'" 'test "$(count_in "$CASE/notify.log" "job falhou")" = 2 && test "$(notify_titles)" = 2'
}

# S23. nothing inside the repo loop can eat the list of repos (the loop's input): a notify, or a git, that reads its stdin used to swallow every repo after the first, silently (the next tick picked them up).
t_stdin() {
  newcase; REPOS="$CASE/a $CASE/b $CASE/c"; run GITW_COUNT_FAIL=1 NOTIFY_STUB_STDIN=1
  chk "S23 three repos fail and the notify reads stdin: all three are handled in the SAME tick (3 failed)" 'contains "$OUT" "3 failed"'
  newcase; cp -R "$WORK/tpl1" "$CASE/a"; cp -R "$WORK/tpl1" "$CASE/b"; cp -R "$WORK/tpl1" "$CASE/c"; REPOS="$CASE/a $CASE/b $CASE/c"; run GITW_STDIN=1
  chk "S23 three repos and a git that reads its stdin to the end: all three are measured (3 below the limit)" 'contains "$OUT" "3 below the limit"'
}

ALL_CASES="t_limit t_args t_unreadable t_heavyguard t_repack_fail t_room t_swap t_watch_free t_watch_swap t_watch_unreadable t_watch_tolerates t_window t_lock t_lock_failures t_settled t_streak t_discovery t_after t_time t_setup t_signal t_order t_static t_notify t_stdin"
for fn in $ALL_CASES; do echo "== $fn"; "$fn"; done

# ── mutants: break one thing in a COPY of the script; the named case(s) must fail ─────────────────
# mutant <name> <old> <new> <case...> — <old> must occur exactly once in the script (else the mutant does not apply and that is a failure of this battery, not a pass)
mkdir -p "$WORK/mut"
mutant() {
  local name="$1" old="$2" new="$3" d="$WORK/mut/$1"; shift 3
  mkdir -p "$d"; cp "$LIB" "$d/"
  if ! OLD="$old" NEW="$new" python3 -I - "$SCRIPT_REAL" "$d/git-loose-repack.sh" <<'PY'
import os, sys
s = open(sys.argv[1]).read(); old = os.environ["OLD"]; new = os.environ["NEW"]
if s.count(old) != 1:
    sys.exit(3)
open(sys.argv[2], "w").write(s.replace(old, new, 1))
PY
  then bad "mutant $name does not apply: the original text is not in the script exactly once"; return; fi
  local p0=$PASS f0=$FAIL s0=$SKIP fn df
  SCRIPT="$d/git-loose-repack.sh"
  for fn in "$@"; do "$fn" >/dev/null 2>&1; done
  df=$((FAIL - f0)); SCRIPT="$SCRIPT_REAL"; PASS=$p0; FAIL=$f0; SKIP=$s0
  if [ "$df" -gt 0 ]; then ok "mutant $name KILLED ($df check(s) failed against it, in: $*)"; else bad "mutant $name SURVIVED — $* did not notice it"; fi
}
echo "== mutants"
if [ "${GLR_ST_SKIP_MUTANTS:-0}" = 1 ]; then
  skip "mutants NOT run (GLR_ST_SKIP_MUTANTS=1) — the cases above were not proven able to fail"
  echo; echo "RESULT: pass=$PASS fail=$FAIL skip=$SKIP"; [ "$FAIL" -eq 0 ]; exit
fi
mutant unreadable-as-below      'finish "$repo" unreadable "$COUNT_ERR'            'finish "$repo" below "$COUNT_ERR'            t_unreadable
mutant no-numeric-check         'if ! _uint "$objs" || ! _uint "$kib"; then COUNT_ERR'  'if false; then COUNT_ERR'                   t_unreadable
mutant count-rc-ignored         'if [ "$rc" -ne 0 ]; then COUNT_ERR='              'if false; then COUNT_ERR='                  t_unreadable
mutant count-unbounded          'out="$("$TIMEOUT_BIN" -k 10 "$COUNT_TIMEOUT_S" "$GIT" -C'  'out="$("$GIT" -C'                         t_unreadable
mutant limit-not-strict         'if ! [ "$kib" -gt "$LIMIT_KIB" ]; then finish "$repo" below'  'if ! [ "$kib" -ge "$LIMIT_KIB" ]; then finish "$repo" below'  t_limit
mutant no-drop-loose            'pack.deltaCacheSize=32m repack -d -q >> "$LOG"'   'pack.deltaCacheSize=32m repack -q >> "$LOG"'  t_args t_limit
mutant repack-all               'pack.deltaCacheSize=32m repack -d -q >> "$LOG"'   'pack.deltaCacheSize=32m repack -a -d -q >> "$LOG"'  t_args
mutant refusal-as-failure       '75|76) finish'                                    '7575|7676) finish'                          t_heavyguard
mutant room-boundary            'if [ $(( free - need )) -lt "$floor" ]; then'     'if [ $(( free - need )) -le "$floor" ]; then'  t_room
mutant swap-start-gate-off      'if [ "$swap" -ge "$SWAP_START_MAX_MB" ]'          'if [ "$swap" -ge 999999 ]'                  t_swap
mutant watch-free-off           'if [ "$free" -lt "$stop_floor" ]; then REPACK_STOP'  'if [ "$free" -lt 0 ]; then REPACK_STOP'      t_watch_free
mutant watch-swap-off           '[ "$swap" -gt $((swap0 + SWAP_GROW_MAX_MB)) ]'    '[ "$swap" -gt $((swap0 + 999999)) ]'        t_watch_swap
mutant watch-one-bad-poll       'if [ "$bad" -ge 3 ]'                              'if [ "$bad" -ge 1 ]'                        t_watch_tolerates
mutant watch-never-unreadable   'if [ "$bad" -ge 3 ]'                              'if [ "$bad" -ge 99 ]'                       t_watch_unreadable
mutant stalled-ignored          'if [ "$kib2" -gt "$LIMIT_KIB" ]; then'            'if false; then'                             t_after
mutant unverified-as-ok         'finish "$repo" unverified'                        'finish "$repo" repacked'                    t_after
mutant window-ignored           'if ! jaw_window_open; then'                       'if false; then'                             t_window
mutant lock-ignored             $'the text only explains a failure in the log\nif ! LOCK_ERR="$(mkdir "$LOCK" 2>&1)"; then'  $'the text only explains a failure in the log\nif false; then'  t_lock t_lock_failures
mutant settled-ignored          'if ! is_deferral "$P_STATUS"; then'               'if false; then'                             t_settled
mutant alarm-too-late           'if [ "$BASE" -ge "$ALARM_NIGHTS" ]'               'if [ "$BASE" -gt "$ALARM_NIGHTS" ]'         t_streak
mutant alarm-too-early          'if [ "$BASE" -ge "$ALARM_NIGHTS" ]'               'if [ "$BASE" -ge 1 ]'                       t_streak
mutant no-job-falhou            'notify_send 4 "git-loose-repack: job falhou ($(repo_label "$repo"))" "$repo: $st'  'notify_send 4 "git-loose-repack: job parou ($(repo_label "$repo"))" "$repo: $st'  t_unreadable t_after
mutant worktree-not-skipped     '[ -d "$d/.git" ] && echo "$d"'                    '[ -e "$d/.git" ] && echo "$d"'              t_discovery
mutant window-end-ignored       'wl=$(( left - WINDOW_MARGIN_S ))'                 'wl=$(( left + 99999 ))'                     t_time
mutant no-signal-handler        "trap 'on_signal TERM 143' TERM"                   ":"                                          t_signal
mutant lock-missing-as-held     '{ echo nothing; return 0; }'                      '{ echo fresh; return 0; }'                  t_lock_failures
mutant lock-file-as-held        'then echo notdir; return 0; fi'                   'then echo fresh; return 0; fi'              t_lock_failures
mutant lock-age-unknown-as-held 'then echo unknown; return 0; fi'                  'then echo fresh; return 0; fi'              t_lock_failures
mutant lock-stuck-as-held       'else LOCK_AT="$(lock_state)"; fi'                 'else LOCK_AT=fresh; fi'                     t_lock_failures
mutant lock-race-as-failure     'else LOCK_AT="$(lock_state)"; fi'                 'else LOCK_AT=unknown; fi'                   t_lock_failures
mutant notify-plain             'NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1 "$TIMEOUT_BIN" -k 5 30'  '"$TIMEOUT_BIN" -k 5 30'  t_notify
mutant notify-rc-not-read       'case "$rc" in 0) ;; 10) say "notify held'         'case "$rc" in *) ;; 10) say "notify held'  t_notify
mutant notify-title-shared      '"git-loose-repack: job falhou ($(repo_label "$repo"))" "$repo: $st'  '"git-loose-repack: job falhou" "$repo: $st'  t_notify
mutant loop-eats-stdin          $'while IFS= read -r _repo <&3; do\n  [ -n "$_repo" ] || continue\n  process_repo "$_repo"\ndone 3<<EOF'  $'while IFS= read -r _repo; do\n  [ -n "$_repo" ] || continue\n  process_repo "$_repo"\ndone <<EOF'  t_stdin
mutant stalled-no-hint          '; likely unreachable loose objects (repack -d neither packs nor prunes them, and this job never prunes): check git fsck --unreachable'  ''  t_after
mutant swap-baseline-dropped    'run_repack "$repo" "$budget" "$swap"'             'run_repack "$repo" "$budget" ""'            t_watch_swap

echo
echo "RESULT: pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
