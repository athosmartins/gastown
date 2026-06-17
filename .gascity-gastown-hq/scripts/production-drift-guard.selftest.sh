#!/usr/bin/env bash
# production-drift-guard.selftest.sh — Regression harness for production-drift-guard.sh (ga-7rvi5).
#
# Sources the guard as a library (PRODUCTION_DRIFT_GUARD_LIB=1 skips the daemon loop)
# and drives the pure dg_* classifiers + the scanners against THROWAWAY real git repos
# and fake LaunchAgent plists — no network, no live root, no gc, no Dolt.
#
# What it pins (the acceptance criteria of ga-7rvi5):
#   • crew-clone + worktree paths are detected by pattern (Scenarios 2,3).
#   • off-main (branch / detached / file-differs / committed-not-pushed / untracked)
#     is detected against the cached origin/main ref (Scenarios 4,5,6,9,10).
#   • a clean on-main job whose file == origin/main produces NO alert — the
#     zero-false-positive guarantee (Scenarios 1,7,8 + the silent-clean scan 14).
#   • findings are actionable: job + path + kind + owner (Scenarios 11,12,13).
#   • launchd plist parsing + end-to-end launchd scan (Scenarios 10,13).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GUARD="$SCRIPT_DIR/production-drift-guard.sh"

# Physical path (pwd -P) so `git rev-parse --show-toplevel` matches our paths on
# macOS, where /tmp and $TMPDIR are symlinks into /private.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pdg-selftest.XXXXXX")" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

# Source as a library, retargeting all env at the throwaway tree.
export PRODUCTION_DRIFT_GUARD_LIB=1
export DRIFT_GT_ROOT="$TMP" CITY="$TMP" LOG_DIR="$TMP" LOG="$TMP/guard.log" STATE_DIR="$TMP/state"
export DRIFT_REMOTE="origin" DRIFT_MAIN_BRANCH="main"
mkdir -p "$STATE_DIR"
# shellcheck disable=SC1090
source "$GUARD"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  BAD: $*"; }

# mk_repo <dir> — fresh git repo forced onto `main`, isolated from the parent repo.
mk_repo() {
  local d="$1"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email "selftest@local"
  git -C "$d" config user.name  "selftest"
  git -C "$d" config commit.gpgsign false
}
# set_origin_main <repo> <sha> — model the cached origin/main ref.
set_origin_main() { git -C "$1" update-ref refs/remotes/origin/main "$2"; }

kind_of()   { printf '%s' "${1%%|*}"; }
detail_of() { printf '%s' "${1#*|}"; }

# ── Scenario 1: clean on-main file == origin/main → NO drift (zero false-positive) ──
echo "Scenario 1: on-main file matching origin/main classifies clean"
R="$TMP/gt"; mk_repo "$R"; mkdir -p "$R/.gascity-gastown-hq/scripts"
printf 'prod v1\n' > "$R/.gascity-gastown-hq/scripts/daemon.sh"
git -C "$R" add -A; git -C "$R" commit -q -m c0
set_origin_main "$R" "$(git -C "$R" rev-parse HEAD)"
res=$(dg_classify_path "$R/.gascity-gastown-hq/scripts/daemon.sh")
[ "$(kind_of "$res")" = "clean" ] && ok "clean (detail: $(detail_of "$res"))" || bad "expected clean, got '$res'"

# ── Scenario 2: crew clone path → crew-clone ──
echo "Scenario 2: path under a crew clone"
res=$(dg_classify_path "$TMP/whatsapp_automation/crew/claude-1/scripts/x.sh")
[ "$(kind_of "$res")" = "crew-clone" ] && ok "crew-clone" || bad "expected crew-clone, got '$res'"

# ── Scenario 3: worktree path → worktree ──
echo "Scenario 3: path under a build worktree"
res=$(dg_classify_path "$TMP/.gc-worktrees/ga-xyz/scripts/x.sh")
[ "$(kind_of "$res")" = "worktree" ] && ok "worktree" || bad "expected worktree, got '$res'"

# ── Scenario 4: repo on a feature branch → off-main-branch ──
echo "Scenario 4: enclosing repo on a non-main branch"
R="$TMP/offbr"; mk_repo "$R"; printf 'v1\n' > "$R/run.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b feature/x
res=$(dg_classify_path "$R/run.sh")
[ "$(kind_of "$res")" = "off-main-branch" ] && ok "off-main-branch ($(detail_of "$res"))" || bad "expected off-main-branch, got '$res'"

# ── Scenario 5: on main but the running file differs from origin/main → off-main-file ──
echo "Scenario 5: on main, file edited vs origin/main (merged fix not deployed / local edit)"
R="$TMP/edited"; mk_repo "$R"; printf 'v1\n' > "$R/run.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
set_origin_main "$R" "$(git -C "$R" rev-parse HEAD)"
printf 'v1 + uncommitted live edit\n' > "$R/run.sh"
res=$(dg_classify_path "$R/run.sh")
[ "$(kind_of "$res")" = "off-main-file" ] && ok "off-main-file ($(detail_of "$res"))" || bad "expected off-main-file, got '$res'"

# ── Scenario 6: on main, file committed locally but origin/main is behind → off-main-file ──
echo "Scenario 6: on main, committed locally but NOT in origin/main (unpushed)"
R="$TMP/unpushed"; mk_repo "$R"; printf 'v1\n' > "$R/run.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
set_origin_main "$R" "$(git -C "$R" rev-parse HEAD)"   # origin/main pinned at c0
printf 'v2\n' > "$R/run.sh"; git -C "$R" commit -q -am c1   # local advances; working tree == HEAD
res=$(dg_classify_path "$R/run.sh")
[ "$(kind_of "$res")" = "off-main-file" ] && ok "off-main-file ($(detail_of "$res"))" || bad "expected off-main-file, got '$res'"

# ── Scenario 7: gitignored artifact on main → clean (no false positive) ──
echo "Scenario 7: gitignored local artifact is not production drift"
R="$TMP/ignored"; mk_repo "$R"; printf 'build/\n' > "$R/.gitignore"; mkdir -p "$R/build"
git -C "$R" add -A; git -C "$R" commit -q -m c0
set_origin_main "$R" "$(git -C "$R" rev-parse HEAD)"
printf 'generated\n' > "$R/build/out.sh"
res=$(dg_classify_path "$R/build/out.sh")
[ "$(kind_of "$res")" = "clean" ] && ok "clean ($(detail_of "$res"))" || bad "expected clean, got '$res'"

# ── Scenario 8: out-of-scope path → clean (we never alert on jobs we don't own) ──
echo "Scenario 8: path outside GT_ROOT is ignored"
res=$(dg_classify_path "/usr/local/bin/some-system-daemon")
[ "$(kind_of "$res")" = "clean" ] && ok "clean ($(detail_of "$res"))" || bad "expected clean, got '$res'"

# ── Scenario 9: detached HEAD → off-main-branch ──
echo "Scenario 9: detached HEAD repo"
R="$TMP/detached"; mk_repo "$R"; printf 'v1\n' > "$R/run.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q --detach HEAD
res=$(dg_classify_path "$R/run.sh")
[ "$(kind_of "$res")" = "off-main-branch" ] && ok "off-main-branch ($(detail_of "$res"))" || bad "expected off-main-branch, got '$res'"

# ── Scenario 10: dg_paths_from_plist extracts script args + WorkingDirectory ──
echo "Scenario 10: launchd plist path extraction"
PL="$TMP/com.test.job.plist"
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.job</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$TMP/gt/.gascity-gastown-hq/scripts/daemon.sh</string>
  </array>
  <key>WorkingDirectory</key><string>$TMP/gt/.gascity-gastown-hq</string>
</dict></plist>
EOF
paths=$(dg_paths_from_plist "$PL")
echo "$paths" | grep -q "scripts/daemon.sh" && ok "extracts script arg" || bad "missing script arg in '$paths'"
echo "$paths" | grep -q "/.gascity-gastown-hq$" && ok "extracts WorkingDirectory" || bad "missing WorkingDirectory in '$paths'"
[ "$(dg_label_from_plist "$PL")" = "com.test.job" ] && ok "extracts Label" || bad "wrong Label"

# ── Scenario 11: dg_owner_for_path is actionable ──
echo "Scenario 11: owner attribution"
[ "$(dg_owner_for_path "$TMP/x/crew/claude-3/y.sh" crew-clone)" = "crew:claude-3" ] && ok "crew owner" || bad "wrong crew owner"
[ "$(dg_owner_for_path "$TMP/.gc-worktrees/ga-7rvi5-x/y.sh" worktree)" = "worktree:ga-7rvi5-x" ] && ok "worktree owner" || bad "wrong worktree owner"
own=$(dg_owner_for_path "$TMP/offbr/run.sh" off-main-branch)
echo "$own" | grep -q "branch=feature/x" && ok "off-main owner names branch ($own)" || bad "off-main owner missing branch: '$own'"

# ── Scenario 12: end-to-end scan_launchd — one clean job, one drifted job ──
echo "Scenario 12: scan_launchd emits exactly the drifted job"
LA="$TMP/LaunchAgents"; mkdir -p "$LA"
# clean job → on-main file matching origin/main (reuse $TMP/gt from Scenario 1)
cat > "$LA/com.test.clean.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.clean</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$TMP/gt/.gascity-gastown-hq/scripts/daemon.sh</string></array>
</dict></plist>
EOF
# drifted job → points into a crew clone
cat > "$LA/com.test.drift.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.test.drift</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$TMP/whatsapp_automation/crew/claude-1/run.sh</string></array>
</dict></plist>
EOF
LAUNCH_AGENTS_DIR="$LA" DRIFT_FOUND=0
findings=$(LAUNCH_AGENTS_DIR="$LA" scan_launchd)
n=$(printf '%s\n' "$findings" | grep -c . )
[ "$n" -eq 1 ] && ok "exactly 1 drift finding (clean job not flagged)" || bad "expected 1 finding, got $n: '$findings'"
echo "$findings" | grep -q "com.test.drift" && ok "the drifted job is named" || bad "drifted job not named"
echo "$findings" | grep -q "crew-clone" && ok "kind=crew-clone reported" || bad "kind not reported"
echo "$findings" | grep -q "crew:claude-1" && ok "owner reported" || bad "owner not reported"
echo "$findings" | grep -q "com.test.clean" && bad "clean job wrongly flagged" || ok "clean job silent (no false positive)"

# ── Scenario 13: run_scan silent + state file on an all-clean host ──
echo "Scenario 13: all-clean scan is silent and writes last_clean state"
LA2="$TMP/LaunchAgentsClean"; mkdir -p "$LA2"
cp "$LA/com.test.clean.plist" "$LA2/"
# Drive run_scan directly in-process (lib already sourced) with only the clean dir.
LAUNCH_AGENTS_DIR="$LA2" SCAN_CRON=0 SCAN_PROCS=0 run_scan
rc=$?
[ "$rc" -eq 0 ] && ok "run_scan returns 0 on clean host" || bad "run_scan rc=$rc on clean host"
[ "$DRIFT_FOUND" -eq 0 ] && ok "DRIFT_FOUND=0 (silent)" || bad "DRIFT_FOUND=$DRIFT_FOUND on clean host"
grep -q "^last_clean " "$STATE_DIR/production-drift-guard.last" 2>/dev/null && ok "last_clean state written" || bad "last_clean state missing"

# ── Scenario 14: run_scan on a drifted host sets DRIFT_FOUND + writes last_drift ──
echo "Scenario 14: drifted scan records findings + state"
LAUNCH_AGENTS_DIR="$LA" SCAN_CRON=0 SCAN_PROCS=0 run_scan
[ "$DRIFT_FOUND" -ge 1 ] && ok "DRIFT_FOUND>=1 ($DRIFT_FOUND)" || bad "DRIFT_FOUND=$DRIFT_FOUND, expected >=1"
grep -q "^last_drift " "$STATE_DIR/production-drift-guard.last" 2>/dev/null && ok "last_drift state written" || bad "last_drift state missing"

# ── Scenario 15: allowlist sanctions a known exception → silent ──
echo "Scenario 15: allowlisted drift is suppressed (acceptance #5 escape hatch)"
ALLOW="$TMP/allow.txt"
printf '# sanctioned on-disk-only stopgap\ncom.test.drift\n' > "$ALLOW"
got=$(DRIFT_ALLOWLIST_FILE="$ALLOW" LAUNCH_AGENTS_DIR="$LA" scan_launchd)
[ -z "$got" ] && ok "allowlisted launchd job produces no finding" || bad "allowlist did not suppress: '$got'"
# and a non-matching allowlist still lets it through
printf 'com.test.something-else\n' > "$ALLOW"
got=$(DRIFT_ALLOWLIST_FILE="$ALLOW" LAUNCH_AGENTS_DIR="$LA" scan_launchd)
printf '%s\n' "$got" | grep -q "com.test.drift" && ok "non-matching allowlist does not suppress real drift" || bad "drift wrongly suppressed by non-matching allowlist"

echo ""
echo "──────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
