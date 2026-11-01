#!/usr/bin/env bash
# nudge-pollers-prune.selftest.sh — ga-9uv1xps.2.
#
# Runs nudge-pollers-prune.py against SANDBOX directories (never the live .gc/nudges), with a canned `ps`.
# No gc, no city, no network. Exit 0 iff every assertion holds. NPP_PRUNE_UNDER_TEST points the run at a
# mutated copy (mutation checks): every guard below must have a case that dies with its mutant.
# Runs on macOS (the order itself runs on the mini) and on the Linux test node: `date` and `mktemp` try the BSD form,
# then the GNU one (ga-9uv1xps.2: the mini's disk was under the heavy-step floor, so the node was the only place to run it).
set -uo pipefail
ulimit -f 204800 2>/dev/null || true   # a runaway write in a fixture stops at ~200 MB instead of filling the disk

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="${NPP_PRUNE_UNDER_TEST:-$SELF_DIR/nudge-pollers-prune.py}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

SBX="$(mktemp -d "${TMPDIR:-/tmp}/nudge-pollers-prune-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap 'chmod -R u+rwx "$SBX" 2>/dev/null; rm -rf "$SBX"' EXIT

# <N>d -> touch -t stamp N days ago. BSD `date -v-Nd`, else GNU `date -d "N days ago"`. A failed date must stop the whole
# selftest (an empty stamp would age nothing and pass for the wrong reason).
stamp() {
  local n="${1%d}"
  date -v-"${n}d" '+%Y%m%d%H%M' 2>/dev/null || date -d "$n days ago" '+%Y%m%d%H%M' 2>/dev/null \
    || { echo "FATAL: stamp $1: date failed" >&2; kill -TERM $$; }
}

# ---------------------------------------------------------------- prune fixtures
digest() { python3 -c 'import hashlib,sys; print(hashlib.sha256((sys.argv[1]+"\x00"+sys.argv[2]).encode()).digest()[:8].hex())' "$1" "$2"; }
# mkstem <dir> <session> <agent> <age e.g. 10d> [pid-content]  -> creates .pid .pid.lock .log, all aged; echoes the stem
mkstem() {
  local dir="$1" sess="$2" agent="$3" age="$4" pidc="${5:-999999}" stem t
  stem="$sess-$(digest "$sess" "$agent")"; t="$(stamp "$age")"
  printf '%s' "$pidc" > "$dir/$stem.pid"; : > "$dir/$stem.pid.lock"; echo "log" > "$dir/$stem.log"
  touch -t "$t" "$dir/$stem.pid" "$dir/$stem.pid.lock" "$dir/$stem.log"
  echo "$stem"
}
nfiles() { ls -1 "$1" 2>/dev/null | wc -l | tr -d ' '; }
# fake ps: prints THIS script's parent (the prune python process, so its own pid is in the table) + $SBX/ps.lines
cat > "$SBX/fake-ps.sh" <<EOF
#!/usr/bin/env bash
case "\${PS_MODE:-ok}" in
  fail)   echo "\$PPID /usr/bin/python3 nudge-pollers-prune.py"; cat "$SBX/ps.lines"; echo "ps: boom" >&2; exit 1 ;;   # a table AND rc 1: only the rc check can catch it
  empty)  exit 0 ;;
  noself) cat "$SBX/ps.lines"; exit 0 ;;
esac
echo "\$PPID /usr/bin/python3 nudge-pollers-prune.py"
cat "$SBX/ps.lines"
EOF
chmod +x "$SBX/fake-ps.sh"
: > "$SBX/ps.lines"
prune() { python3 "$PRUNE" --ps-cmd "$SBX/fake-ps.sh" --dir "$P" "$@"; }
jf() { jq -r "$1" <<<"$OUT"; }
new_pdir() { P="$SBX/$1/pollers"; mkdir -p "$P"; : > "$SBX/ps.lines"; }

echo "== P1. dry run by default; --apply removes a dead 10-day-old stem (all 3 files) and nothing else"
new_pdir p1
dead="$(mkstem "$P" gate-reviewer-adhoc-dead1 ga-wisp-dead1 10d)"
young="$(mkstem "$P" gate-reviewer-adhoc-young1 ga-wisp-young1 2d)"
OUT="$(prune)"; rc=$?
eq "dry run rc" "$rc" "0"
eq "dry run reports the 3 files it would delete" "$(jf '[.mode,.to_delete_files,.deleted_files]|join("/")')" "dry-run/3/0"
eq "dry run deletes nothing" "$(nfiles "$P")" "6"
OUT="$(prune --apply)"; rc=$?
eq "apply rc" "$rc" "0"
eq "apply deleted 1 stem / 3 files" "$(jf '[.deleted_stems,.deleted_files,.kept_young]|join("/")')" "1/3/1"
eq "the dead stem is gone" "$(ls "$P" | grep -c "^$dead\.")" "0"
eq "the young stem is intact (3 files)" "$(ls "$P" | grep -c "^$young\.")" "3"
OUT="$(prune --apply)"
eq "idempotent: second apply deletes nothing" "$(jf '[.deleted_files,.rc]|join("/")')" "0/0"

echo "== P2. liveness: signal a (cmdline digest) and signal b (.pid names a live poller) each keep an OLD stem"
new_pdir p2
liveA="$(mkstem "$P" wa-worker-adhoc-live1 ga-wisp-live1 20d 999999)"
liveB="$(mkstem "$P" some-other-session ga-wisp-other 20d 4343)"
reuse="$(mkstem "$P" dead-reused-pid ga-wisp-reuse 20d 4545)"
dead="$(mkstem "$P" dead-really ga-wisp-gone 20d 999998)"
cat > "$SBX/ps.lines" <<EOF
4242 /opt/homebrew/bin/gc nudge poll --city /x --session wa-worker-adhoc-live1 ga-wisp-live1
4343 /opt/homebrew/bin/gc nudge poll --city /x --session an-unrelated-name ga-wisp-unrelated
4545 /usr/bin/vim notes.txt
EOF
OUT="$(prune --apply)"; rc=$?
eq "rc" "$rc" "0"
eq "signal a: stem whose digest matches a live 'gc nudge poll' survives" "$(ls "$P" | grep -c "^$liveA\.")" "3"
eq "signal b: stem whose .pid is a live nudge poller survives" "$(ls "$P" | grep -c "^$liveB\.")" "3"
eq "a .pid naming a reused PID (alive, not a poller) does NOT keep the stem" "$(ls "$P" | grep -c "^$reuse\.")" "0"
eq "a .pid naming a dead PID does not keep the stem" "$(ls "$P" | grep -c "^$dead\.")" "0"
eq "kept_live=2 deleted_stems=2" "$(jf '[.kept_live,.deleted_stems]|join("/")')" "2/2"

echo "== P3. the age of a stem is its NEWEST file"
new_pdir p3
mixed="$(mkstem "$P" mixed-age ga-wisp-mixed 30d)"
touch -t "$(stamp 1d)" "$P/$mixed.log"
OUT="$(prune --apply)"
eq "30-day-old .pid/.lock + 1-day-old .log: the stem is young, nothing deleted" "$(jf '[.kept_young,.deleted_files]|join("/")')" "1/0"
eq "all 3 files still there" "$(nfiles "$P")" "3"

echo "== P4. a held flock on the stem's .pid.lock keeps the stem (the files of a stem are never deleted under a holder)"
new_pdir p4
held="$(mkstem "$P" held-lock ga-wisp-held 15d)"
python3 - "$P/$held.pid.lock" <<'PY' &
import fcntl, sys, time
fh = open(sys.argv[1], "r+b")
fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
open(sys.argv[1] + ".held", "w").close()
time.sleep(5)
PY
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -e "$P/$held.pid.lock.held" ] && break; sleep 0.3; done
OUT="$(prune --apply)"; rc=$?
eq "locked stem: kept_locked=1, nothing deleted" "$(jf '[.kept_locked,.deleted_files]|join("/")')" "1/0"
eq "its 3 files (plus the sentinel) are still there" "$(nfiles "$P")" "4"
wait "$holder" 2>/dev/null

echo "== P4b. an unreadable .pid or .pid.lock is 'cannot tell' for that stem: kept, counted as undecided (never as live), WARNed, the run goes on"
new_pdir p4b
unr_pid="$(mkstem "$P" unreadable-pid ga-wisp-u1 25d)"; chmod 000 "$P/$unr_pid.pid"
unr_lock="$(mkstem "$P" unreadable-lock ga-wisp-u2 25d)"; chmod 000 "$P/$unr_lock.pid.lock"
fine="$(mkstem "$P" fine-dead ga-wisp-u3 25d)"
OUT="$(prune --apply 2>"$SBX/p4b.err")"; rc=$?
eq "rc 0 (nothing failed that the run could not survive)" "$rc" "0"
eq "both unreadable stems are undecided, none is 'live'" "$(jf '[.kept_live,.kept_undecided]|join("/")')" "0/2"
eq "both stems are intact (3 + 3 files), the third is gone" "$(nfiles "$P")" "6"
eq "the readable dead stem was pruned" "$(ls "$P" | grep -c "^$fine\.")" "0"
eq "the unreadable .pid is named in a WARN on stderr" "$(grep -c "^WARN: kept undecided: .*$unr_pid\.pid: cannot read the .pid" "$SBX/p4b.err")" "1"
eq "the unreadable lock is named in a WARN on stderr" "$(grep -c "^WARN: kept undecided: .*$unr_lock\.pid\.lock: cannot open the lock" "$SBX/p4b.err")" "1"
chmod 644 "$P/$unr_pid.pid" "$P/$unr_lock.pid.lock"

echo "== P4c. a pollers dir whose entries cannot be stat'ed (mode r--): every stem is undecided, with or without a .pid; same failure, same label"
new_pdir p4c
s1="$(mkstem "$P" nostat-one ga-wisp-n1 25d)"; s2="$(mkstem "$P" nostat-two ga-wisp-n2 25d)"
chmod 400 "$P"
OUT="$(prune --apply 2>"$SBX/p4c.err")"; rc=$?
chmod 755 "$P"
eq "rc 0" "$rc" "0"
eq "2 stems with a .pid: kept_live=0, kept_undecided=2, nothing deleted" "$(jf '[.kept_live,.kept_undecided,.deleted_files]|join("/")')" "0/2/0"
eq "…and the files are all still there" "$(nfiles "$P")" "6"
eq "a WARN per stem says why (the .pid cannot be opened in a dir without search permission)" "$(grep -c "^WARN: kept undecided: .*\.pid: cannot read the .pid" "$SBX/p4c.err")" "2"
rm -f "$P"/*.pid
chmod 400 "$P"
OUT="$(prune --apply 2>"$SBX/p4c2.err")"
chmod 755 "$P"
eq "the same dir WITHOUT .pid files lands in the same bucket (undecided=2)" "$(jf '[.kept_live,.kept_undecided]|join("/")')" "0/2"
eq "…and there the WARN is about the unreadable file times (the mtime branch)" "$(grep -c "^WARN: kept undecided: .*cannot read the file times" "$SBX/p4c2.err")" "2"

echo "== P4d. a garbled .pid is 'no signal b', never a crash: a superscript two passes str.isdigit() but not int()"
new_pdir p4d
garbled="$(mkstem "$P" garbled-pid ga-wisp-g1 25d $'\xc2\xb2')"
empty_pid="$(mkstem "$P" empty-pid ga-wisp-g2 25d "")"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "rc 0 (no traceback)" "$rc" "0"
eq "both dead stems pruned, none live" "$(jf '[.deleted_stems,.kept_live]|join("/")')" "2/0"

echo "== P4e. signal a beats an unreadable .pid: the stem of a LIVE poller is live, not undecided (the .pid is not needed to know)"
new_pdir p4e
lu="$(mkstem "$P" live-unreadable-pid ga-wisp-lu 25d)"; chmod 000 "$P/$lu.pid"
echo "4242 /opt/homebrew/bin/gc nudge poll --city /x --session live-unreadable-pid ga-wisp-lu" > "$SBX/ps.lines"
OUT="$(prune --apply 2>"$SBX/p4e.err")"; rc=$?
chmod 644 "$P/$lu.pid"
eq "rc 0" "$rc" "0"
eq "kept_live=1, kept_undecided=0" "$(jf '[.kept_live,.kept_undecided]|join("/")')" "1/0"
eq "no WARN, nothing deleted" "$(grep -c '^WARN' "$SBX/p4e.err")/$(nfiles "$P")" "0/3"

echo "== P5. names outside the stem pattern, and non-regular files, are never touched"
new_pdir p5
echo keep > "$P/README"; echo keep > "$P/notes.pid"; echo keep > "$P/short-0123abcd.log"
echo keep > "$SBX/p5/target.log"
ln -s "$SBX/p5/target.log" "$P/linked-0123456789abcdef.log"
touch -t "$(stamp 40d)" "$P/README" "$P/notes.pid" "$P/short-0123abcd.log"
touch -h -t "$(stamp 40d)" "$P/linked-0123456789abcdef.log" 2>/dev/null
OUT="$(prune --apply)"; rc=$?
eq "rc" "$rc" "0"
eq "4 names ignored, 0 stems" "$(jf '[.ignored_names,.stems]|join("/")')" "4/0"
eq "everything still there" "$(nfiles "$P")" "4"
eq "the symlink target is intact" "$(cat "$SBX/p5/target.log")" "keep"

echo "== P6. cannot tell => rc 2 and NOTHING deleted (failed/empty ps is not 'no pollers')"
new_pdir p6
d6="$(mkstem "$P" would-be-dead ga-wisp-x 30d)"
for mode in fail empty noself; do
  OUT="$(PS_MODE=$mode prune --apply 2>/dev/null)"; rc=$?
  eq "ps $mode: rc 2" "$rc" "2"
  eq "ps $mode: stem intact" "$(nfiles "$P")" "3"
done
echo "4001 /opt/homebrew/bin/gc nudge poll --city /x --session s1" > "$SBX/ps.lines"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "a live poller with no agent argument (target unreadable): rc 2" "$rc" "2"
eq "…and nothing deleted" "$(nfiles "$P")" "3"
echo "4002 /opt/homebrew/bin/gc nudge poll --city /x --session" > "$SBX/ps.lines"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "a live poller with a dangling --session: rc 2" "$rc" "2"
echo "4004 /opt/homebrew/bin/gc nudge poll --city /x some-agent" > "$SBX/ps.lines"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "a live poller with an agent but no --session: rc 2" "$rc" "2"
eq "…and nothing deleted" "$(nfiles "$P")" "3"
echo "4003 /usr/bin/vim a-file nudge poll more words" > "$SBX/ps.lines"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "a non-gc process that merely mentions 'nudge poll' does NOT abort the run" "$rc" "0"
eq "…and the dead stem is pruned" "$(nfiles "$P")" "0"

echo "== P7. missing dir, caps and the age floor"
OUT="$(python3 "$PRUNE" --ps-cmd "$SBX/fake-ps.sh" --dir "$SBX/nope/pollers" --apply 2>/dev/null)"; rc=$?
eq "missing dir: rc 2" "$rc" "2"
eq "…and it is not created" "$([ -e "$SBX/nope" ] && echo created || echo absent)" "absent"
new_pdir p7
for i in 1 2 3; do mkstem "$P" "cap-$i" "a$i" 20d >/dev/null; done
OUT="$(prune --apply --max-deletes 5 2>/dev/null)"; rc=$?
eq "9 files over --max-deletes 5: rc 2" "$rc" "2"
eq "…and nothing deleted" "$(nfiles "$P")" "9"
OUT="$(prune --apply --min-age-days 0.5 2>/dev/null)"; rc=$?
eq "--min-age-days below 1 is refused: rc 2" "$rc" "2"
eq "…and nothing deleted" "$(nfiles "$P")" "9"
OUT="$(prune --apply --min-age-days nan 2>/dev/null)"; rc=$?
eq "--min-age-days nan is refused: rc 2" "$rc" "2"
eq "…and nothing deleted" "$(nfiles "$P")" "9"
OUT="$(prune --apply --min-age-days 30 2>/dev/null)"
eq "--min-age-days 30: 20-day-old stems are young" "$(jf '[.kept_young,.deleted_files]|join("/")')" "3/0"

echo "== P8. the run summary is appended as one valid json line per run"
new_pdir p8
mkstem "$P" logged ga-wisp-l 12d >/dev/null
prune --apply --log "$SBX/p8/out.jsonl" >/dev/null
prune --apply --log "$SBX/p8/out.jsonl" >/dev/null
eq "2 runs -> 2 json lines" "$(jq -c . "$SBX/p8/out.jsonl" | wc -l | tr -d ' ')" "2"
eq "first run deleted 3, second 0" "$(jq -s -r 'map(.deleted_files)|join("/")' "$SBX/p8/out.jsonl")" "3/0"

echo "== P9. an unlink that fails is reported: rc 1, unlink_errors counted, the stem is not counted as deleted"
new_pdir p9
mkstem "$P" unlink-fails ga-wisp-f1 20d >/dev/null
chmod 500 "$P"
OUT="$(prune --apply 2>"$SBX/p9.err")"; rc=$?
chmod 755 "$P"
eq "rc 1" "$rc" "1"
eq "3 unlink errors, 0 stems deleted" "$(jf '[.unlink_errors,.deleted_stems]|join("/")')" "3/0"
eq "3 WARN lines" "$(grep -c '^WARN: unlink ' "$SBX/p9.err")" "3"
eq "the files are still there" "$(nfiles "$P")" "3"

echo "== P10. the order entrypoint (nudge-pollers-prune.sh) end to end against a sandbox city"
CITY10="$SBX/p10/city"; mkdir -p "$CITY10/.gc/nudges/pollers"; P="$CITY10/.gc/nudges/pollers"; : > "$SBX/ps.lines"
mkstem "$P" wrapper-dead ga-wisp-w1 12d >/dev/null
young10="$(mkstem "$P" wrapper-young ga-wisp-w2 1d)"
OUT="$(GC_CITY="$CITY10" GC_PACK_STATE_DIR="$SBX/p10/state" bash "$SELF_DIR/nudge-pollers-prune.sh" --ps-cmd "$SBX/fake-ps.sh")"; rc=$?
eq "rc 0" "$rc" "0"
eq "it applies (the order's flag), dead stem gone, young stem kept" "$(jf '[.mode,.deleted_stems,.kept_young]|join("/")')" "apply/1/1"
eq "the young stem is intact" "$(ls "$P" | grep -c "^$young10\.")" "3"
eq "one json line was logged under the state dir" "$(jq -c . "$SBX/p10/state/nudge-pollers-prune.jsonl" | wc -l | tr -d ' ')" "1"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
