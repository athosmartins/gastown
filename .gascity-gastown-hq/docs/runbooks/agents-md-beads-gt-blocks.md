# AGENTS.md legacy blocks — beads, cross-clone, Gas Town comms, session completion

## Contents

- Beads Workflow Integration · Cross-Clone Discipline · Gas Town Multi-Agent Communication
- Beads Issue Tracker · Session Completion

Moved verbatim from `AGENTS.md` (lines 342-568 of commit 02da0eea8) on 2026-10-11 (rule: AGENTS.md
≤ 200 lines, ga-vhzdh5.2). `AGENTS.md` keeps a short summary that points here.

The HTML-comment markers below (`beads-agent-instructions-v2`, `gastown-agent-instructions-v1`,
`BEGIN/END BEADS INTEGRATION ... hash`) are kept as they were: `bd init` / `bd setup` write the
BEADS INTEGRATION block into `AGENTS.md` and may re-add it there (bringing the file back over 200
lines; not exercised in ga-vhzdh5.2) — if `bd` does that, move the block back here instead.

<!-- beads-agent-instructions-v2 -->

---

## Beads Workflow Integration

This project uses [beads](https://github.com/steveyegge/beads) for issue tracking. Issues live in `.beads/` and are tracked in git.

Two CLIs: **bd** (issue CRUD) and **bv** (graph-aware triage, read-only).

### bd: Issue Management

```bash
bd ready              # Unblocked issues ready to work
bd list --status=open # All open issues
bd show <id>          # Full details with dependencies
bd create --title="..." --type=task --priority=2
bd update <id> --status=in_progress
bd close <id>         # Mark complete
bd close <id1> <id2>  # Close multiple
bd dep add <a> <b>    # a depends on b
bd sync               # Sync with git
```

### bv: Graph Analysis (read-only)

**NEVER run bare `bv`** — it launches interactive TUI. Always use `--robot-*` flags:

```bash
bv --robot-triage     # Ranked picks, quick wins, blockers, health
bv --robot-next       # Single top pick + claim command
bv --robot-plan       # Parallel execution tracks
bv --robot-alerts     # Stale issues, cascades, mismatches
bv --robot-insights   # Full graph metrics: PageRank, betweenness, cycles
```

### Workflow

1. **Start**: `bd ready` (or `bv --robot-triage` for graph analysis)
2. **Claim**: `bd update <id> --status=in_progress`
3. **Work**: Implement the task
4. **Complete**: `bd close <id>`
5. **Sync**: `bd sync` at session end

### Session Close Protocol

```bash
git status            # Check what changed
git add <files>       # Stage code changes
bd sync               # Commit beads changes
git commit -m "..."   # Commit code
bd sync               # Commit any new beads changes
git push              # Push to remote
```

### Key Concepts

- **Priority**: P0=critical, P1=high, P2=medium, P3=low, P4=backlog (numbers only)
- **Types**: task, bug, feature, epic, question, docs
- **Dependencies**: `bd ready` shows only unblocked work

<!-- end-beads-agent-instructions -->

---

## Cross-Clone Discipline

**Never run `git -C <other-rig-or-crew-clone> <write-op>` from this session.** Crews own their own clones — reaching across the boundary creates silent merge breaches (see dc-v1fw root cause analysis). The pattern that triggered dc-c6m2 was `git -C ~/gt/whatsapp_automation/crew/<x> commit ...` issued from this session; that pattern is forbidden.

**What "write op" means here**: `commit`, `push`, `merge`, `rebase`, `cherry-pick`, `reset --hard`, `stash drop`, `clean -f`, `branch -D`, `tag -d`, `apply`, `am`. Read-only ops (`log`, `status`, `diff`, `show`, `cat-file`, `rev-parse`, etc) are fine — diagnostic visibility into other clones is useful and not a breach.

**The right pattern for crew-affecting changes:**

1. Make the change in this rig's parent clone (`~/gt/whatsapp_automation/`).
2. Open an MR via `gt mq submit` (or push to a feature branch + PR).
3. Refinery merges to `origin/main`.
4. Each crew's `SessionStart` hook runs `scripts/crew_session_start.sh` (added by dc-x2qs) which fast-forwards their local `main` from `origin/main` automatically when safe.

This is the standard git workflow — the same one every other agent uses. The cross-clone replication that ran before dc-x2qs was a shortcut that bypassed it; we have removed the shortcut.

**Emergency override**: `DEACON_FORCE_REPLICATE=1 git -C <crew-clone> commit ...` works (consistent with PR #5's existing override). Use only when no other option works AND mayor approves; the action is logged and reviewable.

**Diagnostic check before any cross-clone op (manual or scripted)**:

```python
from lib.crew_sentinel import should_skip_replication
if should_skip_replication("/path/to/crew-clone"):
    # active session detected — skip; the wrapper logs WARN automatically
    continue
```

### PreToolUse Hook Enforcement (Primary)

A `PreToolUse` hook is configured in `.claude/settings.json` to block all cross-clone write operations at the CLI level:

```
Blocked patterns (exit code 2):
  - git -C *crew* commit*
  - git -C *crew* push*
  - git -C *crew* merge*
  - git -C *crew* rebase*
  - git -C *crew* cherry-pick*
  - git -C *crew* reset*
  - git -C *crew* stash* drop*
  - git -C *crew* branch -D*
  - git -C *crew* tag -d*
  - git -C *crew* apply*
  - git -C *crew* am*
  - git -C *crew* clean*
```

Any attempt to run these commands exits immediately with a clear error message referencing the incident (`dc-c6m2`/`dc-v1fw`) that necessitated the block. This is the primary enforcement.

The sentinel (`lib.crew_sentinel`) and the hook are dual enforcement: neither replaces the discipline documented in this section; both can be bypassed via `DEACON_FORCE_REPLICATE=1` in genuine emergencies (with mayor approval).

<!-- gastown-agent-instructions-v1 -->

---

## Gas Town Multi-Agent Communication

This workspace is part of a **Gas Town** multi-agent environment. You communicate
with other agents using `gt` commands — never by printing text or using raw tmux.

### Nudging Agents (Immediate Delivery)

`gt nudge` sends a message directly to another agent's active session:

```bash
gt nudge mayor "Status update: PR review complete"
gt nudge laneassist/crew/dom "Check your mail — PR ready for review"
gt nudge witness "Polecat health check needed"
gt nudge refinery "Merge queue has items"
```

**Target formats:**
- Role shortcuts: `mayor`, `deacon`, `witness`, `refinery`
- Full path: `<rig>/crew/<name>`, `<rig>/polecats/<name>`

**Important:** `gt nudge` is the ONLY way to send text to another agent's session.
Never print "Hey @name" — the other agent cannot see your terminal output.

### Sending Mail (Persistent Messages)

`gt mail` sends messages that persist across session restarts:

```bash
# Reading
gt mail inbox                    # List messages
gt mail read <id>                # Read a specific message

# Sending (use --stdin for multi-line content)
gt mail send mayor/ -s "Subject" -m "Short message"
gt mail send laneassist/crew/dom -s "PR Review" --stdin <<'BODY'
Multi-line message content here.
Details about the PR and what to look for.
BODY
gt mail send --human -s "Subject" -m "Message to overseer"
```

### When to Use Which

| Want to... | Command | Why |
|------------|---------|-----|
| Wake a sleeping agent | `gt nudge <target> "msg"` | Immediate delivery |
| Send detailed task/info | `gt mail send <target> -s "..." --stdin` | Persists across restarts |
| Both: send + wake | `gt mail send` then `gt nudge` | Mail carries payload, nudge wakes |

### Context Recovery

After compaction or new session, run `gt prime` to reload your full role context,
identity, and any pending work.

```bash
gt prime              # Full context reload
gt hook               # Check for assigned work
gt mail inbox         # Check for messages
```

<!-- end-gastown-agent-instructions -->

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `gt prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `gt prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
