#!/usr/bin/env bash
# story-delivery-daemon-refresh-lstart-advance.test.sh — regression test for ga-8hfols
# (extracts the real Step 5b block and the real runtime_head_at_epoch from
# story-delivery.sh, no duplication — same technique as
# story-delivery-daemon-refresh-perdaemon-baseline.test.sh).
#
# THE BUG (ga-8hfols, measured 11/10): the rig baseline marker ($RIG.sha) sat on
# e078b5686 (09/10) through a reboot (10/10 23:40:56) that restarted every KeepAlive WA
# daemon (all lstart 23:41:51). Every later delivery compared the WIDE window since
# e078b5686 and read 29 daemons "guarded"; 53 per-daemon entries stayed 'stuck' for
# days. Every writer of the baseline (ga-0fawwr, ga-49fwiw, ga-n2jnsa, ...) moves it on
# a DIFF-based verdict; none could use the one fact a reboot (or a Mayor kickstart, or a
# crew restart) establishes: WHEN each process started, against what the checkout held
# at that second. Two notify_only_locked dashboards that no automation may restart held
# the whole rig back on top of that, read "older than the merge" by time on every cycle.
#
# THE FIX: daemon-refresh.sh reports each questioned daemon's start epoch
# (LSTART_EPOCHS); story-delivery.sh asks the checkout's HEAD reflog what HEAD was at that
# second (runtime_head_at_epoch) — a process that started while HEAD was H runs code at
# or after H — and then
#   (1) advances that daemon's per-daemon entry to H, whatever the verdict;
#   (2) advances the rig marker to the OLDEST such H when every non-clean label is proven
#       or locked-cosmetic (NEEDS_GUARDED_RESTART only; strictly forward only);
#   (3) lets a notify_only_locked daemon with no symbol path (GUARDED_LOCKED_COSMETIC) stop
#       holding the marker.
# THREE STATES: an unreadable start time, an arrival the reflog cannot place, a git
# failure — "não sei" — never reads as fresh.
#
# Timeline (unix epochs, all via GIT_COMMITTER_DATE so the REFLOG stamps are exact):
#   1000  B   base — arrives in the runtime checkout; the rig marker sits here
#   2000  M   (WANT_MID=1) a middle commit
#   3000  S   POST_DEPLOY_SHA arrives
#
# U1-U7  runtime_head_at_epoch itself, on real reflogs.
# A1     (the spec fixture) old marker + every daemon started after S arrived -> marker = S.
# A2     a flagged daemon that is NOT guarded now loses its flag; a locked-cosmetic daemon
#        no one may restart does not hold the marker.
# C1-C14 controls: a daemon started BEFORE S arrived and touched by it -> no advance;
#        unknown / predates the log / same-second tie / garbage / not on POST's history /
#        FRESH_FAIL / wrong verdict / dry run / locked but not cosmetic / git broken.
# M1-M2  the marker goes to the OLDEST proof and never backwards; a proof older than a
#        recorded entry does not pull the entry back.
# D1-D6  (gate fix 1) a start time proves something only for a daemon that runs the
#        checkout whose reflog is read. D1/D1b: a stuck label the helper did NOT examine this
#        cycle (absent from ALL_LABELS) is not "clean" just because it is not guarded now —
#        its flag survives and its own proof still bounds the marker. D2/D3: a label the
#        helper lists in LSTART_UNPINNED (another clone / a launch whose clone cannot be
#        told) is never "proven" — it blocks the marker and keeps its frozen entry, even if
#        a start epoch is given for it, and the log says why. D4/D5: a missing
#        LSTART_UNPINNED line is "no proof" (not "all pinned"); an empty present one works.
# D7-D9  (gate attempt 2) the same missing line must also withdraw the locked-cosmetic
#        excuse, whether or not epochs were printed (D7 both LSTART lines absent, D8 epochs
#        without UNPINNED; D7b is the positive control). D9: a cosmetic-only advance is logged
#        as such — "process proof" is only claimed when some daemon was proven by start time.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }
HEAD_FN="$(sed -n '/^runtime_head_at_epoch() {/,/^}/p' "$DELIVERY")"
[ -n "$HEAD_FN" ] || { echo "FAIL: could not extract runtime_head_at_epoch from $DELIVERY (the fix is missing)"; exit 1; }
eval "$HEAD_FN"

RIG_MARKER_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.sha"
PERDAEMON_REL=".gc/runtime/daemon-refresh-baseline/whatsapp_automation.perdaemon"

# gitc <repo> <epoch> <git args...>: run git with the committer date — and therefore the
# reflog stamp — pinned. The "@" form is required (see story-delivery-bead-reprobe-arrival-floor.test.sh).
gitc() { local r="$1" e="$2"; shift 2; GIT_COMMITTER_DATE="@$e +0000" GIT_AUTHOR_DATE="@$e +0000" git -C "$r" "$@"; }

# build_repo <dir>: sets SHA_B SHA_M SHA_S SHA_X per WANT_MID / WANT_SIDE.
build_repo() {
  local R="$1"
  git init -q "$R"
  git -C "$R" config user.email t@t.local
  git -C "$R" config user.name t
  echo base > "$R/f.txt"; git -C "$R" add -A; gitc "$R" 1000 commit -q -m B
  SHA_B="$(git -C "$R" rev-parse HEAD)"
  SHA_M=""; SHA_X=""
  if [ "${WANT_SIDE:-0}" = "1" ]; then
    # HEAD sits on a commit that is NOT an ancestor of S between 1500 and 2500
    local main_br; main_br="$(git -C "$R" symbolic-ref --short HEAD)"
    gitc "$R" 1200 checkout -q -b side
    echo side > "$R/f.txt"; git -C "$R" add -A; gitc "$R" 1500 commit -q -m X
    SHA_X="$(git -C "$R" rev-parse HEAD)"
    gitc "$R" 2500 checkout -q "$main_br"
  fi
  if [ "${WANT_MID:-0}" = "1" ]; then
    echo mid > "$R/f.txt"; git -C "$R" add -A; gitc "$R" 2000 commit -q -m M
    SHA_M="$(git -C "$R" rev-parse HEAD)"
  fi
  echo tip > "$R/f.txt"; git -C "$R" add -A; gitc "$R" 3000 commit -q -m S
  SHA_S="$(git -C "$R" rev-parse HEAD)"
}

# run_block — parameters (all optional) come from the environment:
#   VERDICT (NEEDS_GUARDED_RESTART)  ALL  GUARDED  FRESHFAIL  LSTART  UNPINNED  COSMETIC
#   SEED (per-daemon file; tokens @B@ @M@ @S@ @X@)  MARKER (rig marker seed, same tokens; default @B@)
#   STUB_OMIT_LSTART=1 / STUB_OMIT_COSMETIC=1 / STUB_OMIT_UNPINNED=1  (the helper printed no such line at all)
#   WANT_MID WANT_SIDE DRY_RUN_FLAG ERREXIT BREAK_GIT
# Sets: RUN_RC PERDAEMON_AFTER RIGMARKER_AFTER LOG_AFTER SHA_B SHA_M SHA_S SHA_X
run_block() {
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"
  local REPO="$T/runtime"
  build_repo "$REPO"

  local seed="${SEED:-}" marker="${MARKER-@B@}" t
  for t in B M S X; do
    local v="SHA_$t"
    seed="${seed//@$t@/${!v}}"; marker="${marker//@$t@/${!v}}"
  done
  if [ -n "$seed" ]; then
    mkdir -p "$GC_CITY/$(dirname "$PERDAEMON_REL")"
    printf '%s\n' "$seed" > "$GC_CITY/$PERDAEMON_REL"
  fi
  if [ -n "$marker" ]; then
    mkdir -p "$GC_CITY/$(dirname "$RIG_MARKER_REL")"
    printf '%s\n' "$marker" > "$GC_CITY/$RIG_MARKER_REL"
  fi

  {
    echo "echo \"VERDICT=${VERDICT:-NEEDS_GUARDED_RESTART}\""
    echo "echo \"ALL_LABELS=${ALL:-}\""
    echo 'echo "RESTARTED="'
    echo "echo \"GUARDED=${GUARDED:-}\""
    echo "echo \"FRESH_FAIL=${FRESHFAIL:-}\""
    [ "${STUB_OMIT_COSMETIC:-0}" = "1" ] || echo "echo \"GUARDED_LOCKED_COSMETIC=${COSMETIC:-}\""
    [ "${STUB_OMIT_LSTART:-0}" = "1" ] || echo "echo \"LSTART_EPOCHS=${LSTART:-}\""
    [ "${STUB_OMIT_UNPINNED:-0}" = "1" ] || echo "echo \"LSTART_UNPINNED=${UNPINNED:-}\""
    echo 'echo "REASON=stub"'
    echo 'exit 0'
  } > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh"

  LOG_FILE="$T/log.log"
  bd()   { :; }
  gc()   { :; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local PRE_DEPLOY_SHA="$SHA_B" POST_DEPLOY_SHA="$SHA_S" DEPLOY_EPOCH=1
  local DRY_RUN="${DRY_RUN_FLAG:-0}"
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
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
  PERDAEMON_AFTER="$(cat "$GC_CITY/$PERDAEMON_REL" 2>/dev/null || true)"
  RIGMARKER_AFTER="$(cat "$GC_CITY/$RIG_MARKER_REL" 2>/dev/null || true)"
  LOG_AFTER="$(cat "$LOG_FILE" 2>/dev/null || true)"
  rm -rf "$T"
}

has_line() { printf '%s\n' "$1" | grep -qx -- "$2"; }

# ── U1-U7: runtime_head_at_epoch on real reflogs ─────────────────────────────
UT="$(mktemp -d)"
WANT_MID=1 build_repo "$UT/rt"
got="$(runtime_head_at_epoch "$UT/rt" 2500)"
[ "$got" = "$SHA_M" ] && ok "U1 HEAD at 2500 = M (the newest entry stamped before it), not S (3000) nor B (1000)" || nok "U1" "want=$SHA_M got=[$got]"
got="$(runtime_head_at_epoch "$UT/rt" 3000)"
[ "$got" = "$SHA_M" ] && ok "U2 a start stamped in the SAME second S arrived reads as M — the weaker claim; a tie is never taken for 'after'" || nok "U2 tie" "want=$SHA_M got=[$got]"
got="$(runtime_head_at_epoch "$UT/rt" 3001)"
[ "$got" = "$SHA_S" ] && ok "U3 one second later it is S" || nok "U3" "want=$SHA_S got=[$got]"
got="$(runtime_head_at_epoch "$UT/rt" 900)"
[ -z "$got" ] && ok "U4 a process that predates everything the reflog remembers: unknown (nothing printed)" || nok "U4 predates the log" "got=[$got]"
got="$(runtime_head_at_epoch "$UT/rt" "abc")"; got2="$(runtime_head_at_epoch "$UT/rt" "")"
[ -z "$got$got2" ] && ok "U5 a non-numeric / empty epoch: unknown" || nok "U5 garbage epoch" "got=[$got][$got2]"
got="$(GIT_DIR="$UT/no-such-git-dir" runtime_head_at_epoch "$UT/rt" 3001)"
[ -z "$got" ] && ok "U6 a runtime git cannot read: unknown" || nok "U6 broken git" "got=[$got]"
# U7: the clock stepped back between two pulls — the log is not in time order.
git init -q "$UT/skew"; git -C "$UT/skew" config user.email t@t.local; git -C "$UT/skew" config user.name t
echo a > "$UT/skew/f"; git -C "$UT/skew" add -A; gitc "$UT/skew" 5000 commit -q -m one
echo b > "$UT/skew/f"; git -C "$UT/skew" add -A; gitc "$UT/skew" 3000 commit -q -m two
got="$(runtime_head_at_epoch "$UT/skew" 2000)"
[ -z "$got" ] && ok "U7 a reflog that is not in time order (clock step): unknown, never a guess" || nok "U7 clock step" "got=[$got]"
rm -rf "$UT"

# ── A1: the spec fixture ─────────────────────────────────────────────────────
# old marker (B) + every daemon started after S arrived (3500 > 3000) -> marker = S.
ALL="com.t.a com.t.b com.t.c" GUARDED="com.t.a com.t.b com.t.c" LSTART="com.t.a=3500 com.t.b=3500 com.t.c=3500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] \
  && ok "A1 old marker + every non-clean daemon's lstart after S arrived -> the rig marker advances to S" \
  || nok "A1 marker must advance to S" "marker=[$RIGMARKER_AFTER] want=$SHA_S log=[$LOG_AFTER]"
for l in a b c; do
  has_line "$PERDAEMON_AFTER" "com.t.$l $SHA_S stuck" \
    && ok "A1 com.t.$l: per-daemon entry B -> S (the flag stays: it is GUARDED this very cycle, so it is still being watched)" \
    || nok "A1 com.t.$l entry" "perdaemon=[$PERDAEMON_AFTER]"
done
echo "$LOG_AFTER" | grep -q "advanced .* by process proof" && ok "A1 the advance is logged with its proof" || nok "A1 log" "$LOG_AFTER"

# A1b: the same under `set -e`, how story-delivery.sh runs the block in production.
ERREXIT=1 ALL="com.t.a com.t.b" GUARDED="com.t.a com.t.b" LSTART="com.t.a=3500 com.t.b=3500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S stuck" \
  && ok "A1b holds under set -e + pipefail" || nok "A1b errexit" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] rc=$RUN_RC"

# ── A2: a flagged daemon that is not guarded now; a locked-cosmetic one ──────
# a: flagged earlier, restarted (lstart 3500), not guarded now -> entry S, flag OFF.
# b: guarded now, proven.  z: notify_only_locked + no symbol path, never restarted.
ALL="com.t.a com.t.b com.t.z com.t.d" GUARDED="com.t.b com.t.z" COSMETIC="com.t.z" \
LSTART="com.t.a=3500 com.t.b=3500" \
SEED="com.t.a @B@ stuck
com.t.z @B@ stuck" run_block
has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S" \
  && ok "A2 a flagged daemon that is NOT guarded now and is proven at S: entry S and the stuck flag is gone" \
  || nok "A2 a" "perdaemon=[$PERDAEMON_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.b $SHA_S stuck" && ok "A2 b (guarded now, proven) advanced, still watched" || nok "A2 b" "perdaemon=[$PERDAEMON_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.z $SHA_B stuck" \
  && ok "A2 z (locked-cosmetic) keeps its frozen 'stuck' entry — excused for the marker, not erased" \
  || nok "A2 z" "perdaemon=[$PERDAEMON_AFTER]"
[ "$RIGMARKER_AFTER" = "$SHA_S" ] \
  && ok "A2 a notify_only_locked daemon with no symbol path does not hold the rig marker (ga-j3lh6p evidence, this cycle)" \
  || nok "A2 marker" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"
echo "$LOG_AFTER" | grep -q "locked-cosmetic, not blocking: \[com.t.z\]" && ok "A2 the log names the locked-cosmetic daemon it excused" || nok "A2 log" "$LOG_AFTER"

# A3: only locked-cosmetic labels are stuck, nothing needed a proof -> the marker may go to POST.
ALL="com.t.d com.t.z" GUARDED="com.t.z" COSMETIC="com.t.z" LSTART="" SEED="com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] && ok "A3 every stuck label is locked-cosmetic and the rest is clean -> marker = POST" || nok "A3" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"

# ── C1: the control — a daemon that started BEFORE S arrived ─────────────────
ALL="com.t.a com.t.b com.t.c" GUARDED="com.t.a com.t.b com.t.c" LSTART="com.t.a=3500 com.t.b=3500 com.t.c=2500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] \
  && ok "C1 one daemon started at 2500, before S arrived (3000), and is not excused -> the marker does NOT advance" \
  || nok "C1 marker must stay on B" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.c $SHA_B stuck" && ok "C1 the unproven daemon keeps its frozen entry" || nok "C1 c entry" "perdaemon=[$PERDAEMON_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S stuck" \
  && ok "C1 the proven neighbours still advance their OWN entries — the proof is per daemon, independent of the rest" \
  || nok "C1 a entry" "perdaemon=[$PERDAEMON_AFTER]"
echo "$LOG_AFTER" | grep -q "NOT advanced by process proof.*held by \[com.t.c\]" && ok "C1 the log names the daemon that pins the marker" || nok "C1 log" "$LOG_AFTER"

# C2: no start time for c at all (no live pid / ps unreadable): unknown, not fresh.
ALL="com.t.a com.t.c" GUARDED="com.t.a com.t.c" LSTART="com.t.a=3500" \
SEED="com.t.a @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.c $SHA_B stuck" \
  && ok "C2 a daemon with no readable start time blocks the marker and keeps its entry (unknown is not fresh)" \
  || nok "C2" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"

# C3: c started before the oldest reflog entry (500 < 1000): the log cannot place it.
ALL="com.t.a com.t.c" GUARDED="com.t.a com.t.c" LSTART="com.t.a=3500 com.t.c=500" \
SEED="com.t.a @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C3 a daemon older than the reflog's memory blocks the marker" || nok "C3" "marker=[$RIGMARKER_AFTER]"

# C4: the same-second tie. c started at 3000, the second S arrived.
ALL="com.t.a com.t.c" GUARDED="com.t.a com.t.c" LSTART="com.t.a=3500 com.t.c=3000" \
SEED="com.t.a @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.c $SHA_B stuck" \
  && ok "C4 started in the very second S arrived: the pull may have landed after the process loaded — not proven" \
  || nok "C4 tie" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"

# C5: a garbage epoch from the helper.
ALL="com.t.a com.t.c" GUARDED="com.t.a com.t.c" LSTART="com.t.a=3500 com.t.c=soon" \
SEED="com.t.a @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C5 a non-numeric epoch is not a proof" || nok "C5" "marker=[$RIGMARKER_AFTER]"

# C6: the reflog says HEAD was a commit that is NOT on POST's history when c started.
WANT_SIDE=1 ALL="com.t.a com.t.c" GUARDED="com.t.a com.t.c" LSTART="com.t.a=3500 com.t.c=2000" \
SEED="com.t.a @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.c $SHA_B stuck" \
  && ok "C6 HEAD was on a side branch when c started (not an ancestor of POST): proves nothing about this window" \
  || nok "C6 side branch" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] X=$SHA_X"

# C7: FRESH_FAIL is a failure to investigate, not a staleness to excuse — even when proven.
ALL="com.t.a com.t.b" GUARDED="com.t.a" FRESHFAIL="com.t.b" LSTART="com.t.a=3500 com.t.b=3500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C7 a FRESH_FAIL label blocks the marker advance even if its start time is after S" || nok "C7" "marker=[$RIGMARKER_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.b $SHA_S stuck" && ok "C7 (its per-daemon entry still moves to the proven point; the flag stays)" || nok "C7 b entry" "perdaemon=[$PERDAEMON_AFTER]"

# C8: any verdict other than NEEDS_GUARDED_RESTART — the marker is not this path's to move;
# the per-daemon proof still applies ("independent of verdict").
VERDICT=VERIFY_FAILED ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=3500" SEED="com.t.a @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S stuck" \
  && ok "C8 VERIFY_FAILED: marker untouched, per-daemon proof still applied" \
  || nok "C8" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"

# C9: dry run writes nothing at all.
DRY_RUN_FLAG=1 ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=3500" SEED="com.t.a @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_B stuck" \
  && ok "C9 DRY_RUN=1 changes nothing" || nok "C9" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"

# C10: z is guarded, not proven, and the helper says it is NOT locked-cosmetic (empty line).
ALL="com.t.a com.t.z" GUARDED="com.t.a com.t.z" COSMETIC="" LSTART="com.t.a=3500" \
SEED="com.t.a @B@ stuck
com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C10 unproven + not locked-cosmetic blocks the marker" || nok "C10" "marker=[$RIGMARKER_AFTER]"
# C10b: the helper printed no GUARDED_LOCKED_COSMETIC line at all (an older helper): absent != empty != 'z'.
STUB_OMIT_COSMETIC=1 ALL="com.t.a com.t.z" GUARDED="com.t.a com.t.z" LSTART="com.t.a=3500" \
SEED="com.t.a @B@ stuck
com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C10b no cosmetic line from the helper: nothing is excused" || nok "C10b" "marker=[$RIGMARKER_AFTER]"
# C10c: an older helper with no LSTART_EPOCHS line — no proof exists, nothing changes.
STUB_OMIT_LSTART=1 ALL="com.t.a" GUARDED="com.t.a" SEED="com.t.a @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_B stuck" \
  && ok "C10c no LSTART_EPOCHS line (older helper): marker and entry untouched" || nok "C10c" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"

# C11: git cannot answer anything — no crash, nothing advances.
BREAK_GIT=1 ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=3500" SEED="com.t.a @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C11 git failing: the marker stays (unknown is not clean)" || nok "C11" "marker=[$RIGMARKER_AFTER]"

# C12: a stuck label the helper did not examine and cannot read (flagged in the file,
# absent from ALL_LABELS, no start time) is a blocker too — not silently skipped.
ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=3500" \
SEED="com.t.a @B@ stuck
com.t.ghost @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && ok "C12 a flagged label nobody examined and nobody could read blocks the marker" || nok "C12" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"
echo "$LOG_AFTER" | grep -q "com.t.ghost" && ok "C12 the log says which label" || nok "C12 log" "$LOG_AFTER"

# C13: a marker that already equals the oldest proof does not "advance" to itself.
WANT_MID=1 MARKER="@M@" ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=2500" SEED="com.t.a @M@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_M" ] && ok "C13 the oldest proof is the marker itself: no write, nothing moves backwards or sideways" || nok "C13" "marker=[$RIGMARKER_AFTER]"

# ── M1: the marker goes to the OLDEST proof ──────────────────────────────────
WANT_MID=1 ALL="com.t.a com.t.b com.t.c" GUARDED="com.t.a com.t.b com.t.c" LSTART="com.t.a=3500 com.t.b=3500 com.t.c=2500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck
com.t.c @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_M" ] \
  && ok "M1 a, b proven at S and c only at M: the marker goes to M (past it c's closure is still unexamined)" \
  || nok "M1 marker must be M" "marker=[$RIGMARKER_AFTER] want=$SHA_M"
has_line "$PERDAEMON_AFTER" "com.t.c $SHA_M stuck" && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S stuck" \
  && ok "M1 each daemon's own entry is its own proof (c at M, a at S)" || nok "M1 entries" "perdaemon=[$PERDAEMON_AFTER]"

# M2: a proof OLDER than the recorded entry never pulls the entry back.
WANT_MID=1 ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=1500" SEED="com.t.a @M@ stuck" run_block
has_line "$PERDAEMON_AFTER" "com.t.a $SHA_M stuck" \
  && ok "M2 a proof (B) older than the recorded entry (M) leaves the entry on M" \
  || nok "M2 monotone" "perdaemon=[$PERDAEMON_AFTER]"

# ── D1: a stuck label the helper did not examine this cycle is not "clean" ───
# a is examined (ALL) and proven at S. u is flagged stuck, NOT in ALL_LABELS, not guarded,
# has a live pid (start 2500 -> HEAD was M). Absent from GUARDED is not "examined and clean":
# u keeps its flag, and the marker may only go as far as u's own proof (M), not to S.
WANT_MID=1 ALL="com.t.a" GUARDED="com.t.a" LSTART="com.t.a=3500 com.t.u=2500" \
SEED="com.t.a @B@ stuck
com.t.u @B@ stuck" run_block
has_line "$PERDAEMON_AFTER" "com.t.u $SHA_M stuck" \
  && ok "D1 a stuck label the helper did not examine keeps its flag (entry moves to its own proof M)" \
  || nok "D1 u entry/flag" "perdaemon=[$PERDAEMON_AFTER]"
[ "$RIGMARKER_AFTER" = "$SHA_M" ] \
  && ok "D1 the marker stops at the unexamined daemon's proof (M) — 'every other daemon was clean' would be untrue" \
  || nok "D1 marker must be M" "marker=[$RIGMARKER_AFTER] want=$SHA_M log=[$LOG_AFTER]"
has_line "$PERDAEMON_AFTER" "com.t.a $SHA_S stuck" && ok "D1 the examined, proven neighbour still advances its own entry" || nok "D1 a entry" "perdaemon=[$PERDAEMON_AFTER]"

# D1b: the positive control — a label the helper DID examine (in ALL), no longer guarded,
# proven: its flag goes away (A2 a), and the rest of the file is untouched.
WANT_MID=1 ALL="com.t.a com.t.u" GUARDED="com.t.a" LSTART="com.t.a=3500 com.t.u=2500" \
SEED="com.t.a @B@ stuck
com.t.u @B@ stuck" run_block
has_line "$PERDAEMON_AFTER" "com.t.u $SHA_S" \
  && ok "D1b an EXAMINED, no-longer-guarded label is current at POST and loses its stuck flag (the flag is gated on being examined, not removed everywhere)" \
  || nok "D1b u flag must go" "perdaemon=[$PERDAEMON_AFTER]"

# ── D2: a label that runs code outside the runtime checkout is never proven ──
# p is GUARDED and lstart-less (the helper left it out: UNPINNED). Blocks the marker, keeps
# its entry, and the log gives the reason a reader needs.
ALL="com.t.a com.t.p" GUARDED="com.t.a com.t.p" LSTART="com.t.a=3500" UNPINNED="com.t.p" \
SEED="com.t.a @B@ stuck
com.t.p @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.p $SHA_B stuck" \
  && ok "D2 an unpinned GUARDED label (another clone) stays a blocker: marker and its entry do not move" \
  || nok "D2 marker/entry" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"
echo "$LOG_AFTER" | grep -q "run code outside the whatsapp_automation runtime checkout" \
  && ok "D2 the log says WHY (it runs code outside the rig's runtime checkout; a start time read against that checkout proves nothing)" \
  || nok "D2 log reason" "$LOG_AFTER"
echo "$LOG_AFTER" | grep -q "com.t.p" && ok "D2 the log names the label" || nok "D2 log label" "$LOG_AFTER"

# D3: defence in depth — even if an epoch for p slips through next to its UNPINNED entry
# (a helper bug, a mixed-version pair), the consumer does not take it as proof.
ALL="com.t.a com.t.p" GUARDED="com.t.a com.t.p" LSTART="com.t.a=3500 com.t.p=3500" UNPINNED="com.t.p" \
SEED="com.t.a @B@ stuck
com.t.p @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.p $SHA_B stuck" \
  && ok "D3 a start epoch given for a label that is also UNPINNED is ignored: UNPINNED wins" \
  || nok "D3 unpinned must win" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] log=[$LOG_AFTER]"

# D4: no UNPINNED line at all — epochs printed by a helper that never asked "which clone
# does each daemon run?" (a mixed-version pair, a crash mid-print). A missing line is not an
# empty one: no process proof is taken, nothing moves, and the log says why.
STUB_OMIT_UNPINNED=1 ALL="com.t.a com.t.b" GUARDED="com.t.a com.t.b" LSTART="com.t.a=3500 com.t.b=3500" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.a $SHA_B stuck" && has_line "$PERDAEMON_AFTER" "com.t.b $SHA_B stuck" \
  && ok "D4 epochs without an LSTART_UNPINNED line prove nothing: marker and both entries stay where they were" \
  || nok "D4 no-line must be no-proof" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER]"
echo "$LOG_AFTER" | grep -q "LSTART_UNPINNED" && ok "D4 the log names the missing line" || nok "D4 log" "$LOG_AFTER"

# D5: the positive control for D4 — the same input WITH an empty LSTART_UNPINNED line is a
# helper that asked and found every label pinned: the proof works (A1 again, through the
# new field), so D4 fails for the missing line and nothing else.
ALL="com.t.a com.t.b" GUARDED="com.t.a com.t.b" LSTART="com.t.a=3500 com.t.b=3500" UNPINNED="" \
SEED="com.t.a @B@ stuck
com.t.b @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] && ok "D5 an empty (present) LSTART_UNPINNED line: the process proof works" || nok "D5" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"

# D6: a label that is BOTH locked-cosmetic and UNPINNED. The cosmetic verdict is the helper's
# call-graph read of the label's entrypoint against THIS checkout's window; for a daemon whose
# clone cannot be told apart from the runtime checkout it says nothing about the code that
# daemon really imports. Not knowing which clone is not a license to excuse: it stays a blocker.
ALL="com.t.a com.t.p" GUARDED="com.t.a com.t.p" COSMETIC="com.t.p" LSTART="com.t.a=3500" UNPINNED="com.t.p" \
SEED="com.t.a @B@ stuck
com.t.p @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.p $SHA_B stuck" \
  && ok "D6 an UNPINNED label is not excused as locked-cosmetic: marker and its entry do not move" \
  || nok "D6 unpinned must beat cosmetic" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] log=[$LOG_AFTER]"
echo "$LOG_AFTER" | grep -q "run code outside the whatsapp_automation runtime checkout" \
  && ok "D6 the log gives the unpinned reason" || nok "D6 log reason" "$LOG_AFTER"

# D6b: the positive control — the same label, same cosmetic verdict, but the helper pinned it:
# the existing excuse works (A2 again), so D6 holds only because of the UNPINNED entry.
ALL="com.t.a com.t.p" GUARDED="com.t.a com.t.p" COSMETIC="com.t.p" LSTART="com.t.a=3500" UNPINNED="" \
SEED="com.t.a @B@ stuck
com.t.p @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] && ok "D6b a pinned locked-cosmetic label is still excused" || nok "D6b" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"

# D7 (gate attempt 2): BOTH LSTART_EPOCHS and LSTART_UNPINNED absent — a helper that predates
# them, or one cut short between GUARDED_LOCKED_COSMETIC and the LSTART lines (lstart_epochs_line
# forks launchctl/ps/date per questioned label, ~10 s for 53 labels). D4 only covered "epochs
# without UNPINNED". With both absent nothing says which clone the daemon runs, so the cosmetic
# verdict — a call-graph read against THIS checkout's window — is an excuse for code nobody
# located. It was applied anyway: the marker moved on a label with "Proven by start time: []".
STUB_OMIT_LSTART=1 STUB_OMIT_UNPINNED=1 ALL="com.t.z" GUARDED="com.t.z" COSMETIC="com.t.z" \
SEED="com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.z $SHA_B stuck" \
  && ok "D7 no LSTART lines at all: a locked-cosmetic label is NOT excused (marker and entry stay)" \
  || nok "D7 absent LSTART_UNPINNED must not excuse" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] log=[$LOG_AFTER]"
echo "$LOG_AFTER" | grep -q "NOT advanced by process proof" && echo "$LOG_AFTER" | grep -q "LSTART_UNPINNED" \
  && ok "D7 the log says the marker was not advanced and names the missing line" \
  || nok "D7 log reason" "$LOG_AFTER"

# D7b: the positive control — the same label, same cosmetic verdict, the helper's LSTART lines
# present and empty (it asked "which clone?" and every label is pinned): the excuse works,
# so D7 holds only because the LSTART_UNPINNED line is missing.
ALL="com.t.z" GUARDED="com.t.z" COSMETIC="com.t.z" LSTART="" UNPINNED="" \
SEED="com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_S" ] && ok "D7b empty LSTART lines present: a pinned locked-cosmetic label is excused" || nok "D7b" "marker=[$RIGMARKER_AFTER] log=[$LOG_AFTER]"

# D8: the sibling of D7 — epochs printed, LSTART_UNPINNED missing, and the other stuck label is
# locked-cosmetic. Epochs for a (proof) do not make z's clone known: the marker stays.
STUB_OMIT_UNPINNED=1 ALL="com.t.a com.t.z" GUARDED="com.t.a com.t.z" COSMETIC="com.t.z" LSTART="com.t.a=3500" \
SEED="com.t.a @B@ stuck
com.t.z @B@ stuck" run_block
[ "$RIGMARKER_AFTER" = "$SHA_B" ] && has_line "$PERDAEMON_AFTER" "com.t.z $SHA_B stuck" \
  && ok "D8 epochs without LSTART_UNPINNED: the cosmetic neighbour is not excused either" \
  || nok "D8 epochs-without-UNPINNED + cosmetic" "marker=[$RIGMARKER_AFTER] perdaemon=[$PERDAEMON_AFTER] log=[$LOG_AFTER]"

# D9: the log must say what actually moved the marker. A cosmetic-only advance (nothing proven
# by start time) used to be logged as "advanced by process proof ... Proven by start time: []".
ALL="com.t.z" GUARDED="com.t.z" COSMETIC="com.t.z" LSTART="" UNPINNED="" \
SEED="com.t.z @B@ stuck" run_block
echo "$LOG_AFTER" | grep -q "advanced .* by locked-cosmetic evidence alone" \
  && ! echo "$LOG_AFTER" | grep -q "advanced .* by process proof" \
  && ok "D9 a cosmetic-only advance is logged as such, not as process proof" \
  || nok "D9 log must name the real reason" "$LOG_AFTER"

echo ""
echo "story-delivery daemon-refresh lstart-advance (ga-8hfols) tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
