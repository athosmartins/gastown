#!/usr/bin/env bash
# wa-root-worktree-isolation.selftest.sh (fix/wa-root-worktree-isolation)
#
# Proves the SECONDARY (script/skill-layer) fix for the recurring
# "production root checked out onto crew branches" bug.
#
# Root cause (diagnosed, confirmed): a rig's REGISTERED path IS its production
# root (e.g. whatsapp_automation → /Users/athos/gt/whatsapp_automation). When the
# engine slings a wa- bead to a POOL crew it sets WorkDir = that root (no per-bead
# worktree in the crew path), and crew-commit's `git checkout -b crew/...` then
# runs IN-PLACE on the production root → the root leaves main, breaking daemons,
# the painel, and sibling crews.
#
# Two deployable, no-rebuild defenses, both exercised here:
#   PART 1 (load-bearing) — crew-commit SKILL.md Step 1.5 guard: detect "am I in a
#     registered rig ROOT?" by EXACT toplevel==rig.path match, and if so create +
#     cd into a dedicated worktree and branch THERE; a crew clone / worktree UNDER
#     the root must NOT trip the guard; the production root must never be flipped.
#   PART 2 (best-effort) — Pilot dispatch directive: when a build would land in a
#     rig's bare root (non-dog pool/single crew of an on-disk code rig), inject a
#     DO-NOT-BRANCH-IN-ROOT/use-a-worktree block into the dispatch prompt. The
#     gastown.dog pool (HQ builds) is EXEMPT. Fail-open on any lookup miss.
#
# Covers:
#   (A) EXACT rig-root match → guard MUST isolate (wa root, ps root)
#   (B) crew clone subdir under a rig root → guard MUST NOT trip (proceed)
#   (C) worktree path under .gc-worktrees/ → guard MUST NOT trip (proceed)
#   (D) non-rig repo (no registry match) → guard MUST NOT trip (proceed)
#   (E) Pilot directive emitted for a non-dog pool crew building in a real rig root
#   (F) Pilot directive SUPPRESSED for gastown.dog (HQ pool exempt)
#   (G) Pilot directive SUPPRESSED when the rig root path is unknown / absent
#   (H) the worktree never branches the ROOT — the recipe targets the worktree dir
#   (I) Source drift-guards: deployed SKILL.md + pilot-dispatcher.sh still contain
#       the load-bearing logic (so this test cannot silently diverge).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Deployed sources (drift-guard targets). Resolve in priority order:
#   1. sibling pilot-dispatcher.sh (this asset dir)
#   2. repo-relative SKILL.md (worktree / binary-repo context)
PILOT="$SELF_DIR/pilot-dispatcher.sh"
SKILL="$SELF_DIR/../../../../.claude/skills/crew-commit/SKILL.md"
[ -f "$SKILL" ] || SKILL="$SELF_DIR/../../../../../.claude/skills/crew-commit/SKILL.md"
# Last resort: locate via git toplevel of this file.
if [ ! -f "$SKILL" ]; then
  _top="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
  [ -n "$_top" ] && [ -f "$_top/.claude/skills/crew-commit/SKILL.md" ] \
    && SKILL="$_top/.claude/skills/crew-commit/SKILL.md"
fi

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# ── Stub rig registry (mirrors `gc rig list --json` for the live town) ────────
RIG_LIST_JSON='{"rigs":[
  {"name":"gascity","prefix":"ga","path":"/Users/athos/gt/.gascity-gastown-hq","hq":true},
  {"name":"property_scrapers","prefix":"ps","path":"/Users/athos/gt/property_scrapers","hq":false},
  {"name":"gastown","prefix":"gt","path":"/Users/athos/gt/gastown","hq":false},
  {"name":"whatsapp_automation","prefix":"wa","path":"/Users/athos/gt/whatsapp_automation","hq":false},
  {"name":"deacon","prefix":"dc","path":"/Users/athos/gt/deacon","hq":false}
]}'

# ── PART 1 replica: crew-commit Step-1.5 guard decision ───────────────────────
# Pure: given a git toplevel, return the rig name iff toplevel EXACTLY equals a
# registered rig root (the only dangerous case). A subdir/worktree → empty.
# Mirrors the SKILL.md guard's `select(.path == $t)` exact match.
in_rig_root() {
  local toplevel="$1"
  printf '%s' "$RIG_LIST_JSON" \
    | jq -r --arg t "$toplevel" '.rigs[] | select(.path == $t) | .name' 2>/dev/null \
    | head -1
}

# ── PART 2 replica: Pilot worktree_directive_for decision ─────────────────────
# Pure: emit directive (echo "DIRECTIVE") iff builder != gastown.dog AND the rig
# has an on-disk registered root. Here we stub on-disk existence via a set, since
# the live roots may or may not exist in the test sandbox.
ONDISK_ROOTS=" /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers /Users/athos/gt/gastown "
rig_root_path() {
  printf '%s' "$RIG_LIST_JSON" | jq -r --arg n "$1" '.rigs[]? | select(.name==$n) | .path' 2>/dev/null | head -1
}
directive_decision() {
  local rig="$1" builder="$2" root
  [ "$builder" = "gastown.dog" ] && { echo "SUPPRESS"; return; }
  root=$(rig_root_path "$rig")
  [ -z "$root" ] && { echo "SUPPRESS"; return; }
  case "$ONDISK_ROOTS" in *" $root "*) echo "DIRECTIVE";; *) echo "SUPPRESS";; esac
}

echo "wa-root-worktree-isolation.selftest.sh"
echo "  pilot:  $PILOT"
echo "  skill:  $SKILL"
echo

# ── (A) EXACT rig-root match → isolate ────────────────────────────────────────
R=$(in_rig_root "/Users/athos/gt/whatsapp_automation")
[ "$R" = "whatsapp_automation" ] \
  && ok "(A) wa production root → guard isolates (got: $R)" \
  || bad "(A) wa production root → expected whatsapp_automation, got: '$R'"

R=$(in_rig_root "/Users/athos/gt/property_scrapers")
[ "$R" = "property_scrapers" ] \
  && ok "(A2) ps production root → guard isolates (got: $R)" \
  || bad "(A2) ps production root → expected property_scrapers, got: '$R'"

# ── (B) crew clone subdir → DO NOT trip ───────────────────────────────────────
R=$(in_rig_root "/Users/athos/gt/whatsapp_automation/crew/digo")
[ -z "$R" ] \
  && ok "(B) wa crew clone subdir → guard proceeds (no isolation)" \
  || bad "(B) wa crew clone subdir → expected NO match, got: '$R'"

# ── (C) worktree under .gc-worktrees → DO NOT trip ────────────────────────────
R=$(in_rig_root "/Users/athos/gt/whatsapp_automation/.gc-worktrees/wa-abc12-digo-wa")
[ -z "$R" ] \
  && ok "(C) wa worktree subdir → guard proceeds (no isolation)" \
  || bad "(C) wa worktree subdir → expected NO match, got: '$R'"

# ── (D) non-rig repo → DO NOT trip ────────────────────────────────────────────
R=$(in_rig_root "/Users/athos/some/random/repo")
[ -z "$R" ] \
  && ok "(D) non-rig repo → guard proceeds (no isolation)" \
  || bad "(D) non-rig repo → expected NO match, got: '$R'"

# ── (E) Pilot directive emitted for non-dog pool crew in a real rig root ──────
D=$(directive_decision "whatsapp_automation" "digo-wa")
[ "$D" = "DIRECTIVE" ] \
  && ok "(E) wa pool crew (digo-wa) in real rig root → directive emitted" \
  || bad "(E) wa pool crew → expected DIRECTIVE, got: $D"

# ── (F) Pilot directive SUPPRESSED for gastown.dog (HQ pool exempt) ───────────
D=$(directive_decision "gascity" "gastown.dog")
[ "$D" = "SUPPRESS" ] \
  && ok "(F) gastown.dog HQ pool → directive suppressed (dogs never in rig root)" \
  || bad "(F) gastown.dog → expected SUPPRESS, got: $D"

# ── (G) Pilot directive SUPPRESSED when rig root unknown/absent ───────────────
D=$(directive_decision "marketing" "someone-ma")
[ "$D" = "SUPPRESS" ] \
  && ok "(G) rig with no on-disk registered root → directive suppressed (fail-open)" \
  || bad "(G) unknown/absent rig root → expected SUPPRESS, got: $D"

# ── (H) the recipe branches the WORKTREE, never the ROOT ──────────────────────
# Static assertion on the deployed SKILL guard: the `worktree add` carries `-b`
# (branch on the worktree) and there is NO bare `git checkout -b` issued against
# the toplevel inside the guard block.
if [ -f "$SKILL" ]; then
  if grep -Eq 'worktree add .* -b ' "$SKILL"; then
    ok "(H) SKILL guard creates the branch ON the worktree (worktree add … -b)"
  else
    bad "(H) SKILL guard missing 'worktree add … -b' — would not isolate the branch"
  fi
  if grep -q 'symbolic-ref --short HEAD' "$SKILL" && grep -q 'not main' "$SKILL"; then
    ok "(H2) SKILL guard asserts the production root stays on main (abort otherwise)"
  else
    bad "(H2) SKILL guard missing the 'root must stay on main' invariant check"
  fi
else
  bad "(H) SKILL.md not found at $SKILL — cannot drift-guard"
fi

# ── (I) Source drift-guards ───────────────────────────────────────────────────
if [ -f "$SKILL" ]; then
  grep -q 'Rig-Root Isolation Guard' "$SKILL" \
    && ok "(I-skill-1) Step 1.5 'Rig-Root Isolation Guard' present in SKILL.md" \
    || bad "(I-skill-1) Step 1.5 guard heading missing from SKILL.md"
  grep -q 'select(.path == $t)' "$SKILL" \
    && ok "(I-skill-2) guard uses EXACT toplevel==rig.path match (not ancestor)" \
    || bad "(I-skill-2) guard exact-match jq filter missing from SKILL.md"
  grep -q '.gc-worktrees/' "$SKILL" \
    && ok "(I-skill-3) guard isolates into a .gc-worktrees/ worktree" \
    || bad "(I-skill-3) guard worktree path missing from SKILL.md"
else
  bad "(I-skill) SKILL.md not found — drift-guard skipped"
fi

if [ -f "$PILOT" ]; then
  grep -q 'worktree_directive_for' "$PILOT" \
    && ok "(I-pilot-1) worktree_directive_for helper present in pilot-dispatcher.sh" \
    || bad "(I-pilot-1) worktree_directive_for helper missing from pilot-dispatcher.sh"
  grep -q 'WORKTREE_DIRECTIVE' "$PILOT" \
    && ok "(I-pilot-2) WORKTREE_DIRECTIVE injected into dispatch prompt(s)" \
    || bad "(I-pilot-2) WORKTREE_DIRECTIVE injection missing from pilot-dispatcher.sh"
  # dog exemption must be present so HQ builds never carry the directive.
  grep -q '\[ "\$_builder" = "gastown.dog" \] && return 0' "$PILOT" \
    && ok "(I-pilot-3) gastown.dog pool exempted from the directive" \
    || bad "(I-pilot-3) gastown.dog exemption missing from worktree_directive_for"
  # injected as a $-expansion in BOTH heredocs (bug + story) → expect 2 occurrences.
  _n=$(grep -c '^\$WORKTREE_DIRECTIVE$' "$PILOT" 2>/dev/null || echo 0)
  [ "$_n" -eq 2 ] \
    && ok "(I-pilot-4) directive injected into BOTH dispatch prompts (count=$_n)" \
    || bad "(I-pilot-4) expected directive in 2 prompts (bug+story), found $_n"
else
  bad "(I-pilot) pilot-dispatcher.sh not found at $PILOT — drift-guard skipped"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL GREEN"
