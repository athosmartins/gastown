#!/usr/bin/env bash
# pilot-dispatcher.empty-branch.selftest.sh — ga-qcrgi9k: a bead whose worker died AFTER creating its branch and BEFORE
# its first commit was never dispatched again. wa-eosi8l (13/11, reboot): branch crew/wa-worker/wa-eosi8l @ 2b01484294,
# an ancestor of origin/main (0 commits of its own), the work sitting UNCOMMITTED in the worktree. Every sweep the Pilot
# re-admitted the bead (ga-46wq5: owner not active) and _filter_built threw it out again: "branch ... exists".
#
# Root cause: "the tip is an ancestor of origin/main" was read as "already delivered" (_beadid_branch_signal -> class
# merged, and _filter_built vetoes merged). A branch that never got a commit satisfies the same predicate.
#
# What this proves (real git repos, the REAL functions cut out of the dispatcher, no bd/gc/network):
#   S1  _beadid_branch_signal: a branch whose tip is in origin/main AND that no commit of origin/main names the bead
#       for is class `empty`, not `merged` — also with a (dead) owner in the bead JSON, also as a fetched origin ref,
#       also when the tip IS origin/main. A real delivery (a commit naming the bead is on main) stays `merged`; an
#       unmerged branch stays `block`. Third state: when git cannot answer the history question the class stays
#       `merged` (the veto of before), never `empty`. S1b: that history search starts a day before the bead existed
#       (a whole-history scan per bead per call is what a reboot would multiply) and falls back to the whole history
#       when the bead has no usable created_at.
#   S2  _filter_built: the empty-branch bead stays a candidate; merged / in-flight beads are still dropped; a gate:*
#       label or an open gate marker still drops it ("no marker, no label" is part of the contract).
#   S3  the two other callers: _ownership_guard_should_refuse does not refuse on `empty`, still refuses `block`;
#       _pilot_crew_stale_reclaim leaves a crew-owned bead with an empty branch alone (as it did with `merged`).
#   S4  _beadid_dirty_worktrees: the worktrees of the bead with uncommitted work, in three states (found / none /
#       could not tell); a child bead's worktree (<id>.1) does not count; agrees with _beadid_has_live_worktree.
#   S5  resume_directive_for + its wiring in dispatch_one: the builder is told to RESUME the dirty worktree and never to
#       remove it; nothing is said when there is none; "could not tell" gets a generic caution, not silence.
#
# PD_UNDER_TEST=<path to another pilot-dispatcher.sh> runs the same assertions against a different tree: that is how
# "fails before the fix" is proven (point it at the parent commit's file).
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
command -v git >/dev/null 2>&1 || { echo "FATAL: git missing" >&2; exit 2; }
REAL_GIT="$(command -v git)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pilot-empty-branch-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
echo "── pilot-dispatcher empty-branch (ga-qcrgi9k)${PD_UNDER_TEST:+ — UNDER TEST: $PD_UNDER_TEST} ──"

# ── the REAL functions (signature line .. first top-level "}"); a function the tree under test lacks is simply absent ──
FNS="$TMP/fns.sh"
: > "$FNS"
for _fn in _delivery_branch_patterns_ready _delivery_branch_local_ref _delivery_branch_listed_ref _delivery_branch_remote_hit \
           _beadid_matched_crew_branch_ref _beadid_branch_signal _filter_built _ownership_guard_should_refuse \
           _pilot_crew_stale_reclaim _pilot_owner_state _pilot_release_owner \
           _beadid_has_live_worktree _beadid_dirty_worktrees resume_directive_for _pilot_dog_lend_prompt; do
  awk -v n="$_fn" '$0 ~ "^"n"\\(\\) *\\{" {f=1} f {print} f && /^}$/ {exit}' "$PD" >> "$FNS"
done
# Everything those functions call and this test does not exercise: no gate artifact, no attached session, no live owner.
cat >> "$FNS" <<'STUBS'
_ownership_guard_repos() { return 0; }
_beadid_has_active_gate_artifact() { return 1; }
_beadid_has_open_gate_marker() { case " ${OPEN_MARKER_IDS:-} " in *" $1 "*) return 0 ;; esac; return 1; }
_ownership_guard_flag_orphan_branch() { :; }
_beadid_mentioned_in_attached_session() { return 1; }
_session_is_active_owner() { return 1; }
log() { printf '[pilot-dispatcher] %s\n' "$*"; }          # like the real log/warn: STDOUT — a line that forgets its >&2 corrupts the JSON stream
warn() { printf '[pilot-dispatcher] WARN: %s\n' "$*"; }
timeout() { shift; "$@"; }
# bd: the fresh re-read of the guard answers "open, nobody owns it"; every call is logged for the reclaim checks.
bd() {
  echo "bd $*" >> "${BD_LOG:-/dev/null}"
  case " $* " in
    *" show "*) if [ -n "${BD_CLEARED_FILE:-}" ] && [ -e "$BD_CLEARED_FILE" ]; then printf '[{"status":"open"}]'; else printf '[{"status":"in_progress","assignee":"batista-wa","labels":[]}]'; fi ;;
    *" update "*"--assignee"*) [ -n "${BD_CLEARED_FILE:-}" ] && : > "$BD_CLEARED_FILE" ;;
  esac
  return 0
}
STUBS
bash -n "$FNS" 2>/dev/null || { echo "FATAL: extracted functions do not parse" >&2; exit 2; }

# ── fixture: a rig clone R with a bare origin; origin/main has 6 commits, two of them naming a bead ───────────────
ORIGIN="$TMP/origin.git"; R="$TMP/rig"
git init -q --bare "$ORIGIN"
git init -q "$R"
git -C "$R" config user.email t@t.invalid
git -C "$R" config user.name selftest
N=0; NOW="$(date +%s)"; D12=$((NOW - 12*86400)); D11=$((NOW - 11*86400)); D10=$((NOW - 10*86400))
mkc() { # <message> [commit epoch]
  N=$((N+1)); echo "$N" > "$R/f$N.txt"; git -C "$R" add "f$N.txt"
  if [ -n "${2:-}" ]; then GIT_AUTHOR_DATE="@$2" GIT_COMMITTER_DATE="@$2" git -C "$R" commit -q -m "$1"; else git -C "$R" commit -q -m "$1"; fi
}
iso() { jq -rn --argjson e "$1" '$e | todate'; }
echo base > "$R/README"; git -C "$R" add README; GIT_AUTHOR_DATE="@$D12" GIT_COMMITTER_DATE="@$D12" git -C "$R" commit -q -m "init"
MAINBR="$(git -C "$R" symbolic-ref --short HEAD)"
mkc "feat(wa-prior01): groundwork" "$D11";     C1="$(git -C "$R" rev-parse HEAD)"
mkc "fix(wa-done01): delivered work" "$D10";   C2="$(git -C "$R" rev-parse HEAD)"
mkc "chore: later main work";                  C3="$(git -C "$R" rev-parse HEAD)"
mkc "docs(wa-redo01): first attempt notes";    C4="$(git -C "$R" rev-parse HEAD)"
mkc "chore: newest main commit";               C5="$(git -C "$R" rev-parse HEAD)"
mkc "chore: wa-litX1 is another bead's note";  C6="$(git -C "$R" rev-parse HEAD)"   # matches the REGEX wa-lit.1, not the id wa-lit.1
git -C "$R" remote add origin "$ORIGIN"
git -C "$R" push -q origin "HEAD:refs/heads/main" 2>/dev/null
git -C "$R" fetch -q origin 2>/dev/null
# the branches
git -C "$R" branch crew/wa-worker/wa-empty01 "$C1"        # THE BUG: created on an old main commit, never committed to
git -C "$R" branch crew/wa-worker/wa-empty02 "$C6"        # tip IS origin/main
git -C "$R" branch crew/wa-worker/wa-lit.1 "$C6"           # empty; the id has a dot — a REGEX match on it would find C6 and call it merged
git -C "$R" branch crew/wa-worker/wa-empty03 "$C3"        # only as a fetched origin ref (below)
git -C "$R" push -q origin crew/wa-worker/wa-empty03 2>/dev/null
git -C "$R" branch -D crew/wa-worker/wa-empty03 >/dev/null 2>&1
git -C "$R" branch fix/wa-done01-slug "$C2"                # a real delivery: its tip is on main and a commit there names the bead
git -C "$R" branch crew/wa-worker/wa-redo01 "$C3"          # empty, but main already holds a commit naming the bead (C4)
git -C "$R" checkout -q -b crew/wa-worker/wa-live01 "$C6"  # unmerged: a commit of its own
mkc "fix(wa-live01): work in progress"
git -C "$R" checkout -q "$MAINBR"
git -C "$R" branch crew/wa-worker/wa-kid01.1 "$C1"         # a CHILD bead's branch
# the worktrees, named like production (<rig>/crew/worker-<bead>)
mkdir -p "$R/crew"
git -C "$R" worktree add "$R/crew/worker-wa-empty01" crew/wa-worker/wa-empty01 >/dev/null 2>&1
echo "uncommitted edit" >> "$R/crew/worker-wa-empty01/README"; echo "new file" > "$R/crew/worker-wa-empty01/new_file.txt"   # DIRTY: tracked + untracked
git -C "$R" worktree add "$R/crew/worker-wa-empty02" crew/wa-worker/wa-empty02 >/dev/null 2>&1                                     # clean
git -C "$R" worktree add "$R/crew/worker-wa-kid01.1" crew/wa-worker/wa-kid01.1 >/dev/null 2>&1
echo "kid edit" >> "$R/crew/worker-wa-kid01.1/README"                                                                              # dirty, but a CHILD's
git -C "$R" branch crew/wa-worker/wa-gone01 "$C1"                                                                                   # registered worktree whose directory is gone
git -C "$R" worktree add "$R/crew/worker-wa-gone01" crew/wa-worker/wa-gone01 >/dev/null 2>&1
echo "lost" >> "$R/crew/worker-wa-gone01/README"
mv "$R/crew/worker-wa-gone01" "$TMP/gone-wt"
git -C "$R" worktree add --detach "$R/crew/wa-det01" "$C1" >/dev/null 2>&1                                                          # no branch at all: found by its directory name
echo "detached edit" >> "$R/crew/wa-det01/README"
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"                                                                                               # a directory with no git at all
BROKEN="$TMP/broken"; mkdir -p "$BROKEN"; printf 'gitdir: /nonexistent/nowhere\n' > "$BROKEN/.git"                                 # has a .git git will not open
# a git that fails when asked a given subcommand (SHIM_FAIL=log|status|worktree), everything else is the real one;
# SHIM_ONLY=<repo path> narrows the failure to calls that also name that path (git -C <path> ...); SHIM_LOG=<file> records every call's arguments
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<'SHIM'
#!/bin/sh
[ -z "${SHIM_LOG:-}" ] || printf '%s\n' "$*" >> "$SHIM_LOG"
if [ -n "${SHIM_FAIL:-}" ]; then
  hit=0; only=1
  for a in "$@"; do [ "$a" = "$SHIM_FAIL" ] && hit=1; done
  if [ -n "${SHIM_ONLY:-}" ]; then only=0; for a in "$@"; do [ "$a" = "$SHIM_ONLY" ] && only=1; done; fi
  [ "$hit" = 1 ] && [ "$only" = 1 ] && { echo "fatal: shim says no" >&2; exit 128; }
fi
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$TMP/shim/git"
R2="$TMP/rig2"; git init -q "$R2"; git -C "$R2" config user.email t@t.invalid; git -C "$R2" config user.name selftest
git -C "$R2" commit -q --allow-empty -m init                                                                                        # a second, healthy repo with no worktrees
mkdir -p "$TMP/nogit"; ln -s "$(command -v bash)" "$TMP/nogit/bash"                                                                 # a PATH with bash and nothing else

# ── runner: a fresh `set -euo pipefail` shell like the dispatcher's; sets RC, OUT, ERR ───────────────────────────────
TAB=$'\t'; NL=$'\n'; RC=0; OUT=""; ERR=""
run() { # <env assignments (may be empty; no spaces inside a value)> <snippet>
  local _env="$1" _snip="$2"
  RC=0
  OUT="$(env FNS="$FNS" LIB="$LIB" R="$R" REAL_GIT="$REAL_GIT" TMP="$TMP" NL="$NL" $_env bash -c '
    set -euo pipefail
    . "$FNS"; . "$LIB"
    _OWNERSHIP_GUARD_REPOS="${REPOS-$R}"; _NS_BRANCH_REPOS="${REPOS-$R}"; _NS_RIG_LIST_OK="${RIGOK-1}"; GC_CITY=/nonexistent
    if [ -n "${REPOS2:-}" ]; then _OWNERSHIP_GUARD_REPOS="$_OWNERSHIP_GUARD_REPOS$NL$REPOS2"; _NS_BRANCH_REPOS="$_NS_BRANCH_REPOS$NL$REPOS2"; fi
    SELF_BEAD_ID=self-bead; _DEADWORKER_OK=0; PILOT_ORPHAN_BRANCH_STALE_HOURS=48
    PILOT_TEST_GATE_OPEN_BEADS=""
    '"$_snip" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err" 2>/dev/null)"
}
class_of() { printf '%s' "${OUT%%$'\t'*}"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1 — want '$2' got '$3'"; }
has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in: $(printf '%s' "$3" | head -c 300)" ;; esac; }
hasnt() { case "$3" in *"$2"*) bad "$1 — '$2' unexpectedly in: $(printf '%s' "$3" | head -c 300)" ;; *) ok "$1" ;; esac; }
sig() { # <bead> [env assignments] [bead json]
  local _j="${3-}"; [ -n "$_j" ] || _j='{}'
  run "${2:-}" "_beadid_branch_signal $1 '$_j'"
}

echo "── S1. _beadid_branch_signal: an empty branch is not 'merged' ──"
sig wa-empty01;                  eq "branch with no commit of its own, tip older than main → empty" "empty" "$(class_of)"
has "…and names the ref"         "crew/wa-worker/wa-empty01" "$OUT"
sig wa-empty01 "" '{"id":"wa-empty01","assignee":"wa-worker-adhoc-9f68f8533a","status":"in_progress"}'
eq "…with the dead owner still in the bead JSON (the wa-eosi8l shape) → empty" "empty" "$(class_of)"
sig wa-empty02;                  eq "tip IS origin/main → empty" "empty" "$(class_of)"
sig wa-empty03;                  eq "only a fetched origin ref → empty, on the origin ref" "empty" "$(class_of)"
has "…(origin/<name>)"           "origin/crew/wa-worker/wa-empty03" "$OUT"
sig wa-done01;                   eq "a real delivery (a commit on main names the bead) stays merged" "merged" "$(class_of)"
sig wa-redo01;                   eq "empty branch but main already names the bead → merged (the veto of before, never a new loosening)" "merged" "$(class_of)"
sig wa-lit.1;                    eq "the id is matched LITERALLY ('.' is no wildcard: wa-litX1 on main is not wa-lit.1's delivery) → empty" "empty" "$(class_of)"
sig wa-live01;                   eq "an unmerged branch with a commit of its own stays block" "block" "$(class_of)"
sig wa-nobr01;                   eq "no branch at all → rc 1, no class" "1:" "$RC:$(class_of)"
# third state: git cannot read the history → not "no commit names the bead"
sig wa-empty01 "SHIM_FAIL=log PATH=$TMP/shim:$PATH"
eq "history unreadable (git log fails) → merged, NOT empty (failed is not empty)" "merged" "$(class_of)"

echo "── S1b. the history search is bounded by the bead's creation (a whole-history scan per bead per call is what a reboot would multiply) ──"
glog() { cat "$TMP/gitlog.txt"; }
sig wa-done01 "" "{\"id\":\"wa-done01\",\"created_at\":\"$(iso "$D12")\"}"
eq "a bead created before its delivery: the bounded search still finds the delivery → merged" "merged" "$(class_of)"
sig wa-done01 "" "{\"id\":\"wa-done01\",\"created_at\":\"$(iso $((D10 + 18000)))\"}"
eq "created 5 h AFTER the delivery commit (a retroactive bead): the 1-day margin still finds it → merged" "merged" "$(class_of)"
sig wa-done01 "" "{\"id\":\"wa-done01\",\"created_at\":\"$(iso "$NOW")\"}"
eq "created long AFTER that commit: it predates the bead, so it is not its delivery → empty" "empty" "$(class_of)"
: > "$TMP/gitlog.txt"
sig wa-empty01 "SHIM_LOG=$TMP/gitlog.txt PATH=$TMP/shim:$PATH" "{\"id\":\"wa-empty01\",\"created_at\":\"$(iso "$D12")\"}"
has "the bound reaches git: --since=<created_at - 1 day>" "log origin/main -n 1 --format=%H -F --since=@$((D12 - 86400)) --grep=wa-empty01" "$(glog)"
for _cj in '{}' '{"created_at":"not a date"}' 'this is not json at all' "{\"created_at\":\"$(iso $((NOW + 5*86400)))\"}"; do
  : > "$TMP/gitlog.txt"
  sig wa-done01 "SHIM_LOG=$TMP/gitlog.txt PATH=$TMP/shim:$PATH" "$_cj"
  case "$(glog)" in *"log origin/main"*"--since"*) bad "created_at $_cj gave a bounded search" ;; *"log origin/main"*) ok "no usable created_at ($_cj) → the search is unbounded" ;; *) bad "git log was not called for $_cj" ;; esac
  eq "…and the verdict does not change (merged)" "merged" "$(class_of)"
done

echo "── S2. _filter_built ──"
ALL='[{"id":"wa-empty01","labels":[],"assignee":""},{"id":"wa-empty02","labels":[]},{"id":"wa-empty03","labels":[]},{"id":"wa-done01","labels":[]},{"id":"wa-redo01","labels":[]},{"id":"wa-live01","labels":[]},{"id":"wa-nobr01","labels":[]}]'
fb() { run "$1" "printf '%s' '$2' | _filter_built | jq -c '[.[].id] | sort'"; }
fb "" "$ALL"
eq "empty-branch beads stay candidates; merged and in-flight ones are dropped" '["wa-empty01","wa-empty02","wa-empty03","wa-nobr01"]' "$OUT"
has   "the kept empty branch is said out loud, with the reason (the log line)" "wa-empty01 has branch" "$ERR"
has   "…the reason is that it carries no commit of its own" "no commit of its own" "$ERR"
hasnt "…and it is NOT reported as EXCLUÍDO" "EXCLUÍDO wa-empty01" "$ERR"
has   "control: the merged bead is still reported EXCLUÍDO" "EXCLUÍDO wa-done01" "$ERR"
fb "" '[{"id":"wa-empty01","labels":["gate:passed"]}]'
eq "an empty branch WITH a gate:* label is still dropped" '[]' "$OUT"
fb "OPEN_MARKER_IDS=wa-empty01" '[{"id":"wa-empty01","labels":[]}]'
eq "an empty branch with an OPEN gate marker is still dropped" '[]' "$OUT"
fb "" '[{"id":"wa-empty01","labels":["gate:needs-fix"]}]'
eq "gate:needs-fix keeps its own carve-out (candidate)" '["wa-empty01"]' "$OUT"

echo "── S3. the other callers of the signal ──"
: > "$TMP/yes"   # BD_CLEARED_FILE that exists = the fresh re-read says "open, nobody owns it"
guard() { run "BD_CLEARED_FILE=$TMP/yes" "_ownership_guard_should_refuse $1 '{\"id\":\"$1\",\"assignee\":\"\",\"labels\":[]}' /fake"; }
guard wa-empty01; eq "dispatch-time guard: empty branch → not refused (rc 1, silent)" "1:" "$RC:$OUT"
guard wa-done01;  eq "…merged → not refused" "1:" "$RC:$OUT"
guard wa-live01;  has "…an in-flight branch is still refused" "branch:crew/wa-worker/wa-live01" "$OUT"
reclaim() { # <bead id> → exit of the caller and the bd log
  : > "$TMP/bd.log"; rm -f "$TMP/cleared"
  run "BD_LOG=$TMP/bd.log BD_CLEARED_FILE=$TMP/cleared" "PILOT_STUCK_INFLIGHT_HOURS=2; _pilot_crew_stale_reclaim '[{\"id\":\"$1\",\"_rig_db\":\"/fake/wa\",\"assignee\":\"batista-wa\",\"updated_at\":\"2020-01-01T00:00:00Z\"}]' 9999999999"
}
reclaim wa-empty01
if [ "$RC" -eq 0 ] && ! grep -q ' update wa-empty01 ' "$TMP/bd.log" && ! grep -q ' label remove wa-empty01 ' "$TMP/bd.log"; then
  ok "stale reclaim: a crew-owned bead with an empty branch is left alone (rc $RC, no bd write)"
else bad "stale reclaim touched an empty-branch bead (rc $RC): $(cat "$TMP/bd.log")"; fi
reclaim wa-nobr01
if grep -q ' update wa-nobr01 --if-assignee batista-wa ' "$TMP/bd.log"; then ok "stale reclaim control: a never-branched crew bead IS reclaimed"
else bad "stale reclaim control failed (rc $RC): $(cat "$TMP/bd.log")"; fi

echo "── S4. _beadid_dirty_worktrees ──"
dw() { run "${2:-}" "_beadid_dirty_worktrees $1"; }
dw wa-empty01;  eq "dirty worktree (tracked edit + untracked file) → found" "0" "$RC"
has "…its path"   "crew/worker-wa-empty01" "$OUT"
has "…its branch" "${TAB}crew/wa-worker/wa-empty01" "$OUT"
dw wa-det01;    eq "a detached dirty worktree (no branch) found by its directory name → found, branch shown as (detached)" "0" "$RC"
has "…(detached)" "${TAB}(detached)" "$OUT"
dw wa-empty02;  eq "clean worktree → none (rc 1, silent)" "1:" "$RC:$OUT"
dw wa-nobr01;   eq "no worktree for the bead → none" "1:" "$RC:$OUT"
dw wa-kid01;    eq "only a CHILD bead's (wa-kid01.1) worktree is dirty → none for the parent" "1:" "$RC:$OUT"
dw wa-empty01 "SHIM_FAIL=status PATH=$TMP/shim:$PATH"
eq "git status fails → could not tell (rc 2), not none" "2" "$RC"
dw wa-empty01 "SHIM_FAIL=worktree PATH=$TMP/shim:$PATH"
eq "git worktree list fails → could not tell (rc 2)" "2" "$RC"
dw wa-empty01 "REPOS="
eq "no repo list → could not tell (rc 2)" "2" "$RC"
dw wa-empty01 "PATH=$TMP/nogit"
eq "no git on PATH → could not tell (rc 2)" "2" "$RC"
dw wa-nobr01 "REPOS=$R REPOS2=$R2 SHIM_FAIL=worktree SHIM_ONLY=$R2 PATH=$TMP/shim:$PATH"
eq "one repo's worktree list fails, the other is read and has none → could not tell (rc 2): the failed one was never read" "2" "$RC"
dw wa-empty01 "REPOS=$R2 REPOS2=$R SHIM_FAIL=worktree SHIM_ONLY=$R2 PATH=$TMP/shim:$PATH"
eq "…and a dirty worktree found in the readable repo still wins over the failed one (rc 0)" "0" "$RC"
dw wa-nobr01 "SHIM_FAIL=status PATH=$TMP/shim:$PATH"
eq "…a failing status of a worktree that is NOT this bead's changes nothing (none)" "1" "$RC"
dw wa-gone01;   eq "a registered worktree whose directory is gone holds nothing → none (rc 1), not could-not-tell" "1:" "$RC:$OUT"
dw wa-nobr01 "RIGOK=0"
eq "gc rig list failed (_NS_RIG_LIST_OK=0): 'none' would rest on a town-root-only list → could not tell (rc 2)" "2" "$RC"
dw wa-empty01 "RIGOK=0"
eq "…but a dirty worktree that WAS found still wins (rc 0)" "0" "$RC"
dw wa-nobr01 "REPOS=$PLAIN"
eq "a repo list with no git repo in it was never READ → could not tell (rc 2), not none" "2" "$RC"
dw wa-nobr01 "REPOS=$BROKEN"
eq "a repo whose .git git will not open → could not tell (rc 2)" "2" "$RC"
dw wa-empty01 "REPOS=$BROKEN REPOS2=$R"
eq "an unreadable repo plus a readable one that HAS the dirty worktree → found (rc 0)" "0" "$RC"
dw wa-nobr01 "REPOS=$BROKEN REPOS2=$R"
eq "…the same two repos for a bead with none → still could not tell (rc 2): the broken one was never read" "2" "$RC"
# drift guard against the NEVERSTARTED twin (ga-9jrt3o7): the same fixtures, the same verdict
for _b in wa-empty01 wa-empty02 wa-nobr01 wa-kid01; do
  run "" "_beadid_has_live_worktree $_b"; _tw="$RC"
  run "" "_beadid_dirty_worktrees $_b"; _nw="$RC"
  case "$_b:$_tw:$_nw" in
    wa-empty01:0:0|wa-empty02:1:1|wa-nobr01:1:1|wa-kid01:1:1) ok "twin agrees on $_b (live_worktree rc $_tw, dirty_worktrees rc $_nw)" ;;
    *) bad "twin disagrees on $_b: _beadid_has_live_worktree rc $_tw, _beadid_dirty_worktrees rc $_nw" ;;
  esac
done

echo "── S5. resume_directive_for and its wiring ──"
rd() { run "${2:-}" "resume_directive_for $1"; }
rd wa-empty01
has "dirty worktree → the builder is told to RESUME" "RESUME" "$OUT"
has "…names the worktree" "crew/worker-wa-empty01" "$OUT"
has "…names the branch" "crew/wa-worker/wa-empty01" "$OUT"
has "…forbids removing it" "git worktree remove" "$OUT"
rd wa-empty02;  eq "clean worktree → no directive (empty output, rc 0)" "0:" "$RC:$OUT"
rd wa-nobr01;   eq "no worktree → no directive" "0:" "$RC:$OUT"
rd wa-empty01 "SHIM_FAIL=status PATH=$TMP/shim:$PATH"
has "could not tell → a generic caution, not silence" "could not check" "$OUT"
hasnt "…and it does not claim a worktree was found" "crew/worker-wa-empty01" "$OUT"
# the third prompt that tells a builder to create a worktree: a rig bead lent to a dog (pool full)
lend() { run "" "_pilot_dog_lend_prompt $1 'A title' 1 wa-worker whatsapp_automation $R bug; printf '%s' \"\$_PDL_TASK\""; }
lend wa-empty01
has "dog-lend prompt: a dirty worktree of the bead is handed to the dog to RESUME" "RESUME" "$OUT"
has "…and names it" "crew/worker-wa-empty01" "$OUT"
has "…the original steps are all still there (the block is appended, nothing replaced)" "worktree add" "$OUT"
lend wa-empty02
hasnt "dog-lend prompt: nothing to resume → no directive" "RESUME" "$OUT"
has "…and the prompt is the lend prompt" "LENT P1" "$OUT"
run "" "resume_directive_for() { return 7; }; _pilot_dog_lend_prompt wa-empty01 'A title' 1 wa-worker whatsapp_automation $R bug; printf '%s' \"\$_PDL_TASK\""
case "$RC:$OUT" in 0:LENT\ P1*) ok "dog-lend prompt: resume_directive_for failing (rc 7) neither aborts the lend nor changes the prompt" ;; *) bad "dog-lend prompt: a failing resume_directive_for broke the lend (rc $RC): $(printf '%s' "$OUT" | head -c 120)" ;; esac
# The pools never see the task prompt (rig-native beads are self-served): the same rule must sit in their Build Protocol, BEFORE the worktree add.
for _pool in wa-worker ps-worker; do
  _pf="$SELF_DIR/../../../agents/$_pool/prompt.template.md"
  _proto="$(awk '/^## Build Protocol/ {f=1; next} f && /^## / {exit} f {print}' "$_pf" 2>/dev/null)"
  if [ -z "$_proto" ]; then bad "$_pool prompt: Build Protocol section not found at $_pf"; continue; fi
  _rl="$(printf '%s\n' "$_proto" | grep -n -F 'RESUME' | head -1 | cut -d: -f1)"
  _al="$(printf '%s\n' "$_proto" | grep -n -F 'git worktree add ../worker-<id>' | head -1 | cut -d: -f1)"
  if [ -n "$_rl" ] && [ -n "$_al" ] && [ "$_rl" -lt "$_al" ]; then ok "$_pool prompt: the Build Protocol says RESUME an existing worktree before it says worktree add"
  else bad "$_pool prompt: no resume rule ahead of the worktree add (RESUME at line '${_rl:-none}', worktree add at '${_al:-none}')"; fi
  has "$_pool prompt: …and looks for the existing worktree first" "git worktree list | grep <id>" "$_proto"
  has "$_pool prompt: …and forbids removing a dirty one" "NEVER git worktree remove" "$_proto"
done
DISPATCH_BODY="$(awk '/^dispatch_one\(\) *\{/ {f=1} f {print} f && /^}$/ {exit}' "$PD")"
WIRE_TXT='WORKTREE_DIRECTIVE="${WORKTREE_DIRECTIVE}$(resume_directive_for "$STORY_ID"'
WIRE_LN="$(printf '%s\n' "$DISPATCH_BODY" | grep -n -F "$WIRE_TXT" | head -1 | cut -d: -f1)"
WIRE_LINE="$(printf '%s\n' "$DISPATCH_BODY" | grep -F "$WIRE_TXT" | head -1)"
HEREDOC_LN="$(printf '%s\n' "$DISPATCH_BODY" | grep -n 'DISPATCH_TASK=\$(cat <<TASK' | head -1 | cut -d: -f1)"
if [ -n "$WIRE_LN" ] && [ -n "$HEREDOC_LN" ] && [ "$WIRE_LN" -lt "$HEREDOC_LN" ]; then
  ok "dispatch_one fills the directive slot from resume_directive_for before it builds the task prompts"
else bad "dispatch_one does not extend WORKTREE_DIRECTIVE from resume_directive_for \"\$STORY_ID\" ahead of the task prompts (wiring at line '${WIRE_LN:-none}', prompt at '${HEREDOC_LN:-none}')"; fi
case "$(printf '%s\n' "$DISPATCH_BODY" | grep -c '^\$WORKTREE_DIRECTIVE$')" in 2) ok "the two task prompts still carry the directive slot exactly once each (templates untouched)" ;; *) bad "task prompt slots changed" ;; esac
# the REAL wiring line, executed: it must extend the slot, leave it byte for byte alone when there is nothing to say, and never abort dispatch
if [ -n "$WIRE_LINE" ]; then
  wire() { run "${2:-}" "${3:-}STORY_ID=$1; WORKTREE_DIRECTIVE=BASE-DIRECTIVE; $WIRE_LINE; printf '%s' \"\$WORKTREE_DIRECTIVE\""; }
  wire wa-empty01
  case "$OUT" in BASE-DIRECTIVE*RESUME*crew/worker-wa-empty01*) ok "wiring: the dirty worktree's directive is appended to the slot (after what was there)" ;; *) bad "wiring: slot not extended — got '$(printf '%s' "$OUT" | head -c 200)'" ;; esac
  wire wa-empty02;  eq "wiring: nothing to say → the slot is byte for byte what it was" "BASE-DIRECTIVE" "$OUT"
  wire wa-empty01 "" "resume_directive_for() { return 7; }; "
  eq "wiring: resume_directive_for failing (rc 7) neither aborts dispatch nor changes the slot" "0:BASE-DIRECTIVE" "$RC:$OUT"
  wire wa-empty01 "" "unset -f resume_directive_for; "
  eq "wiring: resume_directive_for not defined at all → the same (dispatch goes on)" "0:BASE-DIRECTIVE" "$RC:$OUT"
else bad "wiring line not found in dispatch_one — nothing to execute"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then echo "SELFTEST PASS"; exit 0; fi
echo "SELFTEST FAIL"; exit 1
