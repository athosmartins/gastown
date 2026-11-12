#!/bin/bash
# third-state-arm-coverage.selftest.sh — ga-r4z4ve: the alarm for "the third-state check is ON but records no arms" (third-state-arm-coverage.py).
#
#   A. answers   the three-way answer on fixtures: covered / the 25/10 incident (conf ON, 12 beads, 2 rows) / no arms file, empty, unreadable / too few runs /
#                the thresholds / a gate log that cannot be read is rc 2, never "0 runs" / conf absent, warn, off, invalid / kill-switch flags / own kill switch
#   B. counting  what is a run (dry runs, closed beads, old, future are not), per BEAD not per row, the conf-age gate, corrupt / invalid arm rows,
#                and a gate log that is only PARTLY readable (unparseable lines, verdicts with no usable ts/bead, an empty bead): NAO SEI unless provably before
#                the window (gate-fix 1: 40 truncated lines used to read as "dentro do limite"); the detector's reader pinned to the report's own reader
#   C. producers the diagnosis parses a line made by the REAL guard block (extracted, run with the guard's own log()), and the arms we count are written by the
#                REAL check (third-state-reads-check.py): the builder's --no-record path never counts as coverage
#   D. alarm     cooldown, a failed delivery is retried and fails the --order run, recovery re-arms, an inconclusive tick keeps the marks (also the one that
#                returned early and the one that could only read the log in part), hostile bead ids, a sibling that dies at import in any way
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
  run; want 2 "gate log absent: rc 2 (NAO SEI), never '0 runs'" "NAO SEI.*NAO e 0 runs"; mails 1 "...and a 'blind' alarm"; mailhas "alarme-cego -- nao consegui ler quality-gate.jsonl" "...with its own subject"
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
  v 2026-10-31T11:00:00Z ga-dry FAIL 1; v 2026-10-31T11:01:00Z ga-closed SKIPPED_BEAD_CLOSED; v 2026-10-30T12:00:00Z ga-old PASS; v 2026-10-31T16:00:00Z ga-future PASS
  v 2026-10-30T12:05:00Z "" PASS; v 2026-10-31T16:05:00Z "" FAIL   # a verdict with an empty bead is only a gap while it is inside the window (case_gate_log_gaps)
  printf '{"ts":"2026-10-31T11:03:00Z","event":"guard_dispatched","bead":"ga-ev"}\n' >> "$C/.gc/quality-gate.jsonl"
  run; want 0 "dry runs, closed beads, a 26h-old run, a future one, beadless ones outside the window and other events are not runs: 6 beads, all covered" "veredito real na janela: 6;"; }
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
# A gate log that is only PARTLY readable (ga-r4z4ve gate-fix 1). junk <line>... appends raw lines; trunc <n> [dated] appends n dispatcher_complete lines cut off mid-write
# (dated: the ts survived, inside the window; otherwise the cut came before it). A run the detector cannot read is never "fewer runs": NAO SEI, unless it is provably old.
junk() { printf '%s\n' "$@" >> "$C/.gc/quality-gate.jsonl"; }
trunc() { local i=0; while [ "$i" -lt "$1" ]; do i=$((i+1))
  if [ "${2:-}" = dated ]; then printf '{"ts":"2026-10-31T11:%02d:00Z","event":"dispatcher_complete","branch":"b","bead":"ga-tr%d\n' "$i" "$i" >> "$C/.gc/quality-gate.jsonl"
  else printf '{"event":"dispatcher_complete","branch":"b","bead":"ga-tr%d\n' "$i" >> "$C/.gc/quality-gate.jsonl"; fi; done; }
case_gate_log_gaps() { local row
  newcity gp1; conf mode=enforce; runs ga-g 6; arms ga-g 1 5
  run; want 0 "baseline: 6 beads, 5 arms, one hole (below 'at least 2'): within the limit" "dentro do limite"; mails 0 "...no mail"
  trunc 40 dated
  run; want 2 "the same log + 40 truncated lines dated inside the window (the gate's repro): NAO SEI, rc 2" "NAO SEI.*40 linha\(s\) ilegivel\(is\): 40 com ts dentro da janela"
  printf '%s' "$OUT" | grep -q 'dentro do limite' && bad "...it must not claim 'cobertura dentro do limite' over 40 lines it could not read" || ok "...and it does not claim 'cobertura dentro do limite'"
  mailhas "alarme-cego -- quality-gate.jsonl tem trechos" "...with its own blind mail"
  newcity gp2; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; trunc 3
  run; want 2 "3 truncated lines with no ts of their own, last in the file: nothing proves them old, NAO SEI" "3 sem data propria que nao da para provar"
  newcity gp3; conf mode=enforce; v 2026-06-04T10:00:00Z ga-june1; trunc 18
  junk '{"ts":"2026-06-04T10:30:00Z","event":"dispatcher_comp' '{"ts":"2026-06-04T10:31:00Z","ev'; v 2026-06-04T11:00:00Z ga-june2; runs ga-g 6; arms ga-g 1 6
  run; want 0 "20 old unreadable lines (18 with no ts, 2 dated June) between June rows, as in the live city: provably old, rc 0" "dentro do limite"
  printf '%s' "$OUT" | grep -q '20 provadamente anteriores' && ok "...and said, not hidden" || bad "old unreadable lines not said :: $(printf '%s' "$OUT" | grep ilegivel)"
  newcity gp4; conf mode=enforce; v 2026-06-04T10:00:00Z ga-june1; trunc 2; runs ga-g 6; arms ga-g 1 6
  run; want 2 "2 lines with no ts whose NEXT readable row is inside the window may be from inside it: NAO SEI" "2 sem data propria"
  newcity gp5; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; junk '{"ts":"2026-10-29T08:00:00Z","event":"dispatcher_comp' '{"ts":"2026-10-31T16:30:00Z","event":"dispatcher_comp'
  run; want 0 "a truncated line dated before the window, and one dated after now, cannot be a run in it: rc 0" "dentro do limite"
  newcity gp6; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; junk '{"ts":"2026-13-45T25:61:61Z","event":"dispatcher_comp'
  run; want 2 "a truncated line whose ts has the right shape but is no date (month 13) is undated: NAO SEI, not a crash" "1 sem data propria"
  newcity gp7; conf mode=enforce; runs ga-g 3; trunc 2 dated
  run; want 2 "too few beads (3) AND unreadable lines in the window: NAO SEI, not 'sem conclusao' with rc 0 (the lines may be the other runs)" "NAO SEI"
  printf '%s' "$OUT" | grep -q 'sem conclusao' && bad "...it must not say 'sem conclusao: poucos beads' as if it had counted them" || ok "...and it does not say 'poucos beads'"
  newcity gp8; conf mode=enforce; runs ga-g 12; trunc 3 dated
  run; want 1 "12 beads without an arm + 3 unreadable lines: still a divergence, rc 1" "DIVERGE"; mails 1 "...one mail"
  mailhas "ATENCAO: quality-gate.jsonl: 3 linha\(s\) ilegivel.*pode ser maior" "...which says the real number may be larger"
  for row in '{"event":"dispatcher_complete","bead":"ga-nots","result":"PASS","dry_run":"0"}' '{"ts":"yesterday","event":"dispatcher_complete","bead":"ga-nots","result":"FAIL","dry_run":"0"}' \
             '{"ts":12345,"event":"dispatcher_complete","bead":"ga-nots","result":"PASS","dry_run":"0"}' '{"ts":"2026-10-31T11:30:00Z","event":"dispatcher_complete","bead":7,"result":"PASS","dry_run":"0"}'; do
    newcity gp9; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; junk "$row"
    run; want 2 "a PASS|FAIL verdict whose ts or bead cannot be used (${row:0:44}...) may be a run: NAO SEI" "1 veredito\(s\) sem ts/bead legivel"
  done
  newcity gp10; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; junk '{"event":"guard_dispatched","bead":"ga-x"}' '{"event":"dispatcher_complete","bead":"ga-nots","result":"SKIPPED_BEAD_CLOSED"}' '{"event":"dispatcher_complete","bead":"ga-nots","result":"PASS","dry_run":"1"}'
  run; want 0 "rows with no ts that are NOT a real PASS|FAIL verdict (another event, SKIPPED, a dry run) are not runs: rc 0" "dentro do limite"
  newcity gp11; conf mode=enforce; v 2026-06-04T10:00:00Z ga-june1; junk '{"event":"dispatcher_complete","bead":"ga-nots","result":"PASS","dry_run":"0"}'; v 2026-06-04T11:00:00Z ga-june2; runs ga-g 6; arms ga-g 1 6
  run; want 0 "a verdict with no ts between two June rows is placed by them: old, rc 0" "dentro do limite"
  printf '%s' "$OUT" | grep -q '1 provadamente anteriores' && ok "...and said" || bad "old verdict without ts not said :: $(printf '%s' "$OUT" | grep veredito)"
  newcity gp12; conf mode=enforce; runs ga-g 6; arms ga-g 1 6; v 2026-10-31T11:30:00Z "" FAIL
  run; want 2 "a real verdict with an EMPTY bead (the dispatcher could not read the marker) inside the window is a run nobody can name: NAO SEI" "1 veredito\(s\) com bead vazio na janela"; }
# The detector reads the gate log itself (it needs the file order, which report.read_jsonl throws away): it must call the same lines rows, bad and dated.
case_reader_parity() { newcity rp; conf mode=enforce; runs ga-p 3
  junk '' '   ' 'not json' '[1, 2]' '7' 'null' '"a string"' '{"ts":"2026-10-31T11:00:00Z","event":"disp' '{"event":"no ts' '{"ts":"2026-10-31T11:10:00Z"}' '{"event":"dispatcher_complete","bead":"ga-nots","result":"PASS"}' '{"ts":"bad","event":"dispatcher_complete","bead":"ga-b","result":"FAIL"}'
  printf 'crlf line\r\n{"ts":"2026-10-31T11:20:00Z","event":"x"}\r\n' >> "$C/.gc/quality-gate.jsonl"
  printf '\377\376 not utf8 {"ts":"2026-10-31T11:21:00Z"\n' >> "$C/.gc/quality-gate.jsonl"
  printf 'a\vb {"ts":"2026-10-31T11:22:00Z","e\n' >> "$C/.gc/quality-gate.jsonl"
  v 2026-10-31T11:30:00Z ga-p9
  "$PY" -B -I -c '
import datetime, importlib.util, sys
def load(p, n):
    s = importlib.util.spec_from_file_location(n, p); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
det, rep = load(sys.argv[1], "d"), load(sys.argv[2], "r")
path = sys.argv[3]
gs, items = det.read_gate_log(path, rep)
st, rows, bad, bad_ts = rep.read_jsonl(path)
assert gs == st == "ok", (gs, st)
assert [x for k, x in items if k == "row"] == rows, "the two readers disagree on which lines are rows"
assert sum(1 for k, _ in items if k == "bad") == bad, "the two readers disagree on how many lines are bad"
assert [x for k, x in items if k == "bad" and x is not None] == bad_ts, "the two readers disagree on the ts of the bad lines"
now = rep.parse_ts("2026-10-31T15:00:00Z"); lo = now - datetime.timedelta(hours=24)
g = det.gate_gaps(items, lo, now, rep, True)
assert sum(v for k, v in g.items() if k.startswith("lin_")) == bad, ("a bad line was not placed anywhere", g)
assert sum(v for k, v in g.items() if k.startswith("reg_")) == rep.verdicts(rows)[1] == 2, ("a verdict row was not placed anywhere", g)
for gone in (sys.argv[4], sys.argv[5]):
    assert det.read_gate_log(gone, rep)[0] == rep.read_jsonl(gone)[0] != "ok", gone
' "${DETX:-$DETB}" "$HERE/third-state-report.py" "$C/.gc/quality-gate.jsonl" "$W/no-such-log" "$C/.gc/logs" 2>"$W/par.err" && ok "the detector's reader and report.read_jsonl agree on rows, bad lines, their ts, and on absent / unreadable; every bad line and gap row is placed" || bad "reader parity: $(tail -2 "$W/par.err" | tr '\n' '|')"; }
case_noise; case_per_bead; case_conf_age; case_arm_rows; case_flags_cannot_stat; case_gate_log_gaps; case_reader_parity

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
case_cego_kept_early() { newcity ck; conf mode=enforce; runs ga-k 8; rm -f "$C/.gc/quality-gate.jsonl"
  run; want 2 "tick 1: gate log absent, blind" "NAO SEI"; mails 1 "...alarmed"
  conf mode=warn; AT=2026-10-31T16:00:00Z run; want 0 "tick 2: conf switched to warn, nothing to cover and the gate log is not even read" "nao sorteia braco"
  conf mode=enforce; AT=2026-10-31T17:00:00Z run; want 2 "tick 3: back to enforce, the gate log still absent" "NAO SEI"; mails 1 "...the blind mark survived the tick that did not look: still deduped"; AT=""; }
case_gaps_keep_diverge() { newcity gk; conf mode=enforce; runs ga-k 12
  run; want 1 "tick 1: 12 beads, no arms: alarmed" "DIVERGE"; mails 1 "...once"
  arms ga-k 1 12; trunc 2 dated; AT=2026-10-31T16:00:00Z run; want 2 "tick 2: the arms are there but 2 lines of the window are unreadable: it cannot say it is fixed, NAO SEI" "NAO SEI"; mails 2 "...with its own blind mail"
  rm -f "$C/.gc/third-state-reads-arms.jsonl"; AT=2026-10-31T17:00:00Z run; want 1 "tick 3: the arms are gone again, the lines still there: a divergence" "DIVERGE"
  mails 2 "...and the mark of tick 1 survived the tick that could not judge: deduped (no third mail)"; AT=""; }
case_cooldown; case_failed_delivery; case_rearm; case_inconclusive_keeps; case_cego_kept_early; case_gaps_keep_diverge; case_seen_garbage; case_fallback_and_hostile; case_delivery_errors; case_cli_edges
case_crash_and_siblings() { local SRC="${DETX:-$DET}"; newcity cr; conf mode=enforce; runs ga-k 8; mkbin "$W/bin-crash"; rm -f "$W/bin-crash/third-state-report.py"
  printf 'def verdicts(r):\n    raise RuntimeError("boom")\n' > "$W/bin-crash/third-state-report.py"; cp "$SRC" "$W/bin-crash/third-state-arm-coverage.py"
  DETX="$W/bin-crash/third-state-arm-coverage.py"; run; DETX=""; want 2 "a crash inside the detector is rc 2 (NAO SEI), never rc 1 (a finding)" "internal error: RuntimeError"
  mkbin "$W/bin-nosib"; rm -f "$W/bin-nosib/third-state-reads-check.py"; cp "$SRC" "$W/bin-nosib/third-state-arm-coverage.py"; DETX="$W/bin-nosib/third-state-arm-coverage.py"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; DETX=""
  want 2 "a missing sibling script is blind (rc 2), not 'no conf'" "NAO SEI"; mailhas "alarme-cego -- nao consegui carregar os scripts irmaos" "...and alarmed"
  mailhas "nao conseguiu carregar third-state-reads-check.py: FileNotFoundError" "...and the mail body names the sibling and why"
  # a sibling that dies at import in a way nobody listed (a NameError) or that exits: still blind AND alarmed -- not the generic "internal error", not a silent rc 0
  mkbin "$W/bin-nameerr"; rm -f "$W/bin-nameerr/third-state-report.py"; printf 'x = an_undefined_name\n' > "$W/bin-nameerr/third-state-report.py"; cp "$SRC" "$W/bin-nameerr/third-state-arm-coverage.py"
  DETX="$W/bin-nameerr/third-state-arm-coverage.py"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; DETX=""
  want 2 "a sibling that raises a NameError at import is blind (rc 2)" "NAO SEI.*NameError"; mailhas "alarme-cego -- nao consegui carregar os scripts irmaos" "...and ALARMED (the blind alarm, not the generic crash)"
  mailhas "nao conseguiu carregar third-state-report.py: NameError" "...and the mail body says which sibling broke and how"
  mkbin "$W/bin-exit"; rm -f "$W/bin-exit/third-state-report.py"; printf 'import sys\nsys.exit(0)\n' > "$W/bin-exit/third-state-report.py"; cp "$SRC" "$W/bin-exit/third-state-arm-coverage.py"
  DETX="$W/bin-exit/third-state-arm-coverage.py"; : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run; DETX=""
  want 2 "a sibling that calls sys.exit(0) at import is blind too, never a silent rc 0" "NAO SEI.*SystemExit"; }
case_crash_and_siblings
echo "== D2. what the CLI prints and the defaults (ga-0qhveri) =="
# The header, the --json fields (the age of each flag too), the defaults of every tunable AND their "0 = the default" fallback, the edges of the displayed lists, the arms file's counters, the router forms, the real clock.
# EQUIVALENT (not killable, proved by reading): scan_arms `t > last` -> `t >= last` (an equal ts assigns the same value) · load_sibling `fname[:-3]` -> `fname[:-4]` (the module name is never read: neither sibling
# looks at __name__ except for its own __main__ guard).
# Two that an earlier round declared equivalent were NOT (REVALIDAR, ga-0co26ac), and have a case below each: flag_age `max(0, ...)` -> `max(1, ...)` (51079d669b) shows in --json, which prints the age of every flag in
# seconds (not only through `// 3600`); `datetime.now(UTC).replace(microsecond=0)` -> `microsecond=1` (a0f591ad45) moves the window start `now - 24h` off a whole second, so a verdict exactly at the start drops out.
# EQUIVALENT 7e974aa472: load_sibling `fname[:-3]` -> `fname[:-4]`: the module name is never read (neither sibling looks at __name__ except for its own __main__ guard)
case_flag_age_json() { newcity fj; conf mode=enforce
  : > "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610311330 "$C/.gc/third-state-reads-check.off"   # 1h30 before $NOW
  : > "$C/.gc/gate-hardchecks.off"; TZ=UTC touch -t 202610311700 "$C/.gc/gate-hardchecks.off"   # 2h AFTER $NOW: a flag from a clock that ran ahead
  ARGS="--json"; run; ARGS=""
  printf '%s' "$OUT" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["switches"] == [["third-state-reads-check.off", 5400], ["gate-hardchecks.off", 0]], d["switches"]
' 2>"$W/fj.err" && ok "--json: every flag with its age in seconds (1h30 is 5400), and a flag from the future is 0, never negative" || bad "--json flag ages wrong :: $(tail -1 "$W/fj.err") :: $(printf '%s' "$OUT" | head -c 300)"; }
case_real_clock() { newcity clk; conf mode=enforce; runs ga-e 5; v 2026-10-30T15:00:00Z ga-edge PASS   # the 6th verdict sits EXACTLY at the start of the 24h window that ends at 15:00:00 on the 31st
  # no --now: the detector reads the real clock, so the test fixes it (a datetime subclass with a now() that has half a second on it) and calls main() in process
  "$PY" -B -I -c '
import contextlib, datetime, importlib.util, io, json, sys, types
s = importlib.util.spec_from_file_location("d", sys.argv[1]); det = importlib.util.module_from_spec(s); s.loader.exec_module(det)
class Clock(datetime.datetime):
    sec = 0
    @classmethod
    def now(cls, tz=None):
        return cls(2026, 10, 31, 15, 0, cls.sec, 500000, tzinfo=tz)
det.datetime = types.SimpleNamespace(datetime=Clock, timedelta=datetime.timedelta, timezone=datetime.timezone)
def runs_at(sec):
    Clock.sec = sec
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        det.main(["--city", sys.argv[2], "--json", "--no-lock", "--no-alarm"])
    return json.loads(out.getvalue())["runs"]
got = (runs_at(0), runs_at(1))
assert got == (6, 5), ("a verdict exactly at the window start counts at 15:00:00.5 (the half second is cut) and is out one second later", got)
' "${DETX:-$DETB}" "$C" 2>"$W/rc.err" && ok "real clock (no --now): the half second is cut, so a verdict exactly 24h back is inside the window (6 beads), and one second later it is out (5)" || bad "real clock: $(tail -2 "$W/rc.err" | tr '\n' '|' | cut -c1-300)"; }
case_header_and_json() { local E; newcity hj; conf mode=enforce enforce_pct=50; runs ga-j 6; arms ga-j 1 6
  run; want 0 "the header names the conf in force (mode and percentage)" "checagem: ligada \(mode=enforce enforce_pct=50\)"
  newcity hj2; run; want 0 "no conf at all: mode and percentage are '-', never 'None'" "checagem: nao-ligada \(mode=- enforce_pct=-\)"
  ARGS="--json"; run; ARGS=""
  printf '%s' "$OUT" | "$PY" -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["state"] == "nao-ligada", d["state"]
assert [d[k] for k in ("runs", "covered", "rows", "bad_rows")] == [0, 0, 0, 0], d
assert "alarms" not in d and d["alarm_keys"] == [], d
' 2>"$W/js.err" && ok "--json of a city that is not switched on: every counter is 0, there is no 'alarms' key (only alarm_keys)" || bad "--json fields wrong :: $(tail -1 "$W/js.err") :: $(printf '%s' "$OUT" | head -c 200)"
  newcity hj3; conf mode=enforce; E="$(printf '\303\251')"; runs ga-j 5; v 2026-10-31T11:00:00Z "ga-j$E"; ARGS="--json"; run; ARGS=""   # no PYTHONIOENCODING here: python -I ignores every PYTHON* variable, so the check rests on the default UTF-8 stdout (measured: it is inert)
  printf '%s' "$OUT" | grep -q "ga-j$E" && ok "--json keeps a non-ASCII bead id as it is (not \\u-escaped)" || bad "the non-ASCII bead id was escaped or lost :: $(printf '%s' "$OUT" | head -c 200)"; }
case_tunables() { newcity tn; conf mode=enforce; runs ga-n 6; arms ga-n 1 6
  run; want 0 "the default window is 24 h" "janela: 2026-10-30T15:00Z -> 2026-10-31T15:00Z UTC \(24h\)"
  run TSAC_WINDOW_H=0; want 0 "TSAC_WINDOW_H=0 is the default (24 h), never 'no window'" "UTC \(24h\)"
  run TSAC_WINDOW_H=48; want 0 "...and a real value is used as given" "2026-10-29T15:00Z -> 2026-10-31T15:00Z UTC \(48h\)"
  newcity tn2; conf mode=enforce; runs ga-n 6; arms ga-n 1 6; TZ=UTC touch -t 202610310100 "$C/.gc/third-state-reads.conf"
  run; want 0 "the conf-age gate waits 8 h by default (conf changed 01:00 -> counts from 09:00)" "runs so contam a partir de 2026-10-31T09:00Z"
  run TSAC_SLACK_H=0; want 0 "TSAC_SLACK_H=0 is a real zero (counts from the change itself)" "a partir de 2026-10-31T01:00Z"
  newcity tn3; conf mode=enforce; runs ga-m 4
  run TSAC_MIN_RUNS=0; want 0 "TSAC_MIN_RUNS=0 is the default (5): 4 beads are still too few" "sem conclusao"
  newcity tn4; conf mode=enforce; runs ga-m 5
  run TSAC_MIN_RUNS=0; want 1 "...and 5 beads are enough" "DIVERGE"
  newcity tn5; conf mode=enforce; runs ga-m 6; arms ga-m 1 5
  run TSAC_MIN_UNCOVERED=0; want 0 "TSAC_MIN_UNCOVERED=0 is the default (2): one hole in 6 is not enough" "SEM braco: 1"
  newcity tn6; conf mode=enforce; runs ga-m 6; arms ga-m 1 4
  run TSAC_MIN_UNCOVERED=0; want 1 "...and two holes are" "SEM braco: 2"
  newcity tn7; conf mode=enforce; runs ga-m 12; : > "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610281430 "$C/.gc/third-state-reads-check.off"
  run; want 1 "a kill-switch flag standing 72.5 h is stale by the default limit" "interruptor presente"; mailhas "interruptor-esquecido -- third-state-reads-check.off ligado ha mais de 72h" "...and the subject names the 72 h limit"
  : > "$MAIL"; rm -f "$C/state/third-state-arm-coverage-seen.json"; run TSAC_SWITCH_MAX_H=0; mailhas "ligado ha mais de 72h" "TSAC_SWITCH_MAX_H=0 is the default (72)"
  newcity tn8; conf mode=enforce; runs ga-m 12; : > "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610311300 "$C/.gc/third-state-reads-check.off"
  run TSAC_SWITCH_MAX_H=0; mails 0 "...and a 2-h-old flag is nowhere near it"
  newcity tn9; conf mode=enforce; runs ga-m 12
  run TSAC_WINDOW_H=48; mails 1 "tick 1: alarmed"
  AT=2026-11-01T14:59:59Z run TSAC_WINDOW_H=48; mails 1 "one second short of the default cooldown (24 h): deduped"
  AT=2026-11-01T15:00:00Z run TSAC_WINDOW_H=48; mails 2 "exactly 24 h after the first alarm: alarmed again"
  newcity tn10; conf mode=enforce; runs ga-m 12
  run TSAC_WINDOW_H=48 TSAC_ESCALATE_AFTER_S=0; mails 1 "tick 1: alarmed"
  AT=2026-10-31T16:00:00Z run TSAC_WINDOW_H=48 TSAC_ESCALATE_AFTER_S=0; mails 1 "TSAC_ESCALATE_AFTER_S=0 is not 'always': a tick 1 h after the first is still deduped"
  AT=2026-11-01T15:00:00Z run TSAC_WINDOW_H=48 TSAC_ESCALATE_AFTER_S=0; mails 2 "...and not 'never': exactly 24 h after the first alarm it is the default cooldown, so alarmed again"; AT=""; }
case_tail_edges() { local L1 n; newcity lt2; conf mode=enforce; runs ga-d 6
  L1="[2026-10-31 08:00:00] [quality-gate-guard] HARDCHECK step=2e verdict=nao-consegui-medir reason=fetch-falhou bead=ga-d1 branch=b mode=enforce marker=m checker=[<EMPTY>]"
  n=$((8388608 + 4000 - ${#L1} - 2))
  { printf '%s\n' "$L1"; head -c "$n" /dev/zero | tr '\0' 'x'; printf '\n'; } > "$C/.gc/logs/quality-gate-guard.log"
  run; want 1 "a guard log 4000 bytes over the 8 MiB default tail: its first line has scrolled out" "rodou para ele, ou o log girou\) x6"
  run TSAC_LOG_TAIL_BYTES=0; want 1 "TSAC_LOG_TAIL_BYTES=0 is not 'unlimited': on the big log it is still the 8 MiB default, the first line stays out" "rodou para ele, ou o log girou\) x6"
  newcity lt3; conf mode=enforce; runs ga-d 6; guardlog "$L1"
  run TSAC_LOG_TAIL_BYTES="$(wc -c < "$C/.gc/logs/quality-gate-guard.log" | tr -d ' ')"; want 1 "a tail exactly as long as the log reads all of it, first byte included" "fetch-falhou"
  run TSAC_LOG_TAIL_BYTES=0; want 1 "TSAC_LOG_TAIL_BYTES=0 is not 'read nothing': on the small log it is the 8 MiB default, the first line is found" "fetch-falhou"; }
case_arms_file_counts() { newcity af1; conf mode=enforce; runs ga-a 6
  run; want 1 "no arms file: 0 rows, 0 odd rows, never written" "arquivo de bracos: absent, 0 linha\(s\), 0 ilegivel\(is\)/estranha\(s\), ultima gravacao nunca"
  if [ "$IS_ROOT" = 0 ]; then newcity af2; conf mode=enforce; runs ga-a 6; : > "$C/.gc/third-state-reads-arms.jsonl"; chmod 000 "$C/.gc/third-state-reads-arms.jsonl"; run; chmod 644 "$C/.gc/third-state-reads-arms.jsonl"
    want 1 "an unreadable arms file: also 0 and 0, said as such" "arquivo de bracos: unreadable, 0 linha\(s\), 0 ilegivel\(is\)/estranha\(s\), ultima gravacao nunca"; else ok "(root: chmod 000 case skipped)"; fi
  newcity af3; conf mode=enforce; runs ga-a 10; arm ga-a1 enforce 2026-10-31T09:00:00Z; arm ga-a2 enforce 2026-10-31T11:30:00Z; arms ga-a 3 7 enforce; arm ga-a8 holdout 2026-10-31T10:15:00Z; arm ga-a9 holdout; arm ga-a10 holdout
  run; want 0 "10 rows, the LATEST write (not the first) is the last one, wherever it sits in the file" "arquivo de bracos: ok, 10 linha\(s\), 0 ilegivel.*ultima gravacao 2026-10-31T11:30:00Z"
  printf '%s' "$OUT" | grep -q 'com braco: 10 (enforce 7 / holdout 3); SEM braco: 0' && ok "...and the split is counted per arm (7 / 3, not symmetric)" || bad "split wrong :: $(printf '%s' "$OUT" | grep 'veredito real')"; }
case_first_line_undated() { newcity fu; conf mode=enforce
  printf '{"event":"dispatcher_complete","bead":"ga-cut\n' > "$C/.gc/quality-gate.jsonl"   # the very FIRST line of the log: cut off, no ts of its own
  v 2026-06-04T10:00:00Z ga-june1; runs ga-g 6; arms ga-g 1 6
  run; want 0 "an undated cut line at the very start of the log is placed by the first readable row after it (June): provably old" "dentro do limite"
  printf '%s' "$OUT" | grep -q '1 provadamente anteriores' && ok "...and said, not hidden" || bad "the first-line gap was not said :: $(printf '%s' "$OUT" | grep ilegivel)"; }
case_lists() { local n; newcity sa8; conf mode=enforce; runs ga-u 20; arms ga-u 1 12
  run; want 1 "8 holes in 20: alarmed" "SEM braco: 8"
  n="$(grep -o '(sem-linha)' "$MAIL" | wc -l | tr -d ' ')"; [ "$n" = 8 ] && ok "...the mail names all 8" || bad "the mail names $n beads, want 8"
  grep -q '(sem-linha) \.\.\.\.' "$MAIL" && bad "...no ' ...' after a list of exactly 8" || ok "...and no ' ...' after a list of exactly 8"
  newcity sa9; conf mode=enforce; runs ga-u 20; arms ga-u 1 11
  run; want 1 "9 holes in 20: alarmed" "SEM braco: 9"
  n="$(grep -o '(sem-linha)' "$MAIL" | wc -l | tr -d ' ')"; [ "$n" = 8 ] && ok "...the mail names 8 of the 9" || bad "the mail names $n beads, want 8"
  grep -q '(sem-linha) \.\.\.\.' "$MAIL" && ok "...and says there are more (' ...')" || bad "the 9th hole is not announced"
  newcity sa11; conf mode=enforce; runs ga-o 12; arm ga-o1 enforce
  run; want 1 "11 holes in 12: alarmed" "SEM braco: 11"
  n="$(printf '%s\n' "$OUT" | grep -c '^    sem braco: ')"; [ "$n" = 10 ] && ok "the text lists 10 of the 11" || bad "the text lists $n holes, want 10"; }
case_flag_age_text() { newcity fa; conf mode=enforce; runs ga-w 12
  mkdir "$C/.gc/third-state-reads-check.off"; TZ=UTC touch -t 202610271100 "$C/.gc/third-state-reads-check.off"
  run; want 1 "the check's own kill switch counts even as a directory (it tests exists, not -f); 100 h old" "interruptores presentes: third-state-reads-check.off \(ha 100h\)"
  mailhas "O arquivo third-state-reads-check.off existe ha 100h \(limite 72h\)" "...and the stale-switch mail says for how long"; }
case_router_forms() { newcity rf; conf mode=enforce; runs ga-k 12
  : > "$C/gc.calls"; printf '#!/bin/sh\necho "gc $*" >> "%s"\nexit 0\n' "$C/gc.calls" > "$C/gc"; chmod +x "$C/gc"
  printf '#!/bin/sh\necho "$*" >> "$TSAC_MAIL"\nexit 0\n' > "$C/router-noexec"; chmod 644 "$C/router-noexec"
  run TSAC_ROUTER="$C/router-noexec" GC_BIN="$C/gc"; want 1 "a router file that is not executable is not the router: the mail goes through gc" "DIVERGE"
  grep -q 'gc mail send mayor' "$C/gc.calls" && ok "...via gc mail send mayor" || bad "the fallback was not used :: $(cat "$C/gc.calls")"
  printf '%s' "$OUT" | grep -q 'NAO ENTREGUE' && bad "...a non-executable router must never be tried" || ok "...and it was never tried"
  newcity rf2; conf mode=enforce; runs ga-k 12
  printf '#!/bin/sh\necho NOISE-ROUTER-STDOUT\necho NOISE-ROUTER-STDERR >&2\necho "$*" >> "$TSAC_MAIL"\nexit 0\n' > "$C/router-noisy"; chmod +x "$C/router-noisy"
  run TSAC_ROUTER="$C/router-noisy"; want 1 "a router that talks: its output is captured, not echoed into the detector's own output" "DIVERGE"
  printf '%s' "$OUT" | grep -q 'NOISE-ROUTER' && bad "the router's output leaked into the detector's output" || ok "...nothing of it leaked"; mails 1 "...and it was called"; }
case_help_and_env_city() { newcity hc; conf mode=enforce; runs ga-h 3
  OUT="$("$PY" -I "${DETX:-$DETB}" --help 2>&1)"; RC=$?; want 0 "--help prints the description (the docstring's first line) and exits 0" "ga-r4z4ve: alarm when the gate's runs outnumber"
  OUT="$(env -u GC_CITY_PATH GC_CITY="$C" "$PY" -I "${DETX:-$DETB}" --now "$NOW" --no-lock --no-alarm 2>&1)"; RC=$?; want 0 "no --city and no GC_CITY_PATH: GC_CITY names the city" "cidade: [^ ]*/c[0-9]+-hc "
  OUT="$(env GC_CITY_PATH="$C" GC_CITY="$W/no-such-city" "$PY" -I "${DETX:-$DETB}" --now "$NOW" --no-lock --no-alarm 2>&1)"; RC=$?; want 0 "both set: GC_CITY_PATH wins" "cidade: [^ ]*/c[0-9]+-hc "; }
case_order_no_alarm() { newcity on; conf mode=enforce; runs ga-k 12; ARGS="--order --no-alarm"
  run; ARGS=""; want 0 "--order --no-alarm: nothing was delivered, so nothing failed to deliver (rc 0 though the finding stands)" "DIVERGE"; mails 0 "...and nobody is mailed"; }
case_alarm_in_process() { newcity ip; conf mode=enforce; runs ga-k 12; mkdir -p "$C/unit"   # $C/unit, never a dir shared by calls ($W/unit): the seen marks of one run would make every later run fail the FIRST assertion whatever the detector says, and a mutant would be "caught" by stale state
  "$PY" -B -I -c '
import contextlib, datetime, importlib.util, io, os, subprocess, sys
s = importlib.util.spec_from_file_location("d", sys.argv[1]); det = importlib.util.module_from_spec(s); s.loader.exec_module(det)
city, scratch = sys.argv[2], sys.argv[3]
sent = []
real_deliver = det.deliver
det.deliver = lambda subject, body, c, t: sent.append(subject) or 0
res = {"alarms": {"k": ("subj", "body")}, "unevaluated": []}
failed = det.alarm(res, os.path.join(scratch, "st"), city, datetime.datetime(1970, 1, 1, 0, 1, 40, tzinfo=det.UTC), 86400, 5)
assert sent == ["subj"] and failed == 0, ("a key never alarmed must alarm, even on a clock at epoch 100", sent, failed)
det.deliver = real_deliver
calls = []
class Done: returncode = 0
subprocess.run = lambda cmd, **kw: calls.append(kw) or Done()
for env, want in ((None, 120), ("0", 120), ("7", 7)):
    calls[:] = []
    if env is None: os.environ.pop("TSAC_DELIVER_TIMEOUT_S", None)
    else: os.environ["TSAC_DELIVER_TIMEOUT_S"] = env
    os.environ["TSAC_STATE_DIR"] = os.path.join(scratch, "st-" + str(env))
    with contextlib.redirect_stdout(io.StringIO()):
        rc = det.main(["--city", city, "--now", "2026-10-31T15:00:00Z", "--no-lock"])
    assert rc == 1 and len(calls) == 1 and calls[0].get("timeout") == want and calls[0].get("capture_output") is True, (env, rc, calls)
' "${DETX:-$DETB}" "$C" "$C/unit" 2>"$W/ip.err" && ok "in-process: a never-alarmed key alarms on a clock at epoch 100; the delivery timeout is 120 s by default and for 0, the value given otherwise; the router output is captured" || bad "in-process alarm/deliver: $(tail -2 "$W/ip.err" | tr '\n' '|' | cut -c1-300)"; }
case_diag_unavailable() { newcity du; conf mode=enforce; runs ga-d 6
  run; want 1 "no guard log at all: the diagnosis says it is ABSENT" "quality-gate-guard.log ausente\)"
  if [ "$IS_ROOT" = 0 ]; then mkdir -p "$C/.gc/logs/quality-gate-guard.log"; run; rmdir "$C/.gc/logs/quality-gate-guard.log"
    want 1 "a guard log that cannot be read (a directory): the diagnosis says UNREADABLE" "quality-gate-guard.log ilegivel\)"; fi; }
case_header_and_json; case_tunables; case_tail_edges; case_arms_file_counts; case_first_line_undated; case_lists; case_flag_age_text; case_flag_age_json; case_router_forms; case_help_and_env_city; case_order_no_alarm; case_alarm_in_process; case_real_clock; case_diag_unavailable
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
# the partly readable gate log (gate-fix 1): each way of throwing the unreadable part away, and each way of misplacing it, must die
UNK='unknown = g["lin_in"] + g["lin_doubt"] + g["reg_in"] + g["reg_doubt"] + blank'
mutant lines_dropped "$UNK" 'unknown = g["reg_in"] + g["reg_doubt"] + blank' case_gate_log_gaps
mutant no_ts_dropped "$UNK" 'unknown = g["lin_in"] + g["lin_doubt"] + blank' case_gate_log_gaps
mutant blank_dropped "$UNK" 'unknown = g["lin_in"] + g["lin_doubt"] + g["reg_in"] + g["reg_doubt"]' case_gate_log_gaps
mutant rows_unchecked 'g = gate_gaps(items, lo, now, report, no_ts > 0)' 'g = gate_gaps(items, lo, now, report, False)' case_gate_log_gaps
mutant every_row_a_gap 'elif check_rows and report.verdicts([x])[1]:' 'elif check_rows:' case_gate_log_gaps
mutant blank_any_window 'elif lo <= t <= now:' 'else:' case_noise
PLACE='return "out" if after is not None and after < lo else "doubt"'
mutant undated_is_old "$PLACE" 'return "out"' case_gate_log_gaps
mutant undated_is_doubt "$PLACE" 'return "doubt"' case_gate_log_gaps
mutant undated_after_any "$PLACE" 'return "out" if after is not None else "doubt"' case_gate_log_gaps
mutant own_ts_ignored 'return "in" if lo <= own <= now else "out"' 'return "in"' case_gate_log_gaps
mutant own_ts_future_ok 'return "in" if lo <= own <= now else "out"' 'return "in" if lo <= own else "out"' case_gate_log_gaps
mutant bad_ts_unguarded 'except (TypeError, ValueError):' 'except TypeError:' case_gate_log_gaps
mutant poucos_runs_trusted 'if unknown and res["verdict"] != "diverge":' 'if unknown and res["verdict"] == "ok":' case_gate_log_gaps
mutant diverge_blinded 'if unknown and res["verdict"] != "diverge":' 'if unknown:' case_gate_log_gaps
mutant no_caveat 'body + " ATENCAO: " + gaps_text(g) + " O numero real de beads sem braco pode ser maior."' 'body' case_gate_log_gaps
mutant gaps_unsaid 'if any(g.values()):   # said whenever anything is unreadable' 'if False:   # said whenever anything is unreadable' case_gate_log_gaps
mutant partial_forgets_diverge $'res["unevaluated"] = ["diverge"]\n        return blind(res, "cego|gate-log-parcial"' $'res["unevaluated"] = []\n        return blind(res, "cego|gate-log-parcial"' case_gaps_keep_diverge
mutant early_forgets '(["diverge"] if res["state"] == "interruptor" else []) + ["cego"]' '(["diverge"] if res["state"] == "interruptor" else [])' case_cego_kept_early
mutant sibling_narrow 'except (Exception, SystemExit) as e:' 'except (OSError, SyntaxError, ImportError, AttributeError) as e:' case_crash_and_siblings
mutant scalar_is_row $'if isinstance(d, dict):\n            items.append(("row", d))' $'if d is not None:\n            items.append(("row", d))' case_reader_parity
mutant bad_ts_lost 'items.append(("bad", stamp(report, m.group(1)) if m else None))' 'items.append(("bad", None))' case_reader_parity
# the new cases of D2 (ga-0qhveri): one representative swap each
mutant json_alarms_key 'if k != "alarms"' 'if k == "alarms"' case_header_and_json
mutant window_default 'env_int("TSAC_WINDOW_H", 24) or 24' 'env_int("TSAC_WINDOW_H", 25) or 24' case_tunables
mutant tail_edge 'fh.seek(0, os.SEEK_END)' 'fh.seek(1, os.SEEK_END)' case_tail_edges
mutant last_write_min 'last = t if last is None or t > last else last' 'last = t if last is None or t <= last else last' case_arms_file_counts
mutant first_line_unplaced 'for i in range(len(items) - 1, -1, -1):' 'for i in range(len(items) - 1, 0, -1):' case_first_line_undated
mutant ellipsis_at_8 '(" ..." if u > 8 else "")' '(" ..." if u >= 8 else "")' case_lists
mutant kill_switch_dir 'os.path.join(state, tool.KILL), False)' 'os.path.join(state, tool.KILL), True)' case_flag_age_text
mutant router_not_executable 'os.path.isfile(router) and os.access(router, os.X_OK)' 'os.path.isfile(router) or os.access(router, os.X_OK)' case_router_forms
mutant env_city 'os.environ.get("GC_CITY_PATH") or os.environ.get("GC_CITY"))' 'os.environ.get("GC_CITY_PATH") and os.environ.get("GC_CITY"))' case_help_and_env_city
mutant order_no_alarm_fails $'    failed = 0\n' $'    failed = 1\n' case_order_no_alarm
mutant seen_default 'last = seen.get(k, 0)' 'last = seen.get(k, 1)' case_alarm_in_process
mutant diag_ausente '("ausente" if ls == "absent" else "ilegivel")' '("ausente" if ls != "absent" else "ilegivel")' case_diag_unavailable
# the two 0-means-default knobs the gate found unpinned (ga-0qhveri, round 1): dropping the `or <default>` makes 0 mean "always" / "read nothing"
mutant escalate_zero_is_always 'env_int("TSAC_ESCALATE_AFTER_S", 86400) or 86400' 'env_int("TSAC_ESCALATE_AFTER_S", 86400)' case_tunables
mutant tail_zero_reads_nothing 'env_int("TSAC_LOG_TAIL_BYTES", 8 * 1024 * 1024) or 8 * 1024 * 1024' 'env_int("TSAC_LOG_TAIL_BYTES", 8 * 1024 * 1024)' case_tail_edges

echo "selftest: $PASS passed, $FAILN failed"
REACHED_END=1
[ "$FAILN" = 0 ]
