#!/usr/bin/env bash
# prod-tests/gascity/story-ga-gsnee8.sh — prod test for ga-gsnee8: dolt-backup-reseed.sh's
# low-disk modes could DELETE the only complete local staging of a database on a weak S3
# proof, and the ULTRA mode's disk arithmetic ignored the restore copy.
#
# What shipped, and what this test proves about each part:
#   1. The deletion proof is now dolt-backup-s3-proof.sh's manifest-closure proof
#      (_s3proof_repair_then_prove): the local backup is closed, the S3 backup is closed
#      (every table its manifest names exists in the bucket) and S3 already holds every
#      local file — repairing S3 first when it can. It used to be "the manifest OBJECT
#      exists" + a size ratio against the fingerprint, which said nothing about restoring
#      (hq, 2026-09-25: manifest present, one of its tables missing, 2.69 GB never uploaded).
#   2. The ULTRA mode counts the restore copy: after freeing the old backup the disk must
#      hold the new copy AND the verification restore (they coexist), not just the first.
#   3. The NORMAL low-disk mode no longer frees the old backup when freeing would not
#      make room for the restore.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-gsnee8). Exits 0 on pass. Asserts
# against the LIVE deployed tree ($CITY/scripts — gascity's scripts run in place, so
# "deployed" means present on disk there).
#
# NOT asserted here, on purpose: hq's LIVE S3 state (whether it restores today). That is
# ga-btnq6h's story and moves with the nightly; this story is about what the reseed does
# WHEN the S3 proof does or does not hold, which the deployed selftest exercises end to end
# against a fake bucket that replicates the hq incident. No live aws call is made here.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"

log()  { echo "[prod-test:gascity ga-gsnee8] $*"; }
fail() { echo "[prod-test:gascity ga-gsnee8] FAIL: $*" >&2; exit 1; }

# macOS /bin/bash is 3.2 and is what the launchd jobs and the gate use; Homebrew bash 5
# accepts syntax 3.2 rejects, so check with the interpreter that actually runs these.
BASH32=/bin/bash
[[ -x "$BASH32" ]] || fail "$BASH32 not found — cannot syntax-check under the interpreter the jobs run with"

RESEED="$SCRIPTS/dolt-backup-reseed.sh"
PROOF="$SCRIPTS/dolt-backup-s3-proof.sh"
NIGHTLY="$SCRIPTS/dolt-s3-backup.sh"

# ── 1. The deployed files exist and parse under bash 3.2 ─────────────────────────────
# The proof lib is a hard dependency: if ga-btnq6h's lib is not deployed, the reseed would
# source a missing file and every reseed would die — a present reseed is not a working one.
for f in "$RESEED" "$PROOF" "$NIGHTLY"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f (the merge did not reach the running tree)"
  "$BASH32" -n "$f" 2>/dev/null || fail "$f does not parse under $BASH32 (3.2) — the launchd job would die on start"
done
log "reseed, proof lib and nightly backup are deployed and parse under bash 3.2"

# ── 2. The fix is WIRED into the deletion path, not just present ─────────────────────
# A defined-but-never-called function is the classic dormant fix.
grep -q '^\. .*dolt-backup-s3-proof\.sh"' "$RESEED" \
  || fail "deployed reseed never sources dolt-backup-s3-proof.sh — _s3proof_repair_then_prove would be undefined"
grep -qF '_s3proof_repair_then_prove "$local_dir" "$db"' "$RESEED" \
  || fail "deployed reseed's _s3_current_backup_verified does not call _s3proof_repair_then_prove"
if grep -qF 's3api head-object' "$RESEED"; then
  fail "deployed reseed still contains the weak head-object proof (an object's existence says nothing about restoring)"
fi
n_verify="$(grep -c '_s3_current_backup_verified "\$DB" "\$BACKUP_DIR"' "$RESEED")"
n_rm="$(grep -c 'rm -rf "\$BACKUP_DIR"' "$RESEED")"
[[ "$n_verify" == "2" && "$n_rm" == "2" ]] \
  || fail "deployed reseed has $n_rm early-deletion site(s) and $n_verify proof call site(s) (want 2 and 2) — a deletion path may lack its proof"
grep -q 'ULTRA_NEED_KB' "$RESEED" \
  || fail "deployed reseed's ULTRA mode does not compute the two-copy requirement (ULTRA_NEED_KB missing)"
grep -q 'disco insuficiente para a verificação mesmo liberando o backup antigo' "$RESEED" \
  || fail "deployed reseed lost the normal low-disk mode's 'freeing would not make room' refusal"
log "the manifest-closure proof gates both early-deletion sites; ULTRA counts new copy + restore copy; low-disk refuses a useless deletion"

# ── 3. The classifiers the nightly uses still recognise what the reseed now says ─────
# The proof-failed / lost-backup / margin refusals are routed by SUBSTRING match on the
# reseed's own die() text; rewording one silently reroutes an alarm into a quiet skip.
grep -qF '*"prova do S3 FALHOU"*' "$NIGHTLY" || fail "deployed dolt-s3-backup.sh lost the 'prova do S3 FALHOU' classifier"
grep -q 'prova do S3 FALHOU' "$RESEED" || fail "deployed reseed no longer emits 'prova do S3 FALHOU' — the proof-failed alarm would never fire"
grep -q 'disco insuficiente' "$RESEED" || fail "deployed reseed no longer emits 'disco insuficiente' — the margin-refusal streak would never count"
log "reseed's refusal texts still match the nightly's classifiers"

# ── 4. The regression suites pass against the LIVE tree ──────────────────────────────
run_suite() {  # run_suite <script-basename>
  local name="$1" out
  [[ -f "$SCRIPTS/$name" ]] || fail "deployed selftest missing: $SCRIPTS/$name"
  log "running $name against the live tree ..."
  out="$("$BASH32" "$SCRIPTS/$name" 2>&1)" || { echo "$out" | tail -40 >&2; fail "$name failed against the live tree"; }
  printf '%s\n' "$out" | grep -Eq 'RESULT: PASS=[0-9]+ FAIL=0( ===)?$' \
    || fail "$name did not report a clean FAIL=0 result: $(printf '%s\n' "$out" | tail -3)"
  log "  $(printf '%s\n' "$out" | grep -E 'RESULT: PASS=' | tail -1)"
}
run_suite dolt-backup-reseed.selftest.sh
run_suite dolt-backup-s3-proof.selftest.sh
run_suite dolt-s3-backup.selftest.sh

log "info: kill switches — RESEED_ALLOW_LOW_DISK=0 disables both low-disk modes; RESEED_S3PROOF_UP_TIMEOUT_SECS / RESEED_S3PROOF_TIMEOUT_SECS / RESEED_S3PROOF_REPAIR_ROUNDS bound the proof (defaults 600s upload / 120s read-only / 1 repair round); RESEED_RESTORE_COPY_PCT sizes the restore copy in the ULTRA arithmetic (default 100)"
log "PASS — the low-disk modes free the old backup only on a manifest-closure proof of S3 and only when freeing makes room for the restore; deployed, wired and tested against the live tree"
exit 0
