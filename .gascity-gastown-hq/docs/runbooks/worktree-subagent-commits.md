# Worktree-subagent commits — reliable locate/verify/merge recipe (wa-299h9)

**Problem (reporter batista-ps, 3–4× in one session):** a parent dispatches a
worktree-isolated subagent (`Agent` tool, `isolation:"worktree"`) to commit to a
NAMED branch. The subagent's commit is REAL but lands **off the requested branch**
— a FLOATING commit (reachable by SHA, not on the branch, not on `main`). The parent
verifies by checking the requested branch → finds nothing → false **"work missing /
fabricated"** verdict → escalation + wasted re-work.

## Root cause (confirmed)

1. **The branch is created by the Claude Code runtime, not by Gas City.** The Gas City
   engine (`internal/runtime/t3bridge/provider.go` `rpcCreateWorktree`) only *requests*
   a worktree over WebSocket RPC; the actual `git worktree add` + branch creation happens
   inside the closed Claude Code agent runtime. So the branch-naming/collision behavior is
   **harness-level — NOT patchable from Gas City.**
2. **Branch-name COLLISION is the trigger.** If the requested branch name (e.g.
   `fix/pix-dialer-behavior`) already exists as a **pre-existing remote branch** (stale,
   unrelated work), the worktree's commit can land on a divergent/detached state instead of
   the branch the parent expects → the parent's branch reads as `== main` or behind.
3. **The gate is INNOCENT.** The quality gate only processes branches that carry a
   `/gate-done` marker (keyed on `source-bead`/`marker_id`, branch shape `crew/*/<bead>`).
   A worktree subagent branch (`fix/*`, `feat/*`) has **no marker → the gate never sees or
   merges it.** The floating commit (`fe09f281` in the report) was produced purely by the
   worktree mechanism, **not** auto-merged by the gate.

## The reliable recipe (USE THIS — it makes verification never false-negative)

**Never verify a worktree subagent's work by checking the branch NAME.** Verify by the
**commit SHA**, which the subagent must report.

1. **Require the SHA in the subagent's return.** Instruct the worktree subagent to end its
   report with the exact commit SHA(s) it created and the branch HEAD:
   `git rev-parse HEAD` and `git log --oneline -3`.
2. **Verify by SHA, not by branch name:**
   ```bash
   git -C <repo> cat-file -t <sha>            # exists?  (object is real)
   git -C <repo> show --stat <sha>            # the claimed files/lines are there?
   git -C <repo> branch -a --contains <sha>   # which refs (if any) contain it?
   ```
   If `cat-file` resolves the SHA, **the work is REAL** — even if no branch points at it.
   A "missing on the branch" result is a FALSE NEGATIVE; do **not** conclude "fabricated."
3. **Merge by SHA explicitly** (the commit may be floating):
   ```bash
   git -C <repo> fetch <remote> <sha> 2>/dev/null || true   # if pushed but unref'd
   git -C <repo> cherry-pick <sha>        # onto your target branch
   # or: git merge <sha> ; or: git branch <name> <sha> to re-anchor it
   ```
4. **Avoid the collision: use a UNIQUE branch name per dispatch.** When you ask a worktree
   subagent to commit to a branch, namespace it so it can't collide with a pre-existing
   remote branch — e.g. `wt/<short-task>-<unique-suffix>` (a timestamp or random token).
   Never reuse a generic name like `fix/<feature>` that might already exist on origin.

## Harness escalation (the only true root fix)

The Claude Code `Agent` tool's `isolation:"worktree"` should **namespace the worktree
branch per agent-id** (e.g. `wt/<agent-id>/<name>`) so a parent-requested name can never
collide with a pre-existing remote branch, and should surface the created branch/SHA back
to the parent deterministically. This is a **runtime/harness change** (Anthropic side),
not a Gas City fix — tracked here so agents use the recipe above until the harness changes.

## TL;DR for any agent dispatching worktree subagents

> Verify by **commit SHA** (have the subagent report `git rev-parse HEAD`), never by branch
> name. A SHA that `git cat-file -t` resolves IS real work, even if floating — cherry-pick
> it. Use a unique branch name per dispatch to dodge stale-remote collisions.
