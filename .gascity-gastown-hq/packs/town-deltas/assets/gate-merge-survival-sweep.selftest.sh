#!/usr/bin/env bash
# gate-merge-survival-sweep.selftest.sh — prove the ga-lzj2e survival sweep in
# isolation, with NO live Dolt/gc/launchd and NO network.
#
# Sources the sweep in lib-only mode for the REAL functions (one source of
# truth, no copy-drift), then:
#   • unit-tests the pure classifier survival_classify across EVERY verdict
#     (survived / ff_heal / divergent / unresolved) on a real local git repo;
#   • unit-tests the retention/age helpers (iso_to_epoch, entry_within_retention)
#     including the fail-open-on-unparseable guard;
#   • unit-tests the rig container/self git-dir resolution + git_in dispatch;
#   • DRIFT-GUARDS the live wiring in the sweep, the plist, AND the producer
#     edit in quality-gate-dispatcher.sh (the ledger append).
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SELF_DIR/gate-merge-survival-sweep.sh"
PLIST="$SELF_DIR/gate-merge-survival-sweep.plist"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
# rc0/rc1 take a leading human description, then the command + args to run.
rc0() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d — expected rc0 from: $*"; fi; }
rc1() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d — expected non-zero from: $*"; else ok "$d"; fi; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
SURVIVAL_LIB_ONLY=1 source "$SWEEP" \
  || { echo "FATAL: could not source sweep in lib-only mode"; exit 1; }
for fn in survival_classify rig_gitdir git_in iso_to_epoch entry_within_retention; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by sweep"; exit 1; }
done

# ── Real-git fixture (local only, no network) ───────────────────────────────
T="$(mktemp -d 2>/dev/null || mktemp -d -t galzj2e)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
R="$T/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name  tester
echo a > "$R/a"; git -C "$R" add .; git -C "$R" commit -q -m "C1"
C1=$(git -C "$R" rev-parse HEAD)
echo b > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "C2"
C2=$(git -C "$R" rev-parse HEAD)
echo c > "$R/c"; git -C "$R" add .; git -C "$R" commit -q -m "C3"
C3=$(git -C "$R" rev-parse HEAD)
# Divergent branch off C1: D1 shares no descendancy with C2/C3.
git -C "$R" checkout -q -b other "$C1"
echo d > "$R/d"; git -C "$R" add .; git -C "$R" commit -q -m "D1"
D1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

# ── 1. survival_classify — every verdict, real ancestry ─────────────────────
echo "── 1. survival_classify (pure verdict, real git) ──"
git -C "$R" update-ref refs/remotes/origin/main "$C2"
eq "merge == origin → survived"            "$(survival_classify "$R" 0 "$C2" origin/main)" "survived"
eq "merge ancestor of origin → survived"   "$(survival_classify "$R" 0 "$C1" origin/main)" "survived"
eq "merge ahead of origin → ff_heal"       "$(survival_classify "$R" 0 "$C3" origin/main)" "ff_heal"
git -C "$R" update-ref refs/remotes/origin/main "$D1"
eq "neither ancestor → divergent"          "$(survival_classify "$R" 0 "$C3" origin/main)" "divergent"
eq "bogus merge sha → unresolved"          "$(survival_classify "$R" 0 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" origin/main)" "unresolved"
git -C "$R" update-ref -d refs/remotes/origin/main 2>/dev/null || true
eq "missing origin ref → unresolved"       "$(survival_classify "$R" 0 "$C2" origin/main)" "unresolved"

# Provably-lossless direction check: ff_heal ⟹ origin IS ancestor of merge.
git -C "$R" update-ref refs/remotes/origin/main "$C2"
rc0 "ff_heal precondition: origin ancestor-of merge" git -C "$R" merge-base --is-ancestor "$C2" "$C3"

# ── 2. iso_to_epoch + entry_within_retention ────────────────────────────────
echo "── 2. age / retention helpers ──"
TS="2026-06-11T00:00:00Z"
EXP=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s 2>/dev/null || echo X)
eq "iso_to_epoch parses UTC ts"            "$(iso_to_epoch "$TS")" "$EXP"
eq "iso_to_epoch empty on junk"            "$(iso_to_epoch 'not-a-date')" ""
NOW=$(date -u +%s)
TS_RECENT=$(date -u -r $(( NOW - 86400 ))      +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
TS_OLD=$(date    -u -r $(( NOW - 30*86400 ))   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
rc0 "1-day-old entry within 14d retention"  entry_within_retention "$TS_RECENT" "$NOW" 14
rc1 "30-day-old entry outside 14d retention" entry_within_retention "$TS_OLD" "$NOW" 14
rc0 "unparseable ts FAILS OPEN (kept)"       entry_within_retention "garbage" "$NOW" 14
rc0 "empty ts FAILS OPEN (kept)"             entry_within_retention "" "$NOW" 14

# ── 3. rig_gitdir + git_in dispatch ─────────────────────────────────────────
echo "── 3. rig container/self resolution ──"
mkdir -p "$T/crig/.repo.git" "$T/srig"
eq "container rig → .repo.git + flag 1"    "$(rig_gitdir "$T/crig")" "$(printf '%s\t1' "$T/crig/.repo.git")"
eq "self rig → path + flag 0"              "$(rig_gitdir "$T/srig")" "$(printf '%s\t0' "$T/srig")"
# git_in self-repo path (container=0) and container path (container=1 against .git).
eq "git_in self (container=0)"             "$(git_in "$R" 0 rev-parse --abbrev-ref HEAD)" "main"
eq "git_in container (container=1)"        "$(git_in "$R/.git" 1 rev-parse HEAD)" "$C3"

# ── 4. drift-guard: sweep wiring ────────────────────────────────────────────
echo "── 4. drift-guard: sweep wiring ──"
grep -q 'SURVIVAL_LIB_ONLY' "$SWEEP"            && ok "sweep sourceable in lib-only mode"  || bad "missing lib-only hook"
grep -q 'survival_classify()' "$SWEEP"          && ok "defines survival_classify"          || bad "missing survival_classify def"
grep -q 'escalate_divergent()' "$SWEEP"         && ok "defines escalate_divergent"         || bad "missing escalate_divergent def"
grep -q 'escalate_unresolved()' "$SWEEP"        && ok "defines escalate_unresolved"        || bad "missing escalate_unresolved def"
grep -q 'push origin "${SHA}:refs/heads/$RDEFAULT"' "$SWEEP" && ok "ff_heal does FF-only re-push" || bad "ff_heal re-push missing"
grep -q 'merge-base --is-ancestor "\$mref" "\$sha"' "$SWEEP" && ok "ff_heal direction is origin-ancestor-of-merge (lossless)" || bad "ff_heal ancestry direction wrong/missing"
grep -q 'bd -C "\$beadcity" reopen "\$bead"' "$SWEEP" && ok "divergent reopens source bead (re-enqueue)" || bad "reopen missing"
grep -q 'gate:merge-orphan' "$SWEEP"            && ok "labels orphan bead gate:merge-orphan" || bad "orphan label missing"
grep -q 'mail send mayor' "$SWEEP"              && ok "escalates divergent to Mayor"         || bad "Mayor escalation missing"
grep -q 'entry_within_retention' "$SWEEP"       && ok "retention prune wired"                || bad "retention prune missing"
grep -q 'should_alert' "$SWEEP"                 && ok "per-sha escalation rate-limit wired"  || bad "rate-limit missing"
grep -q 'SURVIVAL_DRY_RUN' "$SWEEP"             && ok "dry-run supported"                    || bad "dry-run support missing"
# -u -j -f UTC guard (ga-35zp1: never omit -u with -j -f).
grep -q 'date -u -j -f "%Y-%m-%dT%H:%M:%SZ"' "$SWEEP" && ok "iso_to_epoch uses -u (UTC age, ga-35zp1)" || bad "missing -u UTC guard"

# ── 5. drift-guard: producer edit in quality-gate-dispatcher.sh ─────────────
echo "── 5. drift-guard: dispatcher ledger producer ──"
grep -q 'merge-survival-ledger.jsonl' "$DISPATCHER"   && ok "dispatcher writes the survival ledger" || bad "dispatcher ledger append missing"
grep -q 'ga-lzj2e' "$DISPATCHER"                       && ok "dispatcher edit tagged ga-lzj2e"       || bad "dispatcher edit untagged"
# Producer guards: container-rig-only + real-sha + dry-run-skip.
grep -q 'IS_CONTAINER_RIG:-0' "$DISPATCHER"            && ok "ledger guarded to container rigs"      || bad "container-rig guard missing"
grep -Eq 'grep -Eq .\^\[0-9a-f\]\{7,40\}' "$DISPATCHER" && ok "ledger guarded to a real merge SHA"   || bad "sha guard missing"

# ── 6. drift-guard: plist ───────────────────────────────────────────────────
echo "── 6. drift-guard: plist ──"
grep -q 'com.gascity.gate-merge-survival-sweep' "$PLIST" && ok "plist Label correct"     || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"              && ok "plist uses StartInterval" || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"           && ok "plist RunAtLoad=true"     || bad "plist missing RunAtLoad"
grep -q 'gate-merge-survival-sweep.sh' "$PLIST"          && ok "plist points at the sweep script" || bad "plist ProgramArguments wrong"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
