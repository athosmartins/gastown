#!/bin/bash
# storage-inventory-monthly.selftest.sh — unit + orchestration tests for
# storage-inventory-monthly.sh (ga-z297h).
#
# Hermetic: sources the script as a LIBRARY (STORAGE_INVENTORY_LIB=1), so
# main() never runs on load. AWS_BIN/DU_BIN/DF_BIN/PYTHON_BIN/GIT_BIN/BD_BIN/
# NOTIFY all point at fake, scratch-local binaries — no real AWS/Google/
# MotherDuck/Dolt/git call ever happens. All paths (DOC_PATH, LOG,
# DRIVE_CREDS_PATH, MOTHERDUCK_CHECK_SCRIPT) point at a throwaway scratch dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/storage-inventory-monthly.sh"

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export STORAGE_INVENTORY_LIB=1
export STORAGE_INVENTORY_LOG="$SCRATCH/storage-inventory.log"
export STORAGE_INVENTORY_DEVIATION_PCT=20
export STORAGE_INVENTORY_SKIP_GIT=0
export WA_ROOT="$SCRATCH/wa"
export DOC_PATH="$SCRATCH/wa/docs/data_dictionary.md"
export DRIVE_CREDS_PATH="$SCRATCH/wa/data/google_credentials.json"
export MOTHERDUCK_CHECK_SCRIPT="$SCRATCH/wa/scripts/motherduck_invoice_usage_check.py"
export STORAGE_INVENTORY_KEY_DIRS="$SCRATCH/dirA|Dir A
$SCRATCH/dir-missing|Missing Dir"
export STORAGE_INVENTORY_BUCKETS="bucket-ok bucket-fail"
mkdir -p "$SCRATCH/wa/docs" "$SCRATCH/wa/data" "$SCRATCH/wa/scripts" "$SCRATCH/dirA"
echo "hello" > "$SCRATCH/dirA/file.txt"

# shellcheck disable=SC1090
. "$SCRIPT"

DF_BIN="$SCRATCH/fake-df.sh"
cat > "$DF_BIN" <<'EOF'
#!/bin/bash
[ "${FAKE_DF_FAIL:-0}" = "1" ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "dummy ${FAKE_DF_TOTAL_KB:-1000000} ${FAKE_DF_USED_KB:-500000} ${FAKE_DF_AVAIL_KB:-104857600} 1% /"
EOF
chmod +x "$DF_BIN"

SYSCTL_BIN="$SCRATCH/fake-sysctl.sh"
cat > "$SYSCTL_BIN" <<'EOF'
#!/bin/bash
[ "${FAKE_SYSCTL_FAIL:-0}" = "1" ] && exit 1
echo "${FAKE_SWAP_LINE:-vm.swapusage: total = 8192.00M  used = 7514.25M  free = 677.75M  (encrypted)}"
EOF
chmod +x "$SYSCTL_BIN"

AWS_BIN="$SCRATCH/fake-aws.sh"
cat > "$AWS_BIN" <<'EOF'
#!/bin/bash
echo "AWS-CALLED $*" >> "${FAKE_AWS_LOG:-/dev/null}"
if [ "$1" = "s3api" ] && [ "$2" = "list-object-versions" ]; then
  # `aws s3api list-object-versions --bucket <b> --query 'sum(...)' --output text`
  # prints ONE number PER PAGE (live-measured: 156 lines for a 77k-version bucket).
  [ "${FAKE_AWS_NC_FAIL:-0}" = "1" ] && exit 1
  [ "$4" = "bucket-fail" ] && exit 1
  [ "${FAKE_AWS_NC_EMPTY:-0}" = "1" ] && exit 0
  for page in ${FAKE_AWS_NONCURRENT_PAGES-0}; do echo "$page"; done
  [ "${FAKE_AWS_NC_PARTIAL_FAIL:-0}" = "1" ] && exit 1   # throttled/timed out MID-pagination
  exit 0
fi
bucket="$3"
case "$bucket" in
  s3://bucket-fail) exit 1 ;;
  s3://bucket-ok) echo "Total Size: ${FAKE_AWS_BYTES:-1073741824}" ;;
  *) echo "Total Size: ${FAKE_AWS_BYTES:-1073741824}" ;;
esac
EOF
chmod +x "$AWS_BIN"

PYTHON_BIN="$SCRATCH/fake-python.sh"
cat > "$PYTHON_BIN" <<'EOF'
#!/bin/bash
echo "PYTHON-CALLED $*" >> "${FAKE_PYTHON_LOG:-/dev/null}"
cat >/dev/null   # drain stdin (heredoc / -c arg script) like real python3 would
case "$*" in
  *google_credentials*)
    [ "${FAKE_DRIVE_FAIL:-0}" = "1" ] && exit 1
    echo "${FAKE_DRIVE_OUTPUT:-12.00 15.00 80.0}"
    ;;
  *motherduck_invoice_usage_check.py*--json*)
    [ "${FAKE_MD_FAIL:-0}" = "1" ] && exit 1
    echo "${FAKE_MD_JSON:-{\"projected_monthly_hours\": 45.2, \"threshold_hours\": 92.0, \"below_threshold\": true}}"
    ;;
  *-c*)
    # the inline `python3 -c` JSON-verdict parser: emulate its real logic
    # minimally so main()'s wiring is actually exercised, not just stubbed.
    if [ "${FAKE_MD_VERDICT:-}" != "" ]; then echo "$FAKE_MD_VERDICT"; else echo "N/A(parse-falhou)"; fi
    ;;
esac
EOF
chmod +x "$PYTHON_BIN"

GIT_BIN="$SCRATCH/fake-git.sh"
cat > "$GIT_BIN" <<'EOF'
#!/bin/bash
echo "GIT-CALLED $*" >> "${FAKE_GIT_LOG:-/dev/null}"
# -C <dir> <subcommand> ...
shift 2
case "$1" in
  pull) [ "${FAKE_GIT_PULL_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
  add) exit 0 ;;
  diff)
    if [ "$3" = "--name-only" ]; then echo "${FAKE_GIT_STAGED:-docs/data_dictionary.md}";
    else [ "${FAKE_GIT_DIFF_EMPTY:-0}" = "1" ] && exit 0 || echo "+++ fake diff +++"; fi
    ;;
  reset) exit 0 ;;
  commit)
    [ "${FAKE_GIT_HOOK_NOISE:-0}" = "1" ] && printf 'OK — 736 plist(s) checked\n\nsome multi-line hook report\nmore lines\n'
    [ "${FAKE_GIT_COMMIT_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
  push)
    [ "${FAKE_GIT_HOOK_NOISE:-0}" = "1" ] && printf 'pre-push: running plist audit...\n27 plist(s) skipped: unresolvable entrypoint\n'
    [ "${FAKE_GIT_PUSH_FAIL:-0}" = "1" ] && exit 1; exit 0 ;;
esac
EOF
chmod +x "$GIT_BIN"

BD_BIN="$SCRATCH/fake-bd.sh"
cat > "$BD_BIN" <<'EOF'
#!/bin/bash
echo "BD-CALLED $*" >> "${FAKE_BD_LOG:-/dev/null}"
case "$1" in -C) shift 2 ;; esac
case "$1" in
  create) [ "${FAKE_BD_CREATE_FAIL:-0}" = "1" ] && exit 1; echo "${FAKE_BD_NEW_ID:-fake-bead-1}" ;;
  close)  ;;
esac
exit 0
EOF
chmod +x "$BD_BIN"

NOTIFY="$SCRATCH/fake-notify.sh"
cat > "$NOTIFY" <<'EOF'
#!/bin/bash
echo "NOTIFY-CALLED $*" >> "${FAKE_NOTIFY_LOG:-/dev/null}"
EOF
chmod +x "$NOTIFY"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== storage-inventory-monthly.selftest.sh ==="

# ════════════════════════════════════════════════════════════════════════════
# 1. Pure functions
# ════════════════════════════════════════════════════════════════════════════
echo "── _pct_delta <old> <new> ──"
[ "$(_pct_delta 100 120)" = "20.0" ] && ok "100->120 = +20.0%" || bad "expected 20.0, got '$(_pct_delta 100 120)'"
[ "$(_pct_delta 100 80)" = "-20.0" ] && ok "100->80 = -20.0%" || bad "expected -20.0, got '$(_pct_delta 100 80)'"
[ -z "$(_pct_delta '' 120)" ] && ok "no baseline -> empty (never fabricates a delta)" || bad "empty old should give empty"
[ -z "$(_pct_delta 0 120)" ] && ok "zero baseline -> empty (never divides by zero)" || bad "zero old should give empty, not crash/garbage"
[ -z "$(_pct_delta abc 120)" ] && ok "non-numeric old -> empty" || bad "non-numeric old should give empty"
[ -z "$(_pct_delta 100 abc)" ] && ok "non-numeric new -> empty" || bad "non-numeric new should give empty"

echo "── _status_for_delta <delta> ──"
[ "$(_status_for_delta '')" = "novo" ] && ok "no baseline -> 'novo', not silently '✅'" || bad "expected 'novo'"
[ "$(_status_for_delta 5.0)" = "✅" ] && ok "+5% within band -> ✅" || bad "expected ✅"
[ "$(_status_for_delta -5.0)" = "✅" ] && ok "-5% within band -> ✅ (abs value, not just positive)" || bad "expected ✅"
[ "$(_status_for_delta 20.0)" = "✅" ] && ok "exactly at the 20% boundary -> ✅ (>, not >=)" || bad "expected ✅ at exact boundary"
[ "$(_status_for_delta 20.1)" = "⚠️" ] && ok "just past the 20% boundary -> ⚠️" || bad "expected ⚠️ just past boundary"
[ "$(_status_for_delta -35.0)" = "⚠️" ] && ok "large negative delta -> ⚠️ (drops count as deviation too)" || bad "expected ⚠️ for large drop"

echo "── _df_data_gb (fake df) ──"
OUT="$(FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 _df_data_gb)"
[ "$OUT" = "100.00 200.00" ] && ok "200GB total/100GB used parsed correctly" || bad "expected '100.00 200.00', got '$OUT'"

echo "── _df_data_free_gb (ga-utr9qf: the APFS container's FREE space — the Avail column the dolt-disk-floor-guard reads) ──"
OUT="$(FAKE_DF_AVAIL_KB=3145728 _df_data_free_gb)"
[ "$OUT" = "3.00" ] && ok "3GiB Avail parsed as 3.00 free" || bad "expected '3.00', got '$OUT'"
[ -z "$(FAKE_DF_FAIL=1 _df_data_free_gb)" ] && ok "df failure -> empty (N/A), never 0 free" || bad "failed df must give empty, got '$(FAKE_DF_FAIL=1 _df_data_free_gb)'"
# 4194303 KB = 3.999999 GiB. ROUNDING it to 4.00 would make the status WARN where the
# guard — which floors the true value to 3 — says CRITICAL. The reading must be
# TRUNCATED to 2 decimals so the floor taken from it is the guard's floor.
OUT="$(FAKE_DF_AVAIL_KB=4194303 _df_data_free_gb)"
[ "$OUT" = "3.99" ] && ok "3.999999 GiB -> 3.99 (truncated, never rounded up across an integer-GB floor)" || bad "expected '3.99', got '$OUT'"
[ "$(_status_for_free_gb "$OUT")" = "🔴" ] && ok "...and that reading is 🔴, exactly as the guard classifies it" || bad "expected 🔴 for 3.999999 GiB free, got '$(_status_for_free_gb "$OUT")'"

echo "── _status_for_free_gb <free_gb> (floors mirror dolt-disk-floor-guard: WARN 8 / CRITICAL 3, integer GB, -le) ──"
[ "$(_status_for_free_gb 100.00)" = "✅" ] && ok "100GB free -> ✅" || bad "expected ✅, got '$(_status_for_free_gb 100.00)'"
[ "$(_status_for_free_gb 9.00)" = "✅" ] && ok "9.00GB free -> ✅ (above the 8GB warn floor)" || bad "expected ✅ at 9.00, got '$(_status_for_free_gb 9.00)'"
[ "$(_status_for_free_gb 8.99)" = "⚠️" ] && ok "8.99GB free -> ⚠️ (guard floors to 8, 8 -le 8 = WARN)" || bad "expected ⚠️ at 8.99, got '$(_status_for_free_gb 8.99)'"
[ "$(_status_for_free_gb 4.00)" = "⚠️" ] && ok "4.00GB free -> ⚠️ (WARN, not yet CRITICAL)" || bad "expected ⚠️ at 4.00, got '$(_status_for_free_gb 4.00)'"
[ "$(_status_for_free_gb 3.99)" = "🔴" ] && ok "3.99GB free -> 🔴 (guard floors to 3, 3 -le 3 = CRITICAL)" || bad "expected 🔴 at 3.99, got '$(_status_for_free_gb 3.99)'"
[ "$(_status_for_free_gb 3.10)" = "🔴" ] && ok "3.1GB free (the ga-utr9qf incident) -> 🔴, never ✅" || bad "expected 🔴 at 3.10, got '$(_status_for_free_gb 3.10)'"
[ "$(_status_for_free_gb '')" = "N/A" ] && ok "unmeasured free space -> N/A, not ✅ (error and healthy are different outcomes)" || bad "expected N/A for empty, got '$(_status_for_free_gb '')'"
[ "$(_status_for_free_gb abc)" = "N/A" ] && ok "non-numeric free space -> N/A" || bad "expected N/A for non-numeric, got '$(_status_for_free_gb abc)'"
# The floors are resolved when the script is SOURCED, so the override has to be
# exercised through a fresh shell that sources it with the env already set.
floor_in_fresh_shell() {  # <free_gb> [ENV=VAL ...] — the status a fresh shell computes
  local free="$1"; shift
  env "$@" STORAGE_INVENTORY_LIB=1 bash -c '. "$1"; _status_for_free_gb "$2"' _ "$SCRIPT" "$free"
}
[ "$(floor_in_fresh_shell 15.00 STORAGE_INVENTORY_FLOOR_WARN_GB=20)" = "⚠️" ] && ok "warn floor overridable (STORAGE_INVENTORY_FLOOR_WARN_GB=20: 15GB free -> ⚠️)" || bad "expected ⚠️ at 15GB with a 20GB warn floor, got '$(floor_in_fresh_shell 15.00 STORAGE_INVENTORY_FLOOR_WARN_GB=20)'"
[ "$(floor_in_fresh_shell 15.00 DOLT_DISK_FLOOR_WARN_GB=20)" = "⚠️" ] && ok "falls back to the guard's own DOLT_DISK_FLOOR_WARN_GB, so the two never disagree" || bad "expected the guard's env var to be honoured, got '$(floor_in_fresh_shell 15.00 DOLT_DISK_FLOOR_WARN_GB=20)'"
[ "$(floor_in_fresh_shell 100.00 STORAGE_INVENTORY_FLOOR_WARN_GB=lots)" = "N/A" ] && ok "a junk floor value -> N/A, never a silent ✅" || bad "expected N/A for a non-numeric floor, got '$(floor_in_fresh_shell 100.00 STORAGE_INVENTORY_FLOOR_WARN_GB=lots)'"

echo "── _swap_used_gb (fake sysctl vm.swapusage) ──"
OUT="$(_swap_used_gb)"
[ "$OUT" = "7.34 8.00" ] && ok "7514.25M used / 8192.00M total -> '7.34 8.00'" || bad "expected '7.34 8.00', got '$OUT'"
[ -z "$(FAKE_SYSCTL_FAIL=1 _swap_used_gb)" ] && ok "sysctl failure -> empty (N/A)" || bad "failed sysctl must give empty"
[ -z "$(FAKE_SWAP_LINE='garbage' _swap_used_gb)" ] && ok "unparseable sysctl line -> empty, never 0 swap" || bad "garbage line must give empty"

echo "── _du_gb <path> ──"
GB="$(_du_gb "$SCRATCH/dirA")"
case "$GB" in ''|*[!0-9.]*) bad "expected numeric GB for real dir, got '$GB'" ;; *) ok "real directory -> numeric GB ($GB)" ;; esac
[ -z "$(_du_gb "$SCRATCH/does-not-exist")" ] && ok "missing directory -> empty (not 0, not a crash)" || bad "missing dir should give empty"

echo "── _s3_bucket_gb <bucket> (fake aws) ──"
GB="$(FAKE_AWS_BYTES=2147483648 _s3_bucket_gb bucket-ok)"
[ "$GB" = "2.00" ] && ok "2GiB bucket parsed correctly" || bad "expected 2.00, got '$GB'"
[ -z "$(_s3_bucket_gb bucket-fail)" ] && ok "aws failure -> empty (SKIP, never a fabricated 0)" || bad "failed bucket should give empty"

echo "── _s3_total_gb (mixed success/failure across buckets) ──"
OUT="$(FAKE_AWS_BYTES=1073741824 _s3_total_gb)"
TOTAL="$(echo "$OUT" | awk '{print $1}')"; OKCOUNT="$(echo "$OUT" | awk '{print $2}')"; CNT="$(echo "$OUT" | awk '{print $3}')"
[ "$TOTAL" = "1.00" ] && [ "$OKCOUNT" = "1" ] && [ "$CNT" = "2" ] && ok "1/2 buckets measured -> total reflects only the successful one, count shows 1/2 (partial sum never looks complete)" || bad "expected '1.00 1 2', got '$OUT'"

echo "── _s3_bucket_noncurrent_gb (ga-utr9qf: noncurrent versions are BILLED but invisible to 's3 ls --recursive') ──"
GB="$(FAKE_AWS_NONCURRENT_PAGES="1073741824 1073741824 1073741824" _s3_bucket_noncurrent_gb bucket-ok)"
[ "$GB" = "3.00" ] && ok "one number per page is SUMMED across pages (3 x 1GiB -> 3.00)" || bad "expected 3.00, got '$GB'"
GB="$(FAKE_AWS_NONCURRENT_PAGES="0" _s3_bucket_noncurrent_gb bucket-ok)"
[ "$GB" = "0.00" ] && ok "measured-and-zero -> 0.00 (a real value, distinct from 'could not measure')" || bad "expected 0.00, got '$GB'"
[ -z "$(_s3_bucket_noncurrent_gb bucket-fail)" ] && ok "aws failure -> empty (SKIP, never a fabricated 0)" || bad "failed bucket should give empty"
[ -z "$(FAKE_AWS_NC_FAIL=1 _s3_bucket_noncurrent_gb bucket-ok)" ] && ok "s3api failure -> empty" || bad "s3api failure should give empty"
[ -z "$(FAKE_AWS_NC_EMPTY=1 _s3_bucket_noncurrent_gb bucket-ok)" ] && ok "exit 0 with NO output -> empty (cannot tell 'zero' from 'nothing came back')" || bad "silent success must give empty, got '$(FAKE_AWS_NC_EMPTY=1 _s3_bucket_noncurrent_gb bucket-ok)'"
[ -z "$(FAKE_AWS_NONCURRENT_PAGES="1073741824 None" _s3_bucket_noncurrent_gb bucket-ok)" ] && ok "a non-numeric page -> empty (fail-closed, not a silently dropped page)" || bad "non-numeric page must give empty"
GB="$(FAKE_AWS_NONCURRENT_PAGES="1073741824 1073741824" FAKE_AWS_NC_PARTIAL_FAIL=1 _s3_bucket_noncurrent_gb bucket-ok)"
[ -z "$GB" ] && ok "failure MID-pagination -> empty, a partial sum never passes for the total" || bad "mid-pagination failure must give empty, got partial sum '$GB'"

echo "── _s3_total_gb: billed = current + noncurrent ──"
OUT="$(FAKE_AWS_BYTES=1073741824 FAKE_AWS_NONCURRENT_PAGES="2147483648" _s3_total_gb)"
BILLED="$(echo "$OUT" | awk '{print $1}')"; CUR="$(echo "$OUT" | awk '{print $4}')"; NC="$(echo "$OUT" | awk '{print $5}')"
[ "$BILLED" = "3.00" ] && ok "1GiB current + 2GiB noncurrent -> billed 3.00 (the noncurrent bytes ARE in the reported total)" || bad "expected billed 3.00, got '$OUT'"
[ "$CUR" = "1.00" ] && [ "$NC" = "2.00" ] && ok "current (1.00) and noncurrent (2.00) are reported separately too" || bad "expected current 1.00 / noncurrent 2.00, got '$OUT'"
OUT="$(FAKE_AWS_BYTES=1073741824 FAKE_AWS_NC_FAIL=1 _s3_total_gb)"
[ -z "$OUT" ] && ok "current measured but noncurrent unmeasurable -> NO total (a current-only number must never pass for the billed one)" || bad "expected empty when noncurrent cannot be measured, got '$OUT'"

echo "── _drive_sa_quota (creds presence + fake python) ──"
[ -z "$(DRIVE_CREDS_PATH="$SCRATCH/no-such-creds.json" _drive_sa_quota)" ] && ok "missing creds file -> empty (SKIP, no fabricated quota)" || bad "missing creds should give empty"
touch "$DRIVE_CREDS_PATH"
OUT="$(FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" _drive_sa_quota)"
[ "$OUT" = "12.00 15.00 80.0" ] && ok "creds present + python succeeds -> parsed quota" || bad "expected '12.00 15.00 80.0', got '$OUT'"
[ -z "$(FAKE_DRIVE_FAIL=1 _drive_sa_quota)" ] && ok "python call fails -> empty (SKIP)" || bad "failed python call should give empty"

echo "── _motherduck_verdict (script presence + fake python) ──"
OUT="$(MOTHERDUCK_CHECK_SCRIPT="$SCRATCH/no-such-script.py" _motherduck_verdict)"
case "$OUT" in "N/A(script-ausente)") ok "missing script -> N/A(script-ausente), never a fabricated verdict" ;; *) bad "expected N/A(script-ausente), got '$OUT'" ;; esac
touch "$MOTHERDUCK_CHECK_SCRIPT"
OUT="$(FAKE_MD_JSON='{"projected_monthly_hours": 45.2, "threshold_hours": 92.0, "below_threshold": true}' FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" _motherduck_verdict)"
case "$OUT" in *"abaixo do teto"*) ok "below threshold -> verdict names it explicitly" ;; *) bad "expected 'abaixo do teto' verdict, got '$OUT'" ;; esac
OUT="$(FAKE_MD_FAIL=1 _motherduck_verdict)"
case "$OUT" in "N/A(falhou)") ok "python invocation fails -> N/A(falhou)" ;; *) bad "expected N/A(falhou), got '$OUT'" ;; esac

echo "── _extract_field <data_line> <key> ──"
LINE='<!-- storage-inventory:data mac_mini_used_gb=180.25 s3_total_gb=270.10 ts=2026-09-25 -->'
[ "$(_extract_field "$LINE" mac_mini_used_gb)" = "180.25" ] && ok "extracts mac_mini_used_gb" || bad "expected 180.25, got '$(_extract_field "$LINE" mac_mini_used_gb)'"
[ "$(_extract_field "$LINE" s3_total_gb)" = "270.10" ] && ok "extracts s3_total_gb" || bad "expected 270.10, got '$(_extract_field "$LINE" s3_total_gb)'"
[ -z "$(_extract_field "" mac_mini_used_gb)" ] && ok "empty data line -> empty (first run has no prior line)" || bad "empty line should give empty"

# ════════════════════════════════════════════════════════════════════════════
# 2. _update_doc_block — the SAFE-EDIT logic. This is the highest-risk
#    function (it rewrites a 562KB shared doc in production) so it gets the
#    most scrutiny: content OUTSIDE the block must survive byte-for-byte.
# ════════════════════════════════════════════════════════════════════════════
echo "── _update_doc_block: first run, no markers yet -> inserts before the anchor heading ──"
FIXTURE="$SCRATCH/fixture.md"
cat > "$FIXTURE" <<'EOF'
# Intro

## Parte 0: Mapa

| # | Local |
|---|---|
| 1 | Mac mini |

Some closing prose for Parte 0.

---

## Parte 1: SQLite — shared/data/

### classifications.db
Content here.
EOF
cp "$FIXTURE" "$SCRATCH/fixture-before.md"
BLOCK="$SCRATCH/block1.txt"
printf '%s\n' "$BEGIN_MARK" "<!-- storage-inventory:data mac_mini_used_gb=100 -->" "| a | b |" "$END_MARK" > "$BLOCK"
RESULT="$(_update_doc_block "$FIXTURE" "$BLOCK")"; RC=$?
[ "$RC" -eq 0 ] && [ "$RESULT" = "inserted" ] && ok "first run reports 'inserted'" || bad "expected rc=0/'inserted', got rc=$RC/'$RESULT'"
grep -qF "$BEGIN_MARK" "$FIXTURE" && grep -qF "$END_MARK" "$FIXTURE" && ok "markers now present in doc" || bad "markers missing after insert"
# Anchor and everything after it must be byte-identical to before.
diff <(sed -n '/## Parte 1: SQLite/,$p' "$SCRATCH/fixture-before.md") <(sed -n '/## Parte 1: SQLite/,$p' "$FIXTURE") >/dev/null \
  && ok "content from the anchor heading onward is untouched, byte-for-byte" || bad "anchor-onward content was mutated by the insert"
diff <(sed -n '1,/^## Parte 0/p' "$SCRATCH/fixture-before.md") <(sed -n '1,/^## Parte 0/p' "$FIXTURE") >/dev/null \
  && ok "content before Parte 0 is untouched" || bad "pre-Parte-0 content was mutated"
BEFORE_ANCHOR_LINE="$(grep -n '## Parte 1: SQLite' "$FIXTURE" | cut -d: -f1)"
BEGIN_LINE="$(grep -n -F "$BEGIN_MARK" "$FIXTURE" | cut -d: -f1)"
[ "$BEGIN_LINE" -lt "$BEFORE_ANCHOR_LINE" ] && ok "block was inserted BEFORE the anchor, not after" || bad "block landed after the anchor (BEGIN=$BEGIN_LINE ANCHOR=$BEFORE_ANCHOR_LINE)"

echo "── _update_doc_block: second run, markers already present -> replaces ONLY between them ──"
BLOCK2="$SCRATCH/block2.txt"
printf '%s\n' "$BEGIN_MARK" "<!-- storage-inventory:data mac_mini_used_gb=999 -->" "| NEW | ROW |" "$END_MARK" > "$BLOCK2"
cp "$FIXTURE" "$SCRATCH/fixture-after-first.md"
RESULT="$(_update_doc_block "$FIXTURE" "$BLOCK2")"; RC=$?
[ "$RC" -eq 0 ] && [ "$RESULT" = "replaced" ] && ok "second run reports 'replaced'" || bad "expected rc=0/'replaced', got rc=$RC/'$RESULT'"
grep -q "mac_mini_used_gb=999" "$FIXTURE" && ok "new data line replaced the old one" || bad "expected the new data line to be present"
grep -q "mac_mini_used_gb=100" "$FIXTURE" && bad "old data line should be GONE after replace" || ok "old data line correctly removed"
diff <(sed -n '/## Parte 1: SQLite/,$p' "$SCRATCH/fixture-after-first.md") <(sed -n '/## Parte 1: SQLite/,$p' "$FIXTURE") >/dev/null \
  && ok "anchor-onward content still untouched after a replace" || bad "replace mutated content outside the markers"
COUNT_BEGIN="$(grep -cF "$BEGIN_MARK" "$FIXTURE")"
[ "$COUNT_BEGIN" -eq 1 ] && ok "exactly one begin-marker after replace (no duplication)" || bad "expected exactly 1 begin-marker, found $COUNT_BEGIN"

echo "── _update_doc_block: neither markers nor anchor found -> fails closed, doc untouched ──"
NOANCHOR="$SCRATCH/no-anchor.md"
echo "# Just some doc with nothing recognizable" > "$NOANCHOR"
cp "$NOANCHOR" "$SCRATCH/no-anchor-before.md"
RESULT="$(_update_doc_block "$NOANCHOR" "$BLOCK")"; RC=$?
[ "$RC" -ne 0 ] && [ "$RESULT" = "anchor-nao-encontrado" ] && ok "no anchor/markers -> fails closed with a named reason" || bad "expected rc!=0/'anchor-nao-encontrado', got rc=$RC/'$RESULT'"
diff "$SCRATCH/no-anchor-before.md" "$NOANCHOR" >/dev/null && ok "doc left completely untouched when it can't safely write" || bad "doc was modified despite failing closed"

echo "── _update_doc_block: doc file missing -> fails closed ──"
RESULT="$(_update_doc_block "$SCRATCH/nope.md" "$BLOCK")"; RC=$?
[ "$RC" -ne 0 ] && [ "$RESULT" = "doc-missing" ] && ok "missing doc -> 'doc-missing', not a crash" || bad "expected 'doc-missing', got '$RESULT' rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# 3. _commit_doc — narrow, single-file commit discipline
# ════════════════════════════════════════════════════════════════════════════
echo "── _commit_doc: SKIP_GIT=1 short-circuits before touching git at all ──"
: > "$SCRATCH/fake-git.log"
RESULT="$(FAKE_GIT_LOG="$SCRATCH/fake-git.log" SKIP_GIT=1 _commit_doc "$DOC_PATH")"
[ "$RESULT" = "git-pulado(SKIP_GIT=1)" ] && ok "SKIP_GIT=1 -> skips git entirely" || bad "expected git-pulado, got '$RESULT'"
[ ! -s "$SCRATCH/fake-git.log" ] && ok "no git subcommand was invoked" || bad "git should not have been called"

echo "── _commit_doc: pull fails (diverged tree) -> aborts before staging anything ──"
: > "$SCRATCH/fake-git.log"
RESULT="$(FAKE_GIT_LOG="$SCRATCH/fake-git.log" FAKE_GIT_PULL_FAIL=1 _commit_doc "$DOC_PATH")"
[ "$RESULT" = "pull-nao-ff" ] && ok "non-ff pull -> aborts, named reason" || bad "expected pull-nao-ff, got '$RESULT'"
grep -q "add" "$SCRATCH/fake-git.log" && bad "should never reach 'add' after a failed pull" || ok "never staged anything after a failed pull"

echo "── _commit_doc: staged set unexpectedly includes more than our file -> resets and aborts ──"
RESULT="$(FAKE_GIT_STAGED="docs/data_dictionary.md docs/other.md" _commit_doc "$DOC_PATH")"
case "$RESULT" in staged-inesperado:*) ok "unexpected extra staged file -> aborts rather than committing someone else's change" ;; *) bad "expected staged-inesperado:*, got '$RESULT'" ;; esac

echo "── _commit_doc: clean single-file diff -> commits and pushes ──"
RESULT="$(_commit_doc "$DOC_PATH")"
[ "$RESULT" = "commitado" ] && ok "clean single-file change -> committed" || bad "expected commitado, got '$RESULT'"

echo "── _commit_doc: a hook prints multi-line noise on commit+push -> return channel stays clean ──"
# Live-caught regression (2026-08-26, real build-time verification run):
# whatsapp_automation's real pre-push hook prints a multi-line plist-audit
# report on every push. With commit/push stdout left inherited, that report
# became PART of commit_result via the caller's $(...) capture, so the
# `case "$commit_result" in commitado|...)` match failed on the polluted
# string and a fully successful push got misclassified as a failure -- the
# summary bead was filed as an open bug ("atencao necessaria") for a run
# that had nothing wrong with it. This is the exact scenario, reproduced
# hermetically.
RESULT="$(FAKE_GIT_HOOK_NOISE=1 _commit_doc "$DOC_PATH")"
[ "$RESULT" = "commitado" ] && ok "hook noise on commit+push never leaks into the return value" || bad "expected exactly 'commitado', got polluted result: '$RESULT'"

echo "── _commit_doc: empty staged diff -> no-op, not a failure ──"
RESULT="$(FAKE_GIT_DIFF_EMPTY=1 _commit_doc "$DOC_PATH")"
[ "$RESULT" = "sem-mudanca" ] && ok "nothing actually changed -> 'sem-mudanca', not an error" || bad "expected sem-mudanca, got '$RESULT'"

# ════════════════════════════════════════════════════════════════════════════
# 4. main() — end-to-end orchestration
# ════════════════════════════════════════════════════════════════════════════
echo "── main: clean run, everything within band -> exit 0, closed chore bead ──"
cat > "$DOC_PATH" <<'EOF'
# Intro

## Parte 0: Mapa

| # | Local |
|---|---|
| 1 | Mac mini |

---

## Parte 1: SQLite — shared/data/
EOF
: > "$SCRATCH/fake-bd.log"; : > "$STORAGE_INVENTORY_LOG"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "first-ever run (no baseline, nothing to compare) -> exit 0" || bad "expected exit 0, got $RC"
grep -qF "$BEGIN_MARK" "$DOC_PATH" && ok "doc now carries the auto-generated block" || bad "block missing from doc after main()"
grep -q "BD-CALLED.*create.*--type=chore" "$SCRATCH/fake-bd.log" && ok "clean run files a closed chore bead" || bad "expected a chore-type summary bead: $(cat "$SCRATCH/fake-bd.log")"

echo "── main: second run with a >20% jump in Mac mini usage -> exit nonzero, bug bead ──"
: > "$SCRATCH/fake-bd.log"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=157286400 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -ne 0 ] && ok "50%->75% used (+50%) trips the deviation alert -> nonzero exit" || bad "expected nonzero exit for a >20% jump, got $RC"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && grep -q "gastown.dog" "$SCRATCH/fake-bd.log" && ok "deviation run files an OPEN bug routed to gastown.dog" || bad "expected a bug-type summary bead routed to gastown.dog: $(cat "$SCRATCH/fake-bd.log")"

echo "── main: doc has no anchor/markers at all -> reports failure, never crashes ──"
echo "# nothing recognizable" > "$DOC_PATH"
: > "$SCRATCH/fake-bd.log"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -ne 0 ] && ok "unwritable doc -> nonzero exit rather than silently 'succeeding'" || bad "expected nonzero exit when the doc write itself fails"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "doc-write failure still files a bug summary bead" || bad "expected a bug-type summary bead for the doc-write failure"

echo "── main: baseline run for the N/A-collapse regression tests below ──"
cat > "$DOC_PATH" <<'EOF'
# Intro

## Parte 0: Mapa

| # | Local |
|---|---|
| 1 | Mac mini |

---

## Parte 1: SQLite — shared/data/
EOF
: > "$SCRATCH/fake-bd.log"; : > "$STORAGE_INVENTORY_LOG"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
[ $? -eq 0 ] && ok "baseline run for N/A-collapse tests below is clean" || bad "baseline setup run unexpectedly failed"

echo "── main: one vector fails (N/A) while all others are healthy -> must NOT report OK (GATE-FEEDBACK ga-z297h attempt 1, blocking issue 1) ──"
: > "$SCRATCH/fake-bd.log"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_FAIL=1 \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -ne 0 ] && ok "MotherDuck fails (N/A) even though every other vector is healthy -> nonzero exit, not silently OK" || bad "expected nonzero exit when one vector is N/A, got $RC"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "N/A-only run files an OPEN bug, not an auto-closed chore" || bad "expected a bug-type summary bead for a partial-N/A run: $(cat "$SCRATCH/fake-bd.log")"

echo "── main: mac-mini measurement fails this round -> next baseline must carry the LAST REAL value forward, never 0 (GATE-FEEDBACK ga-z297h attempt 1, blocking issue 2) ──"
: > "$SCRATCH/fake-bd.log"
FAKE_DF_FAIL=1 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -ne 0 ] && ok "mac-mini N/A this round -> nonzero exit" || bad "expected nonzero exit, got $RC"
DATA_LINE="$(grep -m1 '^<!-- storage-inventory:data ' "$DOC_PATH")"
PRESERVED="$(_extract_field "$DATA_LINE" mac_mini_used_gb)"
[ "$PRESERVED" = "100.00" ] && ok "failed measurement carries the last REAL baseline (100.00) forward, not a fabricated 0" || bad "expected mac_mini_used_gb=100.00 preserved, got '$PRESERVED' (data line: $DATA_LINE)"

echo "── main: mac-mini recovers next round -> must compare against the PRESERVED baseline, not a reset 'novo' ──"
: > "$SCRATCH/fake-bd.log"; : > "$STORAGE_INVENTORY_LOG"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main
RC=$?
[ "$RC" -eq 0 ] && ok "mac-mini back to 100.00 (same as the preserved baseline) -> healthy, exit 0" || bad "expected exit 0 once mac-mini recovers at the same value, got $RC"
grep -q "Mac mini:.*status=✅" "$STORAGE_INVENTORY_LOG" && ok "recovery run compares against the PRESERVED real baseline (status=✅), not a reset 'novo'" || bad "expected status=✅ against preserved baseline: $(grep 'Mac mini:' "$STORAGE_INVENTORY_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# 5. Header/legend duplication (ga-hdab26). The block file used to be written
#    as [### header, '', legend, '', BEGIN, data..., END]; the replace path
#    swapped the whole file in at BEGIN but left the OLD header/legend (which
#    sit BEFORE BEGIN in the doc) untouched -> +1 copy per run (4 copies by
#    2026-10-01). Every fixture above starts its block at BEGIN, so none of
#    them could see it. The header+legend now live INSIDE the markers.
# ════════════════════════════════════════════════════════════════════════════
HDR_RE='Última medição automatizada'
LEGEND_FIXED='Gerado por `storage-inventory-monthly.sh`'
_run_main_ok() {
  FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 \
    FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
    FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
}

echo "── main: 3 runs over the same doc -> exactly ONE header and ONE legend (ga-hdab26) ──"
cat > "$DOC_PATH" <<'EOF'
# Intro

## Parte 0: Mapa

| # | Local |
|---|---|
| 1 | Mac mini |

---

## Parte 1: SQLite — shared/data/
EOF
: > "$SCRATCH/fake-bd.log"; : > "$STORAGE_INVENTORY_LOG"
_run_main_ok; _run_main_ok; _run_main_ok
N_HDR="$(grep -c "$HDR_RE" "$DOC_PATH")"
N_LEGEND="$(grep -cF "$LEGEND_FIXED" "$DOC_PATH")"
[ "$N_HDR" -eq 1 ] && ok "3 runs -> exactly 1 'Última medição automatizada' header" || bad "expected 1 header after 3 runs, found $N_HDR"
[ "$N_LEGEND" -eq 1 ] && ok "3 runs -> exactly 1 legend line" || bad "expected 1 legend after 3 runs, found $N_LEGEND"
[ "$(grep -cF "$BEGIN_MARK" "$DOC_PATH")" -eq 1 ] && [ "$(grep -cF "$END_MARK" "$DOC_PATH")" -eq 1 ] && ok "still exactly one marker pair" || bad "marker pair duplicated or lost"
B="$(grep -nF "$BEGIN_MARK" "$DOC_PATH" | cut -d: -f1)"; E="$(grep -nF "$END_MARK" "$DOC_PATH" | cut -d: -f1)"; H="$(grep -n "$HDR_RE" "$DOC_PATH" | cut -d: -f1)"
{ [ "$H" -gt "$B" ] && [ "$H" -lt "$E" ]; } && ok "header lives INSIDE the markers (so a replace owns it)" || bad "header at line $H is outside markers ($B..$E)"

echo "── _update_doc_block: legacy doc with 4 stacked header/legend copies BEFORE begin -> heals to exactly one (ga-hdab26) ──"
LEGACY="$SCRATCH/legacy.md"
LEG_HDR='### Última medição automatizada (script mensal, ga-z297h)'
LEG_LEGEND='> Gerado por `storage-inventory-monthly.sh` (launchd `com.gascity.storage-inventory-monthly`, mensal). Não edite manualmente entre os marcadores — a próxima rodada sobrescreve. ⚠️ = vetor saiu de ±20% da rodada anterior.'
{
  printf '%s\n' "# Intro" "" "## Parte 0: Mapa" "" "| # | Local |" "|---|---|" "| 1 | Mac mini |" ""
  for _i in 1 2 3 4; do printf '%s\n' "$LEG_HDR" "" "$LEG_LEGEND" ""; done
  printf '%s\n' "$BEGIN_MARK" "<!-- storage-inventory:data mac_mini_used_gb=192.55 -->" "| old | row |" "$END_MARK" "" \
    "## Parte 1: SQLite — shared/data/" "" "### classifications.db" "Content here."
} > "$LEGACY"
cp "$LEGACY" "$SCRATCH/legacy-before.md"
NEWBLOCK="$SCRATCH/newblock.txt"
printf '%s\n' "$BEGIN_MARK" "$LEG_HDR" "" "$LEG_LEGEND" "" "<!-- storage-inventory:data mac_mini_used_gb=200 -->" "| new | row |" "$END_MARK" > "$NEWBLOCK"
RESULT="$(_update_doc_block "$LEGACY" "$NEWBLOCK")"; RC=$?
[ "$RC" -eq 0 ] && [ "$RESULT" = "replaced" ] && ok "legacy doc -> 'replaced'" || bad "expected rc=0/'replaced', got rc=$RC/'$RESULT'"
[ "$(grep -c "$HDR_RE" "$LEGACY")" -eq 1 ] && ok "4 stacked legacy headers collapse to exactly 1" || bad "expected 1 header, found $(grep -c "$HDR_RE" "$LEGACY")"
[ "$(grep -cF "$LEGEND_FIXED" "$LEGACY")" -eq 1 ] && ok "4 stacked legacy legends collapse to exactly 1" || bad "expected 1 legend, found $(grep -cF "$LEGEND_FIXED" "$LEGACY")"
grep -q "mac_mini_used_gb=200" "$LEGACY" && ! grep -q "mac_mini_used_gb=192.55" "$LEGACY" && ok "block data replaced as before" || bad "block data not replaced"
diff <(sed -n '/## Parte 1: SQLite/,$p' "$SCRATCH/legacy-before.md") <(sed -n '/## Parte 1: SQLite/,$p' "$LEGACY") >/dev/null \
  && ok "content from the anchor heading onward is byte-identical" || bad "migration mutated content after the block"
diff <(sed -n '1,/^| 1 | Mac mini |$/p' "$SCRATCH/legacy-before.md") <(sed -n '1,/^| 1 | Mac mini |$/p' "$LEGACY") >/dev/null \
  && ok "Part 0 (everything before the stale headers) is byte-identical" || bad "migration mutated Part 0"
cp "$LEGACY" "$SCRATCH/legacy-healed.md"
RESULT="$(_update_doc_block "$LEGACY" "$NEWBLOCK")"
diff "$SCRATCH/legacy-healed.md" "$LEGACY" >/dev/null && ok "re-running on the healed doc is a no-op (idempotent)" || bad "second replace changed an already-healed doc"

echo "── _update_doc_block: a header-like line NOT directly before begin is human content -> never touched (SAFE-EDIT) ──"
KEEP="$SCRATCH/keep.md"
{
  printf '%s\n' "# Intro" "" "$LEG_HDR" "" "Prosa escrita por um humano que NAO faz parte do bloco gerado." ""
  printf '%s\n' "$BEGIN_MARK" "<!-- storage-inventory:data mac_mini_used_gb=1 -->" "$END_MARK" "" "## Parte 1: SQLite — shared/data/"
} > "$KEEP"
RESULT="$(_update_doc_block "$KEEP" "$NEWBLOCK")"; RC=$?
[ "$RC" -eq 0 ] && grep -q "Prosa escrita por um humano" "$KEEP" && ok "human prose next to a header-like line survives" || bad "human prose was removed"
[ "$(grep -c "$HDR_RE" "$KEEP")" -eq 2 ] && ok "the header-like line outside the contiguous run is left alone (2 = human's + the block's own)" || bad "expected 2 headers (human + block), found $(grep -c "$HDR_RE" "$KEEP")"

# ════════════════════════════════════════════════════════════════════════════
# 6. ga-utr9qf — the inventory measured the WRONG PROXY and reported ✅ on a
#    critical state. Mac mini: 'Used of the Data volume / total' said 84% ✅
#    while the APFS container had 3.1 GB free. S3: `s3 ls --recursive` counts
#    CURRENT versions only (280 GB) while billing was ~1.9 TB.
# ════════════════════════════════════════════════════════════════════════════
fresh_doc() {
  cat > "$DOC_PATH" <<'EOF'
# Intro

## Parte 0: Mapa

| # | Local |
|---|---|
| 1 | Mac mini |

---

## Parte 1: SQLite — shared/data/
EOF
}

echo "── main (ga-utr9qf): Data 'used' ~84% of the container and UNCHANGED, but only ~3 GB FREE -> must NOT be ✅ / OK ──"
fresh_doc
: > "$SCRATCH/fake-bd.log"; : > "$STORAGE_INVENTORY_LOG"
# 228.27 GiB container, 192.55 GiB used by the Data volume (the literal ga-utr9qf numbers), plenty free.
FAKE_DF_TOTAL_KB=239366144 FAKE_DF_USED_KB=201900000 FAKE_DF_AVAIL_KB=104857600 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
[ $? -eq 0 ] && ok "healthy baseline (100 GiB free) -> exit 0" || bad "baseline run unexpectedly failed"
: > "$SCRATCH/fake-bd.log"
# Same Data usage (delta 0% -> the OLD script said ✅), but the container is down to ~2.9 GiB free.
FAKE_DF_TOTAL_KB=239366144 FAKE_DF_USED_KB=201900000 FAKE_DF_AVAIL_KB=3041280 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
RC=$?
[ "$RC" -ne 0 ] && ok "2.9 GiB free -> nonzero exit even though Data 'used' did not move" || bad "expected nonzero exit with ~3GB free, got $RC (the false-OK of ga-utr9qf)"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "files an OPEN bug, not an auto-closed chore" || bad "expected a bug-type summary bead: $(cat "$SCRATCH/fake-bd.log")"
FREE_ROW="$(grep -m1 'container livre' "$DOC_PATH")"
case "$FREE_ROW" in *"🔴"*) ok "the doc's container-free row is 🔴" ;; *) bad "expected 🔴 on the container-free row, got: '$FREE_ROW'" ;; esac
case "$FREE_ROW" in *"✅"*) bad "container-free row must not carry ✅ at 2.9 GiB free: '$FREE_ROW'" ;; *) ok "no ✅ on the container-free row" ;; esac
case "$FREE_ROW" in *"2.90"*) ok "row shows the FREE space (2.90 Gi), the number that matters" ;; *) bad "expected 2.90 in the row, got: '$FREE_ROW'" ;; esac
case "$FREE_ROW" in *"swap"*"7.34"*) ok "row also shows swap pressure (7.34 of 8.00 Gi)" ;; *) bad "expected swap usage in the row, got: '$FREE_ROW'" ;; esac

echo "── main (ga-utr9qf): container free space unmeasurable -> N/A and nonzero, never silently healthy ──"
fresh_doc
: > "$SCRATCH/fake-bd.log"
FAKE_DF_FAIL=1 FAKE_AWS_BYTES=1073741824 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
[ $? -ne 0 ] && ok "df failure -> nonzero" || bad "expected nonzero when free space cannot be measured"
FREE_ROW="$(grep -m1 'container livre' "$DOC_PATH")"
case "$FREE_ROW" in *"N/A"*) ok "container-free row says N/A" ;; *) bad "expected N/A in the container-free row, got '$FREE_ROW'" ;; esac

echo "── main (ga-utr9qf): noncurrent S3 versions swell the BILLED total -> reported, and trips the deviation band ──"
fresh_doc
: > "$SCRATCH/fake-bd.log"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 FAKE_AWS_NONCURRENT_PAGES="0" \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
[ $? -eq 0 ] && ok "baseline (1 GiB current, 0 noncurrent) -> exit 0" || bad "S3 baseline run unexpectedly failed"
: > "$SCRATCH/fake-bd.log"
# current stays 1 GiB (the OLD script's number -> delta 0%), but 5 GiB of noncurrent versions appear: billed 1 -> 6.
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 FAKE_AWS_NONCURRENT_PAGES="5368709120" \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
RC=$?
[ "$RC" -ne 0 ] && ok "5 GiB of noncurrent versions (billed 1.00 -> 6.00) -> nonzero exit" || bad "expected nonzero exit when billed storage jumps +500% behind an unchanged 'current' total, got $RC"
grep -q "BD-CALLED.*create.*--type=bug" "$SCRATCH/fake-bd.log" && ok "files an OPEN bug" || bad "expected a bug-type summary bead: $(cat "$SCRATCH/fake-bd.log")"
DATA_LINE="$(grep -m1 '^<!-- storage-inventory:data ' "$DOC_PATH")"
[ "$(_extract_field "$DATA_LINE" s3_billed_gb)" = "6.00" ] && ok "data line records s3_billed_gb=6.00 as the new baseline" || bad "expected s3_billed_gb=6.00, data line: $DATA_LINE"
[ "$(_extract_field "$DATA_LINE" s3_total_gb)" = "1.00" ] && ok "s3_total_gb keeps its meaning (current versions only) for baseline continuity" || bad "expected s3_total_gb=1.00, data line: $DATA_LINE"
grep -q "S3 faturado" "$DOC_PATH" && ok "doc table names the billed total" || bad "expected an 'S3 faturado' row in the doc"
grep -q "S3 só versões correntes" "$DOC_PATH" && ok "doc table still shows the current-versions-only total next to it" || bad "expected an 'S3 só versões correntes' row in the doc"

echo "── main (ga-utr9qf): noncurrent versions unmeasurable on every bucket -> S3 is N/A, run is NOT OK ──"
: > "$SCRATCH/fake-bd.log"
FAKE_DF_TOTAL_KB=209715200 FAKE_DF_USED_KB=104857600 FAKE_AWS_BYTES=1073741824 FAKE_AWS_NC_FAIL=1 \
  FAKE_DRIVE_OUTPUT="12.00 15.00 80.0" FAKE_MD_VERDICT="45.2h/mes projetado (abaixo do teto 92h)" \
  FAKE_BD_LOG="$SCRATCH/fake-bd.log" main >/dev/null
[ $? -ne 0 ] && ok "billed total unknown -> nonzero (a current-only number is not a substitute)" || bad "expected nonzero when noncurrent bytes cannot be measured"
DATA_LINE="$(grep -m1 '^<!-- storage-inventory:data ' "$DOC_PATH")"
[ "$(_extract_field "$DATA_LINE" s3_billed_gb)" = "6.00" ] && ok "failed S3 round carries the last REAL billed baseline (6.00) forward, not 0" || bad "expected s3_billed_gb=6.00 preserved, data line: $DATA_LINE"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
