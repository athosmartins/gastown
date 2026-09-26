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
  ERR="$(hook_json "$1" "${2-}" | env "${AGENT_ENV[@]}" bash "$GUARD" 2>&1 >/dev/null)"
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

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- FAIL-OPEN: a guard that breaks every Bash call is worse than the problem --"
# ─────────────────────────────────────────────────────────────────────────
run_raw() {  # stdin-text  [env assignments...]
  local input="$1"; shift
  ERR="$(printf '%s' "$input" | env "${AGENT_ENV[@]}" "$@" bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
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
ERR="$(hook_json "$INCIDENT" | env "${NO_ID[@]}" bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "no GC_* identity (Athos's terminal) -> allow, even the incident" || bad "no-identity: rc=$RC err=$ERR"
for v in GC_AGENT GC_ALIAS GC_DIR GC_SESSION_NAME GC_SESSION_ID; do
  ERR="$(hook_json "$INCIDENT" | env "${NO_ID[@]}" "$v=x" bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
  [ "$RC" -eq 2 ] && ok "$v alone identifies an agent session -> block" || bad "$v alone: rc=$RC err=$ERR"
done
# broken classifier / missing helpers
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY=/nonexistent/python bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "classifier binary missing -> allow" || bad "missing python: rc=$RC err=$ERR"
printf '#!/bin/sh\nexit 1\n' > "$SCRATCH/py-crash"; chmod +x "$SCRATCH/py-crash"
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-crash" bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "classifier crashes (exit 1) -> allow" || bad "crashing classifier: rc=$RC err=$ERR"
# python's OWN usage errors exit 2 too: rc==2 alone is not proof of a block, the marker line is
printf '#!/bin/sh\necho "usage: python [option] ... [-c cmd | -m mod | file | -] [arg] ..." >&2\nexit 2\n' > "$SCRATCH/py-usage"; chmod +x "$SCRATCH/py-usage"
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-usage" bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "interpreter exits 2 with a usage error (no BLOCKED marker) -> allow" || bad "stray rc=2 blocked: rc=$RC err=$ERR"
printf '#!/bin/sh\nsleep 30\n' > "$SCRATCH/py-hang"; chmod +x "$SCRATCH/py-hang"
T0=$SECONDS
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-hang" HOME_SCAN_GUARD_TIMEOUT=2 bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ $((SECONDS-T0)) -lt 10 ] && ok "classifier hangs -> allowed after the guard's own timeout (~$((SECONDS-T0))s)" || bad "hanging classifier: rc=$RC took=$((SECONDS-T0))s"
# jq missing from PATH: cannot even read the input -> allow
mkdir -p "$SCRATCH/nojq"; for b in bash cat env sh dirname basename date mkdir printf; do p="$(command -v $b)" && ln -sf "$p" "$SCRATCH/nojq/$b"; done
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" PATH="$SCRATCH/nojq" /bin/bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
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
  hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" "$@" bash "$GUARD" >/dev/null 2>&1; RC=$?
  if [ "$RC" -eq 0 ] && grep -q "result=UNGUARDED" "$DEG" && grep -q -F -- "$frag" "$DEG"; then ok "degradation logged (not silent): $what"
  else bad "degradation not logged: $what -- rc=$RC log=[$(cat "$DEG")]"; fi
}
degraded "classifier interpreter missing" "no python3 interpreter" HOME_SCAN_GUARD_PY=/nonexistent/python
degraded "classifier crashes" "exited 1" HOME_SCAN_GUARD_PY="$SCRATCH/py-crash"
degraded "classifier hangs and is killed" "timed out" HOME_SCAN_GUARD_PY="$SCRATCH/py-hang" HOME_SCAN_GUARD_TIMEOUT=2
degraded "interpreter exits 2 without the BLOCKED marker" "exited 2 without a block verdict" HOME_SCAN_GUARD_PY="$SCRATCH/py-usage"
mkdir -p "$SCRATCH/noengine"; cp "$GUARD" "$SCRATCH/noengine/home-scan-guard.sh"
: > "$DEG"; hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" bash "$SCRATCH/noengine/home-scan-guard.sh" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "classifier missing" "$DEG" && ok "degradation logged (not silent): classifier file gone (a moved/cleaned checkout)" || bad "missing classifier not logged: rc=$RC log=[$(cat "$DEG")]"
: > "$DEG"; hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" PATH="$SCRATCH/nojq" /bin/bash "$GUARD" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && grep -q "jq not found" "$DEG" && ok "degradation logged (not silent): jq missing" || bad "missing jq not logged: rc=$RC log=[$(cat "$DEG")]"
# and the NORMAL quiet exits are not degradations: they must leave the log empty
: > "$DEG"
hook_json 'git status' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" bash "$GUARD" >/dev/null 2>&1
hook_json 'du -sk ~/gt' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" bash "$GUARD" >/dev/null 2>&1
hook_json "$INCIDENT" | env "${NO_ID[@]}" HOME_SCAN_GUARD_LOG="$DEG" bash "$GUARD" >/dev/null 2>&1
echo '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG="$DEG" bash "$GUARD" >/dev/null 2>&1
[ ! -s "$DEG" ] && ok "quiet exits (ordinary command, no identity, non-Bash tool, safe path) write nothing to the log" || bad "quiet exits polluted the log: $(cat "$DEG")"
# an unwritable log must never turn a block into an error, nor an allow into a block
ERR="$(hook_json "$INCIDENT" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_LOG=/nonexistent/dir/x.log bash "$GUARD" 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 2 ] && ok "unwritable log -> still blocks the incident" || bad "unwritable log: rc=$RC"

# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "-- COST: the hook runs on every Bash call of every agent; ordinary calls must not spawn python --"
# ─────────────────────────────────────────────────────────────────────────
# machine load is 40-60 on 10 cores (ga-y0g5x: a detector's poll cost IS load) and python3
# start-up measured 100-280ms there, so the bash prefilter has to be a real fast path.
printf '#!/bin/sh\ntouch "%s/py-called"\nexit 0\n' "$SCRATCH" > "$SCRATCH/py-stub"; chmod +x "$SCRATCH/py-stub"
spawned() {  # command [cwd] -> 0 if the classifier was spawned
  rm -f "$SCRATCH/py-called"
  hook_json "$1" "${2-}" | env "${AGENT_ENV[@]}" HOME_SCAN_GUARD_PY="$SCRATCH/py-stub" bash "$GUARD" >/dev/null 2>&1
  [ -e "$SCRATCH/py-called" ]
}
for c in 'git status --short' 'bd list --status open --limit 0 --json' 'gc session peek x --lines 40' 'ls -la' \
         'du -xsk ~/gt' 'du -xsk ~/.gastown' "find /Users/athos/gt -name '*.sh'" 'rg foo /Users/athos/gt/docs' \
         'grep -rn foo /Users/athos/gt/.gascity-gastown-hq/scripts' 'git log --oneline HEAD~3..HEAD' 'cat ~/gt/CLAUDE.md'; do
  spawned "$c" /Users/athos/gt/whatsapp_automation && bad "python spawned for an ordinary command: $c" || ok "fast path (no python): $c"
done
spawned 'du -sk ~' /Users/athos/gt && ok "python IS spawned when a scan meets \$HOME" || bad "prefilter missed 'du -sk ~'"
spawned 'find . -name x' /Users/athos && ok "python IS spawned when the cwd itself is \$HOME" || bad "prefilter missed cwd=\$HOME"

# A guard that fails open on its OWN bug is silently OFF: the engine logs those as ENGINE-ERROR. A NameError from a
# refactor once turned 71 must-block cases into silent allows here -- this is the assertion that makes that loud.
echo ""
echo "-- the engine never failed open on its own bug --"
if grep -q 'ENGINE-ERROR' "$LOG" 2>/dev/null; then
  bad "engine internal error(s) fail-opened during this run: $(grep 'ENGINE-ERROR' "$LOG" | head -3 | cut -c1-300)"
else
  ok "no ENGINE-ERROR line in the guard log after the whole run ($(grep -c 'BLOCKED' "$LOG" 2>/dev/null) BLOCKED lines, $(grep -c 'GAVE-UP' "$LOG" 2>/dev/null) GAVE-UP)"
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
