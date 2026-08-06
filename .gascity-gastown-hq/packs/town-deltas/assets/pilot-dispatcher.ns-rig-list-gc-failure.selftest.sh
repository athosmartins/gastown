#!/usr/bin/env bash
# pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh — regression harness for
# ga-07rb3 (gc <cmd> --json error-vs-empty idiom variants beyond ga-07509's 16
# sites: bare captures + jq-piped fallbacks).
#
# ROOT BUG (this file's slice of it): _NS_BRANCH_REPOS and _OWNERSHIP_GUARD_REPOS
# are built as `{ dirname "$GC_CITY"; gc rig list --json | jq ...; } | awk ...`.
# dirname "$GC_CITY" always succeeds, so the resulting repo list is NEVER
# genuinely empty even when `gc rig list` itself fails — it silently degrades
# to "just the town root". Every existing "is the repo list empty" guard in
# _beadid_has_branch/_crew_progressed_since/the phantom-claim guard therefore
# could not tell "gc failed" from "confirmed zero non-HQ rigs", and a
# rig-side branch could be silently missed — for _beadid_has_branch
# specifically, that means NEVERSTARTED-recovery could reclaim a bead with
# real rig-side in-flight work (double-dispatch class, ga-1url/ga-u4yi kin).
#
# This proves: a gc rig list FAILURE is now handled EXPLICITLY and distinctly
# from "genuinely searched, found nothing" — each consumer takes ITS OWN
# already-documented safe default specifically because the fetch failed, not
# by accident of which repos happen to be present. Two DIFFERENT signaling
# mechanisms are exercised, because a plain internal variable a function sets
# cannot cross the subshell boundary every caller creates via `$(...)`:
#   - _NS_BRANCH_REPOS's construction runs at TOP LEVEL (not inside a
#     function some caller wraps in `$(...)`), so a plain global
#     (_NS_RIG_LIST_OK) works and is what _beadid_has_branch/
#     _crew_progressed_since consult.
#   - _ownership_guard_repos() IS a function every caller invokes via
#     `repos="$(_ownership_guard_repos)"` — a variable it sets internally
#     would be silently discarded when that subshell exits (caught live by
#     an earlier draft of this very test: it asserted a variable that never
#     actually propagated). Fixed by using the function's own RETURN CODE
#     instead — command substitution's exit status ($?) DOES survive into
#     the caller, so _ownership_guard_repos returns 1 iff the underlying gc
#     fetch failed, and the phantom-claim guard checks $? directly.
#
# Extracts the real function bodies from pilot-dispatcher.sh (the canonical
# copy) rather than re-typing them — same philosophy as
# gc-json-or-unknown.selftest.sh — so this test can't silently drift from the
# shipped code.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$HERE/pilot-dispatcher.sh"

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# extract_fn <name> <file> — prints a top-level `name() { ... }` function
# body (brace opens on the `name() {` line, closes on a bare `}` at column 0)
# or nothing if not found. Same helper as gc-json-or-unknown.selftest.sh.
extract_fn() {
  awk -v fn="$1" '
    $0 == fn"() {" { p=1 }
    p { print; if ($0 == "}") exit }
  ' "$2"
}

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== pilot-dispatcher.ns-rig-list-gc-failure.selftest (ga-07rb3) =="

# ── Load the real functions under test ───────────────────────────────────────
for fn in gc_json_or_unknown _beadid_has_branch _crew_progressed_since \
          _ownership_guard_repos; do
  src="$(extract_fn "$fn" "$DISPATCHER")"
  if [ -z "$src" ]; then
    echo "FATAL: $fn() not found in $DISPATCHER — extraction failed" >&2
    exit 2
  fi
  eval "$src"
  if ! type "$fn" >/dev/null 2>&1; then
    echo "FATAL: extraction ran but did not define a callable $fn" >&2
    exit 2
  fi
done

warn() { :; }   # stub — pilot-dispatcher.sh's own logger, not under test here
log()  { :; }

GC_CITY="$(mktemp -d)"
TOWNROOT="$(dirname "$GC_CITY")"
trap 'rm -rf "$GC_CITY"' EXIT

# A real git repo at the town root, with one commit (a branch ref needs at
# least one commit to exist), and ZERO refs matching our test bead id — proves
# the "genuinely searched and found nothing" path stays correct.
git -C "$TOWNROOT" init -q 2>/dev/null || true
git -C "$TOWNROOT" config user.email t@t 2>/dev/null || true
git -C "$TOWNROOT" config user.name t 2>/dev/null || true
git -C "$TOWNROOT" commit -q --allow-empty -m init 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════
# 1. _beadid_has_branch: gc-failure (_NS_RIG_LIST_OK=0) → return 0 (KEEP),
#    even for a bead id with no matching ref anywhere in what WAS checked.
# ═════════════════════════════════════════════════════════════════════════
echo "-- _beadid_has_branch: gc rig list failure must fail toward KEEP (return 0) --"
unset PILOT_TEST_BRANCH_BEADS
_NS_RIG_LIST_OK=0
_NS_BRANCH_REPOS="$TOWNROOT"
if _beadid_has_branch "no-such-bead-anywhere"; then
  ok "gc-failure (_NS_RIG_LIST_OK=0) -> _beadid_has_branch returns 0 (branch may exist, KEEP)"
else
  bad "gc-failure did NOT trigger the safe default — returned 1 (would let NEVERSTARTED reclaim on unverifiable data)"
fi

echo "-- _beadid_has_branch control: gc SUCCEEDED, genuinely no branch -> still return 1 (unchanged) --"
_NS_RIG_LIST_OK=1
_NS_BRANCH_REPOS="$TOWNROOT"
if _beadid_has_branch "no-such-bead-anywhere"; then
  bad "control regressed: a genuinely-clean search now returns 0 (false KEEP) — the fix over-triggered"
else
  ok "gc succeeded, no branch found -> still returns 1 (genuine no-branch conclusion preserved)"
fi

echo "-- _beadid_has_branch control: a REAL matching branch is still found (fix didn't break detection) --"
git -C "$TOWNROOT" branch -q "crew/tester/hasbranch-bead" 2>/dev/null
_NS_RIG_LIST_OK=1
_NS_BRANCH_REPOS="$TOWNROOT"
if _beadid_has_branch "hasbranch-bead"; then
  ok "gc succeeded, a real branch exists -> correctly returns 0 (KEEP, real work detected)"
else
  bad "a genuinely existing branch was NOT detected — unrelated regression"
fi

# ═════════════════════════════════════════════════════════════════════════
# 2. _crew_progressed_since: gc-failure -> return 1 (not-progressed, the
#    SAME direction as this function's existing default — explicit now,
#    not incidental).
# ═════════════════════════════════════════════════════════════════════════
echo "-- _crew_progressed_since: gc rig list failure must fail toward 'not progressed' (return 1) --"
unset PILOT_TEST_CREW_PROGRESSED
_NS_RIG_LIST_OK=0
_NS_BRANCH_REPOS="$TOWNROOT"
if _crew_progressed_since "some-crew" "0"; then
  bad "gc-failure did NOT trigger the safe default — returned 0 (progressed), which would help RELEASE the bead on unverifiable data"
else
  ok "gc-failure (_NS_RIG_LIST_OK=0) -> _crew_progressed_since returns 1 (not-progressed, KEEP side)"
fi

# ═════════════════════════════════════════════════════════════════════════
# 3. _ownership_guard_repos: exit code signals the underlying gc fetch's
#    success/failure — the mechanism that actually crosses the `$(...)`
#    subshell boundary every real caller uses (a plain variable would not;
#    see the file header). Both stdout (unchanged, fail-open list) and $?
#    (new signal) are checked.
# ═════════════════════════════════════════════════════════════════════════
echo "-- _ownership_guard_repos: real failing gc -> function returns 1, list still fail-opens to town root --"
SANDBOX_BIN="$(mktemp -d)"
cat > "$SANDBOX_BIN/gc" <<'EOF'
#!/usr/bin/env bash
echo '{"schema_version":"1","ok":false,"error":{"code":"command_failed","message":"boom","exit_code":1}}'
exit 1
EOF
chmod +x "$SANDBOX_BIN/gc"
_OWNERSHIP_GUARD_REPOS=""
_OWNERSHIP_GUARD_REPOS_DONE=""
_OWNERSHIP_GUARD_REPOS_FAILED=""
_repos_out="$(PATH="$SANDBOX_BIN:$PATH" _ownership_guard_repos)"
_repos_rc=$?
if [ "$_repos_rc" -eq 1 ]; then
  ok "a real failing gc -> _ownership_guard_repos returns 1 (exit code survives the \$(...) the real callers use)"
else
  bad "a real failing gc -> _ownership_guard_repos returned $_repos_rc, expected 1"
fi
if [ "$_repos_out" = "$TOWNROOT" ]; then
  ok "repo list still fail-opens to just the town root (unchanged stdout behavior for the non-forcing callers)"
else
  bad "repo list on gc failure was '$_repos_out', expected just the town root '$TOWNROOT'"
fi

echo "-- _ownership_guard_repos control: real succeeding gc -> function returns 0 --"
cat > "$SANDBOX_BIN/gc" <<EOF
#!/usr/bin/env bash
echo '{"schema_version":"1","ok":true,"rigs":[{"name":"fakerig","path":"$TOWNROOT","hq":false}]}'
exit 0
EOF
chmod +x "$SANDBOX_BIN/gc"
_OWNERSHIP_GUARD_REPOS=""
_OWNERSHIP_GUARD_REPOS_DONE=""
_OWNERSHIP_GUARD_REPOS_FAILED=""
_repos_out2="$(PATH="$SANDBOX_BIN:$PATH" _ownership_guard_repos)"
_repos_rc2=$?
if [ "$_repos_rc2" -eq 0 ]; then
  ok "a real succeeding gc -> _ownership_guard_repos returns 0"
else
  bad "a real succeeding gc -> _ownership_guard_repos returned $_repos_rc2, expected 0"
fi
rm -rf "$SANDBOX_BIN"

# ═════════════════════════════════════════════════════════════════════════
# 3b. _ownership_guard_repos: the ACTUAL bug fix-attempt-2 targets — a
#     memoized CACHE-HIT call (2nd+ bead processed in the SAME sweep) must
#     still report the failure that produced the cached data, not silently
#     report success just because the fetch itself didn't run again this
#     time. Fix-attempt-1's test (section 3 above) reset
#     _OWNERSHIP_GUARD_REPOS_DONE before EVERY call, so every assertion
#     there took the cache-MISS path — exactly where the bug does not live.
#     Gate reviewer's blocking issue 2 on fix-attempt-1: this scenario was
#     never exercised. This section closes that gap.
#
#     IMPORTANT — why these calls do NOT use `$(_ownership_guard_repos)`
#     the way every real caller in pilot-dispatcher.sh does: command
#     substitution forks a subshell, and a subshell's variable assignments
#     (including _OWNERSHIP_GUARD_REPOS_DONE/_FAILED) never propagate back
#     to the parent — verified empirically, this is standard POSIX subshell
#     semantics, not a test artifact. An earlier draft of this test used
#     `$(...)` for BOTH the priming and checking call and got a FALSE PASS
#     on the failure scenario (both calls independently re-fetched and
#     independently failed — coincidentally the same observable result as a
#     real cache-hit) and a real, honest FAIL on the success scenario
#     (proving no persistence crosses two separate $(...) calls at all).
#     That is a SEPARATE, deeper, already-filed bug (ga-130et): because
#     every one of the 6 real call sites uses `$(...)`, this memoization
#     never actually triggers in production either — gc rig list --json
#     refetches on every single call, not once per sweep as documented.
#     This section tests the FIX's own persistence logic in isolation, via
#     plain output redirection (`f > file`), which — unlike `$(...)` — does
#     NOT fork a subshell for a shell function and so lets the assignments
#     survive, the same way they would if ga-130et is ever fixed and a
#     caller starts priming this cache with a direct call. This is honest
#     about testing the fix's logic, not a production end-to-end guarantee;
#     see ga-130et for the production-reachability caveat.
# ═════════════════════════════════════════════════════════════════════════
echo "-- _ownership_guard_repos: cache-HIT after a failure must still return 1 (the real bug) --"
SANDBOX_BIN2="$(mktemp -d)"
cat > "$SANDBOX_BIN2/gc" <<'EOF'
#!/usr/bin/env bash
echo '{"schema_version":"1","ok":false,"error":{"code":"command_failed","message":"boom","exit_code":1}}'
exit 1
EOF
chmod +x "$SANDBOX_BIN2/gc"
_OWNERSHIP_GUARD_REPOS=""
_OWNERSHIP_GUARD_REPOS_DONE=""
_OWNERSHIP_GUARD_REPOS_FAILED=""
_memo_tmp="$(mktemp)"
PATH="$SANDBOX_BIN2:$PATH" _ownership_guard_repos > "$_memo_tmp"; _first_rc=$?
_first_out="$(cat "$_memo_tmp")"
if [ "$_first_rc" -eq 1 ]; then
  ok "first call (cache-miss) with failing gc -> returns 1, as before"
else
  bad "first call with failing gc returned $_first_rc, expected 1 — setup broken, cannot test cache-hit path"
fi
# Simulate a SECOND bead in the SAME sweep: call again with NO reset of the
# memo state, still via plain redirection (see header note above — this is
# what lets the memoization actually be observed at all). Remove gc from
# PATH entirely first — under correct caching this second call must never
# invoke it (cache-hit skips the fetch entirely), so a missing binary
# cannot change the outcome if the fix is correct, but turns "the fetch ran
# again and coincidentally also failed" into a loud, unambiguous failure
# instead of a test that could pass for the wrong reason.
rm -f "$SANDBOX_BIN2/gc"
PATH="$SANDBOX_BIN2:$PATH" _ownership_guard_repos > "$_memo_tmp"; _second_rc=$?
_second_out="$(cat "$_memo_tmp")"
if [ "$_second_rc" -eq 1 ]; then
  ok "second call, SAME sweep, no reset (cache-hit) -> still returns 1 (fix-attempt-2: closes the gate's blocking issue 1)"
else
  bad "REGRESSION (the exact bug fix-attempt-2 targets): cache-hit call after a failure returned $_second_rc, expected 1 — a second bead in the same sweep would silently see 'success' and could be released for re-dispatch on unverified data"
fi
if [ "$_second_out" = "$_first_out" ]; then
  ok "cache-hit stdout matches the cached (fail-open) list from the first call, unchanged"
else
  bad "cache-hit stdout '$_second_out' differs from first call's '$_first_out' — memoization itself broke"
fi
rm -rf "$SANDBOX_BIN2"

echo "-- _ownership_guard_repos control: cache-HIT after a SUCCESS must still return 0 --"
SANDBOX_BIN3="$(mktemp -d)"
cat > "$SANDBOX_BIN3/gc" <<EOF
#!/usr/bin/env bash
echo '{"schema_version":"1","ok":true,"rigs":[{"name":"fakerig","path":"$TOWNROOT","hq":false}]}'
exit 0
EOF
chmod +x "$SANDBOX_BIN3/gc"
_OWNERSHIP_GUARD_REPOS=""
_OWNERSHIP_GUARD_REPOS_DONE=""
_OWNERSHIP_GUARD_REPOS_FAILED=""
PATH="$SANDBOX_BIN3:$PATH" _ownership_guard_repos > "$_memo_tmp"; _c1_rc=$?
rm -f "$SANDBOX_BIN3/gc"
PATH="$SANDBOX_BIN3:$PATH" _ownership_guard_repos > "$_memo_tmp"; _c2_rc=$?
if [ "$_c1_rc" -eq 0 ] && [ "$_c2_rc" -eq 0 ]; then
  ok "success caches clean -> both first call and cache-hit return 0 (happy path unaffected by the fix)"
else
  bad "success-path memoization broke: first_rc=$_c1_rc second_rc=$_c2_rc, expected 0/0"
fi
rm -rf "$SANDBOX_BIN3"
rm -f "$_memo_tmp"

# ═════════════════════════════════════════════════════════════════════════
# 4. Drift guard: the phantom-claim guard inside _beadid_live_crew_owner
#    must actually CHECK _ownership_guard_repos's exit code — a regression
#    that silently drops the check would leave every test above passing
#    (they test the pieces in isolation) while the real caller stays unsafe.
# ═════════════════════════════════════════════════════════════════════════
echo "-- drift guard: phantom-claim guard checks _ownership_guard_repos's exit code --"
phantom_block="$(awk '
  /^_beadid_live_crew_owner\(\) \{/ { p=1 }
  p { print; if ($0 == "}") exit }
' "$DISPATCHER")"
if printf '%s' "$phantom_block" | grep -qE '_og_repos="\$\(_ownership_guard_repos[^)]*\)"; *_og_rig_list_ok=\$\?'; then
  ok "_beadid_live_crew_owner captures _ownership_guard_repos's output AND exit code together"
else
  bad "REGRESSION: _beadid_live_crew_owner no longer captures _ownership_guard_repos's exit code the way this fix requires"
fi
if printf '%s' "$phantom_block" | grep -qE '&& \[ "\$_og_rig_list_ok" -eq 0 \]'; then
  ok "the exit-code check is wired as a required (&&) condition of the release path"
else
  bad "REGRESSION: \$_og_rig_list_ok is not wired as a required && condition — a gc failure could silently look like 'confirmed no branch' again"
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && exit 0 || exit 1
