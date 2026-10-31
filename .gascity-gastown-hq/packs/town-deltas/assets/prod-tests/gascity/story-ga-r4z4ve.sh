#!/usr/bin/env bash
# prod-tests/gascity/story-ga-r4z4ve.sh — prod test for ga-r4z4ve: the third-state check (step 2e) was ON for six days with no effect, and nothing complained.
# The cause is fixed (ga-vywjzsp runs 2e from the guard); this story adds the watch: assets/third-state-arm-coverage.py + the hourly order of the same name.
#
# What "deployed and correct" means here:
#   (1) the pieces are in the LIVE tree and parse: the detector, its selftest, the order, and the three scripts it leans on (the check, the report, the router);
#   (2) the order is valid TOML, hourly, runs the detector with --order, and `gc order list` resolves it (CLI-side scan: proves the file parses, NOT that the
#       controller fired it — that is a NOTE below, the only proof is `gc order history` after >= 1h);
#   (3) the hermetic selftest passes on the live tree (answers, counting, the real guard line and the real check's rows, alarm mechanics, mutants);
#   (4) THE ACCEPTANCE, on the LIVE city, read-only: the detector reads the live gate log and the live arms file and finds every bead of the last 24h with a
#       real verdict covered. A divergence (exit 1) FAILS this test — that is the bug the bead is about; "could not tell" (exit 2) fails too. Not switched on,
#       mode warn/off, a recent kill switch and too few runs are NOTES, not failures: they are the Mayor's switches, not a defect of this change.
#
# Nothing is written outside a scratch dir (the detector runs with --no-alarm --no-lock). Called by run.sh after deploy (STORY_ID=ga-r4z4ve). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DET="$ASSETS/third-state-arm-coverage.py"
SELFTEST="$ASSETS/third-state-arm-coverage.selftest.sh"
ORDER="$CITY/packs/town-deltas/orders/third-state-arm-coverage.toml"

log()  { echo "[prod-test:gascity ga-r4z4ve] $*"; }
note() { echo "[prod-test:gascity ga-r4z4ve] NOTE: $*"; }
fail() { echo "[prod-test:gascity ga-r4z4ve] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────
for f in "$DET" "$SELFTEST" "$ORDER" "$ASSETS/third-state-reads-check.py" "$ASSETS/third-state-report.py" "$ASSETS/escalation-router.sh"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 missing — the detector cannot run"
for f in "$DET" "$ASSETS/third-state-reads-check.py" "$ASSETS/third-state-report.py"; do
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "$f" || fail "$f does not parse as Python"
done
bash -n "$SELFTEST" || fail "the selftest does not parse under bash"
[[ -x "$DET" ]] || fail "the detector is not executable — the order runs it directly"
log "detector, selftest, order and the scripts they lean on are deployed; the scripts parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-r4z4ve.XXXXXX")" || fail "no scratch dir"
case "$S" in /?*) ;; *) fail "mktemp printed no usable scratch path ('$S')" ;; esac
trap 'rm -rf "$S"' EXIT

# ── 2. the order ──────────────────────────────────────────────────────────────────────────────
# vazio → no python with tomllib at all: the order file is read as TEXT (same three facts), said in a NOTE; falhou → a TOML that does not load, or a wrong value, is a failure (the order would never run), never "no order"
PYT=""; for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  command -v "$c" >/dev/null 2>&1 && "$c" -I -c 'import tomllib' >/dev/null 2>&1 && { PYT="$(command -v "$c")"; break; }
done
if [[ -n "$PYT" ]]; then
  "$PYT" -I -c '
import sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"] == "1h", o
assert "third-state-arm-coverage.py --order" in o["exec"], o
' "$ORDER" || fail "$ORDER is not valid TOML, not hourly, or does not run the detector with --order"
  log "orders/third-state-arm-coverage.toml: valid TOML, cooldown 1h, runs the detector with --order ✓"
else
  note "no python with tomllib here — the order file is read as text, not parsed as TOML"
  grep -q '^trigger = "cooldown"$' "$ORDER" && grep -q '^interval = "1h"$' "$ORDER" && grep -q '^exec = ".*third-state-arm-coverage.py --order"$' "$ORDER" || fail "$ORDER is not hourly or does not run the detector with --order"
  log "orders/third-state-arm-coverage.toml: cooldown 1h, runs the detector with --order (text check) ✓"
fi
# vazio → gc lists no such order: the pack is not deployed or the file does not parse (failure); falhou (gc errors / times out) → cannot tell: failure too, never "not listed = fine"
rc=0; python3 -I -c '
import json, subprocess, sys
p = subprocess.run(["gc", "--city", sys.argv[1], "order", "list", "--json"], capture_output=True, timeout=120)
d = json.loads(p.stdout)
assert p.returncode == 0 and d.get("ok") is True, (p.returncode, p.stderr[:200])
assert any(o.get("name") == "third-state-arm-coverage" for o in d["orders"]), [o.get("name") for o in d["orders"]][:20]
' "$CITY" > "$S/orders.out" 2> "$S/orders.err" || rc=$?
[[ "$rc" -eq 0 ]] || fail "gc order list does not resolve third-state-arm-coverage (rc $rc): $(tail -2 "$S/orders.err")"
log "gc order list resolves the order ✓"
note "whether the controller has FIRED it is unproven until \`gc order history third-state-arm-coverage\` shows a run (>= 1h after deploy)"

# ── 3. the hermetic selftest on the live tree ─────────────────────────────────────────────────
mkdir -p "$S/tmp" || fail "could not create the selftest's scratch parent"
rc=0; TMPDIR="$S/tmp" bash "$SELFTEST" > "$S/selftest.out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then grep -E '^(  FAIL|FAIL|FATAL)' "$S/selftest.out" | head -10 >&2; fail "third-state-arm-coverage.selftest.sh exited $rc on the live tree"; fi
grep -q 'selftest: [0-9]* passed, 0 failed' "$S/selftest.out" || fail "the selftest exited 0 but did not print its '0 failed' line — it did not finish"
log "third-state-arm-coverage.selftest.sh: $(grep 'selftest:' "$S/selftest.out") ✓"

# ── 4. the acceptance, on the LIVE city, read-only ─────────────────────────────────────────────
rc=0; python3 -I "$DET" --city "$CITY" --no-alarm --no-lock --json > "$S/live.json" 2> "$S/live.err" || rc=$?
python3 -I "$DET" --city "$CITY" --no-alarm --no-lock > "$S/live.txt" 2>&1 || true
if [[ "$rc" -eq 2 ]]; then fail "the detector could not tell on the live city (NÃO SEI): $(head -6 "$S/live.txt" | tr '\n' '|' | cut -c1-500)"; fi
if [[ "$rc" -eq 1 ]]; then cat "$S/live.txt" >&2; fail "THE BUG THIS BEAD IS ABOUT: beads with a real gate verdict have no recorded third-state arm (or the conf is unreadable / a kill switch is forgotten) — read the report above"; fi
[[ "$rc" -eq 0 ]] || fail "the detector exited $rc on the live city: $(head -3 "$S/live.txt")"
verdict="$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["verdict"], d["runs"], d["covered"], len(d["uncovered"]))' "$S/live.json")" || fail "the detector's JSON on the live city is unreadable"
set -- $verdict
case "$1" in
  ok)            log "live: $2 bead(s) with a real verdict in the last 24h, $3 with a recorded arm, $4 without (inside the limit) ✓" ;;
  poucos-runs)   note "live: only $2 bead(s) with a verdict in the window — too few to conclude; re-run later (this is not a pass of the coverage, only of the wiring)" ;;
  nao-ligada)    note "live: .gc/third-state-reads.conf is absent — the check is not switched on, so there is nothing to cover (the Mayor's switch)" ;;
  sem-braco)     note "live: the conf is mode=warn/off — it draws no arm by design, nothing to cover (the Mayor's switch)" ;;
  interruptor)   note "live: a kill-switch flag is present (younger than the alarm age) — the check is off on purpose, nothing to cover" ;;
  *)             fail "unexpected verdict '$1' from the detector on the live city: $(head -4 "$S/live.txt")" ;;
esac
grep -E '^  (checagem|arquivo|beads|janela)|cidade:' "$S/live.txt" | cut -c1-230 | while IFS= read -r l; do log "live: $l"; done

log "PASS"
exit 0
