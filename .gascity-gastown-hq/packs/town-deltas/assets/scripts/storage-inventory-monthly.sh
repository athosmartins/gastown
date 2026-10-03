#!/bin/bash
# storage-inventory-monthly.sh (ga-z297h) — lightweight monthly storage
# inventory. Reuses the measurement commands already listed in the Atlas
# Part 0 table (whatsapp_automation/docs/data_dictionary.md "Medir" column)
# for the vectors this story names: Mac mini disk + ~10 key directories, S3
# buckets (recursive --summarize), and Google Drive service-account quota
# (about.get storageQuota). Updates a delimited auto-generated block placed
# once right after the Part 0 table, and flags (⚠️) any vector whose value
# moved more than DEVIATION_PCT since the LAST recorded run — Part 0's own
# cells are hand-written prose, not machine-readable numbers, so "previous
# run's own recorded value" is the only real baseline available to diff
# against.
#
# WHAT EACH VECTOR MEASURES (ga-utr9qf — the first version measured the wrong
# proxy for two of them and reported ✅ on a critical state):
#   - Mac mini: the status is driven by the APFS container's FREE space (the
#     `df` Avail column, which equals diskutil's "Container Free Space" — the
#     exact number dolt-disk-floor-guard.sh reads), against that guard's own
#     floors (WARN 8 GB / CRITICAL 3 GB). "Used of the Data volume / total" is
#     NOT the free space: the container is shared with the VM/swap, system and
#     other volumes, so Data can read 84% while the container has 3 GB left.
#     The Data-volume "used" delta is still tracked, but as its own row.
#   - S3: `aws s3 ls --recursive --summarize` counts CURRENT object versions
#     only; noncurrent versions are billed too (measured 2026-10-01: 280 GB
#     reported vs ~1.9 TB billed). The billed total here = current + the sum of
#     noncurrent version sizes (`s3api list-object-versions`). It is a total
#     only when EVERY bucket was measured: if any bucket could not be, the S3
#     status is N/A (the run is not OK) and the recorded baseline is carried
#     forward unchanged — the sum over the survivors is shown, marked PARCIAL,
#     and never recorded or compared as if it were the total.
#
# MotherDuck: Part 0's row 6 names motherduck_invoice_usage_check.py as its
# "Medir" command, but that script measures COMPUTE hours only (the
# invoice/throttle metric) — it has no storage-bytes field, and row 6 itself
# calls storage "irrelevante" for MotherDuck with compute the real concern.
# This inventory reports that script's compute verdict (the one real,
# working measurement that exists) rather than inventing an unverified
# storage-bytes query against MotherDuck internals.
#
# SAFE-EDIT DESIGN: never rewrites Part 0's own hand-maintained table cells.
# Writes only inside a delimited block (storage-inventory:begin/end HTML
# comments) so a bug here can never corrupt content outside that block — the
# block's own heading and legend live inside the markers too (ga-hdab26). The
# one exception is a legacy migration: stale copies of that same generated
# heading/legend left directly above BEGIN by the old layout are removed on
# replace (see _update_doc_block; nothing else outside the markers is
# touched). The block's own embedded data comment is the script's ONLY
# state — no separate state file, so the doc stays self-contained and
# portable. First run (no markers yet) inserts the block right before the
# unique "## Parte 1: SQLite" heading; every later run replaces only the
# content between its own markers. If neither the markers nor that anchor
# heading exist (doc restructured), fails closed — logs and skips the doc
# write rather than guessing a new location.
#
# Read-only against everything except: (a) the delimited block in
# data_dictionary.md, committed+pushed narrowly (this file only, never -A),
# and (b) the one summary bead per run.
#
# TEST: bash storage-inventory-monthly.selftest.sh
# Library mode: STORAGE_INVENTORY_LIB=1 source storage-inventory-monthly.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
WA_ROOT="${WA_ROOT:-/Users/athos/gt/whatsapp_automation}"
DOC_PATH="${STORAGE_INVENTORY_DOC:-$WA_ROOT/docs/data_dictionary.md}"
LOG="${STORAGE_INVENTORY_LOG:-$CITY/.gc/logs/storage-inventory-monthly.log}"
BD_BIN="${BD_BIN:-bd}"
AWS_BIN="${AWS_BIN:-aws}"
DU_BIN="${DU_BIN:-du}"
DF_BIN="${DF_BIN:-df}"
SYSCTL_BIN="${SYSCTL_BIN:-sysctl}"
GIT_BIN="${GIT_BIN:-git}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DRIVE_CREDS_PATH="${DRIVE_CREDS_PATH:-$WA_ROOT/data/google_credentials.json}"
MOTHERDUCK_CHECK_SCRIPT="${MOTHERDUCK_CHECK_SCRIPT:-$WA_ROOT/scripts/motherduck_invoice_usage_check.py}"
DEVIATION_PCT="${STORAGE_INVENTORY_DEVIATION_PCT:-20}"
DATA_DIR="${STORAGE_INVENTORY_DATA_DIR:-/System/Volumes/Data}"
# Free-space floors, integer GB — same names and defaults as dolt-disk-floor-guard.sh
# (DOLT_DISK_FLOOR_WARN_GB=8 / DOLT_DISK_FLOOR_CRITICAL_GB=3) so this report and the
# guard never disagree about what "low" means.
FLOOR_WARN_GB="${STORAGE_INVENTORY_FLOOR_WARN_GB:-${DOLT_DISK_FLOOR_WARN_GB:-8}}"
FLOOR_CRITICAL_GB="${STORAGE_INVENTORY_FLOOR_CRITICAL_GB:-${DOLT_DISK_FLOOR_CRITICAL_GB:-3}}"
# list-object-versions pages through EVERY version (77k versions took 67s live,
# 2026-10-01), so it gets more headroom than the plain `s3 ls` call.
S3_VERSIONS_TIMEOUT="${STORAGE_INVENTORY_S3_VERSIONS_TIMEOUT:-900}"
NOTIFY="${NOTIFY:-/Users/athos/.local/bin/notify}"
BEGIN_MARK='<!-- storage-inventory:begin -->'
END_MARK='<!-- storage-inventory:end -->'
# The block's own heading + legend. main() builds them from these prefixes and
# _update_doc_block matches on the same prefixes to recognise stale copies
# left OUTSIDE the markers by the pre-ga-hdab26 layout — one source of truth,
# so the two can never drift apart.
HDR_PREFIX='### Última medição automatizada'
LEGEND_PREFIX='> Gerado por `storage-inventory-monthly.sh`'
ANCHOR_RE='^## Parte 1: SQLite'
SKIP_GIT="${STORAGE_INVENTORY_SKIP_GIT:-0}"

# ~10 key directories named in Part 0 row 1's "O que mora" column.
# path|label, one per line.
KEY_DIRS="${STORAGE_INVENTORY_KEY_DIRS:-/Users/athos/gt|~/gt (tudo)
/Users/athos/gt/.gascity-gastown-hq/.beads|HQ .beads (Dolt vivo)
/Users/athos/gt/.gascity-gastown-hq/.dolt-backup|HQ .dolt-backup (staging)
/Users/athos/gt/whatsapp_automation|whatsapp_automation
/Users/athos/gt/property_scrapers|property_scrapers
/Users/athos/shared/data|~/shared/data
/Users/athos/shared/data/contagem_lotes|shared/data/contagem_lotes
/Users/athos/shared/data/map_viewer|shared/data/map_viewer
/Users/athos/.claude|~/.claude
/Users/athos/Library/Caches|~/Library/Caches}"

# S3 buckets — exact names confirmed live via `aws s3 ls` (2026-08-26); Part
# 0's own prose used shortened forms ("classifier-calls", "urblink-claude-
# history") that do not match the real bucket names.
BUCKETS="${STORAGE_INVENTORY_BUCKETS:-whatsapp-viewer-549710416969 urblink-claude-history-backup urblink-dolt-backups urblink-assertiva-recovery urblink-classifier-calls urblink-motherduck-backups}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [storage-inventory] $*" >> "$LOG" 2>/dev/null || true; }

# _pct_delta <old> <new> — signed percent change, empty (no baseline / bad
# input) never collapsed into 0. Fail-closed on non-numeric input.
_pct_delta() {
  local old="$1" new="$2"
  case "$old" in ''|0|0.0|0.00) echo ""; return ;; esac
  case "$old" in *[!0-9.]*) echo ""; return ;; esac
  case "$new" in ''|*[!0-9.]*) echo ""; return ;; esac
  awk -v o="$old" -v n="$new" 'BEGIN{printf "%.1f", (n-o)/o*100}'
}

# _status_for_delta <delta> — "novo" (no prior baseline), "⚠️" (beyond the
# band), or "✅". Never silently treats "no baseline" as "stable".
_status_for_delta() {
  local delta="$1"
  if [ -z "$delta" ]; then echo "novo"; return; fi
  local abs
  abs=$(awk -v d="$delta" 'BEGIN{print (d<0)?-d:d}')
  if awk -v a="$abs" -v t="$DEVIATION_PCT" 'BEGIN{exit !(a>t)}'; then echo "⚠️"; else echo "✅"; fi
}

# _df_data_gb — echoes "<used_gb> <total_gb>" for $DATA_DIR. NEVER `df /` —
# it lies about free space on macOS (same gotcha Part 0 row 1's own Medir
# column and dolt-restore-verify.sh already document).
_df_data_gb() {
  local total_kb used_kb
  total_kb=$("$DF_BIN" -k "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $2}')
  used_kb=$("$DF_BIN" -k "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $3}')
  case "$total_kb" in ''|*[!0-9]*) echo ""; return 1 ;; esac
  case "$used_kb" in ''|*[!0-9]*) echo ""; return 1 ;; esac
  awk -v t="$total_kb" -v u="$used_kb" 'BEGIN{printf "%.2f %.2f", u/1024/1024, t/1024/1024}'
}

# _df_data_free_gb — echoes the FREE GB (2 decimals) of the APFS container that
# hosts $DATA_DIR: the `df` Avail column, the same one dolt-disk-floor-guard.sh
# reads (checked live 2026-10-01: df Avail == diskutil "Container Free Space",
# 5.293 GiB both). Empty on failure — never 0, which would read as "disk full".
# TRUNCATED to 2 decimals, not rounded: _status_for_free_gb floors this value
# against integer-GB floors, and rounding 3.999999 up to 4.00 would call it
# WARN where the guard (which floors the true value to 3) calls it CRITICAL.
_df_data_free_gb() {
  local avail_kb
  avail_kb=$("$DF_BIN" -k "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  case "$avail_kb" in ''|*[!0-9]*) echo ""; return 1 ;; esac
  awk -v a="$avail_kb" 'BEGIN{printf "%.2f", int(a / 1024 / 1024 * 100) / 100}'
}

# _status_for_free_gb <free_gb> — "🔴" (at/below the CRITICAL floor), "⚠️" (at/
# below WARN), "✅", or "N/A" when the free space is unknown. Mirrors the
# guard's _floor_class exactly: integer GB (the fraction is floored) compared
# with -le, so 3.1 GB free is CRITICAL here just as it is for the guard. A
# missing/garbled reading or a non-numeric floor is N/A, never ✅: "could not
# measure" must not read the same as "measured and healthy".
_status_for_free_gb() {
  local free="$1" whole
  case "$free" in *[0-9]*) ;; *) echo "N/A"; return ;; esac
  case "$free" in *[!0-9.]*) echo "N/A"; return ;; esac
  case "$FLOOR_WARN_GB" in ''|*[!0-9]*) echo "N/A"; return ;; esac
  case "$FLOOR_CRITICAL_GB" in ''|*[!0-9]*) echo "N/A"; return ;; esac
  whole=$(awk -v f="$free" 'BEGIN{printf "%d", f}')
  if [ "$whole" -le "$FLOOR_CRITICAL_GB" ]; then echo "🔴"; return; fi
  if [ "$whole" -le "$FLOOR_WARN_GB" ]; then echo "⚠️"; return; fi
  echo "✅"
}

# _swap_used_gb — echoes "<used_gb> <total_gb>" of macOS swap (vm.swapusage).
# Swap lives in the same APFS container as the data, so swap growth is part of
# why the container fills while the Data volume does not. Empty (N/A) if
# sysctl fails or its line does not parse — never a fabricated 0.
_swap_used_gb() {
  local line used_m total_m
  line=$("$SYSCTL_BIN" vm.swapusage 2>/dev/null) || { echo ""; return 1; }
  total_m=$(echo "$line" | sed -n 's/.*total = \([0-9.]*\)M.*/\1/p')
  used_m=$(echo "$line" | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  case "$total_m" in ''|*[!0-9.]*) echo ""; return 1 ;; esac
  case "$used_m" in ''|*[!0-9.]*) echo ""; return 1 ;; esac
  awk -v u="$used_m" -v t="$total_m" 'BEGIN{printf "%.2f %.2f", u/1024, t/1024}'
}

# _du_gb <path> — GB (2 decimals) via du -sk, empty on missing path/failure.
_du_gb() {
  local path="$1" kb
  [ -d "$path" ] || { echo ""; return 1; }
  kb=$(timeout 120 "$DU_BIN" -sk "$path" 2>/dev/null | awk '{print $1}')
  case "$kb" in ''|*[!0-9]*) echo ""; return 1 ;; esac
  awk -v k="$kb" 'BEGIN{printf "%.2f", k/1024/1024}'
}

# _s3_bucket_gb <bucket> — GB from `aws s3 ls --recursive --summarize`'s own
# "Total Size:" line. Empty (SKIP) on any failure — never 0, which would
# read as "confirmed empty bucket".
_s3_bucket_gb() {
  local bucket="$1" bytes
  bytes=$(timeout 300 "$AWS_BIN" s3 ls "s3://$bucket" --recursive --summarize 2>/dev/null \
    | awk -F': ' '/Total Size:/{print $2}')
  case "$bytes" in ''|*[!0-9]*) echo ""; return 1 ;; esac
  awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1024/1024/1024}'
}

# _s3_bucket_noncurrent_gb <bucket> — GB (2 decimals) held in NONCURRENT object
# versions. They are billed like any other byte but `s3 ls --recursive` never
# lists them (ga-utr9qf: 1552 GB in one bucket, 105 GB in another, against a
# reported 280 GB total). `--query sum(...)` makes the CLI print ONE number PER
# PAGE (156 lines for a 77k-version bucket, live 2026-10-01), so the pages are
# summed here. Empty (SKIP) on every doubt, never 0:
#   - aws failed — and that includes failing MID-pagination, after some pages
#     already printed: a partial sum must not pass for the total;
#   - exit 0 but no output at all (even an empty bucket prints one page, "0");
#   - any page that is not a plain integer.
# A bucket that was measured and holds none returns "0.00" — a real value.
_s3_bucket_noncurrent_gb() {
  local bucket="$1" out rc
  out=$(timeout "$S3_VERSIONS_TIMEOUT" "$AWS_BIN" s3api list-object-versions --bucket "$bucket" \
    --query 'sum(Versions[?IsLatest==`false`].Size || `[]`)' --output text 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { echo ""; return 1; }
  echo "$out" | awk '
    { for (i = 1; i <= NF; i++) { if ($i ~ /^[0-9]+$/) { s += $i; n++ } else bad = 1 } }
    END { if (bad || n == 0) exit 1; printf "%.2f", s / 1024 / 1024 / 1024 }'
}

# _s3_total_gb — sums every bucket in $BUCKETS and echoes
# "<billed> <ok> <count> <current> <noncurrent>" (GB; billed = current +
# noncurrent). A bucket counts only if BOTH its current and its noncurrent
# bytes were measured: a bucket with only the current half would put a
# current-only number into a "billed" total. A bucket that fails is skipped
# individually (not fatal to this function) and named in the log. What stops
# the sum over the survivors from passing for the total is the caller: it gets
# <ok> and <count> here, and main() treats ok != count as "could not measure
# the total" (status N/A, baseline untouched) — this function only reports it.
_s3_total_gb() {
  local bucket cur nc total=0 cur_total=0 nc_total=0 ok=0 count=0 skipped=""
  for bucket in $BUCKETS; do
    count=$((count + 1))
    cur=$(_s3_bucket_gb "$bucket")
    nc=""
    [ -n "$cur" ] && nc=$(_s3_bucket_noncurrent_gb "$bucket")
    if [ -n "$cur" ] && [ -n "$nc" ]; then
      cur_total=$(awk -v t="$cur_total" -v g="$cur" 'BEGIN{printf "%.2f", t+g}')
      nc_total=$(awk -v t="$nc_total" -v g="$nc" 'BEGIN{printf "%.2f", t+g}')
      total=$(awk -v t="$total" -v c="$cur" -v n="$nc" 'BEGIN{printf "%.2f", t+c+n}')
      ok=$((ok + 1))
      log "S3: $bucket corrente=${cur}GB nao-corrente=${nc}GB"
    else
      skipped="${skipped}${bucket} "
    fi
  done
  if [ "$ok" -eq 0 ]; then echo ""; return 1; fi
  echo "$total $ok $count $cur_total $nc_total"
  [ -n "$skipped" ] && log "S3: buckets pulados (falha/timeout): $skipped"
  return 0
}

# _drive_sa_quota — echoes "<used_gb> <limit_gb> <pct>" via the Drive
# service-account about.get call already proven live in this rig's own
# drive-pressure-monitor.sh. Empty (SKIP) if creds are absent or the API
# call fails — never fabricates a quota.
_drive_sa_quota() {
  [ -f "$DRIVE_CREDS_PATH" ] || { echo ""; return 1; }
  "$PYTHON_BIN" - "$DRIVE_CREDS_PATH" <<'PYEOF' 2>/dev/null
import sys
creds_path = sys.argv[1]
try:
    from google.oauth2 import service_account
    from googleapiclient.discovery import build
    scopes = ["https://www.googleapis.com/auth/drive.metadata.readonly"]
    creds = service_account.Credentials.from_service_account_file(creds_path, scopes=scopes)
    service = build("drive", "v3", credentials=creds)
    q = service.about().get(fields="storageQuota").execute().get("storageQuota", {})
    limit = int(q.get("limit", 0)); usage = int(q.get("usage", 0))
    if limit <= 0:
        sys.exit(1)
    print(f"{usage/1073741824:.2f} {limit/1073741824:.2f} {usage*100/limit:.1f}")
except Exception:
    sys.exit(1)
PYEOF
}

# _motherduck_verdict — the compute-hours verdict from the one real,
# existing MotherDuck measurement in this rig. Always "N/A(reason)" on any
# failure, never a fabricated number.
_motherduck_verdict() {
  if [ ! -f "$MOTHERDUCK_CHECK_SCRIPT" ]; then echo "N/A(script-ausente)"; return 1; fi
  local json
  json=$(timeout 60 "$PYTHON_BIN" "$MOTHERDUCK_CHECK_SCRIPT" --json 2>/dev/null)
  if [ -z "$json" ]; then echo "N/A(falhou)"; return 1; fi
  "$PYTHON_BIN" -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("N/A(json-invalido)"); sys.exit(0)
proj = d.get("projected_monthly_hours")
thr = d.get("threshold_hours")
below = d.get("below_threshold")
if proj is None or thr is None or below is None:
    print("N/A(inconclusivo)")
elif below:
    print(f"{proj:.1f}h/mes projetado (abaixo do teto {thr:.0f}h)")
else:
    print(f"{proj:.1f}h/mes projetado (ACIMA do teto {thr:.0f}h)")
' "$json" 2>/dev/null || echo "N/A(parse-falhou)"
}

# _read_previous_data_line <doc> — the raw storage-inventory:data comment
# line from a prior run, or empty on first run / doc missing.
_read_previous_data_line() {
  local doc="$1"
  [ -f "$doc" ] || { echo ""; return; }
  grep -m1 '^<!-- storage-inventory:data ' "$doc" 2>/dev/null || true
}

# _extract_field <data_line> <key> — pulls key=NUMBER out of the data line.
_extract_field() {
  local line="$1" key="$2"
  echo "$line" | grep -oE "${key}=[0-9]+(\.[0-9]+)?" | head -1 | cut -d= -f2
}

# _update_doc_block <doc> <new_block_file> — SAFE-EDIT: replaces content
# between existing markers, or inserts before the anchor heading on first
# run. Fails closed (no write) if neither markers nor anchor are found.
#
# The new block file starts at BEGIN_MARK and carries its own heading +
# legend. Docs written by the pre-ga-hdab26 layout have those generated lines
# OUTSIDE (above) the markers, one more copy per run; on replace, the
# contiguous run of such lines (heading/legend prefixes + the blank lines
# between them) sitting DIRECTLY above BEGIN_MARK is dropped, since the new
# block re-emits them inside the markers. Only that adjacent run, only those
# exact generated prefixes: a run followed by anything else is flushed back
# unchanged, so human content is never removed.
_update_doc_block() {
  local doc="$1" blockfile="$2" tmp
  [ -f "$doc" ] || { echo "doc-missing"; return 1; }
  tmp="$(mktemp "${doc}.tmp.XXXXXX")" || { echo "mktemp-falhou"; return 1; }
  if grep -qF "$BEGIN_MARK" "$doc" && grep -qF "$END_MARK" "$doc"; then
    awk -v begin="$BEGIN_MARK" -v end="$END_MARK" -v blockfile="$blockfile" \
        -v hdr="$HDR_PREFIX" -v legend="$LEGEND_PREFIX" '
      function flush_held(   i) { for (i = 1; i <= nheld; i++) print held[i]; nheld = 0 }
      $0 == begin { nheld = 0; while ((getline line < blockfile) > 0) print line; close(blockfile); skip=1; next }
      $0 == end { skip=0; next }
      skip { next }
      index($0, hdr) == 1 || index($0, legend) == 1 { held[++nheld] = $0; next }
      nheld > 0 && $0 == "" { held[++nheld] = $0; next }
      { flush_held(); print }
      END { flush_held() }
    ' "$doc" > "$tmp" && mv "$tmp" "$doc" && { echo "replaced"; return 0; }
    rm -f "$tmp" 2>/dev/null
    echo "write-falhou"; return 1
  elif grep -qE "$ANCHOR_RE" "$doc"; then
    awk -v anchor="$ANCHOR_RE" -v blockfile="$blockfile" '
      $0 ~ anchor && !done { while ((getline line < blockfile) > 0) print line; close(blockfile); print ""; done=1 }
      { print }
    ' "$doc" > "$tmp" && mv "$tmp" "$doc" && { echo "inserted"; return 0; }
    rm -f "$tmp" 2>/dev/null
    echo "write-falhou"; return 1
  else
    rm -f "$tmp" 2>/dev/null
    echo "anchor-nao-encontrado"
    return 1
  fi
}

# _commit_doc <doc> — narrow, single-file commit+push. Never `-A`. Pulls
# --ff-only first (matches this rig's own delivery-runbooks.toml deploy_cmd
# exactly); if that fails (diverged tree) or the staged diff touches
# anything but $doc, the edit is left uncommitted on disk and this returns
# non-zero rather than forcing anything.
#
# Every git subcommand below redirects its OWN stdout/stderr to $LOG, never
# left inheriting this function's stdout. Live-verified failure mode
# (2026-08-26 build-time run): whatsapp_automation's pre-push hook prints a
# multi-line plist audit report on every push (unrelated to this change, it
# runs on all pushes) — with inherited stdout, that report became PART OF
# commit_result via the caller's `$(...)` capture, so the later `case
# "$commit_result" in commitado|...)` match failed (the captured string was
# the whole report, not the literal word "commitado"), and a fully successful
# push got misclassified as a failure. `-q` only silences git's OWN messages,
# never a hook's.
_commit_doc() {
  local doc="$1" rel
  [ "$SKIP_GIT" = "1" ] && { echo "git-pulado(SKIP_GIT=1)"; return 0; }
  rel="${doc#"$WA_ROOT"/}"
  "$GIT_BIN" -C "$WA_ROOT" pull --ff-only >>"$LOG" 2>&1 || { echo "pull-nao-ff"; return 1; }
  "$GIT_BIN" -C "$WA_ROOT" add "$rel" >>"$LOG" 2>&1 || { echo "add-falhou"; return 1; }
  local staged
  staged="$("$GIT_BIN" -C "$WA_ROOT" diff --cached --name-only 2>>"$LOG")"
  if [ "$staged" != "$rel" ]; then
    "$GIT_BIN" -C "$WA_ROOT" reset -q -- "$rel" >>"$LOG" 2>&1
    echo "staged-inesperado:$staged"; return 1
  fi
  if [ -z "$("$GIT_BIN" -C "$WA_ROOT" diff --cached 2>>"$LOG")" ]; then
    "$GIT_BIN" -C "$WA_ROOT" reset -q -- "$rel" >>"$LOG" 2>&1
    echo "sem-mudanca"; return 0
  fi
  "$GIT_BIN" -C "$WA_ROOT" commit -q -m "chore(ga-z297h): inventario mensal de storage automatizado" >>"$LOG" 2>&1 || { echo "commit-falhou"; return 1; }
  "$GIT_BIN" -C "$WA_ROOT" push -q >>"$LOG" 2>&1 || { echo "push-falhou"; return 1; }
  echo "commitado"
}

# _file_summary_bead <table_md> <overall_rc> — ONE bead per run, mirroring
# dolt-restore-verify.sh's convention: clean run = closed chore, any ⚠️/
# failure = open bug routed to gastown.dog (left open on purpose — closing
# it here would hide the exact thing this story exists to surface).
_file_summary_bead() {
  local table="$1" overall_rc="$2" title body bead_id meta
  body="Inventario mensal de storage automatizado (ga-z297h). Tabela desta rodada:
$table

Doc atualizado: $DOC_PATH
Log completo: $LOG"
  if [ "$overall_rc" -eq 0 ]; then
    title="Inventario de storage mensal OK ($(date -u '+%Y-%m-%d'))"
    bead_id=$(timeout 30 "$BD_BIN" -C "$CITY" create --title="$title" --type=chore --priority=3 --labels=storage-inventory --description="$body" --silent 2>/dev/null)
    [ -n "$bead_id" ] && timeout 30 "$BD_BIN" -C "$CITY" close "$bead_id" --reason "inventario mensal limpo, nenhum vetor fora da banda" -q 2>/dev/null
  else
    title="Inventario de storage mensal: atencao necessaria ($(date -u '+%Y-%m-%d'))"
    meta='{"gc.routed_to":"gastown.dog"}'
    bead_id=$(timeout 30 "$BD_BIN" -C "$CITY" create --title="$title" --type=bug --priority=2 --labels=storage-inventory --description="$body" --metadata="$meta" --silent 2>/dev/null)
  fi
  if [ -n "$bead_id" ]; then
    log "bead de resumo: $bead_id"
  else
    log "AVISO: falhei ao criar o bead de resumo — resultado so existe no log ($LOG)"
    "$NOTIFY" -t "Storage inventory mensal" -p 3 "⚠️ rodou mas falhou ao registrar o bead de resumo (bd indisponivel?) — ver $LOG" 2>/dev/null || true
  fi
}

main() {
  local now_date prev_line overall_rc=0
  now_date=$(date -u '+%Y-%m-%d')
  prev_line=$(_read_previous_data_line "$DOC_PATH")

  # Mac mini
  local mm_out mm_used="" mm_total="" mm_prev mm_delta mm_status
  mm_out=$(_df_data_gb) || true
  [ -n "$mm_out" ] && { mm_used=$(echo "$mm_out" | awk '{print $1}'); mm_total=$(echo "$mm_out" | awk '{print $2}'); }
  mm_prev=$(_extract_field "$prev_line" "mac_mini_used_gb")
  mm_delta=$([ -n "$mm_used" ] && _pct_delta "$mm_prev" "$mm_used" || echo "")
  mm_status=$([ -n "$mm_used" ] && _status_for_delta "$mm_delta" || echo "N/A")
  log "Mac mini: used=${mm_used:-?}GB total=${mm_total:-?}GB prev=${mm_prev:-none} delta=${mm_delta:-?} status=$mm_status"

  # Mac mini free space — the number that actually decides whether the disk is
  # in trouble (ga-utr9qf). The "used" delta above only sees the Data volume.
  local mm_free mm_free_status mm_cpct="" mm_swap_out mm_swap_used="" mm_swap_total=""
  mm_free=$(_df_data_free_gb) || true
  mm_free_status=$(_status_for_free_gb "$mm_free")
  if [ -n "$mm_free" ] && [ -n "$mm_total" ]; then
    mm_cpct=$(awk -v t="$mm_total" -v f="$mm_free" 'BEGIN{if (t > 0) printf "%.1f", (t - f) / t * 100}')
  fi
  mm_swap_out=$(_swap_used_gb) || true
  [ -n "$mm_swap_out" ] && { mm_swap_used=$(echo "$mm_swap_out" | awk '{print $1}'); mm_swap_total=$(echo "$mm_swap_out" | awk '{print $2}'); }
  log "Mac mini livre: free=${mm_free:-?}GB container=${mm_cpct:-?}% cheio swap=${mm_swap_used:-?}/${mm_swap_total:-?}GB status=$mm_free_status (pisos: warn<=${FLOOR_WARN_GB}GB crit<=${FLOOR_CRITICAL_GB}GB)"

  # Diretorios-chave (informativo, sem alerta individual — o total do Mac
  # mini acima ja carrega o sinal de desvio agregado).
  local key_dirs_md="" path label gb
  while IFS='|' read -r path label; do
    [ -z "$path" ] && continue
    gb=$(_du_gb "$path")
    key_dirs_md="${key_dirs_md}| ${label} | \`${path}\` | ${gb:-N/A} Gi |
"
  done <<< "$KEY_DIRS"

  # S3
  # The status/baseline is the BILLED total (current + noncurrent versions).
  # s3_total_gb keeps its old meaning (current versions only) as its own data
  # key, so the pre-ga-utr9qf baseline stays comparable; s3_billed_gb is new,
  # so the first run after this change has no billed baseline ("novo").
  local s3_out s3_billed="" s3_ok="" s3_count="" s3_cur="" s3_nc="" s3_partial=0
  local s3_prev s3_delta s3_status s3_cur_prev s3_cur_delta
  s3_out=$(_s3_total_gb) || true
  if [ -n "$s3_out" ]; then
    s3_billed=$(echo "$s3_out" | awk '{print $1}')
    s3_ok=$(echo "$s3_out" | awk '{print $2}')
    s3_count=$(echo "$s3_out" | awk '{print $3}')
    s3_cur=$(echo "$s3_out" | awk '{print $4}')
    s3_nc=$(echo "$s3_out" | awk '{print $5}')
    # The numbers above are sums over the buckets that WERE measured. Only
    # proof that every bucket was measured makes them a total; a missing or
    # malformed count counts as "not proven" (string compare, so it cannot
    # error out into the healthy branch) — the inert state under doubt.
    s3_partial=1
    if [ -n "$s3_count" ] && [ "$s3_ok" = "$s3_count" ]; then s3_partial=0; fi
  fi
  s3_prev=$(_extract_field "$prev_line" "s3_billed_gb")
  s3_delta=$([ -n "$s3_billed" ] && _pct_delta "$s3_prev" "$s3_billed" || echo "")
  s3_status=$([ -n "$s3_billed" ] && _status_for_delta "$s3_delta" || echo "N/A")
  s3_cur_prev=$(_extract_field "$prev_line" "s3_total_gb")
  s3_cur_delta=$([ -n "$s3_cur" ] && _pct_delta "$s3_cur_prev" "$s3_cur" || echo "")
  # What the data line records as next month's baselines (see the data line below).
  local s3_billed_rec="${s3_billed:-$s3_prev}" s3_cur_rec="${s3_cur:-$s3_cur_prev}"
  # Table cells for the two S3 rows.
  local s3_billed_cell="${s3_billed:-N/A} GB (${s3_nc:-N/A} GB são versões não-correntes)"
  local s3_cur_cell="${s3_cur:-N/A} GB"
  if [ "$s3_partial" -eq 1 ]; then
    # A bucket that could not be measured (GATE-FEEDBACK ga-utr9qf attempt 1,
    # blocking issue 1): "couldn't measure the total" is a different outcome
    # from "measured, and healthy". The partial sum gets no delta and no
    # healthy status (N/A trips the overall verdict like any unmeasured
    # vector), and neither baseline moves.
    s3_delta=""; s3_cur_delta=""; s3_status="N/A"
    s3_billed_rec="$s3_prev"; s3_cur_rec="$s3_cur_prev"
    s3_billed_cell="N/A — PARCIAL: só ${s3_ok:-0}/${s3_count:-0} buckets medidos (a soma de ${s3_billed:-N/A} GB NÃO é o total faturado)"
    s3_cur_cell="N/A — PARCIAL: só ${s3_ok:-0}/${s3_count:-0} buckets medidos (soma de ${s3_cur:-N/A} GB)"
  fi
  log "S3: faturado=${s3_billed:-?}GB (corrente=${s3_cur:-?}GB + nao-corrente=${s3_nc:-?}GB; ${s3_ok:-0}/${s3_count:-0} buckets) prev=${s3_prev:-none} delta=${s3_delta:-?} status=$s3_status"
  if [ "$s3_partial" -eq 1 ]; then
    log "S3: cobertura PARCIAL (${s3_ok:-?}/${s3_count:-?} buckets) -> status N/A; s3_billed_gb/s3_total_gb mantidos em ${s3_billed_rec:-vazio}/${s3_cur_rec:-vazio} (a soma parcial nao vira baseline)"
  fi

  # Drive SA
  local drv_out drv_used="" drv_limit="" drv_pct="" drv_prev drv_delta drv_status
  drv_out=$(_drive_sa_quota) || true
  if [ -n "$drv_out" ]; then
    drv_used=$(echo "$drv_out" | awk '{print $1}')
    drv_limit=$(echo "$drv_out" | awk '{print $2}')
    drv_pct=$(echo "$drv_out" | awk '{print $3}')
  fi
  drv_prev=$(_extract_field "$prev_line" "drive_sa_used_gb")
  drv_delta=$([ -n "$drv_used" ] && _pct_delta "$drv_prev" "$drv_used" || echo "")
  drv_status=$([ -n "$drv_used" ] && _status_for_delta "$drv_delta" || echo "N/A")
  log "Drive SA: used=${drv_used:-?}GB limit=${drv_limit:-?}GB pct=${drv_pct:-?}% prev=${drv_prev:-none} delta=${drv_delta:-?} status=$drv_status"

  # MotherDuck (compute verdict — see header note on why not storage bytes)
  local md_verdict md_status
  md_verdict=$(_motherduck_verdict) || true
  case "$md_verdict" in
    *ACIMA*) md_status="⚠️" ;;
    N/A*) md_status="N/A" ;;
    *) md_status="✅" ;;
  esac
  log "MotherDuck: $md_verdict status=$md_status"

  # Overall verdict — plain equality checks (not a case pattern) so this
  # never depends on none of the status strings containing glob metachars.
  # Only ✅ and "novo" (first run, nothing to compare against) are healthy;
  # EVERYTHING else trips it — ⚠️, 🔴, N/A, and any status string added later.
  # N/A (measurement failed) must trip this exactly like ⚠️: "couldn't
  # measure" and "measured and healthy" are different outcomes, and
  # collapsing them let a failed vector auto-close this run as OK
  # (GATE-FEEDBACK ga-z297h attempt 1, blocking issue 1). Listing the BAD
  # statuses instead is how 🔴 would have slipped through as "not ⚠️".
  local st
  for st in "$mm_free_status" "$mm_status" "$s3_status" "$drv_status" "$md_status"; do
    if [ "$st" != "✅" ] && [ "$st" != "novo" ]; then overall_rc=1; fi
  done

  local table_md
  table_md="| Vetor | Medido em | Valor atual | Rodada anterior | Δ | Status |
|---|---|---|---|---|---|
| Mac mini \`$DATA_DIR\` container livre | $now_date | ${mm_free:-N/A} Gi livres de ${mm_total:-N/A} Gi (container ${mm_cpct:-N/A}% cheio; swap ${mm_swap_used:-N/A}/${mm_swap_total:-N/A} Gi) | — | — | $mm_free_status |
| Mac mini \`$DATA_DIR\` usado (só o volume Data, NÃO é o espaço livre) | $now_date | ${mm_used:-N/A} Gi (de ${mm_total:-N/A} Gi) | ${mm_prev:-—} Gi | ${mm_delta:-—}% | $mm_status |
| S3 faturado: correntes + não-correntes (${s3_ok:-0}/${s3_count:-0} buckets) | $now_date | $s3_billed_cell | ${s3_prev:-—} GB | ${s3_delta:-—}% | $s3_status |
| S3 só versões correntes (o que \`s3 ls --recursive\` enxerga) | $now_date | $s3_cur_cell | ${s3_cur_prev:-—} GB | ${s3_cur_delta:-—}% | — |
| Drive SA (service account) | $now_date | ${drv_used:-N/A} Gi (${drv_pct:-N/A}%) | ${drv_prev:-—} Gi | ${drv_delta:-—}% | $drv_status |
| MotherDuck compute | $now_date | $md_verdict | — | — | $md_status |"

  local block_file
  block_file="$(mktemp)" || { log "mktemp falhou para o bloco do doc"; _file_summary_bead "$table_md" 1; return 1; }
  {
    # BEGIN_MARK must be the FIRST line: the heading and legend live INSIDE
    # the markers so a replace owns (and rewrites) them. Written before the
    # markers they were never replaced, and every run stacked one more copy
    # above the block (ga-hdab26: 4 copies by 2026-10-01).
    echo "$BEGIN_MARK"
    echo "${HDR_PREFIX} (script mensal, ga-z297h)"
    echo ""
    echo "${LEGEND_PREFIX} (launchd \`com.gascity.storage-inventory-monthly\`, mensal). Não edite manualmente entre os marcadores — a próxima rodada sobrescreve. ⚠️ = vetor saiu de ±${DEVIATION_PCT}% da rodada anterior. No espaço livre do Mac mini, ⚠️/🔴 = abaixo dos pisos do dolt-disk-floor-guard (≤${FLOOR_WARN_GB} GB / ≤${FLOOR_CRITICAL_GB} GB), não variação."
    echo ""
    # On a failed measurement (mm_used/s3_total/drv_used empty), carry the
    # PREVIOUS recorded value forward instead of writing 0 — a literal 0
    # here becomes next month's baseline, and _pct_delta's own zero-case
    # then reads that fabricated 0 as "no baseline", silently erasing the
    # last real measurement (GATE-FEEDBACK ga-z297h attempt 1, blocking
    # issue 2). The two S3 values are the same rule applied once more: they
    # are carried forward both when S3 failed outright and when only SOME
    # buckets were measured (s3_*_rec above) — a sum over the survivors is
    # not a reading of the total and must not become its baseline.
    echo "<!-- storage-inventory:data mac_mini_used_gb=${mm_used:-$mm_prev} s3_total_gb=${s3_cur_rec} s3_billed_gb=${s3_billed_rec} drive_sa_used_gb=${drv_used:-$drv_prev} ts=$now_date -->"
    echo "$table_md"
    echo ""
    echo "**Diretórios-chave (\`~/gt\` e afins), medidos $now_date:**"
    echo ""
    echo "| Diretório | Path | Tamanho |"
    echo "|---|---|---|"
    printf '%s' "$key_dirs_md"
    echo "$END_MARK"
  } > "$block_file"

  local doc_result
  doc_result=$(_update_doc_block "$DOC_PATH" "$block_file")
  local doc_rc=$?
  rm -f "$block_file" 2>/dev/null
  log "doc update: $doc_result (rc=$doc_rc)"
  [ "$doc_rc" -ne 0 ] && overall_rc=1

  local commit_result=""
  if [ "$doc_rc" -eq 0 ]; then
    commit_result=$(_commit_doc "$DOC_PATH")
    log "git: $commit_result"
    case "$commit_result" in commitado|sem-mudanca|git-pulado*) ;; *) overall_rc=1 ;; esac
  fi

  _file_summary_bead "$table_md" "$overall_rc"
  return "$overall_rc"
}

if [ "${STORAGE_INVENTORY_LIB:-0}" != "1" ]; then
  main
  exit $?
fi
