#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ond0fa.sh — prod test for ga-ond0fa: when
# dolt-disk-floor-guard enters WARN/CRITICAL it photographs WHICH directories
# grew (vs a "last OK" baseline) BEFORE any reclaim lever runs, instead of only
# logging "avail=" — the 2026-09-25 01:30->02:16 dive (10->3GB, ~7GB) had no author.
#
# Verifies on the DEPLOYED $CITY/scripts/dolt-disk-floor-guard.sh (the file
# launchd runs in place — see the gascity rig's deploy_cmd), under /bin/bash 3.2
# (the interpreter the plist names; Homebrew bash 5 accepts what 3.2 rejects):
#   1. it parses under /bin/bash, and main() takes the episode photo BEFORE the
#      first reclaim lever and refreshes the baseline on the healthy path;
#   2. a REAL baseline -> growth -> episode-photo round trip on synthetic
#      directories reports the grown directory, records the episode, keeps the
#      baseline untouched, and feeds the Mayor-mail paragraph — every state file
#      redirected to a throwaway dir, the guard's real .gc/logs is never written.
# The feature's own selftest (300+ assertions, several minutes at this city's
# load) is NOT re-run here; set RUN_FULL_SELFTEST=1 to include it.
# Informational only (never fails): whether the live launchd job points at this
# file and whether the live baseline already exists — the guard is a
# StartInterval job, so the new code takes effect on its next 5-minute run and
# the first baseline lands on the first healthy cycle after that.
#
# Called by run.sh after deploy (STORY_ID=ga-ond0fa). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GUARD="$CITY/scripts/dolt-disk-floor-guard.sh"
SELFTEST="$CITY/scripts/dolt-disk-floor-guard.selftest.sh"
LABEL="com.gascity.dolt-disk-floor-guard"

log()  { echo "[prod-test:gascity ga-ond0fa] $*"; }
fail() { echo "[prod-test:gascity ga-ond0fa] FAIL: $*" >&2; exit 1; }

[[ -f "$GUARD" ]] || fail "guard missing: $GUARD"

log "Checking the deployed guard parses under /bin/bash (what launchd runs)..."
/bin/bash -n "$GUARD" || fail "$GUARD does not parse under /bin/bash (3.2)"
log "  parses ✓"

log "Checking main() wiring: episode photo BEFORE the floor-triggered reclaim levers, baseline refresh on the healthy path..."
awk '
  /^main\(\) \{/ { in_main = 1 }
  in_main && /^  _growth_episode_photo "\$class" "\$avail"/ { photo = NR }
  in_main && /^  _safe_reclaim "\$avail"/ { reclaim = NR }
  in_main && /^    _growth_clear_episode/ { clear_ = NR }
  in_main && /^    _growth_baseline_refresh "\$now"/ { base = NR }
  END { exit !(photo && reclaim && photo < reclaim && clear_ && base && clear_ < base) }
' "$GUARD" || fail "main() does not call _growth_episode_photo before _safe_reclaim (or lacks the healthy-path clear+baseline refresh) — the photo would see a disk the floor-triggered levers had already cleaned"
log "  photo precedes _safe_reclaim (the first floor-triggered lever; _reap_growing_logs runs every cycle before it, by design); healthy path clears the episode then refreshes the baseline ✓"

log "Running a real baseline -> growth -> episode-photo round trip on synthetic directories (state in a throwaway dir)..."
WORK="$(mktemp -d "${TMPDIR:-/tmp}/story-ga-ond0fa.XXXXXX")" || fail "cannot create a scratch dir"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/roundtrip.sh" <<'RTEOF'
#!/bin/bash
set -uo pipefail
export DOLT_DISK_FLOOR_GUARD_LIB=1
export DOLT_DISK_FLOOR_GUARD_LOG="$WORK/guard.log"
# shellcheck disable=SC1090
. "$GUARD"
STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
TAB="$(printf '\t')"
RA="$WORK/rootA"; RB="$WORK/rootB"
mkdir -p "$RA/db1" "$RA/db2" "$RB/keep"
head -c 1048576 /dev/zero > "$RA/db1/f"; head -c 1048576 /dev/zero > "$RA/db2/f"; head -c 1048576 /dev/zero > "$RB/keep/f"
_growth_roots() { printf '%s\n%s\n' "$RA" "$RB"; }
GROWTH_MIN_DELTA_MB=1

f() { echo "roundtrip FAIL: $*" >&2; exit 1; }

BASEF="$(_growth_baseline_file)"
_growth_baseline_refresh "$(date +%s)"
[ -s "$BASEF" ] && grep -q "^TS${TAB}[0-9]" "$BASEF" || f "no baseline photo written"
grep -q "^ROOT${TAB}OK${TAB}$RA" "$BASEF" || f "baseline did not record the synthetic root as OK"
# the ROOT line also carries how many du chunks could not read part of the tree: a MEASURED 0 here,
# never an absent field (absent = unknown, which the diff refuses to treat as "nothing was unreadable")
awk -F'\t' -v r="$RA" '$1 == "ROOT" && $2 == "OK" && $3 == r && $4 == "0" { ok = 1 } END { exit !ok }' "$BASEF" \
  || f "baseline ROOT line has no measured du-error count: $(grep '^ROOT' "$BASEF" | head -2 | tr '\t' ' ')"
SUM_BEFORE="$(cksum < "$BASEF")"

head -c 6291456 /dev/zero > "$RA/db2/growth.bin"        # db2 grows by 6MB
_growth_episode_photo CRITICAL 2
EPF="$(_growth_episode_file)"
PHOTO="$(sed -n 2p "$EPF" 2>/dev/null)"
[ "$(sed -n 1p "$EPF" 2>/dev/null)" = "CRITICAL" ] && [ -s "$PHOTO" ] || f "episode photo not recorded (episode file: $(tr '\n' '|' < "$EPF" 2>/dev/null))"
grep -q "^# ==== disk-growth report" "$PHOTO" || f "photo has no report section"
grep -Eq "^#   \+[0-9]+MB  $RA/db2" "$PHOTO" || f "report does not list the grown directory ($RA/db2): $(grep '^# ' "$PHOTO" | head -6 | tr '\n' '|')"
grep -q "keep" <(grep '^#   +' "$PHOTO") && f "an untouched directory was reported as grown"
[ "$(cksum < "$BASEF")" = "$SUM_BEFORE" ] || f "the episode photo modified the baseline"
_growth_episode_photo CRITICAL 2
[ "$(ls -1 "$STATE_DIR"/disk-growth-*.txt | grep -c .)" = "1" ] || f "a second CRITICAL cycle of the same episode re-photographed"
# captured, not piped into `grep -q`: under pipefail grep -q exits at the first
# match, the producer takes SIGPIPE, and a MATCH reads as a failure
MAILTXT="$(_growth_mail_text)"
case "$MAILTXT" in
  *"Photo file: $PHOTO"*) ;;
  *) f "the Mayor-mail paragraph does not cite the episode photo: $(printf '%s' "$MAILTXT" | head -c 200)" ;;
esac

# A root in which du cannot read part of the tree must be REPORTED as such — not read as complete, and
# not answered with "the growth is outside the roots" (gate ga-7sxd8n: du leaves an unreadable subtree
# out of its parent's row). 60MB lands inside a chmod-000 subtree between the two photos.
RC="$WORK/rootC"; mkdir -p "$RC/vis/locked"
head -c 1048576 /dev/zero > "$RC/vis/visible.bin"; head -c 8388608 /dev/zero > "$RC/vis/locked/hidden.bin"
trap 'chmod 700 "$RC/vis/locked" 2>/dev/null' EXIT
chmod 000 "$RC/vis/locked"
if du -sk "$RC/vis" >/dev/null 2>&1; then
  echo "roundtrip: (skipped the du-error case — chmod 000 does not stop du here, e.g. running as root)"
else
  printf '%s\n' "$RC" | _disk_growth_photo "$WORK/c-base.txt" || f "could not photograph the du-error root"
  chmod 700 "$RC/vis/locked"; head -c 62914560 /dev/zero > "$RC/vis/locked/grown.bin"; chmod 000 "$RC/vis/locked"
  printf '%s\n' "$RC" | _disk_growth_photo "$WORK/c-now.txt" || f "could not photograph the du-error root (now)"
  CREP="$(_growth_report "$WORK/c-base.txt" "$WORK/c-now.txt")"
  case "$CREP" in
    *"none in the roots that could be compared"*) f "a root with du errors read as 'the growth is outside the roots': $(printf '%s' "$CREP" | head -c 300)" ;;
    *"DU ERRORS: $RC"*) ;;
    *) f "the report does not flag the root du could not fully read: $(printf '%s' "$CREP" | head -c 300)" ;;
  esac
  chmod 700 "$RC/vis/locked"
fi
echo "roundtrip OK: photo=$(basename "$PHOTO")"
RTEOF
if ! WORK="$WORK" GUARD="$GUARD" /bin/bash "$WORK/roundtrip.sh" >"$WORK/roundtrip.out" 2>&1; then
    tail -20 "$WORK/roundtrip.out" >&2
    fail "the round trip did not pass on the deployed guard"
fi
log "  $(tail -1 "$WORK/roundtrip.out") ✓"

if [[ "${RUN_FULL_SELFTEST:-0}" == "1" ]]; then
    [[ -f "$SELFTEST" ]] || fail "selftest missing: $SELFTEST"
    log "Running the full selftest under /bin/bash (several minutes)..."
    /bin/bash "$SELFTEST" >"$WORK/selftest.out" 2>&1 || { tail -20 "$WORK/selftest.out" >&2; fail "selftest did not pass on the deployed artifact"; }
    log "  selftest PASS ✓"
fi

# ── informational: is the LIVE job this file, and has it started photographing? ─
# Captured, not piped into grep -q (gate ga-h2gdd2): `launchctl list` is ~33KB,
# grep -q exits on the first match, launchctl takes SIGPIPE and pipefail turns a
# MATCH into "not loaded" (~28% of runs measured). Same hazard as MAILTXT above.
LAUNCHCTL_LIST="$(launchctl list 2>/dev/null)"
if [[ "$LAUNCHCTL_LIST" == *"$LABEL"* ]]; then
    LAUNCHCTL_PRINT="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"
    if [[ "$LAUNCHCTL_PRINT" == *"$GUARD"* ]]; then
        log "  (info) live job $LABEL runs this file ✓"
    else
        log "  (info) live job $LABEL is loaded but its program path was not confirmed as $GUARD — check 'launchctl print gui/$(id -u)/$LABEL'"
    fi
else
    log "  (info) live job $LABEL is not loaded on this host"
fi
LIVE_BASE="$CITY/.gc/logs/.dolt-disk-floor-guard.growth-baseline"
if [[ -s "$LIVE_BASE" ]]; then
    log "  (info) live baseline photo present ✓"
else
    log "  (info) no live baseline yet — it appears on the first healthy (class=NONE) guard cycle after this deploy"
fi

log "PASS — deployed guard photographs WHAT GREW before reclaim, diffs against the last OK baseline, and cites it in the CRITICAL mail"
exit 0
