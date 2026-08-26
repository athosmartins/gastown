#!/usr/bin/env bash
# gate-fail-notify-branch-author.selftest.sh (ga-409f4)
#
# Proves the NOTIFY_AUTHOR resolution added to quality-gate-dispatcher.sh's
# gate_finalize_run() and quality-gate-guard.sh: gate FAIL/PASS-hold/park
# notifications must reach whoever actually wrote the branch, not whoever a
# bead happens to be assigned to.
#
# ROOT CAUSE this guards (ga-409f4, reported by digo-wa, live case wa-o4ygn):
# bead assignee=digo-wa (he filed the bug), but the code was being written by
# mila on branch crew/mila/wa-o4ygn-r2. The gate's FAIL nudge went to
# digo-wa's session — 2 hops and ~15min before mila (the actual author)
# learned her branch had failed. $AUTHOR (bead assignee/created_by/owner) is
# correctly used for a DIFFERENT purpose — self-review exclusion
# (quality-gate-guard.sh Step 5's SECURITY note) — but every FAIL/PASS-hold/
# park notification call site was reusing that same variable as its nudge/
# mail TARGET too.
#
# ACCEPTANCE CRITERIA (from the bug report):
#   - Branch crew/<X>/<bead> with bead assignee=<Y> -> feedback goes to <X>.
#   - CONTROLE: branch without a resolvable crew segment -> falls back to
#     the bead assignee (today's unchanged behavior).
#
# Strategy mirrors gate-author-branch-fallback.selftest.sh: extract the LIVE
# NOTIFY_AUTHOR resolution via its SELFTEST-EXTRACT sentinels (never a
# hand-copied duplicate) from BOTH quality-gate-dispatcher.sh and
# quality-gate-guard.sh, and exercise it under a real `set -euo pipefail`.
# A MUTATION-TEST proves this is not vacuous: neutralizing the crew-from-
# branch tier must turn the primary scenario red again.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-fail-notify-branch-author.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$GUARD" ]      || { echo "FATAL: guard not found at $GUARD" >&2; exit 2; }

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_notify_resolve <file> <BRANCH> <AUTHOR> -> prints "NOTIFY_AUTHOR=<value>"
run_notify_resolve() {
  local file="$1" branch="$2" author="$3" block
  block="$(extract_block "$file" "notify-author-resolve")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  bash -c '
    set -euo pipefail
    BRANCH="$1"; AUTHOR="$2"
    '"$block"'
    echo "NOTIFY_AUTHOR=$NOTIFY_AUTHOR"
  ' _ "$branch" "$author"
}

# ── Tests 1-4: the resolution itself, against BOTH files ───────────────────
for FILE_LABEL_PAIR in "$DISPATCHER:dispatcher" "$GUARD:guard"; do
  FILE="${FILE_LABEL_PAIR%%:*}"
  LABEL="${FILE_LABEL_PAIR##*:}"

  echo "── ($LABEL) crew/<X>/<bead> branch, assignee=<Y> -> resolves to <X> (THE bug scenario) ──"
  OUT="$(run_notify_resolve "$FILE" "crew/mila/wa-o4ygn-r2" "digo-wa" 2>&1)"
  case "$OUT" in
    "NOTIFY_AUTHOR=mila") ok "[$LABEL] resolved to branch author 'mila', not bead assignee 'digo-wa'";;
    *)                    bad "[$LABEL] expected NOTIFY_AUTHOR=mila, got: $OUT";;
  esac

  echo "── ($LABEL) CONTROLE: non-crew branch (dog fix/*) -> falls back to bead assignee, unchanged ──"
  OUT="$(run_notify_resolve "$FILE" "fix/ga-3zi69-gate-notify-author" "digo-wa" 2>&1)"
  case "$OUT" in
    "NOTIFY_AUTHOR=digo-wa") ok "[$LABEL] non-crew branch falls back to bead-derived AUTHOR (today's behavior preserved)";;
    *)                       bad "[$LABEL] expected NOTIFY_AUTHOR=digo-wa (fallback), got: $OUT";;
  esac

  echo "── ($LABEL) CONTROLE: wa-worker pool branch -> falls back to bead assignee (e.g. mayor) ──"
  OUT="$(run_notify_resolve "$FILE" "crew/wa-worker/wa-4821" "" 2>&1)"
  case "$OUT" in
    "NOTIFY_AUTHOR=wa-worker") ok "[$LABEL] crew/wa-worker/* still resolves via the crew segment (wa-worker itself)";;
    *)                         bad "[$LABEL] expected NOTIFY_AUTHOR=wa-worker, got: $OUT";;
  esac

  echo "── ($LABEL) empty branch + empty AUTHOR -> resolves empty (both signals absent, no crash) ──"
  OUT="$(run_notify_resolve "$FILE" "" "" 2>&1)"
  RC=$?
  case "$OUT" in
    "NOTIFY_AUTHOR=") ok "[$LABEL] empty branch + empty AUTHOR -> empty NOTIFY_AUTHOR, rc=$RC (matches existing [ -n \"\$NOTIFY_AUTHOR\" ] guards downstream)";;
    *)                bad "[$LABEL] expected NOTIFY_AUTHOR= (empty), got: $OUT";;
  esac
done

# ── Test 5: drift guard — every notify call site uses NOTIFY_AUTHOR or the
#    already-correct REBASE_AUTHOR (rebase-envelope subsystem, untouched by
#    this bug fix — see quality-gate-dispatcher.sh's ga-6dp9/gate-fix-2
#    comments for why that subsystem keeps its own, separately-reviewed
#    identity handling). No FAIL/PASS-hold/park nudge or mail should still
#    target the bare, bead-derived $AUTHOR. ───────────────────────────────
echo "── (5) drift-guard: no gate_finalize_run notify call site regresses to bare \$AUTHOR ──"
GFR_BLOCK="$(awk '/^gate_finalize_run\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DISPATCHER")"
BARE_AUTHOR_NOTIFY=$(printf '%s\n' "$GFR_BLOCK" | grep -E '(nudge|mail send) "\$AUTHOR"' | grep -v 'NOTIFY_AUTHOR' || true)
if [ -z "$BARE_AUTHOR_NOTIFY" ]; then
  ok "gate_finalize_run() has zero nudge/mail call sites still targeting bare \$AUTHOR"
else
  bad "gate_finalize_run() still has a notify call site targeting bare \$AUTHOR: $BARE_AUTHOR_NOTIFY"
fi
# ga-36ta4: also recognize notify_author_with_fallback(...) calls that pass
# NOTIFY_AUTHOR as an argument — several sites (ga-lxz5w, the fix-attempt-cap
# site, and ga-36ta4's own conversions) route through that wrapper rather
# than a bare `mail send "$NOTIFY_AUTHOR"`. Confirmed pre-existing: this
# count was already 2 (not the expected >=5) right after ga-55syh merged,
# before any ga-36ta4 change — same root cause as every other drift-guard
# fixed in that bead, just not caught until now.
NOTIFY_COUNT=$(printf '%s\n' "$GFR_BLOCK" | grep -cE '(nudge|mail send) "\$NOTIFY_AUTHOR"|notify_author_with_fallback.*NOTIFY_AUTHOR')
if [ "$NOTIFY_COUNT" -ge 5 ]; then
  ok "gate_finalize_run() has $NOTIFY_COUNT NOTIFY_AUTHOR-targeted call sites (>=5 expected)"
else
  bad "expected >=5 NOTIFY_AUTHOR-targeted call sites in gate_finalize_run(), found $NOTIFY_COUNT"
fi
GUARD_BARE=$(grep -E '(nudge|mail send) "\$AUTHOR"' "$GUARD" | grep -v 'NOTIFY_AUTHOR' || true)
if [ -z "$GUARD_BARE" ]; then
  ok "quality-gate-guard.sh has zero nudge/mail call sites still targeting bare \$AUTHOR"
else
  bad "quality-gate-guard.sh still has a notify call site targeting bare \$AUTHOR: $GUARD_BARE"
fi

# ── Test 6: the ASSIGNEE-KEEP decision inside gate_fail_assignee_action's
#    "keep" branch must still key on the bead-derived $AUTHOR — that is bead
#    OWNERSHIP, a different concern from notification routing, and out of
#    this bug's scope. Only the nudge TARGET at that site should have moved
#    to NOTIFY_AUTHOR. ──────────────────────────────────────────────────────
echo "── (6) non-regression: assignee-keep decision (bead ownership) still keys on \$AUTHOR, not NOTIFY_AUTHOR ──"
if grep -qF 'bd -C "$BEAD_CITY" assign "$BEAD_ID" "$AUTHOR"' "$DISPATCHER"; then
  ok "gate_fail_assignee_action 'keep' branch still assigns the bead to \$AUTHOR (ownership unchanged, ga-jyox intact)"
else
  bad "assignee-keep line missing/changed — either the ga-jyox 'keep' behavior regressed, or it was wrongly repointed at NOTIFY_AUTHOR"
fi

# ── Test 7: MUTATION-TEST — neutralize the crew-from-branch tier and confirm
#    the primary scenario goes RED again. Proves this selftest actually
#    exercises the fix, not a tautology. ────────────────────────────────────
echo "── (7) MUTATION-TEST: neutralizing the crew-from-branch tier must turn the primary scenario red again ──"
MUT="$(mktemp)"
cp "$DISPATCHER" "$MUT"
python3 - "$MUT" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
begin = "# SELFTEST-EXTRACT notify-author-resolve: BEGIN"
end = "# SELFTEST-EXTRACT notify-author-resolve: END"
i, j = text.index(begin), text.index(end)
block = text[i:j]
target = "NOTIFY_AUTHOR=$(printf '%s' \"$BRANCH\" | sed -n 's#^crew/\\([^/]\\{1,\\}\\)/.*#\\1#p')"
mutated = block.replace(target, 'NOTIFY_AUTHOR=""', 1)
if mutated == block:
    print("MUTATION_NOT_APPLIED", file=sys.stderr)
    sys.exit(1)
text = text[:i] + mutated + text[j:]
open(path, 'w').write(text)
PYEOF
if [ $? -ne 0 ]; then
  bad "mutation-test: could not construct a mutated scratch copy (script bug in the test itself)"
else
  OUT_MUT="$(run_notify_resolve "$MUT" "crew/mila/wa-o4ygn-r2" "digo-wa" 2>&1)"
  case "$OUT_MUT" in
    "NOTIFY_AUTHOR=digo-wa")
      ok "mutation-test: neutralizing the crew-from-branch tier turns the primary scenario red (falls to digo-wa again) — test is not vacuous"
      ;;
    *)
      bad "mutation-test: unexpected result after neutralization: $OUT_MUT"
      ;;
  esac
fi
rm -f "$MUT"

echo ""
echo "== gate-fail-notify-branch-author: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
