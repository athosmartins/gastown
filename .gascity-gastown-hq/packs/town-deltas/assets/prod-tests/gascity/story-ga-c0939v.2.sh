#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.2.sh — prod test for ga-c0939v.2 (slice 2/4 of ga-c0939v): the JSONL dump is uploaded to S3 every hour,
# with a manifest, and the last verification is recent.
#
# "Merged" is not "live": this checks the DEPLOYED script/helper/order, that `gc order list` resolves the order, whether the
# CONTROLLER has actually fired it, and what is really in S3 right now (latest.json via `--status`, plus its manifest).
# It only READS: nothing is written to the bucket, nothing is restored.
#
# NÃO PROVA que o restore funciona: isso é o jsonl-hourly-restore.sh, rodado de verdade (docs/runbooks/jsonl-hourly-offsite.md).
# Um snapshot fresco no S3 com restore nunca provado NÃO é RPO.
#
# Estados (nunca dois): ok / fail / unproven. `--status` UNKNOWN (sem credencial, S3 fora, latest.json ilegível) nunca vira PASS limpo:
#   sem o order ter disparado é "unproven" (um deploy novo ainda não chegou ao 1º tick de 30 min); depois que disparou é FAIL.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SDIR="$CITY/packs/town-deltas/assets/scripts"
SCRIPT="$SDIR/jsonl-hourly-offsite.sh"
ORDER_FILE="$CITY/packs/town-deltas/orders/jsonl-hourly-offsite.toml"
BUCKET="${JHO_BUCKET:-urblink-dolt-backups}"
AWS_BIN="${JHO_AWS:-$(command -v aws || echo /opt/homebrew/bin/aws)}"

log()  { echo "[prod-test:gascity ga-c0939v.2] $*"; }
fail() { echo "[prod-test:gascity ga-c0939v.2] FAIL: $*" >&2; exit 1; }
_TO=""; for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _TO="$_t"; break; }; done
_to() { local t="$1"; shift; if [[ -n "$_TO" ]]; then "$_TO" "$t" "$@"; else "$@"; fi; }
[[ -n "$_TO" ]] || echo "[prod-test:gascity ga-c0939v.2] WARN: no timeout/gtimeout on this host — the gc/aws calls below are NOT time-bounded"
UNPROVEN=""; UNPROVEN_N=0
_unproven() { UNPROVEN_N=$((UNPROVEN_N + 1)); UNPROVEN="${UNPROVEN:+$UNPROVEN; }$1"; }

# ── 1. deployed artifacts exist and are the verified-upload version ───────────
for f in jsonl-hourly-offsite.sh jsonl_hourly.py; do
  [[ -f "$SDIR/$f" ]] || fail "deployed file missing: $SDIR/$f"
done
[[ -x "$SCRIPT" ]] || fail "deployed script not executable: $SCRIPT"
[[ -f "$ORDER_FILE" ]] || fail "deployed order file missing: $ORDER_FILE"
grep -q -- '--checksum-sha256' "$SCRIPT" || fail "deployed script does not send --checksum-sha256 — the unverified-upload version is live"
# interval: "30m" since ga-c0939v.7 (was "1h": every cooldown order overshoots its interval by a median ~6 min, so "1h" never gave a <= 60 min gap — see story-ga-c0939v.7.sh for the measured proof)
grep -q 'trigger = "cooldown"' "$ORDER_FILE" && grep -q 'interval = "30m"' "$ORDER_FILE" || fail "order file is not cooldown/30m: $(grep -E '^(trigger|interval)' "$ORDER_FILE" | tr '\n' ' ')"
log "script, helper and order file deployed ✓"

# ── 2. `gc order list` resolves the order from the deployed pack (CLI-side scan) ──
orders="$(_to 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed (or timed out)"
n="$(printf '%s' "$orders" | jq '[.orders[] | select(.name == "jsonl-hourly-offsite")] | length' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (jq: '$n')"
[[ "$n" -ge 1 ]] || fail "order jsonl-hourly-offsite is NOT listed by gc order list — the pack is not deployed or the file does not parse"
src="$(printf '%s' "$orders" | jq -r '[.orders[] | select(.name == "jsonl-hourly-offsite")][0].source' 2>/dev/null)"
[[ "$src" == *"packs/town-deltas/orders/jsonl-hourly-offsite.toml" ]] || fail "order resolved from an unexpected source: $src"
log "gc order list resolves the order ($n instance) from $src ✓ (CLI-side scan; whether the controller loaded it is section 3)"

# ── 3. has the CONTROLLER fired the order? (the only proof it loaded it) ──────
FIRED="unknown"
hist="$(_to 90 gc --city "$CITY" order history jsonl-hourly-offsite --json 2>/dev/null)"; hrc=$?
fired="$(printf '%s' "$hist" | jq -r 'if .ok == true and (.entries | type == "array") then [.entries[] | select(.order == "jsonl-hourly-offsite")] | length else "unreadable" end' 2>/dev/null)"
if [[ "$hrc" -ne 0 || ! "$fired" =~ ^[0-9]+$ ]]; then
  log "WARN: could not read gc order history (rc=$hrc, parsed '${fired:-nothing}') — whether the controller has fired the order is UNKNOWN"
  _unproven "controller firing UNKNOWN (gc order history unreadable)"
elif [[ "$fired" -eq 0 ]]; then
  FIRED=0
  log "WARN: gc order history has 0 runs of jsonl-hourly-offsite — the controller has NOT fired it yet, so 'the controller loaded the order' is UNPROVEN. Re-run this test after >= 30 min."
  _unproven "controller has not fired the order yet (0 runs)"
else
  FIRED="$fired"
  log "controller has fired the order $fired time(s), last at $(printf '%s' "$hist" | jq -r '[.entries[] | select(.order == "jsonl-hourly-offsite") | .executed] | max' 2>/dev/null) ✓"
fi

# ── 4. what is in S3 right now (read-only) ────────────────────────────────────
out="$(JHO_AWS="$AWS_BIN" _to 120 "$SCRIPT" --status 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
case "$rc" in
  0) log "last check is recent ✓ (checked_at <= 75 min; the script only moves it while the exporter writes AND commits the databases — data_as_of is when the data last CHANGED)" ;;
  1) if [[ "$FIRED" == "0" ]]; then
       _unproven "latest.json is STALE but the order has not fired yet (a manual first upload is old)"
     else
       fail "--status: latest.json is STALE although the order fired ($FIRED time(s), or its history is unreadable) — the upload is not keeping up, or the exporter stopped (log: 'fonte parada')"
     fi ;;
  2) if [[ "$FIRED" == "0" ]]; then
       _unproven "--status UNKNOWN and the order has not fired yet (no first snapshot, or S3/credentials unreadable from here)"
     else
       fail "--status UNKNOWN after the order fired (or with its history unreadable) — cannot read latest.json from S3 (credentials? bucket? no snapshot ever verified?)"
     fi ;;
  *) fail "--status exited $rc (unexpected)" ;;
esac

if [[ "$rc" -eq 0 ]]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/ga-c0939v.XXXXXX")" || fail "mktemp"
  trap 'rm -f "$tmp" "$tmp.m"' EXIT
  _to 120 "$AWS_BIN" s3api get-object --bucket "$BUCKET" --key jsonl-hourly/latest.json "$tmp" >/dev/null 2>&1 || fail "latest.json read once by --status but not now"
  mkey="$(jq -r '.manifest_key // empty' "$tmp")"
  [[ -n "$mkey" ]] || fail "latest.json has no manifest_key"
  _to 120 "$AWS_BIN" s3api get-object --bucket "$BUCKET" --key "$mkey" "$tmp.m" >/dev/null 2>&1 || fail "manifest $mkey (named by latest.json) is not readable in S3"
  verdict="$(jq -r '.verdict' "$tmp.m")"
  [[ "$verdict" == "ok" ]] || fail "the manifest latest.json points at has verdict '$verdict' (problems: $(jq -r '.problems | join("; ")' "$tmp.m"))"
  hq="$(jq -r '.databases.hq.issues // 0' "$tmp.m")"; wa="$(jq -r '.databases.whatsapp_automation.issues // 0' "$tmp.m")"
  [[ "$hq" =~ ^[0-9]+$ && "$hq" -gt 0 && "$wa" =~ ^[0-9]+$ && "$wa" -gt 0 ]] || fail "manifest has no issues for hq ($hq) or whatsapp_automation ($wa)"
  log "manifest ok: hq=$hq issues, whatsapp_automation=$wa issues, data_as_of $(jq -r '.data_as_of' "$tmp.m") ✓"
  log "NOTE: this proves the upload is live and readable, NOT that a restore works — see docs/runbooks/jsonl-hourly-offsite.md (jsonl-hourly-restore.sh)"
fi

if [[ "$UNPROVEN_N" -gt 0 ]]; then log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; else log "PASS"; fi
exit 0
