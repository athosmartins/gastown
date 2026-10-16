#!/usr/bin/env bash
# third-state-report.selftest.sh — hermetic selftest of third-state-report.py (ga-57e7l0.2). Scratch cities with synthetic
# quality-gate.jsonl / e12-roster.jsonl / ledger and a STUB `bd` (THIRD_STATE_BD), so nothing live is read or written.
#
# What it proves, in three groups:
#   A. the three states against fixtures — DATA (clean percentages, exact numbers), NO DATA ("sem dado", n<5 "sem conclusão"),
#      DON'T KNOW ("NÃO SEI" exit 2 / "sem leitura"); a failed read is never folded into the empty answer;
#   B. the story's controls, each of which must FAIL: missing file, corrupted line, empty window (and unreadable/empty log);
#   C. mutation: six one-line mutants of the script (a bad line silently dropped, an unread gate run counted as "outro", a missing file
#      read as empty, no n<5 floor, the label counted in the non-blocking part, an absent roster read as "nobody enrolled") — each mutant
#      must be caught by the assertion written for it. A selftest that never failed proves nothing.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/third-state-report.py"
W="$(mktemp -d "${TMPDIR:-/tmp}/third-state-st.XXXXXX")" || exit 1
case "$W" in /?*) ;; *) echo "FAIL: mktemp gave no usable path"; exit 1 ;; esac
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
NOW=2026-10-16T09:00:00Z

# ── stub bd: `bd -C <city> comments <run> --json`; fixtures in $STUB/<run>.json; <run>.fail → exit 1; <run>.hang → sleeps; <run>.junk → garbage
STUB="$W/stub"; mkdir -p "$STUB"
cat > "$W/bd" <<'EOF'
#!/bin/bash
run="$4"; echo "$run" >> "$STUB_DIR/calls.log"
[ -e "$STUB_DIR/$run.fail" ] && exit 1
[ -e "$STUB_DIR/$run.hang" ] && sleep 6
[ -e "$STUB_DIR/$run.junk" ] && { echo "<<not json>>"; exit 0; }
[ -e "$STUB_DIR/$run.json" ] && { cat "$STUB_DIR/$run.json"; exit 0; }
echo "[]"
EOF
chmod +x "$W/bd"; export STUB_DIR="$STUB" THIRD_STATE_BD="$W/bd"

python3 - "$STUB" <<'EOF'
import json, sys
d = sys.argv[1]
def put(run, blocking, nonblocking=""):
    t = "Gate FAILED.\nBranch: x\n\nBlocking reasons:\nReviewer 1 FAIL: VERDICT: FAIL\n\n" + blocking
    if nonblocking:
        t += "\n\nNon-blocking findings:\n" + nonblocking
    c = [{"id": "1", "issue_id": run, "author": "T", "text": t, "created_at": "2026-10-12T00:00:00Z"},
         {"id": "2", "issue_id": run, "author": "T", "text": "Vector B: orphan gate-run superseded.", "created_at": "2026-10-12T00:01:00Z"}]
    json.dump(c, open("%s/%s.json" % (d, run), "w"))
lab = "Blocking issue 1 (third state — root-class:error-vs-empty): f.sh:1 a failed read becomes empty."
for r in ("R-P2", "R-P7", "R-P8", "R-O0", "R-O5"):
    put(r, lab, "- nit")
put("R-P3", "Blocking issue 1 (style): naming.", "- (root-class:error-vs-empty) only mentioned here, not blocking")
put("R-P6", "Blocking issue 1 (logic): off by one.")
json.dump([{"id": "1", "issue_id": "R-T2", "author": "T", "text": "Gate FAILED. no blocking section here", "created_at": "x"}], open(d + "/R-T2.json", "w"))
EOF
touch "$STUB/R-O4.fail" "$STUB/R-T1.junk" "$STUB/R-T3.hang"

# ── main fixture: window 2026-10-09T09:00Z → $NOW. P* = Pilot (in roster), O* = outside, M1 = merge failure after PASS
mkcity() { mkdir -p "$W/$1/.gc"; }
v() { printf '{"ts":"%s","event":"dispatcher_complete","branch":"b","bead":"%s","rig":"gascity","tier":"CODE","result":"%s","reason":"%s","gate_run":"%s","dry_run":"%s"}\n' "$1" "$2" "$3" "$4" "$5" "${6:-0}"; }
RV="Reviewer 1 FAIL: VERDICT: FAIL"
mkcity main; L="$W/main/.gc/quality-gate.jsonl"
{
  v 2026-10-10T10:00:00Z P1 PASS ok r1;  v 2026-10-10T11:00:00Z P2 FAIL "$RV" R-P2; v 2026-10-11T11:00:00Z P2 PASS ok r2
  v 2026-10-10T12:00:00Z P3 FAIL "$RV" R-P3; v 2026-10-10T13:00:00Z P4 PASS ok r4; v 2026-10-10T14:00:00Z P5 PASS ok r5
  v 2026-10-12T10:00:00Z P6 FAIL "$RV" R-P6; v 2026-10-13T10:00:00Z P7 FAIL "$RV" R-P7; v 2026-10-13T11:00:00Z P8 FAIL "$RV" R-P8
  v 2026-10-01T10:00:00Z O0 PASS ok r0;  v 2026-10-12T12:00:00Z O0 FAIL "$RV" R-O0
  v 2026-10-11T10:00:00Z O1 PASS ok r6;  v 2026-10-11T11:00:00Z O2 PASS ok r7;  v 2026-10-11T12:00:00Z O3 PASS ok r8
  v 2026-10-14T10:00:00Z O4 FAIL "$RV" R-O4; v 2026-10-14T11:00:00Z O5 FAIL "$RV" R-O5
  v 2026-10-15T10:00:00Z O6 PASS ok r9;  v 2026-10-15T11:00:00Z O7 PASS ok r10
  v 2026-10-15T12:00:00Z M1 PASS ok r11; v 2026-10-15T13:00:00Z M1 FAIL "Merge failed after all-PASS: conflict" R-M1
  v 2026-10-12T00:00:00Z D1 FAIL "$RV" R-D1 1                     # dry run: out
  v 2026-10-12T01:00:00Z S1 SKIPPED_BEAD_CLOSED closed r12         # not a verdict: out
  v 2026-10-17T00:00:00Z F1 PASS ok r13                            # after the window end: out
  echo '{"ts":"2026-10-12T02:00:00Z","event":"guard_dispatched","bead":"G1"}'
} > "$L"
for p in 1 2 3 4 5 6 7 8; do printf '{"event":"assign","bead":"P%s","arm":"treated","stage":"pilot-dispatch"}\n' "$p"; done > "$W/main/.gc/e12-roster.jsonl"
printf '{"event":"assign","bead":"PX","arm":"control"}\n' >> "$W/main/.gc/e12-roster.jsonl"
printf '# comment\nP6\t2026-10-12\t3o-estado\tmanual test\n' > "$W/ledger.tsv"

run() { # run <city> [args...] → $W/out, RC
  local c="$1"; shift
  RC=0; python3 "${SCRIPT_UNDER_TEST:-$SCRIPT}" --city "$W/$c" --now "$NOW" --ledger "$W/ledger.tsv" --timeout-s 2 "$@" > "$W/out" 2> "$W/err" || RC=$?
}
has()  { grep -qF -- "$1" "$W/out"; }
hasx() { grep -qE -- "$1" "$W/out"; }
chk()  { if "$@"; then ok; else bad "$* — $CASE"; sed 's/^/    | /' "$W/out" | head -40; fi; }
sums() { shasum "$W/main/.gc/quality-gate.jsonl" "$W/main/.gc/e12-roster.jsonl" "$W/ledger.tsv" | tr '\n' ' '; }

# ── A. the three states on the main fixture ──────────────────────────────────────────────────
CASE="main fixture"; before="$(sums)"; : > "$STUB/calls.log"; run main
chk test "$RC" -eq 0
chk has "19 vereditos reais na janela (16 beads com 1ª tentativa na janela), 8 reprovações de revisor, 1 FAIL que não são rejeição"
chk has "5 pelo rótulo root-class:error-vs-empty na parte bloqueante, 1 pela classificação manual"
chk hasx '^  todos +56% \(9/16\) +NÃO atinge +86% \(6/7\), faixa 75–88% · sem leitura: 1 +NÃO atinge'      # DATA with one unknown: the range, not a clean 86%
chk hasx '^  Pilot sling \(no roster E12\) +38% \(3/8\) +NÃO atinge +80% \(4/5\) +NÃO atinge'                  # label x3 + manual x1 + 1 outro (label only in the non-blocking part)
chk hasx '^  fora do roster \(pool/crew\) +75% \(6/8\) +atinge +n<5, sem conclusão \(n=2\) · sem leitura: 1'  # NO CONCLUSION: n<5 and the unread one is shown, not zeroed
chk hasx '^  E12 control +sem dado +- +sem dado'                                                               # NO DATA: enrolled in the control arm, nothing delivered
chk hasx '^  E12 treated +38% \(3/8\)'
chk has "fatia 2 NÃO ligada"
chk test "$(sums)" = "$before"                                                                                 # read-only: inputs untouched
chk test "$(ls -A "$W/main/.gc" | tr '\n' ' ')" = "e12-roster.jsonl quality-gate.jsonl third-state-report.cache.json "
chk test "$(grep -c . "$STUB/calls.log")" -eq 7                                                                 # one read per distinct gate run: 6 answered + O4 failing
CASE="cache"; : > "$STUB/calls.log"; cp "$W/out" "$W/out.first"; run main
chk cmp -s "$W/out" "$W/out.first"
chk test "$(cat "$STUB/calls.log")" = "R-O4"                                                                    # answered reads are cached; the unanswered one is asked again
chk test "$(grep -c 'R-O4' "$W/main/.gc/third-state-report.cache.json")" -eq 0                                  # and never cached as an answer
CASE="cache corrupted"; printf 'not json{' > "$W/main/.gc/third-state-report.cache.json"; run main
chk cmp -s "$W/out" "$W/out.first"
CASE="no-classify"; rm -f "$W/main/.gc/third-state-report.cache.json"; : > "$STUB/calls.log"; run main --no-classify
chk hasx '^  todos +56% \(9/16\) +NÃO atinge +n<5, sem conclusão \(n=1\) · sem leitura: 7'                      # only the manual answer is left; the 7 label reads are "sem leitura", not "outro"
chk test "$(grep -c . "$STUB/calls.log")" -eq 0
CASE="python 3.9"; if /usr/bin/python3 -c 'import sys' 2>/dev/null; then
  RC=0; /usr/bin/python3 "$SCRIPT" --city "$W/main" --now "$NOW" --ledger "$W/ledger.tsv" --no-classify > "$W/out39" 2>&1 || RC=$?
  run main --no-classify; chk test "$RC" -eq 0; chk cmp -s "$W/out" "$W/out39"; else echo "SKIP: no /usr/bin/python3"; fi

CASE="slice 2 on, no arm record"; touch "$W/main/.gc/third-state-reads.conf"; run main
chk has "NÃO SEI — a conf existe mas .gc/third-state-reads-arms.jsonl está ausente"
CASE="slice 2 on, with arm record"; printf '{"bead":"O1","arm":"enforce"}\n{"bead":"O2","arm":"enforce"}\n{"bead":"O3","arm":"holdout"}\n' > "$W/main/.gc/third-state-reads-arms.jsonl"; run main
chk hasx '^  com a checagem \(enforce\) +n<5, sem conclusão \(n=2\)'
chk hasx '^  sem registro de braço +'
rm -f "$W/main/.gc/third-state-reads.conf" "$W/main/.gc/third-state-reads-arms.jsonl"

CASE="roster absent"; mv "$W/main/.gc/e12-roster.jsonl" "$W/roster.bak"; run main
chk has "NÃO SEI — o roster .gc/e12-roster.jsonl está ausente"                                                    # not "nobody enrolled"
chk test "$(grep -c 'Pilot sling' "$W/out")" -eq 0
mv "$W/roster.bak" "$W/main/.gc/e12-roster.jsonl"
CASE="ledger absent / junk row"; run main --ledger "$W/nope.tsv"; chk has "NÃO SEI: ledger manual ausente"
printf 'junk row\nP6\t2026-10-12\t3o-estado\tx\n' > "$W/ledger2.tsv"; run main --ledger "$W/ledger2.tsv"; chk has "1 linhas ilegíveis no ledger manual"

# gate runs that cannot be read: garbage JSON, a comment with no blocking part, a timeout — all "sem leitura", never "outro"
CASE="unreadable gate runs"; mkcity t3
{ v 2026-10-12T10:00:00Z T1 FAIL "$RV" R-T1; v 2026-10-12T11:00:00Z T2 FAIL "$RV" R-T2; v 2026-10-12T12:00:00Z T3 FAIL "$RV" R-T3; } > "$W/t3/.gc/quality-gate.jsonl"
: > "$W/t3/.gc/e12-roster.jsonl"; run t3
chk test "$RC" -eq 0
chk hasx '^  todos +n<5, sem conclusão \(n=3\) +- +n<5, sem conclusão \(n=0\) · sem leitura: 3'    # 3 unread runs: never 0%, never "outro"

# ── B. the story's controls: each of these must NOT produce a clean zero ────────────────────────────────────
CASE="control: missing gate log"; mkcity miss; run miss
chk test "$RC" -eq 2; chk has "NÃO SEI: o arquivo não existe"; chk has "NÃO é 0 beads"; chk test "$(grep -cE '[0-9]+% \(' "$W/out")" -eq 0
CASE="control: empty gate log"; mkcity empty; : > "$W/empty/.gc/quality-gate.jsonl"; run empty
chk test "$RC" -eq 2; chk has "NÃO SEI: o arquivo está vazio"
CASE="control: unreadable gate log"; mkcity unr; cp "$L" "$W/unr/.gc/quality-gate.jsonl"; chmod 000 "$W/unr/.gc/quality-gate.jsonl"
if [ -r "$W/unr/.gc/quality-gate.jsonl" ]; then echo "SKIP: running as a user that can read mode 000"; else run unr; chk test "$RC" -eq 2; chk has "NÃO SEI: o arquivo não pôde ser lido"; fi
CASE="control: corrupted line"; mkcity corr; cp "$L" "$W/corr/.gc/quality-gate.jsonl"; cp "$W/main/.gc/e12-roster.jsonl" "$W/corr/.gc/"
printf '{"ts":"2026-10-12T05:00:00Z","event":"dispatcher_complete","bead":"Z9","result":"FAI\n' >> "$W/corr/.gc/quality-gate.jsonl"
printf 'xx not json at all\n' >> "$W/corr/.gc/quality-gate.jsonl"; run corr --no-classify
chk test "$RC" -eq 0; chk has "2 linhas ilegíveis no quality-gate.jsonl"; chk has "1 têm ts legível dentro da janela"; chk has "19 vereditos reais na janela"
CASE="control: empty window"; mkcity ew; v 2026-09-01T10:00:00Z E1 PASS ok r1 > "$W/ew/.gc/quality-gate.jsonl"; : > "$W/ew/.gc/e12-roster.jsonl"; run ew
chk test "$RC" -eq 0; chk hasx '^  todos +sem dado +- +sem dado +-'; chk test "$(grep -E '^  [a-zA-Z]' "$W/out" | grep -cE '[0-9]+% \(')" -eq 0; chk has "0 vereditos reais na janela (0 beads"
CASE="usage"; python3 "$SCRIPT" --days 0 > /dev/null 2>&1; chk test "$?" -eq 64

# ── C. mutants: each must be CAUGHT by the assertion written against it ───────────────────────────────────
mutant() { # mutant <name> <old> <new> <city> <expected rc> <expected text> [args]
  local name="$1" old="$2" new="$3" city="$4" erc="$5" txt="$6"; shift 6
  mkdir -p "$W/mut"; python3 - "$SCRIPT" "$W/mut/m.py" "$old" "$new" <<'EOF'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
if s.count(sys.argv[3]) != 1:
    sys.exit("mutation anchor found %d times" % s.count(sys.argv[3]))
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4]))
EOF
  if [ $? -ne 0 ]; then bad "mutant $name: could not apply (the script changed under the mutation anchor)"; return; fi
  rm -f "$W/$city/.gc/third-state-report.cache.json"        # answers cached by the real script would hide what the mutant does
  SCRIPT_UNDER_TEST="$W/mut/m.py" run "$city" "$@"
  if grep -q Traceback "$W/err"; then bad "mutant '$name' crashed instead of misbehaving — that is not a catch"; return; fi
  if [ "$RC" -eq "$erc" ] && grep -qF -- "$txt" "$W/out"; then bad "mutant '$name' SURVIVED — nothing in this selftest notices it"; else ok; fi
}
mutant "bad line silently dropped" '        bad += 1
        m = TS_RE' '        m = TS_RE' corr 0 "2 linhas ilegíveis no quality-gate.jsonl" --no-classify
mutant "unread gate run counted as outro" '        if p.returncode != 0:
            return None' '        if p.returncode != 0:
            return "outro"' main 0 "sem leitura: 1"
mutant "missing gate log read as empty" 'if st != "ok" or not rows:' 'if False:' miss 2 "NÃO SEI: o arquivo não existe"
mutant "no n<5 floor" 'MIN_N = 5' 'MIN_N = 0' main 0 "n<5, sem conclusão (n=2)"
mutant "label counted in the non-blocking part" 'text.find("Non-blocking findings:", i)' 'text.find("zzz", i)' main 0 "80% (4/5)"
mutant "absent roster read as nobody enrolled" '        return "absent", [], 0, []' '        return "ok", [], 0, []' main 0 "NÃO SEI — o roster"

# ── the order and the files that ship with the report ─────────────────────────────────────────────────────
ORDER="$HERE/../orders/third-state-report.toml"
if [ -f "$ORDER" ]; then
  if python3 -I -c 'import tomllib' 2>/dev/null; then
    python3 -I -c 'import sys,tomllib; d=tomllib.load(open(sys.argv[1],"rb")); o=d["order"]; assert o["trigger"]=="cooldown" and "third-state-report.py" in o["exec"], o' "$ORDER" && ok || bad "order TOML does not parse / does not run the report"
  else echo "SKIP: python3 has no tomllib — order TOML not parsed"; fi
else bad "order missing: $ORDER"; fi
[ -f "$HERE/third-state-manual.tsv" ] && ok || bad "ledger missing: third-state-manual.tsv"
bash -n "$0" && ok || bad "selftest does not parse"

echo "third-state-report selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
