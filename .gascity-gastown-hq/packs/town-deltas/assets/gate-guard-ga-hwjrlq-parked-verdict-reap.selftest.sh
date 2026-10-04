#!/usr/bin/env bash
# gate-guard-ga-hwjrlq-parked-verdict-reap.selftest.sh — proves the ga-hwjrlq fix:
# quality-gate-guard.sh Step 0b.3 closes a verdict bead the dispatcher already parked
# (verdict:REQUEUED / verdict:TIMEOUT) whose `bd close` was lost, once its parent
# gate-run is terminal or gone — so agent-stuck-escalation stops paging the Mayor about it.
#
# INCIDENT (2026-10-04): ga-7dh3v1, ga-pvp2n8, ga-o1vj01 — verdict beads left in_progress
# on dead reviewer sessions, label verdict:REQUEUED, every parent gate-run closed +
# gate-status:superseded. Step 0b.1/0b.2 select verdict:pending and never saw them.
#
# Layers:
#   1. The LIVE block, extracted verbatim from the guard between its SELFTEST-EXTRACT
#      sentinels and run under /bin/bash 3.2 (what launchd runs) with `set -euo pipefail`,
#      against a mock `bd`. Each scenario states what it would have caught: the reap itself,
#      and the shapes that abort or mis-close a sweep (no gate-run label under pipefail, a
#      failing close, an unreadable parent, a still-active parent).
#   2. Drift guards on the guard file (sentinels, the query's exact flags).
#
# The pure decision functions are covered in quality-gate-guard.selftest.sh.
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GUARD_UNDER_TEST:-$SELF_DIR/quality-gate-guard.sh}"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
[ -x /bin/bash ] || { echo "FATAL: no /bin/bash"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gc-hwjrlq-selftest-XXXXXX")"
trap 'rm -rf "$TMPD" 2>/dev/null || true' EXIT

echo "── 1. extract the live Step 0b.3 block ──"
BEGIN_COUNT=$(grep -c '^# SELFTEST-EXTRACT parked-verdict-reap: BEGIN$' "$GUARD" || true)
END_COUNT=$(grep -c '^# SELFTEST-EXTRACT parked-verdict-reap: END$' "$GUARD" || true)
eq "guard.sh: parked-verdict-reap sentinels present exactly once each" "$BEGIN_COUNT/$END_COUNT" "1/1"

BLOCK="$TMPD/block.sh"
sed -n '/^# SELFTEST-EXTRACT parked-verdict-reap: BEGIN$/,/^# SELFTEST-EXTRACT parked-verdict-reap: END$/p' "$GUARD" | sed '1d;$d' > "$BLOCK"
if [ -s "$BLOCK" ] && /bin/bash -n "$BLOCK" 2>/dev/null; then
  ok "extracted block is non-empty and parses under /bin/bash 3.2"
else
  bad "FATAL: extracted block missing or does not parse under /bin/bash — nothing below can run"
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

NOW=1791143706   # 2026-10-04T19:55:06Z, any fixed instant works
ts_ago() { date -u -r $(( NOW - $1 * 60 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( NOW - $1 * 60 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# The driver: sources the guard lib-only (pure functions + age_minutes_of), stubs log/warn and a
# `bd` that serves fixtures from $FIX and records every call, then runs the extracted block.
DRIVER="$TMPD/driver.sh"
cat > "$DRIVER" <<'DRV'
set -euo pipefail
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set -euo pipefail
log()  { echo "LOG: $*"; }
warn() { echo "WARN: $*"; }
GC_CITY=/nonexistent-city
NOW_EPOCH="$NOW"
bd() {
  if [ "$1" = "-C" ]; then shift 2; fi
  sub="$1"; shift
  echo "bd $sub $*" >> "$FIX/calls.log"
  case "$sub" in
    list)
      cat "$FIX/list.json"
      return "$(cat "$FIX/list.rc" 2>/dev/null || echo 0)"
      ;;
    show)
      id="$1"
      if [ -f "$FIX/show.$id" ]; then
        cat "$FIX/show.$id"
        return "$(cat "$FIX/show.$id.rc" 2>/dev/null || echo 0)"
      fi
      printf '{\n  "error": "no issues found matching the provided IDs",\n  "schema_version": 1\n}\n'
      return 1
      ;;
    close)
      echo "$1" >> "$FIX/closed.log"
      return "$(cat "$FIX/close.rc" 2>/dev/null || echo 0)"
      ;;
  esac
  return 0
}
. "$BLOCK"
echo "DRIVER-DONE"
DRV

# new_fix <name> -> creates $FIX dir with defaults
new_fix() { FIX="$TMPD/fix-$1"; mkdir -p "$FIX"; : > "$FIX/calls.log"; : > "$FIX/closed.log"; echo '[]' > "$FIX/list.json"; }
# vbead <id> <status> <verdict-label> <gate-run|-> <age-min>  -> a JSON object line
vbead() {
  local lab='["type:quality-gate-verdict","reviewer-index:1"'
  [ "$4" != "-" ] && lab="$lab,\"gate-run:$4\""
  lab="$lab,\"$3\"]"
  printf '{"id":"%s","status":"%s","assignee":"gate-reviewer-adhoc-dead","updated_at":"%s","labels":%s}' "$1" "$2" "$(ts_ago "$5")" "$lab"
}
run_block() {
  OUT="$TMPD/out.txt"
  env -i PATH="$PATH" HOME="$HOME" GUARD="$GUARD" BLOCK="$BLOCK" FIX="$FIX" NOW="$NOW" /bin/bash "$DRIVER" > "$OUT" 2>&1
  RC=$?
  CLOSED=$(tr '\n' ' ' < "$FIX/closed.log" | sed 's/ $//')
}
done_ok() { grep -q '^DRIVER-DONE$' "$OUT" && echo yes || echo no; }

echo "── 2. scenarios (live block, /bin/bash 3.2, set -euo pipefail, mock bd) ──"

# A. The three real beads: in_progress + verdict:REQUEUED, parents closed+superseded, 60m old.
new_fix A
printf '[%s,%s,%s]' \
  "$(vbead ga-7dh3v1 in_progress verdict:REQUEUED ga-owow5q 60)" \
  "$(vbead ga-pvp2n8 in_progress verdict:REQUEUED ga-590axt 60)" \
  "$(vbead ga-o1vj01 in_progress verdict:REQUEUED ga-su5eyy 60)" > "$FIX/list.json"
for r in ga-owow5q ga-590axt ga-su5eyy; do
  echo "[{\"id\":\"$r\",\"status\":\"closed\",\"labels\":[\"gate-status:superseded\",\"type:quality-gate-run\"]}]" > "$FIX/show.$r"
done
run_block
eq "A. the 2026-10-04 population (REQUEUED, parent closed+superseded, 60m) → all three closed, sweep completes" "$CLOSED/$(done_ok)/$RC" "ga-7dh3v1 ga-pvp2n8 ga-o1vj01/yes/0"
grep -q 'WARN' "$OUT" && bad "A. no WARN expected on the happy path: $(grep WARN "$OUT" | head -1)" || ok "A. no WARN on the happy path"

# B. Same class, the other label the dispatcher parks with.
new_fix B
printf '[%s]' "$(vbead ga-tm1 in_progress verdict:TIMEOUT ga-runB 60)" > "$FIX/list.json"
echo '[{"id":"ga-runB","status":"closed","labels":["gate-status:superseded"]}]' > "$FIX/show.ga-runB"
run_block
eq "B. verdict:TIMEOUT, terminal parent → closed (same lost-close class, Phase C timeout path)" "$CLOSED/$(done_ok)" "ga-tm1/yes"

# C. Parent still running: closing would make Phase C read a received non-PASS verdict.
new_fix C
printf '[%s]' "$(vbead ga-act in_progress verdict:REQUEUED ga-runC 60)" > "$FIX/list.json"
echo '[{"id":"ga-runC","status":"open","labels":["gate-status:running"]}]' > "$FIX/show.ga-runC"
run_block
eq "C. parent gate-run still running → NOT closed (Phase C owns it)" "$CLOSED/$(done_ok)" "/yes"

# D. Parent unreadable (Dolt overload text, exit 1): never closed on a failed lookup, and visible.
new_fix D
printf '[%s]' "$(vbead ga-unk in_progress verdict:REQUEUED ga-runD 60)" > "$FIX/list.json"
echo 'Error 1105 (HY000): row read wait bigger than connection timeout' > "$FIX/show.ga-runD"; echo 1 > "$FIX/show.ga-runD.rc"
run_block
eq "D. parent lookup failed → NOT closed" "$CLOSED/$(done_ok)" "/yes"
grep -q 'WARN: ga-hwjrlq: parent gate-run ga-runD' "$OUT" && ok "D. the skip is a visible WARN, not silence" || bad "D. expected a WARN naming the unreadable parent; got: $(cat "$OUT" | head -5)"

# E. Parent confirmed gone (real not-found envelope, exit 1).
new_fix E
printf '[%s]' "$(vbead ga-gone in_progress verdict:REQUEUED ga-runE 60)" > "$FIX/list.json"
run_block
eq "E. parent confirmed gone (live not-found envelope) → closed" "$CLOSED/$(done_ok)" "ga-gone/yes"

# F. Young bead: the dispatcher's own label→close window.
new_fix F
printf '[%s]' "$(vbead ga-young in_progress verdict:REQUEUED ga-runF 5)" > "$FIX/list.json"
echo '[{"id":"ga-runF","status":"closed","labels":["gate-status:superseded"]}]' > "$FIX/show.ga-runF"
run_block
eq "F. 5m old (<= 15m grace) → NOT closed" "$CLOSED/$(done_ok)" "/yes"

# G. A bead with no gate-run label FIRST, a closeable one after: pipefail must not abort the sweep.
new_fix G
printf '[%s,%s]' \
  "$(vbead ga-nolabel in_progress verdict:REQUEUED - 60)" \
  "$(vbead ga-after in_progress verdict:REQUEUED ga-runG 60)" > "$FIX/list.json"
echo '[{"id":"ga-runG","status":"closed","labels":["gate-status:superseded"]}]' > "$FIX/show.ga-runG"
run_block
eq "G. no gate-run label (grep miss under pipefail) → sweep does NOT abort, the next bead is still closed" "$CLOSED/$(done_ok)/$RC" "ga-after/yes/0"
grep -q 'WARN: ga-hwjrlq: parked verdict ga-nolabel' "$OUT" && ok "G. the unlabeled bead is skipped with a WARN" || bad "G. expected a WARN for the unlabeled bead"

# G2. updated_at unparseable: age_minutes_of reads it as epoch 0 (~29M minutes old) — "can't read" must not read as "ancient".
new_fix G2
printf '[{"id":"ga-badts","status":"in_progress","assignee":null,"updated_at":"not-a-timestamp","labels":["type:quality-gate-verdict","gate-run:ga-runG2","verdict:REQUEUED"]},{"id":"ga-nots","status":"open","assignee":null,"labels":["type:quality-gate-verdict","gate-run:ga-runG2","verdict:TIMEOUT"]}]' > "$FIX/list.json"
echo '[{"id":"ga-runG2","status":"closed","labels":["gate-status:superseded"]}]' > "$FIX/show.ga-runG2"
run_block
eq "G2. unparseable / missing updated_at under a terminal parent → NOT closed (an unreadable age is not 'old')" "$CLOSED/$(done_ok)/$RC" "/yes/0"

# H. The list query itself fails: no closes, a WARN, the block completes.
new_fix H
echo 'Error 1105 (HY000): row read wait bigger than connection timeout' > "$FIX/list.json"; echo 1 > "$FIX/list.rc"
run_block
eq "H. list query failed → nothing closed, block completes (not a confirmed-empty result)" "$CLOSED/$(done_ok)/$RC" "/yes/0"
grep -q 'WARN: ga-hwjrlq: parked-verdict reap query FAILED' "$OUT" && ok "H. the failed query is a visible WARN" || bad "H. expected the query-FAILED WARN"

# I. close itself fails for the first bead: warn, keep going, the second still closes.
new_fix I
printf '[%s,%s]' \
  "$(vbead ga-c1 in_progress verdict:REQUEUED ga-runI 60)" \
  "$(vbead ga-c2 in_progress verdict:REQUEUED ga-runI 60)" > "$FIX/list.json"
echo '[{"id":"ga-runI","status":"closed","labels":["gate-status:superseded"]}]' > "$FIX/show.ga-runI"
echo 1 > "$FIX/close.rc"
run_block
eq "I. close attempts fail → both attempted, sweep completes under set -e" "$CLOSED/$(done_ok)/$RC" "ga-c1 ga-c2/yes/0"
grep -q 'WARN: ga-hwjrlq: close of parked verdict ga-c1 FAILED' "$OUT" && ok "I. a failed close is a visible WARN (no claim of success)" || bad "I. expected a close-FAILED WARN"
grep -q 'LOG: ga-hwjrlq: closed parked verdict' "$OUT" && bad "I. logged 'closed' although every close failed" || ok "I. never logs 'closed' when the close failed"

# J. Empty list and unparseable list.
new_fix J1
run_block
eq "J1. confirmed-empty list → nothing to do, block completes" "$CLOSED/$(done_ok)/$RC" "/yes/0"
new_fix J2
echo 'not json at all' > "$FIX/list.json"
run_block
eq "J2. unparseable list → nothing closed, block completes" "$CLOSED/$(done_ok)/$RC" "/yes/0"
grep -q 'WARN: ga-hwjrlq: parked-verdict reap query returned unparseable output' "$OUT" && ok "J2. unparseable output is a visible WARN (not read as an empty list)" || bad "J2. expected the unparseable WARN"
new_fix J3
echo '{"error":"database is locked"}' > "$FIX/list.json"
run_block
eq "J3. a JSON error envelope as the list result → nothing closed, block completes" "$CLOSED/$(done_ok)/$RC" "/yes/0"
grep -q 'WARN: ga-hwjrlq: parked-verdict reap query returned unparseable output' "$OUT" && ok "J3. an error envelope is a visible WARN, not an empty list" || bad "J3. expected the unparseable WARN for a non-array result"

# K. The query's exact flags (a --status flag would silently drop in_progress rows; no --limit 0 truncates at 50).
new_fix K
run_block
LISTCALL=$(grep '^bd list' "$FIX/calls.log" | head -1)
case "$LISTCALL" in *"--limit 0"*) ok "K. list call carries --limit 0 (ga-21kmp)" ;; *) bad "K. list call missing --limit 0: $LISTCALL" ;; esac
case "$LISTCALL" in *"-l type:quality-gate-verdict"*) ok "K. list call scopes to type:quality-gate-verdict" ;; *) bad "K. list call not scoped to verdict beads: $LISTCALL" ;; esac
case "$LISTCALL" in *"--label-any verdict:REQUEUED,verdict:TIMEOUT"*) ok "K. list call selects REQUEUED or TIMEOUT" ;; *) bad "K. list call labels wrong: $LISTCALL" ;; esac
case "$LISTCALL" in *"--status"*) bad "K. list call must NOT filter by --status (would drop in_progress rows): $LISTCALL" ;; *) ok "K. list call has no --status filter" ;; esac

echo "── 3. drift guard ──"
STEP_LINE=$(grep -n '^# ── Step 0b.3 (ga-hwjrlq)' "$GUARD" | head -1 | cut -d: -f1)
SIB_LINE=$(grep -n '^# ── Step 0b.2 (ga-qtc16)' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$STEP_LINE" ] && [ -n "$SIB_LINE" ] && [ "$STEP_LINE" -gt "$SIB_LINE" ]; then ok "Step 0b.3 sits after Step 0b.2 in the sweep"; else bad "Step 0b.3 ordering/presence wrong (0b.3=${STEP_LINE:-missing}, 0b.2=${SIB_LINE:-missing})"; fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
