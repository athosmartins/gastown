#!/bin/bash
# claude-account-relog.sh — auto-relog into a Claude account with more quota
# when the active account hits the apex of its 5h-window limit (ga-jf689).
#
# WHY THIS EXISTS
# ----------------
# When a Claude session (Mayor / gate reviewer / dog / worker) hits the APEX of
# its 5h rolling window — "You've hit your session limit · resets HH:MM" — it
# STOPS mid-work. The gate then reads the stalled session as a boot-stall,
# waits 45min, and FALSE-FAILs while the backlog grows. Until now Athos had to
# swap Claude accounts BY HAND. This makes the swap automatic.
#
# RELATION TO SIBLINGS
#   - ga-wjlv9 (claude-quota-check.sh): the ground-truth detector this builds
#     on. It reads the real exhaustion EVENT from the session transcript, not a
#     wall-clock fiction. We treat `limited=true` (exit 2) as "at the apex".
#   - ga-x3nmz (quota-aware pipeline): PAUSES until reset. That is the FALLBACK
#     here — if NO pool account has headroom, we do NOT swap; we emit a PAUSE
#     signal and let the pause path take over. Auto-relog is the happy path
#     (keep going on another account); pause is the safety net.
#
# HOW THE SWAP WORKS
# ------------------
# Claude Code on macOS stores its OAuth credential in the login Keychain under
# the generic-password service "Claude Code-credentials". The secret is a JSON
# blob: {"claudeAiOauth":{"accessToken":...,"refreshToken":...,...}, ...}.
# Swapping accounts = replacing that Keychain blob with another account's blob.
# Sessions spawned AFTER the swap pick up the new account. In-flight sessions
# that are already wedged at the apex are killed+respawned by the normal
# shutdown-dance / recovery path and come back on the new account.
#
# We do NOT query each candidate account's live quota (that would require being
# logged in as it). Instead we track a per-account COOLDOWN: when we observe an
# apex event under the active account, we record it limited-until-its-reset, and
# the pool picks the next account NOT currently in cooldown. Simple, and it is
# exactly the signal we have.
#
# SECURITY (AC4: never leak a credential to a log)
#   - The credential blob is read from / written to the Keychain and the secret
#     store ONLY. It is never echoed, never logged, never put in a bead.
#   - Every line we emit goes through a redaction guard that ABORTS if it ever
#     contains an `sk-ant-` token. Accounts are identified in logs by a LABEL
#     and an 8-hex fingerprint (sha256 prefix of the access token), never the
#     token itself.
#   - Account blobs live in Bitwarden, fetched at runtime via `secret`
#     (~/.local/bin/secret). Nothing is hardcoded.
#
# FAIL-CLOSED
#   The orchestrator (`auto`) is gated behind CLAUDE_RELOG_ENABLED=1. Default is
#   OFF: it logs "disabled" and exits 0 without touching anything. This lets the
#   code merge and the launchd job load WITHOUT mutating Athos's live creds
#   before he has populated the account pool and opted in. Read-only subcommands
#   (status/pool/current/select) work regardless. Mutating subcommands
#   (swap/auto) honor --dry-run and the enable gate.
#
# USAGE
#   claude-account-relog.sh status            # active account + quota + pool map
#   claude-account-relog.sh pool              # configured labels + cooldown state
#   claude-account-relog.sh current           # active account label (or unknown)
#   claude-account-relog.sh select            # next label with headroom (or none)
#   claude-account-relog.sh swap <label>      # swap Keychain to <label> (gated)
#   claude-account-relog.sh auto              # detect apex → swap or pause (gated)
#   claude-account-relog.sh register <label>  # tag the CURRENT keychain blob as <label>
#   any of swap/auto/register accept --dry-run to print intent without mutating.
#
# EXIT CODES
#   0 = ok / no action needed / swap done
#   2 = at apex but NO headroom account → PAUSE signaled (defer to ga-x3nmz)
#   3 = at apex, swap attempted but FAILED (e.g. secret missing)
#   1 = internal error / bad usage
#
# ENV OVERRIDES (the selftest injects all of these for hermetic runs)
#   CLAUDE_RELOG_ENABLED       1 to allow live mutation in `auto` (default 0)
#   CLAUDE_RELOG_STATE_DIR     state dir (default ~/.claude/account-pool)
#   CLAUDE_RELOG_QUOTA_CHECK   path to quota checker (default scripts/claude-quota-check.sh)
#   CLAUDE_RELOG_SECRET_CMD    command to fetch an account blob (default: secret)
#                              invoked as: $CLAUDE_RELOG_SECRET_CMD claude-acct-<label>
#   CLAUDE_RELOG_KEYCHAIN_GET  command printing the active Keychain blob to stdout
#                              (default: security find-generic-password -s ... -w)
#   CLAUDE_RELOG_KEYCHAIN_SET  command reading a blob on stdin and storing it
#                              (default: security add-generic-password -U ...)
#   CLAUDE_RELOG_NOTIFY        notify command (default: notify; falls back to log)
#   CLAUDE_RELOG_NOW           epoch seconds to treat as "now" (default: real now)
#   CLAUDE_RELOG_POOL          space/newline-separated label list (overrides registry order)
#
# Dependencies: bash, jq, shasum (or sha256sum), date.

set -uo pipefail

# --------------------------------------------------------------------------
# Config / environment
# --------------------------------------------------------------------------
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYCHAIN_SERVICE="Claude Code-credentials"
STATE_DIR="${CLAUDE_RELOG_STATE_DIR:-$HOME/.claude/account-pool}"
REGISTRY="$STATE_DIR/registry.json"   # [{label, fingerprint}]  — NO secrets
STATE="$STATE_DIR/state.json"         # {label: {limited_until, reset_text, last_active}}
QUOTA_CHECK="${CLAUDE_RELOG_QUOTA_CHECK:-$SELF_DIR/claude-quota-check.sh}"
SECRET_CMD="${CLAUDE_RELOG_SECRET_CMD:-secret}"
NOTIFY_CMD="${CLAUDE_RELOG_NOTIFY:-notify}"
NOW="${CLAUDE_RELOG_NOW:-$(date +%s)}"
ENABLED="${CLAUDE_RELOG_ENABLED:-0}"

command -v jq >/dev/null 2>&1 || { echo "claude-account-relog: jq not found" >&2; exit 1; }

# --------------------------------------------------------------------------
# Redaction guard — AC4. Nothing we print may contain a credential token.
# Any attempt to emit `sk-ant-...` is a bug; abort the WHOLE script loudly
# rather than leak. The check runs INLINE (not behind a pipe) so the abort
# kills the parent process, not just a subshell — a hard fail-loud guarantee.
# --------------------------------------------------------------------------
_assert_clean() { # <text...> ; abort the script if it carries a token
  case "$*" in
    *sk-ant-*) echo "claude-account-relog: FATAL redaction guard tripped (refusing to log a credential)" >&2; exit 1 ;;
  esac
}
# _guard: same protection for arbitrary piped content (defense in depth).
_guard() { # stdin → stdout, dropping+aborting if a token slips through
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *sk-ant-*) echo "claude-account-relog: FATAL redaction guard tripped (refusing to log a credential)" >&2; exit 1 ;;
    esac
    printf '%s\n' "$line"
  done
}
log() { _assert_clean "$*"; printf '%s\n' "$*"; }
err() { _assert_clean "$*"; printf '%s\n' "$*" >&2; }

# --------------------------------------------------------------------------
# Keychain access (overridable for tests)
# --------------------------------------------------------------------------
keychain_get() {
  if [ -n "${CLAUDE_RELOG_KEYCHAIN_GET:-}" ]; then
    eval "$CLAUDE_RELOG_KEYCHAIN_GET"
  else
    security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null
  fi
}
keychain_set() { # reads blob on stdin
  if [ -n "${CLAUDE_RELOG_KEYCHAIN_SET:-}" ]; then
    eval "$CLAUDE_RELOG_KEYCHAIN_SET"
  else
    # -U updates the existing item in place; -a preserves the account field.
    local acct blob
    acct="$(security find-generic-password -s "$KEYCHAIN_SERVICE" 2>/dev/null \
            | sed -n 's/.*"acct"<blob>="\(.*\)"/\1/p')"
    blob="$(cat)"
    security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "${acct:-claude}" -w "$blob" 2>/dev/null
  fi
}

# Fetch an account's blob from the secret store (Bitwarden). Never logged.
secret_get() { # <label> → blob on stdout (empty if unavailable)
  "$SECRET_CMD" "claude-acct-$1" 2>/dev/null
}

# Fingerprint a blob WITHOUT revealing it: sha256 of the access token, 8 hex.
# Returns empty for an unparseable/empty blob.
fingerprint() { # blob on stdin → 8-hex or empty
  local blob tok sum
  blob="$(cat)"
  [ -z "$blob" ] && { printf ''; return; }
  tok="$(printf '%s' "$blob" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)"
  [ -z "$tok" ] && { printf ''; return; }
  if command -v shasum >/dev/null 2>&1; then
    sum="$(printf '%s' "$tok" | shasum -a 256 | cut -c1-8)"
  else
    sum="$(printf '%s' "$tok" | sha256sum | cut -c1-8)"
  fi
  printf '%s' "$sum"
}

# --------------------------------------------------------------------------
# State helpers
# --------------------------------------------------------------------------
ensure_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  [ -f "$REGISTRY" ] || printf '[]\n' > "$REGISTRY"
  [ -f "$STATE" ]    || printf '{}\n' > "$STATE"
}

# Ordered list of pool labels. CLAUDE_RELOG_POOL wins; else registry order.
pool_labels() {
  if [ -n "${CLAUDE_RELOG_POOL:-}" ]; then
    printf '%s\n' $CLAUDE_RELOG_POOL
  else
    jq -r '.[].label' "$REGISTRY" 2>/dev/null
  fi
}

# Is <label> currently in cooldown (limited_until still in the future)?
in_cooldown() { # <label> → exit 0 if limited now
  local until
  until="$(jq -r --arg l "$1" '.[$l].limited_until // 0' "$STATE" 2>/dev/null)"
  [ -n "$until" ] && [ "$until" != "null" ] && [ "$until" -gt "$NOW" ] 2>/dev/null
}

# Record <label> limited until <epoch> (reset text optional).
mark_limited() { # <label> <until_epoch> <reset_text>
  ensure_state
  local tmp; tmp="$(mktemp)"
  jq --arg l "$1" --argjson u "${2:-0}" --arg t "${3:-}" \
     '.[$l] = ((.[$l] // {}) + {limited_until: $u, reset_text: $t})' \
     "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" || rm -f "$tmp"
}

# Record <label> as the active account (clears any stale cooldown on it).
mark_active() { # <label>
  ensure_state
  local tmp; tmp="$(mktemp)"
  jq --arg l "$1" --argjson n "$NOW" \
     '.[$l] = ((.[$l] // {}) + {last_active: $n, limited_until: 0})' \
     "$STATE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE" || rm -f "$tmp"
}

# Upsert a {label,fingerprint} into the registry.
register_fp() { # <label> <fingerprint>
  ensure_state
  local tmp; tmp="$(mktemp)"
  jq --arg l "$1" --arg f "$2" \
     '(map(select(.label != $l))) + [{label:$l, fingerprint:$f}]' \
     "$REGISTRY" > "$tmp" 2>/dev/null && mv "$tmp" "$REGISTRY" || rm -f "$tmp"
}

# Which label matches the current Keychain blob's fingerprint?
current_label() { # → label or "unknown"
  ensure_state
  local fp lbl
  fp="$(keychain_get | fingerprint)"
  [ -z "$fp" ] && { printf 'unknown'; return; }
  lbl="$(jq -r --arg f "$fp" '.[] | select(.fingerprint == $f) | .label' "$REGISTRY" 2>/dev/null | head -1)"
  printf '%s' "${lbl:-unknown}"
}

# --------------------------------------------------------------------------
# Quota detection (ga-wjlv9). Sets QUOTA_JSON, QUOTA_LIMITED (0/1).
# --------------------------------------------------------------------------
read_quota() {
  QUOTA_JSON="$("$QUOTA_CHECK" --json 2>/dev/null)"
  if [ -z "$QUOTA_JSON" ]; then
    QUOTA_LIMITED=-1   # unknown
    return
  fi
  if [ "$(printf '%s' "$QUOTA_JSON" | jq -r '.limited' 2>/dev/null)" = "true" ]; then
    QUOTA_LIMITED=1
  else
    QUOTA_LIMITED=0
  fi
}

# Reset epoch from the quota JSON (active scope), or NOW+5h as a safe default.
quota_reset_epoch() {
  local mins
  mins="$(printf '%s' "$QUOTA_JSON" | jq -r '.reset_in_minutes // empty' 2>/dev/null)"
  if [ -n "$mins" ] && [ "$mins" != "null" ]; then
    printf '%s' "$((NOW + mins * 60))"
  else
    printf '%s' "$((NOW + 18000))"
  fi
}
quota_reset_text() {
  printf '%s' "$(printf '%s' "$QUOTA_JSON" | jq -r '.reset_time_text // ""' 2>/dev/null)"
}

# --------------------------------------------------------------------------
# Selection: next label with headroom (not in cooldown), excluding <exclude>.
# --------------------------------------------------------------------------
select_headroom() { # [exclude_label] → label or empty
  local exclude="${1:-}" lbl
  while IFS= read -r lbl; do
    [ -z "$lbl" ] && continue
    [ "$lbl" = "$exclude" ] && continue
    in_cooldown "$lbl" && continue
    printf '%s' "$lbl"
    return 0
  done < <(pool_labels)
  printf ''
  return 1
}

# --------------------------------------------------------------------------
# notify wrapper — label/ETA only, never a token. `log` aborts inline if the
# message carries a token, so a tainted message never reaches the notifier.
#
# The function is named `relog_notify`, NOT `notify`: NOTIFY_CMD defaults to
# the external `notify` CLI, and a shell function named `notify` would shadow
# it — `command -v notify` resolves the function, so `"$NOTIFY_CMD" ...` would
# re-enter this function recursively (each level sees $1="-t") and segfault
# before any notice is sent. Keeping the names distinct lets the lookup find
# the real CLI on PATH (or nothing, if absent).
# --------------------------------------------------------------------------
relog_notify() { # <message>
  local msg="$1"
  log "$msg"   # aborts the script if $msg contains a credential token
  if command -v "$NOTIFY_CMD" >/dev/null 2>&1; then
    "$NOTIFY_CMD" -t "Claude auto-relog" "$msg" >/dev/null 2>&1 || true
  fi
}

# --------------------------------------------------------------------------
# Core swap: write <label>'s blob into the Keychain. Honors --dry-run.
# Returns 0 on success, 3 on failure (missing/invalid secret).
# --------------------------------------------------------------------------
do_swap() { # <label> [--dry-run]
  local label="$1" dry="${2:-}"
  local blob fp
  blob="$(secret_get "$label")"
  if [ -z "$blob" ]; then
    err "swap: no credential for label '$label' (secret 'claude-acct-$label' missing/empty)"
    return 3
  fi
  fp="$(printf '%s' "$blob" | fingerprint)"
  if [ -z "$fp" ]; then
    err "swap: credential for '$label' is not a valid Claude OAuth blob"
    return 3
  fi
  if [ "$dry" = "--dry-run" ]; then
    log "DRY-RUN: would swap Keychain to account '$label' (fp=$fp)"
    return 0
  fi
  if ! printf '%s' "$blob" | keychain_set; then
    err "swap: keychain write failed for '$label'"
    return 3
  fi
  register_fp "$label" "$fp"
  mark_active "$label"
  log "swapped active Claude account → '$label' (fp=$fp)"
  return 0
}

# --------------------------------------------------------------------------
# Subcommands
# --------------------------------------------------------------------------
cmd_pool() {
  ensure_state
  local lbl until rt active
  active="$(current_label)"
  log "Claude account pool (active: $active)"
  local any=0
  while IFS= read -r lbl; do
    [ -z "$lbl" ] && continue
    any=1
    until="$(jq -r --arg l "$lbl" '.[$l].limited_until // 0' "$STATE" 2>/dev/null)"
    rt="$(jq -r --arg l "$lbl" '.[$l].reset_text // ""' "$STATE" 2>/dev/null)"
    if [ "${until:-0}" -gt "$NOW" ] 2>/dev/null; then
      log "  - $lbl: COOLDOWN until $(date -r "$until" '+%H:%M' 2>/dev/null) ${rt:+($rt)}"
    else
      log "  - $lbl: headroom"
    fi
  done < <(pool_labels)
  if [ "$any" = 0 ]; then
    log "  (no accounts registered — populate registry + Bitwarden 'claude-acct-<label>')"
  fi
  return 0
}

cmd_status() {
  ensure_state
  read_quota
  local active sig
  active="$(current_label)"
  case "$QUOTA_LIMITED" in
    1) sig="LIMITED ($(printf '%s' "$QUOTA_JSON" | jq -r '.scope') — resets $(quota_reset_text))" ;;
    0) sig="not limited" ;;
    *) sig="quota check unavailable" ;;
  esac
  log "active account: $active"
  log "quota: $sig"
  log "relog enabled: $([ "$ENABLED" = 1 ] && echo yes || echo 'no (fail-closed; set CLAUDE_RELOG_ENABLED=1)')"
  cmd_pool
}

cmd_current() { current_label; printf '\n'; }

cmd_select() {
  ensure_state
  local active next
  active="$(current_label)"
  next="$(select_headroom "$active")"
  if [ -n "$next" ]; then log "$next"; else log "none"; return 2; fi
}

cmd_register() { # tag the CURRENT keychain blob with <label>
  local label="$1" dry="${2:-}"
  [ -z "$label" ] && { err "register: missing <label>"; return 1; }
  local fp
  fp="$(keychain_get | fingerprint)"
  if [ -z "$fp" ]; then err "register: no readable Claude credential in Keychain"; return 1; fi
  if [ "$dry" = "--dry-run" ]; then log "DRY-RUN: would register current account as '$label' (fp=$fp)"; return 0; fi
  register_fp "$label" "$fp"
  mark_active "$label"
  log "registered current account as '$label' (fp=$fp)"
}

cmd_swap() {
  local label="$1" dry="${2:-}"
  [ -z "$label" ] && { err "swap: missing <label>"; return 1; }
  if [ "$dry" != "--dry-run" ] && [ "$ENABLED" != 1 ]; then
    err "swap: refusing live swap — CLAUDE_RELOG_ENABLED != 1 (use --dry-run, or enable)"
    return 1
  fi
  do_swap "$label" "$dry"
}

# The orchestrator. Detect apex → mark active limited → swap to headroom →
# notify. No headroom → PAUSE (exit 2). Swap failed → exit 3.
cmd_auto() {
  local dry="${1:-}"
  ensure_state

  # Fail-closed gate (unless explicitly dry-running for observation).
  if [ "$dry" != "--dry-run" ] && [ "$ENABLED" != 1 ]; then
    log "auto: disabled (CLAUDE_RELOG_ENABLED != 1) — no action. Set CLAUDE_RELOG_ENABLED=1 after populating the account pool."
    return 0
  fi

  read_quota
  if [ "$QUOTA_LIMITED" = "-1" ]; then
    err "auto: quota check unavailable — cannot decide; doing nothing"
    return 1
  fi
  if [ "$QUOTA_LIMITED" = "0" ]; then
    log "auto: active account not at apex — nothing to do"
    return 0
  fi

  # At the apex. Mark the active account limited until its reset.
  local active reset_epoch reset_text next
  active="$(current_label)"
  reset_epoch="$(quota_reset_epoch)"
  reset_text="$(quota_reset_text)"
  if [ "$active" != "unknown" ]; then
    mark_limited "$active" "$reset_epoch" "$reset_text"
  fi

  next="$(select_headroom "$active")"
  if [ -z "$next" ]; then
    relog_notify "Claude account '$active' at apex (resets ${reset_text:-?}) — NO pool account with headroom → PAUSE (ga-x3nmz fallback)"
    return 2
  fi

  if [ "$dry" = "--dry-run" ]; then
    log "DRY-RUN: account '$active' at apex → would relog to '$next' (headroom)"
    return 0
  fi

  if do_swap "$next"; then
    relog_notify "Claude account '$active' at apex (resets ${reset_text:-?}) → relogged to '$next' (headroom). Sessions continue."
    return 0
  else
    relog_notify "Claude account '$active' at apex → swap to '$next' FAILED (credential missing/invalid) → PAUSE fallback"
    return 3
  fi
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
usage() { sed -n '/^# USAGE/,/^# EXIT CODES/p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local sub="${1:-status}"; shift || true
  # Split off a trailing --dry-run flag for the mutating subcommands.
  local dry="" pos=()
  for a in "$@"; do
    case "$a" in
      --dry-run) dry="--dry-run" ;;
      *) pos+=("$a") ;;
    esac
  done
  case "$sub" in
    status)   cmd_status ;;
    pool)     cmd_pool ;;
    current)  cmd_current ;;
    select)   cmd_select ;;
    register) cmd_register "${pos[0]:-}" "$dry" ;;
    swap)     cmd_swap "${pos[0]:-}" "$dry" ;;
    auto)     cmd_auto "$dry" ;;
    -h|--help|help) usage ;;
    *) err "unknown subcommand: $sub"; usage; exit 1 ;;
  esac
}

main "$@"
