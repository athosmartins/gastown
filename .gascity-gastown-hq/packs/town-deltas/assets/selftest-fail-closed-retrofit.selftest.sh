#!/usr/bin/env bash
# selftest-fail-closed-retrofit.selftest.sh — ga-f31s7p (follow-up of ga-avma7j).
#
# PROOF that every selftest listed in RETROFITTED is fail-closed: a run that ABORTS before
# its summary exits non-zero, says so on the real stderr, and never reads as green.
#
# THE PROBE (one per listed file). Take the selftest, inject ONE line that kills the shell
# right after the point where `set -u` and the EXIT trap are both in force:
#     : "${SELFTEST_ABORT_PROBE_UNSET}"      # set -u: "unbound variable" aborts the shell
#     echo "SELFTEST_ABORT_PROBE_AFTER"      # must NEVER print: the code after the abort did not run
# then run that copy under /bin/bash (3.2.57 on macOS — the shell the dispatcher and the
# gate run on) and check:
#   * exit status != 0   (before the retrofit: 0 under 3.2 — the trap's `rm -rf` hid the abort)
#   * the AFTER marker is absent from stdout (the abort really happened where we put it)
#   * stderr carries "FATAL: selftest ended before its summary" (the lib's report, on fd 3)
# A probe that does not apply (anchor not found, injected line not exactly once) is a FAIL,
# never a skip: an unproven file is not a retrofitted file.
#
# WHY IT FAILS ON THE BASE. The retrofit's whole point is that the same injected line exits 0
# on the pre-retrofit file. Point SELFTEST_RETROFIT_DIR at a directory holding the
# pre-retrofit copies (e.g. `git show <base>:<path>` for each file) and this file goes red
# for every one of them; the anchor below matches the old `trap '…' EXIT` form as well as
# `selftest_fail_closed_arm`, exactly so that this can be done.
#
# SELF_DIR of the probed copy is rewritten to the real assets directory, so the copy still
# finds the scripts it tests. SELFTEST_ABORT_PROBE keeps a probe from probing itself.
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SELF_DIR/selftest-fail-closed.lib.sh"
[ -r "$LIB" ] || { echo "FATAL: $LIB not found — the fail-closed lib (ga-avma7j) is a precondition" >&2; exit 2; }
. "$LIB" || { echo "FATAL: cannot source $LIB" >&2; exit 2; }

# The retrofitted selftests (assets/<name>.selftest.sh). A file is added here in the same
# commit that adopts the lib in it — never before.
# eval-window-concurrency-guard is on the ga-f31s7p candidate list (rc=0 on the sweep) but is
# NOT retrofitted yet: it is already red on its own (2 assertions: it expects the dog pool's
# max_active_sessions to be 3 and the committed city.toml says 6), and a changed selftest that
# fails would hold the whole slice at the gate. Fix its stale expectation first, then retrofit.
RETROFITTED=(
  quality-gate-headroom
  gate-744kvc-push-skip-reason
  gate-branch-content-coherence
  gate-daemon-locked-cosmetic-release
  gate-dispatcher-cross-repo-rescue
  gate-supersede-cross-repo-sibling
  gate-wfbvx2-commit-verdict-classify
  quality-gate-full-suite-advisory
  story-delivery
)

PROBE_SRC_DIR="${SELFTEST_RETROFIT_DIR:-$SELF_DIR}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

if [ -n "${SELFTEST_ABORT_PROBE:-}" ]; then
  echo "refusing to run inside an abort probe (SELFTEST_ABORT_PROBE is set)" >&2; exit 2
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/selftest-fail-closed-retrofit.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
selftest_fail_closed_arm cleanup

INJ1=': "${SELFTEST_ABORT_PROBE_UNSET}"'
INJ2='echo "SELFTEST_ABORT_PROBE_AFTER"'

# Where the abort is injected: "<mode> <awk ERE>" — the first top-level line matching the
# ERE, injected BEFORE or AFTER it. The default is right after the FIRST top-level arm point:
# the lib's arm call or (pre-retrofit) a `trap '…' EXIT` / `trap fn EXIT` line — never
# `trap - EXIT`, which disarms. The bash 3.2 bug needs `set -e` AND `set -u` AND the trap in
# force, so a file whose `set -e` only starts later overrides the default with the first line
# after that point (measured: quality-gate-headroom has no `set -e` of its own — it gets it
# from sourcing the dispatcher at its section "Load the REAL helpers"; an abort injected before
# that source exits 1 even without the lib, one injected after it exits 0).
DEFAULT_POINT='after ^(selftest_fail_closed_arm([[:space:]]|$)|trap [^-].*[[:space:]]EXIT[[:space:]]*$)'
probe_point() {  # $1 = selftest name
  case "$1" in
    quality-gate-headroom) echo 'before ^type[[:space:]]+gate_headroom_decision[[:space:]]' ;;
    *) echo "$DEFAULT_POINT" ;;
  esac
}

# build_probe <name> -> $WORK_DIR/probe.selftest.sh ; rc 1 = the injection did not apply
build_probe() {
  local src="$PROBE_SRC_DIR/$1.selftest.sh" probe="$WORK_DIR/probe.selftest.sh" point mode re
  [ -r "$src" ] || return 1
  point="$(probe_point "$1")"; mode="${point%% *}"; re="${point#* }"
  awk -v self="$SELF_DIR" -v inj1="$INJ1" -v inj2="$INJ2" -v mode="$mode" -v re="$re" '
    /^SELF_DIR=/ && !s { print "SELF_DIR=\"" self "\""; s=1; next }
    !done && mode == "before" && $0 ~ re { print inj1; print inj2; done=1 }
    { print }
    !done && mode == "after"  && $0 ~ re { print inj1; print inj2; done=1 }
  ' "$src" > "$probe"
  [ "$(grep -cxF "$INJ1" "$probe")" = "1" ] && [ "$(grep -cxF "SELF_DIR=\"$SELF_DIR\"" "$probe")" = "1" ]
}

echo "── an aborted run is red, never green — probed under /bin/bash $(/bin/bash -c 'echo "$BASH_VERSION"') ──"
for name in "${RETROFITTED[@]}"; do
  echo "  [$name]"
  if ! build_probe "$name"; then
    bad "$name: the abort probe did not apply (file missing, no top-level arm point, or SELF_DIR line moved) — fail-closed is unproven"
    continue
  fi
  rc=0
  SELFTEST_ABORT_PROBE=1 /bin/bash "$WORK_DIR/probe.selftest.sh" > "$WORK_DIR/probe.out" 2> "$WORK_DIR/probe.err" || rc=$?
  if [ "$rc" -ne 0 ]; then ok "$name: a run that aborts mid-way exits NON-ZERO (rc=$rc)"
  else bad "$name: REGRESSION — a run that ABORTED mid-way exited 0 (an abort reads as green)"; fi
  if ! grep -q 'SELFTEST_ABORT_PROBE_AFTER' "$WORK_DIR/probe.out"; then ok "$name: the code after the injected abort did not run"
  else bad "$name: the probe's AFTER marker printed — the injected abort did not abort"; fi
  if grep -q 'FATAL: selftest ended before its summary' "$WORK_DIR/probe.err"; then ok "$name: the abort is reported on the real stderr"
  else bad "$name: the abort is silent — nothing on stderr says the run ended before its summary: [$(tr '\n' ' ' < "$WORK_DIR/probe.err" | cut -c1-200)]"; fi
  # Static: the file reaches its summary through the lib, once, and does not leave a
  # bare `trap … EXIT` that would replace the lib's trap after it was armed.
  arm_n="$(grep -c '^selftest_fail_closed_arm\([[:space:]]\|$\)' "$PROBE_SRC_DIR/$name.selftest.sh" || true)"
  sum_n="$(grep -c '^selftest_summary_reached\([[:space:]]\|$\)' "$PROBE_SRC_DIR/$name.selftest.sh" || true)"
  if [ "${arm_n:-0}" -ge 1 ] && [ "${sum_n:-0}" -ge 1 ]; then ok "$name: arms the lib ($arm_n) and marks its summary ($sum_n)"
  else bad "$name: does not adopt the lib (selftest_fail_closed_arm x${arm_n:-0}, selftest_summary_reached x${sum_n:-0})"; fi
  trap_n="$(grep -c '^trap ' "$PROBE_SRC_DIR/$name.selftest.sh" || true)"
  if [ "${trap_n:-0}" -eq 0 ]; then ok "$name: no top-level trap left to replace or disarm the lib's (no \`trap … EXIT\`, no \`trap - EXIT\`)"
  else bad "$name: $trap_n top-level \`trap\` line(s) left — a later \`trap … EXIT\` replaces the lib's trap and \`trap - EXIT\` disarms it, so the rest of the file is fail-open again"; fi
done

# The normal path must survive the trap too. Every file above ends on `[ "$FAIL" -eq 0 ]` (or an
# if/exit) AFTER selftest_summary_reached: a run that DID reach its summary keeps exactly the
# status its last command had — 0 for a pass, 1 for a failed assertion — and is never reported
# as an abort.
echo "  [normal path: a run that reaches its summary keeps its status]"
run_synth() {  # $1 = FAIL value, $2 = the last line of the script
  cat > "$WORK_DIR/synth.sh" <<SYNTH
set -euo pipefail
. "$LIB"
selftest_fail_closed_arm
FAIL=$1
selftest_summary_reached
$2
SYNTH
  SYNTH_RC=0
  /bin/bash "$WORK_DIR/synth.sh" > /dev/null 2> "$WORK_DIR/synth.err" || SYNTH_RC=$?
}
for last in '[ "$FAIL" -eq 0 ]' '[ "$FAIL" -eq 0 ] || exit 1'; do
  run_synth 0 "$last"
  if [ "$SYNTH_RC" -eq 0 ]; then ok "last line \`$last\`, FAIL=0: exits 0"; else bad "last line \`$last\`, FAIL=0: exited $SYNTH_RC, expected 0"; fi
  run_synth 1 "$last"
  if [ "$SYNTH_RC" -eq 1 ]; then ok "last line \`$last\`, FAIL=1: exits exactly 1"; else bad "last line \`$last\`, FAIL=1: exited $SYNTH_RC, expected 1"; fi
  if ! grep -q 'ended before its summary' "$WORK_DIR/synth.err"; then ok "last line \`$last\`, FAIL=1: is not reported as an abort (the summary was reached)"
  else bad "last line \`$last\`, FAIL=1: an ordinary failing run was mislabelled as an abort"; fi
done

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
selftest_summary_reached   # the lib fails every run that never got here
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
