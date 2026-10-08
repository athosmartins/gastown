#!/usr/bin/env bash
# pilot-dispatcher.gate-focus.selftest.sh (ga-kqa08j) — the Pilot's half of GATE FOCUS
# MODE: with PILOT_GATE_FOCUS=1, _filter_candidates keeps ONLY fixes of gate-rejected
# beads (gate:needs-fix or gate:fix-attempt:N); with it unset/0 nothing changes.
# Same extraction harness as pilot-dispatcher.held-until-alone.selftest.sh.
# ORIG_DISPATCHER=<pre-patch file> runs the differential: the focus case must FAIL there.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
ORIG_DISPATCHER="${ORIG_DISPATCHER:-}"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-gate-focus-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/input.json" <<'EOF'
[
  {"id":"ga-new","assignee":null,"labels":[],"description":"a new build"},
  {"id":"ga-needsfix","assignee":null,"labels":["gate:failed","gate:needs-fix","gate:fix-attempt:1"],"description":"x"},
  {"id":"ga-attemptonly","assignee":null,"labels":["gate:failed","gate:fix-attempt:2"],"description":"x"},
  {"id":"ga-other-gate","assignee":null,"labels":["gate-sha-failed:abc:code"],"description":"x"},
  {"id":"ga-autoheal","assignee":null,"labels":["origem:auto-healer-notify","story:approved"],"description":"x"},
  {"id":"ga-dano","assignee":null,"labels":["impacto:dano-ao-vivo"],"description":"x"}
]
EOF

run_filter() { # src tag focus
  local src="$1" tag="$2" focus="$3" log_fn le_fn consts fc_fn
  log_fn="log()  { echo \"[x] [pilot-dispatcher] \$*\"; }"
  le_fn="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$src")"
  consts="$(awk '/^_FILTER_PREAPPROVAL_LABELS=/{print} /^_FILTER_FRAMEWORK_MARKER_LABELS=/{print} /^_FILTER_RECLAIM_CAP=/{print} /^_PILOT_ENGINE_REBUILD_RE=/{print} /^_PILOT_ENGINE_REBUILD_NONREQUEST_RE=/{print}' "$src")"
  fc_fn="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$src")"
  [ -n "$fc_fn" ] || { echo "FATAL: _filter_candidates() not found in $src" >&2; exit 2; }
  cat > "$WORK/$tag.sh" <<EOF
$log_fn
$le_fn
source "$SELF_DIR/framework-marker-labels.sh"
$consts
$fc_fn
SELF_BEAD_ID=""
PILOT_GATE_FOCUS="$focus"
_filter_candidates < "$WORK/input.json"
EOF
  bash "$WORK/$tag.sh" 2>"$WORK/$tag.stderr" | jq -r '.[].id' 2>/dev/null | sort > "$WORK/$tag.ids"
}
ids() { tr '\n' ' ' < "$WORK/$1.ids" | sed 's/ $//'; }

echo "Scenario 1: focus OFF — the filter is inert"
run_filter "$DISPATCHER" off 0
[ "$(ids off)" = "ga-attemptonly ga-autoheal ga-dano ga-needsfix ga-new ga-other-gate" ] && ok "focus off keeps all 6" || bad "focus off changed the list: [$(ids off)]"

echo "Scenario 2: focus ON — only fixes of gate-rejected beads survive"
run_filter "$DISPATCHER" on 1
[ "$(ids on)" = "ga-attemptonly ga-autoheal ga-dano ga-needsfix" ] && ok "focus on keeps needs-fix, fix-attempt-only, auto-healer and live-damage; drops the new build and the sha-only label" \
  || bad "focus on: expected [ga-attemptonly ga-autoheal ga-dano ga-needsfix], got [$(ids on)]"

if [ -n "$ORIG_DISPATCHER" ]; then
  echo "Differential: a pre-patch dispatcher must give a DIFFERENT focus-on list (proves the test sees the change)"
  run_filter "$ORIG_DISPATCHER" orig 1
  [ "$(ids orig)" != "$(ids on)" ] && ok "pre-patch focus-on list differs ([$(ids orig)] vs [$(ids on)])" \
    || bad "pre-patch gives the same list [$(ids orig)] — the test cannot tell the change apart"
fi

echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
