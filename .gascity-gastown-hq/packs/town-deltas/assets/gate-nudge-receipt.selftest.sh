#!/usr/bin/env bash
# gate-nudge-receipt.selftest.sh — ga-5aovajz: a QUEUED author nudge is not a delivered one.
#
# Real code, never a copy: the two dispatcher functions are cut out by their SELFTEST-EXTRACT markers, the lib is sourced. gc and bd are stubs that exist
# only on a sandbox PATH (selftest-sandbox-path.lib.sh): on the Hetzner node the real ones are shims that reach the mini.
#   send    nudge_author_with_fallback reads the outcome (--json): only `delivered` is "told". Queued / no output / garbage / ok:false leave ONE record whose
#           text round-trips byte for byte; the next candidate is tried when one fails; total failure keeps its Mayor mail + comment and records nothing;
#           an ephemeral author, the kill switches, DRY_RUN and a lib that is not there record nothing; an unwritable spool is a WARN, never a failure.
#   sweep   gate_rcpt_sweep: injected -> settled quietly; failed / expired / closed-not-injected -> the author is mailed ONCE (text verbatim, reason, a
#           GATE-NUDGE-RECEIPT comment in the bead's own store, an event, record settled); still queued / unreadable / not found -> waits, then mails at
#           exactly GATE_RCPT_PENDING_MAX_S, and "could not read" is never worded as "not found"; a closed / gate:passed source bead is left alone; mail that
#           fails reaches the Mayor; the per-sweep cap, the min-age and the re-check throttles hold; damaged records are settled; the right nudge bead is
#           picked among look-alikes; every path survives `set -euo pipefail`.
#   wake    (ga-9kxy44u) a receipt that gives up on the author also types ONE short --delivery immediate line into the recipient's pane, after the mail
#           and at most once per record (the attempt is written down first): only with the switch on, a readable bead that is still the author's, not
#           back in the gate (gate:queued / gate:reviewing) nor parked for a human (gate:needs-human*), and a pane that reads as an idle Claude Code
#           prompt (busy, dialog, selection menu, shell, empty and cut-short peeks all skip, with the reason; the idle and busy fixtures are REAL
#           wa-worker panes); the outcome (delivered / queued / unconfirmed / failed / skipped) is never worded as typed unless delivered; both gc
#           calls run under timeout; failing mail, a missing mail helper and errexit leave it alone.
#   static  the live dispatcher loads the lib optionally, calls the sweep (not in a Phase-C-only pass), passes --json and keeps the nudge call in the
#           current shell; both files pass bash -n.
#   mutants each behaviour is broken on a copy (one exact-once edit) and this selftest, limited to the groups that cover it, must turn red.
# Env: GNR_NO_MUTANTS=1 skips the mutants; GNR_GROUPS="send sw_wait ..." runs only those groups; GNR_JOBS (6) mutants at a time; B32_BASH=<bash 3.2> adds
# a bash 3.2 -n. Exit 0 iff every assertion holds; 2 = could not even start.
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
LIB="${GATE_RCPT_LIB_UNDER_TEST:-$SELF_DIR/gate-nudge-receipt.lib.sh}"

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
    to="$3"; json=0; imm=0; dl=wait-idle
    for a in "$@"; do [ "$a" = "--json" ] && json=1; [ "$a" = "immediate" ] && { imm=1; dl=immediate; }; done
    echo "$to" >> "$FAKE_DIR/nudge.log"
    printf '%s\n' "$*" >> "$FAKE_DIR/nudge.argv"
    mode=queued; [ -f "$FAKE_DIR/nudge.$to" ] && mode=$(cat "$FAKE_DIR/nudge.$to")
    # --delivery immediate (the gate's wake-up nudge) has its own mode file, wake.<to>; it types the text, so the default is delivered
    if [ "$imm" = 1 ]; then mode=delivered; [ -f "$FAKE_DIR/wake.$to" ] && mode=$(cat "$FAKE_DIR/wake.$to"); printf '%s' "$4" > "$FAKE_DIR/wake.text"; cat "$GATE_RCPT_DIR"/pending/*.rec > "$FAKE_DIR/rec.at-wake" 2>/dev/null; fi
    case "$mode" in
      fail) echo "gc session nudge: session not found: \"$to\"" >&2; exit 1 ;;
      empty) exit 0 ;;
      garbage) echo "native_store_unavailable: x"; exit 0 ;;
      slow) exec sleep 8 ;;
    esac
    if [ "$json" = 1 ]; then
      case "$mode" in
        delivered) echo '{"ok":true,"delivery":"'$dl'","queued":false,"outcome":"delivered"}' ;;
        notok)     echo '{"ok":false,"outcome":"delivered"}' ;;
        *)         echo '{"ok":true,"delivery":"'$dl'","queued":true,"outcome":"queued"}' ;;
      esac
    else
      echo "Nudged $to"
    fi
    exit 0 ;;
  "session peek")
    echo "$3" >> "$FAKE_DIR/peek.log"
    [ -f "$FAKE_DIR/peek.fail" ] && { echo "gc session peek: session not found: \"$3\"" >&2; exit 1; }
    [ -f "$FAKE_DIR/pane.$3" ] && cat "$FAKE_DIR/pane.$3"
    [ -f "$FAKE_DIR/peek.rc1" ] && exit 1
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
cat > "$SB/bin/date" <<'EOF'
#!/bin/bash
# fake date: FAKE_DATE_FAIL=1 makes the epoch -> day conversions (-r, -d) fail, as on a box whose date knows neither form; everything else is the real date
if [ -n "${FAKE_DATE_FAIL:-}" ]; then for a in "$@"; do case "$a" in -r|-d) exit 1 ;; esac; done; fi
exec "$REAL_DATE" "$@"
EOF
cat > "$SB/bin/timeout" <<'EOF'
#!/bin/bash
# logs what is run under a bound (the wake-up's two gc calls must be), then runs the real timeout
printf '%s\n' "$*" >> "$FAKE_DIR/timeout.log"
exec "$REAL_TIMEOUT" "$@"
EOF
chmod +x "$SB/bin/gc" "$SB/bin/bd" "$SB/bin/date" "$SB/bin/timeout"
sandbox_path_init "$SB" jq date mktemp timeout awk sed tr cat head mv rm mkdir basename wc find grep tail sleep || { echo "FATAL: sandbox PATH" >&2; exit 2; }
export REAL_DATE="$SB/tools/date" REAL_TIMEOUT="$SB/tools/timeout"
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
for fn in nudge_author_with_fallback notify_author_with_fallback gate_rcpt_record gate_rcpt_sweep; do
  declare -F "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined after loading" >&2; exit 2; }
done
warn() { printf '%s\n' "$*" >> "${WARN_LOG:-/dev/null}"; }
log()  { printf '%s\n' "$*" >> "${LOG_LOG:-/dev/null}"; }

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
BEAD="wa-2h615v.7"; TO="peter-wa"; RIGCITY="/rig/whatsapp_automation"; T0=1790000000
MSG1=$'QUALITY GATE FAILED for branch crew/peter/wa-2h615v.7. Blocking reasons: Reviewer 1 FAIL: VERDICT: FAIL\n\nBlocking issue 1: "quoted" text, $dollar, `tick`, back\\slash & more.\nGate run: ga-05z21u8. Fix the issues and re-run /gate-done when ready.'
PROBE1='QUALITY GATE FAILED for branch crew/peter/wa-2h615v.7. Blocking reasons: Reviewer 1 FAIL: VERDICT: FAIL'

# Pane fixtures for the wake-up (ga-9kxy44u). idle / busy are REAL panes copied from the live wa-workers (`gc session peek`, 03/10, the same ones
# scripts/tests/pool-idle-nobead-guard.selftest.sh carries), trimmed. All of them draw the "❯" prompt box: it is on EVERY pane (busy, idle, and the option
# cursor of a dialog), so it can never be what tells them apart. dialog / ask / shell are synthetic: the permission-dialog wording is the one
# agent-stuck-escalation.sh matches, the selection hints are Claude Code's. (top-level heredocs, read back: bash 3.2 mis-parses one inside $( ))
mkdir -p "$SB/panes"
cat > "$SB/panes/idle.txt" <<'EOF'
⏺ Monitor(mutation (new code) and neighbour differential finished)
  ⎿  Monitor started · task bh0a27iaa · timeout 1800s

✻ Cooked for 1h 1m 30s · done 10:22 AM · 3 shells, 1 monitor still running

────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  👥 0 workers · 🚦 running 2/3 6c179cf040677bf559f74e
  [Sonnet 5.5] ctx: 38.0% (380k/1000k)
  ⏵⏵ bypass permissions on · 3 shells, 1 monitor · ← 1 agent
EOF
cat > "$SB/panes/busy.txt" <<'EOF'
⏺ Re-running the real-data E2E with a fresh oracle · 1m 5s
  ⎿  $ cd /Users/athos/gt/whatsapp_automation/crew/worker-wa-yo0ex9 && python3 -
     (ctrl+b ctrl+b (twice) to run in background)

✢ Kneading… (1h 31m 47s · ↓ 298.6k tokens)
  ⎿  Tip: Use /clear to start fresh when switching topics and free up context

────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on · 2 shells · ← 1 agent
EOF
cat > "$SB/panes/dialog.txt" <<'EOF'
⏺ Bash(rm -rf scratch/__pycache__)
  Permission rule Bash(rm -rf:*) requires confirmation for this command.
  Do you want to proceed?
  ❯ 1. Yes
    2. Yes, and don't ask again
    3. No
EOF
cat > "$SB/panes/ask.txt" <<'EOF'
Which way should the fix go?

❯ 1. Mail only
  2. Mail and a wake-up nudge
  3. Type something.
Enter to select · ↑/↓ to navigate · Esc to cancel
EOF
printf 'athos@mini gascity %% ' > "$SB/panes/shell.txt"
CHROME=$'\n────────────────────────────────────────────────────────────────────────────────\n❯ \n────────────────────────────────────────────────────────────────────────────────\n  [Sonnet 5.5] ctx: 38.0% (380k/1000k)'

new_case() {
  CASE="$(mktemp -d "$SB/case.XXXXXX")" || exit 2
  FD="$CASE/fake"; mkdir -p "$FD" "$CASE/city/.gc"
  export FAKE_DIR="$FD" GC_CITY="$CASE/city" GATE_RCPT_DIR="$CASE/city/.gc/runtime/gate-author-nudge" QG_LOG="$CASE/city/.gc/quality-gate.jsonl"
  : > "$FD/mail.log"; : > "$FD/nudge.log"; : > "$FD/nudge.argv"; : > "$FD/peek.log"; : > "$FD/timeout.log"; : > "$FD/bd.lists"; : > "$FD/bd.comments"; : > "$QG_LOG"
  WARN_LOG="$CASE/warn.log"; LOG_LOG="$CASE/log.log"; : > "$WARN_LOG"; : > "$LOG_LOG"
  unset BEAD_CITY GATE_FAIL_DEFER_MAYOR DRY_RUN GATE_RCPT_ENABLED GATE_RCPT_NOW GATE_RCPT_PENDING_MAX_S GATE_RCPT_MIN_AGE_S GATE_RCPT_RECHECK_S GATE_RCPT_MAX_PER_SWEEP GATE_RCPT_OFF_FILE ASG
  unset GATE_RCPT_WAKE GATE_RCPT_WAKE_OFF_FILE GATE_RCPT_WAKE_TIMEOUT_S
  put_bead "$BEAD" in_progress gate:needs-fix
}
# put_bead <id> <status> [label]...   the source bead as `bd show --json` prints it; ASG is its assignee (default: the author the records are written for, "author-x")
put_bead() { jq -n --arg id "$1" --arg s "$2" --arg a "${ASG-author-x}" --arg l "${*:3}" '[{id:$id, status:$s, assignee:$a, labels:($l | split(" ") | map(select(. != "")))}]' > "$FD/bead.$1.json"; }
# nbead <state> <status> <reason> <created-epoch> <message> [agent]. Shape measured live on 2026-11-11 (799 closed gc:nudge beads since 04/11, `bd list --include-infra
# --status closed -l gc:nudge`): the engine's own words are in close_reason; terminal_reason / last_error are "" (EMPTY STRINGS, not null) for a nudge that was
# accepted or injected, and carry the failure for failed / expired / superseded (close_reason there is the engine's generic "nudge <state>: ..." line).
# So <reason> is the close_reason for the delivered states ("nudge accepted for hook-transport injection", "nudge delivered via provider injection") and the
# terminal_reason / last_error text for the others.
nbead() {
  jq -n --arg st "$1" --arg sts "$2" --arg rsn "$3" --argjson c "$4" --arg msg "$5" --arg ag "${6:-peter-wa}" '
    ($st == "failed" or $st == "expired" or $st == "superseded" or ($sts == "closed" and $st != "injected" and $st != "accepted_for_injection")) as $bad
    | (if $sts != "closed" then "" elif $bad then ("nudge " + $st + ": engine close") else $rsn end) as $cr
    | {id:("ga-wisp-n" + ($c|tostring)), status:$sts, created_at:($c|todate), close_reason:$cr,
       metadata:{agent:$ag, session_id:$ag, state:$st, message:$msg, close_reason:$cr,
                 terminal_reason:(if $bad then $rsn else "" end), last_error:(if $bad then $rsn else "" end)}, labels:["gc:nudge",("agent:" + $ag)]}'
}
put_list() { local st="$1"; shift; if [ "$#" -eq 0 ]; then echo '[]' > "$FD/nudges.$st.json"; else printf '%s\n' "$@" | jq -s . > "$FD/nudges.$st.json"; fi; }
recf() { printf '%s/pending/%s.rec' "$GATE_RCPT_DIR" "$(printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')"; }
rget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }
nlines() { wc -l < "$1" | tr -d ' '; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }
settled_verdicts() { cat "$GATE_RCPT_DIR"/settled/*.rec 2>/dev/null | sed -n 's/^verdict=//p' | tr '\n' ' '; }
pending_n() { ls "$GATE_RCPT_DIR"/pending/*.rec 2>/dev/null | wc -l | tr -d ' '; }
event_verdicts() { jq -r 'select(.event=="author_nudge_receipt") | .verdict' "$QG_LOG" 2>/dev/null | tr '\n' ' '; }
mail_n() { nlines "$FD/mail.log"; }
mail_to() { sed -n "${1}p" "$FD/mail.log" | cut -f1; }
lists_n() { nlines "$FD/bd.lists"; }
streq() { [ "$1" = "$2" ]; }

# send <bead> <notify_author> <author> <message> [clock]   (the real nudge_author_with_fallback on the sandbox PATH)
send() { GATE_RCPT_NOW="${5:-$T0}" PATH="$SANDBOX_PATH" nudge_author_with_fallback "$1" "$2" "$3" "$4" "ctx $1"; SEND_RC=$?; }
mkrec() { # [sent] [bead] [message] [to]  — a nudge the queue ACCEPTED, recorded by the real code
  local sent="${1:-$T0}" bead="${2:-$BEAD}" msg="${3:-$MSG1}" to="${4:-$TO}"
  echo queued > "$FD/nudge.$to"; BEAD_CITY="$RIGCITY" send "$bead" "$to" author-x "$msg" "$sent"
}
sweep() { GATE_RCPT_NOW="$1" PATH="$SANDBOX_PATH" gate_rcpt_sweep; SWEEP_RC=$?; }
bare_sweep_reaches_end() { ( set -euo pipefail; PATH="$SANDBOX_PATH"; GATE_RCPT_NOW="$1"; gate_rcpt_sweep; echo REACHED ) 2>/dev/null; }
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
  chk "send2 record: the author is kept (the mail cascade ends with it)" streq "$(rget "$R" author)" "author-x"
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
  new_case; echo queued > "$FD/nudge.$TO"; GATE_RCPT_ENABLED=0 send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7a kill switch GATE_RCPT_ENABLED=0 records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; : > "$GC_CITY/.gc/gate-nudge-receipt.off"; send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7b kill switch off-file records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; DRY_RUN=1 send "$BEAD" "$TO" author-x "$MSG1"
  chk "send7c DRY_RUN=1 records nothing" streq "$SEND_RC:$(pending_n)" "0:0"
  new_case; echo queued > "$FD/nudge.$TO"; ( unset -f gate_rcpt_record; send "$BEAD" "$TO" author-x "$MSG1"; exit "$SEND_RC" ); SEND_RC=$?
  chk "send8 a lib that is not loaded: the nudge still goes out and the call returns 0" streq "$SEND_RC:$(nlines "$FD/nudge.log"):$(pending_n)" "0:1:0"

  new_case; echo queued > "$FD/nudge.$TO"; send "$BEAD" "$TO" author-x "$MSG1" 1000; send "$BEAD" "$TO" author-x $'Gate FAILED for wa-2h615v.7 (attempt 1/3) — see GATE-FEEDBACK.' 2000
  chk "send9 a later notice for the same bead+recipient REPLACES the record (one file, the new probe and time)" streq "$(pending_n):$(rget "$(recf "$BEAD" "$TO")" sent_at):$(rget "$(recf "$BEAD" "$TO")" probe)" "1:2000:Gate FAILED for wa-2h615v.7 (attempt 1/3) — see GATE-FEEDBACK."

  new_case; echo queued > "$FD/nudge.$TO"; : > "$CASE/blocker"; GATE_RCPT_DIR="$CASE/blocker/sub" send "$BEAD" "$TO" author-x "$MSG1"
  chk "send10 an unwritable spool: rc 0 and a WARN that says the nudge will NOT be verified" streq "$SEND_RC:$(grep -c 'NOT be verified' "$WARN_LOG")" "0:1"
  new_case; PATH="$SANDBOX_PATH" gate_rcpt_record "" "$RIGCITY" "$TO" a queued "$MSG1" ctx
  chk "send10b no bead id: nothing recorded, a WARN, rc 0" streq "$?:$(pending_n):$(grep -c 'NOT recorded' "$WARN_LOG")" "0:0:1"

  new_case; echo queued > "$FD/nudge.$TO"
  chk "send11 under set -euo pipefail a queued send is a plain success (no unbound variable, no errexit)" streq "$( ( set -euo pipefail; PATH="$SANDBOX_PATH"; GATE_RCPT_NOW=5; nudge_author_with_fallback "$BEAD" "$TO" author-x m ctx; echo REACHED ) 2>/dev/null )" REACHED
}

# ═════════════════════════════════════════════════ sweep groups ══════════════════════════════════════════════════════════════════════════════════════
g_sw_inject() {
  echo "── sweep: injected ──"
  case_closed injected "nudge delivered via provider injection" 2; sweep $((T0 + 600))
  chk "sweep1 injected: nobody mailed, no comment, record settled as delivered" streq "$(mail_n):$(nlines "$FD/bd.comments"):$(pending_n):$(settled_verdicts)" "0:0:0:delivered "
  chk "sweep1 open was read first, closed only because open had no match, with the day before the send" streq "$(sed -n 1p "$FD/bd.lists" | cut -d' ' -f1):$(sed -n 2p "$FD/bd.lists" | cut -d' ' -f1,2)" "status=open:status=closed after=$(date -u -r $((T0 - 86400)) +%Y-%m-%d 2>/dev/null || date -u -d "@$((T0 - 86400))" +%Y-%m-%d)"
}
# ga-5aovajz gate attempt 1: a CLOSED nudge bead in state accepted_for_injection is the hook-transport SUCCESS state, not a lost nudge. Measured live on
# 2026-11-11 over 799 closed gc:nudge beads since 04/11: 425-428 accepted_for_injection ("nudge accepted for hook-transport injection", 53%, the most common
# outcome), 121 injected, 136 failed (fence mismatch), 113 expired, 4 superseded. The review's own POINTER nudge to the reviewer was in that state and reached it.
g_sw_hook() {
  echo "── sweep: accepted for hook-transport injection ──"
  case_closed accepted_for_injection "nudge accepted for hook-transport injection" 2; sweep $((T0 + 600))
  chk "sweep1b CLOSED accepted_for_injection (the live hook-transport success): settled as delivered, nobody mailed, no comment" streq "$(mail_n):$(nlines "$FD/bd.comments"):$(pending_n):$(settled_verdicts):$(event_verdicts)" "0:0:0:delivered :delivered "
  chk "sweep1c ... and the log says the hook accepted it, not that it was 'injected into the session'" streq "$(has "$LOG_LOG" "accepted for hook-transport injection" && echo y):$(has "$LOG_LOG" "was INJECTED into the session" || echo n)" "y:n"
  case_open accepted_for_injection; sweep $((T0 + 600))
  chk "sweep1d OPEN accepted_for_injection and young: waits (it is not closed yet; nothing mailed, record kept)" streq "$(mail_n):$(pending_n)" "0:1"
  case_closed accepted_for_injection "nudge accepted for hook-transport injection" 2; sweep $((T0 + 5000)); sweep $((T0 + 9000))
  chk "sweep1e a settled receipt is not mailed on a later sweep" streq "$(mail_n):$(pending_n)" "0:0"
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
  chk "sweep3b superseded (replaced by a newer enqueue) is not a delivery either: mailed, and with an EMPTY terminal_reason the engine's close_reason is the reason" streq "$(mail_n):$(has "$FD/mail.body.1" "ended as 'superseded' (nudge superseded: engine close)" && echo y)" "1:y"
  case_closed weird x 5; sweep $((T0 + 600))
  chk "sweep3c a CLOSED nudge in a state nobody named: mailed at once (a closed bead does not change), worded as 'not recognised', never as 'not injected'" streq "$(mail_n):$(has "$FD/mail.body.1" "its bead is closed in state 'weird', which this check does not recognise" && echo y):$(has "$FD/mail.body.1" "without having been injected" || echo n)" "1:y:n"
}
g_sw_wait() {
  echo "── sweep: still queued ──"
  case_open queued; sweep $((T0 + 600))
  chk "sweep4 still queued and young: nothing happens, the record waits, closed is not even read (the open list matched)" streq "$(mail_n):$(pending_n):$(grep -c 'status=closed' "$FD/bd.lists")" "0:1:0"
  case_open queued; sweep $((T0 + 1799))
  chk "sweep5a 1799 s: one second short of the limit still waits" streq "$(mail_n)" 0
  case_open accepted_for_injection; sweep $((T0 + 1800))
  chk "sweep5b exactly GATE_RCPT_PENDING_MAX_S: mailed, worded as 'still not delivered' (not as a failure)" streq "$(mail_n):$(has "$FD/mail.body.1" "it was still not delivered after 1800s (state 'accepted_for_injection')" && echo y)" "1:y"
  new_case; mkrec; GATE_RCPT_PENDING_MAX_S=100 sweep $((T0 + 100))
  chk "sweep5c GATE_RCPT_PENDING_MAX_S is honoured (100 s)" streq "$(mail_n)" 1
}
g_sw_age() {
  echo "── sweep: when it looks ──"
  new_case; mkrec; sweep $((T0 + 60))
  chk "sweep6 younger than GATE_RCPT_MIN_AGE_S: zero bd reads, the record stays" streq "$(lists_n):$(pending_n):$(mail_n)" "0:1:0"
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
  chk "sweep8b ... and at the limit it is worded 'could not be read', never 'no open or closed nudge bead was found'" streq "$(has "$FD/mail.body.1" "could not be read" && echo y):$(has "$FD/mail.body.1" "no open or closed nudge bead was found" || echo n)" "y:n"
  new_case; mkrec; put_list open; put_list closed; sweep $((T0 + 600))
  chk "sweep9 both lists readable and no such nudge: waits" streq "$(mail_n):$(pending_n)" "0:1"
  sweep $((T0 + 2000))
  chk "sweep9b ... at the limit mailed, worded 'no open or closed nudge bead was found'" streq "$(mail_n):$(has "$FD/mail.body.1" "no open or closed nudge bead was found after 2000s" && echo y)" "1:y"
  new_case; mkrec; put_list open; FAKE_DATE_FAIL=1 sweep $((T0 + 600))
  chk "sweep9d the day for --closed-after cannot be computed: the closed list is NOT read (no wrong query), the record waits" streq "$(grep -c 'status=closed' "$FD/bd.lists"):$(mail_n):$(pending_n)" "0:0:1"
  FAKE_DATE_FAIL=1 sweep $((T0 + 2000))
  chk "sweep9e ... and at the limit it is worded 'could not be read', never 'no open or closed nudge bead was found'" streq "$(has "$FD/mail.body.1" "could not be read" && echo y):$(has "$FD/mail.body.1" "no open or closed nudge bead was found" || echo n)" "y:n"
  new_case; mkrec; put_list open; echo '[{"metadata":{"message":5},"created_at":"2026-11-10T01:27:47Z"}]' > "$FD/nudges.closed.json"; sweep $((T0 + 2000))
  chk "sweep9c a nudge bead whose text is not a string makes jq fail: 'could not be read', never 'not found'" streq "$(has "$FD/mail.body.1" "could not be read" && echo y):$(has "$FD/mail.body.1" "no open or closed nudge bead was found" || echo n)" "y:n"
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
  chk "sweep12b both comments (the helper's and the receipt) go to the bead's own store, never the HQ or a stale BEAD_CITY, and the receipt says the Mayor mail was attempted" streq "$(cut -f1 "$FD/bd.comments" | sort -u):$(nlines "$FD/bd.comments"):$(has "$FD/comment.2" "mail to the Mayor was attempted" && echo y)" "$RIGCITY:2:y"
  chk "sweep12c the dispatcher's own BEAD_CITY is left exactly as it was" streq "$BEAD_CITY" "/stale/other"
  unset BEAD_CITY
}
g_sw_cap() {
  echo "── sweep: the per-sweep cap ──"
  new_case; mkrec "$T0" wa-aaa1 $'Gate FAILED for wa-aaa1 — one'; mkrec "$T0" wa-bbb2 $'Gate FAILED for wa-bbb2 — two'
  put_bead wa-aaa1 in_progress; put_bead wa-bbb2 in_progress
  put_list open; put_list closed "$(nbead failed closed x $((T0 + 1)) $'Gate FAILED for wa-aaa1 — one')" "$(nbead failed closed x $((T0 + 1)) $'Gate FAILED for wa-bbb2 — two')"
  GATE_RCPT_MAX_PER_SWEEP=1 sweep $((T0 + 600))
  chk "sweep13 the per-sweep cap: one record handled, the other left for the next sweep" streq "$(mail_n):$(pending_n)" "1:1"
  GATE_RCPT_MAX_PER_SWEEP=1 sweep $((T0 + 601))
  chk "sweep13b ... and the next sweep handles it (each mail names its own bead)" streq "$(mail_n):$(has "$FD/mail.log" wa-aaa1 && has "$FD/mail.log" wa-bbb2 && echo y)" "2:y"
}
g_sw_damage() {
  echo "── sweep: damaged records ──"
  new_case; mkrec; sed -i.bak '/^sent_at=/d' "$(recf "$BEAD" "$TO")"; sweep $((T0 + 600))
  chk "sweep15 a record with no sent_at is DAMAGED: settled with a WARN, nobody mailed, no bd read" streq "$(mail_n):$(settled_verdicts):$(grep -c 'damaged' "$WARN_LOG"):$(lists_n)" "0:damaged :1:0"
  new_case; mkrec; rm -f "${GATE_RCPT_DIR}/pending/"*.msg; sweep $((T0 + 600))
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
  # the nudge bead carries the session it was sent to (metadata.agent / session_id, label agent:<s>): among same-text beads in the window, the one for THIS
  # recipient wins over an older one for another session; with no bead for this recipient the text+time match still applies (the identity can be spelled
  # differently: alias, session name, id — so it ranks, it does not exclude)
  new_case; mkrec; put_list open
  put_list closed "$(nbead failed closed "queued nudge session fence mismatch" $((T0 + 1)) "$MSG1" other-wa)" "$(nbead injected closed "nudge delivered via provider injection" $((T0 + 5)) "$MSG1" "$TO")"
  sweep $((T0 + 600))
  chk "sweep16d same text, an OLDER bead for another session (failed) and a newer one for this recipient (injected): this recipient's wins, nobody mailed" streq "$(mail_n):$(settled_verdicts)" "0:delivered "
  new_case; mkrec; put_list open; put_list closed "$(nbead failed closed "queued nudge session fence mismatch" $((T0 + 1)) "$MSG1" other-wa)"; sweep $((T0 + 600))
  chk "sweep16e the only same-text bead names another session: still used (identity ranks, it does not exclude; the spelling may differ)" streq "$(mail_n):$(has "$FD/mail.body.1" "ended as 'failed'" && echo y)" "1:y"
}
g_sw_budget() {
  echo "── sweep: time budget and housekeeping ──"
  case_closed failed x; GATE_RCPT_BUDGET_S=0 sweep $((T0 + 600))
  chk "sweep19 a spent budget (0 s): no record is started, nothing is read or mailed, the record waits, and the log says so" streq "$(lists_n):$(mail_n):$(pending_n):$(grep -c 'budget' "$LOG_LOG")" "0:0:1:1"
  sweep $((T0 + 601)); chk "sweep19b ... and the next sweep (default budget) handles it" streq "$(mail_n):$(pending_n)" "1:0"
  case_closed failed x; : > "$GATE_RCPT_DIR/settled/old.rec"; touch -t 202001010000 "$GATE_RCPT_DIR/settled/old.rec"; : > "$GATE_RCPT_DIR/settled/new.rec"; sweep $((T0 + 600))
  chk "sweep20 settled records older than 30 days are trimmed by a sweep that did work; recent ones stay" streq "$(test -e "$GATE_RCPT_DIR/settled/old.rec" && echo old)$(test -e "$GATE_RCPT_DIR/settled/new.rec" && echo new)" "new"
  case_closed failed x; : > "$GATE_RCPT_DIR/settled/old.rec"; touch -t 202001010000 "$GATE_RCPT_DIR/settled/old.rec"; sweep $((T0 + 60))
  chk "sweep20b a sweep that did no work trims nothing" test -e "$GATE_RCPT_DIR/settled/old.rec"
}
g_sw_switch() {
  echo "── sweep: switches and errexit ──"
  case_closed failed x; DRY_RUN=1 sweep $((T0 + 600))
  chk "sweep17 DRY_RUN=1: the sweep does nothing" streq "$(lists_n):$(mail_n):$(pending_n)" "0:0:1"
  case_closed failed x; GATE_RCPT_ENABLED=0 sweep $((T0 + 600))
  chk "sweep17b kill switch: the sweep does nothing and the record stays" streq "$(lists_n):$(mail_n):$(pending_n)" "0:0:1"
  case_closed failed x; : > "$FD/show.fail"; echo x > "$FD/mailfail.$TO"; echo x > "$FD/mailfail.author-x"
  chk "sweep18 under set -euo pipefail, bd show failing and every mail failing, a bare sweep still runs to its end" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
  new_case; mkrec; : > "$FD/list.fail"
  chk "sweep18b ... and with bd list failing" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
}

# ═════════════════════════════════════════════════ the wake-up nudge (ga-9kxy44u) ══════════════════════════════════════════════════════════════════
# An idle crew never sees a wait-idle nudge that stays queued, and mail is read at the NEXT turn, which an idle crew does not have (12/11: three beads, 65 min
# to 4 h parked in gate:needs-fix with the crew idle at its prompt; one short --delivery immediate nudge woke each in about a minute). So the author that
# the receipt gives up on gets, besides the mail, ONE short immediate nudge: only when the bead is still theirs and not back in the gate, and only when
# their pane reads as an idle Claude Code prompt (a typed line into a dialog, a busy turn or a shell is worse than none).
wake_n() { grep -c -- '--delivery immediate' "$FD/nudge.argv" 2>/dev/null || true; }
pane_is() { cp "$SB/panes/$1.txt" "$FD/pane.$TO"; }
wake_ev() { jq -r 'select(.event=="author_nudge_receipt") | .wake' "$QG_LOG" 2>/dev/null | tr '\n' ' '; }
case_wake() { # <queued|failed> — a record at T0, the nudge bead in that state, the recipient's pane idle
  new_case; mkrec "$T0"; pane_is idle
  if [ "$1" = queued ]; then put_list open "$(nbead queued open "" $((T0 + 3)) "$MSG1")"; else put_list open; put_list closed "$(nbead "$1" closed "queued nudge session fence mismatch" $((T0 + 1)) "$MSG1")"; fi
}
wake_veto() { # <name> <reason in the comment> <assignee> <labels...> — a bead the wake must leave alone
  local name="$1" frag="$2" asg="$3"; shift 3
  case_wake failed; ASG="$asg" put_bead "$BEAD" in_progress "$@"; sweep $((T0 + 600))
  chk "wake6 [$name] no wake-up and no pane read; the author is still mailed; the comment and the event say it was skipped, and why" streq "$(wake_n):$(nlines "$FD/peek.log"):$(mail_n):$(has "$FD/comment.1" "No immediate nudge was sent" && has "$FD/comment.1" "$frag" && echo y):$(wake_ev)" "0:0:1:y:skipped "
}
wake_pane() { # <name> <reason in the comment> — the pane is already in place: no wake-up, the mail still goes
  chk "wake7 [$1] the pane does not read as an idle prompt: no wake-up, the author is still mailed, the comment says why" streq "$(wake_n):$(mail_n):$(has "$FD/comment.1" "No immediate nudge was sent" && has "$FD/comment.1" "$2" && echo y):$(wake_ev)" "0:1:y:skipped "
}
g_sw_wake() {
  echo "── sweep: the wake-up nudge ──"
  case_wake queued; sweep $((T0 + 1800))
  chk "wake1 still queued at the limit and the recipient's pane idle: the author is mailed AND ONE immediate nudge goes to that recipient (--json, its own identity)" streq "$(mail_n):$(wake_n):$(grep -c -- "^session nudge $TO .* --delivery immediate --json\$" "$FD/nudge.argv"):$(tr '\n' ' ' < "$FD/peek.log")" "1:1:1:$TO "
  W="$(cat "$FD/wake.text" 2>/dev/null)"
  chk "wake1b the text names the bead and the GATE-FEEDBACK and is ONE short line (a long nudge reaches the pane truncated)" streq "$(has "$FD/wake.text" "$BEAD" && has "$FD/wake.text" "GATE-FEEDBACK" && echo y):$([ -n "$W" ] && [ "${#W}" -le 240 ] && echo short):$(printf '%s' "$W" | grep -c '')" "y:short:1"
  chk "wake1c ... with no slash-command token: typed into a prompt, '/gate-done' is attached as the skill and would re-submit the unfixed work" streq "$([ -n "$W" ] && echo text):$(printf '%s' "$W" | grep -c -E '(^|[[:space:]])/[a-z]')" "text:0"
  chk "wake1d the comment says the immediate nudge was DELIVERED (typed); the event and the settled record say wake=delivered" streq "$(has "$FD/comment.1" "immediate nudge" && has "$FD/comment.1" "DELIVERED" && echo y):$(wake_ev):$(cat "$GATE_RCPT_DIR"/settled/*.rec 2>/dev/null | sed -n 's/^wake=//p' | tr '\n' ' ')" "y:delivered :delivered "
  sweep $((T0 + 5000)); chk "wake2 a settled receipt wakes nobody again" streq "$(wake_n):$(mail_n)" "1:1"
  chk "wake2b the attempt is written into the record BEFORE anything is typed (a sweep that dies after the wake, or a settle that fails, must not type a second line)" has "$FD/rec.at-wake" "wake_attempt="
  case_wake failed; printf 'wake_attempt=%s\n' "$T0" >> "$(recf "$BEAD" "$TO")"; sweep $((T0 + 600))
  chk "wake2c a record that already carries an attempt (an earlier sweep died or could not settle it) is mailed again but NOT woken again, and no pane is read" streq "$(mail_n):$(wake_n):$(nlines "$FD/peek.log"):$(has "$FD/comment.1" "already tried" && echo y)" "1:0:0:y"
  if [ "$(id -u)" != 0 ]; then
    case_wake failed; chmod 444 "$(recf "$BEAD" "$TO")"; sweep $((T0 + 600))
    chk "wake2d an attempt that cannot be written down is a skip (a wake-up nobody recorded could repeat on every sweep), the mail still goes" streq "$(wake_n):$(mail_n):$(has "$FD/comment.1" "could not be written down" && echo y)" "0:1:y"
  fi
  case_wake queued; sweep $((T0 + 1799))
  chk "wake3 one second short of the limit nothing happens: no mail, no pane read, no wake-up" streq "$(mail_n):$(wake_n):$(nlines "$FD/peek.log")" "0:0:0"
  case_wake failed; sweep $((T0 + 600))
  chk "wake4 a nudge that is GONE (failed: the session restarted) wakes the new session at once, without waiting for the age rule" streq "$(mail_n):$(wake_n)" "1:1"
  case_wake failed; put_bead "$BEAD" closed; sweep $((T0 + 600))
  chk "wake5 a closed source bead is moot: no wake-up and no pane read" streq "$(wake_n):$(nlines "$FD/peek.log")" "0:0"
  case_wake failed; put_bead "$BEAD" open gate:passed; sweep $((T0 + 600))
  chk "wake5b so is a gate:passed one" streq "$(wake_n):$(nlines "$FD/peek.log")" "0:0"

  wake_veto assignee-cleared "no longer assigned to" "" gate:needs-fix
  wake_veto assignee-other "no longer assigned to" dog-remote-1 gate:needs-fix
  wake_veto resubmitted-queued "back in the gate" author-x gate:needs-fix gate:queued
  wake_veto resubmitted-reviewing "back in the gate" author-x gate:needs-fix gate:reviewing
  wake_veto parked-for-humans "parked" author-x gate:needs-fix gate:needs-human:technical
  case_wake failed; : > "$FD/show.fail"; sweep $((T0 + 600))
  chk "wake6b the bead cannot be read: no wake-up (an interrupt on a guess), no pane read, the mail still goes, the comment says so" streq "$(wake_n):$(nlines "$FD/peek.log"):$(mail_n):$(has "$FD/comment.1" "No immediate nudge was sent" && has "$FD/comment.1" "still waits for the crew" && echo y)" "0:0:1:y"
  case_wake failed; echo '[{"id":"wa-2h615v.7","status":"in_progress","assignee":"author-x","labels":"gate:needs-fix"}]' > "$FD/bead.$BEAD.json"; sweep $((T0 + 600))
  chk "wake6e the labels cannot be read (a string, not a list): unknown is not 'no labels', so no wake-up and no pane read; the mail still goes" streq "$(wake_n):$(nlines "$FD/peek.log"):$(mail_n):$(has "$FD/comment.1" "labels could not be read" && echo y)" "0:0:1:y"
  new_case; echo queued > "$FD/nudge.$TO"; BEAD_CITY="$RIGCITY" send "$BEAD" "$TO" "" "$MSG1" "$T0"; put_list open; put_list closed "$(nbead failed closed x $((T0 + 1)) "$MSG1")"; pane_is idle
  ASG="" put_bead "$BEAD" in_progress gate:needs-fix; sweep $((T0 + 600))
  chk "wake6d no author on the record and nobody assigned: two empty strings are not a match, so no wake-up" streq "$(wake_n):$(nlines "$FD/peek.log")" "0:0"
  case_wake failed; ASG="$TO" put_bead "$BEAD" in_progress gate:needs-fix; sweep $((T0 + 600))
  chk "wake6c the bead may be held under the recipient's own name instead of the author's (identity is spelled both ways): still woken" streq "$(wake_n)" "1"

  case_wake failed; pane_is busy; sweep $((T0 + 600)); wake_pane busy "busy"
  case_wake failed; pane_is dialog; sweep $((T0 + 600)); wake_pane "permission dialog (its option cursor is a '❯' too)" "dialog"
  case_wake failed; pane_is ask; sweep $((T0 + 600)); wake_pane "selection menu (an AskUserQuestion waiting for the human)" "dialog"
  case_wake failed; pane_is shell; sweep $((T0 + 600)); wake_pane "a shell prompt, no Claude Code" "not a Claude Code prompt"
  case_wake failed; : > "$FD/pane.$TO"; sweep $((T0 + 600)); wake_pane "an empty pane" "could not be read"
  case_wake failed; rm -f "$FD/pane.$TO"; : > "$FD/peek.fail"; sweep $((T0 + 600)); wake_pane "peek fails (session not found)" "could not be read"
  case_wake failed; : > "$FD/peek.rc1"; sweep $((T0 + 600)); wake_pane "peek printed an idle pane and still exited 1 (cut short)" "could not be read"
  case_wake failed; printf '%s' $'✻ Pondering…'"$CHROME" > "$FD/pane.$TO"; sweep $((T0 + 600)); wake_pane "a spinner whose timer cannot be read" "not a Claude Code prompt"
  case_wake failed; printf '%s' $'esc to interrupt'"$CHROME" > "$FD/pane.$TO"; sweep $((T0 + 600)); wake_pane "an older build that only says 'esc to interrupt'" "busy"
  case_wake failed; printf '%s' $'✢ Kneading… (45s · ↓ 1.2k tokens)'"$CHROME" > "$FD/pane.$TO"; sweep $((T0 + 600)); wake_pane "a timer in seconds" "busy"
  case_wake failed; printf '%s' $'⏺ Vou verificar… e já volto\n'"$CHROME" > "$FD/pane.$TO"; sweep $((T0 + 600))
  chk "wake7b an ellipsis in the crew's own prose is not a spinner: idle, woken" streq "$(wake_n)" "1"
  case_wake failed; { echo "Do you want to proceed?  1. Yes  2. Yes, and don't ask again  3. No"; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo "old scrollback $i"; done; cat "$SB/panes/idle.txt"; } > "$FD/pane.$TO"; sweep $((T0 + 600))
  chk "wake7c dialog text only in OLD scrollback (outside the last lines) does not hold a wake-up back" streq "$(wake_n)" "1"
  case_wake failed; printf '%s' $'✻ Baked for 2h 3m 4s · done 9:50 AM' > "$FD/pane.$TO"; sweep $((T0 + 600))
  chk "wake7d a turn summary with an hours unit and no prompt box is idle" streq "$(wake_n)" "1"

  for spec in queued:QUEUED:queued empty:UNCONFIRMED:unreadable garbage:UNCONFIRMED:unreadable notok:UNCONFIRMED:unreadable fail:FAILED:failed slow:"FAILED (rc 124":failed; do
    mode="${spec%%:*}"; rest="${spec#*:}"; word="${rest%%:*}"; ev="${rest#*:}"
    case_wake failed; echo "$mode" > "$FD/wake.$TO"; GATE_RCPT_WAKE_TIMEOUT_S=1 sweep $((T0 + 600))
    chk "wake8 [$mode] the immediate nudge ended as '$ev': the comment says $word, NEVER DELIVERED; the event says wake=$ev; the receipt is settled and the author mailed" streq "$(has "$FD/comment.1" "$word" && echo y):$(has "$FD/comment.1" "DELIVERED" || echo n):$(wake_ev):$(mail_n):$(pending_n)" "y:n:$ev :1:0"
  done
  case_wake failed; GATE_RCPT_WAKE_TIMEOUT_S=7 sweep $((T0 + 600))
  chk "wake13 BOTH gc calls of the wake-up (the pane read, the nudge) run under timeout with the configured bound: a hung engine must not hold the gate lock" streq "$(grep -c -- '^-k 5 7 gc --city .* session peek' "$FD/timeout.log"):$(grep -c -- '^-k 5 7 gc --city .* session nudge' "$FD/timeout.log")" "1:1"
  for v in 0 abc ""; do
    case_wake failed; GATE_RCPT_WAKE_TIMEOUT_S="$v" sweep $((T0 + 600))
    chk "wake13b [bound '$v'] 0, text and empty fall back to 20 s (a literal 0 would mean no bound at all)" streq "$(grep -c -- '^-k 5 20 gc --city' "$FD/timeout.log")" "2"
  done
  case_wake failed; GATE_RCPT_WAKE=0 sweep $((T0 + 600))
  chk "wake9 GATE_RCPT_WAKE=0: no pane read and no wake-up, the mail still goes, the comment says it is switched off" streq "$(wake_n):$(nlines "$FD/peek.log"):$(mail_n):$(has "$FD/comment.1" "switched off" && echo y)" "0:0:1:y"
  case_wake failed; : > "$GC_CITY/.gc/gate-nudge-wake.off"; sweep $((T0 + 600))
  chk "wake9b the off-file does the same (an env var is hard to change under launchd)" streq "$(wake_n):$(mail_n)" "0:1"
  case_wake failed; echo x > "$FD/mailfail.$TO"; echo x > "$FD/mailfail.author-x"; sweep $((T0 + 600))
  chk "wake10 mail that cannot be sent (escalated to the Mayor) does not stop the wake-up" streq "$(wake_n):$(settled_verdicts)" "1:escalated "
  case_wake failed; ( unset -f notify_author_with_fallback; GATE_RCPT_NOW=$((T0 + 600)) PATH="$SANDBOX_PATH" gate_rcpt_sweep )
  chk "wake11 no mail helper (the record stays for the next sweep): no wake-up either, or the next sweep would wake twice" streq "$(wake_n):$(mail_n):$(pending_n)" "0:0:1"
  case_wake failed; : > "$FD/peek.fail"
  chk "wake12 under set -euo pipefail with the pane unreadable a bare sweep still runs to its end" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
  case_wake failed; echo fail > "$FD/wake.$TO"
  chk "wake12b ... and with the wake-up itself failing" streq "$(bare_sweep_reaches_end $((T0 + 600)))" REACHED
}

# ═════════════════════════════════════════════════ static ════════════════════════════════════════════════════════════════════════════════════════════
g_static() {
  echo "── static ──"
  local l_pm l_nr
  chk "static1 the dispatcher loads the lib only when readable and sets GATE_RCPT_LIB_OK from the function it must define" bash -c 'grep -qF "[ -r \"\$_GATE_RCPT_LIB\" ]" "$1" && grep -qF "type gate_rcpt_sweep >/dev/null 2>&1; then GATE_RCPT_LIB_OK=1" "$1"' _ "$DISPATCHER"
  l_pm="$(grep -n 'gate_pm_sweep || true' "$DISPATCHER" | head -n1 | cut -d: -f1)"
  l_nr="$(grep -n 'gate_rcpt_sweep || true' "$DISPATCHER" | head -n1 | cut -d: -f1)"
  chk "static2 the sweep is called once, after the post-merge sweep, with its failure neutralised" streq "$(grep -c 'gate_rcpt_sweep || true' "$DISPATCHER"):$([ -n "$l_nr" ] && [ -n "$l_pm" ] && [ "$l_nr" -gt "$l_pm" ] && echo after)" "1:after"
  chk "static3 not in a Phase-C-only child pass (the guard sits just above the call)" bash -c 'sed -n "$(( $2 - 4 )),$2p" "$1" | grep -qF "GATE_PHASE_C_ONLY:-0}\" != \"1\""' _ "$DISPATCHER" "${l_nr:-0}"
  chk "static4 a lib that did not load is said out loud by the sweep call site" bash -c 'sed -n "$2,$(( $2 + 2 ))p" "$1" | grep -qF "NOT being verified"' _ "$DISPATCHER" "${l_nr:-0}"
  chk "static5 the nudge asks for --json and the call stays in THIS shell (output to a file, no command substitution)" streq "$(grep -c 'if gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json >' "$DISPATCHER"):$(grep -c '\$(gc --city "\$GC_CITY" session nudge' "$DISPATCHER")" "1:0"
  chk "static6 the record call is guarded by declare -F (sibling selftests eval the function without the lib) and by the neutralising || true" streq "$(grep -c 'declare -F gate_rcpt_record' "$DISPATCHER"):$(grep -c 'gate_rcpt_record "\$_bead_id".* || true' "$DISPATCHER")" "1:1"
  chk "static7 both files pass bash -n" bash -c 'bash -n "$1" && bash -n "$2"' _ "$DISPATCHER" "$LIB"
  if [ -n "${B32_BASH:-}" ] && [ -x "${B32_BASH:-}" ]; then
    chk "static8 and a real bash 3.2 (B32_BASH) accepts both, printing nothing" streq "$("$B32_BASH" -n "$DISPATCHER" 2>&1)$("$B32_BASH" -n "$LIB" 2>&1)" ""
  fi
}

GROUPS_ALL="send sw_inject sw_hook sw_gone sw_wait sw_age sw_unread sw_moot sw_escal sw_wake sw_cap sw_damage sw_match sw_budget sw_switch static"
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
 ("l01", "lib", '    injected) echo "settle:injected into the session"; return 0 ;;', '    injected) echo "fallback:x"; return 0 ;;', "sw_inject", "an injected nudge is treated as lost"),
 ("l02", "lib", "    failed|expired|superseded) echo \"fallback:it ended as '$st'${rsn:+ ($rsn)} without reaching the session\"; return 0 ;;", "    failed|expired|superseded) ;;", "sw_gone", "failed/expired wait for the age rule instead of mailing now"),
 ("l03", "lib", 'if [ "$age" -ge "$max" ]; then', 'if [ "$age" -gt "$max" ]; then', "sw_wait", "off by one at the pending limit"),
 ("l04", "lib", 'else cls="UNREADABLE"; fi', 'else cls="NONE"; fi', "sw_unread", "an unreadable closed list is read as 'not found'"),
 ("l05", "lib", '    if [ "$st" = "closed" ]; then\n      _gate_rcpt_say', '    if [ "$st" = "never" ]; then\n      _gate_rcpt_say', "sw_moot sw_wake", "a closed source bead still gets the mail (and the wake-up)"),
 ("l06", "lib", '    case " $labels " in *" gate:passed "*) st=closed ;; esac\n', '', "sw_moot sw_wake", "gate:passed is no longer moot"),
 ("l07", "lib", '  if [ -z "$st" ]; then\n    note=', '  if [ -n "$st" ]; then\n    note=', "sw_moot", "an unreadable source bead is not noted / a readable one is"),
 ("l08", "lib", '    [ "$age" -lt "${GATE_RCPT_MIN_AGE_S:-90}" ] && continue\n', '', "sw_age", "no minimum age"),
 ("l09", "lib", 'if [ -n "$last" ] && [ $((now - last)) -lt "${GATE_RCPT_RECHECK_S:-300}" ]; then continue; fi', 'if false; then continue; fi', "sw_age", "no re-check throttle"),
 ("l10", "lib", '($t != null) and ($t >= ($sent - 300))', '($t != null)', "sw_match", "no time window on the nudge bead"),
 ("l11", "lib", '    | .[0]\n    | if . == null then "NONE"', '    | .[-1]\n    | if . == null then "NONE"', "sw_match", "the newest look-alike instead of the oldest"),
 ("l12", "lib", '  [ "${DRY_RUN:-0}" = "1" ] && return 0\n  d="$(gate_rcpt_dir)"\n  [ -d "$d/pending" ] || return 0', '  d="$(gate_rcpt_dir)"\n  [ -d "$d/pending" ] || return 0', "sw_switch", "the sweep ignores DRY_RUN"),
 ("l13", "lib", '  [ "${DRY_RUN:-0}" = "1" ] && return 0\n  if [ -z "$bead" ]', '  if [ -z "$bead" ]', "send", "the record ignores DRY_RUN"),
 ("l14", "lib", 'BEAD_CITY="${bcity:-${GC_CITY:-}}" notify_author_with_fallback', 'notify_author_with_fallback', "sw_escal", "the helper comments in the HQ store"),
 ("l15", "lib", 'if mv "$d/pending/$key.rec" "$d/settled/$key.$now.rec" 2>/dev/null; then', 'if false; then', "sw_gone", "a settled record is deleted instead of kept"),
 ("l16", "lib", '        if [ "$cls" = "NONE" ]; then\n          if [ "$closed_loaded" = "0" ]; then', '        if true; then\n          if [ "$closed_loaded" = "0" ]; then', "sw_wait", "the closed list is read even when the open one matched"),
 ("l17", "lib", '    [ "$n" -ge "$max" ] && break\n', '', "sw_cap", "no per-sweep cap"),
 ("l18", "lib", "      *)          echo \"fallback:it was still not delivered after ${age}s (state '${st:-none}')\" ;;", '      *)          echo "wait:$cls" ;;', "sw_wait", "a queued nudge never ages into a mail"),
 ("l19", "lib", 'if [ "$rc" = "0" ]; then\n    verdict="mailed"', 'if [ "$rc" = "1" ]; then\n    verdict="mailed"', "sw_gone sw_escal", "mailed and escalated swapped"),
 ("l20", "lib", '$(_gate_rcpt_classify "$closed_json" "$probe" "$sent" "$to") || cls="UNREADABLE"', '$(_gate_rcpt_classify "$closed_json" "$probe" "$sent" "$to") || cls="NONE"', "sw_unread", "a jq failure on the closed list is read as 'not found'"),
 ("l21", "lib", '|| [ ! -s "$d/pending/$key.msg" ]; then', '; then', "sw_damage", "a record without its text is not damaged"),
 ("l25", "lib", 'if [ -n "$day" ] && closed_json=$(_gate_rcpt_list closed "$day"); then closed_ok=1; fi', 'if closed_json=$(_gate_rcpt_list closed "$day"); then closed_ok=1; fi', "sw_unread", "an uncomputable day still queries the closed list"),
 ("l22", "lib", 'if [ $(( $(date +%s) - t0 )) -ge "$budget" ]; then', 'if false; then', "sw_budget", "no time budget"),
 ("l23", "lib", '-mtime +30 -exec rm -f {} +', '-mtime +3650 -exec rm -f {} +', "sw_budget", "settled records are kept far too long"),
 ("l26", "lib", '    accepted_for_injection) if [ "$sts" = "closed" ]; then echo "settle:accepted for hook-transport injection"; return 0; fi ;;\n', '', "sw_hook", "a closed accepted_for_injection (the hook-transport success) is read as a lost nudge: the reviewer's finding"),
 ("l27", "lib", 'accepted_for_injection) if [ "$sts" = "closed" ]; then echo', 'accepted_for_injection) if true; then echo', "sw_hook", "an OPEN accepted_for_injection is settled as delivered before the hook drained it"),
 ("l28", "lib", 'index("agent:" + $to)) != null)) then 0 else 1 end)', 'index("agent:" + $to)) != null)) then 1 else 1 end)', "sw_match", "the recipient's own nudge bead is not preferred over an older look-alike for another session"),
 ("l29", "lib", '| map(select(type == "string" and . != ""))', '| map(select(type == "string"))', "sw_gone", "an empty terminal_reason hides the engine's close_reason (jq // keeps the empty string)"),
 ("l24", "lib", 'if [ "$n" -gt 0 ]; then find', 'if true; then find', "sw_budget", "an idle sweep trims too"),
 ("d01", "disp", 'if [ "$_noc" != "delivered" ] && [ "$_defer" != "1" ] && declare -F', 'if [ "$_defer" != "1" ] && declare -F', "send", "a delivered nudge is recorded too"),
 ("d02", "disp", 'if [ "$_noc" != "delivered" ] && [ "$_defer" != "1" ] && declare -F', 'if [ "$_noc" != "delivered" ] && declare -F', "send", "an ephemeral author is recorded"),
 ("d03", "disp", '--delivery wait-idle --json >"${_nf:-/dev/null}"', '--delivery wait-idle >"${_nf:-/dev/null}"', "send", "no --json"),
 ("d04", "disp", "jq -er 'select(.ok == true) | .outcome' \"$_nf\"", "jq -er '.outcome' \"$_nf\"", "send", "ok:false is believed"),
 ("d05", "disp", 'if gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json >"${_nf:-/dev/null}" 2>/dev/null; then', 'if _x=$(gc --city "$GC_CITY" session nudge "$_candidate" "$_message" --delivery wait-idle --json 2>/dev/null); then', "static", "the nudge runs in a subshell"),
 ("d06", "disp", 'if [ "${GATE_RCPT_LIB_OK:-0}" = "1" ]; then gate_rcpt_sweep || true', 'if [ "${GATE_RCPT_LIB_OK:-0}" = "1" ]; then :', "static", "the sweep is never called"),
 ("d07", "disp", 'if [ "${GATE_PHASE_C_ONLY:-0}" != "1" ]; then\n  if [ "${GATE_RCPT_LIB_OK:-0}" = "1" ]', 'if true; then\n  if [ "${GATE_RCPT_LIB_OK:-0}" = "1" ]', "static", "the sweep runs in a Phase-C-only pass"),
 ("d08", "disp", 'gate_rcpt_record "$_bead_id" "${BEAD_CITY:-$GC_CITY}" "$_notified" "$_author" "${_noc:-unreadable}" "$_message" "$_fail_context" || true', 'gate_rcpt_record "$_bead_id" "${BEAD_CITY:-$GC_CITY}" "$_notified" "$_author" "${_noc:-unreadable}" "$_message" "$_fail_context"', "static", "the record call is no longer neutralised"),
 # ── the wake-up (ga-9kxy44u) ──
 ("w01", "lib", '"$txt" --delivery immediate --json || rc=$?', '"$txt" --delivery wait-idle --json || rc=$?', "sw_wake", "the wake-up is queued like the notice it stands in for"),
 ("w02", "lib", '--delivery immediate --json || rc=$?', '--delivery immediate || rc=$?', "sw_wake", "the wake-up asks for no --json (its outcome cannot be read)"),
 ("w03", "lib", '  wake=$(_gate_rcpt_wake "$bead" "$to" "$author" "$st" "$labels" "$asg") || wake="skipped|the wake-up check itself failed"', '  wake="skipped|x"', "sw_wake", "nobody is ever woken"),
 ("w04", "lib", '    busy)    echo "skipped|its pane shows a turn running (busy): nothing is typed into it, the queued notice and the mail wait for its next prompt"; return 0 ;;', '    busy) ;;', "sw_wake", "a line is typed into a pane that is running a turn"),
 ("w05a", "lib", r"""'Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel'""", r"""'Enter to select|Esc to cancel'""", "sw_wake", "a permission prompt is not recognised (its option cursor is a prompt glyph too)"),
 ("w05b", "lib", r"""'Do you want to proceed\?|requires confirmation|Enter to select|Esc to cancel'""", r"""'Do you want to proceed\?|requires confirmation'""", "sw_wake", "a selection menu waiting for the human is typed into"),
 ("w06", "lib", "tail_out=$(printf '%s\\n' \"$pane\" | tail -n 12)", 'tail_out="$pane"', "sw_wake", "dialog text left in old scrollback holds the wake-up back for good"),
 ("w07", "lib", "| tail -n 12)", "| tail -n 2)", "sw_wake", "the dialog window is too small to reach the prompt"),
 ("w08", "lib", 'then echo idle; else echo unknown; fi', 'then echo idle; else echo idle; fi', "sw_wake", "a shell prompt reads as idle"),
 ("w09", "lib", 'if [ "$rc" != "0" ] || [ -z "$pane" ]; then echo unread; return 0; fi', 'if [ -z "$pane" ]; then echo unread; return 0; fi', "sw_wake", "a peek that was cut short is trusted"),
 ("w10", "lib", 'if [ "$rc" != "0" ] || [ -z "$pane" ]; then echo unread; return 0; fi', 'if [ "$rc" != "0" ]; then echo unread; return 0; fi', "sw_wake", "an empty pane is read as a pane"),
 ("w11", "lib", "dur='([0-9]+h[[:space:]]+)?([0-9]+m[[:space:]]+)?[0-9]+s'", "dur='([0-9]+m[[:space:]]+)?[0-9]+s'", "sw_wake", "the elapsed timer has no hours unit (a turn past 1 h reads as idle)"),
 ("w12", "lib", "grep 'esc to interrupt'", "grep 'esc to interruptXX'", "sw_wake", "older builds' busy marker is lost"),
 ("w13", "lib", r"""if printf '%s' "$pane" | grep -E "^[[:space:]]*${glyph}[[:space:]]+[^[:space:]]+(…|\.\.\.)" >/dev/null 2>&1; then echo unknown; return 0; fi""", 'if false; then echo unknown; return 0; fi', "sw_wake", "a spinner whose timer cannot be read reads as idle"),
 ("w14", "lib", 'grep -E "^[[:space:]]*${glyph}[[:space:]]+[^[:space:]]+ for ${dur}"', 'grep -E "^[[:space:]]*${glyph}[[:space:]]+[^[:space:]]+ forXX ${dur}"', "sw_wake", "a finished turn's summary line is not recognised"),
 ("w15a", "lib", '*" gate:queued "*|*" gate:reviewing "*)', '*" gate:reviewing "*)', "sw_wake", "a bead that is back in the gate (queued) is woken"),
 ("w15b", "lib", '*" gate:queued "*|*" gate:reviewing "*)', '*" gate:queued "*)', "sw_wake", "a bead under review is woken"),
 ("w16", "lib", '*" gate:needs-human"*) echo "skipped|the bead is parked for a human', '*" gate:never-human"*) echo "skipped|the bead is parked for a human', "sw_wake", "a bead parked for a human is told to fix and re-run"),
 ("w17", "lib", 'if [ -z "$asg" ] || { [ "$asg" != "$author" ] && [ "$asg" != "$to" ]; }; then', 'if false; then', "sw_wake", "a bead that is no longer the author's is woken"),
 ("w18", "lib", '{ [ "$asg" != "$author" ] && [ "$asg" != "$to" ]; }', '[ "$asg" != "$author" ]', "sw_wake", "the recipient's own name is not accepted as the owner"),
 ("w19", "lib", 'if [ -z "$asg" ] || { [ "$asg" != "$author" ]', 'if { [ "$asg" != "$author" ]', "sw_wake", "two empty strings count as a match"),
 ("w20", "lib", '  if [ -z "$st" ]; then echo "skipped|the bead\'s state could not be read', '  if false; then echo "skipped|the bead\'s state could not be read', "sw_wake", "an unreadable bead is woken on a guess"),
 ("w21", "lib", 'queued)    echo "queued|the engine queued it instead of typing it" ;;', 'queued)    echo "delivered|typed into the session" ;;', "sw_wake", "a queued wake-up is reported as typed"),
 ("w22", "lib", '*)         echo "unreadable|rc 0 but no readable outcome" ;;', '*)         echo "delivered|typed into the session" ;;', "sw_wake", "an unreadable outcome is reported as typed"),
 ("w23", "lib", 'echo "failed|rc $rc"; return 0', 'echo "delivered|typed into the session"; return 0', "sw_wake", "a failed wake-up is reported as typed"),
 ("w24", "lib", 'timeout -k 5 "$tmo" gc --city "${GC_CITY:-}" "$@" >"$out" 2>/dev/null || rc=$?', 'gc --city "${GC_CITY:-}" "$@" >"$out" 2>/dev/null || rc=$?', "sw_wake", "the gc calls of the wake-up have no time bound (a hung engine holds the gate lock)"),
 ("w25", "lib", "case \"$tmo\" in ''|*[!0-9]*|0) tmo=20 ;; esac", "case \"$tmo\" in ''|*[!0-9]*) tmo=20 ;; esac", "sw_wake", "a bound of 0 means no bound at all"),
 ("w26", "lib", 'case "${GATE_RCPT_WAKE:-1}" in 0) return 1 ;; esac', 'case "${GATE_RCPT_WAKE:-1}" in 99) return 1 ;; esac', "sw_wake", "GATE_RCPT_WAKE=0 does not switch the wake-up off"),
 ("w27", "lib", '  [ -e "${GATE_RCPT_WAKE_OFF_FILE:-${GC_CITY:-/nonexistent}/.gc/gate-nudge-wake.off}" ] && return 1\n', '', "sw_wake", "the off-file does not switch the wake-up off"),
 ("w28", "lib", 'if [ "$rc" = "99" ]; then\n    _gate_rcpt_warn "ga-5aovajz: notify_author_with_fallback is not defined', 'if [ "$rc" = "98" ]; then\n    _gate_rcpt_warn "ga-5aovajz: notify_author_with_fallback is not defined', "sw_wake", "a record kept for the next sweep (no mail helper) has already woken its author"),
 ("w29", "lib", 'fix what they ask and run gate-done again."', 'fix what they ask and run /gate-done again."', "sw_wake", "the wake-up carries a slash-command token (attached as a skill)"),
 ("w30", "lib", 'read the GATE-FEEDBACK and the gate comments', 'read the GATE-FEEDBACK\nand the gate comments', "sw_wake", "the wake-up is more than one line"),
 ("w31", "lib", '  txt="Gate FAIL on $bead (the earlier notice may not have reached you): read the GATE-FEEDBACK and the gate comments on the bead (bd show $bead), fix what they ask and run gate-done again."', '  txt="Gate FAIL (the earlier notice may not have reached you): read the GATE-FEEDBACK and the gate comments on the bead, fix what they ask and run gate-done again."', "sw_wake", "the wake-up does not say which bead"),
 ("w32", "lib", 'fix what they ask and run gate-done again."', 'fix what they ask and run gate-done again. ' + '.' * 260 + '"', "sw_wake", "the wake-up is long enough to arrive truncated"),
 ("w33", "lib", '_gate_rcpt_gc "$f" session peek "$1" --lines 40 || rc=$?', '_gate_rcpt_gc "$f" session peek "nobody" --lines 40 || rc=$?', "sw_wake", "the pane read is of another session"),
 ("w34", "lib", 'session nudge "$to" "$txt"', 'session nudge "nobody" "$txt"', "sw_wake", "the wake-up goes to another session"),
 ("w35", "lib", 'age_s "$age" reason "$why" wake "$wres" wake_why "$wwhy" \\\n', 'age_s "$age" reason "$why" \\\n', "sw_wake", "the event does not carry the wake-up outcome"),
 ("w36", "lib", "  printf 'wake=%s\\nwake_why=%s\\n' \"$wres\" \"$(_gate_rcpt_oneline \"$wwhy\")\" >> \"$f\" 2>/dev/null || true\n", '  :\n', "sw_wake", "the settled record does not carry the wake-up outcome"),
 ("w37", "lib", '${how}${note}${wnote} A queued nudge', '${how}${note} A queued nudge', "sw_wake", "the bead comment does not say what happened to the wake-up"),
 ("w39", "lib", '  if [ -n "$(_gate_rcpt_get "$f" wake_attempt)" ]; then', '  if false; then', "sw_wake", "a record that already carries a wake attempt is woken again"),
 ("w40", "lib", "  elif ! printf 'wake_attempt=%s\\n' \"$(_gate_rcpt_now)\" >> \"$f\" 2>/dev/null; then", '  elif false; then', "sw_wake", "the wake attempt is not written down before it is typed"),
 ("w38", "lib", '  if [ "$labels" = "?" ]; then echo "skipped|the bead\'s labels could not be read', '  if false; then echo "skipped|the bead\'s labels could not be read', "sw_wake", "labels that cannot be read count as no labels (a bead back in the gate is woken)"),
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
        GNR_NO_MUTANTS=1 GNR_GROUPS="$groups" GATE_RCPT_LIB_UNDER_TEST="$MUT/$id.lib" bash "$SELF" > "$MUT/$id.out" 2>&1 < /dev/null
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
