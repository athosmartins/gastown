#!/usr/bin/env bash
# Selftest for skill-audit-emit.sh — proves ERROR paths notify (ga-4zpf), not just log.
# Distinct from skill-audit.selftest.sh, which tests the wrapped skill-audit.sh auditor.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/skill-audit-emit.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario 1: auditor produces no JSON ──"
ISO1="$TMP/iso1"; mkdir -p "$ISO1"
cp "$J" "$ISO1/skill-audit-emit.sh"
cat > "$ISO1/skill-audit.sh" <<'EOF'
#!/usr/bin/env bash
exit 0   # produces NOTHING on stdout — simulates a broken auditor
EOF
chmod +x "$ISO1/skill-audit.sh"
: > "$NOTIFY_LOG"
SKILL_AUDIT_NOTIFY="$TMP/notify" SKILL_AUDIT_CITY="$ISO1/city" bash "$ISO1/skill-audit-emit.sh" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "1: exits 2 when auditor produces no JSON" || bad "1: expected exit 2, got $rc"
grep -qi 'skill-audit-emit' "$NOTIFY_LOG" 2>/dev/null && ok "1: notify_fail fired when auditor produced no JSON (ga-4zpf)" || bad "1: no-JSON FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Scenario 2: output dir not writable ──"
ISO2="$TMP/iso2"; mkdir -p "$ISO2"
cp "$J" "$ISO2/skill-audit-emit.sh"
cat > "$ISO2/skill-audit.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":true,"drift_count":0,"offpath_count":0,"skills_checked":1}'
EOF
chmod +x "$ISO2/skill-audit.sh"
mkdir -p "$ISO2/city/.gc/state" "$ISO2/city/.gc/logs"
chmod 555 "$ISO2/city/.gc/state"
: > "$NOTIFY_LOG"
SKILL_AUDIT_NOTIFY="$TMP/notify" SKILL_AUDIT_CITY="$ISO2/city" bash "$ISO2/skill-audit-emit.sh" >/dev/null 2>&1
rc=$?
chmod 755 "$ISO2/city/.gc/state"
[ "$rc" -eq 2 ] && ok "2: exits 2 when state dir is not writable" || bad "2: expected exit 2, got $rc"
grep -qi 'skill-audit-emit' "$NOTIFY_LOG" 2>/dev/null && ok "2: notify_fail fired when output write failed (ga-4zpf)" || bad "2: write-failure FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "skill-audit-emit selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
