#!/usr/bin/env bash
# gate-throughput-meter.selftest.sh — hermetic: a scratch city per case, a synthetic dispatcher log, a fake `gc`
# (GTM_GC_BIN) that records every mail. Never touches the real city, never sends a real mail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gate-meter-st.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
M="$HERE/gate-throughput-meter.py"
export HOME="$W/home"; mkdir -p "$HOME"
unset GTM_ENABLED GTM_DRY_RUN GTM_TARGET GTM_WINDOW_H GTM_REMAIL_S GTM_BLIND_MAIL_S GTM_QUEUE_MAX_AGE_S

# fake gc: appends one line per call to $FAKE_GC_LOG, exits with the number in $FAKE_GC_RC_FILE (default 0)
mkdir -p "$W/bin"
cat > "$W/bin/gc" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >> "$FAKE_GC_LOG"
rc=0; [ -f "$FAKE_GC_RC_FILE" ] && rc="$(cat "$FAKE_GC_RC_FILE")"
[ "$rc" != "0" ] && echo "gc: simulated failure" >&2
exit "$rc"
EOF
chmod +x "$W/bin/gc"
export GTM_GC_BIN="$W/bin/gc"

NOW="$(TZ=UTC python3 -c 'import datetime;print(int(datetime.datetime(2026,11,14,15,0,0,tzinfo=datetime.timezone.utc).timestamp()))')"  # 12:00 BRT
# newcity <name> — fresh scratch city; sets C, FAKE_GC_LOG
newcity() { C="$W/$1"; mkdir -p "$C/.gc/logs" "$C/.gc/state"; export FAKE_GC_LOG="$W/$1.mails"; : > "$FAKE_GC_LOG"; export FAKE_GC_RC_FILE="$W/$1.rc"; rm -f "$FAKE_GC_RC_FILE"; }
# mklog <city> <start-hours-before-now> <completions-in-last-3h-spread> [hours...] — see genlog below
genlog() { # genlog <city> <first_hours_ago> <spec...>   spec = "<hours_ago>:<count>:<verdict>" (count lines evenly inside that hour)
  python3 - "$1" "$NOW" "$2" "${@:3}" <<'PY'
import sys, datetime
city, now, first = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
brt = datetime.timezone(datetime.timedelta(hours=-3))
def st(t): return datetime.datetime.fromtimestamp(t, brt).strftime("%Y-%m-%d %H:%M:%S")
out = ["[%s] [quality-gate-dispatcher] dispatcher start" % st(now - first * 3600)]
n = 0
for spec in sys.argv[4:]:
    h, c, v = spec.split(":")
    for i in range(int(c)):
        n += 1
        t = now - float(h) * 3600 + 60 + i * (3000.0 / max(int(c), 1))
        out.append("[%s] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-r%d branch=x verdict=%s elapsed=100s ===" % (st(t), n, v))
out.sort()
open(city + "/.gc/logs/quality-gate-dispatcher.log", "w").write("\n".join(out) + "\n")
PY
}
focus() { printf 'active=0\nsince=1\ndepth=%s\nat=%s\nescalated=0\n' "$2" "$3" > "$1/.gc/gate-focus.state"; }
meter() { python3 -I "$M" --city "$C" --now "$NOW" "$@" 2>&1; }
mails() { grep -c '^CALL ' "$FAKE_GC_LOG"; }
state() { python3 -c "import json,sys;d=json.load(open('$C/.gc/state/gate-throughput-meter.json'));print(d.get(sys.argv[1],''))" "$1" 2>/dev/null; }

# T1 healthy: 10/h for 3 h → OK, no mail
newcity t1; genlog "$C" 48 "1:10:PASS" "2:10:PASS" "3:10:FAIL"; focus "$C" 5 "$((NOW-60))"
OUT="$(meter)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'OK: 30 revisadas em 3h = 10,0/h' && [ "$(mails)" = 0 ] && ok || bad "T1 healthy: rc=$RC mails=$(mails) out=$OUT"
[ -z "$(state alarm_since)" ] && ok || bad "T1 healthy must leave no alarm state"

# T2 alarm, empty queue → ONE mail naming OFERTA, the three hourly counts and the 24 h average
newcity t2; genlog "$C" 48 "1:3:PASS" "2:2:FAIL" "3:1:PASS" "10:20:PASS"; focus "$C" 0 "$((NOW-120))"
OUT="$(meter)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'ALARM: 6 revisadas em 3h = 2,0/h (por hora, mais recente primeiro: 3/2/1)' && ok || bad "T2 alarm line: rc=$RC out=$OUT"
[ "$(mails)" = 1 ] && grep -q '^CALL mail send mayor -s Gate abaixo de 8,0/h: 2,0/h nas últimas 3h — oferta' "$FAKE_GC_LOG" && ok || bad "T2 expected one mail with cause 'oferta': $(cat "$FAKE_GC_LOG")"
grep -q 'OFERTA' "$FAKE_GC_LOG" && grep -q 'última hora 3; 2ª hora atrás 2; 3ª hora atrás 1' "$FAKE_GC_LOG" && grep -q 'Média 24 h: 1,1/h (26 revisadas em 24 h)' "$FAKE_GC_LOG" && ok || bad "T2 mail body: $(cat "$FAKE_GC_LOG")"
[ -n "$(state last_mail)" ] && [ -n "$(state alarm_since)" ] && ok || bad "T2 state must carry last_mail+alarm_since after a delivered mail"

# T3 dedup: 5 min later, still alarm → no second mail
OUT="$(python3 -I "$M" --city "$C" --now "$((NOW+300))" 2>&1)"
[ "$(mails)" = 1 ] && echo "$OUT" | grep -q 'mail já enviado há 5 min' && ok || bad "T3 dedup: mails=$(mails) out=$OUT"
# T3b re-mail after 6 h while it lasts (marked as repeat)
python3 -I "$M" --city "$C" --now "$((NOW+21700))" >/dev/null 2>&1
[ "$(mails)" = 2 ] && [ "$(grep -c 'AINDA em alarme' "$FAKE_GC_LOG")" = 1 ] && ok || bad "T3b 6h re-mail: mails=$(mails) $(cat "$FAKE_GC_LOG")"

# T4 alarm with a full queue → REVISORES
newcity t4; genlog "$C" 48 "1:2:PASS"; focus "$C" 9 "$((NOW-120))"
meter >/dev/null; grep -q 'REVISORES: 9 beads esperando revisor' "$FAKE_GC_LOG" && grep -q 'revisores' "$FAKE_GC_LOG" && ok || bad "T4 cause must be REVISORES: $(cat "$FAKE_GC_LOG")"
# T4b shallow queue (1-2) → neither supply nor reviewers
newcity t4b; genlog "$C" 48 "1:2:PASS"; focus "$C" 2 "$((NOW-120))"
meter >/dev/null; grep -q 'fila rasa (2)' "$FAKE_GC_LOG" && ok || bad "T4b shallow cause: $(cat "$FAKE_GC_LOG")"

# T5 third state of the QUEUE read: stale / corrupt / absent gate-focus.state → cause 'indeterminada', never 'fila 0'
newcity t5a; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-7200))"
OUT="$(meter)"; echo "$OUT" | grep -q 'fila: não medido (gate-focus.state de 120 min atrás)' && grep -q 'causa indeterminada' "$FAKE_GC_LOG" && ! grep -q 'OFERTA' "$FAKE_GC_LOG" && ok || bad "T5a stale queue: $OUT / $(cat "$FAKE_GC_LOG")"
newcity t5b; genlog "$C" 48 "1:2:PASS"; printf 'depth=abc\nat=zzz\n' > "$C/.gc/gate-focus.state"
OUT="$(meter)"; echo "$OUT" | grep -q 'fila: não medido (gate-focus.state corrompido)' && ! grep -q 'OFERTA' "$FAKE_GC_LOG" && ok || bad "T5b corrupt queue: $OUT"
newcity t5c; genlog "$C" 48 "1:2:PASS"
OUT="$(meter)"; echo "$OUT" | grep -q 'fila: não medido (sem gate-focus.state)' && ! grep -q 'OFERTA' "$FAKE_GC_LOG" && ok || bad "T5c absent queue: $OUT"

# T6 BLIND — dispatcher log unreadable/absent: no number, no 0/h, no alarm mail, rc 1
newcity t6
OUT="$(meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'BLIND: log do dispatcher ilegível' && ! echo "$OUT" | grep -qE '0,0/h|ALARM|OK:' && [ "$(mails)" = 0 ] && ok || bad "T6 absent log: rc=$RC mails=$(mails) out=$OUT"
# T6b log with no stamped line at all (e.g. truncated garbage)
newcity t6b; echo "garbage" > "$C/.gc/logs/quality-gate-dispatcher.log"
OUT="$(meter)"; RC=$?; [ "$RC" = 1 ] && echo "$OUT" | grep -q 'BLIND: log do dispatcher sem nenhuma linha com carimbo' && [ "$(mails)" = 0 ] && ok || bad "T6b garbage log: rc=$RC out=$OUT"
# T6c log is a directory (unreadable) → blind, not a crash
newcity t6c; mkdir -p "$C/.gc/logs/quality-gate-dispatcher.log"
OUT="$(meter)"; RC=$?; [ "$RC" = 1 ] && echo "$OUT" | grep -q 'BLIND' && ok || bad "T6c unreadable log: rc=$RC out=$OUT"

# T7 BLIND — history shorter than the window (a log that starts 1 h ago cannot prove an alarm)
newcity t7; genlog "$C" 1 "1:1:PASS"
OUT="$(meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'BLIND: o log do dispatcher só cobre desde' && ! echo "$OUT" | grep -q 'ALARM' && [ "$(mails)" = 0 ] && ok || bad "T7 short history: rc=$RC out=$OUT"

# T7b blindness lasting past an hour → ONE mail to the Mayor saying the meter is blind (not the gate)
python3 -I "$M" --city "$C" --now "$((NOW+4000))" >/dev/null 2>&1
[ "$(mails)" = 1 ] && grep -q 'Medidor do gate CEGO' "$FAKE_GC_LOG" && ok || bad "T7b blind mail: mails=$(mails) $(cat "$FAKE_GC_LOG")"
python3 -I "$M" --city "$C" --now "$((NOW+4300))" >/dev/null 2>&1
[ "$(mails)" = 1 ] && ok || bad "T7b blind mail must not repeat within 6 h: mails=$(mails)"

# T8 the mail command fails → rc 1, WARN, NO stamp; the next run (gc healthy again) delivers
newcity t8; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"; echo 1 > "$FAKE_GC_RC_FILE"
OUT="$(meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'WARN: mail ao Mayor FALHOU (gc mail send saiu com rc=1' && [ -z "$(state last_mail)" ] && ok || bad "T8 failing mail: rc=$RC last_mail=$(state last_mail) out=$OUT"
! echo "$OUT" | grep -q 'MAIL: alarme enviado' && ok || bad "T8 must not log a delivery that failed"
echo 0 > "$FAKE_GC_RC_FILE"; meter >/dev/null
[ -n "$(state last_mail)" ] && [ "$(mails)" = 2 ] && ok || bad "T8 retry after failure: last_mail=$(state last_mail) mails=$(mails)"
# T8b gc binary does not even start → same inert outcome
newcity t8b; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_GC_BIN="$W/bin/nonexistent" meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'mail ao Mayor FALHOU' && [ -z "$(state last_mail)" ] && ok || bad "T8b missing gc: rc=$RC out=$OUT"

# T9 state file cannot be written (a directory sits where it goes) → NO mail (it could not remember sending it)
newcity t9; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"; mkdir -p "$C/.gc/state/gate-throughput-meter.json"
OUT="$(meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'WARN: estado não gravável' && [ "$(mails)" = 0 ] && ok || bad "T9 unwritable state: rc=$RC mails=$(mails) out=$OUT"
# T9b corrupt state JSON → read as a first run and rewritten (one mail, then valid JSON)
newcity t9b; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"; echo '{not json' > "$C/.gc/state/gate-throughput-meter.json"
meter >/dev/null; [ "$(mails)" = 1 ] && [ -n "$(state last_mail)" ] && ok || bad "T9b corrupt state: mails=$(mails) last_mail=$(state last_mail)"

# T10 recovery: alarm state + healthy rate → RECOVERED logged, state cleared, no mail
newcity t10; genlog "$C" 48 "1:9:PASS" "2:9:PASS" "3:9:PASS"; focus "$C" 4 "$((NOW-60))"
echo "{\"alarm_since\": $((NOW-7200)), \"last_mail\": $((NOW-7200))}" > "$C/.gc/state/gate-throughput-meter.json"
OUT="$(meter)"; echo "$OUT" | grep -q 'RECOVERED: 27 revisadas em 3h = 9,0/h' && [ "$(mails)" = 0 ] && [ -z "$(state alarm_since)" ] && ok || bad "T10 recovery: out=$OUT state=$(state alarm_since)"

# T11 counting rules: a repeated gate_run counts once; SKIPPED and other verdicts do not count
newcity t11; genlog "$C" 48 "1:2:PASS"
cat >> "$C/.gc/logs/quality-gate-dispatcher.log" <<EOF
[$(TZ=America/Sao_Paulo date -r "$((NOW-600))" '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-r1 branch=x verdict=PASS elapsed=1s ===
[$(TZ=America/Sao_Paulo date -r "$((NOW-500))" '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-sk branch=x verdict=SKIPPED_BEAD_CLOSED elapsed=1s ===
EOF
OUT="$(meter --report)"; echo "$OUT" | grep -q '2 revisadas em 3h' && ok || bad "T11 counting: $OUT"

# T12 --report is read-only: no state, no lock, no mail; --dry-run decides and logs but sends/writes nothing
newcity t12; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
meter --report >/dev/null; [ ! -e "$C/.gc/state/gate-throughput-meter.json" ] && [ ! -e "$C/.gc/state/gate-throughput-meter.lock" ] && [ "$(mails)" = 0 ] && ok || bad "T12 --report touched state or mailed"
OUT="$(meter --dry-run)"; echo "$OUT" | grep -q 'DRY_RUN: enviaria mail ao Mayor' && [ "$(mails)" = 0 ] && [ ! -e "$C/.gc/state/gate-throughput-meter.json" ] && ok || bad "T12 --dry-run: mails=$(mails) out=$OUT"
OUT="$(GTM_DRY_RUN=1 meter)"; echo "$OUT" | grep -q 'DRY_RUN' && [ "$(mails)" = 0 ] && ok || bad "T12 GTM_DRY_RUN=1: $OUT"

# T13 kill-switch
newcity t13; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_ENABLED=0 meter)"; echo "$OUT" | grep -q 'GTM_ENABLED=0' && [ "$(mails)" = 0 ] && [ ! -e "$C/.gc/state/gate-throughput-meter.json" ] && ok || bad "T13 kill-switch: $OUT"

# T14 knobs: an unreadable / non-positive number falls back to the default, never to "no alarm"
newcity t14; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_TARGET=oito GTM_WINDOW_H=0 meter)"; echo "$OUT" | grep -q 'ALARM: 2 revisadas em 3h' && [ "$(mails)" = 1 ] && ok || bad "T14 typo in knobs must keep default 8/3h: $OUT"
newcity t14b; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_TARGET=0.5 meter)"; echo "$OUT" | grep -q 'OK: 2 revisadas em 3h = 0,7/h' && [ "$(mails)" = 0 ] && ok || bad "T14b a valid GTM_TARGET=0.5 must be honoured (0,7/h is then OK): $OUT"

# T15 single instance: a held lock → exit 0, no mail
newcity t15; genlog "$C" 48 "1:2:PASS"; focus "$C" 0 "$((NOW-60))"
python3 - "$C/.gc/state/gate-throughput-meter.lock" "$W/lock.ready" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("1"); time.sleep(6)
PY
LP=$!; for _ in $(seq 1 50); do [ -f "$W/lock.ready" ] && break; sleep 0.1; done
OUT="$(meter)"; RC=$?; kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'outra instância em andamento' && [ "$(mails)" = 0 ] && ok || bad "T15 lock held: rc=$RC mails=$(mails) out=$OUT"

# T16 daily_summary (the morning report's line): numbers for the day + trailing 3 h; third state when the log is unreadable
newcity t16; genlog "$C" 72 "1:10:PASS" "2:10:PASS" "3:10:PASS" "20:24:PASS"
S="$(python3 -I - "$M" "$C" "$NOW" <<'PY'
import importlib.util, sys, datetime
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.daily_summary(sys.argv[2], datetime.date(2026, 11, 13), float(sys.argv[3])))
PY
)"
echo "$S" | grep -q '^1,0/h no dia (24 revisadas em 24 h; 1 de 24 horas com ≥ 8,0); 10,0/h nas últimas 3 h até agora (30 revisadas); meta ≥ 8,0/h$' && ok || bad "T16 daily_summary: $S"
newcity t16b
S="$(python3 -I - "$M" "$C" "$NOW" <<'PY'
import importlib.util, sys, datetime
s = importlib.util.spec_from_file_location("m", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.daily_summary(sys.argv[2], datetime.date(2026, 11, 13), float(sys.argv[3])))
PY
)"
echo "$S" | grep -q '^não medido (log do dispatcher ilegível' && ! echo "$S" | grep -q '0,0/h' && ok || bad "T16b unreadable log must read 'não medido': $S"

echo "gate-throughput-meter.selftest: $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
