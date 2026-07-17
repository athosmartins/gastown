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
QUERY_TOOL_RE='([^A-Za-z0-9_]|^)(bd|dolt|jq|grep|git|gh|curl|sqlite3|mysql|aws)([^A-Za-z0-9_]|$)'

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
      *'|| echo "[]"'* | *"|| echo '[]'"* | *'|| echo ""'* | *"|| echo ''"* | \
        *'|| echo "0"'* | *'|| echo "null"'*)
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
      # Por isso o teste abaixo é sobre o INÍCIO da substituição (`=$(<query-tool>`),
      # não sobre a linha conter um query-tool em qualquer posição.
      *'=$(echo '* | *'=$(printf '* | *'=$(cat '* | *'=$( echo '*)
        : ;;   # fonte inerte — não há erro pra confundir com vazio
      *'2>/dev/null |'*' // '* | *'2>/dev/null |'*'2>/dev/null'* | \
        *'| jq '*' // "'* | *"| jq "*" // '"*)
        echo "${file}:${lineno}:C2:${line}"
        ;;
    esac
  done < "$file"
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
  local plist="$1" args line script=""
  args="$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$plist" 2>/dev/null)" || return 0
  [ -z "$args" ] && return 0
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
  local -a EXCL=(
    -not -path '*/.gc-worktrees/*' -not -path '*/.gc-worktrees-adhoc/*'
    -not -path '*/.gc/*' -not -path '*/backup/*' -not -path '*/.dolt-backup/*'
    -not -path '*/.local-patches/*' -not -path '*/node_modules/*'
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
