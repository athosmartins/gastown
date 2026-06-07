#!/usr/bin/env bash
# gate-spawn-abort-escalation.selftest.sh — Prove the ga-piscg consecutive
# spawn-abort escalation logic in isolation, with NO live Dolt/gc/launchd/notify.
#
# Bug ga-piscg: the 2026-06-06 town-wide gate outage ran ~20h before a human
# noticed. The quality-gate-dispatcher aborted reviewer-spawn 7+ times
# ("Failed to spawn reviewer session 1. Aborting gate"), set gate-status:error
# EACH time, and moved on SILENTLY — it never paged anyone. The per-marker
# [GATE-ERROR] monitor (10min-stuck) could not catch it because each marker
# churned error→queued→error too fast to stay stuck.
#
# The fix (dispatcher side): the dispatcher processes exactly ONE queued marker
# per sweep, so a counter persisted across sweeps == consecutive spawn-aborts
# ACROSS markers. After K consecutive aborts it (a) ntfy 🚨 -p 5 to Athos and
# (b) mails the Mayor with the spawn_err — pages a human in MINUTES not hours.
# A successful spawn resets the counter + alert state.
#
# This harness unit-tests the PURE page/hold decision + the counter arithmetic
# the dispatcher uses, then DRIFT-GUARDS the real script so a future refactor
# that drops the escalation (ntfy/mail/threshold/counter/reset) fails loudly.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── The EXACT pure decision the dispatcher uses (mirror of spawn_abort_should_page).
# echo "page" iff count>=threshold AND past the re-alert cooldown, else "hold".
spawn_abort_should_page() {
  local count="$1" threshold="$2" now="$3" last="$4" realert="$5"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last"  in ''|*[!0-9]*) last=0  ;; esac
  if [ "$count" -lt "$threshold" ]; then echo "hold"; return 0; fi
  if [ "$((now - last))" -ge "$realert" ]; then echo "page"; else echo "hold"; fi
}

# ── The EXACT counter arithmetic (increment guarded against junk / set -e).
bump() { local c="$1"; case "$c" in ''|*[!0-9]*) c=0 ;; esac; echo "$((c + 1))"; }

T=3            # SPAWN_ABORT_THRESHOLD default
RA=1800        # SPAWN_ABORT_REALERT_SEC default
NOW=1000000

echo "── 1. counter increment is junk-proof + monotonic across sweeps ──"
eq "empty file → 1"        "$(bump '')"      "1"
eq "non-numeric → 1"       "$(bump 'xyz')"   "1"
eq "1 → 2"                 "$(bump 1)"       "2"
eq "2 → 3"                 "$(bump 2)"       "3"
# Simulate the real 7+ abort outage accumulating across sweeps from scratch.
c=0; for _ in 1 2 3 4 5 6 7; do c="$(bump "$c")"; done
eq "7 sweeps of abort → count 7" "$c" "7"

echo "── 2. page/hold decision (threshold=$T) ──"
eq "1 abort → hold (below threshold)"  "$(spawn_abort_should_page 1 $T $NOW 0 $RA)"            "hold"
eq "2 aborts → hold (below threshold)" "$(spawn_abort_should_page 2 $T $NOW 0 $RA)"            "hold"
eq "3 aborts, never paged → PAGE"      "$(spawn_abort_should_page 3 $T $NOW 0 $RA)"            "page"
eq "7 aborts, never paged → PAGE"      "$(spawn_abort_should_page 7 $T $NOW 0 $RA)"            "page"
eq "junk count → hold (treated as 0)"  "$(spawn_abort_should_page 'x' $T $NOW 0 $RA)"          "hold"

echo "── 3. re-alert cooldown suppresses spam, then re-pages ──"
# Paged 60s ago, cooldown 1800s → still within cooldown → hold.
eq "paged 60s ago → hold (cooldown)"   "$(spawn_abort_should_page 5 $T $NOW $((NOW-60)) $RA)"   "hold"
# Paged exactly RA ago → boundary is inclusive (>=) → page.
eq "paged exactly RA ago → PAGE"       "$(spawn_abort_should_page 5 $T $NOW $((NOW-RA)) $RA)"   "page"
# Paged 2h ago (> RA) → re-page (outage still ongoing).
eq "paged 2h ago → PAGE (re-alert)"    "$(spawn_abort_should_page 5 $T $NOW $((NOW-7200)) $RA)" "page"

echo "── 4. full outage→recovery lifecycle (count + decision together) ──"
# Cold start, sweeps abort one by one; assert when the FIRST page fires.
c=0; first_page_at=0; sweep=0
for _ in 1 2 3 4 5; do
  sweep=$((sweep+1)); c="$(bump "$c")"
  if [ "$first_page_at" -eq 0 ] && [ "$(spawn_abort_should_page "$c" $T $NOW 0 $RA)" = "page" ]; then
    first_page_at=$sweep
  fi
done
eq "first page fires on sweep == threshold" "$first_page_at" "$T"
# Recovery: a successful spawn resets the counter to 0 (rm of the file).
c=0
eq "after reset, count is 0"                 "$c" "0"
eq "after reset, 1 fresh abort → hold"       "$(spawn_abort_should_page "$(bump "$c")" $T $NOW 0 $RA)" "hold"

echo "── 5. DRIFT-GUARD: the real dispatcher still carries the ga-piscg fix ──"
has "$GATE" 'spawn_abort_should_page'                       "pure page/hold decision present"
has "$GATE" 'SPAWN_ABORT_THRESHOLD'                         "consecutive-abort threshold configured"
has "$GATE" 'SPAWN_ABORT_COUNT_FILE'                        "persistent counter file wired"
has "$GATE" 'event:"spawn_abort"'                           "structured spawn_abort audit event emitted"
has "$GATE" 'notify .*-p 5'                                 "ntfy page at -p 5 (highest priority)"
has "$GATE" '🚨'                                            "ntfy carries the 🚨 outage marker"
has "$GATE" 'mail send mayor'                               "Mayor mailed on systemic outage"
has "$GATE" 'spawn_err'                                     "escalation carries the spawn_err"
has "$GATE" 'rm -f "\$SPAWN_ABORT_COUNT_FILE"'              "counter reset on successful spawn"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
