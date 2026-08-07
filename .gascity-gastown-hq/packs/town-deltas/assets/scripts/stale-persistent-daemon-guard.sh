#!/usr/bin/env bash
# stale-persistent-daemon-guard.sh (ga-fckwc)
#
# Detects KeepAlive=true (persistent) LaunchAgents under packs/town-deltas/
# assets/*.plist that are running code OLDER than the last commit to their
# own entrypoint file. Python (and any long-lived interpreter) does not
# hot-reload an already-imported module — a persistent daemon can keep
# running pre-fix code indefinitely after a merge, with ZERO error signal,
# until it is manually restarted (`launchctl kickstart -k`).
#
# Root incident: com.gascity.inflight-reclaim-guard ran pre-fix code for
# 3h44min after ga-114ll's fix merged to origin/main — its PID had been
# alive since 10 days before the fix existed. See ga-fckwc for the writeup.
#
# Scope decision (deliberate, matches whatsapp_automation's own validated
# choice in scripts/detect_stale_daemons.py): this compares each daemon's
# OWN entrypoint file only, not its full transitive import closure.
# Closure-mode over-flags on any additive edit to a shared lib (re-flags
# every importer even when it runs identically) and WA's own operational
# history is that closure-mode never earned a trusted standalone schedule —
# only single-file ("own") mode did. This trades a small amount of
# missed-detection (a fix that touches only a shared lib the daemon
# imports, not its own entrypoint) for a low, trustworthy false-positive
# rate. Ported from WA's prior art (session memory
# whatsapp-daemon-fix-merge-not-live-needs-restart / bead wa-8fzuk).
#
# Detection-only: this guard NEVER restarts a daemon itself (flapping risk;
# some of these daemons hold in-memory state a naive restart could disrupt
# — same caution as the global DEPLOY/RESTART HYGIENE doctrine). It pages
# via `notify` (unconditional, Dolt-independent) and, best-effort, comments
# on the bead whose commit made the daemon stale — only if a bead id can be
# extracted from the commit subject AND independently verified to resolve
# via `bd show`. Never trust an unverified regex match against bd (see
# session memory bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently —
# a guessed id that doesn't validate can silently land on an unrelated
# bead).
#
# Runs as a gc order (cooldown trigger, fresh exec every tick) — deliberately
# NOT a raw KeepAlive plist, so this guard can never itself become a member
# of the bug class it exists to detect.
set -euo pipefail

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
ASSETS_DIR="${STALE_DAEMON_ASSETS_DIR:-$CITY/packs/town-deltas/assets}"
STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
SEEN_FILE="${STALE_DAEMON_SEEN_FILE:-$STATE_DIR/stale-persistent-daemon-guard-seen.json}"
ESCALATE_AFTER_S="${STALE_DAEMON_ESCALATE_AFTER_S:-86400}"   # 24h re-fire, WA's proven cadence
PS_BIN="${PS_BIN:-ps}"
GIT_BIN="${GIT_BIN:-git}"
BD_BIN="${BD_BIN:-bd}"
NOTIFY_BIN="${NOTIFY_BIN:-notify}"
NOW=$(date +%s)

mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE" 2>/dev/null || true
SEEN_JSON=$(cat "$SEEN_FILE" 2>/dev/null || echo '{}')
[ -n "$SEEN_JSON" ] || SEEN_JSON='{}'

# `ps -eo etime=` -> seconds. Deliberately NOT `ps -o lstart=` + `date -j -f`:
# lstart's format is locale-dependent (breaks under non-C locales); etime is
# a plain, portable elapsed-time field. (Corrects an earlier session memory
# that assumed lstart — verified against WA's actual working implementation,
# which grepped clean for zero `lstart` hits.)
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
    # 10# prefix: etime fields are commonly zero-padded ("08", "09"), which
    # bash would otherwise misparse as invalid octal literals.
    d=$((10#${d:-0})); h=$((10#${h:-0})); m=$((10#${m:-0})); s=$((10#${s:-0}))
    echo $(( d*86400 + h*3600 + m*60 + s ))
}

# PID + elapsed-seconds of the process whose command line contains $1 (the
# entrypoint's absolute path). Ties broken toward the OLDEST (largest
# elapsed) match — a stray manual duplicate invocation is typically newer
# and shorter-lived than the launchd-managed instance.
find_process() {
    local needle="$1" best_pid="" best_secs=-1 pid etime secs
    while read -r pid etime; do
        [ -z "$pid" ] && continue
        secs=$(etime_to_secs "$etime") || continue
        if [ "$secs" -gt "$best_secs" ]; then
            best_secs=$secs
            best_pid=$pid
        fi
    done < <("$PS_BIN" -eo pid=,etime=,command= 2>/dev/null | awk -v needle="$needle" '
        { cmd=""; for (i=3; i<=NF; i++) cmd = cmd (i>3?" ":"") $i;
          if (index(cmd, needle) > 0) print $1, $2 }')
    [ -n "$best_pid" ] || return 1
    printf '%s %s\n' "$best_pid" "$best_secs"
}

# Fire `notify` for $key at most once per ESCALATE_AFTER_S window (mirrors
# WA's {key: last_notified_epoch} escalation ledger — a plain seen-set would
# either never re-fire on a fix that's STILL not live days later, or spam on
# every tick; this re-fires on a bounded cadence instead).
notify_once() {
    local key="$1" title="$2" body="$3" last
    last=$(printf '%s' "$SEEN_JSON" | jq -r --arg k "$key" '.[$k] // 0' 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$last" != "0" ] && [ $(( NOW - last )) -lt "$ESCALATE_AFTER_S" ]; then
        return 0
    fi
    "$NOTIFY_BIN" -t "$title" -p 3 "$body" >/dev/null 2>&1 || true
    SEEN_JSON=$(printf '%s' "$SEEN_JSON" | jq --arg k "$key" --argjson n "$NOW" '.[$k] = $n' 2>/dev/null) || true
    [ -n "$SEEN_JSON" ] || SEEN_JSON='{}'
}

# Conservative extraction from a conventional-commit-style subject, e.g.
# "fix(ga-114ll): ..." -> ga-114ll (this repo's own convention — see git
# log). The caller MUST independently verify via `bd show` before trusting
# this: a syntactic match alone is not proof the id is real.
#
# NOTE: grep exits 1 on no-match (the ordinary case for a commit subject with
# no recognizable bead id) and, under `set -o pipefail`, that non-zero exit
# propagates through `| head -1 | tr -d '()'` even though the pipeline's
# actual OUTPUT is perfectly valid (empty). The trailing `|| true` absorbs
# that so "no match" surfaces as an empty string to the caller instead of
# silently killing the whole script at the call site under `set -e` — found
# by this script's own selftest, not by inspection.
bead_id_from_subject() {
    printf '%s' "$1" | grep -oE '\([a-z]{2,8}-[a-z0-9]{2,8}\)' | head -1 | tr -d '()' || true
}

checked=0
stale=0
for plist in "$ASSETS_DIR"/*.plist; do
    [ -f "$plist" ] || continue
    json=$(plutil -convert json -o - "$plist" 2>/dev/null) || continue

    # Persistent iff launchd is told to KeepAlive (bare true, or a dict form
    # — either means "restart me if I exit", i.e. NOT a fresh process each
    # tick). A StartInterval-only entry with no KeepAlive gets a brand new
    # interpreter every firing and always reads current disk content — that
    # class is immune to this bug by construction and is correctly skipped.
    keepalive=$(printf '%s' "$json" | jq -r 'if (.KeepAlive == true) or ((.KeepAlive|type) == "object") then "yes" else "no" end' 2>/dev/null) || continue
    [ "$keepalive" = "yes" ] || continue

    label=$(printf '%s' "$json" | jq -r '.Label // empty' 2>/dev/null) || continue
    [ -n "$label" ] || continue

    entry=$(printf '%s' "$json" | jq -r '.ProgramArguments[]? | select(test("\\.(py|sh)$"))' 2>/dev/null | head -1) || continue
    [ -n "$entry" ] || continue

    checked=$((checked+1))

    proc=$(find_process "$entry") || continue   # not currently running — nothing to compare
    pid=$(printf '%s' "$proc" | awk '{print $1}') || continue
    proc_age_secs=$(printf '%s' "$proc" | awk '{print $2}') || continue
    start_epoch=$(( NOW - proc_age_secs ))

    commit_info=$("$GIT_BIN" -C "$CITY" log -1 --format='%ct%x09%s' origin/main -- "$entry" 2>/dev/null) || continue
    [ -n "$commit_info" ] || continue
    commit_epoch="${commit_info%%$'\t'*}"
    commit_subject="${commit_info#*$'\t'}"
    case "$commit_epoch" in ''|*[!0-9]*) continue ;; esac

    [ "$commit_epoch" -gt "$start_epoch" ] || continue

    stale=$((stale+1))
    stale_h=$(( (commit_epoch - start_epoch) / 3600 ))
    kickstart_hint="launchctl kickstart -k gui/\$(id -u)/$label"

    echo "[STALE-DAEMON] $label (PID $pid) running code from before its own last commit — ${stale_h}h behind. Entrypoint: $entry. Suggested: $kickstart_hint"

    notify_once "$label" "Daemon rodando código antigo" \
        "$label (PID $pid) está ${stale_h}h atrás do último commit em $(basename "$entry"). $kickstart_hint"

    bead_id=$(bead_id_from_subject "$commit_subject") || bead_id=""
    if [ -n "$bead_id" ] && "$BD_BIN" -C "$CITY" show "$bead_id" >/dev/null 2>&1; then
        "$BD_BIN" -C "$CITY" label add "$bead_id" "daemon-stale:detected" -q >/dev/null 2>&1 || true
        "$BD_BIN" -C "$CITY" comment "$bead_id" \
            "stale-persistent-daemon-guard (ga-fckwc): $label (PID $pid) ainda está rodando código de antes deste commit em $entry — ${stale_h}h de defasagem. Restart sugerido, NÃO executado automaticamente: $kickstart_hint" \
            >/dev/null 2>&1 || true
    fi
done

echo "$SEEN_JSON" > "$SEEN_FILE" 2>/dev/null || true

if [ "$stale" -gt 0 ]; then
    echo "stale-persistent-daemon-guard: $stale/$checked persistent daemon(s) running code older than their own last commit"
fi
