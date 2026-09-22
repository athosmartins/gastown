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
#           reported symptom. Alert (shadow or enforce), rate-limited like
#           WARN below. Blocks the spawn only when
#           CLAUDE_CRED_PREFLIGHT_ENFORCE=1.
#   WARN    loggedIn=true but email is NOT a recognized pool account. Alert
#           (a human should confirm/allowlist it) but NEVER blocks, even when
#           enforced — the known-account list can go stale, and a false block
#           here is worse than a missed alert. Rate-limited per account to at
#           most one message per CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC
#           (default 1h): every spawn re-triggers the check, so an account
#           left off the list for a while must not flood the mailbox with
#           one identical message per session (ga-2g6w4s: 170 in one night).
#           A message sent after suppressed repeats reports how many
#           occurrences it collapsed.
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
#   CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC  default: 3600 (1h) — per-key
#                                              alert rate limit, see _alert()
#   CLAUDE_CRED_PREFLIGHT_STATE_DIR        default: ~/.claude/cred-preflight-alerts

set -uo pipefail

_BUDGET_SEC="${CLAUDE_CRED_PREFLIGHT_BUDGET_SEC:-8}"
_ENFORCE="${CLAUDE_CRED_PREFLIGHT_ENFORCE:-0}"
_AUTH_STATUS_CMD="${CLAUDE_CRED_PREFLIGHT_AUTH_STATUS_CMD:-claude auth status --json}"
_NOTIFY_CMD="${CLAUDE_CRED_PREFLIGHT_NOTIFY_CMD:-notify}"
_MAIL_CMD="${CLAUDE_CRED_PREFLIGHT_MAIL_CMD:-gc mail send mayor}"
_ALERT_COOLDOWN_SEC="${CLAUDE_CRED_PREFLIGHT_ALERT_COOLDOWN_SEC:-3600}"
_STATE_DIR="${CLAUDE_CRED_PREFLIGHT_STATE_DIR:-$HOME/.claude/cred-preflight-alerts}"

# Canonical source: /Users/athos/gt/whatsapp_automation/lib/claude_usage_collector.py
# ACCOUNTS (as of 2026-09-22, athosb85@gmail.com added by wa-b741h; cited by
# gastown.mayor in ga-tkd2ll and ga-2g6w4s). Override without editing this
# file via CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS (space-separated) if that list
# changes and this file hasn't caught up.
_DEFAULT_KNOWN_EMAILS="athosmartins@gmail.com terrenos.incorporacoes@gmail.com throw.away.amb@gmail.com athoscrypto@gmail.com athosb85@gmail.com"
_KNOWN_EMAILS="${CLAUDE_CRED_PREFLIGHT_KNOWN_EMAILS:-$_DEFAULT_KNOWN_EMAILS}"

_WHO="${GC_AGENT:-${GC_SESSION_NAME:-unknown}}"

_log() { printf '[CRED-PREFLIGHT] %s\n' "$*"; }

# _alert_state_key <subject> <discriminator> -> sanitized filename stem
# (same tr-based idiom as daemon-presence-watchdog.sh's _alert_cd_file / the
# _cooldown_elapsed+_mark_now pair in city-health-sentinel.sh -- reused here
# rather than reinvented). <discriminator> is normally the account email;
# never shell-interpreted, only ever used as a path component.
_alert_state_key() {
  printf '%s' "${1}__${2}" | tr -c 'A-Za-z0-9._-' '_'
}

# ga-2g6w4s: an unrecognized/missing credential is re-checked on EVERY spawn,
# so a sustained misalignment (an account left off the known-pool list, or a
# real outage) used to mail/notify once per spawn -- 170 identical messages
# in one night, burying real signal in the Mayor's inbox. Collapse repeats:
# at most one message per (subject, discriminator) per _ALERT_COOLDOWN_SEC.
# The first occurrence in a window sends immediately (unchanged latency for
# a fresh problem); further occurrences in the same window are suppressed
# but counted; the next occurrence after the window elapses sends again and
# reports how many occurrences (including itself) it collapsed, so the
# signal ("this is still happening, N times since the last alert") survives
# the suppression instead of going silent.
_alert() {
  local subject="$1" msg="$2" discriminator="${3:-}"
  _log "ALERT $subject -- $msg"

  local key sent_f count_f now last count sent_msg
  key="$(_alert_state_key "$subject" "$discriminator")"
  sent_f="$_STATE_DIR/$key.last_sent"
  count_f="$_STATE_DIR/$key.count"
  now="$(date +%s)"
  # VISIBLE fail-open, not silent: an unwritable state dir makes every
  # subsequent read below come back empty too, so the cooldown degrades to
  # "always send" -- correct (never let a state-layer problem silence a
  # real alert), but doing that with NO signal would reintroduce this
  # bead's own root cause invisibly, one _log line short of the same "170
  # in one night" symptom. Log once per call so the degradation is
  # observable in the script's own output, not just inferred later from a
  # mailbox that never stopped flooding.
  mkdir -p "$_STATE_DIR" 2>/dev/null || _log "WARN: could not create state dir $_STATE_DIR -- rate limiting inactive this call (fail-open: alert still sends)"

  # Fail-open on any read/parse trouble (missing or corrupt state, unwritable
  # dir): treat as "never sent" so a state-layer problem can never
  # permanently silence a real alert -- same posture _cooldown_elapsed()
  # documents in city-health-sentinel.sh, for the identical reason.
  last="$(cat "$sent_f" 2>/dev/null)"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  count="$(cat "$count_f" 2>/dev/null)"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  printf '%s' "$count" > "$count_f" 2>/dev/null || true

  if [ "$last" -eq 0 ] || [ $(( now - last )) -ge "$_ALERT_COOLDOWN_SEC" ]; then
    sent_msg="$msg"
    [ "$count" -gt 1 ] && sent_msg="$msg (x$count in the last ~$((_ALERT_COOLDOWN_SEC / 60))min; repeats were suppressed in this window)"
    # SECURITY: $subject/$msg (and now $discriminator, folded into
    # $sent_msg) can carry data this script does not fully control (claude
    # auth status's own `email` field; $_WHO from GC_AGENT/GC_SESSION_NAME).
    # Earlier drafts built one string via bash -c "$_NOTIFY_CMD -t '...' -p 4
    # '$msg'" -- that hands the ALREADY-expanded string to a SECOND shell
    # parse, so any shell metacharacter inside that content (not just a
    # literal quote) could break out of the intended argument and be
    # re-interpreted as shell syntax. Fixed by invoking directly instead of
    # through bash -c: $_NOTIFY_CMD/$_MAIL_CMD are intentionally left
    # unquoted (word-split into a command+args prefix, e.g. "gc mail send
    # mayor" -- operator/config-controlled, not data), but
    # $subject/$sent_msg are double-quoted and passed as direct argv entries
    # with NO re-parse step, so their content is always inert data, never
    # syntax.
    $_NOTIFY_CMD -t "Claude cred preflight: $subject" -p 4 "$sent_msg" >/dev/null 2>&1 || true
    $_MAIL_CMD -s "Claude cred preflight: $subject" -m "$sent_msg" >/dev/null 2>&1 || true
    printf '%s' "$now" > "$sent_f" 2>/dev/null || true
    printf '0' > "$count_f" 2>/dev/null || true
  else
    _log "SUPPRESSED $subject -- rate-limited ($count occurrence(s) since last alert $(( now - last ))s ago, cooldown=${_ALERT_COOLDOWN_SEC}s)"
  fi
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    _log "UNKNOWN: jq not on PATH -- fail-open, no block"
    return 0
  fi

  local out rc
  # $_AUTH_STATUS_CMD intentionally unquoted (word-split command+args
  # prefix, same rationale as _NOTIFY_CMD/_MAIL_CMD in _alert() above) --
  # no untrusted data is concatenated into this value, only a config
  # override, but avoiding bash -c "$STRING" here too keeps one invocation
  # style throughout instead of leaving a second instance of the pattern
  # a reviewer would otherwise have to re-verify is safe on its own.
  out=$(timeout "$_BUDGET_SEC" $_AUTH_STATUS_CMD 2>&1)
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
    local msg="claude auth status reports loggedIn=true but email=$email is not in the known pool ($_KNOWN_EMAILS). Session about to spawn: $_WHO. Never auto-blocked -- confirm and add to the known list if legitimate, or investigate if not."
    _alert "unrecognized account" "$msg" "$email"
    return 0
  fi

  _log "GOOD: logged in as known account ($email)"
  return 0
}

main
exit $?
