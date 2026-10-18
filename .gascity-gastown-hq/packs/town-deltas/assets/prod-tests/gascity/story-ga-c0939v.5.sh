#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.5.sh — prod test for ga-c0939v.5 (slice 5 of ga-c0939v): the restore of the biggest database (hq)
# has a MEASURED verdict recorded in the runbook, and the restore chain that produced it is complete on this host.
#
# Read-only: nothing is restored, nothing is read from S3. The restore itself (minutes, GBs, the MBP) is not repeated here; this checks
# that the deployed chain is whole (script + helper + the module the helper imports) and that the deployed runbook says what was measured.
#
# Estados (nunca dois): ok / fail / unproven. Runbook ausente no checkout implantado é FAIL (mergeado não é implantado).
# "Unproven" só cobre o que ESTE host não consegue exercitar (hoje: o helper não roda sem python3). Ele é contado e o teste SEGUE: a seção 2
# (o runbook) não depende de python3 e roda sempre, então um runbook ausente ou velho reprova com ou sem python3. O PASS final diz
# quantos itens ficaram sem prova e quais.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SDIR="$CITY/packs/town-deltas/assets/scripts"
RUNBOOK="$CITY/docs/runbooks/jsonl-hourly-offsite.md"

log()  { echo "[prod-test:gascity ga-c0939v.5] $*"; }
fail() { echo "[prod-test:gascity ga-c0939v.5] FAIL: $*" >&2; exit 1; }
UNPROVEN=""; UNPROVEN_N=0
_unproven() { UNPROVEN_N=$((UNPROVEN_N + 1)); UNPROVEN="${UNPROVEN:+$UNPROVEN; }$1"; }

# ── 1. the restore chain is complete on this host ────────────────────────────
# The 18/10 hq round died in 0 s because jsonl_hourly.py (imported by the helper) was not shipped with it: all three files, and the import itself.
for f in jsonl-hourly-restore.sh jsonl_hourly_restore.py jsonl_hourly.py; do
  [[ -f "$SDIR/$f" ]] || fail "deployed file missing: $SDIR/$f"
done
[[ -x "$SDIR/jsonl-hourly-restore.sh" ]] || fail "deployed restore script not executable"
# vazio (python3 fora do PATH) → conta como unproven e SEGUE para a seção 2, que não precisa dele; falhou (python3 existe e o helper não sobe) → FAIL com a ÚLTIMA linha do stderr
# (num traceback do Python a 1ª linha é só "Traceback (most recent call last):"; a mensagem da exceção é a última)
if command -v python3 >/dev/null 2>&1; then
  helper_err="$(python3 -I "$SDIR/jsonl_hourly_restore.py" --help 2>&1 >/dev/null)"; helper_rc=$?
  [[ "$helper_rc" -eq 0 ]] || fail "the deployed helper does not start (python3 -I jsonl_hourly_restore.py --help, rc $helper_rc): ${helper_err##*$'\n'}"
  log "restore script, helper and the module it imports are deployed, and the helper starts ✓"
else
  _unproven "python3 not on PATH: the helper import was not exercised (files present, but whether the helper starts is not known)"
fi

# ── 2. the deployed runbook records the hq verdict ───────────────────────────
# ausente → FAIL "missing"; existe mas não dá para ler → FAIL "not readable" (nunca confundido com "sem linha do hq", e nunca PASS)
[[ -f "$RUNBOOK" ]] || fail "deployed runbook missing: $RUNBOOK"
[[ -r "$RUNBOOK" ]] || fail "deployed runbook exists but is not readable: $RUNBOOK"
# vazio → sem a linha do hq = FAIL (não mediram / não implantou); ilegível → já barrado acima, e se o grep ainda der rc 2 cai no mesmo FAIL, nunca em PASS
row="$(grep -E '^\| hq \| 0 \| [0-9]+/[0-9]+ \|' "$RUNBOOK" | head -1)"
[[ -n "$row" ]] || fail "runbook has no 'hq | 0' measured row (the hq restore has no recorded verdict)"
# vazio → o sed não casa e devolve a linha inteira, que reprova no teste numérico abaixo; falhou → idem (nunca vira "0 0")
nums="$(printf '%s' "$row" | sed -E 's/^\| hq \| 0 \| ([0-9]+)\/([0-9]+) \|.*/\1 \2/')"
iss_ok="${nums% *}"; iss_exp="${nums#* }"
[[ "$iss_ok" =~ ^[0-9]+$ && "$iss_exp" =~ ^[0-9]+$ ]] || fail "the hq row's issues cell is not 'restored/expected' numbers: '${nums}'"
(( 10#$iss_ok == 10#$iss_exp )) || fail "the hq row's issues cell is not restored == expected: ${iss_ok}/${iss_exp}"
(( 10#$iss_ok > 0 )) || fail "the hq row has 0 issues restored: zero is not a measured verdict"
# Acoplado à AFIRMAÇÃO (a frase "Restore provado" nomeia o hq), não às datas nem ao resto da prosa: uma nova rodada que mude as datas não quebra o teste.
# três estados: rc 0 = a frase nomeia o hq (segue) · rc 1 = não nomeia (FAIL) · rc >= 2 = não consegui ler (FAIL, nunca "não nomeia")
grep -Eq 'Restore provado.*[^a-z_]hq[^a-z_]' "$RUNBOOK"; _g=$?
[[ "$_g" -ne 1 ]] || fail "runbook does not state that the 'Restore provado' claim now covers hq"
[[ "$_g" -eq 0 ]] || fail "could not read the runbook to check the 'Restore provado' scope claim (grep rc $_g)"
# três estados: rc 0 = ainda diz "NÃO provado" (FAIL) · rc 1 = não diz (segue) · rc >= 2 = não consegui ler (FAIL, nunca "não diz")
grep -q '\*\*hq NÃO está provado' "$RUNBOOK"; _g=$?
[[ "$_g" -ne 0 ]] || fail "runbook still says hq is NOT proven"
[[ "$_g" -eq 1 ]] || fail "could not read the runbook to check for the stale 'hq NÃO está provado' claim (grep rc $_g)"
log "runbook has an hq rc 0 row with issues restored == expected (${iss_ok}) and states the scope of the claim ✓"

if [[ "$UNPROVEN_N" -gt 0 ]]; then log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; else log "PASS"; fi
exit 0
