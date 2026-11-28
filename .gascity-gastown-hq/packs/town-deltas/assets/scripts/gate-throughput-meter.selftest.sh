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
S_DIR="$HERE"
export HOME="$W/home"; mkdir -p "$HOME"
unset GTM_ENABLED GTM_DRY_RUN GTM_TARGET GTM_WINDOW_H GTM_REMAIL_S GTM_BLIND_MAIL_S GTM_QUEUE_MAX_AGE_S GTM_BANDS GTM_BANDS_CONFIG BANDS_DIAGNOSE

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
# fake claude (the read-only diagnostician) and fake bd: every call is recorded, nothing leaves the scratch dir
cat > "$W/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > "$FAKE_CLAUDE_LOG.stdin"
printf 'CALL %s\n' "$*" >> "$FAKE_CLAUDE_LOG"
printf '{"type":"result","subtype":"success","is_error":false,"result":"diagnóstico de teste: a fila do gate esvaziou"}\n'
EOF
cat > "$W/bin/bd" <<'EOF'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >> "$FAKE_BD_LOG"
case "$3" in
  list) echo '[]' ;;
  create) echo 'ga-test01' ;;
  show) echo '[{"id":"ga-test01","labels":["exec:auto","story:approved","origem:bands","bands:ep:gate_throughput-20261114-1200"],"metadata":{"gc.routed_to":"gastown.dog"}}]' ;;
esac
EOF
chmod +x "$W/bin/claude" "$W/bin/bd"
export BANDS_CLAUDE_BIN="$W/bin/claude" BANDS_BD_BIN="$W/bin/bd"

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


# ---- statistical bands (ga-4mzkfj9): the meter judges the gate against its OWN last 14 days; the 8/h target stays a reference ----
# genband <city> <days-of-log> <rate/h in the active hours 07-22 BRT> [<hours_ago_lo>:<hours_ago_hi>:<exact rate/h>]... — a dispatcher log with
# a deterministic jitter (seed 7) on the base rate; the overridden hours have an EXACT count, so a block's band does not depend on luck
genband() {
  python3 - "$1" "$NOW" "$2" "$3" "${@:4}" <<'PY'
import sys, datetime, random
city, now, days, rate = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
over = [tuple(float(x) for x in s.split(":")) for s in sys.argv[5:]]
brt = datetime.timezone(datetime.timedelta(hours=-3))
rng = random.Random(7)
def st(t): return datetime.datetime.fromtimestamp(t, brt).strftime("%Y-%m-%d %H:%M:%S")
out = ["[%s] [quality-gate-dispatcher] dispatcher start" % st(now - days * 86400 - 600)]
n, t = 0, (int(now - days * 86400) // 3600) * 3600
while t < now:
    h = datetime.datetime.fromtimestamp(t, brt).hour
    ago_lo, ago_hi = (now - t - 3600) / 3600.0, (now - t) / 3600.0
    exact = [rr for lo, hi, rr in over if ago_lo >= lo and ago_hi <= hi]
    if exact: c = int(exact[0])
    elif 7 <= h < 22: c = max(0, int(round(rate + rng.uniform(-1.2, 1.2))))
    else: c = 0
    for i in range(c):
        n += 1
        out.append("[%s] [quality-gate-dispatcher] === Gate run complete: gate_run=ga-b%d branch=x verdict=PASS elapsed=100s ===" % (st(t + 60 + i * (3000.0 / c)), n))
    t += 3600
open(city + "/.gc/logs/quality-gate-dispatcher.log", "w").write("\n".join(sorted(out)) + "\n")
PY
}
newband() { newcity "$1"; export FAKE_BD_LOG="$W/$1.bd" FAKE_CLAUDE_LOG="$W/$1.claude"; : > "$FAKE_BD_LOG"; : > "$FAKE_CLAUDE_LOG"; }
calls() { grep -c '^CALL ' "$1"; }
NOW_NIGHT="$(TZ=UTC python3 -c 'import datetime;print(int(datetime.datetime(2026,11,15,2,0,0,tzinfo=datetime.timezone.utc).timestamp()))')"  # 23:00 BRT on 14/11

# T17 the headline: a STABLE shortfall (3/h for 14 days, far under the 8/h target) is no alarm any more; the old fixed rule alarmed on it
newband t17; genband "$C" 15 3; focus "$C" 4 "$((NOW-60))"
OUT="$(meter)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'FAIXA ok:' && ! echo "$OUT" | grep -q 'ALARM' && [ "$(mails)" = 0 ] && [ "$(calls "$FAKE_BD_LOG")" = 0 ] && ok || bad "T17 steady shortfall must stay quiet under the bands: rc=$RC mails=$(mails) out=$OUT"
[ -z "$(state alarm_since)" ] && ok || bad "T17 the fixed rule's state must stay untouched"
OUT="$(GTM_BANDS=0 meter)"; echo "$OUT" | grep -q 'ALARM: ' && [ "$(mails)" = 1 ] && ok || bad "T17b control: with the bands off the SAME log alarms by the fixed rule (that is the noise the bands remove): mails=$(mails) out=$OUT"

# T18 a collapse (the 07-10 block has NO review) → 3σ: ONE diagnosis, ONE bead, ONE mail citing both; nothing repeats
newband t18; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(meter)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'FAIXA 3σ \[WE1' && [ "$(mails)" = 1 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 1 ] && ok || bad "T18 3σ: rc=$RC mails=$(mails) claude=$(calls "$FAKE_CLAUDE_LOG") out=$OUT"
grep -q '^CALL mail send mayor -s Gate MUITO fora da faixa (3σ)' "$FAKE_GC_LOG" && grep -q 'ga-test01' "$FAKE_GC_LOG" && grep -q 'diagnóstico de teste' "$FAKE_GC_LOG" && grep -q 'Meta do produto' "$FAKE_GC_LOG" && ok || bad "T18 mail must name the band, the bead, the diagnosis and the target as a reference: $(cat "$FAKE_GC_LOG")"
grep -q -- '--tools Read,Grep,Glob' "$FAKE_CLAUDE_LOG" && ! grep -q -- 'Bash' "$FAKE_CLAUDE_LOG" && ok || bad "T18 the diagnostician is read-only by construction: $(cat "$FAKE_CLAUDE_LOG")"
grep -q 'quality-gate-dispatcher.log' "$FAKE_CLAUDE_LOG.stdin" && grep -q 'gate-focus.state' "$FAKE_CLAUDE_LOG.stdin" && grep -q 'Últimos pontos' "$FAKE_CLAUDE_LOG.stdin" && ok || bad "T18 the evidence must point at THIS meter's files and carry the series tail: $(cat "$FAKE_CLAUDE_LOG.stdin")"
grep -q 'nos últimos 14 dias' "$FAKE_GC_LOG" && ! grep -q 'últimas 14 dias' "$FAKE_GC_LOG" && grep -q 'Último ponto (até 14/11 10:00): 0 revisadas/3h, z = ' "$FAKE_GC_LOG" && ok || bad "T18 mail wording: $(cat "$FAKE_GC_LOG")"
grep -q 'create --silent -t bug -p 1' "$FAKE_BD_LOG" && grep -q 'bands:ep:gate_throughput-20261114-1200' "$FAKE_BD_LOG" && ok || bad "T18 bead: $(cat "$FAKE_BD_LOG")"
for k in 1 2 3; do python3 -I "$M" --city "$C" --now "$((NOW+300*k))" >/dev/null 2>&1; done
[ "$(mails)" = 1 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 1 ] && [ "$(grep -c ' create ' "$FAKE_BD_LOG")" = 1 ] && ok || bad "T18b nothing may repeat on the runs that follow: mails=$(mails) claude=$(calls "$FAKE_CLAUDE_LOG") bd=$(cat "$FAKE_BD_LOG")"
[ -z "$(state alarm_since)" ] && ok || bad "T18c the bands do not touch the fixed rule's alarm state"

# T19 2σ (two low blocks in a row of the series): the diagnosis and ONE mail, no bead (proposing a fix is for 3σ)
newband t19; genband "$C" 15 3 "2:5:1" "14:17:1"; focus "$C" 0 "$((NOW-60))"
OUT="$(meter)"
echo "$OUT" | grep -q 'FAIXA 2σ \[WE2\]' && [ "$(mails)" = 1 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 1 ] && [ "$(grep -c ' create ' "$FAKE_BD_LOG")" = 0 ] && grep -q 'Gate fora da faixa (2σ)' "$FAKE_GC_LOG" && ok || bad "T19 2σ: mails=$(mails) claude=$(calls "$FAKE_CLAUDE_LOG") out=$OUT / $(cat "$FAKE_GC_LOG")"

# T20 the mail fails (gc down) → rc 1, nothing stamped; when gc is back the next run delivers and does not spend the diagnosis again
newband t20; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"; echo 1 > "$FAKE_GC_RC_FILE"
OUT="$(meter)"; RC=$?
[ "$RC" = 1 ] && echo "$OUT" | grep -q 'WARN: mail da faixa 3σ FALHOU' && ok || bad "T20 failing mail: rc=$RC out=$OUT"
echo 0 > "$FAKE_GC_RC_FILE"; python3 -I "$M" --city "$C" --now "$((NOW+300))" >/dev/null 2>&1
[ "$(grep -c '^CALL mail send mayor -s Gate MUITO' "$FAKE_GC_LOG")" = 2 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 1 ] && [ "$(grep -c ' create ' "$FAKE_BD_LOG")" = 1 ] && ok || bad "T20 retry: gc=$(cat "$FAKE_GC_LOG") claude=$(calls "$FAKE_CLAUDE_LOG") bd=$(cat "$FAKE_BD_LOG")"

# T21 shadow (GTM_BANDS=shadow): the fixed rule still decides; the bands only count what they WOULD have done
newband t21; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_BANDS=shadow meter)"
echo "$OUT" | grep -q 'ALARM: ' && [ "$(mails)" = 1 ] && grep -q '^CALL mail send mayor -s Gate abaixo de 8,0/h' "$FAKE_GC_LOG" && [ "$(calls "$FAKE_CLAUDE_LOG")" = 0 ] && [ "$(calls "$FAKE_BD_LOG")" = 0 ] && ok || bad "T21 shadow must leave the fixed rule in charge and call nothing: mails=$(mails) out=$OUT"
grep -q '"ev": "would_deliver"' "$C/.gc/state/bands/ledger.jsonl" && grep -q '"shadow": true' "$C/.gc/state/bands/ledger.jsonl" && ok || bad "T21 the ledger must carry what the bands would have sent: $(cat "$C/.gc/state/bands/ledger.jsonl" 2>&1)"

# T22 kill-switch GTM_BANDS=0 → the old rule only, and the bands do not even create their directory
newband t22; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_BANDS=0 meter)"
echo "$OUT" | grep -q 'ALARM: ' && [ "$(mails)" = 1 ] && [ ! -e "$C/.gc/state/bands" ] && ok || bad "T22 GTM_BANDS=0: mails=$(mails) bands-dir=$(ls "$C/.gc/state" 2>&1) out=$OUT"

# T23 silence 22-07: a 3σ at 23:00 is judged by nobody (the alarm waits, it is not lost): no mail, no claude, no bead, no state
newband t23; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW_NIGHT-60))"
OUT="$(python3 -I "$M" --city "$C" --now "$NOW_NIGHT" 2>&1)"; RC=$?
[ "$RC" = 0 ] && echo "$OUT" | grep -q 'SILÊNCIO 22-07 h' && ! echo "$OUT" | grep -q 'ALARM' && [ "$(mails)" = 0 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 0 ] && ok || bad "T23 silence: rc=$RC mails=$(mails) out=$OUT"

# T24 --report prints the band line and stays read-only (no bands dir, no lock, no mail); --dry-run decides and sends nothing
newband t24; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(meter --report)"
echo "$OUT" | grep -q 'FAIXA 3σ' && [ ! -e "$C/.gc/state/bands" ] && [ "$(mails)" = 0 ] && ok || bad "T24 --report: state=$(ls "$C/.gc" 2>&1) out=$OUT"
OUT="$(meter --dry-run)"
echo "$OUT" | grep -q 'FAIXA 3σ' && [ "$(mails)" = 0 ] && [ "$(calls "$FAKE_CLAUDE_LOG")" = 0 ] && [ ! -e "$C/.gc/state/bands/gate_throughput.json" ] && ok || bad "T24b --dry-run: mails=$(mails) out=$OUT"

# T25 the bands cannot start (config unreadable) → loud WARN and the OLD rule stays in charge; never silence
newband t25; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_BANDS_CONFIG="$W/nonexistent/bands.yaml" meter)"
echo "$OUT" | grep -q 'WARN: faixas indisponíveis' && echo "$OUT" | grep -q 'ALARM: ' && [ "$(mails)" = 1 ] && ok || bad "T25 unreadable bands.yaml: mails=$(mails) out=$OUT"
printf 'version: 1\nmetrcs:\n' > "$W/typo.yaml"
newband t25b; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(GTM_BANDS_CONFIG="$W/typo.yaml" meter)"
echo "$OUT" | grep -q 'WARN: faixas indisponíveis' && [ "$(mails)" = 1 ] && ok || bad "T25b a typo in bands.yaml must not silence the gate alarm: out=$OUT"

# T26 learning: a log with only 5 days has too few blocks for a baseline → the old rule decides (no regression while the bands learn)
newband t26; genband "$C" 5 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
OUT="$(meter)"
echo "$OUT" | grep -q 'FAIXA aprendendo' && echo "$OUT" | grep -q 'ALARM: ' && [ "$(mails)" = 1 ] && ok || bad "T26 learning: mails=$(mails) out=$OUT"

# T27 an alarm state left by the old rule is cleared when the bands take over (a later fallback must not think an alarm is still open)
newband t27; genband "$C" 15 3; focus "$C" 4 "$((NOW-60))"
echo "{\"alarm_since\": $((NOW-90000)), \"last_mail\": $((NOW-90000)), \"blind_since\": 5}" > "$C/.gc/state/gate-throughput-meter.json"
meter >/dev/null
[ -z "$(state alarm_since)" ] && [ -z "$(state last_mail)" ] && [ -z "$(state blind_since)" ] && ok || bad "T27 legacy keys (an old blindness is over too: a stale blind_since would fire the next blindness mail at once): alarm_since=$(state alarm_since) last_mail=$(state last_mail) blind_since=$(state blind_since)"

# T28 a dismissal (bands.py dismiss): the same data is NOT re-alarmed, and the reason is in the ledger
newband t28; genband "$C" 15 3 "2:5:0"; focus "$C" 0 "$((NOW-60))"
meter >/dev/null
python3 -I "$S_DIR/bands.py" dismiss --city "$C" --metric gate_throughput --reason "manutenção planejada do gate" --by teste --now "$((NOW+60))" >/dev/null
OUT="$(python3 -I "$M" --city "$C" --now "$((NOW+120))" 2>&1)"
echo "$OUT" | grep -q 'FAIXA ok' && [ "$(mails)" = 1 ] && grep -q 'manutenção planejada do gate' "$C/.gc/state/bands/ledger.jsonl" && ok || bad "T28 dismissal: mails=$(mails) out=$OUT"

echo "gate-throughput-meter.selftest: $PASS ok, $FAIL failed"
[ "$FAIL" = 0 ]
