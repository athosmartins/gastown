#!/usr/bin/env bash
# pkill-blast-guard.selftest.sh (ga-tje7u, supersedes ga-jo3xl) — hermetic
# tests for pkill-blast-guard.py and pkill-blast-guard-activate.sh.
#
# Drives the guard as a real subprocess (the exact JSON a Claude Code
# PreToolUse:Bash hook receives on stdin) and asserts on its stdout JSON +
# exit code. No mocking. Per AC9: every DENY case asserts on the deny
# REASON text, not just the decision — with a single rule there is only
# one possible reason, so this mostly proves the reason is the real one
# (cites ga-jo3xl, teaches the substitute) and not an empty/wrong string.
#
# TEST: bash pkill-blast-guard.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/pkill-blast-guard.py"
ACTIVATE="$HERE/pkill-blast-guard-activate.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# run_guard <command-string> [extra_env...] -> sets OUT (stdout), RC (exit code)
run_guard() {
  local cmd="$1"; shift
  local payload
  payload="$(jq -n --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')"
  OUT="$(printf '%s' "$payload" | env "$@" python3 "$GUARD" 2>/tmp/pkill-guard-selftest-stderr.$$)"
  RC=$?
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow-implicit"' 2>/dev/null; }
reason_of()   { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

assert_deny() {
  local label="$1" cmd="$2"; shift 2
  run_guard "$cmd" "$@"
  if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" = "deny" ]; then
    ok "$label -> denied"
  else
    bad "$label -> expected deny, got rc=$RC out=$OUT"
    return 1
  fi
  # AC9: the reason must be the REAL rule firing, not an empty/wrong string —
  # every deny cites ga-jo3xl (there is only one rule, so this is also a
  # cheap proxy for "a real permissionDecisionReason was emitted at all").
  local reason; reason="$(reason_of "$OUT")"
  case "$reason" in
    *ga-jo3xl*) ok "$label -> deny reason cites ga-jo3xl" ;;
    *) bad "$label -> deny reason should cite ga-jo3xl, got: $reason" ;;
  esac
}

assert_allow() {
  local label="$1" cmd="$2"; shift 2
  run_guard "$cmd" "$@"
  if [ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ]; then
    ok "$label -> allowed"
  else
    bad "$label -> expected allow, got rc=$RC out=$OUT"
  fi
}

echo "=== pkill-blast-guard.selftest.sh (ga-tje7u) ==="

# ─────────────────────────────────────────────────────────────────────────
# AC11: the exact incident line (with its real trailing redirects) denies.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC11: verbatim incident line --"
assert_deny "verbatim ga-jo3xl incident line" \
  'pkill -f "ANUNCIOS_PORT=8214" 2>/dev/null; pkill -f "anuncios_dashboard.py" -U $(id -u) 2>/dev/null | true'

# ─────────────────────────────────────────────────────────────────────────
# AC2: bare pkill/killall, and after every listed separator.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2: bare invocation + every separator form --"
assert_deny "bare pkill"                 'pkill -f "anuncios_dashboard.py" -U $(id -u)'
assert_deny "bare killall"               'killall -u root'
assert_deny "after ;"                    'echo hi;pkill -U 501'
assert_deny "after &&"                   'cd /tmp&&pkill -U 501'
assert_deny "after ||"                   'true||pkill -U 501'
assert_deny "after | (pipe)"             'true|pkill -U 501'
assert_deny "after & (background)"       'sleep 1&pkill -U 501'
assert_deny "after ( (subshell open)"    '(pkill -U 501)'
assert_deny "after { (group open)"       '{ pkill -U 501; }'
assert_deny "after newline"              'echo hi
pkill -U 501'
assert_deny "glued ;pkill + \$(...) flag value" \
  'true;pkill -f "anuncios_dashboard.py" -U $(id -u)'

# Quoting must still protect a separator character that's genuinely part of
# a pattern -- not mistaken for a real separator.
assert_allow "semicolon inside a quoted pattern is not a separator" \
  "echo 'foo;bar;baz'"

# ─────────────────────────────────────────────────────────────────────────
# AC2: env-assignment prefix and sudo/doas/nohup/env/time/xargs.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC2: env-assignment + wrapper prefixes --"
assert_deny "FOO=1 pkill (bare, literal AC2 example)"  'FOO=1 pkill'
assert_deny "FOO=1 pkill -U 501"                       'FOO=1 pkill -U 501'
assert_deny "sudo pkill"                               'sudo pkill -U 501'
assert_deny "doas pkill"                               'doas pkill -U 501'
assert_deny "nohup pkill"                              'nohup pkill -U 501'
assert_deny "env pkill"                                'env pkill -U 501'
assert_deny "time pkill"                               'time pkill -U 501'
assert_deny "xargs pkill (direct)"                     'xargs pkill -U 501'
assert_deny "xargs pkill (piped)"                      'echo x | xargs pkill -U 501'
assert_deny "sudo -u root pkill (wrapper's own flags)" 'sudo -u root pkill -U 501'
assert_deny "env FOO=bar pkill (wrapper + assignment)" 'env FOO=bar pkill -U 501'
assert_deny "sudo nohup pkill (chained wrappers)"      'sudo nohup pkill -U 501'
assert_deny "wrapper glued flush against separator"    'true;sudo pkill -U 501'

# ─────────────────────────────────────────────────────────────────────────
# AC3: pkill/killall as a plain ARGUMENT to an unrelated command — must
# ALLOW. Includes the grep case, which a naive "has trailing args" rule
# would misdeny (see design note in the guard script) — this is the
# regression that most distinguishes this design from a tempting-but-wrong
# alternative, so it gets its own explicit case.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC3: pkill/killall mentioned as a plain argument, not invoked --"
assert_allow "man pkill"              'man pkill'
assert_allow "which pkill"            'which pkill'
assert_allow "type pkill"             'type pkill'
assert_allow "echo pkill"             'echo pkill'
assert_allow "apropos killall"        'apropos killall'
assert_allow "git commit -m ...pkill..." 'git commit -m "fix pkill guard bypass"'
assert_allow "comment citing pkill"   '# this mentions pkill, not a real call'
assert_allow "grep pkill arquivo.sh (AC3 named case)" 'grep pkill arquivo.sh'
assert_allow "sudo echo pkill (sudo's TARGET is echo, not pkill)" 'sudo echo pkill -U 501'
assert_allow "env FOO=1 grep pkill (env's TARGET is grep, not pkill)" 'env FOO=1 grep pkill file.log'
assert_allow "pkill inside a quoted sentence"          'echo "run pkill to kill it"'
assert_allow "cat this guard's own filename"           'cat scripts/pkill-blast-guard.py'
assert_allow "kill \$PID (different command entirely)" 'kill $PID'
assert_allow "ordinary command, no pkill/killall at all" 'ls -la /tmp'

# ─────────────────────────────────────────────────────────────────────────
# AC10: redirection is never mistaken for real trailing content, in EITHER
# direction. The 4 mandatory DENY cases from ga-tje7u's own text, plus the
# 2 mandatory ALLOW cases (the "inverse").
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC10: redirects around a real invocation still deny --"
assert_deny "pkill -U 501 2>/dev/null"          'pkill -U 501 2>/dev/null'
assert_deny "pkill -U \$(id -u) >/tmp/x"        'pkill -U $(id -u) >/tmp/x'
assert_deny "pkill -U 501 >out 2>&1"            'pkill -U 501 >out 2>&1'
assert_deny "killall -u root 2>/dev/null"       'killall -u root 2>/dev/null'

echo ""
echo "-- AC10: redirects around a NON-invocation (argument use) still allow --"
assert_allow "echo pkill > /tmp/x"    'echo pkill > /tmp/x'
assert_allow "man pkill 2>/dev/null"  'man pkill 2>/dev/null'

# ─────────────────────────────────────────────────────────────────────────
# AC9/AC12 (2026-07-29 gate FAIL + Mayor 9-hole sweep, fix-attempt 1): the
# first gate run found the guard's own `_tokenize()` let shlex's default
# '#' comment handling swallow a REAL pkill call on the line after a
# comment, because the newline that should have ended the comment had
# already been rewritten to ';' before shlex ever saw the string. The
# Mayor then swept the whole class ("does this construct make the guard
# IGNORE or REWRITE text?") and found 8 more of the same shape: shell
# block keywords (if/then, while/do, for/do, case/)), and a pkill hidden
# inside a $(...) used for something else. Per the Mayor's AC12 mandate,
# every such construct gets TWO cases: (a) alone, it must still ALLOW
# (proves the fix didn't just start over-denying everything with a "#",
# "if", etc. in it) and (b) with a real pkill hidden inside/after it, it
# must DENY (proves the hole is actually closed, not just the exact
# string from the report).
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC12: comments (word-initial '#', quote- and mid-word-aware) --"
assert_allow "comment only, nothing after (AC3, pre-existing)" \
  '# this mentions pkill, not a real call'
assert_allow "comment after a real command, nothing dangerous follows" \
  'echo hi
# just a note, nothing dangerous here'
assert_allow "mid-word # is not a comment (URL fragment)" \
  'curl http://example.com/#frag'
assert_allow "quoted # is not a comment" \
  'echo "a # b" pkill'
assert_deny "gate-FAIL case: comment then real pkill on the next line" \
  '# note
pkill -f a'
assert_deny "gate's own verbatim reviewed example" \
  '# Clean up stale processes
pkill -f "anuncios_dashboard.py" -U $(id -u)'
assert_deny "trailing comment on the SAME line as other text, pkill on the next" \
  'echo a # nota
pkill -f a'

echo ""
echo "-- AC12: shell block keywords (then/do/else/elif) + case-pattern ')' --"
assert_allow "if/then, no pkill"     'if true; then echo ok; fi'
assert_deny  "if/then hides pkill"   'if true; then pkill -f a; fi'
assert_allow "while/do, no pkill"    'while read l; do echo "$l"; done'
assert_deny  "while/do hides pkill"  'while read l; do pkill -f a; done'
assert_allow "for/do, no pkill"      'for i in 1 2; do echo "$i"; done'
assert_deny  "for/do hides pkill"    'for i in 1 2; do pkill -f a; done'
assert_allow "case, no pkill"        'case $x in a) echo ok;; esac'
assert_deny  "case hides pkill"      'case $x in a) pkill -f a;; esac'
assert_allow "if/else, no pkill"     'if false; then echo x; else echo y; fi'
assert_deny  "if/else hides pkill"   'if false; then echo x; else pkill -f a; fi'
assert_deny  "if/elif hides pkill"   'if false; then echo x; elif true; then pkill -f a; fi'

echo ""
echo "-- AC12: \$(...) / \`...\` command substitution, scanned recursively --"
assert_allow "cmdsub, no pkill anywhere"        'echo $(echo a)'
assert_allow "backtick cmdsub, no pkill"        'echo `echo a`'
assert_deny  "cmdsub hides pkill in a ;-list"   'echo $(echo a; pkill -f a)'
assert_deny  "bare cmdsub wraps the whole call" '$(pkill -9 -f pattern)'
assert_deny  "cmdsub result assigned to a var"  'x=$(sudo pkill -f a)'
assert_deny  "backtick form hides a real pkill" 'echo `pkill -f a`'

echo ""
echo "-- AC12: backslash-escape inside the pkill/killall token itself --"
assert_allow "unrelated backslash-escaped command still allows" 'ec\ho hello'
assert_deny  'backslash-escape hides the literal substring, not the token (pk\ill)' 'pk\ill -f a'

echo ""
echo "-- known, accepted gap (do NOT flip to deny without new machinery) --"
echo "   eval's string argument is re-interpreted as shell BY eval itself,"
echo "   which no shell-syntax scan can see -- ga-tje7u Mayor sweep, "
echo "   2026-07-29, explicitly declined ('fix if free, don't build"
echo "   machinery to chase it'). This assert_allow documents the gap as"
echo "   INTENTIONAL so a future reviewer doesn't mistake it for a miss."
assert_allow "eval hides a real pkill (accepted, documented gap)" 'eval "pkill -f a"'

echo ""
echo "-- regression guard: line continuation and heredocs (Mayor sweep named" \
     "these 'already correct' but neither was actually pinned as a test) --"
assert_deny "backslash-newline continuation, pkill's OWN args span lines" \
  'pkill \
-f a'
assert_allow "backslash-newline continuation joins into echo's args -- never really invokes pkill" \
  'echo hi \
pkill -U 501'
assert_deny "heredoc body precedes a real pkill call on a later line" \
  'cat <<EOF
some text
EOF
pkill -f a'

# ─────────────────────────────────────────────────────────────────────────
# AC4: unparseable shell syntax that still mentions pkill/killall denies
# (fail CLOSED on this narrow edge — it wouldn't run in real bash either).
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC4: unparseable + mentions the token -> deny (fail-closed) --"
assert_deny "unbalanced quote"       'pkill -f "unterminated'
assert_deny "unbalanced \$(...)"     'pkill -f "x" -U $(id -u'

# ─────────────────────────────────────────────────────────────────────────
# AC5: the guard's OWN internal error fails OPEN (never denies everything).
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC5: internal error fails OPEN --"
run_guard 'pkill -f "anuncios_dashboard.py" -U $(id -u)' PKILL_GUARD_SELFTEST_FORCE_ERROR=1
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "forced internal error on an otherwise-dangerous command still ALLOWS" \
  || bad "forced internal error should fail OPEN, got rc=$RC out=$OUT"

run_guard 'echo hello world' PKILL_GUARD_SELFTEST_FORCE_ERROR=1
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "forced error on a command with no pkill/killall mention still fails OPEN" \
  || bad "forced error on unrelated command should fail open, got rc=$RC out=$OUT"

OUT="$(printf 'not json at all' | python3 "$GUARD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "malformed stdin JSON fails OPEN (rc=0, no deny)" \
  || bad "malformed stdin should fail open, got rc=$RC out=$OUT"

# Non-Bash tool calls are never inspected at all.
OUT="$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' | python3 "$GUARD" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$(decision_of "$OUT")" != "deny" ] \
  && ok "non-Bash tool_name ignored" \
  || bad "non-Bash tool_name should be a no-op allow, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────
# Activation script: idempotent compose-not-replace merge into a SCRATCH
# settings.json (never the live file).
# ─────────────────────────────────────────────────────────────────────────
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
  ok "activate: added PreToolUse:Bash hook, left existing SessionStart hook untouched"
else
  bad "activate: expected SessionStart preserved + PreToolUse added, got: $(cat "$TMP_SETTINGS")"
fi

PKILL_GUARD_CITY="$(cd "$HERE/.." && pwd)" bash "$ACTIVATE" "$TMP_SETTINGS" >/tmp/pkill-guard-activate-selftest2.$$ 2>&1
COUNT="$(jq '.hooks.PreToolUse | length' "$TMP_SETTINGS" 2>/dev/null)"
[ "$COUNT" = "1" ] && ok "activate: re-running is idempotent (still exactly 1 PreToolUse entry)" \
  || bad "activate: expected exactly 1 PreToolUse entry after re-run, got $COUNT"

rm -f "$TMP_SETTINGS" /tmp/pkill-guard-activate-selftest.$$ /tmp/pkill-guard-activate-selftest2.$$ /tmp/pkill-guard-selftest-stderr.$$ 2>/dev/null || true

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
