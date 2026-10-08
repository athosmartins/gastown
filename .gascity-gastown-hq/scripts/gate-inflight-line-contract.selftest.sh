#!/usr/bin/env bash
# Contract selftest — ga-49l8kr. The dispatcher's Phase C "still in flight" poll line and the
# two log readers that parse it (PHASE_C_INFLIGHT_RE in pipeline-throughput-heartbeat.py,
# STUCK_INFLIGHT_RE in gate-recovery-watchdog.py) must agree on its shape.
#
# BUG: ga-ufskhy (c629152fc, 07/10 16:43) appended ", anchor=<src>+<N>s" inside the closing
# parenthesis of that line. Both readers ended their pattern in `s\)`, so from that minute on
# neither matched: the heartbeat's "review in progress" guard went dead (false "Pipeline parado
# (gate-merge)") and the watchdog's "marker stuck dispatching" arm went silent. Every selftest
# stayed green because their fixtures hand-wrote the OLD line — a copy of the format, not the format.
#
# This test does not copy the format: it lifts the producer's own `log "Phase C: ... still in
# flight ..."` line out of quality-gate-dispatcher.sh, renders it in bash for each anchor shape
# the dispatcher can emit, and feeds the RENDERED text to both readers' regexes. The next change
# to the line fails here, in CI, instead of in production.
#
# Run: bash scripts/gate-inflight-line-contract.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISP="${DISP_OVERRIDE:-$SELF_DIR/../packs/town-deltas/assets/quality-gate-dispatcher.sh}"
HB="${HB_OVERRIDE:-$SELF_DIR/pipeline-throughput-heartbeat.py}"
WD="${WD_OVERRIDE:-$SELF_DIR/gate-recovery-watchdog.py}"
for f in "$DISP" "$HB" "$WD"; do [ -f "$f" ] || { echo "FATAL: not found: $f"; exit 1; }; done

# The producer's emitting statement, verbatim. Exactly one is expected: zero means the line moved
# or was reworded (this test must be updated with it), two means a second producer shape exists
# that the readers have never been checked against.
EMIT=$(grep -E '^[[:space:]]*log "Phase C: gate-run \$GATE_RUN_ID \(branch=\$BRANCH\) still in flight \(' "$DISP" || true)
N=$(printf '%s\n' "$EMIT" | grep -c . || true)
if [ "$N" -ne 1 ]; then
  echo "FATAL: expected exactly 1 Phase C 'still in flight' emitting line in $DISP, found $N"
  exit 2
fi

# Render the real statement under controlled variables. `log` is stubbed to print its argument;
# the dispatcher's own `[ts] [quality-gate-dispatcher] ` prefix is added by its real log(), so
# the same prefix shape is added here.
render() {  # $1=anchor_src $2=anchor_offset(or "-" for unset) $3=got $4=need $5=elapsed $6=timeout
  (
    log() { printf '[2026-10-08 04:31:22] [quality-gate-dispatcher] %s\n' "$*"; }
    GATE_RUN_ID="ga-testrun"; BRANCH="crew/x/wa-1"
    VERDICTS_RECEIVED="$3"; REQUIRED_REVIEWERS="$4"; PC_ELAPSED="$5"; PC_TIMEOUT_SECS="$6"
    PC_ANCHOR_SRC="$1"
    if [ "$2" = "-" ]; then unset PC_ANCHOR_OFFSET; else PC_ANCHOR_OFFSET="$2"; fi
    eval "$EMIT"
  )
}

# Shapes the dispatcher really emits (gate_phase_c_anchor): task-sent with an offset, created with
# offset 0 (rendered "created+0s" in the live log), and the defensive default when neither
# variable is set (bare "anchor=created"). Plus a no-offset task-sent for good measure.
LINES=$(
  render task-sent 52 0 1 727 2460
  render task-sent 74 1 2 1901 2580
  render created   0  0 1 206 1860
  render created   9  0 2 707 1980
  render ""        -  0 1 120 1560
  render task-sent -  0 1 300 2100
)

python3 -I - "$HB" "$WD" "$LINES" <<'PY'
import importlib.util, sys

HB_PATH, WD_PATH, RENDERED = sys.argv[1], sys.argv[2], sys.argv[3]   # read before load() rewrites argv

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.argv = [name]            # __name__ != "__main__" → main() never runs
    spec.loader.exec_module(mod)
    return mod

hb = load("hb", HB_PATH)
wd = load("wd", WD_PATH)
rendered = [l for l in RENDERED.split("\n") if l.strip()]

PASS = FAIL = 0
def ok(msg):
    global PASS; PASS += 1; print("  ok: %s" % msg)
def bad(msg):
    global FAIL; FAIL += 1; print("  BAD: %s" % msg)

if len(rendered) != 6:
    bad("harness: expected 6 rendered lines, got %d — the producer statement did not render" % len(rendered))

# Each tuple: (got, need, elapsed, timeout) in the order render() was called above.
EXPECT = [(0, 1, 727, 2460), (1, 2, 1901, 2580), (0, 1, 206, 1860), (0, 2, 707, 1980),
          (0, 1, 120, 1560), (0, 1, 300, 2100)]

for line, (got, need, elapsed, timeout) in zip(rendered, EXPECT):
    tag = line.split("still in flight ", 1)[-1][:70]
    m = hb.PHASE_C_INFLIGHT_RE.search(line)
    if m and (int(m.group(1)), int(m.group(2))) == (elapsed, timeout):
        ok("heartbeat PHASE_C_INFLIGHT_RE reads the real line → (%ds/%ds)  «%s»" % (elapsed, timeout, tag))
    else:
        bad("heartbeat PHASE_C_INFLIGHT_RE does NOT read the producer's line (match=%r, want %ds/%ds)  «%s»" % (m and m.groups(), elapsed, timeout, tag))
    m = wd.STUCK_INFLIGHT_RE.search(line)
    if m and (int(m.group(1)), int(m.group(2))) == (got, elapsed):
        ok("watchdog STUCK_INFLIGHT_RE reads the real line → got=%d elapsed=%ds  «%s»" % (got, elapsed, tag))
    else:
        bad("watchdog STUCK_INFLIGHT_RE does NOT read the producer's line (match=%r, want got=%d elapsed=%d)  «%s»" % (m and m.groups(), got, elapsed, tag))

# History: the log still holds ~14k lines in the pre-ga-ufskhy shape, and a reader that only
# understood the new one would silently drop them. Both shapes must keep working.
OLD = "[2026-10-07 16:26:47] [quality-gate-dispatcher] Phase C: gate-run ga-old (branch=b) still in flight (0/1 verdicts, 207s/2100s) — leaving for a future sweep."
m = hb.PHASE_C_INFLIGHT_RE.search(OLD)
(ok if m and m.groups() == ("207", "2100") else bad)("heartbeat still reads the pre-anchor line")
m = wd.STUCK_INFLIGHT_RE.search(OLD)
(ok if m and m.groups() == ("0", "207") else bad)("watchdog still reads the pre-anchor line")

# Not the same thing: a Phase C line that is NOT the in-flight poll must not match.
DONE = "[2026-10-07 11:06:27] [quality-gate-dispatcher] Phase C: gate-run ga-x (branch=b) complete — 1/1 verdicts, overall=PASS (elapsed 723s). Finalizing."
(ok if not hb.PHASE_C_INFLIGHT_RE.search(DONE) else bad)("heartbeat ignores the 'complete' line")
(ok if not wd.STUCK_INFLIGHT_RE.search(DONE) else bad)("watchdog ignores the 'complete' line")

print("PASS=%d FAIL=%d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
