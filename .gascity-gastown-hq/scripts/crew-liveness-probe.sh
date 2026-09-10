#!/usr/bin/env bash
# crew-liveness-probe.sh — detect and heal wedged crews holding story:in-flight beads.
#
# imp21: A crew that is alive (Claude session running) but has made no git commits
# for PROBE_STALE_MIN minutes is wedged — it's consuming a slot without making
# progress. The reclaim-guard fires at 25min; this probe fires at PROBE_STALE_MIN
# (default 15min) to nudge the crew BEFORE reclaim-guard re-dispatches the bead
# to the same dead session (infinite loop).
#
# Detection: for each story:in-flight + pilot:dispatched bead across rig stores,
# check how long since the bead was last updated_at. If longer than PROBE_STALE_MIN
# AND the assignee session is still alive (gc session list), nudge on first sweep,
# and HEAL on second consecutive sweep confirming the crew is still stale.
#
# HEAL (CLP_HEAL_ENABLED=1, default 0):
#   1. Strip pilot:dispatched + story:in-flight labels from the bead → re-enters dispatch
#   2. Clear the bead's assignee → un-owned
#   3. Suspend the crew agent via `gc agent suspend` → Pilot skips it next dispatch cycle
#      (Pilot reads gc agent list | awk '$2=="suspended"' in _pilot_suspended_crews(),
#       checked at pick_pool_builder() lines 750+760 in pilot-dispatcher.sh)
#      On success, records a CLP_STATE_DIR marker (crew/bead/store/session-identity)
#      so run_resume_scan() can auto-resume ONLY what this script itself suspended.
#
# SAFETY (2-confirmation):
#   State files are written per-bead to CLP_STATE_DIR on first detection.
#   Heal fires ONLY if the bead is STILL stale+assigned on the NEXT sweep AND
#   a prior-sweep state file exists (≥ CLP_CONFIRM_MIN minutes old).
#   A slow-but-alive crew is NOT healed — it must appear stale across TWO sweeps.
#
# RESUME (ga-ld0ch, CLP_HEAL_ENABLED=1 — same knob, it's the other half of heal):
#   A crew this script suspends is otherwise a one-way ratchet: nothing ever
#   calls `gc agent resume` again, so the crew stays locked out of nudge+dispatch
#   even after a human restarts its session (which IS the actual cure — restart
#   fixes the wedge, but the suspend flag survives a restart untouched). Each
#   cycle, run_resume_scan() re-checks every crew THIS script suspended (tracked
#   via the CLP_STATE_DIR marker _heal() wrote): if its live session identity
#   has changed since the marker was recorded (new session, or the old one is
#   simply gone) — proof something happened since the wedge — auto-resume it.
#   Never touches a crew without a marker THIS script wrote: a deliberate,
#   committed suspension (e.g. batista-ps, thies-ps in property_scrapers) is
#   never at risk of being auto-resumed by this probe.
#
# WATCHDOG (ga-ld0ch): run_suspend_watchdog() is independent of whether THIS
# script did the suspending — it just flags any agent with suspended=true AND
# a currently-live session and no CLP_STATE_DIR marker. That combination is
# exactly the blind spot from the 2026-09-10 incident (peter-wa/thies-wa/
# mila-wa suspended via some other, uncommitted path — never proven to be this
# script; see ga-ld0ch) that went unnoticed for hours because nothing surfaced
# it. Fires regardless of root cause; dedup so it pages once per crew per hour,
# not every StartInterval. Never flags a DELIBERATE suspension: batista-ps and
# thies-ps (property_scrapers) are suspended on purpose, with that suspended=
# true committed to git — _is_committed_suspend() checks exactly that (HEAD's
# agent.toml, via `git show`, never `git checkout`) and skips them. The
# 2026-09-10 incident's own signature was the opposite of that — suspended=
# true with NO commit at all — which is precisely what this still lets through.
#
# ROOT CAUSE NOTE (ga-ld0ch): `_live_sessions()` used to do `jq -r '.[].name'`
# against `gc session list --json`. The CLI's real output is an envelope object
# ({"filters":{},"ok":true,"schema_version":"1","sessions":[...]}), not a bare
# array — `.[].name` walks EVERY top-level value (including the `ok` boolean)
# and jq fatals the moment it hits one that isn't indexable by `.name`, so the
# function's actual return value was the literal string "null", which never
# matches any real assignee. Net effect: since whenever `session list --json`
# gained this envelope, EVERY bead has read as "not a live session" and this
# probe's detect+nudge+heal path has been a complete, silent no-op — verified
# against the live log (crew-liveness-probe.log), which shows zero heals and
# zero nudges across its entire retained history. The selftest's own `gc` shim
# had been mocking the OLD bare-array shape (matching the code's assumption,
# not the real CLI), so it passed while production silently did nothing —
# fixed here by making the shim emit the real envelope shape too.
#
# Knobs:
#   CLP_ENABLED=1              — enable detect+nudge+watchdog (default 0)
#   CLP_HEAL_ENABLED=1         — enable heal + auto-resume actions (default 0; canary after review)
#   CLP_PROBE_STALE_MIN=15     — stale threshold in minutes (< reclaim 25min)
#   CLP_CONFIRM_MIN=8          — min minutes between first-nudge and heal (default 8)
#   CLP_STORES                 — space-separated rig store paths
#   CLP_DRY_RUN=1              — report only, no nudge/heal/resume
#   CLP_BD=bd                  — bd binary override (test seam)
#   CLP_GC=gc                  — gc binary override (test seam)
#   CLP_STATE_DIR              — directory for per-bead confirmation state files
#
# Runs every 10 minutes (StartInterval 600). DPW_CRITICAL: add after verifying live.
set -uo pipefail

CLP_ENABLED="${CLP_ENABLED:-0}"
CLP_HEAL_ENABLED="${CLP_HEAL_ENABLED:-0}"
CLP_PROBE_STALE_MIN="${CLP_PROBE_STALE_MIN:-15}"
CLP_CONFIRM_MIN="${CLP_CONFIRM_MIN:-8}"
CLP_STORES="${CLP_STORES:-/Users/athos/gt/.gascity-gastown-hq /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"
CLP_DRY_RUN="${CLP_DRY_RUN:-0}"
BD="${CLP_BD:-bd}"
GC="${CLP_GC:-gc}"
LOG="${CLP_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/crew-liveness-probe.log}"
CLP_STATE_DIR="${CLP_STATE_DIR:-/Users/athos/gt/.gascity-gastown-hq/.gc/clp-state}"
CLP_NOTIFY="${CLP_NOTIFY:-/Users/athos/.local/bin/notify}"
CLP_CITY="${CLP_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
CLP_FRAMEWORK_REPO="${CLP_FRAMEWORK_REPO:-/Users/athos/gt}"

# Cache for `gc session list --json`, loaded once per top-level call via
# _load_sessions_json() and read by _live_sessions() / _session_identity().
_sessions_json_cache=""

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$CLP_NOTIFY" -t "Crew Liveness Probe" -p 4 "🚨 $*" 2>/dev/null || true; }
# notify_info — same channel as notify_fail but default priority: for routine,
# non-urgent visibility (a successful heal, an auto-resume) rather than an
# alarm. This is the concrete fix for "ninguem ve" — a heal used to leave no
# trace anyone would proactively see; now it pushes.
notify_info() { "$CLP_NOTIFY" -t "Crew Liveness Probe" "$*" 2>/dev/null || true; }

_nudge() {  # crew-id bead-id
  [ "$CLP_DRY_RUN" = "1" ] && { log "  DRY: would nudge $1 about bead $2"; return 0; }
  "$GC" nudge "$1" "liveness probe: bead $2 has been in-flight for ${CLP_PROBE_STALE_MIN}+ min with no recent commit — please send a status note or commit progress" 2>/dev/null || true
}

# _comment_bead store bead-id text — best-effort durable trail on the bead.
# Always --file (never -m: this bd build silently no-ops on -m and prints
# nothing, so a caller has no signal the comment never landed).
_comment_bead() {
  local store="$1" bead="$2" text="$3" tf
  tf=$(mktemp 2>/dev/null) || return 0
  printf '%s\n' "$text" > "$tf" 2>/dev/null
  "$BD" -C "$store" comment "$bead" --file "$tf" 2>/dev/null \
    || log "  WARN: failed to write bd comment on $bead"
  rm -f "$tf" 2>/dev/null || true
}

# _heal_marker_file crew-id — path to the "this script suspended it" marker.
# Deliberately NEVER cleaned up by time (unlike *.nudged below) — it must
# survive until run_resume_scan() actively resolves it (resume, or discovers
# someone else already did), however long that takes. A time-based expiry
# here would make this probe "forget" its own suspension and have the new
# watchdog wrongly flag it as unexplained.
_heal_marker_file() { echo "${CLP_STATE_DIR}/${1}.suspended-by-probe"; }

# _record_heal_marker crew bead store ident — written on a SUCCESSFUL suspend.
_record_heal_marker() {
  local crew="$1" bead="$2" store="$3" ident="$4"
  mkdir -p "$CLP_STATE_DIR" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$bead" "$store" "$ident" > "$(_heal_marker_file "$crew")" 2>/dev/null || true
}

# _heal crew-id bead-id store-path session-identity
# Strips in-flight labels, clears assignee, suspends the crew agent.
# Called ONLY after 2-confirmation; SAFETY-critical.
_heal() {
  local crew="$1" bead="$2" store="$3" ident="${4:-}"
  log "  HEAL: releasing bead $bead from crew $crew (store=$store)"

  if [ "$CLP_DRY_RUN" = "1" ]; then
    log "  DRY: would strip labels pilot:dispatched+story:in-flight, clear assignee, suspend $crew"
    return 0
  fi

  # Strip dispatch labels so bead re-enters the dispatch pool
  "$BD" -C "$store" label remove "$bead" pilot:dispatched 2>/dev/null \
    && log "  HEAL: stripped pilot:dispatched from $bead" \
    || log "  HEAL WARN: failed to strip pilot:dispatched from $bead (may already be gone)"
  "$BD" -C "$store" label remove "$bead" story:in-flight 2>/dev/null \
    && log "  HEAL: stripped story:in-flight from $bead" \
    || log "  HEAL WARN: failed to strip story:in-flight from $bead"

  # Clear assignee — bead now unowned for Pilot to re-assign
  "$BD" -C "$store" assign "$bead" "" 2>/dev/null \
    && log "  HEAL: cleared assignee on $bead" \
    || log "  HEAL WARN: failed to clear assignee on $bead"

  # Suspend the crew agent so Pilot does NOT re-dispatch to the same dead session.
  # Pilot honors this via _crew_is_suspended() → gc agent list | awk '$2=="suspended"'
  # checked at pick_pool_builder() (pilot-dispatcher.sh lines 750, 760).
  #
  # RISK: if the crew is still alive and working on ANOTHER bead, suspending it
  # prevents new dispatches to it. Mitigation: we only reach here after 2-sweep
  # confirmation that THIS bead is still stale on this crew, which strongly implies
  # the crew is wedged. run_resume_scan() auto-resumes it once its session
  # identity changes (proof of restart — the actual cure, per ga-ld0ch); `gc
  # agent resume <name>` also works manually at any time.
  if "$GC" -C "$CLP_CITY" agent suspend "$crew" 2>/dev/null; then
    log "  HEAL: suspended crew agent $crew"
    _record_heal_marker "$crew" "$bead" "$store" "$ident"
    _comment_bead "$store" "$bead" "crew-liveness-probe: suspended crew agent '$crew' after 2 confirmed sweeps with no commit activity on this bead (>= ${CLP_PROBE_STALE_MIN}min stale, reconfirmed >= ${CLP_CONFIRM_MIN}min later). Bead unassigned and reopened for dispatch. '$crew' auto-resumes once its session restarts (new session identity detected), or resume manually: gc agent resume $crew"
    notify_info "crew-liveness-probe: suspendi $crew (bead $bead confirmado travado 2x) — auto-retoma quando a sessao reiniciar, ou: gc agent resume $crew"
  else
    log "  HEAL WARN: failed to suspend crew agent $crew (may not be a city agent)"
    notify_fail "crew-liveness-probe: falha ao suspender crew $crew apos heal do bead $bead — crew wedged pode ser re-despachado"
  fi
}

# _load_sessions_json — cache `gc session list --json` once per call site.
# The CLI wraps sessions in an envelope: {"filters":{},"ok":true,
# "schema_version":"1","sessions":[...]}. NOT a bare array — see the ROOT
# CAUSE NOTE in the file header for what assuming otherwise did to this probe.
#
# Also tracks _sessions_json_ok (1 = parsed successfully, 0 = the call
# failed or returned something that isn't valid JSON) — third-state
# discipline: an empty _sessions_json_cache from a FAILED call must never
# read the same as "call succeeded, crew genuinely has no live session".
# _live_sessions()/_session_identity() collapse both to "empty" either way
# (safe for run_probe's existing skip-on-not-live path), but a caller that
# would otherwise ACT on "identity changed" (run_resume_scan) must check
# _sessions_json_ok first and skip instead of treating a transient `gc`
# hiccup as proof of a restart.
_sessions_json_ok=0
_load_sessions_json() {
  local raw
  if raw=$("$GC" session list --json 2>/dev/null) && [ -n "$raw" ] \
      && printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
    _sessions_json_cache="$raw"
    _sessions_json_ok=1
  else
    _sessions_json_cache=""
    _sessions_json_ok=0
  fi
}

_live_sessions() {
  printf '%s' "$_sessions_json_cache" | jq -r '.sessions[]?.name // empty' 2>/dev/null || true
}

# _session_identity crew-name — "<id>|<created_at>" for its current live
# session, or empty if not currently live. Used to detect a restart (the
# actual cure for a wedged crew) without betting on which single field is
# the "real" identity — id and created_at both change together on a fresh
# session, so either changing is equally good evidence.
_session_identity() {
  printf '%s' "$_sessions_json_cache" | jq -r --arg n "$1" \
    '.sessions[]? | select(.name == $n) | "\(.id)|\(.created_at)"' 2>/dev/null | head -1
}

# _state_file bead-id crew-id — returns path to confirmation state file
_state_file() {
  mkdir -p "$CLP_STATE_DIR" 2>/dev/null || true
  echo "${CLP_STATE_DIR}/${1}__${2}.nudged"
}

# _record_nudge bead-id crew-id — write state file with current epoch
_record_nudge() {
  local sf; sf=$(_state_file "$1" "$2")
  date +%s > "$sf" 2>/dev/null || true
}

# _is_confirmed bead-id crew-id — returns 0 if state file exists AND is ≥ CLP_CONFIRM_MIN old
_is_confirmed() {
  local sf; sf=$(_state_file "$1" "$2")
  [ -f "$sf" ] || return 1
  local file_ts; file_ts=$(cat "$sf" 2>/dev/null) || return 1
  [ -n "$file_ts" ] || return 1
  local now; now=$(date +%s)
  local age=$(( now - file_ts ))
  local threshold=$(( CLP_CONFIRM_MIN * 60 ))
  [ "$age" -ge "$threshold" ] && return 0 || return 1
}

# _clear_state bead-id crew-id — remove state file after heal
_clear_state() {
  local sf; sf=$(_state_file "$1" "$2")
  rm -f "$sf" 2>/dev/null || true
}

# _watchdog_notify_file crew-id — dedup marker so run_suspend_watchdog() pages
# at most once per crew per hour instead of every StartInterval (600s).
_watchdog_notify_file() { echo "${CLP_STATE_DIR}/${1}.watchdog-notified"; }

_should_watchdog_notify() {
  local wf; wf=$(_watchdog_notify_file "$1")
  [ -f "$wf" ] || return 0
  local file_ts; file_ts=$(cat "$wf" 2>/dev/null) || return 0
  [ -n "$file_ts" ] || return 0
  local age=$(( $(date +%s) - file_ts ))
  [ "$age" -ge 3600 ] && return 0 || return 1
}

_record_watchdog_notify() {
  mkdir -p "$CLP_STATE_DIR" 2>/dev/null || true
  date +%s > "$(_watchdog_notify_file "$1")" 2>/dev/null || true
}

# _is_committed_suspend crew-name — true if the crew's LAST COMMITTED
# agent.toml (HEAD, via `git show` — a read, never `git checkout`, so this
# cannot mutate the shared working tree) already has `suspended = true`.
# That is a deliberate, reviewed suspension (batista-ps/thies-ps in
# property_scrapers: committed, intentional, old) and must never be flagged.
# The 2026-09-10 incident's signature was the opposite: three crews' TOML
# went to suspended=true with NO commit at all — this is exactly the check
# that tells the two apart (see crew-liveness-probe-suspends-never-resumes
# memory). `git show` on a path that was never committed, or doesn't exist,
# just fails closed to "not committed" (empty grep, function returns false).
_is_committed_suspend() {
  git -C "$CLP_FRAMEWORK_REPO" show "HEAD:.gascity-gastown-hq/agents/${1}/agent.toml" 2>/dev/null \
    | grep -qF 'suspended = true'
}

run_probe() {
  if [ "$CLP_ENABLED" != "1" ]; then log "disabled (CLP_ENABLED!=1)"; return 0; fi
  local store id assignee updated_at stale_sec probed=0 healed=0 live_sessions
  local now; now=$(date +%s)
  local stale_threshold=$(( CLP_PROBE_STALE_MIN * 60 ))

  # Cache live sessions once per probe run (gc session list is expensive)
  _load_sessions_json
  live_sessions=$(_live_sessions)

  # Clean up state files for beads that have cleared (stale/expired files ≥ 2h old).
  # *.suspended-by-probe is deliberately NOT included — see _heal_marker_file().
  if [ -d "$CLP_STATE_DIR" ]; then
    find "$CLP_STATE_DIR" -name "*.nudged" -mmin +120 -delete 2>/dev/null || true
    find "$CLP_STATE_DIR" -name "*.watchdog-notified" -mmin +1440 -delete 2>/dev/null || true
  fi

  for store in $CLP_STORES; do
    [ -d "$store" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      id=$(echo "$line" | jq -r '.id' 2>/dev/null)
      assignee=$(echo "$line" | jq -r '(.assignee // "")' 2>/dev/null)
      updated_at=$(echo "$line" | jq -r '(.updated_at // "")' 2>/dev/null)
      [ -n "$id" ] && [ -n "$assignee" ] && [ -n "$updated_at" ] || continue

      # Parse updated_at (UTC ISO8601) to epoch.
      # TZ=UTC0 forces BSD date to treat the parsed time as UTC, not local time.
      local updated_epoch
      updated_epoch=$(TZ=UTC0 date -jf "%Y-%m-%dT%H:%M:%S" "${updated_at%%Z}" +%s 2>/dev/null) \
        || updated_epoch=$(TZ=UTC date -d "$updated_at" +%s 2>/dev/null) || continue
      local stale_sec=$(( now - updated_epoch ))
      [ "$stale_sec" -ge "$stale_threshold" ] || continue

      # Check if assignee is a live session.
      # If NOT live: a dead session means the reclaim-guard will handle it; skip.
      # We only act on sessions still alive (wedged, not dead).
      if ! echo "$live_sessions" | grep -qF "$assignee" 2>/dev/null; then
        log "probe skip: $id assignee=$assignee — NOT a live session (may already be dead/reclaimed)"
        _clear_state "$id" "$assignee"
        continue
      fi

      # === 2-CONFIRMATION SAFETY ===
      # First sweep: nudge + record state. Do NOT heal yet.
      # Second sweep (state file ≥ CLP_CONFIRM_MIN old): confirmed wedged → maybe heal.
      if _is_confirmed "$id" "$assignee"; then
        # CONFIRMED: crew was nudged ≥ CLP_CONFIRM_MIN ago and is STILL stale+alive
        log "probe CONFIRMED-WEDGED: $id assignee=$assignee stale=${stale_sec}s — crew is confirmed wedged (2-sweep)"
        if [ "$CLP_HEAL_ENABLED" = "1" ]; then
          _heal "$assignee" "$id" "$store" "$(_session_identity "$assignee")"
          _clear_state "$id" "$assignee"
          healed=$(( healed + 1 ))
        else
          log "  HEAL skipped (CLP_HEAL_ENABLED!=1) — crew $assignee still wedged on $id"
          # Re-nudge since we skipped heal, so crew gets another poke
          _nudge "$assignee" "$id"
          probed=$(( probed + 1 ))
        fi
      else
        # FIRST SWEEP: nudge + record state file for 2-confirmation
        log "probe FIRST-SWEEP: $id assignee=$assignee stale=${stale_sec}s (>${CLP_PROBE_STALE_MIN}min) — nudging, recording state"
        _nudge "$assignee" "$id"
        _record_nudge "$id" "$assignee"
        probed=$(( probed + 1 ))
      fi
    done < <("$BD" -C "$store" list -l story:in-flight -l pilot:dispatched --json -n 0 2>/dev/null \
              | jq -c '.[] | select((.assignee // "") != "")' 2>/dev/null)
  done
  log "probe complete: nudged $probed crew(s), healed $healed$([ "$CLP_DRY_RUN" = "1" ] && echo ' (DRY)')"
}

# run_resume_scan — the other half of imp21's heal (ga-ld0ch): auto-resume a
# crew THIS script suspended once it looks healthy again. "Healthy again" =
# its live session identity differs from what it was at suspend time — either
# a genuinely new session (restarted, the real cure per ga-ld0ch's own
# incident writeup) or no session at all (the old wedged one exited; resuming
# just lets the reconciler start a clean one instead of leaving the crew
# stuck suspended forever with nothing running). Never acts on a crew without
# a marker THIS function's sibling _heal() wrote, so a deliberate/committed
# suspension is never touched.
run_resume_scan() {
  [ "$CLP_HEAL_ENABLED" = "1" ] || { log "resume-scan skipped (CLP_HEAL_ENABLED!=1)"; return 0; }
  [ -d "$CLP_STATE_DIR" ] || return 0
  _load_sessions_json
  # Third state: a FAILED/unparseable `gc session list --json` must not read
  # the same as "call succeeded, crew has no live session" — the latter
  # would fall through to _session_identity() returning empty, which
  # compares as "changed" against a non-empty ident_then and would auto-
  # resume a crew that, for all we actually know, is still exactly as
  # wedged as when it was suspended. Skip the whole cycle instead; every
  # marker is untouched and gets a fair look again in ~10 minutes.
  if [ "$_sessions_json_ok" != "1" ]; then
    log "resume-scan: gc session list --json failed/unparseable this cycle — skipping (inconclusive, not treating as 'crew restarted')"
    return 0
  fi
  local mf crew suspended_at bead store ident_then ident_now now_suspended agent_list_json resumed=0
  agent_list_json=$("$GC" -C "$CLP_CITY" agent list --json 2>/dev/null)
  if [ -z "$agent_list_json" ] || ! printf '%s' "$agent_list_json" | jq -e . >/dev/null 2>&1; then
    log "resume-scan: gc agent list --json failed/unparseable this cycle — skipping (inconclusive, markers left untouched)"
    return 0
  fi
  for mf in "$CLP_STATE_DIR"/*.suspended-by-probe; do
    [ -e "$mf" ] || continue
    crew=$(basename "$mf" .suspended-by-probe)
    [ -n "$crew" ] || continue
    IFS=$'\t' read -r suspended_at bead store ident_then < "$mf" 2>/dev/null || continue
    [ -n "$store" ] || store="$CLP_CITY"

    # Someone else may have already resumed it (or it was never really
    # suspended, e.g. a marker survived a crash before suspend completed).
    # Either way, if it's not suspended anymore there's nothing to do —
    # clear the now-stale marker so the watchdog doesn't misread it later.
    # (The query itself was already validated above, once, for all crews —
    # a per-crew "not found in the list" still means confirmed-not-suspended
    # here, not inconclusive; only a failed/unparseable CALL is inconclusive.)
    now_suspended=$(printf '%s' "$agent_list_json" | jq -r --arg n "$crew" '.agents[]? | select(.name == $n) | .suspended' 2>/dev/null)
    if [ "$now_suspended" != "true" ]; then
      log "resume-scan: $crew no longer suspended (resumed by someone else, or never took) — clearing stale marker"
      rm -f "$mf" 2>/dev/null || true
      continue
    fi

    ident_now=$(_session_identity "$crew")
    if [ "$ident_now" != "$ident_then" ]; then
      log "resume-scan: $crew session identity changed ('$ident_then' -> '$ident_now') — treating as restarted, auto-resuming"
      if [ "$CLP_DRY_RUN" = "1" ]; then
        log "  DRY: would resume $crew"
      elif "$GC" -C "$CLP_CITY" agent resume "$crew" 2>/dev/null; then
        log "  RESUME: resumed crew agent $crew (was suspended for bead $bead)"
        _comment_bead "$store" "$bead" "crew-liveness-probe: auto-resumed '$crew' — its session identity changed since the suspend ($ident_then -> $ident_now), consistent with a restart."
        notify_info "crew-liveness-probe: retomei $crew (sessao mudou desde a suspensao — parece reiniciada)"
        resumed=$(( resumed + 1 ))
      else
        log "  RESUME WARN: gc agent resume failed for $crew"
        notify_fail "crew-liveness-probe: falha ao dessuspender crew $crew apos detectar sessao nova"
      fi
      rm -f "$mf" 2>/dev/null || true
    else
      local age_min=$(( ( $(date +%s) - suspended_at ) / 60 ))
      log "resume-scan: $crew still suspended (${age_min}min), same session ('$ident_now') — not auto-resuming yet"
    fi
  done
  [ "$resumed" -gt 0 ] && log "resume-scan complete: resumed $resumed crew(s)"
  return 0
}

# run_suspend_watchdog — independent anomaly detector (ga-ld0ch): any agent
# with suspended=true AND a currently-live session, that carries no
# CLP_STATE_DIR marker from this script's own _heal(), is unexplained from
# this probe's point of view — exactly the shape of the 2026-09-10 incident,
# regardless of what actually caused it. Read-only + notify, gated on
# CLP_ENABLED alone (no heal knob needed — it never mutates agent state).
run_suspend_watchdog() {
  [ "$CLP_ENABLED" = "1" ] || return 0
  local agents_json alive_names name flagged=0
  agents_json=$("$GC" -C "$CLP_CITY" agent list --json 2>/dev/null)
  if [ -z "$agents_json" ] || ! printf '%s' "$agents_json" | jq -e . >/dev/null 2>&1; then
    log "watchdog: gc agent list --json failed/unparseable this cycle — skipping (inconclusive)"
    return 0
  fi
  _load_sessions_json
  if [ "$_sessions_json_ok" != "1" ]; then
    log "watchdog: gc session list --json failed/unparseable this cycle — skipping (inconclusive, cannot confirm liveness)"
    return 0
  fi
  alive_names=$(_live_sessions)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$(_heal_marker_file "$name")" ] && continue   # already accounted for by resume-scan
    # Exact match required: grep -F alone is an unanchored substring test, so a
    # live session merely CONTAINING $name (e.g. "gate-reviewer-adhoc-<hash>"
    # vs suspended agent "gate-reviewer") would false-positive as "live" —
    # gate-fix for ga-ld0ch review, see Scenario 21.
    printf '%s\n' "$alive_names" | grep -qxF "$name" 2>/dev/null || continue   # not live — a different problem
    _is_committed_suspend "$name" && continue   # deliberate, reviewed suspension — not an anomaly
    if _should_watchdog_notify "$name"; then
      log "WATCHDOG: $name is suspended=true with a LIVE session and no probe marker — unexplained suspension, invisible unless someone looks (ga-ld0ch shape)"
      notify_fail "crew-liveness-probe watchdog: $name suspenso com sessao viva, sem marca do probe — suspensao manual/desconhecida. Revisar: gc agent list | grep $name ; se for engano: gc agent resume $name"
      _record_watchdog_notify "$name"
      flagged=$(( flagged + 1 ))
    fi
  done < <(printf '%s' "$agents_json" | jq -r '.agents[]? | select(.suspended == true) | .name' 2>/dev/null)
  [ "$flagged" -gt 0 ] && log "watchdog: flagged $flagged suspended-but-live agent(s) with no probe marker"
  return 0
}

# ── selftest ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  NOW_ST=$(date +%s)
  NUDGE_LOG="$TMP/nudges"
  HEAL_LOG="$TMP/heals"
  SUSPEND_LOG="$TMP/suspends"
  NOTIFY_LOG="$TMP/notifies"
  RESUME_LOG="$TMP/resumes"
  COMMENT_LOG="$TMP/comments"
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"; : > "$NOTIFY_LOG"; : > "$RESUME_LOG"; : > "$COMMENT_LOG"

  cat > "$TMP/notify" <<NOTIFYSHIM
#!/usr/bin/env bash
echo "\$*" >> "${NOTIFY_LOG}"
NOTIFYSHIM
  chmod +x "$TMP/notify"

  # Stale bead (updated 20 min ago), live crew
  STALE_TS=$(date -u -r $(( NOW_ST - 1200 )) "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -d "@$(( NOW_ST - 1200 ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  # Fresh bead (updated 5 min ago), live crew
  FRESH_TS=$(date -u -r $(( NOW_ST - 300 )) "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -d "@$(( NOW_ST - 300 ))" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

  cat > "$TMP/bd" <<BDSHIM
#!/usr/bin/env bash
case "\$*" in
  *"list -l story:in-flight -l pilot:dispatched"*)
    echo '[{"id":"wa-stale","assignee":"mila-wa","updated_at":"'"$STALE_TS"'"},{"id":"wa-fresh","assignee":"mila-wa","updated_at":"'"$FRESH_TS"'"},{"id":"wa-dead","assignee":"dead-crew","updated_at":"'"$STALE_TS"'"}]' ;;
  *"label remove"*) echo "\$*" >> "${HEAL_LOG}" ;;
  *"assign"*) echo "\$*" >> "${HEAL_LOG}" ;;
  *"comment"*) echo "\$*" >> "${COMMENT_LOG}" ;;
  *) echo '[]' ;;
esac
BDSHIM
  chmod +x "$TMP/bd"

  # GC shim: session list --json emits the REAL envelope shape (object with a
  # .sessions[] key), not the bare array this file's own tests used to mock —
  # see the ROOT CAUSE NOTE at the top of this file for why that distinction
  # is the whole bug. Session id is read from $TMP/session_id so a scenario
  # can simulate a restart just by rewriting that file. agent suspend/resume/
  # list --json are backed by a tiny stateful mock ($TMP/suspended_state) so
  # resume-scan and the watchdog can be tested against a self-consistent
  # simulated world, the same way $TMP/fail_suspend already toggles scenario 8.
  cat > "$TMP/gc" <<GCSHIM
#!/usr/bin/env bash
SID=\$(cat "${TMP}/session_id" 2>/dev/null || echo "sess-A")
case "\$*" in
  *"session list --json"*)
    # \$TMP/fail_session_list toggles a simulated transient CLI failure —
    # third-state regression coverage (Scenario 18): must never read the
    # same as "call succeeded, nobody's live".
    [ -f "${TMP}/fail_session_list" ] && exit 1
    EXTRA_SESSION=""
    [ -f "${TMP}/extra_session_name" ] && EXTRA_SESSION=',{"name":"'"\$(cat "${TMP}/extra_session_name")"'","id":"sess-extra","created_at":"2026-01-01T00:00:00Z"}'
    echo '{"filters":{},"ok":true,"schema_version":"1","sessions":[{"name":"mila-wa","id":"'"\$SID"'","created_at":"2026-01-01T00:00:00Z"}'"\$EXTRA_SESSION"']}' ;;
  *"nudge"*) echo "\$*" >> "${NUDGE_LOG}" ;;
  *"agent suspend"*)
    [ -f "${TMP}/fail_suspend" ] && exit 1
    echo "\$*" >> "${SUSPEND_LOG}"
    NAME="\${@: -1}"
    grep -qxF "\$NAME" "${TMP}/suspended_state" 2>/dev/null || echo "\$NAME" >> "${TMP}/suspended_state"
    ;;
  *"agent resume"*)
    echo "\$*" >> "${RESUME_LOG}"
    NAME="\${@: -1}"
    grep -vxF "\$NAME" "${TMP}/suspended_state" 2>/dev/null > "${TMP}/suspended_state.tmp"
    mv "${TMP}/suspended_state.tmp" "${TMP}/suspended_state" 2>/dev/null || true
    ;;
  *"agent list --json"*)
    # \$TMP/fail_agent_list — same idea, for Scenario 19.
    [ -f "${TMP}/fail_agent_list" ] && exit 1
    if grep -qxF "mila-wa" "${TMP}/suspended_state" 2>/dev/null; then SUS=true; else SUS=false; fi
    EXTRA_AGENT=""
    [ -f "${TMP}/extra_agent_name" ] && EXTRA_AGENT=',{"name":"'"\$(cat "${TMP}/extra_agent_name")"'","suspended":true}'
    echo '{"agents":[{"name":"mila-wa","suspended":'"\$SUS"'}'"\$EXTRA_AGENT"']}'
    ;;
  *) true ;;
esac
GCSHIM
  chmod +x "$TMP/gc"
  : > "$TMP/suspended_state"
  echo "sess-A" > "$TMP/session_id"

  BD="$TMP/bd"; GC="$TMP/gc"
  CLP_STORES="$TMP"
  CLP_CITY="$TMP"
  LOG="$TMP/log"
  CLP_STATE_DIR="$TMP/state"
  CLP_NOTIFY="$TMP/notify"
  CLP_ENABLED=1; CLP_PROBE_STALE_MIN=15; CLP_DRY_RUN=0
  CLP_HEAL_ENABLED=0; CLP_CONFIRM_MIN=8

  echo "=== Scenario 1: First sweep — nudge only, no heal ==="
  run_probe

  grep -q 'wa-stale' "$NUDGE_LOG" && ok "1: nudged stale in-flight bead with live crew" || bad "1: should have nudged wa-stale"
  grep -q 'wa-fresh' "$NUDGE_LOG" && bad "1: NUDGED a fresh bead (< stale threshold)" || ok "1: skipped fresh bead wa-fresh (not stale yet)"
  grep -q 'dead-crew' "$NUDGE_LOG" && bad "1: NUDGED a dead crew (not a live session)" || ok "1: skipped dead-crew (not in live session list)"
  [ -s "$HEAL_LOG" ] && bad "1: heal actions ran on first sweep" || ok "1: no heal on first sweep"
  [ -s "$SUSPEND_LOG" ] && bad "1: suspend ran on first sweep" || ok "1: no suspend on first sweep"
  [ -f "$TMP/state/wa-stale__mila-wa.nudged" ] && ok "1: state file recorded for wa-stale" || bad "1: state file not written for wa-stale"

  echo ""
  echo "=== Scenario 2: Second sweep immediately — NOT confirmed yet (CLP_CONFIRM_MIN=8) ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_HEAL_ENABLED=1  # enable heal so we can confirm gate stops it
  run_probe

  [ -s "$HEAL_LOG" ] && bad "2: heal ran before CLP_CONFIRM_MIN elapsed" || ok "2: no heal when state file is too fresh"
  # Should re-nudge since HEAL_ENABLED=1 but confirmation not met — actually first-sweep path
  # re-records nudge; the state file IS there but too young, so we re-nudge (first-sweep branch)
  grep -q 'wa-stale' "$NUDGE_LOG" && ok "2: re-nudged on second immediate sweep (not confirmed yet)" || bad "2: expected re-nudge on second sweep"
  [ -s "$SUSPEND_LOG" ] && bad "2: suspend ran before confirmation" || ok "2: no suspend before confirmation"

  echo ""
  echo "=== Scenario 3: Confirmed sweep (backdate state file by CLP_CONFIRM_MIN+1 min) ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  # Backdate the state file so it appears old enough for confirmation
  STATE_FILE="$TMP/state/wa-stale__mila-wa.nudged"
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$STATE_FILE"  # 9 min ago → confirmed
  CLP_HEAL_ENABLED=1
  run_probe

  grep -q 'label remove.*wa-stale.*pilot:dispatched' "$HEAL_LOG" && ok "3: stripped pilot:dispatched from wa-stale" || bad "3: expected pilot:dispatched removal"
  grep -q 'label remove.*wa-stale.*story:in-flight' "$HEAL_LOG" && ok "3: stripped story:in-flight from wa-stale" || bad "3: expected story:in-flight removal"
  grep -q 'assign.*wa-stale' "$HEAL_LOG" && ok "3: cleared assignee on wa-stale" || bad "3: expected assignee clear"
  grep -q 'agent suspend.*mila-wa' "$SUSPEND_LOG" && ok "3: suspended crew agent mila-wa" || bad "3: expected gc agent suspend mila-wa"
  [ -f "$STATE_FILE" ] && bad "3: state file NOT cleared after heal" || ok "3: state file cleared after heal"
  grep -q 'wa-stale' "$NUDGE_LOG" && bad "3: nudged wa-stale on confirmed heal sweep (should heal, not nudge)" || ok "3: no nudge on confirmed-heal sweep"

  echo ""
  echo "=== Scenario 4: Slow crew (alive, NOT stale) — no action ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_HEAL_ENABLED=1; CLP_PROBE_STALE_MIN=25  # raise threshold so STALE_TS bead is NOT stale
  run_probe
  [ -s "$NUDGE_LOG" ] && bad "4: nudged a slow-but-not-stale crew" || ok "4: no action for slow crew below stale threshold"

  echo ""
  echo "=== Scenario 5: DRY_RUN with confirmed state — no actual heal ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_PROBE_STALE_MIN=15; CLP_HEAL_ENABLED=1; CLP_DRY_RUN=1
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$TMP/state/wa-stale__mila-wa.nudged"
  run_probe
  [ -s "$HEAL_LOG" ] && bad "5: DRY_RUN: heal actions ran" || ok "5: DRY_RUN: no heal actions"
  [ -s "$SUSPEND_LOG" ] && bad "5: DRY_RUN: suspend ran" || ok "5: DRY_RUN: no suspend"

  echo ""
  echo "=== Scenario 6: CLP_ENABLED=0 — disabled, no-op ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_DRY_RUN=0; CLP_ENABLED=0; run_probe
  [ ! -s "$NUDGE_LOG" ] && [ ! -s "$HEAL_LOG" ] && ok "6: CLP_ENABLED=0: complete no-op" || bad "6: CLP_ENABLED=0 still acted"

  echo ""
  echo "=== Scenario 7: HEAL_ENABLED=0 with confirmed bead — re-nudge but no heal ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"
  CLP_ENABLED=1; CLP_HEAL_ENABLED=0; CLP_PROBE_STALE_MIN=15
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$TMP/state/wa-stale__mila-wa.nudged"
  run_probe
  [ -s "$HEAL_LOG" ] && bad "7: HEAL_ENABLED=0: heal actions ran" || ok "7: HEAL_ENABLED=0: no heal"
  [ -s "$SUSPEND_LOG" ] && bad "7: HEAL_ENABLED=0: suspend ran" || ok "7: HEAL_ENABLED=0: no suspend"
  grep -q 'wa-stale' "$NUDGE_LOG" && ok "7: HEAL_ENABLED=0: re-nudged confirmed-wedged crew" || bad "7: HEAL_ENABLED=0: expected re-nudge"

  echo ""
  echo "=== Scenario 8: HEAL suspend fails — must notify (silence-is-not-success, ga-4zpf) ==="
  : > "$NUDGE_LOG"; : > "$HEAL_LOG"; : > "$SUSPEND_LOG"; : > "$NOTIFY_LOG"
  touch "$TMP/fail_suspend"
  CLP_ENABLED=1; CLP_HEAL_ENABLED=1; CLP_PROBE_STALE_MIN=15
  echo $(( NOW_ST - (8 * 60 + 60) )) > "$TMP/state/wa-stale__mila-wa.nudged"
  run_probe
  grep -q 'crew-liveness-probe' "$NOTIFY_LOG" && ok "8: notify_fail fired when HEAL's suspend step failed (ga-4zpf)" || bad "8: HEAL suspend failure did NOT notify — silent failure (ga-4zpf regression)"
  rm -f "$TMP/fail_suspend"

  echo ""
  echo "=== Scenario 9: real session-list envelope shape (object, not bare array) parses correctly (ga-ld0ch root cause) ==="
  _load_sessions_json
  echo "$(_live_sessions)" | grep -qF "mila-wa" && ok "9: _live_sessions() found mila-wa in the REAL {sessions:[...]} envelope" || bad "9: _live_sessions() failed against the real envelope shape"
  IDENT9=$(_session_identity "mila-wa")
  { [ -n "$IDENT9" ] && echo "$IDENT9" | grep -qF "sess-A"; } && ok "9: _session_identity() resolved mila-wa's session id" || bad "9: _session_identity() did not resolve mila-wa"

  echo ""
  echo "=== Scenario 10: _heal() records a resume marker + durable bd comment + notify on successful suspend ==="
  : > "$SUSPEND_LOG"; : > "$COMMENT_LOG"; : > "$NOTIFY_LOG"; : > "$TMP/suspended_state"
  MARKER="$CLP_STATE_DIR/mila-wa.suspended-by-probe"
  rm -f "$MARKER" 2>/dev/null
  CLP_DRY_RUN=0
  _load_sessions_json
  _heal "mila-wa" "wa-stale" "$TMP" "$(_session_identity mila-wa)"
  [ -f "$MARKER" ] && ok "10: heal wrote a suspended-by-probe marker for mila-wa" || bad "10: expected marker file after heal"
  grep -q "wa-stale" "$MARKER" 2>/dev/null && ok "10: marker records the bead id" || bad "10: marker missing bead id"
  grep -q "wa-stale" "$COMMENT_LOG" && ok "10: heal left a durable bd comment on the bead" || bad "10: expected a bd comment on heal"
  grep -q "mila-wa" "$NOTIFY_LOG" && ok "10: heal pushed an informational notify (visibility fix for 'ninguem ve')" || bad "10: expected an informational notify on successful heal"

  echo ""
  echo "=== Scenario 11: resume-scan auto-resumes once session identity changes (proof of restart) ==="
  : > "$RESUME_LOG"; : > "$COMMENT_LOG"
  echo "sess-B" > "$TMP/session_id"   # simulate the crew's session having restarted
  CLP_HEAL_ENABLED=1
  run_resume_scan
  grep -q "agent resume.*mila-wa" "$RESUME_LOG" && ok "11: resume-scan resumed mila-wa after its session identity changed" || bad "11: expected gc agent resume mila-wa"
  [ -f "$MARKER" ] && bad "11: marker not cleared after resume" || ok "11: marker cleared after resume"
  grep -qxF "mila-wa" "$TMP/suspended_state" && bad "11: mock still shows mila-wa suspended after resume" || ok "11: mock suspended_state cleared for mila-wa"

  echo ""
  echo "=== Scenario 12: resume-scan does NOT resume when session identity is unchanged ==="
  : > "$RESUME_LOG"
  _load_sessions_json
  _heal "mila-wa" "wa-stale" "$TMP" "$(_session_identity mila-wa)"   # re-suspend; marker back, ident=sess-B
  run_resume_scan   # session_id still sess-B — no change
  [ -s "$RESUME_LOG" ] && bad "12: resumed a crew whose session never changed" || ok "12: no resume while session identity is unchanged"
  [ -f "$MARKER" ] && ok "12: marker preserved (still waiting for a real restart)" || bad "12: marker should not be cleared yet"

  echo ""
  echo "=== Scenario 13: resume-scan clears a stale marker when someone else already resumed the crew ==="
  : > "$RESUME_LOG"
  printf '' > "$TMP/suspended_state"   # simulate: crew was resumed via some OTHER path, not by us
  run_resume_scan
  [ -s "$RESUME_LOG" ] && bad "13: called gc agent resume on an already-resumed crew" || ok "13: no redundant resume call"
  [ -f "$MARKER" ] && bad "13: stale marker not cleared" || ok "13: stale marker cleared once crew was found not-suspended"

  echo ""
  echo "=== Scenario 14: watchdog fires on suspended+live+NO marker (the actual ga-ld0ch incident shape) ==="
  : > "$NOTIFY_LOG"
  rm -f "$CLP_STATE_DIR"/mila-wa.suspended-by-probe "$CLP_STATE_DIR"/mila-wa.watchdog-notified 2>/dev/null
  echo "mila-wa" > "$TMP/suspended_state"   # suspended by some OTHER unmodeled path — no marker
  run_suspend_watchdog
  grep -qi "mila-wa" "$NOTIFY_LOG" && ok "14: watchdog notified on an unexplained suspended+live crew" || bad "14: expected a watchdog notify for mila-wa"

  echo ""
  echo "=== Scenario 15: watchdog does NOT flag a crew already tracked by a probe marker ==="
  : > "$NOTIFY_LOG"
  rm -f "$CLP_STATE_DIR"/mila-wa.watchdog-notified 2>/dev/null
  _record_heal_marker "mila-wa" "wa-stale" "$TMP" "sess-B"
  run_suspend_watchdog
  [ -s "$NOTIFY_LOG" ] && bad "15: watchdog flagged a crew already tracked by resume-scan" || ok "15: watchdog correctly skipped a crew with a probe marker"
  rm -f "$CLP_STATE_DIR"/mila-wa.suspended-by-probe 2>/dev/null

  echo ""
  echo "=== Scenario 16: watchdog does not re-notify the same crew within the dedup window ==="
  : > "$NOTIFY_LOG"
  rm -f "$CLP_STATE_DIR"/mila-wa.watchdog-notified 2>/dev/null
  run_suspend_watchdog
  FIRST_COUNT=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
  run_suspend_watchdog
  SECOND_COUNT=$(wc -l < "$NOTIFY_LOG" | tr -d ' ')
  { [ "$FIRST_COUNT" -ge 1 ] && [ "$SECOND_COUNT" -eq "$FIRST_COUNT" ]; } && ok "16: watchdog did not re-notify within the dedup window" || bad "16: expected exactly one notify across two immediate sweeps (got $FIRST_COUNT then $SECOND_COUNT)"

  echo ""
  echo "=== Scenario 17: _is_committed_suspend distinguishes deliberate (committed) from ga-ld0ch-shaped (uncommitted) suspension ==="
  FIXTURE_REPO="$TMP/fixture-repo"
  mkdir -p "$FIXTURE_REPO/.gascity-gastown-hq/agents/committed-crew" "$FIXTURE_REPO/.gascity-gastown-hq/agents/uncommitted-crew"
  git -C "$FIXTURE_REPO" init -q 2>/dev/null
  printf 'name = "committed-crew"\nsuspended = true\n' > "$FIXTURE_REPO/.gascity-gastown-hq/agents/committed-crew/agent.toml"
  printf 'name = "uncommitted-crew"\nsuspended = false\n' > "$FIXTURE_REPO/.gascity-gastown-hq/agents/uncommitted-crew/agent.toml"
  git -C "$FIXTURE_REPO" add -A 2>/dev/null
  git -C "$FIXTURE_REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q -m "initial: committed-crew is deliberately suspended" 2>/dev/null
  # Simulate the ga-ld0ch shape: flip uncommitted-crew's suspended flag in the
  # WORKING TREE only, exactly like the real incident's diff that never landed a commit.
  printf 'name = "uncommitted-crew"\nsuspended = true\n' > "$FIXTURE_REPO/.gascity-gastown-hq/agents/uncommitted-crew/agent.toml"

  CLP_FRAMEWORK_REPO="$FIXTURE_REPO"
  _is_committed_suspend "committed-crew" && ok "17: committed-crew's suspend is committed — correctly recognized as deliberate" || bad "17: expected committed-crew to be recognized as a committed suspension"
  _is_committed_suspend "uncommitted-crew" && bad "17: uncommitted-crew's UNCOMMITTED suspend was wrongly treated as deliberate (this is the ga-ld0ch shape — must stay flaggable)" || ok "17: uncommitted-crew correctly identified as NOT committed"
  _is_committed_suspend "no-such-crew" && bad "17: a nonexistent agent.toml was wrongly treated as committed-suspended" || ok "17: missing agent.toml fails closed to 'not committed'"
  CLP_FRAMEWORK_REPO="$TMP"

  echo ""
  echo "=== Scenario 18: resume-scan skips (does NOT resume, does NOT touch the marker) when gc session list --json fails ==="
  : > "$RESUME_LOG"
  _record_heal_marker "mila-wa" "wa-stale" "$TMP" "sess-B"   # a marker resume-scan would normally act on
  touch "$TMP/fail_session_list"
  run_resume_scan
  rm -f "$TMP/fail_session_list"
  [ -s "$RESUME_LOG" ] && bad "18: resumed a crew despite gc session list --json having failed (acted on inconclusive data)" || ok "18: no resume attempted while session data was inconclusive"
  [ -f "$MARKER" ] && ok "18: marker left untouched (not discarded) on inconclusive session data" || bad "18: marker was wrongly cleared despite the query having failed, not confirmed"

  echo ""
  echo "=== Scenario 19: resume-scan skips (does NOT clear the marker) when gc agent list --json fails ==="
  : > "$RESUME_LOG"
  # marker from Scenario 18 is still there (untouched, as just proven); leave it
  touch "$TMP/fail_agent_list"
  run_resume_scan
  rm -f "$TMP/fail_agent_list"
  [ -s "$RESUME_LOG" ] && bad "19: resumed a crew despite gc agent list --json having failed" || ok "19: no resume attempted while agent-list data was inconclusive"
  [ -f "$MARKER" ] && ok "19: marker left untouched — a failed query was NOT read as 'confirmed not suspended anymore'" || bad "19: marker was wrongly cleared on a failed (not confirmed-negative) agent list query"
  rm -f "$MARKER" 2>/dev/null

  echo ""
  echo "=== Scenario 20: watchdog does not fire (and does not falsely clear anything) when session data is inconclusive ==="
  : > "$NOTIFY_LOG"
  rm -f "$CLP_STATE_DIR"/mila-wa.suspended-by-probe "$CLP_STATE_DIR"/mila-wa.watchdog-notified 2>/dev/null
  echo "mila-wa" > "$TMP/suspended_state"   # suspended+no-marker — would normally fire (Scenario 14's shape)
  touch "$TMP/fail_session_list"
  run_suspend_watchdog
  rm -f "$TMP/fail_session_list"
  [ -s "$NOTIFY_LOG" ] && bad "20: watchdog notified despite being unable to confirm liveness (acted on inconclusive data)" || ok "20: watchdog stayed silent while session data was inconclusive, rather than guessing"

  echo ""
  echo "=== Scenario 21: watchdog must not false-fire when a LIVE session's name merely CONTAINS a suspended agent's name as a substring (ga-ld0ch gate-fix: grep -qF was unanchored) ==="
  : > "$NOTIFY_LOG"
  rm -f "$CLP_STATE_DIR"/gate-reviewer.suspended-by-probe "$CLP_STATE_DIR"/gate-reviewer.watchdog-notified 2>/dev/null
  echo "gate-reviewer" > "$TMP/extra_agent_name"                   # suspended=true, no live session of its own...
  echo "gate-reviewer-adhoc-9f3a1c2" > "$TMP/extra_session_name"   # ...but a DIFFERENT live session containing its name as a substring
  run_suspend_watchdog
  grep -qi "gate-reviewer" "$NOTIFY_LOG" && bad "21: watchdog false-fired for gate-reviewer via substring match against gate-reviewer-adhoc-9f3a1c2 (unanchored grep -qF regression)" || ok "21: watchdog correctly required an exact name match, not a substring"
  rm -f "$TMP/extra_agent_name" "$TMP/extra_session_name"

  echo ""
  echo "crew-liveness-probe selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_probe
run_resume_scan
run_suspend_watchdog
