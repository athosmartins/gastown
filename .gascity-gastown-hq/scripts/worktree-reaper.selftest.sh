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

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
