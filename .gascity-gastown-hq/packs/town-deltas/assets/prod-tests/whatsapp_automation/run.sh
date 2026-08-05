#!/usr/bin/env bash
# prod-tests/whatsapp_automation/run.sh — rig-level prod test for whatsapp_automation.
#
# Called by story-delivery.sh after deploy. Exits 0 on pass, non-zero on fail.
# Added by ga-857v FIX 2 so WA deliveries reach story:done with delivery:tested
# instead of delivery:untested (the interim warn-only policy from ga-dqp).
#
# STORY_ID (set by story-delivery.sh) selects an OPTIONAL story-specific test;
# the baseline smoke checks below always run and gate pass/fail on their own.
#
# What this proves (the ga-857v FIX 2 acceptance, all four points):
#   1. Kanban de histórias (:8202) is live and returns HTTP 200.
#   2. Its served HTML contains the expected title "Kanban de histórias".
#   3. SSTI is closed: the painel index route returns the prebuilt HTML directly
#      and never funnels it through render_template_string (RCE-class fix).
#   4. The admin console (:8097) shows the Kanban de histórias registration.

set -uo pipefail

PAINEL_PORT="${PAINEL_PORT:-8202}"
ADMIN_PORT="${ADMIN_PORT:-8097}"
WA_ROOT="${WA_ROOT:-/Users/athos/gt/whatsapp_automation}"
PAINEL_SRC="${PAINEL_SRC:-$WA_ROOT/daemons/painel_visibilidade.py}"
STORY_ID="${STORY_ID:-}"

log()  { echo "[prod-test:whatsapp_automation] $*"; }
fail() { echo "[prod-test:whatsapp_automation] FAIL: $*" >&2; exit 1; }

# ── Check 1: Painel :8202 returns HTTP 200 ────────────────────────────────────
log "Check 1: painel http://127.0.0.1:${PAINEL_PORT}/ returns 200 ..."
PAINEL_BODY="/tmp/wa-prodtest-painel.$$.html"
PAINEL_CODE=$(curl -s --max-time 10 -o "$PAINEL_BODY" -w "%{http_code}" \
  "http://127.0.0.1:${PAINEL_PORT}/" 2>/dev/null || echo "000")
if [ "$PAINEL_CODE" != "200" ]; then
  rm -f "$PAINEL_BODY"
  fail "painel :${PAINEL_PORT} returned HTTP ${PAINEL_CODE} (expected 200) — daemon down or not serving?"
fi
log "painel HTTP 200 OK"

# ── Check 2: served HTML contains the expected title ──────────────────────────
log "Check 2: served HTML contains 'Kanban de histórias' ..."
if ! grep -q "Kanban de histórias" "$PAINEL_BODY"; then
  rm -f "$PAINEL_BODY"
  fail "served painel HTML does not contain 'Kanban de histórias' — daemon not restarted after ga-52ib rename, or wrong page served?"
fi
rm -f "$PAINEL_BODY"
log "title present OK"

# ── Check 3: SSTI is closed in the painel index route ─────────────────────────
log "Check 3: SSTI closed (no render_template_string call; returns html directly) ..."
if [ ! -f "$PAINEL_SRC" ]; then
  fail "painel source not found at $PAINEL_SRC — cannot verify SSTI is closed."
fi
# An actual call is 'render_template_string(' with an open paren. The source may
# legitimately MENTION the name in a comment explaining why it is avoided, so we
# match the call form (optional whitespace before the paren) only.
if grep -Eq 'render_template_string[[:space:]]*\(' "$PAINEL_SRC"; then
  fail "painel source calls render_template_string( — SSTI (RCE-class) risk reintroduced. The index route MUST return the prebuilt HTML directly."
fi
# Positive assertion: the index route returns the prebuilt html string directly.
if ! grep -Eq '^[[:space:]]*return[[:space:]]+html\b' "$PAINEL_SRC"; then
  fail "painel source does not 'return html' directly in the index route — verify the SSTI-safe render path is intact."
fi
log "SSTI closed OK"

# ── Check 4: admin :8097 shows the Kanban de histórias registration ────────
# ga-pbbs8: a single transient render glitch (non-empty body, momentarily
# missing the registration list — admin aggregates several upstreams) used
# to hard-fail on one attempt AND assert a cause (registration missing /
# daemon not restarted) that was never measured. Retry absorbs the transient
# case; the fail message states only what was measured and labels the rest
# as an explicit, unverified hypothesis. curl-failure, empty-body, and
# non-empty-without-string are kept as three distinct states so the message
# never points investigation at the wrong thing.
log "Check 4: admin http://127.0.0.1:${ADMIN_PORT}/ shows Kanban de histórias registration ..."
ADMIN_RETRIES="${ADMIN_RETRIES:-3}"
ADMIN_RETRY_DELAY="${ADMIN_RETRY_DELAY:-2}"
admin_attempt=0
admin_state=""
admin_detail=""
while [ "$admin_attempt" -lt "$ADMIN_RETRIES" ]; do
  admin_attempt=$((admin_attempt + 1))
  ADMIN_BODY_FILE="/tmp/wa-prodtest-admin.$$.html"
  ADMIN_CODE=$(curl -s --max-time 10 -o "$ADMIN_BODY_FILE" -w "%{http_code}" \
    "http://127.0.0.1:${ADMIN_PORT}/" 2>/dev/null)
  ADMIN_CURL_EXIT=$?
  ADMIN_BODY=""
  ADMIN_BODY_SIZE=0
  if [ -f "$ADMIN_BODY_FILE" ]; then
    ADMIN_BODY_SIZE=$(wc -c < "$ADMIN_BODY_FILE" | tr -d '[:space:]')
    ADMIN_BODY=$(cat "$ADMIN_BODY_FILE")
    rm -f "$ADMIN_BODY_FILE"
  fi

  if [ "$ADMIN_CURL_EXIT" -ne 0 ]; then
    admin_state="curl_failed"
    admin_detail="admin :${ADMIN_PORT} check failed — curl could not connect (exit ${ADMIN_CURL_EXIT}) after ${admin_attempt} attempt(s). MEASURED: connection failure only. Possible causes (not verified by this check): admin daemon down, port not listening, network/firewall issue."
  elif [ "$ADMIN_BODY_SIZE" -eq 0 ]; then
    admin_state="empty_body"
    admin_detail="admin :${ADMIN_PORT} check failed — HTTP ${ADMIN_CODE}, empty response body (0 bytes) after ${admin_attempt} attempt(s). MEASURED: empty body only. Possible causes (not verified by this check): daemon returned an empty response, upstream aggregation error."
  elif ! printf '%s' "$ADMIN_BODY" | grep -q "Kanban de histórias"; then
    admin_state="string_missing"
    admin_detail="admin :${ADMIN_PORT} check failed — HTTP ${ADMIN_CODE}, body ${ADMIN_BODY_SIZE} bytes, does not contain 'Kanban de histórias' after ${admin_attempt} attempt(s). MEASURED: string absent from a non-empty body only. Possible causes (not verified by this check): registration missing, admin daemon not restarted after ga-52ib rename, or a transient aggregation render issue."
  else
    admin_state="ok"
    break
  fi

  if [ "$admin_attempt" -lt "$ADMIN_RETRIES" ]; then
    log "Check 4 attempt ${admin_attempt}/${ADMIN_RETRIES}: ${admin_state} — retrying in ${ADMIN_RETRY_DELAY}s ..."
    sleep "$ADMIN_RETRY_DELAY"
  fi
done

if [ "$admin_state" != "ok" ]; then
  fail "$admin_detail"
fi
if [ "$admin_attempt" -gt 1 ]; then
  log "admin registration present OK (needed retry: passed on attempt ${admin_attempt}/${ADMIN_RETRIES})"
else
  log "admin registration present OK"
fi
if ! printf '%s' "$ADMIN_BODY" | grep -q "${PAINEL_PORT}"; then
  log "WARN: admin console lists the painel but not port ${PAINEL_PORT} explicitly (non-fatal)."
fi

# ── Optional story-specific test ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$STORY_ID" ] && [ -f "$SCRIPT_DIR/story-${STORY_ID}.sh" ]; then
  log "Running story-specific test: story-${STORY_ID}.sh"
  bash "$SCRIPT_DIR/story-${STORY_ID}.sh" || fail "story-${STORY_ID} test failed"
  log "story-specific test PASS"
fi

log "ALL PASS"
exit 0
