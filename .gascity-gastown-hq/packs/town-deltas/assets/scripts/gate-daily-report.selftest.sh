#!/usr/bin/env bash
# gate-daily-report.selftest.sh — hermetic: a scratch city with a synthetic quality-gate.jsonl, state file,
# agent.toml files and a fake model catalog (HOME is redirected). Never posts (no --post).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/gate-daily-st.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
C="$W/city"; mkdir -p "$C/.gc/state" "$C/.gc/logs" "$C/agents/gate-reviewer" "$C/agents/wa-worker"
export HOME="$W/home"; mkdir -p "$HOME/.gastown/claude-accounts/x/cache/model-catalog"
cat > "$HOME/.gastown/claude-accounts/x/cache/model-catalog/a.json" <<'EOF'
{"fetchedAt":"2026-10-07T10:00:00Z","catalog":{"config":{"models":[{"id":"claude-sonnet-5-5","short_name":"Sonnet"},{"id":"claude-opus-5-5","short_name":"Opus"}]}}}
EOF
printf 'model = "sonnet"\n' > "$C/agents/gate-reviewer/agent.toml"
printf 'model = "opus"\n'   > "$C/agents/wa-worker/agent.toml"
# day under test = 2026-10-06 BRT. Bead A: first verdict PASS on 06 (first-attempt yes). Bead B: FAIL on 05 (first attempt
# belongs to 05), PASS on 06. Bead C: first verdict FAIL on 06. A dry-run row and a SUPERSEDED row must be ignored.
cat > "$C/.gc/quality-gate.jsonl" <<'EOF'
{"event":"dispatcher_complete","ts":"2026-10-06T12:00:00Z","bead":"A","result":"PASS","elapsed_s":"600","rig":"wa","dry_run":"0"}
{"event":"dispatcher_complete","ts":"2026-10-05T23:00:00Z","bead":"B","result":"FAIL","elapsed_s":"1200","rig":"wa","dry_run":"0"}
{"event":"dispatcher_complete","ts":"2026-10-06T15:00:00Z","bead":"B","result":"PASS","elapsed_s":"1800","rig":"wa","dry_run":"0"}
{"event":"dispatcher_complete","ts":"2026-10-06T16:00:00Z","bead":"C","result":"FAIL","elapsed_s":"2400","rig":"ga","dry_run":"0"}
{"event":"dispatcher_complete","ts":"2026-10-06T17:00:00Z","bead":"D","result":"PASS","elapsed_s":"60","rig":"wa","dry_run":"1"}
{"event":"dispatcher_complete","ts":"2026-10-06T17:30:00Z","bead":"E","result":"SUPERSEDED","elapsed_s":"60","rig":"wa","dry_run":"0"}
{"event":"other","ts":"2026-10-06T18:00:00Z"}
EOF
printf 'active=1\nsince=1\ndepth=27\nat=%s\nescalated=0\n' "$(date +%s)" > "$C/.gc/gate-focus.state"
touch "$C/.gc/gate-e11-diff-cap.on" "$C/.gc/gate-e11-diff-cap.all" "$C/.gc/gate-e5-second-reviewer.on"
printf 'treated_pct=100\n' > "$C/.gc/e12-ab.conf"

OUT="$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06)"; RC=$?
[ "$RC" = "0" ] && ok || bad "exit code $RC"
echo "$OUT" | grep -q '1) 1ª tentativa: 50% (1/2 beads)' && ok || bad "first-attempt: want 50% (1/2) — A pass, C fail; B's first attempt was on the 05th. got: $(echo "$OUT" | sed -n 2p)"
echo "$OUT" | grep -q '2) aprovadas: 2 (vereditos 3, FAIL 1, taxa 67%)' && ok || bad "approvals line: $(echo "$OUT" | sed -n 3p)"
echo "$OUT" | grep -q '3) revisão mediana: 30 min' && ok || bad "median: want 30 min (600,1800,2400 s). got: $(echo "$OUT" | sed -n 4p)"
echo "$OUT" | grep -q 'por rig: ga 0/1; wa 2/2' && ok || bad "by rig: $(echo "$OUT" | grep 'por rig')"
echo "$OUT" | grep -q '4) fila do gate agora: 27 (medida há 0 min)' && ok || bad "queue: $(echo "$OUT" | grep '4)')"
echo "$OUT" | grep -q 'modo foco=LIGADO' && echo "$OUT" | grep -q 'E5 2º revisor=ligado, SUSPENSO pelo modo foco' && echo "$OUT" | grep -q 'E11 teto 800 linhas=ligado (100%)' && echo "$OUT" | grep -q 'E12 3º estado na escrita=ligado (100% tratados)' && ok || bad "switches: $(echo "$OUT" | grep Chaves)"
echo "$OUT" | grep -q 'gate-reviewer=sonnet→claude-sonnet-5-5' && echo "$OUT" | grep -q 'wa-worker=opus→claude-opus-5-5' && ok || bad "models: $(echo "$OUT" | grep Modelos)"
echo "$OUT" | grep -q 'primeira foto dos modelos' && ok || bad "first snapshot line missing"

# T2: the alias moves to a successor -> the report says MUDOU (the 28/09 class, now visible the same day)
cat > "$HOME/.gastown/claude-accounts/x/cache/model-catalog/b.json" <<'EOF'
{"fetchedAt":"2026-10-08T10:00:00Z","catalog":{"config":{"models":[{"id":"claude-sonnet-6","short_name":"Sonnet"},{"id":"claude-opus-5-5","short_name":"Opus"}]}}}
EOF
OUT2="$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06)"
echo "$OUT2" | grep -q 'MUDOU: gate-reviewer claude-sonnet-5-5 -> claude-sonnet-6 (alias sonnet)' && ok || bad "model change not flagged: $(echo "$OUT2" | grep -E 'MUDOU|foto')"
echo "$OUT2" | grep -q 'MUDOU: wa-worker' && bad "opus did not change but was flagged" || ok

# T3: third state — no jsonl is 'não medido', never 0; no state file is 'não medido'
rm -f "$C/.gc/quality-gate.jsonl" "$C/.gc/gate-focus.state"
OUT3="$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06)"
echo "$OUT3" | grep -q '1) 1ª tentativa: não medido (jsonl ilegível' && ok || bad "missing jsonl must read 'não medido': $(echo "$OUT3" | sed -n 2p)"
echo "$OUT3" | grep -q '4) fila do gate agora: não medido (sem gate-focus.state)' && ok || bad "missing state must read 'não medido': $(echo "$OUT3" | grep '4)')"
echo "$OUT3" | grep -qE 'aprovadas: 0|1ª tentativa: 0%' && bad "a read failure printed as a zero" || ok

# T4: a day with no verdicts is 'sem vereditos', not 0%
printf '{"event":"dispatcher_complete","ts":"2026-10-01T12:00:00Z","bead":"Z","result":"PASS","elapsed_s":"600","rig":"wa","dry_run":"0"}\n' > "$C/.gc/quality-gate.jsonl"
OUT4="$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06)"
echo "$OUT4" | grep -q '1) 1ª tentativa: não medido (sem vereditos) (0/0 beads)' && echo "$OUT4" | grep -q 'taxa não medido (sem vereditos)' && ok || bad "empty day: $(echo "$OUT4" | sed -n 2,3p)"

# ── ga-ufskhy 07/10: lines 5) and 6) — timeouts / E13 / E11, each from its own source, each honest when unreadable ──
mkdir -p "$C/.gc/logs"
cat > "$C/.gc/quality-gate.jsonl" <<'EOF'
{"event":"dispatcher_complete","ts":"2026-10-06T12:00:00Z","bead":"A","result":"PASS","elapsed_s":"600","rig":"wa","dry_run":"0"}
EOF
cat > "$C/.gc/logs/quality-gate-dispatcher.log" <<'EOF'
[2026-10-06 09:00:00] [quality-gate-dispatcher] WARN: Phase C: gate-run ga-aaa111 (branch=crew/x/y) TIMED OUT after 2435s (limit=2340s) with 0/1 verdicts. Treating as FAIL.
[2026-10-06 09:30:00] [quality-gate-dispatcher] WARN: Phase C: gate-run ga-aaa111 (branch=crew/x/y) TIMED OUT after 2435s (limit=2340s) with 0/1 verdicts. Treating as FAIL.
[2026-10-06 10:00:00] [quality-gate-dispatcher] WARN: Phase C: gate-run ga-bbb222 (branch=crew/x/z) TIMED OUT after 4801s (limit=3000s, grace=1800s, busy=1, judged_fails=0) with 0/1 verdicts. Treating as FAIL.
[2026-10-06 10:05:00] [quality-gate-dispatcher] Phase C: gate-run ga-ccc333 (branch=crew/x/w) is PAST its 3000s verdict budget (3100s) but reviewer r is busy (mid-turn, pane output within the last 900s) and no FAIL is in — E13 GRACE: waiting up to 1700s more (ceiling 4800s); leaving for a future sweep.
[2026-10-06 10:06:00] [quality-gate-dispatcher] Phase C: gate-run ga-ccc333 (branch=crew/x/w) is PAST its 3000s verdict budget (3160s) but reviewer r is busy (mid-turn, pane output within the last 900s) and no FAIL is in — E13 GRACE: waiting up to 1640s more (ceiling 4800s); leaving for a future sweep.
[2026-10-07 10:00:00] [quality-gate-dispatcher] WARN: Phase C: gate-run ga-ddd444 (branch=crew/x/v) TIMED OUT after 2435s (limit=2340s) with 0/1 verdicts. Treating as FAIL.
EOF
cat > "$C/.gc/logs/quality-gate-guard.log" <<'EOF'
[2026-10-06 11:00:00] [quality-gate-guard] E11-DIFF-CAP bead=wa-1 arm=B verdict=recusa production_lines=1001 cap=800 exempt=nao why=- branch=b marker=m forced=0
[2026-10-06 11:10:00] [quality-gate-guard] E11-DIFF-CAP bead=wa-2 arm=B verdict=dentro-do-teto production_lines=40 cap=800 exempt=nao-consultado why=- branch=b marker=m forced=1
[2026-10-06 11:20:00] [quality-gate-guard] E11-DIFF-CAP bead=wa-3 arm=B verdict=nao-medido-isencao production_lines=900 cap=800 exempt=desconhecido why=isencao-ilegivel branch=b marker=m forced=0
[2026-10-07 11:00:00] [quality-gate-guard] E11-DIFF-CAP bead=wa-4 arm=B verdict=recusa production_lines=1001 cap=800 exempt=nao why=- branch=b marker=m forced=0
EOF
cat > "$C/.gc/gate-e13.jsonl" <<'EOF'
{"ts":"2026-10-06T13:05:00Z","event":"e13_grace","outcome":"","run":"ga-ccc333","branch":"crew/x/w","elapsed":3100,"budget":3000,"grace":1800,"busy_sid":"r"}
{"ts":"2026-10-06T13:06:00Z","event":"e13_grace","outcome":"","run":"ga-ccc333","branch":"crew/x/w","elapsed":3160,"budget":3000,"grace":1800,"busy_sid":"r"}
{"ts":"2026-10-06T13:40:00Z","event":"e13_outcome","outcome":"delivered-past-budget","run":"ga-ccc333","branch":"crew/x/w","elapsed":5000,"budget":3000,"grace":1800,"busy_sid":""}
{"ts":"2026-10-06T13:00:00Z","event":"e13_outcome","outcome":"grace-exhausted","run":"ga-bbb222","branch":"crew/x/z","elapsed":4801,"budget":3000,"grace":1800,"busy_sid":"r"}
{"ts":"2026-10-07T13:00:00Z","event":"e13_outcome","outcome":"delivered-past-budget","run":"ga-eee555","branch":"crew/x/u","elapsed":2441,"budget":2340,"grace":1800,"busy_sid":""}
not json at all
EOF
OUT5=$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06 2>&1)
echo "$OUT5" | grep -q '5) tempo estourado: 2 run(s) estouraram o tempo (1 com revisor ocupado no corte) | 1 run(s) receberam grace E13 | E13: 1 run(s) entregaram depois do orçamento, 1 esgotaram a grace (ledger: 1 com grace)' && ok || bad "line 5 (timeouts by distinct run, busy count, graces, ledger outcomes for THE day only): $(echo "$OUT5" | grep '^5)')"
echo "$OUT5" | grep -q '6) E11 (teto 800 linhas de produção): 1 recusa(s), 1 dentro do teto, 0 controle, 1 não medida(s)' && ok || bad "line 6 (E11 decisions for the day, nao-medido family counted as not measured): $(echo "$OUT5" | grep '^6)')"
rm -f "$C/.gc/logs/quality-gate-dispatcher.log" "$C/.gc/gate-e13.jsonl"
OUT6=$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06 2>&1)
echo "$OUT6" | grep -q '5) tempo estourado: não medido (log do dispatcher ilegível: FileNotFoundError) | não medido (log do dispatcher ilegível: FileNotFoundError) | E13: não medido (ledger E13 ilegível: FileNotFoundError)' && ok || bad "unreadable sources must say so, never print 0: $(echo "$OUT6" | grep '^5)')"
echo "$OUT6" | grep -q '6) E11 (teto 800 linhas de produção): 1 recusa(s)' && ok || bad "a readable source still reports while its siblings are unreadable: $(echo "$OUT6" | grep '^6)')"
: > "$C/.gc/logs/quality-gate-guard.log"
OUT7=$(/usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06 2>&1)
echo "$OUT7" | grep -q '6) E11 (teto 800 linhas de produção): 0 decisões registradas' && ok || bad "empty guard log for the day = '0 decisões registradas' (distinct from unreadable): $(echo "$OUT7" | grep '^6)')"

# ── ga-3xrr3l 24/10: --post must not lose the day silently. The bd comment is retried (3 tries), bd's own stderr is
# shown, and when it still fails the notify says "NÃO gravado" at a higher priority (it used to be the normal notify,
# so the phone got the numbers and nobody knew the bead — the record — was missing the day). Fake bd/notify come first
# on PATH, so nothing here can reach the real ga-ufskhy; the retry sleep is 0. ──
FAKE_DIR="$W/fake"; FB="$W/fakebin"; FBN="$W/fakebin-nobd"; mkdir -p "$FAKE_DIR" "$FB" "$FBN"
cat > "$FB/bd" <<'EOF'
#!/bin/sh
# counts every call; fails the first $FAKE_BD_FAIL_UNTIL calls with a message on stderr, then succeeds
n=$(cat "$FAKE_DIR/bd.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$FAKE_DIR/bd.count"
if [ "$n" -le "${FAKE_BD_FAIL_UNTIL:-0}" ]; then echo "boom: dolt gone (call $n)" >&2; exit 1; fi
exit 0
EOF
cat > "$FB/notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_DIR/notify.log"
EOF
cp "$FB/notify" "$FBN/notify"; chmod +x "$FB/bd" "$FB/notify" "$FBN/notify"
post_run() {  # $1 = how many bd calls fail first, $2 = PATH; leaves POUT (stdout+stderr) and PRC
  rm -f "$FAKE_DIR/bd.count" "$FAKE_DIR/notify.log"
  POUT="$(PATH="$2" FAKE_DIR="$FAKE_DIR" FAKE_BD_FAIL_UNTIL="$1" GATE_DAILY_RETRY_SLEEP=0 /usr/bin/python3 "$HERE/gate-daily-report.py" --city "$C" --day 2026-10-06 --post 2>&1)"; PRC=$?
}
bd_calls()    { cat "$FAKE_DIR/bd.count" 2>/dev/null || echo 0; }
notify_calls(){ [ -f "$FAKE_DIR/notify.log" ] && wc -l < "$FAKE_DIR/notify.log" | tr -d ' ' || echo 0; }

# T8a: bd keeps failing -> 3 tries, bd's stderr on screen, exit 1, ONE notify that says the report was NOT recorded
post_run 99 "$FB:$PATH"
[ "$(bd_calls)" = "3" ] && ok || bad "T8a: bd comment must be tried 3 times, was tried $(bd_calls)x"
echo "$POUT" | grep -q 'boom: dolt gone' && ok || bad "T8a: bd's own stderr must reach the log, got: $(echo "$POUT" | grep WARN)"
[ "$PRC" = "1" ] && ok || bad "T8a: exit code must be 1 when the report was not recorded, got $PRC"
[ "$(notify_calls)" = "1" ] && ok || bad "T8a: exactly one notify, got $(notify_calls)"
grep -q 'relatório NÃO gravado na ga-ufskhy' "$FAKE_DIR/notify.log" 2>/dev/null && ok || bad "T8a: notify must say the report was not recorded on ga-ufskhy, got: $(cat "$FAKE_DIR/notify.log" 2>/dev/null)"
grep -q -e '-p 4' "$FAKE_DIR/notify.log" 2>/dev/null && ok || bad "T8a: the not-recorded notify must be priority 4, got: $(cat "$FAKE_DIR/notify.log" 2>/dev/null)"

# T8b: a transient failure (first 2 calls) -> the 3rd try records it: exit 0, the NORMAL notify (priority 3, no alarm)
post_run 2 "$FB:$PATH"
[ "$(bd_calls)" = "3" ] && ok || bad "T8b: expected 3 bd calls (2 fail + 1 ok), got $(bd_calls)"
[ "$PRC" = "0" ] && ok || bad "T8b: a retry that recorded the report must exit 0, got $PRC"
grep -q -e '-p 3' "$FAKE_DIR/notify.log" 2>/dev/null && ! grep -q 'NÃO gravado' "$FAKE_DIR/notify.log" && ok || bad "T8b: a recorded report gets the normal notify, got: $(cat "$FAKE_DIR/notify.log" 2>/dev/null)"

# T8c: first try works -> no retry, no alarm
post_run 0 "$FB:$PATH"
[ "$(bd_calls)" = "1" ] && [ "$PRC" = "0" ] && ok || bad "T8c: clean path = 1 bd call and exit 0, got $(bd_calls) call(s), exit $PRC"

# T8d: bd cannot even be started (not on PATH) is the same "not recorded", with the reason on screen
post_run 0 "$FBN"
[ "$PRC" = "1" ] && grep -q 'relatório NÃO gravado na ga-ufskhy' "$FAKE_DIR/notify.log" 2>/dev/null && ok || bad "T8d: bd missing must read as not recorded (exit $PRC): $(cat "$FAKE_DIR/notify.log" 2>/dev/null)"
# scoped to the WARN line: the report body itself says "FileNotFoundError" for other unreadable sources
echo "$POUT" | grep 'WARN' | grep -q 'FileNotFoundError' && ok || bad "T8d: the reason (FileNotFoundError) must be on the WARN line, got: $(echo "$POUT" | grep WARN)"

echo "gate-daily-report selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
