#!/usr/bin/env bash
# prod-tests/gascity/story-ga-vhzdh5.3.sh — prod test for ga-vhzdh5.3: the
# "## Contents" backfill of the HQ repo docs (epic ga-vhzdh5, rule from Athos 11/10:
# every .md > 300 chars starts with a "## Contents" section).
#
# "Mergeado != vivo": this runs the DEPLOYED lint (city scripts/doc-rules-lint.py)
# over every .md TRACKED in the LIVE repo checkout after the deploy pull, so a
# backfill that merged but never reached the live tree (stale ff-pull) fails here.
# The result must be real: the lint runs against a scratch city (its own .gc/, no
# DOC_RULES_LINT) so the operator kill switch -- which turns --check into an exit-0
# no-op -- cannot make this pass vacuously, and a negative control proves the same
# invocation does reject a doc without Contents.
#
# Hard assertion: the git-tracked docs of the HQ repo (deterministic: they change
# only through the gate). REPORTED only, never failed: ~/.claude/*.md, the
# auto-memory dir and the property_scrapers checkout -- agents write new memory
# notes all day, so asserting on them would fail every deploy that follows one.
#
# Scratch only: no network, no bd/gc call, nothing under the live .gc/ is written.
# Env overrides (for dry runs): CITY, REPO, CLAUDE_HOME, PS_REPO.
# Called by run.sh after deploy (STORY_ID=ga-vhzdh5.3). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
REPO="${REPO:-/Users/athos/gt}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
PS_REPO="${PS_REPO:-/Users/athos/gt/property_scrapers/refinery/rig}"
LINT="$CITY/scripts/doc-rules-lint.py"
MIN_CHECKED=50   # 100 .md are in scope today; fewer means the listing/scope broke, not that docs vanished

log()  { echo "[prod-test:gascity ga-vhzdh5.3] $*"; }
fail() { echo "[prod-test:gascity ga-vhzdh5.3] FAIL: $*" >&2; exit 1; }

# ── 1. Structural: the deployed lint exists and compiles ───────────────────
[[ -f "$LINT" ]] || fail "deployed doc-rules-lint.py missing: $LINT"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
command -v git >/dev/null 2>&1 || fail "git not on PATH"
[[ -d "$REPO/.git" || -f "$REPO/.git" ]] || fail "live repo checkout not found: $REPO"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/prod-contents-backfill.XXXXXX")" || fail "cannot create scratch dir"
trap 'rm -rf "$SBX"' EXIT
python3 -I -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$LINT" "$SBX/lint.pyc" \
  || fail "deployed doc-rules-lint.py does not compile"
log "deployed lint compiles ✓"

# Scratch city: the deployed script via symlink, but its OWN .gc/ so the live kill-switch flag file cannot leak in.
SC="$SBX/city"; mkdir -p "$SC/scripts" "$SC/.gc"
ln -s "$LINT" "$SC/scripts/doc-rules-lint.py"
export GC_CITY_PATH="$SC"
unset DOC_RULES_LINT DOC_RULES_UPSTREAM_REF
lint() { python3 -I "$LINT" "$@"; }
if [[ -e "$CITY/.gc/doc-rules-lint.off" ]]; then
  log "note: live kill switch is ON ($CITY/.gc/doc-rules-lint.off) -- ignored here on purpose; this test lints for real"
fi

# ── 2. Negative control: the same invocation rejects a doc without Contents ─
LONG="$(printf '%*s' 320 '' | tr ' ' 'x')"
F="$SBX/fx"; mkdir -p "$F"
printf '# Doc\n\n## Alpha\n\n%s\n' "$LONG" > "$F/bad.md"
printf '# Doc\n\n## Contents\n\n• Alpha\n\n## Alpha\n\n%s\n' "$LONG" > "$F/good.md"
OUT="$(lint --check --root "$F" --upstream-ref none bad.md 2>&1)"; RC=$?
[[ "$RC" -eq 1 ]] && grep -q 'contents-missing' <<< "$OUT" || fail "negative control: a doc without Contents was not rejected (rc=$RC): $OUT"
lint --check --root "$F" --upstream-ref none good.md >/dev/null 2>&1 || fail "negative control: a doc with Contents was rejected"
log "negative control: no-Contents rejected, with-Contents accepted ✓"

# ── 3. The assertion: every tracked .md of the live HQ repo passes ─────────
# vazio (git lista 0 arquivos) → fail; falhou (git erra) → fail: nunca um pass sem ter lido a lista
LIST="$SBX/tracked-md.z"
git -C "$REPO" ls-files -z -- '*.md' > "$LIST" 2>"$SBX/git.err" || fail "git ls-files failed in $REPO: $(head -c 300 "$SBX/git.err")"
[[ -s "$LIST" ]] || fail "git ls-files returned no .md files in $REPO -- cannot evaluate (empty is not pass)"
FILES=()
while IFS= read -r -d '' f; do FILES+=("$f"); done < "$LIST"
log "live repo $REPO: ${#FILES[@]} tracked .md files to evaluate"

# vazio (nenhuma violação) → exit 0; falhou/não avaliou → exit 2 (também fail): desconhecido não é pass
OUT="$(lint --check --root "$REPO" "${FILES[@]}" 2>&1)"; RC=$?
SUMMARY="$(grep -E '^doc-rules-lint: [0-9]+ file\(s\) checked' <<< "$OUT" | tail -1)"
if [[ "$RC" -ne 0 ]]; then
  echo "$OUT" | head -25 >&2
  fail "doc-rules-lint --check on the live HQ repo exited $RC (1 = docs without Contents / CLAUDE.md > 200 lines, 2 = could not evaluate): ${SUMMARY:-no summary line}"
fi
[[ -n "$SUMMARY" ]] || fail "lint exited 0 but printed no summary line -- cannot tell what it checked: $(head -c 300 <<< "$OUT")"
CHECKED="$(sed -E 's/^doc-rules-lint: ([0-9]+) file.*/\1/' <<< "$SUMMARY")"
[[ "$CHECKED" =~ ^[0-9]+$ && "$CHECKED" -ge "$MIN_CHECKED" ]] \
  || fail "lint checked only '${CHECKED}' file(s) (< $MIN_CHECKED): scope/listing broke, a green here would be vacuous: $SUMMARY"
log "live HQ repo: $SUMMARY ✓"

# ── 4. Reported only: the areas outside the deploy (never fail on these) ───
report_area() {  # <label> <root> <upstream-ref> <file...>
  local label="$1" root="$2" up="$3"; shift 3
  if [[ "$#" -eq 0 ]]; then log "[info] $label: no .md found under $root -- not evaluated"; return 0; fi
  local o r
  o="$(lint --check --root "$root" --upstream-ref "$up" "$@" 2>&1)"; r=$?
  log "[info] $label: $(grep -E '^doc-rules-lint: ' <<< "$o" | tail -1 || true) (exit $r)"
}
if [[ -d "$CLAUDE_HOME" ]]; then
  ( cd "$CLAUDE_HOME" && shopt -s nullglob && report_area "~/.claude/*.md" "$CLAUDE_HOME" none *.md )
  MEMDIR="$CLAUDE_HOME/projects/-Users-athos-gt/memory"
  [[ -d "$MEMDIR" ]] && ( cd "$MEMDIR" && shopt -s nullglob && report_area "auto-memory" "$MEMDIR" none *.md )
else
  log "[info] $CLAUDE_HOME not present here -- ~/.claude and memory not evaluated"
fi
if [[ -d "$PS_REPO" ]]; then
  PSFILES=()
  while IFS= read -r -d '' f; do PSFILES+=("$f"); done < <(git -C "$PS_REPO" ls-files -z -- '*.md' 2>/dev/null)
  report_area "property_scrapers (refinery checkout)" "$PS_REPO" none ${PSFILES[@]+"${PSFILES[@]}"}
else
  log "[info] $PS_REPO not present here -- property_scrapers not evaluated"
fi

log "PASS"
exit 0
