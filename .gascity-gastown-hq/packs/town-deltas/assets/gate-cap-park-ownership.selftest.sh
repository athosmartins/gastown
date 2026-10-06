#!/usr/bin/env bash
# gate-cap-park-ownership.selftest.sh (ga-bwtrrf)
#
# When the gate's fix-attempt cap is exhausted, quality-gate-dispatcher.sh parks the bead with
# gate:needs-human:technical — a TECHNICAL circuit-break, which is the Mayor's/crew's to resolve,
# never Athos's (town rule 2). The branch then did `assign "$BEAD_ID" ""` unconditionally, so the
# bead was left with NO owner and NO next-action:<who>: nothing said whose turn it was, it sat
# 12.5h like that (wa-2362s2.2: cleared 06:25Z, a live crew had to be restored by hand 19:01Z) and
# Athos read the unowned card as his. The park must always say whose turn it is:
#   - author is a LIVE named crew  -> KEEP the assignee (they hold the context and were mailed);
#   - otherwise (ephemeral builder / dead session) -> assignee cleared as before, BUT
#       next-action:mayor + a "Pergunta:" comment (the convention next-action-coordinator-alert.sh
#       keys on) say what is needed;
#   - never story:needs-human / next-action:athos on a :technical park — only :product goes to Athos.
#
# Strategy (same as gate-fail-ephemeral-mayor-defer.selftest.sh): extract the LIVE branch text from
# quality-gate-dispatcher.sh (SELFTEST-EXTRACT cap-branch) and eval it with bd/gc/notify stubbed
# over a file-backed bead — never a hand-copied duplicate. It asserts the bead's final STATE.
#
# GATE_DISPATCHER_UNDER_TEST=<file> points this at another copy (red-before-green proof).
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${GATE_DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has_label()  { grep -qxF -- "$1" "$FAKE_LABELS" 2>/dev/null; }
want_label() { if has_label "$2"; then ok "$1"; else bad "$1 — label [$2] missing (have: $(tr '\n' ' ' <"$FAKE_LABELS"))"; fi; }
no_label()   { if has_label "$2"; then bad "$1 — label [$2] must NOT be set"; else ok "$1"; fi; }

echo "== gate-cap-park-ownership.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'; }
extract_fn()    { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {f=1} f {print} f && /^\}/ {exit}' "$1"; }

CAP_BODY="$(extract_block "$DISPATCHER" cap-branch)"
[ -n "$CAP_BODY" ] || { echo "FATAL: SELFTEST-EXTRACT cap-branch not found in $DISPATCHER" >&2; exit 2; }
for fn in gate_fail_assignee_action resolve_recycled_author; do
  body="$(extract_fn "$DISPATCHER" "$fn")"
  [ -n "$body" ] || { echo "FATAL: could not extract $fn from $DISPATCHER" >&2; exit 2; }
  eval "$body"
done

T="$(mktemp -d 2>/dev/null || mktemp -d -t gabwtrrf)"
trap 'find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null || true' EXIT
FAKE_LABELS="$T/labels"; FAKE_ASSIGNEE="$T/assignee"; FAKE_COMMENTS="$T/comments"; FAKE_CALLS="$T/calls"
FAKE_SHOW_FAIL=0; FAKE_NH_STATUS=armed; FAKE_LIVE=""

# ── stubs (file-backed: the branch calls some of these inside $(...) subshells) ──────────────
log() { :; }; warn() { :; }; notify() { echo "notify" >>"$FAKE_CALLS"; }
gate_needs_human_clause() { printf 'clause(%s)' "${1:-}"; }
notify_author_with_fallback() { echo "author-mail" >>"$FAKE_CALLS"; }
gc() { case "$*" in *"mail send"*) echo "mayor-mail" >>"$FAKE_CALLS" ;; esac; return 0; }
author_is_alive() { case " $FAKE_LIVE " in *" $1 "*) printf 1 ;; *) printf 0 ;; esac; }
gate_apply_needs_human() {   # <city> <id> <label> — records the label like the real one, echoes its status word
  printf '%s\n%s\n' "gate:needs-human" "$3" >>"$FAKE_LABELS"; printf '%s' "$FAKE_NH_STATUS"
}
bd() {                       # bd -C <city> <verb> ...
  case "$3" in
    label)
      case "$4" in
        add)    printf '%s\n' "$6" >>"$FAKE_LABELS" ;;
        remove) grep -vxF -- "$6" "$FAKE_LABELS" >"$FAKE_LABELS.n" 2>/dev/null; mv "$FAKE_LABELS.n" "$FAKE_LABELS" ;;
      esac ;;
    assign)  printf '%s' "$5" >"$FAKE_ASSIGNEE" ;;
    comment) printf '%s\n--8<--\n' "$5" >>"$FAKE_COMMENTS" ;;
    show)
      [ "$FAKE_SHOW_FAIL" = "1" ] && return 1
      # rc 0 but an error ENVELOPE instead of a bead (what a degraded bd/Dolt can hand back)
      [ "$FAKE_SHOW_FAIL" = "envelope" ] && { printf '{"error":"no issue found"}\n'; return 0; }
      [ "$FAKE_SHOW_FAIL" = "notjson" ] && { printf 'Error: dolt unavailable\n'; return 0; }
      printf '[{"id":"%s","assignee":"%s","labels":%s}]\n' "$4" "$(cat "$FAKE_ASSIGNEE")" \
        "$(sort -u "$FAKE_LABELS" | jq -R . | jq -s .)" ;;
  esac
  return 0
}

GC_CITY="$T/city"; mkdir -p "$GC_CITY"
BEAD_CITY="$T/rig"; BEAD_ID="wa-cap1"; BRANCH="feat/cap1"; RIG="wa"; GATE_RUN_ID="run-1"
FAIL_REASONS="blocking: x"; PREV_ATTEMPT=3; GATE_FIX_CAP=3; NOTIFY_AUTHOR=""

# run_cap <author> <author_agent> <live-sessions...> — fresh bead mid-flight, then the REAL cap branch
run_cap() {
  AUTHOR="$1"; AUTHOR_AGENT="$2"; shift 2; FAKE_LIVE="$*"; SRC_LABELS=$'story:in-flight\ngate:reviewing'
  printf '%s\n' story:in-flight gate:reviewing pilot:dispatched gate:needs-fix >"$FAKE_LABELS"
  printf '%s' "$AUTHOR" >"$FAKE_ASSIGNEE"; : >"$FAKE_COMMENTS"; : >"$FAKE_CALLS"
  eval "$CAP_BODY"
}
assignee() { cat "$FAKE_ASSIGNEE"; }
calls()    { grep -c "^$1\$" "$FAKE_CALLS" 2>/dev/null || true; }

invariants() {   # a :technical park never reaches Athos and always sheds the in-flight claim
  no_label "$1: no story:needs-human on a :technical park" story:needs-human
  no_label "$1: no next-action:athos on a :technical park" next-action:athos
  want_label "$1: gate:needs-human:technical armed" gate:needs-human:technical
  no_label "$1: story:in-flight shed" story:in-flight
  no_label "$1: gate:needs-fix shed" gate:needs-fix
}

echo "-- S1: author is a LIVE named crew (digo-wa) --"
run_cap digo-wa "" digo-wa
eq "S1 assignee kept for the live crew" "$(assignee)" "digo-wa"
invariants S1
eq "S1 Mayor still mailed exactly once at the cap" "$(calls mayor-mail)" "1"

echo "-- S2: author's session is dead, no live agent --"
run_cap batista-wa-gadead "" digo-wa
eq "S2 assignee cleared (nobody to hold it)" "$(assignee)" ""
want_label "S2 next-action:mayor says whose turn it is" next-action:mayor
invariants S2
q="$(cat "$FAKE_COMMENTS")"
case "$q" in *"Pergunta:"*) ok "S2 a Pergunta: comment asks for what is needed" ;; *) bad "S2 no Pergunta: comment — coordinator-alert would show 'nenhum comentário Pergunta:'" ;; esac
eq "S2 the Pergunta: comment is not Athos's (no athos.acao ask)" "$(printf '%s' "$q" | grep -c 'athos.acao')" "0"

echo "-- S3: author is an ephemeral pool builder, even though its session is up --"
run_cap dog-abc123 "" dog-abc123
eq "S3 assignee cleared — ephemeral slots are never kept (ga-nkkku)" "$(assignee)" ""
want_label "S3 next-action:mayor" next-action:mayor
invariants S3

echo "-- S4: recycled session — branch author's session died, durable agent digo-wa is live --"
run_cap digo-wa-gadead digo-wa digo-wa
eq "S4 assignee goes to the live durable agent, not cleared" "$(assignee)" "digo-wa"
invariants S4

echo "-- S5: circuit-breaker failed to arm, author dead --"
FAKE_NH_STATUS=failed run_cap batista-wa-gadead "" digo-wa
want_label "S5 still parks on the Mayor even though gate:needs-human is unverified" next-action:mayor
eq "S5 assignee cleared" "$(assignee)" ""

echo "-- S6: post-write read fails — an error is not an empty (ga-p5q3 / ga-n7hu2 class) --"
FAKE_SHOW_FAIL=1 run_cap batista-wa-gadead "" digo-wa
q="$(cat "$FAKE_COMMENTS")"
case "$q" in *UNVERIFIED*) ok "S6 comment reports UNVERIFIED when the re-read failed" ;; *) bad "S6 comment must say UNVERIFIED on a failed re-read, got: $q" ;; esac
case "$q" in *"next-action:mayor=MISSING"*) bad "S6 a READ failure was published as a WRITE failure (MISSING)" ;; *) ok "S6 read failure not reported as MISSING" ;; esac
FAKE_SHOW_FAIL=0
for mode in envelope notjson; do
  for who in "batista-wa-gadead||" "digo-wa||digo-wa"; do   # dead author (clear arm) and live crew (keep arm)
    a="${who%%|*}"; rest="${who#*|}"; live="${rest#*|}"
    FAKE_SHOW_FAIL=$mode run_cap "$a" "" $live
    q="$(cat "$FAKE_COMMENTS")"
    case "$q" in *UNVERIFIED*) ok "S6 [$mode/$a] 200-with-garbage read reported UNVERIFIED" ;; *) bad "S6 [$mode/$a] garbage read must be UNVERIFIED, got: $q" ;; esac
    case "$q" in *"did not stick"*|*"=MISSING"*) bad "S6 [$mode/$a] a READ failure was published as a WRITE failure" ;; *) ok "S6 [$mode/$a] not blamed on the write" ;; esac
  done
done
FAKE_SHOW_FAIL=0

echo "-- S7: gate:needs-human already on the bead — no second mayor/author page (existing once-only contract) --"
AUTHOR=batista-wa-gadead; AUTHOR_AGENT=""; FAKE_LIVE=""; SRC_LABELS=$'gate:needs-human\ngate:needs-human:technical'
printf '%s\n' gate:needs-human gate:needs-human:technical >"$FAKE_LABELS"; printf '%s' "$AUTHOR" >"$FAKE_ASSIGNEE"; : >"$FAKE_COMMENTS"; : >"$FAKE_CALLS"
eval "$CAP_BODY"
eq "S7 no second Mayor mail" "$(calls mayor-mail)" "0"
want_label "S7 still parked on the Mayor" next-action:mayor

echo
echo "gate-cap-park-ownership: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
