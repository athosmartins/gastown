#!/usr/bin/env bash
# gate-g8dmmyf-read-failure-not-race.selftest.sh (ga-g8dmmyf, 2026-11-23)
#
# THE BUG (measured 23/11 in a Dolt brown-out, marker ga-ponlqgd; the bead has the log counts): the
# dispatcher's claim step read the marker with `bd show ... || echo "[]"`. Dolt was failing under
# load, so the read failed, VERIFY_LABELS came back EMPTY — the same value as "I read the marker and
# it carries no gate-status:queued" — and every sweep logged "no longer queued (raced away before
# claim)" and exited. The marker was gate-status:queued the whole time; the gate was blind for tens
# of minutes and the log said "benign race". Three answers collapsed into two: read it and it is
# queued / read it and it is not / could not read it (root-class:error-vs-empty).
#
# THE CLASS (same file, same shape, all swept here): a failed read that becomes the value of a
# genuinely empty answer, and that value then drives a decision or a sentence nobody can doubt:
#   1. claim (queued -> dispatching): "raced away" for a read that failed.        -> claim-verify
#   2. dispatching-TTL recovery: a failed list of RUNNING runs read as "no live run", so a marker
#      whose Phase B is still going was re-queued as a zombie. Destructive.        -> dispatching-ttl-reads
#   3. marker fetch: a failed `bd list` logged "Found 0 queued marker(s) / No queued markers".
#                                                                                   -> marker-fetch
#   4. verdict:FAIL reason: a failed `bd comments` told the builder "empty/unparseable reason".
#                                                                                   -> gate-collect-verdicts-fn
#   5. the guard's own claim (ready -> claimed): the same "raced away" sentence.   -> claim-verify (guard)
#
# What stays as it was, deliberately: a SUCCESSFUL read that says "not queued" is still "raced away",
# "dispatching" is still "already dispatching", an empty-but-readable list is still an empty list, and
# a failed read always ends INERT (nothing claimed, nothing re-queued, retried next sweep).
#
# Strategy: extract the live blocks (SELFTEST-EXTRACT sentinels), run them under `set -euo pipefail`
# with a fake bd that can fail in seven different ways, and assert on what the log says and on what
# the block did. Each block also gets its LEGACY shape (verbatim copy of the pre-fix text) as a
# control: the same case matrix must reproduce the bug on it, otherwise a green result here would
# say nothing. (No `git show HEAD` self-certification: at any committed state HEAD is the fix.)
# Then mutants of the live blocks: each must turn a specific case red.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD="$SELF_DIR/quality-gate-guard.sh"
SHIM="$SELF_DIR/../../../scripts/bd-list-cached.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
flat() { printf '%s' "$1" | tr '\n' '|' | cut -c1-400; }

echo "== gate-g8dmmyf-read-failure-not-race.selftest (ga-g8dmmyf) =="

for f in "$DISPATCHER" "$GUARD" "$SHIM"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1      || { echo "FATAL: jq required" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_block() {  # <file> <name> — the lines BETWEEN the sentinels (sentinels dropped)
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# mutate <in-file> <out-file> <old> <new> — python: the swap must hit EXACTLY ONE place, or the mutant is a no-op
cat > "$TMP/mutate.py" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
n = text.count(old)
if n != 1:
    sys.stderr.write("mutate: anchor occurs %d times (need exactly 1): %r\n" % (n, old))
    sys.exit(3)
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY

# ── the LEGACY shapes: verbatim copies of the pre-fix text (controls, see the header) ──────────────
cat > "$TMP/legacy-claim-dispatcher.sh" <<'LEGACY'
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "[]")
VERIFY_LABELS=$(echo "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$VERIFY_LABELS" | grep "gate-status:dispatching" >/dev/null; then
  log "Marker $MARKER_ID already dispatching by another process. Skipping."
  exit 0
fi
if ! echo "$VERIFY_LABELS" | grep "gate-status:queued" >/dev/null; then
  log "Marker $MARKER_ID no longer queued (raced away before claim). Skipping."
  exit 0
fi
LEGACY
cat > "$TMP/legacy-claim-guard.sh" <<'LEGACY'
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null \
  | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "{}")
CURRENT_LABELS=$(echo "$VERIFY_JSON" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$CURRENT_LABELS" | grep "gate-status:claimed" >/dev/null; then
  log "Marker $MARKER_ID already claimed by another sweep. Skipping."
  exit 0
fi

if ! echo "$CURRENT_LABELS" | grep "gate-status:ready" >/dev/null; then
  log "Marker $MARKER_ID no longer ready (raced away before claim). Skipping."
  exit 0
fi
LEGACY
cat > "$TMP/legacy-ttl-reads.sh" <<'LEGACY'
LIVE_RUN_MARKER_IDS_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --include-infra --limit 0 \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")
DISPATCHING_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --include-infra --limit 0 \
  -l type:quality-gate-marker \
  -l gate-status:dispatching \
  2>/dev/null || echo "[]")
DISPATCHING_COUNT=$(printf '%s\n' "$DISPATCHING_JSON" | jq 'length' 2>/dev/null || echo "0")
LEGACY
cat > "$TMP/legacy-marker-fetch.sh" <<'LEGACY'
MARKERS_JSON=$(bash "$GC_CITY/scripts/bd-list-cached.sh" -C "$GC_CITY" list --json --include-infra --limit 0 \
  -l type:quality-gate-marker \
  -l gate-status:queued \
  2>/dev/null || echo "[]")
LEGACY

# ══ 1. the claim step (dispatcher queued->dispatching, guard ready->claimed) ═════════════════════════
echo "── 1. claim: a read that FAILED is not a race ──"

# The fake store. FAKE_MODE picks how `bd show` answers; FAKE_LABELS is the JSON label list for `labels`.
cat > "$TMP/fake-bd-show.sh" <<'FAKE'
bd() {
  case "${FAKE_MODE:?}" in
    fail)      return 1 ;;                                              # rc!=0, nothing printed (Dolt down / timeout)
    fail-env)  printf '%s' '{"error":"dolt unavailable"}'; return 1 ;;  # an error envelope on stdout AND rc!=0 (ga-07509 shape)
    fail-bead) printf '%s' "[{\"id\":\"m-g8dmmyf\",\"labels\":[${FAKE_LABELS}]}]"; return 1 ;;   # a claimable-looking bead printed, rc!=0: the rc wins
    empty)     return 0 ;;                                              # rc 0, nothing printed
    garbage)   printf '%s\n' 'Error: database is locked'; return 0 ;;   # rc 0, not JSON
    envelope)  printf '%s' '{"error":"issue not found"}'; return 0 ;;   # rc 0, JSON, not a bead
    emptyarr)  printf '%s' '[]'; return 0 ;;                            # rc 0, answers "nothing"
    labels)    printf '%s' "[{\"id\":\"m-g8dmmyf\",\"labels\":[${FAKE_LABELS}]}]"; return 0 ;;
    nolabels)  printf '%s' '[{"id":"m-g8dmmyf"}]'; return 0 ;;          # bd omits the key when there is no label
  esac
}
FAKE

# run_claim <block-file> <mode> [labels] -> OUT (stdout+stderr of the block, then FELL-THROUGH if it did not exit), RC
run_claim() {
  OUT=$(FAKE_MODE="$2" FAKE_LABELS="${3:-}" bash -c '
    set -euo pipefail
    GC_CITY=/fake/city; MARKER_ID=m-g8dmmyf
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    err()  { echo "ERR: $*"; }
    . "$1"
    . "$2"
    echo FELL-THROUGH
  ' _ "$TMP/fake-bd-show.sh" "$1" 2>&1); RC=$?
}

# claim_expect <label> <kind> <already-word>: failed | fell | already | raced  (reads OUT / RC)
claim_expect() {
  local label="$1" kind="$2" word="${3:-}" good=0
  case "$kind" in
    failed)  has "$OUT" "claim read FAILED" && has "$OUT" "NOT a race" && ! has "$OUT" "raced away" && ! has "$OUT" "FELL-THROUGH" && [ "$RC" = 0 ] && good=1 ;;
    fell)    has "$OUT" "FELL-THROUGH" && ! has "$OUT" "raced away" && ! has "$OUT" "FAILED" && ! has "$OUT" "WARN" && [ "$RC" = 0 ] && good=1 ;;
    already) has "$OUT" "already $word" && ! has "$OUT" "FELL-THROUGH" && ! has "$OUT" "FAILED" && [ "$RC" = 0 ] && good=1 ;;
    raced)   has "$OUT" "raced away before claim" && ! has "$OUT" "FAILED" && ! has "$OUT" "FELL-THROUGH" && [ "$RC" = 0 ] && good=1 ;;
  esac
  if [ "$good" = 1 ]; then ok "$label"; else bad "$label — rc=$RC out=[$(flat "$OUT")]"; fi
}

# claim_matrix <name> <block-file> <free-status> <taken-status> <already-word>
claim_matrix() {
  local name="$1" blk="$2" free="$3" taken="$4" word="$5" m
  for m in fail fail-env empty garbage envelope emptyarr; do
    run_claim "$blk" "$m"
    claim_expect "$name: bd show mode '$m' -> 'claim read FAILED (NOT a race)', nothing claimed, no 'raced away'" failed
  done
  # rc!=0 outranks a payload that looks claimable: a failed read cannot vouch for the marker
  run_claim "$blk" fail-bead "\"type:quality-gate-marker\",\"gate-status:$free\""
  claim_expect "$name: bd exits 1 after printing a '$free' bead -> still a failed read (the rc is authoritative)" failed
  run_claim "$blk" labels "\"type:quality-gate-marker\",\"gate-status:$free\""
  claim_expect "$name: readable and '$free' -> falls through to the claim, no warning" fell
  run_claim "$blk" labels "\"type:quality-gate-marker\",\"gate-status:$taken\""
  claim_expect "$name: readable and '$taken' -> 'already $word' (unchanged)" already "$word"
  run_claim "$blk" labels "\"type:quality-gate-marker\",\"gate-status:needs-rebase\""
  claim_expect "$name: readable, not '$free' (another status) -> 'raced away' (a REAL race, unchanged)" raced
  run_claim "$blk" nolabels
  claim_expect "$name: readable, no labels at all -> 'raced away' (no labels is an answer, not a failed read)" raced
}

CLAIM_D="$(extract_block "$DISPATCHER" claim-verify)"
CLAIM_G="$(extract_block "$GUARD" claim-verify)"
if [ -z "$CLAIM_D" ] || [ -z "$CLAIM_G" ]; then
  echo "FATAL: claim-verify sentinel block missing (dispatcher=${#CLAIM_D}B guard=${#CLAIM_G}B)" >&2; exit 2
fi
printf '%s\n' "$CLAIM_D" > "$TMP/claim-dispatcher.sh"
printf '%s\n' "$CLAIM_G"  > "$TMP/claim-guard.sh"

claim_matrix "dispatcher claim" "$TMP/claim-dispatcher.sh" queued dispatching dispatching
claim_matrix "guard claim"      "$TMP/claim-guard.sh"      ready  claimed     claimed

# controls: the LEGACY text must reproduce the 23/11 bug on the very same case
run_claim "$TMP/legacy-claim-dispatcher.sh" fail
if has "$OUT" "no longer queued (raced away before claim)" && [ "$RC" = 0 ]; then
  ok "control: the LEGACY dispatcher claim says 'raced away' for a failed bd show (the 23/11 bug — the case discriminates)"
else bad "control: legacy dispatcher claim did not reproduce the bug: rc=$RC out=[$(flat "$OUT")]"; fi
run_claim "$TMP/legacy-claim-guard.sh" fail
if has "$OUT" "no longer ready (raced away before claim)" && [ "$RC" = 0 ]; then
  ok "control: the LEGACY guard claim says 'raced away' for a failed bd show"
else bad "control: legacy guard claim did not reproduce the bug: rc=$RC out=[$(flat "$OUT")]"; fi

# ══ 2. dispatching-TTL recovery: a failed list of running runs must not become "no live run" ════════
echo "── 2. TTL recovery: an unreadable live-run list must not re-queue a marker whose Phase B is running ──"

FAKE_CITY="$TMP/city"; mkdir -p "$FAKE_CITY/scripts"
cp "$SHIM" "$FAKE_CITY/scripts/bd-list-cached.sh"

cat > "$TMP/fake-bd-list" <<'FAKE'
#!/usr/bin/env bash
# `bd -C <city> list --json ... -l type:quality-gate-run|marker ...` (reached through the REAL cache shim)
case "$*" in
  *" comment "*) exit 0 ;;
  *type:quality-gate-run*)
    case "$FAKE_RUNS" in
      fail)       exit 1 ;;
      fail-valid) echo '[]'; exit 1 ;;                         # prints a valid, empty list AND exits 1: the rc is what says "failed"
      junk)       echo 'Error: database is locked'; exit 0 ;;
      empty)      echo '[]' ;;
      live)       jq -cn '[{id:"run-1", description:("Autonomous gate run\nmarker_id: m-g8dmmyf\nrig: x")}]' ;;
    esac ;;
  *type:quality-gate-marker*)
    case "$FAKE_MARKERS" in
      fail)       exit 1 ;;
      fail-valid) echo '[]'; exit 1 ;;
      junk)       echo 'Error: database is locked'; exit 0 ;;
      one)        jq -cn --arg u "$MARKER_UPDATED" '[{id:"m-g8dmmyf", updated_at:$u, labels:["type:quality-gate-marker","gate-status:dispatching"]}]' ;;
    esac ;;
esac
FAKE
chmod +x "$TMP/fake-bd-list"

TTL_READS="$(extract_block "$DISPATCHER" dispatching-ttl-reads)"
TTL_RECOVERY="$(extract_block "$DISPATCHER" dispatching-ttl-recovery)"
if [ -z "$TTL_READS" ] || [ -z "$TTL_RECOVERY" ]; then
  echo "FATAL: dispatching-ttl-reads / dispatching-ttl-recovery sentinel block missing (${#TTL_READS}B / ${#TTL_RECOVERY}B)" >&2; exit 2
fi
printf '%s\n' "$TTL_READS"    > "$TMP/ttl-reads.sh"
printf '%s\n' "$TTL_RECOVERY" > "$TMP/ttl-recovery.sh"

# run_ttl <reads-block-file> <runs-mode> <markers-mode> -> OUT, RC. The marker is 45 min old in dispatching (TTL 30).
run_ttl() {
  local cache; cache="$(mktemp -d "$TMP/cache.XXXXXX")"
  OUT=$(FAKE_RUNS="$2" FAKE_MARKERS="$3" MARKER_UPDATED="$(iso $(( $(date +%s) - 45 * 60 )))" \
        BD_BIN="$TMP/fake-bd-list" BD_CACHE_OFF=1 BD_CACHE_DIR="$cache" bash -c '
    set -euo pipefail
    GC_CITY="$1"; DISPATCHING_TTL_MINUTES=30; _RQ_SKIPPED=0
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    bd()   { :; }
    gate_requeue_respecting_external() { echo "REQUEUED $1"; return 0; }
    gate_requeue_narrate() { _RQ_SKIPPED=0; }
    . "$2"
    . "$3"
    echo RECOVERY-DONE
  ' _ "$FAKE_CITY" "$1" "$TMP/ttl-recovery.sh" 2>&1); RC=$?
}

# ttl_expect <label> <kind>: requeued | skipped-runs | skipped-markers | live | nothing
ttl_expect() {
  local label="$1" kind="$2" good=0
  case "$kind" in
    requeued)        has "$OUT" "REQUEUED m-g8dmmyf" && ! has "$OUT" "SKIPPED" && has "$OUT" "RECOVERY-DONE" && [ "$RC" = 0 ] && good=1 ;;
    skipped-runs)    ! has "$OUT" "REQUEUED" && has "$OUT" "TTL recovery SKIPPED" && has "$OUT" "live gate-run list" && has "$OUT" "could not be read" && has "$OUT" "RECOVERY-DONE" && [ "$RC" = 0 ] && good=1 ;;
    skipped-markers) ! has "$OUT" "REQUEUED" && has "$OUT" "TTL recovery SKIPPED" && has "$OUT" "dispatching-marker list" && has "$OUT" "could not be read" && has "$OUT" "RECOVERY-DONE" && [ "$RC" = 0 ] && good=1 ;;
    live)            ! has "$OUT" "REQUEUED" && ! has "$OUT" "SKIPPED" && has "$OUT" "has a LIVE gate-run" && [ "$RC" = 0 ] && good=1 ;;
  esac
  if [ "$good" = 1 ]; then ok "$label"; else bad "$label — rc=$RC out=[$(flat "$OUT")]"; fi
}

run_ttl "$TMP/ttl-reads.sh" empty one
ttl_expect "TTL: a 45m marker, the run list READ FINE and is empty -> a real zombie, still re-queued (an empty answer is still an answer)" requeued
run_ttl "$TMP/ttl-reads.sh" live one
ttl_expect "TTL: a 45m marker whose run is live -> not reclaimed (unchanged)" live
run_ttl "$TMP/ttl-reads.sh" fail one
ttl_expect "TTL: the run list could NOT be read (bd list failed) -> recovery SKIPPED with a warning, nothing re-queued" skipped-runs
run_ttl "$TMP/ttl-reads.sh" fail-valid one
ttl_expect "TTL: bd list exits 1 after printing a valid '[]' (the old '|| echo []' shape) -> still a failed read, recovery SKIPPED" skipped-runs
run_ttl "$TMP/ttl-reads.sh" junk one
ttl_expect "TTL: the run list came back as junk with rc 0 -> recovery SKIPPED, nothing re-queued" skipped-runs
run_ttl "$TMP/ttl-reads.sh" empty fail
ttl_expect "TTL: the dispatching-marker list could NOT be read -> its own warning (it used to skip in silence), nothing re-queued" skipped-markers
run_ttl "$TMP/ttl-reads.sh" empty fail-valid
ttl_expect "TTL: the dispatching list exits 1 after printing '[]' -> still a failed read, with its warning" skipped-markers
run_ttl "$TMP/ttl-reads.sh" empty junk
ttl_expect "TTL: the dispatching list came back as junk with rc 0 -> warning, nothing re-queued" skipped-markers
run_ttl "$TMP/ttl-reads.sh" fail fail
ttl_expect "TTL: both lists unreadable -> recovery SKIPPED, nothing re-queued" skipped-runs

# control: the LEGACY reads re-queue a marker whose Phase B may well be running when the run list fails
run_ttl "$TMP/legacy-ttl-reads.sh" fail one
if has "$OUT" "REQUEUED m-g8dmmyf" && has "$OUT" "Re-queuing zombie dispatching marker"; then
  ok "control: the LEGACY reads turn a FAILED run-list read into 'no live run' and re-queue the marker (destructive default — the case discriminates)"
else bad "control: legacy TTL reads did not re-queue on a failed run list: rc=$RC out=[$(flat "$OUT")]"; fi

# ══ 3. marker fetch: a failed `bd list` is not an empty queue ═══════════════════════════════════════
echo "── 3. marker fetch: an unreadable queue is not 'No queued markers' ──"

cat > "$TMP/fake-bd-fetch" <<'FAKE'
#!/usr/bin/env bash
case "$FAKE_FETCH" in
  ok2)  echo '[{"id":"m-1","labels":["gate-status:queued"]},{"id":"m-2","labels":["gate-status:queued"]}]' ;;
  ok0)  echo '[]' ;;
  fail) exit 1 ;;
  fail-valid) echo '[]'; exit 1 ;;     # a valid, empty list AND rc 1: the rc is what says "failed"
  junk) echo 'Error: database is locked'; exit 0 ;;
esac
FAKE
chmod +x "$TMP/fake-bd-fetch"

FETCH="$(extract_block "$DISPATCHER" marker-fetch)"
[ -n "$FETCH" ] || { echo "FATAL: marker-fetch sentinel block missing" >&2; exit 2; }
printf '%s\n' "$FETCH" > "$TMP/fetch.sh"

# run_fetch <block-file> <mode> -> OUT, RC (AFTER-FETCH n=<count> only if the block fell through)
run_fetch() {
  local cache; cache="$(mktemp -d "$TMP/cache.XXXXXX")"
  OUT=$(FAKE_FETCH="$2" BD_BIN="$TMP/fake-bd-fetch" BD_CACHE_OFF=1 BD_CACHE_DIR="$cache" bash -c '
    set -euo pipefail
    GC_CITY="$1"
    log()  { echo "LOG: $*"; }
    warn() { echo "WARN: $*"; }
    . "$2"
    echo "AFTER-FETCH n=$(printf "%s" "$MARKERS_JSON" | jq length)"
  ' _ "$FAKE_CITY" "$1" 2>&1); RC=$?
}

run_fetch "$TMP/fetch.sh" ok2
if has "$OUT" "AFTER-FETCH n=2" && ! has "$OUT" "WARN" && [ "$RC" = 0 ]; then
  ok "fetch: two queued markers -> both reach the sweep, no warning"
else bad "fetch: healthy read broke: rc=$RC out=[$(flat "$OUT")]"; fi
run_fetch "$TMP/fetch.sh" ok0
if has "$OUT" "AFTER-FETCH n=0" && ! has "$OUT" "WARN" && [ "$RC" = 0 ]; then
  ok "fetch: a readable EMPTY queue still falls through as empty (the sweep then says 'No queued markers', truthfully)"
else bad "fetch: a readable empty queue was treated as a failure: rc=$RC out=[$(flat "$OUT")]"; fi
for m in fail fail-valid junk; do
  run_fetch "$TMP/fetch.sh" "$m"
  if has "$OUT" "WARN" && has "$OUT" "could not be read" && has "$OUT" "NOT an empty queue" && ! has "$OUT" "AFTER-FETCH" && [ "$RC" = 0 ]; then
    ok "fetch: mode '$m' -> warning 'could not be read ... NOT an empty queue', the sweep ends inert (exit 0) before 'Found 0 / No queued markers'"
  else bad "fetch: mode '$m' did not end the sweep honestly: rc=$RC out=[$(flat "$OUT")]"; fi
done
run_fetch "$TMP/legacy-marker-fetch.sh" fail
if has "$OUT" "AFTER-FETCH n=0" && ! has "$OUT" "WARN"; then
  ok "control: the LEGACY fetch hands a FAILED read to the sweep as an empty queue, silently (the case discriminates)"
else bad "control: legacy fetch did not collapse the failure: rc=$RC out=[$(flat "$OUT")]"; fi

# ══ 4. verdict:FAIL reason: unread comments are not an empty reason ═════════════════════════════════
echo "── 4. verdict:FAIL: 'comments could not be read' is not 'no parseable reason' ──"

fn_collect="$(extract_block "$DISPATCHER" gate-collect-verdicts-fn)"
fn_peek="$(extract_block "$DISPATCHER" session-peek-reports-dead-fn)"
fn_link="$(extract_block "$DISPATCHER" gate-verdict-identity-link-fn)"
if [ -z "$fn_collect" ] || [ -z "$fn_peek" ] || [ -z "$fn_link" ]; then
  echo "FATAL: gate-collect-verdicts-fn / session-peek-reports-dead-fn / gate-verdict-identity-link-fn sentinel block missing" >&2; exit 2
fi

# fail_case <comments-mode> -> OUT: one closed verdict bead labelled verdict:FAIL; modes: unreadable | empty | reason
fail_case() {
  local mode="$1" fix; fix="$(mktemp -d "$TMP/fix.XXXXXX")"
  printf '%s\n' '{"status":"closed","labels":["type:quality-gate-verdict","verdict:FAIL"],"assignee":"reviewer-vb1"}' > "$fix/vb1.json"
  case "$mode" in
    unreadable) : > "$fix/vb1.comments.fail" ;;
    empty)      printf '%s\n' '[]' > "$fix/vb1.comments.json" ;;
    reason)     printf '%s\n' '[{"text":"VERDICT: FAIL — the retry loop swallows the exception at line 12"}]' > "$fix/vb1.comments.json" ;;
  esac
  OUT=$(bash -c '
    set -euo pipefail
    GC_CITY="/fake/city"; FIX="$1"; shift
    VERDICT_BEAD_IDS=("$@")
    bd() {
      local sub="" id="" a
      for a in "$@"; do
        case "$a" in
          show|comments|close) sub="$a" ;;
          -*|/*) : ;;
          *) [ -n "$sub" ] && [ -z "$id" ] && id="$a" ;;
        esac
      done
      case "$sub" in
        show)     cat "$FIX/$id.json" ;;
        comments) [ -f "$FIX/$id.comments.fail" ] && return 1
                  cat "$FIX/$id.comments.json" ;;
      esac
      return 0
    }
    gc()   { echo "gc session peek: session not found" >&2; return 1; }
    log()  { printf "LOG|%s\n" "$*"; }
    warn() { printf "WARN|%s\n" "$*"; }
    '"$fn_peek"'
    '"$fn_link"'
    '"$fn_collect"'
    GATE_FAIL_NO_EVAL=0
    gate_collect_verdicts
    printf "RESULT|ANY_FAIL=%s|FAIL_REASONS=%s\n" "$ANY_FAIL" "$FAIL_REASONS"
  ' _ "$fix" vb1 2>&1); RC=$?
}

fail_case unreadable
if has "$OUT" "ANY_FAIL=1" && has "$OUT" "could NOT be read" && has "$OUT" "could not be read this sweep" \
   && has "$OUT" "raw_comments=UNREADABLE" && ! has "$OUT" "raw_comments=[]" \
   && ! has "$OUT" "no parseable reason" && ! has "$OUT" "empty/unparseable reason"; then
  ok "FAIL reason: bd comments FAILED -> still a FAIL (fail-safe); the forensics line, the warning and the builder text all say the comments could not be read (never 'raw_comments=[]', never 'empty/unparseable')"
else bad "FAIL reason: an unreadable comment read was described as an empty reason: rc=$RC out=[$(flat "$OUT")]"; fi
fail_case empty
if has "$OUT" "ANY_FAIL=1" && has "$OUT" "no parseable reason" && has "$OUT" "empty/unparseable reason" && has "$OUT" "raw_comments=[]" \
   && ! has "$OUT" "could NOT be read" && ! has "$OUT" "UNREADABLE"; then
  ok "FAIL reason: comments READ FINE and hold nothing -> the INCONCLUSIVE wording and 'raw_comments=[]' are unchanged (an empty reason is still an empty reason)"
else bad "FAIL reason: the readable-but-empty case changed: rc=$RC out=[$(flat "$OUT")]"; fi
fail_case reason
if has "$OUT" "ANY_FAIL=1" && has "$OUT" "the retry loop swallows the exception" && has "$OUT" "raw_comments=[{" \
   && ! has "$OUT" "could NOT be read" && ! has "$OUT" "UNREADABLE" && ! has "$OUT" "WARN"; then
  ok "FAIL reason: a parseable reviewer comment still reaches the builder verbatim"
else bad "FAIL reason: a parseable reason no longer reaches the builder: rc=$RC out=[$(flat "$OUT")]"; fi

# ══ 5. mutants of the live blocks: each must turn a specific case red ═════════════════════════════════
echo "── 5. mutants: the matrix is not vacuous ──"

# Each mutant is the live block with ONE change (python: the swap must hit exactly one place). It runs
# the case that exists to catch it and must NOT show the honest shape any more.
NL=$'\n'
mutate_to() {  # <block-file> <out-file> <old> <new> — false (and a counted failure) if the swap did not apply
  if python3 "$TMP/mutate.py" "$1" "$2" "$3" "$4" 2>"$TMP/mutate.err"; then return 0; fi
  bad "mutation did not apply — $(cat "$TMP/mutate.err")"; return 1
}
verdict() {  # <label> <honest: 0|1> — a mutant is killed iff the honest shape is gone
  if [ "$2" = 1 ]; then bad "$1 — SURVIVED: the case still ended honestly with the mutation in place"
  else ok "$1 — killed ($(flat "$OUT" | cut -c1-90))"; fi
}
claim_honest() { has "$OUT" "claim read FAILED" && ! has "$OUT" "raced away" && ! has "$OUT" "FELL-THROUGH" && [ "$RC" = 0 ]; }
ttl_honest() {  # <runs|markers>
  local want
  case "$1" in runs) want="live gate-run list" ;; markers) want="dispatching-marker list" ;; esac
  ! has "$OUT" "REQUEUED" && has "$OUT" "TTL recovery SKIPPED" && has "$OUT" "could not be read" && has "$OUT" "$want"
}
fetch_honest() { has "$OUT" "NOT an empty queue" && ! has "$OUT" "AFTER-FETCH" && [ "$RC" = 0 ]; }

claim_mutants() {  # <name> <block-file> <free-status>
  local name="$1" blk="$2" free="$3" h
  if mutate_to "$blk" "$TMP/mut.sh" '"$MARKER_ID" --json 2>/dev/null) || CLAIM_READ_OK=0' '"$MARKER_ID" --json 2>/dev/null) || true'; then
    run_claim "$TMP/mut.sh" fail-bead "\"gate-status:$free\""; h=0; claim_honest && h=1
    verdict "mutant [$name claim] the rc of bd show is ignored (case fail-bead)" "$h"
  fi
  if mutate_to "$blk" "$TMP/mut.sh" "jq -er 'if type==" "jq -r 'if type=="; then
    run_claim "$TMP/mut.sh" envelope; h=0; claim_honest && h=1
    verdict "mutant [$name claim] jq without -e: 'nothing selected' reads as a clean answer (case envelope)" "$h"
  fi
  if mutate_to "$blk" "$TMP/mut.sh" 'select((.id // "") != "") | ' ''; then
    run_claim "$TMP/mut.sh" envelope; h=0; claim_honest && h=1
    verdict "mutant [$name claim] an answer that is not a bead is accepted (case envelope)" "$h"
  fi
  if mutate_to "$blk" "$TMP/mut.sh" "ga-g8dmmyf).\"${NL}  exit 0" "ga-g8dmmyf).\""; then
    run_claim "$TMP/mut.sh" fail; h=0; claim_honest && h=1
    verdict "mutant [$name claim] the failure branch falls through instead of exiting (case fail)" "$h"
  fi
}
claim_mutants dispatcher "$TMP/claim-dispatcher.sh" queued
claim_mutants guard      "$TMP/claim-guard.sh"      ready

JQ_RUN="jq -e 'type == \"array\"' <<<\"\$LIVE_RUN_MARKER_IDS_JSON\""
JQ_DSP="jq -e 'type == \"array\"' <<<\"\$DISPATCHING_JSON\""
if mutate_to "$TMP/ttl-reads.sh" "$TMP/mut.sh" '[ "$LIVE_RUN_READ_OK" = "1" ] || DISPATCHING_COUNT=0' ':'; then
  run_ttl "$TMP/mut.sh" fail one; h=0; ttl_honest runs && h=1
  verdict "mutant [TTL] the recovery still runs after a failed run list (case runs=fail)" "$h"
fi
if mutate_to "$TMP/ttl-reads.sh" "$TMP/mut.sh" " || ! $JQ_RUN >/dev/null 2>&1; then" "; then"; then
  run_ttl "$TMP/mut.sh" junk one; h=0; ttl_honest runs && h=1
  verdict "mutant [TTL] no list check on the run list: junk with rc 0 is 'no live run' (case runs=junk)" "$h"
fi
if mutate_to "$TMP/ttl-reads.sh" "$TMP/mut.sh" "2>/dev/null) || ! $JQ_RUN" "2>/dev/null; true) || ! $JQ_RUN"; then
  run_ttl "$TMP/mut.sh" fail-valid one; h=0; ttl_honest runs && h=1
  verdict "mutant [TTL] the rc of the run list is ignored: a failed read that printed '[]' is 'no live run' (case runs=fail-valid)" "$h"
fi
if mutate_to "$TMP/ttl-reads.sh" "$TMP/mut.sh" " || ! $JQ_DSP >/dev/null 2>&1; then" "; then"; then
  run_ttl "$TMP/mut.sh" empty junk; h=0; ttl_honest markers && h=1
  verdict "mutant [TTL] no list check on the dispatching list: junk with rc 0 skips in silence (case markers=junk)" "$h"
fi
if mutate_to "$TMP/ttl-reads.sh" "$TMP/mut.sh" "2>/dev/null) || ! $JQ_DSP" "2>/dev/null; true) || ! $JQ_DSP"; then
  run_ttl "$TMP/mut.sh" empty fail-valid; h=0; ttl_honest markers && h=1
  verdict "mutant [TTL] the rc of the dispatching list is ignored (case markers=fail-valid)" "$h"
fi

JQ_MRK="jq -e 'type == \"array\"' <<<\"\$MARKERS_JSON\""
if mutate_to "$TMP/fetch.sh" "$TMP/mut.sh" "ga-g8dmmyf).\"${NL}  exit 0" "ga-g8dmmyf).\""; then
  run_fetch "$TMP/mut.sh" fail; h=0; fetch_honest && h=1
  verdict "mutant [fetch] the failure branch falls through as an empty queue (case fail)" "$h"
fi
if mutate_to "$TMP/fetch.sh" "$TMP/mut.sh" " || ! $JQ_MRK >/dev/null 2>&1; then" "; then"; then
  run_fetch "$TMP/mut.sh" junk; h=0; fetch_honest && h=1
  verdict "mutant [fetch] no list check: junk with rc 0 is accepted as the queue (case junk)" "$h"
fi
if mutate_to "$TMP/fetch.sh" "$TMP/mut.sh" "2>/dev/null) || ! $JQ_MRK" "2>/dev/null; true) || ! $JQ_MRK"; then
  run_fetch "$TMP/mut.sh" fail-valid; h=0; fetch_honest && h=1
  verdict "mutant [fetch] the rc is ignored: a failed read that printed '[]' is an empty queue (case fail-valid)" "$h"
fi

printf '%s\n' "$fn_collect" > "$TMP/collect.sh"
if mutate_to "$TMP/collect.sh" "$TMP/mut-collect.sh" "VB_COMMENTS_READ_OK=0${NL}        fi${NL}        FAIL_COMMENT=\$(printf" "VB_COMMENTS_READ_OK=1${NL}        fi${NL}        FAIL_COMMENT=\$(printf"; then
  fn_collect_live="$fn_collect"; fn_collect="$(cat "$TMP/mut-collect.sh")"
  fail_case unreadable; fn_collect="$fn_collect_live"
  h=0; if has "$OUT" "could NOT be read" && ! has "$OUT" "empty/unparseable reason"; then h=1; fi
  verdict "mutant [FAIL reason] a failed comments read is never remembered (the legacy wording returns; case unreadable)" "$h"
fi
FORENSIC_OLD="if [ \"\$VB_COMMENTS_READ_OK\" = \"1\" ]; then printf '%s' \"\$VB_COMMENTS_JSON\" | jq -c . 2>/dev/null | cut -c1-2000; else printf 'UNREADABLE (bd comments failed)'; fi"
FORENSIC_NEW="printf '%s' \"\$VB_COMMENTS_JSON\" | jq -c . 2>/dev/null | cut -c1-2000"
if mutate_to "$TMP/collect.sh" "$TMP/mut-collect.sh" "$FORENSIC_OLD" "$FORENSIC_NEW"; then
  fn_collect_live="$fn_collect"; fn_collect="$(cat "$TMP/mut-collect.sh")"
  fail_case unreadable; fn_collect="$fn_collect_live"
  h=0; if has "$OUT" "raw_comments=UNREADABLE"; then h=1; fi
  verdict "mutant [FAIL reason] the forensics line prints the swapped-in '[]' for a failed read (case unreadable)" "$h"
fi

echo
echo "gate-g8dmmyf selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
