#!/bin/bash
# safe-clean.selftest.sh — hermetic behavioral test for safe-clean.py
# (ga-gkap9p: rm -rf's ask-rule stalls agents on disposable-path cleanup).
#
# Hermetic: everything happens under a mktemp -d WORKDIR, including a fake
# HOME for the ~-anchored rules, so this never touches the real filesystem
# outside that tree. Runs the REAL script as a subprocess (not a
# reimplementation of its logic), so this exercises the actual code path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/safe-clean.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Fake HOME so ~-anchored rules (~/.cache, ~/Library/CloudStorage,
# ~/gt/*/shared/data) are exercised without touching the real home dir.
FAKE_HOME="$WORKDIR/home"
mkdir -p "$FAKE_HOME"
run() { HOME="$FAKE_HOME" python3 "$SCRIPT" "$@"; }

echo "=== safe-clean.selftest.sh ==="

# Real layout is /private/tmp/claude-<uid>/<project-slug>/<session-id>/...  —
# claude-<uid> is SHARED by every concurrent session/project for that user
# (ga-gkap9p gate-fix 3). Synthesize that same shape everywhere below
# (.../proj/sess/...) instead of a bare claude-<n> root, so these tests
# exercise a genuinely-allowed path, not one that only happens to still work
# because it's shallow.

# ── 1. scratchpad passes, at and below the session-id boundary ─────────────
UIDROOT1="/private/tmp/claude-selftest1-$$"
SESSDIR1="$UIDROOT1/proj/sess"
mkdir -p "$SESSDIR1/scratchpad"
echo x > "$SESSDIR1/scratchpad/file.txt"
OUT=$(run "$SESSDIR1" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$SESSDIR1" ]; then
  ok "session-id dir (uid/proj/sess) removed, exit 0 — right at the boundary"
else
  bad "session-id dir removal failed (rc=$RC): $OUT"
fi
rm -rf "$UIDROOT1" 2>/dev/null

# ── 1b. the shared claude-<uid> root itself, and claude-<uid>/<project>, are
# ── refused — the exact cross-session-collision bug (ga-gkap9p gate-fix 3):
# ── these used to match the allow rule at depth 3 and get wiped wholesale,
# ── taking every OTHER concurrent session's scratchpad with them ───────────
UIDROOT1B="/private/tmp/claude-selftest1b-$$"
mkdir -p "$UIDROOT1B/other-session/scratchpad"
echo not-mine > "$UIDROOT1B/other-session/scratchpad/file.txt"
OUT=$(run "$UIDROOT1B" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$UIDROOT1B/other-session/scratchpad/file.txt" ]; then
  ok "bare claude-<uid> root refused (exit 2); other sessions' data survives"
else
  bad "bare claude-<uid> root should be refused, not wiped (rc=$RC): $OUT"
fi
OUT=$(run "$UIDROOT1B/other-session" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$UIDROOT1B/other-session/scratchpad/file.txt" ]; then
  ok "claude-<uid>/<project> root (one level short) also refused, survives"
else
  bad "claude-<uid>/<project> root should also be refused (rc=$RC): $OUT"
fi
rm -rf "$UIDROOT1B" 2>/dev/null

# ── 2. protected dirs refuse, even NESTED INSIDE an allowed scratchpad ─────
# (this is also the deny-wins-over-allow-on-double-match test: the parent
# dir matches the /private/tmp/claude-*/*/*/** allow rule, but .gc-worktrees
# is a path component inside it, and deny must still win.)
for name in .gc-worktrees .beads .dolt crew; do
  TARGET="/private/tmp/claude-selftest2-$$/proj/sess/$name/wip-file"
  mkdir -p "$(dirname "$TARGET")"
  echo important > "$TARGET"
  OUT=$(run "/private/tmp/claude-selftest2-$$/proj/sess/$name" 2>&1); RC=$?
  if [ "$RC" -eq 2 ] && [ -e "$TARGET" ]; then
    ok "$name/ refused (exit 2), survives, even nested under an allowed scratchpad"
  else
    bad "$name/ should have been refused and preserved (rc=$RC): $OUT"
  fi
done
rm -rf "/private/tmp/claude-selftest2-$$" 2>/dev/null

# ── 3. symlink pointing outward is not a free pass ─────────────────────────
IMPORTANT_DIR="$WORKDIR/important-elsewhere"
mkdir -p "$IMPORTANT_DIR"
echo do-not-delete-me > "$IMPORTANT_DIR/secret.txt"
mkdir -p "/private/tmp/claude-selftest3-$$"
ln -s "$IMPORTANT_DIR" "/private/tmp/claude-selftest3-$$/escape-link"
OUT=$(run "/private/tmp/claude-selftest3-$$/escape-link" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$IMPORTANT_DIR/secret.txt" ]; then
  ok "symlink out of the allowed tree is refused; target survives"
else
  bad "symlink escape was not caught (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest3-$$" 2>/dev/null

# ── 4. ".." pointing outward is not a free pass ─────────────────────────────
mkdir -p "/private/tmp/claude-selftest4-$$/sub"
# textually walks out to $WORKDIR then into the important dir — no symlink involved
REL_TRAVERSAL="/private/tmp/claude-selftest4-$$/sub/../../..$IMPORTANT_DIR"
OUT=$(run "$REL_TRAVERSAL" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$IMPORTANT_DIR/secret.txt" ]; then
  ok "'..' traversal out of the allowed tree is refused; target survives"
else
  bad "'..' traversal was not caught (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest4-$$" 2>/dev/null

# ── 5. injection / "prose" safety: a weird literal argument is just a
# ── nonexistent path, never shell-evaluated ────────────────────────────────
CANARY="$WORKDIR/canary"
mkdir -p "$CANARY"
OUT=$(run '; rm -rf '"$CANARY"' #' 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -d "$CANARY" ]; then
  ok "shell-metacharacter-laden argument is treated as a literal path, refused, no injection"
else
  bad "injection-shaped argument misbehaved (rc=$RC), canary present=$([ -d "$CANARY" ] && echo yes || echo no): $OUT"
fi

# ── 6. multi-arg is all-or-nothing ──────────────────────────────────────────
mkdir -p "/private/tmp/claude-selftest6-$$/proj/sess"
echo x > "/private/tmp/claude-selftest6-$$/proj/sess/ok-file"
DENY_TARGET="/private/tmp/claude-selftest6b-$$/proj/sess/.beads/db"
mkdir -p "$(dirname "$DENY_TARGET")"
echo x > "$DENY_TARGET"
OUT=$(run "/private/tmp/claude-selftest6-$$/proj/sess" "/private/tmp/claude-selftest6b-$$/proj/sess/.beads" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "/private/tmp/claude-selftest6-$$/proj/sess/ok-file" ] && [ -e "$DENY_TARGET" ]; then
  ok "mixed allow+deny call refuses the whole batch; nothing deleted"
else
  bad "multi-arg call was not all-or-nothing (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest6-$$" "/private/tmp/claude-selftest6b-$$" 2>/dev/null

# ── 7. idempotent: removing an already-absent allowed path is still success ─
ALREADY_GONE="/private/tmp/claude-selftest7-$$/proj/sess/gone"
OUT=$(run "$ALREADY_GONE" 2>&1); RC=$?
if [ "$RC" -eq 0 ]; then
  ok "already-absent path under an allowed prefix is a no-op success"
else
  bad "already-absent path should be a no-op success (rc=$RC): $OUT"
fi

# ── 8. unmatched path fails closed ──────────────────────────────────────────
UNMATCHED="$WORKDIR/nothing-in-policy-covers-this"
mkdir -p "$UNMATCHED"
OUT=$(run "$UNMATCHED" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -d "$UNMATCHED" ]; then
  ok "path matching neither allow nor deny fails closed, survives"
else
  bad "unmatched path should fail closed (rc=$RC): $OUT"
fi

# ── 9. --check classifies without deleting ──────────────────────────────────
mkdir -p "/private/tmp/claude-selftest9-$$/proj/sess"
OUT=$(run --check "/private/tmp/claude-selftest9-$$/proj/sess" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -e "/private/tmp/claude-selftest9-$$/proj/sess" ]; then
  ok "--check reports allow (exit 0) without deleting"
else
  bad "--check should classify without deleting (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest9-$$" 2>/dev/null

# ── 10. non-regression: fake-HOME rules also work (~/.cache, CloudStorage,
# ── ~/gt/<rig>/shared/data) ─────────────────────────────────────────────────
mkdir -p "$FAKE_HOME/.cache/some-tool"
echo x > "$FAKE_HOME/.cache/some-tool/blob"
OUT=$(run "$FAKE_HOME/.cache/some-tool" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$FAKE_HOME/.cache/some-tool" ]; then
  ok "~/.cache/** allowed and removed"
else
  bad "~/.cache/** should be allowed (rc=$RC): $OUT"
fi

mkdir -p "$FAKE_HOME/Library/CloudStorage/GoogleDrive-athos/My Drive/doc"
OUT=$(run "$FAKE_HOME/Library/CloudStorage/GoogleDrive-athos" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$FAKE_HOME/Library/CloudStorage/GoogleDrive-athos/My Drive/doc" ]; then
  ok "~/Library/CloudStorage/** refused, survives"
else
  bad "~/Library/CloudStorage/** should be refused (rc=$RC): $OUT"
fi

mkdir -p "$FAKE_HOME/gt/whatsapp_automation/shared/data"
echo x > "$FAKE_HOME/gt/whatsapp_automation/shared/data/prod.db"
OUT=$(run "$FAKE_HOME/gt/whatsapp_automation/shared/data" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "$FAKE_HOME/gt/whatsapp_automation/shared/data/prod.db" ]; then
  ok "~/gt/<rig>/shared/data/** refused, survives"
else
  bad "~/gt/<rig>/shared/data/** should be refused (rc=$RC): $OUT"
fi

# ── 11. symlink that resolves to ANOTHER allowed location: deletion must
# ── remove the symlink pointer, never the real target it points at ─────────
mkdir -p "$FAKE_HOME/.cache/real-target"
echo precious > "$FAKE_HOME/.cache/real-target/data"
mkdir -p "/private/tmp/claude-selftest11-$$"
ln -s "$FAKE_HOME/.cache/real-target" "/private/tmp/claude-selftest11-$$/link-to-other-allowed"
OUT=$(run "/private/tmp/claude-selftest11-$$/link-to-other-allowed" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "/private/tmp/claude-selftest11-$$/link-to-other-allowed" ] && [ -e "$FAKE_HOME/.cache/real-target/data" ]; then
  ok "symlink to another allowed location: only the pointer is removed, real target untouched"
else
  bad "symlink deletion should remove only the pointer, not dereference into the target (rc=$RC): $OUT — target present=$([ -e "$FAKE_HOME/.cache/real-target/data" ] && echo yes || echo no)"
fi
rm -rf "/private/tmp/claude-selftest11-$$" 2>/dev/null

# ── 12. a partial removal failure is reported, never silently reported as
# ── success (the exact swallow that ignore_errors=True would produce) ──────
PARTIAL="/private/tmp/claude-selftest12-$$/proj/sess/locked-dir"
mkdir -p "$PARTIAL"
echo x > "$PARTIAL/stuck-file"
chmod 555 "$PARTIAL"
OUT=$(run "/private/tmp/claude-selftest12-$$/proj/sess" 2>&1); RC=$?
chmod 755 "$PARTIAL"
if [ "$RC" -eq 3 ] && [ -e "$PARTIAL/stuck-file" ]; then
  ok "partial removal failure is reported (exit 3), not silently swallowed as success"
else
  bad "a removal that partially fails must not report exit 0 (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest12-$$" 2>/dev/null

# ── 13. relative path refused even when CWD sits inside an allowed tree —
# ── CWD must never influence a deletion decision (ga-gkap9p gate-fix 2:
# ── classify() used to realpath() a relative argument against the process's
# ── CWD and check the SAME resolved path against policy, so any relative
# ── argument typed while sitting in an allowed scratchpad silently inherited
# ── an ALLOW verdict regardless of what it actually named) ─────────────────
mkdir -p "/private/tmp/claude-selftest13-$$/proj/sess/sub"
echo important > "/private/tmp/claude-selftest13-$$/proj/sess/sub/file.txt"
OUT=$(cd "/private/tmp/claude-selftest13-$$/proj/sess" && HOME="$FAKE_HOME" python3 "$SCRIPT" "sub" 2>&1); RC=$?
if [ "$RC" -eq 2 ] && [ -e "/private/tmp/claude-selftest13-$$/proj/sess/sub/file.txt" ]; then
  ok "relative path refused even though CWD is inside an allowed scratchpad; survives"
else
  bad "relative path should be refused regardless of CWD (rc=$RC): $OUT"
fi
rm -rf "/private/tmp/claude-selftest13-$$" 2>/dev/null

# ── 14. bytecode under crew/ (ga-0z7kdz): the ONE exception to the crew deny ──
# crew/ holds undelivered work, so safe-clean refused everything in it - including the Python bytecode
# that grew to 1.45GB there and had to be deleted by hand. Only a .pyc FILE directly inside a
# __pycache__ directory under crew/ is exempt; everything next to it, around it and above it still is not.
# Outside every other allow rule on purpose ($WORKDIR is a plain mktemp dir), so a verdict of ALLOW can
# only come from the new rule.
CREW14="$WORKDIR/rig14/crew/thies"
mkdir -p "$CREW14/tests/__pycache__"
echo "def f(): pass" > "$CREW14/tests/a.py"
echo bytecode > "$CREW14/tests/__pycache__/a.cpython-311.pyc"
echo notbytecode > "$CREW14/tests/__pycache__/cache.nbi"
echo "Makefile body" > "$CREW14/Makefile"
echo legacy > "$CREW14/tests/legacy.pyc"

OUT=$(run --check "$CREW14/tests/__pycache__/a.cpython-311.pyc" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -e "$CREW14/tests/__pycache__/a.cpython-311.pyc" ] && echo "$OUT" | grep -q "regenerated by the next import"; then
  ok "crew bytecode: --check allows crew/**/__pycache__/*.pyc, says why, and deletes nothing"
else
  bad "crew bytecode: --check should allow the .pyc (rc=$RC): $OUT"
fi
OUT=$(run "$CREW14/tests/__pycache__/a.cpython-311.pyc" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$CREW14/tests/__pycache__/a.cpython-311.pyc" ] \
   && [ -e "$CREW14/tests/a.py" ] && [ -e "$CREW14/tests/__pycache__/cache.nbi" ] && [ -e "$CREW14/Makefile" ]; then
  ok "crew bytecode: the .pyc is removed (exit 0) and the .py, the .nbi and the extensionless file next to it survive"
else
  bad "crew bytecode: removal of the .pyc went wrong (rc=$RC): $OUT"
fi
OUT=$(run "$CREW14/tests/__pycache__/a.cpython-311.pyc" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "crew bytecode: removing an already-absent .pyc is the idempotent no-op it always was (exit 0)" || bad "crew bytecode: absent .pyc should be a no-op (rc=$RC): $OUT"

# What the exception must NOT open.
refused14() { # <label> <path...> ; every path must survive and the exit code must be 2
  local label="$1"; shift
  local out rc p gone=""
  out=$(run "$@" 2>&1); rc=$?
  for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] || gone="$gone $p"; done
  if [ "$rc" -eq 2 ] && [ -z "$gone" ]; then ok "crew bytecode: $label refused (exit 2), survives"; else bad "crew bytecode: $label should be refused and preserved (rc=$rc, gone:$gone): $out"; fi
}
refused14 "a .py next to the bytecode" "$CREW14/tests/a.py"
refused14 "a file with no extension" "$CREW14/Makefile"
refused14 "a non-bytecode file inside __pycache__ (numba .nbi)" "$CREW14/tests/__pycache__/cache.nbi"
refused14 "a legacy .pyc outside __pycache__" "$CREW14/tests/legacy.pyc"
refused14 "the __pycache__ directory itself" "$CREW14/tests/__pycache__"
refused14 "the crew directory" "$WORKDIR/rig14/crew"

mkdir -p "$CREW14/tests/__pycache__/dir.pyc"
echo precious > "$CREW14/tests/__pycache__/dir.pyc/inside.txt"
refused14 "a DIRECTORY named like a .pyc" "$CREW14/tests/__pycache__/dir.pyc"

mkdir -p "$CREW14/tests/foo__pycache__" && echo x > "$CREW14/tests/foo__pycache__/z.pyc"
refused14 "a .pyc whose parent only ENDS in __pycache__" "$CREW14/tests/foo__pycache__/z.pyc"

# the other protected components still win over the exemption
for prot in .git .beads .dolt .gc-worktrees; do
  mkdir -p "$WORKDIR/rig14/crew/p/$prot/x/__pycache__"
  echo bytecode > "$WORKDIR/rig14/crew/p/$prot/x/__pycache__/b.pyc"
  refused14 "a crew .pyc that is ALSO under $prot" "$WORKDIR/rig14/crew/p/$prot/x/__pycache__/b.pyc"
done

# a symlink named *.pyc is judged by what it points at
ln -s "../a.py" "$CREW14/tests/__pycache__/link.pyc"
refused14 "a .pyc symlink that points at a .py in crew" "$CREW14/tests/__pycache__/link.pyc"
[ -e "$CREW14/tests/a.py" ] && ok "crew bytecode: …and the .py it pointed at is untouched" || bad "crew bytecode: the symlink target was deleted"

# all-or-nothing: an allowed .pyc together with a refused .py removes neither
echo bytecode > "$CREW14/tests/__pycache__/b.cpython-311.pyc"
refused14 "a mix of an allowed .pyc and a .py (all-or-nothing)" "$CREW14/tests/__pycache__/b.cpython-311.pyc" "$CREW14/tests/a.py"

# --help describes the exception from the same table the code reads
HELP=$(run --help 2>&1)
if echo "$HELP" | grep -q "crew/\*\*/__pycache__/\*.pyc" && echo "$HELP" | grep -q "EXCEPT"; then
  ok "crew bytecode: --help lists the exception under both ALLOW and the crew DENY"
else
  bad "crew bytecode: --help does not describe the exception"
fi
rm -rf "$WORKDIR/rig14" 2>/dev/null

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
