#!/usr/bin/env bash
# gate-e6b-union-content-verdict.selftest.sh (ga-5w2gpw item b, 2026-09-30)
#
# CLASS: the merge-time content guard (ga-m07gc) refuses to push when the tree the rebase/merge produced differs from the reference
# 3-way merge (`merge-tree --write-tree`). For a `merge=union` path that comparison is the WRONG question: union keeps BOTH sides'
# lines and is not associative, so a commit-by-commit rebase and one union of the end states differ by ORDER, by a residue line, or
# by a duplicated block — with no line lost. whatsapp_automation declares that for docs/data_dictionary.md (the append-only atlas)
# and the gate refused 3 pushes on 30/09 alone, each failing a review-approved PASS as `failed_merge_time_rebase` (E4 §1; ga-ub5hkz
# fixed the sibling deploy_deps.json case).
#
# FIX under test: when EVERY differing path is declared merge=union (from new_tip's .gitattributes, as ga-stisew does) the verdict
# asks "was any line LOST?" by multiset arithmetic over merge-base, main, branch tip and resulting tip. Anything else stays as before.
#
# ASYMMETRIC on purpose: the lossless divergences must read "yes" and every way a union file can really lose content must still read
# "no" — a guard that only ever says yes is not a guard. Fixtures are real git repos and real `git rebase` runs; the four lossless
# histories were found by brute force and encoded verbatim. Three states, never two: a blob that cannot be read, a path that is not a
# regular file, a blob past the size cap or a diff that errors is `unknown:union-*` — and section 6 pins which of those the gate acts
# on as "no" (they reproduce) and which stay unknown (they may not).
# Strategy: the live `gate-rebase-content-verdict` block is extracted by sentinel and run against the repos. bash 3.2 compatible.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-e6b-union-content-verdict.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
if /bin/bash -n "$DISPATCHER" 2>/dev/null; then ok "dispatcher parses under /bin/bash (3.2)"; else bad "dispatcher does NOT parse under /bin/bash 3.2"; fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e6b.XXXXXX")"
trap 'safe-clean "$TMP" >/dev/null 2>&1 || true' EXIT

sed -n '/SELFTEST-EXTRACT gate-rebase-content-verdict: BEGIN/,/SELFTEST-EXTRACT gate-rebase-content-verdict: END/p' "$DISPATCHER" > "$TMP/block.sh"
grep -q "rebase_content_verdict()" "$TMP/block.sh" || { echo "FATAL: sentinels do not delimit rebase_content_verdict" >&2; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@t

# ── fixture helpers ──────────────────────────────────────────────────────────
# cf <repo> "<line|line|…>" <msg> — write docs/dd.md (one line per `|`) and commit.
# DDFILE (default docs/dd.md) names the union file; BIGPAD=N prepends N untouched filler lines of ~80 bytes (a LARGE union file).
DDFILE="docs/dd.md"; BIGPAD=0
cf() {
  mkdir -p "$(dirname "$1/$DDFILE")"
  { if [ "$BIGPAD" -gt 0 ]; then awk -v n="$BIGPAD" 'BEGIN { for (i = 1; i <= n; i++) printf "pad-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }'; fi
    printf '%s' "$2" | tr '|' '\n'; printf '\n'; } > "$1/$DDFILE"
  git -C "$1" add -A; git -C "$1" commit -qm "$3"
}
# mkbase <repo> — `main` with the union declaration (and a custom, NON-union driver line, like the real rig).
mkbase() {
  mkdir -p "$1"; git -C "$1" init -q -b main
  printf '%s merge=union\ndaemons/deps.json merge=deploydeps\n' "$DDFILE" > "$1/.gitattributes"
  echo base-other > "$1/other.txt"
  cf "$1" "H|t1|t2|t3|t4" base
}
# rebase_onto_main <repo> — detach at feat, real `git rebase main`; echoes the new tip.
rebase_onto_main() {
  git -C "$1" checkout -q --detach feat
  git -C "$1" rebase -q main >/dev/null 2>&1 || { git -C "$1" rebase --abort >/dev/null 2>&1; echo ""; return 1; }
  git -C "$1" rev-parse HEAD
}
verdict() { # verdict <repo> <new_tip>   (MAIN/FEAT globals)
  ( . "$TMP/block.sh"; rebase_content_verdict "$1" "$MAIN" "$FEAT" "$2" )
}
# ref_tree <repo> — the reference tree exactly as the gate computes it (filtered attributes, shared git-dir).
ref_tree() {
  local a="$TMP/attrs.$$"; printf '%s merge=union\n' "$DDFILE" > "$a"
  git --git-dir="$(git -C "$1" rev-parse --absolute-git-dir)" -c core.attributesFile="$a" merge-tree --write-tree "$MAIN" "$FEAT" 2>/dev/null | head -1
}
# ── 1. the four LOSSLESS divergences (found by brute force, encoded verbatim) ──
echo "── 1. lossless union divergences: the trees differ, no line is lost → yes ──"
build_hist() { # build_hist <name> <main1;main2..> <branch1;branch2..>   each item is a full file 'a|b|c'
  local name="$1" R="$TMP/$1" c i
  mkbase "$R"
  git -C "$R" checkout -q -b feat
  i=0; OLDIFS="$IFS"; IFS=';'; set -f; BR=($3); MN=($2); set +f; IFS="$OLDIFS"
  for c in "${BR[@]}"; do cf "$R" "$c" "feat $i"; i=$((i+1)); done
  git -C "$R" checkout -q main
  i=0
  for c in "${MN[@]}"; do cf "$R" "$c" "main $i"; i=$((i+1)); done
  MAIN="$(git -C "$R" rev-parse main)"; FEAT="$(git -C "$R" rev-parse feat)"
  NEW="$(rebase_onto_main "$R")"
  SC_REPO="$R"
}
lossless() { # lossless <label> <name> <main> <branch>
  build_hist "$2" "$3" "$4"
  if [ -z "$NEW" ]; then bad "$1: fixture did not rebase cleanly (union should never conflict)"; return; fi
  local expect actual
  expect="$(ref_tree "$SC_REPO")"; actual="$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")"
  if [ -n "$expect" ] && [ "$expect" != "$actual" ]; then
    ok "$1: precondition — the rebased tree really differs from the reference merge (this is the refused shape)"
  else
    bad "$1: fixture is vacuous — rebased tree equals the reference (expected=[$expect] actual=[$actual])"
  fi
  eq "$1: verdict" "$(verdict "$SC_REPO" "$NEW")" "yes"
}
# residue: an intermediate commit's line survives the rebase
lossless "S1 residue line" s1 \
  "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" \
  "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
# residue, 3 branch commits (append at the end after an edit)
lossless "S2 residue, append after edit" s2 \
  "H|M0|t2|t3|t4;H|M0|t2|t3|t4|M1" \
  "H|t1|t2|t3|B0;H|t1|t2|t3|B1;H|t1|t2|t3|B1|B2"
# a base line the branch edited away is absent from the result while the reference keeps it
lossless "S3 branch edits a base line away" s3 \
  "H|t1|t2|t3|t4|M0" \
  "H|t1|t2|B0|t4;H|t1|t2|B0|B1;H|t1|t2|B2|B0|B1"
# the reference duplicates a block (union of the end states) that the rebase collapses
lossless "S4 duplicated block collapsed" s4 \
  "H|M0|t2|t3|t4;H|M0|t2|t3|t4|M1" \
  "H|B0|t2|t3|t4;H|B0|t2|t3|t4|B1"

# ── 2. every way a union file can REALLY lose content still reads no ─────────
echo "── 2. real losses in a union file still read no ──"
loss() { # loss <label> <name> <mutate-cmd using \$F (the file) and \$R>
  build_hist "$2" "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
  [ -n "$NEW" ] || { bad "$1: fixture did not rebase"; return; }
  local R="$SC_REPO" F="$SC_REPO/$DDFILE"
  git -C "$R" checkout -q --detach "$NEW"
  local before; before="$(git -C "$R" rev-parse "HEAD^{tree}")"
  eval "$3"
  git -C "$R" add -A; git -C "$R" commit -q --amend --no-edit --allow-empty
  if [ "$(git -C "$R" rev-parse "HEAD^{tree}")" = "$before" ]; then
    bad "$1: the mutation changed NOTHING — this case would pass for the wrong reason"; return
  fi
  eq "$1: verdict" "$(verdict "$R" "$(git -C "$R" rev-parse HEAD)")" "no"
}
loss "L1 a line the BRANCH added is gone"        l1 'grep -v "^B1$" "$F" > "$F.n"; mv "$F.n" "$F"'
loss "L2 a line MAIN added is gone"              l2 'grep -v "^M1$" "$F" > "$F.n"; mv "$F.n" "$F"'
loss "L3 an UNTOUCHED line is gone (nobody deleted it)" l3 'grep -v "^t2$" "$F" > "$F.n"; mv "$F.n" "$F"'
loss "L4 the whole file is gone"                 l4 'git -C "$R" rm -q docs/dd.md'
loss "L5 the header line is gone"                l5 'grep -v "^H$" "$F" > "$F.n"; mv "$F.n" "$F"'
loss "L6 conflict markers committed in the file" l6 'printf "<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n" >> "$F"'
# a non-union path differs too: the union arithmetic must NOT whitewash it (mixed set → the old answer)
build_hist mix "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
echo "branch-only content" > "$SC_REPO/other.txt"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
eq "L7 a NON-union path also differs → still no (mixed set is not whitewashed)" "$(verdict "$SC_REPO" "$(git -C "$SC_REPO" rev-parse HEAD)")" "no"

# ── 3. scope: only what .gitattributes at new_tip declares union ─────────────
echo "── 3. scope ──"
build_hist scope "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
git -C "$SC_REPO" rm -q .gitattributes; git -C "$SC_REPO" commit -q --amend --no-edit
R0="$SC_REPO"
V_NOATTR="$(verdict "$R0" "$(git -C "$R0" rev-parse HEAD)")"
# without the declaration at new_tip the file is an ordinary text file: a differing tree is a no
[ "$V_NOATTR" != "yes" ] && ok "union NOT declared at new_tip → the file is ordinary text → verdict is not yes ($V_NOATTR)" || bad "union arithmetic applied to a file not declared union at new_tip"

build_hist custom "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
GDC="$(git -C "$SC_REPO" rev-parse --absolute-git-dir)"
UV="$( . "$TMP/block.sh"; rebase_union_paths_verdict "$GDC" "$MAIN" "$FEAT" "$NEW" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")" 2>&1 )"
eq "direct call, lossless union history" "$UV" "yes"

# a path declared with a CUSTOM driver (merge=deploydeps, like the real rig's deploy_deps.json) is NOT union:
# its difference must fall through ("not-applicable") to the existing deploy_deps logic, never be whitewashed here
mkdir -p "$SC_REPO/daemons"; git -C "$SC_REPO" checkout -q --detach "$NEW"
echo '{"a":1}' > "$SC_REPO/daemons/deps.json"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q -m deps1; T1="$(git -C "$SC_REPO" rev-parse HEAD)"
echo '{"a":2}' > "$SC_REPO/daemons/deps.json"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q -m deps2; T2="$(git -C "$SC_REPO" rev-parse HEAD)"
UV="$( . "$TMP/block.sh"; rebase_union_paths_verdict "$GDC" "$MAIN" "$FEAT" "$T2" "$(git -C "$SC_REPO" rev-parse "${T1}^{tree}")" "$(git -C "$SC_REPO" rev-parse "${T2}^{tree}")" 2>&1 )"
eq "a custom-driver path (merge=deploydeps) is not union → falls through untouched" "$UV" "not-applicable"

echo "── 4. three states: could-not-tell is never yes and never no ──"
GDX="$(git -C "$SC_REPO" rev-parse --absolute-git-dir)"
UV="$( . "$TMP/block.sh"; rebase_union_paths_verdict "$GDX" "$MAIN" "$FEAT" "$NEW" "0000000000000000000000000000000000000000" "$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")" 2>&1 )"
case "$UV" in unknown:union-*) ok "a diff that errors (bad tree id) → $UV" ;; *) bad "bad tree id must be unknown:union-*, got [$UV]" ;; esac
UV="$( . "$TMP/block.sh"; GATE_UNION_VERDICT_MAX_BYTES=8; rebase_union_paths_verdict "$GDX" "$MAIN" "$FEAT" "$NEW" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")" 2>&1 )"
case "$UV" in unknown:union-too-large) ok "a blob past the size cap → $UV (bounded work, not a guess)" ;; *) bad "oversize blob must be unknown:union-too-large, got [$UV]" ;; esac
UV="$( . "$TMP/block.sh"; rebase_union_paths_verdict "$GDX" "$MAIN" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$NEW" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")" 2>&1 )"
case "$UV" in unknown:union-*) ok "an unresolvable branch tip (no merge-base) → $UV" ;; *) bad "unresolvable tip must be unknown:union-*, got [$UV]" ;; esac

# could-not-read is proven through the PUBLIC path too (a mutant that folds these into "nothing lost" must die):
build_hist unread "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
rm -f "$SC_REPO/docs/dd.md"; ln -s ../other.txt "$SC_REPO/docs/dd.md"
git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
SYM_TIP="$(git -C "$SC_REPO" rev-parse HEAD)"; SYM_GD="$(git -C "$SC_REPO" rev-parse --absolute-git-dir)"
eq "a SYMLINK where the union file was: the union function cannot tell (unknown:union-not-regular-file, never yes)" \
   "$( . "$TMP/block.sh"; rebase_union_paths_verdict "$SYM_GD" "$MAIN" "$FEAT" "$SYM_TIP" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${SYM_TIP}^{tree}")" 2>&1 )" "unknown:union-not-regular-file"
# ...but the VERDICT the gate acts on is no: it reproduces on every rebase, so it must reach a human, not the retry machinery
eq "...and rebase_content_verdict answers no (deterministic; anything but no feeds the bounded-retry loop of ga-10uqmi)" \
   "$(verdict "$SC_REPO" "$SYM_TIP")" "no"

build_hist hidden "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
printf 'H\nt1\nt2\nt3\nt4\nM0\nM1\nB0\nB1\nEXTRA\n' > "$SC_REPO/docs/dd.md"
git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
HID="$(git -C "$SC_REPO" rev-parse HEAD:docs/dd.md)"
OBJ="$SC_REPO/.git/objects/$(printf '%s' "$HID" | cut -c1-2)/$(printf '%s' "$HID" | cut -c3-)"
if [ -f "$OBJ" ]; then
  mv "$OBJ" "$OBJ.hidden"   # the tree still names the blob; the blob itself cannot be read
  eq "a blob that cannot be READ (object missing) → unknown:union-unreadable (never yes, never no)" \
     "$(verdict "$SC_REPO" "$(git -C "$SC_REPO" rev-parse HEAD)")" "unknown:union-unreadable"
  mv "$OBJ.hidden" "$OBJ"
else
  bad "fixture: the amended blob is not a loose object at $OBJ — cannot simulate an unreadable blob"
fi


# ── 6. gate attempt 1, blocking issue 2: deterministic causes are a NO, not a retry ──────────────────────
# Every caller of rebase_content_verdict routes ONLY a literal "no" to an immediate needs-rebase; anything else becomes
# CONFLICT_KIND=transient and goes through the bounded-retry / exile machinery ga-10uqmi documents as a measured resonance loop
# that "never converged and never reached a human". A cause that reproduces on every rebase (the file is past the size cap, is
# not a regular file, has a path git cannot hand to check-attr, has no merge-base) is not a hiccup: before this fix a mismatch on
# such a file was "no" (it reached a human) and after the cap it would have become an endless retry.
echo "── 6. deterministic union causes answer no at the VERDICT level; only transient ones stay unknown ──"
build_hist map "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
MAPR="$SC_REPO"; MAPNEW="$NEW"
map_verdict() { # map_verdict <what the union function answers>  -> what rebase_content_verdict tells the gate
  ( . "$TMP/block.sh"; STUB="$1"; rebase_union_paths_verdict() { echo "$STUB"; }; rebase_content_verdict "$MAPR" "$MAIN" "$FEAT" "$MAPNEW" 2>/dev/null )
}
for c in too-large not-regular-file quoted-path no-merge-base; do
  eq "union says unknown:union-$c (deterministic) → the verdict is no" "$(map_verdict "unknown:union-$c")" "no"
done
for c in unreadable awk-failed no-tmp attr-error diff-error; do
  eq "union says unknown:union-$c (transient) → stays unknown:union-$c" "$(map_verdict "unknown:union-$c")" "unknown:union-$c"
done
eq "a NEW unknown:union-* nobody decided defaults to unknown (never no, never yes)" "$(map_verdict "unknown:union-something-new")" "unknown:union-something-new"

# the cap: the real whatsapp_automation docs/data_dictionary.md is 1.93 MB and growing ~70 KB at a time — a 2 MB cap was 96.5% used
BIGPAD=40000 lossless "S5 a 3.2 MB union file" s5 "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
BIG_BYTES="$(wc -c < "$SC_REPO/$DDFILE" | tr -d ' ')"
[ "$BIG_BYTES" -gt 3000000 ] && ok "fixture: the union file is $BIG_BYTES bytes (past the old 2,000,000 cap)" || bad "fixture: the union file is only $BIG_BYTES bytes"
BIG_NEW="$NEW"
GATE_UNION_VERDICT_MAX_BYTES=100000 verdict "$SC_REPO" "$BIG_NEW" > "$TMP/big-small-cap.out"
eq "the same file with the cap forced under its size → no (deterministic), not a retry-loop unknown" "$(cat "$TMP/big-small-cap.out")" "no"

# paths git quotes in its output: non-ASCII names are printed RAW (core.quotePath=false) and are judged like any other path
DDFILE='docs/relatório.md' lossless "S6 a non-ASCII union filename" s6 "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
build_hist nonascii "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
echo "branch-only" > "$SC_REPO/docs/relatório-extra.md"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
eq "L8 a non-ASCII NON-union path also differs → no (was unknown:union-quoted-path, a retry loop for a deterministic mismatch)" \
   "$(verdict "$SC_REPO" "$(git -C "$SC_REPO" rev-parse HEAD)")" "no"
# a name with a double quote is still C-quoted by git whatever quotePath says. It is NOT a union path, so it is not this function's
# question (not-applicable, checked BEFORE the quoting matters) and the verdict the gate acts on stays no
build_hist quoted "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
echo "x" > "$SC_REPO/docs/we\"ird.md"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
Q_TIP="$(git -C "$SC_REPO" rev-parse HEAD)"; Q_GD="$(git -C "$SC_REPO" rev-parse --absolute-git-dir)"
eq "a NON-union filename containing a double quote: not this function's question (not-applicable, not a third state)" \
   "$( . "$TMP/block.sh"; rebase_union_paths_verdict "$Q_GD" "$MAIN" "$FEAT" "$Q_TIP" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${Q_TIP}^{tree}")" 2>&1 )" "not-applicable"
eq "...and the verdict the gate acts on is no" "$(verdict "$SC_REPO" "$Q_TIP")" "no"
# the quoting branch itself stays reachable when a catch-all declares EVERY path union: a C-quoted name cannot be looked up as a blob
echo '* merge=union' >> "$SC_REPO/.gitattributes"; git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit
Q_TIP="$(git -C "$SC_REPO" rev-parse HEAD)"
eq "a quoted name that IS declared union → unknown:union-quoted-path (the caller maps it to no)" \
   "$( . "$TMP/block.sh"; rebase_union_paths_verdict "$Q_GD" "$MAIN" "$FEAT" "$Q_TIP" "$(ref_tree "$SC_REPO")" "$(git -C "$SC_REPO" rev-parse "${Q_TIP}^{tree}")" 2>&1 )" "unknown:union-quoted-path"

# ── 7. a line-tagger that FAILS is not "nothing to compare" ──
# A command group's exit status is its LAST command's, so a failed tagger of B, M or O only SHRANK the arithmetic (no branch lines
# → nothing "needed" from the branch) and a real loss read yes. The shim fails ONLY the tagger of the branch-tip blob (tag 3).
echo "── 7. a failing line-tagger reads unknown:union-awk-failed, never a clean yes ──"
SHIM="$TMP/shim"; mkdir -p "$SHIM"; REAL_AWK="$(command -v awk)"
printf '#!/bin/sh\ncase "$1" in *"print 3 "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$REAL_AWK" > "$SHIM/awk"; chmod +x "$SHIM/awk"
build_hist tagfail "H|t1|t2|t3|t4|M0;H|t1|t2|t3|t4|M0|M1" "H|t1|t2|t3|B0;H|t1|t2|t3|B1"
git -C "$SC_REPO" checkout -q --detach "$NEW"
grep -v '^B1$' "$SC_REPO/$DDFILE" > "$SC_REPO/$DDFILE.n"; mv "$SC_REPO/$DDFILE.n" "$SC_REPO/$DDFILE"
git -C "$SC_REPO" add -A; git -C "$SC_REPO" commit -q --amend --no-edit --allow-empty; TF_TIP="$(git -C "$SC_REPO" rev-parse HEAD)"
[ "$(git -C "$SC_REPO" rev-parse "${TF_TIP}^{tree}")" != "$(git -C "$SC_REPO" rev-parse "${NEW}^{tree}")" ] && ok "fixture: the mutation changed the tree" || bad "fixture: the mutation changed NOTHING — this case would pass for the wrong reason"
eq "control, real awk: a line the branch added is gone → no" "$(verdict "$SC_REPO" "$TF_TIP")" "no"
eq "the branch-tip tagger fails on the same history → unknown:union-awk-failed (was a false yes)" "$( PATH="$SHIM:$PATH"; verdict "$SC_REPO" "$TF_TIP" )" "unknown:union-awk-failed"

# ── 5. wiring: the existing behaviour is untouched where union does not apply ──
echo "── 5. wiring ──"
grep -q 'rebase_union_paths_verdict' "$TMP/block.sh" && ok "rebase_union_paths_verdict is inside the live gate-rebase-content-verdict extract block" || bad "rebase_union_paths_verdict is not in the extract block"
USES="$(grep -c 'rebase_union_paths_verdict "' "$TMP/block.sh")"
[ "$USES" -ge 1 ] && ok "rebase_content_verdict consults it" || bad "rebase_content_verdict never calls rebase_union_paths_verdict"

echo "gate-e6b-union-content-verdict selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
