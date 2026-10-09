#!/bin/bash
# e12-crew-doctrine.selftest.sh — ga-0nz1wi: the named crews (thies/oracle/digo/mila/peter/batista) get the write-time doctrine, and it is
# the SAME text the Pilot appends to a dispatch.
#
#   A. one source   the Pilot's text (e12-arms.sh block, the CLI the dispatcher calls) is what `e12-crew-doctrine.sh check` expects of the
#                   six prompts, and `check` passes on the real tree
#   B. the prompts  each of the six crew prompt templates carries exactly one marked region whose text is the Pilot's, byte for byte (read
#                   here with awk, not through the generator)
#   C. real engine  `gc prime --strict` (the LIVE binary) on the six REAL prompt templates, in a throw-away city that imports the REAL
#                   packs/: the rendered prompt is the crew's own template (its two marker comments render as nothing), the Pilot's block is
#                   there exactly once, and the town-deltas core is still there. The test reads the rendered prompt, never the file.
#   D. controls     every way this can silently stop being true must FAIL here: a region that is gone/doubled/drifted/emptied/unclosed or
#                   holds a template action (engine half), and a source that moved but prompts that did not, a source that cannot be
#                   rendered, a prompt with no usable marker pair, a prompt that is missing or unreadable (generator half, three states).
#                   A control that does not fail means the check above it proves nothing.
#
# Hermetic: no live store, no session; `gc prime` without --hook only writes to stdout. The generator half works on copies in a scratch
# dir. Needs python3 and the `gc` binary (E12C_GC).
# Env: E12C_HQ (the city root in git; default: three levels above this file), E12C_GC (default `gc`), E12C_KEEP=1 (keep the scratch dir).
# bash 3.2 (macOS /bin/bash) safe: no arrays, no associative arrays, no mapfile.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ="${E12C_HQ:-$(cd "$HERE/../../.." && pwd)}"
GC="${E12C_GC:-gc}"
GEN="$HERE/e12-crew-doctrine.sh"
ARMS="$HERE/e12-arms.sh"
AGENTS="$HQ/agents"
CREWS="thies oracle digo mila peter batista"
HEADER='## Write-time doctrine'
END_LINE='{{/* e12-doctrine:end */}}'

PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; }

[ -r "$ARMS" ] || { echo "FAIL: $ARMS not readable" >&2; exit 1; }
[ -r "$GEN" ]  || { echo "FAIL: $GEN not readable — the generator the crews' text comes from does not exist" >&2; exit 1; }
[ -f "$HQ/city.toml" ] || { echo "FATAL: $HQ/city.toml not found — E12C_HQ must be the city root" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 missing — the engine half compares the rendered prompt byte for byte" >&2; exit 1; }

# No scratch dir is a hard stop: with W empty every "$W/..." below would point at the filesystem root.
W="$(mktemp -d "${TMPDIR:-/tmp}/e12-crew-doctrine-selftest.XXXXXX")" || { echo "FATAL: cannot create a scratch directory under ${TMPDIR:-/tmp} — nothing was run" >&2; exit 2; }
case "$W" in /?*) ;; *) echo "FATAL: mktemp printed no usable scratch path ('$W') — nothing was run" >&2; exit 2 ;; esac
# A selftest that dies half-way must not exit 0 (bash 3.2 does that for several abort shapes — ga-f31s7p): reaching the last line is
# part of passing. The scratch dir is removed with safe-clean when it allows the path, otherwise it is left and its path is printed.
REACHED_END=0
finish() {
  local rc=$?
  chmod -R u+rw "$W" 2>/dev/null
  if [ "${E12C_KEEP:-0}" = 1 ]; then echo "(kept: $W)"
  elif command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$W" >/dev/null 2>&1; then safe-clean "$W" >/dev/null 2>&1
  else echo "(scratch dir left behind: $W — safe-clean does not cover this location)"; fi
  if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi
}
trap finish EXIT

# The generator always runs as a subprocess under /bin/bash — the real contract, not a sourced shortcut. Result: RC, ERR (stderr), $W/gen.out (stdout).
RC=0; ERR=""
gen() { # gen <agents dir> <e12-arms.sh> <subcommand>
  E12_CREW_AGENTS_DIR="$1" E12_ARMS="$2" /bin/bash "$GEN" "$3" >"$W/gen.out" 2>"$W/gen.err"; RC=$?; ERR="$(cat "$W/gen.err")"
}
# A copy of the six real prompts under $W/<name>/<crew>-wa/. Every scenario gets its own directory: nothing in the scratch dir is deleted.
mkagents() { # mkagents <name> → prints the directory
  local d="$W/$1" c
  for c in $CREWS; do mkdir -p "$d/$c-wa" && cp "$AGENTS/$c-wa/prompt.template.md" "$d/$c-wa/prompt.template.md" || return 1; done
  printf '%s' "$d"
}
sums() { # sums <dir> → one checksum line per crew prompt: a change anywhere shows
  local c
  for c in $CREWS; do cksum < "$1/$c-wa/prompt.template.md" 2>/dev/null || echo "missing:$c"; done
}
edit() { # edit <file> <sed script>: rewrite through a temp file, and say whether anything changed (rc 1 = nothing changed)
  sed "$2" "$1" > "$1.new" && ! cmp -s "$1" "$1.new" && mv "$1.new" "$1"
}

# ── the Pilot's text ────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Exactly what pilot-dispatcher.sh runs (_e12_doctrine_block): `bash e12-arms.sh block <bead> <store> pilot-dispatch --no-record`, stdout
# captured with $(...) — against a throw-away state dir whose conf puts every bead in the treated arm. This is the independent reference:
# it does not go through e12-crew-doctrine.sh.
STATE="$W/state"; mkdir -p "$STATE"; printf 'treated_pct=100\n' > "$STATE/e12-ab.conf"
PILOT="$(E12_STATE_DIR="$STATE" /bin/bash "$ARMS" block ga-crewtest /nonexistent-store pilot-dispatch --no-record 2>"$W/pilot.err")"; PRC=$?
printf '%s' "$PILOT" > "$W/pilot.txt"

echo "== A. one source: the Pilot's text == what the crews' prompts must carry =="
if [ "$PRC" = 0 ] && case "$PILOT" in "$HEADER"*) true ;; *) false ;; esac; then
  ok "the Pilot's block (e12-arms.sh block, treated arm) is non-empty and starts with the header the dispatcher checks"
else
  bad "could not get the Pilot's block: rc=$PRC out='$(printf '%s' "$PILOT" | head -c 80)' err='$(cat "$W/pilot.err")'"
fi
case "$PILOT" in
  *'{{'*|*'}}'*) bad "the Pilot's text contains a template action ({{ or }}): the prompt engine would run it in a crew prompt instead of printing it" ;;
  *) ok "the Pilot's text holds no template action — the engine prints it as it is" ;;
esac
gen "$AGENTS" "$ARMS" check
[ "$RC" = 0 ] && ok "e12-crew-doctrine.sh check on the real tree: every crew prompt is current ($(cat "$W/gen.out"))" || bad "e12-crew-doctrine.sh check on the real tree: rc=$RC: $ERR"
case "$PILOT" in
  *'"Carregando…"'*timeout*|*timeout*'"Carregando…"'*) ok "the Pilot's text carries the 'not answered yet' case (Carregando… + a timeout that lands in the error state)" ;;
  *) bad "the text lacks the 'read that has not answered yet' case (Carregando… + timeout)" ;;
esac

echo "== B. the six crew prompts carry the Pilot's text in one marked region =="
for c in $CREWS; do
  p="$AGENTS/$c-wa/prompt.template.md"
  if [ ! -r "$p" ]; then bad "$c-wa: $p not readable"; continue; fi
  nb="$(grep -c '^{{/\* e12-doctrine:begin' "$p")"; ne="$(grep -cxF "$END_LINE" "$p")"
  if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then bad "$c-wa: $nb begin marker(s) and $ne end marker(s) (expected exactly 1 of each)"; continue; fi
  # The lines between the markers, read with awk (the begin line is skipped, the end line closes the region).
  inside="$(awk 'index($0,"{{/* e12-doctrine:begin")==1 {on=1; next} $0=="{{/* e12-doctrine:end */}}" {on=0} on' "$p")"
  [ -n "$inside" ] && [ "$inside" = "$PILOT" ] && ok "$c-wa: one region, its text == the Pilot's text (byte for byte)" || bad "$c-wa: the text between the markers differs from the Pilot's text, or is empty"
done

echo "== C. real engine: gc prime --strict on the six real prompts =="
# Python builds the throw-away cities and runs the LIVE gc; it prints one `ok <msg>` / `bad <msg>` line per check and the shell turns
# them into ok/bad (via a file, not a pipe: a pipe would count in a subshell and lose the totals).
cat > "$W/engine.py" <<'PYEOF'
import os, re, subprocess, sys
from pathlib import Path

hq = Path(os.environ["E12C_HQ"]); gc = os.environ["E12C_GC"]; work = Path(os.environ["E12C_WORK"])
pilot = Path(os.environ["E12C_PILOT"]).read_text(encoding="utf-8")        # the Pilot's text, as the dispatcher captures it
crews = os.environ["E12C_CREWS"].split()
BEGIN_RE = re.compile(r"\{\{/\* e12-doctrine:begin[^\n]*?\*/\}\}")
END_TXT = "{{/* e12-doctrine:end */}}"
REGION_RE = re.compile(r"\{\{/\* e12-doctrine:begin[^\n]*\*/\}\}\n.*?" + re.escape(END_TXT) + r"\n", re.S)
CORE = "REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA"             # a town-deltas core sentinel: the region must not displace it
CITY = ('[workspace]\nprovider = "claude"\nglobal_fragments = ["town-deltas"]\n\n[providers]\n[providers.claude]\nbase = "builtin:claude"\n\n'
        '[imports]\n[imports.town-deltas]\nsource = "packs/town-deltas"\n')
AGENT = 'max_active_sessions = 1\nmin_active_sessions = 0\nscope = "city"\n'
clean = {k: v for k, v in os.environ.items() if not k.startswith("GC_")}


def emit(kind, msg):
    print(f"{kind} {msg}", flush=True)


def make_city(root, packs, prompts):
    (root / ".gc").mkdir(parents=True); (root / "gchome").mkdir()
    (root / "pack.toml").write_text('[pack]\nname = "scratch"\nschema = 2\n'); (root / "city.toml").write_text(CITY)
    os.symlink(packs, root / "packs")
    for name, text in prompts.items():
        d = root / "agents" / name; d.mkdir(parents=True)
        (d / "agent.toml").write_text(AGENT); (d / "prompt.template.md").write_text(text)


def prime(root, name, retry):
    env = dict(clean); env["GC_HOME"] = str(root / "gchome")
    r = None
    for _ in range(2 if retry else 1):            # one retry on the real tree: the gc can be under load; a persistent error fails
        r = subprocess.run([gc, "--city", str(root), "prime", "--strict", name], cwd=root, env=env, capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            break
    return r


def problems(r, tpl):
    """What is wrong with this render. Empty list = the crew gets the Pilot's doctrine, its own prompt untouched, the core intact."""
    if r.returncode != 0:
        return [f"gc prime --strict rc={r.returncode}: {r.stderr.strip()[:200]}"]
    out = r.stdout; p = []
    expected = BEGIN_RE.sub("", tpl).replace(END_TXT, "")        # the template as the engine must print it: the two comments are nothing
    if not out.startswith(expected):
        p.append("the rendered prompt does not start with the crew's own template (its two marker comments rendered as nothing)")
    n = out.count(pilot)
    if n != 1:
        p.append(f"the Pilot's block appears {n} times in the rendered prompt (expected 1)")
    if CORE not in out:
        p.append("the town-deltas core (REGRA Nº 1) is missing from the rendered prompt")
    return p


real_packs = hq / "packs"
real = {c + "-wa": (hq / "agents" / (c + "-wa") / "prompt.template.md").read_text(encoding="utf-8") for c in crews}

# C. the real tree
root = work / "real"; make_city(root, real_packs, real)
for c in crews:
    name = c + "-wa"; r = prime(root, name, True); pr = problems(r, real[name])
    if pr:
        emit("bad", f"{name}: " + "; ".join(pr))
    else:
        emit("ok", f"{name}: rendered prompt = its own template, the Pilot's block ({len(pilot)} chars) exactly once, core intact ({len(r.stdout):,} chars)")

# D. controls: each mutant of a real prompt must be caught by the SAME judgement
t = real["thies-wa"]
m = REGION_RE.search(t)
if not m:
    emit("bad", "thies-wa has no marked region — the controls below are built from it and cannot run")
    sys.exit(0)
region = m.group(0); begin_line = region.split("\n")[0]
controls = [
    ("the whole region is gone (the prompt as it was before ga-0nz1wi)", t.replace(region, "")),
    ("the region is there twice",                                       t.replace(region, region + "\n" + region)),
    ("the block inside the region drifted from the Pilot's text (one phrase)", t.replace("in last week's gate reviews", "in the last weeks' gate reviews")),
    ("the region is emptied (markers kept, no text)",                   t.replace(region, begin_line + "\n" + END_TXT + "\n")),
    ("the begin marker is not closed (its */}} is missing)",            t.replace("*/}}\n" + pilot.split("\n")[0], "\n" + pilot.split("\n")[0])),
    ("a template action sits inside the block",                         t.replace("- Why: in last week's", "- Why: {{ .Nope }} in last week's")),
]
for i, (what, tpl) in enumerate(controls):
    if tpl == t:
        emit("bad", f"control — {what}: the mutation changed nothing (the text it edits moved; update this control)")
        continue
    root = work / f"ctl{i}"; make_city(root, real_packs, {"thies-wa": tpl})
    r = prime(root, "thies-wa", False); pr = problems(r, tpl)
    if pr:
        emit("ok", f"control — {what}: caught ({pr[0][:110]})")
    else:
        emit("bad", f"control — {what}: NOT caught — the engine check would pass on this")
# the mutants above are only meaningful if the unmutated twin passes the same judgement in the same kind of city
root = work / "ctl-twin"; make_city(root, real_packs, {"thies-wa": t})
r = prime(root, "thies-wa", True); pr = problems(r, t)
emit("ok" if not pr else "bad", "control twin — the unmutated prompt, built the same way as the mutants, passes" if not pr else "control twin — the unmutated prompt FAILS the judgement: " + "; ".join(pr))
PYEOF

if ! command -v "$GC" >/dev/null 2>&1; then
  bad "gc not found ('$GC') — this half cannot pass in silence; set E12C_GC"
else
  mkdir -p "$W/engine"
  E12C_HQ="$HQ" E12C_GC="$GC" E12C_WORK="$W/engine" E12C_PILOT="$W/pilot.txt" E12C_CREWS="$CREWS" python3 -I "$W/engine.py" > "$W/engine.out" 2> "$W/engine.err"
  erc=$?
  neng=0
  while IFS= read -r line; do
    case "$line" in
      "ok "*)  neng=$((neng+1)); ok "${line#ok }" ;;
      "bad "*) neng=$((neng+1)); bad "${line#bad }" ;;
      *)       bad "unexpected engine-half output: $line" ;;
    esac
  done < "$W/engine.out"
  [ "$erc" = 0 ] || bad "the engine half crashed (rc=$erc): $(tail -n 3 "$W/engine.err" | tr '\n' ' ')"
  # 6 real crews + 6 controls + 1 twin
  [ "$neng" = 13 ] && [ "$erc" = 0 ] && ok "the engine half ran all 13 checks (6 real prompts + 6 controls + the twin)" || bad "the engine half ran $neng checks (expected 13) — a half that stops early is not a pass"
fi

echo "== D. generator controls: a source that moved, prompts that cannot be placed, a source that cannot be rendered =="
# Work on copies: the real prompts and the real e12-arms.sh are never touched.
TWIN="$(mkagents twin)" || { bad "D: could not copy the real prompts into the scratch dir"; TWIN=""; }
if [ -n "$TWIN" ]; then
gen "$TWIN" "$ARMS" check
[ "$RC" = 0 ] && ok "control twin: an unmutated copy of the six prompts checks current (rc 0)" || bad "control twin: rc=$RC $ERR"

# 1. someone hand-edited the text inside one prompt
d="$(mkagents handedit)"; edit "$d/digo-wa/prompt.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || bad "hand-edit control: the edit changed nothing"
gen "$d" "$ARMS" check
if [ "$RC" = 1 ] && printf '%s' "$ERR" | grep -q 'digo-wa'; then ok "a hand-edited prompt: check says STALE (rc 1) and names digo-wa"; else bad "a hand-edited prompt: rc=$RC (expected 1, naming digo-wa) $ERR"; fi
# 2. the source moved, the prompts did not (the exact drift this selftest exists for)
cp "$ARMS" "$W/arms.moved"; edit "$W/arms.moved" "s/in last week's gate reviews/in the last weeks' gate reviews/" || bad "moved-source control: the edit changed nothing"
gen "$TWIN" "$W/arms.moved" check
[ "$RC" = 1 ] && ok "e12_block_text edited, prompts not regenerated: check says STALE (rc 1)" || bad "moved source: rc=$RC (expected 1) $ERR"

# 3. a prompt with no usable marker pair: check says broken (1); write refuses and touches NO prompt, not even the stale sibling
for shape in begin-gone:"/^{{\/\* e12-doctrine:begin/d" begin-twice:"/^{{\/\* e12-doctrine:begin/p" end-gone:"/^{{\/\* e12-doctrine:end \*\/}}\$/d"; do
  nm="${shape%%:*}"; sc="${shape#*:}"
  d="$(mkagents "markers-$nm")"
  edit "$d/oracle-wa/prompt.template.md" "$sc" || { bad "marker control '$nm': the edit changed nothing"; continue; }
  edit "$d/mila-wa/prompt.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || { bad "marker control '$nm': the sibling edit changed nothing"; continue; }
  before="$(sums "$d")"
  gen "$d" "$ARMS" check; rc_check=$RC; err_check="$ERR"
  gen "$d" "$ARMS" write; rc_write=$RC
  if [ "$rc_check" = 1 ] && printf '%s' "$err_check" | grep -q 'BROKEN MARKERS' && [ "$rc_write" = 2 ] && [ "$before" = "$(sums "$d")" ]; then
    ok "oracle-wa $nm: check says BROKEN MARKERS (rc 1); write refuses (rc 2) and leaves all six prompts untouched, the stale mila-wa included"
  else
    bad "oracle-wa $nm: check rc=$rc_check write rc=$rc_write prompts-untouched=$([ "$before" = "$(sums "$d")" ] && echo yes || echo NO) $err_check"
  fi
done

# 4. a prompt that is missing, or that exists but cannot be read — a third answer, never 'stale' and never 'current'
d="$(mkagents missing)"; mv "$d/batista-wa/prompt.template.md" "$d/batista-wa/prompt.template.gone"
gen "$d" "$ARMS" check
[ "$RC" = 2 ] && ok "a missing prompt: check says CANNOT TELL (rc 2)" || bad "a missing prompt: rc=$RC (expected 2) $ERR"
d="$(mkagents locked)"; chmod 000 "$d/peter-wa/prompt.template.md"
if [ -r "$d/peter-wa/prompt.template.md" ]; then
  echo "  ~ SKIP: this user can read a mode-000 file (root?) — the unreadable-prompt control cannot run here"
else
  gen "$d" "$ARMS" check; rc_check=$RC
  gen "$d" "$ARMS" write; rc_write=$RC
  [ "$rc_check" = 2 ] && [ "$rc_write" = 2 ] && ok "an unreadable prompt: check and write both say CANNOT TELL (rc 2)" || bad "an unreadable prompt: check rc=$rc_check write rc=$rc_write (expected 2 and 2)"
fi
chmod 600 "$d/peter-wa/prompt.template.md" 2>/dev/null

# 5. the source cannot be rendered: every shape is "cannot tell" (rc 2), on a copy that WOULD be stale, and nothing is written anywhere
mk_src() { # mk_src <name> <sed script> — a mutated copy of e12-arms.sh that must differ from the original
  sed "$2" "$ARMS" > "$W/arms.$1"; cmp -s "$ARMS" "$W/arms.$1" && { bad "source control '$1': the edit changed nothing"; return 1; }; return 0
}
for shape in missing:x unreadable-fn-fails:"s/^  cat <<'E12BLOCK'/  return 3; cat <<'E12BLOCK'/" empty-output:"s/^  cat <<'E12BLOCK'/  cat >\/dev\/null <<'E12BLOCK'/" \
             wrong-header:"s/^## Write-time doctrine/## Doctrine/" template-action:"s/^- Why: /- Why: {{ .X }} /"; do
  nm="${shape%%:*}"; sc="${shape#*:}"
  if [ "$nm" = missing ]; then src="$W/arms.does-not-exist"
  else mk_src "$nm" "$sc" || continue; src="$W/arms.$nm"; fi
  d="$(mkagents "src-$nm")"; edit "$d/thies-wa/prompt.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || { bad "source control '$nm': could not make a stale copy"; continue; }
  before="$(sums "$d")"
  gen "$d" "$src" check;  rc_check=$RC
  gen "$d" "$src" write;  rc_write=$RC
  if [ "$rc_check" = 2 ] && [ "$rc_write" = 2 ] && [ "$before" = "$(sums "$d")" ] && [ ! -s "$W/gen.out" ]; then
    ok "source '$nm': check and write both say CANNOT RENDER (rc 2); the prompts are untouched and nothing was written to stdout"
  else
    bad "source '$nm': check rc=$rc_check write rc=$rc_write prompts-untouched=$([ "$before" = "$(sums "$d")" ] && echo yes || echo NO)"
  fi
done

# 6. write regenerates stale copies, byte for byte, and check agrees afterwards; a second write changes nothing and leaves no temp file
d="$(mkagents fixme)"
edit "$d/digo-wa/prompt.template.md" "s/in last week's gate reviews/in the last weeks' gate reviews/" || bad "write control: the digo-wa edit changed nothing"
edit "$d/mila-wa/prompt.template.md" "s/32% of the findings/33% of the findings/" || bad "write control: the mila-wa edit changed nothing"
gen "$d" "$ARMS" write; rc_write=$RC
same=1; for c in $CREWS; do cmp -s "$d/$c-wa/prompt.template.md" "$AGENTS/$c-wa/prompt.template.md" || same=0; done
if [ "$rc_write" = 0 ] && [ "$same" = 1 ]; then ok "write on two drifted copies restores all six prompts to the committed ones, byte for byte"; else bad "write on drifted copies: rc=$rc_write, identical-to-committed=$same $ERR"; fi
gen "$d" "$ARMS" check
[ "$RC" = 0 ] && ok "check passes right after write" || bad "check after write: rc=$RC $ERR"
after1="$(sums "$d")"; gen "$d" "$ARMS" write
[ "$RC" = 0 ] && [ "$after1" = "$(sums "$d")" ] && ok "a second write is a no-op (rc 0, nothing changed)" || bad "a second write: rc=$RC, prompts changed=$([ "$after1" = "$(sums "$d")" ] && echo no || echo YES)"
leftovers=0; for f in "$d"/*/*.tmp.*; do [ -e "$f" ] && leftovers=$((leftovers+1)); done
[ "$leftovers" = 0 ] && ok "write leaves no temp file behind" || bad "write left $leftovers temp file(s) behind"
fi

echo
echo "== result: $PASS ok, $FAILN failure(s) =="
REACHED_END=1
[ "$FAILN" = 0 ]
