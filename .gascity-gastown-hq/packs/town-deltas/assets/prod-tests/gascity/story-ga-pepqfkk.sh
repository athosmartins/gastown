#!/usr/bin/env bash
# prod-tests/gascity/story-ga-pepqfkk.sh — prod test for ga-pepqfkk:
# "Espelho do Hetzner (.gc/hetzner-mirror/repos/*.git): manutenção periódica — objetos soltos chegaram a 1,84 GB no WA e o auto-gc nunca rodou".
#
# What "done" means here is that the maintenance is ALIVE, not merely merged (two guards once merged without anyone loading their plist and delivered nothing):
#   1. the deployed hetzner-mirror.sh has the `maint` subcommand (an unknown rig is rc 2 "espelho desconhecido"; an unknown SUBCOMMAND would print the usage line instead);
#   2. the LaunchAgent com.gascity.hetzner-mirror-maint is LOADED (the deploy installs every plist under packs/town-deltas/assets/ — skill-integrity-install.sh,
#      scan_and_install_new_plists). A label a human parked with `launchctl disable` is a soft skip, named in the verdict, never a pass by default;
#   3. every mirror under .gc/hetzner-mirror/repos/ has the auto-gc pinned OFF (gc.auto=0, maintenance.auto=false, receive.autogc=false). The first tick of the job
#      writes the pin before anything else, so this proves the job really RAN on the live mirrors — polled for up to WAIT_S seconds because the kickstart is async;
#   4. any maintenance round already in the launchd log is held to the acceptance numbers: no round whose swap peak is above +1024 MB (FAIL), and the latest round of each
#      mirror ends under 5000 loose objects (WARN only: unreachable objects younger than 2 weeks legitimately stay loose). No round logged yet = soft skip: the two
#      back-to-back rounds the story asks for need the gates (load, disk) to open, which a deploy cannot force.
#
# Called by run.sh after deploy (STORY_ID=ga-pepqfkk). Exits 0 on pass. Overrides (tests): CITY, MH, LA_DIR, MAINT_LABEL, MAINT_LOG, PLIST_SRC, WAIT_S.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
MH="${MH:-$CITY/.gc/hetzner-mirror}"
LA_DIR="${LA_DIR:-$HOME/Library/LaunchAgents}"
MAINT_LABEL="${MAINT_LABEL:-com.gascity.hetzner-mirror-maint}"
MAINT_LOG="${MAINT_LOG:-$CITY/.gc/logs/hetzner-mirror-maint-launchd.out}"
WAIT_S="${WAIT_S:-180}"
SCRIPT="$CITY/scripts/hetzner-mirror.sh"
PLIST_SRC="${PLIST_SRC:-$CITY/packs/town-deltas/assets/hetzner-mirror-maint.plist}"

tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }   # sem `timeout` na máquina roda sem prazo (o script chamado sai rápido: só valida o nome do rig)
log()  { echo "[prod-test:gascity ga-pepqfkk] $*"; }
fail() { echo "[prod-test:gascity ga-pepqfkk] FAIL: $*" >&2; exit 1; }
SKIPPED=""

# ── 1. the deployed script has `maint` ───────────────────────────────────────
[[ -f "$SCRIPT" ]] || fail "deployed script missing: $SCRIPT"
grep -q '^cmd_maint()' "$SCRIPT" || fail "$SCRIPT has no cmd_maint: the deploy did not bring the maintenance"
# vazio (a saída não traz "desconhecido") → o subcomando não existe ou não chegou a validar o rig · falhou/prazo → FAIL (não sei dizer não é "tem")
OUT=$(HETZNER_MIRROR_HOME="$MH" tmo 60 /bin/bash "$SCRIPT" maint nao-existe-ga-pepqfkk 2>&1); RC=$?
if [[ "$RC" != 2 || "$OUT" != *"espelho desconhecido"* ]]; then
    fail "hetzner-mirror.sh maint <rig inexistente> should be rc 2 'espelho desconhecido' (got rc=$RC: ${OUT:0:200})"
fi
log "hetzner-mirror.sh maint: subcommand present (unknown rig -> rc 2) ✓"

# ── 2. the LaunchAgent is loaded ─────────────────────────────────────────────
[[ -f "$PLIST_SRC" ]] || fail "plist source missing: $PLIST_SRC"
PROG=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST_SRC" 2>/dev/null | tr -s ' \n' ' ')
[[ "$PROG" == *"$SCRIPT maint"* ]] || fail "plist ProgramArguments does not run '$SCRIPT maint' (got: $PROG)"
LOADED=0
if launchctl list "$MAINT_LABEL" >/dev/null 2>&1; then
    LOADED=1
    log "$MAINT_LABEL is loaded ✓"
else
    # vazio (label ausente do print-disabled) → não está desabilitado · falhou (rc≠0) → não sei: é FAIL, nunca "provavelmente só desabilitado"
    DIS=$(launchctl print-disabled "gui/$(id -u)" 2>&1) || fail "$MAINT_LABEL is not loaded and 'launchctl print-disabled' failed: cannot tell a parked job from a missing one"
    if grep -qE "\"$MAINT_LABEL\"[[:space:]]*=>[[:space:]]*(true|disabled)" <<<"$DIS"; then
        log "$MAINT_LABEL is launchctl-disabled (deliberate park) — soft skip, the job is NOT running"
        SKIPPED="$SKIPPED launchd-loaded(parked)"
    else
        fail "$MAINT_LABEL is NOT loaded: the plist merged but nothing runs the maintenance (installed copy: $LA_DIR/$MAINT_LABEL.plist)"
    fi
fi
if [[ -f "$LA_DIR/$MAINT_LABEL.plist" ]] && ! cmp -s "$PLIST_SRC" "$LA_DIR/$MAINT_LABEL.plist"; then
    log "WARNING: $LA_DIR/$MAINT_LABEL.plist differs from the repo plist (installed copy is stale?)"
    SKIPPED="$SKIPPED installed-plist-differs"
fi

# ── 3. every mirror has the auto-gc pinned off (proof the job RAN on the live mirrors) ─
shopt -s nullglob
REPOS=("$MH"/repos/*.git)
shopt -u nullglob
if [[ ${#REPOS[@]} -eq 0 ]]; then
    log "no mirror under $MH/repos (nothing to maintain here) — soft skip"
    SKIPPED="$SKIPPED mirrors-pinned"
elif [[ "$LOADED" != 1 ]]; then
    SKIPPED="$SKIPPED mirrors-pinned(job not loaded)"
else
    pinned() { # pinned <repo>: 0 only when all three keys read back with the exact value; a key that cannot be read is NOT pinned
        local r=$1 a b c
        a=$(git -C "$r" config --get gc.auto 2>/dev/null); b=$(git -C "$r" config --get maintenance.auto 2>/dev/null); c=$(git -C "$r" config --get receive.autogc 2>/dev/null)
        [[ "$a" == 0 && "$b" == false && "$c" == false ]]
    }
    deadline=$(( $(date +%s) + WAIT_S ))
    while :; do
        pending=""
        for r in "${REPOS[@]}"; do pinned "$r" || pending="$pending $(basename "$r")"; done
        [[ -z "$pending" ]] && break
        [[ "$(date +%s)" -lt "$deadline" ]] || fail "auto-gc not pinned off after ${WAIT_S}s in:$pending — the maintenance job did not run on the live mirrors (see $MAINT_LOG)"
        sleep 5
    done
    log "auto-gc pinned off (gc.auto=0, maintenance.auto=false, receive.autogc=false) in ${#REPOS[@]} mirror(s) ✓"
fi

# ── 4. rounds already logged vs the acceptance numbers ───────────────────────
if [[ -r "$MAINT_LOG" ]] && grep -q ' maint .*: DEPOIS ' "$MAINT_LOG"; then
    # a round with an unreadable peak ("+?") says swap=? — blind, not a violation, and not a pass either: it is counted below
    WORST=$(grep ' maint .*: DEPOIS ' "$MAINT_LOG" | sed -n 's/.*pico_swap=+\([0-9][0-9]*\) MB.*/\1/p' | sort -n | tail -1)
    BLIND=$(grep -c ' maint .*: DEPOIS .*pico_swap=+? MB' "$MAINT_LOG" || true)
    if [[ -n "$WORST" && "$WORST" -gt 1024 ]]; then
        fail "a maintenance round raised the swap by ${WORST} MB (> 1024) — acceptance says no round above 1 GB (see $MAINT_LOG)"
    fi
    if [[ -n "$WORST" ]]; then
        log "maintenance rounds in the log: worst swap peak +${WORST} MB (<= 1024) ✓$([[ "${BLIND:-0}" -gt 0 ]] && echo ", $BLIND round(s) with unreadable swap (blind, not verified)")"
    else
        log "maintenance rounds in the log carry no readable swap peak (${BLIND:-0} blind round(s)) — swap criterion NOT verified"
        SKIPPED="$SKIPPED swap-peak(unreadable)"
    fi
    for r in "${REPOS[@]}"; do
        n=$(basename "$r" .git)
        last=$(grep " maint $n: DEPOIS " "$MAINT_LOG" | tail -1 | sed -n 's/.*DEPOIS soltos=\([0-9?][0-9]*\).*/\1/p')
        if [[ -z "$last" ]]; then
            continue
        elif [[ "$last" == "?" ]]; then
            log "WARNING: $n: the latest round's loose count was unreadable"
        elif [[ "$last" -gt 5000 ]]; then
            log "WARNING: $n: latest round ended with $last loose objects (> 5000: unreachable objects younger than 2 weeks, or objects that arrived mid-round)"
        else
            log "$n: latest round ended with $last loose objects (< 5000) ✓"
        fi
    done
else
    log "no maintenance round logged yet in $MAINT_LOG — soft skip: the acceptance rounds need the gates (load, disk) to open"
    SKIPPED="$SKIPPED acceptance-rounds(none-yet)"
fi

log "PASS — hetzner-mirror.sh maint is deployed, scheduled and has reached the mirrors${SKIPPED:+ (NOT verified:$SKIPPED)}"
exit 0
