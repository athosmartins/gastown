#!/usr/bin/env bash
# reaper-orphan-count.selftest.sh — regression test for ga-hpdpij.
#
# THE GAPS (found while executing ga-5dggst, 2026-09-20; the orphans were then at 0 in all 8 databases):
#  1. The reaper's DOG_DONE summary only ever left the script as `gc session nudge deacon/ ... || true`
#     and a stdout echo. Nothing durable: 0 hits in .gc/events.jsonl and in the deacon transcript, so
#     "purge_failed_chunks:0, anomalies:0" had to be inferred by SQL.
#  2. While the orphan SWEEP is stopped (free-disk floor, GC_REAPER_ORPHAN_SWEEP=0, a budget, the purge
#     breaker) nothing COUNTED or alerted on NEW orphan child rows: the "new producer" alert only fires
#     in a run whose sweep finished. With the backlog at 0, any return of the orphans was invisible.
#
# This test runs the REAL scripts/reaper.sh against throwaway local Dolt repos (multi-database mode: `dolt
# sql` from the parent directory, no server) with stub `gc`/`bd`/`df` and a stub dolt-target.sh whose
# dolt_sql can log every statement (SQL_LOG), FAIL matching statements on demand (FAIL_RE + FAIL_COUNT) and be
# slow (SLOW_RE + SLOW_S). Same fixture schema as reaper-orphan-sweep.selftest.sh (that file is NOT edited:
# it stays the regression test of ga-x2fj8h). REAPER_SH overrides the script under test — point it at the
# previous version to see the red side.
#
# C1  THE decisive scenario (runs first, BAILS on failure — on the old code it is red in seconds): the sweep is
#     stopped by the free-disk floor and ONE orphan exists -> orphan_count:1 in the summary, nothing deleted.
# C1b above GC_REAPER_ORPHAN_COUNT_ALERT (in ONE database) it is an anomaly and a mail, sweep or no sweep;
#     under it, no anomaly and no mail.
# C2  the count is taken AFTER the sweep (orphans LEFT), exact, and live rows are never counted; it also runs
#     with the sweep switched off.
# C3  three states, never two: a failed read is `unknown`, NEVER `0` (all probes failed -> unknown; some failed
#     -> "N+", a lower bound, with orphan_count_unknown telling how many).
# C4  the alert text carries no counts, so the mail dedupe (same text within the TTL) sends it once.
# C5  the count is BOUNDED (LIMIT cap+1): it cannot run past Dolt's 30 s cutoff on a huge table, and a capped
#     answer is a lower bound ("N+"), not a number that reads as exact.
# C6  the count has its OWN wall-clock budget; what it did not reach is unknown (and mailed), not zero.
# C7  the count runs AFTER every database's purge: a slow count must not starve the purge budget of the
#     databases after it (the per-database budget hazard the in-loop placement has). Asserted on the ORDER of
#     the SQL statements, not on a race against a wall-clock budget (a few-second budget went red on a machine
#     at load average 35, for reasons that had nothing to do with the code).
# C8  the summary line is DURABLE: two runs leave two timestamped lines in .gc/runtime/reaper-summary.log,
#     the last one identical to the stdout line; a log that cannot be written is said so, never silent.
# C9  the log rotates (size cap, GC_REAPER_SUMMARY_LOG_KEEP generations) instead of growing for ever.
# C9b a log that was WRITTEN but could not be size-capped (the rename is impossible) still gets its line and says
#     so (summary_log:UNCAPPED): a swallowed `mv` would let it grow for ever, silently.
# C10 GC_REAPER_ORPHAN_COUNT=0 switches the count off (orphan_count:off, no probe); a malformed value is an
#     anomaly, not a silent skip.
# C11 a bead store the reaper SKIPS for its wisp_dependencies schema is still COUNTED (the count never reads that
#     table; leaving it out printed orphan_count:0 while its orphans piled up); with no bead store at all nothing
#     was measured -> `unknown`, not `0`.
# C12 the order's timeout covers ALL the script's wall-clock budgets, the count's included.
# C13 the schema probe never false-negatives: `printf | grep -qx` under pipefail skipped HEALTHY databases as
#     "unrecognised schema" (and flaked this suite); it is now a pipe-free whole-line membership test.

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

T="$(mktemp -d "${TMPDIR:-/tmp}/reaper-orphan-count-selftest.XXXXXX")" || exit 1
# chmod first: C9b makes a directory read-only, and a test that dies inside it must not leave an undeletable tree.
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
export DOLT_ROOT_PATH="$T/doltroot"; mkdir -p "$DOLT_ROOT_PATH"
DOLT_ROOT="$T/dolt"; mkdir -p "$DOLT_ROOT"
CITY="$T/city"; mkdir -p "$CITY/.beads" "$CITY/.gc/runtime"
printf '{"dolt_database":"hq"}\n' > "$CITY/.beads/metadata.json"
CALLS="$T/calls.log"; : > "$CALLS"
export SQL_LOG="$T/sql.log"; : > "$SQL_LOG"
SUMLOG="$CITY/.gc/runtime/reaper-summary.log"

# ── the script under test + stubs, side by side (the script sources its siblings) ──
SD="$T/scripts"; mkdir -p "$SD" "$T/bin"
cp "$REAPER_SH" "$SD/reaper.sh"
cat > "$SD/_bd_trace.sh" <<'EOF'
_BD_TRACE_CALLER="${1:-unknown}"
EOF
cat > "$SD/dolt-target.sh" <<'EOF'
#!/usr/bin/env bash
# Test double for the shared connection setup (SOURCED by reaper.sh, i.e. it runs under that script's
# `set -o pipefail`: hence [[ =~ ]] below and no `printf | grep -q`, whose matching grep can report FAILURE when its
# writer catches SIGPIPE — an injected failure or delay would silently not happen, ~1-2% under load; ga-5bxuam).
# Hooks, all driven by env the scenario passes:
#   SQL_LOG   every statement is appended (one line each)
#   FAIL_RE   a statement matching this ERE fails ("context canceled", the shape of Dolt's cutoff) while the
#             counter file FAIL_COUNT is > 0 (decremented per failure). The regex is matched per LINE, so a
#             statement meant to be targeted must be a single line.
#   SLOW_RE   a statement matching this ERE sleeps SLOW_S seconds first
dolt_sql() {
    _q=""
    for _a in "$@"; do _q="$_q $_a"; done
    printf '%s\n' "$_q" | tr '\n' ' ' >> "$SQL_LOG"; echo >> "$SQL_LOG"
    if [ -n "${FAIL_RE:-}" ] && [[ "$_q" =~ $FAIL_RE ]]; then
        _n=$(cat "$FAIL_COUNT" 2>/dev/null || echo 0)
        if [ "$_n" -gt 0 ]; then
            echo $((_n - 1)) > "$FAIL_COUNT"
            echo "error on line 1 for query $_q: context canceled" >&2
            return 1
        fi
    fi
    if [ -n "${SLOW_RE:-}" ] && [[ "$_q" =~ $SLOW_RE ]]; then
        sleep "${SLOW_S:-2}"
    fi
    _rc=0
    ( cd "$DOLT_TEST_ROOT" && dolt sql "$@" ) || _rc=$?
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
# `df -Pk <path>` double: free space is whatever the scenario says (default: plenty), so this suite does not
# depend on how full the machine running it happens to be. FAKE_DF_AVAIL_KB=1048576 (1 GiB) is BELOW the sweep's
# default free-disk floor (18 GiB): the sweep is halted, which is the situation the story is about.
cat > "$T/bin/df" <<'EOF'
#!/bin/bash
[ "${FAKE_DF_FAIL:-0}" = "1" ] && exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 999999999 1000 ${FAKE_DF_AVAIL_KB:-999999999} 1% /"
EOF
chmod +x "$T/bin/gc" "$T/bin/bd" "$T/bin/df"
LOW_DISK=1048576

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

new_db() {  # new_db [name] — a fresh fixture database (default hq)
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
#   orphans: labels 3, comments 2, events 4, dependencies 1
#   live   : labels 3, comments 1, events 3, dependencies 1
# The COUNT covers comments + labels + events (the three tables of the story): 2 + 3 + 4 = 9.
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
  # /bin/bash, not `bash`: PATH may resolve to Homebrew bash 5.x, but launchd and the gate run the script
  # under the system bash 3.2 — the version whose quirks (empty arrays, [[ =~ ]]) bite.
  OUT="$( cd "$T" && env GC_CITY_PATH="$CITY" GC_CITY="$CITY" PATH="$T/bin:$PATH" GC_REAPER_PURGE_RETRY_PAUSE_S=0 \
        FAIL_COUNT="$T/failcount" ${envs[@]+"${envs[@]}"} /bin/bash "$SD/reaper.sh" 2>"$T/stderr.log" )"; RC=$?
}
# one summary field: everything after "<name>:" up to the next comma (so "4+", "unknown", "off" come through)
fld() { printf '%s\n' "$OUT" | grep -o "$1:[^,]*" | head -1 | cut -d: -f2 | tr -d ' '; }
mail_count() { grep -c '^gc mail send' "$CALLS" || true; }
sqlcount() { grep -c -E "$1" "$SQL_LOG" || true; }
fresh() {  # fresh — clear per-scenario state: calls, mail dedupe, durable log, injected failures
  : > "$CALLS"; rm -f "$CITY/.gc/runtime/reaper-anomaly-mailed" "$SUMLOG" "$SUMLOG".[0-9]*; echo 0 > "$T/failcount"
}

# ── C1: the decisive scenario — sweep stopped by the disk floor, ONE orphan ───
echo "C1: sweep halted by the free-disk floor + 1 injected orphan -> orphan_count>=1 in the summary"
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_events (issue_id,event_type) VALUES ('live-open','c'),('gone-1','c');
     CALL DOLT_COMMIT('-Am','one orphan','--author','t <t@t.local>');" >/dev/null
fresh
[ "$(orphans)" = "0,0,1,0" ] || nok "C1 fixture is not what the test assumes" "orphans=$(orphans)"
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK
[ "$RC" -eq 0 ] && ok "C1 reaper runs clean (rc=0)" || nok "C1 rc" "rc=$RC $(tail -3 "$T/stderr.log")"
{ [ "$(fld orphan_halted_dbs)" = "1" ] && [ "$(fld orphan_swept)" = "0" ]; } \
  && ok "C1 the gap is reproduced: the disk floor halted the sweep, nothing swept" || nok "C1 the sweep was not halted by the floor" "$OUT"
[ "$(fld orphan_count)" = "1" ] && ok "C1 orphan_count:1 although the sweep is halted" || nok "C1 the orphan is INVISIBLE while the sweep is halted (no orphan_count:1)" "$OUT"
[ "$(orphans)" = "0,0,1,0" ] && [ "$(sqlcount 'DELETE FROM')" = "0" ] && ok "C1 the count is READ-ONLY: the orphan is still there, no DELETE was issued" || nok "C1 the count deleted or changed something" "orphans=$(orphans) deletes=$(sqlcount 'DELETE FROM')"
{ [ "$(fld anomalies)" = "0" ] && [ "$(mail_count)" = "0" ]; } && ok "C1 one orphan is under the alert limit: no anomaly, no mail" || nok "C1 unexpected anomaly/mail" "$OUT"
# The first scenario is the decisive one: if the count does not work at all, the rest is noise (and on the OLD
# code this is what turns the test red, fast — the gate runs a new selftest against the base under a time cap).
[ "$FAIL" -eq 0 ] || { echo ""; echo "reaper-orphan-count selftest (ga-hpdpij): BAIL after C1 — $PASS passed, $FAIL failed"; exit 1; }

# ── C1b: the alert limit, sweep halted ─────────────────────────────────────────
echo "C1b: more orphans than GC_REAPER_ORPHAN_COUNT_ALERT in one database -> anomaly + mail, sweep halted"
new_db; seed_orphans; fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT_ALERT=5
{ [ "$(fld orphan_count)" = "9" ] && [ "$(fld orphan_count_over_dbs)" = "1" ]; } && ok "C1b orphan_count:9 (2 comments + 3 labels + 4 events; live rows and dependencies not counted), over_dbs:1" || nok "C1b count/over_dbs" "$OUT"
{ [ "$(mail_count)" = "1" ] && grep -q 'hq: .*child rows of wisps that no longer exist' "$CALLS"; } && ok "C1b the anomaly is mailed once and names the database" || nok "C1b no mail / wrong text" "$(cat "$CALLS")"
[ "$(orphans)" = "3,2,4,1" ] && ok "C1b nothing was deleted (sweep halted, count read-only)" || nok "C1b rows changed" "$(orphans)"
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK
{ [ "$(fld orphan_count)" = "9" ] && [ "$(fld orphan_count_over_dbs)" = "0" ] && [ "$(mail_count)" = "0" ]; } && ok "C1b the DEFAULT limit (1000) leaves 9 orphans alone: no anomaly, no mail" || nok "C1b default limit" "$OUT | mails=$(mail_count)"

# ── C2: after the sweep; exact; live rows never counted; also with the sweep off ─
echo "C2: the count is taken AFTER the sweep, exact, live rows excluded; the sweep switch does not switch it off"
new_db; seed_orphans; fresh
run_reaper
{ [ "$(fld orphan_swept)" = "10" ] && [ "$(fld orphan_count)" = "0" ] && [ "$(fld orphan_count_unknown)" = "0" ]; } && ok "C2 sweep removed all 10, the count LEFT is a KNOWN zero (orphan_count:0, nothing unknown)" || nok "C2 after-sweep count" "$OUT"
[ "$(live)" = "3,1,3,1" ] && ok "C2 live rows untouched" || nok "C2 live rows changed" "$(live)"
new_db; seed_orphans; fresh
run_reaper GC_REAPER_ORPHAN_SWEEP=0
{ [ "$(fld orphan_swept)" = "0" ] && [ "$(fld orphan_count)" = "9" ] && [ "$(orphans)" = "3,2,4,1" ]; } && ok "C2 sweep switched OFF: nothing deleted, orphan_count:9 still reported" || nok "C2 sweep off" "$OUT | $(orphans)"

# ── C3: three states — a failed read is unknown, NEVER zero ───────────────────
echo "C3: a count that could not be read is 'unknown', not 0"
new_db; seed_orphans; fresh; echo 99 > "$T/failcount"
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK FAIL_RE='orphan_count_probe'
{ [ "$(fld orphan_count)" = "unknown" ] && [ "$(fld orphan_count_unknown)" = "3" ]; } && ok "C3 every probe failed -> orphan_count:unknown, orphan_count_unknown:3" || nok "C3 all-failed" "$OUT"
# A `case`, not `printf | grep -q`: under pipefail a matching grep can leave its writer with SIGPIPE and the pipeline
# then reports "no match" (measured: ~1% of runs on a machine at load 45), which would turn this negative check into a
# false pass.
case "$OUT" in
  *orphan_count:0*) nok "C3 a FAILED read reads as orphan_count:0" "$OUT" ;;
  *)                ok  "C3 a failed read never reads as orphan_count:0" ;;
esac
{ [ "$RC" -eq 0 ] && [ "$(mail_count)" = "1" ] && grep -q 'orphan wisp_comments count failed' "$CALLS"; } && ok "C3 the failed reads are an anomaly (mailed) and the run still completes" || nok "C3 failure not reported" "rc=$RC mails=$(mail_count)"
fresh; echo 99 > "$T/failcount"
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK FAIL_RE='wisp_events c WHERE NOT EXISTS.*orphan_count_probe'
{ [ "$(fld orphan_count)" = "5+" ] && [ "$(fld orphan_count_unknown)" = "1" ]; } && ok "C3 only the events probe failed -> orphan_count:5+ (a lower bound: 2 comments + 3 labels known), unknown:1" || nok "C3 partial" "$OUT"
# Answered ZEROS must not speak for a probe that did not answer: that is "unknown", not "0" and not "0+".
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     CALL DOLT_COMMIT('-Am','live only','--author','t <t@t.local>');" >/dev/null
fresh; echo 99 > "$T/failcount"
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK FAIL_RE='wisp_events c WHERE NOT EXISTS.*orphan_count_probe'
{ [ "$(fld orphan_count)" = "unknown" ] && [ "$(fld orphan_count_unknown)" = "1" ]; } && ok "C3 two probes answered zero and one failed -> unknown: the zeros do not speak for the failed probe" || nok "C3 zeros + a failure read as a number" "$OUT"

# ── C4: the alert text carries no counts -> the mail dedupe holds ──────────────
echo "C4: the alert is one stable text: a second run with MORE orphans is not mailed again"
new_db; seed_orphans; fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT_ALERT=5
# 3 more orphans, spread over the tables so that no probe reaches its cap (alert 5 -> cap 6) and the number stays exact
sql "INSERT INTO wisp_comments (issue_id,text) VALUES ('gone-3','c1'),('gone-3','c2');
     INSERT INTO wisp_labels VALUES ('gone-3','z');
     CALL DOLT_COMMIT('-Am','more','--author','t <t@t.local>');" >/dev/null
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT_ALERT=5
{ [ "$(fld orphan_count)" = "12" ] && [ "$(mail_count)" = "1" ]; } && ok "C4 orphan_count went 9 -> 12 yet the mail went out ONCE (dedupe on stable text)" || nok "C4 re-mailed or wrong count" "$OUT | mails=$(mail_count)"

# ── C5: bounded ───────────────────────────────────────────────────────────────
echo "C5: the count is bounded (LIMIT alert+1); a capped answer is a lower bound"
new_db
V=""; for i in $(seq 1 130); do V="$V${V:+,}('gone-$((i % 3))','e')"; done
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     INSERT INTO wisp_events (issue_id,event_type) VALUES $V, ('live-open','c');
     CALL DOLT_COMMIT('-Am','bulk','--author','t <t@t.local>');" >/dev/null
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT_ALERT=3
{ [ "$(fld orphan_count)" = "4+" ] && [ "$(fld orphan_count_over_dbs)" = "1" ]; } && ok "C5 130 orphan events with alert 3 -> orphan_count:4+ (capped at 4 = alert+1), over_dbs:1" || nok "C5 capped count" "$OUT"
NP="$(sqlcount 'orphan_count_probe')"; NU="$(grep 'orphan_count_probe' "$SQL_LOG" | grep -c -v 'LIMIT 4' || true)"
{ [ "${NP:-0}" -ge 3 ] && [ "${NU:-1}" = "0" ]; } && ok "C5 all $NP count statements carry LIMIT 4 (none is an unbounded anti-join)" || nok "C5 unbounded count statement" "probes=$NP without_limit=$NU"

# ── C6: the count's own budget ────────────────────────────────────────────────
echo "C6: the count has its own wall-clock budget; what it did not reach is unknown, not zero"
new_db; seed_orphans; fresh
# Budget 2 s, each probe 3 s: the first probe starts inside the budget and overruns it, so the other two are never
# started. (A 1 s budget would be flaky by construction: the phase counts whole $SECONDS, so a 1 s budget has
# anywhere between 0 and 1 s of real slack before the FIRST probe.)
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT_BUDGET_S=2 SLOW_RE='orphan_count_probe' SLOW_S=3
{ [ "$RC" -eq 0 ] && [ "$(fld orphan_count)" = "2+" ] && [ "$(fld orphan_count_unknown)" = "2" ]; } && ok "C6 budget spent after the first probe (2 comments): orphan_count:2+, 2 probes unknown" || nok "C6 budget" "rc=$RC $OUT"
{ [ "$(mail_count)" = "1" ] && grep -q 'ran out of its' "$CALLS"; } && ok "C6 running out of budget is an anomaly (mailed), not silent" || nok "C6 budget cut is silent" "$(cat "$CALLS")"

# ── C7: the count must not starve the purge of the databases after it ─────────
echo "C7: the count runs AFTER every database's purge (so a slow count cannot eat the purge budget of zz)"
new_db; seed_orphans
new_db zz
( cd "$DOLT_ROOT" && dolt sql -q "USE zz;
    INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('z1','closed','task',$(H 200),$(H 100),$(H 100)),('z2','closed','task',$(H 200),$(H 100),$(H 100));
    INSERT INTO wisp_events (issue_id,event_type) VALUES ('z1','e'),('z2','e');
    CALL DOLT_COMMIT('-Am','zz','--author','t <t@t.local>');" >/dev/null 2>&1 )
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK
# The property is the ORDER of the statements — deterministic — not a race against a wall-clock budget. A count
# placed inside the per-database loop would issue hq's probes before zz's purge, charging their time to zz's
# purge budget. The loop is alphabetical (hq, zz), so zz's last DELETE is the last purge statement of the run.
LAST_PURGE="$(grep -n -E 'DELETE FROM .zz.\.' "$SQL_LOG" | tail -1 | cut -d: -f1)"
FIRST_PROBE="$(grep -n 'orphan_count_probe' "$SQL_LOG" | head -1 | cut -d: -f1)"
{ [ -n "$LAST_PURGE" ] && [ -n "$FIRST_PROBE" ] && [ "$LAST_PURGE" -lt "$FIRST_PROBE" ]; } \
  && ok "C7 zz's last purge statement (SQL log line $LAST_PURGE) precedes the first count probe (line $FIRST_PROBE)" \
  || nok "C7 a count probe was issued before the last database's purge finished (or one of the two never ran)" "last_purge=${LAST_PURGE:-none} first_probe=${FIRST_PROBE:-none}"
{ [ "$(fld purged)" = "2" ] && [ "$(fld purge_capped_dbs)" = "0" ]; } && ok "C7 zz's purge ran in full" || nok "C7 zz's purge did not run in full" "$OUT"
ZW="$(cd "$DOLT_ROOT/zz" && dolt sql -r csv -q 'SELECT COUNT(*) FROM wisps' 2>/dev/null | tail -1 | tr -d '\r')"
[ "$ZW" = "0" ] && ok "C7 zz's closed wisps are gone" || nok "C7 zz still has wisps" "count=$ZW"
rm -rf "$DOLT_ROOT/zz"      # later scenarios expect the single hq database

# ── C8: the summary line is durable ───────────────────────────────────────────
echo "C8: two runs leave two timestamped summary lines in .gc/runtime/reaper-summary.log (no SQL needed)"
new_db; seed_orphans; fresh
run_reaper; run_reaper
LC="$( [ -f "$SUMLOG" ] && wc -l < "$SUMLOG" | tr -d ' ' || echo missing )"
[ "$LC" = "2" ] && ok "C8 two runs -> two lines in $(basename "$SUMLOG")" || nok "C8 log lines" "lines=$LC file=$SUMLOG"
{ [ -f "$SUMLOG" ] && ! grep -q -v '^[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z .*stale_wisps:' "$SUMLOG"; } && ok "C8 every line = UTC timestamp + the summary" || nok "C8 line format" "$(cat "$SUMLOG" 2>/dev/null | cut -c1-140)"
STDOUT_LINE="$(printf '%s\n' "$OUT" | grep '^reaper: ' | tail -1)"; LAST="$(tail -1 "$SUMLOG" 2>/dev/null)"
[ -n "$STDOUT_LINE" ] && [ "${LAST#* }" = "${STDOUT_LINE#reaper: }" ] && ok "C8 the last log line is the run's own summary, byte for byte" || nok "C8 log != stdout summary" "log: $LAST | out: $STDOUT_LINE"
grep -q 'orphan_count:' "$SUMLOG" 2>/dev/null && ok "C8 the line carries orphan_count" || nok "C8 orphan_count missing from the durable line"
: > "$T/afile"     # a regular FILE where the log's directory should be: mkdir -p cannot work
fresh
run_reaper GC_REAPER_SUMMARY_LOG="$T/afile/reaper-summary.log"
{ [ "$RC" -eq 0 ] && [ "$(fld summary_log)" = "FAILED" ] && grep -q '^gc session nudge deacon/ .*summary_log:FAILED' "$CALLS"; } && ok "C8 a log that cannot be written does not fail the run, and DOG_DONE + stdout SAY so (summary_log:FAILED)" || nok "C8 unwritable log is silent or fatal" "rc=$RC $OUT"

# ── C9: rotation ──────────────────────────────────────────────────────────────
echo "C9: the log rotates (size cap, KEEP generations)"
new_db; seed_orphans; fresh
for _ in 1 2 3 4 5 6 7 8; do run_reaper GC_REAPER_SUMMARY_LOG_MAX_BYTES=1024 GC_REAPER_SUMMARY_LOG_KEEP=2; done
{ [ -f "$SUMLOG.1" ] && [ -f "$SUMLOG.2" ] && [ ! -e "$SUMLOG.3" ]; } && ok "C9 rotated into .1 and .2 and NOT beyond KEEP=2 (no .3)" || nok "C9 generations" "$(ls -1 "$CITY/.gc/runtime" | grep summary | tr '\n' ' ')"
SZ="$(wc -c < "$SUMLOG" | tr -d ' ')"
[ "${SZ:-99999}" -lt 4096 ] && ok "C9 the live file stays small ($SZ bytes, cap 1024 + one line)" || nok "C9 the live file grew unbounded" "size=$SZ"
TOT="$(cat "$SUMLOG" "$SUMLOG".[0-9] 2>/dev/null | wc -l | tr -d ' ')"
[ "${TOT:-0}" -ge 3 ] && [ "${TOT:-0}" -le 8 ] && ok "C9 history is bounded but not lost ($TOT of 8 lines kept)" || nok "C9 lines kept" "kept=$TOT"

# ── C9b: a log that cannot be rotated is written anyway, and says so ──────────
echo "C9b: a log that could not be size-capped still gets its line and says so (summary_log:UNCAPPED)"
if [ "$(id -u)" = "0" ]; then
  echo "  skip - C9b needs a non-root user (root ignores directory permissions)"
else
  new_db; seed_orphans; fresh
  { head -c 1500 /dev/zero | tr '\0' x; echo; } > "$SUMLOG"      # one 1.5 KB line: over the 1024-byte cap
  chmod 555 "$CITY/.gc/runtime"      # the directory cannot be written (so no rename), the existing FILE still can
  run_reaper GC_REAPER_SUMMARY_LOG_MAX_BYTES=1024
  chmod 755 "$CITY/.gc/runtime"
  SL="$(wc -l < "$SUMLOG" | tr -d ' ')"
  { [ "$RC" -eq 0 ] && [ "$(fld summary_log)" = "UNCAPPED" ] && [ "$SL" = "2" ] && [ ! -e "$SUMLOG.1" ]; } \
    && ok "C9b the cap could not be enforced: the line was still written (2 lines, no .1) and stdout says summary_log:UNCAPPED" \
    || nok "C9b an unrotatable log is silent, or lost the line" "rc=$RC lines=$SL rotated=$([ -e "$SUMLOG.1" ] && echo yes || echo no) $OUT"
fi

# ── C10: the switch ───────────────────────────────────────────────────────────
echo "C10: GC_REAPER_ORPHAN_COUNT=0 switches the count off; a malformed value is an anomaly"
new_db; seed_orphans; fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT=0
{ [ "$(fld orphan_count)" = "off" ] && [ "$(sqlcount 'orphan_count_probe')" = "0" ] && [ "$(fld anomalies)" = "0" ]; } && ok "C10 count off: orphan_count:off, no probe issued, no anomaly" || nok "C10 switch" "$OUT | probes=$(sqlcount 'orphan_count_probe')"
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK GC_REAPER_ORPHAN_COUNT=maybe
{ [ "$(fld orphan_count)" = "9" ] && grep -q "GC_REAPER_ORPHAN_COUNT='maybe'" "$CALLS"; } && ok "C10 a malformed switch falls back to ON and is an anomaly (not a silent skip)" || nok "C10 malformed switch" "$OUT | $(cat "$CALLS")"

# ── C11: a bead store the reaper SKIPS for its schema is still counted; nothing measurable is unknown ─────────
echo "C11: a schema-skipped bead store is still COUNTED (not left out of an exact-looking number); no bead store -> unknown"
# (a) hq is clean; zz has orphans AND an unrecognised wisp_dependencies (dropped), so the reaper skips it for its
#     schema (schema_skipped_dbs:1: no purge, no sweep). The count never reads wisp_dependencies, so it must still
#     see zz's orphans. The old placement (COUNT_DBS filled after the schema gate) printed orphan_count:0 here.
new_db
sql "INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('live-open','open','task',$(H 1),$(H 1),NULL);
     CALL DOLT_COMMIT('-Am','hq clean','--author','t <t@t.local>');" >/dev/null
new_db zz
( cd "$DOLT_ROOT" && dolt sql -q "USE zz;
    INSERT INTO wisps (id,status,issue_type,created_at,updated_at,closed_at) VALUES ('z-live','open','task',$(H 1),$(H 1),NULL);
    INSERT INTO wisp_events (issue_id,event_type) VALUES ('z-live','c'),('gone','c'),('gone','u'),('gone','x');
    INSERT INTO wisp_labels VALUES ('gone','l');
    DROP TABLE wisp_dependencies;
    CALL DOLT_COMMIT('-Am','zz: orphans, schema-skipped','--author','t <t@t.local>');" >/dev/null 2>&1 )
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK
{ [ "$(fld schema_skipped_dbs)" = "1" ] && [ "$(fld orphan_count)" = "4" ] && [ "$(fld orphan_count_unknown)" = "0" ]; } \
  && ok "C11 zz is skipped by the reaper for its schema yet its 4 orphans are COUNTED (orphan_count:4, not 0 over a clean hq)" \
  || nok "C11 a schema-skipped database's orphans are INVISIBLE (orphan_count is not 4)" "$OUT"
ZO="$(cd "$DOLT_ROOT" && dolt sql -r csv -q "USE zz; SELECT (SELECT COUNT(*) FROM wisp_events x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL) + (SELECT COUNT(*) FROM wisp_labels x LEFT JOIN wisps w ON w.id=x.issue_id WHERE w.id IS NULL)" 2>/dev/null | tail -1 | tr -d '\r')"
{ [ "$ZO" = "4" ] && [ "$(sqlcount 'DELETE FROM')" = "0" ]; } && ok "C11 the skipped database is left exactly as it was (the count is read-only)" || nok "C11 the skipped database was changed" "orphans=$ZO deletes=$(sqlcount 'DELETE FROM')"
rm -rf "$DOLT_ROOT/zz"      # later scenarios expect the single hq database
# (b) No bead store at all (the only database has no `wisps` table): nothing was measured, so it is `unknown`,
#     never a `0` that reads as "no orphans".
#     wisp_dependencies has a FOREIGN KEY onto wisps, so it goes first (dropping the parent first fails, and that
#     failure must not be swallowed: the fixture is asserted below, not assumed).
new_db; sql "DROP TABLE wisp_dependencies; DROP TABLE wisps; CALL DOLT_COMMIT('-Am','not a bead store','--author','t <t@t.local>');" >/dev/null
[ "$(scalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='hq' AND table_name='wisps'")" = "0" ] || nok "C11 fixture is not what the test assumes: hq still has a wisps table"
fresh
run_reaper FAKE_DF_AVAIL_KB=$LOW_DISK
{ [ "$RC" -eq 0 ] && [ "$(fld orphan_count)" = "unknown" ] && [ "$(fld orphan_count_unknown)" = "0" ]; } && ok "C11 no bead store to measure -> orphan_count:unknown (not 0), nothing failed" || nok "C11 nothing-measured reads as a number" "rc=$RC $OUT"

# ── C12: the order's timeout covers every budget ──────────────────────────────
echo "C12: mol-dog-reaper.toml's timeout covers purge + orphan + COUNT budgets + fixed work"
ORDER_TOML="$HERE/../orders/mol-dog-reaper.toml"
if [ ! -f "$ORDER_TOML" ]; then
  nok "C12 order file not found" "$ORDER_TOML"
else
  TO="$(sed -n 's/^timeout[[:space:]]*=[[:space:]]*"\([0-9][0-9]*\)s".*/\1/p' "$ORDER_TOML" | head -1)"
  PB="$(grep -o 'GC_REAPER_PURGE_BUDGET_S:-[0-9]*' "$REAPER_SH" | head -1 | cut -d- -f2)"
  OB="$(grep -o 'GC_REAPER_ORPHAN_BUDGET_S:-[0-9]*' "$REAPER_SH" | head -1 | cut -d- -f2)"
  CB="$(grep -o 'GC_REAPER_ORPHAN_COUNT_BUDGET_S:-[0-9]*' "$REAPER_SH" | head -1 | cut -d- -f2)"
  if [ -z "$TO" ] || [ -z "$PB" ] || [ -z "$OB" ] || [ -z "$CB" ]; then
    nok "C12 could not read the timeout or a budget default" "TO=$TO PB=$PB OB=$OB CB=$CB"
  elif [ "$TO" -ge $((PB + OB + CB + 120)) ]; then
    ok "C12 timeout ${TO}s >= purge ${PB}s + orphan ${OB}s + count ${CB}s + 120s of fixed work"
  else
    nok "C12 timeout ${TO}s does not cover purge ${PB}s + orphan ${OB}s + count ${CB}s + 120s" "raise timeout in orders/mol-dog-reaper.toml"
  fi
fi

# ── C13: the schema probe finds a column that IS listed, however the pipe timing falls ───────────────────────
echo "C13: probe_dependency_table never false-negatives (no 'printf | grep -q' under pipefail)"
# Found because this very suite flaked: under `set -o pipefail`, `printf "$fields" | grep -qx issue_id` can report
# FAILURE although the column is there (grep -q exits on the first match and its writer catches SIGPIPE). The probe
# then answered "unrecognised schema" and the reaper skipped a HEALTHY database for the whole run (measured at load
# ~45: 8 of 300 probes on the real column list; 3 of 3 on a 140 KB one, where the writer is guaranteed to still be
# writing when grep exits). The probe is extracted from the script under test and run against a stub column list.
PROBE_SRC="$T/probe-fn.sh"
awk '/^field_listed\(\) \{/,/^\}/ {print} /^probe_dependency_table\(\) \{/,/^\}/ {print}' "$SD/reaper.sh" > "$PROBE_SRC"
probe_run() {  # probe_run <filler columns> <iterations>  ->  "<failures>/<iterations>"
  ( set -o pipefail
    DEP_FLAVOR=""; DEP_WISP_TARGET_COL=""; DEP_ISSUE_TARGET_COL=""
    FILLER="$1"; N="$2"
    dolt_sql() {   # the shape of `SHOW COLUMNS FROM wisp_dependencies` in csv, optionally with many filler columns
      printf '%s\n' 'Field,Type,Null,Key,Default,Extra' 'id,char(36),NO,PRI,(uuid()),DEFAULT_GENERATED' \
        'issue_id,varchar(255),NO,"",,""' 'depends_on_issue_id,varchar(255),YES,"",,""' \
        'depends_on_wisp_id,varchar(255),YES,MUL,,""' 'depends_on_external,varchar(255),YES,"",,""'
      [ "$FILLER" -gt 0 ] && seq 1 "$FILLER" | sed 's/.*/filler_&,varchar(255),YES,"",,""/'
      printf '%s\n' 'type,varchar(32),NO,"","blocks",""'
    }
    . "$PROBE_SRC" || exit 99
    bad=0; i=0
    while [ "$i" -lt "$N" ]; do
      i=$((i+1))
      if probe_dependency_table hq wisp_dependencies && [ "$DEP_FLAVOR" = "split" ] \
         && [ "$DEP_WISP_TARGET_COL" = "depends_on_wisp_id" ] && [ "$DEP_ISSUE_TARGET_COL" = "depends_on_issue_id" ]; then :; else bad=$((bad+1)); fi
    done
    echo "$bad/$N" )
}
R_BIG="$(probe_run 12000 3)"
[ "$R_BIG" = "0/3" ] && ok "C13 the columns are found in a 140 KB column list (a SIGPIPE'd writer is not read as 'not listed')" || nok "C13 the probe false-negatives on a large column list" "failures/probes=$R_BIG"
R_REAL="$(probe_run 0 300)"
[ "$R_REAL" = "0/300" ] && ok "C13 300 probes of the real column list: 0 false negatives" || nok "C13 the probe false-negatives on the real column list" "failures/probes=$R_REAL"
# The membership test itself: a WHOLE line, like `grep -x`; a glob character is literal.
SEM="$( . "$PROBE_SRC" 2>/dev/null
  t() { field_listed "$@" 2>/dev/null; printf '%s ' "$?"; }
  t $'id\nissue_id\ntype' issue_id; t $'id\nissue_id_x\ntype' issue_id; t $'id\nxissue_id\ntype' issue_id; t '' issue_id
  t $'issue_id\ntype' issue_id; t $'type\nissue_id' issue_id; t $'a*b\nc' 'a*b'; t $'axb\nc' 'a*b' )"
[ "$SEM" = "0 1 1 1 0 0 0 1 " ] && ok "C13 field_listed is a whole-line match (listed, superstring, prefix, empty, first, last, literal glob)" || nok "C13 field_listed semantics" "got '$SEM', want '0 1 1 1 0 0 0 1 '"

echo ""
echo "reaper-orphan-count selftest (ga-hpdpij): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
