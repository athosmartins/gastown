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
#   * a window with no e5_admit is read against the FLAG FILE (gate attempt 4): flag off -> "not started"; flag ON and judged runs
#     that started after it but no admit -> a loud error (rc 3), never the benign reading; flag unreadable -> "cannot tell" (rc 4).
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
# the apuração reads the E5 flag file; a suite must not depend on (or be moved by) the live one. Absent unless a case builds its own.
export GATE_E5_FLAG_FILE="$TMP/flag.absent"

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

echo "── what 'no e5_admit' means: the FLAG decides (gate attempt 4, blocking issue 2) ──"
# The old report printed "a flag ainda não foi ligada ... (vazio aqui NÃO é erro...)" for ANY window without an e5_admit — also when the
# flag IS on and the E5 is not admitting (lib not loaded, log not written). Same output for two different worlds. REPRO from the verdict:
# a log with 40 dispatcher_complete lines and zero e5_admit exited 0 with exactly that text.
python3 - "$TMP" <<'PYEOF2'
import json, os, sys, calendar, time
tmp = sys.argv[1]
T = "2026-10-02T09:00:00Z"                                  # the flag is turned on here
def comp(ts, g, result="PASS", reason="quorum_1_of_1_independent_sessions", elapsed=600, dry="0", with_elapsed=True):
    e = {"ts": ts, "event": "dispatcher_complete", "gate_run": g, "bead": "ga-b-" + g, "result": result, "reason": reason, "dry_run": dry}
    if with_elapsed:
        e["elapsed_s"] = elapsed
    return e
def write(name, evs):
    with open(os.path.join(tmp, name), "w") as fh:
        for e in evs:
            fh.write(json.dumps(e) + "\n")
# 40 judged runs, all started well after T+10min, none admitted (the verdict's repro)
write("h-broken.jsonl", [comp("2026-10-02T%02d:%02d:00Z" % (10 + i // 30, (i * 2) % 60), "ga-r%03d" % i,
                              *(("FAIL", "Reviewer 1 FAIL: VERDICT: FAIL") if i % 4 == 0 else ())) for i in range(40)]
      + [{"ts": "2026-10-02T09:30:00Z", "event": "e5_lib_not_loaded", "bead": "ga-x", "why": "the lib file is missing"},
         {"ts": "2026-10-02T09:31:00Z", "event": "e5_lib_not_loaded", "bead": "ga-y", "why": "the lib file is missing"},
         {"ts": "2026-10-02T08:00:00Z", "event": "e5_lib_not_loaded", "bead": "ga-old", "why": "BEFORE the flag: not counted"}])
# only runs that were already in flight when the flag flipped, or started inside the 10 min margin
write("h-inflight.jsonl", [comp("2026-10-02T09:05:00Z", "ga-if1", elapsed=1800),      # started 08:35, before the flip
                           comp("2026-10-02T09:12:00Z", "ga-if2", elapsed=420)])      # started 09:05: inside the margin
# runs that prove NOTHING: no reviewer judged, a dry run, a duration that cannot be read
write("h-unjudged.jsonl", [comp("2026-10-02T10:00:00Z", "ga-u1", "FAIL", "TIMEOUT: reviewers did not submit verdicts within 25 minutes."),
                           comp("2026-10-02T10:05:00Z", "ga-u2", "FAIL", "Merge failed after all-PASS verdict."),
                           comp("2026-10-02T10:10:00Z", "ga-u3", dry="1"),
                           comp("2026-10-02T10:15:00Z", "ga-u4", with_elapsed=False),
                           comp("2026-10-02T10:20:00Z", "ga-unknown", elapsed=600)])
evs = [json.loads(l) for l in open(os.path.join(tmp, "h-unjudged.jsonl"))]; evs[-1]["gate_run"] = "unknown"; write("h-unjudged.jsonl", evs)
with open(os.path.join(tmp, "flag.on"), "w") as fh: fh.write("ligado em %s — Mayor, bead ga-syxaki #1, teste\n" % T)
with open(os.path.join(tmp, "flag.nostamp"), "w") as fh: fh.write("ligado\n")
t_epoch = calendar.timegm(time.strptime(T, "%Y-%m-%dT%H:%M:%SZ")); os.utime(os.path.join(tmp, "flag.nostamp"), (t_epoch, t_epoch))
with open(os.path.join(tmp, "flag.unreadable"), "w") as fh: fh.write("ligado em %s — x\n" % T)
os.chmod(os.path.join(tmp, "flag.unreadable"), 0)
PYEOF2
hl() { python3 "$SCRIPT" --qg-log "$1" --lib "$LIB" --no-cost --flag-file "$2" "${@:3}"; }
: > "$TMP/empty.jsonl"
OUT="$(hl "$TMP/empty.jsonl" "$TMP/flag.absent")"; RC=$?
check "empty log + flag absent: exit 0" 0 "$RC"
case "$OUT" in *"o experimento ainda não começou"*) ok "...says the experiment has NOT STARTED (flag off and nothing in the log — both facts, not one)" ;; *) bad "empty log + flag off message wrong: $OUT" ;; esac
check "...and the old absolute ('vazio aqui NÃO é erro') is gone from the output" 0 "$(printf '%s' "$OUT" | grep -c 'NÃO é erro')"
check "--since after every event, flag off, admits exist OUTSIDE the window: its own state ('janela sem admissões'), rc 0" "1,0" \
  "$(hl "$QG" "$TMP/flag.absent" --since 2027-01-01 | grep -c 'Nenhum e5_admit NA JANELA'),$(hl "$QG" "$TMP/flag.absent" --since 2027-01-01 >/dev/null; echo $?)"
# the verdict's repro: flag ON, 40 judged runs, zero admits
OUT="$(hl "$TMP/h-broken.jsonl" "$TMP/flag.on")"; RC=$?
check "flag ON + 40 judged runs that started after it + ZERO e5_admit: exit 3 (not 0)" 3 "$RC"
case "$OUT" in *"O E5 ESTÁ LIGADO E NÃO ESTÁ ADMITINDO NADA"*"40 run(s) julgada(s)"*) ok "...with a loud error that counts the judged runs" ;; *) bad "flag ON + no admits did not say so: $OUT" ;; esac
check "...and it does NOT print the benign 'not started' line for the same empty (the error may QUOTE the phrase to deny it)" 0 "$(printf '%s' "$OUT" | grep -c 'a flag está desligada: o experimento ainda não começou')"
case "$OUT" in *"e5_lib_not_loaded no log desde a flag: 2"*) ok "...and names the lib-not-loaded warnings the dispatcher left since the flag (2; the one BEFORE the flag is not counted)" ;; *) bad "lib-not-loaded warnings not surfaced/counted: $(printf '%s' "$OUT" | grep -i 'lib não')" ;; esac
check "the same state through --json: estado + rc" "ligado_sem_admitir,3" "$(hl "$TMP/h-broken.jsonl" "$TMP/flag.on" --json | jq -r '.saude | "\(.estado),\(.rc)"')"
hl "$TMP/h-broken.jsonl" "$TMP/flag.on" --json >/dev/null; check "--json exits 3 too (the status is not a text-mode privilege)" 3 "$?"
# the other side of the same rule: no false alarm
OUT="$(hl "$TMP/h-inflight.jsonl" "$TMP/flag.on")"; RC=$?
check "flag ON, only runs in flight at the flip / inside the 10-min margin: exit 0 (they read the flag as off, legitimately)" 0 "$RC"
case "$OUT" in *"ainda não dá para dizer se o E5 está admitindo"*) ok "...and says it cannot tell yet — neither 'fine' nor 'broken'" ;; *) bad "in-flight-only log not reported as 'cannot tell yet': $OUT" ;; esac
OUT="$(hl "$TMP/h-unjudged.jsonl" "$TMP/flag.on")"; RC=$?
check "flag ON, runs that prove nothing (timeout / merge failure / dry run / unreadable duration / run id 'unknown'): exit 0" 0 "$RC"
case "$OUT" in *"ainda não dá para dizer"*) ok "...cannot tell yet (a run that never spawned a reviewer has no e5_admit, legitimately)" ;; *) bad "unjudged-only log misread: $OUT" ;; esac
# a flag file with no readable stamp: dated by its mtime, and the report says that is what it did
OUT="$(hl "$TMP/h-broken.jsonl" "$TMP/flag.nostamp")"; RC=$?
check "flag without a 'ligado em' stamp: dated by mtime, still exit 3" 3 "$RC"
case "$OUT" in *"mtime do arquivo"*) ok "...and the report says the date came from the mtime, not from the stamp" ;; *) bad "mtime fallback not disclosed: $(printf '%s' "$OUT" | grep 'flag:')" ;; esac
# unreadable flag: the dispatcher reads it as OFF (inert), the apuração cannot say which world this is
OUT="$(hl "$TMP/h-broken.jsonl" "$TMP/flag.unreadable")"; RC=$?
check "flag file EXISTS but cannot be read: exit 4" 4 "$RC"
case "$OUT" in *"NÃO CONSIGO SABER"*"EXISTE e não pode ser lido"*) ok "...says it cannot tell, and why" ;; *) bad "unreadable flag not reported as such: $OUT" ;; esac
check "...and it is not reported as 'not started' either" 0 "$(printf '%s' "$OUT" | grep -c 'a flag está desligada: o experimento ainda não começou')"
chmod 600 "$TMP/flag.unreadable"
# admits present, but judged runs after the flag that have none: the denominator is incomplete — a warning, not a silent pass
python3 - "$QG" "$TMP/h-partial.jsonl" <<'PYEOF2'
import json, sys
out = open(sys.argv[2], "w")
for line in open(sys.argv[1]):
    out.write(line)
for i in range(3):
    out.write(json.dumps({"ts": "2026-10-02T11:%02d:00Z" % i, "event": "dispatcher_complete", "gate_run": "ga-lost%d" % i, "bead": "ga-lost%d" % i,
                          "result": "PASS", "reason": "quorum_1_of_1_independent_sessions", "elapsed_s": 600, "dry_run": "0"}) + "\n")
PYEOF2
OUT="$(hl "$TMP/h-partial.jsonl" "$TMP/flag.on" --json)"; RC=$?
check "admits present, 3 judged runs after the flag WITHOUT one: exit 0 (the experiment runs) but the gap is counted" "0,3" "$RC,$(printf '%s' "$OUT" | jq -r '.saude.runs_julgadas_sem_admit')"
case "$(hl "$TMP/h-partial.jsonl" "$TMP/flag.on")" in *"3 das 3 run(s) julgada(s)"*"NÃO têm e5_admit"*) ok "...and the text warns that those runs are OUTSIDE A and B" ;; *) bad "incomplete denominator not warned about" ;; esac
check "the normal fixture (flag absent) is unchanged: no 'estado' error, exit 0" "ok,0" "$(run_ap --json | jq -r '.saude | "\(.estado),\(.rc)"')"

# mutations: is this section vacuous?
echo "── Mutations: the apuração suite must notice each of these ──"
mut() { # mut <out> <sed-expression>
  sed -e "$2" "$SCRIPT" > "$1"; cmp -s "$SCRIPT" "$1" && { bad "mutation did not apply: $2"; return 1; }; return 0
}
if mut "$TMP/apur.nojudge.py" 's/            if judged:$/            if False:/'; then
  python3 "$TMP/apur.nojudge.py" --qg-log "$TMP/h-broken.jsonl" --lib "$LIB" --no-cost --flag-file "$TMP/flag.on" >/dev/null 2>&1; R=$?
  [ "$R" = "0" ] && ok "mutation 'flag on + judged runs + no admits is NOT an error' (the old behaviour) is caught: it exits 0 where the real script exits 3" || bad "no-error mutant survived (rc=$R)"
fi
if mut "$TMP/apur.nograce.py" 's/^FLAG_GRACE_S = .*/FLAG_GRACE_S = 0/'; then
  python3 "$TMP/apur.nograce.py" --qg-log "$TMP/h-inflight.jsonl" --lib "$LIB" --no-cost --flag-file "$TMP/flag.on" >/dev/null 2>&1; R=$?
  [ "$R" = "3" ] && ok "mutation 'no 10-min margin' is caught: the run that began 09:05, before the flag could be read as on, becomes a false alarm (rc 3, real 0)" || bad "no-margin mutant survived (rc=$R)"
fi
if mut "$TMP/apur.alljudged.py" 's/    return (res == "PASS" and reason.startswith("quorum_")) or (res == "FAIL" and bool(JUDGED_RE.match(reason)))/    return True/'; then
  python3 "$TMP/apur.alljudged.py" --qg-log "$TMP/h-unjudged.jsonl" --lib "$LIB" --no-cost --flag-file "$TMP/flag.on" >/dev/null 2>&1; R=$?
  [ "$R" = "3" ] && ok "mutation 'any completion is evidence' is caught: a timeout / merge failure (no e5_admit, legitimately) becomes a false alarm (rc 3, real 0)" || bad "any-completion mutant survived (rc=$R)"
fi
if mut "$TMP/apur.unreadable.py" 's/        h.update(estado="flag_ilegivel", rc=RC_UNKNOWN)/        h.update(estado="nao_comecou", rc=0)/'; then
  chmod 000 "$TMP/flag.unreadable"
  python3 "$TMP/apur.unreadable.py" --qg-log "$TMP/h-broken.jsonl" --lib "$LIB" --no-cost --flag-file "$TMP/flag.unreadable" >/dev/null 2>&1; R=$?
  chmod 600 "$TMP/flag.unreadable"
  [ "$R" = "0" ] && ok "mutation 'an unreadable flag reads as not-started' is caught: it exits 0 where the real script exits 4" || bad "unreadable-flag mutant survived (rc=$R)"
fi

echo "== gate-e5-apuracao.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
