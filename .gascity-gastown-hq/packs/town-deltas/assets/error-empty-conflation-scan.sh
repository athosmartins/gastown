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

# ga-q0n6a: inline-comment allowlist, shared by C1/C2 and the new C4-C9
# detectors below. Required by the bead's own design constraint — a
# heuristic grep-class scanner with no escape hatch becomes noise and people
# stop running it (same lesson C1/C2/C3 already learned the hard way via
# their own false-positive fixes above: ga-l4nx1, ga-50m2, ga-g2eg). Mark a
# specific line as reviewed-and-fine with a trailing inline comment:
#   some_risky_line   # erro-vs-vazio: ok porque <razao>
# Deliberately a SUBSTRING match on the marker text, not a structured
# parser — consistent with this file's stated heuristic philosophy.
#
# Deliberately NOT wired into C3 (scan_launchd_no_notify) at all: (a) its
# real finding is reported against the .plist (XML) file at a hardcoded line
# 1, which has no natural home for a shell-style inline comment — an XML
# file's own comment syntax is different, and checking literal line 1 of a
# plist for this marker string would be checking essentially arbitrary XML
# preamble text, not a human's actual annotation; (b) its "plist unreadable"
# case is an "I don't know", not a finding — allowlisting a "don't know" is
# a category error, there is nothing there yet to have reviewed as fine.
_allowlisted() {
  local file="$1" lineno="$2"
  [ -z "$lineno" ] && return 1
  case "$lineno" in ''|*[!0-9]*) return 1 ;; esac
  sed -n "${lineno}p" "$file" 2>/dev/null | grep -qi 'erro-vs-vazio:[[:space:]]*ok'
}

# _allowlisted_range <file> <start> <end> — ga-a4gfd gate-feedback fix.
# A backslash line-continuation REQUIRES the trailing "\" to be the line's
# literal last character — a human cannot append a trailing "# erro-vs-vazio:
# ok ..." comment on any continuation line without breaking the statement.
# The only grammatically-valid place to mark a multi-line bd/git call as
# reviewed is its FINAL physical line. _allowlisted alone only ever checks
# the block's START line (the one _join_continued_lines reports), which for
# any real multi-line statement is never where a human COULD have put the
# marker — a 100% failure rate for the dominant multi-line style this file's
# own docstring says this codebase uses, not an edge case. Checks every
# line from start to end (inclusive) so the marker is honored wherever a
# human could actually have placed it. Single-line callers (start==end,
# or omitted end) degrade to the exact behavior of a plain _allowlisted call.
_allowlisted_range() {
  local file="$1" start="$2" end="$3" i
  [ -z "$start" ] && return 1
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$end" ] && end="$start"
  case "$end" in ''|*[!0-9]*) end="$start" ;; esac
  i="$start"
  while [ "$i" -le "$end" ]; do
    _allowlisted "$file" "$i" && return 0
    i=$((i + 1))
  done
  return 1
}

# _split_statements <fragment> — pure text transform (ga-j34ml gate-feedback
# fix, round 2 on the ga-a4gfd per-statement scoping). ga-a4gfd's own fix
# split on ';' only, independently at 3 call sites (C4/C5/C6) — each site
# was fixed the same INCOMPLETE way, because the split logic wasn't
# centralized. Reproduced live: ';', '&&', and '||' all chain independent
# statements in this exact codebase's own idiom interchangeably (this
# file's own C1/C2 detectors exist BECAUSE of `|| true`/`|| echo` masking —
# `||` is not a rare shape here), so a ';'-only split left the identical
# masking bug (one call's fix hides a different call's real violation)
# fully alive for '&&'/'||'-chained statements in all 3 functions.
#
# ONE shared helper now, not 3 independent copies — so a future 4th
# operator (if one is ever demonstrated to matter) is fixed once, not
# missed at 2 of 3 sites the way this one was. Splits on any of ';', '&&',
# '||' via a single sed pass (sed -E, not bash's [[ =~ ]] regex engine —
# consistent with this file's own documented bash-3.2 caution above).
# Deliberately does NOT split on a bare '&' (backgrounding) — not
# demonstrated as a real shape in this codebase's actual style, and
# distinguishing it from '&&' safely would add real complexity for a
# problem nobody has shown exists; if that changes, extend here, in this
# one place. Naive (does not respect quoting) — the same accepted
# limitation as the original ';'-only split, matching this file's own
# "heuristic, not a parser" house style.
_split_statements() {
  printf '%s' "$1" | sed -E 's/(;|&&|\|\|)/\n/g'
}

# ga-q0n6a: join backslash-line-continued shell statements into one logical
# line before scanning, for detectors where it matters (C4/C5/C9 below — all
# of which look for an ABSENT flag/word anywhere in a `bd`/`git` invocation
# that routinely spans several physical lines in this exact codebase's own
# style, e.g.:
#   MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all --limit 0 \
#     -l type:quality-gate-marker \
#     2>/dev/null || echo "[]")
# A single-physical-line scan would see only the first line, miss the
# --limit 0 on line 2, and FALSE-POSITIVE on a call that is actually fine —
# worse than the false-negative the existing C1/C2 shell detectors accept as
# a documented limitation (a missed real bug vs. a wrong accusation; this
# scanner's own report-only philosophy tolerates the former far better than
# the latter). Outputs "STARTLINE<TAB>ENDLINE<TAB>JOINED TEXT" per logical
# line — the tab is deliberate (a literal backslash "\" inside a bd command's
# own argument text, e.g. a description string, could otherwise be misread
# as a field separator if a naive delimiter like ":" or space were used
# instead). ENDLINE (ga-a4gfd gate-feedback) exists so callers can allowlist
# a multi-line block via _allowlisted_range across its whole span — the
# block's START line is never a valid place for a human to put the marker
# comment (see _allowlisted_range's own docstring for why).
_join_continued_lines() {
  local file="$1" lineno=0 start=0 buf="" line
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ -z "$buf" ]; then start=$lineno; fi
    case "$line" in
      *'\')
        buf="${buf}${line%\\} "
        continue
        ;;
    esac
    buf="${buf}${line}"
    printf '%s\t%s\t%s\n' "$start" "$lineno" "$buf"
    buf=""
  done <"$file"
  # A file ending mid-continuation (dangling trailing backslash, no final
  # newline) still has buffered content to flush — report what was gathered
  # rather than silently dropping the tail of the file.
  if [ -n "$buf" ]; then
    printf '%s\t%s\t%s\n' "$start" "$lineno" "$buf"
  fi
}

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
    # ga-50m2: TUDO passa pela classificação POR SUBSTITUIÇÃO agora — não há mais um
    # `case` sobre a LINHA INTEIRA aqui. A versão anterior tinha um `case` que casava
    # `gc_json_or_unknown`/`|| echo <empty>`/`|| true` na linha inteira e decidia
    # (excluir ou flagrar) direto, e só o fallback `*)` chamava a função por-
    # substituição que checa fonte inerte. MEDIDO (ga-50m2): 181 de 304 achados no HQ
    # (60%) eram `VAR=$(echo "$var" | jq ... || echo "")` — fonte INERTE — flagrados
    # como C2 porque o `|| echo ""` os pegava no caminho cego-à-fonte, ANTES do
    # fallback. A MESMA bifurcação deixava a exclusão do gc_json_or_unknown (ga-l4nx1)
    # vulnerável ao bug do revisor (ga-wisp-3ip2my) também: numa linha com um
    # gc_json_or_unknown seguro E uma substituição arriscada separada, o match
    # whole-line da exclusão vencia primeiro e a arriscada nunca era vista — um falso-
    # negativo, pior que o falso-positivo original. Agora as três decisões (fonte
    # inerte, gc_json_or_unknown, idioma de mascaramento) passam todas pela MESMA porta
    # por substituição — ver _c2_scan_substitutions logo abaixo.
    _c2_scan_substitutions "$file" "$lineno" "$line"
  done < "$file"
}

# ── C2/C1-shell: classifica CADA `VAR=$(...)` da linha, isoladamente ────────
# ÚNICO classificador de assignment-masking agora (ga-50m2) — não há mais um `case`
# sobre a linha inteira antes dele. Existe porque julgar a LINHA INTEIRA casa o
# primeiro padrão e para: numa linha com uma substituição inerte E uma arriscada (ou
# uma gc_json_or_unknown segura E uma arriscada separada), a primeira vencia e a
# segunda sumia (revisor do gate, run ga-wisp-3ip2my — mesmo buraco valia pro
# ga-l4nx1). Aqui cada substituição é julgada sozinha, e as três decisões — fonte
# inerte, gc_json_or_unknown, idioma de mascaramento (parser-default / echo-vazio /
# true) — passam todas por esta função.
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
      # FONTE INERTE — a MESMA porta pra todos os idiomas de mascaramento abaixo agora
      # (ga-50m2). `echo`/`printf`/`cat` de uma variável não falha ⇒ não existe o
      # estado "a pergunta falhou", só "o campo não está lá", que é fato legítimo.
      # Medido: 181 de 304 achados (60%) eram este shape, flagrados à toa porque um
      # `|| echo <vazio>`/`|| true` LITERAL os pegava num caminho que pulava esta
      # checagem (o antigo `case` sobre a linha inteira, eliminado neste fix).
      'echo '* | 'printf '* | 'cat '* | ' echo '* | ' printf '* | ' cat '*) continue ;;
      # ga-l4nx1, agora POR SUBSTITUIÇÃO (ga-50m2): gc_json_or_unknown já captura o rc
      # real e valida o envelope `ok` antes de retornar — um `|| true` depois dele
      # NESTA MESMA substituição é o idioma memoized-cache-com-retry documentado (ver
      # o próprio doc comment do helper), não a máscara crua que este scanner existe
      # pra caçar. Antes vivia num `case` sobre a linha inteira, o que deixava uma
      # substituição arriscada SEPARADA na mesma linha invisível — falso-negativo,
      # pior que o falso-positivo original do ga-50m2. Casa as duas formas reais: bare
      # (`VAR=$(gc_json_or_unknown gc ...)`) e com prefixo de env
      # (`VAR=$(GC_CITY="$GC_CITY" gc_json_or_unknown timeout 15 gc ...)`).
      *'gc_json_or_unknown '*) continue ;;
    esac
    case "$_frag" in
      # C2 — parser fabrica o default (o rc do pipe é o do ÚLTIMO comando = 0, então
      # erro-de-query e campo-genuinamente-ausente saem com o MESMO valor e o MESMO
      # rc=0). PROVADO: `bd -C /nao/existe show x --json 2>/dev/null | jq -r '.a //
      # ""'` -> '' rc=0, igual a `echo '{}' | jq -r '.a // ""'` -> '' rc=0 (ga-vkjs).
      *'2>/dev/null |'*' // '* | *'2>/dev/null |'*'2>/dev/null'* | \
        *'| jq '*' // "'* | *"| jq "*" // '"*)
        # ga-q0n6a: allowlist check wraps the echo, not the return — still
        # "classified" (first-match-wins per this loop's own design above),
        # just silently instead of printed.
        _allowlisted "$_file" "$_lineno" || echo "${_file}:${_lineno}:C2:${_frag}"
        return 0 ;;
      # C2 — fallback literal fabrica um valor vazio-parece-válido (ga-50m2: agora
      # julgado por substituição, não mais casado contra a linha inteira — uma
      # substituição inerte com este MESMO sufixo já foi excluída acima e nunca chega
      # aqui).
      *'|| echo "[]"'* | *"|| echo '[]'"* | *'|| echo ""'* | *"|| echo ''"* | \
        *'|| echo "0"'* | *'|| echo "null"'* | *'|| echo "{}"'* | *"|| echo '{}'"*)
        _allowlisted "$_file" "$_lineno" || echo "${_file}:${_lineno}:C2:${_frag}"
        return 0 ;;
      # C1 — o erro simplesmente some, nenhum sinal sobrevive (ga-50m2: idem, por
      # substituição — não mais pela linha inteira).
      *'|| true'*)
        _allowlisted "$_file" "$_lineno" || echo "${_file}:${_lineno}:C1:${_frag}"
        return 0 ;;
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
        '}'*) _allowlisted "$file" "$start" || echo "${file}:${start}:C1:empty catch block (multi-line)" ;;
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
      _allowlisted "$file" "$lineno" || echo "${file}:${lineno}:C1:${line}"
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
        pass | pass'#'*) _allowlisted "$file" "$start" || echo "${file}:${start}:C1:bare except: pass (multi-line)" ;;
      esac
      waiting=0
      continue
    fi
    case "$line" in
      *except*) ;;
      *) continue ;;
    esac
    if printf '%s\n' "$line" | grep -Eq '^[[:space:]]*except([[:space:]]+[A-Za-z_][A-Za-z0-9_.,[:space:]]*)?:[[:space:]]*pass[[:space:]]*(#.*)?$'; then
      _allowlisted "$file" "$lineno" || echo "${file}:${lineno}:C1:${line}"
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

# ═════════════════════════════════════════════════════════════════════════
# ga-q0n6a: C4-C9 — 6 additional error-vs-empty idioms sliced from the
# erro-vs-vazio epic (ga-05604), each with a real measured instance in this
# city at the time the bead was written. Deliberately NOT folded into C1/C2's
# existing shape-matching — each idiom below has its own distinct trigger
# condition and would only dilute the well-tested C1/C2 logic if merged in.
# All 6 are shell-only (.sh) detectors: `$?`-after-pipe, jq field-existence,
# and the various bd/git flag-omission idioms below are shell-specific
# concepts with no direct JS/Python equivalent (those languages have their
# own distinct failure-modes, out of scope for this slice — see C1's JS/
# Python detectors above for that separate territory).
# ═════════════════════════════════════════════════════════════════════════

# ── C4: `bd list --json` without `--limit 0` in a sweep ─────────────────────
# bd 1.1.0 truncates `bd list --json` at 50 results by default; the warning
# ("Showing 50 issues... use --limit 0 for all") goes to stderr, which this
# very codebase's own idiom (`2>/dev/null`) routinely swallows — a filtered
# query whose real result set is under 50 works by accident, and the defect
# is latent until the backlog crosses 50, which is exactly when a diagnostic
# matters most (ga-21kmp: measured 96 call sites city-wide at bead-write
# time; two real Mayor misjudgments cited: "no digest beads exist" when 10
# existed past the first 50, and "10 armed beads" when there were 19).
# Scoped to `--json` invocations only — a bare interactive `bd list` (no
# --json) is a human eyeballing output directly, not a program silently
# under-seeing a truncated result, which is the actual danger this idiom
# names. Uses the joined-logical-line view (see _join_continued_lines above)
# so a `--limit 0` on a continuation line 2+ is not missed.
#
# Optional 2nd arg <joined>: a pre-computed _join_continued_lines output, so
# run_scan's hot loop can compute it ONCE per file and share it across this
# function and C5/C6/C8 below instead of each re-reading the same file
# independently (ga-kqznp: this scanner's per-file cost is the live known
# bottleneck; 4 redundant full-file read loops per file would have made that
# measurably worse for zero new coverage). Defaults to computing it locally
# when called standalone (as every direct-function selftest call above does),
# so the calling convention used throughout this file's existing tests is
# unchanged.
#
# ga-q0n6a perf fix (falsified against pilot-dispatcher.sh, a real 7426-line
# bd-heavy dispatcher — an earlier draft with a bash-case pre-filter INSIDE
# the per-joined-line loop still forked grep -Eq 2x for every "list"-
# containing line, and this file alone has hundreds; that measurably hung
# the whole scan). The CANDIDATE search is done via `grep -E` PIPED over the
# WHOLE joined blob (grep's own fast internal C loop scans every line in one
# process) — only the FEW lines that survive both greps ever reach the bash
# loop below, where the PRECISE per-statement check runs (cheap, because
# there are now only a handful of candidates, not hundreds).
#
# ga-a4gfd gate-feedback fix: the precise check below now scopes to each
# STATEMENT within a candidate line/block independently (via
# _split_statements above — ';'/'&&'/'||', not just ';'; see ga-j34ml's
# round-2 fix on that helper's own docstring for why), rather than
# reasoning over the whole joined line. Reproduced live before fixing:
# `bd -C "$A" list --json --limit 0 2>/dev/null; bd -C "$B" list --json
# 2>/dev/null` — two independent bd calls, one fixed, one not — used to
# report ZERO findings, because the first call's --limit 0 satisfied the
# whole-line check and silently masked the second call's real, unaddressed
# truncation risk (the exact ga-21kmp class this detector exists for). This
# is the identical scoping mistake _c2_scan_substitutions's own docstring
# above documents already diagnosing and fixing once, for C1/C2 (ga-50m2) —
# reintroduced here in new code that didn't inherit that fix.
scan_bd_list_no_limit() {
  local file="$1" joined="${2:-}" start end frag stmt
  [ -z "$joined" ] && joined="$(_join_continued_lines "$file")"
  while IFS="$(printf '\t')" read -r start end frag; do
    [ -z "$start" ] && continue
    while IFS= read -r stmt || [ -n "$stmt" ]; do
      [ -z "$stmt" ] && continue
      printf '%s' "$stmt" | grep -Eq "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]]list([[:space:]]|\$)" || continue
      printf '%s' "$stmt" | grep -Eq -- '--json' || continue
      printf '%s' "$stmt" | grep -Eq -- '--limit[[:space:]]+0|-n[[:space:]]+0|--limit=0' && continue
      _allowlisted_range "$file" "$start" "$end" && continue
      echo "${file}:${start}:C4:${stmt}"
    done < <(_split_statements "$frag")
  done < <(printf '%s\n' "$joined" \
    | grep -E "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]]list([[:space:]]|\$)" \
    | grep -F -- '--json')
}

# ── C5: `bd list`/`show` on `type:quality-gate-*` without `--include-infra` ──
# bd 1.1.0 classifies an `--ephemeral` bead as INFRA and omits it from `bd
# list` by default. Gate marker/run/verdict beads are the confirmed-affected
# family in this city (ga-vm20x: a guard saw 0 markers where 7 existed,
# logging the honest-sounding "No work. Exiting." for 2 hours while real
# submissions queued). Scoped narrowly to the `type:quality-gate-` prefix —
# the confirmed-affected family — rather than every `type:` filter, since
# this scanner reports only what has been actually verified affected (see
# ga-vm20x's own P1→P3 rescoping note: guessing at unverified affected types
# is exactly the "measure, don't guess" failure this whole epic is about).
# Optional 2nd arg <joined>: see scan_bd_list_no_limit's docstring above —
# same shared-computation rationale, same default-if-omitted behavior.
# ga-a4gfd gate-feedback fix: same per-statement scoping as scan_bd_list_no_
# limit above, for the identical reason — a whole-line check lets one
# bd call's --include-infra mask a different, unrelated bd call's real
# absence of it on the same joined line.
scan_bd_gate_no_infra() {
  local file="$1" joined="${2:-}" start end frag stmt
  [ -z "$joined" ] && joined="$(_join_continued_lines "$file")"
  # Perf: piped grep over the whole blob, not a per-line bash loop — see
  # scan_bd_list_no_limit's docstring above for why this matters.
  while IFS="$(printf '\t')" read -r start end frag; do
    [ -z "$start" ] && continue
    while IFS= read -r stmt || [ -n "$stmt" ]; do
      [ -z "$stmt" ] && continue
      printf '%s' "$stmt" | grep -Eq "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]](list|show)([[:space:]]|\$)" || continue
      printf '%s' "$stmt" | grep -Eq -- 'type:quality-gate-' || continue
      printf '%s' "$stmt" | grep -Eq -- '--include-infra' && continue
      _allowlisted_range "$file" "$start" "$end" && continue
      echo "${file}:${start}:C5:${stmt}"
    done < <(_split_statements "$frag")
  done < <(printf '%s\n' "$joined" \
    | grep -E "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]](list|show)([[:space:]]|\$)" \
    | grep -F -- 'type:quality-gate-')
}

# ── C6: parsing FORMATTED (non-JSON) `bd comments`/`bd show` output ─────────
# `bd comments`/`bd show` without `--json` produce human-readable text that
# `bd` itself wraps at ~80 columns — a grep/sed/awk pattern written against
# one-line-per-record output silently breaks when a matched string happens to
# straddle a wrap point (ga-fic5d: story-delivery's merge-detection regex
# missed a real merge because `bd comments`'s line wrap split the commit SHA
# across two lines). The fix is `--json` + `jq`, which this scanner already
# encourages via C1/C2's own query-tool vocabulary. Only flags when the
# unparsed output is actually piped into a text-processing tool — a bare `bd
# show "$ID"` for a human to read on a terminal is not this bug.
# Optional 2nd arg <joined>: see scan_bd_list_no_limit's docstring above —
# same shared-computation rationale, same default-if-omitted behavior.
# ga-a4gfd gate-feedback fix: same per-statement scoping, for a false
# POSITIVE this time (not just a false negative) — reproduced live before
# fixing: `echo "$x" | grep -q foo; bd show "$ID"` used to flag C6 even
# though bd show's own output is not piped anywhere — the pipe belongs to
# the entirely unrelated first command. Whole-line reasoning treated "a bd
# (show|comments) call exists somewhere" and "a pipe-to-grep/sed/awk exists
# somewhere" as if they had to be the SAME command, which directly
# contradicts this function's own stated intent above ("a bare `bd show
# "$ID"` for a human to read on a terminal is not this bug") for any line
# also containing an unrelated pipe. Ordinary `;`-chained shell style (e.g.
# `ps aux | grep proc; bd show "$ID"`) triggered this.
scan_bd_formatted_output_parsed() {
  local file="$1" joined="${2:-}" start end frag stmt
  [ -z "$joined" ] && joined="$(_join_continued_lines "$file")"
  # Perf: piped grep chain over the whole blob, not a per-line bash loop —
  # see scan_bd_list_no_limit's docstring above.
  while IFS="$(printf '\t')" read -r start end frag; do
    [ -z "$start" ] && continue
    while IFS= read -r stmt || [ -n "$stmt" ]; do
      [ -z "$stmt" ] && continue
      printf '%s' "$stmt" | grep -Eq "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]](comments|show)([[:space:]]|\$)" || continue
      printf '%s' "$stmt" | grep -Eq -- '--json' && continue
      printf '%s' "$stmt" | grep -Eq '\|[[:space:]]*(grep|egrep|sed|awk)([^A-Za-z0-9_]|$)' || continue
      _allowlisted_range "$file" "$start" "$end" && continue
      echo "${file}:${start}:C6:${stmt}"
    done < <(_split_statements "$frag")
  done < <(printf '%s\n' "$joined" \
    | grep -E "([^A-Za-z0-9_]|^)bd([^A-Za-z0-9_].*)?[[:space:]](comments|show)([[:space:]]|\$)" \
    | grep -E '\|[[:space:]]*(grep|egrep|sed|awk)([^A-Za-z0-9_]|$)')
}

# ── C7: `$?` read immediately after a piped command ──────────────────────────
# `$?` reflects only the LAST command in a pipeline — `risky_cmd | head -1;
# echo $?` is always 0 regardless of whether risky_cmd itself failed, because
# head succeeded. A real incident this idiom exists to name: a "confirming" a
# false P0 premise this way, same day this bead was written. Single-physical-
# line detector only (declared limitation, matching this file's own honest
# style for C1/C2's documented backslash-continuation gap above) — the
# continuation-joiner is not used here because `;`-separated statements on
# one joined logical line would make "immediately after" ambiguous to detect
# reliably; the common real shape is two adjacent physical lines or a `;` on
# one line, both handled below.
# The `[^|]\|[^|]` shape matches a lone `|` (pipe) that is not part of a `||`
# (or-operator, already handled by C1) — deliberately avoids `\b`/`\s` per
# this file's house style (BSD grep does not reliably support them).
# ga-q0n6a perf fix: rewritten to use ONLY bash-builtin string checks, zero
# grep subprocess calls per line (the original draft called grep 1-3x per
# LINE unconditionally, measurably worsening the ga-kqznp performance
# concern — falsified by benchmarking the live tree before/after, see the
# bead's own comments). "Has a real pipe" is computed by stripping every
# literal `||` first via bash's own `${var//pat/repl}` substitution, then
# checking whether any `|` remains — a lone survivor is a real pipe, not an
# or-operator (that's C1's territory, not C7's). Trades exact same-line
# ordering precision (is the `$?` actually AFTER the pipe?) for speed — this
# file is a heuristic grep-class scanner by its own stated design, not a
# parser; in practice a `$?` on a line with a real pipe is checking that
# pipe's result in the overwhelming majority of real code.
scan_pipe_then_exit_code() {
  local file="$1" lineno=0 prev_has_pipe=0 prev_line="" line stripped has_pipe has_dollarq
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    stripped="${line//||/}"
    case "$stripped" in *'|'*) has_pipe=1 ;; *) has_pipe=0 ;; esac
    case "$line" in *'$?'*) has_dollarq=1 ;; *) has_dollarq=0 ;; esac

    if [ "$has_pipe" = "1" ] && [ "$has_dollarq" = "1" ]; then
      # Same-line shape: `cmd1 | cmd2; echo $?` (or `[ $? ... ]`, `if [ $? ...`).
      _allowlisted "$file" "$lineno" || echo "${file}:${lineno}:C7:${line}"
    elif [ "$prev_has_pipe" = "1" ] && [ "$has_dollarq" = "1" ]; then
      # Adjacent-line shape: pipe on the line before, $? read on this one.
      _allowlisted "$file" "$((lineno - 1))" || echo "${file}:$((lineno - 1)):C7:${prev_line}"
    fi
    prev_has_pipe="$has_pipe"
    prev_line="$line"
  done <"$file"
}

# ── C8: `jq '.field | length'` used as an existence test ─────────────────────
# ABSENT and EMPTY-ARRAY both report length 0 — `.field | length` cannot tell
# "the key never existed" from "the key exists and holds []". The correct
# existence test is `has("field")`. Two real same-day near-misses cited in
# this bead: almost filing a P0 claiming bd's contract had changed, and
# almost declaring a P0 that a scope-check field was absent, when both were
# actually present-but-empty. Scoped to a DOTTED FIELD PATH piped to length
# (`.foo`, `.foo.bar`) — a bare `jq 'length'` (no leading field) is counting
# the WHOLE input's own size, a different and legitimate operation this
# detector does not flag.
# Optional 2nd arg <joined>: see scan_bd_list_no_limit's docstring above —
# same shared-computation rationale, same default-if-omitted behavior.
#
# ga-a4gfd gate-feedback: uses _allowlisted_range (not the old start-line-
# only _allowlisted) for the same reason as C4/C5/C6 — see
# _allowlisted_range's own docstring. Deliberately NOT given the same
# per-statement `;`-split restructuring those three received: this
# detector's trigger is ONE self-contained regex
# (`\.field[[:space:]]*\|[[:space:]]*length`) that captures the risky
# field-path AND its pipe-to-length together in a single match, unlike
# C4/C5/C6's bug — which was treating two INDEPENDENTLY-matched facts
# (e.g. "a bd call exists" and "--limit 0 exists") as if they had to
# belong to the same statement, when whole-line matching let them come
# from two different, unrelated statements. There is no equivalent second
# fact here to misattribute: a `.field | length` match is real wherever it
# occurs in the fragment, regardless of what other jq calls share the
# line, so whole-fragment presence-checking does not introduce the same
# false-negative/false-positive class for this detector specifically.
scan_jq_length_as_existence() {
  local file="$1" joined="${2:-}" start end frag
  [ -z "$joined" ] && joined="$(_join_continued_lines "$file")"
  # Perf: piped grep chain over the whole blob, not a per-line bash loop —
  # see scan_bd_list_no_limit's docstring above.
  while IFS="$(printf '\t')" read -r start end frag; do
    [ -z "$start" ] && continue
    _allowlisted_range "$file" "$start" "$end" && continue
    echo "${file}:${start}:C8:${frag}"
  done < <(printf '%s\n' "$joined" \
    | grep -E "([^A-Za-z0-9_]|^)jq([^A-Za-z0-9_]|\$)" \
    | grep -E '\.[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*\|[[:space:]]*length')
}

# ── C9: `git merge-base --is-ancestor` / `git rev-parse origin/<br>` with no
# `git fetch` anywhere in the same file ──────────────────────────────────────
# Both commands answer against the LOCAL cached view of origin — fast and
# silent, with no error, even when that cache is stale. Without a preceding
# `git fetch`, the answer reflects whatever origin looked like at the last
# unrelated fetch, not now. Real incident cited: incorrectly disarming a bead
# that actually had pending work, same day this bead was written. FILE-LEVEL
# heuristic (declared limitation, matching C3's own file-level notify-
# presence check above) — true execution-order analysis (is the fetch
# actually BEFORE this specific call?) needs control-flow tracking, out of
# scope for a heuristic grep-class scanner; a file containing both is treated
# as fine even if their relative order is wrong, exactly as C3 treats a
# notify call anywhere in a launchd target script as fine regardless of
# whether it's actually reachable from the failure branch.
scan_git_stale_cache_check() {
  local file="$1"
  grep -Eq -- '--is-ancestor|rev-parse[[:space:]]+.*origin/' "$file" || return 0
  grep -Eq -- 'git[[:space:]]+fetch' "$file" && return 0
  grep -nE -- '--is-ancestor|rev-parse[[:space:]]+.*origin/' "$file" | while IFS=: read -r ln rest; do
    _allowlisted "$file" "$ln" && continue
    echo "${file}:${ln}:C9:no git fetch found anywhere in this file: ${rest}"
  done
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

  local f _joined
  # ga-q0n6a: C4-C9 folded into this SAME .sh loop/find pass rather than each
  # getting their own — ga-kqznp already flags this scanner's per-file cost
  # as the live bottleneck (~5 files/s); a second full-tree find+read pass
  # for the same file set would double that cost for zero new coverage.
  # _join_continued_lines is computed ONCE per file here (when needed at
  # all — see the file-level pre-filters below) and threaded into C4/C5/C6/
  # C8 (their optional 2nd arg) — same rationale, one level down: those 4
  # would otherwise each independently re-read+re-join the same file,
  # quadrupling that specific cost for zero new coverage.
  #
  # File-level pre-filters (cheap single grep -q per file) skip the join AND
  # the per-line detector call entirely for files that cannot possibly
  # match — same "cheap check before expensive work" principle as each
  # detector's own internal bash-case line pre-filter. Benchmarked: an
  # earlier draft without any of this (per-line grep -Eq calls unconditional,
  # no file-level skip) did not complete a full HQ scan within 90s; with
  # these two layers plus the per-line bash-case prefilters above, see the
  # bead's own comment for the measured result.
  while IFS= read -r -d '' f; do
    scan_shell_query_masking "$f" >>"$findings_file"
    _joined=""

    if grep -q 'bd' "$f" 2>/dev/null; then
      _joined="$(_join_continued_lines "$f")"
      scan_bd_list_no_limit "$f" "$_joined" >>"$findings_file"
      scan_bd_gate_no_infra "$f" "$_joined" >>"$findings_file"
      scan_bd_formatted_output_parsed "$f" "$_joined" >>"$findings_file"
    fi

    if grep -q '|' "$f" 2>/dev/null; then
      scan_pipe_then_exit_code "$f" >>"$findings_file"
    fi

    if grep -q 'jq' "$f" 2>/dev/null; then
      [ -z "$_joined" ] && _joined="$(_join_continued_lines "$f")"
      scan_jq_length_as_existence "$f" "$_joined" >>"$findings_file"
    fi

    scan_git_stale_cache_check "$f" >>"$findings_file"
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
