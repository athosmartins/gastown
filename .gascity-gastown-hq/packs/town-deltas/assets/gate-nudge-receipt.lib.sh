#!/usr/bin/env bash
# gate-nudge-receipt.lib.sh — ga-5aovajz: a QUEUED nudge is not a delivered one.
#
# WHY. `gc session nudge --delivery wait-idle` exits 0 both when it TYPED the text and when it only QUEUED it ({"ok":true,"outcome":"queued"}), and the
# dispatcher read that 0 as "the author was told". A queued item waits in the engine queue until the target's next prompt (hook) or a poller drains it.
# It is dropped silently when the target's session restarts first (its bead closes state=failed, last_error "queued nudge session fence mismatch": 136
# of 805 nudges in 7 days) and expires unseen after 24 h (state=expired: 114 of 805). A gate FAIL for a live named crew is the worst place for that: the
# dispatcher KEEPS the crew as the owner on the strength of the nudge, so nobody else picks the bead up (wa-2h615v.7, a P0, sat 28 h in gate:needs-fix
# with both its nudges dropped).
#
# WHAT. nudge_author_with_fallback reads its nudge's outcome (--json). `delivered` = typed into the session: nothing more to do. Anything else (queued,
# or rc 0 with no readable outcome) is written down by gate_rcpt_record, one small file per bead + recipient (a later FAIL notice replaces the earlier
# one: it is the one that matters). Each sweep, gate_rcpt_sweep looks the nudge up as a bead (label gc:nudge; matched by the first line of its text and
# the time it was sent: the --json output measured in pool-idle-nobead-guard.sh carries no nudge id) and decides:
#   state injected                                  the session took it: settled, nothing sent.
#   state failed / expired / superseded, or closed  the nudge is gone: the author is MAILED now. Mail is durable, so it survives the restart that killed
#   in any other state                              the nudge.
#   still queued, not found, or the beads unreadable, once the record is GATE_RCPT_PENDING_MAX_S old (default 1800)   the same mail: "queued" is not
#                                                   "told", and waiting for the 24 h expiry would leave a P0 parked for a day. "I could not confirm it"
#                                                   is worded as that, never as "it failed".
# The mail goes through notify_author_with_fallback (the recipient that accepted the nudge first, the Mayor only when nobody can be mailed, a bd
# comment on total failure), and the source bead gets one GATE-NUDGE-RECEIPT comment saying what happened ("not told" must never read as "told",
# ga-fe5at). A source bead that is already closed or gate:passed is left alone (the FAIL it was about no longer matters).
#
# Detection plus a notice. It never re-sends the nudge, never writes the engine queue, and the nudge sites that do not go through
# nudge_author_with_fallback (the rebase nudges, the Mayor pings) are NOT covered. An ephemeral pool author is not recorded (the dispatcher defers its
# Mayor page on purpose: its session is gone and the bead returns to the pool by itself).
#
# THREE STATES, never two: a bead read that FAILS is "cannot tell", not "failed" and not "delivered" (the record waits until the age rule); a record
# file that cannot be read is settled as `damaged` with a WARN (nothing to verify), never mailed from guesswork.
#
# KILL SWITCH. GATE_RCPT_ENABLED=0 (env) or the file $GC_CITY/.gc/gate-nudge-receipt.off: nothing is recorded and no sweep acts (records already written
# stay where they are). A lib that does not load is reported by the sweep call site, once per sweep.
#
# Source-only: defines functions and runs NOTHING at source time. The dispatcher is `set -euo pipefail` on bash 3.2: no arrays, no ${v,,}, every command
# that may fail is guarded, every function returns 0 unless its header says otherwise.
# Knobs (env): GATE_RCPT_DIR, GATE_RCPT_MIN_AGE_S (90: do not look before the queue had a chance), GATE_RCPT_RECHECK_S (300), GATE_RCPT_PENDING_MAX_S (1800),
# GATE_RCPT_MAX_PER_SWEEP (5 records looked at per sweep), GATE_RCPT_BUDGET_S (90: no new record is started once a sweep has spent this many seconds),
# GATE_RCPT_NOW (test seam: the clock).

gate_rcpt_dir() { printf '%s' "${GATE_RCPT_DIR:-${GC_CITY:-/nonexistent}/.gc/runtime/gate-author-nudge}"; }

_gate_rcpt_say()  { if declare -F log  >/dev/null 2>&1; then log  "$@"; else printf '%s\n' "$*"; fi; }
_gate_rcpt_warn() { if declare -F warn >/dev/null 2>&1; then warn "$@"; else printf 'WARN: %s\n' "$*" >&2; fi; }
_gate_rcpt_now()  { printf '%s' "${GATE_RCPT_NOW:-$(date +%s)}"; }

# gate_rcpt_enabled — rc 0 unless the switch is a literal 0 or the off-file exists. A typo leaves it ON: a switch nobody can read must not silently
# turn a safety net off.
gate_rcpt_enabled() {
  case "${GATE_RCPT_ENABLED:-1}" in 0) return 1 ;; esac
  [ -e "${GATE_RCPT_OFF_FILE:-${GC_CITY:-/nonexistent}/.gc/gate-nudge-receipt.off}" ] && return 1
  return 0
}

# gate_rcpt_event <event> [name value]... — one jsonl line on the gate log. rc 1 when it could not be written (the caller warns; the bead comment and the
# settled/ record are the durable ones).
gate_rcpt_event() {
  local ev="$1" extra='{}' k v out
  shift
  while [ "$#" -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    case "$k" in
      age_s) case "$v" in ''|*[!0-9]*) extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;;
                          *) extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --argjson v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;; esac ;;
      *) extra=$(printf '%s' "$extra" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' 2>/dev/null) || return 1 ;;
    esac
  done
  out="${QG_LOG:-${GC_CITY:-/nonexistent}/.gc/quality-gate.jsonl}"
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$ev" --argjson extra "$extra" '{ts:$ts, event:$event} + $extra' >> "$out" 2>/dev/null || return 1
  return 0
}

# _gate_rcpt_key <bead> <to> — a filename-safe key: one record per bead + recipient.
_gate_rcpt_key() { printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_'; }

# _gate_rcpt_get <record-file> <key> — prints the value of key=value; empty when the key is absent or the file cannot be read (the caller tells those apart
# from a real value only through the fields it must have).
_gate_rcpt_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1 || true; }

# _gate_rcpt_oneline <text> — newlines and CRs to spaces: the record is key=value lines.
_gate_rcpt_oneline() { printf '%s' "$1" | tr '\n\r' '  '; }

# gate_rcpt_record <bead_id> <bead_city> <to> <author> <outcome> <message> <fail_context>
# Called by nudge_author_with_fallback after a nudge that was ACCEPTED but not typed. Always rc 0: a record that cannot be written is a WARN that says the
# nudge will not be verified, never a failure of the gate path that called it.
gate_rcpt_record() {
  local bead="${1:-}" bcity="${2:-}" to="${3:-}" author="${4:-}" outcome="${5:-unreadable}" msg="${6:-}" fctx="${7:-}"
  local d key probe tmp now
  gate_rcpt_enabled || return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -z "$bead" ] || [ -z "$to" ] || [ -z "$msg" ]; then
    _gate_rcpt_warn "ga-5aovajz: a queued nudge (bead='${bead:-?}', to='${to:-?}') has no bead, recipient or text to verify against — NOT recorded; it will not be verified"
    return 0
  fi
  d="$(gate_rcpt_dir)"
  key=$(_gate_rcpt_key "$bead" "$to")
  now=$(_gate_rcpt_now)
  # vazio → a mensagem tem texto (checado acima), então sempre há uma 1ª linha; falhou → sonda vazia, e o registro não é gravado (abaixo)
  probe=$(printf '%s\n' "$msg" | awk 'NF { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; exit }') || probe=""
  if [ -z "$probe" ] || ! mkdir -p "$d/pending" "$d/settled" 2>/dev/null; then
    _gate_rcpt_warn "ga-5aovajz: could not record the queued nudge to $to for $bead (no probe line, or $d is not writable) — it will NOT be verified"
    return 0
  fi
  tmp="$d/pending/.$key.$$"
  # .msg first: the .rec is what the sweep discovers, so it must never exist without its text
  if printf '%s' "$msg" > "$tmp.msg" 2>/dev/null && mv "$tmp.msg" "$d/pending/$key.msg" 2>/dev/null \
     && printf 'bead=%s\nbead_city=%s\nto=%s\nauthor=%s\nsent_at=%s\noutcome=%s\nprobe=%s\nfail_context=%s\n' \
          "$(_gate_rcpt_oneline "$bead")" "$(_gate_rcpt_oneline "$bcity")" "$(_gate_rcpt_oneline "$to")" "$(_gate_rcpt_oneline "$author")" \
          "$now" "$(_gate_rcpt_oneline "$outcome")" "$probe" "$(_gate_rcpt_oneline "$fctx")" > "$tmp.rec" 2>/dev/null \
     && mv "$tmp.rec" "$d/pending/$key.rec" 2>/dev/null; then
    rm -f "$d/pending/$key.chk" 2>/dev/null || true   # a replaced record starts its schedule again
    _gate_rcpt_say "ga-5aovajz: nudge to $to for $bead was QUEUED, not delivered (outcome=$outcome) — a receipt is checked on the next sweeps; if it does not land the author is mailed"
  else
    rm -f "$tmp.msg" "$tmp.rec" 2>/dev/null || true
    _gate_rcpt_warn "ga-5aovajz: could not write the receipt record for the queued nudge to $to ($bead) in $d — it will NOT be verified"
  fi
  return 0
}

# _gate_rcpt_utc_date <epoch> — YYYY-MM-DD in UTC; BSD date first (the mini), GNU date next (CI, the node). Empty when neither can.
_gate_rcpt_utc_date() {
  date -u -r "$1" +%Y-%m-%d 2>/dev/null || date -u -d "@$1" +%Y-%m-%d 2>/dev/null || true
}

# _gate_rcpt_list <status> [closed-after-date] — prints the gc:nudge beads of that status as JSON. rc 1 (nothing printed) when bd failed, timed out or
# printed something that is not a JSON array: a failed read is never an empty list.
_gate_rcpt_list() {
  local out
  # vazio ([]) → lista vazia (rc 0, nenhum nudge nesse estado); falhou/ilegível (bd≠0, estouro, lixo) → rc 1 = "não sei"
  if [ -n "${2:-}" ]; then
    out=$(timeout -k 5 30 bd -C "${GC_CITY:-}" list --json --include-infra --status "$1" --limit 0 -l gc:nudge --closed-after "$2" 2>/dev/null) || return 1
  else
    out=$(timeout -k 5 30 bd -C "${GC_CITY:-}" list --json --include-infra --status "$1" --limit 0 -l gc:nudge 2>/dev/null) || return 1
  fi
  printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# _gate_rcpt_classify <json-array> <probe> <sent_at> — the nudge bead sent for this record: the OLDEST one created no earlier than 300 s before sent_at
# (wait-idle can hold the call up to 30 s before it enqueues) whose text contains the probe line. Prints NONE, or <state>|<status>|<reason> (reason on one
# line, no '|'). rc 1 (nothing printed) when jq cannot read the list.
_gate_rcpt_classify() {
  # vazio ([] ou sem bead que case) → NONE; falhou (jq erra) → rc 1
  printf '%s' "$1" | jq -r --arg probe "$2" --argjson sent "$3" '
    [ .[] | select(type == "object")
          | select((.metadata.message // "") | contains($probe))
          | select(((.created_at // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) as $t | ($t != null) and ($t >= ($sent - 300))) ]
    | sort_by(.created_at) | .[0]
    | if . == null then "NONE"
      else ((.metadata.state // "") + "|" + (.status // "") + "|"
            + ((.metadata.terminal_reason // .metadata.last_error // .close_reason // "") | gsub("[|\n\r]"; " "))) end' 2>/dev/null
}

# _gate_rcpt_decide <class> <age_s> — PURE. <class> is NONE, UNREADABLE or <state>|<status>|<reason>. Prints settle:delivered | fallback:<why> | wait:<class>.
_gate_rcpt_decide() {
  local cls="${1:-UNREADABLE}" age="${2:-0}" max="${GATE_RCPT_PENDING_MAX_S:-1800}" st sts rest rsn
  case "$max" in ''|*[!0-9]*) max=1800 ;; esac
  case "$age" in ''|*[!0-9]*) age=0 ;; esac
  case "$cls" in
    NONE|UNREADABLE) st="$cls"; sts=""; rsn="" ;;
    *) st="${cls%%|*}"; rest="${cls#*|}"; sts="${rest%%|*}"; rsn="${rest#*|}" ;;
  esac
  case "$st" in
    injected) echo "settle:delivered"; return 0 ;;
    failed|expired|superseded) echo "fallback:it ended as '$st'${rsn:+ ($rsn)} without reaching the session"; return 0 ;;
    NONE|UNREADABLE) ;;
    # queued, accepted_for_injection, a state nobody named, or none: still pending while the bead is open; a CLOSED bead that was not injected is gone
    *) if [ "$sts" = "closed" ]; then echo "fallback:its bead is closed (state '${st:-none}'${rsn:+, $rsn}) without having been injected"; return 0; fi ;;
  esac
  if [ "$age" -ge "$max" ]; then
    case "$st" in
      NONE)       echo "fallback:no nudge bead was found after ${age}s" ;;
      UNREADABLE) echo "fallback:the nudge beads could not be read for ${age}s" ;;
      *)          echo "fallback:it was still not delivered after ${age}s (state '${st:-none}')" ;;
    esac
    return 0
  fi
  echo "wait:$cls"
  return 0
}

# _gate_rcpt_settle <dir> <key> <verdict> <why> — moves the record (and its text) to settled/ with the verdict. Quiet on success; a record that cannot be
# moved is removed, and if even that fails the WARN says it will repeat.
_gate_rcpt_settle() {
  local d="$1" key="$2" verdict="$3" why="$4" now
  now=$(_gate_rcpt_now)
  printf 'verdict=%s\nsettled_at=%s\nwhy=%s\n' "$verdict" "$now" "$(_gate_rcpt_oneline "$why")" >> "$d/pending/$key.rec" 2>/dev/null || true
  if mv "$d/pending/$key.rec" "$d/settled/$key.$now.rec" 2>/dev/null; then
    mv "$d/pending/$key.msg" "$d/settled/$key.$now.msg" 2>/dev/null || rm -f "$d/pending/$key.msg" 2>/dev/null || true
    rm -f "$d/pending/$key.chk" 2>/dev/null || true
    return 0
  fi
  rm -f "$d/pending/$key.rec" "$d/pending/$key.msg" "$d/pending/$key.chk" 2>/dev/null || true
  if [ -e "$d/pending/$key.rec" ]; then
    _gate_rcpt_warn "ga-5aovajz: could not settle $key (verdict $verdict) — the record is still in $d/pending and will be handled again next sweep"
  fi
  return 0
}

# _gate_rcpt_fallback <dir> <key> <why> <age_s> — the author could not be told by nudge: mail them, say so on the bead, settle. Always rc 0.
_gate_rcpt_fallback() {
  local d="$1" key="$2" why="$3" age="$4" f="$1/pending/$2.rec" bead bcity to author msg fctx src st labels rc=0 subj body note verdict how who
  bead=$(_gate_rcpt_get "$f" bead); bcity=$(_gate_rcpt_get "$f" bead_city); to=$(_gate_rcpt_get "$f" to)
  author=$(_gate_rcpt_get "$f" author); fctx=$(_gate_rcpt_get "$f" fail_context)
  # vazio/falhou (.msg sem texto ou ilegível) → o registro é liquidado como danificado, sem mail inventado
  msg=$(cat "$d/pending/$key.msg" 2>/dev/null) || msg=""
  if [ -z "$msg" ]; then
    _gate_rcpt_warn "ga-5aovajz: receipt record $key has no readable text — settled as damaged, nobody mailed"
    _gate_rcpt_settle "$d" "$key" damaged "no readable text"
    return 0
  fi
  # vazio/falhou (bd show ≠ 0 ou JSON ilegível) → estado da bead DESCONHECIDO: o aviso segue (o inerte aqui é informar), dito no texto
  src=$(timeout -k 5 30 bd -C "${bcity:-${GC_CITY:-}}" show "$bead" --json 2>/dev/null) || src=""
  st=$(printf '%s' "$src" | jq -r 'if type == "array" then .[0] else . end | .status // empty' 2>/dev/null) || st=""
  labels=$(printf '%s' "$src" | jq -r 'if type == "array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null) || labels=""
  note=""
  if [ -z "$st" ]; then
    note=" (the bead's current state could not be read, so it is not known whether this FAIL is still current)"
  else
    case " $labels " in *" gate:passed "*) st=closed ;; esac
    if [ "$st" = "closed" ]; then
      _gate_rcpt_say "ga-5aovajz: $bead is closed or gate:passed — the FAIL notice to $to is moot, nobody mailed ($why)"
      gate_rcpt_event author_nudge_receipt bead "$bead" to "$to" verdict moot age_s "$age" reason "$why" || true
      _gate_rcpt_settle "$d" "$key" moot "$why"
      return 0
    fi
  fi
  subj="Gate FAIL for $bead — the nudge to $to may not have reached you (ga-5aovajz)"
  body="The quality gate nudged $to about $bead, but it could not be confirmed that the nudge reached the session: $why.${note} Read the GATE-FEEDBACK comment on the bead; the original text follows.

$msg"
  # Mail goes first to the recipient that accepted the nudge (the exact session identity), then the candidate cascade, then the Mayor; the bead is in its
  # own store, so BEAD_CITY is pointed there for the comment notify_author_with_fallback leaves on total failure.
  if declare -F notify_author_with_fallback >/dev/null 2>&1; then
    BEAD_CITY="${bcity:-${GC_CITY:-}}" notify_author_with_fallback "$bead" "$to" "$author" "$subj" "$body" "${fctx:-gate FAIL nudge for $bead}" || rc=$?
  else
    rc=99
  fi
  if [ "$rc" = "99" ]; then
    _gate_rcpt_warn "ga-5aovajz: notify_author_with_fallback is not defined — cannot mail $to about $bead; the record stays for the next sweep"
    return 0
  fi
  if [ "$rc" = "0" ]; then
    verdict="mailed"; how="The author was mailed instead (mail survives a restart)."; who="MAILED"
  else
    verdict="escalated"; how="Mailing the author failed too: the Mayor was mailed to relay it."; who="UNREACHABLE (Mayor mailed)"
  fi
  bd -C "${bcity:-${GC_CITY:-}}" comment "$bead" "GATE-NUDGE-RECEIPT (ga-5aovajz): the gate's FAIL nudge to $to could not be confirmed delivered — $why. ${how}${note} A queued nudge is not a delivered one; this note keeps 'not told' from reading as 'told' (ga-fe5at)." \
    2>/dev/null || _gate_rcpt_warn "ga-5aovajz: could not leave the GATE-NUDGE-RECEIPT comment on $bead (the mail above and the log line are the record)"
  _gate_rcpt_say "ga-5aovajz: $bead → $to: $why — author $who"
  gate_rcpt_event author_nudge_receipt bead "$bead" to "$to" verdict "$verdict" age_s "$age" reason "$why" \
    || _gate_rcpt_warn "ga-5aovajz: could not write the author_nudge_receipt event for $bead (the bead comment and settled/ are the record)"
  _gate_rcpt_settle "$d" "$key" "$verdict" "$why"
  return 0
}

# gate_rcpt_sweep — once per dispatcher sweep. With nothing recorded it is one directory test. Looks at most GATE_RCPT_MAX_PER_SWEEP records, each no oftener
# than GATE_RCPT_RECHECK_S; reads the queue's nudge beads at most twice per sweep (open first, closed only when a record is not among the open ones).
gate_rcpt_sweep() {
  local d now f key sent to bead probe age last day cls decide n=0 pending=0 oldest=0 max verdict open_ok=0 closed_ok=0 closed_loaded=0 open_json="" closed_json=""
  local t0 budget
  gate_rcpt_enabled || return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  d="$(gate_rcpt_dir)"
  [ -d "$d/pending" ] || return 0
  now=$(_gate_rcpt_now)
  t0=$(date +%s)   # the real clock on purpose (now may be a test seam): the budget bounds wall time under the gate lock
  max="${GATE_RCPT_MAX_PER_SWEEP:-5}"; case "$max" in ''|*[!0-9]*) max=5 ;; esac
  budget="${GATE_RCPT_BUDGET_S:-90}"; case "$budget" in ''|*[!0-9]*) budget=90 ;; esac
  for f in "$d"/pending/*.rec; do
    [ -e "$f" ] || continue
    key=$(basename "$f" .rec)
    # vazio (campo ausente) ou falhou (arquivo ilegível) → registro danificado: não há o que verificar, liquida com WARN (nunca mail por palpite)
    sent=$(_gate_rcpt_get "$f" sent_at); to=$(_gate_rcpt_get "$f" to); bead=$(_gate_rcpt_get "$f" bead); probe=$(_gate_rcpt_get "$f" probe)
    case "$sent" in ''|*[!0-9]*) sent="" ;; esac
    if [ -z "$sent" ] || [ -z "$to" ] || [ -z "$bead" ] || [ -z "$probe" ] || [ ! -s "$d/pending/$key.msg" ]; then
      _gate_rcpt_warn "ga-5aovajz: receipt record $key is damaged (a field or its text is missing or unreadable) — settled, nobody mailed"
      _gate_rcpt_settle "$d" "$key" damaged "unreadable record"
      continue
    fi
    pending=$((pending + 1))
    age=$((now - sent)); [ "$age" -lt 0 ] && age=0
    [ "$age" -gt "$oldest" ] && oldest="$age"
    [ "$age" -lt "${GATE_RCPT_MIN_AGE_S:-90}" ] && continue
    # vazio (sem .chk) → nunca olhado, olha agora; falhou/ilegível (conteúdo não numérico) → também olha agora (olhar de novo é barato e inerte)
    last=$(cat "$d/pending/$key.chk" 2>/dev/null) || last=""
    case "$last" in ''|*[!0-9]*) last="" ;; esac
    if [ -n "$last" ] && [ $((now - last)) -lt "${GATE_RCPT_RECHECK_S:-300}" ]; then continue; fi
    [ "$n" -ge "$max" ] && break
    # this runs under the gate lock, ahead of Phase C: once the budget is spent the rest wait for the next sweep (a hung Dolt must not hold the gate)
    if [ $(( $(date +%s) - t0 )) -ge "$budget" ]; then
      _gate_rcpt_say "ga-5aovajz: receipt budget (${budget}s) spent — the remaining records wait for the next sweep"
      break
    fi
    n=$((n + 1))
    printf '%s' "$now" > "$d/pending/$key.chk" 2>/dev/null || true
    if [ "$open_ok" = "0" ]; then
      open_ok=2
      if open_json=$(_gate_rcpt_list open); then open_ok=1; fi
    fi
    cls="UNREADABLE"
    if [ "$open_ok" = "1" ]; then
      if cls=$(_gate_rcpt_classify "$open_json" "$probe" "$sent"); then
        if [ "$cls" = "NONE" ]; then
          if [ "$closed_loaded" = "0" ]; then
            closed_loaded=1
            # vazio/falhou (date não converte a época) → a lista de fechadas NÃO é lida e a classe fica UNREADABLE (a regra da idade decide), nunca NONE
            day=$(_gate_rcpt_utc_date $((sent - 86400)))
            if [ -n "$day" ] && closed_json=$(_gate_rcpt_list closed "$day"); then closed_ok=1; fi
          fi
          if [ "$closed_ok" = "1" ]; then cls=$(_gate_rcpt_classify "$closed_json" "$probe" "$sent") || cls="UNREADABLE"; else cls="UNREADABLE"; fi
        fi
      else
        cls="UNREADABLE"
      fi
    fi
    decide=$(_gate_rcpt_decide "$cls" "$age")
    verdict="${decide%%:*}"
    case "$verdict" in
      settle)
        _gate_rcpt_say "ga-5aovajz: nudge to $to for $bead was INJECTED into the session (after ${age}s) — receipt settled"
        gate_rcpt_event author_nudge_receipt bead "$bead" to "$to" verdict delivered age_s "$age" || true
        _gate_rcpt_settle "$d" "$key" delivered "injected" ;;
      fallback)
        _gate_rcpt_fallback "$d" "$key" "${decide#*:}" "$age" ;;
      *) ;;
    esac
    # a record that is still there (the mail could not be attempted, or it could not be moved) is still awaiting its receipt
    [ -e "$f" ] || pending=$((pending - 1))
  done
  # settled records are kept 30 days for whoever asks what happened to a nudge; only a sweep that did work trims them
  if [ "$n" -gt 0 ]; then find "$d/settled" -type f -mtime +30 -exec rm -f {} + 2>/dev/null || true; fi
  if [ "$pending" -gt 0 ]; then _gate_rcpt_say "ga-5aovajz: author nudges awaiting a receipt: ${pending} (oldest ${oldest}s)"; fi
  return 0
}
