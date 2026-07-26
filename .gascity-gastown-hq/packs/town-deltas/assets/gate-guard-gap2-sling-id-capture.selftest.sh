#!/usr/bin/env bash
# gate-guard-gap2-sling-id-capture.selftest.sh — Drift-guard for ga-ale3o.
#
# Bug: quality-gate-guard.sh's Step 0c.2 (ga-pa36 GAP-2) parent-story
# stranding sweep extracts the sling-task wrapper bead id from a parent's
# "Sling task bead: <id>" comment via a jq capture() using Python-style named
# groups: capture("Sling task bead: (?P<id>[a-z][a-z0-9-]+)"). This
# deployment's jq (1.8.1, Oniguruma-backed) does not understand `(?P<name>...)`
# — only the Oniguruma-native `(?<name>...)` (no P) — and throws "Regex
# failure: undefined group option".
#
# The call site wraps this jq in `2>/dev/null | head -1 || echo ""`, so the
# regex error is silently swallowed and SLING_ID always resolves to empty —
# indistinguishable from "no Sling task bead comment on this bead". That means
# classify_parent_gap2 always receives sling_found=0, so GAP-2 can only ever
# reach its skip:no-sling branch — the free:fail-stranded / free:pass-stranded
# reconciliation paths (the actual point of GAP-2) were dead code on this
# deployment since the sweep was written.
#
# THE FIX: drop the `P` — capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)").
#
# Strategy: this jq program lives inline inside Step 0c.2's `for SC_ID in
# $GAP2_IDS; do ... done` sweep loop, not in a standalone function — it is not
# reachable via GATE_GUARD_LIB_ONLY=1 sourcing (same constraint documented in
# gate-eqjo-reviewing-terminal-clear.selftest.sh and
# gate-guard-gap1-content-merge-check.selftest.sh for sibling sweep code in
# this same file). So this harness (1) structurally confirms the live source
# carries the fixed Oniguruma-native form, (2) EXTRACTS the live jq program
# text verbatim from the source (so the test tracks the real code, not a
# hand-duplicated copy that could silently drift) and executes it against a
# realistic bd-show-shaped fixture — the actual functional proof, (3)
# regression-guards that zero Python-style `(?P<` capture groups remain in
# this file, and (4) is itself a MUTATION TEST: reverting the fix on a
# throwaway copy must flip the functional check to RED via the exact same
# `2>/dev/null || echo ""` failure mode described above (silent empty, not a
# visible crash) — proving this exact assertion would have caught the bug.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-2 sling-id jq capture() drift-guard (ga-ale3o) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

# extract_sling_jq_program <file> — pulls the jq program body (the 3 lines
# between the `jq -r '` opener and the `' 2>/dev/null ...` closer of the
# SLING_ID assignment) verbatim out of <file>. Anchored on stable literal
# substrings via awk's index(), not a regex, since the surrounding shell is
# full of literal $ and quote characters.
extract_sling_jq_program() {
  local file="$1"
  awk '
    index($0, "SLING_ID=$(echo \"$SC_SHOW\" | jq -r '"'"'") > 0 { grabbing=1; next }
    grabbing && index($0, "'"'"' 2>/dev/null | head -1") > 0 { grabbing=0 }
    grabbing { print }
  ' "$file"
}

# ── 1. Structural: live source uses the Oniguruma-native form, not (?P< ─────
echo "── 1. live source carries the fixed capture() syntax ──"
if grep -qF 'capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)")' "$GUARD"; then
  ok "quality-gate-guard.sh contains the Oniguruma-native capture (no P)"
else
  bad "quality-gate-guard.sh is MISSING the expected fixed capture() line (ga-ale3o regression)"
fi

if grep -qF '(?P<' "$GUARD"; then
  bad "quality-gate-guard.sh still contains a Python-style (?P< capture group — jq 1.8.1/Oniguruma cannot parse this"
else
  ok "no Python-style (?P< capture groups remain in quality-gate-guard.sh"
fi

# ── 2. Functional: run the LIVE jq program (extracted verbatim from source)
#    against a realistic bd-show --include-comments fixture. ────────────────
echo "── 2. live jq program correctly extracts the sling id ──"
LIVE_PROGRAM="$(extract_sling_jq_program "$GUARD")"
if [ -z "$LIVE_PROGRAM" ]; then
  bad "could not extract the SLING_ID jq program from $GUARD — anchors drifted?"
else
  # Mirrors the real fixture from ga-ale3o's filing: two comments (an older
  # dispatch round + the current one), text shaped like the real Pilot
  # dispatch comment (multi-line, "Sling task bead: <id>" on its own line
  # among other prose) — exercises sort_by(.created_at)|reverse too.
  FIXTURE='{
    "comments": [
      {"created_at":"2026-07-20T09:00:00Z","text":"Pilot dispatched builder (attempt 1).\nSling task bead: ga-oldest\nBuilder doctrine: fix bug -> /gate-done -> autonomous gate+delivery -> bead closed."},
      {"created_at":"2026-07-26T13:13:00Z","text":"Pilot dispatched builder '"'"'gastown.dog'"'"' at 2026-07-26T13:12:58Z (tier=bug/tech-debt, lane=small, rig=gascity).\nSling task bead: ga-2rp0x\nBuilder doctrine: fix bug -> /gate-done -> autonomous gate+delivery -> bead closed.\nNo human review required. SYSTEM QUALITY FIRST."}
    ]
  }'
  RESULT="$(echo "$FIXTURE" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
  if [ "$RESULT" = "ga-2rp0x" ]; then
    ok "extracted sling id 'ga-2rp0x' from the most recent comment (sort_by+reverse honored)"
  else
    bad "expected 'ga-2rp0x', got '$RESULT' — live jq program broken or extraction anchors drifted"
  fi

  # Second real fixture cited in ga-ale3o's filing (single comment, no reverse needed).
  FIXTURE2='{"comments":[{"created_at":"2026-07-26T13:13:00Z","text":"Sling task bead: ga-803hq"}]}'
  RESULT2="$(echo "$FIXTURE2" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
  [ "$RESULT2" = "ga-803hq" ] && ok "extracted sling id 'ga-803hq' from the second real fixture" \
    || bad "expected 'ga-803hq', got '$RESULT2'"

  # No "Sling task bead" comment at all → must resolve empty, not error, not garbage.
  FIXTURE3='{"comments":[{"created_at":"2026-07-26T13:13:00Z","text":"unrelated comment, no sling reference"}]}'
  RESULT3="$(echo "$FIXTURE3" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
  [ -z "$RESULT3" ] && ok "no 'Sling task bead' comment -> empty result (genuine no-match, not an error)" \
    || bad "expected empty for a comment set with no sling reference, got '$RESULT3'"
fi

# ── 3. MUTATION TEST: reverting to (?P<id> must silently break extraction,
#    reproducing the EXACT swallowed-error failure mode described in ga-ale3o
#    (the call site's own 2>/dev/null || echo "" wrapper), not a visible crash. ─
echo "── 3. MUTATION TEST: reintroducing (?P<id> must silently zero out SLING_ID ──"
MUTANT="$(mktemp "${TMPDIR:-/tmp}/gate-ale3o-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-ale3o-mutant-$$.sh")"
cleanup_mutant() { rm -f "$MUTANT"; }
trap cleanup_mutant EXIT
cp "$GUARD" "$MUTANT"

MUTATE_OK=0
python3 - "$MUTANT" <<'PYEOF' && MUTATE_OK=1
import sys
path = sys.argv[1]
needle = 'capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)")'
mutant = 'capture("Sling task bead: (?P<id>[a-z][a-z0-9-]+)")'
with open(path) as f:
    text = f.read()
count = text.count(needle)
if count != 1:
    print("EXPECTED_EXACTLY_1_OCCURRENCE_GOT_%d" % count, file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f:
    f.write(text.replace(needle, mutant, 1))
PYEOF

if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (expected exactly 1 fixed capture() line to revert) — INCONCLUSIVE, treat as FAIL"
else
  MUTANT_PROGRAM="$(extract_sling_jq_program "$MUTANT")"
  # Reproduce the call site's own real wrapper: 2>/dev/null | head -1 || echo ""
  MUTANT_RESULT="$(echo "$FIXTURE" | jq -r "$MUTANT_PROGRAM" 2>/dev/null | head -1 || echo "")"
  if [ -z "$MUTANT_RESULT" ]; then
    ok "mutant (Python-style capture restored): SLING_ID silently resolves empty under the real call-site wrapper — reproduces ga-ale3o exactly, proves section 2 is load-bearing"
  else
    bad "mutant did NOT reproduce the failure (got '$MUTANT_RESULT') — section 2's functional check may be vacuous against this exact regression"
  fi
  # Confirm it's a genuine jq compile error under the hood, not a coincidental empty match.
  if echo "$FIXTURE" | jq -r "$MUTANT_PROGRAM" >/dev/null 2>/tmp/gate-ale3o-mutant-stderr-$$; then
    bad "mutant jq program unexpectedly exited 0 — expected a Regex failure"
  else
    if grep -q "undefined group option" /tmp/gate-ale3o-mutant-stderr-$$ 2>/dev/null; then
      ok "mutant jq program fails with the documented 'undefined group option' error (swallowed by 2>/dev/null at the real call site)"
    else
      bad "mutant jq program failed, but not with the expected 'undefined group option' error"
    fi
  fi
  rm -f /tmp/gate-ale3o-mutant-stderr-$$ 2>/dev/null || true
fi

# ── 4. Sanity: the live guard is still valid bash after the fix ─────────────
echo "── 4. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n after the ga-ale3o fix"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
