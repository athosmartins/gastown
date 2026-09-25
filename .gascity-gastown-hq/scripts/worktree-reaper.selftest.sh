#!/usr/bin/env bash
# worktree-reaper.selftest.sh — prove the ga-pdrij pool-worktree coverage + merged-only
# branch cleanup in isolation, against a TEMP git repo (no touch to the real $GT).
#
# Asserts: (1) a stale+CLEAN pool worktree (under <rig>/crew/worker-*) is reaped; (2) its
# orphan local branch is deleted IFF merged into origin/<default>; (3) an UNMERGED branch's
# worktree is reaped but the branch is KEPT (no data loss); (4) a DIRTY pool worktree is
# skipped (live WIP protected); (5) a FRESH worktree is kept (age gate).
#
# ZOMBIE-LOCK (wa-8y45): a worktree LOCKED by a stuck/ancient agent. Asserts a DEAD-pid lock
# and an ANCIENT+IDLE-pid lock are unlock+reaped; a YOUNG/ACTIVE-pid lock and an ANCIENT-but-
# BUSY lock are KEPT (never reap a live agent); .claude/worktrees + .gc-worktrees paths are
# covered; an UNPARSEABLE lock (no pid, no confirmed live session) is KEPT unless the tree itself proves
# safe (merged + clean + unused + aged → reaped, ga-vs6shu; see the LOCK CONTRACT in the reaper), and any
# verdict other than exactly 'unparseable' is KEPT; the SIGTERM guard kills a crew claude proc
# but never a supervisor/pilot; kill is default-OFF; the feature has a kill-switch + dry-run.
# Process probes are faked so it's hermetic. Exit 0 iff all hold.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER="$SELF_DIR/worktree-reaper.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# ga-vs6shu: every scenario below now potentially reaches classify_lock's new
# session-name path when a lock reason has no "pid N" phrase — without a fake
# seam it falls through to a REAL (if bounded) `gc session list` call, which
# is both slow (this whole suite would time out) and non-hermetic (depends on
# this machine's live city). Export an EMPTY fake session list as the default
# for every invocation below; a prefixed env var on any one `bash "$REAPER"`
# call overrides this for just that call (ordinary shell semantics), which is
# exactly how the dedicated live_session scenarios further down opt in to a
# non-empty fake list.
EMPTY_SESSIONS="$TMP/empty_sessions.json"
printf '{"sessions":[]}' > "$EMPTY_SESSIONS"
export WORKTREE_REAPER_FAKE_SESSION_LIST="$EMPTY_SESSIONS"

# ga-vs6shu gate-feedback (ga-wpdmj6, blocking issue 4): the same hermeticity, for DISK
# PRESSURE. The reaper drops nothing under pressure — it RAISES the age gate from
# STALE_HOURS to PRESSURE_HOURS (12h) whenever `df` shows < PRESSURE_FREE_GB (8) free on /,
# so on a box that is short of disk every scenario that ages a worktree 3h stops being
# reapable and its assertion fails (measured: 11 pre-existing + 7 ga-vs6shu assertions red at
# 7 GiB free) — the suite went red exactly when the reaper is needed, and the prod test
# (story-ga-vs6shu.sh step 5) runs this suite behind the deploy gate. Pin it OFF, the same
# way the session list is pinned, and UNCONDITIONALLY: an operator's exported value must not
# make the suite depend on the machine either. A scenario that wants pressure mode sets the
# variable on its own `bash "$REAPER"` call, which overrides this per call.
export WORKTREE_REAPER_PRESSURE_FREE_GB=0

# ── build a temp "town" ($TMP) containing one rig repo with an origin/main ───────
TOWN="$TMP/town"; mkdir -p "$TOWN"
REMOTE="$TMP/remote.git"; git init -q --bare "$REMOTE"
RIG="$TOWN/testrig"
git init -q -b main "$RIG"
( cd "$RIG"
  git remote add origin "$REMOTE"
  echo a > a.txt; git add a.txt; git commit -qm "base"
  git push -q origin main
  git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  # merged branch: points at main (no new commits → merged into origin/main)
  git branch crew/x/merged main
  # unmerged branch: one commit ahead of main (NOT merged)
  git branch crew/x/unmerged main
  git worktree add -q "$RIG/crew/worker-merged"   crew/x/merged
  git worktree add -q "$RIG/crew/worker-unmerged" crew/x/unmerged
  ( cd "$RIG/crew/worker-unmerged"; echo b > b.txt; git add b.txt; git commit -qm "ahead" )
  git worktree add -q "$RIG/crew/worker-dirty"    -b crew/x/dirty main
  ( cd "$RIG/crew/worker-dirty"; echo dirty > dirty.txt )   # uncommitted → dirty
  git worktree add -q "$RIG/crew/worker-fresh"    -b crew/x/fresh main
) >/dev/null 2>&1

# backdate the three "stale" worktrees to ~3h ago; leave -fresh at now
for w in worker-merged worker-unmerged worker-dirty; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG/crew/$w" 2>/dev/null || true
done

# ── run the reaper against the temp town, STALE_HOURS=1 ──────────────────────────
WORKTREE_REAPER_GT="$TOWN" \
WORKTREE_REAPER_LOG="$TMP/reaper.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 \
WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

# match by path SUFFIX — macOS mktemp gives /var/... but git reports the realpath
# /private/var/..., so an exact full-line compare false-negatives every worktree.
wt_exists()     { git -C "$RIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/$1\$" >/dev/null; }
branch_exists() { git -C "$RIG" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

echo "── ga-pdrij pool-worktree reaping ──"
wt_exists worker-merged   && bad "stale+clean merged worktree NOT reaped"        || ok "stale+clean merged pool worktree reaped"
branch_exists crew/x/merged   && bad "merged orphan branch NOT deleted"          || ok "merged orphan branch deleted (unblocks _filter_built)"
wt_exists worker-unmerged && bad "stale+clean unmerged worktree NOT reaped"      || ok "stale+clean unmerged pool worktree reaped"
branch_exists crew/x/unmerged && ok "UNMERGED branch KEPT (no data loss)"        || bad "unmerged branch wrongly deleted (DATA LOSS!)"
wt_exists worker-dirty    && bad "ga-xv78c: dirty worktree NOT reaped after preserve (disk never freed)" || ok "ga-xv78c: dirty worktree preserved+reaped (disk freed)"
branch_exists crew/x/dirty    && ok "dirty worktree's local branch kept"        || bad "dirty worktree's local branch wrongly deleted"
git -C "$REMOTE" rev-parse -q --verify refs/heads/crew/x/dirty >/dev/null 2>&1 \
  && ok "ga-xv78c: dirty WIP preserved to origin before reap (own branch name)" \
  || bad "ga-xv78c: dirty WIP LOST — not preserved to origin before reap!"
git -C "$REMOTE" show refs/heads/crew/x/dirty:dirty.txt 2>/dev/null | grep -x dirty >/dev/null \
  && ok "ga-xv78c: preserved commit contains the actual WIP content" \
  || bad "ga-xv78c: preserved ref exists but WIP content is wrong/missing"
wt_exists worker-fresh    && ok "fresh worktree KEPT (age gate)"                 || bad "fresh worktree wrongly reaped"

# ── ga-xv78c gate-feedback (fix-attempt 1 FAILED review): BOTH push attempts fail
# (origin unreachable) → the worktree must be left byte-for-byte as it was — still
# dirty — so the NEXT sweep's plain non-force `worktree remove` refuses it again
# too. Attempt 1 committed the WIP with a real `git commit` BEFORE either push was
# tried; when both failed it correctly returned "kept", but the tree was already
# git-CLEAN from that commit, so sweep 2's plain remove silently succeeded and
# deleted it, logging a routine reaped_pool event indistinguishable from an
# ordinary clean reap. This is the reviewer's exact live repro. No fixture in this
# suite exercised it before this addition.
echo "── ga-xv78c gate-feedback: both-pushes-fail leaves worktree dirty across sweeps ──"
UTOWN="$TMP/utown"; mkdir -p "$UTOWN"
URIG="$UTOWN/urig"; git init -q -b main "$URIG"
( cd "$URIG"
  # origin points at a path that is not a git repo at all → every push fails fast
  # and deterministically, no real network involved — a hermetic stand-in for
  # "origin unreachable" that can't flake or hang.
  git remote add origin "$TMP/no-such-remote.git"
  echo u > u.txt; git add u.txt; git commit -qm ubase
  git worktree add -q "$URIG/crew/worker-unreachable" -b crew/u/unreachable main
  ( cd "$URIG/crew/worker-unreachable"; echo wip > wip.txt )   # uncommitted → dirty
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$URIG/crew/worker-unreachable" 2>/dev/null || true

uwt() { git -C "$URIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-unreachable\$" >/dev/null; }
BEFORE_STATUS="$(git -C "$URIG/crew/worker-unreachable" status --porcelain 2>/dev/null)"

WORKTREE_REAPER_GT="$UTOWN" WORKTREE_REAPER_LOG="$TMP/reaperU1.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

uwt && ok "gate-feedback: both-pushes-fail worktree survives sweep 1 (not deleted)" \
     || bad "gate-feedback: worktree deleted on sweep 1 despite BOTH pushes failing — DATA LOSS!"
grep -q '"event":"preserve_failed_dirty_kept"' "$TMP/reaperU1.jsonl" 2>/dev/null \
  && ok "gate-feedback: preserve_failed_dirty_kept logged (distinguishable from a routine reap)" \
  || bad "gate-feedback: failure not logged — would be indistinguishable from a routine skip"

AFTER_STATUS="$(git -C "$URIG/crew/worker-unreachable" status --porcelain 2>/dev/null)"
[ "$BEFORE_STATUS" = "$AFTER_STATUS" ] \
  && ok "gate-feedback: worktree status BYTE-FOR-BYTE unchanged after failed preserve (no premature commit)" \
  || bad "gate-feedback: worktree status CHANGED after failed preserve — the exact fix-attempt-1 bug (silent commit before push confirmed)"

# sweep 2 against the SAME still-dirty worktree: attempt-1 would have silently
# reaped it here via the plain non-force path, since its earlier commit had
# already cleaned the tree. Our fix must still see it as dirty and refuse+retry.
WORKTREE_REAPER_GT="$UTOWN" WORKTREE_REAPER_LOG="$TMP/reaperU2.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

uwt && ok "gate-feedback: worktree ALSO survives sweep 2 (cross-sweep persistence)" \
     || bad "gate-feedback: worktree silently deleted on sweep 2 — the exact ga-xv78c attempt-1 regression!"
grep -q '"event":"reaped_pool".*worker-unreachable' "$TMP/reaperU2.jsonl" 2>/dev/null \
  && bad "gate-feedback: sweep 2 logged a ROUTINE reaped_pool for a preserve-failed tree — indistinguishable from an ordinary reap!" \
  || ok "gate-feedback: sweep 2 did NOT silently log it as a routine reap"
grep -q '"event":"preserve_failed_dirty_kept"' "$TMP/reaperU2.jsonl" 2>/dev/null \
  && ok "gate-feedback: sweep 2 retried preserve and logged the failure again (never silently skipped)" \
  || bad "gate-feedback: sweep 2 gave no signal at all"

# ── kill switch: ENABLED=0 → would_reap only, no mutation ────────────────────────
echo "── kill switch (ENABLED=0 = dry) ──"
git -C "$RIG" worktree add -q "$RIG/crew/worker-ks" -b crew/x/ks main >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG/crew/worker-ks" 2>/dev/null || true
WORKTREE_REAPER_GT="$TOWN" WORKTREE_REAPER_LOG="$TMP/reaper2.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=0 \
  bash "$REAPER" >/dev/null 2>&1
wt_exists worker-ks && ok "ENABLED=0: stale worktree NOT removed (dry-run)" || bad "ENABLED=0 still removed a worktree"
grep -q '"event":"would_reap_pool"' "$TMP/reaper2.jsonl" 2>/dev/null && ok "ENABLED=0: logged would_reap_pool intent" || bad "ENABLED=0: did not log dry intent"

# ── per-sweep CAP: 3 stale clean worktrees, cap=2 → exactly 2 reaped, 1 survives ──
echo "── per-sweep cap (ga-pdrij backlog drains gradually) ──"
RIG2="$TOWN/caprig"; git init -q -b main "$RIG2"
( cd "$RIG2"
  git remote add origin "$REMOTE"   # reuse the bare remote; push a separate ref
  echo c > c.txt; git add c.txt; git commit -qm capbase
  for n in 1 2 3; do git worktree add -q "$RIG2/crew/worker-cap$n" -b crew/c/cap$n main >/dev/null 2>&1; done
) >/dev/null 2>&1
for n in 1 2 3; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$RIG2/crew/worker-cap$n" 2>/dev/null || true
done
WORKTREE_REAPER_GT="$TOWN" WORKTREE_REAPER_LOG="$TMP/reaper3.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_MAX_PER_SWEEP=2 \
  bash "$REAPER" >/dev/null 2>&1
_capreaped=$(grep -c '"event":"reaped_pool".*caprig' "$TMP/reaper3.jsonl" 2>/dev/null || echo 0)
[ "$_capreaped" = "2" ] && ok "cap=2 reaped exactly 2 of 3 (capped)" || bad "cap=2 reaped $_capreaped (expected 2)"
_capsurv=$(git -C "$RIG2" worktree list --porcelain 2>/dev/null | grep -cE "^worktree .*/crew/worker-cap[0-9]\$")
[ "$_capsurv" = "1" ] && ok "1 capped worktree survives this sweep (drains next)" || bad "expected 1 survivor, got $_capsurv"
grep -q '"event":"pool_cap_hit"' "$TMP/reaper3.jsonl" 2>/dev/null && ok "cap-hit logged (no silent truncation)" || bad "cap-hit NOT logged"

# ══ ZOMBIE-LOCK reaping (wa-8y45): a worktree LOCKED by a stuck/ancient agent ══════
# Proves: (i) DEAD-pid lock → reap; (ii) ANCIENT+IDLE-pid lock → reap; (iii) YOUNG/ACTIVE
# -pid lock → KEEP (critical: never reap a live agent); (iii-b) ANCIENT-but-BUSY → KEEP;
# (iv) .claude/worktrees + .gc-worktrees path coverage; (v) UNPARSEABLE lock on UNMERGED work → KEEP
# (a merged+clean+aged+unused one is reaped instead — the ga-vs6shu scenarios below).
# Process probes are faked (WORKTREE_REAPER_FAKE_PS) so the suite is hermetic.
echo "── zombie-lock detection (wa-8y45) ──"
TOWNZ="$TMP/townz"; mkdir -p "$TOWNZ"
ZREMOTE="$TMP/zremote.git"; git init -q --bare "$ZREMOTE"
ZRIG="$TOWNZ/zrig"; git init -q -b main "$ZRIG"
( cd "$ZRIG"
  git remote add origin "$ZREMOTE"
  echo z > z.txt; git add z.txt; git commit -qm zbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  mkdir -p "$ZRIG/.claude/worktrees" "$ZRIG/.gc-worktrees"
  # (a) DEAD holder, crew branch merged into origin/main → reap + delete merged branch
  git branch crew/z/dead main
  git worktree add -q "$ZRIG/.claude/worktrees/agent-dead" crew/z/dead
  git worktree lock --reason "claude agent agent-dead pid 1001 start 2026-06-27T00:00:00" "$ZRIG/.claude/worktrees/agent-dead"
  # (b) ANCIENT+IDLE holder, NON-crew branch → reap worktree, KEEP branch (no data loss)
  git worktree add -q "$ZRIG/.claude/worktrees/agent-ancient" -b wa-ancient-sortfix main
  git worktree lock --reason "claude agent agent-ancient pid 1002 start 2026-06-26T00:00:00" "$ZRIG/.claude/worktrees/agent-ancient"
  # (c) YOUNG/ACTIVE holder → KEEP (never reap a live agent's tree)
  git worktree add -q "$ZRIG/.claude/worktrees/agent-young" -b crew/z/young main
  git worktree lock --reason "claude agent agent-young pid 1003 start now" "$ZRIG/.claude/worktrees/agent-young"
  # (d) ANCIENT but BUSY (recent CPU) holder → KEEP (not idle)
  git worktree add -q "$ZRIG/.claude/worktrees/agent-busy" -b crew/z/busy main
  git worktree lock --reason "claude agent agent-busy pid 1004 start old" "$ZRIG/.claude/worktrees/agent-busy"
  # (e) gate-review tree under .gc-worktrees, DEAD holder, detached → reap (path coverage)
  git worktree add -q --detach "$ZRIG/.gc-worktrees/zb-mainbase" main
  git worktree lock --reason "claude agent agent-gate pid 1005 start x" "$ZRIG/.gc-worktrees/zb-mainbase"
  # (f) UNPARSEABLE lock (no pid in reason) on a worktree with REAL unmerged
  # work → KEEP (fail-safe). ga-vs6shu's new safety net below must NEVER
  # reap a locked worktree that still has genuine, un-landed work just
  # because its lock text couldn't be understood — this is the important
  # negative case that fix must not break. (A branch left at main's tip with
  # zero commits would be trivially "merged" and WOULD now qualify for the
  # safety net — see scenario (j) further down for that case instead.)
  git worktree add -q "$ZRIG/.claude/worktrees/agent-noreason" -b crew/z/noreason main
  ( cd "$ZRIG/.claude/worktrees/agent-noreason"; echo real-work > real-work.txt; git add real-work.txt; git commit -qm "real unmerged work" )
  git worktree lock --reason "manual hold by human" "$ZRIG/.claude/worktrees/agent-noreason"
  # (g) UNLOCKED stale+clean under .claude/worktrees, crew merged → normal reap + branch del
  git branch crew/z/unlocked main
  git worktree add -q "$ZRIG/.claude/worktrees/agent-unlocked" crew/z/unlocked
  # (h) ga-xv78c: UNLOCKED + DIRTY under .claude/worktrees/agent-* (the exact reported
  # shape — subagent isolation:"worktree" trees). Own branch name is free on origin →
  # exercises the "push under familiar name" success path.
  git worktree add -q "$ZRIG/.claude/worktrees/agent-dirty" -b wa-agent-dirty-wip main
  ( cd "$ZRIG/.claude/worktrees/agent-dirty"; echo agentwip > wip.txt )   # uncommitted → dirty
  # (i) ga-xv78c: UNLOCKED + DIRTY, but the branch name is ALREADY TAKEN on origin by
  # UNRELATED history (orphan root commit, no common ancestor) → the reaper's own-name
  # push must non-fast-forward-reject, and it must fall back to
  # refs/reclaimed/<label>/<sha> rather than force-clobbering someone else's ref.
  git -C "$ZRIG" commit-tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904 -m "unrelated origin history" > "$TMP/collide_sha.txt"
  git -C "$ZRIG" push -q origin "$(cat "$TMP/collide_sha.txt"):refs/heads/wa-collide-wip" >/dev/null 2>&1
  git worktree add -q "$ZRIG/.claude/worktrees/agent-collide" -b wa-collide-wip main
  ( cd "$ZRIG/.claude/worktrees/agent-collide"; echo collidewip > collide.txt )   # uncommitted → dirty
) >/dev/null 2>&1

# backdate every zrig worktree past the age gate (dir mtime) — agent-young is OLD by dir-age
# yet must be KEPT because its HOLDER is young/active (proves holder-age, not dir-age, decides).
for w in agent-dead agent-ancient agent-young agent-busy agent-noreason agent-unlocked agent-dirty agent-collide; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$ZRIG/.claude/worktrees/$w" 2>/dev/null || true
done
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$ZRIG/.gc-worktrees/zb-mainbase" 2>/dev/null || true

# fake process table: "<pid> <alive|dead> <elapsed_secs> <cpu_x10>"  (thr: 48h=172800s, cpu<=50)
FAKEPS="$TMP/fakeps.txt"
{ echo "1001 dead 0 0"            # (a) dead                         → zombie
  echo "1002 alive 370000 3"      # (b) ~4.3d @ 0.3% → ancient+idle  → zombie
  echo "1003 alive 3600 250"      # (c) 1h @ 25%     → young+active  → LIVE
  echo "1004 alive 400000 850"    # (d) ~4.6d @ 85%  → ancient+BUSY  → LIVE
} > "$FAKEPS"                      # 1005 absent → probed as dead     → zombie

WORKTREE_REAPER_GT="$TOWNZ" WORKTREE_REAPER_LOG="$TMP/reaperZ.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_ZOMBIE_HOURS=48 WORKTREE_REAPER_ZOMBIE_MAX_CPU=5 \
WORKTREE_REAPER_FAKE_PS="$FAKEPS" \
  bash "$REAPER" >/dev/null 2>&1

zwt() { git -C "$ZRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/$1\$" >/dev/null; }
zbr() { git -C "$ZRIG" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

zwt ".claude/worktrees/agent-dead"     && bad "DEAD-locked worktree NOT reaped"                 || ok "DEAD-locked worktree reaped"
zbr crew/z/dead                        && bad "dead's merged crew branch NOT deleted"           || ok "dead's merged crew branch deleted"
zwt ".claude/worktrees/agent-ancient"  && bad "ANCIENT+IDLE-locked worktree NOT reaped"         || ok "ANCIENT+IDLE-locked worktree reaped"
zbr wa-ancient-sortfix                 && ok "ancient's NON-crew branch KEPT (no data loss)"    || bad "ancient's non-crew branch wrongly deleted"
zwt ".claude/worktrees/agent-young"    && ok "YOUNG/ACTIVE-locked worktree KEPT (never reap live agent)" || bad "YOUNG/ACTIVE worktree wrongly reaped — DESTROYS LIVE WORK!"
zwt ".claude/worktrees/agent-busy"     && ok "ANCIENT-but-BUSY-locked worktree KEPT (not idle)" || bad "busy worktree wrongly reaped"
zwt ".gc-worktrees/zb-mainbase"        && bad "gate-review DEAD-locked tree NOT reaped"         || ok "gate-review DEAD-locked tree reaped (.gc-worktrees coverage)"
zwt ".claude/worktrees/agent-noreason" && ok "UNPARSEABLE lock w/ real unmerged work KEPT (fail-safe)" || bad "unparseable lock wrongly reaped — DESTROYS UNMERGED WORK!"
grep -q '"event":"kept_locked_unparseable".*agent-noreason' "$TMP/reaperZ.jsonl" 2>/dev/null \
  && ok "ga-vs6shu: agent-noreason logged as kept_locked_unparseable — DISTINCT from a confirmed-live holder" \
  || bad "ga-vs6shu: agent-noreason not logged with the new distinct unparseable event (still collapsed into kept_locked_live?)"
zwt ".claude/worktrees/agent-unlocked" && bad "unlocked stale+clean .claude tree NOT reaped"    || ok "unlocked stale+clean .claude/worktrees tree reaped (path coverage)"
zbr crew/z/unlocked                    && bad "unlocked's merged crew branch NOT deleted"       || ok "unlocked's merged crew branch deleted"

# ── ga-xv78c: dirty + unlocked + aged under .claude/worktrees/agent-* — the exact
# reported failure shape. Old behavior left these stuck forever (dirty never
# self-clears); 94 leaked this way (5.9G, 5 crews) and broke the ITBI pipeline's
# SQLite at 95% disk. Must now be preserved to a durable ref, THEN reaped.
zwt ".claude/worktrees/agent-dirty"    && bad "ga-xv78c: dirty .claude/worktrees tree NOT reaped (disk never freed)" || ok "ga-xv78c: dirty .claude/worktrees tree preserved+reaped"
git -C "$ZREMOTE" rev-parse -q --verify refs/heads/wa-agent-dirty-wip >/dev/null 2>&1 \
  && ok "ga-xv78c: dirty WIP preserved to origin (own branch name free → used directly)" \
  || bad "ga-xv78c: dirty WIP LOST — own-name preserve path broken"
git -C "$ZREMOTE" show refs/heads/wa-agent-dirty-wip:wip.txt 2>/dev/null | grep -x agentwip >/dev/null \
  && ok "ga-xv78c: preserved own-name commit has the real WIP content" \
  || bad "ga-xv78c: preserved own-name ref exists but content is wrong/missing"
grep -q '"event":"reaped_dirty_preserved"' "$TMP/reaperZ.jsonl" 2>/dev/null && ok "reaped_dirty_preserved logged" || bad "reaped_dirty_preserved NOT logged"

# ── ga-xv78c: same, but the branch name collides with UNRELATED history already on
# origin → own-name push must non-fast-forward-reject, falling back to
# refs/reclaimed/<label>/<sha> WITHOUT clobbering the pre-existing unrelated ref.
zwt ".claude/worktrees/agent-collide"  && bad "ga-xv78c: colliding-name dirty tree NOT reaped" || ok "ga-xv78c: colliding-name dirty tree preserved+reaped (fallback path)"
[ "$(git -C "$ZREMOTE" rev-parse -q --verify refs/heads/wa-collide-wip 2>/dev/null)" = "$(cat "$TMP/collide_sha.txt" 2>/dev/null)" ] \
  && ok "ga-xv78c: pre-existing unrelated origin ref NOT clobbered (no force-push)" \
  || bad "ga-xv78c: collision ref was overwritten — unrelated history destroyed!"
git -C "$ZREMOTE" for-each-ref "refs/reclaimed/agent-collide/" --format='%(objectname)' 2>/dev/null | grep . >/dev/null \
  && ok "ga-xv78c: collision WIP preserved under refs/reclaimed/ fallback" \
  || bad "ga-xv78c: collision WIP LOST — refs/reclaimed/ fallback path broken"
grep -q '"event":"reaped_zombie_lock"' "$TMP/reaperZ.jsonl" 2>/dev/null && ok "reaped_zombie_lock logged" || bad "reaped_zombie_lock NOT logged"
grep -q '"event":"kept_locked_live"'   "$TMP/reaperZ.jsonl" 2>/dev/null && ok "kept_locked_live logged (live holder)" || bad "kept_locked_live NOT logged"

# ══ ga-vs6shu: the ACTUAL measured bug — unparseable lock + independently-safe
# worktree → reaped via the new safety net instead of kept forever ═══════════
# Real incident (25/09, ga-ormexj disk crisis): the reaper's classify_lock only
# ever understood a "pid N" phrase. The REAL reasons pool workers write name a
# SESSION instead ("wa-ho1ol build (wa-worker-adhoc-...)", "(no reason)", ...)
# — none matched, so EVERY one fell to "unparseable", which the call site then
# collapsed into the SAME kept_locked_live verdict as a genuinely-confirmed-
# alive holder. 51 real worktrees (2.3G) sat locked forever this way — ALL of
# them already 100% merged into main, clean, with no process anywhere near
# them, aged 72h to 1384h (57 days) — until a human removed them by hand to
# make room for the nightly backup. Proves: an unparseable-locked worktree
# that independently proves merged+clean+not-in-use+aged IS now reaped, its
# merged branch is cleaned up too, and the event is distinctly logged.
echo "── ga-vs6shu: unparseable lock + independently-safe worktree → reaped ──"
STOWN="$TMP/stown"; mkdir -p "$STOWN"
SREMOTE="$TMP/sremote.git"; git init -q --bare "$SREMOTE"
SRIG="$STOWN/srig"; git init -q -b main "$SRIG"
( cd "$SRIG"
  git remote add origin "$SREMOTE"
  echo s > s.txt; git add s.txt; git commit -qm sbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  mkdir -p "$SRIG/crew"
  # branch sits at main's tip (trivially merged, nothing has diverged) — the
  # exact shape of the 51 real stuck worktrees: locked, but with nothing left
  # to protect.
  git branch crew/s/safeunparse main
  git worktree add -q "$SRIG/crew/worker-safeunparse" crew/s/safeunparse
  # a REALISTIC reason, matching the empirically-observed live format (session
  # name in parens) — but that session does NOT exist in the (empty, by the
  # suite-wide default) fake session list, so it correctly resolves unparseable.
  git worktree lock --reason "wa-something build (wa-worker-adhoc-longgoneabc)" "$SRIG/crew/worker-safeunparse"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$SRIG/crew/worker-safeunparse" 2>/dev/null || true

WORKTREE_REAPER_GT="$STOWN" WORKTREE_REAPER_LOG="$TMP/reaperS.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

swt() { git -C "$SRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-safeunparse\$" >/dev/null; }
swt && bad "ga-vs6shu: unparseable+merged+clean+aged lock NOT reaped (the actual measured bug NOT fixed)" \
     || ok "ga-vs6shu: unparseable+merged+clean+aged lock REAPED via the new safety net (the 51-worktree leak, fixed)"
git -C "$SRIG" rev-parse --verify -q "refs/heads/crew/s/safeunparse" >/dev/null 2>&1 \
  && bad "ga-vs6shu: merged orphan branch NOT deleted after safety-net reap" \
  || ok "ga-vs6shu: merged orphan branch deleted after safety-net reap (unblocks re-dispatch too)"
grep -q '"event":"reaped_locked_unparseable_safe"' "$TMP/reaperS.jsonl" 2>/dev/null \
  && ok "ga-vs6shu: reaped_locked_unparseable_safe logged (distinguishable from a routine zombie reap or a routine unlocked reap)" \
  || bad "ga-vs6shu: safety-net reap not distinctly logged"

# ── same shape, but genuinely UNMERGED (real work ahead of main) → must stay
# KEPT even though the lock is just as unparseable. Proves the safety net
# checks REAL safety, not just "the lock text was unparseable" alone — the
# critical negative case (never lose real work because a lock's prose
# happened to be unreadable).
echo "── ga-vs6shu: unparseable lock + genuinely UNMERGED work → still kept ──"
UPTOWN="$TMP/uptown"; mkdir -p "$UPTOWN"
UPREMOTE="$TMP/upremote.git"; git init -q --bare "$UPREMOTE"
UPRIG="$UPTOWN/uprig"; git init -q -b main "$UPRIG"
( cd "$UPRIG"
  git remote add origin "$UPREMOTE"
  echo up > up.txt; git add up.txt; git commit -qm upbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  mkdir -p "$UPRIG/crew"
  git worktree add -q "$UPRIG/crew/worker-unparseunmerged" -b crew/up/unmerged main
  ( cd "$UPRIG/crew/worker-unparseunmerged"; echo real > real.txt; git add real.txt; git commit -qm "real unmerged work" )
  git worktree lock --reason "wa-other build (wa-worker-adhoc-stillgone99)" "$UPRIG/crew/worker-unparseunmerged"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$UPRIG/crew/worker-unparseunmerged" 2>/dev/null || true

WORKTREE_REAPER_GT="$UPTOWN" WORKTREE_REAPER_LOG="$TMP/reaperUP.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

upwt() { git -C "$UPRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-unparseunmerged\$" >/dev/null; }
upwt && ok "ga-vs6shu: unparseable+UNMERGED lock KEPT (never lose real work over an unreadable lock reason)" \
      || bad "ga-vs6shu: unparseable+unmerged worktree wrongly reaped — DATA LOSS!"
git -C "$UPRIG" rev-parse --verify -q "refs/heads/crew/up/unmerged" >/dev/null 2>&1 \
  && ok "ga-vs6shu: unmerged branch still present (nothing was ever removed)" \
  || bad "ga-vs6shu: unmerged branch is gone — should be impossible if the worktree itself was kept"

# ── live_session positive detection: a lock names a session that IS alive
# AND whose own work_dir is exactly this worktree → CONFIRMED live, kept, and
# logged with the live_session verdict (better diagnostics than falling all
# the way to "unparseable" for a genuinely still-building worktree).
echo "── ga-vs6shu: live_session positive detection (session alive, work_dir matches) ──"
LSTOWN="$TMP/lstown"; mkdir -p "$LSTOWN"
LSREMOTE="$TMP/lsremote.git"; git init -q --bare "$LSREMOTE"
LSRIG="$LSTOWN/lsrig"; git init -q -b main "$LSRIG"
( cd "$LSRIG"
  git remote add origin "$LSREMOTE"
  echo ls > ls.txt; git add ls.txt; git commit -qm lsbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  mkdir -p "$LSRIG/crew"
  git branch crew/ls/live main
  git worktree add -q "$LSRIG/crew/worker-livesession" crew/ls/live
  git worktree lock --reason "wa-live build (wa-worker-adhoc-imalivehere)" "$LSRIG/crew/worker-livesession"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$LSRIG/crew/worker-livesession" 2>/dev/null || true
LS_WT_PATH="$(cd "$LSRIG/crew/worker-livesession" && pwd -P)"
LS_SESSIONS="$TMP/ls_sessions.json"
jq -n --arg name "wa-worker-adhoc-imalivehere" --arg wd "$LS_WT_PATH" \
  '{"sessions":[{"name":$name,"session_name":$name,"work_dir":$wd,"closed":false}]}' > "$LS_SESSIONS"

WORKTREE_REAPER_GT="$LSTOWN" WORKTREE_REAPER_LOG="$TMP/reaperLS.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_SESSION_LIST="$LS_SESSIONS" \
  bash "$REAPER" >/dev/null 2>&1

lswt() { git -C "$LSRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-livesession\$" >/dev/null; }
lswt && ok "ga-vs6shu: live_session-confirmed worktree KEPT" || bad "ga-vs6shu: a session CONFIRMED alive and working here was wrongly reaped!"
grep -q '"event":"kept_locked_live".*live_session wa-worker-adhoc-imalivehere' "$TMP/reaperLS.jsonl" 2>/dev/null \
  && ok "ga-vs6shu: kept_locked_live logged with a live_session verdict (real diagnostic signal, not a guess)" \
  || bad "ga-vs6shu: live_session verdict not reflected in the log"

# ── pool-slot-reuse guard: the lock names a session that IS in the fake list
# and IS alive, but its work_dir points somewhere ELSE (the slot has since
# moved on to different work) → must NOT be trusted as "live for THIS lock" —
# falls through to unparseable, still correctly gated by the safety net.
# Without the work_dir check, a busy-but-unrelated persistent pool slot
# (gastown.dog-1, wa-worker-1, ...) would permanently block every stale lock
# it ever left behind, forever, just because the slot itself stays busy with
# newer, unrelated work.
echo "── ga-vs6shu: pool-slot-reuse guard (session alive elsewhere, not here) ──"
PSTOWN="$TMP/pstown"; mkdir -p "$PSTOWN"
PSREMOTE="$TMP/psremote.git"; git init -q --bare "$PSREMOTE"
PSRIG="$PSTOWN/psrig"; git init -q -b main "$PSRIG"
( cd "$PSRIG"
  git remote add origin "$PSREMOTE"
  echo ps > ps.txt; git add ps.txt; git commit -qm psbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  mkdir -p "$PSRIG/crew"
  git branch crew/ps/stale main
  git worktree add -q "$PSRIG/crew/worker-staleslot" crew/ps/stale
  git worktree lock --reason "gastown.dog-1/ga-someoldbead active fix 99999" "$PSRIG/crew/worker-staleslot"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$PSRIG/crew/worker-staleslot" 2>/dev/null || true
PS_SESSIONS="$TMP/ps_sessions.json"
# gastown.dog-1 IS alive — but working in a COMPLETELY different directory,
# simulating the slot having moved on to unrelated newer work.
jq -n --arg name "gastown.dog-1" --arg wd "$TMP/some/other/unrelated/dir" \
  '{"sessions":[{"name":$name,"session_name":$name,"work_dir":$wd,"closed":false}]}' > "$PS_SESSIONS"

WORKTREE_REAPER_GT="$PSTOWN" WORKTREE_REAPER_LOG="$TMP/reaperPS.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_SESSION_LIST="$PS_SESSIONS" \
  bash "$REAPER" >/dev/null 2>&1

pswt() { git -C "$PSRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-staleslot\$" >/dev/null; }
pswt && bad "ga-vs6shu: stale lock from a slot busy ELSEWHERE not reaped (pool-slot-reuse guard broken — permanently blocked)" \
      || ok "ga-vs6shu: stale lock from a slot busy elsewhere correctly reaped (name-alive alone is not enough — work_dir must match)"
grep -q '"event":"reaped_locked_unparseable_safe"' "$TMP/reaperPS.jsonl" 2>/dev/null \
  && ok "ga-vs6shu: pool-slot-reuse case went through the SAFE unparseable path, not a false live_session match" \
  || bad "ga-vs6shu: pool-slot-reuse case did not take the expected safety-net path"

# ── loop-1 (legacy path-glob) coverage: the same safety net must fire for a
# LOCKED worktree found by the flat/nested .gc-worktrees scan too, not only
# via reap_pool_worktrees's `git worktree list` enumeration — the two loops
# share _reap_or_log_unparseable_lock, but each has its OWN call-site wiring
# that could independently drift.
echo "── ga-vs6shu: loop-1 (legacy path-glob) unparseable-safe reap coverage ──"
L1TOWN="$TMP/l1town"; mkdir -p "$L1TOWN/.gc-worktrees"
L1REMOTE="$TMP/l1remote.git"; git init -q --bare "$L1REMOTE"
git init -q -b main "$L1TOWN"
( cd "$L1TOWN"
  git remote add origin "$L1REMOTE"
  echo l1 > l1.txt; git add l1.txt; git commit -qm l1base
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git branch w/l1safe main
  git worktree add -q "$L1TOWN/.gc-worktrees/l1-safeunparse" w/l1safe
  git worktree lock --reason "wa-l1 build (wa-worker-adhoc-l1longgone)" "$L1TOWN/.gc-worktrees/l1-safeunparse"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$L1TOWN/.gc-worktrees/l1-safeunparse" 2>/dev/null || true

WORKTREE_REAPER_GT="$L1TOWN" WORKTREE_REAPER_LOG="$TMP/reaperL1.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

git -C "$L1TOWN" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/\.gc-worktrees/l1-safeunparse\$" >/dev/null \
  && bad "ga-vs6shu: loop-1 unparseable+safe lock NOT reaped (call-site wiring drifted from loop 2)" \
  || ok "ga-vs6shu: loop-1 (legacy path-glob) also reaps an unparseable+safe lock via the same safety net"

# ══ ga-vs6shu GATE FEEDBACK (ga-wpdmj6): the third state, the memo, the log, the bare lock ══
# Everything above drives the reaper through WORKTREE_REAPER_FAKE_SESSION_LIST, which can only
# ever say "the list was fetched". The gate's blocking issues 1+2 live in the REAL fetch path
# (gc missing / failing / timing out / printing garbage, and how many times it is called), so
# these scenarios put a FAKE `gc` on PATH instead — same code path as production, counting calls.
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gc" <<'FAKEGC'
#!/bin/sh
echo "$*" >> "${FAKE_GC_LOG:-/dev/null}"
case "${FAKE_GC_MODE:-ok}" in
  ok)    printf '{"ok":true,"sessions":[]}' ;;
  notok) printf '{"ok":false,"sessions":[]}' ;;
  fail)  exit 1 ;;
  hang)  exec sleep 30 ;;   # exec: the shell must BE the sleep, or `timeout` kills the shell and the orphan holds the pipe
  stubborn) trap '' TERM; i=0; while [ "$i" -lt 12 ]; do sleep 1; i=$((i+1)); done ;;   # ignores TERM (finite: 12s)
  empty) exit 0 ;;
  brace) printf '{}' ;;
esac
FAKEGC
chmod +x "$FAKEBIN/gc"

# mk_locked_rig <name> <n> <reason-template> — a town $TMP/<name> holding one rig with
# crew/worker-1..n, each on a branch already MERGED into origin/main, CLEAN, aged 3h, and
# LOCKED with <reason-template> (@N@ = the worker number; the literal @BARE@ = a lock with
# no --reason at all). Every one is exactly the shape ga-vs6shu is allowed to reap.
mk_locked_rig() {
  local name="$1" n="$2" tmpl="$3" root i
  root="$TMP/$name"; mkdir -p "$root"
  git init -q --bare "$root/remote.git"
  git init -q -b main "$root/rig"
  ( cd "$root/rig" || exit 1
    git remote add origin "$root/remote.git"
    echo x > x.txt; git add x.txt; git commit -qm base
    git push -q origin main; git fetch -q origin
    git remote set-head origin main 2>/dev/null || true
    mkdir -p crew
    for i in $(seq 1 "$n"); do
      git branch "crew/$name/b$i" main
      git worktree add -q "crew/worker-$i" "crew/$name/b$i"
      if [ "$tmpl" = "@BARE@" ]; then git worktree lock "crew/worker-$i"
      else git worktree lock --reason "${tmpl//@N@/$i}" "crew/worker-$i"; fi
    done
  ) >/dev/null 2>&1
  for i in $(seq 1 "$n"); do
    touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$root/rig/crew/worker-$i" 2>/dev/null || true
  done
}
# count_wt <name> — how many crew/worker-* worktrees the rig still has registered.
count_wt() { git -C "$TMP/$1/rig" worktree list --porcelain 2>/dev/null | grep -c '/crew/worker-'; }
# run_fakegc <name> <mode> [ENV=val ...] — run the reaper on town <name> with the fake gc in
# <mode>; the real seam is unset so the REAL fetch path runs. Log → $TMP/<name>.jsonl,
# gc call log → $TMP/<name>.gc.
run_fakegc() {
  local name="$1" mode="$2"; shift 2
  : > "$TMP/$name.gc"
  env -u WORKTREE_REAPER_FAKE_SESSION_LIST PATH="$FAKEBIN:$PATH" \
    FAKE_GC_LOG="$TMP/$name.gc" FAKE_GC_MODE="$mode" \
    WORKTREE_REAPER_GT="$TMP/$name" WORKTREE_REAPER_LOG="$TMP/$name.jsonl" \
    WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_SESSION_LIST_TIMEOUT=2 \
    "$@" bash "$REAPER" >/dev/null 2>&1
}
gc_calls() { wc -l < "$TMP/$1.gc" | tr -d ' '; }
events()   { local n; n="$(grep -c "\"event\":\"$2\"" "$TMP/$1.jsonl" 2>/dev/null)"; echo "${n:-0}"; }

# ── issue 2 (memo) + happy path: 3 locked worktrees, gc healthy → ONE gc call, all reaped.
# Pre-fix, `classify_lock` ran in a subshell so its "memo" died with it: each locked worktree
# paid TWO fetches (reap_zombie_locked, then _reap_or_log_unparseable_lock) = 6 calls here.
echo "── ga-vs6shu gate-feedback: ONE session-list fetch per sweep, not per lock ──"
mk_locked_rig memo 3 'wa-x build (wa-worker-adhoc-gone@N@)'
run_fakegc memo ok
[ "$(count_wt memo)" = "0" ] && ok "3 locked+merged+clean+aged worktrees reaped when gc answers (unparseable-safe path still works)" \
                             || bad "healthy-gc sweep left $(count_wt memo) of 3 locked worktrees"
[ "$(gc_calls memo)" = "1" ] && ok "issue 2: 3 locked worktrees → exactly 1 'gc session list' call (memo shared across the classify subshell)" \
                             || bad "issue 2: expected 1 gc call for 3 locked worktrees, saw $(gc_calls memo) — memo lost in the classify_lock subshell"
[ "$(events memo session_list_unavailable)" = "0" ] && grep -q '"session_list":"ok"' "$TMP/memo.jsonl" \
  && ok "healthy fetch is reported: sweep line says session_list=ok, no session_list_unavailable event" \
  || bad "healthy fetch not reported as session_list=ok / spurious session_list_unavailable event"

# ── issue 1 (third state): every way the fetch can fail must KEEP the worktree, log a distinct
# counted event, and never take the destructive safety-net path. The worktrees are IDENTICAL
# to the ones reaped above — merged, clean, aged, no process — so the ONLY thing that differs
# is whether we could find out about live sessions. Pre-fix: `{}` == "nobody alive" → REAPED.
echo "── ga-vs6shu gate-feedback: session list UNAVAILABLE ≠ 'no session alive' (KEEP + distinct event) ──"
for spec in fail:gc_failed hang:timeout stubborn:timeout empty:invalid_output brace:invalid_output notok:invalid_output; do
  mode="${spec%%:*}"; why="${spec##*:}"
  mk_locked_rig "un_$mode" 2 'wa-x build (wa-worker-adhoc-held@N@)'
  run_fakegc "un_$mode" "$mode" WORKTREE_REAPER_SESSION_LIST_TIMEOUT=1
  [ "$(count_wt "un_$mode")" = "2" ] && ok "gc mode '$mode': both locked worktrees KEPT (could-not-know is not 'nobody alive')" \
                                     || bad "gc mode '$mode': $((2 - $(count_wt "un_$mode"))) locked worktree(s) REAPED on an unavailable session list — DESTROYS A POSSIBLY-LIVE SESSION'S TREE"
  [ "$(events "un_$mode" reaped_locked_unparseable_safe)" = "0" ] \
    || bad "gc mode '$mode': safety-net reap event logged although the list was unavailable"
  [ "$(events "un_$mode" kept_locked_session_list_unavailable)" = "2" ] && ok "gc mode '$mode': 2× kept_locked_session_list_unavailable (distinct from kept_locked_unparseable / kept_locked_live)" \
                                                                        || bad "gc mode '$mode': expected 2 kept_locked_session_list_unavailable events, saw $(events "un_$mode" kept_locked_session_list_unavailable)"
  grep -q "\"event\":\"session_list_unavailable\",\"rc\":[0-9]*,\"why\":\"$why\"" "$TMP/un_$mode.jsonl" \
    && ok "gc mode '$mode': one session_list_unavailable event carries the cause (why=$why)" \
    || bad "gc mode '$mode': no session_list_unavailable event with why=$why"
  grep -q '"session_list":"unavailable","kept_session_list_unavailable":2' "$TMP/un_$mode.jsonl" \
    && ok "gc mode '$mode': sweep line COUNTS it (session_list=unavailable, kept_session_list_unavailable=2)" \
    || bad "gc mode '$mode': sweep line does not count the unavailable-list keeps"
  [ "$(gc_calls "un_$mode")" = "1" ] || bad "gc mode '$mode': a failed fetch was retried per lock ($(gc_calls "un_$mode") calls) instead of memoized"
done
# …and "kept" is not "kept forever": the next sweep, with gc healthy again, reaps them.
run_fakegc un_fail ok
[ "$(count_wt un_fail)" = "0" ] && ok "next sweep with gc healthy again reaps what the unavailable sweep kept (nothing stuck)" \
                                || bad "worktrees kept during a gc outage are not reaped once gc recovers"

# ── a bare lock (no --reason at all) is "(no reason)" in BOTH loops, and reaped when safe.
echo "── ga-vs6shu gate-feedback: bare lock (no reason) — pool loop AND legacy loop-1 ──"
mk_locked_rig bare 1 '@BARE@'
run_fakegc bare ok
[ "$(count_wt bare)" = "0" ] && ok "pool loop: bare lock reaped via the safety net" || bad "pool loop: bare lock (no reason) NOT reaped"
L1BTOWN="$TMP/l1btown"; mkdir -p "$L1BTOWN/.gc-worktrees"
git init -q --bare "$TMP/l1bremote.git"; git init -q -b main "$L1BTOWN"
( cd "$L1BTOWN"
  git remote add origin "$TMP/l1bremote.git"
  echo b > b.txt; git add b.txt; git commit -qm b
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git branch w/l1bare main
  git worktree add -q "$L1BTOWN/.gc-worktrees/l1-bare" w/l1bare
  git worktree lock "$L1BTOWN/.gc-worktrees/l1-bare"
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$L1BTOWN/.gc-worktrees/l1-bare" 2>/dev/null || true
WORKTREE_REAPER_GT="$L1BTOWN" WORKTREE_REAPER_LOG="$TMP/l1b.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 bash "$REAPER" >/dev/null 2>&1
git -C "$L1BTOWN" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/\.gc-worktrees/l1-bare\$" >/dev/null \
  && bad "loop-1: a BARE lock is silently skipped (lock_reason='' failed the -n test) while the pool loop reaps the same shape" \
  || ok "loop-1 (legacy path-glob): bare lock reaped too — both loops now agree on '(no reason)'"

# ── issue 3 (log escaping): a lock reason with quotes + a backslash arrives from
# `git worktree list --porcelain` C-quoted; every event that carries it must stay valid JSON.
# Worker-1 is merged+clean → reaped_locked_unparseable_safe; worker-2 has real unmerged work →
# kept_locked_unparseable (the event emitted for every kept lock on every sweep).
echo "── ga-vs6shu gate-feedback: free-text lock reason cannot break the JSON log ──"
mk_locked_rig esc 2 'fix "quoted" thing \ back @N@'
( cd "$TMP/esc/rig/crew/worker-2" && echo real > real.txt && git add real.txt && git commit -qm "real unmerged work" ) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$TMP/esc/rig/crew/worker-2" 2>/dev/null || true
run_fakegc esc ok
jq -e . "$TMP/esc.jsonl" >/dev/null 2>&1 \
  && ok "issue 3: EVERY line of the log parses as JSON with a quote+backslash lock reason (jq -e . over the file)" \
  || bad "issue 3: the log is not valid JSON — a lock reason with quotes/backslash poisoned it (jq: $(jq -e . "$TMP/esc.jsonl" 2>&1 >/dev/null | head -1))"
[ "$(events esc reaped_locked_unparseable_safe)" = "1" ] && [ "$(events esc kept_locked_unparseable)" = "1" ] \
  && ok "both free-text events were emitted (1 reaped_locked_unparseable_safe, 1 kept_locked_unparseable)" \
  || bad "expected 1 reaped_locked_unparseable_safe + 1 kept_locked_unparseable, saw $(events esc reaped_locked_unparseable_safe)/$(events esc kept_locked_unparseable)"
jq -r 'select(.event=="kept_locked_unparseable") | .reason' "$TMP/esc.jsonl" 2>/dev/null | grep -q 'quoted' \
  && ok "the logged reason round-trips (still readable, still mentions the original text)" \
  || bad "the logged reason did not round-trip through JSON"

# ── low finding: `for tok in $(…)` glob-expanded a token like `*` against the reaper's cwd.
# A reason of `*`, a cwd holding a file NAMED like a live session for this worktree: glob
# expansion would turn `*` into that session name → "confirmed live" → kept forever. Literal
# `*` names no session, so the (merged+clean+aged) worktree is reaped.
echo "── ga-vs6shu gate-feedback: a '*' token in a lock reason is not glob-expanded ──"
mk_locked_rig glob 1 '*'
GLOBCWD="$TMP/globcwd"; mkdir -p "$GLOBCWD"; : > "$GLOBCWD/wa-worker-adhoc-globbed"
GLOB_WT="$(cd "$TMP/glob/rig/crew/worker-1" && pwd -P)"
GLOB_SESSIONS="$TMP/glob_sessions.json"
jq -n --arg name "wa-worker-adhoc-globbed" --arg wd "$GLOB_WT" \
  '{"sessions":[{"name":$name,"session_name":$name,"work_dir":$wd,"closed":false}]}' > "$GLOB_SESSIONS"
( cd "$GLOBCWD" && WORKTREE_REAPER_GT="$TMP/glob" WORKTREE_REAPER_LOG="$TMP/glob.jsonl" \
  WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_FAKE_SESSION_LIST="$GLOB_SESSIONS" \
  bash "$REAPER" >/dev/null 2>&1 )
[ "$(count_wt glob)" = "0" ] && ok "'*' in a lock reason stays a literal token (not expanded to the cwd's filenames)" \
                             || bad "'*' in a lock reason was glob-expanded against the cwd → matched a live session name it never contained"

# ── low finding: the safety-net reap must not `worktree unlock` before `remove -f -f`. With no
# unlock, a remove that fails cannot leave the worktree stripped of a lock whose holder was never
# identified. (Source-level: a forced remove FAILURE cannot be staged hermetically — git
# deregisters the worktree even when the on-disk delete only half-succeeds.)
if sed -n '/^_reap_or_log_unparseable_lock() {/,/^}/p' "$REAPER" | grep -v '^[[:space:]]*#' | grep -q 'worktree unlock'; then
  bad "_reap_or_log_unparseable_lock unlocks BEFORE remove -f -f — a failed remove leaves an unidentified holder's worktree unlocked"
else
  ok "_reap_or_log_unparseable_lock removes with -f -f and never unlocks first (a failed remove leaves the lock as found)"
fi

# ══ ga-vs6shu GATE FEEDBACK 2 (ga-x7lbcr): the default arm, the kill grace, and a stale-contract guard ══
# The reviewer's blocking issue was comment-only (four comments still stated the OLD lock contract), but its
# non-blocking findings were real, and the same class — an unrecognised outcome read as a known one — is asked
# of the code too: only the EXACT verdict "unparseable" may reach the destructive independent-proof path.
echo ""
echo "── ga-vs6shu gate-feedback 2: only the exact 'unparseable' verdict may reach the safety net ──"
# Unit level, against the REAL functions (awk-extracted from the reaper — it runs on source, so it cannot be sourced):
# _reap_or_log_unparseable_lock is called directly with verdicts the classifier is not supposed to produce, or does
# not produce because it was killed inside its `$(...)` (empty). The worktree is the exact shape the safety net DOES
# reap (locked, merged, clean, aged 3h, no process cwd) — so a keep can only come from the verdict handling itself.
extract_reaper_fn() { awk -v n="$1" '$0 ~ "^" n "\\(\\)" {f=1} f{print} f&&/^}$/{exit}' "$REAPER"; }
UV_FNS=""
for _f in _json_esc _log_lock_event _worktree_head_merged _worktree_in_use delete_merged_local_branch _reap_or_log_unparseable_lock; do
  _body="$(extract_reaper_fn "$_f")"
  [ -n "$_body" ] || { echo "FATAL: $_f() not found in $REAPER (extraction pattern drifted)" >&2; exit 2; }
  UV_FNS="$UV_FNS
$_body"
done
UV_SCRIPT="$TMP/uv_sandbox.sh"
{
  echo 'set -uo pipefail'
  cat <<'EOS_HEAD'
LOG="$UV_LOG"; ENABLED=1; gate_hours=1; kept_session_list_unavailable=0; branches_deleted=0
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
EOS_HEAD
  echo "$UV_FNS"
  cat <<'EOS_BODY'
if [ "$UV_VERDICT" = "@CLASSIFY_EMPTY@" ]; then
  # A classifier killed inside its `$(...)` prints nothing: the caller has no verdict to pass, so the function
  # classifies for itself and gets an EMPTY string back.
  classify_lock() { :; }
  _session_list_ensure() { :; }
  _reap_or_log_unparseable_lock "$UV_REPO" "$UV_WT" crew/uv/b1 'wa-x build' 3 pool
else
  _reap_or_log_unparseable_lock "$UV_REPO" "$UV_WT" crew/uv/b1 'wa-x build' 3 pool "$UV_VERDICT"
fi
echo "rc=$?"
EOS_BODY
} > "$UV_SCRIPT"
: > "$TMP/uv_no_lsof.txt"
uv_events() { local n; n="$(grep -c "\"event\":\"$2\"" "$TMP/$1.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
run_uv() { # run_uv <town-name> <verdict> -> the function's exit code ("rc=N"); log -> $TMP/<town-name>.jsonl
  local name="$1" verdict="$2" rig wt
  rig="$(cd "$TMP/$name/rig" && pwd -P)"; wt="$(cd "$TMP/$name/rig/crew/worker-1" && pwd -P)"
  : > "$TMP/$name.jsonl"
  UV_LOG="$TMP/$name.jsonl" UV_REPO="$rig" UV_WT="$wt" UV_VERDICT="$verdict" \
    WORKTREE_REAPER_FAKE_LSOF="$TMP/uv_no_lsof.txt" /bin/bash "$UV_SCRIPT" 2>/dev/null | tail -1
}
# positive control FIRST: the very same fixture IS reaped for the one verdict the safety net accepts, so the keeps
# below cannot be the fixture failing some other proof (merged/clean/aged/in-use).
mk_locked_rig uv_ctl 1 'wa-x build (wa-worker-adhoc-held@N@)'
[ "$(run_uv uv_ctl unparseable)" = "rc=0" ] && [ "$(count_wt uv_ctl)" = "0" ] \
  && ok "control: verdict 'unparseable' + a merged+clean+aged+unused tree → the safety net reaps it (the fixture is reapable)" \
  || bad "control: the fixture was NOT reaped for verdict 'unparseable' — the keep assertions below would prove nothing"
for spec in "garbage:garbage" "zombie:zombie 42 dead" "empty:@CLASSIFY_EMPTY@"; do
  tag="${spec%%:*}"; verdict="${spec#*:}"
  mk_locked_rig "uv_$tag" 1 'wa-x build (wa-worker-adhoc-held@N@)'
  rc="$(run_uv "uv_$tag" "$verdict")"
  [ "$rc" = "rc=1" ] && [ "$(count_wt "uv_$tag")" = "1" ] \
    && ok "verdict '$verdict' (not exactly 'unparseable') → the worktree is KEPT even though it is merged+clean+aged+unused" \
    || bad "verdict '$verdict' reached the destructive path: $rc, worktrees left: $(count_wt "uv_$tag") (expected rc=1, 1 kept)"
  [ "$(uv_events "uv_$tag" reaped_locked_unparseable_safe)" = "0" ] \
    || bad "verdict '$verdict': a reaped_locked_unparseable_safe event was logged for a verdict the safety net must not accept"
  [ "$(uv_events "uv_$tag" kept_locked_unrecognized_verdict)" = "1" ] \
    && ok "verdict '$verdict' → one distinct kept_locked_unrecognized_verdict event (not folded into kept_locked_unparseable)" \
    || bad "verdict '$verdict' → expected 1 kept_locked_unrecognized_verdict event, saw $(uv_events "uv_$tag" kept_locked_unrecognized_verdict)"
  jq -e . "$TMP/uv_$tag.jsonl" >/dev/null 2>&1 \
    && ok "verdict '$verdict' → the event line is valid JSON" \
    || bad "verdict '$verdict' → the log line is not valid JSON: $(head -c 200 "$TMP/uv_$tag.jsonl")"
done

# ... an "unknown <cause>" verdict is NOT this arm: it already has its own KEEP + event, and must keep it.
mk_locked_rig uv_unk 1 'wa-x build (wa-worker-adhoc-held@N@)'
rc="$(run_uv uv_unk "unknown some_other_cause")"
[ "$rc" = "rc=1" ] && [ "$(count_wt uv_unk)" = "1" ] && [ "$(uv_events uv_unk kept_locked_unknown)" = "1" ] \
  && ok "verdict 'unknown <cause>' → KEPT with its own kept_locked_unknown event (the new default arm did not swallow it)" \
  || bad "verdict 'unknown <cause>' → expected rc=1, 1 kept, 1 kept_locked_unknown; got $rc, kept $(count_wt uv_unk), events $(uv_events uv_unk kept_locked_unknown)"

# ── the timeout kill grace: `timeout N gc ...` alone leaves a gc that ignores TERM holding the sweep past its bound.
echo "── ga-vs6shu gate-feedback 2: the session-list fetch is killed after a grace (timeout -k) ──"
REAL_TIMEOUT="$(command -v timeout)"
if [ -z "$REAL_TIMEOUT" ]; then
  ok "no timeout(1) on this machine — the kill-grace check does not apply (the reaper keeps every lock without it)"
else
  FAKETO="$TMP/faketo"; mkdir -p "$FAKETO"
  cat > "$FAKETO/timeout" <<EOTO
#!/bin/sh
echo "\$*" >> "$TMP/timeout.args"
exec "$REAL_TIMEOUT" "\$@"
EOTO
  chmod +x "$FAKETO/timeout"
  mk_locked_rig kg 1 'wa-x build (wa-worker-adhoc-gone@N@)'
  : > "$TMP/timeout.args"
  run_fakegc kg ok PATH="$FAKETO:$FAKEBIN:$PATH"
  grep -E '^(-k|--kill-after)[ =][0-9]+ [0-9]+ gc ' "$TMP/timeout.args" >/dev/null 2>&1 \
    && ok "the gc fetch runs as 'timeout -k <grace> <bound> gc ...' (a gc that ignores TERM is KILLed, not waited for)" \
    || bad "the gc fetch has no kill grace — got: $(head -c 200 "$TMP/timeout.args")"
fi

# ── the comments must not still state the OLD contract (gate ga-x7lbcr, blocking issue 1). The code lets a lock
# whose holder is not a pid-confirmed zombie be reaped when the tree independently proves safe, so a comment that
# says "reap ONLY if zombie" / "ALWAYS kept" / "caller KEEPS" is a false absolute the next maintainer builds on.
echo "── ga-vs6shu gate-feedback 2: no comment states the pre-ga-vs6shu lock contract ──"
for _stale in 'reap ONLY if the lock holder is a ZOMBIE' \
              'is ALWAYS kept' \
              'reap ONLY if the holder is a zombie, else keep' \
              'NOT-a-zombie (caller KEEPS)' \
              "NOT a zombie → the worktree is KEPT"; do
  if grep -qF -- "$_stale" "$REAPER"; then
    bad "stale contract text is still in worktree-reaper.sh: '$_stale' (a lock is no longer 'only reaped if a zombie' / 'always kept')"
  else
    ok "no comment says '$_stale'"
  fi
done

# ── zombie SIGTERM guard: kill a crew claude agent, NEVER a supervisor/pilot ──────
echo "── zombie kill guard (guarded when ON) ──"
KTOWN="$TMP/ktown"; mkdir -p "$KTOWN"; KRIG="$KTOWN/krig"; git init -q -b main "$KRIG"
( cd "$KRIG"; echo k>k.txt; git add k.txt; git commit -qm kbase; mkdir -p "$KRIG/.claude/worktrees"
  git worktree add -q "$KRIG/.claude/worktrees/agent-crew"  -b crew/k/crew  main
  git worktree lock --reason "claude agent agent-crew pid 2001 start x" "$KRIG/.claude/worktrees/agent-crew"
  git worktree add -q "$KRIG/.claude/worktrees/agent-super" -b crew/k/super main
  git worktree lock --reason "claude agent agent-super pid 2002 start x" "$KRIG/.claude/worktrees/agent-super"
) >/dev/null 2>&1
for w in agent-crew agent-super; do
  touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$KRIG/.claude/worktrees/$w" 2>/dev/null || true
done
KFAKEPS="$TMP/kfakeps.txt"; { echo "2001 alive 400000 2"; echo "2002 alive 400000 2"; } > "$KFAKEPS"  # both ancient+idle=zombie
KCMD="$TMP/kcmd.txt"
{ echo "2001 /Users/athos/.local/bin/claude --agent agent-crew wa-worker build"
  echo "2002 /Users/athos/.local/bin/claude pilot-dispatcher.sh supervisor"; } > "$KCMD"
KSINK="$TMP/ksink.txt"; : > "$KSINK"
WORKTREE_REAPER_GT="$KTOWN" WORKTREE_REAPER_LOG="$TMP/reaperK.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_PS="$KFAKEPS" WORKTREE_REAPER_FAKE_CMDLINE="$KCMD" \
WORKTREE_REAPER_KILL_ZOMBIE=1 WORKTREE_REAPER_KILL_SINK="$KSINK" \
  bash "$REAPER" >/dev/null 2>&1
grep -qx 2001 "$KSINK" 2>/dev/null && ok "crew claude zombie SIGTERM'd (kill enabled)"      || bad "crew claude zombie NOT killed"
grep -qx 2002 "$KSINK" 2>/dev/null && bad "SUPERVISOR/pilot wrongly SIGTERM'd (guard FAILED!)" || ok "supervisor/pilot process NOT killed (guard holds)"
grep -q '"event":"kill_skipped_protected"' "$TMP/reaperK.jsonl" 2>/dev/null && ok "protected-kill-skip logged" || bad "protected kill-skip NOT logged"

# ── kill DEFAULT-OFF: zombie reaped, but process NEVER signaled ───────────────────
echo "── zombie kill default-OFF ──"
DTOWN="$TMP/dtown"; mkdir -p "$DTOWN"; DRIG="$DTOWN/drig"; git init -q -b main "$DRIG"
( cd "$DRIG"; echo d>d.txt; git add d.txt; git commit -qm dbase; mkdir -p "$DRIG/.claude/worktrees"
  git worktree add -q "$DRIG/.claude/worktrees/agent-d" -b crew/d/d main
  git worktree lock --reason "claude agent agent-d pid 3001 start x" "$DRIG/.claude/worktrees/agent-d" ) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$DRIG/.claude/worktrees/agent-d" 2>/dev/null || true
DFAKEPS="$TMP/dfakeps.txt"; echo "3001 alive 400000 2" > "$DFAKEPS"
DCMD="$TMP/dcmd.txt"; echo "3001 /Users/athos/.local/bin/claude --agent agent-d build" > "$DCMD"
DSINK="$TMP/dsink.txt"; : > "$DSINK"
WORKTREE_REAPER_GT="$DTOWN" WORKTREE_REAPER_LOG="$TMP/reaperD.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_PS="$DFAKEPS" WORKTREE_REAPER_FAKE_CMDLINE="$DCMD" \
WORKTREE_REAPER_KILL_SINK="$DSINK" \
  bash "$REAPER" >/dev/null 2>&1
[ -s "$DSINK" ] && bad "KILL default-OFF but a pid was signaled" || ok "KILL default-OFF: process NOT signaled"
git -C "$DRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/.claude/worktrees/agent-d\$" >/dev/null \
  && bad "kill-off: zombie worktree NOT reaped" || ok "kill-off: zombie worktree still reaped (kill is orthogonal)"

# ── feature kill-switch: ZOMBIE_LOCK_ENABLED=0 → ALL locked trees skipped (old behavior) ─
echo "── zombie feature kill-switch (ZOMBIE_LOCK_ENABLED=0) ──"
OTOWN="$TMP/otown"; mkdir -p "$OTOWN"; ORIG="$OTOWN/orig"; git init -q -b main "$ORIG"
( cd "$ORIG"; echo o>o.txt; git add o.txt; git commit -qm obase; mkdir -p "$ORIG/.claude/worktrees"
  git worktree add -q "$ORIG/.claude/worktrees/agent-o" -b crew/o/o main
  git worktree lock --reason "claude agent agent-o pid 4001 start x" "$ORIG/.claude/worktrees/agent-o" ) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$ORIG/.claude/worktrees/agent-o" 2>/dev/null || true
OFAKEPS="$TMP/ofakeps.txt"; echo "4001 dead 0 0" > "$OFAKEPS"
WORKTREE_REAPER_GT="$OTOWN" WORKTREE_REAPER_LOG="$TMP/reaperO.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_ZOMBIE_LOCK_ENABLED=0 WORKTREE_REAPER_FAKE_PS="$OFAKEPS" \
  bash "$REAPER" >/dev/null 2>&1
git -C "$ORIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/.claude/worktrees/agent-o\$" >/dev/null \
  && ok "ZOMBIE_LOCK_ENABLED=0: dead-locked tree KEPT (old behavior preserved)" || bad "ZOMBIE_LOCK_ENABLED=0 still reaped a locked tree"

# ── dry-run: ENABLED=0 logs would_reap_zombie_lock, removes nothing ───────────────
echo "── zombie dry-run (ENABLED=0) ──"
YTOWN="$TMP/ytown"; mkdir -p "$YTOWN"; YRIG="$YTOWN/yrig"; git init -q -b main "$YRIG"
( cd "$YRIG"; echo y>y.txt; git add y.txt; git commit -qm ybase; mkdir -p "$YRIG/.claude/worktrees"
  git worktree add -q "$YRIG/.claude/worktrees/agent-y" -b crew/y/y main
  git worktree lock --reason "claude agent agent-y pid 5001 start x" "$YRIG/.claude/worktrees/agent-y" ) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$YRIG/.claude/worktrees/agent-y" 2>/dev/null || true
YFAKEPS="$TMP/yfakeps.txt"; echo "5001 dead 0 0" > "$YFAKEPS"
WORKTREE_REAPER_GT="$YTOWN" WORKTREE_REAPER_LOG="$TMP/reaperY.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=0 \
WORKTREE_REAPER_FAKE_PS="$YFAKEPS" \
  bash "$REAPER" >/dev/null 2>&1
git -C "$YRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/.claude/worktrees/agent-y\$" >/dev/null \
  && ok "ENABLED=0: zombie-locked tree NOT removed (dry-run)" || bad "ENABLED=0 removed a zombie-locked tree"
grep -q '"event":"would_reap_zombie_lock"' "$TMP/reaperY.jsonl" 2>/dev/null && ok "ENABLED=0: logged would_reap_zombie_lock intent" || bad "ENABLED=0: no zombie dry intent logged"

# ══ INDEPENDENT CREW-CLONE COVERAGE (wa-bptki) ═══════════════════════════════════
# A named crew member's clone (<rig>/crew/oracle, crew/mila, …) is its OWN independent
# repo — a real `git clone` with its own .git DIRECTORY + own `origin` remote — NOT a
# linked worktree of the rig repo (which is how every other case in this file builds its
# fixtures, via `git worktree add "$RIG/crew/..."` FROM the rig itself). `git -C <rig>
# worktree list` cannot see worktrees registered inside such a clone. Proves: (i) a
# stale+clean worktree inside an independent crew clone IS reaped; (ii) a crew/ subdir
# with NO .git of its own (mirrors the real crew/worker, which shares the rig's .git) is
# left alone, not mistaken for an independent repo, no crash.
echo "── independent crew-clone coverage (wa-bptki) ──"
CTOWN="$TMP/ctown"; mkdir -p "$CTOWN"
CREMOTE="$TMP/cremote.git"; git init -q --bare "$CREMOTE"
CRIG="$CTOWN/crig"; git init -q -b main "$CRIG"
( cd "$CRIG"
  git remote add origin "$CREMOTE"
  echo r > r.txt; git add r.txt; git commit -qm rbase
  git push -q origin main; git fetch -q origin; git remote set-head origin main 2>/dev/null || true
) >/dev/null 2>&1
# the bare remote's HEAD symref defaults to whatever this git install's default branch
# name is (often master), NOT necessarily "main" — leaving it unset makes `git clone`
# below try to check out a branch that was never pushed, failing silently under the
# >/dev/null redirects and making every assertion in this section vacuously pass
# regardless of whether the reaper fix works. Point it at the branch that actually exists.
git -C "$CREMOTE" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
mkdir -p "$CRIG/crew"
# independent clone at crew/oracle — own .git DIRECTORY, own origin remote (mirrors the
# real crew/oracle: a `git clone` + `git remote add rootwt <rig>`, not `git worktree add`)
git clone -q "$CREMOTE" "$CRIG/crew/oracle" >/dev/null 2>&1
( cd "$CRIG/crew/oracle"
  git remote add rootwt "$CRIG" 2>/dev/null || true
  git branch crew/oracle/stale main
  git worktree add -q "$CRIG/crew/oracle/.claude/worktrees/agent-stale" crew/oracle/stale
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$CRIG/crew/oracle/.claude/worktrees/agent-stale" 2>/dev/null || true
# crew/worker — a plain dir with NO .git of its own — must be left alone, not crash
mkdir -p "$CRIG/crew/worker"

# precondition: the fixture itself must exist BEFORE reaping, independent of the fix —
# otherwise an "it's gone" assertion below would pass vacuously on a setup that silently
# failed to create it (this is exactly what happened the first time this section was
# written: an unset bare-remote HEAD broke the clone, and the reap assertion "passed"
# against the UNFIXED reaper because there was nothing there to reap in the first place).
if [ -d "$CRIG/crew/oracle/.claude/worktrees/agent-stale" ]; then
  ok "fixture precondition: agent-stale worktree exists before reap"
else
  bad "fixture precondition FAILED: agent-stale worktree was never created — assertions below are meaningless"
fi

WORKTREE_REAPER_GT="$CTOWN" WORKTREE_REAPER_LOG="$TMP/reaperC.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

git -C "$CRIG/crew/oracle" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/oracle/\.claude/worktrees/agent-stale\$" >/dev/null \
  && bad "independent crew-clone's stale worktree NOT reaped (scope gap NOT fixed)" \
  || ok "independent crew-clone's stale worktree reaped (wa-bptki scope gap fixed)"
branch_exists_in() { git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1; }
branch_exists_in "$CRIG/crew/oracle" crew/oracle/stale \
  && bad "crew clone's merged orphan branch NOT deleted" || ok "crew clone's merged orphan branch deleted"
[ -d "$CRIG/crew/worker" ] && ok "crew/worker (no own .git) left alone, no crash" || bad "crew/worker directory unexpectedly gone"

# ══ ga-0j2zc: gitignored-but-tracked drift must not leak into the preserve commit ══
# The dirty-worktree preserve path (ga-xv78c) stages the full working-tree state via
# `add -A` into a scratch index. `add -A` correctly skips NEW untracked files that match
# .gitignore, but it does NOT skip modifications to files that are ALREADY TRACKED and
# merely happen to also match a (later-added) .gitignore pattern — e.g. a vendorized/
# materialized dir like whatsapp_automation's .gc/, tracked before it was gitignored.
# Reported live: a preserve-before-reap commit (82e40efb6) carried 166 FILES / 24,021
# lines of .gc/ into a crew branch — none of it the crew's own work, all of it incidental
# drift in an already-tracked, now-ignored directory. Prove: (i) a tracked+now-ignored
# file's on-disk DRIFT is excluded from the preserve commit (pinned back to its pre-drift
# committed content); (ii) a tracked+now-ignored file's on-disk DELETION is likewise not
# swept in; (iii) genuine crew WIP in a NOT-ignored file is still captured (no regression
# on the ga-xv78c feature itself); (iv) a brand-new untracked file under the ignored dir
# stays excluded (pre-existing correct add -A behavior, must not regress).
echo "── ga-0j2zc: gitignored-but-tracked drift excluded from preserve commit ──"
GTOWN="$TMP/gtown"; mkdir -p "$GTOWN"
GREMOTE="$TMP/gremote.git"; git init -q --bare "$GREMOTE"
GRIG="$GTOWN/grig"; git init -q -b main "$GRIG"
( cd "$GRIG"
  git remote add origin "$GREMOTE"
  mkdir -p .gc
  echo orig-keep > .gc/keep.txt
  echo orig-del  > .gc/will-delete.txt
  git add .gc/keep.txt .gc/will-delete.txt
  git commit -qm "base: tracked files under .gc/ (before it was ignored)"
  echo ".gc/" > .gitignore
  git add .gitignore
  git commit -qm "ignore .gc/ going forward (already-tracked files stay tracked)"
  git push -q origin main
  git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree add -q "$GRIG/crew/worker-ga0j2zc" -b crew/g/ga0j2zc main
) >/dev/null 2>&1
( cd "$GRIG/crew/worker-ga0j2zc"
  echo "DRIFTED-BY-LIVE-DAEMON" > .gc/keep.txt        # tracked+ignored, modified on disk
  rm -f .gc/will-delete.txt                            # tracked+ignored, deleted on disk
  echo "new ignored artifact" > .gc/new-artifact.txt   # untracked+ignored — add -A already excludes this
  echo "genuine crew wip" > crew_wip.txt               # untracked, NOT ignored — must be captured
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$GRIG/crew/worker-ga0j2zc" 2>/dev/null || true

WORKTREE_REAPER_GT="$GTOWN" WORKTREE_REAPER_LOG="$TMP/reaperG.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1

gwt() { git -C "$GRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-ga0j2zc\$" >/dev/null; }
gwt && bad "ga-0j2zc: dirty worktree with ignored-tracked drift NOT reaped" || ok "ga-0j2zc: dirty worktree with ignored-tracked drift preserved+reaped"

git -C "$GREMOTE" rev-parse -q --verify refs/heads/crew/g/ga0j2zc >/dev/null 2>&1 \
  && ok "ga-0j2zc: preserve commit landed on origin" \
  || bad "ga-0j2zc: preserve commit never reached origin — cannot check its contents"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:.gc/keep.txt 2>/dev/null | grep -x orig-keep >/dev/null \
  && ok "ga-0j2zc: tracked+ignored file's on-disk DRIFT excluded (preserve kept pre-drift committed content)" \
  || bad "ga-0j2zc: tracked+ignored file's drift LEAKED into the preserve commit (the reported bug)"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:.gc/will-delete.txt 2>/dev/null | grep -x orig-del >/dev/null \
  && ok "ga-0j2zc: tracked+ignored file's on-disk DELETION not swept into the preserve commit" \
  || bad "ga-0j2zc: tracked+ignored file's deletion leaked into the preserve commit"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:crew_wip.txt 2>/dev/null | grep -x "genuine crew wip" >/dev/null \
  && ok "ga-0j2zc: genuine (non-ignored) crew WIP still captured (no ga-xv78c regression)" \
  || bad "ga-0j2zc: genuine crew WIP LOST — regression on the ga-xv78c preserve feature"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:.gc/new-artifact.txt >/dev/null 2>&1 \
  && bad "ga-0j2zc: new untracked file under the ignored dir wrongly captured" \
  || ok "ga-0j2zc: new untracked file under the ignored dir correctly excluded (pre-existing add -A behavior)"

# ══ ga-t14of: MERGED branch bypasses the age gate — but never while in use ═══════
# Reported live: 114 worktrees / 2.9G, 15 already merged into origin/main, sitting for
# hours to days because the age gate never distinguished "branch is done" from "branch
# is still live" — it only ever asked "how old is this directory". Proves: (i) a
# worktree whose branch is already merged, backdated PAST MERGED_MIN_AGE_MIN but still
# WELL UNDER the normal STALE_HOURS gate, is reaped anyway (the actual fix); (ii) the
# same shape, but with a live process's cwd inside it (WORKTREE_REAPER_FAKE_LSOF), is
# KEPT — the acceptance criteria's explicit test ("worktree em uso não é removido,
# mesmo que a branch esteja mergeada"); (iii) a worktree branched from main SECONDS ago
# (zero commits, so HEAD trivially equals main — "merged" in the literal sense, but
# nobody has started working yet) is KEPT, not reaped on sight — MERGED_MIN_AGE_MIN
# closing exactly the gap this fix's own selftest caught (see git history: an earlier
# version of this fix reaped its own in-progress worktree the instant it branched).
echo "── ga-t14of: merged-branch age-gate bypass (never while in use) ──"
MTOWN="$TMP/mtown"; mkdir -p "$MTOWN"
MREMOTE="$TMP/mremote.git"; git init -q --bare "$MREMOTE"
MRIG="$MTOWN/mrig"; git init -q -b main "$MRIG"
( cd "$MRIG"
  git remote add origin "$MREMOTE"
  echo m > m.txt; git add m.txt; git commit -qm mbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  # both branches sit at main's tip (merged); one will be faked as "in use", one not.
  git worktree add -q "$MRIG/crew/worker-merged-idle" -b crew/m/idle main
  git worktree add -q "$MRIG/crew/worker-merged-busy" -b crew/m/busy main
) >/dev/null 2>&1
# backdate PAST MERGED_MIN_AGE_MIN (default 30min) but dir-mtime age stays 0 in HOURS —
# well under STALE_HOURS=1 — so a reap here can ONLY be the merge fast-path, never the
# ordinary hour-granularity age gate.
for w in worker-merged-idle worker-merged-busy; do
  touch -t "$(date -v-35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M)" "$MRIG/crew/$w" 2>/dev/null || true
done
MFAKELSOF="$TMP/mfakelsof.txt"
# resolve to the REALPATH — macOS mktemp gives /var/..., git worktree list reports the
# realpath /private/var/..., and _worktree_in_use compares against git's form (same
# gotcha wt_exists() already works around above via suffix matching).
(cd "$MRIG/crew/worker-merged-busy" && pwd -P) > "$MFAKELSOF"

WORKTREE_REAPER_GT="$MTOWN" WORKTREE_REAPER_LOG="$TMP/reaperM.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_LSOF="$MFAKELSOF" \
  bash "$REAPER" >/dev/null 2>&1

mwt() { git -C "$MRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/$1\$" >/dev/null; }

mwt worker-merged-idle && bad "ga-t14of: merged+idle worktree, past grace period, NOT reaped (age-gate bypass broken)" \
  || ok "ga-t14of: merged+idle worktree reaped despite being under STALE_HOURS (age-gate bypass works)"
mwt worker-merged-busy && ok "ga-t14of: merged+IN-USE worktree KEPT (never reap out from under a live process)" \
  || bad "ga-t14of: merged+IN-USE worktree wrongly reaped — turns cleanup into an incident!"
grep -q '"event":"kept_merged_in_use"' "$TMP/reaperM.jsonl" 2>/dev/null \
  && ok "ga-t14of: kept_merged_in_use logged (distinguishable from an ordinary keep)" \
  || bad "ga-t14of: in-use protection fired silently (no log signal)"

# ── a JUST-CREATED worktree is trivially "merged" (HEAD==main, nothing has diverged
# yet) but must NOT be reaped on sight — own dedicated town, not backdated at all.
FTOWN="$TMP/ftown"; mkdir -p "$FTOWN"
FREMOTE="$TMP/fremote.git"; git init -q --bare "$FREMOTE"
FRIG="$FTOWN/frig"; git init -q -b main "$FRIG"
( cd "$FRIG"
  git remote add origin "$FREMOTE"
  echo f > f.txt; git add f.txt; git commit -qm fbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree add -q "$FRIG/crew/worker-merged-fresh" -b crew/f/fresh main
) >/dev/null 2>&1
WORKTREE_REAPER_GT="$FTOWN" WORKTREE_REAPER_LOG="$TMP/reaperF.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1
git -C "$FRIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-merged-fresh\$" >/dev/null \
  && ok "ga-t14of: freshly-branched (trivially merged) worktree KEPT (grace period protects not-yet-started work)" \
  || bad "ga-t14of: freshly-branched worktree wrongly reaped the instant it was created — destroys work before it starts!"

# ══ ga-t14of: WT_DIRS multi-root scan (the actual reported coverage gap) ══════════
# Loop 1 (the flat .gc-worktrees path-glob) had ZERO dedicated selftest coverage before
# this fix — every fixture above exercises loop 2 (reap_pool_worktrees) via <rig>/crew/*
# or <rig>/.claude|.gc-worktrees paths, never $TOWN/.gc-worktrees directly. Live measured
# root cause: .gascity-gastown-hq has no .git of its own (just a subdirectory sharing
# $GT's), so it's invisible to loop 2's per-rig scan (which deliberately skips $GT on the
# assumption loop 1 already covers it) — and loop 1 only ever looked at the FLAT
# $GT/.gc-worktrees root, never the NESTED $GT/.gascity-gastown-hq/.gc-worktrees one.
# Result: 105 of 113 real worktrees sat under exactly that nested shape, NEVER scanned
# by anything, for as long as 729 hours (30 days). Proves: (i) the flat root still reaps
# a stale worktree (loop-1 baseline, now with explicit coverage); (ii) the NESTED root is
# ALSO scanned — the actual fix; (iii) a merged branch in the nested root bypasses the
# age gate same as the flat one; (iv) a merged+IN-USE worktree in the nested root is
# KEPT — the safety property holds via loop 1 too, not just loop 2.
echo "── ga-t14of: WT_DIRS multi-root scan (.gascity-gastown-hq nesting) ──"
WTOWN="$TMP/wtown"; mkdir -p "$WTOWN/.gc-worktrees" "$WTOWN/.gascity-gastown-hq/.gc-worktrees"
WREMOTE="$TMP/wremote.git"; git init -q --bare "$WREMOTE"
# $WTOWN itself is the "repo" — mirrors real life, where .gascity-gastown-hq has no .git
# of its own and just shares $GT's: one shared checkout, two different `worktree add`
# targets (flat vs nested), both registered in the SAME repo's worktree list.
git init -q -b main "$WTOWN"
( cd "$WTOWN"
  git remote add origin "$WREMOTE"
  echo w > w.txt; git add w.txt; git commit -qm wbase
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  # flat root: unmerged branch — should reap on the ordinary age gate (loop-1 baseline)
  git worktree add -q "$WTOWN/.gc-worktrees/flat-unmerged" -b w/flat-unmerged main
  ( cd "$WTOWN/.gc-worktrees/flat-unmerged"; echo x > x.txt; git add x.txt; git commit -qm "ahead" )
  # nested root: merged branch (at main's tip), past grace period — the reported shape
  git worktree add -q "$WTOWN/.gascity-gastown-hq/.gc-worktrees/nested-merged" -b w/nested-merged main
  # nested root: SECOND merged branch, will be faked as in-use — must stay KEPT
  git worktree add -q "$WTOWN/.gascity-gastown-hq/.gc-worktrees/nested-merged-busy" -b w/nested-merged-busy main
) >/dev/null 2>&1
touch -t "$(date -v-3H +%Y%m%d%H%M 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M)" "$WTOWN/.gc-worktrees/flat-unmerged" 2>/dev/null || true
for w in nested-merged nested-merged-busy; do
  touch -t "$(date -v-35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M)" "$WTOWN/.gascity-gastown-hq/.gc-worktrees/$w" 2>/dev/null || true
done
WFAKELSOF="$TMP/wfakelsof.txt"
(cd "$WTOWN/.gascity-gastown-hq/.gc-worktrees/nested-merged-busy" && pwd -P) > "$WFAKELSOF"

WORKTREE_REAPER_GT="$WTOWN" WORKTREE_REAPER_LOG="$TMP/reaperW.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
WORKTREE_REAPER_FAKE_LSOF="$WFAKELSOF" \
  bash "$REAPER" >/dev/null 2>&1

wflat()       { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/\.gc-worktrees/flat-unmerged\$" >/dev/null; }
wnested()     { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/\.gascity-gastown-hq/\.gc-worktrees/nested-merged\$" >/dev/null; }
wnestedbusy() { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/\.gascity-gastown-hq/\.gc-worktrees/nested-merged-busy\$" >/dev/null; }

wflat && bad "ga-t14of: flat-root stale worktree NOT reaped (loop-1 baseline broken)" \
  || ok "ga-t14of: flat-root (\$GT/.gc-worktrees) stale worktree reaped (loop-1 baseline holds)"
wnested && bad "ga-t14of: nested-root (.gascity-gastown-hq/.gc-worktrees) merged worktree NOT reaped — the actual reported bug NOT fixed" \
  || ok "ga-t14of: nested-root (.gascity-gastown-hq/.gc-worktrees) merged worktree reaped — coverage gap closed"
wnestedbusy && ok "ga-t14of: nested-root merged+IN-USE worktree KEPT (in-use protection applies via loop 1 too)" \
  || bad "ga-t14of: nested-root merged+IN-USE worktree wrongly reaped via loop 1 — turns cleanup into an incident!"

# ══ ga-t14of gate-feedback (fix-attempt 1 FAILED review): the REAL (non-fake) lsof
# code path had ZERO coverage — every fixture above sets WORKTREE_REAPER_FAKE_LSOF,
# which short-circuits _worktree_in_use before it ever invokes lsof at all. These
# cases PATH-inject a stand-in `lsof` executable so the function's actual invocation
# (command -v lsof, then the real pipe/capture) runs for real, proving the reviewer's
# exact failure mode is fixed rather than merely reasoned about:
#   (i)   a real lsof that EXITS NONZERO while still printing a genuine match is read
#         as in-use — the pipefail-inversion bug (lsof's own often-nonzero exit no
#         longer overwrites awk's correctly-computed found=1, since lsof's exit code
#         is no longer consulted at all once its output is captured separately);
#   (ii)  a real lsof that prints NO output at all (any reason — permission-scoped
#         visibility, transient error, version skew) fails SAFE (kept), instead of
#         collapsing "couldn't tell" and "confirmed free" into the same value;
#   (iii) a real lsof that runs and genuinely finds no match is still correctly read
#         as not-in-use (no over-conservative regression from the (i)/(ii) hardening).
echo "── ga-t14of gate-feedback: real (non-fake) lsof path, fail-safe on error/empty ──"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"

# (i) exits 1 (mirrors lsof's real-world nonzero exit from permission errors on
# processes unrelated to the match) while still printing a genuine match.
R1TOWN="$TMP/r1town"; mkdir -p "$R1TOWN"
R1REMOTE="$TMP/r1remote.git"; git init -q --bare "$R1REMOTE"
R1RIG="$R1TOWN/r1rig"; git init -q -b main "$R1RIG"
( cd "$R1RIG"
  git remote add origin "$R1REMOTE"
  echo r1 > r1.txt; git add r1.txt; git commit -qm r1base
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree add -q "$R1RIG/crew/worker-real-busy" -b crew/r1/busy main
) >/dev/null 2>&1
touch -t "$(date -v-35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M)" "$R1RIG/crew/worker-real-busy" 2>/dev/null || true
REAL_BUSY_PATH="$(cd "$R1RIG/crew/worker-real-busy" && pwd -P)"
cat > "$FAKEBIN/lsof" <<EOF
#!/usr/bin/env bash
echo "n${REAL_BUSY_PATH}"
exit 1
EOF
chmod +x "$FAKEBIN/lsof"
PATH="$FAKEBIN:$PATH" \
WORKTREE_REAPER_GT="$R1TOWN" WORKTREE_REAPER_LOG="$TMP/reaperR1.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1
r1wt() { git -C "$R1RIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-real-busy\$" >/dev/null; }
r1wt && ok "gate-feedback: real lsof exit!=0-but-matched → still read as in-use (pipefail-inversion fixed)" \
       || bad "gate-feedback: real lsof's own nonzero exit inverted a genuine match into 'not in use' — the exact reported bug"

# (ii) prints NO output at all → fail SAFE (treated as in-use, kept)
R2TOWN="$TMP/r2town"; mkdir -p "$R2TOWN"
R2REMOTE="$TMP/r2remote.git"; git init -q --bare "$R2REMOTE"
R2RIG="$R2TOWN/r2rig"; git init -q -b main "$R2RIG"
( cd "$R2RIG"
  git remote add origin "$R2REMOTE"
  echo r2 > r2.txt; git add r2.txt; git commit -qm r2base
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree add -q "$R2RIG/crew/worker-real-empty" -b crew/r2/empty main
) >/dev/null 2>&1
touch -t "$(date -v-35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M)" "$R2RIG/crew/worker-real-empty" 2>/dev/null || true
cat > "$FAKEBIN/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKEBIN/lsof"
PATH="$FAKEBIN:$PATH" \
WORKTREE_REAPER_GT="$R2TOWN" WORKTREE_REAPER_LOG="$TMP/reaperR2.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1
r2wt() { git -C "$R2RIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-real-empty\$" >/dev/null; }
r2wt && ok "gate-feedback: real lsof with ZERO output fails SAFE (kept, not silently reaped)" \
       || bad "gate-feedback: real lsof's empty output was read as 'confirmed free' — the exact reported bug"

# (iii) runs cleanly and genuinely finds no match → still correctly reaped (no
# over-conservative regression from the (i)/(ii) hardening above)
R3TOWN="$TMP/r3town"; mkdir -p "$R3TOWN"
R3REMOTE="$TMP/r3remote.git"; git init -q --bare "$R3REMOTE"
R3RIG="$R3TOWN/r3rig"; git init -q -b main "$R3RIG"
( cd "$R3RIG"
  git remote add origin "$R3REMOTE"
  echo r3 > r3.txt; git add r3.txt; git commit -qm r3base
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree add -q "$R3RIG/crew/worker-real-clean" -b crew/r3/clean main
) >/dev/null 2>&1
touch -t "$(date -v-35M +%Y%m%d%H%M 2>/dev/null || date -d '35 minutes ago' +%Y%m%d%H%M)" "$R3RIG/crew/worker-real-clean" 2>/dev/null || true
cat > "$FAKEBIN/lsof" <<'EOF'
#!/usr/bin/env bash
echo "nSOME/OTHER/UNRELATED/PATH"
exit 0
EOF
chmod +x "$FAKEBIN/lsof"
PATH="$FAKEBIN:$PATH" \
WORKTREE_REAPER_GT="$R3TOWN" WORKTREE_REAPER_LOG="$TMP/reaperR3.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1
r3wt() { git -C "$R3RIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-real-clean\$" >/dev/null; }
r3wt && bad "gate-feedback: real lsof clean-exit + genuine non-match NOT reaped (over-conservative regression)" \
       || ok "gate-feedback: real lsof clean-exit + genuine non-match correctly reaped (no over-conservative regression)"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
