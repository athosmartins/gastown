#!/usr/bin/env bash
# pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh — regression harness for
# ga-07rb3 (gc <cmd> --json error-vs-empty idiom variants beyond ga-07509's 16
# sites: bare captures + jq-piped fallbacks) AND ga-130et (_ownership_guard_repos
# memoization never actually reaching a second real caller in the same sweep,
# because every real call site wrapped the call in `$(...)`, forking a subshell
# that discarded the memo state — see section 5 below).
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
#   - _ownership_guard_repos() IS a function every caller invokes UNWRAPPED
#     (ga-130et) — `_ownership_guard_repos >/dev/null; rc=$?` then a direct
#     read of $_OWNERSHIP_GUARD_REPOS — never via
#     `repos="$(_ownership_guard_repos)"`. A command-substitution-wrapped
#     call forks a subshell; a variable the function sets internally would
#     be silently discarded when that subshell exits (caught live by an
#     earlier draft of this very test: it asserted a variable that never
#     actually propagated). Calling unwrapped avoids the subshell entirely,
#     so both the memo globals and the function's own RETURN CODE reach the
#     caller for real — the phantom-claim guard checks $? directly.
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
#     IMPORTANT — why these calls do NOT use `$(_ownership_guard_repos)`:
#     command substitution forks a subshell, and a subshell's variable
#     assignments (including _OWNERSHIP_GUARD_REPOS_DONE/_FAILED) never
#     propagate back to the parent — verified empirically, this is standard
#     POSIX subshell semantics, not a test artifact. An earlier draft of
#     this test used `$(...)` for BOTH the priming and checking call and got
#     a FALSE PASS on the failure scenario (both calls independently
#     re-fetched and independently failed — coincidentally the same
#     observable result as a real cache-hit) and a real, honest FAIL on the
#     success scenario (proving no persistence crosses two separate `$(...)`
#     calls at all). At the time this section was written, that was a
#     SEPARATE, deeper, still-open bug (ga-130et): every one of the 6 real
#     call sites used `$(...)` too, so this memoization never actually
#     triggered in production either — gc rig list --json refetched on
#     every single call, not once per sweep as documented. This section
#     tests the memoization logic in isolation, via plain output redirection
#     (`f > file`), which — unlike `$(...)` — does NOT fork a subshell for a
#     shell function and so lets the assignments survive. ga-130et is now
#     FIXED (every real call site was switched to this same unwrapped-call
#     shape) — section 5 below proves it end-to-end through an actual,
#     unmodified call site instead of this isolated harness.
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
if printf '%s' "$phantom_block" | grep -qE '_ownership_guard_repos >/dev/null 2>&1; *_og_rig_list_ok=\$\?'; then
  ok "_beadid_live_crew_owner calls _ownership_guard_repos unwrapped and captures its exit code (ga-130et shape)"
else
  bad "REGRESSION: _beadid_live_crew_owner no longer calls _ownership_guard_repos unwrapped + captures its exit code the way ga-130et requires"
fi
if printf '%s' "$phantom_block" | grep -qE '_og_repos="\$\{_OWNERSHIP_GUARD_REPOS:-\}"'; then
  ok "_beadid_live_crew_owner reads the memoized repos list directly from the global (ga-130et shape)"
else
  bad "REGRESSION: _beadid_live_crew_owner no longer reads \$_OWNERSHIP_GUARD_REPOS directly — may have reverted to a \$(...)-wrapped call"
fi
if printf '%s' "$phantom_block" | grep -qE '&& \[ "\$_og_rig_list_ok" -eq 0 \]'; then
  ok "the exit-code check is wired as a required (&&) condition of the release path"
else
  bad "REGRESSION: \$_og_rig_list_ok is not wired as a required && condition — a gc failure could silently look like 'confirmed no branch' again"
fi

# ═════════════════════════════════════════════════════════════════════════
# 5. ga-130et END-TO-END: an actual, unmodified real call site — not this
#    file's isolated harness — must reuse the memoized fetch across two
#    "beads" processed in the same simulated sweep. Section 3b proved the
#    function's OWN persistence logic works via plain redirection; this
#    proves that proof actually reaches production, by extracting
#    _target_has_real_branch() verbatim (same extract_fn helper as the
#    top-of-file loader) and counting real `gc` invocations across two
#    calls with NO reset of the memo globals in between — exactly how
#    pilot-dispatcher.sh's real sweep loop calls it once per candidate bead.
#    Before ga-130et's fix this counted 2 (every call independently
#    re-fetched); the fix makes it 1.
# ═════════════════════════════════════════════════════════════════════════
echo "-- ga-130et end-to-end: _target_has_real_branch (real call site) reuses the memoized fetch across 2 calls --"
_e2e_src="$(extract_fn _target_has_real_branch "$DISPATCHER")"
if [ -z "$_e2e_src" ]; then
  bad "FATAL: _target_has_real_branch() not found in $DISPATCHER — cannot run section 5"
else
  eval "$_e2e_src"
  SANDBOX_BIN5="$(mktemp -d)"
  GC_CALL_COUNT_FILE="$(mktemp)"
  echo 0 > "$GC_CALL_COUNT_FILE"
  cat > "$SANDBOX_BIN5/gc" <<EOF
#!/usr/bin/env bash
echo "\$(( \$(cat "$GC_CALL_COUNT_FILE") + 1 ))" > "$GC_CALL_COUNT_FILE"
echo '{"schema_version":"1","ok":true,"rigs":[]}'
exit 0
EOF
  chmod +x "$SANDBOX_BIN5/gc"
  _OWNERSHIP_GUARD_REPOS=""
  _OWNERSHIP_GUARD_REPOS_DONE=""
  _OWNERSHIP_GUARD_REPOS_FAILED=""
  PATH="$SANDBOX_BIN5:$PATH" _target_has_real_branch "e2e-bead-one" >/dev/null 2>&1
  PATH="$SANDBOX_BIN5:$PATH" _target_has_real_branch "e2e-bead-two" >/dev/null 2>&1
  _gc_calls="$(cat "$GC_CALL_COUNT_FILE" 2>/dev/null || echo "?")"
  if [ "$_gc_calls" = "1" ]; then
    ok "ga-130et FIXED end-to-end: 2 real calls to _target_has_real_branch (simulating 2 beads, 1 sweep) invoked gc rig list only ONCE"
  else
    bad "ga-130et REGRESSION: 2 real calls to _target_has_real_branch invoked gc $_gc_calls time(s), expected 1 — memoization is not reaching this real call site (a \$(...)-wrapped call may have crept back in)"
  fi
  rm -rf "$SANDBOX_BIN5"
  rm -f "$GC_CALL_COUNT_FILE"
  unset -f _target_has_real_branch 2>/dev/null || true
fi

# ═════════════════════════════════════════════════════════════════════════
# 6. ga-130et fix-attempt-2 END-TO-END: the gate review of fix-attempt-1
#    found that unwrapping each call site's OWN invocation (what section 5
#    proves) only closes the gap for a chain with ZERO subshells anywhere
#    above it. 5 of the 6 real call sites are reached through a caller that
#    wraps the containing function in `$(...)` (_beadid_live_crew_owner,
#    _beadid_matched_crew_branch_ref, _beadid_needs_remerge_branch) or pipes
#    it (_filter_built, 10 real call sites) — section 5's proof, using only
#    _target_has_real_branch, could not have caught that gap, and didn't.
#    This proves fix-attempt-2's actual mechanism (_ownership_guard_repos_
#    prime, called once at top level) closes BOTH previously-broken shapes,
#    using two real, unmodified functions: _beadid_matched_crew_branch_ref
#    (the $(...) shape) and _filter_built (the pipe shape) — not synthetic
#    stand-ins, so this can't silently drift from the shipped code either.
#    Negative control first: the SAME two real calls, with NO prime call,
#    must reproduce fix-attempt-1's exact gap (gc invoked more than once) —
#    proof this test would actually have failed against fix-attempt-1, not
#    just that it passes against fix-attempt-2.
# ═════════════════════════════════════════════════════════════════════════
echo "-- ga-130et fix-attempt-2 end-to-end: prime-once reaches the \$(...)-wrapped AND piped real call shapes gate flagged --"
_e2e2_ok=1
for _fn in _ownership_guard_repos_prime _filter_built _beadid_matched_crew_branch_ref; do
  _e2e2_src="$(extract_fn "$_fn" "$DISPATCHER")"
  if [ -z "$_e2e2_src" ]; then
    bad "FATAL: $_fn() not found in $DISPATCHER — cannot run section 6"
    _e2e2_ok=0
  else
    eval "$_e2e2_src"
  fi
done

if [ "$_e2e2_ok" -eq 1 ]; then
  SANDBOX_BIN6="$(mktemp -d)"
  GC_CALL_COUNT_FILE6="$(mktemp)"
  cat > "$SANDBOX_BIN6/gc" <<EOF
#!/usr/bin/env bash
echo "\$(( \$(cat "$GC_CALL_COUNT_FILE6") + 1 ))" > "$GC_CALL_COUNT_FILE6"
echo '{"schema_version":"1","ok":true,"rigs":[]}'
exit 0
EOF
  chmod +x "$SANDBOX_BIN6/gc"

  # -- Negative control: no prime call — matches fix-attempt-1's shape
  #    exactly (every call site unwrapped, but nothing primes the cache
  #    before either real chain runs) --
  _OWNERSHIP_GUARD_REPOS=""
  _OWNERSHIP_GUARD_REPOS_DONE=""
  _OWNERSHIP_GUARD_REPOS_FAILED=""
  echo 0 > "$GC_CALL_COUNT_FILE6"
  _e2e2_rt=$(PATH="$SANDBOX_BIN6:$PATH" _beadid_matched_crew_branch_ref "e2e2-bead-nocontrol" 2>/dev/null) || true
  printf '[]' | PATH="$SANDBOX_BIN6:$PATH" _filter_built >/dev/null 2>&1 || true
  _gc_calls_nocontrol="$(cat "$GC_CALL_COUNT_FILE6" 2>/dev/null || echo "?")"
  if [ "$_gc_calls_nocontrol" -gt 1 ] 2>/dev/null; then
    ok "negative control: WITHOUT the prime call, 1 \$(...)-wrapped call + 1 piped call invoke gc $_gc_calls_nocontrol times — reproduces fix-attempt-1's exact gap, confirming this test can actually detect it"
  else
    bad "negative control did not reproduce the gap (gc called $_gc_calls_nocontrol time(s), expected >1) — the positive result below would not be meaningful; investigate before trusting it"
  fi

  # -- Positive proof: same two real chains, but _ownership_guard_repos_prime
  #    runs ONCE first, unwrapped, at this (top) level — exactly how the real
  #    script calls it, right after the function definition --
  _OWNERSHIP_GUARD_REPOS=""
  _OWNERSHIP_GUARD_REPOS_DONE=""
  _OWNERSHIP_GUARD_REPOS_FAILED=""
  echo 0 > "$GC_CALL_COUNT_FILE6"
  PATH="$SANDBOX_BIN6:$PATH" _ownership_guard_repos_prime
  _e2e2_rt=$(PATH="$SANDBOX_BIN6:$PATH" _beadid_matched_crew_branch_ref "e2e2-bead-one" 2>/dev/null) || true
  _e2e2_rt2=$(PATH="$SANDBOX_BIN6:$PATH" _beadid_matched_crew_branch_ref "e2e2-bead-two" 2>/dev/null) || true
  printf '[]' | PATH="$SANDBOX_BIN6:$PATH" _filter_built >/dev/null 2>&1 || true
  printf '[]' | PATH="$SANDBOX_BIN6:$PATH" _filter_built >/dev/null 2>&1 || true
  _gc_calls="$(cat "$GC_CALL_COUNT_FILE6" 2>/dev/null || echo "?")"
  if [ "$_gc_calls" = "1" ]; then
    ok "ga-130et fix-attempt-2 FIXED end-to-end: prime once, then 2 \$(...)-wrapped calls (_beadid_matched_crew_branch_ref) + 2 piped calls (_filter_built) invoke gc rig list only ONCE total"
  else
    bad "ga-130et fix-attempt-2 REGRESSION: a primed sweep still invoked gc $_gc_calls time(s), expected 1 — the \$(...)-wrapped or piped real call shapes are still re-fetching"
  fi

  rm -rf "$SANDBOX_BIN6"
  rm -f "$GC_CALL_COUNT_FILE6"
fi
unset -f _ownership_guard_repos_prime _filter_built _beadid_matched_crew_branch_ref 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════════
# 7. ga-130et fix-attempt-3: gate review of fix-attempt-2 found that the
#    top-level `_ownership_guard_repos_prime` call (section 6) is invoked
#    BARE, under pilot-dispatcher.sh's own top-of-file `set -euo pipefail`.
#    _ownership_guard_repos legitimately returns 1 whenever
#    `gc rig list --json` fails (subprocess failure, empty output, bad JSON,
#    or an explicit ok:false envelope — gc_json_or_unknown's four documented
#    failure modes), and a bare, unguarded call whose last statement fails
#    aborts the ENTIRE script under set -e before the dispatch loop even
#    runs — turning a transient gc/Dolt hiccup at startup into total sweep
#    failure, a regression from the documented fail-open design (the sibling
#    rig_root_path cache explicitly retries-on-failure rather than crashing,
#    citing ga-07509).
#    Sections 5/6's mocked `gc` always exits 0, so neither exercises this
#    path. This test harness itself runs under `set -uo pipefail` (no -e,
#    see top of file) so it cannot observe an errexit abort by simply
#    calling the extracted function in-process — it needs a REAL child bash
#    process with `set -euo pipefail` actually enabled, matching the
#    dispatcher's own top-level semantics, to reproduce (or fail to
#    reproduce) the abort.
#    Negative control hand-sets fix-attempt-2's exact shipped shape (bare
#    call, same convention section 6 uses for its negative control) to prove
#    this harness can detect the crash at all. The positive proof instead
#    extracts the ACTUAL shipped top-level invocation line via grep — not
#    hand-typed — so a future regression back to a bare call is caught here
#    too, not just today's specific fix.
# ═════════════════════════════════════════════════════════════════════════
echo "-- ga-130et fix-attempt-3: a gc failure at prime time must not abort the whole dispatcher under set -e --"

_p3_setline="$(grep -n '^set -' "$DISPATCHER" | head -1 | cut -d: -f2-)"
_p3_gjou_src="$(extract_fn gc_json_or_unknown "$DISPATCHER")"
_p3_ogr_src="$(extract_fn _ownership_guard_repos "$DISPATCHER")"
_p3_prime_src="$(extract_fn _ownership_guard_repos_prime "$DISPATCHER")"
_p3_invoke_line="$(grep -n '^_ownership_guard_repos_prime' "$DISPATCHER" | grep -v '()' | head -1 | cut -d: -f2-)"

if [ -z "$_p3_setline" ] || [ -z "$_p3_gjou_src" ] || [ -z "$_p3_ogr_src" ] \
   || [ -z "$_p3_prime_src" ] || [ -z "$_p3_invoke_line" ]; then
  bad "FATAL: could not extract set-line/gc_json_or_unknown/_ownership_guard_repos/_ownership_guard_repos_prime/invoke-line from $DISPATCHER — cannot run section 7"
else
  SANDBOX_BIN7="$(mktemp -d)"
  cat > "$SANDBOX_BIN7/gc" <<'GCEOF'
#!/usr/bin/env bash
exit 1
GCEOF
  chmod +x "$SANDBOX_BIN7/gc"
  _P3_GC_CITY="$(mktemp -d)"

  # Common preamble shared by both child scripts: real set -e semantics,
  # real (extracted) function bodies, a warn() stub (pilot-dispatcher.sh's
  # own logger, not under test here — same stub the top of this file uses),
  # and a PRE marker proving the child got this far before either variant's
  # own invocation line runs.
  _p3_base="$(mktemp)"
  {
    printf '%s\n' "$_p3_setline"
    echo 'warn() { :; }'
    printf '%s\n' "$_p3_gjou_src"
    printf '%s\n' "$_p3_ogr_src"
    echo '_OWNERSHIP_GUARD_REPOS=""'
    echo '_OWNERSHIP_GUARD_REPOS_DONE=""'
    echo '_OWNERSHIP_GUARD_REPOS_FAILED=""'
    printf '%s\n' "$_p3_prime_src"
    printf 'GC_CITY=%q\n' "$_P3_GC_CITY"
    echo 'echo PRE_PRIME_MARKER'
  } > "$_p3_base"

  _p3_neg_script="$(mktemp)"
  cat "$_p3_base" > "$_p3_neg_script"
  {
    echo '_ownership_guard_repos_prime'
    echo 'echo POST_PRIME_MARKER'
  } >> "$_p3_neg_script"

  _p3_pos_script="$(mktemp)"
  cat "$_p3_base" > "$_p3_pos_script"
  {
    printf '%s\n' "$_p3_invoke_line"
    echo 'echo POST_PRIME_MARKER'
  } >> "$_p3_pos_script"
  rm -f "$_p3_base"

  # -- Negative control: fix-attempt-2's exact shipped shape (bare call) —
  #    must abort before the post marker prints. --
  _p3_neg_out="$(PATH="$SANDBOX_BIN7:$PATH" bash "$_p3_neg_script" 2>&1)"; _p3_neg_rc=$?
  if [ "$_p3_neg_rc" -ne 0 ] && ! printf '%s' "$_p3_neg_out" | grep -q POST_PRIME_MARKER; then
    ok "negative control: fix-attempt-2's bare invocation shape aborts the whole script on a gc failure (rc=$_p3_neg_rc, post-marker absent) — confirms this test can detect the bug"
  else
    bad "negative control did not reproduce the crash (rc=$_p3_neg_rc, output: $_p3_neg_out) — the positive result below would not be meaningful; investigate before trusting it"
  fi

  # -- Positive proof: the ACTUAL shipped top-level invocation line — must
  #    survive a gc failure and keep running. --
  _p3_pos_out="$(PATH="$SANDBOX_BIN7:$PATH" bash "$_p3_pos_script" 2>&1)"; _p3_pos_rc=$?
  if [ "$_p3_pos_rc" -eq 0 ] && printf '%s' "$_p3_pos_out" | grep -q POST_PRIME_MARKER; then
    ok "ga-130et fix-attempt-3 FIXED: the shipped top-level invocation ('$_p3_invoke_line') survives a gc rig list failure and the script keeps running"
  else
    bad "ga-130et fix-attempt-3 REGRESSION: the shipped top-level invocation ('$_p3_invoke_line') still aborts the whole script on a gc failure (rc=$_p3_pos_rc, output: $_p3_pos_out)"
  fi

  rm -f "$_p3_neg_script" "$_p3_pos_script"
  rm -rf "$SANDBOX_BIN7" "$_P3_GC_CITY"
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && exit 0 || exit 1
