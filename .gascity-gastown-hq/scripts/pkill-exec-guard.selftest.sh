#!/usr/bin/env bash
# pkill-exec-guard.selftest.sh (ga-79ge9, successor to ga-tje7u after 7
# failed shell-text-parsing rounds) -- hermetic tests for
# pkill-exec-guard.sh + pkill-exec-guard-activate.sh.
#
# Deploys into a SCRATCH bin dir (PKILL_EXEC_GUARD_BIN_DIR override) and
# a scratch log file (PKILL_EXEC_GUARD_LOG override) -- never touches the
# real ~/.local/bin or the real guard log. Every guard invocation in this
# file either targets a random nonce pattern guaranteed to match no real
# process, or stays entirely inside the REFUSE branch (which never
# execs anything). This file never runs a real pkill/killall against a
# pattern that could match a live process on this machine.
#
# TEST: bash pkill-exec-guard.selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVATE="$HERE/pkill-exec-guard-activate.sh"
GUARD_SOURCE="$HERE/pkill-exec-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

BIN_DIR="$SCRATCH/bin"
LOG_FILE="$SCRATCH/guard.log"
NONCE="pkill-exec-guard-selftest-nonce-$$-$RANDOM-does-not-exist"

export PKILL_EXEC_GUARD_BIN_DIR="$BIN_DIR"
export PKILL_EXEC_GUARD_LOG="$LOG_FILE"

log_lines() { wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0; }

# ─────────────────────────────────────────────────────────────────────────
# Deploy: activate script installs both shims into the scratch bin dir.
# ─────────────────────────────────────────────────────────────────────────
echo "-- deploy: activate script installs both shims into scratch bin dir --"
bash "$ACTIVATE" >/tmp/pxg-selftest-deploy.$$ 2>&1
RC_DEPLOY=$?
if [ "$RC_DEPLOY" -eq 0 ] && [ -x "$BIN_DIR/pkill" ] && [ -x "$BIN_DIR/killall" ] \
   && cmp -s "$GUARD_SOURCE" "$BIN_DIR/pkill" && cmp -s "$GUARD_SOURCE" "$BIN_DIR/killall"; then
  ok "activate: deployed executable pkill+killall, byte-identical to source"
else
  bad "activate: expected both deployed+executable+identical, rc=$RC_DEPLOY out=$(cat /tmp/pxg-selftest-deploy.$$ 2>/dev/null)"
fi

bash "$ACTIVATE" >/tmp/pxg-selftest-deploy2.$$ 2>&1
BAK_COUNT="$(ls "$BIN_DIR"/*.bak.* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BAK_COUNT" = "0" ] && grep -q "up to date" /tmp/pxg-selftest-deploy2.$$; then
  ok "activate: re-run is idempotent (no backup created, reports already-up-to-date)"
else
  bad "activate: expected idempotent no-op, got bak_count=$BAK_COUNT out=$(cat /tmp/pxg-selftest-deploy2.$$ 2>/dev/null)"
fi

echo "modified" >> "$BIN_DIR/pkill"
bash "$ACTIVATE" >/tmp/pxg-selftest-deploy3.$$ 2>&1
BAK_COUNT_2="$(ls "$BIN_DIR"/pkill.bak.* 2>/dev/null | wc -l | tr -d ' ')"
if [ "$BAK_COUNT_2" = "1" ] && cmp -s "$GUARD_SOURCE" "$BIN_DIR/pkill"; then
  ok "activate: detects drift, backs up modified file, restores from source"
else
  bad "activate: expected 1 backup + restored content, got bak=$BAK_COUNT_2"
fi

# ─────────────────────────────────────────────────────────────────────────
# Guard: agent-context signals (GC_AGENT / GC_ALIAS / GC_DIR) refuse.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- guard: agent-context env vars refuse, never reach the real binary --"

: > "$LOG_FILE"
OUT="$(GC_AGENT=selftest-agent GC_ALIAS= GC_DIR= "$BIN_DIR/pkill" -f "$NONCE" 2>&1)"
RC=$?
if [ "$RC" -eq 77 ] && echo "$OUT" | grep -q "BLOCKED"; then
  ok "pkill refuses with GC_AGENT set (exit 77, BLOCKED message)"
else
  bad "pkill with GC_AGENT: expected exit 77 + BLOCKED, got rc=$RC out=$OUT"
fi
grep -q "REFUSED" "$LOG_FILE" 2>/dev/null && ok "refusal logged" || bad "refusal not logged: $(cat "$LOG_FILE" 2>/dev/null)"

: > "$LOG_FILE"
OUT="$(GC_AGENT= GC_ALIAS=selftest-alias GC_DIR= "$BIN_DIR/killall" "$NONCE" 2>&1)"
RC=$?
if [ "$RC" -eq 77 ] && echo "$OUT" | grep -q "BLOCKED" && echo "$OUT" | grep -q "killall"; then
  ok "killall refuses with GC_ALIAS set (exit 77, BLOCKED message names killall)"
else
  bad "killall with GC_ALIAS: expected exit 77 + BLOCKED + 'killall', got rc=$RC out=$OUT"
fi

: > "$LOG_FILE"
OUT="$(GC_AGENT= GC_ALIAS= GC_DIR=/some/agent/dir "$BIN_DIR/pkill" -f "$NONCE" 2>&1)"
RC=$?
[ "$RC" -eq 77 ] && ok "pkill refuses on GC_DIR alone (third fallback signal)" \
  || bad "pkill with only GC_DIR: expected exit 77, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────
# Guard: no agent-context signal -> transparent passthrough to real binary.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- guard: no agent env vars -> transparent passthrough to real binary --"

: > "$LOG_FILE"
OUT="$(env -u GC_AGENT -u GC_ALIAS -u GC_DIR "$BIN_DIR/pkill" -f "$NONCE" 2>&1)"
RC=$?
if [ "$RC" -ne 77 ] && ! echo "$OUT" | grep -q "BLOCKED"; then
  ok "pkill passes through without agent env (rc=$RC, no BLOCKED -- real pkill's own no-match exit)"
else
  bad "pkill without agent env: expected passthrough (rc!=77, no BLOCKED), got rc=$RC out=$OUT"
fi
grep -q "ALLOWED" "$LOG_FILE" 2>/dev/null && ok "passthrough logged as ALLOWED" || bad "passthrough not logged: $(cat "$LOG_FILE" 2>/dev/null)"

OUT="$(env -u GC_AGENT -u GC_ALIAS -u GC_DIR "$BIN_DIR/killall" "$NONCE" 2>&1)"
RC=$?
if [ "$RC" -ne 77 ] && ! echo "$OUT" | grep -q "BLOCKED"; then
  ok "killall passes through without agent env"
else
  bad "killall without agent env: expected passthrough, got rc=$RC out=$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────
# Guard: deployed under an unrecognized name refuses to guess a real binary.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- guard: unrecognized basename does not fall through to any real binary --"
cp "$GUARD_SOURCE" "$BIN_DIR/mystery-name"
chmod +x "$BIN_DIR/mystery-name"
OUT="$(env -u GC_AGENT -u GC_ALIAS -u GC_DIR "$BIN_DIR/mystery-name" -f "$NONCE" 2>&1)"
RC=$?
[ "$RC" -eq 78 ] && ok "unrecognized basename exits distinctly (78), no fallthrough" \
  || bad "unrecognized basename: expected exit 78, got rc=$RC out=$OUT"

# ─────────────────────────────────────────────────────────────────────────
# AC1-4: real bash constructs that must PASS -- pkill/killall appear only
# as inert text, never in command position, so the guard must never even
# be reached. PATH is wired to the scratch bin dir and GC_AGENT is set for
# every one of these, specifically to prove it's not passing "by accident"
# because the guard was unreachable -- if any of these DID somehow invoke
# the real shim, the log-line-count assertion below would catch it.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC1-4: bash constructs that mention pkill/killall as inert text --"

AC_DIR="$SCRATCH/ac-tests"
mkdir -p "$AC_DIR"

# AC1: heredoc redirected to a file; body mentions "pkill/killall is blocked".
AC1_SCRIPT="$SCRATCH/ac1.sh"
cat > "$AC1_SCRIPT" <<'OUTER_EOF'
cat > "$AC_FILE" <<'EOF'
this line explains that pkill/killall is blocked for agent sessions
EOF
OUTER_EOF
: > "$LOG_FILE"
AC_FILE="$AC_DIR/reason.txt" PATH="$BIN_DIR:$PATH" GC_AGENT=selftest-agent bash "$AC1_SCRIPT"
RC1=$?
if [ "$RC1" -eq 0 ] && grep -q "pkill/killall is blocked" "$AC_DIR/reason.txt" 2>/dev/null && [ "$(log_lines)" = "0" ]; then
  ok "AC1: heredoc-to-file mentioning pkill/killall is blocked -- succeeds, guard never invoked"
else
  bad "AC1: expected rc=0 + file content + zero log lines, got rc=$RC1 log_lines=$(log_lines)"
fi

# AC2: heredoc body containing a literal "pkill -f a" line, printed not executed.
AC2_SCRIPT="$SCRATCH/ac2.sh"
cat > "$AC2_SCRIPT" <<'OUTER_EOF'
cat <<'EOF'
pkill -f a
EOF
OUTER_EOF
: > "$LOG_FILE"
AC2_OUT="$(PATH="$BIN_DIR:$PATH" GC_AGENT=selftest-agent bash "$AC2_SCRIPT")"
RC2=$?
if [ "$RC2" -eq 0 ] && [ "$AC2_OUT" = "pkill -f a" ] && [ "$(log_lines)" = "0" ]; then
  ok "AC2: heredoc body containing 'pkill -f a' -- printed as data, guard never invoked"
else
  bad "AC2: expected rc=0 + literal output + zero log lines, got rc=$RC2 out='$AC2_OUT' log_lines=$(log_lines)"
fi

# AC3: git commit -m "$(heredoc)" with "pkill" in a paragraph of the message.
: > "$LOG_FILE"
GIT_SCRATCH="$SCRATCH/git-ac3"
mkdir -p "$GIT_SCRATCH"
git -C "$GIT_SCRATCH" init -q
PATH="$BIN_DIR:$PATH" GC_AGENT=selftest-agent \
  git -C "$GIT_SCRATCH" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$(cat <<'EOF'
fix: unrelated change

this paragraph discusses pkill and killall guard behavior for context
EOF
)"
RC3=$?
COMMIT_MSG="$(git -C "$GIT_SCRATCH" log -1 --format=%B 2>/dev/null)"
if [ "$RC3" -eq 0 ] && echo "$COMMIT_MSG" | grep -q "pkill" && [ "$(log_lines)" = "0" ]; then
  ok "AC3: git commit with 'pkill' in a heredoc-built message paragraph -- succeeds, guard never invoked"
else
  bad "AC3: expected rc=0 + commit message containing pkill + zero log lines, got rc=$RC3 log_lines=$(log_lines)"
fi

# AC4: escaped command substitution, printed literally not executed.
# NOTE: the bead's own text writes this as `echo \$(pkill -f a)` with no
# surrounding quotes -- verified empirically that form is not valid shell
# at all (bash: "syntax error near unexpected token `('"), independent of
# this guard; a bare backslash-escaped `\$` still leaves a bare `(`
# immediately after it, and bash's grammar doesn't accept that mid-word.
# The double-quoted form below is the valid version of the same intent
# (escaped $ suppresses command substitution; pkill is mentioned, never
# invoked) and is what the bead must actually have meant.
AC4_SCRIPT="$SCRATCH/ac4.sh"
cat > "$AC4_SCRIPT" <<'OUTER_EOF'
echo "\$(pkill -f a)"
OUTER_EOF
: > "$LOG_FILE"
AC4_OUT="$(PATH="$BIN_DIR:$PATH" GC_AGENT=selftest-agent bash "$AC4_SCRIPT")"
RC4=$?
if [ "$RC4" -eq 0 ] && [ "$AC4_OUT" = '$(pkill -f a)' ] && [ "$(log_lines)" = "0" ]; then
  ok "AC4: escaped \$(pkill -f a) prints literally, guard never invoked"
else
  bad "AC4: expected literal output + zero log lines, got rc=$RC4 out='$AC4_OUT' log_lines=$(log_lines)"
fi

# ─────────────────────────────────────────────────────────────────────────
# AC5: a REAL pkill invocation in a fresh subprocess must be refused.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- AC5: a real pkill invocation is refused in a fresh subprocess --"
: > "$LOG_FILE"
AC5_SCRIPT="$SCRATCH/ac5.sh"
cat > "$AC5_SCRIPT" <<OUTER_EOF
pkill -f '$NONCE'
OUTER_EOF
AC5_OUT="$(PATH="$BIN_DIR:$PATH" GC_AGENT=selftest-agent bash "$AC5_SCRIPT" 2>&1)"
RC5=$?
if [ "$RC5" -eq 77 ] && echo "$AC5_OUT" | grep -q "BLOCKED"; then
  ok "AC5: real 'pkill -f <pattern>' invocation in a fresh subprocess is refused"
else
  bad "AC5: expected exit 77 + BLOCKED, got rc=$RC5 out=$AC5_OUT"
fi

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
