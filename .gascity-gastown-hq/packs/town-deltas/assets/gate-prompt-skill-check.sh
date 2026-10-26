#!/usr/bin/env bash
# gate-prompt-skill-check.sh — ga-gqtg1fs: the measurement behind quality-gate-guard.sh Step 5b-pre4.
#
#   gate-prompt-skill-check.sh <rig-path> <base-sha> <tip-sha>
#
# WHY. A skill token ("/" + the name of a real skill) in a pool worker's boot prompt makes Claude Code attach a
# skill_mention at boot: the fresh worker runs that skill with no bead and idles on a pool slot (ga-7nxfa1).
# pool-prompt-skill-mention.selftest.sh is the detector, but NOTHING ran it when a prompt changed: the gate's reviewers
# run "the test files the diff changed" and a prompt is not a test file, so 3eea2c223 (ga-eei1o4) landed red on 24/10
# and nobody saw it until the Mayor ran the selftest by hand on 26/10.
#
# WHAT. When <base>..<tip> touches an INPUT of that detector (a prompt, city.toml, a template fragment, a skill or
# command name, the detector itself) this runs the detector of the TIP tree on the TIP tree, and, only if that is red,
# the detector of the BASE tree on the BASE tree, to tell what the diff broke from what main already carried (the
# gate's own rule: "a failing test blocks only when this diff made it fail"). A diff that touches no input costs one
# `git diff` and runs nothing.
#
# OUTPUT. Exactly one verdict line first, then (fail / debito-previo only) the detector's red lines, capped:
#   VERDICT=<token> reason=<slug> hits=<n> tip=<green|red|unknown|-> base=<green|red|unknown|->
#   sem-prompt-alterado  no input in the diff: nothing was run (a MEASURED zero: the diff itself was read)
#   ok                   tip green (a repair of a red main lands here too)
#   fail                 tip red AND base green: this diff broke it. The only verdict the guard refuses on
#   debito-previo        tip red AND base red: main already carried it; recorded, never refused
#   nao-consegui-medir   anything that stopped a measurement (see the reason); the guard fails OPEN on it, loudly
# Always exits 0: the verdict is the answer, and the guard reads it from stdout.
#
# THIRD STATES. "Could not run" is never "green" and never "red": a detector that crashed, hung, printed no summary line
# or whose summary contradicts its exit code is `unknown`. The class is taken from what the detector REPORTED (its last
# line "pool-prompt-skill-mention selftest: N passed, M failed") AND its exit code agreeing: green = M 0 and rc 0,
# red = M > 0 and rc 1, everything else unknown. (rc 1 alone is not red: a `set -u` crash exits 1 too.)
#
# ENV. GATE_PSC_TIMEOUT seconds per detector run (default 60; a garbage value is the default, never "no limit").
# The detector runs with a scrubbed environment (PATH, HOME, TMPDIR inside the scratch tree, the locale vars): it is
# branch-supplied code run by the guard, like the ga-rstae base test, so it gets no tokens.
#
# bash 3.2 (the macOS /bin/bash the guard's launchd job runs under): no arrays, no mapfile, no ${v,,}; case patterns are
# parenthesised so they are safe inside $( ) too. No `set -e`: every step that can fail is handled where it happens.
set -u

HQ=".gascity-gastown-hq"
SELFTEST_REL="$HQ/packs/town-deltas/assets/pool-prompt-skill-mention.selftest.sh"
TMO="${GATE_PSC_TIMEOUT:-60}"
case "$TMO" in (''|*[!0-9]*) TMO=60 ;; esac
[ "$TMO" -ge 1 ] 2>/dev/null || TMO=60

SCRATCH=""
TOP=""
HITS="-"
DETAIL=""
cleanup() { if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH" 2>/dev/null; fi; return 0; }
trap cleanup EXIT

# emit <verdict> <reason> [tip-class] [base-class]: the one verdict line, then any detail; ends the run.
emit() {
  printf 'VERDICT=%s reason=%s hits=%s tip=%s base=%s\n' "$1" "$2" "$HITS" "${3:--}" "${4:--}"
  if [ -n "$DETAIL" ]; then printf '%s\n' "$DETAIL"; fi
  exit 0
}

# is_input <root-relative path>: rc 0 if a change to that path can change what the detector says. Exactly what the
# detector reads (its section B names, C templates, C2 city.toml + fragments) plus the detector itself.
is_input() {
  case "$1" in
    ($HQ/agents/*/prompt.template.md) return 0 ;;
    ($HQ/city.toml) return 0 ;;
    ($HQ/skills/*/SKILL.md) return 0 ;;
    ($HQ/commands/*.md) return 0 ;;
    ($HQ/packs/*/template-fragments/*.template.md) return 0 ;;
    ($SELFTEST_REL) return 0 ;;
    (.claude/commands/*.md) return 0 ;;
    (.claude/skills/*/SKILL.md) return 0 ;;
  esac
  return 1
}

# extract_tree <sha> <dest>: writes every input entry of <sha> under <dest>, same relative layout, so the detector finds
# its own tree by its own location. rc 0 = all written (an empty list is legitimate: the caller then finds no detector);
# rc 1 = could not (the listing failed, or any single entry could not be read: a partial tree is not a tree).
extract_tree() {
  local sha="$1" dest="$2" listf="" f=""
  listf="$SCRATCH/list.$RANDOM$RANDOM"
  # vazio → nenhuma entrada de detector nessa árvore; o chamador responde "selftest ausente" (não "ok"); falhou/ilegível → return 1 = nao-consegui-medir
  git -C "$TOP" ls-tree -r -z --name-only "$sha" -- "$HQ" .claude > "$listf" 2>/dev/null || return 1
  mkdir -p "$dest" 2>/dev/null || return 1
  while IFS= read -r -d '' f; do
    is_input "$f" || continue
    mkdir -p "$dest/$(dirname "$f")" 2>/dev/null || return 1
    # falhou/ilegível (gitlink, objeto ausente) → return 1; nunca segue com a árvore pela metade
    git -C "$TOP" show "$sha:$f" > "$dest/$f" 2>/dev/null || return 1
  done < "$listf"
  return 0
}

# run_detector <tree> <outfile>: prints green | red | unknown | ausente (the detector is not in that tree).
run_detector() {
  local tree="$1" out="$2" rc=0 line="" nfail=""
  if [ ! -f "$tree/$SELFTEST_REL" ]; then printf 'ausente'; return 0; fi
  mkdir -p "$tree/.tmp" 2>/dev/null || { printf 'unknown'; return 0; }
  ( cd "$tree" && timeout "$TMO" env -i PATH="$PATH" HOME="${HOME:-/}" TMPDIR="$tree/.tmp" ${LANG:+"LANG=$LANG"} ${LC_ALL:+"LC_ALL=$LC_ALL"} ${LC_CTYPE:+"LC_CTYPE=$LC_CTYPE"} bash "$SELFTEST_REL" ) > "$out" 2>&1 || rc=$?
  # vazio → sem linha de resumo = o detector não terminou de reportar (caiu, travou, timeout 124, 126/127): unknown; falhou/ilegível → idem
  line=$(grep -E '^pool-prompt-skill-mention selftest: [0-9]+ passed, [0-9]+ failed$' "$out" 2>/dev/null | tail -n 1)
  if [ -z "$line" ]; then printf 'unknown'; return 0; fi
  nfail=${line##*passed, }; nfail=${nfail%% failed*}
  case "$nfail" in (''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ "$nfail" -eq 0 ] && [ "$rc" -eq 0 ]; then printf 'green'
  elif [ "$nfail" -gt 0 ] && [ "$rc" -eq 1 ]; then printf 'red'
  else printf 'unknown'; fi
  return 0
}

# red_lines <detector output>: the failed assertions and the offending text under them, capped for a bead comment.
red_lines() {
  awk '/^  ✗/ { p = 1; print; next } /^      / { if (p) print; next } { p = 0 }' "$1" 2>/dev/null | cut -c1-200 | head -n 40
}

main() {
  local rig="${1-}" base="${2-}" tip="${3-}" f="" cls="" bcls=""
  if [ -z "$rig" ] || [ -z "$base" ] || [ -z "$tip" ]; then emit nao-consegui-medir entrada-vazia; fi
  # vazio/falhou → rig que não é repositório git (ou git ausente): nao-consegui-medir, nunca "sem prompt alterado"
  TOP=$(git -C "$rig" rev-parse --show-toplevel 2>/dev/null) || TOP=""
  if [ -z "$TOP" ] || [ ! -d "$TOP" ]; then emit nao-consegui-medir sem-toplevel; fi
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/psc.XXXXXX" 2>/dev/null) || SCRATCH=""
  if [ -z "$SCRATCH" ]; then emit nao-consegui-medir sem-scratch; fi

  # vazio → o diff foi lido e não tem nenhuma entrada do detector = zero MEDIDO (sem-prompt-alterado); falhou (sha desconhecido, objeto ausente) → diff-falhou, nunca zero
  git -C "$TOP" diff -z --name-only --no-renames "${base}..${tip}" -- "$HQ" .claude > "$SCRATCH/diff" 2>/dev/null || emit nao-consegui-medir diff-falhou
  HITS=0
  while IFS= read -r -d '' f; do
    if is_input "$f"; then HITS=$((HITS + 1)); fi
  done < "$SCRATCH/diff"
  if [ "$HITS" -eq 0 ]; then emit sem-prompt-alterado diff-sem-entradas-do-detector; fi

  extract_tree "$tip" "$SCRATCH/tip" || emit nao-consegui-medir extracao-tip
  cls=$(run_detector "$SCRATCH/tip" "$SCRATCH/tip.out")
  case "$cls" in
    (green) emit ok detector-verde-no-tip green ;;
    (ausente) emit nao-consegui-medir selftest-ausente-no-tip ;;
    (red) : ;;
    (*) emit nao-consegui-medir selftest-inconclusivo-tip unknown ;;
  esac

  # tip is red: was it this diff? The base answers (a repair or a latent break shows up here as green/red).
  extract_tree "$base" "$SCRATCH/base" || emit nao-consegui-medir extracao-base red
  bcls=$(run_detector "$SCRATCH/base" "$SCRATCH/base.out")
  DETAIL=$(red_lines "$SCRATCH/tip.out")
  case "$bcls" in
    (green) emit fail detector-vermelho-no-tip-e-verde-na-base red green ;;
    (red) emit debito-previo vermelho-na-base-tambem red red ;;
    (ausente) DETAIL=""; emit nao-consegui-medir selftest-ausente-na-base red ;;
    (*) DETAIL=""; emit nao-consegui-medir selftest-inconclusivo-base red unknown ;;
  esac
}

main "$@"
