#!/bin/bash
# claude-credential-preflight — ga-tkd2ll pre_start preflight.
#
# Verifies the Claude Code credential a freshly-spawned session will use is
# actually usable BEFORE the session starts, instead of discovering "sessao
# nasceu sem token" or "logada na conta errada" only after a human notices a
# dead/misrouted session and kills it by hand (the reported ga-tkd2ll
# incident: post-reboot, several sessions spawned this way and Athos had to
# intervene manually).
#
# CONTRACT — mirrors dog-pool-preflight-reclaim.py's pre_start contract
# (bounded wall-clock budget, catch-all fail-safe on anything the check
# itself can't determine). UNLIKE that script, this one CAN legitimately
# block a spawn (nonzero exit) — a pre_start nonzero exit is FATAL to that
# one start attempt by engine design (see internal/runtime/tmux/adapter.go
# runPreStart: "Failures are fatal because launching into an unprepared ...
# state" can point agents at the wrong repo or skip required bootstrap
# state — an unusable credential is exactly that class of problem). But
# blocking is gated behind an explicit, prove-then-arm flag
# (CLAUDE_CRED_PREFLIGHT_ENFORCE=1), mirroring the same staged-rollout
# precedent this bead's own history already established for the sibling
# claude-account-relog.sh / CLAUDE_RELOG_ENABLED: ship detection + alerting
# live first (shadow mode, can never block), only arm enforcement after
# observing real output across at least one reboot cycle. This mechanism
# applies city-wide (every agent template that spawns a real `claude`
# process) — a bug that produces a false BAD verdict while enforcement is
# armed would freeze spawns broadly, which is a worse failure than the one
# this script fixes. Shadow-mode-first is the guard against that.
#
# STATES — never collapsed into each other (ga-tkd2ll ACs + the citywide
# "erro e vazio nao podem produzir o mesmo valor" doctrine):
#   GOOD    loggedIn=true, email is a known pool account. Silent, exit 0.
#   BAD     loggedIn=false (no usable credential at all) — the literal
#           reported symptom. Loud alert ALWAYS (shadow or enforce). Blocks
#           the spawn only when CLAUDE_CRED_PREFLIGHT_ENFORCE=1.
#   WARN    loggedIn=true but email is NOT a recognized pool account. Loud
#           alert always (a human should confirm/allowlist it) but NEVER
#           blocks, even when enforced — the known-account list can go
#           stale, and a false block here is worse than a missed alert.
#   UNKNOWN the check itself could not complete (claude/jq missing, timeout,
#           unparseable output). Never blocks, never mails (too noisy for a
#           possibly-transient boot-time blip) — log only, same posture as
#           the sibling dog-pool-preflight-reclaim.py's own catch-all.
#
# KNOWN LIMITATION (documented, not silently swept under): this only
# classifies a CLEAN "loggedIn: false" JSON response as BAD. A hard
# crash / nonzero-exit failure mode of `claude auth status` itself (never
# directly observed while writing this — this machine's own credential was
# valid throughout) is classified UNKNOWN, not BAD, since the real shape of
# that failure is unmeasured and guessing risks either a false block or a
# false silent pass. If that failure mode is later observed, sharpen this
# classification with the real evidence rather than a hypothesis.
#
# Injection points for the selftest (defaults are the real commands):
#   CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD  default: "claude auth status --json"
#   CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD       default: "notify"
#   CLAUDE_CRED_PREFLIGHT_MAIL_CMD         default: "gc mail send mayor"

set -uo pipefail

_BUDGET_SEC="${CLAUDE_CRED_PREFLIGHT_BUDGET_SEC:-8}"
_ENFORCE="${CLAUDE_CRED_PREFLIGHT_ENFORCE:-0}"
_AUTH_STATUS_CMD="${CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD:-claude auth status --json}"
_NOTIFY_CMD="${CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD:-notify}"
_MAIL_CMD="${CLAUDE_CRED_PREFLIGHT_MAIL_CMD:-gc mail send mayor}"

# Canonical source: /Users/athos/gt/whatsapp_automation/lib/claude_usage_collector.py
# L92-100 (as of 2026-08-15, cited by gastown.mayor in ga-tkd2ll). Override
# without editing this file via CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS
# (space-separated) if that list changes and this file hasn't caught up.
_DEFAULT_KNOWN_EMAILS="athosmartins@gmail.com terrenos.incorporacoes@gmail.com throw.away.amb@gmail.com athoscrypto@gmail.com"
_KNOWN_EMAILS="${CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS:-$_DEFAULT_KNOWN_EMAILS}"

_WHO="${GC_AGENT:-${GC_SESSION_NAME:-unknown}}"

_log() { printf '[CRED-PREFLIGHT] %s\n' "$*"; }

_alert() {
  local subject="$1" msg="$2"
  _log "ALERT $subject -- $msg"
  bash -c "$_NOTIFY_CMD -t 'Claude cred preflight: $subject' -p 4 '$msg'" >/dev/null 2>&1 || true
  bash -c "$_MAIL_CMD -s 'Claude cred preflight: $subject' -m '$msg'" >/dev/null 2>&1 || true
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    _log "UNKNOWN: jq not on PATH -- fail-open, no block"
    return 0
  fi

  local out rc
  out=$(timeout "$_BUDGET_SEC" bash -c "$_AUTH_STATUS_CMD" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    _log "UNKNOWN: auth-status check exited $rc or produced no output -- fail-open, no block"
    return 0
  fi

  # Check presence and value separately -- jq's `// empty` treats JSON
  # `false` as falsy too, which would collapse a confirmed loggedIn:false
  # into the same "empty" shape as a genuinely-missing field. That would
  # misclassify a definitively-confirmed BAD state as UNKNOWN and silently
  # skip the alert -- exactly the bug this script exists to avoid one layer
  # up. has()+tostring keeps "false" (a real BAD reading) and "" (the field
  # was truly absent, i.e. UNKNOWN) distinct.
  local logged_in
  logged_in=$(printf '%s' "$out" | jq -r 'if has("loggedIn") then (.loggedIn|tostring) else "" end' 2>/dev/null)

  if [ -z "$logged_in" ]; then
    _log "UNKNOWN: could not find/parse loggedIn in auth-status output -- fail-open, no block"
    return 0
  fi

  if [ "$logged_in" != "true" ]; then
    local msg="claude auth status reports loggedIn=false at pre_start time (session about to spawn: $_WHO). This is the exact ga-tkd2ll symptom -- a session was about to start with no usable credential."
    _alert "no usable credential" "$msg"
    if [ "$_ENFORCE" = "1" ]; then
      _log "BAD + enforced -- blocking this spawn (exit 1)"
      return 1
    fi
    _log "BAD (shadow mode -- NOT blocking; set CLAUDE_CRED_PREFLIGHT_ENFORCE=1 to enforce once proven)"
    return 0
  fi

  local email
  email=$(printf '%s' "$out" | jq -r '.email // empty' 2>/dev/null)

  local known=0 e
  for e in $_KNOWN_EMAILS; do
    if [ "$e" = "$email" ]; then
      known=1
      break
    fi
  done

  if [ "$known" -eq 0 ]; then
    local msg="claude auth status reports loggedIn=true but email='$email' is not in the known pool ($_KNOWN_EMAILS). Session about to spawn: $_WHO. Never auto-blocked -- confirm and add to the known list if legitimate, or investigate if not."
    _alert "unrecognized account" "$msg"
    return 0
  fi

  _log "GOOD: logged in as known account ($email)"
  return 0
}

main
exit $?
