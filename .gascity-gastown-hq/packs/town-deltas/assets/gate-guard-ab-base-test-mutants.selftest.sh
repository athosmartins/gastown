#!/usr/bin/env bash
# gate-guard-ab-base-test-mutants.selftest.sh — Prove ga-4kykayr: a slice of the hq-mutants lastro
# (origem:lastro-hq-mutants) only hardens a SELFTEST, so production code does not change and the new
# selftest passes UNCHANGED against base. In arm B of ga-rstae that read as passou-na-base and the marker
# was refused (ga-iu0fvlo, marker ga-1iur59y). The honest question for such a slice is "does the selftest
# catch a BROKEN base?", and the lastro already lists the breakages (its mutants). Same design as the
# portability repair (ga-hlcfzx9, Mayor 2026-10-28): the builder DECLARES (label teste:endurece-mutantes on
# the source bead), the gate MEASURES (it applies the mutants the bead lists for that selftest, one at a
# time, to a copy of base and runs the branch's selftest against each: GREEN with none, RED with at least
# one), and the path never depends on the bead id. The new verdict word is matou-mutantes (does not block).
#
# Slice 1 of 2 (ga-4kykayr.1) covers what MEASURES: the label reader, the lastro list parser, the engine's
# apply, the sandboxed mutant run and the opt-in heavy-guard wrapper. The verdict word and the Step 5b-pre2
# call site (their dispatch and acceptance cases) are slice 2 (ga-4kykayr.2).
#
## Contents
##   1. pure         label reader · lastro list parser · rc classes
##   2. real runs    gate_base_test_mutants_state against a real git repo, the real hq-mutate.py `apply`
##                   and the real macOS sandbox: killed / survived / every way it cannot tell
##   3. engine       hq-mutate.py apply, called directly
##   4. drift        placement, containment and "nothing here picks anything by bead id"
##
# The sandbox sections need /usr/bin/sandbox-exec (macOS); without it they are skipped, loudly, and the pure
# and drift sections still run. This file is listed in hetzner-mac-only.hq.txt next to the other A/B check
# selftests: the Linux node has no sandbox-exec, so it could only ever skip.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
ENGINE="$SELF_DIR/../../../scripts/hq-mutate.py"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — got '$2', want '$3'"; }

[ -f "$GUARD" ] || { echo "FATAL: missing $GUARD"; exit 1; }
[ -f "$ENGINE" ] || { echo "FATAL: missing $ENGINE"; exit 1; }
bash -n "$GUARD" && ok "guard passes bash -n syntax check" || bad "guard has syntax errors"
bash -n "${BASH_SOURCE[0]}" && ok "this selftest passes bash -n" || bad "this selftest has syntax errors"

# A caller's own overrides must not steer this run.
unset GATE_ABT_HEAVY_GUARD GATE_ABT_MUTATE GATE_ABT_MUT_TIMEOUT GATE_ABT_MUT_BUDGET GATE_ABT_MUT_MAX \
      GATE_ABT_SANDBOX_EXEC GATE_ABT_RUN_GUARD \
      FAKE_BD_OUT_FILE FAKE_BD_RC FAKE_BD_LOG FAKE_HG_RC FAKE_HG_LOG FAKE_ENGINE_MODE

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail, which leaks into this shell (sourced, not subprocessed) and
        # would silently kill the rest of this harness on the first non-zero command.

for _fn in gate_base_test_label_declared gate_base_test_mutants_declared gate_base_test_mutant_list \
           gate_base_test_mutant_rc_class gate_base_test_mutants_state gate_base_test_sandbox_exec; do
  type "$_fn" >/dev/null 2>&1 && ok "$_fn is defined after LIB_ONLY sourcing" || bad "FATAL: $_fn is not defined"
done
type gate_base_test_mutants_state >/dev/null 2>&1 || { echo "  PASS=$PASS  FAIL=$FAIL"; exit 1; }

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-4kykayr-selftest.XXXXXX")"
TMPD="$(cd "$TMPD" && pwd -P)"
REPO="$TMPD/repo"
cleanup() {
  [ -d "$REPO/.git" ] && git -C "$REPO" worktree prune 2>/dev/null
  rm -rf "$TMPD"
}
trap cleanup EXIT

mkdir -p "$TMPD/bin"

# ── fakes ────────────────────────────────────────────────────────────────────────────────────────────
# bd: prints the file named by FAKE_BD_OUT_FILE, exits FAKE_BD_RC, logs its arguments.
cat > "$TMPD/bin/bd" <<'FAKEBDEOF'
#!/usr/bin/env bash
echo "$*" >> "${FAKE_BD_LOG:-/dev/null}"
[ -n "${FAKE_BD_OUT_FILE:-}" ] && cat "$FAKE_BD_OUT_FILE"
exit "${FAKE_BD_RC:-0}"
FAKEBDEOF
chmod +x "$TMPD/bin/bd"
# heavy-guard stand-in: logs "<--what NAME --max-file-mb N --> <last arg>" (one line per run), answers
# FAKE_HG_RC if set, else runs what follows the `--`. The real heavy-guard needs a disk reading; the real
# one is what runs in production (the drift section pins that the guard asks for it by that path).
cat > "$TMPD/bin/hg-stub.sh" <<'FAKEHGEOF'
#!/usr/bin/env bash
echo "$1 $2 $3 $4 $5 | ${@: -1}" >> "${FAKE_HG_LOG:-/dev/null}"
[ -n "${FAKE_HG_RC:-}" ] && exit "$FAKE_HG_RC"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
FAKEHGEOF
chmod +x "$TMPD/bin/hg-stub.sh"
# a stand-in for hq-mutate.py: `apply` writes whatever FAKE_ENGINE_MODE says, whatever file it is asked about.
cat > "$TMPD/fake-engine.py" <<'FAKEENGEOF'
import os, sys
a = sys.argv
out = a[a.index('--out') + 1]
mode = os.environ.get('FAKE_ENGINE_MODE', 'garbage')
if mode == 'rc5':
    sys.exit(5)
if mode == 'noout':
    sys.exit(0)
with open(out, 'w') as fh:
    fh.write('' if mode == 'empty' else '# MUTATED BY THE FAKE ENGINE\n')
sys.exit(0)
FAKEENGEOF
export PATH="$TMPD/bin:$PATH"
export FAKE_BD_LOG="$TMPD/bd.log" FAKE_HG_LOG="$TMPD/hg.log"
: > "$FAKE_BD_LOG"; : > "$FAKE_HG_LOG"

STORE=/fake/store
BEAD=ga-mut
LBL_M="teste:endurece-mutantes"
LBL_P="teste:portabilidade-os"
bdset() {  # bdset <bead-id> <description> [label...]   -> the fake bd serves that bead
  local id="$1" desc="$2"; shift 2
  jq -n --arg id "$id" --arg d "$desc" '$ARGS.positional as $l | [{id:$id, labels:$l, description:$d}]' --args "$@" > "$TMPD/bd.json"
  export FAKE_BD_OUT_FILE="$TMPD/bd.json"
}
bdraw() { printf '%s' "$1" > "$TMPD/bd.json"; export FAKE_BD_OUT_FILE="$TMPD/bd.json"; }
nlines() { if [ -s "$1" ]; then grep -c . "$1" || true; else echo 0; fi; }   # grep -c prints 0 AND exits 1 on an empty file

# ── 1. pure ──────────────────────────────────────────────────────────────────────────────────────────
echo "── 1. pure: label reader, lastro list parser, rc classes ──"
echo "  -- gate_base_test_mutants_declared / label_declared --"
bdraw "[{\"id\":\"$BEAD\",\"labels\":[\"gate:g\",\"$LBL_M\"]}]"
eq "label teste:endurece-mutantes present -> yes" "$(gate_base_test_mutants_declared $STORE $BEAD)" "yes"
eq "... and the portability label is NOT declared by it" "$(gate_base_test_portability_declared $STORE $BEAD)" "no"
bdraw "[{\"id\":\"$BEAD\",\"labels\":[\"gate:g\",\"$LBL_P\"]}]"
eq "only the portability label -> mutants: no" "$(gate_base_test_mutants_declared $STORE $BEAD)" "no"
eq "... and portability: yes (the ga-hlcfzx9 reader still answers)" "$(gate_base_test_portability_declared $STORE $BEAD)" "yes"
bdraw "[{\"id\":\"$BEAD\",\"labels\":[\"$LBL_M-x\",\"x$LBL_M\"]}]"
eq "labels that only CONTAIN the name (suffix/prefix) -> no (exact match)" "$(gate_base_test_mutants_declared $STORE $BEAD)" "no"
bdraw "[{\"id\":\"$BEAD\"}]"
eq "a bead with no labels key -> no (bd omits it when empty)" "$(gate_base_test_mutants_declared $STORE $BEAD)" "no"
bdraw "{\"id\":\"$BEAD\",\"labels\":[\"$LBL_M\"]}"
eq "a bare object instead of a one-element array -> yes" "$(gate_base_test_mutants_declared $STORE $BEAD)" "yes"
bdraw '{"error":"no issues found matching the provided IDs","schema_version":1}'
eq "bd not-found answer -> unknown (not 'no')" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw "[{\"id\":\"ga-other\",\"labels\":[\"$LBL_M\"]}]"
eq "another bead's record -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw "[{\"id\":\"$BEAD\",\"labels\":\"$LBL_M\"}]"
eq "labels is a string, not a list -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw "[{\"id\":\"$BEAD\",\"labels\":[\"$LBL_M\",7]}]"
eq "labels holds a non-string -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw 'this is not json'
eq "bd output that is not JSON -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw ''
eq "bd printed nothing -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
bdraw "[{\"id\":\"$BEAD\",\"labels\":[\"$LBL_M\"]}]"
export FAKE_BD_RC=1
eq "bd failed (rc 1) even though it printed a record -> unknown" "$(gate_base_test_mutants_declared $STORE $BEAD)" "unknown"
unset FAKE_BD_RC
eq "empty store -> unknown" "$(gate_base_test_mutants_declared "" $BEAD)" "unknown"
eq "empty bead -> unknown" "$(gate_base_test_mutants_declared $STORE "")" "unknown"
eq "label_declared with an empty label -> unknown" "$(gate_base_test_label_declared $STORE $BEAD "")" "unknown"
: > "$FAKE_BD_LOG"; gate_base_test_mutants_declared $STORE $BEAD >/dev/null
eq "the reader asks 'bd -C <store> show <bead> --json'" "$(head -1 "$FAKE_BD_LOG")" "-C $STORE show $BEAD --json"
eq "both readers exit 0 (safe under the guard's set -e)" "$(gate_base_test_mutants_declared "" "" >/dev/null; echo $?)$(gate_base_test_portability_declared "" "" >/dev/null; echo $?)" "00"

echo "  -- gate_base_test_mutant_list (the lastro's own description format) --"
TAB=$'\t'
SELW="packs/town-deltas/assets/widget.selftest.sh"
SELO="packs/town-deltas/assets/other.selftest.sh"
LASTRO="Mutantes SOBREVIVENTES confirmados pelo lastro do nó (item hq-mutants): 3 troca(s)

Cada linha é uma quebra deliberada.

ARQUIVO packs/town-deltas/assets/widget.sh (3)
  L4 [num+1] 10 -> 11  id=aaaaaaaaaa  (testes: $SELW)
  L4 [cmp-lim] -gt -> -ge  id=bbbbbbbbbb  (testes: $SELO,$SELW)
  L9 [num] 1 -> 2  id=cccccccccc  (testes: $SELO)
ARQUIVO packs/town-deltas/assets/gadget.sh (2)
  L2 [num] 5 -> 6  id=dddddddddd  (testes: $SELW,$SELO)
  L7 [lim] <= -> <  id=0123456789  (testes: $SELW)"
bdset $BEAD "$LASTRO" origem:lastro-hq-mutants "$LBL_M"
eq "list for widget.selftest.sh: its four lines, in list order, as '<file><TAB><id>' (a selftest named in a comma list counts)" \
  "$(gate_base_test_mutant_list $STORE $BEAD $SELW | tr '\t' '|' | tr '\n' ' ')" \
  "packs/town-deltas/assets/widget.sh|aaaaaaaaaa packs/town-deltas/assets/widget.sh|bbbbbbbbbb packs/town-deltas/assets/gadget.sh|dddddddddd packs/town-deltas/assets/gadget.sh|0123456789 "
eq "list for other.selftest.sh: the lines that name it, across ARQUIVO blocks" \
  "$(gate_base_test_mutant_list $STORE $BEAD $SELO | cut -f2 | tr '\n' ' ')" "bbbbbbbbbb cccccccccc dddddddddd "
eq "a selftest the list never names -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD packs/town-deltas/assets/none.selftest.sh)" ""
eq "a selftest whose name only CONTAINS a listed one -> nothing (exact match per entry)" \
  "$(gate_base_test_mutant_list $STORE $BEAD "x$SELW")$(gate_base_test_mutant_list $STORE $BEAD "$SELW.bak")" ""
eq "empty selftest argument -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD "")" ""
bdset $BEAD "ARQUIVO packs/a.sh (4)
  L1 [n] 1 -> 2  id=abc  (testes: $SELW)
  L2 [n] 1 -> 2  id=ABCDEF0123  (testes: $SELW)
  L3 [n] 1 -> 2  (testes: $SELW)
  L4 [n] 1 -> 2  id=0a0a0a0a0a
 L5 [n] 1 -> 2  id=1b1b1b1b1b  (testes: $SELW)
  L6 [n] 1 -> 2  (testes: $SELW)  id=2c2c2c2c2c
  L7 [n] 1 -> 2  id=3d3d3d3d3d  (testes: $SELW)"
eq "malformed lines (short id, upper-case id, no id, no testes, one-space indent, testes before id) are skipped, the good one is kept" \
  "$(gate_base_test_mutant_list $STORE $BEAD $SELW | cut -f2 | tr '\n' ' ')" "3d3d3d3d3d "
bdset $BEAD "  L7 [n] 1 -> 2  id=3d3d3d3d3d  (testes: $SELW)"
eq "a mutant line with no ARQUIVO above it has no file to apply to -> skipped" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdset $BEAD "só texto, nenhuma lista"
eq "a description with no list at all -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdset ga-other "$LASTRO"
eq "another bead's record -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdraw "[{\"id\":\"$BEAD\",\"labels\":[]}]"
eq "a record with no description -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdraw "[{\"id\":\"$BEAD\",\"description\":7}]"
eq "a description that is not a string -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdraw 'not json'
eq "bd output that is not JSON -> nothing" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
bdset $BEAD "$LASTRO"; export FAKE_BD_RC=1
eq "bd failed -> nothing (the same as 'no list': both are 'nothing to measure against')" "$(gate_base_test_mutant_list $STORE $BEAD $SELW)" ""
unset FAKE_BD_RC
eq "empty store/bead -> nothing" "$(gate_base_test_mutant_list "" $BEAD $SELW)$(gate_base_test_mutant_list $STORE "" $SELW)" ""
eq "always exits 0" "$(gate_base_test_mutant_list "" "" "" >/dev/null; echo $?)" "0"

echo "  -- gate_base_test_mutant_rc_class --"
for _c in "0:green" "1:red" "2:red" "10:red" "95:red" "007:red" "00:green" \
          "64:unknown" "75:unknown" "76:unknown" "78:unknown" "79:unknown" \
          "96:unknown" "97:unknown" "98:unknown" "99:unknown" "124:unknown" "126:unknown" "127:unknown" "128:unknown" "137:unknown" "143:unknown" "255:unknown" \
          "x:unknown" "-1:unknown" "1.5:unknown" ":unknown"; do
  eq "rc '${_c%%:*}' -> ${_c#*:}" "$(gate_base_test_mutant_rc_class "${_c%%:*}")" "${_c#*:}"
done
eq "rc class with no argument -> unknown" "$(gate_base_test_mutant_rc_class)" "unknown"

# ── real-run fixtures ────────────────────────────────────────────────────────────────────────────────
CAN_RUN=1
for _t in /usr/bin/sandbox-exec python3 jq git; do command -v "$_t" >/dev/null 2>&1 || [ -x "$_t" ] || CAN_RUN=0; done
command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || CAN_RUN=0

if [ "$CAN_RUN" -ne 1 ]; then
  echo "── 2-3. SKIPPED: sandbox-exec / python3 / jq / git / timeout missing on this host (the sandbox is macOS-only) ──"
else
A=.gascity-gastown-hq/packs/town-deltas/assets      # repo-root-relative, the form `git diff --name-only` prints
HQ="$REPO/.gascity-gastown-hq"
F_W="$A/widget.selftest.sh"
F_T="$A/trivial.selftest.sh"
mkdir -p "$REPO/$A" "$TMPD/outside/dir"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" checkout -q -b main 2>/dev/null
git -C "$REPO" config user.email t@example.invalid
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

cat > "$REPO/$A/widget.sh" <<'WIDGETEOF'
#!/usr/bin/env bash
# widget: names the size class of its first argument
n="${1:-0}"
if [ "$n" -gt 10 ]; then
  echo big
else
  echo small
fi
WIDGETEOF
mk_widget_selftest() {  # mk_widget_selftest [<arg>:<want>]...   -> a selftest of widget.sh on stdout
  printf '%s\n' '#!/usr/bin/env bash' 'SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'fail=0' \
    'chk() { [ "$(bash "$SELF_DIR/widget.sh" "$1")" = "$2" ] || { echo "FAIL widget $1 -> $2"; fail=1; }; }' \
    'chk 50 big' 'chk 0 small'
  local c
  for c in "$@"; do printf 'chk %s %s\n' "${c%%:*}" "${c#*:}"; done
  printf '%s\n' 'exit $fail'
}
mk_widget_selftest > "$REPO/$A/widget.selftest.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$REPO/$A/trivial.selftest.sh"
# a production file whose text cites sudo: the engine refuses to run mutants of it
printf '#!/usr/bin/env bash\n# needs sudo on the host\nif [ "${1:-0}" -gt 3 ]; then echo a; fi\n' > "$REPO/$A/risky.sh"
# a symlinked subject (to a file OUTSIDE the tree) and a subject under a symlinked directory
printf '#!/usr/bin/env bash\nif [ "${1:-0}" -gt 3 ]; then echo a; fi\n' > "$TMPD/outside/outside.sh"
cp "$TMPD/outside/outside.sh" "$TMPD/outside/dir/x.sh"
ln -s "$TMPD/outside/outside.sh" "$REPO/$A/link.sh"
ln -s "$TMPD/outside/dir" "$REPO/$A/linkdir"
git -C "$REPO" add -- "$A/widget.sh" "$A/widget.selftest.sh" "$A/trivial.selftest.sh" "$A/risky.sh" "$A/link.sh" "$A/linkdir"
git -C "$REPO" commit -q -m base
BASE=$(git -C "$REPO" rev-parse HEAD)
OUT_SUM="$(cksum < "$TMPD/outside/outside.sh") $(cksum < "$TMPD/outside/dir/x.sh")"

gid() {  # gid <file-relative-to-assets> <op>   -> the engine's own id for that mutant of the base tree
  python3 -I "$ENGINE" gen "$REPO/$A/$1" --tree "$HQ" 2>/dev/null | awk -F'\t' -v op="$2" '$3 == op { print $1; exit }'
}
ID_LIM=$(gid widget.sh cmp-lim)     # -gt -> -ge   (the boundary: only a case AT 10 catches it)
ID_NUM=$(gid widget.sh "num+1")     # 10 -> 11     (only a case AT 11 catches it)
ID_NEG=$(gid widget.sh neg-if)      # ! [ ... ]    (the weak selftest already catches it)
ID_RISKY=$(gid risky.sh cmp-lim)
for _v in ID_LIM ID_NUM ID_NEG ID_RISKY; do
  case "$(eval "printf '%s' \"\$$_v\"")" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "fixture: the engine's gen produced a 10-hex id for $_v" ;;
    *) bad "FATAL fixture: no id for $_v — the engine's gen printed nothing usable" ;;
  esac
done

mkbranch() {  # mkbranch <branch> <message> <repo-relative file>   (the new content on stdin)
  git -C "$REPO" checkout -q -B "$1" "$BASE" || return 1
  cat > "$REPO/$3"
  git -C "$REPO" add -- "$3"
  git -C "$REPO" commit -q -m "$2"
}
mk_widget_selftest 10:small   | mkbranch kills       "kills the boundary"                         "$F_W"
mk_widget_selftest 10:small   | mkbranch killscited  "kills the boundary (mutant $ID_LIM)"        "$F_W"
mk_widget_selftest 11:big     | mkbranch kills11     "kills the +1"                               "$F_W"
mk_widget_selftest 10:small 11:big | mkbranch killsboth "kills both"                             "$F_W"
mk_widget_selftest 100:big    | mkbranch weak        "a case that kills nothing"                  "$F_W"
mk_widget_selftest 50:small   | mkbranch redctl      "red with no mutant at all"                  "$F_W"
printf '%s\n' '#!/usr/bin/env bash' 'f="$TMPDIR/runs"; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$f"' \
  '[ "$n" -eq 2 ] && exit 1' 'exit 0' | mkbranch flaky "red once, green on the repeat" "$F_W"
printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'exit 0' | mkbranch slowctl "slow even with no mutant" "$F_W"
printf '%s\n' '#!/usr/bin/env bash' 'SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  '[ "$(bash "$SELF_DIR/widget.sh" 10)" = small ] || sleep 30' 'exit 0' | mkbranch hang "hangs when the mutant is in" "$F_W"
printf '%s\n' '#!/usr/bin/env bash' '# touched' 'exit 0' | mkbranch trivial "touches a selftest that is not about widget.sh" "$F_T"
git -C "$REPO" checkout -q main

WT="$TMPD/wt"
git -C "$REPO" worktree add --detach --quiet "$WT" "$BASE" 2>/dev/null || bad "FATAL fixture: worktree add failed"
tip() { git -C "$REPO" rev-parse "$1"; }
st() {  # st <branch> [repo-relative selftest]   -> gate_base_test_mutants_state
  gate_base_test_mutants_state "$REPO" "$BASE" "$(tip "$1")" "$WT" "${2:-$F_W}" "$STORE" "$BEAD"
}
mutdesc() {  # mutdesc <subject-under-assets> <selftest-under-hq> <id>...   -> a lastro description listing those ids
  local subj="$1" sel="$2"; shift 2
  printf 'Mutantes SOBREVIVENTES\n\nARQUIVO packs/town-deltas/assets/%s (%d)\n' "$subj" "$#"
  local i; for i in "$@"; do printf '  L4 [x] a -> b  id=%s  (testes: %s)\n' "$i" "$sel"; done
}
SEL_W="packs/town-deltas/assets/widget.selftest.sh"
SEL_T="packs/town-deltas/assets/trivial.selftest.sh"
use_list() {  # use_list <subject> <selftest> <id>...
  local subj="$1" sel="$2"; shift 2
  bdset $BEAD "$(mutdesc "$subj" "$sel" "$@")" origem:lastro-hq-mutants "$LBL_M"
}
hgreset() { : > "$FAKE_HG_LOG"; unset FAKE_HG_RC; }
W_SUM() { cksum < "$WT/$A/widget.sh"; }
export GATE_ABT_HEAVY_GUARD="$TMPD/bin/hg-stub.sh" GATE_ABT_MUTATE="$ENGINE"

# ── 2. real runs ─────────────────────────────────────────────────────────────────────────────────────
echo "── 2. gate_base_test_mutants_state: a real repo, the real engine, the real macOS sandbox ──"
W0=$(W_SUM)

use_list widget.sh "$SEL_W" "$ID_NUM" "$ID_LIM"; hgreset
eq "KILLED: the branch adds 'chk 10 small', the list holds a survivor then the boundary mutant" "$(st kills)" "killed"
eq "... the production file is back byte for byte" "$(W_SUM)" "$W0"
eq "... and git sees the worktree's production file as untouched" "$(git -C "$WT" status --porcelain -- "$A/widget.sh")" ""
eq "... 4 sandboxed runs: control, the survivor once, the killer twice (red must repeat)" "$(nlines "$FAKE_HG_LOG")" "4"
eq "... every one went through the heavy-guard wrapper with the per-file write cap (--max-file-mb 512)" \
  "$(grep -c '^--what selftest-gate-abt --max-file-mb 512 -- | ' "$FAKE_HG_LOG")" "4"
eq "... and the run is of the BRANCH's selftest, inside the worktree" "$(sed 's#.*| ##' "$FAKE_HG_LOG" | sort -u)" "$WT/$F_W"

use_list widget.sh "$SEL_W" "$ID_LIM" "$ID_NUM"; hgreset
eq "KILLED with the killer first in the list (one mutant, red:red, stops there)" "$(st kills)" "killed"
eq "... 3 runs (control + the killer twice)" "$(nlines "$FAKE_HG_LOG")" "3"
use_list widget.sh "$SEL_W" "$ID_NUM"; hgreset
eq "KILLED the other way: 'chk 11 big' kills 10 -> 11" "$(st kills11)" "killed"
use_list widget.sh "$SEL_W" "$ID_NUM" "$ID_LIM"; hgreset
eq "KILLED with both boundary cases" "$(st killsboth)" "killed"

use_list widget.sh "$SEL_W" "$ID_NUM" "$ID_LIM"; hgreset
eq "SURVIVED: a selftest that kills neither listed mutant, COMPLETE measurement -> survived (stays passou-na-base)" "$(st weak)" "survived"
eq "... 3 runs (control + each mutant once: a green needs no repeat)" "$(nlines "$FAKE_HG_LOG")" "3"
eq "... production file back byte for byte" "$(W_SUM)" "$W0"
use_list widget.sh "$SEL_W" "$ID_LIM"
eq "a selftest that kills a mutant NOT in this list does not count: 'chk 11 big' against {boundary} -> survived" "$(st kills11)" "survived"
use_list widget.sh "$SEL_W" "$ID_NUM"
eq "... and 'chk 10 small' against {+1} -> survived" "$(st kills)" "survived"

echo "  -- every way the measurement cannot tell: unknown, never survived, never killed --"
bdset $BEAD "ARQUIVO packs/town-deltas/assets/widget.sh (1)
  L4 [x] a -> b  id=$ID_LIM  (testes: packs/town-deltas/assets/another.selftest.sh)" "$LBL_M"; hgreset
eq "the list names other selftests only (this one has no mutants listed) -> unknown" "$(st kills)" "unknown"
eq "... nothing ran at all" "$(nlines "$FAKE_HG_LOG")" "0"
bdset $BEAD "sem lista" "$LBL_M"
eq "no list in the description -> unknown" "$(st kills)" "unknown"
use_list widget.sh "$SEL_W" "$ID_LIM"; export FAKE_BD_RC=1
eq "bd failed -> unknown" "$(st kills)" "unknown"
unset FAKE_BD_RC
use_list widget.sh "$SEL_W" deadbeef00; hgreset
eq "a stale id (the file shifted since the lastro): apply says rc 4 -> unknown" "$(st kills)" "unknown"
use_list widget.sh "$SEL_W" deadbeef00 "$ID_LIM"
eq "... a stale id in front of the killer -> still killed (one proven kill is proof)" "$(st kills)" "killed"
use_list widget.sh "$SEL_W" "$ID_NUM" deadbeef00
eq "... a surviving mutant and a stale one -> unknown (the stale one was not measured), NOT survived" "$(st weak)" "unknown"
use_list widget.sh "$SEL_W" "$ID_LIM"; hgreset
eq "control not green (the selftest is red with NO mutant) -> unknown" "$(st redctl)" "unknown"
eq "... only the control ran" "$(nlines "$FAKE_HG_LOG")" "1"
hgreset
eq "flaky: red on the mutant once, green on the repeat -> unknown (a flaky test is not a kill)" "$(st flaky)" "unknown"
use_list widget.sh "$SEL_W" "$ID_NUM" "$ID_LIM"; hgreset
eq "cap: GATE_ABT_MUT_MAX=1 and the survivor is first -> unknown (the killer was not reached)" "$(GATE_ABT_MUT_MAX=1 st kills)" "unknown"
eq "... cap=2 reaches it -> killed" "$(GATE_ABT_MUT_MAX=2 st kills)" "killed"
eq "cited first: the commit message names the killer's id, so cap=1 reaches it -> killed" "$(GATE_ABT_MUT_MAX=1 st killscited)" "killed"
eq "... the same selftest with the id NOT cited (message without it) -> unknown at cap=1" "$(GATE_ABT_MUT_MAX=1 st kills)" "unknown"
eq "an unusable cap (0, abc) falls back to the default (40) -> killed" "$(GATE_ABT_MUT_MAX=0 st kills)$(GATE_ABT_MUT_MAX=abc st kills)" "killedkilled"
use_list widget.sh "$SEL_W" "$ID_LIM"; hgreset
eq "budget: GATE_ABT_MUT_BUDGET=1 and a control that takes 2s -> no mutant is tried -> unknown" "$(GATE_ABT_MUT_BUDGET=1 st slowctl)" "unknown"
eq "... only the control ran" "$(nlines "$FAKE_HG_LOG")" "1"
hgreset
eq "timeout: GATE_ABT_MUT_TIMEOUT=1 and a control that takes 2s -> 124 on the control -> unknown" "$(GATE_ABT_MUT_TIMEOUT=1 st slowctl)" "unknown"
hgreset
eq "a mutant that makes the selftest HANG (timeout 2s) is unknown, never killed" "$(GATE_ABT_MUT_TIMEOUT=2 st hang)" "unknown"
eq "... and the production file is still back" "$(W_SUM)" "$W0"
hgreset
eq "no sandbox-exec -> unknown" "$(GATE_ABT_SANDBOX_EXEC=/nonexistent/sandbox-exec st kills)" "unknown"
eq "... nothing ran (never started unsandboxed)" "$(nlines "$FAKE_HG_LOG")" "0"
eq "engine missing -> unknown" "$(GATE_ABT_MUTATE=/nonexistent/hq-mutate.py st kills)" "unknown"
eq "heavy-guard wrapper missing -> unknown (sandbox_exec answers 97: not run)" "$(GATE_ABT_HEAVY_GUARD=/nonexistent/heavy-guard.sh st kills)" "unknown"
for _rc in 75 76 78 79 64; do
  hgreset; export FAKE_HG_RC=$_rc
  eq "heavy-guard answers rc $_rc (disk floor / watch / lock / usage) on the control -> unknown" "$(st kills)" "unknown"
done
hgreset; export FAKE_HG_RC=1
eq "a wrapper that always answers 1 = a selftest that is always red: the control is not green -> unknown" "$(st kills)" "unknown"
hgreset
eq "wrong file kinds: a production file where a selftest belongs -> unknown" "$(st kills "$A/widget.sh")" "unknown"
eq "... a path outside .gascity-gastown-hq/ -> unknown" "$(st kills other/widget.selftest.sh)" "unknown"
eq "... bare '.gascity-gastown-hq/.selftest.sh' (no name) -> unknown" "$(st kills .gascity-gastown-hq/.selftest.sh)" "unknown"
for _blank in rig base tip wt file store bead; do
  _args=("$REPO" "$BASE" "$(tip kills)" "$WT" "$F_W" "$STORE" "$BEAD")
  case "$_blank" in rig) _args[0]="" ;; base) _args[1]="" ;; tip) _args[2]="" ;; wt) _args[3]="" ;; file) _args[4]="" ;; store) _args[5]="" ;; bead) _args[6]="" ;; esac
  eq "empty $_blank argument -> unknown" "$(gate_base_test_mutants_state "${_args[@]}")" "unknown"
done
eq "a tip that does not resolve -> unknown" "$(gate_base_test_mutants_state "$REPO" "$BASE" 0000000000000000000000000000000000000000 "$WT" "$F_W" "$STORE" "$BEAD")" "unknown"
eq "a worktree that is not there -> unknown" "$(gate_base_test_mutants_state "$REPO" "$BASE" "$(tip kills)" "$TMPD/no-such-wt" "$F_W" "$STORE" "$BEAD")" "unknown"
eq "always exits 0" "$(gate_base_test_mutants_state "" "" "" "" "" "" "" >/dev/null; echo $?)" "0"
eq "the wrapper's local GATE_ABT_RUN_GUARD never leaks into this shell" "${GATE_ABT_RUN_GUARD+set}" ""

echo "  -- containment: a hostile or odd engine, a symlinked or sensitive subject --"
export GATE_ABT_MUTATE="$TMPD/fake-engine.py"
use_list widget.sh "$SEL_W" "$ID_LIM"; hgreset
eq "a mutant that wrecks widget.sh (fake engine, 'garbage' mode): the selftest goes red twice -> killed" "$(FAKE_ENGINE_MODE=garbage st weak)" "killed"
eq "... and the worktree's widget.sh was put back byte for byte" "$(W_SUM)" "$W0"
eq "... git agrees" "$(git -C "$WT" status --porcelain -- "$A/widget.sh")" ""
hgreset
eq "an engine that writes an EMPTY mutant -> unknown (never run)" "$(FAKE_ENGINE_MODE=empty st weak)" "unknown"
eq "... only the control ran" "$(nlines "$FAKE_HG_LOG")" "1"
eq "an engine that exits 0 and writes nothing -> unknown" "$(FAKE_ENGINE_MODE=noout st weak)" "unknown"
eq "an engine that refuses to compile it (rc 5) -> unknown" "$(FAKE_ENGINE_MODE=rc5 st weak)" "unknown"
eq "... the production file is untouched after all of them" "$(W_SUM)" "$W0"
hgreset
use_list link.sh "$SEL_T" "$ID_LIM"
eq "a SYMLINKED subject (the fake engine would happily write a mutant) -> unknown, never written through" "$(FAKE_ENGINE_MODE=garbage st trivial "$F_T")" "unknown"
eq "... the file the link points at, outside the tree, is unchanged" "$(cksum < "$TMPD/outside/outside.sh") $(cksum < "$TMPD/outside/dir/x.sh")" "$OUT_SUM"
eq "... and no mutant was ever run (control only)" "$(nlines "$FAKE_HG_LOG")" "1"
bdset $BEAD "ARQUIVO packs/town-deltas/assets/linkdir/x.sh (1)
  L2 [x] a -> b  id=$ID_LIM  (testes: $SEL_T)" "$LBL_M"; hgreset
eq "a subject under a SYMLINKED DIRECTORY that leaves the worktree -> unknown, never written through" "$(FAKE_ENGINE_MODE=garbage st trivial "$F_T")" "unknown"
eq "... the file outside is unchanged" "$(cksum < "$TMPD/outside/outside.sh") $(cksum < "$TMPD/outside/dir/x.sh")" "$OUT_SUM"
eq "... and no mutant was ever run (control only)" "$(nlines "$FAKE_HG_LOG")" "1"
use_list no-such-file.sh "$SEL_T" "$ID_LIM"; hgreset
eq "a subject that does not exist in the worktree -> unknown" "$(FAKE_ENGINE_MODE=garbage st trivial "$F_T")" "unknown"
use_list ../../../../../outside/outside.sh "$SEL_T" "$ID_LIM"; hgreset
eq "a subject path that climbs out of the worktree with .. -> unknown" "$(FAKE_ENGINE_MODE=garbage st trivial "$F_T")" "unknown"
eq "... the file outside is unchanged" "$(cksum < "$TMPD/outside/outside.sh") $(cksum < "$TMPD/outside/dir/x.sh")" "$OUT_SUM"
export GATE_ABT_MUTATE="$ENGINE"
use_list risky.sh "$SEL_T" "$ID_RISKY"; hgreset
RISKY0=$(cksum < "$WT/$A/risky.sh")
eq "a production file whose text cites sudo: the real engine refuses (rc 6) -> unknown" "$(st trivial "$F_T")" "unknown"
eq "... file untouched, only the control ran" "$(cksum < "$WT/$A/risky.sh") $(nlines "$FAKE_HG_LOG")" "$RISKY0 1"

echo "  -- defaults: the wrapper and the engine come from \$GC_CITY/scripts --"
# The guard assigns GC_CITY itself when it is sourced (GC_CITY="/Users/athos/gt/.gascity-gastown-hq"), so an environment
# value would be overwritten: the child shells below set it AFTER sourcing, which is what the functions read.
mkdir -p "$TMPD/city/scripts"
cp "$TMPD/bin/hg-stub.sh" "$TMPD/city/scripts/heavy-guard.sh"
cp "$ENGINE" "$TMPD/city/scripts/hq-mutate.py"
use_list widget.sh "$SEL_W" "$ID_LIM"; hgreset
eq "no overrides, GC_CITY set: both come from \$GC_CITY/scripts -> killed" \
  "$(env -u GATE_ABT_HEAVY_GUARD -u GATE_ABT_MUTATE bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; set +e; GC_CITY="$9"; gate_base_test_mutants_state "$2" "$3" "$4" "$5" "$6" "$7" "$8"' _ "$GUARD" "$REPO" "$BASE" "$(tip kills)" "$WT" "$F_W" "$STORE" "$BEAD" "$TMPD/city")" "killed"
eq "... through that heavy-guard (3 runs logged)" "$(nlines "$FAKE_HG_LOG")" "3"
hgreset
eq "no overrides and GC_CITY empty: nothing to run -> unknown" \
  "$(env -u GATE_ABT_HEAVY_GUARD -u GATE_ABT_MUTATE bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; set +e; GC_CITY="$9"; gate_base_test_mutants_state "$2" "$3" "$4" "$5" "$6" "$7" "$8"' _ "$GUARD" "$REPO" "$BASE" "$(tip kills)" "$WT" "$F_W" "$STORE" "$BEAD" "")" "unknown"
rm -f "$TMPD/city/scripts/heavy-guard.sh"
eq "engine present but heavy-guard.sh missing from \$GC_CITY/scripts -> unknown (the run is never made without it)" \
  "$(env -u GATE_ABT_HEAVY_GUARD -u GATE_ABT_MUTATE bash -c 'GATE_GUARD_LIB_ONLY=1 . "$1"; set +e; GC_CITY="$9"; gate_base_test_mutants_state "$2" "$3" "$4" "$5" "$6" "$7" "$8"' _ "$GUARD" "$REPO" "$BASE" "$(tip kills)" "$WT" "$F_W" "$STORE" "$BEAD" "$TMPD/city")" "unknown"

echo "  -- gate_base_test_sandbox_exec: the wrapper is opt-in, and the pytest/js runs never get it --"
SBX_SCR="$TMPD/sbx"; mkdir -p "$SBX_SCR"
hgreset
gate_base_test_sandbox_exec "$SBX_SCR" 10 "$TMPD" /bin/echo hi; _rc=$?
eq "default call (the pytest/js runs): runs the command, rc 0" "$_rc" "0"
eq "... and the heavy-guard stand-in was not involved (it is exported in this shell and still not called)" "$(nlines "$FAKE_HG_LOG")" "0"
eq "... the command's output is in run.log" "$(cat "$SBX_SCR/run.log")" "hi"
GATE_ABT_RUN_GUARD="$TMPD/bin/hg-stub.sh" gate_base_test_sandbox_exec "$SBX_SCR" 10 "$TMPD" /bin/echo hi; _rc=$?
eq "with GATE_ABT_RUN_GUARD set: rc 0 and the command ran" "$_rc $(cat "$SBX_SCR/run.log")" "0 hi"
eq "... through the wrapper, asked for the disk watch and the write cap" "$(cat "$FAKE_HG_LOG" | sed 's#| .*##')" "--what selftest-gate-abt --max-file-mb 512 -- "
hgreset
GATE_ABT_RUN_GUARD="$TMPD/bin/no-such-wrapper" gate_base_test_sandbox_exec "$SBX_SCR" 10 "$TMPD" /usr/bin/touch "$SBX_SCR/ran-marker"; _rc=$?
eq "GATE_ABT_RUN_GUARD set to something that is not executable -> 97 (not run)" "$_rc" "97"
eq "... and the command did not start" "$([ -e "$SBX_SCR/ran-marker" ] && echo started || echo not-started)" "not-started"
GATE_ABT_RUN_GUARD="$TMPD/bin/hg-stub.sh" FAKE_HG_RC=75 gate_base_test_sandbox_exec "$SBX_SCR" 10 "$TMPD" /bin/echo hi; _rc=$?
eq "the wrapper's own refusal (rc 75) is what sandbox_exec returns" "$_rc" "75"
hgreset

# ── 3. the engine's apply, called directly ───────────────────────────────────────────────────────────
echo "── 3. hq-mutate.py apply ──"
AP() { python3 -I "$ENGINE" apply "$@" >/dev/null 2>&1; echo $?; }
W_ORIG=$(cksum < "$REPO/$A/widget.sh")
eq "apply the boundary mutant: rc 0" "$(AP "$REPO/$A/widget.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut.out")" "0"
eq "... the output is the file with -gt turned into -ge" "$(diff "$REPO/$A/widget.sh" "$TMPD/mut.out" | grep -c '^[<>]')" "2"
eq "... exactly that substitution" "$(grep -c -- '-ge 10' "$TMPD/mut.out")" "1"
eq "... the source file itself is untouched" "$(cksum < "$REPO/$A/widget.sh")" "$W_ORIG"
eq "an id that does not exist in the file: rc 4" "$(AP "$REPO/$A/widget.sh" --tree "$HQ" --id 0000000000 --out "$TMPD/mut2.out")" "4"
eq "... and nothing is written" "$([ -e "$TMPD/mut2.out" ] && echo written || echo none)" "none"
eq "a file that cannot be read: rc 3 or 6, never 0" "$(AP "$HQ/nope.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut3.out" | grep -cE '^[36]$')" "1"
eq "a symlinked subject: rc 6" "$(AP "$REPO/$A/link.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut4.out")" "6"
eq "a subject under a symlinked directory: rc 6" "$(AP "$REPO/$A/linkdir/x.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut5.out")" "6"
eq "a selftest as the subject: rc 6 (the engine never mutates its own tests)" "$(AP "$REPO/$A/widget.selftest.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut6.out")" "6"
eq "a file outside the tree: rc 6" "$(AP "$TMPD/outside/outside.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut7.out")" "6"
eq "a subject whose text cites sudo: rc 6" "$(AP "$REPO/$A/risky.sh" --tree "$HQ" --id "$ID_RISKY" --out "$TMPD/mut8.out")" "6"
printf '# docker run x\n' > "$TMPD/also.txt"
eq "an --also file whose text cites docker: rc 6" "$(AP "$REPO/$A/widget.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut9.out" --also "$TMPD/also.txt")" "6"
eq "... and nothing is written" "$([ -e "$TMPD/mut9.out" ] && echo written || echo none)" "none"
printf 'ordinary text\n' > "$TMPD/also.txt"
eq "an --also file without any of that: rc 0" "$(AP "$REPO/$A/widget.sh" --tree "$HQ" --id "$ID_LIM" --out "$TMPD/mut9.out" --also "$TMPD/also.txt")" "0"
eq "apply without --id: argparse refuses (rc 2), the guard reads that as unknown" "$(AP "$REPO/$A/widget.sh" --tree "$HQ" --out "$TMPD/mut10.out")" "2"

fi

# ── 4. drift guards ──────────────────────────────────────────────────────────────────────────────────
echo "── 4. drift guards ──"
code_of() { sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d'; }   # no comments: only what runs
SEC=$(awk '/^# ── Mutant-hardening slices \(ga-4kykayr\)/{p=1} /^gate_base_test_outside_subtree\(\)/{p=0} p' "$GUARD")
[ -n "$SEC" ] && ok "the mutant-hardening section is in the guard" || bad "the mutant-hardening section was not found in the guard"
eq "the section defines its five functions" "$(printf '%s\n' "$SEC" | grep -cE '^(gate_base_test_mutants_declared|gate_base_test_mutant_list|gate_base_test_mutant_rc_class|_gate_base_test_mutant_run|gate_base_test_mutants_state)\(\)')" "5"
eq "no code line of the guard names ga-iu0fvlo or its marker ga-1iur59y (the path hangs off the declaration and the measurement)" \
  "$(code_of < "$GUARD" | grep -cE 'ga-iu0fvlo|ga-1iur59y')" "0"
eq "the section never reads the arm (no gate_ab_arm_for_bead, no ARM variable)" "$(printf '%s\n' "$SEC" | code_of | grep -cE 'gate_ab_arm_for_bead|_ARM|ARM=')" "0"
eq "the section never branches on a bead id's text (no case on \$bead / \$BEAD_ID patterns)" "$(printf '%s\n' "$SEC" | code_of | grep -cE 'case "\$\{?(bead|BEAD_ID)')" "0"
eq "GATE_ABT_RUN_GUARD is assigned in exactly one place, as a local of the mutant run" \
  "$(code_of < "$GUARD" | grep -E 'GATE_ABT_RUN_GUARD=' | sed 's/^[[:space:]]*//' | cut -c1-40 | sort -u)" 'local GATE_ABT_RUN_GUARD="${GATE_ABT_HEA'
eq "... and nothing exports it or GATE_ABT_HEAVY_GUARD" "$(code_of < "$GUARD" | grep -cE 'export[^;|&]*(GATE_ABT_RUN_GUARD|GATE_ABT_HEAVY_GUARD)')" "0"
eq "the wrapper's default is heavy-guard.sh under \$GC_CITY/scripts" "$(printf '%s\n' "$SEC" | code_of | grep -c 'GATE_ABT_HEAVY_GUARD:-\${GC_CITY:-}/scripts/heavy-guard.sh')" "1"
eq "the engine's default is hq-mutate.py under \$GC_CITY/scripts, run with python3 -I" \
  "$(printf '%s\n' "$SEC" | code_of | grep -cE 'GATE_ABT_MUTATE:-\$\{GC_CITY:-\}/scripts/hq-mutate.py|"\$py" -I "\$mut" apply')" "2"
eq "the engine's apply and the sandboxed run both detach stdin (they sit inside here-doc fed read loops)" \
  "$(printf '%s\n' "$SEC" | code_of | grep -cE '(apply .*|bash "\$sel" )</dev/null')" "2"
eq "the only rm -rf in the section is of the one mktemp root" "$(printf '%s\n' "$SEC" | code_of | grep 'rm -rf' | grep -vc 'rm -rf "\$root"')" "0"
eq "the sandbox profile is the same one the pytest/js runs use (the section calls sandbox_ok and sandbox_exec, writes its own profile nowhere)" \
  "$(printf '%s\n' "$SEC" | code_of | grep -cE 'gate_base_test_sandbox_ok|gate_base_test_sandbox_exec|sandbox-exec')" "2"
eq "sandbox_exec adds the wrapper only when GATE_ABT_RUN_GUARD is set, as 97 when it is not executable" \
  "$(awk '/^gate_base_test_sandbox_exec\(\)/,/^}/' "$GUARD" | code_of | grep -cE 'GATE_ABT_RUN_GUARD:-|\[ -x "\$GATE_ABT_RUN_GUARD" \] \|\| return 97|--what selftest-gate-abt --max-file-mb 512 --')" "3"
eq "scripts/hetzner-mac-only.hq.txt lists this selftest (it needs sandbox-exec)" \
  "$(grep -c '^packs/town-deltas/assets/gate-guard-ab-base-test-mutants.selftest.sh$' "$SELF_DIR/../../../scripts/hetzner-mac-only.hq.txt")" "1"
/bin/bash -n "$GUARD" 2>/dev/null && ok "guard passes /bin/bash -n (the macOS system bash 3.2 reads it)" || bad "guard does not parse under /bin/bash"
/bin/bash -n "${BASH_SOURCE[0]}" 2>/dev/null && ok "this selftest passes /bin/bash -n" || bad "this selftest does not parse under /bin/bash"

echo ""
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
