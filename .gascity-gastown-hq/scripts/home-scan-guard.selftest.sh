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
# The must-block corpus was written BEFORE the guard existed (TDD: it failed with the
# guard missing); the must-allow corpus is the other half of the contract -- a guard that
# blocks every Bash call of every agent is worse than the problem (bead: "FAIL-OPEN").
#
# TEST: bash home-scan-guard.selftest.sh
#       HOME_SCAN_GUARD_LIVE=1 bash home-scan-guard.selftest.sh   # also proves REAL hook
#                                                                 # dispatch via a nested `claude -p`
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/home-scan-guard.sh"
# The installed hook runs `exec /bin/bash "$P"` (home-scan-guard-activate.sh): macOS bash 3.2, not the newer bash
# this file is probably running under. The wrapper has to be exercised under exactly that shell -- it passed on
# bash 5 while nothing pinned that the hook's own interpreter agrees.
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
  run_guard "$2" "${3-}"
  if [ "$RC" -eq 2 ] && [[ "$ERR" == *TCC* ]]; then ok "BLOCK  $1"
  else bad "BLOCK  $1 -- expected rc=2 + TCC message, got rc=$RC err=[${ERR:0:160}] cmd=[$2] cwd=[${3-}]"; fi
}
expect_allow() {  # name command [cwd]
  run_guard "$2" "${3-}"
  if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then ok "ALLOW  $1"
  else bad "ALLOW  $1 -- expected rc=0 + silent, got rc=$RC err=[${ERR:0:160}] cmd=[$2] cwd=[${3-}]"; fi
}

if [ ! -f "$GUARD" ]; then
  echo "FATAL: guard not found at $GUARD"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
echo "-- the incident (ga-6cyp1l, 26/09 14:52), verbatim --"
# ─────────────────────────────────────────────────────────────────────────
INCIDENT='cd /Users/athos && for d in $(ls -A); do [ "$d" = "Library" ] && continue; timeout 60 du -xsk "$d" 2>/dev/null; done | sort -rn | head -25'
expect_block "incident command exactly as run by the batista crew" "$INCIDENT"
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
# cd to home / protected, then relative scan (the bead: "`cd` para o home seguido de loop/glob")
expect_block "cd ~ && du *"                'cd ~ && du -sk *'
expect_block "cd ~; find ."                'cd ~; find . -name x'
expect_block "cd \$HOME && for d in *"     'cd $HOME && for d in *; do du -sk "$d"; done'
expect_block "cd /Users/athos && ls -A | while read" 'cd /Users/athos && ls -A | while read d; do du -sk "$d"; done'
expect_block "cd ~ (bare) then du ."       'cd; du -sk .'
expect_block "cd ~/Downloads && find ."    'cd ~/Downloads && find .'
expect_block "pushd ~ then du ."           'pushd ~ >/dev/null; du -sk .'
expect_block "subshell (cd ~ && du .)"     '(cd ~ && du -sk .)'
expect_block "cd ~ && du (no operand)"     'cd ~ && du -sk'
expect_block "cd ~ && rg pat (no path)"    'cd ~ && rg foo'
expect_block "cd ~ && grep -r pat ."       'cd ~ && grep -r foo .'
# home listing feeding a scanner
expect_block "ls ~ | while read: du ~/\$d" 'ls ~ | while read d; do du -sk ~/"$d"; done'
expect_block "ls ~ | while read: du \$d"   'ls ~ | while read d; do du -sk "$d"; done'
expect_block "du \$(ls ~)"                 'du -sk $(ls ~)'
expect_block "du \$(ls -A /Users/athos)"   'du -sk $(ls -A /Users/athos)'
expect_block "du backtick ls ~"            'du -sk `ls ~`'
expect_block "for d in ~/*; du \$d"        'for d in ~/*; do du -sk "$d"; done'
expect_block "for d in \$(ls ~); du ~/\$d" 'for d in $(ls ~); do du -sk ~/$d; done'
expect_block "ls ~ | xargs du"             'ls ~ | xargs du -sk'
expect_block "find ~ -maxdepth 1 | xargs du" 'find ~ -maxdepth 1 | xargs du -sk'
# wrappers and indirection
expect_block "timeout 60 du ~"             'timeout 60 du -xsk ~'
expect_block "nice du ~"                   'nice -n 10 du -sk ~'
expect_block "env VAR=1 du ~"              'env FOO=1 du -sk ~'
expect_block "time du ~"                   'time du -sk ~'
expect_block "bash -c 'du ~'"              "bash -c 'du -sk ~'"
expect_block "sh -c \"find ~\""            'sh -c "find ~ -maxdepth 1"'
expect_block "zsh -lc"                     "zsh -lc 'du -sk ~/Downloads'"
expect_block "eval du ~"                   "eval 'du -sk ~'"
expect_block "var alias H=\$HOME; du \$H"  'H=$HOME; du -sk $H'
expect_block "var to Downloads"            'D=~/Downloads; find "$D" -type f'
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
expect_block "rg pat /"                      'rg foo /'
expect_block "grep -r pat /Users"            'grep -r foo /Users'
expect_block "ls -R /Users"                  'ls -R /Users'
# a glob / unknown component under /Users expands to $HOME (or a folder in it)
expect_block "du /Users/*"                   'du -sk /Users/*'
expect_block "du /Users/*/Downloads"         'du -sk /Users/*/Downloads'
expect_block "ls /Users/*/Desktop"           'ls -la /Users/*/Desktop'
expect_block "du /Users/at* (glob matches \$HOME)" 'du -sk /Users/at*'
expect_block "find /Users/\$u/Documents (unknown user)" 'find /Users/$u/Documents -name x'
# spellings of $HOME that only NORMALISE to it
expect_block "find ~/."                      'find ~/. -name x'
expect_block "du ~//"                        'du -sk ~//'
expect_block "du ~/./"                       'du -sk ~/./'
expect_block "cd .. && du * (from a repo dir up to \$HOME)" 'cd .. && du -sk *' /Users/athos/gt
expect_block "du ../.. (relative up to \$HOME)" 'du -sk ../..' /Users/athos/gt/foo
# taint mechanisms, each with the cwd AWAY from $HOME so nothing else can catch them
expect_block "taint via for-list \$(ls ~), cwd elsewhere"  'for d in $(ls ~); do du -sk "$d"; done' /Users/athos/gt
expect_block "taint via while-read fed by ls ~, cwd elsewhere" 'ls ~ | while read -r d; do du -sk "$d"; done' /Users/athos/gt
expect_block "taint via a variable holding a home listing"  'L=$(ls ~); for d in $L; do du -sk "$d"; done' /Users/athos/gt
expect_block "taint via for-list ~/*, cwd elsewhere"        'for d in ~/*; do du -sk "$d"; done' /Users/athos/gt
# names are case-insensitive on the default macOS volume
expect_block "du ~/downloads (lowercase)"    'du -sk ~/downloads'
expect_block "du ~/DOCUMENTS"                'du -sk ~/DOCUMENTS'
expect_block "du ~/library/cloudstorage"     'du -sk ~/library/cloudstorage'
# brace / glob expansion under $HOME
expect_block "du ~/{gt,Downloads}"           'du -sk ~/{gt,Downloads}'
expect_block "du ~/D* (matches Documents)"   'du -sk ~/D*'
expect_block "du ~/.* (hidden entries incl .Trash)" 'du -sk ~/.*'
expect_block "ls ~/.Trash"                   'ls -la ~/.Trash'
expect_block "du Photos library (a dir with an extension)" 'du -sk ~/Pictures/Photos\ Library.photoslibrary'
expect_block "du Group Containers"           'du -sk ~/Library/Group\ Containers'
expect_block "bash -c with \$HOME in double quotes" 'bash -c "du -sk $HOME"'
expect_block "du -d 1 (numeric option value) with cwd=\$HOME" 'du -d 1 -h' /Users/athos
# implicit cwd taken from the hook JSON
expect_block "find . with cwd=\$HOME"        'find . -name x'               /Users/athos
expect_block "du (no operand) cwd=Downloads" 'du -sk'                        /Users/athos/Downloads
expect_block "rg pat cwd=Documents"          'rg foo'                        /Users/athos/Documents
expect_block "grep -r pat . cwd=\$HOME"      'grep -r foo .'                 /Users/athos
expect_block "du * cwd=\$HOME"               'du -sk *'                      /Users/athos
expect_block "ls -R cwd=Desktop"             'ls -R'                         /Users/athos/Desktop
expect_block "for d in * cwd=\$HOME"         'for d in *; do du -sk "$d"; done' /Users/athos

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate round 1 (ga-02cqk4 attempt 1/3): the two blockers, as the reviewer reproduced them --"
# ─────────────────────────────────────────────────────────────────────────
# BLOCKER 1: the "depth <= 2 never reaches a protected folder" exemption for an ANCESTOR (/, /Users) is
# true for the flags that STOP THE WALK (find -maxdepth, tree -L, fd/rg --max-depth) and false for du -d /
# --max-depth and dust -d, which only limit what is PRINTED: du still opens the whole subtree to add the
# sizes up. `du -d 1 -h /` is the most natural "what is eating my disk" query there is.
expect_block "du -d 1 -h /Users (depth limits the printout, not the walk)" 'du -d 1 -h /Users'
expect_block "du -d 2 /"                    'du -d 2 /'
expect_block "du -h -d1 /"                  'du -h -d1 /'
expect_block "du --max-depth=1 /Users"      'du --max-depth=1 /Users'
expect_block "du --max-depth 1 /"           'du --max-depth 1 /'
expect_block "dust -d 1 /Users"             'dust -d 1 /Users'
expect_block "gdu -d 1 /"                   'gdu -d 1 /'
expect_block "du -d 1 -h \$HOME (the control the guard already had)" 'du -d 1 -h /Users/athos'
expect_block "ls -R -L 2 /Users (ls has no depth flag: -L is 'follow symlinks')" 'ls -R -L 2 /Users'
# a depth flag that DOES stop the walk only excuses an ancestor if every stated limit is small and readable
expect_block "tree -L 2 -L 9 / (the tools disagree on which occurrence wins)" 'tree -L 2 -L 9 /'
expect_block "find / -maxdepth 1 -maxdepth 6"         'find / -maxdepth 1 -maxdepth 6 -name x'
expect_block "tree -L \$N / (a limit the text does not show)" 'tree -L $N /'
expect_block "find / -maxdepth \$N"                   'find / -maxdepth $N -name x'
# BLOCKER 2: du, dust, gdu, ncdu and tree used ONE valued-flag table, so a letter that takes a value for one
# tool and is a plain switch for another swallowed the PATH as its "value"; the operand list came out empty
# and the guard checked the cwd instead. In real du -L/-P/-n are switches; in real tree -d/-t/-n are switches.
expect_block "tree -d ~/Downloads (-d = dirs only)"   'tree -d ~/Downloads'
expect_block "tree -t ~/Documents (-t = sort by mtime)" 'tree -t ~/Documents'
expect_block "tree -n ~/Desktop (-n = no colour)"     'tree -n ~/Desktop'
expect_block "du -L ~/Downloads"            'du -L ~/Downloads'
expect_block "du -sL ~/Downloads"           'du -sL ~/Downloads'
expect_block "du -hP ~/Documents"           'du -hP ~/Documents'
expect_block "du -P ~"                      'du -P ~'
expect_block "du -n ~/Pictures"             'du -n ~/Pictures'
expect_block "gdu -n ~ (gdu is du here; -n is a switch)" 'gdu -n ~'
expect_block "dust -P ~/Documents"          'dust -P ~/Documents'
expect_block "the swallowed word is kept even when another operand follows" 'du -L ~/Downloads ~/gt'
expect_block "du -L on a hot operand behind a safe one" 'du -L ~/gt ~/Downloads'
# the same shape one tool over: BSD find takes options BEFORE the path, and the parser stopped at the first one it
# did not know, so the path after it was read as "no operand" and the cwd was checked instead
expect_block "find -f ~/Downloads (BSD: -f names the tree to walk)" 'find -f ~/Downloads -name x'
expect_block "find -Hx ~/Downloads (BSD clusters its option letters)" 'find -Hx ~/Downloads -name x'
expect_block "find -EX ~/Documents"         'find -EX ~/Documents -name x'
expect_block "find -O3 ~/Downloads (GNU optimiser level)" 'find -O3 ~/Downloads -name x'
expect_block "find -D tree ~/Downloads (GNU debug option takes a value)" 'find -D tree ~/Downloads -name x'
expect_block "find -H ~/Downloads"          'find -H ~/Downloads -name x'

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate round 1: the non-blocking findings, fixed with the class --"
# ─────────────────────────────────────────────────────────────────────────
# a trailing slash is PROOF of a directory: a dotted directory name is not "one named file"
expect_block "du a dotted dir with a trailing slash"    'du -sk ~/Downloads/jdk-17.0.2/'
expect_block "cp -r a dotted dir with a trailing slash" 'cp -r ~/Documents/proj.v2/ /tmp/x'
expect_block "rsync -a a dotted dir with a trailing slash" 'rsync -a ~/Downloads/data.bak/ /tmp/x/'
expect_block "tar c a dotted dir with a trailing slash" 'tar czf /tmp/x.tgz ~/Documents/site.2024/'
# ...and an explicit recursion flag means the operand is walked, so "it has an extension" proves nothing
expect_block "cp -r ~/Downloads/x.pdf (explicit recursion)"   'cp -r ~/Downloads/x.pdf /tmp/x'
expect_block "rsync -a ~/Documents/proj.v2 (dotted name)"     'rsync -a ~/Documents/proj.v2 /tmp/x'
expect_block "zip -r ~/Documents/site.2024"                   'zip -r /tmp/x.zip ~/Documents/site.2024'
expect_block "tar c a dotted name"                            'tar czf /tmp/x.tgz ~/Documents/site.2024'
# an option VALUE can carry the path too: tar walks whatever -C / --directory points at, spelled any way
expect_block "tar --directory=\$HOME ."              'tar czf /tmp/x.tgz --directory=/Users/athos .'
expect_block "tar -C/Users/athos . (attached)"      'tar czf /tmp/x.tgz -C/Users/athos .'
expect_block "tar --directory ~/Downloads ."        'tar czf /tmp/x.tgz --directory ~/Downloads .'
expect_block "tar -czC \$HOME (C last in a cluster)" 'tar -czC /Users/athos -f /tmp/x.tgz .'
expect_block "tar --directory=\$HOME with an expansion" 'tar czf /tmp/x.tgz --directory=$HOME .'
# ls -d does not list a directory operand -- but the SHELL expands a glob operand by listing it
expect_block "ls -d ~/Downloads/* (the shell lists Downloads)" 'ls -d ~/Downloads/*'
expect_block "ls -d ~/Documents/*.pdf"              'ls -d ~/Documents/*.pdf'
# a cd inside a subshell is scoped to it: what runs AFTER the subshell sees the outer cwd again
expect_block "subshell cd away then a relative scan of the real cwd (\$HOME)" '(cd /tmp && ls); du -sk *' /Users/athos
expect_block "nested subshells, the outer cwd is \$HOME again" '( (cd /tmp) ); du -sk *' /Users/athos
expect_block "subshell that closes before && then scans"       '(cd /tmp && true) && find . -name x' /Users/athos
expect_block "a cd on the left of a pipe runs in a subshell"    'cd /tmp | cat; du -sk *' /Users/athos
expect_block "a backgrounded cd runs in a subshell"             'cd /tmp & du -sk *' /Users/athos
# cd - / popd: the previous directory is TRACKED, not forgotten (a forgotten cwd behaves like a safe one)
expect_block "cd - returns to a hot dir, then a relative scan"       'cd ~/Downloads && cd /tmp && cd - && du -sk *' /Users/athos/gt
expect_block "pushd/popd back to \$HOME, then a relative scan"       'pushd /tmp >/dev/null; popd >/dev/null; du -sk *' /Users/athos
# ls -T is tree mode for eza/exa/lsd only; recursion through those is still recursion
expect_block "eza -T ~"                     'eza -T ~'
expect_block "eza --tree ~/Documents"       'eza --tree ~/Documents'
expect_block "exa -R ~"                     'exa -R ~'
expect_block "lsd --tree ~"                 'lsd --tree ~'
expect_block "eza -L 3 -T / (a depth that reaches ~/Desktop)" 'eza -L 3 -T /'
# the bash prefilter is a SUPERSET of the classifier: doubled slashes and /./ spell the same path
expect_block "du //Users/athos (doubled leading slash)"  'du -sk //Users/athos'
expect_block "find /Users//athos/Desktop"                'find /Users//athos/Desktop -type f'
expect_block "du /Users/./athos (a dot component)"       'du -sk /Users/./athos'
expect_block "find /Users/athos/./Desktop"               'find /Users/athos/./Desktop -type f'
expect_block "du /users/athos (case-insensitive volume)" 'du -sk /users/athos'
# found by a differential fuzz of the prefilter against the classifier (62 of 5658 blocked commands never reached it):
# a path that ends in "/" and is followed by a space is the directory itself, and an ancestor can be attached to an option
expect_block "find ~/ -name x (trailing slash, then more arguments)"  'find ~/ -name x'   /Users/athos/gt
expect_block "find /Users/athos/ -maxdepth 3"        'find /Users/athos/ -maxdepth 3 -name x' /Users/athos/gt
expect_block "rsync -a ~/ /tmp/x"                     'rsync -a ~/ /tmp/x'                     /Users/athos/gt
expect_block "mdfind -onlyin ~/ foo"                  'mdfind -onlyin ~/ foo'                  /Users/athos/gt
expect_block "cd ~/ && du -sk ."                      'cd ~/ && du -sk .'                      /Users/athos/gt
expect_block "tar -C/Users . (ancestor attached to the option)" 'tar czf /tmp/x.tgz -C/Users .' /Users/athos/gt
expect_block "tar -C/ ."                              'tar czf /tmp/x.tgz -C/ .'               /Users/athos/gt
expect_block "tar -C/Users/*/Desktop ."               'tar czf /tmp/x.tgz -C/Users/*/Desktop .' /Users/athos/gt

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate round 2 (ga-02cqk4 attempt 2/3): a fixed cap must never turn 'too big to analyse' into 'not hot' --"
# ─────────────────────────────────────────────────────────────────────────
# The classifier had fixed caps (brace alternatives, brace rounds, stacked wrappers) and each ended in the SAME silent exit 0
# that a genuinely safe command gets: no block, no log line. "Couldn't know" must not look like "knew it was fine". Now the
# unexpandable becomes an unknown VALUE (the way `~/$UNSET` already is, and unknown-under-~ is hot), and nothing is capped that
# does not have to be. The helper below asserts the LOG as well as the rc: Abort is exit 0, so an rc-only test cannot tell
# "blocked" from "gave up quietly".
ONE="$SCRATCH/one.log"
blocked_and_logged() {  # name command [cwd]
  : > "$ONE"
  hook_json "$2" "${3-}" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$ONE" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; local rc=$?
  if [ "$rc" -eq 2 ] && [ "$(grep -c 'result=BLOCKED' "$ONE")" = 1 ] && ! grep -qE 'result=(GAVE-UP|ENGINE-ERROR|UNGUARDED)' "$ONE"; then
    ok "BLOCK+LOG  $1"
  else
    bad "BLOCK+LOG  $1 -- rc=$rc, log=[$(cut -c1-200 "$ONE" | tr '\n' '|')] cmd=[${2:0:120}]"
  fi
}
ALT70="$(printf 'a%s,' $(seq 0 69))Desktop"
blocked_and_logged "brace: 125 words, 25 of them ~/Desktop (the reviewer's repro; the cap was 64)" 'du -sk ~/{Desktop,x,y,z,w}{,,,,}{,,,,}'
blocked_and_logged "brace: 71 alternatives, the last one ~/Desktop (the reviewer's second repro)"  "du -sk ~/{$ALT70}"
blocked_and_logged "wrappers: env x8 (the reviewer's repro; the budget was 8)"                  'env env env env env env env env du -sk ~/Desktop'
blocked_and_logged "wrappers: nice x9"                                                          'nice nice nice nice nice nice nice nice nice du -sk ~/Desktop'
# the SAME class one site over: the brace loop had a 6-round budget, and the 7th group was left unexpanded ("desktop{,}" is
# not a protected name). 7 two-way groups is exactly 64 items after round 6 -- under the alternatives cap, over the round cap.
blocked_and_logged "brace: 7 chained groups (the round budget, not the alternatives cap)"       'du -sk ~/{Desktop,x}{,}{,}{,}{,}{,}{,}'
blocked_and_logged "brace: 7 nested groups"                                                     'du -sk ~/{x,{x,{x,{x,{x,{x,{x,Desktop}}}}}}}'
blocked_and_logged "brace: a sequence expression ({D..D}esktop is Desktop)"                      'du -sk ~/{D..D}esktop'
expect_block "brace: {D..E}esktop"                          'du -sk ~/{D..E}esktop'
expect_block "brace (control): a sequence with a step, then .. still normalises" 'du -sk ~/{1..9..2}/../Desktop'
expect_block "brace: over the cap under ~/Library"          "du -sk ~/Library/{$ALT70,CloudStorage}"
expect_block "brace: over the cap, /Users/*-style ancestor" "du -sk /Users/{$ALT70}"
# ...and the cap must not become a blanket block: unknown under a SAFE parent is not hot
expect_allow "brace: 71 alternatives under ~/gt"            "du -sk ~/gt/{$ALT70}"
expect_allow "brace: 7 chained groups under ~/gt"           'du -sk ~/gt/{a,b}{,}{,}{,}{,}{,}{,}'
expect_allow "brace: a sequence under ~/gt"                 'du -sk ~/gt/{1..3}'
expect_allow "brace: a numeric sequence in a harmless command" 'echo {1..3}'
# stacking: no cap on how many wrappers sit in front of the scanner
expect_block "wrappers: 40 x env"                  "$(printf 'env %.0s' $(seq 1 40))du -sk ~/Desktop"
expect_block "wrappers: a mix of eight kinds"      'command exec nohup setsid time timeout 5 nice sudo du -sk ~/Desktop'
expect_block "wrappers: wrappers, then xargs"      'env env env env env env env env env xargs du -sk ~/Downloads'
expect_allow "wrappers: 40 x env before a SAFE scan" "$(printf 'env %.0s' $(seq 1 40))du -sk ~/gt"
# the command WORD is brace-expanded by the shell too: {du,ls} ~/Desktop runs `du ls ~/Desktop`
expect_block "command word: {du,ls} ~/Desktop"     '{du,ls} ~/Desktop'
expect_block "command word: du{,} ~/Desktop"       'du{,} ~/Desktop'
expect_block "command word: a wrapper inside the braces" '{env,du} -sk ~/Desktop'
expect_block "command word: 8 wrappers inside the braces" '{env,env,env,env,env,env,env,env,du} -sk ~/Desktop'
expect_allow "command word: {ls,-la} ~/gt"         '{ls,-la} ~/gt'
expect_allow "command word: {echo,hi}"             '{echo,hi}'
# tilde prefixes: ~athos is $HOME (the prefilter in the wrapper skipped it too), ~+ / ~- are $PWD / $OLDPWD
expect_block "tilde: ~athos/Desktop"               'du -sk ~athos/Desktop'
expect_block "tilde: ~athos (bare)"                'du -sk ~athos'
expect_block "tilde: find ~athos"                  'find ~athos -name x'
expect_block "tilde: ls ~athos/Downloads"          'ls ~athos/Downloads'
expect_block "tilde: ~+ is \$PWD (cwd ~/gt, one .. up is \$HOME)" 'du -sk ~+/../Desktop' /Users/athos/gt
expect_block "tilde (control): ~+ with cwd=Downloads"       'du -sk ~+' /Users/athos/Downloads
expect_allow "tilde: another user's home"          'du -sk ~someone/Desktop'
expect_allow "tilde: ~athos/gt"                    'du -sk ~athos/gt'
expect_allow "tilde: ~+ with cwd=~/gt"             'du -sk ~+' /Users/athos/gt
# stdin fed by a listing of $HOME: the incident (list $HOME, measure each entry) in the other standard spelling
G=/Users/athos/gt
expect_block "stdin: xargs du < <(ls ~)"           'xargs du -sk < <(ls ~)' $G
expect_block "stdin: xargs du <<< \"\$(ls ~)\""    'xargs du -sk <<< "$(ls ~)"' $G
expect_block "stdin: while read ...; done < <(ls ~)" 'while read -r d; do du -sk "$d"; done < <(ls ~)' $G
expect_block "stdin: IFS= read -r, ls -A"          'while IFS= read -r d; do du -sk "$d"; done < <(ls -A ~)' $G
expect_block "stdin (control): a bare ls with cwd=\$HOME"    'while read -r d; do du -sk "$d"; done < <(ls -A)' /Users/athos
expect_block "stdin: the listing is made after a cd" 'while read -r d; do du -sk "$d"; done < <(cd ~ && ls)' $G
expect_block "stdin: read ONE entry, then measure it" 'read -r d < <(ls ~); du -sk "$d"' $G
expect_block "stdin: read with no name (REPLY)"    'read -r < <(ls ~); du -sk "$REPLY"' $G
expect_block "stdin: mapfile, loop over the array" 'mapfile -t a < <(ls ~); for d in "${a[@]}"; do du -sk "$d"; done' $G
expect_block "stdin: readarray, measure the array" 'readarray -t a < <(ls ~); du -sk "${a[@]}"' $G
expect_block "stdin: mapfile with no name (MAPFILE)" 'mapfile -t < <(ls ~); du -sk "${MAPFILE[@]}"' $G
expect_block "stdin: a heredoc carrying the listing" $'xargs du -sk <<EOF\n$(ls ~)\nEOF' $G
INNER_LOOP='while read -r d; do du -sk "$d"; done < <(ls ~)'
expect_block "stdin: the same loop inside bash -c" "bash -c '$INNER_LOOP'" $G
expect_allow "stdin: the same loop over ~/gt"       'while read -r d; do du -sk "$d"; done < <(ls ~/gt)' $G
expect_allow "stdin: xargs du over ~/gt"            'xargs du -sk < <(ls ~/gt)' $G
expect_allow "stdin: mapfile of ~/gt"               'mapfile -t a < <(ls ~/gt); du -sk "${a[@]}"' $G
expect_allow "stdin: a loop fed by git"             'while read -r l; do du -sk "$l"; done < <(git ls-files)' $G
expect_allow "stdin: a listing of \$HOME read but no entry scanned" 'while read -r d; do echo "$d"; done < <(ls ~)' $G
# gate round 3: "stdin is a listing of $HOME" must survive the SHELL hop. `xargs -I{} sh -c 'du -sk "{}"'` is the incident with
# one more process in the middle: the placeholder ({} / -I str) and the positional parameters ($0, $1, "$@") of that inner shell ARE
# entries of $HOME, and the inner script used to be analysed as if nothing was feeding it (a static literal `{}` is not hot).
H=/Users/athos
expect_block "xargs sh -c: the incident, spelled with xargs + sh -c" \
  $'cd /Users/athos && ls -A | xargs -I{} sh -c \'timeout 60 du -xsk "{}" 2>/dev/null\' | sort -rn | head -25' $H
expect_block "xargs sh -c: ls -A, quoted placeholder"       $'ls -A | xargs -I{} sh -c \'du -sk "{}"\'' $H
expect_block "xargs sh -c: ls, bare placeholder"            $'ls | xargs -I{} sh -c \'du -sk {}\'' $H
expect_block "xargs sh -c: ls ~, placeholder under ~/"      $'ls ~ | xargs -I{} sh -c \'du -sk ~/{}\'' $G
expect_block "xargs sh -c: ls -d ~/*/ (absolute entries)"   $'ls -d ~/*/ | xargs -I{} sh -c \'du -sk "{}"\'' $G
expect_block "xargs sh -c: positional \$0 (-n1)"            $'ls -d ~/* | xargs -n1 sh -c \'du -sk "$0"\'' $G
expect_block "xargs sh -c: positional \$0, echo of ~/*"     $'echo ~/* | xargs -n1 sh -c \'du -sk "$0"\'' $G
expect_allow "(control) ~**/* is not \$HOME in bash: ~ + ** is no tilde prefix" $'ls -d ~**/* | xargs -n1 sh -c \'du -sk "$0"\'' $G
expect_block "xargs sh -c: printf of ~/*"                   $'printf \'%s\\n\' ~/* | xargs -I{} sh -c \'du -sk "{}"\'' $G
expect_block "xargs bash -c: the same"                      $'ls ~ | xargs -I{} bash -c \'du -sk "{}"\'' $G
expect_block "xargs sh -c: -I% (another replacement string)" $'ls ~ | xargs -I% sh -c \'du -sk "%"\'' $G
expect_block "xargs sh -c: -I {} (value is a separate word)" $'ls ~ | xargs -I {} sh -c \'du -sk "{}"\'' $G
expect_block "xargs sh -c: -i (GNU, default {})"            $'ls ~ | xargs -i sh -c \'du -sk {}\'' $G
expect_block "xargs sh -c: --replace=@@"                    $'ls ~ | xargs --replace=@@ sh -c \'du -sk "@@"\'' $G
expect_block "xargs sh -c: -J (BSD)"                        $'ls ~ | xargs -J @ sh -c \'du -sk @\'' $G
expect_block "xargs sh -c: positional \$1 after a name"     $'ls ~ | xargs -n1 sh -c \'du -sk "$1"\' _' $G
expect_block "xargs sh -c: \"\$@\" after a name"            $'ls ~ | xargs sh -c \'du -sk "$@"\' _' $G
expect_block "xargs sh -c: \${1} spelled with braces"       $'ls ~ | xargs -n1 sh -c \'du -sk "${1}"\' _' $G
expect_block "xargs sh -c: \$* after a name"                $'ls ~ | xargs sh -c \'du -sk $*\' _' $G
expect_block "xargs sh -c: the placeholder used twice, one use safe" $'ls ~ | xargs -I{} sh -c \'echo {}; du -sk {}\'' $G
expect_block "xargs sh -c: find on the entry"               $'ls ~ | xargs -I{} sh -c \'find {} -type f\'' $G
expect_block "xargs sh -c: ls -R on the entry"              $'ls ~ | xargs -I{} sh -c \'ls -R ~/{}\'' $G
expect_block "xargs sh -c: cd into the entry, then measure" $'ls ~ | xargs -I{} sh -c \'cd ~/{} && du -sk .\'' $G
expect_block "xargs sh -c: a wrapper between xargs and the shell" $'ls ~ | xargs -I{} timeout 5 sh -c \'du -sk "{}"\'' $G
expect_block "xargs sh -c: env, then the shell"             $'ls ~ | xargs -I{} env A=1 sh -c \'du -sk "{}"\'' $G
expect_block "xargs sh -c: bash -lc (clustered flags)"      $'ls ~ | xargs -I{} bash -lc \'du -sk "{}"\'' $G
expect_block "xargs sh -c: the scan is inside a \$( ) of the inner script" $'ls ~ | xargs -I{} sh -c \'du -sk "$(echo {})"\'' $G
expect_block "xargs sh -c: a shell inside the shell"        $'ls ~ | xargs -I{} sh -c "sh -c \'du -sk {}\'"' $G
expect_block "xargs sh -c: after a filter stage in the pipeline" $'ls ~ | grep -v x | xargs -I{} sh -c \'du -sk "{}"\'' $G
expect_block "xargs eval: the same hop through eval"        $'ls ~ | xargs -I{} eval "du -sk {}"' $G
expect_block "xargs sh -c: fed by a redirect, not a pipe"   $'xargs -I{} sh -c \'du -sk "{}"\' < <(ls ~)' $G
expect_block "xargs sh -c: fed by a here-string"            $'xargs -I{} sh -c \'du -sk "{}"\' <<< "$(ls ~)"' $G
# the same hop WITHOUT xargs: whatever tells the inner script "this is an entry of $HOME" has to cross `sh -c` / `eval` too --
# a $( ) written inside the -c string, a loop variable handed over as an argument, or one carried in by a prefix assignment
expect_block "hop: \$(ls ~) inside a double-quoted bash -c string"  $'bash -c "du -sk $(ls ~)"' $G
expect_block "hop: \$(ls ~) inside an eval string"                  $'eval "du -sk $(ls ~)"' $G
expect_block "hop: \$(ls -A) inside sh -c, cwd=\$HOME"              $'sh -c "du -sk $(ls -A)"' $H
expect_block "hop: a backtick listing inside sh -c"                 $'sh -c "du -sk `ls ~`"' $G
expect_block "hop: a listing among other \$( ) in the string"       $'sh -c "echo $(date); du -sk $(ls ~)"' $G
expect_block "hop: loop variable passed as \$1"                     $'for d in $(ls ~); do bash -c \'du -sk "$1"\' _ "$d"; done' $G
expect_block "hop: loop variable passed as \$0"                     $'for d in $(ls ~); do bash -c \'du -sk "$0"\' "$d"; done' $G
expect_block "hop: loop variable passed, read as \"\$@\""           $'for d in $(ls ~); do bash -c \'du -sk "$@"\' _ "$d"; done' $G
expect_block "hop: an explicit protected folder passed as \$1"      $'bash -c \'du -sk "$1"\' _ ~/Downloads' $G
expect_block "hop: loop variable carried by a prefix assignment"    $'for d in $(ls ~); do x="$d" sh -c \'du -sk "$x"\'; done' $G
expect_block "hop: loop variable carried by env NAME=VALUE"         $'for d in $(ls ~); do env x="$d" sh -c \'du -sk "$x"\'; done' $G
expect_block "hop: a prefix assignment of an explicit protected folder" $'x=~/Downloads sh -c \'du -sk "$x"\'' $G
expect_block "hop: the assignment carries a listing"                $'x="$(ls ~)" sh -c \'du -sk $x\'' $G
expect_allow "hop (control): \$(ls ~/gt) inside a bash -c string"   $'bash -c "du -sk $(ls ~/gt)"' $G
expect_allow "hop (control): a repo loop variable passed as \$1"    $'for d in $(ls ~/gt); do bash -c \'du -sk "$1"\' _ "$d"; done' $G
expect_allow "hop (control): a repo path passed as \$1"             $'bash -c \'du -sk "$1"\' _ ~/gt/docs' $G
expect_allow "hop (control): a prefix assignment of a repo path"    $'x=~/gt sh -c \'du -sk "$x"\'' $G
expect_allow "hop (control): \$(ls ~) inside -c, but only echoed"   $'sh -c "echo $(ls ~)"' $G
expect_allow "hop (control): a \$( ) that lists nothing of \$HOME"  $'sh -c "du -sk $(git rev-parse --show-toplevel)"' $G
expect_allow "hop (control): env with a plain value"                $'env A=1 sh -c \'du -sk ~/gt\'' $G
# gate round 3, the wrapper's prefilter: what the classifier blocks, the wrapper must not pass in silence. A glob / class / brace /
# backslash inside the FIRST component of an absolute path can still name /Users (or /Volumes), and a backslash before a protected
# name is the same folder (\D = D). The same roots also have a second spelling on macOS: /System/Volumes/Data/Users/...
# EVERY case below carries a cwd ($G): with none, the wrapper sends the command straight to the classifier (an empty cwd is "don't know"),
# so the PREFILTER -- the stage under test -- would never run and these would pass whether or not it had the hole.
expect_block "prefilter: glob in the first component (/U*/athos)"        'du -sk /U*/athos' $G
expect_block "prefilter: /U*/*"                                         'du -sh /U*/*' $G
expect_block "prefilter: ls -R /U*"                                     'ls -R /U*' $G
expect_block "prefilter: ? in /Us?rs"                                   'du -sk /Us?rs/athos' $G
expect_block "prefilter: a class, /[U]sers"                             'du -sk /[U]sers/athos/Desktop' $G
expect_block "prefilter: a brace list, /{Users,x}"                      'du -sk /{Users,x}/athos/Desktop' $G
expect_block "prefilter: find /Us?rs"                                   'find /Us?rs -name x' $G
expect_block "prefilter: backslash before the protected name (~/\\Desktop)"  'du -sk ~/\Desktop' $G
expect_block "prefilter: backslash, lower case (~/\\downloads)"         'du -sk ~/\downloads' $G
expect_block "prefilter: backslash under an absolute \$HOME"            'du -sk /Users/athos/\Desktop' $G
expect_block "prefilter: glob naming /Volumes (/Vol*)"                  'du -sk /Vol*' $G
expect_block "prefilter: ? naming /Volumes (/V?lumes/x)"                'du -sk /V?lumes/x' $G
expect_block "prefilter: /Vol*/x"                                       'du -sk /Vol*/x' $G
expect_block "prefilter: find /Volume?"                                 'find /Volume? -type f' $G
expect_block "firmlink: /System/Volumes/Data/Users/athos/Desktop"      'du -sk /System/Volumes/Data/Users/athos/Desktop' $G
expect_block "firmlink: /System/Volumes/Data/Users/athos"              'du -sk /System/Volumes/Data/Users/athos' $G
expect_block "firmlink: find /System/Volumes/Data (the whole data volume)" 'find /System/Volumes/Data -name x' $G
expect_block "firmlink: ls -R /System/Volumes/Data/Users"              'ls -R /System/Volumes/Data/Users' $G
expect_allow "prefilter (control): a glob in the first component that is not /Users" 'du -sk /usr/lib*' $G
expect_allow "prefilter (control): ls /tmp/*"                           'ls /tmp/*' $G
expect_allow "prefilter (control): find /usr/local/l*"                  'find /usr/local/l* -name x' $G
expect_allow "prefilter (control): a class over /opt"                   'grep -r foo /opt/homebrew/li?/' $G
expect_allow "prefilter (control): /Users/Shared/*"                     'ls /Users/Shared/*' $G
expect_allow "firmlink (control): the private tmp under the data volume" 'du -sk /System/Volumes/Data/private/tmp/x' $G
expect_allow "firmlink (control): /System/Library"                      'ls /System/Library' $G
# gate round 3, a false positive: with explicit path operands after it, a path-LIKE first operand of a searcher is the PATTERN
# (grep -rn "/Users/athos/Downloads" scripts/ searches scripts/ for that text). Only a lone operand (`rg ~`) is read as a path.
expect_allow "pattern that looks like a path, explicit dir after it (grep)"  'grep -rn "/Users/athos/Downloads" scripts/' $G
expect_allow "pattern that looks like a path, explicit dir after it (rg)"    "rg -n '/Users/athos/Documents' scripts/" $G
expect_allow "pattern /Volumes/ with two dirs after it (rg)"                 'rg -n "/Volumes/" scripts/ packs/' $G
expect_allow "pattern ~/Downloads (quoted) with a dir after it"              'grep -rn "~/Downloads" scripts/' $G
expect_allow "pattern \$HOME/Desktop (single-quoted) with a dir after it"    "rg -n '\$HOME/Desktop' docs/" $G
expect_allow "fd with a path-like pattern and a dir"                         "fd '/Users/athos/Downloads' scripts" $G
expect_block "pattern-looking first operand, but the path after it is protected" 'grep -rn "/Users/athos/Downloads" ~/Documents' $G
expect_block "(control) a lone path-like operand is still a path (rg ~)"    'rg ~' $G
expect_block "(control) a lone path-like operand is still a path (grep -r ~/Downloads)" 'grep -r ~/Downloads' $G
expect_block "(control) grep -r PATTERN ~/Downloads"                        'grep -r foo ~/Downloads' $G
expect_block "(control) rg -e PATTERN ~/Downloads"                          'rg -e foo ~/Downloads' $G
expect_allow "xargs sh -c (control): the listing is a repo dir, not \$HOME" $'ls ~/gt | xargs -I{} sh -c \'du -sk ~/gt/{}\'' $G
expect_allow "xargs sh -c (control): \$0 over a repo listing"  $'ls ~/gt | xargs -n1 sh -c \'du -sk "$0"\'' $G
expect_allow "xargs sh -c (control): fed by printf of names"   $'printf "a\\nb\\n" | xargs -I{} sh -c \'du -sk ~/gt/{}\'' $G
expect_allow "xargs sh -c (control): \$HOME listing, inner script scans nothing" $'ls ~ | xargs -I{} sh -c \'echo {}\'' $G
expect_allow "xargs sh -c (control): \$HOME listing, inner script only counts" $'ls ~ | xargs -I{} sh -c \'echo "{}" | wc -c\'' $G
expect_allow "xargs sh -c (control): \$HOME listing, inner scan of a repo dir that ignores the entry" $'ls ~ | xargs -I{} sh -c \'du -sk ~/gt\'' $G
expect_allow "xargs sh -c (control): \$0 of a \$HOME listing, inner script only echoes" $'ls ~ | xargs -n1 sh -c \'echo "$0"\'' $G
# a hook payload with NO cwd: a relative scan cannot be judged, so it goes to the classifier, which COUNTS it
: > "$ONE"
hook_json 'for d in $(ls -A); do du -sk "$d"; done' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$ONE" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q 'result=UNKNOWN-CWD' "$ONE" && ok "no cwd in the payload + a relative scan -> allowed but COUNTED (UNKNOWN-CWD), not silent" \
  || bad "no-cwd payload: rc=$RC log=[$(cat "$ONE")]"
: > "$ONE"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"for d in $(ls -A); do du -sk \"$d\"; done"},"cwd":null}' \
  | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$ONE" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q 'result=UNKNOWN-CWD' "$ONE" && ok "cwd:null in the payload is the same: counted" || bad "cwd:null payload: rc=$RC log=[$(cat "$ONE")]"

# The class, in-process: for EVERY size of every construct that used to have a cap, a hot value hidden in it is still a block,
# and the same construct over a safe target is still an allow (a cap that became a blanket block would be its own bug).
if [ -f "$HERE/home-scan-guard.py" ]; then
  CAPS_OUT="$(HSG_ENGINE="$HERE/home-scan-guard.py" python3 -I -S - <<'PY' 2>&1
import importlib.util, os
spec = importlib.util.spec_from_file_location("hsg", os.environ["HSG_ENGINE"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def verdict(cmd, cwd="/Users/athos/gt"):
    try:
        m.analyze(cmd, cwd, ["/Users/athos"])
    except m.Block:
        return "block"
    except m.Abort:
        return "gave-up"
    return "allow"

cases = []          # (cmd, must)
for n in range(2, 91):                                  # a brace list of n alternatives, the hot one first / middle / last
    names = ["a%d" % i for i in range(n - 1)]
    for pos in (0, (n - 1) // 2, n - 1):
        hot = names[:pos] + ["Desktop"] + names[pos:]
        cases.append(("du -sk ~/{%s}" % ",".join(hot), "block"))
    cases.append(("du -sk ~/gt/{%s}" % ",".join(names + ["docs"]), "allow"))
for k in range(1, 13):                                  # k chained two-way groups
    cases.append(("du -sk ~/{Desktop,x}" + "{,}" * (k - 1), "block"))
    cases.append(("du -sk ~/gt/{a,b}" + "{,}" * (k - 1), "allow"))
    cases.append(("du -sk ~/{Desktop,x}" + "{,,}" * (k // 3), "block"))          # three-way groups of nothing: still ~/Desktop
for k in range(1, 13):                                  # k nested groups
    cases.append(("du -sk ~/" + "{x," * (k - 1) + "{x,Desktop}" + "}" * (k - 1), "block"))
    cases.append(("du -sk ~/gt/" + "{x," * (k - 1) + "{x,docs}" + "}" * (k - 1), "allow"))
for tail in ("~/{D..D}esktop", "~/{D..E}esktop", "~/{1..9..2}/../Desktop", "~/{a..z}ownloads"):
    cases.append(("du -sk " + tail, "block"))
for tail in ("~/gt/{1..3}", "~/gt/{a..z}", "~/gt/f{01..12}.txt"):
    cases.append(("du -sk " + tail, "allow"))
wrappers = ["env", "nice", "command", "exec", "nohup", "setsid", "time", "sudo", "caffeinate", "arch", "timeout 5",
            "stdbuf -o0", "ionice -c 3", "env FOO=1", "nice -n 5", "command --"]
for w in wrappers:                                      # 1..60 stacked wrappers
    for depth in list(range(1, 25)) + [40, 60]:
        cases.append(((w + " ") * depth + "du -sk ~/Desktop", "block"))
        cases.append(((w + " ") * depth + "du -sk ~/gt", "allow"))
for depth in (1, 5, 9, 20):                             # the same behind the shell own word splitting (brace expansion of the command word)
    cases.append(("{" + "env," * depth + "du} -sk ~/Desktop", "block"))

wrong = [(c, must, verdict(c)) for c, must in cases if verdict(c) != must]
print("CAPS total=%d wrong=%d" % (len(cases), len(wrong)))
for c, must, got in wrong[:12]:
    print("  WRONG (want %s, got %s): %s" % (must, got, c[:110]))
PY
)"
  case "$CAPS_OUT" in
    "CAPS total="*" wrong=0"*) ok "class: no size of a brace list / chain / nest / wrapper stack hides a hot value, and none blocks a safe one (${CAPS_OUT%%$'\n'*})" ;;
    *) bad "class: a cap collapsed 'too big' into 'not hot' (or into a false block) -- $CAPS_OUT" ;;
  esac
fi

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
expect_allow "read the disk-growth logs"             'cat /Users/athos/gt/.gascity-gastown-hq/.gc/logs/disk-growth-20260926.txt'
expect_allow "read ONE file in Downloads (cat)"      'cat ~/Downloads/relatorio.pdf'
expect_allow "read ONE file in Downloads (pdftotext)" 'pdftotext ~/Downloads/x.pdf -'
expect_allow "read ONE file in Downloads (head)"     'head -5 ~/Downloads/x.csv'
expect_allow "read ONE file in Downloads (file)"     'file ~/Downloads/x.png'
expect_allow "read ONE file in Downloads (stat)"     'stat -f %z ~/Downloads/x.zip'
expect_allow "copy ONE file out of Downloads"        'cp ~/Downloads/x.pdf /tmp/x.pdf'
expect_allow "ls one named file in Downloads"        'ls -l ~/Downloads/x.pdf'
expect_allow "grep one named file in Downloads"      'grep -n foo ~/Downloads/x.txt'
# everyday repo / city work
expect_allow "find inside the repo (abs)"            "find /Users/athos/gt -name '*.sh' -maxdepth 4"
expect_allow "find inside the repo (~)"              "find ~/gt/.gascity-gastown-hq/scripts -name '*.sh'"
expect_allow "find . in a repo cwd"                  'find . -name x'                     /Users/athos/gt/whatsapp_automation
expect_allow "rg in a repo cwd"                      'rg foo'                             /Users/athos/gt/whatsapp_automation
expect_allow "rg with path in repo"                  'rg -n foo /Users/athos/gt/.gascity-gastown-hq/scripts'
expect_allow "grep -r in repo"                       'grep -rn foo /Users/athos/gt/.gascity-gastown-hq/scripts'
expect_allow "grep one file in ~"                    'grep foo ~/.zshrc'
expect_allow "ls the home dir itself"                'ls ~'
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
expect_allow "zip -r a repo dir"                     'zip -r /tmp/x.zip /Users/athos/gt/docs'
expect_allow "sibling that merely starts like a protected name" 'du -sk /Users/athos/gt/Downloads-archive'
expect_allow "a repo directory literally named Documents" 'find /Users/athos/gt/whatsapp_automation/docs/Documents -type f'
expect_allow "du a sibling user dir that is not \$HOME (static mismatch)" 'du -sk /Users/Shared'
expect_allow "glob under a repo dir"                 'ls /Users/athos/gt/*.sh'
expect_allow "loop var over ls of a repo dir (NOT tainted), cwd in the repo" 'for d in $(ls /Users/athos/gt); do du -sk "$d"; done' /Users/athos/gt/docs
expect_allow "read loop fed by something that is not a home listing" 'cat /Users/athos/gt/list.txt | while read -r d; do du -sk "$d"; done' /Users/athos/gt
expect_allow "brace expansion that stays in the repo" 'du -sk ~/{gt,.gastown}'
expect_allow "ls a Library folder that is not protected" 'ls ~/Library/Caches'
expect_allow "du a go build cache under Library/Caches" 'du -sk ~/Library/Caches/go-build'
expect_allow "du ONE file in Downloads (named, has an extension)" 'du -sk ~/Downloads/x.zip'
expect_allow "ls one file on the Desktop"            'ls -la ~/Desktop/x.txt'
expect_allow "tar -tf an archive in Downloads"       'tar -tf ~/Downloads/a.tar'
expect_allow "tar xf an archive in Downloads into /tmp" 'tar xf ~/Downloads/a.tar -C /tmp/x'
expect_allow "find / with a shallow depth (never reaches a protected folder)" 'find / -maxdepth 1 -name Users'
expect_allow "find under /usr/local"                 'find /usr/local -name libfoo.dylib'
expect_allow "ls / and ls /Users (not recursive)"    'ls / /Users'
expect_allow "df / and du of a non-home root"        'df -h / && du -xsk /private/tmp/claude-501'
expect_allow "command -v does not run the tool"      'command -v du'
expect_allow "xargs fed by something that is not a home listing" 'printf "a\nb\n" | xargs du -sk'
expect_allow "rg fed by a pipe is a stdin filter, not a scan of the cwd" 'git log --oneline | rg foo' /Users/athos
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
expect_allow "grep for the words in a repo file"     'grep -n "du -sk" /Users/athos/gt/CLAUDE.md'
expect_allow "python that merely prints"             'python3 -c "print(1)"'
expect_allow "cd ~ alone (nothing scanned)"          'cd ~ && git status'
expect_allow "empty-ish command"                     ':'
# gate round 1: what the fixes must NOT start blocking
expect_allow "du -d 1 on a repo dir (a depth flag with a non-hot operand)" 'du -d 1 -h ~/gt'
expect_allow "du -d 2 ~/.gastown"                    'du -d 2 ~/.gastown'
expect_allow "du --max-depth=1 on a repo dir"        'du --max-depth=1 /Users/athos/gt/docs'
expect_allow "dust -d 1 on a repo dir"               'dust -d 1 /Users/athos/gt'
expect_allow "du -sL / -hP / -n on a repo dir (they are switches)" 'du -sL ~/gt && du -hP ~/gt/docs && du -n ~/gt'
expect_allow "du -B / -t / -I with a value, on a repo dir"       'du -B 1024 -sk ~/gt && du -t 1M -sk ~/gt && du -I "*.log" -sk ~/gt'
expect_allow "tree -d / -t / -n on a repo dir (switches)"        'tree -d ~/gt/docs && tree -t -n ~/gt/docs'
expect_allow "tree -I pattern on a repo dir"         'tree -I node_modules ~/gt/docs'
expect_allow "tree -I pattern with the repo as cwd"  'tree -I node_modules' /Users/athos/gt
expect_allow "tree -L 2 / (the depth flag STOPS the walk)"       'tree -L 2 /'
expect_allow "tree -L 1 /Users"                      'tree -L 1 /Users'
expect_allow "tree -aL 2 / (clustered, the value is -L's)"       'tree -aL 2 /'
expect_allow "fd -d 1 . /Users (fd's depth flag stops the walk)" 'fd -d 1 . /Users'
expect_allow "rg --max-depth 1 pat /Users"           'rg --max-depth 1 foo /Users'
expect_allow "find /Users -maxdepth 2 -type d"       'find /Users -maxdepth 2 -type d'
expect_allow "eza -T -L 2 /Users (eza's level flag stops the walk)" 'eza -T -L 2 /Users'
expect_allow "eza -T on a repo dir"                  'eza -T ~/gt/docs'
expect_allow "BSD find option letters before a repo path" 'find -H /Users/athos/gt -name x && find -f /Users/athos/gt -name x && find -Hx ~/gt -name x && find -O3 /Users/athos/gt -name x'
expect_allow "ls -lT ~ (macOS: full timestamps, not tree mode)"  'ls -lT ~'
expect_allow "ls -laT /Users/athos"                  'ls -laT /Users/athos'
expect_allow "a cd inside a subshell does not leak out of it"    '(cd ~/Downloads && ls report.pdf); find . -name "*.sh"' /Users/athos/gt
expect_allow "a cd inside \$( ) does not leak out of it"         'x=$(cd ~/Downloads && pwd); find . -name "*.sh"' /Users/athos/gt
expect_allow "a cd on the left of a pipe does not leak out of it" 'cd ~/Downloads | cat; find . -name "*.sh"' /Users/athos/gt
expect_allow "cd - returns to where the command started"         'cd ~/Downloads && cd - && du -sk *' /Users/athos/gt
expect_allow "pushd/popd round trip through a hot dir"           'pushd ~/Downloads >/dev/null; popd >/dev/null; du -sk *' /Users/athos/gt
expect_allow "du ONE dotted-name file (no trailing slash, no recursion flag)" 'du -sk ~/Downloads/data.bak'
expect_allow "cp -r of a repo dir with a trailing slash"         'cp -r /Users/athos/gt/docs/ /tmp/docs/'
expect_allow "tar --directory / -C in every spelling, on a repo dir" 'tar czf /tmp/x.tgz --directory=/Users/athos/gt docs && tar czf /tmp/x.tgz -C/Users/athos/gt docs && tar -czC /Users/athos/gt -f /tmp/x.tgz docs'
expect_allow "ls -d on a protected dir itself (a stat, no listing)" 'ls -d ~/Downloads'
expect_allow "ls -d with a glob in a repo dir"                   'ls -d ~/gt/*'

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
for weird in "echo 'unterminated" 'echo "unterminated' 'echo $(unterminated' 'echo `unterminated' 'cat <<EOF' 'for d in' ')))' 'du -sk "$(' $'echo \x01\x02'; do
  expect_allow "unparseable but harmless: ${weird:0:24}" "$weird"
done
# a genuinely unparseable command that ALSO scans home is not something we can prove; it must not be an error either
run_guard "du -sk ~ 'unterminated"
[ "$RC" -eq 0 ] || [ "$RC" -eq 2 ] && ok "unterminated quote + scan -> a clean decision, never a crash (rc=$RC)" || bad "unterminated+scan: rc=$RC err=$ERR"
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
ENGINE="$HERE/home-scan-guard.py"
if [ -f "$ENGINE" ]; then
  printf 'garbage, not json' | env "${AGENT_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 0 ] && ok "engine: non-JSON stdin -> allow" || bad "engine non-JSON: rc=$RC"
  hook_json 'du -sk ~' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_HOME= HOME= python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 0 ] && ok "engine: no usable home -> allow (cannot classify, does not guess)" || bad "engine no-home: rc=$RC"
  deep="$(printf 'echo %s' "$(printf '$(%.0s' $(seq 1 30))")"
  hook_json "$deep" | env "${AGENT_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 0 ] && ok "engine: absurd nesting -> allow (gives up, never crashes or blocks)" || bad "engine deep nesting: rc=$RC"
  hook_json 'du -sk ~' | env "${AGENT_ENV[@]}" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 2 ] && ok "engine: direct call blocks the plain case (sanity for the three above)" || bad "engine direct sanity: rc=$RC"
fi
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

# The wrapper's OTHER exits that are not "nothing to see here" are counted as well. The header used to say "every way the
# wrapper can NOT run the classifier is counted" while two were silent: a payload jq could not parse, and an unusable $HOME.
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
if [ -f "$ENGINE" ]; then
  : > "$DEG"; printf '\377\376{"tool_name":"Bash"}' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" python3 -I -S "$ENGINE" >/dev/null 2>&1; RC=$?
  [ "$RC" -eq 0 ] && grep -q "result=GAVE-UP" "$DEG" && grep -q "not valid UTF-8" "$DEG" && ok "engine: stdin that is not valid UTF-8 -> allow, and logged (was swallowed by a bare except ValueError)" || bad "engine non-UTF-8: rc=$RC log=[$(cat "$DEG")]"
fi
# a cwd the guard cannot know (cd - with no history) is a THIRD state, not "not hot": the relative scan after it is allowed
# (fail-open is the contract) but COUNTED; a cwd it does know leaves the log empty
: > "$DEG"; hook_json 'cd - && du -sk *' /Users/athos/gt | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "result=UNKNOWN-CWD" "$DEG" && ok "cd - with no history then a relative scan -> allowed, but logged UNKNOWN-CWD (not silent)" || bad "unknown cwd not logged: rc=$RC log=[$(cat "$DEG")]"
: > "$DEG"; hook_json 'cd ~/gt && cd - && du -sk *' /Users/athos/gt | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$HOOK_BASH" "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$DEG" ] && ok "cd - with a KNOWN previous dir leaves the log empty" || bad "known cwd polluted the log: rc=$RC log=[$(cat "$DEG")]"

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
# no cwd in the payload is "don't know", not "not hot": a scan goes to the classifier (which counts it); a command with no scan tool
# still takes the fast path
spawned 'du -sk *' && ok "python IS spawned for a scan when the payload has no cwd" || bad "prefilter dropped a scan with no cwd"
spawned 'git status --short' && bad "python spawned for git status with no cwd" || ok "fast path with no cwd: a command with no scan tool"
spawned 'du -sk ~athos/Desktop' /Users/athos/gt && ok "python IS spawned for ~athos/Desktop (the prefilter reads ~name)" || bad "prefilter missed ~athos"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- CLASS check: no option letter can hide a hot operand (the engine, in-process, every letter) --"
# ─────────────────────────────────────────────────────────────────────────
# Blocker 2 was one instance of a class: a parser that decides for the tool which words are OPTIONS' values can
# swallow the path. Rather than pin the letters the reviewer happened to try, walk EVERY letter and digit, alone and
# clustered, for every tool that shares the du-style option parsing, with the hot operand first, last and alone. A
# letter that really takes a value ("du -B ~/Downloads") is still a block: the swallowed word stays a candidate.
if [ -f "$HERE/home-scan-guard.py" ]; then
  CLASS_OUT="$(HSG_ENGINE="$HERE/home-scan-guard.py" HOME_SCAN_GUARD_LOG="$LOG" python3 -I -S - <<'PY' 2>&1
import importlib.util, os, string, sys
spec = importlib.util.spec_from_file_location("hsg", os.environ["HSG_ENGINE"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def blocked(cmd, cwd="/Users/athos/gt"):
    try:
        m.analyze(cmd, cwd, ["/Users/athos"])
    except m.Block:
        return True
    return False

letters = string.ascii_letters + string.digits
missed, total = [], 0
for tool in ("du", "dust", "gdu", "ncdu", "tree"):
    for x in letters:
        for flag in ("-" + x, "-s" + x, "-" + x + "s"):
            for tail in ("~/Downloads", "~/Downloads ~/gt", "~/gt ~/Downloads", "/Users", "/Users/athos"):
                cmd = "%s %s %s" % (tool, flag, tail)
                total += 1
                if not blocked(cmd):
                    missed.append(cmd)
# BSD find: a letter (or cluster) before the path must not hide it either
for pre in ["-" + c for c in "EHLPXdsx"] + ["-Hx", "-EX", "-Ps", "-O1", "-O2", "-O3", "-f ~/Downloads", "-D tree", "-D opt"]:
    cmd = "find %s ~/Downloads -name x" % pre if not pre.startswith("-f") else "find %s -name x" % pre
    total += 1
    if not blocked(cmd):
        missed.append(cmd)
print("CLASS total=%d missed=%d" % (total, len(missed)))
for c in missed[:12]:
    print("  MISSED: " + c)
PY
)"
  case "$CLASS_OUT" in
    "CLASS total="*" missed=0"*) ok "class: every option letter, alone and clustered, leaves a hot operand blocked (${CLASS_OUT%%$'\n'*})" ;;
    *) bad "class: an option letter hid a hot operand -- $CLASS_OUT" ;;
  esac
fi

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- gate round 4 (ga-p7agas): no wrapper option table decides which word is the command; a pipe does not replace grep -r / fd's cwd --"
# ─────────────────────────────────────────────────────────────────────────
# Blocker 1 -- ONE option table shared by six wrappers marked `-i -u -n -t -w ...` as taking a VALUE, so a switch (`caffeinate -i`,
# `sudo -n`) swallowed the scanner's own NAME and the scan behind it was allowed with no trace. The class, not the letters: a wrapper
# reader that decides from a table which words are option VALUES loses the command to any wrong or MISSING entry (`time -o FILE`,
# `nice --adjustment 5` were in no table at all). The engine now reads EVERY way a wrapper's leading options can split into
# switches and values; the sections below assert that property for every wrapper, every letter and digit, in the forms a
# switch / a value / an attached value / a cluster / a long option take.
# Blocker 2 -- `grep -r` and `fd` with no path walk the CWD whatever is on stdin (BSD grep measured; GNU grep's manual says the same);
# the classifier assumed a pipe replaced the cwd operand for all of rg/ag/ack/fd/grep.
# The reviewer's own repros, verbatim, through the real wrapper (bash 3.2) with the log asserted:
blocked_and_logged "wrapper table: caffeinate -i (a switch; the shared table said 'valued')"     'caffeinate -i du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: caffeinate -i tar czf ~/Documents"                             'caffeinate -i tar czf /tmp/x.tgz ~/Documents' $G
blocked_and_logged "wrapper table: caffeinate -u"                                                 'caffeinate -u du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: sudo -n (non-interactive, a switch)"                           'sudo -n du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: sudo -i (login shell, a switch)"                               'sudo -i du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: env -S STRING (the value IS the command line)"                 'env -S "du -sk ~/Downloads"' $G
blocked_and_logged "wrapper table: /usr/bin/time -o FILE (the option was in no table)"            '/usr/bin/time -o /tmp/t.txt du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: nice --adjustment 5 (long option, separate value)"             'nice --adjustment 5 du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: sudo -D DIR"                                                   'sudo -D /tmp du -sk ~/Downloads' $G
blocked_and_logged "wrapper table (control that used to work): caffeinate -t 60"                  'caffeinate -t 60 du -sk ~/Downloads' $G
blocked_and_logged "wrapper table (control that used to work): sudo -u athos"                     'sudo -u athos du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: a scan through a shell -c behind a switch"                     "sudo -n bash -c 'du -sk ~/Downloads'" $G
blocked_and_logged "wrapper table: a clustered switch+value, sudo -Hu athos"                      'sudo -Hu athos du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: two wrappers, each with a switch"                              'sudo -n caffeinate -i du -sk ~/Downloads' $G
blocked_and_logged "wrapper table: env -S attached, and with a switch cluster"                    'env -iS"du -sk ~/Downloads"' $G
expect_allow "wrapper table (control): caffeinate -i on a SAFE scan"                              'caffeinate -i du -sk ~/gt' $G
expect_allow "wrapper table (control): sudo -n on a SAFE scan"                                    'sudo -n du -sk ~/gt' $G
expect_allow "wrapper table (control): env -S over a SAFE command line"                           'env -S "du -sk ~/gt"' $G
expect_allow "wrapper table (control): time -o FILE on a SAFE scan"                               '/usr/bin/time -o /tmp/t.txt du -sk ~/gt' $G
expect_allow "wrapper table (control): nice --adjustment 5 on a SAFE scan"                        'nice --adjustment 5 du -sk ~/gt' $G
expect_allow "wrapper table (control): timeout -s KILL 5 on a SAFE scan"                          'timeout -s KILL 5 du -sk ~/gt' $G
expect_allow "wrapper table (control): a scan-tool word that is only an ARGUMENT, from a hot cwd" 'sudo -u athos brew install ncdu' /Users/athos
blocked_and_logged "grep -r: a pipe does not replace the cwd operand (cd ~ && ... | grep -rl)"    'cd ~ && git log --oneline | grep -rl foo' $G
blocked_and_logged "grep -r: same, the payload's cwd is a protected folder"                       'echo x | grep -r foo' /Users/athos/Downloads
blocked_and_logged "fd: a pipe does not replace the cwd operand"                                  'cd ~ && echo x | fd foo' $G
blocked_and_logged "grep -r/xargs: fed by a listing of \$HOME (the same variable, one branch over)" 'ls ~ | xargs grep -rl foo' $G
expect_allow "grep -r (control): unpiped from a safe cwd is not a finding"                        'git log | grep -r foo' $G
expect_allow "rg (control): rg READS stdin when piped (measured), so cd ~ && ... | rg is not a scan" 'cd ~ && git log --oneline | rg foo' $G
expect_allow "grep -r/xargs (control): operands come from xargs' input, not from the cwd"         'git ls-files | xargs grep -rl foo' /Users/athos

# The class, in-process. Every wrapper x every letter/digit x the forms an option takes x a scanner behind it; the same over a SAFE
# target (a reading the engine adds must never become a false block); every search tool x every stdin arrangement; and the SHAPE:
# the wrapper dispatcher is table-driven and the search branch is gated by the stdin table, so a wrapper or a tool nobody classified
# cannot be added without the sweep above covering it.
if [ -f "$HERE/home-scan-guard.py" ]; then
  # The program goes to a FILE first: a heredoc inside $( ) is parsed by macOS bash 3.2 as shell text, and the quotes / backticks in a
  # Python program of this size broke that parse ("unexpected EOF") -- the file died there and every later check silently did not run.
  cat > "$SCRATCH/r4-class.py" <<'PY'
import ast, importlib.util, os, re, string
spec = importlib.util.spec_from_file_location("hsg", os.environ["HSG_ENGINE"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
src = open(os.environ["HSG_ENGINE"]).read()
tree = ast.parse(src)
problems = []
total = 0


def verdict(cmd, cwd="/Users/athos/gt"):
    try:
        m.analyze(cmd, cwd, ["/Users/athos"])
    except m.Block:
        return "block"
    except m.Abort:
        return "gave-up"
    return "allow"


def expect(cmd, want, cwd="/Users/athos/gt"):
    global total
    total += 1
    got = verdict(cmd, cwd)
    if got != want:
        problems.append("WRONG (want %s, got %s, cwd %s): %s" % (want, got, cwd, cmd[:120]))


def func(name):
    return next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name)


# What the TOOLS do is stated HERE, not read back from the engine: a test that takes its expectation from the table it is testing
# passes for any table (mutation-tested: flipping grep to "reads stdin" in the table moved the expectation with it and survived).
KNOWN_WRAPPERS = {"command", "builtin", "exec", "nohup", "setsid", "time", "env", "nice", "ionice", "stdbuf", "arch", "caffeinate",
                  "sudo", "timeout", "xargs"}
positionals = {"timeout": 1}                       # GNU timeout: DURATION sits between its options and the command
assigners = {"env", "sudo"}                        # NAME=VALUE words may precede the command
wrappers = getattr(m, "WRAPPERS", None)
wopts = getattr(m, "WRAPPER_OPTS", None)
if not wrappers or not wopts:
    problems.append("STRUCT: the engine has no WRAPPERS / WRAPPER_OPTS table -- the wrapper dispatcher is not table-driven")
    wrappers = ()
else:
    if not KNOWN_WRAPPERS <= set(wrappers):
        problems.append("STRUCT: wrappers missing from the engine's WRAPPERS: %s" % sorted(KNOWN_WRAPPERS - set(wrappers)))
    if dict(m.WRAPPER_POSITIONALS) != positionals or set(m.WRAPPER_ASSIGNS) != assigners:
        problems.append("STRUCT: WRAPPER_POSITIONALS / WRAPPER_ASSIGNS differ from what timeout / env / sudo take: %r %r"
                        % (dict(m.WRAPPER_POSITIONALS), set(m.WRAPPER_ASSIGNS)))
    # the option tables are for PRECISION and must be RIGHT: the reading they give (the one a cd belongs to) is the real command
    st = m.State(["/Users/athos"], "/Users/athos/gt")
    for cmd, want in (("caffeinate -i du -sk ~/gt", "du"), ("caffeinate -t 60 -d du -sk ~/gt", "du"), ("sudo -n du -sk ~/gt", "du"),
                      ("sudo -i du -sk ~/gt", "du"), ("sudo -u athos -H du -sk ~/gt", "du"), ("sudo -D /tmp FOO=1 du -sk ~/gt", "du"),
                      ("nice -n 5 du -sk ~/gt", "du"), ("nice --adjustment 5 du -sk ~/gt", "du"), ("nice -5 du -sk ~/gt", "du"),
                      ("timeout -s KILL 5 du -sk ~/gt", "du"), ("gtimeout 5 du -sk ~/gt", "du"), ("env -u X -i FOO=1 du -sk ~/gt", "du"),
                      ("env -S x du -sk ~/gt", "du"), ("time -p du -sk ~/gt", "du"), ("/usr/bin/time -o /tmp/t du -sk ~/gt", "du"),
                      ("stdbuf -oL du -sk ~/gt", "du"), ("stdbuf -o L du -sk ~/gt", "du"), ("arch -arch arm64 du -sk ~/gt", "du"),
                      ("arch -x86_64 du -sk ~/gt", "du"), ("command -p du -sk ~/gt", "du"), ("exec -a x du -sk ~/gt", "du"),
                      ("ionice -c 3 -t du -sk ~/gt", "du"), ("nohup du -sk ~/gt", "du"), ("setsid -f du -sk ~/gt", "du"),
                      ("xargs -0 -n 1 du -sk", "du"), ("sudo -n nice -n 5 caffeinate -i timeout 5 du -sk ~/gt", "du"),
                      ('env FOO="$X" du -sk ~/gt', "du"), ('sudo -n BAR="$d" -i du -sk ~/gt', "du"),
                      ('env -u X A="$d" B=2 sh -c "true"', "sh")):
        script, _ = m.scan(cmd, 0, False, 0)
        primary = [r.name for r in m.unwrap(list(script[0].words), st) if r.primary]
        if primary != [want]:
            problems.append("STRUCT: the option tables misread %r: primary reading %r, want [%r]" % (cmd, primary, want))
        total += 1
    # (1) SHAPE: unwrap() names only the wrappers that carry behaviour a table cannot (xargs' own parser, `command -v`, env -S).
    # Any other wrapper spelled out in it is a hand-kept list beside the table -- the drift that produced blocker 1.
    named = {"xargs", "command", "env"}
    spelled = {n.value for n in ast.walk(func("unwrap")) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
    if spelled & (set(wrappers) - named):
        problems.append("STRUCT: unwrap() spells out wrapper names beside the table: %s" % sorted(spelled & (set(wrappers) - named)))
    for w in wrappers:
        if w != "xargs" and not isinstance(wopts.get(w), tuple):
            problems.append("STRUCT: wrapper %r has no option table (a tuple) in WRAPPER_OPTS" % w)

letters = string.ascii_letters + string.digits
scanners = [("du -sk %s", "~/Downloads", "~/gt"),
            ("tar czf /tmp/x.tgz %s", "~/Documents", "~/gt"),
            ("sh -c 'du -sk %s'", "~/Desktop", "~/gt")]
VAL = "5"


def line(w, opt, tail):
    pos = " 5" * positionals.get(w, 0)                  # timeout's DURATION sits between its options and the command
    return "%s %s%s %s" % (w, opt, pos, tail) if opt else "%s%s %s" % (w, pos, tail)


def forms(w):
    out = []
    for x in letters:
        out += ["-%s" % x, "-%s %s" % (x, VAL), "-%s%s" % (x, VAL), "-s%s" % x, "-s%s %s" % (x, VAL)]
        if w in assigners:
            out.append("-%s FOO=1" % x)
    longs = {o for o in wopts.get(w, ()) if o.startswith("--")} | {"--zz"}
    for lo in sorted(longs):
        out += [lo, "%s %s" % (lo, VAL), "%s=%s" % (lo, VAL)]
    out.append("")
    return out


for w in wrappers:
    for opt in forms(w):
        for cmd, hot, safe in scanners:
            # the ONE exception, and it is asserted rather than skipped: `command -v NAME` / `-V` LOOKS a command up and runs nothing
            lookup = w == "command" and opt.split(" ")[0] in ("-v", "-V")
            expect(line(w, opt, cmd % hot), "allow" if lookup else "block")
    for opt in forms(w)[::7]:                           # the same shapes over a SAFE target: no reading may become a false block
        for cmd, hot, safe in scanners:
            expect(line(w, opt, cmd % safe), "allow")
# a wrapper behind a wrapper, each with a switch or a value in front
for w1 in wrappers:
    for w2 in wrappers:
        for o1, o2 in (("-n", "-i"), ("-i", "-n 5"), ("-u", "-t 9"), ("", "-o"), ("-c", "")):
            expect(line(w1, o1, line(w2, o2, "du -sk ~/Downloads")), "block")
            expect(line(w1, o1, line(w2, o2, "du -sk ~/gt")), "allow")
# env -S: the value is a command line, in every spelling
for cmd in ('env -S "du -sk ~/Downloads"', 'env -S"du -sk ~/Downloads"', 'env --split-string="du -sk ~/Downloads"',
            'env --split-string "du -sk ~/Downloads"', 'env -iS "du -sk ~/Downloads"', 'env -i -S "du -sk ~/Downloads"',
            "env -S 'find ~/Desktop -name x'", 'env -S "sh -c \'du -sk ~/Downloads\'"'):
    expect(cmd, "block")
for cmd in ('env -S "du -sk ~/gt"', 'env --split-string="du -sk ~/gt"', "env -S 'find ~/gt -name x'"):
    expect(cmd, "allow")

# The false-positive surface of the extra readings is what the engine header says it is: a reading starts at a word near the front
# of the line, so it only bites when that word is a scanner's own name AND the cwd is hot -- `caffeinate -i make find` from $HOME reads
# a bare `find` (an accepted, documented false positive); from a repo, and every ordinary neighbour, it is allowed.
# Only the PRIMARY reading moves the working directory: `caffeinate -t cd ~/Downloads` is caffeinate -t <timeout "cd"> running
# ~/Downloads -- not a `cd` (the other reading, where -t is a switch, would be one). Letting it move the cwd made the `du -sk .` after
# it a scan of Downloads: a false block, from a reading that is only a guess.
expect("caffeinate -t cd ~/Downloads && du -sk .", "allow")
expect("command -p cd ~/Downloads && du -sk .", "block")             # ...and a REAL cd behind a wrapper still counts
expect("caffeinate -i make find", "block", "/Users/athos")
expect("caffeinate -i make find", "allow", "/Users/athos/gt")
for cmd in ("sudo -u athos brew install tree", "sudo -u athos brew install ncdu", "nice -n 5 make -j4 tree",
            "timeout 60 git log -- du", "env FOO=1 npm install fd", "sudo brew install tree"):
    expect(cmd, "allow", "/Users/athos")

# an assignment whose VALUE is an expansion is still an assignment (it has to be read before the "is this word a literal" test:
# a loop variable handed to the script through `env x="$d" sh -c ...` is how the incident reaches a shell)
for w in sorted(assigners):
    # "-Q FOO" is an option no table knows, with a value: the table reading is WRONG there (FOO would be the command), so the
    # assignment is only reached by the other reading -- which is where reading it after the literal test used to lose it
    for opt in ("", "-n", "-i", "-u FOO", "-n -i", "-Q FOO", "-Q FOO -i"):
        pre = ("%s %s " % (w, opt)).replace("  ", " ")
        expect("for d in $(ls ~); do %sx=\"$d\" sh -c 'du -sk \"$x\"'; done" % pre, "block")
        expect("for d in $(ls ~/gt); do %sx=\"$d\" sh -c 'du -sk \"$x\"'; done" % pre, "allow")

# ---- search tools: does a pipe replace the implicit cwd operand?
ss = getattr(m, "SEARCH_STDIN", None)
if not ss:
    problems.append("STRUCT: the engine has no SEARCH_STDIN table (which search tools read stdin instead of walking the cwd)")
else:
    body = ast.get_source_segment(src, func("check_command"))
    if not re.search(r"\bif name in SEARCH_STDIN\b", body):
        problems.append("STRUCT: check_command's search branch is not gated by SEARCH_STDIN")
    if re.search(r'"rg",\s*"ag",\s*"ack"', body):
        problems.append("STRUCT: check_command spells out the search tools beside SEARCH_STDIN")
    flag = {"grep": "-r "}
    # What each tool does with a pipe and no path, stated here (measured on this machine for grep and rg, 26/09: BSD grep 2.6.0
    # -r prints ./a.txt and ignores the pipe; `echo x | rg x` prints the stdin line; the other three are from their manuals) --
    # NOT read back from the engine's table, or flipping an entry would move the expectation with it.
    truth = {"grep": False, "fd": False, "rg": True, "ag": True, "ack": True}
    if {t: e[0] for t, e in ss.items()} != truth:
        problems.append("STRUCT: SEARCH_STDIN disagrees with what the tools do: %r" % {t: e[0] for t, e in ss.items()})
    for tool, entry in ss.items():
        reads_stdin, evidence = entry
        reads_stdin = truth.get(tool, reads_stdin)
        if not str(evidence).strip():
            problems.append("STRUCT: SEARCH_STDIN[%r] says nothing about HOW it is known (measured / documented)" % tool)
        c = "%s %sfoo" % (tool, flag.get(tool, ""))
        piped = "allow" if reads_stdin else "block"
        expect("cd ~ && git log --oneline | " + c, piped)
        expect("echo x | " + c, piped, "/Users/athos/Downloads")
        expect("cd ~ && " + c, "block")                   # nothing on stdin: every one of them walks the cwd
        expect("git log | " + c, "allow")                 # the cwd is safe
        expect("ls ~ | xargs " + c, "block")              # operands: the entries of $HOME
        expect("ls -A | xargs " + c, "block", "/Users/athos")
        expect("git ls-files | xargs " + c, "allow", "/Users/athos")   # operands come from xargs, not from the cwd

print("R4 total=%d wrong=%d" % (total, len([p for p in problems if p.startswith("WRONG")])) + (" struct=%d" % len([p for p in problems if p.startswith("STRUCT")])))
for p in problems[:14]:
    print("  " + p)
if len(problems) > 14:
    print("  ... and %d more" % (len(problems) - 14))
PY
  R4_OUT="$(HSG_ENGINE="$HERE/home-scan-guard.py" HOME_SCAN_GUARD_LOG="$LOG" python3 -I -S "$SCRATCH/r4-class.py" 2>&1)"
  case "$R4_OUT" in
    "R4 total="*" wrong=0 struct=0"*) ok "class: every wrapper x every letter/digit x switch/value/attached/cluster/long reads through to the scanner, no safe target is blocked, every search tool is classified for stdin (${R4_OUT%%$'\n'*})" ;;
    *) bad "class (gate round 4) -- $R4_OUT" ;;
  esac
fi

# A guard that fails open on its OWN bug is silently OFF: the engine logs those as ENGINE-ERROR. A NameError from a
# refactor once turned 71 must-block cases into silent allows here -- this is the assertion that makes that loud.
echo ""
echo "-- the engine never failed open on its own bug --"
if grep -q 'ENGINE-ERROR' "$LOG" 2>/dev/null; then
  bad "engine internal error(s) fail-opened during this run: $(grep 'ENGINE-ERROR' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no ENGINE-ERROR line in the guard log after the whole run ($(grep -c 'BLOCKED' "$LOG" 2>/dev/null) BLOCKED lines, $(grep -c 'GAVE-UP' "$LOG" 2>/dev/null) GAVE-UP)"
fi
# ...nor did the WRAPPER degrade under a case that was supposed to be decided by the classifier: an expect_allow can
# pass because the wrapper timed out or lost its interpreter and fell open, not because the classifier said allow.
if grep -q 'UNGUARDED' "$LOG" 2>/dev/null; then
  bad "the wrapper degraded (fell open) during the main corpus, so an allow may not be the classifier's verdict: $(grep 'UNGUARDED' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no UNGUARDED line in the guard log after the whole run (every verdict above came from the classifier)"
fi
grep -q 'GAVE-UP' "$LOG" 2>/dev/null && ok "absurd nesting is logged as GAVE-UP (deliberate fail-open), not as an error" || bad "no GAVE-UP line for the nesting case"

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
