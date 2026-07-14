#!/usr/bin/env bash
# Selftest for cloudflared-dns-reconcile.sh — proves ERROR paths notify (ga-4zpf), not just log.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/cloudflared-dns-reconcile.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$TMP/notify"

echo "── Scenario 1: cloudflared binary missing ──"
: > "$NOTIFY_LOG"
CLOUDFLARED="$TMP/nonexistent-cloudflared" \
  CLOUDFLARED_CONFIG="$TMP/nonexistent-config.yml" \
  CLOUDFLARE_CERT="$TMP/nonexistent-cert.pem" \
  LOG_FILE="$TMP/run1.log" \
  CLOUDFLARED_NOTIFY="$TMP/notify" \
  bash "$J" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "1: exits nonzero when cloudflared binary is missing" || bad "1: expected nonzero exit, got $rc"
grep -qi 'cloudflared' "$NOTIFY_LOG" 2>/dev/null && ok "1: notify_fail fired for missing cloudflared binary (ga-4zpf)" || bad "1: missing-binary FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "── Scenario 2: config file missing (cloudflared binary present) ──"
: > "$NOTIFY_LOG"
FAKE_CLOUDFLARED="$TMP/fake-cloudflared"
cat > "$FAKE_CLOUDFLARED" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_CLOUDFLARED"
CLOUDFLARED="$FAKE_CLOUDFLARED" \
  CLOUDFLARED_CONFIG="$TMP/nonexistent-config.yml" \
  CLOUDFLARE_CERT="$TMP/nonexistent-cert.pem" \
  LOG_FILE="$TMP/run2.log" \
  CLOUDFLARED_NOTIFY="$TMP/notify" \
  bash "$J" >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && ok "2: exits nonzero when config is missing" || bad "2: expected nonzero exit, got $rc"
grep -qi 'config' "$NOTIFY_LOG" 2>/dev/null && ok "2: notify_fail fired for missing config (ga-4zpf)" || bad "2: missing-config FATAL did NOT notify — silent failure (ga-4zpf regression)"

echo ""
echo "cloudflared-dns-reconcile selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
