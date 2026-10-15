#!/usr/bin/env bash
# skill-integrity-install.selftest.sh — Regression harness for
# scan_and_install_new_plists() (ga-7ryjey, discovered-from ga-stu930).
#
# Sources skill-integrity-install.sh as a library (SKILL_INTEGRITY_LIB_ONLY=1
# skips baseline-adopt, the two hardcoded installs, and the verify step) and
# drives scan_and_install_new_plists() against THROWAWAY fixture plists in a
# temp dir. Overrides _is_loaded (broken out in the source file exactly so
# this can be shadowed) instead of calling real launchctl, and runs under
# SKILL_INTEGRITY_NO_LAUNCHD=true so install_plist() itself never touches
# ~/Library/LaunchAgents or real launchd either — no live root, no network,
# no launchd. Under NO_LAUNCHD=true install_plist() emits
# "Skipping launchd install for <label>" instead of actually installing,
# which is what these scenarios assert on to confirm a call happened.
#
# Scenarios:
#   1. new plist, com.gascity.*, not loaded         -> installed
#   2. already-loaded plist                          -> left untouched
#   3. non-gascity label (other vendor's plist)       -> skipped, not touched
#   4. malformed plist (no Label at all)              -> skipped, no crash
#   5. two new plists in the same sweep               -> BOTH installed, in file order
#   6. already-installed hardcoded label (skill-audit) -> still untouched if loaded
#      (regression guard: this loop must never re-touch the two hand-wired
#      installs just because they're also *.plist files in the same dir)
#   7. post-install re-check queries launchctl again -> VERIFIED (ga-7ryjey b)
#   8. not loaded but launchctl-DISABLED (deliberate pause)  -> SKIP line, never installed (ga-jh3ske)
#   9. not loaded and print-disabled unreadable ("?")       -> WARNING+SKIP, never installed (third state)
#  10. hand-wired install_plist() on a disabled label        -> SKIP before any launchd action
#      (8-10 override _disabled_state, broken out in the source for exactly this)
#
# Exit 0 iff every scenario behaves as expected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/skill-integrity-install.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  BAD: %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export SKILL_INTEGRITY_LIB_ONLY=1
export SKILL_INTEGRITY_NO_LAUNCHD=true
# shellcheck disable=SC1090
source "$SCRIPT"

# mk_plist <path> <label> — minimal but well-formed plist fixture.
mk_plist() {
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$2</string>
    <key>StartInterval</key>
    <integer>1200</integer>
</dict>
</plist>
PLIST
}

# ── Scenario 1: new plist, never loaded -> gets installed ──────────────────
echo "Scenario 1: brand-new com.gascity.* plist, not loaded -> installed"
DIR1="$TMP/s1"; mkdir -p "$DIR1"
mk_plist "$DIR1/newthing.plist" "com.gascity.newthing"
_is_loaded() { [ "$1" = "__never__" ]; }  # everything reports not-loaded (before AND after install)
OUT="$(scan_and_install_new_plists "$DIR1" 2>&1)"
if printf '%s' "$OUT" | grep "NEW PLIST detected.*com.gascity.newthing" >/dev/null \
   && printf '%s' "$OUT" | grep "Skipping launchd install for com.gascity.newthing" >/dev/null \
   && printf '%s' "$OUT" | grep "WARNING: installed com.gascity.newthing but launchctl still does not show it loaded" >/dev/null; then
  ok "new plist detected, install_plist called, post-install re-check correctly WARNs (still not loaded under this mock)"
else
  bad "expected a NEW PLIST detection + install_plist call + post-install WARNING for com.gascity.newthing" "$OUT"
fi

# ── Scenario 2: already-loaded plist -> left completely untouched ──────────
echo "Scenario 2: plist whose label IS loaded -> never touched"
DIR2="$TMP/s2"; mkdir -p "$DIR2"
mk_plist "$DIR2/existing.plist" "com.gascity.existing"
_is_loaded() { [ "$1" = "com.gascity.existing" ]; }  # this ONE is loaded
OUT="$(scan_and_install_new_plists "$DIR2" 2>&1)"
if [ -z "$OUT" ]; then
  ok "already-loaded plist produced zero output — install_plist never called"
else
  bad "already-loaded plist must never be touched by this loop" "$OUT"
fi

# ── Scenario 3: non-gascity label -> skipped regardless of load state ──────
echo "Scenario 3: plist with a non-com.gascity. label -> skipped"
DIR3="$TMP/s3"; mkdir -p "$DIR3"
mk_plist "$DIR3/other.plist" "com.example.other"
_is_loaded() { return 1; }  # nothing is loaded — if scope filter is broken, this would install
OUT="$(scan_and_install_new_plists "$DIR3" 2>&1)"
if [ -z "$OUT" ]; then
  ok "non-com.gascity. label correctly out of scope, never installed"
else
  bad "this loop must only ever touch com.gascity.* labels" "$OUT"
fi

# ── Scenario 4: malformed plist (no Label) -> skipped, no crash ────────────
echo "Scenario 4: plist with no <key>Label</key> at all -> skipped, doesn't crash"
DIR4="$TMP/s4"; mkdir -p "$DIR4"
cat > "$DIR4/broken.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>ProgramArguments</key>
    <array><string>/bin/true</string></array>
</dict>
</plist>
PLIST
_is_loaded() { return 1; }
if OUT="$(scan_and_install_new_plists "$DIR4" 2>&1)"; then
  RC=0
else
  RC=$?
fi
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "plist with no Label skipped cleanly, function did not error out"
else
  bad "a malformed plist must be skipped, not crash the whole sweep (rc=$RC)" "$OUT"
fi

# ── Scenario 5: two new plists in the same sweep -> BOTH installed ─────────
echo "Scenario 5: two new plists in one directory -> both get installed"
DIR5="$TMP/s5"; mkdir -p "$DIR5"
mk_plist "$DIR5/first.plist" "com.gascity.first"
mk_plist "$DIR5/second.plist" "com.gascity.second"
_is_loaded() { return 1; }
OUT="$(scan_and_install_new_plists "$DIR5" 2>&1)"
if printf '%s' "$OUT" | grep "com.gascity.first" >/dev/null \
   && printf '%s' "$OUT" | grep "com.gascity.second" >/dev/null; then
  ok "both new plists installed in the same sweep, neither skipped the other"
else
  bad "a sweep with 2 new plists must install both, not just the first" "$OUT"
fi

# ── Scenario 6: regression guard — hand-wired labels never re-touched ──────
# The two calls install_plist "$PLIST_SRC" "$LABEL" / crew-hang-detector in
# the real script's ── 2. Install launchd section run BEFORE this loop, and
# their plists live in the SAME directory this loop scans. If those labels
# are already loaded (the normal steady state), this loop must not re-fire
# on them just because they're *.plist files it also sees.
echo "Scenario 6: hardcoded skill-audit label already loaded -> loop leaves it alone"
DIR6="$TMP/s6"; mkdir -p "$DIR6"
mk_plist "$DIR6/skill-audit.plist" "com.gascity.skill-audit"
mk_plist "$DIR6/brandnew.plist" "com.gascity.brandnew"
_is_loaded() { [ "$1" = "com.gascity.skill-audit" ]; }
OUT="$(scan_and_install_new_plists "$DIR6" 2>&1)"
if ! printf '%s' "$OUT" | grep "skill-audit" >/dev/null \
   && printf '%s' "$OUT" | grep "com.gascity.brandnew" >/dev/null; then
  ok "already-loaded hardcoded-elsewhere label untouched; genuinely new sibling still installed"
else
  bad "loop must not re-touch com.gascity.skill-audit (already installed by the hardcoded call above it), but must still catch a genuinely new sibling plist" "$OUT"
fi

# ── Scenario 7: post-install re-check reports VERIFIED, not inferred ───────
# ga-7ryjey acceptance criterion b): "launchctl list confirma o job rodando
# depois — verificado, não só 'comando de load retornou 0'". Models the
# happy path: _is_loaded says "not loaded" the FIRST time (triggers
# install), then "loaded" on the SECOND call for the same label (the
# post-install re-check) — a stateful mock, since a static answer can't
# distinguish "checked before" from "checked after".
echo "Scenario 7: post-install re-check confirms load via a FRESH query, prints VERIFIED"
DIR7="$TMP/s7"; mkdir -p "$DIR7"
mk_plist "$DIR7/nowlive.plist" "com.gascity.nowlive"
CALL_COUNT_FILE="$TMP/s7-calls"
: > "$CALL_COUNT_FILE"
_is_loaded() {
  [ "$1" = "com.gascity.nowlive" ] || return 1
  local n; n="$(wc -l < "$CALL_COUNT_FILE" | tr -d ' ')"
  printf '.\n' >> "$CALL_COUNT_FILE"
  [ "$n" -ge 1 ]  # false on 1st call (pre-install check), true on 2nd+ (post-install re-check)
}
OUT="$(scan_and_install_new_plists "$DIR7" 2>&1)"
if printf '%s' "$OUT" | grep "NEW PLIST detected.*com.gascity.nowlive" >/dev/null \
   && printf '%s' "$OUT" | grep "VERIFIED: com.gascity.nowlive now loaded" >/dev/null; then
  ok "post-install re-check queries launchctl again and reports VERIFIED once it's genuinely loaded"
else
  bad "post-install check must re-query and report VERIFIED, not just trust install_plist's own exit code" "$OUT"
fi

echo
# ── Scenario 8: not loaded, but launchctl-disabled -> SKIP, never installed ──
# ga-jh3ske: on 15/10 the two refino dispatchers Athos paused with
# `launchctl disable` were re-armed twice by this loop (`load -w`). A paused
# label is NOT "never installed".
echo "Scenario 8: com.gascity.* plist not loaded but launchctl-disabled -> SKIP, not installed"
DIR8D="$TMP/s8-disabled"; mkdir -p "$DIR8D"
mk_plist "$DIR8D/paused.plist" "com.gascity.paused"
_is_loaded() { return 1; }
_disabled_state() { [ "$1" = "com.gascity.paused" ] && echo yes || echo no; }
OUT="$(scan_and_install_new_plists "$DIR8D" 2>&1)"
if printf '%s' "$OUT" | grep "SKIP com.gascity.paused: launchctl-disabled" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "NEW PLIST detected|Skipping launchd install|Installed plist" >/dev/null; then
  ok "disabled label skipped with an explicit SKIP line; install_plist never reached"
else
  bad "a launchctl-disabled label must be skipped, not reinstalled (ga-jh3ske)" "$OUT"
fi

# ── Scenario 9: disabled-state unreadable ("?") -> WARNING + SKIP (third state) ──
echo "Scenario 9: print-disabled unreadable -> WARNING + SKIP, not installed"
DIR9U="$TMP/s9-unknown"; mkdir -p "$DIR9U"
mk_plist "$DIR9U/unknown.plist" "com.gascity.unknown"
_is_loaded() { return 1; }
_disabled_state() { echo "?"; }
OUT="$(scan_and_install_new_plists "$DIR9U" 2>&1)"
if printf '%s' "$OUT" | grep "WARNING: SKIP com.gascity.unknown" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "NEW PLIST detected|Skipping launchd install|Installed plist" >/dev/null; then
  ok "unreadable disable state is reported loudly and does NOT fall through to install"
else
  bad "'cannot tell' must not collapse into 'not disabled' (install)" "$OUT"
fi

# ── Scenario 10: hand-wired install_plist() on a disabled label -> SKIP ──────
echo "Scenario 10: install_plist() called directly on a disabled label -> SKIP before launchd"
DIR10="$TMP/s10-handwired"; mkdir -p "$DIR10"
mk_plist "$DIR10/hw.plist" "com.gascity.handwired"
_disabled_state() { echo yes; }
OUT="$(install_plist "$DIR10/hw.plist" "com.gascity.handwired" 2>&1)"
if printf '%s' "$OUT" | grep "SKIP com.gascity.handwired: launchctl-disabled" >/dev/null \
   && ! printf '%s' "$OUT" | grep -E "Skipping launchd install|Installed plist" >/dev/null; then
  ok "hand-wired install path honors the pause too"
else
  bad "install_plist() itself must refuse a disabled label (hand-wired calls bypass the scan loop)" "$OUT"
fi
_disabled_state() { echo no; }

printf 'skill-integrity-install selftest: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
