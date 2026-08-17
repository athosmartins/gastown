#!/bin/bash
# framework-marker-labels-source-guard.selftest.sh — ga-vmn7kv (gate run ga-gdlzv6)
#
# WHAT THIS PROVES, and why `|| true` was never the guard it looked like.
#
# pilot-dispatcher.sh and context-check-dispatcher.sh both source the shared
# framework-marker-labels.sh at top-level init. Both run under `set -euo
# pipefail`. bash's `source`/`.` is a POSIX special builtin: when the target
# cannot be READ, the shell terminates immediately — the trailing `|| true` is
# never evaluated, and neither is anything after it.
#
# The consequence was not "the exclusion degrades to a no-op" (what both files'
# own comments claimed). It was: the dispatcher's entire top-level init dies,
# silently, before any log/warn call exists — pilot-dispatcher.sh is the sole
# path beads get claimed and dispatched through, on a ~300s launchd cycle. A
# briefly-missing sibling in packs/town-deltas/assets/ (a partial/desynced
# deploy — a failure class this town has hit repeatedly in this exact
# directory) would have taken the autonomous dispatch loop dark with no log
# line anywhere explaining why.
#
# These assertions FAIL against the pre-fix source (measured, not assumed):
# the pre-fix idiom exits 1 with zero output in the missing case, so REACHED is
# never printed and case (a)/(b) both fail.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "framework-marker-labels-source-guard.selftest (ga-vmn7kv)"

# Extract the real guarded idiom from the shipped dispatcher, so this test
# tracks the actual code instead of a hand-copied paraphrase that could drift.
# Both consumers use the identical block; pilot-dispatcher.sh is the canonical
# one. Anchored on the _GC_FML_SIBLING assignment through its `unset`.
# Extraction is deliberately VERSION-AGNOSTIC: it pulls whatever executable
# lines sit between the _FILTER_PREAPPROVAL_LABELS= anchor and the third-state
# guard, rather than grepping for the fixed version's own variable name. That
# matters for the Iron Law — a test keyed on `_GC_FML_SIBLING` would fail
# against the pre-fix source merely by not finding that string ("could not
# extract"), which proves nothing about the bug. Keyed on the RANGE, the
# pre-fix source yields its own `source ... || true` line, case (a) actually
# executes it, and the test fails with the real symptom: the probe dies at the
# source line and never prints REACHED. Verified RED that way against
# HEAD~ before this fix landed.
IDIOM=$(sed -n '/^_FILTER_PREAPPROVAL_LABELS=/,/^if \[ -z "\$GC_FRAMEWORK_MARKER_LABELS" \]/p' \
          "$SELF_DIR/pilot-dispatcher.sh" \
        | grep -vE '^[[:space:]]*#' \
        | grep -vE '^_FILTER_PREAPPROVAL_LABELS=' \
        | grep -vE '^if \[ -z "\$GC_FRAMEWORK_MARKER_LABELS" \]')
if [ -z "$(printf '%s' "$IDIOM" | tr -d '[:space:]')" ]; then
  bad "extracted an EMPTY sourcing block from pilot-dispatcher.sh between _FILTER_PREAPPROVAL_LABELS= and the third-state guard (did the anchors move?)"
  echo ""
  echo "framework-marker-labels-source-guard.selftest: PASS=$PASS FAIL=$FAIL"
  exit 1
fi
ok "extracted the sourcing block from the shipped pilot-dispatcher.sh (version-agnostic)"

# Harness: run the idiom under the SAME shell options the real dispatchers use
# (`set -euo pipefail`), with the sibling in a given state, and report whether
# execution survived past it.
# The idiom resolves its sibling relative to $(dirname "${BASH_SOURCE[0]}") —
# the probe's OWN location, not the caller's cwd. So the probe must be written
# INTO the directory under test; `cd`-ing there and running a probe from
# elsewhere would silently test the wrong directory (it did, on the first
# draft of this test: case (c) looked for the sibling in $WORK and reported
# <unset> even though the file was in place).
run_case() {
  local dir="$1"
  cat > "$dir/probe.sh" <<EOF
#!/bin/bash
set -euo pipefail
$IDIOM
echo "REACHED:\${GC_FRAMEWORK_MARKER_LABELS:-<unset>}"
EOF
  ( /bin/bash "$dir/probe.sh" 2>/dev/null )
}

# ── (a) sibling MISSING — the deploy-skew case ────────────────────────────────
mkdir -p "$WORK/missing"
OUT_MISSING=$(run_case "$WORK/missing")
case "$OUT_MISSING" in
  REACHED:*) ok "(a) sibling MISSING: init SURVIVES past the source (pre-fix: exit 1, nothing after it ran)" ;;
  *) bad "(a) sibling MISSING: execution died at the source line — got '${OUT_MISSING:-<empty>}'" ;;
esac

# ── (b) sibling EXISTS but is UNREADABLE — why [ -f ] is not enough ───────────
# `[ -f ]` passes here and `source` still terminates the shell (measured:
# exit 1, "Permission denied"). Only `[ -r ]` covers this.
mkdir -p "$WORK/noread"
printf 'GC_FRAMEWORK_MARKER_LABELS="gt:agent gt:rig"\n' > "$WORK/noread/framework-marker-labels.sh"
chmod 000 "$WORK/noread/framework-marker-labels.sh"
OUT_NOREAD=$(run_case "$WORK/noread")
case "$OUT_NOREAD" in
  REACHED:*) ok "(b) sibling UNREADABLE: init SURVIVES ([ -r ] guard, not [ -f ])" ;;
  *) bad "(b) sibling UNREADABLE: execution died — got '${OUT_NOREAD:-<empty>}' (is the guard [ -f ] instead of [ -r ]?)" ;;
esac

# ── (c) sibling PRESENT — the happy path still actually loads ────────────────
# Guarding must not silently become "never source anything": a guard that makes
# the feature permanently inert would pass (a) and (b) while breaking the whole
# point of the shared file.
mkdir -p "$WORK/present"
printf 'GC_FRAMEWORK_MARKER_LABELS="gt:agent gt:rig gt:convoy"\n' > "$WORK/present/framework-marker-labels.sh"
OUT_PRESENT=$(run_case "$WORK/present")
case "$OUT_PRESENT" in
  "REACHED:gt:agent gt:rig gt:convoy") ok "(c) sibling PRESENT: sourced correctly, labels loaded (guard did not make it inert)" ;;
  *) bad "(c) sibling PRESENT: expected the labels to load, got '${OUT_PRESENT:-<empty>}'" ;;
esac

# ── (d) the real shipped sibling loads, and is non-empty ─────────────────────
# Ties the test to production reality: the file the dispatchers actually source
# must exist, be readable, and define a non-empty list. Copied into a temp dir
# rather than probing $SELF_DIR in place — run_case writes a probe.sh next to
# the sibling, and this test must never write into the repo working tree.
mkdir -p "$WORK/real"
cp "$SELF_DIR/framework-marker-labels.sh" "$WORK/real/" 2>/dev/null \
  || bad "(d) could not copy the shipped framework-marker-labels.sh — does it exist?"
OUT_REAL=$(run_case "$WORK/real")
case "$OUT_REAL" in
  REACHED:) bad "(d) shipped framework-marker-labels.sh sourced but GC_FRAMEWORK_MARKER_LABELS is EMPTY" ;;
  REACHED:*) ok "(d) shipped framework-marker-labels.sh loads a non-empty list" ;;
  *) bad "(d) shipped sibling did not load — got '${OUT_REAL:-<empty>}'" ;;
esac

echo ""
echo "framework-marker-labels-source-guard.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
