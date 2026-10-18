#!/bin/bash
# claude_home_trim.selftest.sh (ga-mnznp8) — unit tests for claude_home_trim.py.
#
# Hermetic: every scenario points CLAUDE_HOME_TRIM_HOME at a disposable fixture under
# $TMPDIR and CLAUDE_HOME_TRIM_GC_BIN at a stub. The real ~/.claude and the real `gc` are
# never read or touched (the sentinel scenario patches the module's notion of "the real
# home" to a fixture, so it can prove the forced dry-run without going near the real one).
# Fixtures are a few hundred KB at most (one 3 MB file for the freed-MB line), so this is
# safe to run on a disk at the floor.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/claude_home_trim.py"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-home-trim-selftest.XXXXXX")"
trap 'chmod -R u+rwx "$T" 2>/dev/null; rm -rf "$T"' EXIT

# A live session of the one running this selftest must not leak into the scenarios.
unset CLAUDE_CODE_SESSION_ID

inode() { stat -f %i "$1" 2>/dev/null || stat -c %i "$1"; }
fsize() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
stamp() { date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M; }
old()   { local s; s="$(stamp "$1")"; shift; touch -t "$s" "$@"; }

# stub for `gc session list --json`: prints $FAKE_GC_OUT, or fails with $FAKE_GC_RC
cat > "$T/fake-gc" <<'EOF'
#!/bin/bash
[ "$1 $2 $3" = "session list --json" ] || { echo "fake-gc: unexpected args: $*" >&2; exit 64; }
if [ -n "${FAKE_GC_RC:-}" ] && [ "$FAKE_GC_RC" != 0 ]; then echo "fake-gc: boom" >&2; exit "$FAKE_GC_RC"; fi
cat "$FAKE_GC_OUT"
EOF
chmod +x "$T/fake-gc"
printf '{"sessions":[]}\n' > "$T/gc-empty.json"

# run_trim <home> [VAR=val ...] → OUT, RC
run_trim() {
  local home="$1"; shift
  OUT="$(env CLAUDE_HOME_TRIM_HOME="$home" CLAUDE_HOME_TRIM_GC_BIN="$T/fake-gc" \
         FAKE_GC_OUT="${FAKE_GC_OUT:-$T/gc-empty.json}" "$@" python3 -I "$SCRIPT" 2>&1)"; RC=$?
}

# numbered 45-byte-ish lines so a cut is easy to verify
make_history() { awk -v n="$2" 'BEGIN{for(i=1;i<=n;i++) printf "line-%06d some prompt text padding padding\n", i}' > "$1"; }

# a python harness that loads the script as a module (for the hooks no shell can reach)
pyrun() { python3 -I -c "$1" "$SCRIPT" "${@:2}" 2>&1; }

echo "=== claude_home_trim.selftest.sh ==="

# ── history.jsonl ───────────────────────────────────────────────────────────
echo "-- history.jsonl --"
H="$T/h1"; mkdir -p "$H"
make_history "$H/history.jsonl" 4000          # ~180 KB
cp "$H/history.jsonl" "$T/h1.orig"
INO0="$(inode "$H/history.jsonl")"
exec 9>>"$H/history.jsonl"                     # a long-lived writer, like a Claude Code session
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
SZ="$(fsize "$H/history.jsonl")"
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'history: CUT' \
  && ok "over the cap: cut, exit 0" || bad "over the cap: expected CUT + rc 0, got rc=$RC out='$OUT'"
[ "$(inode "$H/history.jsonl")" = "$INO0" ] \
  && ok "the cut keeps the same inode" || bad "the inode changed (a rename would orphan the writers)"
{ [ "$SZ" -le 40000 ] && [ "$SZ" -gt 39900 ]; } \
  && ok "kept ≈ the last 40 KB ($SZ bytes)" || bad "kept size out of range: $SZ"
head -n1 "$H/history.jsonl" | grep -Eq '^line-[0-9]{6} some prompt text padding padding$' \
  && ok "the kept part starts on a whole line" || bad "first kept line is cut mid-line: '$(head -n1 "$H/history.jsonl")'"
cmp -s <(tail -c "$SZ" "$T/h1.orig") "$H/history.jsonl" \
  && ok "the kept part is byte-identical to the tail of the original" || bad "kept part differs from the original tail"
echo "writer-after-cut" >&9; exec 9>&-
{ [ "$(tail -n1 "$H/history.jsonl")" = "writer-after-cut" ] && [ "$(tail -n2 "$H/history.jsonl" | head -n1)" = "$(tail -n1 "$T/h1.orig")" ]; } \
  && ok "a writer that held the file open keeps appending right after the kept lines" \
  || bad "writer append after the cut landed in the wrong place"
echo "$OUT" | grep -q 'usage-analytics.jsonl=' && echo "$OUT" | grep -q 'credit-cache-updater.log=' \
  && ok "the run measures usage-analytics.jsonl and credit-cache-updater.log" || bad "measure line missing: '$OUT'"

# under the cap → untouched
H="$T/h2"; mkdir -p "$H"; make_history "$H/history.jsonl" 500; cp "$H/history.jsonl" "$T/h2.orig"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
{ [ "$RC" -eq 0 ] && cmp -s "$T/h2.orig" "$H/history.jsonl" && echo "$OUT" | grep -q 'under the'; } \
  && ok "under the cap: untouched, exit 0" || bad "under the cap: rc=$RC out='$OUT'"

# cut point that is exactly on a line boundary (the byte before the window is the newline)
H="$T/h3"; mkdir -p "$H"
X="$(printf 'x%.0s' $(seq 1 96))"
for i in $(seq -w 1 20); do printf 'L%s%s\n' "$i" "$X"; done > "$H/history.jsonl"   # 20 lines × 100 B
[ "$(fsize "$H/history.jsonl")" = 2000 ] || bad "fixture h3 is not 2000 bytes"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=1000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=500
{ [ "$(fsize "$H/history.jsonl")" = 500 ] && [ "$(head -c3 "$H/history.jsonl")" = "L16" ]; } \
  && ok "window already on a line start: exactly 5 whole lines kept (L16..L20)" \
  || bad "boundary cut: size=$(fsize "$H/history.jsonl") first='$(head -c3 "$H/history.jsonl")'"

# no line break in the tail → the file is left alone, and that is reported as a failure
H="$T/h4"; mkdir -p "$H"
{ make_history "$H/history.jsonl" 10; head -c 300000 /dev/zero | tr '\0' 'y'; } > "$T/h4.tmp"; mv "$T/h4.tmp" "$H/history.jsonl"
cp "$H/history.jsonl" "$T/h4.orig"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
{ [ "$RC" -eq 1 ] && cmp -s "$T/h4.orig" "$H/history.jsonl" && echo "$OUT" | grep -q 'no line break'; } \
  && ok "no line break in the tail: untouched, exit 1 (cannot cut safely ≠ nothing to do)" || bad "no-newline tail: rc=$RC out='$OUT'"

# the only line break is the very last byte → nothing would be kept → untouched
H="$T/h5"; mkdir -p "$H"
{ head -c 200000 /dev/zero | tr '\0' 'z'; echo; } > "$H/history.jsonl"; cp "$H/history.jsonl" "$T/h5.orig"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
{ [ "$RC" -eq 1 ] && cmp -s "$T/h5.orig" "$H/history.jsonl"; } \
  && ok "one huge line: never emptied, exit 1" || bad "huge single line: rc=$RC out='$OUT'"

# history.jsonl that is a symlink → not followed
H="$T/h6"; mkdir -p "$H"; make_history "$T/h6.target" 4000; cp "$T/h6.target" "$T/h6.target.orig"
ln -s "$T/h6.target" "$H/history.jsonl"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
{ [ "$RC" -eq 1 ] && cmp -s "$T/h6.target.orig" "$T/h6.target"; } \
  && ok "symlinked history.jsonl: not followed, target untouched, exit 1" || bad "symlink: rc=$RC out='$OUT'"

# missing history.jsonl → nothing to rotate, exit 0
H="$T/h7"; mkdir -p "$H"
run_trim "$H"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'history: .* does not exist'; } \
  && ok "no history.jsonl: nothing to rotate, exit 0" || bad "missing history: rc=$RC out='$OUT'"

# unusable limits → that part is skipped, file untouched, exit 1
H="$T/h8"; mkdir -p "$H"; make_history "$H/history.jsonl" 4000; cp "$H/history.jsonl" "$T/h8.orig"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=abc
R1=$RC; cmp -s "$T/h8.orig" "$H/history.jsonl" && U1=1 || U1=0
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=1000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=1000
R2=$RC; cmp -s "$T/h8.orig" "$H/history.jsonl" && U2=1 || U2=0
{ [ "$R1" -eq 1 ] && [ "$U1" = 1 ] && [ "$R2" -eq 1 ] && [ "$U2" = 1 ]; } \
  && ok "non-numeric MAX, and KEEP >= MAX: skipped, untouched, exit 1" || bad "bad limits: rc=$R1/$R2 untouched=$U1/$U2"

# freed MB is logged
H="$T/h9"; mkdir -p "$H"; yes "$(printf 'p%.0s' $(seq 1 99))" | head -c 3145728 > "$H/history.jsonl"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=2097152 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=1048576
{ echo "$OUT" | grep -q 'freed≈2 MB' && echo "$OUT" | grep -q 'OK — history=rotated'; } \
  && ok "the MB freed is logged (3 MB → 1 MB: freed≈2 MB)" || bad "freed line: '$OUT'"

# dry-run and the kill switch change nothing
H="$T/h10"; mkdir -p "$H"; make_history "$H/history.jsonl" 4000; cp "$H/history.jsonl" "$T/h10.orig"
run_trim "$H" CLAUDE_HOME_TRIM_DRY_RUN=1 CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
R1=$RC; echo "$OUT" | grep -q 'DRY-RUN' && D1=1 || D1=0
run_trim "$H" CLAUDE_HOME_TRIM_ENABLED=0 CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
R2=$RC; echo "$OUT" | grep -q 'DISABLED' && D2=1 || D2=0
{ [ "$R1" -eq 0 ] && [ "$D1" = 1 ] && [ "$R2" -eq 0 ] && [ "$D2" = 1 ] && cmp -s "$T/h10.orig" "$H/history.jsonl"; } \
  && ok "DRY_RUN=1 and ENABLED=0: report only, file untouched" || bad "dry-run/kill switch: rc=$R1/$R2 reported=$D1/$D2"

# a line appended by a writer WHILE the cut runs is carried over (deterministic, via a hook)
H="$T/h11"; mkdir -p "$H"; make_history "$H/history.jsonl" 4000; cp "$H/history.jsonl" "$T/h11.orig"
HOUT="$(pyrun '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cht", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
path = sys.argv[2]
orig = m._pwrite_all
calls = {"n": 0}
def hooked(fd, data, off):
    calls["n"] += 1
    if calls["n"] in (1, 2):   # a writer appends before the kept part is written, and again during the copy-back
        with open(path, "ab") as f:
            f.write(b"APPENDED-DURING-CUT-%d\n" % calls["n"])
    return orig(fd, data, off)
m._pwrite_all = hooked
print(m.rotate_history(path, 100000, 40000, False)[0])
' "$H/history.jsonl")"
{ [ "$(tail -n2 "$H/history.jsonl" | head -n1)" = "APPENDED-DURING-CUT-1" ] \
  && [ "$(tail -n1 "$H/history.jsonl")" = "APPENDED-DURING-CUT-2" ] \
  && [ "$(tail -n3 "$H/history.jsonl" | head -n1)" = "$(tail -n1 "$T/h11.orig")" ] \
  && [ "$(echo "$HOUT" | tail -n1)" = "rotated" ]; } \
  && ok "lines appended during the cut survive it, in order" || bad "append-during-cut: '$(tail -n3 "$H/history.jsonl")' / $HOUT"

# ── file-history ────────────────────────────────────────────────────────────
echo "-- file-history --"
A=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa   # old, nothing alive → deleted
B=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb   # new → kept
C=cccccccc-cccc-4ccc-8ccc-cccccccccccc   # folder old, but a file inside is new → kept
D=dddddddd-dddd-4ddd-8ddd-dddddddddddd   # old, but gc lists it → kept
E=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee   # old, but its transcript is fresh → kept
F=ffffffff-ffff-4fff-8fff-ffffffffffff   # old, but it is the caller's own session → kept
G=99999999-9999-4999-8999-999999999999   # old symlink to a dir → kept, target kept
J=11111111-1111-4111-8111-111111111111   # 2 days old → younger than the 3 day limit → kept
K=22222222-2222-4222-8222-222222222222   # old, but one subdir cannot be read → kept (cannot tell)

mkfh() {   # mkfh <home>
  local h="$1"
  mkdir -p "$h/file-history" "$h/projects/-Users-fixture"
  local s
  for s in $A $B $C $D $E $F $J $K; do
    mkdir -p "$h/file-history/$s"; echo "snapshot of $s" > "$h/file-history/$s/0123abcd@v1"
  done
  mkdir -p "$h/file-history/not-a-session"; echo x > "$h/file-history/not-a-session/f"
  mkdir -p "$T/g.target"; echo keep > "$T/g.target/f"; ln -s "$T/g.target" "$h/file-history/$G"
  mkdir -p "$h/file-history/$K/sub"; echo y > "$h/file-history/$K/sub/f"
  echo '{}' > "$h/projects/-Users-fixture/$E.jsonl"
  # ages, files first then their folders (touching a file does not move the folder's mtime)
  old 10 "$h/file-history/$A/0123abcd@v1" "$h/file-history/$D/0123abcd@v1" "$h/file-history/$E/0123abcd@v1" \
         "$h/file-history/$F/0123abcd@v1" "$h/file-history/$C/0123abcd@v1" "$h/file-history/$K/0123abcd@v1" \
         "$h/file-history/$K/sub/f" "$h/file-history/not-a-session/f" "$h/projects/-Users-fixture/$E.jsonl"
  old 2  "$h/file-history/$J/0123abcd@v1"
  touch "$h/file-history/$B/0123abcd@v1"
  old 10 "$h/file-history/$A" "$h/file-history/$C" "$h/file-history/$D" "$h/file-history/$E" "$h/file-history/$F" \
         "$h/file-history/$K/sub" "$h/file-history/$K" "$h/file-history/not-a-session"
  old 2  "$h/file-history/$J"
  touch "$h/file-history/$C/fresh-edit"            # C: folder mtime moves with this, so age it back; the file stays new
  old 10 "$h/file-history/$C"
  # E's session transcript is old in the fixture above; make it fresh for the "fresh transcript" case
  touch "$h/projects/-Users-fixture/$E.jsonl"
}
exists() { [ -e "$1" ] || [ -L "$1" ]; }

H="$T/f1"; mkfh "$H"
chmod 000 "$H/file-history/$K/sub"
echo "{\"sessions\":[{\"session_key\":\"$D\"},{\"session_key\":\"unrelated\"},{\"no_key\":1}]}" > "$T/gc-d.json"
FAKE_GC_OUT="$T/gc-d.json" run_trim "$H" CLAUDE_CODE_SESSION_ID="$F"
chmod 755 "$H/file-history/$K/sub"
[ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'file-history: DELETED' \
  && ok "file-history prune ran, exit 0" || bad "file-history run: rc=$RC out='$OUT'"
exists "$H/file-history/$A" && bad "old idle dir A should be deleted" || ok "old idle dir with nobody alive is deleted"
exists "$H/file-history/$B" && ok "a new dir stays" || bad "new dir B was deleted"
exists "$H/file-history/$C" && ok "an old folder with a new file inside stays" || bad "dir C (new file inside) was deleted"
exists "$H/file-history/$D" && ok "a dir whose session gc lists as alive stays" || bad "live dir D was deleted"
exists "$H/file-history/$E" && ok "a dir whose transcript was written recently stays" || bad "dir E (fresh transcript) was deleted"
exists "$H/file-history/$F" && ok "the caller's own session dir stays" || bad "own-session dir F was deleted"
{ exists "$H/file-history/$G" && [ -f "$T/g.target/f" ]; } \
  && ok "an old symlink is neither followed nor removed" || bad "symlink G or its target was removed"
exists "$H/file-history/$J" && ok "a dir younger than 3 days stays" || bad "2-day dir J was deleted"
exists "$H/file-history/$K" && ok "a dir with an unreadable part stays (cannot tell → keep)" || bad "unreadable dir K was deleted"
exists "$H/file-history/not-a-session" && ok "a folder that is not a session id stays" || bad "not-a-session was deleted"

# gc cannot answer → NOTHING is deleted, exit 1
H="$T/f2"; mkfh "$H"
run_trim "$H" FAKE_GC_RC=3 CLAUDE_CODE_SESSION_ID="$F"
{ [ "$RC" -eq 1 ] && exists "$H/file-history/$A" && echo "$OUT" | grep -q 'ABORT'; } \
  && ok "gc session list fails: nothing deleted, exit 1" || bad "gc failure: rc=$RC A-exists=$(exists "$H/file-history/$A" && echo y || echo n) out='$OUT'"

# gc answers with the wrong shape → NOTHING is deleted
H="$T/f3"; mkfh "$H"; BADOK=1
for body in '{"sessions":null}' '{"sessions":"x"}' '[]' 'not json' ''; do
  printf '%s\n' "$body" > "$T/gc-bad.json"
  FAKE_GC_OUT="$T/gc-bad.json" run_trim "$H" CLAUDE_CODE_SESSION_ID="$F"
  { [ "$RC" -eq 1 ] && exists "$H/file-history/$A"; } || { BADOK=0; echo "    (body '$body': rc=$RC)"; }
done
[ "$BADOK" = 1 ] && ok "gc answer null / non-array / bare array / garbage / empty: nothing deleted, exit 1" \
                 || bad "a malformed gc answer let the prune go ahead"

# an empty but well-formed gc answer is a real "nobody is alive": A and D (idle, no fresh transcript) go; E (fresh transcript) and F (self) stay
H="$T/f4"; mkfh "$H"
run_trim "$H" CLAUDE_CODE_SESSION_ID="$F"
{ [ "$RC" -eq 0 ] && ! exists "$H/file-history/$A" && ! exists "$H/file-history/$D" \
  && exists "$H/file-history/$E" && exists "$H/file-history/$F"; } \
  && ok "{\"sessions\":[]} is a valid answer: idle A and D go; E (fresh transcript) and F (self) stay" \
  || bad "empty-but-valid gc answer: rc=$RC A=$(exists "$H/file-history/$A" && echo kept || echo gone) D=$(exists "$H/file-history/$D" && echo kept || echo gone) out='$OUT'"

# no projects/ → the transcript check cannot be done → nothing deleted
H="$T/f5"; mkfh "$H"; rm -rf "$H/projects"
run_trim "$H" CLAUDE_CODE_SESSION_ID="$F"
{ [ "$RC" -eq 1 ] && exists "$H/file-history/$A" && echo "$OUT" | grep -q 'not a directory'; } \
  && ok "no projects/ dir: cannot check transcripts → nothing deleted, exit 1" || bad "no projects: rc=$RC out='$OUT'"

# dry-run reports and deletes nothing
H="$T/f6"; mkfh "$H"
run_trim "$H" CLAUDE_HOME_TRIM_DRY_RUN=1 CLAUDE_CODE_SESSION_ID="$F"
{ [ "$RC" -eq 0 ] && exists "$H/file-history/$A" && echo "$OUT" | grep -q 'DRY-RUN would delete'; } \
  && ok "dry-run: says what it would delete, deletes nothing" || bad "file-history dry-run: rc=$RC out='$OUT'"

# no file-history dir at all
H="$T/f7"; mkdir -p "$H"
run_trim "$H"
{ [ "$RC" -eq 0 ] && echo "$OUT" | grep -q 'file-history: .* does not exist'; } \
  && ok "no file-history dir: nothing to prune, exit 0" || bad "missing file-history: rc=$RC out='$OUT'"

# ── report-only files are never touched ────────────────────────────────────
echo "-- report-only --"
H="$T/r1"; mkdir -p "$H"; make_history "$H/usage-analytics.jsonl" 20000; make_history "$H/credit-cache-updater.log" 20000; make_history "$H/history.jsonl" 4000
cksum "$H/usage-analytics.jsonl" "$H/credit-cache-updater.log" > "$T/r1.sum"
run_trim "$H" CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000
cksum "$H/usage-analytics.jsonl" "$H/credit-cache-updater.log" | cmp -s - "$T/r1.sum" \
  && ok "usage-analytics.jsonl and credit-cache-updater.log are measured, never modified" || bad "a report-only file changed"

# ── production sentinel ─────────────────────────────────────────────────────
echo "-- sentinel --"
H="$T/s1"; mkdir -p "$H"; make_history "$H/history.jsonl" 4000; cp "$H/history.jsonl" "$T/s1.orig"
SENT='
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cht", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.REAL_DEFAULT_HOME = sys.argv[2]
sys.exit(m.main())
'
env CLAUDE_HOME_TRIM_HOME="$H" CLAUDE_HOME_TRIM_GC_BIN="$T/fake-gc" FAKE_GC_OUT="$T/gc-empty.json" \
    CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000 \
    python3 -I -c "$SENT" "$SCRIPT" "$H" > "$T/s1.out" 2>&1; R1=$?
{ [ "$R1" -eq 0 ] && cmp -s "$T/s1.orig" "$H/history.jsonl" && grep -q 'SENTINEL' "$T/s1.out" && grep -q 'DRY-RUN' "$T/s1.out"; } \
  && ok "the real home without CLAUDE_HOME_TRIM_PROD=1: forced dry-run, file untouched" || bad "sentinel (no PROD): rc=$R1 out='$(cat "$T/s1.out")'"
env CLAUDE_HOME_TRIM_HOME="$H" CLAUDE_HOME_TRIM_GC_BIN="$T/fake-gc" FAKE_GC_OUT="$T/gc-empty.json" CLAUDE_HOME_TRIM_PROD=1 \
    CLAUDE_HOME_TRIM_HISTORY_MAX_BYTES=100000 CLAUDE_HOME_TRIM_HISTORY_KEEP_BYTES=40000 \
    python3 -I -c "$SENT" "$SCRIPT" "$H" > "$T/s1.out" 2>&1; R2=$?
{ [ "$R2" -eq 0 ] && [ "$(fsize "$H/history.jsonl")" -le 40000 ] && ! grep -q 'SENTINEL' "$T/s1.out"; } \
  && ok "the real home with CLAUDE_HOME_TRIM_PROD=1: it cuts" || bad "sentinel (PROD=1): rc=$R2 size=$(fsize "$H/history.jsonl") out='$(cat "$T/s1.out")'"

# the script's own default home is the real one, so the sentinel constant must match what the guard passes
grep -q '^REAL_DEFAULT_HOME = "/Users/athos/.claude"$' "$SCRIPT" \
  && ok "REAL_DEFAULT_HOME names the real ~/.claude" || bad "REAL_DEFAULT_HOME constant changed"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
