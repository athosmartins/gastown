#!/usr/bin/env bash
# pool-probe-priority-sort.selftest.sh — regression guard for ga-x80j1 + ga-0pg2o.
#
# ga-x80j1: wa-worker's and ps-worker's prompt.template.md each carry a
# hand-typed routed-pool probe (originally numbered "Step 1b3", renumbered to
# "Step 1b2" by ga-0pg2o — see below). Both copies explicitly passed `--sort
# oldest`, overriding bd ready's own default (`bd ready --help`: "Sort
# policy: priority (default), hybrid, oldest") to raw creation-time FIFO.
# Verified live 2026-09-10 against the real WA routed-pool backlog: --sort
# oldest put a priority=2 bead ahead of five priority=1 beads created later
# — a fresh high-priority dispatch (e.g. a P0) could sit behind an older,
# lower-priority backlog indefinitely, while the spawned worker self-claimed
# the wrong bead.
#
# The fix is NOT a plain `--sort priority` swap. The engine's own
# routedReadyTierCommand (internal/config/config.go — renders the gated
# Go-side query, now Step 1b3) deliberately sorts survivors by `updated_at`
# instead of priority (see its ga-w4k2z comment): a repeatedly-reclaimed
# bead's created_at never changes, so ANY static sort key (age OR priority)
# lets that one poisoned bead re-occupy position 0 forever and starve every
# sibling behind it. So the corrected probe line does both: `--sort
# priority` bounds the fetched candidate window by priority (a large
# low-priority backlog can't push a fresh P0 out of the --limit=20 window
# before the jq filters even see it), and the jq tail's compound
# `sort_by([.priority, (.updated_at // .created_at // "")])` re-sorts
# survivors with priority as the dominant key and ga-w4k2z's own
# LRU-by-updated_at as the tiebreak WITHIN each priority tier.
#
# ga-0pg2o (Mayor decision, 2026-09-10): ga-x80j1's fix only ever reached a
# Pilot-spawned (non-ephemeral-origin) session, because the Go-rendered
# query ({{ .RoutedPoolQuery }}) is GATED on GC_SESSION_ORIGIN=ephemeral
# (ga-dbibq) and was consulted FIRST in file order. A genuinely
# ephemeral-origin session still hit that gated, LRU-only query first and
# could still claim an older, lower-priority routed bead ahead of a fresh
# P0/P1 — the exact ga-x80j1 bug, just for a different origin. ga-0pg2o
# reordered both templates so the hardcoded, un-gated, priority-aware probe
# (renumbered "Step 1b2") now runs FIRST for every origin, and the
# Go-rendered query (renumbered "Step 1b3") is consulted only as a fallback
# if Step 1b2 found nothing. Putting priority first for every origin
# reopens the ga-w4k2z starvation risk in a new shape: a single always-failing
# P0/P1 bead with no same-priority sibling would win Step 1b2 on every
# session indefinitely (the updated_at tiebreak only protects a bead from a
# SIBLING at the same priority, not from being sole occupant of its tier).
# ga-0pg2o closes that gap by also excluding any bead at Pilot's reclaim-count
# cap (pilot-dispatcher.sh's own _FILTER_RECLAIM_CAP=3, mirrored here as a
# literal since the two scripts share no runtime state).
#
# This guard runs the ACTUAL jq program extracted from both templates
# against synthetic multi-bead fixtures (not just a text/flag assertion) so
# it catches a reversion to plain age-sort, a naive swap to plain
# priority-sort that drops the anti-starvation tiebreak, or a dropped
# reclaim-cap exclusion:
#   1. priority dominates: a priority=0 bead with an OLDER updated_at must
#      still lose to nothing — i.e. must win over a priority=1 bead with a
#      NEWER updated_at (proves priority beats recency).
#   2. anti-starvation tiebreak: within the SAME priority, a bead whose
#      updated_at was just bumped (simulating a fresh reclaim) must lose to
#      a same-priority sibling that hasn't been touched since creation
#      (proves a poisoned bead can't re-monopolize position 0 forever
#      against a SIBLING).
#   3. the literal reported shape: priority=2/older vs priority=1/newer —
#      the priority=1 bead must win (this is the exact wa-j4bzx repro).
#   4. missing updated_at falls back to created_at without erroring.
#   5. (ga-0pg2o) reclaim-cap exclusion: a priority=0 bead carrying
#      pilot:reclaim-count:3 (at Pilot's cap) must lose to a priority=1
#      sibling with no reclaim-count label — proves a poisoned bead with NO
#      same-priority sibling still cedes its slot once it hits the cap,
#      closing the gap the tiebreak alone (case 2) cannot close.
#   6. (ga-0pg2o) reclaim-count BELOW the cap must NOT be excluded: a
#      priority=0 bead carrying pilot:reclaim-count:2 must still win over a
#      priority=1 bead — proves the exclusion threshold is exactly ">=3",
#      not an overbroad "any reclaim-count label at all".
#   7. (ga-0pg2o gate-fix round 2, 2026-09-11) Step 1b3's fallback inherits
#      the SAME reclaim-cap exclusion, not just Step 1b2: round 1 excluded a
#      capped bead from Step 1b2 only, so when that bead is the sole
#      occupant of its priority tier, Step 1b2 correctly returns [] and the
#      Go-rendered fallback — which has zero reclaim-count awareness — used
#      to re-surface that SAME bead. Tested as a standalone post-filter (see
#      assert_fallback_result) rather than end-to-end, for the same reason
#      the structural check below is text-based: the Go-rendered query
#      itself is opaque to a pack-level selftest.
#
# A separate, non-jq structural check (test b from the ga-0pg2o bead: "a
# session of ephemeral origin chooses by priority") verifies the ORDERING
# ga-0pg2o's fix actually depends on: the hardcoded probe line must appear
# BEFORE the (real, uncommented) {{ .RoutedPoolQuery }} line in the
# template text. The Go-side gating on GC_SESSION_ORIGIN=ephemeral lives
# entirely inside the rendered template variable and is opaque to a
# pack-level selftest — but since a genuinely ephemeral-origin session is
# the ONLY origin for which that gated query ever produces real output,
# proving this probe precedes it in file order is exactly what guarantees
# an ephemeral-origin session's FIRST real routed-pool result comes from
# the priority-aware probe, not the LRU-only Go path.
#
# ga-9t9acg.5 + ga-9t9acg.6 (2026-10-07): a worker's ORDER moves out of the probe's jq into the shared library
# (scripts/work-order.sh: priority > feature-before-the-rest > oldest first, age = `reclaim`), so the cases
# 1-6b above are no longer run on an extracted jq program for a worker that has moved: the ps-worker (.6)
# and the wa-worker (.5; until that slice lands the wa-worker keeps run_case, and run_case has no caller
# once both are in). They are run END TO END
# (run_case_lib): the whole Step 1b2 block is extracted from the tracked prompt and executed against a fake
# `bd`, together with the cases the new rule adds — a newer P0 feature beats an older P0 bug; a bead reclaimed
# twice sinks behind a newer feature of its class (and does NOT sink without the label); the oldest P0 feature
# at position 25 of the pool is the one chosen (the old `--limit=20` window cut it off); the fetch is
# `--limit 0`; ages compare as epoch, not as text; an unreadable field is kept at the end with its WARN on
# stderr; a missing or "cannot tell" library falls back to the PREVIOUS order with a visible WARN (never `[]`);
# an empty pool prints `[]` and a failed query does not. Six textual MUTANTS of the block must each be caught by
# the scenario named for them.
#
# Exit 0 iff every scenario, for both files, behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

# extract_priority_probe_jq <template-file> — pulls the jq PROGRAM (the
# single-quoted argument to `jq --argjson now_ts "$(date +%s)"`) out of the
# hardcoded routed-pool probe line (Step 1b2 as of ga-0pg2o; was "Step 1b3"
# before that reorder — this extractor keys off the command shape, not the
# step number, so renumbering alone does not require touching it). Same
# technique as pool-probe-text-veto-family.selftest.sh's extractor,
# duplicated (not sourced) so this guard fails loudly on its own if the line
# shape changes, rather than silently inheriting a broken extractor.
extract_priority_probe_jq() {
  local tpl="$1"
  local line
  line="$(grep -F '| jq --argjson now_ts "$(date +%s)" ' "$tpl" | grep -F 'bd ready --metadata-field "gc.routed_to=' | head -1)"
  if [ -z "$line" ]; then
    return 1
  fi
  local marker
  marker='| jq --argjson now_ts "$(date +%s)" '"'"
  local after="${line#*$marker}"
  if [ "$after" = "$line" ]; then
    return 1
  fi
  local prog="${after%\'}"
  if [ -z "$prog" ] || [ "$prog" = "$after" ]; then
    return 1
  fi
  printf '%s' "$prog"
}

# extract_fallback_postfilter_jq <template-file> — pulls the jq PROGRAM out
# of the Step 1b3 post-filter added by ga-0pg2o's gate-fix round 2: the
# `{{ .RoutedPoolQuery }} | jq -c '...'` line that re-applies the
# reclaim-cap exclusion to the Go-rendered fallback's own output. Same
# extraction technique as extract_priority_probe_jq above (key off the exact
# line shape, fail loudly if it changes) — deliberately a SEPARATE function
# rather than a shared helper, since the two lines have different anchors
# and mirroring extract_priority_probe_jq's own "duplicated, not shared"
# choice (see its comment) keeps each guard independently diagnosable.
extract_fallback_postfilter_jq() {
  local tpl="$1"
  local line
  line="$(grep -F '{{ .RoutedPoolQuery }} | jq -c ' "$tpl" | head -1)"
  if [ -z "$line" ]; then
    return 1
  fi
  local marker
  marker='{{ .RoutedPoolQuery }} | jq -c '"'"
  local after="${line#*$marker}"
  if [ "$after" = "$line" ]; then
    return 1
  fi
  local prog="${after%\'}"
  if [ -z "$prog" ] || [ "$prog" = "$after" ]; then
    return 1
  fi
  printf '%s' "$prog"
}

# assert_winner <label> <jq-program> <fixture-array-json> <expected-id>
# Feeds the WHOLE fixture array through the real probe's filter+sort chain
# (which itself ends in .[:1]) and checks the single survivor's id.
assert_winner() {
  local label="$1" prog="$2" fixture="$3" expected="$4"
  local out rc got_id
  out="$(printf '%s' "$fixture" | jq -c --argjson now_ts "$(date +%s)" "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed: $out"
    return
  fi
  got_id="$(printf '%s' "$out" | jq -r '.[0].id // "EMPTY"' 2>/dev/null)"
  if [ "$got_id" = "$expected" ]; then
    ok "$label: winner is $expected as expected"
  else
    bad "$label: expected winner $expected, got $got_id (full output: $out)"
  fi
}

# assert_fallback_result <label> <jq-program> <fixture-array-json> <expected-array-json>
# Unlike assert_winner (which picks a single winner out of several
# candidates), the Step 1b3 post-filter preserves array shape straight
# through — it receives the Go-rendered query's own already-.[0:1]-sliced
# output (0 or 1 items) and either keeps or drops that one item. So this
# compares the WHOLE compacted array rather than pulling out a single .id;
# no --argjson now_ts is passed since this post-filter clause (copied
# verbatim from Step 1b2) references no $now_ts.
assert_fallback_result() {
  local label="$1" prog="$2" fixture="$3" expected="$4"
  local out rc exp_norm
  out="$(printf '%s' "$fixture" | jq -c "$prog" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$label: jq program failed: $out"
    return
  fi
  exp_norm="$(printf '%s' "$expected" | jq -c '.' 2>/dev/null)"
  if [ "$out" = "$exp_norm" ]; then
    ok "$label: output matches expected ($exp_norm)"
  else
    bad "$label: expected $exp_norm, got $out"
  fi
}

# assert_probe_before_fallback <label> <template-file>
# Structural check for ga-0pg2o requirement #1 / reported test (b): the
# un-gated priority probe must appear BEFORE the Go-rendered fallback query
# ({{ .RoutedPoolQuery }}, real directive only — not a comment merely
# mentioning it by name) in the template text, so every session origin,
# including a genuinely ephemeral one, reaches the priority-aware probe
# first. A regression that moves {{ .RoutedPoolQuery }} back ahead of the
# hardcoded bd-ready line would silently revert the fix for ephemeral-origin
# sessions specifically, while a Pilot-spawned session (which never gets
# real output from the gated query regardless of position) would look
# completely unaffected — exactly the kind of regression a jq-fixture-only
# test cannot see, since both probes' jq logic would remain individually
# correct.
assert_probe_before_fallback() {
  local label="$1" tpl="$2"
  local probe_line fallback_line
  probe_line="$(grep -n -F 'bd ready --metadata-field "gc.routed_to=' "$tpl" | grep -F '| jq --argjson now_ts "$(date +%s)" ' | head -1 | cut -d: -f1)"
  fallback_line="$(grep -n -F '{{ .RoutedPoolQuery }}' "$tpl" | grep -v '^[0-9]*:#' | tail -1 | cut -d: -f1)"
  if [ -z "$probe_line" ]; then
    bad "$label: could not locate the hardcoded priority-probe line"
    return
  fi
  if [ -z "$fallback_line" ]; then
    bad "$label: could not locate an uncommented {{ .RoutedPoolQuery }} line"
    return
  fi
  if [ "$probe_line" -lt "$fallback_line" ]; then
    ok "$label: priority probe (line $probe_line) precedes Go-rendered fallback (line $fallback_line)"
  else
    bad "$label: priority probe (line $probe_line) does NOT precede Go-rendered fallback (line $fallback_line) — an ephemeral-origin session would hit the LRU-only Go query first, reopening ga-0pg2o"
  fi
}

run_case() {
  local label="$1" tpl="$2"
  if [ ! -f "$tpl" ]; then
    bad "$label: template not found at $tpl"
    return
  fi
  local prog
  if ! prog="$(extract_priority_probe_jq "$tpl")"; then
    bad "$label: could not extract priority-probe jq program from $tpl (line shape changed?)"
    return
  fi

  # 1. priority dominates recency: p0/old-touch must beat p1/new-touch.
  assert_winner "$label priority-dominates" "$prog" \
    '[{"id":"p0-old-touch","priority":0,"updated_at":"2026-01-01T00:00:00Z"},{"id":"p1-new-touch","priority":1,"updated_at":"2026-09-10T22:00:00Z"}]' \
    "p0-old-touch"

  # 2. anti-starvation tiebreak: same priority, the just-reclaimed (recently
  # touched) bead must lose to the untouched sibling — mirrors ga-w4k2z.
  assert_winner "$label anti-starvation-tiebreak" "$prog" \
    '[{"id":"just-reclaimed","priority":1,"updated_at":"2026-09-10T22:00:00Z"},{"id":"never-touched","priority":1,"updated_at":"2026-01-01T00:00:00Z"}]' \
    "never-touched"

  # 3. literal reported shape: priority=2/older vs priority=1/newer — the
  # priority=1 bead must win (the exact wa-j4bzx-vs-wa-qjjj6 repro).
  assert_winner "$label literal-repro" "$prog" \
    '[{"id":"wa-j4bzx-like","priority":2,"created_at":"2026-09-10T17:35:12Z","updated_at":"2026-09-10T17:35:12Z"},{"id":"wa-qjjj6-like","priority":1,"created_at":"2026-09-10T19:49:21Z","updated_at":"2026-09-10T19:49:21Z"}]' \
    "wa-qjjj6-like"

  # 4. missing updated_at falls back to created_at without erroring.
  assert_winner "$label updated-at-fallback" "$prog" \
    '[{"id":"no-updated-at","priority":1,"created_at":"2026-01-01T00:00:00Z"},{"id":"has-updated-at","priority":1,"updated_at":"2026-09-10T22:00:00Z","created_at":"2026-01-01T00:00:00Z"}]' \
    "no-updated-at"

  # 5. (ga-0pg2o, reported test a) reclaim-cap exclusion: a P0 bead AT the
  # cap (reclaim-count:3) has no same-priority sibling to lose a tiebreak
  # to, so without this exclusion it would monopolize position 0 forever.
  # The following P1 (no reclaim-count) must win instead.
  assert_winner "$label reclaim-cap-excludes-p0" "$prog" \
    '[{"id":"poisoned-p0-at-cap","priority":0,"updated_at":"2026-01-01T00:00:00Z","labels":["pilot:reclaim-count:3"]},{"id":"clean-p1","priority":1,"updated_at":"2026-09-10T22:00:00Z","labels":[]}]' \
    "clean-p1"

  # 6. (ga-0pg2o) reclaim-count BELOW the cap must NOT be excluded — proves
  # the threshold is exactly ">=3", not "any reclaim-count label at all".
  assert_winner "$label reclaim-count-below-cap-still-wins" "$prog" \
    '[{"id":"reclaimed-p0-below-cap","priority":0,"updated_at":"2026-01-01T00:00:00Z","labels":["pilot:reclaim-count:2"]},{"id":"clean-p1","priority":1,"updated_at":"2026-09-10T22:00:00Z","labels":[]}]' \
    "reclaimed-p0-below-cap"

  # 6a. (ga-oc6knj) the core reported defect: a NEVER-reclaimed bead (no
  # pilot:reclaim-count label at all) whose updated_at was JUST bumped by
  # the Pilot's own dispatch write must still win the tiebreak against a
  # same-priority sibling that was routed earlier but hasn't been re-touched
  # since — because on created_at (which the dispatch write never touches)
  # it genuinely has been waiting longer. Literal shape of the live
  # wa-aaekc/wa-yzx9g repro (transcript 0bc29f56, 17/09): the just-dispatched
  # bead's updated_at (01:40:55Z) is LATER than the other bead's (23:38:41Z
  # the previous day) even though its created_at is EARLIER — pre-fix, plain
  # updated_at sorting picked the wrong winner here.
  assert_winner "$label ga-oc6knj-first-dispatch-not-penalized" "$prog" \
    '[{"id":"older-just-dispatched","priority":2,"created_at":"2026-09-16T23:38:41Z","updated_at":"2026-09-17T01:40:55Z","labels":[]},{"id":"newer-waiting","priority":2,"created_at":"2026-09-17T00:00:00Z","updated_at":"2026-09-16T23:38:41Z","labels":[]}]' \
    "older-just-dispatched"

  # 6b. (ga-oc6knj) ga-w4k2z's anti-poison property, re-proven with a REAL
  # pilot:reclaim-count label this time (test 2 above exercises the same
  # shape incidentally, via the created_at-and-updated_at-both-absent
  # fallback, not because either fixture actually carries reclaim history —
  # this case makes the GENUINELY-reclaimed branch of the compound key
  # itself the thing under test): two same-priority beads that have BOTH
  # already been reclaimed once — the one reclaimed AGAIN just now (updated_at
  # bumped) must still lose to the sibling that has been idle since ITS OWN
  # earlier reclaim. Proves the fix does not regress ga-w4k2z for a bead that
  # actually IS repeatedly failing, only for a bead's first-ever dispatch.
  assert_winner "$label ga-oc6knj-real-reclaim-still-anti-poison" "$prog" \
    '[{"id":"just-reclaimed-again","priority":1,"updated_at":"2026-09-17T01:40:55Z","labels":["pilot:reclaim-count:1"]},{"id":"reclaimed-earlier-idle-since","priority":1,"updated_at":"2026-09-16T20:00:00Z","labels":["pilot:reclaim-count:1"]}]' \
    "reclaimed-earlier-idle-since"

  run_step1b3_and_structure_cases "$label" "$tpl"
}

# run_step1b3_and_structure_cases <label> <template> — the Step 1b3 post-filter cases (7-9) and the file-order
# check. Split out of run_case by ga-9t9acg.5 UNCHANGED, so a worker whose ORDER is tested end to end
# (run_case_lib below: the ps-worker, and the wa-worker once ga-9t9acg.5 lands) still gets exactly these two checks;
# a worker still on run_case gets them through it.
run_step1b3_and_structure_cases() {
  local label="$1" tpl="$2"

  # 7-9. (ga-0pg2o gate-fix round 2) Step 1b3's fallback post-filter must
  # apply the SAME reclaim-cap exclusion as Step 1b2 — GATE-FEEDBACK on
  # round 1 named the reopened gap: a capped bead that is the sole occupant
  # of its priority tier makes Step 1b2 correctly return [], and the
  # Go-rendered fallback (zero reclaim-count awareness on its own) used to
  # hand that SAME bead back unfiltered.
  local fallback_prog
  if ! fallback_prog="$(extract_fallback_postfilter_jq "$tpl")"; then
    bad "$label: could not extract Step 1b3 post-filter jq program from $tpl (line shape changed?)"
  else
    # 7. simulates the Go-rendered query handing back its one real result
    # (routedReadyTierCommand's own contract: 0 or 1 items) when that result
    # is at the cap — the post-filter must drop it to [].
    assert_fallback_result "$label fallback-drops-capped-bead" "$fallback_prog" \
      '[{"id":"poisoned-p0-at-cap","labels":["pilot:reclaim-count:3"]}]' \
      '[]'

    # 8. below-cap passthrough — same ">=3" threshold as Step 1b2's own case
    # 6; the post-filter must not eat a legitimate fallback result.
    assert_fallback_result "$label fallback-keeps-clean-bead" "$fallback_prog" \
      '[{"id":"clean-fallback-bead","labels":["pilot:reclaim-count:2"]}]' \
      '[{"id":"clean-fallback-bead","labels":["pilot:reclaim-count:2"]}]'

    # 9. a genuinely empty fallback result ([]) must stay [] without erroring.
    assert_fallback_result "$label fallback-empty-stays-empty" "$fallback_prog" \
      '[]' \
      '[]'
  fi

  # (ga-0pg2o, reported test b) structural: the priority probe must precede
  # the Go-rendered fallback in file order — see assert_probe_before_fallback
  # for why this is what "an ephemeral-origin session chooses by priority"
  # actually reduces to at the pack-level (non-Go-rendered) file.
  assert_probe_before_fallback "$label" "$tpl"
}

# ── ga-9t9acg.5/.6: a worker probe (wa-worker, ps-worker) runs the SHARED order library, so its order is tested END TO END ──
# Until its slice the order lived INSIDE the single jq program of the probe line, so run_case could pull the program
# out and feed it a fixture. Now the order comes from scripts/work-order.sh (work_order_sort --age reclaim) and the
# line only filters; testing the extracted program would test nothing about the order. So the whole Step 1b2 BLOCK is
# extracted from the tracked prompt exactly as a worker pastes it, and RUN, with a fake `bd` on PATH that behaves like
# `bd ready --json` (default priority order, cut to --limit, 0 = everything) over a fixture. That exercises what ships:
# the filters and vetoes, the fetch window, the library, the stderr, and the fallback when the library is missing or
# cannot tell — and it makes the new cases below fail on the pre-change prompt (a --limit=20 window, no feature tier,
# no WARN) instead of passing on a technicality.
# Each scenario is a function returning 0/1 (WHY says what was seen) so the SAME scenarios also run against textual
# mutants of the block: a mutant the scenarios do not catch means the scenario proves nothing.

WORK=""
cleanup_work() { if [ -n "$WORK" ] && command -v safe-clean >/dev/null 2>&1 && safe-clean --check "$WORK" >/dev/null 2>&1; then safe-clean "$WORK" >/dev/null 2>&1; fi; }

# extract_step1b2_block <template> — the CODE of Step 1b2: from the first non-comment line after the "# Step 1b2"
# header comment up to (not including) the "# If it returns a bead" claim note. Keyed on those two anchors, not on a
# line number, so it reads the pre-change prompt (one line) and the post-change one (a block) alike.
extract_step1b2_block() {
  awk '
    /^# Step 1b2/ { seen = 1; next }
    seen && /^# If it returns a bead/ { exit }
    seen && !started && (/^#/ || /^$/) { next }
    seen { started = 1; print }
  ' "$1"
}

# The fake bd. `bd ready ... --json [--limit N | --limit=N | -n N]`: $WA_FIXTURE (a JSON array) in bd's default order
# (priority ascending, stable), cut to N (default 100, like bd; 0 = the whole population). Its argv goes to
# $FAKE_BD_ARGV so a scenario can assert the window; FAKE_BD_FAIL=1 makes it fail like a down store.
make_fake_bd() {
  cat > "$1/bd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_BD_ARGV:-/dev/null}"
if [ -n "${FAKE_BD_FAIL:-}" ]; then echo "bd: simulated failure" >&2; exit 1; fi
lim=100
while [ $# -gt 0 ]; do
  case "$1" in
    --limit=*) lim="${1#--limit=}" ;;
    --limit|-n) shift; lim="${1:-100}" ;;
  esac
  shift
done
jq -c --argjson n "$lim" 'sort_by(.priority // 99) | if $n == 0 then . else .[:$n] end' "$WA_FIXTURE"
SH
  chmod +x "$1/bd"
}

# mk <id> <priority-json> <type> <created_at> <updated_at> [label...] — one bead the way bd prints it.
mk() { jq -cn --arg id "$1" --argjson p "$2" --arg t "$3" --arg c "$4" --arg u "$5" \
  '$ARGS.positional as $l | {id: $id, priority: $p, issue_type: $t, created_at: $c, updated_at: $u, labels: $l}' --args "${@:6}"; }
arr() { printf '%s\n' "$@" | jq -cs '.'; }

# run_block <block-file> <fixture-json> [city-dir] [fail] — runs the block like a worker would. Sets OUT, ERR, ARGV.
run_block() {
  local blk="$1" fx="$2" city="${3:-$CITY_ROOT}" fail="${4:-}"
  printf '%s' "$fx" > "$WORK/fixture.json"
  : > "$WORK/argv"
  OUT="$(PATH="$WORK/bin:$PATH" WA_FIXTURE="$WORK/fixture.json" FAKE_BD_ARGV="$WORK/argv" FAKE_BD_FAIL="$fail" \
         GC_CITY_PATH="$city" GC_CITY="$city" bash "$blk" 2>"$WORK/err")"
  ERR="$(cat "$WORK/err")"
  ARGV="$(cat "$WORK/argv")"
}
WHY=""
want_winner() { # <id> — the first bead printed is <id>
  local got
  got="$(printf '%s' "$OUT" | jq -r '.[0].id // "EMPTY"' 2>/dev/null)"
  if [ "$got" = "$1" ]; then return 0; fi
  WHY="expected winner $1, got '${got:-<nothing>}' (stdout: ${OUT:0:160})"
  return 1
}
want_err() { # <fixed string> — stderr carries it (the WARN lines are the only signal: they must reach the worker)
  case "$ERR" in *"$1"*) return 0 ;; esac
  WHY="stderr lacks '$1' (stderr: ${ERR:0:300})"
  return 1
}

# The scenarios. $1 = the block file under test.
sc_priority_dominates() {
  run_block "$1" "$(arr "$(mk p0-old-touch 0 task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)" "$(mk p1-new-touch 1 task 2026-09-01T00:00:00Z 2026-09-10T22:00:00Z)")"
  want_winner p0-old-touch
}
sc_reclaim_sinks_within_priority() { # ga-w4k2z: the bead reclaimed again just now loses to an untouched sibling
  run_block "$1" "$(arr "$(mk just-reclaimed 1 task 2026-01-01T00:00:00Z 2026-09-10T22:00:00Z pilot:reclaim-count:1)" "$(mk never-touched 1 task 2026-02-01T00:00:00Z 2026-02-01T00:00:00Z)")"
  want_winner never-touched
}
sc_literal_repro() { # wa-j4bzx (P2, older) vs wa-qjjj6 (P1, newer): the P1 wins
  run_block "$1" "$(arr "$(mk wa-j4bzx-like 2 task 2026-09-10T17:35:12Z 2026-09-10T17:35:12Z)" "$(mk wa-qjjj6-like 1 task 2026-09-10T19:49:21Z 2026-09-10T19:49:21Z)")"
  want_winner wa-qjjj6-like
}
sc_reclaim_cap_excludes() { # ga-0pg2o: a P0 at pilot:reclaim-count:3 is not offered, even alone in its tier
  run_block "$1" "$(arr "$(mk poisoned-p0-at-cap 0 task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z pilot:reclaim-count:3)" "$(mk clean-p1 1 task 2026-09-01T00:00:00Z 2026-09-10T22:00:00Z)")"
  want_winner clean-p1
}
sc_below_cap_still_wins() { # the cap is exactly >= 3
  run_block "$1" "$(arr "$(mk reclaimed-p0-below-cap 0 task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z pilot:reclaim-count:2)" "$(mk clean-p1 1 task 2026-09-01T00:00:00Z 2026-09-10T22:00:00Z)")"
  want_winner reclaimed-p0-below-cap
}
sc_first_dispatch_not_penalized() { # ga-oc6knj: the Pilot's own dispatch write (updated_at) must not sink a never-reclaimed bead
  run_block "$1" "$(arr "$(mk older-just-dispatched 2 task 2026-09-16T23:38:41Z 2026-09-17T01:40:55Z)" "$(mk newer-waiting 2 task 2026-09-17T00:00:00Z 2026-09-16T23:38:41Z)")"
  want_winner older-just-dispatched
}
sc_real_reclaim_anti_poison() { # ga-oc6knj/ga-w4k2z with REAL reclaim labels on both
  run_block "$1" "$(arr "$(mk just-reclaimed-again 1 task 2026-09-01T00:00:00Z 2026-09-17T01:40:55Z pilot:reclaim-count:1)" "$(mk reclaimed-earlier-idle-since 1 task 2026-09-01T00:00:00Z 2026-09-16T20:00:00Z pilot:reclaim-count:1)")"
  want_winner reclaimed-earlier-idle-since
}
sc_feature_beats_older_bug() { # the Athos rule: inside a priority, feature first — a NEWER P0 feature beats an OLDER P0 bug
  run_block "$1" "$(arr "$(mk old-p0-bug 0 bug 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)" "$(mk new-p0-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")"
  want_winner new-p0-feature
}
sc_reclaimed_x2_sinks_behind_newer_feature() { # the inherited anti-starvation, inside one class: reclaimed twice -> aged by updated_at
  run_block "$1" "$(arr "$(mk reclaimed-feature 0 feature 2026-01-01T00:00:00Z 2026-09-20T00:00:00Z pilot:reclaim-count:2)" "$(mk fresh-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")"
  want_winner fresh-feature
}
sc_older_feature_wins_without_the_label() { # the control of the one above: the LABEL is what sinks it, not the dates
  run_block "$1" "$(arr "$(mk reclaimed-feature 0 feature 2026-01-01T00:00:00Z 2026-09-20T00:00:00Z)" "$(mk fresh-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")"
  want_winner reclaimed-feature
}
sc_whole_pool_oldest_p0_feature_at_25() { # ga-g7yt: 24 newer P0 features come first in bd's order; the OLDEST is the 25th — outside a window of 20
  run_block "$1" "$(jq -cn '[range(1; 25) as $i | ("0" + ($i | tostring))[-2:] as $d
      | {id: ("f" + $d), priority: 0, issue_type: "feature", created_at: ("2026-03-" + $d + "T00:00:00Z"), updated_at: ("2026-03-" + $d + "T00:00:00Z"), labels: []}]
      + [{id: "oldest-p0-feature", priority: 0, issue_type: "feature", created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z", labels: []}]')"
  want_winner oldest-p0-feature
}
sc_fetch_is_the_whole_pool() { # the query asks for everything: --limit 0, never --limit=N before the order is applied
  run_block "$1" "$(arr "$(mk only 1 task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)")"
  case "$ARGV" in *"--limit 0"*) ;; *) WHY="bd was not asked for --limit 0 (argv: ${ARGV:0:200})"; return 1 ;; esac
  case "$ARGV" in *"--limit="*) WHY="bd was asked for a --limit=N window (argv: ${ARGV:0:200})"; return 1 ;; esac
  return 0
}
sc_age_is_epoch_not_string() { # same second, two spellings: "…:05.123Z" and "…:05+00:00" tie by epoch, so the id decides (a-frac); as text '+' < '.' would put b-plus first
  run_block "$1" "$(arr "$(mk b-plus 1 task 2026-01-01T00:00:05+00:00 2026-01-01T00:00:05+00:00)" "$(mk a-frac 1 task 2026-01-01T00:00:05.123Z 2026-01-01T00:00:05.123Z)")"
  want_winner a-frac
}
sc_illegible_is_kept_at_the_end_with_a_warn() { # the three states: a bead with an unreadable priority is NOT promoted, NOT dropped, and the library's WARN reaches the worker
  run_block "$1" "$(arr "$(mk bad-prio '"high"' task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)" "$(mk ok-p3 3 task 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")"
  want_winner ok-p3 || return 1
  want_err "work-order WARN: bad-prio" || return 1
  run_block "$1" "$(arr "$(mk bad-prio '"high"' task 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)")"
  want_winner bad-prio
}
# The two fallbacks. The pool is chosen so the OLD order (priority, then age; no feature tier) and the library's order
# DISAGREE: the old order serves old-p0-bug, the library new-p0-feature. So "which one came back" says which path ran.
FALLBACK_POOL_BUG="old-p0-bug"
sc_lib_missing_falls_back_and_warns() {
  mkdir -p "$WORK/nolib-city"
  run_block "$1" "$(arr "$(mk old-p0-bug 0 bug 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)" "$(mk new-p0-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")" "$WORK/nolib-city"
  want_winner "$FALLBACK_POOL_BUG" || return 1       # a bead came back — never [] / nothing — and it is the pre-migration order's
  want_err "WARN Step 1b2" || return 1               # ... and the worker was told which path it was on
}
sc_lib_cannot_tell_falls_back_and_shows_why() {
  mkdir -p "$WORK/stub-city/packs/town-deltas/assets/scripts"
  printf '%s\n' 'work_order_sort() { cat >/dev/null; echo "work-order ERROR: stub: cannot tell" >&2; return 2; }' > "$WORK/stub-city/packs/town-deltas/assets/scripts/work-order.sh"
  run_block "$1" "$(arr "$(mk old-p0-bug 0 bug 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)" "$(mk new-p0-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)")" "$WORK/stub-city"
  want_winner "$FALLBACK_POOL_BUG" || return 1
  want_err "WARN Step 1b2" || return 1
  want_err "work-order ERROR: stub: cannot tell" || return 1   # the library's own line is kept, not swallowed
}
sc_an_empty_pool_is_an_empty_list() { # genuinely nothing to do: [] and NO warning (the WARN must mean something)
  run_block "$1" "[]"
  if [ "$OUT" != "[]" ]; then WHY="an empty pool should print [], got '${OUT:0:120}'"; return 1; fi
  case "$ERR" in *"WARN Step 1b2"*) WHY="an empty pool must not WARN (stderr: ${ERR:0:200})"; return 1 ;; esac
  return 0
}
sc_a_failed_query_is_not_an_empty_list() { # bd down: NOT [] (a worker that reads [] drains) and a WARN that says so
  run_block "$1" "[]" "$CITY_ROOT" 1
  if [ "$OUT" = "[]" ]; then WHY="a failed bd query printed [] — it reads as 'no work'"; return 1; fi
  want_err "WARN Step 1b2" || return 1
  want_err "NOT 'queue empty'" || return 1
}
sc_probe_agrees_with_the_library_head() { # one order for the whole city: the probe's pick IS what the top-up (R4) takes off the same pool
  # The pool: a P0 bug that is the OLDEST, a P0 feature reclaimed twice (aged by updated_at), a P0 feature that is simply
  # newer than the old bug, a P1 feature, and a P0 feature at the reclaim cap (the probe's veto drops it: the top-up's
  # own query drops it too, so it is NOT in the population the two are compared on).
  local old_bug rec_feat new_feat p1_feat capped pool lib_head lib_dir="${CITY_ROOT}/packs/town-deltas/assets/scripts"
  old_bug="$(mk old-p0-bug 0 bug 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)"
  rec_feat="$(mk reclaimed-p0-feature 0 feature 2026-02-01T00:00:00Z 2026-09-20T00:00:00Z pilot:reclaim-count:2)"
  new_feat="$(mk new-p0-feature 0 feature 2026-09-01T00:00:00Z 2026-09-01T00:00:00Z)"
  p1_feat="$(mk old-p1-feature 1 feature 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z)"
  capped="$(mk capped-p0-feature 0 feature 2025-12-01T00:00:00Z 2025-12-01T00:00:00Z pilot:reclaim-count:3)"
  run_block "$1" "$(arr "$old_bug" "$rec_feat" "$new_feat" "$p1_feat" "$capped")"
  pool="$(arr "$old_bug" "$rec_feat" "$new_feat" "$p1_feat")"
  # The top-up's view: the library applied to that population, taking the head — exactly how R4 picks its bead.
  lib_head="$( . "$lib_dir/work-order.sh" && printf '%s' "$pool" | work_order_sort --age reclaim 2>/dev/null | work_order_head 2>/dev/null | jq -r '.id // "EMPTY"' )"
  if [ "$lib_head" != "new-p0-feature" ]; then WHY="the library's own head over the pool is '$lib_head', not new-p0-feature — the fixture no longer says what this scenario thinks it says"; return 1; fi
  want_winner "$lib_head" || { WHY="probe and top-up disagree: the library's head is $lib_head; $WHY"; return 1; }
}
WA_SCENARIOS="priority_dominates reclaim_sinks_within_priority literal_repro reclaim_cap_excludes below_cap_still_wins
  first_dispatch_not_penalized real_reclaim_anti_poison feature_beats_older_bug reclaimed_x2_sinks_behind_newer_feature
  older_feature_wins_without_the_label whole_pool_oldest_p0_feature_at_25 fetch_is_the_whole_pool age_is_epoch_not_string
  illegible_is_kept_at_the_end_with_a_warn lib_missing_falls_back_and_warns lib_cannot_tell_falls_back_and_shows_why
  an_empty_pool_is_an_empty_list a_failed_query_is_not_an_empty_list probe_agrees_with_the_library_head"

# mutate_block <block-in> <block-out> <old> <new> — an EXACT-ONCE textual mutation; a target that is not there exactly
# once is an error (rc 3), never a silent no-op that would "pass" a mutation control.
mutate_block() {
  python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if text.count(old) != 1:
    sys.stderr.write("mutation target occurs %d times (want 1): %r\n" % (text.count(old), old)); sys.exit(3)
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

# run_case_lib <label> <template> [prefix] — a worker's probe, end to end (the ps-worker here; the wa-worker when
# ga-9t9acg.5 lands). <prefix> is the shell-variable prefix the template's Step 1b2 block uses (WA_ for wa-worker, PS_ for
# ps-worker; default WA): only the two mutants that rewrite the block's own variable names need it.
run_case_lib() {
  local label="$1" tpl="$2" pfx="${3:-WA}" name blk
  if [ ! -f "$tpl" ]; then bad "$label: template not found at $tpl"; return; fi
  if [ ! -r "$CITY_ROOT/packs/town-deltas/assets/scripts/work-order.sh" ]; then bad "$label: the shared library is not at $CITY_ROOT/packs/town-deltas/assets/scripts/work-order.sh"; return; fi
  blk="$WORK/$(basename "$(dirname "$tpl")").block.sh"
  extract_step1b2_block "$tpl" > "$blk"
  if [ ! -s "$blk" ]; then bad "$label: could not extract the Step 1b2 block from $tpl (header/claim-note anchors changed?)"; return; fi
  if ! bash -n "$blk" 2>"$WORK/syntax"; then bad "$label: the Step 1b2 block does not parse: $(cat "$WORK/syntax")"; return; fi
  # the sibling selftests (next-action, delivery-pending-restart, text-veto, pilot-dispatched, vetoes) read the filter
  # program off the probe LINE: if that line shape goes, they go silently blind — so it is asserted here, once.
  if extract_priority_probe_jq "$tpl" >/dev/null; then ok "$label: the probe line the sibling selftests extract is still there"; else bad "$label: the probe line shape the sibling selftests extract is gone"; fi
  for name in $WA_SCENARIOS; do
    WHY=""
    if "sc_$name" "$blk"; then ok "$label $name"; else bad "$label $name: $WHY"; fi
  done
  run_step1b3_and_structure_cases "$label" "$tpl"

  # Mutation controls: each mutant of the block must be CAUGHT by the scenario named for it (the scenario fails on it).
  local mut_n=0
  mutation_control() { # <name> <caught-by scenario> <old> <new>
    local mname="$1" scen="$2" old="$3" new="$4" mblk
    mut_n=$((mut_n + 1))
    mblk="$WORK/mutant.$mut_n.sh"
    if ! mutate_block "$blk" "$mblk" "$old" "$new" 2>"$WORK/mut-err"; then bad "$label mutant $mname: could not be built: $(cat "$WORK/mut-err")"; return; fi
    if ! bash -n "$mblk" 2>/dev/null; then bad "$label mutant $mname: does not parse (a syntax error would 'catch' anything)"; return; fi
    WHY=""
    if "sc_$scen" "$mblk"; then bad "$label mutant $mname SURVIVED $scen — that scenario does not guard what it claims"; else ok "$label mutant $mname is caught by $scen"; fi
  }
  mutation_control "age-created (drops the reclaim age)"            reclaimed_x2_sinks_behind_newer_feature 'work_order_sort --age reclaim' 'work_order_sort --age created'
  mutation_control "window of 20 comes back"                        whole_pool_oldest_p0_feature_at_25      '--limit 0' '--limit=20'
  mutation_control "probe ages by created, the top-up by reclaim"   probe_agrees_with_the_library_head     'work_order_sort --age reclaim' 'work_order_sort --age created'
  mutation_control "no sort at all (bd's own order)"                feature_beats_older_bug                 'work_order_sort --age reclaim' 'cat'
  mutation_control "the library's stderr is swallowed"              illegible_is_kept_at_the_end_with_a_warn 'work_order_sort --age reclaim )' 'work_order_sort --age reclaim 2>/dev/null )'
  mutation_control "no fallback: a missing library answers nothing" lib_missing_falls_back_and_warns        "if [ -z \"\$${pfx}_PICK\" ]; then" 'if false; then'
  mutation_control "a silent fallback (no WARN)"                    lib_missing_falls_back_and_warns        "WARN Step 1b2: \$${pfx}_LIB is missing" "note: \$${pfx}_LIB is missing"
}

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not available"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-priority-sort.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap cleanup_work EXIT
mkdir -p "$WORK/bin"
make_fake_bd "$WORK/bin"

run_case "wa-worker Step 1b2" "$CITY_ROOT/agents/wa-worker/prompt.template.md"   # -> run_case_lib ... WA when ga-9t9acg.5 lands
run_case_lib "ps-worker Step 1b2" "$CITY_ROOT/agents/ps-worker/prompt.template.md" PS

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
