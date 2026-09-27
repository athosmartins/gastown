#!/usr/bin/env bash
# home-scan-guard.selftest.sh (ga-02cqk4) -- hermetic tests for home-scan-guard.sh
# (+ home-scan-guard.py). The guard is purely lexical (it never touches a path the command mentions),
# and neither does this file -- every command below is only ever handed to the guard as TEXT inside a
# hook-input JSON, never executed. (The one exception is the opt-in LIVE section at the end: a real
# nested `claude -p` whose ~ is redirected to a scratch fake home, so it can only ever walk scratch dirs.)
#
# WHY THIS EXISTS: a crew session ran `cd /Users/athos && for d in $(ls -A); do ...
# du -xsk "$d" ...; done` and four `du` calls hit Desktop/Documents/Downloads/Photos in
# ~1s. macOS TCC blames that on gc (the supervisor is the "responsible" process of every
# agent session) -> the "gc wants to access ..." prompt (ga-6cyp1l).
#
# HOW THE FILE IS ORGANISED -- read this before adding a case:
#   1. the incident, then a SPEC corpus (must-BLOCK / must-ALLOW) that was written before the guard existed;
#   2. ACCEPTED FALSE POSITIVES and KNOWN GAPS, pinned so nobody "fixes" one by re-adding a heuristic without
#      reading why the guard is small (see the engine's header: rounds 1-4 of the gate each found one more
#      instance of the same class in a design that read option tables and tracked stdin; round 5 removed the design);
#   3. STRUCTURAL SWEEPS (run in-process against the engine): they do not list more examples, they LOCK THE FORM.
#      Insert any option, any wrapper, any pipe consumer around a hot target -- BLOCK must stay BLOCK. A fifth
#      "one more spelling" case is not a test of the class; a sweep that fails when the form regresses is;
#   4. fail-open / cost / the engine never failed open on its own bug / LIVE dispatch.
#
# TEST: bash home-scan-guard.selftest.sh
#       HOME_SCAN_GUARD_LIVE=1 bash home-scan-guard.selftest.sh   # also proves REAL hook
#                                                                 # dispatch via a nested `claude -p`
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/home-scan-guard.sh"
ENGINE="$HERE/home-scan-guard.py"
# The installed hook runs `/bin/bash "$P"` (home-scan-guard-activate.sh): macOS bash 3.2, not the newer bash
# this file is probably running under. The wrapper has to be exercised under exactly that shell.
HOOK_BASH=/bin/bash
[ -x "$HOOK_BASH" ] || HOOK_BASH="$(command -v bash)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
LOG="$SCRATCH/guard.log"

# The guard resolves ~ / $HOME against this (lexically), so the corpus can use the literal
# /Users/athos on any machine.
export HOME_SCAN_GUARD_HOME=/Users/athos
export HOME_SCAN_GUARD_LOG="$LOG"
AGENT_ENV=(GC_AGENT=selftest-agent)

# hook_json <command> [cwd]  -> the PreToolUse JSON Claude Code sends on stdin.
hook_json() {
  jq -cn --arg c "$1" --arg w "${2-}" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", tool_input:{command:$c}} + (if $w == "" then {} else {cwd:$w} end)'
}

# run_guard <command> [cwd]  -> sets RC and ERR
run_guard() {
  ERR="$(hook_json "$1" "${2-}" | env "${AGENT_ENV[@]}" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"
  RC=$?
}

expect_block() {  # name command [cwd]
  printf '%s\0%s\0' "$2" "${3-}" >> "$SCRATCH/spec-blocks.bin"     # kept for the prefilter differential below
  run_guard "$2" "${3-}"
  if [ "$RC" -eq 2 ] && [[ "$ERR" == *TCC* ]]; then ok "BLOCK  $1"
  else bad "BLOCK  $1 -- expected rc=2 + TCC message, got rc=$RC err=[${ERR:0:160}] cmd=[$2] cwd=[${3-}]"; fi
}
expect_allow() {  # name command [cwd]
  run_guard "$2" "${3-}"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "ALLOW  $1"
  else bad "ALLOW  $1 -- expected rc=0 + silent, got rc=$RC err=[${ERR:0:160}] cmd=[$2] cwd=[${3-}]"; fi
}

if [ ! -f "$GUARD" ] || [ ! -f "$ENGINE" ]; then
  echo "FATAL: guard or engine not found next to this file ($GUARD, $ENGINE)"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
echo "-- the incident (ga-6cyp1l, 26/09 14:52), verbatim --"
# ─────────────────────────────────────────────────────────────────────────
INCIDENT='cd /Users/athos && for d in $(ls -A); do [ "$d" = "Library" ] && continue; timeout 60 du -xsk "$d" 2>/dev/null; done | sort -rn | head -25'
expect_block "incident command exactly as run by the batista crew" "$INCIDENT"
expect_block "incident, from a repo cwd (the real one: cd is what moves it to \$HOME)" "$INCIDENT" /Users/athos/gt
run_guard "$INCIDENT"
if [[ "$ERR" == *"df -h /"* && "$ERR" == *"disk-growth"* && "$ERR" == *"du -xsk"* ]]; then
  ok "message names the alternatives (df -h /, disk-growth logs, du -xsk on explicit roots)"
else
  bad "message must name the alternatives, got [$ERR]"
fi
[ -s "$LOG" ] && grep -q "BLOCKED" "$LOG" && ok "block is logged" || bad "block not logged: $(cat "$LOG" 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- must BLOCK: measure / enumerate / recurse over \$HOME or a protected folder --"
# ─────────────────────────────────────────────────────────────────────────
# du
expect_block "du ~"                        'du -sk ~'
expect_block "du \$HOME"                   'du -xsk $HOME'
expect_block "du \${HOME}"                 'du -xsk ${HOME}'
expect_block "du /Users/athos"             'du -sh /Users/athos'
expect_block "du /Users/athos/"            'du -sh /Users/athos/'
expect_block "du ~/*"                      'du -sk ~/*'
expect_block "du /Users/athos/*"           'du -sk /Users/athos/*'
expect_block "du \$HOME/*"                 'du -sk "$HOME"/*'
expect_block "du ~/Desktop"                'du -sk ~/Desktop'
expect_block "du ~/Documents/sub"          'du -sk ~/Documents/sub'
expect_block "du ~/Downloads"              'du -sk ~/Downloads'
expect_block "du ~/Pictures"               'du -sk ~/Pictures'
expect_block "du ~/Movies"                 'du -sk ~/Movies'
expect_block "du ~/Music"                  'du -sk ~/Music'
expect_block "du quoted \$HOME/Downloads"  'du -sk "$HOME/Downloads"'
expect_block "du Mobile Documents (quoted)" 'du -sk "$HOME/Library/Mobile Documents"'
expect_block "du Mobile Documents (escaped)" 'du -sk ~/Library/Mobile\ Documents'
expect_block "du CloudStorage"             'du -sk ~/Library/CloudStorage'
expect_block "du ~/Library (whole)"        'du -sk ~/Library'
expect_block "du /Volumes"                 'du -sk /Volumes'
expect_block "du /Volumes/x"               'du -sk /Volumes/Backup'
expect_block "du mixed safe+hot operands"  'du -sk ~/gt ~/Downloads'
expect_block "du path trick via .."        'du -sk /Users/athos/gt/../Downloads'
expect_block "du path trick via ~/gt/../.."  'du -sk ~/gt/..'
expect_block "du -d 1 (numeric option value) with cwd=\$HOME" 'du -d 1 -h' /Users/athos
# find
expect_block "find ~"                      'find ~ -maxdepth 1'
expect_block "find \$HOME"                 'find $HOME -name foo'
expect_block "find /Users/athos"           'find /Users/athos -type f'
expect_block "find ~/Downloads"            "find ~/Downloads -name '*.pdf'"
expect_block "find /Volumes"               'find /Volumes -maxdepth 2'
expect_block "find CloudStorage"           'find ~/Library/CloudStorage -type f'
expect_block "find Mobile Documents"       'find "$HOME/Library/Mobile Documents" -type f'
expect_block "find (abs path binary)"      '/usr/bin/find ~ -maxdepth 1'
# ls
expect_block "ls -R ~"                     'ls -R ~'
expect_block "ls -laR ~/Documents"         'ls -laR ~/Documents'
expect_block "ls ~/Downloads"              'ls ~/Downloads'
expect_block "ls ~/Downloads/*"            'ls ~/Downloads/*'
expect_block "ls -A ~/Desktop"             'ls -A ~/Desktop'
expect_block "ls /Volumes"                 'ls /Volumes'
expect_block "ls CloudStorage"             'ls ~/Library/CloudStorage'
expect_block "ls ~/* (each entry is listed)" 'ls ~/*'
expect_block "ls -la ~/.Trash"             'ls -la ~/.Trash'
# other scanners
expect_block "tree ~"                      'tree -L 2 ~'
expect_block "ncdu ~"                      'ncdu ~'
expect_block "fd pat ~"                    'fd foo ~'
expect_block "rg pat ~"                    'rg foo ~'
expect_block "rg pat ~/Documents"          'rg -n foo ~/Documents'
expect_block "grep -r ~"                   'grep -r foo ~'
expect_block "grep -rn ~/Downloads"        'grep -rn foo ~/Downloads'
expect_block "grep -R /Users/athos"        'grep -R foo /Users/athos'
expect_block "grep --recursive"            'grep --recursive foo ~/Documents'
expect_block "mdfind -onlyin ~"            'mdfind -onlyin ~ foo'
expect_block "mdfind -onlyin Downloads"    'mdfind -onlyin ~/Downloads foo'
expect_block "rsync ~/Documents"           'rsync -a ~/Documents /tmp/x'
expect_block "rsync ~/Documents/ trailing" 'rsync -a ~/Documents/ /tmp/x/'
expect_block "tar ~/Documents"             'tar czf /tmp/x.tgz ~/Documents'
expect_block "tar -C ~"                    'tar czf /tmp/x.tgz -C ~ .'
expect_block "zip -r ~/Downloads"          'zip -r /tmp/x.zip ~/Downloads'
expect_block "cp -R ~/Documents"           'cp -R ~/Documents /tmp/x'
expect_block "cp -r ~/Downloads/dir"       'cp -r ~/Downloads/dir /tmp/y'
expect_block "cp -a \$HOME"                'cp -a $HOME /tmp/y'
expect_block "ditto ~/Documents"           'ditto ~/Documents /tmp/x'
# adversarial review (round 5): a POSIX bracket class ([[:upper:]]) is a glob that matches Desktop/Documents/... too, and must
# not be fed raw to Python's re (which warns "nested set" on stderr -- a warning there would break the WRAPPER's own marker
# check, since it reads only the first line of stderr looking for "home-scan-guard: BLOCKED")
expect_block "du ~/[[:upper:]]* (POSIX bracket class matches Desktop/Documents/...)" 'du -sk ~/[[:upper:]]*'
expect_block "du ~/[[:upper:]]* ~ (same warning-triggering glob, plus a plain \$HOME operand)" 'du -sk ~/[[:upper:]]* ~'
# a tool name held in a plain tracked variable is the tool it names, exactly as real bash resolves it
expect_block "T=du; \$T -sk ~ (a variable IS the command word)" 'T=du; $T -sk ~'
expect_block "cmd=du; \${cmd} -sk ~"          'cmd=du; ${cmd} -sk ~'
expect_block "T=du; \$T -sk ~/Downloads"      'T=du; $T -sk ~/Downloads'
# rm/mv/chmod/chown/xattr readdir() the whole tree too -- the same TCC trigger, even though they modify rather than read
expect_block "rm -rf ~/Downloads"           'rm -rf ~/Downloads'
expect_block "rm -R ~/Documents"            'rm -R ~/Documents'
expect_block "mv ~/Documents (no flag needed)" 'mv ~/Documents /tmp/x'
expect_block "mv ONE named file INTO Downloads (accepted false positive: text can't tell same-volume rename from cross-volume copy)" 'mv /tmp/report.pdf ~/Downloads/'
expect_block "mv ONE named file OUT of Downloads"  'mv ~/Downloads/report.pdf /tmp/x'
expect_block "chmod -R ~/Documents"         'chmod -R 755 ~/Documents'
expect_block "chown -R ~/Documents"         'chown -R me ~/Documents'
expect_block "chflags -R ~/Downloads"       'chflags -R nouchg ~/Downloads'
expect_block "xattr -r ~/Downloads"         'xattr -r -d com.apple.quarantine ~/Downloads'
expect_block "bsdtar ~"                     'bsdtar -cf /tmp/x.tar ~'
# cd into it, then scan relative to it (the incident's own shape)
expect_block "cd ~ && du *"                'cd ~ && du -sk *'
expect_block "cd ~; find ."                'cd ~; find . -name x'
expect_block "cd \$HOME && for d in *"     'cd $HOME && for d in *; do du -sk "$d"; done'
expect_block "cd /Users/athos && ls -A | while read" 'cd /Users/athos && ls -A | while read d; do du -sk "$d"; done'
expect_block "cd ~ (bare) then du ."       'cd; du -sk .'
expect_block "cd ~/Downloads && find ."    'cd ~/Downloads && find .'
expect_block "pushd ~ then du ."           'pushd ~ >/dev/null; du -sk .'
expect_block "subshell (cd ~ && du .)"     '(cd ~ && du -sk .)'
expect_block "cd ~ && du (no operand)"     'cd ~ && du -sk'
expect_block "cd ~ && du (no operand), initial cwd is a SAFE repo dir (every tracked cwd is checked, not just the first)" 'cd ~ && du -sk' /Users/athos/gt
expect_block "cd ~ && rg pat (no path)"    'cd ~ && rg foo'
expect_block "cd ~ && grep -r pat ."       'cd ~ && grep -r foo .'
expect_block "cd .. && du * (from a repo dir up to \$HOME)" 'cd .. && du -sk *' /Users/athos/gt
expect_block "du ../.. (relative up to \$HOME)" 'du -sk ../..' /Users/athos/gt/foo
# a listing of $HOME that feeds a measurement, whatever the plumbing
expect_block "ls ~ | while read: du ~/\$d" 'ls ~ | while read d; do du -sk ~/"$d"; done'
expect_block "ls ~ | while read: du \$d"   'ls ~ | while read d; do du -sk "$d"; done'
expect_block "du \$(ls ~)"                 'du -sk $(ls ~)'
expect_block "du \$(ls -A /Users/athos)"   'du -sk $(ls -A /Users/athos)'
expect_block "du backtick ls ~"            'du -sk `ls ~`'
expect_block "for d in ~/*; du \$d"        'for d in ~/*; do du -sk "$d"; done'
expect_block "for d in \$(ls ~); du ~/\$d" 'for d in $(ls ~); do du -sk ~/$d; done'
expect_block "ls ~ | xargs du"             'ls ~ | xargs du -sk'
expect_block "find ~ -maxdepth 1 | xargs du" 'find ~ -maxdepth 1 | xargs du -sk'
expect_block "a glob over \$HOME carried by a command that is not a producer, feeding du" 'stat -f %N ~/* | xargs du -sk' /Users/athos/gt
expect_block "basename of a home glob, measured" 'basename -a ~/* | xargs -I{} du -sk {}' /Users/athos/gt
expect_block "the incident with ls in the loop (each entry LISTED)" 'cd ~ && for d in *; do ls -la "$d"; done'
expect_block "for d in \$(ls ~); ls of each entry" 'for d in $(ls ~); do ls -la ~/"$d"; done' /Users/athos/gt
expect_block "ls ~ | xargs ls (each entry listed)" 'ls ~ | xargs ls -la' /Users/athos/gt
expect_block "ls ~ | xargs -I{} sh -c 'ls {}'" "ls ~ | xargs -I{} sh -c 'ls -la {}'" /Users/athos/gt
expect_block "taint via a variable holding a home listing"  'L=$(ls ~); for d in $L; do du -sk "$d"; done' /Users/athos/gt
expect_block "taint via for-list ~/*, cwd elsewhere"        'for d in ~/*; do du -sk "$d"; done' /Users/athos/gt
# wrappers, shells, variables, structure
expect_block "timeout 60 du ~"             'timeout 60 du -xsk ~'
expect_block "nice du ~"                   'nice -n 10 du -sk ~'
expect_block "env VAR=1 du ~"              'env FOO=1 du -sk ~'
expect_block "time du ~"                   'time du -sk ~'
expect_block "bash -c 'du ~'"              "bash -c 'du -sk ~'"
expect_block "sh -c \"find ~\""            'sh -c "find ~ -maxdepth 1"'
expect_block "zsh -lc"                     "zsh -lc 'du -sk ~/Downloads'"
expect_block "eval du ~"                   "eval 'du -sk ~'"
expect_block "bash -c with \$HOME in double quotes" 'bash -c "du -sk $HOME"'
expect_block "var alias H=\$HOME; du \$H"  'H=$HOME; du -sk $H'
expect_block "var to Downloads"            'D=~/Downloads; find "$D" -type f'
expect_block "for d in <hot dir>; du \$d"  'for d in ~/Downloads/*; do du -sk "$d"; done'
expect_block "brace group"                 '{ du -sk ~; }'
expect_block "if/then body"                'if true; then du -sk ~; fi'
expect_block "pipe stage 2"                'echo x | du -sk ~'
expect_block "after && "                   'true && du -sk ~/Documents'
expect_block "after || "                   'false || du -sk ~/Documents'
expect_block "later line of multi-line"    $'echo start\ndu -sk ~\necho end'
expect_block "after a heredoc terminator"  $'cat <<EOF\nhello\nEOF\ndu -sk ~'
expect_block "command substitution in echo" 'echo "size: $(du -sk ~)"'
# / and /Users are ANCESTORS of $HOME: a recursive scan from there walks straight into it
expect_block "find / -name"                  'find / -name foo 2>/dev/null'
expect_block "find /Users"                   'find /Users -name foo'
expect_block "find / -maxdepth 3 (reaches ~/Desktop)" 'find / -maxdepth 3 -name foo'
expect_block "du -sk /Users"                 'du -sk /Users'
expect_block "du -d 1 -h / (depth limits the printout, not the walk)" 'du -d 1 -h /'
expect_block "find / -maxdepth \$N (a limit the text does not show is no limit)" 'find / -maxdepth $N -name x'
expect_block "find / -maxdepth \$N -maxdepth 1 (one unreadable value makes the WHOLE thing unlimited, even with a small one alongside)" 'find / -maxdepth $N -maxdepth 1 -name x'
expect_block "find / -maxdepth 1 -maxdepth 6 (the tools disagree which occurrence wins: the largest counts)" 'find / -maxdepth 1 -maxdepth 6 -name x'
expect_block "rg pat /"                      'rg foo /'
expect_block "grep -r pat /Users"            'grep -r foo /Users'
expect_block "ls -R /Users"                  'ls -R /Users'
# a glob / unknown component under /Users expands to $HOME (or a folder in it)
expect_block "du /Users/*"                   'du -sk /Users/*'
expect_block "du /Users/*/Downloads"         'du -sk /Users/*/Downloads'
expect_block "ls /Users/*/Desktop"           'ls -la /Users/*/Desktop'
expect_block "du /Users/at* (glob matches \$HOME)" 'du -sk /Users/at*'
expect_block "find /Users/\$u/Documents (unknown user)" 'find /Users/$u/Documents -name x'
expect_block "du /U*/athos (glob in the first component)" 'du -sk /U*/athos'
expect_block "du /[U]sers/athos/Desktop"     'du -sk /[U]sers/athos/Desktop'
expect_block "du /System/Volumes/Data/Users/athos (firmlink to \$HOME)" 'du -sk /System/Volumes/Data/Users/athos'
# spellings of $HOME that only NORMALISE to it
expect_block "find ~/."                      'find ~/. -name x'
expect_block "du ~//"                        'du -sk ~//'
expect_block "du ~/./"                       'du -sk ~/./'
expect_block "du //Users//athos"             'du -sk //Users//athos'
expect_block "du ~athos/Desktop"             'du -sk ~athos/Desktop'
# names are case-insensitive on the default macOS volume
expect_block "du ~/downloads (lowercase)"    'du -sk ~/downloads'
expect_block "du ~/DOCUMENTS"                'du -sk ~/DOCUMENTS'
expect_block "du ~/library/cloudstorage"     'du -sk ~/library/cloudstorage'
# brace / glob expansion under $HOME
expect_block "du ~/{gt,Downloads}"           'du -sk ~/{gt,Downloads}'
# a brace expression past MAX_ALTERNATIVES (64) is "could be anything" (a hit), not a pass -- even when every alternative it
# COULD show is safe: chained groups multiply (7 x {a,b} = 128), a single group with >64 comma items does not (see the ALLOW
# control below: the single-group case only blocks when a protected NAME happens to be among its fully-expanded alternatives)
expect_block "7 chained {a,b} groups (128 alternatives) under \$HOME" 'du -sk ~/gt{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}'
expect_allow "6 chained {a,b} groups (64, at the cap, not over) under a repo dir" 'du -sk ~/gt{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}'
expect_block "du ~/D* (matches Documents)"   'du -sk ~/D*'
expect_block "du ~/.* (hidden entries incl .Trash)" 'du -sk ~/.*'
expect_block "du Photos library (a dir with an extension)" 'du -sk ~/Pictures/Photos\ Library.photoslibrary'
expect_block "du Group Containers"           'du -sk ~/Library/Group\ Containers'
expect_block "du \$'...' (ANSI-C quoting, plain text)" "du -sk \$'/Users/athos/Desktop'"
# the Drive / iCloud mounts are network-backed: ANY listing under them can prompt or hang the session (ga-khuz1)
expect_block "ls a Google Drive folder under CloudStorage (seen in the wild)" 'timeout 15 ls "/Users/athos/Library/CloudStorage/GoogleDrive-x@example.com/My Drive" | head -3'
expect_block "ls -la ~/Library/CloudStorage/"  'ls -la ~/Library/CloudStorage/'
expect_block "ls an iCloud Drive folder"       'ls ~/Library/Mobile\ Documents/com~apple~CloudDocs'
# recursion without a flag, and a cwd spelled as a variable
expect_block "git grep --no-index over a protected folder" 'git grep --no-index foo ~/Downloads'
expect_block "the real GNU idiom for git-grep-style recursion: --directories recurse (space form)" 'grep --directories recurse foo /Users/athos'
expect_block "du \"\$PWD/..\" from a repo dir (= \$HOME)" 'du -sk "$PWD/.."' /Users/athos/gt
expect_block "cd \$HOME then a recursive grep with no path (seen in the wild)" "cd /Users/athos && timeout 120 grep -rIln --include='*.sh' -E 'Group Containers|Library/Containers' --exclude-dir=venv"
# implicit cwd taken from the hook JSON
expect_block "find . with cwd=\$HOME"        'find . -name x'               /Users/athos
expect_block "du (no operand) cwd=Downloads" 'du -sk'                        /Users/athos/Downloads
expect_block "rg pat cwd=Documents"          'rg foo'                        /Users/athos/Documents
expect_block "grep -r pat . cwd=\$HOME"      'grep -r foo .'                 /Users/athos
expect_block "du * cwd=\$HOME"               'du -sk *'                      /Users/athos
expect_block "ls -R cwd=Desktop"             'ls -R'                         /Users/athos/Desktop
expect_block "ls (plain) cwd=Downloads (a listing OF the protected folder)" 'ls -la' /Users/athos/Downloads
expect_block "for d in * cwd=\$HOME"         'for d in *; do du -sk "$d"; done' /Users/athos
# a launched scan inside a quoted string, and a scan whose text is split by quoting
expect_block "d\"\"u (quote-split tool name)" 'd""u -sk ~/Downloads'
expect_block "\\du (backslash before the tool name)" '\du -sk ~/Downloads'
expect_block "DU (macOS resolves names case-insensitively)" 'DU -sk ~/Downloads'
expect_block "abs path to du"                '/usr/bin/du -sk ~/Downloads'
expect_block "a scan 30 levels deep in \$( )" "echo $(printf '$(true %.0s' $(seq 1 30))du -sk ~/Downloads$(printf ')%.0s' $(seq 1 30))"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- must ALLOW: the bead's explicit list, and everything an agent does all day --"
# ─────────────────────────────────────────────────────────────────────────
# the bead's DEVE PERMITIR
expect_allow "du -xsk ~/gt"                          'du -xsk ~/gt'
expect_allow "du -xsk ~/.gastown"                    'du -xsk ~/.gastown'
expect_allow "du -xsk scratchpad"                    'du -xsk /private/tmp/claude-501/-Users-athos-gt/abc/scratchpad'
expect_allow "du explicit roots list"                'du -xsk ~/gt ~/.gastown ~/.local /private/tmp/claude-501'
expect_allow "du -sk /Users/athos/gt/.gascity-gastown-hq" 'du -sk /Users/athos/gt/.gascity-gastown-hq'
expect_allow "du gt/../.gastown (normalises to a safe root)" 'du -sk /Users/athos/gt/../.gastown'
expect_allow "df -h /"                               'df -h /'
expect_allow "df / and du of a non-home root (the guard's own advice, in one command)" 'df -h / && du -xsk /private/tmp/claude-501'
expect_allow "read the disk-growth logs"             'cat /Users/athos/gt/.gascity-gastown-hq/.gc/logs/disk-growth-20260926.txt'
expect_allow "a POSIX bracket class confined to a repo dir"  'du -sk /Users/athos/gt/[[:upper:]]*'
expect_allow "a variable holding a SAFE command, resolved the same way"  'T=du; $T -sk ~/gt'
expect_allow "an unresolved variable as the command word (known gap: dynamic, not tracked)" 'T=$1; $T -sk ~'
# the destructive family, confined to a repo dir (must NOT start blocking ordinary use)
expect_allow "rm -f ONE named file in Downloads"     'rm -f ~/Downloads/x.txt'
expect_allow "rm -rf a repo build dir"               'rm -rf ~/gt/build'
expect_allow "chmod (no -R) a repo script"           'chmod 755 ~/gt/script.sh'
expect_allow "chmod -R a repo build dir"             'chmod -R 755 ~/gt/build'
expect_allow "chown -R a repo build dir"             'chown -R me ~/gt/build'
expect_allow "mv a repo dir"                         'mv ~/gt/docs /tmp/x'
expect_allow "xattr -r a repo build dir"             'xattr -r -d com.apple.quarantine ~/gt/build'
expect_allow "bsdtar of a repo dir"                  'bsdtar -cf /tmp/x.tar ~/gt'
# cp/tar/zip/rsync/rm/mv/chmod/chown/xattr/chflags always need an explicit operand (or do nothing): the ancestor-cwd rule
# (which has NO exemption for du/find/grep-family, on purpose) does not apply to them -- rule A already reads their operand.
# The idiom that surfaced this (real corpus command): cd / ; ... ; rm -rf "$T" -- a temp-dir cleanup, not a scan of /.
expect_allow "cd / then cp -r of two explicit safe paths (cp has no implicit-cwd mode)" 'cd / && cp -r /tmp/a /tmp/b'
expect_allow "cd / then tar of an explicit safe path"          'cd / && tar czf /tmp/x.tgz /tmp/a'
expect_allow "cd / then zip -r of an explicit safe path"       'cd / && zip -r /tmp/x.zip /tmp/a'
expect_allow "cd / then rsync of two explicit safe paths"      'cd / && rsync -a /tmp/a/ /tmp/b/'
expect_allow "cd / then rm -rf of an explicit safe path (the corpus idiom)" 'cd / && rm -rf /tmp/a'
expect_allow "the corpus idiom verbatim: cd \$T then cleanup from /"  'T=$(mktemp -d); cd "$T" && echo hi; cd /; rm -rf "$T"'
expect_block "cd / then du of an explicit safe path (du DOES have an implicit-cwd mode: no exemption, by design)" 'cd / && du -sk /tmp/a'
expect_block "cd / then find of an explicit safe path (same: find is implicit-cwd, no exemption)" 'cd / && find /tmp/a -name x'
expect_allow "read ONE file in Downloads (cat)"      'cat ~/Downloads/relatorio.pdf'
expect_allow "read ONE file in Downloads (pdftotext)" 'pdftotext ~/Downloads/x.pdf -'
expect_allow "read ONE file in Downloads (head)"     'head -5 ~/Downloads/x.csv'
expect_allow "read ONE file in Downloads (file)"     'file ~/Downloads/x.png'
expect_allow "read ONE file in Downloads (stat)"     'stat -f %z ~/Downloads/x.zip'
expect_allow "copy ONE file out of Downloads"        'cp ~/Downloads/x.pdf /tmp/x.pdf'
expect_allow "ls one named file in Downloads"        'ls -l ~/Downloads/x.pdf'
expect_allow "ls one file on the Desktop"            'ls -la ~/Desktop/x.txt'
expect_allow "grep one named file in Downloads"      'grep -n foo ~/Downloads/x.txt'
# gate round 6: a search PATTERN or a filename that happens to spell a scanner's name is not the scanner (mv/find/du never
# ran; grep did, and grep alone does not recurse) -- only the word ACTUALLY in command position names the program.
expect_allow "grep pattern spelled 'mv' (the incident's exact repro)" 'grep -n mv ~/Downloads/onefile.txt'
expect_allow "grep pattern spelled 'find'"           'grep "find" ~/Downloads/onefile.txt'
expect_allow "grep pattern spelled 'du'"             'grep "du" ~/Downloads/onefile.txt'
expect_allow "grep pattern spelled 'rm'"             'grep -n rm ~/Downloads/onefile.txt'
expect_allow "grep pattern spelled 'tar'"            'grep -n tar ~/Downloads/onefile.txt'
expect_allow "a file NAMED like a tool, not a command run on it" 'grep -n foo ~/Downloads/mv'
expect_allow "'git' as the search pattern (after grep, not before) does not turn on git-grep recursion" 'grep -n git ~/Downloads/onefile.txt'
expect_allow "'recurse' as the search pattern is not the --directories value" 'grep -n recurse ~/Downloads/onefile.txt'
expect_allow "two scanner-spelled words in one segment: only the first (du) is the command" 'du find ~/gt'
expect_allow "tar -tf an archive in Downloads"       'tar -tf ~/Downloads/a.tar'
expect_allow "tar xf an archive in Downloads into /tmp" 'tar xf ~/Downloads/a.tar -C /tmp/x'
# everyday repo / city work
expect_allow "find inside the repo (abs)"            "find /Users/athos/gt -name '*.sh' -maxdepth 4"
expect_allow "find inside the repo (~)"              "find ~/gt/.gascity-gastown-hq/scripts -name '*.sh'"
expect_allow "find . in a repo cwd"                  'find . -name x'                     /Users/athos/gt/whatsapp_automation
expect_allow "rg in a repo cwd"                      'rg foo'                             /Users/athos/gt/whatsapp_automation
expect_allow "rg with path in repo"                  'rg -n foo /Users/athos/gt/.gascity-gastown-hq/scripts'
expect_allow "grep -r in repo"                       'grep -rn foo /Users/athos/gt/.gascity-gastown-hq/scripts'
expect_allow "grep one file in ~"                    'grep foo ~/.zshrc'
expect_allow "ls the home dir itself (not recursive)" 'ls ~'
expect_allow "ls -A the home dir itself"             'ls -A ~'
expect_allow "a plain ls with the cwd at \$HOME (a listing of \$HOME is not a scan; recursion is)" 'ls -la' /Users/athos
expect_allow "ls -la ~/.gastown/logs"                'ls -la ~/.gastown/logs'
expect_allow "ls ~/gt"                               'ls ~/gt'
expect_allow "ls -R inside the repo"                 'ls -R /Users/athos/gt/.gascity-gastown-hq/scripts'
expect_allow "tree in repo subdir"                   'tree -L 2 /Users/athos/gt/docs'
expect_allow "cd into repo then find/du"             'cd /Users/athos/gt && find . -name x && du -sk *'
expect_allow "cd ~/gt then du *"                     'cd ~/gt && du -sk *'
expect_allow "for over named repo dirs"              'for f in a b; do du -sk ~/gt/$f; done'
expect_allow "for over ls of repo"                   'for d in $(ls /Users/athos/gt); do du -sk /Users/athos/gt/$d; done'
expect_allow "tar of a repo dir"                     'tar czf /tmp/x.tgz -C /Users/athos/gt docs'
expect_allow "rsync between repo dirs"               'rsync -a /Users/athos/gt/docs/ /tmp/docs/'
expect_allow "cp -R inside repo"                     'cp -R /Users/athos/gt/docs /tmp/docs'
expect_allow "cp -r of a repo dir with a trailing slash" 'cp -r /Users/athos/gt/docs/ /tmp/docs/'
expect_allow "zip -r a repo dir"                     'zip -r /tmp/x.zip /Users/athos/gt/docs'
expect_allow "sibling that merely starts like a protected name" 'du -sk /Users/athos/gt/Downloads-archive'
expect_allow "a repo directory literally named Documents" 'find /Users/athos/gt/whatsapp_automation/docs/Documents -type f'
expect_allow "du a sibling user dir that is not \$HOME (static mismatch)" 'du -sk /Users/Shared'
expect_allow "glob under a repo dir"                 'ls /Users/athos/gt/*.sh'
expect_allow "loop var over ls of a repo dir, cwd in the repo" 'for d in $(ls /Users/athos/gt); do du -sk "$d"; done' /Users/athos/gt/docs
expect_allow "read loop fed by something that is not a home listing" 'cat /Users/athos/gt/list.txt | while read -r d; do du -sk "$d"; done' /Users/athos/gt
expect_allow "brace expansion that stays in the repo" 'du -sk ~/{gt,.gastown}'
expect_allow "ls a Library folder that is not protected" 'ls ~/Library/Caches'
expect_allow "du a go build cache under Library/Caches" 'du -sk ~/Library/Caches/go-build'
expect_allow "ls -d on a protected dir itself (a stat, no listing)" 'ls -d ~/Downloads'
expect_allow "ls -d with a glob in a repo dir"       'ls -d ~/gt/*'
expect_allow "find / with a shallow depth (never reaches a protected folder)" 'find / -maxdepth 1 -name Users'
expect_allow "find /Users -maxdepth 2 -type d"       'find /Users -maxdepth 2 -type d'
expect_allow "find under /usr/local"                 'find /usr/local -name libfoo.dylib'
expect_allow "ls / and ls /Users (not recursive)"    'ls / /Users'
expect_allow "ls -lT ~ (macOS: full timestamps, not tree mode)"  'ls -lT ~'
expect_allow "du -d 1 on a repo dir (a depth flag with a non-hot operand)" 'du -d 1 -h ~/gt'
expect_allow "du -sL / -hP / -n on a repo dir (they are switches)" 'du -sL ~/gt && du -hP ~/gt/docs && du -n ~/gt'
expect_allow "tree -d / -t / -n on a repo dir"       'tree -d ~/gt/docs && tree -t -n ~/gt/docs'
expect_allow "BSD find option letters before a repo path" 'find -H /Users/athos/gt -name x && find -f /Users/athos/gt -name x && find -Hx ~/gt -name x'
# an option can carry its path GLUED to it, no space (tar -C/Users/athos, find -f/Users/athos, --directory=/Users/athos)
expect_block "tar -C glued to \$HOME (no space)"    'tar czf /tmp/x.tgz -C/Users/athos .'
expect_block "find -f glued to \$HOME (no space)"   'find -f/Users/athos -name x'
expect_block "tar --directory= glued to \$HOME"     'tar czf /tmp/x.tgz --directory=/Users/athos .'
expect_allow "command -v does not run the tool"      'command -v du'
expect_allow "xargs fed by something that is not a home listing" 'printf "a\nb\n" | xargs du -sk'
expect_allow "grep -r ... is not what runs after a git ~ revision" 'git diff HEAD~2..HEAD --stat | grep -r foo /Users/athos/gt/docs'
expect_allow "git ~ revision syntax (HEAD~3)"        'git log --oneline HEAD~3..HEAD'
expect_allow "git diff HEAD~1 | grep"                'git diff HEAD~1 | grep foo'
expect_allow "plain git"                             'git status --short'
expect_allow "bd list"                               'bd list --status open --limit 0 --json'
# scan words that are only MENTIONED: quoted text, comments, heredocs, commit / bead bodies
expect_allow "echo of a scan"                        'echo "du -sk ~"'
expect_allow "printf of a scan"                      "printf '%s\n' 'find ~ -name x'"
expect_allow "bead comment mentioning du/find"       'bd comment ga-6cyp1l "medi com du -xsk ~ e find ~/Downloads e deu prompt"'
expect_allow "git commit -m mentioning a scan"       'git commit -m "guard: block du ~ and find ~/Downloads scans"'
expect_allow "heredoc body mentioning scans"         $'cat <<\'EOF\'\ndu -sk ~\nfind ~/Downloads\nls -R ~\nEOF'
expect_allow "heredoc inside \$() (bd create style)" $'bd create --description "$(cat <<\'EOF\'\nO agente rodou du -xsk ~ e find ~/Downloads\nEOF\n)"'
expect_allow "heredoc with <<- and tabs"             $'cat <<-EOF\n\tdu -sk ~\n\tEOF\necho done'
expect_allow "comment line"                          $'# du -sk ~ is what NOT to do\ngit status'
expect_allow "echo/printf print their arguments, they never run them" 'echo du ~/Downloads; printf "%s\n" ls ~/Downloads find ~ -name x'
expect_allow "a quoted string handed to a SCRIPT is data, not a command (bash probe.sh 'du -sk ~')" "bash /tmp/probe.sh 'du -sk ~' 'find ~ -name x'"
expect_allow "a listing pipeline that only names non-hot paths (seen in the wild)" 'find /Users/athos/gt /private/tmp -xdev -type f -mmin -20 -size +50M 2>/dev/null | head -20 | while read f; do echo "$(du -sm "$f" | cut -f1)MB $f"; done | sort -rn | head -12' /Users/athos/gt
expect_allow "ls of home, then ls of a named repo dir (a plain ls is not a scanner unless its operand is fed)" 'ls ~ && ls -la ~/gt' /Users/athos/gt
expect_allow "a home glob that cannot name a protected folder (~/*.txt), read by cat, then an explicit du" 'for f in ~/*.txt; do cat "$f"; done; du -sk /private/tmp/x' /Users/athos/gt
expect_allow "grep for the words in a repo file"     'grep -n "du -sk" /Users/athos/gt/CLAUDE.md'
expect_allow "grep for a \$HOME pattern in a repo (single quotes: no expansion)" "grep -rn '\$HOME' /Users/athos/gt/docs"
expect_allow "python that merely prints"             'python3 -c "print(1)"'
expect_allow "cd ~ alone (nothing scanned)"          'cd ~ && git status'
expect_allow "a redirect target is not a scan operand" 'du -sk /tmp/x > ~/Downloads/out.txt'
expect_allow "empty-ish command"                     ':'

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- ACCEPTED FALSE POSITIVES: the guard is lexical and errs toward blocking; each of these is a harmless command it refuses --"
# ─────────────────────────────────────────────────────────────────────────
# Pinned so that nobody re-adds a heuristic to "fix" one without reading the engine's header: every heuristic of this kind
# (is it a file? how deep does this flag walk? which word is the pattern? did that cd leave the subshell?) was a place a
# scan slipped through in gate rounds 1-4. The message tells the agent what to do instead.
expect_block "du of ONE file in Downloads (no 'is it a file?' guess: read it with cat / stat)" 'du -sk ~/Downloads/x.zip'
expect_block "du of a dotted name in Downloads"        'du -sk ~/Downloads/data.bak'
expect_block "tree -L 2 / (no per-tool 'depth flag stops the walk' table)" 'tree -L 2 /'
expect_block "fd -d 1 . /Users"                        'fd -d 1 . /Users'
expect_block "rg --max-depth 1 pat /Users"             'rg --max-depth 1 foo /Users'
expect_block "find ~ -maxdepth 1 (only ANCESTORS of \$HOME get the shallow-find exemption)" 'find ~ -maxdepth 1 -name x'
expect_block "a cd into a hot dir taints the cwd for the rest of the command (no subshell scoping)" '(cd ~/Downloads && ls report.pdf); find . -name "*.sh"' /Users/athos/gt
expect_block "cd - after a hot cd (no directory stack)" 'cd ~/Downloads && cd - && du -sk *' /Users/athos/gt
expect_block "rg on a pipe at \$HOME (every relative scan at a hot cwd is refused; use an absolute path)" 'git log --oneline | rg foo' /Users/athos
expect_block "a search PATTERN spelled like a hot path (every non-dash word is a candidate path)" 'grep -rn "/Users/athos/Downloads" /Users/athos/gt/scripts'
expect_block "a listing of \$HOME and a scanner in the same command"  'ls ~ && du -xsk ~/gt'
expect_block "a hot cwd and only a relative-looking safe path"  'du -sk gt/docs' /Users/athos
expect_block "cd ~ then a scan of an explicit SAFE path (operands are not consulted: an absolute path can be an option's value)" 'cd ~ && du -sk ~/gt'
expect_block "an explicit safe path from a session whose cwd is \$HOME"  'du -xsk ~/gt' /Users/athos

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- KNOWN GAPS: allowed on purpose (the engine's header lists the same set; the bead is about CLI scanners, not an adversary) --"
# ─────────────────────────────────────────────────────────────────────────
expect_allow "GAP interpreter: python os.walk"         "python3 -c 'import os; list(os.walk(\"/Users/athos\"))'"
expect_allow "GAP interpreter: node fs.readdirSync"    "node -e 'require(\"fs\").readdirSync(\"/Users/athos/Downloads\")'"
expect_allow "GAP a script FILE is not read"           'bash /tmp/some-script.sh'
expect_allow "GAP a script handed to a shell on stdin" $'bash <<\'EOF\'\ndu -sk ~/Downloads\nEOF'
expect_allow "GAP a value only known at run time (non-hot cwd)" 'du -sk "$1"'
expect_allow "GAP \${VAR:-default} keeps the run-time part unknown" 'du -sk "${X:-$HOME}"'
expect_allow "GAP a glob under a protected folder for a command that is NOT a scanner (reading files the operator pointed at)" 'cat ~/Downloads/*.csv'
expect_allow "GAP git walks the tree it is pointed at"  'git -C ~ status --short'

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- FAIL-OPEN: a guard that breaks every Bash call is worse than the problem --"
# ─────────────────────────────────────────────────────────────────────────
# Runs that DELIBERATELY degrade the guard (bad input, missing interpreter, hung classifier) log to their own file, so
# the corpus log above can assert that the must-block / must-allow cases themselves never degraded or crashed.
DELIB="$SCRATCH/deliberate.log"
DELIB_ENV=(GC_AGENT=selftest-agent HOME_SCAN_GUARD_LOG="$DELIB")
run_raw() {  # stdin-text  [env assignments...]
  local input="$1"; shift
  ERR="$(printf '%s' "$input" | env "${DELIB_ENV[@]}" "$@" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
}
run_raw '';                                                            [ "$RC" -eq 0 ] && ok "empty stdin -> allow" || bad "empty stdin: rc=$RC"
run_raw 'not json at all {{{';                                         [ "$RC" -eq 0 ] && ok "malformed JSON -> allow" || bad "malformed JSON: rc=$RC err=$ERR"
run_raw '{"tool_name":"Bash"}';                                        [ "$RC" -eq 0 ] && ok "no tool_input -> allow" || bad "no tool_input: rc=$RC"
run_raw '{"tool_name":"Bash","tool_input":{"command":123}}';           [ "$RC" -eq 0 ] && ok "non-string command -> allow" || bad "non-string command: rc=$RC"
run_raw '{"tool_name":"Bash","tool_input":{"command":null}}';          [ "$RC" -eq 0 ] && ok "null command -> allow" || bad "null command: rc=$RC"
run_raw '[1,2,3]';                                                     [ "$RC" -eq 0 ] && ok "JSON array -> allow" || bad "JSON array: rc=$RC"
run_raw "$(jq -cn --arg c 'du -sk ~' '{tool_name:"Read",tool_input:{command:$c}}')"
[ "$RC" -eq 0 ] && ok "non-Bash tool_name -> allow" || bad "non-Bash tool: rc=$RC"
# unbalanced quotes / parens must not crash the classifier into blocking or erroring
for weird in "echo 'unterminated" 'echo "unterminated' 'echo $(unterminated' 'echo `unterminated' 'cat <<EOF' 'for d in' ')))' 'du -sk "$(' $'echo \x01\x02' 'echo ${' 'echo $((' '<<' '>' '&&' '|' ';' '((' 'echo <(' ; do
  expect_allow "unparseable but harmless: ${weird:0:24}" "$weird"
done
# a genuinely unparseable command that ALSO scans home: the words are still read, so it is refused
run_guard "du -sk ~ 'unterminated"
[ "$RC" -eq 2 ] && ok "unterminated quote + scan -> still a clean BLOCK (the words are read)" || bad "unterminated+scan: rc=$RC err=$ERR"
run_guard 'echo "$(du -sk ~'
[ "$RC" -eq 2 ] && ok "unterminated \$( + scan -> still a clean BLOCK" || bad "unterminated \$(+scan: rc=$RC err=$ERR"
# no agent identity in the environment => Athos's own terminal: never blocked. Scrub EVERY
# identity variable: the session running this selftest is itself an agent session, and a leaked
# GC_SESSION_ID/GC_ALIAS would make both of the checks below vacuous.
NO_ID=(-u GC_AGENT -u GC_ALIAS -u GC_DIR -u GC_SESSION_NAME -u GC_SESSION_ID)
# (a file redirect, not a pipe: the guard exits at the identity gate WITHOUT reading stdin, so with a pipe the
# producer's SIGPIPE -- rc 141 under pipefail -- leaked into RC and this case flaked under the city's load)
hook_json "$INCIDENT" > "$SCRATCH/incident.json"
ERR="$(env "${NO_ID[@]}" "$HOOK_BASH" "$GUARD" < "$SCRATCH/incident.json" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "no GC_* identity (Athos's terminal) -> allow, even the incident" || bad "no-identity: rc=$RC err=$ERR"
for v in GC_AGENT GC_ALIAS GC_DIR GC_SESSION_NAME GC_SESSION_ID; do
  ERR="$(hook_json "$INCIDENT" | env "${NO_ID[@]}" "$v=x" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
  [ "$RC" -eq 2 ] && ok "$v alone identifies an agent session -> block" || bad "$v alone: rc=$RC err=$ERR"
done
# broken classifier / missing helpers
ERR="$(hook_json "$INCIDENT" | env "${DELIB_ENV[@]}" HOME_SCAN_GUARD_PY=/nonexistent/python "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "classifier binary missing -> allow" || bad "missing python: rc=$RC err=$ERR"
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/py-crash"; chmod +x "$SCRATCH/py-crash"
ERR="$(hook_json "$INCIDENT" | env "${DELIB_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-crash" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "classifier crashes (exit 1) -> allow" || bad "crashing classifier: rc=$RC err=$ERR"
# python's OWN usage errors exit 2 too: rc==2 alone is not proof of a block, the marker line is
printf '#!/bin/sh\necho "usage: python [option] ... [-c cmd | -m mod | file | -] [arg] ..." >&2\nexit 2\n' > "$SCRATCH/py-usage"; chmod +x "$SCRATCH/py-usage"
ERR="$(hook_json "$INCIDENT" | env "${DELIB_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-usage" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "interpreter exits 2 with a usage error (no BLOCKED marker) -> allow" || bad "stray rc=2 blocked: rc=$RC err=$ERR"
printf '#!/bin/sh\nsleep 30\n' > "$SCRATCH/py-hang"; chmod +x "$SCRATCH/py-hang"
T0=$SECONDS
ERR="$(hook_json "$INCIDENT" | env "${DELIB_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-hang" HOME_SCAN_GUARD_TIMEOUT=2 "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ $((SECONDS-T0)) -lt 10 ] && ok "classifier hangs -> allowed after the guard's own timeout (~$((SECONDS-T0))s)" || bad "hanging classifier: rc=$RC took=$((SECONDS-T0))s"
# jq missing from PATH: cannot even read the input -> allow
mkdir -p "$SCRATCH/nojq"; for b in bash cat env sh dirname basename date mkdir printf; do p="$(command -v $b)" && ln -sf "$p" "$SCRATCH/nojq/$b"; done
ERR="$(hook_json "$INCIDENT" | env "${DELIB_ENV[@]}" PATH="$SCRATCH/nojq" /bin/bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "jq missing -> allow" || bad "no jq: rc=$RC err=$ERR"
# the classifier itself, fed directly (the wrapper's prefilter never lets these reach it)
printf 'garbage, not json' | env "${DELIB_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "engine: non-JSON stdin -> allow" || bad "engine non-JSON: rc=$RC"
hook_json 'du -sk ~' | env "${DELIB_ENV[@]}" HOME_SCAN_GUARD_HOME= HOME= python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "engine: no usable home -> allow (cannot classify, does not guess)" || bad "engine no-home: rc=$RC"
deep="$(printf 'echo %s' "$(printf '$(%.0s' $(seq 1 30))")"
hook_json "$deep" | env "${DELIB_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok "engine: absurd nesting with nothing in it -> allow, no crash" || bad "engine deep nesting: rc=$RC"
hook_json 'du -sk ~' | env "${DELIB_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && ok "engine: direct call blocks the plain case (sanity for the three above)" || bad "engine direct sanity: rc=$RC"
# ...but every DEGRADATION is counted (a guard that quietly stops guarding is worse than none). Each scenario gets its own log.
DEG="$SCRATCH/degraded.log"
degraded() {  # description  expected-log-fragment  [env assignments...]   (runs the incident through the wrapper)
  local what="$1" frag="$2"; shift 2
  : > "$DEG"
  hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$@" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
  if [ "$RC" -eq 0 ] && grep -q "result=UNGUARDED" "$DEG" && grep -q -F -- "$frag" "$DEG"; then ok "degradation logged (not silent): $what"
  else bad "degradation not logged: $what -- rc=$RC log=[$(cat "$DEG")]"; fi
}
degraded "classifier interpreter missing" "no python3 interpreter" HOME_SCAN_GUARD_PY=/nonexistent/python
degraded "classifier crashes" "exited 1" HOME_SCAN_GUARD_PY="$SCRATCH/py-crash"
degraded "classifier hangs and is killed" "timed out" HOME_SCAN_GUARD_PY="$SCRATCH/py-hang" HOME_SCAN_GUARD_TIMEOUT=2
degraded "interpreter exits 2 without the BLOCKED marker" "exited 2 without a block verdict" HOME_SCAN_GUARD_PY="$SCRATCH/py-usage"
mkdir -p "$SCRATCH/noengine"; cp "$GUARD" "$SCRATCH/noengine/home-scan-guard.sh"
: > "$DEG"; hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$SCRATCH/noengine/home-scan-guard.sh" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "classifier missing" "$DEG" && ok "degradation logged (not silent): classifier file gone (a moved/cleaned checkout)" || bad "missing classifier not logged: rc=$RC log=[$(cat "$DEG")]"
: > "$DEG"; hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" PATH="$SCRATCH/nojq" /bin/bash "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "jq not found" "$DEG" && ok "degradation logged (not silent): jq missing" || bad "missing jq not logged: rc=$RC log=[$(cat "$DEG")]"
# and the NORMAL quiet exits are not degradations: they must leave the log empty
: > "$DEG"
hook_json 'git status' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1
hook_json 'du -sk ~/gt' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1
hook_json "$INCIDENT" | env "${NO_ID[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1
echo '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1
[ ! -s "$DEG" ] && ok "quiet exits (ordinary command, no identity, non-Bash tool, safe path) write nothing to the log" || bad "quiet exits polluted the log: $(cat "$DEG")"
# an unwritable log must never turn a block into an error, nor an allow into a block
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG=/nonexistent/dir/x.log "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "unwritable log -> still blocks the incident" || bad "unwritable log: rc=$RC"
# The wrapper's OTHER exits that are not "nothing to see here" are counted as well.
counted() {  # description  fragment  input  [env assignments...]
  local what="$1" frag="$2" input="$3"; shift 3
  : > "$DEG"
  printf '%s' "$input" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$@" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
  if [ "$RC" -eq 0 ] && grep -q "result=UNGUARDED" "$DEG" && grep -q -F -- "$frag" "$DEG"; then ok "degradation logged (not silent): $what"
  else bad "degradation not logged: $what -- rc=$RC log=[$(cat "$DEG")]"; fi
}
counted "hook payload that is not JSON"   "not parseable" 'not json at all {{{ du -sk ~'
counted "hook payload that is empty"      "empty"         ''
counted "a scan with no usable \$HOME"    "no usable home" "$(hook_json 'du -sk ~')" HOME_SCAN_GUARD_HOME=nohome
: > "$DEG"; printf '\377\376{"tool_name":"Bash"}' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "result=GAVE-UP" "$DEG" && grep -q "not valid UTF-8" "$DEG" && ok "engine: stdin that is not valid UTF-8 -> allow, and logged" || bad "engine non-UTF-8: rc=$RC log=[$(cat "$DEG")]"
# a cwd the guard cannot know is a THIRD state, not "not hot": a relative scan after it is allowed (fail-open is the
# contract) but COUNTED (UNKNOWN-CWD). A cwd it does know leaves the log empty.
: > "$DEG"; hook_json 'du -sk *' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "result=UNKNOWN-CWD" "$DEG" && ok "a relative scan with NO cwd in the payload -> allowed, but logged UNKNOWN-CWD (not silent)" || bad "no-cwd relative scan not logged: rc=$RC log=[$(cat "$DEG")]"
: > "$DEG"; hook_json 'cd "$SOMEWHERE" && du -sk * ../x' /Users/athos/gt | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "result=UNKNOWN-CWD" "$DEG" && ok "a cd to a run-time value, then a relative scan -> allowed, but logged UNKNOWN-CWD" || bad "unknown cd target not logged: rc=$RC log=[$(cat "$DEG")]"
: > "$DEG"; hook_json 'cd ~/gt && du -sk *' /Users/athos/gt | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$DEG" ] && ok "a KNOWN cwd leaves the log empty" || bad "known cwd polluted the log: rc=$RC log=[$(cat "$DEG")]"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- COST: the hook runs on every Bash call of every agent; ordinary calls must not spawn python --"
# ─────────────────────────────────────────────────────────────────────────
# machine load is 40-60 on 10 cores (ga-y0g5x: a detector's poll cost IS load) and python3
# start-up measured 100-280ms there, so the bash prefilter has to be a real fast path.
printf '#!/bin/sh\ntouch "%s/py-called"\nexit 0\n' "$SCRATCH" > "$SCRATCH/py-stub"; chmod +x "$SCRATCH/py-stub"
spawned() {  # command [cwd] -> 0 if the classifier was spawned
  rm -f "$SCRATCH/py-called"
  hook_json "$1" "${2-}" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-stub" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1
  [ -e "$SCRATCH/py-called" ]
}
for c in 'git status --short' 'bd list --status open --limit 0 --json' 'gc session peek x --lines 40' 'ls -la' \
         'du -xsk ~/gt' 'du -xsk ~/.gastown' "find /Users/athos/gt -name '*.sh'" 'rg foo /Users/athos/gt/docs' \
         'grep -rn foo /Users/athos/gt/.gascity-gastown-hq/scripts' 'git log --oneline HEAD~3..HEAD' 'cat ~/gt/CLAUDE.md'; do
  spawned "$c" /Users/athos/gt/whatsapp_automation && bad "python spawned for an ordinary command: $c" || ok "fast path (no python): $c"
done
spawned 'du -sk ~' /Users/athos/gt && ok "python IS spawned when a scan meets \$HOME" || bad "prefilter missed 'du -sk ~'"
spawned 'find . -name x' /Users/athos && ok "python IS spawned when the cwd itself is \$HOME" || bad "prefilter missed cwd=\$HOME"
spawned 'du -sk *' && ok "python IS spawned for a scan when the payload has no cwd" || bad "prefilter dropped a scan with no cwd"
spawned 'git status --short' && bad "python spawned for git status with no cwd" || ok "fast path with no cwd: a command with no scan tool"
spawned 'du -sk ~athos/Desktop' /Users/athos/gt && ok "python IS spawned for ~athos/Desktop (the prefilter reads ~name)" || bad "prefilter missed ~athos"
# $HOME goes into a regex in the prefilter: a home with regex metacharacters must neither break it nor turn "cannot compile" into "not hot"
# (the old escape handled only '.', so a home like /Users/a+b(c[d] made `[[ =~ ]]` return 2 and the guard quietly stood down)
for h in '/Users/a+b(c[d]' '/Users/x.y*z' '/Users/we^ird$name|x'; do
  ERR="$(hook_json "du -sk '$h/Desktop'" /Users/athos/gt | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_HOME="$h" "$HOOK_BASH" "$GUARD" 2>&1 >/dev/null)"; RC=$?
  [ "$RC" -eq 2 ] && ok "a \$HOME with regex metacharacters ($h) still blocks a scan of its Desktop" || bad "home with metacharacters $h: rc=$RC err=[${ERR:0:120}]"
done

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- STRUCTURAL SWEEPS: lock the FORM of the guard (in-process against the engine) --"
# ─────────────────────────────────────────────────────────────────────────
# Rounds 1-4 of the gate each reproduced ONE more spelling of the same defect: an option table, a wrapper table or a
# stdin-taint rule decided which word was the path, and a wrong entry became a silent allow. The fix for a class is a test
# that fails when the FORM regresses, so these do not list examples: they take every scanner x every hot target and put
# arbitrary options, wrappers and pipe consumers around them. BLOCK must stay BLOCK for every one; and the same shapes over
# SAFE targets must stay ALLOW (or the sweep would be satisfied by a guard that blocks everything).
cat > "$SCRATCH/sweeps.py" <<'PYEOF'
import importlib.util, itertools, json, random, shlex, sys, time

spec = importlib.util.spec_from_file_location("hsg", sys.argv[1])
hsg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hsg)
SAMPLE_OUT, BLOCKS_OUT = sys.argv[2], sys.argv[3]
HOMES = ["/Users/athos"]
GT = "/Users/athos/gt"
sample, allblocks = [], []


def verdict(cmd, cwd):
    try:
        hsg.analyze(cmd, cwd, HOMES)
        return "allow"
    except hsg.Block:
        return "block"
    except BaseException as exc:          # an engine crash is neither verdict: the run must show it
        return "ERROR %s: %s" % (type(exc).__name__, exc)


def sweep(name, cases, want, sample_every=0, stride=1):
    fails = []
    for i, (cmd, cwd) in enumerate(cases):
        got = verdict(cmd, cwd)
        if got != want:
            fails.append((cmd, cwd, got))
        elif want == "block":
            if sample_every and i % sample_every == 0:
                sample.append({"cmd": cmd, "cwd": cwd or ""})
            if i % stride == 0:
                allblocks.append((cmd, cwd or ""))
    print("SWEEP\t%s\t%d\t%d" % (name, len(cases), len(fails)))
    for cmd, cwd, got in fails[:6]:
        print("FAILCASE\t%s\t%r\tcwd=%s\tgot=%s" % (name, cmd, cwd, got))


SCANNERS = ["du -sk", "du", "gdu", "dust", "ncdu", "tree", "fd", "rg", "ag", "ack", "grep -r", "grep -rn",
            "grep --recursive", "egrep -R", "mdfind", "find", "gfind", "ls -R", "ls -laR", "gls -R", "eza -R",
            "eza -T", "rsync -a", "cp -r", "cp -R", "zip -r /tmp/x.zip", "tar czf /tmp/x.tgz", "ditto"]
HOT = ["~", "~/", "$HOME", "${HOME}", '"$HOME"', "/Users/athos", "/Users/athos/", "~/Downloads", "~/Documents/sub",
       "~/Desktop/", "~/Pictures", "~/Movies", "~/Music", "~/*", "~/D*", "~/.*", "/Users/athos/*", "/Users/*/Downloads",
       "/Volumes", "/Volumes/Backup", "~/Library/CloudStorage", '"$HOME/Library/Mobile Documents"', "~/Library",
       "/Users", "/", "~/gt/..", "~/{gt,Downloads}", "/Users/athos/gt/../Documents"]
SAFE = ["~/gt", "~/gt/", "/tmp", "/private/tmp/claude-501", "/Users/athos/gt/docs", "~/.gastown",
        "~/Library/Caches/go-build", "/usr/local", "~/{gt,.gastown}", '"$HOME/gt"', "/Users/athos/gt/../.gastown",
        "${HOME}/.local", "/Users/Shared", "/Users/athos/gt/Downloads-archive",
        "/Users/athos/gt/whatsapp_automation/docs/Documents"]
# what an option can look like: switch, cluster, long, long=value, long value, short value, number, path value, "--"
DECOR = ["", "-x", "-xs", "-h", "--foo", "--foo=bar", "--foo bar", "-n 5", "-L", "-P", "-d 1", "-t 1M", "-B 1024",
         "-I x", "-e pat", "--sort path", "--max-filesize 1M", "--changed-within 1d", "--exclude-from f", "-o /tmp/o",
         "--", "-j4"]


def placed(tool, target, decor):
    yield "%s %s %s" % (tool, decor, target)
    yield "%s %s %s" % (tool, target, decor)
    yield "%s %s %s %s" % (tool, decor, target, decor)


# 1. OPTIONS ARE IRRELEVANT: no option shape, anywhere, turns a hot target into a safe one
cases = [(c, GT) for t in SCANNERS for h in HOT for d in DECOR for c in placed(t, h, d)]
sweep("options: every scanner x every hot target x every option shape x every position -> BLOCK", cases, "block", 1200, 3)
cases = [(c, GT) for t in SCANNERS for h in SAFE for d in DECOR for c in placed(t, h, d)]
sweep("options: the same shapes over SAFE targets -> ALLOW (the control)", cases, "allow")

# 2. THE TOOL'S NAME IS ITS NAME, however spelled
NAMES = ["du", "/usr/bin/du", "DU", '"du"', "'du'", 'd""u', "\\du", "command du", "/usr/bin/find", "FIND", "'find'"]
cases = [("%s -sk %s" % (n, h), GT) for n in NAMES for h in ["~", "~/Downloads", "$HOME", "/Users/athos"]]
sweep("tool name spellings (path, case, quotes, backslash, command) -> BLOCK", cases, "block")
# ...and so is a PATH: the shell joins a quote or a backslash in the middle of a component (this also runs through the wrapper's prefilter
# differential below, which used to read the quote-stripped copy for the tool NAME only)
SPLIT = ['/Us""ers/athos/Downloads', "/Users/ath''os", '/Users/athos/Down"loads"', "~/D\\ownloads", '"$HOME"/Down""loads',
         "'/Users'/athos/Desktop", '/Users/athos/"Docu"ments', '~/Lib""rary/CloudStorage', '/Vol""umes', "/Users/athos/Pic\\tures"]
cases = [("%s %s" % (tool, path), GT) for tool in ["du -sk", "find", "rg foo", "grep -r foo", "ls -R", "tree"] for path in SPLIT]
sweep("paths the shell joins (a quote or backslash inside a component) -> BLOCK", cases, "block")

# 3. WRAPPERS ARE IRRELEVANT: no wrapper (and no wrapper option) hides the scanner
WRAPPERS = ["env", "env -i", "env FOO=1", "sudo", "sudo -n", "sudo -i", "sudo -u athos", "sudo -D /tmp", "nice",
            "nice -n 5", "nice --adjustment 5", "ionice -c 3", "caffeinate", "caffeinate -i", "caffeinate -u",
            "caffeinate -t 60", "time", "time -o /tmp/t", "/usr/bin/time -o /tmp/t", "time -p", "timeout 60",
            "timeout -k 5 60", "gtimeout 60", "nohup", "watch -n 5", "flock /tmp/l", "taskpolicy -b",
            "script /tmp/o", "doas", "command", "exec", "stdbuf -o0", "arch -arm64", "setsid", "unbuffer",
            "chronic", "xargs", "xargs -n1", "xargs -I{}", "parallel", "some-wrapper-nobody-has-heard-of --flag x"]
SOME = ["du -sk", "find", "rg foo", "grep -r foo", "tree", "ls -R"]
TGT = ["~", "~/Downloads", "/Users/athos", "~/*"]
cases = [("%s %s %s" % (w, s, t), GT) for w in WRAPPERS for s in SOME for t in TGT]
sweep("wrappers: every wrapper x scanner x hot target -> BLOCK", cases, "block", 100)
cases = [("%s %s %s" % (w, s, t), GT) for w in WRAPPERS for s in SOME for t in ["~/gt", "/tmp", "/Users/athos/gt/docs"]]
sweep("wrappers: the same over SAFE targets -> ALLOW (the control)", cases, "allow")
PAIR = ["env", "sudo -n", "nice -n 5", "caffeinate -i", "time -o /tmp/t", "timeout 60", "nohup", "watch -n 5", "xargs -n1"]
cases = [("%s %s %s %s" % (a, b, s, t), GT) for a in PAIR for b in PAIR for s in SOME for t in TGT]
sweep("wrappers: chains of two wrappers -> BLOCK", cases, "block")
cases = [("%s '%s'" % (l, inner), GT) for l in ["bash -c", "sh -c", "zsh -c", "zsh -lc", "eval", "sudo sh -c", "xargs sh -c",
         "timeout 5 bash -c", "nice bash -c", "env -S", "env FOO=1 bash -c"]
         for inner in ["du -sk ~", "find ~ -maxdepth 1", "ls -R ~/Documents", "cd ~ && du -sk *",
                       'for d in $(ls ~); do du -sk "$d"; done', "du -sk ~/Downloads", "du -sk /Users/athos"]]
sweep("launchers that take the scan as ONE string (bash -c, eval, env -S, ...) -> BLOCK", cases, "block", 20)
cases = [("bash -c \"sh -c 'du -sk ~'\"", GT), ("sh -c 'bash -c \"du -sk ~/Downloads\"'", GT),
         ("bash -c 'eval \"du -sk ~\"'", GT), ("bash -c 'bash -c '\"'\"'du -sk ~'\"'\"''", GT)]
sweep("launchers nested inside launchers -> BLOCK", cases, "block")

# 4. A LISTING THAT FEEDS A MEASUREMENT: every producer x every consumer plumbing x every measuring tool
PRODUCERS = ["ls ~", "ls -A ~", "ls -la /Users/athos", "ls /Users", "ls /", "ls -1 ~/", "find ~ -maxdepth 1",
             "find /Users -maxdepth 1", "find / -maxdepth 2", "printf '%s\\n' ~/*", "echo ~/*", "ls -d ~/*/",
             "echo $HOME", "ls $HOME", "ls -A ${HOME}"]
CONSUMERS = ["{P} | xargs {T}", "{P} | xargs -I{} {T} {}", "{P} | xargs -I{} sh -c '{T} {}'",
             "{P} | xargs -I{} sh -c '{T} \"{}\"'", "{P} | xargs -n1 sh -c '{T} \"$0\"'",
             "{P} | xargs -n 1 bash -c '{T} \"$1\"' _", "{P} | while read -r d; do {T} \"$d\"; done",
             "for d in $({P}); do {T} \"$d\"; done", "{T} $({P})", "{T} `{P}`", "xargs {T} < <({P})",
             "mapfile -t a < <({P}); {T} \"${a[@]}\"", "L=$({P}); {T} $L", "{P} | parallel {T} {}",
             "{P} | xargs -I% {T} %", "{P} | sort | head -20 | xargs {T}", "{P} | xargs --max-args 1 {T}",
             "{P} | while read d; do sh -c \"{T} $d\"; done"]
MEASURE = ["du -sk", "du -xsk", "dust", "gdu", "ncdu", "tree", "ls -la", "ls"]
cases = [(c.replace("{P}", p).replace("{T}", t), cwd) for c in CONSUMERS for p in PRODUCERS for t in MEASURE
         for cwd in (GT, None)]
sweep("feeds: every listing of \\$HOME/an ancestor x every plumbing x every measuring tool -> BLOCK", cases, "block", 200)
SAFE_PROD = ["ls ~/gt", "ls /Users/athos/gt", "ls /tmp", "find ~/gt -maxdepth 1", "printf '%s\\n' ~/gt/*", "echo ~/.gastown/*"]
cases = [(c.replace("{P}", p).replace("{T}", t), GT) for c in CONSUMERS for p in SAFE_PROD for t in MEASURE]
sweep("feeds: the same plumbing fed by a SAFE listing -> ALLOW (the control)", cases, "allow")

# 5. A HOT CWD: every relative-scan shape x every hot cwd
REL = ["find .", "find", "find . -name x", "du -sk *", "du -sk", "du -sk .", "du -d 1", "du -d 1 -h", "rg foo",
       "rg --sort path foo", "rg --pre ./x foo", "rg --max-filesize 1M foo", "fd py", "fd --changed-within 1d py",
       "grep -r foo", "grep -r foo .", "grep -r --exclude-from f foo", "gls -R", "gls -R --sort time", "ls -R",
       "eza -R --sort size", "eza -T --sort size", "tree", "ncdu", "dust", "gdu",
       'for d in *; do du -sk "$d"; done', 'ls -A | xargs du -sk', "ls | xargs -I{} sh -c 'du -sk \"{}\"'",
       'for d in $(ls -A); do du -xsk "$d"; done', 'ls -A | while read d; do du -sk "$d"; done', "du -sk ./*",
       "rsync -a . /tmp/x", "cp -r . /tmp/x", "tar czf /tmp/x.tgz ."]
HOTCWD = ["/Users/athos", "/Users/athos/Desktop", "/Users/athos/Documents/sub", "/Users/athos/Library/CloudStorage",
          "/Volumes", "/Volumes/Backup", "/Users", "/"]
cases = [(c, cwd) for c in REL for cwd in HOTCWD]
sweep("hot cwd: every relative scan x every hot cwd -> BLOCK", cases, "block", 30)
# NO exemption for an explicit absolute path: it can be an option's VALUE (`rg --ignore-file /tmp/ig foo` still walks the cwd), and reading
# options is exactly what this guard does not do. (Rule B was the last place that guessed which word was the operand.)
EXPLICIT = ["du -sk /tmp/x", "du -xsk ~/gt ~/.gastown", "find /Users/athos/gt -name x", "rg foo ~/gt", "grep -rn foo /Users/athos/gt/docs",
            "tree /private/tmp/claude-501", "ls -R /Users/athos/gt/docs", "rg --ignore-file /tmp/ig foo", "rg --pre /usr/bin/cat foo",
            "rg --sort path /tmp/x foo", "fd --ignore-file /tmp/ig py", "grep -r --exclude-from /tmp/ig foo", "grep -r -f /tmp/patterns",
            "du --files0-from /tmp/l", "find -newer /tmp/ref -name x", "find -f /tmp/x", "ag --path-to-ignore /tmp/ig foo",
            "ack --ignore-file /tmp/ig foo", "rg --files --ignore-file /tmp/ig"]
cases = [(c, cwd) for c in EXPLICIT for cwd in HOTCWD]
sweep("hot cwd: even a scan that names an explicit SAFE absolute path is refused (it can be an option's value) -> BLOCK", cases, "block", 40)
cases = [("find /Users -maxdepth 1 -name x", GT), ("find / -maxdepth 2 -type d", None),
         ("find . -maxdepth 1", "/"), ("find . -maxdepth 2 -name x", "/Users")]
sweep("the ONE exemption: find with -maxdepth <= 2 whose only hot target is an ANCESTOR of $HOME -> ALLOW", cases, "allow")
cases = [(c, cwd) for c in REL for cwd in [GT, GT + "/docs", "/tmp", "/private/tmp/claude-501/x", "/Users/athos/.gastown"]]
sweep("safe cwd: the same relative scans away from $HOME -> ALLOW (the control)", cases, "allow")

# 5b. A HOME WHOSE NAME HAS GLOB / REGEX CHARACTERS is still recognised as itself (its `[d]` was read as a character class, so the guard
# could not tell its own home and stood down): the home and the payload's cwd enter the classifier as literal text
def verdict_home(cmd, cwd, home):
    try:
        hsg.analyze(cmd, cwd, [home])
        return "allow"
    except hsg.Block:
        return "block"
    except BaseException as exc:
        return "ERROR %s: %s" % (type(exc).__name__, exc)


odd = ["/Users/a+b(c[d]", "/Users/x.y*z", "/Users/we^ird$name|x", "/Users/q?r{s,t}", "/Users/o~p"]
bad_odd = []
for h in odd:
    for cmd, want in [("du -sk ~", "block"), ("du -sk ~/Downloads", "block"), ("du -sk '" + h + "/Desktop'", "block"),
                      ("cd " + shlex.quote(h) + " && du -sk *", "block"), ("du -sk ~/gt", "allow"), ("du -sk '" + h + "/gt'", "allow")]:
        got = verdict_home(cmd, "/Users/athos/gt", h)
        if got != want:
            bad_odd.append((h, cmd, want, got))
    if verdict_home("du -sk *", h, h) != "block":
        bad_odd.append((h, "du -sk * (cwd is the odd home)", "block", "allow"))
print("SWEEP\ta $HOME with glob/regex characters in its name is still $HOME (5 homes x 7 shapes)\t%d\t%d" % (len(odd) * 7, len(bad_odd)))
for h, cmd, want, got in bad_odd[:5]:
    print("FAILCASE\todd-home\t%r\thome=%s\tgot=%s (wanted %s)" % (cmd, h, got, want))

# 5c. "don't know" is COUNTED: a scan whose cwd is unknown is allowed but returns a note (the caller logs it as UNKNOWN-CWD); a known cwd returns none
note_unknown = hsg.analyze("du -sk *", None, HOMES)
note_after_cd = hsg.analyze('cd "$SOMEWHERE" && du -sk *', GT, HOMES)
note_known = hsg.analyze("du -sk *", GT, HOMES)
print("SWEEP\ta scan with NO cwd, or after a cd to a run-time value, returns a note; a known cwd returns none\t3\t%d"
      % ((0 if note_unknown else 1) + (0 if note_after_cd else 1) + (1 if note_known else 0)))

# 6. ROBUSTNESS: whatever the text is, the engine never raises (a crash is a silent fail-open) and stays fast
random.seed(20260927)
TOKS = ["du", "-sk", "~", "$HOME", "${HOME}", "/Users/athos", "/", "'", '"', "`", "$(", ")", "(", "{", "}", ",", ";", "&&",
        "||", "|", "&", "<<", "<<<", "<", ">", ">>", "2>&1", "\n", " ", "\\", "$", "*", "?", "[", "]", "cd", "find",
        "ls", "-R", "for", "d", "in", "do", "done", "xargs", "bash", "-c", "eval", "EOF", "#", "~/Downloads", "$'", "${",
        "$((", "))", "x=", "=", "a", "b", "\t", "\x00", "é", "\ud7ff"]
worst = 0.0
errors = []
for i in range(20000):
    cmd = "".join(random.choice(TOKS) + random.choice(["", " ", ""]) for _ in range(random.randint(1, 40)))
    t0 = time.perf_counter()
    got = verdict(cmd, random.choice([None, GT, "/Users/athos", "/"]))
    worst = max(worst, time.perf_counter() - t0)
    if got.startswith("ERROR"):
        errors.append((cmd, got))
print("SWEEP\trobustness: 20000 random token soups never raise\t20000\t%d" % len(errors))
for cmd, got in errors[:4]:
    print("FAILCASE\trobustness\t%r\tcwd=?\tgot=%s" % (cmd, got))
print("SWEEP\trobustness: worst single verdict under 1.0s (was %.3fs)\t1\t%d" % (worst, 1 if worst >= 1.0 else 0))
def timed(name, cmd, cwd, want, limit):
    t0 = time.perf_counter()
    got = verdict(cmd, cwd)
    took = time.perf_counter() - t0
    print("SWEEP\t%s (%.3fs)\t1\t%d" % (name, took, 0 if got == want and took < limit else 1))
    if got != want or took >= limit:
        print("FAILCASE\t%s\t%r\tcwd=%s\tgot=%s in %.2fs" % (name, cmd[:80], cwd, got, took))


# a glob with many wildcards compiles to a regex that is exponential to match: it must be READ AS "could be anything", never compiled
# (before: `du -sk ~/**************************************************x` did not return in 60s -- the wrapper kills it at 5s = a silent allow)
timed("a component with 50 stars is 'could be anything' (BLOCK), not a hang", "du -sk ~/" + "*" * 50 + "x", GT, "block", 1.0)
timed("a component of 40 x '*a' then a literal: BLOCK in under 1s", "du -sk ~/" + "*a" * 40 + "x", GT, "block", 1.0)
timed("the same stars in a SAFE component (~/gt/...): still ALLOW, in under 1s", "du -sk ~/gt/" + "*" * 50 + "x", GT, "allow", 1.0)
timed("a word of 20000 tildes reads in under 2s (the NAME= check was quadratic)", "du -sk " + "~" * 20000, GT, "allow", 2.0)
timed("15000 DISTINCT words in one scanner segment read in under 3s", "du -sk " + " ".join("w%d" % i for i in range(15000)), GT, "allow", 3.0)
# quoted scripts nested inside quoted scripts: a worklist, not recursion (nesting is bounded by the QUOTING, which grows ~3x per level, so
# 8 levels is ~13KB of text). Eight levels -- the depth where the recursion this replaced gave up -- are read like one. The depth cap is tested by lowering it: past it the command is REFUSED -- a cap
# must end in a block, never an allow (the flat fallback this replaced split on whitespace and let `bash -c 'bash -c ...du -sk ~/Downloads'` through)
ws8, scan8, ok8 = "   ", "du -sk ~/Downloads", "true"
for _ in range(6):
    ws8, scan8, ok8 = "bash -c " + shlex.quote(ws8), "bash -c " + shlex.quote(scan8), "bash -c " + shlex.quote(ok8)
timed("8 levels of bash -c around a whitespace-only script: no exception", ws8, GT, "allow", 2.0)
timed("8 levels of bash -c around a harmless command: read, ALLOW", ok8, GT, "allow", 2.0)
timed("8 levels of bash -c around a scan: BLOCK", scan8, GT, "block", 2.0)
saved_cap, hsg.MAX_SCRIPT_DEPTH = hsg.MAX_SCRIPT_DEPTH, 2
timed("past the script-depth cap (lowered to 2): a harmless command 8 levels deep is REFUSED, not allowed", ok8, GT, "block", 2.0)
hsg.MAX_SCRIPT_DEPTH = saved_cap
big = "echo " + "x " * 20000 + "; du -sk ~"
t0 = time.perf_counter()
got = verdict(big, GT)
took = time.perf_counter() - t0
print("SWEEP\ta 40KB command with a scan at the end is read (blocked) in under 2s (%.3fs)\t1\t%d" % (took, 0 if got == "block" and took < 2 else 1))
# adversarial review (round 5): a heredoc body with many UNCLOSED $( used to re-lex the remaining body from every
# occurrence independently (O(matches x body length)); many repeats of one grep-family tool name did an O(n) whole-words
# scan once per matching word (O(n^2)). Both are ordinary generated-command shapes, not adversarial ones.
timed("heredoc body with 400 unclosed $( : fast, not a multi-second hang", "cat <<EOF\n" + "$(" * 400 + "\nEOF\ndu -sk ~", GT, "block", 1.0)
timed("6000 repeated grep-family words in one segment: fast, not O(n^2)", "grep " * 6000 + "foo /tmp/x", GT, "allow", 1.0)
timed("a heredoc scan buried after 50 PROPERLY CLOSED $(...) is still found",
      "cat <<EOF\n" + "".join("$(echo t%d) " % i for i in range(50)) + "$(du -sk ~) x\nEOF\necho done", GT, "block", 1.0)
deep = "echo " + "$(true " * 200 + "du -sk ~" + ")" * 200
t0 = time.perf_counter()
got = verdict(deep, GT)
took = time.perf_counter() - t0
print("SWEEP\t200 levels of \\$( ) with a scan at the bottom: BLOCK, not a give-up, in under 2s (%.3fs)\t1\t%d" % (took, 0 if got == "block" and took < 2 else 1))

# 7. A TOOL NAME IN DATA POSITION IS NOT THE TOOL (gate round 6): only the FIRST word in command position may name the
# program that runs; a search pattern, a filename, or any later operand that happens to spell du/find/mv/git/recurse/...
# is not a second command. This does not list examples, it locks the FORM: every scanner-family name (+ git, + the
# --directories value "recurse") x every data position around a genuinely non-recursive grep of ONE named file -> ALLOW.
TOOLWORDS = sorted(hsg.SCANNER_NAMES) + ["git", "recurse"]
DATAPOS = ["grep -n {w} /Users/athos/Downloads/onefile.txt", "grep {w} /Users/athos/Downloads/onefile.txt",
           "grep -e {w} /Users/athos/Downloads/onefile.txt", "grep -n foo /Users/athos/Downloads/{w}",
           "grep -n {w} {w} /Users/athos/Downloads/onefile.txt"]
cases = [(p.format(w=w), GT) for p in DATAPOS for w in TOOLWORDS]
sweep("data position: a scanner/git/recurse name as grep's pattern or filename (grep has no -r) -> ALLOW (it never ran)", cases, "allow")
# the control: the SAME names, in COMMAND position (word 0), still name the program and still recurse over a hot target
cases = [("%s -sk ~/Downloads" % w, GT) for w in sorted(hsg.ALWAYS | hsg.FIND | hsg.MOVE)]
sweep("data position control: the same names in COMMAND position still recurse -> BLOCK", cases, "block")

with open(SAMPLE_OUT, "w") as fh:
    for row in sample:
        fh.write(json.dumps(row) + "\n")
with open(BLOCKS_OUT, "wb") as fh:
    for cmd, cwd in allblocks:
        fh.write(cmd.encode() + b"\0" + cwd.encode() + b"\0")
PYEOF
python3 -I "$SCRATCH/sweeps.py" "$ENGINE" "$SCRATCH/sample.jsonl" "$SCRATCH/sweep-blocks.bin" > "$SCRATCH/sweeps.out" 2> "$SCRATCH/sweeps.err"; SRC=$?
if [ "$SRC" -ne 0 ] || ! grep -q '^SWEEP' "$SCRATCH/sweeps.out"; then
  bad "sweep driver did not run (rc=$SRC): $(head -c 600 "$SCRATCH/sweeps.err")"
else
  while IFS=$'\t' read -r kind name total nfail; do
    if [ "$kind" = "SWEEP" ]; then
      if [ "$nfail" = "0" ]; then ok "sweep [$total cases]: $name"
      else bad "sweep: $name -- $nfail of $total failed"; fi
    fi
  done < <(grep '^SWEEP' "$SCRATCH/sweeps.out")
  grep '^FAILCASE' "$SCRATCH/sweeps.out" | head -40 | while IFS=$'\t' read -r _ name cmd cwd got; do echo "        first failures: $name  $cmd  $cwd  $got"; done
fi

# the sampled sweep cases, THROUGH THE WRAPPER: the in-process sweeps prove the classifier, this proves the bash prefilter never
# stands between a shape the classifier blocks and the block (a non-hot cwd, so the prefilter is the only thing that could let it by)
echo ""
echo "-- sweep samples THROUGH the wrapper (bash 3.2 prefilter + classifier) --"
NSAMPLE=0; NMISS=0; MISSED=""
if [ -s "$SCRATCH/sample.jsonl" ]; then
  while IFS= read -r row; do
    cmd="$(printf '%s' "$row" | jq -r .cmd)"; cwd="$(printf '%s' "$row" | jq -r .cwd)"
    run_guard "$cmd" "$cwd"
    NSAMPLE=$((NSAMPLE+1))
    if [ "$RC" -ne 2 ]; then NMISS=$((NMISS+1)); MISSED="$MISSED
        rc=$RC cwd=[$cwd] cmd=[${cmd:0:120}]"; fi
  done < "$SCRATCH/sample.jsonl"
fi
[ "$NSAMPLE" -ge 60 ] && ok "the sampled set is big enough to mean something ($NSAMPLE cases)" || bad "sample too small: $NSAMPLE"
[ "$NMISS" -eq 0 ] && ok "every sampled BLOCK of the engine is also a BLOCK of the wrapper ($NSAMPLE of $NSAMPLE)" || bad "$NMISS of $NSAMPLE engine blocks were let through by the wrapper:$MISSED"

# The exhaustive half: the wrapper's OWN prefilter code (cut out of the file, so it cannot drift from what runs) over EVERY case the
# classifier blocked -- the whole spec must-block corpus and every block the sweeps checked (the huge option sweep at stride 3) -- with a
# non-hot cwd, so the prefilter is the only thing that can let one through. A miss is a block that is silently switched off.
echo ""
echo "-- the wrapper's prefilter never stands between a classifier block and the block (every blocked case, one bash process) --"
{
  echo 'note() { :; }'
  echo 'prefilter() { local tool=Bash cmd="$1" cwd="$2"'
  awk '/^# ---- 2\. cheap superset prefilter/{f=1} /^# ---- 3\. exact classifier/{f=0} f' "$GUARD" | sed 's/exit 0/return 0/g'
  echo '  return 99; }'
  cat <<'HARNESS'
n=0; miss=0
for f in "$@"; do
  while IFS= read -r -d '' cmd && IFS= read -r -d '' cwd; do
    [ -n "$cwd" ] || cwd=/Users/athos/gt
    n=$((n+1))
    prefilter "$cmd" "$cwd"; rc=$?
    if [ "$rc" -ne 99 ]; then miss=$((miss+1)); [ "$miss" -le 12 ] && printf 'MISS cwd=[%s] cmd=[%s]\n' "$cwd" "${cmd:0:150}"; fi
  done < "$f"
done
echo "RESULT n=$n miss=$miss"
HARNESS
} > "$SCRATCH/prefilter-harness.sh"
DIFF_OUT="$(env HOME_SCAN_GUARD_HOME=/Users/athos "$HOOK_BASH" "$SCRATCH/prefilter-harness.sh" "$SCRATCH/spec-blocks.bin" "$SCRATCH/sweep-blocks.bin" 2>&1)"
DN="$(printf '%s\n' "$DIFF_OUT" | sed -n 's/^RESULT n=\([0-9]*\) miss=.*/\1/p')"; DM="$(printf '%s\n' "$DIFF_OUT" | sed -n 's/^RESULT n=[0-9]* miss=\([0-9]*\)/\1/p')"
if [ -n "$DN" ] && [ "${DN:-0}" -ge 5000 ] && [ "$DM" = "0" ]; then ok "prefilter differential: $DN classifier-BLOCKED cases (spec corpus + sweeps), 0 let through by the prefilter"
else bad "prefilter differential: n=${DN:-?} miss=${DM:-?} (a block the prefilter switches off): $(printf '%s\n' "$DIFF_OUT" | grep '^MISS' | head -5)"; fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- FORM PIN: the parts of the old design that the gate kept finding holes in must not come back --"
# ─────────────────────────────────────────────────────────────────────────
# Gate rounds 1-4 (ga-02cqk4): a table of which option takes a value / which wrapper takes which option / which tool's depth flag
# stops the walk / which variable is "tainted" decided what the guard read, and every wrong or missing entry was a silent allow.
# The engine now reads EVERY non-dash word of a scanner's command as a candidate path and never asks what an option means.
# If one of those mechanisms is re-added, this fails and points here; re-adding one needs a reason stronger than "a case slipped".
if grep -nE '(^|[^A-Za-z_])(TOOL_OPTS|WRAPPER_OPTS|WRAPPER_POSITIONALS|TRAVERSAL_DEPTH|SEARCH_STDIN|valued_short|valued_long|parse_args|_all_starts|pipe_home|HDYN|command_lists_home|script_lists_home|looks_like_file|DIR_EXTENSIONS)([^A-Za-z_]|$)' "$ENGINE" | grep -v '^[0-9]*:[[:space:]]*#' | grep -v '^[0-9]*:[[:space:]]*"""' >/dev/null; then
  bad "the engine mentions a mechanism that gate rounds 1-4 removed: $(grep -nE '(TOOL_OPTS|WRAPPER_OPTS|WRAPPER_POSITIONALS|TRAVERSAL_DEPTH|SEARCH_STDIN|valued_short|valued_long|parse_args|_all_starts|pipe_home|HDYN|command_lists_home|script_lists_home|looks_like_file|DIR_EXTENSIONS)' "$ENGINE" | head -3 | cut -c1-160)"
else
  ok "the engine has no option table, wrapper table, depth table, stdin-taint or is-it-a-file heuristic"
fi
CODELINES="$(python3 -I - "$ENGINE" <<'CLEOF'
import ast, sys
src = open(sys.argv[1]).read()
skip = set()
for node in ast.walk(ast.parse(src)):
    if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef)) and node.body and isinstance(node.body[0], ast.Expr) \
            and isinstance(getattr(node.body[0], "value", None), ast.Constant) and isinstance(node.body[0].value.value, str):
        skip.update(range(node.body[0].lineno, node.body[0].end_lineno + 1))
print(sum(1 for i, l in enumerate(src.splitlines(), 1) if l.strip() and not l.strip().startswith("#") and i not in skip))
CLEOF
)"
[ "${CODELINES:-9999}" -le 760 ] && ok "the engine stays small enough to review in one sitting ($CODELINES code lines, docs and comments excluded; the design it replaced had 1363)" || bad "the engine grew to ${CODELINES:-?} code lines (limit 760): a guard that cannot be read cannot be trusted"

# ─────────────────────────────────────────────────────────────────────────
# The classifier can also fail OPEN on its OWN bug, silently (a caught exception is an allow). A NameError
# once turned 71 must-block cases into silent allows here -- this is the assertion that makes that loud.
echo ""
echo "-- the engine never failed open on its own bug --"
if grep -q 'ENGINE-ERROR' "$LOG" 2>/dev/null; then
  bad "engine internal error(s) fail-opened during this run: $(grep 'ENGINE-ERROR' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no ENGINE-ERROR line in the guard log after the whole run ($(grep -c 'BLOCKED' "$LOG" 2>/dev/null) BLOCKED lines)"
fi
# ...nor did the WRAPPER degrade under a case that was supposed to be decided by the classifier: an expect_allow can
# pass because the wrapper timed out or lost its interpreter and fell open, not because the classifier said allow.
if grep -q 'UNGUARDED' "$LOG" 2>/dev/null; then
  bad "the wrapper degraded (fell open) during the main corpus, so an allow may not be the classifier's verdict: $(grep 'UNGUARDED' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no UNGUARDED line in the guard log after the whole run (every verdict above came from the classifier)"
fi
if grep -q 'GAVE-UP' "$LOG" 2>/dev/null; then
  bad "the classifier gave up on a case of the main corpus (an ALLOW logged after the fact): $(grep 'GAVE-UP' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no GAVE-UP line: the classifier never abandoned a command (it has no cap that ends in an allow)"
fi

# ─────────────────────────────────────────────────────────────────────────
# LIVE (opt-in): the script working in isolation proves nothing about DISPATCH -- ga-7j1yu found a
# whole class of hook config that looked right and never fired. This runs a real nested `claude -p`
# whose project settings.json was written by home-scan-guard-activate.sh (so it also proves the
# "^Bash$" matcher dispatches), points ~ at a SCRATCH fake home (HOME_SCAN_GUARD_HOME) so that even
# if the guard failed to fire the model's `du` would only walk scratch directories, and checks the
# guard's own log + the tool result the model got back. Costs one short haiku session.
# ─────────────────────────────────────────────────────────────────────────
if [ "${HOME_SCAN_GUARD_LIVE:-0}" = "1" ]; then
  echo ""
  echo "-- LIVE: real Claude Code hook dispatch (nested claude -p, scratch fake home) --"
  LIVE="$SCRATCH/live"; FH="$LIVE/fakehome"; PROJ="$LIVE/proj"
  mkdir -p "$FH/Downloads" "$FH/Documents" "$FH/gt" "$PROJ/.claude"
  echo hello > "$FH/Downloads/a.txt"; echo hello > "$FH/gt/b.txt"
  echo '{}' > "$PROJ/.claude/settings.json"
  HOME_SCAN_GUARD_SCRIPT="$GUARD" bash "$HERE/home-scan-guard-activate.sh" "$PROJ/.claude/settings.json" >/dev/null 2>&1
  jq -e '.hooks.PreToolUse[0].matcher == "^Bash$"' "$PROJ/.claude/settings.json" >/dev/null \
    && ok "live: project settings.json registers the guard through home-scan-guard-activate.sh (matcher ^Bash\$)" \
    || bad "live: activation did not produce the ^Bash\$ entry: $(cat "$PROJ/.claude/settings.json")"
  BLOCK_CMD="cd $FH && for d in \$(ls -A); do du -xsk \"\$d\"; done"
  ALLOW_CMD="du -xsk $FH/gt"
  PROMPT="Call the Bash tool exactly twice, as two separate tool calls, running each command below verbatim. Do not modify them, do not run anything else, and do not retry a command that fails or is blocked. Command 1: ${BLOCK_CMD}   Command 2: ${ALLOW_CMD}   Afterwards reply with one short sentence."
  : > "$LIVE/log"
  ( cd "$PROJ" && env GC_AGENT=live-test HOME_SCAN_GUARD_HOME="$FH" HOME_SCAN_GUARD_LOG="$LIVE/log" \
      timeout 300 claude -p "$PROMPT" --model haiku --dangerously-skip-permissions --setting-sources project \
        --no-session-persistence --disable-slash-commands --output-format stream-json --verbose \
        > "$LIVE/out.jsonl" 2> "$LIVE/err" ); LRC=$?
  echo "  (nested claude exit=$LRC, $(wc -l < "$LIVE/out.jsonl" | tr -d ' ') stream events)"
  if grep -q 'BLOCKED' "$LIVE/log" && grep -q "fakehome" "$LIVE/log"; then
    ok "live: the guard's own log recorded a BLOCK for the incident-shaped command run by the real session"
  else
    bad "live: no BLOCKED line in the guard log -- the hook did not fire, or fired without blocking: log=[$(cat "$LIVE/log")]"
  fi
  if jq -e -s '[.[] | select(.type == "user") | (.message.content // [])[]? | select(.type == "tool_result") | (.content | tostring)] | any(contains("home-scan-guard: BLOCKED"))' "$LIVE/out.jsonl" >/dev/null 2>&1; then
    ok "live: the model received the guard's message as the tool result (so it learns the alternative)"
  else
    bad "live: the block message never reached the model's tool result (see $LIVE/out.jsonl)"
  fi
  if jq -e -s '[.[] | select(.type == "user") | (.message.content // [])[]? | select(.type == "tool_result") | (.content | tostring)] | any(contains("fakehome/gt"))' "$LIVE/out.jsonl" >/dev/null 2>&1; then
    ok "live: the ordinary command (du -xsk on a non-protected dir) ran and returned its output"
  else
    bad "live: positive control failed -- the allowed command did not run (see $LIVE/out.jsonl)"
  fi
  [ "$(grep -c 'BLOCKED' "$LIVE/log")" = "1" ] && ok "live: exactly one block -- the ordinary command was not blocked" || bad "live: expected exactly 1 BLOCKED log line, got $(grep -c 'BLOCKED' "$LIVE/log")"
  if [ "${HOME_SCAN_GUARD_LIVE_KEEP:-0}" = "1" ]; then cp "$LIVE/out.jsonl" /tmp/home-scan-guard-live.out.jsonl; cp "$LIVE/log" /tmp/home-scan-guard-live.log; echo "  (kept /tmp/home-scan-guard-live.out.jsonl + .log)"; fi
fi

echo ""
echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
