#!/usr/bin/env bash
# selftest-sandbox-path.lib.sh — SOURCED by selftests (never run on its own): gives the script
# under test a PATH on which the REAL `gc` / `bd` do not exist, so a stub that disappears can
# never turn into the real command. ga-d21b40.
#
# WHAT WENT WRONG (29/09 16:31Z): a selftest ran the script under test with
# PATH="$T/bin:$PATH", `$T/bin/gc` being a stub that logs the call. The harness died mid-run and
# its scratch dir $T went away (stub included) while the script under test lived on. With the stub
# gone, `command -v gc` walked on down $PATH and found /opt/homebrew/bin/gc — the REAL one — and
# reaper.sh's `gc mail send mayor/` went out for real: two "ESCALATION: Reaper anomalies" mails to
# the Mayor whose bodies quoted selftest scratch paths.
#
# A stub earlier in PATH is a promise the stub keeps only while the file exists. The fix makes the
# promise structural: the child's PATH holds ONLY (1) the stub dir, (2) a dir of symlinks to the few
# harmless tools the script needs and (3) the system dirs. Remove $T and the child has no `gc` at
# all — "command not found" is the inert outcome (a `|| true` swallows it, a `command -v` guard
# skips the block), never a call on the real town.
#
# WHY NOT "kill the child in the harness's EXIT trap" (measured, macOS /bin/bash 3.2): while a
# foreground `$(...)` child runs, SIGTERM and SIGHUP end the harness WITHOUT running its EXIT trap and
# the child survives. A trap is not a guarantee there, so nothing here leans on one; whoever removes
# $T (a dying harness, a scratch sweeper, a person) the PATH answer is the same.
#
# WHY THIS LIVES IN ITS OWN FILE and not inside the selftests that use it: the quality gate's
# base-commit test check (quality-gate-guard.sh, ga-rstae, A/B arm B) overlays the BRANCH's copy of
# every changed `*.selftest.sh` onto a PRE-FIX base. A fix written inside a `*.selftest.sh` travels
# onto the base with its own test and always passes there. Kept here, under a name that is not
# `*.selftest.sh`, it does not travel: on the base the selftest cannot find this file, refuses to
# start (`. "$HERE/selftest-sandbox-path.lib.sh" || exit 2`) and the check fails for the honest
# reason. (Same reason as selftest-tmproot-tripwire.lib.sh.)
#
# Source with an explicit failure check; this file does not touch the caller's shell options (no
# `set`) and only defines a function:
#     . "$HERE/selftest-sandbox-path.lib.sh" || { echo "FATAL: ..." >&2; exit 2; }
#
#   sandbox_path_init <T> <tool>...   after `T` and `$T/bin` exist. Symlinks each <tool> (resolved
#                                     from the CALLER's PATH) into $T/tools and sets SANDBOX_PATH.
#                                     Returns non-zero — refuse to run — if it cannot make the
#                                     sandbox provably free of a real gc/bd.

# Commands that act on the town (mail, sling, close, nudge). They must only ever be stubs, so they
# cannot be requested as a "harmless tool" and must not exist on the system dirs either.
_SANDBOX_TOWN_TOOLS="gc bd"
_SANDBOX_SYSTEM_DIRS="/usr/bin:/bin:/usr/sbin:/sbin"

sandbox_path_init() {
  local T="${1:-}" tool src town
  [ -n "$T" ] && [ -d "$T/bin" ] || { echo "FATAL: sandbox_path_init: '$T/bin' does not exist (create the stub dir first)" >&2; return 2; }
  shift
  mkdir -p "$T/tools" || return 2
  for tool in "$@"; do
    for town in $_SANDBOX_TOWN_TOOLS; do
      [ "$tool" = "$town" ] && { echo "FATAL: sandbox_path_init: '$tool' acts on the town — it must be a stub in \$T/bin, never linked to the real one" >&2; return 2; }
    done
    src="$(command -v "$tool" 2>/dev/null)" && [ -x "$src" ] || { echo "FATAL: sandbox_path_init: required tool '$tool' not found" >&2; return 2; }
    ln -sf "$src" "$T/tools/$tool" || return 2
  done
  SANDBOX_PATH="$T/bin:$T/tools:$_SANDBOX_SYSTEM_DIRS"
  # Prove the property instead of assuming it: with the stub dir and the link dir REMOVED from the
  # PATH, no town tool may resolve. If /usr/bin ever grows a real `gc`, the sandbox is not one.
  for town in $_SANDBOX_TOWN_TOOLS; do
    if PATH="$_SANDBOX_SYSTEM_DIRS" command -v "$town" >/dev/null 2>&1; then
      echo "FATAL: sandbox_path_init: a real '$town' resolves on $_SANDBOX_SYSTEM_DIRS — the sandbox cannot exclude it" >&2
      return 2
    fi
  done
  return 0
}
