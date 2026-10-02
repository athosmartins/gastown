#!/usr/bin/env bash
# pilot-dispatcher.delivery-probes.selftest.sh — ga-3ebneo.
#
# Four Pilot probes answer "does this bead already have a delivery branch?":
#   _filter_built                      (drops an already-built candidate; unknown → KEEP)
#   _target_has_real_branch            (keep-signal for a sling reclaim; unknown → "no branch")
#   _beadid_has_crew_branch            (ownership-guard signal (a); unknown → "no branch")
#   _beadid_matched_crew_branch_ref    (names the matched ref; unknown → "no match")
# Each carried its own hand-written list (fix/<id>-* and crew/*/<id>), so a bead
# delivered on feat/<id> — or on fix/<id> with no slug — read "no branch" and the Pilot
# could dispatch a builder onto work that already exists. They now read
# delivery-branch-patterns.sh through _delivery_branch_local_ref /
# _delivery_branch_remote_hit.
#
# Real functions (awk-extracted from the dispatcher, never copies) against REAL git repos
# — a work clone plus a bare origin — all run under `set -euo pipefail`, the dispatcher's
# own mode. Per probe: (1) a branch on a NEW shape is seen, (2) the old shapes still are,
# (3) no branch / a longer id / a foreign tail-match / a nested decoy are NOT, and (4) the
# third state — lookup could not run — lands on the value each probe ALREADY used for
# "don't know", never on a veto and never on a delivery.
#
# Set PD_UNDER_TEST=<path to another pilot-dispatcher.sh> to run the same assertions
# against a different tree (this is how "fails before the fix" is proven: point it at the
# parent commit's file and the new-shape cases go red).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PD="${PD_UNDER_TEST:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="${LIB_UNDER_TEST:-$SELF_DIR/delivery-branch-patterns.sh}"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -r "$PD" ]  || { echo "FATAL: $PD missing" >&2; exit 2; }
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq missing" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "── pilot-dispatcher delivery-branch probes (ga-3ebneo)${PD_UNDER_TEST:+ — UNDER TEST: $PD_UNDER_TEST} ──"

# ── extract the REAL functions (signature line .. first top-level "}") ────────────────
FNS="$TMP/fns.sh"
: > "$FNS"
for _fn in _delivery_branch_patterns_ready _delivery_branch_local_ref _delivery_branch_remote_hit \
           _target_has_real_branch _beadid_has_crew_branch _beadid_matched_crew_branch_ref _filter_built; do
  awk -v n="$_fn" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$PD" >> "$FNS"
done
# Stubs for what the extracted functions call and this test does not exercise: the gate
# lookups say "not in a gate", the branch classifier says "block" (= the pre-ga-rcees veto,
# so a found branch DROPS the candidate), and log goes to stderr.
cat >> "$FNS" <<'STUBS'
_ownership_guard_repos() { return 0; }
_beadid_has_active_gate_artifact() { return 1; }
_beadid_has_open_gate_marker() { return 1; }
_beadid_branch_signal() { printf 'block\t%s' "$1"; return 0; }
_ownership_guard_flag_orphan_branch() { :; }
log() { printf '%s\n' "$*" >&2; }
STUBS
bash -n "$FNS" 2>/dev/null || { echo "FATAL: extracted functions do not parse" >&2; exit 2; }

# ── fixture: a work clone + a bare origin ─────────────────────────────────────────────
ORIGIN="$TMP/origin.git"
R="$TMP/work"
git init -q --bare "$ORIGIN"
git init -q "$R"
git -C "$R" config user.email t@t.invalid
git -C "$R" config user.name selftest
git -C "$R" commit -q --allow-empty -m init
git -C "$R" remote add origin "$ORIGIN"
SHA="$(git -C "$R" rev-parse HEAD)"
mk_local()    { git -C "$R" update-ref "refs/heads/$1" "$SHA"; }                     # local branch only
mk_pushed()   { mk_local "$1"; git -C "$R" push -q origin "refs/heads/$1:refs/heads/$1" 2>/dev/null; }
mk_tracking() { mk_pushed "$1"; git -C "$R" update-ref -d "refs/heads/$1"; }        # fetched origin ref only
mk_unfetched(){ mk_pushed "$1"; git -C "$R" update-ref -d "refs/heads/$1"; git -C "$R" update-ref -d "refs/remotes/origin/$1"; }  # on origin, unknown locally

mk_local    feat/ga-feat                # NEW shape: feat/<id>
mk_local    fix/ga-bare                 # NEW shape: fix/<id> with no slug
mk_local    fix/ga-slug-fixture         # old shape: fix/<id>-<slug>
mk_local    crew/alice/ga-crew          # old shape: crew/<owner>/<id>
mk_local    crew/alice/ga-crewslug-wip  # NEW shape: crew/<owner>/<id>-<slug>
mk_tracking refactor/ga-trk-x           # only as a fetched origin ref
mk_unfetched docs/ga-unf                # only on origin, never fetched
mk_local    feat/ga-longer              # decoy: LONGER id sharing the prefix of ga-long
mk_local    fix/ga-long2-x              # decoy: ditto
mk_local    chore/ga-nest/child         # decoy: sorts BEFORE the real branch, matches by path-prefix
mk_local    feat/ga-nest                # the real delivery of ga-nest
mk_local    chore/ga-ovr/child          # ONLY a path-prefix decoy → ga-ovr has no branch
mk_local    fix/ga-prio-b               # priority: fix/ beats feat/ ...
mk_local    feat/ga-prio                # ... whichever sorts first
mk_unfetched zzz/feat/ga-tail           # ls-remote TAIL-match hazard: ends like feat/ga-tail

# ── runners: each call is a fresh `set -euo pipefail` shell, like the dispatcher ──────
# call <lib|nolib> <repos> <fn> [args...]   → prints "<rc>" then the function's stdout.
call() {
  local _mode="$1" _repos="$2"; shift 2
  FNS="$FNS" LIB="$LIB" bash -c '
    set -euo pipefail
    mode="$1"; repos="$2"; shift 2
    . "$FNS"
    if [ "$mode" = lib ]; then . "$LIB"; fi
    _OWNERSHIP_GUARD_REPOS="$repos"
    rc=0; out=$("$@" 2>/dev/null) || rc=$?
    printf "%s\n%s" "$rc" "$out"
  ' _ "$_mode" "$_repos" "$@"
}
RC=""; OUT=""
run() { local _r; _r="$(call "$@")"; RC="${_r%%$'\n'*}"; OUT="${_r#*$'\n'}"; [ "$_r" = "$RC" ] && OUT=""; return 0; }
expect() { # label want_rc want_out(or "*") mode repos fn args...
  local _label="$1" _wrc="$2" _wout="$3"; shift 3
  run "$@"
  if [ "$RC" = "$_wrc" ] && { [ "$_wout" = "*" ] || [ "$OUT" = "$_wout" ]; }; then
    ok "$_label"
  else
    bad "$_label — want rc=$_wrc out='$_wout', got rc=$RC out='$OUT'"
  fi
}
TAB=$'\t'

# A repo that EXISTS as a directory but git cannot open (the "could not tell" fixture).
BROKEN="$TMP/broken"
mkdir -p "$BROKEN"; printf 'gitdir: /nonexistent/nowhere\n' > "$BROKEN/.git"
# A repo whose origin is unreachable (ls-remote fails → could not tell).
DEADREMOTE="$TMP/deadremote"
git init -q "$DEADREMOTE"
git -C "$DEADREMOTE" remote add origin "$TMP/does-not-exist.git"
# A repo with no origin at all (nothing to ask).
NOORIGIN="$TMP/noorigin"
git init -q "$NOORIGIN"

echo "── 1. _delivery_branch_local_ref — the shared local+fetched lookup ──"
expect "feat/<id> only                       → found"                       0 "refs/heads/feat/ga-feat"                 lib "$R" _delivery_branch_local_ref "$R" ga-feat
expect "fix/<id> with NO slug                → found"                       0 "refs/heads/fix/ga-bare"                  lib "$R" _delivery_branch_local_ref "$R" ga-bare
expect "fix/<id>-<slug> (old shape)          → found"                       0 "refs/heads/fix/ga-slug-fixture"          lib "$R" _delivery_branch_local_ref "$R" ga-slug
expect "crew/<owner>/<id> (old shape)        → found"                       0 "refs/heads/crew/alice/ga-crew"           lib "$R" _delivery_branch_local_ref "$R" ga-crew
expect "crew/<owner>/<id>-<slug>             → found"                       0 "refs/heads/crew/alice/ga-crewslug-wip"   lib "$R" _delivery_branch_local_ref "$R" ga-crewslug
expect "only a fetched origin ref            → found"                       0 "refs/remotes/origin/refactor/ga-trk-x"   lib "$R" _delivery_branch_local_ref "$R" ga-trk
expect "fix/ beats feat/ (priority order)    → fix/"                        0 "refs/heads/fix/ga-prio-b"                lib "$R" _delivery_branch_local_ref "$R" ga-prio
expect "decoy that sorts first does not hide the real branch" 0 "refs/heads/feat/ga-nest" lib "$R" _delivery_branch_local_ref "$R" ga-nest
expect "no branch at all                     → looked, none (rc 1)"         1 ""                                        lib "$R" _delivery_branch_local_ref "$R" ga-none
expect "LONGER id sharing the prefix         → none"                        1 ""                                        lib "$R" _delivery_branch_local_ref "$R" ga-long
expect "only a path-prefix decoy (x/<id>/y)  → none, not a false delivery"  1 ""                                        lib "$R" _delivery_branch_local_ref "$R" ga-ovr
expect "branch only on origin, never fetched → none locally (no network)"   1 ""                                        lib "$R" _delivery_branch_local_ref "$R" ga-unf
expect "lib NOT loaded                       → could not tell (rc 2)"       2 ""                                        nolib "$R" _delivery_branch_local_ref "$R" ga-feat
expect "repo git cannot open                 → could not tell (rc 2), not 'none'" 2 ""                                    lib "$R" _delivery_branch_local_ref "$BROKEN" ga-feat
expect "empty bead id                        → could not tell (rc 2)"       2 ""                                        lib "$R" _delivery_branch_local_ref "$R" ""

echo "── 2. _delivery_branch_remote_hit — origin itself ──"
expect "branch only on origin (docs/<id>)    → found, branch name"          0 "docs/ga-unf"                             lib "$R" _delivery_branch_remote_hit "$R" ga-unf
expect "no such branch on origin             → looked, none (rc 1)"         1 ""                                        lib "$R" _delivery_branch_remote_hit "$R" ga-none
expect "ls-remote TAIL-match hazard rejected → none"                        1 ""                                        lib "$R" _delivery_branch_remote_hit "$R" ga-tail
expect "no origin configured                 → none (nothing to ask), rc 1" 1 ""                                        lib "$R" _delivery_branch_remote_hit "$NOORIGIN" ga-feat
expect "origin unreachable                   → could not tell (rc 2)"       2 ""                                        lib "$R" _delivery_branch_remote_hit "$DEADREMOTE" ga-feat
expect "lib NOT loaded                       → could not tell (rc 2)"       2 ""                                        nolib "$R" _delivery_branch_remote_hit "$R" ga-unf

echo "── 3. _target_has_real_branch (unknown → \"no branch\", rc 1) ──"
for _id in ga-feat ga-bare ga-slug ga-crew ga-crewslug ga-trk ga-prio ga-nest; do
  expect "$_id → has a branch (rc 0)"   0 "" lib "$R" _target_has_real_branch "$_id"
done
for _id in ga-none ga-long ga-ovr ga-unf; do
  expect "$_id → no branch (rc 1)"      1 "" lib "$R" _target_has_real_branch "$_id"
done
expect "lib NOT loaded: even a real feat/ branch reads 'no branch' — never a keep-signal from nothing" 1 "" nolib "$R" _target_has_real_branch ga-feat
expect "only an unreadable repo → 'no branch' (rc 1)"                       1 "" lib "$BROKEN" _target_has_real_branch ga-feat
expect "unreadable repo FIRST, good repo second → positive evidence wins"   0 "" lib "$BROKEN"$'\n'"$R" _target_has_real_branch ga-feat

echo "── 4. _beadid_has_crew_branch (unknown → \"no branch\", rc 1) ──"
for _id in ga-feat ga-bare ga-slug ga-crew ga-crewslug ga-trk ga-prio ga-nest; do
  expect "$_id → local/fetched branch (rc 0)" 0 "" lib "$R" _beadid_has_crew_branch "$_id"
done
expect "ga-unf: not fetched, found by the ls-remote fallback (rc 0)"        0 "" lib "$R" _beadid_has_crew_branch ga-unf
for _id in ga-none ga-long ga-ovr ga-tail; do
  expect "$_id → no branch, ls-remote tail/decoys rejected (rc 1)" 1 "" lib "$R" _beadid_has_crew_branch "$_id"
done
expect "lib NOT loaded → rc 1 (no evidence is not a branch)"                1 "" nolib "$R" _beadid_has_crew_branch ga-feat
expect "unreachable origin, no local branch → rc 1, no abort"               1 "" lib "$DEADREMOTE" _beadid_has_crew_branch ga-feat
expect "local branch found even when ls-remote would fail"                  0 "" lib "$R" _beadid_has_crew_branch ga-feat

echo "── 5. _beadid_matched_crew_branch_ref (names the ref; unknown → no match, rc 1) ──"
expect "local feat/ branch → <repo>⇥<bare name>"            0 "$R${TAB}feat/ga-feat"            lib "$R" _beadid_matched_crew_branch_ref ga-feat
expect "fix/<id> no slug"                                   0 "$R${TAB}fix/ga-bare"             lib "$R" _beadid_matched_crew_branch_ref ga-bare
expect "fetched origin ref → origin/<name> (resolvable: _beadid_branch_signal runs merge-base on it)" 0 "$R${TAB}origin/refactor/ga-trk-x" lib "$R" _beadid_matched_crew_branch_ref ga-trk
expect "priority: fix/ first"                               0 "$R${TAB}fix/ga-prio-b"           lib "$R" _beadid_matched_crew_branch_ref ga-prio
expect "origin-only (ls-remote): repo known, ref EMPTY"     0 "$R${TAB}"                        lib "$R" _beadid_matched_crew_branch_ref ga-unf
expect "no branch → rc 1, no output"                        1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-none
expect "LONGER id sharing the prefix → rc 1"                1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-long
expect "ls-remote tail-match hazard → rc 1"                 1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-tail
expect "lib NOT loaded → rc 1"                              1 ""                                nolib "$R" _beadid_matched_crew_branch_ref ga-feat

echo "── 6. _filter_built (unknown → KEEP the candidate) ──"
fb() { # <lib|nolib> <repos> <json-array>  → sorted ids of the candidates that SURVIVE
  local _mode="$1" _repos="$2" _json="$3"
  printf '%s' "$_json" | FNS="$FNS" LIB="$LIB" bash -c '
    set -euo pipefail
    mode="$1"; repos="$2"
    . "$FNS"
    if [ "$mode" = lib ]; then . "$LIB"; fi
    _OWNERSHIP_GUARD_REPOS="$repos"
    _filter_built 2>/dev/null | jq -c "[.[].id] | sort"
  ' _ "$_mode" "$_repos" 2>/dev/null
}
ALL='[{"id":"ga-feat","labels":[]},{"id":"ga-bare","labels":[]},{"id":"ga-slug","labels":[]},{"id":"ga-crew","labels":[]},{"id":"ga-crewslug","labels":[]},{"id":"ga-trk","labels":[]},{"id":"ga-nest","labels":[]},{"id":"ga-none","labels":[]},{"id":"ga-long","labels":[]},{"id":"ga-ovr","labels":[]}]'
ALLIDS='["ga-bare","ga-crew","ga-crewslug","ga-feat","ga-long","ga-nest","ga-none","ga-ovr","ga-slug","ga-trk"]'
GOT="$(fb lib "$R" "$ALL")"
WANT='["ga-long","ga-none","ga-ovr"]'
[ "$GOT" = "$WANT" ] \
  && ok "already-built beads (feat/, no-slug fix/, crew+slug, fetched refactor/, decoy-masked feat/, old shapes) are DROPPED; none / longer-id / path-decoy are KEPT" \
  || bad "survivors wrong — want $WANT got '$GOT'"
GOT="$(fb nolib "$R" "$ALL")"
[ "$GOT" = "$ALLIDS" ] \
  && ok "lib NOT loaded → every candidate KEPT (fail-open: a failed lookup never drops a bead)" \
  || bad "no-lib must keep all — got '$GOT'"
GOT="$(fb lib "$BROKEN" "$ALL")"
[ "$GOT" = "$ALLIDS" ] \
  && ok "repo git cannot open → every candidate KEPT" \
  || bad "unreadable repo must keep all — got '$GOT'"
GOT="$(fb lib "$BROKEN"$'\n'"$R" "$ALL")"
[ "$GOT" = "$WANT" ] \
  && ok "unreadable repo first, good repo second → the good repo still decides" \
  || bad "multi-repo survivors wrong — want $WANT got '$GOT'"
GOT="$(fb lib "$R" '[{"id":"ga-none","labels":[]}]')"
[ "$GOT" = '["ga-none"]' ] && ok "a lone no-branch candidate passes through untouched" || bad "lone candidate wrong: '$GOT'"

echo "── 7. drift guard: the four probes carry no list of their own ──"
for _fn in _filter_built _target_has_real_branch _beadid_has_crew_branch _beadid_matched_crew_branch_ref; do
  _body="$(awk -v n="$_fn" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$PD" | grep -v '^[[:space:]]*#')"
  if [ -z "$_body" ]; then bad "$_fn not found in $PD"; continue; fi
  # `git ... ls-remote`, not bare "ls-remote": an inline `# ... (ls-remote-only)` comment is not a probe.
  if grep -qE 'refs/(heads|remotes/origin)/(fix|feat|crew)|"(fix|feat|crew)/\$|git[^#]* ls-remote' <<< "$_body"; then
    bad "$_fn carries a hand-written branch pattern again — it must read delivery-branch-patterns.sh via _delivery_branch_*"
  elif grep -q '_delivery_branch_' <<< "$_body"; then
    ok "$_fn reads the shared list through _delivery_branch_* (no pattern of its own)"
  else
    bad "$_fn does not use the _delivery_branch_* helpers"
  fi
done

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
