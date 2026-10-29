#!/usr/bin/env bash
# quality-gate-headroom-node.selftest.sh (ga-n4ql4ur) — a reviewer served by the Hetzner node does not spend the mini's reviewer ceiling
#
# Contents: 0 compile-guard · 1 gate_headroom_node_admit (pure matrix) · 2 against the REAL gate_headroom_decision · 3 the wiring block
# (the real code, extracted and run under set -euo pipefail) · 4 drift-guards (position, spawn-time warning)
#
# WHAT IS PROVEN. The gate admits a run iff local_live + per_run <= ceiling (gate_headroom_decision). The ceiling is clamped to the
# engine's cap for the LOCAL template `gate-reviewer` and local_live counts only that template, so a run served by
# `gate-reviewer-remote` never spends it — but when the local ceiling is FULL and the node has a free slot, the decision still says
# `defer ... dolt-calm-cap-reached` although the next run would open on the node. gate_headroom_node_admit turns exactly that one
# deferral into an admit, and only when the node pick (gate_remote_pick_template) says KIND=node. Every other reason (Dolt warm/hot,
# quota, memory, swap, no signal), the operator's pause (ceiling 0) and a run that needs more than one reviewer stay deferred.
#
# NOT PROVEN HERE: that a reviewer on the node finishes a review (runbook docs/runbooks/gate-reviewer-remote.md), nor the live log with
# more than 2 runs at once — that needs the daemon reloaded after the merge.
#
# Runs without Dolt, launchd, network, `gc` or `bd`. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/selftest-fail-closed.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-fail-closed.lib.sh" >&2; exit 2; }
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 — [$2] not in [$1]" ;; esac; }   # has <text> <needle> <label>

TMP="$(mktemp -d)"
selftest_cleanup() { rm -rf "$TMP" 2>/dev/null || true; }
selftest_fail_closed_arm selftest_cleanup

if [ ! -f "$DISPATCHER" ]; then echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; fi

echo "── 0. compile-guard ──"
if bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher: system bash -n clean (the dispatcher runs on bash 3.2)"; else bad "dispatcher: system bash -n FAILED"; fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 1; }
log()  { :; }
warn() { :; }
err()  { :; }

# NA <verdict> <ceiling> <reason> <perrun> <node_kind> — through a wrapper so a missing function is ONE failed assertion per case
# (the red run lists every behaviour it lacks) instead of a single FATAL.
NA() {
  if type gate_headroom_node_admit >/dev/null 2>&1; then gate_headroom_node_admit "$@"; else printf 'FUNCTION-MISSING'; fi
}

echo "── 1. gate_headroom_node_admit: the one deferral the node can resolve ──"
eq "local ceiling 2 full, calm Dolt, 1 reviewer per run, node has room → admit (the bead's case)" "$(NA defer 2 dolt-calm-cap-reached 1 node)" "admit"
eq "same, node FULL (pick says fallback) → keep the defer (never past the local cap when the node cannot take it)" "$(NA defer 2 dolt-calm-cap-reached 1 fallback)" "keep"
eq "same, flag off (pick says inert) → keep" "$(NA defer 2 dolt-calm-cap-reached 1 inert)" "keep"
eq "same, the pick never answered (kind empty) → keep: an unread node is not a node with room" "$(NA defer 2 dolt-calm-cap-reached 1 '')" "keep"
eq "same, kind is junk ('NODE') → keep: only the exact word 'node' counts" "$(NA defer 2 dolt-calm-cap-reached 1 NODE)" "keep"
eq "same, kind has a trailing blank ('node ') → keep" "$(NA defer 2 dolt-calm-cap-reached 1 'node ')" "keep"
eq "ceiling 3 (agent.toml's cap, no fragment entry) works the same → admit" "$(NA defer 3 dolt-calm-cap-reached 1 node)" "admit"
eq "verdict already admit → keep (this function never touches an admit)" "$(NA admit 2 dolt-calm 1 node)" "keep"
eq "verdict admit but with a cap-reached reason (inconsistent input) → keep: the verdict check is its own guard, not borrowed from the reason string" "$(NA admit 2 dolt-calm-cap-reached 1 node)" "keep"
eq "operator's pause, ceiling 0 (GATE_MAX_REVIEWERS=0) → keep: a pause is not 'cap reached'" "$(NA defer 0 dolt-calm-cap-reached 1 node)" "keep"
eq "ceiling empty → keep" "$(NA defer '' dolt-calm-cap-reached 1 node)" "keep"
eq "ceiling not a number → keep" "$(NA defer two dolt-calm-cap-reached 1 node)" "keep"
eq "Dolt WARM cap reached → keep: the remote reviewer talks to the same Dolt" "$(NA defer 1 dolt-warm-cap-reached 1 node)" "keep"
eq "Dolt HOT floor cap reached → keep" "$(NA defer 1 dolt-hot-floor-cap-reached 1 node)" "keep"
eq "no-signal-failopen cap reached → keep: a plane nobody could read is not calm" "$(NA defer 2 no-signal-failopen-cap-reached 1 node)" "keep"
for _r in quota-limited mem-critical swap-low dolt-hot no-signal-failclosed; do
  eq "hard stop '$_r' → keep" "$(NA defer 0 "$_r" 1 node)" "keep"
done
eq "a run needs 3 reviewers → keep: one node pick says room for ONE reviewer, the other two would fall back local" "$(NA defer 2 dolt-calm-cap-reached 3 node)" "keep"
eq "per-run empty → keep" "$(NA defer 2 dolt-calm-cap-reached '' node)" "keep"
eq "reason empty → keep" "$(NA defer 2 '' 1 node)" "keep"
eq "reason is a prefix-lookalike ('dolt-calm-cap-reached-x') → keep: exact match only" "$(NA defer 2 dolt-calm-cap-reached-x 1 node)" "keep"
eq "too few arguments → keep (never admit on a missing argument)" "$(NA defer 2)" "keep"

echo "── 2. against the REAL gate_headroom_decision (couples the reason string) ──"
# gate_headroom_decision <cpu> <lat> <qlim> <inflight> <cpu_hot> <cpu_warm> <lat_hot> <maxr> <perrun> <failopen>
_dec() { gate_headroom_decision "$@"; }
# Parsed exactly as the dispatcher parses HR_DECISION: field 1 verdict, field 2 ceiling, the rest the reason.
_via_real() { # <cpu> <inflight> <maxr> <perrun> <kind> → NA's answer for the decision the real function gives
  local d v c r
  d="$(_dec "$1" 120 0 "$2" 180 100 2500 "$3" "$4" 1)"
  v="$(printf '%s' "$d" | awk '{print $1}')"; c="$(printf '%s' "$d" | awk '{print $2}')"; r="$(printf '%s' "$d" | cut -d' ' -f3-)"
  printf '%s|%s' "$d" "$(NA "$v" "$c" "$r" "$4" "$5")"
}
eq "calm, 2 local live, cap 2, 1 per run, node room → real decision is defer …cap-reached, node turns it into admit" "$(_via_real 50 2 2 1 node)" "defer 2 dolt-calm-cap-reached|admit"
eq "calm, 2 local live, cap 2, node full → stays deferred" "$(_via_real 50 2 2 1 fallback)" "defer 2 dolt-calm-cap-reached|keep"
eq "calm, 1 local live, cap 2 → the real decision already admits; the node is not consulted for it" "$(_via_real 50 1 2 1 node)" "admit 2 dolt-calm|keep"
eq "Dolt warm, 1 local live → real decision defers 'dolt-warm-cap-reached'; node room does not matter" "$(_via_real 140 1 2 1 node)" "defer 1 dolt-warm-cap-reached|keep"
eq "operator's pause (GATE_MAX_REVIEWERS=0): the real decision says 'defer 0 dolt-calm-cap-reached' and the node must NOT undo the pause" "$(_via_real 50 0 0 1 node)" "defer 0 dolt-calm-cap-reached|keep"

echo "── 3. the wiring block, extracted from the dispatcher and run under set -euo pipefail ──"
WIRE_X="$(sed -n '/SELFTEST-EXTRACT gate-node-headroom-admit: BEGIN/,/SELFTEST-EXTRACT gate-node-headroom-admit: END/p' "$DISPATCHER" 2>/dev/null)"
if [ -z "$WIRE_X" ]; then
  bad "RED on the pre-fix tree: no SELFTEST-EXTRACT gate-node-headroom-admit block in the dispatcher (the Step 0b-1 defer is final even when the node has room)"
else
  # The inner shell needs the functions the dispatcher defines: hand it a tiny shim that sources it in lib-only mode.
  cat > "$TMP/shim.sh" <<SHIM
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" >/dev/null 2>&1
SHIM
  # wire <verdict> <ceiling> <reason> <perrun> <lib_ok> <pick_mode> [stale_kind]
  #   pick_mode: node | fallback | inert | silent (pick sets nothing) | fails (pick returns 1 and sets nothing)
  #   stale_kind: what GATE_REMOTE_PICK_KIND held from an EARLIER pick in the same process (Phase C's re-convene runs before admission)
  # Prints: VERDICT=… REASON=… ADMITTED=… PICKS=… then the log lines.
  # The inputs travel as W_* and are assigned AFTER the source: loading the dispatcher itself sets GATE_REMOTE_LIB_OK=0 (and 1 only if the
  # lib loads from $GC_CITY), so an input passed under its real name would be silently overwritten and every "node" case would read as
  # "lib absent" — the defers would then stand for the wrong reason.
  wire() {
    W_VERDICT="$1" W_CEILING="$2" W_REASON="$3" W_PERRUN="$4" W_LIB_OK="$5" PICK_MODE="$6" STALE_KIND="${7:-}" \
    bash -c '
      set -euo pipefail
      source "$1"
      HR_VERDICT="$W_VERDICT"; HR_CEILING="$W_CEILING"; HR_REASON="$W_REASON"; GATE_REVIEWERS_PER_RUN="$W_PERRUN"; GATE_REMOTE_LIB_OK="$W_LIB_OK"
      GATE_REMOTE_PICK_KIND="$STALE_KIND"; GATE_REMOTE_PICK_WHY=""; PICKS=0
      log() { printf "LOG:%s\n" "$*"; }
      gate_remote_pick_template() {
        PICKS=$((PICKS + 1))
        case "$PICK_MODE" in
          node)     GATE_REMOTE_PICK_KIND="node";     GATE_REMOTE_PICK_WHY="node has room - remote reviewer first" ;;
          fallback) GATE_REMOTE_PICK_KIND="fallback"; GATE_REMOTE_PICK_WHY="full (node has 2 of 2 gate-reviewer-remote sessions) - local reviewer" ;;
          inert)    GATE_REMOTE_PICK_KIND="inert";    GATE_REMOTE_PICK_WHY="gate-remote-reviewers.on absent" ;;
          silent)   : ;;
          fails)    return 1 ;;
        esac
        return 0
      }
      eval "$2"
      echo "VERDICT=$HR_VERDICT"; echo "REASON=$HR_REASON"; echo "ADMITTED=${GATE_NODE_ADMITTED:-unset}"; echo "PICKS=$PICKS"
    ' _ "$TMP/shim.sh" "$WIRE_X" 2>&1
  }
  out="$(wire defer 2 dolt-calm-cap-reached 1 1 node)"
  has "$out" "VERDICT=admit" "local cap full + node room → the verdict becomes admit"
  has "$out" "ADMITTED=1" "…and the run is marked admitted-on-node (the spawn step reads it)"
  has "$out" "REASON=dolt-calm-cap-reached+node-room" "…and the reason says it was the node (the 'Headroom OK' log line prints it)"
  has "$out" "PICKS=1" "…after exactly one node probe"
  has "$out" "LOG:" "…and the block says out loud what it did (ga-n4ql4ur)"
  out="$(wire defer 2 dolt-calm-cap-reached 1 1 fallback)"
  has "$out" "VERDICT=defer" "node full → the defer stands"
  has "$out" "ADMITTED=0" "…not marked admitted-on-node"
  has "$out" "PICKS=1" "…the node WAS asked"
  has "$out" "2 of 2 gate-reviewer-remote" "…and the log carries the node's own reason, so the deferral is explained"
  out="$(wire defer 2 dolt-calm-cap-reached 1 1 inert)"; has "$out" "VERDICT=defer" "flag off (inert) → the defer stands"
  out="$(wire defer 2 dolt-calm-cap-reached 1 0 node)"
  has "$out" "VERDICT=defer" "remote lib NOT loaded → the defer stands"; has "$out" "PICKS=0" "…and the node is never asked (the function does not exist there)"
  out="$(wire defer 1 dolt-warm-cap-reached 1 1 node)"
  has "$out" "VERDICT=defer" "Dolt warm → the defer stands"; has "$out" "PICKS=0" "…and the node probe (ssh) is NOT paid when its answer cannot change the outcome"
  out="$(wire defer 0 dolt-calm-cap-reached 1 1 node)"; has "$out" "VERDICT=defer" "pause (ceiling 0) → the defer stands"; has "$out" "PICKS=0" "…without a probe"
  out="$(wire defer 2 dolt-calm-cap-reached 3 1 node)"; has "$out" "VERDICT=defer" "3 reviewers per run → the defer stands"; has "$out" "PICKS=0" "…without a probe"
  out="$(wire admit 2 dolt-calm 1 1 node)"; has "$out" "VERDICT=admit" "already admit → unchanged"; has "$out" "PICKS=0" "…without a probe"; has "$out" "ADMITTED=0" "…and NOT marked admitted-on-node (it was local room)"
  out="$(wire defer 2 dolt-calm-cap-reached 1 1 silent node)"
  has "$out" "VERDICT=defer" "a pick that sets nothing, while an EARLIER pick in this process left KIND=node → the defer stands (stale 'node' is not an answer)"
  out="$(wire defer 2 dolt-calm-cap-reached 1 1 fails node)"
  has "$out" "VERDICT=defer" "a pick that FAILS (returns 1) under set -e: the gate does not abort and the defer stands"
  has "$out" "ADMITTED=0" "…not marked admitted-on-node"
fi

echo "── 4. drift-guards ──"
# Position: the override must run AFTER HR_REASON is parsed and BEFORE the defer branch that exits the sweep.
# Sourcing the dispatcher turned its `set -e` on for this shell: a grep with no match (the RED case) must not abort the run, so each
# line-number read ends in `|| true`. vazio → the line number stays empty and the check says "none"; falhou → same, never a pass.
L_REASON="$(grep -n 'HR_REASON=\$(printf' "$DISPATCHER" | head -1 | cut -d: -f1 || true)"
L_BEGIN="$(grep -n 'SELFTEST-EXTRACT gate-node-headroom-admit: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1 || true)"
L_DEFER="$(grep -n 'if \[ "\$HR_VERDICT" = "defer" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1 || true)"
if [ -n "$L_REASON" ] && [ -n "$L_BEGIN" ] && [ -n "$L_DEFER" ] && [ "$L_REASON" -lt "$L_BEGIN" ] && [ "$L_BEGIN" -lt "$L_DEFER" ]; then
  ok "the override sits between the HR_REASON parse (line $L_REASON) and the defer branch (line $L_DEFER)"
else
  bad "RED on the pre-fix tree: the override is not wired between the HR_REASON parse and the defer branch (reason=${L_REASON:-none} begin=${L_BEGIN:-none} defer=${L_DEFER:-none})"
fi
# Spawn time: a run admitted on the node's room that ends up opening LOCAL (the node refused at spawn) is the one residual risk — it must be said.
if grep -q 'GATE_NODE_ADMITTED:-0}" = "1"' "$DISPATCHER" && grep 'GATE_NODE_ADMITTED:-0}" = "1"' "$DISPATCHER" | grep -q 'SESSION_ID'; then
  ok "the local-spawn fallback warns when the run was admitted on the node's room (the residual risk is logged)"
else
  bad "RED on the pre-fix tree: nothing warns when a run admitted on the node's room falls back to a LOCAL reviewer above the local cap"
fi
# The pure function must be defined BEFORE the lib-only cutoff (this selftest sources the dispatcher in lib-only mode and found it above).
if type gate_headroom_node_admit >/dev/null 2>&1; then ok "gate_headroom_node_admit is defined before the lib-only cutoff"; else bad "RED on the pre-fix tree: gate_headroom_node_admit is not defined"; fi
# gate_headroom_decision itself must stay untouched in what the override depends on: the reason string.
if grep -q 'echo "defer \$ceiling \${reason}-cap-reached"' "$DISPATCHER"; then ok "gate_headroom_decision still names the local-cap deferral '<reason>-cap-reached'"; else bad "gate_headroom_decision no longer builds '<reason>-cap-reached' — the override would never match"; fi

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
selftest_summary_reached   # the lib fails every run that never got here
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0
