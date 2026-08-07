#!/usr/bin/env bash
# stale-persistent-daemon-guard.selftest.sh (ga-fckwc)
#
# Runs the REAL stale-persistent-daemon-guard.sh (not a reimplementation)
# against a disposable git repo + fixture plists, with ps/bd/notify swapped
# for fakes via the script's own PS_BIN/BD_BIN/NOTIFY_BIN env-var seams (no
# PATH shimming needed — real git and real plutil/jq run against fixtures).
# Exit 0 iff every assertion holds.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../stale-persistent-daemon-guard.sh"
FAKE_PS="$SELF_DIR/stale-persistent-daemon-guard.fake-ps"
FAKE_BD="$SELF_DIR/stale-persistent-daemon-guard.fake-bd"
FAKE_NOTIFY="$SELF_DIR/stale-persistent-daemon-guard.fake-notify"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CITY="$WORK/city"
NOTIFY_LOG="$WORK/notify.log"
BD_LOG="$WORK/bd.log"
: > "$NOTIFY_LOG"
: > "$BD_LOG"

echo "── 1. syntax ──"
if bash -n "$SCRIPT"; then ok "stale-persistent-daemon-guard.sh passes bash -n"; else bad "bash -n FAILED"; exit 1; fi

echo "── setup: disposable git repo + fixture plists ──"
NOW=$(date +%s)
OLD=$((NOW - 3600))
mkdir -p "$CITY/scripts" "$CITY/packs/town-deltas/assets"
git -C "$CITY" init -q
git -C "$CITY" config user.email "test@test.local"
git -C "$CITY" config user.name "selftest"

# daemon-a: KeepAlive=true, entrypoint committed just NOW, process running
# for 2h -> commit is NEWER than process start -> STALE. Commit subject
# cites a bead id the fake bd DOES know about.
echo "# stub" > "$CITY/scripts/daemon-a.py"
git -C "$CITY" add scripts/daemon-a.py
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "fix(ga-realbead): daemon-a fix"

# daemon-b: KeepAlive=true, entrypoint committed 1h ago, process running for
# only 5s -> commit is OLDER than process start -> NOT stale.
echo "# stub" > "$CITY/scripts/daemon-b.py"
git -C "$CITY" add scripts/daemon-b.py
GIT_AUTHOR_DATE="@$OLD" GIT_COMMITTER_DATE="@$OLD" \
    git -C "$CITY" commit -q -m "fix(ga-realbead): daemon-b fix"

# daemon-c: NO KeepAlive (StartInterval-only). Deliberately given a git/ps
# fixture that WOULD read as stale if ever compared -- must never be
# compared at all, proving the KeepAlive gate actually skips it.
echo "# stub" > "$CITY/scripts/daemon-c.sh"
git -C "$CITY" add scripts/daemon-c.sh
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "chore: daemon-c stub"

# daemon-d: KeepAlive=true but NOT present in the ps fixture at all ->
# "not currently running" -> must be skipped without crashing.
echo "# stub" > "$CITY/scripts/daemon-d.py"
git -C "$CITY" add scripts/daemon-d.py
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "fix(ga-realbead): daemon-d fix"

# daemon-e: same STALE shape as daemon-a, but its commit subject cites a
# bead id the fake bd does NOT know about -> notify must still fire, but
# NO bd label/comment call may happen (never trust an unverified regex
# match against bd -- bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently).
echo "# stub" > "$CITY/scripts/daemon-e.py"
git -C "$CITY" add scripts/daemon-e.py
GIT_AUTHOR_DATE="@$NOW" GIT_COMMITTER_DATE="@$NOW" \
    git -C "$CITY" commit -q -m "fix(ga-unknownxx): daemon-e fix"

git -C "$CITY" update-ref refs/remotes/origin/main HEAD

write_plist() {
    local path="$1" label="$2" entry="$3" keepalive_block="$4"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$entry</string>
  </array>
  $keepalive_block
</dict>
</plist>
EOF
}

write_plist "$CITY/packs/town-deltas/assets/daemon-a.plist" "com.test.daemon-a" "$CITY/scripts/daemon-a.py" \
    '<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>'
write_plist "$CITY/packs/town-deltas/assets/daemon-b.plist" "com.test.daemon-b" "$CITY/scripts/daemon-b.py" \
    '<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>'
write_plist "$CITY/packs/town-deltas/assets/daemon-c.plist" "com.test.daemon-c" "$CITY/scripts/daemon-c.sh" \
    '<key>StartInterval</key><integer>300</integer>'
write_plist "$CITY/packs/town-deltas/assets/daemon-d.plist" "com.test.daemon-d" "$CITY/scripts/daemon-d.py" \
    '<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>'
write_plist "$CITY/packs/town-deltas/assets/daemon-e.plist" "com.test.daemon-e" "$CITY/scripts/daemon-e.py" \
    '<key>KeepAlive</key><true/><key>RunAtLoad</key><true/>'

# daemon-c and daemon-d are deliberately absent from FAKE_PS_OUTPUT:
# daemon-c must never even be looked up (no KeepAlive); daemon-d simulates
# "loaded but not currently running".
FAKE_PS_OUTPUT="111   02:00:00 /usr/bin/python3 $CITY/scripts/daemon-a.py
222   00:00:05 /usr/bin/python3 $CITY/scripts/daemon-b.py
333   02:00:00 /usr/bin/python3 $CITY/scripts/daemon-e.py"

run_guard() {
    env -i \
        PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin" \
        HOME="$HOME" \
        GC_CITY_PATH="$CITY" \
        STALE_DAEMON_SEEN_FILE="$WORK/seen.json" \
        STALE_DAEMON_ESCALATE_AFTER_S="${TEST_ESCALATE_AFTER_S:-86400}" \
        PS_BIN="$FAKE_PS" \
        BD_BIN="$FAKE_BD" \
        NOTIFY_BIN="$FAKE_NOTIFY" \
        FAKE_PS_OUTPUT="$FAKE_PS_OUTPUT" \
        FAKE_BD_KNOWN_IDS="ga-realbead" \
        NOTIFY_LOG="$NOTIFY_LOG" \
        BD_LOG="$BD_LOG" \
        bash "$SCRIPT"
}

echo "── 2. functional: first run classifies all five daemons correctly ──"
OUT1=$(run_guard)

if printf '%s' "$OUT1" | grep -q "com.test.daemon-a"; then ok "daemon-a (stale, KeepAlive) reported"; else bad "daemon-a NOT reported (should be stale)"; fi
if printf '%s' "$OUT1" | grep -q "com.test.daemon-b"; then bad "daemon-b (fresh) incorrectly reported"; else ok "daemon-b (fresh, commit older than process) correctly silent"; fi
if printf '%s' "$OUT1" | grep -q "com.test.daemon-c"; then bad "daemon-c (no KeepAlive) incorrectly reported -- fresh-exec class must never alarm"; else ok "daemon-c (StartInterval-only, no KeepAlive) correctly skipped"; fi
if printf '%s' "$OUT1" | grep -q "com.test.daemon-d"; then bad "daemon-d (not running) incorrectly reported"; else ok "daemon-d (KeepAlive but not currently running) correctly skipped, no crash"; fi
if printf '%s' "$OUT1" | grep -q "com.test.daemon-e"; then ok "daemon-e (stale, unresolvable bead) reported"; else bad "daemon-e NOT reported (should be stale)"; fi

echo "── 3. functional: notify fires for both stale daemons, exactly once each ──"
NOTIFY_COUNT=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT" = "2" ]; then ok "exactly 2 notify calls (daemon-a + daemon-e)"; else bad "expected 2 notify calls, got $NOTIFY_COUNT"; fi

echo "── 4. functional: bd comment/label only for the RESOLVABLE bead id (daemon-a), never for the unverified one (daemon-e) ──"
if grep -q "^LABEL ga-realbead daemon-stale:detected$" "$BD_LOG"; then ok "label added to resolvable bead ga-realbead"; else bad "label missing for ga-realbead"; fi
if grep -q "^COMMENT ga-realbead$" "$BD_LOG"; then ok "comment added to resolvable bead ga-realbead"; else bad "comment missing for ga-realbead"; fi
if grep -q "ga-unknownxx" "$BD_LOG"; then bad "bd was mutated for ga-unknownxx -- an UNVERIFIED regex match must never be trusted (bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently)"; else ok "no bd mutation attempted for the unresolvable id ga-unknownxx"; fi

echo "── 5. functional: dedup -- immediate re-run within the escalate window does NOT re-notify ──"
run_guard >/dev/null
NOTIFY_COUNT2=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT2" = "$NOTIFY_COUNT" ]; then ok "second run within escalate window added zero new notifies ($NOTIFY_COUNT2 total)"; else bad "second run re-notified (got $NOTIFY_COUNT2, expected $NOTIFY_COUNT) -- dedup ledger not honored"; fi

echo "── 6. functional: a run past the escalate window DOES re-notify (dedup is a re-fire cadence, not a permanent silence) ──"
TEST_ESCALATE_AFTER_S=0 run_guard >/dev/null
NOTIFY_COUNT3=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
if [ "$NOTIFY_COUNT3" -gt "$NOTIFY_COUNT2" ]; then ok "re-notified after escalate window elapsed ($NOTIFY_COUNT2 -> $NOTIFY_COUNT3)"; else bad "did NOT re-notify after escalate window elapsed (stuck at $NOTIFY_COUNT3) -- a real still-unfixed daemon would go silent forever"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
