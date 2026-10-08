#!/usr/bin/env bash
# config-drift-watcher.sh — Robust config-drift protection for Gas City crew sessions.
#
# STRATEGY (dual-mode protection):
#   1. FILE WATCHER  — polls skill/config files every 3s. On a change it requests
#      "gc reload --soft" as soon as the controller's reload slot is free, so drift is
#      accepted before the reconciler drains sessions. A change is NEVER dropped because
#      the slot was busy: it stays pending and is retried until a reload is accepted.
#
#   2. BACKSTOP HEARTBEAT — a periodic "gc reload --soft" that catches drift from ANY
#      source the file watcher doesn't cover:
#        - Controller's own watch reloads (agent.toml, rig config changes)
#        - Remote pack refresh events
#        - Any config path not tracked by this script's hash
#      It is DUTY-CAPPED (ga-mc42px), see below. It used to fire unconditionally every 20s.
#
# WHY THE HEARTBEAT IS DUTY-CAPPED (ga-mc42px — measured 2026-10-05, load 60-80):
#   The controller has ONE reload slot. An accepted reload holds it until the reconciler
#   tick that processes the reload FINISHES (engine: cmd/gc/city_runtime.go — the reload
#   is completed by completeManualReload() at the END of the tick; reloadActiveTTL = 10m
#   force-clears a wedged slot). "--async" only returns when the request is ACCEPTED
#   (~50ms) — it does not shorten how long the slot stays occupied. Under load a tick takes
#   8-10 min, and a watcher that re-requests as soon as the slot frees keeps it occupied
#   ~100% of the time: 05/10 12:00-21:40 the log shows 5-9 accepted heartbeat reloads per
#   hour at ~600s gaps and ~110 "already in progress" refusals per hour. Everyone else who
#   needs a reload — "gc agent resume" in the peter-wa evening job (120 tries over 1805s,
#   aborted), the Mayor (~6 min wait) — queued behind the watcher.
#
#   Now: the heartbeat reload runs in the background as a SYNCHRONOUS "gc reload --soft",
#   so its wall time is the real time it held the slot (D). After it finishes the heartbeat
#   stays off the slot for  D * (100 - P) / P  seconds (P = HEARTBEAT_MAX_SLOT_DUTY_PCT,
#   default 10, so 9*D), never less than HEARTBEAT_INTERVAL. The heartbeat therefore occupies
#   the slot at most ~P% of the time whatever the load (for holds up to 800s, i.e. the
#   controller's 10 min TTL; a measured hold above that meets the 7200s cooldown ceiling and
#   reaches ~12% at the 1020s bound), and leaves a free window of 9*D
#   after every reload for callers that need one. When reloads are fast (D <= ~2s) the
#   cadence stays at the old 20s. Raise CONFIG_DRIFT_HEARTBEAT_DUTY_PCT to trade slot
#   availability for a tighter backstop. File-change reloads use a looser cap
#   (FILE_MAX_SLOT_DUTY_PCT, default 50) so an editing burst cannot monopolise the slot
#   either. A known change is requested as soon as the slot is free and the file cooldown
#   has passed: at once when the slot is idle, but behind one of OUR OWN reloads it waits
#   that reload's remaining hold plus the file cooldown (up to ~2*D, ~20 min at D=600s).
#
# SAFETY NOTES:
#   - The watcher TRACKS at most one reload of its own at a time (RELOAD_PID) and never
#     probes the slot with a second request (a probe that is accepted just becomes
#     another reload holding the slot). That is bookkeeping, not a promise about processes: a
#     client that survives the watchdog's SIGKILL (logged as leaked), or an orphan from a
#     previous daemon life, is not tracked and may still be running. What it can no longer do
#     is pass for the reload in flight: each reload hands its result back through ITS OWN path
#     (RELOAD_RESULT_CUR), so a late or leftover result is never read as the current one.
#     The watchdog kills a hung client's whole process
#     tree and logs what it saw: a process that survives SIGKILL is logged as leaked, and a
#     tree pgrep could not enumerate is logged as "NOT confirmed killed" — never as killed.
#   - If another caller's reload holds the slot, the heartbeat does NOT assume that reload
#     covers the current drift (it may be a hard reload, or have been accepted before the
#     drift appeared). A refused probe holds nothing, so the heartbeat just retries after
#     min(cooldown, HEARTBEAT_BUSY_RETRY_MAX). A pending FILE change retries every
#     FILE_RETRY_WAIT seconds.
#   - THE THIRD STATE: "I cannot know" must never do what "it was fine" does.
#       * How long a reload held the slot (unreadable result, wall-clock step) is UNKNOWN,
#         not 0s: the learned D is left alone and the cooldown assumes
#         max(D, RELOAD_UNKNOWN_HELD_ASSUMED). A failed client did not hold the slot for D
#         either, so a failure never overwrites D. The same holds for a D that was NEVER
#         learned: it is "" in memory, "-" in the stats file and "No hold time learned yet"
#         in the startup log — never a 0 that a restart would read back as a measurement.
#       * After a RESTART the watcher cannot know whether files changed while it was down
#         (delivery kickstarts it right after the deploy git-pull, often before a change is
#         detected), so the heartbeat embargo is carried over ONLY when the files are
#         unchanged since the last SAVED reload record (a reload that finished OK; its hash is
#         persisted with the stats). A changed or unknown hash queues a file-change reload. If a
#         save fails the record on disk is an older one, and a restart acts on THAT one — the
#         failed save is logged with exactly that consequence.
#   - Do NOT run bulk symlink migrations on live crew; do it in a maintenance window.
#
# Watched paths (for file-change detection):
#   - HQ skill sinks (source + vendor):
#       .gascity-gastown-hq/skills/
#       .gascity-gastown-hq/.claude/skills/
#   - Crew skill copies (per-member):
#       whatsapp_automation/crew/*/.claude/skills/
#       whatsapp_automation/city-local/skills/
#   - City config files:
#       .gascity-gastown-hq/city.toml
#       .gascity-gastown-hq/pack.toml
#   - Agent templates (structural config — triggers session churn if missed):
#       .gascity-gastown-hq/agents/**  (agent.toml + prompt.template.md)
#   - Daemon scripts (source — *.sh and *.py only; __pycache__/.pyc excluded):
#       .gascity-gastown-hq/scripts/*.sh
#       .gascity-gastown-hq/scripts/*.py
#
# Deployed as launchd agent: com.gascity.config-drift-watcher (KeepAlive, /bin/bash 3.2 —
# keep this file bash-3.2 clean: no associative arrays, no ${x^^}, no wait -n).
# Log: .gc/logs/config-drift-watcher.log
# Selftests: hooks-lock-guard.selftest.sh, config-drift-watcher-reload-policy.selftest.sh

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
WA="${CONFIG_DRIFT_WATCHER_WA:-/Users/athos/gt/whatsapp_automation}"   # override: selftest only
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/config-drift-watcher.log"
GC="${GC:-gc}"
HOOKS_DIR="${CITY}/.beads/hooks"
STATE_DIR="$CITY/.gc/state"
RELOAD_RESULT_FILE="$STATE_DIR/config-drift-watcher.reload-result"
RELOAD_STATS_FILE="$STATE_DIR/config-drift-watcher.reload-stats"

# Skip log redirect in lib mode so the selftest can capture its own output.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]; then
    mkdir -p "$LOG_DIR"
    exec >> "$LOG" 2>&1
fi

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [drift-watcher] ERROR: $*"; }

# Wall clock in epoch seconds. A function so the selftest can drive a fake clock.
epoch_now() { date +%s; }

if [[ "${CONFIG_DRIFT_WATCHER_LIB:-0}" != "1" ]]; then
    log "=== config-drift-watcher started (PID $$) ==="

    # Startup marker for delivery freshness verification (ga-fbjg).
    # Prod-test reads this to confirm the live process was restarted, not merely
    # that the script file changed on disk.
    mkdir -p "$STATE_DIR"
    printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/config-drift-watcher.startup"
fi

# ── Build list of watched paths ───────────────────────────────────────────────
# Returns hash of all relevant files. Using find+stat over the watched dirs.
compute_hash() {
    {
        # HQ skill sinks
        find "$CITY/skills" -type f 2>/dev/null
        find "$CITY/.claude/skills" -type f 2>/dev/null
        # Crew skill copies (follow symlinks to detect changes in targets too)
        find "$WA/crew" -path "*/.claude/skills/*" -type f 2>/dev/null
        find "$WA/city-local/skills" -type f 2>/dev/null
        # City config files
        [[ -f "$CITY/city.toml" ]] && echo "$CITY/city.toml"
        [[ -f "$CITY/pack.toml" ]] && echo "$CITY/pack.toml"
        # Agent templates — adding/editing a template changes the effective config hash
        # for all sessions; catching this here requests gc reload --soft before the
        # controller's own watcher can queue drains (immediate vs heartbeat fallback).
        find "$CITY/agents" -type f 2>/dev/null
        # Daemon scripts (source only — .sh and .py; excludes __pycache__/.pyc which
        # are regenerated on every python invocation and would cause reload storms).
        find "$CITY/scripts" -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null
    } | sort | while IFS= read -r f; do
        # Include file path + mtime + size (fast, no md5 overhead per file)
        stat -f '%N %m %z' "$f" 2>/dev/null || true
    done | md5 -q 2>/dev/null || echo "hash-error"
}

# ── Hooks lock-guard (ga-tctky) ───────────────────────────────────────────────
# Asserts $CITY/.beads/hooks is empty AND uchg-locked. bd 1.0.5 auto-installs
# legacy hooks that gc's native store rejects (ga-rfq1j outage). The permanent
# fix keeps the dir empty+locked; a future gc op / gc doctor --fix could silently
# unlock it. This guard re-asserts the lock on every HOOKS_CHECK_INTERVAL and
# remediates + notifies on drift so the gate outage cannot silently recur.

check_hooks_guard() {
    local needs_fix=0 reason_parts=""

    if [ ! -d "$HOOKS_DIR" ]; then
        needs_fix=1
        reason_parts="hooks dir missing"
    else
        local count
        count=$(find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
        if [ "${count:-0}" -gt 0 ]; then
            needs_fix=1
            reason_parts="${reason_parts:+$reason_parts, }non-empty ($count files)"
        fi
        local flags
        flags=$(stat -f '%Sf' "$HOOKS_DIR" 2>/dev/null || echo "-")
        if [[ "$flags" != *uchg* ]]; then
            needs_fix=1
            reason_parts="${reason_parts:+$reason_parts, }uchg missing (flags: $flags)"
        fi
    fi

    [ "$needs_fix" -eq 0 ] && return 0

    log "HOOKS-GUARD: drift detected ($reason_parts) — re-asserting empty+locked"

    # Unlock → remove files → re-lock
    chflags -R nouchg "$HOOKS_DIR" 2>/dev/null || true
    if [ -d "$HOOKS_DIR" ]; then
        find "$HOOKS_DIR" -mindepth 1 -delete 2>/dev/null || true
    else
        mkdir -p "$HOOKS_DIR" || { err "HOOKS-GUARD: cannot mkdir $HOOKS_DIR"; return 1; }
    fi
    chflags uchg "$HOOKS_DIR" || { err "HOOKS-GUARD: chflags uchg failed on $HOOKS_DIR"; return 1; }

    local new_count new_flags
    new_count=$(find "$HOOKS_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
    new_flags=$(stat -f '%Sf' "$HOOKS_DIR" 2>/dev/null || echo "-")

    if [ "${new_count:-1}" -eq 0 ] && [[ "$new_flags" == *uchg* ]]; then
        log "HOOKS-GUARD: remediated OK (empty+uchg-locked) — was: $reason_parts"
        notify -t "Gas City: hooks-guard" -p 3 ".beads/hooks drift remediated: $reason_parts" 2>/dev/null || true
    else
        err "HOOKS-GUARD: remediation FAILED (count=${new_count:-?} flags=${new_flags:-?}) — native store at risk"
        notify -t "Gas City: hooks-guard FAIL" -p 5 ".beads/hooks still drifted after fix attempt ($reason_parts)" 2>/dev/null || true
    fi
}

# ── Configuration ─────────────────────────────────────────────────────────────
POLL_INTERVAL=3         # seconds between file-hash checks
DEBOUNCE_WINDOW=2       # seconds to wait after last file change before reloading
HEARTBEAT_INTERVAL=20   # floor (s) between backstop reloads; also the hooks-guard beat
HOOKS_CHECK_INTERVAL=60 # seconds between hooks-lock-guard sweeps (ga-tctky)

# Reload-slot duty caps (ga-mc42px): the share of wall-clock time this watcher's reloads
# may keep the controller's single reload slot occupied. See the header.
HEARTBEAT_MAX_SLOT_DUTY_PCT="${CONFIG_DRIFT_HEARTBEAT_DUTY_PCT:-10}"
FILE_MAX_SLOT_DUTY_PCT="${CONFIG_DRIFT_FILE_DUTY_PCT:-50}"
HEARTBEAT_MAX_INTERVAL=7200   # sanity ceiling (s) on any cooldown. 9*D stays below it for every hold up to
                              # 800s, which covers the controller's 10 min TTL (600s). A MEASURED hold may be
                              # longer (finish_reload accepts up to RELOAD_CLIENT_TIMEOUT+RELOAD_WATCHDOG_GRACE
                              # = 1020s): there the ceiling bites, and the duty is ~12% (1020s held / 7200s off)
                              # instead of the 10% cap
RELOAD_CLIENT_TIMEOUT=900     # gc reload --timeout (s): above the controller's 10 min TTL so a
                              # force-cleared reload is REPORTED instead of timing out locally
RELOAD_WATCHDOG_GRACE=120     # s past the client timeout before a stuck gc client is killed
FILE_RETRY_WAIT=15            # s between retries of a pending file-change reload
FILE_MAX_FAIL_RETRIES=3       # RETRIES of a failed (non-"busy") file-change reload: 1 try + this many
                              # retries, then the change is left to the heartbeat
HEARTBEAT_BUSY_RETRY_MAX=300  # s: cap on the heartbeat's retry after a refusal. A refused probe holds
                              # nothing, and the holder is not known to cover our drift (see SAFETY NOTES)
RELOAD_UNKNOWN_HELD_ASSUMED=600  # s a reload of UNKNOWN duration is assumed to have held the slot (when no D
                              # was learned yet, or the learned D is shorter): the controller's reloadActiveTTL,
                              # the longest a slot is NORMALLY held. A hold that was measured can be longer
                              # (see HEARTBEAT_MAX_INTERVAL); one that was not measured is assumed this long
RELOAD_MSG_MAX=500            # chars of gc's reply kept for ONE log line; a longer reply is cut and says so ("...")
RELOAD_LITTER_MIN=60          # minutes after which a result file nobody consumed cannot belong to a live runner
                              # (a runner lives at most RELOAD_CLIENT_TIMEOUT+RELOAD_WATCHDOG_GRACE = 17 min): swept

# ── Reload scheduling state ───────────────────────────────────────────────────
prev_hash=""
last_change_time=0
pending_reload=false
last_beat_time=0          # hooks-guard beat (every HEARTBEAT_INTERVAL, as the old heartbeat did)
last_hooks_check=0
RELOAD_PID=""             # background "gc reload --soft" of THIS watcher; "" = none in flight
RELOAD_RESULT_CUR=""      # the ONE path the reload in flight hands its result back through ("" = none in flight)
reload_seq=0              # counts reloads started by this process (part of every result path)
litter_warned=false       # sweep_reload_result_litter says a leftover it cannot remove once per run, not per reload
pending_cause=""          # why a file-change reload is pending: what the log says about it
RELOAD_TRIGGER=""         # heartbeat | file-change
RELOAD_STARTED=0
RELOAD_COVERS_HASH=""     # the file hash in force when the in-flight reload was requested
hb_next_allowed=0         # earliest epoch the next heartbeat reload may start
file_next_allowed=0       # earliest epoch the next file-change reload may start
file_fail_count=0
file_busy_streak=0
last_reload_secs=""       # D: how long the last reload of ours that we could MEASURE held the slot.
                          # "" = NEVER learned — not 0s. A measured 0 is a number (a sub-second hold)
reload_held_total=0       # sum of the measured holds since start (for the duty line in the log)
reload_count=0
reload_unknown_count=0    # reloads that ran but whose hold time could not be measured
watcher_started_at=0
stats_carried_over=false  # true once load_reload_stats carried over a LEARNED D (not merely read a stats file)
KILL_TREE_SEEN=""         # kill_process_tree's report: the descendants it found (space separated)...
KILL_TREE_COMPLETE=true   # ...whether pgrep could enumerate the whole tree (false: the list is partial)...
KILL_TREE_SURVIVORS=""    # ...and which of the signalled pids were still alive after SIGKILL
covered_hash=""           # file hash the last reload that finished OK was requested against ("" = unknown)
startup_gap_verdict=""    # what init_watcher_state concluded about the restart gap: unchanged|changed|unknown
startup_gap_note=""       # the same, in words, for the log

# uint_or_empty <text> — a canonical non-negative integer from untrusted text, or nothing at all
# (not a number, negative, or too long to be a sane count of seconds). Leading zeros are decimal:
# "08" is 8, never the octal error that aborts a bash 3.2 arithmetic expansion. Callers test the
# result with [ -n ] — "not a number" is a THIRD state and must not be confused with 0.
uint_or_empty() {
    local v="${1:-}"
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
    if (( ${#v} > 12 )); then return 0; fi
    echo $(( 10#$v ))
}

# hash_is_known <text> — true for a real file hash. Empty, "-" (the stats file's placeholder) and
# "hash-error" (compute_hash could not run md5) mean "cannot tell", which is not "no drift".
hash_is_known() {
    case "${1:-}" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
}

# clamp_duty_pct <pct> — the duty percentage slot_cooldown_secs really uses: garbage -> 10, 0 -> 1,
# above 100 -> 100. One definition, so the startup log prints the decided value, not the raw input.
clamp_duty_pct() {
    local duty
    duty=$(uint_or_empty "${1:-}")
    [ -n "$duty" ] || duty=10
    if (( duty < 1 )); then duty=1; fi
    if (( duty > 100 )); then duty=100; fi
    echo "$duty"
}

# secs_txt <secs> — a measured duration for the log: "42s", and "<1s" for 0. The clock has 1s
# resolution, so a measured 0 means "under a second", and a bare "0s" would read like the
# never-learned / unknown case this watcher keeps apart from it.
secs_txt() {
    if [ "${1:-}" = 0 ]; then echo "<1s"; else echo "${1}s"; fi
}

# slot_cooldown_secs <held_secs> <duty_pct> <floor_secs> — how long to stay off the reload
# slot after a reload that held it <held_secs>, so the slot is occupied at most <duty_pct>%
# of the time: held * (100 - duty) / duty, clamped to [floor, HEARTBEAT_MAX_INTERVAL].
# Garbage input degrades to "no history" (held=0 → floor), never to a division by zero. Callers
# that can tell "unknown" from "0s" (finish_reload) decide that BEFORE calling this.
slot_cooldown_secs() {
    local held floor duty cd
    held=$(uint_or_empty "${1:-}");  [ -n "$held" ]  || held=0
    floor=$(uint_or_empty "${3:-}"); [ -n "$floor" ] || floor=0
    duty=$(clamp_duty_pct "${2:-}")
    cd=$(( held * (100 - duty) / duty ))
    if (( cd < floor )); then cd=$floor; fi
    if (( cd > HEARTBEAT_MAX_INTERVAL )); then cd=$HEARTBEAT_MAX_INTERVAL; fi
    echo "$cd"
}

# slot_duty_line <now> — "own slot duty since start: X% (N reloads, Ts held / Us up)".
# The proof, in the log, that this watcher leaves the slot free. Reloads whose hold time could
# not be measured are counted separately, not folded into the held total as 0s.
slot_duty_line() {
    local now="$1" up pct unk=""
    up=$(( now - watcher_started_at ))
    if (( up < 1 )); then up=1; fi
    pct=$(( reload_held_total * 100 / up ))
    if (( reload_unknown_count > 0 )); then unk=", ${reload_unknown_count} of unknown duration not counted as held"; fi
    echo "own slot duty since start: ${pct}% (${reload_count} reloads, ${reload_held_total}s held / ${up}s up${unk})"
}

# save_reload_stats — "<D> <heartbeat embargo epoch> <covered hash>" (one line, atomic). D is "-" until
# an OK reload measured one (a D never learned is NOT saved as 0: it would come back as a measured
# 0s); the hash is what the last reload that finished OK was requested against, "-" when unknown.
save_reload_stats() {
    local h="-" d
    if hash_is_known "$covered_hash"; then h=$covered_hash; fi
    d=$(uint_or_empty "$last_reload_secs"); [ -n "$d" ] || d="-"
    if mkdir -p "$STATE_DIR" 2>/dev/null \
        && printf '%s %s %s\n' "$d" "$hb_next_allowed" "$h" > "$RELOAD_STATS_FILE.tmp" 2>/dev/null \
        && mv "$RELOAD_STATS_FILE.tmp" "$RELOAD_STATS_FILE" 2>/dev/null; then
        return 0
    fi
    # Never fatal (a full disk must not stop the watcher), never silent. What a restart does about
    # it depends on what is ALREADY on disk, because the next start reads the last record that WAS
    # saved. Three outcomes: none -> the restart gap is unknown -> a file-change reload is queued and
    # no embargo is carried; an older record and the files changed since -> "changed": the same;
    # an older record whose hash still matches -> "unchanged": nothing is queued, ITS older D and
    # embargo apply, and this reload's own cooldown is gone.
    err "could not save the reload stats to '$RELOAD_STATS_FILE' — a restart before the next successful save reads the last record that WAS saved (no record: the restart gap is unknown and a file-change reload is queued; an older record and the files changed since: the same; an older record and the files unchanged: its older D and embargo apply and the cooldown of this reload is lost)"
    return 0
}

# load_reload_stats <now> — carry D across restarts, and decide what the restart gap may have
# dropped. Needs prev_hash (the hash of the tree as it is NOW) to be set already.
#
# A fresh process cannot know whether files changed while the old one was down, or while a
# file-change reload was still pending (slot busy / our own reload in flight). So:
#   * the saved hash is known AND equals the current one -> nothing changed since the last reload
#     record that was saved (a reload that finished OK; it is the newest one only if its save
#     worked, see save_reload_stats): carry the heartbeat embargo too (a restart must not re-open
#     the slot to the watcher: every delivery restarts this daemon);
#   * known but different -> the files changed in the gap: queue a file-change reload NOW and do
#     not carry the embargo (it would suppress the very backstop that covers this);
#   * absent / unreadable / legacy format / hash-error -> UNKNOWN. Not "covered": same as changed.
load_reload_stats() {
    local now="$1" line="" a="" b="" c="" d_saved emb_saved
    covered_hash=""
    if [ -r "$RELOAD_STATS_FILE" ]; then
        line=$(head -1 "$RELOAD_STATS_FILE" 2>/dev/null) || line=""
        read -r a b c <<< "$line"
    fi
    d_saved=$(uint_or_empty "$a")      # "-" (never learned), garbage, legacy: nothing — NOT 0
    emb_saved=$(uint_or_empty "$b")
    # Held to the bound a fresh measurement is held to (finish_reload): a longer D cannot have been
    # measured, so it is not credible (a hand-edited file, clock skew) and is not carried over.
    if [ -n "$d_saved" ] && (( d_saved > RELOAD_CLIENT_TIMEOUT + RELOAD_WATCHDOG_GRACE )); then d_saved=""; fi
    if [ -n "$d_saved" ]; then
        last_reload_secs=$d_saved
        stats_carried_over=true
    fi
    if hash_is_known "$c"; then covered_hash=$c; fi

    if hash_is_known "$prev_hash" && [ -n "$covered_hash" ] && [ "$covered_hash" = "$prev_hash" ]; then
        startup_gap_verdict=unchanged
        # The note says "carried over" only when a saved embargo really was applied: one that is
        # over already, absent, or beyond the ceiling (clock skew, a hand-edited file) changes
        # nothing, and the log must not claim a protection the code did not give.
        if [ -n "$emb_saved" ] && (( emb_saved > hb_next_allowed && emb_saved <= now + HEARTBEAT_MAX_INTERVAL )); then
            hb_next_allowed=$emb_saved
            startup_gap_note="files unchanged since the last saved reload record (a reload that finished OK, hash ${covered_hash}) — heartbeat embargo carried over (next heartbeat not before epoch ${emb_saved})"
        else
            startup_gap_note="files unchanged since the last saved reload record (a reload that finished OK, hash ${covered_hash}) — no saved heartbeat embargo applies (it is over, absent or not credible); the ${HEARTBEAT_INTERVAL}s heartbeat floor holds"
        fi
        return 0
    fi
    if hash_is_known "$prev_hash" && [ -n "$covered_hash" ]; then
        startup_gap_verdict=changed
        startup_gap_note="files changed since the last saved reload record (a reload that finished OK; was ${covered_hash}, now ${prev_hash}) — file-change reload queued, heartbeat embargo NOT carried over"
        pending_cause="restart gap, verdict changed: this process saw no change, but the files differ from what the last saved reload covered"
    else
        startup_gap_verdict=unknown
        startup_gap_note="no usable record of what the last reload covered (stats '${RELOAD_STATS_FILE}', hash now '${prev_hash:-none}') — assuming NOT covered: file-change reload queued, heartbeat embargo NOT carried over"
        pending_cause="restart gap, verdict unknown: no usable record of what the last reload covered, so a change cannot be ruled out"
    fi
    pending_reload=true
    last_change_time=$(( now - DEBOUNCE_WINDOW ))
}

# init_watcher_state <now> — daemon startup, as a function so the selftest can replay the restart
# gap with a fake clock (this logic used to sit below the library guard, out of its reach).
init_watcher_state() {
    local now="$1"
    watcher_started_at=$now
    prev_hash=$(compute_hash)
    last_beat_time=$now
    hb_next_allowed=$(( now + HEARTBEAT_INTERVAL ))
    load_reload_stats "$now"
}

# startup_stats_line — the startup log line about D. "held the slot" is said ONLY for a D that a
# reload really measured; a D never learned (no stats file, unreadable, '-', not credible) says so
# instead of showing a number.
startup_stats_line() {
    if [ "$stats_carried_over" = "true" ] && [ -n "$last_reload_secs" ]; then
        echo "Carried over from the previous run: the last reload that could be measured held the slot $(secs_txt "$last_reload_secs")"
    else
        echo "No hold time learned yet (stats '${RELOAD_STATS_FILE}': absent, unreadable, or D never measured) — the cadence is learned from the first reload that finishes OK"
    fi
}

# descendants_of <pid> — every descendant of <pid>, one per line, breadth first. A snapshot: take
# it BEFORE killing, while the tree is intact. Returns 0 when the whole tree was enumerated and 2
# when it could not be: pgrep failed for some pid (rc >= 2, or no pgrep at all: rc 127), printed
# something that is not a pid, or the tree is implausibly big. pgrep's rc 1 is NOT a failure — it
# is its answer for "no children". Whatever a FAILED pgrep printed is not trusted and not listed:
# a caller signals these pids.
descendants_of() {
    local queue="$1" next cur kids rc k complete=0 n=0
    while [ -n "$queue" ]; do
        next=""
        for cur in $queue; do
            kids=$(pgrep -P "$cur" 2>/dev/null); rc=$?
            if [ "$rc" -ge 2 ]; then complete=2; continue; fi
            for k in $kids; do
                case "$k" in ''|*[!0-9]*|0|1) complete=2; continue ;; esac
                n=$(( n + 1 ))
                if [ "$n" -gt 500 ]; then return 2; fi
                echo "$k"
                next="$next $k"
            done
        done
        queue=$next
    done
    return $complete
}

# kill_process_tree <pid> — SIGTERM <pid> and every descendant, then SIGKILL what is still alive a
# second later. Killing just the wrapper subshell leaves the gc client orphaned (ga-mc42px gate FAIL
# 1/3): the client is a grandchild of the runner. It REPORTS what it knew, so the caller can say
# "killed" only when that is true (gate FAIL 2/3: "could not list the descendants" is not "there
# were none"):
#   KILL_TREE_SEEN       the descendants found and signalled (space separated, may be empty)
#   KILL_TREE_COMPLETE   true only when pgrep could enumerate the WHOLE tree
#   KILL_TREE_SURVIVORS  the signalled pids still alive after SIGKILL
# Status 0 = a CONFIRMED kill (complete enumeration, no survivor); 1 = anything less.
kill_process_tree() {
    local root="$1" desc drc pids p
    KILL_TREE_SEEN=""; KILL_TREE_SURVIVORS=""; KILL_TREE_COMPLETE=true
    desc=$(descendants_of "$root"); drc=$?
    if [ "$drc" -ne 0 ]; then KILL_TREE_COMPLETE=false; fi
    for p in $desc; do KILL_TREE_SEEN="${KILL_TREE_SEEN:+$KILL_TREE_SEEN }$p"; done
    pids="${KILL_TREE_SEEN:+$KILL_TREE_SEEN }$root"
    for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
    sleep 1
    for p in $pids; do
        if kill -0 "$p" 2>/dev/null; then
            kill -KILL "$p" 2>/dev/null || true
        fi
    done
    sleep 0.2
    for p in $pids; do
        if kill -0 "$p" 2>/dev/null; then KILL_TREE_SURVIVORS="${KILL_TREE_SURVIVORS:+$KILL_TREE_SURVIVORS }$p"; fi
    done
    [ "$KILL_TREE_COMPLETE" = true ] && [ -z "$KILL_TREE_SURVIVORS" ]
}

# one_line_ascii — stdin as ONE trimmed line of printable ASCII. Whitespace becomes a space, and every run of
# bytes outside printable ASCII becomes one "?": the length cut in reload_message_text is bytewise, and under
# launchd's C locale a cut inside a multibyte character would write an invalid byte into the log.
one_line_ascii() {
    local s
    s=$(tr '\n\r\t' '   ' | LC_ALL=C tr -cs ' -~' '?')
    s="${s#"${s%%[! ]*}"}"
    s="${s%"${s##*[! ]}"}"
    printf '%s' "$s"
}

# reload_message_text <gc's merged stdout+stderr> <gc's exit status> — gc's reply as ONE short line for the log.
# Real gc in this city puts "warning:" lines on stderr in front of EVERY reply (a local pack edit;
# 453 chars in the first one), and the runner merges stderr into the reply (2>&1), so the real text
# always comes AFTER them. Kept, the first N chars were only that preamble: an OK reload logged
# "OK, took 603s: warning: builtin pack…" and a failed one the same, the cause cut off and the pack
# warning read as the reason (gate FAIL 3/3). Lines that START with "warning:" are dropped; a real error
# that merely mentions a warning stays. Four states, kept apart: no output at all; a reply; only warnings
# on a call that SUCCEEDED (they say nothing about the reload: "(gc printed only warning lines…)", never
# "no output" — gc did print); only warnings on a call that FAILED (then they are all there is to say why,
# so they are kept — dropping them would hide the one cause gc gave). A reply longer than RELOAD_MSG_MAX is
# cut and says so.
reload_message_text() {
    local raw="$1" rc="${2:-0}" kept
    if [ -z "$raw" ]; then echo "no output"; return 0; fi
    kept=$(printf '%s\n' "$raw" | grep -v '^warning:' | one_line_ascii)
    if [ -z "$kept" ]; then
        if [ "$rc" = 0 ]; then
            echo "(gc printed only warning lines, no reply text)"
            return 0
        fi
        kept="(gc failed and printed only warning lines) $(printf '%s\n' "$raw" | one_line_ascii)"
    fi
    if (( ${#kept} > RELOAD_MSG_MAX )); then kept="${kept:0:$RELOAD_MSG_MAX}..."; fi
    echo "$kept"
}

# sweep_reload_result_litter — HOUSEKEEPING, not part of the hand-off. Nothing ever READS what this removes:
# a reload's result is read only from that reload's own path (RELOAD_RESULT_CUR), so a leftover here cannot be
# mistaken for a result however it got there. What it tidies: the single fixed path earlier versions handed
# results back through, and per-reload results nobody consumed (the daemon died mid-reload; a client that
# outlived the watchdog finished late) once they are too old to belong to any live runner — a recent one is
# left alone, it may be a live runner's of another instance. After the removal it looks again, and a leftover
# that is STILL there (the fixed path, or an aged per-reload file) is said once per run — the first one found,
# with why it is harmless: failing to remove it must not stop a reload, and must not read as "nothing there".
sweep_reload_result_litter() {
    local base stuck=""
    base=$(basename "$RELOAD_RESULT_FILE")
    rm -f "$RELOAD_RESULT_FILE" "$RELOAD_RESULT_FILE.tmp" 2>/dev/null || true
    find "$STATE_DIR" -maxdepth 1 -type f -name "${base}.*" -mmin +"$RELOAD_LITTER_MIN" -exec rm -f {} + 2>/dev/null || true
    # Look again at what was meant to go: "rm failed" and "nothing was there" must not look the same.
    if [ -e "$RELOAD_RESULT_FILE" ]; then
        stuck="$RELOAD_RESULT_FILE"
    elif [ -e "$RELOAD_RESULT_FILE.tmp" ]; then
        stuck="$RELOAD_RESULT_FILE.tmp"
    else
        stuck=$(find "$STATE_DIR" -maxdepth 1 -type f -name "${base}.*" -mmin +"$RELOAD_LITTER_MIN" 2>/dev/null | head -1)
    fi
    if [ -n "$stuck" ] && [ "$litter_warned" != true ]; then
        litter_warned=true
        err "cannot remove '$stuck' (a leftover reload result) — harmless: results are read only from each reload's own path, so it is never read (said once per run, for the first one found)"
    fi
}

# release_reload_runner — stop tracking the reload in flight: its pid and its result path. It NEVER wait()s.
# A wait() on a runner that is still running blocks the whole daemon loop (no hooks guard, no file watching)
# for up to the client timeout; disown hands the child to bash, which reaps it when it exits. The result path
# is forgotten with the pid: nothing reads that path again, so a late write to it is litter, swept by age.
release_reload_runner() {
    if [ -n "$RELOAD_PID" ]; then disown "$RELOAD_PID" 2>/dev/null || true; fi
    RELOAD_PID=""
    RELOAD_RESULT_CUR=""
}

# start_reload <trigger> <now> — fire "gc reload --soft" in the background. It is the
# SYNCHRONOUS form on purpose: its wall time is how long this reload held the controller's
# slot (D), which is the number the heartbeat cadence is derived from. The result is handed
# back through THIS reload's own path, $RELOAD_RESULT_CUR ("<ok|busy|fail> <secs> <rc>" + one
# message line), written atomically as the very last step: a file at that path means "finished".
# The path is unique per start (daemon pid, sequence, start time, a random number): a collision
# would need all four to repeat, so for practical purposes nothing that is already on disk — a
# leftover that could not be removed, a late write from a runner the watchdog gave up on, an
# orphan of a previous daemon life — can be at it. "A file exists" and "THIS reload finished"
# are the same fact only because of that.
start_reload() {
    local trigger="$1" now="$2" result
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    sweep_reload_result_litter
    reload_seq=$(( reload_seq + 1 ))
    result="$RELOAD_RESULT_FILE.$$.$reload_seq.$now.$RANDOM"
    RELOAD_RESULT_CUR="$result"
    RELOAD_TRIGGER="$trigger"
    RELOAD_STARTED=$now
    RELOAD_COVERS_HASH="$prev_hash"   # what this reload is requested against (see finish_reload)
    log "reload[$trigger] requested — gc reload --soft (sync, in background, timeout ${RELOAD_CLIENT_TIMEOUT}s)"
    (
        t0=$(date +%s)
        out=$("$GC" reload --soft --timeout "${RELOAD_CLIENT_TIMEOUT}s" --city "$CITY" 2>&1)
        rc=$?
        t1=$(date +%s)
        if [ "$rc" -eq 0 ]; then
            outcome=ok
        elif printf '%s\n' "$out" | grep "already in progress" >/dev/null; then
            outcome=busy
        else
            outcome=fail
        fi
        msg=$(reload_message_text "$out" "$rc")
        if { printf '%s %s %s\n' "$outcome" "$(( t1 - t0 ))" "$rc"; printf '%s\n' "$msg"; } > "$result.tmp" 2>/dev/null \
            && mv "$result.tmp" "$result" 2>/dev/null; then
            :
        else
            err "reload runner could not hand its result back through '$result' (outcome $outcome, rc $rc, $(( t1 - t0 ))s: ${msg}) — the watcher will count this reload as exited without a result"
        fi
    ) &
    RELOAD_PID=$!
}

# finish_reload <trigger> <ok|busy|fail> <held_secs> <rc> <message> <now> — account for a
# finished reload and schedule what may run next. Pure state update (no process handling),
# so the selftest can replay an incident timeline through it.
#
# <held_secs> is how long the reload ran, or ANYTHING NOT A SANE NUMBER when that is unknown
# (unreadable result, runner killed, a wall-clock step made it negative or absurd). Unknown is
# not 0s: D (last_reload_secs) is left alone — "" while none was ever learned, which is not 0 —
# and the cooldown assumes the worst we know of. A FAILED reload is never a measurement of D
# either (a client that died in 1s did not hold the slot for the 600s the previous reload did),
# and only a reload that finished OK is "covered".
finish_reload() {
    local trigger="$1" outcome="$2" held_raw="$3" rc="$4" msg="$5" now="$6"
    local held eff hb_cd file_cd retry held_txt d_txt
    held=$(uint_or_empty "$held_raw")
    # A reload cannot outlive its own client timeout + the watchdog grace: more is a clock step.
    if [ -n "$held" ] && (( held > RELOAD_CLIENT_TIMEOUT + RELOAD_WATCHDOG_GRACE )); then held=""; fi
    case "$outcome" in
        ok|fail)
            reload_count=$(( reload_count + 1 ))
            if [ -n "$held" ]; then
                eff=$held
                if [ "$outcome" = "ok" ]; then
                    last_reload_secs=$held
                elif (( eff > RELOAD_UNKNOWN_HELD_ASSUMED )); then
                    eff=$RELOAD_UNKNOWN_HELD_ASSUMED    # a FAILED client's wall time is not a hold time; the controller's TTL is the most a slot is normally held
                fi
                reload_held_total=$(( reload_held_total + eff ))
                held_txt=$(secs_txt "$held")
            else
                eff=${last_reload_secs:-0}
                if (( eff < RELOAD_UNKNOWN_HELD_ASSUMED )); then eff=$RELOAD_UNKNOWN_HELD_ASSUMED; fi
                reload_unknown_count=$(( reload_unknown_count + 1 ))
                if [ -n "$last_reload_secs" ]; then d_txt="learned D=$(secs_txt "$last_reload_secs") left untouched"; else d_txt="no D learned yet"; fi
                held_txt="an UNKNOWN time (cooldown assumes ${eff}s; ${d_txt})"
            fi
            hb_cd=$(slot_cooldown_secs "$eff" "$HEARTBEAT_MAX_SLOT_DUTY_PCT" "$HEARTBEAT_INTERVAL")
            file_cd=$(slot_cooldown_secs "$eff" "$FILE_MAX_SLOT_DUTY_PCT" "$DEBOUNCE_WINDOW")
            hb_next_allowed=$(( now + hb_cd ))
            file_next_allowed=$(( now + file_cd ))
            file_busy_streak=0
            if [ "$outcome" = "ok" ]; then
                covered_hash="$RELOAD_COVERS_HASH"
                file_fail_count=0
                log "reload[$trigger] OK, took ${held_txt}: ${msg:-no output}"
            else
                err "reload[$trigger] FAILED rc=$rc after ${held_txt}: ${msg:-no output}"
                if [ "$trigger" = "file-change" ]; then
                    if (( file_fail_count < FILE_MAX_FAIL_RETRIES )); then
                        file_fail_count=$(( file_fail_count + 1 ))
                        pending_reload=true
                        retry=$file_cd
                        if (( retry < FILE_RETRY_WAIT )); then retry=$FILE_RETRY_WAIT; fi
                        file_next_allowed=$(( now + retry ))
                        err "file-change reload will be retried in ${retry}s (retry $file_fail_count of $FILE_MAX_FAIL_RETRIES)"
                    else
                        err "file-change reload gave up after $(( FILE_MAX_FAIL_RETRIES + 1 )) failures (1 try + $FILE_MAX_FAIL_RETRIES retries) — left to the backstop heartbeat, which is not due for ${hb_cd}s"
                        file_fail_count=0
                    fi
                fi
            fi
            save_reload_stats
            log "next heartbeat reload not before +${hb_cd}s, next file-change reload not before +${file_cd}s; $(slot_duty_line "$now")"
            ;;
        busy)
            # Someone else's reload holds the slot; we did not take it, so there is no D to learn,
            # and nothing of ours is held. We do not know that holder covers our drift.
            if [ "$trigger" = "file-change" ]; then
                pending_reload=true
                file_next_allowed=$(( now + FILE_RETRY_WAIT ))
                file_busy_streak=$(( file_busy_streak + 1 ))
                if (( file_busy_streak == 1 || file_busy_streak % 20 == 0 )); then
                    log "reload[file-change] busy (another reload holds the slot, streak $file_busy_streak) — the file change stays pending, retry every ${FILE_RETRY_WAIT}s"
                fi
            else
                # A D that was never learned ("") reads as 0s inside slot_cooldown_secs, so the probe cadence here
                # is the HEARTBEAT_INTERVAL floor — the same as for a measured 0s. That is deliberate: a REFUSED
                # probe holds nothing. The first probe that is ACCEPTED in that state is a reload whose hold time
                # nobody knows yet (D is learned only when it finishes OK), not a cheap one.
                hb_cd=$(slot_cooldown_secs "$last_reload_secs" "$HEARTBEAT_MAX_SLOT_DUTY_PCT" "$HEARTBEAT_INTERVAL")
                if (( hb_cd > HEARTBEAT_BUSY_RETRY_MAX )); then hb_cd=$HEARTBEAT_BUSY_RETRY_MAX; fi
                hb_next_allowed=$(( now + hb_cd ))
                log "reload[heartbeat] busy (another reload holds the slot; not assumed to cover the current drift) — probing again not before +${hb_cd}s"
            fi
            ;;
    esac
}

# consume_reload_result <now> — if the reload in flight has left ITS result, account for it and say so.
# Only the current reload's own path is ever read (RELOAD_RESULT_CUR, unique per start), so a file there
# is that runner's last act: it is done, or about to exit — and the runner is NOT waited for (see
# release_reload_runner). Returns 1 when there is no result (nothing was changed).
consume_reload_result() {
    local now="$1" outcome="" held="" rc="" msg="" result="$RELOAD_RESULT_CUR"
    [ -n "$result" ] && [ -f "$result" ] || return 1
    { read -r outcome held rc; read -r msg; } < "$result" || true
    rm -f "$result" "$result.tmp" 2>/dev/null || true   # litter at worst: this path belongs to the reload being accounted for now and is never read again
    case "$outcome" in
        ok|busy|fail) ;;
        *) outcome=fail; held=""; msg="unreadable reload result" ;;
    esac
    release_reload_runner
    finish_reload "$RELOAD_TRIGGER" "$outcome" "$held" "${rc:-?}" "$msg" "$now"
    return 0
}

# poll_reload_result <now> — reap the background reload, if it has finished, or kill it when it
# has outlived its own client timeout.
poll_reload_result() {
    local now="$1" verdict
    [ -n "$RELOAD_PID" ] || return 0
    if consume_reload_result "$now"; then
        return 0
    fi
    if ! kill -0 "$RELOAD_PID" 2>/dev/null; then
        # The runner is gone. It may have written its result and exited between the check above
        # and this one — look again before calling that a failure.
        if consume_reload_result "$now"; then
            return 0
        fi
        # Killed from outside and left no result. How long it held the slot is UNKNOWN.
        release_reload_runner
        finish_reload "$RELOAD_TRIGGER" fail "" "?" "reload runner exited without a result" "$now"
        return 0
    fi
    if (( now - RELOAD_STARTED > RELOAD_CLIENT_TIMEOUT + RELOAD_WATCHDOG_GRACE )); then
        # Disowned BEFORE the kill, and never wait()ed on: a job bash still tracks that dies of a signal
        # makes it print "Terminated" plus the runner's whole script into the log, and a wait() on a
        # process that survived SIGKILL would freeze the daemon loop. Bash still reaps the child.
        disown "$RELOAD_PID" 2>/dev/null || true
        if kill_process_tree "$RELOAD_PID"; then
            # A confirmed kill: the tree was fully enumerated and nothing in it survived. Say WHAT was seen.
            if [ -n "$KILL_TREE_SEEN" ]; then
                verdict="the runner and its descendants (pids ${KILL_TREE_SEEN}) were killed"
            else
                verdict="the runner was killed; no descendant process was found under it"
            fi
        else
            # Not confirmed. Each way it can fall short is said on its own: "could not list the tree" is
            # not "there was nothing in it", and a survivor is never reported as killed.
            verdict=""
            if [ "$KILL_TREE_COMPLETE" != true ]; then
                verdict="the process tree could NOT be enumerated (pgrep failed) — only the runner and the descendants found (${KILL_TREE_SEEN:-none}) were signalled, so the gc client is NOT confirmed killed"
            fi
            if [ -n "$KILL_TREE_SURVIVORS" ]; then
                verdict="${verdict:+$verdict; }kill FAILED — still alive (leaked): ${KILL_TREE_SURVIVORS}"
            fi
        fi
        # The abandoned reload's result path is forgotten, not cleaned up for correctness: a client that
        # survived (logged as leaked) may still write there, late, and nothing will read it. Removing it is
        # tidiness; the age sweep catches what this misses.
        if [ -n "$RELOAD_RESULT_CUR" ]; then rm -f "$RELOAD_RESULT_CUR" "$RELOAD_RESULT_CUR.tmp" 2>/dev/null || true; fi
        release_reload_runner
        finish_reload "$RELOAD_TRIGGER" fail "" "?" "reload exceeded ${RELOAD_CLIENT_TIMEOUT}s + ${RELOAD_WATCHDOG_GRACE}s grace — ${verdict}" "$now"
    fi
}

# heartbeat_due <now> — may the backstop heartbeat start a reload right now? Never while one of
# ours is in flight, never while a file change is waiting its turn (that reload will cover it),
# and never inside the cooldown that keeps the slot duty at or below the cap.
heartbeat_due() {
    [ -z "$RELOAD_PID" ] && [ "$pending_reload" != "true" ] && (( $1 >= hb_next_allowed ))
}

# file_reload_due <now> — may a pending, debounced file change start its reload right now?
file_reload_due() {
    [ -z "$RELOAD_PID" ] && [ "$pending_reload" = "true" ] \
        && (( $1 - last_change_time >= DEBOUNCE_WINDOW )) && (( $1 >= file_next_allowed ))
}

# watcher_tick [now] — one pass of the main loop (everything except the sleep), so the selftest
# can drive it with a fake clock. The daemon passes nothing and reads the clock itself.
watcher_tick() {
    local now="${1:-}" current_hash
    [ -n "$now" ] || now=$(epoch_now)

    poll_reload_result "$now"

    # ── HOOKS GUARD: every HEARTBEAT_INTERVAL (what the old heartbeat block did) ──
    if (( now - last_beat_time >= HEARTBEAT_INTERVAL )); then
        check_hooks_guard
        last_beat_time=$now
    fi

    # ── HOOKS LOCK-GUARD: periodic assertion (ga-tctky) ─────────────────────
    if (( now - last_hooks_check >= HOOKS_CHECK_INTERVAL )); then
        check_hooks_guard
        last_hooks_check=$now
    fi

    # ── FILE WATCHER: detect and debounce file changes ──────────────────────
    current_hash=$(compute_hash)

    if [[ "$current_hash" != "$prev_hash" ]]; then
        # Hash changed — note the time, mark pending
        last_change_time=$now
        pending_reload=true
        pending_cause="a file hash change seen by this process"
        prev_hash="$current_hash"
        log "Hash changed (new: $current_hash) — debouncing..."
    fi

    # ── RELOAD SCHEDULING: a file change outranks the heartbeat ─────────────
    # The log says WHY the reload is due: a restart-gap reload (and every busy retry of it) is not a file
    # change this process detected, and "File change detected" would claim one.
    if file_reload_due "$now"; then
        log "File-change reload due (${pending_cause:-cause not recorded}) — requesting gc reload --soft"
        pending_reload=false
        start_reload file-change "$now"
    elif heartbeat_due "$now"; then
        start_reload heartbeat "$now"
    fi
}

# Library-source guard — selftests source this file with CONFIG_DRIFT_WATCHER_LIB=1 to
# exercise check_hooks_guard and the reload scheduling without starting the daemon loop.
if [ "${CONFIG_DRIFT_WATCHER_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# Initialize hash (don't trigger on start — unless the restart gap says a change may be unaccepted)
now=$(epoch_now)
init_watcher_state "$now"

# Assert hooks-lock invariant at startup before first heartbeat.
check_hooks_guard

log "Initial hash: $prev_hash"
log "Watching: $CITY/skills, $CITY/.claude/skills, $WA/crew/*/.claude/skills/, $WA/city-local/skills/, city.toml, pack.toml, agents/, scripts/*.{sh,py}"
log "Poll interval: ${POLL_INTERVAL}s, debounce: ${DEBOUNCE_WINDOW}s, heartbeat floor: ${HEARTBEAT_INTERVAL}s"
log "Mode: file-watcher (immediate, retried until accepted) + duty-capped backstop heartbeat (slot duty <= $(clamp_duty_pct "$HEARTBEAT_MAX_SLOT_DUTY_PCT")% [configured '${HEARTBEAT_MAX_SLOT_DUTY_PCT}'], file-change reloads <= $(clamp_duty_pct "$FILE_MAX_SLOT_DUTY_PCT")% [configured '${FILE_MAX_SLOT_DUTY_PCT}'])"
log "$(startup_stats_line)"
log "Restart gap: ${startup_gap_verdict} — ${startup_gap_note}"
if [ "$pending_reload" = "true" ]; then
    log "A file-change reload is queued from startup; next heartbeat not before epoch ${hb_next_allowed}"
else
    log "Next heartbeat not before epoch ${hb_next_allowed} (+$(( hb_next_allowed - now ))s)"
fi

while true; do
    sleep "$POLL_INTERVAL"
    watcher_tick
done
