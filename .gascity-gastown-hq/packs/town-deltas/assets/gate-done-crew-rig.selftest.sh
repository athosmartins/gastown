#!/usr/bin/env bash
# gate-done-crew-rig.selftest.sh (ga-owfll)
#
# Proves the corrected RIG derivation and source-bead store-scoping in /gate-done.
#
# Root bug (ga-owfll, filed by batista-wa):
#   1. RIG fallback invalid for crew in a clone subdir. Crew members work in
#      <rig>/crew/<name> — a SUBDIR of the registered rig path. /gate-done derived
#      RIG with an EXACT path match (`select(.path == $cwd)`) which never matched
#      for crew, then fell back to `${GC_AGENT%%/*}` and wrote the crew AGENT name
#      (e.g. `rig: batista-wa`) — an invalid rig — into the marker. Evidence: live
#      HQ markers carrying `rig: batista-wa`. The dispatcher only survived by an
#      accidental trailing-segment fallback; the marker was still wrong/fragile.
#   2. source-bead rig-scoped outside HQ scope. crew/<name>/<bead> branches were not
#      parsed for the bead id, and the marker recorded no signal of WHICH Dolt store
#      owns the source bead. Framework stories live in HQ (gascity) even when the
#      code-rig is wa/ps/lx, so the dispatcher's default rig-scoped close (BEAD_CITY=
#      RIG_PATH) silently no-ops on an HQ bead → bead stays open → re-dispatched.
#
# Covers:
#   (A)  RIG via ANCESTOR-path match: cwd under <rig>/crew/<name> → that rig
#   (B)  RIG for a dog/HQ cwd → gascity
#   (C)  RIG fallback NEVER emits the raw agent name; maps suffix THROUGH rig list
#        (batista-wa → wa → whatsapp_automation)
#   (D)  RIG fallback via source-bead prefix (wa-27jn → wa → whatsapp_automation)
#   (E)  crew/<name>/<bead-id>[-desc] branch → bead id extracted (3rd segment)
#   (F)  bead_rig probes owning store: ga-* resolves in HQ → gascity; wa-* → rig
#   (G)  Source drift-guards: deployed gate-done.md uses ancestor matching, crew
#        branch extraction, bead_rig recording, and does NOT contain the raw
#        `${GC_AGENT%%/*}` → RIG leak.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (priority order):
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# ── Stub rig list ─────────────────────────────────────────────────────────────
# Mirrors `gc --city <hq> rig list --json` for the live town. Paths are siblings
# under /Users/athos/gt; crew clones live at <rig>/crew/<name>.
RIG_LIST_JSON='{"rigs":[
  {"name":"gascity","prefix":"ga","path":"/Users/athos/gt/.gascity-gastown-hq"},
  {"name":"property_scrapers","prefix":"ps","path":"/Users/athos/gt/property_scrapers"},
  {"name":"marketing","prefix":"mk","path":"/Users/athos/gt/marketing"},
  {"name":"lexbh","prefix":"lx","path":"/Users/athos/gt/lexbh"},
  {"name":"gastown","prefix":"gt","path":"/Users/athos/gt/gastown"},
  {"name":"whatsapp_automation","prefix":"wa","path":"/Users/athos/gt/whatsapp_automation"},
  {"name":"deacon","prefix":"dc","path":"/Users/athos/gt/deacon"}
]}'

# ── Replicas of the corrected gate-done.md logic ──────────────────────────────
# These MUST mirror the deployed command exactly; section (G) asserts the source
# still defines the same structure so the test cannot silently diverge.

# derive_rig <cwd> <bead_id> <gc_agent>
derive_rig() {
  local cwd="$1" bead_id="$2" gc_agent="$3" rig="" bpfx asfx
  # PRIMARY: rig whose path == cwd OR is an ANCESTOR of cwd (longest match).
  rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg cwd "$cwd" '
    [ .rigs[] | select(($cwd == .path) or ($cwd | startswith(.path + "/"))) ]
    | sort_by(.path | length) | last | .name // empty' 2>/dev/null || echo "")
  # FALLBACK 1: source-bead prefix → rig.
  if [ -z "$rig" ] || [ "$rig" = "null" ]; then
    bpfx="${bead_id%%-*}"
    if [ -n "$bpfx" ] && [ "$bpfx" != "$bead_id" ]; then
      rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$bpfx" \
        '.rigs[] | select(.prefix == $p or .name == $p) | .name' 2>/dev/null | head -1 || echo "")
    fi
  fi
  # FALLBACK 2: agent-name rig SUFFIX → rig (mapped THROUGH rig list, never raw).
  if [ -z "$rig" ] || [ "$rig" = "null" ]; then
    asfx="${gc_agent##*-}"
    if [ -n "$asfx" ] && [ "$asfx" != "$gc_agent" ]; then
      rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$asfx" \
        '.rigs[] | select(.prefix == $p or .name == $p) | .name' 2>/dev/null | head -1 || echo "")
    fi
  fi
  [ -z "$rig" ] || [ "$rig" = "null" ] && rig="unknown"
  printf '%s' "$rig"
}

# extract_bead_from_branch <branch>
extract_bead_from_branch() {
  local branch="$1" bead="" seg
  case "$branch" in
    crew/*/*)
      seg=${branch#crew/*/}
      bead=$(printf '%s\n' "$seg" | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}' | head -1 2>/dev/null || echo "")
      ;;
    *)
      bead=$(echo "$branch" | grep -oE '^[^/]+/[a-z]{2,8}-[a-z0-9]{2,8}-' \
        | grep -oE '[a-z]{2,8}-[a-z0-9]{2,8}' 2>/dev/null || echo "")
      ;;
  esac
  printf '%s' "$bead"
}

# bead_rig <bead_id>  — store probe replica (ga-* → HQ/gascity, others → owning rig)
HQ_BEADS=" ga-owfll ga-u70a8 ga-5uhbs ga-dx5 "
WA_BEADS=" wa-27jn wa-iv51 wa-lstd "
bead_rig() {
  local bead="$1"
  case "$HQ_BEADS" in *" $bead "*) printf 'gascity'; return;; esac
  case "$WA_BEADS" in *" $bead "*) printf 'whatsapp_automation'; return;; esac
  printf 'unknown'
}

echo "gate-done-crew-rig.selftest.sh (ga-owfll)"
echo "  source: $GATE_DONE"
echo

# ── (A) crew clone subdir → owning rig ────────────────────────────────────────
R=$(derive_rig "/Users/athos/gt/whatsapp_automation/crew/batista" "wa-27jn" "batista-wa")
[ "$R" = "whatsapp_automation" ] \
  && ok "(A) crew clone subdir cwd → whatsapp_automation (got: $R)" \
  || bad "(A) crew clone subdir cwd → expected whatsapp_automation, got: $R"

R=$(derive_rig "/Users/athos/gt/property_scrapers/crew/batista" "ps-7a1z" "batista-ps")
[ "$R" = "property_scrapers" ] \
  && ok "(A2) ps crew clone subdir → property_scrapers (got: $R)" \
  || bad "(A2) ps crew clone subdir → expected property_scrapers, got: $R"

# ── (B) dog/HQ cwd → gascity ──────────────────────────────────────────────────
R=$(derive_rig "/Users/athos/gt/.gascity-gastown-hq/.gc/agents/dogs/gastown.dog-2" "ga-owfll" "gastown.dog-2")
[ "$R" = "gascity" ] \
  && ok "(B) dog HQ subdir cwd → gascity (got: $R)" \
  || bad "(B) dog HQ subdir cwd → expected gascity, got: $R"

# ── (C) fallback maps agent SUFFIX through rig list, never the raw agent name ──
# cwd that matches NO rig path → must fall back; agent batista-wa → wa → whatsapp_automation.
R=$(derive_rig "/tmp/detached-checkout" "" "batista-wa")
[ "$R" = "whatsapp_automation" ] \
  && ok "(C) no-path-match + agent batista-wa → whatsapp_automation (got: $R)" \
  || bad "(C) agent-suffix fallback → expected whatsapp_automation, got: $R"
[ "$R" != "batista-wa" ] \
  && ok "(C2) RIG is NEVER the raw agent name 'batista-wa'" \
  || bad "(C2) RIG leaked the raw agent name 'batista-wa' (the ga-owfll bug)"

# ── (D) fallback via source-bead prefix ───────────────────────────────────────
R=$(derive_rig "/tmp/detached-checkout" "wa-27jn" "")
[ "$R" = "whatsapp_automation" ] \
  && ok "(D) bead prefix wa-27jn → whatsapp_automation (got: $R)" \
  || bad "(D) bead-prefix fallback → expected whatsapp_automation, got: $R"

# ── (E) crew/<name>/<bead> branch extraction ──────────────────────────────────
B=$(extract_bead_from_branch "crew/batista/wa-27jn"); [ "$B" = "wa-27jn" ] \
  && ok "(E) crew/batista/wa-27jn → wa-27jn (got: $B)" \
  || bad "(E) crew bead extraction → expected wa-27jn, got: $B"
B=$(extract_bead_from_branch "crew/batista/ga-5uhbs"); [ "$B" = "ga-5uhbs" ] \
  && ok "(E2) crew/batista/ga-5uhbs → ga-5uhbs (got: $B)" \
  || bad "(E2) crew bead extraction (HQ bead) → expected ga-5uhbs, got: $B"
B=$(extract_bead_from_branch "crew/whatsapp_automation-claude-1/wa-iv51"); [ "$B" = "wa-iv51" ] \
  && ok "(E3) crew/<compound-name>/wa-iv51 → wa-iv51 (got: $B)" \
  || bad "(E3) crew bead extraction (compound name) → expected wa-iv51, got: $B"
B=$(extract_bead_from_branch "crew/mila/wa-6rdl-touchpoint-fix"); [ "$B" = "wa-6rdl" ] \
  && ok "(E4) crew/mila/wa-6rdl-desc → wa-6rdl (got: $B)" \
  || bad "(E4) crew bead extraction (with desc) → expected wa-6rdl, got: $B"
# generic builder convention still works
B=$(extract_bead_from_branch "fix/ga-owfll-gate-done-crew-rig"); [ "$B" = "ga-owfll" ] \
  && ok "(E5) generic fix/ga-owfll-desc → ga-owfll (got: $B)" \
  || bad "(E5) generic extraction → expected ga-owfll, got: $B"

# ── (F) bead_rig probes the owning store ──────────────────────────────────────
BR=$(bead_rig "ga-owfll"); [ "$BR" = "gascity" ] \
  && ok "(F) HQ bead ga-owfll → bead_rig=gascity (got: $BR)" \
  || bad "(F) ga-owfll owning store → expected gascity, got: $BR"
BR=$(bead_rig "wa-27jn"); [ "$BR" = "whatsapp_automation" ] \
  && ok "(F2) rig bead wa-27jn → bead_rig=whatsapp_automation (got: $BR)" \
  || bad "(F2) wa-27jn owning store → expected whatsapp_automation, got: $BR"

# ── (G) source drift-guards against deployed gate-done.md ─────────────────────
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -q 'startswith(.path + "/")' \
    && ok "(G1) gate-done.md uses ANCESTOR-path rig matching" \
    || bad "(G1) gate-done.md missing ancestor-path rig matching (startswith(.path + \"/\"))"
  printf '%s' "$src" | grep -qE 'crew/\*/\*\)' \
    && ok "(G2) gate-done.md handles crew/<name>/<bead> branches" \
    || bad "(G2) gate-done.md missing crew/*/* branch handling"
  printf '%s' "$src" | grep -q 'bead_rig:' \
    && ok "(G3) gate-done.md records bead_rig (owning store) in the marker" \
    || bad "(G3) gate-done.md missing bead_rig recording"
  # The raw-agent-name leak MUST be gone from LIVE code: `RIG="${GC_AGENT%%/*}"`
  # wrote rig=<agent>. Strip comment lines first — the fix QUOTES the old form in an
  # explanatory comment, which is documentation, not a live code path.
  if printf '%s' "$src" | grep -vE '^[[:space:]]*#' | grep -qE 'RIG="\$\{GC_AGENT%%/\*\}"'; then
    bad "(G4) gate-done.md STILL has a live \${GC_AGENT%%/*} → RIG assignment (the bug)"
  else
    ok "(G4) gate-done.md no longer leaks the raw agent name into RIG (live code)"
  fi
else
  bad "(G) gate-done.md not found at $GATE_DONE"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
