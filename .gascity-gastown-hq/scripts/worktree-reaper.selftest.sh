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
# covered; an UNPARSEABLE lock is KEPT (fail-safe); the SIGTERM guard kills a crew claude proc
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
wt_exists()     { git -C "$RIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/$1\$"; }
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
git -C "$REMOTE" show refs/heads/crew/x/dirty:dirty.txt 2>/dev/null | grep -qx dirty \
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

uwt() { git -C "$URIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/worker-unreachable\$"; }
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
# (iv) .claude/worktrees + .gc-worktrees path coverage; (v) UNPARSEABLE lock → KEEP.
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
  # (f) UNPARSEABLE lock (no pid in reason) → KEEP (fail-safe)
  git worktree add -q "$ZRIG/.claude/worktrees/agent-noreason" -b crew/z/noreason main
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

zwt() { git -C "$ZRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/$1\$"; }
zbr() { git -C "$ZRIG" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

zwt ".claude/worktrees/agent-dead"     && bad "DEAD-locked worktree NOT reaped"                 || ok "DEAD-locked worktree reaped"
zbr crew/z/dead                        && bad "dead's merged crew branch NOT deleted"           || ok "dead's merged crew branch deleted"
zwt ".claude/worktrees/agent-ancient"  && bad "ANCIENT+IDLE-locked worktree NOT reaped"         || ok "ANCIENT+IDLE-locked worktree reaped"
zbr wa-ancient-sortfix                 && ok "ancient's NON-crew branch KEPT (no data loss)"    || bad "ancient's non-crew branch wrongly deleted"
zwt ".claude/worktrees/agent-young"    && ok "YOUNG/ACTIVE-locked worktree KEPT (never reap live agent)" || bad "YOUNG/ACTIVE worktree wrongly reaped — DESTROYS LIVE WORK!"
zwt ".claude/worktrees/agent-busy"     && ok "ANCIENT-but-BUSY-locked worktree KEPT (not idle)" || bad "busy worktree wrongly reaped"
zwt ".gc-worktrees/zb-mainbase"        && bad "gate-review DEAD-locked tree NOT reaped"         || ok "gate-review DEAD-locked tree reaped (.gc-worktrees coverage)"
zwt ".claude/worktrees/agent-noreason" && ok "UNPARSEABLE lock KEPT (fail-safe)"                || bad "unparseable lock wrongly reaped"
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
git -C "$ZREMOTE" show refs/heads/wa-agent-dirty-wip:wip.txt 2>/dev/null | grep -qx agentwip \
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
git -C "$ZREMOTE" for-each-ref "refs/reclaimed/agent-collide/" --format='%(objectname)' 2>/dev/null | grep -q . \
  && ok "ga-xv78c: collision WIP preserved under refs/reclaimed/ fallback" \
  || bad "ga-xv78c: collision WIP LOST — refs/reclaimed/ fallback path broken"
grep -q '"event":"reaped_zombie_lock"' "$TMP/reaperZ.jsonl" 2>/dev/null && ok "reaped_zombie_lock logged" || bad "reaped_zombie_lock NOT logged"
grep -q '"event":"kept_locked_live"'   "$TMP/reaperZ.jsonl" 2>/dev/null && ok "kept_locked_live logged (live holder)" || bad "kept_locked_live NOT logged"

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
git -C "$DRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/.claude/worktrees/agent-d\$" \
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
git -C "$ORIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/.claude/worktrees/agent-o\$" \
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
git -C "$YRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/.claude/worktrees/agent-y\$" \
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

git -C "$CRIG/crew/oracle" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/oracle/\.claude/worktrees/agent-stale\$" \
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

gwt() { git -C "$GRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/worker-ga0j2zc\$"; }
gwt && bad "ga-0j2zc: dirty worktree with ignored-tracked drift NOT reaped" || ok "ga-0j2zc: dirty worktree with ignored-tracked drift preserved+reaped"

git -C "$GREMOTE" rev-parse -q --verify refs/heads/crew/g/ga0j2zc >/dev/null 2>&1 \
  && ok "ga-0j2zc: preserve commit landed on origin" \
  || bad "ga-0j2zc: preserve commit never reached origin — cannot check its contents"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:.gc/keep.txt 2>/dev/null | grep -qx orig-keep \
  && ok "ga-0j2zc: tracked+ignored file's on-disk DRIFT excluded (preserve kept pre-drift committed content)" \
  || bad "ga-0j2zc: tracked+ignored file's drift LEAKED into the preserve commit (the reported bug)"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:.gc/will-delete.txt 2>/dev/null | grep -qx orig-del \
  && ok "ga-0j2zc: tracked+ignored file's on-disk DELETION not swept into the preserve commit" \
  || bad "ga-0j2zc: tracked+ignored file's deletion leaked into the preserve commit"

git -C "$GREMOTE" show refs/heads/crew/g/ga0j2zc:crew_wip.txt 2>/dev/null | grep -qx "genuine crew wip" \
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

mwt() { git -C "$MRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/$1\$"; }

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
git -C "$FRIG" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/crew/worker-merged-fresh\$" \
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

wflat()       { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/\.gc-worktrees/flat-unmerged\$"; }
wnested()     { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/\.gascity-gastown-hq/\.gc-worktrees/nested-merged\$"; }
wnestedbusy() { git -C "$WTOWN" worktree list --porcelain 2>/dev/null | grep -qE "^worktree .*/\.gascity-gastown-hq/\.gc-worktrees/nested-merged-busy\$"; }

wflat && bad "ga-t14of: flat-root stale worktree NOT reaped (loop-1 baseline broken)" \
  || ok "ga-t14of: flat-root (\$GT/.gc-worktrees) stale worktree reaped (loop-1 baseline holds)"
wnested && bad "ga-t14of: nested-root (.gascity-gastown-hq/.gc-worktrees) merged worktree NOT reaped — the actual reported bug NOT fixed" \
  || ok "ga-t14of: nested-root (.gascity-gastown-hq/.gc-worktrees) merged worktree reaped — coverage gap closed"
wnestedbusy && ok "ga-t14of: nested-root merged+IN-USE worktree KEPT (in-use protection applies via loop 1 too)" \
  || bad "ga-t14of: nested-root merged+IN-USE worktree wrongly reaped via loop 1 — turns cleanup into an incident!"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
