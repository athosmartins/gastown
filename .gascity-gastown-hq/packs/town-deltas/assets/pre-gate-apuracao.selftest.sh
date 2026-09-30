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
# a real PASS record always says how much of the diff the reviewer saw (a PASS that does not is read as "coverage unknown", 5d)
pgpass = {"launched": True, "verdict": "PASS", "cost_usd": 0.5, "cost_known": True, "coverage": "full", "partial": False}
pgfail = {"launched": True, "verdict": "FAIL", "cost_usd": 0.5, "cost_known": True}
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
# on b11: first gate outcome carries a token the dispatcher does NOT emit today ("Gate run complete" only ever says PASS or FAIL;
#   "ERROR" is synthetic) -> exercises the forward-compat guard, NOT an infra outcome: infra aborts are logged as FAIL (see 2b)
# on b12: no gate outcome yet (waiting)
bead(on[10], "on", [["ERROR", 30]]); bead(on[11], "on", [])
# on b13: roster says off but the real function says on -> ANOMALY, out of the count
bead(on[12], "on", [["PASS", 30]], assign_arm="off")
# on b14: assigned BEFORE --since (old) -> excluded by the date cut in the --since test
bead(on[13], "on", [["FAIL", 30]], dt=-86400 * 5)
# off o1-o5 PASS first ; o6,o7 FAIL then PASS ; o8 FAIL FAIL ; o9,o10 FAIL once
bead(off[0], "off", [["PASS", 30]], [{"launched": True, "verdict": "PASS", "cost_usd": 0.5, "cost_known": True, "forced": True}])   # a --force run in the control arm
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
has "$OUT" "a diferença são as de 1o desfecho com token inesperado: on=1 off=0" "…and the cost-table difference is named for what it is: an unexpected token (the line above spells it 'nem PASS nem FAIL')"
has "$OUT" "desfecho com token inesperado (nem PASS nem FAIL): on=1 off=0" "the unexpected-token first outcome is counted apart, not as PASS or FAIL"
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
echo "── 2b. a FAIL that no reviewer judged is NOT separable from this log — and the report must not pretend it is ──"
# The live dispatcher log holds exactly two tokens in "Gate run complete" lines (PASS, FAIL): a run where no reviewer judged
# (timeout with a live reviewer, reviewer died before judging — GATE_FAIL_NO_EVAL) is logged verdict=FAIL. A bucket labelled
# "infra/timeout" therefore reads 0 in production, and "on=0 off=0" next to it is a reassuring zero about something this log
# cannot see. The report says so instead, and says which way the error leans.
hasnt "$OUT" "(infra/timeout)" "the old 'infra/timeout' label is gone (it could only ever read 0 against the real log)"
hasnt "$OUT" "1o desfecho infra/timeout" "…and so is the cost-table sentence that named it"
has "$OUT" "FAIL inclui runs em que NENHUM revisor julgou" "the report states that FAIL includes runs no reviewer judged"
has "$OUT" "NÃO separável deste log" "…and that they are not separable from this log"
has "$OUT" "só emite PASS ou FAIL" "…because the outcome line only ever says PASS or FAIL"
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
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 20]] if k < 38 else [["FAIL", 20], ["PASS", 60]], "runs": [{"launched": True, "verdict": "PASS", "cost_usd": 0.10, "cost_known": True}]})
for k, b in enumerate(off):    # 22/40 = 55% first-try, many retries
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "off", "t0": t0, "outcomes": [["PASS", 20]] if k < 22 else [["FAIL", 20], ["FAIL", 60], ["PASS", 100]]})
json.dump({"beads": L}, open(sys.argv[1], "w"))
PY
gen "$B_HQ" "$T/specB.json"
OUTB="$(apu "$B_HQ")"
has "$OUTB" "CRITÉRIO ATINGIDO" "strong + cheap + n=40/arm → criterion met (proposal for the Mayor, not an auto-enable)"
has "$OUTB" "diferença exclui 0 (efeito real, não acaso)?  → SIM" "the CI excludes 0"
hasnt "$OUTB" "CONTROLE CONTAMINADO" "no contamination warning when the control arm is clean"
has "$OUTB" "pré-gate = EXATO" "every launched run has a known cost → the pre-gate figure may be called EXATO"
hasnt "$OUTB" "SEM custo conhecido" "…and no unknown-cost warning appears"
has "$OUTB" "a taxa conta como reprovação os runs em que nenhum revisor julgou" "the verdict section says the rate counts no-reviewer-judged runs as FAIL"
has "$OUTB" "viés para BAIXO" "…and which way that leans (toward NOT reaching on ≥ target)"
# same on-rate but the on arm costs MORE per approved bead than off → must NOT be green
python3 - "$T/specB.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
for b in s["beads"]:
    if b["assign_arm"] == "on":
        b["runs"] = [{"launched": True, "verdict": "PASS", "cost_usd": 9.00, "cost_known": True}]
json.dump(s, open(sys.argv[1], "w"))
PY
gen "$B_HQ" "$T/specB.json"
OUTB3="$(apu "$B_HQ")"
has "$OUTB3" "CRITÉRIO NÃO ATINGIDO" "on wins on approval but costs far more per approved bead → criterion NOT met"
has "$OUTB3" "US\$/aprovada on ≤ off (PARCIAL, sem construtor)?" "the cost condition is printed as PARTIAL (no builder cost)"

echo "── 5c. a run whose cost is UNKNOWN is a lower bound — never a \$0 reported as EXATO ──"
# The bug this guards (gate ga-ta6wow): pre-gate-review.sh wrote cost_usd=0 for a run with no result event (timeout rc=124,
# kill rc=137, garbage stream), and this report summed it and printed "pré-gate = EXATO". A timed-out run can burn up to the
# per-run cap, and the error leans toward ENABLING the step. Ruler: a cost this code could not know must not look like $0.
mk_b() {   # mk_b <out.json> <arm-to-poison|none> <extra-launched-run-json> <on-arm-first-try: pass|fail>
  python3 - "$@" "${BON[@]}" -- "${BOFF[@]}" "$T0" <<'PY'
import json, sys
a = sys.argv[1:]; i = a.index("--")
out, poison, runjson, first = a[0], a[1], json.loads(a[2]), a[3]
on = a[4:i]; off = a[i+1:-1]; t0 = int(a[-1])
known = {"launched": True, "verdict": "PASS", "cost_usd": 0.10, "cost_known": True}
L = []
for k, b in enumerate(on):
    ok = k < 38 and first == "pass"
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 20]] if ok else [["FAIL", 20], ["PASS", 60]], "runs": [dict(known)]})
for k, b in enumerate(off):
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "off", "t0": t0, "outcomes": [["PASS", 20]] if k < 22 else [["FAIL", 20], ["FAIL", 60], ["PASS", 100]], "runs": []})
if poison in ("on", "off"):
    next(x for x in L if x["assign_arm"] == poison)["runs"].append(runjson)
json.dump({"beads": L}, open(out, "w"))
PY
}
UNK_TIMEOUT='{"launched": true, "verdict": "INCONCLUSIVE", "reason": "timeout:1500s", "cost_known": false, "exit_code": 124}'
C_HQ="$T/hqC"; mk_hq "$C_HQ"
mk_b "$T/specC.json" on "$UNK_TIMEOUT" pass; gen "$C_HQ" "$T/specC.json"
OUTC="$(apu "$C_HQ")"
has "$OUTC" "SEM custo conhecido: on=1 off=0" "a launched run with cost_known=false is counted and named (on=1)"
has "$OUTC" "≥4.00" "the pre-gate US\$ is printed as a LOWER BOUND (40 known runs × 0.10, the unknown one adds nothing): ≥4.00"
has "$OUTC" "LIMITE INFERIOR" "…and labelled LIMITE INFERIOR"
hasnt "$OUTC" "pré-gate = EXATO" "…and it is no longer called EXATO"
has "$OUTC" "→ INDETERMINADO" "the cost condition reads INDETERMINADO, not SIM"
has "$OUTC" "CRITÉRIO INDETERMINADO" "rate and CI pass, cost unknown → the criterion is INDETERMINADO"
hasnt "$OUTC" "CRITÉRIO ATINGIDO" "…never ATINGIDO (this is the direction the old zero erred in)"
hasnt "$OUTC" "CRITÉRIO NÃO ATINGIDO" "…and not a made-up NÃO either: it is unknown"
# the same money, but unknown for a different reason each time: none of these may be read as a cost
for flavor in \
  'legacy zero (old writer: cost_usd=0, no cost_known)|{"launched": true, "verdict": "INCONCLUSIVE", "reason": "timeout:1s", "cost_usd": 0}' \
  'known-flag but cost is a string|{"launched": true, "verdict": "PASS", "cost_known": true, "cost_usd": "abc"}' \
  'known-flag but cost is NaN|{"launched": true, "verdict": "PASS", "cost_known": true, "cost_usd": NaN}' \
  'known-flag but cost is negative|{"launched": true, "verdict": "PASS", "cost_known": true, "cost_usd": -1}' \
  'known-flag but cost is a bool|{"launched": true, "verdict": "PASS", "cost_known": true, "cost_usd": true}' \
  'known-flag but no cost_usd|{"launched": true, "verdict": "PASS", "cost_known": true}'; do
  label="${flavor%%|*}"; js="${flavor#*|}"
  mk_b "$T/specC2.json" on "$js" pass; gen "$C_HQ" "$T/specC2.json"; O="$(apu "$C_HQ")"
  hasnt "$O" "Traceback" "unknown cost — $label: the report does not crash on it (a string cost used to raise inside float())"
  has "$O" "SEM custo conhecido: on=1 off=0" "unknown cost — $label: counted as unknown"
  has "$O" "CRITÉRIO INDETERMINADO" "unknown cost — $label: criterion INDETERMINADO"
  hasnt "$O" "CRITÉRIO ATINGIDO" "unknown cost — $label: never ATINGIDO"
done
# an unknown cost in the CONTROL arm (a --force run that timed out) poisons the comparison just the same
mk_b "$T/specC3.json" off "$UNK_TIMEOUT" pass; gen "$C_HQ" "$T/specC3.json"; O="$(apu "$C_HQ")"
has "$O" "SEM custo conhecido: on=0 off=1" "unknown cost in the OFF arm is counted (off=1)"
has "$O" "CRITÉRIO INDETERMINADO" "…and makes the criterion INDETERMINADO too"
# when another condition already fails the verdict is still decisive: an unknown cost does not soften a NÃO into a maybe
mk_b "$T/specC4.json" on "$UNK_TIMEOUT" fail; gen "$C_HQ" "$T/specC4.json"; O="$(apu "$C_HQ")"
has "$O" "CRITÉRIO NÃO ATINGIDO" "on rate far below target + an unknown cost → still NÃO ATINGIDO (decisive)"
hasnt "$O" "CRITÉRIO INDETERMINADO" "…not INDETERMINADO"
has "$O" "SEM custo conhecido: on=1 off=0" "…and the unknown cost is still reported"

echo "── 5d. a PASS on PART of the diff is not calibrated with the PASSes on the WHOLE diff (gate ga-0ygcas) ──"
# pre-gate-review.sh used to record a reviewer PASS on 1 of 3 files as verdict=PASS, exactly like a PASS on the whole diff, and
# this report's calibration line ("pré-revisão PASS → gate 1a-PASS") mixed the two: it would have measured how often a rehearsal
# that read HALF the diff predicts the gate under the label of one that read all of it. The current writer records that run as
# INCONCLUSIVE (reason partial-diff / coverage-unknown, the reviewer's own word kept in reviewer_verdict); an OLDER writer's
# record still says PASS. Both are read here as "PASS without full coverage", and a record that says nothing about coverage is
# not "whole" either.
DON=($(pick on 8 ond)); DOFF=($(pick off 2 offd))
D_HQ="$T/hqD"; mk_hq "$D_HQ"
python3 - "$T/specD.json" "${DON[@]}" -- "${DOFF[@]}" "$T0" <<'PY'
import json, sys
a = sys.argv[2:]; i = a.index("--"); on = a[:i]; off = a[i+1:-1]; t0 = int(a[-1])
def run(**kw):
    d = {"launched": True, "cost_usd": 0.5, "cost_known": True}; d.update(kw); return d
runs = [   # (the bead's first pre-gate run, its first gate outcome)
  (run(verdict="PASS", coverage="full", partial=False), "PASS"),                                                                    # d1 whole diff
  (run(verdict="INCONCLUSIVE", reason="partial-diff:1/3-files", coverage="partial:1/3", partial=True, reviewer_verdict="PASS"), "FAIL"),   # d2 current writer, partial
  (run(verdict="PASS", partial=True), "PASS"),                                                                                      # d3 older writer: PASS on a partial diff
  (run(verdict="PASS", partial=False), "PASS"),                                                                                     # d4 older writer: whole diff shown
  (run(verdict="PASS"), "FAIL"),                                                                                                    # d5 PASS, and the record says nothing about coverage
  (run(verdict="INCONCLUSIVE", reason="coverage-unknown", coverage="unknown", reviewer_verdict="PASS"), "PASS"),                    # d6 coverage unknown
  (run(verdict="INCONCLUSIVE", reason="timeout:1500s", cost_known=False), "FAIL"),                                                  # d7 an ordinary INCONCLUSIVE stays one
  (run(verdict="FAIL", reason="blocking", coverage="partial:1/3", partial=True, reviewer_verdict="FAIL"), "FAIL"),                  # d8 a FAIL on a partial diff is a FAIL
]
L = []
for b, (r, g) in zip(on, runs):
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [[g, 30]], "runs": [r]})
for b in off:
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "off", "t0": t0, "outcomes": [["PASS", 30]], "runs": []})
json.dump({"beads": L}, open(sys.argv[1], "w"))
PY
gen "$D_HQ" "$T/specD.json"
OUTD="$(apu "$D_HQ" --min-n 1)"
has "$OUTD" "FAIL=1, INCONCLUSIVE=1, PASS=2, PASS sem cobertura total=4" "1st pre-gate verdicts: 2 PASS on the whole diff, 4 PASS without full coverage (d2 d3 d5 d6), 1 ordinary INCONCLUSIVE (d7), 1 FAIL (d8)"
has "$OUTD" "pré-revisão PASS → gate 1a-PASS 2/2" "the PASS calibration holds only the two whole-diff PASSes (d1, and d4 whose older record says partial=false)"
has "$OUTD" "pré-revisão PASS sem cobertura total → gate 1a-PASS 2/4" "the PASSes that saw part of the diff, or an unknown amount, have a line of their own (d7 is not among them: 2/4, not 2/5)"
has "$OUTD" "FORA da calibração do PASS" "…and that line says why it is not the PASS calibration"
has "$OUTD" "pré-revisão FAIL → gate 1a-PASS 0/1" "a FAIL on a partial diff is still a FAIL (d8)"

echo "── 5e. an arm with no approved bead has no US\$/aprovada: INDETERMINADO, not a NÃO (gate ga-0ygcas, low) ──"
# cost per approved is NaN when an arm has no approved bead (a division by zero approvals), and `c_on <= NaN` is False: the report
# printed "→ NÃO" and "CRITÉRIO NÃO ATINGIDO" for a comparison that was never made — cannot-compute read as a failed condition.
E_HQ="$T/hqE"; mk_hq "$E_HQ"
python3 - "$T/specE.json" "${BON[@]}" -- "${BOFF[@]}" "$T0" <<'PY'
import json, sys
a = sys.argv[1:]; i = a.index("--")
out, on, off, t0 = a[0], a[1:i], a[i+1:-1], int(a[-1])
L = []
for b in on:   # every on bead passes first time, with a known cost
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 20]], "runs": [{"launched": True, "verdict": "PASS", "coverage": "full", "cost_usd": 0.10, "cost_known": True}]})
for b in off:  # no off bead is ever approved
    L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": "off", "t0": t0, "outcomes": [["FAIL", 20], ["FAIL", 60]], "runs": []})
json.dump({"beads": L}, open(out, "w"))
PY
gen "$E_HQ" "$T/specE.json"
OUTE="$(apu "$E_HQ")"
has "$OUTE" "INDETERMINADO (um braço sem bead aprovada: US\$/aprovada não calculável)" "the cost condition says WHY it cannot be decided"
has "$OUTE" "CRITÉRIO INDETERMINADO" "rate and CI pass, cost not computable → the criterion is INDETERMINADO"
hasnt "$OUTE" "CRITÉRIO NÃO ATINGIDO" "…not a NÃO for a comparison that was never made"
hasnt "$OUTE" "CRITÉRIO ATINGIDO" "…and never ATINGIDO"

echo "── 5f. a launched run leaves TWO rows (PENDING + FINAL, one run_id): they are ONE run; a run with no outcome is its own cause (gate ga-dkdir3) ──"
# pre-gate-review.sh writes a PENDING row BEFORE claude starts and a FINAL row after; a run killed mid-review has only the PENDING
# row, or a FINAL that says interrupted. Read naively, that (a) counts every finished run twice, and (b) files a killed run under
# "SEM REGISTRO" — "the builder never ran Step 2b" — and prices the arm as EXATO with that run's spend left out.
HON=($(pick on 6 onh)); HOFF=($(pick off 1 offh))
mk_h() {   # mk_h <out.json> [live-ts-offset-seconds] — one on bead per shape of run, one control bead with an interrupted forced run
  python3 - "$1" "$T0" "${HON[@]}" -- "${HOFF[@]}" <<'PY'
import json, sys, time
out, t0 = sys.argv[1], int(sys.argv[2]); a = sys.argv[3:]; i = a.index("--"); on, off = a[:i], a[i+1:]
utc = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
def run(rid, **kw):
    d = {"launched": True, "run_id": rid}; d.update(kw); return d
pend = lambda rid, **kw: run(rid, verdict="PENDING", reason="launched", cost_known=False, **kw)
L = []
def bead(b, arm, runs): L.append({"bead": b, "branch": f"crew/x/{b}", "assign_arm": arm, "t0": t0, "outcomes": [["PASS", 30]], "runs": runs})
# h1: finished PASS, cost 0.50 known — PENDING + FINAL under one run_id: ONE run
bead(on[0], "on", [pend("r1"), run("r1", verdict="PASS", coverage="full", partial=False, cost_known=True, cost_usd=0.5)])
# h2: interrupted by TERM — PENDING + a FINAL that says so
bead(on[1], "on", [pend("r2"), run("r2", verdict="INCONCLUSIVE", reason="interrupted:TERM", cost_known=False, exit_code=143)])
# h3: only a PENDING row, an hour old (SIGKILL / reboot: nothing could be written after it)
bead(on[2], "on", [pend("r3")])
# h4: only a PENDING row, 10 minutes old (the run may still be going)
bead(on[3], "on", [pend("r4", ts=utc(t0 + 3000))])
# h5: two launched rows from a writer with no run_id — nothing ties them, so they are TWO runs
bead(on[4], "on", [run(None, verdict="PASS", coverage="full", cost_known=True, cost_usd=0.3) for _ in range(2)])
for r in L[-1]["runs"]: del r["run_id"]
# h6 (control arm, --force): interrupted by the EXIT net
bead(off[0], "off", [pend("r6"), run("r6", verdict="INCONCLUSIVE", reason="abnormal-exit", cost_known=False, forced=True)])
json.dump({"beads": L}, open(out, "w"))
PY
}
H_HQ="$T/hqH"; mk_hq "$H_HQ"; mk_h "$T/specH.json"; gen "$H_HQ" "$T/specH.json"
OUTH="$(apu "$H_HQ" --min-n 1)"; rc=$?
eq "$rc" "0" "H: exit 0"; hasnt "$OUTH" "Traceback" "H: no traceback"
has "$OUTH" "INTERROMPIDOS por sinal ou saída anormal (TERM/INT/HUP, dreno, abnormal-exit): on=1 off=1" "H: the TERM run (h2) and the abnormal-exit run (h6, control arm) are INTERROMPIDOS — the FINAL row's own cause, counted ONCE each"
has "$OUTH" "SEM DESFECHO GRAVADO há mais de 40 min (SIGKILL, reboot, queda — só a linha PENDING ficou): on=1 off=0" "H: the hour-old PENDING with no FINAL (h3) is 'sem desfecho gravado'"
has "$OUTH" "EM CURSO (linha PENDING de ≤ 40 min — pode ainda terminar): on=1 off=0" "H: the 10-minute-old PENDING (h4) is 'em curso' — not declared dead"
has "$OUTH" "rodaram a pré-revisão: 5 de 5 beads (100%)" "H: all 5 on beads RAN the step — the killed ones are not 'never ran'"
hasnt "$OUTH" "× SEM REGISTRO" "H: no on bead is filed under the 'never ran' bucket"
has "$OUTH" "1o veredito da pré-revisão nas beads que rodaram: PASS=2, run sem desfecho (interrompido ou em curso)=3" "H: first verdicts: h1 + h5 PASS; h2 h3 h4 have NO verdict (their own group, outside the PASS calibration)"
has "$OUTH" "SEM custo conhecido: on=3 off=1" "H: unknown-cost runs = h2 + h3 + h4 (on=3) and h6 (off=1): each counted ONCE — a PENDING + FINAL pair is not two unknown runs"
has "$OUTH" "LIMITE INFERIOR" "H: with unknown-cost runs the pre-gate figure is a lower bound"
hasnt "$OUTH" "pré-gate = EXATO" "H: …never EXATO while a launched run has no cost"
has "$OUTH" "≥1.10" "H: on-arm pre-gate spend is 0.50 (h1, once) + 0.30 + 0.30 (h5: two id-less runs) = 1.10, printed as a lower bound"
has "$OUTH" "CONTROLE CONTAMINADO: 1 bead(s) do braço OFF" "H: the forced control-arm run is still flagged"
# the grace window is an argument
OUTHG="$(apu "$H_HQ" --min-n 1 --pending-grace-min 100)"
has "$OUTHG" "EM CURSO (linha PENDING de ≤ 100 min — pode ainda terminar): on=2 off=0" "H: --pending-grace-min 100 makes the hour-old PENDING (h3) 'em curso' too (and the printed window follows)"
has "$OUTHG" "SEM DESFECHO GRAVADO há mais de 100 min (SIGKILL, reboot, queda — só a linha PENDING ficou): on=0 off=0" "H: …and nothing is then 'sem desfecho gravado'"
# a PENDING + FINAL pair on its own: ONE run, known cost, EXATO — the dedupe must not turn a clean run into an unknown one
H2_HQ="$T/hqH2"; mk_hq "$H2_HQ"
python3 - "$T/specH2.json" "$T0" "${HON[0]}" <<'PY'
import json, sys
out, t0, b = sys.argv[1], int(sys.argv[2]), sys.argv[3]
runs = [{"launched": True, "run_id": "r1", "verdict": "PENDING", "reason": "launched", "cost_known": False},
        {"launched": True, "run_id": "r1", "verdict": "PASS", "coverage": "full", "partial": False, "cost_known": True, "cost_usd": 0.5}]
json.dump({"beads": [{"bead": b, "branch": f"crew/x/{b}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 30]], "runs": runs}]}, open(out, "w"))
PY
gen "$H2_HQ" "$T/specH2.json"; OUTH2="$(apu "$H2_HQ" --min-n 1)"
has "$OUTH2" "pré-gate = EXATO" "H2: a clean PENDING + FINAL pair is EXATO (the PENDING row is not a second, unknown run)"
hasnt "$OUTH2" "SEM custo conhecido" "H2: …and no unknown-cost run is reported"
has "$OUTH2" "1.10" "H2: US\$/aprovada = (0.50 pre-gate + 0.60 reviewer estimate) / 1 approved = 1.10 — the run's 0.50 is counted once, not twice"
has "$OUTH2" "INTERROMPIDOS por sinal ou saída anormal (TERM/INT/HUP, dreno, abnormal-exit): on=0 off=0" "H2: …and the report says plainly that nothing was interrupted (a real count, not a placeholder)"
# the other order in the file (FINAL first, PENDING after) must give the same answer: the FINAL row wins wherever it sits
python3 - "$H2_HQ/.gc/logs/pre-gate-review/runs.jsonl" <<'PY'
import sys
p = sys.argv[1]; L = open(p).read().splitlines()
runs = [i for i, l in enumerate(L) if '"event": "run"' in l]
L[runs[0]], L[runs[1]] = L[runs[1]], L[runs[0]]
open(p, "w").write("\n".join(L) + "\n")
PY
OUTH3="$(apu "$H2_HQ" --min-n 1)"
has "$OUTH3" "pré-gate = EXATO" "H3: FINAL before PENDING in the file → still ONE clean run (the FINAL row wins, wherever it sits)"
hasnt "$OUTH3" "SEM custo conhecido" "H3: …and no unknown-cost run"

# a run killed on a bead with NO gate outcome yet is not in the cost table (its population is "branches with an outcome") — but it
# spent money, and a killed run is exactly the kind that never reaches an outcome. Leaving it out of the "is any cost unknown?" test
# would print EXATO with that spend missing: the same hole as an unrecorded run, one step later.
H4_HQ="$T/hqH4"; mk_hq "$H4_HQ"
python3 - "$T/specH4.json" "$T0" "${HON[0]}" "${HON[1]}" <<'PY'
import json, sys
out, t0, b1, b2 = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
clean = [{"launched": True, "run_id": "r1", "verdict": "PASS", "coverage": "full", "partial": False, "cost_known": True, "cost_usd": 0.5}]
killed = [{"launched": True, "run_id": "r2", "verdict": "PENDING", "reason": "launched", "cost_known": False},
          {"launched": True, "run_id": "r2", "verdict": "INCONCLUSIVE", "reason": "interrupted:TERM", "cost_known": False, "exit_code": 143}]
L = [{"bead": b1, "branch": f"crew/x/{b1}", "assign_arm": "on", "t0": t0, "outcomes": [["PASS", 30]], "runs": clean},
     {"bead": b2, "branch": f"crew/x/{b2}", "assign_arm": "on", "t0": t0, "outcomes": [], "runs": killed}]
json.dump({"beads": L}, open(out, "w"))
PY
gen "$H4_HQ" "$T/specH4.json"
# an EARLIER dated line, so the log covers the waiting bead's assignment (without it the report rightly says "log gap", not "waiting")
python3 - "$H4_HQ" "$T0" <<'PYLOG'
import sys, time
hq, t0 = sys.argv[1], int(sys.argv[2]); path = f"{hq}/.gc/logs/quality-gate-dispatcher.log"
old = open(path).read()
stamp = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t0 - 7200))
open(path, "w").write(f"[{stamp}] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-old branch=crew/x/other verdict=PASS elapsed=60s ===\n" + old)
PYLOG
OUTH4="$(apu "$H4_HQ" --min-n 1)"
has "$OUTH4" "aguardando 1o desfecho do gate: 1" "H4: the killed run's bead is still waiting for its gate outcome (so it is NOT in the cost table)"
has "$OUTH4" "INTERROMPIDOS por sinal ou saída anormal (TERM/INT/HUP, dreno, abnormal-exit): on=1 off=0" "H4: …but the interrupted-runs block is roster-wide and sees it"
has "$OUTH4" "SEM custo conhecido: on=1 off=0" "H4: …and its unknown cost is counted"
has "$OUTH4" "Inclui 1 run(s) de beads do roster que ainda não têm desfecho do gate" "H4: …with the reason it is outside the sum, said plainly"
hasnt "$OUTH4" "pré-gate = EXATO" "H4: …so the pre-gate figure is NOT called EXATO (a spent run is missing from the sum)"
has "$OUTH4" "≥0.50" "H4: …it is printed as a lower bound (the known 0.50 only)"
hasnt "$OUTH4" "CRITÉRIO ATINGIDO" "H4: …and the criterion cannot be ATINGIDO on it"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
