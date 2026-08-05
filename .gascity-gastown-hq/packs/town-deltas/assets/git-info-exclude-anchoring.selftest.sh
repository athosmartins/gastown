#!/usr/bin/env bash
# git-info-exclude-anchoring.selftest.sh (ga-x51d0)
#
# .git/info/exclude at the repo root carries bare rig-name patterns
# (mayor/, whatsapp_automation/, etc.) meant to exclude only the
# top-level rig runtime dirs. Git treats a bare `name/` pattern (no
# leading slash, no other slash) as `**/name/` — it matches at ANY
# depth, not just the repo root. This silently swallows real tracked-
# adjacent source dirs that share one of these names anywhere in the
# tree (e.g. .gascity-gastown-hq/packs/town-deltas/assets/prod-tests/
# whatsapp_automation/) — new files dropped there never show in
# `git status`, not even under `--ignored` unless you know to look.
# Fix: anchor each pattern with a leading slash, the standard gitignore
# idiom for "repo-root only, not any nested occurrence".
#
# .git/info/exclude is NOT version-controlled (local to each clone/
# machine) — this selftest verifies the LIVE machine's actual state via
# `git check-ignore`, read-only (no fixture files are created). It must
# be re-run — and the fix re-applied — independently on every clone. See
# ga-x51d0 for full context and root-class:error-vs-empty.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
EXCLUDE_FILE="$(git rev-parse --git-common-dir)/info/exclude"
cd "$REPO_ROOT"

RIG_NAMES="daemon deacon gastown lexbh marketing mayor observer property_scrapers whatsapp_automation witness shared events hooks warrants"
NESTED_PREFIX=".gascity-gastown-hq/packs/town-deltas/assets/prod-tests"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$EXCLUDE_FILE" ]; then
  echo "  ✗ exclude file not found at $EXCLUDE_FILE"
  echo "  RESULT: FAIL"
  exit 1
fi

echo "── 1. nested dirs sharing a rig name must NOT be swallowed (FIXTURE) ──"
for name in $RIG_NAMES; do
  probe="$NESTED_PREFIX/$name/__selftest_probe__"
  if git check-ignore -q -- "$probe" 2>/dev/null; then
    bad "'$name/' matches at nested depth (unanchored): $(git check-ignore -v -- "$probe" 2>/dev/null)"
  else
    ok "'$name/' does not swallow nested path $probe"
  fi
done

echo "── 2. top-level rig runtime dirs must STILL be excluded (CONTROL) ──"
for name in $RIG_NAMES; do
  probe="$name/__selftest_probe__"
  if git check-ignore -q -- "$probe" 2>/dev/null; then
    ok "'$name/' still excludes top-level $probe"
  else
    bad "'$name/' no longer excluded at top level — over-corrected"
  fi
done

echo "── 3. tracked-file status is a git invariant, not separately tested ──"
echo "  (ignore rules never affect already-tracked files' git-status output;"
echo "   criterion 3 from ga-x51d0 cannot regress via this class of edit.)"

echo ""
echo "────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
fi

echo ""
echo "  Fix: in $EXCLUDE_FILE, anchor each bare '<name>/' line with a"
echo "  leading '/' (e.g. 'mayor/' -> '/mayor/'). This file is git-local —"
echo "  the correction must be repeated on every machine/clone. See ga-x51d0."
echo "  RESULT: FAIL"
exit 1
