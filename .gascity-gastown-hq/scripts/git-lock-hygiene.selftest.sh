#!/usr/bin/env bash
# git-lock-hygiene.selftest.sh — standalone regression harness for imp18
# Delegates to the --selftest flag built into git-lock-hygiene.sh.
# Exit 0 = pass.
#
# ga-d8zeli: also proves that selftest is HERMETIC with respect to the city log.
# The script's own --selftest fires real removed/would_remove events through
# _log_json, which appends to $LOG — by default the LIVE sweeps log,
# $GC_CITY_PATH/.gc/logs/git-lock-hygiene.jsonl. Measured 2026-09-20: 746 of the
# 36791 lines in that live log were selftest fixtures (paths under
# git-lock-hygiene-selftest.*). So run it inside a throwaway city and fail if it
# wrote anything there. GIT_LOCK_LOG is unset for the child on purpose: the
# default log path is the one under test, and an inherited override would hide
# a leak.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

SBX_CITY="$(mktemp -d "${TMPDIR:-/tmp}/git-lock-hygiene-selftest-city.XXXXXX")"
trap 'rm -rf "$SBX_CITY" "${LIB_SBX:-}"' EXIT
mkdir -p "$SBX_CITY/.gc/logs"   # _log_json's append fails silently when this is missing

rc=0
env -u GIT_LOCK_LOG GC_CITY_PATH="$SBX_CITY" bash "$SCRIPT_DIR/git-lock-hygiene.sh" --selftest "$@" || rc=$?

city_log="$SBX_CITY/.gc/logs/git-lock-hygiene.jsonl"
if [ -s "$city_log" ]; then
  echo "FAIL hermetic: --selftest appended $(wc -l < "$city_log" | tr -d ' ') line(s) to the city log (\$LOG default) — against the live city that is the production log:" >&2
  head -2 "$city_log" | cut -c1-200 >&2
  rc=1
else
  echo "  ok  hermetic: --selftest wrote nothing to the city log"
fi

# ── ga-kimlod: LIB MODE MUST BE PURE ──────────────────────────────────────────
# `GIT_LOCK_HYGIENE_LIB=1 source git-lock-hygiene.sh` means "load the mutex functions, skip the
# sweep" (header). quality-gate-dispatcher.sh sources it on EVERY cycle (StartInterval=60). Before
# this fix the top-level rig-roots block ran BEFORE the lib-mode `return`: it shelled out to
# `gc rig list` (bounded at 20 s, at the moment Dolt is busiest) and, when that failed, called
# notify — whose STDOUT ("Logged for digest ...") leaked into whatever sourced the file. Measured
# 25/09: the line preceded the sourcer's own output in 50 of 120 runs at load ~50, and it broke
# gate-verdict-timeout-scale.selftest.sh (ga-5hw36b).
# A FAKE gc that fails and counts, and a fake notify that counts and prints, make the impurity
# observable; the sandbox city carries the REAL lib/rig-stores.sh because the block is only
# reachable when that file is readable. Run under BOTH shells: 3.2 (/bin/bash, the gate's) and
# whatever `bash` is first in PATH.
LIB_SBX="$(mktemp -d "${TMPDIR:-/tmp}/git-lock-hygiene-libmode.XXXXXX")"
mkdir -p "$LIB_SBX/city/scripts/lib" "$LIB_SBX/city/.gc/logs" "$LIB_SBX/bin" "$LIB_SBX/repo"
ln -s "$SCRIPT_DIR/lib/rig-stores.sh" "$LIB_SBX/city/scripts/lib/rig-stores.sh"
cat > "$LIB_SBX/bin/gc" <<'FAKE'
#!/bin/sh
echo "$*" >> "$LIB_SBX/gc.calls"
exit 1
FAKE
cat > "$LIB_SBX/bin/notify" <<'FAKE'
#!/bin/sh
echo "$*" >> "$LIB_SBX/notify.calls"
echo "Logged for digest (infra mirror off): Git-lock hygiene"
exit 0
FAKE
chmod +x "$LIB_SBX/bin/gc" "$LIB_SBX/bin/notify"
export LIB_SBX

_lm_reset() { : > "$LIB_SBX/gc.calls"; : > "$LIB_SBX/notify.calls"; : > "$LIB_SBX/city/.gc/logs/git-lock-hygiene.jsonl"; }
_lm_env() {   # a sourcer that does NOT pre-set GIT_LOCK_RIG_ROOTS (the case the block used to handle)
  env -u GIT_LOCK_RIG_ROOTS -u GIT_LOCK_LOG GC_CITY_PATH="$LIB_SBX/city" GIT_LOCK_GC="$LIB_SBX/bin/gc" \
      NOTIFY_BIN="$LIB_SBX/bin/notify" GIT_REPO_MUTEX_BASE="$LIB_SBX/mutex" "$@"
}
_lm_count() { local n; n="$(grep -c . "$1" 2>/dev/null || true)"; echo "${n:-0}"; }

for _lm_shell in /bin/bash bash; do
  _lm_reset
  _lm_out="$LIB_SBX/out.$$"; _lm_err="$LIB_SBX/err.$$"
  _lm_env GIT_LOCK_HYGIENE_LIB=1 "$_lm_shell" -c '
    source "$1"
    echo LIB_LOADED
    git_mutex_acquire "$2" && git_mutex_release "$2" && echo MUTEX_OK
  ' _ "$SCRIPT_DIR/git-lock-hygiene.sh" "$LIB_SBX/repo" >"$_lm_out" 2>"$_lm_err" || true
  _lm_label="lib mode [$_lm_shell $("$_lm_shell" -c 'echo ${BASH_VERSION%%(*}')]"
  if [ "$(cat "$_lm_out")" = "$(printf 'LIB_LOADED\nMUTEX_OK')" ]; then
    echo "  ok  $_lm_label: stdout is exactly the sourcer's own output (nothing leaked) and the mutex API still works"
  else
    echo "FAIL $_lm_label: stdout polluted or lib broken: [$(tr '\n' '|' < "$_lm_out")]" >&2; rc=1
  fi
  if [ "$(_lm_count "$LIB_SBX/gc.calls")" = "0" ]; then
    echo "  ok  $_lm_label: 0 calls to gc (no 'gc rig list' on every source)"
  else
    echo "FAIL $_lm_label: sourcing called gc $(_lm_count "$LIB_SBX/gc.calls")x: $(head -1 "$LIB_SBX/gc.calls")" >&2; rc=1
  fi
  if [ "$(_lm_count "$LIB_SBX/notify.calls")" = "0" ]; then
    echo "  ok  $_lm_label: 0 calls to notify"
  else
    echo "FAIL $_lm_label: sourcing called notify $(_lm_count "$LIB_SBX/notify.calls")x" >&2; rc=1
  fi
  if [ ! -s "$LIB_SBX/city/.gc/logs/git-lock-hygiene.jsonl" ]; then
    echo "  ok  $_lm_label: nothing written to the hygiene log"
  else
    echo "FAIL $_lm_label: sourcing wrote to the hygiene log: $(head -c 160 "$LIB_SBX/city/.gc/logs/git-lock-hygiene.jsonl")" >&2; rc=1
  fi
done

# Control: the SWEEP path (no lib flag) must keep resolving the live rig list — the fix must not
# have turned that off. GIT_LOCK_ENABLED=0 exits at the top of the sweep, so nothing is scanned
# or removed; the block still runs first, so the fake gc is called and its failure is reported.
_lm_reset
_lm_env GIT_LOCK_ENABLED=0 bash "$SCRIPT_DIR/git-lock-hygiene.sh" >/dev/null 2>&1 || true
if [ "$(_lm_count "$LIB_SBX/gc.calls")" -ge 1 ] && [ "$(_lm_count "$LIB_SBX/notify.calls")" -ge 1 ]; then
  echo "  ok  control: the sweep still resolves rig roots from 'gc rig list' and still reports a failure (gc x$(_lm_count "$LIB_SBX/gc.calls"), notify x$(_lm_count "$LIB_SBX/notify.calls"))"
else
  echo "FAIL control: the sweep no longer resolves rig roots (gc x$(_lm_count "$LIB_SBX/gc.calls"), notify x$(_lm_count "$LIB_SBX/notify.calls")) — the lib-mode fix disabled the real sweep" >&2; rc=1
fi
# Control: a sourcer that pre-sets GIT_LOCK_RIG_ROOTS (git-deploy-pull.sh) is left alone in sweep mode too.
_lm_reset
env -u GIT_LOCK_LOG GIT_LOCK_RIG_ROOTS="$LIB_SBX/repo" GC_CITY_PATH="$LIB_SBX/city" GIT_LOCK_GC="$LIB_SBX/bin/gc" \
    NOTIFY_BIN="$LIB_SBX/bin/notify" GIT_LOCK_ENABLED=0 bash "$SCRIPT_DIR/git-lock-hygiene.sh" >/dev/null 2>&1 || true
if [ "$(_lm_count "$LIB_SBX/gc.calls")" = "0" ]; then
  echo "  ok  control: a caller-set GIT_LOCK_RIG_ROOTS still skips the gc call (ga-wz03iq seam intact)"
else
  echo "FAIL control: caller-set GIT_LOCK_RIG_ROOTS no longer skips gc" >&2; rc=1
fi
exit "$rc"
