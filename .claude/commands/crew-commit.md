---
description: Canonical commit workflow for crew members — branch, commit, rebase, push, PR
allowed-tools: Bash(git *), Bash(gt commit*), Bash(gh pr create*), Bash(gh pr view*)
argument-hint: [<type>/<description> e.g. fix/cors-headers]
---

Crew commit workflow. Run all steps in order.

Branch argument (if provided): $ARGUMENTS

## ⚠️ NEVER commit directly to main

Crew members ALWAYS work on feature branches and submit PRs.
Direct pushes to main are forbidden — the Refinery handles merges.

---

## Step 1: Pre-flight checks

### Deacon safety guard — refuse cross-clone ops

```bash
# Guard: deacon cannot run crew-commit inside crew clones
if [[ "$GT_ROLE" == */deacon ]]; then
  # Check if current directory is a crew clone (~/gt/<rig>/crew/<name>/)
  if [[ "$PWD" =~ /gt/[^/]+/crew/[^/]+/?$ ]]; then
    cat >&2 <<'EOF'
❌ BLOCKED: Deacon cannot commit in crew clones

This is a crew clone (path: $PWD). Deacon must not execute git operations
against crew clones — this is a cross-clone discipline boundary.

→ For replication guidance, see: dc-x2qs
→ For incident reference, see: dc-c6m2 (cross-clone breach)

STOP. Do not proceed. Work in deacon's own clone only.
EOF
    exit 1
  fi
fi
```

---

### Standard pre-flight checks


```bash
# Verify we're in a git repo
git rev-parse --is-inside-work-tree

# Fetch latest from origin
git fetch origin

# Detect the default branch
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"
echo "Default branch: $DEFAULT_BRANCH"
```

Check current status:
```bash
git status
git branch --show-current
```

If already on a feature branch with commits, skip to Step 3.

## Step 2: Create feature branch

If `$ARGUMENTS` was provided, use it as the branch name. Otherwise, construct
one from the work being done:

**Branch naming convention:** `<type>/<short-description>`

Types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`

```bash
git checkout -b <type>/<description> origin/$DEFAULT_BRANCH
```

Examples:
- `feat/add-webhook-handler`
- `fix/cors-headers`
- `refactor/split-auth-middleware`

## Step 3: Submodule and shared directory check

**CRITICAL:** Before staging files, check for accidental submodule or shared
directory changes. These are common sources of broken commits.

```bash
# Check for submodules
git submodule status 2>/dev/null

# Check for changes in shared/ or config directories
git diff --name-only | grep -E '^(shared/|config/|\.gitmodules)' || true
git diff --staged --name-only | grep -E '^(shared/|config/|\.gitmodules)' || true
```

**If shared/ or config/ changes are detected:**
- ASK before including them — they may affect other rigs
- If the changes are intentional, proceed
- If accidental (e.g., submodule pointer drift), unstage them:
  ```bash
  git checkout -- shared/ config/ .gitmodules
  ```

## Step 4: Stage and commit

Stage relevant files (NEVER use `git add -A` blindly — review first):

```bash
git status                    # Review what changed
git add <specific-files>      # Stage intentionally
```

**Do not use bare `gt commit`** — it only sets identity when the legacy
`GT_ROLE` env var is set, which this city never sets (agents carry
`GC_AGENT`/`GC_ALIAS` instead), so it silently falls back to whatever
identity is already sitting in the worktree's `.git/config` (often the
human's own, not yours — ga-qpsen). Set identity explicitly, per commit:

```bash
IDENTITY="${GC_ALIAS:-${GC_AGENT:-}}"
if [ -n "$IDENTITY" ]; then
  git -c user.name="$IDENTITY" -c user.email="${IDENTITY}@gascity.local" commit -m "<type>: <description>"
else
  git commit -m "<type>: <description>"
fi
```

Commit message conventions:
- `feat: add webhook handler for Slack integration`
- `fix: resolve CORS header race condition`
- `refactor: extract auth middleware into separate package`
- `test: add coverage for token refresh edge case`
- `docs: update API reference for v2 endpoints`
- `chore: bump dependency versions`

Make multiple atomic commits if the work has distinct logical units.

## Step 5: Rebase onto latest target

Before pushing, rebase onto the latest default branch to minimize merge conflicts:

```bash
git fetch origin
git rebase origin/$DEFAULT_BRANCH
```

**If rebase conflicts occur:**
1. Resolve conflicts in each file
2. `git add <resolved-files>`
3. `git rebase --continue`
4. If stuck, `git rebase --abort` and ask for help

## Step 6: Push and create PR

```bash
# Push the branch
git push -u origin HEAD
```

Create the PR:

```bash
gh pr create \
  --title "<type>: <short description>" \
  --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing the change>

## Test plan
- [ ] <How to verify this change>

🤖 Generated with Gas Town crew workflow
EOF
)"
```

Report the PR URL when done.

## Step 7: Post-push verification

```bash
# Verify PR was created
gh pr view --json url,state,title

# Verify branch is clean
git status
```

Done. The PR is now ready for review. Do NOT merge it — the Refinery or a
maintainer handles that.
