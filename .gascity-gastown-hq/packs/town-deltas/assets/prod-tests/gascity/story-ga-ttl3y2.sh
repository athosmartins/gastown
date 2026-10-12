#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ttl3y2.sh — prod test for ga-ttl3y2: the `rea-scraper-first` skill (programa REA, epic ga-oe7o1p)
# and its entry in the pool-worker skill lists.
#
# Verifies the DEPLOYED files (the city root IS the git working tree, so merged == on disk), not a copy of the claims:
#   0. the skill file and the files that list it exist;
#   1. the skill's frontmatter and the safety rules a worker must not lose (never the logged-in Chrome 9222/9223, never `rea setup`,
#      the machine pre-flight, the Athos hand-off fields) are still in the text, and the doc-rules lint passes on it;
#   2. every `rea <command>` the skill names exists in the installed `rea` (a rea upgrade that renames one is drift, not a pass);
#   3. the committed overlays: wa-worker/ps-worker LIST the skill, dog/reviewer have it `off` — read from the files, not regenerated;
#   4. the preamble builder's own `check` passes on the live tree;
#   5. `gc` itself sees the skill as a city skill.
# NOT asserted here (it cannot be forced from a test): the per-worker `.claude/skills/rea-scraper-first` symlink, which the materializer
# creates when a worker next starts — step 6 only REPORTS whether it is there yet.
#
# Called by run.sh after deploy (STORY_ID=ga-ttl3y2). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
SKILL="$CITY/skills/rea-scraper-first/SKILL.md"
ROLES="$ASSETS/claude-overlays/pool-roles.json"
BUILDER="$ASSETS/pool-preamble-build.py"
LINT="$CITY/scripts/doc-rules-lint.py"
OVERLAYS="$ASSETS/claude-overlays"

log()  { echo "[prod-test:gascity ga-ttl3y2] $*"; }
fail() { echo "[prod-test:gascity ga-ttl3y2] FAIL: $*" >&2; exit 1; }

# ── 0. everything the story ships is on disk ───────────────────────────────────────────────────────────────
for f in "$SKILL" "$ROLES" "$BUILDER" "$LINT" "$OVERLAYS/pool-dog/.claude/settings.json" "$OVERLAYS/pool-reviewer/.claude/settings.json" \
         "$OVERLAYS/pool-wa-worker/.claude/settings.json" "$OVERLAYS/pool-ps-worker/.claude/settings.json"; do
  [[ -f "$f" ]] || fail "missing: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
log "Skill file, manifest, builder and the four overlays found."

# ── 1. frontmatter, the rules that must survive edits, and the doc-rules lint ──────────────────────────────
python3 -I - "$SKILL" <<'EOF' || fail "SKILL.md frontmatter is not name=rea-scraper-first + a 'Use when' description"
import re, sys
txt = open(sys.argv[1], encoding="utf-8").read()
m = re.match(r"---\nname: (\S+)\ndescription: (.+)\n---\n", txt)
sys.exit(0 if m and m.group(1) == "rea-scraper-first" and m.group(2).startswith("Use when") else 1)
EOF
need() { grep -qF -- "$1" "$SKILL" || fail "the skill lost a rule it must carry: $2 (looked for '$1')"; }
need '9222'               "never attach to the logged-in Chrome (9222/9223)"
need '9223'               "never attach to the logged-in Chrome (9222/9223)"
need 'rea setup'          "do NOT run rea setup (it would register the MCP server)"
need '10 GB'              "machine pre-flight (disk)"
need 'athos.acao'         "hand-off to Athos when only a protected path exists"
need 'next-action:athos'  "hand-off to Athos when only a protected path exists"
need 'safe-clean'         "cleanup without rm -rf"
need 'REA:'               "the REA: line the bead must carry"
python3 -I "$LINT" --check --root "$CITY" skills/rea-scraper-first/SKILL.md >/dev/null 2>&1 \
  || fail "doc-rules-lint rejects skills/rea-scraper-first/SKILL.md (run: python3 scripts/doc-rules-lint.py --check --root . skills/rea-scraper-first/SKILL.md)"
log "  frontmatter, safety rules and doc-rules lint OK ✓"

# ── 2. every `rea <command>` the skill names exists in the installed rea ───────────────────────────────────
# vazio → 'rea' não achado: NOTE "UNVERIFIED" dito em voz alta (nunca vira "comandos conferidos"); falhou/ilegível (--help) → FAIL
REA_BIN="$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v rea 2>/dev/null || true)"
if [[ -z "$REA_BIN" ]]; then
  # a third state, said out loud: not a pass, and not worth blocking a skill delivery on a launchd PATH that lacks homebrew
  log "  NOTE: UNVERIFIED — 'rea' is not on PATH here, so the commands named in the skill were NOT checked against the installed CLI"
else
  HELP="$("$REA_BIN" --help 2>/dev/null)" || fail "'$REA_BIN --help' failed — cannot check the commands named in the skill"
  [[ -n "$HELP" ]] || fail "'$REA_BIN --help' printed nothing — cannot check the commands named in the skill"
  # vazio → a skill não nomeia comando nenhum: FAIL (um grep que não achou nada não pode virar "todos existem"); falhou/ilegível → idem
  CMDS="$(grep -oE 'rea [a-z]+(-[a-z]+)+' "$SKILL" | awk '{print $2}' | sort -u)"
  [[ -n "$CMDS" ]] || fail "the skill names no 'rea <command>' at all"
  for c in $CMDS; do
    printf '%s\n' "$HELP" | grep -qE "^  $c( |$)" || fail "the skill names 'rea $c' but the installed rea has no such command (rea upgrade drift?)"
  done
  log "  every named rea command exists in $REA_BIN: $(echo $CMDS | tr '\n' ' ')✓"
fi

# ── 3. the committed overlays: workers LIST the skill, dog/reviewer have it off ────────────────────────────
# vazio → sem a chave skillOverrides num overlay de WORKER = "sem override" = a skill é listada (correto); o mesmo no dog/revisor = erro (deveria ser off)
# falhou/ilegível (arquivo ou JSON) → conta como erro daquele overlay, nunca como "sem override"
python3 -I - "$OVERLAYS" <<'EOF' || fail "overlay skill visibility is wrong (workers must list rea-scraper-first; dog and reviewer must have it off)"
import json, os, sys
ov = sys.argv[1]
bad = []
for overlay, want in (("pool-wa-worker", None), ("pool-ps-worker", None), ("pool-dog", "off"), ("pool-reviewer", "off")):
    p = os.path.join(ov, overlay, ".claude", "settings.json")
    try:
        got = json.load(open(p, encoding="utf-8")).get("skillOverrides", {}).get("rea-scraper-first")
    except Exception as e:
        bad.append(f"{overlay}: unreadable ({e!r})"); continue
    if got != want: bad.append(f"{overlay}: skillOverrides['rea-scraper-first']={got!r}, want {want!r}")
print("\n".join(bad), file=sys.stderr)
sys.exit(1 if bad else 0)
EOF
log "  workers list the skill; dog and reviewer have it off ✓"

# ── 4. the preamble builder's own check, on the live tree ──────────────────────────────────────────────────
CHK="$(python3 -I "$BUILDER" check 2>&1)" || fail "pool-preamble-build.py check failed on the live tree: $(printf '%s' "$CHK" | tail -3)"
log "  preamble builder check OK ✓"

# ── 5. gc sees it as a city skill ──────────────────────────────────────────────────────────────────────────
# vazio → a lista veio sem a skill: FAIL; falhou/ilegível/timeout → FAIL (não dá para afirmar que o gc enxerga a skill)
LIST="$(timeout 90 gc --city "$CITY" skill list 2>/dev/null)" || fail "gc skill list failed or timed out"
printf '%s\n' "$LIST" | grep -qE '^rea-scraper-first[[:space:]]+city[[:space:]]' || fail "gc skill list does not show rea-scraper-first as a city skill"
log "  gc sees rea-scraper-first as a city skill ✓"

# ── 6. REPORT (not assert): has a worker workdir been given the symlink yet? ───────────────────────────────
# Every city skill is symlinked into every workdir (the overlays only hide it from the listing), so a hit on ANY role's workdir says the
# materializer has run for this skill — it does NOT say a worker lists it; that needs a fresh wa-worker/ps-worker session.
if compgen -G "$CITY/.gc/agents/*/*/.claude/skills/rea-scraper-first" >/dev/null 2>&1; then
  log "  NOTE: the materializer has already linked rea-scraper-first into at least one agent workdir (any role)"
else
  log "  NOTE: UNVERIFIED — no agent workdir under .gc/agents has the .claude/skills/rea-scraper-first symlink yet; the materializer creates it when a session next starts. Check a fresh wa-worker/ps-worker session lists the skill"
fi

log "PASS"
exit 0
