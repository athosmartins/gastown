#!/usr/bin/env bash
# pool-prompt-skill-mention.selftest.sh — ga-7nxfa1: a pool worker's boot prompt must not contain a
# slash token that names a real skill.
#
# WHY. Claude Code reads a "/<skill>" token in the first user message as a skill mention and attaches
# {"type":"skill_mention","skillName":"<skill>"} to the boot. The fresh wa-worker then runs that skill with
# no bead, finds nothing to do, and idles on a pool slot (2 slots, 1 held for 30 min => 72 approved beads,
# 0 in flight). MEASURED 03/10 on Claude Code 2.1.288 in an INTERACTIVE session (the path the city boots
# through; `claude -p` does not reproduce it):
#     " → /gate-done → "        mention      /gate-done alone on a line   mention
#     `/gate-done` (backticks)   none         bare "gate-done"            none
#     "the gate-done skill"      none         "a skill gate-done"         none
# and it only fires when the skill is resolvable in that session (ps-worker's listing has no gate-done,
# so the same text did nothing there — today).
#
# THREE parts, because a detector that was never shown to catch anything proves nothing:
#   A. CONTROLS on synthetic text: the detector flags every shape that mentions a skill and spares paths,
#      URLs and the replacement wording. If A fails, B's "no hits" would be vacuous.
#   B. NAMES: the set of skill/command names is derived from this repo, never hard-coded alone, and an
#      empty set is FATAL (no names => nothing could be flagged => a silent pass).
#   C. TEMPLATES: every agents/*/prompt.template.md has no UNQUOTED skill token (the measured trigger);
#      the unattended POOL templates are held to the stricter rule — no token at all, backticks included —
#      so they do not depend on an undocumented parser detail of one Claude Code version.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${POOL_PROMPT_REPO_ROOT:-$SELF_DIR/../../../..}"
AGENTS_DIR="${POOL_PROMPT_AGENTS_DIR:-$SELF_DIR/../../../agents}"
# Unattended pool agents: nobody is at the keyboard to notice a misfire, and each one holds a slot.
POOL_TEMPLATES="${POOL_PROMPT_POOL_TEMPLATES:-wa-worker ps-worker gemini-worker}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -d "$AGENTS_DIR" ] || { echo "FATAL: agents dir not found at $AGENTS_DIR"; exit 1; }

# ---- B. names ---------------------------------------------------------------------------------------
echo "B. skill/command names derived from the repo"
NAMES_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-prompt-names.XXXXXX")"
trap 'rm -f "$NAMES_FILE" "${FIX:-}"' EXIT
{
  echo gate-done   # the incident's skill: stays flagged even if its source file moves
  for d in "$ROOT/.claude/commands" "$ROOT/.gascity-gastown-hq/commands"; do
    [ -d "$d" ] && for f in "$d"/*.md; do [ -f "$f" ] && basename "$f" .md; done
  done
  [ -d "$ROOT/.claude/skills" ] && for s in "$ROOT/.claude/skills"/*/; do [ -f "${s}SKILL.md" ] && basename "$s"; done
} 2>/dev/null | grep -E '^[A-Za-z][A-Za-z0-9._-]*$' | sort -u > "$NAMES_FILE"
NNAMES="$(wc -l < "$NAMES_FILE" | tr -d ' ')"
if [ "$NNAMES" -ge 1 ] && grep -qx 'gate-done' "$NAMES_FILE"; then ok "derived $NNAMES name(s), gate-done among them"
else bad "name set is empty or lacks gate-done (n=$NNAMES): detector would be vacuous"; fi
ALT="$(sed 's/\./\\./g' "$NAMES_FILE" | paste -sd'|' -)"

# Token = "/<name>" not glued to a path/word on the left, and not continued into a path/extension on the
# right. STRICT also flags the backtick-quoted form; TRIGGER (the measured one) does not.
PRE_STRICT='(^|[^[:alnum:]_/.~-])'
PRE_TRIGGER='(^|[^[:alnum:]_/.~`-])'
POST='([^[:alnum:]_/.-]|\.([^[:alnum:]]|$)|$)'
hits() { # hits <strict|trigger> <file>  -> matching lines, "N:text"
  local pre="$PRE_TRIGGER"; [ "$1" = strict ] && pre="$PRE_STRICT"
  grep -nE "${pre}/(${ALT})${POST}" "$2" 2>/dev/null
}

# ---- A. controls ------------------------------------------------------------------------------------
echo "A. detector controls (synthetic text)"
FIX="$(mktemp "${TMPDIR:-/tmp}/pool-prompt-fixture.XXXXXX")"
expect() { # expect <strict|trigger> <flag|clear> <text> <label>
  printf '%s\n' "$3" > "$FIX"
  local n; n="$(hits "$1" "$FIX" | wc -l | tr -d ' ')"
  if [ "$2" = flag ]; then [ "$n" -ge 1 ] && ok "$1 flags: $4" || bad "$1 MISSED: $4  [$3]"
  else [ "$n" -eq 0 ] && ok "$1 spares: $4" || bad "$1 FALSE POSITIVE: $4  [$3]"; fi
}
expect trigger flag  'lifecycle: commit → /gate-done → exit.'                 'inline, space-preceded (the incident line)'
expect trigger flag  '/gate-done'                                              'alone on its own line'
expect trigger flag  '**Após /gate-done:**'                                    'followed by a colon'
expect trigger flag  'then run /gate-done.'                                    'followed by a full stop'
expect trigger clear 'use `/gate-done` to submit'                              'backticked (measured non-trigger)'
expect strict  flag  'use `/gate-done` to submit'                              'backticked, pool rule'
expect strict  flag  '2. Rodar `/gate-done` → cria o marker'                   'backticked, Portuguese step'
expect strict  clear 'commit → the gate-done skill → exit.'                    'replacement wording'
expect strict  clear 'use a skill `gate-done` (NUNCA `gt mq submit`)'          'replacement wording, backticked name'
expect strict  clear 'see .claude/commands/gate-done.md for details'           'path ending in the skill file'
expect strict  clear 'branch crew/wa-worker/gate-done-fix'                     'branch name containing the name'
expect strict  clear 'https://example.com/docs/gate-done'                      'URL'
expect strict  clear 'the gate-done-marker file'                               'longer hyphenated word'
expect strict  clear '/gate-done/x is a directory'                             'path continuing after the name'

# ---- C. templates -----------------------------------------------------------------------------------
echo "C. agents/*/prompt.template.md"
SCANNED=0
for f in "$AGENTS_DIR"/*/prompt.template.md; do
  [ -f "$f" ] || continue
  SCANNED=$((SCANNED+1)); agent="$(basename "$(dirname "$f")")"
  mode=trigger; case " $POOL_TEMPLATES " in *" $agent "*) mode=strict ;; esac
  h="$(hits "$mode" "$f")"
  if [ -z "$h" ]; then ok "$agent: no skill token ($mode)"
  else bad "$agent: skill token present ($mode) — Claude Code will attach a skill_mention at boot:"; echo "$h" | sed 's/^/      /' | cut -c1-170; fi
done
[ "$SCANNED" -ge 1 ] && ok "scanned $SCANNED template(s)" || bad "scanned 0 templates under $AGENTS_DIR: nothing was checked"
for p in $POOL_TEMPLATES; do
  [ -f "$AGENTS_DIR/$p/prompt.template.md" ] || bad "pool template listed but missing: $p (a renamed pool would silently escape the strict rule)"
done

echo
echo "pool-prompt-skill-mention selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
