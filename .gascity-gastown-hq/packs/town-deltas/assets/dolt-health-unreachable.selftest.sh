#!/usr/bin/env bash
# dolt-health-unreachable.selftest.sh — ga-epf9hn.
#
# BUG: `gc dolt health --json` ALWAYS exits 0 and starts server.latency_ms at 0 / server.reachable
# at false, overwriting them only after its bounded SELECT 1 answers (packs/dolt/commands/health/
# run.sh L115-116, L161-165, L663-664). A Dolt that is down — or whose TCP is up while SQL is
# wedged — therefore prints {"reachable":false,"latency_ms":0}. A reader that decides on
# .server.latency_ms alone reads that as "latency zero = healthy":
#   - Pilot _dolt_probe → _dolt_saturated treats a PRESENT latency as the AUTHORITY, so 0 decides
#     "healthy" and the Pilot keeps dispatching to a wedged Dolt (the incident ga-hzt7 guards).
#   - gate headroom (HR_LAT) → the decision does not change (fail-open admits on 0 and on empty),
#     but the log says lat=0ms instead of "?" and pool_ceiling_dolt_class gets 0 ("ok") instead of
#     empty ("unknown"), so the dynamic ceiling can GROW with Dolt down.
#
# This test runs the LIVE code — functions/lines extracted from the real scripts, not copies — against
# the payload shapes `gc dolt health --json` really prints (same shapes as the shim in
# gate-spawn-transient-retry.selftest.sh, which models gate_dolt_ready_verdict, fixed in ga-9e446u).
# It must FAIL on the pre-fix scripts and pass after.
#
# Not covered on purpose: auto-refino-dispatcher.sh _ar_dolt_hot reads the same field but is
# fail-OPEN: latency 0 and latency empty both mean "not hot", so no input changes its output —
# there is no failing test to write, and the iron law of TDD forbids an edit without one.
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# DHU_PILOT / DHU_GATE point the test at another copy of the scripts — used to prove it FAILS on the
# pre-fix ones (`git show <base>:<path> > copy`); unset, it tests the scripts next to it.
PILOT="${DHU_PILOT:-$SELF_DIR/pilot-dispatcher.sh}"
GATE="${DHU_GATE:-$SELF_DIR/quality-gate-dispatcher.sh}"
POOLCEIL="$SELF_DIR/pool-ceiling.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got [$2], want [$3]"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dolt-health-unreachable.XXXXXX")"
sleep 600 & LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT   # LIVE_PID: a real, idle (≈0% cpu) process the payloads can name as dolt's pid

# The shim `gc`: prints what `gc dolt health --json` REALLY prints for each state of the server.
SHIM="$WORK/bin"; mkdir -p "$SHIM"
cat > "$SHIM/gc" <<'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"dolt health"*)
    case "${FAKE_HEALTH:-}" in
      up)       printf '{"server":{"running":true,"reachable":true,"pid":%s,"port":52756,"latency_ms":120}}' "$FAKE_PID" ;;
      hot)      printf '{"server":{"running":true,"reachable":true,"pid":%s,"port":52756,"latency_ms":9000}}' "$FAKE_PID" ;;
      down)     printf '{"server":{"running":false,"reachable":false,"pid":0,"port":52756,"latency_ms":0}}' ;;
      hung)     printf '{"server":{"running":true,"reachable":false,"pid":%s,"port":52756,"latency_ms":0}}' "$FAKE_PID" ;;
      hungnolat) printf '{"server":{"running":true,"reachable":false,"pid":%s,"port":52756}}' "$FAKE_PID" ;;
      nofield)  printf '{"server":{"running":true,"pid":%s,"port":52756,"latency_ms":120}}' "$FAKE_PID" ;;
      strtrue)  printf '{"server":{"running":true,"reachable":"true","pid":%s,"port":52756,"latency_ms":120}}' "$FAKE_PID" ;;
      junk)     printf 'not json at all' ;;
      refused)  echo "dial tcp 127.0.0.1:52756: connect: connection refused" >&2; exit 1 ;;
      *)        echo "shim: unknown FAKE_HEALTH='${FAKE_HEALTH:-}'" >&2; exit 97 ;;
    esac ;;
esac
exit 0
SHIMEOF
chmod +x "$SHIM/gc"

# Shim self-check: a blank/unreadable expectation below must come from the CODE UNDER TEST, never from a typo'd payload
# name or a broken shim (both would also read as "blank"). Every JSON payload parses and names a server; junk does not
# parse; refused fails with the connection error; an unknown name fails with the shim's own exit code (97).
for _n in up hot down hung hungnolat nofield strtrue; do
  FAKE_HEALTH="$_n" FAKE_PID="$LIVE_PID" "$SHIM/gc" dolt health --json 2>/dev/null | jq -e '.server | type == "object"' >/dev/null 2>&1 \
    || { echo "FATAL: shim payload '$_n' is not a JSON object with a server — the test would be vacuous"; exit 1; }
done
FAKE_HEALTH=junk "$SHIM/gc" dolt health --json 2>/dev/null | jq -e . >/dev/null 2>&1 && { echo "FATAL: shim payload 'junk' parses as JSON"; exit 1; }
FAKE_HEALTH=refused "$SHIM/gc" dolt health --json >/dev/null 2>&1; [ "$?" -eq 1 ] || { echo "FATAL: shim payload 'refused' does not exit 1"; exit 1; }
FAKE_HEALTH=no-such-payload "$SHIM/gc" dolt health --json >/dev/null 2>&1; [ "$?" -eq 97 ] || { echo "FATAL: shim does not reject an unknown payload name"; exit 1; }

# extract <file> <function-name> — the live function body, top-level definition to its closing brace.
extract() { awk -v n="$2" '$0 ~ "^"n"\\(\\) \\{" {c=1} c{print} c&&/^}$/{exit}' "$1"; }

# ── Pilot: the REAL _dolt_probe → _dolt_saturated chain ───────────────────────
PILOT_FNS="$(extract "$PILOT" gc_json_or_unknown; extract "$PILOT" _dolt_probe; extract "$PILOT" _dolt_cpu; extract "$PILOT" _dolt_saturated)"
if [ -z "$(extract "$PILOT" _dolt_probe)" ] || [ -z "$(extract "$PILOT" _dolt_saturated)" ] || [ -z "$(extract "$PILOT" gc_json_or_unknown)" ]; then
  echo "FATAL: could not extract _dolt_probe/_dolt_saturated/gc_json_or_unknown from $PILOT"; exit 1
fi
run_pilot() { # $1 = payload name → "LAT=[..] PID=[..] REASON=[..]"
  env -i PATH="$SHIM:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" FAKE_HEALTH="$1" FAKE_PID="$LIVE_PID" GC_CITY="$WORK/city" \
    PILOT_DOLT_LATENCY_MAX_MS=2500 PILOT_DOLT_CPU_MAX=200 PILOT_DOLT_LATENCY_OVERRIDE_MS= PILOT_DOLT_CPU_OVERRIDE= \
    bash -c "warn() { :; }; log() { :; }"$'\n'"$PILOT_FNS"$'\n''DOLT_LATENCY_MS=""; DOLT_PID=""; DOLT_SAT_REASON=""; _dolt_probe; _dolt_saturated >/dev/null; printf "LAT=[%s] PID=[%s] REASON=[%s]" "$DOLT_LATENCY_MS" "$DOLT_PID" "$DOLT_SAT_REASON"'
}

echo "Pilot _dolt_probe/_dolt_saturated — a Dolt that did not ANSWER is never 'latency 0 = healthy'"
eq "(p1) reachable Dolt keeps its measured latency and pid → healthy"            "$(run_pilot up)"        "LAT=[120] PID=[$LIVE_PID] REASON=[healthy]"
eq "(p2) reachable but slow Dolt is still caught by the latency ceiling"          "$(run_pilot hot)"       "LAT=[9000] PID=[$LIVE_PID] REASON=[latency]"
eq "(p3) the REAL down payload (running:false reachable:false latency_ms:0) → unreadable, NOT healthy" "$(run_pilot down)" "LAT=[] PID=[] REASON=[unreadable]"
eq "(p4) TCP up but SQL wedged (running:true reachable:false latency_ms:0, live pid) → unreadable, NOT healthy" "$(run_pilot hung)" "LAT=[] PID=[] REASON=[unreadable]"
# The pid must go too: with a live pid the CPU fallback reads an idle-looking process and says "healthy".
eq "(p5) wedged with NO latency key but a live pid → unreadable, NOT 'healthy' via the CPU fallback" "$(run_pilot hungnolat)" "LAT=[] PID=[] REASON=[unreadable]"
eq "(p6) payload with no reachable key (latency 120, live pid) → unreadable, never healthy" "$(run_pilot nofield)" "LAT=[] PID=[] REASON=[unreadable]"
eq "(p7) reachable as the STRING \"true\" is not the boolean true → unreadable"    "$(run_pilot strtrue)"   "LAT=[] PID=[] REASON=[unreadable]"
eq "(p8) non-JSON output stays unreadable (unchanged)"                            "$(run_pilot junk)"      "LAT=[] PID=[] REASON=[unreadable]"
eq "(p9) a failing command stays unreadable (unchanged)"                          "$(run_pilot refused)"   "LAT=[] PID=[] REASON=[unreadable]"

# ── Gate headroom: the REAL inline HR_H/HR_LAT/HR_PID read ────────────────────
GATE_JSC="$(extract "$GATE" gc_json_or_unknown)"
GATE_HR="$(sed -n '/^    HR_H=\$(GC_CITY=/,/^    HR_PID=/p' "$GATE")"
if [ -z "$GATE_JSC" ] || [ -z "$GATE_HR" ]; then
  echo "FATAL: could not extract gc_json_or_unknown / the HR_H..HR_PID read from $GATE"; exit 1
fi
run_gate() { # $1 = payload name → "LAT=[..]"
  env -i PATH="$SHIM:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" FAKE_HEALTH="$1" FAKE_PID="$LIVE_PID" GC_CITY="$WORK/city" \
    bash -c "warn() { :; }; log() { :; }"$'\n'"$GATE_JSC"$'\n'"$GATE_HR"$'\n''printf "LAT=[%s]" "$HR_LAT"'
}
ceiling_class() { # $1 = HR_LAT as the gate would pass it; cpu is empty (no ambient reading) → ok | hot | unknown
  bash -c 'source "$1"; pool_ceiling_dolt_class "" "$2" 180 2500' _ "$POOLCEIL" "$1"
}

echo "Gate headroom HR_LAT — an unanswered probe reads as '?' (unknown), never 0ms (ok)"
eq "(g1) reachable Dolt keeps its measured latency"                               "$(run_gate up)"        "LAT=[120]"
eq "(g2) reachable but slow Dolt keeps its (hot) latency"                         "$(run_gate hot)"       "LAT=[9000]"
eq "(g3) the REAL down payload → latency blank, not 0"                            "$(run_gate down)"      "LAT=[]"
eq "(g4) TCP up but SQL wedged → latency blank, not 0"                            "$(run_gate hung)"      "LAT=[]"
eq "(g5) payload with no reachable key → latency blank, never a number"           "$(run_gate nofield)"   "LAT=[]"
eq "(g6) reachable as the STRING \"true\" → latency blank"                        "$(run_gate strtrue)"   "LAT=[]"
eq "(g7) non-JSON output stays blank (unchanged)"                                 "$(run_gate junk)"      "LAT=[]"
# What the blank buys: the dynamic ceiling classes the Dolt as unknown (does not grow), not ok.
LAT_DOWN="$(run_gate down | sed -n 's/^LAT=\[\(.*\)\]$/\1/p')"
eq "(g8) the ceiling classes a down Dolt as unknown, NOT ok"                      "$(ceiling_class "$LAT_DOWN")" "unknown"
LAT_UP="$(run_gate up | sed -n 's/^LAT=\[\(.*\)\]$/\1/p')"
eq "(g9) the ceiling still classes a reachable Dolt as ok"                        "$(ceiling_class "$LAT_UP")"   "ok"
LAT_HOT="$(run_gate hot | sed -n 's/^LAT=\[\(.*\)\]$/\1/p')"
eq "(g10) the ceiling still classes a reachable slow Dolt as hot"                 "$(ceiling_class "$LAT_HOT")"  "hot"

# What the blank does to the admit/defer decision itself (the REAL gate_headroom_decision, fed the REAL read).
# Default fail-open: same verdict and ceiling as before, but the reason is honest — no-signal, not "calm".
# Fail-closed (GATE_HEADROOM_FAILOPEN=0): a down Dolt used to read "calm" and admit; now it defers.
GATE_DECIDE_FN="$(extract "$GATE" gate_headroom_decision)"
[ -n "$GATE_DECIDE_FN" ] || { echo "FATAL: could not extract gate_headroom_decision from $GATE"; exit 1; }
decide() { # $1 = HR_LAT, $2 = failopen → "<verdict> <ceiling> <reason>"; cpu empty, no quota limit, nothing in flight
  bash -c "$GATE_DECIDE_FN"$'\n''gate_headroom_decision "" "$1" 0 0 180 100 2500 6 3 "$2"' _ "$1" "$2"
}
eq "(g11) fail-open, down Dolt: still admits at the max ceiling, but says no-signal — not dolt-calm" "$(decide "$LAT_DOWN" 1)" "admit 6 no-signal-failopen"
eq "(g12) fail-CLOSED, down Dolt: defers (it used to read 'calm' and admit)"        "$(decide "$LAT_DOWN" 0)" "defer 0 no-signal-failclosed"
eq "(g13) reachable Dolt, fail-closed: unchanged — calm, admits"                   "$(decide "$LAT_UP" 0)"   "admit 6 dolt-calm"
eq "(g14) reachable slow Dolt: unchanged — hot floor of one run with nothing in flight" "$(decide "$LAT_HOT" 1)" "admit 3 dolt-hot-floor"

# ── Acceptance (c): no selftest mocks `gc dolt health` in the old shape (no `reachable`) ──
echo "No mock of the health payload in the old shape (server{...latency_ms} without reachable)"
# Filter on the line's CONTENT, never on grep's "path:line:" prefix — the path itself can contain the word
# "reachable" (this very worktree's name does), which silently emptied the first version of this check.
SCAN_FILES=("$SELF_DIR"/*.selftest.sh "$SELF_DIR"/../../../scripts/*.selftest.sh)
OLD_SHAPE="$(awk '/"server" *: *[{][^}]*latency_ms/ && !/reachable/ && !/nofield/ && FILENAME !~ /dolt-health-unreachable[.]selftest[.]sh$/ { print FILENAME ":" FNR ": " $0 }' "${SCAN_FILES[@]}" 2>/dev/null)"
# "Found none" must not be confusable with "could not look": a scan that read nothing would also find nothing.
# Positive control — the scan has to SEE the mocks it is meant to vouch for (the shapes with reachable, e.g. in
# gate-spawn-transient-retry.selftest.sh), over a sane number of files.
SEEN_MOCKS="$(awk '/"server" *: *[{][^}]*latency_ms/ && FILENAME !~ /dolt-health-unreachable[.]selftest[.]sh$/ { n++ } END { print n+0 }' "${SCAN_FILES[@]}" 2>/dev/null)"
case "$SEEN_MOCKS" in ''|*[!0-9]*) SEEN_MOCKS=0 ;; esac
if [ "${#SCAN_FILES[@]}" -lt 20 ] || [ "$SEEN_MOCKS" -lt 3 ]; then
  bad "(c0) the scan could not see what it is meant to check: ${#SCAN_FILES[@]} files, $SEEN_MOCKS health-payload mocks (expected >=20 files, >=3 mocks) — (c1) below proves nothing"
else
  ok "(c0) the scan saw $SEEN_MOCKS health-payload mocks across ${#SCAN_FILES[@]} selftest files"
fi
if [ -z "$OLD_SHAPE" ]; then ok "(c1) every health-payload mock carries reachable (the deliberate 'nofield' negative case aside)"
else bad "(c1) mocks in the old shape — a reader that now requires reachable would read them as unreadable:"; echo "$OLD_SHAPE" | sed 's/^/      /'; fi

echo
echo "dolt-health-unreachable.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
