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
#   write    render, then put the fresh text into every target (crew prompts and the fragment section). If any target cannot be read or has no
#            usable marker, NO file is touched. Each file is replaced through a temp file + rename; a rename that fails part-way is not rolled
#            back, it is reported with the list of files already replaced (run write again). Run it after editing the block text.
#   check    exit 0 iff every target is byte-identical to a fresh render.
#            exit 1 = at least one target is stale, or its marker is missing/duplicated/out of order (the message names the file);
#            exit 2 = could not tell (the render, or a target, could not be read).
#
# THREE STATES, NEVER TWO. "Current" / "stale or broken" / "could not tell" are three different exits. A block that cannot be read from
# e12-arms.sh, that comes back empty, that does not start with the header the Pilot checks, or that contains a template action ({{ or }}:
# the engine would run it, and the Pilot would send something else) is "could not render" — never an empty region, because an empty region
# is what a failed write leaves behind and a prompt that carries it silently loses the doctrine.
#
# ga-57e7l0 (a) — THE PILOT'S MESSAGE IS NOT THE ONLY WAY A BEAD REACHES A BUILDER. Measured 16/10 (roster x gate log, treated_pct=100): 70% of the
# beads the gate reviewed have no roster row, and even a bead WITH a row was often never shown the text: dispatch_one() spawns the pool
# worker with a bare `gc session new` and drops the message; pool top-up (Step 2d) sends none; a gate FAIL returns the bead to the pool,
# where a worker serves itself. For those builders the PROMPT is the only channel, so this script also writes the block into:
#   - the town-deltas fragment, as the guarded section td:e12-write-time-doctrine (TD_ROLE dog / ps-worker / wa-worker, show_unset=false: a
#     crew has no TD_ROLE and already carries its own region, so it must not get the block twice);
#   - three more crew prompts that build and finish through the gate (batista-ps, thies-ps, batista-lx), as the same marked region.
# The fragment section is plain text between its guard line and `{{ end -}}` (no markers inside: pool-preamble-build.py compares the rendered
# prompt with the fragment's lines, byte for byte).
#
#   coverage exit 0 iff every builder prompt is covered by one of the two channels and each channel is wired:
#            (1) the fragment section's guard lists dog, ps-worker and wa-worker and does not show the block to an agent with no TD_ROLE;
#            (2) city.toml gives each of those roles to an agent (a guard for a role nobody has renders for nobody) and puts town-deltas in
#                global_fragments (otherwise the fragment renders nowhere);
#            (3) every agents/*/prompt.template.md that mentions gate-done is a region target here or belongs to such a role agent.
#            exit 1 = a gap (every gap is listed on stderr); exit 2 = could not tell (a file, or tomllib, is missing) — never "covered".
#
# Env (tests only): E12_ARMS = the e12-arms.sh to render from; E12_CREW_AGENTS_DIR = the agents/ directory holding <crew>-wa/prompt.template.md;
# E12_CREW_NAMES = the crews (default: thies oracle digo mila peter batista); E12_EXTRA_AGENTS = more agents whose own prompt gets the region
# (default: batista-ps thies-ps batista-lx; set but empty = none); E12_FRAGMENT = the fragment file (default: ../template-fragments/town-deltas.template.md;
# set but empty = no fragment target); E12_CITY_TOML = the city.toml that coverage reads (default: three levels above this file).
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMS="${E12_ARMS:-$SD/e12-arms.sh}"
AGENTS="${E12_CREW_AGENTS_DIR:-$SD/../../../agents}"
AGENTS="$(cd "$AGENTS" 2>/dev/null && pwd || printf '%s' "$AGENTS")"   # a normalised path in messages; an unreachable one stays as given
CREWS="${E12_CREW_NAMES:-thies oracle digo mila peter batista}"
EXTRA="${E12_EXTRA_AGENTS-batista-ps thies-ps batista-lx}"              # no colon: set-but-empty means "none", unset means the default
FRAGMENT="${E12_FRAGMENT-$SD/../template-fragments/town-deltas.template.md}"
CITY_TOML="${E12_CITY_TOML-$SD/../../../city.toml}"
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

# The file surgery. Python, not sed: it has to tell "no marker" from "could not read the file" from "text differs", and rewrite several
# files all-or-nothing. argv: <check|write> <region> <block> <kind:path>...   (kind = region | fragment)
# stdout: the one-line result. stderr: one line per problem. Exit: 0 ok · 1 (check only) stale or broken markers · 2 could not tell / did not write.
#   region    a crew prompt: the lines from the begin marker to the end marker are `region`.
#   fragment  the town-deltas fragment: the lines between the guard line that carries `{{/* td:e12-write-time-doctrine */ -}}` and the next
#             `{{ end -}}` are `block`, a blank line, nothing else (pool-preamble-build.py reads those lines as the section's text).
read -r -d '' E12_PY <<'PYEOF' || true
import os, shutil, sys

mode, region, block, targets = sys.argv[1], sys.argv[2].rstrip("\n") + "\n", sys.argv[3].rstrip("\n"), sys.argv[4:]
BEGIN_PREFIX = "{{/* e12-doctrine:begin"
END_LINE = "{{/* e12-doctrine:end */}}"
FRAG_MARK = "{{/* td:e12-write-time-doctrine */ -}}"
FRAG_END = "{{ end -}}"
unreadable, broken, stale, new = [], [], [], {}


def say(msg):
    print("e12-crew-doctrine: " + msg, file=sys.stderr)


def find_region(lines):
    """-> (first, last, expected text) of the replaceable span, or None when the markers are not exactly one usable pair."""
    b = [i for i, l in enumerate(lines) if l.startswith(BEGIN_PREFIX)]
    e = [i for i, l in enumerate(lines) if l.rstrip("\r\n") == END_LINE]
    if len(b) != 1 or len(e) != 1 or b[0] >= e[0]:
        return None, "expected one begin line followed by one end line, found %d begin and %d end" % (len(b), len(e))
    return (b[0], e[0] + 1, region), ""


def find_fragment(lines):
    m = [i for i, l in enumerate(lines) if l.rstrip("\r\n").endswith(FRAG_MARK)]
    if len(m) != 1:
        return None, "expected exactly one line ending in %s, found %d" % (FRAG_MARK, len(m))
    ends = [i for i in range(m[0] + 1, len(lines)) if lines[i].rstrip("\r\n") == FRAG_END]
    if not ends:
        return None, "the section opened by %s has no %s after it" % (FRAG_MARK, FRAG_END)
    return (m[0] + 1, ends[0], block + "\n\n"), ""


for t in targets:
    kind, _, p = t.partition(":")
    # vazio → an empty file has no marker, which is BROKEN (a known state); falhou/ilegível → CANNOT TELL, never stale and never current
    try:
        with open(p, encoding="utf-8", newline="") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        unreadable.append(p)
        say("CANNOT TELL — %s: %s" % (p, e))
        continue
    lines = text.splitlines(keepends=True)
    span, why = (find_region if kind == "region" else find_fragment)(lines)
    if span is None:
        broken.append(p)
        say("BROKEN MARKERS — %s: %s (write cannot place the text: put the marker lines where the doctrine goes)" % (p, why))
        continue
    first, last, want = span
    if "".join(lines[first:last]) != want:
        stale.append(p)
        if mode == "check":
            say("STALE — %s differs from e12_block_text (run: bash e12-crew-doctrine.sh write)" % p)
        else:
            say("updating %s (it differed from e12_block_text)" % p)
        new[p] = "".join(lines[:first]) + want + "".join(lines[last:])

if mode == "check":
    if unreadable:
        sys.exit(2)
    if broken or stale:
        sys.exit(1)
    print("e12-crew-doctrine: current (%d targets)" % len(targets))
    sys.exit(0)

# write: all or nothing. A target that cannot be read or has no usable marker stops the whole run before any file is touched.
if unreadable or broken:
    say("not writing — %d target(s) could not be read and %d have no usable marker; no file was touched" % (len(unreadable), len(broken)))
    sys.exit(2)
if not new:
    print("e12-crew-doctrine: already current (%d targets), nothing written" % len(targets))
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
    say("not writing — could not stage the new text (%s); no file was touched" % e)
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
    say("FAILED part-way (%s): replaced %d of %d files: %s — run write again" % (e, len(replaced), len(staged), " ".join(replaced)))
    sys.exit(2)
print("e12-crew-doctrine: wrote %d target(s)" % len(replaced))
PYEOF

# coverage: is every prompt that builds and finishes through the gate covered by one of the two channels? Reads no block text. argv: <agents dir>
# <fragment path or ""> <city.toml> <names of the agents whose own prompt carries the region>.
# Exit: 0 covered · 1 at least one gap (all listed on stderr) · 2 could not tell (a file or tomllib is missing, a file does not parse).
read -r -d '' E12_COV_PY <<'PYEOF' || true
import re, sys
from pathlib import Path

agents_dir, fragment, city_toml, region_agents = Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4].split()
FRAG_MARK = "{{/* td:e12-write-time-doctrine */ -}}"
POOL_ROLES = ("dog", "ps-worker", "wa-worker")        # the three pool roles a bead can be handed to without a Pilot message
gaps, unknown = [], []


def say(msg):
    print("e12-crew-doctrine: " + msg, file=sys.stderr)


try:
    import tomllib
except ImportError:                                   # python < 3.11
    say("CANNOT TELL — tomllib is missing (python >= 3.11 needed to read city.toml)")
    sys.exit(2)

# (1) the fragment section's guard. vazio → no marker line is a GAP (known); falhou/ilegível → CANNOT TELL, never "covered"
guard_roles, section, ftext = set(), False, None
if not fragment:
    unknown.append("no fragment path given")
else:
    try:
        ftext = Path(fragment).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        unknown.append("fragment %s: %s" % (fragment, e))
if ftext is not None:
    marks = [l for l in ftext.splitlines() if l.rstrip().endswith(FRAG_MARK)]
    if len(marks) != 1:
        gaps.append("the fragment has %d section(s) marked %s (expected exactly 1): the pool roles get no block from their prompt" % (len(marks), FRAG_MARK))
    else:
        section = True
        guard = marks[0][: marks[0].index(FRAG_MARK)]
        guard_roles = set(re.findall(r'\(?eq \.TD_ROLE "([^"]+)"\)?', guard))
        for r in POOL_ROLES:
            if r not in guard_roles:
                gaps.append("pool role %s is not in the guard of the fragment's E12 section — a %s session is handed beads without the block" % (r, r))
        if re.search(r"\bnot \.TD_ROLE\b", guard):
            gaps.append("the guard of the fragment's E12 section also shows it to an agent with no TD_ROLE (every crew) — they carry their own region, "
                        "so they would read the block twice; the section must be show_unset=false")

# (2) city.toml: who has which TD_ROLE, and is the fragment rendered at all
role_agents = {}
try:
    with open(city_toml, "rb") as fh:
        city = tomllib.load(fh)
except (OSError, tomllib.TOMLDecodeError) as e:
    unknown.append("city.toml %s: %s" % (city_toml, e))
    city = None
if city is not None:
    for a in city.get("patches", {}).get("agent", []) or []:
        role = (a.get("env") or {}).get("TD_ROLE")
        if role and a.get("name"):
            role_agents.setdefault(role, []).append(a["name"])
    for r in POOL_ROLES:
        if r not in role_agents:
            gaps.append("no agent in city.toml has TD_ROLE=%s — the fragment section is guarded for a role nobody has, so it renders for nobody" % r)
    if "town-deltas" not in (city.get("workspace", {}).get("global_fragments") or []):
        gaps.append("town-deltas is not in workspace.global_fragments of city.toml — the fragment (and the E12 section in it) renders in no prompt")

# (3) every prompt that finishes through the gate is covered by a channel
covered_by_role = {}                                  # prompt dir name -> role, for the dirs of agents that carry a pool role
for r in POOL_ROLES:
    if section and r in guard_roles:
        for n in role_agents.get(r, []):
            covered_by_role[n] = r
seen = {}
try:
    prompts = sorted(agents_dir.glob("*/prompt.template.md"))
    if not prompts:
        unknown.append("no agents/*/prompt.template.md under %s" % agents_dir)
    for p in prompts:
        try:
            text = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            unknown.append("%s: %s" % (p, e))
            continue
        if "gate-done" not in text:
            continue
        name = p.parent.name
        if name in region_agents:
            seen[name] = "region"
        elif name in covered_by_role:
            seen[name] = "fragment (TD_ROLE=%s)" % covered_by_role[name]
        elif city is None:
            # falhou/ilegível → without city.toml nobody knows which agent has a pool role, so this prompt is "cannot tell", not "uncovered"
            unknown.append("%s mentions gate-done and has no region of its own; whether a pool TD_ROLE covers it cannot be told without city.toml" % p)
        else:
            gaps.append("UNCOVERED builder prompt — %s mentions gate-done but nothing gives it the E12 block: add it to E12_EXTRA_AGENTS in "
                        "e12-crew-doctrine.sh (and put the marker pair in it), or give its agent a pool TD_ROLE" % p)
except OSError as e:
    unknown.append("agents dir %s: %s" % (agents_dir, e))

for g in gaps:
    say("GAP — " + g)
for u in unknown:
    say("CANNOT TELL — " + u)
if gaps:
    sys.exit(1)
if unknown:
    sys.exit(2)
print("e12-crew-doctrine: coverage ok")
print("  pool roles (fragment section, TD_ROLE guard): " + ", ".join("%s [%s]" % (r, " ".join(role_agents[r])) for r in POOL_ROLES))
print("  prompts with their own region: " + " ".join(sorted(region_agents)))
print("  builder prompts that mention gate-done, all covered (%d): %s" % (len(seen), ", ".join("%s via %s" % (n, how) for n, how in sorted(seen.items()))))
PYEOF

e12_crew_main() {
  local cmd="${1:-}" rendered block c a targets=""
  case "$cmd" in
    render|write|check|coverage) ;;
    *) echo "usage: e12-crew-doctrine.sh render | write | check | coverage" >&2; return 2 ;;
  esac
  command -v python3 >/dev/null 2>&1 || { echo "e12-crew-doctrine: python3 is missing — the prompts cannot be read or rewritten" >&2; return 2; }
  if [ "$cmd" = coverage ]; then
    local names=""
    for c in $CREWS; do names="$names $c-wa"; done
    for a in $EXTRA; do names="$names $a"; done
    python3 -I -c "$E12_COV_PY" "$AGENTS" "$FRAGMENT" "$CITY_TOML" "$names"
    return $?
  fi
  rendered="$(e12_region_x)" || { echo "e12-crew-doctrine: CANNOT RENDER — nothing was compared or written" >&2; return 2; }
  rendered="${rendered%x}"
  [ -n "$rendered" ] || { echo "e12-crew-doctrine: CANNOT RENDER — the region came back empty" >&2; return 2; }
  if [ "$cmd" = render ]; then printf '%s' "$rendered"; return 0; fi
  block="$(e12_crew_block)" || { echo "e12-crew-doctrine: CANNOT RENDER — nothing was compared or written" >&2; return 2; }
  for c in $CREWS; do targets="$targets region:$AGENTS/$c-wa/prompt.template.md"; done
  for a in $EXTRA; do targets="$targets region:$AGENTS/$a/prompt.template.md"; done
  [ -n "$FRAGMENT" ] && targets="$targets fragment:$FRAGMENT"
  # shellcheck disable=SC2086  # the targets are space-free by construction (crew names and the agents dir)
  python3 -I -c "$E12_PY" "$cmd" "$rendered" "$block" $targets
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then e12_crew_main "$@"; exit $?; fi
