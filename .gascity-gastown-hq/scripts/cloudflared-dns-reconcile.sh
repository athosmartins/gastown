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
#   - Idempotent: `cloudflared tunnel route dns` is a no-op when the route
#     already points at this tunnel (it just logs "already configured").
#   - Logs every action to LOG_FILE; also echoes to the terminal when run
#     interactively. Under launchd, stdout is redirected to LOG_FILE, so we
#     echo to stdout ONLY when it is a tty — otherwise every line would be
#     written twice (once by the script, once by the launchd redirect).
#   - Safe: only ADDS missing DNS routes. Never edits the ingress YAML, never
#     deletes records, never touches Cloudflare Access.
#
# AUTH
#   Uses the tunnel-scoped credentials in ~/.cloudflared/cert.pem, which can
#   perform `cloudflared tunnel route dns`. No secrets are printed.

set -uo pipefail

CLOUDFLARED="${CLOUDFLARED:-/opt/homebrew/bin/cloudflared}"
CONFIG="${CLOUDFLARED_CONFIG:-/Users/athos/.cloudflared/urblink-ops.yml}"
LOG_FILE="${LOG_FILE:-/tmp/cloudflared-dns-reconcile.log}"

log() {
  local line="$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
  printf '%s\n' "$line" >> "$LOG_FILE"
  # Echo to stdout only when interactive; under launchd stdout is the LOG_FILE,
  # so echoing unconditionally would duplicate every line.
  [[ -t 1 ]] && printf '%s\n' "$line"
  return 0
}

if [[ ! -x "$CLOUDFLARED" ]]; then
  log "ERROR: cloudflared not found/executable at $CLOUDFLARED"
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  log "ERROR: config not found at $CONFIG"
  exit 1
fi

# Extract the tunnel id from the config (first `tunnel:` line).
TUNNEL_ID="$(awk -F': *' '/^tunnel:/{print $2; exit}' "$CONFIG" | tr -d '[:space:]')"
if [[ -z "$TUNNEL_ID" ]]; then
  log "ERROR: could not parse tunnel id from $CONFIG"
  exit 1
fi

# Extract all ingress hostnames. Matches lines like:
#   - hostname: foo.urblink.com.br
HOSTS="$(awk '/hostname:/{ for(i=1;i<=NF;i++) if($i=="hostname:"){print $(i+1)} }' "$CONFIG" | tr -d ' \t\r' | grep -v '^$' | sort -u)"

if [[ -z "$HOSTS" ]]; then
  log "WARN: no hostnames found in ingress; nothing to reconcile"
  exit 0
fi

log "reconcile start: tunnel=$TUNNEL_ID config=$CONFIG hosts=$(echo "$HOSTS" | wc -l | tr -d ' ')"

created=0
ok=0
failed=0

while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  out="$("$CLOUDFLARED" tunnel --config "$CONFIG" route dns "$TUNNEL_ID" "$host" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    # A non-zero exit usually means the record exists but points elsewhere, or
    # a transient API error. Report it; do NOT attempt to overwrite blindly.
    log "FAIL  $host :: $(echo "$out" | tail -1)"
    failed=$((failed+1))
  elif echo "$out" | grep -qi 'already configured'; then
    ok=$((ok+1))
  else
    # New route created (e.g. "INF Added CNAME ... which will route to ...")
    log "CREATED $host :: $(echo "$out" | tail -1)"
    created=$((created+1))
  fi
done <<< "$HOSTS"

log "reconcile done: created=$created already_ok=$ok failed=$failed"

# Exit non-zero only if a route actually failed, so launchd/monitoring can flag it.
[[ $failed -eq 0 ]]
