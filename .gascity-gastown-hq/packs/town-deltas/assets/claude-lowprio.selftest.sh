#!/usr/bin/env bash
# claude-lowprio.selftest.sh — ga-rj7b1a: prove every pool claude session is born LOW-priority, so the
# heavy suites it runs never compete with Dolt / the supervisor on equal terms.
#
# Two halves, because the fix has two halves and either one alone is worth nothing:
#   A. BEHAVIOUR of assets/scripts/claude-lowprio.sh (run against a fake `claude` that reports its own and a
#      child's niceness): it raises niceness to an ABSOLUTE target, inherits into children, never lowers,
#      never stacks, keeps the pid (exec), keeps argv byte-for-byte, honours both kill switches, and is
#      FAIL-OPEN — a broken renice/ps must still launch claude, and say so in the log.
#   B. WIRING in city.toml: [providers.claude-headless] actually launches through the wrapper (with
#      path_check so the engine still verifies the real `claude`), while the Mayor's and the crews'
#      providers are untouched and no agent escapes through start_command.
#
# HERMETIC w.r.t. ambient niceness: the reader may be running this inside a session that is ALREADY
# reniced (the Mayor's 2026-09-19 stopgap loop, or this very wrapper), so no case assumes ambient == 0;
# every target is chosen relative to the niceness this process actually has, and a case that has no
# headroom left says so (SKIP) instead of passing vacuously.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${CLAUDE_LOWPRIO_WRAPPER:-$SELF_DIR/scripts/claude-lowprio.sh}"
CITY_TOML="${CLAUDE_LOWPRIO_CITY_TOML:-$SELF_DIR/../../../city.toml}"
AGENTS_DIR="${CLAUDE_LOWPRIO_AGENTS_DIR:-$SELF_DIR/../../../agents}"

PASS=0
FAIL=0
SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }

[ -f "$WRAPPER" ]   || { echo "FATAL: wrapper not found at $WRAPPER"; exit 1; }
[ -f "$CITY_TOML" ] || { echo "FATAL: city.toml not found at $CITY_TOML"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-lowprio-selftest.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

ni_now() { ps -o ni= -p "$$" 2>/dev/null | tr -d '[:space:]'; }
AMB="$(ni_now)"
case "$AMB" in ''|*[!0-9-]*) echo "FATAL: cannot read this process's niceness (got '$AMB')"; exit 1 ;; esac
# One notch above ambient is enough to tell "raised" from "left alone"; +3 keeps a doubled increment
# distinguishable from an absolute set. Capped at the macOS maximum of 20.
T=$((AMB + 3)); [ "$T" -gt 20 ] && T=20
HEADROOM=1; [ "$T" -le "$AMB" ] && HEADROOM=0

# ── fake claude: reports what a real one would inherit, one fact per line ─────────────────────────
FAKE="$W/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
echo "pid=$$"
echo "ni=$(ps -o ni= -p $$ | tr -d '[:space:]')"
echo "child_ni=$(sh -c 'ps -o ni= -p $$' | tr -d '[:space:]')"
echo "argc=$#"
i=0
for a in "$@"; do i=$((i+1)); printf 'arg%d=[%s]\n' "$i" "$a"; done
EOF
chmod +x "$FAKE"

field() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

# Runs the wrapper as a BACKGROUND job so $! is its pid (exec must keep it), with a scrubbed environment
# so a stray GC_* in the caller can never leak into a case. Extra env assignments are passed as args
# BEFORE the literal `--`; everything after it is claude's argv.
LAST_PID=""
run_wrapper() {
  local envs=() a
  while [ "$#" -gt 0 ]; do a="$1"; shift; [ "$a" = "--" ] && break; envs+=("$a"); done
  local out="$W/out.$$.$RANDOM"
  env -i PATH="${SHIM_PATH:-$PATH}" HOME="$W" TMPDIR="$W" GC_LOWPRIO_CLAUDE_BIN="$FAKE" ${envs[@]+"${envs[@]}"} \
    ${NICE_PREFIX:-} "$WRAPPER" "$@" > "$out" 2>"$out.err" &
  LAST_PID=$!
  wait "$LAST_PID"; LAST_RC=$?
  OUT="$(cat "$out")"; ERR="$(cat "$out.err")"
}

echo "ambient ni=$AMB  target for raise cases T=$T"

echo "── A1. raises niceness to the ABSOLUTE target; children inherit; exec keeps the pid ──"
if [ "$HEADROOM" -eq 1 ]; then
  run_wrapper GC_LOWPRIO_NICE="$T" -- --settings '{"remoteControlAtStartup":false}' --model sonnet --strict-mcp-config
  [ "$(field ni "$OUT")" = "$T" ] && ok "claude runs at ni=$T (absolute, not ambient+$T)" || bad "claude ni='$(field ni "$OUT")', wanted $T (rc=$LAST_RC err=$ERR)"
  [ "$(field child_ni "$OUT")" = "$T" ] && ok "a child of claude inherits ni=$T — tests it spawns are low-priority by construction" || bad "child ni='$(field child_ni "$OUT")', wanted $T"
  [ "$(field pid "$OUT")" = "$LAST_PID" ] && ok "exec kept the pid ($LAST_PID): the tmux pane still runs claude itself" || bad "pid changed: wrapper $LAST_PID, claude '$(field pid "$OUT")' (a child, not exec?)"
else
  skip "ambient ni=$AMB leaves no headroom to raise"
fi

echo "── A2. argv reaches claude byte-for-byte ──"
run_wrapper GC_LOWPRIO_NICE="$T" -- --settings '{"remoteControlAtStartup":false}' 'a  b' '' '*' --model sonnet
got="$(printf '%s\n' "$OUT" | grep -E '^(argc|arg[0-9]+)=')"
# Seven args go in; assert on the exact list, not on a hand-counted number.
exp='argc=7
arg1=[--settings]
arg2=[{"remoteControlAtStartup":false}]
arg3=[a  b]
arg4=[]
arg5=[*]
arg6=[--model]
arg7=[sonnet]'
[ "$got" = "$exp" ] && ok "quotes, JSON, spaces, empty string and glob char survive untouched" || bad "argv mangled: got [$got]"

echo "── A3. never stacks: a wrapped session launching a wrapped session stays at T ──"
if [ "$HEADROOM" -eq 1 ]; then
  # The outer wrapper's "claude" is a shim that execs the wrapper again, whose claude is the fake.
  # `renice -n` (an increment) would climb to ~2T here; the absolute form stays at exactly T.
  cat > "$W/chain.sh" <<EOF
#!/bin/bash
GC_LOWPRIO_CLAUDE_BIN="$FAKE" exec "$WRAPPER" "\$@"
EOF
  chmod +x "$W/chain.sh"
  run_wrapper GC_LOWPRIO_NICE="$T" GC_LOWPRIO_CLAUDE_BIN="$W/chain.sh" -- x
  [ "$(field ni "$OUT")" = "$T" ] && ok "two wrappers in a row leave ni=$T (no compounding)" || bad "chained wrappers: ni='$(field ni "$OUT")', wanted $T"
else
  skip "no headroom"
fi

echo "── A4. never LOWERS an already lower priority ──"
if [ "$AMB" -le 18 ]; then
  hi=$((AMB + 2)); tgt=$((AMB + 1))
  NICE_PREFIX="nice -n 2" run_wrapper GC_LOWPRIO_NICE="$tgt" -- x
  [ "$(field ni "$OUT")" = "$hi" ] && ok "started at ni=$hi with target $tgt: stays $hi (KEEP, not lowered to $tgt)" || bad "ni='$(field ni "$OUT")', wanted $hi to be kept (target $tgt)"
else
  skip "ambient ni=$AMB too high to start a wrapper above it"
fi

echo "── A5. kill switches ──"
run_wrapper GC_LOWPRIO=0 GC_LOWPRIO_NICE="$T" -- x
[ "$(field ni "$OUT")" = "$AMB" ] && ok "GC_LOWPRIO=0 leaves ni=$AMB" || bad "GC_LOWPRIO=0 still changed ni to '$(field ni "$OUT")'"
mkdir -p "$W/city/.gc/logs"
touch "$W/city/.gc/no-lowprio"
run_wrapper GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE="$T" -- x
[ "$(field ni "$OUT")" = "$AMB" ] && ok "\$GC_CITY_PATH/.gc/no-lowprio leaves ni=$AMB (no config reload needed)" || bad "kill file ignored: ni='$(field ni "$OUT")'"
rm -f "$W/city/.gc/no-lowprio"
if [ "$HEADROOM" -eq 1 ]; then
  run_wrapper GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE="$T" -- x
  [ "$(field ni "$OUT")" = "$T" ] && ok "removing the kill file re-arms it at once (stateless)" || bad "not re-armed: ni='$(field ni "$OUT")'"
fi

echo "── A6. FAIL-OPEN: a broken renice still launches claude — and says so ──"
mkdir -p "$W/shim-renice"
cat > "$W/shim-renice/renice" <<EOF
#!/bin/bash
echo "\$*" >> "$W/renice.calls"
exit 1
EOF
chmod +x "$W/shim-renice/renice"
: > "$W/city/.gc/logs/claude-lowprio.log"
SHIM_PATH="$W/shim-renice:$PATH" run_wrapper GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE="$T" -- --model sonnet
if [ "$HEADROOM" -eq 1 ]; then
  [ "$(field arg1 "$OUT")" = "[--model]" ] && [ "$LAST_RC" -eq 0 ] && ok "claude was launched anyway (rc=0, argv intact)" || bad "renice failure blocked/damaged the launch: rc=$LAST_RC out=$OUT"
  [ "$(field ni "$OUT")" = "$AMB" ] && ok "it runs at its inherited ni=$AMB" || bad "ni changed to '$(field ni "$OUT")' despite the failing renice"
  grep -q ' WARN renice rc=1 ' "$W/city/.gc/logs/claude-lowprio.log" && ok "the failure is a visible WARN line in the log, not an absence" || bad "no WARN in the log: $(cat "$W/city/.gc/logs/claude-lowprio.log")"
  grep -qx "$T -p $LAST_PID" "$W/renice.calls" && ok "renice was called in the ABSOLUTE form: 'renice $T -p $LAST_PID'" || bad "renice call was not the absolute form: $(cat "$W/renice.calls" 2>/dev/null)"
else
  skip "no headroom: the wrapper correctly does not try (see KEEP in A4)"
fi

echo "── A7. FAIL-OPEN: unreadable niceness is not 'already low' — it still tries, and still launches ──"
mkdir -p "$W/shim-ps"
cat > "$W/shim-ps/ps" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$W/shim-ps/ps"
: > "$W/renice.calls"; : > "$W/city/.gc/logs/claude-lowprio.log"
SHIM_PATH="$W/shim-ps:$W/shim-renice:/bin:/usr/bin" run_wrapper GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE="$T" -- --model sonnet
[ "$LAST_RC" -eq 0 ] && [ "$(field arg1 "$OUT")" = "[--model]" ] && ok "claude launched with ps broken (the fake's own ps is the shim too, so only launch + argv are asserted)" || bad "broken ps blocked the launch: rc=$LAST_RC err=$ERR"
[ -s "$W/renice.calls" ] && ok "with an unreadable niceness it still attempted the renice (unknown != already-low)" || bad "renice was not attempted when niceness was unreadable"
grep -q ' WARN ' "$W/city/.gc/logs/claude-lowprio.log" && ok "and logged a WARN, because it could not confirm the result" || bad "no WARN when the result could not be confirmed: $(cat "$W/city/.gc/logs/claude-lowprio.log")"

echo "── A8. knob validation ──"
run_wrapper GC_CITY_PATH="$W/city" GC_LOWPRIO_NICE=abc -- x
want=15; [ "$AMB" -gt 15 ] && want="$AMB"
[ "$(field ni "$OUT")" = "$want" ] && ok "GC_LOWPRIO_NICE=abc falls back to 15 (ni=$want)" || bad "GC_LOWPRIO_NICE=abc: ni='$(field ni "$OUT")', wanted $want"
grep -q "is not a number" "$W/city/.gc/logs/claude-lowprio.log" && ok "the bad knob is reported in the log" || bad "bad knob not reported"
if [ "$AMB" -lt 20 ]; then
  run_wrapper GC_LOWPRIO_NICE=99 -- x
  [ "$(field ni "$OUT")" = "20" ] && ok "GC_LOWPRIO_NICE=99 is clamped to the macOS maximum, 20" || bad "GC_LOWPRIO_NICE=99: ni='$(field ni "$OUT")', wanted 20"
fi

echo "── A9. one log line per launch; no city → no log and no error ──"
: > "$W/city/.gc/logs/claude-lowprio.log"
run_wrapper GC_CITY_PATH="$W/city" GC_AGENT=gastown.dog GC_LOWPRIO_NICE="$T" -- x
n="$(grep -c "pid=$LAST_PID " "$W/city/.gc/logs/claude-lowprio.log" || true)"
[ "$n" = "1" ] && ok "exactly one line for pid $LAST_PID: $(head -1 "$W/city/.gc/logs/claude-lowprio.log" | cut -d' ' -f2-)" || bad "expected 1 log line for pid $LAST_PID, got $n"
grep -q 'agent=gastown.dog ' "$W/city/.gc/logs/claude-lowprio.log" && ok "the line names the agent (GC_AGENT)" || bad "agent missing from the log line"
run_wrapper GC_LOWPRIO_NICE="$T" -- x
[ "$LAST_RC" -eq 0 ] && [ -z "$ERR" ] && ok "with no GC_CITY_PATH: launches cleanly, no stderr noise" || bad "no-city launch: rc=$LAST_RC err=$ERR"

echo "── A10. a missing claude fails like the unwrapped provider would ──"
run_wrapper GC_LOWPRIO_CLAUDE_BIN="$W/does-not-exist" -- x
[ "$LAST_RC" -ne 0 ] && ok "non-zero exit (rc=$LAST_RC) instead of a hang or a silent 0" || bad "missing claude exited 0"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "── B. wiring in city.toml ──"
block() { awk -v h="[providers.$1]" '$0==h{f=1; print; next} /^\[/{f=0} f' "$CITY_TOML"; }
key_of() { block "$1" | grep -E "^$2[[:space:]]*=" | head -1 || true; }
CITY_DIR="$(cd "$(dirname "$CITY_TOML")" && pwd)"

cmd_line="$(key_of claude-headless command)"
cmd_val="$(printf '%s' "$cmd_line" | sed -n 's/^command[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')"
if [ -z "$cmd_val" ]; then
  bad "[providers.claude-headless] has no command = \"…/claude-lowprio.sh\" — pool sessions are NOT launched low-priority"
else
  case "$cmd_val" in
    */scripts/claude-lowprio.sh) ok "claude-headless.command launches the wrapper ($cmd_val)" ;;
    *) bad "claude-headless.command is '$cmd_val', not …/scripts/claude-lowprio.sh" ;;
  esac
  case "$cmd_val" in /*) ok "the command is an absolute path (the engine execs it as-is; same convention as the pre_start scripts)" ;; *) bad "command '$cmd_val' is not absolute" ;; esac
  # The command is an absolute path into the LIVE city; the same file must exist, executable, at the same
  # city-relative place in THIS tree (a gate worktree included) — that is what ships with the config.
  rel="${cmd_val#*/.gascity-gastown-hq/}"
  if [ "$rel" = "$cmd_val" ]; then
    bad "command '$cmd_val' is not under .gascity-gastown-hq/ — cannot map it into this tree"
  elif [ -x "$CITY_DIR/$rel" ]; then
    ok "$rel exists in this tree and is executable (ships in the same commit as the config that points at it)"
  else
    bad "$rel is missing or not executable under $CITY_DIR — city.toml would point at a launcher that does not exist"
  fi
  [ "$CITY_DIR/$rel" -ef "$WRAPPER" ] && ok "…and it is the very file this selftest exercises" || bad "the configured launcher ($CITY_DIR/$rel) is not the wrapper under test ($WRAPPER)"
fi
[ "$(key_of claude-headless path_check)" = 'path_check = "claude"' ] \
  && ok "path_check = \"claude\": the engine still verifies the REAL binary, not the wrapper" \
  || bad "claude-headless lacks path_check = \"claude\" (got: '$(key_of claude-headless path_check)')"
block claude-headless | grep -q '^base = "builtin:claude"$' \
  && ok "claude-headless is still built on builtin:claude (process names, resume, hooks inherited)" || bad "claude-headless lost base = builtin:claude"

for p in claude claude-rc; do
  if [ -n "$(key_of $p command)" ] || [ -n "$(key_of $p path_check)" ]; then
    bad "[providers.$p] sets command/path_check — the Mayor and named crews must stay at NORMAL priority (interactive)"
  else
    ok "[providers.$p] untouched: normal priority for the Mayor / attended crews"
  fi
done

sc="$(grep -rlE '^[[:space:]]*start_command[[:space:]]*=' "$CITY_TOML" "$AGENTS_DIR" 2>/dev/null | tr '\n' ' ' || true)"
[ -z "$(printf '%s' "$sc" | tr -d ' ')" ] \
  && ok "no agent sets start_command: none can bypass the provider (and so the wrapper)" \
  || bad "start_command in: $sc — that agent's session skips the low-priority wrapper; decide deliberately"

echo
echo "== $PASS passed, $FAIL failed, $SKIP skipped =="
[ "$FAIL" -eq 0 ]
