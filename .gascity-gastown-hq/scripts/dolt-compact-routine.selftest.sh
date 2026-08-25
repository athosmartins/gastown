#!/bin/bash
# dolt-compact-routine.selftest.sh — unit + orchestration tests for
# dolt-compact-routine.sh (ga-6uz7yn).
#
# Hermetic: sources the script as a LIBRARY (DOLT_COMPACT_ROUTINE_LIB=1), so
# main() never runs. Every _decide_and_run scenario below stubs the 3
# precondition checks, _run_compact, _snapshot_db, and _rescan_control_bead —
# the real `gc dolt compact`, real `bd`, and real notify/mail are NEVER
# invoked. All paths (DOLTDIR, QUARANTINE_DIR, LOG, BACKUP_LOG, HALT_SENTINEL,
# LOCK_DIR) point at a throwaway scratch dir, never the live city.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-compact-routine.sh"

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export DOLT_COMPACT_ROUTINE_LIB=1
export DOLT_COMPACT_ROUTINE_LOG="$SCRATCH/routine.log"
export DOLT_COMPACT_ROUTINE_BACKUP_LOG="$SCRATCH/backup.log"
export DOLT_COMPACT_HALT_SENTINEL="$SCRATCH/HALT"
export DOLT_COMPACT_LOCK_DIR="$SCRATCH/lock.d"
# shellcheck disable=SC1090
. "$SCRIPT"

# Never let a stray code path touch the real notify/mail binaries during any
# test below — set once, globally, before any scenario runs.
NOTIFY="$SCRATCH/fake-notify.sh"
cat > "$NOTIFY" <<'EOF'
#!/bin/bash
echo "NOTIFY-CALLED $*" >> "${FAKE_NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$NOTIFY"
GC="$SCRATCH/fake-gc.sh"
cat > "$GC" <<'EOF'
#!/bin/bash
echo "GC-CALLED $*" >> "${FAKE_GC_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$GC"
RESEED_SCRIPT="$SCRATCH/fake-reseed.sh"
cat > "$RESEED_SCRIPT" <<'EOF'
#!/bin/bash
echo "RESEED-CALLED $*" >> "${FAKE_RESEED_LOG:-/dev/null}"
[ "$1" = "${FAKE_RESEED_FAIL_DB:-}" ] && [ -n "${FAKE_RESEED_FAIL_DB:-}" ] && exit 1
exit 0
EOF
chmod +x "$RESEED_SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-compact-routine.selftest.sh ==="

# ════════════════════════════════════════════════════════════════════════════
# 1. Pure decision functions
# ════════════════════════════════════════════════════════════════════════════
echo "── _headroom_ok ──"
_headroom_ok 100 40 2 && ok "100 >= 40*2(80) → ok" || bad "100 vs 80 should pass"
_headroom_ok 79 40 2 && bad "79 < 80 should fail" || ok "79 < 80 → refuse"
_headroom_ok 80 40 2 && ok "boundary: exactly 2x → ok (>=, not >)" || bad "boundary 80==80 should pass"
_headroom_ok "" 40 2 && bad "empty avail should fail-closed" || ok "empty avail → refuse (fail-closed, not fail-open)"
_headroom_ok 100 "" 2 && bad "empty largest should fail-closed" || ok "empty largest → refuse"
_headroom_ok abc 40 2 && bad "non-numeric avail should fail-closed" || ok "non-numeric avail → refuse"

echo "── _gate_quiet ──"
_gate_quiet 0 0 0 0 && ok "all zero → quiet" || bad "0/0/0/0 should be quiet"
_gate_quiet 1 0 0 0 && bad "dispatching=1 should not be quiet" || ok "dispatching=1 → not quiet"
_gate_quiet 0 1 0 0 && bad "claimed=1 should not be quiet" || ok "claimed=1 → not quiet"
_gate_quiet 0 0 1 0 && bad "running=1 should not be quiet" || ok "running=1 → not quiet (this is the label _check_quiet deliberately adds beyond list_gate_active_source_beads)"
_gate_quiet 0 0 0 1 && bad "reviewing=1 should not be quiet" || ok "reviewing=1 → not quiet (ga-6uz7yn adversarial review finding 1: currently-dead label, but treated as dispatching-equivalent elsewhere in this codebase — must still gate if it's ever written)"
_gate_quiet "" 0 0 0 && bad "UNKNOWN dispatching should fail-closed" || ok "UNKNOWN (failed query) → not quiet, never conflated with 0"
_gate_quiet 0 0 0 "" && bad "UNKNOWN reviewing should fail-closed" || ok "UNKNOWN reviewing (failed query) → not quiet, never conflated with 0"

echo "── _classify_compact_output ──"
noop_out='compact: db=gastown commits=1840 below_threshold=2000 — skip
compact: db=lexbh not in GC_DOLT_COMPACT_ONLY_DBS — skip'
a="$(_classify_compact_output "$noop_out")"
[ -z "$a" ] && ok "pure skip output → no attempted dbs (silent noop)" || bad "expected empty, got: '$a'"

one_out='compact: db=gastown commits=1840 below_threshold=2000 — skip
compact: db=whatsapp_automation commits=2500 root=abc123 tables=42 — flattening...
compact: db=whatsapp_automation flatten OK'
a="$(_classify_compact_output "$one_out")"
[ "$a" = "whatsapp_automation" ] && ok "one real attempt correctly extracted" || bad "expected 'whatsapp_automation', got: '$a'"

two_out='compact: db=marketing commits=3000 root=aaa tables=5 — flattening...
compact: db=property_scrapers commits=4000 root=bbb tables=9 — flattening...'
a="$(_classify_compact_output "$two_out" | paste -sd, -)"
[ "$a" = "marketing,property_scrapers" ] && ok "two real attempts both extracted, in order" || bad "expected 'marketing,property_scrapers', got: '$a'"

echo "── _db_rig_paths / _rig_path_for_db ──"
RM="$SCRATCH/rigmap"
mkdir -p "$RM/rig-one/.beads" "$RM/rig-two/.beads"
printf '{"dolt_database": "alpha"}\n' > "$RM/rig-one/.beads/metadata.json"
printf '{"dolt_database": "beta"}\n' > "$RM/rig-two/.beads/metadata.json"
FAKE_RIG_JSON=$(printf '{"rigs":[{"name":"rig-one","path":"%s"},{"name":"rig-two","path":"%s"},{"name":"rig-broken","path":"%s/does-not-exist"}]}' "$RM/rig-one" "$RM/rig-two" "$RM")
rigtable="$(_db_rig_paths "$FAKE_RIG_JSON")"
p="$(_rig_path_for_db "alpha" "$rigtable")"
[ "$p" = "$RM/rig-one" ] && ok "_db_rig_paths keys by dolt_database (alpha), NOT by rig name (rig-one)" || bad "expected $RM/rig-one, got '$p'"
p="$(_rig_path_for_db "beta" "$rigtable")"
[ "$p" = "$RM/rig-two" ] && ok "second rig also correctly mapped (beta -> rig-two's own path)" || bad "expected $RM/rig-two, got '$p'"
p="$(_rig_path_for_db "rig-broken" "$rigtable")"
[ -z "$p" ] && ok "a rig whose metadata.json is unreadable contributes NO mapping (not a blank/guessed one)" || bad "broken rig should not resolve, got '$p'"
p="$(_rig_path_for_db "gamma" "$rigtable")"
[ -z "$p" ] && ok "unmapped db name → empty (caller must exclude it, never guess a path)" || bad "unmapped db should be empty, got '$p'"
rm -rf "$RM"

echo "── _is_quarantined / _enumerate_eligible_dbs (now gated on rig-resolvability too) ──"
QT="$SCRATCH/q-doltdir"; QQ="$SCRATCH/q-quarantine"
mkdir -p "$QT/hq" "$QT/whatsapp_automation" "$QT/gastown" "$QT/orphan-no-rig" "$QQ"
: > "$QQ/hq"                                   # live quarantine
: > "$QQ/whatsapp_automation.resolvido-ga-wfzmk"  # RELEASED (suffixed) — must NOT count
_is_quarantined "hq" "$QQ" 2>/dev/null; QUARANTINE_DIR="$QQ" _is_quarantined "hq" && ok "hq: live marker → quarantined" || bad "hq should be quarantined"
QUARANTINE_DIR="$QQ" _is_quarantined "whatsapp_automation" && bad "resolved marker should NOT count as quarantined" || ok "whatsapp_automation: only a .resolvido- suffixed marker exists → NOT quarantined"
QUARANTINE_DIR="$QQ" _is_quarantined "gastown" && bad "no marker at all should not be quarantined" || ok "gastown: no marker → not quarantined"
# fixture rig map covers hq/gastown/whatsapp_automation but deliberately has
# NO entry for "orphan-no-rig" — mirrors the real `beads`/`fixdepkeys_*`
# scratch databases that exist under .beads/dolt/ but have no registered rig
# (ga-6uz7yn adversarial review: these are excluded from eligibility
# entirely, not just from verification, because an unverifiable db must
# never be one this routine compacts).
QMAP=$(printf '{"rigs":[{"name":"hq","path":"%s"},{"name":"gastown","path":"%s"},{"name":"whatsapp_automation","path":"%s"}]}' "$QT/hq" "$QT/gastown" "$QT/whatsapp_automation")
for d in hq gastown whatsapp_automation; do mkdir -p "$QT/$d/.beads"; printf '{"dolt_database": "%s"}\n' "$d" > "$QT/$d/.beads/metadata.json"; done
qrigtable="$(_db_rig_paths "$QMAP")"
elig="$(_enumerate_eligible_dbs "$QT" "$QQ" "$qrigtable" | sort | paste -sd, -)"
[ "$elig" = "gastown,whatsapp_automation" ] && ok "eligible set excludes the quarantined db (hq) AND the rig-unmapped one (orphan-no-rig)" || bad "expected 'gastown,whatsapp_automation', got: '$elig'"
rm -rf "$QT" "$QQ"

echo "── _snapshot_db: REAL regression test for adversarial-review finding 1 ──"
echo "    (bd -C on a path NESTED under a shared parent silently re-resolves"
echo "    to the PARENT's own database — this is why a real, separate rig"
echo "    checkout is mandatory, never \$DOLTDIR/\$db directly)"
RT="$SCRATCH/regression-real-bd"
mkdir -p "$RT/store-a" "$RT/store-b"
( cd "$RT/store-a" && bd init --non-interactive --prefix rta >/dev/null 2>&1 )
( cd "$RT/store-b" && bd init --non-interactive --prefix rtb >/dev/null 2>&1 )
bd -C "$RT/store-a" create "fixture bead A" -t task -q >/dev/null 2>&1
bd -C "$RT/store-b" create "fixture bead B1" -t task -q >/dev/null 2>&1
bd -C "$RT/store-b" create "fixture bead B2" -t task -q >/dev/null 2>&1

cnt_a="$(_snapshot_db "$RT/store-a" | awk '{print $1}')"
cnt_b="$(_snapshot_db "$RT/store-b" | awk '{print $1}')"
[ "$cnt_a" = "1" ] && ok "store-a (real, separate rig checkout) correctly reads its OWN count (1)" || bad "expected store-a count=1, got '$cnt_a'"
[ "$cnt_b" = "2" ] && ok "store-b (real, separate rig checkout) correctly reads its OWN count (2)" || bad "expected store-b count=2, got '$cnt_b'"
[ "$cnt_a" != "$cnt_b" ] && ok "two distinct real dbs → two distinct counts (THIS is the actual bug: before the fix, both were indistinguishable)" || bad "REGRESSION: store-a and store-b returned the SAME count ($cnt_a) — finding-1 bug is back"

# Reproduce the ORIGINAL bug shape directly (a path nested under store-a's
# own tree, mimicking $CITY/.beads/dolt/<db> nested under $CITY/.beads/), to
# prove this fixture harness is actually capable of catching a regression —
# not just coincidentally passing.
mkdir -p "$RT/store-a/fake-nested/dolt/some-other-db"
cnt_nested="$(_snapshot_db "$RT/store-a/fake-nested/dolt/some-other-db" | awk '{print $1}')"
[ "$cnt_nested" = "$cnt_a" ] && ok "confirmed bug mechanism: a path NESTED under store-a's tree silently aliases store-a's own count ($cnt_a) — proves why callers must resolve a real rig checkout, never construct a path under a shared parent" || bad "expected the nested path to alias store-a's count ($cnt_a), got '$cnt_nested'"
rm -rf "$RT"

echo "── _largest_db_mb (real filesystem, MB granularity — not GB, see script header) ──"
LT="$SCRATCH/l-doltdir"; mkdir -p "$LT/small" "$LT/big" "$LT/empty"
dd if=/dev/zero of="$LT/small/f" bs=1m count=2 >/dev/null 2>&1
dd if=/dev/zero of="$LT/big/f"   bs=1m count=9 >/dev/null 2>&1
m="$(_largest_db_mb "$LT" "$(printf 'small\nbig\nempty\n')")"
[ "$m" -ge 8 ] && [ "$m" -le 10 ] && ok "largest across 3 dbs correctly picks the ~9MB one (got ${m}MB)" || bad "expected ~9MB, got '$m'"
m="$(_largest_db_mb "$LT" "")"
[ "$m" = "0" ] && ok "empty list → 0 (legitimate no-op, not an error)" || bad "expected 0, got '$m'"
rm -rf "$LT"

echo "── _avail_mb ──"
m="$(_avail_mb "$SCRATCH")"
case "$m" in ''|*[!0-9]*) bad "real path should return a number, got '$m'" ;; *) ok "real path → numeric MB ($m)" ;; esac
m="$(_avail_mb "/no/such/path/at/all")"
[ -z "$m" ] && ok "nonexistent path → empty (never silently 0 — error and empty must not be the same value)" || bad "expected empty, got '$m'"

echo "── _backup_today_ok ──"
TODAY="$(date '+%Y-%m-%d')"
YDAY="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d')"
BL="$SCRATCH/backup-fixture.log"

cat > "$BL" <<EOF
[$TODAY 04:00:00] === run start (port=52756 bucket=x) ===
[$TODAY 04:00:03] beads: OK (issues=0 head=abc size=1K)
[$TODAY 04:00:06] whatsapp_automation: OK (issues=100 head=def size=1G)
[$TODAY 04:01:20] === run complete: ok=2 failed=0 total=2 ===
EOF
r="$(_backup_today_ok "$BL" "$TODAY" "$(printf 'beads\nwhatsapp_automation\n')")" && ok "healthy today's run, all eligible dbs OK, failed=0 → pass" || bad "should have passed: $r"

r="$(_backup_today_ok "$BL" "$TODAY" "$(printf 'beads\ngastown\n')")" && bad "should fail: gastown never appeared as OK" || ok "eligible db missing from backup block → refuse ($r)"

cat > "$BL" <<EOF
[$YDAY 04:00:00] === run start (port=52756 bucket=x) ===
[$YDAY 04:00:03] beads: OK (issues=0 head=abc size=1K)
[$YDAY 04:01:20] === run complete: ok=1 failed=0 total=1 ===
EOF
r="$(_backup_today_ok "$BL" "$TODAY" "$(printf 'beads\n')")" && bad "yesterday's run should not satisfy 'today'" || ok "latest run is from yesterday → refuse ($r)"

cat > "$BL" <<EOF
[$TODAY 04:00:00] === run start (port=52756 bucket=x) ===
[$TODAY 04:00:03] beads: OK (issues=0 head=abc size=1K)
[$TODAY 04:00:06] whatsapp_automation: DOLT_BACKUP sync FAILED
[$TODAY 04:01:20] === run complete: ok=1 failed=1 total=2 ===
EOF
r="$(_backup_today_ok "$BL" "$TODAY" "$(printf 'beads\n')")" && bad "failed=1 in the run should refuse even if MY eligible db was OK" || ok "run closed with failed=1 (a DIFFERENT db failed) → refuse anyway ($r)"

r="$(_backup_today_ok "$SCRATCH/does-not-exist.log" "$TODAY" "$(printf 'beads\n')")" && bad "missing log should refuse" || ok "no backup log at all → refuse, fail-closed ($r)"
rm -f "$BL"

# ════════════════════════════════════════════════════════════════════════════
# 2. Lock — mkdir-atomic + heartbeat + PID:RANDOM token, stale reclaim.
#    Mirrors ga-y0g5x's own AC almost verbatim: "two runs fired together: the
#    second exits without working and without alarming."
# ════════════════════════════════════════════════════════════════════════════
echo "── lock: double-fire ──"
rm -rf "$LOCK_DIR"
LOCK_TOKEN="proc-A:111"; _acquire_lock && ok "first acquirer gets the lock" || bad "first acquire should succeed"
LOCK_TOKEN="proc-B:222"; _acquire_lock && bad "second concurrent acquirer should back off" || ok "second acquirer (live holder) backs off silently — no error, this is serialization"
LOCK_TOKEN="proc-A:111"; _release_lock
[ -d "$LOCK_DIR" ] && bad "lock dir should be gone after the OWNER releases" || ok "owner's release removes the lock"

# Token shape is PID:RANDOM (matches production's "$$:${RANDOM}${RANDOM}" —
# _lock_holder_dead does `cut -d: -f1` to get the PID, so the numeric PID
# MUST be the part before the colon, not a fake human-readable label there.
echo "── lock: a live holder's lock is never stolen, even by a later caller ──"
rm -rf "$LOCK_DIR"
LOCK_TOKEN="$$:aaa"; _acquire_lock >/dev/null   # real, current PID → "alive"
LOCK_TOKEN="333:ccc"; _acquire_lock && bad "should not steal a lock held by a live PID" || ok "holder PID is alive ($$) → not reclaimed"
LOCK_TOKEN="$$:aaa"; _release_lock

echo "── lock: stale (dead PID) is reclaimed, not wedged forever ──"
rm -rf "$LOCK_DIR"
DEAD_PID=999999   # astronomically unlikely to be a live pid on this host
LOCK_TOKEN="$DEAD_PID:bbb"; _acquire_lock >/dev/null
LOCK_TOKEN="444:ddd"; _acquire_lock && ok "dead-PID holder → fast-path reclaimed by a later caller" || bad "should have reclaimed a dead-PID lock"
own="$(head -n1 "$LOCK_HB" 2>/dev/null)"
[ "$own" = "444:ddd" ] && ok "reclaimer's own token is now the heartbeat owner" || bad "expected 444:ddd as owner, got '$own'"
LOCK_TOKEN="444:ddd"; _release_lock

echo "── lock: aged-out heartbeat (unknown/unparseable holder) is reclaimed after MAX_AGE ──"
rm -rf "$LOCK_DIR"
LOCK_MAX_AGE=1
mkdir "$LOCK_DIR"; printf 'not-a-valid-token\n' > "$LOCK_HB"
touch -t 202001010000 "$LOCK_HB" 2>/dev/null || touch -d '2020-01-01' "$LOCK_HB" 2>/dev/null
LOCK_TOKEN="proc-E:555"; _acquire_lock && ok "very old + unparseable heartbeat → reclaimed via age path" || bad "should have reclaimed the aged-out lock"
LOCK_TOKEN="proc-E:555"; _release_lock
LOCK_MAX_AGE=5400   # restore default for anything below

# ════════════════════════════════════════════════════════════════════════════
# 3. _decide_and_run orchestration — the AC #6 test: "simulate a db above
#    threshold with a missing precondition -> assert it does NOT compact."
#    This drives the REAL _decide_and_run (not a reimplementation) with the
#    real precondition-gating logic in the loop — a prior HEAD that called
#    _run_compact unconditionally (no gate at all) would fail this test.
# ════════════════════════════════════════════════════════════════════════════
echo "── _decide_and_run: precondition failure must prevent _run_compact ──"

_setup_fixture_city() {
  rm -rf "$SCRATCH/city"
  DOLTDIR="$SCRATCH/city/doltdir"
  QUARANTINE_DIR="$SCRATCH/city/quarantine"
  mkdir -p "$DOLTDIR/whatsapp_automation" "$QUARANTINE_DIR"
  # _enumerate_eligible_dbs now ALSO requires a resolvable rig mapping (the
  # ga-6uz7yn adversarial-review fix) — without this, ELIGIBLE_DBS comes back
  # empty, _decide_and_run exits at the "no eligible databases" check before
  # ever reaching preconditions, and EVERY test below (including the positive
  # control) would silently see RUN_COMPACT_CALLS=0 for the wrong reason.
  mkdir -p "$SCRATCH/city/rigs/wa-fixture/.beads"
  printf '{"dolt_database": "whatsapp_automation"}\n' > "$SCRATCH/city/rigs/wa-fixture/.beads/metadata.json"
  _rig_list_json() { printf '{"rigs":[{"name":"wa-fixture","path":"%s/city/rigs/wa-fixture"}]}\n' "$SCRATCH"; }
  rm -rf "$LOCK_DIR"
  rm -f "$HALT_SENTINEL"
  : > "$LOG"
}

RUN_COMPACT_CALLS=0
_run_compact() { RUN_COMPACT_CALLS=$((RUN_COMPACT_CALLS + 1)); _COMPACT_STDOUT=""; _COMPACT_RC=0; }

# -- negative control: quiet-check fails → must refuse before ever calling _run_compact
_setup_fixture_city
RUN_COMPACT_CALLS=0
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { _REASON="quiet-city precondition failed: dispatching=2 claimed=0 running=1 (need all 0)"; return 1; }
ENABLED=1
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 0 ] && ok "AC#6: city not quiet → _run_compact NEVER invoked" || bad "AC#6 FAILED: _run_compact was called $RUN_COMPACT_CALLS time(s) despite a failing precondition"
grep -q "REFUSE" "$LOG" && ok "refusal is logged with the reason" || bad "expected a REFUSE line in the log"
[ ! -f "$HALT_SENTINEL" ] && ok "a precondition refusal never writes a HALT sentinel (only a verification divergence does)" || bad "HALT sentinel should not exist yet"

# -- same for the other two preconditions, one at a time (each must independently gate)
_setup_fixture_city
RUN_COMPACT_CALLS=0
_check_backup()   { _REASON="backup precondition failed: latest backup run is not from today"; return 1; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 0 ] && ok "backup precondition failing alone also blocks _run_compact" || bad "backup-precondition case should have blocked compact"

_setup_fixture_city
RUN_COMPACT_CALLS=0
_check_backup()   { return 0; }
_check_headroom() { _REASON="headroom precondition failed: avail=100MB largest-eligible=900MB need>=1800MB"; return 1; }
_check_quiet()    { return 0; }
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 0 ] && ok "headroom precondition failing alone also blocks _run_compact" || bad "headroom-precondition case should have blocked compact"

# -- positive control: the harness itself must be capable of reaching
#    _run_compact when every gate genuinely passes (proves the negative
#    controls above are testing something real, not a permanently-0 stub)
_setup_fixture_city
RUN_COMPACT_CALLS=0
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_snapshot_db()          { echo "10 ga-fixture-1 3"; }   # identical before/after → clean
_rescan_control_bead()  { echo "3"; }
_run_compact() { RUN_COMPACT_CALLS=$((RUN_COMPACT_CALLS + 1)); _COMPACT_STDOUT="compact: db=whatsapp_automation commits=2500 root=abc tables=9 — flattening...
compact: db=whatsapp_automation flatten OK"; _COMPACT_RC=0; }
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 1 ] && ok "positive control: all preconditions pass → _run_compact IS invoked exactly once" || bad "positive control FAILED: _run_compact called $RUN_COMPACT_CALLS time(s), expected 1"
[ ! -f "$HALT_SENTINEL" ] && ok "clean verification (identical snapshots) → no HALT" || bad "should not have halted on a clean run"
grep -q "post-verification clean" "$LOG" && ok "clean run logs a verification-clean line" || bad "expected a verification-clean log line"

# -- steady-state NOOP: preconditions pass, but compact finds nothing to do
#    (every db below threshold) → silent, no notify
_setup_fixture_city
RUN_COMPACT_CALLS=0
: > "$SCRATCH/fake-notify.log"
_run_compact() { RUN_COMPACT_CALLS=$((RUN_COMPACT_CALLS + 1)); _COMPACT_STDOUT="compact: db=whatsapp_automation commits=1200 below_threshold=2000 — skip"; _COMPACT_RC=0; }
FAKE_NOTIFY_LOG="$SCRATCH/fake-notify.log" _decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 1 ] && ok "noop case: compact IS invoked (preconditions passed)..." || bad "noop case should still invoke compact once"
[ ! -s "$SCRATCH/fake-notify.log" ] && ok "...but a pure skip-only result never calls notify (silent steady state, per the bead's own AC)" || bad "noop should not have notified: $(cat "$SCRATCH/fake-notify.log" 2>/dev/null)"
grep -q "NOOP" "$LOG" && ok "noop is still logged (log-only, not silent in the log itself)" || bad "expected a NOOP log line"

# -- verification divergence → HALT sentinel written, mail attempted, no
#    silent pass-through
_setup_fixture_city
RUN_COMPACT_CALLS=0
: > "$SCRATCH/fake-gc.log"
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_run_compact() { _COMPACT_STDOUT="compact: db=whatsapp_automation commits=2500 root=abc tables=9 — flattening...
compact: db=whatsapp_automation flatten OK"; _COMPACT_RC=0; }
# Call counter MUST be file-based, not a shell variable: _snapshot_db is
# invoked as `line="$(_snapshot_db ...)"` in _decide_and_run, and a command
# substitution runs in a SUBSHELL — any in-memory variable mutation inside it
# is invisible to the parent once the subshell exits. A `SNAP_CALL=$((...))`
# shell-variable counter here would silently never advance past its inherited
# value, and BOTH the before- and after- calls would return the SAME line —
# exactly masking the divergence this test exists to catch. Only a file
# survives across separate subshell invocations.
SNAP_CALL_FILE="$SCRATCH/snap-call-count"; echo 0 > "$SNAP_CALL_FILE"
_snapshot_db() {
  local n; n=$(($(cat "$SNAP_CALL_FILE") + 1)); echo "$n" > "$SNAP_CALL_FILE"
  if [ "$n" -eq 1 ]; then echo "500 ga-fixture-1 7"; else echo "499 ga-fixture-1 7"; fi
}
_rescan_control_bead() { echo "7"; }
FAKE_GC_LOG="$SCRATCH/fake-gc.log" _decide_and_run
[ -f "$HALT_SENTINEL" ] && ok "bead-count divergence (500 -> 499) → HALT sentinel written" || bad "expected a HALT sentinel after a count divergence"
grep -q "bead count changed 500 -> 499" "$HALT_SENTINEL" 2>/dev/null && ok "HALT sentinel names the exact divergence" || bad "HALT sentinel missing the specific divergence detail"
grep -q "GC-CALLED mail send mayor" "$SCRATCH/fake-gc.log" 2>/dev/null && ok "a divergence mails the Mayor (durable — survives a session restart)" || bad "expected the fake gc stub to record a mail-send-mayor call"

# -- rc!=0 despite a non-empty $attempted (a DIFFERENT eligible db failed
#    inside this same compact invocation, e.g. newly quarantined by
#    compact's own verify_counts) must ALSO halt, even when the wrapper's
#    OWN bead-count/control-bead check sees nothing wrong for the db that
#    DID flatten. Regression test for ga-6uz7yn adversarial-review finding
#    2: a prior HEAD only consulted $_COMPACT_RC in the "$attempted is
#    empty" branch — once $attempted was non-empty it was never checked
#    again, so this exact case reported a bare "✅ compacted ... verification
#    clean" and silently dropped a real per-db failure. Identical snapshots
#    on every _snapshot_db call proves the bead-count check ALONE cannot
#    catch this — only the rc check can.
_setup_fixture_city
RUN_COMPACT_CALLS=0
: > "$SCRATCH/fake-gc.log"
: > "$SCRATCH/fake-notify.log"
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_run_compact() { _COMPACT_STDOUT="compact: db=whatsapp_automation commits=2500 root=abc tables=9 — flattening...
compact: db=whatsapp_automation flatten OK
compact: db=some-other-db integrity quarantine marker exists — manual intervention required before compaction or GC"; _COMPACT_RC=1; }
_snapshot_db()         { echo "500 ga-fixture-1 7"; }   # IDENTICAL every call — the bead-count signal alone sees nothing wrong
_rescan_control_bead() { echo "7"; }
FAKE_GC_LOG="$SCRATCH/fake-gc.log" FAKE_NOTIFY_LOG="$SCRATCH/fake-notify.log" _decide_and_run
[ -f "$HALT_SENTINEL" ] && ok "rc=1 with clean bead-counts still → HALT (finding 2: rc was silently dropped once \$attempted was non-empty)" || bad "REGRESSION (finding 2): rc!=0 alongside a successful-looking attempt did not halt"
grep -q "exited rc=1" "$HALT_SENTINEL" 2>/dev/null && ok "HALT sentinel names the nonzero exit code, not just the bead-count signal" || bad "HALT sentinel should mention the compact exit code"
grep -q "GC-CALLED mail send mayor" "$SCRATCH/fake-gc.log" 2>/dev/null && ok "this class of divergence also mails the Mayor" || bad "expected a mail-send-mayor call for the rc divergence"

echo "── _decide_and_run: HALT sentinel blocks a subsequent run entirely ──"
_setup_fixture_city
: > "$HALT_SENTINEL"; echo "HALTED (fixture)" > "$HALT_SENTINEL"
RUN_COMPACT_CALLS=0
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_run_compact() { RUN_COMPACT_CALLS=$((RUN_COMPACT_CALLS + 1)); }
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 0 ] && ok "an existing HALT sentinel blocks the run before preconditions are even checked" || bad "HALT sentinel should have short-circuited before compact"

echo "── _decide_and_run: kill switch ──"
_setup_fixture_city
RUN_COMPACT_CALLS=0
ENABLED=0
_decide_and_run
[ "$RUN_COMPACT_CALLS" -eq 0 ] && ok "DOLT_COMPACT_ROUTINE_ENABLED=0 → hard no-op" || bad "kill switch should have prevented everything"
ENABLED=1

# ════════════════════════════════════════════════════════════════════════════
# 4. Post-compaction reseed hook (ga-jz7gg, scope item 1) — after a
#    successful, clean-verified compact, each ATTEMPTED db must trigger
#    scripts/dolt-backup-reseed.sh <db>, exactly once, so the append-only
#    .dolt-backup staging area doesn't accumulate orphan blobs (3 prior
#    occurrences: 9.6G/12G/13G — see the story's own description). A skip-only
#    (nothing flattened) run must NEVER trigger reseed. A reseed failure is a
#    best-effort concern, not a data-integrity one — it must notify (silent
#    failure would recreate the exact bug this hook exists to close) but must
#    NEVER write a HALT sentinel (compact's own post-verification already
#    proved the DATA is fine; reseed only refreshes the BACKUP of that data).
# ════════════════════════════════════════════════════════════════════════════
echo "── _decide_and_run: reseed runs after a clean compact, once per attempted db ──"
_setup_fixture_city
RUN_COMPACT_CALLS=0
: > "$SCRATCH/fake-reseed.log"
: > "$SCRATCH/fake-notify.log"
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_snapshot_db()          { echo "10 ga-fixture-1 3"; }
_rescan_control_bead()  { echo "3"; }
_run_compact() { RUN_COMPACT_CALLS=$((RUN_COMPACT_CALLS + 1)); _COMPACT_STDOUT="compact: db=whatsapp_automation commits=2500 root=abc tables=9 — flattening...
compact: db=whatsapp_automation flatten OK"; _COMPACT_RC=0; }
FAKE_RESEED_LOG="$SCRATCH/fake-reseed.log" FAKE_NOTIFY_LOG="$SCRATCH/fake-notify.log" _decide_and_run
grep -q "RESEED-CALLED whatsapp_automation" "$SCRATCH/fake-reseed.log" 2>/dev/null && ok "clean compact of an attempted db triggers reseed with that db's name" || bad "expected 'RESEED-CALLED whatsapp_automation' in $SCRATCH/fake-reseed.log, got: $(cat "$SCRATCH/fake-reseed.log" 2>/dev/null)"
[ "$(grep -c 'RESEED-CALLED whatsapp_automation' "$SCRATCH/fake-reseed.log" 2>/dev/null)" = "1" ] && ok "reseed fires exactly once per attempted db, not more" || bad "expected exactly 1 reseed call for whatsapp_automation"

echo "── _decide_and_run: reseed only fires for ATTEMPTED dbs, never on a skip-only (noop) run ──"
_setup_fixture_city
: > "$SCRATCH/fake-reseed.log"
_run_compact() { _COMPACT_STDOUT="compact: db=whatsapp_automation commits=1200 below_threshold=2000 — skip"; _COMPACT_RC=0; }
FAKE_RESEED_LOG="$SCRATCH/fake-reseed.log" _decide_and_run
[ ! -s "$SCRATCH/fake-reseed.log" ] && ok "skip-only compact never triggers reseed (nothing was actually flattened)" || bad "reseed should not fire when nothing was attempted, got: $(cat "$SCRATCH/fake-reseed.log" 2>/dev/null)"

echo "── _decide_and_run: a reseed failure notifies but does NOT halt ──"
_setup_fixture_city
: > "$SCRATCH/fake-notify.log"
_check_backup()   { return 0; }
_check_headroom() { return 0; }
_check_quiet()    { return 0; }
_snapshot_db()          { echo "10 ga-fixture-1 3"; }
_rescan_control_bead()  { echo "3"; }
_run_compact() { _COMPACT_STDOUT="compact: db=whatsapp_automation commits=2500 root=abc tables=9 — flattening...
compact: db=whatsapp_automation flatten OK"; _COMPACT_RC=0; }
FAKE_RESEED_FAIL_DB="whatsapp_automation" FAKE_NOTIFY_LOG="$SCRATCH/fake-notify.log" _decide_and_run
[ ! -f "$HALT_SENTINEL" ] && ok "reseed failure does not write a HALT sentinel (compact's own data integrity was already verified clean; reseed is a separate, best-effort backup refresh)" || bad "reseed failure should never halt compact"
RESEED_NOTIFY_LINE="$(grep -i "reseed" "$SCRATCH/fake-notify.log" 2>/dev/null)"
[ -n "$RESEED_NOTIFY_LINE" ] && ok "reseed failure IS surfaced via notify (silent failure would recreate the exact orphan-blob problem this hook exists to close)" || bad "expected a notify call mentioning reseed, got: $(cat "$SCRATCH/fake-notify.log" 2>/dev/null)"
# Deliberately grep the isolated reseed-notify LINE, not the whole log — the
# unrelated "✅ compacted: whatsapp_automation" success notify ALSO contains
# the db name, and a whole-log grep would false-pass here even with the
# reseed-failure notify never implemented at all (caught live while writing
# this test: the whole-log version passed before the feature existed).
printf '%s' "$RESEED_NOTIFY_LINE" | grep -q "whatsapp_automation" && ok "notify names which db's reseed failed" || bad "notify should name the failing db, got: $RESEED_NOTIFY_LINE"
FAKE_RESEED_FAIL_DB=""

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
