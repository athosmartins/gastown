#!/usr/bin/env bash
# prod-tests/gascity/story-ga-1xnfx.sh — prod test for ga-1xnfx: doctrine
# telling a crew that creates a bead for work it is ALREADY building to set
# the assignee in the same act (bead without an owner is, by definition,
# available for dispatch — the gap that let the Pilot double-dispatch
# wa-vktvx on 2026-09-05, ~25min of duplicated worker time).
#
# The deliverable is a doctrine paragraph in the git-tracked template
# fragment that gets rendered into every agent's context (Dog Context,
# crew context, etc.) via gc prime — NOT a change to /Users/athos/gt/CLAUDE.md,
# which is clone-local and gitignored (see .gitignore:74) and does not carry
# this section at all. Verifies the paragraph exists, both example commands
# are present, the "why" is stated (so the rule can't decay into a decorative
# one nobody applies), and the template's own define/end wrapper is intact.
#
# Called by run.sh after deploy (STORY_ID=ga-1xnfx). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
FRAGMENT="$CITY/packs/town-deltas/template-fragments/town-deltas.template.md"

log()  { echo "[prod-test:gascity ga-1xnfx] $*"; }
fail() { echo "[prod-test:gascity ga-1xnfx] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed source exists ─────────────────────────────────────────────────
[[ -f "$FRAGMENT" ]] || fail "template fragment missing: $FRAGMENT"
log "template fragment present ✓"

# ── 2. Template wrapper still intact (a bad edit could have broken this) ──────
head -1 "$FRAGMENT" | grep -q '{{ define "town-deltas" }}' \
    || fail "template define wrapper missing/moved from line 1"
tail -1 "$FRAGMENT" | grep -q '{{ end }}' \
    || fail "template end wrapper missing/moved from last line"
log "define/end wrapper intact ✓"

# Prose reflows across lines, so phrase-level checks below normalize the file
# to one whitespace-collapsed line first rather than depending on where a
# hand-wrapped markdown line break happens to fall.
NORMALIZED="$(tr '\n' ' ' < "$FRAGMENT" | tr -s '[:space:]' ' ')"
phrase_present() { printf '%s' "$NORMALIZED" | grep -qF "$1"; }

# ── 3. The doctrine paragraph itself landed ───────────────────────────────────
grep -q "ga-1xnfx" "$FRAGMENT" \
    || fail "no ga-1xnfx doctrine entry found in the deployed fragment"
log "ga-1xnfx entry present ✓"

phrase_present "bead sem dono É, por definição, disponível pra despacho" \
    || fail "core rule statement missing"
log "core rule statement present ✓"

# ── 4. Both required examples are present, each with its concrete command ────
phrase_present "Vai construir AGORA" \
    || fail "'vou construir agora' example missing"
phrase_present "bd update <id> --assignee <você>" \
    || fail "assignee-on-creation command example missing"
log "'building now -> set assignee' example present ✓"

phrase_present "Está arquivando pra pool" \
    || fail "'arquivando pra pool' example missing"
phrase_present "cria SEM assignee, DE PROPÓSITO" \
    || fail "'pool archiving -> no assignee, deliberately' example missing"
log "'archiving for pool -> no assignee' example present ✓"

# ── 5. The reason is stated, not just the rule (otherwise it decays unused) ───
phrase_present "bead sem dono = disponível pra despacho" \
    || fail "the 'why' (bead without owner = available for dispatch) is missing"
log "reasoning present ✓"

# ── 6. Scope guard: doctrine explicitly says NOT to change bd create ─────────
phrase_present "isto NÃO muda \`bd create\`" \
    || fail "bd-create-out-of-scope guard missing"
log "bd create out-of-scope guard present ✓"

log "PASS — crew-assignee-on-creation doctrine deployed with both examples and rationale"
exit 0
