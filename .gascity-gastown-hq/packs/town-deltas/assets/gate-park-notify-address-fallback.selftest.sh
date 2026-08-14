#!/usr/bin/env bash
# gate-park-notify-address-fallback.selftest.sh (ga-z3i2p)
#
# Proves the Step 5a park-author-notify cascade in quality-gate-guard.sh:
# NOTIFY_AUTHOR (ga-409f4's crew-branch-derived identity, e.g. "oracle" from
# crew/oracle/wa-166gf) is frequently a BARE, UNDELIVERABLE mail address — the
# live session mailbox is rig-qualified ("oracle-wa"), and `gc mail send`
# resolves recipients by EXACT session_name/alias match with no prefix/fuzzy
# fallback (internal/session/resolve.go ResolveSessionID). Before this fix,
# a failed send became a bare log WARN and nothing else — the author was
# NEVER told their marker parked, even though this park is TERMINAL (no
# retry will ever re-attempt it) and /gate-done explicitly promises "you
# will be mailed when the gate passes or fails".
#
# REAL INCIDENT (2026-08-14, reported by oracle-wa): marker ga-gq8x5 (bead
# wa-166gf) parked at Step 5a. Guard log: "WARN: Could not mail author oracle
# for Step 5a park on wa-166gf". oracle-wa (the live session alias) never
# received the notice; the guard tried the bare crew segment "oracle" only.
#
# FIX: try, in order — (1) the bare NOTIFY_AUTHOR (covers pool/template
# aliases like wa-worker that ARE already exact), (2) NOTIFY_AUTHOR qualified
# with the source bead's own rig-code suffix (covers persistent named crew:
# oracle -> oracle-wa; the bead's own prefix is authoritative for ITS rig, no
# guessing across rigs), (3) the bead-derived $AUTHOR (historically
# deliverable). If EVERY candidate fails: mail mayor (second destination) +
# a durable marker comment, so "could not notify" can never look identical
# to "notified" in a bd list/painel view.
#
# Strategy mirrors gate-author-branch-fallback.selftest.sh and
# gate-fail-notify-branch-author.selftest.sh: extract the LIVE block via its
# SELFTEST-EXTRACT sentinel (never a hand-copied duplicate), exercise it
# under the guard's own `set -euo pipefail`, stubbing only `gc`/`bd`/`warn`/
# `log` (no real Dolt writes, no real mail). A per-recipient stub lets each
# scenario decide which mail addresses "exist" — MUTATION-TESTS (7) prove
# this is not vacuous.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-park-notify-address-fallback.selftest =="

[ -f "$GUARD" ] || { echo "FATAL: guard not found at $GUARD" >&2; exit 2; }

# extract_block <file> <sentinel-name> -> prints the block between BEGIN/END,
# stripped of the sentinel comment lines themselves.
extract_block() {
  local file="$1" name="$2"
  sed -n "/# SELFTEST-EXTRACT ${name}: BEGIN/,/# SELFTEST-EXTRACT ${name}: END/p" "$file" \
    | sed '1d;$d'
}

# run_park_notify <file> <NOTIFY_AUTHOR> <AUTHOR> <BEAD_ID> <MARKER_ID> \
#                  <BRANCH> <fail-recipients> <mail-log> <bd-log>
# Runs the live park-author-notify block under a real `set -euo pipefail`,
# with gc/bd/warn/log stubbed. <fail-recipients> is a space-separated list of
# recipients (matched against the arg right after "send") that the stub `gc
# mail send` treats as UNRESOLVABLE (rc=1); every other recipient succeeds
# (rc=0) — mirroring gc's own exact-match-or-error resolution. `gc` calls are
# appended to <mail-log>, `bd` calls to <bd-log>, one call per line each.
# Prints "PARK_NOTIFIED=<value>" at the end (empty iff every candidate failed).
run_park_notify() {
  local file="$1" notify_author="$2" author="$3" bead_id="$4" marker_id="$5" \
        branch="$6" fail_recipients="$7" mail_log="$8" bd_log="$9" block
  block="$(extract_block "$file" "park-author-notify")"
  if [ -z "$block" ]; then
    echo "COULD_NOT_EXTRACT_BLOCK" >&2
    return 99
  fi
  : > "$mail_log"
  : > "$bd_log"
  bash -c '
    set -euo pipefail
    NOTIFY_AUTHOR="$1"; AUTHOR="$2"; BEAD_ID="$3"; MARKER_ID="$4"; BRANCH="$5"
    PARK_REASON="source bead $BEAD_ID carries gate:needs-human (circuit-broken)"
    UNBLOCK_HINT="Get a human/Mayor to resolve the gate:needs-human circuit-break on $BEAD_ID"
    GC_CITY="/fake/city"
    FAIL_RECIPIENTS="$6"; MAIL_LOG="$7"; BD_LOG="$8"
    gc() {
      echo "$*" >> "$MAIL_LOG"
      local args=("$@") recipient="" i
      for ((i=0; i<${#args[@]}; i++)); do
        if [ "${args[$i]}" = "send" ]; then recipient="${args[$((i+1))]}"; break; fi
      done
      case " $FAIL_RECIPIENTS " in
        *" $recipient "*) return 1 ;;
        *) return 0 ;;
      esac
    }
    bd()   { echo "$*" >> "$BD_LOG"; return 0; }
    log()  { echo "LOG: $*" >&2; }
    warn() { echo "WARN: $*" >&2; }
    '"$block"'
    echo "PARK_NOTIFIED=$PARK_NOTIFIED"
  ' _ "$notify_author" "$author" "$bead_id" "$marker_id" "$branch" "$fail_recipients" "$mail_log" "$bd_log"
  return $?
}

# ── Test 1: THE bug scenario, reproduced verbatim (ga-gq8x5/wa-166gf) ───────
echo "── (1) THE bug: bare crew segment 'oracle' unresolvable, qualified 'oracle-wa' resolves → delivered ──"
MAIL1="$(mktemp)"; BD1="$(mktemp)"
OUT1="$(run_park_notify "$GUARD" "oracle" "oracle-wa" "wa-166gf" "ga-gq8x5" "crew/oracle/wa-166gf" "oracle" "$MAIL1" "$BD1" 2>&1)"
RC1=$?
echo "$OUT1" | sed 's/^/    [test1] /'
[ "$RC1" -eq 0 ] && ok "rc=0" || bad "unexpected rc=$RC1"
case "$OUT1" in
  *"PARK_NOTIFIED=oracle-wa"*) ok "delivered to qualified candidate 'oracle-wa' (the real live session alias)";;
  *)                           bad "expected PARK_NOTIFIED=oracle-wa, got: $OUT1";;
esac
if grep -q 'mail send oracle ' "$MAIL1" && grep -q 'mail send oracle-wa ' "$MAIL1"; then
  ok "tried bare 'oracle' first, then qualified 'oracle-wa' (cascade order preserved)"
else
  bad "expected attempts at both 'oracle' and 'oracle-wa', got: $(cat "$MAIL1")"
fi
grep -q 'mail send mayor' "$MAIL1" \
  && bad "escalated to mayor even though a candidate succeeded — should not happen: $(cat "$MAIL1")" \
  || ok "no mayor escalation (a candidate succeeded, nothing to escalate)"
[ -s "$BD1" ] \
  && bad "unexpected bd call on the successful-delivery path: $(cat "$BD1")" \
  || ok "no bd comment on the successful-delivery path (nothing to mark)"
rm -f "$MAIL1" "$BD1"

# ── Test 2: CONTROLE — pool/template alias (bare) already resolves, unchanged ─
echo "── (2) CONTROLE: pool/template alias 'wa-worker' resolves bare → delivered on first try, no extra attempts ──"
MAIL2="$(mktemp)"; BD2="$(mktemp)"
OUT2="$(run_park_notify "$GUARD" "wa-worker" "mayor" "wa-4821" "ga-wisp-abc" "crew/wa-worker/wa-4821" "" "$MAIL2" "$BD2" 2>&1)"
echo "$OUT2" | sed 's/^/    [test2] /'
case "$OUT2" in
  *"PARK_NOTIFIED=wa-worker"*) ok "delivered to bare 'wa-worker' (pool/template alias, already exact)";;
  *)                           bad "expected PARK_NOTIFIED=wa-worker, got: $OUT2";;
esac
# Count CALLS, not lines: the mail body is multi-paragraph (embedded blank
# lines), so `wc -l` overcounts a single call. Each call's dump starts with
# "--city" as the first token of its first line — count those instead.
CALLCOUNT2=$(grep -c '^--city' "$MAIL2" | tr -d ' ')
[ "$CALLCOUNT2" -eq 1 ] \
  && ok "exactly one mail attempt (stopped at first success, no wasted qualified/AUTHOR attempts)" \
  || bad "expected exactly 1 mail attempt, got $CALLCOUNT2: $(cat "$MAIL2")"
rm -f "$MAIL2" "$BD2"

# ── Test 3: total failure → escalates to mayor AND leaves a durable bd comment (AC2) ─
echo "── (3) total failure: every candidate unresolvable → mayor escalation + durable marker comment (ga-z3i2p AC2) ──"
MAIL3="$(mktemp)"; BD3="$(mktemp)"
OUT3="$(run_park_notify "$GUARD" "ghost" "ghost-wa" "wa-999" "ga-wisp-ghost" "crew/ghost/wa-999" "ghost ghost-wa" "$MAIL3" "$BD3" 2>&1)"
echo "$OUT3" | sed 's/^/    [test3] /'
if printf '%s\n' "$OUT3" | grep -qx 'PARK_NOTIFIED='; then
  ok "PARK_NOTIFIED stayed empty (every candidate genuinely failed)"
else
  bad "expected empty PARK_NOTIFIED, got: $OUT3"
fi
grep -q 'mail send mayor' "$MAIL3" \
  && ok "escalated to mayor (second destination — ga-z3i2p AC2)" \
  || bad "did NOT escalate to mayor on total failure — silent WARN regression: $(cat "$MAIL3")"
grep -q 'ga-wisp-ghost' "$MAIL3" \
  && ok "mayor mail identifies the affected marker id" \
  || bad "mayor mail does not mention the marker id — a human reading it can't act: $(cat "$MAIL3")"
[ -s "$BD3" ] && grep -q 'comment ga-wisp-ghost' "$BD3" \
  && ok "durable bd comment left on the marker (second signal, survives even if the mayor mail is missed)" \
  || bad "expected a bd comment on the marker for the total-failure path, got: $(cat "$BD3")"
rm -f "$MAIL3" "$BD3"

# ── Test 4: HQ/gascity bead prefix ('ga') → no invented rig-suffix guess ────
echo "── (4) HQ bead (ga-* prefix): no '-ga' suffix guessed (unverified convention) ──"
MAIL4="$(mktemp)"; BD4="$(mktemp)"
OUT4="$(run_park_notify "$GUARD" "somebody" "somebody" "ga-abc12" "ga-wisp-hq1" "crew/somebody/ga-abc12" "somebody" "$MAIL4" "$BD4" 2>&1)"
echo "$OUT4" | sed 's/^/    [test4] /'
grep -q 'mail send somebody-ga ' "$MAIL4" \
  && bad "guessed an unverified 'somebody-ga' suffix for an HQ bead — should not happen: $(cat "$MAIL4")" \
  || ok "no 'somebody-ga' guess attempted for an HQ/gascity bead (ga-* prefix correctly skipped)"
rm -f "$MAIL4" "$BD4"

# ── Test 5: already-qualified crew segment → no double-suffix ("-wa-wa") ────
echo "── (5) already-qualified NOTIFY_AUTHOR ('oracle-wa') → no double-suffixed 'oracle-wa-wa' guess ──"
MAIL5="$(mktemp)"; BD5="$(mktemp)"
OUT5="$(run_park_notify "$GUARD" "oracle-wa" "oracle-wa" "wa-166gf" "ga-gq8x6" "crew/oracle-wa/wa-166gf" "" "$MAIL5" "$BD5" 2>&1)"
echo "$OUT5" | sed 's/^/    [test5] /'
grep -q 'oracle-wa-wa' "$MAIL5" \
  && bad "double-suffixed 'oracle-wa-wa' was attempted — should not happen: $(cat "$MAIL5")" \
  || ok "no double-suffix guess when NOTIFY_AUTHOR is already qualified"
case "$OUT5" in
  *"PARK_NOTIFIED=oracle-wa"*) ok "delivered to 'oracle-wa' on the first (bare, already-correct) attempt";;
  *)                           bad "expected PARK_NOTIFIED=oracle-wa, got: $OUT5";;
esac
rm -f "$MAIL5" "$BD5"

# ── Test 6: drift guards — sentinel + key literals still present verbatim ──
echo "── (6) drift guards on the live source ──"
grep -qF '# SELFTEST-EXTRACT park-author-notify: BEGIN' "$GUARD" \
  && ok "park-author-notify sentinel BEGIN present" \
  || bad "park-author-notify sentinel BEGIN MISSING — extraction would silently return empty"
grep -qF '# SELFTEST-EXTRACT park-author-notify: END' "$GUARD" \
  && ok "park-author-notify sentinel END present" \
  || bad "park-author-notify sentinel END MISSING — extraction would silently return empty"
grep -qF 'gc --city "$GC_CITY" mail send mayor' "$GUARD" \
  && ok "mail-mayor escalation call present in live source" \
  || bad "mail-mayor escalation call MISSING — ga-z3i2p AC2 regression"

# ── Test 7: MUTATION-TEST — neutralize the qualified-suffix tier and confirm
#    Test 1's key delivery goes RED (falls through to mayor instead of
#    reaching oracle-wa directly). AUTHOR is deliberately EMPTY here so ONLY
#    the qualified-suffix tier can succeed — isolates this tier from the
#    $AUTHOR fallback tier, which would otherwise mask the mutation. ────────
echo "── (7) MUTATION-TEST: neutralizing the rig-suffix qualification must turn delivery red again ──"
MUT="$(mktemp)"
cp "$GUARD" "$MUT"
python3 - "$MUT" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
begin = "# SELFTEST-EXTRACT park-author-notify: BEGIN"
end = "# SELFTEST-EXTRACT park-author-notify: END"
i, j = text.index(begin), text.index(end)
block = text[i:j]
target = 'PARK_NOTIFY_CANDIDATES="$PARK_NOTIFY_CANDIDATES ${NOTIFY_AUTHOR}-${_park_bid_prefix}"'
mutated = block.replace(target, ': # ga-z3i2p selftest: qualification neutralized', 1)
if mutated == block:
    print("MUTATION_NOT_APPLIED", file=sys.stderr)
    sys.exit(1)
text = text[:i] + mutated + text[j:]
open(path, 'w').write(text)
PYEOF
if [ $? -ne 0 ]; then
  bad "mutation-test: could not construct a mutated scratch copy (script bug in the test itself)"
else
  MAIL_MUT="$(mktemp)"; BD_MUT="$(mktemp)"
  # AUTHOR="" here (unlike Test 1's "oracle-wa") so the $AUTHOR fallback tier
  # cannot mask the mutation — only the (now-neutralized) qualified-suffix
  # tier could have reached "oracle-wa".
  OUT_MUT="$(run_park_notify "$MUT" "oracle" "" "wa-166gf" "ga-gq8x5" "crew/oracle/wa-166gf" "oracle" "$MAIL_MUT" "$BD_MUT" 2>&1)"
  echo "$OUT_MUT" | sed 's/^/    [mutation] /'
  case "$OUT_MUT" in
    *"PARK_NOTIFIED=oracle-wa"*)
      bad "mutation-test: neutralized qualification but STILL delivered to oracle-wa — mutation had no effect: $OUT_MUT"
      ;;
    *)
      if grep -q 'mail send mayor' "$MAIL_MUT"; then
        ok "mutation-test: neutralizing the rig-suffix qualification turns Test 1 red (falls through to mayor escalation instead of reaching oracle-wa) — test is not vacuous"
      else
        bad "mutation-test: delivery failed after neutralization but did not escalate — unexpected shape: mail=$(cat "$MAIL_MUT") bd=$(cat "$BD_MUT")"
      fi
      ;;
  esac
  rm -f "$MAIL_MUT" "$BD_MUT"
fi
rm -f "$MUT"

echo ""
echo "== gate-park-notify-address-fallback: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
