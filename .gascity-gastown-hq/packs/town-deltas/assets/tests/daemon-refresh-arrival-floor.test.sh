#!/usr/bin/env bash
# daemon-refresh-arrival-floor.test.sh — regression test for ga-maor6ab.
# Runs the REAL daemon-refresh.sh (same harness style as
# daemon-refresh-noop-pull-bead-fallback.test.sh: standalone, env-var-driven, mock
# launchctl/ps, a throwaway git repo as RUNTIME_DIR).
#
# THE BUG (measured 11/11, wa-j0af6b): the fix to daemons/inbound_sweep.py was
# COMMITTED at 08:57:33 but only reached the runtime checkout at 09:17:55 (the HEAD
# reflog). com.urblink.inbound-sweep had started at 09:05 — after the commit, before
# the code. already_fresh() compared the process start with the COMMIT time only, read
# "started after the commit" as "plausibly already running the new code", and put the
# label in ALREADY_FRESH. The one daemon whose OWN file was in the diff never reached
# the NEEDS_GUARDED_RESTART list; the verdict named other daemons instead. Same class
# on 17/10 (demand-dashboard). Header point 27 of daemon-refresh.sh.
#
# THE FIX: the floor is the LATER of the commit time and the time the floor commit
# became reachable from $RUNTIME_DIR's HEAD (reflog). A process that started in the gap
# ran the previous code and is NOT already fresh.
#
# The fixtures set GIT_COMMITTER_DATE on the fast-forward merge, which is what the
# reflog records: that is how a commit dated early arrives late.
#
# T1 (the incident): process started between the commit and the arrival -> GUARDED,
#    not ALREADY_FRESH, verdict NEEDS_GUARDED_RESTART.
# T2 (control): process started AFTER the arrival -> still ALREADY_FRESH, verdict OK.
# T3 (cannot tell): same start time as T2 but the reflog (HEAD and branch) is gone -> NOT claimed
#    fresh (the unreadable third state does not read as "arrived long ago").
# T4 (per-daemon floor kept, ga-n2jnsa): two commits in the window, the daemon's own
#    file in the FIRST; the process started after that one arrived and before the
#    second (docs only) arrived -> still ALREADY_FRESH. Proves the floor is the
#    daemon's own commit's arrival, not the tip's.
# T5 (control): process started BEFORE the commit -> GUARDED (unchanged behaviour).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# DAEMON_REFRESH_HELPER lets a mutation run point this suite at another copy of the script.
HELPER="${DAEMON_REFRESH_HELPER:-$SCRIPT_DIR/../daemon-refresh.sh}"
export RESTART_STABLE_SECS="${RESTART_STABLE_SECS:-0}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }
has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

make_plist() {  # make_plist <dir> <label> <prog-arg> [<prog-arg>...]
  local dir="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args="$args      <string>$a</string>
"; done
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
</dict>
</plist>
EOF
}

new_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  RUNTIME="$CASE_DIR/runtime"; AGENTS="$CASE_DIR/agents"; MOCK="$CASE_DIR/mock"; BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"

  git -C "$RUNTIME" init -q -b main
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons" "$RUNTIME/docs" "$RUNTIME/launchd"
  # main needs a first commit before commit_at can branch off it.
  GIT_AUTHOR_DATE="@$((NOW - 7200))" GIT_COMMITTER_DATE="@$((NOW - 7200))" \
    git -C "$RUNTIME" commit -q --allow-empty -m init

  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    echo "${last##*/}" >> "$S/kicks.log"
    ;;
esac
exit 0
LCEOF
  chmod +x "$BIN/launchctl"

  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] && [ -f "$S/start.$pid" ] && cat "$S/start.$pid"
exit 0
PSEOF
  chmod +x "$BIN/ps"
}

seed_running() { echo "$2" > "$MOCK/pid.$1"; echo "$3" > "$MOCK/start.$2"; }

# commit_at <message> <commit_epoch> <arrival_epoch>: stage everything and make a commit
# DATED <commit_epoch> on a side branch, then fast-forward main to it with the merge
# dated <arrival_epoch> — the HEAD reflog entry that says when the code reached the
# checkout. (git records GIT_COMMITTER_DATE in the reflog.)
commit_at() {
  local msg="$1" cepoch="$2" aepoch="$3"
  git -C "$RUNTIME" checkout -q -b side
  git -C "$RUNTIME" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="@$cepoch" GIT_COMMITTER_DATE="@$cepoch" \
    git -C "$RUNTIME" commit -q -m "$msg" --allow-empty
  git -C "$RUNTIME" checkout -q main
  GIT_COMMITTER_DATE="@$aepoch" git -C "$RUNTIME" merge -q --ff-only side
  git -C "$RUNTIME" branch -q -D side
}

# daemon_files <name> <script>: the .py entrypoint and a wrapper plist target for it.
daemon_files() {
  local name="$1" script="$2"
  printf 'x = 1\n' > "$RUNTIME/daemons/$script"
  cat > "$RUNTIME/launchd/$name-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/$script"
EOF
  make_plist "$AGENTS" "com.test.$name" /bin/bash "$RUNTIME/launchd/$name-wrapper.sh"
}

# invoke_helper <pre_sha> <post_sha> <deploy_epoch>
invoke_helper() {
  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$1" POST_DEPLOY_SHA="$2" \
  DEPLOY_EPOCH="$3" \
  SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>"$CASE_DIR/stderr.log"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-arrival-floor.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

NOW=$(date +%s)
COMMIT_T=$((NOW - 1800))     # the fix was committed 30 min ago ...
ARRIVAL_T=$((NOW - 600))     # ... and reached the runtime checkout 10 min ago
LABEL="com.test.inbound-sweep"
SENSITIVE_DAEMONS="inbound-sweep"

# base_with_daemon: a base commit (arrival = commit = now-3600) that already holds the
# daemon, then bump the file with a real statement for the deploy commit.
base_with_daemon() {
  daemon_files inbound-sweep inbound_sweep.py
  commit_at base $((NOW - 3600)) $((NOW - 3600))
  C0=$(git -C "$RUNTIME" rev-parse HEAD)
  printf 'x = 2\n' > "$RUNTIME/daemons/inbound_sweep.py"
}

# ════════════════════════════════════════════════════════════════════════════
# T1: the incident — started in the gap between commit time and arrival
# ════════════════════════════════════════════════════════════════════════════
new_case t1
base_with_daemon
commit_at "fix inbound_sweep" "$COMMIT_T" "$ARRIVAL_T"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
seed_running "$LABEL" 5001 "$(lstart_of $((COMMIT_T + 600)))"   # 09:05-style: after the commit, before the code
OUT=$(invoke_helper "$C0" "$C1" "$NOW"); RC=$?
V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT"); AF=$(field ALREADY_FRESH "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T1 verdict NEEDS_GUARDED_RESTART (got '$V')" || nok "T1 verdict" "got '$V' rc=$RC"
has_word "$G" "$LABEL" && ok "T1 the daemon whose own file changed is in GUARDED" || nok "T1 GUARDED" "got '$G'"
has_word "$AF" "$LABEL" && nok "T1 must NOT be ALREADY_FRESH" "got '$AF'" || ok "T1 not ALREADY_FRESH"
grep -q "NOT after the code reached the runtime checkout" "$CASE_DIR/stderr.log" \
  && ok "T1 the log says why (code arrived after the process started)" || nok "T1 log line" "$(grep "$LABEL" "$CASE_DIR/stderr.log" | head -3)"

# ════════════════════════════════════════════════════════════════════════════
# T2: control — started AFTER the arrival
# ════════════════════════════════════════════════════════════════════════════
new_case t2
base_with_daemon
commit_at "fix inbound_sweep" "$COMMIT_T" "$ARRIVAL_T"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
seed_running "$LABEL" 5002 "$(lstart_of $((ARRIVAL_T + 120)))"
OUT=$(invoke_helper "$C0" "$C1" "$NOW"); RC=$?
V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT"); AF=$(field ALREADY_FRESH "$OUT")
[ "$V" = "OK" ] && ok "T2 verdict OK (got '$V')" || nok "T2 verdict" "got '$V' rc=$RC"
has_word "$AF" "$LABEL" && ok "T2 ALREADY_FRESH names the daemon" || nok "T2 ALREADY_FRESH" "got '$AF'"
[ -z "${G// /}" ] && ok "T2 nothing GUARDED" || nok "T2 GUARDED" "got '$G'"

# ════════════════════════════════════════════════════════════════════════════
# T3: cannot tell — T2's exact fixture with the HEAD reflog removed
# ════════════════════════════════════════════════════════════════════════════
new_case t3
base_with_daemon
commit_at "fix inbound_sweep" "$COMMIT_T" "$ARRIVAL_T"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
seed_running "$LABEL" 5003 "$(lstart_of $((ARRIVAL_T + 120)))"
# git answers `reflog show HEAD` from the branch reflog when logs/HEAD is gone, so both go.
rm -f "$RUNTIME/.git/logs/HEAD" "$RUNTIME/.git/logs/refs/heads/main"
OUT=$(invoke_helper "$C0" "$C1" "$NOW"); RC=$?
V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT"); AF=$(field ALREADY_FRESH "$OUT")
has_word "$G" "$LABEL" && ok "T3 unreadable reflog: daemon GUARDED, not claimed fresh" || nok "T3 GUARDED" "got '$G' verdict='$V'"
has_word "$AF" "$LABEL" && nok "T3 must NOT be ALREADY_FRESH" "got '$AF'" || ok "T3 not ALREADY_FRESH"
grep -q "cannot tell when commit" "$CASE_DIR/stderr.log" \
  && ok "T3 the log says it could not tell" || nok "T3 log line" "$(grep "$LABEL" "$CASE_DIR/stderr.log" | head -3)"

# ════════════════════════════════════════════════════════════════════════════
# T4: per-daemon floor — the daemon's own commit arrived EARLY, a later docs-only
#     commit arrived after the process started
# ════════════════════════════════════════════════════════════════════════════
new_case t4
base_with_daemon
A1=$((NOW - 3000))
commit_at "fix inbound_sweep" $((NOW - 3400)) "$A1"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
printf 'notes\n' > "$RUNTIME/docs/notes.md"
commit_at "docs only" $((NOW - 700)) "$ARRIVAL_T"
C2=$(git -C "$RUNTIME" rev-parse HEAD)
seed_running "$LABEL" 5004 "$(lstart_of $((A1 + 600)))"   # after the daemon's own commit arrived, before the docs one
OUT=$(invoke_helper "$C0" "$C2" "$NOW"); RC=$?
V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT"); AF=$(field ALREADY_FRESH "$OUT")
has_word "$AF" "$LABEL" && ok "T4 ALREADY_FRESH (floor = arrival of the daemon's own commit)" || nok "T4 ALREADY_FRESH" "got '$AF' guarded='$G' verdict='$V'"
[ -z "${G// /}" ] && ok "T4 nothing GUARDED" || nok "T4 GUARDED" "got '$G'"

# ════════════════════════════════════════════════════════════════════════════
# T5: control — started BEFORE the commit
# ════════════════════════════════════════════════════════════════════════════
new_case t5
base_with_daemon
commit_at "fix inbound_sweep" "$COMMIT_T" "$ARRIVAL_T"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
seed_running "$LABEL" 5005 "$(lstart_of $((COMMIT_T - 900)))"
OUT=$(invoke_helper "$C0" "$C1" "$NOW"); RC=$?
V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT"); AF=$(field ALREADY_FRESH "$OUT")
has_word "$G" "$LABEL" && ok "T5 started before the commit: GUARDED" || nok "T5 GUARDED" "got '$G' verdict='$V'"
has_word "$AF" "$LABEL" && nok "T5 must NOT be ALREADY_FRESH" "got '$AF'" || ok "T5 not ALREADY_FRESH"

echo
echo "daemon-refresh-arrival-floor: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
