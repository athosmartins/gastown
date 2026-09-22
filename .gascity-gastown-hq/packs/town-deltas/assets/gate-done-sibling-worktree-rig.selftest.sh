#!/usr/bin/env bash
# gate-done-sibling-worktree-rig.selftest.sh (ga-mxwg89)
#
# Proves /gate-done's sibling-worktree rig check by EXECUTING THE SHIPPED BLOCK —
# extracted verbatim from gate-done.md between its SELFTEST-EXTRACT sentinels —
# under BOTH bash and zsh, against a real git fixture (bare origin + outer clone +
# sibling worktrees) built under one mktemp dir. Nothing here touches the live
# town: every repo, worktree and path lives under that dir, and git runs with a
# hermetic environment (no user config, hooks or inherited GIT_DIR).
#
# Root bug (ga-mxwg89, filed by gastown.dog-1 from a live incident, 21/09): this
# city's own worktree recipe (`git worktree add .gc-worktrees/<name> ...` run from
# ~/gt) parks the worktree as a SIBLING of .gascity-gastown-hq, so neither PRIMARY
# (ga-owfll) nor ga-6mir5's reverse containment recognises it and RIG fell through
# to "unknown". The fix resolves rig=gascity when the worktree's origin matches
# HQ's own AND every file changed since BASE_COMMIT falls under HQ's subtree.
#
# Why THIS file exists (ga-mxwg89 gate attempt 1, reviewer 1/1 CORRECTNESS):
#   The first cut walked the changed-file list with `for f in $list`. That only
#   works where an unquoted parameter is word-split — bash. Every agent session in
#   this city runs /gate-done under zsh (SHELL=/bin/zsh, and the Bash tool execs
#   /bin/zsh), which does NOT split it: the loop ran ONCE over the whole
#   multi-line list and the trailing * of "$prefix"/* swallowed every newline, so
#   "EVERY changed file is under the subtree" degraded to "the alphabetically-first
#   changed path is" — and .gascity-gastown-hq/ sorts ahead of docs/, gastown/,
#   internal/ and packs/. The suite meant to catch that was green anyway:
#   gate-done-crew-rig.selftest.sh's old (AB1)-(AB5) called a bash REPLICA of the
#   block fed pre-split strings, so nothing ever ran the shipped code, and never
#   in zsh. This file closes both holes: it runs the real block, in both shells.
#
# Covers (each scenario under every available shell):
#   in1 / in2 / in_space   every changed file under the subtree → gascity
#                          (in_space: a path with spaces must not be mis-split)
#   mix_internal, mix_gastown, mix4
#                          in-subtree files PLUS outside ones → abstain. The
#                          in-subtree path sorts first: the exact shape the zsh
#                          split bug mis-resolved to gascity.
#   outside_only           nothing under the subtree → abstain
#   rename_in              a file MOVED from outside into the subtree → abstain
#                          (needs --no-renames: default rename detection lists
#                          only the new path)
#   empty_diff, bad_base   empty / unreadable diff → abstain, never vacuous
#   distinct               different origin than HQ's → abstain even though every
#                          changed path is under the subtree
#   preset_rig             RIG already resolved upstream → left untouched
#   (mutation)             the OLD `for f in $list` shape still mis-classifies
#                          under this zsh, so the mix scenarios can discriminate
#
# Exit 0 iff every assertion holds. zsh scenarios are skipped (loudly) only when
# zsh is not installed.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (same priority as the sibling gate-done selftests):
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-done-sibling-worktree-rig.selftest =="

command -v git >/dev/null 2>&1 || { echo "git required"; exit 2; }

# Hermetic git: the fixture must neither depend on nor be perturbed by the
# caller's git config, hooks, identity, or an inherited GIT_DIR/GIT_WORK_TREE
# (which would silently point every `git -C` below at the WRONG repository).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
      GIT_CEILING_DIRECTORIES
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-done-sib.XXXXXX")" || { echo "mktemp failed"; exit 2; }
cleanup() {
  # Only ever remove the directory this run created.
  case "$(basename "$T")" in
    gate-done-sib.*) [ -d "$T" ] && rm -rf "$T" ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$T/home"
export HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config"   # older gits ignore GIT_CONFIG_GLOBAL

SHELLS=(bash)
if command -v zsh >/dev/null 2>&1; then
  SHELLS+=(zsh)
else
  echo "  (skip) zsh is not installed — the zsh half of this suite is NOT being run"
fi

# extract_sentinel_block <file> <name> — prints the lines strictly BETWEEN the
# "# SELFTEST-EXTRACT <name>: BEGIN" / ": END" sentinels. Fails (message on
# stderr, non-zero) unless each sentinel occurs exactly once and END follows
# BEGIN: a sed range with a missing END would otherwise silently run to EOF.
extract_sentinel_block() {
  local file="$1" name="$2" nb ne
  nb=$(grep -cF "# SELFTEST-EXTRACT ${name}: BEGIN" "$file")
  ne=$(grep -cF "# SELFTEST-EXTRACT ${name}: END" "$file")
  if [ "$nb" -ne 1 ] || [ "$ne" -ne 1 ]; then
    echo "expected exactly one BEGIN and one END sentinel for '${name}', found BEGIN=$nb END=$ne" >&2
    return 1
  fi
  awk -v b="# SELFTEST-EXTRACT ${name}: BEGIN" -v e="# SELFTEST-EXTRACT ${name}: END" '
    index($0, b) { inblk = 1; next }
    index($0, e) { if (inblk) closed = 1; exit }
    inblk        { print }
    END          { exit (closed ? 0 : 1) }' "$file" \
    || { echo "'${name}': END sentinel does not follow BEGIN" >&2; return 1; }
}

# ── (SW0) the shipped block must be extractable and must parse in every shell ──
RUN_MATRIX=0
if [ ! -f "$GATE_DONE" ]; then
  bad "(SW0) gate-done.md not found at $GATE_DONE"
elif extract_sentinel_block "$GATE_DONE" sibling-worktree-rig > "$T/block.sh" 2> "$T/extract.err" \
     && [ -s "$T/block.sh" ]; then
  ok "(SW0) extracted the shipped block from gate-done.md via its SELFTEST-EXTRACT sentinels ($(wc -l < "$T/block.sh" | tr -d ' ') lines)"
  RUN_MATRIX=1
  for sh in "${SHELLS[@]}"; do
    if "$sh" -n "$T/block.sh" 2> "$T/parse.err"; then
      ok "(SW0/$sh) the extracted block parses"
    else
      bad "(SW0/$sh) the extracted block does not parse: $(head -c 300 "$T/parse.err")"
      RUN_MATRIX=0
    fi
  done
else
  bad "(SW0) could not extract the sibling-worktree-rig block from $GATE_DONE: $(cat "$T/extract.err" 2>/dev/null)"
fi

# ── (SW1) fixture: bare origin + outer clone, sibling worktrees, one scenario each ──
#
#   $T/origin.git                      bare origin
#   $T/outer/                          the "outer repo" (~/gt in the real town)
#   $T/outer/.gascity-gastown-hq/      $GC_CITY_PATH: a tracked SUBDIR, no .git of its own
#   $T/outer/.gc-worktrees/<name>/     SIBLING worktrees — the shape ga-mxwg89 is about
#   $T/outer2/                         a clone whose origin URL differs from HQ's
OUTER="$T/outer"
CITY="$OUTER/.gascity-gastown-hq"
SUBTREE=".gascity-gastown-hq"

# put_file <dir> <relpath> — create or append to a file (each gets a unique body).
put_file() { mkdir -p "$(dirname "$1/$2")" && printf 'change to %s\n' "$2" >> "$1/$2"; }
# commit_all <dir> <msg>
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
# mk_wt <name> — a SIBLING worktree of $OUTER on a fresh branch; prints its physical toplevel.
mk_wt() {
  git -C "$OUTER" worktree add -q -b "fx-$1" "$OUTER/.gc-worktrees/$1" main 2>/dev/null \
    && git -C "$OUTER/.gc-worktrees/$1" rev-parse --show-toplevel
}
# diff_shape <dir> — "<changed paths>/<of which outside the subtree>", as the block sees them.
diff_shape() {
  git -C "$1" diff --name-only --no-renames "$BASE"...HEAD 2>/dev/null \
    | awk -v p="$SUBTREE/" '{ if (index($0, p) != 1) out++ } END { printf "%d/%d", NR, out + 0 }'
}

WT_IN1=""; WT_IN2=""; WT_INSP=""; WT_MIXI=""; WT_MIXG=""; WT_MIX4=""
WT_OUT=""; WT_REN=""; WT_EMPTY=""; WT_DIST=""; BASE=""
build_fixture() {
  git init -q --bare "$T/origin.git" || return 1
  git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/main || return 1
  git clone -q "$T/origin.git" "$OUTER" 2>/dev/null
  git -C "$OUTER" symbolic-ref HEAD refs/heads/main || return 1
  put_file "$OUTER" "$SUBTREE/commands/base.md"
  put_file "$OUTER" "$SUBTREE/packs/town-deltas/assets/base.sh"
  put_file "$OUTER" gastown/base.md
  put_file "$OUTER" internal/base.md
  put_file "$OUTER" docs/base.md
  put_file "$OUTER" packs/base.md
  # A body long enough that a rename of it is unambiguous to git's detector.
  { i=0; while [ "$i" -lt 20 ]; do echo "line $i of a file that will be moved into the subtree"; i=$((i+1)); done; } > "$OUTER/docs/moved.md"
  commit_all "$OUTER" base || return 1
  git -C "$OUTER" push -q -u origin main 2>/dev/null || return 1
  BASE="$(git -C "$OUTER" rev-parse origin/main)" || return 1

  WT_IN1=$(mk_wt in1)  || return 1
  put_file "$WT_IN1" "$SUBTREE/packs/town-deltas/assets/a.sh"
  commit_all "$WT_IN1" in1 || return 1

  WT_IN2=$(mk_wt in2)  || return 1
  put_file "$WT_IN2" "$SUBTREE/packs/town-deltas/assets/a.sh"
  put_file "$WT_IN2" "$SUBTREE/commands/b.md"
  commit_all "$WT_IN2" in2 || return 1

  WT_INSP=$(mk_wt in_space) || return 1
  put_file "$WT_INSP" "$SUBTREE/dir with space/x y.md"
  commit_all "$WT_INSP" in_space || return 1

  WT_MIXI=$(mk_wt mix_internal) || return 1
  put_file "$WT_MIXI" "$SUBTREE/packs/town-deltas/assets/a.sh"
  put_file "$WT_MIXI" internal/i.md
  commit_all "$WT_MIXI" mix_internal || return 1

  WT_MIXG=$(mk_wt mix_gastown) || return 1
  put_file "$WT_MIXG" "$SUBTREE/packs/town-deltas/assets/a.sh"
  put_file "$WT_MIXG" gastown/g.md
  commit_all "$WT_MIXG" mix_gastown || return 1

  WT_MIX4=$(mk_wt mix4) || return 1
  put_file "$WT_MIX4" "$SUBTREE/packs/town-deltas/assets/a.sh"
  put_file "$WT_MIX4" "$SUBTREE/commands/b.md"
  put_file "$WT_MIX4" docs/d.md
  put_file "$WT_MIX4" packs/p.md
  commit_all "$WT_MIX4" mix4 || return 1

  WT_OUT=$(mk_wt outside_only) || return 1
  put_file "$WT_OUT" gastown/g.md
  commit_all "$WT_OUT" outside_only || return 1

  WT_REN=$(mk_wt rename_in) || return 1
  git -C "$WT_REN" mv docs/moved.md "$SUBTREE/moved.md" || return 1
  commit_all "$WT_REN" rename_in || return 1

  WT_EMPTY=$(mk_wt empty) || return 1        # no commit: nothing changed since BASE

  # A separate clone of the SAME history whose origin URL differs from HQ's: the
  # only thing that should stop it resolving is the origin comparison.
  git clone -q "$T/origin.git" "$T/outer2" 2>/dev/null || return 1
  git -C "$T/outer2" remote set-url origin "$T/origin2.git" || return 1
  git -C "$T/outer2" checkout -q -b fx-distinct || return 1
  put_file "$T/outer2" "$SUBTREE/packs/town-deltas/assets/a.sh"
  commit_all "$T/outer2" distinct || return 1
  WT_DIST="$(git -C "$T/outer2" rev-parse --show-toplevel)" || return 1
}

if [ "$RUN_MATRIX" -eq 1 ]; then
  if build_fixture; then
    ok "(SW1) fixture built: bare origin, outer clone, 10 sibling worktrees, 1 distinct-origin clone"
  else
    bad "(SW1) fixture build failed — the matrix below would pass or fail for the wrong reason, so it is NOT run"
    RUN_MATRIX=0
  fi
fi

# Every abstain scenario below is only meaningful if its worktree really holds the
# change set it claims to (otherwise "abstain" could just mean "nothing was there").
# Verify the diff SHAPE the block will see, and that the rename premise holds.
if [ "$RUN_MATRIX" -eq 1 ]; then
  shape_ok=1
  for spec in "in1:$WT_IN1:1/0" "in2:$WT_IN2:2/0" "in_space:$WT_INSP:1/0" \
              "mix_internal:$WT_MIXI:2/1" "mix_gastown:$WT_MIXG:2/1" "mix4:$WT_MIX4:4/2" \
              "outside_only:$WT_OUT:1/1" "rename_in:$WT_REN:2/1" "empty:$WT_EMPTY:0/0" \
              "distinct:$WT_DIST:1/0"; do
    name="${spec%%:*}"; rest="${spec#*:}"; dir="${rest%:*}"; want="${rest##*:}"
    got="$(diff_shape "$dir")"
    if [ "$got" != "$want" ]; then
      bad "(SW1) fixture '$name' holds changed/outside='$got', expected '$want'"
      shape_ok=0
    fi
  done
  [ "$shape_ok" -eq 1 ] && ok "(SW1) every scenario's worktree holds exactly the change set it claims (changed/outside paths)"
  # rename_in must reach the block as a rename that DEFAULT git collapses to one
  # in-subtree path — else the scenario would pass even without --no-renames.
  rn="$(git -C "$WT_REN" diff --name-only "$BASE"...HEAD 2>/dev/null | awk '{ n++ } END { print n + 0 }')"
  if [ "$rn" = "1" ]; then
    ok "(SW1) rename_in premise: default rename detection collapses the move to ONE (in-subtree) path"
  else
    bad "(SW1) rename_in premise: default git reported $rn paths, expected 1 — the --no-renames scenario would not discriminate"
  fi
fi

# ── (SW2) run the extracted block, verbatim, under each shell ──
if [ "$RUN_MATRIX" -eq 1 ]; then
  {
    echo 'RIG="$AC_RIG"; GC_CITY_PATH="$AC_CITY"; CWD_TOP="$AC_CWD"; BASE_COMMIT="$AC_BASE"'
    cat "$T/block.sh"
    echo 'printf "__RIG__=%s\n" "$RIG"'
  } > "$T/driver.sh"
fi

# run_file <shell> <file> — run a script file in a clean, rc-less shell of that kind
# (bash: no profile/rc; zsh -f: default options, so SH_WORD_SPLIT is off — exactly
# what the agents' live Bash tool runs).
run_file() {
  case "$1" in
    bash) env -u BASH_ENV -u ENV bash --noprofile --norc "$2" ;;
    zsh)  env -u BASH_ENV -u ENV zsh -f "$2" ;;
  esac
}

# run_block <shell> <rig_init> <cwd_top> <base_commit> — prints the RIG the block
# left behind (empty == abstained). Prints __CRASH__ if the driver never reached
# its end marker: a block that dies must not read as "abstained" (error and empty
# are different answers).
run_block() {
  local sh="$1" rig_init="$2" cwd="$3" base="$4" out res
  out=$(AC_RIG="$rig_init" AC_CITY="$CITY" AC_CWD="$cwd" AC_BASE="$base" \
        run_file "$sh" "$T/driver.sh" 2> "$T/stderr.txt")
  res=$(printf '%s\n' "$out" | awk '/^__RIG__=/ { found = 1; v = substr($0, 9) } END { if (found) print "OK:" v; else print "CRASH" }')
  case "$res" in
    OK:*) printf '%s' "${res#OK:}" ;;
    *)    printf '__CRASH__' ;;
  esac
}

# check <label> <shell> <want> <rig_init> <cwd_top> <base_commit> — want "" == abstain.
check() {
  local label="$1" sh="$2" want="$3" got
  shift 3
  got="$(run_block "$sh" "$@")"
  if [ "$got" = "$want" ]; then
    ok "(SW2/$sh) $label → ${want:-abstain}"
  elif [ "$got" = "__CRASH__" ]; then
    bad "(SW2/$sh) $label: the block crashed — $(head -c 300 "$T/stderr.txt")"
  else
    bad "(SW2/$sh) $label: expected '${want:-abstain}', got '${got:-abstain}'"
  fi
}

if [ "$RUN_MATRIX" -eq 1 ]; then
  for sh in "${SHELLS[@]}"; do
    check "in1: single change under the subtree"                  "$sh" gascity "" "$WT_IN1"   "$BASE"
    check "in2: two changes, both under the subtree"              "$sh" gascity "" "$WT_IN2"   "$BASE"
    check "in_space: a path with spaces is not mis-split"         "$sh" gascity "" "$WT_INSP"  "$BASE"
    check "mix_internal: subtree + internal/ (subtree sorts first)" "$sh" ""    "" "$WT_MIXI"  "$BASE"
    check "mix_gastown: subtree + gastown/ (subtree sorts first)" "$sh" ""      "" "$WT_MIXG"  "$BASE"
    check "mix4: two in-subtree + docs/ + packs/"                 "$sh" ""      "" "$WT_MIX4"  "$BASE"
    check "outside_only: nothing under the subtree"               "$sh" ""      "" "$WT_OUT"   "$BASE"
    check "rename_in: a file moved INTO the subtree from docs/"   "$sh" ""      "" "$WT_REN"   "$BASE"
    check "empty_diff: no changed file since base"                "$sh" ""      "" "$WT_EMPTY" "$BASE"
    check "bad_base: unreadable diff (unknown base commit)"       "$sh" ""      "" "$WT_IN1"   "not-a-commit"
    check "distinct: origin differs from HQ's, all paths in-subtree" "$sh" ""   "" "$WT_DIST"  "$BASE"
    check "preset_rig: RIG already resolved upstream is untouched" "$sh" wa     "wa" "$WT_IN1" "$BASE"
  done
fi

# ── (SW3) mutation guard: the class this harness exists to catch ──
# The FIRST cut's loop shape, in isolation. Under bash it classifies the mix
# correctly (outside=1) — which is why a bash-only suite never saw the bug. Under
# zsh it runs once over the whole string and reports outside=0. If zsh ever stops
# doing that, the mix scenarios above lose their power to discriminate — say so.
cat > "$T/oldshape.sh" <<'OLDSHAPE'
list=".gascity-gastown-hq/a.sh
internal/i.md"
outside=0
old_ifs="$IFS"; IFS='
'
for f in $list; do
  case "$f" in ".gascity-gastown-hq"/*) : ;; *) outside=1 ;; esac
done
IFS="$old_ifs"
printf 'outside=%s\n' "$outside"
OLDSHAPE
for sh in "${SHELLS[@]}"; do
  got="$(run_file "$sh" "$T/oldshape.sh" 2>/dev/null)"
  case "$sh" in
    bash)
      [ "$got" = "outside=1" ] \
        && ok "(SW3/bash) old loop shape is correct under bash (outside=1) — why a bash-only suite could not see ga-mxwg89" \
        || bad "(SW3/bash) old loop shape gave '$got' under bash, expected outside=1 — harness premise is off"
      ;;
    zsh)
      [ "$got" = "outside=0" ] \
        && ok "(SW3/zsh) mutation check: old loop shape mis-classifies a mixed diff as all-inside under this zsh (outside=0), so the (SW2) mix scenarios can catch the class" \
        || bad "(SW3/zsh) old loop shape gave '$got' under zsh, expected outside=0 — the mix scenarios have lost their power to discriminate; revisit this suite"
      ;;
  esac
done

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"
