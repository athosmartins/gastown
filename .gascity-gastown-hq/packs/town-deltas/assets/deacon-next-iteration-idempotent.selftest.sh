#!/usr/bin/env bash
# deacon-next-iteration-idempotent.selftest.sh — behavioral drift-guard for ga-x9jivyf (same class as ga-jhsxo4p, which fixed mol-witness-patrol).
#
# Bug ga-x9jivyf: step 3 ("Pour next iteration BEFORE burning") of formulas/mol-deacon-patrol.toml was two lines,
#     NEXT=$(gc bd mol wisp mol-deacon-patrol ... --json | jq -r '.new_epic_id')
#     gc bd update "$NEXT" --assignee=$GC_AGENT
# with no read before the pour, no check that the pour answered with an id, no read of the update's exit code, and prose that went straight on to
# `sleep` (step 4) and to burning the CURRENT wisp (step 5). Two windows ("the pour answered, the next leg did not"):
#   (a) the assign fails (`bd update` answers exit 1 under a Dolt i/o timeout): nothing reads the exit code and nothing says to stop, so the deacon can
#       go on to sleep and burn THIS wisp, leaving a next wisp that has no owner. No `--assignee` read finds an unassigned wisp and the wisp reaper
#       only closes a wisp whose parent is closed (a root-only patrol wisp has none: see mol-dog-reaper.toml and ga-jhsxo4p), so it stays; and a
#       re-run of the block pours ANOTHER one;
#   (b) the pour's answer is lost or unreadable: `jq -r '.new_epic_id'` prints nothing (or the string "null" when the key is missing), and the update runs on
#       that empty or "null" id anyway, while a wisp MAY exist.
#
# The fix makes the step safe to re-run: it READS first (my live wisps, in three states: two or more mean a next wisp already exists, so no pour; one or
# none, pour; the read failed or came back unreadable, "do not know", no pour), reads the assign's exit code and, when it fails, burns the wisp it just poured
# (never the current one), and exits 0 only when a next wisp exists and is assigned. The failures it cannot undo (the burn fails too, the pour's answer is
# lost) say so loudly and mail the mayor with the id (or the read that finds it). The prose says what exit 1 means: do not go on to step 4 (the
# sleep), do not burn this wisp.
#
# The formula has no exec script: an agent reads the step's description and types the shell it finds there. So the unit under test is the text the agent is
# DELIVERED (the TOML parsed by tomllib, escapes consumed), never the raw source (see mol-digest-generate.selftest.sh). The step-3 block is extracted and
# EXECUTED under a stub `gc` on a sandbox PATH. The stub is stateful: one tiny store on disk (one "id|assignee" line per live wisp), faults armed per scenario
# (`mode:count`), and a spy that logs every call. "No pour" / "no burn" are asserted as the ABSENCE of the call and as the state of the store after a RE-RUN;
# the healthy scenarios prove the spy does see a pour and an assign, and Group C (an assign that fails) proves it sees a burn.
#
# Sibling guard for the same class on the other patrol formula: witness-next-iteration-idempotent.selftest.sh (that one pins a rig store with -C; the deacon
# block has no pin and no rig_root: this guard makes no claim about which store a bare `gc bd` resolves).
#
# DEACON_FORMULA_UNDER_TEST overrides the formula (mutant runs, see the delivery of ga-x9jivyf).
# Exit 0 iff every scenario holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
FORMULA="${DEACON_FORMULA_UNDER_TEST:-$HQ_ROOT/formulas/mol-deacon-patrol.toml}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$FORMULA" ] || { echo "FATAL: formula not found at $FORMULA" >&2; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }
# extract() parses the formula with tomllib (Python >= 3.11); on an older python every assertion below would fail on a traceback that hides the real cause.
# The same candidates, in the same order, as the gate's hard checks (gate-hard-checks.sh): the mini's default python3 can be older than its homebrew one.
# vazio → no candidate has tomllib: FATAL exit 2; falhou → a candidate that is missing or cannot import tomllib is skipped, never used
PY=""
for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "FATAL: no python3 with tomllib (>= 3.11) found (tried python3, /opt/homebrew/bin/python3, /usr/local/bin/python3)" >&2; exit 2; }

echo "deacon-next-iteration-idempotent.selftest — ga-x9jivyf: a re-run after pour-ok + assign-failed ends with ONE next wisp"

FAKE_AGENT="gastown.deacon"
HEAD3='**3. Pour next iteration BEFORE burning'

# ── Extract what the agent is delivered ───────────────────────────────────────
# extract MODE [HEAD]: block = the first ```bash fence after the line that starts with HEAD (exactly one such line); desc = the
# step's whole text; steps / needs / vars / tokens = structure.
# vazio → prints nothing (the caller refuses to run an empty block); falhou/ilegível → python exits non-zero (a parse error is a traceback, a missing or duplicated anchor is exit 3/4), the caller reads the exit code
extract() {
  "$PY" -I - "$FORMULA" "$@" <<'PY'
import re, sys, tomllib
path, mode = sys.argv[1], sys.argv[2]
d = tomllib.load(open(path, "rb"))
step = next((s for s in d["steps"] if s["id"] == "next-iteration"), None)
if step is None:
    sys.exit(3)
desc = step["description"]
if mode == "desc":
    sys.stdout.write(desc)
elif mode == "steps":
    print("\n".join(s["id"] for s in d["steps"]))
elif mode == "needs":
    print(",".join(step.get("needs", [])))
elif mode == "vars":
    print("\n".join(sorted(d.get("vars", {}))))
elif mode == "tokens":
    print("\n".join(sorted(set(re.findall(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}", desc)))))
elif mode == "block":
    head = sys.argv[3]
    lines = desc.split("\n")
    at = [i for i, l in enumerate(lines) if l.startswith(head)]
    if len(at) != 1:
        sys.exit(4)
    out, inb = [], False
    for l in lines[at[0] + 1:]:
        if not inb and l == "```bash":
            inb = True
            continue
        if inb and l == "```":
            break
        if inb:
            out.append(l)
    else:
        sys.exit(5)
    print("\n".join(out))
else:
    sys.exit(6)
PY
}
# fill_vars: the two formula variables the way the engine renders them (the deacon has no rig_root)
fill_vars() { sed -e "s|{{binding_prefix}}|bp|g" -e "s|{{event_timeout}}|1|g"; }

STEP3_RAW="$(extract block "$HEAD3")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$STEP3_RAW" ]; then
  ok "formula parses (tomllib) and the step-3 block is found exactly once, after '$HEAD3'"
else
  echo "FATAL: could not isolate the step-3 block (python exit $rc: 3 = no next-iteration step, 4 = heading not found exactly once, 5 = fence not closed) — nothing below can be trusted" >&2
  exit 2
fi
STEP3="$(printf '%s\n' "$STEP3_RAW" | fill_vars)"
DESC="$(extract desc)" || { echo "FATAL: could not read the step description" >&2; exit 2; }

# ── Stub gc + sandbox PATH ────────────────────────────────────────────────────
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# A fake gc with state. $WORLD holds: store (one wisp per line, "id|assignee"), seq (how many pours were attempted),
# spy (one line per call) and fault.<name> ("mode:count": the next <count> calls of that kind misbehave as <mode>).
W="${WORLD:-}"
[ -n "$W" ] && [ -d "$W" ] || { echo "stub gc: WORLD is not set" >&2; exit 98; }
printf 'GC %s\n' "$*" >> "$W/spy"

# fault_mode NAME: prints the armed mode and spends one use; rc 1 when nothing is armed
fault_mode() {
  local f="$W/fault.$1" line mode n
  [ -f "$f" ] || return 1
  line=$(cat "$f"); mode=${line%%:*}; n=${line##*:}
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  n=$((n - 1))
  if [ "$n" -gt 0 ]; then printf '%s:%s\n' "$mode" "$n" > "$f"; else rm -f "$f"; fi
  printf '%s' "$mode"
}
has_id() { grep -q "^$1|" "$sf"; }   # id

case "${1:-}" in
  mail|session) exit 0 ;;
  bd)
    shift
    # the deacon block has no -C pin; if a later edit adds one it still means this single store
    if [ "${1:-}" = "-C" ]; then shift 2; fi
    sf="$W/store"
    case "${1:-}" in
      list)
        who=""; lim=50
        for a in "$@"; do
          case "$a" in
            --assignee=*) who=${a#--assignee=} ;;
            --limit=*) lim=${a#--limit=} ;;
          esac
        done
        if m=$(fault_mode list); then
          case "$m" in
            fail)     echo "Error: timed out after 30s" >&2; exit 1 ;;
            failjson) echo "Error: timed out after 30s" >&2; printf '[]'; exit 1 ;;
            empty)    exit 0 ;;
            text)     echo "Error: database is locked"; exit 0 ;;
            object)   printf '{"error":"x"}'; exit 0 ;;
            overlimit) lim=1000 ;;   # a bd that answers with more rows than --limit asked for
          esac
        fi
        out=""; n=0
        while IFS='|' read -r id as; do
          [ -n "$id" ] || continue
          [ "$as" = "$who" ] || continue
          [ "$n" -lt "$lim" ] || break
          out="$out${out:+,}{\"id\":\"$id\",\"assignee\":\"$as\",\"status\":\"open\",\"issue_type\":\"molecule\"}"
          n=$((n + 1))
        done < "$sf"
        printf '[%s]' "$out"
        exit 0
        ;;
      show)
        id=${2:-}
        if has_id "$id"; then printf '[{"id":"%s"}]' "$id"; exit 0; fi
        echo "Error fetching $id: no issue found matching \"$id\"" >&2
        exit 1
        ;;
      update)
        id=${2:-}; who=""
        for a in "$@"; do
          case "$a" in --assignee=*) who=${a#--assignee=} ;; esac
        done
        um=$(fault_mode update) || um=ok
        case "$um" in
          fail)        echo "Error: 1 of 1 issues failed to update (timed out after 30s)" >&2; exit 1 ;;   # nothing was applied
          failapplied) has_id "$id" && { sed "s#^$id|.*#$id|$who#" "$sf" > "$sf.new" && mv "$sf.new" "$sf"; }
                       echo "Error: 1 of 1 issues failed to update (timed out after 30s)" >&2; exit 1 ;;   # applied, the answer was lost
        esac
        has_id "$id" || { echo "Error resolving $id: no issue found" >&2; exit 1; }
        sed "s#^$id|.*#$id|$who#" "$sf" > "$sf.new" && mv "$sf.new" "$sf"
        exit 0
        ;;
      mol)
        case "${2:-}" in
          wisp)
            pm=$(fault_mode pour) || pm=ok
            n=$(cat "$W/seq"); n=$((n + 1)); echo "$n" > "$W/seq"; id="ga-wisp-new$n"
            case "$pm" in
              fail)    echo "Error: timed out after 30s" >&2; exit 1 ;;                                    # nothing was created
              noid)    echo "$id|" >> "$sf"; exit 1 ;;                                                    # created, the answer was lost
              garbage) echo "$id|" >> "$sf"; echo "Created wisp"; exit 0 ;;                               # created, the answer is not JSON
              nokey)   echo "$id|" >> "$sf"; printf '{"created":1,"phase":"vapor"}'; exit 0 ;;            # created, the answer has no new_epic_id
            esac
            echo "$id|" >> "$sf"
            printf '{"new_epic_id":"%s","created":1,"phase":"vapor"}' "$id"
            exit 0
            ;;
          burn)
            id=${3:-}
            if fault_mode burn >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
            has_id "$id" || { echo "Error: $id not found" >&2; exit 1; }
            grep -v "^$id|" "$sf" > "$sf.new"; mv "$sf.new" "$sf"
            exit 0
            ;;
        esac
        ;;
    esac
    echo "unstubbed gc bd call: $*" >&2
    exit 99
    ;;
esac
echo "unstubbed gc call: $*" >&2
exit 99
STUB
chmod +x "$STUBDIR/bin/gc"
# The block runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh): a vanished stub is "command not found", never the real town.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2   # jq: the parse the block does; gc is the stub above

# ── World + runner ────────────────────────────────────────────────────────────
W=""
# world_new: a fresh world. The wisp being executed (ga-wisp-cur) is live and assigned to this deacon; nothing is armed.
world_new() {
  W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  printf 'ga-wisp-cur|%s\n' "$FAKE_AGENT" > "$W/store"
  : > "$W/spy"; echo 0 > "$W/seq"
}
arm() { printf '%s:%s\n' "$2" "$3" > "$W/fault.$1"; }   # arm KIND MODE COUNT

# run_block CODE [VAR=value ...] — one run of the block in a clean environment (env -i: none of this session's GC_* leaks in).
# Sets OUT (stdout+stderr), RC and SPY_LOG (the gc calls of THIS run, one per line). The world persists between runs: that is the point.
run_block() {
  local code="$1"
  shift
  : > "$W/spy"
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" GC_AGENT="$FAKE_AGENT" "$@" bash -c "$code" 2>&1)"
  RC=$?
  # vazio → no gc call was made (a legitimate answer for the refusals that run before any call); falhou → the spy file is ours, cat cannot fail short of a dead disk
  SPY_LOG="$(cat "$W/spy")"
}
spy_n()     { printf '%s\n' "$SPY_LOG" | grep -c -E -- "$1"; }
spy_first() { printf '%s\n' "$SPY_LOG" | grep -n -E -- "$1" | head -n 1 | cut -d: -f1; }
POUR_RE='^GC bd (-C [^ ]+ )?mol wisp'
BURN_RE='^GC bd (-C [^ ]+ )?mol burn'
UPDATE_RE='^GC bd (-C [^ ]+ )?update '
SHOW_RE='^GC bd (-C [^ ]+ )?show '
LIST_RE='^GC bd (-C [^ ]+ )?list '
MAIL_RE='^GC mail send'
# mail_ok_to_mayor: at least one mail went out and every one of them is addressed to the mayor (vazio → no mail: false; the mails of one run are all in SPY_LOG)
mail_ok_to_mayor() { [ "$(spy_n "$MAIL_RE")" -ge 1 ] && [ "$(spy_n "$MAIL_RE")" -eq "$(spy_n '^GC mail send mayor/ ')" ]; }
# vazio → the file always has the seq line the stub wrote; falhou → a missing file is a harness break (the comparison below then fails loudly)
pours()         { cat "$W/seq"; }
next_count()    { awk -F'|' '$1 != "ga-wisp-cur" && $1 != "" { n++ } END { print n + 0 }' "$W/store"; }                    # live wisps besides the one being executed
assigned_next() { awk -F'|' -v a="${1:-$FAKE_AGENT}" '$1 != "ga-wisp-cur" && $1 != "" && $2 == a { n++ } END { print n + 0 }' "$W/store"; }   # ... of those, assigned to this deacon
cur_alive()     { grep -q '^ga-wisp-cur|' "$W/store"; }

# ── Group A: the healthy cycle ────────────────────────────────────────────────
echo ""
echo "Group A: healthy cycle (this wisp live, no next one)"
world_new
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && cur_alive; then
  ok "exit 0, one pour, one next wisp assigned to this deacon, this wisp neither burned nor touched"
else
  bad "healthy cycle (exit $RC, pours=$(pours), next=$(next_count), assigned=$(assigned_next), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
if printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-new1'; then ok "the output names the next wisp"; else bad "the output does not name the next wisp: $OUT"; fi
if printf '%s\n' "$OUT" | tail -n 1 | grep -F -q 'go on to step 4'; then ok "the last line tells the deacon to go on to step 4 (its cue that exit 0 means a next wisp exists)"; else bad "the block does not end by telling the deacon to go on to step 4: $OUT"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd list --assignee=$FAKE_AGENT --type=molecule --include-infra --limit=2 --json"; then
  ok "the read is by this deacon's identity, molecules incl. infra, limit 2 (two or more is all it needs to see)"
else
  bad "the read is not the expected shape (--assignee=GC_AGENT --type=molecule --include-infra --limit=2 --json): $SPY_LOG"
fi
r="$(spy_first "$LIST_RE")"; p="$(spy_first "$POUR_RE")"
if [ -n "$r" ] && [ -n "$p" ] && [ "$r" -lt "$p" ]; then ok "the read comes BEFORE the pour"; else bad "the read does not precede the pour (read line '$r', pour line '$p'): $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd mol wisp mol-deacon-patrol --root-only --var binding_prefix=bp --json"; then
  ok "the pour is mol-deacon-patrol, root-only, with the binding_prefix variable"
else
  bad "the pour is not 'mol wisp mol-deacon-patrol --root-only --var binding_prefix=bp --json': $SPY_LOG"
fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x "GC bd update ga-wisp-new1 --assignee=$FAKE_AGENT"; then
  ok "the assign names the id the pour answered and this deacon"
else
  bad "the assign is not 'update <the pour's id> --assignee=<GC_AGENT>': $SPY_LOG"
fi
# the same block again in the same world: the one thing the old text could not do
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then
  ok "IDEMPOTENT: the block run a second time pours nothing, assigns nothing, burns nothing (still ONE pour and ONE next wisp), exit 0"
else
  bad "a second run of the block is not a no-op (exit $RC, pours=$(pours) (want 1), next=$(next_count) (want 1), updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
# an identity with a space in it: only a quoted $GC_AGENT reaches the store whole (an unquoted one is split into two words).
# Two worlds, because each quote is visible in a different one: the assign's in the world that pours, the read's in the world that must NOT pour.
SPACED="gastown deacon"
world_new; printf 'ga-wisp-cur|%s\n' "$SPACED" > "$W/store"
run_block "$STEP3" GC_AGENT="$SPACED"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(assigned_next "$SPACED")" -eq 1 ]; then
  ok "GC_AGENT is quoted in the assign (an identity with a space is assigned whole)"
else
  bad "an identity with a space broke the assign (exit $RC, pours=$(pours), assigned=$(assigned_next "$SPACED")) :: $OUT $SPY_LOG"
fi
world_new; printf 'ga-wisp-cur|%s\nga-wisp-nxt|%s\n' "$SPACED" "$SPACED" > "$W/store"
run_block "$STEP3" GC_AGENT="$SPACED"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ]; then
  ok "GC_AGENT is quoted in the read (an identity with a space still finds its next wisp: no pour)"
else
  bad "an identity with a space was not found by the read (exit $RC, pours=$(pours), updates=$(spy_n "$UPDATE_RE")) :: $OUT $SPY_LOG"
fi

# ── Group B: a next wisp already exists -> no pour ────────────────────────────
echo ""
echo "Group B: a next wisp is already there (this one plus a next one) -> no second pour"
world_new; printf 'ga-wisp-nxt|%s\n' "$FAKE_AGENT" >> "$W/store"
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 1 ]; then
  ok "two live wisps of mine -> exit 0, no pour, no assign, no burn"
else
  bad "existing next wisp did not stop the pour (exit $RC, pours=$(pours), updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
if printf '%s\n' "$OUT" | grep -F -q 'already' && printf '%s\n' "$OUT" | tail -n 1 | grep -F -q 'go on to step 4'; then ok "it says a next wisp already exists and to go on to step 4"; else bad "the reuse path is silent or does not say to go on to step 4: $OUT"; fi
world_new; printf 'ga-wisp-a|%s\nga-wisp-b|%s\n' "$FAKE_AGENT" "$FAKE_AGENT" >> "$W/store"
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ]; then ok "three live wisps (leftovers from an old failure) -> still no pour, exit 0"; else bad "three live wisps: exit $RC, pours=$(pours) :: $OUT"; fi
# --limit=2 caps the answer at two rows, so ">= 2" and "== 2" are the same test for a bd that honours it; a bd that does not must still read as "a next wisp exists"
world_new; printf 'ga-wisp-a|%s\nga-wisp-b|%s\n' "$FAKE_AGENT" "$FAKE_AGENT" >> "$W/store"; arm list overlimit 1
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q '(3 live wisps'; then ok "a read that answers with 3 rows although it asked for 2 still means 'a next wisp exists' (the test is >= 2, not == 2)"; else bad "an over-long answer (3 rows) poured or was not read as 'exists': exit $RC, pours=$(pours) :: $OUT"; fi
world_new; printf 'ga-wisp-theirs|some/other.agent\n' >> "$W/store"
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then ok "a live wisp that belongs to someone else does not count: this deacon still pours its own"; else bad "someone else's wisp stopped the pour (exit $RC, pours=$(pours), assigned=$(assigned_next)) :: $OUT"; fi

# ── Group C: THE BUG — the pour worked, the assign did not, then the block is run again ─
echo ""
echo "Group C: pour ok + assign failed, then a re-run -> exactly one next wisp"
# C1: the assign fails and applied nothing (window a)
world_new; arm update fail 1
run_block "$STEP3"; rc1=$RC; out1="$OUT"; left1="$(next_count)"; burn1="$(spy_n '^GC bd mol burn ga-wisp-new1 --force$')"; curburn1="$(spy_n 'mol burn ga-wisp-cur')"
run_block "$STEP3"
if [ "$rc1" -eq 1 ] && [ "$left1" -eq 0 ] && [ "$burn1" -eq 1 ] && [ "$curburn1" -eq 0 ]; then
  ok "THE BUG (a): assign fails -> exit 1, the wisp it just poured is burned (nothing left behind) and THIS wisp is not"
else
  bad "THE BUG (a): assign failed but exit=$rc1, next wisps left=$left1 (want 0), burn of the new wisp=$burn1 (want 1), burn of the current wisp=$curburn1 (want 0) :: $out1"
fi
if [ "$RC" -eq 0 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then
  ok "THE BUG (a): the re-run ends with exactly one next wisp, assigned"
else
  bad "THE BUG (a): after the failed assign and a re-run: exit $RC, next wisps=$(next_count) (want 1), assigned=$(assigned_next) (want 1), pours=$(pours) :: $OUT"
fi
# C2: the assign fails but WAS applied (the answer was lost): the block cannot know, burns the wisp it poured; nothing is left and the re-run starts clean
world_new; arm update failapplied 1
run_block "$STEP3"; rc1=$RC; left1="$(next_count)"
run_block "$STEP3"
if [ "$rc1" -eq 1 ] && [ "$left1" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then
  ok "an assign that failed AFTER applying: exit 1, nothing left behind, and the re-run ends with exactly one next wisp, assigned"
else
  bad "assign failed after applying: exit $rc1 then $RC, left after run 1=$left1 (want 0), next=$(next_count), assigned=$(assigned_next) :: $OUT"
fi
# C3: the assign fails AND the burn fails (the one case the block cannot undo): loud, with the id
world_new; arm update fail 1; arm burn fail 1
run_block "$STEP3"
if [ "$RC" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'ga-wisp-new1'; then
  ok "assign and burn both fail -> exit 1, the stray stays (it cannot be undone) and the mayor is mailed with ITS ID"
else
  bad "double failure not handled loudly (exit $RC, next=$(next_count), assigned=$(assigned_next), mails=$(spy_n "$MAIL_RE")) :: $OUT $SPY_LOG"
fi
if printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'mol burn ga-wisp-new1'; then ok "the mail says how to clean it (the burn command for that id)"; else bad "the mail does not say how to clean the stray"; fi
if mail_ok_to_mayor; then ok "the mail goes to the mayor"; else bad "the stray's mail is not addressed to the mayor: $SPY_LOG"; fi
if printf '%s\n' "$OUT" | grep -F -q 'LEFT BEHIND' && ! printf '%s\n' "$OUT" | grep -q 'safe to retry'; then ok "the output says LEFT BEHIND and does not call a retry safe"; else bad "the stray is not announced as left behind, or still promises a safe retry: $OUT"; fi
# C4: the assign keeps failing: every run pours and burns its own wisp, nothing accumulates and this wisp stays
world_new; arm update fail 999
c4_bad=0
for i in 1 2 3; do
  run_block "$STEP3"
  if [ "$RC" -ne 1 ] || [ "$(next_count)" -ne 0 ] || ! cur_alive; then c4_bad=$((c4_bad + 1)); bad "run $i of a persistent assign failure: exit $RC, next wisps=$(next_count) (want 0) :: $OUT"; fi
done
if [ "$c4_bad" -eq 0 ] && [ "$(pours)" -eq 3 ]; then ok "an assign that never recovers: three runs, three exit 1, no stray accumulates, this wisp stays"; else bad "persistent assign failure accumulated state (bad runs $c4_bad, pours=$(pours), next=$(next_count))"; fi
# C5: this wisp is never burned by the block, whatever fails (that is step 5's job, after the sleep)
c5_runs=0; c5_bad=0
for armed in "update fail 1" "update failapplied 1" "update fail 1|burn fail 1" "pour noid 1" "pour fail 1" "pour garbage 1" "pour nokey 1" "list fail 1"; do
  world_new
  IFS='|' read -r a1 a2 <<EOF
$armed
EOF
  # shellcheck disable=SC2086
  arm $a1
  # shellcheck disable=SC2086
  if [ -n "${a2:-}" ]; then arm $a2; fi
  run_block "$STEP3"
  c5_runs=$((c5_runs + 1))
  if [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ] && cur_alive; then :; else c5_bad=$((c5_bad + 1)); bad "the block burned or lost the CURRENT wisp when '$armed': $SPY_LOG"; fi
done
if [ "$c5_bad" -eq 0 ]; then ok "this wisp is never burned by the block: it survives each of $c5_runs injected failures"; fi

# ── Group D: the read of my live wisps — three states, only 'a clean answer' may pour ─
echo ""
echo "Group D: a read that fails or comes back unreadable is 'do not know' — no pour, exit 1"
read_inert() { # LABEL MODE
  world_new; arm list "$2" 999
  run_block "$STEP3"
  if [ "$RC" -eq 1 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 0 ] \
     && [ "$(spy_n "$MAIL_RE")" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q 'NOT pouring'; then
    ok "$1 -> no pour, no assign, no burn, exit 1, says NOT pouring"
  else
    bad "$1: expected the inert state (exit $RC, pours=$(pours), updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE"), mails=$(spy_n "$MAIL_RE")) :: $OUT"
  fi
}
read_inert "THE BUG class: the read fails (exit 1, timed out)" fail
if printf '%s\n' "$OUT" | grep -F -q 'Error: timed out after 30s'; then ok "the failed read's own error line reaches the deacon"; else bad "the read's error line is hidden: $OUT"; fi
read_inert "a failing read that still printed [] is not a clean empty" failjson
read_inert "exit 0 but no output at all (truncated read)" empty
read_inert "exit 0 with text instead of JSON" text
read_inert "exit 0 with a JSON object, not a list" object
world_new
run_block "$STEP3" GC_AGENT=
if [ "$RC" -eq 1 ] && [ -z "$SPY_LOG" ] && printf '%s\n' "$OUT" | grep -F -q 'GC_AGENT is empty'; then
  ok "GC_AGENT empty -> not a single gc call (an empty --assignee would match anything), exit 1, says so"
else
  bad "empty GC_AGENT was not refused up front (exit $RC) :: $OUT $SPY_LOG"
fi

# ── Group E: the pour itself does not answer ──────────────────────────────────
echo ""
echo "Group E: the pour fails, or loses its answer"
world_new; arm pour fail 1
run_block "$STEP3"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && mail_ok_to_mayor; then
  ok "the pour fails outright -> exit 1, no assign / burn of anything, the mayor is told"
else
  bad "failed pour (exit $RC, updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE"), mails=$(spy_n "$MAIL_RE")) :: $OUT"
fi
for m in noid garbage nokey; do
  world_new; arm pour "$m" 1
  run_block "$STEP3"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] \
     && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] \
     && mail_ok_to_mayor && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q -- '--no-assignee' \
     && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'mol burn <id>' && printf '%s\n' "$OUT" | grep -F -q 'MAY'; then
    ok "pour answered '$m' (the wisp exists, its id is unknown) -> exit 1, nothing assigned or burned by guess, says a wisp MAY exist, mails the mayor the read that finds it and the burn that cleans it"
  else
    bad "pour answer '$m': exit $RC, next=$(next_count), mails=$(spy_n "$MAIL_RE"), blind calls=$(spy_n "$UPDATE_RE")/$(spy_n "$BURN_RE") :: $OUT"
  fi
done

# ── Group F: the delivered formula is still a formula, and says what the code does ─
echo ""
echo "Group F: structure and prose"
if [ "$(extract steps | tr '\n' ' ')" = "check-inbox orphan-process-cleanup health-scan queue-starvation-check utility-agent-health dolt-health system-health next-iteration " ] && [ "$(extract needs)" = "system-health" ]; then
  ok "the step list and next-iteration's needs are unchanged"
else
  bad "the step list or the needs of next-iteration changed: $(extract steps | tr '\n' ' ') / $(extract needs)"
fi
undeclared=""
for t in $(extract tokens); do
  extract vars | grep -qx "$t" || undeclared="$undeclared $t"
done
if [ -z "$undeclared" ]; then ok "every {{variable}} the step uses is declared in [vars]"; else bad "the step uses undeclared {{variables}}:$undeclared"; fi
if printf '%s\n' "$STEP3_RAW" | grep -F -q '<this-wisp-id>'; then bad "the step-3 block names the CURRENT wisp (<this-wisp-id>): burning it is step 5's job, after the sleep"; else ok "the step-3 block never names the current wisp"; fi
n3="$(printf '%s\n' "$DESC" | grep -n -F -- '**3. Pour next iteration BEFORE burning' | head -n 1 | cut -d: -f1)"
n4="$(printf '%s\n' "$DESC" | grep -n -F -- '**4. Wait before next cycle' | head -n 1 | cut -d: -f1)"
n5="$(printf '%s\n' "$DESC" | grep -n -F -- '**5. Burn this wisp' | head -n 1 | cut -d: -f1)"
if [ -n "$n3" ] && [ -n "$n4" ] && [ -n "$n5" ] && [ "$n3" -lt "$n4" ] && [ "$n4" -lt "$n5" ]; then ok "pour (3), then sleep (4), then burn (5), in that order"; else bad "the pour / sleep / burn steps are missing or out of order (lines '$n3' '$n4' '$n5')"; fi
if [ "$(printf '%s\n' "$DESC" | grep -c -x -F 'sleep {{event_timeout}}')" -eq 1 ] && [ "$(printf '%s\n' "$DESC" | grep -c -x -F 'gc bd mol burn <this-wisp-id> --force')" -eq 1 ]; then
  ok "step 4 still sleeps and step 5 still burns the current wisp, once each"
else
  bad "the sleep line or the burn-this-wisp line is gone or duplicated"
fi
if printf '%s\n' "$DESC" | grep -F -q 'safe to re-run'; then ok "the step tells the deacon the block is safe to re-run"; else bad "the step does not say the block is safe to re-run"; fi
if printf '%s\n' "$DESC" | grep -F -q 'Exit 0 = ' && printf '%s\n' "$DESC" | grep -F -q 'Exit 1 = '; then ok "the step says what exit 0 and exit 1 mean"; else bad "the step does not say what exit 0 and exit 1 mean"; fi
if printf '%s\n' "$DESC" | grep -F -q 'do NOT go on to step 4 and do NOT burn this wisp'; then ok "the step says that on exit 1 the deacon does not go on to step 4 (the sleep) and does not burn this wisp"; else bad "the step does not say to neither go on to step 4 nor burn this wisp on exit 1"; fi
if printf '%s\n' "$DESC" | grep -F -q 'never the next wisp from step 3'; then ok "step 5 says to burn only the wisp being executed, never the next one"; else bad "step 5 does not say to never burn the next wisp"; fi
if printf '%s\n' "$DESC" | grep -F -q 'ga-x9jivyf'; then ok "the step cites ga-x9jivyf"; else bad "the step does not cite ga-x9jivyf"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
