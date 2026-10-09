#!/bin/bash
# e12-crew-doctrine.sh — ga-0nz1wi: the write-time doctrine reaches the named crews (thies/oracle/digo/mila/peter/batista) from the SAME
# text the Pilot appends to a dispatch.
#
# WHY. The doctrine block (e12-arms.sh, e12_block_text) is appended by the Pilot to a builder's dispatch message, and the named crews are
# not built from a Pilot dispatch, so they never saw it. ga-0nz1wi measured the gate log of 09/10 00:00–06:45: the crews failed the gate
# more often than the pool workers, and most of the FAILs were the one mistake the block exists to prevent (a read that can come back
# empty or fail, handled as if both meant the same). A copy typed into six prompts would drift from the Pilot's the first time someone
# edits the text, so the crews' text is GENERATED from e12_block_text into a marked region of each prompt template.
#
# WHY INLINE TEXT AND NOT A {{ template }} INCLUDE. The obvious design — the text in a template fragment, the six prompts including it —
# was tried and rejected. The gate's template-fragment-lint-guard runs `gc lint` from the repo root, where packs/town-deltas is not
# imported, so it reports every such include as "template not defined" (the same lint-context artifact it already tolerates for
# propulsion-dog). Tolerating that message for these six prompts would also blind the guard to the failure it exists for — an include
# whose fragment was renamed or deleted, which is a crew prompt that does not render. Literal text between two markers cannot dangle:
# the worst a stale copy does is show older wording, and `check` says so.
#
# The region is these lines, in each prompt, where the doctrine goes (the markers are Go-template comments: they render as nothing):
#     {{/* e12-doctrine:begin … */}}
#     <the block, exactly as e12_block_text prints it>
#     {{/* e12-doctrine:end */}}
# Keep both marker lines whole. A begin marker that lost its closing `*/}}` makes the engine swallow everything up to the end marker's
# own `*/}}` — the block vanishes from the prompt with exit 0 and nothing on stderr (measured in the selftest, section C). `check` reports
# that prompt as STALE, since its begin line no longer equals the generated one.
#
#   render  print the region on stdout. Nothing on stdout if it cannot be made.
#   write    render, then put the fresh region into every crew prompt. If any prompt cannot be read or has no usable marker pair, NO prompt is
#            touched. Each file is replaced through a temp file + rename; a rename that fails part-way is not rolled back, it is reported
#            with the list of files already replaced (run write again). Run it after editing the block text.
#   check    exit 0 iff every crew prompt's region is byte-identical to a fresh render.
#            exit 1 = at least one prompt is stale, or its marker pair is missing/duplicated/out of order (the message names the file);
#            exit 2 = could not tell (the render, or a prompt, could not be read).
#
# THREE STATES, NEVER TWO. "Current" / "stale or broken" / "could not tell" are three different exits. A block that cannot be read from
# e12-arms.sh, that comes back empty, that does not start with the header the Pilot checks, or that contains a template action ({{ or }}:
# the engine would run it, and the Pilot would send something else) is "could not render" — never an empty region, because an empty region
# is what a failed write leaves behind and a prompt that carries it silently loses the doctrine.
#
# Env (tests only): E12_ARMS = the e12-arms.sh to render from; E12_CREW_AGENTS_DIR = the agents/ directory holding <crew>-wa/prompt.template.md;
# E12_CREW_NAMES = the crews (default: thies oracle digo mila peter batista).
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMS="${E12_ARMS:-$SD/e12-arms.sh}"
AGENTS="${E12_CREW_AGENTS_DIR:-$SD/../../../agents}"
AGENTS="$(cd "$AGENTS" 2>/dev/null && pwd || printf '%s' "$AGENTS")"   # a normalised path in messages; an unreachable one stays as given
CREWS="${E12_CREW_NAMES:-thies oracle digo mila peter batista}"
HEADER="## Write-time doctrine"
BEGIN='{{/* e12-doctrine:begin — GENERATED from e12_block_text (assets/e12-arms.sh) by assets/e12-crew-doctrine.sh (ga-0nz1wi). Edit the text there, then run '"'"'bash e12-crew-doctrine.sh write'"'"'. */}}'
END='{{/* e12-doctrine:end */}}'

# The block exactly as the Pilot gets it (without the trailing newline $(...) drops), or rc 1 with the reason on stderr.
e12_crew_block() {
  local out rc=0
  [ -r "$ARMS" ] || { echo "e12-crew-doctrine: $ARMS is not readable" >&2; return 1; }
  # shellcheck source=/dev/null  # ARMS is overridable on purpose (tests); the default is e12-arms.sh next to this file
  out="$( . "$ARMS" >/dev/null 2>&1 && e12_block_text )" || rc=$?
  [ "$rc" -eq 0 ] || { echo "e12-crew-doctrine: e12_block_text failed (rc=$rc) when sourced from $ARMS" >&2; return 1; }
  [ -n "$out" ] || { echo "e12-crew-doctrine: e12_block_text printed nothing" >&2; return 1; }
  case "$out" in
    "$HEADER"*) ;;
    *) echo "e12-crew-doctrine: e12_block_text does not start with '$HEADER' — the Pilot would refuse it, so the crews do not get it either" >&2; return 1 ;;
  esac
  case "$out" in
    *'{{'*|*'}}'*) echo "e12-crew-doctrine: the block contains a template action ({{ or }}) — the prompt engine would run it instead of printing it" >&2; return 1 ;;
  esac
  printf '%s' "$out"
}

# The region (begin marker, block, end marker; every line ends in a newline), or nothing and rc 1.
e12_region() {
  local block
  block="$(e12_crew_block)" || return 1
  printf '%s\n%s\n%s\n' "$BEGIN" "$block" "$END"
}

# The region with a sentinel byte appended, so a caller can keep the trailing newline that $(...) would drop: the `&&` is what makes a
# failed render fail the substitution (with `;` the substitution would end with the exit status of the printf and always look fine).
e12_region_x() { e12_region && printf x; }

# The file surgery. Python, not sed: it has to tell "no marker pair" from "could not read the file" from "region differs", and rewrite
# six files all-or-nothing. argv: <check|write> <region> <prompt path>...   stdout: the one-line result. stderr: one line per problem.
# Exit: 0 ok · 1 (check only) stale or broken markers · 2 could not tell / did not write.
read -r -d '' E12_PY <<'PYEOF' || true
import os, shutil, sys

mode, region, paths = sys.argv[1], sys.argv[2].rstrip("\n") + "\n", sys.argv[3:]
BEGIN_PREFIX = "{{/* e12-doctrine:begin"
END_LINE = "{{/* e12-doctrine:end */}}"
unreadable, broken, stale, new = [], [], [], {}


def say(msg):
    print("e12-crew-doctrine: " + msg, file=sys.stderr)


for p in paths:
    # vazio → an empty file has no marker pair, which is BROKEN (a known state); falhou/ilegível → CANNOT TELL, never stale and never current
    try:
        with open(p, encoding="utf-8", newline="") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        unreadable.append(p)
        say("CANNOT TELL — %s: %s" % (p, e))
        continue
    lines = text.splitlines(keepends=True)
    b = [i for i, l in enumerate(lines) if l.startswith(BEGIN_PREFIX)]
    e = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == END_LINE]
    if len(b) != 1 or len(e) != 1 or b[0] >= e[0]:
        broken.append(p)
        say("BROKEN MARKERS — %s: expected one begin line followed by one end line, found %d begin and %d end "
            "(write cannot place them: add the two marker lines where the doctrine goes)" % (p, len(b), len(e)))
        continue
    if "".join(lines[b[0]:e[0] + 1]) != region:
        stale.append(p)
        if mode == "check":
            say("STALE — %s differs from e12_block_text (run: bash e12-crew-doctrine.sh write)" % p)
        else:
            say("updating %s (it differed from e12_block_text)" % p)
        new[p] = "".join(lines[:b[0]]) + region + "".join(lines[e[0] + 1:])

if mode == "check":
    if unreadable:
        sys.exit(2)
    if broken or stale:
        sys.exit(1)
    print("e12-crew-doctrine: current (%d prompts)" % len(paths))
    sys.exit(0)

# write: all or nothing. A prompt that cannot be read or has no usable marker pair stops the whole run before any file is touched.
if unreadable or broken:
    say("not writing — %d prompt(s) could not be read and %d have no usable marker pair; no prompt was touched" % (len(unreadable), len(broken)))
    sys.exit(2)
if not new:
    print("e12-crew-doctrine: already current (%d prompts), nothing written" % len(paths))
    sys.exit(0)
staged = []
try:
    for p, t in new.items():
        tmp = "%s.tmp.%d" % (p, os.getpid())
        staged.append((p, tmp))
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(t)
        shutil.copymode(p, tmp)
except OSError as e:
    for _, tmp in staged:
        if os.path.lexists(tmp):
            os.remove(tmp)
    say("not writing — could not stage the new text (%s); no prompt was touched" % e)
    sys.exit(2)
replaced = []
try:
    for p, tmp in staged:
        os.replace(tmp, p)
        replaced.append(p)
except OSError as e:
    for p, tmp in staged:
        if p not in replaced and os.path.lexists(tmp):
            os.remove(tmp)
    say("FAILED part-way (%s): replaced %d of %d prompts: %s — run write again" % (e, len(replaced), len(staged), " ".join(replaced)))
    sys.exit(2)
print("e12-crew-doctrine: wrote %d prompt(s)" % len(replaced))
PYEOF

e12_crew_main() {
  local cmd="${1:-}" rendered c paths=""
  case "$cmd" in
    render|write|check) ;;
    *) echo "usage: e12-crew-doctrine.sh render | write | check" >&2; return 2 ;;
  esac
  command -v python3 >/dev/null 2>&1 || { echo "e12-crew-doctrine: python3 is missing — the prompts cannot be read or rewritten" >&2; return 2; }
  rendered="$(e12_region_x)" || { echo "e12-crew-doctrine: CANNOT RENDER — nothing was compared or written" >&2; return 2; }
  rendered="${rendered%x}"
  [ -n "$rendered" ] || { echo "e12-crew-doctrine: CANNOT RENDER — the region came back empty" >&2; return 2; }
  if [ "$cmd" = render ]; then printf '%s' "$rendered"; return 0; fi
  for c in $CREWS; do paths="$paths $AGENTS/$c-wa/prompt.template.md"; done
  # shellcheck disable=SC2086  # the paths are space-free by construction (crew names and the agents dir)
  python3 -I -c "$E12_PY" "$cmd" "$rendered" $paths
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then e12_crew_main "$@"; exit $?; fi
