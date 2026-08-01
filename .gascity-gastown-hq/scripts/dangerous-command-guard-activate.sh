#!/usr/bin/env bash
# dangerous-command-guard-activate.sh (ga-7j1yu, follow-up to ga-vrwo3) —
# idempotently registers "gt tap guard dangerous-command" as an if-gated
# PreToolUse:Bash hook in one or more Claude Code settings.json files,
# composing with whatever hooks are already there.
#
# WHY: per-rig .claude/ dirs are gitignored -- so the live settings.json
# these hooks must land in can never itself be a git commit. This script
# is the git-tracked, reviewable, re-runnable substitute: run it once to
# activate, and again any time `gc init`/`gc start` or a rig reset
# regenerates a settings.json. Mirrors the pattern established by
# pkill-blast-guard-activate.sh (ga-tje7u).
#
# WHY THIS SET (ga-vrwo3 FURO 1 + FURO 2): the `gt tap guard
# dangerous-command` binary already knows how to block `git reset
# --hard`, `git clean -f`/`-fd`, `git push --force`/`-f` and `rm -rf /` --
# verified live, both exit 2. Package-manager/sudo matchers are a
# separate, broader finding (see ga-vrwo3 Mayor comment) and out of scope
# here.
#
# WHY "if", NOT "matcher": ga-vrwo3 (and this repo's entire existing hook
# config, including whatsapp_automation/crew's config this bead's own
# FURO 1 called "already correct") puts the command-pattern on the
# PreToolUse entry's "matcher" field, e.g.
# {"matcher": "Bash(git reset --hard*)", "hooks":[...]}. Verified live
# (nested Claude Code session, real PreToolUse hook dispatch, not just
# the guard binary in isolation) that this NEVER fires: Claude Code's
# "matcher" field matches the TOOL NAME only ("Bash" exactly), so a
# matcher value of "Bash(git reset --hard*)" never equals tool name
# "Bash" and the hook is silently dead. The command-pattern belongs on a
# per-hook "if" field instead: {"matcher": "Bash", "hooks":[{"type":
# "command", "command": ..., "if": "Bash(git reset --hard*)"}]} --
# confirmed live this selectively fires only for matching commands and
# leaves non-matching Bash calls untouched. This script writes the
# correct (matcher="Bash" + hooks[].if=pattern) shape. It does NOT touch
# any pre-existing matcher="Bash(pattern)" entries for OTHER guards
# (pr-workflow, cross-clone-block, patrol blockers, etc.) in the target
# files -- those have the same defect but are a separate, city-wide
# finding outside this bead's scope (see ga-vrwo3 follow-up escalation).
#
# MERGE SEMANTICS: a target settings.json is considered "already guarded"
# for a given pattern only if some matcher="Bash" PreToolUse entry has a
# hook whose "if" equals that pattern AND whose command contains the
# marker "guard dangerous-command". Only missing patterns are appended,
# as new hook objects inside the existing matcher="Bash" entry (creating
# one if none exists yet). Nothing already present is ever removed,
# replaced, or reordered.
#
# USAGE: dangerous-command-guard-activate.sh [path-to-settings.json ...]
#   With no args, targets the exact 4 files named in ga-vrwo3 FURO 1/2
#   (rooted at ${DANGEROUS_GUARD_RIGS_ROOT:-/Users/athos/gt}). With args,
#   targets exactly the paths given (used by the selftest against scratch
#   files, and for re-running against a single rig after a settings
#   reset). DANGEROUS_GUARD_RIGS_ROOT is deliberately its own variable,
#   NOT the ambient GT_ROOT -- GT_ROOT is already bound in agent sessions
#   to the HQ engine root (.gascity-gastown-hq), not the rigs umbrella
#   dir the default targets live under; reusing it here silently pointed
#   every default target at the wrong tree.
#   Idempotent -- safe to re-run, including against a file that already
#   has some/all of the patterns guarded.
set -euo pipefail

RIGS_ROOT="${DANGEROUS_GUARD_RIGS_ROOT:-/Users/athos/gt}"
GUARD_CMD="/Users/athos/.local/bin/gt tap guard dangerous-command"
MARKER="guard dangerous-command"

# Canonical set from ga-vrwo3 FURO 1 (git-destructive + rm-rf). Order
# matches whatsapp_automation/crew's matcher order (the "if" values are
# unchanged from that config's existing matcher strings -- only which
# JSON field carries them has changed).
PATTERNS=(
  "Bash(rm -rf /*)"
  "Bash(git push --force*)"
  "Bash(git push -f*)"
  "Bash(git reset --hard*)"
  "Bash(git clean -f*)"
  "Bash(git clean -fd*)"
)

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=(
    "$RIGS_ROOT/property_scrapers/crew/.claude/settings.json"
    "$RIGS_ROOT/lexbh/crew/.claude/settings.json"
    "$RIGS_ROOT/lexbh/witness/.claude/settings.json"
    "$RIGS_ROOT/lexbh/refinery/.claude/settings.json"
  )
fi

PATTERNS_JSON="$(printf '%s\n' "${PATTERNS[@]}" | jq -R . | jq -s .)"

STATUS=0
for SETTINGS in "${TARGETS[@]}"; do
  if [ ! -f "$SETTINGS" ]; then
    echo "FATAL: settings.json not found at $SETTINGS" >&2
    STATUS=1
    continue
  fi

  TMP="$(mktemp)"

  jq \
    --arg cmd "$GUARD_CMD" \
    --arg marker "$MARKER" \
    --argjson patterns "$PATTERNS_JSON" \
    '
    (.hooks //= {}) |
    (.hooks.PreToolUse //= []) |
    (
      [.hooks.PreToolUse[] | select(.matcher == "Bash") | (.hooks // [])[]
        | select((.command // "") | contains($marker)) | (.if // "")]
    ) as $already_guarded |
    ($patterns - $already_guarded) as $missing |
    ($missing | map({type: "command", command: $cmd, "if": .})) as $new_hooks |
    (if ($new_hooks | length) == 0 then
      .
    elif (.hooks.PreToolUse | any(.matcher == "Bash")) then
      .hooks.PreToolUse |= map(if .matcher == "Bash" then .hooks = ((.hooks // []) + $new_hooks) else . end)
    else
      .hooks.PreToolUse += [{matcher: "Bash", hooks: $new_hooks}]
    end) |
    # Cleanup: an old-style entry whose matcher is exactly one of our
    # canonical patterns (the pre-if-field convention this script
    # replaces) is now 100% superseded by the if-gated hook this same
    # pass just guaranteed exists -- Claude Code never matches tool name
    # "Bash" against a matcher value of "Bash(...)", so these entries
    # were always dead. Drop ONLY entries matching one of our exact
    # patterns AND pointing at dangerous-command; entries for any other
    # guard (pr-workflow, cross-clone-block, patrol blockers, etc.) are
    # untouched even though they have the same underlying defect -- that
    # is a separate, city-wide finding outside this script'\''s scope.
    .hooks.PreToolUse |= map(select(
      (.matcher as $m | ($patterns | index($m))) == null
      or ((.hooks // []) | any(((.command // "") | contains($marker)) | not))
    ))
    ' \
    "$SETTINGS" > "$TMP"

  # Validate before overwriting the real file -- never leave settings.json
  # truncated/corrupt if jq produced something unexpected.
  jq empty "$TMP"

  if cmp -s "$SETTINGS" "$TMP"; then
    echo "Already fully guarded: $SETTINGS"
    rm -f "$TMP"
    continue
  fi

  cp "$SETTINGS" "${SETTINGS}.bak.$(date +%s)" 2>/dev/null || true
  mv "$TMP" "$SETTINGS"
  echo "Registered dangerous-command if-gated hooks in $SETTINGS"
done

exit "$STATUS"
