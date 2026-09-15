#!/usr/bin/env bash
# dolt-pid-lib.selftest.sh (ga-0bjqix) — decoy-PID regression test for dolt_server_pid().
#
# WHY: `pgrep -f 'dolt sql-server' | head -1` picks whichever candidate sorts
# first in process-table order, not necessarily the real server. Measured live
# 2026-09-15 08:39Z: a witness scan using that exact recipe picked pid 5546 —
# etime 1s, 0.1% CPU, no --config in argv, no listener — while the real server
# (pid 30796, up 4h17m, the only *:52756 listener) was untouched. The same
# recipe feeds dolt-hang-watchdog.sh's CPU veto and its kill -QUIT target: a
# wrong idle PID reads ~0% CPU, which would have skipped the veto and let a
# merely-saturated (not hung) server get killed. This test proves
# dolt_server_pid() rejects that kind of decoy instead of trusting sort order.
#
# HOW: stub pgrep/ps/lsof via a scratch PATH dir. Two real (but harmless)
# background `sleep` processes stand in for "decoy" and "real server" PIDs —
# real, so kill -0 liveness checks are genuine; their identity (comm) and
# listen-socket state are faked via the stubbed ps/lsof, keyed by PID, so the
# test needs no actual dolt binary or open port.
set -uo pipefail

FAILURES=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc -- expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

SCRATCH="$(mktemp -d)"
cleanup() {
  kill "$DECOY_PID" "$REAL_PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Two genuinely-alive processes so kill -0 liveness checks in the lib are
# real, not faked -- only their comm/listen-socket facts are stubbed below.
sleep 300 & DECOY_PID=$!
sleep 300 & REAL_PID=$!

STUBBIN="$SCRATCH/bin"
mkdir -p "$STUBBIN"

# Fake pgrep: returns the decoy PID FIRST, real second -- the same ordering
# hazard as the live incident (a decoy that happened to sort ahead of the
# server).
cat > "$STUBBIN/pgrep" <<EOF
#!/usr/bin/env bash
printf '%s\n%s\n' "$DECOY_PID" "$REAL_PID"
EOF
chmod +x "$STUBBIN/pgrep"

# Fake ps: only REAL_PID reports comm=dolt; decoy reports comm=sleep.
# Supports the two invocation shapes the lib uses: `ps -o comm= -p PID` and
# `ps -p PID -o %cpu=`.
cat > "$STUBBIN/ps" <<EOF
#!/usr/bin/env bash
pid=""
for a in "\$@"; do case "\$a" in [0-9]*) pid="\$a" ;; esac; done
case " \$* " in
  *"%cpu"*) echo "0.0" ;;
  *) if [ "\$pid" = "$REAL_PID" ]; then echo "dolt"; else echo "sleep"; fi ;;
esac
EOF
chmod +x "$STUBBIN/ps"

# Fake lsof: only REAL_PID holds a LISTEN socket.
cat > "$STUBBIN/lsof" <<EOF
#!/usr/bin/env bash
pid="" prev=""
for a in "\$@"; do
  [ "\$prev" = "-p" ] && pid="\$a"
  prev="\$a"
done
[ "\$pid" = "$REAL_PID" ]
EOF
chmod +x "$STUBBIN/lsof"

export PATH="$STUBBIN:$PATH"
export GC_CITY="$SCRATCH/no-such-city"   # no dolt.pid here -- forces the pgrep fallback path

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="$_SCRIPT_DIR/dolt-pid-lib.sh"
if [ ! -r "$LIB" ]; then
  echo "FAIL: $LIB not found"
  exit 1
fi
# shellcheck source=dolt-pid-lib.sh
source "$LIB"

got="$(dolt_server_pid)"
assert_eq "dolt_server_pid skips the decoy and returns the real server PID" "$REAL_PID" "$got"

# Old, buggy recipe kept here for contrast/documentation -- proves the decoy
# really would win under process-table order alone, i.e. the bug this test
# guards against is real, not hypothetical.
old="$(pgrep -f 'dolt sql-server' | head -1)"
assert_eq "the old 'pgrep | head -1' recipe (for contrast) picks the decoy" "$DECOY_PID" "$old"

# Pidfile path (step 1) takes priority and must be checked even when pgrep
# would return only decoys -- point pgrep at nothing but the decoy so a pass
# here can only come from the pidfile branch, not a lucky pgrep fallback.
cat > "$STUBBIN/pgrep" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$DECOY_PID"
EOF
chmod +x "$STUBBIN/pgrep"
PIDFILE_CITY="$SCRATCH/pidfile-city"
mkdir -p "$PIDFILE_CITY/.gc/runtime/packs/dolt"
printf '%s' "$REAL_PID" > "$PIDFILE_CITY/.gc/runtime/packs/dolt/dolt.pid"
got_pidfile="$(GC_CITY="$PIDFILE_CITY" dolt_server_pid)"
assert_eq "a valid dolt.pid wins over pgrep fallback entirely" "$REAL_PID" "$got_pidfile"

# Restore the decoy-then-real pgrep stub for the remaining scenarios below.
cat > "$STUBBIN/pgrep" <<EOF
#!/usr/bin/env bash
printf '%s\n%s\n' "$DECOY_PID" "$REAL_PID"
EOF
chmod +x "$STUBBIN/pgrep"

# No candidate passes both checks -> must return empty, never a guess.
cat > "$STUBBIN/ps" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *"%cpu"*) echo "0.0" ;;
  *) echo "sleep" ;;
esac
EOF
chmod +x "$STUBBIN/ps"
got_none="$(dolt_server_pid)"
rc=$?
assert_eq "no valid candidate -> empty result" "" "$got_none"
if [ "$rc" -eq 0 ]; then
  echo "FAIL: dolt_server_pid returned success (rc=0) with no valid candidate"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: dolt_server_pid returns non-zero when no valid candidate exists"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
