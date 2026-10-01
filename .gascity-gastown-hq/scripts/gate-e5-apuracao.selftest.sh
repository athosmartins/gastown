#!/usr/bin/env bash
# gate-e5-apuracao.selftest.sh (ga-syxaki, E5)
#
# Proves the apuração tells the truth on a synthetic log whose answer is known:
#   * the primary metric is per BEAD, binary, with THREE states — a bead whose 1st FAIL has no
#     later outcome yet is "ainda não se sabe", never counted as "resolveu";
#   * a FAIL without a reviewer judgment (timeout, dead reviewer) is not a "FAIL de revisor";
#   * a bead whose 1st FAIL predates the flag stays out of the primary metric;
#   * the recorded arm is AUDITED against the live lib; a wrong arm aborts loudly;
#   * cost has three states per session (sabido / desconhecido / sem registro), dedupes the
#     streamed repeats of one message, and never reports an exact per-bead cost while any of
#     that bead's sessions is unknown;
#   * an empty window says "flag not on yet", not "0%".
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/gate-e5-apuracao.py"
LIB="$SELF_DIR/../packs/town-deltas/assets/gate-e5-second-reviewer.lib.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 (=$3)"; else bad "$1 — expected '$2', got '$3'"; fi; }

echo "== gate-e5-apuracao.selftest =="
[ -r "$SCRIPT" ] && [ -r "$LIB" ] || { echo "FATAL: missing script or lib" >&2; exit 2; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gate-e5-apur.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# bead ids of each arm, from the REAL lib function
arm() { env -i PATH="$PATH" GC_CITY=/x /bin/bash -c "set -euo pipefail; source '$LIB'; gate_e5_arm_for_bead '$1'"; }
A_IDS=(); B_IDS=()
for k in $(seq 1 200); do
  id="ga-ap$(printf '%03d' "$k")"
  if [ "$(arm "$id")" = "A" ]; then [ "${#A_IDS[@]}" -lt 12 ] && A_IDS+=("$id"); else [ "${#B_IDS[@]}" -lt 16 ] && B_IDS+=("$id"); fi
  [ "${#A_IDS[@]}" -ge 12 ] && [ "${#B_IDS[@]}" -ge 16 ] && break
done
[ "${#A_IDS[@]}" -ge 12 ] && [ "${#B_IDS[@]}" -ge 16 ] && ok "12 arm-A and 16 arm-B beads picked with the live arm function" || { bad "could not pick the fixture beads"; exit 1; }

# ── fixture: known answer ─────────────────────────────────────────────────────
python3 - "$TMP" "${A_IDS[*]}" "${B_IDS[*]}" "$LIB" <<'PYEOF'
import json, os, subprocess, sys, time
tmp, a_ids, b_ids, lib = sys.argv[1], sys.argv[2].split(), sys.argv[3].split(), sys.argv[4]
ev = []
n = [0]
def ts():
    n[0] += 1
    return "2026-10-02T10:%02d:%02dZ" % (n[0] // 60, n[0] % 60)
# The e5_admit fields are what the REAL gate_e5_admit_decision writes, never invented here (gate attempt 3, blocking issue 2): this fixture
# used to fabricate a line count for every arm-A run, which production never emitted (arm A logged size_state=no with raw_lines="") — so a
# stratified comparison with no measured control arm passed this suite. lines="fail" = the diff cannot be read (git fails).
_admit = {}
def real_admit(bead, lines):
    key = (bead, lines)
    if key not in _admit:
        script = ('set -euo pipefail; warn() { :; }; '
                  'git_rig() { if [ "$N" = fail ]; then return 128; fi; i=0; while [ "$i" -lt "$N" ]; do echo "+l"; i=$((i+1)); done; }; '
                  'BEAD_ID="$B"; DEFAULT_BRANCH=main; BRANCH=x; REQUIRED_REVIEWERS=1; source "$LIB"; gate_e5_admit_decision; '
                  'printf "%s|%s|%s|%s" "$GATE_E5_ARM" "$GATE_E5_TRIGGER" "$GATE_E5_SIZE_STATE" "${GATE_E5_RAW_LINES:-}"')
        out = subprocess.run(["/bin/bash", "-c", script], env={"PATH": os.environ["PATH"], "LIB": lib, "B": bead, "N": str(lines)},
                             capture_output=True, text=True, check=True).stdout
        _admit[key] = out.split("|")
    return _admit[key]
def run(bead, arm, result, reason, admitted=True, lines="300", extra=None):
    g = "ga-run-%s-%d" % (bead, n[0] + 1)
    t = ts()
    if admitted:
        real_arm, trigger, size_state, raw = real_admit(bead, lines)
        assert real_arm == arm, "fixture bead %s is arm %s in the live lib, not %s" % (bead, real_arm, arm)
        ev.append({"ts": t, "event": "e5_admit", "gate_run": g, "bead": bead, "arm": arm, "trigger": trigger,
                   "size_state": size_state, "raw_lines": raw, "rig": "whatsapp_automation", "tier": "CODE"})
        ev.append({"ts": t, "event": "e5_session", "gate_run": g, "bead": bead, "slot": "1", "verdict_bead": "ga-r1%s" % format(abs(hash(g)) % 10**6, "06d")})
    ev.append({"ts": ts(), "event": "dispatcher_complete", "gate_run": g, "bead": bead, "result": result, "reason": reason})
    if extra:
        ev.append({"ts": ts(), "event": extra[0], "gate_run": g, "bead": bead, **extra[1]})
    return g
FAILJ = "Reviewer 1 FAIL: VERDICT: FAIL"
# arm A: 4 beads 1st-FAIL -> 2nd FAIL ; 4 -> FAIL then PASS ; 2 -> FAIL, nothing after yet ; 1 timeout-only (not a reviewer FAIL) ; 1 clean PASS
# sizes (the stratification key): default 300 lines; one arm-A bead with a 1200-line diff and one whose diff could not be read ("fail"),
# and the same pair on arm B further down — every size stratum has BOTH arms measured, and the unmeasured one is symmetric.
for b in a_ids[0:4]:
    lines = "1200" if b == a_ids[0] else "300"
    run(b, "A", "FAIL", FAILJ, lines=lines); run(b, "A", "FAIL", FAILJ); run(b, "A", "PASS", "quorum_1_of_1_independent_sessions")
for b in a_ids[4:8]:
    run(b, "A", "FAIL", FAILJ, lines="fail" if b == a_ids[4] else "300"); run(b, "A", "PASS", "quorum")
for b in a_ids[8:10]:
    run(b, "A", "FAIL", FAILJ)
run(a_ids[10], "A", "FAIL", "TIMEOUT: reviewers did not submit verdicts within 25 minutes."); run(a_ids[10], "A", "PASS", "quorum")
run(a_ids[11], "A", "PASS", "quorum")
# arm B: 2 beads 1st-FAIL -> 2nd FAIL ; 6 -> FAIL then PASS ; 2 pending ; 1 prior-to-flag FAIL ; 1 clean PASS
for b in b_ids[0:2]:
    run(b, "B", "FAIL", FAILJ); run(b, "B", "FAIL", FAILJ); run(b, "B", "PASS", "quorum")
for b in b_ids[2:8]:
    lines = {b_ids[2]: "fail", b_ids[3]: "900"}.get(b, "300")
    run(b, "B", "FAIL", FAILJ, lines=lines); run(b, "B", "PASS", "quorum")
for b in b_ids[8:10]:
    run(b, "B", "FAIL", FAILJ)
# 1st FAIL BEFORE the flag (no e5_admit for it), then a flagged PASS -> must stay out of the primary metric
run(b_ids[10], "B", "FAIL", FAILJ, admitted=False); g10 = run(b_ids[10], "B", "PASS", "quorum")
g11 = run(b_ids[11], "B", "PASS", "quorum")
# treatment delivery on B, each on its OWN bead so the primary metric stays exactly as counted above
g = run(b_ids[12], "B", "FAIL", FAILJ, lines="1200")                            # 1st FAIL, big diff, extra delivered a FAIL
ev.append({"ts": ts(), "event": "e5_extra_spawn", "gate_run": g, "bead": b_ids[12], "trigger": "big-diff", "extra_vb": "ga-exkn01", "session_id": "s", "session_key": ""})
ev.append({"ts": ts(), "event": "e5_run_end", "gate_run": g, "bead": b_ids[12], "result": "FAIL", "extra_verdict": "FAIL"})
run(b_ids[12], "B", "PASS", "quorum")                                           # -> resolved
g = run(b_ids[13], "B", "PASS", "quorum")                                       # extra spawned then abandoned
ev.append({"ts": ts(), "event": "e5_extra_spawn", "gate_run": g, "bead": b_ids[13], "trigger": "first-fail", "extra_vb": "ga-exun02", "session_id": "s2", "session_key": ""})
ev.append({"ts": ts(), "event": "e5_extra_abandoned", "gate_run": g, "bead": b_ids[13], "extra_vb": "ga-exun02", "reason": "extra-timeout"})
g = run(b_ids[14], "B", "PASS", "quorum")                                       # declined for the cap: ran as arm A
ev.append({"ts": ts(), "event": "e5_extra_declined", "gate_run": g, "bead": b_ids[14], "trigger": "first-fail", "reason": "daily-cap-reached"})
g = run(b_ids[15], "B", "PASS", "quorum")                                       # spawned, no run_end, no transcript anywhere
ev.append({"ts": ts(), "event": "e5_extra_spawn", "gate_run": g, "bead": b_ids[15], "trigger": "first-fail", "extra_vb": "ga-exms03", "session_id": "s3", "session_key": ""})
# the two other states of an extra that ended without delivering (the log says which; "no record at all" is the b_ids[15] case above)
ev.append({"ts": ts(), "event": "e5_extra_spawn", "gate_run": g11, "bead": b_ids[11], "trigger": "first-fail", "extra_vb": "ga-exno04", "session_id": "s4", "session_key": ""})
ev.append({"ts": ts(), "event": "e5_run_end", "gate_run": g11, "bead": b_ids[11], "result": "PASS", "extra_verdict": "NONE"})           # closed with no verdict
ev.append({"ts": ts(), "event": "e5_extra_spawn", "gate_run": g10, "bead": b_ids[10], "trigger": "first-fail", "extra_vb": "ga-exun05", "session_id": "s5", "session_key": ""})
ev.append({"ts": ts(), "event": "e5_run_end", "gate_run": g10, "bead": b_ids[10], "result": "PASS", "extra_verdict": "UNREADABLE"})     # its comments could not be read
with open(os.path.join(tmp, "qg.jsonl"), "w") as fh:
    fh.write("not json at all\n")
    for e in ev:
        fh.write(json.dumps(e) + "\n")
# transcripts: one complete (old, end_turn, streamed duplicate), one still active, nothing for "vb-extra-missing"
tdir = os.path.join(tmp, "transcripts"); os.makedirs(tdir)
def write(name, vb, model, stop, old):
    path = os.path.join(tdir, name)
    usage = lambda out: {"input_tokens": 2, "output_tokens": out, "cache_read_input_tokens": 10000,
                         "cache_creation": {"ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 30000}}
    with open(path, "w") as fh:
        fh.write(json.dumps({"type": "user", "message": {"content": "task ... close \"%s\" ..." % vb}}) + "\n")
        # the SAME message id streamed twice (partial then final): must be counted once, at the larger output
        fh.write(json.dumps({"type": "assistant", "message": {"id": "m1", "model": model, "stop_reason": None, "usage": usage(400)}}) + "\n")
        fh.write(json.dumps({"type": "assistant", "message": {"id": "m1", "model": model, "stop_reason": stop, "usage": usage(1000)}}) + "\n")
    if old:
        t = time.time() - 3600
        os.utime(path, (t, t))
write("done.jsonl", "ga-exkn01", "claude-sonnet-5-5", "end_turn", True)
write("active.jsonl", "ga-exun02", "claude-sonnet-5-5", "end_turn", False)
PYEOF
QG="$TMP/qg.jsonl"; TR="$TMP/transcripts"
run_ap() { python3 "$SCRIPT" --qg-log "$QG" --lib "$LIB" --transcripts "$TR" "$@"; }

echo "── primary metric ──"
J="$(run_ap --json)"; RC=$?
check "exit code" 0 "$RC"
check "arm A: 4 second-FAIL, 4 resolved, 2 still unknown (timeout-only and clean beads never enter)" "4,4,2" "$(printf '%s' "$J" | jq -r '.primaria.A | "\(.segunda_fail),\(.resolveu_sem_segunda_fail),\(.ainda_nao_se_sabe)"')"
check "arm B: 2 second-FAIL, 7 resolved, 2 unknown (the pre-flag 1st-FAIL bead is OUT)" "2,7,2" "$(printf '%s' "$J" | jq -r '.primaria.B | "\(.segunda_fail),\(.resolveu_sem_segunda_fail),\(.ainda_nao_se_sabe)"')"
check "beads whose 1st FAIL predates the flag are counted apart" 1 "$(printf '%s' "$J" | jq -r '.beads_com_1o_fail_anterior_a_flag_fora')"
check "arm audit passed against the live lib" "ok" "$(printf '%s' "$J" | jq -r '.braco_auditado' | cut -c1-2)"
T="$(run_ap)"
case "$T" in *"50.0%"*"22.2%"*) ok "rates: A 4/8 = 50.0%, B 2/9 = 22.2%" ;; *) bad "rates not shown as 50.0% / 22.2%: $(printf '%s' "$T" | grep -E 'A \(ctrl\)|B \(2º rev\)')" ;; esac
case "$T" in *"ficam FORA da taxa"*) ok "unresolved beads are flagged as OUTSIDE the rate" ;; *) bad "no warning about unresolved beads" ;; esac
case "$T" in *"AINDA NÃO CONCLUSIVO"*) ok "underpowered result says so" ;; *) bad "no 'not conclusive yet' warning" ;; esac
case "$T" in *"1 linha(s) ilegíveis"*) ok "a garbage line in the log is counted, not fatal" ;; *) bad "garbage line not reported" ;; esac

echo "── treatment delivery ──"
check "B: 5 extras spawned" 5 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento.extra_disparado')"
check "B: one extra delivered a FAIL" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento["extra_entregou:FAIL"]')"
check "B: one extra abandoned (reason kept)" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento["extra_abandonado:extra-timeout"]')"
check "B: one run declined for the daily cap (ran as arm A)" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento["recusado:daily-cap-reached"]')"
# gate attempt 3: an extra that ended without delivering is filed by WHAT the log says happened — "closed with no verdict" and "its comments
# could not be read" and "no run-end line at all" are three different facts, not one "no verdict recorded" bucket.
check "B: an extra that closed with NO verdict is its own state" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento.extra_fechou_sem_veredito')"
check "B: an extra whose comments could not be read is its own state" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento.extra_comentarios_ilegiveis')"
check "B: an extra with no e5_run_end line at all stays 'no record' (unknown, not 'delivered nothing')" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento.extra_sem_veredito_registrado')"
check "B: a big-diff run whose extra never spawned is counted apart" 1 "$(printf '%s' "$J" | jq -r '.entrega_do_tratamento["big-diff_sem_extra_registrado"]')"

echo "── size stratification: the diff is measured for BOTH arms ──"
# gate attempt 3, blocking issue 2. The admit records above come from the REAL gate_e5_admit_decision. Before the fix arm A logged
# size_state=no with raw_lines="" for every run, so all of arm A fell into 'tamanho desconhecido' while arm B had real buckets: a table
# with "<800 A: 0/0 B: 0/2", ">=800 A: 0/0 B: 1/2", "desconhecido A: 0/4 B: 0/0" — no control arm in the strata that matter.
S() { printf '%s' "$J" | jq -r "$1"; }
check "tamanho=<800, arm A: 3 second-FAIL / 3 resolved / 2 unknown" "3,3,2" "$(S '.strata["tamanho=<800"].A | "\(.segunda_fail),\(.resolveu_sem_segunda_fail),\(.ainda_nao_se_sabe)"')"
check "tamanho=<800, arm B: 2 second-FAIL / 4 resolved / 2 unknown" "2,4,2" "$(S '.strata["tamanho=<800"].B | "\(.segunda_fail),\(.resolveu_sem_segunda_fail),\(.ainda_nao_se_sabe)"')"
check "tamanho=>=800, arm A has its OWN measured bead (1 second-FAIL)" 1 "$(S '.strata["tamanho=>=800"].A.segunda_fail')"
check "tamanho=>=800, arm B: 2 resolved" 2 "$(S '.strata["tamanho=>=800"].B.resolveu_sem_segunda_fail')"
check "a diff that could not be read: one bead per arm in 'tamanho desconhecido' — symmetric, and only those" "1,1" "$(S '.strata["tamanho=tamanho desconhecido"] | "\(.A.resolveu_sem_segunda_fail),\(.B.resolveu_sem_segunda_fail)"')"
check "EVERY size stratum has a bead of BOTH arms (a stratified comparison needs a control in each cell)" true "$(S '[.strata | to_entries[] | select(.key | startswith("tamanho=")) | ((.value.A | length) > 0 and (.value.B | length) > 0)] | all')"
check "beads with no measured size, per arm" "1,1" "$(S '.tamanho_nao_medido | "\(.A),\(.B)"')"
case "$T" in *"NÃO medido em A: 1 de 12"*"B: 1 de 16"*) ok "the report says how many beads per arm have no measured size" ;; *) bad "no size-coverage line in the report: $(printf '%s' "$T" | grep -i 'medido' | head -2)" ;; esac

echo "── cost: three states ──"
check "sessions by state, arm B: known=1 unknown=1 no-record=1 + every reviewer-1 session has no transcript" \
  "1,1" "$(printf '%s' "$J" | jq -r '.custo.sessoes_por_estado.B | "\(.sabido),\(.desconhecido)"')"
check "the measured cost is only the complete session: (2*3 + 1000*15 + 10000*0.30 + 30000*6)/1e6 = 0.198 (streamed duplicate counted once)" \
  "0.2" "$(printf '%s' "$J" | jq -r '.custo.usd_sabido_so_extras')"
check "no bead is reported with an exact cost while any of its sessions is unknown / unrecorded" 0 "$(printf '%s' "$J" | jq -r '.custo.beads_com_custo_exato.B')"
case "$T" in *"PISO"*"NUNCA leia 'exato'"*) ok "the report labels measured cost as a floor" ;; *) bad "report does not warn that cost is a floor" ;; esac
check "a missing transcript dir is 'sem registro' for EVERY session, never zero cost" 0 "$(python3 "$SCRIPT" --qg-log "$QG" --lib "$LIB" --transcripts "$TMP/nope" --json | jq -r '.custo.sessoes_por_estado | [.A.sabido // 0, .B.sabido // 0] | add')"
echo '{"other":{"in":1,"out":1,"cache_read":1,"cache_write_5m":1,"cache_write_1h":1}}' > "$TMP/prices.json"
check "a model with no price is never costed: 0 known, both transcripts 'desconhecido' (no invented price)" "0,2" "$(python3 "$SCRIPT" --qg-log "$QG" --lib "$LIB" --transcripts "$TR" --price-json "$TMP/prices.json" --json | jq -r '.custo.sessoes_por_estado.B | "\(.sabido // 0),\(.desconhecido)"')"

echo "── an unreadable transcript is not 'no record' ──"
mkdir -p "$TMP/tr-unreadable"; cp "$TR"/done.jsonl "$TMP/tr-unreadable/done.jsonl"; : > "$TMP/tr-unreadable/locked.jsonl"; chmod 000 "$TMP/tr-unreadable/locked.jsonl"
UJ="$(python3 "$SCRIPT" --qg-log "$QG" --lib "$LIB" --transcripts "$TMP/tr-unreadable" --json)"
check "with one unreadable transcript, sessions that found no match are 'desconhecido', never 'sem registro'" 0 "$(printf '%s' "$UJ" | jq -r '.custo.sessoes_por_estado.B.sem_registro // 0')"
chmod 600 "$TMP/tr-unreadable/locked.jsonl"

echo "── the recorded arm is audited ──"
python3 - "$QG" "$TMP/qg-bad.jsonl" <<'PYEOF'
import json, sys
out = open(sys.argv[2], "w")
flipped = False
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: out.write(line); continue
    if o.get("event") == "e5_admit" and not flipped:
        o["arm"] = "B" if o["arm"] == "A" else "A"; flipped = True
    out.write(json.dumps(o) + "\n")
PYEOF
python3 "$SCRIPT" --qg-log "$TMP/qg-bad.jsonl" --lib "$LIB" --no-cost >/dev/null 2>"$TMP/err.txt"; RC=$?
[ "$RC" -ne 0 ] && grep -q "FATAL: braço gravado" "$TMP/err.txt" && ok "a wrong recorded arm aborts loudly (rc=$RC)" || bad "a wrong recorded arm was accepted (rc=$RC)"
# gate attempt 1, blocking issue 3: an admit record with NO arm field is an UNMEASURED arm ("?", outside A/B), never A. Read as A, a
# bead whose live arm is B would abort the whole analysis with "braço gravado != recalculado" over a record that only lacked a field.
python3 - "$QG" "$TMP/qg-noarm.jsonl" "${B_IDS[0]}" <<'PYEOF'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: out.write(line); continue
    if o.get("event") == "e5_admit" and o.get("bead") == sys.argv[3]:
        o.pop("arm", None)
    out.write(json.dumps(o) + "\n")
PYEOF
python3 "$SCRIPT" --qg-log "$TMP/qg-noarm.jsonl" --lib "$LIB" --no-cost --json >"$TMP/noarm.json" 2>"$TMP/err.txt"; RC=$?
[ "$RC" = "0" ] && ok "an admit record with no arm field does not abort the audit (read as ?, not as A)" || bad "an admit record with no arm field aborted the analysis (rc=$RC): $(head -1 "$TMP/err.txt")"
check "...and that bead is counted as 'sem braço' (in neither arm), not silently dropped" 1 "$(jq -r '.beads_sem_braco' "$TMP/noarm.json")"
python3 "$SCRIPT" --qg-log "$QG" --lib /nonexistent/lib.sh --no-cost >/dev/null 2>"$TMP/err.txt"; RC=$?
[ "$RC" -ne 0 ] && ok "a missing lib aborts (no guessed arm rule), rc=$RC" || bad "missing lib did not abort"
# gate attempt 3 (non-blocking): an audit that comes back EMPTY is not an audit that found no divergence. Both ways it can come back empty
# must abort, each under its own message: the live function gave no arm (no sha tool), and the bash that runs it died.
printf 'gate_e5_arm_for_bead() {\n  return 3\n}\n' > "$TMP/fake-lib-noarm.sh"
python3 "$SCRIPT" --qg-log "$QG" --lib "$TMP/fake-lib-noarm.sh" --no-cost >/dev/null 2>"$TMP/err.txt"; RC=$?
[ "$RC" -ne 0 ] && grep -q "FATAL: a auditoria do braço não recalculou" "$TMP/err.txt" && ok "the live lib returning NO arm for the recorded beads aborts (was: 'ok (0 beads recalculadas, 0 divergências)'), rc=$RC" || bad "an audit that recalculated nothing passed (rc=$RC): $(head -1 "$TMP/err.txt")"
printf 'gate_e5_arm_for_bead() {\n  kill -9 $$\n}\n' > "$TMP/fake-lib-crash.sh"
python3 "$SCRIPT" --qg-log "$QG" --lib "$TMP/fake-lib-crash.sh" --no-cost >/dev/null 2>"$TMP/err.txt"; RC=$?
[ "$RC" -ne 0 ] && grep -q "FATAL: a auditoria do braço não rodou" "$TMP/err.txt" && ok "the audit's bash dying aborts under its own message, rc=$RC" || bad "a crashed audit passed (rc=$RC): $(head -1 "$TMP/err.txt")"
# every admit record with no arm: nothing to audit — and the header must SAY so instead of claiming an audit passed
python3 - "$QG" "$TMP/qg-allnoarm.jsonl" <<'PYEOF'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: out.write(line); continue
    if o.get("event") == "e5_admit":
        o.pop("arm", None)
    out.write(json.dumps(o) + "\n")
PYEOF
python3 "$SCRIPT" --qg-log "$TMP/qg-allnoarm.jsonl" --lib "$LIB" --no-cost --json >"$TMP/allnoarm.json" 2>"$TMP/err.txt"; RC=$?
check "a log whose admit records all lack an arm: runs, no abort" "0" "$RC"
case "$(jq -r '.braco_auditado' "$TMP/allnoarm.json")" in "NADA AUDITADO"*) ok "...and the header says NOTHING WAS AUDITED (never 'ok')" ;; *) bad "nothing-to-audit reads as a passed audit: $(jq -r '.braco_auditado' "$TMP/allnoarm.json")" ;; esac
# the per-bead arm comes from ALL of a bead's admitted runs: a FIRST run recorded "?" (a sha tool missing for one sweep) must not drop the
# bead from both arms when a later run of the same bead carries its arm
python3 - "$QG" "$TMP/qg-qfirst.jsonl" "${B_IDS[4]}" <<'PYEOF'
import json, sys
out = open(sys.argv[2], "w")
done = False
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: out.write(line); continue
    if o.get("event") == "e5_admit" and o.get("bead") == sys.argv[3] and not done:
        o.pop("arm", None); done = True
    out.write(json.dumps(o) + "\n")
PYEOF
python3 "$SCRIPT" --qg-log "$TMP/qg-qfirst.jsonl" --lib "$LIB" --no-cost --json >"$TMP/qfirst.json" 2>"$TMP/err.txt"; RC=$?
check "a bead whose FIRST admitted run has no arm but whose later run is B: rc" "0" "$RC"
check "...stays in arm B (2 second-FAIL / 7 resolved / 2 unknown, unchanged)" "2,7,2" "$(jq -r '.primaria.B | "\(.segunda_fail),\(.resolveu_sem_segunda_fail),\(.ainda_nao_se_sabe)"' "$TMP/qfirst.json")"
check "...and is NOT counted as 'sem braço'" 0 "$(jq -r '.beads_sem_braco' "$TMP/qfirst.json")"

echo "── empty window ──"
: > "$TMP/empty.jsonl"
OUT="$(python3 "$SCRIPT" --qg-log "$TMP/empty.jsonl" --lib "$LIB")"; RC=$?
check "empty log: exit 0" 0 "$RC"
case "$OUT" in *"flag ainda não foi ligada"*"NÃO é erro"*) ok "empty log says 'the flag is not on yet', not 0%" ;; *) bad "empty log message wrong: $OUT" ;; esac
check "--since after every event: same (no runs in the window)" 1 "$(python3 "$SCRIPT" --qg-log "$QG" --lib "$LIB" --since 2027-01-01 | grep -c 'flag ainda não foi ligada')"

echo "== gate-e5-apuracao.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
