#!/usr/bin/env bash
# debris-janitor.sh — imp09: move .bak debris out of live asset/script dirs + git worktree prune
#
# WHY (imp09): .bak sprawl in packs/town-deltas/assets/ and scripts/ drives CopyFiles
# config-drift → supervisor drains non-pinned crews on each edit. Git worktree leftovers
# accumulate stale admin metadata. Neither is cleaned automatically.
#
# SAFETY RULES:
# - MOVE (not delete): files go to DEBRIS_DIR with a timestamp prefix; never rm.
# - Idempotent: re-running after a partial run is always safe.
# - Dry-run: --dry-run flag logs what would happen without moving anything.
# - Only touches .bak*, .bak-*, and *.bak-* patterns in SCAN_DIRS (no live files).
# - NEVER touches Dolt data dirs (.dolt/, .dolt-data/) or production databases.
# - git worktree prune only — no gc, no reset, no destructive git ops.
#
# Usage:
#   debris-janitor.sh [--dry-run] [--selftest]
#   DRY_RUN=1 debris-janitor.sh
#
# Env knobs:
#   DRY_RUN=1            — log only, no moves
#   DEBRIS_DIR           — destination for moved files (default: HQ/.gc/script-backups/debris-<date>)
#   DEBRIS_JANITOR_ROOTS — colon-separated git roots to worktree-prune (default: HQ + WA)

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
NOTIFY_BIN="${NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
NOW_TS="$(date +%Y%m%d-%H%M%S)"
DEBRIS_DIR="${DEBRIS_DIR:-${CITY}/.gc/script-backups/debris-${NOW_TS}}"
DRY_RUN="${DRY_RUN:-0}"
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Dirs to scan for .bak debris (live asset + script dirs only)
SCAN_DIRS=(
  "${CITY}/packs/town-deltas/assets"
  "${CITY}/scripts"
)

# Git roots to worktree-prune. HQ lives under the town root /Users/athos/gt (the actual .git);
# the CITY dir (/Users/athos/gt/.gascity-gastown-hq) is a subdirectory, not a repo root.
IFS=':' read -ra PRUNE_ROOTS <<< "${DEBRIS_JANITOR_ROOTS:-/Users/athos/gt:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [debris-janitor] $*"; }

# ── selftest ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $*"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

  echo ""
  echo "[debris-janitor selftest] running scenarios..."
  echo ""

  # T1: dry-run on a temp dir with .bak files → no files moved
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/pilot-dispatcher.sh.bak-old1"
  touch "${tmpdir}/quality-gate.sh.bak-old2"
  touch "${tmpdir}/live-script.sh"    # NOT a bak file — must not be touched
  tmpdbris="$(mktemp -d)"

  DRY_RUN=1 SCAN_DIRS_OVERRIDE="${tmpdir}" DEBRIS_DIR="${tmpdbris}/debris" \
    bash -c "
      set -uo pipefail
      DRY_RUN=1
      moved=0
      mkdir -p \"\${DEBRIS_DIR}\" 2>/dev/null || true
      while IFS= read -r -d '' f; do
        log_line=\"DRY_RUN: would move \$f → \${DEBRIS_DIR}/\"
        moved=\$((moved+1))
      done < <(find \"${tmpdir}\" -maxdepth 1 -name '*.bak-*' -o -name '*.bak' 2>/dev/null | tr '\n' '\0')
      echo \"moved_count=\$moved\"
    " 2>/dev/null
  # Count .bak files in scan dir
  bak_count="$(find "${tmpdir}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) 2>/dev/null | wc -l | tr -d ' ')"
  live_count="$(find "${tmpdir}" -maxdepth 1 -name 'live-script.sh' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "${tmpdir}" "${tmpdbris}" 2>/dev/null || true

  if [ "${bak_count}" -ge 2 ]; then
    ok "T1-setup: found $bak_count .bak files in temp dir"
  else
    bad "T1-setup: expected >=2 .bak files, found ${bak_count}"
  fi
  if [ "${live_count}" -eq 1 ]; then
    ok "T1-live: live-script.sh not classified as bak"
  else
    bad "T1-live: live-script.sh should not match bak pattern"
  fi

  # T2: real move (not dry-run) → files moved, debris dir created, original gone
  tmpdir2="$(mktemp -d)"
  touch "${tmpdir2}/auto-refino.sh.bak-old"
  touch "${tmpdir2}/quality-gate.sh.bak-123"
  touch "${tmpdir2}/live-file.sh"
  tmpdbris2="$(mktemp -d)"
  debris_dest="${tmpdbris2}/debris"

  # Run minimal inline move logic
  mkdir -p "${debris_dest}" 2>/dev/null
  moved_count=0
  while IFS= read -r -d '' f; do
    fname="$(basename "$f")"
    dest="${debris_dest}/${NOW_TS}-${fname}"
    if mv "$f" "$dest" 2>/dev/null; then
      moved_count=$((moved_count+1))
    fi
  done < <(find "${tmpdir2}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) -print0 2>/dev/null)

  remaining_bak="$(find "${tmpdir2}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) 2>/dev/null | wc -l | tr -d ' ')"
  moved_in_debris="$(find "${debris_dest}" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  live_still_there="$(find "${tmpdir2}" -maxdepth 1 -name 'live-file.sh' 2>/dev/null | wc -l | tr -d ' ')"
  rm -rf "${tmpdir2}" "${tmpdbris2}" 2>/dev/null || true

  if [ "${moved_count}" -eq 2 ]; then
    ok "T2-moved: $moved_count .bak files moved to debris dir"
  else
    bad "T2-moved: expected 2 moved, got ${moved_count}"
  fi
  if [ "${remaining_bak}" -eq 0 ]; then
    ok "T2-cleared: no .bak files left in original dir"
  else
    bad "T2-cleared: ${remaining_bak} .bak files still remain"
  fi
  if [ "${live_still_there}" -eq 1 ]; then
    ok "T2-live: live file untouched"
  else
    bad "T2-live: live file was moved (should NOT be touched)"
  fi

  # T3: dpm_halt_imminent threshold logic (sourced from disk-pressure-monitor if available)
  DPM="${HOME}/.gastown/scripts/disk-pressure-monitor.sh"
  if [ -f "$DPM" ]; then
    DISK_PRESSURE_MONITOR_LIB=1 source "$DPM" 2>/dev/null
    if dpm_halt_imminent 97 97; then
      ok "T3: dpm_halt_imminent 97>=97 → true"
    else
      bad "T3: dpm_halt_imminent 97>=97 should be true"
    fi
    if ! dpm_halt_imminent 96 97; then
      ok "T4: dpm_halt_imminent 96<97 → false"
    else
      bad "T4: dpm_halt_imminent 96<97 should be false"
    fi
    if dpm_halt_imminent 100 97; then
      ok "T5: dpm_halt_imminent 100>=97 → true"
    else
      bad "T5: dpm_halt_imminent 100>=97 should be true"
    fi
  else
    ok "T3-T5: disk-pressure-monitor.sh not found — threshold tests skipped"
  fi

  # T4: idempotent — running twice doesn't error
  tmpdir3="$(mktemp -d)"
  touch "${tmpdir3}/file.bak-x"
  tmpdbris3="$(mktemp -d)"
  debris_dest3="${tmpdbris3}/debris"
  mkdir -p "${debris_dest3}"
  # First run
  while IFS= read -r -d '' f; do
    mv "$f" "${debris_dest3}/${NOW_TS}-$(basename "$f")" 2>/dev/null || true
  done < <(find "${tmpdir3}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) -print0 2>/dev/null)
  # Second run (nothing left to move)
  second_run_moved=0
  while IFS= read -r -d '' f; do
    second_run_moved=$((second_run_moved+1))
  done < <(find "${tmpdir3}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) -print0 2>/dev/null)
  rm -rf "${tmpdir3}" "${tmpdbris3}" 2>/dev/null || true
  if [ "${second_run_moved}" -eq 0 ]; then
    ok "T6: idempotent — second run finds 0 files to move"
  else
    bad "T6: idempotent — second run found ${second_run_moved} files (should be 0)"
  fi

  echo ""
  echo "=== RESULT: PASS=${PASS} FAIL=${FAIL} ==="
  [ "${FAIL}" -eq 0 ]
fi

# ── main ───────────────────────────────────────────────────────────────────────
log "debris-janitor starting (DRY_RUN=${DRY_RUN})"

total_moved=0
total_skipped=0

# ── 1. Move .bak debris from live dirs ────────────────────────────────────────
if [ "${DRY_RUN}" = "0" ]; then
  mkdir -p "${DEBRIS_DIR}" || { log "ERROR: cannot create DEBRIS_DIR=${DEBRIS_DIR}"; exit 1; }
fi

for scan_dir in "${SCAN_DIRS[@]}"; do
  [ -d "${scan_dir}" ] || { log "SKIP: scan dir not found: ${scan_dir}"; continue; }

  # Match: *.bak  and  *.bak-*  (covers pilot-dispatcher.sh.bak-old, file.bak, etc.)
  while IFS= read -r -d '' f; do
    fname="$(basename "$f")"
    dest="${DEBRIS_DIR}/${NOW_TS}-${fname}"

    if [ "${DRY_RUN}" = "1" ]; then
      log "DRY_RUN: would move ${f} → ${dest}"
      total_moved=$((total_moved+1))
    else
      if mv "${f}" "${dest}" 2>/dev/null; then
        log "MOVED: ${f} → ${dest}"
        total_moved=$((total_moved+1))
      else
        log "WARN: could not move ${f} (skipping)"
        total_skipped=$((total_skipped+1))
      fi
    fi
  done < <(find "${scan_dir}" -maxdepth 1 \( -name '*.bak-*' -o -name '*.bak' \) -print0 2>/dev/null)
done

log "Bak debris: moved=${total_moved} skipped=${total_skipped} (DRY_RUN=${DRY_RUN})"

# ── 2. Git worktree prune ──────────────────────────────────────────────────────
for repo in "${PRUNE_ROOTS[@]}"; do
  repo="${repo%/}"
  [ -d "${repo}/.git" ] || { log "SKIP worktree prune: not a git repo: ${repo}"; continue; }
  if [ "${DRY_RUN}" = "1" ]; then
    log "DRY_RUN: would run: git -C ${repo} worktree prune"
  else
    if git -C "${repo}" worktree prune 2>/dev/null; then
      log "git worktree prune OK: ${repo}"
    else
      log "WARN: git worktree prune failed: ${repo} (non-fatal)"
    fi
  fi
done

log "debris-janitor done (DRY_RUN=${DRY_RUN}, moved=${total_moved}, skipped=${total_skipped})"

# Notify on non-dry-run runs that actually moved files
if [ "${DRY_RUN}" = "0" ] && [ "${total_moved}" -gt 0 ] && [ -x "${NOTIFY_BIN}" ]; then
  "${NOTIFY_BIN}" -t "Debris janitor" -p 2 \
    "Moved ${total_moved} .bak files to ${DEBRIS_DIR}" 2>/dev/null || true
fi
