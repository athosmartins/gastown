#!/usr/bin/env bash
# reaper-schema-purge.selftest.sh — regression test for ga-u8nbt9.
#
# THE BUG (measured live 2026-09-19): the maintenance reaper did
#   has_dependency_target_column ... || continue      # "Skip silently"
# and the probe demanded a `depends_on_id` column. bd split that column into
# depends_on_issue_id / depends_on_wisp_id / depends_on_external, so EVERY database
# was skipped before any step ran — no purge, no anomaly, no mail. hq.wisps grew to
# 23k rows (99% closed) and every scan-shaped wisps read slowed to 5-30 s.
#
# This test runs the REAL scripts/reaper.sh against throwaway local Dolt repos
# (multi-database mode: `dolt sql` from the parent directory, no server) with stub
# `gc`/`bd` and a stub dolt-target.sh. The fixture schema mirrors the live one for
# every column the reaper reads (bd 1.1.0, 2026-09-19), trimmed to those columns.
# REAPER_SH overrides the script under test — run it against the embedded original
# (.gc/system/packs/maintenance/assets/scripts/reaper.sh) to see the red side.
#
# R1  split schema, default age: purges old closed wisps AND their labels/comments/
#     events/edges (no orphans); keeps a recent one, closed MAIL (ga-3rqwa), a
#     closed parent that still has an OPEN child, and open wisps; a closed row with
#     NULL closed_at is not immortal; a NULL depends_on_wisp_id (issue-parent edge)
#     does not stop the purge (the NOT IN trap); Step 1 still closes a stale child
#     of a closed parent; issue steps stay OFF (no `bd close`) and the summary says so.
# R2  chunking: a per-run cap leaves work for the next run and says so (capped).
# R3  an UNRECOGNISED schema is an anomaly, counted, mailed ONCE (deduped) — never a
#     silent skip — and nothing is deleted.
# R4  the legacy depends_on_id schema still works.
# R5  dry run deletes nothing and reports would_purge.
# R6  GC_REAPER_ISSUE_STEPS=1 closes a stale issue (and NULL edges in `dependencies`
#     do not block it); P1 and epics are excluded.
# R7  a malformed GC_REAPER_PURGE_AGE falls back to the default AND is an anomaly.
# R8  the wall-clock budget stops the purge (before the scan, and before a chunk) and
#     the summary says work remains; a stub `date` makes it deterministic.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAPER_SH="${REAPER_SH:-$HERE/scripts/reaper.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Fail CLOSED: a missing prerequisite must not read as a green run.
for tool in dolt jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: '$tool' is required by this selftest but is not installed"; exit 1; }
done
[ -f "$REAPER_SH" ] || { echo "FAIL: script under test not found: $REAPER_SH"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/reaper-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export DOLT_ROOT_PATH="$T/doltroot"; mkdir -p "$DOLT_ROOT_PATH"
DOLT_ROOT="$T/dolt"; mkdir -p "$DOLT_ROOT"
CITY="$T/city"; mkdir -p "$CITY/.beads" "$CITY/.gc/runtime"
printf '{"dolt_database":"hq"}\n' > "$CITY/.beads/metadata.json"
CALLS="$T/calls.log"; : > "$CALLS"

# ── the script under test + stubs, side by side (the script sources its siblings) ──
SD="$T/scripts"; mkdir -p "$SD" "$T/bin"
cp "$REAPER_SH" "$SD/reaper.sh"
cat > "$SD/_bd_trace.sh" <<'EOF'
_BD_TRACE_CALLER="${1:-unknown}"
EOF
cat > "$SD/dolt-target.sh" <<'EOF'
#!/usr/bin/env sh
dolt_sql() { ( cd "$DOLT_TEST_ROOT" && dolt sql "$@" ); }
has_wisps_table() (
    db="$1"
    output=$(dolt_sql -r csv -q "SHOW TABLES FROM \`$db\` LIKE 'wisps'" 2>/dev/null) || return 0
    [ "$(printf '%s\n' "$output" | tail -n +2 | head -1 | tr -d '\r')" = "wisps" ]
)
EOF
export DOLT_TEST_ROOT="$DOLT_ROOT"
cat > "$T/bin/gc" <<EOF
#!/bin/bash
echo "gc \$*" >> "$CALLS"
case "\$1 \$2" in
  "session prune") echo '{"count":0}' ;;
esac
exit 0
EOF
cat > "$T/bin/bd" <<EOF
#!/bin/bash
echo "bd \$*" >> "$CALLS"
case "\$1" in
  prune) echo '{"pruned_count":0}' ;;
esac
exit 0
EOF
chmod +x "$T/bin/gc" "$T/bin/bd"

sql()  { ( cd "$DOLT_ROOT" && dolt sql -r csv -q "USE hq; $1" 2>&1 | tail -n +2 ); }   # rows, no header
scalar() { sql "$1" | tail -1 | tr -d '\r'; }

H() { echo "DATE_SUB(NOW(), INTERVAL $1 HOUR)"; }

# ── fixtures ──────────────────────────────────────────────────────────────────
new_db() {  # new_db <split|legacy|unknown>
  ( cd "$DOLT_ROOT" && rm -rf hq && mkdir hq && cd hq && dolt init --name t --email t@t.local >/dev/null 2>&1 )
  local depcols
  case "$1" in
    split)   depcols="depends_on_issue_id VARCHAR(255) NULL, depends_on_wisp_id VARCHAR(255) NULL, depends_on_external VARCHAR(255) NULL" ;;
    legacy)  depcols="depends_on_id VARCHAR(255) NULL" ;;
    unknown) depcols="target VARCHAR(255) NULL" ;;
  esac
  local wfk=""
  [ "$1" = split ] && wfk=", KEY fk_wisp_dep_wisp_target (depends_on_wisp_id), CONSTRAINT fk_wisp_dep_wisp_target FOREIGN KEY (depends_on_wisp_id) REFERENCES wisps(id) ON DELETE CASCADE"
  local cols="id VARCHAR(255) NOT NULL PRIMARY KEY, title TEXT, status VARCHAR(32) NOT NULL DEFAULT 'open',
    issue_type VARCHAR(32) NOT NULL DEFAULT 'task', priority INT NOT NULL DEFAULT 2,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at DATETIME NULL, metadata JSON NULL"
  ( cd "$DOLT_ROOT" && dolt sql -q "USE hq;
    CREATE TABLE wisps ($cols);
    CREATE TABLE issues ($cols);
    CREATE TABLE wisp_dependencies (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, $depcols, type VARCHAR(32) NOT NULL$wfk);
    CREATE TABLE dependencies (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, $depcols, type VARCHAR(32) NOT NULL);
    CREATE TABLE wisp_labels (issue_id VARCHAR(255) NOT NULL, label VARCHAR(255) NOT NULL, PRIMARY KEY (issue_id, label));
    CREATE TABLE wisp_comments (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, text TEXT);
    CREATE TABLE wisp_events (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, event_type VARCHAR(64) NULL);
    CREATE TABLE labels (issue_id VARCHAR(255) NOT NULL, label VARCHAR(255) NOT NULL, PRIMARY KEY (issue_id, label));
    CALL DOLT_COMMIT('-Am', 'fixture schema', '--author', 't <t@t.local>');" >/dev/null 2>&1 )
}

seed_main() {  # rows for R1/R5 (split schema)
  sql "INSERT INTO wisps (id, status, issue_type, created_at, updated_at, closed_at) VALUES
    ('w-old-task',        'closed', 'task',    $(H 120), $(H 100), $(H 100)),
    ('w-old-chore',       'closed', 'chore',   $(H 70),  $(H 60),  $(H 60)),
    ('w-old-nullclosed',  'closed', 'task',    $(H 120), $(H 100), NULL),
    ('w-recent',          'closed', 'task',    $(H 3),   $(H 1),   $(H 1)),
    ('w-old-mail',        'closed', 'message', $(H 120), $(H 100), $(H 100)),
    ('w-parent-old',      'closed', 'task',    $(H 120), $(H 100), $(H 100)),
    ('w-child-open',      'open',   'task',    $(H 1),   $(H 1),   NULL),
    ('w-old-open',        'open',   'task',    $(H 200), $(H 200), NULL),
    ('w-issue-child',     'open',   'task',    $(H 1),   $(H 1),   NULL),
    ('w-chain-parent',    'closed', 'task',    $(H 120), $(H 100), $(H 100)),
    ('w-chain-child',     'closed', 'task',    $(H 120), $(H 100), $(H 100)),
    ('w-closed-parent2',  'closed', 'task',    $(H 5),   $(H 1),   $(H 1)),
    ('w-stale-child',     'open',   'task',    $(H 200), $(H 200), NULL);
   INSERT INTO issues (id, status, issue_type, priority, updated_at) VALUES ('i-parent', 'open', 'task', 2, NOW());
   INSERT INTO wisp_dependencies (issue_id, depends_on_wisp_id, type) VALUES
    ('w-child-open',  'w-parent-old',     'parent-child'),
    ('w-chain-child', 'w-chain-parent',   'parent-child'),
    ('w-stale-child', 'w-closed-parent2', 'parent-child');
   INSERT INTO wisp_dependencies (issue_id, depends_on_issue_id, type) VALUES ('w-issue-child', 'i-parent', 'parent-child');
   INSERT INTO wisp_labels VALUES ('w-old-task','a'), ('w-old-task','b'), ('w-old-chore','c'), ('w-recent','x'), ('w-old-mail','m');
   INSERT INTO wisp_comments (issue_id, text) VALUES ('w-old-task','hello'), ('w-recent','keep');
   INSERT INTO wisp_events (issue_id, event_type) VALUES ('w-old-task','created'), ('w-old-task','closed'), ('w-old-chore','created'), ('w-recent','created');
   CALL DOLT_COMMIT('-Am', 'fixture rows', '--author', 't <t@t.local>');" >/dev/null
}

run_reaper() {  # run_reaper [ENV=val ...] ; sets OUT and RC
  local envs=("$@")
  # ${envs[@]+...}: macOS bash 3.2 treats an EMPTY array expansion as unbound under `set -u`.
  OUT="$( cd "$T" && env GC_CITY_PATH="$CITY" GC_CITY="$CITY" PATH="$T/bin:$PATH" ${envs[@]+"${envs[@]}"} bash "$SD/reaper.sh" 2>"$T/stderr.log" )"; RC=$?
}
field() { printf '%s' "$OUT" | grep -o "$1:[0-9a-z]*" | head -1 | cut -d: -f2; }
mail_count() { grep -c '^gc mail send' "$CALLS" || true; }

# ── R1: the main scenario ─────────────────────────────────────────────────────
echo "R1: split schema — purge, carve-outs, NULL-edge safety, children, issue steps off"
new_db split; seed_main; : > "$CALLS"
run_reaper
[ "$RC" -eq 0 ] && ok "R1 reaper runs clean (rc=0)" || nok "R1 rc" "rc=$RC $(tail -3 "$T/stderr.log")"
[ "$(field schema_skipped_dbs)" = "0" ] && ok "R1 the split schema is RECOGNISED (schema_skipped_dbs:0)" \
  || nok "R1 the database was skipped as an unrecognised schema" "$OUT"
REMAIN="$(sql "SELECT id FROM wisps ORDER BY id" | tr -d '\r' | tr '\n' ' ')"
WANT="w-child-open w-closed-parent2 w-issue-child w-old-mail w-old-open w-parent-old w-recent w-stale-child "
[ "$REMAIN" = "$WANT" ] && ok "R1 exactly the right wisps survive" || nok "R1 surviving wisps differ" "got: $REMAIN | want: $WANT"
[ "$(field purged)" = "5" ] && ok "R1 purged:5 (old task/chore, NULL-closed_at, and the closed parent+child chain)" \
  || nok "R1 summary purged count" "$OUT"
sql "SELECT 1 FROM wisps WHERE id='w-old-mail'" | grep 1 >/dev/null && ok "R1 closed MAIL is never purged (ga-3rqwa)" || nok "R1 closed mail was hard-deleted"
sql "SELECT 1 FROM wisps WHERE id='w-parent-old'" | grep 1 >/dev/null && ok "R1 a closed parent that still has an OPEN child is kept" || nok "R1 closed parent of an open child was purged"
sql "SELECT 1 FROM wisps WHERE id='w-old-nullclosed'" | grep 1 >/dev/null && nok "R1 a closed row with NULL closed_at is immortal" || ok "R1 closed row with NULL closed_at is purged via updated_at"
ORPH="$(scalar "SELECT (SELECT COUNT(*) FROM wisp_labels l LEFT JOIN wisps w ON w.id=l.issue_id WHERE w.id IS NULL)
  + (SELECT COUNT(*) FROM wisp_comments c LEFT JOIN wisps w ON w.id=c.issue_id WHERE w.id IS NULL)
  + (SELECT COUNT(*) FROM wisp_events e LEFT JOIN wisps w ON w.id=e.issue_id WHERE w.id IS NULL)
  + (SELECT COUNT(*) FROM wisp_dependencies d LEFT JOIN wisps w ON w.id=d.issue_id WHERE w.id IS NULL)")"
[ "$ORPH" = "0" ] && ok "R1 no orphan rows left in wisp_labels/comments/events/dependencies" || nok "R1 orphans left behind" "orphans=$ORPH"
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id IN ('w-recent','w-old-mail')")" = "2" ] \
  && ok "R1 the children of KEPT wisps are untouched" || nok "R1 children of kept wisps were deleted"
[ "$(field closed_wisps)" = "1" ] && ok "R1 Step 1 still closes a stale child of a closed parent (closed_wisps:1)" || nok "R1 step 1" "$OUT"
[ "$(field issue_steps)" = "off" ] && ok "R1 summary says issue_steps:off" || nok "R1 issue_steps flag missing" "$OUT"
grep -q '^bd close' "$CALLS" && nok "R1 an issue was closed although the issue steps are off" "$(grep '^bd close' "$CALLS")" || ok "R1 no issue is closed with the issue steps off"
[ "$(field anomalies)" = "0" ] && [ "$(mail_count)" = "0" ] && ok "R1 no anomaly, no mail" || nok "R1 unexpected anomaly/mail" "$OUT"

# ── R2: chunking, cap, continuation ───────────────────────────────────────────
echo "R2: chunked purge with a per-run cap"
new_db split
VALS=""; for i in $(seq 1 1200); do VALS="$VALS${VALS:+,}('c$i','closed','task',$(H 120),$(H 100),$(H 100))"; done
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES $VALS; INSERT INTO wisp_labels SELECT id,'x' FROM wisps; CALL DOLT_COMMIT('-Am','bulk','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"
run_reaper GC_REAPER_PURGE_BATCH=100 GC_REAPER_PURGE_MAX_PER_RUN=1000
[ "$(field purged)" = "1000" ] && ok "R2 run 1 purges exactly the cap (1000)" || nok "R2 run 1 purged count" "$OUT"
[ "$(field purge_batches)" = "10" ] && ok "R2 in 10 chunks of 100" || nok "R2 chunk count" "$OUT"
[ "$(field purge_capped_dbs)" = "1" ] && ok "R2 the summary says work REMAINS (purge_capped_dbs:1)" || nok "R2 capped not reported" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisps")" = "200" ] && ok "R2 200 wisps remain for the next run" || nok "R2 remaining wisps" "$(scalar "SELECT COUNT(*) FROM wisps")"
run_reaper GC_REAPER_PURGE_BATCH=100 GC_REAPER_PURGE_MAX_PER_RUN=1000
[ "$(field purged)" = "200" ] && [ "$(field purge_capped_dbs)" = "0" ] && ok "R2 run 2 finishes the rest and is no longer capped" || nok "R2 run 2" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisps")" = "0" ] && [ "$(scalar "SELECT COUNT(*) FROM wisp_labels")" = "0" ] \
  && ok "R2 wisps and their labels are all gone" || nok "R2 leftovers"

# ── R3: unrecognised schema is LOUD, once ─────────────────────────────────────
echo "R3: unrecognised schema — anomaly + counter + one deduplicated mail, nothing deleted"
new_db unknown
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('u1','closed','task',$(H 120),$(H 100),$(H 100)); CALL DOLT_COMMIT('-Am','u','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper
[ "$RC" -eq 0 ] && ok "R3 rc=0" || nok "R3 rc" "rc=$RC"
[ "$(field schema_skipped_dbs)" = "1" ] && ok "R3 schema_skipped_dbs:1 — the skip is COUNTED" || nok "R3 the skip is silent" "$OUT"
[ "$(field anomalies)" -ge 1 ] 2>/dev/null && ok "R3 an anomaly is recorded" || nok "R3 no anomaly" "$OUT"
[ "$(mail_count)" = "1" ] && grep -q 'unrecognised schema' "$CALLS" && ok "R3 the mayor is mailed, naming the unrecognised schema" || nok "R3 no mail / wrong text" "$(cat "$CALLS")"
[ "$(scalar "SELECT COUNT(*) FROM wisps")" = "1" ] && ok "R3 nothing is deleted under an unknown schema" || nok "R3 rows deleted under an unknown schema"
run_reaper
[ "$(mail_count)" = "1" ] && ok "R3 the SAME anomaly is not re-mailed (dedup)" || nok "R3 mail spam: $(mail_count) mails after two runs"

# ── R4: legacy schema still works ─────────────────────────────────────────────
echo "R4: legacy depends_on_id schema"
new_db legacy
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES
      ('l-old','closed','task',$(H 120),$(H 100),$(H 100)), ('l-parent','closed','task',$(H 120),$(H 100),$(H 100)), ('l-child','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_dependencies (issue_id, depends_on_id, type) VALUES ('l-child','l-parent','parent-child');
     CALL DOLT_COMMIT('-Am','l','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; run_reaper
[ "$(field schema_skipped_dbs)" = "0" ] && [ "$(field purged)" = "1" ] && ok "R4 legacy schema recognised; only the unprotected old wisp is purged" || nok "R4 legacy" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisps WHERE id='l-parent'")" = "1" ] && ok "R4 legacy parent of an open child is kept" || nok "R4 legacy parent purged"

# ── R5: dry run ───────────────────────────────────────────────────────────────
echo "R5: dry run"
new_db split; seed_main; : > "$CALLS"
run_reaper GC_REAPER_DRY_RUN=1
[ "$(scalar "SELECT COUNT(*) FROM wisps")" = "13" ] && ok "R5 dry run deletes nothing" || nok "R5 dry run mutated the database"
[ "$(field would_purge)" = "5" ] && printf '%s' "$OUT" | grep '(dry run)' >/dev/null && ok "R5 reports would_purge:5" || nok "R5 dry-run summary" "$OUT"

# ── R6: issue steps on ────────────────────────────────────────────────────────
echo "R6: GC_REAPER_ISSUE_STEPS=1"
new_db split
sql "INSERT INTO issues (id,status,issue_type,priority,updated_at) VALUES
      ('i-stale','open','task',3,$(H 900)), ('i-p1','open','task',1,$(H 900)), ('i-epic','open','epic',3,$(H 900)), ('i-fresh','open','task',3,NOW()),
      ('i-agent','open','agent',3,$(H 900)), ('i-role','open','role',3,$(H 900));
     INSERT INTO dependencies (issue_id, depends_on_wisp_id, type) VALUES ('i-fresh','w-none','blocks');
     CALL DOLT_COMMIT('-Am','i','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; run_reaper GC_REAPER_ISSUE_STEPS=1
grep -q '^bd close i-stale' "$CALLS" && ok "R6 the stale issue is auto-closed (a NULL depends_on_issue_id edge does not block it)" || nok "R6 stale issue not closed" "$(cat "$CALLS") | $OUT"
grep -q -E '^bd close i-(p1|epic|fresh)' "$CALLS" && nok "R6 an excluded issue was closed" "$(grep '^bd close' "$CALLS")" || ok "R6 P1, epic and fresh issues are left alone"
grep -q -E '^bd close i-(agent|role)' "$CALLS" && nok "R6 an agent/role IDENTITY bead was auto-closed (13 of 16 live candidates were agent beads)" "$(grep '^bd close' "$CALLS")" || ok "R6 agent and role identity beads are never auto-closed"
[ "$(field issue_steps)" = "on" ] && [ "$(field anomalies)" = "0" ] && ok "R6 summary issue_steps:on, no SQL anomaly" || nok "R6 summary/anomaly" "$OUT"

# ── R7: malformed config ──────────────────────────────────────────────────────
echo "R7: malformed GC_REAPER_PURGE_AGE"
new_db split; seed_main; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_PURGE_AGE=2d
[ "$(field purge_age_h)" = "48" ] && [ "$(field purged)" = "5" ] && ok "R7 falls back to the default age and still purges" || nok "R7 fallback" "$OUT"
[ "$(field anomalies)" = "1" ] && grep -q 'PURGE_AGE_H' "$CALLS" && ok "R7 the bad value is an ANOMALY (not a silent SQL error)" || nok "R7 bad config not reported" "$OUT | $(cat "$CALLS")"

# ── R8: the wall-clock budget (deterministic: a stub `date` that walks a fixed sequence) ──
echo "R8: purge time budget"
mkdir -p "$T/bin_date"
cat > "$T/bin_date/date" <<'EOF'
#!/bin/bash
# reaper.sh only ever calls `date +%s`. Return the Nth value of $DATE_SEQ, then repeat the last one.
n=$(cat "$DATE_STATE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$DATE_STATE"
arr=($DATE_SEQ); idx=$((n - 1)); [ "$idx" -ge "${#arr[@]}" ] && idx=$((${#arr[@]} - 1))
echo "${arr[$idx]}"
EOF
chmod +x "$T/bin_date/date"
# R8a: the budget is ALREADY spent when the database is reached -> capped, nothing purged. (The
# top-of-function check also skips the candidate scan; that is not observable from here, the
# assert below covers the outcome — the in-loop check alone would produce the same outcome.)
new_db split; seed_main; : > "$CALLS"; rm -f "$T/date.n"
run_reaper PATH="$T/bin_date:$T/bin:$PATH" DATE_SEQ="1000 2000" DATE_STATE="$T/date.n"
[ "$(field purged)" = "0" ] && [ "$(field purge_batches)" = "0" ] && [ "$(scalar "SELECT COUNT(*) FROM wisps")" = "13" ] \
  && ok "R8a a budget already spent purges nothing" || nok "R8a purged despite an exhausted budget" "$OUT"
[ "$(field purge_capped_dbs)" = "1" ] && ok "R8a ...and the summary says work REMAINS (purge_capped_dbs:1)" || nok "R8a capped not reported" "$OUT"
# R8b: the budget runs out AFTER the candidate scan, before the first chunk -> capped, nothing deleted.
new_db split; seed_main; : > "$CALLS"; rm -f "$T/date.n"
run_reaper PATH="$T/bin_date:$T/bin:$PATH" DATE_SEQ="1000 1100 1300" DATE_STATE="$T/date.n"
[ "$(field purged)" = "0" ] && [ "$(field purge_batches)" = "0" ] && [ "$(scalar "SELECT COUNT(*) FROM wisps")" = "13" ] \
  && ok "R8b a budget spent mid-run stops before the first chunk" || nok "R8b purged despite an exhausted budget" "$OUT"
[ "$(field purge_capped_dbs)" = "1" ] && ok "R8b ...and is reported as capped" || nok "R8b capped not reported" "$OUT"

echo ""
echo "reaper-schema-purge selftest (ga-u8nbt9): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
