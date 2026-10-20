#!/usr/bin/env bash
# pilot-dispatcher.filter-built-batch.selftest.sh — ga-it7qiq: _filter_built asks `bd` and `git` about the whole list,
# not about one bead at a time.
#
# Why. _filter_built is the "already built / already in the gate" veto (the double-dispatch guard). It ran, for EVERY
# candidate: one `bd list --include-infra -l source-bead:<id>` (1.2-2.7 s each at load 44) and one `git for-each-ref`
# per repo (0.4-1.0 s each, x7 repos). For the 255 beads of the WA rig that is minutes — and the chain runs ~6 times a
# sweep. There are 8 open gate markers in the whole city; the answer to "does an open marker name bead X" is a SET.
#
# The verdict must not change — a wrong "not built" is a second builder on work that exists. Proved here:
#   (1) the verdict: built / in-gate beads are dropped, everything else stays — LITERAL expected ids, incl. the exact-id
#       traps (b-1 vs a b-12 branch, b-mark vs a b-marker marker), open-only (a closed marker does not veto) and
#       marker-only (an open gate RUN does not veto);
#   (2) the cost: one bulk marker read per call (not one per bead), and a list of beads that no ref names costs one
#       ref listing per repo (not one git call per bead per repo);
#   (3) THREE states: a failed / unreadable bulk read falls back to the per-bead read of before (same verdict, never a
#       silent "no marker"); a repo whose refs cannot be listed is asked the exact way, per bead (still "could not
#       tell", still counted and logged, candidate KEPT);
#   (4) mutants: a prefilter that skips every repo, a marker set matched by substring, and a bulk read that ignores
#       the status must each make THIS file fail.
#
# Runs the REAL function text cut out of the dispatcher, in a child bash (/bin/bash, like production) under
# `set -euo pipefail`, with counting `bd` / `git` shims first on PATH and two real throw-away git repos. No Dolt needed.
# Env: FBB_DISPATCHER_UNDER_TEST points at a mutant; FBB_SKIP_MUTATION=1 skips (4). Exit 0 iff every check holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${FBB_DISPATCHER_UNDER_TEST:-$HERE/pilot-dispatcher.sh}"
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -r "$HERE/delivery-branch-patterns.sh" ] || { echo "FATAL: delivery-branch-patterns.sh missing next to the test" >&2; exit 2; }
REALGIT="$(command -v git)"; REALJQ="$(command -v jq)"
[ -n "$REALGIT" ] && [ -n "$REALJQ" ] || { echo "FATAL: git and jq are required" >&2; exit 2; }

P=0; F=0
ok()  { echo "  ok: $*"; P=$((P+1)); }
bad() { echo "  BAD: $*"; F=$((F+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ga-it7qiq-fbb.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fn() { sed -n "/^$1() {/,/^}\$/p" "$DISPATCHER"; }
FB="$(fn _filter_built)"; HOM="$(fn _beadid_has_open_gate_marker)"; HAA="$(fn _beadid_has_active_gate_artifact)"
DBL="$(fn _delivery_branch_local_ref)"; DBR="$(fn _delivery_branch_patterns_ready)"
for pair in "FB:_filter_built" "HOM:_beadid_has_open_gate_marker" "HAA:_beadid_has_active_gate_artifact" "DBL:_delivery_branch_local_ref" "DBR:_delivery_branch_patterns_ready"; do
  v="${pair%%:*}"; [ -n "${!v}" ] || { echo "FATAL: ${pair#*:} not found in $DISPATCHER" >&2; exit 2; }
done

# ── two real repos; refs chosen to cover the exact-id traps ───────────────────────────────
R1="$TMP/r1"; R2="$TMP/r2"; R3="$TMP/r3-not-a-repo"; mkdir -p "$R1" "$R2" "$R3"
mkgit() { "$REALGIT" -C "$1" init -q && "$REALGIT" -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x; }
mkgit "$R1"; mkgit "$R2"
"$REALGIT" -C "$R1" branch "fix/b-built-slug"
"$REALGIT" -C "$R1" branch "fix/b-12-other-bead"                       # names b-12 — and contains the text "b-1"
"$REALGIT" -C "$R1" update-ref "refs/remotes/origin/feat/b-remote" HEAD   # a fetched origin ref
"$REALGIT" -C "$R2" branch "crew/mila/b-crew"

# ── bd shim: serves a marker fixture; counts bulk vs per-bead reads ───────────────────────
MARKERS="$TMP/markers.json"
cat > "$MARKERS" <<'JSON'
[
 {"id":"m1","status":"open",  "labels":["type:quality-gate-marker","source-bead:b-marker","gate-status:ready"]},
 {"id":"m2","status":"closed","labels":["type:quality-gate-marker","source-bead:b-marker-closed","gate-status:passed"]},
 {"id":"r1","status":"open",  "labels":["type:quality-gate-run","source-bead:b-run-only","gate-status:running"]},
 {"id":"m3","status":"open",  "labels":["type:quality-gate-marker","source-bead:b-needsfix-active","gate-status:reviewing"]},
 {"id":"m4","status":"closed","labels":["type:quality-gate-marker","source-bead:b-needsfix","gate-status:failed"]}
]
JSON
BIN="$TMP/bin"; mkdir -p "$BIN"; BDLOG="$TMP/bd.log"; GITLOG="$TMP/git.log"
cat > "$BIN/bd" <<EOF
#!/bin/bash
# args: -C <dir> list --include-infra -l <label> [--status open] --json [-n 0]
echo "\$*" >> "$BDLOG"
label=""; status=""; prev=""
for a in "\$@"; do
  [ "\$prev" = "-l" ] && label="\$a"
  [ "\$prev" = "--status" ] && status="\$a"
  prev="\$a"
done
# a failure mode hits ONLY the bulk marker read; the per-bead reads (the fallback) keep working
if [ "\$label" = "type:quality-gate-marker" ]; then
  case "\${BDMODE:-ok}" in
    fail)    exit 1 ;;
    garbage) echo 'not json at all'; exit 0 ;;
  esac
fi
"$REALJQ" -c --arg l "\$label" --arg s "\$status" '[ .[] | select((.labels | index(\$l)) != null) | select(\$s == "" or .status == \$s) ]' "$MARKERS"
EOF
cat > "$BIN/git" <<EOF
#!/bin/bash
echo "\$*" >> "$GITLOG"
exec "$REALGIT" "\$@"
EOF
chmod +x "$BIN/bd" "$BIN/git"
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1" 2>/dev/null || true; else echo 0; fi; }

# ── harness: the real function in a child /bin/bash under the dispatcher's strictness ─────
run_fb() { # <candidates-json> <repos (newline list)> [BDMODE]
  printf '%s' "$1" > "$TMP/in.json"; : > "$BDLOG"; : > "$GITLOG"
  BDMODE="${3:-ok}" PATH="$BIN:$PATH" /bin/bash -c "
set -euo pipefail
log()  { echo \"[pilot-dispatcher] \$*\"; }
warn() { echo \"[pilot-dispatcher] WARN: \$*\"; }
GC_CITY='$TMP/city'
source '$HERE/delivery-branch-patterns.sh'
$DBR
$DBL
$HOM
$HAA
$FB
_ownership_guard_repos() { :; }
_OWNERSHIP_GUARD_REPOS='$2'
_beadid_branch_signal() { printf 'block\t-'; }
_ownership_guard_flag_orphan_branch() { :; }
_out=\$(cat '$TMP/in.json' | _filter_built)
printf '%s' \"\$_out\"" > "$TMP/out" 2> "$TMP/err"
  RC=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
ids() { "$REALJQ" -c '[.[].id] | sort' <<<"$1" 2>/dev/null; }
mk() { # ids... -> candidates JSON (optional "id|label" form)
  local a first=1 out="["
  for a in "$@"; do
    [ "$first" = 1 ] || out="$out,"; first=0
    case "$a" in
      *\|*) out="$out{\"id\":\"${a%%|*}\",\"labels\":[\"${a#*|}\"]}" ;;
      *)    out="$out{\"id\":\"$a\",\"labels\":[]}" ;;
    esac
  done
  printf '%s]' "$out"
}
REPOS="$R1
$R2"

echo "== pilot-dispatcher.filter-built-batch.selftest (ga-it7qiq) =="

echo "-- 1. the verdict, with literal expected ids --"
ALL="$(mk b-fresh b-built b-crew b-remote b-1 b-12 b-marker b-mark b-marker-closed b-run-only 'b-glabel|gate:passed' 'b-needsfix|gate:needs-fix' 'b-needsfix-active|gate:needs-fix' b.odd_id)"
run_fb "$ALL" "$REPOS"
WANT_KEPT='["b-1","b-fresh","b-mark","b-marker-closed","b-needsfix","b-run-only","b.odd_id"]'
if [ "$RC" = 0 ] && [ "$(ids "$OUT")" = "$WANT_KEPT" ]; then ok "kept $WANT_KEPT"; else bad "rc=$RC kept=$(ids "$OUT") want=$WANT_KEPT err=$ERR"; fi
DROPPED="$("$REALJQ" -nc --argjson all "$ALL" --argjson kept "$(ids "$OUT")" '[$all[].id | select(. as $i | $kept | index($i) | not)] | sort')"
WANT_DROPPED='["b-built","b-crew","b-glabel","b-12","b-marker","b-needsfix-active","b-remote"]'
WANT_DROPPED="$("$REALJQ" -c 'sort' <<<"$WANT_DROPPED")"
[ "$DROPPED" = "$WANT_DROPPED" ] && ok "dropped $DROPPED (branch in r1, crew branch in r2, origin ref, b-12 branch, open marker, gate label, actively re-gated needs-fix)" || bad "dropped $DROPPED want $WANT_DROPPED"
for id in b-built b-crew b-remote b-12 b-marker b-glabel b-needsfix-active; do
  grep -q "EXCLUÍDO $id por _filter_built" <<<"$ERR$OUT" || grep -q "EXCLUÍDO $id por _filter_built" "$TMP/err" || bad "no EXCLUÍDO trace line for $id"
done

echo "-- 1b. the prefilter's premise: EVERY delivery glob embeds the bead id literally --"
GLOB_BAD=""
for sid in b-1 wa-8gfrgd ga-2hd02v.6 x_y.z-9; do
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in *"$sid"*) ;; *) GLOB_BAD="$GLOB_BAD [$sid -> $g]" ;; esac
  done < <(/bin/bash -c "source '$HERE/delivery-branch-patterns.sh'; gc_delivery_branch_globs '$sid'")
done
NGLOBS="$(/bin/bash -c "source '$HERE/delivery-branch-patterns.sh'; gc_delivery_branch_globs b-1" | wc -l | tr -d ' ')"
if [ -z "$GLOB_BAD" ] && [ "$NGLOBS" -ge 4 ]; then ok "all $NGLOBS globs contain the id: a repo whose refs lack the id cannot hold its delivery branch"; else bad "a glob without the id would make the ref prefilter skip a real branch:$GLOB_BAD (globs=$NGLOBS)"; fi

echo "-- 2. the cost: 1 bulk marker read; no ref listing per bead --"
BULK="$(count "$BDLOG" 'type:quality-gate-marker')"; PERBEAD="$(count "$BDLOG" 'source-bead:')"
# the two needs-fix beads are still asked the exact way (rare, and a different question: ACTIVE re-gating)
if [ "$BULK" = "1" ] && [ "$PERBEAD" = "2" ]; then ok "bd: 1 bulk read + 2 per-bead reads (the 2 gate:needs-fix beads) for 14 candidates"; else bad "bd reads: bulk=$BULK per-bead=$PERBEAD (want 1 and 2)"; fi
FRESH="$(mk f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16 f17 f18 f19 f20)"
run_fb "$FRESH" "$REPOS"
G="$(count "$GITLOG" 'for-each-ref')"; B="$(count "$BDLOG" 'list')"
if [ "$RC" = 0 ] && [ "$(ids "$OUT")" = "$(ids "$FRESH")" ] && [ "$G" -le 2 ] && [ "$B" = "1" ]; then ok "20 beads nobody names: all kept, $G git call(s) for 2 repos (was 40), $B bd read (was 20)"; else bad "20 fresh beads: rc=$RC git=$G bd=$B (want git<=2, bd=1) kept=$(ids "$OUT")"; fi

echo "-- 3. THREE states: nothing is collapsed into 'not built' --"
for mode in fail garbage; do
  run_fb "$ALL" "$REPOS" "$mode"; PB="$(count "$BDLOG" 'source-bead:')"
  if [ "$RC" = 0 ] && [ "$(ids "$OUT")" = "$WANT_KEPT" ] && [ "$PB" -ge 10 ]; then ok "bulk read $mode: same verdict through the per-bead fallback ($PB per-bead reads)"; else bad "bulk $mode: rc=$RC kept=$(ids "$OUT") per-bead=$PB (want the same verdict and >= 10 per-bead reads)"; fi
done
run_fb "$(mk b-fresh b-built)" "$REPOS
$R3"
if [ "$RC" = 0 ] && [ "$(ids "$OUT")" = '["b-fresh"]' ] && grep -q 'could not be checked for an existing delivery branch' "$TMP/err"; then ok "a repo that cannot be listed: b-fresh KEPT, b-built still dropped by the other repo, 'could not be checked' logged"; else bad "unlistable repo: rc=$RC kept=$(ids "$OUT") err=$ERR"; fi
run_fb '[]' "$REPOS"; [ "$RC" = 0 ] && [ "$OUT" = "[]" ] && ok "empty list stays []" || bad "empty list: rc=$RC out=[$OUT]"

if [ "${FBB_SKIP_MUTATION:-0}" != "1" ] && [ -z "${FBB_DISPATCHER_UNDER_TEST:-}" ]; then
  echo "-- 4. mutation controls: each reverts one property and THIS file must fail --"
  mutate() { # <name> <old> <new> [<old> <new> ...]
    local name="$1"; shift
    python3 -I - "$DISPATCHER" "$TMP/mut-$name.sh" "$@" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
args = sys.argv[3:]
for old, new in zip(args[0::2], args[1::2]):
    t2 = t.replace(old, new, 1)
    if t2 == t:
        print("ANCHOR NOT FOUND: " + old); sys.exit(3)
    t = t2
open(sys.argv[2], "w", encoding="utf-8").write(t)
PY
  }
  expect_reject() { # <name> <what the mutant breaks>
    if [ ! -s "$TMP/mut-$1.sh" ]; then bad "mutant $1 could not be built (anchor drifted)"; return; fi
    FBB_DISPATCHER_UNDER_TEST="$TMP/mut-$1.sh" FBB_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mut-$1.out" 2>&1 \
      && bad "mutant $1 ($2) was NOT rejected" || ok "mutant $1 ($2) is rejected"
  }
  # M1: a repo whose refs mention the id is skipped too (only the 'unlistable' clause kept) -> built beads stay candidates
  mutate skipall '*"${_fb_nl}${r}${_bf_tab}*${_fb_nl}"*|*"${_fb_nl}${r}${_bf_tab}${id}${_fb_nl}"*) ;;' '*"${_fb_nl}${r}${_bf_tab}*${_fb_nl}"*) ;;'
  expect_reject skipall "prefilter skips repos that DO name the id"
  # M2: marker set matched by substring instead of the exact id line -> b-mark is dropped by b-marker's marker
  mutate substr '*"${_fb_nl}${id}${_fb_nl}"*) _fb_named=1 ;;' '*"${id}"*) _fb_named=1 ;;'
  expect_reject substr "marker set matched by substring"
  # M3: the bulk read stops being open-only -> a closed marker vetoes
  mutate allstatus '--status open --json -n 0' '--json -n 0' '(.[] | select(.status == "open") | (.labels // [])[]' '(.[] | (.labels // [])[]'
  expect_reject allstatus "bulk read ignores the marker status"
  # M4: a failed bulk read is read as 'no marker' instead of falling back to the per-bead question
  mutate failopen 'elif _beadid_has_open_gate_marker "$id"; then' 'elif false; then'
  expect_reject failopen "unreadable bulk read becomes 'no open marker'"
  # M5: an unlistable repo is read as 'looked, none' -> the 'could not tell' accounting disappears
  mutate unlistable '*"${_fb_nl}${r}${_bf_tab}*${_fb_nl}"*|*"${_fb_nl}${r}${_bf_tab}${id}${_fb_nl}"*) ;;' '*"${_fb_nl}${r}${_bf_tab}${id}${_fb_nl}"*) ;;'
  expect_reject unlistable "unlistable repo read as 'no branch'"
fi

echo
echo "== filter-built-batch: $P passed, $F failed =="
[ "$F" -eq 0 ]
