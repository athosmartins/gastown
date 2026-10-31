#!/bin/bash
# third-state-arm-coverage.selftest.sh — ga-r4z4ve: the alarm for "the third-state check is ON but records no arms" (third-state-arm-coverage.py).
#
#   A. answers   the three-way answer on fixtures: covered / the 25/10 incident (conf ON, 12 beads, 2 rows) / no arms file, empty, unreadable / too few runs /
#                the thresholds / a gate log that cannot be read is rc 2, never "0 runs" / conf absent, warn, off, invalid / kill-switch flags / own kill switch
#   B. counting  what is a run (dry runs, closed beads, old, future, beadless are not), per BEAD not per row, the conf-age gate, corrupt / invalid arm rows
#   C. producers the diagnosis parses a line made by the REAL guard block (extracted, run with the guard's own log()), and the arms we count are written by the
#                REAL check (third-state-reads-check.py): the builder's --no-record path never counts as coverage
#   D. alarm     cooldown, a failed delivery is retried and fails the --order run, recovery re-arms, an inconclusive tick keeps the marks, hostile bead ids
#   E. controls  mutants of the detector, each of which one case above must catch (a selftest that cannot fail proves nothing)
# Hermetic: scratch dir only, throw-away git repo, a stub router; needs python3 and git. Env: TSAC_KEEP=1 keeps the scratch dir,
# TSAC_SHOW_KILLS=1 prints which assertion killed each mutant (to see that it died of the intended difference). bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DET="$HERE/third-state-arm-coverage.py"
CHK="$HERE/third-state-reads-check.py"
GUARD="$HERE/quality-gate-guard.sh"
HARDCHECKS="$HERE/gate-hard-checks.sh"
PASS=0; FAILN=0; QUIET=0; CASE_BAD=0
ok()  { if [ "$QUIET" = 1 ]; then :; else PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; fi; }
bad() { if [ "$QUIET" = 1 ]; then CASE_BAD=$((CASE_BAD+1)); printf 'killed by: %s\n' "$(printf '%s' "$1" | cut -c1-170)" >> "$W/kills.log"; else FAILN=$((FAILN+1)); printf '  FAIL %s\n' "$1" >&2; fi; }

[ -r "$DET" ] || { echo "FATAL: $DET not found" >&2; exit 2; }
PY="$(command -v python3)" || { echo "FATAL: python3 missing" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git missing" >&2; exit 2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/third-state-arm-coverage.XXXXXX")" || { echo "FATAL: no scratch dir" >&2; exit 2; }
case "$W" in /?*) ;; *) echo "FATAL: unusable scratch path '$W'" >&2; exit 2 ;; esac
REACHED_END=0
finish() {
  local rc=$?
  chmod -R u+rw "$W" 2>/dev/null
  if [ "${TSAC_KEEP:-0}" = 1 ]; then echo "(kept: $W)"
  elif command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$W" >/dev/null 2>&1; then safe-clean "$W" >/dev/null 2>&1
  else echo "(scratch dir left behind: $W — safe-clean does not cover this location)"; fi
  if [ "$REACHED_END" != 1 ] && [ "$rc" = 0 ]; then echo "FAIL: selftest aborted before its last line" >&2; exit 1; fi
}
trap finish EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset THIRD_STATE_READS_STATE_DIR THIRD_STATE_READS_CHECK THIRD_STATE_ARM_COVERAGE TSAC_WINDOW_H TSAC_SLACK_H TSAC_MIN_RUNS TSAC_MIN_UNCOVERED TSAC_MAX_UNCOVERED_PCT TSAC_SWITCH_MAX_H TSAC_ESCALATE_AFTER_S
NOW=2026-10-31T15:00:00Z
IS_ROOT=0; [ "$(id -u)" = 0 ] && IS_ROOT=1
HAD_PYC=0; [ -d "$HERE/__pycache__" ] && HAD_PYC=1

# the detector runs from a copy dir whose siblings are links: the real scripts are never written to, and a mutant gets the same layout
mkbin() { mkdir -p "$1"; for s in third-state-reads-check.py third-state-report.py; do ln -sf "$HERE/$s" "$1/$s"; done; }
mkbin "$W/bin"; cp "$DET" "$W/bin/third-state-arm-coverage.py"; DETB="$W/bin/third-state-arm-coverage.py"; DETX=""
printf '#!/bin/sh\necho "$*" >> "$TSAC_MAIL"\nexit 0\n' > "$W/router"; chmod +x "$W/router"
cat > "$W/router-fail" <<'EOF'
#!/bin/sh
echo "$*" >> "$TSAC_MAIL"
exit 1
EOF
chmod +x "$W/router-fail"

# ── fixtures: a city is a scratch dir with .gc/; conf is old (no conf-age gate) unless a case says otherwise
NC=0
newcity() { NC=$((NC+1)); C="$W/c$NC-$1"; mkdir -p "$C/.gc/logs"; : > "$C/city.toml"; MAIL="$C/mail.log"; : > "$MAIL"; }   # a NEW dir per call: a mutant re-running a case never inherits its marks
conf() { rm -f "$C/.gc/third-state-reads.conf"; printf '%s\n' "$@" > "$C/.gc/third-state-reads.conf"; TZ=UTC touch -t 202610200000 "$C/.gc/third-state-reads.conf"; }
v() { printf '{"ts":"%s","event":"dispatcher_complete","branch":"b","bead":"%s","rig":"gascity","tier":"CODE","result":"%s","reason":"x","gate_run":"g","dry_run":"%s"}\n' "$1" "$2" "${3:-PASS}" "${4:-0}" >> "$C/.gc/quality-gate.jsonl"; }
runs() { local i=0; while [ "$i" -lt "$2" ]; do i=$((i+1)); v "2026-10-31T10:$(printf '%02d' "$i"):00Z" "$1$i"; done; }   # runs <prefix> <n>: beads <prefix>1..n, all inside the window
arm() { printf '{"bead":"%s","arm":"%s","pct":50,"ts":"%s"}\n' "$1" "${2:-enforce}" "${3:-2026-10-31T09:00:00Z}" >> "$C/.gc/third-state-reads-arms.jsonl"; }
arms() { local i="$2"; while [ "$i" -le "$3" ]; do arm "$1$i" "${4:-enforce}"; i=$((i+1)); done; }   # arms <prefix> <from> <to> [arm]
guardlog() { printf '%s\n' "$@" >> "$C/.gc/logs/quality-gate-guard.log"; }
RC=0; OUT=""; ARGS=""; NOLOCK="--no-lock"
run() {   # run [VAR=val ...]: the detector on $C at $NOW; extra args in $ARGS
  # shellcheck disable=SC2086
  OUT="$(env TSAC_ROUTER="${ROUTER:-$W/router}" TSAC_MAIL="$MAIL" TSAC_STATE_DIR="$C/state" "$@" "$PY" -I "${DETX:-$DETB}" --city "$C" --now "${AT:-$NOW}" $NOLOCK $ARGS 2>&1)"; RC=$?
}
want() {   # want <rc> <label> [pattern the output must match; newlines count as spaces]
  if [ "$RC" != "$1" ]; then bad "$2: rc=$RC, want $1 :: $(printf '%s' "$OUT" | tail -3 | tr '\n' '|' | cut -c1-300)"
  elif [ -n "${3:-}" ] && ! printf '%s' "$OUT" | tr '\n' ' ' | grep -Eq -- "$3"; then bad "$2: rc ok but no /$3/ :: $(printf '%s' "$OUT" | tail -4 | tr '\n' '|' | cut -c1-300)"
  else ok "$2"; fi
}
mails() { local n; n="$(wc -l < "$MAIL" | tr -d ' ')"; [ "$n" = "$1" ] && ok "$2 ($1 mail)" || bad "$2: $n mail(s), want $1"; }
mailhas() { grep -Eq -- "$1" "$MAIL" && ok "$2" || bad "$2: no /$1/ in the mail :: $(head -c 300 "$MAIL")"; }

echo "== A. answers =="
case_covered() { newcity cov; conf mode=enforce enforce_pct=50; runs ga-c 10; arms ga-c 1 5 enforce; arms ga-c 6 10 holdout
  run; want 0 "every bead with a verdict has an arm: rc 0" "com braco: 10 \(enforce 5 / holdout 5\); SEM braco: 0"; mails 0 "...and nobody is mailed"; }
case_incident() { newcity inc; conf mode=enforce enforce_pct=50; runs ga-i 12; arm ga-i1 enforce; arm ga-i2 holdout
  run; want 1 "the 25/10 incident (conf ON, 12 beads with a verdict, 2 arm rows): rc 1" "SEM braco: 10"; mails 1 "...one alarm"; mailhas "10 de 12 beads" "...saying 10 of 12"; }
case_no_file() { newcity nof; conf mode=enforce; runs ga-n 8
  run; want 1 "no arms file at all while ON: rc 1, not 'nothing recorded = fine'" "arquivo de bracos: absent"; mails 1 "...alarmed"
  : > "$C/.gc/third-state-reads-arms.jsonl"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; want 1 "an empty arms file is the same divergence" "ok, 0 linha"
  if [ "$IS_ROOT" = 0 ]; then chmod 000 "$C/.gc/third-state-reads-arms.jsonl"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; chmod 644 "$C/.gc/third-state-reads-arms.jsonl"
    want 1 "an unreadable arms file (chmod 000): every run uncovered, and it says why" "arquivo de bracos: unreadable"; else ok "(root: chmod 000 case skipped)"; fi; }
case_few_runs() { newcity few; conf mode=enforce; runs ga-f 4
  run; want 0 "4 beads, none with an arm: too few to conclude, rc 0" "sem conclusao.*NAO e 'ok'"; mails 0 "...no alarm"
  newcity few5; conf mode=enforce; runs ga-f 5; run; want 1 "5 beads, none with an arm: enough, rc 1" "DIVERGE"; }
case_thresholds() { newcity thr; conf mode=enforce; runs ga-t 20; arms ga-t 1 18
  run; want 0 "2 of 20 uncovered is exactly 10%: not above the limit" "SEM braco: 2"; mails 0 "...no alarm"
  newcity thr3; conf mode=enforce; runs ga-t 20; arms ga-t 1 17; run; want 1 "3 of 20 (15%) is above it" "SEM braco: 3"
  newcity thr1; conf mode=enforce; runs ga-t 6; arms ga-t 1 5; run; want 0 "1 of 6 (17%) is above the percentage but one hole is not 'at least 2'" "SEM braco: 1"
  newcity thre; conf mode=enforce; runs ga-t 20; arms ga-t 1 18; run TSAC_MAX_UNCOVERED_PCT=5; want 1 "the percentage is tunable (5%: 2 of 20 alarms)"
  run TSAC_MAX_UNCOVERED_PCT=garbage; want 0 "a garbage value is the default (10%), never 'no limit'"; }
case_blind() { newcity bl1; conf mode=enforce; rm -f "$C/.gc/quality-gate.jsonl"
  run; want 2 "gate log absent: rc 2 (NAO SEI), never '0 runs'" "NAO SEI.*NAO e 0 runs"; mails 1 "...and a 'blind' alarm"; mailhas "cego|alarme-cego" "...with its own subject"
  newcity bl2; conf mode=enforce; : > "$C/.gc/quality-gate.jsonl"; run; want 2 "gate log empty: rc 2"
  newcity bl3; conf mode=enforce; printf 'garbage not json at all\n{"half": \n' > "$C/.gc/quality-gate.jsonl"; run; want 2 "gate log with only unparseable lines: rc 2"
  if [ "$IS_ROOT" = 0 ]; then newcity bl4; conf mode=enforce; runs ga-b 6; chmod 000 "$C/.gc/quality-gate.jsonl"; run; chmod 644 "$C/.gc/quality-gate.jsonl"; want 2 "gate log unreadable (chmod 000): rc 2"; fi
  newcity bl5; conf mode=enforce; printf '{"ts":"2026-10-31T10:00:00Z","event":"guard_dispatched","bead":"ga-x"}\n' > "$C/.gc/quality-gate.jsonl"; run
  want 0 "a readable log with no verdicts is 'no data' (rc 0, 'sem conclusao'), not NAO SEI" "sem conclusao"; }
case_conf_states() { newcity cs1; runs ga-s 12; run; want 0 "conf absent: nothing is switched on, nothing to cover (12 uncovered beads, no alarm)" "nao ligada"; mails 0 "...no mail"
  newcity cs2; conf mode=warn; runs ga-s 12; run; want 0 "mode=warn draws no arm by design: not alarmed" "nao sorteia braco"; mails 0 "...no mail"
  newcity cs3; conf mode=off; runs ga-s 12; run; want 0 "mode=off: same"
  newcity cs4; conf modee=enforce; run; want 1 "a conf the check cannot parse: rc 1 even with no gate log at all (it answers NAO SEI to every submission)" "CONF QUEBRADA"; mailhas "conf-quebrada" "...alarmed"
  newcity cs5; conf '# nothing but a comment'; run; want 1 "a conf with no keys is invalid, not 'off'" "CONF QUEBRADA"
  newcity cs6; ln -s "$W/no-such-target" "$C/.gc/third-state-reads.conf"; run; want 1 "a dangling-symlink conf is 'unreadable' to the check: broken, never 'absent'" "CONF QUEBRADA"; }
case_switches() { newcity sw1; conf mode=enforce; runs ga-w 12; : > "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610311400 "$C/.gc/third-state-reads-check.off"
  run; want 0 "a fresh kill-switch flag: the check is off on purpose, 12 uncovered beads are not alarmed" "interruptor presente"; mails 0 "...no mail"
  TZ=UTC touch -t 202610250000 "$C/.gc/third-state-reads-check.off"; run; want 1 "the same flag standing 6 days: forgotten, alarmed" "interruptor presente"; mailhas "interruptor-esquecido" "...with its own subject"
  newcity sw2; conf mode=enforce; : > "$C/.gc/gate-hardchecks.off"; TZ=UTC touch -t 202610250000 "$C/.gc/gate-hardchecks.off"; runs ga-w 12; run; want 1 "a stale guard-wide flag (gate-hardchecks.off) is alarmed too"
  newcity sw3; : > "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610250000 "$C/.gc/third-state-reads-check.off"; run; want 0 "a stale flag with the check not even configured: nothing is on, nothing to forget"
  newcity sw4; conf mode=enforce; runs ga-w 12; run THIRD_STATE_ARM_COVERAGE=off; want 0 "own kill switch (env): a loud no-op" "switched OFF"
  : > "$C/.gc/third-state-arm-coverage.off"; rm -f "$C/.gc/quality-gate.jsonl"; run; want 0 "own kill switch (flag file) reads nothing: no gate log needed" "switched OFF"; }
case_covered; case_incident; case_no_file; case_few_runs; case_thresholds; case_blind; case_conf_states; case_switches

echo "== B. counting =="
case_noise() { newcity noise; conf mode=enforce; runs ga-r 6; arms ga-r 1 6
  v 2026-10-31T11:00:00Z ga-dry FAIL 1; v 2026-10-31T11:01:00Z ga-closed SKIPPED_BEAD_CLOSED; v 2026-10-30T12:00:00Z ga-old PASS; v 2026-10-31T16:00:00Z ga-future PASS; v 2026-10-31T11:02:00Z "" PASS
  printf '{"ts":"2026-10-31T11:03:00Z","event":"guard_dispatched","bead":"ga-ev"}\n' >> "$C/.gc/quality-gate.jsonl"
  run; want 0 "dry runs, closed beads, a 26h-old run, a future one, a beadless one and other events are not runs: 6 beads, all covered" "veredito real na janela: 6;"; }
case_per_bead() { newcity pb; conf mode=enforce; runs ga-p 5; arms ga-p 1 5; v 2026-10-31T12:00:00Z ga-p1 FAIL; v 2026-10-31T13:00:00Z ga-p1 PASS
  arm ga-orphan holdout; printf '{"bead":"ga-old","arm":"enforce","ts":"2026-09-01T00:00:00Z"}\n' >> "$C/.gc/third-state-reads-arms.jsonl"; v 2026-10-31T12:30:00Z ga-old PASS
  run; want 0 "a bead with 3 runs counts once; a row from a month ago still covers its bead; a row without a run is not a run: 6 beads, 6 covered" "veredito real na janela: 6; com braco: 6"; }
case_conf_age() { newcity ca1; conf mode=enforce; runs ga-a 12; TZ=UTC touch -t 202610311300 "$C/.gc/third-state-reads.conf"
  run; want 0 "conf changed 2h ago: the window starts 8h after it (in the future): no data, not an alarm" "conf alterada em.*sem conclusao"; mails 0 "...no mail"
  newcity ca2; conf mode=enforce; v 2026-10-30T20:00:00Z ga-before PASS; v 2026-10-30T21:00:00Z ga-before2 PASS; runs ga-a 6; arms ga-a 1 6; TZ=UTC touch -t 202610301900 "$C/.gc/third-state-reads.conf"
  run; want 0 "conf changed at 10-30 19:00: runs before 10-31 03:00 are not counted (their markers may predate the arms): 6 beads, all covered" "veredito real na janela: 6;"; }
case_arm_rows() { newcity ar; conf mode=enforce; runs ga-q 6; ARGS="--no-alarm"
  printf '{"bead": "ga-q1", "arm": "holdou\n{"bead": "ga-q1", "arm": "enforce"}\n' >> "$C/.gc/third-state-reads-arms.jsonl"
  printf 'garbage that names nobody\n[1, 2]\n{"bead": "ga-q2", "arm": "bogus"}\n{"bead": "ga-q9", "arm": "enforce", "ts": "garbage"}\n' >> "$C/.gc/third-state-reads-arms.jsonl"; arms ga-q 3 6
  run; ARGS=""; want 1 "(six beads, four covered, two holes: a finding, --no-alarm only silences the mail)" "com braco: 4"; mails 0 "...and --no-alarm sent nothing"
  printf '%s' "$OUT" | grep -q 'sem braco: ga-q1 (linha-corrompida)' && ok "a corrupt line that names the bead decides: later valid row ignored, like the check (NAO SEI there)" || bad "ga-q1 not reported linha-corrompida :: $OUT"
  printf '%s' "$OUT" | grep -q 'sem braco: ga-q2 (linha-invalida)' && ok "a row with an invalid arm value is not coverage" || bad "ga-q2 not reported linha-invalida"
  printf '%s' "$OUT" | grep -q ', 3 ilegivel' && ok "garbage lines and a non-object JSON line are counted, not dropped" || bad "bad-row count missing :: $(printf '%s' "$OUT" | grep arquivo)"
  printf '%s' "$OUT" | grep -q 'ultima gravacao 2026-10-31T09:00:00Z' && ok "a row whose ts is garbage does not break the last-write time" || bad "last write not shown :: $(printf '%s' "$OUT" | grep arquivo)"; }
case_flags_cannot_stat() { newcity fl; conf mode=enforce; runs ga-l 12; ln -s third-state-reads-check.off "$C/.gc/third-state-reads-check.off"
  run; want 1 "a kill-switch flag that cannot be stat'ed (a symlink loop) is NOT a switch, as in the check and the guard: the divergence is still seen" "DIVERGE"; printf '%s' "$OUT" | grep -q 'ilegivel.*tratado como ausente' && ok "...and the unreadable flag is said" || bad "unreadable flag not announced"
  newcity fl2; conf mode=enforce; runs ga-l 8; arms ga-l 1 8; mkdir "$C/.gc/gate-hardchecks.off"; TZ=UTC touch -t 202610250000 "$C/.gc/gate-hardchecks.off"
  run; want 0 "a DIRECTORY named gate-hardchecks.off is not the guard's flag (it tests -f): no stale-switch alarm" "dentro do limite"; mails 0 "...no mail"; }
case_noise; case_per_bead; case_conf_age; case_arm_rows; case_flags_cannot_stat

echo "== C. producers: the guard's real log line and the check's real rows =="
case_diag() { newcity dg; conf mode=enforce; runs ga-d 6; arms ga-d 1 2
  guardlog "[2026-10-30 09:00:00] [quality-gate-guard] HARDCHECK step=2e verdict=ok reason=x bead=ga-d3 branch=b mode=enforce marker=m checker=[VERDICT=ok step=2e reason=x rc=0 tip=- base=- arm=enforce]" \
    "[2026-10-31 12:00:01] [quality-gate-guard] HARDCHECK step=2e verdict=nao-consegui-medir reason=fetch-falhou bead=ga-d3 branch=b mode=enforce marker=m checker=[VERDICT=nao-consegui-medir step=2e reason=fetch-falhou rc=- tip=- base=- arm=-]" \
    "[2026-10-31 12:00:02] [quality-gate-guard] HARDCHECK step=2e verdict=nao-consegui-medir reason=entrada-nao-resolvida bead=ga-d4 branch=b mode=enforce marker=m checker=[<EMPTY>]" \
    "[2026-10-31 12:00:03] [quality-gate-guard] HARDCHECK step=2c verdict=ok reason=x bead=ga-d5 branch=b mode=enforce marker=m checker=[VERDICT=ok step=2c reason=x rc=0 tip=- base=- arm=-]"
  run; want 1 "diagnosis from the guard log" "nao-consegui-medir/fetch-falhou \(o log diz arm=-\) x1"
  printf '%s' "$OUT" | grep -q 'ok/x (o log diz arm=enforce)' && bad "an older line must not win over the newest one for ga-d3" || ok "the NEWEST HARDCHECK line of a bead wins"
  printf '%s' "$OUT" | grep -q 'entrada-nao-resolvida (o log diz arm=?)' && ok "a line whose checker answered nothing (checker=[<EMPTY>]) is still read: arm=?" || bad "ga-d4's line not parsed"
  printf '%s' "$OUT" | grep -q 'sem linha HARDCHECK 2e no log.* x2' && ok "beads with no 2e line (ga-d5 has only a 2c line) are said to have none" || bad "missing-line count wrong :: $OUT"
  rm -f "$C/.gc/logs/quality-gate-guard.log"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; want 1 "no guard log: the verdict stands, the diagnosis says it is unavailable" "diagnostico pelo log do guard indisponivel"
  if [ "$IS_ROOT" = 0 ]; then mkdir -p "$C/.gc/logs/quality-gate-guard.log"; run; rmdir "$C/.gc/logs/quality-gate-guard.log"; want 1 "an unreadable guard log (a directory): same" "indisponivel"; fi; }
case_log_tail() { newcity lt; conf mode=enforce; runs ga-d 6
  guardlog "[2026-10-31 08:00:00] [quality-gate-guard] HARDCHECK step=2e verdict=nao-consegui-medir reason=fetch-falhou bead=ga-d1 branch=b mode=enforce marker=m checker=[<EMPTY>]"
  i=0; while [ "$i" -lt 40 ]; do i=$((i+1)); guardlog "[2026-10-31 09:00:$(printf '%02d' $((i % 60)))] [quality-gate-guard] sweep $i: nothing to do, a filler line long enough to push the first one out of a short tail"; done
  run; want 1 "the whole guard log is read by default" "fetch-falhou"; run TSAC_LOG_TAIL_BYTES=1000; want 1 "only the tail is read when it is capped: the line that scrolled out is gone, all 6 beads are said to have none" "rodou para ele, ou o log girou\) x6"; }
case_diag; case_log_tail
mkdir -p "$W/hc"; sed -n '/^# SELFTEST-EXTRACT hardchecks: BEGIN$/,/^# SELFTEST-EXTRACT hardchecks: END$/p' "$GUARD" | sed '1d;$d' > "$W/hc/block.sh"
grep -E '^log\(\) +\{' "$GUARD" > "$W/hc/log.sh"
printf 'set -euo pipefail\n. "$HC_LOG"\nerr() { :; }\nset_gate_status() { :; }\nbd() { :; }\n. "$HC_BLOCK"\n' > "$W/hc/driver.sh"
case_real_guard_line() { newcity rg; conf mode=enforce; runs ga-real 6
  env HC_LOG="$W/hc/log.sh" HC_BLOCK="$W/hc/block.sh" GC_CITY="$C" MARKER_ID=ga-marker BEAD_ID=ga-real3 BRANCH=fix/x RIG_PATH="" bash "$W/hc/driver.sh" > "$C/.gc/logs/quality-gate-guard.log" 2>/dev/null
  grep -q 'HARDCHECK step=2e' "$C/.gc/logs/quality-gate-guard.log" && ok "the REAL guard block (extracted, its own log()) printed its 2e line" || bad "the extracted guard block printed no 2e line"
  run; want 1 "a line made by the real guard block is parsed" "nao-consegui-medir/entrada-nao-resolvida \(o log diz arm=\?\) x1"; }
case_real_guard_line
grep -qF 'HARDCHECK step=$_HC_STEP verdict=$_HC_V reason=${_HC_R:-<EMPTY>} bead=${BEAD_ID:-<EMPTY>} ' "$GUARD" && ok "pin: the guard still logs 'HARDCHECK step= verdict= reason= bead=' in this order" || bad "the guard's HARDCHECK log format changed: update GUARD_LINE in the detector"
grep -qF "printf 'VERDICT=%s step=%s reason=%s rc=%s tip=%s base=%s arm=%s" "$HARDCHECKS" && ok "pin: the checker still ends its VERDICT line with arm=" || bad "gate-hard-checks.sh VERDICT format changed: update the arm= read in the detector"
"$PY" -B -I -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("t", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
assert m.MODES == ("enforce", "warn", "off") and m.ARMS == "third-state-reads-arms.jsonl" and m.CONF == "third-state-reads.conf" and m.KILL == "third-state-reads-check.off", (m.MODES, m.ARMS)
' "$CHK" 2>"$W/pin.err" && ok "pin: the check still has the modes and file names this detector relies on" || bad "the check's contract changed: $(cat "$W/pin.err")"
case_real_check() { newcity rc; conf mode=enforce enforce_pct=50; R="$W/repo-real"; mkdir -p "$R"; git -C "$R" init -q -b main && printf 'a\n' > "$R/a.txt" && git -C "$R" add a.txt && git -C "$R" commit -q -m a
  runs ga-real 12; i=0; while [ "$i" -lt 12 ]; do i=$((i+1)); "$PY" -I "$CHK" --repo "$R" --base main --head main --city "$C" --bead "ga-real$i" >/dev/null 2>&1; done
  run; want 0 "12 beads through the REAL check (--bead, recording): all covered, rc 0" "com braco: 12 .*SEM braco: 0"
  printf '%s' "$OUT" | grep -Eq 'enforce [1-9][0-9]* / holdout [1-9]' && ok "...both arms were drawn at 50%" || bad "arm split not shown :: $(printf '%s' "$OUT" | grep 'veredito real')"
  runs ga-nr 6; i=0; while [ "$i" -lt 6 ]; do i=$((i+1)); "$PY" -I "$CHK" --repo "$R" --base main --head main --city "$C" --bead "ga-nr$i" --no-record >/dev/null 2>&1; done
  run; want 1 "6 more beads that only ran the builder's --no-record path: they never count as coverage (6 of 18)" "SEM braco: 6"
  rm -f "$C/.gc/third-state-reads-arms.jsonl"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; want 1 "the arms file deleted behind the check's back: rc 1" "arquivo de bracos: absent"; }
case_real_check

echo "== D. alarm mechanics =="
case_cooldown() { newcity cd; conf mode=enforce; runs ga-k 12
  run; mails 1 "tick 1: alarmed"; AT=2026-10-31T15:30:00Z run; mails 1 "tick 2, half an hour later: deduped (cooldown 24h)"
  AT=2026-10-31T15:30:00Z run TSAC_ESCALATE_AFTER_S=1500; mails 2 "the cooldown is tunable: 30 min later with a 25-min cooldown it alarms again"
  AT=2026-10-31T15:31:00Z run TSAC_ESCALATE_AFTER_S=1500; mails 2 "...and the re-alarm restarted the clock"; AT=""; }
case_failed_delivery() { newcity fd; conf mode=enforce; runs ga-k 12; ARGS="--order"
  ROUTER="$W/router-fail" run; want 2 "--order: a delivery that failed makes the order run fail (rc 2)" "ALARME NAO ENTREGUE"
  [ ! -s "$C/state/third-state-arm-coverage-seen.json" ] || ! grep -q diverge "$C/state/third-state-arm-coverage-seen.json" && ok "...and is NOT recorded as sent" || bad "a failed delivery was recorded as sent"
  : > "$MAIL"; ROUTER="$W/router" run; want 0 "next tick, router back: --order rc 0" ; mails 1 "...and the alarm that failed is retried (it was never marked)"
  AT=2026-10-31T15:10:00Z run; mails 1 "...then deduped"; ARGS=""; ROUTER=""; }
case_rearm() { newcity ra; conf mode=enforce; runs ga-k 12
  run; mails 1 "tick 1: alarmed"; arms ga-k 1 12; AT=2026-10-31T16:00:00Z run; want 0 "tick 2: arms recorded, covered" "dentro do limite"
  rm -f "$C/.gc/third-state-reads-arms.jsonl"; AT=2026-10-31T17:00:00Z run; mails 2 "tick 3: broken again INSIDE the cooldown of tick 1: alarmed at once (the clean tick forgot the mark)"; AT=""; }
case_inconclusive_keeps() { newcity ik; conf mode=enforce; runs ga-k 12
  run; mails 1 "tick 1: alarmed"; head -2 "$C/.gc/quality-gate.jsonl" > "$C/gl.tmp"; cp "$C/.gc/quality-gate.jsonl" "$C/gl.full"; cp "$C/gl.tmp" "$C/.gc/quality-gate.jsonl"
  AT=2026-10-31T16:00:00Z run; want 0 "tick 2: only 2 beads in the window, cannot conclude" "sem conclusao"
  cp "$C/gl.full" "$C/.gc/quality-gate.jsonl"; AT=2026-10-31T17:00:00Z run; mails 1 "tick 3: broken again, the 'could not judge' tick kept the mark: still deduped"; AT=""; }
case_seen_garbage() { newcity sg; conf mode=enforce; runs ga-k 12; mkdir -p "$C/state"; printf 'this is not json {{{' > "$C/state/third-state-arm-coverage-seen.json"
  run; mails 1 "a corrupt seen-file is read as empty: the alarm still goes out (one repeat at worst, never a swallowed one)"; "$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "diverge" in d' "$C/state/third-state-arm-coverage-seen.json" && ok "...and the file is rewritten" || bad "seen-file not repaired"; }
case_fallback_and_hostile() { newcity fh; conf mode=enforce; : > "$C/gc.calls"; printf '#!/bin/sh\necho "gc $*" >> "%s"\nexit 0\n' "$C/gc.calls" > "$C/gc"; chmod +x "$C/gc"
  v 2026-10-31T10:00:00Z 'ga-evil\"; touch /tmp/pwned; echo \"' PASS; runs ga-h 8
  run TSAC_ROUTER="$C/no-such-router" GC_BIN="$C/gc"; grep -q 'gc mail send mayor' "$C/gc.calls" && ok "no router: falls back to gc mail send mayor" || bad "fallback not used :: $(cat "$C/gc.calls")"
  EVIL="$(printf '%s' 'ga-evil"; touch /tmp/pwned; echo "' | sed 's/[^A-Za-z0-9._:-]/?/g')"
  grep -qF -- "$EVIL" "$C/gc.calls" && ok "a hostile bead id is cleaned to id characters before it reaches the mail" || bad "bead id not sanitised :: $(head -c 400 "$C/gc.calls")"
  LC_ALL=C grep -q '[^ -~]' "$C/gc.calls" && bad "the mail text must be plain ASCII" || ok "the mail text is plain ASCII"; }
printf '#!/no/such/interpreter\n' > "$W/router-bad"; chmod +x "$W/router-bad"
printf '#!/bin/sh\nsleep 5\nexit 0\n' > "$W/router-slow"; chmod +x "$W/router-slow"
case_delivery_errors() { newcity de; conf mode=enforce; runs ga-k 12; ARGS="--order"
  ROUTER="$W/router-bad" run; want 2 "a router that cannot even start (bad interpreter): not delivered, the order run fails" "ALARME NAO ENTREGUE"
  ROUTER="$W/router-slow" run TSAC_DELIVER_TIMEOUT_S=1; want 2 "a router that hangs past the delivery timeout: not delivered, the order run fails" "ALARME NAO ENTREGUE"; ARGS=""; ROUTER=""
  if [ "$IS_ROOT" = 0 ]; then newcity de2; conf mode=enforce; runs ga-k 12; mkdir -p "$C/state"; echo '{}' > "$C/state/third-state-arm-coverage-seen.json"; chmod 000 "$C/state/third-state-arm-coverage-seen.json"
    run; chmod 644 "$C/state/third-state-arm-coverage-seen.json"; mails 1 "an unreadable seen-file: read as empty, the alarm goes out"; printf '%s' "$OUT" | grep -q 'nao gravei' && ok "...and the failed write of the marks is said (a repeat next tick, never silence)" || bad "failed write not said :: $OUT"; fi; }
case_cli_edges() { newcity ce; conf mode=enforce; runs ga-k 8
  AT=not-a-time run; want 64 "an invalid --now is a usage error (64), not a run" "inv"
  OUT="$(env -u GC_CITY_PATH -u GC_CITY "$PY" -I "${DETX:-$DETB}" --city "$W/no-such-city" 2>&1)"; RC=$?; want 2 "a city that does not exist: NAO SEI (rc 2), nothing read" "cidade n"
  mkdir -p "$C/.gc/runtime"; "$PY" -I -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(6)' "$C/.gc/runtime/third-state-arm-coverage.lock" > "$C/held.out" &
  i=0; while [ "$i" -lt 50 ] && ! grep -q held "$C/held.out" 2>/dev/null; do i=$((i+1)); sleep 0.1; done
  NOLOCK=""; run; want 2 "another instance holds the lock: the CLI run says it did NOT run (rc 2), never a clean 0" "outra inst"; ARGS="--order"; run; want 0 "...and the order tick just leaves (rc 0): the holder covers this round" "saindo"; ARGS=""
  wait; newcity ce2; conf mode=enforce; runs ga-k 8; : > "$C/.gc/runtime"; NOLOCK=""; run; want 2 "a lock that cannot be created: NAO SEI (rc 2), never 'ran fine'" "lock"; NOLOCK="--no-lock"; }
case_cooldown; case_failed_delivery; case_rearm; case_inconclusive_keeps; case_seen_garbage; case_fallback_and_hostile; case_delivery_errors; case_cli_edges
case_crash_and_siblings() { local SRC="${DETX:-$DET}"; newcity cr; conf mode=enforce; runs ga-k 8; mkbin "$W/bin-crash"; rm -f "$W/bin-crash/third-state-report.py"
  printf 'def read_jsonl(p):\n    raise RuntimeError("boom")\ndef verdicts(r):\n    return ([], 0, 0, 0)\n' > "$W/bin-crash/third-state-report.py"; cp "$SRC" "$W/bin-crash/third-state-arm-coverage.py"
  DETX="$W/bin-crash/third-state-arm-coverage.py"; run; DETX=""; want 2 "a crash inside the detector is rc 2 (NAO SEI), never rc 1 (a finding)" "internal error: RuntimeError"
  mkbin "$W/bin-nosib"; rm -f "$W/bin-nosib/third-state-reads-check.py"; cp "$SRC" "$W/bin-nosib/third-state-arm-coverage.py"; DETX="$W/bin-nosib/third-state-arm-coverage.py"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; DETX=""
  want 2 "a missing sibling script is blind (rc 2), not 'no conf'" "NAO SEI"; mailhas "cego|irmaos|carregar" "...and alarmed"; }
case_crash_and_siblings
if [ ! -d "$W/bin/__pycache__" ] && { [ "$HAD_PYC" = 1 ] || [ ! -d "$HERE/__pycache__" ]; }; then ok "no __pycache__ written next to the detector or its siblings"; else bad "the detector left a __pycache__ behind"; fi
ORDER_TOML="$HERE/../orders/third-state-arm-coverage.toml"
if "$PY" -I -c 'import tomllib' 2>/dev/null; then
  "$PY" -I -c '
import sys, tomllib
o = tomllib.load(open(sys.argv[1], "rb"))["order"]
assert o["trigger"] == "cooldown" and o["interval"] == "1h" and "third-state-arm-coverage.py --order" in o["exec"], o
' "$ORDER_TOML" && ok "the order is valid TOML, hourly, and runs the detector with --order" || bad "orders/third-state-arm-coverage.toml is wrong"
else   # python < 3.11 (the stock macOS one): the same facts, read as text
  grep -q '^trigger = "cooldown"$' "$ORDER_TOML" && grep -q '^interval = "1h"$' "$ORDER_TOML" && grep -q '^exec = ".*third-state-arm-coverage.py --order"$' "$ORDER_TOML" && ok "the order is hourly and runs the detector with --order (read as text: this python has no tomllib)" || bad "orders/third-state-arm-coverage.toml is wrong"
fi
[ -x "$DET" ] && ok "the detector is executable (the order runs it directly)" || bad "the detector is not executable"

echo "== E. controls: mutants of the detector that one case above must catch =="
mutant() {   # mutant <name> <old> <new> <case function>: <old> must occur exactly once; the case must FAIL against the mutant
  local name="$1" dir="$W/mut-$1"; mkbin "$dir"
  "$PY" -I -c 'import sys; s = open(sys.argv[1], encoding="utf-8").read(); assert s.count(sys.argv[3]) == 1, sys.argv[3]; open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4]))' \
    "$DET" "$dir/third-state-arm-coverage.py" "$2" "$3" 2>"$W/mut.err" || { bad "mutant $name: the swap did not apply exactly once (the control is void) :: $(tail -1 "$W/mut.err")"; return; }
  : > "$W/kills.log"; DETX="$dir/third-state-arm-coverage.py"; QUIET=1; CASE_BAD=0; "$4" >/dev/null 2>&1; QUIET=0; DETX=""
  [ "$CASE_BAD" -gt 0 ] && ok "mutant $name is caught by $4" || bad "mutant $name SURVIVED $4"
  if [ "${TSAC_SHOW_KILLS:-0}" = 1 ]; then head -2 "$W/kills.log" | sed 's/^/        /'; fi
}
mutant missing_is_covered 'if arms.get(b) not in ARM_VALUES)' 'if b in arms and arms.get(b) not in ARM_VALUES)' case_incident
mutant warn_alarms 'elif mode != "enforce":' 'elif False:' case_conf_states
mutant no_floor 'if n < a.min_runs:' 'if False:' case_few_runs
mutant pct_ge '100 * u > a.max_pct * n' '100 * u >= a.max_pct * n' case_thresholds
mutant no_min_holes 'elif u >= a.min_uncovered and 100 * u' 'elif 100 * u' case_thresholds
mutant blind_is_zero 'if gs != "ok" or not rows:' 'if gs == "ok" and not rows:' case_blind
mutant window_open 'if lo <= t <= now and d["bead"].strip():' 'if t <= now and d["bead"].strip():' case_noise
mutant no_conf_age 'if conf_t + datetime.timedelta(hours=a.slack_h) > lo:' 'if False:' case_conf_age
mutant per_row 'runs.setdefault(d["bead"], t)' 'runs[d["bead"] + str(t)] = t' case_per_bead
mutant corrupt_skipped 'out[b] = "linha-corrompida"' 'pass' case_arm_rows
mutant bogus_arm_ok 'else "linha-invalida"' 'else d.get("arm")' case_arm_rows
mutant conf_broken_absent 'elif st != "ok":' 'elif False:' case_conf_states
mutant stale_never 'if age > a.switch_max_h * 3600:' 'if False:' case_switches
mutant no_dedup 'if isinstance(last, int) and last and t - last < escalate_s:' 'if False:' case_cooldown
mutant record_failed 'print("third-state-arm-coverage: ALARME NAO ENTREGUE (rc=%s) key=' 'keep[k] = t; print("third-state-arm-coverage: ALARME NAO ENTREGUE (rc=%s) key=' case_failed_delivery
mutant swallow_failure 'return (RC_UNKNOWN if failed else RC_OK) if a.order else res["rc"]' 'return RC_OK if a.order else res["rc"]' case_failed_delivery
mutant never_forget 'keep = {k: v for k, v in seen.items() if k in res["alarms"] or any(k.split("|")[0] == p for p in res["unevaluated"])}' 'keep = dict(seen)' case_rearm
mutant forget_unjudged 'any(k.split("|")[0] == p for p in res["unevaluated"])' 'False' case_inconclusive_keeps
mutant crash_is_finding 'sys.exit(RC_UNKNOWN)' 'sys.exit(RC_FOUND)' case_crash_and_siblings
mutant no_sanitise 'return re.sub(r"[^A-Za-z0-9._:-]", "?", str(x))[:60]' 'return str(x)' case_fallback_and_hostile
mutant guard_line_any_step 'HARDCHECK step=2e verdict=(\S+)' 'HARDCHECK step=2. verdict=(\S+)' case_diag
mutant unreadable_flag_counts 'return None, "interruptor %s ilegivel (%s): tratado como ausente, como a checagem faz" % (os.path.basename(path), type(e).__name__)' 'return 0, ""' case_flags_cannot_stat
mutant dir_is_a_flag 'if regular and not stat.S_ISREG(st.st_mode):' 'if False:' case_flags_cannot_stat
mutant tail_ignored 'fh.seek(max(0, fh.tell() - tail))' 'fh.seek(0)' case_log_tail
mutant oserror_uncaught 'except (OSError, subprocess.SubprocessError):' 'except (subprocess.SubprocessError):' case_delivery_errors
mutant timeout_ignored 'timeout=timeout_s' 'timeout=300' case_delivery_errors
mutant no_lock 'fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)' 'pass' case_cli_edges
mutant oldest_line_wins 'if m and m.group(3) in beads:' 'if m and m.group(3) in beads and m.group(3) not in out:' case_diag

echo "selftest: $PASS passed, $FAILN failed"
REACHED_END=1
[ "$FAILN" = 0 ]
