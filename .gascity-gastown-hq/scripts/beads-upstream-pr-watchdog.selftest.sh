#!/usr/bin/env bash
# beads-upstream-pr-watchdog.selftest.sh — hermetic proof for ga-574zr/ga-se0ly:
# our own upstream PRs against gastownhall/beads must be watched, the alert
# must fire exactly on a state TRANSITION, and — the ga-se0ly rewrite — the
# tracker-bead map must be discovered LIVE each sweep (via `gc rig list` +
# `bd list --label-pattern 'waiting-on:pr-*'`) rather than hand-maintained,
# in BOTH directions: a merged/closed PR must alert EVERY tracker bead across
# every city, and an open PR with NO tracker bead anywhere must alert the
# Mayor to create one.
#
# No live gh/bd/gc/launchd: `gh`, `bd`, and `gc` are stubbed on PATH to record
# their calls instead of doing anything. All BUPW_* path overrides (state
# file, log file) are set BEFORE sourcing the watchdog in lib mode
# (BEADS_UPSTREAM_PR_WATCHDOG_LIB=1) — the watchdog binds STATE=$BUPW_STATE
# etc. as a top-level assignment AT SOURCE TIME, not inside a function, so
# setting the override after sourcing would silently write to the REAL
# production state path instead of this test's tmpdir.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SELF_DIR/beads-upstream-pr-watchdog.sh"
PLIST="$SELF_DIR/../packs/town-deltas/assets/beads-upstream-pr-watchdog.plist"
# The plist must reference where the script lives once deployed to the real
# HQ checkout — NOT wherever this selftest happens to be running from (a
# worktree path here would never match, before or after merge).
CANONICAL_SCRIPT="/Users/athos/gt/.gascity-gastown-hq/scripts/beads-upstream-pr-watchdog.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# sanitize_path <path> -> same scheme the bd stub uses to name per-city
# fixture files (must match verbatim).
sanitize_path() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

write_bd_fixture() {
  local city="$1" json="$2"
  printf '%s' "$json" > "$BD_FIXTURE_DIR/$(sanitize_path "$city").json"
}
clear_bd_fixture() { rm -f "$BD_FIXTURE_DIR/$(sanitize_path "$1").json"; }

# ── Hermetic stubs + all path overrides, set up BEFORE sourcing ────────────
export GH_CALLS_LOG="$TMP/gh-calls.log"
export BD_CALLS_LOG="$TMP/bd-calls.log"
export GC_CALLS_LOG="$TMP/gc-calls.log"
: > "$GH_CALLS_LOG"; : > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"

CITY_HQ="/fake/hq"
CITY_WA="/fake/wa"
CITY_FALLBACK="/fake/fallback-only"

export BD_FIXTURE_DIR="$TMP/bd-fixtures"
mkdir -p "$BD_FIXTURE_DIR"

export GC_RIG_LIST_FIXTURE="$TMP/rig-list.json"
cat > "$GC_RIG_LIST_FIXTURE" <<JSON
{"rigs": [{"name": "hq", "path": "$CITY_HQ"}, {"name": "wa", "path": "$CITY_WA"}]}
JSON

# GH_FIXTURE_STATE controls what the stubbed `gh pr list` returns for PR
# #5439 this sweep — swapped between invocations below to simulate it going
# OPEN -> MERGED. #5470 stays OPEN until Part 2.5 flips it to CLOSED. #9999
# has NO tracker bead anywhere (orphan case). #6001 has exactly one tracker
# bead, and it is `deferred` status (ga-r8haw precedent) — proves a
# non-"open" tracker still counts and is not misreported as an orphan.
export GH_FIXTURE_STATE="$TMP/gh-fixture-state"
echo "OPEN" > "$GH_FIXTURE_STATE"

cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GH_CALLS_LOG"
state="$(cat "$GH_FIXTURE_STATE" 2>/dev/null || echo OPEN)"
merged_at="null"
[ "$state" = "MERGED" ] && merged_at='"2026-08-09T20:00:00Z"'
cat <<JSON
[
  {"number": 5439, "state": "$state", "mergedAt": $merged_at, "url": "https://github.com/gastownhall/beads/pull/5439", "title": "fix(bd): canonicalize actor==assignee comparisons"},
  {"number": 5479, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5479", "title": "fix(bd): canonicalize remaining actor==assignee comparisons"},
  {"number": 5470, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5470", "title": "fix: widen DefaultLeaseTTL"},
  {"number": 9999, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/9999", "title": "feat: something nobody made a bead for"},
  {"number": 6001, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/6001", "title": "fix: tracked by a deferred bead"}
]
JSON
STUB
chmod +x "$TMP/gh"

# bd stub: `bd -C <city> list --all --label-pattern 'waiting-on:pr-*' --json
# --limit 0` returns that city's fixture (empty array if none registered);
# `bd -C <city> comment <id> --stdin` records the call + stdin body and can
# be made to fail via BD_FAIL_FLAG. Stdin is read ONLY for `comment` — a
# `list` call passes no stdin, and unconditionally cat-ing stdin for every
# subcommand (as the pre-ga-se0ly stub did, safe back then because `list`
# was never stubbed) would hang list calls in a non-interactive shell.
cat > "$TMP/bd" <<'STUB'
#!/usr/bin/env bash
argline=""
for a in "$@"; do argline="$argline [$a]"; done

is_comment=0; is_list=0; city=""; prev=""
for a in "$@"; do
  [ "$prev" = "-C" ] && city="$a"
  case "$a" in
    comment) is_comment=1 ;;
    list) is_list=1 ;;
  esac
  prev="$a"
done

if [ "$is_comment" = "1" ]; then
  body="$(cat)"
  printf 'CALL:%s STDIN=[%s]\n' "$argline" "$body" >> "$BD_CALLS_LOG"
  [ -n "${BD_FAIL_FLAG:-}" ] && [ -f "$BD_FAIL_FLAG" ] && exit 1
  exit 0
fi

if [ "$is_list" = "1" ]; then
  printf 'CALL:%s\n' "$argline" >> "$BD_CALLS_LOG"
  safe="$(printf '%s' "$city" | tr -c 'A-Za-z0-9' '_')"
  fixture="$BD_FIXTURE_DIR/${safe}.json"
  if [ -f "$fixture" ]; then cat "$fixture"; else echo '[]'; fi
  exit 0
fi

printf 'CALL:%s\n' "$argline" >> "$BD_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/bd"

# gc stub: `gc rig list --json` returns $GC_RIG_LIST_FIXTURE (or an
# empty-rigs object if that path is missing, to exercise the fallback);
# `gc mail send mayor ...` records the call and can be made to fail via
# GC_FAIL_FLAG.
cat > "$TMP/gc" <<'STUB'
#!/usr/bin/env bash
argline=""
for a in "$@"; do argline="$argline [$a]"; done
printf 'CALL:%s\n' "$argline" >> "$GC_CALLS_LOG"

is_rig_list=0; is_mail=0
for a in "$@"; do
  case "$a" in
    rig) is_rig_list=$((is_rig_list + 1)) ;;
    list) is_rig_list=$((is_rig_list + 1)) ;;
    mail) is_mail=$((is_mail + 1)) ;;
    send) is_mail=$((is_mail + 1)) ;;
  esac
done

if [ "$is_rig_list" -ge 2 ]; then
  if [ -f "${GC_RIG_LIST_FIXTURE:-/nonexistent}" ]; then cat "$GC_RIG_LIST_FIXTURE"; else echo '{"rigs": []}'; fi
  exit 0
fi

if [ "$is_mail" -ge 2 ]; then
  [ -n "${GC_FAIL_FLAG:-}" ] && [ -f "$GC_FAIL_FLAG" ] && exit 1
  exit 0
fi

exit 0
STUB
chmod +x "$TMP/gc"

export PATH="$TMP:$PATH"
export BUPW_STATE="$TMP/state.json"
export BUPW_LOG="$TMP/watchdog.log"
export BUPW_LOCK_ENABLED=0
export BD_BIN="bd"
export GC_BIN="gc"
export BUPW_FALLBACK_CITIES="$CITY_FALLBACK"

# ── Fixture data: who tracks what, before sourcing/running anything ────────
# #5439: TWO tracker beads in TWO different cities — proves a merge alert
# reaches every one of them, not just the first (the exact gap ga-se0ly
# reported: ga-5ksp5 never heard about PR #5439 merging because the old
# hand-maintained map only listed wa-msxg5 for it).
write_bd_fixture "$CITY_HQ" '[{"id":"ga-5ksp5","status":"open","labels":["lane:small","waiting-on:pr-5439"]}]'
write_bd_fixture "$CITY_WA" '[{"id":"wa-msxg5","status":"open","labels":["waiting-on:pr-5439"]}]'
# #6001: exactly one tracker, and it is `deferred` — must still count.
# #5470 gets no tracker bead here; Part 2.5 adds one via a fixture update.
append_hq_fixture() {
  local extra="$1"
  local cur; cur="$(cat "$BD_FIXTURE_DIR/$(sanitize_path "$CITY_HQ").json")"
  write_bd_fixture "$CITY_HQ" "$(printf '%s' "$cur" | jq -c --argjson x "$extra" '. + [$x]')"
}
append_hq_fixture '{"id":"ga-6001-tracker","status":"deferred","labels":["waiting-on:pr-6001"]}'
# 9999 deliberately has NO fixture entry anywhere -> orphan.

export BEADS_UPSTREAM_PR_WATCHDOG_LIB=1
# shellcheck disable=SC1090
source "$WATCHDOG"

# ── Part 1: classify_pr_transition — pure logic, no I/O ────────────────────
echo "== classify_pr_transition =="

eq "unseen, still open"             "$(classify_pr_transition UNKNOWN OPEN)"   "first-seen"
eq "unseen, already merged"         "$(classify_pr_transition UNKNOWN MERGED)" "merged"
eq "unseen, already closed"         "$(classify_pr_transition UNKNOWN CLOSED)" "closed-no-merge"
eq "open, unchanged"                "$(classify_pr_transition OPEN OPEN)"      "no-change"
eq "open -> merged"                 "$(classify_pr_transition OPEN MERGED)"    "merged"
eq "open -> closed"                 "$(classify_pr_transition OPEN CLOSED)"    "closed-no-merge"
eq "closed -> reopened"             "$(classify_pr_transition CLOSED OPEN)"    "reopened"
eq "merged, unchanged (no re-fire)" "$(classify_pr_transition MERGED MERGED)"  "no-change"

# ── Part 1.5: discover_tracker_beads — dynamic scan replaces PR_BEAD_MAP ───
echo ""
echo "== discover_tracker_beads (dynamic, no hardcoded map) =="

rows="$(discover_tracker_beads)"
eq "discovers exactly 3 (PR,bead) rows across both cities" "$(printf '%s\n' "$rows" | grep -c .)" "3"
if printf '%s' "$rows" | awk -F'\t' '$1=="5439" && $2=="ga-5ksp5"' | grep -q .; then
  ok "5439 -> ga-5ksp5 discovered in HQ city"
else
  bad "5439 -> ga-5ksp5 NOT discovered: $rows"
fi
if printf '%s' "$rows" | awk -F'\t' '$1=="5439" && $2=="wa-msxg5"' | grep -q .; then
  ok "5439 -> wa-msxg5 discovered in WA city (second tracker, same PR)"
else
  bad "5439 -> wa-msxg5 NOT discovered: $rows"
fi
if printf '%s' "$rows" | awk -F'\t' '$1=="6001" && $2=="ga-6001-tracker"' | grep -q .; then
  ok "6001 -> ga-6001-tracker discovered despite deferred status"
else
  bad "6001 tracker (deferred status) NOT discovered: $rows"
fi

# ── Part 2: run_sweep, multi-bead merge alert (dynamic discovery) ─────────
echo ""
echo "== run_sweep: multi-bead merge alert =="

# Sweep 1: PR #5439 OPEN, no prior state -> baseline only, NO alert.
run_sweep
eq "sweep1: no bd comment calls (baseline, not a transition)" "$(grep -c 'comment' "$BD_CALLS_LOG" || true)" "0"
eq "sweep1: no gc mail calls for 5439 yet (baseline)" "$(grep -c 'pull/5439' "$GC_CALLS_LOG" || true)" "0"
eq "sweep1: state file records OPEN for 5439" "$(jq -r '.prs["5439"].state' "$BUPW_STATE" 2>&1)" "OPEN"
grep -q 'has no tracking bead: gastownhall/beads #9999' "$GC_CALLS_LOG" \
  && ok "sweep1 also fires the orphan alert for #9999 (no bead anywhere references it)" \
  || bad "no orphan alert for #9999 on sweep1: $(cat "$GC_CALLS_LOG")"
eq "orphans_alerted remembers 9999 after sweep1" "$(jq -r '.orphans_alerted["9999"] != null' "$BUPW_STATE" 2>&1)" "true"
eq "6001's deferred-status tracker means it is NEVER flagged orphan" "$(grep -c 'no tracking bead: gastownhall/beads #6001' "$GC_CALLS_LOG" || true)" "0"

# Sweep 2: PR #5439 flips to MERGED -> must alert BOTH tracker beads + Mayor once.
echo "MERGED" > "$GH_FIXTURE_STATE"
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "sweep2: exactly two bd comment calls on merge (one per tracker bead)" "$(grep -c 'comment' "$BD_CALLS_LOG" || true)" "2"
eq "sweep2: exactly one gc mail call on merge" "$(grep -c 'mail.*send.*mayor' "$GC_CALLS_LOG" || true)" "1"
grep -q '\[-C\] \[/fake/hq\] \[comment\] \[ga-5ksp5\]' "$BD_CALLS_LOG" \
  && ok "sweep2: bd comment reached ga-5ksp5 in HQ city (previously missed by the static map)" \
  || bad "sweep2: no comment call to ga-5ksp5/HQ: $(cat "$BD_CALLS_LOG")"
grep -q '\[-C\] \[/fake/wa\] \[comment\] \[wa-msxg5\]' "$BD_CALLS_LOG" \
  && ok "sweep2: bd comment also reached wa-msxg5 in WA city" \
  || bad "sweep2: no comment call to wa-msxg5/WA: $(cat "$BD_CALLS_LOG")"
eq "sweep2: state file now records MERGED for 5439" "$(jq -r '.prs["5439"].state' "$BUPW_STATE" 2>&1)" "MERGED"

# Sweep 3: still MERGED -> must NOT re-alert (transition-only alerting).
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "sweep3: no repeat bd comment on unchanged MERGED state" "$(grep -c 'comment' "$BD_CALLS_LOG" || true)" "0"
eq "sweep3: no repeat gc mail for 5439 on unchanged MERGED state" "$(grep -c 'pull/5439' "$GC_CALLS_LOG" || true)" "0"

# ── Part 2.5: a partially-failed alert must NOT advance state ──────────────
# Proves: if bd succeeds but gc mail fails (a transient Dolt/network blip at
# the exact moment a transition is detected), the state must stay at the OLD
# value so the SAME transition is retried next sweep — advancing state on a
# failed notification would silence it forever under transition-only
# alerting.
echo ""
echo "== partial alert failure must not silently advance state =="

# Give #5470 a tracker bead now (it had none above, so it was never in the
# tracked set). First let it establish a normal OPEN baseline (via the
# gh stub still active from Part 2) — otherwise the transition below would
# be UNKNOWN->CLOSED (first-seen, always alerts) rather than the intended
# OPEN->CLOSED, and the "state not advanced" assertion would have nothing
# meaningful to stay at.
write_bd_fixture "$CITY_HQ" "$(cat "$BD_FIXTURE_DIR/$(sanitize_path "$CITY_HQ").json" | jq -c '. + [{"id":"ga-7uoua","status":"open","labels":["waiting-on:pr-5470"]}]')"
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "baseline: 5470 recorded as OPEN once its tracker bead exists" "$(jq -r '.prs["5470"].state' "$BUPW_STATE" 2>&1)" "OPEN"
eq "baseline sweep for 5470 caused no bd comments (no-change/no-op for everything else)" "$(grep -c 'comment' "$BD_CALLS_LOG" || true)" "0"

export GC_FAIL_FLAG="$TMP/gc-should-fail"
cat > "$TMP/gh" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GH_CALLS_LOG"
cat <<JSON
[
  {"number": 5439, "state": "MERGED", "mergedAt": "2026-08-09T20:00:00Z", "url": "https://github.com/gastownhall/beads/pull/5439", "title": "x"},
  {"number": 5479, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5479", "title": "x"},
  {"number": 5470, "state": "CLOSED", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/5470", "title": "x"},
  {"number": 9999, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/9999", "title": "x"},
  {"number": 6001, "state": "OPEN", "mergedAt": null, "url": "https://github.com/gastownhall/beads/pull/6001", "title": "x"}
]
JSON
STUB
chmod +x "$TMP/gh"

touch "$GC_FAIL_FLAG"
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "partial-fail sweep: state NOT advanced for 5470 (alert incomplete)" \
  "$(jq -r '.prs["5470"].state' "$BUPW_STATE" 2>&1)" "OPEN"

# Recover: gc works again. The SAME OPEN->CLOSED transition must retry, not
# be skipped — proving state was genuinely left unhandled above, not just
# coincidentally still OPEN.
rm -f "$GC_FAIL_FLAG"
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "retry sweep: exactly one bd comment once gc recovers" "$(grep -c 'comment' "$BD_CALLS_LOG" || true)" "1"
eq "retry sweep: exactly one gc mail once gc recovers"    "$(grep -c 'pull/5470' "$GC_CALLS_LOG" || true)" "1"
eq "retry sweep: state now advances to CLOSED for 5470" "$(jq -r '.prs["5470"].state' "$BUPW_STATE" 2>&1)" "CLOSED"

# ── Part 2.6: orphan detection (case b — the direction v1 never saw) ──────
# The alert itself already fired back at sweep1 (asserted there) and every
# sweep since has correctly deduped it (each Part 2/2.5 gc-mail assertion
# above scoped its grep to a specific PR#, so a lingering #9999 alert would
# not have masked any of them). This part proves the REST of the orphan
# lifecycle: continued dedup, clearing once resolved, and re-alerting if it
# regresses.
echo ""
echo "== orphan detection: dedup, resolve, and regression =="

# Same state again next sweep -> must NOT re-alert the same orphan.
: > "$BD_CALLS_LOG"; : > "$GC_CALLS_LOG"
run_sweep
eq "no repeat orphan alert for 9999 on unchanged state" "$(grep -c 'pull/9999' "$GC_CALLS_LOG" || true)" "0"

# A bead finally gets created for #9999 -> orphan record must clear, and a
# LATER disappearance must be re-alertable (not permanently silenced).
write_bd_fixture "$CITY_WA" "$(cat "$BD_FIXTURE_DIR/$(sanitize_path "$CITY_WA").json" | jq -c '. + [{"id":"wa-newbead","status":"open","labels":["waiting-on:pr-9999"]}]')"
: > "$GC_CALLS_LOG"
run_sweep
eq "orphans_alerted clears 9999 once a tracker bead exists" "$(jq -r 'has("orphans_alerted") and (.orphans_alerted | has("9999") | not)' "$BUPW_STATE" 2>&1)" "true"

clear_bd_fixture "$CITY_WA"
write_bd_fixture "$CITY_WA" '[]'
: > "$GC_CALLS_LOG"
run_sweep
grep -q 'has no tracking bead: gastownhall/beads #9999' "$GC_CALLS_LOG" \
  && ok "9999 re-alerts after its only tracker bead disappears again" \
  || bad "9999 did not re-alert after losing its tracker: $(cat "$GC_CALLS_LOG")"

# ── Part 2.7: gc rig list failure falls back to \$BUPW_FALLBACK_CITIES ─────
echo ""
echo "== gc rig list failure degrades to fallback cities, not silent zero-scan =="

rm -f "$GC_RIG_LIST_FIXTURE"   # stub now returns {"rigs": []}
write_bd_fixture "$CITY_FALLBACK" '[{"id":"fallback-tracker","status":"open","labels":["waiting-on:pr-9999"]}]'
: > "$GC_CALLS_LOG"
run_sweep
eq "fallback city's tracker suppresses the 9999 orphan alert" "$(grep -c 'pull/9999' "$GC_CALLS_LOG" || true)" "0"
grep -q 'falling back to' "$BUPW_LOG" \
  && ok "fallback path is logged (not silent)" \
  || bad "no fallback log line found in $BUPW_LOG"

# ── Part 3: single-instance lock (ga-y0g5x pattern) ─────────────────────────
echo ""
echo "== single-instance lock =="
export BUPW_LOCK_DIR="$TMP/lock.d"
export BUPW_LOCK_HB="$BUPW_LOCK_DIR/heartbeat"
# Real pid:random format, using THIS process's own pid — it is guaranteed
# alive for the duration of this test, so this exercises the actual `kill -0`
# liveness branch, not the separate fail-closed-on-unparseable-token branch.
export BUPW_LOCK_TOKEN="$$:aaa"

if _acquire_bupw_lock; then ok "first acquire succeeds"; else bad "first acquire should succeed"; fi

BUPW_LOCK_TOKEN="$$:bbb" _acquire_bupw_lock \
  && bad "second acquire while holder is LIVE should fail, but it succeeded" \
  || ok "second acquire correctly blocked while first holder is live (kill -0 \$\$ path, always alive during this test)"

_release_bupw_lock
[ -d "$BUPW_LOCK_DIR" ] && bad "lock dir should be gone after release" || ok "release removes the lock dir"

# Dead-holder reclaim: fabricate a lock held by a PID that cannot be alive.
mkdir "$BUPW_LOCK_DIR"
echo "999999:deadtoken" > "$BUPW_LOCK_HB"
if kill -0 999999 2>/dev/null; then
  echo "  (skip dead-holder-reclaim case: pid 999999 unexpectedly alive on this machine)"
else
  BUPW_LOCK_TOKEN="holder-c" _acquire_bupw_lock \
    && ok "reclaim succeeds when the recorded holder pid is dead" \
    || bad "reclaim should succeed over a dead holder"
fi
rm -rf "$BUPW_LOCK_DIR" "${BUPW_LOCK_DIR}.reaping" 2>/dev/null

# ── Part 4: plist points at the canonical deployed path ─────────────────────
echo ""
echo "== plist wiring =="
if [ -f "$PLIST" ]; then
  if grep -q "$CANONICAL_SCRIPT" "$PLIST"; then
    ok "plist ProgramArguments references the canonical deployed script path"
  else
    bad "plist does not reference $CANONICAL_SCRIPT"
  fi
  grep -q "<key>StartInterval</key>" "$PLIST" \
    && bad "plist uses StartInterval (resets on sleep/reboot, may never fire) instead of StartCalendarInterval" \
    || ok "plist does not use StartInterval for the daily cadence"
  grep -q "<key>StartCalendarInterval</key>" "$PLIST" \
    && ok "plist uses StartCalendarInterval for the daily cadence" \
    || bad "plist is missing StartCalendarInterval"
else
  bad "plist not found at $PLIST"
fi

echo ""
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
