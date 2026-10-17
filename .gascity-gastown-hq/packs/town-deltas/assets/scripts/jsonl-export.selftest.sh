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

# ── ga-wkoij7: the repo is born (and a pre-existing one gains it) with NO background maintenance: a plain commit must not start a geometric repack at noon ──
# vazio → the key is not set (MISSING, and the assertion fails); falhou (git config cannot read) → also MISSING, same failure
ma=$(git -C "$FRESH_REPO" config --get maintenance.auto 2>/dev/null || echo "MISSING")
ga=$(git -C "$FRESH_REPO" config --get gc.auto 2>/dev/null || echo "MISSING")
[ "$ma" = "false" ] \
  && ok "fresh repo: maintenance.auto = false (ga-wkoij7)" \
  || bad "fresh repo: maintenance.auto = '$ma', want 'false'"
[ "$ga" = "0" ] \
  && ok "fresh repo: gc.auto = 0 (ga-wkoij7)" \
  || bad "fresh repo: gc.auto = '$ga', want '0'"
git -C "$EXISTING_REPO" config maintenance.auto true     # an operator (or git) left the old value: the next run must put it back
git -C "$EXISTING_REPO" config gc.auto 6700
lib_call ensure_archive_pack_config "$EXISTING_REPO"
ma2=$(git -C "$EXISTING_REPO" config --get maintenance.auto 2>/dev/null || echo "MISSING")
ga2=$(git -C "$EXISTING_REPO" config --get gc.auto 2>/dev/null || echo "MISSING")
[ "$ma2" = "false" ] && [ "$ga2" = "0" ] \
  && ok "pre-existing repo with the git defaults: the next run sets maintenance.auto=false and gc.auto=0 in place" \
  || bad "pre-existing repo: maintenance.auto='$ma2' gc.auto='$ga2', want false/0"
[ "$(git -C "$EXISTING_REPO" config --get-all maintenance.auto | wc -l | tr -d ' ')" = "1" ] \
  && ok "maintenance.auto stays a single value (replaced, not added)" \
  || bad "maintenance.auto has several values after repeated calls"

# ── ga-fxrrav: a SHORT export must not replace the previous snapshot ────────
# Runs the WHOLE script (not lib mode) against a stub dolt-target.sh and a stub
# `gc`, so no live Dolt, mail or nudge is touched. The stub `dolt_sql` answers
# from STUB_EXPORT_ROWS (rows in the issues export) and STUB_SOURCE_COUNT (the
# source-of-truth COUNT(*); "ERR" makes it unreadable).
E2E="$WORK/e2e"
mkdir -p "$E2E/scripts" "$E2E/bin" "$E2E/city" "$E2E/state"
cp "$SCRIPT" "$E2E/scripts/jsonl-export.sh"
cp "$HERE/jsonl-archive-repack-window-lib.sh" "$E2E/scripts/jsonl-archive-repack-window-lib.sh"   # ga-wkoij7: sourced by the exporter at start
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
      # ga-aai87v: STUB_KILL_SELF=1 is the engine's SIGKILL at the order's timeout — the exporter dies mid-export, no trap runs,
      # and its scratch file stays wherever the exporter put it.
      [ "${STUB_KILL_SELF:-0}" = "1" ] && kill -9 $$
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
# ga-ck3sz7: the exporter runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh). It mails the Mayor
# (`gc mail send`) when an export comes up short; if $E2E/bin/gc vanished under it, the real `gc` further down
# $PATH would send that mail for real. Here "command not found" is the only outcome.
. "$HERE/../selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $HERE/../selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$E2E" git jq || exit 2   # git: the archive repo; jq: row scrub; dolt is the stubbed dolt-target.sh, gc the stub above

ARCH="$E2E/archive"
OUT=""
run_export() {  # run_export <export-rows> <source-count|ERR> [scrubbed-away-rows]
  : > "$E2E/gc.log"
  OUT=$(
    E2E_GC_LOG="$E2E/gc.log" STUB_EXPORT_ROWS="$1" STUB_SOURCE_COUNT="$2" STUB_TEST_ROWS="${3:-0}" \
    PATH="$SANDBOX_PATH" GC_CITY="$E2E/city" GC_PACK_STATE_DIR="${E2E_STATE:-$E2E/state}" \
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
    PATH="$SANDBOX_PATH" GC_CITY="$CITY2" GC_PACK_STATE_DIR="$TD_STATE" \
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

# ── ga-aai87v: the export's scratch file never reaches the archive ───────────
# The exporter wrote its scratch file (issues.jsonl.tmp.XXXXXX) INSIDE the archive, in the directory `git add -A -- <db>` stages. The engine's SIGKILL at the order's
# timeout runs no trap, the file stayed, and the NEXT run's commit took it: 19 of them (16 MB) sat in the archive's HEAD and went offsite with the S3 mirror. The kill is
# simulated for real (STUB_KILL_SELF makes the stub SIGKILL the exporter mid-export), so these cases do not depend on where the file is put.
echo "=== ga-aai87v: the scratch issues.jsonl.tmp.* of a killed export never reaches the archive ==="
scratch_archive() {  # scratch_archive <name> — a fresh archive with its own scratch dir
  fresh_archive "$1"
  E2E_TMPD="$E2E/scratch-$1"
  export GC_JSONL_EXPORT_TMP_DIR="$E2E_TMPD"
}
# vazio → no scratch file under the given dirs; falhou (find could not read a dir) → the output starts with "find failed:", so a failed find is never read as "empty"
stray_in() {
  local out
  out=$(find "$@" -name 'issues.jsonl.tmp.*' -not -path '*/.git/*' 2>&1) || out="find failed: $out"
  printf '%s\n' "$out" | sed '/^$/d'
}
# vazio → 0 scratch files in HEAD; falhou/ilegível (HEAD or ls-tree unreadable) → prints "?", which none of the "= 0" / "= 1" assertions accept
tracked_stray() {
  local names
  names=$(git -C "$ARCH" ls-tree -r --name-only HEAD 2>/dev/null) || { echo "?"; return 0; }
  printf '%s\n' "$names" | grep -c 'issues\.jsonl\.tmp\.' || true
}
# vazio → archive working tree clean; falhou (git status errors) → prints "git status failed", so a broken repo is never read as clean
dirty_tree() {
  local out
  out=$(git -C "$ARCH" status --porcelain 2>&1) || out="git status failed: $out"
  printf '%s' "$out"
}
git_fixture()    { git -C "$ARCH" -c user.name=fixture -c user.email=fixture@localhost -c maintenance.auto=false "$@"; }

# Case 1 — the real sequence: a run is SIGKILLed mid-export, the next run commits.
scratch_archive killed
run_export 200 200
BASE_COMMITS=$(commits)
export STUB_KILL_SELF=1
run_export 201 201
unset STUB_KILL_SELF
[ "$RC" != "0" ] \
  && ok "killed export: the run died mid-export (rc=$RC)" \
  || bad "test setup invalid: the simulated SIGKILL did not stop the exporter (rc=0): $OUT"
[ -n "$(stray_in "$ARCH" "$E2E_TMPD")" ] \
  && ok "killed export: the dead run left its scratch file behind (the case under test exists)" \
  || bad "test setup invalid: no scratch file anywhere after the killed run"
[ -z "$(stray_in "$ARCH")" ] \
  && ok "killed export: the scratch file is NOT under the archive (outside everything git add stages)" \
  || bad "killed export: scratch file left inside the archive: $(stray_in "$ARCH" | tr '\n' ' ')"
run_export 201 201
[ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "after a killed export: the next export commits its snapshot (201 rows, one new commit)" \
  || bad "after a killed export: head=$(head_rows) commits $BASE_COMMITS -> $(commits), want 201 rows and +1 commit (rc=$RC): $OUT"
[ "$(tracked_stray)" = "0" ] \
  && ok "after a killed export: the snapshot commit holds no scratch file" \
  || bad "after a killed export: the archive HEAD tracks $(tracked_stray) scratch file(s): $(git -C "$ARCH" ls-tree -r --name-only HEAD | grep 'issues\.jsonl\.tmp\.' | tr '\n' ' ')"
[ -z "$(dirty_tree)" ] \
  && ok "after a killed export: archive working tree is clean" \
  || bad "after a killed export: archive working tree is dirty: $(dirty_tree | tr '\n' ' ')"

# Case 2 — what production holds today: scratch files already in HEAD (19) and one untracked. The next snapshot commit drops them; their blobs stay in history.
scratch_archive legacy
run_export 200 200
printf 'junk' > "$ARCH/wa/issues.jsonl.tmp.TRKD01"
git_fixture add -f -- wa/issues.jsonl.tmp.TRKD01 >/dev/null 2>&1 \
  && git_fixture commit -q -m "fixture: a scratch file already in HEAD" >/dev/null 2>&1
printf 'junk' > "$ARCH/wa/issues.jsonl.tmp.UNTR02"
[ "$(tracked_stray)" = "1" ] \
  && ok "legacy leftovers: fixture has 1 scratch file in HEAD and 1 untracked" \
  || bad "test setup invalid: tracked_stray=$(tracked_stray), want 1"
BASE_COMMITS=$(commits)
run_export 201 201
[ "$(tracked_stray)" = "0" ] \
  && ok "legacy leftovers: the next snapshot commit drops the tracked scratch file from HEAD" \
  || bad "legacy leftovers: HEAD still tracks $(tracked_stray) scratch file(s)"
[ -z "$(stray_in "$ARCH")" ] \
  && ok "legacy leftovers: no scratch file left in the archive working tree (tracked or untracked)" \
  || bad "legacy leftovers: still in the working tree: $(stray_in "$ARCH" | tr '\n' ' ')"
[ "$(head_rows)" = "201" ] && [ "$(commits)" = "$((BASE_COMMITS + 1))" ] \
  && ok "legacy leftovers: the real snapshot (201 rows) still commits, one new commit" \
  || bad "legacy leftovers: head=$(head_rows) commits $BASE_COMMITS -> $(commits), want 201 rows and +1 commit (rc=$RC): $OUT"
[ -z "$(dirty_tree)" ] \
  && ok "legacy leftovers: archive working tree is clean" \
  || bad "legacy leftovers: archive working tree is dirty: $(dirty_tree | tr '\n' ' ')"

# Case 3 — a dead run's leftover in the scratch dir is swept once it is old enough that no live run can own it; a fresh one (a run still going) is left alone.
scratch_archive sweep
mkdir -p "$E2E_TMPD"
printf 'old' > "$E2E_TMPD/issues.jsonl.tmp.OLD000"; touch -t 200001010000 "$E2E_TMPD/issues.jsonl.tmp.OLD000"
printf 'live' > "$E2E_TMPD/issues.jsonl.tmp.LIVE00"
run_export 200 200
[ ! -e "$E2E_TMPD/issues.jsonl.tmp.OLD000" ] \
  && ok "scratch sweep: a leftover older than the sweep age is removed" \
  || bad "scratch sweep: the old leftover is still there"
[ -e "$E2E_TMPD/issues.jsonl.tmp.LIVE00" ] \
  && ok "scratch sweep: a fresh scratch file (a run still going) is left alone" \
  || bad "scratch sweep: a fresh scratch file was deleted — it could belong to a live run"

# Case 4 — default location (no override) is the archive's sibling, and a clean run leaves nothing in it.
unset GC_JSONL_EXPORT_TMP_DIR
fresh_archive defaultdir
run_export 200 200
DEFAULT_TMPD="$(dirname "$ARCH")/.jsonl-export-tmp"
[ -d "$DEFAULT_TMPD" ] \
  && ok "default scratch dir: <archive's parent>/.jsonl-export-tmp is created" \
  || bad "default scratch dir: $DEFAULT_TMPD does not exist after a run (rc=$RC): $OUT"
# vazio → the dir is empty (a clean run left nothing); falhou (ls cannot read it) → also empty, but the -d assertion just above already failed for a missing dir
[ -z "$(ls -A "$DEFAULT_TMPD" 2>/dev/null)" ] \
  && ok "default scratch dir: a clean run leaves nothing in it" \
  || bad "default scratch dir: a clean run left: $(ls -A "$DEFAULT_TMPD" | tr '\n' ' ')"

# Case 5 — the scratch dir cannot be created: the run says so and exports nothing (the archive keeps its last snapshot), instead of falling back to a path inside the archive.
fresh_archive noscratch
run_export 200 200
BASE_COMMITS=$(commits)
printf 'not a dir' > "$E2E/scratch-is-a-file"
GC_JSONL_EXPORT_TMP_DIR="$E2E/scratch-is-a-file/sub" run_export 201 201
[ "$RC" != "0" ] && case "$OUT" in *"cannot create the scratch dir"*) true ;; *) false ;; esac \
  && ok "scratch dir not creatable: exits non-zero and names the scratch dir" \
  || bad "scratch dir not creatable: rc=$RC, want non-zero with 'cannot create the scratch dir'. Output: $OUT"
[ "$(head_rows)" = "200" ] && [ "$(commits)" = "$BASE_COMMITS" ] && [ -z "$(stray_in "$ARCH")" ] \
  && ok "scratch dir not creatable: archive untouched (HEAD still 200 rows, no new commit, nothing written inside)" \
  || bad "scratch dir not creatable: head=$(head_rows) commits $BASE_COMMITS -> $(commits) stray=$(stray_in "$ARCH" | tr '\n' ' ')"

# ga-8z0hy7 — a commit that lands while jsonl-archive-compact.sh runs must not start git's background maintenance.
# `git commit` runs `git maintenance run --auto --quiet --detach`; on git 2.54 that is a geometric repack which merges and deletes the loose-*.pack batch
# packs, for 19+ minutes and with no lock file, and a compactor gc that is running meanwhile dies with "could not find pack 'loose-....pack'". trace2 logs the
# spawn as a child_start event of the committing process itself, synchronously (the detached process logs later), so that is what is counted — not a process listing.
echo "=== ga-8z0hy7: a commit during a compaction run starts no background maintenance; outside one it still does ==="
maint_spawns() {  # maint_spawns <trace2 file> — how many times that run's git commit started `git maintenance run --auto`
  local n; n="$(grep -c '"maintenance","run","--auto"' "$1" 2>/dev/null)"; echo "${n:-0}"
}
maint_case() {  # maint_case <name> — one fresh archive, one export (its first commit), trace2 into $E2E/t2-<name>.json; JAC_LOCK is whatever the caller exported
  fresh_archive "maint-$1"
  : > "$E2E/t2-$1.json"
  GIT_TRACE2_EVENT="$E2E/t2-$1.json" run_export 300 300
}
DEAD_PID="$(sh -c 'echo $$')"      # a pid that was alive a moment ago and is gone now
kill -0 "$DEAD_PID" 2>/dev/null && DEAD_PID=999999

# ga-wkoij7: a commit starts git's maintenance only inside the night window with room on the disk. The lock cases below pin the compaction-lock logic alone, so the window is held OPEN
# with room (the clock and the free space are seams); the window's own cases follow them.
export JAW_HOUR=2 JAW_FREE_KIB=99999999
export JAC_LOCK="$E2E/lock-absent"
maint_case nolock
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-nolock.json")" -ge 1 ] \
  && ok "no compaction lock, window open with room: the commit starts git's background maintenance (consolidation is not switched off)" \
  || bad "no lock, window open: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-nolock.json") — want 1 commit and a maintenance run started: $OUT"

export JAC_LOCK="$E2E/lock-live"; mkdir -p "$JAC_LOCK"; echo "$$" > "$JAC_LOCK/pid"
maint_case live
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-live.json")" -eq 0 ] \
  && ok "a live compactor holds its lock: the commit is made and starts NO background maintenance" \
  || bad "live lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-live.json") — want 1 commit and 0 maintenance runs started: $OUT"
case "$OUT" in *"compaction run is in flight"*) ok "the run says why (a compaction run is in flight)" ;; *) bad "no 'compaction run is in flight' line in the output: $OUT" ;; esac

export JAC_LOCK="$E2E/lock-dead"; mkdir -p "$JAC_LOCK"; echo "$DEAD_PID" > "$JAC_LOCK/pid"
maint_case dead
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-dead.json")" -ge 1 ] \
  && ok "a lock whose owner is dead (a run killed by the order's timeout) does not hold git's consolidation off — the commit starts it" \
  || bad "dead-owner lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-dead.json") — want 1 commit and a maintenance run started: $OUT"

export JAC_LOCK="$E2E/lock-nopid"; mkdir -p "$JAC_LOCK"
maint_case nopid
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-nopid.json")" -eq 0 ] \
  && ok "a lock directory with no pid file (its mkdir, not yet its pid write; or unreadable) counts as in flight — under doubt, no background run" \
  || bad "no-pid lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-nopid.json") — want 1 commit and 0 maintenance runs started: $OUT"

export JAC_LOCK="$E2E/lock-junk"; mkdir -p "$JAC_LOCK"; echo "not-a-pid" > "$JAC_LOCK/pid"
maint_case junk
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-junk.json")" -eq 0 ] \
  && ok "a pid file that holds no number counts as in flight as well" \
  || bad "junk-pid lock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-junk.json") — want 1 commit and 0 maintenance runs started: $OUT"
unset JAC_LOCK

# ga-wkoij7 — outside the night window, or without room for a repack, a commit starts NO background maintenance even with no compactor running. The repo the exporter works on already
# carries maintenance.auto=false (ensure_archive_pack_config), so the open-window cases below prove that `-c maintenance.auto=true` on the commit beats it; the closed cases are
# proven twice — on that repo, and (keyless_commit, further down) on a repo that does not carry the keys.
echo "=== ga-wkoij7: a commit starts git's repack only in the 00:00-04:59 start window with room on the disk ==="
export JAC_LOCK="$E2E/lock-absent"
WIN_LOG="$E2E/city/.gc/logs/jsonl-archive-repack-window.log"
window_case() {  # window_case <name> <JAW_HOUR> <JAW_FREE_KIB> — one fresh archive, one export, the window seams as given; trace2 in $E2E/t2-<name>.json
  rm -f "$WIN_LOG"
  JAW_HOUR="$2" JAW_FREE_KIB="$3" maint_case "$1"
}
window_case win-open 2 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-open.json")" -ge 1 ] \
  && ok "02h with 95GB free: the commit starts git's maintenance (maintenance.auto=true on that commit, over the repo's own false)" \
  || bad "02h, room: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-open.json") — want 1 commit and a maintenance run: $OUT"
grep -q 'repack allowed' "$WIN_LOG" 2>/dev/null \
  && ok "the allowed repack is on record in the window log" \
  || bad "no 'repack allowed' line in $WIN_LOG"
window_case win-noon 12 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noon.json")" -eq 0 ] \
  && ok "12h with room: the commit is made and starts NO background maintenance (the incident of 17/10)" \
  || bad "12h: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noon.json") — want 1 commit and 0 maintenance runs: $OUT"
case "$OUT" in *"outside the start window"*) ok "the run says why (outside the start window)" ;; *) bad "no 'outside the start window' line: $OUT" ;; esac
[ ! -e "$WIN_LOG" ] \
  && ok "an outside-the-window refusal (20 hours a day) is not written to the window log" \
  || bad "the window log was written for an outside-the-window refusal: $(cat "$WIN_LOG")"
window_case win-noroom 2 1000
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noroom.json")" -eq 0 ] \
  && ok "02h but 1000KiB free: the commit is made and starts NO background maintenance" \
  || bad "02h, no room: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noroom.json") — want 1 commit and 0 maintenance runs: $OUT"
grep -q 'INSIDE the window' "$WIN_LOG" 2>/dev/null \
  && ok "the night's refused repack is on record in the window log (why it did not run)" \
  || bad "no 'INSIDE the window' line in $WIN_LOG"
window_case win-nofree 2 abc
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-nofree.json")" -eq 0 ] && case "$OUT" in *"cannot be read"*) true ;; *) false ;; esac \
  && ok "free space that cannot be read: no repack, and the run says it cannot read it (under doubt, inert)" \
  || bad "unreadable free space: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-nofree.json") — want 1 commit, 0 runs, 'cannot be read': $OUT"
window_case win-noclock xx 99999999
[ "$(commits)" = "1" ] && [ "$(maint_spawns "$E2E/t2-win-noclock.json")" -eq 0 ] \
  && ok "a clock that cannot be read: no repack" \
  || bad "unreadable clock: commits=$(commits) spawns=$(maint_spawns "$E2E/t2-win-noclock.json") — want 1 commit and 0 maintenance runs: $OUT"
window_case win-h04 4 99999999
[ "$(maint_spawns "$E2E/t2-win-h04.json")" -ge 1 ] \
  && ok "04h (last hour to start): allowed" \
  || bad "04h: spawns=$(maint_spawns "$E2E/t2-win-h04.json"), want >= 1: $OUT"
window_case win-h05 5 99999999
[ "$(maint_spawns "$E2E/t2-win-h05.json")" -eq 0 ] \
  && ok "05h (a repack started now would run past 06:00): refused" \
  || bad "05h: spawns=$(maint_spawns "$E2E/t2-win-h05.json"), want 0: $OUT"
# A repo recreated WITHOUT the two keys (the exporter recreates it when .git goes missing; ensure_archive_pack_config runs only afterwards): the commit itself must start nothing outside the
# window, by its own -c flags. commit_archive_snapshot lives past the library-mode return, so its text is lifted out of the script and run against a bare repo with no keys.
keyless_commit() {  # keyless_commit <name> <JAW_HOUR> — one commit in a fresh repo with NO maintenance/gc keys; trace2 in $E2E/t2-<name>.json
  local kr="$E2E/keyless-$1"
  mkdir -p "$kr" && git -C "$kr" init -q && : > "$E2E/t2-$1.json"
  printf 'x\n' > "$kr/f.txt" && git -C "$kr" add f.txt
  (
    . "$HERE/jsonl-archive-repack-window-lib.sh"
    eval "$(sed -n '/^compaction_in_flight() {/,/^}/p;/^commit_archive_snapshot() {/,/^}/p' "$SCRIPT")"
    COMPACT_LOCK="$E2E/lock-absent"; ARCHIVE_REPO="$kr"; JAW_LOG=""
    cd "$kr" && JAW_HOUR="$2" JAW_FREE_KIB=99999999 GIT_TRACE2_EVENT="$E2E/t2-$1.json" commit_archive_snapshot "keyless" "selftest"
  ) >/dev/null 2>&1
}
keyless_commit keyless-open 2
[ "$(git -C "$E2E/keyless-keyless-open" rev-list --count HEAD 2>/dev/null)" = "1" ] && [ "$(maint_spawns "$E2E/t2-keyless-open.json")" -ge 1 ] \
  && ok "keyless repo, 02h: the commit starts maintenance (the spawn detector sees it)" \
  || bad "keyless repo, 02h: commits=$(git -C "$E2E/keyless-keyless-open" rev-list --count HEAD 2>/dev/null) spawns=$(maint_spawns "$E2E/t2-keyless-open.json") — want 1 and >= 1"
keyless_commit keyless-noon 12
[ "$(git -C "$E2E/keyless-keyless-noon" rev-list --count HEAD 2>/dev/null)" = "1" ] && [ "$(maint_spawns "$E2E/t2-keyless-noon.json")" -eq 0 ] \
  && ok "keyless repo, 12h: the commit starts NO maintenance on its own flags (git's default would have)" \
  || bad "keyless repo, 12h: commits=$(git -C "$E2E/keyless-keyless-noon" rev-list --count HEAD 2>/dev/null) spawns=$(maint_spawns "$E2E/t2-keyless-noon.json") — want 1 and 0"
unset JAC_LOCK JAW_HOUR JAW_FREE_KIB

# the lib is not optional: an exporter that cannot load it must stop, not commit with a gate that is silently absent
mkdir -p "$E2E/scripts-nolib"; cp "$SCRIPT" "$E2E/scripts-nolib/jsonl-export.sh"
NOLIB_OUT="$(PATH="$SANDBOX_PATH" GC_CITY="$E2E/city" bash "$E2E/scripts-nolib/jsonl-export.sh" 2>&1)"; NOLIB_RC=$?
[ "$NOLIB_RC" -ne 0 ] && case "$NOLIB_OUT" in *"cannot load"*"jsonl-archive-repack-window-lib.sh"*) true ;; *) false ;; esac \
  && ok "no window lib next to the exporter: it exits non-zero and names the missing file" \
  || bad "no lib: rc=$NOLIB_RC, want non-zero with 'cannot load ...jsonl-archive-repack-window-lib.sh': $NOLIB_OUT"

# The cases above point BOTH scripts at one directory with JAC_LOCK, so nothing in them would notice the two DEFAULTS drifting apart — and then the exporter would look for a lock the
# compactor never takes, and every commit would start the background repack again with all of the above still green. So: the same environment, the default path each one derives.
# (--print-config prints the compactor's effective `lock=`; the exporter's is the one assignment, evaluated here with the city and runtime variables it reads.)
echo "=== ga-8z0hy7: the exporter looks for the compaction lock where the compactor takes it (default paths) ==="
CMP_SCRIPT="$HERE/jsonl-archive-compact.sh"
EXP_LOCK_LINE="$(grep -E '^COMPACT_LOCK=' "$SCRIPT")"
lock_paths_agree() {  # lock_paths_agree <label> <city dir> <runtime dir or ""> — the runtime variable is exported only when given
  local label="$1" city="$2" rt="$3" exp_path cmp_path
  exp_path="$( unset JAC_LOCK GC_CITY_RUNTIME_DIR; [ -n "$rt" ] && export GC_CITY_RUNTIME_DIR="$rt"; CITY="$city"; eval "$EXP_LOCK_LINE"; printf '%s' "${COMPACT_LOCK:-}" )"
  cmp_path="$( unset JAC_LOCK JAC_STATE JAC_LOG GC_CITY_RUNTIME_DIR; [ -n "$rt" ] && export GC_CITY_RUNTIME_DIR="$rt"; GC_CITY_PATH="$city" "$CMP_SCRIPT" --print-config 2>/dev/null | sed -n 's/.* lock=//p' )"
  if [ -n "$exp_path" ] && [ "$exp_path" = "$cmp_path" ]; then ok "$label: both resolve to $exp_path"
  else bad "$label: the exporter looks at [$exp_path], the compactor takes [$cmp_path] — a commit would never see the compaction lock"; fi
}
lock_paths_agree "runtime dir given (GC_CITY_RUNTIME_DIR, as the supervisor sets it)" "$E2E/city-x" "$E2E/runtime-x"
lock_paths_agree "no runtime dir given (derived from the city)" "$E2E/city-y" ""

echo "=== ga-48e0du: the order declares a timeout the run fits in — and one that cannot stack ==="
# With no `timeout` the engine kills an exec order at 300 s (orders.Order.TimeoutOrDefault; see mol-dog-reaper.toml, ga-x2fj8h). The exporter commits ONLY after every database has been
# exported (the one commit_archive_snapshot after the loop), so a run killed before that leaves the files written and NOTHING committed: on 2026-10-16 the archive HEAD froze at 12:08:15Z while
# eight runs in a row were killed at 5m02s-5m06s (`gc order history jsonl-export`; the last run that finished took 4m07s, so the ceiling was already 82% used). The data did not grow
# (hq/issues.jsonl 71.39 -> 71.97 MB between the last commit and the fix); the host load did (84 on 10 cores). A run now needs about 6-8 minutes — an ESTIMATE from file mtimes, not a stopwatch.
# The script has no single-flight lock, so the timeout must also stay under the 15 m interval: two exports in one git working tree is the ga-fxrrav failure.
ORDER_TOML="$HERE/../../orders/jsonl-export.toml"
order_field() {  # order_field <file> <key> — the value of `key = "..."` on a non-comment line (a `# key = ...` line does not count)
  # vazio → prints nothing (the caller turns that into "not declared"); falhou/ilegível → the caller checks the file is readable BEFORE calling, so nothing here is read from a missing file
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([0-9a-z]*)"?.*$/\1/'
}
dur_s() {  # dur_s <Ns|Nm|Nh> — seconds on stdout; returns 1 (prints nothing) for empty or anything that is not one plain duration
  # 10# on purpose: a leading zero ("0840s") is decimal here, not an octal error in $(( ))
  case "$1" in ''|*[!0-9smh]*) return 1 ;; esac
  local n="${1%[smh]}" u="${1: -1}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in s) echo $((10#$n)) ;; m) echo $((10#$n * 60)) ;; h) echo $((10#$n * 3600)) ;; *) return 1 ;; esac
}
order_timeout_verdict() {  # order_timeout_verdict <order toml> — "ok", or the reason it is not. Every doubt is a reason: nothing here defaults to ok.
  local f="$1" t i ts is
  [ -r "$f" ] || { echo "cannot read $f"; return 0; }
  t="$(order_field "$f" timeout)"; i="$(order_field "$f" interval)"
  [ -n "$t" ] || { echo "no timeout declared: the engine's 300 s default applies"; return 0; }
  ts="$(dur_s "$t")" || { echo "timeout '$t' is not one plain Ns/Nm/Nh duration"; return 0; }
  is="$(dur_s "$i")" || { echo "interval '$i' unreadable: cannot tell whether runs can stack"; return 0; }
  [ "$ts" -ge 600 ] || { echo "timeout ${ts}s is under 600 s: a run needs about 6-8 min"; return 0; }
  [ "$ts" -lt "$is" ] || { echo "timeout ${ts}s is not under the ${is}s interval and the script has no lock: two exports could overlap"; return 0; }
  echo ok
}
v="$(order_timeout_verdict "$ORDER_TOML")"
[ "$v" = ok ] && ok "jsonl-export.toml: timeout declared, at least 600 s, and under the interval" || bad "jsonl-export.toml: $v"
# the check bites: each of these order files must be refused for its own reason, and only the sound ones pass
mk_order() {  # mk_order <name> <interval value or ""> <timeout line or ""> — writes $WORK/order-<name>.toml and prints its path
  { printf '[order]\nexec = "x"\ntrigger = "cooldown"\n'; [ -n "$2" ] && printf 'interval = "%s"\n' "$2"; [ -n "$3" ] && printf '%s\n' "$3"; } > "$WORK/order-$1.toml"
  printf '%s' "$WORK/order-$1.toml"
}
expect_verdict() {  # expect_verdict <label> <file> <"ok" | substring of the reason>
  local got; got="$(order_timeout_verdict "$2")"
  if [ "$3" = ok ]; then [ "$got" = ok ] && ok "$1 -> ok" || bad "$1 -> '$got', wanted ok"
  else case "$got" in *"$3"*) ok "$1 -> refused ($3)" ;; *) bad "$1 -> '$got', wanted a refusal naming '$3'" ;; esac; fi
}
expect_verdict "no timeout line"                          "$(mk_order none 15m '')"                                         "no timeout declared"
expect_verdict "only a commented-out timeout"             "$(mk_order commented 15m '# timeout = "840s"')"                  "no timeout declared"
expect_verdict "timeout 300s (the engine default)"        "$(mk_order t300 15m 'timeout = "300s"')"                         "under 600"
expect_verdict "timeout equal to the interval"            "$(mk_order teq 15m 'timeout = "900s"')"                          "not under"
expect_verdict "timeout above the interval"               "$(mk_order t1800 15m 'timeout = "1800s"')"                       "not under"
expect_verdict "timeout 'ten' (not a duration)"           "$(mk_order tten 15m 'timeout = "ten"')"                          "not one plain"
expect_verdict "timeout 1h30m (compound, not accepted)"   "$(mk_order tcomp 15m 'timeout = "1h30m"')"                       "not one plain"
expect_verdict "no interval at all"                       "$(mk_order noint '' 'timeout = "840s"')"                         "interval '' unreadable"
expect_verdict "order file missing"                       "$WORK/order-does-not-exist.toml"                                 "cannot read"
expect_verdict "timeout 840s"                             "$(mk_order t840 15m 'timeout = "840s"')"                         ok
expect_verdict "timeout 14m, trailing comment"            "$(mk_order t14m 15m 'timeout = "14m"   # headroom, see the header')" ok
expect_verdict "timeout 0840s (leading zero is decimal)"  "$(mk_order t0840 15m 'timeout = "0840s"')"                       ok

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
