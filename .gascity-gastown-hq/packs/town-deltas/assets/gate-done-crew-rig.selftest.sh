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
#   (P)  ga-3dhdg: the ga-ljbx fix/*-branch rig=gascity pin only fires when the
#        physical cwd is actually inside HQ, not merely because the branch
#        name starts with fix/ (also the everyday convention in non-HQ rigs).
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

# GC_CITY_PATH the real town sets for every session (also used standalone by
# section (P)/(Q) below) — defined here so derive_rig()'s call sites can pass
# the realistic value from the start, exactly like production always does.
GC_CITY_PATH_STUB="/Users/athos/gt/.gascity-gastown-hq"

# ── Replicas of the corrected gate-done.md logic ──────────────────────────────
# These MUST mirror the deployed command exactly; section (G) asserts the source
# still defines the same structure so the test cannot silently diverge.

# derive_rig <cwd> <bead_id> <gc_agent> <gc_city_path>
derive_rig() {
  local cwd="$1" bead_id="$2" gc_agent="$3" gc_city_path="${4:-}" rig="" bpfx asfx
  # PRIMARY: rig whose path == cwd OR is an ANCESTOR of cwd (longest match).
  # ga-8a9n: .path bound to $p BEFORE the pipe — see (I) below for why.
  rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg cwd "$cwd" '
    [ .rigs[] | select(.path as $p | ($cwd == $p) or ($cwd | startswith($p + "/"))) ]
    | sort_by(.path | length) | last | .name // empty' 2>/dev/null || echo "")
  # ga-6mir5 PRIMARY-continued: the check above can never match gascity from
  # ANY cwd — its registered path (gc_city_path) has no .git of its own, so
  # CWD_TOP is always the outer repo root, never equal to or a subdir of it.
  # Catch the reverse containment explicitly: gc_city_path itself is cwd, or
  # a tracked subdir of it.
  if { [ -z "$rig" ] || [ "$rig" = "null" ]; } && [ -n "$gc_city_path" ] && [ -n "$cwd" ]; then
    case "$gc_city_path" in
      "$cwd"|"$cwd"/*) rig="gascity" ;;
    esac
  fi
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
      # ga-pkvfc: optional dotted sub-bead suffix (ps-8iuu.4), plus an
      # identity check — see the deployed source for the full rationale.
      bead=$(printf '%s\n' "$seg" | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}(\.[0-9]+)?' | head -1 2>/dev/null || echo "")
      if [ -n "$bead" ]; then
        case "$seg" in
          "$bead"|"$bead"-*) : ;;
          *) bead="" ;;
        esac
      fi
      ;;
    *)
      # ga-ghnff9: trailing '-' is OPTIONAL — a bare <prefix>/<bead-id> branch
      # (no '-desc' suffix) has nothing after the id, so the '$' alternative
      # matches end-of-string in place of the '-' — see the deployed source
      # for the full rationale.
      bead=$(echo "$branch" | grep -oE '^[^/]+/[a-z]{2,8}-[a-z0-9]{2,8}(-|$)' \
        | grep -oE '[a-z]{2,8}-[a-z0-9]{2,8}' 2>/dev/null || echo "")
      ;;
  esac
  printf '%s' "$bead"
}

# extract_bead_from_branch_prebug <branch> — replica of the ORIGINAL
# (pre-ga-ghnff9) generic-case regex: requires a LITERAL trailing '-'
# immediately after the bead id, so a bare (no-desc) branch never matches.
# The crew/*/* arm is unchanged (that convention already handled bare ids).
extract_bead_from_branch_prebug() {
  local branch="$1" bead="" seg
  case "$branch" in
    crew/*/*)
      seg=${branch#crew/*/}
      bead=$(printf '%s\n' "$seg" | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}(\.[0-9]+)?' | head -1 2>/dev/null || echo "")
      if [ -n "$bead" ]; then
        case "$seg" in
          "$bead"|"$bead"-*) : ;;
          *) bead="" ;;
        esac
      fi
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
PS_BEADS=" ps-8iuu "
bead_rig() {
  local bead="$1"
  case "$HQ_BEADS" in *" $bead "*) printf 'gascity'; return;; esac
  case "$WA_BEADS" in *" $bead "*) printf 'whatsapp_automation'; return;; esac
  printf 'unknown'
}

# ── Stub bead-existence probe (mirrors `bd -C <path> show <id>` exit code) ────
# Reuses the HQ_BEADS/WA_BEADS/PS_BEADS membership lists above as the source of
# truth for which ids "exist" in which store, for the ga-u4yi validation
# replica below. PS_BEADS carries ps-8iuu (a real EPIC bead) — needed for the
# ga-pkvfc (K) section: the parent epic of a truncated dotted sub-bead id is
# genuinely real, which is exactly why existence-check alone was fooled.
bead_exists_in_store() {
  local path="$1" id="$2"
  case "$path" in
    */.gascity-gastown-hq)
      case "$HQ_BEADS" in *" $id "*) return 0;; *) return 1;; esac ;;
    */whatsapp_automation)
      case "$WA_BEADS" in *" $id "*) return 0;; *) return 1;; esac ;;
    */property_scrapers)
      case "$PS_BEADS" in *" $id "*) return 0;; *) return 1;; esac ;;
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
R=$(derive_rig "/Users/athos/gt/whatsapp_automation/crew/batista" "wa-27jn" "batista-wa" "$GC_CITY_PATH_STUB")
[ "$R" = "whatsapp_automation" ] \
  && ok "(A) crew clone subdir cwd → whatsapp_automation (got: $R)" \
  || bad "(A) crew clone subdir cwd → expected whatsapp_automation, got: $R"

R=$(derive_rig "/Users/athos/gt/property_scrapers/crew/batista" "ps-7a1z" "batista-ps" "$GC_CITY_PATH_STUB")
[ "$R" = "property_scrapers" ] \
  && ok "(A2) ps crew clone subdir → property_scrapers (got: $R)" \
  || bad "(A2) ps crew clone subdir → expected property_scrapers, got: $R"

# ── (B) dog/HQ cwd → gascity ──────────────────────────────────────────────────
R=$(derive_rig "/Users/athos/gt/.gascity-gastown-hq/.gc/agents/dogs/gastown.dog-2" "ga-owfll" "gastown.dog-2" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(B) dog HQ subdir cwd → gascity (got: $R)" \
  || bad "(B) dog HQ subdir cwd → expected gascity, got: $R"

# ── (C) fallback maps agent SUFFIX through rig list, never the raw agent name ──
# cwd that matches NO rig path → must fall back; agent batista-wa → wa → whatsapp_automation.
R=$(derive_rig "/tmp/detached-checkout" "" "batista-wa" "$GC_CITY_PATH_STUB")
[ "$R" = "whatsapp_automation" ] \
  && ok "(C) no-path-match + agent batista-wa → whatsapp_automation (got: $R)" \
  || bad "(C) agent-suffix fallback → expected whatsapp_automation, got: $R"
[ "$R" != "batista-wa" ] \
  && ok "(C2) RIG is NEVER the raw agent name 'batista-wa'" \
  || bad "(C2) RIG leaked the raw agent name 'batista-wa' (the ga-owfll bug)"

# ── (D) fallback via source-bead prefix ───────────────────────────────────────
R=$(derive_rig "/tmp/detached-checkout" "wa-27jn" "" "$GC_CITY_PATH_STUB")
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
R=$(derive_rig "/Users/athos/gt/whatsapp_automation" "" "" "$GC_CITY_PATH_STUB")
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

# ── (K) ga-pkvfc: dotted sub-bead id (ps-8iuu.4) no longer truncates to its
#    parent epic (ps-8iuu), and a truncation can no longer sail through on
#    existence alone (existence-check is not identity-check).
#
# Root bug (filed by ps-worker submitting ps-8iuu.4): the crew/*/* char class
# [a-z0-9]{2,8} has no '.', so a dotted sub-bead id truncates at the dot:
# crew/ps-worker/ps-8iuu.4 -> _CREW_SEG=ps-8iuu.4 -> regex -> ps-8iuu (drops
# .4). WORSE (ga-p5q3 class — existence-check without identity-check):
# ps-8iuu IS a real bead (the parent epic), so the ga-u4yi existence-check
# accepted the truncated, WRONG id silently — the marker shipped
# source-bead:ps-8iuu instead of source-bead:ps-8iuu.4, reviewing/closing the
# wrong bead.

# (K1) primary repro, fixed regex + identity-check together.
B=$(extract_bead_from_branch "crew/ps-worker/ps-8iuu.4")
[ "$B" = "ps-8iuu.4" ] \
  && ok "(K1) crew/ps-worker/ps-8iuu.4 -> ps-8iuu.4, not truncated (got: $B)" \
  || bad "(K1) dotted sub-bead extraction -> expected ps-8iuu.4, got: $B"

# (K2) mutation guard: the ORIGINAL buggy regex (no dotted-suffix capture)
# MUST still truncate on this exact repro — proves (K1) would actually catch
# a reversion of the regex fix, not just happen to pass either way.
OLD_REGEX_MATCH=$(printf '%s\n' "ps-8iuu.4" | grep -oE '^[a-z]{2,8}-[a-z0-9]{2,8}' | head -1)
[ "$OLD_REGEX_MATCH" = "ps-8iuu" ] \
  && ok "(K2) mutation check: pre-fix regex truncates ps-8iuu.4 -> ps-8iuu, reproducing the original bug" \
  || bad "(K2) mutation check: pre-fix regex unexpectedly did not truncate (got '$OLD_REGEX_MATCH') — (K1) would not catch a regex reversion"

# (K3a) ga-p5q3 class: prove the OLD buggy regex output ('ps-8iuu') resolves
# via the EXISTENCE-only validator (it IS a real bead — the parent epic) —
# this is exactly why an existence-check-only validation silently accepted
# the truncated id.
EXISTS_CHECK=$(validate_bead_id "$OLD_REGEX_MATCH")
[ "$EXISTS_CHECK" = "ps-8iuu" ] \
  && ok "(K3a) existence-only check WOULD accept truncated 'ps-8iuu' (it is a real epic bead) — proves existence-check alone is not enough" \
  || bad "(K3a) expected existence-only check to accept 'ps-8iuu' for this demo to be meaningful, got '$EXISTS_CHECK'"

# (K3b) the FULL extractor (regex + identity check together) never produces
# the truncated id in the first place for this branch — the identity check
# discards it before existence is ever consulted.
B=$(extract_bead_from_branch "crew/ps-worker/ps-8iuu.4")
[ "$B" != "ps-8iuu" ] \
  && ok "(K3b) full extractor never yields the truncated 'ps-8iuu' for crew/ps-worker/ps-8iuu.4 (got: '$B')" \
  || bad "(K3b) full extractor yielded truncated 'ps-8iuu' — the ga-p5q3-class silent-wrong-bead bug is back"

# (K4) legitimate '-desc' suffix still survives the identity check (no
# false-positive rejection of the documented crew/<name>/<STORY_ID>[-desc]
# convention).
B=$(extract_bead_from_branch "crew/mila/wa-6rdl-touchpoint-fix")
[ "$B" = "wa-6rdl" ] \
  && ok "(K4) crew branch with -desc suffix still resolves correctly: wa-6rdl (got: $B)" \
  || bad "(K4) -desc suffix regression -> expected wa-6rdl, got: $B"

# (K5) a double-digit sub-bead suffix does not truncate either — guards
# against an off-by-bound regression in the digit class.
B=$(extract_bead_from_branch "crew/thies/ps-8iuu.12")
[ "$B" = "ps-8iuu.12" ] \
  && ok "(K5) double-digit sub-bead suffix survives: ps-8iuu.12 (got: $B)" \
  || bad "(K5) double-digit sub-bead suffix -> expected ps-8iuu.12, got: $B"

# (K6) demand-mobile-phase2 (the ga-u4yi repro) must still be rejected by
# existence, unchanged by the (K) identity check — a descriptive branch with
# no real bead id embedded looks exactly like "BEAD_ID-desc" syntactically,
# so identity alone cannot reject it; existence (H1/H2 above) must still
# carry that case. Guards against the two checks silently swapping roles.
B=$(extract_bead_from_branch "crew/thies/demand-mobile-phase2")
[ "$B" = "demand-mobile" ] \
  && ok "(K6) identity check still lets 'demand-mobile' through syntactically (existence check must catch it — see H2)" \
  || bad "(K6) identity check unexpectedly rejected 'demand-mobile' — see if H1/H2 still pass unchanged"

# ── (L) ga-pkvfc source drift-guard: deployed gate-done.md captures the
#    dotted suffix and performs the identity check, not just existence.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF '(\.[0-9]+)?' \
    && ok "(L1) gate-done.md crew regex captures the optional dotted sub-bead suffix" \
    || bad "(L1) gate-done.md missing the dotted sub-bead suffix capture group (ga-pkvfc regression)"
  printf '%s' "$src" | grep -qF '"$BEAD_ID"|"$BEAD_ID"-*' \
    && ok "(L2) gate-done.md performs the identity/boundary check (segment == BEAD_ID or BEAD_ID-desc)" \
    || bad "(L2) gate-done.md missing the ga-pkvfc identity check (existence-check-only regression)"
else
  bad "(L) gate-done.md not found at $GATE_DONE"
fi

# ── (M) ga-kkwsa: Step 3 (marker creation) fails closed if BRANCH or BEAD_ID
#    is empty, mirroring the fail-closed pattern Step 2 already uses for
#    BEAD_ID (see the FAIL CLOSED block feeding (H)/(K) above).
#
# Root bug (ga-kkwsa, filed by gastown.dog-2 from a live incident): the
# skill presents Pre-flight/Step 1/Step 2/Step 3 as 4 separate ```bash
# blocks. This harness's Bash tool persists CWD between calls but NOT shell
# variable state, so running Step 2 and Step 3 as separate tool calls leaves
# every var Step 3 references (BRANCH, BEAD_ID, ...) unset in Step 3's shell.
# Step 3's old success check only verified $MARKER_ID was non-empty (i.e.
# `bd create` itself succeeded) — it never checked that the CONTENT it just
# wrote was non-empty. Result: a real incident created marker ga-wisp-vv2pmqo
# with title "ready-for-gate: " and every interpolated field blank, which sat
# unreviewable at gate-status:queued for 44+ minutes before anyone noticed.
#
# step3_marker_guard <branch> <bead_id> — replica of the ga-kkwsa fail-closed
# guard added to the TOP of Step 3, before the `bd create` call. Returns 0
# (safe to proceed) or 1 (must abort BEFORE calling bd create).
step3_marker_guard() {
  local branch="$1" bead_id="$2"
  [ -z "$branch" ] && return 1
  [ -z "$bead_id" ] && return 1
  return 0
}

# run_step3_fixed / run_step3_prefix — replicas of the FULL Step 3 flow
# (guard, then create) for the fixed and pre-fix shapes respectively.
# MOCK_BD_CREATE_CALLS proves whether `bd create` — the exact call that
# shipped the blank marker in the real incident — was ever reached.
MOCK_BD_CREATE_CALLS=0
mock_bd_create() { MOCK_BD_CREATE_CALLS=$((MOCK_BD_CREATE_CALLS+1)); }
run_step3_fixed() {
  local branch="$1" bead_id="$2"
  step3_marker_guard "$branch" "$bead_id" || return 1
  mock_bd_create
  return 0
}
run_step3_prefix() {
  # pre-ga-kkwsa Step 3: no guard at all, goes straight to bd create
  # regardless of blank vars — the exact incident shape.
  mock_bd_create
  return 0
}

# (M1) both blank — the exact incident shape (Step 2 never ran in this shell).
MOCK_BD_CREATE_CALLS=0
run_step3_fixed "" ""
M1_RC=$?
[ "$M1_RC" -ne 0 ] && [ "$MOCK_BD_CREATE_CALLS" -eq 0 ] \
  && ok "(M1) blank BRANCH+BEAD_ID: guard aborts (rc=$M1_RC), bd create NOT called" \
  || bad "(M1) blank BRANCH+BEAD_ID: expected abort with zero bd-create calls, got rc=$M1_RC calls=$MOCK_BD_CREATE_CALLS"

# (M2) BRANCH set, BEAD_ID blank.
MOCK_BD_CREATE_CALLS=0
run_step3_fixed "fix/ga-z5cm2-guard" ""
M2_RC=$?
[ "$M2_RC" -ne 0 ] && [ "$MOCK_BD_CREATE_CALLS" -eq 0 ] \
  && ok "(M2) blank BEAD_ID alone: guard aborts, bd create NOT called" \
  || bad "(M2) blank BEAD_ID alone: expected abort with zero bd-create calls, got rc=$M2_RC calls=$MOCK_BD_CREATE_CALLS"

# (M3) BEAD_ID set, BRANCH blank.
MOCK_BD_CREATE_CALLS=0
run_step3_fixed "" "ga-z5cm2"
M3_RC=$?
[ "$M3_RC" -ne 0 ] && [ "$MOCK_BD_CREATE_CALLS" -eq 0 ] \
  && ok "(M3) blank BRANCH alone: guard aborts, bd create NOT called" \
  || bad "(M3) blank BRANCH alone: expected abort with zero bd-create calls, got rc=$M3_RC calls=$MOCK_BD_CREATE_CALLS"

# (M4) control: both populated — the normal, working case must be UNCHANGED.
MOCK_BD_CREATE_CALLS=0
run_step3_fixed "fix/ga-z5cm2-guard" "ga-z5cm2"
M4_RC=$?
[ "$M4_RC" -eq 0 ] && [ "$MOCK_BD_CREATE_CALLS" -eq 1 ] \
  && ok "(M4) control: populated vars → marker created exactly once, no behavior change" \
  || bad "(M4) control: expected success with exactly 1 bd-create call, got rc=$M4_RC calls=$MOCK_BD_CREATE_CALLS"

# (M5) mutation guard: the ORIGINAL (pre-fix) Step 3 — no guard at all — MUST
# still call bd create even with both vars blank, reproducing the exact
# incident. Proves M1-M3 would actually catch a reversion of the guard, not
# just happen to pass either way.
MOCK_BD_CREATE_CALLS=0
run_step3_prefix "" ""
[ "$MOCK_BD_CREATE_CALLS" -eq 1 ] \
  && ok "(M5) mutation check: pre-fix Step 3 (no guard) creates a blank marker from empty vars — reproduces the ga-kkwsa incident" \
  || bad "(M5) mutation check: pre-fix replica unexpectedly did not call bd create — (M1-M3) would not catch a guard reversion"

# ── (N) ga-kkwsa source drift-guard: deployed gate-done.md's Step 3 fails
#    closed on blank BRANCH/BEAD_ID BEFORE calling bd create.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  # Isolate Step 3's block so this cannot be satisfied by Step 2's UNRELATED
  # BEAD_ID fail-closed guard earlier in the same file.
  step3_src=$(printf '%s\n' "$src" | awk '/^## Step 3:/{flag=1} flag; /^## Step 4:/{flag=0}')
  printf '%s' "$step3_src" | grep -qE '\[ -z "\$BRANCH" \]' \
    && ok "(N1) gate-done.md Step 3 checks for blank BRANCH before creating the marker" \
    || bad "(N1) gate-done.md Step 3 missing a blank-BRANCH check (ga-kkwsa regression)"
  printf '%s' "$step3_src" | grep -qE '\[ -z "\$BEAD_ID" \]' \
    && ok "(N2) gate-done.md Step 3 checks for blank BEAD_ID before creating the marker" \
    || bad "(N2) gate-done.md Step 3 missing a blank-BEAD_ID check (ga-kkwsa regression)"
  # The guard must appear BEFORE the `bd ... create` call within Step 3, not
  # merely somewhere in the block.
  guard_line=$(printf '%s\n' "$step3_src" | grep -nE '\[ -z "\$BRANCH" \] \|\| \[ -z "\$BEAD_ID" \]' | head -1 | cut -d: -f1)
  create_line=$(printf '%s\n' "$step3_src" | grep -nE '^MARKER_ID=\$\(bd ' | head -1 | cut -d: -f1)
  if [ -n "$guard_line" ] && [ -n "$create_line" ] && [ "$guard_line" -lt "$create_line" ]; then
    ok "(N3) gate-done.md Step 3 guard runs BEFORE the bd create call (line $guard_line < $create_line)"
  else
    bad "(N3) gate-done.md Step 3 guard does not precede bd create (guard_line='$guard_line' create_line='$create_line')"
  fi
else
  bad "(N) gate-done.md not found at $GATE_DONE"
fi

# ── (O) ga-ogvyk source drift-guard: /gate-done runs a mandatory pre-flight
#    self-audit for the "third state" (error-vs-empty) defect class BEFORE
#    the marker is created, and records the result in the marker so the
#    practice leaves a trail instead of living only in prose nobody executes.
#
# Root bug (ga-ogvyk, filed by the Mayor from a live measurement): the gate
# rejected six submissions in one day for the SAME defect class
# (root-class:error-vs-empty) — reviewers catch it consistently, but only
# AFTER a full review cycle burns, and only the cited example is learned, not
# the class (one bead was rejected on this shape 3 times running). The rule
# lived only in the reviewer's prompt template — a path builders never read
# before submitting — so it never reached the WRITE side at all.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'Pre-flight Self-Audit: THE THIRD STATE' \
    && ok "(O1) gate-done.md has a mandatory Pre-flight Self-Audit section" \
    || bad "(O1) gate-done.md missing the Pre-flight Self-Audit section (ga-ogvyk regression)"
  printf '%s' "$src" | grep -qF 'root-class:error-vs-empty' \
    && ok "(O2) gate-done.md's self-audit cites the same taxonomy reviewers use (root-class:error-vs-empty)" \
    || bad "(O2) gate-done.md self-audit missing the root-class:error-vs-empty cross-reference"

  # The audit must run BEFORE Step 1 (push) — catching a bug here should be
  # cheap (fix, recommit, re-push), not something discovered after the
  # branch is already on origin and a marker is one command away.
  audit_line=$(printf '%s\n' "$src" | grep -nF '## Pre-flight Self-Audit: THE THIRD STATE' | head -1 | cut -d: -f1)
  step1_line=$(printf '%s\n' "$src" | grep -nE '^## Step 1:' | head -1 | cut -d: -f1)
  if [ -n "$audit_line" ] && [ -n "$step1_line" ] && [ "$audit_line" -lt "$step1_line" ]; then
    ok "(O3) gate-done.md's self-audit section runs BEFORE Step 1 (line $audit_line < $step1_line)"
  else
    bad "(O3) gate-done.md's self-audit section does not precede Step 1 (audit_line='$audit_line' step1_line='$step1_line')"
  fi

  # The result must be RECORDED in the marker (Step 3), not just asked for in
  # prose — a check that leaves no trace can't be measured later, which is
  # exactly the failure mode ga-ogvyk's acceptance criteria warns about.
  step3_src=$(printf '%s\n' "$src" | awk '/^## Step 3:/{flag=1} flag; /^## Step 4:/{flag=0}')
  printf '%s' "$step3_src" | grep -qF 'self_audit: $SELF_AUDIT_SUMMARY' \
    && ok "(O4) gate-done.md Step 3 records self_audit in the marker description" \
    || bad "(O4) gate-done.md Step 3 missing the self_audit: field (ga-ogvyk regression)"

  # This must FAIL OPEN, not closed: the sweep is a judgment call, not a
  # lint (ga-ogvyk's explicit NAO FAZER), and a hard block would just train
  # builders to type a meaningless string to get past it (Goodhart) instead
  # of doing the sweep. Assert the parameter-expansion DEFAULT exists
  # (fail-open) and that Step 3 does NOT separately abort on a blank
  # SELF_AUDIT_SUMMARY (which would be a fail-closed regression). Written as
  # explicit if/then, not the file's usual &&/|| idiom — inverted polarity
  # ("presence is the BAD outcome") is exactly the kind of collapsed-boolean
  # shape this whole section exists to catch, so the check for it should not
  # itself read ambiguously.
  printf '%s' "$step3_src" | grep -qF 'SELF_AUDIT_SUMMARY:-' \
    && ok "(O5a) gate-done.md Step 3 defaults SELF_AUDIT_SUMMARY when unset (fail-open)" \
    || bad "(O5a) gate-done.md Step 3 missing the SELF_AUDIT_SUMMARY fallback default"
  if printf '%s' "$step3_src" | grep -qE '\[ -z "\$SELF_AUDIT_SUMMARY" \]'; then
    bad "(O5b) gate-done.md Step 3 hard-blocks on blank SELF_AUDIT_SUMMARY — must stay fail-open (ga-ogvyk: judgment sweep, not a lint)"
  else
    ok "(O5b) gate-done.md Step 3 does not hard-block on SELF_AUDIT_SUMMARY (correctly fail-open)"
  fi
else
  bad "(O) gate-done.md not found at $GATE_DONE"
fi

# ── (P) ga-3dhdg: the ga-ljbx pin only fires when CWD is ACTUALLY inside HQ,
#    not merely because the branch name starts with fix/.
#
# Root bug (ga-3dhdg, filed by the Mayor from a live near-miss): fix/* is also
# the everyday branch convention in non-HQ rigs (whatsapp_automation alone has
# 54 origin/fix/* branches). The pin fired on the branch text alone and
# stomped a correctly-derived non-HQ RIG with "gascity", stranding the marker
# in the wrong repo — concretely, fix/ga-c1yqp-panel-canonical-state (code in
# whatsapp_automation/daemons/painel_visibilidade.py) would have shipped with
# rig=gascity had the builder not hand-authored the marker to work around it
# (ga-v1i9b).

# apply_ljbx_pin <branch> <cwd_physical> <rig> <gc_city_path> — replica of the
# FIXED pin: gate on cwd_physical being INSIDE gc_city_path, not branch text.
# Also replicates the `-n "$gc_city_path"` guard: an empty gc_city_path must
# NEVER match (the "$gc_city_path"/* glob would otherwise collapse to the
# match-everything pattern `/*`).
apply_ljbx_pin() {
  local branch="$1" cwd_physical="$2" rig="$3" gc_city_path="$4"
  case "$branch" in
    fix/*)
      if [ -n "$gc_city_path" ]; then
        case "$cwd_physical" in
          "$gc_city_path"|"$gc_city_path"/*)
            [ "$rig" != "gascity" ] && rig="gascity"
            ;;
        esac
      fi
      ;;
  esac
  printf '%s' "$rig"
}

# apply_ljbx_pin_prebug <branch> <rig> — replica of the ORIGINAL (buggy) pin,
# used only by the (P5) mutation guard to prove (P1) would have caught the
# regression, not just happened to pass either way.
apply_ljbx_pin_prebug() {
  local branch="$1" rig="$2"
  case "$branch" in
    fix/*) [ "$rig" != "gascity" ] && rig="gascity" ;;
  esac
  printf '%s' "$rig"
}

GC_CITY_PATH_STUB="/Users/athos/gt/.gascity-gastown-hq"

# (P1) the exact repro: fix/* branch, cwd physically inside whatsapp_automation
# (a real, separate git repo — PRIMARY correctly derives it), must NOT be
# stomped to gascity.
R=$(apply_ljbx_pin "fix/ga-c1yqp-panel-canonical-state" "/Users/athos/gt/whatsapp_automation" "whatsapp_automation" "$GC_CITY_PATH_STUB")
[ "$R" = "whatsapp_automation" ] \
  && ok "(P1) fix/* branch authored in whatsapp_automation keeps RIG=whatsapp_automation (got: $R)" \
  || bad "(P1) fix/* branch in whatsapp_automation → expected whatsapp_automation, got: $R (ga-3dhdg regression)"

# (P2) genuine HQ self-fix: cwd physically inside gascity's registered path
# (e.g. a worktree nested under it) — the pin must STILL fire, preserving
# ga-ljbx's original protective intent for the case it was written for.
R=$(apply_ljbx_pin "fix/ga-3dhdg" "$GC_CITY_PATH_STUB/.gc-worktrees/fix-ga-3dhdg-gate-rig-pin/.gascity-gastown-hq" "unknown" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(P2) fix/* branch authored inside HQ still pins to gascity (got: $R)" \
  || bad "(P2) fix/* branch inside HQ → expected gascity, got: $R (ga-ljbx protection lost)"

# (P3) exact cwd == gc_city_path (no trailing subdir) also pins — boundary
# case for the equality arm of the case pattern.
R=$(apply_ljbx_pin "fix/ga-owfll" "$GC_CITY_PATH_STUB" "unknown" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(P3) fix/* branch with cwd EXACTLY at gc_city_path pins to gascity (got: $R)" \
  || bad "(P3) fix/* branch cwd == gc_city_path → expected gascity, got: $R"

# (P4) non-fix branch (e.g. crew/*/*) is never touched by the pin regardless
# of cwd — control, proves the outer case-branch gating is unchanged.
R=$(apply_ljbx_pin "crew/batista/wa-27jn" "$GC_CITY_PATH_STUB" "whatsapp_automation" "$GC_CITY_PATH_STUB")
[ "$R" = "whatsapp_automation" ] \
  && ok "(P4) non-fix/* branch is never touched by the pin (got: $R)" \
  || bad "(P4) non-fix/* branch → expected untouched whatsapp_automation, got: $R"

# (P5) mutation guard: the ORIGINAL (pre-fix) pin, given the EXACT (P1) repro
# inputs, DOES incorrectly stomp to gascity — proves (P1) would have caught
# ga-3dhdg, not just happened to pass either way.
R=$(apply_ljbx_pin_prebug "fix/ga-c1yqp-panel-canonical-state" "whatsapp_automation")
[ "$R" = "gascity" ] \
  && ok "(P5) mutation check: pre-fix pin stomps the (P1) repro to gascity, reproducing ga-3dhdg" \
  || bad "(P5) mutation check: pre-fix pin unexpectedly did not stomp — (P1) would not catch a reversion"

# (P6) third-state edge case: an EMPTY gc_city_path must never match (the
# "$gc_city_path"/* glob would otherwise collapse to `/*`, matching every
# physical cwd — a confidently-wrong pin from a value the guard doesn't
# actually have).
R=$(apply_ljbx_pin "fix/ga-c1yqp-panel-canonical-state" "/Users/athos/gt/whatsapp_automation" "whatsapp_automation" "")
[ "$R" = "whatsapp_automation" ] \
  && ok "(P6) empty gc_city_path never false-positive-matches (got: $R)" \
  || bad "(P6) empty gc_city_path → expected untouched whatsapp_automation, got: $R (glob-collapse regression)"

# ── (Q) ga-3dhdg source drift-guard: deployed gate-done.md gates the ga-ljbx
#    pin on the physical cwd being inside $GC_CITY_PATH, not on branch text
#    alone.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'CWD_PHYSICAL=$(pwd -P' \
    && ok "(Q1) gate-done.md computes CWD_PHYSICAL via pwd -P for the ga-ljbx pin" \
    || bad "(Q1) gate-done.md missing CWD_PHYSICAL computation (ga-3dhdg regression)"
  printf '%s' "$src" | grep -qF '"$GC_CITY_PATH"|"$GC_CITY_PATH"/*)' \
    && ok "(Q2) gate-done.md's ga-ljbx pin gates on CWD_PHYSICAL being inside \$GC_CITY_PATH, not branch text alone" \
    || bad "(Q2) gate-done.md's ga-ljbx pin missing the GC_CITY_PATH containment gate (ga-3dhdg regression)"
  printf '%s' "$src" | grep -qF -- '-n "$GC_CITY_PATH"' \
    && ok "(Q3) gate-done.md guards the ga-ljbx pin against an empty \$GC_CITY_PATH (no glob-collapse false-positive)" \
    || bad "(Q3) gate-done.md's ga-ljbx pin missing the empty-GC_CITY_PATH guard (P6 regression)"
else
  bad "(Q) gate-done.md not found at $GATE_DONE"
fi

# ── (R) ga-6mir5: PRIMARY-continued reverse-containment match for the HQ/self
#    rig, so a framework fix delivered from the repo root (not from inside
#    .gascity-gastown-hq) no longer falls through to the bead-id-prefix
#    fallback and gets mis-resolved to the BEAD's rig instead of the CODE's.
#
# Root bug (ga-6mir5, real incident 13/08, wa-sowus): PRIMARY's containment
# check only recognizes cwd being INSIDE a rig's registered path. gascity's
# registered path (.gascity-gastown-hq) has no .git of its own, so it is
# ALWAYS a subdirectory of the git toplevel, never the reverse — PRIMARY can
# never match it from any cwd. A wa-* bead whose fix was pushed from the repo
# root fell straight to the bead-prefix fallback (wa- → whatsapp_automation),
# even though the branch lived on origin in the ROOT repo the whole time. The
# gate then searched the wrong repo, found nothing, and permanently
# circuit-broke the marker — telling the author their pushed, live work had
# vanished. (The ga-6mir5 dispatcher-side cross-repo-rescue fix is a separate,
# complementary safety net for when RIG is STILL wrong for some other reason;
# this section covers preventing the wrong value in the first place.)

# (R1) primary repro: cwd is the repo root itself (not inside
# .gascity-gastown-hq), bead is wa-* — must resolve gascity, not
# whatsapp_automation from the bead prefix.
R=$(derive_rig "/Users/athos/gt" "wa-sowus" "mayor" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(R1) cwd=repo root, bead=wa-sowus → gascity, not the bead's own rig (got: $R)" \
  || bad "(R1) repo-root cwd with wa-* bead → expected gascity, got: $R (ga-6mir5 regression)"

# (R2) real-git-topology check: derive_rig's <cwd> parameter is always fed
# CWD_TOP — the git toplevel, already normalized by `git rev-parse
# --show-toplevel` — never a raw un-normalized pwd. (R1) only proves the
# LOGIC is correct given that premise; this proves the premise itself: a
# worker physically standing in packs/town-deltas/assets/ (the exact
# directory the real wa-sowus incident's file lives in, and NOT itself
# nested under .gascity-gastown-hq) computes the IDENTICAL CWD_TOP as one
# standing at the bare repo root or inside .gascity-gastown-hq — because
# none of those three locations has a .git of its own. Real git, not a
# hardcoded string — this is exactly the fact that made PRIMARY permanently
# blind to gascity (verified live, 2026-08-13).
R2_TOP_ROOT=$(git -C "$TOWN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")
R2_TOP_HQ=$(git -C "$TOWN_ROOT/.gascity-gastown-hq" rev-parse --show-toplevel 2>/dev/null || echo "")
R2_TOP_PACKS=$(git -C "$TOWN_ROOT/packs/town-deltas/assets" rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$R2_TOP_ROOT" ] && [ "$R2_TOP_ROOT" = "$R2_TOP_HQ" ] && [ "$R2_TOP_ROOT" = "$R2_TOP_PACKS" ]; then
  ok "(R2) real git: toplevel from repo-root/.gascity-gastown-hq/packs-town-deltas-assets all agree ($R2_TOP_ROOT) — CWD_TOP is invariant across the whole repo, confirming the premise this fix depends on"
else
  bad "(R2) real git: toplevel mismatch — root='$R2_TOP_ROOT' hq='$R2_TOP_HQ' packs='$R2_TOP_PACKS' (if these differ, ga-6mir5's fix no longer applies as designed)"
fi

# (R3) a ps-* bead shows the same shape (not wa-specific) — the CLASS is "any
# bead prefix, code delivered at the repo root", not one rig's prefix.
R=$(derive_rig "/Users/athos/gt" "ps-9k2m" "digo-ps" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(R3) cwd=repo root, bead=ps-9k2m → gascity, proving this is a CLASS fix, not wa-specific (got: $R)" \
  || bad "(R3) repo-root cwd with ps-* bead → expected gascity, got: $R"

# (R4) control: a bead resolved via the crew-clone ANCESTOR match (test A)
# must be COMPLETELY unaffected — PRIMARY already found a real, more specific
# match before this new check even runs.
R=$(derive_rig "/Users/athos/gt/whatsapp_automation/crew/batista" "wa-27jn" "batista-wa" "$GC_CITY_PATH_STUB")
[ "$R" = "whatsapp_automation" ] \
  && ok "(R4) control: crew-clone PRIMARY match still wins, untouched by the new check (got: $R)" \
  || bad "(R4) control: crew-clone match → expected whatsapp_automation, got: $R"

# (R5) control: with NO gc_city_path supplied (simulates an unset
# $GC_CITY_PATH), the new check must not fire at all — the same repo-root cwd
# falls through to the bead-prefix fallback exactly as it did before this fix,
# rather than crashing or silently mismatching.
R=$(derive_rig "/Users/athos/gt" "wa-sowus" "mayor" "")
[ "$R" = "whatsapp_automation" ] \
  && ok "(R5) control: empty gc_city_path → new check inert, old (bead-prefix) behavior preserved (got: $R)" \
  || bad "(R5) control: empty gc_city_path → expected old fallback behavior (whatsapp_automation), got: $R"

# (R6) mutation guard: the ORIGINAL (pre-ga-6mir5) derive_rig — PRIMARY plus
# the two fallbacks, no reverse-containment check — given the EXACT (R1) repro
# inputs, DOES mis-resolve to whatsapp_automation. Proves (R1) would actually
# catch a reversion, not just happen to pass either way.
derive_rig_prebug() {
  local cwd="$1" bead_id="$2" gc_agent="$3" rig="" bpfx asfx
  rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg cwd "$cwd" '
    [ .rigs[] | select(.path as $p | ($cwd == $p) or ($cwd | startswith($p + "/"))) ]
    | sort_by(.path | length) | last | .name // empty' 2>/dev/null || echo "")
  if [ -z "$rig" ] || [ "$rig" = "null" ]; then
    bpfx="${bead_id%%-*}"
    if [ -n "$bpfx" ] && [ "$bpfx" != "$bead_id" ]; then
      rig=$(printf '%s' "$RIG_LIST_JSON" | jq -r --arg p "$bpfx" \
        '.rigs[] | select(.prefix == $p or .name == $p) | .name' 2>/dev/null | head -1 || echo "")
    fi
  fi
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
R=$(derive_rig_prebug "/Users/athos/gt" "wa-sowus" "mayor")
[ "$R" = "whatsapp_automation" ] \
  && ok "(R6) mutation check: pre-fix derive_rig mis-resolves the (R1) repro to whatsapp_automation, reproducing ga-6mir5" \
  || bad "(R6) mutation check: pre-fix replica unexpectedly resolved to '$R' — (R1) would not catch a reversion"

# ── (S) ga-6mir5 source drift-guard: deployed gate-done.md contains the
#    PRIMARY-continued reverse-containment check, positioned BEFORE FALLBACK 1
#    (so it takes priority over the bead-prefix heuristic, not just patches
#    around it after the fact).
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'ga-6mir5 PRIMARY-continued' \
    && ok "(S1) gate-done.md has the ga-6mir5 PRIMARY-continued reverse-containment check" \
    || bad "(S1) gate-done.md missing the ga-6mir5 fix (regression)"
  printf '%s' "$src" | grep -qF '"$GC_CITY_PATH" in' \
    && ok "(S2) gate-done.md's new check tests containment against \$GC_CITY_PATH" \
    || bad "(S2) gate-done.md's ga-6mir5 check missing the \$GC_CITY_PATH case pattern"
  new_check_line=$(printf '%s\n' "$src" | grep -nF 'ga-6mir5 PRIMARY-continued' | head -1 | cut -d: -f1)
  fallback1_line=$(printf '%s\n' "$src" | grep -nF 'ga-owfll FALLBACK 1' | head -1 | cut -d: -f1)
  if [ -n "$new_check_line" ] && [ -n "$fallback1_line" ] && [ "$new_check_line" -lt "$fallback1_line" ]; then
    ok "(S3) gate-done.md's ga-6mir5 check runs BEFORE FALLBACK 1 (line $new_check_line < $fallback1_line)"
  else
    bad "(S3) gate-done.md's ga-6mir5 check does not precede FALLBACK 1 (new_check_line='$new_check_line' fallback1_line='$fallback1_line')"
  fi
else
  bad "(S) gate-done.md not found at $GATE_DONE"
fi

# ── (T) ga-3xuanq: crew/generic branch bead-id extraction no longer TRUNCATES
#    a custom bead id that embeds a '-' beyond the {2,8} char-class cap, and
#    no longer silently ships that truncated id when it "exists" only as a
#    PREFIX of a longer real bead.
#
# Root bug (ga-3xuanq, filed by digo-wa from a live incident, 15/08): a
# crew/<name>/<STORY_ID>[-desc] branch where STORY_ID itself is a custom id
# with an embedded hyphen (wa-campanha-diaria, created via `bd create --id`)
# truncates to "wa-campanha" (8-char cap on the second regex token). The
# ga-pkvfc identity/boundary guard ("$BEAD_ID"|"$BEAD_ID"-*) cannot catch
# this: "wa-campanha-diaria" legitimately starts with "wa-campanha-", so the
# guard reads it as "id=wa-campanha, desc=diaria" — syntactically
# indistinguishable from a real '-desc' suffix. Because `bd show` itself
# resolves by PREFIX, the existing ga-u4yi existence-only validation (H/K
# above) also can't catch it: "wa-campanha" "exists" (it resolves onto
# wa-campanha-diaria), so the marker ships with the WRONG, truncated
# source-bead. Live repro: marker ga-tyi7k3 shipped source-bead:wa-campanha
# for branch crew/digo/wa-campanha-diaria; fixed by hand before the sweep.
#
# The SAME char-class cap exists in the generic (fix/*, feat/*, ...) branch
# convention with NO guard at all — the (T) tests below cover both paths.

# Extend the fixture stores with the exact repro bead, plus the ga-pkvfc
# dotted sub-bead ITSELF (not just its parent epic — PS_BEADS above only
# carried "ps-8iuu" because the older existence-only stub never needed to
# resolve the full dotted id; the new prefix-resolving stub does), so the
# resolution replica below can be probed against realistic data rather than
# synthetic candidates.
WA_BEADS=" wa-27jn wa-iv51 wa-lstd wa-campanha-diaria "
PS_BEADS=" ps-8iuu ps-8iuu.4 "

# bead_resolve_prefix_in_store <path> <candidate> — mirrors `bd -C <path>
# show <candidate> --json | jq .id`: bd resolves by PREFIX (ga-3xuanq's own
# bug report: "bd resolve por PREFIXO"), succeeding iff the candidate is an
# unambiguous (exactly one match) prefix of some bead's real id in that
# store, returning that bead's REAL id. This is a DIFFERENT (stricter, more
# accurate) stub than bead_exists_in_store above, which only checks EXACT
# membership and therefore cannot reproduce this bug class at all — "wa-
# campanha" is not itself a member of WA_BEADS, only a prefix of one of its
# entries.
bead_resolve_prefix_in_store() {
  local path="$1" candidate="$2" list="" b n=0 found=""
  case "$path" in
    */.gascity-gastown-hq) list="$HQ_BEADS" ;;
    */whatsapp_automation) list="$WA_BEADS" ;;
    */property_scrapers) list="$PS_BEADS" ;;
    *) printf ''; return ;;
  esac
  for b in $list; do
    case "$b" in
      "$candidate"*) n=$((n+1)); found="$b" ;;
    esac
  done
  [ "$n" -eq 1 ] && printf '%s' "$found" || printf ''
}

# resolve_bead_id_from_branch <branch> — FULL replica of the FIXED gate-done.md
# logic: extract_bead_from_branch() (UNCHANGED, still the exact deployed
# regex+guard) -> prefix-resolve across stores, HQ then every registered rig
# (same probe order validate_bead_id above already uses) -> exact-identity
# upgrade against the real (untruncated) branch segment.
resolve_bead_id_from_branch() {
  local branch="$1" seg bead resolved rig_path
  case "$branch" in
    crew/*/*) seg=${branch#crew/*/} ;;
    */*) seg=${branch#*/} ;;
    *) seg="" ;;
  esac
  bead=$(extract_bead_from_branch "$branch")
  [ -z "$bead" ] && { printf ''; return; }
  resolved=$(bead_resolve_prefix_in_store "$GC_CITY_PATH_STUB" "$bead")
  if [ -z "$resolved" ]; then
    for rig_path in $(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[].path // empty' 2>/dev/null); do
      resolved=$(bead_resolve_prefix_in_store "$rig_path" "$bead")
      [ -n "$resolved" ] && break
    done
  fi
  [ -z "$resolved" ] && { printf ''; return; }
  if [ "$resolved" != "$bead" ]; then
    case "$seg" in
      "$resolved"|"$resolved"-*) bead="$resolved" ;;
    esac
  fi
  printf '%s' "$bead"
}

# resolve_bead_id_from_branch_prebug <branch> — replica of the ORIGINAL
# (pre-ga-3xuanq) resolution: existence via prefix is trusted AS INPUT
# IDENTITY — the candidate is kept verbatim once any store resolves it,
# never upgraded to the store's own longer id. This is exactly what real
# `bd show "$BEAD_ID" >/dev/null 2>&1` (exit-code-only) checking did.
resolve_bead_id_from_branch_prebug() {
  local branch="$1" bead resolved rig_path
  bead=$(extract_bead_from_branch "$branch")
  [ -z "$bead" ] && { printf ''; return; }
  resolved=$(bead_resolve_prefix_in_store "$GC_CITY_PATH_STUB" "$bead")
  if [ -n "$resolved" ]; then printf '%s' "$bead"; return; fi
  for rig_path in $(printf '%s' "$RIG_LIST_JSON" | jq -r '.rigs[].path // empty' 2>/dev/null); do
    resolved=$(bead_resolve_prefix_in_store "$rig_path" "$bead")
    if [ -n "$resolved" ]; then printf '%s' "$bead"; return; fi
  done
  printf ''
}

# (T1) primary repro: crew branch, custom id with an embedded hyphen, NO
# desc suffix at all — the exact live incident shape.
B=$(resolve_bead_id_from_branch "crew/digo/wa-campanha-diaria")
[ "$B" = "wa-campanha-diaria" ] \
  && ok "(T1) crew/digo/wa-campanha-diaria -> wa-campanha-diaria, not truncated (got: $B)" \
  || bad "(T1) embedded-hyphen crew id -> expected wa-campanha-diaria, got: $B"

# (T2) mutation guard: the ORIGINAL (pre-fix) resolution, given the EXACT
# (T1) repro, DOES ship the truncated id — proves (T1) would have caught the
# live ga-tyi7k3 incident, not just happened to pass either way.
B=$(resolve_bead_id_from_branch_prebug "crew/digo/wa-campanha-diaria")
[ "$B" = "wa-campanha" ] \
  && ok "(T2) mutation check: pre-fix resolution ships truncated 'wa-campanha', reproducing the ga-tyi7k3 incident" \
  || bad "(T2) mutation check: pre-fix replica unexpectedly produced '$B' — (T1) would not catch a reversion"

# (T3) same class, GENERIC (non-crew) branch convention — no guard at all
# protected this path before the fix.
B=$(resolve_bead_id_from_branch "fix/wa-campanha-diaria-desc")
[ "$B" = "wa-campanha-diaria" ] \
  && ok "(T3) fix/wa-campanha-diaria-desc -> wa-campanha-diaria, not truncated (got: $B)" \
  || bad "(T3) embedded-hyphen generic id -> expected wa-campanha-diaria, got: $B"

# (T4) mutation guard for the generic path.
B=$(resolve_bead_id_from_branch_prebug "fix/wa-campanha-diaria-desc")
[ "$B" = "wa-campanha" ] \
  && ok "(T4) mutation check: pre-fix generic-path resolution also ships truncated 'wa-campanha'" \
  || bad "(T4) mutation check: pre-fix generic replica unexpectedly produced '$B'"

# (T5) control: a real bead whose id does NOT need extending (short id, real
# '-desc' suffix) must resolve exactly as before — no upgrade, no regression.
B=$(resolve_bead_id_from_branch "crew/batista/wa-27jn-desc")
[ "$B" = "wa-27jn" ] \
  && ok "(T5) control: short real id with genuine -desc suffix still resolves to wa-27jn (got: $B)" \
  || bad "(T5) control regression: expected wa-27jn, got: $B"

# (T6) control: the ga-u4yi phantom-bead case (demand-mobile-phase2) must
# still be discarded entirely — no store resolves any prefix of it, so the
# upgrade path never even engages.
B=$(resolve_bead_id_from_branch "crew/thies/demand-mobile-phase2")
[ -z "$B" ] \
  && ok "(T6) control: phantom bead 'demand-mobile-phase2' still discarded (got: '$B')" \
  || bad "(T6) control regression: expected discard, got: '$B'"

# (T7) control: the ga-pkvfc dotted sub-bead case (ps-8iuu.4) still resolves
# to its own full id, not its parent epic — proves the new upgrade path
# doesn't interfere with the existing dotted-suffix protection.
B=$(resolve_bead_id_from_branch "crew/ps-worker/ps-8iuu.4")
[ "$B" = "ps-8iuu.4" ] \
  && ok "(T7) control: dotted sub-bead ps-8iuu.4 still resolves correctly (got: $B)" \
  || bad "(T7) control regression: expected ps-8iuu.4, got: $B"

# ── (U) ga-3xuanq source drift-guard: deployed gate-done.md carries the
#    exact-identity upgrade step, positioned to run AFTER the existing
#    ga-u4yi existence check (not replacing it).
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'ga-3xuanq' \
    && ok "(U1) gate-done.md references the ga-3xuanq fix" \
    || bad "(U1) gate-done.md missing the ga-3xuanq fix marker (regression)"
  printf '%s' "$src" | grep -qF '_BRANCH_SEG=""' \
    && ok "(U2) gate-done.md initializes _BRANCH_SEG before the branch-convention case" \
    || bad "(U2) gate-done.md missing _BRANCH_SEG initialization (ga-3xuanq regression)"
  printf '%s' "$src" | grep -qF '_RESOLVED_FULL_ID=' \
    && ok "(U3) gate-done.md queries the resolving store for the bead's own full id" \
    || bad "(U3) gate-done.md missing the _RESOLVED_FULL_ID exact-identity lookup (ga-3xuanq regression)"
  # The upgrade must run AFTER the ga-u4yi existence check succeeds, not
  # before/instead of it — it depends on $_BEAD_HOME_RIG_PATH, which only the
  # existence check populates.
  existence_line=$(printf '%s\n' "$src" | grep -nF '_BEAD_ID_RESOLVED=1' | head -1 | cut -d: -f1)
  upgrade_line=$(printf '%s\n' "$src" | grep -nF '_RESOLVED_FULL_ID=' | head -1 | cut -d: -f1)
  if [ -n "$existence_line" ] && [ -n "$upgrade_line" ] && [ "$existence_line" -lt "$upgrade_line" ]; then
    ok "(U4) gate-done.md's exact-identity upgrade runs AFTER the ga-u4yi existence check (line $existence_line < $upgrade_line)"
  else
    bad "(U4) gate-done.md's upgrade does not follow the existence check (existence_line='$existence_line' upgrade_line='$upgrade_line')"
  fi
else
  bad "(U) gate-done.md not found at $GATE_DONE"
fi

# ── (V) gate-feedback ga-3xuanq attempt 1: the exact-identity upgrade's
#    identity probe (bd show --json | jq .id) must FAIL CLOSED when the
#    probe itself is inconclusive (bd RPC failure, garbled JSON, or a
#    response missing .id) — not silently keep the UNVERIFIED candidate.
#
# Root bug (reviewer finding on marker ga-qqnftg / gate-run ga-5geigo,
# 15/08): the original one-line pipeline
#   _RESOLVED_FULL_ID=$(bd ... --json | jq -r '...' || echo "")
# cannot tell "resolved and already correct" apart from "the bd/jq call
# itself failed" — both collapse into the same downstream behavior (BEAD_ID
# left unchanged), so a transient Dolt hiccup during the SECOND probe
# silently shipped the truncated, unverified candidate — reproducing the
# very ga-3xuanq/ga-tyi7k3 bug this diff exists to fix. The fix captures
# bd's own exit status and raw stdout BEFORE ever handing input to jq, so a
# failed probe is its own state and gets the same discard-and-fallback
# treatment the sibling existence check above already applies.

# resolve_identity_probe <mode> <bead> <resolved> <branch_seg> — replica of
# the FIXED gate-done.md identity-upgrade block. <mode> simulates the second
# bd probe's outcome:
#   ok_same     — probe succeeds, resolved id equals the candidate (no-op)
#   ok_diff     — probe succeeds, resolved id differs, branch text confirms it
#   ok_mismatch — probe succeeds, resolved id differs, branch text does NOT
#                 confirm it (coincidental unrelated prefix — existing
#                 accepted fuzzy behavior, must stay a no-op)
#   fail_hard   — bd itself exits nonzero (transient RPC failure)
#   fail_garbled— bd exits 0 but prints unparseable/truncated JSON
#   fail_no_id  — bd exits 0 with valid JSON that has no .id field
resolve_identity_probe() {
  local mode="$1" bead="$2" resolved="$3" branch_seg="$4"
  local rc=0 json="" full="" known=""
  case "$mode" in
    ok_same)      rc=0; json="{\"id\":\"$bead\"}" ;;
    ok_diff)      rc=0; json="{\"id\":\"$resolved\"}" ;;
    ok_mismatch)  rc=0; json="{\"id\":\"$resolved\"}" ;;
    fail_hard)    rc=1; json="" ;;
    fail_garbled) rc=0; json='{"id": "wa-c' ;;
    fail_no_id)   rc=0; json='{}' ;;
  esac
  if [ "$rc" -eq 0 ] && [ -n "$json" ]; then
    full=$(printf '%s' "$json" | jq -r 'if type=="array" then .[0] else . end | .id // empty' 2>/dev/null)
    [ $? -eq 0 ] && [ -n "$full" ] && known=1
  fi
  if [ -n "$known" ]; then
    if [ "$full" != "$bead" ]; then
      case "$branch_seg" in
        "$full"|"$full"-*) bead="$full" ;;
      esac
    fi
  else
    bead=""
  fi
  printf '%s' "$bead"
}

# resolve_identity_probe_prebug <mode> <bead> <resolved> <branch_seg> —
# replica of the ORIGINAL (pre-fix) block: a single collapsed pipeline with
# `|| echo ""` as the only failure handling, which cannot distinguish
# "resolved and equal" from "probe failed" — both produce the effective
# no-upgrade outcome, so on failure the UNVERIFIED candidate survives.
resolve_identity_probe_prebug() {
  local mode="$1" bead="$2" resolved="$3" branch_seg="$4"
  local json="" full=""
  case "$mode" in
    ok_same)      json="{\"id\":\"$bead\"}" ;;
    ok_diff)      json="{\"id\":\"$resolved\"}" ;;
    ok_mismatch)  json="{\"id\":\"$resolved\"}" ;;
    fail_hard)    json="" ;;
    fail_garbled) json='{"id": "wa-c' ;;
    fail_no_id)   json='{}' ;;
  esac
  full=$(printf '%s' "$json" | jq -r 'if type=="array" then .[0] else . end | .id // empty' 2>/dev/null || echo "")
  if [ -n "$full" ] && [ "$full" != "$bead" ]; then
    case "$branch_seg" in
      "$full"|"$full"-*) bead="$full" ;;
    esac
  fi
  printf '%s' "$bead"
}

# (V1) already correct — no upgrade needed, unchanged.
B=$(resolve_identity_probe ok_same "wa-27jn" "wa-27jn" "wa-27jn-desc")
[ "$B" = "wa-27jn" ] \
  && ok "(V1) probe confirms already-correct id, no upgrade (got: $B)" \
  || bad "(V1) expected wa-27jn unchanged, got: $B"

# (V2) primary repro: probe succeeds, confirms the longer id, branch text
# backs it up -> upgrade.
B=$(resolve_identity_probe ok_diff "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ "$B" = "wa-campanha-diaria" ] \
  && ok "(V2) probe confirms truncated->full upgrade (got: $B)" \
  || bad "(V2) expected wa-campanha-diaria, got: $B"

# (V3) control: coincidental unrelated-prefix hit — branch text does not
# back up the resolved id, so the short candidate survives unchanged (same
# fuzzy edge case that predates this fix, not a regression to close here).
B=$(resolve_identity_probe ok_mismatch "wa-campanha" "wa-campanha-outro" "wa-campanha-diaria")
[ "$B" = "wa-campanha" ] \
  && ok "(V3) control: coincidental prefix hit stays unchanged (got: $B)" \
  || bad "(V3) control regression: expected wa-campanha, got: $B"

# (V4) blocking issue repro: bd itself fails (transient RPC hiccup) -> MUST
# fail closed (discard), never silently trust the unverified candidate.
B=$(resolve_identity_probe fail_hard "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ -z "$B" ] \
  && ok "(V4) bd RPC failure discards the unverified candidate (got: '$B')" \
  || bad "(V4) expected discard (empty), got: '$B' — unverified truncated id survived a failed probe"

# (V5) same class: bd exits 0 but the JSON is garbled/truncated.
B=$(resolve_identity_probe fail_garbled "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ -z "$B" ] \
  && ok "(V5) garbled JSON response discards the unverified candidate (got: '$B')" \
  || bad "(V5) expected discard (empty), got: '$B'"

# (V6) same class: bd exits 0 with valid JSON but no .id field.
B=$(resolve_identity_probe fail_no_id "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ -z "$B" ] \
  && ok "(V6) response with no .id field discards the unverified candidate (got: '$B')" \
  || bad "(V6) expected discard (empty), got: '$B'"

# (V7) mutation guard: the ORIGINAL (pre-fix) replica, given the EXACT (V4)
# repro, silently ships the truncated 'wa-campanha' instead of discarding —
# proves (V4) would have caught the actual reviewed regression, not just
# happened to pass either way.
B=$(resolve_identity_probe_prebug fail_hard "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ "$B" = "wa-campanha" ] \
  && ok "(V7) mutation check: pre-fix replica ships unverified 'wa-campanha' on a failed probe" \
  || bad "(V7) mutation check: pre-fix replica unexpectedly produced '$B' — (V4) would not catch a reversion"

# (V8) mutation guard for the garbled-JSON failure mode.
B=$(resolve_identity_probe_prebug fail_garbled "wa-campanha" "wa-campanha-diaria" "wa-campanha-diaria")
[ "$B" = "wa-campanha" ] \
  && ok "(V8) mutation check: pre-fix replica ships unverified 'wa-campanha' on garbled JSON" \
  || bad "(V8) mutation check: pre-fix replica unexpectedly produced '$B'"

# ── (W) gate-feedback ga-3xuanq attempt 1 source drift-guard: deployed
#    gate-done.md carries the two-step capture (bd's exit status checked
#    BEFORE jq ever runs) instead of the collapsed one-line pipeline. Does
#    NOT grep for the removed `|| echo ""` idiom itself — that construct is
#    used legitimately elsewhere in the file for unrelated probes, so its
#    mere presence/absence is not a reliable signal; only markers unique to
#    THIS fix are checked.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF '_BEAD_ID_JSON_RC' \
    && ok "(W1) gate-done.md captures bd's own exit status separately from jq's parse" \
    || bad "(W1) gate-done.md missing _BEAD_ID_JSON_RC (gate-feedback ga-3xuanq attempt 1 regression)"
  printf '%s' "$src" | grep -qF '_RESOLVED_FULL_ID_KNOWN' \
    && ok "(W2) gate-done.md tracks whether the identity probe positively resolved" \
    || bad "(W2) gate-done.md missing _RESOLVED_FULL_ID_KNOWN (gate-feedback ga-3xuanq attempt 1 regression)"
  known_line=$(printf '%s\n' "$src" | grep -nF '_RESOLVED_FULL_ID_KNOWN=1' | head -1 | cut -d: -f1)
  discard_line=$(printf '%s\n' "$src" | grep -nF 'identity probe failed' | head -1 | cut -d: -f1)
  if [ -n "$known_line" ] && [ -n "$discard_line" ] && [ "$known_line" -lt "$discard_line" ]; then
    ok "(W3) gate-done.md's fail-closed discard runs in the else of the known-identity check (line $known_line < $discard_line)"
  else
    bad "(W3) gate-done.md's fail-closed discard not positioned correctly (known_line='$known_line' discard_line='$discard_line')"
  fi
else
  bad "(W) gate-done.md not found at $GATE_DONE"
fi

# ── (X) ga-ghnff9: a bare <prefix>/<bead-id> branch with NO '-desc' suffix
#    (e.g. fix/ga-okcgb) failed to resolve at all — a DIFFERENT failure mode
#    than ga-3xuanq's silent truncation (missing-match vs wrong-match),
#    found while fixing ga-3xuanq in the exact same case block and scoped
#    out at the time. The generic '*/*)' arm's first grep required a
#    literal trailing '-' right after the bead id; a bare id has nothing
#    after it at all, so the match failed outright, BEAD_ID came back
#    empty, and Step 2 hit the fail-closed guard: "ERROR: Cannot resolve
#    owning story bead...". Live incidents: fix/ga-okcgb (2026-08-13) and
#    fix/ga-7mbry (2026-08-09), both hand-worked around by renaming the
#    branch to add a throwaway -desc suffix.

# (X1) primary repro: bare generic branch, no desc suffix at all.
B=$(extract_bead_from_branch "fix/ga-okcgb")
[ "$B" = "ga-okcgb" ] \
  && ok "(X1) fix/ga-okcgb -> ga-okcgb, bare id resolves (got: $B)" \
  || bad "(X1) bare generic branch -> expected ga-okcgb, got: '$B'"

# (X2) mutation guard: the ORIGINAL (pre-ga-ghnff9) generic regex, given the
# EXACT (X1) repro, returns empty — proves (X1) would have caught the live
# fix/ga-okcgb incident, not just happened to pass either way.
B=$(extract_bead_from_branch_prebug "fix/ga-okcgb")
[ -z "$B" ] \
  && ok "(X2) mutation check: pre-fix generic regex returns empty on a bare branch, reproducing the fix/ga-okcgb incident" \
  || bad "(X2) mutation check: pre-fix replica unexpectedly produced '$B' — (X1) would not catch a reversion"

# (X3) control: a real '-desc' suffix still resolves exactly as before — no
# regression on the case this regex already handled correctly.
B=$(extract_bead_from_branch "fix/ga-dx5-my-fix")
[ "$B" = "ga-dx5" ] \
  && ok "(X3) control: fix/ga-dx5-my-fix still resolves to ga-dx5 (got: $B)" \
  || bad "(X3) control regression: expected ga-dx5, got: '$B'"

# (X4) control: the crew/*/* arm (a separate case branch, untouched by this
# fix) still resolves a bare crew id exactly as before.
B=$(extract_bead_from_branch "crew/thies/ga-dx5")
[ "$B" = "ga-dx5" ] \
  && ok "(X4) control: crew/thies/ga-dx5 (bare, crew convention) still resolves to ga-dx5 (got: $B)" \
  || bad "(X4) control regression: expected ga-dx5, got: '$B'"

# (X5) end-to-end: the bare id survives the FULL pipeline (extraction +
# prefix-store existence probe), not just the low-level regex — a real bead
# that exists in a non-HQ rig store, referenced by a bare fix/* branch.
B=$(resolve_bead_id_from_branch "fix/wa-27jn")
[ "$B" = "wa-27jn" ] \
  && ok "(X5) end-to-end: fix/wa-27jn resolves through the full pipeline (got: $B)" \
  || bad "(X5) end-to-end regression: expected wa-27jn, got: '$B'"

# (X6) source drift-guard: deployed gate-done.md's generic-case regex
# carries the '(-|$)' alternation, not just a literal trailing '-'.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'ga-ghnff9' \
    && ok "(X6a) gate-done.md references the ga-ghnff9 fix" \
    || bad "(X6a) gate-done.md missing the ga-ghnff9 fix marker (regression)"
  printf '%s' "$src" | grep -qF '[a-z]{2,8}-[a-z0-9]{2,8}(-|$)' \
    && ok "(X6b) gate-done.md's generic-case regex accepts end-of-string as an alternative to a trailing '-'" \
    || bad "(X6b) gate-done.md's generic-case regex missing the '(-|\$)' alternation (ga-ghnff9 regression)"
else
  bad "(X6) gate-done.md not found at $GATE_DONE"
fi

# ── (Y) ga-5nshv: the ga-ljbx pin no longer stomps a correctly-derived
#    non-gascity RIG just because the worktree is PHYSICALLY parked under
#    $GC_CITY_PATH — it now checks whether the worktree's own git origin
#    unambiguously belongs to a DIFFERENT, distinct-origin rig first.
#
# Root bug (ga-5nshv, filed by dog-ga7z8hj from a live near-miss): this
# city's own documented worktree-parking convention
# ($GC_CITY_PATH/.gc-worktrees/, packs/town-deltas CLAUDE.md's "Idioma
# WORKTREE" recipe) places a worktree's DIRECTORY under HQ regardless of
# which repo/rig the worktree's CODE actually belongs to — a worktree's
# physical location and its git identity (origin, object store, commit
# history) are independent facts. The (P)/(Q) pin above already correctly
# gates on physical containment vs. branch text (ga-3dhdg) but still
# conflates "physically under HQ" with "code belongs to gascity" — exactly
# the gap ga-3dhdg's own SUGGESTED FIX DIRECTION flagged as unresolved.
# Reproduced live: a fix/wa-* worktree created off whatsapp_automation's
# main but parked at .gascity-gastown-hq/.gc-worktrees/ga-1bxea-fix got
# pinned to rig=gascity, where neither the branch nor its base_commit SHA
# resolve — a gate-runner following that value would strand or error.
# Two more worktrees already living under this convention right now
# (.gc-worktrees/ga-xd0zg-rebase, ga-ydpng-rebase, for fix/wa-xd0zg-rebase
# / fix/wa-ydpng-rebase) were AT RISK of the exact same mis-pin.

# apply_ljbx_pin_with_origin <branch> <cwd_physical> <cwd_top> <rig>
# <gc_city_path> <rig_list_json> — replica of the FIXED pin. Uses REAL git
# calls against the REAL, live registered-rig directories already used
# elsewhere in this file (no synthetic repos needed) — cwd_top is
# deliberately a SEPARATE parameter from cwd_physical, exactly modeling the
# bug: a worktree's git identity (what `git -C <path> remote get-url
# origin` reports) and its physical parking directory are independent.
apply_ljbx_pin_with_origin() {
  local branch="$1" cwd_physical="$2" cwd_top="$3" rig="$4" gc_city_path="$5" rig_list_json="$6"
  case "$branch" in
    fix/*)
      if [ -n "$gc_city_path" ]; then
        case "$cwd_physical" in
          "$gc_city_path"|"$gc_city_path"/*)
            local cwd_origin_url cwd_origin_norm origin_match_rig="" origin_match_count=0
            local orig_rig_name orig_rig_path orig_rig_url orig_rig_norm
            cwd_origin_url=$(git -C "$cwd_top" remote get-url origin 2>/dev/null || echo "")
            if [ -n "$cwd_origin_url" ]; then
              cwd_origin_norm=$(printf '%s' "$cwd_origin_url" | sed -E 's#\.git/?$##; s#/$##')
              for orig_rig_name in $(printf '%s' "$rig_list_json" | jq -r '.rigs[].name // empty' 2>/dev/null); do
                orig_rig_path=$(printf '%s' "$rig_list_json" | jq -r --arg n "$orig_rig_name" '.rigs[] | select(.name==$n) | .path' 2>/dev/null | head -1)
                [ -z "$orig_rig_path" ] && continue
                orig_rig_url=$(git -C "$orig_rig_path" remote get-url origin 2>/dev/null || echo "")
                [ -z "$orig_rig_url" ] && continue
                orig_rig_norm=$(printf '%s' "$orig_rig_url" | sed -E 's#\.git/?$##; s#/$##')
                if [ "$orig_rig_norm" = "$cwd_origin_norm" ]; then
                  origin_match_rig="$orig_rig_name"
                  origin_match_count=$((origin_match_count + 1))
                fi
              done
            fi
            if [ "$origin_match_count" -eq 1 ] && [ "$origin_match_rig" != "gascity" ]; then
              rig="$origin_match_rig"
            elif [ "$rig" != "gascity" ]; then
              rig="gascity"
            fi
            ;;
        esac
      fi
      ;;
  esac
  printf '%s' "$rig"
}

# (Y1) primary repro: the EXACT at-risk worktree named in the bug report
# (fix/wa-xd0zg-rebase, parked at .gc-worktrees/ga-xd0zg-rebase under HQ,
# code from whatsapp_automation — a real repo with its own distinct
# origin). RIG going in is already correctly "whatsapp_automation" (as
# FALLBACK 1's bead-prefix derivation would produce for a wa-* bead) — the
# OLD pin stomped this correct value to gascity purely from physical
# location; the fix must leave it alone.
R=$(apply_ljbx_pin_with_origin "fix/wa-xd0zg-rebase" \
  "$GC_CITY_PATH_STUB/.gc-worktrees/ga-xd0zg-rebase" \
  "/Users/athos/gt/whatsapp_automation" "whatsapp_automation" "$GC_CITY_PATH_STUB" "$RIG_LIST_JSON")
[ "$R" = "whatsapp_automation" ] \
  && ok "(Y1) worktree under HQ with whatsapp_automation origin keeps RIG=whatsapp_automation, not stomped to gascity (got: $R)" \
  || bad "(Y1) worktree-under-HQ + distinct-origin repro → expected whatsapp_automation, got: $R (ga-5nshv regression)"

# (Y2) control: a GENUINE HQ self-fix worktree (cwd_top really is gascity's
# own registered path) must still pin to gascity — ga-ljbx's original
# protective intent, unchanged.
R=$(apply_ljbx_pin_with_origin "fix/ga-5nshv-gate-done-rig" \
  "$GC_CITY_PATH_STUB/.gc-worktrees/fix-ga-5nshv-gate-done-rig" \
  "$GC_CITY_PATH_STUB" "unknown" "$GC_CITY_PATH_STUB" "$RIG_LIST_JSON")
[ "$R" = "gascity" ] \
  && ok "(Y2) control: a genuine HQ self-fix worktree still pins to gascity (got: $R)" \
  || bad "(Y2) control: genuine HQ self-fix → expected gascity, got: $R (ga-ljbx protection lost)"

# (Y3) ambiguous-collision control: cwd_top is gastown's real registered
# path — gastown shares ONE origin URL with gascity AND deacon (all three
# are tracked subdirs of the same outer monorepo, verified live 2026-08-18,
# no rig has its own .git). An origin match against 3 candidates is exactly
# as inconclusive as no match — must fall through to the OLD physical-path
# pin (gascity) rather than guess, proving the fix does not misfire on the
# case it cannot actually disambiguate.
R=$(apply_ljbx_pin_with_origin "fix/gt-abc123-something" \
  "$GC_CITY_PATH_STUB/.gc-worktrees/gt-abc123-something" \
  "/Users/athos/gt/gastown" "unknown" "$GC_CITY_PATH_STUB" "$RIG_LIST_JSON")
[ "$R" = "gascity" ] \
  && ok "(Y3) ambiguous-origin worktree (shared by gascity/gastown/deacon) safely falls through to the old pin, not a wrong guess (got: $R)" \
  || bad "(Y3) ambiguous-origin worktree → expected safe fallthrough to gascity, got: $R"

# (Y4) control: non-fix/* branch is never touched, exactly like (P4) —
# proves the outer case-branch gating is unchanged by this addition.
R=$(apply_ljbx_pin_with_origin "crew/batista/wa-27jn" \
  "$GC_CITY_PATH_STUB" "/Users/athos/gt/whatsapp_automation" "whatsapp_automation" "$GC_CITY_PATH_STUB" "$RIG_LIST_JSON")
[ "$R" = "whatsapp_automation" ] \
  && ok "(Y4) control: non-fix/* branch is never touched by the origin check (got: $R)" \
  || bad "(Y4) control: non-fix/* branch → expected untouched whatsapp_automation, got: $R"

# (Y5) mutation guard: the ORIGINAL (pre-ga-5nshv) pin — apply_ljbx_pin(),
# already defined above for (P), which has no concept of cwd_top/origin at
# all — given the EXACT (Y1) repro's branch/cwd_physical/rig/gc_city_path,
# DOES incorrectly stomp to gascity. Proves (Y1) would have caught this
# live near-miss, not just happened to pass either way.
R=$(apply_ljbx_pin "fix/wa-xd0zg-rebase" \
  "$GC_CITY_PATH_STUB/.gc-worktrees/ga-xd0zg-rebase" "whatsapp_automation" "$GC_CITY_PATH_STUB")
[ "$R" = "gascity" ] \
  && ok "(Y5) mutation check: pre-fix pin stomps the (Y1) repro to gascity, reproducing ga-5nshv" \
  || bad "(Y5) mutation check: pre-fix pin unexpectedly did not stomp — (Y1) would not catch a reversion"

# (Y6) source drift-guard: deployed gate-done.md's ga-ljbx pin block checks
# the worktree's own git origin before pinning to gascity.
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  printf '%s' "$src" | grep -qF 'ga-5nshv' \
    && ok "(Y6a) gate-done.md references the ga-5nshv fix" \
    || bad "(Y6a) gate-done.md missing the ga-5nshv fix marker (regression)"
  printf '%s' "$src" | grep -qF 'git -C "$CWD_TOP" remote get-url origin' \
    && ok "(Y6b) gate-done.md's ga-ljbx pin checks the worktree's own git origin before pinning" \
    || bad "(Y6b) gate-done.md missing the origin-URL check (ga-5nshv regression)"
  printf '%s' "$src" | grep -qF '_ORIGIN_MATCH_COUNT" -eq 1' \
    && ok "(Y6c) gate-done.md only trusts an UNAMBIGUOUS (single) origin match, never a guess among several" \
    || bad "(Y6c) gate-done.md missing the single-match-only guard (would misresolve the gascity/gastown/deacon collision)"
  # The origin check must run BEFORE the unconditional pin, not after — an
  # after-the-fact check can't prevent the stomp it's meant to prevent.
  origin_check_line=$(printf '%s\n' "$src" | grep -nF '_CWD_ORIGIN_URL=$(git -C "$CWD_TOP"' | head -1 | cut -d: -f1)
  pin_line=$(printf '%s\n' "$src" | grep -nE 'echo "Note: framework self-fix branch' | head -1 | cut -d: -f1)
  if [ -n "$origin_check_line" ] && [ -n "$pin_line" ] && [ "$origin_check_line" -lt "$pin_line" ]; then
    ok "(Y6d) gate-done.md's origin check runs BEFORE the unconditional gascity pin (line $origin_check_line < $pin_line)"
  else
    bad "(Y6d) gate-done.md's origin check does not precede the pin (origin_check_line='$origin_check_line' pin_line='$pin_line')"
  fi
else
  bad "(Y6) gate-done.md not found at $GATE_DONE"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
