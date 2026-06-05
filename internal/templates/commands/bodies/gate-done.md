# Gate Done — Signal Work Ready for Quality Gate

Signal that your work is complete and ready to pass through the quality gate.
This command writes a DURABLE ready-for-gate marker that the launchd guard will
pick up within ~2 minutes.

Arguments: $ARGUMENTS

## What This Does

1. Validates your working tree is clean and pushed.
2. Creates a durable bead marker in the CITY database (so the guard can find it).
3. You are DONE — the launchd guard sweeps every ~2 min, claims the marker,
   and spawns a gate-runner in a separate session. You will be mailed when the
   gate passes or fails.

You do NOT spawn reviewers yourself. You do NOT merge your own work.

## Pre-flight Checks

```bash
git status                              # Must be clean
git log --oneline origin/main..HEAD     # Must have at least 1 commit
```

If uncommitted changes exist, commit them first.

## Step 1: Push your branch (fail-closed verification)

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)

git push origin HEAD

# ga-ljbx: fail-closed push verification. The gate guard/dispatcher operate
# entirely off origin — if the branch is NOT actually on the push remote, the
# marker would be created for a branch the gate can never find, and the work
# strands. `git push` can also report success while the ref does not land
# (proxy/auth edge cases), so we ASSERT the ref exists on origin before writing
# the marker. Abort loudly otherwise.
if [ -z "$(git ls-remote --heads origin "$BRANCH" 2>/dev/null)" ]; then
  echo "ERROR: branch '$BRANCH' is NOT present on origin after push."
  echo "  The quality gate operates off origin and cannot see unpushed work."
  echo "  Fix the push (auth, network, remote) and re-run /gate-done. Marker NOT created."
  exit 1
fi
echo "Push verified: $BRANCH present on origin."
```

If push fails, fix the issue (auth, network, conflict) and retry.

## Step 2: Gather context

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# IMPORTANT: GC_CITY_PATH is set by the session environment.
# If not set, derive it from the session's city directory.
if [ -z "$GC_CITY_PATH" ]; then
  GC_CITY_PATH=$(gc --city . config show 2>/dev/null | grep 'city_path\|city =' | head -1 \
    | sed 's/.*=[ ]*//' | tr -d '"' || echo "")
fi
if [ -z "$GC_CITY_PATH" ]; then
  echo "ERROR: GC_CITY_PATH is not set. Run 'gc prime' and try again."
  exit 1
fi

echo "City DB path: $GC_CITY_PATH"

# Get bead from current session hook (in_progress assignment) using city DB.
# Try all session identifiers in order — beads may be assigned using the full
# session name (GC_SESSION_NAME), session ID, BEADS_ACTOR, or alias.
BEAD_ID=""
for _BEAD_ASSIGNEE in "${GC_SESSION_NAME:-}" "${GC_SESSION_ID:-}" "${BEADS_ACTOR:-}" "${GC_ALIAS:-}"; do
  [ -z "$_BEAD_ASSIGNEE" ] && continue
  _BEAD_RESULT=$(bd -C "$GC_CITY_PATH" list \
    --assignee="$_BEAD_ASSIGNEE" --status=in_progress --json 2>/dev/null \
    | jq -r '.[0].id // empty' 2>/dev/null || echo "")
  if [ -n "$_BEAD_RESULT" ]; then
    BEAD_ID="$_BEAD_RESULT"
    break
  fi
done

# Fallback: extract bead ID from branch name (e.g. fix/ga-dx5-some-desc → ga-dx5)
if [ -z "$BEAD_ID" ]; then
  BEAD_ID=$(echo "$BRANCH" | tr '/' '\n' \
    | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}$' | head -1 || echo "")
fi
AUTHOR="${GC_ALIAS:-${BEADS_ACTOR:-$(git config user.name)}}"
BASE_COMMIT=$(git rev-parse origin/main 2>/dev/null || echo "unknown")
# Derive rig from gc rig list (authoritative)
RIG=$(gc --city "$GC_CITY_PATH" rig list --json 2>/dev/null \
  | jq -r --arg cwd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
      '.rigs[] | select(.path == $cwd) | .name' 2>/dev/null | head -1 || echo "")
# Fallback: extract from GC_AGENT if gc rig list didn't match
if [ -z "$RIG" ] || [ "$RIG" = "null" ]; then
  RIG="${GC_AGENT%%/*}"
fi
if [ -z "$RIG" ] || [ "$RIG" = "$GC_AGENT" ]; then
  RIG="unknown"
fi

# ga-ljbx: hard-pin rig=gascity for framework/self-fix beads. Branches named
# fix/* authored from inside the HQ are framework self-fixes whose code lives ONLY
# in the gascity (HQ) repo. If the cwd-based derivation ever mis-resolves them to
# another rig (e.g. gastown), the gate would look for the branch in the wrong repo
# and strand it. Pin explicitly so self-fixes always route to gascity.
case "$BRANCH" in
  fix/*)
    if [ "$RIG" != "gascity" ]; then
      echo "Note: framework self-fix branch ($BRANCH) — pinning rig=gascity (was: ${RIG:-unknown})."
      RIG="gascity"
    fi
    ;;
esac

echo "Branch:      $BRANCH"
echo "Bead:        ${BEAD_ID:-<unknown>}"
echo "Author:      $AUTHOR"
echo "Base commit: $BASE_COMMIT"
echo "Rig:         $RIG"
```

Verify these values look correct before continuing.
If `Bead` shows `<unknown>`, check that you have an in-progress bead assigned
to you. If `Rig` shows `unknown`, the guard may not be able to find the source
repository — verify you are running from inside a registered rig directory.

## Step 3: Create the ready-for-gate marker

The marker MUST be written to the city database (same database the guard reads).
We use `-C "$GC_CITY_PATH"` to target the city DB explicitly.

```bash
MARKER_ID=$(bd -C "$GC_CITY_PATH" create \
  "ready-for-gate: $BRANCH" \
  -t chore --ephemeral \
  -l type:quality-gate-marker \
  -l gate-status:ready \
  -l "branch:$BRANCH" \
  -l "source-bead:${BEAD_ID:-unknown}" \
  -d "branch: $BRANCH
bead_id: ${BEAD_ID:-unknown}
author: $AUTHOR
base_commit: $BASE_COMMIT
rig: $RIG
submitted_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$MARKER_ID" ]; then
  echo "ERROR: Failed to create ready-for-gate marker."
  echo "  Check that Dolt server is running: gc dolt status"
  echo "  Check GC_CITY_PATH: $GC_CITY_PATH"
  exit 1
fi

echo "Marker created: $MARKER_ID"
```

## Step 4: Report

```bash
echo ""
echo "Ready for quality gate."
echo "  Branch:  $BRANCH"
echo "  Bead:    ${BEAD_ID:-<unknown>}"
echo "  Marker:  $MARKER_ID"
echo "  City DB: $GC_CITY_PATH"
echo ""
echo "The launchd guard sweeps every ~2 minutes and will pick this up."
echo "You will be mailed when the gate passes or fails."
echo ""
echo "You are done. The gate-runner handles the rest."
```

## Common Issues

**"bd create failed"**: Check that Dolt server is running (`gc dolt status`).

**"GC_CITY_PATH not set"**: Run `gc prime` first, or check your session environment.

**"No commits ahead of main"**: You need at least one commit on your branch.

**"working tree not clean"**: Commit or stash your changes first.

**"Bead unknown"**: You may not have an in_progress bead. The gate will still
run but author-exclusion fallback to `$GC_ALIAS`.

**Long wait (>5 min)**: Check guard is running:
```bash
launchctl list | grep quality-gate-guard
# If not listed, load it:
launchctl load ~/Library/LaunchAgents/com.gascity.quality-gate-guard.plist
# Check guard logs:
tail -50 /Users/athos/gt/.gascity-gastown-hq/.gc/logs/quality-gate-guard.log
```
