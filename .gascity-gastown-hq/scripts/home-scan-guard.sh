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
# The filter must be a SUPERSET of the classifier: a shape the classifier blocks and the filter passes is a block
# silently switched off. home-scan-guard.selftest.sh checks it two ways -- every classifier BLOCK of the spec corpus
# and of the structural sweeps is run through THIS file's own prefilter code (cut out of the file, one bash process,
# a non-hot cwd; ~25k cases at the time of writing, 0 misses), and a sample goes end to end through bash + jq + python.
# That is a measurement of the shapes tried, not a proof for every spelling: a new classifier rule needs its filter rule.
# The classifier compares paths case-insensitively and normalises them (//, /./, ..), so the filter does
# the same to ITS copy of the text: nocasematch, and // and /./ collapsed before any pattern runs. A token boundary is any
# character that cannot continue a path name (a backtick, `{`, `,` end a token as well as a space does).
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
# Every failure to run is exit 0 and is COUNTED in the log: a wrapper that cannot run the classifier writes
# UNGUARDED, a classifier that fails on its own bug writes ENGINE-ERROR (a guard that fails open on its
# own bug is silently off), and the selftest asserts its cases produced neither. The log is best effort:
# if its directory cannot be created or written, the count is lost too (the block itself never depends on it).
#
# WHO is guarded: only processes whose environment carries a Gas Town identity (GC_AGENT,
# GC_ALIAS, GC_DIR, GC_SESSION_NAME, GC_SESSION_ID). Athos's own terminal in a crew directory has
# none of them and passes untouched -- same runtime-identity test as pkill-exec-guard.sh.
#
# Test seams (env): HOME_SCAN_GUARD_HOME (what ~ / $HOME mean), HOME_SCAN_GUARD_LOG,
# HOME_SCAN_GUARD_PY (classifier interpreter), HOME_SCAN_GUARD_TIMEOUT (seconds, default 5).
set -u

# A guard that quietly stops guarding is worse than none: every way the wrapper can NOT do its job is a fail-open --
# but a COUNTED one (UNGUARDED): a hook payload that is empty or that jq rejects, jq or python or the classifier missing,
# a classifier that crashes or hangs, no usable $HOME for a command that looks like a scan, no scratch dir. The NORMAL
# quiet exits (not an agent session, not a Bash call, nothing that looks like a scan) are not degradations and log nothing.
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
[ -n "$input" ] || { note UNGUARDED "hook input was empty"; exit 0; }
command -v jq >/dev/null 2>&1 || { note UNGUARDED "jq not found on PATH"; exit 0; }

# The last record is a sentinel: jq prints it only after it has parsed the payload, so "jq rejected the input"
# (tool="" cmd="" ...) cannot be mistaken for "a payload that is not a Bash call".
tool=""; cmd=""; cwd=""; jq_ok=""
{
  IFS= read -r -d '' tool
  IFS= read -r -d '' cmd
  IFS= read -r -d '' cwd
  IFS= read -r -d '' jq_ok
} < <(printf '%s' "$input" | jq -j '
    (if type == "object" then . else {} end)
    | (.tool_name | if type == "string" then . else "" end), "\u0000",
      (.tool_input.command? | if type == "string" then . else "" end), "\u0000",
      (.cwd | if type == "string" then . else "" end), "\u0000",
      "ok", "\u0000"' 2>/dev/null)

[ "$jq_ok" = "ok" ] || { note UNGUARDED "hook input is not parseable JSON (jq rejected it)"; exit 0; }
[ "$tool" = "Bash" ] || exit 0
[ -n "$cmd" ] || exit 0

# ---- 2. cheap superset prefilter ----------------------------------------------------------
# The classifier reads paths the way the (case-insensitive) macOS volume does and normalises them, so the filter
# matches a NORMALISED, case-folded copy: /users/ATHOS/./Desktop, //Users/athos and /Users//athos are all $HOME.
shopt -s nocasematch
cmd_n="$cmd"; prev=""
while [ "$prev" != "$cmd_n" ]; do
  prev="$cmd_n"
  cmd_n="${cmd_n//\/\///}"
  cmd_n="${cmd_n//\/.\///}"
done

# a tool that can scan. A wrapper (sudo, nice, caffeinate ...) or a `bash -c '...'` string still puts the tool's name
# in the text, so the text is a superset of every wrapped form; the quote-stripped copy below covers d""u, \du, 'du'.
tool_re='(^|[^[:alnum:]_.-])(du|find|gfind|gdu|dust|tree|ncdu|fd|fdfind|rg|ripgrep|ag|ack|grep|egrep|fgrep|zgrep|ggrep|ls|gls|eza|exa|lsd|mdfind|rsync|ditto|tar|gtar|bsdtar|zip|cp|gcp|scp|xargs|rm|mv|gmv|chmod|chown|chflags|xattr)($|[^[:alnum:]_-])'
# The shell joins d""u, \du, 'du' into du and /Us""ers/athos into /Users/athos: every test below reads the text AND a copy with the quoting
# removed (pure bash, no spawn), so a quote in the middle of a name cannot hide it from the filter.
cmd_q="${cmd_n//\"/}"; cmd_q="${cmd_q//\'/}"; cmd_q="${cmd_q//\\/}"
[[ $cmd_n =~ $tool_re ]] || [[ $cmd_q =~ $tool_re ]] || exit 0

# only now: a command that looks like a scan needs a home to be classified against
home="${HOME_SCAN_GUARD_HOME:-${HOME:-}}"
home="${home%/}"
case "$home" in /*/*) ;; *) note UNGUARDED "no usable home (HOME_SCAN_GUARD_HOME/HOME = '$home'): cannot tell what is protected"; exit 0 ;; esac

# $HOME goes into a regex: escape EVERY metacharacter (a home with a + ( [ in it made an invalid or wrong pattern)
home_esc="${home//\\/\\\\}"
for ch in "." "*" "+" "?" "(" ")" "[" "]" "{" "}" "^" "\$" "|"; do home_esc="${home_esc//"$ch"/\\$ch}"; done
after='($|[^[:alnum:]_./~-]|/($|[[:space:];|&)]|[*?[{$"'"'"'`/\\]|\.($|[[:space:]"'"'"'/;|&)])|\.\.|\.\*|\.\[|\.[Tt]rash|[DdPpMmLl]))'
# the token before a path is a boundary -- or an option cluster the path is ATTACHED to (tar -C/Users/athos, -xzC$HOME),
# which is a value the classifier reads and the old boundary (a non-alphanumeric) hid. `~` may carry a name: ~athos/Desktop is
# $HOME/Desktop, ~+ / ~- are $PWD / $OLDPWD (a superset: `~foo` reaches the classifier too, which is free to say no)
hot_re="(^|[^[:alnum:]_./~-]|-[[:alpha:]]+)(~[[:alnum:]_.+-]*|\\\$HOME|\\\$\\{HOME|${home_esc})${after}"
vol_re='/Volumes'
dots_re='\.\.'                                       # /Users/athos/gt/../Downloads
bare_cd_re='(^|[;&|({[:space:]])(cd|pushd)[[:space:]]*($|[;&|)`])'   # cd with no operand = $HOME
back_cd_re='(^|[;&|({[:space:]])(cd[[:space:]]+-|popd)($|[[:space:]]|[;&|)`])'   # cd - / popd: the previous dir may be a hot one
# / and /Users are ANCESTORS of $HOME: `find / -name x` walks straight into it
# (a token boundary is ANY character that cannot continue a path name: a backtick, `{`, `,`, `:` ... end a token as well as a space does)
anc_re='(^|[^[:alnum:]_./~-]|-[[:alpha:]]+)(/|/Users/?)($|[^[:alnum:]_./~-])'      # bare / or /Users
anc_glob_re='(^|[^[:alnum:]_./~-]|-[[:alpha:]]+)/Users/([*?[{$]|[^[:space:]/]*[*?[{$])'   # /Users/*, /Users/*/Downloads, /Users/at*
# /U*/athos, /Us?rs, /[U]sers, /{Users,x}/..., /Vol*, /V?lumes/x: the FIRST component of an absolute path holds a glob, class, brace or
# backslash, so it can still name /Users or /Volumes. The classifier reads those; a filter that only knew the literal names let them
# through in silence (the selftest runs these WITH a cwd -- with none, every command goes to the classifier and the filter is never used).
abs_glob_re='(^|[^[:alnum:]_./~-]|-[[:alpha:]]+)/[^[:space:]/]*[*?[{\\][^[:space:]/]*($|/|[^[:alnum:]_./~-])'
# a word can chain several {a,b} groups after a SAFE-looking name (~/gt{a,b}{a,b}{a,b}...): the classifier's own cap
# (MAX_ALTERNATIVES) treats that as "could be anything" once the count multiplies past it, regardless of what any single
# alternative spells -- this filter cannot count alternatives cheaply, so it treats 3+ brace groups anywhere in a command
# that also mentions ~/$HOME/the literal home as hot outright (coarse and deliberately over-inclusive: python decides the real verdict)
chained_brace_re='\{[^{}]*\}.*\{[^{}]*\}.*\{[^{}]*\}'

# `[[ =~ ]]` returns 2 for a pattern it cannot compile: that is "don't know", never "not hot" -- hand it to the classifier
text_is_hot() {   # $1 = one copy of the command text; 0 = hot
  local t="$1" r
  [[ $t =~ $hot_re ]]; r=$?; [ "$r" -ne 1 ] && return 0
  [[ $t == *"$vol_re"* ]] && return 0
  [[ $t =~ $dots_re ]] && return 0
  [[ $t =~ $bare_cd_re ]] && return 0
  [[ $t =~ $back_cd_re ]] && return 0
  [[ $t =~ $anc_re ]] && return 0
  [[ $t =~ $anc_glob_re ]] && return 0
  [[ $t =~ $abs_glob_re ]] && return 0
  { [[ $t =~ $chained_brace_re ]] && [[ $t == *'~'* || $t == *'$HOME'* || $t == *"$home"* ]]; } && return 0
  return 1
}
hot=0
if text_is_hot "$cmd_n" || { [ "$cmd_q" != "$cmd_n" ] && text_is_hot "$cmd_q"; }; then
  hot=1
else
  # An empty cwd is "don't know", not "not hot": a relative scan (`for d in $(ls -A); do du -sk "$d"; done`) cannot be judged
  # here, so it goes to the classifier, which counts it (UNKNOWN-CWD). Claude Code always sends a cwd; this is the payload that
  # does not, and it must not be the one that walks past the guard unlogged.
  case "$cwd" in
    ""|"$home"|"$home"/[DdPpMmLl.]*|/Volumes|/Volumes/*|/|/Users) hot=1 ;;
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
# Job-control notices ("Terminated: 15 ( sleep ... )", "Killed: 9") are written by the SHELL itself when it reaps a
# background job, so redirecting `wait`'s own stderr does not catch them: measured, ~5% of ALLOWED commands leaked one
# to the hook's stderr under macOS bash 3.2. The watchdog is disowned (it is never waited for -- it is only killed) and the
# wait runs in a group whose stderr is discarded.
disown "$watchdog" 2>/dev/null
{ wait "$pid"; rc=$?; } 2>/dev/null
kill "$watchdog" >/dev/null 2>&1

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
