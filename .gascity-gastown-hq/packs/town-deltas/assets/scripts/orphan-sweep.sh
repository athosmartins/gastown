#!/usr/bin/env bash
# orphan-sweep — reset beads assigned to dead agents.
#
# Replaces the deacon patrol town-orphan-sweep step. Cross-references
# in-progress beads against all known agents. Beads assigned to agents
# that don't exist in ANY rig get reset to open/unassigned so the rig's
# witness picks them up on its next patrol.
#
# Does NOT do worktree salvage — that's the witness's job.
#
# ga-u0vzx: a bead's single orphan-candidate snapshot is not trusted on its
# own — see the CONFIRM_THRESHOLD ledger in Step 3. A live worker (dog-gaxfpyg,
# continuously state=awake per the session-reconciler trace) had its claim on
# ga-beikk reset by this order 25s after its last bd update, even though
# is_known_agent()'s multi-field live_session_match() should have protected
# it; the exact transient (a single `gc session list --json` read racing or
# momentarily missing that session) was not reproducible, but the design gap
# was clear either way: this order, unlike its sibling
# scripts/inflight-reclaim-guard.py (25min continuous-stranding hysteresis
# before any reclaim), acted destructively on ONE point-in-time snapshot with
# no cross-cycle confirmation. Hysteresis closes that gap the same way.
#
# ga-kq4jf: CONFIRM_THRESHOLD hysteresis alone (2 consecutive 5min sweeps,
# ~5-10min effective window) turned out NOT sufficient — the same
# irreproducible `gc session list` gap ga-u0vzx describes can apparently
# persist across MULTIPLE consecutive sweeps for a genuinely-live claimant,
# not just one. Confirmed twice on 2026-07-17 alone: ga-adkny's dog-pool
# claim was reset 11.8min after a fresh claim, then again 6.4min after a
# second fresh claim, both times while the claimant was independently
# confirmed alive via `gc session peek` (session mid a long extended-
# thinking turn, so no bd write or branch push had happened yet — the exact
# telemetry a genuinely dead claimant also produces). One of the two
# incidents also reset a simultaneous gate-reviewer-pool bead (ga-zd96h) in
# the same sweep, proving this isn't a dog-pool-specific gap. See
# RECENT_UPDATE_GRACE_SECS below for the added mitigation.
#
# ga-114ll: RECENT_UPDATE_GRACE_SECS + CONFIRM_THRESHOLD together still
# weren't enough — confirmed live 2026-08-06/07: a claim genuinely alive the
# whole time (owning process at 16.7% CPU, 5h+ tmux session) was reset and
# self-healed on a ~45min cycle, for hours, because whatever intermittently
# drops a live claimant from `gc session list --json` (the same gap ga-u0vzx/
# ga-kq4jf document, still not reproducible on demand) doesn't need to persist
# long — it only has to land on CONFIRM_THRESHOLD consecutive post-grace
# sweeps, and eventually does. Widening these same two knobs a third time
# would only lengthen the cycle, not close it (the read is what's unreliable,
# not the threshold). Instead: scripts/inflight-reclaim-guard.py's self-heal
# now stamps orphan-sweep:shielded-until:<epoch> on every claim it restores.
# This sweep honors that stamp unconditionally in Step 3 below — skipping
# candidacy regardless of what is_known_agent() concludes — trusting the
# sibling daemon's fresh, explicit verdict over re-deriving liveness from the
# exact read that just missed it. A bead that was never healed (a genuinely
# dead claimant) carries no stamp and sweeps normally.
#
# Runs as an exec order (no LLM, no agent, no wisp).
set -euo pipefail

# Trace bd invocations to $GC_BD_TRACE when set (no-op otherwise).
case "${BASH_SOURCE[0]}" in
    */*) __SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;;
    *) __SCRIPT_DIR="$(pwd)" ;;
esac
# ga-5a87qv: `.`/source is a POSIX special builtin — under this file's
# `set -euo pipefail`, a missing/unreadable target kills the shell
# immediately, before any log/warn call exists (same defect class ga-q4sadt
# fixed for the core gate/dispatch pipeline). Check readability BEFORE
# sourcing instead.
# shellcheck disable=SC1091
if [ -r "$__SCRIPT_DIR/_bd_trace.sh" ]; then
  . "$__SCRIPT_DIR/_bd_trace.sh" "orphan-sweep"
fi

CITY="${GC_CITY:-.}"

# ga-u0vzx: hysteresis ledger. A bead must be seen as an orphan-candidate on
# CONFIRM_THRESHOLD *consecutive* sweeps (default 2, i.e. spans one full
# cooldown interval — ~5-10min given the order's 5m cooldown) before it is
# actually reset. Mirrors the state-file convention used by the sibling
# spawn-storm-detect.sh order. A bead that drops out of the candidate set on
# any intervening sweep (session came back, bead reassigned/closed, or the
# prior read was a transient blip) has its counter pruned immediately, so
# only a *sustained* orphan condition ever triggers a reset.
PACK_STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
LEDGER="$PACK_STATE_DIR/orphan-sweep-counts.json"
CONFIRM_THRESHOLD="${ORPHAN_SWEEP_CONFIRM_THRESHOLD:-2}"

# ga-kq4jf: a bead updated (claimed, commented, relabeled, etc.) more
# recently than this is presumed to have an active owner even when its
# assignee doesn't resolve via is_known_agent() this sweep. Mirrors the
# secondary progress signal ga-64usm already added to the sibling
# scripts/inflight-reclaim-guard.py (session_owner_is_healthy's
# bead_update_age rescue): "a recent bd update on the bead is the secondary
# progress signal" that rescues a claim even when the primary session-
# liveness signal is stale or unavailable. Same TTL value as
# STALE_ACTIVITY_TTL in inflight-reclaim-guard.py — reusing an
# already-validated answer to "how long can a live builder go quiet"
# instead of inventing a new number — but independently override-able via
# its own env var. Does NOT weaken the agent_exists()/pool-instance/
# city-qualified paths in is_known_agent(): a bead assigned to a genuinely
# removed agent template is still caught at full CONFIRM_THRESHOLD speed;
# only the live_session_match() fallback path gets this extra grace.
RECENT_UPDATE_GRACE_SECS="${ORPHAN_SWEEP_RECENT_UPDATE_GRACE_SECS:-1800}"

# Step 1: Collect in-progress beads from HQ and every rig whose session
# liveness can be determined.
# `gc bd list` without --rig is HQ-scoped from the city cwd, so per-rig
# beads are invisible to a bare query — walk every rig explicitly.
TMP=$(mktemp) || exit 0
SESSION_TMP=$(mktemp) || {
    rm -f "$TMP"
    exit 0
}
trap 'rm -f "$TMP" "$SESSION_TMP"' EXIT

RIG_NAMES=""
RIG_LIST=$(gc rig list --json 2>/dev/null) || RIG_LIST=""
if [ -n "$RIG_LIST" ]; then
    RIG_NAMES=$(echo "$RIG_LIST" | jq -r '.rigs[] | select(.hq == false) | .name' 2>/dev/null) || RIG_NAMES=""
fi

append_session_list() {
    local session_fetch_tmp
    session_fetch_tmp=$(mktemp) || return 1
    if "$@" >"$session_fetch_tmp" 2>/dev/null; then
        cat "$session_fetch_tmp" >>"$SESSION_TMP"
        rm -f "$session_fetch_tmp"
        return 0
    fi
    rm -f "$session_fetch_tmp"
    return 1
}

append_hq_scope() {
    local bead_fetch_tmp
    bead_fetch_tmp=$(mktemp) || return 1
    append_session_list gc session list --json || {
        rm -f "$bead_fetch_tmp"
        return 1
    }
    gc bd list --status=in_progress --json --limit=0 2>/dev/null >"$bead_fetch_tmp" || true
    append_session_list gc session list --json || {
        rm -f "$bead_fetch_tmp"
        return 1
    }
    cat "$bead_fetch_tmp" >>"$TMP"
    rm -f "$bead_fetch_tmp"
}

append_rig_scope() {
    local rig="$1"
    local bead_fetch_tmp
    bead_fetch_tmp=$(mktemp) || return 1
    append_session_list gc --rig "$rig" session list --json || {
        rm -f "$bead_fetch_tmp"
        return 1
    }
    gc bd list --rig "$rig" --status=in_progress --json --limit=0 2>/dev/null >"$bead_fetch_tmp" || true
    append_session_list gc --rig "$rig" session list --json || {
        rm -f "$bead_fetch_tmp"
        return 1
    }
    cat "$bead_fetch_tmp" >>"$TMP"
    rm -f "$bead_fetch_tmp"
}

# Step 1b: Get all known live session identities around each bead-list query.
# The second liveness pass closes the session-list-before-bd-list race where a
# newly spawned session can claim work after the first pass but before bd-list.
# HQ liveness is required; per-rig failures only skip that rig's staged bead
# rows so one stale or unreachable rig does not disable cleanup elsewhere.
append_hq_scope || exit 0

while IFS= read -r rig; do
    [ -z "$rig" ] && continue
    if ! append_rig_scope "$rig"; then
        echo "orphan-sweep: skipping rig $rig after session-list failure" >&2
    fi
done <<<"$RIG_NAMES"

IN_PROGRESS=$(jq -c -s 'add // []' "$TMP" 2>/dev/null) || IN_PROGRESS="[]"
if [ "$IN_PROGRESS" = "[]" ]; then
    exit 0
fi

# Step 2: Get all known agent identities from resolved config.
# `gc config explain` prints Agent.QualifiedName(), including import binding
# and rig scope. Fall back to the older config-show parser for older binaries.
AGENTS=$(gc config explain 2>/dev/null | awk '/^Agent: /{print $2}') || AGENTS=""
if [ -z "$AGENTS" ]; then
    AGENTS=$(gc config show 2>/dev/null | awk '/^\[\[agent\]\]/{a=1} a && /^[[:space:]]*name[[:space:]]*=/{print; a=0}' | sed 's/.*=[[:space:]]*"\(.*\)"/\1/') || exit 0
fi
if [ -z "$AGENTS" ]; then
    exit 0
fi

# Step 2b: Parse identities of every session row that `gc session list --json`
# reports as open so that pool-spawned ephemeral assignees (e.g.
# gastown__polekitten-gc-q9j0om) are treated as known. The Go-side
# releaseOrphanedPoolAssignments path validates these from session beads via
# liveOpenSessionAssignmentExists, but this shell sweep only has the CLI JSON
# contract available. That means it protects the exposed wire identities below;
# it cannot see bead-only fields such as configured_named_identity or
# alias_history unless the CLI starts exporting them.
#
# The default CLI path already omits closed sessions. The closed/state guards
# below keep explicit or future session-list producers from making terminal
# rows live while preserving any non-closed row the CLI reports.
#
# This shell sweep ran without a live-session guard before ga-nvx: an ephemeral
# assignee whose template-stripped form did not match any agent name was
# incorrectly reset, racing against active polekitten work and producing a
# false-orphan loop.
# Two bugs the chronic strip pattern (gastownhall/gascity#2363) revealed:
# (1) The JSON shape is {"sessions":[...], "summary":..., "filters":..., "schema_version":...},
#     so `.[]` iterated four top-level scalar keys instead of session objects.
# (2) Field names vary by runtime/API path. The current CLI emits snake_case
#     (.closed/.id/.session_name/.alias/.agent_name); PascalCase is accepted
#     only as forward-compatible hardening so a casing change cannot make
#     LIVE_SESSION_IDS empty and strip active pool claims.
LIVE_SESSION_IDS=$(jq -r -s '
    def pick($snake; $pascal; $default):
      if has($snake) and .[$snake] != null then .[$snake]
      elif has($pascal) and .[$pascal] != null then .[$pascal]
      else $default end;
    .[] | .sessions[]?
    | select(
        (pick("closed"; "Closed"; false) == false)
        and ((pick("state"; "State"; "") | ascii_downcase) != "closed")
      )
    | [
        pick("id"; "ID"; null),
        pick("session_name"; "SessionName"; null),
        pick("alias"; "Alias"; null),
        pick("agent_name"; "AgentName"; null),
        pick("template"; "Template"; null),
        pick("name"; "Name"; null)
      ]
    | .[]
    | select(. != null and . != "")
' "$SESSION_TMP" 2>/dev/null) || exit 0

agent_exists() {
    local candidate="$1"
    [ -n "$candidate" ] && printf '%s\n' "$AGENTS" | grep -Fxq -- "$candidate"
}

live_session_match() {
    local candidate="$1"
    [ -n "$candidate" ] && [ -n "$LIVE_SESSION_IDS" ] \
        && printf '%s\n' "$LIVE_SESSION_IDS" | grep -Fxq -- "$candidate"
}

# Step 3: Find orphaned beads (assigned to non-existent agents).
# Pool instances use names like "worker-3"; strip the -N suffix to match
# the template name from config.
is_known_agent() {
    local name="$1"
    # Direct match against a configured agent template name.
    if agent_exists "$name"; then return 0; fi
    # Pool instance: strip trailing -<digits> and check template name.
    local base="${name%-[0-9]*}"
    if [ "$base" != "$name" ] && agent_exists "$base"; then return 0; fi
    # City-qualified assignee (gastown.deacon): strip everything through the
    # last dot and re-check. This relies on flattened pack binding chains.
    # Defense-in-depth for older binaries that fall through to `gc config show`
    # and emit unqualified names. Also covers pool patterns like
    # "gastown.dog-3" by re-stripping the -N suffix.
    local short="${name##*.}"
    if [ "$short" != "$name" ]; then
        if agent_exists "$short"; then return 0; fi
        local short_base="${short%-[0-9]*}"
        if [ "$short_base" != "$short" ] && agent_exists "$short_base"; then return 0; fi
    fi
    # Live ephemeral session names like gastown__polekitten-gc-q9j0om won't
    # match any template form — accept them as known when a non-closed session
    # is currently running with a matching ID, SessionName, Alias, or
    # AgentName. Mirrors liveOpenSessionAssignmentExists in the Go path.
    if live_session_match "$name"; then return 0; fi
    return 1
}

# ga-u0vzx: load the hysteresis ledger. Any read/parse failure is treated as
# an empty ledger (fail-open toward "needs re-confirmation", never toward
# "skip confirmation and reset immediately") — a corrupt or missing ledger
# must never make this order MORE aggressive than its designed default.
mkdir -p "$PACK_STATE_DIR" 2>/dev/null || true
[ -f "$LEDGER" ] || echo '{}' > "$LEDGER" 2>/dev/null || true
COUNTS=$(cat "$LEDGER" 2>/dev/null) || COUNTS='{}'
echo "$COUNTS" | jq -e 'type == "object"' >/dev/null 2>&1 || COUNTS='{}'

ORPHANED=0
CANDIDATES='{}'
# Process substitution (not a pipe) keeps the loop body in the parent
# shell so $ORPHANED/$COUNTS/$CANDIDATES survive for the code below.
while IFS=$'\t' read -r bead_id assignee update_age_secs shield_remaining; do
    # ga-114ll: inflight-reclaim-guard's self-heal just vouched for this exact
    # claim on its own, independent poll — honor that verdict unconditionally
    # for the shield window instead of re-deriving liveness from the same
    # is_known_agent() check that already missed it once this cycle (see the
    # header comment above for the full rationale). A bead never healed
    # carries no stamp (shield_remaining <= 0) and falls through untouched.
    if [ -n "$shield_remaining" ] && [ "$shield_remaining" -gt 0 ] 2>/dev/null; then
        continue
    fi
    if ! is_known_agent "$assignee"; then
        # ga-kq4jf: a recently-updated bead is presumed to have a live owner
        # even though this sweep's session snapshot didn't resolve it — skip
        # candidacy entirely this sweep. The prune step below then clears any
        # stale count left over from a sweep before the bead got this fresh,
        # so a later *genuine* orphan condition still starts its own clean
        # CONFIRM_THRESHOLD count rather than inheriting a stale one.
        if [ -n "$update_age_secs" ] && [ "$update_age_secs" -lt "$RECENT_UPDATE_GRACE_SECS" ] 2>/dev/null; then
            continue
        fi
        CANDIDATES=$(echo "$CANDIDATES" | jq --arg id "$bead_id" '.[$id] = 1') || CANDIDATES='{}'
        PREV=$(echo "$COUNTS" | jq -r --arg id "$bead_id" '.[$id] // 0' 2>/dev/null) || PREV=0
        NEW=$((PREV + 1))
        if [ "$NEW" -ge "$CONFIRM_THRESHOLD" ]; then
            # Confirmed orphaned across CONFIRM_THRESHOLD consecutive sweeps —
            # act. `gc bd update` auto-resolves the bead's prefix to the right
            # rig store, so HQ and rig beads update in the correct database.
            # ga-f6igb round 2 (GATE-FEEDBACK gate_run=ga-2esd2): stamp
            # orphan-sweep:reset atomically in this SAME update call — the
            # positive, single-call-atomic marker inflight-reclaim-guard.py's
            # heal_orphan_sweep_false_resets() now REQUIRES before restoring a
            # claim. No per-mutation actor attribution exists anywhere in this
            # codebase to tell a genuine orphan-sweep reset apart from an
            # unlabeled deliberate release after the fact (both leave the
            # identical bd-state shape; see that file's own module docstring
            # for the full audit-trail investigation) — this closes the gap
            # from the one side that CAN be made reliable: this call site is
            # the only place order:orphan-sweep itself resets a claim, so
            # self-stamping here is a complete, not partial, positive signal.
            echo "orphan-sweep: resetting $bead_id (assignee=$assignee, update_age=${update_age_secs}s, confirmed ${NEW}x consecutive sweeps)"
            gc bd update "$bead_id" --status=open --assignee="" --add-label "orphan-sweep:reset" 2>/dev/null || true
            ORPHANED=$((ORPHANED + 1))
            COUNTS=$(echo "$COUNTS" | jq --arg id "$bead_id" 'del(.[$id])') || true
        else
            # Not yet confirmed — record this sweep's hit and wait for the next.
            COUNTS=$(echo "$COUNTS" | jq --arg id "$bead_id" --argjson n "$NEW" '.[$id] = $n') || true
        fi
    fi
done < <(echo "$IN_PROGRESS" | jq -r '
    now as $now
    | .[]
    | select(.assignee != null and .assignee != "")
    | (.updated_at // .started_at // .created_at // "") as $ts
    | (try ($ts | fromdateiso8601) catch null) as $epoch
    | ((.labels // [])
       | map(select(startswith("orphan-sweep:shielded-until:"))
             | ltrimstr("orphan-sweep:shielded-until:")
             | (try tonumber catch null))
       | map(select(. != null))
       | max // 0) as $shield_until
    | [.id, .assignee,
       (if $epoch != null then (($now - $epoch) | floor) else 999999999 end),
       (($shield_until - $now) | floor)]
    | @tsv
' 2>/dev/null)

# ga-u0vzx: prune ledger entries for beads that were NOT an orphan-candidate
# on THIS sweep — the assignee resolved to a known/live agent again (session
# came back, bead reassigned) or the bead left in_progress entirely. Anything
# not continuously suspect gets a clean slate rather than accumulating a
# count across gaps, which is what makes this a *consecutive*-sweeps check
# rather than a leaky "N-times-ever" counter.
COUNTS=$(echo "$COUNTS" | jq --argjson keep "$CANDIDATES" \
    'to_entries | map(select(.key as $k | $keep[$k] != null)) | from_entries' 2>/dev/null) || COUNTS='{}'
echo "$COUNTS" > "$LEDGER" 2>/dev/null || true

if [ "$ORPHANED" -gt 0 ]; then
    echo "orphan-sweep: reset $ORPHANED orphaned beads"
fi
