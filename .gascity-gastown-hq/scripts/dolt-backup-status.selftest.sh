#!/bin/bash
# dolt-backup-status.selftest.sh — unit tests for dolt-backup-status.sh
# (ga-odtd3f). Hermetic: sources the script as a LIBRARY
# (DOLT_BACKUP_STATUS_LIB=1) so the live report/exit-code flow never runs
# against a real BACKUP_ROOT. Every scenario below builds its own scratch
# .dolt-backup-shaped directory tree; the real one is NEVER touched or read.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-backup-status.sh"

export DOLT_BACKUP_STATUS_LIB=1
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-backup-status.selftest.sh ==="

for fn in _status_age_human _status_one_copy _status_kb_human _status_report_db; do
  type "$fn" >/dev/null 2>&1 && ok "$fn defined by lib-mode source" \
    || { bad "$fn NOT defined — lib mode broken"; echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="; exit 1; }
done

# ── _status_age_human() — pure formatting ────────────────────────────────────
echo "── _status_age_human() ──"
[ "$(_status_age_human 90)" = "1m" ] && ok "90s -> 1m" || bad "90s -> $(_status_age_human 90), expected 1m"
[ "$(_status_age_human 3661)" = "1h1m" ] && ok "3661s -> 1h1m" || bad "3661s -> $(_status_age_human 3661), expected 1h1m"
[ "$(_status_age_human 90000)" = "1d1h" ] && ok "90000s -> 1d1h" || bad "90000s -> $(_status_age_human 90000), expected 1d1h"
[ "$(_status_age_human "")" = "?" ] && ok "empty seconds -> ? (fail-closed formatting, never a fake 0m)" || bad "empty seconds did not format as ?"
[ "$(_status_age_human "x")" = "?" ] && ok "non-numeric seconds -> ?" || bad "non-numeric seconds did not format as ?"

# ── _status_kb_human() — pure formatting ─────────────────────────────────────
echo "── _status_kb_human() ──"
[ "$(_status_kb_human 512)" = "512K" ] && ok "512KB shown exactly (sub-1MB never rounds to a misleading 0M)" || bad "512KB -> $(_status_kb_human 512), expected 512K"
[ "$(_status_kb_human 2097152)" = "2.0G" ] && ok "2097152KB -> 2.0G" || bad "2097152KB -> $(_status_kb_human 2097152), expected 2.0G"
[ "$(_status_kb_human "")" = "?" ] && ok "empty KB -> ?" || bad "empty KB did not format as ?"

# ── _status_one_copy() — manifest presence is the ONLY validity signal ──────
echo "── _status_one_copy() ──"
SOC_ROOT="$(mktemp -d)"

mkdir -p "$SOC_ROOT/good"; touch "$SOC_ROOT/good/manifest"; dd if=/dev/zero of="$SOC_ROOT/good/data" bs=1024 count=100 2>/dev/null
line="$(_status_one_copy "$SOC_ROOT/good")"
IFS="$(printf '\t')" read -r size mtime manifest <<< "$line"
[ "$manifest" = "OK" ] && ok "dir with manifest -> OK" || bad "dir with manifest -> '$manifest', expected OK"
[ -n "$size" ] && ok "size measured for existing dir" || bad "size not measured for existing dir"

mkdir -p "$SOC_ROOT/broken"; dd if=/dev/zero of="$SOC_ROOT/broken/data" bs=1024 count=100 2>/dev/null
line="$(_status_one_copy "$SOC_ROOT/broken")"
IFS="$(printf '\t')" read -r size mtime manifest <<< "$line"
[ "$manifest" = "AUSENTE" ] && ok "large recent dir WITHOUT manifest -> AUSENTE (size/mtime never substitute for the manifest check)" \
  || bad "dir without manifest -> '$manifest', expected AUSENTE"

line="$(_status_one_copy "$SOC_ROOT/does-not-exist")"
# shellcheck disable=SC2034  # size/mtime deliberately unused here — only manifest matters for this assertion
IFS="$(printf '\t')" read -r size mtime manifest <<< "$line"
[ -z "$manifest" ] && ok "nonexistent dir -> empty manifest field (not AUSENTE, not OK — a third 'not present at all' state)" \
  || bad "nonexistent dir -> '$manifest', expected empty"

rm -rf "$SOC_ROOT"

# ── _status_report_db() — the real ga-odtd3f scenario, reconstructed ────────
echo "── _status_report_db() (ga-odtd3f incident reconstruction) ──"
SRD_ROOT="$(mktemp -d)"
# shellcheck disable=SC2034  # read by _status_report_db (sourced file), not visibly within this one
BACKUP_ROOT="$SRD_ROOT"

# Scenario A: healthy primary, no residue.
mkdir -p "$SRD_ROOT/healthy"; touch "$SRD_ROOT/healthy/manifest"
out="$(_status_report_db "healthy")"; rc=$?
[ "$rc" -eq 0 ] && ok "scenario A (healthy primary): rc=0" || bad "scenario A: rc=$rc, expected 0"
printf '%s' "$out" | grep -qF "MANIFEST=OK" && ok "scenario A: reports MANIFEST=OK" || bad "scenario A: missing MANIFEST=OK"
printf '%s' "$out" | grep -q "residuo\|RESIDUO" && bad "scenario A: should not mention residue at all" || ok "scenario A: no residue mentioned (none exists)"

# Scenario B (the actual incident): primary broken (no manifest), .new is
# the real one (has manifest) — must name PRIMARY invalid, must point at
# .new as the one that works, must return rc=1.
mkdir -p "$SRD_ROOT/hq" "$SRD_ROOT/hq.new"
touch "$SRD_ROOT/hq.new/manifest"   # hq/ deliberately has NO manifest
out="$(_status_report_db "hq")"; rc=$?
[ "$rc" -eq 1 ] && ok "scenario B (ga-odtd3f reconstruction): rc=1 (primary invalid)" || bad "scenario B: rc=$rc, expected 1"
printf '%s' "$out" | grep -qF "MANIFEST=AUSENTE" && ok "scenario B: primary reported AUSENTE" || bad "scenario B: primary not reported AUSENTE"
printf '%s' "$out" | grep -qF "NAO E UM BACKUP VALIDO" && ok "scenario B: primary explicitly called out as not a valid backup" || bad "scenario B: missing explicit invalid-backup wording"
printf '%s' "$out" | grep -qF "ESTE presta, o PRIMARY acima nao" && ok "scenario B: .new is explicitly pointed to as the one that works" || bad "scenario B: missing the 'this one is good' pointer to .new"
printf '%s' "$out" | grep -qF "troca INCOMPLETA" && ok "scenario B: .new residue explained as an incomplete swap" || bad "scenario B: missing incomplete-swap explanation"
rm -rf "$SRD_ROOT/hq" "$SRD_ROOT/hq.new"

# Scenario C: healthy primary with ROUTINE .old residue (normal post-reseed
# state — reseed never auto-deletes .old). Must NOT fire the strong .new-style
# warning, must NOT fail rc, and must describe it as normal/expected.
mkdir -p "$SRD_ROOT/rotated" "$SRD_ROOT/rotated.old"
touch "$SRD_ROOT/rotated/manifest" "$SRD_ROOT/rotated.old/manifest"
out="$(_status_report_db "rotated")"; rc=$?
[ "$rc" -eq 0 ] && ok "scenario C (routine .old residue): rc=0 — this is normal, not a failure" || bad "scenario C: rc=$rc, expected 0"
printf '%s' "$out" | grep -qF "normal" && ok "scenario C: .old residue is described as normal/expected" || bad "scenario C: .old residue not described as normal"
printf '%s' "$out" | grep -q "troca INCOMPLETA" && bad "scenario C: must NOT fire the .new-style incomplete-swap warning for routine .old" || ok "scenario C: incomplete-swap warning correctly not fired for routine .old"
rm -rf "$SRD_ROOT/rotated" "$SRD_ROOT/rotated.old"

# Scenario D: primary missing entirely (never backed up, or fully lost).
out="$(_status_report_db "nonexistent-db")"; rc=$?
[ "$rc" -eq 1 ] && ok "scenario D (primary missing entirely): rc=1" || bad "scenario D: rc=$rc, expected 1"
printf '%s' "$out" | grep -qF "PRIMARY ausente" && ok "scenario D: reports PRIMARY ausente (a third state, distinct from AUSENTE-manifest)" || bad "scenario D: missing 'PRIMARY ausente' wording"

rm -rf "$SRD_ROOT"

# ── drift-guard: db discovery skips .new/.old as top-level entries ──────────
echo "── drift-guard: live script wiring ──"
if grep -qE '\*\.new\|\*\.old\)' "$SCRIPT"; then
  ok "discovery loop excludes *.new/*.old suffixed dirs from being treated as separate databases"
else
  bad "discovery loop does not exclude .new/.old — every stuck .new would be double-counted as its own 'db'"
fi
if grep -qF 'exit "$overall_rc"' "$SCRIPT"; then
  ok "script exits with the accumulated overall_rc (nonzero if any primary is invalid)"
else
  bad "script does not exit with overall_rc — a broken primary might not surface as a nonzero exit"
fi
if grep -qE '^set -uo pipefail' "$SCRIPT"; then
  ok "script has set -uo pipefail (same safety posture as every other script in this city)"
else
  bad "script missing set -uo pipefail"
fi
# Read-only invariant: this is a DIAGNOSTIC script, it must never delete,
# move, or write under .dolt-backup — that stays dolt-backup-residue-reclaim.sh's
# job. Strip comments first so this doesn't false-positive on prose
# describing that invariant (same technique dolt-s3-backup.selftest.sh uses).
if sed -E 's/#.*$//' "$SCRIPT" | grep -qE '\brm -rf|\bmv \$|\bmv "\$'; then
  bad "found a delete/move outside comments — this script must stay read-only"
else
  ok "no delete/move anywhere in the script (read-only, as designed)"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
