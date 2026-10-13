#!/usr/bin/env bash
# gate-remerge.fixture.lib.sh — ga-mzw9dt: what the remerge selftests share. SOURCED, runs no test: it sets up the temp dir and the
# assertion helpers, builds the real-git fixture repo (approved commit A, its rebase, A+1 line, two positions of one line, a real conflict
# and its hand-made resolution, tests that fail / have no runner), and installs a stateful fake `bd` (labels and metadata in files).
# The caller sets `set -uo pipefail` and prints its own RESULT line.


SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLLIB="$SELF_DIR/gate-fastlane.lib.sh"
RMLIB="${RMLIB:-$SELF_DIR/gate-remerge.lib.sh}"
DISPATCHER="${DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
B32=/bin/bash   # the daemon's shell (macOS bash 3.2) — never the first `bash` on PATH
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }

[ -x "$B32" ] || { echo "FATAL: $B32 not found"; exit 2; }
for f in "$FLLIB" "$RMLIB" "$DISPATCHER"; do [ -r "$f" ] || { echo "FATAL: missing $f"; exit 2; }; done

T=$(mktemp -d "${TMPDIR:-/tmp}/gate-remerge-XXXXXX") || { echo "FATAL: no temp dir"; exit 1; }
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T/tmp" "$T/bin" "$T/city/.gc" "$T/fakebd"

extract_block() { sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1" | sed '1d;$d'; }
S40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
S64=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
R="$T/w"
git init -q -b main "$R" || { echo "FATAL: git init"; exit 1; }
(
  cd "$R" || exit 1
  mkdir -p src docs tests
  awk 'BEGIN{for(i=1;i<=30;i++) print "line " i}' > src/app.sh
  printf 'a\nb\nc\n' > src/other.sh
  echo "hello" > docs/README.md
  printf '#!/bin/bash\nexit 0\n' > tests/base.selftest.sh
  git add -A && git commit -qm M0
) >/dev/null 2>&1
M0=$(git -C "$R" rev-parse HEAD)
repl3() { awk 'NR==3{print "line 3 CHANGED3"; next}{print}' src/app.sh > .x && mv .x src/app.sh; }
mktest() { printf '#!/bin/bash\ncd "$(dirname "$0")/.." && grep -q "%s" src/app.sh\n' "$2" > "$1"; chmod +x "$1"; }
# A: the approved commit — changes line 3 and adds the test that checks it
( cd "$R" && git checkout -q -b feat "$M0" && repl3 && mktest tests/new.selftest.sh CHANGED3 && git add -A && git commit -qm A ) >/dev/null 2>&1
A=$(git -C "$R" rev-parse feat)
# main moves (M1: an unrelated file)
( cd "$R" && git checkout -q main && printf 'd\n' >> src/other.sh && git commit -qam M1 ) >/dev/null 2>&1
M1=$(git -C "$R" rev-parse main)
# A' = A rebased onto M1 (what the dispatcher's autorebase / the author's rebase produce)
( cd "$R" && git checkout -q -b feat-reb "$A" && git rebase -q main ) >/dev/null 2>&1
AR=$(git -C "$R" rev-parse feat-reb)
# A + one more line on top (content changed after the approval)
( cd "$R" && git checkout -q -b feat-plus "$A" && printf 'extra\n' >> src/other.sh && git commit -qam plus ) >/dev/null 2>&1
AP=$(git -C "$R" rev-parse feat-plus)
# the SAME added line at another position: approved P1 inserts after line 3, head P2 inserts the identical line after line 20
ins() { awk -v n="$2" 'NR==n{print; print "echo hi"; next}{print}' src/app.sh > .x && mv .x src/app.sh; }
( cd "$R" && git checkout -q -b pos1 "$M0" && ins x 3 && mktest tests/pos.selftest.sh "echo hi" && git add -A && git commit -qm P1 ) >/dev/null 2>&1
P1=$(git -C "$R" rev-parse pos1)
( cd "$R" && git checkout -q -b pos2 "$M0" && ins x 20 && mktest tests/pos.selftest.sh "echo hi" && git add -A && git commit -qm P2 ) >/dev/null 2>&1
P2=$(git -C "$R" rev-parse pos2)
# a real conflict: M2 changes line 3 differently, on top of M1
( cd "$R" && git checkout -q main && awk 'NR==3{print "line 3 THEIRS"; next}{print}' src/app.sh > .x && mv .x src/app.sh && git commit -qam M2 ) >/dev/null 2>&1
M2=$(git -C "$R" rev-parse main)
# …and the author's hand-made resolution on top of M2 (same words as A, written by a person)
( cd "$R" && git checkout -q -b feat-res "$M2" && repl3 && mktest tests/new.selftest.sh CHANGED3 && git add -A && git commit -qm RES ) >/dev/null 2>&1
RES=$(git -C "$R" rev-parse feat-res)
# a branch whose directed test FAILS, one with a test no runner can run, and one with two tests
( cd "$R" && git checkout -q -b badtest "$M0" && repl3 && printf '#!/bin/bash\nexit 1\n' > tests/bad.selftest.sh && chmod +x tests/bad.selftest.sh && git add -A && git commit -qm BT ) >/dev/null 2>&1
BT=$(git -C "$R" rev-parse badtest)
( cd "$R" && git checkout -q -b lua "$M0" && repl3 && printf 'print(1)\n' > tests/helper.lua && git add -A && git commit -qm LUA ) >/dev/null 2>&1
LUA=$(git -C "$R" rev-parse lua)
( cd "$R" && git checkout -q -b notest "$M0" && repl3 && git add -A && git commit -qm NT ) >/dev/null 2>&1
NT=$(git -C "$R" rev-parse notest)
( cd "$R" && git checkout -q main ) >/dev/null 2>&1
for v in M0 A M1 AR AP P1 P2 M2 RES BT LUA NT; do
  if [ -n "$(eval "echo \$$v")" ]; then :; else bad "fixture: $v was not created"; fi
done
ok "fixture repo built (approved A, its rebase, A+1 line, two positions of one line, a real conflict and its hand-made resolution)"

NOW=$(date +%s)
lbl() { printf 'gate-approved:%s:%s' "$1" "$2"; }
FRESH=$((NOW - 60))
# mklog <labels> — the dispatcher's log as it would hold it for these labels: one gate_approval event per approval label, in $QG_FIX.
# (A label with no event in it is what a hand-added label looks like to gate_remerge_decide.)
QG_FIX="$T/qg.jsonl"
mklog() { local w s; : > "$QG_FIX"; for w in $1; do case "$w" in gate-approved:*) s=${w#gate-approved:}; printf '{"event":"gate_approval","bead":"ga-x","sha":"%s","epoch":%s}\n' "${s%%:*}" "${s##*:}" >> "$QG_FIX" ;; esac; done; }
cat > "$T/bin/bd" <<'EOF'
#!/bin/bash
# stateful stub: -C <city> <verb> ...   labels and metadata live in files under $FAKE_BD_DIR
shift 2
verb="$1"; shift
D="$FAKE_BD_DIR"
case "$verb" in
  label)
    sub="$1"; bead="$2"; lab="$3"; f="$D/labels.$bead"; touch "$f"
    case "$sub" in
      add)    [ "${FAKE_BD_FAIL_LABEL_ADD:-}" = 1 ] && exit 0; echo "$lab" >> "$f" ;;
      remove) [ "${FAKE_BD_FAIL_LABEL_REMOVE:-}" = 1 ] && exit 0; grep -vxF -- "$lab" "$f" > "$f.n"; mv "$f.n" "$f" ;;
    esac ;;
  show)
    bead="$1"; [ "${FAKE_BD_FAIL_SHOW:-}" = 1 ] && exit 1
    f="$D/labels.$bead"; m="$D/meta.$bead"; touch "$f" "$m"
    jq -n --rawfile l "$f" --rawfile m "$m" '[{labels: ($l|split("\n")|map(select(length>0))), metadata: ($m|split("\n")|map(select(length>0)|capture("^(?<k>[^=]+)=(?<v>.*)$")|{(.k):.v})|add // {})}]' ;;
  update)
    bead="$1"; shift
    while [ $# -gt 0 ]; do case "$1" in --set-metadata) echo "$2" >> "$D/meta.$bead"; shift ;; esac; shift; done ;;
  comment) echo "$*" >> "$D/comments.log" ;;
esac
exit 0
EOF
chmod +x "$T/bin/bd"
bdenv() { env PATH="$T/bin:$PATH" FAKE_BD_DIR="$T/fakebd" "$@"; }
reset_bd() { rm -f "$T"/fakebd/*; }
labels_of() { cat "$T/fakebd/labels.$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
