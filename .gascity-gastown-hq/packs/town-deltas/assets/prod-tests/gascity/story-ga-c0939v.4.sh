#!/usr/bin/env bash
# prod-tests/gascity/story-ga-c0939v.4.sh — prod test for ga-c0939v.4 (slice 4/4 of ga-c0939v): the DEPLOYED jsonl-hourly-restore.sh
# restores a dump with the DEPLOYED, REAL `bd` and the accounts close.
#
# Smoke only: a synthetic dump of 3 issues (one label, one dependency, one comment) goes through the whole chain — convert, throwaway
# embedded store, `bd import`, `bd export`, reconcile. It proves the deployed script + helper + bd work TOGETHER on this host today.
# It does NOT replace the real round (hq / whatsapp_automation / gastown against the latest S3 snapshot, minutes and GBs): the numbers
# of that round live in docs/runbooks/jsonl-hourly-offsite.md ("Provar o restore").
#
# Estados (nunca dois): ok / fail / unproven. rc 2 do restore (sem bd, pouco disco, estourou o tempo) NUNCA vira PASS limpo nem FAIL:
#   é "unproven" (sem veredito). rc 1 (não reproduz) é FAIL.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SDIR="$CITY/packs/town-deltas/assets/scripts"
SCRIPT="$SDIR/jsonl-hourly-restore.sh"
HELPER="$SDIR/jsonl_hourly_restore.py"
LIMIT="${JHR_PROD_TEST_TIMEOUT:-420}"

log()  { echo "[prod-test:gascity ga-c0939v.4] $*"; }
fail() { echo "[prod-test:gascity ga-c0939v.4] FAIL: $*" >&2; exit 1; }
_TO=""; for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _TO="$_t"; break; }; done
UNPROVEN=""; UNPROVEN_N=0
_unproven() { UNPROVEN_N=$((UNPROVEN_N + 1)); UNPROVEN="${UNPROVEN:+$UNPROVEN; }$1"; }

# ── 1. deployed artifacts exist and are the restore-module version ────────────
for f in "$SCRIPT" "$HELPER" "$SDIR/jsonl_hourly.py"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f"
done
[[ -x "$SCRIPT" ]] || fail "deployed script not executable: $SCRIPT"
grep -q 'jsonl_hourly_restore\.py' "$SCRIPT" || fail "deployed restore script does not call jsonl_hourly_restore.py — the wip version (helper without convert/reconcile) is live"
"$SCRIPT" --help >/dev/null 2>&1 || fail "$SCRIPT --help failed"
log "script and helper deployed ✓"

# ── 2. smoke: tiny dump -> real bd -> accounts ────────────────────────────────
[[ -n "$_TO" ]] || { _unproven "no timeout/gtimeout on this host: the smoke restore is not run unbounded"; log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; exit 0; }
command -v bd >/dev/null 2>&1 || { _unproven "bd not on PATH: the real restore chain was not exercised"; log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ga-c0939v4.XXXXXX")" || fail "mktemp"
case "$T" in */ga-c0939v4.*) ;; *) fail "mktemp returned a strange path: $T" ;; esac
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/dump/smoke" "$T/tmp"
python3 -I - "$T/dump/smoke" <<'PYEOF' || fail "could not write the synthetic dump"
import json, os, sys
d = sys.argv[1]
ts = "2026-10-01 00:00:00"
def put(name, rows):
    open(os.path.join(d, name + ".jsonl"), "w").write(json.dumps({"rows": rows}) if rows else "{}")
put("issues", [{"id": "sm-%d" % n, "title": "t%d" % n, "description": "d", "status": st, "priority": "2", "issue_type": "task",
                "created_at": ts, "updated_at": ts} for n, st in ((1, "open"), (2, "closed"), (3, "in_progress"))])
put("labels", [{"issue_id": "sm-1", "label": "smoke"}])
put("dependencies", [{"issue_id": "sm-2", "depends_on_id": "sm-1", "type": "blocks", "created_at": ts, "created_by": "t"}])
put("comments", [{"id": "c1", "issue_id": "sm-1", "author": "t", "text": "oi", "created_at": ts}])
put("config", [{"key": "issue_prefix", "value": "sm"}])
put("metadata", [])
PYEOF

out="$(TMPDIR="$T/tmp" "$_TO" "$LIMIT" nice -n 10 "$SCRIPT" --db smoke --dump "$T/dump" --min-free-mb 1024 2>"$T/err")"; rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
case "$rc" in
  0) case "$out" in *"RESULT: OK db=smoke"*"issues=3/3"*"labels=1/1"*"dependencies=1/1"*"comments=1/1"*) log "restore with the real bd: accounts close (3 issues, 1 label, 1 dependency, 1 comment) ✓" ;;
       *) fail "restore rc 0 but the RESULT line does not show the expected counts" ;; esac ;;
  1) fail "restore did NOT reproduce the synthetic dump with the real bd: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
  2|124) why="$(printf '%s\n' "$out" | sed -n 's/^RESULT: UNKNOWN //p' | head -1 | head -c 300)"   # vazio (rc 124: o timeout externo matou antes da linha RESULT) → última linha do log
         _unproven "smoke restore had no verdict (rc=$rc: ${why:-$(tail -1 "$T/err" 2>/dev/null | head -c 200)})" ;;
  *) fail "restore exited $rc (unexpected): $(tail -2 "$T/err" 2>/dev/null | tr '\n' ' ')" ;;
esac
log "NOTE: smoke only. The round against the real S3 snapshot is in docs/runbooks/jsonl-hourly-offsite.md (Provar o restore)"

if [[ "$UNPROVEN_N" -gt 0 ]]; then log "PASS ($UNPROVEN_N unproven: $UNPROVEN)"; else log "PASS"; fi
exit 0
