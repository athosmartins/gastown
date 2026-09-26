#!/usr/bin/env bash
# home-scan-guard.sh (ga-02cqk4) -- PreToolUse:Bash hook. Refuses (exit 2) a Bash command that
# ENUMERATES, MEASURES or READS RECURSIVELY $HOME or a macOS-protected folder, in Gas Town agent
# sessions. Everything else -- and every failure of this script -- is exit 0 (FAIL-OPEN: a guard
# that breaks every Bash call of every agent is worse than the problem it fixes).
#
# WHY: ga-6cyp1l (26/09 14:52). A crew session ran
#   cd /Users/athos && for d in $(ls -A); do ...; timeout 60 du -xsk "$d" ...; done
# and four `du` calls hit Desktop/Documents/Downloads/Photos in ~1s. macOS TCC blames every file
# access of an agent session on gc (the supervisor is the "responsible" process), which is the
# "gc wants to access ..." prompt Athos sees, and which a headless session blocks on or is denied
# in silence. The doctrine already said "no wide traversals" but only named `find`; prose does not
# restrict a tool (ga-1udgm). This is the mechanical guard.
#
# TWO STAGES, because this runs on EVERY Bash call of every agent and python3 starts in 100-280ms
# at the city's load (40-60 on 10 cores; ga-y0g5x: a detector's poll cost IS load):
#   1. here, in bash + one jq: identity gate, then a cheap SUPERSET filter (a scan-tool word AND a
#      $HOME / protected-folder token, or a cwd that is itself $HOME / protected). Nearly every
#      command ends here with exit 0 and no python.
#   2. home-scan-guard.py: the exact lexical classifier, under a hard timeout. Only rc==2 blocks.
# The filter must never be narrower than the classifier (it would silently disable a block);
# home-scan-guard.selftest.sh runs the whole must-block corpus THROUGH this file to prove it.
#
# WIRING (why it is not just a settings.json line). Two facts about Claude Code hook config bit this
# bead, and both are pinned by selftests:
#   * a command-pattern in "matcher" NEVER fires (ga-7j1yu; it belongs in a hook's "if"). This guard
#     needs no pattern at all -- the bash prefilter above already makes the no-op case free, and an
#     "if" glob could not see inside `for ... do ... done` -- so it is registered by TOOL NAME only.
#   * the engine merges pool overlays into a workdir's settings.json BY MATCHER IDENTITY (gascity
#     internal/overlay/merge.go hookEntryKey): an overlay entry with matcher="Bash" REPLACES the
#     workdir's own Bash entry -- measured: it drops the dangerous-command hooks 2 -> 0. So the guard
#     lives in its own entry, matcher "^Bash$" (a tool-name regex: still only the Bash tool), which
#     the engine appends once and idempotently.
# See home-scan-guard-activate.sh (crews) and pool-roles.json / pool-preamble-build.py (pools);
# both write the identical entry (home-scan-guard-activate.selftest.sh, case 9, compares them).
# Every failure to run is exit 0, but a failure of the CLASSIFIER ITSELF is written to the log as
# ENGINE-ERROR (a guard that fails open on its own bug is silently off), and the selftest asserts
# its cases produced none.
#
# WHO is guarded: only processes whose environment carries a Gas Town identity (GC_AGENT,
# GC_ALIAS, GC_DIR, GC_SESSION_NAME, GC_SESSION_ID). Athos's own terminal in a crew directory has
# none of them and passes untouched -- same runtime-identity test as pkill-exec-guard.sh.
#
# Test seams (env): HOME_SCAN_GUARD_HOME (what ~ / $HOME mean), HOME_SCAN_GUARD_LOG,
# HOME_SCAN_GUARD_PY (classifier interpreter), HOME_SCAN_GUARD_TIMEOUT (seconds, default 5).
set -u

# A guard that quietly stops guarding is worse than none: every way the wrapper can NOT run the classifier
# (helper missing, classifier gone/crashing/hung) is a fail-open -- but a COUNTED one. The normal quiet exits (not an
# agent session, not a Bash call, nothing that looks like a scan) are not degradations and log nothing.
note() {   # note <result> <reason>
  local log="${HOME_SCAN_GUARD_LOG:-${HOME:-/tmp}/.gastown/logs/home-scan-guard.log}"
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s\tagent=%s\tresult=%s\treason=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${GC_AGENT:-${GC_ALIAS:-${GC_SESSION_NAME:-none}}}" "$1" "$2" >> "$log" 2>/dev/null || true
}

# ---- 0. identity gate ---------------------------------------------------------------------
if [ -z "${GC_AGENT:-}${GC_ALIAS:-}${GC_DIR:-}${GC_SESSION_NAME:-}${GC_SESSION_ID:-}" ]; then
  exit 0
fi

# ---- 1. read + extract (jq: one spawn) ----------------------------------------------------
input="$(cat 2>/dev/null)" || exit 0
[ -n "$input" ] || exit 0
command -v jq >/dev/null 2>&1 || { note UNGUARDED "jq not found on PATH"; exit 0; }

tool=""; cmd=""; cwd=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' cmd
  IFS= read -r -d '' cwd
} < <(printf '%s' "$input" | jq -j '
    (if type == "object" then . else {} end)
    | (.tool_name | if type == "string" then . else "" end), "\u0000",
      (.tool_input.command? | if type == "string" then . else "" end), "\u0000",
      (.cwd | if type == "string" then . else "" end), "\u0000"' 2>/dev/null)

[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# ---- 2. cheap superset prefilter ----------------------------------------------------------
home="${HOME_SCAN_GUARD_HOME:-${HOME:-}}"
home="${home%/}"
case "$home" in /*/*) ;; *) exit 0 ;; esac        # no usable home: nothing to classify

# a tool that can scan (or a wrapper/interpreter that can hide one -- those still put the scan
# tool's name in the text, so the raw text is a superset of every wrapped form)
tool_re='(^|[^[:alnum:]_.-])(du|find|gfind|gdu|dust|tree|ncdu|fd|fdfind|rg|ripgrep|ag|ack|grep|egrep|fgrep|zgrep|ggrep|ls|gls|eza|exa|lsd|mdfind|rsync|ditto|tar|gtar|zip|cp|gcp|scp|xargs)($|[^[:alnum:]_-])'
[[ $cmd =~ $tool_re ]] || exit 0

home_esc="${home//./\\.}"
after='($|[^[:alnum:]_./~-]|/($|[*?[{$"'"'"'`/]|\.($|[[:space:]"'"'"'/;|&)])|\.\.|\.\*|\.\[|\.[Tt]rash|[DdPpMmLl]))'
hot_re="(^|[^[:alnum:]_./~-])(~|\\\$HOME|\\\$\\{HOME|${home_esc})${after}"
vol_re='/Volumes'
dots_re='\.\.'                                       # /Users/athos/gt/../Downloads
bare_cd_re='(^|[;&|({[:space:]])(cd|pushd)[[:space:]]*($|[;&|)`])'   # cd with no operand = $HOME
# / and /Users are ANCESTORS of $HOME: `find / -name x` walks straight into it
anc_re='(^|[[:space:]"'"'"'=(])(/|/Users/?)($|[[:space:]"'"'"')*;|&])'      # bare / or /Users
anc_glob_re='(^|[[:space:]"'"'"'=(])/Users/([*?[{$]|[^[:space:]/]*[*?[{$])'   # /Users/*, /Users/*/Downloads, /Users/at*

hot=0
if   [[ $cmd =~ $hot_re ]];     then hot=1
elif [[ $cmd == *"$vol_re"* ]]; then hot=1
elif [[ $cmd =~ $dots_re ]];    then hot=1
elif [[ $cmd =~ $bare_cd_re ]]; then hot=1
elif [[ $cmd =~ $anc_re ]];     then hot=1
elif [[ $cmd =~ $anc_glob_re ]]; then hot=1
else
  case "$cwd" in
    "$home"|"$home"/[DdPpMmLl.]*|/Volumes|/Volumes/*|/|/Users) hot=1 ;;
  esac
fi
[ "$hot" -eq 1 ] || exit 0

# ---- 3. exact classifier, under a hard timeout --------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
ENGINE="$HERE/home-scan-guard.py"
[ -f "$ENGINE" ] || { note UNGUARDED "classifier missing: $ENGINE"; exit 0; }
PY="${HOME_SCAN_GUARD_PY:-$(command -v python3 2>/dev/null)}"
{ [ -n "$PY" ] && [ -x "$PY" ]; } || { note UNGUARDED "no python3 interpreter"; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/home-scan-guard.XXXXXX" 2>/dev/null)" || { note UNGUARDED "mktemp failed"; exit 0; }
trap 'rm -rf "$tmp"' EXIT
printf '%s' "$input" > "$tmp/in" 2>/dev/null || { note UNGUARDED "could not stage the hook input"; exit 0; }

"$PY" -I -S "$ENGINE" < "$tmp/in" > "$tmp/out" 2> "$tmp/err" &
pid=$!
( sleep "${HOME_SCAN_GUARD_TIMEOUT:-5}"; kill -9 "$pid" ) >/dev/null 2>&1 &
watchdog=$!
wait "$pid" 2>/dev/null
rc=$?
kill "$watchdog" >/dev/null 2>&1
wait "$watchdog" >/dev/null 2>&1

# rc==2 is also what python itself exits with on a usage error, so rc alone is not proof of a block:
# require the classifier's own marker on the first line of stderr (fail-open on anything else)
if [ "$rc" -eq 2 ] && [ "$(head -c 24 "$tmp/err" 2>/dev/null)" = "home-scan-guard: BLOCKED" ]; then
  cat "$tmp/err" >&2
  exit 2
fi
case "$rc" in
  0) ;;                                                                    # the classifier's own "allow"
  137|143) note UNGUARDED "classifier timed out after ${HOME_SCAN_GUARD_TIMEOUT:-5}s and was killed" ;;
  *) note UNGUARDED "classifier exited $rc without a block verdict" ;;
esac
exit 0
