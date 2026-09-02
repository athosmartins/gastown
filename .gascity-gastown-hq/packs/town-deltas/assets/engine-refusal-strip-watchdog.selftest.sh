#!/usr/bin/env bash
# engine-refusal-strip-watchdog.selftest.sh — hermetic test for
# engine-refusal-strip-watchdog.sh (ga-pxtib).
#
# Stubs `gc` (dolt sql / mail send) and `bd` (show / label add / comment) with
# fixture-driven shims so NO real Dolt query, label mutation, comment, or mail
# ever fires. Drives the watchdog through every decision branch (AC1-AC4 of
# ga-pxtib) and asserts the actions it would take (recorded by the shims).
# Exits 0 on PASS, non-zero on first failure.
#
# `gc dolt sql -q "USE hq; <query>" -r csv` is routed first by table name
# (dolt_log vs dolt_diff_labels — neither name is a substring of the other).
# Within dolt_diff_labels, a SECOND routing step distinguishes the per-commit
# specific lookup (has "to_commit = '<hash>'") from the marker-removal
# candidate-discovery scan (no to_commit clause — see the watchdog's own
# header doc for why that query can't use dolt_log.message like its primary
# counterpart does). `bd -C <city> show <id>` is served from a per-issue JSON
# fixture file; `label add` / `comment` / `mail send` are recorded to an
# actions log for assertion.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$HERE/engine-refusal-strip-watchdog.sh"
[ -f "$WATCHDOG" ] || { echo "FAIL: watchdog not found at $WATCHDOG" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  ok: $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SHIM_DIR="$WORK/bin"
ACTIONS="$WORK/actions.log"
CANDIDATES_CSV="$WORK/candidates.csv"
DIFF_DIR="$WORK/diffs"
BEADS_DIR="$WORK/beads"
mkdir -p "$SHIM_DIR" "$DIFF_DIR" "$BEADS_DIR"
: > "$ACTIONS"

# ── gc shim ───────────────────────────────────────────────────────────────────
cat > "$SHIM_DIR/gc" <<SHIM
#!/usr/bin/env bash
# engine-refusal-strip-watchdog.sh calls two DIFFERENT argv shapes (dolt sql
# deliberately omits --city — see the "WHY NOT --city" comment on DOLT_SQL()
# in the watchdog itself; mail send keeps it, matching city-health-sentinel's
# proven precedent):
#   gc dolt sql -q "USE hq; <query>" -r csv
#     -> \$1=dolt \$2=sql \$3=-q \$4=<query> \$5=-r \$6=csv
#   gc --city <city> mail send mayor -s <subj> -m <body>
#     -> \$1=--city \$2=<city> \$3=mail \$4=send \$5=mayor ...
case "\$1 \$2" in
  "dolt sql")
    q="\$4"
    case "\$q" in
      *dolt_diff_labels*)
        # Two DIFFERENT dolt_diff_labels queries land here: the per-commit
        # specific lookup (has "to_commit = '<hash>'" -- used by both the
        # primary AC1 loop and the marker-removal second pass to resolve
        # issue_ids for one already-known commit) and the marker-removal
        # CANDIDATE DISCOVERY scan itself (ga-6u8e4 second fix: no to_commit
        # clause -- filters on from_label = 'pilot:no-auto-dispatch' and a
        # to_commit_date lower bound instead, because dolt_log.message can't
        # be trusted for this event class -- see the watchdog's own header
        # doc). Route on presence of "to_commit = '".
        case "\$q" in
          *"to_commit = '"*)
            hash="\$(printf '%s' "\$q" | sed -n "s/.*to_commit = '\\([^']*\\)'.*/\\1/p")"
            if [ -f "$DIFF_DIR/\$hash.FAIL" ]; then exit 1; fi
            f="$DIFF_DIR/\$hash.csv"
            if [ ! -f "\$f" ]; then printf 'from_issue_id,from_label\n'; exit 0; fi
            # The two per-commit callers filter by DIFFERENT from_label
            # conditions in the real query (primary: IN the 4 refusal
            # labels; marker: = pilot:no-auto-dispatch exactly) — replicate
            # that filtering here so a fixture row meant for one loop is
            # never handed to the other. Needed to test a commit_hash shared
            # across both loops (ga-tb8mt gate review, blocking issue 1).
            case "\$q" in
              *"from_label = 'pilot:no-auto-dispatch'"*)
                { head -1 "\$f"; tail -n +2 "\$f" | awk -F, '\$2=="pilot:no-auto-dispatch"'; }
                ;;
              *"from_label IN ("*)
                { head -1 "\$f"; tail -n +2 "\$f" | awk -F, '\$2=="needs:engine-window" || \$2=="pool:refused:engine-rebuild-required" || \$2=="framework:engine" || \$2=="pilot:refused-reason:engine-rebuild-required"'; }
                ;;
              *) cat "\$f" ;;
            esac
            ;;
          *)
            # Separate failure flag from the dolt_log (primary) query below
            # on purpose: they must be independently failable to test that
            # one query's failure never suppresses the other's pass
            # (ga-tb8mt gate review, blocking issue 2).
            if [ -f "$WORK/marker_candidates.FAIL" ]; then exit 1; fi
            if [ -f "$WORK/marker_candidates.csv" ]; then cat "$WORK/marker_candidates.csv"; else printf 'commit_hash,date\n'; fi
            ;;
        esac
        exit 0
        ;;
      *dolt_log*)
        if [ -f "$WORK/candidates.FAIL" ]; then exit 1; fi
        if [ -f "$CANDIDATES_CSV" ]; then cat "$CANDIDATES_CSV"; else printf 'commit_hash,date\n'; fi
        exit 0
        ;;
      *) printf 'x\n1\n'; exit 0 ;;
    esac
    ;;
  *)
    case "\$3 \$4" in
      "mail send")
        echo "mail \$5" >> "$ACTIONS"   # \$5 = recipient (mayor)
        ;;
    esac
    exit 0
    ;;
esac
SHIM
chmod +x "$SHIM_DIR/gc"

# ── bd shim ───────────────────────────────────────────────────────────────────
cat > "$SHIM_DIR/bd" <<SHIM
#!/usr/bin/env bash
# engine-refusal-strip-watchdog.sh calls:
#   bd -C <city> show <id> --json --include-comments
#   bd -C <city> label add <id> <label>
#   bd -C <city> comment <id> <text>
case "\$3" in
  show)
    id="\$4"
    if [ -f "$BEADS_DIR/\$id.json.FAIL" ]; then exit 1; fi
    f="$BEADS_DIR/\$id.json"
    if [ -f "\$f" ]; then cat "\$f"; else echo "null"; fi
    exit 0
    ;;
  label)
    echo "label \$4 \$5 \$6" >> "$ACTIONS"   # add <id> <labelname>
    exit 0
    ;;
  comment)
    echo "comment \$4" >> "$ACTIONS"
    exit 0
    ;;
  *) exit 0 ;;
esac
SHIM
chmod +x "$SHIM_DIR/bd"

# ── fixture builders ─────────────────────────────────────────────────────────

# Recent, fixed reference timestamps (well within the default 72h lookback).
# Derived from ONE epoch (STRIP_EPOCH) via pure arithmetic rather than N
# independent `date -v-NH` calls, so every offset is EXACT relative to the
# strip instant. Needed below for the sub-minute deltas (ga-iybm6) — a few
# milliseconds of drift between independent `date` invocations wouldn't
# matter at 1h granularity but would matter at 30s granularity.
STRIP_EPOCH="$(date -u -v-4H '+%s' 2>/dev/null || date -u -d '-4 hours' '+%s')"
fmt_epoch_sql() { date -u -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%d %H:%M:%S'; }
fmt_epoch_iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
STRIP_TS="$(fmt_epoch_sql "$STRIP_EPOCH")"
COMMENT_BEFORE_TS="$(fmt_epoch_iso "$((STRIP_EPOCH - 3600))")"    # 1h before strip (stale/unrelated)
COMMENT_AFTER_TS="$(fmt_epoch_iso "$((STRIP_EPOCH + 3600))")"     # 1h after strip (story moved on)
# ga-iybm6: the Mayor's real incident — a justification comment written ~0.5s
# BEFORE the label-strip commit (his loop: bd comment -> bd label remove,
# same deliberate act, sub-second apart). 30s sits comfortably inside the
# fix's default 120s window and comfortably outside "instant", so it
# exercises the window math rather than just the t=0 edge.
COMMENT_NEAR_BEFORE_TS="$(fmt_epoch_iso "$((STRIP_EPOCH - 30))")"
COMMENT_NEAR_AFTER_TS="$(fmt_epoch_iso "$((STRIP_EPOCH + 30))")"
# 150s > the fix's default 120s window — must NOT be treated as the same act.
COMMENT_OUTSIDE_WINDOW_TS="$(fmt_epoch_iso "$((STRIP_EPOCH - 150))")"

# set_candidates "hash1|date1
# hash2|date2"
set_candidates() {
    { echo "commit_hash,date"
      printf '%s\n' "$1" | while IFS='|' read -r h d; do
          [ -z "$h" ] && continue
          echo "$h,$d"
      done
    } > "$CANDIDATES_CSV"
}

# set_marker_candidates "hash1|date1
# hash2|date2" — same shape as set_candidates, but feeds the SEPARATE
# marker-removal (pilot:no-auto-dispatch) detection query.
set_marker_candidates() {
    { echo "commit_hash,date"
      printf '%s\n' "$1" | while IFS='|' read -r h d; do
          [ -z "$h" ] && continue
          echo "$h,$d"
      done
    } > "$WORK/marker_candidates.csv"
}

# set_diff <hash> "issue1|label1
# issue2|label2"
set_diff() {
    { echo "from_issue_id,from_label"
      printf '%s\n' "$2" | while IFS='|' read -r i l; do
          [ -z "$i" ] && continue
          echo "$i,$l"
      done
    } > "$DIFF_DIR/$1.csv"
}

# set_bead <id> <status> <labels-comma-or-empty> <comments-json-array-or-empty>
set_bead() {
    python3 - "$BEADS_DIR/$1.json" "$1" "$2" "$3" "$4" <<'PY'
import json, sys
out, id_, status, labels, comments = sys.argv[1:6]
labels_list = [l for l in labels.split(",") if l]
data = [{
    "id": id_,
    "status": status,
    "labels": labels_list,
    "comments": json.loads(comments) if comments else [],
}]
with open(out, "w") as f:
    json.dump(data, f)
PY
}

# set_bead_raw <id> <raw-json-or-text> — for simulating a `bd show` response
# that is NOT a normal issue array (a structured {"error": "..."} object, or
# garbage/truncated output).
set_bead_raw() {
    printf '%s' "$2" > "$BEADS_DIR/$1.json"
}

reset_all() {
    rm -rf "$WORK/city" "$DIFF_DIR" "$BEADS_DIR" "$WORK/candidates.FAIL" "$WORK/marker_candidates.FAIL"
    mkdir -p "$WORK/city/.gc/state" "$DIFF_DIR" "$BEADS_DIR"
    : > "$ACTIONS"
    rm -f "$CANDIDATES_CSV" "$WORK/marker_candidates.csv"
}

run() {  # run [extra env assignments...]
    env GC_CITY_PATH="$WORK/city" PATH="$SHIM_DIR:$PATH" \
        LOOKBACK_HOURS=72 DOLT_DB=hq "$@" \
        bash "$WATCHDOG" >/dev/null 2>&1
}

echo "== test 1: exposed open bead, unprotected, no comment -> flagged (label+comment) =="
reset_all
set_candidates "hashA|$STRIP_TS"
set_diff "hashA" "ga-exposed1|needs:engine-window"
set_bead "ga-exposed1" "open" "area:infra" ""
run
if grep -q "^label add ga-exposed1 pilot:no-auto-dispatch$" "$ACTIONS" && grep -q "^comment ga-exposed1$" "$ACTIONS"; then
    ok "exposed open bead flagged with label + comment"
else bad "expected label+comment for ga-exposed1, got: $(cat "$ACTIONS")"; fi

echo "== test 2: bead already CLOSED -> no action =="
reset_all
set_candidates "hashB|$STRIP_TS"
set_diff "hashB" "ga-closed1|needs:engine-window"
set_bead "ga-closed1" "closed" "area:infra" ""
run
if [ ! -s "$ACTIONS" ]; then ok "closed bead not flagged"; else bad "acted on closed bead: $(cat "$ACTIONS")"; fi

echo "== test 3: bead already has pilot:no-auto-dispatch -> no action =="
reset_all
set_candidates "hashC|$STRIP_TS"
set_diff "hashC" "ga-protected1|needs:engine-window"
set_bead "ga-protected1" "open" "area:infra,pilot:no-auto-dispatch" ""
run
if [ ! -s "$ACTIONS" ]; then ok "already-vetoed bead not re-flagged"; else bad "acted on protected bead: $(cat "$ACTIONS")"; fi

echo "== test 4: refusal label was RE-ADDED (labels restored) -> no action =="
reset_all
set_candidates "hashD|$STRIP_TS"
set_diff "hashD" "ga-restored1|framework:engine"
set_bead "ga-restored1" "open" "area:infra,framework:engine,needs:engine-window" ""
run
if [ ! -s "$ACTIONS" ]; then ok "bead with restored refusal labels not flagged"; else bad "acted on restored-label bead: $(cat "$ACTIONS")"; fi

echo "== test 5: bead has a comment POSTDATING the strip -> no action (story moved on) =="
reset_all
set_candidates "hashE|$STRIP_TS"
set_diff "hashE" "ga-commented1|needs:engine-window"
set_bead "ga-commented1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_AFTER_TS\"}]"
run
if [ ! -s "$ACTIONS" ]; then ok "bead with postdating comment not flagged"; else bad "acted despite postdating comment: $(cat "$ACTIONS")"; fi

echo "== test 5b: bead has a comment PREDATING the strip -> still flagged (old comment doesn't count) =="
reset_all
set_candidates "hashE2|$STRIP_TS"
set_diff "hashE2" "ga-oldcomment1|needs:engine-window"
set_bead "ga-oldcomment1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\"}]"
run
if grep -q "^label add ga-oldcomment1 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "bead with only a predating comment still flagged"
else bad "expected flag despite stale comment, got: $(cat "$ACTIONS")"; fi

echo "== test 5c (ga-iybm6): comment predates the strip by 30s, WITHIN the window -> NOT flagged (comment-then-strip is one deliberate act; order must not matter) =="
reset_all
set_candidates "hashE3|$STRIP_TS"
set_diff "hashE3" "ga-nearbefore1|needs:engine-window"
set_bead "ga-nearbefore1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_NEAR_BEFORE_TS\"}]"
run
if [ ! -s "$ACTIONS" ]; then ok "near-before comment (30s, within window) averts the flag"; else bad "flagged despite a near-before deliberate-unblock comment: $(cat "$ACTIONS")"; fi

echo "== test 5d (ga-iybm6): comment predates the strip by 150s, OUTSIDE the window -> still flagged (a stale/unrelated comment must not launder a silent strip) =="
reset_all
set_candidates "hashE4|$STRIP_TS"
set_diff "hashE4" "ga-outsidewindow1|needs:engine-window"
set_bead "ga-outsidewindow1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_OUTSIDE_WINDOW_TS\"}]"
run
if grep -q "^label add ga-outsidewindow1 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "comment just outside the window still flagged"
else bad "expected flag for a comment outside the window, got: $(cat "$ACTIONS")"; fi

echo "== test 5e (ga-iybm6): comment postdates the strip by 30s -> NOT flagged (regression guard: postdate-by-any-amount must keep working unchanged) =="
reset_all
set_candidates "hashE5|$STRIP_TS"
set_diff "hashE5" "ga-nearafter1|needs:engine-window"
set_bead "ga-nearafter1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_NEAR_AFTER_TS\"}]"
run
if [ ! -s "$ACTIONS" ]; then ok "near-after comment (30s later) averts the flag"; else bad "flagged despite a near-after comment: $(cat "$ACTIONS")"; fi

echo "== test 6: in_progress (not closed) unprotected bead -> flagged too =="
reset_all
set_candidates "hashF|$STRIP_TS"
set_diff "hashF" "ga-inprogress1|pool:refused:engine-rebuild-required"
set_bead "ga-inprogress1" "in_progress" "area:infra" ""
run
if grep -q "^label add ga-inprogress1 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "in_progress unprotected bead flagged"
else bad "expected flag for in_progress bead, got: $(cat "$ACTIONS")"; fi

echo "== test 7: already-processed commit hash -> skipped, no re-flag =="
reset_all
set_candidates "hashG|$STRIP_TS"
set_diff "hashG" "ga-dup1|needs:engine-window"
set_bead "ga-dup1" "open" "area:infra" ""
echo "hashG" > "$WORK/city/.gc/state/engine-refusal-strip-watchdog.processed"
run
if [ ! -s "$ACTIONS" ]; then ok "already-processed commit skipped, no duplicate flag"; else bad "re-flagged a processed commit: $(cat "$ACTIONS")"; fi

echo "== test 8: dolt_diff_labels lookup fails -> commit NOT marked processed (retried next pass) =="
reset_all
set_candidates "hashH|$STRIP_TS"
touch "$DIFF_DIR/hashH.FAIL"
set_bead "ga-retry1" "open" "area:infra" ""
run
if [ -s "$ACTIONS" ]; then bad "unexpected action on a failed diff lookup: $(cat "$ACTIONS")"; else ok "no action while diff lookup fails"; fi
if grep -qxF "hashH" "$WORK/city/.gc/state/engine-refusal-strip-watchdog.processed" 2>/dev/null; then
    bad "hashH was marked processed despite a failed lookup — a real event could be silently dropped"
else
    ok "hashH left unprocessed after failure (will retry)"
fi
# Now the transient failure clears -> a later pass must still catch it.
rm -f "$DIFF_DIR/hashH.FAIL"
set_diff "hashH" "ga-retry1|needs:engine-window"
: > "$ACTIONS"
run
if grep -q "^label add ga-retry1 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "retried commit flagged once the transient failure cleared"
else bad "expected retry to flag ga-retry1, got: $(cat "$ACTIONS")"; fi

echo "== test 9: dolt_log candidate query itself fails -> whole pass skips cleanly, no crash =="
reset_all
touch "$WORK/candidates.FAIL"
run
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$ACTIONS" ]; then
    ok "candidate-query failure -> clean no-op pass (exit 0, no action)"
else bad "expected clean skip on candidate-query failure, got rc=$rc actions=$(cat "$ACTIONS" 2>/dev/null)"; fi

echo "== test 10: DRY_RUN=1 -> would-be flag takes NO real action =="
reset_all
set_candidates "hashI|$STRIP_TS"
set_diff "hashI" "ga-dryrun1|needs:engine-window"
set_bead "ga-dryrun1" "open" "area:infra" ""
run DRY_RUN=1
if [ ! -s "$ACTIONS" ]; then ok "DRY_RUN took no action"; else bad "DRY_RUN mutated: $(cat "$ACTIONS")"; fi
# And DRY_RUN must not consume the dedup state either (a real pass afterward
# should still see the commit as unprocessed and flag for real).
run
if grep -q "^label add ga-dryrun1 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "real pass after DRY_RUN still flags (dry run didn't mark processed)"
else bad "expected real flag after dry run, got: $(cat "$ACTIONS")"; fi

echo "== test 11: kill-switch -> no action even with an exposed bead =="
reset_all
set_candidates "hashJ|$STRIP_TS"
set_diff "hashJ" "ga-killswitch1|needs:engine-window"
set_bead "ga-killswitch1" "open" "area:infra" ""
touch "$WORK/city/.gc/state/engine-refusal-strip-watchdog.disabled"
run
if [ ! -s "$ACTIONS" ]; then ok "kill-switch suppressed all action"; else bad "acted despite kill-switch: $(cat "$ACTIONS")"; fi

echo "== test 12: startup marker written =="
reset_all
set_candidates ""
run
if [ -s "$WORK/city/.gc/state/engine-refusal-strip-watchdog.startup" ]; then ok "startup marker written"; else bad "no startup marker"; fi

echo "== test 13: one commit touches TWO issues — one exposed, one already closed =="
reset_all
set_candidates "hashK|$STRIP_TS"
set_diff "hashK" "ga-multi-exposed|needs:engine-window
ga-multi-closed|framework:engine"
set_bead "ga-multi-exposed" "open" "area:infra" ""
set_bead "ga-multi-closed" "closed" "area:infra" ""
run
if grep -q "^label add ga-multi-exposed pilot:no-auto-dispatch$" "$ACTIONS" \
   && ! grep -q "ga-multi-closed" "$ACTIONS"; then
    ok "multi-issue commit: exposed sibling flagged, closed sibling untouched"
else bad "multi-issue handling wrong, got: $(cat "$ACTIONS")"; fi

echo "== test 14: batched mail — one mail per PASS naming every flagged bead, not one per bead =="
reset_all
set_candidates "hashL1|$STRIP_TS
hashL2|$STRIP_TS"
set_diff "hashL1" "ga-batch1|needs:engine-window"
set_diff "hashL2" "ga-batch2|framework:engine"
set_bead "ga-batch1" "open" "area:infra" ""
set_bead "ga-batch2" "open" "area:infra" ""
run
mail_count="$(grep -c "^mail mayor$" "$ACTIONS" || true)"
if [ "$mail_count" = "1" ] && grep -q "^label add ga-batch1 pilot:no-auto-dispatch$" "$ACTIONS" \
   && grep -q "^label add ga-batch2 pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "both beads flagged, exactly one batched mail to mayor"
else bad "expected 1 batched mail + 2 flags, got: $(cat "$ACTIONS")"; fi

echo "== test 15: no candidates at all -> no mail sent (nothing to report) =="
reset_all
set_candidates ""
run
if ! grep -q "^mail mayor$" "$ACTIONS"; then ok "no mail when nothing was flagged"; else bad "mailed with nothing flagged: $(cat "$ACTIONS")"; fi

echo "== test 16: bead was hard-deleted (bd show returns a structured {\"error\":...} object, not an array) -> not flagged, commit still marked processed (nothing left to ever protect) =="
reset_all
set_candidates "hashM|$STRIP_TS"
set_diff "hashM" "ga-deleted1|needs:engine-window"
set_bead_raw "ga-deleted1" '{"error": "no issues found matching the provided IDs", "schema_version": 1}'
run
if [ -s "$ACTIONS" ]; then bad "acted on a deleted bead: $(cat "$ACTIONS")"; else ok "deleted bead not flagged"; fi
if grep -qxF "hashM" "$WORK/city/.gc/state/engine-refusal-strip-watchdog.processed" 2>/dev/null; then
    ok "commit marked processed — a permanently-deleted bead is never retried forever"
else
    bad "commit for a deleted bead was left unprocessed — would retry forever for no reason"
fi

echo "== test 17: bd show returns garbage/unparseable output (genuinely ambiguous) -> treated as transient, commit NOT marked processed =="
reset_all
set_candidates "hashN|$STRIP_TS"
set_diff "hashN" "ga-garbled1|needs:engine-window"
set_bead_raw "ga-garbled1" 'not valid json at all'
run
if [ -s "$ACTIONS" ]; then bad "acted on unparseable bd show output: $(cat "$ACTIONS")"; else ok "no action on unparseable output"; fi
if grep -qxF "hashN" "$WORK/city/.gc/state/engine-refusal-strip-watchdog.processed" 2>/dev/null; then
    bad "hashN marked processed despite unparseable (ambiguous, possibly transient) bd show output"
else
    ok "hashN left unprocessed after ambiguous output (will retry, doesn't assume 'gone')"
fi

echo "== test 18 (ga-6u8e4): watchdog's OWN veto removed from a bead it previously protected -> re-flagged =="
reset_all
set_marker_candidates "hashO|$STRIP_TS"
set_diff "hashO" "ga-reexposed1|pilot:no-auto-dispatch"
set_bead "ga-reexposed1" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"engine-refusal-strip-watchdog (ga-pxtib): this bead's engine-refusal labels were stripped by commit abc123 ...\"}]"
run
if grep -q "^label add ga-reexposed1 pilot:no-auto-dispatch$" "$ACTIONS" && grep -q "^comment ga-reexposed1$" "$ACTIONS"; then
    ok "bead re-flagged after its own watchdog veto was removed"
else bad "expected re-flag for ga-reexposed1, got: $(cat "$ACTIONS")"; fi

echo "== test 19 (ga-6u8e4): pilot:no-auto-dispatch removed from a bead with NO prior watchdog comment -> NOT flagged (false-positive guard) =="
reset_all
set_marker_candidates "hashP|$STRIP_TS"
set_diff "hashP" "ga-unrelated-veto|pilot:no-auto-dispatch"
set_bead "ga-unrelated-veto" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"cleared the on-device hold, phone available again\"}]"
run
if [ ! -s "$ACTIONS" ]; then
    ok "unrelated no-auto-dispatch clear left untouched (no watchdog fingerprint)"
else bad "false-flagged an unrelated veto removal: $(cat "$ACTIONS")"; fi

echo "== test 20 (ga-6u8e4): watchdog's veto removed, but a comment POSTDATES it -> no action (story moved on) =="
reset_all
set_marker_candidates "hashQ|$STRIP_TS"
set_diff "hashQ" "ga-reexposed-moved-on|pilot:no-auto-dispatch"
set_bead "ga-reexposed-moved-on" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"engine-refusal-strip-watchdog (ga-pxtib): this bead's engine-refusal labels were stripped ...\"},{\"created_at\":\"$COMMENT_AFTER_TS\",\"text\":\"confirmed the fix is live in the deployed binary, safe to clear\"}]"
run
if [ ! -s "$ACTIONS" ]; then
    ok "bead with postdating comment on the marker-removal not re-flagged"
else bad "acted despite postdating comment on marker removal: $(cat "$ACTIONS")"; fi

echo "== test 20b (ga-iybm6): watchdog's own veto removed, but the deliberate-unblock comment predates the removal by 30s (order: comment-then-strip -- the exact live Mayor incident trace) -> NOT re-flagged =="
reset_all
set_marker_candidates "hashQ2|$STRIP_TS"
set_diff "hashQ2" "ga-reexposed-ordering|pilot:no-auto-dispatch"
set_bead "ga-reexposed-ordering" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"engine-refusal-strip-watchdog (ga-pxtib): this bead's engine-refusal labels were stripped ...\"},{\"created_at\":\"$COMMENT_NEAR_BEFORE_TS\",\"text\":\"Unblocking deliberately: patch already staged in docs/pending-engine-window/, see ga-iybm6.\"}]"
run
if [ ! -s "$ACTIONS" ]; then
    ok "deliberate-unblock comment 30s before the removal averts re-flag"
else bad "re-flagged despite a near-before deliberate-unblock comment: $(cat "$ACTIONS")"; fi

echo "== test 21 (ga-tb8mt gate review, blocking issue 1): one commit_hash is a candidate for BOTH loops at once (issue A's refusal label AND issue B's pilot:no-auto-dispatch stripped in the SAME commit) — the marker loop must still evaluate issue B even after the primary loop has processed that commit_hash =="
reset_all
set_candidates "hashR|$STRIP_TS"
set_marker_candidates "hashR|$STRIP_TS"
set_diff "hashR" "ga-shared-a|needs:engine-window
ga-shared-b|pilot:no-auto-dispatch"
set_bead "ga-shared-a" "open" "area:infra" ""
set_bead "ga-shared-b" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"engine-refusal-strip-watchdog (ga-pxtib): this bead's engine-refusal labels were stripped by commit abc123 ...\"}]"
run
if grep -q "^label add ga-shared-a pilot:no-auto-dispatch$" "$ACTIONS" && grep -q "^label add ga-shared-b pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "both the primary-path sibling and the marker-path sibling were flagged despite sharing one commit_hash"
else bad "shared commit_hash across both loops: expected both ga-shared-a and ga-shared-b flagged, got: $(cat "$ACTIONS")"; fi

echo "== test 22 (ga-tb8mt gate review, blocking issue 2): primary dolt_log candidate query fails — the independent marker-removal pass must still run, not be silently skipped too =="
reset_all
touch "$WORK/candidates.FAIL"
set_marker_candidates "hashS|$STRIP_TS"
set_diff "hashS" "ga-marker-only|pilot:no-auto-dispatch"
set_bead "ga-marker-only" "open" "area:infra" "[{\"created_at\":\"$COMMENT_BEFORE_TS\",\"text\":\"engine-refusal-strip-watchdog (ga-pxtib): this bead's engine-refusal labels were stripped by commit abc123 ...\"}]"
run
rc=$?
if [ "$rc" -eq 0 ] && grep -q "^label add ga-marker-only pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "primary query failure didn't suppress the independent marker-removal pass"
else bad "expected marker pass to still flag ga-marker-only despite primary query failure, got rc=$rc actions=$(cat "$ACTIONS" 2>/dev/null)"; fi

echo "== test 23 (ga-tb8mt gate review, blocking issue 2 symmetry): marker-discovery query fails — the primary pass must still run and flag its own candidate =="
reset_all
set_candidates "hashT|$STRIP_TS"
set_diff "hashT" "ga-primary-only|needs:engine-window"
set_bead "ga-primary-only" "open" "area:infra" ""
touch "$WORK/marker_candidates.FAIL"
run
rc=$?
if [ "$rc" -eq 0 ] && grep -q "^label add ga-primary-only pilot:no-auto-dispatch$" "$ACTIONS"; then
    ok "marker-discovery query failure didn't suppress the independent primary pass"
else bad "expected primary pass to still flag ga-primary-only despite marker-discovery failure, got rc=$rc actions=$(cat "$ACTIONS" 2>/dev/null)"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
