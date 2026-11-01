#!/usr/bin/env bash
# nudge-stranded-census.selftest.sh — ga-9uv1xps.3.
#
# Runs nudge-stranded-census.py against SANDBOX state files (never the live .gc/nudges), with a canned `bd`.
# No gc, no city, no network. Exit 0 iff every assertion holds. NSC_CENSUS_UNDER_TEST points the run at a
# mutated copy (mutation checks): every guard below must have a case that dies with its mutant.
set -uo pipefail
ulimit -f 204800 2>/dev/null || true   # a runaway write in a fixture stops at ~200 MB instead of filling the disk

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CENSUS="${NSC_CENSUS_UNDER_TEST:-$SELF_DIR/nudge-stranded-census.py}"

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }

SBX="$(mktemp -d "${TMPDIR:-/tmp}/nudge-stranded-census-selftest.XXXXXX")" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$SBX"' EXIT

jf() { jq -r "$1" <<<"$OUT"; }

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
  [ "\$st" = "-" ] && st=""   # "-" in beads.json = the bead EXISTS but its row carries no readable status
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

echo "== C8. a bead row with NO readable status is nao-sei: never 'encerrada' (would alarm) and never 'viva'"
new_cen c8
echo '{"s-nostatus":"-","s-live":"open"}' > "$SBX/beads.json"   # s-live keeps bd "answering" (all-nao-sei would be rc 2, see C6)
{ nitem n1 s-nostatus "$UNK" "$SOON"; nitem n2 s-live "$UNK" "$SOON"; } | put_pending
OUT="$(cen 2>/dev/null)"; rc=$?
eq "rc 0 (not an alarm: the fence was never confirmed closed)" "$rc" "0"
eq "the statusless row is nao-sei, kept apart from encerrada and viva" "$(jf '[.fences_nao_sei,(.matrix|keys|join(","))]|join("/")')" "1/nao-sei|outro,viva|outro"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
