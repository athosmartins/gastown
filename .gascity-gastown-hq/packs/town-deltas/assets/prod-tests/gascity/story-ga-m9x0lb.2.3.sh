#!/usr/bin/env bash
# prod-tests/gascity/story-ga-m9x0lb.2.3.sh — prod test for ga-m9x0lb.2.3 (programa do teto dinâmico, fatia 2): the warnings the pool-ceiling engine
# must give BEFORE anyone turns it on (.on), read from the engine that is deployed.
#
# What "deployed and correct" means here:
#   (1) the engine is on disk in the LIVE tree and parses under the interpreter the launchd model names (/bin/bash);
#   (2) an ENABLED engine whose clock cannot be read says so: ONE notification over several sweeps (it used to leave an event=skip line every
#       5 minutes and nobody the wiser - an engine that does not sweep does not lower under pressure), and the notification names the reason;
#   (3) the lock heartbeat is re-stamped before a slow step when it is OURS (a sweep that outlives the lock's TTL is reaped even with a live PID),
#       and left exactly as it is when it is somebody else's or absent;
#   (4) the PLAN over a fragment whose parser died (awk killed, rc 137) names the reason (fragment-unreadable ... its parser died), not "levels-change".
# Everything runs in a scratch city (a throwaway git repo) with a fake notify and no gc: it never touches the real city's .gc, never turns the real
# engine on, calls no API and spends nothing.
#
# Called by run.sh after deploy (STORY_ID=ga-m9x0lb.2.3). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ENGINE="${POOL_CEILING_ENGINE_PATH:-$CITY/packs/town-deltas/assets/pool-ceiling-engine.sh}"
LIB="$(dirname "$ENGINE")/pool-ceiling.sh"
ENGBASH=/bin/bash

log()  { echo "[prod-test:gascity ga-m9x0lb.2.3] $*"; }
fail() { echo "[prod-test:gascity ga-m9x0lb.2.3] FAIL: $*" >&2; exit 1; }

# ── (1) on disk in the live tree, and it parses ──────────────────────────────
[[ -f "$ENGINE" && -f "$LIB" ]] || fail "the deployed engine ($ENGINE) or its lib ($LIB) is not on disk"
"$ENGBASH" -n "$ENGINE" || fail "the deployed engine does not parse under $ENGBASH"
grep -q '_pce_lock_renew' "$ENGINE" || fail "the deployed engine has no heartbeat renewal (_pce_lock_renew): this is not the ga-m9x0lb.2.3 version"

# the engine reads city.toml's include array with python3 + tomllib (>= 3.11); a host without one cannot run it meaningfully
PYTL=""; for p in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do "$p" -c 'import tomllib' >/dev/null 2>&1 && { PYTL="$p"; break; }; done
[[ -n "$PYTL" ]] || fail "no python3 >= 3.11 (tomllib) on this host: the engine cannot read city.toml's include array"

T="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-m9x0lb23.XXXXXX")" || fail "no scratch dir"
trap 'rm -rf "$T"' EXIT

# ── the scratch city: wa-worker 2, ps-worker 1, gate-reviewer 3 (committed), the include present, the fragment empty, the engine ON (in the scratch only)
C="$T/city"; mkdir -p "$C/.gc" "$C/agents/wa-worker" "$C/agents/ps-worker" "$C/agents/gate-reviewer" "$T/bin" "$T/noclock" "$T/awkx"
printf 'min_active_sessions = 0\nmax_active_sessions = 2\n' > "$C/agents/wa-worker/agent.toml"
printf 'min_active_sessions = 0\nmax_active_sessions = 1\n' > "$C/agents/ps-worker/agent.toml"
printf 'max_active_sessions = 3 # gate\nmin_active_sessions = 0\n' > "$C/agents/gate-reviewer/agent.toml"
printf 'include = [".gc/pool-ceiling-engine.toml"]\n\n[workspace]\nname = "prod-test"\n' > "$C/city.toml"
printf '# empty\n' > "$C/.gc/pool-ceiling-engine.toml"; : > "$C/.gc/pool-ceiling-engine.on"; printf '.gc/\n' > "$C/.gitignore"
( cd "$C" && git init -q . && git add city.toml agents .gitignore && git -c user.email=t@t -c user.name=t commit -q -m base ) >/dev/null 2>&1 || fail "could not make the scratch city"
printf '#!/bin/sh\necho "$*" >> "%s/notify.log"\n' "$T" > "$T/bin/notify"; chmod +x "$T/bin/notify"; : > "$T/notify.log"
printf '#!/bin/sh\nexit 1\n' > "$T/noclock/date"; chmod +x "$T/noclock/date"                                                   # not even the epoch can be read
printf '#!/bin/sh\ncase "$*" in *"function fin()"*) exit 137 ;; esac\nexec /usr/bin/awk "$@"\n' > "$T/awkx/awk"; chmod +x "$T/awkx/awk"   # the fragment parser's awk, killed

# eng <cmd> <now> [VAR=val ...] — one engine run against the scratch city (swap 4000 MB / disk 7000 MB: the hysteresis band)
eng() {
  local cmd="$1" now="$2"; shift 2
  env POOL_CEILING_ENGINE_CITY="$C" POOL_CEILING_ENGINE_NOW="$now" POOL_CEILING_T_SWAP_USED_MB=4000 POOL_CEILING_T_DISK_FREE_MB=7000 \
      POOL_CEILING_ENGINE_GC="$T/no-such-gc" POOL_CEILING_ENGINE_NOTIFY="$T/bin/notify" POOL_CEILING_ENGINE_PILOT_PLIST="$T/no-such.plist" \
      POOL_CEILING_ENGINE_PYTHON="$PYTL" POOL_CEILING_ENGINE_LIB="$LIB" GC_VARIABLE_SESSION_MAX=9 "$@" "$ENGBASH" "$ENGINE" "$cmd" 2>&1
}

# ── (2) an enabled engine that cannot read its clock tells somebody, once
for _ in 1 2 3; do eng run "" "PATH=$T/noclock:$PATH" >/dev/null; done
n="$(grep -c 'sweeps are NOT running (clock-unreadable' "$T/notify.log" | tr -d ' ')"
[[ "$n" = "1" ]] || fail "an ENABLED engine with an unreadable clock must notify exactly once over 3 sweeps; it notified $n time(s): $(tr '\n' '|' < "$T/notify.log")"
log "clock unreadable, 3 sweeps: one notification"

# ── (3) the lock heartbeat: re-stamped when it is ours, untouched when it is not
probe() { # <ours|foreign|none> <bounded|notify> -> renewed / old / absent
  (
    export POOL_CEILING_ENGINE_CITY="$C" POOL_CEILING_ENGINE_LIB="$LIB" POOL_CEILING_ENGINE_NOTIFY="$T/bin/notify"
    # shellcheck disable=SC1090
    . "$ENGINE"; pce_init
    rm -f "$PCE_LOCK_HB" 2>/dev/null; mkdir -p "$PCE_LOCK_DIR"; want=""
    case "$1" in ours) want="$PCE_LOCK_TOKEN" ;; foreign) want="99999:other" ;; esac
    [[ -z "$want" ]] || { printf '%s\n' "$want" > "$PCE_LOCK_HB"; touch -t 202001010000 "$PCE_LOCK_HB"; }
    case "$2" in bounded) _pce_bounded 5 true ;; notify) pce_notify "heartbeat probe" ;; esac
    [[ -e "$PCE_LOCK_HB" ]] || { echo absent; exit 0; }
    age=$(( $(date +%s) - $(stat -f %m "$PCE_LOCK_HB") ))
    if [[ "$(head -n1 "$PCE_LOCK_HB")" != "$want" ]]; then echo CONTENT-CHANGED; elif [[ "$age" -lt 120 ]]; then echo renewed; else echo old; fi
  )
}
for step in bounded notify; do
  [[ "$(probe ours "$step")" = "renewed" ]]   || fail "OUR heartbeat, aged past the TTL, must be re-stamped before a $step step (got: $(probe ours "$step"))"
  [[ "$(probe foreign "$step")" = "old" ]]    || fail "a heartbeat that is another holder's must be left alone before a $step step (got: $(probe foreign "$step"))"
  [[ "$(probe none "$step")" = "absent" ]]    || fail "no heartbeat must stay no heartbeat before a $step step (got: $(probe none "$step"))"
done
log "heartbeat renewed only when ours"

# ── (4) the plan names a dead parser
out="$(eng plan 1790000000 "PATH=$T/awkx:$PATH")"
case "$out" in
  *"why=fragment-unreadable(its parser died, rc=137"*) ;;
  *) fail "the plan over a fragment whose parser died (rc 137) must name it; got: $(printf '%s' "$out" | tr '\n' '|' | cut -c1-400)" ;;
esac
log "plan names a parser that died"

log "PASS"
exit 0
