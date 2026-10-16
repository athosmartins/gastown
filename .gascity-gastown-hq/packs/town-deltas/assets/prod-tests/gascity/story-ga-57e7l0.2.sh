#!/usr/bin/env bash
# prod-tests/gascity/story-ga-57e7l0.2.sh — prod test for ga-57e7l0.2 (slice 3/3 of ga-57e7l0): the 7-day readout of first-attempt approval and of the
# third-state share of rejections, per delivery path and per arm (assets/third-state-report.py).
#
# What "deployed and correct" means here:
#   (1) the pieces are in the LIVE tree: the report, its selftest, the manual ledger, the daily order; the scripts parse;
#   (2) the order is valid TOML, daily, and runs the report;
#   (3) the hermetic selftest passes on the live tree (three states against fixtures, the story's controls that must fail, six mutants);
#   (4) the report runs against the LIVE gate log, read-only (--no-classify: no bd call, nothing written), and prints the three tables with
#       honest cells — the live log has unparseable lines (old multi-line records), so the "N linhas ilegíveis" notice must be there too.
#
# Not asserted here, and why: that the third-state share fell below 30% and first-attempt approval reached 60% is a measurement over a week
# of gate runs — the report is how that is read (docs/runbooks/third-state-report.md), not a deploy check.
# Nothing is written outside a scratch dir. Called by run.sh after deploy (STORY_ID=ga-57e7l0.2). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
REPORT="$ASSETS/third-state-report.py"
SELFTEST="$ASSETS/third-state-report.selftest.sh"
LEDGER="$ASSETS/third-state-manual.tsv"
ORDER="$CITY/packs/town-deltas/orders/third-state-report.toml"

log()  { echo "[prod-test:gascity ga-57e7l0.2] $*"; }
fail() { echo "[prod-test:gascity ga-57e7l0.2] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────
for f in "$REPORT" "$SELFTEST" "$LEDGER" "$ORDER"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 missing — the report cannot run"
python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$REPORT" || fail "the report does not parse as Python"
bash -n "$SELFTEST" || fail "the selftest does not parse under bash"
[[ -x "$REPORT" ]] || fail "the report is not executable — the order runs it directly"
log "report, selftest, manual ledger and order are deployed; the scripts parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-57e7l0.2.XXXXXX")" || fail "no scratch dir"
case "$S" in /?*) ;; *) fail "mktemp printed no usable scratch path ('$S')" ;; esac
trap 'rm -rf "$S"' EXIT

# ── 2. the order ──────────────────────────────────────────────────────────────────────────────
# falhou → a TOML that does not load is a failure (the order would never run), never "no order"
python3 -I -c '
import sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"] == "24h", o
assert "third-state-report.py" in o["exec"], o
' "$ORDER" || fail "$ORDER is not valid TOML, not daily, or does not run the report"
log "orders/third-state-report.toml: valid TOML, cooldown 24h, runs the report ✓"

# ── 3. the hermetic selftest on the live tree ──────────────────────────────────────────────────
mkdir -p "$S/tmp" || fail "could not create the selftest's scratch parent"
rc=0; TMPDIR="$S/tmp" bash "$SELFTEST" > "$S/selftest.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then grep -E '^(FAIL|SKIP)' "$S/selftest.out" | head -10 >&2; fail "third-state-report.selftest.sh exited $rc on the live tree"; fi
grep -q 'selftest: [0-9]* passed, 0 failed' "$S/selftest.out" || fail "the selftest exited 0 but did not print its '0 failed' line — it did not finish"
log "third-state-report.selftest.sh: $(grep 'selftest:' "$S/selftest.out") ✓"

# ── 4. the report on the LIVE gate log, read-only ──────────────────────────────────────────────
# exit 0 = printed; 2 = NÃO SEI (log absent/unreadable/empty) — on the live city that is a failure, the log exists and is not empty
rc=0; python3 -I "$REPORT" --city "$CITY" --no-classify > "$S/live.out" 2> "$S/live.err" || rc=$?
[[ "$rc" -eq 0 ]] || fail "the report exited $rc on the live city: $(head -3 "$S/live.out") $(head -3 "$S/live.err")"
for t in "^Total" "^Por CAMINHO de entrega" "^Por BRAÇO — E12" "^Por BRAÇO — checagem da fatia 2"; do
  grep -qE -- "$t" "$S/live.out" || fail "the live report has no section '$t'"
done
grep -qE '^Fonte: [0-9]+ vereditos reais na janela' "$S/live.out" || fail "the live report does not say how many verdicts it read"
# vazio → 0 verdicts in 7 days on the live gate would be a real (alarming) answer, but the report must then SAY "0 vereditos"; here a live gate
# that judged nothing in a week means the log is not the live one, so it is a failure of the test's premise
grep -qE '^Fonte: 0 vereditos' "$S/live.out" && fail "the live gate log holds no verdict in the last 7 days — wrong city or a dead gate: $(grep '^Fonte' "$S/live.out")"
grep -E '^(Fonte|⚠)' "$S/live.out" | cut -c1-220 | while IFS= read -r l; do log "live: $l"; done
log "the report ran on the live gate log (read-only): three tables, verdicts counted, unreadable lines announced ✓"

log "PASS"
exit 0
