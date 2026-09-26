#!/usr/bin/env bash
# jev-daily-report.test.sh — wa-dln9g: the end-of-day Jev ntfy.
#
# Runs the REAL scripts/jev-daily-report.sh against the REAL
# scripts/jev_experiment_report.py, with a synthetic experiment log and a fake
# `notify` first on PATH (records its args, never touches ntfy). Covers:
#   T1 a day with data -> full report file + ONE ntfy carrying the Portuguese
#      summary, with the exact MEASURED/ESTIMATED numbers and the Jev-unavailable
#      warning (a day the filter never ran must not read as "saved 0%").
#   T2 a day with no events -> still exactly one ntfy, saying there is no data
#      (silence would look the same as "the job never ran").
#   T3 the report script failing -> an ntfy saying so, and exit != 0.
#   T4 no date argument -> reports the UTC day that just closed (yesterday, UTC).
#   T5 the plist fires daily at 21:07 (= 00:07 UTC) and runs this script.
#   T6 the experiment log missing -> "report failed" ntfy + exit != 0, never
#      the "no alerts today" line (can't-know must not read as nothing-happened).
#   T7 a garbled day argument -> refused (--date "" would report the whole log
#      under one day's name).
#   T8 every ntfy goes out with NOTIFY_FORCE_PUSH=1 (ga-9wimr7): notify's default
#      route is the digest, and on 23/09 the real report landed there, never on
#      the phone. Checked on the success path AND on a failure path.
#   T9 (ga-aijm2v.3/F5) the gate-verdict join step runs before the report AND is
#      fail-open: a join failure is logged to gate-verdict-join.log but never
#      blocks or changes the report/ntfy outcome (same rc/calls as T1). T9c covers
#      a HUNG join step specifically -- gate_run=ga-hu89on found that a fast
#      sys.exit(1) stub (T9b) gives zero coverage for an actual stall, since the
#      outer `timeout` and the stub exiting on its own are different code paths.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HQ="$(cd "$HERE/../../../.." && pwd)"
SCRIPT="$HQ/scripts/jev-daily-report.sh"
REPORT="$HQ/scripts/jev_experiment_report.py"
PLIST="$HQ/packs/town-deltas/assets/jev-daily-report.plist"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1: $2"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/out"
cat >"$T/bin/notify" <<'EOF'
#!/bin/bash
{ printf 'CALL'; printf '\nFORCE=%s' "${NOTIFY_FORCE_PUSH:-}"; for a in "$@"; do printf '\n%s' "$a"; done; printf '\n--END--\n'; } >>"$NOTIFY_LOG"
EOF
chmod +x "$T/bin/notify"

# ga-aijm2v.3 (F5): every test below MUST override the gate-verdict join script --
# without this, jev-daily-report.sh's new default ($HQ/scripts/jev_gate_verdict_experiment.py)
# would run for real here: live `gc rig list`, live `bd show`, live git, live production
# quality-gate.jsonl. This stub keeps the whole suite hermetic. RUN_JOIN lets T9 swap in a
# failing stub without touching this default.
cat >"$T/join-ok.py" <<'EOF'
#!/usr/bin/env python3
print("jev_gate_verdict_experiment: considered=0 logged=0 skipped_dup=0 other_skips=0")
EOF
cat >"$T/join-fail.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("jev_gate_verdict_experiment: simulated failure (ga-aijm2v.3 T9)", file=sys.stderr)
sys.exit(1)
EOF
# T9c: a real stall, not a fast exit. Paired with RUN_JOIN_TIMEOUT=1 in the test below
# so proving the kill costs ~1s, never the full 5s sleep.
cat >"$T/join-hang.py" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(5)
print("jev_gate_verdict_experiment: should never get here (ga-aijm2v.3 T9c)")
EOF

# ga-aijm2v.9: the quem-pensa report step. Same hermetic rule as the join: the real
# jev_quem_pensa_report.py would read the LIVE quality-gate.jsonl, so every test runs against
# a stub unless it says otherwise. The stubs answer like the real one: full text by default,
# the short Portuguese block for --resumo-pt.
cat >"$T/qp-ok.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("Quem pensa (so observacao): QP-RESUMO-STUB" if "--resumo-pt" in sys.argv else "QUEM-PENSA FULL REPORT STUB")
EOF
cat >"$T/qp-fail.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("jev_quem_pensa_report: simulated failure (ga-aijm2v.9 T10b)", file=sys.stderr)
sys.exit(1)
EOF
cat >"$T/qp-empty.py" <<'EOF'
#!/usr/bin/env python3
EOF
cat >"$T/qp-hang.py" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(30)
print("QP-HANG-SHOULD-NEVER-BE-PRINTED")
EOF

# ga-aijm2v.7: the preambulo report step. Hermetic for the same reason as the quem-pensa one (the real
# jev_preambulo_report.py reads the LIVE gate log and bd). It is called ONCE with --full-to PATH: the
# stub writes the full text there and prints the short Portuguese block on stdout, like the real one.
cat >"$T/pb-ok.py" <<'EOF'
#!/usr/bin/env python3
import sys
a = sys.argv
if "--full-to" in a:
    open(a[a.index("--full-to") + 1], "w").write("PREAMBULO FULL REPORT STUB\n")
print("Preambulo por tarefa (so observacao): PB-RESUMO-STUB")
EOF
cat >"$T/pb-fail.py" <<'EOF'
#!/usr/bin/env python3
import sys
print("jev_preambulo_report: simulated failure (ga-aijm2v.7 T11b)", file=sys.stderr)
sys.exit(1)
EOF
cat >"$T/pb-empty.py" <<'EOF'
#!/usr/bin/env python3
EOF
cat >"$T/pb-hang.py" <<'EOF'
#!/usr/bin/env python3
import time
time.sleep(30)
print("PB-HANG-SHOULD-NEVER-BE-PRINTED")
EOF

# 2 control + 2 experiment on 2026-09-20: one suppressed by a working Jev
# (300 in / 20 out tokens), one fired because Jev had no credentials.
cat >"$T/log.jsonl" <<'EOF'
{"ts": "2026-09-20T01:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "a", "arm": "control", "jev_ok": false, "jev_error": "control_arm_skips_jev", "jev_tokens_in": 0, "jev_tokens_out": 0, "suppress": false}
{"ts": "2026-09-20T02:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "b", "arm": "control", "jev_ok": false, "jev_error": "control_arm_skips_jev", "jev_tokens_in": 0, "jev_tokens_out": 0, "suppress": false}
{"ts": "2026-09-20T03:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "c", "arm": "experiment", "jev_ok": true, "jev_noul": 0.05, "jev_error": null, "jev_tokens_in": 300, "jev_tokens_out": 20, "suppress": true}
{"ts": "2026-09-20T04:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "d", "arm": "experiment", "jev_ok": false, "jev_error": "no_credentials", "jev_tokens_in": 0, "jev_tokens_out": 0, "suppress": false}
{"ts": "2026-09-21T04:00:00Z", "experiment": "gate-orphaned-label", "entity_id": "e", "arm": "control", "jev_ok": false, "jev_error": "control_arm_skips_jev", "jev_tokens_in": 0, "jev_tokens_out": 0, "suppress": false}
EOF

run() {  # run [date-arg...] with the sandboxed env; sets RC
  : >"$T/notify.log"
  rm -f "$T/out/gate-verdict-join.log"
  env -u NOTIFY_FORCE_PUSH PATH="$T/bin:$PATH" NOTIFY_LOG="$T/notify.log" JEV_EXPERIMENT_LOG="${RUN_LOG:-$T/log.jsonl}" \
      JEV_DAILY_OUT_DIR="$T/out" JEV_REPORT="${RUN_REPORT:-$REPORT}" JEV_GATE_VERDICT_JOIN="${RUN_JOIN:-$T/join-ok.py}" \
      JEV_GATE_VERDICT_JOIN_TIMEOUT="${RUN_JOIN_TIMEOUT:-600}" \
      JEV_QUEM_PENSA_REPORT="${RUN_QP:-$T/qp-ok.py}" JEV_QUEM_PENSA_REPORT_TIMEOUT="${RUN_QP_TIMEOUT:-120}" \
      JEV_PREAMBULO_REPORT="${RUN_PB:-$T/pb-ok.py}" JEV_PREAMBULO_REPORT_TIMEOUT="${RUN_PB_TIMEOUT:-300}" \
      bash "$SCRIPT" "$@" >"$T/stdout" 2>&1
  RC=$?
}
calls() { grep -c '^CALL$' "$T/notify.log"; }

echo "jev-daily-report tests"

# T1
run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T1 exit 0, exactly one ntfy"; else nok "T1 rc/calls" "rc=$RC calls=$(calls) out=$(cat "$T/stdout")"; fi
grep -q 'Jev experiment report — 2026-09-20' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T1 full report written to <out>/2026-09-20.txt" || nok "T1 report file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
case "$N" in *"Jev — fim do dia 2026-09-20 (UTC)"*) ok "T1 ntfy title names the UTC day" ;; *) nok "T1 title" "$N" ;; esac
case "$N" in *"controle 2 alerta(s); experimento 2, dos quais 1 silenciado(s) pelo Jev."*) ok "T1 arm counts" ;; *) nok "T1 arm counts" "$N" ;; esac
case "$N" in *"Redução de alertas (medida): 50,0%."*) ok "T1 measured reduction 50,0%" ;; *) nok "T1 reduction" "$N" ;; esac
case "$N" in *"~3680 = 46,0%."*) ok "T1 estimated tokens ~3680 = 46,0% (1x4000 - 320 Jev tokens, vs 2x4000)" ;; *) nok "T1 estimate" "$N" ;; esac
case "$N" in *"Custo do Jev (medido): 300 + 20 tokens."*) ok "T1 measured Jev cost" ;; *) nok "T1 cost" "$N" ;; esac
case "$N" in *"Jev indisponível em 1 de 2 alerta(s)"*) ok "T1 warns the day's number is understated (Jev unavailable 1/2)" ;; *) nok "T1 unavailable warning" "$N" ;; esac
case "$N" in *"2026-09-21"*) nok "T1 day filter" "another day's event leaked: $N" ;; *) ok "T1 only the requested UTC day is counted" ;; esac
case "$N" in *"FORCE=1"*) ok "T8 the daily result is sent with NOTIFY_FORCE_PUSH=1 (phone, not digest)" ;; *) nok "T8 force push (result)" "$N" ;; esac
grep -q 'considered=0' "$T/out/gate-verdict-join.log" 2>/dev/null \
  && ok "T9 gate-verdict join step ran before the report (join-ok stub's own output captured)" \
  || nok "T9 join ran" "$(cat "$T/out/gate-verdict-join.log" 2>&1)"

# T2
run 2026-09-25
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T2 day without events still sends exactly one ntfy"; else nok "T2 rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"nenhum alerta candidato registrado"*) ok "T2 ntfy says there is no data" ;; *) nok "T2 text" "$N" ;; esac

# T3
RUN_REPORT="$T/does-not-exist.py" run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -ne 0 ] && [ "$(calls)" -eq 1 ]; then ok "T3 failing report -> exit != 0 and one ntfy"; else nok "T3 rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"falhou"*) ok "T3 ntfy says the report failed" ;; *) nok "T3 text" "$N" ;; esac
case "$N" in *"FORCE=1"*) ok "T8 the failure ntfy is also forced to the phone" ;; *) nok "T8 force push (failure)" "$N" ;; esac

# T4
run
N="$(cat "$T/notify.log")"
Y="$(date -u -v-1d +%Y-%m-%d)"
case "$N" in *"fim do dia $Y (UTC)"*) ok "T4 default day = yesterday UTC ($Y)" ;; *) nok "T4 default day" "want $Y, got: $N" ;; esac

# T5
H="$(plutil -extract StartCalendarInterval.Hour raw "$PLIST" 2>/dev/null)"
M="$(plutil -extract StartCalendarInterval.Minute raw "$PLIST" 2>/dev/null)"
P="$(plutil -extract ProgramArguments.1 raw "$PLIST" 2>/dev/null)"
L="$(plutil -extract Label raw "$PLIST" 2>/dev/null)"
if [ "$H" = "21" ] && [ "$M" = "7" ] && [ "$P" = "/Users/athos/gt/.gascity-gastown-hq/scripts/jev-daily-report.sh" ] && [ "$L" = "com.gascity.jev-daily-report" ]; then
  ok "T5 plist: com.gascity.jev-daily-report, daily 21:07, runs the live script path"
else
  nok "T5 plist" "hour=$H minute=$M prog=$P label=$L"
fi

# T6
RUN_LOG="$T/no-such-log.jsonl" run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -ne 0 ] && [ "$(calls)" -eq 1 ]; then ok "T6 missing log -> exit != 0 and one ntfy"; else nok "T6 rc/calls" "rc=$RC calls=$(calls) n=$N"; fi
case "$N" in *"falhou"*) ok "T6 ntfy says the report failed" ;; *) nok "T6 text" "$N" ;; esac
case "$N" in *"nenhum alerta"*) nok "T6 can't-know" "missing log reported as 'no alerts': $N" ;; *) ok "T6 missing log is NOT reported as 'no alerts today'" ;; esac

# T7
run "garbage"
N="$(cat "$T/notify.log")"
if [ "$RC" -ne 0 ] && [ "$(calls)" -eq 1 ]; then ok "T7 garbled day -> exit != 0 and one ntfy"; else nok "T7 rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"Dia inválido"*) ok "T7 ntfy names the invalid day" ;; *) nok "T7 text" "$N" ;; esac
ls "$T/out" | grep -q garbage && nok "T7 no report file" "a report was written for the garbled day" || ok "T7 no report written for the garbled day"

# T9b: a FAILING join script must never block or change the report/ntfy outcome --
# same rc/calls as T1, and the failure is captured in gate-verdict-join.log for a human
# to notice later, never surfaced as a report/ntfy failure.
RUN_JOIN="$T/join-fail.py" run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T9b failing join step still yields exit 0, exactly one ntfy (fail-open)"; else nok "T9b rc/calls" "rc=$RC calls=$(calls)"; fi
grep -q 'Jev experiment report — 2026-09-20' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T9b report still generated despite the join failure" || nok "T9b report file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
grep -q 'simulated failure' "$T/out/gate-verdict-join.log" 2>/dev/null \
  && ok "T9b join failure captured in gate-verdict-join.log" || nok "T9b join failure logged" "$(cat "$T/out/gate-verdict-join.log" 2>&1)"
grep -q 'exited non-zero' "$T/out/gate-verdict-join.log" 2>/dev/null \
  && ok "T9b jev-daily-report.sh itself notes the non-zero exit" || nok "T9b non-zero note" "$(cat "$T/out/gate-verdict-join.log" 2>&1)"

# T9c: a HUNG join step (join-hang.py sleeps 5s) must be killed by the outer bound
# well before it ever returns on its own -- RUN_JOIN_TIMEOUT=1 keeps this test itself
# fast (~1s) while still proving a real process gets terminated, not just a fast exit.
RUN_JOIN="$T/join-hang.py" RUN_JOIN_TIMEOUT=1 run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T9c hung join step still yields exit 0, exactly one ntfy (fail-open)"; else nok "T9c rc/calls" "rc=$RC calls=$(calls)"; fi
grep -q 'Jev experiment report — 2026-09-20' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T9c report still generated despite the join hanging" || nok "T9c report file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
grep -q 'TIMED OUT' "$T/out/gate-verdict-join.log" 2>/dev/null \
  && ok "T9c the hang is captured as TIMED OUT, distinct from an ordinary non-zero exit" || nok "T9c timeout logged" "$(cat "$T/out/gate-verdict-join.log" 2>&1)"
grep -q 'should never get here' "$T/out/gate-verdict-join.log" 2>/dev/null \
  && nok "T9c process actually killed" "join-hang.py's post-sleep line ran -- the process was not terminated" \
  || ok "T9c the hung process was killed before finishing its sleep"

# T10 (ga-aijm2v.9): the quem-pensa block. The generic report/ntfy numbers must be exactly
# T1's whatever happens to the block, and the block must never fail SILENTLY.
# T10a the block reaches the full report file AND the ntfy.
run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T10a exit 0, exactly one ntfy with the quem-pensa step on"; else nok "T10a rc/calls" "rc=$RC calls=$(calls)"; fi
grep -q 'QUEM-PENSA FULL REPORT STUB' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T10a the quem-pensa report is appended to the day's full report file" || nok "T10a report file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
case "$N" in *"QP-RESUMO-STUB"*) ok "T10a the ntfy carries the quem-pensa Portuguese block" ;; *) nok "T10a ntfy block" "$N" ;; esac
case "$N" in *"Redução de alertas (medida): 50,0%."*) ok "T10a the generic numbers are untouched by the extra block" ;; *) nok "T10a generic numbers" "$N" ;; esac
# T10b a FAILING quem-pensa report: fail-open (rc 0, one ntfy, generic report intact) but
# VISIBLE — one line in the ntfy and the file, and the stderr kept in quem-pensa-report.log.
RUN_QP="$T/qp-fail.py" run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T10b failing quem-pensa report still yields exit 0 and exactly one ntfy (fail-open)"; else nok "T10b rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"Quem pensa: relatório falhou"*) ok "T10b the failure is VISIBLE in the ntfy, not a silent absence" ;; *) nok "T10b visible failure" "$N" ;; esac
case "$N" in *"Redução de alertas (medida): 50,0%."*) ok "T10b generic numbers still reported" ;; *) nok "T10b generic numbers" "$N" ;; esac
grep -q 'simulated failure' "$T/out/quem-pensa-report.log" 2>/dev/null \
  && ok "T10b the failure's stderr is kept in quem-pensa-report.log" || nok "T10b stderr kept" "$(cat "$T/out/quem-pensa-report.log" 2>&1)"
# T10c empty output with rc 0 is ALSO a failure: the real report always prints a line, and an
# empty block would read exactly like "nothing to report".
RUN_QP="$T/qp-empty.py" run 2026-09-20
N="$(cat "$T/notify.log")"
case "$N" in *"Quem pensa: relatório falhou"*) ok "T10c an empty quem-pensa report is a visible failure, not silence" ;; *) nok "T10c empty" "$N" ;; esac
# T10d a HUNG quem-pensa report is killed by its own bound and does not stall the ntfy.
T0=$SECONDS
RUN_QP="$T/qp-hang.py" RUN_QP_TIMEOUT=1 run 2026-09-20
ELAPSED=$((SECONDS - T0))
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T10d hung quem-pensa report still yields exit 0 and exactly one ntfy"; else nok "T10d rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"Quem pensa: relatório falhou"*) ok "T10d the hang is a visible failure" ;; *) nok "T10d hang visible" "$N" ;; esac
# The report is called twice (full + --resumo-pt), each bounded at 1s here, so a real kill costs
# a few seconds even on a loaded machine. The stub sleeps 30s per call: an unkilled run would take
# 60s+, so the 20s line separates the two cases with a wide margin (a tight one flaked-by-design
# on this city's saturated CPU). Timing, not just the absence of the marker, so a missing stub
# file cannot pass this vacuously.
if [ "$ELAPSED" -lt 20 ]; then ok "T10d both hung calls were cut by the bound (${ELAPSED}s, not the stub's 30s sleep each)"; else nok "T10d killed" "took ${ELAPSED}s: the hung process was not terminated"; fi
case "$N" in *"QP-HANG-SHOULD-NEVER-BE-PRINTED"*) nok "T10d marker" "the hung process finished its sleep" ;; *) ok "T10d the hung process never printed past its sleep" ;; esac
# T10e a quem-pensa record in the experiment log must NOT reach the generic report. Measured on the
# base code: summarize() files any mode it does not know under the suppression experiment's
# "experiment arm", so the record shows up as a WHOLE EXTRA BLOCK ("quem-pensa-nova: controle 0
# alerta(s); experimento 1 ..." with a bogus negative "tokens economizados"). The other
# experiment's own numbers do not move, so asserting those alone passes on the broken code --
# assert the leaked experiment's ABSENCE, with a positive control that the real block is there.
cp "$T/log.jsonl" "$T/log-qp.jsonl"
cat >>"$T/log-qp.jsonl" <<'EOF'
{"ts": "2026-09-20T05:00:00Z", "mode": "quem-pensa", "experiment": "quem-pensa-nova", "entity_id": "wa-x", "jev_ok": true, "escolha_jev": "facil", "prob_escolha": 0.97, "confianca_jev": 0.95, "modelo_jev": "haiku", "modelo_real": "sonnet", "desfecho_veredito": "PASS", "jev_tokens_in": 400, "jev_tokens_out": 45}
EOF
RUN_LOG="$T/log-qp.jsonl" run 2026-09-20
N="$(cat "$T/notify.log")"
F="$(cat "$T/out/2026-09-20.txt" 2>/dev/null)"
case "$N" in *"controle 2 alerta(s); experimento 2"*) ok "T10e positive control: the real experiment's block is in the ntfy (the fixture was read)" ;; *) nok "T10e control" "$N" ;; esac
case "$N" in *"quem-pensa-nova"*) nok "T10e leak (ntfy)" "a quem-pensa record became its own suppression-experiment block: $N" ;; *) ok "T10e the ntfy has no quem-pensa-nova suppression block" ;; esac
case "$F" in *"## quem-pensa-nova"*) nok "T10e leak (report file)" "a quem-pensa record became a '## quem-pensa-nova' section" ;; *) ok "T10e the full report has no '## quem-pensa-nova' section" ;; esac
case "$N" in *"400 + 45 tokens"*) nok "T10e token leak" "the record's Jev tokens were counted: $N" ;; *) ok "T10e the record's Jev tokens are not counted as suppression cost" ;; esac

# T11 (ga-aijm2v.7): the preambulo block. Same contract as T10: the generic numbers stay exactly T1's
# whatever happens to the block, and the block never fails SILENTLY.
run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T11a exit 0, exactly one ntfy with the preambulo step on"; else nok "T11a rc/calls" "rc=$RC calls=$(calls)"; fi
grep -q 'PREAMBULO FULL REPORT STUB' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T11a the preambulo report is appended to the day's full report file" || nok "T11a report file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
case "$N" in *"PB-RESUMO-STUB"*) ok "T11a the ntfy carries the preambulo Portuguese block" ;; *) nok "T11a ntfy block" "$N" ;; esac
case "$N" in *"QP-RESUMO-STUB"*) ok "T11a the quem-pensa block is still there (the two blocks coexist)" ;; *) nok "T11a coexist" "$N" ;; esac
case "$N" in *"Redução de alertas (medida): 50,0%."*) ok "T11a the generic numbers are untouched by the extra block" ;; *) nok "T11a generic numbers" "$N" ;; esac
RUN_PB="$T/pb-fail.py" run 2026-09-20
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T11b failing preambulo report still yields exit 0 and exactly one ntfy (fail-open)"; else nok "T11b rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"Preâmbulo: relatório falhou"*) ok "T11b the failure is VISIBLE in the ntfy, not a silent absence" ;; *) nok "T11b visible failure" "$N" ;; esac
case "$N" in *"Redução de alertas (medida): 50,0%."*) ok "T11b generic numbers still reported" ;; *) nok "T11b generic numbers" "$N" ;; esac
case "$N" in *"QP-RESUMO-STUB"*) ok "T11b the quem-pensa block survives a preambulo failure" ;; *) nok "T11b qp survives" "$N" ;; esac
grep -q 'simulated failure' "$T/out/preambulo-report.log" 2>/dev/null \
  && ok "T11b the failure's stderr is kept in preambulo-report.log" || nok "T11b stderr kept" "$(cat "$T/out/preambulo-report.log" 2>&1)"
RUN_PB="$T/pb-empty.py" run 2026-09-20
N="$(cat "$T/notify.log")"
case "$N" in *"Preâmbulo: relatório falhou"*) ok "T11c an empty preambulo report is a visible failure, not silence" ;; *) nok "T11c empty" "$N" ;; esac
grep -q 'Preâmbulo: relatório falhou' "$T/out/2026-09-20.txt" 2>/dev/null \
  && ok "T11c ...and the day's file says so too" || nok "T11c file" "$(cat "$T/out/2026-09-20.txt" 2>&1)"
T0=$SECONDS
RUN_PB="$T/pb-hang.py" RUN_PB_TIMEOUT=1 run 2026-09-20
ELAPSED=$((SECONDS - T0))
N="$(cat "$T/notify.log")"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 1 ]; then ok "T11d hung preambulo report still yields exit 0 and exactly one ntfy"; else nok "T11d rc/calls" "rc=$RC calls=$(calls)"; fi
case "$N" in *"Preâmbulo: relatório falhou"*) ok "T11d the hang is a visible failure" ;; *) nok "T11d hang visible" "$N" ;; esac
if [ "$ELAPSED" -lt 20 ]; then ok "T11d the hung call was cut by the bound (${ELAPSED}s, not the stub's 30s sleep)"; else nok "T11d killed" "took ${ELAPSED}s: the hung process was not terminated"; fi
case "$N" in *"PB-HANG-SHOULD-NEVER-BE-PRINTED"*) nok "T11d marker" "the hung process finished its sleep" ;; *) ok "T11d the hung process never printed past its sleep" ;; esac
# T11e a preambulo record in the experiment log must NOT reach the generic report (same leak as T10e:
# summarize() files any mode it does not know under the suppression experiment's "experiment arm").
cp "$T/log.jsonl" "$T/log-pb.jsonl"
cat >>"$T/log-pb.jsonl" <<'EOF'
{"ts": "2026-09-20T05:00:00Z", "mode": "preambulo", "experiment": "preambulo", "entity_id": "ga-x", "bead": "ga-x", "arm": "experiment", "jev_status": "ok", "jev_ok": true, "aplicado": false, "cortadas": ["engine-window-patch"], "jev_tokens_in": 400, "jev_tokens_out": 45}
EOF
RUN_LOG="$T/log-pb.jsonl" run 2026-09-20
N="$(cat "$T/notify.log")"
F="$(cat "$T/out/2026-09-20.txt" 2>/dev/null)"
case "$N" in *"controle 2 alerta(s); experimento 2"*) ok "T11e positive control: the real experiment's block is in the ntfy (the fixture was read)" ;; *) nok "T11e control" "$N" ;; esac
case "$N" in *"experimento 3"*) nok "T11e leak (ntfy)" "a preambulo record was counted as a fired alert: $N" ;; *) ok "T11e the preambulo record is not counted as a suppression alert" ;; esac
case "$F" in *"## preambulo"*) nok "T11e leak (report file)" "a preambulo record became a '## preambulo' section" ;; *) ok "T11e the full report has no '## preambulo' section" ;; esac
case "$N" in *"400 + 45 tokens"*) nok "T11e token leak" "the record's Jev tokens were counted: $N" ;; *) ok "T11e the record's Jev tokens are not counted as suppression cost" ;; esac

echo ""
echo "jev-daily-report tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
