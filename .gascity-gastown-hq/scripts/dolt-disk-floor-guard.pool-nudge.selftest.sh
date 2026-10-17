#!/usr/bin/env bash
# dolt-disk-floor-guard.pool-nudge.selftest.sh (ga-vln2py, ga-xdj2si) — _nudge_pool_heavy_stop: at CRITICAL the guard
# tells the ACTIVE pool sessions to stop heavy steps. The main()-level WIRING (called on CRITICAL only, before the photo
# and the levers, a failure never aborts the cycle, the CRITICAL notify/mail leave on time even with a slow `gc`) is
# proven in dolt-disk-floor-guard.selftest.sh; this file is the function and its join.
#
# Hermetic: the guard is SOURCED as a library, `gc` is a fake script that records its argv and answers from a fixture
# (it can be made slow, hanging on one target, or stdin-hungry), the state dir and log are scratch. No real session is
# listed or nudged. The suite runs against the real guard and then against MUTANTS of it (each one reintroduces a bug
# this lever had or could have: a session that is not active gets nudged; a list that could not be read is taken for
# "no pool sessions"; a nudge that did not land is stamped as told; a timeout is counted as a failure; the phase blocks
# its caller; there is no total budget; `gc` can read the target list; the join does not wait) - each must make the
# suite fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$HERE/dolt-disk-floor-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/dolt-floor-nudge-st.XXXXXX")"
trap '[ -n "${W:-}" ] && [ -d "$W" ] && rm -rf -- "$W"' EXIT
PASS=0; FAIL=0
# every `p` the suite prints on the real guard; the completeness guard below is an equality, so a check that silently
# stops running (or a new one nobody counted) fails the suite instead of passing unnoticed.
EXPECTED_CHECKS=24

cat > "$W/gc" <<'SH'
#!/bin/sh
# fake gc: `session list --json` answers from $FW/list.json (or fails); `session nudge <t> <msg>` records and succeeds
# unless <t> is in $FW/nudge-fail (one alias per line) or $FW/nudge-fail-all exists. Knobs: $FW/nudge-sleep (seconds
# every nudge takes), $FW/nudge-hang (aliases whose nudge hangs 6 s, long enough to hit a short timeout), $FW/gc-reads-stdin
# (the nudge drains stdin, as a gc that read its input would).
echo "$1 $2 $3" >> "$FW/gc.calls"
case "$1 $2" in
  "session list") [ -e "$FW/list-fail" ] && exit 1; cat "$FW/list.json"; exit 0 ;;
  "session nudge")
    printf '%s\n' "$4" > "$FW/last-msg"
    [ -e "$FW/gc-reads-stdin" ] && cat >/dev/null
    [ -f "$FW/nudge-hang" ] && grep -qx "$3" "$FW/nudge-hang" && exec sleep 6
    [ -f "$FW/nudge-sleep" ] && sleep "$(cat "$FW/nudge-sleep")"
    [ -e "$FW/nudge-fail-all" ] && exit 1
    [ -f "$FW/nudge-fail" ] && grep -qx "$3" "$FW/nudge-fail" && exit 1
    exit 0 ;;
esac
exit 2
SH
chmod +x "$W/gc"
cat > "$W/list-full.json" <<'EOF'
{"ok":true,"sessions":[
 {"alias":"gastown.dog-1","id":"ga-a1","template":"gastown.dog","state":"active"},
 {"alias":"gastown.dog-2","id":"ga-a2","template":"gastown.dog","state":"active"},
 {"alias":"gastown.dog-3","id":"ga-a3","template":"gastown.dog","state":"asleep"},
 {"alias":"wa-worker-x","id":"ga-b1","template":"wa-worker","state":"active"},
 {"alias":"ps-worker-w","id":"ga-b3","template":"ps-worker","state":"active"},
 {"alias":"ps-worker-y","id":"ga-b2","template":"ps-worker","state":"asleep"},
 {"alias":"gate-reviewer-z","id":"ga-c1","template":"gate-reviewer","state":"active"},
 {"alias":"thies-wa","id":"ga-d1","template":"thies-wa","state":"active"},
 {"alias":"gastown.mayor","id":"ga-e1","template":"gastown.mayor","state":"active"},
 {"id":"ga-f1","template":"wa-worker","state":"active"}
]}
EOF
printf '{"ok":true,"sessions":[{"alias":"gastown.mayor","id":"ga-e1","template":"gastown.mayor","state":"active"},{"alias":"gastown.dog-3","id":"ga-a3","template":"gastown.dog","state":"asleep"}]}' > "$W/list-none.json"

# suite <guard-file> — prints one "FAIL: ..." line per broken expectation, "PASS" lines otherwise
suite() {
  local guard="$1" S FWD
  S="$(mktemp -d "$W/state.XXXXXX")"; FWD="$(mktemp -d "$W/fw.XXXXXX")"
  (
    export FW="$FWD" DOLT_DISK_FLOOR_GUARD_LIB=1 DOLT_DISK_FLOOR_GUARD_LOG="$FWD/log" DOLT_DISK_FLOOR_STATE_DIR="$S" GC_BIN="$W/gc"
    export DOLT_DISK_FLOOR_POOL_NUDGE_COOLDOWN_SECS=900
    # shellcheck disable=SC1090
    . "$guard"
    NOW=1800000000
    ALL6="ga-f1 gastown.dog-1 gastown.dog-2 gate-reviewer-z ps-worker-w wa-worker-x "
    p() { echo "PASS: $1"; }
    f() { echo "FAIL: $1"; }
    reset() {
      : > "$FW/gc.calls"; : > "$FW/log"
      rm -f "$FW/list-fail" "$FW/nudge-fail" "$FW/nudge-fail-all" "$FW/nudge-sleep" "$FW/nudge-hang" "$FW/gc-reads-stdin" "$FW/last-msg"
      rm -f "$STATE_POOL_NUDGE_DIR"/* 2>/dev/null
      cp "$W/list-full.json" "$FW/list.json"
      POOL_NUDGE_ENABLED=1; POOL_NUDGE_BUDGET_SECS=60; POOL_NUDGE_TIMEOUT_SECS=15; POOL_NUDGE_JOIN_SLACK_SECS=10
      POOL_NUDGE_TEMPLATES="gastown.dog wa-worker ps-worker gate-reviewer"
    }
    nudged() { grep '^session nudge ' "$FW/gc.calls" | awk '{print $3}' | sort | tr '\n' ' '; }
    log_has() { grep -q -- "$1" "$FW/log"; }
    stamp_of() { cat "$(_pool_nudge_stamp_file "$1")" 2>/dev/null; }
    stamps() { ls "$STATE_POOL_NUDGE_DIR" 2>/dev/null | wc -l | tr -d ' '; }
    # the guard under test runs the nudges in the background; the join is what a finished cycle does at its end
    run() { _nudge_pool_heavy_stop "$@"; _pool_nudge_join; }

    reset; run 2 "$NOW"; got="$(nudged)"
    [ "$got" = "$ALL6" ] && p "tells exactly the ACTIVE sessions of dog/wa-worker/ps-worker/gate-reviewer (alias, else id) - an ACTIVE ps-worker included, not asleep ones, crews or the mayor" || f "wrong set nudged: '$got' (wanted '$ALL6')"
    msg="$(cat "$FW/last-msg" 2>/dev/null)"
    case "$msg" in *"DISK CRITICAL"*"2 GB free"*"stop any HEAVY step"*"automatic notice"*) p "the message names the disk, the reading, what to stop and that it is automatic" ;; *) f "message lacks the essentials: $msg" ;; esac
    ok_stamps=0; for t in $ALL6; do [ "$(stamp_of "$t")" = "$NOW" ] && ok_stamps=$((ok_stamps + 1)); done
    [ "$ok_stamps" = "6" ] && [ "$(stamps)" = "6" ] && p "every target that was told holds its OWN cooldown stamp with the cycle epoch" || f "per-target stamps wrong: $ok_stamps of 6 hold $NOW, $(stamps) files"

    : > "$FW/gc.calls"; run 2 $((NOW + 300))
    [ -z "$(nudged)" ] && log_has "inside the 900s cooldown" && p "inside the cooldown (300 s later): nobody is nudged again, and the log says why" || f "nudged again inside the cooldown: '$(nudged)'"
    run 2 $((NOW + 900))
    [ "$(nudged)" = "$ALL6" ] && p "cooldown elapsed (900 s): the notice goes out again, to everybody" || f "no full nudge after the cooldown elapsed: '$(nudged)'"

    reset; mkdir -p "$STATE_POOL_NUDGE_DIR"; printf 'not-a-number' > "$(_pool_nudge_stamp_file gastown.dog-1)"; run 2 "$NOW"
    case "$(nudged)" in *gastown.dog-1*) p "a garbage stamp never mutes a target (fail open on the cooldown)" ;; *) f "garbage stamp muted the notice" ;; esac

    reset; touch "$FW/list-fail"; run 2 "$NOW"
    if [ -z "$(nudged)" ] && [ "$(stamps)" = "0" ] && log_has "could not read the session list"; then p "gc session list failing: nobody nudged, NO stamp (retry next cycle), and the log says it could not read - not 'no sessions'"; else f "list failure mishandled (nudged='$(nudged)' stamps=$(stamps) log=$(tr '\n' '|' < "$FW/log"))"; fi
    reset; echo 'garbage, not json' > "$FW/list.json"; run 2 "$NOW"
    [ -z "$(nudged)" ] && [ "$(stamps)" = "0" ] && log_has "could not read the session list" && p "an answer that is not JSON is 'could not read', not 'none'" || f "non-JSON list mishandled"
    reset; echo '{"ok":false,"sessions":[]}' > "$FW/list.json"; run 2 "$NOW"
    [ -z "$(nudged)" ] && [ "$(stamps)" = "0" ] && log_has "could not read the session list" && p "ok:false is 'could not read', not 'none'" || f "ok:false list mishandled"

    # jq passing the validation call and then dying on the extraction (a shadowing function makes it so): a failure, not "none"
    reset; jq() { if [ "${1:-}" = "-r" ]; then return 5; fi; command jq "$@"; }
    run 2 "$NOW"; unset -f jq
    [ -z "$(nudged)" ] && [ "$(stamps)" = "0" ] && log_has "could not pick the active pool sessions" && ! log_has "no active session of" \
      && p "jq failing on the extraction is 'could not pick', never the same as 'no active pool session'" || f "jq failure on the extraction was read as an empty list"

    reset; cp "$W/list-none.json" "$FW/list.json"; run 2 "$NOW"
    [ -z "$(nudged)" ] && [ "$(stamps)" = "0" ] && log_has "no active session of" && p "a readable list with no active pool session: 'none' on the log, no stamp" || f "empty case mishandled"

    # item 2 of ga-xdj2si: the stamp is per TARGET, so a target whose nudge failed is retried next cycle while the rest keep their cooldown
    reset; printf 'gastown.dog-2\n' > "$FW/nudge-fail"; run 2 "$NOW"
    got="$(nudged)"
    case "$got" in *"gastown.dog-1"*"wa-worker-x"*) ;; *) f "one failing nudge stopped the others: '$got'" ;; esac
    log_has "could not nudge gastown.dog-2" && [ "$(stamp_of wa-worker-x)" = "$NOW" ] && [ -z "$(stamp_of gastown.dog-2)" ] && p "one nudge failing is logged, the others still go out and are stamped, the failed one is NOT stamped" || f "partial failure mishandled"
    rm -f "$FW/nudge-fail"; : > "$FW/gc.calls"; run 2 $((NOW + 300))
    [ "$(nudged)" = "gastown.dog-2 " ] && p "next cycle (300 s later, inside the cooldown): ONLY the target that failed is retried" || f "retry set wrong: '$(nudged)' (wanted 'gastown.dog-2 ')"
    reset; touch "$FW/nudge-fail-all"; run 2 "$NOW"
    [ "$(stamps)" = "0" ] && p "every nudge failing: NO stamp at all, so the next cycle tries everybody again" || f "stamps written although no nudge landed ($(stamps))"

    reset; DOLT_DISK_FLOOR_POOL_NUDGE=0; POOL_NUDGE_ENABLED=0; run 2 "$NOW"
    [ -z "$(nudged)" ] && [ ! -s "$FW/gc.calls" ] && log_has "pool-nudge SKIP" && p "the kill switch: no gc call at all, and it says SKIP on the log like the other levers" || f "kill switch mishandled (calls=$(wc -l < "$FW/gc.calls") log=$(tr '\n' '|' < "$FW/log"))"
    reset; POOL_NUDGE_TEMPLATES="thies-wa"; run 2 "$NOW"
    [ "$(nudged)" = "thies-wa " ] && p "the template list is data (DOLT_DISK_FLOOR_POOL_NUDGE_TEMPLATES): only what it names is nudged" || f "template filter ignored: '$(nudged)'"

    # item 3: a nudge that TIMED OUT may still have been delivered (the text was queued) - it is "delivery unknown", counted apart from failures, and not stamped
    reset; printf 'gastown.dog-2\n' > "$FW/nudge-hang"; POOL_NUDGE_TIMEOUT_SECS=1; run 2 "$NOW"
    if log_has "delivery unknown 1" && log_has "failed 0" && ! log_has "could not nudge gastown.dog-2" && [ -z "$(stamp_of gastown.dog-2)" ] && [ "$(stamp_of wa-worker-x)" = "$NOW" ]; then
      p "a nudge that timed out is 'delivery unknown', not one of the 'failed'; it is not stamped, so it is retried"
    else f "timeout mishandled: log=$(tr '\n' '|' < "$FW/log")"; fi

    # item 4: a gc that reads its stdin must not swallow the rest of the target list
    reset; touch "$FW/gc-reads-stdin"; run 2 "$NOW"
    [ "$(nudged)" = "$ALL6" ] && p "a gc that reads stdin does not eat the remaining targets (gc runs with </dev/null)" || f "stdin-hungry gc swallowed targets: '$(nudged)' (wanted '$ALL6')"

    # item 1 - the lever must not hold its caller: 6 targets x 1 s of nudging, the caller must get control back at once
    reset; echo 1 > "$FW/nudge-sleep"; POOL_NUDGE_BUDGET_SECS=3
    t0=$(date +%s); _nudge_pool_heavy_stop 2 "$NOW"; t1=$(date +%s)
    [ $((t1 - t0)) -le 1 ] && p "the nudge phase does not block its caller: control is back within 1 s although nudging all 6 targets would take 6 s" || f "the caller was held $((t1 - t0)) s by the nudge phase (6 targets x 1 s)"
    # ... and the phase has a TOTAL budget: past it the rest are logged as not reached, unstamped, and the join returns on time
    _pool_nudge_join; t2=$(date +%s)
    calls="$(grep -c '^session nudge ' "$FW/gc.calls")"
    if [ $((t2 - t0)) -le 6 ] && [ "$calls" -ge 1 ] && [ "$calls" -le 5 ] && log_has "not reached (budget) [1-9]" && [ "$(stamps)" -le "$calls" ]; then
      p "the total budget (3 s) cuts the phase: $calls of 6 nudges started, the rest logged 'not reached' and left unstamped; the join was back after $((t2 - t0)) s"
    else f "budget not honoured (join back after $((t2 - t0)) s, $calls nudges started, stamps=$(stamps), log=$(tr '\n' '|' < "$FW/log"))"; fi
    log_has "pool nudge: told" && p "after the join the phase has finished and said so (no summary line is left pending behind the cycle)" || f "no summary line after the join"

    # the join cannot wait forever on a phase that hung: it kills it past budget + slack and says so (the phase is faked as a sleeper)
    reset; POOL_NUDGE_BUDGET_SECS=1; POOL_NUDGE_JOIN_SLACK_SECS=1
    _pool_nudge_phase() { exec sleep 30; }
    t0=$(date +%s); run 2 "$NOW"; t1=$(date +%s)
    [ $((t1 - t0)) -le 5 ] && log_has "still running" && p "a hung phase is killed by the join past budget + slack (back after $((t1 - t0)) s), logged, the cycle goes on" || f "join waited $((t1 - t0)) s on a hung phase / did not log it"
    unset -f _pool_nudge_phase
    # shellcheck disable=SC1090
    . "$guard"
    reset
    _pool_nudge_join; [ "$?" = "0" ] && p "a join with nothing started is a no-op that succeeds" || f "empty join failed"
    # `kill -0 0` signals the whole process group and always succeeds: a pid that is not a plain pid >= 2 must make the join
    # do NOTHING - never wait on it, never kill. `kill` is shadowed (it answers "alive" three times, then "gone", so a join
    # that did try to wait cannot hang the suite) and every call it gets is recorded.
    : > "$FW/kill.calls"; kill() { echo "$*" >> "$FW/kill.calls"; kc=$((${kc:-0} + 1)); [ "$kc" -le 3 ]; }
    for bad in 0 1 abc; do kc=0; _POOL_NUDGE_PID="$bad"; _POOL_NUDGE_DEADLINE=1; _pool_nudge_join; done
    unset -f kill
    [ ! -s "$FW/kill.calls" ] && p "a join handed a pid that is not a plain pid >= 2 (0, 1, text) neither waits nor kills - never a signal to the whole process group" || f "join signalled on a bogus pid: $(tr '\n' '|' < "$FW/kill.calls")"
  ) 2>&1
}

fails_of() { printf '%s\n' "$1" | grep -c '^FAIL:'; }
out="$(suite "$REAL")"
printf '%s\n' "$out" | grep -v '^PASS:' | sed 's/^/  /'
real_fail="$(fails_of "$out")"; real_pass="$(printf '%s\n' "$out" | grep -c '^PASS:')"
PASS=$real_pass; FAIL=$real_fail
[ "$real_pass" -eq "$EXPECTED_CHECKS" ] || { echo "FAIL: $real_pass checks passed, expected exactly $EXPECTED_CHECKS - the suite did not run to the end, or a check was added/removed without updating EXPECTED_CHECKS"; FAIL=$((FAIL+1)); }

# The mutants are independent, so they run side by side (each suite sleeps most of the time on its fake gc): every job
# writes one result line, the parent prints them in order and counts.
MUT_N=0; MUT_RES=""
mutant_check() { # <name> <mutated-guard-file> <result-file>   (run in the background)
  local name="$1" m="$2" res="$3" o n
  if cmp -s "$REAL" "$m"; then echo "FAIL:  mutant '$name' did not change the guard" > "$res"; return; fi
  o="$(suite "$m")"; n="$(fails_of "$o")"
  if [ "$n" -gt 0 ]; then echo "OK:  mutant '$name' is caught ($n expectation(s) fail)" > "$res"
  else echo "FAIL:  mutant '$name' SURVIVED the suite" > "$res"; fi
}
mutant() { # <name> <sed-expr>
  local name="$1" expr="$2"; MUT_N=$((MUT_N + 1))
  sed "$expr" "$REAL" > "$W/mut.$MUT_N.sh"; mutant_check "$name" "$W/mut.$MUT_N.sh" "$W/mut.$MUT_N.res" & MUT_RES="$MUT_RES $W/mut.$MUT_N.res"
}
mutant_perl() { # <name> <perl -0pe expression>
  local name="$1" expr="$2"; MUT_N=$((MUT_N + 1))
  perl -0pe "$expr" "$REAL" > "$W/mut.$MUT_N.sh"; mutant_check "$name" "$W/mut.$MUT_N.sh" "$W/mut.$MUT_N.res" & MUT_RES="$MUT_RES $W/mut.$MUT_N.res"
}
mutant "a session that is not active is nudged too" 's/| select(.state == "active")//'
mutant "an unreadable list is taken for no pool sessions" 's/  if ! printf .%s. "\$list" | jq -e .(.ok != false) and ((.sessions \/\/ \[\]) | type == "array"). >\/dev\/null 2>&1; then/  if false; then/'
mutant_perl "a jq failure on the extraction is taken for no pool sessions" 's/\|\| \{\n    log "WARN pool nudge: could not pick[^\n]*\n    return 0\n  \}/|| targets=""/'
mutant "a nudge that did not land is stamped as told" 's/    if \[ "\$rc" = "0" \]; then/    if true; then/'
mutant "a timed-out nudge is counted among the failures" 's/    elif \[ "\$rc" = "124" \] || \[ "\$rc" = "137" \]; then/    elif false; then/'
mutant "the nudge phase runs in the foreground and holds its caller" 's/^\(  _pool_nudge_phase "\$avail" "\$now" "\$deadline" >\/dev\/null 2>&1 <\/dev\/null\) &$/\1/'
mutant "the phase has no total budget" 's/    if \[ "\$remaining" -lt 1 \]; then/    if false; then/'
mutant "gc inherits the loop stdin and can eat the target list" '/session nudge "\$target"/s/ <\/dev\/null//'
mutant "the join does not wait for the phase" 's/^  while kill -0 "\$pid" 2>\/dev\/null; do/  while false; do/'
mutant "the join accepts any pid (0 signals the whole process group)" "s/  case \"\\\$pid\" in ''|\\*\\[!0-9\\]\\*|0|1) return 0 ;; esac/  :/"
mutant "the kill switch is silent" 's/    log "pool-nudge SKIP/    : "pool-nudge SKIP/'
wait
for r in $MUT_RES; do
  line="$(cat "$r" 2>/dev/null)"; [ -n "$line" ] || line="FAIL:  mutant result missing ($r)"
  case "$line" in OK:*) PASS=$((PASS+1)); echo "${line#OK:}" ;; *) FAIL=$((FAIL+1)); echo "${line#FAIL:}" ;; esac
done

echo "dolt-disk-floor-guard pool-nudge selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
