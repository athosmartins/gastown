#!/bin/bash
# jsonl-export-budget.selftest.sh — ga-fegzc8h: the exporter fits ITS WORK in a time budget and commits what is complete, instead of dying at the order's timeout with nothing committed.
#
# Contents
#   Harness · A rotation over four runs · B the first database always starts · C a killed database goes to the back · D the table cutoff · E a state this scheme did not write ·
#   F "no changes" still names the deferred · G the budget fits under the order's timeout · H validate_and_count_issues
#
# THE FAILURE (28/10, load 70-120 on 10 cores): the exporter commits ONCE, after the last database. A whole pass is ~960 s (hq alone 530 s); the order's timeout is 840 s and has to stay under the 15 m
# interval (there is no single-flight lock). Three runs in a row wrote every file and committed none: the archive's HEAD stood still for 8 h and the offsite stopped. On the base commit this file
# fails: that exporter has no budget, so a run that cannot fit does not defer anything.
#
# Hermetic: the whole exporter runs against a stub dolt-target.sh (several databases, zero-row supplemental tables) and a stub `gc`, on the PATH of selftest-sandbox-path.lib.sh (no real gc/bd). TIME is
# the seam JEX_CLOCK_FILE: a file holding the elapsed seconds, which the stub Dolt advances by STUB_COST_<db> per issues export and STUB_TABLE_COST_<db> per supplemental table. Nothing sleeps and the
# load of the host does not matter.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/jsonl-export.sh"
ORDER_TOML="$HERE/../../orders/jsonl-export.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

. "$HERE/../selftest-fail-closed.lib.sh" || { echo "FATAL: cannot source $HERE/../selftest-fail-closed.lib.sh" >&2; exit 2; }
. "$HERE/../selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $HERE/../selftest-sandbox-path.lib.sh" >&2; exit 2; }
[ -r "$SCRIPT" ] || { echo "FATAL: $SCRIPT not readable" >&2; exit 2; }

echo "=== jsonl-export-budget.selftest.sh ==="

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
selftest_fail_closed_arm cleanup

E2E="$WORK/e2e"
mkdir -p "$E2E/scripts" "$E2E/bin" "$E2E/city" "$E2E/state"
cp "$SCRIPT" "$E2E/scripts/jsonl-export.sh"
cp "$HERE/jsonl-archive-repack-window-lib.sh" "$E2E/scripts/jsonl-archive-repack-window-lib.sh"
cp "$HERE/disk-headroom-lib.sh" "$E2E/scripts/disk-headroom-lib.sh"
cat > "$E2E/scripts/dolt-target.sh" <<'STUB'
# Several databases, each with STUB_ROWS issues (the title carries STUB_TAG, so two runs with different tags write different files) and five zero-row supplemental tables with no primary key.
#   STUB_DBS                 the databases, space-separated, in Dolt's order
#   STUB_COST_<db>           what the whole database costs on the fake clock (default 10): 10 s on its issues export and the rest on its LAST table (metadata), so the issues export is
#                            over early and the tables are read before the cutoff, as in a real run where hq's 21 s export is followed by 500 s of tables and scrub
#   STUB_TABLE_COST_<db>     seconds it moves on EACH supplemental table read of that database, on top of that (default 0)
#   STUB_KILL_DB             that database's issues export is the engine's SIGKILL: the exporter dies, no trap runs
stub_var() { local v="$1"; printf '%s' "${!v:-${2:-}}"; }
stub_db() {  # the database a query names: `db`.xxx
  if [[ "$1" =~ \`([A-Za-z0-9_-]+)\`\. ]]; then printf '%s' "${BASH_REMATCH[1]}"; fi
  return 0
}
stub_tick() {  # stub_tick <seconds> — the fake clock moves
  local now
  now=$(cat "$E2E_CLOCK" 2>/dev/null || echo 0)
  printf '%s' "$((now + $1))" > "$E2E_CLOCK"
}
dolt_sql() {
  local q="" db cost extra
  while [ $# -gt 0 ]; do
    case "$1" in -q) q="$2"; shift ;; esac
    shift
  done
  case "$q" in
    "SHOW DATABASES") printf 'Database\n'; for db in $STUB_DBS; do printf '%s\n' "$db"; done; return 0 ;;
    *KEY_COLUMN_USAGE*) printf 'COLUMN_NAME\n'; return 0 ;;
  esac
  db=$(stub_db "$q")
  case "$q" in
    "SELECT COUNT(*) AS row_count FROM \`$db\`.issues"*) printf 'row_count\n%s\n' "$STUB_ROWS"; return 0 ;;
    "SELECT COUNT(*)"*) printf 'row_count\n0\n'; return 0 ;;
    "SELECT * FROM \`$db\`.issues"*)
      if [ "${STUB_KILL_DB:-}" = "$db" ]; then kill -9 $$; fi
      cost=$(stub_var "STUB_COST_$db" 10)
      stub_tick "$((cost < 10 ? cost : 10))"
      jq -n -c --arg db "$db" --arg tag "${STUB_TAG:-0}" --argjson n "$STUB_ROWS" '{rows: [range($n) | {id: "\($db)-\(.)", title: "issue \(.) run \($tag)", issue_type: "task"}]}'
      return 0 ;;
    "SELECT * FROM"*)
      extra=0
      case "$q" in *'`.`metadata`'*) cost=$(stub_var "STUB_COST_$db" 10); extra=$((cost > 10 ? cost - 10 : 0)) ;; esac
      stub_tick "$(($(stub_var "STUB_TABLE_COST_$db" 0) + extra))"
      printf '{"rows":[]}\n'; return 0 ;;
  esac
  return 1
}
has_wisps_table() { return 0; }
STUB
cat > "$E2E/bin/gc" <<'STUB'
#!/bin/sh
echo "gc $*" >> "$E2E_GC_LOG"
exit 0
STUB
chmod +x "$E2E/bin/gc"
sandbox_path_init "$E2E" git jq || { echo "FATAL: cannot build the sandbox PATH" >&2; exit 2; }
export DISK_FREE_OVERRIDE_MB=102400   # the disk cadence (ga-j2f5v5) must never skip a case on a host with a low disk

export STUB_ROWS=50
unset STUB_KILL_DB STUB_DBS 2>/dev/null || true
ARCH=""; E2E_STATE=""; SCEN=""; RUN_N=0; TAG_FIXED=""
OUT=""; RC=0

fresh() {  # fresh <name> — a new archive, a new state, a new log, the run counter back to 0
  SCEN="$1"; ARCH="$E2E/archive-$1"; E2E_STATE="$E2E/state-$1"; RUN_N=0; TAG_FIXED=""
  mkdir -p "$E2E_STATE"
  unset STUB_KILL_DB GC_JSONL_BUDGET_SECONDS GC_JSONL_UNKNOWN_COST_SECONDS GC_JSONL_POST_RESERVE_SECONDS
  for v in aa bb cc dd; do unset "STUB_COST_$v" "STUB_TABLE_COST_$v"; done
  export STUB_DBS="aa bb cc dd"
}
run_export() {  # run_export — one run of the whole exporter in the current scenario; sets OUT and RC
  RUN_N=$((RUN_N + 1))
  printf '0' > "$E2E/clock"
  : > "$E2E/gc.log"
  OUT=$(
    E2E_GC_LOG="$E2E/gc.log" E2E_CLOCK="$E2E/clock" JEX_CLOCK_FILE="$E2E/clock" STUB_TAG="${TAG_FIXED:-$RUN_N}" JEX_LOG="$E2E/log-$SCEN" \
    PATH="$SANDBOX_PATH" GC_CITY="$E2E/city" GC_PACK_STATE_DIR="$E2E_STATE" GC_JSONL_ARCHIVE_REPO="$ARCH" \
    bash "$E2E/scripts/jsonl-export.sh" 2>&1
  )
  RC=$?
}
subject() { git -C "$ARCH" log -1 --format=%s 2>/dev/null || echo "?"; }
commits() { git -C "$ARCH" rev-list --count HEAD 2>/dev/null || echo 0; }
in_head() { git -C "$ARCH" cat-file -e "HEAD:$1" 2>/dev/null; }
sum_of() { cksum < "$ARCH/$1/issues.jsonl" 2>/dev/null || echo "none"; }
log_has() { grep -q -- "$1" "$E2E/log-$SCEN" 2>/dev/null; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # has <text> <needle>

# ── A: four runs of four databases (aa, bb 300 s each; cc, dd 100 s) under a 690 s budget ──────────────────────────────────────────────────
# Run 1 has no cost on record: the first database starts whatever it costs, the next one is judged at the 240 s a database nobody has timed is assumed to cost (x 125 % = 300 s) and fits, the
# third does not. The two it left are the FIRST two of run 2, so every database is exported within a run or two of its turn, and the run COMMITS every time.
echo "--- A: rotation: a run commits what fits, what it left goes first next run ---"
fresh rotation
export STUB_COST_aa=300 STUB_COST_bb=300 STUB_COST_cc=100 STUB_COST_dd=100

run_export
[ "$RC" = "0" ] && ok "run 1: exits 0" || bad "run 1: rc=$RC: $OUT"
[ "$(commits)" = "1" ] && ok "run 1: a commit exists in the archive although two databases did not fit" || bad "run 1: commits=$(commits), want 1: $OUT"
has "$(subject)" "exported=2/4" && has "$(subject)" "deferred=cc,dd" \
  && ok "run 1: the commit subject says exported=2/4 and deferred=cc,dd" || bad "run 1: subject '$(subject)', want exported=2/4 ... deferred=cc,dd"
has "$(subject)" "partial=" && bad "run 1: a deferral must not read as partial= (jsonl_hourly.py alerts on partial=): '$(subject)'" || ok "run 1: the subject has no partial= (a deferral is not a stale table)"
in_head aa/issues.jsonl && in_head bb/issues.jsonl && ok "run 1: aa and bb are in HEAD" || bad "run 1: aa/bb missing from HEAD"
in_head cc/issues.jsonl && bad "run 1: cc was deferred but is in HEAD" || ok "run 1: cc and dd, deferred, were not exported"
has "$OUT" "deferred: cc dd" && ok "run 1: the run's summary names 'deferred: cc dd'" || bad "run 1: summary lacks 'deferred: cc dd': $OUT"
has "$OUT" "failed:" && bad "run 1: a deferral was reported as failed: $OUT" || ok "run 1: a deferral is not a failure"
grep -q 'DOG_DONE:.*deferred: cc dd' "$E2E/gc.log" && ok "run 1: the DOG_DONE nudge names the deferred databases" || bad "run 1: DOG_DONE lacks 'deferred: cc dd': $(cat "$E2E/gc.log")"
log_has 'DEFER cc — needs ~300s (last cost 240s, never observed, assumed)' && ok "run 1: the log says why cc waited (a database never timed counts 240 s x 125 %)" || bad "run 1: no DEFER line for cc: $(cat "$E2E/log-rotation" 2>/dev/null | tail -5)"
log_has 'budget: .*2 of 4 database(s) deferred' && ok "run 1: the log has the budget line" || bad "run 1: no 'budget: ... 2 of 4 database(s) deferred' line in the log"
[ -z "$(git -C "$ARCH" status --porcelain)" ] && ok "run 1: the archive's working tree is clean (a deferred database leaves no dirty file behind)" || bad "run 1: dirty tree: $(git -C "$ARCH" status --porcelain | tr '\n' ' ')"

run_export
[ "$RC" = "0" ] && [ "$(commits)" = "2" ] && ok "run 2: exits 0 and commits" || bad "run 2: rc=$RC commits=$(commits): $OUT"
has "$(subject)" "exported=3/4" && has "$(subject)" "deferred=bb" && ! has "$(subject)" "deferred=cc" \
  && ok "run 2: cc and dd went first and were exported; bb (started longest ago of those that were) is the one left" || bad "run 2: subject '$(subject)', want exported=3/4 ... deferred=bb"
log_has 'DEFER bb — needs ~375s (last cost 300s, observed), 190s left of the 690s budget' && ok "run 2: bb waited because its OBSERVED cost (300 s x 125 %) did not fit in the 190 s left" || bad "run 2: no DEFER line for bb with the observed cost"
in_head cc/issues.jsonl && in_head dd/issues.jsonl && ok "run 2: cc and dd are in HEAD now" || bad "run 2: cc/dd missing from HEAD"

run_export
[ "$RC" = "0" ] && [ "$(commits)" = "3" ] && ok "run 3: exits 0 and commits (three runs in a row, three commits)" || bad "run 3: rc=$RC commits=$(commits): $OUT"
has "$(subject)" "deferred=aa" && ok "run 3: bb went first, aa is the one left" || bad "run 3: subject '$(subject)', want deferred=aa"
ALL4=1; for d in aa bb cc dd; do in_head "$d/issues.jsonl" || ALL4=0; done
[ "$ALL4" = "1" ] && ok "after 3 runs every database has a snapshot in HEAD" || bad "after 3 runs a database is still missing from HEAD"

# run 4: aa first. The two it leaves keep EXACTLY the files they had (the stub writes a different title every run, so a touched file would differ).
SUM_CC=$(sum_of cc); SUM_DD=$(sum_of dd); SUM_AA=$(sum_of aa)
run_export
[ "$RC" = "0" ] && [ "$(commits)" = "4" ] && ok "run 4: exits 0 and commits" || bad "run 4: rc=$RC commits=$(commits): $OUT"
has "$(subject)" "deferred=cc,dd" && ok "run 4: aa and bb went first, cc and dd are left" || bad "run 4: subject '$(subject)', want deferred=cc,dd"
[ "$(sum_of cc)" = "$SUM_CC" ] && [ "$(sum_of dd)" = "$SUM_DD" ] && ok "run 4: the deferred databases' files are byte for byte what the last run left" || bad "run 4: a deferred database's file changed"
[ "$(sum_of aa)" != "$SUM_AA" ] && ok "run 4: a database that ran has a new file (the stub's check that 'unchanged' means 'not touched')" || bad "run 4: aa's file did not change, the check above proves nothing"
[ -z "$(git -C "$ARCH" status --porcelain)" ] && ok "run 4: the working tree is clean after the commit" || bad "run 4: dirty tree: $(git -C "$ARCH" status --porcelain | tr '\n' ' ')"

# ── B: the first database of a run always starts ───────────────────────────────────────────────────────────────────────────────────────
echo "--- B: a budget smaller than the first database still exports the first database ---"
fresh first
export STUB_COST_aa=300 GC_JSONL_BUDGET_SECONDS=100 GC_JSONL_POST_RESERVE_SECONDS=0   # the 200 s default reserve is longer than this budget
run_export
[ "$RC" = "0" ] && [ "$(commits)" = "1" ] && in_head aa/issues.jsonl && ok "a 100 s budget and a 300 s first database: aa is exported and committed (a run that starts nothing makes no progress)" || bad "first-database run: rc=$RC commits=$(commits) aa-in-head=$(in_head aa/issues.jsonl && echo y || echo n): $OUT"
has "$(subject)" "exported=1/4" && has "$(subject)" "deferred=bb,cc,dd" && ok "the other three are deferred" || bad "subject '$(subject)', want exported=1/4 ... deferred=bb,cc,dd"

# ── C: a database that was started and killed goes to the BACK of the next order ───────────────────────────────────────────────────────────
echo "--- C: a killed database does not hold the front of the line ---"
fresh killed
export STUB_COST_aa=300 STUB_COST_bb=300 STUB_COST_cc=100 STUB_COST_dd=100 STUB_KILL_DB=aa
run_export
[ "$RC" != "0" ] && [ "$(commits)" = "0" ] && ok "run 1: aa is killed mid-export (rc=$RC), nothing is committed" || bad "run 1: rc=$RC commits=$(commits), want a kill and no commit"
unset STUB_KILL_DB
run_export
[ "$RC" = "0" ] && [ "$(commits)" = "1" ] && ok "run 2: exits 0 and commits" || bad "run 2: rc=$RC commits=$(commits): $OUT"
has "$(subject)" "deferred=dd,aa" && ok "run 2: bb and cc went first; aa (the one that was killed) is at the back, behind dd" || bad "run 2: subject '$(subject)', want deferred=dd,aa"
in_head bb/issues.jsonl && in_head cc/issues.jsonl && ok "run 2: bb and cc are in HEAD" || bad "run 2: bb/cc missing from HEAD"

# ── D: past the table cutoff no further supplemental table is read ─────────────────────────────────────────────────────────────────────
echo "--- D: the table cutoff keeps the previous version of a table the budget has no time for ---"
fresh cutoff
export STUB_DBS="aa" STUB_COST_aa=10 STUB_TABLE_COST_aa=0
run_export
[ "$RC" = "0" ] && in_head aa/metadata.jsonl && ok "run 1 (fast tables): aa/metadata.jsonl is in HEAD" || bad "run 1: rc=$RC metadata-in-head=$(in_head aa/metadata.jsonl && echo y || echo n): $OUT"
has "$(subject)" "partial=" && bad "run 1: no table was skipped but the subject says partial=: '$(subject)'" || ok "run 1: every table read, no partial="
MD_BEFORE=$(git -C "$ARCH" rev-parse HEAD:aa/metadata.jsonl 2>/dev/null || echo none)
# 150 s a table: issues 10, comments -> 160, config -> 310, dependencies -> 460, labels starts at 460 (< 490 = 690 - 200) -> 610, metadata is past the cutoff
export STUB_TABLE_COST_aa=150
run_export
[ "$RC" = "0" ] && [ "$(commits)" -ge 1 ] && ok "run 2 (slow tables): exits 0" || bad "run 2: rc=$RC: $OUT"
has "$(subject)" "partial=aa(metadata)" && ok "run 2: the subject names the table the cutoff kept: partial=aa(metadata)" || bad "run 2: subject '$(subject)', want partial=aa(metadata)"
has "$OUT" "aa.metadata not read: 610s into the 690s budget" && ok "run 2: the run says which table it did not read and when" || bad "run 2: no 'aa.metadata not read: 610s into the 690s budget' in: $OUT"
[ "$(git -C "$ARCH" rev-parse HEAD:aa/metadata.jsonl 2>/dev/null || echo none)" = "$MD_BEFORE" ] && ok "run 2: aa/metadata.jsonl in HEAD is the previous version" || bad "run 2: aa/metadata.jsonl changed"
in_head aa/labels.jsonl && ok "run 2: the table read before the cutoff (labels) is committed" || bad "run 2: aa/labels.jsonl missing"
log_has 'budget: .*1 table(s) kept at their previous version' && ok "run 2: the log has the budget line with the table the cutoff kept" || bad "run 2: no 'budget: ... 1 table(s) kept at their previous version' line in the log"

# ── E: a state this scheme did not write ───────────────────────────────────────────────────────────────────────────────────────────────
echo "--- E: a state edited by hand or reset does not stop the run ---"
fresh oddstate
export STUB_DBS="aa bb" STUB_COST_aa=10 STUB_COST_bb=10
printf '%s\n' '{"jex_seq":"abc","db_runs":"nope"}' > "$E2E_STATE/jsonl-export-state.json"
run_export
[ "$RC" = "0" ] && [ "$(commits)" = "1" ] && has "$(subject)" "exported=2/2" && ok "garbage jex_seq and db_runs: the run exports both databases and commits" || bad "odd state: rc=$RC commits=$(commits) subject='$(subject)': $OUT"
log_has 'budget:' && bad "a run the budget did not touch wrote a budget line to the log (the log is the record of what the budget changed)" || ok "a run the budget did not touch writes no budget line to the log"
STATE_NOW=$(cat "$E2E_STATE/jsonl-export-state.json" 2>/dev/null || echo '{}')
[ "$(printf '%s' "$STATE_NOW" | jq -r '[(.jex_seq | type), (.db_runs | type), (.db_runs.aa.cost_s | type)] | join(",")' 2>/dev/null)" = "number,object,number" ] \
  && ok "the state is rewritten in the shape the scheme reads (jex_seq number, db_runs object, a cost per exported database)" || bad "state after the odd one: $STATE_NOW"

# ── F: a run with nothing new still says what it deferred ──────────────────────────────────────────────────────────────────────────────
echo "--- F: 'no changes' does not hide a deferral ---"
fresh nochange
export STUB_DBS="aa bb cc dd" STUB_COST_aa=10 STUB_COST_bb=10 STUB_COST_cc=10 STUB_COST_dd=10 GC_JSONL_BUDGET_SECONDS=40 GC_JSONL_UNKNOWN_COST_SECONDS=20 GC_JSONL_POST_RESERVE_SECONDS=0
TAG_FIXED=1   # every run writes the same rows: what a database exports a second time is what HEAD already has
run_export; run_export
BASE_N=$(commits)
run_export
[ "$RC" = "0" ] && [ "$(commits)" = "$BASE_N" ] && ok "run 3: nothing changed, no new commit, exit 0" || bad "run 3: rc=$RC commits $BASE_N -> $(commits): $OUT"
has "$OUT" "no changes" && has "$OUT" "deferred: aa" && ok "run 3: the summary says 'no changes' AND 'deferred: aa'" || bad "run 3: summary lacks 'no changes' / 'deferred: aa': $OUT"
grep -q 'DOG_DONE:.*no changes.*deferred: aa' "$E2E/gc.log" && ok "run 3: the DOG_DONE nudge says it too" || bad "run 3: DOG_DONE lacks 'deferred: aa': $(cat "$E2E/gc.log")"

# ── G: the budget leaves the commit room under the order's timeout ─────────────────────────────────────────────────────────────────────
echo "--- G: BUDGET + 120 s <= the order's timeout, and the timeout stays under the interval ---"
dur_s() {  # dur_s <Ns|Nm|Nh> — seconds, or return 1 for anything that is not one plain duration
  case "$1" in ''|*[!0-9smh]*) return 1 ;; esac
  local n="${1%[smh]}" u="${1: -1}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$u" in s) echo $((10#$n)) ;; m) echo $((10#$n * 60)) ;; h) echo $((10#$n * 3600)) ;; *) return 1 ;; esac
}
order_field() {  # order_field <file> <key> — the value of `key = "..."` on a non-comment line
  grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([0-9a-z]*)"?.*$/\1/'
}
budget_fit_verdict() {  # budget_fit_verdict <budget s> <post-reserve s> <timeout> <interval> — "ok", or the reason it is not. Every doubt is a reason.
  local b="$1" r="$2" t i
  t="$(dur_s "$3")" || { echo "timeout '$3' is not one plain duration"; return 0; }
  i="$(dur_s "$4")" || { echo "interval '$4' is not one plain duration"; return 0; }
  case "$b$r" in ''|*[!0-9]*) echo "budget '$b' / reserve '$r' is not a whole number"; return 0 ;; esac
  [ $((b + 120)) -le "$t" ] || { echo "budget ${b}s + 120 s is over the ${t}s timeout: the commit would be killed with the rest"; return 0; }
  [ "$t" -lt "$i" ] || { echo "timeout ${t}s is not under the ${i}s interval and the script has no lock"; return 0; }
  [ "$r" -lt "$b" ] || { echo "the table reserve ${r}s is not under the budget ${b}s: no table would ever be read"; return 0; }
  echo ok
}
BUDGET_DEFAULT=$(sed -n 's/^JEX_BUDGET_SECONDS=.*GC_JSONL_BUDGET_SECONDS:-\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)
RESERVE_DEFAULT=$(sed -n 's/^JEX_POST_RESERVE_SECONDS=.*GC_JSONL_POST_RESERVE_SECONDS:-\([0-9]*\)}.*/\1/p' "$SCRIPT" | head -1)
[ -n "$BUDGET_DEFAULT" ] && [ -n "$RESERVE_DEFAULT" ] && ok "the exporter declares a default budget (${BUDGET_DEFAULT:-?} s) and a table reserve (${RESERVE_DEFAULT:-?} s)" || bad "no default budget / reserve found in jsonl-export.sh"
[ -r "$ORDER_TOML" ] && ok "the order file is readable" || bad "cannot read $ORDER_TOML"
V=$(budget_fit_verdict "${BUDGET_DEFAULT:-x}" "${RESERVE_DEFAULT:-x}" "$(order_field "$ORDER_TOML" timeout)" "$(order_field "$ORDER_TOML" interval)")
[ "$V" = "ok" ] && ok "default budget + 120 s <= the order's timeout, the timeout is under the interval, the reserve is under the budget" || bad "budget vs order: $V"
[ "$(budget_fit_verdict 690 200 840s 15m)" = "ok" ] && ok "fixture: 690 / 200 / 840s / 15m is ok" || bad "fixture 690/200/840s/15m was refused"
case "$(budget_fit_verdict 760 200 840s 15m)" in *"over the 840s timeout"*) ok "fixture: a 760 s budget under an 840 s timeout is refused" ;; *) bad "fixture: 760 s budget accepted" ;; esac
case "$(budget_fit_verdict 690 200 15m 15m)" in *"not under the 900s interval"*) ok "fixture: a timeout equal to the interval is refused" ;; *) bad "fixture: timeout == interval accepted" ;; esac
case "$(budget_fit_verdict 690 700 840s 15m)" in *"reserve"*) ok "fixture: a table reserve over the budget is refused" ;; *) bad "fixture: reserve > budget accepted" ;; esac
case "$(budget_fit_verdict 690 200 "" 15m)" in *"not one plain duration"*) ok "fixture: a missing timeout is refused, never defaulted to ok" ;; *) bad "fixture: a missing timeout was accepted" ;; esac

# ── H: validate_and_count_issues: the validation and the row count in ONE pass ─────────────────────────────────────────────────────────
echo "--- H: validate_and_count_issues ---"
# The function sits below the script's lib-mode return, which stops before dolt-target.sh: take its text out of the script and define it here.
VC_SRC=$(awk '/^validate_and_count_issues\(\) \{/ {p=1} p {print} p && /^\}/ {exit}' "$SCRIPT")
[ -n "$VC_SRC" ] && ok "validate_and_count_issues is defined in jsonl-export.sh" || bad "validate_and_count_issues not found in jsonl-export.sh"
vc() {  # vc <stdin text> — prints "<rc>:<stdout>" of validate_and_count_issues
  local out rc
  out=$(printf '%s' "$1" | ( eval "$VC_SRC" && validate_and_count_issues ) 2>/dev/null)
  rc=$?
  printf '%s:%s' "$rc" "$out"
}
[ "$(vc '{"rows":[{"id":1},{"id":2},{"id":3}]}')" = "0:3" ] && ok "three rows: rc 0, prints 3" || bad "three rows: '$(vc '{"rows":[{"id":1},{"id":2},{"id":3}]}')'"
[ "$(vc '{"rows":[]}')" = "0:0" ] && ok "an empty rows array: rc 0, prints 0" || bad "empty rows: '$(vc '{"rows":[]}')'"
[ "$(vc '{}')" = "0:0" ] && ok "Dolt's {} for a table with no rows: rc 0, prints 0" || bad "{}: '$(vc '{}')'"
case "$(vc '')" in 0:*) bad "empty input was accepted: '$(vc '')'" ;; *) ok "empty input: refused (an empty export is never a count of 0)" ;; esac
case "$(vc '[1,2]')" in 0:*) bad "an array was accepted" ;; *) ok "a JSON array: refused" ;; esac
case "$(vc '{"rows":5}')" in 0:*) bad "rows: 5 was accepted" ;; *) ok "rows that is not an array: refused" ;; esac
case "$(vc '{"rows":[1]} {"rows":5}')" in 0:*) bad "a second bad document was accepted" ;; *) ok "a second document that is not valid: refused, as validate_exported_issues refuses it" ;; esac

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
selftest_summary_reached
[ "$FAIL" -eq 0 ]
