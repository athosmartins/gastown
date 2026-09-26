#!/bin/bash
# jsonl-export.selftest.sh — unit tests for ensure_archive_pack_config(), the
# ga-gtrc8n fix that makes the git-maintenance pack.threads/windowMemory/
# deltaCacheSize bound durable across archive-repo deletion+recreation.
#
# Hermetic: sources jsonl-export.sh in library mode (JSONL_EXPORT_LIB=1),
# which returns before dolt-target.sh is sourced — no live Dolt server, port
# resolution, or GC_CITY_PATH is ever required. Real dolt/git-push/mail/nudge
# are NEVER called; only throwaway repos under a temp directory are touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/jsonl-export.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Runs "$@" as a command after sourcing jsonl-export.sh in library mode, in a
# subshell — so the sourced script's `set -euo pipefail` never leaks into
# this selftest's own shell, and each call starts from a clean function/var
# state.
lib_call() {
  (
    export JSONL_EXPORT_LIB=1
    . "$SCRIPT" >/dev/null 2>&1
    "$@"
  )
}

echo "=== jsonl-export.selftest.sh ==="

if lib_call type ensure_archive_pack_config >/dev/null 2>&1; then
  ok "ensure_archive_pack_config defined by lib-mode source"
else
  bad "ensure_archive_pack_config NOT defined — lib mode broken, or fix not yet implemented"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── AC1: a freshly created repo (the real "git init" + call path) is born ────
# ── with all three keys ───────────────────────────────────────────────────────
FRESH_REPO="$WORK/fresh-repo"
mkdir -p "$FRESH_REPO"
git -C "$FRESH_REPO" init -q
lib_call ensure_archive_pack_config "$FRESH_REPO"

threads=$(git -C "$FRESH_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
window=$(git -C "$FRESH_REPO" config --get pack.windowMemory 2>/dev/null || echo "MISSING")
deltacache=$(git -C "$FRESH_REPO" config --get pack.deltaCacheSize 2>/dev/null || echo "MISSING")

[ "$threads" = "2" ] \
  && ok "fresh repo: pack.threads = 2" \
  || bad "fresh repo: pack.threads = '$threads', want '2'"
[ "$window" = "256m" ] \
  && ok "fresh repo: pack.windowMemory = 256m" \
  || bad "fresh repo: pack.windowMemory = '$window', want '256m'"
[ "$deltacache" = "64m" ] \
  && ok "fresh repo: pack.deltaCacheSize = 64m" \
  || bad "fresh repo: pack.deltaCacheSize = '$deltacache', want '64m'"

# ── AC2: a pre-existing repo WITHOUT the keys (simulates a repo created ──────
# ── before this fix shipped) gains them on its next execution ────────────────
EXISTING_REPO="$WORK/existing-repo"
mkdir -p "$EXISTING_REPO"
git -C "$EXISTING_REPO" init -q
if git -C "$EXISTING_REPO" config --get pack.threads >/dev/null 2>&1; then
  bad "test setup invalid: existing-repo already has pack.threads before the fix runs"
else
  ok "test setup: existing-repo has no pack.threads before the fix runs (sanity check)"
fi

lib_call ensure_archive_pack_config "$EXISTING_REPO"
threads2=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")
[ "$threads2" = "2" ] \
  && ok "pre-existing repo without keys: gains pack.threads = 2 on next execution" \
  || bad "pre-existing repo without keys: pack.threads = '$threads2', want '2'"

# ── AC3: idempotent — calling it again does not duplicate or change values ──
lib_call ensure_archive_pack_config "$EXISTING_REPO"
lib_call ensure_archive_pack_config "$EXISTING_REPO"

value_count=$(git -C "$EXISTING_REPO" config --get-all pack.threads | wc -l | tr -d ' ')
threads3=$(git -C "$EXISTING_REPO" config --get pack.threads 2>/dev/null || echo "MISSING")

[ "$value_count" = "1" ] \
  && ok "idempotent: pack.threads has exactly one value after repeated calls (no duplication)" \
  || bad "idempotent: pack.threads has $value_count values after repeated calls, want 1"
[ "$threads3" = "2" ] \
  && ok "idempotent: pack.threads still = 2 after repeated calls" \
  || bad "idempotent: pack.threads = '$threads3' after repeated calls, want '2'"

# ── ga-fxrrav: a SHORT export must not replace the previous snapshot ────────
# Runs the WHOLE script (not lib mode) against a stub dolt-target.sh and a stub
# `gc`, so no live Dolt, mail or nudge is touched. The stub `dolt_sql` answers
# from STUB_EXPORT_ROWS (rows in the issues export) and STUB_SOURCE_COUNT (the
# source-of-truth COUNT(*); "ERR" makes it unreadable).
E2E="$WORK/e2e"
mkdir -p "$E2E/scripts" "$E2E/bin" "$E2E/city" "$E2E/state"
cp "$SCRIPT" "$E2E/scripts/jsonl-export.sh"
cat > "$E2E/scripts/dolt-target.sh" <<'STUB'
dolt_sql() {
  local q=""
  while [ $# -gt 0 ]; do
    case "$1" in -q) q="$2"; shift ;; esac
    shift
  done
  case "$q" in
    "SHOW DATABASES") printf 'Database\nwa\n' ;;
    "SELECT COUNT(*)"*)
      [ "$STUB_SOURCE_COUNT" = "ERR" ] && return 1
      printf 'row_count\n%s\n' "$STUB_SOURCE_COUNT" ;;
    "SELECT * FROM \`wa\`.issues"*)
      jq -n -c --argjson n "$STUB_EXPORT_ROWS" \
        '{rows: [range($n) | {id: "wa-\(.)", title: "real issue \(.)", issue_type: "task"}]}' ;;
    "SELECT * FROM"*) printf '{"rows":[]}\n' ;;
    *) return 1 ;;
  esac
}
has_wisps_table() { return 0; }
STUB
cat > "$E2E/bin/gc" <<'STUB'
#!/bin/sh
echo "gc $*" >> "$E2E_GC_LOG"
exit 0
STUB
chmod +x "$E2E/bin/gc"

ARCH="$E2E/archive"
OUT=""
run_export() {  # run_export <export-rows> <source-count|ERR>
  : > "$E2E/gc.log"
  OUT=$(
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS="$1" STUB_SOURCE_COUNT="$2" \
    PATH="$E2E/bin:$PATH" GC_CITY="$E2E/city" GC_PACK_STATE_DIR="$E2E/state" \
    GC_JSONL_ARCHIVE_REPO="$ARCH" \
    bash "$E2E/scripts/jsonl-export.sh" 2>&1
  )
  RC=$?
}
head_rows()  { git -C "$ARCH" show HEAD:wa/issues.jsonl 2>/dev/null | jq -s -r '.[0].rows | length' 2>/dev/null || echo "?"; }
file_rows()  { jq -s -r '.[0].rows | length' "$ARCH/wa/issues.jsonl" 2>/dev/null || echo "?"; }
flat_rows()  { jq -s -r '.[0].rows | length' "$ARCH/wa.jsonl" 2>/dev/null || echo "?"; }
commits()    { git -C "$ARCH" rev-list --count HEAD 2>/dev/null || echo 0; }
mailed()     { grep -c 'mail send' "$E2E/gc.log" 2>/dev/null || true; }

# Baseline: a full export (200 rows, source agrees) becomes the first snapshot.
run_export 200 200
[ "$(head_rows)" = "200" ] && [ "$(file_rows)" = "200" ] \
  && ok "e2e baseline: full export archived (200 rows)" \
  || bad "e2e baseline: head=$(head_rows) file=$(file_rows), want 200/200 (rc=$RC): $OUT"
BASE_COMMITS=$(commits)

# Case 1 — short export, source still full (source 200 >= previous 200): the
# old code suppressed the halt but still wrote the 120-row file as the snapshot.
# 120 (not smaller) keeps the short snapshot above MIN_PREV_FOR_SPIKE_CHECK, so
# the old code's follow-up complete export is judged against it — as in prod.
run_export 120 200
[ "$(file_rows)" = "200" ] \
  && ok "short export (source >= prev): issues.jsonl keeps the previous 200 rows" \
  || bad "short export (source >= prev): issues.jsonl has $(file_rows) rows, want 200 — short export was written as snapshot"
[ "$(flat_rows)" = "200" ] \
  && ok "short export (source >= prev): flat wa.jsonl keeps the previous 200 rows" \
  || bad "short export (source >= prev): wa.jsonl has $(flat_rows) rows, want 200"
[ "$(head_rows)" = "200" ] \
  && ok "short export (source >= prev): archive HEAD still holds the 200-row snapshot" \
  || bad "short export (source >= prev): HEAD holds $(head_rows) rows, want 200 — truncated snapshot committed"
[ -z "$(git -C "$ARCH" status --porcelain)" ] \
  && ok "short export (source >= prev): archive working tree is clean" \
  || bad "short export (source >= prev): archive working tree is dirty: $(git -C "$ARCH" status --porcelain | tr '\n' ' ')"
case "$OUT" in
  *"export curto de wa: 120 vs fonte 200"*"mantido o snapshot anterior"*)
    ok "short export (source >= prev): logs 'export curto de wa: 120 vs fonte 200, mantido o snapshot anterior'" ;;
  *) bad "short export (source >= prev): missing 'export curto' log line. Output: $OUT" ;;
esac
case "$OUT" in
  *HALTED*) bad "short export (source >= prev): must not HALT (it is not a spike alarm)" ;;
  *) ok "short export (source >= prev): no HALT" ;;
esac
[ "$RC" = "0" ] \
  && ok "short export (source >= prev): exits 0" \
  || bad "short export (source >= prev): rc=$RC, want 0"
[ "$(commits)" = "$BASE_COMMITS" ] \
  && ok "short export (source >= prev): no new archive commit" \
  || bad "short export (source >= prev): commits went $BASE_COMMITS -> $(commits)"

# Case 2 — the next, complete export must NOT read as a growth spike.
run_export 200 200
case "$OUT" in
  *HALTED*) bad "recovery after short export: complete 200-row export raised a HALT (false growth spike): $OUT" ;;
  *) ok "recovery after short export: complete export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] \
  && ok "recovery after short export: no spike mail sent" \
  || bad "recovery after short export: $(mailed) spike mail(s) sent"

# Case 3 — the other suppression branch: source dropped a little (5% <= 20%)
# while the export dropped a lot (40%) — still a short export.
run_export 120 190
[ "$(file_rows)" = "200" ] && [ "$(head_rows)" = "200" ] \
  && ok "short export (source drop <= threshold): previous 200-row snapshot kept" \
  || bad "short export (source drop <= threshold): file=$(file_rows) head=$(head_rows), want 200/200"

# Case 4 — a REAL drop (source fell 50%, export agrees) must still HALT and be
# recorded, so a genuine shrink is never silently swallowed by the new keep-
# previous path.
run_export 100 100
case "$OUT" in
  *HALTED*) ok "real drop (source fell with the export): still HALTs" ;;
  *) bad "real drop: expected HALT, got: $OUT" ;;
esac
[ "$(head_rows)" = "100" ] \
  && ok "real drop: HALT baseline commit records the 100-row export (existing behaviour kept)" \
  || bad "real drop: HEAD holds $(head_rows) rows, want 100"
[ "$(mailed)" -ge 1 ] \
  && ok "real drop: spike alert mail sent" \
  || bad "real drop: no spike alert mail sent"

# Case 5 — source unreadable: no way to tell short from real, so the existing
# halt is preserved (third state must not collapse into 'short export').
run_export 20 ERR
case "$OUT" in
  *HALTED*) ok "unreadable source: HALT preserved" ;;
  *) bad "unreadable source: expected HALT, got: $OUT" ;;
esac

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
