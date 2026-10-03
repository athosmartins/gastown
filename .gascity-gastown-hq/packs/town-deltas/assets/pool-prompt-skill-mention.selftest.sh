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
#   B. NAMES: the set of skill/command names is derived from this repo (.claude/commands, .claude/skills,
#      the city's own skills/ and commands/), plus a short list of names that live OUTSIDE the repo (gate-done,
#      the core gc-* skills). The derived part is checked on its own — a hard-coded name can never make the
#      "names found" check pass — and an empty derived set, or a missing city skills/ dir, is FATAL (no names
#      => nothing could be flagged => a silent pass).
#   C. TEMPLATES: every agents/*/prompt.template.md has no UNQUOTED skill token (the measured trigger);
#      the unattended POOL templates are held to the stricter rule — no token at all, backticks included —
#      so they do not depend on an undocumented parser detail of one Claude Code version. The city.toml
#      global_fragments are appended to EVERY boot prompt, pool workers' included, so the ones that live in
#      this repo are scanned under the strict rule too; the ones that ship inside the gc binary cannot be
#      read from here and are reported as NOT SCANNED, out loud.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${POOL_PROMPT_REPO_ROOT:-$SELF_DIR/../../../..}"
CITY_DIR="${POOL_PROMPT_CITY_DIR:-$ROOT/.gascity-gastown-hq}"
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
DERIVED_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-prompt-derived.XXXXXX")"
CITYSK_FILE="$(mktemp "${TMPDIR:-/tmp}/pool-prompt-citysk.XXXXXX")"
trap 'rm -f "$NAMES_FILE" "$DERIVED_FILE" "$CITYSK_FILE" "${FIX:-}"' EXIT
# Names that live OUTSIDE this repo, so they cannot be derived: the incident's skill (its source file moved
# once already) and the core gc-* skills the gc binary materialises into every session.
EXTRA_NAMES="gate-done gc-work gc-dispatch gc-agents gc-rigs gc-mail gc-city gc-dashboard"
# the city's own skills (recall, refino, wa-worker-session-protocol, browser-control...) — measured 03/10 to be
# missing from the first version of this set, so a future unquoted "/recall" in a pool template passed.
{ [ -d "$CITY_DIR/skills" ] && for s in "$CITY_DIR/skills"/*/; do [ -f "${s}SKILL.md" ] && basename "$s"; done; } 2>/dev/null | grep -E '^[A-Za-z][A-Za-z0-9._-]*$' | sort -u > "$CITYSK_FILE"
{
  cat "$CITYSK_FILE"
  for d in "$ROOT/.claude/commands" "$CITY_DIR/commands"; do
    [ -d "$d" ] && for f in "$d"/*.md; do [ -f "$f" ] && basename "$f" .md; done
  done
  [ -d "$ROOT/.claude/skills" ] && for s in "$ROOT/.claude/skills"/*/; do [ -f "${s}SKILL.md" ] && basename "$s"; done
} 2>/dev/null | grep -E '^[A-Za-z][A-Za-z0-9._-]*$' | sort -u > "$DERIVED_FILE"
{ cat "$DERIVED_FILE"; for n in $EXTRA_NAMES; do echo "$n"; done; } | sort -u > "$NAMES_FILE"
NDERIVED="$(wc -l < "$DERIVED_FILE" | tr -d ' ')"; NCITYSK="$(wc -l < "$CITYSK_FILE" | tr -d ' ')"; NNAMES="$(wc -l < "$NAMES_FILE" | tr -d ' ')"
if [ "$NDERIVED" -ge 1 ]; then ok "$NDERIVED name(s) derived from files in the repo (+ ${EXTRA_NAMES// /,} from outside it = $NNAMES)"
else bad "no name could be derived from the repo: the detector would only know the hard-coded extras"; fi
if [ "$NCITYSK" -ge 1 ]; then ok "the city's own skills/ contributed $NCITYSK name(s)"
else bad "no skill found under $CITY_DIR/skills: the city's skills would silently drop out of the detector"; fi
ALT="$(sed 's/\./\\./g' "$NAMES_FILE" | paste -sd'|' -)"

# Token = "/<name>" not glued to a path/word on the left, and not continued into a path/extension on the
# right. STRICT also flags the backtick-quoted form; TRIGGER (the measured one) does not.
PRE_STRICT='(^|[^[:alnum:]_/.~-])'
PRE_TRIGGER='(^|[^[:alnum:]_/.~`-])'
POST='([^[:alnum:]_/.-]|\.([^[:alnum:]]|$)|$)'
hits() { # hits <strict|trigger> <file>  -> matching lines, "N:text"
  local pre="$PRE_TRIGGER"; [ "$1" = strict ] && pre="$PRE_STRICT"
  grep -nE "${pre}/(${ALT})${POST}" "$2" 2>/dev/null   # exit: 0 = token found, 1 = clean, >=2 = could not read
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
expect trigger flag  'first run /recall to look for prior art'                'a city skill (from the city skills/ dir)'
expect trigger flag  'use /gc-work to find beads'                             'a core gc-* skill (outside the repo)'
expect strict  clear 'commit → the gate-done skill → exit.'                    'replacement wording'
expect strict  clear 'use a skill `gate-done` (NUNCA `gt mq submit`)'          'replacement wording, backticked name'
expect strict  clear 'see .claude/commands/gate-done.md for details'           'path ending in the skill file'
expect strict  clear 'branch crew/wa-worker/gate-done-fix'                     'branch name containing the name'
expect strict  clear 'https://example.com/docs/gate-done'                      'URL'
expect strict  clear 'the gate-done-marker file'                               'longer hyphenated word'
expect strict  clear '/gate-done/x is a directory'                             'path continuing after the name'

UNR="$(mktemp "${TMPDIR:-/tmp}/pool-prompt-unreadable.XXXXXX")"; printf '/gate-done\n' > "$UNR"; chmod 000 "$UNR"
if [ -r "$UNR" ]; then echo "  ~ SKIP: cannot make a file unreadable here (running as a user that reads everything)"
else hits strict "$UNR" >/dev/null; r=$?
  [ "$r" -ge 2 ] && ok "unreadable file => grep exit $r, distinguishable from 'clean' (1)" || bad "unreadable file gave grep exit $r: it would pass as a clean template"; fi
chmod 600 "$UNR"; rm -f "$UNR"

# ---- C. templates -----------------------------------------------------------------------------------
echo "C. agents/*/prompt.template.md"
SCANNED=0
for f in "$AGENTS_DIR"/*/prompt.template.md; do
  [ -f "$f" ] || continue
  SCANNED=$((SCANNED+1)); agent="$(basename "$(dirname "$f")")"
  mode=trigger; case " $POOL_TEMPLATES " in *" $agent "*) mode=strict ;; esac
  h="$(hits "$mode" "$f")"; rc=$?
  case "$rc" in
    1) ok "$agent: no skill token ($mode)" ;;
    0) bad "$agent: skill token present ($mode) — Claude Code will attach a skill_mention at boot:"; echo "$h" | sed 's/^/      /' | cut -c1-170 ;;
    *) bad "$agent: template could not be read (grep exit $rc) — an unreadable template is not a clean one" ;;
  esac
done
[ "$SCANNED" -ge 1 ] && ok "scanned $SCANNED template(s)" || bad "scanned 0 templates under $AGENTS_DIR: nothing was checked"
for p in $POOL_TEMPLATES; do
  [ -f "$AGENTS_DIR/$p/prompt.template.md" ] || bad "pool template listed but missing: $p (a renamed pool would silently escape the strict rule)"
done

# ---- C2. global fragments: appended to EVERY boot prompt, the pool workers' included ----------------------
echo "C2. city.toml global_fragments"
FRAGS="$(python3 -c 'import sys, tomllib; print(*tomllib.load(open(sys.argv[1], "rb"))["workspace"]["global_fragments"])' "$CITY_DIR/city.toml" 2>/dev/null)"; frc=$?
if [ "$frc" -ne 0 ] || [ -z "$FRAGS" ]; then
  bad "cannot read global_fragments from $CITY_DIR/city.toml (rc=$frc): the fragments appended to every boot prompt were not checked"
else
  NSCAN=0
  for fr in $FRAGS; do
    ff="$(ls "$CITY_DIR"/packs/*/template-fragments/"$fr".template.md 2>/dev/null | head -1)"
    if [ -z "$ff" ]; then
      echo "  ~ NOT SCANNED: fragment '$fr' is not in this repo (it ships inside the gc binary); a skill token there cannot be seen from here"
      continue
    fi
    NSCAN=$((NSCAN+1))
    h="$(hits strict "$ff")"; rc=$?
    case "$rc" in
      1) ok "fragment $fr: no skill token (strict)" ;;
      0) bad "fragment $fr: skill token present (strict) — it is appended to every pool worker's boot prompt:"; echo "$h" | sed 's/^/      /' | cut -c1-170 ;;
      *) bad "fragment $fr: could not be read (grep exit $rc)" ;;
    esac
  done
  [ "$NSCAN" -ge 1 ] && ok "scanned $NSCAN fragment(s) from the repo" || bad "no global fragment lives in this repo: nothing was checked"
fi

echo
echo "pool-prompt-skill-mention selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
