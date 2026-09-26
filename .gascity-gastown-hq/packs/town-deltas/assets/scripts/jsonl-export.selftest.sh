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
      # STUB_TEST_ROWS extra rows are ones the SQL filter lets through but the
      # jq scrub (title ^test_) removes — like a real store's leftover fixtures.
      jq -n -c --argjson n "$STUB_EXPORT_ROWS" --argjson t "${STUB_TEST_ROWS:-0}" \
        '{rows: ([range($n) | {id: "wa-\(.)", title: "real issue \(.)", issue_type: "task"}]
                 + [range($t) | {id: "wa-t\(.)", title: "test_\(.)", issue_type: "task"}])}' ;;
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
run_export() {  # run_export <export-rows> <source-count|ERR> [scrubbed-away-rows]
  : > "$E2E/gc.log"
  OUT=$(
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS="$1" STUB_SOURCE_COUNT="$2" STUB_TEST_ROWS="${3:-0}" \
    PATH="$E2E/bin:$PATH" GC_CITY="$E2E/city" GC_PACK_STATE_DIR="${E2E_STATE:-$E2E/state}" \
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
# ga-7sxdmb: the HALT is not the only trace of the don't-know — the export was also
# never checked against the source, and every place that reports the run says so.
case "$OUT" in
  *"source count unavailable for wa"*"NOT verified against source"*)
    ok "unreadable source (HALT path): logs that the export was NOT verified against the source" ;;
  *) bad "unreadable source (HALT path): no 'NOT verified against source' log line. Output: $OUT" ;;
esac
grep -q 'DOG_DONE:.*HALTED.*unverified: wa' "$E2E/gc.log" \
  && ok "unreadable source (HALT path): the DOG_DONE nudge names 'unverified: wa'" \
  || bad "unreadable source (HALT path): DOG_DONE nudge lacks 'unverified: wa'. gc log: $(cat "$E2E/gc.log")"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unreadable source (HALT path): the HALT commit message records unverified=wa" \
  || bad "unreadable source (HALT path): HALT commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"

# ── ga-7sxdmb: a partial export must never become the baseline, at ANY size ──
# ga-fxrrav discards a short export only when its drop trips the spike check
# (> SPIKE_THRESHOLD vs the previous snapshot). A truncated export that lost
# 15-20% slips under it, is committed as the new baseline, and the next COMPLETE
# export then reads as > 20% growth — a false HIGH escalation, same family. The
# gate is now the export against the SOURCE count, independent of the previous
# snapshot and of the threshold. Each scenario starts from its own archive.
fresh_archive() {  # fresh_archive <name>
  ARCH="$E2E/archive-$1"
  E2E_STATE="$E2E/state-$1"
  mkdir -p "$E2E_STATE"
}

# Case 6 — 800 of 1000 rows: exactly 20% short, so DELTA == 20 is NOT > 20 and
# the spike check never runs. Source is full (1000).
fresh_archive subthreshold
run_export 1000 1000
[ "$(head_rows)" = "1000" ] \
  && ok "sub-threshold: baseline full export archived (1000 rows)" \
  || bad "sub-threshold: baseline head=$(head_rows), want 1000 (rc=$RC): $OUT"
BASE_COMMITS=$(commits)
run_export 800 1000
[ "$(file_rows)" = "1000" ] && [ "$(flat_rows)" = "1000" ] \
  && ok "sub-threshold short export (800 of 1000): both files keep the previous 1000 rows" \
  || bad "sub-threshold short export: issues.jsonl=$(file_rows) wa.jsonl=$(flat_rows), want 1000/1000 — partial export written as snapshot"
[ "$(head_rows)" = "1000" ] && [ "$(commits)" = "$BASE_COMMITS" ] \
  && ok "sub-threshold short export: archive HEAD unchanged, no new commit" \
  || bad "sub-threshold short export: HEAD holds $(head_rows) rows, commits $BASE_COMMITS -> $(commits) — partial snapshot committed"
case "$OUT" in
  *"export curto de wa: 800 vs fonte 1000"*"mantido o snapshot anterior"*)
    ok "sub-threshold short export: logs 'export curto de wa: 800 vs fonte 1000, mantido o snapshot anterior'" ;;
  *) bad "sub-threshold short export: missing 'export curto' log line. Output: $OUT" ;;
esac
case "$OUT" in
  *HALTED*) bad "sub-threshold short export: must not HALT" ;;
  *) ok "sub-threshold short export: no HALT" ;;
esac
# Case 7 — the next, complete export must not read as growth.
run_export 1000 1000
case "$OUT" in
  *HALTED*) bad "recovery after sub-threshold short export: complete export raised a HALT (false growth spike): $OUT" ;;
  *) ok "recovery after sub-threshold short export: complete export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] \
  && ok "recovery after sub-threshold short export: no spike mail sent" \
  || bad "recovery after sub-threshold short export: $(mailed) spike mail(s) sent"

# Case 8 — the literal ga-7sxdmb sequence (WA 5423 -> 505 -> 5425): the 505 must
# not become the base, so the 5425 export is not a +974% "spike".
fresh_archive sequence
run_export 5423 5423
run_export 505 5423
[ "$(head_rows)" = "5423" ] \
  && ok "ga-7sxdmb sequence: the 505-row export is not committed (HEAD keeps 5423)" \
  || bad "ga-7sxdmb sequence: HEAD holds $(head_rows) rows after the 505-row export, want 5423"
run_export 5425 5425
case "$OUT" in
  *HALTED*) bad "ga-7sxdmb sequence: the 5425-row export raised a HALT (false +974% spike): $OUT" ;;
  *) ok "ga-7sxdmb sequence: the 5425-row export does not HALT" ;;
esac
[ "$(mailed)" = "0" ] && [ "$(head_rows)" = "5425" ] \
  && ok "ga-7sxdmb sequence: no spike mail, HEAD advances to 5425" \
  || bad "ga-7sxdmb sequence: mails=$(mailed) head=$(head_rows), want 0 / 5425"

# Case 9 — the gate must not become the load it guards: an export a few rows
# under the source (rows removed while it ran) is a fine snapshot, not a stall.
fresh_archive churn
run_export 1000 1000
run_export 996 1000
[ "$(head_rows)" = "996" ] \
  && ok "churn: 996 of 1000 (0.4% under the source) is accepted as the new snapshot" \
  || bad "churn: HEAD holds $(head_rows) rows, want 996 — the gate discarded an export within the slack"
case "$OUT" in
  *"export curto"*) bad "churn: 996 of 1000 must not be reported as a short export: $OUT" ;;
  *) ok "churn: no 'export curto' for an export within the slack" ;;
esac

# Case 10 — the comparison is raw-export vs source (same SQL filter), NOT the
# post-scrub count: 30 rows the SQL lets through and the jq scrub removes must
# not read as a short export (that would discard every run of a store that
# carries a few leftover fixtures).
fresh_archive scrub
run_export 1000 1000
run_export 1000 1030 30
[ "$(file_rows)" = "1000" ] \
  && ok "scrub offset: scrubbed file has the 1000 real rows" \
  || bad "scrub offset: issues.jsonl has $(file_rows) rows, want 1000"
case "$OUT" in
  *"export curto"*|*"failed:"*) bad "scrub offset: rows removed by the scrub read as a short export: $OUT" ;;
  *) ok "scrub offset: 1030 raw rows vs source 1030 is a complete export" ;;
esac

# Case 11 — WHERE the archive lives. gc runs an order with GC_PACK_STATE_DIR set to
# the pack that OWNS the order (town-deltas), so a default derived from it forks
# the archive away from the one scripts/dolt-s3-backup.sh mirrors offsite (and
# dolt-gc-maintenance.sh archives pruned rows into, when enabled). The default
# must be the mirrored path.
CITY2="$E2E/city-default"
TD_STATE="$CITY2/.gc/runtime/packs/town-deltas"
mkdir -p "$TD_STATE"
: > "$E2E/gc.log"
OUT=$(
  env -u GC_JSONL_ARCHIVE_REPO -u GC_CITY_RUNTIME_DIR \
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS=200 STUB_SOURCE_COUNT=200 STUB_TEST_ROWS=0 \
    PATH="$E2E/bin:$PATH" GC_CITY="$CITY2" GC_PACK_STATE_DIR="$TD_STATE" \
    bash "$E2E/scripts/jsonl-export.sh" 2>&1
)
RC=$?
MIRROR_REL=$(sed -n 's|^JSONL_ARCHIVE_DIR="\$CITY/\(.*\)"$|\1|p' "$HERE/../../../../scripts/dolt-s3-backup.sh" 2>/dev/null)
if [ -z "$MIRROR_REL" ]; then
  bad "default archive: could not read JSONL_ARCHIVE_DIR from scripts/dolt-s3-backup.sh — cannot tell where the offsite mirror reads"
else
  [ -d "$CITY2/$MIRROR_REL/.git" ] \
    && ok "default archive: with GC_PACK_STATE_DIR=<town-deltas> the export lands in $MIRROR_REL (what the offsite mirror reads)" \
    || bad "default archive: nothing at $CITY2/$MIRROR_REL (rc=$RC) — export forked the archive. Output: $OUT"
fi
[ ! -e "$TD_STATE/jsonl-archive" ] \
  && ok "default archive: no second archive under the owning pack's state dir" \
  || bad "default archive: a forked archive appeared at $TD_STATE/jsonl-archive"

# ── ga-7sxdmb gate round 2: the THIRD STATE of the partial-export gate ───────────
# The gate compares the export with the source's COUNT(*). When that count cannot be
# read the gate cannot tell a partial export from a complete one. It used to answer
# "not short" and commit the export with NO trace: byte-for-byte the output of a
# verified-complete export. A failing count query is likeliest exactly when Dolt is
# loaded — the truncation the gate exists for. The don't-know must be NAMED wherever
# the run is reported: the log, the DOG_DONE summary, the archive commit message.
# (Whether an unverifiable export still becomes the snapshot is deliberate — see the
# comment on the gate in jsonl-export.sh; these cases pin that behaviour too.)
unverified_seen() {  # unverified_seen <label> — the run's outputs all name the don't-know
  case "$OUT" in
    *"source count unavailable for wa"*"NOT verified against source"*)
      ok "$1: logs 'source count unavailable for wa; export NOT verified against source'" ;;
    *) bad "$1: no 'NOT verified against source' log line — a don't-know that looks like success. Output: $OUT" ;;
  esac
  case "$OUT" in
    *"unverified: wa"*) ok "$1: the run summary names 'unverified: wa'" ;;
    *) bad "$1: run summary lacks 'unverified: wa'. Output: $OUT" ;;
  esac
  grep -q 'DOG_DONE:.*unverified: wa' "$E2E/gc.log" \
    && ok "$1: the DOG_DONE nudge names 'unverified: wa'" \
    || bad "$1: DOG_DONE nudge lacks 'unverified: wa'. gc log: $(cat "$E2E/gc.log")"
}

# Case 12 — the reviewer's repro: 850 of 1000 rows, source count unreadable.
fresh_archive unknown-partial
run_export 1000 1000
case "$OUT$(cat "$E2E/gc.log")" in
  *unverified*|*"NOT verified"*) bad "verified export: must not carry the unverified marker (it would be always-on noise): $OUT" ;;
  *) ok "verified export: no unverified marker anywhere (the signal is not always-on)" ;;
esac
BASE_COMMITS=$(commits)
run_export 850 ERR
[ "$RC" = "0" ] \
  && ok "unverified partial (850, source ERR): exits 0" \
  || bad "unverified partial: rc=$RC, want 0"
unverified_seen "unverified partial (850, source ERR)"
[ "$(head_rows)" = "850" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "unverified partial: archived as the snapshot, as documented (HEAD 850, +1 commit)" \
  || bad "unverified partial: HEAD holds $(head_rows) rows, commits $BASE_COMMITS -> $(commits) — documented behaviour is 'archived, flagged'"
git -C "$ARCH" log -1 --format=%s | grep -q 'unverified=wa' \
  && ok "unverified partial: the archive commit message records unverified=wa" \
  || bad "unverified partial: commit message lacks unverified=wa: $(git -C "$ARCH" log -1 --format=%s)"

# Case 13 — first run (no previous snapshot, so no spike check at all), source unreadable.
fresh_archive unknown-first
run_export 200 ERR
unverified_seen "unverified first run (200, source ERR)"
[ "$(head_rows)" = "200" ] \
  && ok "unverified first run: the export is archived (HEAD 200)" \
  || bad "unverified first run: HEAD holds $(head_rows) rows, want 200"

# Cases 14/15 — the run ends WITHOUT a new commit (identical export): the signal must
# still reach the report. Two exits, so two cases: with an archive push still pending,
# and with none pending.
fresh_archive unknown-nochange
run_export 300 300
run_export 300 ERR
unverified_seen "unverified, nothing new to commit (300, source ERR)"
[ "$RC" = "0" ] \
  && ok "unverified, nothing new to commit: exits 0" \
  || bad "unverified, nothing new to commit: rc=$RC, want 0"

fresh_archive unknown-nopending
run_export 300 300
# Clear the pending-push marker (the archive has no origin, so nothing is "local-only"
# either) and the next run takes the plain "no changes" exit.
STATE_JSON="$E2E_STATE/jsonl-export-state.json"
if [ "$(jq -r '.pending_archive_push // false' "$STATE_JSON" 2>/dev/null)" != "true" ]; then
  bad "test setup invalid: no pending_archive_push in $STATE_JSON after the baseline commit"
fi
jq 'del(.pending_archive_push)' "$STATE_JSON" > "$STATE_JSON.tmp" && mv -f "$STATE_JSON.tmp" "$STATE_JSON"
run_export 300 ERR
case "$OUT" in
  *"push:"*) bad "test setup invalid: the run did not take the plain no-changes exit (it reported a push status): $OUT" ;;
esac
unverified_seen "unverified, plain no-changes exit (300, source ERR)"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
