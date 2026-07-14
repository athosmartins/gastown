---
description: Signal work ready for quality gate (writes durable marker; launchd guard picks it up within ~2 min)
argument-hint: ""
allowed-tools: Bash(git status:*), Bash(git push:*), Bash(git rev-parse:*), Bash(git log:*), Bash(git config:*), Bash(bd create:*), Bash(bd label:*), Bash(bd list:*), Bash(bd show:*), Bash(gc rig list:*)
---

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

# ga-mxhf6: block submission from protected branches — builders must NEVER commit
# directly to main/master. branch=main is always an ancestor of itself, so the
# dispatcher would supersede the marker without running any reviewers, silently
# bypassing the gate (the exact incident that created this bug).
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  echo "ERROR: You are on branch '$BRANCH' — this is a protected branch."
  echo "  Builders must NEVER commit directly to $BRANCH."
  echo "  Create a feature branch first, then re-run /gate-done:"
  echo "    git checkout -b fix/<bead-id>-<description>"
  echo "  Marker NOT created."
  exit 1
fi

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

# ga-dx5/ga-owfll: PRIMARY resolution — extract bead_id from branch name convention.
# Branch name is the canonical pointer to the owning STORY bead. Session-assigned
# in_progress beads may include sling/task beads from the gate-dispatcher that are
# NOT the story bead. If we pick the sling bead, the dispatcher strips story:in-flight
# from the wrong bead → lane slot never frees. Branch name is always authoritative.
# Two conventions:
#   crew/<name>/<STORY_ID>[-desc]  — crew clone branches (e.g. crew/batista/wa-27jn).
#                                    The bead id is the 3rd path segment's leading
#                                    token. The generic regex below CANNOT match this
#                                    form (it requires a trailing '-'), so crew
#                                    submissions used to fall through to the session
#                                    lookup and pick the wrong bead — ga-owfll.
#   <prefix>/<STORY_ID>-<desc>     — builder convention (e.g. fix/ga-dx5-my-fix → ga-dx5)
case "$BRANCH" in
  crew/*/*)
    _CREW_SEG=${BRANCH#crew/*/}
    BEAD_ID=$(printf '%s\n' "$_CREW_SEG" \
      | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}' | head -1 2>/dev/null || echo "")
    ;;
  *)
    BEAD_ID=$(echo "$BRANCH" | grep -oE '^[^/]+/[a-z]{2,8}-[a-z0-9]{2,8}-' \
      | grep -oE '[a-z]{2,8}-[a-z0-9]{2,8}' 2>/dev/null || echo "")
    ;;
esac

# ga-u4yi: VALIDATE the regex match before trusting it. The patterns above are
# syntactic, not semantic — on a descriptively-named crew branch
# (crew/thies/demand-mobile-phase2) the crew/*/* case happily matches
# "demand-mobile", a token that is NOT a bead id. Because that value is
# non-empty, both the SECONDARY fallback and the FAIL-CLOSED guard below (which
# gate on `-z "$BEAD_ID"`) would be skipped, and a marker would ship with a
# phantom source-bead no reviewer can ever find. Probe HQ, then every
# registered rig's store (a bead can legitimately live in either); discard the
# match if it resolves nowhere so the real checks below get a chance to run.
RIG_LIST_JSON=$(gc --city "$GC_CITY_PATH" rig list --json 2>/dev/null || echo '{}')
if [ -n "$BEAD_ID" ]; then
  _BEAD_ID_RESOLVED=""
  if bd -C "$GC_CITY_PATH" show "$BEAD_ID" >/dev/null 2>&1; then
    _BEAD_ID_RESOLVED=1
  else
    for _RIG_PATH in $(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[].path // empty' 2>/dev/null); do
      if bd -C "$_RIG_PATH" show "$BEAD_ID" >/dev/null 2>&1; then
        _BEAD_ID_RESOLVED=1
        break
      fi
    done
  fi
  if [ -z "$_BEAD_ID_RESOLVED" ]; then
    echo "Note: '$BEAD_ID' parsed from branch '$BRANCH' does not resolve to a real bead — discarding, will try fallback."
    BEAD_ID=""
  fi
fi

# SECONDARY: if branch doesn't embed a bead ID (uncommon), fall back to the
# session's in_progress bead that carries story:in-flight — that label is ONLY on
# story/bug beads, not on sling/task beads from the gate-dispatcher.
if [ -z "$BEAD_ID" ]; then
  for _BEAD_ASSIGNEE in "${GC_SESSION_NAME:-}" "${GC_SESSION_ID:-}" "${BEADS_ACTOR:-}" "${GC_ALIAS:-}"; do
    [ -z "$_BEAD_ASSIGNEE" ] && continue
    _BEAD_RESULT=$(bd -C "$GC_CITY_PATH" list \
      --assignee="$_BEAD_ASSIGNEE" --status=in_progress \
      --label story:in-flight --json 2>/dev/null \
      | jq -r '.[0].id // empty' 2>/dev/null || echo "")
    if [ -n "$_BEAD_RESULT" ]; then
      BEAD_ID="$_BEAD_RESULT"
      break
    fi
  done
fi

# FAIL CLOSED: a marker with bead_id=unknown causes gate-status:error (the guard
# rejects delivery). If we cannot positively identify the story bead, it is safer
# to abort than to create a marker the gate will reject — the builder can fix the
# branch name or bead assignment and re-run.
if [ -z "$BEAD_ID" ]; then
  echo "ERROR: Cannot resolve owning story bead from branch '$BRANCH' or session assignments."
  echo "  Expected branch convention: <prefix>/<bead-id>-<desc> (e.g. fix/ga-dx5-my-fix)"
  echo "  Or ensure you have an in_progress bead with label 'story:in-flight' assigned to you."
  echo "  Marker NOT created. Fix the branch name or bead assignment and re-run /gate-done."
  exit 1
fi
AUTHOR="${GC_ALIAS:-${BEADS_ACTOR:-$(git config user.name)}}"
BASE_COMMIT=$(git rev-parse origin/main 2>/dev/null || echo "unknown")
# Rig list (RIG_LIST_JSON) was already fetched above during bead_id validation.
CWD_TOP=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# ga-owfll PRIMARY: the rig whose registered path == cwd OR is an ANCESTOR of cwd.
# Crew members work in <rig>/crew/<name> — a SUBDIR of the registered rig path — so
# the old EXACT match (.path == $cwd) never matched for them. Match by ancestry and
# take the LONGEST (deepest) path to disambiguate any nested layout.
# ga-8a9n: bind .path to $p BEFORE the pipe — `$cwd | startswith(.path + "/")`
# rebinds `.` to the STRING $cwd for everything after the pipe, so the bare
# `.path` inside startswith() tried to index a string and crashed. Since
# `[.rigs[] | select(...)]` collects every output into one array, a SINGLE
# crashing element (any rig that isn't an exact cwd match) poisoned the whole
# result — so this crashed on nearly every invocation, silently falling
# through to the bead-prefix/agent-suffix fallbacks below.
RIG=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg cwd "$CWD_TOP" '
    [ .rigs[] | select(.path as $p | ($cwd == $p) or ($cwd | startswith($p + "/"))) ]
    | sort_by(.path | length) | last | .name // empty' 2>/dev/null || echo "")

# ga-owfll FALLBACK 1: map the source bead's PREFIX to a rig (wa-27jn → wa →
# whatsapp_automation). The bead id already encodes its owning rig.
if [ -z "$RIG" ] || [ "$RIG" = "null" ]; then
  _BPFX="${BEAD_ID%%-*}"
  if [ -n "$_BPFX" ] && [ "$_BPFX" != "$BEAD_ID" ]; then
    RIG=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$_BPFX" \
      '.rigs[] | select(.prefix == $p or .name == $p) | .name' 2>/dev/null | head -1 || echo "")
  fi
fi

# ga-owfll FALLBACK 2: map the agent-name rig SUFFIX to a rig (batista-wa → wa →
# whatsapp_automation). CRITICAL: we map the suffix THROUGH rig list — we never write
# the raw agent name as the rig. The old `RIG="${GC_AGENT%%/*}"` fallback emitted
# `rig: batista-wa` (an invalid rig) into the marker, stranding crew submissions.
if [ -z "$RIG" ] || [ "$RIG" = "null" ]; then
  _ASFX="${GC_AGENT##*-}"
  if [ -n "$_ASFX" ] && [ "$_ASFX" != "$GC_AGENT" ]; then
    RIG=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$_ASFX" \
      '.rigs[] | select(.prefix == $p or .name == $p) | .name' 2>/dev/null | head -1 || echo "")
  fi
fi

if [ -z "$RIG" ] || [ "$RIG" = "null" ]; then
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

# ga-owfll: record which DOLT STORE owns the source bead, independently of the
# code-rig. The dispatcher closes source-bead in the rig's store by default
# (BEAD_CITY=RIG_PATH); but framework/story beads live in HQ (gascity) even when the
# code-rig is wa/ps/lx, so a rig-scoped close silently no-ops and the bead is left
# open → re-dispatched ("source-bead rig-scoped fora do escopo HQ"). Probe HQ first
# (GC_CITY_PATH is the gascity store), then the code-rig DB, and record the owning
# rig so a store-aware consumer targets the right DB. Fail-soft: a store-aware
# dispatcher probes independently, so we only WARN if neither store resolves it.
BEAD_RIG=""
if bd -C "$GC_CITY_PATH" show "$BEAD_ID" >/dev/null 2>&1; then
  BEAD_RIG="gascity"
else
  _BEAD_RIG_PATH=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg r "$RIG" \
    '.rigs[] | select(.name == $r) | .path' 2>/dev/null | head -1 || echo "")
  if [ -n "$_BEAD_RIG_PATH" ] && bd -C "$_BEAD_RIG_PATH" show "$BEAD_ID" >/dev/null 2>&1; then
    BEAD_RIG="$RIG"
  fi
fi
if [ -z "$BEAD_RIG" ]; then
  echo "Warning: source bead '$BEAD_ID' did not resolve in HQ or rig '$RIG' store."
  echo "  Recording bead_rig=unknown; a store-aware dispatcher will probe the owner."
  BEAD_RIG="unknown"
fi

echo "Branch:      $BRANCH"
echo "Bead:        ${BEAD_ID:-<unknown>}"
echo "Author:      $AUTHOR"
echo "Base commit: $BASE_COMMIT"
echo "Rig:         $RIG"
echo "Bead rig:    $BEAD_RIG"
```

Verify these values look correct before continuing.
If this step aborts with "Cannot resolve owning story bead", name your branch
`<prefix>/<bead-id>-<desc>` (e.g. `fix/ga-dx5-my-fix`), or — if you are crew working
in a clone — `crew/<name>/<bead-id>[-desc]` (e.g. `crew/batista/wa-27jn`); or ensure
you have an in_progress bead with label `story:in-flight` assigned to you. `Rig` is
derived from the rig whose registered path contains your working directory, so crew
clones at `<rig>/crew/<name>` resolve to their owning rig. If `Rig` shows `unknown`,
the guard may not be able to find the source repository — verify you are running from
inside a registered rig directory. `Bead rig` shows which Dolt store owns the source
bead (HQ `gascity` vs the code-rig); it is recorded so the gate closes the bead in
the correct store.

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
  -l "source-bead:$BEAD_ID" \
  -l "bead-rig:$BEAD_RIG" \
  -d "branch: $BRANCH
bead_id: $BEAD_ID
author: $AUTHOR
base_commit: $BASE_COMMIT
rig: $RIG
bead_rig: $BEAD_RIG
submitted_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$MARKER_ID" ]; then
  echo "ERROR: Failed to create ready-for-gate marker."
  echo "  Check that Dolt server is running: gc dolt status"
  echo "  Check GC_CITY_PATH: $GC_CITY_PATH"
  exit 1
fi

# Stamp gate:queued on the SOURCE bead (ga-dt6bu / ga-oonk3 thrash fix). Without it, a
# bead created with no lifecycle label sits RAW between marker creation and the gate
# guard's first sweep (~2min), and the auto-refino raw-Triagem ingestion re-ingests it
# as a fresh story (ga-oonk3 thrashed 3x). gate:queued gives it a gate:* label so the
# auto-refino gate:* exclusion guard skips it. Stamp in the bead's OWN store (HQ or rig).
_BEAD_STORE="$GC_CITY_PATH"
[ "$BEAD_RIG" != "gascity" ] && [ "$BEAD_RIG" != "unknown" ] && [ -n "${_BEAD_RIG_PATH:-}" ] && _BEAD_STORE="$_BEAD_RIG_PATH"
bd -C "$_BEAD_STORE" label add "$BEAD_ID" "gate:queued" -q 2>/dev/null || true

echo "Marker created: $MARKER_ID"
```

## Step 4: Report

```bash
echo ""
echo "Ready for quality gate."
echo "  Branch:  $BRANCH"
echo "  Bead:    $BEAD_ID"
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

**"Cannot resolve owning story bead"**: Name your branch `<prefix>/<bead-id>-<desc>`
(e.g. `fix/ga-dx5-my-fix`) so /gate-done can extract the story bead from the branch
name. Alternatively, ensure you have an in_progress bead with label `story:in-flight`
assigned to your session. /gate-done aborts rather than writing a marker with
`bead_id=unknown` (which the guard would reject with `gate-status:error`).

**Long wait (>5 min)**: Check guard is running:
```bash
launchctl list | grep quality-gate-guard
# If not listed, load it:
launchctl load ~/Library/LaunchAgents/com.gascity.quality-gate-guard.plist
# Check guard logs:
tail -50 /Users/athos/gt/.gascity-gastown-hq/.gc/logs/quality-gate-guard.log
```
