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
# safe (merged + clean + unused + aged → reaped, ga-vs6shu; "merged" = an ancestor of main OR, for a branch
# the gate rebased and that carries no merge commit, every commit there as an equivalent patch per
# `git cherry`, ga-1md7na; a merge commit, which cherry cannot see, blocks that proof; see the LOCK
# CONTRACT in the reaper), and any
# verdict other than exactly 'unparseable' is KEPT; ga-yw18yk: a branch that never shipped is still reaped (tree only,
# branch kept, detached HEAD parked on rescue/) when every bead the tree is named for is CLOSED long enough, and kept
# for every state that is not that (open, young, unknown, unreadable, lookup failed, op in progress, dirty, in use);
# ga-he2c1u: an UNLOCKED, delivered tree whose bead(s) are closed long enough and which is dirty with nothing but generated
# files (.gc/system, run markers, caches) is removed with a single --force by loop 1 — and kept for any other dirt (a modified or
# staged tracked file, an untracked source file, an edited pack.toml), an open/young/unknown bead, an unshipped commit, a live
# process, a lock (no -f -f there), the dry-run, and a narrowed list;
# the SIGTERM guard kills a crew claude proc
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

# ga-m5i7e6: two more pins, both for the scenarios that PREDATE it. (1) A tree's age is now its FRESHEST sign of life (index,
# HEAD commit, any file inside), but those scenarios backdate ONLY the root directory — the index, files and commits of their
# fixtures are minutes old — so they run the old rule (ACTIVITY_SCAN=0); the ga-m5i7e6 scenarios age the whole tree and switch
# it on per call. (2) _worktree_in_use now runs for every tree about to be removed, not only merged ones: unpinned, each of
# those scenarios would shell out to this machine's REAL lsof (and an lsof that prints nothing reads as "in use"). Pinned to an
# empty list = nothing in use; a scenario that wants a busy tree points the seam at its own list, the real-lsof ones unset it.
export WORKTREE_REAPER_ACTIVITY_SCAN=0
# ga-xpoj67: the same pin for the ignored-data guard. The ga-m5i7e6 scenarios keep an IGNORED battery output (pesquisa/) in the trees their
# controls expect reaped (a merged tree under pressure, the ordinary age path, a dead-holder lock), so they run the old rule (guard off);
# the ga-xpoj67 scenarios switch it on per call, and one of them unsets the pin to prove the default.
export WORKTREE_REAPER_IGNORED_DATA_GUARD=0
NO_LSOF="$TMP/no_lsof.txt"; : > "$NO_LSOF"
export WORKTREE_REAPER_FAKE_LSOF="$NO_LSOF"

# ga-yw18yk: the same hermeticity, for the BEAD lookup. An unparseable lock whose tree is clean/aged/unused
# now asks `bd` whether the worktree's bead is closed; without a seam every scenario below that keeps such a
# lock would shell out to the real `bd` against a temp repo with no beads database (slow, and dependent on
# this machine). Pin it to "the lookup worked and found no bead" for every invocation; the ga-yw18yk scenarios
# override it per call, and the one that exercises the real `bd` call unsets it (env -u) behind a stub on PATH.
EMPTY_BEADS="$TMP/empty_beads.json"
printf '[]' > "$EMPTY_BEADS"
export WORKTREE_REAPER_FAKE_BEADS="$EMPTY_BEADS"

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
for _f in _json_esc _log_lock_event _worktree_head_merged _ref_patch_equivalent _worktree_in_use delete_merged_local_branch _reap_or_log_unparseable_lock; do
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
env -u WORKTREE_REAPER_FAKE_LSOF PATH="$FAKEBIN:$PATH" \
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
env -u WORKTREE_REAPER_FAKE_LSOF PATH="$FAKEBIN:$PATH" \
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
env -u WORKTREE_REAPER_FAKE_LSOF PATH="$FAKEBIN:$PATH" \
WORKTREE_REAPER_GT="$R3TOWN" WORKTREE_REAPER_LOG="$TMP/reaperR3.jsonl" \
WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  bash "$REAPER" >/dev/null 2>&1
r3wt() { git -C "$R3RIG" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/worker-real-clean\$" >/dev/null; }
r3wt && bad "gate-feedback: real lsof clean-exit + genuine non-match NOT reaped (over-conservative regression)" \
       || ok "gate-feedback: real lsof clean-exit + genuine non-match correctly reaped (no over-conservative regression)"

# ══ ga-1md7na: a REBASED branch — content in main by PATCH, HEAD not an ancestor ═══════════
# The gate rebases/re-anchors a branch before merging, so the worktree's HEAD is never an
# ancestor of origin/<default> even when 100% of its content shipped (measured 05/10: 27 locked
# worktrees of CLOSED beads, `git cherry origin/main HEAD` showing only '-' lines, kept forever
# by the ancestry-only proof). `git cherry` (patch equivalence) is the second proof; every other
# proof of the safety net (clean status, not in use, aged) stays mandatory. The "kept" scenarios
# below cannot fail on pre-fix code (it keeps everything of this shape) — they pin the fix
# against being too eager, and were checked by mutation (see the bead comment).
echo "── ga-1md7na: rebased branch (patch-equivalent, not an ancestor) behind an unparseable lock ──"
PE_BIN="$TMP/pe_bin"; mkdir -p "$PE_BIN"
export PE_REAL_GIT="$(command -v git)"
cat > "$PE_BIN/git" <<'PEGIT'
#!/bin/sh
# Real git, except `git cherry` which PE_CHERRY can break: fail = rc 128 and no output;
# garbage = rc 0 and output that is not cherry's format; partial = a '-' line, THEN rc 1.
# And `git rev-list --merges` (the merge-commit check), which PE_REVLIST=fail breaks: rc 128, no output.
for a in "$@"; do
  if [ "$a" = "cherry" ]; then
    case "${PE_CHERRY:-}" in
      fail)    exit 128 ;;
      garbage) echo "warning: this is not a cherry line"; exit 0 ;;
      partial) echo "- 0123456789012345678901234567890123456789"; exit 1 ;;
    esac
  fi
  if [ "$a" = "--merges" ] && [ "${PE_REVLIST:-}" = "fail" ]; then exit 128; fi
done
exec "$PE_REAL_GIT" "$@"
PEGIT
chmod +x "$PE_BIN/git"
: > "$TMP/pe_nolsof.txt"

pe_age() { touch -t "$(date -v-"${2:-3}"H +%Y%m%d%H%M 2>/dev/null || date -d "${2:-3} hours ago" +%Y%m%d%H%M)" "$1" 2>/dev/null || true; }
# mk_rebased_rig <name> — $TMP/<name>/rig, crew/worker-pe on branch crew/<name>/pe with ONE commit
# that origin/main also has as a DIFFERENT commit (main moved on first, then took the same patch):
# HEAD is not an ancestor of origin/main, `git cherry` shows only '-'. Locked with an unreadable
# reason, 3h old. $2 = optional extra setup run inside the worktree (after the rebase shape exists).
mk_rebased_rig() {
  local name="$1" extra="${2:-}" root; root="$TMP/$name"; mkdir -p "$root"
  git init -q --bare "$root/remote.git"
  git init -q -b main "$root/rig"
  ( cd "$root/rig" || exit 1
    git remote add origin "$root/remote.git"
    echo base > base.txt; echo other > other.txt; git add base.txt other.txt; git commit -qm base
    git push -q origin main
    mkdir -p crew
    git worktree add -q crew/worker-pe -b "crew/$name/pe" main
    ( cd crew/worker-pe && echo feature > feature.txt && git add feature.txt && git commit -qm "feature" )
    echo more >> other.txt; git commit -qam "main moves on"
    git cherry-pick "crew/$name/pe" >/dev/null
    git push -q origin main; git fetch -q origin
    git remote set-head origin main 2>/dev/null || true
    git worktree lock --reason "wa-pe build (wa-worker-adhoc-gone-$name)" crew/worker-pe
    if [ -n "$extra" ]; then ( cd crew/worker-pe && eval "$extra" ); fi
  ) >/dev/null 2>&1
  pe_age "$root/rig/crew/worker-pe"
}
run_pe() { # run_pe <name> [ENV=val ...] — log → $TMP/<name>.jsonl
  local name="$1"; shift
  env PATH="$PE_BIN:$PATH" WORKTREE_REAPER_GT="$TMP/$name" WORKTREE_REAPER_LOG="$TMP/$name.jsonl" \
    WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_FAKE_LSOF="$TMP/pe_nolsof.txt" \
    "$@" bash "$REAPER" >/dev/null 2>&1
}
pe_wt() { git -C "$TMP/$1/rig" worktree list --porcelain 2>/dev/null | grep -E "/crew/worker-pe\$" >/dev/null; }
pe_br() { git -C "$TMP/$1/rig" rev-parse --verify -q "refs/heads/crew/$1/pe" >/dev/null 2>&1; }
pe_kept() { # pe_kept <name> <label> — still registered, branch intact, kept_locked_unparseable logged, never a reap event
  if pe_wt "$1" && pe_br "$1" && [ "$(events "$1" kept_locked_unparseable)" = "1" ] \
     && [ "$(events "$1" reaped_locked_unparseable_patch_equivalent)" = "0" ] \
     && [ "$(events "$1" reaped_locked_unparseable_safe)" = "0" ]; then ok "ga-1md7na: $2 → KEPT (worktree + branch intact, kept_locked_unparseable logged)"
  else bad "ga-1md7na: $2 → NOT kept (wt=$(pe_wt "$1" && echo y || echo n) br=$(pe_br "$1" && echo y || echo n) kept_ev=$(events "$1" kept_locked_unparseable) reaped_pe=$(events "$1" reaped_locked_unparseable_patch_equivalent))"; fi
}

# fixture sanity: the shape must be a REBASE (not an ancestor) whose patch IS in main — otherwise (a)
# would pass on the old ancestry-only code and prove nothing.
mk_rebased_rig pe_a
PE_HEAD="$(git -C "$TMP/pe_a/rig/crew/worker-pe" rev-parse HEAD)"
git -C "$TMP/pe_a/rig" merge-base --is-ancestor "$PE_HEAD" refs/remotes/origin/main 2>/dev/null \
  && bad "ga-1md7na fixture: HEAD IS an ancestor of origin/main — not a rebase shape, scenario (a) would prove nothing" \
  || ok "ga-1md7na fixture: HEAD is NOT an ancestor of origin/main (the rebase shape)"
PE_CH="$(git -C "$TMP/pe_a/rig" cherry refs/remotes/origin/main "$PE_HEAD" 2>/dev/null)"
case "$PE_CH" in "- "*) ok "ga-1md7na fixture: git cherry reports the commit as already in main ('-')" ;; *) bad "ga-1md7na fixture: git cherry said '$PE_CH', expected a '- <sha>' line" ;; esac

# (a) the measured bug: clean, old, no pid, patch in main → REAPED, branch gone, distinct event
run_pe pe_a
pe_wt pe_a && bad "ga-1md7na (a): rebased+patch-equivalent+clean+aged locked worktree NOT reaped (the measured leak)" \
           || ok "ga-1md7na (a): rebased+patch-equivalent+clean+aged locked worktree REAPED"
pe_br pe_a && bad "ga-1md7na (a): the patch-equivalent local branch was NOT deleted (orphan branch keeps the Pilot's _filter_built vetoing re-dispatch)" \
           || ok "ga-1md7na (a): the patch-equivalent local branch deleted under the same proof"
[ "$(events pe_a reaped_locked_unparseable_patch_equivalent)" = "1" ] && [ "$(events pe_a reaped_locked_unparseable_safe)" = "0" ] \
  && ok "ga-1md7na (a): logged as reaped_locked_unparseable_patch_equivalent (distinct from the ancestry reap)" \
  || bad "ga-1md7na (a): expected exactly 1 reaped_locked_unparseable_patch_equivalent and 0 reaped_locked_unparseable_safe, saw $(events pe_a reaped_locked_unparseable_patch_equivalent)/$(events pe_a reaped_locked_unparseable_safe)"

# (b) the same, but ONE commit that main does not have → KEPT (never lose real work)
mk_rebased_rig pe_b 'echo unshipped > unshipped.txt && git add unshipped.txt && git commit -qm "not in main"'
pe_age "$TMP/pe_b/rig/crew/worker-pe"
run_pe pe_b
pe_kept pe_b "rebased worktree with 1 commit NOT in main"

# (c) `git cherry` cannot answer → the third state, KEPT. Three ways to fail.
for mode in fail garbage partial; do
  mk_rebased_rig "pe_c_$mode"
  run_pe "pe_c_$mode" PE_CHERRY="$mode"
  pe_kept "pe_c_$mode" "git cherry unusable ($mode)"
done

# (d) a changed tracked file, and (d2) an untracked file → KEPT as today, even with every commit in main
mk_rebased_rig pe_d 'echo edited >> feature.txt'
pe_age "$TMP/pe_d/rig/crew/worker-pe"
run_pe pe_d
pe_kept pe_d "patch-equivalent HEAD but a modified tracked file"
mk_rebased_rig pe_d2 'echo scratch > untracked.txt'
pe_age "$TMP/pe_d2/rig/crew/worker-pe"
run_pe pe_d2
pe_kept pe_d2 "patch-equivalent HEAD but an untracked file"

# (e) a live process has the tree as cwd → KEPT; (f) younger than the gate → KEPT
mk_rebased_rig pe_e
( cd "$TMP/pe_e/rig/crew/worker-pe" && pwd -P ) > "$TMP/pe_e_lsof.txt"
run_pe pe_e WORKTREE_REAPER_FAKE_LSOF="$TMP/pe_e_lsof.txt"
pe_kept pe_e "patch-equivalent HEAD but a live process has it as cwd"
mk_rebased_rig pe_f
touch "$TMP/pe_f/rig/crew/worker-pe"
run_pe pe_f
pe_wt pe_f && pe_br pe_f && ok "ga-1md7na (f): patch-equivalent HEAD younger than the age gate → KEPT" \
           || bad "ga-1md7na (f): a worktree younger than the age gate was reaped"

# (g) dry-run: would_reap event, nothing removed
mk_rebased_rig pe_g
run_pe pe_g WORKTREE_REAPER_ENABLED=0
pe_wt pe_g && pe_br pe_g && [ "$(events pe_g would_reap_locked_unparseable_patch_equivalent)" = "1" ] \
  && ok "ga-1md7na (g): dry-run logs would_reap_locked_unparseable_patch_equivalent and removes nothing" \
  || bad "ga-1md7na (g): dry-run — wt=$(pe_wt pe_g && echo y || echo n) br=$(pe_br pe_g && echo y || echo n) would_ev=$(events pe_g would_reap_locked_unparseable_patch_equivalent)"

# (h) loop 1 (legacy path-glob over .gc-worktrees) shares the safety net but has its own wiring
PEL1="$TMP/pe_l1"; mkdir -p "$PEL1/.gc-worktrees"
git init -q --bare "$TMP/pe_l1_remote.git"
git init -q -b main "$PEL1"
( cd "$PEL1" || exit 1
  git remote add origin "$TMP/pe_l1_remote.git"
  echo base > base.txt; echo other > other.txt; git add base.txt other.txt; git commit -qm base
  git push -q origin main
  git worktree add -q .gc-worktrees/pe-l1 -b w/pel1 main
  ( cd .gc-worktrees/pe-l1 && echo feature > feature.txt && git add feature.txt && git commit -qm feature )
  echo more >> other.txt; git commit -qam "main moves on"
  git cherry-pick w/pel1 >/dev/null
  git push -q origin main; git fetch -q origin
  git remote set-head origin main 2>/dev/null || true
  git worktree lock --reason "wa-pe build (wa-worker-adhoc-gone-l1)" .gc-worktrees/pe-l1
) >/dev/null 2>&1
pe_age "$PEL1/.gc-worktrees/pe-l1"
run_pe pe_l1
git -C "$PEL1" worktree list --porcelain 2>/dev/null | grep -E "/\.gc-worktrees/pe-l1\$" >/dev/null \
  && bad "ga-1md7na (h): loop-1 rebased+patch-equivalent locked worktree NOT reaped (wiring drifted from loop 2)" \
  || ok "ga-1md7na (h): loop-1 (legacy path-glob) reaps the rebased+patch-equivalent locked worktree too"

# ══ ga-1md7na gate-feedback 1 (ga-jxkpdr): `git cherry` NEVER reports MERGE commits ═══════════
# A branch whose tip is a merge commit carrying content of its own reads as "every commit shipped" when
# every OTHER commit did: cherry lists only f1 ('-'), the merge is invisible, and the reaper would
# `worktree remove -f -f` a tree of unidentified holder and `branch -D` the only copy of the merge's
# content. Reviewer's repro: main = base + m1; branch = f1, then a merge of main@m1 with a file added
# INSIDE the merge commit; main then takes f1 by cherry-pick. Fail-closed rule: ANY merge commit in
# origin/<default>..<ref> means NOT proven (merge content is not examined); a merge-check that cannot
# answer is NOT proven either. Both keep the tree, exactly like a '+' line.
echo "── ga-1md7na gate-feedback 1: a merge commit in the branch is never proven by git cherry ──"
# Setup snippets for mk_rebased_rig, run inside the worktree: PE_MERGE_OWN merges the older main (m1 = main~1) and adds
# a file inside the merge commit; PE_MERGE_CLEAN is the same merge with nothing added.
PE_MERGE_OWN='git merge -q --no-ff --no-commit "$(git rev-parse main~1)" && echo "content only the merge has" > resolution_notes.txt && git add resolution_notes.txt && git commit -qm "merge carrying its own content"'
PE_MERGE_CLEAN='git merge -q --no-ff -m "clean merge of an older main" "$(git rev-parse main~1)"'

# (i) the reviewer's case: the merge has content of its own, f1 shipped by patch → KEPT.
mk_rebased_rig pe_i "$PE_MERGE_OWN"
PE_I_HEAD="$(git -C "$TMP/pe_i/rig/crew/worker-pe" rev-parse HEAD 2>/dev/null)"
# fixture sanity — without these the scenario could pass on a broken fixture and prove nothing.
[ -n "$(git -C "$TMP/pe_i/rig" rev-list --merges "refs/remotes/origin/main..$PE_I_HEAD" 2>/dev/null)" ] \
  && ok "ga-1md7na (i) fixture: the branch tip range holds a merge commit" \
  || bad "ga-1md7na (i) fixture: no merge commit in origin/main..HEAD — the setup did not build the merge shape"
PE_I_CH="$(git -C "$TMP/pe_i/rig" cherry refs/remotes/origin/main "$PE_I_HEAD" 2>/dev/null)"
if [ -n "$PE_I_CH" ] && ! printf '%s\n' "$PE_I_CH" | grep -qv '^- '; then ok "ga-1md7na (i) fixture: git cherry reports ONLY '-' lines (it cannot see the merge — the hole)"
else bad "ga-1md7na (i) fixture: git cherry said '$PE_I_CH', expected only '- <sha>' lines"; fi
git -C "$TMP/pe_i/rig" cat-file -e "$PE_I_HEAD:resolution_notes.txt" 2>/dev/null \
  && ! git -C "$TMP/pe_i/rig" cat-file -e refs/remotes/origin/main:resolution_notes.txt 2>/dev/null \
  && ok "ga-1md7na (i) fixture: resolution_notes.txt is in the branch tip and NOT in origin/main (content only the merge carries)" \
  || bad "ga-1md7na (i) fixture: resolution_notes.txt is not (in the tip, absent from main) — not the reviewer's shape"
pe_age "$TMP/pe_i/rig/crew/worker-pe"
run_pe pe_i
pe_kept pe_i "merge commit carrying its own content, every other commit patch-equivalent (reviewer's case)"

# (i2) the same merge with NO content of its own → also KEPT: merge commits are not examined, so any one blocks
# the proof (a false keep, the safe direction — the tree stays, nothing is lost).
mk_rebased_rig pe_i2 "$PE_MERGE_CLEAN"
[ -n "$(git -C "$TMP/pe_i2/rig" rev-list --merges "refs/remotes/origin/main..$(git -C "$TMP/pe_i2/rig/crew/worker-pe" rev-parse HEAD 2>/dev/null)" 2>/dev/null)" ] \
  && ok "ga-1md7na (i2) fixture: the branch tip range holds a merge commit" \
  || bad "ga-1md7na (i2) fixture: no merge commit in origin/main..HEAD — the setup did not build the merge shape"
pe_age "$TMP/pe_i2/rig/crew/worker-pe"
run_pe pe_i2
pe_kept pe_i2 "clean merge commit (no content of its own) — merges are not examined, so not proven"

# (j) the merge check itself cannot answer → the third state, KEPT (never read as "no merges").
mk_rebased_rig pe_j
run_pe pe_j PE_REVLIST=fail
pe_kept pe_j "merge-commit check failed (rev-list rc 128, no output)"

# (k) the BRANCH is re-proven at the moment it is deleted (delete_merged_local_branch, proof=patch_equivalent),
# not just the tree's HEAD — pinned at unit level because a worktree's HEAD is its branch tip, so a scenario cannot
# stage a branch that differs from the tree it was proven on. Real functions, awk-extracted (the reaper runs on source).
DB_SCRIPT="$TMP/db_sandbox.sh"
{
  echo 'set -uo pipefail'
  echo 'LOG="$DB_LOG"; ENABLED=1; branches_deleted=0'
  echo 'ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }'
  extract_reaper_fn _ref_patch_equivalent
  extract_reaper_fn delete_merged_local_branch
  echo 'delete_merged_local_branch "$DB_REPO" "$DB_BR" "$DB_PROOF"'
} > "$DB_SCRIPT"
db_run() { # db_run <fixture-name> — proof=patch_equivalent against crew/<name>/pe, tree already unregistered
  env DB_LOG="$TMP/$1.db.jsonl" DB_REPO="$TMP/$1/rig" DB_BR="crew/$1/pe" DB_PROOF=patch_equivalent bash "$DB_SCRIPT" >/dev/null 2>&1
}
db_unreg() { git -C "$TMP/$1/rig" worktree remove -f -f crew/worker-pe >/dev/null 2>&1; }
mk_rebased_rig pe_ka;                                                   db_unreg pe_ka; db_run pe_ka
pe_br pe_ka && bad "ga-1md7na (k) control: a shipped patch-equivalent branch was NOT deleted (the harness or the re-proof is broken)" \
            || ok "ga-1md7na (k) control: a shipped patch-equivalent branch IS deleted under proof=patch_equivalent"
mk_rebased_rig pe_kb 'echo unshipped > unshipped.txt && git add unshipped.txt && git commit -qm "not in main"'; db_unreg pe_kb; db_run pe_kb
pe_br pe_kb && ok "ga-1md7na (k): a branch with 1 commit NOT in main is KEPT even though the caller passed proof=patch_equivalent (branch re-proven)" \
            || bad "ga-1md7na (k): a branch with a commit main lacks was DELETED on a proof it does not satisfy (re-proof dropped)"
mk_rebased_rig pe_kc "$PE_MERGE_OWN";                                   db_unreg pe_kc; db_run pe_kc
pe_br pe_kc && ok "ga-1md7na (k): a branch whose tip is a merge carrying its own content is KEPT on proof=patch_equivalent" \
            || bad "ga-1md7na (k): a branch holding merge-only content was DELETED on proof=patch_equivalent"

echo "── ga-yw18yk: a free-text lock on a worktree whose BEAD is closed ──"
# The measured leak (14/10): 20 crew/worker-wa-* trees of CLOSED beads, 6h-15d old, ~165-340 MB each, held by a
# lock whose reason is free text ("wa-621dz active build"). Not "pid N", names no live session -> "unparseable";
# its branch is neither an ancestor of main nor patch-equivalent (a bead closed without a merge, a squash with
# local commits), so neither earlier proof fires and the tree sat there on every sweep (1.580 kept_locked_unparseable).
# The third proof: EVERY bead id the tree's directory/branch names is confirmed CLOSED for long enough. The branch is
# never deleted on it (only the tree goes), and a detached HEAD gets a rescue/ branch first.
BC_ID="wa-bc1xyz"
: > "$TMP/bc_nolsof.txt"
bc_iso() { date -u -v-"$1"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ; }
bc_bead() { # bc_bead <id> <status> [<hours since closed>] → one element of what `bd list --json` prints
  if [ -n "${3:-}" ]; then printf '{"id":"%s","status":"%s","closed_at":"%s"}' "$1" "$2" "$(bc_iso "$3")"
  else printf '{"id":"%s","status":"%s","closed_at":null}' "$1" "$2"; fi
}
# mk_bc_rig <name> [<setup run inside the worktree>] [<age in hours>] — $TMP/<name>/rig with crew/worker-wa-bc1xyz on
# branch crew/wa-worker/wa-bc1xyz carrying ONE commit that main lacks (so neither delivery proof can fire), CLEAN,
# locked with the free-text reason from the ticket, <age> (default 3) hours old.
mk_bc_rig() {
  local name="$1" extra="${2:-}" root; root="$TMP/$name"; mkdir -p "$root"
  git init -q --bare "$root/remote.git"
  git init -q -b main "$root/rig"
  ( cd "$root/rig" || exit 1
    git remote add origin "$root/remote.git"
    echo base > base.txt; git add base.txt; git commit -qm base
    git push -q origin main; git fetch -q origin
    git remote set-head origin main 2>/dev/null || true
    mkdir -p crew
    git worktree add -q "crew/worker-$BC_ID" -b "crew/wa-worker/$BC_ID" main
    ( cd "crew/worker-$BC_ID" && echo built > built.txt && git add built.txt && git commit -qm "built, never merged" )
    git worktree lock --reason "$BC_ID active build" "crew/worker-$BC_ID"
    if [ -n "$extra" ]; then ( cd "crew/worker-$BC_ID" && eval "$extra" ); fi
  ) >/dev/null 2>&1
  pe_age "$root/rig/crew/worker-$BC_ID" "${3:-3}"
}
run_bc() { # run_bc <name> <beads-json-array | @missing> [ENV=val ...] — the lookup goes through the FAKE_BEADS seam
  local name="$1" beads="$2"; shift 2
  if [ "$beads" = "@missing" ]; then rm -f "$TMP/$name.beads.json"; else printf '%s' "$beads" > "$TMP/$name.beads.json"; fi
  env WORKTREE_REAPER_GT="$TMP/$name" WORKTREE_REAPER_LOG="$TMP/$name.jsonl" \
    WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 WORKTREE_REAPER_FAKE_LSOF="$TMP/bc_nolsof.txt" \
    WORKTREE_REAPER_FAKE_BEADS="$TMP/$name.beads.json" "$@" bash "$REAPER" >/dev/null 2>&1
}
bc_wt() { git -C "$TMP/$1/rig" worktree list --porcelain 2>/dev/null | grep -E "/crew/worker-$BC_ID\$" >/dev/null; }
bc_br() { git -C "$TMP/$1/rig" rev-parse --verify -q "refs/heads/crew/wa-worker/$BC_ID" >/dev/null 2>&1; }
bc_tip() { git -C "$TMP/$1/rig" rev-parse "refs/heads/crew/wa-worker/$BC_ID" 2>/dev/null; }
bc_kept() { # bc_kept <name> <label> — tree + branch intact, kept_locked_unparseable logged, no bead_closed reap
  if bc_wt "$1" && bc_br "$1" && [ "$(events "$1" kept_locked_unparseable)" = "1" ] \
     && [ "$(events "$1" reaped_locked_unparseable_bead_closed)" = "0" ]; then ok "ga-yw18yk: $2 → KEPT (tree + branch intact, kept_locked_unparseable logged)"
  else bad "ga-yw18yk: $2 → NOT kept (wt=$(bc_wt "$1" && echo y || echo n) br=$(bc_br "$1" && echo y || echo n) kept_ev=$(events "$1" kept_locked_unparseable) reaped_bc=$(events "$1" reaped_locked_unparseable_bead_closed))"; fi
}

# (a) the measured bug: bead closed 10h ago, tree clean + aged + unused → tree REAPED, branch and its commit KEPT
mk_bc_rig bc_a; BC_A_TIP="$(bc_tip bc_a)"
run_bc bc_a "[$(bc_bead "$BC_ID" closed 10)]"
bc_wt bc_a && bad "ga-yw18yk (a): locked worktree of a CLOSED bead (clean, aged, unused) NOT reaped — the measured leak" \
           || ok "ga-yw18yk (a): locked worktree of a CLOSED bead (clean, aged, unused) REAPED"
{ bc_br bc_a && [ "$(bc_tip bc_a)" = "$BC_A_TIP" ]; } && ok "ga-yw18yk (a): the branch survives with its unmerged commit (no data loss: only the tree goes)" \
           || bad "ga-yw18yk (a): the branch (or its commit) was lost — the reap must never delete an unmerged branch"
[ "$(events bc_a reaped_locked_unparseable_bead_closed)" = "1" ] && [ "$(events bc_a kept_locked_unparseable)" = "0" ] \
  && ok "ga-yw18yk (a): logged as reaped_locked_unparseable_bead_closed (its own event, not the ancestry/patch ones)" \
  || bad "ga-yw18yk (a): expected exactly 1 reaped_locked_unparseable_bead_closed and 0 kept_locked_unparseable, saw $(events bc_a reaped_locked_unparseable_bead_closed)/$(events bc_a kept_locked_unparseable)"
grep '"event":"reaped_locked_unparseable_bead_closed"' "$TMP/bc_a.jsonl" 2>/dev/null | grep -F "\"verdict\":\"bead_closed $BC_ID\"" >/dev/null \
  && ok "ga-yw18yk (a): the event's verdict field names the closed bead it relied on (not just the directory name)" \
  || bad "ga-yw18yk (a): the reap event does not say which bead was closed: $(grep bead_closed "$TMP/bc_a.jsonl" 2>/dev/null | head -1)"

# (b) the bead is still OPEN (the worker may be mid-build) → KEPT
mk_bc_rig bc_b; run_bc bc_b "[$(bc_bead "$BC_ID" open)]";            bc_kept bc_b "bead OPEN"
mk_bc_rig bc_b2; run_bc bc_b2 "[$(bc_bead "$BC_ID" in_progress)]";   bc_kept bc_b2 "bead IN_PROGRESS"

# (c) the tree holds uncommitted work → KEPT (and, being locked, never preserve-and-forced either)
mk_bc_rig bc_c 'echo wip > wip.txt'; run_bc bc_c "[$(bc_bead "$BC_ID" closed 10)]"
bc_kept bc_c "bead closed but the tree is DIRTY"
[ -f "$TMP/bc_c/rig/crew/worker-$BC_ID/wip.txt" ] && ok "ga-yw18yk (c): the uncommitted file is still on disk" || bad "ga-yw18yk (c): uncommitted work was destroyed"

# (d) closed only 1h ago (default grace is 6h) → KEPT: a gate-fix round may be about to reopen/re-use it
mk_bc_rig bc_d; run_bc bc_d "[$(bc_bead "$BC_ID" closed 1)]";        bc_kept bc_d "bead closed only 1h ago (grace 6h)"
mk_bc_rig bc_d2; run_bc bc_d2 "[$(bc_bead "$BC_ID" closed 1)]" WORKTREE_REAPER_CLOSED_BEAD_HOURS=banana
bc_kept bc_d2 "unparseable WORKTREE_REAPER_CLOSED_BEAD_HOURS falls back to the 6h grace"
mk_bc_rig bc_d3; run_bc bc_d3 "[$(bc_bead "$BC_ID" closed 1)]" WORKTREE_REAPER_CLOSED_BEAD_HOURS=0
bc_wt bc_d3 && bad "ga-yw18yk (d): WORKTREE_REAPER_CLOSED_BEAD_HOURS=0 was ignored (a bead closed 1h ago should qualify)" \
            || ok "ga-yw18yk (d): WORKTREE_REAPER_CLOSED_BEAD_HOURS is honoured (0 → a bead closed 1h ago qualifies)"

# (e) a live process has the tree as its cwd → KEPT
mk_bc_rig bc_e; ( cd "$TMP/bc_e/rig/crew/worker-$BC_ID" && pwd -P > "$TMP/bc_e.lsof" )   # realpath: lsof reports /private/var, mktemp says /var
run_bc bc_e "[$(bc_bead "$BC_ID" closed 10)]" WORKTREE_REAPER_FAKE_LSOF="$TMP/bc_e.lsof"
bc_kept bc_e "bead closed but a process has the tree as its cwd"

# (f) the lookup cannot tell: failed (seam file missing), junk output, bead absent from a SUCCESSFUL answer, status
#     closed but no readable closed_at → none of these is "closed" → KEPT
mk_bc_rig bc_f1; run_bc bc_f1 "@missing";                              bc_kept bc_f1 "bead lookup FAILED"
mk_bc_rig bc_f2; run_bc bc_f2 'this is not json';                      bc_kept bc_f2 "bead lookup printed JUNK"
mk_bc_rig bc_f3; run_bc bc_f3 '{"id":"wa-bc1xyz","status":"closed"}';  bc_kept bc_f3 "bead lookup printed an object, not the array"
mk_bc_rig bc_f4; run_bc bc_f4 '[]';                                    bc_kept bc_f4 "bead NOT FOUND (the id was never a bead)"
mk_bc_rig bc_f5; run_bc bc_f5 "[$(bc_bead "$BC_ID" closed)]";          bc_kept bc_f5 "bead closed but closed_at missing"
mk_bc_rig bc_f6; run_bc bc_f6 '[{"id":"wa-bc1xyz","status":"closed","closed_at":"yesterday-ish"}]'; bc_kept bc_f6 "bead closed but closed_at unreadable"

# (g) two beads named by the tree (directory = wa-bc1xyz, branch = wa-bc2xyz): ALL found must be closed
mk_bc_rig bc_g 'git branch -m crew/wa-worker/wa-bc2xyz'
git -C "$TMP/bc_g/rig" rev-parse --verify -q refs/heads/crew/wa-worker/wa-bc2xyz >/dev/null 2>&1 || bad "ga-yw18yk fixture (g): branch rename failed"
run_bc bc_g "[$(bc_bead "$BC_ID" closed 10),$(bc_bead wa-bc2xyz open)]"
if bc_wt bc_g && [ "$(events bc_g kept_locked_unparseable)" = "1" ] && [ "$(events bc_g reaped_locked_unparseable_bead_closed)" = "0" ]; then
  ok "ga-yw18yk (g): directory names a closed bead but the branch names an OPEN one → KEPT"
else bad "ga-yw18yk (g): a tree naming an open bead was reaped on its other, closed bead"; fi
mk_bc_rig bc_g2 'git branch -m crew/wa-worker/wa-bc2xyz'; run_bc bc_g2 "[$(bc_bead "$BC_ID" closed 10),$(bc_bead wa-bc2xyz closed 9)]"
bc_wt bc_g2 && bad "ga-yw18yk (g): both named beads closed, tree NOT reaped" || ok "ga-yw18yk (g): every named bead closed → REAPED"

# (h) detached HEAD carrying a commit no branch holds → a rescue/ branch FIRST, then the tree goes
mk_bc_rig bc_h 'git checkout -q --detach && echo orphan > orphan.txt && git add orphan.txt && git commit -qm "detached-only work"'
BC_H_HEAD="$(git -C "$TMP/bc_h/rig/crew/worker-$BC_ID" rev-parse HEAD 2>/dev/null)"; BC_H_RESCUE="rescue/$BC_ID-$(printf '%s' "$BC_H_HEAD" | cut -c1-9)"
run_bc bc_h "[$(bc_bead "$BC_ID" closed 10)]"
bc_wt bc_h && bad "ga-yw18yk (h): detached-HEAD tree of a closed bead NOT reaped" || ok "ga-yw18yk (h): detached-HEAD tree of a closed bead REAPED"
[ -n "$BC_H_HEAD" ] && [ "$(git -C "$TMP/bc_h/rig" rev-parse --verify -q "refs/heads/$BC_H_RESCUE" 2>/dev/null)" = "$BC_H_HEAD" ] \
  && ok "ga-yw18yk (h): the detached commit is held by $BC_H_RESCUE (nothing is left only in a removed tree)" \
  || bad "ga-yw18yk (h): no $BC_H_RESCUE pointing at the detached HEAD — the commit is lost with the tree"
# (h2) the rescue branch cannot be created (a ref blocks its name) → the tree is KEPT, never removed without it
mk_bc_rig bc_h2 'git checkout -q --detach && echo orphan > orphan.txt && git add orphan.txt && git commit -qm "detached-only work"'
BC_H2_HEAD="$(git -C "$TMP/bc_h2/rig/crew/worker-$BC_ID" rev-parse HEAD 2>/dev/null)"
git -C "$TMP/bc_h2/rig" branch "rescue/$BC_ID-$(printf '%s' "$BC_H2_HEAD" | cut -c1-9)/blocker" main >/dev/null 2>&1
run_bc bc_h2 "[$(bc_bead "$BC_ID" closed 10)]"
if bc_wt bc_h2 && [ "$(events bc_h2 reaped_locked_unparseable_bead_closed)" = "0" ] && [ "$(events bc_h2 bead_closed_rescue_failed)" = "1" ]; then
  ok "ga-yw18yk (h2): the rescue branch could not be created → tree KEPT, bead_closed_rescue_failed logged"
else bad "ga-yw18yk (h2): rescue creation failed but the tree was reaped / the failure not logged (wt=$(bc_wt bc_h2 && echo y || echo n) rescue_failed=$(events bc_h2 bead_closed_rescue_failed))"; fi

# (i) younger than the age gate → KEPT before the lock is even looked at (the proof never shortens the age gate)
mk_bc_rig bc_i '' 0; run_bc bc_i "[$(bc_bead "$BC_ID" closed 10)]" WORKTREE_REAPER_STALE_HOURS=24
bc_wt bc_i && bc_br bc_i && ok "ga-yw18yk (i): a tree younger than the age gate is KEPT even though its bead is long closed" \
            || bad "ga-yw18yk (i): a fresh tree was reaped on the bead proof"

# (j) dry-run (ENABLED=0): says what it would do, does it not
mk_bc_rig bc_j; run_bc bc_j "[$(bc_bead "$BC_ID" closed 10)]" WORKTREE_REAPER_ENABLED=0
if bc_wt bc_j && bc_br bc_j && [ "$(events bc_j would_reap_locked_unparseable_bead_closed)" = "1" ]; then
  ok "ga-yw18yk (j): dry-run logs would_reap_locked_unparseable_bead_closed and removes nothing"
else bad "ga-yw18yk (j): dry-run — wt=$(bc_wt bc_j && echo y || echo n) would_ev=$(events bc_j would_reap_locked_unparseable_bead_closed)"; fi

# (k) the pid contract still wins: a lock naming a LIVE pid is never reaped on the bead proof
mk_bc_rig bc_k; git -C "$TMP/bc_k/rig" worktree unlock "crew/worker-$BC_ID" >/dev/null 2>&1
git -C "$TMP/bc_k/rig" worktree lock --reason "$BC_ID pid 4242 build" "crew/worker-$BC_ID" >/dev/null 2>&1
printf '4242 alive 600 10\n' > "$TMP/bc_k.ps"
run_bc bc_k "[$(bc_bead "$BC_ID" closed 10)]" WORKTREE_REAPER_FAKE_PS="$TMP/bc_k.ps"
bc_wt bc_k && bc_br bc_k && [ "$(events bc_k reaped_locked_unparseable_bead_closed)" = "0" ] \
  && ok "ga-yw18yk (k): a pid-confirmed LIVE holder is still kept — the bead proof only replaces the 'unparseable' verdict's gap" \
  || bad "ga-yw18yk (k): a live-pid lock was reaped on the bead proof"

# (l) the REAL `bd` call (no seam), through a stub on PATH: argv shape, a failing bd, a junk bd, a hanging bd (bounded)
BC_BIN="$TMP/bc_bin"; mkdir -p "$BC_BIN"
cat > "$BC_BIN/bd" <<'BCBD'
#!/bin/sh
echo "$*" >> "${FAKE_BD_LOG:-/dev/null}"
case "${FAKE_BD_MODE:-ok}" in
  ok)   case "$2" in
          */.gascity-gastown-hq) [ "${FAKE_BD_JSON_HQ:-}" = "@empty" ] && exit 0; cat "${FAKE_BD_JSON_HQ:-$FAKE_BD_JSON}" ;;
          *) cat "$FAKE_BD_JSON" ;;
        esac ;;
  empty) exit 0 ;;   # rc 0 and NOTHING on stdout: not "no such bead" (that is the array []), just no answer
  fail) echo "boom" >&2; exit 1 ;;
  junk) echo "this is not json" ;;
  hang) exec sleep 30 ;;
esac
BCBD
chmod +x "$BC_BIN/bd"
run_bc_bd() { # run_bc_bd <name> <mode> [ENV=val ...]
  local name="$1" mode="$2"; shift 2
  env -u WORKTREE_REAPER_FAKE_BEADS PATH="$BC_BIN:$PATH" FAKE_BD_MODE="$mode" FAKE_BD_JSON="$TMP/$name.beads.json" FAKE_BD_LOG="$TMP/$name.bd.log" \
    WORKTREE_REAPER_GT="$TMP/$name" WORKTREE_REAPER_LOG="$TMP/$name.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
    WORKTREE_REAPER_FAKE_LSOF="$TMP/bc_nolsof.txt" "$@" bash "$REAPER" >/dev/null 2>&1
}
mk_bc_rig bc_l1; printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_l1.beads.json"; run_bc_bd bc_l1 ok
bc_wt bc_l1 && bad "ga-yw18yk (l): the real bd lookup (stub on PATH) did not lead to a reap" || ok "ga-yw18yk (l): the real bd lookup (stub on PATH) → closed bead REAPED"
if grep -E -- "^-C .*/rig list --id .*$BC_ID.* --all --json --limit 0\$" "$TMP/bc_l1.bd.log" >/dev/null 2>&1; then
  ok "ga-yw18yk (l): bd is called as 'bd -C <repo> list --id <ids> --all --json --limit 0' (closed beads included, no 50-row truncation)"
else bad "ga-yw18yk (l): unexpected bd call shape: $(head -2 "$TMP/bc_l1.bd.log" 2>/dev/null)"; fi
mk_bc_rig bc_l2; printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_l2.beads.json"; run_bc_bd bc_l2 fail;  bc_kept bc_l2 "real bd EXITED non-zero"
mk_bc_rig bc_l3; printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_l3.beads.json"; run_bc_bd bc_l3 junk;  bc_kept bc_l3 "real bd printed JUNK"
mk_bc_rig bc_l4; printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_l4.beads.json"
BC_T0=$(date +%s); run_bc_bd bc_l4 hang WORKTREE_REAPER_BEAD_LOOKUP_TIMEOUT=2; BC_T1=$(date +%s)
bc_kept bc_l4 "real bd HUNG (bounded by WORKTREE_REAPER_BEAD_LOOKUP_TIMEOUT)"
[ $((BC_T1 - BC_T0)) -lt 20 ] && ok "ga-yw18yk (l): a hung bd cost the sweep $((BC_T1 - BC_T0))s, not the stub's 30s" \
                              || bad "ga-yw18yk (l): a hung bd held the sweep for $((BC_T1 - BC_T0))s — the lookup is not bounded"

# (n) a merge / rebase / cherry-pick under way in the tree is not a finished worktree, whatever the bead says → KEPT
mk_bc_rig bc_n 'echo "$(git rev-parse main)" > "$(git rev-parse --git-path MERGE_HEAD)"'
run_bc bc_n "[$(bc_bead "$BC_ID" closed 10)]"
bc_kept bc_n "bead closed but a MERGE is in progress in the tree"
mk_bc_rig bc_n2 'mkdir -p "$(git rev-parse --git-path rebase-merge)"'
run_bc bc_n2 "[$(bc_bead "$BC_ID" closed 10)]"
bc_kept bc_n2 "bead closed but a REBASE is in progress in the tree"

# (o) a name the rig database does not hold, with a prefix it has no beads for, is asked of the HQ database too:
#     directory = rig bead wa-bc1xyz (closed), branch = HQ bead ga-bc9xyz. Open there → KEPT; closed there → REAPED.
mk_bc_rig bc_o 'git branch -m crew/wa-worker/ga-bc9xyz'
printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_o.beads.json"; printf '%s' "[$(bc_bead ga-bc9xyz open)]" > "$TMP/bc_o.hq.json"
run_bc_bd bc_o ok FAKE_BD_JSON_HQ="$TMP/bc_o.hq.json"
if bc_wt bc_o && [ "$(events bc_o kept_locked_unparseable)" = "1" ] && [ "$(events bc_o reaped_locked_unparseable_bead_closed)" = "0" ]; then
  ok "ga-yw18yk (o): the rig's bead is closed but the HQ bead named by the branch is OPEN → KEPT"
else bad "ga-yw18yk (o): a tree naming an open HQ bead was reaped on its closed rig bead (the HQ database was not asked)"; fi
if [ "$(grep -c -- 'list --id' "$TMP/bc_o.bd.log" 2>/dev/null)" = "2" ] && grep -E -- "^-C .*/\.gascity-gastown-hq list --id ga-bc9xyz --all" "$TMP/bc_o.bd.log" >/dev/null 2>&1; then
  ok "ga-yw18yk (o): exactly one extra bd call, to the HQ database, asking only for the name the rig could not account for"
else bad "ga-yw18yk (o): unexpected bd calls: $(tr '\n' '|' < "$TMP/bc_o.bd.log" 2>/dev/null)"; fi
mk_bc_rig bc_o2 'git branch -m crew/wa-worker/ga-bc9xyz'
printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_o2.beads.json"; printf '%s' "[$(bc_bead ga-bc9xyz closed 9)]" > "$TMP/bc_o2.hq.json"
run_bc_bd bc_o2 ok FAKE_BD_JSON_HQ="$TMP/bc_o2.hq.json"
bc_wt bc_o2 && bad "ga-yw18yk (o): both the rig bead and the HQ bead closed, tree NOT reaped" || ok "ga-yw18yk (o): rig bead and HQ bead both closed → REAPED"
# ... and an HQ database that cannot be asked keeps the tree (a possibly-open bead is not a closed one)
mk_bc_rig bc_o3 'git branch -m crew/wa-worker/ga-bc9xyz'
printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_o3.beads.json"
run_bc_bd bc_o3 ok FAKE_BD_JSON_HQ=/nonexistent/hq.json
if bc_wt bc_o3 && [ "$(events bc_o3 kept_locked_unparseable)" = "1" ] && [ "$(events bc_o3 reaped_locked_unparseable_bead_closed)" = "0" ] \
   && [ "$(events bc_o3 bead_lookup_failed)" = "1" ]; then
  ok "ga-yw18yk (o): the HQ database could not be read → KEPT, and bead_lookup_failed says why"
else bad "ga-yw18yk (o): unreadable HQ database — wt=$(bc_wt bc_o3 && echo y || echo n) kept_ev=$(events bc_o3 kept_locked_unparseable) lookup_failed_ev=$(events bc_o3 bead_lookup_failed)"; fi

# (p) bd exits 0 but prints NOTHING. That is no answer, not the answer "none of these exist" (which is the array []):
#     jq exits 0 on empty input too, so reading the silence as "not found" would let a possibly-open bead go unseen.
mk_bc_rig bc_p1; printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_p1.beads.json"; run_bc_bd bc_p1 empty
if bc_wt bc_p1 && bc_br bc_p1 && [ "$(events bc_p1 reaped_locked_unparseable_bead_closed)" = "0" ] && [ "$(events bc_p1 bead_lookup_failed)" = "1" ]; then
  ok "ga-yw18yk (p): the rig database answers with silence → KEPT, and bead_lookup_failed says so"
else bad "ga-yw18yk (p): empty bd output — wt=$(bc_wt bc_p1 && echo y || echo n) reaped=$(events bc_p1 reaped_locked_unparseable_bead_closed) lookup_failed_ev=$(events bc_p1 bead_lookup_failed)"; fi
mk_bc_rig bc_p2 'git branch -m crew/wa-worker/ga-bc9xyz'
printf '%s' "[$(bc_bead "$BC_ID" closed 10)]" > "$TMP/bc_p2.beads.json"
run_bc_bd bc_p2 ok FAKE_BD_JSON_HQ=@empty
if bc_wt bc_p2 && [ "$(events bc_p2 reaped_locked_unparseable_bead_closed)" = "0" ] && [ "$(events bc_p2 bead_lookup_failed)" = "1" ]; then
  ok "ga-yw18yk (p): the rig's bead is closed but the HQ database answers with silence → KEPT (a silent HQ is not 'no HQ bead')"
else bad "ga-yw18yk (p): silent HQ database — wt=$(bc_wt bc_p2 && echo y || echo n) reaped=$(events bc_p2 reaped_locked_unparseable_bead_closed) lookup_failed_ev=$(events bc_p2 bead_lookup_failed)"; fi

# (m) loop 1 (the legacy .gc-worktrees glob, label 'town', branch passed empty): same proof, branch read from the tree itself
BCTOWN="$TMP/bc_m"; mkdir -p "$BCTOWN/.gc-worktrees"; git init -q --bare "$TMP/bc_m.git"; git init -q -b main "$BCTOWN"
( cd "$BCTOWN" || exit 1
  git remote add origin "$TMP/bc_m.git"; echo t > t.txt; git add t.txt; git commit -qm t
  git push -q origin main; git fetch -q origin; git remote set-head origin main 2>/dev/null || true
  git worktree add -q .gc-worktrees/ga-bc3xyz-build -b fix/ga-bc3xyz-build main
  ( cd .gc-worktrees/ga-bc3xyz-build && echo b > b.txt && git add b.txt && git commit -qm "built, never merged" )
  git worktree lock --reason "ga-bc3xyz gate-fix r1 builder" .gc-worktrees/ga-bc3xyz-build
) >/dev/null 2>&1
pe_age "$BCTOWN/.gc-worktrees/ga-bc3xyz-build" 3
printf '%s' "[$(bc_bead ga-bc3xyz closed 10)]" > "$TMP/bc_m.beads.json"
WORKTREE_REAPER_GT="$BCTOWN" WORKTREE_REAPER_LOG="$TMP/bc_m.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
  WORKTREE_REAPER_FAKE_LSOF="$TMP/bc_nolsof.txt" WORKTREE_REAPER_FAKE_BEADS="$TMP/bc_m.beads.json" bash "$REAPER" >/dev/null 2>&1
git -C "$BCTOWN" worktree list --porcelain 2>/dev/null | grep -E "/\.gc-worktrees/ga-bc3xyz-build\$" >/dev/null \
  && bad "ga-yw18yk (m): loop-1 locked worktree of a closed bead NOT reaped (call-site wiring drifted from the pool loop)" \
  || ok "ga-yw18yk (m): loop-1 (legacy path-glob) also reaps a locked worktree of a closed bead"
git -C "$BCTOWN" rev-parse --verify -q refs/heads/fix/ga-bc3xyz-build >/dev/null 2>&1 \
  && ok "ga-yw18yk (m): loop-1 keeps the (unmerged) branch" || bad "ga-yw18yk (m): loop-1 deleted an unmerged branch"

# ══ ga-he2c1u: a DELIVERED tree of a CLOSED bead that is dirty with nothing but GENERATED files ═══
# The plain `worktree remove` refuses any dirt, so such a tree (bead closed + merged + a copy of .gc/system and a few
# run markers) was skipped on every sweep, silently, and stayed on a disk that was down to 2 GiB. Loop 1 now removes it
# with a single --force iff EVERY proof holds; each scenario below breaks exactly one of them (or the generated-only
# claim itself) and must KEEP the tree, its files and its lock.
echo "── ga-he2c1u: dirty-only-generated tree of a closed bead, delivered → reaped; any other dirt or missing proof → kept ──"
DG_ID="ga-dg1xyz"
DG_GEN='mkdir -p .gc/system/packs/bd && echo s > .gc/system/packs/bd/pack.toml && echo o > .pce-full.out && mkdir -p __pycache__ && echo b > __pycache__/m.cpython-313.pyc && mkdir -p .gascity-gastown-hq && cp ../../.gascity-gastown-hq/pack.toml .gascity-gastown-hq/pack.toml'
# mk_dg_town <name> [<setup run inside the worktree>] [<setup run in the town after it>] [<age in hours>] — a town repo $TMP/<name>
# (origin/main set) with the city's pack.toml at .gascity-gastown-hq/pack.toml and ONE worktree .gc-worktrees/ga-dg1xyz-build on
# branch fix/ga-dg1xyz-build at main (so: delivered by ancestry), <age> (default 3) hours old.
mk_dg_town() {
  local name="$1" extra="${2:-}" post="${3:-}" town="$TMP/$1"
  mkdir -p "$town/.gc-worktrees" "$town/.gascity-gastown-hq"; git init -q --bare "$TMP/$name.git"; git init -q -b main "$town"
  ( cd "$town" || exit 1
    git remote add origin "$TMP/$name.git"; echo t > t.txt; git add t.txt; git commit -qm t
    echo "city pack" > .gascity-gastown-hq/pack.toml
    git push -q origin main; git fetch -q origin; git remote set-head origin main 2>/dev/null || true
    git worktree add -q ".gc-worktrees/$DG_ID-build" -b "fix/$DG_ID-build" main
    [ -z "$extra" ] || ( cd ".gc-worktrees/$DG_ID-build" && eval "$extra" )
    [ -z "$post" ] || eval "$post"
  ) >/dev/null 2>&1
  pe_age "$town/.gc-worktrees/$DG_ID-build" "${4:-3}"
}
run_dg() { # run_dg <name> <beads-json-array> [ENV=val ...]
  local name="$1" beads="$2"; shift 2
  printf '%s' "$beads" > "$TMP/$name.beads.json"
  env WORKTREE_REAPER_GT="$TMP/$name" WORKTREE_REAPER_LOG="$TMP/$name.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 \
    WORKTREE_REAPER_FAKE_LSOF="$TMP/bc_nolsof.txt" WORKTREE_REAPER_FAKE_BEADS="$TMP/$name.beads.json" "$@" bash "$REAPER" >/dev/null 2>&1
}
dg_wt() { git -C "$TMP/$1" worktree list --porcelain 2>/dev/null | grep -E "/\.gc-worktrees/$DG_ID-build\$" >/dev/null; }
dg_br() { git -C "$TMP/$1" rev-parse --verify -q "refs/heads/fix/$DG_ID-build" >/dev/null 2>&1; }
dg_kept() { # dg_kept <name> <label> — tree, its files and the branch intact; nothing reaped on this path
  if dg_wt "$1" && dg_br "$1" && [ -e "$TMP/$1/.gc-worktrees/$DG_ID-build/t.txt" ] && [ "$(events "$1" reaped_dirty_generated_only)" = "0" ]; then
    ok "ga-he2c1u: $2 → KEPT (tree + branch intact, nothing reaped on the generated-only path)"
  else bad "ga-he2c1u: $2 → NOT kept (wt=$(dg_wt "$1" && echo y || echo n) br=$(dg_br "$1" && echo y || echo n) reaped_ev=$(events "$1" reaped_dirty_generated_only))"; fi
}
DG_CLOSED="[$(bc_bead "$DG_ID" closed 10)]"

# (a) the measured gap: closed 10h ago, HEAD in main, dirty with .gc/system + a run marker + a bytecode cache + the city's pack.toml copy
mk_dg_town dg_a "$DG_GEN"
run_dg dg_a "$DG_CLOSED"
dg_wt dg_a && bad "ga-he2c1u (a): delivered tree of a closed bead, dirty only with generated files, NOT reaped — the criterion still cannot retire it" \
           || ok "ga-he2c1u (a): delivered tree of a closed bead, dirty only with generated files, REAPED"
[ ! -e "$TMP/dg_a/.gc-worktrees/$DG_ID-build" ] && ok "ga-he2c1u (a): the directory is gone (git removed it, not a rm -rf)" \
  || bad "ga-he2c1u (a): the worktree is unregistered but its directory is still on disk"
dg_br dg_a && ok "ga-he2c1u (a): the branch survives (only the tree goes)" || bad "ga-he2c1u (a): the branch was lost"
grep '"event":"reaped_dirty_generated_only"' "$TMP/dg_a.jsonl" 2>/dev/null | grep -F "\"verdict\":\"ancestor bead_closed $DG_ID\"" >/dev/null \
  && ok "ga-he2c1u (a): its own event, and the verdict names the delivery proof and the closed bead" \
  || bad "ga-he2c1u (a): no reaped_dirty_generated_only event with the proof + bead: $(grep dirty_generated "$TMP/dg_a.jsonl" 2>/dev/null | head -1)"

# (b) the same, plus ONE untracked file nobody generated → kept, file intact
mk_dg_town dg_b "$DG_GEN; echo 'echo mine' > mine.sh"
run_dg dg_b "$DG_CLOSED"
dg_kept dg_b "generated files + one untracked source file"
[ -e "$TMP/dg_b/.gc-worktrees/$DG_ID-build/mine.sh" ] && ok "ga-he2c1u (b): the untracked source file is still there" || bad "ga-he2c1u (b): the untracked source file was destroyed"

# (c) a TRACKED file modified, plus generated files → kept
mk_dg_town dg_c "$DG_GEN; echo edit >> t.txt"
run_dg dg_c "$DG_CLOSED"
dg_kept dg_c "generated files + a modified tracked file"

# (c2) a path that LOOKS generated but is staged (tracked) → kept: a tracked file is somebody's
mk_dg_town dg_c2 "$DG_GEN; echo keep > .pce-staged.out; git add .pce-staged.out"
run_dg dg_c2 "$DG_CLOSED"
dg_kept dg_c2 "a staged file whose path matches the generated list"

# (d) bead still open → kept
mk_dg_town dg_d "$DG_GEN"
run_dg dg_d "[$(bc_bead "$DG_ID" open)]"
dg_kept dg_d "bead open"

# (e) bead closed, but only 1h ago (< 6h) → kept
mk_dg_town dg_e "$DG_GEN"
run_dg dg_e "[$(bc_bead "$DG_ID" closed 1)]"
dg_kept dg_e "bead closed only 1h ago"

# (f) the bead lookup knows no such bead (the seam's empty answer) → kept: nothing says the work is over
mk_dg_town dg_f "$DG_GEN"
run_dg dg_f "[]"
dg_kept dg_f "no bead found for the tree's name"

# (g) HEAD carries a commit main lacks (neither delivery proof) → kept
mk_dg_town dg_g "echo w > w.txt && git add w.txt && git commit -qm w && $DG_GEN"
run_dg dg_g "$DG_CLOSED"
dg_kept dg_g "an unshipped commit"

# (h) a live process has the tree as its cwd → kept
mk_dg_town dg_h "$DG_GEN"
(cd "$TMP/dg_h/.gc-worktrees/$DG_ID-build" && pwd -P) > "$TMP/dg_h.lsof"   # realpath, like the reaper's $d (TMP sits behind /var → /private/var)
run_dg dg_h "$DG_CLOSED" WORKTREE_REAPER_FAKE_LSOF="$TMP/dg_h.lsof"
dg_kept dg_h "a live process in the tree"

# (h2) the same for a PATCH-EQUIVALENT tree: Loop 1 only checks "in use" up front for an ancestor-merged HEAD, so here the
# new path's own check is the only thing between a live process and the --force
mk_dg_town dg_h2 "echo p > p.txt && git add p.txt && git commit -qm p && $DG_GEN" "git cherry-pick -x fix/$DG_ID-build && git push -q origin main && git fetch -q origin"
(cd "$TMP/dg_h2/.gc-worktrees/$DG_ID-build" && pwd -P) > "$TMP/dg_h2.lsof"
run_dg dg_h2 "$DG_CLOSED" WORKTREE_REAPER_FAKE_LSOF="$TMP/dg_h2.lsof"
dg_kept dg_h2 "a live process in a patch-equivalent tree"

# (i) LOCKED → never --force'd by this path (locks keep their own contract); the lock survives
mk_dg_town dg_i "$DG_GEN; git worktree lock --reason 'ga-dg1xyz active build' ."
run_dg dg_i "$DG_CLOSED"
dg_kept dg_i "locked tree"
git -C "$TMP/dg_i" worktree list --porcelain 2>/dev/null | grep -q '^locked' && ok "ga-he2c1u (i): the lock is still in place" || bad "ga-he2c1u (i): the lock was dropped"
# git would refuse the --force on a locked tree by itself; the point of looking first is that the refusal costs no event per sweep
[ "$(events dg_i dirty_generated_reap_failed)" = "0" ] && ok "ga-he2c1u (i): a locked tree never even reaches the --force (no dirty_generated_reap_failed)" \
  || bad "ga-he2c1u (i): the --force was attempted on a locked tree ($(events dg_i dirty_generated_reap_failed) dirty_generated_reap_failed)"

# (j) the city's pack.toml copy was EDITED → not generated → kept
mk_dg_town dg_j "$DG_GEN; echo local-edit >> .gascity-gastown-hq/pack.toml"
run_dg dg_j "$DG_CLOSED"
dg_kept dg_j "a pack.toml that differs from the city's"

# (k) delivered by an EQUIVALENT PATCH (the gate re-anchored it: HEAD is not an ancestor of main) → reaped, verdict says so
mk_dg_town dg_k "echo p > p.txt && git add p.txt && git commit -qm p && $DG_GEN" "git cherry-pick -x fix/$DG_ID-build && git push -q origin main && git fetch -q origin"
run_dg dg_k "$DG_CLOSED"
dg_wt dg_k && bad "ga-he2c1u (k): patch-equivalent delivered tree of a closed bead NOT reaped" || ok "ga-he2c1u (k): patch-equivalent delivered tree of a closed bead REAPED"
grep '"event":"reaped_dirty_generated_only"' "$TMP/dg_k.jsonl" 2>/dev/null | grep -F '"verdict":"patch_equivalent bead_closed' >/dev/null \
  && ok "ga-he2c1u (k): the verdict says patch_equivalent" || bad "ga-he2c1u (k): verdict does not name the patch-equivalence proof: $(grep dirty_generated "$TMP/dg_k.jsonl" 2>/dev/null | head -1)"

# (l) dry-run (ENABLED=0): Loop 1 logs its own would_reap and removes nothing — the --force path is never reached
mk_dg_town dg_l "$DG_GEN"
run_dg dg_l "$DG_CLOSED" WORKTREE_REAPER_ENABLED=0
if dg_wt dg_l && dg_br dg_l && [ -e "$TMP/dg_l/.gc-worktrees/$DG_ID-build/t.txt" ] && [ "$(events dg_l would_reap)" = "1" ] \
   && [ "$(events dg_l reaped_dirty_generated_only)" = "0" ] && [ "$(events dg_l dirty_generated_reap_failed)" = "0" ]; then
  ok "ga-he2c1u (l): dry-run logs would_reap, removes nothing and never tries the --force path"
else bad "ga-he2c1u (l): dry-run — wt=$(dg_wt dg_l && echo y || echo n) would=$(events dg_l would_reap) reaped=$(events dg_l reaped_dirty_generated_only) failed=$(events dg_l dirty_generated_reap_failed)"; fi

# (n) the town repo does NOT list the tree (an engine worktree parked under the town's .gc-worktrees belongs to ANOTHER
# repo; `git -C $GT worktree list` cannot vouch for it): kept, files intact, and no --force even attempted
mk_dg_town dg_n "$DG_GEN"
git -C "$TMP/dg_n" worktree remove --force ".gc-worktrees/$DG_ID-build" >/dev/null 2>&1   # free the path, then re-home it under another repo
git init -q -b main "$TMP/dg_n_other" >/dev/null 2>&1
( cd "$TMP/dg_n_other" && echo o > o.txt && git add o.txt && git commit -qm o && git worktree add -q "$TMP/dg_n/.gc-worktrees/$DG_ID-build" -b "fix/$DG_ID-build" \
  && cd "$TMP/dg_n/.gc-worktrees/$DG_ID-build" && eval "$DG_GEN" ) >/dev/null 2>&1
pe_age "$TMP/dg_n/.gc-worktrees/$DG_ID-build" 3
run_dg dg_n "$DG_CLOSED"
if [ -e "$TMP/dg_n/.gc-worktrees/$DG_ID-build/o.txt" ] && [ -e "$TMP/dg_n/.gc-worktrees/$DG_ID-build/.pce-full.out" ] \
   && [ "$(events dg_n reaped_dirty_generated_only)" = "0" ] && [ "$(events dg_n dirty_generated_reap_failed)" = "0" ]; then
  ok "ga-he2c1u (n): a tree the town repo does not list → KEPT, files intact, no --force attempted"
else bad "ga-he2c1u (n): foreign tree — o.txt=$([ -e "$TMP/dg_n/.gc-worktrees/$DG_ID-build/o.txt" ] && echo y || echo n) reaped=$(events dg_n reaped_dirty_generated_only) failed=$(events dg_n dirty_generated_reap_failed)"; fi

# (o) DETACHED HEAD (symbolic-ref cannot name a branch): delivered by ancestry, so it is still reaped; no branch is
# touched or invented, and the commit stays in main
mk_dg_town dg_o "git checkout -q --detach && $DG_GEN"
run_dg dg_o "$DG_CLOSED"
dg_wt dg_o && bad "ga-he2c1u (o): detached delivered tree of a closed bead NOT reaped" || ok "ga-he2c1u (o): detached delivered tree of a closed bead REAPED"
[ "$(events dg_o reaped_dirty_generated_only)" = "1" ] && dg_br dg_o && [ "$(git -C "$TMP/dg_o" branch --list | wc -l | tr -d ' ')" = "2" ] \
  && ok "ga-he2c1u (o): the reap is logged once and no branch was deleted or created" \
  || bad "ga-he2c1u (o): detached reap — events=$(events dg_o reaped_dirty_generated_only) branches=$(git -C "$TMP/dg_o" branch --list | wc -l | tr -d ' ')"

# (m) the generated list is overridable (WORKTREE_REAPER_GENERATED_RE): narrowed to match nothing, the same tree is kept
mk_dg_town dg_m "$DG_GEN"
run_dg dg_m "$DG_CLOSED" WORKTREE_REAPER_GENERATED_RE='^nothing-matches$'
dg_kept dg_m "WORKTREE_REAPER_GENERATED_RE narrowed to match nothing"

# ══ ga-m5i7e6: a tree's age is its FRESHEST sign of life; "in use" is checked on EVERY removal path; pressure removes only MERGED trees ══
# Incident (21/10): in disk-pressure mode (age gate 12 h) the reaper removed six WORK trees of another repo at "13-14 h", one with a
# calibration agent inside. Three holes: (1) age = the mtime of the root DIRECTORY, which only moves when a top-level entry is added or
# removed — a battery writing under an ignored pesquisa/ never touches it; (2) _worktree_in_use was asked for MERGED trees only; (3)
# `git worktree remove` without --force refuses only a DIRTY tree and ignored files do not make one, so the outputs went with it.
# Every scenario here ages the WHOLE tree (dir, files, index; commits carry an old date) and turns ACTIVITY_SCAN on. Run against the
# pre-fix reaper they all fail except (b2)(c)(e)(l)(n)(k3)(r), which pin what must NOT change (and (s), whose outcome there is arbitrary: see its note below): disk is still freed (a merged tree, the
# ordinary age path, a dead-holder lock) and the old rules stay one knob away.
echo "── ga-m5i7e6: freshest-signal age, in-use on every path, pressure = merged only ──"
M5_OLD=2020-01-01T00:00:00Z
m5_mk() {   # <town> — a rig with origin/main (one OLD commit); pesquisa/ is excluded repo-wide so a tree holding it stays CLEAN
  local t="$TMP/$1"; mkdir -p "$t"; git init -q --bare "$TMP/$1-remote.git"; git init -q -b main "$t/rig"
  ( cd "$t/rig" && git remote add origin "$TMP/$1-remote.git" && echo a > a.txt && git add a.txt \
    && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm base \
    && git push -q origin main && git fetch -q origin && git remote set-head origin main \
    && echo 'pesquisa/' >> .git/info/exclude ) >/dev/null 2>&1
}
m5_age() {   # <tree> <hours> — backdate the root dir and everything inside it (not .git), plus the tree's own index
  local ts idx; ts="$(date -v-"$2"H +%Y%m%d%H%M 2>/dev/null || date -d "$2 hours ago" +%Y%m%d%H%M)"
  find "$1" -path "$1/.git" -prune -o -exec touch -h -t "$ts" {} + 2>/dev/null
  idx="$(git -C "$1" rev-parse --git-path index)"; case "$idx" in /*) : ;; *) idx="$1/$idx" ;; esac
  touch -t "$ts" "$idx" 2>/dev/null
}
m5_tree() {   # <town> <name> merged|unmerged — <town>/rig/crew/<name> holding an ignored pesquisa/out/battery.csv, every signal 14 h old
  local r="$TMP/$1/rig"
  ( cd "$r" && git worktree add -q "$r/crew/$2" -b "crew/m5/$2" main && cd "$r/crew/$2" && mkdir -p pesquisa/out && echo r1 > pesquisa/out/battery.csv \
    && { [ "$3" != unmerged ] || { echo b > b.txt && git add b.txt && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm ahead; }; } ) >/dev/null 2>&1
  m5_age "$r/crew/$2" 14
}
m5_run() { local t="$1"; shift; env WORKTREE_REAPER_ACTIVITY_SCAN=1 WORKTREE_REAPER_GT="$TMP/$t" WORKTREE_REAPER_LOG="$TMP/$t.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 "$@" bash "$REAPER" >/dev/null 2>&1; }
m5_has() { git -C "$TMP/$1/rig" worktree list --porcelain 2>/dev/null | grep -E "^worktree .*/crew/w\$" >/dev/null; }
m5_real() { ( cd "$TMP/$1/rig/crew/w" && pwd -P ); }
m5_kept() {   # <town> <label> [event] — the tree is still there (and, when given, the keep was logged exactly once under that event)
  if m5_has "$1" && { [ -z "${3:-}" ] || [ "$(events "$1" "$3")" = "1" ]; }; then ok "ga-m5i7e6 $2"
  else bad "ga-m5i7e6 $2 — present=$(m5_has "$1" && echo y || echo n) ${3:-event}=$([ -n "${3:-}" ] && events "$1" "$3" || echo -)"; fi
}
m5_gone() { if m5_has "$1"; then bad "ga-m5i7e6 $2 — tree still there"; else ok "ga-m5i7e6 $2"; fi; }
PRESS=WORKTREE_REAPER_PRESSURE_FREE_GB=99999   # free GiB is always below this → pressure (a box without `df -g` reads 99)

m5_mk m5a; m5_tree m5a w unmerged; m5_real m5a > "$TMP/m5a.lsof"
m5_run m5a "$PRESS" WORKTREE_REAPER_FAKE_LSOF="$TMP/m5a.lsof"
m5_kept m5a "(a): unmerged tree, 14 h idle, a live process inside, pressure mode → KEPT, kept_in_use logged" kept_in_use

m5_mk m5b; m5_tree m5b w unmerged; m5_run m5b "$PRESS"
m5_kept m5b "(b): unmerged tree, nobody inside, pressure mode → KEPT, kept_pressure_unmerged logged once" kept_pressure_unmerged
grep -q '"event":"kept_pressure_unmerged".*"size_kb":[0-9]' "$TMP/m5b.jsonl" && ok "ga-m5i7e6 (b): the pressure keep names the tree's size" || bad "ga-m5i7e6 (b): no numeric size_kb on kept_pressure_unmerged"
m5_mk m5b2; m5_tree m5b2 w unmerged; m5_run m5b2 "$PRESS" WORKTREE_REAPER_PRESSURE_REAP_UNMERGED=1
m5_gone m5b2 "(b2): WORKTREE_REAPER_PRESSURE_REAP_UNMERGED=1 gives the old pressure rule back (reaped)"

m5_mk m5c; m5_tree m5c w merged; m5_run m5c "$PRESS"
if ! m5_has m5c && [ "$(events m5c reaped_pool)" = "1" ]; then ok "ga-m5i7e6 (c): MERGED tree, nobody inside, pressure mode → reaped (disk is still freed)"; else bad "ga-m5i7e6 (c): merged idle tree under pressure — present=$(m5_has m5c && echo y || echo n)"; fi

m5_mk m5d; m5_tree m5d w unmerged; touch "$TMP/m5d/rig/crew/w/pesquisa/out/battery.csv"; m5_run m5d
m5_kept m5d "(d): root dir 14 h old but a file two levels down written just now → KEPT (age is the freshest sign)"
m5_mk m5e; m5_tree m5e w unmerged; m5_run m5e
m5_gone m5e "(e): unmerged tree idle in EVERY signal, normal mode → reaped (the ordinary age path still frees disk)"
m5_mk m5l; m5_tree m5l w unmerged; touch "$TMP/m5l/rig/crew/w/pesquisa/out/battery.csv"; m5_run m5l WORKTREE_REAPER_ACTIVITY_SCAN=0
m5_gone m5l "(l): WORKTREE_REAPER_ACTIVITY_SCAN=0 → the old directory-mtime rule (the tree of (d) is reaped)"
m5_mk m5o; m5_tree m5o w unmerged; touch "$TMP/m5o/rig/crew/w/pesquisa/out/battery.csv"
env -u WORKTREE_REAPER_ACTIVITY_SCAN WORKTREE_REAPER_GT="$TMP/m5o" WORKTREE_REAPER_LOG="$TMP/m5o.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 bash "$REAPER" >/dev/null 2>&1
m5_kept m5o "(d2): ACTIVITY_SCAN unset (the default) → the tree of (d) is KEPT"
m5_mk m5p; m5_tree m5p w unmerged; touch "$TMP/m5p/rig/crew/w/pesquisa/out/battery.csv"; m5_run m5p WORKTREE_REAPER_ACTIVITY_SCAN=yes
m5_kept m5p "(d3): a garbage ACTIVITY_SCAN value reads as 'scan', never as the old rule → the tree of (d) is KEPT"

m5_mk m5f; m5_tree m5f w unmerged; touch "$(git -C "$TMP/m5f/rig/crew/w" rev-parse --git-path index)"; m5_run m5f
m5_kept m5f "(f): only the tree's own index is fresh (a git command just ran in it) → KEPT"
m5_mk m5g; m5_tree m5g w unmerged
( cd "$TMP/m5g/rig/crew/w" && echo c > c.txt && git add c.txt && git commit -qm recent ) >/dev/null 2>&1; m5_age "$TMP/m5g/rig/crew/w" 14
m5_run m5g
m5_kept m5g "(g): only the HEAD commit is fresh (dir, files and index 14 h old) → KEPT"

m5_mk m5h; m5_tree m5h w unmerged; echo "$(m5_real m5h)/pesquisa/out/battery.csv" > "$TMP/m5h.lsof"; m5_run m5h WORKTREE_REAPER_FAKE_LSOF="$TMP/m5h.lsof"
m5_kept m5h "(h): a process has an OPEN FILE inside (its cwd is elsewhere) → KEPT, kept_in_use logged" kept_in_use
m5_mk m5i; m5_tree m5i w unmerged
cat > "$FAKEBIN/lsof" <<EOF
#!/usr/bin/env bash
# the open file shows only when lsof is NOT narrowed to cwd: the real _worktree_in_use must ask for every fd
case "\$*" in *"-d cwd"*) echo "n/elsewhere" ;; *) echo "n/elsewhere"; echo "n$(m5_real m5i)/pesquisa/out/battery.csv" ;; esac
EOF
chmod +x "$FAKEBIN/lsof"
env -u WORKTREE_REAPER_FAKE_LSOF PATH="$FAKEBIN:$PATH" WORKTREE_REAPER_ACTIVITY_SCAN=1 WORKTREE_REAPER_GT="$TMP/m5i" WORKTREE_REAPER_LOG="$TMP/m5i.jsonl" \
  WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 bash "$REAPER" >/dev/null 2>&1
m5_kept m5i "(i): the REAL lsof path asks for every open file, not just the cwd → tree with an open file KEPT" kept_in_use

m5_mk m5j; m5_tree m5j w unmerged; mkdir -p "$TMP/m5j-bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/m5j-bin/find"; chmod +x "$TMP/m5j-bin/find"
m5_run m5j PATH="$TMP/m5j-bin:$PATH"
m5_kept m5j "(j): the walk inside the tree FAILS → unknown is not old: KEPT, kept_activity_unknown logged" kept_activity_unknown

# (m)(n) a pid-confirmed ZOMBIE lock holder says nothing about OTHER processes working in the tree, and its reap is `remove -f -f`
M5_PS="$TMP/m5_ps.txt"; echo "1001 dead 0 0" > "$M5_PS"
m5_mk m5m; m5_tree m5m w unmerged; git -C "$TMP/m5m/rig" worktree lock --reason "claude agent agent-m5 pid 1001 start x" "$TMP/m5m/rig/crew/w"
m5_real m5m > "$TMP/m5m.lsof"; m5_run m5m WORKTREE_REAPER_FAKE_PS="$M5_PS" WORKTREE_REAPER_FAKE_LSOF="$TMP/m5m.lsof"
m5_kept m5m "(m): lock holder is a dead pid BUT another process is inside the tree → KEPT, kept_zombie_lock_in_use logged" kept_zombie_lock_in_use
m5_mk m5n; m5_tree m5n w unmerged; git -C "$TMP/m5n/rig" worktree lock --reason "claude agent agent-m5 pid 1001 start x" "$TMP/m5n/rig/crew/w"
m5_run m5n WORKTREE_REAPER_FAKE_PS="$M5_PS"
m5_gone m5n "(n): the same dead-holder lock with nobody inside → reaped (positive control: the zombie reap itself still works)"

# (k) loop 1 (the town's own .gc-worktrees) has the same two checks: a live process, or pressure with an unmerged tree
m5_town1() {   # <town> — the TOWN is the repo; one unmerged tree <town>/.gc-worktrees/x, every signal 14 h old
  local t="$TMP/$1"; git init -q --bare "$TMP/$1-remote.git"; git init -q -b main "$t"
  ( cd "$t" && git remote add origin "$TMP/$1-remote.git" && echo a > a.txt && git add a.txt && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm base \
    && git push -q origin main && git fetch -q origin && git remote set-head origin main && echo 'pesquisa/' >> .git/info/exclude && mkdir -p .gc-worktrees \
    && git worktree add -q "$t/.gc-worktrees/x" -b w/x main && cd "$t/.gc-worktrees/x" && mkdir pesquisa && echo r > pesquisa/o.csv \
    && echo b > b.txt && git add b.txt && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm ahead ) >/dev/null 2>&1
  m5_age "$t/.gc-worktrees/x" 14
}
m5_town1 m5k; (cd "$TMP/m5k/.gc-worktrees/x" && pwd -P) > "$TMP/m5k.lsof"
m5_run m5k WORKTREE_REAPER_FAKE_LSOF="$TMP/m5k.lsof"
if [ -d "$TMP/m5k/.gc-worktrees/x" ] && [ "$(events m5k kept_in_use)" = "1" ]; then ok "ga-m5i7e6 (k): town .gc-worktrees loop — unmerged tree with a live process inside → KEPT, kept_in_use logged"
else bad "ga-m5i7e6 (k): town loop in-use — present=$([ -d "$TMP/m5k/.gc-worktrees/x" ] && echo y || echo n) kept_in_use=$(events m5k kept_in_use)"; fi
m5_town1 m5k2; m5_run m5k2 "$PRESS"
if [ -d "$TMP/m5k2/.gc-worktrees/x" ] && [ "$(events m5k2 kept_pressure_unmerged)" = "1" ]; then ok "ga-m5i7e6 (k): town .gc-worktrees loop — unmerged tree under pressure → KEPT, kept_pressure_unmerged logged"
else bad "ga-m5i7e6 (k): town loop pressure — present=$([ -d "$TMP/m5k2/.gc-worktrees/x" ] && echo y || echo n) event=$(events m5k2 kept_pressure_unmerged)"; fi

# (k2)(k3) loop 1 and a LOCKED unmerged tree: the guard leaves it to the lock contract (as the pool loop does), in use or not, pressure or not
m5_town1 m5q; git -C "$TMP/m5q" worktree lock --reason "claude agent agent-m5 pid 1001 start x" "$TMP/m5q/.gc-worktrees/x"
(cd "$TMP/m5q/.gc-worktrees/x" && pwd -P) > "$TMP/m5q.lsof"
m5_run m5q WORKTREE_REAPER_FAKE_PS="$M5_PS" WORKTREE_REAPER_FAKE_LSOF="$TMP/m5q.lsof"
if [ -d "$TMP/m5q/.gc-worktrees/x" ] && [ "$(events m5q kept_zombie_lock_in_use)" = "1" ]; then ok "ga-m5i7e6 (k2): town loop — dead lock holder but another process inside → KEPT, kept_zombie_lock_in_use logged"
else bad "ga-m5i7e6 (k2): town loop zombie-in-use — present=$([ -d "$TMP/m5q/.gc-worktrees/x" ] && echo y || echo n) kept_zombie_lock_in_use=$(events m5q kept_zombie_lock_in_use)"; fi
m5_town1 m5r; git -C "$TMP/m5r" worktree lock --reason "claude agent agent-m5 pid 1001 start x" "$TMP/m5r/.gc-worktrees/x"
m5_run m5r "$PRESS" WORKTREE_REAPER_FAKE_PS="$M5_PS"
if [ ! -d "$TMP/m5r/.gc-worktrees/x" ]; then ok "ga-m5i7e6 (k3): town loop — the same dead-holder lock, nobody inside, PRESSURE → reaped (the pressure keep does not shadow the lock contract)"
else bad "ga-m5i7e6 (k3): town loop dead-holder lock under pressure — tree still there, kept_pressure_unmerged=$(events m5r kept_pressure_unmerged)"; fi

# (o) the tree's own root directory cannot be stat'ed: unknown is not "since 1970" (pressure would read that as ancient and keep the tree for
# ANOTHER reason, so the event is what tells them apart) → KEPT, kept_activity_unknown. The fake stat fails for that one path, anything else is the real one.
m5_mk m5s; m5_tree m5s w unmerged; mkdir -p "$TMP/m5s-bin"
printf '#!/bin/sh\nfor a in "$@"; do l="$a"; done\ncase "$l" in */crew/w) exit 1 ;; esac\nexec /usr/bin/stat "$@"\n' > "$TMP/m5s-bin/stat"; chmod +x "$TMP/m5s-bin/stat"
m5_run m5s "$PRESS" PATH="$TMP/m5s-bin:$PATH"
m5_kept m5s "(o): the tree's root directory cannot be read (stat fails) → unknown is not 1970: KEPT, kept_activity_unknown logged" kept_activity_unknown

# (p) the same unknown-is-kept rule in loop 1: the walk inside the tree fails
m5_town1 m5t; mkdir -p "$TMP/m5t-bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/m5t-bin/find"; chmod +x "$TMP/m5t-bin/find"
m5_run m5t PATH="$TMP/m5t-bin:$PATH"
if [ -d "$TMP/m5t/.gc-worktrees/x" ] && [ "$(events m5t kept_activity_unknown)" = "1" ]; then ok "ga-m5i7e6 (p): town loop — the walk inside the tree FAILS → KEPT, kept_activity_unknown logged"
else bad "ga-m5i7e6 (p): town loop unknown — present=$([ -d "$TMP/m5t/.gc-worktrees/x" ] && echo y || echo n) kept_activity_unknown=$(events m5t kept_activity_unknown)"; fi

# ── ga-m5i7e6 gate-feedback (fix-attempt 1 FAILED review): the "in use" guard answered "free" for a live process on the real lsof ──
# `lsof -Fn` prints ~1.7 MB on the mini (the old `-d cwd -Fn` ~19 KB). _worktree_in_use piped that into an awk that `exit`ed at its first
# match; printf died of SIGPIPE (141), `set -o pipefail` made 141 the function's return, and every caller read it as "not in use".
# Scenarios (a)(h)(k)(m) use the FAKE_LSOF file seam (no pipe) and (i) a 2-line stub (nothing to break the pipe), so none of them could
# see it. These feed the real function an lsof that prints far more than a pipe holds (the premise is asserted, not assumed):
#   (q) the live process's line comes FIRST in a ~450 KB listing → the tree is KEPT and kept_in_use is logged (fails on the shipped
#       fix-attempt 0: the tree is reaped); (r) control, the same listing without the process → still reaped (disk is still freed);
#   (s) the real lsof and a real `sleep` whose cwd is inside the tree → KEPT. Realism, not a pin: on attempt 0 it passed or failed from
#       one run to the next, because whether the process is caught depends on where its lines fall in the real listing (the arbitrariness
#       the reviewer measured); (q) and (t1) are the deterministic pins. (t) the function alone, 3 calls each: (t1) match FIRST → in use
#       every time (fails on attempt 0, rc 141); (t4) an awk that fails (neither 0 nor 1) reads as "in use", never "free" (fails on
#       attempt 0); (t2) match LAST and (t3) no match are controls that pass on attempt 0 too: a late match is still found, and "no
#       match" is still the one answer that reads as free.
M5_BIG="$TMP/m5_big_filler.txt"
awk 'BEGIN { for (i = 0; i < 6000; i++) print "n/Users/someone/unrelated/path/" i "/padding/padding/padding/padding/padding" }' > "$M5_BIG"
M5_BIG_N=$(( $(wc -c < "$M5_BIG") ))
if [ "$M5_BIG_N" -gt 200000 ]; then ok "ga-m5i7e6 (q)-(t) premise: the stub listing is $M5_BIG_N bytes (> 200 KB, far past a pipe buffer)"
else bad "ga-m5i7e6 (q)-(t) premise: the stub listing is only $M5_BIG_N bytes — too small to break a pipe, so (q)-(t) would pass on the broken code"; fi
m5_stub() {   # <name> first|last|none <tree-path> — $TMP/<name>-bin/lsof prints the filler with <tree-path>'s file as an `n` line at the start, at the end, or not at all
  mkdir -p "$TMP/$1-bin"
  { [ "$2" != first ] || printf 'p1\nn%s/pesquisa/out/battery.csv\n' "$3"; cat "$M5_BIG"; [ "$2" != last ] || printf 'p2\nn%s/pesquisa/out/battery.csv\n' "$3"; } > "$TMP/$1.out"
  printf '#!/usr/bin/env bash\ncat "%s"\n' "$TMP/$1.out" > "$TMP/$1-bin/lsof"; chmod +x "$TMP/$1-bin/lsof"
}

m5_mk m5q; m5_tree m5q w unmerged; m5_stub m5q first "$(m5_real m5q)"
m5_run m5q WORKTREE_REAPER_FAKE_LSOF= PATH="$TMP/m5q-bin:$PATH"
m5_kept m5q "(q): the REAL _worktree_in_use, a ~450 KB lsof listing with the live process FIRST → unmerged 14 h tree KEPT, kept_in_use logged" kept_in_use
m5_mk m5r; m5_tree m5r w unmerged; m5_stub m5r none "$(m5_real m5r)"
m5_run m5r WORKTREE_REAPER_FAKE_LSOF= PATH="$TMP/m5r-bin:$PATH"
m5_gone m5r "(r): the same ~450 KB listing WITHOUT the process → reaped (control: a big listing alone does not freeze the reaper)"

if command -v lsof >/dev/null 2>&1; then
  m5_mk m5s; m5_tree m5s w unmerged
  ( cd "$(m5_real m5s)/pesquisa/out" && exec sleep 60 ) & M5_SLEEP=$!
  sleep 0.5
  m5_run m5s WORKTREE_REAPER_FAKE_LSOF=
  kill "$M5_SLEEP" 2>/dev/null; wait "$M5_SLEEP" 2>/dev/null
  m5_kept m5s "(s): the real lsof and a real process with its cwd inside → unmerged 14 h tree KEPT, kept_in_use logged" kept_in_use
else echo "  - ga-m5i7e6 (s) skipped: no lsof on this machine"; fi

m5_fn="$(awk '/^_worktree_in_use\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$REAPER")"
m5_call() {   # <bindir> <path> — rc of the REAL function in its own `set -o pipefail` shell, <bindir> first on PATH, the file seam off
  ( set -uo pipefail; unset WORKTREE_REAPER_FAKE_LSOF; PATH="$1:$PATH"; eval "$m5_fn"; _worktree_in_use "$2" ) >/dev/null 2>&1
}
if [ -z "$m5_fn" ]; then bad "ga-m5i7e6 (t): could not extract _worktree_in_use from the reaper (renamed?) — the function-level checks would test nothing"
else
  M5_P="$TMP/m5-fn-probe/tree"   # the function only compares strings, so the path need not exist: no dependence on a scenario tree surviving
  m5_stub m5v first "$M5_P"; m5_stub m5w last "$M5_P"; m5_stub m5x none "$M5_P"
  m5_call "$TMP/m5v-bin" "$M5_P"; t1=$?; m5_call "$TMP/m5v-bin" "$M5_P"; t2=$?; m5_call "$TMP/m5v-bin" "$M5_P"; t3=$?
  if [ "$t1$t2$t3" = "000" ]; then ok "ga-m5i7e6 (t1): match first in a ~450 KB listing → in use (rc 0) on 3 calls out of 3"
  else bad "ga-m5i7e6 (t1): match first in a big listing gave rc $t1/$t2/$t3 (want 0/0/0; 141 = SIGPIPE read as 'free')"; fi
  m5_call "$TMP/m5w-bin" "$M5_P"; t4=$?
  if [ "$t4" = 0 ]; then ok "ga-m5i7e6 (t2): match LAST in a ~450 KB listing → in use (the answer does not depend on where the match falls)"
  else bad "ga-m5i7e6 (t2): match last in a big listing gave rc $t4 (want 0)"; fi
  m5_call "$TMP/m5x-bin" "$M5_P"; t5=$?
  if [ "$t5" = 1 ]; then ok "ga-m5i7e6 (t3): no match in a ~450 KB listing → rc 1, the only answer that reads as free"
  else bad "ga-m5i7e6 (t3): no match in a big listing gave rc $t5 (want exactly 1)"; fi
  mkdir -p "$TMP/m5u-bin"; cp "$TMP/m5x-bin/lsof" "$TMP/m5u-bin/lsof"; printf '#!/bin/sh\nexit 2\n' > "$TMP/m5u-bin/awk"; chmod +x "$TMP/m5u-bin/awk"
  m5_call "$TMP/m5u-bin" "$M5_P"; t6=$?
  if [ "$t6" = 0 ]; then ok "ga-m5i7e6 (t4): awk itself fails (rc 2) → 'cannot tell' = in use, never free"
  else bad "ga-m5i7e6 (t4): a failing awk gave rc $t6 (want 0: only a clean rc 1 may read as free)"; fi
fi

# ══ ga-xpoj67: a file git IGNORES that is not known junk is DATA — never removed with its tree ══
# Follow-up of ga-m5i7e6 (its consequence 2): `git worktree remove` counts only tracked/untracked files as dirt, so a MERGED idle tree went with
# its ignored battery outputs (pesquisa/…) — the loss of 21/10. Every removal path now measures the ignored non-junk files first: some → KEPT,
# kept_ignored_data (size_kb + the 5 largest paths), locked or not; junk only (.venv, node_modules, __pycache__, …) → reaped as before.
# Against the pre-fix reaper (x1)(x1b)(x3)(x4)(x5)(x6)(x7)(x10)(x11) fail; (x2)(x2b)(x4b)(x8)(x9) pin what must NOT change: disk is still freed.
echo "── ga-xpoj67: ignored non-junk data is never removed with its tree ──"
xp_mk() { m5_mk "$1"; printf '%s\n' .venv/ node_modules/ __pycache__/ '*.pyc' .pytest_cache/ .mypy_cache/ build/ dist/ '*.dat' venv/ .ruff_cache/ .beads/ '*.swp' .DS_Store Thumbs.db .claude/settings.local.json >> "$TMP/$1/rig/.git/info/exclude"; }
xp_tree() {   # <town> merged|unmerged data|junk — crew/w as m5_tree makes it; junk swaps the ignored battery output for the known-junk list; aged 14 h again
  m5_tree "$1" w "$2"; [ "$3" = junk ] || return 0
  rm -rf "$TMP/$1/rig/crew/w/pesquisa"
  ( cd "$TMP/$1/rig/crew/w" && mkdir -p .venv/lib node_modules/p __pycache__ build dist .pytest_cache .mypy_cache && echo x > .venv/lib/a.py && echo x > node_modules/p/i.js \
    && echo x > __pycache__/m.pyc && echo x > build/o && echo x > dist/o && echo x > .pytest_cache/v && echo x > .mypy_cache/m ) >/dev/null 2>&1
  ( cd "$TMP/$1/rig/crew/w" && mkdir -p venv .ruff_cache .beads && echo x > venv/p && echo x > .ruff_cache/c && echo x > .beads/redirect && echo x > loose.pyc \
    && echo x > f.swp && echo x > .DS_Store && echo x > Thumbs.db ) >/dev/null 2>&1
  m5_age "$TMP/$1/rig/crew/w" 14
}
xp_run() { local t="$1"; shift; m5_run "$t" WORKTREE_REAPER_IGNORED_DATA_GUARD=1 "$@"; }
xp_lock() { git -C "$TMP/$1/rig" worktree lock --reason "claude agent agent-m5 pid 1001 start x" "$TMP/$1/rig/crew/w"; }   # the holder is the dead pid of $M5_PS
xp_kept() {    # <town> <label> <event> — the tree is still there and the keep was logged exactly once under that event
  if m5_has "$1" && [ "$(events "$1" "$3")" = "1" ]; then ok "ga-xpoj67 $2"; else bad "ga-xpoj67 $2 — present=$(m5_has "$1" && echo y || echo n) $3=$(events "$1" "$3")"; fi
}
xp_freed() {   # <town> <label> — the tree is gone and nothing was kept for its ignored files
  if ! m5_has "$1" && [ "$(events "$1" kept_ignored_data)" = "0" ]; then ok "ga-xpoj67 $2"; else bad "ga-xpoj67 $2 — present=$(m5_has "$1" && echo y || echo n) kept_ignored_data=$(events "$1" kept_ignored_data)"; fi
}

xp_mk xp1; xp_tree xp1 merged data; xp_run xp1
xp_kept xp1 "(x1): MERGED tree, idle 14 h, nobody inside, an ignored battery output in it → KEPT, kept_ignored_data logged once" kept_ignored_data
grep '"event":"kept_ignored_data"' "$TMP/xp1.jsonl" | grep -Eq '"size_kb":[1-9][0-9]*,"top":\[\{"path":"pesquisa/","kb":[1-9][0-9]*\}\]' \
  && ok "ga-xpoj67 (x1): the event names the total size and the ignored path" || bad "ga-xpoj67 (x1): event lacks size_kb/top: $(grep kept_ignored_data "$TMP/xp1.jsonl" | head -1)"
[ -f "$TMP/xp1/rig/crew/w/pesquisa/out/battery.csv" ] && ok "ga-xpoj67 (x1): the battery output is still on disk" || bad "ga-xpoj67 (x1): the battery output is gone"
xp_mk xp1b; xp_tree xp1b merged data; xp_run xp1b "$PRESS"
xp_kept xp1b "(x1b): the same tree in PRESSURE mode (merged trees go under pressure) → KEPT, kept_ignored_data" kept_ignored_data
xp_mk xp2; xp_tree xp2 merged junk; xp_run xp2
xp_freed xp2 "(x2): the same MERGED tree holding only .venv, node_modules, __pycache__, build, dist and the caches → reaped (disk recovery not regressed)"
xp_mk xp2b; xp_tree xp2b unmerged junk; xp_run xp2b
xp_freed xp2b "(x2b): an UNMERGED tree past the age gate with only that junk → reaped"
xp_mk xp3; xp_tree xp3 unmerged data; xp_run xp3
xp_kept xp3 "(x3): UNMERGED tree past the age gate (normal mode) with ignored data → KEPT, kept_ignored_data" kept_ignored_data

# (x4) a LOCKED tree: the holder is a dead pid (the zombie reap is `remove -f -f`) → KEPT with its lock; with junk only the same lock is reaped
xp_mk xp4; xp_tree xp4 unmerged data; xp_lock xp4; xp_run xp4 WORKTREE_REAPER_FAKE_PS="$M5_PS"
if m5_has xp4 && [ "$(events xp4 kept_ignored_data)" = "1" ] && [ "$(events xp4 reaped_zombie_lock)" = "0" ] \
   && [ "$(git -C "$TMP/xp4/rig" worktree list --porcelain | grep -c '^locked')" = "1" ] \
   && grep '"event":"kept_ignored_data"' "$TMP/xp4.jsonl" | grep -q '"locked":true'; then ok "ga-xpoj67 (x4): dead-holder lock, ignored data inside → KEPT, lock untouched, kept_ignored_data logged with locked:true"
else bad "ga-xpoj67 (x4): zombie lock + ignored data — present=$(m5_has xp4 && echo y || echo n) kept_ignored_data=$(events xp4 kept_ignored_data) reaped_zombie_lock=$(events xp4 reaped_zombie_lock)"; fi
xp_mk xp4b; xp_tree xp4b unmerged junk; xp_lock xp4b; xp_run xp4b WORKTREE_REAPER_FAKE_PS="$M5_PS"
xp_freed xp4b "(x4b): the same dead-holder lock with only junk inside → reaped (the zombie reap itself still works)"

# (x4c) a LOCKED tree that is also MERGED: _keep_unsafe keeps it before the lock contract is ever asked, and the event must still say the tree is locked
xp_mk xp4c; xp_tree xp4c merged data; xp_lock xp4c; xp_run xp4c WORKTREE_REAPER_FAKE_PS="$M5_PS"
if m5_has xp4c && [ "$(events xp4c kept_ignored_data)" = "1" ] && [ "$(events xp4c reaped_zombie_lock)" = "0" ] \
   && [ "$(git -C "$TMP/xp4c/rig" worktree list --porcelain | grep -c '^locked')" = "1" ] \
   && grep '"event":"kept_ignored_data"' "$TMP/xp4c.jsonl" | grep -q '"locked":true'; then ok "ga-xpoj67 (x4c): MERGED tree with a dead-holder lock and ignored data → KEPT, lock untouched, event says locked:true"
else bad "ga-xpoj67 (x4c): merged + locked + ignored data — present=$(m5_has xp4c && echo y || echo n) kept_ignored_data=$(events xp4c kept_ignored_data) event=$(grep kept_ignored_data "$TMP/xp4c.jsonl" 2>/dev/null | head -1)"; fi
xp_mk xp4d; xp_tree xp4d merged junk; xp_lock xp4d; xp_run xp4d WORKTREE_REAPER_FAKE_PS="$M5_PS"
xp_freed xp4d "(x4d): the same MERGED dead-holder lock with only junk inside → reaped (control: the guard does not hold a clean locked tree)"
# (x4e) and an UNLOCKED tree says locked:false (the field is git's answer, not a constant)
xp_mk xp4e; xp_tree xp4e merged data; xp_run xp4e
grep '"event":"kept_ignored_data"' "$TMP/xp4e.jsonl" | grep -q '"locked":false' && ok "ga-xpoj67 (x4e): an unlocked tree's event says locked:false" || bad "ga-xpoj67 (x4e): event: $(grep kept_ignored_data "$TMP/xp4e.jsonl" 2>/dev/null | head -1)"

# (x5) a lock nobody can name, unmerged work, the BEAD-CLOSED proof (`remove -f -f`): clean + aged + unused + bead closed → reaped; ignored data in it → KEPT first
mk_bc_rig xp5 'echo pesquisa/ >> "$(git rev-parse --git-common-dir)/info/exclude"; mkdir pesquisa; echo r > pesquisa/o.csv'
run_bc xp5 "[$(bc_bead "$BC_ID" closed 10)]" WORKTREE_REAPER_IGNORED_DATA_GUARD=1
if bc_wt xp5 && bc_br xp5 && [ "$(events xp5 kept_ignored_data)" = "1" ] && [ "$(events xp5 reaped_locked_unparseable_bead_closed)" = "0" ]; then ok "ga-xpoj67 (x5): closed-bead proof on a locked tree holding ignored data → KEPT, kept_ignored_data (tree and branch intact)"
else bad "ga-xpoj67 (x5): bead-closed lock + ignored data — wt=$(bc_wt xp5 && echo y || echo n) kept_ignored_data=$(events xp5 kept_ignored_data) reaped_bc=$(events xp5 reaped_locked_unparseable_bead_closed)"; fi

# (x6) loop 1 (the town's own .gc-worktrees) asks the same question
m5_town1 xp6; xp_run xp6
if [ -d "$TMP/xp6/.gc-worktrees/x" ] && [ "$(events xp6 kept_ignored_data)" = "1" ]; then ok "ga-xpoj67 (x6): town .gc-worktrees loop — unmerged tree with ignored data → KEPT, kept_ignored_data logged"
else bad "ga-xpoj67 (x6): town loop — present=$([ -d "$TMP/xp6/.gc-worktrees/x" ] && echo y || echo n) kept_ignored_data=$(events xp6 kept_ignored_data)"; fi

# (x7) the listing of ignored files FAILS: that is not "none" → KEPT, and the event says it could not tell
xp_mk xp7; xp_tree xp7 merged data; mkdir -p "$TMP/xp7-bin"
printf '#!/bin/sh\ncase " $* " in *" ls-files "*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v git)" > "$TMP/xp7-bin/git"; chmod +x "$TMP/xp7-bin/git"
xp_run xp7 PATH="$TMP/xp7-bin:$PATH"
xp_kept xp7 "(x7): listing the ignored files fails → unknown is not 'none': KEPT, kept_ignored_data_unknown logged" kept_ignored_data_unknown
grep '"event":"kept_ignored_data_unknown"' "$TMP/xp7.jsonl" | grep -q '"size_kb":null,"top":\[\]' && ok "ga-xpoj67 (x7): the unknown event says size null, not 0" || bad "ga-xpoj67 (x7): unknown event: $(grep unknown "$TMP/xp7.jsonl" | head -1)"

# (x8) the knob: 0 = the old rule (reaped); a garbage value and the unset default = guard on
xp_mk xp8; xp_tree xp8 merged data; xp_run xp8 WORKTREE_REAPER_IGNORED_DATA_GUARD=0
xp_freed xp8 "(x8): WORKTREE_REAPER_IGNORED_DATA_GUARD=0 gives the old rule back (the tree of (x1) is reaped)"
xp_mk xp8b; xp_tree xp8b merged data; m5_run xp8b WORKTREE_REAPER_IGNORED_DATA_GUARD=yes
xp_kept xp8b "(x8b): a garbage guard value reads as 'on', never as the old rule → KEPT" kept_ignored_data
xp_mk xp8c; xp_tree xp8c merged data
env -u WORKTREE_REAPER_IGNORED_DATA_GUARD WORKTREE_REAPER_ACTIVITY_SCAN=1 WORKTREE_REAPER_GT="$TMP/xp8c" WORKTREE_REAPER_LOG="$TMP/xp8c.jsonl" WORKTREE_REAPER_STALE_HOURS=1 WORKTREE_REAPER_ENABLED=1 bash "$REAPER" >/dev/null 2>&1
xp_kept xp8c "(x8c): the guard variable UNSET (the shipped default) → the tree of (x1) is KEPT" kept_ignored_data

# (x9) the limit: ignored data below WORKTREE_REAPER_IGNORED_MIN_KB does not hold a tree
xp_mk xp9; xp_tree xp9 merged data; xp_run xp9 WORKTREE_REAPER_IGNORED_MIN_KB=99999999
xp_freed xp9 "(x9): ignored data below WORKTREE_REAPER_IGNORED_MIN_KB → reaped"

# (x10) a DIRTY tree takes the preserve path, whose snapshot leaves ignored files out and then force-removes: the guard comes first
xp_mk xp10; xp_tree xp10 unmerged data; echo wip > "$TMP/xp10/rig/crew/w/dirty.txt"; m5_age "$TMP/xp10/rig/crew/w" 14; xp_run xp10
if m5_has xp10 && [ -f "$TMP/xp10/rig/crew/w/dirty.txt" ] && [ -f "$TMP/xp10/rig/crew/w/pesquisa/out/battery.csv" ] \
   && [ "$(events xp10 kept_ignored_data)" = "1" ] && [ "$(events xp10 reaped_dirty_preserved)" = "0" ]; then ok "ga-xpoj67 (x10): dirty tree with ignored data → KEPT whole (no preserve-and-force), kept_ignored_data logged"
else bad "ga-xpoj67 (x10): dirty + ignored data — present=$(m5_has xp10 && echo y || echo n) kept_ignored_data=$(events xp10 kept_ignored_data) reaped_dirty_preserved=$(events xp10 reaped_dirty_preserved)"; fi

# (x11) seven ignored data files of 8..56 KiB: the event carries the total and the FIVE largest, largest first
xp_mk xp11; m5_tree xp11 w merged
( cd "$TMP/xp11/rig/crew/w" && rm -rf pesquisa && for i in 1 2 3 4 5 6 7; do dd if=/dev/zero of="d$i.dat" bs=1024 count=$((i*8)) 2>/dev/null; done ); m5_age "$TMP/xp11/rig/crew/w" 14
xp_run xp11
L11="$(grep '"event":"kept_ignored_data"' "$TMP/xp11.jsonl" 2>/dev/null)"
if printf '%s' "$L11" | grep -Eq '"size_kb":[0-9]+,"top":\[\{"path":"d7\.dat","kb":[0-9]+\},\{"path":"d6\.dat","kb":[0-9]+\},\{"path":"d5\.dat","kb":[0-9]+\},\{"path":"d4\.dat","kb":[0-9]+\},\{"path":"d3\.dat","kb":[0-9]+\}\]' \
   && ! printf '%s' "$L11" | grep -Eq 'd[12]\.dat'; then ok "ga-xpoj67 (x11): top = the 5 largest ignored paths, largest first (d7..d3), the 2 smallest left out"
else bad "ga-xpoj67 (x11): top-5 wrong: ${L11:-<no kept_ignored_data event>}"; fi

# (x12) du cannot size an entry git listed: unreadable is not empty — it counts 1 KiB and the tree stays
xp_mk xp12; xp_tree xp12 merged data; mkdir -p "$TMP/xp12-bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/xp12-bin/du"; chmod +x "$TMP/xp12-bin/du"
xp_run xp12 PATH="$TMP/xp12-bin:$PATH"
xp_kept xp12 "(x12): du cannot size the ignored entry → it counts 1 KiB and the tree is KEPT (unreadable is not empty)" kept_ignored_data

# (x14) past the 200th entry the scan stops running du and each entry counts 1 KiB: 205 EMPTY ignored files and one data file listed after them still hold the tree
xp_mk xp14; m5_tree xp14 w merged
( cd "$TMP/xp14/rig/crew/w" && rm -rf pesquisa && for i in $(seq -f '%03g' 1 205); do : > "a$i.dat"; done && echo r > z.dat ) >/dev/null 2>&1; m5_age "$TMP/xp14/rig/crew/w" 14
mkdir -p "$TMP/xp14-bin"; printf '#!/bin/sh\necho x >> "%s"\nexec %s "$@"\n' "$TMP/xp14.du" "$(command -v du)" > "$TMP/xp14-bin/du"; chmod +x "$TMP/xp14-bin/du"   # counts its calls
xp_run xp14 PATH="$TMP/xp14-bin:$PATH"
xp_kept xp14 "(x14): 205 empty ignored files and a data file after them (past the 200-entry du cap) → KEPT" kept_ignored_data
N14="$(wc -l < "$TMP/xp14.du" 2>/dev/null | tr -d ' ')"
if [ "${N14:-0}" -ge 1 ] && [ "${N14:-0}" -le 200 ]; then ok "ga-xpoj67 (x14): du ran ${N14} times for 206 entries — never more than 200 (the cost is bounded)"; else bad "ga-xpoj67 (x14): du calls = ${N14:-?}, want 1..200"; fi

# (x13) junk is matched by directory NAME, not by substring: an ignored rebuild/ next to the junk list is data, and only it is reported
xp_mk xp13; echo 'rebuild/' >> "$TMP/xp13/rig/.git/info/exclude"; xp_tree xp13 merged junk
mkdir -p "$TMP/xp13/rig/crew/w/rebuild"; echo r > "$TMP/xp13/rig/crew/w/rebuild/o.csv"; m5_age "$TMP/xp13/rig/crew/w" 14; xp_run xp13
xp_kept xp13 "(x13): an ignored rebuild/ among the junk (build/, dist/, .venv/ …) is data → KEPT, kept_ignored_data" kept_ignored_data
grep '"event":"kept_ignored_data"' "$TMP/xp13.jsonl" | grep -Eq '"top":\[\{"path":"rebuild/","kb":[1-9][0-9]*\}\]' && ok "ga-xpoj67 (x13): only rebuild/ is reported, the junk is not" || bad "ga-xpoj67 (x13): top: $(grep kept_ignored_data "$TMP/xp13.jsonl" | head -1)"
# (x13b) WORKTREE_REAPER_IGNORED_JUNK_RE replaces the junk list
xp_mk xp13b; xp_tree xp13b merged data; xp_run xp13b WORKTREE_REAPER_IGNORED_JUNK_RE='(^|/)pesquisa(/|$)'
xp_freed xp13b "(x13b): WORKTREE_REAPER_IGNORED_JUNK_RE names pesquisa/ as junk → the tree of (x1) is reaped"

# (x2c) .claude/settings.local.json is ignored tool state beside TRACKED .claude files (this repo's own layout): junk by path → the tree is reaped
xp_mk xp2c; m5_tree xp2c w unmerged
( cd "$TMP/xp2c/rig/crew/w" && rm -rf pesquisa && mkdir -p .claude && echo k > .claude/keep.md && echo '{}' > .claude/settings.local.json && git add .claude/keep.md \
  && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm claude ) >/dev/null 2>&1; m5_age "$TMP/xp2c/rig/crew/w" 14; xp_run xp2c
xp_freed xp2c "(x2c): an ignored .claude/settings.local.json beside a tracked .claude/ file is junk → the tree is reaped"

# (x9b)(x9c) the limit is inclusive: a total equal to WORKTREE_REAPER_IGNORED_MIN_KB holds the tree, one KiB more of limit lets it go
xp_mk xp9b; xp_tree xp9b merged data; N9="$(du -sk "$TMP/xp9b/rig/crew/w/pesquisa" | awk '{print $1; exit}')"
xp_run xp9b WORKTREE_REAPER_IGNORED_MIN_KB="$N9"
xp_kept xp9b "(x9b): ignored data of exactly WORKTREE_REAPER_IGNORED_MIN_KB ($N9 KiB) → KEPT (the limit is inclusive)" kept_ignored_data
xp_mk xp9c; xp_tree xp9c merged data; xp_run xp9c WORKTREE_REAPER_IGNORED_MIN_KB=$((N9+1))
xp_freed xp9c "(x9c): the same data one KiB under the limit → reaped"
# (x9d) a limit that is not a number reads as the strictest one (1 KiB), never as "no limit": the tree is KEPT
xp_mk xp9d; xp_tree xp9d merged data; xp_run xp9d WORKTREE_REAPER_IGNORED_MIN_KB=abc
xp_kept xp9d "(x9d): a non-numeric WORKTREE_REAPER_IGNORED_MIN_KB reads as 1 KiB → the tree of (x1) is KEPT" kept_ignored_data
# (x9e)(x9f) 0 = every ignored non-junk entry holds the tree, even a file with no bytes in it; the default limit (1 KiB) lets an empty file go
xp_mk xp9e; m5_tree xp9e w merged; ( cd "$TMP/xp9e/rig/crew/w" && rm -rf pesquisa && : > empty.dat ) >/dev/null 2>&1; m5_age "$TMP/xp9e/rig/crew/w" 14; xp_run xp9e WORKTREE_REAPER_IGNORED_MIN_KB=0
xp_kept xp9e "(x9e): WORKTREE_REAPER_IGNORED_MIN_KB=0 → an ignored file with no bytes in it holds the tree" kept_ignored_data
xp_mk xp9f; m5_tree xp9f w merged; ( cd "$TMP/xp9f/rig/crew/w" && rm -rf pesquisa && : > empty.dat ) >/dev/null 2>&1; m5_age "$TMP/xp9f/rig/crew/w" 14; xp_run xp9f
xp_freed xp9f "(x9f): the same tree at the default limit → reaped (a file with no bytes is not data)"
# (x9g)(x9h) 0 holds an entry that EXISTS: a tree with only junk, or with nothing ignored at all, has none, so the limit 0 does not hold it either
xp_mk xp9g; xp_tree xp9g merged junk; xp_run xp9g WORKTREE_REAPER_IGNORED_MIN_KB=0
xp_freed xp9g "(x9g): WORKTREE_REAPER_IGNORED_MIN_KB=0 and only junk inside → reaped (0 is 'any entry', not 'even an empty listing')"
xp_mk xp9h; m5_tree xp9h w merged; ( cd "$TMP/xp9h/rig/crew/w" && rm -rf pesquisa ) >/dev/null 2>&1; m5_age "$TMP/xp9h/rig/crew/w" 14; xp_run xp9h WORKTREE_REAPER_IGNORED_MIN_KB=0
xp_freed xp9h "(x9h): WORKTREE_REAPER_IGNORED_MIN_KB=0 and nothing ignored at all → reaped"

# (x15) mktemp fails: the scan cannot even start — that is not 'nothing ignored': KEPT, kept_ignored_data_unknown
xp_mk xp15; xp_tree xp15 merged data; mkdir -p "$TMP/xp15-bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/xp15-bin/mktemp"; chmod +x "$TMP/xp15-bin/mktemp"
xp_run xp15 PATH="$TMP/xp15-bin:$PATH"
xp_kept xp15 "(x15): mktemp fails → KEPT, kept_ignored_data_unknown logged" kept_ignored_data_unknown

# (x16) a file name with a quote, a backslash and a space is escaped in the event, so the line stays one JSON object
xp_mk xp16; m5_tree xp16 w merged; ( cd "$TMP/xp16/rig/crew/w" && rm -rf pesquisa && printf r > 'a"b\c d.dat' ) >/dev/null 2>&1; m5_age "$TMP/xp16/rig/crew/w" 14; xp_run xp16
grep '"event":"kept_ignored_data"' "$TMP/xp16.jsonl" | grep -qF '"top":[{"path":"a\"b\\c d.dat","kb":' && ok "ga-xpoj67 (x16): quote, backslash and space in a file name are escaped in the event" || bad "ga-xpoj67 (x16): event: $(grep kept_ignored_data "$TMP/xp16.jsonl" 2>/dev/null | head -1)"

# ══ ga-1bfcda7: the pool session's own .claude/ settings files are tool state, not data ══
# Measured 27/10 (git 2.43): an ignored .claude/ FOLDER is ONE entry of `ls-files -o -i --directory` (".claude/"), so IGNORED_JUNK_RE — which named only
# .claude/settings.local.json, and could not look inside a folder entry — kept 15 wa-worker trees (~170 MB each) for a 4 KB .claude/settings.json. With a
# TRACKED file in .claude/ the settings files come one by one and were not junk either. Now .claude/settings*.json(.bak.*) is junk by path, and a folder
# entry named .claude/ is opened: only junk inside → dropped; any other file → the tree is kept and the event names THAT file; unreadable → unknown.
# Against the pre-fix reaper (c1)(c1b)(c2)(c3)(c4)(c5)(c6)(c7)(c8)(c9b)(c10)(c11)(c14)(c16a)(c16b)(c16c)(c16d) fail; (c9)(c15) pin what must NOT change.
echo "── ga-1bfcda7: an ignored .claude/ holding only the tool's settings files does not keep a tree ──"
cl_tree() {   # <town> merged|unmerged [file…] — crew/w with an ignored .claude/ FOLDER (info/exclude) holding the given files (paths below .claude/), no pesquisa/, aged 14 h
  local t="$1" k="$2" f; shift 2
  xp_mk "$t"; echo '.claude/' >> "$TMP/$t/rig/.git/info/exclude"; m5_tree "$t" w "$k"
  ( cd "$TMP/$t/rig/crew/w" && rm -rf pesquisa && mkdir -p .claude && for f in "$@"; do mkdir -p ".claude/$(dirname "$f")" && echo '{}' > ".claude/$f"; done ) >/dev/null 2>&1
  m5_age "$TMP/$t/rig/crew/w" 14
}
cl_b() {   # <town> [extra ignored file] — crew/w with a TRACKED .claude/keep.md; settings.json, settings.json.bak.<epoch> and settings.local.json ignored ONE BY ONE (no folder entry)
  local t="$1" x="${2:-}"
  xp_mk "$t"; printf '%s\n' .claude/settings.json '.claude/settings.json.bak.*' >> "$TMP/$t/rig/.git/info/exclude"; [ -z "$x" ] || echo ".claude/$x" >> "$TMP/$t/rig/.git/info/exclude"
  m5_tree "$t" w unmerged
  ( cd "$TMP/$t/rig/crew/w" && rm -rf pesquisa && mkdir -p .claude && echo k > .claude/keep.md && echo '{}' > .claude/settings.json && echo '{}' > .claude/settings.local.json \
    && echo '{}' > .claude/settings.json.bak.1793102038 && { [ -z "$x" ] || echo n > ".claude/$x"; } && git add .claude/keep.md \
    && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm claude ) >/dev/null 2>&1
  m5_age "$TMP/$t/rig/crew/w" 14
}
cl_kept() {   # <town> <label> <event> — the tree is still there and the keep was logged exactly once under that event
  if m5_has "$1" && [ "$(events "$1" "$3")" = "1" ]; then ok "ga-1bfcda7 $2"; else bad "ga-1bfcda7 $2 — present=$(m5_has "$1" && echo y || echo n) $3=$(events "$1" "$3")"; fi
}
cl_freed() {  # <town> <label> — the tree is gone and nothing was kept for its ignored files, known or unknown
  if ! m5_has "$1" && [ "$(events "$1" kept_ignored_data)" = "0" ] && [ "$(events "$1" kept_ignored_data_unknown)" = "0" ]; then ok "ga-1bfcda7 $2"
  else bad "ga-1bfcda7 $2 — present=$(m5_has "$1" && echo y || echo n) kept_ignored_data=$(events "$1" kept_ignored_data) unknown=$(events "$1" kept_ignored_data_unknown)"; fi
}
cl_top() {    # <town> <label> <path ERE> — the kept_ignored_data event names exactly ONE path and it is that one (the file inside .claude/, not the folder)
  local re='"top":\[\{"path":"'"$3"'","kb":[1-9][0-9]*\}\]'
  if grep '"event":"kept_ignored_data"' "$TMP/$1.jsonl" 2>/dev/null | grep -Eq "$re"; then ok "ga-1bfcda7 $2"; else bad "ga-1bfcda7 $2 — event: $(grep kept_ignored_data "$TMP/$1.jsonl" 2>/dev/null | head -1)"; fi
}

# (c1)(c1b)(c2) the bead's case: the ignored folder holds only the tool's own files → junk → the tree is reaped (normal mode, PRESSURE mode, with the .bak and the local file)
cl_tree cl1 merged settings.json; xp_run cl1
cl_freed cl1 "(c1): MERGED tree idle 14 h whose ignored .claude/ holds only settings.json → reaped (the 15 wa-worker trees of 27/10 were kept for 4 KB)"
cl_tree cl1b merged settings.json; xp_run cl1b "$PRESS"
cl_freed cl1b "(c1b): the same tree in PRESSURE mode → reaped"
cl_tree cl2 merged settings.json settings.local.json settings.json.bak.1793102038; xp_run cl2
cl_freed cl2 "(c2): settings.json + settings.local.json + settings.json.bak.<epoch> in the ignored .claude/ → all tool state → reaped"

# (c3)(c4) any other file in the folder is data: the tree is KEPT and the event names the FILE (not the folder, not the settings file beside it)
cl_tree cl3 merged settings.json notes.md; xp_run cl3
cl_kept cl3 "(c3): settings.json + a notes.md in the ignored .claude/ → the notes are data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl3 "(c3): the event names .claude/notes.md alone — not the folder, not settings.json" '\.claude/notes\.md'
[ -f "$TMP/cl3/rig/crew/w/.claude/notes.md" ] && ok "ga-1bfcda7 (c3): the notes are still on disk" || bad "ga-1bfcda7 (c3): the notes are gone"
cl_tree cl4 unmerged settings.json skills/x/SKILL.md; xp_run cl4
cl_kept cl4 "(c4): UNMERGED tree, a file in a subfolder of the ignored .claude/ → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl4 "(c4): the event names .claude/skills/x/SKILL.md" '\.claude/skills/x/SKILL\.md'

# (c5)(c6) the same files ignored ONE BY ONE beside a TRACKED .claude/ file (git lists each, the folder is no entry): junk by path; with another ignored file → kept
cl_b cl5; xp_run cl5
cl_freed cl5 "(c5): settings.json, settings.json.bak.<epoch> and settings.local.json ignored one by one beside a tracked .claude/keep.md → junk by path → reaped"
cl_b cl6 notes.md; xp_run cl6
cl_kept cl6 "(c6): the same plus an ignored .claude/notes.md → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl6 "(c6): the event names .claude/notes.md alone" '\.claude/notes\.md'

# (c7)(c8) opening the folder fails → unknown is not "only settings" (KEPT, kept_ignored_data_unknown); it reads EMPTY → nothing inside to lose (the entry is dropped, reaped)
cl_tree cl7 merged settings.json; mkdir -p "$TMP/cl7-bin"
printf '#!/bin/sh\ncase " $* " in *" -print0 "*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v find)" > "$TMP/cl7-bin/find"; chmod +x "$TMP/cl7-bin/find"
xp_run cl7 PATH="$TMP/cl7-bin:$PATH"
cl_kept cl7 "(c7): find cannot open the ignored .claude/ (rc 1) → unknown is not 'only settings': KEPT, kept_ignored_data_unknown logged" kept_ignored_data_unknown
grep '"event":"kept_ignored_data_unknown"' "$TMP/cl7.jsonl" 2>/dev/null | grep -q '"size_kb":null,"top":\[\]' && ok "ga-1bfcda7 (c7): the unknown event says size null, not 0" || bad "ga-1bfcda7 (c7): unknown event: $(grep unknown "$TMP/cl7.jsonl" 2>/dev/null | head -1)"
cl_tree cl8 merged settings.json; mkdir -p "$TMP/cl8-bin"
printf '#!/bin/sh\ncase " $* " in *" -print0 "*) exit 0 ;; esac\nexec %s "$@"\n' "$(command -v find)" > "$TMP/cl8-bin/find"; chmod +x "$TMP/cl8-bin/find"
xp_run cl8 PATH="$TMP/cl8-bin:$PATH"
cl_freed cl8 "(c8): the folder reads EMPTY (find prints nothing, rc 0) → nothing inside to lose: the entry is dropped and the tree is reaped"
# (c10) the rewritten list cannot replace the old one (a full disk would do it; here mv exits 1 — nothing else in the reaper calls mv): that is "could not tell"
# (KEPT, kept_ignored_data_unknown), not a quiet fall back to judging the old list, where the whole .claude/ folder is one entry again and the event names it
cl_tree cl10 merged settings.json notes.md; mkdir -p "$TMP/cl10-bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/cl10-bin/mv"; chmod +x "$TMP/cl10-bin/mv"
xp_run cl10 PATH="$TMP/cl10-bin:$PATH"
cl_kept cl10 "(c10): replacing the list with the rewritten one fails (mv rc 1) → KEPT, kept_ignored_data_unknown" kept_ignored_data_unknown
[ -f "$TMP/cl10/rig/crew/w/.claude/notes.md" ] && ok "ga-1bfcda7 (c10): the notes are still on disk" || bad "ga-1bfcda7 (c10): the notes are gone"

# (c9) WORKTREE_REAPER_IGNORED_JUNK_RE stays THE junk list: naming the folder itself as junk (the Mayor's by-hand relief of 27/10) skips it without opening it;
# a list that does not name the settings files makes them data again
cl_tree cl9 merged notes.md; xp_run cl9 WORKTREE_REAPER_IGNORED_JUNK_RE='(^|/)\.claude/$'
cl_freed cl9 "(c9): WORKTREE_REAPER_IGNORED_JUNK_RE naming .claude/ as junk → reaped without opening the folder, notes and all (the relief of 27/10 still works)"
cl_tree cl9b merged settings.json; xp_run cl9b WORKTREE_REAPER_IGNORED_JUNK_RE='(^|/)nothing$'
cl_kept cl9b "(c9b): a junk list that does not name the settings files → the file inside is data again → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl9b "(c9b): the event names .claude/settings.json" '\.claude/settings\.json'

# (c11) tool state beside real data: only the data is reported
xp_mk cl11; echo '.claude/' >> "$TMP/cl11/rig/.git/info/exclude"; m5_tree cl11 w merged
( cd "$TMP/cl11/rig/crew/w" && mkdir -p .claude && echo '{}' > .claude/settings.json ) >/dev/null 2>&1; m5_age "$TMP/cl11/rig/crew/w" 14; xp_run cl11
cl_kept cl11 "(c11): pesquisa/ (data) beside an ignored .claude/ with only settings.json → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl11 "(c11): the event names pesquisa/ alone — the settings file is not reported" 'pesquisa/'

# (c14) a .claude/ below a folder that has TRACKED files is an entry of its own (sub/.claude/) → opened the same way
xp_mk cl14; echo '.claude/' >> "$TMP/cl14/rig/.git/info/exclude"; m5_tree cl14 w unmerged
( cd "$TMP/cl14/rig/crew/w" && rm -rf pesquisa && mkdir -p sub/.claude && echo k > sub/keep.md && echo '{}' > sub/.claude/settings.json && git add sub/keep.md \
  && GIT_AUTHOR_DATE=$M5_OLD GIT_COMMITTER_DATE=$M5_OLD git commit -qm sub ) >/dev/null 2>&1; m5_age "$TMP/cl14/rig/crew/w" 14; xp_run cl14
cl_freed cl14 "(c14): sub/.claude/ (ignored, beside a tracked sub/keep.md) holding only settings.json → reaped"

# (c15) only a folder NAMED .claude is opened: an ignored x.claude/ is an ordinary folder → data
xp_mk cl15; echo 'x.claude/' >> "$TMP/cl15/rig/.git/info/exclude"; m5_tree cl15 w merged
( cd "$TMP/cl15/rig/crew/w" && rm -rf pesquisa && mkdir -p x.claude && echo '{}' > x.claude/settings.json ) >/dev/null 2>&1; m5_age "$TMP/cl15/rig/crew/w" 14; xp_run cl15
cl_kept cl15 "(c15): an ignored x.claude/ (not a folder named .claude) is data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl15 "(c15): the event names x.claude/ itself" 'x\.claude/'

# (c16a)(c16b) tool state is exactly settings*.json and settings*.json.bak.* directly in .claude/: a ".old" copy, and a settings.json one level down, are data
cl_tree cl16a merged settings.json settings.json.old; xp_run cl16a
cl_kept cl16a "(c16a): settings.json.old beside settings.json → data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl16a "(c16a): the event names .claude/settings.json.old alone" '\.claude/settings\.json\.old'
cl_tree cl16b merged sub/settings.json; xp_run cl16b
cl_kept cl16b "(c16b): .claude/sub/settings.json (not directly in .claude/) → data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl16b "(c16b): the event names .claude/sub/settings.json" '\.claude/sub/settings\.json'
# (c16c)(c16d) "settings*" is a FILE name: a folder called settings.d/ or settings.json.bak.d/ with files inside is not tool state
cl_tree cl16c merged settings.d/extra.json; xp_run cl16c
cl_kept cl16c "(c16c): .claude/settings.d/extra.json (a file inside a folder named settings*) → data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl16c "(c16c): the event names .claude/settings.d/extra.json" '\.claude/settings\.d/extra\.json'
cl_tree cl16d merged settings.json.bak.d/f.md; xp_run cl16d
cl_kept cl16d "(c16d): .claude/settings.json.bak.d/f.md (a file inside a folder named settings.json.bak.*) → data → KEPT, kept_ignored_data" kept_ignored_data
cl_top cl16d "(c16d): the event names .claude/settings.json.bak.d/f.md" '\.claude/settings\.json\.bak\.d/f\.md'

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
