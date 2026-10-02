#!/usr/bin/env bash
# pilot-dispatcher.delivery-probes.selftest.sh — ga-3ebneo.
#
# Four Pilot probes answer "does this bead already have a delivery branch?":
#   _filter_built                      (drops an already-built candidate; unknown → KEEP, counted)
#   _target_has_real_branch            (keep-signal for a sling reclaim; rc 0 / 1 none / 2 could not tell)
#   _beadid_has_crew_branch            (ownership-guard signal (a);      rc 0 / 1 none / 2 could not tell)
#   _beadid_matched_crew_branch_ref    (names the matched ref;           rc 0 / 1 none / 2 could not tell)
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
# third state — lookup could not run — is its OWN answer (rc 2), never "none" and never a
# delivery. §9 then runs the three callers that RELEASE a bead on "no branch"
# (_sling_is_live, the phantom-claim guard in _beadid_live_crew_owner, and
# _pilot_crew_stale_reclaim) with the real probes underneath: "none" releases, "could not
# tell" keeps (pre-gate review of ga-3ebneo, blocking finding: rc 2 used to read as "none").
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
  FNS="$FNS" LIB="$LIB" PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH" bash -c '
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
# A repo that HAS a local delivery branch but whose origin is unreachable: positive local
# evidence must win over a remote that cannot answer (the old fixture used $R, whose origin
# works, so it passed whether or not the local hit short-circuited).
LOCALDEAD="$TMP/localdead"
git init -q "$LOCALDEAD"
git -C "$LOCALDEAD" config user.email t@t.invalid
git -C "$LOCALDEAD" config user.name selftest
git -C "$LOCALDEAD" commit -q --allow-empty -m init
git -C "$LOCALDEAD" update-ref refs/heads/feat/ga-feat HEAD
git -C "$LOCALDEAD" remote add origin "$TMP/does-not-exist.git"
# A `git` that answers EVERY `ls-remote` with two lines — a TAIL-matching foreign ref
# (zzz/feat/ga-tail ends like feat/ga-tail, which git's own rooted pattern matching would NOT
# return, so only a shim can put it in front of the anchored re-check) and one genuine
# feat/ga-shimreal — and passes everything else through to the real git.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
REALGIT="$(command -v git)"
cat > "$SHIM/git" <<SHIMEOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = ls-remote ]; then
    printf '%s\trefs/heads/zzz/feat/ga-tail\n' "0000000000000000000000000000000000000000"
    printf '%s\trefs/heads/feat/ga-shimreal\n' "0000000000000000000000000000000000000000"
    exit 0
  fi
done
exec "$REALGIT" "\$@"
SHIMEOF
chmod +x "$SHIM/git"

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
# The case above is satisfied by git's own rooted pattern matching, so it would stay green if
# the anchored gc_delivery_branch_pick were dropped from the helper. The shim makes ls-remote
# hand back the foreign ref itself: only the anchored re-check can reject it.
EXTRA_PATH="$SHIM"
expect "ls-remote HANDS BACK a tail-matching foreign ref → the anchored re-check rejects it (rc 1)" 1 ""               lib "$R" _delivery_branch_remote_hit "$R" ga-tail
expect "…while a genuine line in the SAME reply is picked (so the shim itself is not what rejects)" 0 "feat/ga-shimreal" lib "$R" _delivery_branch_remote_hit "$R" ga-shimreal
EXTRA_PATH=""
expect "no origin configured                 → none (nothing to ask), rc 1" 1 ""                                        lib "$R" _delivery_branch_remote_hit "$NOORIGIN" ga-feat
expect "origin unreachable                   → could not tell (rc 2)"       2 ""                                        lib "$R" _delivery_branch_remote_hit "$DEADREMOTE" ga-feat
expect "lib NOT loaded                       → could not tell (rc 2)"       2 ""                                        nolib "$R" _delivery_branch_remote_hit "$R" ga-unf

echo "── 3. _target_has_real_branch (rc 0 branch / rc 1 looked, none / rc 2 could not tell) ──"
for _id in ga-feat ga-bare ga-slug ga-crew ga-crewslug ga-trk ga-prio ga-nest; do
  expect "$_id → has a branch (rc 0)"   0 "" lib "$R" _target_has_real_branch "$_id"
done
for _id in ga-none ga-long ga-ovr ga-unf; do
  expect "$_id → no branch (rc 1)"      1 "" lib "$R" _target_has_real_branch "$_id"
done
expect "lib NOT loaded → could not tell (rc 2), never 'none' and never a keep-signal from nothing" 2 "" nolib "$R" _target_has_real_branch ga-feat
expect "only an unreadable repo → could not tell (rc 2)"                    2 "" lib "$BROKEN" _target_has_real_branch ga-feat
expect "unreadable repo FIRST, good repo second → positive evidence wins"   0 "" lib "$BROKEN"$'\n'"$R" _target_has_real_branch ga-feat
expect "unreadable repo + good repo that says none → still rc 2: 'none' needs EVERY repo to have answered" 2 "" lib "$BROKEN"$'\n'"$R" _target_has_real_branch ga-none

echo "── 4. _beadid_has_crew_branch (rc 0 branch / rc 1 looked, none / rc 2 could not tell) ──"
for _id in ga-feat ga-bare ga-slug ga-crew ga-crewslug ga-trk ga-prio ga-nest; do
  expect "$_id → local/fetched branch (rc 0)" 0 "" lib "$R" _beadid_has_crew_branch "$_id"
done
expect "ga-unf: not fetched, found by the ls-remote fallback (rc 0)"        0 "" lib "$R" _beadid_has_crew_branch ga-unf
for _id in ga-none ga-long ga-ovr ga-tail; do
  expect "$_id → no branch, ls-remote tail/decoys rejected (rc 1)" 1 "" lib "$R" _beadid_has_crew_branch "$_id"
done
expect "lib NOT loaded → could not tell (rc 2): no evidence of a branch is not 'no branch'" 2 "" nolib "$R" _beadid_has_crew_branch ga-feat
expect "unreachable origin, no local branch → could not tell (rc 2), no abort" 2 "" lib "$DEADREMOTE" _beadid_has_crew_branch ga-feat
expect "repo git cannot open → could not tell (rc 2)"                       2 "" lib "$BROKEN" _beadid_has_crew_branch ga-feat
expect "no origin configured, no local branch → looked, none (rc 1): nothing to ask is an answer" 1 "" lib "$NOORIGIN" _beadid_has_crew_branch ga-feat
expect "local branch found even though the origin is unreachable (positive evidence wins)" 0 "" lib "$LOCALDEAD" _beadid_has_crew_branch ga-feat
expect "unreadable repo FIRST, good repo has the branch → rc 0"             0 "" lib "$BROKEN"$'\n'"$R" _beadid_has_crew_branch ga-feat
expect "unreadable repo + good repo that says none → still rc 2"            2 "" lib "$BROKEN"$'\n'"$R" _beadid_has_crew_branch ga-none

echo "── 5. _beadid_matched_crew_branch_ref (names the ref; rc 0 / 1 none / 2 could not tell) ──"
expect "local feat/ branch → <repo>⇥<bare name>"            0 "$R${TAB}feat/ga-feat"            lib "$R" _beadid_matched_crew_branch_ref ga-feat
expect "fix/<id> no slug"                                   0 "$R${TAB}fix/ga-bare"             lib "$R" _beadid_matched_crew_branch_ref ga-bare
expect "fetched origin ref → origin/<name> (resolvable: _beadid_branch_signal runs merge-base on it)" 0 "$R${TAB}origin/refactor/ga-trk-x" lib "$R" _beadid_matched_crew_branch_ref ga-trk
expect "priority: fix/ first"                               0 "$R${TAB}fix/ga-prio-b"           lib "$R" _beadid_matched_crew_branch_ref ga-prio
expect "origin-only (ls-remote): repo known, ref EMPTY"     0 "$R${TAB}"                        lib "$R" _beadid_matched_crew_branch_ref ga-unf
expect "no branch → rc 1, no output"                        1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-none
expect "LONGER id sharing the prefix → rc 1"                1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-long
expect "ls-remote tail-match hazard → rc 1"                 1 ""                                lib "$R" _beadid_matched_crew_branch_ref ga-tail
expect "lib NOT loaded → could not tell (rc 2), no output"  2 ""                                nolib "$R" _beadid_matched_crew_branch_ref ga-feat
expect "repo git cannot open → rc 2"                        2 ""                                lib "$BROKEN" _beadid_matched_crew_branch_ref ga-feat
expect "unreachable origin, no local branch → rc 2"         2 ""                                lib "$DEADREMOTE" _beadid_matched_crew_branch_ref ga-feat
expect "no origin configured, no local branch → rc 1"       1 ""                                lib "$NOORIGIN" _beadid_matched_crew_branch_ref ga-feat
expect "unreadable repo FIRST, good repo has it → matched"  0 "$R${TAB}feat/ga-feat"            lib "$BROKEN"$'\n'"$R" _beadid_matched_crew_branch_ref ga-feat

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

# "could not tell" keeps the candidate — but must be VISIBLE and COUNTED, not quiet (one line per call).
fberr() { # <lib|nolib> <repos> <json-array>  → _filter_built's stderr
  local _mode="$1" _repos="$2" _json="$3"
  printf '%s' "$_json" | FNS="$FNS" LIB="$LIB" bash -c '
    set -euo pipefail
    mode="$1"; repos="$2"
    . "$FNS"
    if [ "$mode" = lib ]; then . "$LIB"; fi
    _OWNERSHIP_GUARD_REPOS="$repos"
    _filter_built 2>&1 >/dev/null
  ' _ "$_mode" "$_repos" 2>/dev/null
}
GOT="$(fberr nolib "$R" "$ALL")"
case "$GOT" in *"10 candidate(s) could not be checked"*"KEPT"*) ok "lib NOT loaded → ONE line counts the 10 unverifiable candidates (kept, not cleared)" ;; *) bad "no-lib: missing/wrong unverified-count line — got '$GOT'" ;; esac
[ "$(printf '%s\n' "$GOT" | grep -c 'could not be checked')" = "1" ] && ok "…and it is ONE line per call, not one per candidate" || bad "unverified line repeated: '$GOT'"
GOT="$(fberr lib "$BROKEN" "$ALL")"
case "$GOT" in *"10 candidate(s) could not be checked"*) ok "repo git cannot open → the same count" ;; *) bad "broken-repo: missing unverified-count line — got '$GOT'" ;; esac
GOT="$(fberr lib "$BROKEN"$'\n'"$R" "$ALL")"
case "$GOT" in *"3 candidate(s) could not be checked"*) ok "unreadable repo + good repo: the 7 found in the good repo are SETTLED, only the 3 with no branch stay unverified" ;; *) bad "mixed repos: want 3 unverified — got '$GOT'" ;; esac
GOT="$(fberr lib "$R" "$ALL")"
case "$GOT" in *"could not be checked"*) bad "all repos readable: no unverified line expected — got '$GOT'" ;; *) ok "every lookup ran → no unverified line (silence means checked)" ;; esac

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

# ── 8. ordering on the REAL file ────────────────────────────────────────────────────────
# Every assertion above loads the lib up front, so none of them can see WHEN the real script
# loads it. pilot-dispatcher.sh runs top-level statements in file order, and the lib used to be
# sourced at the bottom — after _pilot_emit_dispatchable (queue emit → _filter_built) and
# _ttl_recover_db (→ _sling_is_live → _target_has_real_branch) had already run. In production
# both saw "lib not loaded" = "could not tell" = "no branch" on EVERY sweep: the TTL path then
# released a claim whose bead had a delivery branch (a second builder on work that exists), and
# the already-built veto went quiet. The check is structural, on the real file: build the call
# graph of its functions, take everything that can reach the lib (directly or through callers),
# and require the `source` line to come before the first top-level line that names any of them.
echo "── 8. ordering: the lib is sourced BEFORE any top-level statement that can reach a probe ──"
cat > "$TMP/order.py" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
FN_OPEN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
defs = {}   # name -> text of its body, comments dropped
top = []    # (lineno, text) outside every function body, comments dropped
cur = None
for no, ln in enumerate(lines, 1):
    code = "" if ln.lstrip().startswith("#") else ln
    if cur is None:
        m = FN_OPEN.match(ln)
        if m:
            if ln.rstrip().endswith("}") and ln.count("{") == ln.count("}"):
                defs[m.group(1)] = ln          # one-line function
            else:
                cur = m.group(1)
                defs[cur] = code
        elif code.strip():
            top.append((no, code))
    else:
        defs[cur] += "\n" + code
        if re.match(r"^\}\s*$", ln):
            cur = None

lib_fns = {"gc_delivery_branch_globs", "gc_delivery_branch_pick",
           "_delivery_branch_local_ref", "_delivery_branch_remote_hit"}
changed = True
while changed:
    changed = False
    for name, body in defs.items():
        if name in lib_fns:
            continue
        if any(re.search(r"(?<![A-Za-z0-9_])" + re.escape(f) + r"(?![A-Za-z0-9_])", body) for f in lib_fns):
            lib_fns.add(name)
            changed = True

# Non-vacuity: the analysis must see the two known consumers as lib-dependent, or it proves nothing.
missing = [f for f in ("_filter_built", "_target_has_real_branch", "_pilot_emit_dispatchable", "_ttl_recover_db")
           if f not in lib_fns]
if missing:
    print("VACUOUS: not seen as reaching the lib: " + ", ".join(missing))
    sys.exit(2)

src = [no for no, code in top if re.match(r'\s*source\s+"\$_GC_DBP_SIBLING"', code)]
if not src:
    print("NO-SOURCE: no top-level `source \"$_GC_DBP_SIBLING\"` line found")
    sys.exit(2)
src_no = src[0]

hits = []
for no, code in top:
    for f in sorted(lib_fns):
        if f.startswith("gc_delivery_branch_"):
            continue
        if re.search(r"(?<![A-Za-z0-9_])" + re.escape(f) + r"(?![A-Za-z0-9_])", code):
            hits.append((no, f))
            break
if not hits:
    print("VACUOUS: no top-level line names a lib-dependent function")
    sys.exit(2)
first_no, first_fn = min(hits)
if src_no < first_no:
    print("source at L%d, first top-level reference L%d (%s)" % (src_no, first_no, first_fn))
    sys.exit(0)
early = [h for h in hits if h[0] < src_no]
print("source at L%d but %d top-level line(s) run before it, first L%d (%s)%s" % (
    src_no, len(early), first_no, first_fn,
    "; also " + ", ".join("L%d %s" % h for h in early[1:4]) if len(early) > 1 else ""))
sys.exit(1)
PY
if ! command -v python3 >/dev/null 2>&1; then
  bad "python3 missing — the lib/consumer ordering was NOT checked"
else
  ORD_OUT="$(python3 "$TMP/order.py" "$PD" 2>&1)"; ORD_RC=$?
  case "$ORD_RC" in
    0) ok "the lib is sourced before any top-level statement that can reach a probe ($ORD_OUT)" ;;
    1) bad "lib sourced TOO LATE — a top-level consumer runs first and sees 'could not tell' = 'no branch' on every sweep: $ORD_OUT" ;;
    *) bad "ordering analysis could not run: $ORD_OUT" ;;
  esac
fi

# ── 9. the three callers that RELEASE a bead on "no branch" ──────────────────────────────
# Pre-gate review of ga-3ebneo (blocking finding): the probes' rc 2 ("could not tell") was folded into
# "none" by the callers that act destructively on "none" — an idle sling declared DEAD (TTL
# release), a stale crew claim released as a phantom, a stale crew bead unassigned as "never
# engaged". Real functions, real probes, real git repos; only the edges are stubbed (bd, sessions,
# warn). Every group first proves the RELEASE path is reachable ("none" releases), then that
# "could not tell" and "found" do not.
echo "── 9. release-type callers: \"none\" releases, \"could not tell\" keeps ──"
FNS2="$TMP/fns2.sh"
: > "$FNS2"
for _fn in _delivery_branch_patterns_ready _delivery_branch_local_ref _delivery_branch_remote_hit \
           _target_has_real_branch _beadid_has_crew_branch _beadid_matched_crew_branch_ref _beadid_branch_signal \
           _iso_to_epoch _sling_is_live _beadid_live_crew_owner _pilot_crew_stale_reclaim; do
  awk -v n="$_fn" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$PD" >> "$FNS2"
done
cat >> "$FNS2" <<'STUBS2'
_ownership_guard_repos() { return 0; }
_session_is_live() { return 0; }
warn() { printf 'WARN %s\n' "$*"; }
bd() {
  if [ -n "${BDLOG:-}" ]; then printf '%s\n' "$*" >> "$BDLOG"; fi
  case "$*" in
    *" show "*) printf '[{"assignee":"alice-wa","updated_at":"2020-01-01T00:00:00Z"}]' ;;
  esac
  return 0
}
STUBS2
bash -n "$FNS2" 2>/dev/null || { echo "FATAL: section-9 functions do not parse" >&2; exit 2; }
for _fn in _sling_is_live _beadid_live_crew_owner _pilot_crew_stale_reclaim _beadid_branch_signal; do
  grep -q "^${_fn}()" "$FNS2" || { echo "FATAL: $_fn not extracted from $PD" >&2; exit 2; }
done
BDLOG="$TMP/bd.log"; : > "$BDLOG"
CXRC=""; CXOUT=""
cx() { # <lib|nolib> <repos> <snippet>  → CXRC, CXOUT (stdout+stderr of the snippet); fresh `set -euo pipefail` shell
  local _mode="$1" _repos="$2" _snip="$3" _r
  _r="$(FNS2="$FNS2" LIB="$LIB" BDLOG="$BDLOG" bash -c '
    set -euo pipefail
    mode="$1"; repos="$2"; snip="$3"
    . "$FNS2"
    if [ "$mode" = lib ]; then . "$LIB"; fi
    _OWNERSHIP_GUARD_REPOS="$repos"
    STALE_SLING_SECONDS=10800; GC_CITY=/stub-city; PILOT_STUCK_INFLIGHT_HOURS=1; PILOT_ORPHAN_BRANCH_STALE_HOURS=24
    _DEADWORKER_OK=1; PILOT_BEAD_STATE_PY_OVERRIDE=/nonexistent/bead_state.py
    rc=0; out=$(eval "$snip" 2>&1) || rc=$?
    printf "%s\n%s" "$rc" "$out"
  ' _ "$_mode" "$_repos" "$_snip")"
  CXRC="${_r%%$'\n'*}"; CXOUT="${_r#*$'\n'}"; [ "$_r" = "$CXRC" ] && CXOUT=""; return 0
}
cxexpect() { # label want_rc out_substring(or "") mode repos snippet — substring must appear in the output ("" = no check)
  local _label="$1" _wrc="$2" _wsub="$3"; shift 3
  cx "$@"
  if [ "$CXRC" = "$_wrc" ] && { [ -z "$_wsub" ] || case "$CXOUT" in *"$_wsub"*) true ;; *) false ;; esac; }; then
    ok "$_label"
  else
    bad "$_label — want rc=$_wrc out~'$_wsub', got rc=$CXRC out='$CXOUT'"
  fi
}

# 9a. _sling_is_live — an OPEN sling idle past STALE_SLING_SECONDS with no branch is declared DEAD and
#     its bead released; a branch (rc 0) or "could not tell" (rc 2) must keep it LIVE.
cxexpect "sling idle 6y, target has NO branch (looked, none) → DEAD, released (the release path is reachable)" 1 "" lib "$R" '_sling_is_live sl-1 /x ga-none'
cxexpect "sling idle 6y, target HAS a branch                → LIVE"                                           0 "" lib "$R" '_sling_is_live sl-1 /x ga-feat'
cxexpect "lib NOT loaded → could not tell → LIVE, and says so (a deploy fault must not release a bead)"       0 "kept LIVE" nolib "$R" '_sling_is_live sl-1 /x ga-none'
cxexpect "repo git cannot open → could not tell → LIVE"                                                      0 "kept LIVE" lib "$BROKEN" '_sling_is_live sl-1 /x ga-none'
cxexpect "one repo says none, another is unreadable → NOT confirmed none → LIVE"                             0 "kept LIVE" lib "$BROKEN"$'\n'"$R" '_sling_is_live sl-1 /x ga-none'

# 9b. the phantom-claim guard (_beadid_live_crew_owner): a crew owner with a live session but a STALE
#     bead and NO branch is a phantom → rc 1 (release for the pool). rc 0 + the owner on stdout = keep.
export PILOT_TEST_PHANTOM_STALE_BEADS="ga-none ga-feat"
cxexpect "stale + looked at every repo, no branch → PHANTOM, released (rc 1)"                                 1 ""            lib "$R" '_beadid_live_crew_owner ga-none /stub-db'
cxexpect "stale + a delivery branch exists → owner KEPT"                                                      0 "alice-wa"    lib "$R" '_beadid_live_crew_owner ga-feat /stub-db'
cxexpect "stale + lib NOT loaded → could not tell → owner KEPT, loudly"                                       0 "KEEPS crew owner of ga-none" nolib "$R" '_beadid_live_crew_owner ga-none /stub-db'
cxexpect "stale + unreachable origin, no local branch → owner KEPT, loudly"                                   0 "KEEPS crew owner of ga-none" lib "$DEADREMOTE" '_beadid_live_crew_owner ga-none /stub-db'
cxexpect "stale + repo git cannot open → owner KEPT"                                                          0 "alice-wa"    lib "$BROKEN" '_beadid_live_crew_owner ga-none /stub-db'
cxexpect "stale + no origin configured, no branch → nothing to ask is an answer → PHANTOM, released"          1 ""            lib "$NOORIGIN" '_beadid_live_crew_owner ga-none /stub-db'
PILOT_TEST_PHANTOM_STALE_BEADS="ga-feat"
cxexpect "control: NOT stale + no branch → owner KEPT (staleness still gates the release)"                    0 "alice-wa"    lib "$R" '_beadid_live_crew_owner ga-none /stub-db'
unset PILOT_TEST_PHANTOM_STALE_BEADS

# 9c. _beadid_branch_signal passes the third state through (its non-releasing callers read any non-zero as "no signal").
cxexpect "branch signal: a branch → rc 0 with a class"                                                        0 "block"       lib "$R" '_beadid_branch_signal ga-feat "{\"assignee\":\"alice-wa\"}"'
cxexpect "branch signal: looked, none → rc 1, empty"                                                          1 ""            lib "$R" '_beadid_branch_signal ga-none "{}"'
cxexpect "branch signal: could not tell → rc 2 (NOT 1), empty"                                                2 ""            nolib "$R" '_beadid_branch_signal ga-none "{}"'

# 9d. _pilot_crew_stale_reclaim — a stale crew bead with NO branch anywhere is unassigned; anything unverifiable is left alone.
NOW_EPOCH="$(date +%s)"
ROW_NONE='[{"id":"ga-none","_rig_db":"/stub-db","assignee":"alice-wa","updated_at":"2020-01-01T00:00:00Z"}]'
ROW_FEAT='[{"id":"ga-feat","_rig_db":"/stub-db","assignee":"alice-wa","updated_at":"2020-01-01T00:00:00Z"}]'
reclaim() { # <lib|nolib> <repos> <row-json>  → CXRC/CXOUT, and BDLOG holds every bd call the function made
  : > "$BDLOG"
  cx "$1" "$2" "_pilot_crew_stale_reclaim '$3' $NOW_EPOCH"
}
reclaim lib "$R" "$ROW_NONE"
if [ "$CXRC" = 0 ] && grep -q ' assign ga-none ' "$BDLOG"; then ok "no branch anywhere (every repo answered) → RECLAIMED: unassigned (the release path is reachable)"; else bad "reclaim of a branch-less stale bead did not happen — rc=$CXRC out='$CXOUT' bdlog='$(cat "$BDLOG")'"; fi
reclaim lib "$R" "$ROW_FEAT"
if [ "$CXRC" = 0 ] && ! grep -q ' assign ' "$BDLOG"; then ok "a delivery branch exists → NOT reclaimed"; else bad "bead with a branch was reclaimed — rc=$CXRC bdlog='$(cat "$BDLOG")'"; fi
reclaim nolib "$R" "$ROW_NONE"
if [ "$CXRC" = 0 ] && ! grep -q ' assign ' "$BDLOG" && case "$CXOUT" in *"NOT reclaiming stale in-flight ga-none"*) true ;; *) false ;; esac; then
  ok "lib NOT loaded → could not tell → NOT reclaimed, and the log says why"
else bad "lib-less sweep reclaimed (or stayed silent) — rc=$CXRC out='$CXOUT' bdlog='$(cat "$BDLOG")'"; fi
reclaim lib "$DEADREMOTE" "$ROW_NONE"
if [ "$CXRC" = 0 ] && ! grep -q ' assign ' "$BDLOG"; then ok "unreachable origin, no local branch → NOT reclaimed"; else bad "reclaimed on an unreachable origin — rc=$CXRC bdlog='$(cat "$BDLOG")'"; fi
reclaim lib "$BROKEN" "$ROW_NONE"
if [ "$CXRC" = 0 ] && ! grep -q ' assign ' "$BDLOG"; then ok "repo git cannot open → NOT reclaimed"; else bad "reclaimed on an unreadable repo — rc=$CXRC bdlog='$(cat "$BDLOG")'"; fi
reclaim lib "$BROKEN"$'\n'"$R" "$ROW_NONE"
if [ "$CXRC" = 0 ] && ! grep -q ' assign ' "$BDLOG"; then ok "one repo says none, another is unreadable → NOT reclaimed (none must be confirmed everywhere)"; else bad "reclaimed with an unreadable repo in the scan — rc=$CXRC bdlog='$(cat "$BDLOG")'"; fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
