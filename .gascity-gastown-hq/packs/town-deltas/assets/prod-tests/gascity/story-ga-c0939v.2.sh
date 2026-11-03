#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.2.sh — prod test for ga-c0939v.2 (slice 2/4 of ga-c0939v): the JSONL dump is uploaded to S3 every hour,
# with a manifest, and the last verification is recent.
#
# "Merged" is not "live": this checks the DEPLOYED script/helper/order file, that the launchd job com.gascity.jsonl-hourly-offsite is installed (same bytes as the
# repo copy), loaded and has run, that the gc order it replaced is OFF, and what is really in S3 right now (latest.json via `--status`, plus its manifest).
# It only READS: nothing is written to the bucket, nothing is restored.
#
# SINCE ga-ki02nmt (2026-11-03) the upload runs from launchd, not from the gc order: the engine dispatcher serves ~1.16 order runs/min against ~14.7 asked, so the
# "every 30 min" order ran every ~35 min or worse and latest.json aged past the 75 min alarm. The order file stays in the repo (the source of the 30 m / 2400 s the plist
# copies; scripts/jsonl-launchd-plists.selftest.sh holds them equal) and city.toml [orders] skip switches it off, so this test now requires it NOT to be listed.
#
# NÃO PROVA que o restore funciona: isso é o jsonl-hourly-restore.sh, rodado de verdade (docs/runbooks/jsonl-hourly-offsite.md).
# Um snapshot fresco no S3 com restore nunca provado NÃO é RPO.
#
# Estados (nunca dois): ok / fail / unproven. `--status` UNKNOWN (sem credencial, S3 fora, latest.json ilegível) nunca vira PASS limpo:
#   sem o job do launchd ter rodado é "unproven" (um deploy novo ainda não chegou ao 1º tick de 30 min); depois que rodou é FAIL.

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
[[ -f "$ORDER_FILE" ]] || fail "deployed order file missing: $ORDER_FILE (skipped, but it is the source of the cadence/timeout the plist copies)"
grep -q -- '--checksum-sha256' "$SCRIPT" || fail "deployed script does not send --checksum-sha256 — the unverified-upload version is live"
# interval: "30m" since ga-c0939v.7 (was "1h": every cooldown order overshoots its interval by a median ~6 min, so "1h" never gave a <= 60 min gap — see story-ga-c0939v.7.sh for the measured proof)
grep -q 'trigger = "cooldown"' "$ORDER_FILE" && grep -q 'interval = "30m"' "$ORDER_FILE" || fail "order file is not cooldown/30m: $(grep -E '^(trigger|interval)' "$ORDER_FILE" | tr '\n' ' ')"
log "script, helper and order file deployed ✓"
# the launchd job's plist: the repo copy exists and the INSTALLED one is the same bytes (a stale installed copy would keep running an old timeout/interval).
# ausente no repo / ausente em ~/Library/LaunchAgents / diferente → FALHA; "skip ligado e plist não instalado" = nenhum upload.
PLIST_REPO="$CITY/scripts/com.gascity.jsonl-hourly-offsite.plist"
PLIST_INST="$HOME/Library/LaunchAgents/com.gascity.jsonl-hourly-offsite.plist"
[[ -f "$PLIST_REPO" ]] || fail "plist missing in the repo: $PLIST_REPO"
[[ -f "$PLIST_INST" ]] || fail "plist NOT installed: $PLIST_INST — the order is skipped and nothing runs the upload (docs/runbooks/jsonl-launchd-cutover.md)"
cmp -s "$PLIST_REPO" "$PLIST_INST" || fail "installed plist differs from the repo copy ($PLIST_INST vs $PLIST_REPO): reinstall it and bootout/bootstrap the label"
log "launchd plist installed, identical to the repo copy ✓"

# ── 2. the gc order it replaced is OFF (city.toml [orders] skip) ───────────────
# lista ilegível / ok:false / jq falhou → FALHA ("não sei" nunca vira "0 instâncias"); 0 instâncias é o estado ESPERADO desde o ga-ki02nmt.
orders="$(_to 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed (or timed out)"
n="$(printf '%s' "$orders" | jq -r 'if .ok == true and (.orders | type == "array") then ([.orders[] | select(.name == "jsonl-hourly-offsite")] | length | tostring) else "unreadable" end' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (parsed '${n:-nothing}')"
[[ "$n" -eq 0 ]] || fail "order jsonl-hourly-offsite is still listed by gc order list ($n instance(s)): its launchd job runs the upload now — add \"jsonl-hourly-offsite\" to city.toml [orders] skip, or the cadence is the dispatcher's again"
log "gc order list: jsonl-hourly-offsite is not listed (skipped) ✓"

# ── 3. has LAUNCHD run the job? (the only proof it is loaded and ticking) ─────
# launchctl ausente / label não carregada → FALHA; "runs =" ausente/ilegível → UNPROVEN (não sei se rodou); runs = 0 → UNPROVEN; runs >= 1 → rodou.
FIRED="unknown"
LABEL="com.gascity.jsonl-hourly-offsite"
command -v launchctl >/dev/null 2>&1 || fail "launchctl not found: cannot tell whether $LABEL is loaded"
lp="$(launchctl print "gui/$(id -u)/$LABEL" 2>&1)"; lrc=$?
[[ "$lrc" -eq 0 ]] || fail "$LABEL is NOT loaded in gui/$(id -u) ($(printf '%s' "$lp" | head -1)) — the order is skipped and nothing runs the upload: launchctl bootstrap it (docs/runbooks/jsonl-launchd-cutover.md)"
printf '%s\n' "$lp" | grep -qF "$SCRIPT" || fail "$LABEL is loaded but its arguments do not run $SCRIPT"
fired="$(printf '%s\n' "$lp" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)"
if [[ ! "$fired" =~ ^[0-9]+$ ]]; then
  log "WARN: launchctl print $LABEL has no readable 'runs =' line (parsed '${fired:-nothing}') — whether launchd has run the job is UNKNOWN"
  _unproven "launchd run count UNKNOWN (launchctl print has no 'runs =')"
elif [[ "$fired" -eq 0 ]]; then
  FIRED=0
  log "WARN: $LABEL is loaded but has run 0 times — 'launchd ticks the job' is UNPROVEN. Re-run this test after a few minutes (RunAtLoad starts it at bootstrap)."
  _unproven "launchd has not run the job yet (0 runs)"
else
  FIRED="$fired"
  log "launchd has run $LABEL $fired time(s) ✓ (loaded, runs $SCRIPT)"
fi

# ── 4. what is in S3 right now (read-only) ────────────────────────────────────
out="$(JHO_AWS="$AWS_BIN" _to 120 "$SCRIPT" --status 2>&1)"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
case "$rc" in
  0) log "last check is recent ✓ (checked_at <= 75 min; the script only moves it while the exporter writes AND commits the databases — data_as_of is when the data last CHANGED)" ;;
  1) if [[ "$FIRED" == "0" ]]; then
       _unproven "latest.json is STALE but the launchd job has not run yet (a manual first upload is old)"
     else
       fail "--status: latest.json is STALE although launchd ran the job ($FIRED time(s), or the count is unreadable) — the upload is not keeping up, or the exporter stopped (log: 'fonte parada')"
     fi ;;
  2) if [[ "$FIRED" == "0" ]]; then
       _unproven "--status UNKNOWN and the launchd job has not run yet (no first snapshot, or S3/credentials unreadable from here)"
     else
       fail "--status UNKNOWN after launchd ran the job (or with the run count unreadable) — cannot read latest.json from S3 (credentials? bucket? no snapshot ever verified?)"
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
