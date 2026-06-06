#!/usr/bin/env bash
#
# cloudflared-dns-reconcile.sh
#
# PURPOSE
#   Ensure every `hostname:` listed in the cloudflared ingress config has a
#   corresponding public DNS route to the tunnel. When a new hostname is added
#   to the ingress YAML, the tunnel will serve it locally, but Cloudflare's
#   public edge returns HTTP 404 until a DNS route (proxied CNAME ->
#   <tunnel-id>.cfargotunnel.com) is created. This reconciler closes that gap
#   automatically so newly-published URLs self-heal instead of 404ing.
#
# ROOT CAUSE THIS PREVENTS
#   "sempre que e publicado uma URL nova da esse pau" — every newly published
#   hostname 404s from the public internet because the ingress entry exists but
#   the DNS route was never created. Triggered by painel.urblink.com.br and
#   qualidade.urblink.com.br (2026-06-04).
#
# BEHAVIOR
#   Read-first: queries Cloudflare API to find which hostnames are already
#   configured, then only calls `cloudflared tunnel route dns` for the ones
#   that are genuinely missing. In the steady state (all hosts already
#   configured), this is a single fast read instead of N slow writes.
#
#   - Idempotent: safe to run repeatedly; existing records are never touched.
#   - Safe: only ADDS missing DNS routes. Never edits the ingress YAML, never
#     deletes records, never touches Cloudflare Access.
#   - Fallback: if the Cloudflare API call fails, falls back to calling
#     `cloudflared tunnel route dns` for every host (pre-v2 behavior).
#   - Logs every action to LOG_FILE; also echoes to the terminal when run
#     interactively. Under launchd, stdout is redirected to LOG_FILE, so we
#     echo to stdout ONLY when it is a tty — otherwise every line would be
#     written twice (once by the script, once by the launchd redirect).
#
# AUTH
#   API token and zone ID extracted from ~/.cloudflared/cert.pem (the Argo
#   Tunnel token). No secrets are printed to logs.

set -uo pipefail

CLOUDFLARED="${CLOUDFLARED:-/opt/homebrew/bin/cloudflared}"
CONFIG="${CLOUDFLARED_CONFIG:-/Users/athos/.cloudflared/urblink-ops.yml}"
CERT="${CLOUDFLARE_CERT:-/Users/athos/.cloudflared/cert.pem}"
LOG_FILE="${LOG_FILE:-/tmp/cloudflared-dns-reconcile.log}"

log() {
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  printf '%s\n' "$line" >> "$LOG_FILE"
  # Echo to stdout only when interactive; under launchd stdout is LOG_FILE,
  # so echoing unconditionally would duplicate every line.
  [[ -t 1 ]] && printf '%s\n' "$line"
  return 0
}

# --- Preflight ---
if [[ ! -x "$CLOUDFLARED" ]]; then
  log "ERROR: cloudflared not found/executable at $CLOUDFLARED"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  log "ERROR: config not found at $CONFIG"
  exit 1
fi

if [[ ! -f "$CERT" ]]; then
  log "ERROR: cert not found at $CERT"
  exit 1
fi

# --- Parse YAML config ---
TUNNEL_ID="$(awk -F': *' '/^tunnel:/{print $2; exit}' "$CONFIG" | tr -d '[:space:]')"
if [[ -z "$TUNNEL_ID" ]]; then
  log "ERROR: could not parse tunnel id from $CONFIG"
  exit 1
fi

# Extract all ingress hostnames. Matches lines like:
#   - hostname: foo.urblink.com.br
YAML_HOSTS="$(awk '/hostname:/{ for(i=1;i<=NF;i++) if($i=="hostname:"){print $(i+1)} }' "$CONFIG" \
  | tr -d ' \t\r' | grep -v '^$' | sort -u)"

if [[ -z "$YAML_HOSTS" ]]; then
  log "WARN: no hostnames found in ingress; nothing to reconcile"
  exit 0
fi

yaml_count="$(printf '%s\n' "$YAML_HOSTS" | grep -c .)"

# --- Extract Cloudflare API credentials from cert.pem ---
# cert.pem contains a base64-encoded JSON with apiToken and zoneID fields.
_py_extract_creds='
import base64, json, re, sys
try:
    with open("/Users/athos/.cloudflared/cert.pem") as f:
        cert = f.read()
    m = re.search(r"-----BEGIN ARGO TUNNEL TOKEN-----\n([\s\S]+?)\n-----END ARGO TUNNEL TOKEN-----", cert)
    if not m:
        print("ERROR: no ARGO TUNNEL TOKEN found in cert.pem", file=sys.stderr); sys.exit(1)
    raw = m.group(1).replace("\n", "")
    raw += "=" * (-len(raw) % 4)
    data = json.loads(base64.b64decode(raw))
    api_token = data.get("apiToken", "")
    zone_id = data.get("zoneID", "")
    if not api_token or not zone_id:
        print("ERROR: apiToken or zoneID missing from cert.pem token", file=sys.stderr); sys.exit(1)
    print(api_token)
    print(zone_id)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)
'
_creds="$(python3 -c "$_py_extract_creds" 2>&1)"

if printf '%s\n' "$_creds" | grep -q '^ERROR:'; then
  log "ERROR: failed to extract Cloudflare credentials: $_creds"
  exit 1
fi

CF_TOKEN="$(printf '%s\n' "$_creds" | sed -n '1p')"
ZONE_ID="$(printf '%s\n' "$_creds" | sed -n '2p')"

# --- Query Cloudflare API: which hostnames already point to this tunnel? ---
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"
_cf_response="$(curl -sf \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&per_page=500" 2>&1)"
curl_rc=$?

_reconcile_fallback() {
  # Pre-v2 behavior: call cloudflared for all hosts (used when API unavailable).
  log "FALLBACK: calling cloudflared route dns for all $yaml_count hosts"
  local created=0 ok=0 failed=0
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    local out rc
    out="$("$CLOUDFLARED" tunnel --config "$CONFIG" route dns "$TUNNEL_ID" "$host" 2>&1)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      log "FAIL  $host :: $(printf '%s\n' "$out" | tail -1)"
      failed=$((failed+1))
    elif printf '%s\n' "$out" | grep -qi 'already configured'; then
      ok=$((ok+1))
    else
      log "CREATED $host :: $(printf '%s\n' "$out" | tail -1)"
      created=$((created+1))
    fi
  done <<< "$YAML_HOSTS"
  log "reconcile done (fallback): created=$created already_ok=$ok failed=$failed"
  [[ $failed -eq 0 ]]
}

if [[ $curl_rc -ne 0 ]]; then
  log "WARN: Cloudflare API request failed (curl exit=$curl_rc)"
  _reconcile_fallback
  exit $?
fi

_api_ok="$(printf '%s\n' "$_cf_response" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('success') else 'no')" 2>/dev/null || echo 'no')"

if [[ "$_api_ok" != "yes" ]]; then
  _err="$(printf '%s\n' "$_cf_response" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('errors','unknown'))" 2>/dev/null || echo "$_cf_response")"
  log "WARN: Cloudflare API returned success=false: $_err"
  _reconcile_fallback
  exit $?
fi

# Extract hostnames that already have a CNAME pointing to this tunnel.
_py_extract_hosts="
import json, sys
data = json.loads(sys.argv[1])
tunnel_cname = sys.argv[2]
for r in data.get('result', []):
    if r.get('content', '') == tunnel_cname:
        print(r['name'])
"
CF_CONFIGURED="$(python3 -c "$_py_extract_hosts" "$_cf_response" "$TUNNEL_CNAME")"

cf_count="$(printf '%s\n' "$CF_CONFIGURED" | grep -c . || true)"
log "reconcile start: tunnel=$TUNNEL_ID yaml_hosts=$yaml_count cloudflare_configured=$cf_count"

# --- Diff: find YAML hostnames not yet in Cloudflare ---
MISSING_HOSTS=""
while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  if ! printf '%s\n' "$CF_CONFIGURED" | grep -qxF "$host"; then
    MISSING_HOSTS="${MISSING_HOSTS}${host}"$'\n'
  fi
done <<< "$YAML_HOSTS"
MISSING_HOSTS="${MISSING_HOSTS%$'\n'}"

if [[ -z "$MISSING_HOSTS" ]]; then
  log "reconcile done: all $yaml_count hosts already configured in Cloudflare — nothing to do"
  exit 0
fi

missing_count="$(printf '%s\n' "$MISSING_HOSTS" | grep -c .)"
log "found $missing_count missing host(s) not yet in Cloudflare — adding now"

# --- Add missing hosts via cloudflared ---
created=0
failed=0

while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  out="$("$CLOUDFLARED" tunnel --config "$CONFIG" route dns "$TUNNEL_ID" "$host" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log "FAIL  $host :: $(printf '%s\n' "$out" | tail -1)"
    failed=$((failed+1))
  else
    log "CREATED $host :: $(printf '%s\n' "$out" | tail -1)"
    created=$((created+1))
  fi
done <<< "$MISSING_HOSTS"

already_ok=$((yaml_count - missing_count))
log "reconcile done: created=$created already_ok=$already_ok failed=$failed"

# Exit non-zero only if a route actually failed, so launchd/monitoring can flag it.
[[ $failed -eq 0 ]]
