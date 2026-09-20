#!/usr/bin/env bash
# reaper-orphan-sweep.selftest.sh — regression test for ga-x2fj8h.
#
# THE BUGS (measured live 2026-09-19, hq database):
#  1. purge_chunk sent five DELETEs as ONE multi-statement bounded by WISPS (500 ids). Rows per
#     wisp are unbounded (a live wisp owns ~1000 wisp_events rows) and removing a wisp_events row
#     is a random read in a 1.9M-row uuid-keyed table, so one statement ran past Dolt's 30 s read
#     cutoff: "purging closed wisps failed for hq: error on line 6 for query DELETE FROM
#     hq.wisp_events ...". The loop then STOPPED at the first failed chunk, the oldest candidates
#     are retried first, and the failure reached only the mail — never the DOG_DONE summary.
#  2. 2.9M child rows (1.87M wisp_events, 1.06M wisp_labels, 7.5k wisp_comments) belonged to wisps
#     that no longer existed (deleted before ga-u8nbt9 without their children); nothing looked at
#     them again.
#
# This test runs the REAL scripts/reaper.sh against throwaway local Dolt repos (multi-database
# mode: `dolt sql` from the parent directory, no server) with stub `gc`/`bd`, and a stub
# dolt-target.sh whose dolt_sql can (a) log every statement, (b) FAIL matching statements on demand
# to reproduce the cutoff ("context canceled"), (c) fake the orphan sample, (d) be slow. The fixture
# schema mirrors the live one (uuid keys, the same indexes on issue_id). REAPER_SH overrides the
# script under test — point it at the previous version to see the red side.
#
# O1  the sweep removes ONLY orphan rows, in all four child tables; live rows are untouched.
#     (Runs first and BAILS on failure: on the old code it is red within the gate's 30 s A/B.)
# O2  ROW-bounded: many orphans need several bounded statements (DELETE ... LIMIT n), all gone.
# O3  the wall-clock budget stops the sweep and the summary says work remains.
# O4  a TRANSIENT statement failure is retried with a smaller batch: no failed chunk, no mail.
# O5  a chunk that fails FOR GOOD does not stop the purge: the next chunk still goes, the failure
#     is in the DOG_DONE summary (purge_failed_chunks, last_error), it is mailed, and the wisps of
#     the failed chunk stay candidates (half-emptied, NEVER orphans).
# O6  the circuit breaker: consecutive failed chunks stop the purge (Dolt is unwell).
# O7  a FAILED orphan sample is not "no orphans": counted, reported, nothing deleted.
# O8  sweeping more than GC_REAPER_ORPHAN_ALERT rows is an anomaly (the detector).
# O9  dry run deletes nothing and reports would_sweep.
# O10 GC_REAPER_ORPHAN_SWEEP=0 switches the sweep off; a malformed value is an anomaly, not a skip.
# O11 a STALE sample naming a LIVE wisp deletes nothing: the guard is inside the DELETE.
# O12 an orphan whose id has unexpected characters is never interpolated into SQL, is reported,
#     and does not make the sweep loop for ever.
# --- safety rails (measured: a deleted row costs ~3 KB of transient disk, on a 96%-full volume) ---
# O13 the order declares a timeout that covers the script's own wall-clock budgets (the engine
#     default for an exec order is 300 s; the budgets alone add up to 420 s).
# O14 the per-run ROW cap stops the sweep (work reported as remaining) and the next run carries on.
#     The cap is HARD (O14/O14b/O14c): a sampled round can name wisps owning far more rows than the
#     cap, so the last DELETE batch is shrunk to the allowance instead of checking only between rounds;
#     a remainder of one row is left (a one-row DELETE reports ROW_COUNT() -1 on wisp_dependencies).
# O15 the free-disk floor: below it nothing is deleted and the DOG_DONE line says why (no mail);
#     0 switches the guard off; an UNREADABLE df is "cannot tell", not "enough" (anomaly).
# O15b the DEFAULT floor is 18 GiB — above the dolt_gc job's headroom gate (max(200% of the store,
#     store + 3 GB) ~ 15 GiB): a sweep that ate that headroom would block the GC that returns space.
# O16 the seatbelt: children exist but `wisps` is empty -> nothing is deleted (every row would look
#     orphaned) and it is reported; an empty database with no children raises nothing.
# O17 the purge's failure breaker tripped -> the sweep does not add load, and says so.
# O8b a run that stopped at a budget (drain mode) sweeping more than the alert threshold is NOT mailed.
# --- found by the adversarial review of this change ---
# O5b a >5 KB failing statement keeps its CAUSE in DOG_DONE and the mail, drops its id list, and the
#     same failure next run is not re-mailed (real Dolt puts the cause LAST in a ~10 KB message).
# O16b `wisps` emptied MID-sweep halts the very next round (the seatbelt is re-read every round).
# O18 a slow sweep in one database does not starve the PURGE budget of the databases after it.

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

T="$(mktemp -d "${TMPDIR:-/tmp}/reaper-orphan-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export DOLT_ROOT_PATH="$T/doltroot"; mkdir -p "$DOLT_ROOT_PATH"
DOLT_ROOT="$T/dolt"; mkdir -p "$DOLT_ROOT"
CITY="$T/city"; mkdir -p "$CITY/.beads" "$CITY/.gc/runtime"
printf '{"dolt_database":"hq"}\n' > "$CITY/.beads/metadata.json"
CALLS="$T/calls.log"; : > "$CALLS"
export SQL_LOG="$T/sql.log"; : > "$SQL_LOG"

# ── the script under test + stubs, side by side (the script sources its siblings) ──
SD="$T/scripts"; mkdir -p "$SD" "$T/bin"
cp "$REAPER_SH" "$SD/reaper.sh"
cat > "$SD/_bd_trace.sh" <<'EOF'
_BD_TRACE_CALLER="${1:-unknown}"
EOF
cat > "$SD/dolt-target.sh" <<'EOF'
#!/usr/bin/env sh
# Test double for the shared connection setup. Hooks, all driven by env the scenario passes:
#   SQL_LOG     every statement is appended (one line each)
#   FAIL_RE     a statement matching this ERE fails ("context canceled", the shape of Dolt's cutoff)
#               while the counter file FAIL_COUNT is > 0 (decremented per failure)
#   FAKE_SAMPLE the orphan-sample SELECT answers with this id instead of asking Dolt
#   SLOW_RE     a statement matching this ERE sleeps SLOW_S seconds first
dolt_sql() {
    _q=""
    for _a in "$@"; do _q="$_q $_a"; done
    printf '%s\n' "$_q" | tr '\n' ' ' >> "$SQL_LOG"; echo >> "$SQL_LOG"
    if [ -n "${FAIL_RE:-}" ] && printf '%s' "$_q" | grep -Eq "$FAIL_RE"; then
        _n=$(cat "$FAIL_COUNT" 2>/dev/null || echo 0)
        if [ "$_n" -gt 0 ]; then
            echo $((_n - 1)) > "$FAIL_COUNT"
            # Like real Dolt, echo the FAILING STATEMENT (with its id list) and put the cause LAST:
            # a purge chunk names hundreds of ids, so the message is ~10 KB and the cause sits at the end.
            echo "error on line 3 for query $_q: context canceled" >&2
            return 1
        fi
    fi
    if [ -n "${FAKE_SAMPLE:-}" ] && printf '%s' "$_q" | grep -q 'SELECT c.issue_id'; then
        printf 'issue_id\n%s\n' "$FAKE_SAMPLE"
        return 0
    fi
    if [ -n "${SLOW_RE:-}" ] && printf '%s' "$_q" | grep -Eq "$SLOW_RE"; then
        sleep "${SLOW_S:-2}"
    fi
    _rc=0
    ( cd "$DOLT_TEST_ROOT" && dolt sql "$@" ) || _rc=$?
    # SABOTAGE_AFTER_RE: once, right AFTER a statement matching it ran, EMPTY hq.wisps behind the script's
    # back (a migration/rebuild/other actor mid-sweep) — see O16b.
    if [ -n "${SABOTAGE_AFTER_RE:-}" ] && [ ! -e "${SABOTAGE_DONE:-/nonexistent}" ] && printf '%s' "$_q" | grep -Eq "$SABOTAGE_AFTER_RE"; then
        : > "$SABOTAGE_DONE"
        ( cd "$DOLT_TEST_ROOT" && dolt sql -q 'USE hq; DELETE FROM wisps' >/dev/null 2>&1 )
    fi
    return $_rc
}
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
# `df -Pk <path>` double: free space is whatever the scenario says (default: plenty), so this suite
# does not depend on how full the machine running it happens to be (the sweep refuses to work
# below a free-disk floor). FAKE_DF_FAIL=1 = df cannot be read.
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
[ "${FAKE_DF_FAIL:-0}" = "1" ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1000 ${FAKE_DF_AVAIL_KB:-999999999} 1% /"
EOF
chmod +x "$T/bin/gc" "$T/bin/bd" "$T/bin/df"

sql()  { ( cd "$DOLT_ROOT" && dolt sql -r csv -q "USE hq; $1" 2>&1 | tail -n +2 ); }   # rows, no header
scalar() { sql "$1" | tail -1 | tr -d '\r'; }
H() { echo "DATE_SUB(NOW(), INTERVAL $1 HOUR)"; }

# orphans (labels,comments,events,dependencies) and live-owned rows (same order), as "a,b,c,d"
ORPH_Q="SELECT (SELECT COUNT(*) FROM wisp_labels x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL),
  (SELECT COUNT(*) FROM wisp_comments x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL),
  (SELECT COUNT(*) FROM wisp_events x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL),
  (SELECT COUNT(*) FROM wisp_dependencies x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL)"
LIVE_Q="SELECT (SELECT COUNT(*) FROM wisp_labels x JOIN wisps w ON w.id=x.issue_id),
  (SELECT COUNT(*) FROM wisp_comments x JOIN wisps w ON w.id=x.issue_id),
  (SELECT COUNT(*) FROM wisp_events x JOIN wisps w ON w.id=x.issue_id),
  (SELECT COUNT(*) FROM wisp_dependencies x JOIN wisps w ON w.id=x.issue_id)"
orphans() { sql "$ORPH_Q" | tail -1 | tr -d '\r'; }
live()    { sql "$LIVE_Q" | tail -1 | tr -d '\r'; }

new_db() {  # new_db [name] — a fresh fixture database (default hq; O18 adds a second one)
  local dbn="${1:-hq}"
  ( cd "$DOLT_ROOT" && rm -rf "$dbn" && mkdir "$dbn" && cd "$dbn" && dolt init --name t --email t@t.local >/dev/null 2>&1 )
  local cols="id VARCHAR(255) NOT NULL PRIMARY KEY, title TEXT, status VARCHAR(32) NOT NULL DEFAULT 'open',
    issue_type VARCHAR(32) NOT NULL DEFAULT 'task', priority INT NOT NULL DEFAULT 2,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at DATETIME NULL, metadata JSON NULL"
  ( cd "$DOLT_ROOT" && dolt sql -q "USE $dbn;
    CREATE TABLE wisps ($cols);
    CREATE TABLE issues ($cols);
    CREATE TABLE wisp_dependencies (id CHAR(36) NOT NULL DEFAULT (uuid()) PRIMARY KEY, issue_id VARCHAR(255) NOT NULL,
      depends_on_issue_id VARCHAR(255) NULL, depends_on_wisp_id VARCHAR(255) NULL, depends_on_external VARCHAR(255) NULL,
      type VARCHAR(32) NOT NULL DEFAULT 'blocks',
      KEY fk_wisp_dep_wisp_target (depends_on_wisp_id),
      CONSTRAINT fk_wisp_dep_wisp_target FOREIGN KEY (depends_on_wisp_id) REFERENCES wisps(id) ON DELETE CASCADE);
    CREATE TABLE dependencies (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, issue_id VARCHAR(255) NOT NULL,
      depends_on_issue_id VARCHAR(255) NULL, depends_on_wisp_id VARCHAR(255) NULL, depends_on_external VARCHAR(255) NULL, type VARCHAR(32) NOT NULL);
    CREATE TABLE wisp_labels (issue_id VARCHAR(255) NOT NULL, label VARCHAR(255) NOT NULL, PRIMARY KEY (issue_id, label), KEY idx_wisp_labels_issue_id (issue_id));
    CREATE TABLE wisp_comments (id CHAR(36) NOT NULL DEFAULT (uuid()) PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, text TEXT NOT NULL, KEY idx_wisp_comments_issue (issue_id));
    CREATE TABLE wisp_events (id CHAR(36) NOT NULL DEFAULT (uuid()) PRIMARY KEY, issue_id VARCHAR(255) NOT NULL, event_type VARCHAR(32) NOT NULL DEFAULT 'x', KEY idx_wisp_events_issue (issue_id));
    CREATE TABLE labels (issue_id VARCHAR(255) NOT NULL, label VARCHAR(255) NOT NULL, PRIMARY KEY (issue_id, label));
    CALL DOLT_COMMIT('-Am', 'fixture schema', '--author', 't <t@t.local>');" >/dev/null 2>&1 )
}

# 2 live wisps with their children + orphan children of 2 wisps that no longer exist.
#   orphans: labels 3, comments 2, events 4, dependencies 1  (= 10)
#   live   : labels 3, comments 1, events 3, dependencies 1  (= 8)
seed_orphans() {
  sql "INSERT INTO wisps (id, status, issue_type, created_at, updated_at, closed_at) VALUES
        ('live-open','open','task',$(H 1),$(H 1),NULL), ('live-recent','closed','task',$(H 3),$(H 1),$(H 1));
     INSERT INTO wisp_labels VALUES ('live-open','a'),('live-open','b'),('live-recent','c'),('gone-1','x'),('gone-1','y'),('gone-2','x');
     INSERT INTO wisp_comments (issue_id, text) VALUES ('live-open','keep'),('gone-1','t1'),('gone-2','t2');
     INSERT INTO wisp_events (issue_id, event_type) VALUES ('live-open','c'),('live-open','u'),('live-recent','c'),('gone-1','c'),('gone-1','u'),('gone-1','x'),('gone-2','c');
     INSERT INTO wisp_dependencies (issue_id, type) VALUES ('gone-1','blocks'),('live-open','blocks');
     CALL DOLT_COMMIT('-Am', 'fixture rows', '--author', 't <t@t.local>');" >/dev/null
}

run_reaper() {  # run_reaper [ENV=val ...] ; sets OUT and RC
  local envs=("$@")
  : > "$SQL_LOG"
  # ${envs[@]+...}: macOS bash 3.2 treats an EMPTY array expansion as unbound under `set -u`.
  # /bin/bash, not `bash`: PATH may resolve to Homebrew bash 5.x, but launchd and the gate run the
  # script under the system bash 3.2 — the version whose quirks (empty arrays, [[ =~ ]]) bite.
  OUT="$( cd "$T" && env GC_CITY_PATH="$CITY" GC_CITY="$CITY" PATH="$T/bin:$PATH" GC_REAPER_PURGE_RETRY_PAUSE_S=0 \
        FAIL_COUNT="$T/failcount" ${envs[@]+"${envs[@]}"} /bin/bash "$SD/reaper.sh" 2>"$T/stderr.log" )"; RC=$?
}
field() { printf '%s' "$OUT" | grep -o "$1:[0-9a-z]*" | head -1 | cut -d: -f2; }
mail_count() { grep -c '^gc mail send' "$CALLS" || true; }
sqlcount() { grep -c -E "$1" "$SQL_LOG" || true; }

# ── O1: the main scenario — ONLY orphans go ───────────────────────────────────
echo "O1: orphan sweep — only orphans, all four child tables, live rows untouched"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
[ "$(orphans)" = "3,2,4,1" ] && [ "$(live)" = "3,1,3,1" ] || nok "O1 fixture is not what the test assumes" "orphans=$(orphans) live=$(live)"
run_reaper
[ "$RC" -eq 0 ] && ok "O1 reaper runs clean (rc=0)" || nok "O1 rc" "rc=$RC $(tail -3 "$T/stderr.log")"
[ "$(field orphan_swept)" = "10" ] && ok "O1 orphan_swept:10 (3 labels + 2 comments + 4 events + 1 edge)" || nok "O1 orphan_swept" "$OUT"
[ "$(orphans)" = "0,0,0,0" ] && ok "O1 no orphan left in any of the four tables" || nok "O1 orphans left" "$(orphans)"
[ "$(live)" = "3,1,3,1" ] && ok "O1 every row of a LIVE wisp is untouched" || nok "O1 live rows changed" "$(live)"
[ "$(field anomalies)" = "0" ] && [ "$(mail_count)" = "0" ] && ok "O1 no anomaly, no mail" || nok "O1 unexpected anomaly/mail" "$OUT"
# The first scenario is the decisive one: if the sweep does not work at all, the rest is noise
# (and on the OLD code this is what turns the test red, fast).
[ "$FAIL" -eq 0 ] || { echo ""; echo "reaper-orphan-sweep selftest (ga-x2fj8h): BAIL after O1 — $PASS passed, $FAIL failed"; exit 1; }

# ── O2: ROW-bounded, several statements ───────────────────────────────────────
echo "O2: row-bounded — many orphans take several LIMIT-ed statements"
new_db
V=""; for i in $(seq 1 130); do V="$V${V:+,}('gone-$((i % 3))','e')"; done
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_events (issue_id,event_type) VALUES $V, ('live-open','c'),('live-open','u');
     CALL DOLT_COMMIT('-Am','bulk','--author','t <t@t.local>');" >/dev/null
run_reaper GC_REAPER_ORPHAN_SELECT_ROWS=50 GC_REAPER_PURGE_ROW_BATCH=50
[ "$(field orphan_swept)" = "130" ] && ok "O2 orphan_swept:130" || nok "O2 orphan_swept" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisp_events")" = "2" ] && ok "O2 only the 2 live events remain" || nok "O2 events left" "$(scalar "SELECT COUNT(*) FROM wisp_events")"
N="$(sqlcount 'DELETE FROM `hq`.wisp_events WHERE .*LIMIT 50')"
[ "${N:-0}" -ge 3 ] && ok "O2 the events went in $N bounded statements (LIMIT 50), not one" || nok "O2 not row-bounded" "bounded events deletes: $N"
[ "$(sqlcount 'DELETE FROM `hq`.wisp_events WHERE issue_id IN \(.*\) AND NOT EXISTS')" -ge 1 ] \
  && ok "O2 every sweep DELETE re-checks NOT EXISTS inside the statement" || nok "O2 the DELETE is not guarded"

# ── O3: the wall-clock budget ─────────────────────────────────────────────────
echo "O3: sweep time budget"
new_db; seed_orphans
run_reaper GC_REAPER_ORPHAN_BUDGET_S=1 SLOW_RE='SELECT c.issue_id' SLOW_S=2
[ "$(field orphan_swept)" = "0" ] && [ "$(orphans)" = "3,2,4,1" ] && ok "O3 a budget spent before the first delete removes nothing" || nok "O3 swept past the budget" "$OUT | $(orphans)"
[ "$(field orphan_capped_dbs)" = "1" ] && ok "O3 the summary says work REMAINS (orphan_capped_dbs:1)" || nok "O3 capped not reported" "$OUT"

# ── O4: a transient failure is retried with a smaller batch ───────────────────
echo "O4: transient statement failure — retried with half the batch"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('c1','closed','task',$(H 120),$(H 100),$(H 100)),('c2','closed','task',$(H 120),$(H 90),$(H 90));
     INSERT INTO wisp_events (issue_id,event_type) VALUES ('c1','a'),('c1','b'),('c2','a');
     INSERT INTO wisp_labels VALUES ('c1','x'),('c2','x');
     CALL DOLT_COMMIT('-Am','c','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 1 > "$T/failcount"
run_reaper FAIL_RE='DELETE FROM `hq`.wisp_events'
[ "$(field purged)" = "2" ] && [ "$(field purge_failed_chunks)" = "0" ] && ok "O4 the chunk is purged on the retry (purged:2, purge_failed_chunks:0)" || nok "O4 the transient failure was not absorbed" "$OUT"
[ "$(sqlcount 'DELETE FROM `hq`.wisp_events WHERE .*LIMIT 500')" -ge 1 ] && ok "O4 the retry used HALF the batch (LIMIT 500)" || nok "O4 the retry did not shrink the batch" "$(grep -c 'wisp_events' "$SQL_LOG") statements on wisp_events"
[ "$(field anomalies)" = "0" ] && [ "$(mail_count)" = "0" ] && ok "O4 a retried statement is not a mail" || nok "O4 a retried statement raised an anomaly" "$OUT"

# ── O5: a chunk that fails for good does not stop the purge ───────────────────
echo "O5: a failed chunk is skipped, reported in the summary, and never leaves orphans"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES
      ('a1','closed','task',$(H 200),$(H 190),$(H 190)),('a2','closed','task',$(H 200),$(H 180),$(H 180)),
      ('a3','closed','task',$(H 200),$(H 170),$(H 170)),('a4','closed','task',$(H 200),$(H 160),$(H 160));
     INSERT INTO wisp_labels SELECT id,'x' FROM wisps;
     INSERT INTO wisp_comments (issue_id,text) SELECT id,'t' FROM wisps;
     INSERT INTO wisp_events (issue_id,event_type) SELECT id,'e' FROM wisps;
     CALL DOLT_COMMIT('-Am','a','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 999 > "$T/failcount"
run_reaper GC_REAPER_PURGE_BATCH=2 FAIL_RE="wisp_events.*'a1'"
[ "$RC" -eq 0 ] && ok "O5 rc=0" || nok "O5 rc" "rc=$RC"
[ "$(field purged)" = "2" ] && [ "$(scalar "SELECT COUNT(*) FROM wisps WHERE id IN ('a3','a4')")" = "0" ] \
  && ok "O5 the chunk AFTER the failed one is still purged (purged:2)" || nok "O5 one failed chunk stopped the purge" "$OUT"
[ "$(field purge_failed_chunks)" = "1" ] && ok "O5 purge_failed_chunks:1 in the summary" || nok "O5 the failure is not counted" "$OUT"
grep -q 'DOG_DONE:.*last_error:.*context canceled' "$CALLS" && ok "O5 the DOG_DONE line names the cause (last_error: ... context canceled)" || nok "O5 the error never reached DOG_DONE" "$(grep DOG_DONE "$CALLS")"
[ "$(mail_count)" = "1" ] && ok "O5 the failure is also mailed, once" || nok "O5 mail count" "$(mail_count)"
[ "$(scalar "SELECT COUNT(*) FROM wisps WHERE id IN ('a1','a2')")" = "2" ] && ok "O5 the failed chunk's wisps stay purge CANDIDATES" || nok "O5 wisps of the failed chunk were lost"
[ "$(orphans)" = "0,0,0,0" ] && ok "O5 half-emptied is not orphaned: no orphan rows anywhere" || nok "O5 a failed chunk left orphans" "$(orphans)"
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id IN ('a1','a2')")" = "0" ] && [ "$(scalar "SELECT COUNT(*) FROM wisp_events WHERE issue_id IN ('a1','a2')")" = "2" ] \
  && ok "O5 the partial state is as designed: children go first (labels gone, events still there)" || nok "O5 partial state differs from the design"
echo 0 > "$T/failcount"
run_reaper GC_REAPER_PURGE_BATCH=2
[ "$(field purged)" = "2" ] && [ "$(scalar "SELECT COUNT(*) FROM wisps")" = "0" ] && [ "$(orphans)" = "0,0,0,0" ] \
  && ok "O5 the next (healthy) run finishes the failed chunk" || nok "O5 the failed chunk was not finished later" "$OUT"

# ── O5b: a LONG failing statement keeps its CAUSE, loses its id list, and is not re-mailed ──
# Real Dolt echoes the failing statement inside its error and puts the cause LAST; a 500-id purge
# chunk makes that ~10 KB, so a head-only 4000-char cut dropped the cause (the DOG_DONE last_error and
# the mail never said WHY — the bead's own requirement) and the ever-changing id list defeated the
# anomaly-mail dedupe. 200 ids of ~28 chars = a >5 KB statement.
echo "O5b: a failing 200-id chunk — cause kept, id list dropped, mail deduped"
new_db
V=""; for i in $(seq 1 200); do V="$V${V:+,}('bulk-wisp-$(printf '%04d' "$i")-abcdefghij','closed','task',$(H 200),$(H 100),$(H 100))"; done
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES $V;
     CALL DOLT_COMMIT('-Am','bulk','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 999 > "$T/failcount"
run_reaper FAIL_RE='DELETE FROM `hq`.wisp_events'
[ "$(field purge_failed_chunks)" = "1" ] && ok "O5b the 200-id chunk failed for good (purge_failed_chunks:1)" || nok "O5b setup: the chunk did not fail" "$OUT"
printf '%s' "$OUT" | grep 'last_error:.*context canceled' >/dev/null && ok "O5b DOG_DONE last_error keeps the CAUSE of a >5 KB failing statement" || nok "O5b the cause was truncated away" "$(printf '%s' "$OUT" | grep -o 'last_error:.*' | cut -c1-300)"
if printf '%s' "$OUT" | grep 'bulk-wisp-' >/dev/null; then nok "O5b the id list leaked into the DOG_DONE line" "$(printf '%s' "$OUT" | grep -o 'last_error:.*' | cut -c1-300)"; else ok "O5b no id list in the DOG_DONE line"; fi
grep 'mail send' "$CALLS" | grep 'context canceled' >/dev/null && ok "O5b the mail names the cause" || nok "O5b the mail lost the cause" "$(grep 'mail send' "$CALLS" | cut -c1-300)"
if grep 'mail send' "$CALLS" | grep 'bulk-wisp-' >/dev/null; then nok "O5b the id list leaked into the mail"; else ok "O5b the mail carries no id list"; fi
: > "$CALLS"; echo 999 > "$T/failcount"
run_reaper FAIL_RE='DELETE FROM `hq`.wisp_events'     # the same failure on the next run; the anomaly state is kept
[ "$(mail_count)" = "0" ] && ok "O5b the same failure next run is NOT mailed again (the text is stable, dedupe holds)" || nok "O5b mailed again — the text changes every run" "$(grep 'mail send' "$CALLS" | cut -c1-260)"

# ── O6:the circuit breaker ───────────────────────────────────────────────────
echo "O6: consecutive failed chunks stop the purge"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES
      ('b1','closed','task',$(H 200),$(H 190),$(H 190)),('b2','closed','task',$(H 200),$(H 180),$(H 180)),('b3','closed','task',$(H 200),$(H 170),$(H 170)),
      ('b4','closed','task',$(H 200),$(H 160),$(H 160)),('b5','closed','task',$(H 200),$(H 150),$(H 150));
     INSERT INTO wisp_events (issue_id,event_type) SELECT id,'e' FROM wisps;
     CALL DOLT_COMMIT('-Am','b','--author','t <t@t.local>');" >/dev/null
echo 999 > "$T/failcount"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_PURGE_BATCH=1 FAIL_RE='DELETE FROM `hq`.wisp_events'
[ "$(field purge_failed_chunks)" = "3" ] && ok "O6 the purge gives up after 3 failed chunks in a row (not 5)" || nok "O6 circuit breaker" "$OUT"
[ "$(field purge_capped_dbs)" = "1" ] && [ "$(scalar "SELECT COUNT(*) FROM wisps")" = "5" ] && ok "O6 nothing purged, work reported as remaining" || nok "O6 state" "$OUT"

# ── O7: a failed sample is not "no orphans" ───────────────────────────────────
echo "O7: the orphan SAMPLE fails — reported, not read as a clean table"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 999 > "$T/failcount"
run_reaper FAIL_RE='SELECT c.issue_id'
[ "$(field orphan_failed_dbs)" = "1" ] && ok "O7 orphan_failed_dbs:1 — the failure is COUNTED" || nok "O7 a failed sample is silent" "$OUT"
[ "$(field orphan_swept)" = "0" ] && [ "$(orphans)" = "3,2,4,1" ] && ok "O7 nothing was deleted on a failed sample" || nok "O7 rows deleted" "$(orphans)"
printf '%s' "$OUT" | grep 'last_error:.*context canceled' >/dev/null && ok "O7 the cause is in the summary" || nok "O7 no last_error" "$OUT"
[ "$(field anomalies)" -ge 1 ] 2>/dev/null && ok "O7 an anomaly is recorded" || nok "O7 no anomaly" "$OUT"

# ── O8: the detector ──────────────────────────────────────────────────────────
echo "O8: sweeping more than GC_REAPER_ORPHAN_ALERT rows is an anomaly"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 0 > "$T/failcount"
run_reaper GC_REAPER_ORPHAN_ALERT=5
[ "$(field orphan_swept)" = "10" ] && [ "$(mail_count)" = "1" ] && grep -q 'swept more than 5 child rows' "$CALLS" \
  && ok "O8 10 swept > alert 5: mailed, naming the threshold (stable text, no counts)" || nok "O8 detector" "$OUT | $(grep -c . "$CALLS") calls"

# ── O9: dry run ───────────────────────────────────────────────────────────────
echo "O9: dry run"
new_db; seed_orphans; : > "$CALLS"
run_reaper GC_REAPER_DRY_RUN=1
[ "$(orphans)" = "3,2,4,1" ] && [ "$(live)" = "3,1,3,1" ] && ok "O9 dry run deletes nothing" || nok "O9 dry run mutated the database" "$(orphans) / $(live)"
[ "$(field would_sweep)" = "10" ] && printf '%s' "$OUT" | grep '(dry run)' >/dev/null && ok "O9 reports would_sweep:10" || nok "O9 dry-run summary" "$OUT"

# ── O10: the kill switch and its validation ───────────────────────────────────
echo "O10: GC_REAPER_ORPHAN_SWEEP"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_ORPHAN_SWEEP=0
[ "$(orphans)" = "3,2,4,1" ] && [ "$(field orphan_swept)" = "0" ] && ok "O10 =0 switches the sweep off" || nok "O10 kill switch" "$OUT | $(orphans)"
run_reaper GC_REAPER_ORPHAN_SWEEP=maybe
[ "$(orphans)" = "0,0,0,0" ] && [ "$(field anomalies)" = "1" ] && grep -q 'GC_REAPER_ORPHAN_SWEEP' "$CALLS" \
  && ok "O10 a malformed value is an ANOMALY and the default (on) applies — not a silent skip" || nok "O10 malformed value" "$OUT | $(orphans)"

# ── O11: a STALE sample naming a live wisp cannot delete its rows ─────────────
echo "O11: the guard lives inside the DELETE"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper FAKE_SAMPLE='live-open'
[ "$(live)" = "3,1,3,1" ] && ok "O11 the rows of a LIVE wisp named by a stale sample survive" || nok "O11 a live wisp's rows were deleted" "$(live)"
[ "$(field orphan_swept)" = "0" ] && grep -q 'removed nothing' "$CALLS" && ok "O11 swept nothing, and said the sample was stale" || nok "O11 stale sample not reported" "$OUT"

# ── O12: unexpected characters in an orphan id ────────────────────────────────
echo "O12: an orphan id with unexpected characters"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_labels VALUES ('bad''id','z'),('gone-9','x'),('live-open','a');
     CALL DOLT_COMMIT('-Am','bad','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper
[ "$RC" -eq 0 ] && ok "O12 terminates (rc=0) — the refused id does not make the sweep loop" || nok "O12 rc" "rc=$RC"
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id='gone-9'")" = "0" ] && ok "O12 the ordinary orphan is swept" || nok "O12 good orphan left"
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id='bad''id'")" = "1" ] && ok "O12 the odd id is NOT interpolated into SQL (row untouched)" || nok "O12 the odd id was deleted"
grep -q 'unexpected characters' "$CALLS" && ok "O12 it is reported" || nok "O12 silent" "$(cat "$CALLS")"

# ── O13: the order's timeout covers the budgets ───────────────────────────────
echo "O13: the order declares a timeout that covers the script's budgets"
ORDER_TOML="$HERE/../orders/mol-dog-reaper.toml"
if [ ! -f "$ORDER_TOML" ]; then
  nok "O13 order file not found" "$ORDER_TOML"
else
  TO="$(sed -n 's/^timeout[[:space:]]*=[[:space:]]*"\([0-9][0-9]*\)s".*/\1/p' "$ORDER_TOML" | head -1)"
  PB="$(grep -o 'GC_REAPER_PURGE_BUDGET_S:-[0-9]*' "$REAPER_SH" | head -1 | cut -d- -f2)"
  OB="$(grep -o 'GC_REAPER_ORPHAN_BUDGET_S:-[0-9]*' "$REAPER_SH" | head -1 | cut -d- -f2)"
  if [ -z "$TO" ]; then
    nok "O13 mol-dog-reaper.toml declares no timeout (the engine default for an exec order is 300 s)" "$ORDER_TOML"
  elif [ -z "$PB" ]; then
    nok "O13 could not read the purge budget default from the script" "PB=$PB OB=$OB"
  elif [ "$TO" -ge $((PB + ${OB:-0} + 120)) ]; then
    ok "O13 timeout ${TO}s >= purge budget ${PB}s + orphan budget ${OB:-0}s + 120s of fixed work"
  else
    nok "O13 timeout ${TO}s does not cover purge ${PB}s + orphan ${OB:-0}s + 120s of fixed work" "raise timeout in orders/mol-dog-reaper.toml"
  fi
fi

# ── O14: the per-run row cap ──────────────────────────────────────────────────
echo "O14: row cap — the run stops, says work remains, the next run carries on"
new_db
V=""; for i in $(seq 1 120); do V="$V${V:+,}('gone-$(( (i - 1) / 20 ))','e')"; done   # 6 orphan wisps x 20 events
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_events (issue_id,event_type) VALUES $V, ('live-open','c'),('live-open','u');
     CALL DOLT_COMMIT('-Am','cap','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_ORPHAN_MAX_ROWS=25 GC_REAPER_ORPHAN_SELECT_ROWS=50 GC_REAPER_PURGE_ROW_BATCH=50
SW="$(field orphan_swept)"
# EXACT, not "roughly": one round names several wisps (20 rows each; the sample can touch all six)
# and the guarded DELETE removes every row of every wisp it names, so a per-round check alone sweeps
# all 120 — the bug this scenario found. The last batch must be shrunk to the allowance.
[ "${SW:-}" = "25" ] && ok "O14 the cap is EXACT: orphan_swept:25 of 120 orphans (cap 25)" || nok "O14 the row cap is not exact" "orphan_swept=${SW:-?} — $OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisp_events")" = "97" ] && ok "O14 95 orphan events + the 2 live ones remain after the capped run" || nok "O14 rows left after the capped run" "events: $(scalar "SELECT COUNT(*) FROM wisp_events")"
[ "$(field orphan_capped_dbs)" = "1" ] && ok "O14 the summary says work REMAINS (orphan_capped_dbs:1)" || nok "O14 capped not reported" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisp_events WHERE issue_id='live-open'")" = "2" ] && ok "O14 the live wisp's events are untouched" || nok "O14 live rows changed"
run_reaper
[ "$(scalar "SELECT COUNT(*) FROM wisp_events")" = "2" ] && [ "$(field orphan_capped_dbs)" = "0" ] && ok "O14 the next (uncapped) run finishes the drain" || nok "O14 carry-over" "$OUT | events: $(scalar "SELECT COUNT(*) FROM wisp_events")"

# ── O14b: a cap larger than one batch — the remainder is shrunk to the allowance ──
echo "O14b: cap 70, batch 50 — one full batch, then exactly what is left of the allowance"
new_db
V=""; for i in $(seq 1 120); do V="$V${V:+,}('gone-$(( (i - 1) / 20 ))','e')"; done
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_events (issue_id,event_type) VALUES $V, ('live-open','c'),('live-open','u');
     CALL DOLT_COMMIT('-Am','cap2','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_ORPHAN_MAX_ROWS=70 GC_REAPER_ORPHAN_SELECT_ROWS=50 GC_REAPER_PURGE_ROW_BATCH=50
[ "$(field orphan_swept)" = "70" ] && ok "O14b orphan_swept:70 — exact across statements" || nok "O14b the cap is not exact across statements" "$OUT"
[ "$(sqlcount 'DELETE FROM `hq`.wisp_events WHERE .*LIMIT 20')" -ge 1 ] && ok "O14b the last statement was shrunk to the allowance (LIMIT 20)" || nok "O14b no shrunk statement" "$(grep -c 'wisp_events' "$SQL_LOG") statements on wisp_events"
[ "$(scalar "SELECT COUNT(*) FROM wisp_events")" = "52" ] && [ "$(scalar "SELECT COUNT(*) FROM wisp_events WHERE issue_id='live-open'")" = "2" ] \
  && ok "O14b 50 orphan events + the 2 live ones remain" || nok "O14b rows left" "events: $(scalar "SELECT COUNT(*) FROM wisp_events")"

# ── O14c: a remainder of ONE row is left for the next run ─────────────────────
# On this Dolt, DELETE ... LIMIT 1 on wisp_dependencies (it carries a foreign key) answers
# ROW_COUNT() = -1 although the row is removed (probed with `dolt sql`; every other LIMIT and every
# other table counts exactly). The script reads -1 as a failed statement and would retry it: the row is
# gone but uncounted, and a false "removed nothing" anomaly is mailed. So no one-row DELETE is sent.
echo "O14c: cap 3 over comments(2) -> dependencies(1): the last single row is left, nothing is mis-counted"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_ORPHAN_MAX_ROWS=3
[ "$(field orphan_swept)" = "2" ] && [ "$(orphans)" = "3,0,4,1" ] && ok "O14c 2 swept (the comments); the dependency row is left for the next run" || nok "O14c remainder handling" "$OUT | $(orphans)"
[ "$(sqlcount 'LIMIT 1;')" = "0" ] && ok "O14c no one-row DELETE was sent" || nok "O14c a one-row DELETE was sent" "$(grep 'LIMIT 1;' "$SQL_LOG" | head -2)"
[ "$(field anomalies)" = "0" ] && [ "$(mail_count)" = "0" ] && [ "$(field orphan_capped_dbs)" = "1" ] && ok "O14c capped, no anomaly, no mail" || nok "O14c unexpected anomaly/mail" "$OUT"
run_reaper
[ "$(orphans)" = "0,0,0,0" ] && [ "$(live)" = "3,1,3,1" ] && ok "O14c the next (uncapped) run takes the rest; every live row is intact" || nok "O14c carry-over" "$(orphans) / $(live)"

# ── O15: the free-disk floor ──────────────────────────────────────────────────
echo "O15: free-disk floor"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper FAKE_DF_AVAIL_KB=1048576     # 1 GiB free < the default floor (18 GiB, see O15b)
[ "$(orphans)" = "3,2,4,1" ] && [ "$(field orphan_swept)" = "0" ] && ok "O15 below the floor: nothing is deleted" || nok "O15 swept below the floor" "$OUT | $(orphans)"
[ "$(field orphan_halted_dbs)" = "1" ] && printf '%s' "$OUT" | grep 'orphan_halt: .*below the floor' >/dev/null && ok "O15 the DOG_DONE line counts it and names the reason" || nok "O15 the halt is silent" "$OUT"
[ "$(mail_count)" = "0" ] && ok "O15 low disk is not a mail (the disk guard already alarms)" || nok "O15 mailed" "$(cat "$CALLS")"
run_reaper FAKE_DF_AVAIL_KB=1048576 GC_REAPER_ORPHAN_MIN_FREE_GB=0
[ "$(orphans)" = "0,0,0,0" ] && [ "$(field orphan_halted_dbs)" = "0" ] && ok "O15 GC_REAPER_ORPHAN_MIN_FREE_GB=0 switches the guard off" || nok "O15 guard-off" "$OUT | $(orphans)"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper FAKE_DF_FAIL=1               # df unreadable: "cannot tell" must not read as "enough"
[ "$(orphans)" = "3,2,4,1" ] && [ "$(field orphan_swept)" = "0" ] && ok "O15 df unreadable: nothing is deleted (inert under doubt)" || nok "O15 swept blind" "$OUT | $(orphans)"
[ "$(field orphan_halted_dbs)" = "1" ] && [ "$(mail_count)" = "1" ] && grep -q 'could not be read' "$CALLS" && ok "O15 an unreadable df IS mailed (something is wrong)" || nok "O15 unreadable df is silent" "$OUT | $(cat "$CALLS")"

# ── O15b: the DEFAULT floor sits above the dolt_gc headroom gate ──────────────
# The GC job (dolt-gc-maintenance) only runs with free space >= max(200% of the store, store + 3 GB),
# ~15 GiB for the 7.6 GB hq, and a delete-based drain costs ~8 KB of disk per row until a FULL gc. A
# floor below that gate would let the sweep eat the headroom the GC needs to give space back — so the
# default is 18 GiB. This pins the default at its boundary; lower it only with a written reason.
echo "O15b: the default floor is 18 GiB — above the dolt_gc headroom gate"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper FAKE_DF_AVAIL_KB=17825792    # 17 GiB free: under the default
[ "$(orphans)" = "3,2,4,1" ] && [ "$(field orphan_halted_dbs)" = "1" ] && ok "O15b 17 GiB free: the sweep stays inert" || nok "O15b swept under the default floor" "$OUT | $(orphans)"
printf '%s' "$OUT" | grep 'orphan_halt: free disk 17 GiB is below the floor of 18 GiB' >/dev/null && ok "O15b the DOG_DONE line names both numbers" || nok "O15b halt reason" "$OUT"
run_reaper FAKE_DF_AVAIL_KB=19922944    # 19 GiB free: above it
[ "$(orphans)" = "0,0,0,0" ] && [ "$(field orphan_halted_dbs)" = "0" ] && ok "O15b 19 GiB free: the sweep runs" || nok "O15b did not sweep above the default floor" "$OUT | $(orphans)"

# ── O16:the empty-wisps seatbelt ─────────────────────────────────────────────
echo "O16: children exist but wisps is empty — nothing is deleted"
new_db
sql "INSERT INTO wisp_labels VALUES ('ghost','x'),('ghost','y');
     INSERT INTO wisp_events (issue_id,event_type) VALUES ('ghost','c'),('ghost','u'),('ghost','x');
     CALL DOLT_COMMIT('-Am','ghost','--author','t <t@t.local>');" >/dev/null
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels")" = "2" ] && [ "$(scalar "SELECT COUNT(*) FROM wisp_events")" = "3" ] && ok "O16 against an EMPTY wisps table no child row is deleted" || nok "O16 rows deleted under an empty wisps" "$OUT"
[ "$(field orphan_halted_dbs)" = "1" ] && [ "$(mail_count)" = "1" ] && grep -q 'wisps table of hq is empty or unreadable' "$CALLS" && ok "O16 it is reported (halted + mailed)" || nok "O16 silent" "$OUT | $(cat "$CALLS")"
new_db; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper
[ "$(field orphan_halted_dbs)" = "0" ] && [ "$(field anomalies)" = "0" ] && [ "$(mail_count)" = "0" ] && ok "O16 a legitimately empty database (no children) raises nothing" || nok "O16 noise on an empty database" "$OUT"

# ── O16b: `wisps` emptied MID-sweep stops the very next round ─────────────────
# The empty-wisps seatbelt used to be read once per database; a `wisps` table emptied or rebuilt while
# the sweep runs (a migration, another actor) then let it keep deleting every "orphan". It is re-read
# every round now. The stub empties hq.wisps right after the first sweep DELETE (comments come first).
echo "O16b: wisps emptied behind the script's back mid-sweep — the next round halts"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed" "$T/sabotage-done"
run_reaper SABOTAGE_AFTER_RE='DELETE FROM `hq`.wisp_comments' SABOTAGE_DONE="$T/sabotage-done"
[ -e "$T/sabotage-done" ] && ok "O16b (setup) wisps was emptied right after the first sweep DELETE" || nok "O16b the sabotage never fired" "$(grep -c 'DELETE FROM' "$SQL_LOG") DELETE statements"
C1="$(scalar "SELECT COUNT(*) FROM wisp_comments WHERE issue_id='live-open'")"; L1="$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id='live-open'")"; E1="$(scalar "SELECT COUNT(*) FROM wisp_events WHERE issue_id='live-open'")"
[ "$C1,$L1,$E1" = "1,2,2" ] && ok "O16b the children of the now-vanished wisp were NOT swept (comments,labels,events = 1,2,2)" || nok "O16b children deleted after wisps was emptied" "comments,labels,events = $C1,$L1,$E1"
[ "$(field orphan_halted_dbs)" = "1" ] && grep -q 'empty or unreadable' "$CALLS" && ok "O16b halted and mailed (empty or unreadable)" || nok "O16b not halted" "$OUT"

# ── O17:the purge breaker tripped -> the sweep does not add load ─────────────
echo "O17: the purge's failure breaker tripped — the sweep waits"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES
      ('b1','closed','task',$(H 200),$(H 190),$(H 190)),('b2','closed','task',$(H 200),$(H 180),$(H 180)),('b3','closed','task',$(H 200),$(H 170),$(H 170)),
      ('b4','closed','task',$(H 200),$(H 160),$(H 160)),('b5','closed','task',$(H 200),$(H 150),$(H 150));
     INSERT INTO wisp_events (issue_id,event_type) SELECT id,'e' FROM wisps;
     INSERT INTO wisp_labels VALUES ('gone-x','z');
     CALL DOLT_COMMIT('-Am','b','--author','t <t@t.local>');" >/dev/null
echo 999 > "$T/failcount"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"
run_reaper GC_REAPER_PURGE_BATCH=1 FAIL_RE='DELETE FROM `hq`.wisp_events'
[ "$(field purge_failed_chunks)" = "3" ] && ok "O17 (setup) the breaker tripped after 3 failed chunks" || nok "O17 setup: the breaker did not trip" "$OUT"
[ "$(scalar "SELECT COUNT(*) FROM wisp_labels WHERE issue_id='gone-x'")" = "1" ] && [ "$(field orphan_swept)" = "0" ] && ok "O17 the sweep did not run: the orphan is still there" || nok "O17 the sweep piled on an unwell Dolt" "$OUT"
[ "$(field orphan_halted_dbs)" = "1" ] && printf '%s' "$OUT" | grep 'orphan_halt: .*failure breaker' >/dev/null && ok "O17 counted and named in the DOG_DONE line" || nok "O17 the halt is silent" "$OUT"

# ── O18: a slow sweep in one database must not eat the PURGE budget of the next ─
# purge_closed_wisps measures its budget from the start of the script, and the sweep runs inside the
# per-database loop: a long sweep in hq (up to 180 s) used to leave the databases after it with no purge
# budget, run after run for the whole drain — and the purge is what keeps the wisps tables small. The
# sweep now shifts the purge clock by the time it spent. hq's first sample sleeps 25 s (a 5 s sweep
# budget ends the sweep right after it); zz comes after hq and has two old closed wisps to purge.
echo "O18: hq's slow sweep does not starve zz's purge (purge budget 20 s, sweep ~25 s)"
new_db; new_db zz
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_comments (issue_id,text) VALUES ('gone-1','t1');
     CALL DOLT_COMMIT('-Am','o18','--author','t <t@t.local>');" >/dev/null
( cd "$DOLT_ROOT" && dolt sql -q "USE zz;
    INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('z1','closed','task',$(H 200),$(H 100),$(H 100)),('z2','closed','task',$(H 200),$(H 100),$(H 100));
    INSERT INTO wisp_events (issue_id,event_type) VALUES ('z1','e'),('z2','e');
    CALL DOLT_COMMIT('-Am','zz','--author','t <t@t.local>');" >/dev/null 2>&1 )
: > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 0 > "$T/failcount"
run_reaper GC_REAPER_PURGE_BUDGET_S=20 GC_REAPER_ORPHAN_BUDGET_S=5 SLOW_RE='`hq`\.wisp_comments c' SLOW_S=25
[ "$(field purged)" = "2" ] && [ "$(field purge_capped_dbs)" = "0" ] && ok "O18 zz's purge ran in full although hq's sweep took ~25 s" || nok "O18 the sweep ate the next database's purge budget" "$OUT"
ZW="$(cd "$DOLT_ROOT/zz" && dolt sql -r csv -q 'SELECT COUNT(*) FROM wisps' 2>/dev/null | tail -1 | tr -d '\r')"
[ "$ZW" = "0" ] && ok "O18 zz's closed wisps are gone" || nok "O18 zz still has wisps" "count=$ZW"
rm -rf "$DOLT_ROOT/zz"      # later scenarios expect the single hq database

# ── O8b:drain mode does not page ─────────────────────────────────────────────
echo "O8b: a run that stopped at a budget is not mailed as an orphan producer"
new_db; seed_orphans; : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed"; echo 0 > "$T/failcount"
# cap 4 over comments(2) -> dependencies(1) -> labels(3): 2 + 1 swept, then a remainder of ONE row is
# left (a one-row DELETE is never sent, see O14c) -> capped with 3 swept, above the alert of 2.
run_reaper GC_REAPER_ORPHAN_ALERT=2 GC_REAPER_ORPHAN_MAX_ROWS=4
SW="$(field orphan_swept)"
[ "${SW:-0}" -gt 2 ] && [ "$(field orphan_capped_dbs)" = "1" ] && [ "$(mail_count)" = "0" ] && ok "O8b swept $SW > alert 2 but capped: no mail (the drain is tracked, not a new producer)" || nok "O8b a capped run paged" "$OUT | mails: $(mail_count)"

echo ""
echo "reaper-orphan-sweep selftest (ga-x2fj8h): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
