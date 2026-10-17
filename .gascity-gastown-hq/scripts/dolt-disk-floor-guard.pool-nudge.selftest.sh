#!/usr/bin/env bash
# dolt-disk-floor-guard.pool-nudge.selftest.sh (ga-vln2py) — _nudge_pool_heavy_stop: at CRITICAL the guard tells the
# ACTIVE pool sessions to stop heavy steps. The main()-level WIRING (called on CRITICAL only, before the photo and the
# levers, a failure never aborts the cycle) is proven in dolt-disk-floor-guard.selftest.sh; this file is the function.
#
# Hermetic: the guard is SOURCED as a library, `gc` is a fake script that records its argv and answers from a fixture,
# the state dir and log are scratch. No real session is listed or nudged. The suite runs against the real guard and
# then against three MUTANTS of it (a session that is not active gets nudged; a list that could not be read is taken
# for "no pool sessions"; the cooldown stamp is written although nobody was told) - each must make the suite fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$HERE/dolt-disk-floor-guard.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
W="$(mktemp -d "${TMPDIR:-/tmp}/dolt-floor-nudge-st.XXXXXX")"
trap '[ -n "${W:-}" ] && [ -d "$W" ] && rm -rf -- "$W"' EXIT
PASS=0; FAIL=0

cat > "$W/gc" <<'SH'
#!/bin/sh
# fake gc: `session list --json` answers from $W/list.json (or fails); `session nudge <t> <msg>` records and succeeds
# unless <t> is in $W/nudge-fail (one alias per line) or $W/nudge-fail-all exists.
echo "$1 $2 $3" >> "$FW/gc.calls"
case "$1 $2" in
  "session list") [ -e "$FW/list-fail" ] && exit 1; cat "$FW/list.json"; exit 0 ;;
  "session nudge")
    printf '%s\n' "$4" > "$FW/last-msg"
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
  local guard="$1" S="$W/state.$RANDOM" FWD="$W/fw.$RANDOM"
  mkdir -p "$S" "$FWD"
  (
    export FW="$FWD" DOLT_DISK_FLOOR_GUARD_LIB=1 DOLT_DISK_FLOOR_GUARD_LOG="$FWD/log" DOLT_DISK_FLOOR_STATE_DIR="$S" GC_BIN="$W/gc"
    export DOLT_DISK_FLOOR_POOL_NUDGE_COOLDOWN_SECS=900
    # shellcheck disable=SC1090
    . "$guard"
    STAMP="$STATE_POOL_NUDGE_FILE"
    NOW=1800000000
    p() { echo "PASS: $1"; }
    f() { echo "FAIL: $1"; }
    reset() { : > "$FW/gc.calls"; : > "$FW/log"; rm -f "$FW/list-fail" "$FW/nudge-fail" "$FW/nudge-fail-all" "$STAMP" "$FW/last-msg"; cp "$W/list-full.json" "$FW/list.json"; }
    nudged() { grep '^session nudge ' "$FW/gc.calls" | awk '{print $3}' | sort | tr '\n' ' '; }
    log_has() { grep -q -- "$1" "$FW/log"; }

    reset; _nudge_pool_heavy_stop 2 "$NOW"; got="$(nudged)"
    want="ga-f1 gastown.dog-1 gastown.dog-2 gate-reviewer-z wa-worker-x "
    [ "$got" = "$want" ] && p "tells exactly the ACTIVE sessions of dog/wa-worker/ps-worker/gate-reviewer (alias, else id) - not asleep ones, crews or the mayor" || f "wrong set nudged: '$got' (wanted '$want')"
    msg="$(cat "$FW/last-msg" 2>/dev/null)"
    case "$msg" in *"DISK CRITICAL"*"2 GB free"*"heavy-guard.sh --check"*"automatic notice"*) p "the message names the disk, the reading, the command to check and that it is automatic" ;; *) f "message lacks the essentials: $msg" ;; esac
    [ "$(cat "$STAMP" 2>/dev/null)" = "$NOW" ] && p "the cooldown stamp holds the cycle epoch after a nudge landed" || f "stamp is '$(cat "$STAMP" 2>/dev/null)', wanted $NOW"

    : > "$FW/gc.calls"; _nudge_pool_heavy_stop 2 $((NOW + 300))
    [ -z "$(nudged)" ] && log_has "inside the 900s cooldown" && p "inside the cooldown (300 s later): nobody is nudged again, and the log says why" || f "nudged again inside the cooldown: '$(nudged)'"
    _nudge_pool_heavy_stop 2 $((NOW + 900))
    [ -n "$(nudged)" ] && p "cooldown elapsed (900 s): the notice goes out again" || f "no nudge after the cooldown elapsed"

    reset; printf 'not-a-number' > "$STAMP"; _nudge_pool_heavy_stop 2 "$NOW"
    [ -n "$(nudged)" ] && p "a garbage stamp never mutes the notice (fail open on the cooldown)" || f "garbage stamp muted the notice"

    reset; touch "$FW/list-fail"; _nudge_pool_heavy_stop 2 "$NOW"
    if [ -z "$(nudged)" ] && [ ! -e "$STAMP" ] && log_has "could not read the session list"; then p "gc session list failing: nobody nudged, NO stamp (retry next cycle), and the log says it could not read - not 'no sessions'"; else f "list failure mishandled (nudged='$(nudged)' stamp=$([ -e "$STAMP" ] && echo yes || echo no) log=$(tr '\n' '|' < "$FW/log"))"; fi
    reset; echo 'garbage, not json' > "$FW/list.json"; _nudge_pool_heavy_stop 2 "$NOW"
    [ -z "$(nudged)" ] && [ ! -e "$STAMP" ] && log_has "could not read the session list" && p "an answer that is not JSON is 'could not read', not 'none'" || f "non-JSON list mishandled"
    reset; echo '{"ok":false,"sessions":[]}' > "$FW/list.json"; _nudge_pool_heavy_stop 2 "$NOW"
    [ -z "$(nudged)" ] && [ ! -e "$STAMP" ] && log_has "could not read the session list" && p "ok:false is 'could not read', not 'none'" || f "ok:false list mishandled"

    # jq passing the validation call and then dying on the extraction (a shadowing function makes it so): a failure, not "none"
    reset; jq() { if [ "${1:-}" = "-r" ]; then return 5; fi; command jq "$@"; }
    _nudge_pool_heavy_stop 2 "$NOW"; unset -f jq
    [ -z "$(nudged)" ] && [ ! -e "$STAMP" ] && log_has "could not pick the active pool sessions" && ! log_has "no active session of" \
      && p "jq failing on the extraction is 'could not pick', never the same as 'no active pool session'" || f "jq failure on the extraction was read as an empty list"

    reset; cp "$W/list-none.json" "$FW/list.json"; _nudge_pool_heavy_stop 2 "$NOW"
    [ -z "$(nudged)" ] && [ ! -e "$STAMP" ] && log_has "no active session of" && p "a readable list with no active pool session: 'none' on the log, no stamp" || f "empty case mishandled"

    reset; printf 'gastown.dog-2\n' > "$FW/nudge-fail"; _nudge_pool_heavy_stop 2 "$NOW"
    got="$(nudged)"
    case "$got" in *"gastown.dog-1"*"wa-worker-x"*) ;; *) f "one failing nudge stopped the others: '$got'" ;; esac
    log_has "could not nudge gastown.dog-2" && [ "$(cat "$STAMP" 2>/dev/null)" = "$NOW" ] && p "one nudge failing is logged, the others still go out, the stamp is written (at least one landed)" || f "partial failure mishandled"
    reset; touch "$FW/nudge-fail-all"; _nudge_pool_heavy_stop 2 "$NOW"
    [ ! -e "$STAMP" ] && p "every nudge failing: NO stamp, so the next cycle tries again" || f "stamp written although no nudge landed"

    reset; DOLT_DISK_FLOOR_POOL_NUDGE=0; POOL_NUDGE_ENABLED=0; _nudge_pool_heavy_stop 2 "$NOW"; POOL_NUDGE_ENABLED=1
    [ -z "$(nudged)" ] && [ ! -s "$FW/gc.calls" ] && p "the kill switch: no gc call at all" || f "kill switch still called gc"
    reset; POOL_NUDGE_TEMPLATES="thies-wa"; _nudge_pool_heavy_stop 2 "$NOW"
    [ "$(nudged)" = "thies-wa " ] && p "the template list is data (DOLT_DISK_FLOOR_POOL_NUDGE_TEMPLATES): only what it names is nudged" || f "template filter ignored: '$(nudged)'"
  ) 2>&1
}

fails_of() { printf '%s\n' "$1" | grep -c '^FAIL:'; }
out="$(suite "$REAL")"
printf '%s\n' "$out" | grep -v '^PASS:' | sed 's/^/  /'
real_fail="$(fails_of "$out")"; real_pass="$(printf '%s\n' "$out" | grep -c '^PASS:')"
PASS=$real_pass; FAIL=$real_fail
[ "$real_pass" -ge 12 ] || { echo "FAIL: only $real_pass checks passed - the suite did not run to the end"; FAIL=$((FAIL+1)); }

mutant() { # <name> <sed-expr>
  local name="$1" expr="$2" m="$W/mut.$RANDOM.sh" o
  sed "$expr" "$REAL" > "$m"
  if cmp -s "$REAL" "$m"; then echo "  FAIL: mutant '$name' did not change the guard"; FAIL=$((FAIL+1)); return; fi
  o="$(suite "$m")"
  if [ "$(fails_of "$o")" -gt 0 ]; then PASS=$((PASS+1)); echo "  mutant '$name' is caught ($(fails_of "$o") expectation(s) fail)"
  else echo "  FAIL: mutant '$name' SURVIVED the suite"; FAIL=$((FAIL+1)); fi
}
mutant "a session that is not active is nudged too" 's/| select(.state == "active")//'
mutant "an unreadable list is taken for no pool sessions" 's/  if ! printf .%s. "\$list" | jq -e .(.ok != false) and ((.sessions \/\/ \[\]) | type == "array"). >\/dev\/null 2>&1; then/  if false; then/'
mutant_perl() { # <name> <perl -0pe expression>
  local name="$1" expr="$2" m="$W/mutp.$RANDOM.sh" o
  perl -0pe "$expr" "$REAL" > "$m"
  if cmp -s "$REAL" "$m"; then echo "  FAIL: mutant '$name' did not change the guard"; FAIL=$((FAIL+1)); return; fi
  o="$(suite "$m")"
  if [ "$(fails_of "$o")" -gt 0 ]; then PASS=$((PASS+1)); echo "  mutant '$name' is caught ($(fails_of "$o") expectation(s) fail)"
  else echo "  FAIL: mutant '$name' SURVIVED the suite"; FAIL=$((FAIL+1)); fi
}
mutant_perl "a jq failure on the extraction is taken for no pool sessions" 's/\|\| \{\n    log "WARN pool nudge: could not pick[^\n]*\n    return 0\n  \}/|| targets=""/'
mutant "the cooldown stamp is written although nobody was told" 's/  if \[ "\$sent" -gt 0 \]; then/  if true; then/'

echo "dolt-disk-floor-guard pool-nudge selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
