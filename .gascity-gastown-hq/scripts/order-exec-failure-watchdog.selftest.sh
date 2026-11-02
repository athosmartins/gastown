#!/usr/bin/env bash
# order-exec-failure-watchdog.selftest.sh — hermetic proof for ga-q5t8r: a
# supervisor order that fails repeatedly must alert the Mayor, exactly once per
# cooldown window, with the engine's own diagnostic line attached — and a
# benign `context canceled` failure must never count or alert at all.
#
# No live supervisor.log/gc/launchd/notify: SUPERVISOR_LOG points at a fixture
# this test builds incrementally (simulating successive 5-min sweeps by
# appending lines and re-invoking run_sweep), and `gc`/`notify` are stubbed to
# record their calls instead of doing anything. Sources the watchdog in lib
# mode (ORDER_EXEC_FAILURE_WATCHDOG_LIB=1) so run_sweep() can be driven
# directly, once per simulated sweep, in-process.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$SELF_DIR/order-exec-failure-watchdog.sh"
PLIST="$SELF_DIR/../packs/town-deltas/assets/order-exec-failure-watchdog.plist"
# The plist must reference where the script lives once deployed to the real
# HQ checkout — NOT wherever this selftest happens to be running from (a
# worktree path here would never match, before or after merge).
CANONICAL_SCRIPT="/Users/athos/gt/.gascity-gastown-hq/scripts/order-exec-failure-watchdog.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# vazio/falhou → sai: nunca segue com TMP vazio (os "$TMP/..." cairiam na raiz)
TMP="$(mktemp -d)" || { echo "FATAL: mktemp falhou"; exit 1; }
[ -d "$TMP" ] || { echo "FATAL: mktemp nao criou $TMP"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── hermetic stubs ─────────────────────────────────────────────────────────
export GC_CALLS_LOG="$TMP/gc-calls.log"
export NOTIFY_CALLS_LOG="$TMP/notify-calls.log"
: > "$GC_CALLS_LOG"; : > "$NOTIFY_CALLS_LOG"

cat > "$TMP/gc" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$GC_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/gc"

cat > "$TMP/notify" <<'STUB'
#!/usr/bin/env bash
{ printf 'CALL:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "$NOTIFY_CALLS_LOG"
exit 0
STUB
chmod +x "$TMP/notify"
export PATH="$TMP:$PATH"

# Each stub invocation writes one "CALL:" header line, but the alert body
# passed via -m has EMBEDDED newlines of its own (it's a multi-line message) —
# so `wc -l` on the raw file counts those too. Count "CALL:" headers, not raw
# lines, to get the actual number of gc/notify invocations.
gc_call_count()     { grep -c '^CALL:' "$GC_CALLS_LOG" 2>/dev/null; }
notify_call_count() { grep -c '^CALL:' "$NOTIFY_CALLS_LOG" 2>/dev/null; }
# Isolates the single most recent invocation's full multi-line content (from
# its "CALL:" header to just before the next one, or EOF) — plain `tail -1`
# would only catch the last physical line of that entry, not its content.
last_call() { awk '/^CALL:/{buf=$0"\n"; next} {buf = buf $0 "\n"} END{printf "%s", buf}' "$1"; }

# ── fixture supervisor.log + isolated state dir ────────────────────────────
FIXTURE="$TMP/supervisor.log"
: > "$FIXTURE"

export OEFW_STATE="$TMP/state"
export GC_SUPERVISOR_LOG="$FIXTURE"
export OEFW_FAIL_THRESHOLD=2
export OEFW_COOLDOWN_SEC=3600
export OEFW_LOG="$TMP/watchdog.log"
export ORDER_EXEC_FAILURE_WATCHDOG_LIB=1
# shellcheck disable=SC1090
source "$WATCHDOG" || { echo "FATAL: could not source watchdog in lib mode"; exit 1; }
type run_sweep >/dev/null 2>&1 || { echo "FATAL: run_sweep not defined by watchdog"; exit 1; }

append() { printf '%s\n' "$1" >> "$FIXTURE"; }

# ── 1. bootstrap: pre-existing backlog must NOT alert on first-ever run ─────
echo "── 1. bootstrap skips historical backlog ──"
append "2026/07/31 07:45:48 gc: order exec mol-dog-backup failed: exit status 1"
append "2026/07/31 07:45:48 gc: order exec mol-dog-backup output: /path/port_resolve.sh: No such file or directory"
append "2026/07/31 07:50:52 gc: order exec mol-dog-backup failed: exit status 1"
run_sweep
eq "bootstrap: zero gc mail calls" "$(gc_call_count)" "0"
eq "bootstrap: zero notify calls"  "$(notify_call_count)" "0"
eq "bootstrap: cursor seeded at current EOF" "$(cat "$OEFW_STATE")" "$(wc -c < "$FIXTURE" | tr -d ' ')"

# ── 2. context-canceled is benign: never counted, never alerts ──────────────
echo "── 2. context-canceled is ignored, even repeatedly ──"
for i in 1 2 3 4 5; do
  append "2026/07/28 12:0$i:00 gc: order exec orphan-sweep failed: context canceled"
  run_sweep
done
eq "context-canceled ×5 sweeps: still zero gc calls" "$(gc_call_count)" "0"
[ ! -f "${OEFW_STATE}.fail-counts/orphan-sweep" ] \
  && ok "context-canceled never created a fail-count file" \
  || bad "context-canceled incorrectly created a fail-count file"

# ── 3. one real failure is below threshold — no alert yet ───────────────────
echo "── 3. single real failure stays below threshold ──"
append "2026/08/01 06:12:05 gc: order exec mol-dog-doctor failed: exit status 1"
append "2026/08/01 06:12:05 gc: order exec mol-dog-doctor output: /path/port_resolve.sh: No such file or directory"
run_sweep
eq "sweep-count after 1st failure" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "1"
eq "still zero gc calls (below threshold=2)" "$(gc_call_count)" "0"

# ── 4. second CONSECUTIVE sweep crosses threshold — alert fires with output: line ──
echo "── 4. second consecutive sweep alerts, with diagnostic attached ──"
append "2026/08/01 06:17:09 gc: order exec mol-dog-doctor failed: exit status 1"
append "2026/08/01 06:17:09 gc: order exec mol-dog-doctor output: /path/port_resolve.sh: No such file or directory"
run_sweep
eq "sweep-count after 2nd failure" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "2"
eq "exactly one gc mail call fired" "$(gc_call_count)" "1"
eq "exactly one notify call fired"  "$(notify_call_count)" "1"
grep -q 'mol-dog-doctor' "$GC_CALLS_LOG"          && ok "alert mail names the order" || bad "alert mail missing order name"
grep -q 'port_resolve.sh' "$GC_CALLS_LOG"         && ok "alert mail includes the engine's output: diagnostic" || bad "alert mail missing output: diagnostic"
grep -q 'consecutive sweeps' "$GC_CALLS_LOG"      && ok "alert mail states the consecutive-sweep count" || bad "alert mail missing sweep-count context"
grep -q 'mayor' "$GC_CALLS_LOG"                   && ok "mail addressed to mayor" || bad "mail not addressed to mayor"

# ── 5. still failing, but WITHIN cooldown — must NOT re-mail (this is the 78-mails bug) ──
echo "── 5. within cooldown: repeated failures do not flood ──"
for i in 1 2 3; do
  append "2026/08/01 06:2$i:00 gc: order exec mol-dog-doctor failed: exit status 1"
  run_sweep
done
eq "gc call count unchanged during cooldown (dedup holds)" "$(gc_call_count)" "1"

# ── 6. cooldown expires — a still-failing order alerts again (not silenced forever) ──
echo "── 6. after cooldown expires, a persisting failure re-alerts ──"
echo $(( $(date +%s) - OEFW_COOLDOWN_SEC - 10 )) > "${OEFW_STATE}.cooldown/mol-dog-doctor"
append "2026/08/01 07:30:00 gc: order exec mol-dog-doctor failed: exit status 1"
run_sweep
eq "gc call count incremented after cooldown expiry" "$(gc_call_count)" "2"

# ── 7. recovery: silence resets the counter, not just the cooldown ──────────
echo "── 7. a quiet sweep resets a recovered order's counter ──"
run_sweep    # no new lines appended — order went silent (=recovered)
[ ! -f "${OEFW_STATE}.fail-counts/mol-dog-doctor" ] \
  && ok "fail-count cleared after a quiet sweep" \
  || bad "fail-count NOT cleared after recovery — $(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor" 2>/dev/null)"
[ ! -f "${OEFW_STATE}.cooldown/mol-dog-doctor" ] \
  && ok "cooldown cleared after recovery (fresh alert next time, not stale window)" \
  || bad "cooldown NOT cleared after recovery"
append "2026/08/01 09:00:00 gc: order exec mol-dog-doctor failed: exit status 1"
run_sweep
eq "recovered order restarts its own count at 1, not resuming at 2+" "$(cat "${OEFW_STATE}.fail-counts/mol-dog-doctor")" "1"

# ── 8. two orders failing at once get one batched alert, independent counters ──
# Two names UNTOUCHED by any earlier scenario — mol-dog-doctor carries a
# leftover fc=1 from test 7's setup, which would cross threshold a sweep
# ahead of a fresh order and fire two separate alerts instead of one batch
# (a real bug this exact mismatch caught once already: the recovery pass's
# containment check silently dropped a concurrently-failing order — see the
# `tr '\n' ' '` fix in the watchdog script). Fresh names isolate the
# batching assertion from that other scenario's accumulated state.
echo "── 8. concurrent failures: independent per-order state, batched mail ──"
GC_BEFORE=$(gc_call_count)
append "2026/08/01 09:05:00 gc: order exec mol-dog-compactor failed: exit status 1"
append "2026/08/01 09:05:00 gc: order exec dolt-health failed: exit status 1"
run_sweep
append "2026/08/01 09:10:00 gc: order exec mol-dog-compactor failed: exit status 1"
append "2026/08/01 09:10:00 gc: order exec dolt-health failed: exit status 1"
run_sweep
GC_AFTER=$(gc_call_count)
eq "one new batched alert covering both orders" "$((GC_AFTER - GC_BEFORE))" "1"
last_call "$GC_CALLS_LOG" | grep 'mol-dog-compactor' >/dev/null && ok "batched alert names mol-dog-compactor" || bad "batched alert missing mol-dog-compactor"
last_call "$GC_CALLS_LOG" | grep 'dolt-health' >/dev/null        && ok "batched alert names dolt-health"        || bad "batched alert missing dolt-health"

# ── 9. log rotation/truncation: cursor resets to 0, no crash ────────────────
echo "── 9. a shrunk log file (rotation) is handled without crashing ──"
: > "$FIXTURE"
append "2026/08/01 10:00:00 gc: order exec beads-health failed: exit status 1"
if run_sweep; then rc=0; else rc=1; fi
[ "$rc" = "0" ] || [ "$rc" = "1" ] && ok "sweep completes (rc=$rc) after truncation, does not crash the shell"
grep -q 'shrank' "$OEFW_LOG" && ok "rotation/truncation logged explicitly" || bad "rotation/truncation not logged"

# ── 10. real-shape duplicate lines: untimestamped echo must not corrupt state ──
# Live supervisor.log writes every event as TWO consecutive lines: one
# timestamped, one a bare untimestamped duplicate (confirmed against the real
# file, 2026-08-01 — e.g. line 447830 timestamped, 447831 an identical
# untimestamped echo). An earlier version of the parser matched both, and
# `$1 " " $2` grabbed "gc: order" as the "timestamp" from the untimestamped
# copy whenever it landed last — this proves that regression stays fixed:
# one sweep-count increment per sweep (not two, from the duplicate), and a
# real date in the alert body (not "gc: order").
echo "── 10. real-shape duplicate lines (timestamped + bare echo) ──"
append "2026/08/01 14:16:50 gc: order exec spawn-storm-detect failed: exit status 1"
append "gc: order exec spawn-storm-detect failed: exit status 1"
append "2026/08/01 14:16:50 gc: order exec spawn-storm-detect output: /path/to/missing-file"
append "gc: order exec spawn-storm-detect output: /path/to/missing-file"
run_sweep >/dev/null
eq "duplicate untimestamped echo does not double-count" "$(cat "${OEFW_STATE}.fail-counts/spawn-storm-detect")" "1"
append "2026/08/01 14:21:50 gc: order exec spawn-storm-detect failed: exit status 1"
append "gc: order exec spawn-storm-detect failed: exit status 1"
GC_BEFORE10=$(gc_call_count)
run_sweep
GC_AFTER10=$(gc_call_count)
eq "second sweep crosses threshold, one alert (not two from the duplicate)" "$((GC_AFTER10 - GC_BEFORE10))" "1"
last_call "$GC_CALLS_LOG" | grep '2026/08/01 14:21:50' >/dev/null \
  && ok "alert shows the REAL last-seen timestamp" \
  || bad "alert timestamp corrupted — likely picked up the untimestamped duplicate's bogus 'gc: order' field"
last_call "$GC_CALLS_LOG" | grep -F 'gc: order' >/dev/null \
  && bad "alert leaked the untimestamped duplicate's garbage timestamp ('gc: order')" \
  || ok "no 'gc: order' garbage leaked into the alert"

# ── 11. drift-guard: the plist actually points at THIS script, on disk ──────
echo "── 11. drift-guard: plist wiring matches the shipped script ──"
[ -f "$PLIST" ] && ok "plist exists at packs/town-deltas/assets/order-exec-failure-watchdog.plist" \
                 || bad "plist NOT found — watchdog would never be deployed (ga-nehkr precedent)"
grep -qF "$CANONICAL_SCRIPT" "$PLIST" \
  && ok "plist ProgramArguments references the canonical deploy path" \
  || bad "plist ProgramArguments does NOT match $CANONICAL_SCRIPT — would fail to launch once deployed"
grep -q '<string>com.gascity.order-exec-failure-watchdog</string>' "$PLIST" \
  && ok "plist Label follows the com.gascity.<script-name> convention" \
  || bad "plist Label missing or does not match convention"
grep -q '<key>ProcessType</key><string>Interactive</string>' "$PLIST" \
  && ok "ProcessType=Interactive set (DAS-deferral guard, ga-u04vp lesson)" \
  || bad "ProcessType=Interactive missing — watchdog could itself go silently deferred"

# ── Lastro hq-mutants (ga-qec2rdl) ──────────────────────────────────────────
# Ate aqui nenhum caso lia o STATUS de run_sweep, o limite exato do cooldown e do clamp, o ramo "so linhas
# benignas" nem o script EXECUTADO (o guard do modo lib). date, wc e tail de mentira (funcoes deste shell;
# gc e notify seguem sendo os stubs do PATH) fazem falhar o que de graca nao falha.
# EQUIVALENTES (lastro): 829c43a963 bc42a497e0 237afdb31f 8dc1c151f3 5f72a8c256 0720001ec3 5a0417f77d 4cfff30377
# 2752235dc1 0f4a812dbe c2c2b2831a (`cmd || true` -> `cmd && true` em escrita de log/estado: ninguem le o status
# e nao ha set -e) e aaa8b8590e 6082e67a18 (`command -v X && X ... || true` -> `&& true`: so muda o status de
# _alert, que o run_sweep descarta).
date() { if [ "${1-}" = "+%s" ] && [ -n "${FAKE_NOW:-}" ]; then echo "$FAKE_NOW"; else command date "$@"; fi; }

# ── 12. status de run_sweep e o cooldown no limite exato ────────────────────
echo "── 12. run_sweep devolve 1 so quando alerta; o cooldown acaba exatamente em OEFW_COOLDOWN_SEC ──"
FAKE_NOW=2000000000
mkdir -p "${OEFW_STATE}.fail-counts" "${OEFW_STATE}.cooldown"
echo 1 > "${OEFW_STATE}.fail-counts/cd-edge"; echo $((FAKE_NOW - OEFW_COOLDOWN_SEC + 1)) > "${OEFW_STATE}.cooldown/cd-edge"
append "2026/08/02 10:00:00 gc: order exec cd-edge failed: exit status 1"
GC_BEFORE12=$(gc_call_count)
run_sweep; rc=$?
eq "1 s antes do fim do cooldown: suprime o alerta e sai 0 (rc/novos mails)" "$rc/$(( $(gc_call_count) - GC_BEFORE12 ))" "0/0"
echo 1 > "${OEFW_STATE}.fail-counts/cd-edge"; echo $((FAKE_NOW - OEFW_COOLDOWN_SEC)) > "${OEFW_STATE}.cooldown/cd-edge"
append "2026/08/02 10:05:00 gc: order exec cd-edge failed: exit status 1"
run_sweep; rc=$?
eq "exatamente no fim do cooldown: alerta e sai 1 (rc/novos mails)" "$rc/$(( $(gc_call_count) - GC_BEFORE12 ))" "1/1"
FAKE_NOW=""

# ── 13. so linhas benignas ──────────────────────────────────────────────────
echo "── 13. varredura so com linhas output: (sem failed:) registra 'only benign'; falha real nao ──"
: > "$OEFW_LOG"
append "2026/08/02 11:00:00 gc: order exec only-out output: algo aconteceu"
run_sweep; rc=$?
[ "$rc" = "0" ] && grep -F "only benign(context-canceled)/output lines" "$OEFW_LOG" >/dev/null \
  && ok "so output: registra 'only benign' e sai 0" || bad "so output: rc=$rc log=$(cat "$OEFW_LOG")"
: > "$OEFW_LOG"
append "2026/08/02 11:05:00 gc: order exec real-fail failed: exit status 1"
run_sweep
grep -F "only benign" "$OEFW_LOG" >/dev/null \
  && bad "falha real foi registrada como 'only benign'" || ok "falha real nao e registrada como 'only benign'"

# ── 14. entradas ruins do supervisor.log ────────────────────────────────────
echo "── 14. supervisor.log ausente, wc que falha, tail que falha, bootstrap e clamp no limite ──"
SAVED_SUPERVISOR_LOG="$SUPERVISOR_LOG"
SUPERVISOR_LOG="$TMP/nao-existe.log"; : > "$OEFW_LOG"; run_sweep; rc=$?; SUPERVISOR_LOG="$SAVED_SUPERVISOR_LOG"
[ "$rc" = "0" ] && grep -F "WARN supervisor.log not found" "$OEFW_LOG" >/dev/null \
  && ok "supervisor.log ausente: avisa e sai 0" || bad "supervisor.log ausente: rc=$rc"
CUR14="$(cat "$OEFW_STATE")"
wc() { return 1; }; : > "$OEFW_LOG"; run_sweep; rc=$?; unset -f wc
[ "$rc" = "0" ] && grep -F "could not stat" "$OEFW_LOG" >/dev/null && [ "$(cat "$OEFW_STATE")" = "$CUR14" ] \
  && ok "tamanho ilegivel: 'could not stat', sai 0 e o cursor nao anda" || bad "tamanho ilegivel: rc=$rc"
append "2026/08/02 12:00:00 gc: order exec tail-edge failed: exit status 1"
tail() { return 1; }; : > "$OEFW_LOG"; run_sweep; rc=$?; unset -f tail
[ "$rc" = "0" ] && grep -F "tail read of" "$OEFW_LOG" >/dev/null && [ "$(cat "$OEFW_STATE")" = "$CUR14" ] \
  && [ ! -f "${OEFW_STATE}.fail-counts/tail-edge" ] \
  && ok "leitura que falha: avisa, sai 0, nao avanca o cursor e nao conta a falha" || bad "tail falha: rc=$rc"
rm -f "$OEFW_STATE"; : > "$OEFW_LOG"; run_sweep; rc=$?
[ "$rc" = "0" ] && grep -F "BOOTSTRAP: first run" "$OEFW_LOG" >/dev/null \
  && [ "$(cat "$OEFW_STATE")" = "$(wc -c < "$SUPERVISOR_LOG" | tr -d ' ')" ] \
  && ok "primeira varredura: planta o cursor no fim e sai 0" || bad "bootstrap: rc=$rc"
SZ14="$(wc -c < "$SUPERVISOR_LOG" | tr -d ' ')"
echo $((SZ14 - 20)) > "$OEFW_STATE"; OEFW_MAX_READ_BYTES=20; : > "$OEFW_LOG"; run_sweep; OEFW_MAX_READ_BYTES=5000000
grep -F "exceeds clamp" "$OEFW_LOG" >/dev/null \
  && bad "exatamente OEFW_MAX_READ_BYTES novos bytes foram tratados como excesso" || ok "novos bytes == teto: le tudo, sem aviso de clamp"
echo $((SZ14 - 21)) > "$OEFW_STATE"; OEFW_MAX_READ_BYTES=20; : > "$OEFW_LOG"; run_sweep; OEFW_MAX_READ_BYTES=5000000
grep -F "exceeds clamp" "$OEFW_LOG" >/dev/null \
  && ok "um byte acima do teto: clamp avisado" || bad "um byte acima do teto nao foi tratado como excesso"

# ── 15. o script executado ──────────────────────────────────────────────────
echo "── 15. executado: ORDER_EXEC_FAILURE_WATCHDOG_LIB=1 so define; sem ela roda uma varredura ──"
: > "$TMP/exec.log"
ORDER_EXEC_FAILURE_WATCHDOG_LIB=1 OEFW_LOG="$TMP/exec.log" GC_SUPERVISOR_LOG="$TMP/nao-existe.log" bash "$WATCHDOG" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && [ ! -s "$TMP/exec.log" ] && ok "LIB=1: executar nao varre nada" || bad "LIB=1 executado: rc=$rc log=$(cat "$TMP/exec.log")"
ORDER_EXEC_FAILURE_WATCHDOG_LIB=0 OEFW_LOG="$TMP/exec.log" GC_SUPERVISOR_LOG="$TMP/nao-existe.log" bash "$WATCHDOG" >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && grep -F "WARN supervisor.log not found" "$TMP/exec.log" >/dev/null \
  && ok "sem LIB: executar roda uma varredura" || bad "sem LIB executado: rc=$rc"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
