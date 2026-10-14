#!/usr/bin/env bash
# gate-taskrapida.lib.sh (ga-dzzqvw) — the gate's "task-rapida" lane.
#
# Athos, 2026-10-12: "Task com até 200 linhas de código e que não mexe em envio de mensagem, dinheiro ou dado de
# cliente: uma revisão curta, sem bateria de testes, em ~5 min. O resto continua no gate normal."
#
# The lane is only ever GRANTED, on POSITIVE evidence, all of it at once:
#   * the source bead says issue_type == task (feature / bug / chore / epic, and "could not read it", are not);
#   * the production lines of the diff, counted by E11's own counter (gate_e11_count_production_lines — tests, docs,
#     lockfiles and generated files do not count), are <= 200;
#   * no file of the diff matches the risk list (.gc/gate-task-rapida-risco.txt: sending messages, money, customer data);
#   * the switch file (.gc/gate-task-rapida.on) exists.
# Everything else — a "no" AND a "could not tell" — leaves the run on the normal gate. Three states, and the last two are
# one: the lane never turns an unreadable input into a grant.
#
# Unlike the DOC/TEST fast lane (gate-fastlane.lib.sh) this lane does NOT skip the reviewer: the run keeps ONE reviewer
# with a short prompt (gate-review-task.lib.sh, GATE_REVIEW_PROMPT_MODE=task-rapida), and the merge side — content
# coherence, the rig's full-suite check, rebase, merge — is exactly the normal gate's. So there is no push-time
# re-confirmation here: nothing is merged without a verdict, and the verdict is on the diff the reviewer is shown.
#
# Interface (bash 3.2: no arrays, no ${v,,}; every decision $(...) is guarded; safe under `set -euo pipefail`):
#   gate_taskrapida_decide <git_fn> <base_ref> <head_ref> <bead_show_json> <rig> <policy_files>
#       <git_fn>          a command run as `$git_fn <git args>` against the rig's repo (the dispatcher's git_rig)
#       <bead_show_json>  `bd show <bead> --json` of the SOURCE bead (an array of one, or one object); "" if unreadable
#       <policy_files>    the dispatcher's POLICY_FILES (the diff touches the gate's own policy files if non-empty)
#     returns 0 and sets the lane only on a clean grant; returns 1 on everything else and leaves GATE_LANE as it was.
#   Sets always:   GATE_TR_CODE (see gate_taskrapida_codes), GATE_TR_WHY, GATE_TR_LINES (measured production lines, or "")
#   Sets on grant: GATE_LANE=task-rapida, GATE_LANE_REASON, GATE_LANE_REASON_CODE=task-rapida-granted, GATE_LANE_FILES,
#                  GATE_LANE_COUNTS — the same globals gate_fastlane_record writes to the marker and the jsonl.
#   Reads:         GATE_TASKRAPIDA_ENABLED (default 1; anything but 1 = off), GATE_TASKRAPIDA_ON_FILE,
#                  GATE_TASKRAPIDA_RISK_FILE (both default to $GC_CITY/.gc/...), GATE_TASKRAPIDA_MAX_LINES (default 200,
#                  1..2000), GATE_TASKRAPIDA_MAX_TOTAL_LINES (default 1000, 1..20000), GATE_E5_ACTIVE.
# Needs gate_e11_count_production_lines (quality-gate-guard.sh, sourced lib-only by the dispatcher); without it: counter-missing.

# gate_taskrapida_codes — "code<TAB>label" per line: every GATE_TR_CODE this lib can leave, in one place. gate-taskrapida.selftest.sh
# fails when this list and its cases drift. The weekly tally (python) cannot source this file, so gate-lane-tally.py keeps its own copy
# (TR_REASON_CODES, printed by `gate-lane-tally.py --list-tr-codes`) and the same selftest fails when the two lists differ in a code or in a word.
gate_taskrapida_codes() {
  printf '%s\t%s\n' \
    granted           "concedida: task pequena, fora da lista de risco" \
    disabled          "faixa desligada por GATE_TASKRAPIDA_ENABLED" \
    switch-off        "chave .gc/gate-task-rapida.on ausente (faixa desligada)" \
    switch-unreadable "chave da faixa ilegivel ou sem local" \
    lane-decided      "a fast-lane (doc/teste) ja decidiu esta rodada" \
    bad-inputs        "entrada da decisao vazia" \
    e5-active         "rodada com revisor extra do E5" \
    policy-files      "diff mexe em arquivo de politica do gate" \
    not-task          "bead de origem nao e task" \
    type-unreadable   "tipo do bead de origem ilegivel" \
    opted-out         "bead com a label gate:normal-only (pediu o gate normal)" \
    labels-unreadable "labels do bead de origem ilegiveis" \
    cap-invalid       "teto de linhas ilegivel (variavel de ambiente)" \
    counter-missing   "contador de linhas de producao (E11) nao carregado" \
    diff-failed       "git nao devolveu o diff" \
    count-failed      "contagem de linhas ilegivel" \
    binary-file       "arquivo binario no diff" \
    empty-diff        "diff vazio" \
    over-limit        "mais de 200 linhas de producao" \
    over-total        "diff grande demais no total (com testes e docs)" \
    risk-unreadable   "lista de risco ausente, ilegivel, vazia ou malformada" \
    risk-file         "arquivo do diff casa com a lista de risco" \
    lib-not-loaded    "lib da faixa nao carregada no dispatcher" \
    no-changed-files  "lista de arquivos do dispatcher vazia (erro de git)" \
    decision-errored  "decisao da faixa deu erro ou resposta incoerente"
  return 0
}

# _gate_tr_refuse <code> <why> — the outcome of every "no" and every "could not tell". Always returns 0 (the caller returns 1:
# a function that returns 1 here would end a `set -e` caller before it could say why).
_gate_tr_refuse() {
  GATE_TR_CODE="$1"; GATE_TR_WHY="$2"
  return 0
}

# _gate_tr_cap <value> <default> <max> — prints the cap: <default> for an empty value (the documented default is a decision,
# not a failure), the value if it is a plain positive integer <= <max>, and NOTHING for anything else (rc 0 either way; the
# caller tests for empty output). "0200", "1,200", "20 0", "-5" and "99999" are not caps: an override nobody could read must
# not widen the lane silently (a typo for 200 that became 99999 would grant everything).
_gate_tr_cap() {
  local v="$1" def="$2" max="$3"
  if [ -z "$v" ]; then printf '%s' "$def"; return 0; fi
  case "$v" in *[!0-9]*|0*|?????????*) return 0 ;; esac
  if [ "$v" -le "$max" ] 2>/dev/null; then printf '%s' "$v"; fi
  return 0
}

# _gate_tr_off — returns 0 (and sets GATE_TR_CODE/WHY) when the lane is OFF or its switch cannot be read; 1 when it is ON.
# The file is the switch and its PRESENCE is "on" (born ON, 12/10): absent = off, so a deploy that lost the file, or a
# host whose $GC_CITY is not set, falls to the normal gate.
_gate_tr_off() {
  local flag
  if [ "${GATE_TASKRAPIDA_ENABLED:-1}" != "1" ]; then
    _gate_tr_refuse "disabled" "task-rapida lane disabled (GATE_TASKRAPIDA_ENABLED=${GATE_TASKRAPIDA_ENABLED:-})"; return 0
  fi
  flag="${GATE_TASKRAPIDA_ON_FILE:-}"
  if [ -z "$flag" ] && [ -n "${GC_CITY:-}" ]; then flag="$GC_CITY/.gc/gate-task-rapida.on"; fi
  if [ -z "$flag" ]; then
    _gate_tr_refuse "switch-unreadable" "task-rapida cannot find its switch (GC_CITY and GATE_TASKRAPIDA_ON_FILE are both unset) — a switch that cannot be found is not one that is on"; return 0
  fi
  if [ -f "$flag" ] && [ ! -r "$flag" ]; then
    _gate_tr_refuse "switch-unreadable" "the task-rapida switch file exists but cannot be read"; return 0
  fi
  if [ ! -f "$flag" ]; then
    _gate_tr_refuse "switch-off" "task-rapida switched off (.gc/gate-task-rapida.on is absent)"; return 0
  fi
  return 1
}

# _gate_tr_load_risk <rig> — reads the risk list into GATE_TR_PATTERNS (newline-separated, lower-cased: the patterns that apply
# to <rig>) and GATE_TR_NPAT. Returns 0 only for a list that was read AND leaves at least one pattern for the rig. 1 otherwise
# (absent, unreadable, a directory, an unterminated [section, or nothing that applies) with GATE_TR_WHY saying which.
_gate_tr_load_risk() {
  local rig="$1" f line section="*" pat content
  GATE_TR_PATTERNS=""; GATE_TR_NPAT=0; GATE_TR_RISK_WHY=""
  f="${GATE_TASKRAPIDA_RISK_FILE:-}"
  if [ -z "$f" ] && [ -n "${GC_CITY:-}" ]; then f="$GC_CITY/.gc/gate-task-rapida-risco.txt"; fi
  if [ -z "$f" ]; then GATE_TR_RISK_WHY="the risk list has no location (GC_CITY and GATE_TASKRAPIDA_RISK_FILE are both unset)"; return 1; fi
  if [ ! -f "$f" ]; then GATE_TR_RISK_WHY="the risk list is absent (or not a file): $f"; return 1; fi
  if [ ! -r "$f" ]; then GATE_TR_RISK_WHY="the risk list cannot be read: $f"; return 1; fi
  content=$(cat "$f" 2>/dev/null) || { GATE_TR_RISK_WHY="the risk list could not be read: $f"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      '['*']')
        section="${line#[}"; section="${section%]}"
        section="${section#"${section%%[![:space:]]*}"}"; section="${section%"${section##*[![:space:]]}"}"
        continue ;;
      '['*)
        GATE_TR_RISK_WHY="the risk list has a section header that is not closed ($line) — the list cannot be trusted"; GATE_TR_PATTERNS=""; GATE_TR_NPAT=0; return 1 ;;
    esac
    if [ "$section" = "*" ] || [ "$section" = "$rig" ]; then
      pat=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]') || { GATE_TR_RISK_WHY="a pattern of the risk list could not be lower-cased (tr failed)"; GATE_TR_PATTERNS=""; GATE_TR_NPAT=0; return 1; }
      GATE_TR_PATTERNS="${GATE_TR_PATTERNS}${pat}"$'\n'
      GATE_TR_NPAT=$((GATE_TR_NPAT + 1))
    fi
  done <<< "$content"
  if [ "$GATE_TR_NPAT" -lt 1 ]; then
    GATE_TR_RISK_WHY="the risk list has no pattern for rig '${rig:-?}' — nothing to check the diff against"; return 1
  fi
  return 0
}

# _gate_tr_risk_hit <paths> — the first path that matches a loaded pattern, as "path<TAB>pattern" on stdout; nothing when none
# does. A pattern without * ? is a piece of the path; with them it is a glob over the whole path. Case-insensitive.
_gate_tr_risk_hit() {
  local paths="$1" p lp pat
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    lp=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]') || { printf '%s\t%s' "$p" "(path could not be lower-cased: counted as a match)"; return 0; }
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      case "$pat" in
        *[\*\?]*) case "$lp" in $pat) printf '%s\t%s' "$p" "$pat"; return 0 ;; esac ;;
        *)        case "$lp" in *"$pat"*) printf '%s\t%s' "$p" "$pat"; return 0 ;; esac ;;
      esac
    done <<< "$GATE_TR_PATTERNS"
  done <<< "$paths"
  return 0
}

gate_taskrapida_decide() {
  local git_fn="${1:-}" base="${2:-}" head="${3:-}" bead_json="${4-}" rig="${5:-}" policy="${6:-}"
  local ty lb cap total_cap numstat rc=0 add del path total=0 nfiles=0 bad=0 binary=0 paths="" list="" prod hit hit_path hit_pat
  GATE_TR_CODE=""; GATE_TR_WHY=""; GATE_TR_LINES=""

  if [ -z "$git_fn" ] || [ -z "$base" ] || [ -z "$head" ]; then
    _gate_tr_refuse "bad-inputs" "missing git runner / base / head for the task-rapida decision"; return 1
  fi
  if [ "${GATE_LANE:-normal}" != "normal" ]; then
    _gate_tr_refuse "lane-decided" "the lane is already ${GATE_LANE} — task-rapida only ever decides for a run the fast lane did not take"; return 1
  fi
  if _gate_tr_off; then return 1; fi
  if [ "${GATE_E5_ACTIVE:-0}" = "1" ]; then
    _gate_tr_refuse "e5-active" "this run carries the E5 extra-reviewer slot — the reviewer count is the experiment's, normal gate"; return 1
  fi
  if [ -n "$policy" ]; then
    _gate_tr_refuse "policy-files" "the diff touches the gate's own policy files — normal gate"; return 1
  fi

  # the type: ONLY the word "task" is evidence. Not-readable is not "not a task" and is not a grant either.
  ty=$(printf '%s' "$bead_json" | jq -r 'if type=="array" then .[0] else . end | if type=="object" then .issue_type else null end | if type=="string" then . else "" end' 2>/dev/null) || ty=""
  if [ -z "$ty" ]; then
    _gate_tr_refuse "type-unreadable" "the type of the source bead could not be read — normal gate"; return 1
  fi
  if [ "$ty" != "task" ]; then
    _gate_tr_refuse "not-task" "the source bead is a ${ty}, not a task — normal gate"; return 1
  fi

  # the opt-out: the label gate:normal-only is how a builder asks for the normal gate (and what the short review tells a builder to add
  # when it finds the diff out of scope). No labels key / null is a bead with none; labels that are not an array of strings are a read
  # that could not be made, which is not "no opt-out". Case does not matter: the doubtful reading is the normal gate.
  lb=$(printf '%s' "$bead_json" | jq -r '(if type=="array" then .[0] else . end) as $b | ($b.labels) as $l | if $l == null then "none" elif ($l|type) != "array" then "unreadable" elif ($l | all(.[]; type=="string")) | not then "unreadable" elif ($l | map(ascii_downcase) | any(. == "gate:normal-only")) then "optout" else "none" end' 2>/dev/null) || lb=""
  case "$lb" in
    none) ;;
    optout) _gate_tr_refuse "opted-out" "the source bead carries the label gate:normal-only — normal gate"; return 1 ;;
    *) _gate_tr_refuse "labels-unreadable" "the labels of the source bead could not be read — normal gate"; return 1 ;;
  esac

  cap=$(_gate_tr_cap "${GATE_TASKRAPIDA_MAX_LINES:-}" 200 2000) || cap=""
  total_cap=$(_gate_tr_cap "${GATE_TASKRAPIDA_MAX_TOTAL_LINES:-}" 1000 20000) || total_cap=""
  if [ -z "$cap" ] || [ -z "$total_cap" ]; then
    _gate_tr_refuse "cap-invalid" "GATE_TASKRAPIDA_MAX_LINES / GATE_TASKRAPIDA_MAX_TOTAL_LINES is set to something that is not a usable cap — normal gate"; return 1
  fi

  if ! declare -F gate_e11_count_production_lines >/dev/null 2>&1; then
    _gate_tr_refuse "counter-missing" "E11's production-lines counter is not loaded (quality-gate-guard.sh) — cannot measure, normal gate"; return 1
  fi
  numstat=$("$git_fn" -c core.quotepath=off diff --numstat --no-renames "$base...$head" 2>/dev/null) || rc=$?
  if [ "$rc" != "0" ]; then
    _gate_tr_refuse "diff-failed" "git diff --numstat of the branch failed (rc=$rc) — cannot measure, normal gate"; return 1
  fi
  if [ -z "$numstat" ]; then
    _gate_tr_refuse "empty-diff" "the diff is empty — nothing here is evidence of a small task, normal gate"; return 1
  fi
  # one pass over the rows: the files (for the risk list) and the total (the bound that E11's count does not give: E11
  # leaves every .md and test out, so a 1500-line doc diff is "0 production lines"). A row that cannot be read poisons the
  # whole count — a partial sum is not a measurement.
  while IFS=$'\t' read -r add del path; do
    [ -n "$add$del$path" ] || continue
    if [ -z "$path" ]; then bad=1; break; fi
    case "$path" in \"*\") path="${path#\"}"; path="${path%\"}" ;; esac
    if [ "$add" = "-" ] && [ "$del" = "-" ]; then binary=1; paths="${paths}${path}"$'\n'; continue; fi
    case "$add" in ''|*[!0-9]*|??????????*) bad=1; break ;; esac
    case "$del" in ''|*[!0-9]*|??????????*) bad=1; break ;; esac
    total=$((total + 10#$add + 10#$del)); nfiles=$((nfiles + 1))
    paths="${paths}${path}"$'\n'
    list="${list}${path}"$'\t'"$((10#$add + 10#$del))"$'\n'
  done <<< "$numstat"
  # no file read at all (a numstat of blank lines) is not "files read, none risky": nothing was checked against the risk list
  if [ "$bad" = "1" ] || [ -z "$paths" ]; then
    _gate_tr_refuse "count-failed" "a row of the diff could not be read as a line count, or no row could be read at all — normal gate"; return 1
  fi
  prod=$(gate_e11_count_production_lines "$numstat") || prod="unknown"
  case "$prod" in ''|*[!0-9]*) prod="" ;; esac
  if [ -z "$prod" ]; then
    _gate_tr_refuse "count-failed" "E11's production-lines count could not be read — normal gate"; return 1
  fi
  GATE_TR_LINES="$prod"
  if [ "$binary" = "1" ]; then
    _gate_tr_refuse "binary-file" "the diff carries a binary file — it has no lines to count and nothing a short review can read, normal gate"; return 1
  fi
  if [ "$prod" -gt "$cap" ]; then
    _gate_tr_refuse "over-limit" "$prod production lines, over the task-rapida limit of $cap — normal gate"; return 1
  fi
  if [ "$total" -gt "$total_cap" ]; then
    _gate_tr_refuse "over-total" "$total lines in all (tests and docs included), over the task-rapida bound of $total_cap — normal gate"; return 1
  fi

  if ! _gate_tr_load_risk "$rig"; then
    _gate_tr_refuse "risk-unreadable" "${GATE_TR_RISK_WHY:-the risk list could not be loaded} — normal gate"; return 1
  fi
  hit=$(_gate_tr_risk_hit "$paths") || hit=""
  if [ -n "$hit" ]; then
    hit_path="${hit%%$'\t'*}"; hit_pat="${hit#*$'\t'}"
    _gate_tr_refuse "risk-file" "${hit_path} matches the risk list (pattern '${hit_pat}': sending messages, money or customer data) — normal gate"; return 1
  fi

  GATE_LANE="task-rapida"
  GATE_LANE_REASON_CODE="task-rapida-granted"
  GATE_LANE_REASON="task of ${prod} production lines (limit ${cap}), ${nfiles} file(s), none on the risk list (${GATE_TR_NPAT} patterns) — one short review, same merge as the normal gate"
  GATE_LANE_FILES="$list"
  GATE_LANE_COUNTS="prod=${prod} total=${total} files=${nfiles}"
  GATE_TR_CODE="granted"; GATE_TR_WHY="$GATE_LANE_REASON"
  return 0
}
