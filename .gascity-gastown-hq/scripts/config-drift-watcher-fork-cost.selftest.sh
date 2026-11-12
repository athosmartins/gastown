#!/usr/bin/env bash
# config-drift-watcher-fork-cost.selftest.sh — ga-qg1dw5z.6.
#
# compute_hash runs every POLL_INTERVAL (3 s) for the life of the config-drift watcher. It used to start one
# `stat` per watched file (a `while read` loop) and one `find` per skills dir: about one process per file per
# tick (1086 for the 1061 files of the measured tree), so this one daemon created ~360 processes/s on a mini
# already saturated by short-lived processes. It now starts the same few processes however many files there are.
#
# Proves, against the real compute_hash (the watcher sourced with CONFIG_DRIFT_WATCHER_LIB=1):
#   A. its output is BYTE FOR BYTE what the old per-file loop printed (kept below as legacy_compute_hash, the
#      oracle): on trees with odd names, every kind of crew skills dir, missing roots, unwatched files. That value
#      is persisted (covered_hash) and compared again after a restart, so changing it is not a refactor
#   B. the third states did not move: a scripts/ that cannot be listed, or no md5, still end in "hash-error" (a hash
#      nobody may trust), and a file that vanished between find and stat is dropped, NOT an error
#   C. it still detects: a change, a new file or a removed file in every watched place changes the hash, and
#      files outside the watched set do not
#   D. the cost: stat and find start a number of times that does not grow with the files, while the oracle's does
#      (the control that shows the counter counts)
#
# Run it against another copy of the watcher with WATCHER_UNDER_TEST=<path>: the pre-fix watcher must FAIL D.
# Works under /bin/bash 3.2 and bash 5.x. The watcher's `stat -f '%N %m %z'` and `md5 -q` are macOS: where the
# machine's are not, this file puts a small emulation first in PATH (same output for the forms the watcher uses).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL_CLOSED_LIB="$SELF_DIR/../packs/town-deltas/assets/selftest-fail-closed.lib.sh"
. "$FAIL_CLOSED_LIB" || { echo "FATAL: cannot source $FAIL_CLOSED_LIB" >&2; exit 2; }

WATCHER="${WATCHER_UNDER_TEST:-$SELF_DIR/config-drift-watcher.sh}"
[ -f "$WATCHER" ] || { echo "FATAL: watcher not found: $WATCHER" >&2; exit 2; }

# $TMP is rm -rf'd on exit, so it must be a directory this run really created (see the sibling selftest).
TMP_MADE="$(mktemp -d "${TMPDIR:-/tmp}/cdw-forks.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
if [ -z "$TMP_MADE" ] || [ ! -d "$TMP_MADE" ]; then echo "FATAL: mktemp -d gave no directory ('$TMP_MADE')" >&2; exit 2; fi
TMP="$(cd "$TMP_MADE" && pwd -P)" || { echo "FATAL: cannot enter $TMP_MADE" >&2; exit 2; }
case "$TMP" in
    ''|/|"$PWD"|"$HOME"|"$SELF_DIR") echo "FATAL: refusing to use '$TMP' as the scratch dir" >&2; exit 2 ;;
esac
cleanup() { chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"; }
selftest_fail_closed_arm cleanup

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
ne()  { if [ "$2" != "$3" ]; then ok "$1"; else bad "$1 (both '$2')"; fi; }
le()  { if [ "$2" -le "$3" ] 2>/dev/null; then ok "$1 ($2 <= $3)"; else bad "$1 (got '$2', want <= $3)"; fi; }
ge()  { if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1 ($2 >= $3)"; else bad "$1 (got '$2', want >= $3)"; fi; }

echo "config-drift-watcher fork-cost selftest (bash $BASH_VERSION, watcher: $WATCHER)"

# ── BSD tools where the machine has none ─────────────────────────────────────
mkdir -p "$TMP/bsd"
probe=$(stat -f '%N %m %z' "$0" 2>/dev/null) || probe=""
case "${probe#"$0 "}" in
    [0-9]*" "[0-9]*) ;;
    *)  cat > "$TMP/bsd/stat" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-f" ] && [ "${2:-}" = '%N %m %z' ]; then shift 2; exec /usr/bin/stat -c '%n %Y %s' -- "$@"; fi
echo "stat emulation: unsupported arguments: $*" >&2; exit 64
EOF
        chmod +x "$TMP/bsd/stat" ;;
esac
probe=$(printf x | md5 -q 2>/dev/null) || probe=""
case "$probe" in
    ????????????????????????????????) ;;
    *)  cat > "$TMP/bsd/md5" <<'EOF'
#!/bin/bash
[ "${1:-}" = "-q" ] || { echo "md5 emulation: unsupported arguments: $*" >&2; exit 64; }
/usr/bin/md5sum | { read -r h _; echo "$h"; }
EOF
        chmod +x "$TMP/bsd/md5" ;;
esac
PATH="$TMP/bsd:$PATH"

# ── Source the watcher as a library, every path inside $TMP ──────────────────
export CITY="$TMP/city" CONFIG_DRIFT_WATCHER_WA="$TMP/wa" CONFIG_DRIFT_WATCHER_LIB=1
mkdir -p "$CITY/.gc/state" "$CITY/.gc/logs"
# shellcheck disable=SC1090
. "$WATCHER" || { echo "FATAL: cannot source $WATCHER" >&2; exit 2; }
unset CONFIG_DRIFT_WATCHER_LIB
declare -F compute_hash >/dev/null || { echo "FATAL: the watcher under test has no compute_hash" >&2; exit 2; }

# The oracle: compute_hash as it was before ga-qg1dw5z.6, verbatim (one stat per file).
legacy_compute_hash() {
    {
        find "$CITY/skills" -type f 2>/dev/null
        find "$CITY/.claude/skills" -type f 2>/dev/null
        for _skills in "$WA"/crew/*/.claude/skills; do
            [[ -d "$_skills" ]] && find "$_skills" -type f 2>/dev/null
        done
        find "$WA/city-local/skills" -type f 2>/dev/null
        [[ -f "$CITY/city.toml" ]] && echo "$CITY/city.toml"
        [[ -f "$CITY/pack.toml" ]] && echo "$CITY/pack.toml"
        [[ -f "$CITY/.gc/pool-ceiling-engine.toml" ]] && echo "$CITY/.gc/pool-ceiling-engine.toml"
        find "$CITY/agents" -type f 2>/dev/null
        find "$CITY/scripts" -type f \( -name "*.sh" -o -name "*.py" \) 2>/dev/null
    } | sort | while IFS= read -r f; do
        stat -f '%N %m %z' "$f" 2>/dev/null || true
    done | md5 -q 2>/dev/null || echo "hash-error"
}

mkcity() {   # mkcity <name>: a fresh watched tree, sets CITY and WA (compute_hash reads both at call time)
    CITY="$TMP/$1/city"; WA="$TMP/$1/wa"
    mkdir -p "$CITY/skills" "$CITY/agents" "$CITY/scripts" "$CITY/.gc" "$WA/crew" "$WA/city-local/skills"
}
put() { mkdir -p "$(dirname "$1")" && printf '%s\n' "${2:-x}" > "$1"; }
same() {     # same <what>: the current compute_hash prints exactly what the old loop printed (trailing newlines
             # too) and nothing on stderr (the daemon's stderr is its log: a stat error per tick would fill it)
    local o n e
    o=$(legacy_compute_hash; echo "<end>"); n=$(compute_hash; echo "<end>"); e=$(compute_hash 2>&1 >/dev/null)
    if [ "$o" = "$n" ] && [ -z "$e" ]; then ok "A $1: same output as the per-file loop, silent on stderr"
    else bad "A $1: old [$o] new [$n] stderr [$e]"; fi
}

echo "== A. the hash is the one the per-file loop printed"
mkcity plain
put "$CITY/skills/a.md"; put "$CITY/.claude/skills/hq.md"; put "$CITY/agents/x/agent.toml"; put "$CITY/scripts/s.sh"; put "$CITY/scripts/t.py"
put "$CITY/city.toml"; put "$CITY/pack.toml"; put "$CITY/.gc/pool-ceiling-engine.toml"
put "$WA/crew/c1/.claude/skills/k/SKILL.md"; put "$WA/city-local/skills/l.md"
same "a tree with every watched kind of file"
mkcity odd
put "$CITY/scripts/a b.sh"; put "$CITY/scripts/a.sh"; put "$CITY/scripts/a-b.sh"; put "$CITY/scripts/a  c.py"
put "$CITY/scripts/it's.sh"; put "$CITY/scripts/q\"d.sh"; put "$CITY/scripts/star*.sh"; put "$CITY/scripts/br[ack]et.py"
put "$CITY/scripts/dollar\$x.sh"; put "$CITY/scripts/-dash.sh"; put "$CITY/scripts/ünï.py"; put "$CITY/scripts/back\\slash.sh"
put "$CITY/scripts/ lead.sh"; put "$CITY/scripts/trail .sh"; put "$CITY/scripts/sub dir/n e s t.sh"
put "$CITY/agents/a b/c d.md"; put "$WA/crew/c 1/.claude/skills/s k/i t.md"
same "names with spaces, quotes, globs, a leading dash, unicode and a prefix of another name"
mkcity crews0
same "an empty crew dir (the glob matches nothing)"
rmdir "$WA/crew"
same "no crew dir at all"
mkcity crews12; put "$CITY/scripts/s.sh"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do put "$WA/crew/c$i/.claude/skills/k/f$i.md"; done
same "12 crews"
mkcity crewlink; put "$TMP/crewlink-real/f.md"; mkdir -p "$WA/crew/c1/.claude"; ln -s "$TMP/crewlink-real" "$WA/crew/c1/.claude/skills"
same "a crew skills dir that is a symlink (find does not follow it)"
mkcity crewfile; mkdir -p "$WA/crew/c1/.claude"; put "$WA/crew/c1/.claude/skills" "i am a file, not a dir"
same "a crew skills entry that is a plain file"
mkcity links; put "$CITY/skills/a.md"; ln -s "$CITY/skills/a.md" "$CITY/skills/link.md"; ln -s /nonexistent "$CITY/skills/broken.md"
same "symlinks, one of them broken, inside a root"
mkcity bare; rmdir "$CITY/skills" "$CITY/agents" "$WA/city-local/skills" "$WA/crew"; put "$CITY/scripts/s.sh"
same "skills, agents, city-local and crew all missing"
mkcity empty
same "everything empty (the md5 of nothing)"
mkcity unwatched; put "$CITY/scripts/s.sh"; put "$CITY/scripts/__pycache__/s.pyc"; put "$CITY/scripts/n.txt"; put "$CITY/.gc/logs/x.log"
same "unwatched files present (pyc, txt, logs)"
mkcity locked; put "$CITY/skills/z/a.md"; chmod 000 "$CITY/skills/z"
same "an unreadable subdir of a skills root"
chmod 755 "$CITY/skills/z"

echo "== B. the third states did not move"
mkcity noscripts; put "$CITY/skills/a.md"; rmdir "$CITY/scripts"
n=$(compute_hash)
eq "B1 a scripts/ that cannot be listed ends in the hash-error line" "hash-error" "${n##*$'\n'}"
ne "B1 ...after a digest, as before" "hash-error" "${n%%$'\n'*}"
if declare -F hash_is_known >/dev/null; then
    if hash_is_known "$n"; then bad "B1 hash_is_known took that output for a real hash"; else ok "B1 hash_is_known refuses it (\"cannot tell\" is not \"no drift\")"; fi
fi
same "a missing scripts/"
mkcity nomd5; put "$CITY/scripts/s.sh"
mkdir -p "$TMP/nomd5-bin"
for t in find sort tr xargs stat; do ln -sf "$(command -v $t)" "$TMP/nomd5-bin/$t"; done
n=$( PATH="$TMP/nomd5-bin"; compute_hash )
eq "B2 no md5: exactly hash-error, no digest" "hash-error" "$n"
mkcity ghost; put "$CITY/scripts/s.sh"; put "$CITY/skills/a.md"
clean=$(compute_hash)
mkdir -p "$TMP/ghost-bin"
real_find=$(command -v find)
printf '#!/bin/sh\n"%s" "$@"; rc=$?\necho /nonexistent/ghost.sh\nexit $rc\n' "$real_find" > "$TMP/ghost-bin/find"; chmod +x "$TMP/ghost-bin/find"
n=$( PATH="$TMP/ghost-bin:$PATH"; compute_hash )
eq "B3 a file listed by find that vanished before stat is dropped, not an error" "$clean" "$n"
o=$( PATH="$TMP/ghost-bin:$PATH"; legacy_compute_hash )
eq "B3 ...which is what the old loop did" "$o" "$n"
e=$( PATH="$TMP/ghost-bin:$PATH"; compute_hash 2>&1 >/dev/null )
eq "B3 ...without a word on stderr" "" "$e"

echo "== C. it still detects"
mkcity detect
put "$CITY/skills/a.md"; put "$CITY/.claude/skills/hq.md"; put "$WA/crew/c1/.claude/skills/k/s.md"; put "$WA/city-local/skills/l.md"
put "$CITY/city.toml"; put "$CITY/pack.toml"; put "$CITY/.gc/pool-ceiling-engine.toml"; put "$CITY/agents/x/agent.toml"
put "$CITY/scripts/s.sh"; put "$CITY/scripts/t.py"
prev=$(compute_hash)
for f in "$CITY/skills/a.md" "$CITY/.claude/skills/hq.md" "$WA/crew/c1/.claude/skills/k/s.md" "$WA/city-local/skills/l.md" \
         "$CITY/city.toml" "$CITY/pack.toml" "$CITY/.gc/pool-ceiling-engine.toml" "$CITY/agents/x/agent.toml" \
         "$CITY/scripts/s.sh" "$CITY/scripts/t.py"; do
    printf 'more\n' >> "$f"; cur=$(compute_hash)
    ne "C a changed ${f#"$TMP/detect/"}" "$prev" "$cur"; prev=$cur
done
for f in "$CITY/skills/new.md" "$WA/crew/c2/.claude/skills/k/new.md" "$CITY/agents/new.md" "$CITY/scripts/new.sh"; do
    put "$f"; cur=$(compute_hash)
    ne "C a new ${f#"$TMP/detect/"}" "$prev" "$cur"; prev=$cur
    rm -f "$f"; cur=$(compute_hash)
    ne "C a removed ${f#"$TMP/detect/"}" "$prev" "$cur"; prev=$cur
done
for f in "$CITY/scripts/__pycache__/s.pyc" "$CITY/scripts/notes.txt" "$CITY/.gc/logs/x.log" "$CITY/.gc/other.toml" "$WA/crew/c1/not-skills.md"; do
    put "$f" "unwatched"; cur=$(compute_hash)
    eq "C an unwatched ${f#"$TMP/detect/"} does not change it" "$prev" "$cur"
done

echo "== D. the processes it starts do not grow with the files"
CALLS="$TMP/calls.log"
mkdir -p "$TMP/count"
for t in find stat sort tr xargs md5; do
    real=$(command -v "$t") || { echo "FATAL: no $t on PATH" >&2; exit 2; }
    printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$t" "$CALLS" "$real" > "$TMP/count/$t"
    chmod +x "$TMP/count/$t"
done
starts() {   # starts <function> <tool>: how often one call of <function> started <tool>
    : > "$CALLS"
    ( PATH="$TMP/count:$PATH"; "$1" > /dev/null )
    grep -c "^$2\$" "$CALLS" 2>/dev/null || true
}
mkcity few;  i=0; while [ "$i" -lt 30 ];  do put "$CITY/scripts/s$i.sh"; put "$WA/crew/c$((i % 5))/.claude/skills/k/f$i.md"; i=$((i + 1)); done
f_stat=$(starts compute_hash stat); f_find=$(starts compute_hash find)
mkcity many; i=0; while [ "$i" -lt 300 ]; do put "$CITY/scripts/s$i.sh"; put "$WA/crew/c$((i % 5))/.claude/skills/k/f$i.md"; i=$((i + 1)); done
m_stat=$(starts compute_hash stat); m_find=$(starts compute_hash find)
le "D stat starts with 60 watched files" "$f_stat" 2
le "D stat starts with 600 watched files" "$m_stat" 2
le "D find starts with 60 watched files (one for the roots, one for scripts/)" "$f_find" 2
le "D find starts with 600 watched files" "$m_find" 2
eq "D sort, tr and md5 start once each" "1 1 1" "$(starts compute_hash sort) $(starts compute_hash tr) $(starts compute_hash md5)"
ge "D control: the old loop starts one stat per file, so this counter counts" "$(starts legacy_compute_hash stat)" 600

selftest_summary_reached
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
