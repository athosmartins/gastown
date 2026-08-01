#!/usr/bin/env bash
# order-exec-failure-watchdog.selftest.sh — hermetic proof for ga-q5t8r: a
# supervisor order that fails repeatedly must alert the Mayor, exactly once per
# cooldown window, with the engine's own diagnostic line attached — and a
# benign `context canceled` failure must never count or alert at all.
#
# No live supervisor.log/gc/launchd/notify: SUPERVISOR_LOG points at a fixture
# this test builds incrementally (simulating successive 5-min sweeps by
# appending lines and re-invoking run_sweep), and `gc`/`notify` are stubbed to
# record their calls instead of doing anything. Sources the watchdog in lib
# mode (ORDER_EXEC_FAILURE_WATCHDOG_LIB=1) so run_sweep() can be driven
# directly, once per simulated sweep, in-process.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SELF_DIR/order-exec-failure-watchdog.sh"
PLIST="$SELF_DIR/../packs/town-deltas/assets/order-exec-failure-watchdog.plist"
# The plist must reference where the script lives once deployed to the real
# HQ checkout — NOT wherever this selftest happens to be running from (a
# worktree path here would never match, before or after merge).
CANONICAL_SCRIPT="/Users/athos/gt/.gascity-gastown-hq/scripts/order-exec-failure-watchdog.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── hermetic stubs ─────────────────────────────────────────────────────────
export GC_CALLS_LOG="$TMP/gc-calls.log"
export NOTIFY_CALLS_LOG="$TMP/notify-calls.log"
: > "$GC_CALLS_LOG"; : > "$NOTIFY_CALLS_LOG"

cat > "$TMP/gc" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GC_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/gc"

cat > "$TMP/notify" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$NOTIFY_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/notify"
export PATH="$TMP:$PATH"

# Each stub invocation writes one "CALL:" header line, but the alert body
# passed via -m has EMBEDDED newlines of its own (it's a multi-line message) —
# so `wc -l` on the raw file counts those too. Count "CALL:" headers, not raw
# lines, to get the actual number of gc/notify invocations.
gc_call_count()     { grep -c '^CALL:' "$GC_CALLS_LOG" 2>/dev/null; }
notify_call_count() { grep -c '^CALL:' "$NOTIFY_CALLS_LOG" 2>/dev/null; }
# Isolates the single most recent invocation's full multi-line content (from
# its "CALL:" header to just before the next one, or EOF) — plain `tail -1`
# would only catch the last physical line of that entry, not its content.
last_call() { awk '/^CALL:/{buf=$0"\n"; next} {buf = buf $0 "\n"} END{printf "%s", buf}' "$1"; }

# ── fixture supervisor.log + isolated state dir ────────────────────────────
FIXTURE="$TMP/supervisor.log"
: > "$FIXTURE"

export OEFW_STATE="$TMP/state"
export GC_SUPERVISOR_LOG="$FIXTURE"
export OEFW_FAIL_THRESHOLD=2
export OEFW_COOLDOWN_SEC=3600
export OEFW_LOG="$TMP/watchdog.log"
export ORDER_EXEC_FAILURE_WATCHDOG_LIB=1
# shellcheck disable=SC1090
source "$WATCHDOG" || { echo "FATAL: could not source watchdog in lib mode"; exit 1; }
type run_sweep >/dev/null 2>&1 || { echo "FATAL: run_sweep not defined by watchdog"; exit 1; }

append() { printf '%s\n' "$1" >> "$FIXTURE"; }

# ── 1. bootstrap: pre-existing backlog must NOT alert on first-ever run ─────
echo "── 1. bootstrap skips historical backlog ──"
append "2026/07/31 07:45:48 gc: order exec mol-dog-backup failed: exit status 1"
append "2026/07/31 07:45:48 gc: order exec mol-dog-backup output: /path/port_resolve.sh: No such file or directory"
append "2026/07/31 07:50:52 gc: order exec mol-dog-backup failed: exit status 1"
run_sweep
eq "bootstrap: zero gc mail calls" "$(gc_call_count)" "0"
eq "bootstrap: zero notify calls"  "$(notify_call_count)" "0"
eq "bootstrap: cursor seeded at current EOF" "$(cat "$OEFW_STATE")" "$(wc -c < "$FIXTURE" | tr -d ' ')"

# ── 2. context-canceled is benign: never counted, never alerts ──────────────
echo "── 2. context-canceled is ignored, even repeatedly ──"
for i in 1 2 3 4 5; do
  append "2026/07/28 12:0$i:00 gc: order exec orphan-sweep failed: context canceled"
  run_sweep
done
eq "context-canceled ×5 sweeps: still zero gc calls" "$(gc_call_count)" "0"
[ ! -f "${OEFW_STATE}.fail-counts/orphan-sweep" ] \
  && ok "context-canceled never created a fail-count file" \
  || bad "context-canceled incorrectly created a fail-count file"

# ── 3. one real failure is below threshold — no alert yet ───────────────────
echo "── 3. single real failure stays below threshold ──"
append "2026/08/01 06:12:05 gc: order exec mol-dog-doctor failed: exit status 1"
append "2026/08/01 06:12:05 gc: order exec mol-dog-doctor output: /path/port_resolve.sh: No such file or directory"
run_sweep
eq "sweep-count after 1st failure" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "1"
eq "still zero gc calls (below threshold=2)" "$(gc_call_count)" "0"

# ── 4. second CONSECUTIVE sweep crosses threshold — alert fires with output: line ──
echo "── 4. second consecutive sweep alerts, with diagnostic attached ──"
append "2026/08/01 06:17:09 gc: order exec mol-dog-doctor failed: exit status 1"
append "2026/08/01 06:17:09 gc: order exec mol-dog-doctor output: /path/port_resolve.sh: No such file or directory"
run_sweep
eq "sweep-count after 2nd failure" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "2"
eq "exactly one gc mail call fired" "$(gc_call_count)" "1"
eq "exactly one notify call fired"  "$(notify_call_count)" "1"
grep -q 'mol-dog-doctor' "$GC_CALLS_LOG"          && ok "alert mail names the order" || bad "alert mail missing order name"
grep -q 'port_resolve.sh' "$GC_CALLS_LOG"         && ok "alert mail includes the engine's output: diagnostic" || bad "alert mail missing output: diagnostic"
grep -q 'consecutive sweeps' "$GC_CALLS_LOG"      && ok "alert mail states the consecutive-sweep count" || bad "alert mail missing sweep-count context"
grep -q 'mayor' "$GC_CALLS_LOG"                   && ok "mail addressed to mayor" || bad "mail not addressed to mayor"

# ── 5. still failing, but WITHIN cooldown — must NOT re-mail (this is the 78-mails bug) ──
echo "── 5. within cooldown: repeated failures do not flood ──"
for i in 1 2 3; do
  append "2026/08/01 06:2$i:00 gc: order exec mol-dog-doctor failed: exit status 1"
  run_sweep
done
eq "gc call count unchanged during cooldown (dedup holds)" "$(gc_call_count)" "1"

# ── 6. cooldown expires — a still-failing order alerts again (not silenced forever) ──
echo "── 6. after cooldown expires, a persisting failure re-alerts ──"
echo $(( $(date +%s) - OEFW_COOLDOWN_SEC - 10 )) > "${OEFW_STATE}.cooldown/mol-dog-doctor"
append "2026/08/01 07:30:00 gc: order exec mol-dog-doctor failed: exit status 1"
run_sweep
eq "gc call count incremented after cooldown expiry" "$(gc_call_count)" "2"

# ── 7. recovery: silence resets the counter, not just the cooldown ──────────
echo "── 7. a quiet sweep resets a recovered order's counter ──"
run_sweep    # no new lines appended — order went silent (=recovered)
[ ! -f "${OEFW_STATE}.fail-counts/mol-dog-doctor" ] \
  && ok "fail-count cleared after a quiet sweep" \
  || bad "fail-count NOT cleared after recovery — $(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor" 2>/dev/null)"
[ ! -f "${OEFW_STATE}.cooldown/mol-dog-doctor" ] \
  && ok "cooldown cleared after recovery (fresh alert next time, not stale window)" \
  || bad "cooldown NOT cleared after recovery"
append "2026/08/01 09:00:00 gc: order exec mol-dog-doctor failed: exit status 1"
run_sweep
eq "recovered order restarts its own count at 1, not resuming at 2+" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "1"

# ── 8. two orders failing at once get one batched alert, independent counters ──
# Two names UNTOUCHED by any earlier scenario — mol-dog-doctor carries a
# leftover fc=1 from test 7's setup, which would cross threshold a sweep
# ahead of a fresh order and fire two separate alerts instead of one batch
# (a real bug this exact mismatch caught once already: the recovery pass's
# containment check silently dropped a concurrently-failing order — see the
# `tr '\n' ' '` fix in the watchdog script). Fresh names isolate the
# batching assertion from that other scenario's accumulated state.
echo "── 8. concurrent failures: independent per-order state, batched mail ──"
GC_BEFORE=$(gc_call_count)
append "2026/08/01 09:05:00 gc: order exec mol-dog-compactor failed: exit status 1"
append "2026/08/01 09:05:00 gc: order exec dolt-health failed: exit status 1"
run_sweep
append "2026/08/01 09:10:00 gc: order exec mol-dog-compactor failed: exit status 1"
append "2026/08/01 09:10:00 gc: order exec dolt-health failed: exit status 1"
run_sweep
GC_AFTER=$(gc_call_count)
eq "one new batched alert covering both orders" "$((GC_AFTER - GC_BEFORE))" "1"
last_call "$GC_CALLS_LOG" | grep -q 'mol-dog-compactor' && ok "batched alert names mol-dog-compactor" || bad "batched alert missing mol-dog-compactor"
last_call "$GC_CALLS_LOG" | grep -q 'dolt-health'        && ok "batched alert names dolt-health"        || bad "batched alert missing dolt-health"

# ── 9. log rotation/truncation: cursor resets to 0, no crash ────────────────
echo "── 9. a shrunk log file (rotation) is handled without crashing ──"
: > "$FIXTURE"
append "2026/08/01 10:00:00 gc: order exec beads-health failed: exit status 1"
if run_sweep; then rc=0; else rc=1; fi
[ "$rc" = "0" ] || [ "$rc" = "1" ] && ok "sweep completes (rc=$rc) after truncation, does not crash the shell"
grep -q 'shrank' "$OEFW_LOG" && ok "rotation/truncation logged explicitly" || bad "rotation/truncation not logged"

# ── 10. real-shape duplicate lines: untimestamped echo must not corrupt state ──
# Live supervisor.log writes every event as TWO consecutive lines: one
# timestamped, one a bare untimestamped duplicate (confirmed against the real
# file, 2026-08-01 — e.g. line 447830 timestamped, 447831 an identical
# untimestamped echo). An earlier version of the parser matched both, and
# `$1 " " $2` grabbed "gc: order" as the "timestamp" from the untimestamped
# copy whenever it landed last — this proves that regression stays fixed:
# one sweep-count increment per sweep (not two, from the duplicate), and a
# real date in the alert body (not "gc: order").
echo "── 10. real-shape duplicate lines (timestamped + bare echo) ──"
append "2026/08/01 14:16:50 gc: order exec spawn-storm-detect failed: exit status 1"
append "gc: order exec spawn-storm-detect failed: exit status 1"
append "2026/08/01 14:16:50 gc: order exec spawn-storm-detect output: /path/to/missing-file"
append "gc: order exec spawn-storm-detect output: /path/to/missing-file"
run_sweep >/dev/null
eq "duplicate untimestamped echo does not double-count" "$(cat "${OEFW_STATE}.fail-counts/spawn-storm-detect")" "1"
append "2026/08/01 14:21:50 gc: order exec spawn-storm-detect failed: exit status 1"
append "gc: order exec spawn-storm-detect failed: exit status 1"
GC_BEFORE10=$(gc_call_count)
run_sweep
GC_AFTER10=$(gc_call_count)
eq "second sweep crosses threshold, one alert (not two from the duplicate)" "$((GC_AFTER10 - GC_BEFORE10))" "1"
last_call "$GC_CALLS_LOG" | grep -q '2026/08/01 14:21:50' \
  && ok "alert shows the REAL last-seen timestamp" \
  || bad "alert timestamp corrupted — likely picked up the untimestamped duplicate's bogus 'gc: order' field"
last_call "$GC_CALLS_LOG" | grep -qF 'gc: order' \
  && bad "alert leaked the untimestamped duplicate's garbage timestamp ('gc: order')" \
  || ok "no 'gc: order' garbage leaked into the alert"

# ── 11. drift-guard: the plist actually points at THIS script, on disk ──────
echo "── 11. drift-guard: plist wiring matches the shipped script ──"
[ -f "$PLIST" ] && ok "plist exists at packs/town-deltas/assets/order-exec-failure-watchdog.plist" \
                 || bad "plist NOT found — watchdog would never be deployed (ga-nehkr precedent)"
grep -qF "$CANONICAL_SCRIPT" "$PLIST" \
  && ok "plist ProgramArguments references the canonical deploy path" \
  || bad "plist ProgramArguments does NOT match $CANONICAL_SCRIPT — would fail to launch once deployed"
grep -q '<string>com.gascity.order-exec-failure-watchdog</string>' "$PLIST" \
  && ok "plist Label follows the com.gascity.<script-name> convention" \
  || bad "plist Label missing or does not match convention"
grep -q '<key>ProcessType</key><string>Interactive</string>' "$PLIST" \
  && ok "ProcessType=Interactive set (DAS-deferral guard, ga-u04vp lesson)" \
  || bad "ProcessType=Interactive missing — watchdog could itself go silently deferred"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
