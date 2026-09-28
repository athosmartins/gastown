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
#     (gascity internal/overlay/merge.go: hookEntryKey() keys an entry by its "matcher" string and
#     mergeHookArray() lets an overlay entry with the same key REPLACE the base entry in place --
#     read in the engine source, .local-patches/_src-hookfix, not just measured). A pool overlay
#     carrying matcher="Bash" would therefore wipe the
#     dangerous-command guards that live in a workdir's own Bash entry. "^Bash$" is a tool-name
#     regex (it still matches only the Bash tool) with an identity of its own: the overlay appends
#     it once, idempotently, and this script and the overlay converge on the very same entry.
#   * no command pattern in "matcher" (that never fires -- ga-7j1yu) and no "if": this guard's bash
#     prefilter already makes the no-op case nearly free, and an "if" glob could not see inside a
#     `for ... do ... done`.
#   * the command is fail-open three times over: it exits 0 when the guard file is gone (a checkout that
#     moved must not turn every Bash call of every crew into a hook error), home-scan-guard.sh
#     itself exits 0 on any failure of its own, and the command only lets the wrapper's own BLOCK verdict
#     through (rc 2 + marker on stderr) -- a wrapper that cannot even be parsed exits 0 too, counted.
#   * the guard path is the MAIN checkout, never a worktree: a hook that points into a worktree
#     dies when the worktree is cleaned up (same trap pkill-exec-guard-activate.sh documents).
#     Because the command is a no-op while that file does not exist, running this BEFORE the guard has
#     merged is harmless (it just starts biting when the file lands); running it after is the normal order.
#
# MERGE SEMANTICS: any hook whose command contains the marker "home-scan-guard" is OURS (the command
# carries it as a `: home-scan-guard;` no-op, so this never depends on the guard's path or file name).
# The FIRST ^Bash$ entry is the dedicated one and is converged IN PLACE: our hook there is replaced by the
# current command where it sat (appended when there was none), extra copies of ours are dropped, and every
# hook in it that is NOT ours stays exactly where it was (someone else may register under the same matcher).
# Every other entry loses only its hooks of ours (an older activation that folded it into a Bash entry, or a
# second ^Bash$ entry) and is dropped only if that left it empty. Nothing that is not ours is ever
# modified, replaced or reordered.
#
# THREE STATES, not two: "registered" is not "effective". The registered command is `[ -f "$P" ] || exit 0`,
# so a hook that points at a guard file which does not exist is a registered NO-OP. Reporting that as
# GUARDED would put the very word MERGED != LIVE warns about on a file that guards nothing, so the state
# is INERT (and --check exits 1 on it).
#
# USAGE: home-scan-guard-activate.sh [--check] [path-to-settings.json ...]
#   no paths : every crew / witness / refinery settings.json that exists under
#              ${HOME_SCAN_GUARD_RIGS_ROOT:-/Users/athos/gt}   (the four globs at the bottom of this file -- there is no
#              "worker" one: pool roles get the hook from their overlays, see pool-roles.json), PLUS the one city-root
#              ${HOME_SCAN_GUARD_CITY_SETTINGS:-/Users/athos/gt/.gascity-gastown-hq/.claude/settings.json} (ga-awsf9k).
#              THIS IS THE OVERRIDE INPUT, NOT THE DERIVED `.gc/settings.json` -- do not retarget this at
#              `.gc/settings.json` again, that was tried and reverted within under a minute (28/09, see the bead).
#              Read from gc's own source (internal/hooks/hooks.go desiredClaudeSettings/readClaudeSettingsOverride,
#              engine-window-0926 worktree, gastownhall/gascity#2109's neighborhood): on every reconcile tick, for
#              every workdir, gc rebuilds `.gc/settings.json` fresh as embedded-base MERGED with the highest-priority
#              override it finds, and the FIRST candidate it checks -- ahead of the legacy hook file and ahead of
#              `.gc/settings.json`'s own prior content -- is exactly `citylayout.ClaudeSettingsPath(cityDir)` ==
#              `<cityDir>/.claude/settings.json` (internal/citylayout/layout.go). That file already exists here
#              (created 26/09, carries remoteControlAtStartup/permissions.deny/env -- those three fields are proof
#              this override path is live and load-bearing: they show up in the merged `.gc/settings.json` and are
#              NOT in the embedded base). The merge itself (internal/overlay/merge.go MergeSettingsJSON) unions hook
#              categories and merges entries by matcher identity -- same shape home-scan-guard-activate.sh's own
#              JQ_APPLY below replicates for the crew/witness/refinery targets -- so writing our hook into THIS file
#              the same way is stable: every reconcile tick re-reads it and re-merges it into `.gc/settings.json`,
#              instead of `.gc/settings.json` being the thing edited (which that same tick then discards, since it
#              is the OUTPUT of the merge, not an input to it). Registering the hook here reaches every session that
#              is neither one of the four crew/witness/refinery globs nor a pool-role overlay: the Mayor, the deacon,
#              boot, auto-refiner, context-check-reviewer, the long-lived overlays, and any ephemeral WISP a named
#              crew spawns under a bare `<rig>/claude-headless` template (no [[patches.agent]] matches that name --
#              confirmed via `gc config explain`, "claude-headless" is synthesized per rig from [providers.claude-
#              headless] and is NOT a patchable agent identity, `patches.agent` on it errors "not found in merged
#              config" -- so overlay_dir is not an available fix here either). Confirmed 27/09 16:21: a wa-worker
#              wisp under this exact template ran `find / -maxdepth 6 -iname gate-done*` unblocked, see ga-awsf9k.
#              home-scan-guard.py's own "KNOWN GAPS" list (WHO IS GUARDED) predates this fix.
#              ALSO, if present:
#              ${HOME_SCAN_GUARD_POOL_BASE_SETTINGS:-/Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool/.claude/settings.json}
#              (ga-9bgxwi) -- the pool overlay BASE (pool-roles.json base_overlay), not a per-role overlay. Every
#              per-role overlay already carries this hook via a SEPARATE generator (pool-roles.json common.hooks +
#              pool-preamble-build.py), and CITY_SETTINGS above puts the identical entry in the root for every
#              session; overlay-root-leak-guard.py diffs role overlays against this base to find a role that leaked
#              to the root, so a hook present in every role but absent from the base leaf-matched all of them and
#              was misread as a leak (false positive, ga-9bgxwi). Converging it into the base too makes the guard's
#              own model agree that this leaf is universal, not role-specific -- closing the false positive instead
#              of teaching the guard a name-based exception.
#   --check  : write nothing; print GUARDED / INERT / NOT-GUARDED per target; exit 1 if any is not GUARDED
#   Idempotent. A target that cannot be processed (missing, unparseable) never stops the others;
#   the exit status is 1 if any failed.
set -uo pipefail

RIGS_ROOT="${HOME_SCAN_GUARD_RIGS_ROOT:-/Users/athos/gt}"
# Derived from RIGS_ROOT (not a bare absolute default): the real city root is $RIGS_ROOT/.gascity-gastown-hq, and
# keeping this relationship means a sandboxed RIGS_ROOT (the selftest's $SCRATCH/rigs) naturally sandboxes this
# target too -- it resolves to a path that does not exist there, so the `[ -f ]` guard below skips it, exactly
# like every other target this script has never seen. HOME_SCAN_GUARD_CITY_SETTINGS overrides independently.
# .claude/settings.json (NOT .gc/settings.json -- see the USAGE block above): the stable override input.
CITY_SETTINGS="${HOME_SCAN_GUARD_CITY_SETTINGS:-$RIGS_ROOT/.gascity-gastown-hq/.claude/settings.json}"
# ga-9bgxwi: the pool BASE overlay (pool-roles.json base_overlay) -- NOT a per-role overlay (those already carry
# this hook via pool-roles.json common.hooks + pool-preamble-build.py, a separate generator). overlay-root-leak-
# guard.py treats any leaf that is in a per-role overlay but NOT in the base as "a role leaked to the city root" --
# and CITY_SETTINGS above puts this exact hook entry in the root for EVERY session (root-resident or not), which
# happens to leaf-match every role overlay's copy of the same hook, so the guard misread deliberate, universal
# registration as a role-overlay leak (false positive, escalates to Athos after 4h). Converging the identical entry
# into the base too makes it universal in the guard's own model (no role's delta any more), closing the false
# positive at the source instead of teaching the guard a name-based exception. Registering it here (not by hand)
# keeps this and CITY_SETTINGS as the ONE place this hook's exact command is authored for both channels.
POOL_BASE_SETTINGS="${HOME_SCAN_GUARD_POOL_BASE_SETTINGS:-$RIGS_ROOT/.gascity-gastown-hq/packs/town-deltas/assets/claude-overlays/pool/.claude/settings.json}"
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
# The rest runs the wrapper and decides what Claude Code sees. It used to be `exec /bin/bash "$P"`, which handed bash's OWN
# exit status to Claude Code -- and bash exits 2 on a SYNTAX ERROR in the script (a file half-written by a checkout, a bad
# merge), 2 being exactly how a hook says BLOCK: a broken wrapper blocked every Bash call of every agent. Now only the wrapper's
# own verdict blocks (rc 2 AND its marker line "home-scan-guard: BLOCKED" first on stderr, the same test the wrapper applies
# to python); every other outcome is exit 0 and leaves an UNGUARDED line in the guard's log, so it is fail-open but counted.
# POSIX only (Claude Code may run it under sh, bash or zsh): pool-roles.json carries the same text, and case 9 of the
# selftest compares the two, case 11 runs it under all three shells.
HOOK_TAIL='[ -f "$P" ] || exit 0; e=$(/bin/bash "$P" 2>&1 >/dev/null); r=$?; case "$r:$e" in 2:"home-scan-guard: BLOCKED"*) printf "%s\n" "$e" >&2; exit 2;; 0:*) exit 0;; esac; L="${HOME_SCAN_GUARD_LOG:-${HOME:-/tmp}/.gastown/logs/home-scan-guard.log}"; mkdir -p "${L%/*}" 2>/dev/null; printf "%s\tresult=UNGUARDED\treason=hook wrapper exited %s without a block verdict\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$r" >> "$L" 2>/dev/null; exit 0'
HOOK_CMD=": ${MARKER}; P='${GUARD_PATH}'; ${HOOK_TAIL}"

CHECK=0
TARGETS=()
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,/^set -uo pipefail$/{/^set -uo pipefail$/!p;}' "$0"; exit 0 ;;   # the whole leading comment block, however long it grows
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
  # ga-awsf9k: the city-root .claude/settings.json -- the override gc merges into .gc/settings.json on
  # every reconcile tick, reaching every session in the city -- see the USAGE block above. Added only if
  # present: a city this script has never seen (different RIGS_ROOT, no city checkout there yet, or one
  # whose city root has no override file at all yet -- absence is not an error, it just means "nothing to
  # add hooks to here today") must not turn into a FATAL below.
  [ -f "$CITY_SETTINGS" ] && TARGETS+=("$CITY_SETTINGS")
  # ga-9bgxwi: the pool BASE overlay -- see POOL_BASE_SETTINGS above. Added only if present, same reasoning
  # as CITY_SETTINGS (a city/checkout this script has never seen must not turn into a FATAL below).
  [ -f "$POOL_BASE_SETTINGS" ] && TARGETS+=("$POOL_BASE_SETTINGS")
fi
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "FATAL: no settings.json targets found under $RIGS_ROOT" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 1; }

# The desired state, as ONE jq definition shared by activation and --check so they cannot drift.
JQ_APPLY='
  def ours: ((.command // "") | contains($marker));
  (.hooks //= {}) | (.hooks.PreToolUse //= []) |
  ({type: "command", command: $cmd, timeout: $timeout}) as $hook |
  ([.hooks.PreToolUse | to_entries[] | select(.value.matcher == $m) | .key][0]) as $first |
  .hooks.PreToolUse |= [to_entries[]
      | .key as $i | .value as $e
      | if $i == $first then
          # the dedicated entry: hooks that are not ours stay where they were, ours is replaced IN PLACE by the
          # current command (extra copies dropped), and it is appended when there was none
          ((($e.hooks // []) | map(ours)) | index(true)) as $pos
          | (if $pos == null then (($e.hooks // []) + [$hook])
             else ($e.hooks | to_entries
                   | map(select((.value | ours | not) or (.key == $pos)))
                   | map(if (.value | ours) then $hook else .value end))
             end) as $hs
          | ($e | .hooks = $hs)
        else
          # any other entry: pull ours out; drop the entry only if that left it empty -- an entry that held
          # none of ours is never touched
          ((($e.hooks // []) | map(select(ours))) | length) as $n
          | if $n == 0 then $e
            else (($e.hooks | map(select(ours | not))) as $keep
                  | if ($keep | length) == 0 then empty else ($e | .hooks = $keep) end)
            end
        end] |
  (if $first == null then (.hooks.PreToolUse += [{matcher: $m, hooks: [$hook]}]) else . end)'

# "Registered" is not "effective": the hook command is a no-op while the guard file is missing (see THREE STATES).
guard_present() { [ -f "$GUARD_PATH" ]; }
INERT_NOTE="hook registered, but $GUARD_PATH does not exist -- the hook is a no-op until it does"

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
    if guard_present; then
      echo "GUARDED: $SETTINGS"
    else
      echo "INERT: $SETTINGS ($INERT_NOTE)"
      [ "$CHECK" -eq 1 ] && STATUS=1
    fi
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
    if guard_present; then echo "Registered home-scan-guard hook in $SETTINGS"
    else echo "Registered home-scan-guard hook in $SETTINGS -- INERT: $GUARD_PATH does not exist yet, the hook is a no-op until it does"; fi
  else
    echo "FATAL: could not write $SETTINGS (original left as it was; backup at $BAK)" >&2
    rm -f "$NEW"
    STATUS=1
  fi
  rm -f "$TMP"
done

exit "$STATUS"
