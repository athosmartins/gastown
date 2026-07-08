#!/usr/bin/env bash
# town-root-reconciler.selftest.sh — Regression harness for reconcile_tracked_for_ffpull
# (gt-yjr20 — recurring "town root diverged" FF jam on an uncommitted tracked edit).
#
# ROOT CAUSE this pins: reconcile_tracked_for_ffpull used to block the FF for ANY
# dirty tracked file whose working-tree bytes differ from the incoming origin/main
# version — even when the incoming FF DOES NOT modify that file at all. So a single
# uncommitted crew edit to a tracked file (e.g. skills/refino/SKILL.md) froze EVERY
# subsequent unrelated framework FF until a human committed/resolved it. Git's own
# `pull --ff-only` happily preserves an ORTHOGONAL uncommitted edit (a file the FF
# does not touch) and still advances — the reconciler was over-blocking.
#
# THE FIX: an edit is a genuine conflict ONLY when the incoming FF actually changes
# that file (upstream blob != HEAD blob) AND the local edit differs from the incoming
# version. If the incoming FF leaves the file alone (upstream blob == HEAD blob), the
# edit is orthogonal — preserve it, do NOT block. The FF lands and the edit survives.
#
# These scenarios drive the helper against THROWAWAY real git repos (no live root, no
# live Dolt, no gc). Scenario 1 replays the exact gt-yjr20 shape and proves the FF now
# lands; Scenarios 2/3/4 pin the ga-y3tx behaviors the fix must NOT regress (identical
# dup restore, genuine conflict still blocks, deleted-upstream skip). Scenario 5 mixes
# orthogonal + identical-dup + clean-incoming in one FF.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILER="$SCRIPT_DIR/town-root-reconciler.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/trr-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Source the reconciler as a library (guard skips the daemon loop). Point ROOT/CITY/
# LOG at the throwaway dir so nothing touches the live root or its logs.
export TOWN_ROOT_RECONCILER_LIB=1
export ROOT="$TMP" CITY="$TMP" LOG_DIR="$TMP" LOG="$TMP/reconciler.log"
# shellcheck disable=SC1090
source "$RECONCILER"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  BAD: $*"; }

# mk_repo <dir> — fresh git repo with deterministic identity, isolated from any
# parent repo (the worktree we run inside) via a ceiling at the repo dir.
mk_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main   # force 'main' regardless of init.defaultBranch
  git -C "$d" config user.email "selftest@local"
  git -C "$d" config user.name  "selftest"
  git -C "$d" config commit.gpgsign false
}

# A clean "upstream" is modeled by a local branch `upstream` that is strictly
# AHEAD of HEAD (HEAD stays on `main`). reconcile_tracked_for_ffpull takes the
# upstream as a ref string, so a branch name works exactly like "origin/main".

# ── Scenario 1: ORTHOGONAL uncommitted edit — the gt-yjr20 fix ────────────────
# Local has an uncommitted edit to skills/refino/SKILL.md; the incoming FF only
# changes an UNRELATED file. The edit must be preserved, the FF must NOT be blocked,
# and a real `git merge --ff-only` must land while keeping the edit.
echo "Scenario 1: orthogonal uncommitted tracked edit — FF must land, edit preserved (gt-yjr20)"
R="$TMP/s1"; mk_repo "$R"
mkdir -p "$R/skills/refino" "$R/scripts"
printf 'skill v1\n'   > "$R/skills/refino/SKILL.md"
printf 'pilot v1\n'   > "$R/scripts/pilot.sh"
git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'pilot v2 (framework fix)\n' > "$R/scripts/pilot.sh"   # incoming changes ONLY pilot.sh
git -C "$R" commit -q -am c1
git -C "$R" checkout -q main
# crew leaves an uncommitted edit on the tracked skill file:
printf 'skill v1\n+ anti-overlap section (uncommitted crew edit)\n' > "$R/skills/refino/SKILL.md"
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                && ok "returns 0 (does not block the FF)"            || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ "${ORTHOGONAL_COUNT:-x}" -eq 1 ] && ok "ORTHOGONAL_COUNT=1 (edit recognised as untouched-by-FF)" || bad "expected ORTHOGONAL_COUNT=1, got '${ORTHOGONAL_COUNT:-unset}'"
[ "${TRACKED_COUNT:-x}" -eq 0 ]    && ok "TRACKED_COUNT=0 (nothing restored)"           || bad "expected TRACKED_COUNT=0, got '${TRACKED_COUNT:-unset}'"
[ -z "${TRACKED_DIFF_LIST// /}" ]  && ok "no conflict recorded"                          || bad "TRACKED_DIFF_LIST should be empty, got '$TRACKED_DIFF_LIST'"
grep -q "anti-overlap" "$R/skills/refino/SKILL.md" && ok "local edit NOT clobbered"      || bad "local edit was clobbered"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS (jam gone)" || bad "FF still blocked after reconcile (the recurring jam)"
grep -q "anti-overlap" "$R/skills/refino/SKILL.md" && ok "edit survives the FF"          || bad "edit lost across the FF"
grep -q "pilot v2"    "$R/scripts/pilot.sh"        && ok "framework fix landed (pilot v2)" || bad "incoming framework fix did not land"

# ── Scenario 2: byte-identical tracked modification (ga-y3tx) — must restore + land
echo "Scenario 2: incoming changes a file; local edit is byte-identical to incoming → restore + FF"
R="$TMP/s2"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'v2\n' > "$R/a.sh"; git -C "$R" commit -q -am c1   # incoming changes a.sh -> v2
git -C "$R" checkout -q main
printf 'v2\n' > "$R/a.sh"                                  # local edited a.sh to the SAME v2 (uncommitted)
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                  && ok "returns 0"                              || bad "expected rc 0, got $rc"
[ "${TRACKED_COUNT:-x}" -eq 1 ]  && ok "TRACKED_COUNT=1 (identical dup restored)" || bad "expected TRACKED_COUNT=1, got '${TRACKED_COUNT:-unset}'"
[ "${ORTHOGONAL_COUNT:-x}" -eq 0 ] && ok "ORTHOGONAL_COUNT=0 (file IS changed by FF)" || bad "expected ORTHOGONAL_COUNT=0, got '${ORTHOGONAL_COUNT:-unset}'"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS" || bad "FF blocked"
[ "$(cat "$R/a.sh")" = "v2" ]    && ok "a.sh advanced to v2"                    || bad "a.sh not at v2"

# ── Scenario 3: genuine conflict — incoming changes the file, local edit differs → BLOCK
echo "Scenario 3: incoming changes a file AND local edit differs → must BLOCK (never clobber)"
R="$TMP/s3"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'upstream-v2\n' > "$R/a.sh"; git -C "$R" commit -q -am c1   # incoming changes a.sh
git -C "$R" checkout -q main
printf 'local-different\n' > "$R/a.sh"                              # local changed it to something else
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 2 ]                              && ok "returns 2 (blocks)"                    || bad "expected rc 2, got $rc"
case " $TRACKED_DIFF_LIST " in *" a.sh "*) ok "a.sh recorded in TRACKED_DIFF_LIST";; *) bad "a.sh not in TRACKED_DIFF_LIST ('$TRACKED_DIFF_LIST')";; esac
[ "$(cat "$R/a.sh")" = "local-different" ]   && ok "local edit NOT clobbered"             || bad "local edit was clobbered"

# ── Scenario 4: incoming DELETES the file; local edit present → skip, leave alone
echo "Scenario 4: incoming deletes the file → skip (not our concern), do not block"
R="$TMP/s4"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; printf 'keep\n' > "$R/b.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
git -C "$R" rm -q a.sh; git -C "$R" commit -q -m c1   # incoming deletes a.sh
git -C "$R" checkout -q main
printf 'local edit\n' > "$R/a.sh"                      # local edited the (still-tracked-here) a.sh
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                          && ok "returns 0 (deleted-upstream skipped)"     || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ -z "${TRACKED_DIFF_LIST// /}" ]        && ok "no conflict recorded"                     || bad "TRACKED_DIFF_LIST should be empty, got '$TRACKED_DIFF_LIST'"
[ "$(cat "$R/a.sh")" = "local edit" ]    && ok "local edit left untouched"               || bad "local edit was touched"

# ── Scenario 5: mixed — orthogonal edit + identical-dup + clean incoming in ONE FF
echo "Scenario 5: orthogonal edit + byte-identical dup + unrelated clean change → land all"
R="$TMP/s5"; mk_repo "$R"
printf 'A v1\n' > "$R/orth.sh"; printf 'B v1\n' > "$R/dup.sh"; printf 'C v1\n' > "$R/clean.sh"
git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'B v2\n' > "$R/dup.sh"; printf 'C v2\n' > "$R/clean.sh"   # incoming changes dup.sh + clean.sh, NOT orth.sh
git -C "$R" commit -q -am c1
git -C "$R" checkout -q main
printf 'A v1\n+ local orthogonal edit\n' > "$R/orth.sh"   # uncommitted, untouched by FF
printf 'B v2\n' > "$R/dup.sh"                              # uncommitted, identical to incoming
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                    && ok "returns 0"                                  || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ "${ORTHOGONAL_COUNT:-x}" -eq 1 ] && ok "ORTHOGONAL_COUNT=1 (orth.sh preserved)"     || bad "expected ORTHOGONAL_COUNT=1, got '${ORTHOGONAL_COUNT:-unset}'"
[ "${TRACKED_COUNT:-x}" -eq 1 ]    && ok "TRACKED_COUNT=1 (dup.sh restored)"           || bad "expected TRACKED_COUNT=1, got '${TRACKED_COUNT:-unset}'"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS" || bad "FF blocked"
grep -q "orthogonal edit" "$R/orth.sh" && ok "orthogonal edit survives FF"            || bad "orthogonal edit lost"
[ "$(cat "$R/dup.sh")" = "B v2" ]      && ok "dup.sh at B v2"                          || bad "dup.sh wrong"
[ "$(cat "$R/clean.sh")" = "C v2" ]    && ok "clean.sh at C v2"                        || bad "clean.sh wrong"

# ── Escalation ladder scenarios (ga-k4uh) ─────────────────────────────────────
# Humans are NOT the first line of defense for town-root infra problems: infra
# (Mayor) is told first via durable mail; the human is only paged if the
# problem stays unresolved past ESCALATE_THRESHOLD_SECONDS, and even then at
# most once per NTFY_THROTTLE_SECONDS. Stub gc/notify as shell functions so
# these scenarios never touch real Dolt/ntfy — bash resolves unqualified
# command names against functions defined in the current shell before falling
# back to $PATH, so these shadow the real binaries for the rest of this script.
GC_MAIL_LOG="$TMP/gc-mail.log"
NOTIFY_LOG="$TMP/notify.log"
reset_stubs() { : > "$GC_MAIL_LOG"; : > "$NOTIFY_LOG"; }
gc() {
  # Args (the -m body) can contain embedded newlines; normalize to ONE log
  # line per invocation so `wc -l` on the log counts calls, not text lines.
  if [ "$1" = "mail" ] && [ "$2" = "send" ]; then
    printf 'mail-sent: %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$GC_MAIL_LOG"
  fi
  return 0
}
notify() { echo "notified: $*" >> "$NOTIFY_LOG"; return 0; }

# ── Scenario 6: tier 1 — first sight mails Mayor, does NOT page human ────────
echo "Scenario 6: escalation ladder tier 1 — first sight mails Mayor, does NOT page human"
rm -f "$ESCALATE_STAMP" "$NTFY_STAMP"
reset_stubs
maybe_ntfy "test divergence msg"
[ "$(wc -l < "$GC_MAIL_LOG" | tr -d ' ')" = "1" ] && ok "tier 1: Mayor mailed exactly once" || bad "tier 1: expected 1 Mayor mail, got $(wc -l < "$GC_MAIL_LOG")"
[ ! -s "$NOTIFY_LOG" ]   && ok "tier 1: human NOT paged"          || bad "tier 1: human was paged on first sight (should defer)"
[ -f "$ESCALATE_STAMP" ] && ok "tier 1: escalation stamp written" || bad "tier 1: no escalation stamp written"

# ── Scenario 7: tier 2 — still within grace window, no repeat mail/page ──────
echo "Scenario 7: escalation ladder tier 2 — within grace window, no repeat mail/page"
reset_stubs
maybe_ntfy "still diverged, second tick"
[ ! -s "$GC_MAIL_LOG" ] && ok "tier 2: no repeat Mayor mail within grace window" || bad "tier 2: Mayor mailed again within grace window"
[ ! -s "$NOTIFY_LOG" ]  && ok "tier 2: human still not paged"                    || bad "tier 2: human paged too early"

# ── Scenario 8: tier 3 — unresolved past threshold pages the human ───────────
echo "Scenario 8: escalation ladder tier 3 — unresolved past threshold pages human"
reset_stubs
echo "$(( $(date +%s) - ESCALATE_THRESHOLD_SECONDS - 5 ))" > "$ESCALATE_STAMP"
rm -f "$NTFY_STAMP"
maybe_ntfy "still diverged, past threshold"
[ ! -s "$GC_MAIL_LOG" ]  && ok "tier 3: no re-mail to Mayor (already escalated)" || bad "tier 3: unexpectedly re-mailed Mayor"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" = "1" ] && ok "tier 3: human paged exactly once" || bad "tier 3: expected 1 human page, got $(wc -l < "$NOTIFY_LOG")"
[ -f "$NTFY_STAMP" ]     && ok "tier 3: NTFY_STAMP written" || bad "tier 3: NTFY_STAMP not written"

# ── Scenario 9: daily human throttle — second tier-3 call same day no repeat ─
echo "Scenario 9: daily human throttle — second tier-3-eligible call same day does not re-page"
reset_stubs
maybe_ntfy "still diverged, third tick same day"
[ ! -s "$NOTIFY_LOG" ] && ok "daily throttle: human NOT paged again same day" || bad "daily throttle: human paged twice within throttle window"

# ── Scenario 10: clear_escalation resets the ladder for a fresh episode ──────
echo "Scenario 10: clear_escalation resets ladder — fresh divergence restarts at tier 1"
clear_escalation
[ ! -f "$ESCALATE_STAMP" ] && ok "clear_escalation removed the stamp" || bad "escalation stamp survived clear_escalation"
reset_stubs
maybe_ntfy "new divergence episode after resolve"
[ "$(wc -l < "$GC_MAIL_LOG" | tr -d ' ')" = "1" ] && ok "tier 1 restarts: Mayor mailed again for the NEW episode" || bad "tier 1 restarts: Mayor not mailed for new episode"
[ ! -s "$NOTIFY_LOG" ] && ok "tier 1 restarts: human not paged immediately on the fresh episode" || bad "tier 1 restarts: human paged immediately on fresh episode"

# ── Scenario 11: reconcile_once wiring — already-in-sync clears escalation ───
# Integration check that reconcile_once's healthy exit point actually CALLS
# clear_escalation (scenarios 6-10 test maybe_ntfy/clear_escalation directly;
# this pins the call site so a future edit can't silently drop the wiring).
echo "Scenario 11: reconcile_once wiring — already-in-sync clears a stale escalation stamp"
R="$TMP/s11"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" remote add origin "$R"
echo "999999999" > "$ESCALATE_STAMP"   # simulate a stale outstanding escalation
_saved_ROOT="$ROOT"; _saved_REMOTE="$REMOTE"; _saved_BRANCH="$BRANCH"
ROOT="$R"; REMOTE="origin"; BRANCH="main"
reconcile_once >/dev/null 2>&1
rc_fetch=$?
ROOT="$_saved_ROOT"; REMOTE="$_saved_REMOTE"; BRANCH="$_saved_BRANCH"
[ "$rc_fetch" -eq 0 ]     && ok "reconcile_once completed without error"          || bad "reconcile_once returned $rc_fetch"
[ ! -f "$ESCALATE_STAMP" ] && ok "reconcile_once cleared escalation on already-in-sync" || bad "reconcile_once did NOT clear escalation on already-in-sync"

echo ""
echo "town-root-reconciler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
