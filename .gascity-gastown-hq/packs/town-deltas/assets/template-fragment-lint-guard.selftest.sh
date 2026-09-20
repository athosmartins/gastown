#!/usr/bin/env bash
# template-fragment-lint-guard.selftest.sh — regression test for
# template-fragment-lint-guard.sh (ga-8fwusw).
#
# Proves, against a throwaway copy of the REAL town-deltas pack (never the
# live tree), that the guard:
#   1. exits 0 and skips gc lint entirely when no changed file matches a
#      template/fragment/pack.toml pattern;
#   2. exits 0 (gc lint passes) against the pack as it stands today;
#   3. exits 1, with gc lint's own diagnostic in the output, when the exact
#      historical bug is reintroduced: `{{rig_root}}` (Go template
#      function-call syntax) written inside a prose sentence instead of the
#      field form `{{ .RigRoot }}` used everywhere else in the file.
#
# Case 3 is the one that matters: it is a test that FAILS against the
# pre-a25cc3724 state (the regression this whole bead is about) and passes
# only because template-fragment-lint-guard.sh now exists and gc lint
# actually parses fragments before the gate can call tests green.
#
# Run standalone: bash template-fragment-lint-guard.selftest.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/template-fragment-lint-guard.sh"
LIVE_PACK="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

check_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local desc="$1" haystack="$2" needle_re="$3"
  if printf '%s' "$haystack" | grep -E "$needle_re" >/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc (pattern '$needle_re' not found in output)"
    FAIL=$((FAIL + 1))
  fi
}

if ! command -v gc >/dev/null 2>&1; then
  echo "SKIP: 'gc' not on PATH -- cannot exercise gc lint in this environment."
  exit 0
fi

if [ ! -x "$GUARD" ] && [ ! -f "$GUARD" ]; then
  echo "FAIL: guard script not found at $GUARD"
  exit 1
fi

if [ ! -f "$LIVE_PACK/pack.toml" ]; then
  echo "FAIL: fixture source $LIVE_PACK/pack.toml not found -- cannot build fixture (is pack.toml tracked/present?)."
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$LIVE_PACK" "$WORK/town-deltas"

FRAG="$WORK/town-deltas/template-fragments/town-deltas.template.md"
if [ ! -f "$FRAG" ]; then
  echo "FAIL: fixture fragment $FRAG missing after copy."
  exit 1
fi

# ── Case 1: irrelevant changed file -- guard must no-op (exit 0) without
# needing gc lint to run at all. ────────────────────────────────────────
set +e
OUT1=$(bash "$GUARD" "$WORK" "README.md" 2>&1)
EXIT1=$?
set -e
check_exit "irrelevant file -> exit 0, no-op" "0" "$EXIT1"
check_contains "irrelevant file -> no-op message" "$OUT1" "skipping gc lint"

# ── Case 2: fragment as shipped today must lint clean. ──────────────────
set +e
OUT2=$(bash "$GUARD" "$WORK" "town-deltas/template-fragments/town-deltas.template.md" "town-deltas/pack.toml" 2>&1)
EXIT2=$?
set -e
check_exit "current fragment lints clean -> exit 0" "0" "$EXIT2"

# ── Case 3: reintroduce the exact historical bug (ga-3v2n4's fix commit
# shipped it; fixed by a25cc3724). Anchor on the surrounding sentence so
# this fails LOUDLY, not silently, if that text is ever edited away. ────
ANCHOR="mesma técnica"
if ! grep -qF "$ANCHOR" "$FRAG"; then
  echo "FAIL: anchor text for the historical bug not found in $FRAG -- source text has changed, update this selftest's anchor."
  exit 1
fi

if ! python3 - "$FRAG" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()
old = "'{{ .RigRoot }}'` + verificação pós-pour antes de assign/burn) já está"
new = "'{{rig_root}}'` + verificação pós-pour antes de assign/burn) já está"
if old not in text:
    sys.exit(1)
text = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
then
  echo "FAIL: could not reintroduce the historical bug into the fixture (exact anchor text mismatch) -- selftest cannot proceed, update the anchor above."
  exit 1
fi

set +e
OUT3=$(bash "$GUARD" "$WORK" "town-deltas/template-fragments/town-deltas.template.md" 2>&1)
EXIT3=$?
set -e
check_exit "historical bug reintroduced -> exit 1" "1" "$EXIT3"
check_contains "historical bug -> gc lint's own diagnostic surfaces" "$OUT3" 'rig_root.*not defined'

echo
echo "template-fragment-lint-guard.selftest.sh: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
