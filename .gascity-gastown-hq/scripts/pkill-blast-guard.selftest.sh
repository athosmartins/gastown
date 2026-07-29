#!/usr/bin/env bash
# pkill-blast-guard.selftest.sh (ga-jo3xl) — hermetic tests for
# pkill-blast-guard.py and pkill-blast-guard-activate.sh.
#
# Drives the guard as a real subprocess (feeding it the exact JSON a Claude
# Code PreToolUse:Bash hook receives on stdin) and asserts on its stdout
# JSON + exit code. No mocking of the guard's own logic — this is the real
# script, real shlex tokenizing, real pgrep. The only faked state is a
# handful of throwaway `sleep` decoy processes this file spawns itself (for
# the >N-matches and matches-a-claude-process cases), which it always kills
# in a trap before exiting. Never touches a real claude session or any
# production process.
#
# TEST: bash scripts/pkill-blast-guard.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/pkill-blast-guard.py"
ACTIVATE="$HERE/pkill-blast-guard-activate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# decoy PIDs spawned by the >N / matches-claude test cases, always reaped.
DECOY_PIDS=()
cleanup() {
  for pid in "${DECOY_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

# run_guard <command-string> [extra_env...] -> sets OUT (stdout) and RC (exit code)
run_guard() {
  local cmd="$1"; shift
  local payload
  payload="$(jq -n --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
  OUT="$(printf '%s' "$payload" | env "$@" python3 "$GUARD" 2>/tmp/pkill-guard-selftest-stderr.$$)"
  RC=$?
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow-implicit"' 2>/dev/null; }

echo "=== pkill-blast-guard.selftest.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# AC6(i): the EXACT incident line must be BLOCKED.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(i): exact incident line is blocked --"
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)'
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "incident line denied (pattern not last)"
else
  bad "incident line should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("PATTERN must be the LAST argument")' >/dev/null 2>&1 \
  && ok "deny reason teaches the correct form (AC5)" \
  || bad "deny reason should teach the correct form, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"

# ─────────────────────────────────────────────────────────────────────────────
# AC6(ii): the 3 AC3 safe forms must PASS (allow).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(ii): AC3 safe forms are allowed --"

run_guard "pkill -f 'ANUNCIOS_PORT=8214'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "pkill -f 'ANUNCIOS_PORT=8214' allowed" \
  || bad "pkill -f 'ANUNCIOS_PORT=8214' should be allowed, got rc=$RC out=$OUT"

run_guard 'kill $PID'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "kill \$PID allowed (not pkill/killall at all)" \
  || bad "kill \$PID should be allowed untouched, got rc=$RC out=$OUT"

run_guard "pkill -9 -f 'adb.*fork-server'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "pkill -9 -f 'adb.*fork-server' allowed" \
  || bad "pkill -9 -f 'adb.*fork-server' should be allowed, got rc=$RC out=$OUT"

# Non-Bash tool calls and non-pkill commands must be untouched too.
run_guard_raw_tool() {
  local payload="$1"
  OUT="$(printf '%s' "$payload" | python3 "$GUARD" 2>/dev/null)"; RC=$?
}
run_guard_raw_tool '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "non-Bash tool_name ignored" \
  || bad "non-Bash tool_name should be a no-op allow, got rc=$RC out=$OUT"

run_guard 'ls -la /tmp'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "ordinary command with no pkill/killall allowed" \
  || bad "ordinary command should be allowed, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# AC6(iii): broken hook (internal error / forced exception) fails OPEN.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC6(iii): internal error fails OPEN --"
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)' PKILL_GUARD_SELFTEST_FORCE_ERROR=1
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ]; then
  ok "forced internal error on an otherwise-dangerous command still ALLOWS (fail-open, AC4)"
else
  bad "forced internal error should fail OPEN (allow), got rc=$RC out=$OUT"
fi

# Malformed / unparseable JSON on stdin must also fail open, not crash.
OUT="$(printf 'not json at all' | python3 "$GUARD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "malformed stdin JSON fails OPEN (rc=0, no deny)" \
  || bad "malformed stdin should fail open, got rc=$RC out=$OUT"

# A command with NO pkill/killall mention at all must still fail open on a
# forced internal error -- distinct from the unbalanced-quote case below,
# which DOES mention pkill/killall and is a deliberate deny (fix-attempt 3).
run_guard 'echo hello world' PKILL_GUARD_SELFTEST_FORCE_ERROR=1
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "forced error on a command with no pkill/killall mention still fails OPEN" \
  || bad "forced error on unrelated command should fail open, got rc=$RC out=$OUT"

# A bad PKILL_GUARD_MAX_MATCHES env value is a guard MISCONFIGURATION, not a
# property of the command -- stays fail-open per AC4.
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)' PKILL_GUARD_MAX_MATCHES=not-a-number
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "malformed PKILL_GUARD_MAX_MATCHES env value fails OPEN" \
  || bad "bad env value should fail open, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# AC2(c): pattern matching more than N processes is blocked (using disposable
# decoy processes, never real ones). Spawn 7 to safely clear the default N=5.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2(c): pattern matching more than N processes is blocked --"
MARKER_MANY="pkill-guard-selftest-many-$$"
for _ in 1 2 3 4 5 6 7; do
  bash -c "exec -a $MARKER_MANY sleep 60" &
  DECOY_PIDS+=("$!")
  disown 2>/dev/null || true
done
sleep 0.3   # let the decoys register in the process table before pgrep runs
run_guard "pkill -f '$MARKER_MANY'"
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "pattern matching 7 decoy processes (> default N=5) denied"
else
  bad "pattern matching 7 processes should be denied, got rc=$RC out=$OUT"
fi
# same pattern, but with the threshold raised via env -> must now be allowed.
run_guard "pkill -f '$MARKER_MANY'" PKILL_GUARD_MAX_MATCHES=50
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "same pattern allowed once PKILL_GUARD_MAX_MATCHES raised above the match count" \
  || bad "raising PKILL_GUARD_MAX_MATCHES should allow it through, got rc=$RC out=$OUT"
for pid in "${DECOY_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
DECOY_PIDS=()

# ─────────────────────────────────────────────────────────────────────────────
# AC2(b): pattern matching a process whose command line contains "claude" is
# blocked, using a disposable decoy (never a real claude session).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2(b): pattern matching a 'claude'-containing process is blocked --"
MARKER_CLAUDE="pkill-guard-selftest-decoy-claude-proc-$$"
bash -c "exec -a $MARKER_CLAUDE sleep 60" &
DECOY_PIDS+=("$!")
disown 2>/dev/null || true
sleep 0.3
run_guard "pkill -f '$MARKER_CLAUDE'"
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "pattern matching a decoy process with 'claude' in its command line denied"
else
  bad "pattern matching a 'claude'-named decoy should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("claude")' >/dev/null 2>&1 \
  && ok "claude-match deny reason names the reason" \
  || bad "claude-match deny reason should mention claude, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"
for pid in "${DECOY_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
DECOY_PIDS=()

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 2): pkill/killall glued flush against a
# preceding shell separator with no whitespace must still be caught -- plain
# shlex.split only splits on whitespace, so e.g. "hi;pkill" was one token that
# never matched the "pkill" basename check, silently hiding the invocation
# from the guard entirely (confirmed allow-by-default before this fix).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression: separator-glued pkill/killall is still caught --"

run_guard 'echo hi;pkill -f "anuncios_dashboard.py" -U $(id -u)'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "';pkill' glued with no space still denied" \
  || bad "';pkill' glued with no space should be denied, got rc=$RC out=$OUT"

run_guard 'cd /tmp&&pkill -f "anuncios_dashboard.py" -U $(id -u)'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "'&&pkill' glued with no space still denied" \
  || bad "'&&pkill' glued with no space should be denied, got rc=$RC out=$OUT"

run_guard 'true||pkill -f "anuncios_dashboard.py" -U $(id -u)'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "'||pkill' glued with no space still denied" \
  || bad "'||pkill' glued with no space should be denied, got rc=$RC out=$OUT"

run_guard 'true|pkill -f "anuncios_dashboard.py" -U $(id -u)'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "'|pkill' (single pipe) glued with no space still denied" \
  || bad "'|pkill' glued with no space should be denied, got rc=$RC out=$OUT"

# Quoting must still protect a pattern that legitimately contains a separator
# character -- this must NOT be misread as a second glued invocation.
run_guard "pkill -f 'foo;bar;baz'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "semicolon INSIDE a quoted pattern is not mistaken for a separator" \
  || bad "quoted-semicolon pattern should be allowed, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 2): a pattern built from an unexpanded
# shell variable/substitution must never be silently confirmed "safe" just
# because pgrep finds zero matches for the LITERAL variable-reference text --
# that zero-matches read says nothing about what the pattern actually expands
# to once the shell resolves it at runtime (confirmed allow-by-default, on a
# machine with a real live claude session pgrep would have matched, before
# this fix).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression: unexpanded-variable pattern is refused, not silently allowed --"

run_guard 'TARGET=claude ; pkill -f "$TARGET"'
if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "pkill -f \"\$TARGET\" (unexpanded) denied instead of silently confirmed safe"
else
  bad "unexpanded-variable pattern should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("unexpanded")' >/dev/null 2>&1 \
  && ok "unexpanded-variable deny reason explains why" \
  || bad "deny reason should explain the unexpanded-variable refusal, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"

run_guard 'pkill -f "${TARGET}"'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "pkill -f \"\${TARGET}\" (braced variable) denied" \
  || bad "braced-variable pattern should be denied, got rc=$RC out=$OUT"

run_guard 'pkill -f "$(hostname)"'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "pkill -f \"\$(hostname)\" (command substitution) denied" \
  || bad "command-substitution pattern should be denied, got rc=$RC out=$OUT"

run_guard 'pkill -f `hostname`'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "pkill -f \`hostname\` (backtick substitution) denied" \
  || bad "backtick-substitution pattern should be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 3), structural: THREE rounds of gate
# review each found a DIFFERENT way for decide() to fall through to its old
# default "allow" instead of denying an unverified result. Mayor's directive
# after round 3: stop patching individual cases, invert the default -- once a
# command is confirmed to contain pkill/killall, every path is
# deny-unless-verified-safe. The cases below are that inversion's regression
# coverage, one per path that used to silently fall through to allow.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 3): criteria-only invocation (no pattern operand) is denied --"
echo "   (bypass found live: pkill -U \$(id -u) / pkill -u root reach the SAME blast radius as the"
echo "    original misordered-flag incident, just by omitting -f entirely -- 8 shapes below)"

for cmd in \
  "pkill -u root" \
  "pkill -U 501" \
  "killall -u root" \
  "pkill -G staff" \
  "pkill -P 1" \
  "pkill -t tty01" \
  "pkill -9 -U 501" \
  "pkill -U 501 -G staff" \
; do
  run_guard "$cmd"
  [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
    && ok "criteria-only '$cmd' denied (no pattern operand)" \
    || bad "criteria-only '$cmd' should be denied, got rc=$RC out=$OUT"
done
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("WIDEST possible match")' >/dev/null 2>&1 \
  && ok "criteria-only deny reason explains the BSD 'absent pattern = widest match' semantics" \
  || bad "criteria-only deny reason should explain widest-match semantics, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 3): killall's own documented multi-
# target form (`killall [procname ...]`) was a FALSE POSITIVE under the old
# single-operand assumption -- the second plain target got misread as "a
# flag placed after the pattern" (rule a) and denied. A flag genuinely
# appearing after the first target must still deny.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 3): killall multi-target is not a false positive --"

MARK_A="pkill-guard-selftest-decoy-multitarget-a-$$"
MARK_B="pkill-guard-selftest-decoy-multitarget-b-$$"

run_guard "killall $MARK_A $MARK_B"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "killall with two plain targets allowed (documented killall usage)" \
  || bad "killall with two plain targets should be allowed, got rc=$RC out=$OUT"

run_guard "killall -9 $MARK_A $MARK_B"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "killall with a leading flag then two targets allowed" \
  || bad "killall -9 <a> <b> should be allowed, got rc=$RC out=$OUT"

run_guard "killall $MARK_A -9 $MARK_B"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "killall with a flag AFTER the first target still denied (rule a still fires)" \
  || bad "killall <a> -9 <b> should still be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 3): a $(...) command substitution used
# as a CRITERIA FLAG's value (not the pattern) must survive as one opaque
# token, not get shattered by the punctuation-aware tokenizer into stray
# operands/flags. Without this fix, the guard's OWN suggested "correct form"
# in its rule-(a) deny message -- `pkill -f -U $(id -u) 'PATTERN'` -- was
# itself silently denied, which nobody would have discovered by reading the
# message, only by trying it.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 3): \$(...) as a flag's value is not shattered --"

MARK_CORRECT="pkill-guard-selftest-decoy-correctform-$$"
run_guard "pkill -f -U \$(id -u) '$MARK_CORRECT'"
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "the guard's own suggested correct form (with a real \$(id -u)) is actually allowed" \
  || bad "own suggested correct form should be allowed, got rc=$RC out=$OUT"

# An unbalanced $(...) is a genuine parse failure -- see the tokenizer-
# failure section below, not this one.

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 3), tokenizer FAILURE on a command
# already confirmed (by the coarse pre-filter) to mention pkill/killall: per
# Mayor's clarification, "cannot verify" is a RESULT that denies, distinct
# from AC4's fail-open (which is for THIS SCRIPT breaking on input unrelated
# to any specific dangerous shape). This deliberately CHANGES prior behavior
# for the unbalanced-quote case (was allow in fix-attempt 2's selftest).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 3): unparseable pkill/killall command denies, not fail-open --"

run_guard 'pkill -f "unterminated'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "unbalanced quote in a pkill command now DENIES (was fail-open through fix-attempt 2)" \
  || bad "unbalanced-quote pkill command should now deny, got rc=$RC out=$OUT"
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("could not be parsed")' >/dev/null 2>&1 \
  && ok "unparseable-command deny reason explains why" \
  || bad "deny reason should explain the parse failure, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"

run_guard 'pkill -f "x" -U $(id -u'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "unbalanced \$(...) (missing close paren) in a pkill command denied" \
  || bad "unbalanced-\$(...) pkill command should be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Engineering judgment call (fix-attempt 3) -- documented explicitly because
# it is a DELIBERATE, NARROWER reading of one line of Mayor's review rather
# than a literal implementation of it. Mayor's review listed "the coarse
# regex matched pkill/killall but no invocation was extracted" as a case
# that must deny. Taken completely literally, that would deny ANY command
# whose raw text merely CONTAINS the word "pkill"/"killall" without a real
# invocation being present -- which includes this guard's own filename
# (scripts/pkill-blast-guard.py), its own branch name
# (fix/ga-jo3xl-pkill-blast-guard), and any commit message or comment that
# mentions "pkill" -- extremely common in exactly the files this bug's own
# fix touches. Verified live before choosing this: with a literal
# CMD_RE-matched-but-zero-invocations-denies rule, `cat
# scripts/pkill-blast-guard.py` and `git commit -m "fix pkill guard"` would
# both be denied. Instead, this fix closes the NARROWER, actually-dangerous
# version of the same concern above (the tokenizer FAILING to parse a
# pkill/killall-mentioning command denies) and leaves a clean "found nothing"
# read as allow, because find_invocations already matches by exact token
# basename regardless of position (catches `sudo pkill`, `nohup pkill`,
# glued separators, etc.) -- a clean zero-invocations read is trustworthy,
# not a detector gap. If a reviewer disagrees with this call, it is a one-
# line change (drop the `if not invocations: return "allow", None` early
# return in decide()) -- flagged for visibility, not hidden in the diff.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- engineering judgment call (fix-attempt 3): mentioning pkill/killall in a filename or"
echo "   commit message, with no real invocation, is NOT denied (see selftest.sh comment + commit"
echo "   message for the full reasoning + the literal-reading false-positive this avoids) --"

run_guard 'cat scripts/pkill-blast-guard.py'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "cat on this guard's own filename is allowed (no real invocation present)" \
  || bad "cat on the guard's own filename should be allowed, got rc=$RC out=$OUT"

run_guard 'git commit -m "fix pkill guard bypass"'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "a commit message mentioning pkill is allowed (no real invocation present)" \
  || bad "commit message mentioning pkill should be allowed, got rc=$RC out=$OUT"

run_guard 'ls .gc-worktrees/fix-ga-jo3xl-pkill-blast-guard'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "a path shaped like this bug's own branch name is allowed" \
  || bad "branch-name-shaped path should be allowed, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 4), false positive: find_invocations()
# previously matched ANY token whose basename equals "pkill"/"killall"
# regardless of position, so pkill/killall used as a plain STRING ARGUMENT to
# an unrelated command (never actually invoked) was misread as a real
# invocation with zero args -- which then tripped the "no pattern/target
# operand" rule and denied a command that never runs pkill/killall at all.
# Confirmed live pre-fix: `man pkill`, `which pkill`, `echo pkill`, `type
# pkill`, `apropos killall` were ALL denied with the criteria-only message.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 4): pkill/killall as a plain argument to"
echo "   another command (not actually invoked) is allowed, not denied --"

for cmd in "man pkill" "which pkill" "echo pkill" "type pkill" "apropos killall"; do
  run_guard "$cmd"
  [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
    && ok "'$cmd' allowed (pkill/killall is an argument, not an invocation)" \
    || bad "'$cmd' should be allowed, got rc=$RC out=$OUT"
done

# A longer sentence where pkill/killall is a trailing word with no operands
# of its own -- same class as the examples above, not just single-word cases.
run_guard 'echo "run pkill to kill it"'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "pkill mentioned inside a quoted sentence argument is allowed" \
  || bad "pkill inside a quoted sentence should be allowed, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 4), non-regression: the position check
# added above must NOT stop recognizing pkill/killall invoked through a
# transparent wrapper -- sudo/doas/nohup/env, that wrapper's OWN flags (e.g.
# `sudo -u root pkill ...`), or a leading inline VAR=VALUE assignment (e.g.
# `PKILL_GUARD_MAX_MATCHES=50 pkill ...`, the same idiom this very selftest
# uses to drive the guard). None of these were previously covered by an
# explicit test -- only asserted in the module docstring -- so a naive
# "pkill must be the first word" position check would have silently
# regressed all of them from denied to allowed. Using the criteria-only
# (no-pattern) shape throughout: cheap to assert on and, per fix-attempt 3,
# denied on its own merits regardless of the wrapper prefix.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 4): wrapper-prefixed pkill/killall is still"
echo "   fully inspected (sudo, doas, nohup, env, inline VAR=VALUE, and combinations) --"

for cmd in \
  "sudo pkill -U 501" \
  "sudo -u root pkill -U 501" \
  "doas pkill -U 501" \
  "nohup pkill -U 501" \
  "env pkill -U 501" \
  "env FOO=bar pkill -U 501" \
  "FOO=bar pkill -U 501" \
  "sudo nohup pkill -U 501" \
; do
  run_guard "$cmd"
  [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
    && ok "'$cmd' still denied (wrapper does not hide the invocation)" \
    || bad "'$cmd' should still be denied, got rc=$RC out=$OUT"
done

# Glued-separator + wrapper together must still be caught too (fix-attempt 2
# regression combined with the fix-attempt 4 position check).
run_guard 'true;sudo pkill -U 501'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "wrapper glued flush against a separator ('sudo' right after ';') still denied" \
  || bad "separator-glued wrapper form should still be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Self-found regression, fixed before submission: an EARLIER version of this
# same fix-attempt-4 diff used a wrapper-command WHITELIST only (no
# non-empty-args fallback) to decide command position. Checked live against
# real invented inputs before ever writing this test: that version silently
# ALLOWED `exec pkill -U 501`, `time pkill -U 501`, `command pkill -U 501`,
# `! pkill -U 501`, and `... | xargs pkill -U 501` -- none of those
# wrapper/builtin names happened to be enumerated in WRAPPER_PREFIXES, so a
# criteria-only pkill behind any of them went through unexamined. This is the
# SAME root-class defect (a detector gap silently reading as "safe") the
# prior three fix-attempts each hit in a different spot -- catching it here,
# ourselves, before the gate, rather than shipping a fourth bypass.
# Fix: a pkill/killall token with any trailing argv of its own is now ALWAYS
# a real invocation regardless of what precedes it (see
# _is_command_position's non-empty-`args` clause) -- no wrapper enumeration
# needed for this to hold.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- self-found regression (fixed pre-submission): pkill/killall behind an"
echo "   UNENUMERATED wrapper/builtin is still denied when it has its own args --"

for cmd in \
  "exec pkill -U 501" \
  "time pkill -U 501" \
  "command pkill -U 501" \
  "! pkill -U 501" \
; do
  run_guard "$cmd"
  [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
    && ok "'$cmd' denied (non-empty args catch it even with no wrapper enumerated)" \
    || bad "'$cmd' should be denied, got rc=$RC out=$OUT"
done

run_guard 'echo x | xargs pkill -U 501'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "'... | xargs pkill -U 501' denied (unenumerated wrapper, non-empty args)" \
  || bad "xargs-piped pkill should be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (fix-attempt 4): UNVERIFIABLE_PATTERN_RE previously
# matched only named variables ($VAR, ${VAR}), $(...), and backticks -- it
# missed shell SPECIAL/POSITIONAL parameters ($1-$9, $@, $*, $#, $?, $!, $$,
# $0, $-). Confirmed live pre-fix: $1/$$/$@/$0/$#/$!/$- were silently
# ALLOWED (pgrep checked the literal unexpanded text, found ~0 matches, read
# as "confirmed safe"); $*/$? happened to DENY already, but only because
# pgrep's own regex engine errored on those two characters -- an accident of
# pgrep's parser, not this guard's own detection, and the message it produced
# ("pgrep itself failed or timed out") doesn't teach the real reason (AC5).
# This guard must refuse ALL of them as unverifiable, and for the correct,
# explained reason.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression (fix-attempt 4): special/positional shell parameters"
echo "   are refused as unverifiable, not silently allowed --"

for varref in '$1' '$9' '$0' '$@' '$*' '$#' '$?' '$!' '$$' '$-'; do
  run_guard "pkill -f \"myscript-${varref}\""
  [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
    && ok "pattern containing ${varref} denied as unverifiable" \
    || bad "pattern containing ${varref} should be denied, got rc=$RC out=$OUT"
  echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("unexpanded")' >/dev/null 2>&1 \
    && ok "${varref} deny reason names it as unexpanded/unverifiable (not a pgrep failure)" \
    || bad "${varref} deny reason should explain the unexpanded-parameter refusal, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"
done

# Bare (non-braced, non-prefixed) special parameter as the WHOLE pattern,
# not just embedded in a larger string.
run_guard 'pkill -f "$1"'
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ] \
  && ok "bare \$1 as the entire pattern denied" \
  || bad "bare \$1 pattern should be denied, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────────
# Gate-review regression (post-fix-attempt-4): the analysis-time budget was
# previously checked only once per pkill/killall INVOCATION, never once per
# OPERAND within a single invocation -- so a single multi-target killall
# (killall's own documented `killall [procname ...]` form) could blow past
# OVERALL_BUDGET_SECS with zero safety net, and past that, past the 5s
# timeout pkill-blast-guard-activate.sh registers for this hook. A
# PreToolUse hook that exceeds ITS OWN timeout does not fail closed (Claude
# Code treats a timed-out hook as though it never ran -- normal unguarded
# flow applies), so this used to be a complete, silent bypass of the whole
# guard given enough targets. Reviewer measured ~17.6ms/operand live;
# 150 synthetic (guaranteed non-matching) targets is comfortably past the
# ~51 needed to exceed the 0.9s budget, while staying well under both the
# 5s hook timeout and this selftest's own patience.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate-review regression: many-target killall denies via budget, not timeout bypass --"

MANY_TARGETS=""
for n in $(seq 1 150); do
  MANY_TARGETS="$MANY_TARGETS pkill-guard-selftest-budget-decoy-$$-$n"
done

START_NS=$(date +%s%N)
run_guard "killall$MANY_TARGETS"
END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
  ok "killall with 150 targets denied (was an unguarded timeout-bypass pre-fix)"
else
  bad "killall with 150 targets should be denied, got rc=$RC out=$OUT"
fi
echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("analysis time budget")' >/dev/null 2>&1 \
  && ok "150-target denial reason is the budget check (proves the per-operand gate fired, not a per-pattern one)" \
  || bad "150-target deny reason should cite the analysis time budget, got: $(echo "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // "MISSING"')"
if [ "$ELAPSED_MS" -lt 4500 ]; then
  ok "guard returned in ${ELAPSED_MS}ms, comfortably under the hook's 5s registered timeout"
else
  bad "guard took ${ELAPSED_MS}ms -- too close to (or past) the hook's 5s timeout, budget enforcement may not be working"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Activation script: idempotent compose-not-replace merge into a SCRATCH
# settings.json (never the live file).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "-- pkill-blast-guard-activate.sh: composes with existing hooks, idempotent --"
TMP_SETTINGS="$(mktemp)"
cat > "$TMP_SETTINGS" <<'JSONEOF'
{
  "awaySummaryEnabled": false,
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "gc prime --hook" } ] }
    ]
  }
}
JSONEOF

PKILL_GUARD_CITY="$(cd "$HERE/.." && pwd)" bash "$ACTIVATE" "$TMP_SETTINGS" >/tmp/pkill-guard-activate-selftest.$$ 2>&1
ACT_RC=$?
if [ "$ACT_RC" -eq 0 ] \
   && jq -e '.hooks.SessionStart[0].hooks[0].command == "gc prime --hook"' "$TMP_SETTINGS" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$TMP_SETTINGS" >/dev/null 2>&1 \
   && jq -e '.hooks.PreToolUse[0].hooks[0].command | contains("pkill-blast-guard.py")' "$TMP_SETTINGS" >/dev/null 2>&1; then
  ok "activate: added PreToolUse:Bash hook, left the existing SessionStart hook untouched (compose, not replace)"
else
  bad "activate: expected SessionStart preserved + PreToolUse added, got: $(cat "$TMP_SETTINGS")"
fi

# Re-run: must stay idempotent (exactly one PreToolUse entry, not two).
PKILL_GUARD_CITY="$(cd "$HERE/.." && pwd)" bash "$ACTIVATE" "$TMP_SETTINGS" >/tmp/pkill-guard-activate-selftest2.$$ 2>&1
COUNT="$(jq '.hooks.PreToolUse | length' "$TMP_SETTINGS" 2>/dev/null)"
[ "$COUNT" = "1" ] && ok "activate: re-running is idempotent (still exactly 1 PreToolUse entry)" \
  || bad "activate: expected exactly 1 PreToolUse entry after re-run, got $COUNT"

rm -f "$TMP_SETTINGS" /tmp/pkill-guard-activate-selftest.$$ /tmp/pkill-guard-activate-selftest2.$$ /tmp/pkill-guard-selftest-stderr.$$ 2>/dev/null || true

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
