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
#
# ga-iu0fvlo: three more scenarios, each with its OWN stub dir (sc_rc_sucesso, sc_pidfile_vazio, sc_pidfile_morto), and embedded mutants (one loose edit of the lib, the scenario must FAIL):
#   - the PID comes WITH rc 0 (pidfile and pgrep paths): callers read `if pid=$(dolt_server_pid)`, and the old scenarios only compared the text;
#   - an EMPTY dolt.pid is "not the server", the lookup goes on to pgrep (a `return 0` there made the lib answer "success, empty PID" and skip the fallback);
#   - a dolt.pid of a DEAD process is never returned even when ps/lsof (stubbed to swear "dolt, listening" for any PID) would accept it: kill -0 is the liveness arbiter, not ps/lsof.
# EQUIVALENT (d04a2a88f3, L41 `[ -n "$_p" ] || return 1` without the `|| return 1`): with an empty $_p the next line, `kill -0 "" || return 1`, fails by itself (rc 1), so the answer is the same.
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

# ── ga-iu0fvlo: scenarios with their own stubs (do not depend on the PATH/stub state left by the ones above) ──
# stubs in dir $1: $2 = the PID that IS the server (ps says dolt, lsof says LISTEN), or ALL (every PID is, to test that kill -0 decides liveness on its own);
# the rest = what pgrep prints, one PID each (none = pgrep exits 1 with nothing)
mkstubs() {
  local d="$1" who="$2" p; shift 2; mkdir -p "$d"
  { echo '#!/usr/bin/env bash'; for p in "$@"; do echo "echo $p"; done; if [ "$#" -gt 0 ]; then echo 'exit 0'; else echo 'exit 1'; fi; } > "$d/pgrep"
  cat > "$d/ps" <<EOF
#!/usr/bin/env bash
pid=""
for a in "\$@"; do case "\$a" in [0-9]*) pid="\$a" ;; esac; done
if [ "$who" = ALL ] || [ "\$pid" = "$who" ]; then echo dolt; else echo sleep; fi
EOF
  cat > "$d/lsof" <<EOF
#!/usr/bin/env bash
pid="" prev=""
for a in "\$@"; do [ "\$prev" = "-p" ] && pid="\$a"; prev="\$a"; done
[ "$who" = ALL ] || [ "\$pid" = "$who" ]
EOF
  chmod +x "$d/pgrep" "$d/ps" "$d/lsof"
}
# dolt_server_pid with the stubs of $1 and the city $2 -> GOT (stdout) and GOT_RC (rc); a missing/unreadable answer is "" with rc != 0, never a PID
run_pid() { GOT="$( ( PATH="$1:$PATH"; GC_CITY="$2"; dolt_server_pid ) )"; GOT_RC=$?; }
mkcity() { mkdir -p "$1/.gc/runtime/packs/dolt"; rm -f "$1/.gc/runtime/packs/dolt/dolt.pid"; }   # no dolt.pid yet (the mutant runs reuse the dirs of the main run)

sc_rc_sucesso() {
  local b="$SCRATCH/sc1/bin" c="$SCRATCH/sc1/city"
  mkcity "$c"; mkstubs "$b" "$REAL_PID" "$DECOY_PID" "$REAL_PID"
  run_pid "$b" "$c"
  assert_eq "pgrep fallback: the server PID" "$REAL_PID" "$GOT"; assert_eq "pgrep fallback: rc 0 comes with the PID" 0 "$GOT_RC"
  printf '%s' "$REAL_PID" > "$c/.gc/runtime/packs/dolt/dolt.pid"; mkstubs "$b" "$REAL_PID" "$DECOY_PID"   # pgrep now has only the decoy: the PID can only come from dolt.pid
  run_pid "$b" "$c"
  assert_eq "dolt.pid: the server PID" "$REAL_PID" "$GOT"; assert_eq "dolt.pid: rc 0 comes with the PID" 0 "$GOT_RC"
}
sc_pidfile_vazio() {   # empty dolt.pid (interrupted write): not the server, the lookup goes on to pgrep
  local b="$SCRATCH/sc2/bin" c="$SCRATCH/sc2/city"
  mkcity "$c"; : > "$c/.gc/runtime/packs/dolt/dolt.pid"; mkstubs "$b" "$REAL_PID" "$DECOY_PID" "$REAL_PID"
  run_pid "$b" "$c"
  assert_eq "empty dolt.pid: falls through to pgrep and finds the server" "$REAL_PID" "$GOT"; assert_eq "empty dolt.pid: rc 0" 0 "$GOT_RC"
}
sc_pidfile_morto() {   # dolt.pid of a process that already exited; ps/lsof stubbed to accept ANY pid, so only kill -0 can refuse it
  local b="$SCRATCH/sc3/bin" c="$SCRATCH/sc3/city" dead="" i
  for i in 1 2 3; do sleep 0 & dead=$!; wait "$dead" 2>/dev/null; kill -0 "$dead" 2>/dev/null || break; dead=""; done   # a PID that is really gone (retry if it was reused at once)
  if [ -z "$dead" ]; then echo "FAIL: could not get a dead PID for the stale dolt.pid scenario (not measured)"; FAILURES=$((FAILURES + 1)); return; fi
  mkcity "$c"; printf '%s' "$dead" > "$c/.gc/runtime/packs/dolt/dolt.pid"; mkstubs "$b" ALL
  run_pid "$b" "$c"
  assert_eq "dolt.pid of a dead process: empty, ps/lsof alone do not decide" "" "$GOT"; assert_eq "dolt.pid of a dead process: rc 1" 1 "$GOT_RC"
}
sc_rc_sucesso; sc_pidfile_vazio; sc_pidfile_morto

echo "── mutants: one loose edit of the lib, the scenario must FAIL ──"
mutant() {   # name · original piece (\n = newline) · loose piece · scenario that must catch it
  local name="$1" old="$2" new="$3" case_fn="$4" res
  if ! python3 - "$LIB" "$old" "$new" > "$SCRATCH/mut-lib.sh" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
if src.count(old) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(old, new))
PY
  then echo "FAIL: mutant $name: the original piece does not appear exactly once in the lib (did the lib change?)"; FAILURES=$((FAILURES + 1)); return; fi
  res="$( ( source "$SCRATCH/mut-lib.sh"; $case_fn ) 2>&1 )"
  if printf '%s\n' "$res" | grep -q '^FAIL'; then echo "PASS: mutant $name killed by $case_fn"; else echo "FAIL: mutant $name SURVIVED $case_fn"; FAILURES=$((FAILURES + 1)); fi
}
mutant vazio-vira-servidor   '[ -n "$_p" ] || return 1' '[ -n "$_p" ] || return 0' sc_pidfile_vazio
mutant morto-vira-servidor   'kill -0 "$_p" 2>/dev/null || return 1' 'kill -0 "$_p" 2>/dev/null || return 0' sc_pidfile_morto
mutant vivo-fica-com-ps-lsof 'kill -0 "$_p" 2>/dev/null || return 1' 'kill -0 "$_p" 2>/dev/null' sc_pidfile_morto
mutant pidfile-sucesso-rc-1  "printf '%s' \"\$_cand\"\\n      return 0" "printf '%s' \"\$_cand\"\\n      return 1" sc_rc_sucesso
mutant pgrep-sucesso-rc-1    "printf '%s' \"\$_p\"\\n      return 0" "printf '%s' \"\$_p\"\\n      return 1" sc_rc_sucesso

if [ "$FAILURES" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
else
  echo "$FAILURES FAILURE(S)"
  exit 1
fi
