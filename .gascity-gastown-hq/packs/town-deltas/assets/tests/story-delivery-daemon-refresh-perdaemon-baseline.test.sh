#!/usr/bin/env bash
# story-delivery-daemon-refresh-perdaemon-baseline.test.sh — regression test
# for ga-0fawwr and ga-7polxu (extracts the real Step 5b block from
# story-delivery.sh, no duplication — same technique as
# story-delivery-step5b.test.sh).
#
# THE BUG (ga-0fawwr; see daemon-refresh.sh's own big comment on
# DAEMON_BASELINE_OVERRIDES, at its point of use, for the full incident): the
# rig-wide baseline marker ($RIG.sha) only advances when the WHOLE rig comes
# back OK|SKIPPED in one cycle. A single persistently-guarded daemon freezes it
# for every OTHER daemon on the same rig too, so a large-closure daemon gets
# falsely re-flagged AFFECTED on nearly every cycle even when nothing in ITS OWN
# closure has changed since it was last individually clean (measured live:
# 115 of 194 cycles NEEDS_GUARDED_RESTART over 5 days, rig-wide marker
# advancing only twice).
#
# THE FIX (ga-0fawwr): story-delivery.sh ALSO persists a per-daemon baseline
# file ($RIG.perdaemon, one "<label> <sha>" pair per line), advancing each label
# independently of the overall verdict: any label examined this cycle
# (daemon-refresh.sh's ALL_LABELS field) and NOT left in GUARDED or FRESH_FAIL
# gets its own entry advanced to POST_DEPLOY_SHA, regardless of what any other
# label on the same rig did. The file is read back and fed to daemon-refresh.sh
# as DAEMON_BASELINE_OVERRIDES — see tests/daemon-refresh.test.sh's T51/T52 for
# the closure-narrowing half of this fix. That consumer only ever NARROWS: an
# entry strictly between the rig-wide PRE and POST can drop a label out of
# AFFECTED; it can never add one, and an entry older than PRE is ignored.
#
# ga-7polxu — THE SECOND BUG, in the same block. A label left in GUARDED or
# FRESH_FAIL was neither written nor carried forward: the carry-forward loop
# skipped every label the cycle examined, so the still-stuck label's previous
# entry was DROPPED, and a first-time stuck label never got one. Its baseline
# then fell back to the rig-wide marker, which the ga-49fwiw unattributed
# release advances to POST_DEPLOY_SHA in the very same sweep. Measured live on
# whatsapp_automation 2026-09-20 00:47-00:48: 41 guarded daemons, 0 of them in
# the per-daemon file, the marker advanced, the wide list went 41 -> 5 with no
# restart and no per-daemon check. The block comment (and this file's old T1)
# both asserted the opposite ("a still-stuck label keeps its own baseline
# frozen"); T1 even blessed the drop as correct.
#
# THE FIX (ga-7polxu): a label left in GUARDED or FRESH_FAIL is FROZEN, never
# dropped: it keeps its existing entry when that is a real commit reachable
# from POST_DEPLOY_SHA (its last known-clean point) and otherwise gets the
# effective PRE the helper was measured against. It is written as
# "<label> <sha> stuck". A stuck-flagged entry is not overwritten by a "clean"
# advance unless this cycle's wide window still covers its sha — after a
# marker advance the window starts past it, and "not flagged" then means
# "not looked at", not "clean" (unknown is not clean).
#
# T1: two labels examined, one guarded, one clean, no pre-existing file →
#     the clean label is advanced to POST_DEPLOY_SHA; the guarded one is
#     RECORDED, frozen at the effective PRE (C0), flagged stuck, NOT advanced.
#     (Inverted from the pre-ga-7polxu T1, which asserted the guarded label
#     was correctly LEFT OUT of the file.)
# T2: a pre-existing entry for a label NOT examined this cycle (e.g. hidden
#     from discovery by a plist parse error) is carried forward untouched
#     (T2b: including its stuck flag).
# T3: overall REFRESH_VERDICT is NEEDS_GUARDED_RESTART (non-OK) — the
#     per-daemon write still happens for the clean label (independent of the
#     rig-wide gate), while the rig-wide $RIG.sha marker is confirmed NOT
#     advanced (ga-gokm6 behavior, unchanged).
# T4: a guarded label with a real pre-existing entry BETWEEN PRE and POST
#     keeps that entry (its last known-clean point), not C0 and not C1.
# T5: a guarded label whose pre-existing entry is not a commit is re-frozen at
#     the effective PRE (T5b: an older-than-PRE real commit is preserved — it
#     is the truthful "unresolved since").
# T6: FRESH_FAIL is treated exactly like GUARDED (T6b: a stuck label the
#     helper did not list in ALL_LABELS is still frozen, exactly one line).
# T7: durability across a marker advance — a stuck-flagged entry older than
#     the marker survives a cycle in which the label is no longer flagged,
#     because the window no longer covers it; the clean neighbour still
#     advances (T7b: a flagged entry whose sha is not a real commit is replaced
#     rather than kept forever — it carries no information).
# T8: once the window DOES cover the flagged entry and the label is not
#     flagged, it is genuinely clean: advanced to POST, flag cleared.
# T9: format compatibility — the consumer (daemon-refresh.sh) reads an entry
#     with `awk '$1==l{print $2; exit}'`; the extra column must not leak in.
# T10: the block also holds under `set -e`, which is how story-delivery.sh
#     runs it in production (the harness above runs without it).

# No `pipefail` at file level (ga-7polxu): every assertion below is
# `echo "$X" | grep -q ...`, and under pipefail grep -q's early exit hands the
# writer a SIGPIPE — the pipeline then reports 141 and a PASSING assertion prints
# FAIL. Measured at load ~45: 29 false FAILs in 1500 such pipelines with pipefail
# on, 0 in 1500 with it off — which is what made this whole test family flake
# under load. The block under test still runs WITH pipefail (see run_block),
# because that is how story-delivery.sh runs it in production.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to story-delivery-step5b.test.sh.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

RIG_MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"
PERDAEMON_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.perdaemon"

# run_block <stub-verdict> <all-labels> <guarded> <freshfail> [<seed-perdaemon>] [<seed-marker>]
# Builds a git fixture (C0 -> C1, or C0 -> MID -> C1 when WANT_MID=1), a stub
# daemon-refresh.sh that emits the given fields, optionally seeds the perdaemon
# file (may hold several lines; @C0@ @MID@ @C1@ are replaced by the real shas)
# and the rig-wide marker, then runs the real Step 5b block with
# PRE_DEPLOY_SHA=C0 POST_DEPLOY_SHA=C1. ERREXIT=1 runs the block under `set -e`.
# Sets globals: RUN_RC, PERDAEMON_AFTER, RIGMARKER_AFTER, EXPECT_C0, EXPECT_MID,
# EXPECT_C1.
run_block() {
  local stub_verdict="$1" all_labels="$2" guarded="$3" freshfail="$4" seed="${5:-}" marker="${6:-}"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  local SHA_MID=""
  if [ "${WANT_MID:-0}" = "1" ]; then
    echo mid > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m CM
    SHA_MID="$(git -C "$REPO" rev-parse HEAD)"
  fi
  echo tip  > "$REPO/f.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

  seed="${seed//@C0@/$SHA_C0}"; seed="${seed//@MID@/$SHA_MID}"; seed="${seed//@C1@/$SHA_C1}"
  marker="${marker//@C0@/$SHA_C0}"; marker="${marker//@MID@/$SHA_MID}"; marker="${marker//@C1@/$SHA_C1}"
  if [ -n "$seed" ]; then
    mkdir -p "$GC_CITY/$(dirname "$PERDAEMON_REL")"
    printf '%s\n' "$seed" > "$GC_CITY/$PERDAEMON_REL"
    # PD_SEED_MODE: e.g. 200 = writable but NOT readable, the case where the read
    # fails and a naive rewrite would still succeed.
    [ -z "${PD_SEED_MODE:-}" ] || chmod "$PD_SEED_MODE" "$GC_CITY/$PERDAEMON_REL"
  fi
  if [ -n "$marker" ]; then
    mkdir -p "$GC_CITY/$(dirname "$RIG_MARKER_REL")"
    printf '%s\n' "$marker" > "$GC_CITY/$RIG_MARKER_REL"
  fi

  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
echo "VERDICT=$stub_verdict"
echo "ALL_LABELS=$all_labels"
echo "RESTARTED="
echo "GUARDED=$guarded"
echo "FRESH_FAIL=$freshfail"
echo "REASON=stub"
exit 0
EOF
  # STUB_OMIT_GUARDED=1: a helper output with no GUARDED= line at all ("the helper
  # did not say"), as opposed to a GUARDED= line that is genuinely empty.
  if [ "${STUB_OMIT_GUARDED:-0}" = "1" ]; then
    grep -v '^echo "GUARDED=' "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" > "$T/stub.new" \
      && cat "$T/stub.new" > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh"
  fi

  LOG_FILE="$T/log.log"
  bd()   { :; }
  gc()   { :; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  # BREAK_GIT=1: every git question the BLOCK asks comes back as an ERROR (exit
  # 128), not as a clean "no" — the "git could not say" state. Done with GIT_DIR
  # pointing at nothing, NOT with a non-repository directory: on this machine the
  # system temp dir is itself inside a stray git repository, so a "non-repo" temp
  # subdirectory silently resolves to that repo and git answers a plain "no".
  local PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_C1" DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  # declared (not left unset) because the block runs under `set -u` here —
  # same reasoning as story-delivery-daemon-refresh-baseline.test.sh.
  local MERGE_SHA=""
  local MERGE_PRE_MAIN=""
  get_runbook_field() { echo "central-sender"; }

  if [ "${ERREXIT:-0}" = "1" ]; then
    ( [ "${BREAK_GIT:-0}" != "1" ] || export GIT_DIR="$T/no-such-git-dir"
      set -o pipefail; set -e; for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  else
    ( [ "${BREAK_GIT:-0}" != "1" ] || export GIT_DIR="$T/no-such-git-dir"
      set -o pipefail; for _t in _once; do eval "$BLOCK"; done ) >/dev/null 2>&1
  fi
  RUN_RC=$?
  chmod u+rw "$GC_CITY/$PERDAEMON_REL" 2>/dev/null || true
  PERDAEMON_AFTER="$(cat "$GC_CITY/$PERDAEMON_REL" 2>/dev/null || true)"
  RIGMARKER_AFTER="$(cat "$GC_CITY/$RIG_MARKER_REL" 2>/dev/null || true)"
  EXPECT_C0="$SHA_C0"
  EXPECT_MID="$SHA_MID"
  EXPECT_C1="$SHA_C1"
  rm -rf "$T"
}

# ── T1: two labels, one guarded one clean, no pre-existing file ──────────────
run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" ""
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T1 clean label (com.test.b) gets its own baseline advanced to POST_DEPLOY_SHA" \
  || nok "T1 clean label advanced" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && ok "T1 guarded label (com.test.a) is RECORDED, frozen at the effective PRE (C0) and flagged stuck" \
  || nok "T1 guarded label must be recorded frozen at C0 with the stuck flag (ga-7polxu: it used to be dropped)" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -q "^com.test.a $EXPECT_C1" \
  && nok "T1 guarded label must NOT have its baseline advanced to POST_DEPLOY_SHA" "perdaemon=[$PERDAEMON_AFTER]" \
  || ok "T1 guarded label was not advanced past its frozen baseline"

# ── T2: a pre-existing entry for a label NOT examined this cycle is kept ─────
run_block "NEEDS_GUARDED_RESTART" "com.test.b" "" "" "com.test.c deadbeef0000000000000000000000000000000"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.c deadbeef0000000000000000000000000000000" \
  && ok "T2 pre-existing entry for a label outside this cycle's ALL_LABELS is carried forward untouched" \
  || nok "T2 carry-forward" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T2 this cycle's clean label is still advanced alongside the carried-forward entry" \
  || nok "T2 clean label advanced" "perdaemon=[$PERDAEMON_AFTER]"

# ── T2b: a stuck-flagged entry for a label NOT examined this cycle keeps its flag
run_block "NEEDS_GUARDED_RESTART" "com.test.b" "" "" "com.test.c @C0@ stuck"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.c $EXPECT_C0 stuck" \
  && ok "T2b a stuck-flagged entry for an unexamined label is carried forward verbatim, flag included" \
  || nok "T2b flagged carry-forward" "perdaemon=[$PERDAEMON_AFTER]"

# ── T3: per-daemon write is independent of the rig-wide OK|SKIPPED gate ──────
run_block "NEEDS_GUARDED_RESTART" "com.test.b" "" "" ""
[ -z "$RIGMARKER_AFTER" ] \
  && ok "T3 rig-wide marker NOT advanced on a non-OK verdict (ga-gokm6 behavior, unchanged)" \
  || nok "T3 rig marker" "got '$RIGMARKER_AFTER', want empty"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T3 per-daemon marker STILL advances for the clean label despite the non-OK rig-wide verdict — the actual fix" \
  || nok "T3 perdaemon advanced despite non-OK verdict" "perdaemon=[$PERDAEMON_AFTER]"

# ── T4: a guarded label keeps a real pre-existing entry between PRE and POST ─
WANT_MID=1 run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" "com.test.a @MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_MID stuck" \
  && ok "T4 guarded label keeps its own last-known-clean point (MID), frozen and flagged" \
  || nok "T4 existing entry must be carried, not reset" "perdaemon=[$PERDAEMON_AFTER] want 'com.test.a $EXPECT_MID stuck'"

# ── T5: an unusable pre-existing entry is re-frozen at the effective PRE ─────
run_block "NEEDS_GUARDED_RESTART" "com.test.a" "com.test.a" "" "com.test.a deadbeef0000000000000000000000000000000"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && ok "T5 an entry that is not a commit is replaced by the effective PRE (C0), never trusted" \
  || nok "T5 garbage entry must be replaced" "perdaemon=[$PERDAEMON_AFTER]"

# ── T5b: an older-than-PRE real commit is the truthful 'unresolved since' ────
WANT_MID=1 run_block "NEEDS_GUARDED_RESTART" "com.test.a" "com.test.a" "" "com.test.a @C0@" "@MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && ok "T5b a real commit older than the effective PRE is preserved for a still-stuck label" \
  || nok "T5b older-than-PRE real entry must be preserved" "perdaemon=[$PERDAEMON_AFTER]"

# ── T6: FRESH_FAIL is frozen exactly like GUARDED ────────────────────────────
run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.c" "" "com.test.c" ""
echo "$PERDAEMON_AFTER" | grep -qx "com.test.c $EXPECT_C0 stuck" \
  && ok "T6 a FRESH_FAIL label is frozen at the effective PRE and flagged" \
  || nok "T6 FRESH_FAIL must be frozen" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C1" \
  && ok "T6 the clean label beside it still advances" \
  || nok "T6 clean neighbour" "perdaemon=[$PERDAEMON_AFTER]"

# ── T6b: a stuck label absent from ALL_LABELS is frozen too, one line each ───
run_block "NEEDS_GUARDED_RESTART" "com.test.a" "com.test.a com.test.z" "" ""
[ "$(echo "$PERDAEMON_AFTER" | grep -c '^com.test.z ')" = "1" ] && echo "$PERDAEMON_AFTER" | grep -qx "com.test.z $EXPECT_C0 stuck" \
  && ok "T6b a guarded label the helper did not list in ALL_LABELS is still frozen (exactly one line)" \
  || nok "T6b guarded-but-unlisted label" "perdaemon=[$PERDAEMON_AFTER]"
[ "$(echo "$PERDAEMON_AFTER" | grep -c '^com.test.a ')" = "1" ] \
  && ok "T6b a label in both ALL_LABELS and GUARDED is written exactly once" \
  || nok "T6b duplicate line for a label in ALL_LABELS and GUARDED" "perdaemon=[$PERDAEMON_AFTER]"

# ── T7: a stuck-flagged entry survives a cycle where the window no longer
#    covers it (the marker already advanced past it) ──────────────────────────
WANT_MID=1 run_block "OK" "com.test.a com.test.b" "" "" "com.test.a @C0@ stuck" "@MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && ok "T7 the frozen entry survives a cycle where the label is no longer flagged but the window (MID..C1) does not cover C0" \
  || nok "T7 unknown must not become clean (ga-7polxu)" "perdaemon=[$PERDAEMON_AFTER]"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T7 the never-stuck neighbour still advances to POST_DEPLOY_SHA" \
  || nok "T7 clean neighbour" "perdaemon=[$PERDAEMON_AFTER]"

# ── T7b: a flagged entry whose sha is not a real commit carries no information;
#    it must not read as "not covered" and outlive the label forever ───────────
WANT_MID=1 run_block "OK" "com.test.a" "" "" "com.test.a deadbeef0000000000000000000000000000000 stuck" "@MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C1" \
  && ok "T7b a stuck-flagged entry whose sha is not a commit is replaced (advanced), not kept forever" \
  || nok "T7b a garbage flagged entry must not outlive the label" "perdaemon=[$PERDAEMON_AFTER]"

# ── T8: once the window covers the flagged entry, not-flagged is really clean ─
run_block "OK" "com.test.a" "" "" "com.test.a @C0@ stuck" "@C0@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C1" \
  && ok "T8 a flagged label the covering window finds clean is advanced to POST_DEPLOY_SHA with the flag cleared" \
  || nok "T8 verified-clean label must be released" "perdaemon=[$PERDAEMON_AFTER]"

# ── T9: the consumer's own lookup returns the sha alone ──────────────────────
run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" ""
consumed="$(printf '%s\n' "$PERDAEMON_AFTER" | awk -v l="com.test.a" '$1==l{print $2; exit}')"
[ "$consumed" = "$EXPECT_C0" ] \
  && ok "T9 daemon-refresh.sh's own awk lookup reads a frozen entry as the bare sha (the stuck flag does not leak into it)" \
  || nok "T9 consumer lookup" "got '$consumed' want '$EXPECT_C0'"

# ── T11: no GUARDED= line = "the helper did not say", not "nothing is stuck" ──
#    A missing line and an empty line are different facts; only the second may
#    let a flagged label advance. The file must be left exactly as it was.
STUB_OMIT_GUARDED=1 run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "" "" "com.test.a @C0@ stuck"
[ "$PERDAEMON_AFTER" = "com.test.a $EXPECT_C0 stuck" ] \
  && ok "T11 a helper output with no GUARDED= line leaves the per-daemon file exactly as it was (unknown is not clean)" \
  || nok "T11 absent GUARDED= must not be read as 'nothing is stuck'" "perdaemon=[$PERDAEMON_AFTER] want 'com.test.a $EXPECT_C0 stuck'"

# ── T12: a per-daemon file that cannot be READ is not an EMPTY one ────────────
#    mode 200 = writable but unreadable: a naive read-as-empty then rewrite would
#    succeed and erase every flag.
PD_SEED_MODE=200 run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "" "" "com.test.a @C0@ stuck"
[ "$PERDAEMON_AFTER" = "com.test.a $EXPECT_C0 stuck" ] \
  && ok "T12 an unreadable per-daemon file is left untouched this cycle, not rewritten as if empty" \
  || nok "T12 read failure must not read as an empty file" "perdaemon=[$PERDAEMON_AFTER] want 'com.test.a $EXPECT_C0 stuck'"

# ── T13: git that cannot ANSWER is not git saying NO ──────────────────────────
#    Runtime dir is not a repository, so every git call errors. A stuck record
#    must survive: neither replaced by PRE (stuck branch) nor advanced as clean
#    (unknown branch) on a guess.
WANT_MID=1 BREAK_GIT=1 run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" "com.test.a @MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_MID stuck" \
  && ok "T13a a still-stuck label keeps its existing entry when git cannot say whether it is valid" \
  || nok "T13a a git error must not replace the recorded baseline" "perdaemon=[$PERDAEMON_AFTER] want 'com.test.a $EXPECT_MID stuck'"
WANT_MID=1 BREAK_GIT=1 run_block "OK" "com.test.a" "" "" "com.test.a @C0@ stuck" "@MID@"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && ok "T13b a flagged entry is kept, not advanced as clean, when git cannot say whether the window covers it" \
  || nok "T13b a git error must not turn a stuck record into a clean one" "perdaemon=[$PERDAEMON_AFTER] want 'com.test.a $EXPECT_C0 stuck'"

# ── T10: the same block, under `set -e` ──────────────────────────────────────
ERREXIT=1 run_block "NEEDS_GUARDED_RESTART" "com.test.a com.test.b" "com.test.a" "" ""
[ "$RUN_RC" -eq 0 ] \
  && ok "T10 the block runs clean under set -e" \
  || nok "T10 set -e" "rc=$RUN_RC"
echo "$PERDAEMON_AFTER" | grep -qx "com.test.a $EXPECT_C0 stuck" \
  && echo "$PERDAEMON_AFTER" | grep -qx "com.test.b $EXPECT_C1" \
  && ok "T10 both entries are written under set -e" \
  || nok "T10 entries under set -e" "perdaemon=[$PERDAEMON_AFTER]"

echo ""
echo "story-delivery per-daemon baseline tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
