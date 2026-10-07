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

echo "gate-daily-report selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
