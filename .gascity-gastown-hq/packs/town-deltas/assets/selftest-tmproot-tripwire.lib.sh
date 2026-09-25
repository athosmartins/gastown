#!/usr/bin/env bash
# selftest-tmproot-tripwire.lib.sh — SOURCED by selftests (never run on its own):
# a fail-closed tripwire that keeps a selftest fixture from running `git init` (or
# any other git write) against the shared OS temp root. wa-x02jx / ga-bdebb0.
#
# WHY THIS LIVES IN ITS OWN FILE and not inside the selftest that uses it: the
# quality gate's base-commit test check (quality-gate-guard.sh, ga-rstae, A/B arm B)
# runs every `*.selftest.sh` a branch adds or changes against the PRE-FIX base by
# overlaying the BRANCH's copy of that file onto a base checkout. A fix written
# inside a `*.selftest.sh` therefore travels onto the base together with its own
# test and always passes there ("passou-na-base" = proves nothing, blocks the
# marker). Kept here, under a name that is not `*.selftest.sh`, the fix is NOT
# carried over: on the base the selftest cannot find this file, refuses to start
# (see the `. "$_TRIPWIRE_LIB" || exit 2` guard in
# pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh) and the wrapper harness
# fails — for the honest reason that the fix is absent.
#
# Source with an explicit failure check; this file deliberately does not touch the
# caller's shell options (no `set`) and defines only functions:
#     . "$HERE/selftest-tmproot-tripwire.lib.sh" || { echo "FATAL: ..." >&2; exit 2; }

# _refuse_if_townroot_is_os_tmp <path> — fail-closed tripwire, called BEFORE any git
# op on TOWNROOT. Returns non-zero if <path> is empty, cannot be resolved (can't-tell
# is not "safe"), or resolves to an OS temp root ($TMPDIR, /tmp, /var/tmp, or the
# per-user Darwin temp dir); compared by physical path so a trailing slash or a
# /tmp -> /private/tmp symlink can't defeat it.
_refuse_if_townroot_is_os_tmp() {
  local root="${1:-}" root_p cand cand_p
  if [ -z "$root" ]; then
    echo "FATAL: TOWNROOT is empty — refusing to run git against it" >&2
    return 2
  fi
  root_p="$(cd "$root" 2>/dev/null && pwd -P)"
  if [ -z "$root_p" ]; then
    echo "FATAL: cannot resolve TOWNROOT '$root' — refusing to run git against it" >&2
    return 2
  fi
  for cand in "${TMPDIR:-}" /tmp /var/tmp "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"; do
    [ -n "$cand" ] || continue
    cand_p="$(cd "$cand" 2>/dev/null && pwd -P)" || continue
    [ -n "$cand_p" ] || continue
    if [ "$root_p" = "$cand_p" ]; then
      echo "FATAL: TOWNROOT '$root' IS the OS temp root ('$cand_p') — a git init here would poison every process that uses it (wa-x02jx)" >&2
      return 2
    fi
  done
  return 0
}
