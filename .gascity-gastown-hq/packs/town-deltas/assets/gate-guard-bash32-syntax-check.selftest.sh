#!/usr/bin/env bash
# gate-guard-bash32-syntax-check.selftest.sh — Proves the ga-7dx2vw fix:
# quality-gate-guard.sh's Step 5b-pre3 refuses, at SUBMISSION time, any
# branch that changes a .sh file under packs/town-deltas/assets/ or
# scripts/ which does not parse under the REAL /bin/bash 3.2 interpreter
# these scripts are actually launchd-invoked with.
#
# INCIDENT THIS CLOSES: ga-6aj348 (00d526a76) passed reviewer verdicts and
# whatever ran under the PATH's Homebrew bash 5.3, but broke quality-gate-
# dispatcher.sh's own parse under /bin/bash 3.2 the moment it was merged and
# a sweep tried to spawn a reviewer — the gate itself was the broken
# component, 21 markers queued (incl. a P0) for 3h until a human-triggered
# emergency revert (79392548f) landed straight to main. Root cause (measured
# directly on THIS machine's two real bash binaries, both invoked below, and
# re-measured in the gate-fix pass — an earlier version of this header and of
# the refusal text blamed the position of `esac`, which is WRONG): a `case`
# whose patterns are NOT parenthesized, inside a `$( ... )` command
# substitution. /bin/bash (3.2.57 on macOS) rejects it at the first `;;`
# ("syntax error near unexpected token `;;'") wherever `esac` and the closing
# `)` sit — esac on its own line fails too. It parses with a LEADING paren on
# every pattern, `$(case $x in (a) ...;; (*) ...;; esac)`, or with the case
# moved out of the substitution. The PATH's Homebrew bash (5.x) parses all of
# them. shellcheck -s bash does not catch it either — it is a raw bash-3.2
# PARSER limitation, not a shellcheck-recognized anti-pattern.
#
# Four layers, matching this codebase's own established convention (see
# gate-guard-ab-base-test-check.selftest.sh, the sibling this file copies
# its shape from):
#   0. Confirms the fixtures actually reproduce the divergence on THIS
#      machine's real /bin/bash vs the PATH bash — and that the remedy the
#      refusal text recommends really does parse — without this, the rest of
#      the test would be exercising fixtures that prove nothing.
#   1. Pure-function unit tests of gate_bash32_verdict, run under the real
#      /bin/bash 3.2 (the interpreter the guard actually runs under).
#   2. The LIVE Step 5b-pre3 block — extracted verbatim from the guard between
#      its SELFTEST-EXTRACT sentinels and executed under /bin/bash 3.2 against
#      a real git repo with an origin remote (only log/err/set_gate_status/bd
#      are stubbed). Not a replica: an earlier revision re-implemented the
#      block here, which is why it passed while the live code had defects.
#      Covers: bad add (refused), clean add (proceeds), no .sh touched, bad
#      file outside the protected trees, missing branch, a RENAMED-and-edited
#      bad file (refused), a non-ASCII path (refused), `git diff` failing (must
#      be nao-consegui-medir, never sem-sh-alterado), a failed fetch with stale
#      refs (must not measure the stale commit), and that every verdict leaves
#      a log line + marker label so coverage can be audited afterwards.
#   3. Drift guards on the live script — placement, wiring, ordering.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
[ -x /bin/bash ] || { echo "FATAL: /bin/bash missing — this selftest exists to run under the real 3.2"; exit 1; }
bash -n "$GUARD" && ok "guard passes bash -n (PATH bash) syntax check" || bad "guard has syntax errors under PATH bash"
/bin/bash -n "$GUARD" && ok "guard passes /bin/bash -n (the real 3.2 interpreter) syntax check — this fix must not itself repeat ga-6aj348" \
  || bad "REGRESSION: guard.sh itself fails to parse under /bin/bash 3.2 — this fix would BE the next ga-6aj348"

# ── 0. Fixture sanity: does the case-in-$() construct actually diverge here? ──
echo "── 0. fixture sanity: bash-3.2-vs-5.x divergence reproduces on THIS machine ──"

FIXTURE_TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-b32-fixture.XXXXXX")"
BAD_FIXTURE="$FIXTURE_TMPD/bad.sh"
BAD_NEWLINE_FIXTURE="$FIXTURE_TMPD/bad-newline.sh"
GOOD_FIXTURE="$FIXTURE_TMPD/good.sh"
GOOD_PAREN_FIXTURE="$FIXTURE_TMPD/good-paren.sh"
GOOD_IF_FIXTURE="$FIXTURE_TMPD/good-if.sh"

cat > "$BAD_FIXTURE" <<'BADEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  b) echo B;;
  *) echo Z;; esac)
echo "$result"
BADEOF

# The earlier (WRONG) remedy: put esac on its own line and the closing paren
# on the next one. It must STILL be rejected — if this ever starts parsing on
# 3.2, the refusal text's advice needs revisiting.
cat > "$BAD_NEWLINE_FIXTURE" <<'BADNLEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  *) echo Z;;
esac
)
echo "$result"
BADNLEOF

cat > "$GOOD_FIXTURE" <<'GOODEOF'
#!/usr/bin/env bash
x="a"
case "$x" in
  a) result="A" ;;
  b) result="B" ;;
  *) result="Z" ;;
esac
echo "$result"
GOODEOF

# The remedy the refusal text recommends: leading paren on every pattern.
cat > "$GOOD_PAREN_FIXTURE" <<'GOODPEOF'
#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  (a) echo A;;
  (b) echo B;;
  (*) echo Z;;
esac)
echo "$result"
GOODPEOF

cat > "$GOOD_IF_FIXTURE" <<'GOODIFEOF'
#!/usr/bin/env bash
x="a"
result=$(if [ "$x" = a ]; then echo A; else echo Z; fi)
echo "$result"
GOODIFEOF

if /bin/bash -n "$BAD_FIXTURE" >/dev/null 2>&1; then
  bad "FATAL: fixture assumption broken — /bin/bash 3.2 on this machine accepts the case-in-\$() construct (expected it to reject). Cannot proceed; find a different reproducer."
  echo "  PASS=$PASS  FAIL=$FAIL"; echo "  RESULT: FAIL"; exit 1
else
  ok "/bin/bash 3.2 REJECTS the case-in-\$() fixture, as the incident describes"
fi

if bash -n "$BAD_FIXTURE" >/dev/null 2>&1; then
  ok "PATH bash (Homebrew, newer) ACCEPTS the same fixture — this is exactly how it slipped through ga-6aj348's own review/tests"
else
  bad "fixture assumption broken — PATH bash also rejects it; the divergence this bug is about does not reproduce with this fixture"
fi

/bin/bash -n "$BAD_NEWLINE_FIXTURE" >/dev/null 2>&1 \
  && bad "REGRESSION of the corrected root cause: esac on its own line + closing paren on the next now PARSES on /bin/bash 3.2 — the position of esac was the earlier (wrong) explanation, re-check the refusal text" \
  || ok "/bin/bash 3.2 still REJECTS the case-in-\$() with esac/paren on their own lines — the position of esac is NOT the cause (the earlier text's advice would not have remediated)"

/bin/bash -n "$GOOD_PAREN_FIXTURE" >/dev/null 2>&1 \
  && ok "leading-paren patterns inside \$( ) parse clean under /bin/bash 3.2 — the remedy the refusal text recommends actually works" \
  || bad "the leading-paren remedy does NOT parse under /bin/bash 3.2 — the refusal text would send submitters to another rejection"

/bin/bash -n "$GOOD_IF_FIXTURE" >/dev/null 2>&1 \
  && ok "if/else inside \$( ) parses clean under /bin/bash 3.2 (the other remedy named in the refusal text)" \
  || bad "if/else inside \$( ) does not parse under /bin/bash 3.2 — fixture or advice is wrong"

/bin/bash -n "$GOOD_FIXTURE" >/dev/null 2>&1 \
  && ok "control fixture (plain case...esac, not inside \$()) parses clean under /bin/bash 3.2" \
  || bad "control fixture unexpectedly fails under /bin/bash 3.2 — fixture itself is broken"

rm -f "$BAD_FIXTURE" "$BAD_NEWLINE_FIXTURE" "$GOOD_FIXTURE" "$GOOD_PAREN_FIXTURE" "$GOOD_IF_FIXTURE"
rmdir "$FIXTURE_TMPD" 2>/dev/null || true

# ── 1. Pure function: gate_bash32_verdict (under the REAL /bin/bash 3.2) ──────
echo "── 1. pure function unit tests (each call is a /bin/bash 3.2 subprocess) ──"

# Sourcing the guard in LIB_ONLY mode defines the pure helpers without running
# the sweep. Done in a /bin/bash subprocess per call so the function is
# exercised by the interpreter it actually runs under, and so the guard's
# `set -euo pipefail` cannot leak into this harness.
verdict() {
  /bin/bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; shift; gate_bash32_verdict "$@"' _ "$GUARD" "$@" 2>/dev/null
}

if [ -z "$(verdict 0 0 0)" ]; then
  bad "FATAL: gate_bash32_verdict not defined / silent after LIB_ONLY sourcing under /bin/bash — cannot continue section 1"
else
  eq "no .sh changed (0,0,0) -> sem-sh-alterado" \
    "$(verdict 0 0 0)" "sem-sh-alterado"

  eq "unparseable changed count (empty) -> nao-consegui-medir, NOT sem-sh-alterado (the erro==vazio collapse this whole convention exists to catch)" \
    "$(verdict "" 0 0)" "nao-consegui-medir"

  eq "unparseable changed count (non-numeric) -> nao-consegui-medir" \
    "$(verdict "abc" 0 0)" "nao-consegui-medir"

  eq "1 file, fully checked, parses clean -> bash32-ok" \
    "$(verdict 1 1 0)" "bash32-ok"

  eq "1 file, fully checked, fails to parse -> bash32-fail (the block case)" \
    "$(verdict 1 1 1)" "bash32-fail"

  eq "3 files, all checked, all clean -> bash32-ok" \
    "$(verdict 3 3 0)" "bash32-ok"

  eq "3 files, all checked, only ONE fails -> bash32-fail (one genuine syntax failure is enough to block)" \
    "$(verdict 3 3 1)" "bash32-fail"

  eq "2 changed but only 1 checked (extraction failure), none failed -> nao-consegui-medir (partial measurement is never treated as proof)" \
    "$(verdict 2 1 0)" "nao-consegui-medir"

  eq "2 changed, 1 checked, that 1 FAILED -> bash32-fail (a CONFIRMED failure blocks even when another file could not be measured)" \
    "$(verdict 2 1 1)" "bash32-fail"

  eq "2 files, both checked, both fail -> bash32-fail" \
    "$(verdict 2 2 2)" "bash32-fail"

  # gate-fix 1: the changed-file LIST itself could not be read.
  eq "list unread (0,0,0,1) -> nao-consegui-medir, NEVER sem-sh-alterado (the third-state collapse the gate reviewer reproduced)" \
    "$(verdict 0 0 0 1)" "nao-consegui-medir"

  eq "explicit 4th arg 0 (list was read, nothing changed) -> sem-sh-alterado" \
    "$(verdict 0 0 0 0)" "sem-sh-alterado"

  eq "explicit EMPTY 4th arg -> nao-consegui-medir (only the exact value 0 means the list was read)" \
    "$(verdict 0 0 0 "")" "nao-consegui-medir"

  eq "list unread even though counts look clean (1,1,0,1) -> nao-consegui-medir" \
    "$(verdict 1 1 0 1)" "nao-consegui-medir"

  # A garbled <failed> must be 'don't know', not 0 (which would read as bash32-ok).
  eq "garbled failed count (1,1,abc) -> nao-consegui-medir, NOT bash32-ok" \
    "$(verdict 1 1 abc)" "nao-consegui-medir"

  eq "empty failed count (1,1,'') -> nao-consegui-medir, NOT bash32-ok" \
    "$(verdict 1 1 "")" "nao-consegui-medir"

  eq "garbled checked count with changed=0 (0,abc,0) -> nao-consegui-medir, NOT sem-sh-alterado" \
    "$(verdict 0 abc 0)" "nao-consegui-medir"
fi

# gate_bash32_parse_class: what ONE `/bin/bash -n` exit status means. Measured
# on this machine's real 3.2.57 (2 = syntax error, 0 = clean, 126 = unreadable,
# 127 = missing); only 0 and 2 are verdicts about the FILE.
parse_class() {
  /bin/bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; shift; gate_bash32_parse_class "$@"' _ "$GUARD" "$@" 2>/dev/null
}
_PC_SYN=$(printf 'x=$(case $1 in a) echo A;; *) echo Z;; esac)\n' > "${TMPDIR:-/tmp}/gate-b32-pc.$$.sh"; /bin/bash -n "${TMPDIR:-/tmp}/gate-b32-pc.$$.sh" >/dev/null 2>&1; echo $?)
rm -f "${TMPDIR:-/tmp}/gate-b32-pc.$$.sh"
eq "sanity: the real /bin/bash -n exits 2 on a syntax error (the status the classifier keys on)" "$_PC_SYN" "2"
eq "parse_class 0 (clean parse) -> ok"                              "$(parse_class 0)"   "ok"
eq "parse_class 2 (syntax error) -> fail"                           "$(parse_class 2)"   "fail"
eq "parse_class 126 (file unreadable / not executable) -> unmeasured, NOT fail" "$(parse_class 126)" "unmeasured"
eq "parse_class 127 (file missing) -> unmeasured, NOT fail"         "$(parse_class 127)" "unmeasured"
eq "parse_class 137 (parser killed, e.g. under memory pressure) -> unmeasured, NOT fail" "$(parse_class 137)" "unmeasured"
eq "parse_class 1 (any other non-zero) -> unmeasured"               "$(parse_class 1)"   "unmeasured"
eq "parse_class '' (no status at all) -> unmeasured, NOT ok"        "$(parse_class "")"  "unmeasured"
eq "parse_class garbled -> unmeasured"                              "$(parse_class abc)" "unmeasured"

# ── 2. The LIVE block, extracted verbatim, against a real git repo ────────────
echo "── 2. live Step 5b-pre3 block (extracted from the guard) under /bin/bash 3.2 + real git/origin ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-b32-selftest.XXXXXX")"
trap 'rm -rf "$TMPD"' EXIT

LIVE_BLOCK="$TMPD/live-block.sh"
sed -n '/^# SELFTEST-EXTRACT bash32-check: BEGIN$/,/^# SELFTEST-EXTRACT bash32-check: END$/p' "$GUARD" | sed '1d;$d' > "$LIVE_BLOCK"
if [ -s "$LIVE_BLOCK" ] && /bin/bash -n "$LIVE_BLOCK" 2>/dev/null; then
  ok "live block extracted from the guard ($(wc -l < "$LIVE_BLOCK" | tr -d ' ') lines) and parses under /bin/bash 3.2"
else
  bad "FATAL: could not extract a parseable live block between the SELFTEST-EXTRACT bash32-check sentinels — section 2 cannot run"
fi

# Driver: runs under the real 3.2, sources the guard in lib mode (so the pure
# helpers and the guard's own `set -euo pipefail` are live, exactly as in the
# sweep), stubs ONLY the side-effecting helpers, then sources the extracted
# block. `exit 1` in the block (the refusal) ends this process, like the sweep.
cat > "$TMPD/driver.sh" <<'DRIVEREOF'
#!/bin/bash
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
log() { printf 'LOG %s\n' "$*" >> "$CALLS"; }
err() { printf 'ERR %s\n' "$*" >> "$CALLS"; }
set_gate_status() { printf 'STATUS %s %s\n' "$1" "$2" >> "$CALLS"; }
bd() { printf 'BD %s\n' "$*" >> "$CALLS"; }
. "$BLOCK"
echo "BLOCK-FELL-THROUGH" >> "$CALLS"
DRIVEREOF

# PATH shim that makes `git ... diff ...` fail (rc 128) and delegates all else.
REAL_GIT="$(command -v git)"
mkdir -p "$TMPD/shim-diff-fails"
cat > "$TMPD/shim-diff-fails/git" <<SHIMEOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "diff" ]; then echo "fatal: simulated git diff failure" >&2; exit 128; fi
done
exec "$REAL_GIT" "\$@"
SHIMEOF
chmod +x "$TMPD/shim-diff-fails/git"

# PATH shim that makes `mktemp -d` (the scratch dir the extracted files go in)
# fail while plain `mktemp` (the changed-file list) still works: the list is
# read fine, but nothing can be extracted to parse.
REAL_MKTEMP="$(command -v mktemp)"
mkdir -p "$TMPD/shim-mktemp-d-fails"
cat > "$TMPD/shim-mktemp-d-fails/mktemp" <<SHIMEOF
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "-d" ]; then echo "mktemp: simulated failure" >&2; exit 1; fi
done
exec "$REAL_MKTEMP" "\$@"
SHIMEOF
chmod +x "$TMPD/shim-mktemp-d-fails/mktemp"

# ...and one that makes EVERY mktemp fail (no scratch file for the diff output).
mkdir -p "$TMPD/shim-mktemp-fails"
cat > "$TMPD/shim-mktemp-fails/mktemp" <<'SHIMEOF'
#!/bin/sh
echo "mktemp: simulated failure" >&2
exit 1
SHIMEOF
chmod +x "$TMPD/shim-mktemp-fails/mktemp"

ORIGIN_DIR="$TMPD/origin.git"
CLONE_DIR="$TMPD/rig-clone"

git init -q --bare "$ORIGIN_DIR"
git -C "$ORIGIN_DIR" symbolic-ref HEAD refs/heads/main

git init -q -b main "$TMPD/seed"
git -C "$TMPD/seed" config user.email "test@gascity.local"
git -C "$TMPD/seed" config user.name "Test"
mkdir -p "$TMPD/seed/packs/town-deltas/assets" "$TMPD/seed/scripts"
cat > "$TMPD/seed/packs/town-deltas/assets/existing.sh" <<'SEEDEOF'
#!/usr/bin/env bash
echo "existing, untouched"
SEEDEOF
# A longer file, so renaming it and appending a few lines stays well above
# git's rename-similarity threshold (git reports it as R, not D+A).
{
  echo '#!/usr/bin/env bash'
  for _i in $(seq 1 40); do echo "echo \"rename-me line $_i\""; done
} > "$TMPD/seed/packs/town-deltas/assets/rename-me.sh"
git -C "$TMPD/seed" add -A
git -C "$TMPD/seed" commit -q -m base
git -C "$TMPD/seed" remote add origin "$ORIGIN_DIR"
git -C "$TMPD/seed" push -q origin main

git clone -q "$ORIGIN_DIR" "$CLONE_DIR"
git -C "$CLONE_DIR" config user.email "test@gascity.local"
git -C "$CLONE_DIR" config user.name "Test"

BAD_BODY='#!/usr/bin/env bash
x="a"
result=$(case "$x" in
  a) echo A;;
  b) echo B;;
  *) echo Z;; esac)
echo "$result"'

# Branch A: introduces the bad construct under packs/town-deltas/assets/ —
# must be caught.
git -C "$CLONE_DIR" checkout -q -b feat/badsyntax
printf '%s\n' "$BAD_BODY" > "$CLONE_DIR/packs/town-deltas/assets/new-daemon.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: new daemon with a bash-3.2-incompatible construct"
git -C "$CLONE_DIR" push -q origin feat/badsyntax

# Branch B: clean .sh change under scripts/ — must proceed.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/goodsyntax
mkdir -p "$CLONE_DIR/scripts"
cat > "$CLONE_DIR/scripts/helper.sh" <<'GOODEOF'
#!/usr/bin/env bash
x="a"
case "$x" in
  a) result="A" ;;
  *) result="Z" ;;
esac
echo "$result"
GOODEOF
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: new helper script, clean bash-3.2 syntax"
git -C "$CLONE_DIR" push -q origin feat/goodsyntax

# Branch C: no .sh file touched at all — just docs.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/notouch
echo "notes" > "$CLONE_DIR/NOTES.md"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "docs: notes, no .sh files touched"
git -C "$CLONE_DIR" push -q origin feat/notouch

# Branch D: bad construct, but OUTSIDE both protected trees — must NOT be
# flagged (scope must not over-reach into every rig's own scripts).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/outofscope
mkdir -p "$CLONE_DIR/some/other/dir"
printf '%s\n' "$BAD_BODY" > "$CLONE_DIR/some/other/dir/unrelated.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: bad-syntax script outside the protected trees"
git -C "$CLONE_DIR" push -q origin feat/outofscope

# Branch E: an existing daemon script is RENAMED and edited to carry the bad
# construct (gate-fix 2: --diff-filter=AM used to skip renames entirely).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/renamedbad
git -C "$CLONE_DIR" mv packs/town-deltas/assets/rename-me.sh packs/town-deltas/assets/renamed.sh
printf '%s\n' "$BAD_BODY" >> "$CLONE_DIR/packs/town-deltas/assets/renamed.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "refactor: rename daemon script + add a bash-3.2-incompatible construct"
git -C "$CLONE_DIR" push -q origin feat/renamedbad
_RENAME_STATUS=$(git -C "$CLONE_DIR" diff -M --name-status main...feat/renamedbad | cut -c1)
eq "fixture sanity: git itself reports the renamed+edited file as R (so the rename scenario truly exercises rename handling)" "$_RENAME_STATUS" "R"

# Branch F: bad construct in a NON-ASCII path (gate-fix, medium finding:
# core.quotePath makes --name-only emit "scripts/caf\303\251.sh" with quotes).
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/unicodebad
UNI_NAME="caf$(printf '\303\251').sh"
mkdir -p "$CLONE_DIR/scripts"   # scripts/ has no tracked file on main, so it does not exist on this branch yet
printf '%s\n' "$BAD_BODY" > "$CLONE_DIR/scripts/$UNI_NAME"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "feat: bad-syntax script with a non-ASCII file name"
git -C "$CLONE_DIR" push -q origin feat/unicodebad
_QUOTED=$(git -C "$CLONE_DIR" diff --name-only main...feat/unicodebad -- scripts)
if [ -z "$_QUOTED" ]; then
  bad "FATAL fixture: the non-ASCII branch changed nothing under scripts/ — the unicode scenario below would be vacuous"
else
  case "$_QUOTED" in
    *'\303\251'*) ok "fixture sanity: git's default --name-only QUOTES the non-ASCII path ($_QUOTED) — the case a naive '\\.sh\$' filter silently drops" ;;
    *) ok "fixture sanity: the non-ASCII branch changed '$_QUOTED' under scripts/ (this git does not quote it by default; the scenario still runs)" ;;
  esac
fi

# Branch G (gate-fix 3, the reviewer's SURVIVING MUTATION): an EXISTING daemon
# script is edited IN PLACE into the bad construct — git status M, not A or R.
# This is the exact ga-6aj348 shape (that merge MODIFIED quality-gate-
# dispatcher.sh; it did not add a file). Every other refusal scenario in this
# file is an ADD or a RENAME, so changing the live block's --diff-filter=AM to
# =A left this whole selftest at 91/91 — the one shape the check exists for was
# the one shape nothing pinned.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/modifiedbad
printf '%s\n' "$BAD_BODY" >> "$CLONE_DIR/packs/town-deltas/assets/existing.sh"
git -C "$CLONE_DIR" add -A
git -C "$CLONE_DIR" commit -q -m "fix: edit an existing daemon script in place (adds a bash-3.2-incompatible construct)"
git -C "$CLONE_DIR" push -q origin feat/modifiedbad
_MOD_STATUS=$(git -C "$CLONE_DIR" diff --name-status main...feat/modifiedbad | cut -c1)
eq "fixture sanity: git reports the in-place edit as M (so this scenario truly exercises a MODIFIED file, not an add)" "$_MOD_STATUS" "M"

# Branch H (gate-fix 3, low finding): a path git DIFF lists but git SHOW cannot
# extract — a gitlink (mode 160000, i.e. a submodule entry) named *.sh. The file
# is counted as changed but can never be checked, so it must ALSO be counted as
# unrun: the verdict (nao-consegui-medir, because checked != changed) was already
# right, but the record used to read unrun=0.
git -C "$CLONE_DIR" checkout -q main
git -C "$CLONE_DIR" checkout -q -b feat/gitlinkfail
git -C "$CLONE_DIR" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,scripts/vendored.sh
git -C "$CLONE_DIR" commit -q -m "feat: a gitlink named vendored.sh (git show cannot extract it)"
git -C "$CLONE_DIR" push -q origin feat/gitlinkfail
_GL_LISTED=$(git -C "$CLONE_DIR" diff -z --name-only --no-renames --diff-filter=AM main...feat/gitlinkfail -- scripts | tr '\0' '\n')
_GL_SHOW_RC=0; git -C "$CLONE_DIR" show "feat/gitlinkfail:scripts/vendored.sh" >/dev/null 2>&1 || _GL_SHOW_RC=$?
if [ "$_GL_LISTED" = "scripts/vendored.sh" ] && [ "$_GL_SHOW_RC" -ne 0 ]; then
  ok "fixture sanity: git diff LISTS scripts/vendored.sh but git show cannot extract it (rc=$_GL_SHOW_RC) — the extraction-failure scenario below is real"
else
  bad "FATAL fixture: gitlink scenario is vacuous (listed='$_GL_LISTED' show_rc=$_GL_SHOW_RC)"
fi
git -C "$CLONE_DIR" checkout -q main

RIG_PATH="$TMPD/rig-registered-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH"
git -C "$RIG_PATH" config user.email "test@gascity.local"
git -C "$RIG_PATH" config user.name "Test"

# b32_run <rig_path> <branch> [<path_shim_dir>] — executes the live block via
# the driver under /bin/bash 3.2; sets R_* result variables.
R_RC=""; R_VERDICT=""; R_STATUS_ERR=""; R_FELL=""; R_LOGN=""; R_LOG=""; R_CALLS=""
b32_run() {
  local rig="$1" branch="$2" shim="${3:-}"
  local calls="$TMPD/calls.$RANDOM.$RANDOM"
  : > "$calls"
  local pathv="$PATH"
  [ -n "$shim" ] && pathv="$shim:$PATH"
  env PATH="$pathv" RIG_PATH="$rig" BEAD_ID="ga-selftest" BRANCH="$branch" \
      MARKER_ID="ga-marker-selftest" GC_CITY="/nonexistent-city" \
      GUARD="$GUARD" BLOCK="$LIVE_BLOCK" CALLS="$calls" \
      /bin/bash "$TMPD/driver.sh" >/dev/null 2>"$calls.stderr"
  R_RC=$?
  R_VERDICT=$(grep -o 'gate-bash32:[a-z0-9-]*' "$calls" | head -1 | cut -d: -f2)
  R_STATUS_ERR=$(grep -c '^STATUS ga-marker-selftest error' "$calls")
  R_FELL=$(grep -c '^BLOCK-FELL-THROUGH' "$calls")
  R_LOGN=$(grep -c '^LOG BASH32-CHECK' "$calls")
  R_LOG=$(grep '^LOG BASH32-CHECK' "$calls" | head -1)
  R_CALLS="$calls"
}

# --- refused: bad construct in a new file ---
b32_run "$RIG_PATH" feat/badsyntax
eq "live block: badsyntax (bad .sh under packs/town-deltas/assets/) -> bash32-fail" "$R_VERDICT" "bash32-fail"
eq "live block: badsyntax is REFUSED (exit 1, the block does not fall through to Step 7)" "$R_RC/$R_FELL" "1/0"
eq "live block: badsyntax marks the marker gate-status:error exactly once" "$R_STATUS_ERR" "1"
grep -q 'leading paren' "$R_CALLS" \
  && ok "live block: refusal text names the WORKING remedy (leading paren / move the case out)" \
  || bad "live block: refusal text does not mention the leading-paren remedy"
if grep -q 'directly abuts' "$R_CALLS"; then
  bad "live block: refusal text still carries the wrong 'esac directly abuts the closing paren' explanation"
else
  ok "live block: refusal text no longer blames esac abutting the closing paren"
fi
if grep -Eq 'new-daemon\.sh: (packs/[^ ]*)?new-daemon\.sh: line' "$R_CALLS"; then
  bad "live block: detail line prints the path twice ('path: path: line N')"
else
  ok "live block: detail line names the file once ('path: line N: ...')"
fi
grep -q 'new-daemon.sh: line' "$R_CALLS" \
  && ok "live block: detail line carries bash -n's own message for the failing file" \
  || bad "live block: detail line missing the bash -n message"
eq "live block: badsyntax leaves exactly one BASH32-CHECK audit log line" "$R_LOGN" "1"

# --- proceeds ---
b32_run "$RIG_PATH" feat/goodsyntax
eq "live block: goodsyntax (clean .sh under scripts/) -> bash32-ok, proceeds" "$R_VERDICT/$R_RC/$R_FELL/$R_STATUS_ERR" "bash32-ok/0/1/0"

b32_run "$RIG_PATH" feat/notouch
eq "live block: notouch (no .sh touched) -> sem-sh-alterado, proceeds" "$R_VERDICT/$R_RC/$R_FELL/$R_STATUS_ERR" "sem-sh-alterado/0/1/0"
eq "live block: sem-sh-alterado STILL leaves an audit log line + marker label (it used to leave no trace)" "$R_LOGN" "1"
case "$R_LOG" in
  *"changed=0"*"list_unread=0"*) ok "live block: the sem-sh-alterado log line records changed=0 list_unread=0 (a CONFIRMED zero, distinguishable from an unread list)" ;;
  *) bad "live block: sem-sh-alterado log line is not the expected confirmed-zero record: '$R_LOG'" ;;
esac

b32_run "$RIG_PATH" feat/outofscope
eq "live block: outofscope (bad syntax OUTSIDE both protected trees) -> sem-sh-alterado (scope does not over-reach)" "$R_VERDICT/$R_RC" "sem-sh-alterado/0"

b32_run "$RIG_PATH" feat/does-not-exist
eq "live block: nonexistent branch (fetch/rev-parse fails) -> nao-consegui-medir, fails open, never crashes" "$R_VERDICT/$R_RC/$R_FELL" "nao-consegui-medir/0/1"
case "$R_LOG" in
  *"refs_resolved=0"*) ok "live block: the unmeasurable record says refs_resolved=0" ;;
  *) bad "live block: nonexistent-branch log line does not say refs_resolved=0: '$R_LOG'" ;;
esac

# --- gate-fix 2: a renamed-and-edited file must be scanned ---
b32_run "$RIG_PATH" feat/renamedbad
eq "live block: renamedbad (git mv + bad construct, reported as R by git) -> bash32-fail, refused (was a silent bypass: AM excluded R)" "$R_VERDICT/$R_RC" "bash32-fail/1"

# --- non-ASCII path must not be silently dropped ---
b32_run "$RIG_PATH" feat/unicodebad
eq "live block: unicodebad (bad .sh in a non-ASCII path) -> bash32-fail, refused (was silently dropped by the quoted-path/\\.sh\$ filter)" "$R_VERDICT/$R_RC" "bash32-fail/1"

# --- gate-fix 3: an existing script edited IN PLACE (status M) must be scanned ---
b32_run "$RIG_PATH" feat/modifiedbad
eq "live block: modifiedbad (existing .sh edited in place into the bad construct, git status M — the ga-6aj348 shape) -> bash32-fail, refused (--diff-filter=A would silently skip it)" "$R_VERDICT/$R_RC" "bash32-fail/1"
case "$R_LOG" in
  *"changed=1 checked=1 failed=1"*) ok "live block: the in-place edit is counted, checked and failed (changed=1 checked=1 failed=1)" ;;
  *) bad "live block: modifiedbad record is not changed=1 checked=1 failed=1: '$R_LOG'" ;;
esac

# --- gate-fix 3: git show cannot extract a listed file -> counted as UNRUN, never a silent gap ---
b32_run "$RIG_PATH" feat/gitlinkfail
eq "live block: gitlinkfail (git diff lists scripts/vendored.sh, git show cannot extract it) -> nao-consegui-medir, proceeds (not bash32-ok, not sem-sh-alterado)" "$R_VERDICT/$R_RC/$R_STATUS_ERR" "nao-consegui-medir/0/0"
case "$R_LOG" in
  *"changed=1 checked=0"*"unrun=1"*"list_unread=0"*) ok "live block: the extraction failure is recorded as changed=1 checked=0 unrun=1 (the record says WHY it is unmeasured; it used to read unrun=0)" ;;
  *) bad "live block: extraction failure is not recorded as unrun=1: '$R_LOG'" ;;
esac

# --- gate-fix 1: a FAILED git diff must be nao-consegui-medir, and logged ---
b32_run "$RIG_PATH" feat/badsyntax "$TMPD/shim-diff-fails"
eq "live block: git diff FAILS on a branch that contains a bad .sh -> nao-consegui-medir, NEVER sem-sh-alterado (the third-state defect)" "$R_VERDICT" "nao-consegui-medir"
eq "live block: a failed diff fails OPEN (proceeds, exit 0) — invisible is the defect, not open" "$R_RC/$R_FELL/$R_STATUS_ERR" "0/1/0"
case "$R_LOG" in
  *"list_unread=1"*) ok "live block: a failed diff is LOGGED with list_unread=1 (visible, not silent)" ;;
  *) bad "live block: failed diff left no list_unread=1 record: '$R_LOG'" ;;
esac
grep -q 'could not fully measure' "$R_CALLS" \
  && ok "live block: the human-readable 'could not fully measure' line is emitted for the failed diff" \
  || bad "live block: no 'could not fully measure' line for the failed diff"

# --- no scratch dir: the list is read, files counted as changed, none checked ---
b32_run "$RIG_PATH" feat/badsyntax "$TMPD/shim-mktemp-d-fails"
eq "live block: mktemp -d fails (no place to extract to) on a branch with a bad .sh -> nao-consegui-medir, not bash32-ok / sem-sh-alterado" "$R_VERDICT/$R_RC/$R_STATUS_ERR" "nao-consegui-medir/0/0"
case "$R_LOG" in
  *"changed=1 checked=0"*"list_unread=0"*) ok "live block: the record shows the file was COUNTED as changed but never checked (changed=1 checked=0 list_unread=0)" ;;
  *) bad "live block: no-scratch-dir record is not 'changed=1 checked=0 list_unread=0': '$R_LOG'" ;;
esac
case "$R_LOG" in
  *"unrun=1"*) ok "live block: the no-scratch-dir file is ALSO counted as unrun=1 (it used to read unrun=0 while checked < changed)" ;;
  *) bad "live block: no-scratch-dir record does not say unrun=1: '$R_LOG'" ;;
esac

# --- no scratch file for the diff output: the list itself is unknown ---
b32_run "$RIG_PATH" feat/badsyntax "$TMPD/shim-mktemp-fails"
eq "live block: every mktemp fails (no file for the diff output) -> nao-consegui-medir with list_unread=1, NEVER sem-sh-alterado" "$R_VERDICT/$R_RC" "nao-consegui-medir/0"
case "$R_LOG" in
  *"list_unread=1"*) ok "live block: the no-scratch-file case is logged with list_unread=1" ;;
  *) bad "live block: no-scratch-file case left no list_unread=1 record: '$R_LOG'" ;;
esac

# --- a failed fetch must not let STALE refs be measured as if they were current ---
RIG_PATH2="$TMPD/rig-stale-copy"
git clone -q "$ORIGIN_DIR" "$RIG_PATH2"
git -C "$RIG_PATH2" config user.email "test@gascity.local"
git -C "$RIG_PATH2" config user.name "Test"
b32_run "$RIG_PATH2" feat/goodsyntax
eq "live block: (setup) fresh clone measures goodsyntax -> bash32-ok" "$R_VERDICT" "bash32-ok"
git -C "$RIG_PATH2" remote set-url origin "$TMPD/origin-is-gone.git"
b32_run "$RIG_PATH2" feat/goodsyntax
eq "live block: fetch now FAILS but the old origin/feat/goodsyntax ref still resolves -> nao-consegui-medir (does not report bash32-ok on a possibly stale commit)" "$R_VERDICT/$R_RC" "nao-consegui-medir/0"
case "$R_LOG" in
  *"list_unread=1"*) ok "live block: the failed-fetch case is logged with list_unread=1" ;;
  *) bad "live block: failed fetch left no list_unread=1 record: '$R_LOG'" ;;
esac

# --- production topology: RIG_PATH is a SUBDIR of the git toplevel ---
# (the registered HQ rig path is <repo>/.gascity-gastown-hq, a tracked subdir
# with no .git of its own; every scenario above uses a flat repo, so without
# this the exact layout the guard runs in would be untested.)
git init -q --bare "$TMPD/topo-origin.git"
git -C "$TMPD/topo-origin.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$TMPD/topo-seed"
git -C "$TMPD/topo-seed" config user.email "test@gascity.local"
git -C "$TMPD/topo-seed" config user.name "Test"
mkdir -p "$TMPD/topo-seed/.gascity-gastown-hq/packs/town-deltas/assets" "$TMPD/topo-seed/docs/tools"
printf '#!/usr/bin/env bash\necho base\n' > "$TMPD/topo-seed/.gascity-gastown-hq/packs/town-deltas/assets/base.sh"
git -C "$TMPD/topo-seed" add -A
git -C "$TMPD/topo-seed" commit -q -m base
git -C "$TMPD/topo-seed" remote add origin "$TMPD/topo-origin.git"
git -C "$TMPD/topo-seed" push -q origin main
git clone -q "$TMPD/topo-origin.git" "$TMPD/topo-clone"
git -C "$TMPD/topo-clone" config user.email "test@gascity.local"
git -C "$TMPD/topo-clone" config user.name "Test"
git -C "$TMPD/topo-clone" checkout -q -b topo/bad
printf '%s\n' "$BAD_BODY" > "$TMPD/topo-clone/.gascity-gastown-hq/packs/town-deltas/assets/daemon.sh"
git -C "$TMPD/topo-clone" add -A
git -C "$TMPD/topo-clone" commit -q -m "feat: bad .sh under the rig subdir"
git -C "$TMPD/topo-clone" push -q origin topo/bad
git -C "$TMPD/topo-clone" checkout -q main
git -C "$TMPD/topo-clone" checkout -q -b topo/outside
printf '%s\n' "$BAD_BODY" > "$TMPD/topo-clone/docs/tools/x.sh"
git -C "$TMPD/topo-clone" add -A
git -C "$TMPD/topo-clone" commit -q -m "feat: bad .sh in the toplevel but OUTSIDE the rig subdir"
git -C "$TMPD/topo-clone" push -q origin topo/outside
TOPO_RIG="$TMPD/topo-clone/.gascity-gastown-hq"

b32_run "$TOPO_RIG" topo/bad
eq "live block, RIG_PATH=<toplevel>/.gascity-gastown-hq: a bad .sh under the rig's packs/town-deltas/assets -> bash32-fail, refused (root-relative paths from git diff + git show work from a subdir)" "$R_VERDICT/$R_RC" "bash32-fail/1"
b32_run "$TOPO_RIG" topo/outside
eq "live block, subdir topology: a bad .sh in the toplevel but OUTSIDE the rig subdir -> sem-sh-alterado (the pathspec is relative to the rig path)" "$R_VERDICT/$R_RC" "sem-sh-alterado/0"

_WT_COUNT=$(git -C "$RIG_PATH" worktree list 2>/dev/null | wc -l | tr -d ' ')
eq "the check creates no linked worktrees in the rig repo (only the main worktree is listed)" "$_WT_COUNT" "1"
_TMP_LEFTOVER=$(ls -d "${TMPDIR:-/tmp}"/gate-b32-list-* "${TMPDIR:-/tmp}"/gate-b32-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9] 2>/dev/null | wc -l | tr -d ' ')
eq "the check cleans up its own scratch list/worktree dirs" "$_TMP_LEFTOVER" "0"

rm -rf "$TMPD"
trap - EXIT

# ── 3. DRIFT GUARDS on the live script ────────────────────────────────────────
echo "── 3. drift guards: placement, wiring, ordering ──"

CUTOFF_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY:-' "$GUARD" | head -1 | cut -d: -f1)
VERDICT_DEF_LINE=$(grep -n '^gate_bash32_verdict() {' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$VERDICT_DEF_LINE" ] && [ -n "$CUTOFF_LINE" ] && [ "$VERDICT_DEF_LINE" -lt "$CUTOFF_LINE" ]; then
  ok "guard.sh: gate_bash32_verdict (L$VERDICT_DEF_LINE) defined BEFORE the GATE_GUARD_LIB_ONLY cutoff (L$CUTOFF_LINE)"
else
  bad "REGRESSION (ga-zdkn1-class): gate_bash32_verdict def=${VERDICT_DEF_LINE:-missing} cutoff=${CUTOFF_LINE:-missing}"
fi

STEP_COUNT=$(grep -c 'Step 5b-pre3 (ga-7dx2vw)' "$GUARD")
eq "guard.sh: Step 5b-pre3 (ga-7dx2vw) block present exactly once" "$STEP_COUNT" "1"

BEGIN_COUNT=$(grep -c '^# SELFTEST-EXTRACT bash32-check: BEGIN$' "$GUARD")
END_COUNT=$(grep -c '^# SELFTEST-EXTRACT bash32-check: END$' "$GUARD")
eq "guard.sh: SELFTEST-EXTRACT bash32-check sentinels present exactly once each (section 2 depends on them)" "$BEGIN_COUNT/$END_COUNT" "1/1"

B32_BLOCK=$(awk '/Step 5b-pre3 \(ga-7dx2vw\)/,/^fi$/' "$GUARD")
B32_CODE=$(sed -n '/^# SELFTEST-EXTRACT bash32-check: BEGIN$/,/^# SELFTEST-EXTRACT bash32-check: END$/p' "$GUARD" | grep -v '^[[:space:]]*#')

echo "$B32_BLOCK" | grep 'gate_bash32_verdict "\$_B32_CHANGED" "\$_B32_CHECKED" "\$_B32_FAILED" "\$_B32_UNMEASURED"' >/dev/null \
  && ok "guard.sh: block calls gate_bash32_verdict with the three counts AND the list-unread flag" \
  || bad "guard.sh: block does not call gate_bash32_verdict with the unmeasured flag"

echo "$B32_BLOCK" | grep '/bin/bash -n' >/dev/null \
  && ok "guard.sh: block invokes /bin/bash -n explicitly (not bare 'bash -n', which would hit PATH's Homebrew bash and never catch this class of bug)" \
  || bad "guard.sh: block does not invoke /bin/bash -n — would not reproduce the real interpreter"

echo "$B32_BLOCK" | grep -F "'packs/town-deltas/assets' 'scripts'" >/dev/null \
  && ok "guard.sh: diff is scoped to packs/town-deltas/assets and scripts (not every rig's own scripts)" \
  || bad "guard.sh: diff pathspec scoping missing or changed"

echo "$B32_CODE" | grep -F -e '--no-renames' >/dev/null \
  && ok "guard.sh: the diff runs with --no-renames (a renamed+edited file is scanned as an add)" \
  || bad "guard.sh: --no-renames missing — a renamed file would bypass the check again"

echo "$B32_CODE" | grep -E 'git .* diff .*-z ' >/dev/null \
  && ok "guard.sh: the diff is NUL-delimited (-z), so non-ASCII / quoted paths are not dropped" \
  || bad "guard.sh: the diff is not -z — quoted paths would be silently dropped again"

if echo "$B32_CODE" | grep -E 'diff.*\|[[:space:]]*grep' >/dev/null; then
  bad "REGRESSION (third state): the git diff is piped through grep on a code line — its exit status is masked and a failing diff reads as 'no .sh changed'"
else
  ok "guard.sh: no code line pipes the git diff through grep (its exit status decides the list-unread state)"
fi

echo "$B32_CODE" | grep 'gate_bash32_parse_class "\$_b32_rc"' >/dev/null \
  && ok "guard.sh: the block classifies bash -n's exit status through gate_bash32_parse_class (only status 2 counts as a syntax failure)" \
  || bad "guard.sh: the block does not route bash -n's exit status through gate_bash32_parse_class"

if echo "$B32_CODE" | grep -E '/bin/bash -n .*\|\|[[:space:]]*\{' >/dev/null; then
  bad "REGRESSION (third state): any non-zero exit of bash -n is counted as a syntax failure again (a killed/unrunnable parser would read as 'does not parse')"
else
  ok "guard.sh: bash -n is not followed by '|| { ... }' that would count EVERY non-zero exit as a syntax failure"
fi

echo "$B32_CODE" | grep 'label add "\$MARKER_ID" "gate-bash32:\$_B32_VERDICT"' >/dev/null \
  && ok "guard.sh: every verdict is labelled gate-bash32:<verdict> on the marker (auditable after the fact, mirrors ga-rstae)" \
  || bad "guard.sh: the gate-bash32:<verdict> marker label is missing"

echo "$B32_BLOCK" | grep 'set_gate_status "\$MARKER_ID" "error"' >/dev/null \
  && ok "guard.sh: refusal sets gate-status:error (re-submittable, matches the sibling checks' own convention)" \
  || bad "guard.sh: refusal does not set gate-status:error"

echo "$B32_BLOCK" | grep 'exit 1' >/dev/null \
  && ok "guard.sh: refusal actually exits 1 (does not fall through to Step 7)" \
  || bad "guard.sh: refusal does not exit — sweep would continue to Step 7 anyway"

echo "$B32_BLOCK" | grep '"\$_B32_VERDICT" in' -A1 | grep 'bash32-fail)' >/dev/null \
  && ok "guard.sh: refusal is gated on verdict = bash32-fail (not a broader condition that would also refuse sem-sh-alterado/nao-consegui-medir/bash32-ok)" \
  || bad "guard.sh: refusal condition missing or wrong — could over-refuse the non-blocking states"

echo "$B32_BLOCK" | grep -F 'NOT full coverage' >/dev/null \
  && ok "guard.sh: the header comment states the *.sh-only scope (so it is not read as full coverage of launchd-run scripts)" \
  || bad "guard.sh: the header comment does not state that only *.sh files are parsed"

if echo "$B32_BLOCK" | grep -F 'directly abuts' >/dev/null; then
  bad "guard.sh: a comment/text in the block still carries the wrong 'esac directly abuts the closing paren' root cause"
else
  ok "guard.sh: no text in the block carries the wrong 'esac directly abuts the closing paren' root cause"
fi

# gate-fix 3 (the reviewer's BLOCKING finding): the scope comment claimed "Other
# rigs' own scripts never live under these two paths ... costs one empty git diff
# and nothing else" — false as measured (whatsapp_automation tracks 84 .sh under
# scripts/, lexbh 5, property_scrapers 4, gascity 511), and it told the next reader
# that a check that HARD-BLOCKS cannot touch other rigs. Prose is what a reader
# trusts instead of re-measuring, so pin it: the false sentences must stay gone,
# and the true scope must stay stated.
for _false_claim in "never live under" "costs one empty git diff and nothing else" "gate/pilot/witness/deacon" "every com.gascity.* launchd"; do
  if echo "$B32_BLOCK" | grep -F "$_false_claim" >/dev/null; then
    bad "guard.sh: the bash32 block still says '$_false_claim' — a scope/interpreter claim measured to be false (or rig-specific in a rig-neutral refusal)"
  else
    ok "guard.sh: the bash32 block no longer says '$_false_claim'"
  fi
done
if echo "$B32_BLOCK" | grep -F 'WHICHEVER rig' >/dev/null && echo "$B32_BLOCK" | grep -F 'whatsapp_automation' >/dev/null; then
  ok "guard.sh: the scope comment states the check applies in WHICHEVER rig the marker belongs to and names whatsapp_automation (a rig that DOES track .sh under those paths)"
else
  bad "guard.sh: the scope comment no longer states that the check reaches other rigs (whatsapp_automation) — the ga-7dx2vw blocking finding would return"
fi
if echo "$B32_BLOCK" | grep -F '4 plists exec such a .sh' >/dev/null && echo "$B32_BLOCK" | grep -F 'DIRECTLY' >/dev/null; then
  ok "guard.sh: the scope comment states the unverified case (plists that exec a .sh directly) instead of asserting /bin/bash for every job"
else
  bad "guard.sh: the scope comment does not state that some jobs exec a .sh directly (interpreter unverified)"
fi
if grep -F 'launchd-invoked with (com.gascity' "$GUARD" >/dev/null; then
  bad "guard.sh: the gate_bash32_verdict doc still says the com.gascity.* plists hardcode /bin/bash for every script (measured: 70 of 93; the rest run python3/gc/launchctl)"
else
  ok "guard.sh: the gate_bash32_verdict doc no longer over-claims what the com.gascity.* plists run"
fi

RIGPATH_LINE=$(grep -n '\[ -d "\$RIG_PATH" \] || RIG_PATH=""' "$GUARD" | head -1 | cut -d: -f1)
CHECK_LINE=$(grep -n 'Step 5b-pre3 (ga-7dx2vw)' "$GUARD" | head -1 | cut -d: -f1)
QUEUED_LINE=$(grep -n 'label add    "\$MARKER_ID" "gate-status:queued"' "$GUARD" | head -1 | cut -d: -f1)

if [ -n "$RIGPATH_LINE" ] && [ -n "$CHECK_LINE" ] && [ "$RIGPATH_LINE" -lt "$CHECK_LINE" ]; then
  ok "guard.sh: RIG_PATH resolved (L$RIGPATH_LINE) BEFORE the bash32 check (L$CHECK_LINE)"
else
  bad "guard.sh: ordering wrong — RIG_PATH=${RIGPATH_LINE:-missing} check=${CHECK_LINE:-missing}, check would run with an unresolved RIG_PATH"
fi

if [ -n "$CHECK_LINE" ] && [ -n "$QUEUED_LINE" ] && [ "$CHECK_LINE" -lt "$QUEUED_LINE" ]; then
  ok "guard.sh: bash32 check (L$CHECK_LINE) fires BEFORE the marker is parked gate-status:queued (L$QUEUED_LINE) — genuinely pre-enqueue"
else
  bad "guard.sh: ordering wrong — check=${CHECK_LINE:-missing} queued-park=${QUEUED_LINE:-missing}, check would run too late to prevent enqueueing"
fi

# Neighboring checks (ga-pj5va, ga-rstae) untouched.
PJ5VA_COUNT=$(grep -c 'Step 5b-pre (ga-pj5va)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre (ga-pj5va) check still present exactly once, untouched" "$PJ5VA_COUNT" "1"
RSTAE_COUNT=$(grep -c 'Step 5b-pre2 (ga-rstae)' "$GUARD")
eq "guard.sh: neighboring Step 5b-pre2 (ga-rstae) check still present exactly once, untouched" "$RSTAE_COUNT" "1"
E7ZK7_COUNT=$(grep -c 'Step 5b (ga-e7zk7)' "$GUARD")
eq "guard.sh: downstream Step 5b (ga-e7zk7) still present exactly once, untouched" "$E7ZK7_COUNT" "1"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "  RESULT: PASS"
  exit 0
else
  echo "  RESULT: FAIL"
  exit 1
fi
