#!/usr/bin/env bash
# gate-hard-checks.sh — ga-vywjzsp: the measurement behind quality-gate-guard.sh Step 5b-pre5 (the gate's hard checks).
#
#   gate-hard-checks.sh <step> <rig-path> <base-sha> <tip-sha> <bead-id>      <step> = 2b | 2c | 2d | 2e
#
# WHY. formulas/mol-quality-gate-runner.toml (run-tests) holds four deterministic hard checks: 2b template parse,
# 2c doc-rules lint, 2d E12 coverage, 2e third-state reads. Nothing pours that formula: the live gate is guard ->
# dispatcher -> gate-reviewer sessions, and none of the six live gate files has ever named a step (633 versions read).
# A reviewer ran 2c by hand once because it happened to find the formula; the arms file stopped growing. This runs each
# check for every submission, from the guard (the one deterministic path every builder passes), one step per call.
#
# TRUST. The guard runs this with its own privileges and the branch may come from a sandboxed node, so nothing the
# branch supplies is EXECUTED: each tool is the copy already merged beside this script (HQ_DIR), run over the branch's
# files as DATA. A diff that edits the tool itself is not judged (ferramenta-alterada-no-diff): its own copy cannot
# vouch for it. Tree paths are data too: an entry with a "." / ".." / ".git" component, a symlink or a gitlink where
# a wanted file should be is refused before anything is written.
#
# OUTPUT. One line first, then (fail / debito-previo) the tool's red lines, capped at 40:
#   VERDICT=<token> step=<s> reason=<slug> rc=<n|-> tip=<green|red|unknown|-> base=<..|-> arm=<enforce|holdout|->
#   ok                  the tool ran and found nothing
#   fail                the tool printed a finding AND exited 1 (2b/2d also need the base tree to be green).
#                       The only verdict the guard refuses on
#   aviso               2e found reads with no failure test but its mode (warn, or the holdout arm) does not refuse
#   debito-previo       2b/2d: red on the tip and on the base: main already carried it
#   nao-se-aplica       the diff touches nothing this step reads (a MEASURED zero: the diff itself was read)
#   desligado           a kill switch is on (the tool's own, or E12_COVERAGE_GATE=off / .gc/e12-coverage-gate.off for 2d)
#   nao-ligado          2e only: .gc/third-state-reads.conf is absent or mode=off, so the tool checked nothing
#   nao-consegui-medir  anything that stopped a measurement (see the reason); the guard fails OPEN on it, loudly
# rc is the tool's exit code (124 = timeout, 126/127 = could not exec), so a host problem reads in the log at a glance.
# Always exits 0 after printing; a crash prints no VERDICT= line, which the guard reads as unmeasured.
#
# THIRD STATES. "Could not run" is never green and never red. A finding needs POSITIVE evidence in the tool's output
# (a crash also exits 1); everything else is unmeasured. A python without tomllib (< 3.11) cannot run 2d and would
# make the base tree red as well, so it is said (python-sem-tomllib), never read as debito-previo for good.
#
# ENV. GATE_HC_HQ = the directory holding the tools (default: three levels above this script); GATE_HC_TIMEOUT seconds
# per tool run (default 90; garbage is the default, never "no limit"); GATE_HC_PYTHONS = the pythons to try for tomllib.
# bash 3.2 (the macOS /bin/bash the guard runs under): no associative arrays, no mapfile; case patterns are
# parenthesised so they are safe inside $( ) too. No `set -e`: every step that can fail is handled where it happens.
set -u

HQ=".gascity-gastown-hq"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_DIR="${GATE_HC_HQ:-$(cd "$HERE/../../.." 2>/dev/null && pwd)}"
ASSETS_REL="$HQ/packs/town-deltas/assets"
TMO="${GATE_HC_TIMEOUT:-90}"
case "$TMO" in (''|*[!0-9]*) TMO=90 ;; esac
[ "$TMO" -ge 1 ] 2>/dev/null || TMO=90

STEP="${1-}"; SCRATCH=""; TOP=""; WANT=""; LIVE_MD=""; RC="-"; TIPC="-"; BASEC="-"; ARM="-"; DETAIL=""
PY=""; PY_TOML=0; TBIN=""
cleanup() { if [ -n "$SCRATCH" ]; then rm -rf "$SCRATCH" 2>/dev/null; fi; return 0; }
trap cleanup EXIT

emit() { # emit <verdict> <reason>: the one verdict line, then the detail; ends the run.
  printf 'VERDICT=%s step=%s reason=%s rc=%s tip=%s base=%s arm=%s\n' "$1" "$STEP" "$2" "$RC" "$TIPC" "$BASEC" "$ARM"
  if [ -n "$DETAIL" ]; then printf '%s\n' "$DETAIL"; fi
  exit 0
}
cap() { printf '%s\n' "$1" | awk 'NR <= 40 { print substr($0, 1, 200) }'; }

# want <path>: rc 0 when this step needs that tree entry (WANT picks the step's set).
want() {
  case "$WANT" in
    (md-all) case "$1" in (*.md) return 0 ;; esac ;;
    (md-changed) case "$1" in (*.md) case "$LIVE_MD" in (*$'\n'"$1"$'\n'*) return 0 ;; esac ;; esac ;;
    (e12) case "$1" in
            ($HQ/agents/*/prompt.template.md|$HQ/city.toml|$HQ/packs/town-deltas/template-fragments/town-deltas.template.md) return 0 ;;
          esac ;;
    (tmpl) case "$1" in
             (template-fragments/*|*/template-fragments/*|prompts/shared/*|*/prompts/shared/*|*.template.md|*.md.tmpl|pack.toml|*/pack.toml|$HQ/city.toml|$HQ/agents/*/agent.toml) return 0 ;;
           esac ;;
  esac
  return 1
}

# extract <sha> <dest>: writes every wanted entry of <sha> under <dest>, same relative layout. rc 0 = all written (an
# empty set is legitimate); rc 1 = could not (listing failed, or any wanted entry is unsafe or unreadable): a partial
# tree is not a tree. Blobs are read by object id, so no path is ever resolved against the repository.
extract() {
  local sha="$1" dest="$2" rec="" meta="" path="" mode="" obj="" listf="$SCRATCH/ls.$RANDOM$RANDOM"
  # vazio → nenhuma entrada querida nessa árvore (o chamador roda a ferramenta sobre o que há); falhou/ilegível → return 1 = nao-consegui-medir
  git -C "$TOP" ls-tree -r -z "$sha" > "$listf" 2>/dev/null || return 1
  mkdir -p "$dest" 2>/dev/null || return 1
  while IFS= read -r -d '' rec; do
    meta=${rec%%$'\t'*}; path=${rec#*$'\t'}
    want "$path" || continue
    # A path is data from the branch (git mktree builds "." / ".." / ".git" entries): refuse, never skip and go on.
    case "/$path/" in (*/./*|*/../*|*/.git/*|*//*) return 1 ;; esac
    mode=${meta%% *}; obj=${meta##* }
    case "$mode" in (100644|100755) ;; (*) return 1 ;; esac
    mkdir -p "$dest/$(dirname "$path")" 2>/dev/null || return 1
    git -C "$TOP" cat-file blob "$obj" > "$dest/$path" 2>/dev/null || return 1
  done < "$listf"
  return 0
}

# tool_altered <repo-relative path>...: rc 0 when the diff edits any of them (then that step is not judged).
tool_altered() { local p=""; for p in "$@"; do if grep -F -x -q -- "$p" "$SCRATCH/all.nl" 2>/dev/null; then return 0; fi; done; return 1; }

pick_tools() { # PY = first python3 with tomllib (PY_TOML=1), else the PATH one; TBIN = GNU timeout
  local c=""
  for c in ${GATE_HC_PYTHONS:-python3 /opt/homebrew/bin/python3 /usr/local/bin/python3}; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -I -c 'import tomllib' >/dev/null 2>&1; then PY="$(command -v "$c")"; PY_TOML=1; break; fi
  done
  if [ -z "$PY" ]; then PY="$(command -v python3 2>/dev/null)" || PY=""; fi
  TBIN="$(command -v timeout 2>/dev/null)" || TBIN="$(command -v gtimeout 2>/dev/null)" || TBIN=""
  return 0
}

step_2c() {
  local tool="$HQ_DIR/scripts/doc-rules-lint.py" out="" gd=""
  [ -r "$tool" ] || emit nao-consegui-medir ferramenta-ilegivel
  tool_altered "$HQ/scripts/doc-rules-lint.py" && emit nao-consegui-medir ferramenta-alterada-no-diff
  # A named doc (CLAUDE.md, AGENTS.md) counts its @imports: only then does the lint need every .md, not just the changed ones.
  WANT=md-changed; LIVE_MD=$'\n'"$(grep '\.md$' "$SCRATCH/live.nl")"$'\n'
  if grep -E -q '(^|/)(CLAUDE|CLAUDE\.local|AGENTS)\.md$' "$SCRATCH/live.nl"; then WANT=md-all; fi
  extract "$tip" "$SCRATCH/tip" || emit nao-consegui-medir extracao-tip
  # vazio/falhou → sem git-dir não há diff nem ref do upstream: nao-consegui-medir, nunca "sem violação"
  gd="$(git -C "$TOP" rev-parse --absolute-git-dir 2>/dev/null)" || gd=""
  [ -n "$gd" ] || emit nao-consegui-medir sem-git-dir
  # GIT_DIR gives the lint the real objects (the diff) and refs (upstream/main); the CONTENT it reads is the extracted tip.
  # GIT_WORK_TREE makes `rev-parse --show-toplevel` answer the tip root from any subdirectory (else a file under docs/ looks
  # like it lives at the root of its folder and the upstream skip silently never matches).
  out="$(cd "$SCRATCH/tip" && env "GIT_DIR=$gd" "GIT_WORK_TREE=$SCRATCH/tip" "GC_CITY_PATH=$HQ_DIR" "$TBIN" "$TMO" "$PY" -I "$tool" --check --root "$SCRATCH/tip" --diff "${base}...${tip}" 2>&1)"; RC=$?
  # vazio → saída sem linha de resumo = a ferramenta não terminou de reportar: nao-consegui-medir; falhou (rc 2/124/127) → idem
  # The tool echoes branch text (a heading, a file name) in its violation lines, so its kill-switch line is believed only on a
  # CLEAN exit, whole line at the start: a branch that writes "DISABLED via" in a title must not turn a refusal into desligado.
  case "$RC" in
    (0) if printf '%s\n' "$out" | grep -E -q '^doc-rules-lint: DISABLED via '; then emit desligado interruptor; fi
        emit ok lint-limpo ;;
    (1) if printf '%s\n' "$out" | grep -E -q '^doc-rules-lint: [0-9]+ file\(s\) checked, [1-9][0-9]* violation\(s\)'; then DETAIL="$(cap "$out")"; emit fail violacoes-doc-rules; fi
        emit nao-consegui-medir saida-sem-resumo ;;
    (*) emit nao-consegui-medir "lint-rc$RC" ;;
  esac
}

step_2e() {
  local tool="$HQ_DIR/packs/town-deltas/assets/third-state-reads-check.py" out="" line="" v=""
  [ -r "$tool" ] || emit nao-consegui-medir ferramenta-ilegivel
  tool_altered "$ASSETS_REL/third-state-reads-check.py" && emit nao-consegui-medir ferramenta-alterada-no-diff
  case "$bead" in (''|*[!A-Za-z0-9._-]*) emit nao-consegui-medir bead-invalido ;; esac
  # The tool draws the bead's arm and records it in <city>/.gc/third-state-reads-arms.jsonl (first draw wins), only when
  # .gc/third-state-reads.conf is on: that row is the proof this step ran on a real submission.
  out="$(env "GC_CITY_PATH=$HQ_DIR" "$TBIN" "$TMO" "$PY" -I "$tool" --repo "$TOP" --base "$base" --head "$tip" --city "$HQ_DIR" "--bead=$bead" 2>&1)"; RC=$?
  line="$(printf '%s\n' "$out" | grep -E '^third-state-reads-check: verdict=' | tail -n 1)"
  # vazio → sem linha de veredito: ligado-mas-mudo é nao-consegui-medir, nunca ok; "nothing checked" é a ferramenta dizendo que está desligada
  if [ -n "$line" ]; then
    v="${line#*verdict=}"; v="${v%% *}"; ARM="${line#*arm=}"; ARM="${ARM%% *}"
  elif [ "$RC" -eq 0 ]; then
    # Whole lines at the start only (the finding lines echo branch text, indented): see step_2c.
    if printf '%s\n' "$out" | grep -E -q '^NOTE: third-state-reads-check: not switched on \('; then emit nao-ligado conf-ausente; fi
    if printf '%s\n' "$out" | grep -E -q '^NOTE: third-state-reads-check: mode=off in '; then emit nao-ligado mode-off; fi
    if printf '%s\n' "$out" | grep -E -q '^NOTE: third-state-reads-check: is switched OFF \('; then emit desligado interruptor; fi
  fi
  case "$RC:$v" in
    (0:ok) emit ok leituras-com-teste ;;
    (0:reads-without-test) DETAIL="$(cap "$out")"; emit aviso leitura-sem-teste-sem-recusa ;;
    (1:reads-without-test) DETAIL="$(cap "$out")"; emit fail leitura-sem-teste ;;
    (0:nao-sei|1:nao-sei) DETAIL="$(cap "$out")"; emit nao-consegui-medir ferramenta-nao-sei ;;
    (0:*|1:*) emit nao-consegui-medir saida-ilegivel ;;
    (*) emit nao-consegui-medir "ferramenta-rc$RC" ;;
  esac
}

# run_e12 <tree> <outfile>: check + coverage of the E12 generator (the city's copy) over <tree>'s prompts, fragment and
# city.toml; prints "<class> <rc>" (green | red | unknown). Red needs a STALE / BROKEN MARKERS / GAP line AND rc 1.
run_e12() {
  local t="$1" out="$2" c="" r=0 worst=0 hq="$1/$HQ"
  : > "$out"
  for c in check coverage; do
    r=0
    env "PATH=$(dirname "$PY"):$PATH" "E12_ARMS=$HQ_DIR/packs/town-deltas/assets/e12-arms.sh" "E12_CREW_AGENTS_DIR=$hq/agents" \
      "E12_FRAGMENT=$hq/packs/town-deltas/template-fragments/town-deltas.template.md" "E12_CITY_TOML=$hq/city.toml" \
      "$TBIN" "$TMO" bash "$HQ_DIR/packs/town-deltas/assets/e12-crew-doctrine.sh" "$c" >> "$out" 2>&1 || r=$?
    [ "$r" -gt "$worst" ] && worst=$r
  done
  if [ "$worst" -eq 0 ]; then printf 'green %s' "$worst"
  elif [ "$worst" -eq 1 ] && grep -E -q '^e12-crew-doctrine: (STALE|BROKEN MARKERS|GAP) — ' "$out"; then printf 'red %s' "$worst"
  else printf 'unknown %s' "$worst"; fi
}

step_2d() {
  local cr="" cls="" bcr=""
  if [ "${E12_COVERAGE_GATE:-}" = "off" ] || [ -f "$HQ_DIR/.gc/e12-coverage-gate.off" ]; then emit desligado interruptor; fi
  [ -r "$HQ_DIR/packs/town-deltas/assets/e12-crew-doctrine.sh" ] && [ -r "$HQ_DIR/packs/town-deltas/assets/e12-arms.sh" ] || emit nao-consegui-medir ferramenta-ilegivel
  # The generator SOURCES e12-arms.sh: the branch's copy would be branch code, so an edit to either file is not judged.
  tool_altered "$ASSETS_REL/e12-crew-doctrine.sh" "$ASSETS_REL/e12-arms.sh" && emit nao-consegui-medir ferramenta-alterada-no-diff
  [ "$PY_TOML" -eq 1 ] || emit nao-consegui-medir python-sem-tomllib
  WANT=e12
  extract "$tip" "$SCRATCH/tip" || emit nao-consegui-medir extracao-tip
  cr="$(run_e12 "$SCRATCH/tip" "$SCRATCH/tip.out")"; cls="${cr%% *}"; TIPC="$cls"; RC="${cr##* }"
  case "$cls" in (green) emit ok e12-verde-no-tip ;; (red) ;; (*) emit nao-consegui-medir e12-inconclusivo-tip ;; esac
  DETAIL="$(cap "$(cat "$SCRATCH/tip.out")")"
  # Red on the tip: was it this diff? The base answers (a repair or a debt main already carried shows up here).
  extract "$base" "$SCRATCH/base" || { DETAIL=""; emit nao-consegui-medir extracao-base; }
  bcr="$(run_e12 "$SCRATCH/base" "$SCRATCH/base.out")"; BASEC="${bcr%% *}"
  case "$BASEC" in
    (green) emit fail e12-vermelho-no-tip-e-verde-na-base ;;
    (red) emit debito-previo e12-vermelho-na-base-tambem ;;
    (*) DETAIL=""; emit nao-consegui-medir e12-inconclusivo-base ;;
  esac
}

# run_tmpl <tree> <outfile> <list>: the template-fragment parse guard (the city's copy) over <tree> for the template
# files named in <list>; prints "<class> <rc>". Red needs the guard's own "FAIL --" line AND rc 1.
run_tmpl() {
  local t="$1" out="$2" list="$3" r=0 f=""
  set --
  while IFS= read -r f; do set -- "$@" "$f"; done < "$list"
  env "PATH=$(dirname "$PY"):$PATH" "$TBIN" "$TMO" bash "$HQ_DIR/packs/town-deltas/assets/template-fragment-lint-guard.sh" "$t" "$@" > "$out" 2>&1 || r=$?
  if [ "$r" -eq 0 ]; then printf 'green %s' "$r"
  elif [ "$r" -eq 1 ] && grep -q '^template-fragment-lint-guard: FAIL' "$out"; then printf 'red %s' "$r"
  else printf 'unknown %s' "$r"; fi
}

step_2b() {
  local cr="" cls="" bcr=""
  [ -r "$HQ_DIR/packs/town-deltas/assets/template-fragment-lint-guard.sh" ] || emit nao-consegui-medir ferramenta-ilegivel
  tool_altered "$ASSETS_REL/template-fragment-lint-guard.sh" && emit nao-consegui-medir ferramenta-alterada-no-diff
  # The guard exits 0 with only a WARNING when gc is absent, and fails on every report when jq is: neither may read as a verdict.
  command -v gc >/dev/null 2>&1 || emit nao-consegui-medir sem-gc
  command -v jq >/dev/null 2>&1 || emit nao-consegui-medir sem-jq
  WANT=tmpl
  extract "$tip" "$SCRATCH/tip" || emit nao-consegui-medir extracao-tip
  cr="$(run_tmpl "$SCRATCH/tip" "$SCRATCH/tip.out" "$SCRATCH/hits.nl")"; cls="${cr%% *}"; TIPC="$cls"; RC="${cr##* }"
  case "$cls" in (green) emit ok parse-verde-no-tip ;; (red) ;; (*) emit nao-consegui-medir parse-inconclusivo-tip ;; esac
  DETAIL="$(cap "$(cat "$SCRATCH/tip.out")")"
  # Positive control: a plain pack must lint green here. If it does not (gc cannot lint at all, jq breaks the report) every
  # tree reads red, and "red on the base too" would be debito-previo for good: said out loud instead.
  mkdir -p "$SCRATCH/ctl/agents/ctl" || { DETAIL=""; emit nao-consegui-medir sem-controle; }
  printf '[pack]\nname = "ctl"\nschema = 2\n' > "$SCRATCH/ctl/pack.toml"
  printf 'plain text.\n' > "$SCRATCH/ctl/agents/ctl/prompt.template.md"
  printf 'agents/ctl/prompt.template.md\n' > "$SCRATCH/ctl.nl"
  cr="$(run_tmpl "$SCRATCH/ctl" "$SCRATCH/ctl.out" "$SCRATCH/ctl.nl")"
  case "${cr%% *}" in (green) ;; (*) DETAIL="$(cap "$(cat "$SCRATCH/ctl.out")")"; emit nao-consegui-medir gc-lint-controle-vermelho ;; esac
  extract "$base" "$SCRATCH/base" || { DETAIL=""; emit nao-consegui-medir extracao-base; }
  bcr="$(run_tmpl "$SCRATCH/base" "$SCRATCH/base.out" "$SCRATCH/hits.nl")"; BASEC="${bcr%% *}"
  case "$BASEC" in
    (green) emit fail parse-vermelho-no-tip-e-verde-na-base ;;
    (red) emit debito-previo parse-vermelho-na-base-tambem ;;
    (*) DETAIL=""; emit nao-consegui-medir parse-inconclusivo-base ;;
  esac
}

main() {
  rig="${2-}"; base="${3-}"; tip="${4-}"; bead="${5-}"
  case "$STEP" in (2b|2c|2d|2e) ;; (*) emit nao-consegui-medir passo-invalido ;; esac
  if [ -z "$rig" ] || [ -z "$base" ] || [ -z "$tip" ]; then emit nao-consegui-medir entrada-vazia; fi
  # The shas go into `git diff <base>..<tip>`: anything that is not hex (--output=FILE would be read as an option) is refused.
  case "$base$tip" in (*[!0-9a-fA-F]*) emit nao-consegui-medir entrada-invalida ;; esac
  # vazio/falhou → rig que não é repositório git (ou git ausente): nao-consegui-medir, nunca "nada a medir"
  TOP="$(git -C "$rig" rev-parse --show-toplevel 2>/dev/null)" || TOP=""
  if [ -z "$TOP" ] || [ ! -d "$TOP" ]; then emit nao-consegui-medir sem-toplevel; fi
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ghc.XXXXXX" 2>/dev/null)" || SCRATCH=""
  if [ -z "$SCRATCH" ]; then emit nao-consegui-medir sem-scratch; fi
  # vazio → o diff foi lido e está vazio = zero MEDIDO (nao-se-aplica); falhou (sha desconhecido, objeto ausente) → diff-falhou, nunca zero
  git -C "$TOP" diff -z --name-only --no-renames "${base}..${tip}" > "$SCRATCH/all" 2>/dev/null || emit nao-consegui-medir diff-falhou
  git -C "$TOP" diff -z --name-only --no-renames --diff-filter=ACMR "${base}..${tip}" > "$SCRATCH/live" 2>/dev/null || emit nao-consegui-medir diff-falhou
  tr '\0' '\n' < "$SCRATCH/all" > "$SCRATCH/all.nl"; tr '\0' '\n' < "$SCRATCH/live" > "$SCRATCH/live.nl"
  case "$STEP" in
    (2b) grep -E '(^|/)template-fragments/|(^|/)prompts/shared/|\.template\.md$|\.md\.tmpl$|(^|/)pack\.toml$' "$SCRATCH/all.nl" > "$SCRATCH/hits.nl" ;;
    (2c) grep '\.md$' "$SCRATCH/live.nl" > "$SCRATCH/hits.nl" ;;
    (2d) grep -E "^[.]gascity-gastown-hq/(agents/[^/]+/prompt[.]template[.]md|city[.]toml|packs/town-deltas/(template-fragments/town-deltas[.]template[.]md|assets/(e12-arms[.]sh|e12-crew-doctrine[.]sh|claude-overlays/pool-roles[.]json)))\$" "$SCRATCH/all.nl" > "$SCRATCH/hits.nl" ;;
    (2e) cp "$SCRATCH/all.nl" "$SCRATCH/hits.nl" ;;
  esac
  if [ ! -s "$SCRATCH/hits.nl" ]; then emit nao-se-aplica diff-sem-entradas-do-passo; fi
  pick_tools
  if [ -z "$PY" ]; then emit nao-consegui-medir sem-python; fi
  if [ -z "$TBIN" ]; then emit nao-consegui-medir sem-timeout; fi
  "step_$STEP"
}

main "$@"
