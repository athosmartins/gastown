#!/usr/bin/env bash
# beads-upstream-pr-watchdog.sh — durable watcher for our own upstream PRs
# against gastownhall/beads (the beads CLI's own repo — not a registered gc
# rig, so nothing in the normal gate/dispatch machinery watches it; fixes
# there ship via fork+PR+human-review only).
#
# ga-574zr: the only thing that had EVER polled PR #5439 for review activity
# was an ACCIDENT — a dog's Step 1a resume hook kept re-finding an in_progress
# bead and re-checking it as a side effect of retrying its own dispatch. This
# script (v1) was the deliberate replacement, built around a hand-maintained
# PR_BEAD_MAP.
#
# ga-se0ly (v2, this rewrite): the v1 map was a NEW instance of the same
# disease it was built to cure. Measured 2026-08-31: 4 of 6 open PRs had NO
# entry in PR_BEAD_MAP (never added — "add a line here" was a step nobody
# remembered), and one entry (#5439 -> wa-msxg5 only) missed that ga-5ksp5
# ALSO depended on the same PR and so never got its own merge notification —
# a static map can only ever alert the bead(s) someone remembered to write
# in, in either direction (new PR opened, or a second bead added later for an
# already-tracked PR). v2 replaces the map with a live scan, each sweep, of
# every registered rig (`gc rig list`) for beads labeled `waiting-on:pr-<N>`
# (the convention already used by ga-9sghx/ga-xcq1ph/etc.) — so a bead
# becomes a tracker the moment it's labeled, no code edit required, and BOTH
# directions get a durable watcher:
#   (a) a tracked PR transitions to MERGED/CLOSED while its bead(s) are still
#       open — alerts EVERY matching bead across every city, not just one.
#   (b) an OPEN PR by $GH_AUTHOR has NO bead anywhere carrying its
#       `waiting-on:pr-<N>` label — alerts the Mayor to open one (or close
#       the PR) — the direction v1 could never see at all, since it can only
#       enumerate PRs someone already told it about.
#
# What it does:
#   - One `gh pr list --repo gastownhall/beads --author athosmartins --state
#     all` call per sweep.
#   - discover_tracker_beads() scans every city from `gc rig list --json`
#     (falling back to $BUPW_FALLBACK_CITIES if that fails) for beads with
#     ANY status (--all — a tracker can legitimately be `deferred`, e.g.
#     ga-r8haw's self-clearing pool-visibility park, and still be the
#     correct, current tracker) carrying a `waiting-on:pr-<N>` label.
#   - Alerts ONLY on a state TRANSITION (previously-recorded state != current
#     state) — never on a persisting state. An alert that fires every sweep
#     regardless of change teaches people to ignore it. Same rule for orphan
#     alerts: once alerted for a given PR#, no repeat until a bead appears
#     (resolved) or disappears again (re-alertable).
#   - On transition to MERGED or CLOSED (without merging): comments on EVERY
#     mapped tracker bead and mails the Mayor. A close-without-merge means a
#     human should decide whether to resubmit. A merge means engine
#     rebuild+swap MAY be needed — ga-6ur6h: the alert now checks (via `gh pr
#     diff --name-only`) whether the PR actually touches compiled Go source
#     (*.go/go.mod/go.sum) before claiming Mayor coordination is required; a
#     PR that only touches scripts/docs/test-infra says so instead. A failed
#     check (network/auth/etc.) defaults to the stronger claim — see
#     _pr_touches_compiled_go.
#   - A PR observed for the FIRST time (no prior state) that is ALREADY
#     merged/closed also alerts immediately — "no prior baseline" must not be
#     silently folded into "nothing changed"; those are different states (see
#     classify_pr_transition below).
#   - Reopened PRs are tracked (state updated) but do not alert — nothing
#     downstream needs to act on a reopen by itself.
#   - Single-instance lock: mkdir+heartbeat+pid-liveness, same shape as
#     gate-orphaned-label-watchdog.sh's GOLW lock (ga-y0g5x: 4 simultaneous
#     watchdog instances stacked Dolt queries and took bd down citywide; the
#     fix there gates reclaim SOLELY on `kill -0` liveness, never on
#     heartbeat age alone — an old-but-alive holder must never be reclaimed).
#   - Runs once/day via launchd StartCalendarInterval (NOT StartInterval — a
#     long StartInterval resets its countdown on every sleep/reboot of the
#     mini and may in practice never fire; see upstream-drift-sentinel.plist
#     for the same lesson already learned in this repo). NOT CronCreate —
#     session-only, expires in 7 days, would silently reproduce this exact
#     bug (an invisible watcher nobody notices disappearing).
#
# TEST (hermetic, no live gh/bd/gc):
#   bash scripts/beads-upstream-pr-watchdog.selftest.sh
set -uo pipefail

HQ="${BUPW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
GH_REPO="${BUPW_GH_REPO:-gastownhall/beads}"
GH_AUTHOR="${BUPW_GH_AUTHOR:-athosmartins}"
GH_LIMIT="${BUPW_GH_LIMIT:-200}"
BD_BIN="${BD_BIN:-bd}"
GC_BIN="${GC_BIN:-gc}"
LOG="${BUPW_LOG:-$HQ/.gc/logs/beads-upstream-pr-watchdog.log}"
STATE="${BUPW_STATE:-$HOME/.gastown/state/beads-upstream-pr-watchdog.state.json}"
# Used ONLY if `gc rig list` itself fails outright (e.g. gc not on PATH or a
# transient Dolt blip) — not a hardcoded substitute for it; gc rig list is
# always tried first every sweep. Degrading to "scan what we know about"
# beats "scan nothing and report a false orphan for every open PR."
BUPW_FALLBACK_CITIES="${BUPW_FALLBACK_CITIES:-$HQ}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# discover_cities -> one bd-DB path per line to scan for tracker beads.
# Dynamic on purpose: a hardcoded rig list would reproduce the exact bug this
# rewrite fixes (see PR_BEAD_MAP's history in git blame) — a new rig must be
# visible here without a code change.
discover_cities() {
  local rigs
  rigs=$("$GC_BIN" rig list --json 2>>"$LOG" | jq -r '.rigs[]?.path // empty' 2>/dev/null)
  if [ -z "$rigs" ]; then
    log "WARN: gc rig list returned no cities — falling back to \$BUPW_FALLBACK_CITIES ($BUPW_FALLBACK_CITIES); scan is now PARTIAL (unknown cities may be silently missing), suppressing this sweep's orphan check"
    # Signal the fallback through the SAME channel discover_tracker_beads()
    # uses for a per-city bd-list failure (BUPW_DISCOVERY_ERRORS, set by our
    # caller before invoking us — see run_sweep). A gc-rig-list failure is
    # strictly worse than a single city erroring: we don't even know which
    # (or how many) cities are missing from $BUPW_FALLBACK_CITIES, so the
    # orphan sweep must be suppressed the same way, not just when a KNOWN
    # city fails to answer.
    [ -n "${BUPW_DISCOVERY_ERRORS:-}" ] && echo "__gc_rig_list_fallback__" >> "$BUPW_DISCOVERY_ERRORS" 2>/dev/null
    printf '%s\n' "$BUPW_FALLBACK_CITIES"
    return
  fi
  printf '%s\n' "$rigs"
}

# discover_tracker_beads -> TSV: pr_num<TAB>bead_id<TAB>city — one row per
# (PR, bead) pair found by scanning every city for the `waiting-on:pr-<N>`
# label convention (precedent: ga-9sghx, ga-xcq1ph). Scans --all statuses
# deliberately: a tracker bead can legitimately be non-"open" (e.g.
# `deferred`, see ga-r8haw) while still being the correct, current tracker —
# filtering to status=open would reproduce this rewrite's own bug. A PR MAY
# have more than one tracker bead, in one city or across several; all are
# returned so every one gets alerted (v1's single PR->bead map could only
# ever notify one — part of what ga-se0ly reported: ga-5ksp5 never heard
# about PR #5439 merging because only wa-msxg5 was in the map for it).
#
# If $BUPW_DISCOVERY_ERRORS is set, a city whose `bd list` call fails or
# returns unparseable output appends its name to that file instead of just
# being silently skipped. This distinguishes "queried and genuinely has zero
# trackers" from "could not be queried" — the caller (run_sweep) uses it to
# suppress the orphan sweep on an incomplete scan, since "this city has no
# tracker" and "this city errored" must not collapse into the same "not
# tracked anywhere" verdict that triggers an orphan alert to the Mayor.
discover_tracker_beads() {
  local city rows
  while IFS= read -r city; do
    [ -z "$city" ] && continue
    rows=$("$BD_BIN" -C "$city" list --all --label-pattern 'waiting-on:pr-*' --json --limit 0 2>>"$LOG")
    if [ -z "$rows" ] || ! printf '%s' "$rows" | jq -e '.' >/dev/null 2>&1; then
      log "WARN: bd list failed or returned unparseable output for city=$city — its tracker beads are UNKNOWN this sweep, not confirmed-absent"
      [ -n "${BUPW_DISCOVERY_ERRORS:-}" ] && echo "$city" >> "$BUPW_DISCOVERY_ERRORS" 2>/dev/null
      continue
    fi
    printf '%s' "$rows" | jq -r --arg city "$city" '
      .[] as $b |
      (($b.labels // [])[] | select(startswith("waiting-on:pr-"))) as $lbl |
      [($lbl | ltrimstr("waiting-on:pr-")), $b.id, $city] | @tsv
    ' 2>>"$LOG"
  done < <(discover_cities)
}

# classify_pr_transition <prev_state> <cur_state>
#   -> first-seen | merged | closed-no-merge | reopened | no-change | unknown
# Pure decision, no I/O — same shape as classify_external_pr_gap3 in
# quality-gate-guard.sh (that one sweeps per-bead-labeled PRs; this one
# sweeps by author, so a PR needs no per-bead opt-in to be watched).
# prev="UNKNOWN" means "no prior sweep ever recorded a state for this PR" —
# kept distinct from "recorded and unchanged" (no-change) on purpose: a PR
# that is ALREADY merged/closed the first time we ever see it still deserves
# an alert, because nothing has watched its transition until now either.
classify_pr_transition() {
  local prev="$1" cur="$2"
  if [ "$prev" = "UNKNOWN" ]; then
    case "$cur" in
      MERGED) echo "merged"; return ;;
      CLOSED) echo "closed-no-merge"; return ;;
      *)      echo "first-seen"; return ;;
    esac
  fi
  if [ "$prev" = "$cur" ]; then echo "no-change"; return; fi
  case "$cur" in
    MERGED) echo "merged" ;;
    CLOSED) echo "closed-no-merge" ;;
    OPEN)   echo "reopened" ;;
    *)      echo "unknown" ;;
  esac
}

# _pr_touches_compiled_go <pr_num> -> 0 (touches, or undetermined — fail
#                                        safe/escalate) | 1 (diff fetched
#                                        successfully and touches no
#                                        compiled Go source)
# ga-6ur6h: the watchdog used to claim "Next step (engine rebuild+swap)
# needs Mayor coordination" for EVERY merged upstream PR, unconditionally —
# including one that only touched scripts/migration-test/ + lib/*.sh (test
# infra, ported to darwin/arm64, zero cmd/gc or cmd/bd change). Checked by
# file extension/name (*.go, go.mod, go.sum) rather than a directory
# whitelist (cmd/, internal/, ...): gastownhall/beads' compiled runtime
# spans many top-level packages (backend/, beadserrors/, format/,
# issueops/, journalops/, memoryops/, plugins/, query_interfaces*,
# root-level *.go files) beyond just cmd/+internal/, and a directory
# whitelist would need to track that set as the upstream repo evolves — an
# extension check doesn't, and can't silently go stale the way a whitelist
# would. Any command failure (network, auth, gh missing at sweep time, repo
# access) is treated as "touches" — silently downgrading a real engine
# change to "nothing to do" is a worse failure than one extra alert.
_pr_touches_compiled_go() {
  local pr_num="$1" files rc
  files=$(gh pr diff "$pr_num" --repo "$GH_REPO" --name-only 2>>"$LOG")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "WARN: gh pr diff --name-only failed for PR #$pr_num (rc=$rc) — cannot determine whether it touches compiled Go sources; defaulting to touches=yes (fail safe)"
    return 0
  fi
  if printf '%s\n' "$files" | grep -qE '(^|/)go\.(mod|sum)$|\.go$'; then
    return 0
  fi
  return 1
}

# _alert_merge / _alert_closed_no_merge take a NEWLINE-separated "bead\tcity"
# list (one PR can have several tracker beads) and comment on every one, plus
# a single Mayor mail. Both return 0 only if EVERY notification channel
# succeeded (all bead comments AND the mail), 1 if any failed. The caller
# (run_sweep) uses this to decide whether the transition is truly "handled"
# — see the state-advance comment below for why that distinction matters.
_alert_merge() {
  local pr_num="$1" url="$2" pairs="$3" msg ok=0 bead_id bead_city
  if _pr_touches_compiled_go "$pr_num"; then
    msg="beads-upstream-pr-watchdog (ga-574zr/ga-se0ly): upstream PR $url (gastownhall/beads #$pr_num, author $GH_AUTHOR) is now MERGED. Next step (engine rebuild+swap) needs Mayor coordination — this bead does not close itself."
  else
    msg="beads-upstream-pr-watchdog (ga-574zr/ga-se0ly/ga-6ur6h): upstream PR $url (gastownhall/beads #$pr_num, author $GH_AUTHOR) is now MERGED, but its diff touches no compiled Go source (no *.go/go.mod/go.sum files) — looks like test/docs/script infra only, no engine work expected. This bead does not close itself; confirm and close if there is nothing further to do."
  fi
  while IFS=$'\t' read -r bead_id bead_city; do
    [ -z "$bead_id" ] && continue
    printf '%s' "$msg" | "$BD_BIN" -C "$bead_city" comment "$bead_id" --stdin >>"$LOG" 2>&1 \
      || { ok=1; log "WARN: bd comment failed for $bead_id (PR #$pr_num)"; }
  done <<<"$pairs"
  "$GC_BIN" mail send mayor -s "Upstream PR merged: gastownhall/beads #$pr_num" -m "$msg" >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: gc mail send failed for PR #$pr_num"; }
  return "$ok"
}

_alert_closed_no_merge() {
  local pr_num="$1" url="$2" pairs="$3" msg ok=0 bead_id bead_city
  msg="beads-upstream-pr-watchdog (ga-574zr/ga-se0ly): upstream PR $url (gastownhall/beads #$pr_num, author $GH_AUTHOR) was CLOSED WITHOUT merging. A human should decide whether to resubmit or abandon."
  while IFS=$'\t' read -r bead_id bead_city; do
    [ -z "$bead_id" ] && continue
    printf '%s' "$msg" | "$BD_BIN" -C "$bead_city" comment "$bead_id" --stdin >>"$LOG" 2>&1 \
      || { ok=1; log "WARN: bd comment failed for $bead_id (PR #$pr_num)"; }
  done <<<"$pairs"
  "$GC_BIN" mail send mayor -s "Upstream PR closed without merge: gastownhall/beads #$pr_num" -m "$msg" >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: gc mail send failed for PR #$pr_num"; }
  return "$ok"
}

# _alert_orphan: the direction v1 could never detect (see header). Mails the
# Mayor only — deliberately does NOT auto-create a bead. Fabricating a bead
# from a PR title with no other context risks a low-quality duplicate if the
# real tracker exists but uses different wording; a human decision here is
# cheap and safer (ga-se0ly's own text: "NAO precisa ser sofisticado").
_alert_orphan() {
  local pr_num="$1" url="$2" title="$3" msg ok=0
  msg="beads-upstream-pr-watchdog (ga-se0ly): upstream PR $url (gastownhall/beads #$pr_num: \"$title\", author $GH_AUTHOR) is OPEN with NO tracking bead found in any scanned city. Open one (label story:awaiting-external-merge + waiting-on:pr-$pr_num, external_ref=$url) or close the PR if it is no longer wanted."
  "$GC_BIN" mail send mayor -s "Upstream PR has no tracking bead: gastownhall/beads #$pr_num" -m "$msg" >>"$LOG" 2>&1 \
    || { ok=1; log "WARN: gc mail send failed for orphan PR #$pr_num"; }
  return "$ok"
}

run_sweep() {
  if ! command -v gh >/dev/null 2>&1; then
    log "gh CLI not found on PATH — skipping sweep entirely"
    return 0
  fi

  local all_prs
  all_prs=$(gh pr list --repo "$GH_REPO" --author "$GH_AUTHOR" --state all \
    --json number,state,mergedAt,url,title --limit "$GH_LIMIT" 2>>"$LOG")
  if [ -z "$all_prs" ] || ! printf '%s' "$all_prs" | jq -e '.' >/dev/null 2>&1; then
    log "gh pr list failed or returned unparseable output — safe-skip, no state change"
    return 0
  fi

  local raw_state
  raw_state=$(cat "$STATE" 2>/dev/null || echo '{}')
  printf '%s' "$raw_state" | jq -e '.' >/dev/null 2>&1 || raw_state='{}'
  # Schema: {"prs": {"<num>": {state, checked_at}}, "orphans_alerted": {"<num>": {alerted_at}}}.
  # A pre-ga-se0ly state file (flat "<num>": {...} at the top level, no "prs"
  # key) migrates transparently: treat the whole object as the prs map and
  # start orphans_alerted empty.
  local prev_prs prev_orphans
  prev_prs=$(printf '%s' "$raw_state" | jq -c 'if has("prs") then .prs else . end')
  prev_orphans=$(printf '%s' "$raw_state" | jq -c '.orphans_alerted // {}')
  local new_prs="$prev_prs"
  local new_orphans="$prev_orphans"
  local tracked_count=0 event_count=0

  local tracker_rows tracked_pr_nums
  local discovery_errors_file discovery_incomplete=0
  discovery_errors_file=$(mktemp 2>/dev/null || printf '%s/bupw-discovery-errors.%s' "${TMPDIR:-/tmp}" "$$")
  : > "$discovery_errors_file" 2>/dev/null || true
  tracker_rows=$(BUPW_DISCOVERY_ERRORS="$discovery_errors_file" discover_tracker_beads)
  [ -s "$discovery_errors_file" ] && discovery_incomplete=1
  rm -f "$discovery_errors_file" 2>/dev/null
  tracked_pr_nums=$(printf '%s' "$tracker_rows" | cut -f1 | sort -u)

  local pr_num
  while IFS= read -r pr_num; do
    [ -z "$pr_num" ] && continue

    local cur cur_state cur_url prev_pr_state action handled pairs
    cur=$(printf '%s' "$all_prs" | jq -c --argjson n "$pr_num" '[.[] | select(.number == $n)][0] // empty')
    if [ -z "$cur" ]; then
      log "PR #$pr_num tracked by bead(s) but not found in this sweep's gh result — safe-skip (may be outside --limit=$GH_LIMIT, or authored by someone else; widen BUPW_GH_LIMIT if this persists)"
      continue
    fi
    cur_state=$(printf '%s' "$cur" | jq -r '.state')
    cur_url=$(printf '%s' "$cur" | jq -r '.url')
    prev_pr_state=$(printf '%s' "$prev_prs" | jq -r --arg k "$pr_num" '.[$k].state // "UNKNOWN"')
    pairs=$(printf '%s' "$tracker_rows" | awk -F'\t' -v n="$pr_num" '$1==n {print $2"\t"$3}')

    tracked_count=$((tracked_count + 1))
    action=$(classify_pr_transition "$prev_pr_state" "$cur_state")
    # "handled" gates whether new_prs advances below. A transition whose
    # alert only partially succeeded (e.g. one bd comment landed but the
    # Mayor mail failed on a transient Dolt/network blip) must NOT be
    # recorded as done — advancing here would permanently silence the retry,
    # since transition-only alerting means classify_pr_transition() would
    # see MERGED->MERGED ("no-change") on every future sweep and never speak
    # again. Leaving prev_pr_state untouched costs one duplicate alert
    # (visible, cheap) in exchange for never silently losing one.
    handled=1
    case "$action" in
      merged)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (merged) — alerting bead(s)=$(printf '%s' "$pairs" | cut -f1 | paste -sd, -)"
        if _alert_merge "$pr_num" "$cur_url" "$pairs"; then
          event_count=$((event_count + 1))
        else
          handled=0
          log "WARN: PR #$pr_num merge alert incomplete — state NOT advanced, will retry next sweep"
        fi
        ;;
      closed-no-merge)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (closed, no merge) — alerting bead(s)=$(printf '%s' "$pairs" | cut -f1 | paste -sd, -)"
        if _alert_closed_no_merge "$pr_num" "$cur_url" "$pairs"; then
          event_count=$((event_count + 1))
        else
          handled=0
          log "WARN: PR #$pr_num closed-no-merge alert incomplete — state NOT advanced, will retry next sweep"
        fi
        ;;
      reopened)
        log "TRANSITION: PR #$pr_num $prev_pr_state -> $cur_state (reopened) — tracking resumes, no alert"
        event_count=$((event_count + 1))
        ;;
      first-seen)
        log "BASELINE: PR #$pr_num first seen at state=$cur_state (bead(s)=$(printf '%s' "$pairs" | cut -f1 | paste -sd, -)) — no prior watcher to compare against, recording only"
        ;;
      no-change) ;;
      *)
        log "WARN: PR #$pr_num unrecognized transition $prev_pr_state -> $cur_state"
        event_count=$((event_count + 1))
        ;;
    esac

    if [ "$handled" = "1" ]; then
      new_prs=$(printf '%s' "$new_prs" | jq --arg k "$pr_num" --arg s "$cur_state" --arg t "$(ts)" \
        '.[$k] = {state: $s, checked_at: $t}')
    fi
  done <<<"$tracked_pr_nums"

  # ── Orphan sweep (case b): an OPEN PR by $GH_AUTHOR with ZERO tracker bead
  # in ANY scanned city — the direction a hand-maintained map can never see,
  # since it can only enumerate PRs someone already told it about.
  #
  # Skipped entirely when ANY city failed to respond this sweep
  # ($discovery_incomplete, set above from discover_tracker_beads' error
  # file). A city that errored contributes ZERO rows to $tracker_rows —
  # exactly indistinguishable, by row count alone, from a city that was
  # queried successfully and genuinely tracks nothing. Proceeding anyway
  # would risk mailing the Mayor a false "no tracking bead anywhere" claim
  # for a PR whose only tracker lives in the city that failed to answer.
  # One skipped day is cheap; a false claim costs a human's investigation
  # time chasing a bead that was never missing. Merge/close-transition
  # alerting above is unaffected by this — a PR merely not found as tracked
  # this sweep is silently retried next sweep, never misreported.
  if [ "$discovery_incomplete" = "1" ]; then
    log "SKIPPING orphan sweep this sweep: at least one city failed to respond (see WARN lines above) — 'no tracker found' cannot be trusted while the scan is incomplete"
  else
    local open_pr_nums n o_url o_title
    open_pr_nums=$(printf '%s' "$all_prs" | jq -r '.[] | select(.state=="OPEN") | .number')
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      if printf '%s\n' "$tracked_pr_nums" | grep -qx "$n"; then
        # Now has a tracker -> clear any stale orphan-alert record so a
        # FUTURE re-orphaning (e.g. the tracker bead gets deleted) can alert
        # again.
        new_orphans=$(printf '%s' "$new_orphans" | jq --arg k "$n" 'del(.[$k])')
        continue
      fi
      if printf '%s' "$prev_orphans" | jq -e --arg k "$n" 'has($k)' >/dev/null 2>&1; then
        continue
      fi
      o_url=$(printf '%s' "$all_prs" | jq -r --argjson n "$n" '[.[] | select(.number==$n)][0].url')
      o_title=$(printf '%s' "$all_prs" | jq -r --argjson n "$n" '[.[] | select(.number==$n)][0].title')
      log "ORPHAN: PR #$n is OPEN with no tracker bead in any scanned city — alerting"
      if _alert_orphan "$n" "$o_url" "$o_title"; then
        event_count=$((event_count + 1))
        new_orphans=$(printf '%s' "$new_orphans" | jq --arg k "$n" --arg t "$(ts)" '.[$k] = {alerted_at: $t}')
      else
        log "WARN: PR #$n orphan alert failed — will retry next sweep"
      fi
    done <<<"$open_pr_nums"
  fi

  # Unconditional per-sweep line, even when nothing changed: on a log that
  # only ever writes on notable events, a daemon that silently stopped
  # running would leave the exact same empty-since-last-write log as one that
  # ran fine and found nothing new — the two are indistinguishable without
  # this. This line is the proof-of-life the other one can't provide.
  log "sweep complete: $tracked_count tracked PR(s), $event_count event(s)"

  mkdir -p "$(dirname "$STATE")" 2>/dev/null || true
  jq -n --argjson prs "$new_prs" --argjson orph "$new_orphans" '{prs: $prs, orphans_alerted: $orph}' \
    > "$STATE" 2>/dev/null || log "WARN: failed to write state file $STATE"
}

# ── Single-instance lock ────────────────────────────────────────────────────
# Same shape as gate-orphaned-label-watchdog.sh's GOLW lock (ga-y0g5x): atomic
# `mkdir` mutex (POSIX-atomic, no fd — a leaked fd can never keep a directory
# "locked", unlike the flock-inode leak that once deadlocked the pilot for
# 5h+), a heartbeat file for staleness, and `kill -0 $pid` as the SOLE gate on
# reclaim (age is diagnostic-only in the log line — gating reclaim on age
# alone can steal the lock from a legitimately-slow-but-alive holder).
BUPW_LOCK_ENABLED="${BUPW_LOCK_ENABLED:-1}"
BUPW_LOCK_DIR="${TMPDIR:-/tmp}/beads-upstream-pr-watchdog.lock.d"
BUPW_LOCK_HB="$BUPW_LOCK_DIR/heartbeat"
BUPW_LOCK_REAP_TTL="${BUPW_LOCK_REAP_TTL:-10}"
BUPW_LOCK_TOKEN="${BUPW_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_bupw_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}
_bupw_lock_hb_age() { _bupw_lock_path_age "$BUPW_LOCK_HB"; }

_bupw_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$BUPW_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_bupw_lock_write_hb() { printf '%s\n' "$BUPW_LOCK_TOKEN" > "$BUPW_LOCK_HB" 2>/dev/null || true; }

_release_bupw_lock() {
  local _own
  _own=$(head -n1 "$BUPW_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$BUPW_LOCK_TOKEN" ] && rm -rf "$BUPW_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (caller backs off).
_acquire_bupw_lock() {
  if mkdir "$BUPW_LOCK_DIR" 2>/dev/null; then
    _bupw_lock_write_hb
    if [ ! -s "$BUPW_LOCK_HB" ]; then
      rm -rf "$BUPW_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  if ! _bupw_lock_holder_dead; then
    return 1   # holder is ALIVE -> never reclaim, no matter how old the heartbeat is.
  fi
  if [ ! -s "$BUPW_LOCK_HB" ]; then
    return 1
  fi
  local _reaping="${BUPW_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_bupw_lock_path_age "$_reaping")" -ge "$BUPW_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${BUPW_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then rm -rf "$_dead" 2>/dev/null || true; fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1   # another reclaimer owns the recovery -> back off (no double-win).
    fi
  fi
  if ! _bupw_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  local _age
  _age=$(_bupw_lock_hb_age)
  _bupw_lock_write_hb
  if [ ! -s "$BUPW_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock (heartbeat age ${_age}s) — taking over."
  return 0
}

# Lib mode (BEADS_UPSTREAM_PR_WATCHDOG_LIB=1): define functions, do not run —
# lets the selftest source this file and drive run_sweep()/classify_pr_transition()
# directly against hermetic fixtures. Matches the house convention
# (GATE_DISPATCHER_LIB_ONLY, ORDER_EXEC_FAILURE_WATCHDOG_LIB, …) used
# throughout this tree's *.selftest.sh files.
if [ "${BEADS_UPSTREAM_PR_WATCHDOG_LIB:-0}" != "1" ]; then
  if [ "$BUPW_LOCK_ENABLED" = "1" ]; then
    if _acquire_bupw_lock; then
      trap '_release_bupw_lock' EXIT
    else
      log "Another beads-upstream-pr-watchdog run holds the lock — backing off (single-instance guard)."
      exit 0
    fi
  fi
  run_sweep
  exit 0
fi
