#!/bin/bash
# nightly-reboot-postcheck.sh — what the nightly reboot hands off to once the
# machine is back (ga-a2v0bz).
#
# nightly-reboot.sh (root LaunchDaemon) ends in `shutdown -r now`. Until now
# nothing told Athos whether the city came back whole: the Mayor ran a manual
# "is Dolt up, is the sender up, is the map up" checklist after each reboot.
# This is that checklist as a script, so a reboot that went wrong is a push
# notification at 23:45, not a surprise at 07:00.
#
# TRIGGER: a user LaunchAgent (scripts/com.gascity.nightly-reboot-postcheck.plist,
# RunAtLoad, once per login). It fires on EVERY login, so the script acts only when
# nightly-reboot.sh left PENDING_FILE (issued=, boot_before=, mode=, and optionally
# scraper_cut_alarm= / scraper_cut_reason=) AND this boot is newer than boot_before.
# Every other fire is a silent no-op. The plist lives in
# scripts/, so daemon-presence-watchdog's PRESENCE-DRIFT sweep alerts if it is
# merged but never loaded — an unloaded postcheck must not look like a clean night.
#
# THE DRAIN NEEDS NO CLEARING HERE. The drain signal carries the boot-epoch it was
# written under, and every reader ignores one from another boot, so the reboot
# itself ends the drain. This script still CHECKS the signal is not live for this
# boot (it would mean the dispatchers are paused), but never removes it: a
# post-boot "clear the flag" step that can fail is exactly what that design avoids.
#
# CHECKS — three states each, never collapsed (ok / FAIL / unknown):
#   dolt    gc-dolt-probe.sh --robust: 0 healthy | 1 unreachable | 2 or anything else unknown
#   sender  launchd job com.whatsapp.central-sender has a PID
#   map     the map ORIGIN answers on loopback (http://127.0.0.1:8099/: 2xx/3xx ok, 5xx or
#           connection refused FAIL, else unknown) AND the cloudflared tunnel that carries it
#           is up (launchd PID + its own /ready reports >= 1 edge connection; 0 = FAIL; cannot
#           read = unknown). The worst of the two wins (FAIL > unknown > ok).
#           NOT the public URL: https://mapa.urblink.com.br/ sits behind Cloudflare Access, which
#           answers an unauthenticated request with a 302 to its login FROM THE EDGE, before any
#           origin fetch (measured 01/10: 302, server: cloudflare, www-authenticate: Cloudflare-
#           Access). That 302 is the same whether the map and the tunnel are up or both are dead,
#           so "mapa ok" built on it could never be anything but ok — the ruler of a check is
#           that it must be able to FAIL for the thing it names (gate FAIL 3/3).
#   drain   no drain signal live for THIS boot
# Services come up staggered after a boot, so the checks are retried as one round
# (every INTERVAL seconds, for up to MAX_WAIT seconds of wall-clock, 20min by default)
# and the verdict is the LAST round.
# "unknown" is not "ok": it is reported, and exits 1 like FAIL — read the label.
#
# REPORT: notify (primary, no Dolt dependency) always; a mail to the mayor
# (secondary, best-effort, needs Dolt) only when something is not ok. The failure
# notifications go out with route=push (NOTIFY_FORCE_PUSH): notify's default route is the
# silent digest and -p 4 does not change that. The routine OK is left on the digest.
#
# NOT CHECKED HERE (by design): the property_scrapers rodada the reboot cut. It is
# resumed by the scraper's own catch-up (--skip-done-today), owned by that rig. The reboot
# script counts the nights in a row it was cut and, from the 2nd, leaves the alarm for the
# mayor in the pending file; THIS script sends it (send_owed_scraper_alarm), because only
# here is it known that the cut happened: a mail sent before the shutdown would announce a
# cut that a failed shutdown never made, and nothing written after `shutdown -r now`
# returns can be counted on.
#
# MODES:
#   nightly-reboot-postcheck.sh          the LaunchAgent entry (acts only when pending)
#   nightly-reboot-postcheck.sh --now    run the four checks ONCE and print one line each;
#                                        no retry, no notify, no log, never touches the
#                                        pending file. Exit 0 only if all four are ok.
set -uo pipefail

NOW_ONLY=0
if [ "$#" -eq 1 ] && [ "$1" = "--now" ]; then
    NOW_ONLY=1
elif [ "$#" -ne 0 ]; then
    echo "usage: nightly-reboot-postcheck.sh [--now]" >&2
    exit 2
fi

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC_BIN:-/opt/homebrew/bin/gc}"
LOG="${NIGHTLY_REBOOT_LOG:-${CITY}/.gc/logs/nightly-reboot.log}"
PENDING_FILE="${NIGHTLY_REBOOT_PENDING_FILE:-${CITY}/.gc/logs/nightly-reboot.pending}"
DRAIN_FILE="${NIGHTLY_REBOOT_DRAIN_FILE:-/Users/athos/.gastown/run/city-drain.level}"
NOTIFY_BIN="${NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
SYSCTL_BIN="${SYSCTL_BIN:-/usr/sbin/sysctl}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-/bin/launchctl}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
LSOF_BIN="${LSOF_BIN:-/usr/sbin/lsof}"
DOLT_PROBE="${NIGHTLY_REBOOT_POSTCHECK_DOLT_PROBE:-${CITY}/scripts/gc-dolt-probe.sh}"
SENDER_LABEL="${NIGHTLY_REBOOT_POSTCHECK_SENDER_LABEL:-com.whatsapp.central-sender}"
# The map's ORIGIN (com.whatsapp.map-viewer -> map_viewer_dashboard.py; cloudflared maps
# mapa.urblink.com.br to it, ~/.cloudflared/urblink-ops.yml) and the launchd job of the
# tunnel in front of it. Loopback ONLY: a connection refused there is a definite "nothing is
# listening", which is what lets the probe call it FAIL instead of "cannot tell".
MAP_ORIGIN_URL="${NIGHTLY_REBOOT_POSTCHECK_MAP_ORIGIN_URL:-http://127.0.0.1:8099/}"
TUNNEL_LABEL="${NIGHTLY_REBOOT_POSTCHECK_TUNNEL_LABEL:-br.urblink.cloudflared.urblink-ops}"
VM_DIR="${NIGHTLY_REBOOT_POSTCHECK_VM_DIR:-/System/Volumes/VM}"
INTERVAL="${NIGHTLY_REBOOT_POSTCHECK_INTERVAL:-30}"
# The retry budget is WALL-CLOCK, not a count of rounds: a failing round is not instant
# (the Dolt probe alone can take ~50s, the map call up to 15s), so 40 rounds x 30s would
# stretch to about an hour before a "COM PROBLEMA" push. MAX_ATTEMPTS is only a ceiling.
MAX_WAIT="${NIGHTLY_REBOOT_POSTCHECK_MAX_WAIT_SECS:-1200}"
MAX_ATTEMPTS="${NIGHTLY_REBOOT_POSTCHECK_MAX_ATTEMPTS:-40}"
MAX_PENDING_AGE="${NIGHTLY_REBOOT_POSTCHECK_MAX_PENDING_AGE:-10800}" # 3h: a macOS install can make the boot slow
LOCK_DIR="${PENDING_FILE}.lock.d"
MAIL_TIMEOUT="${NIGHTLY_REBOOT_POSTCHECK_MAIL_TIMEOUT_SECS:-30}"
case "${MAIL_TIMEOUT}" in ''|*[!0-9]*|0) MAIL_TIMEOUT=30 ;; esac

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] postcheck: $*" >> "${LOG}" 2>/dev/null; }

# boot_epoch: kern.boottime's `sec` by EXACT TOKEN. `sysctl -n kern.boottime` prints
# `{ sec = 1789579812, usec = 958892 } Wed Sep 16 ...`; a greedy `.*sec = ([0-9]+)`
# matches the "sec" inside "usec" and returns the microseconds (ga-ljncyt, ga-rc7tz).
boot_epoch() {
    "${SYSCTL_BIN}" -n kern.boottime 2>/dev/null \
      | awk '{for (i = 1; i <= NF; i++) if ($i == "sec") { v = $(i+2); gsub(/[^0-9]/, "", v); print v; exit } }'
}

# --- the four checks -------------------------------------------------------
# Each sets CHECK_STATE (ok|FAIL|unknown) and CHECK_DETAIL. A check that cannot look
# is "unknown", never "ok".
check_dolt() {
    CHECK_STATE="unknown"; CHECK_DETAIL=""
    local out rc
    if [ ! -r "${DOLT_PROBE}" ]; then
        CHECK_DETAIL="probe ${DOLT_PROBE} not readable — cannot tell"
        return 1
    fi
    # --robust, NOT the bare probe: right after a boot the box is saturated (measured
    # 01/10 at load 37: `gc dolt health` takes ~9s and the bare probe's 12s budget
    # timed out, reporting a LIVE Dolt as "unhealthy"). --robust retries and, if every
    # health call fails, asks Dolt directly (SELECT 1): served = alive, refused = down,
    # no client = unknown. Keep the flag — the bare form turns "slow" into a false FAIL.
    # A SUBPROCESS, never `source`: that file also defines a kill -QUIT goroutine dump
    # that must never be loaded here (SIGQUIT terminates a live Dolt).
    out=$(bash "${DOLT_PROBE}" --robust 2>/dev/null); rc=$?
    case "${rc}" in
        0) CHECK_STATE="ok"; CHECK_DETAIL="${out:-healthy}"; return 0 ;;
        1) CHECK_STATE="FAIL"; CHECK_DETAIL="Dolt ${out:-unhealthy}" ;;
        *) CHECK_DETAIL="probe rc=${rc} (${out:-no output}) — cannot tell" ;;
    esac
    return 1
}

# launchd_job_check <label>: is the launchd job loaded AND running? ok = has a PID; FAIL = not
# loaded, or loaded with no PID; unknown = launchctl itself gave an answer we cannot read.
# Sets CHECK_STATE / CHECK_DETAIL and JOB_PID (empty unless ok). Shared by the sender and the
# map's tunnel so both read the three states the same way.
launchd_job_check() {
    local label="$1" out rc pid
    CHECK_STATE="unknown"; CHECK_DETAIL=""; JOB_PID=""
    out=$("${LAUNCHCTL_BIN}" list "${label}" 2>&1); rc=$?
    if [ "${rc}" -ne 0 ]; then
        case "${out}" in
            *"Could not find service"*) CHECK_STATE="FAIL"; CHECK_DETAIL="${label} is not loaded in launchd" ;;
            *) CHECK_DETAIL="launchctl list rc=${rc}: $(printf '%s' "${out}" | tr '\n' ' ') — cannot tell" ;;
        esac
        return 1
    fi
    case "${out}" in
        *'"Label"'*) ;;
        *) CHECK_DETAIL="launchctl list ${label} exited 0 but printed no job dictionary ('$(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-80)') — cannot tell"
           return 1 ;;
    esac
    pid=$(printf '%s\n' "${out}" | sed -n 's/.*"PID" = \([0-9][0-9]*\);.*/\1/p' | head -1)
    if [ -n "${pid}" ]; then
        CHECK_STATE="ok"; CHECK_DETAIL="${label} running (pid ${pid})"; JOB_PID="${pid}"
        return 0
    fi
    CHECK_STATE="FAIL"
    CHECK_DETAIL="${label} is loaded but has no PID ($(printf '%s\n' "${out}" | sed -n 's/.*"LastExitStatus" = \([-0-9]*\);.*/last exit \1/p' | head -1))"
    return 1
}

check_sender() {
    launchd_job_check "${SENDER_LABEL}"
}

# map, half 1: the ORIGIN, asked directly on loopback. There is no edge in front of it, so
# the status code is the app's own answer.
#   2xx/3xx  the app served            -> ok
#   5xx      the app is up but broken  -> FAIL
#   curl rc 7 (could not connect)      -> FAIL: on loopback that is "nothing is listening"
#   anything else (timeout on a saturated box, 4xx, garbage, no curl output) -> unknown
map_origin_probe() {
    CHECK_STATE="unknown"; CHECK_DETAIL=""
    local code rc
    code=$("${CURL_BIN}" -sS -o /dev/null -w '%{http_code}' --max-time 15 "${MAP_ORIGIN_URL}" 2>/dev/null); rc=$?
    case "${code}" in
        [23][0-9][0-9]) CHECK_STATE="ok"; CHECK_DETAIL="${MAP_ORIGIN_URL} answers HTTP ${code}"; return 0 ;;
        5[0-9][0-9]) CHECK_STATE="FAIL"; CHECK_DETAIL="${MAP_ORIGIN_URL} answers HTTP ${code}"; return 1 ;;
    esac
    if [ "${rc}" -eq 7 ]; then
        CHECK_STATE="FAIL"; CHECK_DETAIL="${MAP_ORIGIN_URL}: connection refused — nothing is listening"
    else
        CHECK_DETAIL="${MAP_ORIGIN_URL}: no clear answer (curl rc=${rc}, HTTP '${code}') — cannot tell if the map is down or this host cannot reach it"
    fi
    return 1
}

# map, half 2: the cloudflared TUNNEL in front of it. A running process is not a connected
# tunnel (right after a boot the network may not be up yet), so once the launchd job has a PID
# we ask cloudflared itself: its metrics listener serves /ready = {"readyConnections":N}, 200
# when N >= 1 and 503 when 0. The listener port is NOT hardcoded (the config pins no `metrics:`,
# so cloudflared takes the first free port from 20241 up): it is read off the live PID, the
# same "derive it from the process" rule the city applies to Dolt.
#   no PID / not loaded                 -> FAIL (launchd_job_check)
#   /ready says readyConnections >= 1   -> ok
#   /ready says readyConnections 0      -> FAIL (alive, but not connected to the edge)
#   no listener / no /ready answer / unreadable JSON / no lsof -> unknown, NEVER ok: a PID alone
#   does not prove the tunnel carries traffic, and "could not look" must not read as "looked".
map_tunnel_probe() {
    local job_detail pid ports port body conns
    launchd_job_check "${TUNNEL_LABEL}" || return 1
    job_detail="${CHECK_DETAIL}"; pid="${JOB_PID}"
    CHECK_STATE="unknown"
    ports=$("${LSOF_BIN}" -nP -a -p "${pid}" -iTCP -sTCP:LISTEN -Fn 2>/dev/null | sed -n 's/^n.*:\([0-9][0-9]*\)$/\1/p')
    for port in ${ports}; do
        body=$("${CURL_BIN}" -sS --max-time 5 "http://127.0.0.1:${port}/ready" 2>/dev/null)
        conns=$(printf '%s' "${body}" | sed -n 's/.*"readyConnections":\([0-9][0-9]*\).*/\1/p')
        [ -n "${conns}" ] || continue   # not the /ready JSON (another listener of the same pid): try the next
        if [ "${conns}" -ge 1 ]; then
            CHECK_STATE="ok"; CHECK_DETAIL="${job_detail}; ${conns} edge connection(s) ready (127.0.0.1:${port}/ready)"
            return 0
        fi
        CHECK_STATE="FAIL"; CHECK_DETAIL="${job_detail}, but 0 edge connections ready (127.0.0.1:${port}/ready) — the tunnel is not connected"
        return 1
    done
    CHECK_DETAIL="${job_detail}, but its /ready did not answer (pid ${pid} listening on: ${ports:-nothing found}) — cannot tell whether the tunnel is connected to the edge"
    return 1
}

# map = origin AND tunnel; the WORST of the two wins (FAIL > unknown > ok), and only both-ok is
# ok. The detail always names both halves, so a FAIL that is "the tunnel" is not read as "the map".
check_map() {
    local o_state o_detail t_state t_detail
    map_origin_probe || true; o_state="${CHECK_STATE}"; o_detail="${CHECK_DETAIL}"
    map_tunnel_probe || true; t_state="${CHECK_STATE}"; t_detail="${CHECK_DETAIL}"
    if [ "${o_state}" = "FAIL" ] || [ "${t_state}" = "FAIL" ]; then
        CHECK_STATE="FAIL"
    elif [ "${o_state}" = "ok" ] && [ "${t_state}" = "ok" ]; then
        CHECK_STATE="ok"
    else
        CHECK_STATE="unknown"
    fi
    CHECK_DETAIL="origin ${o_state} (${o_detail}); tunnel ${t_state} (${t_detail})"
    [ "${CHECK_STATE}" = "ok" ]
}

# The drain signal is DRAIN | written | boot | until. Live for this boot = the
# dispatchers are paused; from an older boot = every reader already ignores it.
# (SC2034: CHECK_DETAIL is read by run_round through eval, which shellcheck cannot see.)
# shellcheck disable=SC2034
check_drain() {
    CHECK_STATE="unknown"; CHECK_DETAIL=""
    local sig_boot
    if [ ! -e "${DRAIN_FILE}" ]; then
        CHECK_STATE="ok"; CHECK_DETAIL="no drain signal"
        return 0
    fi
    sig_boot="$(sed -n '3p' "${DRAIN_FILE}" 2>/dev/null)"
    case "${sig_boot}" in
        ''|*[!0-9]*)
            CHECK_DETAIL="${DRAIN_FILE} exists but its boot field is unreadable ('${sig_boot}') — cannot tell if the dispatchers are paused"
            return 1 ;;
    esac
    # Without this boot's epoch, "from another boot" cannot be established: unknown,
    # not ok (--now reaches here without the entry path's BOOT_NOW validation).
    case "${BOOT_NOW:-}" in
        ''|*[!0-9]*)
            CHECK_DETAIL="${DRAIN_FILE} exists (boot ${sig_boot}) but kern.boottime is unreadable — cannot tell whether it is this boot's"
            return 1 ;;
    esac
    if [ "${sig_boot}" = "${BOOT_NOW}" ]; then
        CHECK_STATE="FAIL"; CHECK_DETAIL="drain signal is LIVE for this boot (${DRAIN_FILE}) — pilot/gate/refino are paused"
        return 1
    fi
    CHECK_STATE="ok"; CHECK_DETAIL="signal from boot ${sig_boot} left on disk; readers ignore it (this boot is ${BOOT_NOW})"
    return 0
}

# One round: all four checks, results in R_<name>_STATE / R_<name>_DETAIL. Returns 0 only if all ok.
run_round() {
    local all=0 name
    for name in dolt sender map drain; do
        "check_${name}" || true
        eval "R_${name}_STATE=\"\${CHECK_STATE}\"; R_${name}_DETAIL=\"\${CHECK_DETAIL}\""
        [ "${CHECK_STATE}" = "ok" ] || all=1
    done
    return "${all}"
}

print_round() {
    local name state detail
    for name in dolt sender map drain; do
        eval "state=\"\${R_${name}_STATE}\"; detail=\"\${R_${name}_DETAIL}\""
        printf '%s %s: %s\n' "${name}" "${state}" "${detail}"
    done
}

# print_round_problems: the same lines as print_round, only for the checks whose STATE is not ok.
# Selected by the state variable, NOT by filtering the rendered text with grep: a detail is free
# text (the Dolt probe's own output, the map's "tunnel ok (...)"), and a FAILing line that merely
# CONTAINS " ok: " would be filtered out as if it were ok and vanish from the alert.
print_round_problems() {
    local name state detail
    for name in dolt sender map drain; do
        eval "state=\"\${R_${name}_STATE}\"; detail=\"\${R_${name}_DETAIL}\""
        [ "${state}" = "ok" ] || printf '%s %s: %s\n' "${name}" "${state}" "${detail}"
    done
}

# --- --now: one pass, print, no side effects --------------------------------
if [ "${NOW_ONLY}" -eq 1 ]; then
    BOOT_NOW="$(boot_epoch)"
    run_round; rc=$?
    print_round
    exit "${rc}"
fi

# --- the LaunchAgent entry --------------------------------------------------
# Fast path: no pending file = not a boot the nightly reboot asked for.
[ -e "${PENDING_FILE}" ] || exit 0

# One instance at a time (the plist can be loaded and kicked at once). mkdir is
# atomic; a lock whose owner is dead is taken over, so a crash or a power loss
# mid-run cannot wedge the check forever. No `rm -rf` (see ga-gkap9p).
# The lock records the BOOT it was taken in beside the pid. Pids are reused after a reboot, so a
# lock left by a postcheck that was killed mid-run could name a pid that now belongs to some
# unrelated process: `kill -0` alone would call it live and every later login would log
# "another instance holds..." and exit without checking anything. A lock from another boot is
# dead, whatever its pid says. A lock without a boot (older format) or a boot we cannot read
# falls back to the pid test alone, as before.
take_lock() { echo "$$" > "${LOCK_DIR}/pid" 2>/dev/null; boot_epoch > "${LOCK_DIR}/boot" 2>/dev/null; return 0; }
acquire_lock() {
    local pid lock_boot now_boot
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        take_lock
        return 0
    fi
    pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null)"
    lock_boot="$(cat "${LOCK_DIR}/boot" 2>/dev/null)"
    now_boot="$(boot_epoch)"
    # each side on its own: a boot we can read on one side only proves nothing, and
    # "I could not read my own boot" must never read as "the lock is from another boot"
    case "${lock_boot}" in ''|*[!0-9]*) lock_boot="" ;; esac
    case "${now_boot}" in ''|*[!0-9]*) lock_boot="" ;; esac
    if [ -n "${lock_boot}" ] && [ "${lock_boot}" != "${now_boot}" ]; then
        log "stale lock ${LOCK_DIR}: taken in boot ${lock_boot}, this is boot ${now_boot} — pid ${pid:-?} may have been reused; taking it over"
    else
        case "${pid}" in ''|*[!0-9]*) ;; *) kill -0 "${pid}" 2>/dev/null && return 1 ;; esac
    fi
    rm -f "${LOCK_DIR}/pid" "${LOCK_DIR}/boot" 2>/dev/null; rmdir "${LOCK_DIR}" 2>/dev/null
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
        take_lock
        return 0
    fi
    return 1
}
release_lock() { rm -f "${LOCK_DIR}/pid" "${LOCK_DIR}/boot" 2>/dev/null; rmdir "${LOCK_DIR}" 2>/dev/null; return 0; }

if ! acquire_lock; then
    log "another postcheck instance holds ${LOCK_DIR} — leaving it to that one"
    exit 0
fi
trap release_lock EXIT

# Another instance may have finished (and removed the file) between the fast path and the lock.
[ -e "${PENDING_FILE}" ] || exit 0

pending_field() { sed -n "s/^$1=//p" "${PENDING_FILE}" 2>/dev/null | head -1; }
ISSUED="$(pending_field issued)"
BOOT_BEFORE="$(pending_field boot_before)"
MODE="$(pending_field mode)"
BOOT_NOW="$(boot_epoch)"

# notify_athos <title> <body> [priority] [route]. `notify` sends to the silent digest unless
# the message is on its allowlist or NOTIFY_FORCE_PUSH is set — -p 4 and the title do NOT force
# a push (measured with NOTIFY_ROUTE_TEST=1: every message below lands on the digest without
# it). route=push is for the two that mean "the city may not be up": without it the primary
# alert of this script is the one nobody sees, and the mail to the mayor needs the Dolt that
# may be the thing that did not come back. The routine "OK" stays on the digest.
notify_athos() {
    if [ "${4:-}" = "push" ]; then
        NOTIFY_FORCE_PUSH=1 "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
    else
        "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
    fi
}
# mail_mayor <subject> <body>: best-effort, but the OUTCOME is logged. `mail send` writes a
# bead, so it hangs when Dolt is wedged — and this mail goes out in exactly the branch where
# Dolt may be the thing that did not come back. Without a deadline the check would sit here
# with its lock held, never run again, and say nothing. The deadline is counted with $SECONDS
# and `kill -0` (builtins: no fork needed), not timeout(1), which macOS does not ship.
mail_mayor() {
    local out rc pid wd
    out="$(mktemp -t nightly-reboot-postcheck-mail)"
    "${GC}" --city "${CITY}" mail send mayor --from nightly-reboot-postcheck.sh -s "$1" -m "$2" >"${out}" 2>&1 &
    pid=$!
    (
        end=$(( SECONDS + MAIL_TIMEOUT ))
        while kill -0 "${pid}" 2>/dev/null; do
            if [ "${SECONDS}" -ge "${end}" ]; then
                : > "${out}.deadline"
                /usr/bin/pkill -TERM -P "${pid}" 2>/dev/null
                kill -TERM "${pid}" 2>/dev/null
                # TERM is a request: a process that ignores it would keep the `wait` below
                # (and the lock) for as long as it lives. A short grace, then KILL.
                grace=$(( SECONDS + 2 ))
                while kill -0 "${pid}" 2>/dev/null && [ "${SECONDS}" -lt "${grace}" ]; do sleep 1 2>/dev/null || :; done
                if kill -0 "${pid}" 2>/dev/null; then
                    /usr/bin/pkill -KILL -P "${pid}" 2>/dev/null
                    kill -KILL "${pid}" 2>/dev/null
                fi
                break
            fi
            sleep 1 2>/dev/null || :
        done
    ) >/dev/null 2>&1 &
    wd=$!
    wait "${pid}" 2>/dev/null; rc=$?
    kill "${wd}" 2>/dev/null; wait "${wd}" 2>/dev/null
    if [ -e "${out}.deadline" ]; then
        log "ERROR: mail to mayor TIMED OUT after ${MAIL_TIMEOUT}s — NOT sent (Dolt not answering?)"
    elif [ "${rc}" -eq 0 ]; then
        log "mail to mayor: sent"
    else
        log "ERROR: mail to mayor FAILED (rc=${rc}: $(head -c 300 "${out}" 2>/dev/null | tr '\n' ' '))"
    fi
    rm -f "${out}" "${out}.deadline"
    return 0
}
drop_pending() { rm -f "${PENDING_FILE}" 2>/dev/null; return 0; }

# The scraper-cut alarm nightly-reboot.sh decided on before the shutdown (the counter reached
# the alarm threshold) and left in the pending file. Absent = nothing is owed (the normal
# night). Present but not a number = the file is damaged: say so, never mail a guess. Called
# only past the point where this boot was attributed to the nightly, i.e. after the cut.
send_owed_scraper_alarm() {
    local n reason
    n="$(pending_field scraper_cut_alarm)"
    [ -n "${n}" ] || return 0
    case "${n}" in
        *[!0-9]*) log "ERROR: ${PENDING_FILE} carries scraper_cut_alarm='${n}' (not a number) — the scraper-cut alarm is NOT sent"; return 0 ;;
    esac
    reason="$(pending_field scraper_cut_reason)"
    log "ALARM: the scraper was cut ${n} nights in a row — mailing mayor (property_scrapers owner)"
    mail_mayor "nightly-reboot: scraper cortado ${n} noites seguidas (ga-a2v0bz)" \
      "$(printf 'O reboot noturno das 23:40 encontrou uma rodada do scraper em andamento %s noites seguidas e a cortou (o catch-up retoma no boot).\nUltima: %s\nSe a rodada leva horas a cada noite, o ps precisa saber: o corte vira rotina.\nLog: %s' "${n}" "${reason:-<sem motivo registrado>}" "${LOG}")"
}

# A pending file we cannot read is reported once and dropped: the nightly rewrites it
# every night, and leaving it would re-report on every login.
case "${ISSUED}" in ''|*[!0-9]*) ISSUED="" ;; esac
case "${BOOT_BEFORE}" in ''|*[!0-9]*) BOOT_BEFORE="" ;; esac
if [ -z "${ISSUED}" ] || [ -z "${BOOT_BEFORE}" ]; then
    log "ERROR: ${PENDING_FILE} is unreadable (issued='${ISSUED}' boot_before='${BOOT_BEFORE}') — cannot tell whether this boot is the nightly one; dropping it"
    notify_athos "Reboot noturno: pós-boot não conferido" "o arquivo de pendência estava ilegível — não sei se este boot foi o do reboot noturno. Confira a cidade à mão: nightly-reboot-postcheck.sh --now" 4 push
    drop_pending
    exit 1
fi

# kern.boottime unreadable: cannot tell if the reboot happened. Keep the file for a later fire.
case "${BOOT_NOW}" in
    ''|*[!0-9]*)
        log "ERROR: kern.boottime unreadable — cannot tell whether the reboot happened; leaving ${PENDING_FILE} for the next fire"
        exit 1 ;;
esac

# Same boot as when the nightly issued the shutdown: this fire is a login (or the plist
# being loaded) before the reboot happened. Not ours yet — leave the file.
if [ "${BOOT_NOW}" -le "${BOOT_BEFORE}" ]; then
    log "same boot as when the reboot was issued (boot ${BOOT_NOW}) — the reboot has not happened (yet); leaving ${PENDING_FILE}"
    exit 0
fi

AGE=$(( $(date +%s) - ISSUED ))
if [ "${AGE}" -gt "${MAX_PENDING_AGE}" ]; then
    log "WARN: the pending reboot was issued ${AGE}s ago (> ${MAX_PENDING_AGE}s) — this boot is not attributed to the nightly reboot (the shutdown probably never happened and a later reboot got here); dropping it, no checks"
    drop_pending
    exit 0
fi

# --- ours: check, retrying the whole round while services come up ------------
log "boot ${BOOT_NOW} is the nightly reboot's (mode=${MODE:-?}, issued ${AGE}s ago) — checking Dolt/sender/map/drain for up to ${MAX_WAIT}s (at most ${MAX_ATTEMPTS} rounds, ${INTERVAL}s apart)"
ATTEMPT=1
ROUND_OK=0
START_TS="$(date +%s)"
while true; do
    if run_round; then
        ROUND_OK=1
        break
    fi
    if [ "${ATTEMPT}" -ge "${MAX_ATTEMPTS}" ] || [ $(( $(date +%s) - START_TS )) -ge "${MAX_WAIT}" ]; then
        break
    fi
    log "round ${ATTEMPT}/${MAX_ATTEMPTS} not all ok ($(print_round_problems | tr '\n' ';')) — retrying in ${INTERVAL}s"
    sleep "${INTERVAL}"
    ATTEMPT=$((ATTEMPT+1))
done

UPTIME_MIN=$(( ( $(date +%s) - BOOT_NOW ) / 60 ))
# "0 swapfiles" is good news: an unreadable VM dir must not be able to say it.
if [ -d "${VM_DIR}" ] && [ -r "${VM_DIR}" ]; then
    SWAPFILES=0
    for f in "${VM_DIR}"/swapfile*; do [ -e "${f}" ] && SWAPFILES=$((SWAPFILES+1)); done
else
    SWAPFILES="?"
fi
DISK_FREE="$(df -g / 2>/dev/null | awk 'NR==2 {print $4}')"
INFO="swap: ${SWAPFILES} arquivo(s); disco livre: ${DISK_FREE:-?} GB; uptime ${UPTIME_MIN}min"
while IFS= read -r line; do log "${line}"; done < <(print_round)
log "${INFO}"

if [ "${ROUND_OK}" -eq 1 ]; then
    log "RESULT: all four checks ok after ${ATTEMPT} round(s) — the city is back"
    notify_athos "Reboot noturno OK" "Cidade de pé após o reboot (${ATTEMPT} rodada(s) de conferência): Dolt ok, envio ok, mapa ok, dreno fora. ${INFO}." 3
    send_owed_scraper_alarm
    drop_pending
    exit 0
fi

PROBLEMS="$(print_round_problems | tr '\n' ';')"
log "RESULT: NOT all ok after ${ATTEMPT} round(s) — ${PROBLEMS}"
notify_athos "Reboot noturno: pós-boot COM PROBLEMA" "${PROBLEMS} (FAIL = caiu; unknown = não consegui olhar). ${INFO}. Rode: nightly-reboot-postcheck.sh --now" 4 push
mail_mayor "nightly-reboot: pós-boot com problema (ga-a2v0bz)" "$(printf 'O reboot noturno terminou mas a conferência pós-boot não fechou limpa depois de %s rodada(s):\n%s\n%s\nLog: %s' "${ATTEMPT}" "$(print_round)" "${INFO}" "${LOG}")"
send_owed_scraper_alarm
drop_pending
exit 1
