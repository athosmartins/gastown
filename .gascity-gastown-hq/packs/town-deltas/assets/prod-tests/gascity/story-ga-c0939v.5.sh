#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.5.sh — prod test for ga-c0939v.5 (slice 5 of ga-c0939v): the restore of the biggest database (hq)
# has a MEASURED verdict recorded in the runbook, and the restore chain that produced it is complete on this host.
#
# Read-only: nothing is restored, nothing is read from S3. The restore itself (minutes, GBs, the MBP) is not repeated here; this checks
# that the deployed chain is whole (script + helper + the module the helper imports) and that the deployed runbook says what was measured.
#
# Estados (nunca dois): ok / fail / unproven. Runbook ausente no checkout implantado é FAIL (mergeado não é implantado).

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SDIR="$CITY/packs/town-deltas/assets/scripts"
RUNBOOK="$CITY/docs/runbooks/jsonl-hourly-offsite.md"

log()  { echo "[prod-test:gascity ga-c0939v.5] $*"; }
fail() { echo "[prod-test:gascity ga-c0939v.5] FAIL: $*" >&2; exit 1; }

# ── 1. the restore chain is complete on this host ────────────────────────────
# The 18/10 hq round died in 0 s because jsonl_hourly.py (imported by the helper) was not shipped with it: all three files, and the import itself.
for f in jsonl-hourly-restore.sh jsonl_hourly_restore.py jsonl_hourly.py; do
  [[ -f "$SDIR/$f" ]] || fail "deployed file missing: $SDIR/$f"
done
[[ -x "$SDIR/jsonl-hourly-restore.sh" ]] || fail "deployed restore script not executable"
command -v python3 >/dev/null 2>&1 || { log "PASS (1 unproven: python3 not on PATH, the helper import was not exercised)"; exit 0; }
python3 -I "$SDIR/jsonl_hourly_restore.py" --help >/dev/null 2>&1 || fail "the deployed helper does not start (python3 -I jsonl_hourly_restore.py --help): a module it imports is missing or broken"
log "restore script, helper and the module it imports are deployed, and the helper starts ✓"

# ── 2. the deployed runbook records the hq verdict ───────────────────────────
[[ -f "$RUNBOOK" ]] || fail "deployed runbook missing: $RUNBOOK"
# vazio → sem a linha do hq = FAIL (não mediram / não implantou); ilegível → grep rc 2 cai no mesmo FAIL, nunca em PASS
row="$(grep -E '^\| hq \| 0 \| [0-9]+/[0-9]+ \|' "$RUNBOOK" | head -1)"
[[ -n "$row" ]] || fail "runbook has no 'hq | 0' measured row (the hq restore has no recorded verdict)"
nums="$(printf '%s' "$row" | sed -E 's/^\| hq \| 0 \| ([0-9]+)\/([0-9]+) \|.*/\1 \2/')"
[[ "${nums% *}" =~ ^[0-9]+$ && "${nums% *}" == "${nums#* }" ]] || fail "the hq row's issues cell is not restored == expected: '${nums}'"
grep -q 'Restore provado" vale agora para gastown e whatsapp_automation (17/10) e hq (18/10)' "$RUNBOOK" || fail "runbook does not state that the restore proof now covers hq"
# três estados: rc 0 = ainda diz "NÃO provado" (FAIL) · rc 1 = não diz (segue) · rc >= 2 = não consegui ler (FAIL, nunca "não diz")
grep -q '\*\*hq NÃO está provado' "$RUNBOOK"; _g=$?
[[ "$_g" -ne 0 ]] || fail "runbook still says hq is NOT proven"
[[ "$_g" -eq 1 ]] || fail "could not read the runbook to check for the stale 'hq NÃO está provado' claim (grep rc $_g)"
log "runbook has an hq rc 0 row with issues restored == expected (${nums% *}) and states the scope of the claim ✓"

log "PASS"
exit 0
