#!/usr/bin/env bash
# quality-gate-guard.selftest.sh — regression harness for the pure decision
# functions of the gate guard (ga-jfo7 AWOL-run recovery). Sources the guard in
# GATE_GUARD_LIB_ONLY=1 mode so only the pure functions load (no main loop, no I/O).
#
# Focus (ga-jfo7 review-2 blocker): verdict_bead_count_for_run conflated a FAILED
# bd query with a confirmed-empty result via `bd ... || echo "[]"`, so a Dolt
# timeout (rc!=0) read as "0 verdict beads" — identical to a genuinely reviewer-
# AWOL run — and fired supersede:requeue-marker against a HEALTHY run. Dolt-hot is
# exactly when both the query fails AND real AWOLs happen, so the conflation is
# maximally dangerous. The pure verdict_count_from_query() must return a NON-numeric
# "unknown" on query failure so the caller's ''|*[!0-9]* fail-safe defers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/quality-gate-guard.sh"
# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with `set -euo pipefail`; the harness counts its own pass/fail

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

# ── verdict_count_from_query <rc> <stdout> — the ga-jfo7 review-2 fix ─────────
echo "verdict_count_from_query: query-failure must NOT read as 0 verdicts"
r=$(verdict_count_from_query 0 '[{"a":1},{"b":2}]'); [ "$r" = "2" ] && ok "rc0 2-elem array → 2" || bad "rc0 2-elem got '$r'"
r=$(verdict_count_from_query 0 '[{"a":1}]');        [ "$r" = "1" ] && ok "rc0 1-elem array → 1" || bad "rc0 1-elem got '$r'"
r=$(verdict_count_from_query 0 '[]');               [ "$r" = "0" ] && ok "rc0 empty array → 0 (genuine confirmed-empty)" || bad "rc0 [] got '$r'"
# THE regression: a failed query (nonzero rc) must be 'unknown', never numeric 0.
r=$(verdict_count_from_query 1 '');   case "$r" in ''|*[!0-9]*) ok "rc1 (Dolt query FAILED) → non-numeric unknown ('$r')" ;; *) bad "REGRESSION: rc1 mapped to numeric '$r' — the || echo [] bug: a query failure would supersede a HEALTHY run" ;; esac
r=$(verdict_count_from_query 1 '[]'); case "$r" in ''|*[!0-9]*) ok "rc1 with stale [] payload → still unknown (rc wins)" ;; *) bad "REGRESSION: rc1 [] mapped to numeric '$r'" ;; esac
r=$(verdict_count_from_query 2 '[{"a":1}]'); case "$r" in ''|*[!0-9]*) ok "rc2 with a real-looking payload → unknown (never trust a failed query's body)" ;; *) bad "REGRESSION: rc2 mapped to numeric '$r'" ;; esac
r=$(verdict_count_from_query 0 'not json');  case "$r" in ''|*[!0-9]*) ok "rc0 unparseable body → unknown (jq failure ≠ 0)" ;; *) bad "unparseable got numeric '$r'" ;; esac
r=$(verdict_count_from_query 0 '');          case "$r" in ''|*[!0-9]*) ok "rc0 empty body → unknown (bd returns [] for 0 matches; '' is anomalous)" ;; *) bad "rc0 empty body got numeric '$r'" ;; esac

# ── the caller contract (line ~638): unknown must fail-safe to 1 (skip), not 0 ─
echo "caller fail-safe: query-failure must NOT trigger the supersede branch"
zv=$(verdict_count_from_query 1 ''); case "$zv" in ''|*[!0-9]*) zv=1 ;; esac
[ "$zv" = "1" ] && ok "query-failure → ZV_TOTAL=1 → the 'if ZV_TOTAL = 0' supersede branch is skipped" || bad "fail-safe gave zv='$zv' — would enter the supersede branch"
zv=$(verdict_count_from_query 0 '[]'); case "$zv" in ''|*[!0-9]*) zv=1 ;; esac
[ "$zv" = "0" ] && ok "genuine confirmed-0 still flows to the supersede branch (recovery still works)" || bad "confirmed-0 became zv='$zv' — recovery would never fire"

# ── reconcile_zero_verdict_run_action regression (age-anchor contract, attempt 1) ─
echo "reconcile_zero_verdict_run_action: age anchor + marker-status routing"
r=$(reconcile_zero_verdict_run_action 5 15 dispatching);  [ "$r" = "skip" ] && ok "young (5≤15) → skip regardless of status (fresh handoff needs a moment)" || bad "young got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 queued);      [ "$r" = "supersede:still-queued" ] && ok "aged+queued → still-queued (close orphan bookkeeping, don't touch a healthily-queued marker)" || bad "aged queued got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 dispatching); [ "$r" = "supersede:requeue-marker" ] && ok "aged+dispatching → requeue-marker (dispatcher died mid-flight)" || bad "aged dispatching got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 claimed);     [ "$r" = "supersede:requeue-marker" ] && ok "aged+claimed → requeue-marker" || bad "aged claimed got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 '');          [ "$r" = "skip" ] && ok "aged+empty-status → skip (fail-safe, never guess)" || bad "empty status got '$r'"
r=$(reconcile_zero_verdict_run_action 30 15 reviewing);   [ "$r" = "skip" ] && ok "aged+unrecognized-status → skip (fail-safe)" || bad "unrecognized status got '$r'"

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
