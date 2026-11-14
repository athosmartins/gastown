#!/usr/bin/env bash
# gate-throughput-meter.selftest.sh — hermetic (ga-v8p1tx.1.1): a scratch city, a synthetic dispatcher log built
# relative to a fixed NOW, a fake `gc` that records mails. Never touches the real log, state, Dolt or mail.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gate-meter-st.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
C="$W/city"; mkdir -p "$C/.gc/logs" "$W/bin"
LOG="$C/.gc/logs/quality-gate-dispatcher.log"
MAILLOG="$W/mail.log"; export MAILLOG
cat > "$W/bin/gc" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_GC_RC:-}" ]; then echo "boom" >&2; exit 3; fi
{ echo MAIL; for a in "$@"; do printf '%s\n' "$a"; done; echo ENDMAIL; } >> "$MAILLOG"
EOF
chmod +x "$W/bin/gc"; export GATE_MEASURE_GC="$W/bin/gc"
NOW=$(/usr/bin/python3 -c 'import datetime as d;print(int(d.datetime(2026,11,14,12,0,0,tzinfo=d.timezone(d.timedelta(hours=-3))).timestamp()))')

# mklog <file> <first-line age in hours> <bucket counts, bucket 0 = last hour ... as csv> [extra "age_min:VERDICT" ...]
cat > "$W/mk.py" <<'EOF'
import datetime as d, sys
TZ = d.timezone(d.timedelta(hours=-3))
out, now, first_h, buckets = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), [int(x) for x in sys.argv[4].split(",") if x != ""]
extra = sys.argv[5:]
def L(t, body): return "[%s] [quality-gate-dispatcher] %s\n" % (d.datetime.fromtimestamp(t, TZ).strftime("%Y-%m-%d %H:%M:%S"), body)
lines = ["landing verified (attempt 2): crew/x → main (sha=abc)\n"]      # a continuation line with no timestamp, as in the real log
lines.append(L(now - first_h * 3600, "Dispatcher sweep start"))
for k, n in enumerate(buckets):
    for i in range(n):
        t = now - k * 3600 - 60 - i * (3300 // max(n, 1))                 # inside bucket k, away from the edges
        lines.append(L(t, "=== Gate run complete: gate_run=ga-%d%d branch=b verdict=%s elapsed=900s ===" % (k, i, "FAIL" if i % 4 == 3 else "PASS")))
for e in extra:
    age, v = e.split(":")
    lines.append(L(now - float(age) * 60, "=== Gate run complete: gate_run=ga-x branch=b verdict=%s elapsed=900s ===" % v))
lines.append(L(now - 60, "Dispatcher sweep start"))
open(out, "w").write("".join(lines))
EOF
mklog() { /usr/bin/python3 "$W/mk.py" "$LOG" "$NOW" "$@"; }
run() { /usr/bin/python3 "$HERE/gate-throughput-meter.py" --city "$C" --now "${AT:-$NOW}" "$@"; }
mails() { [ -f "$MAILLOG" ] && grep -c '^MAIL$' "$MAILLOG" || echo 0; }
reset() { rmdir "$C/.gc/gate-throughput-meter.state" 2>/dev/null; rm -f "$MAILLOG" "$C/.gc/gate-throughput-meter.state"; unset AT FAKE_GC_RC; }
queue() { printf 'active=0\nsince=1\ndepth=%s\nat=%s\nescalated=0\n' "$1" "${2:-$NOW}" > "$C/.gc/gate-focus.state"; }

# T1: counts. Buckets 0..2 = 10 each (30 in 3 h, 3 FAIL-of-4 pattern), buckets 3..23 = 2 each -> 24 h total 72.
# A SKIPPED_BEAD_CLOSED line 10 min ago must NOT count. Healthy: rate 10,0/h.
mklog 30 "10,10,10,$(printf '2,%.0s' $(seq 1 21))" "10:SKIPPED_BEAD_CLOSED"
J="$(run --json)"
[ "$(echo "$J" | jq -r '.window_count')" = "30" ] && ok || bad "T1 window_count want 30: $(echo "$J" | jq -c '.window_count')"
[ "$(echo "$J" | jq '.window_rate == 10')" = "true" ] && ok || bad "T1 window_rate want 10: $(echo "$J" | jq -c '.window_rate')"
[ "$(echo "$J" | jq '.avg24 == 3')" = "true" ] && ok || bad "T1 avg24 want 3 (72/24): $(echo "$J" | jq -c '.avg24')"
[ "$(echo "$J" | jq -c '.hourly24')" = "[$(printf '2,%.0s' $(seq 1 21))10,10,10]" ] && ok || bad "T1 hourly24 oldest->newest: $(echo "$J" | jq -c '.hourly24')"
OUT="$(run)"; echo "$OUT" | grep -q 'janela 3 h: 10,0/h (30 em 3 h) | média 24 h: 3,0/h (72 em 24 h) | meta ≥ 8,0/h' && ok || bad "T1 summary: $OUT"

# T2: healthy rate never mails, even with --alarm
reset; queue 0; run --alarm >/dev/null; [ "$(mails)" = "0" ] && ok || bad "T2 mailed at 10/h"

# T3: low rate (6 in 3 h = 2,0/h) mails the Mayor once, subject has rate and cause; body has the count and the queue read
mklog 30 "3,2,1,$(printf '1,%.0s' $(seq 1 21))"
reset; queue 0; run --alarm >/dev/null; RC=$?
[ "$RC" = "0" ] && ok || bad "T3 rc=$RC"
[ "$(mails)" = "1" ] && ok || bad "T3 want 1 mail, got $(mails)"
grep -q '^mayor/$' "$MAILLOG" && grep -q 'Gate: 2,0 revisadas/h nas últimas 3 h (meta ≥ 8,0) — causa provável: oferta' "$MAILLOG" && ok || bad "T3 subject/to: $(cat "$MAILLOG" 2>/dev/null | head -8)"
grep -q 'OFERTA: fila do gate com 0' "$MAILLOG" && grep -q '6 revisadas (PASS+FAIL) nas últimas 3 h' "$MAILLOG" && ok || bad "T3 body"

# T4: cause follows the queue — full queue => REVISORES; unreadable/stale queue => 'causa não medida', never 'oferta'
reset; queue 5; run --alarm >/dev/null
grep -q 'causa provável: revisores' "$MAILLOG" && grep -q 'REVISORES: fila do gate com 5' "$MAILLOG" && ok || bad "T4 full queue: $(sed -n 3p "$MAILLOG")"
reset; rm -f "$C/.gc/gate-focus.state"; run --alarm >/dev/null
grep -q 'causa provável: desconhecida' "$MAILLOG" && ! grep -q 'OFERTA' "$MAILLOG" && ok || bad "T4 missing queue must not read as oferta: $(sed -n 3p "$MAILLOG")"
reset; queue 0 $((NOW - 7200)); run --alarm >/dev/null
grep -q 'causa provável: desconhecida' "$MAILLOG" && ok || bad "T4 stale queue (2 h old) must not read as oferta"

# T5: cooldown — a second run 15 min later does not mail again; 6 h + 1 min later it does
reset; queue 0; run --alarm >/dev/null
AT=$((NOW + 900)); export AT; run --alarm >/dev/null; [ "$(mails)" = "1" ] && ok || bad "T5 re-mailed inside cooldown ($(mails))"
AT=$((NOW + 21600 + 60)); export AT; run --alarm >/dev/null; [ "$(mails)" = "2" ] && ok || bad "T5 should mail again after the cooldown ($(mails))"
unset AT

# T6: mail failure -> exit 1, cooldown NOT consumed: the next cycle (gc back) mails
reset; queue 0; FAKE_GC_RC=3 run --alarm >/dev/null 2>"$W/err"; RC=$?
[ "$RC" = "1" ] && ok || bad "T6 rc want 1 got $RC"
grep -q 'mail ao Mayor falhou' "$W/err" && ok || bad "T6 stderr: $(cat "$W/err")"
run --alarm >/dev/null; [ "$(mails)" = "1" ] && ok || bad "T6 retry after a failed mail must send ($(mails))"

# T6b: gc cannot even be started (not found) -> same: exit 1, WARN names the failure, cooldown not consumed
reset; queue 0; GATE_MEASURE_GC="$W/bin/no-such-gc" run --alarm >/dev/null 2>"$W/err"; RC=$?
[ "$RC" = "1" ] && grep -q 'mail ao Mayor falhou' "$W/err" && [ "$(mails)" = "0" ] && ok || bad "T6b rc=$RC err=$(cat "$W/err")"
run --alarm >/dev/null; [ "$(mails)" = "1" ] && ok || bad "T6b retry after a missing gc must send ($(mails))"

# T7: state unreadable (a directory where the file should be) -> inert: no mail, rc 1
reset; queue 0; mkdir "$C/.gc/gate-throughput-meter.state"; run --alarm >/dev/null 2>"$W/err"; RC=$?
[ "$RC" = "1" ] && [ "$(mails)" = "0" ] && ok || bad "T7 rc=$RC mails=$(mails)"
# T7b: state file present but not readable (mode 000) -> same: unknown cooldown must never read as "no alarm yet"
reset; queue 0; printf 'last_alarm_at=0\n' > "$C/.gc/gate-throughput-meter.state"; chmod 000 "$C/.gc/gate-throughput-meter.state"
run --alarm >/dev/null 2>"$W/err"; RC=$?
[ "$RC" = "1" ] && [ "$(mails)" = "0" ] && grep -q 'estado do medidor ilegível' "$W/err" && ok || bad "T7b rc=$RC mails=$(mails) err=$(cat "$W/err")"
reset

# T8: third state — no log at all is 'não medido', exit 1, never '0/h'; no low-rate mail
rm -f "$LOG"; OUT="$(run)"; RC=$?
echo "$OUT" | grep -q 'não medido (log ilegível' && ! echo "$OUT" | grep -q '0,0/h' && [ "$RC" = "1" ] && ok || bad "T8 missing log: rc=$RC out=$OUT"
reset; queue 0; run --alarm >/dev/null 2>&1; [ "$(mails)" = "0" ] && ok || bad "T8 mailed 'baixa' on an unreadable log"

# T9: log that starts INSIDE the window (rotated) is 'não medido', not a low rate; 24 h average likewise
mklog 1 "0"; OUT="$(run)"
echo "$OUT" | grep -q 'janela 3 h: não medido (log só começa em' && echo "$OUT" | grep -q 'média 24 h: não medido' && ok || bad "T9 rotated log: $OUT"
reset; queue 0; run --alarm >/dev/null 2>&1; [ "$(mails)" = "0" ] && ok || bad "T9 mailed 'baixa' on a rotated log"
# 5 h of log: the window is measurable (and low), the 24 h average is not
mklog 5 "1,0,1,0,1"; OUT="$(run)"
echo "$OUT" | grep -q 'janela 3 h: 0,7/h (2 em 3 h)' && echo "$OUT" | grep -q 'média 24 h: não medido' && ok || bad "T9b partial coverage: $OUT"

# T10: blind meter — unmeasurable for 3 h in a row mails ONE 'cego' (not before 3 h)
rm -f "$LOG"; reset; queue 0
run --alarm >/dev/null 2>&1; [ "$(mails)" = "0" ] && ok || bad "T10 mailed 'cego' on the first unmeasured run"
AT=$((NOW + 10800 + 60)); export AT; run --alarm >/dev/null 2>&1
[ "$(mails)" = "1" ] && grep -q 'medidor de revisadas/h CEGO' "$MAILLOG" && ok || bad "T10 'cego' after 3 h: $(mails)"
AT=$((NOW + 10800 + 960)); export AT; run --alarm >/dev/null 2>&1; [ "$(mails)" = "1" ] && ok || bad "T10 'cego' repeated inside cooldown"
reset

# T11: --day. Day 13/11 fully inside the log: hourly counts + average; the current day is 'ainda em curso'
/usr/bin/python3 - "$LOG" "$NOW" <<'EOF'
import datetime as d, sys
TZ = d.timezone(d.timedelta(hours=-3)); now = int(sys.argv[2])
day0 = d.datetime(2026, 11, 13, tzinfo=TZ).timestamp()
def L(t, b): return "[%s] [quality-gate-dispatcher] %s\n" % (d.datetime.fromtimestamp(t, TZ).strftime("%Y-%m-%d %H:%M:%S"), b)
ls = [L(day0 - 3600, "Dispatcher sweep start")]
for h, n in ((0, 4), (5, 2), (23, 1)):
    for i in range(n): ls.append(L(day0 + h * 3600 + 120 + i * 60, "=== Gate run complete: gate_run=g branch=b verdict=PASS elapsed=1s ==="))
ls.append(L(day0 + 86400 + 60, "=== Gate run complete: gate_run=g branch=b verdict=FAIL elapsed=1s ==="))   # next day: not in the 13th
ls.append(L(now - 60, "Dispatcher sweep start"))
open(sys.argv[1], "w").write("".join(ls))
EOF
J="$(run --json --day 2026-11-13)"
[ "$(echo "$J" | jq -r '.day.total')" = "7" ] && [ "$(echo "$J" | jq -c '.day.hourly | [.[0], .[5], .[23], .[1]]')" = "[4,2,1,0]" ] && ok || bad "T11 day buckets: $(echo "$J" | jq -c .day)"
OUT="$(run --day 2026-11-13)"; echo "$OUT" | grep -q 'dia 2026-11-13: 0,3/h (7 em 24 h)' && ok || bad "T11 day line: $OUT"
OUT="$(run --day 2026-11-14)"; echo "$OUT" | grep -q 'dia 2026-11-14: não medido (dia ainda em curso)' && ok || bad "T11 today: $OUT"
OUT="$(run --day 2026-11-01)"; echo "$OUT" | grep -q 'dia 2026-11-01: não medido (log só começa em' && ok || bad "T11 day before the log: $OUT"

# T12: single instance — while another run holds the lock, --alarm leaves quietly (no mail, rc 0)
mklog 30 "3,2,1,$(printf '1,%.0s' $(seq 1 21))"; reset; queue 0
/usr/bin/python3 -c "
import fcntl,time,sys
f=open(sys.argv[1],'w'); fcntl.flock(f,fcntl.LOCK_EX); print('held',flush=True); time.sleep(8)" "$C/.gc/gate-throughput-meter.lock" > "$W/held" &
HP=$!; for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q held "$W/held" 2>/dev/null && break; sleep 0.3; done
OUT="$(run --alarm)"; RC=$?
kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null
[ "$RC" = "0" ] && [ "$(mails)" = "0" ] && echo "$OUT" | grep -q 'outro run' && ok || bad "T12 lock: rc=$RC mails=$(mails) out=$OUT"

# T13: dry run (no --alarm) writes no state and sends nothing, even when the rate is low
reset; queue 0; run >/dev/null; [ "$(mails)" = "0" ] && [ ! -e "$C/.gc/gate-throughput-meter.state" ] && ok || bad "T13 dry run wrote state or mailed"

echo "gate-throughput-meter.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
