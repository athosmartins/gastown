#!/usr/bin/env bash
# gate-rea-check.lib.sh — ga-jdzri9: the gate asks for a `REA:` comment when a diff touches a scraper (epic ga-oe7o1p).
#
# WHY. The REA rule is "whoever touches how we read an outside source leaves one comment on the bead: a line starting `REA:` with the target,
# the command, found / not found and why — never a token, cookie, JWT or CPF/CNPJ". The gate's reviewers see the file list and the first 800
# diff lines, not the bead's comments, so without a mechanical check the rule is prose.
#
# WHAT. For a marker whose rig has entries in config/rea_paths.txt and whose diff touches one of them, look at the SOURCE bead's comments
# (gate-rea-comments.py): a comment with a `REA:` line must exist, and the LATEST such comment must not have the shape of a credential or a
# CPF/CNPJ. Verdict (GATE_REA_VERDICT):
#   off      the switch is off              na       no changed file is on the rig's list (or the rig has none)
#   pass     answered and clean             missing  touches the list, no comment answers
#   secret   the latest REA comment has a credential / CPF / CNPJ shape
#   unknown  could not tell (list, comments, scanner or bead id unreadable) — the inert state, same outcome as `na`, but said out loud
# Two moments use it. Step 5 of the dispatcher (gate_rea_step5): label + ONE comment on the bead, in both phases, so the author can fix it
# while the reviewers work. gate_finalize_run (gate_rea_finalize_block): in the enforce phase only, a PASS becomes a FAIL of class `hold`
# (adding a comment does not change the commit, so the same SHA may pass afterwards). It recomputes — Phase C can run in a later process.
#
# PHASES. warn for GATE_REA_WARN_DAYS (14) counted from the first time this check ever ran (the stamp file, written by the first call), then
# enforce. A stamp or a day count that cannot be read keeps the phase at warn: "could not tell" never blocks.
# SWITCH. GATE_REA_CHECK=1|0 (env wins; any other non-empty value is OFF and said so), else the file $GC_CITY/.gc/gate-rea-check.off (exists = off).
#
# THE THIRD STATE. Every read has three answers. No `REA:` comment is `missing`; a comment list that could not be read, or holds an element
# whose text cannot be read while none answers, is `unknown` — never `missing`. A secret scan that could not run is `unknown` — never `pass`.
# Under doubt nothing is written to a bead and nothing blocks. Matched secret VALUES are never logged, only the shape names.
#
# LABELS. rea:missing / rea:secret-in-comment are a RECORD that the check fired on this bead (written once, with the comment); they are not live
# state. Adding the REA comment does not remove them, and nothing reads them back: every verdict is recomputed from the bead's comments.
# KNOWN LIMIT. The enforce-phase FAIL goes through the dispatcher's generic FAIL path, so it consumes one gate:fix-attempt slot (the `hold` class
# stamp keeps the same SHA from being refused, it does not skip the counter). That is kept on purpose: the counter is what bounds the loop - a
# bead that keeps arriving without the comment reaches GATE_FIX_CAP and is escalated, instead of cycling for ever (the no-eval exemption, which
# leaves the counter alone, is for runs where no reviewer judged anything, and it raises its own alert; this is not that).
# Source-only: defines functions and runs NOTHING at source time. The dispatcher is `set -euo pipefail` on bash 3.2: no arrays, no ${v,,},
# every command that may fail is guarded, every function returns 0 (results travel in the GATE_REA_* globals).
GATE_REA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || GATE_REA_DIR=""

# gate_rea_switch_state — prints on | off | env-invalido (an override nobody can read is OFF, not "no override").
gate_rea_switch_state() {
  case "${GATE_REA_CHECK:-}" in
    1) printf 'on'; return 0 ;;
    0) printf 'off'; return 0 ;;
    '') ;;
    *) printf 'env-invalido'; return 0 ;;
  esac
  local flag="${GATE_REA_OFF_FLAG:-${GC_CITY:-}/.gc/gate-rea-check.off}"
  if [ -e "$flag" ] || [ -L "$flag" ]; then printf 'off'; else printf 'on'; fi
  return 0
}

# gate_rea_phase — sets GATE_REA_PHASE (warn | enforce), GATE_REA_ENFORCE_AT (epoch, empty if unknown), GATE_REA_PHASE_WHY.
gate_rea_phase() {
  local stamp="${GATE_REA_STAMP_FILE:-${GC_CITY:-}/.gc/gate-rea-warn-since}" days="${GATE_REA_WARN_DAYS:-14}" now since=""
  GATE_REA_PHASE="warn"; GATE_REA_ENFORCE_AT=""; GATE_REA_PHASE_WHY=""
  case "$days" in ''|*[!0-9]*|?????*) GATE_REA_PHASE_WHY="GATE_REA_WARN_DAYS is not a whole number of days (up to 4 digits) - staying in warn"; return 0 ;; esac
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in ''|*[!0-9]*) GATE_REA_PHASE_WHY="the clock could not be read - staying in warn"; return 0 ;; esac
  if [ ! -e "$stamp" ] && [ ! -L "$stamp" ]; then
    mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
    if printf '%s\n' "$now" > "$stamp.tmp.$$" 2>/dev/null && mv "$stamp.tmp.$$" "$stamp" 2>/dev/null; then
      since="$now"
    else
      rm -f "$stamp.tmp.$$" 2>/dev/null || true
      GATE_REA_PHASE_WHY="the start of the warn window could not be recorded ($stamp) - staying in warn"; return 0
    fi
  else
    since=$(head -n 1 "$stamp" 2>/dev/null | tr -d '[:space:]') || since=""
  fi
  case "$since" in ''|*[!0-9]*|???????????*) GATE_REA_PHASE_WHY="the warn-window stamp $stamp is unreadable - staying in warn"; return 0 ;; esac
  GATE_REA_ENFORCE_AT=$((since + days * 86400))
  if [ "$now" -ge "$GATE_REA_ENFORCE_AT" ]; then GATE_REA_PHASE="enforce"; fi
  return 0
}

# gate_rea_paths_match <rig> <changed files, one per line> — sets GATE_REA_MATCHED_LIST (the changed files on <rig>'s list, one per line) and
# GATE_REA_PATHS_SKIPPED (list lines that were not `<rig> <glob>`). rc 0 = the list was read (the match list may be empty: nothing matched),
# rc 2 = the list is missing or unreadable. Called bare, never inside $(...): the globals would die with the subshell. The list is read ONCE into
# a variable, so a loop's own last status can never be mistaken for "unreadable".
gate_rea_paths_match() {
  local rig="${1:-}" files="${2:-}" list="${GATE_REA_PATHS_FILE:-${GC_CITY:-}/config/rea_paths.txt}"
  local content line lrig lpat rest pats="" f p
  GATE_REA_MATCHED_LIST=""; GATE_REA_PATHS_SKIPPED=0
  [ -f "$list" ] || return 2
  content=$(cat "$list" 2>/dev/null) || return 2
  while IFS= read -r line; do
    line="${line%%#*}"
    lrig=""; lpat=""; rest=""
    IFS=$' \t' read -r lrig lpat rest <<< "$line" || true
    [ -n "$lrig" ] || continue
    if [ -z "$lpat" ] || [ -n "$rest" ]; then GATE_REA_PATHS_SKIPPED=$((GATE_REA_PATHS_SKIPPED + 1)); continue; fi
    if [ "$lrig" = "$rig" ]; then pats="${pats}${lpat}"$'\n'; fi
  done <<< "$content"
  [ -n "$pats" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in \"*\") f="${f#\"}"; f="${f%\"}" ;; esac   # git quotes odd names; the directory prefix is ASCII, which is what the globs name
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2254 — $p is meant as a glob
      case "$f" in $p) GATE_REA_MATCHED_LIST="${GATE_REA_MATCHED_LIST}${f}"$'\n'; break ;; esac
    done <<< "$pats"
  done <<< "$files"
  return 0
}

# gate_rea_comments_state <bead_city> <bead_id> — sets GATE_REA_COMMENTS (present | missing | secret | unknown), GATE_REA_COMMENT_ID (the
# latest REA comment), GATE_REA_SHAPES (its shapes), GATE_REA_NOTE (an EARLIER REA comment had a shape; the latest is what counts), GATE_REA_WHY.
gate_rea_comments_state() {
  local city="${1:-}" bead="${2:-}" scan="${GATE_REA_DIR:-}/gate-rea-comments.py" json="" rows="" rc=0 id shapes
  GATE_REA_COMMENTS="unknown"; GATE_REA_COMMENT_ID=""; GATE_REA_SHAPES=""; GATE_REA_NOTE=""; GATE_REA_WHY=""
  [ -n "$bead" ] || { GATE_REA_WHY="no source bead id"; return 0; }
  [ -r "$scan" ] || { GATE_REA_WHY="the comment scanner $scan is missing or unreadable"; return 0; }
  json=$(bd -C "$city" comments "$bead" --json 2>/dev/null) || { GATE_REA_WHY="bd comments $bead failed"; return 0; }
  [ -n "$json" ] || { GATE_REA_WHY="bd comments $bead returned nothing"; return 0; }
  rows=$(printf '%s' "$json" | python3 "$scan" 2>/dev/null) || rc=$?
  if [ "$rc" != "0" ]; then GATE_REA_WHY="the comment list of $bead could not be read (scanner rc=$rc)"; return 0; fi
  if [ -z "$rows" ]; then GATE_REA_COMMENTS="missing"; return 0; fi
  while IFS=$'\t' read -r id shapes; do
    [ -n "$id" ] || continue
    if [ -n "$GATE_REA_COMMENT_ID" ] && [ "$GATE_REA_SHAPES" != "-" ]; then GATE_REA_NOTE="the earlier REA comment $GATE_REA_COMMENT_ID has the shape of: $GATE_REA_SHAPES"; fi
    GATE_REA_COMMENT_ID="$id"; GATE_REA_SHAPES="${shapes:--}"
  done <<< "$rows"
  if [ -z "$GATE_REA_COMMENT_ID" ]; then GATE_REA_WHY="the scanner output could not be read"; return 0; fi
  if [ "$GATE_REA_SHAPES" = "-" ]; then GATE_REA_COMMENTS="present"; else GATE_REA_COMMENTS="secret"; fi
  return 0
}

# gate_rea_check <rig> <bead_city> <bead_id> <changed files> — the decision. Resets every output first, so a stale verdict never leaks between runs.
# Outputs: GATE_REA_VERDICT GATE_REA_PHASE GATE_REA_DETAIL GATE_REA_MATCHED GATE_REA_FIRST (+ the ones set by the helpers above).
gate_rea_check() {
  local rig="${1:-}" city="${2:-}" bead="${3:-}" files="${4:-}" sw rc=0
  GATE_REA_VERDICT="off"; GATE_REA_DETAIL=""; GATE_REA_MATCHED=0; GATE_REA_FIRST=""; GATE_REA_PHASE="warn"; GATE_REA_ENFORCE_AT=""; GATE_REA_PHASE_WHY=""
  GATE_REA_COMMENTS=""; GATE_REA_COMMENT_ID=""; GATE_REA_SHAPES=""; GATE_REA_NOTE=""; GATE_REA_WHY=""; GATE_REA_PATHS_SKIPPED=0; GATE_REA_MATCHED_LIST=""
  sw=$(gate_rea_switch_state 2>/dev/null) || sw=""
  case "$sw" in
    on) ;;
    off) return 0 ;;
    *) GATE_REA_DETAIL="the switch could not be read (GATE_REA_CHECK='${GATE_REA_CHECK:-}') - the check is OFF"; return 0 ;;
  esac
  gate_rea_phase
  gate_rea_paths_match "$rig" "$files" || rc=$?
  if [ "$rc" != "0" ]; then GATE_REA_VERDICT="unknown"; GATE_REA_DETAIL="the REA path list is missing or unreadable"; return 0; fi
  if [ -z "$GATE_REA_MATCHED_LIST" ]; then GATE_REA_VERDICT="na"; return 0; fi
  GATE_REA_MATCHED=$(printf '%s' "$GATE_REA_MATCHED_LIST" | grep -c . || true)
  GATE_REA_FIRST=$(printf '%s' "$GATE_REA_MATCHED_LIST" | head -n 1 || true)
  gate_rea_comments_state "$city" "$bead"
  case "$GATE_REA_COMMENTS" in
    present) GATE_REA_VERDICT="pass" ;;
    missing) GATE_REA_VERDICT="missing" ;;
    secret)  GATE_REA_VERDICT="secret"; GATE_REA_DETAIL="comment $GATE_REA_COMMENT_ID has the shape of: $GATE_REA_SHAPES" ;;
    *)       GATE_REA_VERDICT="unknown"; GATE_REA_DETAIL="$GATE_REA_WHY" ;;
  esac
  return 0
}

# gate_rea_when — the enforce date as YYYY-MM-DD, or the phrase "the end of the warn window" when it cannot be computed.
gate_rea_when() {
  local d=""
  [ -n "${GATE_REA_ENFORCE_AT:-}" ] && d=$(date -u -r "$GATE_REA_ENFORCE_AT" +%Y-%m-%d 2>/dev/null) || d=""
  printf '%s' "${d:-the end of the warn window}"
  return 0
}

# gate_rea_text <kind> <branch> <bead> — the words for the bead. No line of it may START with `REA:` (that would answer the rule by itself); one line, no backslashes.
gate_rea_text() {
  local kind="${1:-}" branch="${2:-}" bead="${3:-}" when how
  when=$(gate_rea_when)
  if [ "${GATE_REA_PHASE:-warn}" = "enforce" ]; then how="the gate refuses the PASS until this is fixed"; else how="a warning until $when, after that the gate refuses the PASS"; fi
  case "$kind" in
    secret) printf 'REA-CHECK (ga-jdzri9, %s): the latest REA comment (%s) on %s has the shape of: %s. Comments cannot be edited: add a NEW comment whose first line starts with REA: and says the same without the value. If a real credential or a person number was exposed, tell the Mayor so it is rotated.' "$how" "${GATE_REA_COMMENT_ID:-?}" "$bead" "${GATE_REA_SHAPES:-?}" ;;
    *)      printf 'REA-CHECK (ga-jdzri9, %s): branch %s changes %s file(s) on the REA path list (first: %s) but %s has no comment with a line starting with REA: . Add one - target, command, found or not found and why; no token, cookie, JWT or CPF/CNPJ - with: bd comments add %s "REA: ..." . A change that is not a source investigation needs only: REA: n/a - the reason.' "$how" "$branch" "${GATE_REA_MATCHED:-?}" "${GATE_REA_FIRST:-?}" "$bead" "$bead" ;;
  esac
  return 0
}

# gate_rea_mark <bead_city> <bead_id> <label> <comment> — ONE comment per bead and label: if the label is there, nothing; else the comment FIRST and the label
# after it (a failed comment leaves no label, so the next sweep tries again). Prints done | already | unreadable | failed.
gate_rea_mark() {
  local city="${1:-}" bead="${2:-}" label="${3:-}" text="${4:-}" json="" has=""
  [ -n "$bead" ] || { printf 'unreadable'; return 0; }
  json=$(bd -C "$city" show "$bead" --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  has=$(printf '%s' "$json" | jq -r --arg l "$label" 'if type=="array" then .[0] else . end | if ((.labels // []) | index($l)) != null then "yes" else "no" end' 2>/dev/null) || has=""
  case "$has" in
    yes) printf 'already'; return 0 ;;
    no) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  bd -C "$city" comment "$bead" "$text" >/dev/null 2>&1 || { printf 'failed'; return 0; }
  bd -C "$city" label add "$bead" "$label" -q >/dev/null 2>&1 || { printf 'failed'; return 0; }
  printf 'done'
  return 0
}

# gate_rea_event <branch> <marker> <where> — one record for the apuração, to $QG_LOG when it is set. The shapes, never the values.
gate_rea_event() {
  [ -n "${QG_LOG:-}" ] || return 0
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg branch "${1:-}" --arg marker "${2:-}" --arg at "${3:-}" --arg bead "${GATE_REA_BEAD:-}" \
    --arg rig "${GATE_REA_RIG:-}" --arg verdict "$GATE_REA_VERDICT" --arg phase "$GATE_REA_PHASE" --arg matched "$GATE_REA_MATCHED" \
    --arg shapes "${GATE_REA_SHAPES:-}" --arg skipped "${GATE_REA_PATHS_SKIPPED:-0}" --arg detail "${GATE_REA_DETAIL:-}" \
    '{ts:$ts,event:"rea_check",at:$at,branch:$branch,marker:$marker,bead:$bead,rig:$rig,verdict:$verdict,phase:$phase,matched:$matched,shapes:$shapes,skipped:$skipped,detail:$detail}' \
    >> "$QG_LOG" 2>/dev/null || true
  return 0
}

# gate_rea_say <message> — into the dispatcher log when it has log/warn, else stderr.
gate_rea_say() {
  if type warn >/dev/null 2>&1; then warn "$1"; else printf '%s\n' "$1" >&2; fi
  return 0
}

# gate_rea_step5 <rig> <bead_city> <bead_id> <changed files> <branch> <marker> — the early moment: decide, write the label + comment (once), record.
gate_rea_step5() {
  local label="" kind="" got="" text=""
  GATE_REA_BEAD="${3:-}"; GATE_REA_RIG="${1:-}"
  gate_rea_check "$1" "$2" "$3" "$4"
  case "$GATE_REA_VERDICT" in
    na) return 0 ;;
    off) [ -n "$GATE_REA_DETAIL" ] && gate_rea_say "REA check: $GATE_REA_DETAIL"; return 0 ;;
    pass) gate_rea_say "REA check: ${GATE_REA_MATCHED} file(s) on the REA list, REA comment ${GATE_REA_COMMENT_ID} is clean (phase=$GATE_REA_PHASE)." ;;
    missing) label="rea:missing"; kind="missing" ;;
    secret)  label="rea:secret-in-comment"; kind="secret" ;;
    *) gate_rea_say "REA check: COULD NOT TELL (${GATE_REA_DETAIL:-no reason}) for ${3:-?} - nothing written, nothing blocked." ;;
  esac
  if [ -n "$label" ]; then
    text=$(gate_rea_text "$kind" "$5" "$3")
    got=$(gate_rea_mark "$2" "$3" "$label" "$text") || got="failed"
    gate_rea_say "REA check: ${GATE_REA_VERDICT} on ${3:-?} (phase=$GATE_REA_PHASE, ${GATE_REA_MATCHED} file(s), first ${GATE_REA_FIRST}) - $label: $got. $GATE_REA_PHASE_WHY"
  fi
  [ -n "$GATE_REA_NOTE" ] && gate_rea_say "REA check: on ${3:-?}, $GATE_REA_NOTE."
  gate_rea_event "${5:-}" "${6:-}" "step5"
  return 0
}

# gate_rea_finalize_block <rig> <bead_city> <bead_id> <changed files> <branch> — the late moment. Sets GATE_REA_BLOCK_REASON (empty = no block). Only the
# enforce phase blocks, only on `missing` / `secret`; `unknown`, `na`, `pass`, `off` and the warn phase never do.
gate_rea_finalize_block() {
  GATE_REA_BLOCK_REASON=""
  GATE_REA_BEAD="${3:-}"; GATE_REA_RIG="${1:-}"
  gate_rea_check "$1" "$2" "$3" "$4"
  if [ "$GATE_REA_PHASE" = "enforce" ]; then
    case "$GATE_REA_VERDICT" in
      missing) GATE_REA_BLOCK_REASON="REA check (ga-jdzri9): branch ${5:-?} changes ${GATE_REA_MATCHED} file(s) on the REA path list (first: ${GATE_REA_FIRST}) but the source bead ${3:-?} has no comment with a line starting with REA: . Add one (target, command, found or not found, why; no token, cookie, JWT or CPF/CNPJ) or, if this change is not a source investigation, the single line REA: n/a - the reason; then run /gate-done again. This is not a code rejection: the same commit can pass once the comment exists." ;;
      secret)  GATE_REA_BLOCK_REASON="REA check (ga-jdzri9): the latest REA comment (${GATE_REA_COMMENT_ID}) on ${3:-?} has the shape of: ${GATE_REA_SHAPES}. Comments cannot be edited: add a NEW comment whose first line starts with REA: and says the same without the value, then run /gate-done again. This is not a code rejection: the same commit can pass." ;;
    esac
  fi
  case "$GATE_REA_VERDICT" in na|off) ;; *) gate_rea_event "${5:-}" "" "finalize" ;; esac
  return 0
}
