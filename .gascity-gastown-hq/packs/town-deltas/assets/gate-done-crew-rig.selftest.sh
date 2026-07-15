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
#   (I)  ga-8a9n: the ancestor-match OR crashes jq (`.` corrupted by a leading
#        pipe) unless `.path` is bound to a local var before the pipe; a single
#        crashing rig-list element poisons the whole `[...]` array construction,
#        so this fired on nearly every invocation, masked by the fallbacks.
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
  # ga-8a9n: .path bound to $p BEFORE the pipe — see (I) below for why.
  rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg cwd "$cwd" '
    [ .rigs[] | select(.path as $p | ($cwd == $p) or ($cwd | startswith($p + "/"))) ]
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

# ── Stub bead-existence probe (mirrors `bd -C <path> show <id>` exit code) ────
# Reuses the HQ_BEADS/WA_BEADS membership lists above as the source of truth for
# which ids "exist" in which store, for the ga-u4yi validation replica below.
bead_exists_in_store() {
  local path="$1" id="$2"
  case "$path" in
    */.gascity-gastown-hq)
      case "$HQ_BEADS" in *" $id "*) return 0;; *) return 1;; esac ;;
    */whatsapp_automation)
      case "$WA_BEADS" in *" $id "*) return 0;; *) return 1;; esac ;;
    *) return 1 ;;
  esac
}

# validate_bead_id <bead_id> — replica of the ga-u4yi validation block: probe HQ,
# then every registered rig store; empty result means "discard, does not resolve
# anywhere" (the fix for the "demand-mobile" phantom bead_id bug).
validate_bead_id() {
  local bead_id="$1" rig_path
  [ -z "$bead_id" ] && { printf ''; return; }
  if bead_exists_in_store "/Users/athos/gt/.gascity-gastown-hq" "$bead_id"; then
    printf '%s' "$bead_id"; return
  fi
  for rig_path in $(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[].path // empty' 2>/dev/null); do
    if bead_exists_in_store "$rig_path" "$bead_id"; then
      printf '%s' "$bead_id"; return
    fi
  done
  printf ''
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

# ── (H) ga-u4yi: bead_id VALIDATION discards non-existent regex matches ───────
# Root bug (ga-u4yi, filed by thies-wa): the crew/*/* regex is syntactic, not
# semantic — on a descriptive branch (crew/thies/demand-mobile-phase2) it happily
# matches "demand-mobile", which is NOT a bead. Because that value is non-empty,
# the SECONDARY fallback and FAIL-CLOSED guard (both gate on `-z "$BEAD_ID"`) were
# skipped, and a marker shipped with a phantom source-bead no reviewer could find.
B=$(extract_bead_from_branch "crew/thies/demand-mobile-phase2")
[ "$B" = "demand-mobile" ] \
  && ok "(H1) regex still extracts 'demand-mobile' from descriptive branch (pre-validation)" \
  || bad "(H1) expected regex extraction 'demand-mobile', got: $B"
V=$(validate_bead_id "$B")
[ -z "$V" ] \
  && ok "(H2) ga-u4yi repro: 'demand-mobile' does not resolve → validation discards it (got: '$V')" \
  || bad "(H2) ga-u4yi repro: expected discard (empty), got: '$V' — REGRESSION of ga-u4yi"

# real beads — in HQ and in a rig store — must SURVIVE validation (no false positives)
B=$(extract_bead_from_branch "crew/batista/wa-27jn-desc"); V=$(validate_bead_id "$B")
[ "$V" = "wa-27jn" ] \
  && ok "(H3) real rig bead survives validation: wa-27jn (got: '$V')" \
  || bad "(H3) expected wa-27jn to survive validation, got: '$V'"
B=$(extract_bead_from_branch "crew/batista/ga-5uhbs"); V=$(validate_bead_id "$B")
[ "$V" = "ga-5uhbs" ] \
  && ok "(H4) real HQ bead survives validation: ga-5uhbs (got: '$V')" \
  || bad "(H4) expected ga-5uhbs to survive validation, got: '$V'"

# the generic (non-crew) branch case has the SAME class of bug — no trailing '-'
# guarantees the match is a real bead either — validation must catch it too.
B=$(extract_bead_from_branch "fix/totally-fake-desc"); V=$(validate_bead_id "$B")
[ -z "$V" ] \
  && ok "(H5) generic-path bogus match also discarded: 'totally-fake' (got: '$V')" \
  || bad "(H5) expected discard for bogus generic match, got: '$V'"

# ── (I) ga-8a9n: jq `.` context-corruption crash in the ancestor-match OR ─────
# `$cwd | startswith(.path + "/")` rebinds `.` to the STRING $cwd via the
# leading pipe, so `.path` inside startswith() tries to index a string and jq
# errors ("Cannot index string with string \"path\""). Because
# `[.rigs[] | select(...)]` collects every output into ONE array, a single
# crashing element poisons the whole array construction — so this fired on
# nearly every invocation (any rig that wasn't an exact cwd match reached the
# crashing branch), silently masked by the fallbacks below it.
GA8A9N_ERR="$(mktemp)"

# (I1) repro from the bug report: 2-entry array, cwd = the deeper entry. The
# FIXED filter must resolve it with NO jq error.
REPRO_JSON='[{"path":"/foo"},{"path":"/foo/bar"}]'
: > "$GA8A9N_ERR"
I1_OUT=$(printf '%s' "$REPRO_JSON" | jq -r --arg cwd "/foo/bar" '
    [ .[] | select(.path as $p | ($cwd == $p) or ($cwd | startswith($p + "/"))) ]
    | sort_by(.path | length) | last | .path // empty' 2>"$GA8A9N_ERR")
I1_RC=$?
[ "$I1_RC" -eq 0 ] && [ "$I1_OUT" = "/foo/bar" ] \
  && ok "(I1) fixed jq resolves the repro with no error (got: '$I1_OUT')" \
  || bad "(I1) fixed jq repro failed (out='$I1_OUT' rc=$I1_RC stderr='$(cat "$GA8A9N_ERR" 2>/dev/null)')"

# (I2) mutation guard: the ORIGINAL buggy filter (before the `.path as $p`
# binding) MUST still crash on this exact repro — proves (I1) would actually
# catch a reversion of the fix, not just happen to pass either way.
: > "$GA8A9N_ERR"
printf '%s' "$REPRO_JSON" | jq -r --arg cwd "/foo/bar" '
    [ .[] | select(($cwd == .path) or ($cwd | startswith(.path + "/"))) ]
    | sort_by(.path | length) | last | .path // empty' >/dev/null 2>"$GA8A9N_ERR"
I2_RC=$?
[ "$I2_RC" -ne 0 ] && grep -q 'Cannot index string' "$GA8A9N_ERR" \
  && ok "(I2) mutation check: reverting the fix reproduces the original jq crash (rc=$I2_RC)" \
  || bad "(I2) mutation check: reverted (buggy) jq unexpectedly succeeded — (I1) would NOT catch this regression"

# (I3) exact-match on a non-HQ rig, through derive_rig() with EMPTY bead_id and
# gc_agent — neither fallback can fire, so a correct result can only come from
# PRIMARY. This is the case ga-8a9n flagged as silently passing through
# fallback before the fix, poisoned by the OTHER (non-matching) array elements
# during array construction — exactly like the crew/HQ ancestor cases in (A)/(B).
R=$(derive_rig "/Users/athos/gt/whatsapp_automation" "" "")
[ "$R" = "whatsapp_automation" ] \
  && ok "(I3) exact-path match via PRIMARY alone, no fallback available → whatsapp_automation (got: $R)" \
  || bad "(I3) exact-path PRIMARY-only match → expected whatsapp_automation, got: $R"

rm -f "$GA8A9N_ERR"

# ── (G) source drift-guards against deployed gate-done.md ─────────────────────
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF '.path as $p' \
    && ok "(G1) gate-done.md binds .path to a local var before the pipe (ga-8a9n jq-context fix)" \
    || bad "(G1) gate-done.md missing '.path as \$p' binding — ga-8a9n jq-context-corruption regression"
  printf '%s' "$src" | grep -qF 'startswith($p + "/")' \
    && ok "(G1b) gate-done.md uses ANCESTOR-path rig matching via the bound var" \
    || bad "(G1b) gate-done.md missing ancestor-path rig matching (startswith(\$p + \"/\"))"
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
  printf '%s' "$src" | grep -q '_BEAD_ID_RESOLVED' \
    && ok "(G5) gate-done.md validates bead_id existence before trusting the regex match (ga-u4yi)" \
    || bad "(G5) gate-done.md missing ga-u4yi bead_id existence validation"
else
  bad "(G) gate-done.md not found at $GATE_DONE"
fi

# ── (I) ga-dmox: tree-wide unification — every REAL deployed gate-done.md is
#    either the canonical file itself or a symlink resolving to it. Section (G)
#    above only drift-guards ONE resolved path (via a 3-tier fallback); it has
#    zero visibility into the other real copies crews actually execute. ga-dmox
#    found 30 such copies (mayor/, gastown/*, lexbh/*, marketing/*,
#    property_scrapers/*, whatsapp_automation/*) were stale, byte-identical
#    157-line files with NO bead_rig logic at all — genuinely untracked by any
#    git repo (gitignored in the main repo via .git/info/exclude, or inside a
#    separate nested per-crew repo), so no git operation could ever have
#    propagated the ga-owfll/ga-u4yi fixes into them. Fixed by symlinking each
#    to the canonical file (same pattern as the existing root .claude/commands/
#    symlink, ga-x8m6r). This section is the regression guard against that
#    drift recurring — e.g. if a future crew-provisioning step ever recreates a
#    real (non-symlink) file at one of these paths again.
#
#    internal/templates/commands/bodies/gate-done.md is DELIBERATELY EXCLUDED
#    from this list (ga-54iu): it is subject to a live `//go:embed bodies/*.md`
#    in internal/templates/commands/provision.go, and Go's embed refuses to
#    embed symlinks ("irregular files") at compile time — symlinking it here
#    like the other 30 broke `go build ./...` entirely. See section (J) below
#    for its (different) drift guard: real file, content-synced by copy.
TOWN_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
CANONICAL_REAL="$TOWN_ROOT/.gascity-gastown-hq/commands/gate-done.md"

# PROD_ROOT is deliberately the FIXED, real town-root path — NOT $TOWN_ROOT.
# The 30 rig/crew/witness/refinery/mayor directories below are genuinely
# untracked, singleton, machine-wide operational state (excluded via
# .git/info/exclude, or living inside their own separate nested git repos —
# see ga-dmox investigation) — `git worktree add` never materializes them, so
# they exist ONLY at the one real production path, regardless of which
# worktree/branch this selftest is invoked from. This section is therefore an
# infrastructure-audit check against the live town, not a pure test of THIS
# branch's tracked files (unlike the two $TOWN_ROOT-relative entries just
# below, which correctly reflect whatever checkout is under test).
PROD_ROOT="/Users/athos/gt"

if [ ! -f "$CANONICAL_REAL" ]; then
  bad "(I0) canonical gate-done.md not found at $CANONICAL_REAL — cannot run tree-wide check"
else
  # Every path a crew/witness/refinery/mayor session could actually execute.
  # Kept as an explicit list (not a live `find`) so the test doesn't silently
  # start (or stop) covering new directories without a deliberate edit here.
  DEPLOYED_COPIES=(
    "$TOWN_ROOT/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/crew/batista/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/crew/deacon/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/crew/furiosa/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/crew/gastown/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/refinery/rig/.claude/commands/gate-done.md"
    "$PROD_ROOT/gastown/witness/.claude/commands/gate-done.md"
    "$PROD_ROOT/lexbh/crew/batista/.claude/commands/gate-done.md"
    "$PROD_ROOT/lexbh/crew/digo/.claude/commands/gate-done.md"
    "$PROD_ROOT/lexbh/crew/thies/.claude/commands/gate-done.md"
    "$PROD_ROOT/lexbh/refinery/rig/.claude/commands/gate-done.md"
    "$PROD_ROOT/lexbh/witness/.claude/commands/gate-done.md"
    "$PROD_ROOT/marketing/crew/mila/.claude/commands/gate-done.md"
    "$PROD_ROOT/marketing/refinery/rig/.claude/commands/gate-done.md"
    "$PROD_ROOT/marketing/witness/.claude/commands/gate-done.md"
    "$PROD_ROOT/mayor/.claude/commands/gate-done.md"
    "$PROD_ROOT/property_scrapers/crew/batista/.claude/commands/gate-done.md"
    "$PROD_ROOT/property_scrapers/crew/digo/.claude/commands/gate-done.md"
    "$PROD_ROOT/property_scrapers/crew/thies/.claude/commands/gate-done.md"
    "$PROD_ROOT/property_scrapers/refinery/rig/.claude/commands/gate-done.md"
    "$PROD_ROOT/property_scrapers/witness/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/batista/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/digo/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/mila/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/oracle/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/peter/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/property_scrapers/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/crew/thies/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/refinery/rig/.claude/commands/gate-done.md"
    "$PROD_ROOT/whatsapp_automation/witness/rig/.claude/commands/gate-done.md"
  )

  # deployed_copy_status <f> — pure predicate, no ok/bad side effects. Echoes a
  # one-line reason and returns 0 (healthy) or 1 (broken). Kept separate from
  # ok/bad so the mutation-check below can probe a DELIBERATELY-broken path
  # without printing a confusing "✗" for an intentional, temporary break that
  # doesn't count as a real failure.
  deployed_copy_status() {
    local f="$1"
    if [ ! -e "$f" ]; then
      echo "does not exist (was this crew/rig removed? update the list in this test)"
      return 1
    fi
    if [ ! -L "$f" ]; then
      echo "is a REGULAR file, not a symlink to canonical — drifts silently from ga-owfll/ga-u4yi/ga-dmox fixes"
      return 1
    fi
    if ! grep -q 'bead_rig:' "$f" 2>/dev/null; then
      echo "symlink does not resolve to bead_rig-carrying content (broken link or wrong target?)"
      return 1
    fi
    echo "symlinked to canonical, resolves with bead_rig fix present"
    return 0
  }

  for f in "${DEPLOYED_COPIES[@]}"; do
    reason="$(deployed_copy_status "$f")"
    if [ $? -eq 0 ]; then ok "(I) $f: $reason"; else bad "(I) $f: $reason"; fi
  done

  # Mutation check: this section must not be vacuous. Break ONE real symlink
  # (point it at a scratch file with no bead_rig content), confirm the SAME
  # predicate now reports it broken, then restore the original symlink
  # exactly. Uses the whatsapp_automation/crew/oracle copy — arbitrary choice,
  # any one of the 30 would do.
  MUT_TARGET="$PROD_ROOT/whatsapp_automation/crew/oracle/.claude/commands/gate-done.md"
  if [ -L "$MUT_TARGET" ]; then
    ORIG_LINK="$(readlink "$MUT_TARGET")"
    SCRATCH_STALE="$(mktemp)"
    echo "not the real gate-done content" > "$SCRATCH_STALE"
    # Belt-and-suspenders: guarantee restoration even on an unexpected
    # interrupt/kill between the break and the (immediately-following) restore
    # below — this mutates a LIVE crew directory and must never be left broken.
    trap 'rm -f "'"$MUT_TARGET"'"; ln -s -- "'"$ORIG_LINK"'" "'"$MUT_TARGET"'"; rm -f "'"$SCRATCH_STALE"'"' EXIT INT TERM
    rm -- "$MUT_TARGET"
    ln -s -- "$SCRATCH_STALE" "$MUT_TARGET"
    deployed_copy_status "$MUT_TARGET" >/dev/null 2>&1
    MUT_RC=$?
    # Restore immediately, before evaluating the result — a live crew directory
    # must not be left mutated if anything below throws.
    rm -- "$MUT_TARGET"
    ln -s -- "$ORIG_LINK" "$MUT_TARGET"
    rm -f "$SCRATCH_STALE"
    trap - EXIT INT TERM
    if [ "$MUT_RC" -ne 0 ]; then
      ok "(I-mutation) breaking a real symlink is correctly caught by deployed_copy_status (test is not vacuous)"
    else
      bad "(I-mutation) breaking oracle's symlink did NOT get caught — this section may be vacuous"
    fi
    if [ "$(readlink "$MUT_TARGET")" = "$ORIG_LINK" ]; then
      ok "(I-mutation) oracle's real symlink was restored exactly after the mutation check"
    else
      bad "(I-mutation) FAILED TO RESTORE oracle's symlink to '$ORIG_LINK' — got '$(readlink "$MUT_TARGET")' — fix by hand"
    fi
  else
    bad "(I-mutation) $MUT_TARGET is not a symlink — cannot run the mutation check (has (I) already failed above?)"
  fi
fi

# ── (J) ga-54iu: internal/templates/commands/bodies/gate-done.md gets a
#    DIFFERENT drift guard than section (I) above, not the same one. It is
#    matched by a live `//go:embed bodies/*.md` in
#    internal/templates/commands/provision.go, and Go's embed refuses to
#    embed symlinks ("irregular files") at compile time — verified empirically
#    by the quality-gate reviewer, who built the symlinked version and got
#    `pattern bodies/*.md: cannot embed irregular file bodies/gate-done.md`
#    (exit 1), then built the pre-ga-dmox parent commit cleanly (exit 0) with
#    the identical command. So this copy must stay a REAL file, kept in sync
#    with canonical by content copy — this section guards BOTH halves of that
#    invariant (never re-symlinked, never silently drifted).
EMBEDDED_COPY="$TOWN_ROOT/internal/templates/commands/bodies/gate-done.md"
if [ ! -e "$EMBEDDED_COPY" ]; then
  bad "(J0) $EMBEDDED_COPY not found — go:embed bodies/*.md would fail to compile"
elif [ -L "$EMBEDDED_COPY" ]; then
  bad "(J1) $EMBEDDED_COPY is a SYMLINK — go:embed cannot embed symlinks, this breaks 'go build ./...' (ga-54iu regression)"
else
  ok "(J1) $EMBEDDED_COPY is a regular file (go:embed-safe)"
fi

if [ -f "$EMBEDDED_COPY" ] && [ -f "$CANONICAL_REAL" ]; then
  if cmp -s "$EMBEDDED_COPY" "$CANONICAL_REAL"; then
    ok "(J2) $EMBEDDED_COPY content matches canonical byte-for-byte"
  else
    bad "(J2) $EMBEDDED_COPY has DRIFTED from canonical $CANONICAL_REAL — re-copy canonical's content"
  fi

  # Mutation check on a SCRATCH fixture, never on the real tracked file — unlike
  # section (I)'s untracked crew copies, this file IS git-tracked source feeding
  # a compiled binary; mutating it in place risks leaving the working tree (or a
  # concurrent build) broken if this script is interrupted mid-check.
  SCRATCH_DRIFT="$(mktemp)"
  echo "drifted content, not synced with canonical" > "$SCRATCH_DRIFT"
  if cmp -s "$SCRATCH_DRIFT" "$CANONICAL_REAL"; then
    bad "(J-mutation) scratch fixture unexpectedly matches canonical — fixture itself is broken"
  else
    ok "(J-mutation) a deliberately-drifted copy is correctly caught as non-identical (test is not vacuous)"
  fi
  rm -f "$SCRATCH_DRIFT"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
