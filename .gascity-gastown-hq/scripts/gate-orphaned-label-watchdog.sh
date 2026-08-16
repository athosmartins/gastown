#!/usr/bin/env bash
# gate-orphaned-label-watchdog.sh — detects beads carrying a gate:* lifecycle
# label with ZERO active quality-gate-marker/-run behind them, for longer than
# a configurable age threshold.
#
# WHY THIS EXISTS (ga-l8yh6, follow-up AC4 of ga-d3eg2):
#   ga-d3eg2 fixed the ownership-guard deadlock (gate:needs-fix stripped but
#   gate:fix-attempt:N survives — pilot-dispatcher.sh's _ownership_guard_should_refuse
#   and _filter_built now carve out on gate:fix-attempt:N alone too). That closed
#   the DEADLOCK, but the underlying VISIBILITY gap it measured remains: a bead
#   can carry a gate:* lifecycle label with no active marker/run behind it for a
#   long time before anyone notices. ga-d3eg2's own one-off measurement found 8
#   such beads, some stuck 10+ days — different root causes per bead (stale
#   label, branch conflicts needing re-anchor, already-merged-but-bead-
#   never-closed, or intentionally parked at gate:needs-human/blocked-by:*/
#   blocked:*).
#   gate-throughput-stall-watchdog.sh answers "is the GATE stalled" (queue-level);
#   this answers "is this ONE BEAD stranded" (bead-level) — a bead can be
#   individually stuck while the gate itself is healthy and processing other work.
#
# LOGIC (runs every ~900s via launchd):
#   1. For each rig store in GOLW_STORES: list non-closed beads (bd's default
#      view already excludes status=closed — no --all/--status needed here,
#      verified live against bd 1.0.5), keep those carrying >=1 label starting
#      with "gate:" (the TARGET bead's lifecycle namespace — distinct from an
#      artifact's gate-status:* namespace, so artifact beads can never leak in
#      as false candidates even if a store listing ever included them).
#   2. Age-gate: skip any candidate whose updated_at (fallback created_at) is
#      younger than GOLW_STALE_MINUTES — avoids flagging a bead mid-transition
#      between gate states.
#   3. For each aged candidate, replicate pilot-dispatcher.sh's signal-(d) check
#      (_beadid_has_active_gate_artifact, ~line 3212) against the HQ store: an
#      OPEN type:quality-gate-marker/-run labeled source-bead:<id> at an ACTIVE
#      gate-status (ready/claimed/queued/dispatching/reviewing/running) means
#      the gate IS holding the branch right now — not orphaned, skip. Otherwise
#      (no artifact at all, OR only parked/terminal ones like needs-rebase/
#      error/passed/failed/superseded/deferred, OR a closed artifact) → a
#      CANDIDATE for flagging.
#   4. Split candidates into orphan-suspect vs. parado-de-proposito (ga-cjk1j,
#      blocked:* added ga-te41ft): a bead carrying gate:needs-human* /
#      blocked-by:* / blocked:* / status=blocked is a
#      human's self-declared park — it's counted (see the "PARK:" log line and
#      the mail summary) but never enters the age-based alert/cooldown/comment
#      pipeline below. Everything else is an orphan-suspect and flows through
#      step 5 exactly as before this split. A THIRD bucket (ga-eiaidn) is
#      split out the same way: status=in_progress with a session-VERIFIED-
#      live assignee (gc session list) — counted separately (see the
#      "ACTIVE:" log line) and likewise excluded from the pipeline below
#      while that session remains live.
#   5. Report only — this daemon NEVER mutates a bead (no label/status/assignee/
#      close calls of any kind). Per-bead: `bd comment` (durable, lives on the
#      bead itself). Aggregate: `notify` (low priority — see note below) +
#      `gc mail send mayor`. Re-alerting on an already-flagged bead is
#      cooldown-gated (GOLW_ALERT_COOLDOWN_S) via a local state file so a
#      persistently-stuck bead doesn't spam a fresh alert every ~15min forever.
#
# WHY DETECTION-ONLY, NO AUTO-CORRECT: lifecycle-coherence-janitor.sh's R4/R5
# history (memory: lifecycle-janitor-R4-R5-false-positive-corrupts-pipeline) —
# automated correctors in this exact problem class ("reclaim can't reliably
# tell live from dead") force-closed an ACTIVELY-FAILING gate:needs-fix bead
# and cleared a live builder's assignee mid-build, causing duplicate work.
# ga-d3eg2 explicitly scoped this follow-up to detection-only for that reason:
# "Detection-only is the safer starting point; auto-remediation (if ever
# wanted) should be a separate, later decision made with real detector data in
# hand."
#
# PARK-VS-ORPHAN SPLIT (ga-cjk1j, fixing a ga-l8yh6 blind spot): the first
# release of this watchdog surfaced every gate:*-labeled bead with no active
# marker alike, whether silently stranded or deliberately parked by a human
# (gate:needs-human*, blocked-by:*, status=blocked). Measured 2026-08-05: 11 of
# 20 (55%) flagged beads were self-declared, intentional parks — a channel
# that re-alerts on the same 11 every cooldown cycle trains readers to ignore
# the whole report, and that's how the 9 real orphan-suspects hid in the
# noise. A park bead is now excluded from the age-based alert/cooldown/comment
# pipeline entirely and only contributes to a count (see the "PARK:" log line
# and the mail summary) — it is still logged every sweep, but it no longer
# competes for attention with a bead nobody decided to leave alone.
#
# blocked:* GAP (ga-te41ft, same class reappearing in a sibling namespace):
# the ga-cjk1j fix above only ever excluded blocked-by:* (a DEPENDENCY
# POINTER — "what blocks this bead"). It never covered blocked:* (colon, no
# hyphen) — the town's actual deliberate self-park label family
# (blocked:sem-prioridade, blocked:needs-oracle-approval, etc. — 8 distinct
# labels measured live 2026-08-15, all intentional parks). Every blocked:*
# bead re-alerted every cooldown cycle exactly like the original bug this
# file exists to fix — same precision-erosion mechanism, different label
# prefix. blocked:* is now excluded alongside blocked-by:* in the is_park
# check below.
#
# IN-PROGRESS+LIVE-ASSIGNEE SPLIT (ga-eiaidn, follow-up of ga-te41ft AC2 —
# split out rather than folded in, mirroring this file's own precedent of
# ga-h8rcp being deferred out of ga-cjk1j): a bead can be status=in_progress,
# genuinely and correctly owned by a LIVE, working session, and still
# re-alert forever — measured live: wa-nxwqw (assignee=oracle-wa, a
# crew-style persistent worker) received 5 separate watchdog comments over
# 31+ hours, ~6h apart, exactly matching GOLW_ALERT_COOLDOWN_S, as its
# updated_at flip-flopped below/above GOLW_STALE_MINUTES every time
# oracle-wa touched it and then went stale again before the next touch. This
# is NOT the same bug as the park split above: nobody declared this bead
# parked — it is actively being worked, just not continuously enough to stay
# under the age gate. The obvious shortcut (exclude any status=in_progress
# bead with a non-empty assignee, is_park's own shape) was checked against
# live data and rejected: `bd list --id wa-nxwqw --all --json | jq
# '{heartbeat_at,lease_expires_at}'` returned BOTH null despite a real, live
# assignee — crew-style singleton workers don't populate the claim-lease
# heartbeat fields ephemeral dog/wa-worker/ps-worker pool sessions do, so
# there is no cheap, already-in-the-JSON signal here. A bead stuck
# in_progress with a genuinely DEAD/crashed assignee is a REAL orphan this
# watchdog must keep catching (this is exactly the failure mode
# lifecycle-coherence-janitor.sh's R4/R5 history warns about, cited in WHY
# DETECTION-ONLY below) — so this fix adds actual session-liveness
# verification (`gc session list --json --state active`, one fetch per
# sweep, cross-referenced against the assignee string — see
# _golw_active_sessions_json/_golw_session_alive) rather than a label/status
# heuristic. The fail-safe DIRECTION here is the OPPOSITE of the FAIL-OPEN
# rule below: elsewhere in this file, an unreadable query must never be
# treated as a confirmed negative; here, an unreadable query — or simply no
# matching live session — must never be treated as a confirmed POSITIVE. A
# wrong "declared alive" would silently blind this watchdog to a real
# orphan, which is worse than the noise this bug is about, so uncertainty
# always falls through to the pre-existing alert behavior, unchanged.
#
# NOTIFY PRIORITY: low (-p 2), not the -p 4 used by throughput-stall-watchdog.
# That watchdog pages Athos only when auto-recovery of a SYSTEMIC stall fails
# (Athos, 2026-06-30: "só me notifique quando a máquina precisar de mim"). A
# single stranded bead is an ops/triage finding for the Mayor, not something
# that needs Athos's phone — gc mail send mayor is the primary, actionable
# channel here; notify is a low-priority heads-up, not a page.
#
# FAIL-OPEN: any bd/jq/store-read error → skip that store/candidate, log a
# WARN, never let a read failure masquerade as "confirmed orphaned" (ga-p5q3
# defense (a): a failed query is not the same value as zero/confirmed).
#
# RESOLVED-PRUNING IS INDIVIDUALLY VERIFIED (ga-tqe4j): the mirror-image of
# the FAIL-OPEN rule above. A prior version declared a tracked bead RESOLVED
# and pruned it from state the moment it was simply ABSENT from this sweep's
# flagged set — collapsing "re-checked it, the label is really gone" and
# "this sweep just failed to re-observe it" into the same verdict. Verified
# live 2026-08-05: 18 beads logged RESOLVED in one sweep while >=4 of them
# still carried the gate:* label. Every bead about to be pruned is now
# individually re-checked against its own store (_bead_recheck_status) before
# the verdict is written; anything that cannot be positively confirmed
# cleared (query fails, store unknown, or the label is still there) stays in
# state with first_seen intact and is logged UNVERIFIED, never RESOLVED. This
# applies even when the WHOLE sweep comes back empty (every store failing at
# once is the most severe case of the same conflation, not a different one)
# — see _golw_resolve_tracked_state, the single choke point both branches of
# run_sweep funnel through.
#
# KILL-SWITCH: GOLW_ENABLED=0 → no-op.
# DRY-RUN: GOLW_DRY_RUN=1 → log findings, skip comment/notify/mail/state-write.
#
# Selftest: bash gate-orphaned-label-watchdog.sh --selftest
set -uo pipefail

# ── config (all env-overridable) ──────────────────────────────────────────────
GOLW_ENABLED="${GOLW_ENABLED:-1}"
GOLW_DRY_RUN="${GOLW_DRY_RUN:-0}"
GOLW_STALE_MINUTES="${GOLW_STALE_MINUTES:-180}"          # 3h — generous vs. normal gate-review latency (p99 ~240min per GTSW)
GOLW_ALERT_COOLDOWN_S="${GOLW_ALERT_COOLDOWN_S:-21600}"   # 6h — per-bead re-alert dedup window
GOLW_NOTIFY_PRIORITY="${GOLW_NOTIFY_PRIORITY:-2}"

HQ="${GOLW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
# Default sweep set = all rigs registered live at authoring time (`gc rig list`,
# 2026-08-03). Static + env-overridable (matches LCJ_STORES precedent in
# lifecycle-coherence-janitor.sh) rather than calling `gc rig list` every sweep
# — that call runs 8-17s under Dolt load, not worth paying every ~900s cycle
# for a set that changes rarely. If a new rig is added, update this default or
# override GOLW_STORES.
GOLW_STORES="${GOLW_STORES:-$HQ /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers /Users/athos/gt/marketing /Users/athos/gt/lexbh /Users/athos/gt/gastown /Users/athos/gt/deacon}"

# Label prefixes that start with "gate:" but are NOT part of the automated
# code-review gate lifecycle this watchdog audits, so they never carry (and
# were never meant to carry) a type:quality-gate-marker/-run artifact — a
# perpetual, meaningless flag rather than a real finding. Confirmed live
# (2026-08-03) via wa-kty2h/wa-5u2cv/wa-kty2h-class beads: gate:prod-deploy:*
# is a hand-applied "shipped, needs Athos's manual prod test" marker stamped
# AFTER the code-review gate already passed (see memory:
# auto-refino-raw-ingestion-4th-occurrence-timing-race-hypothesis) — grep of
# scripts/ + packs/town-deltas/assets/ found zero write-sites for it in any
# quality-gate-*/pilot-dispatcher code, confirming it's outside that pipeline
# entirely. Space-separated, env-overridable if another such family turns up.
#
# ga-h8rcp (Mayor, 2026-08-08): + gate:passed. Unlike gate:prod-deploy: this one
# IS inside the pipeline — it is the state in which having no active marker is
# CORRECT, so flagging it inverts the watchdog's own question. gate:passed is
# terminal SUCCESS: the gate is done with the bead by design. The bead may then
# legitimately stay open (ga-7j5vf: delivery:partial + scope:needs-review — one
# slice landed, more scope pending) or close hours later (wa-f2fc8 closed 5h
# after passing). Neither is anything a human can triage.
#
# That is why the alert count only ever GREW through a day (8 -> 10 in one
# night) and never correlated with any label-transition window: it was counting
# delivered work. Measured across HQ+wa+ps: the 8 flagged beads were exactly
# 7x [gate:passed] + 1x [gate:fix-attempt:1,gate:passed]; zero real strands.
#
# ⚠️ KNOWN RESIDUAL, measured not assumed: this kills 7 of the 8, not 8 of 8.
# gate:fix-attempt:N is a COUNTER, never cleared, so a bead that needed one fix
# and then passed keeps [gate:fix-attempt:1,gate:passed] and still alerts until
# it closes. It is NOT added to this list because gate:fix-attempt:1 is the
# default fixture label in ~25 selftest scenarios below — excluding it would
# silently un-flag most of this file's own regression coverage. The right fix
# is a separate NEUTRAL-prefix concept (counters ignored when deciding whether
# every remaining gate:* label is excluded), which needs its own tests; tracked
# on ga-h8rcp rather than smuggled in here.
#
# ⚠️ The safety property comes from the ALL-must-match semantics below, NOT
# from this list: a bead is excluded only when EVERY one of its gate:* labels
# falls in an excluded family. So the anomalies stay visible —
# [gate:passed,gate:queued] (the ga-i0n83 contradiction) and
# [gate:failed,gate:fix-attempt:1,gate:needs-fix] both keep alerting, because
# queued/failed/needs-fix are not excluded. Do NOT "simplify" this into a
# per-label skip: that would silence the contradiction this watchdog exists to
# catch, and I cleaned that contradiction by hand 7x in one night.
#
# ⚠️ Excluding gate:passed does NOT blind the city to "merged but never closed"
# — merged-bead-janitor.sh owns that class and is live (verified sweeping,
# closing beads and pruning branches, 2026-08-08 04:50). Checked before
# removing the signal, because a detector deleted on the assumption that
# something else covers it is how a gap opens silently.
GOLW_EXCLUDE_LABEL_PREFIXES="${GOLW_EXCLUDE_LABEL_PREFIXES:-gate:prod-deploy: gate:passed}"

LOG="${GOLW_LOG:-$HQ/.gc/logs/gate-orphaned-label-watchdog.log}"
NOTIFY_BIN="${GOLW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${GOLW_GC_BIN:-gc}"
BD_BIN="${GOLW_BD_BIN:-bd}"

GOLW_STATE_DIR="${GOLW_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${GOLW_STATE_FILE:-$GOLW_STATE_DIR/gate-orphaned-label-watchdog.state.json}"

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [golw] $*" >> "$LOG" 2>/dev/null || true; }

_store_name() { basename "$1"; }

# _gate_artifact_probe <bead_id>
# Prints "<active:0|1|error>\t<last_artifact_gate_status_or_none|unknown>\t<open_artifact_count>"
# The active bit replicates pilot-dispatcher.sh's _beadid_has_active_gate_artifact
# (ga-wisp signal (d), ~line 3212) EXACTLY — same active-state set, same query
# shape (bd list -l "source-bead:<id>" against the HQ store).
# CORRECTION (ga-vm20x, Mayor 07/08): the line above used to claim this
# label-scoped query surfaces type:quality-gate-marker/-run beads without
# needing --include-infra, "empirically verified 2026-08-03." That was true
# when written but bd 1.1.0 changed the ground under it: --ephemeral beads
# are now classified INFRA and hidden from `bd list` by default, including
# gate markers/runs. Re-verified live (ga-vm20x): of 8 sampled source-bead:
# queries against real markers, 2 diverged (1 result without --include-infra
# vs the true 2 with it) — this probe WAS silently under-counting. Flag added
# below; a comment asserting a query property is only as durable as the bd
# version it was measured against — don't trust it without re-measuring.
# The other two fields are reporting-only extras computed from the same read.
# FAIL-OPEN: a non-zero exit from the bd|jq pipe (pipefail-visible via $?) prints
# "error\tunknown\t0" instead of the confirmed-zero "0\tnone\t0" — a failed read
# must never be indistinguishable from a genuinely-empty result (gate-feedback
# 2026-08-03: the caller posts a durable comment asserting "0 = none ever
# found", which is false when the true state is "the query failed").
# Test seam: routes through $BD_BIN, stubbed in --selftest.
_gate_artifact_probe() {
  local _bid="$1" _arts _out _rc
  _arts=$("$BD_BIN" -C "$HQ" list --include-infra -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    log "WARN: gate-artifact probe failed for bead '$_bid' (bd/jq exit $_rc) — fail-open, not treating as confirmed-zero"
    printf 'error\tunknown\t0\n'
    return 1
  fi
  if [ -z "${_arts:-}" ] || [ "$_arts" = "null" ]; then
    printf '0\tnone\t0\n'
    return 0
  fi
  _out=$(printf '%s' "$_arts" | jq -r '
      [ .[] | select(.status == "open")
            | select( ((.labels // []) | index("type:quality-gate-marker"))
                      or ((.labels // []) | index("type:quality-gate-run")) )
      ] as $open
      | ($open | length) as $n
      | ( [ $open[] | select(
              ((.labels // []) | index("gate-status:ready"))       or
              ((.labels // []) | index("gate-status:claimed"))     or
              ((.labels // []) | index("gate-status:queued"))      or
              ((.labels // []) | index("gate-status:dispatching")) or
              ((.labels // []) | index("gate-status:reviewing"))   or
              ((.labels // []) | index("gate-status:running"))
            ) ] | length ) as $active
      | ( if $n == 0 then "none"
          else ( [ $open[] | (.labels // []) | map(select(startswith("gate-status:"))) | .[0] // empty ]
                 | .[0] // "gate-status:unknown" | sub("^gate-status:"; "") )
          end ) as $laststatus
      | "\(if $active > 0 then 1 else 0 end)\t\($laststatus)\t\($n)"
    ' 2>/dev/null)
  if [ -z "${_out:-}" ]; then
    printf '0\tnone\t0\n'
  else
    printf '%s\n' "$_out"
  fi
}

# _golw_active_sessions_json — one-shot fetch of the live session roster
# (`gc session list --json --state active`), reused for every
# status=in_progress candidate's liveness check this sweep instead of
# re-querying per bead (same reasoning GOLW_STORES' own header comment gives
# for not calling `gc rig list` every cycle — avoid paying a repeated cost
# for data that can't change mid-sweep). gc's own --state active filter
# already draws exactly the line this probe needs: verified live
# (2026-08-16) that sessions in "asleep" or "start-pending" state are NOT
# returned under --state active — neither is a session that could touch a
# bead again soon, so neither should count as verified-alive here.
# Prints the `.sessions` array as compact JSON, or "[]" on any read/parse
# failure — see _golw_session_alive for why an unreadable roster and an
# empty roster are treated identically (ga-eiaidn: this file's usual
# FAIL-OPEN direction is inverted for liveness checks).
# Test seam: routes through $GC_BIN, stubbed in --selftest.
_golw_active_sessions_json() {
  local _out _rc
  _out=$("$GC_BIN" session list --json --state active 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "${_out:-}" ]; then
    log "WARN: gc session list failed (exit $_rc) — session-liveness checks this sweep default to NOT verified-alive (fail-safe toward the pre-existing alert behavior, ga-eiaidn)"
    printf '[]'
    return 0
  fi
  printf '%s' "$_out" | jq -c '.sessions // []' 2>/dev/null || printf '[]'
}

# _golw_session_alive <assignee> <active_sessions_json>
# Verifies whether <assignee> — a bd bead's raw .assignee string — names a
# CURRENTLY ACTIVE gc session. Matches against every identity field a bd
# assignee value is known to carry in this city (measured live 2026-08-16):
# crew-style singleton workers (oracle-wa, mila-wa, thies-wa, ...) store the
# STABLE role name as .name/.agent_name/.alias/.template but a per-spawn
# RANDOM-SUFFIXED .session_name (e.g. "thies-wa-awisp559gquj") — and bd's
# own assignee value for these is the stable role name, never the suffixed
# one. Ephemeral dog/wa-worker/ps-worker pool sessions are the mirror image:
# bd's assignee is the per-spawn .session_name (e.g. "dog-gach4yyi"), while
# .agent_name/.alias is the reusable POOL SLOT name (e.g. "gastown.dog-1"),
# which is NOT what bd recorded as assignee. Matching only one field (only
# .agent_name, or only .session_name) silently misses one of these two
# worker families entirely — matching all five is what makes this uniform
# across both without needing to know which family a given assignee is.
# WRONG-DIRECTION WARNING (ga-eiaidn, the bug's own explicit caution): a
# false "1" here SUPPRESSES a real alert on a genuinely-dead assignee — a
# wrong "declared alive" is worse than the noise this bug exists to fix.
# Uncertainty (empty assignee, empty/unreadable roster, no match) always
# resolves to "0" — the opposite fail-direction from _gate_artifact_probe
# above, where uncertainty must not resolve to a confirmed NEGATIVE. Here it
# must not resolve to a confirmed POSITIVE.
# Prints "1" (verified alive) or "0" (dead, unknown, unmatched, or the
# roster itself could not be read).
_golw_session_alive() {
  local _assignee="$1" _sessions="$2" _out
  [ -z "${_assignee:-}" ] && { printf '0'; return 0; }
  [ -z "${_sessions:-}" ] && { printf '0'; return 0; }
  _out=$(printf '%s' "$_sessions" | jq -r --arg a "$_assignee" '
      ( map(select(
          (.name // "") == $a or (.agent_name // "") == $a or
          (.alias // "") == $a or (.template // "") == $a or
          (.session_name // "") == $a
        )) | length ) as $n
      | if $n > 0 then "1" else "0" end
    ' 2>/dev/null)
  case "$_out" in
    1) printf '1' ;;
    *) printf '0' ;;
  esac
}

# _bead_recheck_status <bead_id> <store> <exclude_prefixes_json>
# Individually re-verifies ONE bead's current orphan-suspect status directly
# against its store — the ga-tqe4j fix. Used ONLY when a bead already tracked
# in state did not appear in this sweep's flagged set, to decide whether that
# absence means "genuinely resolved" or "this sweep simply failed to
# re-observe it" (those two must never collapse to the same verdict — see the
# RESOLVED-PRUNING header comment). Uses the safe `list --id <id>` FLAG form
# (not a positional `bd show <id>`) — an exact-match filter, immune to bd's
# fuzzy positional-id matching. Prints exactly one token to stdout:
#   error   — the query itself failed (bd/jq non-zero, unreadable output):
#             UNKNOWN, caller must NOT prune (fail-open, ga-p5q3 defense (a)).
#   gone    — store has no record at all for this id (rare: hard-deleted):
#             treated as resolved.
#   closed  — bead exists, status=closed: no longer "stuck in gate limbo" by
#             definition, treated as resolved regardless of label residue.
#   absent  — bead exists, open, carries NO non-excluded gate:* label: the
#             label genuinely cleared — the exact case the bug asks to
#             confirm before declaring RESOLVED.
#   present — bead exists, open, STILL carries a non-excluded gate:* label:
#             it dropped out of this sweep for some OTHER reason (transient
#             probe failure, reclassified as park, etc.) — NOT resolved.
_bead_recheck_status() {
  local _id="$1" _store="$2" _excl="$3" _out _rc
  _out=$("$BD_BIN" -C "$_store" list --id "$_id" --all --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "${_out:-}" ] || [ "$_out" = "null" ]; then
    printf 'error\n'
    return 1
  fi
  printf '%s' "$_out" | jq -r --arg id "$_id" --argjson excl "$_excl" '
      ([ .[] | select(.id == $id) ] | .[0]) as $b
      | if $b == null then "gone"
        elif ($b.status // "") == "closed" then "closed"
        else ( (($b.labels // []) | map(select(startswith("gate:")))) as $gl
               | if ($gl | length) == 0 then "absent"
                 elif ($gl | all(. as $x | $excl | any(. as $p | $x | startswith($p)))) then "absent"
                 else "present"
                 end )
        end
    ' 2>/dev/null
}

# _state_load — prints the current state JSON (or "{}" on missing/corrupt file, fail-open)
_state_load() {
  if [ -f "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# _golw_resolve_tracked_state <state_json> <flagged_ids_json> <exclude_prefixes_json>
# ga-tqe4j: the single choke point BOTH branches of run_sweep funnel through
# before pruning anything from state. For every bead in <state_json> that is
# NOT in <flagged_ids_json> (i.e. a resolution candidate — including the
# degenerate case where <flagged_ids_json> is "[]" because the whole sweep
# came back empty), individually re-verifies it via _bead_recheck_status
# before deciding. Only a positively-confirmed clear (absent/closed/gone)
# gets pruned; anything else (query error, unknown store, or the label is
# genuinely still there) stays in state untouched, first_seen intact, and is
# logged UNVERIFIED rather than RESOLVED — see the RESOLVED-PRUNING header
# comment for why this must never collapse into one verdict.
# Prints ONE json object on stdout: {"state": <pruned-state>, "resolved_ids":
# [<ids individually confirmed resolved this call>]}. Every keep/prune
# decision is also written to $LOG via `log`.
_golw_resolve_tracked_state() {
  local _state="$1" _keep="$2" _excl="$3"
  local _candidates
  _candidates="$(printf '%s' "$_state" | jq -r --argjson keep "$_keep" 'keys - $keep | .[]' 2>/dev/null)"
  local _resolved="" _rid _rstore _rstatus _unverified_count=0
  if [ -n "${_candidates:-}" ]; then
    while IFS= read -r _rid; do
      [ -z "$_rid" ] && continue
      _rstore="$(printf '%s' "$_state" | jq -r --arg id "$_rid" '.[$id].store // empty' 2>/dev/null)"
      if [ -z "${_rstore:-}" ]; then
        log "UNVERIFIED: $_rid absent from this sweep but no store on record (pre-fix state entry) — cannot re-check, keeping (fail-safe)"
        _unverified_count=$((_unverified_count + 1))
        continue
      fi
      _rstatus="$(_bead_recheck_status "$_rid" "$_rstore" "$_excl")"
      case "$_rstatus" in
        absent|closed|gone)
          log "RESOLVED: $_rid re-checked individually (${_rstatus}) — no longer carries an orphaned gate:* label — cleared from state"
          _resolved="${_resolved}${_rid}"$'\n'
          ;;
        present)
          log "UNVERIFIED: $_rid re-checked and STILL carries a gate:* label (dropped from this sweep for another reason) — keeping in state, NOT resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
        *)
          log "UNVERIFIED: $_rid re-check query failed (store '$_rstore') — fail-safe, keeping in state, NOT declaring resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
      esac
    done <<< "$_candidates"
  fi
  if [ "$_unverified_count" -gt 0 ]; then
    log "UNVERIFIED total this sweep: ${_unverified_count} bead(s) absent from the flagged set but not positively confirmed cleared — kept in state"
  fi
  local _resolved_json
  _resolved_json="$(printf '%s' "$_resolved" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
  [ -z "${_resolved_json:-}" ] && _resolved_json="[]"
  local _new_state
  _new_state="$(printf '%s' "$_state" | jq -c --argjson gone "$_resolved_json" 'with_entries(select(.key as $k | ($gone | index($k)) == null))' 2>/dev/null)"
  [ -z "${_new_state:-}" ] && _new_state="$_state"
  jq -nc --argjson st "$_new_state" --argjson rid "$_resolved_json" '{state: $st, resolved_ids: $rid}' 2>/dev/null
}

run_sweep() {
  if [ "${GOLW_ENABLED:-1}" != "1" ]; then
    log "disabled (GOLW_ENABLED=0) — no-op"
    return 0
  fi
  if [ -z "${GOLW_TEST_MODE:-}" ]; then
    command -v "$BD_BIN" >/dev/null 2>&1 || { log "WARN: bd not on PATH — fail-open, no sweep"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not on PATH — fail-open, no sweep"; return 0; }
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - GOLW_STALE_MINUTES * 60 ))

  local exclude_prefixes_json
  exclude_prefixes_json="$(printf '%s\n' $GOLW_EXCLUDE_LABEL_PREFIXES | jq -R . | jq -s -c '[.[] | select(length > 0)]' 2>/dev/null)"
  [ -z "${exclude_prefixes_json:-}" ] && exclude_prefixes_json="[]"

  # ga-tqe4j: loaded up-front (was previously loaded further down, only in
  # the non-empty branch) so BOTH the empty-sweep fast path and the normal
  # cooldown/resolve path below can run beads already in state through
  # _golw_resolve_tracked_state before anything gets pruned.
  local state; state="$(_state_load)"

  # ga-eiaidn: one-shot fetch, reused by every status=in_progress candidate's
  # liveness check below via _golw_session_alive — see
  # _golw_active_sessions_json for why this is fetched once per sweep
  # instead of once per candidate.
  local active_sessions_json; active_sessions_json="$(_golw_active_sessions_json)"

  # Accumulate flagged candidates as TSV lines: id\tstore\tage_min\tlabels\tartifact_status\tartifact_count
  local flagged_tsv=""
  local store cand_json aged_json
  for store in $GOLW_STORES; do
    # Re-stamp the lock heartbeat once per store (mirrors quality-gate-
    # dispatcher.sh's per-verdict-poll re-stamp — see header). Guarded via
    # `command -v`: during in-process selftest scenarios (run_sweep called
    # directly, before the script reaches the lock section below in file
    # order) this function doesn't exist yet and the call is a silent no-op;
    # in the real script and in the lock-race selftest scenarios (which
    # invoke a full subprocess) it's already defined by the time run_sweep
    # executes for real.
    command -v _golw_lock_write_hb >/dev/null 2>&1 && _golw_lock_write_hb
    cand_json=$("$BD_BIN" -C "$store" list --json --limit 0 2>/dev/null \
      | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
    if [ -z "${cand_json:-}" ] || [ "$cand_json" = "null" ]; then
      log "WARN: could not read store '$store' (bd query or jq parse failed) — skipping (fail-open)"
      continue
    fi

    # Keep only beads carrying >=1 label in the gate:* TARGET namespace, EXCLUDING:
    #  (a) the gate artifacts (type:quality-gate-marker/-run) themselves —
    #      verified live 2026-08-03 (ga-wisp-fpyxxhp) that a marker bead can
    #      carry its OWN literal gate:* labels (e.g. gate:exiled-tier5:2,
    #      gate:rebase-fail-count:2) alongside its gate-status:* label, so
    #      "different namespace" alone does NOT separate target beads from
    #      artifact beads — the type:* label must be excluded explicitly or a
    #      marker misreads as a stranded target.
    #  (b) GOLW_EXCLUDE_LABEL_PREFIXES (default: gate:prod-deploy: gate:passed)
    #      — gate:*-prefixed families for which "no active marker" is the
    #      CORRECT state, so flagging them is always noise: non-pipeline
    #      families that never carry a marker by design (gate:prod-deploy:),
    #      plus the terminal success state gate:passed (see config comment
    #      above for the live measurement). Only
    #      excludes a bead when ALL of its gate:*-prefixed labels fall in this
    #      family — a bead mixing e.g. gate:prod-deploy:* with a real pipeline
    #      label like gate:queued still gets evaluated, since the pipeline
    #      label means it genuinely may be gate-tracked.
    # Then age-gate via the proven lifecycle-coherence-janitor.sh R3 idiom:
    # unparseable/missing timestamp falls back to a far-future epoch so it
    # NEVER wrongly ages a candidate whose timestamp we can't parse (fail-safe,
    # not fail-alert).
    aged_json=$(printf '%s' "$cand_json" | jq -c --argjson cut "$cutoff" --argjson excl "$exclude_prefixes_json" '
        [ .[] | select((.labels // []) | any(startswith("gate:")))
              | select((.labels // []) | (index("type:quality-gate-marker") or index("type:quality-gate-run")) | not)
              | select( ( (.labels // []) | map(select(startswith("gate:"))) ) as $gl
                        | ( $gl | all(. as $x | $excl | any(. as $p | $x | startswith($p)) ) ) | not )
              | select( ((( .updated_at // .created_at // "") | fromdateiso8601?) // 9999999999) < $cut )
        ]
      ' 2>/dev/null)
    if [ -z "${aged_json:-}" ]; then
      log "WARN: age-filter jq failed for store '$store' — skipping (fail-open)"
      continue
    fi

    local ids_labels
    # is_park (ga-cjk1j): computed per-label via jq's own startswith() (exact
    # prefix semantics on each label individually) rather than a substring
    # match on the joined-labels string later in bash — a joined string like
    # "gate:needs-human,gate:queued" makes "contains gate:needs-human" easy to
    # get right, but a naive bash substring check is the wrong tool once any
    # label could plausibly share a prefix (e.g. a hypothetical
    # "gate:needs-humanoid"); doing it once here on the real label array is
    # unambiguous. status=blocked is the other park signal (ga-cjk1j AC3): 4 of
    # the 11 known intentional parks carry status=blocked with NO
    # gate:needs-human label at all — a labels-only check would miss them.
    # blocked:* (colon — ga-te41ft): a DIFFERENT namespace from blocked-by:*
    # (a dependency pointer, "what blocks this bead" — deliberately NOT park,
    # mirrors context-check-dispatcher.sh's ga-7mbry convention). blocked:* is
    # the town's actual self-park label (e.g. blocked:sem-prioridade,
    # blocked:needs-oracle-approval). The original ga-cjk1j fix only excluded
    # blocked-by:*, so every blocked:*-labeled bead re-alerted forever — 8
    # measured live 2026-08-15, one (wa-kty2h) stuck ~4.8 days despite being
    # correctly and deliberately parked on an open dependency.
    # bstatus/bassignee (ga-eiaidn): carried through unchanged from $b so the
    # while-loop below can decide, per candidate, whether a session-liveness
    # check even applies (status=in_progress with a non-empty assignee) —
    # see _golw_session_alive. Plain passthrough fields, not a park-style
    # boolean, because "in_progress with a live assignee" is a DIFFERENT
    # bucket from is_park (counted separately — see the ACTIVE split below).
    ids_labels=$(printf '%s' "$aged_json" | jq -r '
        .[] | . as $b
        | ($b.labels // []) as $L
        | [ $b.id,
            ([$L[] | select(startswith("gate:"))] | join(",")),
            ($b.updated_at // $b.created_at // ""),
            ( if ( ($L | any(startswith("gate:needs-human")))
                   or ($L | any(startswith("blocked-by:")))
                   or ($L | any(startswith("blocked:")))
                   or (($b.status // "") == "blocked") )
              then "1" else "0" end ),
            ($b.status // ""),
            ($b.assignee // "")
          ] | @tsv
      ' 2>/dev/null)
    [ -z "${ids_labels:-}" ] && continue

    local bid blabels bts is_park bstatus bassignee age_min probe active lstatus lcount is_live
    while IFS=$'\t' read -r bid blabels bts is_park bstatus bassignee; do
      [ -z "${bid:-}" ] && continue
      probe="$(_gate_artifact_probe "$bid")"
      active="$(printf '%s' "$probe" | cut -f1)"
      lstatus="$(printf '%s' "$probe" | cut -f2)"
      lcount="$(printf '%s' "$probe" | cut -f3)"
      case "$active" in
        1) continue ;;      # has an ACTIVE marker/run right now — not orphaned, skip
        error) continue ;;  # probe read failed (WARN already logged by _gate_artifact_probe) — fail-open, don't flag on unknown state
      esac
      local bepoch
      bepoch="$(printf '%s' "$bts" | jq -Rr 'fromdateiso8601? // empty' 2>/dev/null)"
      if [ -n "${bepoch:-}" ]; then
        age_min=$(( (now - bepoch) / 60 ))
      else
        age_min="?"
      fi
      # ga-eiaidn: only worth a liveness lookup when it could change the
      # verdict — a bead already headed for park_tsv (is_park=1) stays
      # parked regardless, and only status=in_progress with a non-empty
      # assignee is even eligible for the ACTIVE bucket at all.
      is_live="0"
      if [ "$is_park" != "1" ] && [ "$bstatus" = "in_progress" ] && [ -n "${bassignee:-}" ]; then
        is_live="$(_golw_session_alive "$bassignee" "$active_sessions_json")"
      fi
      flagged_tsv="${flagged_tsv}${bid}\t${store}\t${age_min}\t${blabels}\t${lstatus}\t${lcount}\t${is_park}\t${is_live}\n"
    done <<< "$ids_labels"
  done

  # ── ga-cjk1j: split flagged candidates into orphan-suspect (drives the
  # age-based alert below, unchanged) vs. parado-de-proposito (counted only).
  # Splitting here, before ANY state/cooldown/comment/notify/mail logic runs,
  # means every downstream stage operates on orphan_tsv exactly as it did
  # before this fix — an un-parked bead's behavior is byte-for-byte identical
  # (AC2 control: a real orphan must keep alerting exactly as today). ────────
  local orphan_tsv="" park_tsv="" park_count=0 active_tsv="" active_count=0
  local bid store2 age_min labels lstatus lcount is_park is_live
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount is_park is_live; do
    [ -z "${bid:-}" ] && continue
    if [ "$is_park" = "1" ]; then
      park_tsv="${park_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
      park_count=$((park_count + 1))
    elif [ "$is_live" = "1" ]; then
      # ga-eiaidn: is_park takes precedence above — a bead carrying BOTH a
      # park label and a live in_progress assignee is counted as parked, not
      # active-live, matching how a deliberate human signal already outranks
      # everything else in this split.
      active_tsv="${active_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
      active_count=$((active_count + 1))
    else
      orphan_tsv="${orphan_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
    fi
  done < <(printf '%b' "$flagged_tsv")
  flagged_tsv="$orphan_tsv"

  if [ "$park_count" -gt 0 ]; then
    log "PARK: ${park_count} bead(s) parado(s) de proposito (gate:needs-human*/blocked-by:*/blocked:*/status=blocked) — nao contam para o alerta de orfao"
    printf '%b' "$park_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
      [ -z "${bid:-}" ] && continue
      log "  - PARK $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}]"
    done
  fi

  if [ "$active_count" -gt 0 ]; then
    log "ACTIVE: ${active_count} bead(s) in_progress com sessao de assignee viva confirmada via gc session list (ga-eiaidn) — nao contam para o alerta de orfao"
    printf '%b' "$active_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
      [ -z "${bid:-}" ] && continue
      log "  - ACTIVE $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}]"
    done
  fi

  if [ -z "${flagged_tsv:-}" ]; then
    local park_suffix=""
    [ "$park_count" -gt 0 ] && park_suffix="${park_suffix} (${park_count} parked, excluded)"
    [ "$active_count" -gt 0 ] && park_suffix="${park_suffix} (${active_count} active-live, excluded)"
    if [ "$state" = "{}" ]; then
      # Nothing currently orphaned AND nothing was ever tracked — genuine
      # no-op, nothing to verify or prune.
      if [ -f "$STATE_FILE" ] && [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
        rm -f "$STATE_FILE" 2>/dev/null || true
      fi
      log "OK: 0 beads with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min) across ${GOLW_STORES}${park_suffix}"
      return 0
    fi
    # ga-tqe4j: pre-existing tracked state but nothing flagged THIS sweep —
    # this is the MOST SEVERE form of the exact bug this fix targets (a total
    # read failure across every store looks byte-for-byte identical to "every
    # tracked bead just got fixed"). Never blind-wipe here either — run every
    # tracked bead through the same individual-recheck choke point as the
    # normal path below before touching anything. The recheck itself is
    # read-only, so (matching how the rest of this file treats DRY_RUN) it
    # still runs and still logs — only the STATE FILE WRITE is skipped.
    local _envelope0; _envelope0="$(_golw_resolve_tracked_state "$state" "[]" "$exclude_prefixes_json")"
    state="$(printf '%s' "$_envelope0" | jq -c '.state' 2>/dev/null)"
    [ -z "${state:-}" ] && state="{}"
    if [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
      if [ "$state" = "{}" ]; then
        if [ -f "$STATE_FILE" ]; then
          rm -f "$STATE_FILE" 2>/dev/null || true
          log "STATE CLEARED: no orphaned gate-labeled beads found — previous episode(s) resolved"
        fi
      else
        mkdir -p "$GOLW_STATE_DIR" 2>/dev/null || true
        printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
      fi
    fi
    log "OK: 0 beads with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min) across ${GOLW_STORES}${park_suffix}"
    return 0
  fi

  # ── cooldown/state handling: only ALERT on new-or-cooldown-expired beads,
  # but the aggregate report always lists the FULL current flagged set so a
  # human sees the whole picture, not just what's new this cycle. `state` was
  # already loaded up-front (see above the empty-sweep branch). ──
  local flagged_ids="[]"
  local to_alert_tsv=""
  local bid store2 age_min labels lstatus lcount last_alert
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    flagged_ids="$(printf '%s' "$flagged_ids" | jq -c --arg id "$bid" '. + [$id]' 2>/dev/null)" || flagged_ids="$flagged_ids"
    last_alert="$(printf '%s' "$state" | jq -r --arg id "$bid" '.[$id].last_alert // 0' 2>/dev/null)"
    case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
    if [ "$last_alert" -eq 0 ] || [ $(( now - last_alert )) -ge "$GOLW_ALERT_COOLDOWN_S" ]; then
      to_alert_tsv="${to_alert_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${lstatus}\t${lcount}\n"
      # ga-tqe4j: record the REAL store2 path, not the old self-referential
      # `.[$id].store // ""` (which only ever read back what a prior write put
      # there — and no write ever put anything but "" — so this field was
      # empty for every bead, forever; the Mayor flagged it live as a lead).
      # It's the prerequisite for _bead_recheck_status to know where to verify
      # a bead that later drops out of a sweep.
      state="$(printf '%s' "$state" | jq -c --arg id "$bid" --argjson now "$now" --arg st "$store2" \
        '.[$id] = {first_seen: (.[$id].first_seen // $now), last_alert: $now, store: $st}' 2>/dev/null)"
    fi
  done < <(printf '%b' "$flagged_tsv")

  # Prune resolved beads (no longer in the flagged set) from state — ga-tqe4j:
  # routed through the same individually-verified choke point as the
  # empty-sweep branch above, not a blind keys-subtraction (see the
  # RESOLVED-PRUNING header comment and _golw_resolve_tracked_state).
  local _envelope; _envelope="$(_golw_resolve_tracked_state "$state" "$flagged_ids" "$exclude_prefixes_json")"
  state="$(printf '%s' "$_envelope" | jq -c '.state' 2>/dev/null)"
  [ -z "${state:-}" ] && state="{}"
  local resolved_ids
  resolved_ids="$(printf '%s' "$_envelope" | jq -r '.resolved_ids[]' 2>/dev/null)"

  # ga-lnpa7: cooldown is correctly per-bead, but the mail used to report the
  # FULL flagged_tsv every time ANY bead was due — one new bead re-spammed
  # every already-alerted bead still in cooldown. Compute the delta up front
  # so both the "nothing changed" gate and the mail body key off it.
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"
  local resolved_count; resolved_count="$(printf '%s\n' "${resolved_ids:-}" | grep -c . || true)"

  local total_flagged; total_flagged="$(printf '%b' "$flagged_tsv" | grep -c . || true)"
  log "FLAGGED: ${total_flagged} bead(s) with gate:* label and zero active marker (>=${GOLW_STALE_MINUTES}min)"
  printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid ($(_store_name "$store2")) age=${age_min}min labels=[${labels}] last_artifact=${lstatus} (${lcount} open)"
  done

  if [ "${new_count:-0}" -eq 0 ] && [ "${resolved_count:-0}" -eq 0 ]; then
    local park_suffix2=""
    [ "$park_count" -gt 0 ] && park_suffix2="${park_suffix2} (+${park_count} parked, excluded)"
    [ "$active_count" -gt 0 ] && park_suffix2="${park_suffix2} (+${active_count} active-live, excluded)"
    log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${GOLW_ALERT_COOLDOWN_S}s) — no new notification${park_suffix2}"
    if [ "${GOLW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$GOLW_STATE_DIR" 2>/dev/null || true
      printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
    fi
    return 1
  fi

  if [ "${GOLW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would comment on new/due bead(s), notify (-p ${GOLW_NOTIFY_PRIORITY}), and mail mayor; state not persisted"
    return 1
  fi

  # ── per-bead durable comment (new-or-cooldown-expired only) ──────────────
  local msg
  while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
    [ -z "${bid:-}" ] && continue
    msg="gate-orphaned-label-watchdog (ga-l8yh6): this bead carries gate:* label(s) [${labels}] with no ACTIVE quality-gate-marker/-run for >= ${GOLW_STALE_MINUTES}min (age: ${age_min}min). Last known gate artifact: ${lstatus} (${lcount} open artifact(s) referencing this bead; 0 = none ever found in the HQ store). Detection-only report — no label/status/assignee was touched. Common causes seen historically (ga-d3eg2): stale label after a manual fix, branch conflicts needing re-anchor, or already-merged-but-never-closed (an intentional park via gate:needs-human*/blocked-by:*/blocked:*/status=blocked is excluded from this alert entirely — see ga-cjk1j/ga-te41ft) — a human/Mayor should triage."
    if [ -n "${GOLW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${store2}:${bid}:${msg}" >> "$GOLW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$store2" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail — DELTA report (ga-lnpa7): new/due + resolved +
  # a count of what's unchanged, not the full flagged set every cycle. ───────
  local unchanged_count=$(( total_flagged - new_count ))
  local summary="GATE ORPHANED LABEL: ${new_count} new/due, ${resolved_count} resolved, ${unchanged_count} unchanged-already-reported — ${total_flagged} total currently flagged (>=${GOLW_STALE_MINUTES}min)."
  if [ "$park_count" -gt 0 ]; then
    summary="${summary} +${park_count} parado(s) por decisao humana (gate:needs-human*/blocked-by:*/blocked:*/status=blocked) — nao contam para o alerta acima."
  fi
  if [ "$active_count" -gt 0 ]; then
    summary="${summary} +${active_count} em andamento com sessao viva (status=in_progress, assignee confirmado ativo via gc session list, ga-eiaidn) — nao contam para o alerta acima."
  fi

  if [ -n "${GOLW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$GOLW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Gate: orphaned label(s)" -p "${GOLW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body="GATE ORPHANED-LABEL WATCHDOG — detection-only report (ga-l8yh6, follow-up of ga-d3eg2 AC4).
"
  mail_body="${mail_body}
${summary}
"

  if [ "${new_count:-0}" -gt 0 ]; then
    local new_lines; new_lines="$(printf '%b' "$to_alert_tsv" | while IFS=$'\t' read -r bid store2 age_min labels lstatus lcount; do
      [ -z "${bid:-}" ] && continue
      echo "  ${bid}  (${store2})  age=${age_min}min  labels=[${labels}]  last_artifact=${lstatus} (${lcount} open)"
    done)"
    mail_body="${mail_body}
NEW/DUE (${new_count}) — why this cycle alerted:
${new_lines}
"
  fi

  if [ "${resolved_count:-0}" -gt 0 ]; then
    local resolved_lines; resolved_lines="$(printf '%s\n' "$resolved_ids" | while IFS= read -r rid; do
      [ -z "${rid:-}" ] && continue
      echo "  ${rid}  (no longer carries an orphaned gate:* label)"
    done)"
    mail_body="${mail_body}
RESOLVED (${resolved_count}) since last alert:
${resolved_lines}
"
  fi

  if [ "${unchanged_count:-0}" -gt 0 ]; then
    mail_body="${mail_body}
+${unchanged_count} already reported previously, unchanged — see the log for the full current list.
"
  fi

  mail_body="${mail_body}
This is SURFACE-ONLY — no label/status/assignee was touched on any bead. Common
root causes seen historically (ga-d3eg2's own measurement): a stale label left
after a manual fix, a branch that conflicts with main and needs re-anchor, or
work already merged but the bead never closed. Beads carrying an intentional
park signal (gate:needs-human*, blocked-by:*, blocked:*, status=blocked) are excluded from
this list entirely (ga-cjk1j) — see the parked-count line above. Beads that are
status=in_progress with a session-verified-live assignee (gc session list,
ga-eiaidn) are also excluded while that session remains active — see the
active-live count line above.

Per-bead detail for NEW/DUE beads is also posted as a comment on each bead.
Re-alerts for an already-flagged bead are suppressed for ${GOLW_ALERT_COOLDOWN_S}s
(state: ${STATE_FILE}). Full current list always in the log: ${LOG}"

  if [ -n "${GOLW_TEST_MAILED:-}" ]; then
    { echo "mail:gate-orphaned-label:$summary"; printf '%s\n' "$mail_body"; } >> "$GOLW_TEST_MAILED" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "Watchdog: ${total_flagged} bead(s) com gate:* label e zero marker ativo (>=${GOLW_STALE_MINUTES}min)" \
        -m "$mail_body" 2>/dev/null || true
  fi

  mkdir -p "$GOLW_STATE_DIR" 2>/dev/null || true
  printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${GOLW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  GOLW_TEST_MODE=1
  LOG="$TMP/golw.log"
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  BD_BIN="$TMP/bd"
  GOLW_ENABLED=1
  GOLW_DRY_RUN=0
  GOLW_STALE_MINUTES=180
  GOLW_ALERT_COOLDOWN_S=21600
  GOLW_STATE_DIR="$TMP/state"
  STATE_FILE="$TMP/state/golw.state.json"
  HQ="$TMP/hq"
  GOLW_STORES="$TMP/hq $TMP/wa"

  mkdir -p "$TMP/fixtures" "$GOLW_STATE_DIR"

  # Fake bd: routes on the verb + args. Candidate sweep = `list --json --limit 0`
  # with NO `-l` flag; artifact probe = `list -l source-bead:<id> --json`;
  # per-bead alert = `comment <id> --stdin`; ga-tqe4j individual re-check =
  # `list --id <id> --all --json`.
  cat > "$BD_BIN" <<'BDSTUB'
#!/usr/bin/env bash
store="$2"; verb="$3"; shift 3 2>/dev/null || true
storename="$(basename "$store")"
case "$verb" in
  list)
    args="$*"
    if [[ "$args" == *"-l source-bead:"* ]]; then
      id="$(printf '%s' "$args" | grep -oE 'source-bead:[A-Za-z0-9_.-]+' | head -1 | cut -d: -f2)"
      f="$GOLW_TEST_FIXTURES_DIR/artifacts-${id}.json"
    elif [[ "$args" == *"--id "* ]]; then
      id="$(printf '%s' "$args" | grep -oE -- '--id [A-Za-z0-9_.-]+' | head -1 | awk '{print $2}')"
      f="$GOLW_TEST_FIXTURES_DIR/recheck-${id}.json"
    else
      f="$GOLW_TEST_FIXTURES_DIR/candidates-${storename}.json"
    fi
    # __BD_FAIL__ sentinel fixture simulates a genuine bd command failure
    # (non-zero exit, no valid stdout) — distinct from a missing fixture,
    # which simulates a real, successful, empty result ("[]").
    if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
      echo "simulated bd failure: connection refused" >&2
      exit 1
    fi
    [ -f "$f" ] && cat "$f" || echo "[]"
    ;;
  comment)
    bid="$1"
    echo "comment:${storename}:${bid}" >> "${GOLW_TEST_COMMENTS_LOG:-/dev/null}"
    ;;
  *) echo "[]" ;;
esac
BDSTUB
  chmod +x "$BD_BIN"
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$GOLW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$NOTIFY_BIN"
  # Fake gc: "mail send mayor" keeps its pre-existing (effectively unused —
  # run_sweep only shells out to $GC_BIN for mail when GOLW_TEST_MAILED is
  # UNSET, which no selftest scenario does) behavior byte-for-byte. "session
  # list" (ga-eiaidn) is the new, actually-exercised path: reads a
  # fixture-driven active-session roster so _golw_session_alive's matching
  # can be tested without a live gc/session subsystem. __GC_FAIL__ mirrors
  # BD_BIN's own sentinel convention for simulating a genuine query failure.
  cat > "$GC_BIN" <<'GCSTUB'
#!/usr/bin/env bash
case "$1" in
  mail)
    echo "mail:$*" >> "${GOLW_TEST_MAILED:-/dev/null}" 2>/dev/null
    ;;
  session)
    if [ "$2" = "list" ]; then
      f="$GOLW_TEST_FIXTURES_DIR/sessions-active.json"
      if [ -f "$f" ] && grep -qx '__GC_FAIL__' "$f" 2>/dev/null; then
        echo "simulated gc session list failure" >&2
        exit 1
      fi
      [ -f "$f" ] && cat "$f" || echo '{"sessions":[]}'
    fi
    ;;
esac
exit 0
GCSTUB
  chmod +x "$NOTIFY_BIN" "$GC_BIN"

  export GOLW_TEST_FIXTURES_DIR="$TMP/fixtures"

  # ── fixture builders ──────────────────────────────────────────────────────
  # Real shapes verified live against ga-d3eg2's own measured beads (2026-08-03):
  # a stale bead with fix-attempt:N and NO artifact at all (ga-hn3kh shape), and
  # a stale bead with a PARKED (needs-rebase) artifact (wa-vcd01 shape) both
  # correctly flag; an ACTIVE marker (gate-status:dispatching, live wa-vlhki
  # shape) correctly suppresses.
  OLD_TS="$(date -u -v-10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ)"
  FRESH_TS="$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"

  mk_candidate() {  # id store labels_csv updated_at
    local id="$1" labels="$3" upd="$4"
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"open","updated_at":"%s","labels":%s}' "$id" "$upd" "$labels_json"
  }

  # ga-eiaidn: separate builder (not a mk_candidate signature change — every
  # existing scenario above relies on mk_candidate's hardcoded status=open
  # and absent .assignee) for the in_progress+assignee shape the new
  # session-liveness scenarios below need.
  mk_candidate_inprogress() {  # id store labels_csv updated_at assignee
    local id="$1" labels="$3" upd="$4" assignee="$5"
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"in_progress","assignee":"%s","updated_at":"%s","labels":%s}' "$id" "$assignee" "$upd" "$labels_json"
  }

  # ── Scenario 1: no artifact at all + stale → FLAG (ga-hn3kh shape) ────────
  echo "Scenario 1: stale bead, zero gate artifacts ever → flagged"
  printf '[%s]' "$(mk_candidate cand-a "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-a.json"
  NOTIF1="$TMP/notif1"; MAIL1="$TMP/mail1"; COMM1="$TMP/comm1"
  : > "$NOTIF1"; : > "$MAIL1"; : > "$COMM1"
  GOLW_TEST_NOTIFIED="$NOTIF1" GOLW_TEST_MAILED="$MAIL1" GOLW_TEST_COMMENTS_LOG="$COMM1" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 1: flagged (return 1)" || bad "scenario 1: should return 1 (flagged), got $rc"
  grep -q "comment:.*:cand-a" "$COMM1" 2>/dev/null && ok "scenario 1: bd comment posted on cand-a" || bad "scenario 1: no comment posted"
  grep -q "notify:" "$NOTIF1" 2>/dev/null && ok "scenario 1: notify fired" || bad "scenario 1: notify did NOT fire"
  grep -q "mail:" "$MAIL1" 2>/dev/null && ok "scenario 1: mayor mailed" || bad "scenario 1: mayor NOT mailed"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 2: PARKED artifact (needs-rebase) + stale → still FLAG (wa-vcd01 shape) ──
  echo "Scenario 2: stale bead with a parked (needs-rebase) artifact → still flagged"
  printf '[%s]' "$(mk_candidate cand-b "$TMP/wa" "gate:needs-fix,gate:needs-rebase,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  printf '[{"id":"art-b","status":"open","labels":["type:quality-gate-marker","gate-status:needs-rebase","source-bead:cand-b"]}]' > "$TMP/fixtures/artifacts-cand-b.json"
  NOTIF2="$TMP/notif2"; MAIL2="$TMP/mail2"; COMM2="$TMP/comm2"
  : > "$NOTIF2"; : > "$MAIL2"; : > "$COMM2"
  GOLW_TEST_NOTIFIED="$NOTIF2" GOLW_TEST_MAILED="$MAIL2" GOLW_TEST_COMMENTS_LOG="$COMM2" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 2: parked artifact still flagged (return 1)" || bad "scenario 2: should still flag a parked-only artifact, got $rc"
  grep -q "cand-b" "$COMM2" 2>/dev/null && ok "scenario 2: comment posted on cand-b" || bad "scenario 2: no comment on cand-b"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 3: ACTIVE artifact (dispatching) → NOT flagged (wa-vlhki shape) ──
  echo "Scenario 3: bead with an ACTIVE (dispatching) artifact → NOT flagged"
  printf '[%s]' "$(mk_candidate cand-c "$TMP/hq" "gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  printf '[{"id":"art-c","status":"open","labels":["type:quality-gate-marker","gate-status:dispatching","source-bead:cand-c"]}]' > "$TMP/fixtures/artifacts-cand-c.json"
  NOTIF3="$TMP/notif3"; MAIL3="$TMP/mail3"; COMM3="$TMP/comm3"
  : > "$NOTIF3"; : > "$MAIL3"; : > "$COMM3"
  GOLW_TEST_NOTIFIED="$NOTIF3" GOLW_TEST_MAILED="$MAIL3" GOLW_TEST_COMMENTS_LOG="$COMM3" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 3: active artifact suppresses (return 0)" || bad "scenario 3: active artifact should suppress, got $rc"
  [ ! -s "$NOTIF3" ] && ok "scenario 3: no notify when artifact is active" || bad "scenario 3: notify fired despite active artifact (false positive)"
  [ ! -s "$COMM3" ] && ok "scenario 3: no comment when artifact is active" || bad "scenario 3: comment posted despite active artifact"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 4: too FRESH → NOT flagged (age-gate) ────────────────────────
  echo "Scenario 4: bead orphaned but only 5min old → NOT flagged (below threshold)"
  printf '[%s]' "$(mk_candidate cand-d "$TMP/hq" "gate:queued" "$FRESH_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-d.json"
  NOTIF4="$TMP/notif4"; : > "$NOTIF4"
  GOLW_TEST_NOTIFIED="$NOTIF4" GOLW_TEST_MAILED="$TMP/mail4" GOLW_TEST_COMMENTS_LOG="$TMP/comm4" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 4: fresh orphan not flagged yet (return 0)" || bad "scenario 4: should NOT flag a 5min-old candidate (threshold 180min), got $rc"
  [ ! -s "$NOTIF4" ] && ok "scenario 4: no notify for a fresh candidate" || bad "scenario 4: notify fired for a fresh candidate (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5: no gate:* label at all → never a candidate ────────────────
  echo "Scenario 5: bead has other labels but no gate:* label → never a candidate"
  printf '[%s]' "$(mk_candidate cand-e "$TMP/hq" "ctx:ready,exec:auto" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5="$TMP/notif5"; : > "$NOTIF5"
  GOLW_TEST_NOTIFIED="$NOTIF5" GOLW_TEST_MAILED="$TMP/mail5" GOLW_TEST_COMMENTS_LOG="$TMP/comm5" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5: no gate:* label → not flagged (return 0)" || bad "scenario 5: bead with no gate:* label should never be a candidate, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5b (live-verified 2026-08-03, ga-wisp-fpyxxhp): a MARKER bead
  # carrying its own literal gate:* labels must never be misread as a stranded
  # TARGET bead — "different namespace" alone does not separate them; the
  # type:quality-gate-marker/-run label must be excluded explicitly. ─────────
  echo "Scenario 5b: a gate-marker bead with its own gate:* labels is excluded, not misflagged as a target"
  printf '[%s]' "$(mk_candidate cand-marker "$TMP/hq" "gate:exiled-tier5:2,gate:rebase-fail-count:2,type:quality-gate-marker,gate-status:needs-rebase,source-bead:cand-other" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5B="$TMP/notif5b"; : > "$NOTIF5B"
  GOLW_TEST_NOTIFIED="$NOTIF5B" GOLW_TEST_MAILED="$TMP/mail5b" GOLW_TEST_COMMENTS_LOG="$TMP/comm5b" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5b: marker bead with own gate:* labels excluded (return 0)" || bad "scenario 5b (ga-wisp-fpyxxhp regression): a type:quality-gate-marker bead was misflagged as a stranded target, got $rc"
  [ ! -s "$NOTIF5B" ] && ok "scenario 5b: no notify for a marker bead" || bad "scenario 5b: notify fired for a marker bead (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5c (live-verified 2026-08-03, wa-5u2cv/wa-kty2h class): a bead
  # whose ONLY gate:* label is gate:prod-deploy:* (a hand-applied "shipped,
  # needs Athos's manual prod test" marker stamped AFTER the code-review gate
  # already passed — never backed by a quality-gate-marker) must NOT be
  # flagged as orphaned. ──────────────────────────────────────────────────────
  echo "Scenario 5c: bead with ONLY a gate:prod-deploy:* label is excluded (not a code-review-gate orphan)"
  printf '[%s]' "$(mk_candidate cand-prod "$TMP/hq" "gate:prod-deploy:needs-athos-test,blocked-on:cand-other" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  NOTIF5C="$TMP/notif5c"; : > "$NOTIF5C"
  GOLW_TEST_NOTIFIED="$NOTIF5C" GOLW_TEST_MAILED="$TMP/mail5c" GOLW_TEST_COMMENTS_LOG="$TMP/comm5c" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5c: prod-deploy-only bead excluded (return 0)" || bad "scenario 5c (wa-5u2cv/wa-kty2h regression): a gate:prod-deploy:*-only bead was misflagged as a code-review-gate orphan, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5d: a bead MIXING gate:prod-deploy:* with a REAL pipeline label
  # (gate:queued) must still be evaluated — the exclusion is per-bead only when
  # ALL its gate:* labels fall in the excluded family, not on partial match. ──
  echo "Scenario 5d: bead mixing gate:prod-deploy:* with a real pipeline label (gate:queued) is still evaluated"
  printf '[%s]' "$(mk_candidate cand-mixed "$TMP/hq" "gate:prod-deploy:needs-athos-test,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mixed.json"
  NOTIF5D="$TMP/notif5d"; : > "$NOTIF5D"
  GOLW_TEST_NOTIFIED="$NOTIF5D" GOLW_TEST_MAILED="$TMP/mail5d" GOLW_TEST_COMMENTS_LOG="$TMP/comm5d" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 5d: mixed-label bead with a real pipeline label still flagged (return 1)" || bad "scenario 5d: a bead with gate:queued alongside gate:prod-deploy:* should still be evaluated on its own merits, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5e (ga-h8rcp, live-measured 2026-08-08): a bead whose ONLY
  # gate:* label is gate:passed must NOT be flagged. gate:passed is terminal
  # SUCCESS — the gate is done with it by design, so "no active marker" is the
  # expected state, not a strand. This was 7 of the 8 live false positives in
  # one night (ga-7j5vf shape: passed + still open on delivery:partial). ──────
  echo "Scenario 5e: bead with ONLY gate:passed is excluded (terminal success, not an orphan)"
  printf '[%s]' "$(mk_candidate cand-passed "$TMP/hq" "gate:passed,delivery:partial,scope:needs-review" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-passed.json"
  NOTIF5E="$TMP/notif5e"; : > "$NOTIF5E"
  GOLW_TEST_NOTIFIED="$NOTIF5E" GOLW_TEST_MAILED="$TMP/mail5e" GOLW_TEST_COMMENTS_LOG="$TMP/comm5e" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5e: gate:passed-only bead excluded (return 0)" || bad "scenario 5e (ga-h8rcp regression): a gate:passed-only bead was misflagged as orphaned, got $rc"
  [ ! -s "$NOTIF5E" ] && ok "scenario 5e: no notify for delivered work" || bad "scenario 5e: notify fired for a gate:passed-only bead (false positive)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5f (ga-h8rcp AC2 — the control that keeps 5e honest):
  # gate:passed ALONGSIDE a real pipeline label (gate:queued) is the ga-i0n83
  # CONTRADICTION — passed and queued at once — and MUST still alert. This is
  # the case the naive fix ("just skip any bead carrying gate:passed") would
  # silence, and it is exactly the residue I cleaned by hand 7x in one night.
  # The ALL-must-match semantics of the exclusion is what preserves it. ───────
  echo "Scenario 5f: gate:passed TOGETHER with gate:queued still alerts (the ga-i0n83 contradiction)"
  printf '[%s]' "$(mk_candidate cand-contra "$TMP/hq" "gate:passed,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-contra.json"
  NOTIF5F="$TMP/notif5f"; : > "$NOTIF5F"
  GOLW_TEST_NOTIFIED="$NOTIF5F" GOLW_TEST_MAILED="$TMP/mail5f" GOLW_TEST_COMMENTS_LOG="$TMP/comm5f" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 5f: passed+queued contradiction still flagged (return 1)" || bad "scenario 5f (ga-h8rcp AC2 regression): excluding gate:passed also silenced the passed+queued contradiction, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 5g (ga-h8rcp AC3): a REAL strand must be unaffected. gate:queued
  # with no active artifact is the shape the watchdog exists to catch; if this
  # ever stops alerting, the exclusion list has been over-broadened. ──────────
  echo "Scenario 5g: a real strand (gate:queued, no artifact) is unaffected by the exclusion"
  printf '[%s]' "$(mk_candidate cand-real "$TMP/hq" "gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-real.json"
  NOTIF5G="$TMP/notif5g"; : > "$NOTIF5G"
  GOLW_TEST_NOTIFIED="$NOTIF5G" GOLW_TEST_MAILED="$TMP/mail5g" GOLW_TEST_COMMENTS_LOG="$TMP/comm5g" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 5g: real gate:queued strand still flagged (return 1)" || bad "scenario 5g (ga-h8rcp AC3 regression): the exclusion swallowed a real strand, got $rc"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 6: COOLDOWN — same bead flagged twice, 2nd run within cooldown suppresses re-alert ──
  echo "Scenario 6: cooldown suppresses re-alert on the SAME still-orphaned bead"
  printf '[%s]' "$(mk_candidate cand-f "$TMP/hq" "gate:fix-attempt:2" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-f.json"
  NOTIF6A="$TMP/notif6a"; : > "$NOTIF6A"
  GOLW_TEST_NOTIFIED="$NOTIF6A" GOLW_TEST_MAILED="$TMP/mail6a" GOLW_TEST_COMMENTS_LOG="$TMP/comm6a" run_sweep
  rc1=$?
  NOTIF6B="$TMP/notif6b"; : > "$NOTIF6B"
  GOLW_TEST_NOTIFIED="$NOTIF6B" GOLW_TEST_MAILED="$TMP/mail6b" GOLW_TEST_COMMENTS_LOG="$TMP/comm6b" run_sweep
  rc2=$?
  [ "$rc1" -eq 1 ] && ok "scenario 6: 1st sweep flags (return 1)" || bad "scenario 6: 1st sweep should flag, got $rc1"
  [ -s "$NOTIF6A" ] && ok "scenario 6: 1st sweep notified" || bad "scenario 6: 1st sweep should notify"
  [ "$rc2" -eq 1 ] && ok "scenario 6: 2nd sweep still returns 1 (still orphaned)" || bad "scenario 6: 2nd sweep should still report flagged state, got $rc2"
  [ ! -s "$NOTIF6B" ] && ok "scenario 6: 2nd sweep within cooldown does NOT re-notify" || bad "scenario 6: cooldown did not suppress duplicate notify"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 7: RESOLVED — bead no longer a candidate → state cleared, no re-alert ──
  echo "Scenario 7: previously-flagged bead resolves (no longer orphaned) → state clears"
  printf '[%s]' "$(mk_candidate cand-g "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-g.json"
  GOLW_TEST_NOTIFIED="$TMP/notif7a" GOLW_TEST_MAILED="$TMP/mail7a" GOLW_TEST_COMMENTS_LOG="$TMP/comm7a" run_sweep >/dev/null
  [ -s "$STATE_FILE" ] && ok "scenario 7: state file written after 1st flag" || bad "scenario 7: state file missing after 1st flag"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"   # bead resolved (e.g. merged+closed, or gate picked it up)
  run_sweep >/dev/null
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 7: resolved sweep returns 0" || bad "scenario 7: resolved sweep should return 0, got $rc"
  grep -q "cand-g" "$STATE_FILE" 2>/dev/null && bad "scenario 7: resolved bead still lingers in state" || ok "scenario 7: resolved bead pruned from state"

  # ── Scenario 8: DRY-RUN — flags but no side effects, no state write ───────
  echo "Scenario 8: GOLW_DRY_RUN=1 → detects but no comment/notify/mail/state"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-h "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-h.json"
  NOTIF8="$TMP/notif8"; COMM8="$TMP/comm8"; : > "$NOTIF8"; : > "$COMM8"
  GOLW_DRY_RUN=1
  GOLW_TEST_NOTIFIED="$NOTIF8" GOLW_TEST_MAILED="$TMP/mail8" GOLW_TEST_COMMENTS_LOG="$COMM8" run_sweep
  rc=$?
  GOLW_DRY_RUN=0
  [ "$rc" -eq 1 ] && ok "scenario 8: DRY_RUN still reports flagged (return 1)" || bad "scenario 8: DRY_RUN should still return 1, got $rc"
  [ ! -s "$NOTIF8" ] && ok "scenario 8: no notify in DRY_RUN" || bad "scenario 8: notify fired in DRY_RUN"
  [ ! -s "$COMM8" ] && ok "scenario 8: no comment in DRY_RUN" || bad "scenario 8: comment posted in DRY_RUN"
  [ ! -f "$STATE_FILE" ] && ok "scenario 8: no state written in DRY_RUN" || bad "scenario 8: state written despite DRY_RUN"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 9: KILL-SWITCH ────────────────────────────────────────────────
  echo "Scenario 9: GOLW_ENABLED=0 → no-op"
  GOLW_ENABLED=0
  NOTIF9="$TMP/notif9"; : > "$NOTIF9"
  GOLW_TEST_NOTIFIED="$NOTIF9" GOLW_TEST_MAILED="$TMP/mail9" GOLW_TEST_COMMENTS_LOG="$TMP/comm9" run_sweep
  rc=$?
  GOLW_ENABLED=1
  [ "$rc" -eq 0 ] && ok "scenario 9: disabled returns 0" || bad "scenario 9: disabled should return 0, got $rc"
  [ ! -s "$NOTIF9" ] && ok "scenario 9: no notify when disabled" || bad "scenario 9: notify fired despite disabled"

  # ── Scenario 10: bd/jq read failure on one store's candidate listing → fail-open (skip that store), other store still swept ──
  echo "Scenario 10 (ga-p5q3): unreadable store (bd exits non-zero) → fail-open (skip it), does not crash or false-flag"
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/candidates-hq.json"   # genuine bd failure (non-zero exit), not just an empty result
  printf '[%s]' "$(mk_candidate cand-i "$TMP/wa" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-i.json"
  NOTIF10="$TMP/notif10"; : > "$NOTIF10"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF10" GOLW_TEST_MAILED="$TMP/mail10" GOLW_TEST_COMMENTS_LOG="$TMP/comm10" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 10: other store's candidate still flagged despite one unreadable store" || bad "scenario 10: should still flag cand-i from the wa store, got $rc"
  grep -q "WARN: could not read store" "$LOG" 2>/dev/null && ok "scenario 10: WARN logged for the unreadable store" || bad "scenario 10: no WARN logged for the unreadable hq store"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 10b (blocking issue 1, gate-feedback 2026-08-03): a bd/jq FAILURE
  # on the per-bead ARTIFACT PROBE (not the store-level candidate listing) must
  # NOT be treated as "confirmed zero artifacts" — regression test for the exact
  # defect the reviewer found, which Scenario 10 (store-level only) never
  # exercised. ──────────────────────────────────────────────────────────────────
  echo "Scenario 10b (blocking issue 1): artifact-probe bd failure on a stale candidate → fail-open, NOT flagged as orphaned"
  printf '[%s]' "$(mk_candidate cand-j "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/artifacts-cand-j.json"   # the artifact-probe bd call itself fails
  NOTIF10B="$TMP/notif10b"; MAIL10B="$TMP/mail10b"; COMM10B="$TMP/comm10b"
  : > "$NOTIF10B"; : > "$MAIL10B"; : > "$COMM10B"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF10B" GOLW_TEST_MAILED="$MAIL10B" GOLW_TEST_COMMENTS_LOG="$COMM10B" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 10b: probe failure → candidate not flagged (return 0)" || bad "scenario 10b (blocking issue 1 regression): a bd/jq failure on the artifact probe must fail-open, not flag as orphaned — got $rc"
  [ ! -s "$COMM10B" ] && ok "scenario 10b: no comment posted despite probe failure" || bad "scenario 10b: comment posted on a bead whose artifact probe failed to read (false 'confirmed zero' claim)"
  [ ! -s "$NOTIF10B" ] && ok "scenario 10b: no notify despite probe failure" || bad "scenario 10b: notify fired despite probe failure"
  grep -q "WARN.*cand-j" "$LOG" 2>/dev/null && ok "scenario 10b: WARN logged naming the failed candidate" || bad "scenario 10b: no WARN logged for the failed artifact probe"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 12 (ga-lnpa7 AC1): already-alerted beads + 1 new → mail
  # highlights the NEW bead, summarizes the rest as a COUNT, does not re-list
  # their per-bead detail. Also locks AC5: the LOG still gets the full set. ──
  echo "Scenario 12 (ga-lnpa7 AC1): already-alerted beads + 1 new → mail highlights NEW, counts the rest"
  printf '[%s,%s]' "$(mk_candidate cand-k1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" "$(mk_candidate cand-k2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k2.json"
  GOLW_TEST_NOTIFIED="$TMP/notif12a" GOLW_TEST_MAILED="$TMP/mail12a" GOLW_TEST_COMMENTS_LOG="$TMP/comm12a" run_sweep >/dev/null
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-k1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-k2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-k3 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-k3.json"
  MAIL12B="$TMP/mail12b"; : > "$MAIL12B"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif12b" GOLW_TEST_MAILED="$MAIL12B" GOLW_TEST_COMMENTS_LOG="$TMP/comm12b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 12: 2nd sweep still flags (return 1)" || bad "scenario 12: 2nd sweep should flag, got $rc"
  grep -q "cand-k3" "$MAIL12B" 2>/dev/null && ok "scenario 12: mail highlights the NEW bead (cand-k3)" || bad "scenario 12: mail does not mention the new bead cand-k3"
  grep -q "cand-k1" "$MAIL12B" 2>/dev/null && bad "scenario 12 (ga-lnpa7 regression): mail re-lists an already-reported bead (cand-k1) individually" || ok "scenario 12: already-reported cand-k1 not individually re-listed"
  grep -q "cand-k2" "$MAIL12B" 2>/dev/null && bad "scenario 12 (ga-lnpa7 regression): mail re-lists an already-reported bead (cand-k2) individually" || ok "scenario 12: already-reported cand-k2 not individually re-listed"
  grep -q "+2 already reported" "$MAIL12B" 2>/dev/null && ok "scenario 12: mail includes a count-only summary for the 2 already-reported beads" || bad "scenario 12: mail missing count-only summary for already-reported beads"
  grep -q "cand-k1" "$LOG" 2>/dev/null && grep -q "cand-k2" "$LOG" 2>/dev/null && grep -q "cand-k3" "$LOG" 2>/dev/null \
    && ok "scenario 12: log still records the FULL flagged list (k1,k2,k3) even though mail summarizes k1/k2" \
    || bad "scenario 12 (ga-lnpa7 AC5 regression): log is missing one or more flagged beads"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 13 (ga-lnpa7 AC2): nothing changed since the last alert (no
  # new/due bead, none resolved) → ZERO mail (not just zero notify). ─────────
  echo "Scenario 13 (ga-lnpa7 AC2): nothing changed since last alert → zero mail"
  printf '[%s]' "$(mk_candidate cand-l "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-l.json"
  GOLW_TEST_NOTIFIED="$TMP/notif13a" GOLW_TEST_MAILED="$TMP/mail13a" GOLW_TEST_COMMENTS_LOG="$TMP/comm13a" run_sweep >/dev/null
  MAIL13B="$TMP/mail13b"; : > "$MAIL13B"
  GOLW_TEST_NOTIFIED="$TMP/notif13b" GOLW_TEST_MAILED="$MAIL13B" GOLW_TEST_COMMENTS_LOG="$TMP/comm13b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 13: 2nd sweep still reports flagged state (return 1)" || bad "scenario 13: 2nd sweep should still return 1 (still orphaned), got $rc"
  [ ! -s "$MAIL13B" ] && ok "scenario 13: no mail sent when nothing changed" || bad "scenario 13 (ga-lnpa7 AC2 regression): mail sent despite nothing changing since last alert"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 14 (ga-lnpa7 AC3): a bead resolves while a SIBLING bead stays
  # flagged (still within its own cooldown, not due) → the resolution alone
  # triggers a mail, and that mail names the resolved bead. ──────────────────
  echo "Scenario 14 (ga-lnpa7 AC3): a resolved bead appears in the next mail even if nothing else is due"
  printf '[%s,%s]' "$(mk_candidate cand-m1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" "$(mk_candidate cand-m2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-m1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-m2.json"
  GOLW_TEST_NOTIFIED="$TMP/notif14a" GOLW_TEST_MAILED="$TMP/mail14a" GOLW_TEST_COMMENTS_LOG="$TMP/comm14a" run_sweep >/dev/null
  printf '[%s]' "$(mk_candidate cand-m2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  MAIL14B="$TMP/mail14b"; : > "$MAIL14B"
  GOLW_TEST_NOTIFIED="$TMP/notif14b" GOLW_TEST_MAILED="$MAIL14B" GOLW_TEST_COMMENTS_LOG="$TMP/comm14b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 14: sweep still returns 1 (cand-m2 still flagged)" || bad "scenario 14: should still return 1, got $rc"
  [ -s "$MAIL14B" ] && ok "scenario 14: a mail fired for the resolution alone (no bead was newly due)" || bad "scenario 14 (ga-lnpa7 AC3 regression): resolved bead did not trigger a mail"
  grep -q "cand-m1" "$MAIL14B" 2>/dev/null && ok "scenario 14: mail names the resolved bead (cand-m1)" || bad "scenario 14 (ga-lnpa7 AC3 regression): mail does not mention the resolved bead cand-m1"
  grep -q "RESOLVED" "$MAIL14B" 2>/dev/null && ok "scenario 14: mail labels it under a RESOLVED section" || bad "scenario 14: mail missing a RESOLVED section header"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 15 (ga-lnpa7 AC4, CONTROL): first-ever sweep (no prior state)
  # → every flagged bead is "new" and gets full per-bead detail in the mail —
  # the fix must not silence or truncate the FIRST report. ───────────────────
  echo "Scenario 15 (ga-lnpa7 AC4 control): first execution (no prior state) → full detail for every bead, nothing suppressed"
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-n1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-n2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-n3 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n2.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-n3.json"
  MAIL15="$TMP/mail15"; : > "$MAIL15"
  [ -f "$STATE_FILE" ] && bad "scenario 15: state file should not pre-exist for this control" || ok "scenario 15: no prior state (genuine first run)"
  GOLW_TEST_NOTIFIED="$TMP/notif15" GOLW_TEST_MAILED="$MAIL15" GOLW_TEST_COMMENTS_LOG="$TMP/comm15" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 15: first sweep flags (return 1)" || bad "scenario 15: first sweep should flag, got $rc"
  for id in cand-n1 cand-n2 cand-n3; do
    grep -q "$id" "$MAIL15" 2>/dev/null && ok "scenario 15: first report includes $id" || bad "scenario 15 (ga-lnpa7 AC4 regression): first report is missing $id"
  done
  grep -q "already reported" "$MAIL15" 2>/dev/null && bad "scenario 15: first report should have zero already-reported beads to summarize" || ok "scenario 15: no spurious already-reported summary on a first run"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 16 (ga-cjk1j AC1, FIXTURE): a bead carrying gate:queued +
  # gate:needs-human, stale (>180min) → must NOT enter NEW/DUE at all; appears
  # at most in the parked count. This is the exact bug measured 2026-08-05:
  # 11 of 20 flagged beads were self-declared parks re-alerted every cycle. ──
  echo "Scenario 16 (ga-cjk1j AC1 fixture): gate:queued+gate:needs-human, stale → NOT flagged as orphan, counted as PARK only"
  printf '[%s]' "$(mk_candidate cand-park1 "$TMP/hq" "gate:queued,gate:needs-human" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park1.json"
  NOTIF16="$TMP/notif16"; MAIL16="$TMP/mail16"; COMM16="$TMP/comm16"
  : > "$NOTIF16"; : > "$MAIL16"; : > "$COMM16"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF16" GOLW_TEST_MAILED="$MAIL16" GOLW_TEST_COMMENTS_LOG="$COMM16" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 16: park-labeled bead does not enter NEW/DUE (return 0)" || bad "scenario 16 (ga-cjk1j AC1 regression): a gate:needs-human bead was treated as an orphan-suspect, got $rc"
  [ ! -s "$COMM16" ] && ok "scenario 16: no comment posted on the parked bead" || bad "scenario 16: comment posted on a bead carrying gate:needs-human (should be excluded)"
  [ ! -s "$NOTIF16" ] && ok "scenario 16: no notify fired for a park-only sweep" || bad "scenario 16: notify fired despite only a parked bead being present"
  [ ! -s "$MAIL16" ] && ok "scenario 16: no mail fired for a park-only sweep" || bad "scenario 16: mail fired despite only a parked bead being present"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 16: log records the park count" || bad "scenario 16: log missing the PARK count line"
  grep -q "cand-park1" "$LOG" 2>/dev/null && ok "scenario 16: log names the parked bead" || bad "scenario 16: log does not name the parked bead cand-park1"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 17 (ga-cjk1j AC2, CONTROL — the real alert must not disappear):
  # a bead with gate:queued and NO park signal, stale → CONTINUES alerting
  # exactly as before this fix. If this fails, the fix blinded the watchdog,
  # which is worse than the bug it fixes. ──────────────────────────────────
  echo "Scenario 17 (ga-cjk1j AC2 control): gate:queued with NO park signal, stale → still flags exactly as before this fix"
  printf '[%s]' "$(mk_candidate cand-orphan1 "$TMP/hq" "gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-orphan1.json"
  NOTIF17="$TMP/notif17"; MAIL17="$TMP/mail17"; COMM17="$TMP/comm17"
  : > "$NOTIF17"; : > "$MAIL17"; : > "$COMM17"
  GOLW_TEST_NOTIFIED="$NOTIF17" GOLW_TEST_MAILED="$MAIL17" GOLW_TEST_COMMENTS_LOG="$COMM17" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 17: real orphan (no park signal) still flags (return 1)" || bad "scenario 17 (ga-cjk1j AC2 regression): the fix must not blind the watchdog to a genuine orphan, got $rc"
  grep -q "cand-orphan1" "$COMM17" 2>/dev/null && ok "scenario 17: comment posted on the real orphan" || bad "scenario 17 (ga-cjk1j AC2 regression): no comment on cand-orphan1 — the fix silenced a real alert"
  [ -s "$NOTIF17" ] && ok "scenario 17: notify still fires for a real orphan" || bad "scenario 17: notify did not fire for a real orphan"
  [ -s "$MAIL17" ] && ok "scenario 17: mail still fires for a real orphan" || bad "scenario 17: mail did not fire for a real orphan"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 18 (ga-cjk1j AC3, CONTROL2): status=blocked with NO
  # gate:needs-human/blocked-by label → still counts as park. 4 of the 11
  # known intentional parks in production carry status=blocked with no
  # needs-human label at all — a labels-only check would miss exactly these. ──
  echo "Scenario 18 (ga-cjk1j AC3 control2): status=blocked with NO gate:needs-human/blocked-by label → still counted as park, not orphan"
  printf '[{"id":"cand-park2","status":"blocked","updated_at":"%s","labels":["gate:queued"]}]' "$OLD_TS" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park2.json"
  NOTIF18="$TMP/notif18"; MAIL18="$TMP/mail18"; COMM18="$TMP/comm18"
  : > "$NOTIF18"; : > "$MAIL18"; : > "$COMM18"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF18" GOLW_TEST_MAILED="$MAIL18" GOLW_TEST_COMMENTS_LOG="$COMM18" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 18: status=blocked alone (no needs-human label) is still treated as park (return 0)" || bad "scenario 18 (ga-cjk1j AC3 regression): a status=blocked bead with no needs-human label was misflagged as orphan, got $rc"
  [ ! -s "$COMM18" ] && ok "scenario 18: no comment posted on the status=blocked bead" || bad "scenario 18: comment posted despite status=blocked"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 18: log records the park count for the status=blocked bead" || bad "scenario 18: log missing PARK count for a status=blocked-only park signal"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 19 (ga-cjk1j, mixed — mirrors the real production shape): 1
  # real orphan + 2 parked beads (one label-based, one status-based) in the
  # SAME sweep. Verifies the split doesn't cross-contaminate: the orphan must
  # still alert on its own merits, and neither park bead may leak into its
  # comment/mail, while both parks are counted together. ───────────────────
  echo "Scenario 19 (ga-cjk1j mixed): 1 real orphan + 2 parked beads (label-based and status-based) in the same sweep"
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-mix-orphan "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-mix-park1 "$TMP/hq" "gate:fix-attempt:1,gate:needs-human:technical" "$OLD_TS")" \
    "$(printf '{"id":"cand-mix-park2","status":"blocked","updated_at":"%s","labels":["gate:fix-attempt:1"]}' "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-orphan.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-park1.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix-park2.json"
  NOTIF19="$TMP/notif19"; MAIL19="$TMP/mail19"; COMM19="$TMP/comm19"
  : > "$NOTIF19"; : > "$MAIL19"; : > "$COMM19"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF19" GOLW_TEST_MAILED="$MAIL19" GOLW_TEST_COMMENTS_LOG="$COMM19" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 19: mixed sweep still flags the real orphan (return 1)" || bad "scenario 19: mixed sweep should flag cand-mix-orphan, got $rc"
  grep -q "cand-mix-orphan" "$COMM19" 2>/dev/null && ok "scenario 19: comment posted on the real orphan only" || bad "scenario 19: no comment on cand-mix-orphan"
  grep -q "cand-mix-park1" "$COMM19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): comment posted on a gate:needs-human-labeled park bead" || ok "scenario 19: no comment on the label-based park bead"
  grep -q "cand-mix-park2" "$COMM19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): comment posted on a status=blocked park bead" || ok "scenario 19: no comment on the status-based park bead"
  grep -q "+2 parado" "$MAIL19" 2>/dev/null && ok "scenario 19: mail summary counts both parked beads" || bad "scenario 19: mail summary missing the '+2 parado(s)' count"
  grep -q "cand-mix-park1" "$MAIL19" 2>/dev/null && bad "scenario 19 (ga-cjk1j regression): mail individually names a parked bead" || ok "scenario 19: mail does not individually name cand-mix-park1"
  grep -q "PARK: 2 bead" "$LOG" 2>/dev/null && ok "scenario 19: log records park_count=2" || bad "scenario 19: log missing PARK count of 2"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 20 (ga-tqe4j AC1+AC4, FIXTURE): a bead tracked in state drops
  # out of this sweep's candidate list AND its individual re-check query also
  # fails (the exact incident: 18 beads pruned RESOLVED while the sweep had
  # simply failed to re-observe them) → must stay in state, first_seen
  # UNCHANGED, and must NEVER be logged as RESOLVED. ─────────────────────────
  echo "Scenario 20 (ga-tqe4j AC1+AC4 fixture): bead vanishes from sweep AND its recheck query fails → stays in state, first_seen intact, never RESOLVED"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-r1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r1.json"
  GOLW_TEST_NOTIFIED="$TMP/notif20a" GOLW_TEST_MAILED="$TMP/mail20a" GOLW_TEST_COMMENTS_LOG="$TMP/comm20a" run_sweep >/dev/null
  STORE_REC="$(jq -r '.["cand-r1"].store // empty' "$STATE_FILE" 2>/dev/null)"
  [ "$STORE_REC" = "$TMP/hq" ] && ok "scenario 20: state records the correct store for cand-r1 (store-field regression check)" || bad "scenario 20 (store-field regression): expected store='$TMP/hq', got '$STORE_REC'"
  FIRST_SEEN_A="$(jq -r '.["cand-r1"].first_seen // empty' "$STATE_FILE" 2>/dev/null)"
  [ -n "$FIRST_SEEN_A" ] && ok "scenario 20: first_seen recorded after 1st sweep" || bad "scenario 20: first_seen missing after 1st sweep"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"                     # bead vanishes from the main sweep
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/recheck-cand-r1.json" # AND its individual recheck also fails
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif20b" GOLW_TEST_MAILED="$TMP/mail20b" GOLW_TEST_COMMENTS_LOG="$TMP/comm20b" run_sweep >/dev/null
  grep -q '"cand-r1"' "$STATE_FILE" 2>/dev/null && ok "scenario 20 (AC1): cand-r1 SURVIVES in state when its recheck query fails" || bad "scenario 20 (AC1 regression — the exact bug): cand-r1 was pruned from state despite an unverifiable recheck"
  FIRST_SEEN_B="$(jq -r '.["cand-r1"].first_seen // empty' "$STATE_FILE" 2>/dev/null)"
  [ "$FIRST_SEEN_B" = "$FIRST_SEEN_A" ] && ok "scenario 20 (AC4): first_seen unchanged across the degraded sweep" || bad "scenario 20 (AC4 regression): first_seen changed ($FIRST_SEEN_A -> $FIRST_SEEN_B) — age clock reset on a degraded sweep"
  grep -q "RESOLVED: cand-r1" "$LOG" 2>/dev/null && bad "scenario 20 (AC1 regression — the exact bug): cand-r1 logged as RESOLVED despite an unverifiable recheck" || ok "scenario 20: cand-r1 never logged as RESOLVED"
  grep -q "UNVERIFIED: cand-r1 re-check query failed" "$LOG" 2>/dev/null && ok "scenario 20: log reports cand-r1's recheck failure as unverified this run" || bad "scenario 20: log does not report cand-r1's recheck failure as unverified"
  rm -f "$TMP/fixtures/recheck-cand-r1.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 21 (ga-tqe4j AC2, CONTROL — must not regress): a bead whose
  # label genuinely disappeared, confirmed by its individual recheck → still
  # declared RESOLVED and pruned. If this breaks, state grows forever. ───────
  echo "Scenario 21 (ga-tqe4j AC2 control): bead's label genuinely cleared, recheck confirms it → still RESOLVED and pruned"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-r2 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r2.json"
  GOLW_TEST_NOTIFIED="$TMP/notif21a" GOLW_TEST_MAILED="$TMP/mail21a" GOLW_TEST_COMMENTS_LOG="$TMP/comm21a" run_sweep >/dev/null
  echo '[]' > "$TMP/fixtures/candidates-hq.json"        # bead vanishes from the main sweep
  printf '[%s]' "$(mk_candidate cand-r2 "$TMP/hq" "ctx:ready" "$OLD_TS")" > "$TMP/fixtures/recheck-cand-r2.json"  # recheck: label genuinely gone
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif21b" GOLW_TEST_MAILED="$TMP/mail21b" GOLW_TEST_COMMENTS_LOG="$TMP/comm21b" run_sweep >/dev/null
  grep -q '"cand-r2"' "$STATE_FILE" 2>/dev/null && bad "scenario 21 (AC2 regression): cand-r2 still lingers in state after a confirmed resolution" || ok "scenario 21 (AC2): cand-r2 pruned from state after a confirmed resolution"
  grep -q "RESOLVED: cand-r2" "$LOG" 2>/dev/null && ok "scenario 21 (AC2): cand-r2 logged as RESOLVED" || bad "scenario 21 (AC2 regression): cand-r2 not logged as RESOLVED despite a confirmed-cleared recheck"
  rm -f "$TMP/fixtures/recheck-cand-r2.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 22 (ga-tqe4j AC3 — the heart of the bug): re-run the AC1 and
  # AC2 conditions side by side in the SAME sweep and assert their outcomes
  # DIFFER. Before this fix both cases collapsed to the identical "RESOLVED,
  # pruned" verdict — that collapse, not either case alone, was the bug. ────
  echo "Scenario 22 (ga-tqe4j AC3): unverifiable-vs-confirmed-resolved must produce DIFFERENT outcomes in the same sweep"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s,%s]' \
    "$(mk_candidate cand-r3 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-r4 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r3.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r4.json"
  GOLW_TEST_NOTIFIED="$TMP/notif22a" GOLW_TEST_MAILED="$TMP/mail22a" GOLW_TEST_COMMENTS_LOG="$TMP/comm22a" run_sweep >/dev/null
  # cand-r3: same absence, UNVERIFIABLE recheck (store fails)
  # cand-r4: same absence, CONFIRMED-cleared recheck
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  printf '%s\n' "__BD_FAIL__" > "$TMP/fixtures/recheck-cand-r3.json"
  printf '[%s]' "$(mk_candidate cand-r4 "$TMP/hq" "ctx:ready" "$OLD_TS")" > "$TMP/fixtures/recheck-cand-r4.json"
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif22b" GOLW_TEST_MAILED="$TMP/mail22b" GOLW_TEST_COMMENTS_LOG="$TMP/comm22b" run_sweep >/dev/null
  R3_SURVIVES="no"; grep -q '"cand-r3"' "$STATE_FILE" 2>/dev/null && R3_SURVIVES="yes"
  R4_SURVIVES="no"; grep -q '"cand-r4"' "$STATE_FILE" 2>/dev/null && R4_SURVIVES="yes"
  [ "$R3_SURVIVES" != "$R4_SURVIVES" ] && ok "scenario 22 (AC3): unverifiable (cand-r3, kept=$R3_SURVIVES) and confirmed-resolved (cand-r4, kept=$R4_SURVIVES) produced DIFFERENT outcomes" || bad "scenario 22 (AC3 — the heart of the bug): both cases produced the SAME outcome (kept=$R3_SURVIVES for both) — absence-from-sweep and confirmed-clear are still indistinguishable"
  [ "$R3_SURVIVES" = "yes" ] && ok "scenario 22: the unverifiable one (cand-r3) is the one KEPT" || bad "scenario 22: cand-r3 (unverifiable) should be kept, was pruned"
  [ "$R4_SURVIVES" = "no" ] && ok "scenario 22: the confirmed-resolved one (cand-r4) is the one PRUNED" || bad "scenario 22: cand-r4 (confirmed resolved) should be pruned, still lingers"
  rm -f "$TMP/fixtures/recheck-cand-r3.json" "$TMP/fixtures/recheck-cand-r4.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 23 (ga-tqe4j, extra coverage — the "present" recheck path): a
  # bead drops out of the main sweep's candidate list but its individual
  # recheck shows the gate:* label is STILL there → must stay tracked, NOT be
  # declared resolved. ────────────────────────────────────────────────────────
  echo "Scenario 23 (ga-tqe4j extra): recheck confirms the label is STILL present → kept, not resolved"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-r5 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r5.json"
  GOLW_TEST_NOTIFIED="$TMP/notif23a" GOLW_TEST_MAILED="$TMP/mail23a" GOLW_TEST_COMMENTS_LOG="$TMP/comm23a" run_sweep >/dev/null
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  printf '[%s]' "$(mk_candidate cand-r5 "$TMP/hq" "gate:fix-attempt:2" "$OLD_TS")" > "$TMP/fixtures/recheck-cand-r5.json"
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif23b" GOLW_TEST_MAILED="$TMP/mail23b" GOLW_TEST_COMMENTS_LOG="$TMP/comm23b" run_sweep >/dev/null
  grep -q '"cand-r5"' "$STATE_FILE" 2>/dev/null && ok "scenario 23: cand-r5 stays tracked when its recheck still shows the gate:* label" || bad "scenario 23: cand-r5 was pruned despite its recheck confirming the label is still present"
  grep -q "RESOLVED: cand-r5" "$LOG" 2>/dev/null && bad "scenario 23 regression: cand-r5 logged RESOLVED despite still carrying the label" || ok "scenario 23: cand-r5 never logged as RESOLVED"
  rm -f "$TMP/fixtures/recheck-cand-r5.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 24 (ga-tqe4j, extra coverage — the "closed" recheck path): a
  # bead that got CLOSED (merged+closed, or manually closed) is no longer
  # "stuck in gate limbo" by definition — resolved regardless of label
  # residue. ───────────────────────────────────────────────────────────────
  echo "Scenario 24 (ga-tqe4j extra): bead closed → treated as resolved even if the label wasn't explicitly stripped"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate cand-r6 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-r6.json"
  GOLW_TEST_NOTIFIED="$TMP/notif24a" GOLW_TEST_MAILED="$TMP/mail24a" GOLW_TEST_COMMENTS_LOG="$TMP/comm24a" run_sweep >/dev/null
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  printf '[{"id":"cand-r6","status":"closed","updated_at":"%s","labels":["gate:fix-attempt:1"]}]' "$OLD_TS" > "$TMP/fixtures/recheck-cand-r6.json"
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif24b" GOLW_TEST_MAILED="$TMP/mail24b" GOLW_TEST_COMMENTS_LOG="$TMP/comm24b" run_sweep >/dev/null
  grep -q '"cand-r6"' "$STATE_FILE" 2>/dev/null && bad "scenario 24: cand-r6 still lingers in state after being closed" || ok "scenario 24: closed bead cand-r6 pruned from state"
  grep -q "RESOLVED: cand-r6" "$LOG" 2>/dev/null && ok "scenario 24: closed bead logged as RESOLVED" || bad "scenario 24: closed bead not logged as RESOLVED"
  rm -f "$TMP/fixtures/recheck-cand-r6.json"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 25 (ga-tqe4j, extra coverage — the MOST SEVERE form + migration
  # safety): a LEGACY state entry (store field empty — the exact shape the
  # Mayor found live, from before this fix) whose sweep comes back TOTALLY
  # empty (0 candidates from any store — the 100%-drop extreme of the same
  # bug) cannot be re-checked (no store on record) → must stay tracked rather
  # than be silently wiped by the empty-sweep fast path. ─────────────────────
  echo "Scenario 25 (ga-tqe4j extra): legacy pre-fix state entry (empty store field), sweep totally empty → kept, not resolved, not wiped"
  rm -f "$STATE_FILE" 2>/dev/null
  mkdir -p "$GOLW_STATE_DIR"
  printf '{"cand-r7":{"first_seen":1700000000,"last_alert":1700000000,"store":""}}' > "$STATE_FILE"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif25" GOLW_TEST_MAILED="$TMP/mail25" GOLW_TEST_COMMENTS_LOG="$TMP/comm25" run_sweep >/dev/null
  grep -q '"cand-r7"' "$STATE_FILE" 2>/dev/null && ok "scenario 25: legacy entry with no store on record is kept (cannot verify, fail-safe) even on a totally-empty sweep" || bad "scenario 25 (migration-safety regression): a legacy entry with no recorded store was wiped by the empty-sweep fast path without any re-check"
  grep -q "RESOLVED: cand-r7" "$LOG" 2>/dev/null && bad "scenario 25 regression: legacy entry logged RESOLVED without ever being re-checked" || ok "scenario 25: legacy entry never logged as RESOLVED"
  grep -q "STATE CLEARED" "$LOG" 2>/dev/null && bad "scenario 25 (the total-wipe form of the bug): log shows a blind STATE CLEARED despite an unverifiable tracked bead" || ok "scenario 25: no blind STATE CLEARED — the totally-empty sweep did not bypass verification"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 11: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 11: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 11: bash -n passes" || bad "scenario 11: bash -n FAILED — syntax error"

  # ── Scenario 26 (ga-y0g5x): single-instance lock — two REAL concurrent
  # invocations of the actual script ENTRY POINT (the lock guards the entry
  # point, not the run_sweep function, so this must fire real subprocesses —
  # a background `&` job is a genuine separate OS process — not call
  # run_sweep in-process like every scenario above). AC: the second run must
  # exit without working AND without alarming.
  echo "Scenario 26 (ga-y0g5x): two concurrent real invocations — exactly one proceeds, the other backs off silently"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  LOCKTEST26="$TMP/locktest26"; mkdir -p "$LOCKTEST26/tmp" "$LOCKTEST26/state"
  SHARED_LOG26="$LOCKTEST26/golw.log"; : > "$SHARED_LOG26"
  run_golw_race26() {
    env -i \
      PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
      HOME="$HOME" \
      TMPDIR="$LOCKTEST26/tmp" \
      GOLW_ENABLED=1 GOLW_LOCK_ENABLED=1 GOLW_DRY_RUN=0 \
      GOLW_TEST_MODE=1 \
      GOLW_HQ="$HQ" \
      GOLW_LOG="$SHARED_LOG26" \
      GOLW_NOTIFY_BIN="$NOTIFY_BIN" \
      GOLW_GC_BIN="$GC_BIN" \
      GOLW_BD_BIN="$BD_BIN" \
      GOLW_STATE_DIR="$LOCKTEST26/state" \
      GOLW_STORES="$GOLW_STORES" \
      GOLW_TEST_FIXTURES_DIR="$GOLW_TEST_FIXTURES_DIR" \
      bash "$0" >/dev/null 2>&1 || true
  }
  run_golw_race26 &
  RG26_1=$!
  run_golw_race26 &
  RG26_2=$!
  wait "$RG26_1" "$RG26_2"
  RAN26=$(grep -cE "OK:|FLAGGED:" "$SHARED_LOG26" 2>/dev/null | tr -d ' '); RAN26=${RAN26:-0}
  BACKOFF26=$(grep -c "backing off (single-instance guard" "$SHARED_LOG26" 2>/dev/null | tr -d ' '); BACKOFF26=${BACKOFF26:-0}
  [ "$RAN26" -eq 1 ] && ok "scenario 26: exactly one of two concurrent runs executed the sweep ($RAN26)" || bad "scenario 26: expected exactly 1 run to execute the sweep, got $RAN26 — double-run or zero-run"
  [ "$BACKOFF26" -eq 1 ] && ok "scenario 26: exactly one run backed off on the live lock, silently ($BACKOFF26)" || bad "scenario 26: expected exactly 1 back-off, got $BACKOFF26"
  rm -rf "$LOCKTEST26"

  # ── Scenario 27 (ga-y0g5x): a lock held by a DEAD pid, with a FRESH
  # heartbeat mtime, is reclaimed IMMEDIATELY — proving the reclaim is
  # PID-liveness-gated, not merely age-gated. An age-only check would let a
  # killed run's lock block every future sweep for GOLW_LOCK_MAX_AGE (up to
  # 900s default) — the exact failure mode the bug calls out ("o modo de
  # falha que troca 'sobreposicao' por 'nunca mais roda'").
  echo "Scenario 27 (ga-y0g5x): lock held by a DEAD pid (fresh mtime) is reclaimed immediately, not after MAX_AGE"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  LOCKTEST27="$TMP/locktest27"; mkdir -p "$LOCKTEST27/tmp"
  LOCK27_DIR="$LOCKTEST27/tmp/gate-orphaned-label-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
  mkdir -p "$LOCK27_DIR"
  ( : ) & DEADPID27=$!
  wait "$DEADPID27" 2>/dev/null
  printf '%s:1\n' "$DEADPID27" > "$LOCK27_DIR/heartbeat"   # fresh mtime, dead pid
  LOG27="$LOCKTEST27/golw.log"; : > "$LOG27"
  env -i \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    HOME="$HOME" \
    TMPDIR="$LOCKTEST27/tmp" \
    GOLW_ENABLED=1 GOLW_LOCK_ENABLED=1 GOLW_DRY_RUN=0 \
    GOLW_LOCK_MAX_AGE=900 \
    GOLW_TEST_MODE=1 \
    GOLW_HQ="$HQ" \
    GOLW_LOG="$LOG27" \
    GOLW_NOTIFY_BIN="$NOTIFY_BIN" \
    GOLW_GC_BIN="$GC_BIN" \
    GOLW_BD_BIN="$BD_BIN" \
    GOLW_STATE_DIR="$LOCKTEST27/state" \
    GOLW_STORES="$GOLW_STORES" \
    GOLW_TEST_FIXTURES_DIR="$GOLW_TEST_FIXTURES_DIR" \
    bash "$0" >/dev/null 2>&1
  grep -qE "OK:|FLAGGED:" "$LOG27" 2>/dev/null && ok "scenario 27: dead-pid lock reclaimed immediately, sweep ran" || bad "scenario 27: dead-pid lock blocked the run — a killed holder would wedge the watchdog forever"
  grep -q "Recovered STALE/DEAD lock" "$LOG27" 2>/dev/null && ok "scenario 27: reclaim logged" || bad "scenario 27: no reclaim log line"
  rm -rf "$LOCKTEST27"

  # ── Scenario 28 (ga-y0g5x GATE-FEEDBACK, mirror of 27): a lock held by an
  # ALIVE pid, with a heartbeat mtime backdated PAST MAX_AGE, must NOT be
  # reclaimed by a second run — proving reclaim is gated on PID liveness
  # alone, never on age. This is the exact case the gate reviewer found
  # unexercised: scenario 27 only proved "dead + fresh mtime → reclaim";
  # this proves the missing mirror, "alive + stale mtime → NEVER reclaim" —
  # the case where the original bug's fix-attempt-1 broke.
  echo "Scenario 28 (ga-y0g5x GATE-FEEDBACK): lock held by an ALIVE pid with a heartbeat mtime OLDER than MAX_AGE is NEVER reclaimed (age must not override liveness)"
  echo '[]' > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  LOCKTEST28="$TMP/locktest28"; mkdir -p "$LOCKTEST28/tmp"
  LOCK28_DIR="$LOCKTEST28/tmp/gate-orphaned-label-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
  mkdir -p "$LOCK28_DIR"
  sleep 30 & ALIVEPID28=$!
  printf '%s:1\n' "$ALIVEPID28" > "$LOCK28_DIR/heartbeat"
  OLD28="$(date -v-20M +%Y%m%d%H%M.%S 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M.%S)"
  touch -t "$OLD28" "$LOCK28_DIR/heartbeat"
  LOG28="$LOCKTEST28/golw.log"; : > "$LOG28"
  env -i \
    PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    HOME="$HOME" \
    TMPDIR="$LOCKTEST28/tmp" \
    GOLW_ENABLED=1 GOLW_LOCK_ENABLED=1 GOLW_DRY_RUN=0 \
    GOLW_LOCK_MAX_AGE=900 \
    GOLW_TEST_MODE=1 \
    GOLW_HQ="$HQ" \
    GOLW_LOG="$LOG28" \
    GOLW_NOTIFY_BIN="$NOTIFY_BIN" \
    GOLW_GC_BIN="$GC_BIN" \
    GOLW_BD_BIN="$BD_BIN" \
    GOLW_STATE_DIR="$LOCKTEST28/state" \
    GOLW_STORES="$GOLW_STORES" \
    GOLW_TEST_FIXTURES_DIR="$GOLW_TEST_FIXTURES_DIR" \
    bash "$0" >/dev/null 2>&1
  kill "$ALIVEPID28" 2>/dev/null; wait "$ALIVEPID28" 2>/dev/null
  grep -qE "OK:|FLAGGED:" "$LOG28" 2>/dev/null && bad "scenario 28: sweep RAN despite a live holder with a stale heartbeat — age wrongly overrode liveness (the exact GATE-FEEDBACK regression)" || ok "scenario 28: sweep did NOT run — live holder protected despite a stale heartbeat"
  grep -q "backing off (single-instance guard" "$LOG28" 2>/dev/null && ok "scenario 28: second run backed off silently, as required" || bad "scenario 28: no back-off log line — second run may not have deferred correctly"
  rm -rf "$LOCKTEST28"

  # ── Scenario 29 (ga-te41ft, FIXTURE — REPROVES on HEAD before this fix): a
  # bead carrying blocked:sem-prioridade (colon, the town's real self-park
  # label — distinct from blocked-by:*, a dependency pointer already handled
  # since ga-cjk1j) alongside real gate:* lifecycle labels, stale → must NOT
  # enter NEW/DUE at all; counted as PARK only. Mirrors the exact shape of the
  # live victim (wa-kty2h): [blocked:sem-prioridade, story:approved,
  # gate:failed, gate:fix-attempt:2, gate:needs-fix]. Before this fix, is_park
  # only checked blocked-by:* (hyphen) — blocked:* (colon) fell through and
  # this bead alerted every cooldown cycle despite being a deliberate,
  # correct park on an open dependency. ─────────────────────────────────────
  echo "Scenario 29 (ga-te41ft fixture): blocked:sem-prioridade (colon) + gate:* labels, stale → NOT flagged as orphan, counted as PARK only"
  printf '[%s]' "$(mk_candidate cand-park3 "$TMP/hq" "blocked:sem-prioridade,story:approved,gate:failed,gate:fix-attempt:2,gate:needs-fix" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park3.json"
  NOTIF29="$TMP/notif29"; MAIL29="$TMP/mail29"; COMM29="$TMP/comm29"
  : > "$NOTIF29"; : > "$MAIL29"; : > "$COMM29"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF29" GOLW_TEST_MAILED="$MAIL29" GOLW_TEST_COMMENTS_LOG="$COMM29" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 29: blocked:-labeled bead does not enter NEW/DUE (return 0)" || bad "scenario 29 (ga-te41ft regression — the exact bug): a blocked:sem-prioridade bead was treated as an orphan-suspect, got $rc"
  [ ! -s "$COMM29" ] && ok "scenario 29: no comment posted on the blocked:-parked bead" || bad "scenario 29 (ga-te41ft regression): comment posted on a bead carrying blocked:sem-prioridade (should be excluded)"
  [ ! -s "$NOTIF29" ] && ok "scenario 29: no notify fired for a blocked:-park-only sweep" || bad "scenario 29: notify fired despite only a blocked:-parked bead being present"
  [ ! -s "$MAIL29" ] && ok "scenario 29: no mail fired for a blocked:-park-only sweep" || bad "scenario 29: mail fired despite only a blocked:-parked bead being present"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 29: log records the park count for the blocked:-labeled bead" || bad "scenario 29: log missing the PARK count line for a blocked:-labeled park"
  grep -q "cand-park3" "$LOG" 2>/dev/null && ok "scenario 29: log names the blocked:-parked bead" || bad "scenario 29: log does not name the parked bead cand-park3"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 30 (ga-te41ft, CONTROL — blocked-by:* must keep meaning
  # "dependency pointer", NOT self-park, per context-check-dispatcher.sh's
  # ga-7mbry convention this file already shares): a bead carrying ONLY
  # blocked-by:<id> with no gate:needs-human/blocked:/status=blocked signal is
  # already parked today (ga-cjk1j) — this fix must not change that. ────────
  echo "Scenario 30 (ga-te41ft control): blocked-by:<id> alone still parks exactly as before this fix (no regression on the ga-cjk1j behavior)"
  printf '[%s]' "$(mk_candidate cand-park4 "$TMP/hq" "blocked-by:wa-v8rkm,gate:queued" "$OLD_TS")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-park4.json"
  NOTIF30="$TMP/notif30"; MAIL30="$TMP/mail30"; COMM30="$TMP/comm30"
  : > "$NOTIF30"; : > "$MAIL30"; : > "$COMM30"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF30" GOLW_TEST_MAILED="$MAIL30" GOLW_TEST_COMMENTS_LOG="$COMM30" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 30: blocked-by:-labeled bead still does not enter NEW/DUE (return 0)" || bad "scenario 30 (regression on ga-cjk1j behavior): a blocked-by: bead was treated as an orphan-suspect, got $rc"
  [ ! -s "$COMM30" ] && ok "scenario 30: no comment posted on the blocked-by:-parked bead" || bad "scenario 30: comment posted on a bead carrying blocked-by: (should still be excluded)"
  rm -f "$STATE_FILE" 2>/dev/null

  # ── Scenario 31 (ga-eiaidn AC1 FIXTURE — reproduces the exact wa-nxwqw
  # shape): a bead status=in_progress, assignee is a crew-style role name,
  # stale (>180min), gate:* labels, with a session VERIFIED alive in the
  # roster (matched via .agent_name/.alias/.template — NOT .session_name,
  # which carries an unrelated per-spawn suffix, mirroring the real
  # oracle-wa production shape measured live 2026-08-16) → must NOT enter
  # NEW/DUE; counted as ACTIVE only. ─────────────────────────────────────
  echo "Scenario 31 (ga-eiaidn AC1 fixture): in_progress bead with a session-verified-live assignee → NOT flagged as orphan, counted as ACTIVE only"
  printf '[%s]' "$(mk_candidate_inprogress cand-live1 "$TMP/hq" "gate:failed,gate:fix-attempt:2,gate:needs-fix" "$OLD_TS" "oracle-wa")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-live1.json"
  echo '{"sessions":[{"name":"oracle-wa","agent_name":"oracle-wa","alias":"oracle-wa","template":"oracle-wa","session_name":"oracle-wa-awisp9z8x1","state":"active"}]}' > "$TMP/fixtures/sessions-active.json"
  NOTIF31="$TMP/notif31"; MAIL31="$TMP/mail31"; COMM31="$TMP/comm31"
  : > "$NOTIF31"; : > "$MAIL31"; : > "$COMM31"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF31" GOLW_TEST_MAILED="$MAIL31" GOLW_TEST_COMMENTS_LOG="$COMM31" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 31: in_progress bead with a live-verified assignee does not enter NEW/DUE (return 0)" || bad "scenario 31 (ga-eiaidn AC1 regression — the exact wa-nxwqw bug): a bead with a verified-live assignee was treated as an orphan-suspect, got $rc"
  [ ! -s "$COMM31" ] && ok "scenario 31: no comment posted on the active-live bead" || bad "scenario 31: comment posted on a bead with a verified-live assignee (should be excluded)"
  [ ! -s "$NOTIF31" ] && ok "scenario 31: no notify fired for an active-live-only sweep" || bad "scenario 31: notify fired despite only an active-live bead being present"
  [ ! -s "$MAIL31" ] && ok "scenario 31: no mail fired for an active-live-only sweep" || bad "scenario 31: mail fired despite only an active-live bead being present"
  grep -q "ACTIVE: 1 bead" "$LOG" 2>/dev/null && ok "scenario 31: log records the active-live count" || bad "scenario 31: log missing the ACTIVE count line"
  grep -q "cand-live1" "$LOG" 2>/dev/null && ok "scenario 31: log names the active-live bead" || bad "scenario 31: log does not name the active-live bead cand-live1"
  rm -f "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  # ── Scenario 32 (ga-eiaidn AC2 CONTROL — the real-orphan control that
  # keeps 31 honest): same in_progress+assignee shape, but the assignee is
  # NOT present in the active-session roster (dead/crashed session) → must
  # continue alerting exactly as before this fix. If this fails, the fix
  # blinded the watchdog to a genuine orphan — worse than the bug it fixes
  # (bug body, criterio de aceite #2). ──────────────────────────────────────
  echo "Scenario 32 (ga-eiaidn AC2 control): in_progress bead with a DEAD assignee (absent from active roster) → still flags exactly as before this fix"
  printf '[%s]' "$(mk_candidate_inprogress cand-dead1 "$TMP/hq" "gate:failed,gate:fix-attempt:2,gate:needs-fix" "$OLD_TS" "oracle-wa")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-dead1.json"
  echo '{"sessions":[{"name":"mila-wa","agent_name":"mila-wa","alias":"mila-wa","template":"mila-wa","session_name":"mila-wa-awispother","state":"active"}]}' > "$TMP/fixtures/sessions-active.json"
  NOTIF32="$TMP/notif32"; MAIL32="$TMP/mail32"; COMM32="$TMP/comm32"
  : > "$NOTIF32"; : > "$MAIL32"; : > "$COMM32"
  GOLW_TEST_NOTIFIED="$NOTIF32" GOLW_TEST_MAILED="$MAIL32" GOLW_TEST_COMMENTS_LOG="$COMM32" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 32: in_progress bead with a dead assignee still flags (return 1)" || bad "scenario 32 (ga-eiaidn AC2 regression): a dead-assignee in_progress bead was wrongly excluded, got $rc"
  grep -q "cand-dead1" "$COMM32" 2>/dev/null && ok "scenario 32: comment posted on the dead-assignee orphan" || bad "scenario 32 (ga-eiaidn AC2 regression): no comment on cand-dead1 — the fix silenced a real alert"
  [ -s "$NOTIF32" ] && ok "scenario 32: notify still fires for a dead-assignee orphan" || bad "scenario 32: notify did not fire for a dead-assignee orphan"
  rm -f "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  # ── Scenario 33 (ga-eiaidn AC2 CONTROL2 — the crux of the inverted
  # fail-direction): the `gc session list` query itself fails (e.g. gc down,
  # transient error) → liveness is UNVERIFIABLE, and per this bug's own
  # explicit caution (criterio de aceite #4: "a wrong 'declared alive' is
  # worse than the noise this bug is about"), unverifiable must resolve to
  # NOT-alive — still alerts exactly as before this fix, the OPPOSITE
  # direction from every other fail-open probe in this file. ───────────────
  echo "Scenario 33 (ga-eiaidn AC2 control2): gc session list query FAILS → liveness unverifiable, still flags (inverted fail-direction from the rest of this file)"
  printf '[%s]' "$(mk_candidate_inprogress cand-unk1 "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS" "oracle-wa")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-unk1.json"
  printf '%s\n' "__GC_FAIL__" > "$TMP/fixtures/sessions-active.json"
  NOTIF33="$TMP/notif33"; MAIL33="$TMP/mail33"; COMM33="$TMP/comm33"
  : > "$NOTIF33"; : > "$MAIL33"; : > "$COMM33"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF33" GOLW_TEST_MAILED="$MAIL33" GOLW_TEST_COMMENTS_LOG="$COMM33" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 33: unreadable session roster → still flags (return 1)" || bad "scenario 33 (ga-eiaidn AC2 regression — the exact wrong-direction bug): an unverifiable liveness check was treated as confirmed-alive, got $rc"
  grep -q "cand-unk1" "$COMM33" 2>/dev/null && ok "scenario 33: comment posted despite the unreadable roster" || bad "scenario 33: no comment on cand-unk1 — an unreadable roster wrongly suppressed a real alert"
  grep -q "WARN: gc session list failed" "$LOG" 2>/dev/null && ok "scenario 33: WARN logged for the failed session-list query" || bad "scenario 33: no WARN logged for the failed gc session list query"
  rm -f "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  # ── Scenario 34 (ga-eiaidn control — status gating): a bead whose
  # assignee matches a live session, but the bead's own status is "open"
  # (not "in_progress") → the exclusion must NOT fire. This proves the new
  # check is scoped to in_progress specifically, not "any bead whose
  # assignee happens to be a live session name." ───────────────────────────
  echo "Scenario 34 (ga-eiaidn control): status=open (not in_progress) bead with a live-matching assignee still flags — exclusion is status-gated"
  printf '[{"id":"cand-open-live","status":"open","assignee":"oracle-wa","updated_at":"%s","labels":["gate:queued"]}]' "$OLD_TS" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-open-live.json"
  echo '{"sessions":[{"name":"oracle-wa","agent_name":"oracle-wa","alias":"oracle-wa","template":"oracle-wa","session_name":"oracle-wa-awisp9z8x1","state":"active"}]}' > "$TMP/fixtures/sessions-active.json"
  NOTIF34="$TMP/notif34"; MAIL34="$TMP/mail34"; COMM34="$TMP/comm34"
  : > "$NOTIF34"; : > "$MAIL34"; : > "$COMM34"
  GOLW_TEST_NOTIFIED="$NOTIF34" GOLW_TEST_MAILED="$MAIL34" GOLW_TEST_COMMENTS_LOG="$COMM34" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 34: status=open bead with a live-matching assignee still flags (return 1)" || bad "scenario 34 (regression): the active-live exclusion fired on a non-in_progress bead, got $rc"
  grep -q "cand-open-live" "$COMM34" 2>/dev/null && ok "scenario 34: comment posted — status=open is not exempted by this fix" || bad "scenario 34: no comment on cand-open-live — the exclusion wrongly applied to a non-in_progress bead"
  rm -f "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  # ── Scenario 35 (ga-eiaidn mixed, mirrors Scenario 19's style): 1 real
  # orphan + 1 parked bead + 1 active-live bead in the SAME sweep. Verifies
  # the three-way split doesn't cross-contaminate: the orphan alerts on its
  # own merits, neither excluded bead leaks into its comment/mail, and both
  # exclusion counts are correct and independent. ──────────────────────────
  echo "Scenario 35 (ga-eiaidn mixed): 1 real orphan + 1 parked bead + 1 active-live bead in the same sweep"
  printf '[%s,%s,%s]' \
    "$(mk_candidate cand-mix2-orphan "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS")" \
    "$(mk_candidate cand-mix2-park "$TMP/hq" "gate:fix-attempt:1,gate:needs-human:technical" "$OLD_TS")" \
    "$(mk_candidate_inprogress cand-mix2-live "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS" "oracle-wa")" \
    > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix2-orphan.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix2-park.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-mix2-live.json"
  echo '{"sessions":[{"name":"oracle-wa","agent_name":"oracle-wa","alias":"oracle-wa","template":"oracle-wa","session_name":"oracle-wa-awisp9z8x1","state":"active"}]}' > "$TMP/fixtures/sessions-active.json"
  NOTIF35="$TMP/notif35"; MAIL35="$TMP/mail35"; COMM35="$TMP/comm35"
  : > "$NOTIF35"; : > "$MAIL35"; : > "$COMM35"; : > "$LOG"
  GOLW_TEST_NOTIFIED="$NOTIF35" GOLW_TEST_MAILED="$MAIL35" GOLW_TEST_COMMENTS_LOG="$COMM35" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 35: mixed sweep still flags the real orphan (return 1)" || bad "scenario 35: mixed sweep should flag cand-mix2-orphan, got $rc"
  grep -q "cand-mix2-orphan" "$COMM35" 2>/dev/null && ok "scenario 35: comment posted on the real orphan only" || bad "scenario 35: no comment on cand-mix2-orphan"
  grep -q "cand-mix2-park" "$COMM35" 2>/dev/null && bad "scenario 35 (regression): comment posted on the parked bead" || ok "scenario 35: no comment on the parked bead"
  grep -q "cand-mix2-live" "$COMM35" 2>/dev/null && bad "scenario 35 (regression): comment posted on the active-live bead" || ok "scenario 35: no comment on the active-live bead"
  grep -q "PARK: 1 bead" "$LOG" 2>/dev/null && ok "scenario 35: log records park_count=1" || bad "scenario 35: log missing PARK count of 1"
  grep -q "ACTIVE: 1 bead" "$LOG" 2>/dev/null && ok "scenario 35: log records active_count=1" || bad "scenario 35: log missing ACTIVE count of 1"
  grep -q "cand-mix2-park" "$MAIL35" 2>/dev/null && bad "scenario 35 (regression): mail individually names the parked bead" || ok "scenario 35: mail does not individually name cand-mix2-park"
  grep -q "cand-mix2-live" "$MAIL35" 2>/dev/null && bad "scenario 35 (regression): mail individually names the active-live bead" || ok "scenario 35: mail does not individually name cand-mix2-live"
  rm -f "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  # ── Scenario 36 (ga-eiaidn × ga-tqe4j interaction — defensive check, not
  # required by the bug's own AC but this file's history makes it cheap
  # insurance): a bead tracked in state from a sweep where its assignee was
  # DEAD, then the SAME bead transitions to a verified-live assignee on the
  # next sweep. Its gate:* labels are UNCHANGED throughout — only its
  # liveness verdict changed — so it must NOT be declared RESOLVED (that
  # would be the exact ga-tqe4j class of mistake: absence-from-flagged-set
  # misread as "confirmed cleared"). It should simply stop re-alerting
  # (excluded via the ACTIVE bucket) while staying tracked/UNVERIFIED. ─────
  echo "Scenario 36 (ga-eiaidn x ga-tqe4j): bead transitions dead-assignee -> live-assignee across sweeps → NOT declared RESOLVED"
  rm -f "$STATE_FILE" 2>/dev/null
  printf '[%s]' "$(mk_candidate_inprogress cand-transition "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS" "oracle-wa")" > "$TMP/fixtures/candidates-hq.json"
  echo '[]' > "$TMP/fixtures/candidates-wa.json"
  echo '[]' > "$TMP/fixtures/artifacts-cand-transition.json"
  echo '{"sessions":[]}' > "$TMP/fixtures/sessions-active.json"
  GOLW_TEST_NOTIFIED="$TMP/notif36a" GOLW_TEST_MAILED="$TMP/mail36a" GOLW_TEST_COMMENTS_LOG="$TMP/comm36a" run_sweep >/dev/null
  [ -s "$STATE_FILE" ] && ok "scenario 36: state file written after 1st sweep (dead assignee, real alert)" || bad "scenario 36: state file missing after 1st sweep"
  echo '{"sessions":[{"name":"oracle-wa","agent_name":"oracle-wa","alias":"oracle-wa","template":"oracle-wa","session_name":"oracle-wa-awispnew","state":"active"}]}' > "$TMP/fixtures/sessions-active.json"
  # recheck fixture: _bead_recheck_status only reads status/labels — the
  # gate:* label is still there (assignee liveness isn't part of that
  # check), so a correct implementation must report "present", not "gone".
  printf '[%s]' "$(mk_candidate_inprogress cand-transition "$TMP/hq" "gate:fix-attempt:1" "$OLD_TS" "oracle-wa")" > "$TMP/fixtures/recheck-cand-transition.json"
  : > "$LOG"
  GOLW_TEST_NOTIFIED="$TMP/notif36b" GOLW_TEST_MAILED="$TMP/mail36b" GOLW_TEST_COMMENTS_LOG="$TMP/comm36b" run_sweep >/dev/null
  grep -q '"cand-transition"' "$STATE_FILE" 2>/dev/null && ok "scenario 36: cand-transition SURVIVES in state after becoming active-live (not wiped)" || bad "scenario 36 (ga-tqe4j-class regression): cand-transition was pruned from state after merely becoming active-live"
  grep -q "RESOLVED: cand-transition" "$LOG" 2>/dev/null && bad "scenario 36 (ga-tqe4j-class regression — the exact bug): cand-transition logged as RESOLVED merely because its assignee became live" || ok "scenario 36: cand-transition never logged as RESOLVED"
  grep -q "ACTIVE: 1 bead" "$LOG" 2>/dev/null && ok "scenario 36: 2nd sweep logs it under ACTIVE (no longer re-alerting)" || bad "scenario 36: 2nd sweep did not record the active-live count"
  [ ! -s "$TMP/comm36b" ] && ok "scenario 36: no NEW comment posted on the 2nd sweep" || bad "scenario 36: a comment was posted on the 2nd sweep despite the assignee now being live"
  rm -f "$TMP/fixtures/recheck-cand-transition.json" "$STATE_FILE" "$TMP/fixtures/sessions-active.json" 2>/dev/null

  echo ""
  echo "gate-orphaned-label-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

# ── Single-instance lock (ga-y0g5x) ────────────────────────────────────────
# REGRESSION 2026-08-06 (Mayor): the sibling pilot-missing-route-watchdog.sh
# was found overlapping 4-way (StartInterval < one full sweep's duration, so
# launchd never serializes) and stacking Dolt queries badly enough to throw
# bd's `bd` client city-wide. The SAME measurement found this watchdog with
# 3 simultaneous instances — same pre-existing defect, same fix applied here.
#
# Same lock shape quality-gate-dispatcher.sh already uses in this city (don't
# invent another, per the bug's own instruction): an atomic mkdir mutex +
# heartbeat mtime for staleness + PID-liveness for a KILLED holder (mtime
# alone would still look "fresh" for up to GOLW_LOCK_MAX_AGE after a kill —
# ga-T1 #7's own lesson) + a sentinel-gated reclaim that overwrites the stale
# heartbeat IN PLACE — the lock dir is never renamed away, so there is no
# window where the path is briefly absent for a TOCTOU double-acquisition
# (ga-T1 #4's own lesson).
#
# GATE-FEEDBACK FIX (gate_run=ga-wisp-ohox1gs, fix-attempt 1, same review
# that flagged the pilot-missing-route-watchdog.sh twin): the first cut of
# this lock gated reclaim on `age < MAX_AGE && holder alive` — which backs
# off ONLY when BOTH are true, so an old-but-genuinely-ALIVE holder (a
# legitimately slow multi-store sweep under sustained Dolt degradation —
# exactly the condition that caused the original 3-instance incident) fell
# through to reclaim and got its lock STOLEN, reproducing the double-run bug
# this fix exists to prevent. Three states, resolved by PID-liveness ALONE —
# age is NOT a gating input at all:
#   holder ALIVE   → NEVER reclaim, regardless of heartbeat age. Age doesn't
#                    kill anyone; only a confirmed-dead PID does.
#   holder DEAD    → reclaim immediately, regardless of heartbeat age (a
#                    killed run's lock must not wedge the watchdog forever —
#                    proven by scenario 27's dead-pid+fresh-mtime case).
#   liveness UNKNOWN (malformed/empty heartbeat token) → treated as ALIVE by
#                    _golw_lock_holder_dead's own existing safe default →
#                    never reclaim. Safe direction under doubt: at worst the
#                    watchdog loses a cycle; stealing a live lock corrupts
#                    the other run.
# quality-gate-dispatcher.sh's own age-gated fallback is safe ONLY because
# its live holder re-stamps the heartbeat every verdict poll, so MAX_AGE is
# practically unreachable while genuinely progressing — that compensating
# mechanism did not get ported when this lock was first written here. This
# fix (1) drops age as a reclaim GATE entirely — liveness is the sole
# authority — and (2) still adds a heartbeat re-stamp during run_sweep's
# per-store loop (mirroring the reference file for real this time) as
# defense-in-depth/diagnostic value; (1) alone already closes the reported
# hole, since a single hung bd call mid-sweep could otherwise cross MAX_AGE
# while the holder is still legitimately (if silently) alive.
#
# A LIVE holder makes the second run exit 0 SILENTLY — not an error, pure
# serialization, no comment/notify/mail. A DEAD holder (PID no longer
# running) is reclaimed immediately regardless of heartbeat age — an
# age-only check would let a killed run's zombie lock block every future
# sweep for up to GOLW_LOCK_MAX_AGE, trading "overlap" for "never runs
# again."
GOLW_LOCK_ENABLED="${GOLW_LOCK_ENABLED:-1}"
GOLW_LOCK_DIR="${TMPDIR:-/tmp}/gate-orphaned-label-watchdog$(printf '%s' "$HQ" | tr '/ ' '__').lock.d"
GOLW_LOCK_HB="$GOLW_LOCK_DIR/heartbeat"
# A full multi-store sweep normally takes seconds; this margin still reclaims
# a wedged holder within a couple of launchd intervals.
GOLW_LOCK_MAX_AGE="${GOLW_LOCK_MAX_AGE:-900}"
GOLW_LOCK_REAP_TTL="${GOLW_LOCK_REAP_TTL:-10}"
GOLW_LOCK_TOKEN="${GOLW_LOCK_TOKEN:-$$:${RANDOM}${RANDOM}}"

_golw_lock_path_age() {
  local _p="$1" _mt _now
  _now=$(date +%s)
  _mt=$(stat -f %m "$_p" 2>/dev/null || stat -c %Y "$_p" 2>/dev/null || echo "")
  [ -z "$_mt" ] && { echo 999999999; return; }
  echo $(( _now - _mt ))
}
_golw_lock_hb_age() { _golw_lock_path_age "$GOLW_LOCK_HB"; }

# Empty/non-numeric token → treat as ALIVE (do not fast-reclaim); PID reuse
# only falls back to the (still-bounded) mtime path, never a wrong reclaim of
# a genuinely live holder.
_golw_lock_holder_dead() {
  local _pid
  _pid=$(head -n1 "$GOLW_LOCK_HB" 2>/dev/null | cut -d: -f1 || true)
  case "$_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$_pid" 2>/dev/null && return 1
  return 0
}

_golw_lock_write_hb() { printf '%s\n' "$GOLW_LOCK_TOKEN" > "$GOLW_LOCK_HB" 2>/dev/null || true; }

# Remove the lock dir only if WE still own it (token match) — never clobber a
# peer that recovered our lock after we were (wrongly) judged stale.
_release_golw_lock() {
  local _own
  _own=$(head -n1 "$GOLW_LOCK_HB" 2>/dev/null || true)
  [ "$_own" = "$GOLW_LOCK_TOKEN" ] && rm -rf "$GOLW_LOCK_DIR" 2>/dev/null
  return 0
}

# Returns 0 if we own the lock, 1 if a LIVE run holds it (caller backs off).
_acquire_golw_lock() {
  if mkdir "$GOLW_LOCK_DIR" 2>/dev/null; then
    _golw_lock_write_hb
    if [ ! -s "$GOLW_LOCK_HB" ]; then
      rm -rf "$GOLW_LOCK_DIR" 2>/dev/null || true
      return 1
    fi
    return 0
  fi
  local _age
  _age=$(_golw_lock_hb_age)
  # Liveness ALONE gates reclaim — age is never a gating input (see header:
  # age-OR-dead let an old-but-alive holder get its lock stolen). _age is
  # still computed/logged below purely for diagnostics.
  if ! _golw_lock_holder_dead; then
    return 1   # holder is ALIVE (or liveness unreadable, treated as alive by design) → never reclaim, no matter how old the heartbeat is.
  fi
  # An absent/empty heartbeat on an existing dir is a holder caught in the µs
  # window between its mkdir and its hb write (a write-failed acquire tears
  # its own dir down above, so this is only ever transient) — treat as LIVE
  # and back off.
  if [ ! -s "$GOLW_LOCK_HB" ]; then
    return 1
  fi
  # Single-winner stale reclaim: gate the recovery on ONE atomic sentinel at a
  # FIXED path, and take the stale dir over IN PLACE (heartbeat overwritten,
  # dir never removed) so no entry-mkdir gap is ever exposed to a racing
  # acquirer — mirrors quality-gate-dispatcher.sh's _acquire_gate_lock exactly.
  local _reaping="${GOLW_LOCK_DIR}.reaping"
  if ! mkdir "$_reaping" 2>/dev/null; then
    if [ "$(_golw_lock_path_age "$_reaping")" -ge "$GOLW_LOCK_REAP_TTL" ]; then
      local _dead="${_reaping}.dead.${GOLW_LOCK_TOKEN}"
      if mv "$_reaping" "$_dead" 2>/dev/null; then
        rm -rf "$_dead" 2>/dev/null || true
      fi
    fi
    if ! mkdir "$_reaping" 2>/dev/null; then
      return 1   # another reclaimer owns the recovery → back off (no double-win).
    fi
  fi
  # Re-check UNDER the sentinel: if the lock turned live while we waited, an
  # earlier reclaimer already took over — back off rather than clobber it.
  # Same liveness-only gate as the initial check above — age plays no part.
  if ! _golw_lock_holder_dead; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  _golw_lock_write_hb
  if [ ! -s "$GOLW_LOCK_HB" ]; then
    rmdir "$_reaping" 2>/dev/null || true
    return 1
  fi
  rmdir "$_reaping" 2>/dev/null || true
  log "Recovered STALE/DEAD lock (heartbeat age ${_age}s) — taking over (ga-y0g5x)."
  return 0
}

if [ "$GOLW_LOCK_ENABLED" = "1" ]; then
  if _acquire_golw_lock; then
    trap '_release_golw_lock' EXIT
  else
    log "Another gate-orphaned-label-watchdog run holds the lock — backing off (single-instance guard, ga-y0g5x)."
    exit 0
  fi
fi

run_sweep; exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail
