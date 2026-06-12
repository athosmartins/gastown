#!/bin/bash
# Selftest for claude-account-relog.sh (ga-jf689).
#
# Fully hermetic: NO real Keychain, NO real secret store, NO real `notify`, NO
# real quota transcripts. Every backend is injected via env so the script's
# decision logic — apex→swap, no-headroom→pause, cooldown, fingerprint
# identification, fail-closed gating, dry-run, and the credential-redaction
# guard — is exercised without touching live credentials.
#
# The injected Keychain is a plain file (KC). The injected secret store is a
# directory of per-label blob files (SECRETS/<label>). The injected quota check
# is a tiny script that prints whatever JSON we stage (QJSON).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/claude-account-relog.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

NOW=1781233200   # pinned "now"

SBX="$(mktemp -d /tmp/relog-selftest.XXXXXX)"
trap 'rm -rf "$SBX"' EXIT
KC="$SBX/keychain.blob"            # injected active-keychain file
SECRETS="$SBX/secrets"            # injected secret store dir
STATE_DIR="$SBX/state"
QJSON="$SBX/quota.json"           # staged quota-check output
mkdir -p "$SECRETS" "$STATE_DIR"

# A fake but well-formed Claude OAuth blob with a given token marker.
blob_for() { # <token-marker>
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":"sk-ant-ort01-%s","expiresAt":9999999999999,"subscriptionType":"max"}}' "$1" "$1"
}

# Injected quota checker: emits the staged QJSON, exit 2 if limited true.
QCHECK="$SBX/quota-check.sh"
cat > "$QCHECK" <<EOF
#!/bin/bash
cat "$QJSON"
[ "\$(jq -r '.limited' "$QJSON")" = "true" ] && exit 2 || exit 0
EOF
chmod +x "$QCHECK"

stage_quota() { # <limited:true|false> <scope> <reset_in_minutes> <reset_text>
  cat > "$QJSON" <<EOF
{"limited":$1,"scope":"$2","reset_in_minutes":$3,"reset_time_text":"$4",
 "weekly":{"active":false},"window_5h":{"output_tokens":0,"billable_tokens":0}}
EOF
}

# Injected secret command: prints SECRETS/<arg> if present.
SECRET_CMD="$SBX/secret.sh"
cat > "$SECRET_CMD" <<EOF
#!/bin/bash
f="$SECRETS/\$1"
[ -f "\$f" ] && cat "\$f" || exit 1
EOF
chmod +x "$SECRET_CMD"

# Common env for every run. Keychain get = cat KC; set = overwrite KC.
run() { # <args...> ; sets OUT, RC
  OUT=$(env \
    CLAUDE_RELOG_STATE_DIR="$STATE_DIR" \
    CLAUDE_RELOG_QUOTA_CHECK="$QCHECK" \
    CLAUDE_RELOG_SECRET_CMD="$SECRET_CMD" \
    CLAUDE_RELOG_KEYCHAIN_GET="cat '$KC' 2>/dev/null" \
    CLAUDE_RELOG_KEYCHAIN_SET="cat > '$KC'" \
    CLAUDE_RELOG_NOTIFY="true" \
    CLAUDE_RELOG_NOW="$NOW" \
    "$@" 2>&1)
  RC=$?
}

echo "claude-account-relog selftest (pinned now=$NOW)"

# ---------------------------------------------------------------------------
# Setup: keychain holds account 'alpha'; pool = alpha beta gamma.
# Bitwarden has beta + gamma blobs (alpha is the live one, not needed to swap).
# ---------------------------------------------------------------------------
blob_for alpha > "$KC"
blob_for beta  > "$SECRETS/claude-acct-beta"
blob_for gamma > "$SECRETS/claude-acct-gamma"
export CLAUDE_RELOG_POOL="alpha beta gamma"

# Register the active blob as 'alpha' so current_label resolves it.
run bash "$SUT" register alpha
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "registered current account as 'alpha'"; then
  ok "register tags current keychain blob → alpha"
else bad "register alpha" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 1: current resolves the active account by fingerprint
# ---------------------------------------------------------------------------
run bash "$SUT" current
if [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "alpha" ]; then
  ok "current → alpha (fingerprint match)"
else bad "current → alpha" "out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 2: not at apex → auto (dry) does nothing
# ---------------------------------------------------------------------------
stage_quota false none null ""
run bash "$SUT" auto --dry-run
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "not at apex"; then
  ok "not limited → auto no-op"
else bad "not limited → auto no-op" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 3: at apex, headroom available → auto (dry) plans relog to beta
# ---------------------------------------------------------------------------
stage_quota true session 120 "4:50pm"
run bash "$SUT" auto --dry-run
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "would relog to 'beta'"; then
  ok "apex + headroom → dry-run plans relog to beta"
else bad "apex dry-run plans beta" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 4: gated swap refused without enable
# ---------------------------------------------------------------------------
run bash "$SUT" swap beta
if [ "$RC" = 1 ] && printf '%s' "$OUT" | grep -q "refusing live swap"; then
  ok "swap without CLAUDE_RELOG_ENABLED → refused"
else bad "swap gating" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 5: enabled live swap to beta actually rewrites the keychain
# ---------------------------------------------------------------------------
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" swap beta
NEWFP=$(jq -r '.claudeAiOauth.accessToken' "$KC" 2>/dev/null)
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "swapped active Claude account → 'beta'" \
   && [ "$NEWFP" = "sk-ant-oat01-beta" ]; then
  ok "enabled swap beta → keychain rewritten to beta"
else bad "live swap beta" "rc=$RC fp=$NEWFP out=$OUT"; fi

# current now resolves to beta
run bash "$SUT" current
if [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "beta" ]; then
  ok "current → beta after swap"
else bad "current after swap" "out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 6: full auto (enabled) at apex from beta → relogs to a headroom acct
#         and marks beta in cooldown
# ---------------------------------------------------------------------------
stage_quota true session 90 "5:20pm"
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" auto
ACTIVE=$(jq -r '.claudeAiOauth.accessToken' "$KC")
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "relogged to" \
   && [ "$ACTIVE" = "sk-ant-oat01-gamma" ]; then
  ok "auto at apex from beta → relogged to gamma"
else bad "auto relog gamma" "rc=$RC active=$ACTIVE out=$OUT"; fi

# beta should now be in cooldown (limited_until in the future)
BU=$(jq -r '.beta.limited_until // 0' "$STATE_DIR/state.json")
if [ "$BU" -gt "$NOW" ] 2>/dev/null; then
  ok "beta marked in cooldown after apex"
else bad "beta cooldown" "limited_until=$BU now=$NOW"; fi

# ---------------------------------------------------------------------------
# CASE 7: apex again, but ALL other accounts in cooldown → PAUSE (exit 2)
# Put alpha and beta in cooldown; active is gamma → no headroom elsewhere.
# ---------------------------------------------------------------------------
stage_quota true session 60 "6:00pm"
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" auto   # gamma hits apex, alpha/beta...
# After this, gamma cooled down too. alpha cooldown? alpha was never limited.
# So this run should have relogged to alpha (still headroom). Verify, then
# force the true no-headroom case explicitly below.
:

# Explicit no-headroom: mark every non-active account limited.
cat > "$STATE_DIR/state.json" <<EOF
{"alpha":{"limited_until":$((NOW+9999))},"beta":{"limited_until":$((NOW+9999))},
 "gamma":{"limited_until":0}}
EOF
blob_for gamma > "$KC"   # make gamma active
run bash "$SUT" register gamma   # ensure fingerprint maps to gamma
stage_quota true session 60 "6:00pm"
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" auto
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q "NO pool account with headroom"; then
  ok "apex + all others in cooldown → PAUSE (exit 2)"
else bad "no-headroom pause" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 8: select skips cooldown accounts
# ---------------------------------------------------------------------------
cat > "$STATE_DIR/state.json" <<EOF
{"alpha":{"limited_until":0},"beta":{"limited_until":$((NOW+9999))},"gamma":{"limited_until":0}}
EOF
blob_for gamma > "$KC"
run bash "$SUT" register gamma
run bash "$SUT" select   # active gamma; beta cooled → should pick alpha
if [ "$(printf '%s' "$OUT" | tr -d '[:space:]')" = "alpha" ]; then
  ok "select skips active+cooldown → alpha"
else bad "select headroom" "out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 9: swap to a label whose secret is MISSING → exit 3
# ---------------------------------------------------------------------------
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" swap delta
if [ "$RC" = 3 ] && printf '%s' "$OUT" | grep -q "no credential for label 'delta'"; then
  ok "swap missing-secret label → exit 3"
else bad "swap missing secret" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 10: fail-closed — auto without --dry-run and without enable = no-op
# ---------------------------------------------------------------------------
stage_quota true session 60 "6:00pm"
PRE=$(cat "$KC")
run bash "$SUT" auto    # CLAUDE_RELOG_ENABLED unset → disabled
POST=$(cat "$KC")
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "disabled" && [ "$PRE" = "$POST" ]; then
  ok "auto disabled (fail-closed) → no keychain mutation"
else bad "fail-closed auto" "rc=$RC mutated=$([ "$PRE" = "$POST" ] && echo no || echo YES) out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 11: REDACTION GUARD — a swap must NEVER print a token, even on success.
# Scan all output of an enabled swap for the token marker.
# ---------------------------------------------------------------------------
blob_for alpha > "$KC"; run bash "$SUT" register alpha
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" swap beta
if printf '%s' "$OUT" | grep -q 'sk-ant-'; then
  bad "no token in swap output" "LEAKED: $OUT"
else
  ok "swap output contains no credential token (AC4)"
fi

# ---------------------------------------------------------------------------
# CASE 12: status renders without leaking and shows enable state
# ---------------------------------------------------------------------------
stage_quota false none null ""
run bash "$SUT" status
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q "relog enabled: no" \
   && ! printf '%s' "$OUT" | grep -q 'sk-ant-'; then
  ok "status renders, fail-closed, no leak"
else bad "status render" "rc=$RC out=$OUT"; fi

# ---------------------------------------------------------------------------
# CASE 13: REDACTION GUARD fires — if a token ever reaches a logged field, the
# script ABORTS instead of leaking it. We smuggle a token into the quota JSON's
# reset_time_text (which the apex notify message interpolates) and assert the
# guard trips: nonzero exit AND no token in output.
# ---------------------------------------------------------------------------
blob_for alpha > "$KC"; run bash "$SUT" register alpha
cat > "$STATE_DIR/state.json" <<EOF
{"alpha":{"limited_until":0},"beta":{"limited_until":0},"gamma":{"limited_until":0}}
EOF
stage_quota true session 60 "sk-ant-oat01-LEAKMARKER"
run env CLAUDE_RELOG_ENABLED=1 bash "$SUT" auto
if [ "$RC" != 0 ] && ! printf '%s' "$OUT" | grep -q 'sk-ant-oat01-LEAKMARKER'; then
  ok "redaction guard aborts on a token in a logged field (AC4)"
else bad "redaction guard fires" "rc=$RC out=$OUT"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
