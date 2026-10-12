#!/usr/bin/env bash
# prod-tests/gascity/story-ga-vhzdh5.1.sh — prod test for ga-vhzdh5.1: doc-rules
# lint (CLAUDE.md/AGENTS.md <= 200 lines incl. @imports; "## Contents" in every
# .md > 300 chars) wired into the quality gate's run-tests step (2c).
#
# "Mergeado != vivo": this checks the pieces in the LIVE city tree, not the
# worktree that produced them -- the deployed script parses and enforces both
# rules on scratch fixtures, and the deployed formula's step-2c snippet, run
# against a scratch git worktree, fails a branch that changes a bad .md and
# passes one that changes a good .md. Scratch only: no network, no bd/gc call,
# nothing under the live .gc/ is written. The live kill switch is REPORTED
# (a flag file or DOC_RULES_LINT=off means the gate step is a no-op in prod).
#
# Called by run.sh after deploy (STORY_ID=ga-vhzdh5.1). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
LINT="$CITY/scripts/doc-rules-lint.py"
FORMULA="$CITY/formulas/mol-quality-gate-runner.toml"

log()  { echo "[prod-test:gascity ga-vhzdh5.1] $*"; }
fail() { echo "[prod-test:gascity ga-vhzdh5.1] FAIL: $*" >&2; exit 1; }

# ── 1. Structural: the deployed pieces exist and parse ─────────────────────
[[ -f "$LINT" ]] || fail "deployed doc-rules-lint.py missing: $LINT"
[[ -f "$FORMULA" ]] || fail "deployed quality-gate runner formula missing: $FORMULA"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH -- the gate step runs 'python3 doc-rules-lint.py'"
SBX="$(mktemp -d "${TMPDIR:-/tmp}/prod-doc-rules-lint.XXXXXX")" || fail "cannot create scratch dir"
trap 'rm -rf "$SBX"' EXIT
python3 -I -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "$LINT" "$SBX/lint.pyc" \
  || fail "deployed doc-rules-lint.py does not compile"
grep -q 'SELFTEST-EXTRACT doc-rules-lint-step2c: BEGIN' "$FORMULA" \
  || fail "step 2c (doc-rules lint) missing from the deployed mol-quality-gate-runner.toml -- gate wiring not deployed"
log "deployed script compiles; step 2c present in the deployed runner formula ✓"

# ── 2. Live kill-switch state (reported, not failed: it is an operator choice)
if [[ -e "$CITY/.gc/doc-rules-lint.off" ]]; then
  log "WARNING: live kill switch is ON ($CITY/.gc/doc-rules-lint.off) -- the gate step is a no-op in prod until it is removed"
else
  log "live kill switch: off-flag file absent -> the lint is ENFORCING in prod ✓"
fi
[[ "${DOC_RULES_LINT:-}" == "off" ]] && log "WARNING: DOC_RULES_LINT=off is set in THIS environment"

# Scratch city: the deployed script via symlink, but its OWN .gc/ so the live flag file cannot leak into the fixtures.
SC="$SBX/city"; mkdir -p "$SC/scripts" "$SC/.gc"
ln -s "$LINT" "$SC/scripts/doc-rules-lint.py"
export GC_CITY_PATH="$SC"
unset DOC_RULES_LINT DOC_RULES_UPSTREAM_REF
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=prod GIT_AUTHOR_EMAIL=prod@test GIT_COMMITTER_NAME=prod GIT_COMMITTER_EMAIL=prod@test

LONG="$(printf '%*s' 320 '' | tr ' ' 'x')"
good_doc() { printf '# Doc\n\n## Contents\n\n• Alpha · Beta\n\n## Alpha\n\n%s\n\n## Beta\n\ntext\n' "$LONG"; }
bad_doc()  { printf '# Doc\n\n## Alpha\n\n%s\n\n## Beta\n\ntext\n' "$LONG"; }

# ── 3. Behavioral, deployed script on scratch fixtures ──────────────────────
F="$SBX/fx"; mkdir -p "$F"
good_doc > "$F/good.md"; bad_doc > "$F/bad.md"
python3 "$LINT" --check --root "$F" good.md >/dev/null 2>&1 || fail "good doc (Contents present) was rejected by the deployed lint"
OUT="$(python3 "$LINT" --check --root "$F" bad.md 2>&1)"; RC=$?
[[ "$RC" -eq 1 ]] && grep -q 'contents-missing' <<< "$OUT" || fail "bad doc (no Contents) not rejected with exit 1 / contents-missing (rc=$RC): $OUT"
{ printf '# T\n\n## Contents\n\n• A\n\n## A\n\n'; i=8; while [[ $i -lt 201 ]]; do echo "l$i"; i=$((i+1)); done; } > "$F/CLAUDE.md"
OUT="$(python3 "$LINT" --check --root "$F" CLAUDE.md 2>&1)"; RC=$?
[[ "$RC" -eq 1 ]] && grep -q 'claude-md-max-lines' <<< "$OUT" || fail "201-line CLAUDE.md not rejected (rc=$RC): $OUT"
OUT="$(DOC_RULES_LINT=off python3 "$LINT" --check --root "$F" bad.md 2>&1)"; RC=$?
[[ "$RC" -eq 0 ]] && grep -q 'DISABLED' <<< "$OUT" || fail "negative control: DOC_RULES_LINT=off did not turn the lint into a loud no-op (rc=$RC): $OUT"
cp "$F/bad.md" "$F/fixme.md"
python3 "$LINT" --fix-contents --root "$F" fixme.md >/dev/null 2>&1 && python3 "$LINT" --check --root "$F" fixme.md >/dev/null 2>&1 \
  || fail "--fix-contents did not turn a bad doc into a passing one"
log "deployed script: good accepted, no-Contents rejected, 201-line CLAUDE.md rejected, off-switch no-op, --fix-contents repairs ✓"

# ── 4. The deployed formula's step 2c, run against a scratch worktree ──────
# vazio (markers sem corpo) → fail abaixo; falhou (formula ilegível) → awk dá vazio = o mesmo fail, nunca um pass
SNIP="$(awk '/SELFTEST-EXTRACT doc-rules-lint-step2c: BEGIN/{f=1;next} /SELFTEST-EXTRACT doc-rules-lint-step2c: END/{f=0} f' "$FORMULA")"
[[ -n "$SNIP" ]] || fail "step 2c markers present but the snippet body is empty"
{ printf 'TEST_EXIT=0\nTEST_OUTPUT=""\n%s\n' "$SNIP"; printf 'echo "__TEST_EXIT=$TEST_EXIT"\n'; } > "$SBX/step2c.sh"
WT="$SBX/wt"; mkdir -p "$WT"
git -C "$WT" init -q && git -C "$WT" symbolic-ref HEAD refs/heads/main
bad_doc > "$WT/legacy-bad.md"; printf 'x\n' > "$WT/a.txt"
git -C "$WT" add -A >/dev/null 2>&1 && git -C "$WT" commit -qm base
git -C "$WT" update-ref refs/remotes/origin/main HEAD
git -C "$WT" checkout -q -b feat-bad; bad_doc > "$WT/new-bad.md"; git -C "$WT" add -A >/dev/null 2>&1; git -C "$WT" commit -qm "bad doc"
OUT="$(WORKTREE_PATH="$WT" bash "$SBX/step2c.sh" 2>&1)"
# vazio (o snippet morreu antes de imprimir __TEST_EXIT) → TE vazio: os dois checks ("deve falhar" e "deve ser 0") tratam vazio como FAIL; falhou → idem
TE="$(sed -n 's/^__TEST_EXIT=//p' <<< "$OUT" | tail -1)"
[[ -n "$TE" && "$TE" != 0 ]] || fail "step 2c did not fail a branch that changes a bad .md (TEST_EXIT=${TE:-unset}): $OUT"
grep -q 'new-bad.md' <<< "$OUT" || fail "step 2c failed but did not name the offending file: $OUT"
grep -q 'legacy-bad.md' <<< "$OUT" && fail "step 2c flagged an UNTOUCHED legacy doc (backfill is another slice): $OUT"
git -C "$WT" checkout -q -b feat-good refs/remotes/origin/main; good_doc > "$WT/new-good.md"; git -C "$WT" add -A >/dev/null 2>&1; git -C "$WT" commit -qm "good doc"
OUT="$(WORKTREE_PATH="$WT" bash "$SBX/step2c.sh" 2>&1)"
TE="$(sed -n 's/^__TEST_EXIT=//p' <<< "$OUT" | tail -1)"
[[ "$TE" == 0 ]] || fail "step 2c failed a branch that changes only a compliant .md (TEST_EXIT=${TE:-unset}): $OUT"
log "deployed step 2c: changed bad .md -> gate fails (names the file, ignores untouched legacy doc); changed good .md -> passes ✓"

log "PASS"
exit 0
