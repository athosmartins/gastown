#!/usr/bin/env bash
# prod-tests/lexbh/run.sh — rig-level prod test for lexbh.
#
# Called by story-delivery.sh after deploy. Exits 0 on pass, non-zero on fail.
# Added by ga-apcolz so lexbh deliveries can reach story:done via the automated
# gate pipeline instead of halting forever on "no prod_test_script" (ga-dqp
# interim policy) / "no deploy_cmd" (ga-aqqj0 retry cap, hit on lx-dnw).
#
# STORY_ID (set by story-delivery.sh) selects an OPTIONAL story-specific test;
# the baseline smoke checks below always run and gate pass/fail on their own.
#
# What this proves:
#   1. The dashboard (:7842) is live. GET / redirects to /radar by design (see
#      dashboard/app.py's index() route) — curl -L follows that hop, so a
#      healthy service resolves to HTTP 200 with recognizable content.
#   2. The acervo search (GET /acervo?q=...) is live and returns a non-empty
#      result set for a known, stable query term.

set -uo pipefail

LEXBH_PORT="${LEXBH_PORT:-7842}"
SEARCH_TERM="${LEXBH_SMOKE_QUERY:-IPTU}"
STORY_ID="${STORY_ID:-}"

log()  { echo "[prod-test:lexbh] $*"; }
fail() { echo "[prod-test:lexbh] FAIL: $*" >&2; exit 1; }

# ── Check 1: dashboard :7842 is live (/ redirects to /radar — follow it) ──────
log "Check 1: http://127.0.0.1:${LEXBH_PORT}/ resolves to HTTP 200 ..."
INDEX_BODY="/tmp/lexbh-prodtest-index.$$.html"
INDEX_CODE=$(curl -sL --max-time 10 -o "$INDEX_BODY" -w "%{http_code}" \
  "http://127.0.0.1:${LEXBH_PORT}/" 2>/dev/null || echo "000")
if [ "$INDEX_CODE" != "200" ]; then
  rm -f "$INDEX_BODY"
  fail "http://127.0.0.1:${LEXBH_PORT}/ returned HTTP ${INDEX_CODE} (expected 200 after following the /radar redirect) — daemon down, wrong port, or not serving?"
fi
if ! grep -q "LexBH" "$INDEX_BODY"; then
  rm -f "$INDEX_BODY"
  fail "served HTML does not contain 'LexBH' — wrong page served, or daemon not restarted after deploy?"
fi
rm -f "$INDEX_BODY"
log "dashboard HTTP 200, 'LexBH' present OK"

# ── Check 2: acervo search returns a non-empty result set ─────────────────────
log "Check 2: GET /acervo?q=${SEARCH_TERM} returns at least one result ..."
SEARCH_BODY="/tmp/lexbh-prodtest-acervo.$$.html"
SEARCH_CODE=$(curl -sL --max-time 15 -o "$SEARCH_BODY" -w "%{http_code}" \
  --data-urlencode "q=${SEARCH_TERM}" -G \
  "http://127.0.0.1:${LEXBH_PORT}/acervo" 2>/dev/null || echo "000")
if [ "$SEARCH_CODE" != "200" ]; then
  rm -f "$SEARCH_BODY"
  fail "GET /acervo?q=${SEARCH_TERM} returned HTTP ${SEARCH_CODE} (expected 200)"
fi
if grep -q "Nenhum resultado" "$SEARCH_BODY"; then
  rm -f "$SEARCH_BODY"
  fail "acervo search for '${SEARCH_TERM}' returned zero results ('Nenhum resultado') — search index empty/broken, or DB not reachable?"
fi
if ! grep -q "norma(s)" "$SEARCH_BODY"; then
  rm -f "$SEARCH_BODY"
  fail "acervo search response for '${SEARCH_TERM}' missing the expected 'norma(s)' result marker — page shape changed?"
fi
rm -f "$SEARCH_BODY"
log "acervo search OK"

# ── Optional story-specific test ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "$STORY_ID" ] && [ -f "$SCRIPT_DIR/story-${STORY_ID}.sh" ]; then
  log "Running story-specific test: story-${STORY_ID}.sh"
  bash "$SCRIPT_DIR/story-${STORY_ID}.sh" || fail "story-${STORY_ID} test failed"
  log "story-specific test PASS"
fi

log "ALL PASS"
exit 0
