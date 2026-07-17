#!/usr/bin/env bash
# gate-author-branch-fallback.selftest.sh (ga-tmkjg)
#
# Proves the gate-author-final-fallback block in quality-gate-dispatcher.sh:
# when BOTH gate.submitted_by (marker metadata) AND the source bead's
# assignee/created_by/owner are empty, the dispatcher no longer fail-safe
# aborts unconditionally. It first tries a BRANCH fallback (crew/<name>/<bead>
# always names the crew that owns the branch — the one signal that cannot be
# blanked by a raw `bd update` or a lifecycle-R4 reclaim, since the marker
# could not exist without it), and only if THAT also fails does it defer +
# ESCALATE (mail Mayor) instead of deferring silently.
#
# ROOT CAUSE this guards (ga-tmkjg, 2026-07-17): 12 markers went authorless
# (gate.submitted_by blanked + source-bead assignee/created_by/owner all
# null). The dispatcher picks the OLDEST queued marker each sweep; an
# unresolvable-author marker aborts (fail-safe, correct) but the abort was
# SILENT (log only) — gate-recovery-watchdog's grw-defer-requeue put it right
# back at the head of the same oldest-first queue, so it failed identically
# every sweep, head-of-line-blocking all 11 other queued markers behind it.
# Result: 0 gate-runs, 0 reviewers spawned, ~2h with nothing "em revisao",
# found only because Athos noticed the review queue looked empty. Same
# root-class as ga-p5q3 (a fail-safe that doesn't escalate is a silent stall,
# not a safe stop).
#
# Strategy mirrors gate-dispatcher-rig-resolve-noabort.selftest.sh: extract
# the LIVE block via its SELFTEST-EXTRACT sentinels (never a hand-copied
# duplicate) and exercise it under the dispatcher's own `set -euo pipefail`,
# stubbing only `bd`/`gc`/`log`/`err`/`warn` (no real Dolt writes, no real
# mail). A MUTATION-TEST (Test 6) proves this is not vacuous: neutralizing the
# branch-fallback assignment in a scratch copy must turn Test 1 red again —
# the literal acceptance criterion from the bug report ("Neutralize o
# fallback => volta a abortar => o gate para => VERMELHO").
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-author-branch-fallback.selftest =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_author_fallback <file> <AUTHOR> <BRANCH> <BEAD_ID> <MARKER_ID> <bd-log> <mail-log>
# Runs the live gate-author-final-fallback block under a real `set -euo
# pipefail`, with bd/gc/log/err/warn stubbed. `bd` calls (label remove/add)
# are appended to <bd-log>; `gc` calls (mail send) are appended to <mail-log>
# — one call per line each, so callers can assert on exactly what happened.
# Prints "REACHED_END|AUTHOR=<value>" iff the block did NOT abort (the abort
# path always `exit 0`s before that echo is reached) — this is the signal
# that distinguishes "resolved via fallback" from "deferred+escalated", since
# BOTH paths return rc=0 from the subshell.
run_author_fallback() {
  local file="$1" author="$2" branch="$3" bead_id="$4" marker_id="$5" bd_log="$6" mail_log="$7"
  local block
  block="$(extract_block "$file" "gate-author-final-fallback")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$bd_log"
  : > "$mail_log"
  bash -c '
    set -euo pipefail
    AUTHOR="$1"; BRANCH="$2"; BEAD_ID="$3"; MARKER_ID="$4"
    GC_CITY="/fake/city"; RIG="fake-rig"
    BD_LOG="$5"; MAIL_LOG="$6"
    bd()   { echo "$*" >> "$BD_LOG"; return 0; }
    gc()   { echo "$*" >> "$MAIL_LOG"; return 0; }
    log()  { echo "LOG: $*" >&2; }
    err()  { echo "ERR: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }
    '"$block"'
    echo "REACHED_END|AUTHOR=$AUTHOR"
  ' _ "$author" "$branch" "$bead_id" "$marker_id" "$bd_log" "$mail_log"
  return $?
}

# ── Test 1: THE bug scenario — both fields empty, branch names a crew ──────
echo "── (1) both gate.submitted_by and bead fields empty, branch names a crew → resolves via branch, does NOT abort ──"
BD1="$(mktemp)"; MAIL1="$(mktemp)"
OUT1="$(run_author_fallback "$DISPATCHER" "" "crew/oracle-wa/wa-1e7f5" "wa-1e7f5" "ga-wisp-u5rwq" "$BD1" "$MAIL1" 2>&1)"
RC1=$?
echo "$OUT1" | sed 's/^/    [test1] /'
[ "$RC1" -eq 0 ] && ok "rc=0" || bad "unexpected rc=$RC1"
case "$OUT1" in
  *"REACHED_END|AUTHOR=oracle-wa"*) ok "AUTHOR resolved to 'oracle-wa' via branch fallback, block reached end (no abort)";;
  *)                                bad "expected REACHED_END|AUTHOR=oracle-wa, got: $OUT1";;
esac
[ -s "$BD1" ]   && bad "unexpected bd call(s) on the fallback-success path: $(cat "$BD1")" \
                || ok "no bd label calls (marker never touched — it dispatches normally downstream)"
[ -s "$MAIL1" ] && bad "unexpected mail sent on the fallback-success path: $(cat "$MAIL1")" \
                || ok "no mail sent (nothing to escalate — author was resolved)"
rm -f "$BD1" "$MAIL1"

# ── Test 2: total failure — both fields empty, branch does NOT name a crew ─
echo "── (2) both fields empty, branch is NOT crew/<name>/* → defers AND escalates (mail Mayor), does not abort silently ──"
BD2="$(mktemp)"; MAIL2="$(mktemp)"
OUT2="$(run_author_fallback "$DISPATCHER" "" "fix/ga-tmkjg-gate-author-branch-fallback" "" "ga-wisp-abc123" "$BD2" "$MAIL2" 2>&1)"
RC2=$?
echo "$OUT2" | sed 's/^/    [test2] /'
[ "$RC2" -eq 0 ] && ok "rc=0 (deferred, not a hard failure)" || bad "unexpected rc=$RC2"
case "$OUT2" in
  *"REACHED_END"*) bad "block reached end — should have aborted via the second if: $OUT2";;
  *)                ok "block did NOT reach end (aborted via the second if, as expected)";;
esac
if grep -q "gate-status:dispatching" "$BD2" && grep -q "gate-status:deferred" "$BD2"; then
  ok "marker relabeled dispatching -> deferred: $(cat "$BD2")"
else
  bad "expected label remove gate-status:dispatching + label add gate-status:deferred, got: $(cat "$BD2")"
fi
if grep -q "mail send mayor" "$MAIL2"; then
  ok "mail sent to mayor (the ga-tmkjg fix — was previously silent-defer only)"
else
  bad "expected a 'mail send mayor' call, got: $(cat "$MAIL2")"
fi
if grep -q "ga-wisp-abc123" "$MAIL2"; then
  ok "mail identifies the affected marker id"
else
  bad "mail does not mention the marker id ga-wisp-abc123 — a human reading it can't act: $(cat "$MAIL2")"
fi
rm -f "$BD2" "$MAIL2"

# ── Test 3: non-regression — author already resolved, fallback untouched ──
echo "── (3) AUTHOR already resolved upstream → fallback block is a no-op (happy path unaffected) ──"
BD3="$(mktemp)"; MAIL3="$(mktemp)"
OUT3="$(run_author_fallback "$DISPATCHER" "batista-wa" "crew/batista-wa/wa-999" "wa-999" "ga-wisp-xyz" "$BD3" "$MAIL3" 2>&1)"
RC3=$?
echo "$OUT3" | sed 's/^/    [test3] /'
case "$OUT3" in
  *"REACHED_END|AUTHOR=batista-wa"*) ok "AUTHOR unchanged, block reached end normally";;
  *)                                  bad "expected REACHED_END|AUTHOR=batista-wa, got: $OUT3";;
esac
[ "$RC3" -eq 0 ] && ok "rc=0" || bad "unexpected rc=$RC3"
[ -s "$BD3" ] || [ -s "$MAIL3" ] \
  && bad "unexpected side effects on the already-resolved happy path: bd=$(cat "$BD3") mail=$(cat "$MAIL3")" \
  || ok "no bd/mail side effects (neither if-branch entered)"
rm -f "$BD3" "$MAIL3"

# ── Test 4: AUTHOR="null" (string) is treated the same as empty ───────────
echo "── (4) AUTHOR literal string 'null' + crew branch → same branch-fallback path as empty ──"
BD4="$(mktemp)"; MAIL4="$(mktemp)"
OUT4="$(run_author_fallback "$DISPATCHER" "null" "crew/thies-wa/ga-777" "ga-777" "ga-wisp-null1" "$BD4" "$MAIL4" 2>&1)"
case "$OUT4" in
  *"REACHED_END|AUTHOR=thies-wa"*) ok "'null' string treated like empty — resolved via branch fallback to 'thies-wa'";;
  *)                                bad "expected REACHED_END|AUTHOR=thies-wa, got: $OUT4";;
esac
rm -f "$BD4" "$MAIL4"

# ── Test 5: drift guards — key implementation lines still present verbatim ─
echo "── (5) drift guards on the live source ──"
grep -qF '_CREW_FROM_BRANCH=$(printf '"'"'%s'"'"' "$BRANCH" | sed -n '"'"'s#^crew/\([^/]\{1,\}\)/.*#\1#p'"'"')' "$DISPATCHER" \
  && ok "branch-derivation sed still present" \
  || bad "branch-derivation sed MISSING/changed — fallback source drifted?"
grep -qF 'gc --city "$GC_CITY" mail send mayor' "$DISPATCHER" \
  && ok "mail-Mayor escalation call still present" \
  || bad "mail-Mayor escalation call MISSING — ga-tmkjg regression (back to silent defer)?"
grep -qF 'err "Cannot derive author authoritatively for bead $BEAD_ID — aborting (fail-safe)."' "$DISPATCHER" \
  && ok "original fail-safe abort message unchanged (ga-p5q3-family log scrapers keep matching)" \
  || bad "fail-safe abort message changed/missing — downstream log matchers may break"
grep -qF 'bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred"' "$DISPATCHER" \
  && ok "deferred labeling on total-failure path still present" \
  || bad "deferred labeling MISSING on the total-failure path"

# ── Test 6: MUTATION-TEST — neutralize the branch fallback in a scratch
#    copy and confirm Test 1's key assertion goes RED. Proves this selftest
#    is actually exercising the fix, not a tautology (the bug's own
#    acceptance criterion: "Neutralize o fallback => volta a abortar").  ────
echo "── (6) MUTATION-TEST: neutralizing the branch fallback must turn Test 1 red again ──"
MUT="$(mktemp)"
cp "$DISPATCHER" "$MUT"
python3 - "$MUT" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
begin = "# SELFTEST-EXTRACT gate-author-final-fallback: BEGIN"
end = "# SELFTEST-EXTRACT gate-author-final-fallback: END"
i, j = text.index(begin), text.index(end)
block = text[i:j]
target = 'AUTHOR="$_CREW_FROM_BRANCH"'
mutated = block.replace(target, ': # ga-tmkjg selftest: fallback neutralized', 1)
if mutated == block:
    print("MUTATION_NOT_APPLIED", file=sys.stderr)
    sys.exit(1)
text = text[:i] + mutated + text[j:]
open(path, 'w').write(text)
PYEOF
if [ $? -ne 0 ]; then
  bad "mutation-test: could not construct a mutated scratch copy (script bug in the test itself)"
else
  BD_MUT="$(mktemp)"; MAIL_MUT="$(mktemp)"
  OUT_MUT="$(run_author_fallback "$MUT" "" "crew/oracle-wa/wa-1e7f5" "wa-1e7f5" "ga-wisp-u5rwq" "$BD_MUT" "$MAIL_MUT" 2>&1)"
  case "$OUT_MUT" in
    *"REACHED_END"*)
      bad "mutation-test: fallback neutralized but block STILL reached end — mutation had no effect: $OUT_MUT"
      ;;
    *)
      if grep -q "mail send mayor" "$MAIL_MUT"; then
        ok "mutation-test: neutralizing the fallback turns Test 1 red (now aborts+escalates instead of resolving) — test is not vacuous"
      else
        bad "mutation-test: block aborted after neutralization but did not escalate — unexpected shape: bd=$(cat "$BD_MUT") mail=$(cat "$MAIL_MUT")"
      fi
      ;;
  esac
  rm -f "$BD_MUT" "$MAIL_MUT"
fi
rm -f "$MUT"

echo ""
echo "== gate-author-branch-fallback: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
