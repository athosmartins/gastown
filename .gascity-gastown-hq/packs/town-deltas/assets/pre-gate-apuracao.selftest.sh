#!/usr/bin/env bash
# pre-gate-apuracao.selftest.sh — guard for scripts/pre-gate-apuracao.py (ga-gnr3tw): the report that decides whether the
# builder's pre-gate self-review (E3 of P0 ga-ufskhy) raises first-attempt approval.
#
# A measurement report has two ways to be wrong that LOOK right: a number computed on the wrong population, and an empty
# input printed as a clean zero. This harness feeds it synthetic runs.jsonl + dispatcher log with HAND-COMPUTED expected
# values (arm split, first-attempt rate, adherence buckets, exact vs estimated cost, time to PASS, the ITT rule, timezone
# handling) and the degenerate inputs (empty roster, missing files, corrupt lines, a roster arm that disagrees with the
# real assignment function). No live Dolt/gc/launchd. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APU="${APURACAO_UNDER_TEST:-$SELF_DIR/../../../scripts/pre-gate-apuracao.py}"
PG="$SELF_DIR/pre-gate-review.sh"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 — not found: $2"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$1"; then bad "$3 — present: $2"; else ok "$3"; fi; }
eq()  { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 — expected [$2] got [$1]"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pre-gate-apu.XXXXXX")"
trap '[ -n "${T:-}" ] && [ -d "$T" ] && rm -rf "$T"' EXIT

echo "── 1. COMPILE-GUARD ──"
if python3 -m py_compile "$APU" 2>/dev/null; then ok "pre-gate-apuracao.py compiles"; else bad "pre-gate-apuracao.py does NOT compile"; fi
if [ -f "$PG" ]; then ok "pre-gate-review.sh present (arm rule is executed from it, not reimplemented)"; else bad "missing $PG"; fi
# hashing CODE, not the word: the error message may legitimately say "sem ferramenta sha256"
if grep -qE 'hashlib|hexdigest|% *100000007|shasum|sha256sum|openssl' "$APU"; then bad "the apuracao reimplements the arm rule (hashing code found) — it must EXECUTE pregate_arm_for_bead"; else ok "the apuracao does not reimplement the arm rule"; fi

# shellcheck disable=SC1090
source "$PG"
pick() {   # pick <arm> <count> <prefix> -> ids whose REAL arm is <arm>
  local arm="$1" n="$2" pre="$3" i=0 out="" c=0 id
  while [ "$c" -lt "$n" ] && [ "$i" -lt 2000 ]; do id="ga-$pre$i"; if [ "$(pregate_arm_for_bead "$id")" = "$arm" ]; then out="$out $id"; c=$((c+1)); fi; i=$((i+1)); done
  echo $out
}

mk_hq() {   # mk_hq <dir> — a minimal HQ tree: the real script + lib under packs/, empty logs
  mkdir -p "$1/packs/town-deltas/assets" "$1/.gc/logs/pre-gate-review"
  cp "$SELF_DIR/pre-gate-review.sh" "$SELF_DIR/gate-review-task.lib.sh" "$1/packs/town-deltas/assets/"
  : > "$1/.gc/logs/quality-gate-dispatcher.log"; : > "$1/.gc/logs/pre-gate-review/runs.jsonl"
}
# gen <hq> <spec.json> — writes runs.jsonl + the dispatcher log from a spec; timestamps are epochs so the UTC record and
# the LOCAL log line are guaranteed to be the same instant (the tz trap the apuracao must survive)
gen() {
  python3 - "$1" "$2" <<'PY'
import json, sys, time
hq, spec = sys.argv[1], json.load(open(sys.argv[2]))
utc = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
loc = lambda e: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e))
runs, log = [], []
for b in spec["beads"]:
    t0 = b["t0"]
    runs.append({"ts": utc(t0), "event": "assign", "bead": b["bead"], "branch": b["branch"], "sha": "x", "arm": b["assign_arm"]})
    for r in b.get("runs", []):
        rec = {"ts": utc(t0 + 60), "event": "run", "bead": b["bead"], "branch": b["branch"], "arm": b["assign_arm"], "attempt": 1}
        rec.update(r); runs.append(rec)
    for verdict, mins in b.get("outcomes", []):
        log.append((t0 + mins * 60, f"[{loc(t0 + mins * 60)}] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-r{len(log)} branch={b['branch']} verdict={verdict} elapsed=900s ==="))
log.sort()
open(f"{hq}/.gc/logs/pre-gate-review/runs.jsonl", "w").write("\n".join(json.dumps(r) for r in runs) + ("\n" if runs else "") + ("THIS IS NOT JSON\n" if spec.get("junk") else ""))
open(f"{hq}/.gc/logs/quality-gate-dispatcher.log", "w").write("\n".join(l for _, l in log) + ("\n" if log else ""))
PY
}
# The clock is pinned (T0 + 1h) so "assigned recently" does not depend on when this suite runs; a test that needs another
# instant passes its own --now, which wins because argparse takes the last occurrence.
apu() { python3 "$APU" --hq "$1" --now "$((T0 + 3600))" "${@:2}" 2>&1; }

T0=1790000000   # 2026-09-22T... an instant; only differences matter

echo "── 2. SCENARIO A: hand-computed numbers (on 8/10 first-attempt PASS, off 5/10) ──"
ON_IDS=($(pick on 14 ona)); OFF_IDS=($(pick off 10 offa))
A_HQ="$T/hqA"; mk_hq "$A_HQ"
python3 - "$T/specA.json" "${ON_IDS[@]:0:14}" -- "${OFF_IDS[@]:0:10}" "$T0" <<'PY'
import json, sys
args = sys.argv[2:]; i = args.index("--"); on = args[:i]; off = args[i+1:-1]; t0 = int(args[-1])
L = []
def bead(b, arm, outcomes, runs=(), assign_arm=None, dt=0):
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": assign_arm or arm, "t0": t0 + dt, "outcomes": outcomes, "runs": list(runs)})
pgpass = {"launched": True, "verdict": "PASS", "cost_usd": 0.5}
pgfail = {"launched": True, "verdict": "FAIL", "cost_usd": 0.5}
# on b1-b4: pre-gate PASS, gate PASS first try (30 min)
for b in on[0:4]: bead(b, "on", [["PASS", 30]], [pgpass])
# on b5,b6: guard refused (nothing spent) ; gate PASS first try
for b in on[4:6]: bead(b, "on", [["PASS", 30]], [{"launched": False, "verdict": "INCONCLUSIVE", "reason": "machine-guard:disk-low:7GiB<10GiB"}])
# on b7: hit the per-bead cap ; PASS
bead(on[6], "on", [["PASS", 30]], [{"launched": False, "verdict": "SKIPPED", "reason": "max-runs"}])
# on b8: NO record at all (never ran step 2b) ; PASS
bead(on[7], "on", [["PASS", 30]])
# on b9: pre-gate FAIL, gate FAIL then PASS (90 min)  ; b10: pre-gate FAIL, gate FAIL FAIL
bead(on[8], "on", [["FAIL", 30], ["PASS", 90]], [pgfail]); bead(on[9], "on", [["FAIL", 30], ["FAIL", 90]], [pgfail])
# on b11: first gate outcome is infra (ERROR) -> not PASS/FAIL ; b12: no gate outcome yet (waiting)
bead(on[10], "on", [["ERROR", 30]]); bead(on[11], "on", [])
# on b13: roster says off but the real function says on -> ANOMALY, out of the count
bead(on[12], "on", [["PASS", 30]], assign_arm="off")
# on b14: assigned BEFORE --since (old) -> excluded by the date cut in the --since test
bead(on[13], "on", [["FAIL", 30]], dt=-86400 * 5)
# off o1-o5 PASS first ; o6,o7 FAIL then PASS ; o8 FAIL FAIL ; o9,o10 FAIL once
bead(off[0], "off", [["PASS", 30]], [{"launched": True, "verdict": "PASS", "cost_usd": 0.5, "forced": True}])   # a --force run in the control arm
for b in off[1:5]: bead(b, "off", [["PASS", 30]])
for b in off[5:7]: bead(b, "off", [["FAIL", 30], ["PASS", 90]])
bead(off[7], "off", [["FAIL", 30], ["FAIL", 90]])
for b in off[8:10]: bead(b, "off", [["FAIL", 30]])
json.dump({"beads": L, "junk": True}, open(sys.argv[1], "w"))
PY
gen "$A_HQ" "$T/specA.json"
OUT="$(apu "$A_HQ" --min-n 10)"; rc=$?
eq "$rc" "0" "apuracao exits 0 on good data"
has "$OUT" "roster: 23 branches (13 on / 10 off)" "roster counts: 14 assigned on − 1 anomaly = 13 on, 10 off"
has "$OUT" "aguardando 1o desfecho do gate: 1 (atribuídas há ≤ 48h)" "one bead is still waiting for its first gate outcome — and the window that word means is printed"
hasnt "$OUT" "SEM desfecho e FORA da conta" "no stale / log-gap warning while nothing is stale and the log covers the roster"
has "$OUT" "esta tabela conta TODA branch com algum desfecho do gate: on=12 off=10" "the COST table's population is stated: 12 on (11 PASS/FAIL + 1 infra) and 10 off"
has "$OUT" "a tabela da taxa acima só as de 1o desfecho PASS/FAIL: on=11 off=10" "…next to the RATE table's population (11 on, 10 off), so the two denominators can no longer differ unlabelled"
has "$OUT" "a diferença são as de 1o desfecho infra/timeout: on=1 off=0" "…and the difference is named (the 1 infra-first bead)"
has "$OUT" "on=1 off=0" "the infra (ERROR) first outcome is counted apart, not as PASS or FAIL"
has "$OUT" "1 com braço gravado ≠ recalculado" "the roster arm that disagrees with the real function is flagged"
has "$OUT" "1 linha(s) ilegível(is)" "the corrupt runs.jsonl line is counted, not fatal, not silent"
has "$OUT" "on (pré)         11        8    73%" "PRIMARY on: 11 branches, 8 first-try PASS, 73% (b14 old-but-in-window counts here; see the --since test)"
has "$OUT" "off (ctrl)       10        5    50%" "PRIMARY off: 10 branches, 5 first-try PASS, 50%"
has "$OUT" "diferença on − off: +22.7pp" "difference on−off = 8/11 − 5/10 = +22.7pp"
has "$OUT" "NÃO exclui 0" "with n≈10/arm the difference is NOT distinguishable from chance — and the report says so"
has "$OUT" "rodaram a pré-revisão: 6 de 12 beads (50%)" "adherence: 6 of the 12 on-arm beads that reached the gate ran the step"
has "$OUT" "2 × machine-guard" "not-ran bucket: machine guard ×2"
has "$OUT" "1 × max-runs" "not-ran bucket: per-bead cap ×1"
has "$OUT" "3 × SEM REGISTRO" "not-ran bucket: no record ×3 (b8, the infra bead, the old bead) — named, not folded into 'off'"
has "$OUT" "FAIL=2, PASS=4" "1st pre-gate verdicts among the on beads that ran"
has "$OUT" "pré-revisão PASS → gate 1a-PASS 4/4" "calibration: pre-gate PASS predicted gate PASS 4/4"
has "$OUT" "pré-revisão FAIL → gate 1a-PASS 0/2" "calibration: pre-gate FAIL, gate FAIL 0/2 (small n flagged)"
has "$OUT" "3.00" "pre-gate spend is EXACT: 6 launched runs × US\$0.50 = 3.00"
has "$OUT" "CONTROLE CONTAMINADO: 1 bead(s) do braço OFF rodaram a pré-revisão" "a control-arm bead that ran the step (--force) is flagged, not silently counted"
has "$OUT" "NÃO MEDIDO" "builder rework cost is declared NOT MEASURED"
has "$OUT" "ESTIMATIVA" "reviewer cost is labelled an ESTIMATE"
has "$OUT" "mediana 30 min (n=9)" "time to first gate PASS, on: median 30 min over 9 approved beads"
has "$OUT" "mediana 30 min (n=7)" "time to first gate PASS, off: median 30 min over 7 approved beads"
# --min-n default (30) => INCONCLUSIVO, no verdict
OUT30="$(apu "$A_HQ")"
has "$OUT30" "INCONCLUSIVO" "n < 30 per arm → INCONCLUSIVO"
hasnt "$OUT30" "CRITÉRIO ATINGIDO" "no 'criterion met' can appear on n < min-n"

echo "── 3. ITT + the date window ──"
OUTS="$(apu "$A_HQ" --min-n 10 --since "$(python3 -c "import time;print(time.strftime('%Y-%m-%d',time.gmtime($T0-86400)))")")"
has "$OUTS" "roster: 22 branches" "--since drops the assignment made 5 days earlier (23 → 22)"
has "$OUTS" "on (pré)         10        8    80%" "after the date cut: on = 8/10 = 80%"

echo "── 3b. 'no outcome' is three different things: waiting, stale, log gap ──"
# X: assigned at T0, no gate outcome ever. Y: a later, unrelated bead whose outcome makes the log start after X's assignment.
XB=($(pick on 2 onx)); YB=($(pick on 1 ony))
python3 - "$T/specF.json" "${XB[0]}" "${YB[0]}" "$T0" <<'PY'
import json, sys
x, y, t0 = sys.argv[2], sys.argv[3], int(sys.argv[4])
L = [{"bead": x, "branch": f"crew/x/{x}", "assign_arm": "on", "t0": t0, "outcomes": [], "runs": []}]
json.dump({"beads": L}, open(sys.argv[1], "w"))
PY
# F1: fresh, no outcome, the log has an EARLIER dated line (an unrelated outcome two hours before) -> genuinely waiting
F1_HQ="$T/hqF1"; mk_hq "$F1_HQ"; gen "$F1_HQ" "$T/specF.json"
python3 - "$F1_HQ" "$T0" <<'PY'
import sys, time
hq, t0 = sys.argv[1], int(sys.argv[2])
stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0 - 7200))
open(f"{hq}/.gc/logs/quality-gate-dispatcher.log", "w").write(f"[{stamp}] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-old branch=crew/x/other verdict=PASS elapsed=60s ===\n")
PY
OUTF1="$(apu "$F1_HQ")"
has "$OUTF1" "aguardando 1o desfecho do gate: 1" "F1 fresh + covered by the log → waiting"
hasnt "$OUTF1" "SEM desfecho e FORA da conta" "F1 …and not flagged as stale or a log gap"
# F2: same data, 3 days later -> stale, NOT waiting: an old bead with no outcome is not 'still waiting'
OUTF2="$(apu "$F1_HQ" --now "$((T0 + 259200))")"
has "$OUTF2" "aguardando 1o desfecho do gate: 0" "F2 older than the window → no longer counted as waiting"
has "$OUTF2" "1 sem desfecho localizável após 48h" "F2 …reported as stale, out loud"
# F2b: the window is an argument
OUTF2B="$(apu "$F1_HQ" --now "$((T0 + 259200))" --wait-h 96)"
has "$OUTF2B" "aguardando 1o desfecho do gate: 1 (atribuídas há ≤ 96h)" "F2b --wait-h 96 widens the window (and the printed window follows)"
# F3: the log starts AFTER the assignment (rotated): an outcome may exist and not be readable -> log gap, never 'waiting'
F3_HQ="$T/hqF3"; mk_hq "$F3_HQ"
python3 - "$T/specF3.json" "${XB[0]}" "${YB[0]}" "$T0" <<'PY'
import json, sys
x, y, t0 = sys.argv[2], sys.argv[3], int(sys.argv[4])
L = [{"bead": x, "branch": f"crew/x/{x}", "assign_arm": "on", "t0": t0, "outcomes": [], "runs": []},
     {"bead": y, "branch": f"crew/x/{y}", "assign_arm": "on", "t0": t0 + 10800, "outcomes": [["PASS", 10]], "runs": []}]
json.dump({"beads": L}, open(sys.argv[1], "w"))
PY
gen "$F3_HQ" "$T/specF3.json"
OUTF3="$(apu "$F3_HQ" --now "$((T0 + 14400))")"
has "$OUTF3" "1 que o log do dispatcher não cobre" "F3 assignment older than the log's first line → 'the log does not cover it'"
has "$OUTF3" "aguardando 1o desfecho do gate: 0" "F3 …and it is NOT counted as waiting"
# F4: a log with no dated line at all cannot testify about anything: every outcome-less bead is a log gap
F4_HQ="$T/hqF4"; mk_hq "$F4_HQ"; gen "$F4_HQ" "$T/specF.json"; printf 'no timestamps here\n' > "$F4_HQ/.gc/logs/quality-gate-dispatcher.log"
OUTF4="$(apu "$F4_HQ")"
has "$OUTF4" "1 que o log do dispatcher não cobre" "F4 an undated log → log gap, not 'waiting'"
# F5: valid JSON that is not a record must not crash the report — it is counted with the unreadable lines
F5_HQ="$T/hqF5"; mk_hq "$F5_HQ"; gen "$F5_HQ" "$T/specF.json"
printf '%s\n' '12' 'null' '[1,2]' '"str"' >> "$F5_HQ/.gc/logs/pre-gate-review/runs.jsonl"
OUTF5="$(apu "$F5_HQ")"; rc=$?
eq "$rc" "0" "F5 non-object JSON lines → exit 0 (no traceback)"; hasnt "$OUTF5" "Traceback" "F5 …no Python traceback in the report"
has "$OUTF5" "4 linha(s) ilegível(is) em runs.jsonl" "F5 …and all four are counted as unreadable, not dropped"

echo "── 4. DEGENERATE INPUTS never print a clean zero ──"
E_HQ="$T/hqE"; mk_hq "$E_HQ"
OUTE="$(apu "$E_HQ")"; rc=$?
eq "$rc" "0" "empty roster → exit 0 (nothing to measure is not an error)"
has "$OUTE" "roster: 0 branches" "empty roster says 0 branches"
has "$OUTE" "n/a" "empty arms print n/a, not 0%"
hasnt "$OUTE" " 0%" "no '0%' rate is invented for an empty arm"
has "$OUTE" "INCONCLUSIVO" "empty roster → INCONCLUSIVO"
# a malformed roster row is COUNTED, never silently dropped; and an arm function that cannot run invalidates the report
Z_HQ="$T/hqZ"; mk_hq "$Z_HQ"
printf '%s\n' '{"ts":"2026-09-30T00:00:00Z","event":"assign","bead":"ga-z1","branch":"crew/x/ga-z1","arm":"maybe"}' \
               '{"ts":"not-a-date","event":"assign","bead":"ga-z2","branch":"crew/x/ga-z2","arm":"on"}' \
               '{"ts":"2026-09-30T00:00:00Z","event":"assign","bead":"ga-z3","arm":"on"}' > "$Z_HQ/.gc/logs/pre-gate-review/runs.jsonl"
OUTZ="$(apu "$Z_HQ")"; rc=$?
eq "$rc" "0" "an empty-after-filter roster is still exit 0"; has "$OUTZ" "3 linha(s) de atribuição malformada(s)" "3 malformed roster rows (bad arm, bad ts, no branch) are counted"
V_HQ="$T/hqV"; mk_hq "$V_HQ"; rm -f "$V_HQ/packs/town-deltas/assets/pre-gate-review.sh"
printf '%s\n' '{"ts":"2026-09-30T00:00:00Z","event":"assign","bead":"ga-v1","branch":"crew/x/ga-v1","arm":"on"}' > "$V_HQ/.gc/logs/pre-gate-review/runs.jsonl"
OUTV="$(apu "$V_HQ")"; rc=$?
eq "$rc" "2" "the arm function cannot run (script missing) → exit 2, not a tidy empty report"; has "$OUTV" "NENHUM braço" "and it says why"
M_HQ="$T/hqM"; mk_hq "$M_HQ"; rm -f "$M_HQ/.gc/logs/pre-gate-review/runs.jsonl"
OUTM="$(apu "$M_HQ")"; rc=$?
eq "$rc" "2" "missing runs.jsonl → exit 2 (NOT a silent empty report)"; has "$OUTM" "FALHA" "missing runs.jsonl → says FALHA"
L_HQ="$T/hqL"; mk_hq "$L_HQ"; rm -f "$L_HQ/.gc/logs/quality-gate-dispatcher.log"
OUTL="$(apu "$L_HQ")"; rc=$?
eq "$rc" "2" "missing dispatcher log → exit 2"; has "$OUTL" "FALHA" "missing dispatcher log → says FALHA"

echo "── 5. SCENARIO B: a strong, cheap effect DOES reach the criterion (the verdict can go green) ──"
BON=($(pick on 40 onb)); BOFF=($(pick off 40 offb))
B_HQ="$T/hqB"; mk_hq "$B_HQ"
python3 - "$T/specB.json" "${BON[@]}" -- "${BOFF[@]}" "$T0" <<'PY'
import json, sys
args = sys.argv[2:]; i = args.index("--"); on = args[:i]; off = args[i+1:-1]; t0 = int(args[-1])
L = []
for k, b in enumerate(on):     # 38/40 = 95% first-try, pre-gate spend US$0.10 each
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 20]] if k < 38 else [["FAIL", 20], ["PASS", 60]], "runs": [{"launched": True, "verdict": "PASS", "cost_usd": 0.10}]})
for k, b in enumerate(off):    # 22/40 = 55% first-try, many retries
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "off", "t0": t0, "outcomes": [["PASS", 20]] if k < 22 else [["FAIL", 20], ["FAIL", 60], ["PASS", 100]]})
json.dump({"beads": L}, open(sys.argv[1], "w"))
PY
gen "$B_HQ" "$T/specB.json"
OUTB="$(apu "$B_HQ")"
has "$OUTB" "CRITÉRIO ATINGIDO" "strong + cheap + n=40/arm → criterion met (proposal for the Mayor, not an auto-enable)"
has "$OUTB" "diferença exclui 0 (efeito real, não acaso)?  → SIM" "the CI excludes 0"
hasnt "$OUTB" "CONTROLE CONTAMINADO" "no contamination warning when the control arm is clean"
# same on-rate but the on arm costs MORE per approved bead than off → must NOT be green
python3 - "$T/specB.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for b in s["beads"]:
    if b["assign_arm"] == "on":
        b["runs"] = [{"launched": True, "verdict": "PASS", "cost_usd": 9.00}]
json.dump(s, open(sys.argv[1], "w"))
PY
gen "$B_HQ" "$T/specB.json"
OUTB3="$(apu "$B_HQ")"
has "$OUTB3" "CRITÉRIO NÃO ATINGIDO" "on wins on approval but costs far more per approved bead → criterion NOT met"
has "$OUTB3" "US\$/aprovada on ≤ off (PARCIAL, sem construtor)?" "the cost condition is printed as PARTIAL (no builder cost)"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
