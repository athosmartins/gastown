#!/usr/bin/env bash
# home-scan-guard-activate.sh (ga-02cqk4) -- idempotently registers home-scan-guard.sh as a
# PreToolUse:Bash hook in Claude Code settings.json files (the per-rig crew ones), composing with
# whatever hooks are already there. Pool roles do NOT go through this script: their overlays are
# generated from pool-roles.json (common.hooks) by pool-preamble-build.py.
#
# WHY A SCRIPT: per-rig .claude/ dirs are gitignored, so the live settings.json these hooks must
# land in can never itself be a git commit. This git-tracked, re-runnable script is the substitute
# (same reasoning and shape as dangerous-command-guard-activate.sh, ga-7j1yu): run it once to
# activate, and again any time a rig reset / `gc init` regenerates a settings.json. MERGED != LIVE:
# after running it, `--check` proves the hook is in the settings each crew reads, and a crew
# session only picks up a changed hook set when it (re)starts.
#
# WHAT IT WRITES: ONE dedicated entry
#     {"matcher":"^Bash$","hooks":[{"type":"command","command":<see below>,"timeout":10}]}
#   * a DEDICATED entry with its own matcher, never a hook folded into an existing matcher="Bash"
#     entry. The engine merges pool overlays into a workdir's settings.json by matcher identity
#     (gascity internal/overlay/merge.go hookEntryKey: same matcher => the overlay entry REPLACES
#     the base entry in place). A pool overlay carrying matcher="Bash" would therefore wipe the
#     dangerous-command guards that live in a workdir's own Bash entry. "^Bash$" is a tool-name
#     regex (it still matches only the Bash tool) with an identity of its own: the overlay appends
#     it once, idempotently, and this script and the overlay converge on the very same entry.
#   * no command pattern in "matcher" (that never fires -- ga-7j1yu) and no "if": this guard's bash
#     prefilter already makes the no-op case nearly free, and an "if" glob could not see inside a
#     `for ... do ... done`.
#   * the command is fail-open twice over: it exits 0 when the guard file is gone (a checkout that
#     moved must not turn every Bash call of every crew into a hook error), and home-scan-guard.sh
#     itself exits 0 on any failure of its own.
#   * the guard path is the MAIN checkout, never a worktree: a hook that points into a worktree
#     dies when the worktree is cleaned up (same trap pkill-exec-guard-activate.sh documents).
#     Because the command is a no-op while that file does not exist, running this BEFORE the guard has
#     merged is harmless (it just starts biting when the file lands); running it after is the normal order.
#
# MERGE SEMANTICS: any hook whose command contains the marker "home-scan-guard" is OURS (the command
# carries it as a `: home-scan-guard;` no-op, so this never depends on the guard's path or file name).
# The dedicated ^Bash$ entry is converged IN PLACE (created at the end if absent, extra copies
# dropped); a hook of ours found inside any OTHER entry (an older activation that folded it into a
# Bash entry) is removed, and that entry is dropped only if that left it empty. Nothing that is not
# ours is ever modified, replaced or reordered.
#
# USAGE: home-scan-guard-activate.sh [--check] [path-to-settings.json ...]
#   no paths : every crew / witness / refinery / worker settings.json that exists under
#              ${HOME_SCAN_GUARD_RIGS_ROOT:-/Users/athos/gt}
#   --check  : write nothing; print GUARDED / NOT-GUARDED per target; exit 1 if any is not guarded
#   Idempotent. A target that cannot be processed (missing, unparseable) never stops the others;
#   the exit status is 1 if any failed.
set -uo pipefail

RIGS_ROOT="${HOME_SCAN_GUARD_RIGS_ROOT:-/Users/athos/gt}"
GUARD_PATH="${HOME_SCAN_GUARD_SCRIPT:-/Users/athos/gt/.gascity-gastown-hq/scripts/home-scan-guard.sh}"
MARKER="home-scan-guard"
ENTRY_MATCHER='^Bash$'
TIMEOUT_S=10
case "$GUARD_PATH" in
  /*) ;;
  *) echo "FATAL: guard path must be absolute, got '$GUARD_PATH'" >&2; exit 1 ;;
esac
case "$GUARD_PATH" in
  *"'"*) echo "FATAL: guard path may not contain a single quote (it is embedded in single quotes): $GUARD_PATH" >&2; exit 1 ;;
esac
# the leading `: home-scan-guard;` is a no-op whose only job is to carry the MARKER inside the command
# itself, so identifying "our" hook never depends on the guard's path or file name.
HOOK_CMD=": ${MARKER}; P='${GUARD_PATH}'; [ -f \"\$P\" ] || exit 0; exec /bin/bash \"\$P\""

CHECK=0
TARGETS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) TARGETS+=("$a") ;;
  esac
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  shopt -s nullglob
  for f in "$RIGS_ROOT"/*/crew/.claude/settings.json \
           "$RIGS_ROOT"/*/crew/*/.claude/settings.json \
           "$RIGS_ROOT"/*/witness/.claude/settings.json \
           "$RIGS_ROOT"/*/refinery/.claude/settings.json; do
    TARGETS+=("$f")
  done
  shopt -u nullglob
fi
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "FATAL: no settings.json targets found under $RIGS_ROOT" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 1; }

# The desired state, as ONE jq definition shared by activation and --check so they cannot drift.
JQ_APPLY='
  (.hooks //= {}) | (.hooks.PreToolUse //= []) |
  ({type: "command", command: $cmd, timeout: $timeout}) as $hook |
  # the dedicated entry: converge the FIRST one in place, drop any extra copies
  ([.hooks.PreToolUse | to_entries[] | select(.value.matcher == $m) | .key]) as $mine |
  .hooks.PreToolUse |= [to_entries[]
      | select((.value.matcher != $m) or (.key == $mine[0]))
      | (if .value.matcher == $m then .value.hooks = [$hook] else . end)
      | .value] |
  # a hook of ours inside any OTHER entry (older activation): remove it; drop the entry only if
  # that left it empty -- an entry that held none of ours is never touched
  .hooks.PreToolUse |= map(
    if (.matcher != $m) and (((.hooks // []) | map(select((.command // "") | contains($marker))) | length) > 0) then
      ((.hooks | map(select(((.command // "") | contains($marker)) | not))) as $keep
       | if ($keep | length) == 0 then empty else .hooks = $keep end)
    else . end) |
  (if any(.hooks.PreToolUse[]; .matcher == $m) then . else .hooks.PreToolUse += [{matcher: $m, hooks: [$hook]}] end)'

STATUS=0
for SETTINGS in "${TARGETS[@]}"; do
  if [ ! -f "$SETTINGS" ]; then
    echo "FATAL: settings.json not found at $SETTINGS" >&2
    STATUS=1
    continue
  fi
  TMP="$(mktemp "${TMPDIR:-/tmp}/hsg-activate.XXXXXX")" || { STATUS=1; continue; }

  if ! jq --arg cmd "$HOOK_CMD" --arg marker "$MARKER" --arg m "$ENTRY_MATCHER" --argjson timeout "$TIMEOUT_S" \
        "$JQ_APPLY" "$SETTINGS" > "$TMP" 2>/dev/null; then
    echo "FATAL: jq failed processing $SETTINGS (invalid/unparseable JSON, or not an object) -- skipped, other targets unaffected" >&2
    rm -f "$TMP"
    STATUS=1
    continue
  fi
  # never overwrite a real settings file with something jq should not have produced
  if ! jq -e 'type == "object"' "$TMP" >/dev/null 2>&1; then
    echo "FATAL: jq produced invalid JSON for $SETTINGS -- skipped, not overwriting" >&2
    rm -f "$TMP"
    STATUS=1
    continue
  fi

  # "already guarded" is decided on the SEMANTIC state (jq -S), not on bytes: a settings.json
  # whose formatting merely differs from jq's must not be rewritten (and backed up) every run.
  if [ "$(jq -S . "$SETTINGS" 2>/dev/null)" = "$(jq -S . "$TMP")" ]; then
    echo "GUARDED: $SETTINGS"
    rm -f "$TMP"
    continue
  fi

  if [ "$CHECK" -eq 1 ]; then
    echo "NOT-GUARDED: $SETTINGS"
    rm -f "$TMP"
    STATUS=1
    continue
  fi

  # Backup FIRST and treat a failed backup as "cannot proceed", not as a formality: overwriting a live
  # settings file when we could not preserve the previous one is a destructive write on "don't know".
  BAK="${SETTINGS}.bak.$(date +%s)"
  if ! cp -p "$SETTINGS" "$BAK" 2>/dev/null; then
    echo "FATAL: could not back up $SETTINGS -- NOT modified" >&2
    rm -f "$TMP"
    STATUS=1
    continue
  fi
  # Write through a copy of the ORIGINAL (cp -p keeps its mode/owner), so the result keeps the settings
  # file's own mode without having to read it (a mktemp file is 0600), then rename over it atomically.
  NEW="${SETTINGS}.new.$$"
  if cp -p "$SETTINGS" "$NEW" 2>/dev/null && cat "$TMP" > "$NEW" 2>/dev/null && mv "$NEW" "$SETTINGS"; then
    echo "Registered home-scan-guard hook in $SETTINGS"
  else
    echo "FATAL: could not write $SETTINGS (original left as it was; backup at $BAK)" >&2
    rm -f "$NEW"
    STATUS=1
  fi
  rm -f "$TMP"
done

exit "$STATUS"
