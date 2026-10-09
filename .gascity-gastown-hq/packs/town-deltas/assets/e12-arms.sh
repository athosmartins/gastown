#!/bin/bash
# e12-arms.sh — ga-4q2zo5 (E12, child of the P0 ga-ufskhy): the doctrine of WRITING, as an A/B.
#
# WHAT THIS IS. On 05/10 the 789 blocking findings of the last week were labelled by the reviewers themselves: 38% were a "third state"
# (a read that can come back empty OR fail, handled as if the two were one), 32% a comment that promises more than the code does,
# 15% a variable decided on but not the one used, 10% a test that does not exercise the path. E3 showed that one more REVIEW before the
# submission changes nothing (49% x 43% first-attempt approval, at twice the cost). The thesis here is to change how the code is
# WRITTEN: for the treated arm the builder's dispatch message carries a short block — before each new read, one comment line
# 'vazio → <what it does>; falhou/ilegível → <what it does>' (and "failed" must be the inert state), and before /gate-done a re-read of
# every comment in the diff. The control arm is the dispatch exactly as it is today.
#
# WHAT IS TO BE MEASURED: first-attempt approval per arm, the share of rejections labelled third-state / comment-promises-more, and cost
# per approved bead (the E8 meter). THIS FILE ONLY BUILDS THE DENOMINATOR — the roster below says which bead was in which arm; the
# readout that joins it to the gate's verdicts and to the cost meter is not part of this change.
#
# BORN OFF. The experiment does not exist until the Mayor writes  <city>/.gc/e12-ab.conf :
#     treated_pct=50
# and it ends when that file is removed — takes effect on the next dispatch, no reload. A comment (#) and blank lines are allowed.
# Only treated_pct is a key, and it must be 1..100: a typo'd key, 0, an empty or comment-only file, or a conf that cannot be read is
# INVALID — it hands nothing out and says so (exit 6) — never "no conf". An empty file is what a failed write leaves behind (the disk
# has been near full), and that must not switch an experiment on at a default.
#
# THREE STATES, NEVER TWO. Every read that can be missing has three answers and they are never collapsed: there is a value / there is
# not / it could not be determined. Here: no conf (the experiment is legitimately off) / a bead in the control arm / "could not tell"
# (no hash tool, roster unreadable, roster unwritable, conf invalid). "Could not tell" never prints `treated`, and it never prints
# `control` either: a bead with no arm is not in the experiment.
#
# Arm recipe (recomputable by anyone):  bucket = first 32 bits of SHA-256("e12-write-3state:<bead-id>") mod 100;
#   treated <=> bucket < treated_pct.   e.g.  printf '%s' "e12-write-3state:ga-abc123" | shasum -a 256 | cut -c1-8
# The salt is part of the hashed string on purpose: E3's arm is the parity of SHA-256("pregate:<id>") and E9's another salted bucket;
# two experiments over the same beads must not be one coin (the selftest measures this arm against E3's).
#
# ONE ASSIGNMENT PER BEAD. The first assignment is recorded in <city>/.gc/e12-roster.jsonl and every later call prints THAT arm,
# whatever treated_pct says now — recomputing instead would let a pct ramp (canary → 50%) flip a re-dispatched bead (gate-rejected, then
# slung again) while the roster counts it under its first arm: the variable decided on must be the variable acted on. Control beads get
# a row too — a control with no denominator is not a control. A bead that is recorded but never actually dispatched (parked, refused
# by another guard) is a row with no gate outcome: whoever builds the readout has to join the roster to the gate's verdicts and drop
# the rows that have none.
#
# Commands (exit codes are part of the contract; the one real caller, the Pilot, discards stderr and logs a non-zero exit):
#   state                                   prints absent | invalid:<why> | active treated_pct=<N>
#   arm <bead-id>                           prints treated | control. PURE: no roster, ignores recorded rows. exit 4 = no conf (no experiment
#                                           is NOT "control"), 2 = empty id / invalid conf, 3 = no sha256 tool (prints nothing)
#   assign <bead-id> [store] [stage]        WRITES the roster. Prints the bead's arm (recorded one wins), or NOTHING when there is no conf
#                                           (exit 0: legitimately off). exit 2 = the arguments are not that shape (see below), 3 = no arm
#                                           could be determined, 5 = arm decided but NOT recorded (roster unwritable), 6 = the conf is
#                                           INVALID. Every non-zero exit prints nothing on stdout.
#   block <bead-id> [store] [stage] [--no-record]
#                                           assign, then print the write-time doctrine block ONLY for a treated bead (nothing for control
#                                           or when off). Same exits as assign. --no-record is for a dry run: nothing is written, the
#                                           recorded arm (else the pure arm) decides — looking at a bead must not enrol it.
# Arguments (assign and block): --no-record, which only block takes, may stand ANYWHERE in the list — it is an option, taken out before
# the positionals are counted, so `block <id> --no-record` is a dry run with no store. Any other word that starts with '-', and a 4th
# positional, is refused with exit 2 and nothing written, never filed into a field of the roster row. An empty word keeps its slot.
#
# Safe to source under `set -e` / `set -u` (the selftest does exactly that, section 8): every command substitution whose non-zero status is
# an ANSWER ("no row" is rc 1, "cannot be read" rc 3) is captured with `|| rc=$?`, never `x="$(…)"; rc=$?`, which `set -e` turns into an
# abort on the ordinary first-sight case. Today the only caller, the Pilot, runs it as a child process. The one `exit` is the last line and
# runs only when the file is executed, never when it is sourced.

E12_SALT="e12-write-3state"

e12_city() { printf '%s' "${GC_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}"; }
e12_state_dir() { printf '%s' "${E12_STATE_DIR:-$(e12_city)/.gc}"; }
e12_roster() { printf '%s' "$(e12_state_dir)/e12-roster.jsonl"; }

# ── conf ──────────────────────────────────────────────────────────────────────────────────────────────────────
# Sets E12_PCT, E12_PARSE (absent | ok | invalid:<why>) and E12_STATE (absent | invalid:<why> | active). It PRINTS NOTHING and callers
# must not wrap it in $(...): a subshell would throw the values away. Never exits.
e12_conf_load() {
  E12_PCT=0; E12_PARSE=absent; E12_STATE=absent
  local conf line key val seen=0
  conf="$(e12_state_dir)/e12-ab.conf"
  # -e follows symlinks: a symlink whose target is gone is NOT absent, it is there and cannot be read (-> invalid:not-a-file below)
  [ -e "$conf" ] || [ -L "$conf" ] || return 0
  E12_PARSE=ok
  if [ ! -f "$conf" ]; then E12_PARSE="invalid:not-a-file"
  elif [ ! -r "$conf" ]; then E12_PARSE="invalid:unreadable"; fi
  while [ "$E12_PARSE" = ok ] && { IFS= read -r line || [ -n "$line" ]; }; do
    line="${line%%#*}"
    # trim both ends (bash 3.2: no ${var,,}, no extglob assumptions)
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in *=*) ;; *) E12_PARSE="invalid:no-equals:$line"; break ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      treated_pct)
        case "$val" in ''|*[!0-9]*) E12_PARSE="invalid:treated_pct=$val"; break ;; esac
        if [ "${#val}" -gt 3 ] || [ "$((10#$val))" -gt 100 ] || [ "$((10#$val))" -lt 1 ]; then E12_PARSE="invalid:treated_pct=$val"; break; fi
        E12_PCT=$((10#$val)); seen=1 ;;
      *) E12_PARSE="invalid:unknown-key:$key"; break ;;
    esac
  done < "$conf"
  if [ "$E12_PARSE" = ok ] && [ "$seen" = 0 ]; then E12_PARSE="invalid:no-treated_pct"; fi
  case "$E12_PARSE" in ok) E12_STATE=active ;; *) E12_STATE="$E12_PARSE" ;; esac
}

# e12_state_gate — what a command that hands out an arm does with the conf's state (call after e12_conf_load):
#   0  active    carry on
#   1  absent    the experiment is legitimately OFF: the caller prints nothing and exits 0
#   6  invalid   the conf exists but cannot be used: the experiment is NOT running and nobody chose that. Said on stderr AND by the exit
#                code — the one real caller discards stderr and logs only a non-zero exit.
e12_state_gate() {
  case "$E12_STATE" in
    active) return 0 ;;
    absent) return 1 ;;
    *)      echo "e12: the experiment config is unusable ($E12_STATE) — no arm is handed out, the experiment is NOT running; fix or remove $(e12_state_dir)/e12-ab.conf" >&2
            return 6 ;;
  esac
}

e12_cmd_state() {
  e12_conf_load
  if [ "$E12_STATE" = active ]; then echo "active treated_pct=$E12_PCT"; else echo "$E12_STATE"; fi
}

# ── arm ───────────────────────────────────────────────────────────────────────────────────────────────────────
# First 8 hex digits of SHA-256(<string>), or return 3 (prints nothing) when no tool works. Fast C tools first: shasum is a perl script
# (~0.1 s a call under load). E12_SHA_TOOLS (space-separated: sha256sum openssl shasum) exists so the selftest can take tools away and see
# the third state.
e12_sha8() {
  local d t
  for t in ${E12_SHA_TOOLS:-sha256sum openssl shasum}; do
    d=""
    case "$t" in
      sha256sum) command -v sha256sum >/dev/null 2>&1 && d="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-8)" ;;
      openssl)   command -v openssl   >/dev/null 2>&1 && d="$(printf '%s' "$1" | openssl dgst -sha256 -r 2>/dev/null | cut -c1-8)" ;;
      shasum)    command -v shasum    >/dev/null 2>&1 && d="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-8)" ;;
    esac
    case "$d" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$d"; return 0 ;; esac
  done
  return 3
}

e12_bad_bead_id() { case "${1:-}" in ''|*[[:space:]]*) return 0 ;; esac; return 1; }

# e12_arm_for <bead-id> → treated|control. Uses E12_PCT as left by e12_conf_load (callers load first).
e12_arm_for() {
  local d
  e12_bad_bead_id "${1:-}" && return 2
  d="$(e12_sha8 "$E12_SALT:$1")" || return 3
  if [ "$(( 16#$d % 100 ))" -lt "$E12_PCT" ]; then echo treated; else echo control; fi
}

e12_cmd_arm() {
  e12_conf_load
  case "$E12_PARSE" in
    absent)    echo "e12: no e12-ab.conf — there is no experiment, so no arm (not 'control')" >&2; return 4 ;;
    invalid:*) echo "e12: $E12_PARSE" >&2; return 2 ;;
  esac
  e12_arm_for "${1:-}"
}

# ── roster ────────────────────────────────────────────────────────────────────────────────────────────────────
# e12_record <bead> <store> <arm> <stage> — one JSON line, built by jq so a path or a "quote" can never corrupt the file. rc 0 = the row is
# in the roster on a line of its own; rc 3 = it is not (a failing append can itself leave a short fragment; the next call seals it, below).
# A write that stopped short (disk near full, a killed process) leaves a fragment with NO newline — the newline is the last byte of a row.
# A bare append would glue this row onto that fragment: one unparseable line, reported as success, the bead treated in the builder's prompt
# and missing from the roster. So when the file's last byte is not a newline the row is written with a newline in front, in the same
# printf as the row (not a seal followed by an append). The last byte has three answers, never two: a newline / something else / could not
# be read — the third is a failed record, never "looks fine". It is read with od, not $(tail -c1): command substitution drops a NUL, and a
# tail ending in NUL is what some filesystems leave after a crash. An existing path that is not a regular file (a dangling symlink,
# a directory) is refused up front, so the append cannot create a target out of nothing.
e12_record() {
  local r row lead="" last lrc=0
  command -v jq >/dev/null 2>&1 || return 3
  mkdir -p "$(e12_state_dir)" 2>/dev/null || return 3
  r="$(e12_roster)"
  row="$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bead "$1" --arg store "$2" --arg salt "$E12_SALT" --arg arm "$3" \
    --argjson pct "$E12_PCT" --arg stage "$4" \
    '{ts:$ts,event:"assign",bead:$bead,store:$store,salt:$salt,arm:$arm,treated_pct:$pct} + (if $stage == "" then {} else {stage:$stage} end)' \
    2>/dev/null)" || return 3
  [ -n "$row" ] || return 3
  if [ -e "$r" ] || [ -L "$r" ]; then
    [ -f "$r" ] || return 3
    if [ -s "$r" ]; then
      last="$(tail -c1 "$r" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" || lrc=$?
      [ "$lrc" -eq 0 ] || return 3
      case "$last" in
        0a)                   ;;
        [0-9a-f][0-9a-f])     lead=$'\n' ;;
        *)                    return 3 ;;
      esac
    fi
  fi
  printf '%s%s\n' "$lead" "$row" >> "$r" 2>/dev/null || return 3
}

# e12_recorded_arm <bead> — the arm the ROSTER holds for this bead under this salt (the first assignment wins). Three answers:
#   rc 0  prints treated|control   the roster has a row for it
#   rc 1  prints nothing           there is no row (no roster file, or a readable roster without one) — the only case where an arm may be COMPUTED
#   rc 3  prints nothing           it cannot be told: jq is missing (checked first — with no jq a row can be neither read nor written, whether
#                                  or not the roster file exists yet), the roster exists but cannot be read (a dangling symlink included —
#                                  -e alone would call it "no roster"), or the row's arm is not treated|control
# A line that is not a JSON object (a truncated write) is skipped, not fatal: one bad line must not make every bead look unassigned.
# The ROW: prefix is what tells "a row without an arm" from "no row".
e12_recorded_arm() {
  local r out rc first; r="$(e12_roster)"
  command -v jq >/dev/null 2>&1 || return 3
  [ -e "$r" ] || [ -L "$r" ] || return 1
  { [ -f "$r" ] && [ -r "$r" ]; } || return 3
  rc=0
  out="$(jq -R -r --arg b "$1" --arg s "$E12_SALT" \
    'try fromjson catch empty | select(type=="object" and .event=="assign" and .bead==$b and .salt==$s) | "ROW:" + ((.arm // "") | tostring)' "$r" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 3
  [ -n "$out" ] || return 1
  first="${out%%$'\n'*}"; first="${first#ROW:}"
  case "$first" in treated|control) printf '%s' "$first"; return 0 ;; *) return 3 ;; esac
}

# e12_resolve <bead> <store> <stage> <record:1|0> — sets E12_ARM (treated|control, or EMPTY when the experiment is off) and returns the
# exit code of the contract above: 0, 3, 5 or 6. Not for $(...): the global is the result.
e12_resolve() {
  local bead="${1:-}" store="${2:-}" stage="${3:-}" record="${4:-1}" g=0 rec rrc arm
  E12_ARM=""
  e12_conf_load
  e12_state_gate || g=$?
  case "$g" in 0) ;; 1) return 0 ;; *) return "$g" ;; esac
  if e12_bad_bead_id "$bead"; then echo "e12: cannot assign an arm to '$bead'" >&2; return 3; fi
  rrc=0; rec="$(e12_recorded_arm "$bead")" || rrc=$?
  case "$rrc" in
    0) E12_ARM="$rec"; return 0 ;;
    1) ;;
    *) echo "e12: the roster cannot be read (unreadable, or jq is missing), so it cannot be told whether '$bead' was already assigned — no arm (not a recompute)" >&2; return 3 ;;
  esac
  arm="$(e12_arm_for "$bead")" || { echo "e12: cannot assign an arm to '$bead' (no sha256 tool?)" >&2; return 3; }
  if [ "$record" = 1 ]; then
    e12_record "$bead" "$store" "$arm" "$stage" || { echo "e12: WARN: assignment for $bead NOT recorded (roster unwritable, or not in a state a row can safely be appended to) — no arm handed out" >&2; return 5; }
  fi
  E12_ARM="$arm"
  return 0
}

# e12_parse_args <accept-no-record:1|0> <args…> — the shape of assign and block: <bead-id> [store] [stage], and for block alone --no-record.
# Sets E12_A_BEAD, E12_A_STORE, E12_A_STAGE and E12_A_RECORD (1, or 0 when --no-record was given). Not for $(...): the globals are the result.
# rc 0 = parsed; rc 2 = the arguments are not that shape — and nothing has been written, because nothing has been resolved yet.
# --no-record is an OPTION, so it is taken out of the whole list before the positionals are counted, wherever it stands. Read by position
# (the first two words are bead and store, the rest are options) it turned into the store whenever the store was left out: `block <id>
# --no-record` printed the block AND enrolled the bead, with {"store":"--no-record"} — a dry run that mutates, and the first assignment is
# sticky. Any other word that starts with '-' is refused rather than filed into a field of the roster row, and so is a 4th positional
# (assign used to drop it, block let it replace the stage): the roster is the denominator and a row with a flag in it is a row nobody can
# trust. An empty word is a value, not a missing one — the Pilot can pass an empty store — so it keeps its slot.
e12_parse_args() {
  local accept="$1" a n=0
  shift
  E12_A_BEAD=""; E12_A_STORE=""; E12_A_STAGE=""; E12_A_RECORD=1
  for a in "$@"; do
    if [ "$a" = "--no-record" ] && [ "$accept" = 1 ]; then E12_A_RECORD=0; continue; fi
    case "$a" in
      -*) echo "e12: '$a' is not an argument this command takes (a word that starts with '-' is never a bead id, a store or a stage) — nothing was written" >&2; return 2 ;;
    esac
    n=$((n+1))
    case "$n" in
      1) E12_A_BEAD="$a" ;;
      2) E12_A_STORE="$a" ;;
      3) E12_A_STAGE="$a" ;;
      *) echo "e12: too many arguments (expected <bead-id> [store] [stage]) — nothing was written" >&2; return 2 ;;
    esac
  done
  return 0
}

e12_cmd_assign() {
  local rc=0
  e12_parse_args 0 "$@" || return $?
  e12_resolve "$E12_A_BEAD" "$E12_A_STORE" "$E12_A_STAGE" 1 || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$E12_ARM" ] && printf '%s\n' "$E12_ARM"
  return "$rc"
}

# ── the block ─────────────────────────────────────────────────────────────────────────────────────────────────
# Short (the spec: <= 10 lines), no shouting, with the why: the guide for the current models says a clear reason generalises better than
# capital letters. The header line is what the Pilot checks before it appends the text to a dispatch.
# The named crews read this SAME text, not a copy typed by hand: e12-crew-doctrine.sh writes it between the e12-doctrine:begin/end marker
# comments of their six prompt templates (agents/{thies,oracle,digo,mila,peter,batista}-wa/prompt.template.md, ga-0nz1wi). After editing
# the text below, run `bash e12-crew-doctrine.sh write`; e12-crew-doctrine.selftest.sh fails for as long as a prompt differs from it.
e12_block_text() {
  cat <<'E12BLOCK'
## Write-time doctrine — experiment E12 (ga-4q2zo5)
- Why: in last week's gate reviews, 38% of the blocking findings were one mistake — a read that can come back empty or fail was handled as if both meant the same thing.
- Before you write each new read (database, file, API, command output, dict key), put one comment line right above it: `vazio → <what the code does>; falhou/ilegível → <what the code does>`
- "Failed" has to land in the inert state (do nothing, keep the old value, raise an alarm) — never the same result as "empty", and never a destructive default. If you cannot fill in both halves, decide first, then write the read.
- A read that has not answered yet is a third state too (it showed up twice in UI slices this week): while it is pending, draw "Carregando…" — never the empty verdict ("Nada por aqui ainda.") — and put a timeout on the request that lands in the error state, so a read that never answers cannot leave "nobody" on the screen for good.
- Before /gate-done, re-read every comment in your own diff and ask "does the code next to it do exactly this?" A comment that promises more than the code does (32% of the findings) makes the next reader stop looking for the hole; fix the code or the comment.
E12BLOCK
}

e12_cmd_block() {
  local rc=0
  e12_parse_args 1 "$@" || return $?
  e12_resolve "$E12_A_BEAD" "$E12_A_STORE" "$E12_A_STAGE" "$E12_A_RECORD" || rc=$?
  [ "$rc" -eq 0 ] && [ "$E12_ARM" = treated ] && e12_block_text
  return "$rc"
}

e12_main() {
  local cmd="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$cmd" in
    state)  e12_cmd_state ;;
    arm)    e12_cmd_arm "$@" ;;
    assign) e12_cmd_assign "$@" ;;
    block)  e12_cmd_block "$@" ;;
    *)      echo "usage: e12-arms.sh state | arm <bead-id> | assign <bead-id> [store] [stage] | block <bead-id> [store] [stage] [--no-record]" >&2
            return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then e12_main "$@"; exit $?; fi
