#!/usr/bin/env bash
# prod-tests/gascity/story-ga-5c3msy.sh — prod test for ga-5c3msy (E8 of P0 ga-ufskhy): tokens (and US$) per APPROVED
# bead — the meter, its standing harvest, the INERT effort A/B arm, and the study published on 📚 Estudos.
#
# "Merged" is not "live". Each thing the story delivered can be present in git and dead in production, so each gets
# its own check against the DEPLOYED copy in $CITY (never the worktree that built it):
#   1. structure   — the deployed files exist, the meter parses and has its four subcommands, the order's interval is
#                    inside the transcript reaper's window, the report keeps its E2 record;
#   2. A/B inert   — the effort arm decides sessions only when $CITY/.gc/effort-ab.conf exists. Turning it on is the
#                    Mayor's call, so a conf that is present is reported, never failed; the wrapper itself is the
#                    highest-blast-radius file of the delivery (it launches EVERY agent) and its selftest runs in 3.;
#   3. selftests   — the three selftests, run against the deployed code (all use throwaway dirs); a selftest that
#                    reports zero checks is a failure, not a pass;
#   4. live data   — the meter reads the REAL ledger and reports non-empty, priced numbers, and a report never
#                    writes to the ledger (a report that mutates what it measures would corrupt every later A/B); and a
#                    second run WITHOUT --assume-price proves the unpriced path: it finishes, and an unknown never reads
#                    as a number (cohort/system US$-per-approved null, floor in its own field, no CV from < 20 priced beads);
#   5. the order   — `gc order list` resolves it (CLI-side scan: proves the file parses, NOT that the controller loaded
#                    it) and `gc order history` says whether the controller has fired it (the only proof it did);
#                    once it has fired, its own log must show a recent rc=0 run THAT READ TRANSCRIPTS (an rc=0 harvest of
#                    zero transcripts is the silent failure: the root moved, the reaper deletes what was never copied), and the
#                    ledger must keep up with the newest transcript ON DISK (the log can lie by omission; the files cannot);
#   6. the study   — the 📚 Estudos entry exists once, is INTERNAL (a truthy `publico` would serve it on a host with
#                    no login), points at a real file, and the admin daemon serves it.
#
# Three states, never two, wherever a read can fail: ok / not ok / could not find out. "Could not find out" is not a FAIL
# by itself (a fresh deploy legitimately has not reached the order's first tick, and the daemon may be restarting),
# but it is never silent: every such item is counted and listed in the PASS line.
#
# Called by run.sh after deploy (STORY_ID=ga-5c3msy). Exits 0 on pass. Read-only everywhere: nothing here writes to the
# ledger, the index, a marker, a bead or a daemon.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="${ASSETS:-$CITY/packs/town-deltas/assets}"
METER="$ASSETS/bead-token-meter.py"
METER_ST="$ASSETS/bead-token-meter.selftest.py"
AB_ST="$ASSETS/claude-effort-ab.selftest.sh"
HV_ST="$ASSETS/token-ledger-harvest.selftest.sh"
LOWPRIO="$ASSETS/scripts/claude-lowprio.sh"
HARVEST="$ASSETS/scripts/token-ledger-harvest.sh"
ORDER_FILE="${ORDER_FILE:-$CITY/packs/town-deltas/orders/token-ledger-harvest.toml}"
REPORT="${REPORT:-$CITY/docs/reports/token-por-bead-e8.md}"
E2_SCRIPT="${E2_SCRIPT:-$CITY/docs/reports/token-por-bead-e8/e2-readout.py}"
LEDGER="$CITY/.gc/token-ledger/sessions.jsonl"
HLOG="${HLOG:-$CITY/.gc/logs/token-ledger-harvest.log}"
TRANSCRIPTS_ROOT="${TRANSCRIPTS_ROOT:-$HOME/.claude/projects}"
ESTUDOS_DIR="${ESTUDOS_DIR:-/Users/athos/gt/whatsapp_automation/shared/data/estudos}"
SLUG="tokens-por-bead-aprovada-ga-5c3msy"
ESTUDOS_PORT="${ESTUDOS_PORT:-8097}"

log()  { echo "[prod-test:gascity ga-5c3msy] $*"; }
fail() { echo "[prod-test:gascity ga-5c3msy] FAIL: $*" >&2; exit 1; }
# _to <seconds> <cmd...> — bounded when the host has timeout/gtimeout, else unbounded and SAID so. Calling `timeout` directly would make a
# host without it report "failed or timed out" for a command that never ran.
_TO=""; for _t in timeout gtimeout; do command -v "$_t" >/dev/null 2>&1 && { _TO="$_t"; break; }; done
_to() { local t="$1"; shift; if [[ -n "$_TO" ]]; then "$_TO" "$t" "$@"; else "$@"; fi; }
[[ -n "$_TO" ]] || echo "[prod-test:gascity ga-5c3msy] WARN: no timeout/gtimeout on this host — the calls below are NOT time-bounded"

UNPROVEN=""; UNPROVEN_N=0
_unproven() { UNPROVEN_N=$((UNPROVEN_N + 1)); UNPROVEN="${UNPROVEN:+$UNPROVEN; }$1"; }   # one place adds an item, so the count cannot disagree with the list
NOTES=""
_note() { NOTES="${NOTES:+$NOTES; }$1"; }

# _ledger_stamp <file> — "<size> <inode> <sha256>" from ONE python call; rc != 0 and no output when the file cannot be read.
_ledger_stamp() {
  python3 -c 'import hashlib, os, sys
st = os.stat(sys.argv[1])
print(st.st_size, st.st_ino, hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1" 2>/dev/null
}

# check_report_readonly <stamp-before> <stamp-after> <copy-taken-BEFORE-the-run> <the report's own args...> — a `report` must not write to the ledger. The proof is by CONTENT, never
# by mtime: `stat` gives 1 s resolution, so a write inside the same second reads as untouched, and the 30-min harvest order rewrites the ledger on every
# tick (atomically: new inode, new bytes), so a changed mtime is not proof that the REPORT did it either. Sets RO_PROOF for the log line.
#   identical stamp (size, inode, sha256) -> proven read-only.
#   stamp moved -> the report wrote OR a harvest tick landed in the window, and on the live file the two cannot be told apart. So the report is run again on
#                  the private COPY the caller took BEFORE the run, where nothing else writes: unchanged copy = the report is read-only; changed copy = FAIL.
#                  (A copy taken AFTER would already carry an idempotent write, and a second run of the same report would show nothing.)
#   could not stamp / copy / run -> "could not find out": counted in the PASS line (_unproven), neither a silent pass nor a FAIL by itself.
RO_PROOF=""
check_report_readonly() {
  local before="$1" after="$2" copy="$3" c0 c1; shift 3
  if [[ -z "$before" || -z "$after" ]]; then
    RO_PROOF="UNPROVEN"; _unproven "report read-only (could not stamp the live ledger before/after the run)"; return 0
  fi
  if [[ "$before" == "$after" ]]; then RO_PROOF="live ledger byte-identical (size, inode, sha256)"; return 0; fi
  if [[ -z "$copy" ]] || ! c0="$(_ledger_stamp "$copy")"; then
    RO_PROOF="UNPROVEN"; _unproven "report read-only (the live ledger moved during the run and there is no readable pre-run copy to re-run the report on)"; return 0
  fi
  if ! _to 200 python3 "$METER" report --ledger "$copy" "$@" >/dev/null 2>&1; then
    RO_PROOF="UNPROVEN"; _unproven "report read-only (the live ledger moved during the run and the report failed on the private copy)"; return 0
  fi
  if ! c1="$(_ledger_stamp "$copy")"; then
    RO_PROOF="UNPROVEN"; _unproven "report read-only (the private copy could not be read back)"; return 0
  fi
  [[ "$c0" == "$c1" ]] || fail "'report' changed the ledger it reads (private copy: ${c0##* } -> ${c1##* }) — a report must be read-only"
  RO_PROOF="the live ledger moved during the run (a harvest tick) — the report left a private copy byte-identical"
  _note "live ledger moved during the report (harvest tick); read-only proven on a private copy"
}

# Sourced by a selftest (token-ledger-harvest.selftest.sh): only the helpers above are wanted — stop before any live check runs.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/ga-5c3msy-prodtest.XXXXXX")" || fail "cannot create a scratch dir"
cleanup() { [[ -n "$TMPROOT" && -d "$TMPROOT" ]] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

# ── 1. structure ──────────────────────────────────────────────────────────────
for f in "$METER" "$METER_ST" "$AB_ST" "$HV_ST" "$ORDER_FILE" "$REPORT" "$E2_SCRIPT"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f"
done
for f in "$LOWPRIO" "$HARVEST"; do
  [[ -x "$f" ]] || fail "deployed script missing or not executable: $f"
done
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$METER" 2>/dev/null || fail "the deployed meter does not parse as Python: $METER"

help_out="$(_to 30 python3 "$METER" --help 2>&1)" || fail "the deployed meter does not run (--help failed): ${help_out:0:300}"
for sub in harvest report backfill-s3 prices; do
  [[ "$help_out" == *"$sub"* ]] || fail "the deployed meter has no '$sub' subcommand"
done

# /bin/bash is 3.2 on macOS and the wrapper runs under it: "${argv[@]}" on an EMPTY array is fatal there under set -u, which would
# stop every agent from launching. The ${argv[@]+...} form is what makes the final exec safe, so its removal is a failure here.
grep -q -F 'EFFORT A/B' "$LOWPRIO" || fail "the deployed claude-lowprio.sh has no EFFORT A/B block — the delivery is not what is running"
grep -q -F 'exec "$claude_bin" ${argv[@]+"${argv[@]}"}' "$LOWPRIO" || fail "claude-lowprio.sh's final exec is not the bash-3.2-safe form: an empty argv would abort the launch of every agent"

grep -q -E '^exec *= *"\$PACK_DIR/assets/scripts/token-ledger-harvest\.sh"' "$ORDER_FILE" || fail "the order does not exec the deployed harvest wrapper"
iv="$(sed -n 's/^interval *= *"\([0-9]*\)\([mh]\)".*/\1 \2/p' "$ORDER_FILE" | head -n 1)"
read -r iv_n iv_u <<< "$iv"
[[ "${iv_n:-}" =~ ^[0-9]+$ && -n "${iv_u:-}" ]] || fail "cannot read the order's interval (got '${iv:-nothing}')"
iv_min="$iv_n"; [[ "$iv_u" == "h" ]] && iv_min=$((iv_n * 60))
# transcript-reaper deletes a dead session's transcript 24h after its last write; a harvest slower than half of that can lose history
[[ "$iv_min" -ge 1 && "$iv_min" -le 720 ]] || fail "order interval is ${iv_n}${iv_u} — outside 1m..12h; the reaper's 24h window is not safely covered"

grep -q -E '^## 5\. E2' "$REPORT" || fail "the report lost its E2 section (the story requires E2 to be recorded and closed without a conclusion)"
grep -q -F 'encerrado sem conclusão' "$REPORT" || fail "the report's E2 section does not say it closed without a conclusion"
log "meter + selftests + harvest wrapper + order file + report + E2 script deployed; interval ${iv_n}${iv_u}; exec form bash-3.2-safe ✓"

# ── 2. the effort A/B is INERT unless somebody turned it on ───────────────────
if [[ -e "$CITY/.gc/effort-ab.conf" ]]; then
  if [[ -e "$CITY/.gc/no-effort-ab" ]]; then
    log "effort A/B conf present but the kill switch ($CITY/.gc/no-effort-ab) is set — inert"
  else
    log "WARN: $CITY/.gc/effort-ab.conf EXISTS — the effort A/B is ACTIVE for new sessions. The delivery ships it OFF; that is fine only if the Mayor turned it on."
    _note "effort A/B is ACTIVE (conf present)"
  fi
else
  log "effort A/B is OFF (no $CITY/.gc/effort-ab.conf) — launches use their configured effort untouched ✓"
fi

# ── 3. the selftests, against the DEPLOYED code ───────────────────────────────
# Each passes/fails on its exit code AND must print its "<N> ok, 0 falhas|failed" summary with N > 0: a selftest that
# exits 0 after running nothing proves nothing.
run_selftest() {   # <label> <summary-regex> <cmd...>
  local label="$1" rx="$2"; shift 2
  local out="$TMPROOT/$label.out" rc
  _to 280 nice -n 10 "$@" > "$out" 2>&1; rc=$?     # _to wraps nice, not the reverse: nice cannot exec a shell function
  if [[ "$rc" -ne 0 ]]; then
    tail -n 15 "$out" | sed 's/^/    /' >&2
    fail "$label selftest exited $rc"
  fi
  local n
  n="$(sed -n -E "s/^${rx}\$/\1/p" "$out" | tail -n 1)"
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]] || { tail -n 8 "$out" | sed 's/^/    /' >&2; fail "$label selftest exited 0 but printed no '<N> ok, 0 …' summary with N > 0 (parsed '${n:-nothing}')"; }
  log "$label selftest: $n checks, 0 failed ✓"
}
run_selftest "meter"          '([0-9]+) ok, 0 falhas' python3 "$METER_ST"
run_selftest "effort-ab"      '([0-9]+) ok, 0 failed' /bin/bash "$AB_ST"
run_selftest "harvest-order"  '([0-9]+) ok, 0 failed' /bin/bash "$HV_ST"

# ── 4. live data: the deployed meter on the REAL ledger, read-only ────────────
[[ -f "$LEDGER" ]] || fail "the ledger does not exist: $LEDGER — nothing has ever harvested"
rows="$(wc -l < "$LEDGER" | tr -d ' ')"
[[ "$rows" =~ ^[0-9]+$ && "$rows" -ge 500 ]] || fail "the ledger has $rows rows (< 500) — an almost-empty ledger reads as 'cheap', not as 'unmeasured'"
tail -n 1 "$LEDGER" | jq -e '(.sid | type == "string") and (.first_ts | type == "string")' >/dev/null 2>&1 || fail "the last ledger row does not parse as a session record"
pre_copy="$TMPROOT/ledger-pre.jsonl"; cp "$LEDGER" "$pre_copy" 2>/dev/null || pre_copy=""       # the pristine copy the read-only proof falls back on
st_before="$(_ledger_stamp "$LEDGER")" || st_before=""
since="$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(days=2)).strftime("%Y-%m-%d"))')"
rep="$TMPROOT/report.json"
_to 200 python3 "$METER" report --from "$since" --assume-price claude-sonnet-5=claude-sonnet-5-5 --json > "$rep" 2> "$TMPROOT/report.err"; rrc=$?
[[ "$rrc" -eq 0 ]] || { head -c 400 "$TMPROOT/report.err" >&2; fail "meter report --from $since exited $rrc"; }
jq -e '.exit_code == 0 and (.sessions > 0) and (.total_usd_priced > 0) and ((.by_role | length) > 0)' "$rep" >/dev/null 2>&1 \
  || fail "meter report on the live ledger is empty or unpriced (sessions/total_usd_priced/by_role): $(jq -c '{exit_code, sessions, total_usd_priced}' "$rep" 2>/dev/null)"
st_after="$(_ledger_stamp "$LEDGER")" || st_after=""
check_report_readonly "$st_before" "$st_after" "$pre_copy" --from "$since" --assume-price claude-sonnet-5=claude-sonnet-5-5 --json
ro_txt="✓ read-only: $RO_PROOF"; [[ "$RO_PROOF" == "UNPROVEN" ]] && ro_txt="? read-only NOT proven (listed in the PASS line)"
log "live ledger: $rows rows; report since $since: $(jq -r '"\(.sessions) sessions, US$ \(.total_usd_priced | floor) priced"' "$rep") $ro_txt"

# The same report WITHOUT --assume-price. The live ledger holds tokens of models the price table does not cover, so THIS is the run
# that exercises the third state (n/p / floor); the run above prices everything it can and never touches that path. It must finish
# (a report that hit an unpriced model once crashed and threw away every section) and must never show a floor as a measurement:
# no US$-per-approved figure for a cohort that holds an unpriced bead, system usd_per_approved null while unpriced tokens exist
# (the floor lives in its own field), and no cost CV computed from fewer than 20 priced beads. Invariants, not numbers: the live
# figures drift every harvest.
rep2="$TMPROOT/report-noassume.json"
_to 200 python3 "$METER" report --from "$since" --json > "$rep2" 2> "$TMPROOT/report2.err"; rrc2=$?
[[ "$rrc2" -eq 0 ]] || { head -c 400 "$TMPROOT/report2.err" >&2; fail "meter report --from $since WITHOUT --assume-price exited $rrc2 — an unpriced model must read as n/p, not crash the report"; }
jq -e '.exit_code == 0
       and (.system | has("usd_per_approved") and has("usd_per_approved_floor") and has("unpriced_tokens"))
       and (if .unpriced_tokens > 0 then (.system.usd_per_approved == null and (.system.usd_per_approved_floor | type == "number")) else true end)
       and ([.cohorts[] | select(.beads_unpriced > 0 and (.usd_per_approved != null or .usd_per_first_pass != null))] | length == 0)
       and ([.power[]? | select(.beads_priced < 20 and .cv_usd_per_bead != null)] | length == 0)' "$rep2" >/dev/null 2>&1 \
  || fail "report WITHOUT --assume-price shows an unknown as a number (system/cohorts/power): $(jq -c '{exit_code, unpriced_tokens, system, unpriced_cohorts_with_usd: [.cohorts[]? | select(.beads_unpriced > 0 and (.usd_per_approved != null or .usd_per_first_pass != null)) | .cohort]}' "$rep2" 2>/dev/null | head -c 500)"
sys_s="$(jq -r 'if .system.usd_per_approved == null then "n/p, floor US$ \((.system.usd_per_approved_floor // 0) | floor)" else "US$ \(.system.usd_per_approved | floor)" end' "$rep2" 2>/dev/null)"
log "live ledger WITHOUT --assume-price: finished; $(jq -r '(.unpriced_tokens / 1e6) | floor' "$rep2" 2>/dev/null) Mtok unpriced; per approved bead: ${sys_s:-?} ✓ (a floor is never shown as a measurement)"

# ── 5. the order: resolves, has the CONTROLLER fired it, and is its harvest healthy ──
orders="$(_to 60 gc --city "$CITY" order list --json 2>/dev/null)" || fail "gc order list failed (or timed out)"
n="$(printf '%s' "$orders" | jq '[.orders[] | select(.name == "token-ledger-harvest")] | length' 2>/dev/null)"
[[ "$n" =~ ^[0-9]+$ ]] || fail "could not read gc order list (jq: '$n')"
[[ "$n" -ge 1 ]] || fail "order token-ledger-harvest is NOT listed by gc order list — the pack is not deployed or the file does not parse (listed: $n)"
src="$(printf '%s' "$orders" | jq -r '[.orders[] | select(.name == "token-ledger-harvest")][0].source' 2>/dev/null)"
[[ "$src" == *"packs/town-deltas/orders/token-ledger-harvest.toml" ]] || fail "order resolved from an unexpected source: $src"
log "gc order list resolves the order ($n instance) from $src ✓ (CLI-side scan; whether the controller loaded it is next)"

FIRED="unknown"
hist="$(_to 90 gc --city "$CITY" order history token-ledger-harvest --json 2>/dev/null)"; hrc=$?
fired="$(printf '%s' "$hist" | jq -r 'if .ok == true and (.entries | type == "array") then [.entries[] | select(.order == "token-ledger-harvest")] | length else "unreadable" end' 2>/dev/null)"
if [[ "$hrc" -ne 0 || ! "$fired" =~ ^[0-9]+$ ]]; then
  log "WARN: could not read gc order history (rc=$hrc, parsed '${fired:-nothing}') — whether the controller has fired the order is UNKNOWN"
  _unproven "controller firing UNKNOWN (gc order history unreadable)"
elif [[ "$fired" -eq 0 ]]; then
  FIRED=0
  log "WARN: gc order history has 0 runs of token-ledger-harvest — the controller has NOT fired it yet, so 'the controller loaded the order' is UNPROVEN. Re-run this test after >= 30m."
  _unproven "controller has not fired the order yet (0 runs)"
else
  FIRED="$fired"
  log "controller has fired the order $fired time(s) ✓"
fi

if [[ "$FIRED" =~ ^[0-9]+$ && "$FIRED" -gt 0 ]]; then
  # it HAS fired: its own wrapper must have logged a recent, successful run (one line per run: "<ts> rc=<n> secs=<n> ...")
  [[ -f "$HLOG" ]] || fail "the order has fired $FIRED time(s) but $HLOG does not exist — the wrapper is not what it runs"
  last="$(tail -n 1 "$HLOG")"
  lts="${last%% *}"
  lrc="$(printf '%s' "$last" | sed -n 's/.* rc=\([0-9][0-9]*\) .*/\1/p')"
  [[ "$lrc" =~ ^[0-9]+$ ]] || fail "cannot read rc from the harvest log's last line: ${last:0:200}"
  [[ "$lrc" -eq 0 ]] || fail "the last scheduled harvest FAILED (rc=$lrc): ${last:0:300}"
  age="$(python3 -c 'import sys, datetime as d; t = d.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=d.timezone.utc); print(int((d.datetime.now(d.timezone.utc) - t).total_seconds()))' "$lts" 2>/dev/null)"
  [[ "$age" =~ ^[0-9]+$ ]] || fail "cannot read the timestamp of the harvest log's last line ('$lts')"
  [[ "$age" -le 14400 ]] || fail "the order has fired but the harvest log's last line is $((age / 60)) min old (> 240 min) — the harvest has stopped running and transcripts the reaper deletes are lost"
  # rc=0 is not "it harvested": a root that moved used to print the normal summary and exit 0. The summary must show transcripts READ.
  sum_re='harvest: ([0-9]+) [^,]*, ([0-9]+) inalteradas'
  if [[ "$last" =~ $sum_re ]]; then
    seen_n=$(( BASH_REMATCH[1] + BASH_REMATCH[2] ))
    [[ "$seen_n" -gt 0 ]] || fail "the last scheduled harvest exited 0 but read ZERO transcripts (0 scanned + 0 unchanged): ${last:0:300}"
    log "last scheduled harvest: rc=0, $((age / 60)) min ago, $seen_n transcripts read ✓"
  elif [[ "$last" == *"outra colheita em curso"* ]]; then
    log "WARN: the last harvest tick was skipped by the ledger lock (another harvest/backfill held it) — it read nothing itself"
    _unproven "last harvest tick was a lock skip (no transcript count to check)"
  else
    fail "the last scheduled harvest exited 0 but its line has no 'harvest: <n> … <m> inalteradas' summary: ${last:0:300}"
  fi
  # the log can lie by omission; the files cannot. The ledger's newest transcript mtime (stored per row at scan time) must not trail the newest
  # transcript on disk by more than 2 harvest intervals + slack. Compared against the transcripts root a human shell sees: a harvest whose own
  # root drifted (HOME/CLAUDE_CONFIG_DIR of the order) keeps logging rc=0 while this lag grows.
  lag="$(_to 120 python3 - "$LEDGER" "$TRANSCRIPTS_ROOT" <<'PY'
import json, os, sys
ledger, root = sys.argv[1], sys.argv[2]
newest_ledger = None
for line in open(ledger, errors="replace"):
    try:
        r = json.loads(line)
    except Exception:
        continue
    if isinstance(r, dict) and isinstance(r.get("mtime_ns"), int) and r["mtime_ns"] > 0:
        newest_ledger = r["mtime_ns"] if newest_ledger is None else max(newest_ledger, r["mtime_ns"])
newest_disk = None
try:
    for proj in os.scandir(root):
        if not proj.is_dir():
            continue
        for f in os.scandir(proj.path):
            if f.name.endswith(".jsonl"):
                t = f.stat().st_mtime_ns
                newest_disk = t if newest_disk is None else max(newest_disk, t)
except OSError as e:
    print("unreadable-root:", e.strerror or e)
    sys.exit(0)
if newest_ledger is None:
    print("no-mtime-in-ledger")
elif newest_disk is None:
    print("no-transcripts-on-disk")
else:
    print((newest_disk - newest_ledger) // 10**9)
PY
)"
  if [[ "$lag" =~ ^-?[0-9]+$ ]]; then
    [[ "$lag" -le 7200 ]] || fail "the ledger trails the newest transcript on disk ($TRANSCRIPTS_ROOT) by $((lag / 60)) min (> 120 min) although the harvest logs rc=0 — it is not harvesting where the transcripts are"
    log "ledger keeps up with the transcripts on disk (newest transcript is ${lag}s newer than the newest the ledger scanned) ✓"
  else
    log "WARN: could not compare the ledger with the transcripts on disk ('${lag:-nothing}')"
    _unproven "ledger vs transcripts-on-disk freshness UNKNOWN (${lag:-nothing})"
  fi
elif [[ -f "$HLOG" ]]; then
  log "harvest log present (a manual or earlier run): $(tail -n 1 "$HLOG" | cut -c1-160)"
else
  log "no $HLOG yet — the wrapper has not run under the order since the reload"
fi

# ── 6. the study is published on 📚 Estudos — INTERNAL, behind the admin login ──
IDX="$ESTUDOS_DIR/index.json"
[[ -f "$IDX" ]] || fail "the Estudos index does not exist: $IDX"
jq -e '.estudos | type == "array"' "$IDX" >/dev/null 2>&1 || fail "the Estudos index is not valid JSON with an 'estudos' list: $IDX"
cnt="$(jq --arg s "$SLUG" '[.estudos[] | select(.slug == $s)] | length' "$IDX" 2>/dev/null)"
[[ "$cnt" == "1" ]] || fail "the Estudos index has $cnt entries for slug $SLUG (expected exactly 1)"
pub="$(jq -r --arg s "$SLUG" '[.estudos[] | select(.slug == $s)][0] | (.publico // false) | tostring' "$IDX" 2>/dev/null)"
[[ "$pub" == "false" ]] || fail "the study is marked publico=$pub — that serves it on a host with NO login; this study is internal"
arq="$(jq -r --arg s "$SLUG" '[.estudos[] | select(.slug == $s)][0].arquivo' "$IDX" 2>/dev/null)"
[[ "$arq" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.html$ ]] || fail "the index entry's arquivo is not a plain .html name the dashboard accepts: '$arq'"
page="$ESTUDOS_DIR/$arq"
[[ -f "$page" ]] || fail "the index points at $arq but the file does not exist (the dashboard drops orphan entries silently — a 404 for whoever clicks)"
psize="$(wc -c < "$page" | tr -d ' ')"
[[ "$psize" -ge 5000 ]] || fail "the published page is only $psize bytes — not the study"
grep -q -F 'bead-token-meter' "$page" || fail "the published page does not mention the meter — it is not this study"
grep -q -F 'id="estudo-tabelas"' "$page" || fail "the published page lacks the table behaviour (click-to-sort / per-column filter / sticky header — wa-6qnv9)"
log "Estudos entry: slug $SLUG, $arq ($psize bytes), internal (no publico) ✓"

code="$(_to 15 curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$ESTUDOS_PORT/estudos/$SLUG" 2>/dev/null)"
case "${code:-000}" in
  200) log "the admin daemon on :$ESTUDOS_PORT serves /estudos/$SLUG (HTTP 200) ✓" ;;
  000) log "WARN: nothing answered on 127.0.0.1:$ESTUDOS_PORT — the page is in the index but whether the daemon serves it is UNKNOWN"
       _unproven "admin daemon on :$ESTUDOS_PORT unreachable (page served: unknown)" ;;
  404|5??) fail "the admin daemon answered HTTP $code for /estudos/$SLUG — the page is indexed but not served" ;;
  *)   log "WARN: /estudos/$SLUG answered HTTP $code (not 200, not an error) — serving is UNPROVEN from here"
       _unproven "/estudos/$SLUG answered HTTP $code" ;;
esac

line="PASS"
[[ "$UNPROVEN_N" -gt 0 ]] && line="$line ($UNPROVEN_N unproven: $UNPROVEN)"
[[ -n "$NOTES" ]] && line="$line [note: $NOTES]"
log "$line"
exit 0
