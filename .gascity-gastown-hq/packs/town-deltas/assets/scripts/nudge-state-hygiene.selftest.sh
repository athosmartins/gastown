#!/usr/bin/env bash
# nudge-state-hygiene.selftest.sh — ga-9uv1xps.
#
# Runs nudge-pollers-prune.py, nudge-stranded-census.py and the nudge-state-hygiene.sh wrapper against SANDBOX
# directories (never the live .gc/nudges), with a canned `ps` and a canned `bd`. No gc, no city, no network.
# Exit 0 iff every assertion holds. NSH_PRUNE_UNDER_TEST / NSH_CENSUS_UNDER_TEST / NSH_WRAPPER_UNDER_TEST point
# the run at a mutated copy (mutation checks): every guard below must have a case that dies with its mutant.
set -uo pipefail
ulimit -f 204800 2>/dev/null || true   # a runaway write in a fixture stops at ~200 MB instead of filling the disk

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRUNE="${NSH_PRUNE_UNDER_TEST:-$SELF_DIR/nudge-pollers-prune.py}"
CENSUS="${NSH_CENSUS_UNDER_TEST:-$SELF_DIR/nudge-stranded-census.py}"
WRAPPER="${NSH_WRAPPER_UNDER_TEST:-$SELF_DIR/nudge-state-hygiene.sh}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

SBX="$(mktemp -d -t nudge-state-hygiene-selftest)" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$SBX"' EXIT

# BSD date/touch: a failed date must stop the whole selftest (an empty stamp would age nothing and pass for the wrong reason)
stamp() { date -v-"$1" '+%Y%m%d%H%M' || { echo "FATAL: stamp $1: date failed" >&2; kill -TERM $$; }; }
iso_ahead() { date -u -v+"$1" '+%Y-%m-%dT%H:%M:%S.000000Z' || { echo "FATAL: iso_ahead $1: date failed" >&2; kill -TERM $$; }; }

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

echo "== P4b. an unreadable .pid or .pid.lock is 'cannot tell' for that stem: kept and counted, the run goes on"
new_pdir p4b
unr_pid="$(mkstem "$P" unreadable-pid ga-wisp-u1 25d)"; chmod 000 "$P/$unr_pid.pid"
unr_lock="$(mkstem "$P" unreadable-lock ga-wisp-u2 25d)"; chmod 000 "$P/$unr_lock.pid.lock"
fine="$(mkstem "$P" fine-dead ga-wisp-u3 25d)"
OUT="$(prune --apply 2>/dev/null)"; rc=$?
eq "rc 0 (nothing failed that the run could not survive)" "$rc" "0"
eq "the unreadable-.pid stem is kept as live-by-doubt, the unreadable-lock stem as undecided" "$(jf '[.kept_live,.kept_undecided]|join("/")')" "1/1"
eq "both stems are intact (3 + 3 files), the third is gone" "$(nfiles "$P")" "6"
eq "the readable dead stem was pruned" "$(ls "$P" | grep -c "^$fine\.")" "0"
chmod 644 "$P/$unr_pid.pid" "$P/$unr_lock.pid.lock"

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
OUT="$(prune --apply --min-age-days 30 2>/dev/null)"
eq "--min-age-days 30: 20-day-old stems are young" "$(jf '[.kept_young,.deleted_files]|join("/")')" "3/0"

echo "== P8. the run summary is appended as one valid json line per run"
new_pdir p8
mkstem "$P" logged ga-wisp-l 12d >/dev/null
prune --apply --log "$SBX/p8/out.jsonl" >/dev/null
prune --apply --log "$SBX/p8/out.jsonl" >/dev/null
eq "2 runs -> 2 json lines" "$(jq -c . "$SBX/p8/out.jsonl" | wc -l | tr -d ' ')" "2"
eq "first run deleted 3, second 0" "$(jq -s -r 'map(.deleted_files)|join("/")' "$SBX/p8/out.jsonl")" "3/0"

# ---------------------------------------------------------------- census fixtures
cat > "$SBX/fake-bd.sh" <<EOF
#!/usr/bin/env bash
# fake 'bd show <ids...> --json' over \$SBX/beads.json {id: status}; like the real bd, ANY unknown id fails the whole call
[ "\${BD_MODE:-ok}" = fail ] && { echo "bd: boom" >&2; exit 1; }
[ "\$1" = show ] || exit 2
shift; ids=(); for a in "\$@"; do [ "\$a" = --json ] || ids+=("\$a"); done
out="[" ; first=1
for id in "\${ids[@]}"; do
  st=\$(jq -r --arg id "\$id" '.[\$id] // empty' "$SBX/beads.json")
  [ -n "\$st" ] || { echo '{"error":"no issues found matching the provided IDs"}'; exit 1; }
  [ \$first = 1 ] || out="\$out,"; first=0
  out="\$out{\"id\":\"\$id\",\"status\":\"\$st\",\"issue_type\":\"session\"}"
done
echo "\$out]"
EOF
chmod +x "$SBX/fake-bd.sh"
cen() { python3 "$CENSUS" --bd-cmd "$SBX/fake-bd.sh" --city "$SBX" --state "$S" --now 2026-11-01T12:00:00Z "$@"; }
# nitem <id> <fence> <message> <expires_at>
nitem() { jq -cn --arg id "$1" --arg f "$2" --arg m "$3" --arg e "$4" '{id:$id, agent:"a", session_id:$f, message:$m, expires_at:$e}'; }
put_pending() { jq -s '{pending: .}' > "$S"; }
new_cen() { S="$SBX/$1.state.json"; echo '{}' > "$SBX/beads.json"; }
SOON="2026-11-01T14:00:00.000000Z"     # 2 h after --now
LATER="2026-11-02T08:00:00.000000Z"    # 20 h after --now
UNK="please remember to rotate the vendor key before friday"

echo "== C1. the known shapes of a stranded item never alarm, whatever their TTL"
new_cen c1
echo '{"s-closed":"closed"}' > "$SBX/beads.json"
{ nitem g1 s-closed "QUALITY GATE REVIEW — wa-1 POINTER (ga-aaa)" "$SOON"
  nitem g2 s-closed "Bead nova para você: ga-xyz" "$SOON"
  nitem g3 s-closed "DISK CRITICAL: 1.2 GB free" "$SOON"
  nitem g4 s-closed "ga-1 has passed gate" "$SOON"; } | put_pending
OUT="$(cen 2>/dev/null)"; rc=$?
eq "rc 0" "$rc" "0"
eq "matrix counts them as encerrada x known class" "$(jf '.matrix|to_entries|map("\(.key)=\(.value)")|sort|join(",")')" "encerrada|aviso-transit=1,encerrada|ponteiro-bead=2,encerrada|tarefa-gate=1"
eq "no alarms" "$(jf '.alarms|length')" "0"

echo "== C2. unknown shape + CONFIRMED closed fence + under 6 h of TTL => STRANDED-INFO, rc 1"
new_cen c2
echo '{"s-closed":"closed"}' > "$SBX/beads.json"
{ nitem u1 s-closed "$UNK" "$SOON"; } | put_pending
LINES="$(cen 2>/dev/null)"; rc=$?
OUT="$(echo "$LINES" | tail -n 1)"
eq "rc 1" "$rc" "1"
eq "the STRANDED-INFO line names the item and carries its text" "$(echo "$LINES" | grep -c "^STRANDED-INFO item=u1 .*rotate the vendor key")" "1"
eq "alarms lists it" "$(jf '.alarms|map(.id)|join(",")')" "u1"

echo "== C3. each leg of the trigger is necessary: far TTL, live fence, unknown fence, known shape"
new_cen c3
echo '{"s-closed":"closed","s-live":"open"}' > "$SBX/beads.json"
{ nitem far s-closed "$UNK" "$LATER"
  nitem live s-live "$UNK" "$SOON"
  nitem unk s-missing "$UNK" "$SOON"
  nitem nofence "" "$UNK" "$SOON"; } | put_pending
OUT="$(cen 2>/dev/null)"; rc=$?
eq "rc 0 (nothing satisfies all three legs)" "$rc" "0"
eq "the fence nobody can resolve is nao-sei, NOT closed (and the batch fell back to one-by-one)" "$(jf '.fences_nao_sei')" "1"
eq "matrix keeps the three states apart" "$(jf '.matrix|to_entries|map("\(.key)=\(.value)")|sort|join(",")')" "encerrada|outro=1,nao-sei|outro=1,sem-fence|outro=1,viva|outro=1"

echo "== C4. an unreadable expires_at on an unknown closed item is inert (not an alarm) but is listed"
new_cen c4
echo '{"s-closed":"closed"}' > "$SBX/beads.json"
{ nitem t1 s-closed "$UNK" "not-a-date"; nitem t2 s-closed "$UNK" ""; } | put_pending
OUT="$(cen 2>/dev/null)"; rc=$?
eq "rc 0" "$rc" "0"
eq "both listed as outro_ttl_unreadable" "$(jf '.outro_ttl_unreadable|sort|join(",")')" "t1,t2"

echo "== C5. one purged bead in a batch does not hide the others (fallback one-by-one), 45 fences span 3 batches"
new_cen c5
python3 - "$SBX/beads.json" <<'PY'
import json, sys
json.dump({f"s{i}": "closed" for i in range(45) if i != 7}, open(sys.argv[1], "w"))
PY
for i in $(seq 0 44); do nitem "i$i" "s$i" "QUALITY GATE REVIEW $i" "$LATER"; done | put_pending
OUT="$(cen 2>/dev/null)"; rc=$?
eq "rc 0" "$rc" "0"
eq "44 closed, exactly 1 nao-sei" "$(jf '[.matrix["encerrada|tarefa-gate"], .matrix["nao-sei|tarefa-gate"]]|join("/")')" "44/1"

echo "== C6. cannot tell => rc 2 (bd down, state unreadable / odd shape), never a clean 0"
new_cen c6
{ nitem b1 s-closed "$UNK" "$SOON"; } | put_pending
echo '{"s-closed":"closed"}' > "$SBX/beads.json"
OUT="$(BD_MODE=fail cen 2>/dev/null)"; rc=$?
eq "bd fails for every fence: rc 2" "$rc" "2"
echo '{"pending": ' > "$S"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "truncated state.json: rc 2" "$rc" "2"
echo '{"pending": "x"}' > "$S"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "pending present but not a list: rc 2" "$rc" "2"
echo '[]' > "$S"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "state that is not an object: rc 2" "$rc" "2"
S="$SBX/does-not-exist.json"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "missing state file: rc 2" "$rc" "2"
S="$SBX/c6.state.json"; echo '{"pending": []}' > "$S"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "an empty pending list is a clean rc 0 (empty, not failed)" "$rc" "0"
echo '{"dead": []}' > "$S"
OUT="$(cen 2>/dev/null)"; rc=$?
eq "no 'pending' key at all is also empty: rc 0" "$rc" "0"

echo "== C7. READ-ONLY: the queue file is byte-identical after a run that alarms"
new_cen c7
echo '{"s-closed":"closed"}' > "$SBX/beads.json"
{ nitem r1 s-closed "$UNK" "$SOON"; } | put_pending
before="$(shasum -a 256 "$S")"
cen >/dev/null 2>&1
after="$(shasum -a 256 "$S")"
eq "state.json unchanged" "$after" "$before"

# ---------------------------------------------------------------- wrapper (worst rc of the two, none skipped)
echo "== W1. wrapper: worst of the two rc, a stray rc counts as 2, and one failing never skips the other"
W="$SBX/wrap"; mkdir -p "$W"
cp "$WRAPPER" "$W/nudge-state-hygiene.sh"
for s in nudge-pollers-prune nudge-stranded-census; do
  var="$(echo "$s" | tr 'a-z-' 'A-Z_')_RC"
  printf '#!/usr/bin/env python3\nimport os, sys\nopen(os.environ["TRACE"], "a").write("%s\\n")\nsys.exit(int(os.environ.get("%s", "0")))\n' "$s" "$var" > "$W/$s.py"
done
wrap() { TRACE="$W/trace" GC_CITY="$SBX" GC_PACK_STATE_DIR="$W" bash "$W/nudge-state-hygiene.sh" >/dev/null 2>&1; echo $?; }
: > "$W/trace"
eq "0 + 0 => 0" "$(wrap)" "0"
eq "both ran" "$(sort "$W/trace" | tr '\n' ' ')" "nudge-pollers-prune nudge-stranded-census "
: > "$W/trace"; eq "prune 1, census 0 => 1" "$(NUDGE_POLLERS_PRUNE_RC=1 wrap)" "1"
eq "prune 0, census 1 => 1" "$(NUDGE_STRANDED_CENSUS_RC=1 wrap)" "1"
eq "prune 2, census 1 => 2" "$(NUDGE_POLLERS_PRUNE_RC=2 NUDGE_STRANDED_CENSUS_RC=1 wrap)" "2"
eq "prune 1, census 2 => 2" "$(NUDGE_POLLERS_PRUNE_RC=1 NUDGE_STRANDED_CENSUS_RC=2 wrap)" "2"
eq "a stray rc (127) from the prune counts as 2, not 0" "$(NUDGE_POLLERS_PRUNE_RC=127 wrap)" "2"
: > "$W/trace"; NUDGE_POLLERS_PRUNE_RC=2 wrap >/dev/null
eq "a prune that cannot tell still lets the census run" "$(sort "$W/trace" | tr '\n' ' ')" "nudge-pollers-prune nudge-stranded-census "

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
