#!/usr/bin/env bash
# supervisor-formula-staleness-guard.sh (ga-4tt37)
#
# Detects the live `com.gascity.supervisor` process running continuously
# since BEFORE the last edit to a formula file targeted by a `type=formula`
# gc order (e.g. digest-generate -> mol-digest-generate). Orders of this
# type are materialized by the supervisor itself, not by a fresh CLI
# invocation each tick — so if the supervisor loaded/cached the formula's
# content once (at its own process start) and never refreshes it, every
# periodic pour for the rest of that process's life can silently produce
# step beads carrying PRE-EDIT instructions, with zero error signal.
#
# Root incident (ga-4tt37): mol-digest-generate's generate-and-send step was
# fixed TWICE (ga-8f40w, 2026-08-07; then ga-4tt37 itself, 2026-08-13) to
# archive digests as --type=message with a verify+self-correct block. Both
# fixes were correctly committed and merged. Despite that, the digest-
# generate order's actual materialized step bead for the very next day's run
# (2026-08-14) still contained the ORIGINAL, pre-ga-8f40w `--type=task` line
# verbatim -- proving the supervisor's in-memory copy of the formula
# predated BOTH fixes, not just the newest one. Confirmed via Dolt
# create-commit forensics (issue_type=task from the bead's own creation
# commit, not reverted later) cross-referenced against
# `com.gascity.supervisor`'s actual process start time and the existing
# supervisor-restart-watchdog.sh ledger (zero restarts recorded across the
# entire window the bad beads were produced in): every digest materialized
# before the supervisor's current run began was wrong; every one after was
# correct, with no code change in between -- an incidental crash-respawn
# (the class of event supervisor-restart-watchdog.sh already tracks) was
# what actually fixed it, not either merged commit.
#
# Same underlying bug class as [[merged-fix-inert-in-persistent-daemon-until-restart]]
# / stale-persistent-daemon-guard.sh, at a different layer: that guard
# watches leaf packs/town-deltas/assets/*.plist Python daemons against their
# OWN entrypoint file; this one watches the CORE engine process against the
# formula files it materializes on a schedule the leaf guard cannot see
# (com.gascity.supervisor is registered at ~/Library/LaunchAgents/, outside
# that guard's ASSETS_DIR glob by design).
#
# Detection-only: NEVER restarts the supervisor itself. Restarting the one
# process that manages every registered city's agent lifecycle is a much
# larger blast radius than restarting a single leaf daemon (global
# DEPLOY/RESTART HYGIENE doctrine's "ask per process" applies with extra
# weight here) -- this guard pages so a human/Mayor can decide when,
# deliberately, matching how supervisor-restart-watchdog.sh (ga-b0gltl) is
# ALSO explicitly detection-only for the same process.
#
# No bd label/comment on any specific bead: unlike a single daemon's own
# entrypoint fix (one commit, one bead, a clean regex off the commit
# subject), a stale-formula finding here has no single attributable bead --
# multiple orders, multiple formula edit commits, no 1:1 mapping. Guessing
# one would risk exactly the "unverified regex match against bd" trap this
# city already knows to avoid (bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently).
# `notify` alone (unconditional, Dolt-independent) carries the finding.
#
# Runs as a gc order (cooldown trigger, fresh exec every tick) -- deliberately
# NOT a raw KeepAlive plist, so this guard can never itself become a member
# of the bug class it detects.
set -euo pipefail

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${STALE_FORMULA_SEEN_FILE:-$STATE_DIR/supervisor-formula-staleness-guard-seen.json}"
ESCALATE_AFTER_S="${STALE_FORMULA_ESCALATE_AFTER_S:-86400}"   # 24h re-fire, matches sibling guard's proven cadence
SUPERVISOR_NEEDLE="${SUPERVISOR_NEEDLE:-supervisor run}"
PS_BIN="${PS_BIN:-ps}"
GIT_BIN="${GIT_BIN:-git}"
GC_BIN="${GC_BIN:-gc}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
NOW=$(date +%s)

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

# `ps -eo etime=` -> seconds. Portable across locales (unlike `lstart` +
# `date -j -f`) -- copied verbatim from stale-persistent-daemon-guard.sh,
# see that script's comment for the full rationale.
etime_to_secs() {
    local e="$1" d=0 h=0 m=0 s=0 rest
    case "$e" in
        *-*) d="${e%%-*}"; rest="${e#*-}" ;;
        *) rest="$e" ;;
    esac
    case "$rest" in
        *:*:*)
            h="${rest%%:*}"; rest="${rest#*:}"
            m="${rest%%:*}"; s="${rest#*:}"
            ;;
        *:*)
            m="${rest%%:*}"; s="${rest#*:}"
            ;;
        *)
            s="$rest"
            ;;
    esac
    d=$((10#${d:-0})); h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0}))
    echo $(( d*86400 + h*3600 + m*60 + s ))
}

# PID + elapsed-seconds of the process whose command line contains $1.
# Ties broken toward the OLDEST (largest elapsed) match. Adapted from
# stale-persistent-daemon-guard.sh's find_process, with one deliberate
# change: the `ps` snapshot is captured into a variable BEFORE piping to
# awk, not piped directly. Piping directly starts the awk subprocess
# concurrently with ps's own snapshot -- and awk's OWN command line (it
# receives the needle via `-v needle="$needle"`) then contains the needle
# as a literal substring, so `ps` can catch awk matching ITSELF the moment
# the real target ISN'T running (the one case this function most needs to
# get right: "not running" must return failure, not a bogus ~0s-old match).
# Freezing the snapshot first means awk doesn't exist yet when ps runs, so
# it can never appear in its own search space.
find_process() {
    local needle="$1" best_pid="" best_secs=-1 pid etime secs ps_snapshot
    ps_snapshot=$("$PS_BIN" -eo pid=,etime=,command= 2>/dev/null)
    while read -r pid etime; do
        [ -z "$pid" ] && continue
        secs=$(etime_to_secs "$etime") || continue
        if [ "$secs" -gt "$best_secs" ]; then
            best_secs=$secs
            best_pid=$pid
        fi
    done < <(printf '%s\n' "$ps_snapshot" | awk -v needle="$needle" '
        { cmd=""; for (i=3; i<=NF; i++) cmd = cmd (i>3?" ":"") $i;
          if (index(cmd, needle) > 0) print $1, $2 }')
    [ -n "$best_pid" ] || return 1
    printf '%s %s\n' "$best_pid" "$best_secs"
}

# Resolve a formula source path to its git-committed real file. Formula
# sources ($GC_BIN bd formula show) can be a symlink (e.g.
# .beads/formulas/<name>.formula.toml -> packs/town-deltas/formulas/<name>.toml)
# -- `git log -- <symlink-path>` would follow the wrong object, so resolve
# to the real path first. python3 (not BSD `readlink -f`, unavailable on
# macOS) matches this repo's own established portable-realpath idiom.
resolve_real_path() {
    "$PYTHON_BIN" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null
}

# Fire `notify` for $key at most once per ESCALATE_AFTER_S window. Copied
# verbatim from stale-persistent-daemon-guard.sh's notify_once (same
# {key: last_notified_epoch} escalation ledger, same bounded re-fire
# rationale — see that script's comment).
notify_once() {
    local key="$1" title="$2" body="$3" last
    last=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$last" != "0" ] && [ $(( NOW - last )) -lt "$ESCALATE_AFTER_S" ]; then
        return 1
    fi
    "$NOTIFY_BIN" -t "$title" -p 3 "$body" >/dev/null 2>&1 || true
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "$key" --argjson n "$NOW" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
    return 0
}

checked=0
stale=0
unresolved=0

proc=$(find_process "$SUPERVISOR_NEEDLE") || { echo "supervisor-formula-staleness-guard: com.gascity.supervisor not found running — skipping cycle."; exit 0; }
sup_pid=$(printf '%s' "$proc" | awk '{print $1}')
sup_age_secs=$(printf '%s' "$proc" | awk '{print $2}')
sup_start_epoch=$(( NOW - sup_age_secs ))

orders_json=$("$GC_BIN" order list --json 2>/dev/null) || { echo "supervisor-formula-staleness-guard: gc order list --json failed — skipping cycle."; exit 0; }
[ -n "$orders_json" ] || { echo "supervisor-formula-staleness-guard: gc order list --json returned nothing — skipping cycle."; exit 0; }

while IFS=$'\t' read -r order_name formula_name; do
    [ -n "$order_name" ] || continue
    [ -n "$formula_name" ] || continue
    checked=$((checked+1))

    # GATE FIX (blocking issue 2): every branch below that `continue`s without
    # reaching the stale/fresh verdict now increments `unresolved` first. This
    # is the SAME "don't know" bucket regardless of WHICH lookup step failed
    # (gc bd formula show erroring, a reshaped/missing .source field, a
    # broken symlink, or git log failing for a reason other than "never
    # committed") -- what matters for the third-state check below is only
    # that this order's staleness could NOT be determined, not why. A future
    # `gc` output-shape change that breaks every lookup at once must be
    # VISIBLE, not silently indistinguishable from "checked everything, all
    # fresh" (verified live: forcing every `gc bd formula show` call to fail
    # while `gc order list` still succeeds previously produced zero stdout,
    # zero notify, exit 0 -- identical to a genuinely healthy cycle).
    formula_json=$("$GC_BIN" bd formula show "$formula_name" --json 2>/dev/null) || { unresolved=$((unresolved+1)); continue; }
    [ -n "$formula_json" ] || { unresolved=$((unresolved+1)); continue; }
    src=$(printf '%s' "$formula_json" | jq -r '.source // empty' 2>/dev/null) || { unresolved=$((unresolved+1)); continue; }
    [ -n "$src" ] || { unresolved=$((unresolved+1)); continue; }
    real_src=$(resolve_real_path "$src") || { unresolved=$((unresolved+1)); continue; }
    [ -n "$real_src" ] || { unresolved=$((unresolved+1)); continue; }

    commit_epoch=$("$GIT_BIN" -C "$CITY" log -1 --format='%ct' origin/main -- "$real_src" 2>/dev/null) || { unresolved=$((unresolved+1)); continue; }
    case "$commit_epoch" in
        '')
            # Empty output: either never git-committed (a legitimate state --
            # e.g. a .gc/system materialized copy, no evidence either way) OR
            # `git log` itself failed silently. Can't tell which from here,
            # but either way this order's staleness is genuinely unknown, not
            # "confirmed fresh" -- count it so an ALL-unresolved cycle is
            # still visible even when every failure is this specific shape.
            unresolved=$((unresolved+1)); continue ;;
        *[!0-9]*) unresolved=$((unresolved+1)); continue ;;
    esac

    if [ "$commit_epoch" -le "$sup_start_epoch" ]; then
        continue   # positively confirmed fresh -- a real verdict, not a skip
    fi

    stale=$((stale+1))
    stale_h=$(( (commit_epoch - sup_start_epoch) / 3600 ))

    echo "[SUPERVISOR-FORMULA-STALE] order=$order_name formula=$formula_name — com.gascity.supervisor (PID $sup_pid) has been running since before the last edit to $real_src, ${stale_h}h behind. Periodic pours of this order under the CURRENT supervisor run may carry pre-edit step instructions. Coordinate a deliberate restart (do not auto-restart the core supervisor) — e.g. launchctl kickstart -k gui/\$(id -u)/com.gascity.supervisor."

    notify_once "supervisor-formula:$order_name" "Formula do supervisor está desatualizada" \
        "com.gascity.supervisor (PID $sup_pid) roda há ${stale_h}h a menos do que o último commit em $formula_name ($order_name) -- pours periódicos podem estar usando instrução pré-fix. Coordene um restart deliberado do supervisor (não é seguro automatizar)." \
        || true
done < <(printf '%s' "$orders_json" | jq -r '.orders[]? | select(.type=="formula") | "\(.name)\t\(.formula)"' 2>/dev/null)

# GATE FIX (blocking issue 2, continued): a summary line is now ALWAYS
# printed, not gated behind `stale > 0` -- silence must mean "confirmed
# healthy," never "confirmed healthy OR gave up on everything," and a log
# reader (or a future automated consumer of this guard's output) needs the
# unresolved count to tell those apart.
if [ "$checked" -gt 0 ] && [ "$unresolved" -eq "$checked" ]; then
    echo "supervisor-formula-staleness-guard: $unresolved/$checked formula order(s) could not be checked at all this cycle (every lookup failed) -- staleness UNKNOWN, not confirmed fresh."
    notify_once "supervisor-formula-guard-degraded" "Guard de staleness do supervisor não conseguiu checar nada" \
        "supervisor-formula-staleness-guard: $unresolved/$checked orders falharam em TODAS as tentativas de lookup nesse ciclo -- possivelmente gc order list/bd formula show mudou de formato. Staleness dos formulas ficou desconhecida, não confirmada como saudável." \
        || true
elif [ "$stale" -gt 0 ] || [ "$unresolved" -gt 0 ]; then
    echo "supervisor-formula-staleness-guard: checked=$checked stale=$stale unresolved=$unresolved"
fi

echo "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null || true
