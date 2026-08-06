#!/usr/bin/env bash
# error-empty-conflation-scan.sh — finds the "ERROR and EMPTY produce the same
# value" bug class (ga-p5q3): a FAILED query/command collapses to the same
# signal a genuinely-empty result would produce, so any caller that branches
# on emptiness cannot tell "the question failed" from "there is nothing
# there" — the root cause behind 5 real incidents in one night (20h of lost
# work, a UI ship that would have shown zero data in silence, and a gate-
# recovery fix that itself carried the identical bug).
#
# REPORT-ONLY: finds and prints/notifies. Never modifies a scanned file.
#
# Three categories (see ga-p5q3 for the full incident writeup):
#   C1  swallowed/empty error handling: JS/TS `catch (e) {}`, Python bare
#       `except: pass`, or a shell query-command assignment whose failure is
#       masked via `|| true` (no distinguishable signal survives at all).
#   C2  (PRIORITY — the only one that destroys data) a shell query result
#       (bd/dolt/jq/grep/git/gh/curl/sqlite3/mysql/aws) whose emptiness drives
#       a decision without distinguishing "command failed" from "command
#       succeeded with zero rows": `VAR=$(query-cmd ...) ... || echo <empty>`.
#   C3  a launchd job whose target script never calls a notification path —
#       silence is not success.
#
# Calibrated against real precedent already in this codebase:
#   verdict_count_from_query()  — quality-gate-guard.sh, ga-jfo7
#   prune_decision()            — gate-needs-human-divergence-sweep.sh,
#                                  ga-u4yi gate-feedback attempt 1
# Both fix this exact idiom by capturing rc explicitly
# (`if ! VAR=$(cmd); then ...`) instead of masking it behind `|| echo`/`|| true`.
# That fixed shape contains neither `|| echo` nor `|| true`, so it does not
# match this scanner's suffix checks — confirmed by the selftest's "good"
# fixtures.
#
# Deliberate style note: this scanner avoids `\b` and `\s` in its own regexes
# — BSD grep (what `/usr/bin/grep` is on this city's macOS hosts) does not
# reliably support those PCRE escapes, which is exactly instance #1 of the
# ga-p5q3 incident (a macOS awk pattern using `\b`/`\s` silently matched
# nothing). Only `[[:space:]]` and explicit character classes are used here.
# A second, related lesson learned while BUILDING this scanner — bash 3.2's
# `[[ =~ ]]` (not just awk) can silently mismatch too — is documented at
# scan_js_empty_catch below. All pattern matching here now goes through the
# external `grep -E` binary instead of bash's built-in regex engine.
#
# Known limitations (honest, not hidden — this is a heuristic grep-class
# scanner, not a parser):
#   - Shell detectors operate on single logical lines; a command substitution
#     split across a backslash continuation is not tracked.
#   - JS/Python empty-block detectors handle the single-line and simple
#     immediate-next-line shapes; they do not track nested brace/indent depth.
#   - C3 flags a launchd job's script only when it contains NO notification
#     call anywhere; it does not verify the call is actually gated on the
#     failure branch (that needs control-flow analysis out of scope here).
#   - This tool does not cover the ga-p5q3 instance #1 shape (awk portability
#     escapes) — that is a different bug family (portability, not error/empty
#     conflation) and is intentionally out of this scan's 3-category scope.
#   - C1 `except: pass` findings need case-by-case triage, not blanket
#     fixing — not every swallow is load-bearing (ga-g2eg). Example benign:
#     gate-recovery-watchdog.py:587 swallows a log-file f.seek() optimization
#     failure — the fallback is just re-reading the whole file. Example real:
#     gate-health-monitor.py:175 swallows the failure of the monitor's OWN
#     notify call — the alarm silently stops ringing. This tool is REPORT-
#     ONLY by design (see file header); the reader decides per finding.
#
# Usage:
#   error-empty-conflation-scan.sh [--path DIR] [--quiet]
#     --path DIR   scan this directory instead of the default framework roots
#     --quiet      suppress the `notify` call even when findings > 0
#
# Exit code: 0 on a completed scan (findings are reported, never enforced);
# 1 only on an internal error (e.g. a requested --path does not exist).

set -uo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"

# Query-tool token allowed inside a `VAR=$( ... )` assignment for the shell
# detector. Boundary-safe via explicit non-identifier character classes —
# never `\b` (see style note above).
#
# ga-l4nx1: gc was missing — the tool this whole scanner exists to cover (ga-p5q3's
# own motivating incident, "gc <cmd> --json prints an error envelope on failure",
# ga-07509) was invisible to it. Verified: none of ga-07509's 16 real call sites
# would have been caught before this line added `gc`.
QUERY_TOOL_RE='([^A-Za-z0-9_]|^)(bd|gc|dolt|jq|grep|git|gh|curl|sqlite3|mysql|aws)([^A-Za-z0-9_]|$)'

# ── C2 (priority) + C1-shell: query-command assignment whose failure is ────
# masked by an empty-looking fallback (C2) or by an unconditional `|| true`
# (C1) instead of an explicit `if ! VAR=$(cmd); then ...` rc capture.
scan_shell_query_masking() {
  local file="$1" lineno=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      *'=$('*) ;;
      *) continue ;;
    esac
    printf '%s' "$line" | grep -Eq "$QUERY_TOOL_RE" || continue
    case "$line" in
      # ga-l4nx1: gc_json_or_unknown() (ga-07509's own fix) already captures the
      # real exit code AND validates the JSON envelope's `ok` field before ever
      # returning — a trailing `|| true` here is the documented memoized-cache-
      # with-retry idiom (see the helper's own doc comment: "CACHE=$(gc_json_or_
      # unknown gc ...) || true; [ -z "$CACHE" ] unambiguously means failed"), not
      # the raw-gc-call masking this scanner exists to catch. Adding gc to
      # QUERY_TOOL_RE above would otherwise flag ga-07509's own fix at every one
      # of its ~16 real call sites across pilot-dispatcher.sh / quality-gate-
      # dispatcher.sh / quality-gate-guard.sh / auto-refino-dispatcher.sh — the
      # exact "flags everything" failure this scanner's own header warns is as
      # useless as flagging nothing. Matches both real call shapes: bare
      # (`VAR=$(gc_json_or_unknown gc ...)`) and env-prefixed
      # (`VAR=$(GC_CITY="$GC_CITY" gc_json_or_unknown timeout 15 gc ...)`).
      *'=$('*'gc_json_or_unknown '*) ;;
      *'|| echo "[]"'* | *"|| echo '[]'"* | *'|| echo ""'* | *"|| echo ''"* | \
        *'|| echo "0"'* | *'|| echo "null"'* | *'|| echo "{}"'* | *"|| echo '{}'"*)
        echo "${file}:${lineno}:C2:${line}"
        ;;
      *'|| true'*)
        echo "${file}:${lineno}:C1:${line}"
        ;;
      # ga-vkjs: o idioma que faltava, e é o MAIS COMUM na city — a query é
      # canalizada pra um PARSER que fabrica um default, então não há `||` nenhum
      # pros case-suffixes acima casarem. Perigoso porque o parser ZERA o rc do
      # pipe (o rc de um pipeline é o do ÚLTIMO comando): erro-de-query e
      # campo-genuinamente-ausente saem com o MESMO valor E o MESMO rc=0.
      # PROVADO (não hipótese):
      #   bd -C /nao/existe show x --json 2>/dev/null | jq -r '.a // ""'  ->  '' rc=0
      #   echo '{}'                                   | jq -r '.a // ""'  ->  '' rc=0
      # Instâncias reais: o gc sling (ga-66wc, "não roteado" era a query falhando)
      # e a checagem do mila-wa que leu "o worker não despachou".
      # ⚠️ A FONTE DO PIPE TEM QUE PODER FALHAR. `VAR=$(echo "$row" | jq -r '.a // ""')`
      # NÃO é este bug: `echo` de uma variável não falha, então não existe o estado
      # "a pergunta falhou" — só existe "o campo não está lá", que é um fato legítimo.
      # Medido: sem esta exclusão, 48 dos 54 achados novos eram esse shape (89% ruído).
      # ⚠️ O ESCOPO É A SUBSTITUIÇÃO, NÃO A LINHA — e é por isso que isto virou função.
      # A v1 testava a linha INTEIRA num `case`, que casa o primeiro padrão e PARA. Numa
      # linha com duas substituições —  `x=$(echo a); y=$(cmd 2>/dev/null | jq -r '.a // ""')` —
      # a inerte casava primeiro e a ARRISCADA nunca era flagrada. Multi-statement na mesma
      # linha é estilo corrente aqui (este diff mesmo: `notify_mode=0; seed_mode=0`), então
      # não é canto raro. Achado pelo revisor do gate (run ga-wisp-3ip2my).
      *) _c2_scan_substitutions "$file" "$lineno" "$line" ;;
    esac
  done < "$file"
}

# ── C2: classifica CADA `VAR=$(...)` da linha, isoladamente ─────────────────
# Existe porque o `case` sobre a linha inteira casa o primeiro padrão e para: numa linha
# com uma substituição inerte E uma arriscada, a inerte vencia e a arriscada sumia
# (revisor do gate, run ga-wisp-3ip2my). Aqui cada substituição é julgada sozinha.
#
# ⚠️ O FIM DO FRAGMENTO É O PRÓXIMO `=$(`, NUNCA o primeiro ')'. Cortar no ')' parece
# óbvio e está ERRADO: `n=$(bd ... 2>/dev/null | python3 -c "...print(len(json.load(
# sys.stdin)))" 2>/dev/null)` tem ')' DENTRO das aspas, então o corte perde o segundo
# `2>/dev/null` e a linha deixa de ser flagrada. Eu escrevi essa versão, chamei de
# "limitação declarada aceitável", e ela QUEBROU uma fixture que já passava — o selftest
# do scanner pegou (20/23). Delimitar pela próxima substituição sobre-aproxima (o
# fragmento pode incluir texto após o ')' de fecho), mas sobre-aproximar erra pra FLAGRAR
# a mais, e neste scanner — report-only — um achado a mais custa um humano olhar, um a
# menos custa ninguém olhar. O teste de inerte só precisa do INÍCIO do fragmento, então a
# sobra à direita não o afeta.
_c2_scan_substitutions() {
  _file="$1"; _lineno="$2"; _rest="$3"
  while [ "${_rest#*=\$\(}" != "$_rest" ]; do
    _rest="${_rest#*=\$\(}"
    case "$_rest" in
      *'=$('*) _frag="${_rest%%=\$\(*}" ;;   # até a PRÓXIMA substituição
      *)       _frag="$_rest" ;;             # última: vai até o fim da linha
    esac
    case "$_frag" in
      # FONTE INERTE: `echo`/`printf`/`cat` de uma variável não falha ⇒ não existe o
      # estado "a pergunta falhou", só "o campo não está lá", que é fato legítimo.
      # Medido: sem esta exclusão, 48 dos 54 achados eram este shape (89% de ruído).
      'echo '* | 'printf '* | 'cat '* | ' echo '* | ' printf '* | ' cat '*) continue ;;
    esac
    case "$_frag" in
      *'2>/dev/null |'*' // '* | *'2>/dev/null |'*'2>/dev/null'* | \
        *'| jq '*' // "'* | *"| jq "*" // '"*)
        echo "${_file}:${_lineno}:C2:${_frag}"
        return 0 ;;   # 1 achado por linha basta: o objetivo é a linha ser OLHADA
    esac
  done
  return 1
}

# ── C1: JS/TS empty catch block ─────────────────────────────────────────────
# Handles `catch (e) {}` on one line, and the immediate-next-line shape:
#   catch (e) {
#   }
# Does not track nested brace depth (documented limitation above).
#
# Uses `grep -E` (an external, standardized binary) rather than bash's
# built-in `[[ =~ ]]` for every check in this file. This is not a style
# preference: while writing this scanner, `[[ "$line" =~
# catch[[:space:]]*\([^\)]*\)[[:space:]]*\{[[:space:]]*\} ]]` silently
# returned no-match against a real `catch (e) {}` line under this host's
# /bin/bash (3.2.57 — macOS's frozen pre-GPLv3 build), even though the
# identical pattern piped through `grep -Eq` matched correctly. Falsifying
# the check (ga-p5q3 defense (b): run it against a case you KNOW matches)
# caught this before it shipped a scanner that couldn't find its own named
# example — see the selftest for the fixture that proves it.
scan_js_empty_catch() {
  local file="$1" lineno=0 waiting=0 start=0 line compact
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$waiting" = "1" ]; then
      compact="$(printf '%s' "$line" | tr -d '[:space:]')"
      if [ -z "$compact" ]; then continue; fi
      case "$compact" in
        '}'*) echo "${file}:${start}:C1:empty catch block (multi-line)" ;;
      esac
      waiting=0
      continue
    fi
    # Cheap bash-builtin pre-filter (no subprocess) before the grep -E call —
    # `catch` is rare per-line, so this skips the fork+exec for almost every
    # line in a large file instead of spawning grep once per line.
    case "$line" in
      *catch*) ;;
      *) continue ;;
    esac
    if printf '%s\n' "$line" | grep -Eq 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}'; then
      echo "${file}:${lineno}:C1:${line}"
    elif printf '%s\n' "$line" | grep -Eq 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*$'; then
      waiting=1
      start=$lineno
    fi
  done < "$file"
}

# ── C1: Python bare `except: pass` ──────────────────────────────────────────
# See scan_js_empty_catch's comment above: matching is done via `grep -E`,
# not bash `[[ =~ ]]`, for verified reliability on this host's bash 3.2.
scan_py_bare_except() {
  local file="$1" lineno=0 waiting=0 start=0 line compact
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$waiting" = "1" ]; then
      compact="$(printf '%s' "$line" | tr -d '[:space:]')"
      if [ -z "$compact" ]; then continue; fi
      case "$compact" in
        pass | pass'#'*) echo "${file}:${start}:C1:bare except: pass (multi-line)" ;;
      esac
      waiting=0
      continue
    fi
    case "$line" in
      *except*) ;;
      *) continue ;;
    esac
    if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*except([[:space:]]+[A-Za-z_][A-Za-z0-9_.,[:space:]]*)?:[[:space:]]*pass[[:space:]]*(#.*)?$'; then
      echo "${file}:${lineno}:C1:${line}"
    elif printf '%s\n' "$line" | grep -Eq '^[[:space:]]*except([[:space:]]+[A-Za-z_][A-Za-z0-9_.,[:space:]]*)?:[[:space:]]*(#.*)?$'; then
      waiting=1
      start=$lineno
    fi
  done < "$file"
}

# ── C3: launchd job with no failure-notification path ───────────────────────
# Uses PlistBuddy (canonical macOS tool) rather than regexing XML by hand.
#
# ga-g2eg (instance #6 of the ga-p5q3 class, found INSIDE this lint itself):
# the original match required `notify` followed by whitespace, which missed
# the three real idioms this codebase actually uses — a NEGATIVE result meant
# "my pattern didn't match this idiom," not "no notify exists," the exact
# conflation this whole scanner exists to catch:
#   NOTIFY="/path/to/notify"   # assigns the tool to a variable — ends in a
#                               # quote, not whitespace
#   "$NOTIFY" -t "..." "..."   # invokes via the variable, not the literal word
#   notify_fail() { ... }      # a function NAMED notify_*, not `notify ` itself
# Measured 4/11 (36%) false-positive rate in C3 before this fix. Case-
# insensitive substring match (no trailing-space requirement) catches all
# three without needing to resolve variables or parse function defs — see the
# selftest's notify-via-variable/notify-via-function fixtures for the
# falsification proof (ga-p5q3 defense (b)).
scan_launchd_no_notify() {
  local plist="$1" args line script="" rc_pa rc_pg
  # ⚠️ FAIL-OPEN SILENCIOSO ERA AQUI (revisor do gate, run ga-wisp-3f5t3y). A v1 fazia
  #   args="$(PlistBuddy -c "Print :ProgramArguments" ... 2>/dev/null)" || return 0
  # e `return 0` significa "nada a reportar" = "este job avisa, está tudo bem". Ou seja:
  # NÃO CONSEGUI LER o plist saía igual a JÁ CHEQUEI E ESTÁ OK. Fail-open mudo dentro do
  # exato tipo de ferramenta que este arquivo existe pra caçar — e, ao contrário das
  # outras limitações, esta não estava declarada em "Known limitations".
  # Gatilho concreto: o launchd aceita a chave `Program` (string única) como alternativa
  # válida a `ProgramArguments` (array). Num plist assim, o Print :ProgramArguments FALHA
  # e o job inteiro era dado como saudável sem ninguém olhar.
  args="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$plist" 2>/dev/null)"; rc_pa=$?
  if [ "$rc_pa" -ne 0 ] || [ -z "$args" ]; then
    # fallback: a outra chave válida do launchd.
    args="$(/usr/libexec/PlistBuddy -c "Print :Program" "$plist" 2>/dev/null)"; rc_pg=$?
    if [ "$rc_pg" -ne 0 ] || [ -z "$args" ]; then
      # NENHUMA das duas chaves foi legível. Não sei se este job avisa — e "não sei" NÃO
      # é "está ok". Reporto o desconhecido em vez de engolir (o scanner é report-only:
      # o custo de um achado a mais é um humano olhar; o de um a menos é ninguém olhar).
      echo "${plist}:1:C3:launchd plist ilegível (nem :ProgramArguments nem :Program) — NÃO consegui apurar se este job avisa em falha; isto é 'não sei', não 'está ok'"
      return 0
    fi
  fi
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    case "$line" in
      Array* | '{' | '}' | '') continue ;;
      */bash | */sh | */zsh | /usr/bin/python3 | /usr/bin/env) continue ;;
    esac
    if [ -f "$line" ]; then
      script="$line"
      break
    fi
  done <<<"$args"
  [ -z "$script" ] && return 0
  [ -r "$script" ] || return 0
  grep -qiE 'notify|ntfy|gc mail send|gc session nudge' "$script" && return 0
  echo "${plist}:1:C3:launchd job (script: $script) has no failure-notification call (notify/gc mail send/gc session nudge/ntfy)"
}

# ── driver ───────────────────────────────────────────────────────────────────
# run_scan <findings_file> <root>... — appends "file:line:CATEGORY:snippet"
# lines to findings_file (truncated first). Count is the caller's job (just
# wc -l the file) — kept out of this function so stdout carries only findings,
# never a count line mixed in with them.
run_scan() {
  local findings_file="$1"
  shift
  local -a roots=("$@")
  : >"$findings_file"

  # Shared prune list — worktree copies, backups, and vendored deps would
  # otherwise multiply the same finding once per copy. Applied identically to
  # every find below so coverage doesn't quietly differ by file type.
  # ga-ypl5l: o buraco era de ESCOPO (distinto do ga-50m2, que é de CLASSIFICAÇÃO). Medido:
  # whatsapp_automation tinha 211.282 arquivos .sh/.py, ~1.369 canônicos — 154x de varredura
  # à toa. A causa não é um dir, é uma CLASSE de dirs: cópias do repo (crew/<nome>, worktrees
  # .wt-*, .viewer-deploy-clone, .gc-worktrees) e deps Python (venv/site-packages). Cada cópia
  # multiplica o MESMO achado, e o volume afogava o --seed do monitor (>14min) — e um job
  # agendado que estoura por volume é a própria classe (timeout lido como "nada novo").
  # Excluo por CLASSE, não caçando nome a nome: qualquer dir-ponto (.wt-*, .viewer-*,
  # .gc-*, .claude) + crew/ + as deps Python. NÃO exclua o root em si — só as cópias DENTRO.
  #
  # ga-9krhl: MAIS 2 classes da MESMA família (crew/* já cobria as cópias DENTRO de
  # crew/<nome>, mas não o rig do PRÓPRIO mayor/refinery na raiz do rig, nem os
  # worktrees "polecat"/".worktrees" que usam nomes diferentes de .gc-worktrees):
  #   1. <rig>/mayor/rig/ e <rig>/refinery/rig/ — cada rig (whatsapp_automation,
  #      gastown, etc.) tem sua PRÓPRIA cópia de trabalho pro mayor e pro refinery,
  #      irmã da canônica na raiz do rig — não nomeada "crew" nem ".gc-worktrees",
  #      então nenhuma exclusão existente pegava. Medido: whatsapp_automation/mayor/rig/
  #      e /refinery/rig/ sozinhos respondiam por 1054 dos 2279 C1 do baseline da
  #      silent-ignorance-watch (3x duplicação da fonte canônica; demand_dashboard.js
  #      sozinho: 103 canônico + 97 + 78 das 2 cópias = 278 "achados" que eram na
  #      verdade 1 arquivo contado 3x).
  #   2. /polecats/ (worktrees transientes, nome da doutrina Gas Town) e /.worktrees/
  #      (convenção usada por property_scrapers) — mesma classe de ".wt-*"/
  #      ".gc-worktrees", nome diferente por rig.
  # NÃO restrinjo a varredura a .py: falsifiquei antes de aceitar (ga-p5q3 defesa b) —
  # depois de só este dedup, o total .py caiu pra 830 achados em 327 arquivos, batendo
  # quase exato com o "~848 em ~330 arquivos" que motivou este bug, SEM precisar excluir
  # .js/.sh. E excluir .js/.sh estragaria sinal real: merged-bead-janitor.sh sozinho tem
  # 21 achados C1 (`|| true` masking), todos na cópia canônica única, zero duplicação —
  # sinal genuíno num script de infra da própria cidade, não ruído. "achado em .js/.sh
  # não é 'except:pass'" é
  # verdade mas irrelevante — cada C1 tem o idioma de fix certo pra sua própria
  # linguagem (catch(e){} para JS, `|| true` pra shell); a varredura multi-linguagem é
  # a missão documentada deste monitor desde o cabeçalho de silent-ignorance-watch.sh,
  # não um acidente de escopo.
  local -a EXCL=(
    -not -path '*/.gc-worktrees/*' -not -path '*/.gc-worktrees-adhoc/*'
    -not -path '*/.gc/*' -not -path '*/backup/*' -not -path '*/.dolt-backup/*'
    -not -path '*/.local-patches/*' -not -path '*/node_modules/*'
    -not -path '*/crew/*'
    -not -path '*/.wt-*' -not -path '*/.viewer-deploy-clone/*' -not -path '*/.claude/*'
    -not -path '*/venv/*' -not -path '*/.venv/*'
    -not -path '*/site-packages/*' -not -path '*/__pycache__/*'
    -not -path '*/mayor/rig/*' -not -path '*/refinery/rig/*'
    -not -path '*/polecats/*' -not -path '*/.worktrees/*'
    -not -path '*.bak-*/*'
    # ga-6jfuo: *.selftest.sh contem padroes C1/C2 DE PROPOSITO (fixtures pra
    # testar o proprio detector) -> falso-positivo na varredura de producao.
    # Nao afeta o selftest do scanner em si, que chama scan_* diretamente.
    -not -name '*.selftest.sh'
  )

  local f
  while IFS= read -r -d '' f; do
    scan_shell_query_masking "$f" >>"$findings_file"
  done < <(find "${roots[@]}" -type f -name '*.sh' "${EXCL[@]}" -print0 2>/dev/null)

  while IFS= read -r -d '' f; do
    scan_js_empty_catch "$f" >>"$findings_file"
  done < <(find "${roots[@]}" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.jsx' -o -name '*.tsx' \) "${EXCL[@]}" -print0 2>/dev/null)

  while IFS= read -r -d '' f; do
    scan_py_bare_except "$f" >>"$findings_file"
  done < <(find "${roots[@]}" -type f -name '*.py' "${EXCL[@]}" -print0 2>/dev/null)

  while IFS= read -r -d '' f; do
    scan_launchd_no_notify "$f" >>"$findings_file"
  done < <(find "${roots[@]}" -type f -name '*.plist' "${EXCL[@]}" -print0 2>/dev/null)
}

# ── lib-only mode: source with CONFLATION_SCAN_LIB_ONLY=1 to load only the ──
# pure/scan functions above (used by the selftest). Must come after all
# function definitions, before any live-mode execution below.
if [ -n "${CONFLATION_SCAN_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

main() {
  local target_path="" quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --path)
        target_path="$2"
        shift 2
        ;;
      --quiet)
        quiet=1
        shift
        ;;
      *)
        echo "error-empty-conflation-scan: unknown arg: $1" >&2
        exit 1
        ;;
    esac
  done

  local -a roots
  if [ -n "$target_path" ]; then
    roots=("$target_path")
  else
    roots=("$GC_CITY/packs" "$GC_CITY/scripts")
  fi

  local r
  for r in "${roots[@]}"; do
    if [ ! -d "$r" ]; then
      echo "error-empty-conflation-scan: scan root missing: $r" >&2
      exit 1
    fi
  done

  local findings_file count
  findings_file="$(mktemp)"
  run_scan "$findings_file" "${roots[@]}"
  count="$(wc -l <"$findings_file" | tr -d '[:space:]')"

  if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    echo "error-empty-conflation-scan: $count finding(s)"
    cat "$findings_file"
    if [ "$quiet" != "1" ]; then
      notify -t "Gas City: error-empty-conflation-scan" -p 3 \
        "$count finding(s) — error/empty conflation candidates (ga-p5q3 class)" 2>/dev/null || true
    fi
  else
    echo "error-empty-conflation-scan: 0 findings"
  fi
  rm -f "$findings_file"
}

main "$@"
