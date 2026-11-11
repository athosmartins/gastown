#!/usr/bin/env bash
# gate-nudge-receipt.selftest.sh — ga-5aovajz: a QUEUED author nudge is not a delivered one.
#
# Real code, never a copy: the two dispatcher functions are cut out by their SELFTEST-EXTRACT markers, the lib is sourced. gc and bd are stubs that exist
# only on a sandbox PATH (selftest-sandbox-path.lib.sh): on the Hetzner node the real ones are shims that reach the mini.
#   send    nudge_author_with_fallback reads the outcome (--json): only `delivered` is "told". Queued / no output / garbage / ok:false leave ONE record whose
#           text round-trips byte for byte; the next candidate is tried when one fails; total failure keeps its Mayor mail + comment and records nothing;
#           an ephemeral author, the kill switches, DRY_RUN and a lib that is not there record nothing; an unwritable spool is a WARN, never a failure.
#   sweep   gate_nr_sweep: injected -> settled quietly; failed / expired / closed-not-injected -> the author is mailed ONCE (text verbatim, reason, a
#           GATE-NUDGE-RECEIPT comment in the bead's own store, an event, record settled); still queued / unreadable / not found -> waits, then mails at
#           exactly GATE_NR_PENDING_MAX_S, and "could not read" is never worded as "not found"; a closed / gate:passed source bead is left alone; mail that
#           fails reaches the Mayor; the per-sweep cap, the min-age and the re-check throttles hold; damaged records are settled; the right nudge bead is
#           picked among look-alikes; every path survives `set -euo pipefail`.
#   static  the live dispatcher loads the lib optionally, calls the sweep (not in a Phase-C-only pass), passes --json and keeps the nudge call in the
#           current shell; both files pass bash -n.
#   mutants each behaviour is broken on a copy (one exact-once edit) and this selftest, limited to the groups that cover it, must turn red.
# Env: GNR_NO_MUTANTS=1 skips the mutants; GNR_GROUPS="send sw_wait ..." runs only those groups; GNR_JOBS (6) mutants at a time; B32_BASH=<bash 3.2> adds
# a bash 3.2 -n. Exit 0 iff every assertion holds; 2 = could not even start.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
LIB="${GATE_NR_LIB_UNDER_TEST:-$SELF_DIR/gate-nudge-receipt.lib.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }
chk() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

echo "== gate-nudge-receipt.selftest =="
for f in "$DISPATCHER" "$LIB" "$SELF_DIR/selftest-sandbox-path.lib.sh" "$SELF_DIR/selftest-fail-closed.lib.sh"; do
  [ -r "$f" ] || { echo "FATAL: missing $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing" >&2; exit 2; }
# shellcheck disable=SC1090
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source selftest-sandbox-path.lib.sh" >&2; exit 2; }
# shellcheck disable=SC1090
. "$SELF_DIR/selftest-fail-closed.lib.sh" || { echo "FATAL: cannot source selftest-fail-closed.lib.sh" >&2; exit 2; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/gate-nr-selftest.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
cleanup() { rm -rf "$SB"; }
mkdir -p "$SB/bin"

# ── stubs: the only gc / bd on the sandbox PATH; every call is logged under $FAKE_DIR ──────────────────────────────────────────────────────────────────
cat > "$SB/bin/gc" <<'EOF'
#!/bin/bash
[ "$1" = "--city" ] && shift 2
case "$1 $2" in
  "session nudge")
    to="$3"; json=0
    for a in "$@"; do [ "$a" = "--json" ] && json=1; done
    echo "$to" >> "$FAKE_DIR/nudge.log"
    printf '%s\n' "$*" >> "$FAKE_DIR/nudge.argv"
    mode=queued; [ -f "$FAKE_DIR/nudge.$to" ] && mode=$(cat "$FAKE_DIR/nudge.$to")
    case "$mode" in
      fail) echo "gc session nudge: session not found: \"$to\"" >&2; exit 1 ;;
      empty) exit 0 ;;
      garbage) echo "native_store_unavailable: x"; exit 0 ;;
    esac
    if [ "$json" = 1 ]; then
      case "$mode" in
        delivered) echo '{"ok":true,"delivery":"wait-idle","queued":false,"outcome":"delivered"}' ;;
        notok)     echo '{"ok":false,"outcome":"delivered"}' ;;
        *)         echo '{"ok":true,"delivery":"wait-idle","queued":true,"outcome":"queued"}' ;;
      esac
    else
      echo "Nudged $to"
    fi
    exit 0 ;;
  "mail send")
    to="$3"; n=$(wc -l < "$FAKE_DIR/mail.log" | tr -d ' '); n=$((n+1))
    printf '%s\t%s\n' "$to" "$5" >> "$FAKE_DIR/mail.log"
    printf '%s' "$7" > "$FAKE_DIR/mail.body.$n"
    [ -f "$FAKE_DIR/mailfail.$to" ] && exit 1
    exit 0 ;;
esac
exit 0
EOF
cat > "$SB/bin/bd" <<'EOF'
#!/bin/bash
store=""; [ "$1" = "-C" ] && { store="$2"; shift 2; }
case "$1" in
  list)
    status=""; after=""; shift
    while [ $# -gt 0 ]; do case "$1" in --status) status="$2"; shift 2 ;; --closed-after) after="$2"; shift 2 ;; *) shift ;; esac; done
    printf 'status=%s after=%s store=%s\n' "$status" "$after" "$store" >> "$FAKE_DIR/bd.lists"
    [ -f "$FAKE_DIR/list.fail" ] && exit 1
    [ -f "$FAKE_DIR/list.$status.fail" ] && exit 1
    [ -f "$FAKE_DIR/list.garbage" ] && { echo "not json at all"; exit 0; }
    if [ -f "$FAKE_DIR/nudges.$status.json" ]; then cat "$FAKE_DIR/nudges.$status.json"; else echo '[]'; fi ;;
  show)
    [ -f "$FAKE_DIR/show.fail" ] && exit 1
    if [ -f "$FAKE_DIR/bead.$2.json" ]; then cat "$FAKE_DIR/bead.$2.json"; else echo '{"error":"no issue found"}'; exit 1; fi ;;
  comment)
    n=$(wc -l < "$FAKE_DIR/bd.comments" | tr -d ' '); n=$((n+1))
    printf '%s\t%s\n' "$store" "$2" >> "$FAKE_DIR/bd.comments"
    printf '%s' "$3" > "$FAKE_DIR/comment.$n" ;;
esac
exit 0
EOF
chmod +x "$SB/bin/gc" "$SB/bin/bd"
sandbox_path_init "$SB" jq date mktemp timeout awk sed tr cat head mv rm mkdir basename wc find || { echo "FATAL: sandbox PATH" >&2; exit 2; }
selftest_fail_closed_arm cleanup

# ── the code under test ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
extract_block() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'; }
NOTIFY_BLOCK="$(extract_block "$DISPATCHER" notify-author-with-fallback)"
NUDGE_BLOCK="$(extract_block "$DISPATCHER" nudge-author-with-fallback)"
[ -n "$NOTIFY_BLOCK" ] && [ -n "$NUDGE_BLOCK" ] || { echo "FATAL: SELFTEST-EXTRACT blocks not found in $DISPATCHER" >&2; exit 2; }
eval "$NOTIFY_BLOCK"
eval "$NUDGE_BLOCK"
# shellcheck disable=SC1090
. "$LIB" || { echo "FATAL: cannot source $LIB" >&2; exit 2; }
for fn in nudge_author_with_fallback notify_author_with_fallback gate_nr_record gate_nr_sweep; do
  declare -F "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined after loading" >&2; exit 2; }
done
warn() { printf '%s\n' "$*" >> "${WARN_LOG:-/dev/null}"; }
log()  { printf '%s\n' "$*" >> "${LOG_LOG:-/dev/null}"; }

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
BEAD="wa-2h615v.7"; TO="peter-wa"; RIGCITY="/rig/whatsapp_automation"; T0=1790000000
MSG1=$'QUALITY GATE FAILED for branch crew/peter/wa-2h615v.7. Blocking reasons: Reviewer 1 FAIL: VERDICT: FAIL\n\nBlocking issue 1: "quoted" text, $dollar, `tick`, back\\slash & more.\nGate run: ga-05z21u8. Fix the issues and re-run /gate-done when ready.'
PROBE1='QUALITY GATE FAILED for branch crew/peter/wa-2h615v.7. Blocking reasons: Reviewer 1 FAIL: VERDICT: FAIL'

new_case() {
  CASE="$(mktemp -d "$SB/case.XXXXXX")" || exit 2
  FD="$CASE/fake"; mkdir -p "$FD" "$CASE/city/.gc"
  export FAKE_DIR="$FD" GC_CITY="$CASE/city" GATE_NR_DIR="$CASE/city/.gc/runtime/gate-author-nudge" QG_LOG="$CASE/city/.gc/quality-gate.jsonl"
  : > "$FD/mail.log"; : > "$FD/nudge.log"; : > "$FD/nudge.argv"; : > "$FD/bd.lists"; : > "$FD/bd.comments"; : > "$QG_LOG"
  WARN_LOG="$CASE/warn.log"; LOG_LOG="$CASE/log.log"; : > "$WARN_LOG"; : > "$LOG_LOG"
  unset BEAD_CITY GATE_FAIL_DEFER_MAYOR DRY_RUN GATE_NR_ENABLED GATE_NR_NOW GATE_NR_PENDING_MAX_S GATE_NR_MIN_AGE_S GATE_NR_RECHECK_S GATE_NR_MAX_PER_SWEEP GATE_NR_OFF_FILE
  put_bead "$BEAD" in_progress gate:needs-fix
}
put_bead() { jq -n --arg id "$1" --arg s "$2" --arg l "${*:3}" '[{id:$id, status:$s, labels:($l | split(" ") | map(select(. != "")))}]' > "$FD/bead.$1.json"; }
nbead() { jq -n --arg st "$1" --arg sts "$2" --arg rsn "$3" --argjson c "$4" --arg msg "$5" '{id:("ga-wisp-n" + ($c|tostring)), status:$sts, created_at:($c|todate), close_reason:$rsn, metadata:{agent:"peter-wa", state:$st, message:$msg, terminal_reason:$rsn}, labels:["gc:nudge","agent:peter-wa"]}'; }
put_list() { local st="$1"; shift; if [ "$#" -eq 0 ]; then echo '[]' > "$FD/nudges.$st.json"; else printf '%s\n' "$@" | jq -s . > "$FD/nudges.$st.json"; fi; }
recf() { printf '%s/pending/%s.rec' "$GATE_NR_DIR" "$(printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')"; }
rget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }
nlines() { wc -l < "$1" | tr -d ' '; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
settled_verdicts() { cat "$GATE_NR_DIR"/settled/*.rec 2>/dev/null | sed -n 's/^verdict=//p' | tr '\n' ' '; }
pending_n() { ls "$GATE_NR_DIR"/pending/*.rec 2>/dev/null | wc -l | tr -d ' '; }
event_verdicts() { jq -r 'select(.event=="author_nudge_receipt") | .verdict' "$QG_LOG" 2>/dev/null | tr '\n' ' '; }
mail_n() { nlines "$FD/mail.log"; }
mail_to() { sed -n "${1}p" "$FD/mail.log" | cut -f1; }
lists_n() { nlines "$FD/bd.lists"; }
streq() { [ "$1" = "$2" ]; }

# send <bead> <notify_author> <author> <message> [clock]   (the real nudge_author_with_fallback on the sandbox PATH)
send() { GATE_NR_NOW="${5:-$T0}" PATH="$SANDBOX_PATH" nudge_author_with_fallback "$1" "$2" "$3" "$4" "ctx $1"; SEND_RC=$?; }
mkrec() { # [sent] [bead] [message] [to]  — a nudge the queue ACCEPTED, recorded by the real code
  local sent="${1:-$T0}" bead="${2:-$BEAD}" msg="${3:-$MSG1}" to="${4:-$TO}"
  echo queued > "$FD/nudge.$to"; BEAD_CITY="$RIGCITY" send "$bead" "$to" author-x "$msg" "$sent"
}
sweep() { GATE_NR_NOW="$1" PATH="$SANDBOX_PATH" gate_nr_sweep; SWEEP_RC=$?; }
bare_sweep_reaches_end() { ( set -euo pipefail; PATH="$SANDBOX_PATH"; GATE_NR_NOW="$1"; gate_nr_sweep; echo REACHED ) 2>/dev/null; }
case_closed() { # <state> <reason> [created offset]  → a record at T0 and one CLOSED nudge bead of that state
  new_case; mkrec "$T0"; put_list open; put_list closed "$(nbead "$1" closed "$2" "$((T0 + ${3:-1}))" "$MSG1")"
}
case_open() { # <state> [created offset]  → a record at T0 and one OPEN nudge bead of that state
  new_case; mkrec "$T0"; put_list open "$(nbead "$1" open "" "$((T0 + ${2:-3}))" "$MSG1")"
}

# ═════════════════════════════════════════════════ send ══════════════════════════════════════════════════════════════════════════════════════════════
g_send() {
  echo "── send ──"
  new_case; echo delivered > "$FD/nudge.$TO"; send "$BEAD" "$TO" author-x "$MSG1"
  chk "send1 delivered: rc 0" streq "$SEND_RC" 0
  chk "send1 the nudge asks for --json" has "$FD/nudge.argv" "--delivery wait-idle --json"
  chk "send1 delivered: nothing recorded" test ! -e "$(recf "$BEAD" "$TO")"
  chk "send1 delivered: nobody mailed" streq "$(mail_n)" 0

  new_case; echo queued > "$FD/nudge.$TO"; BEAD_CITY="$RIGCITY" send "$BEAD" "$TO" author-x "$MSG1" 1000000
  R="$(recf "$BEAD" "$TO")"
  chk "send2 queued: rc 0 (the gate path is not failed by it)" streq "$SEND_RC" 0
  chk "send2 queued: a record exists" test -f "$R"
  chk "send2 record: to / bead / bead_city / sent_at / outcome" streq "$(rget "$R" to)|$(rget "$R" bead)|$(rget "$R" bead_city)|$(rget "$R" sent_at)|$(rget "$R" outcome)" "$TO|$BEAD|$RIGCITY|1000000|queued"
  chk "send2 record: author and notify_author kept for the mail cascade" streq "$(rget "$R" author)|$(rget "$R" notify_author)" "author-x|$TO"
  chk "send2 record: the probe is the first line of the text" streq "$(rget "$R" probe)" "$PROBE1"
  printf '%s' "$MSG1" > "$CASE/expect.msg"
  chk "send2 the text round-trips byte for byte (newlines, quotes, \$, backtick, backslash)" cmp -s "$CASE/expect.msg" "${R%.rec}.msg"
  chk "send2 queued: nobody is mailed at send time" streq "$(mail_n)" 0

  for mode in empty garbage notok; do
    new_case; echo "$mode" > "$FD/nudge.$TO"; send "$BEAD" "$TO" author-x "$MSG1"
    chk "send3 [$mode] rc 0 and the outcome is recorded as unreadable (cannot tell is not told)" streq "$SEND_RC:$(rget "$(recf "$BEAD" "$TO")" outcome)" "0:unreadable"
  done

  new_case; echo fail > "$FD/nudge.batista"; echo queued > "$FD/nudge.batista-lx"; send lx-dnw batista some-author "$MSG1"
  chk "send4 cascade: the recipient that ACCEPTED is recorded, not the first one tried" streq "$(nlines "$FD/nudge.log"):$(rget "$(recf lx-dnw batista-lx)" to)" "2:batista-lx"

  new_case; for r in peter-wa author-x; do echo fail > "$FD/nudge.$r"; done; send "$BEAD" "$TO" author-x "$MSG1"
  chk "send5 every candidate fails: rc 1, the Mayor is mailed once, a comment is left, nothing is recorded" streq "$SEND_RC:$(mail_to 1):$(mail_n):$(nlines "$FD/bd.comments"):$(pending_n)" "1:mayor:1:1:0"

  new_case; echo queued > "$FD/nudge.$TO"; GATE_FAIL_DEFER_MAYOR=1 send "$BEAD" "$TO" author-x "$MSG1"
  chk "send6 an ephemeral pool author (deferred Mayor page) is not recorded" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; GATE_NR_ENABLED=0 send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7a kill switch GATE_NR_ENABLED=0 records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; : > "$GC_CITY/.gc/gate-nudge-receipt.off"; send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7b kill switch off-file records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; DRY_RUN=1 send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7c DRY_RUN=1 records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; ( unset -f gate_nr_record; send "$BEAD" "$TO" author-x "$MSG1"; exit "$SEND_RC" ); SEND_RC=$?
  chk "send8 a lib that is not loaded: the nudge still goes out and the call returns 0" streq "$SEND_RC:$(nlines "$FD/nudge.log"):$(pending_n)" "0:1:0"

  new_case; echo queued > "$FD/nudge.$TO"; send "$BEAD" "$TO" author-x "$MSG1" 1000; send "$BEAD" "$TO" author-x $'Gate FAILED for wa-2h615v.7 (attempt 1/3) — see GATE-FEEDBACK.' 2000
  chk "send9 a later notice for the same bead+recipient REPLACES the record (one file, the new probe and time)" streq "$(pending_n):$(rget "$(recf "$BEAD" "$TO")" sent_at):$(rget "$(recf "$BEAD" "$TO")" probe)" "1:2000:Gate FAILED for wa-2h615v.7 (attempt 1/3) — see GATE-FEEDBACK."

  new_case; echo queued > "$FD/nudge.$TO"; : > "$CASE/blocker"; GATE_NR_DIR="$CASE/blocker/sub" send "$BEAD" "$TO" author-x "$MSG1"
  chk "send10 an unwritable spool: rc 0 and a WARN that says the nudge will NOT be verified" streq "$SEND_RC:$(grep -c 'NOT be verified' "$WARN_LOG")" "0:1"
  new_case; PATH="$SANDBOX_PATH" gate_nr_record "" "$RIGCITY" "$TO" a b queued "$MSG1" ctx
  chk "send10b no bead id: nothing recorded, a WARN, rc 0" streq "$?:$(pending_n):$(grep -c 'NOT recorded' "$WARN_LOG")" "0:0:1"

  new_case; echo queued > "$FD/nudge.$TO"
  chk "send11 under set -euo pipefail a queued send is a plain success (no unbound variable, no errexit)" streq "$( ( set -euo pipefail; PATH="$SANDBOX_PATH"; GATE_NR_NOW=5; nudge_author_with_fallback "$BEAD" "$TO" author-x m ctx; echo REACHED ) 2>/dev/null )" REACHED
}

# ═════════════════════════════════════════════════ sweep groups ══════════════════════════════════════════════════════════════════════════════════════
g_sw_inject() {
  echo "── sweep: injected ──"
  case_closed injected "accepted by injection at the hook" 2; sweep $((T0 + 600))
  chk "sweep1 injected: nobody mailed, no comment, record settled as delivered" streq "$(mail_n):$(nlines "$FD/bd.comments"):$(pending_n):$(settled_verdicts)" "0:0:0:delivered "
  chk "sweep1 open was read first, closed only because open had no match, with the day before the send" streq "$(sed -n 1p "$FD/bd.lists" | cut -d' ' -f1):$(sed -n 2p "$FD/bd.lists" | cut -d' ' -f1,2)" "status=open:status=closed after=$(date -u -r $((T0 - 86400)) +%Y-%m-%d 2>/dev/null || date -u -d "@$((T0 - 86400))" +%Y-%m-%d)"
}
g_sw_gone() {
  echo "── sweep: the nudge is gone ──"
  case_closed failed "queued nudge session fence mismatch"; sweep $((T0 + 600))
  chk "sweep2 failed: the author is mailed exactly once, at the identity that accepted the nudge" streq "$(mail_n):$(mail_to 1)" "1:$TO"
  chk "sweep2 mail body: the reason, in the state and the engine's own words" has "$FD/mail.body.1" "ended as 'failed' (queued nudge session fence mismatch)"
  chk "sweep2 the whole original text ends the mail, byte for byte" streq "$(tail -c ${#MSG1} "$FD/mail.body.1")" "$MSG1"
  chk "sweep2 the mail subject names the bead and the recipient" has "$FD/mail.log" "Gate FAIL for $BEAD — the nudge to $TO may not have reached you"
  chk "sweep2 a GATE-NUDGE-RECEIPT comment lands in the BEAD's store (not the HQ), saying the author was mailed" streq "$(cut -f1,2 "$FD/bd.comments" | tr '\t' '|'):$(has "$FD/comment.1" 'GATE-NUDGE-RECEIPT' && has "$FD/comment.1" 'The author was mailed instead' && echo y)" "$RIGCITY|$BEAD:y"
  chk "sweep2 event + settled record agree: mailed" streq "$(event_verdicts)|$(settled_verdicts)" "mailed |mailed "
  sweep $((T0 + 5000)); chk "sweep2 a second sweep mails nobody again (the record is gone)" streq "$(mail_n):$(pending_n)" "1:0"
  case_closed expired "expired by delivery deadline" 5; sweep $((T0 + 600))
  chk "sweep3 expired: mailed, reason names the state" streq "$(mail_n):$(has "$FD/mail.body.1" "ended as 'expired'" && echo y)" "1:y"
  case_closed superseded "" 5; sweep $((T0 + 600))
  chk "sweep3b superseded (replaced by a newer enqueue) is not a delivery either: mailed" streq "$(mail_n)" "1"
  case_closed weird x 5; sweep $((T0 + 600))
  chk "sweep3c a CLOSED nudge in a state nobody named, not injected: mailed (it is gone)" streq "$(mail_n):$(has "$FD/mail.body.1" "its bead is closed (state 'weird'" && echo y)" "1:y"
}
g_sw_wait() {
  echo "── sweep: still queued ──"
  case_open queued; sweep $((T0 + 600))
  chk "sweep4 still queued and young: nothing happens, the record waits, closed is not even read (the open list matched)" streq "$(mail_n):$(pending_n):$(grep -c 'status=closed' "$FD/bd.lists")" "0:1:0"
  case_open queued; sweep $((T0 + 1799))
  chk "sweep5a 1799 s: one second short of the limit still waits" streq "$(mail_n)" 0
  case_open accepted_for_injection; sweep $((T0 + 1800))
  chk "sweep5b exactly GATE_NR_PENDING_MAX_S: mailed, worded as 'still not delivered' (not as a failure)" streq "$(mail_n):$(has "$FD/mail.body.1" "it was still not delivered after 1800s (state 'accepted_for_injection')" && echo y)" "1:y"
  new_case; mkrec; GATE_NR_PENDING_MAX_S=100 sweep $((T0 + 100))
  chk "sweep5c GATE_NR_PENDING_MAX_S is honoured (100 s)" streq "$(mail_n)" 1
}
g_sw_age() {
  echo "── sweep: when it looks ──"
  new_case; mkrec; sweep $((T0 + 60))
  chk "sweep6 younger than GATE_NR_MIN_AGE_S: zero bd reads, the record stays" streq "$(lists_n):$(pending_n):$(mail_n)" "0:1:0"
  new_case; sweep $((T0 + 600))
  chk "sweep6b nothing recorded: no bd read at all, rc 0" streq "$(lists_n):$SWEEP_RC" "0:0"
  case_open queued; sweep $((T0 + 120)); sweep $((T0 + 180))
  chk "sweep14 the re-check throttle: a record looked at 60 s ago is not read again" streq "$(grep -c 'status=open' "$FD/bd.lists")" 1
  sweep $((T0 + 420)); chk "sweep14b ... and is read again 300 s later" streq "$(grep -c 'status=open' "$FD/bd.lists")" 2
}
g_sw_unread() {
  echo "── sweep: cannot tell ──"
  for how in list.fail list.garbage; do
    new_case; mkrec; : > "$FD/$how"; sweep $((T0 + 600))
    chk "sweep7 [$how] bd unreadable before the limit: the record WAITS (cannot tell is not failed, not delivered)" streq "$(mail_n):$(pending_n)" "0:1"
    sweep $((T0 + 1800 + 600))
    chk "sweep7 [$how] and at the limit the author is mailed, worded 'could not be read' (not 'not found')" streq "$(mail_n):$(has "$FD/mail.body.1" "the nudge beads could not be read for 2400s" && echo y)" "1:y"
  done
  new_case; mkrec; : > "$FD/list.closed.fail"; put_list open; sweep $((T0 + 600))
  chk "sweep8 open read fine but empty, closed unreadable: still 'cannot tell' (waits)" streq "$(mail_n):$(pending_n)" "0:1"
  sweep $((T0 + 2000))
  chk "sweep8b ... and at the limit it is worded 'could not be read', never 'no nudge bead was found'" streq "$(has "$FD/mail.body.1" "could not be read" && echo y):$(has "$FD/mail.body.1" "no nudge bead was found" || echo n)" "y:n"
  new_case; mkrec; put_list open; put_list closed; sweep $((T0 + 600))
  chk "sweep9 both lists readable and no such nudge: waits" streq "$(mail_n):$(pending_n)" "0:1"
  sweep $((T0 + 2000))
  chk "sweep9b ... at the limit mailed, worded 'no nudge bead was found'" streq "$(mail_n):$(has "$FD/mail.body.1" "no nudge bead was found after 2000s" && echo y)" "1:y"
  new_case; mkrec; put_list open; echo '[{"metadata":{"message":5},"created_at":"2026-11-10T01:27:47Z"}]' > "$FD/nudges.closed.json"; sweep $((T0 + 2000))
  chk "sweep9c a nudge bead whose text is not a string makes jq fail: 'could not be read', never 'not found'" streq "$(has "$FD/mail.body.1" "could not be read" && echo y):$(has "$FD/mail.body.1" "no nudge bead was found" || echo n)" "y:n"
}
g_sw_moot() {
  echo "── sweep: the source bead ──"
  case_closed failed x; put_bead "$BEAD" closed; sweep $((T0 + 600))
  chk "sweep10 a CLOSED source bead: the FAIL notice is moot, nobody mailed, settled as moot, event says moot" streq "$(mail_n):$(nlines "$FD/bd.comments"):$(settled_verdicts):$(event_verdicts)" "0:0:moot :moot "
  case_closed failed x; put_bead "$BEAD" open gate:passed; sweep $((T0 + 600))
  chk "sweep10b a gate:passed source bead is moot too" streq "$(mail_n):$(settled_verdicts)" "0:moot "
  case_closed failed x; : > "$FD/show.fail"; sweep $((T0 + 600))
  chk "sweep11 the source bead cannot be read: the author is STILL mailed, and the text says its state is unknown" streq "$(mail_n):$(has "$FD/mail.body.1" "could not be read, so it is not known" && echo y):$(has "$FD/comment.1" "could not be read" && echo y)" "1:y:y"
}
g_sw_escal() {
  echo "── sweep: the author cannot be mailed ──"
  case_closed failed x; echo x > "$FD/mailfail.$TO"; echo x > "$FD/mailfail.author-x"; BEAD_CITY="/stale/other"; sweep $((T0 + 600))
  chk "sweep12 the author cannot be mailed: the Mayor is mailed (author first, then author-x, then mayor), verdict escalated" streq "$(mail_n):$(mail_to 3):$(settled_verdicts)" "3:mayor:escalated "
  chk "sweep12b both comments (the helper's and the receipt) go to the bead's own store, never the HQ or a stale BEAD_CITY, and the receipt says the Mayor was mailed" streq "$(cut -f1 "$FD/bd.comments" | sort -u):$(nlines "$FD/bd.comments"):$(has "$FD/comment.2" "Mayor was mailed" && echo y)" "$RIGCITY:2:y"
  chk "sweep12c the dispatcher's own BEAD_CITY is left exactly as it was" streq "$BEAD_CITY" "/stale/other"
  unset BEAD_CITY
}
g_sw_cap() {
  echo "── sweep: the per-sweep cap ──"
  new_case; mkrec "$T0" wa-aaa1 $'Gate FAILED for wa-aaa1 — one'; mkrec "$T0" wa-bbb2 $'Gate FAILED for wa-bbb2 — two'
  put_bead wa-aaa1 in_progress; put_bead wa-bbb2 in_progress
  put_list open; put_list closed "$(nbead failed closed x $((T0 + 1)) $'Gate FAILED for wa-aaa1 — one')" "$(nbead failed closed x $((T0 + 1)) $'Gate FAILED for wa-bbb2 — two')"
  GATE_NR_MAX_PER_SWEEP=1 sweep $((T0 + 600))
  chk "sweep13 the per-sweep cap: one record handled, the other left for the next sweep" streq "$(mail_n):$(pending_n)" "1:1"
  GATE_NR_MAX_PER_SWEEP=1 sweep $((T0 + 601))
  chk "sweep13b ... and the next sweep handles it (each mail names its own bead)" streq "$(mail_n):$(has "$FD/mail.log" wa-aaa1 && has "$FD/mail.log" wa-bbb2 && echo y)" "2:y"
}
g_sw_damage() {
  echo "── sweep: damaged records ──"
  new_case; mkrec; sed -i.bak '/^sent_at=/d' "$(recf "$BEAD" "$TO")"; sweep $((T0 + 600))
  chk "sweep15 a record with no sent_at is DAMAGED: settled with a WARN, nobody mailed, no bd read" streq "$(mail_n):$(settled_verdicts):$(grep -c 'damaged' "$WARN_LOG"):$(lists_n)" "0:damaged :1:0"
  new_case; mkrec; rm -f "${GATE_NR_DIR}/pending/"*.msg; sweep $((T0 + 600))
  chk "sweep15b a record whose text is gone is damaged too (a mail with no text would be made up)" streq "$(mail_n):$(settled_verdicts)" "0:damaged "
  if [ "$(id -u)" != 0 ]; then
    new_case; mkrec; chmod 000 "$(recf "$BEAD" "$TO")"; sweep $((T0 + 600))
    chk "sweep15c a record file that cannot be READ is damaged (never mailed from guesswork)" streq "$(mail_n):$(grep -c 'damaged' "$WARN_LOG")" "0:1"
  fi
}
g_sw_match() {
  echo "── sweep: which nudge bead is this record's ──"
  new_case; mkrec; put_list open
  put_list closed "$(nbead failed closed "x" $((T0 - 10)) "$MSG1")" "$(nbead injected closed "y" $((T0 + 50)) "$MSG1")"
  sweep $((T0 + 600))
  chk "sweep16 look-alikes: the OLDEST in the window is this record's nudge (failed), not a later one with the same text (injected)" streq "$(mail_n):$(has "$FD/mail.body.1" "ended as 'failed'" && echo y)" "1:y"
  new_case; mkrec; put_list open; put_list closed "$(nbead injected closed "y" $((T0 - 1000)) "$MSG1")"; sweep $((T0 + 600))
  chk "sweep16b a nudge with the same text created 1000 s BEFORE the send is another notice: not this one (waits)" streq "$(mail_n):$(pending_n)" "0:1"
  new_case; mkrec; put_list open; put_list closed "$(nbead failed closed "x" $((T0 + 1)) "A different text entirely")"; sweep $((T0 + 600))
  chk "sweep16c a different text is not this record's nudge (waits)" streq "$(mail_n):$(pending_n)" "0:1"
}
g_sw_budget() {
  echo "── sweep: time budget and housekeeping ──"
  case_closed failed x; GATE_NR_BUDGET_S=0 sweep $((T0 + 600))
  chk "sweep19 a spent budget (0 s): no record is started, nothing is read or mailed, the record waits, and the log says so" streq "$(lists_n):$(mail_n):$(pending_n):$(grep -c 'budget' "$LOG_LOG")" "0:0:1:1"
  sweep $((T0 + 601)); chk "sweep19b ... and the next sweep (default budget) handles it" streq "$(mail_n):$(pending_n)" "1:0"
  case_closed failed x; : > "$GATE_NR_DIR/settled/old.rec"; touch -t 202001010000 "$GATE_NR_DIR/settled/old.rec"; : > "$GATE_NR_DIR/settled/new.rec"; sweep $((T0 + 600))
  chk "sweep20 settled records older than 30 days are trimmed by a sweep that did work; recent ones stay" streq "$(test -e "$GATE_NR_DIR/settled/old.rec" && echo old)$(test -e "$GATE_NR_DIR/settled/new.rec" && echo new)" "new"
  case_closed failed x; : > "$GATE_NR_DIR/settled/old.rec"; touch -t 202001010000 "$GATE_NR_DIR/settled/old.rec"; sweep $((T0 + 60))
  chk "sweep20b a sweep that did no work trims nothing" test -e "$GATE_NR_DIR/settled/old.rec"
}
g_sw_switch() {
  echo "── sweep: switches and errexit ──"
  case_closed failed x; DRY_RUN=1 sweep $((T0 + 600))
  chk "sweep17 DRY_RUN=1: the sweep does nothing" streq "$(lists_n):$(mail_n):$(pending_n)" "0:0:1"
  case_closed failed x; GATE_NR_ENABLED=0 sweep $((T0 + 600))
  chk "sweep17b kill switch: the sweep does nothing and the record stays" streq "$(lists_n):$(mail_n):$(pending_n)" "0:0:1"
  case_closed failed x; : > "$FD/show.fail"; echo x > "$FD/mailfail.$TO"; echo x > "$FD/mailfail.author-x"
  chk "sweep18 under set -euo pipefail, bd show failing and every mail failing, a bare sweep still runs to its end" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
  new_case; mkrec; : > "$FD/list.fail"
  chk "sweep18b ... and with bd list failing" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
}

# ═════════════════════════════════════════════════ static ════════════════════════════════════════════════════════════════════════════════════════════
g_static() {
  echo "── static ──"
  local l_pm l_nr
  chk "static1 the dispatcher loads the lib only when readable and sets GATE_NR_LIB_OK from the function it must define" bash -c 'grep -qF "[ -r \"\$_GATE_NR_LIB\" ]" "$1" && grep -qF "type gate_nr_sweep >/dev/null 2>&1; then GATE_NR_LIB_OK=1" "$1"' _ "$DISPATCHER"
  l_pm="$(grep -n 'gate_pm_sweep || true' "$DISPATCHER" | head -n1 | cut -d: -f1)"
  l_nr="$(grep -n 'gate_nr_sweep || true' "$DISPATCHER" | head -n1 | cut -d: -f1)"
  chk "static2 the sweep is called once, after the post-merge sweep, with its failure neutralised" streq "$(grep -c 'gate_nr_sweep || true' "$DISPATCHER"):$([ -n "$l_nr" ] && [ -n "$l_pm" ] && [ "$l_nr" -gt "$l_pm" ] && echo after)" "1:after"
  chk "static3 not in a Phase-C-only child pass (the guard sits just above the call)" bash -c 'sed -n "$(( $2 - 4 )),$2p" "$1" | grep -qF "GATE_PHASE_C_ONLY:-0}\" != \"1\""' _ "$DISPATCHER" "${l_nr:-0}"
  chk "static4 a lib that did not load is said out loud by the sweep call site" bash -c 'sed -n "$2,$(( $2 + 2 ))p" "$1" | grep -qF "NOT being verified"' _ "$DISPATCHER" "${l_nr:-0}"
  chk "static5 the nudge asks for --json and the call stays in THIS shell (output to a file, no command substitution)" streq "$(grep -c 'if gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json >' "$DISPATCHER"):$(grep -c '\$(gc --city "\$GC_CITY" session nudge' "$DISPATCHER")" "1:0"
  chk "static6 the record call is guarded by declare -F (sibling selftests eval the function without the lib) and by the neutralising || true" streq "$(grep -c 'declare -F gate_nr_record' "$DISPATCHER"):$(grep -c 'gate_nr_record "\$_bead_id".* || true' "$DISPATCHER")" "1:1"
  chk "static7 both files pass bash -n" bash -c 'bash -n "$1" && bash -n "$2"' _ "$DISPATCHER" "$LIB"
  if [ -n "${B32_BASH:-}" ] && [ -x "${B32_BASH:-}" ]; then
    chk "static8 and a real bash 3.2 (B32_BASH) accepts both, printing nothing" streq "$("$B32_BASH" -n "$DISPATCHER" 2>&1)$("$B32_BASH" -n "$LIB" 2>&1)" ""
  fi
}

GROUPS_ALL="send sw_inject sw_gone sw_wait sw_age sw_unread sw_moot sw_escal sw_cap sw_damage sw_match sw_budget sw_switch static"
for g in ${GNR_GROUPS:-$GROUPS_ALL}; do "g_$g"; done

# ═════════════════════════════════════════════════ mutants ═══════════════════════════════════════════════════════════════════════════════════════════
run_mutants() {
  [ "${GNR_NO_MUTANTS:-0}" = "1" ] && return 0
  echo "── mutants (each must turn this selftest red, on the groups that cover it) ──"
  command -v python3 >/dev/null 2>&1 || { bad "mutants: python3 missing"; return 0; }
  local MUT="$SB/mut" id kind groups desc n=0 jobs="${GNR_JOBS:-6}" rc
  mkdir -p "$MUT"
  GNR_LIB="$LIB" GNR_DISP="$DISPATCHER" GNR_OUT="$MUT" python3 -I - <<'PYEOF' || { bad "mutants: an anchor is not exactly-once in the file (the source drifted: update the mutant)"; return 0; }
import os, sys
lib = open(os.environ["GNR_LIB"]).read()
disp = open(os.environ["GNR_DISP"]).read()
out = os.environ["GNR_OUT"]
M = [
 # (id, file, old, new, groups, description)
 ("l01", "lib", '    injected) echo "settle:delivered"; return 0 ;;', '    injected) echo "fallback:x"; return 0 ;;', "sw_inject", "an injected nudge is treated as lost"),
 ("l02", "lib", "    failed|expired|superseded) echo \"fallback:it ended as '$st'${rsn:+ ($rsn)} without reaching the session\"; return 0 ;;", "    failed|expired|superseded) ;;", "sw_gone", "failed/expired wait for the age rule instead of mailing now"),
 ("l03", "lib", 'if [ "$age" -ge "$max" ]; then', 'if [ "$age" -gt "$max" ]; then', "sw_wait", "off by one at the pending limit"),
 ("l04", "lib", 'else cls="UNREADABLE"; fi', 'else cls="NONE"; fi', "sw_unread", "an unreadable closed list is read as 'not found'"),
 ("l05", "lib", '    if [ "$st" = "closed" ]; then\n      _gate_nr_say', '    if [ "$st" = "never" ]; then\n      _gate_nr_say', "sw_moot", "a closed source bead still gets the mail"),
 ("l06", "lib", '    case " $labels " in *" gate:passed "*) st=closed ;; esac\n', '', "sw_moot", "gate:passed is no longer moot"),
 ("l07", "lib", '  if [ -z "$st" ]; then\n    note=', '  if [ -n "$st" ]; then\n    note=', "sw_moot", "an unreadable source bead is not noted / a readable one is"),
 ("l08", "lib", '    [ "$age" -lt "${GATE_NR_MIN_AGE_S:-90}" ] && continue\n', '', "sw_age", "no minimum age"),
 ("l09", "lib", 'if [ -n "$last" ] && [ $((now - last)) -lt "${GATE_NR_RECHECK_S:-300}" ]; then continue; fi', 'if false; then continue; fi', "sw_age", "no re-check throttle"),
 ("l10", "lib", '($t != null) and ($t >= ($sent - 300))', '($t != null)', "sw_match", "no time window on the nudge bead"),
 ("l11", "lib", '| sort_by(.created_at) | .[0]', '| sort_by(.created_at) | .[-1]', "sw_match", "the newest look-alike instead of the oldest"),
 ("l12", "lib", '  [ "${DRY_RUN:-0}" = "1" ] && return 0\n  d="$(gate_nr_dir)"\n  [ -d "$d/pending" ] || return 0', '  d="$(gate_nr_dir)"\n  [ -d "$d/pending" ] || return 0', "sw_switch", "the sweep ignores DRY_RUN"),
 ("l13", "lib", '  [ "${DRY_RUN:-0}" = "1" ] && return 0\n  if [ -z "$bead" ]', '  if [ -z "$bead" ]', "send", "the record ignores DRY_RUN"),
 ("l14", "lib", 'BEAD_CITY="${bcity:-${GC_CITY:-}}" notify_author_with_fallback', 'notify_author_with_fallback', "sw_escal", "the helper comments in the HQ store"),
 ("l15", "lib", 'if mv "$d/pending/$key.rec" "$d/settled/$key.$now.rec" 2>/dev/null; then', 'if false; then', "sw_gone", "a settled record is deleted instead of kept"),
 ("l16", "lib", '        if [ "$cls" = "NONE" ]; then\n          if [ "$closed_loaded" = "0" ]; then', '        if true; then\n          if [ "$closed_loaded" = "0" ]; then', "sw_wait", "the closed list is read even when the open one matched"),
 ("l17", "lib", '    [ "$n" -ge "$max" ] && break\n', '', "sw_cap", "no per-sweep cap"),
 ("l18", "lib", "      *)          echo \"fallback:it was still not delivered after ${age}s (state '${st:-none}')\" ;;", '      *)          echo "wait:$cls" ;;', "sw_wait", "a queued nudge never ages into a mail"),
 ("l19", "lib", 'if [ "$rc" = "0" ]; then\n    verdict="mailed"', 'if [ "$rc" = "1" ]; then\n    verdict="mailed"', "sw_gone sw_escal", "mailed and escalated swapped"),
 ("l20", "lib", '$(_gate_nr_classify "$closed_json" "$probe" "$sent") || cls="UNREADABLE"', '$(_gate_nr_classify "$closed_json" "$probe" "$sent") || cls="NONE"', "sw_unread", "a jq failure on the closed list is read as 'not found'"),
 ("l21", "lib", '|| [ ! -s "$d/pending/$key.msg" ]; then', '; then', "sw_damage", "a record without its text is not damaged"),
 ("l22", "lib", 'if [ $(( $(date +%s) - t0 )) -ge "$budget" ]; then', 'if false; then', "sw_budget", "no time budget"),
 ("l23", "lib", '-mtime +30 -exec rm -f {} +', '-mtime +3650 -exec rm -f {} +', "sw_budget", "settled records are kept far too long"),
 ("l24", "lib", 'if [ "$n" -gt 0 ]; then find', 'if true; then find', "sw_budget", "an idle sweep trims too"),
 ("d01", "disp", 'if [ "$_noc" != "delivered" ] && [ "$_defer" != "1" ] && declare -F', 'if [ "$_defer" != "1" ] && declare -F', "send", "a delivered nudge is recorded too"),
 ("d02", "disp", 'if [ "$_noc" != "delivered" ] && [ "$_defer" != "1" ] && declare -F', 'if [ "$_noc" != "delivered" ] && declare -F', "send", "an ephemeral author is recorded"),
 ("d03", "disp", '--delivery wait-idle --json >"${_nf:-/dev/null}"', '--delivery wait-idle >"${_nf:-/dev/null}"', "send", "no --json"),
 ("d04", "disp", "jq -er 'select(.ok == true) | .outcome' \"$_nf\"", "jq -er '.outcome' \"$_nf\"", "send", "ok:false is believed"),
 ("d05", "disp", 'if gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json >"${_nf:-/dev/null}" 2>/dev/null; then', 'if _x=$(gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json 2>/dev/null); then', "static", "the nudge runs in a subshell"),
 ("d06", "disp", 'if [ "${GATE_NR_LIB_OK:-0}" = "1" ]; then gate_nr_sweep || true', 'if [ "${GATE_NR_LIB_OK:-0}" = "1" ]; then :', "static", "the sweep is never called"),
 ("d07", "disp", 'if [ "${GATE_PHASE_C_ONLY:-0}" != "1" ]; then\n  if [ "${GATE_NR_LIB_OK:-0}" = "1" ]', 'if true; then\n  if [ "${GATE_NR_LIB_OK:-0}" = "1" ]', "static", "the sweep runs in a Phase-C-only pass"),
 ("d08", "disp", 'gate_nr_record "$_bead_id" "${BEAD_CITY:-$GC_CITY}" "$_notified" "$_notify_author" "$_author" "${_noc:-unreadable}" "$_message" "$_fail_context" || true', 'gate_nr_record "$_bead_id" "${BEAD_CITY:-$GC_CITY}" "$_notified" "$_notify_author" "$_author" "${_noc:-unreadable}" "$_message" "$_fail_context"', "static", "the record call is no longer neutralised"),
]
bad = 0
with open(os.path.join(out, "manifest.tsv"), "w") as man:
    for (mid, which, old, new, groups, desc) in M:
        src = lib if which == "lib" else disp
        if src.count(old) != 1:
            sys.stderr.write("mutant %s: anchor occurs %d times (want 1): %r\n" % (mid, src.count(old), old[:70])); bad = 1; continue
        open(os.path.join(out, mid + "." + which), "w").write(src.replace(old, new))
        man.write("%s\t%s\t%s\t%s\n" % (mid, which, groups, desc))
sys.exit(bad)
PYEOF
  # a batch of $jobs mutants at a time (no `wait -n` on bash 3.2); each leaves its exit status in $MUT/<id>.rc
  while IFS="$(printf '\t')" read -r id kind groups desc; do
    (
      if [ "$kind" = "lib" ]; then
        GNR_NO_MUTANTS=1 GNR_GROUPS="$groups" GATE_NR_LIB_UNDER_TEST="$MUT/$id.lib" bash "$SELF" > "$MUT/$id.out" 2>&1 < /dev/null
      else
        GNR_NO_MUTANTS=1 GNR_GROUPS="$groups" GATE_DISPATCHER_UNDER_TEST="$MUT/$id.disp" bash "$SELF" > "$MUT/$id.out" 2>&1 < /dev/null
      fi
      echo "$?" > "$MUT/$id.rc"
    ) &
    n=$((n + 1))
    if [ "$((n % jobs))" -eq 0 ]; then wait; fi
  done < "$MUT/manifest.tsv"
  wait
  # GNR_KEEP_MUT=<dir>: keep the mutated copies and each run's output (to see WHICH assertion killed which mutant)
  if [ -n "${GNR_KEEP_MUT:-}" ]; then mkdir -p "$GNR_KEEP_MUT" && cp "$MUT"/* "$GNR_KEEP_MUT"/ 2>/dev/null || true; fi
  while IFS="$(printf '\t')" read -r id kind groups desc; do
    rc="$(cat "$MUT/$id.rc" 2>/dev/null || echo none)"
    case "$rc" in
      1) ok "mutant $id killed: $desc" ;;
      0) bad "mutant $id SURVIVED: $desc" ;;
      *) bad "mutant $id did not run (rc=$rc): $desc — $(tail -n 2 "$MUT/$id.out" 2>/dev/null | tr '\n' ' ')" ;;
    esac
  done < "$MUT/manifest.tsv"
}
run_mutants

echo ""; echo "gate-nudge-receipt.selftest: PASS=$PASS FAIL=$FAIL"
selftest_summary_reached
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
