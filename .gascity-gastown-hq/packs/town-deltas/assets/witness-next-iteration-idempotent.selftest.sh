#!/usr/bin/env bash
# witness-next-iteration-idempotent.selftest.sh — behavioral drift-guard for ga-jhsxo4p (daughter of ga-6zrshxb).
#
# Bug ga-jhsxo4p: the `next-iteration` step of mol-witness-patrol poured the next wisp with no read first ("the pour is
# unconditional by design") and treated what came after the pour as an all-or-nothing leg. When the pour SUCCEEDED (the wisp
# exists, with no owner) and the leg after it failed, the step ended with exit 1 and a mail that said "safe to retry" — but a
# retry poured again, so the witness ended up with two next wisps and the first one stayed in the store for good (an
# unassigned wisp is found by no `--assignee` read, and the reaper only closes a wisp whose parent is closed: a root-only
# patrol wisp has none). Three windows, all "the pour answered, the next leg did not":
#   (a) `show` fails right after the pour (a transient failure: under load 45-71 `gc` calls were measured timing out at 30 s on
#       12/11 -- in `gc hook`, ga-6zrshxb -- and `bd` answers with i/o timeouts from the same Dolt) -> exit 1, wisp unassigned;
#   (b) `update --assignee` fails: the old block never read its exit code and its text said nothing about stopping, so the step
#       could go on to sleep and burn the CURRENT wisp, leaving a next wisp with no owner and a witness with nothing on its hook;
#   (c) the pour's answer is lost (timeout after the commit, unreadable output): `$NEXT` is empty, but a wisp may exist.
#
# The fix makes the step safe to re-run: it READS first (my live wisps in the pinned store, in three states: two or more mean a
# next wisp already exists, so no pour; one or none, pour; the read failed or came back unreadable, "do not know", no pour),
# assigns BEFORE the read-back (so a wisp left by a later failure is one a re-run finds by assignee), reads the assign's exit
# code, and burns the wisp it just poured when it cannot assign it (never the current one). Exit 0 only when a next wisp exists
# and is assigned. The failures it cannot undo (the burn fails too, the pour's answer is lost) say so loudly and mail the mayor
# with the id (or the read that finds it).
#
# The formula has no exec script: an agent reads the step's description and types the shell it finds there. So the unit under
# test is the text the agent is DELIVERED (the TOML parsed by tomllib, escapes consumed), never the raw source (see
# mol-digest-generate.selftest.sh). The step-2 block is extracted and EXECUTED under a stub `gc` on a sandbox PATH. The stub is
# stateful: two tiny stores on disk (what `-C <rig root>` sees, and another one where a wrong-store pour lands), faults armed
# per scenario (`mode:count`), and a spy that logs every call. "No pour" / "no burn" are asserted as the ABSENCE of the call and
# as the state of the stores after a RE-RUN; the healthy scenarios prove the spy does see a pour, an assign and a burn.
#
# Sibling guards on the same file: witness-patrol-wisp-store.selftest.sh (text anchors: -C pins, the `show "$NEXT" --json` line,
# the empty-rig_root refusal) and witness-startup-three-states.selftest.sh (the same three-state rule in the prompt's blocks).
#
# WITNESS_FORMULA_UNDER_TEST overrides the formula (mutant runs, see the delivery of ga-jhsxo4p).
# Exit 0 iff every scenario holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FORMULA="${WITNESS_FORMULA_UNDER_TEST:-$TOWN_DELTAS_ROOT/formulas/mol-witness-patrol.toml}"

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

echo "witness-next-iteration-idempotent.selftest — ga-jhsxo4p: a re-run after pour-ok + verify/assign-failed ends with ONE next wisp"

FAKE_RIG="/fake/rig"
FAKE_AGENT="property_scrapers/gastown.witness"
HEAD2='**2. Pour next iteration BEFORE burning'

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
# fill_vars RIG: the three formula variables the way the engine renders a rig
fill_vars() { sed -e "s|{{rig_root}}|$1|g" -e "s|{{binding_prefix}}|bp|g" -e "s|{{event_timeout}}|1|g"; }

STEP2_RAW="$(extract block "$HEAD2")"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$STEP2_RAW" ]; then
  ok "formula parses (tomllib) and the step-2 block is found exactly once, after '$HEAD2'"
else
  echo "FATAL: could not isolate the step-2 block (python exit $rc: 3 = no next-iteration step, 4 = heading not found exactly once, 5 = fence not closed) — nothing below can be trusted" >&2
  exit 2
fi
STEP2="$(printf '%s\n' "$STEP2_RAW" | fill_vars "$FAKE_RIG")"
STEP2_NORIG="$(printf '%s\n' "$STEP2_RAW" | fill_vars "")"
DESC="$(extract desc)" || { echo "FATAL: could not read the step description" >&2; exit 2; }

# ── Stub gc + sandbox PATH ────────────────────────────────────────────────────
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# A fake gc with state. $WORLD holds: rig and other (one wisp per line, "id|assignee"), seq (how many pours were attempted),
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
has_id() { grep -q "^$2|" "$W/$1"; }   # store, id

case "${1:-}" in
  mail|session) exit 0 ;;
  bd)
    shift
    store=other
    if [ "${1:-}" = "-C" ]; then
      [ "${2:-}" = "/fake/rig" ] && store=rig
      shift 2
    else
      store=rig   # no pin: the cwd store (never used by the step under test)
    fi
    sf="$W/$store"
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
        if fault_mode show >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
        if has_id "$store" "$id"; then printf '[{"id":"%s"}]' "$id"; exit 0; fi
        echo "Error fetching $id: no issue found matching \"$id\"" >&2
        exit 1
        ;;
      update)
        id=${2:-}; who=""
        for a in "$@"; do
          case "$a" in --assignee=*) who=${a#--assignee=} ;; esac
        done
        if fault_mode update >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
        has_id "$store" "$id" || { echo "Error resolving $id: no issue found" >&2; exit 1; }
        sed "s#^$id|.*#$id|$who#" "$sf" > "$sf.new" && mv "$sf.new" "$sf"
        exit 0
        ;;
      mol)
        case "${2:-}" in
          wisp)
            pm=$(fault_mode pour) || pm=ok
            n=$(cat "$W/seq"); n=$((n + 1)); echo "$n" > "$W/seq"; id="ga-wisp-new$n"
            case "$pm" in
              fail)       echo "Error: timed out after 30s" >&2; exit 1 ;;                                    # nothing was created
              noid)       echo "$id|" >> "$W/rig"; exit 1 ;;                                                 # created, the answer was lost
              garbage)    echo "$id|" >> "$W/rig"; echo "Created wisp"; exit 0 ;;                            # created, the answer is not JSON
              wrongstore) echo "$id|" >> "$W/other"; printf '{"new_epic_id":"%s","created":1,"phase":"vapor"}' "$id"; exit 0 ;;
            esac
            echo "$id|" >> "$sf"
            printf '{"new_epic_id":"%s","created":1,"phase":"vapor"}' "$id"
            exit 0
            ;;
          burn)
            id=${3:-}
            if fault_mode burn >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
            has_id "$store" "$id" || { echo "Error: $id not found" >&2; exit 1; }
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
# world_new: a fresh world. The wisp being executed (ga-wisp-cur) is live and assigned to this witness; nothing is armed.
world_new() {
  W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  printf 'ga-wisp-cur|%s\n' "$FAKE_AGENT" > "$W/rig"
  : > "$W/other"; : > "$W/spy"; echo 0 > "$W/seq"
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
POUR_RE='^GC bd .*mol wisp'
BURN_RE='^GC bd .*mol burn'
UPDATE_RE='^GC bd .* update '
SHOW_RE='^GC bd .* show '
LIST_RE='^GC bd .* list '
MAIL_RE='^GC mail send'
pours()         { cat "$W/seq"; }
next_count()    { grep -v '^ga-wisp-cur|' "$W/rig" | grep -c .; }                       # live wisps in the rig store besides the one being executed
assigned_next() { grep -v '^ga-wisp-cur|' "$W/rig" | grep -c "|$FAKE_AGENT\$"; }          # ... of those, assigned to this witness
cur_alive()     { grep -q '^ga-wisp-cur|' "$W/rig"; }

# ── Group A: the healthy cycle ────────────────────────────────────────────────
echo ""
echo "Group A: healthy cycle (this wisp live, no next one)"
world_new
run_block "$STEP2"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && cur_alive; then
  ok "exit 0, one pour, one next wisp assigned to this witness, this wisp neither burned nor touched"
else
  bad "healthy cycle (exit $RC, pours=$(pours), next=$(next_count), assigned=$(assigned_next), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
if printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-new1'; then ok "the output names the next wisp"; else bad "the output does not name the next wisp: $OUT"; fi
if printf '%s\n' "$OUT" | tail -n 1 | grep -F -q 'go on to step 3'; then ok "the last line tells the witness to go on to step 3 (its cue that exit 0 means a next wisp exists)"; else bad "the block does not end by telling the witness to go on to step 3: $OUT"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q "GC bd -C $FAKE_RIG list --assignee=$FAKE_AGENT --type=molecule --include-infra --limit=2 --json"; then
  ok "the read is the pinned one: -C rig root, by this witness's identity, molecules incl. infra, limit 2 (two or more is all it needs to see)"
else
  bad "the read is not the pinned shape (-C rig root, --assignee=GC_AGENT, --type=molecule --include-infra --limit=2 --json): $SPY_LOG"
fi
r="$(spy_first "$LIST_RE")"; p="$(spy_first "$POUR_RE")"
if [ -n "$r" ] && [ -n "$p" ] && [ "$r" -lt "$p" ]; then ok "the read comes BEFORE the pour"; else bad "the read does not precede the pour (read line '$r', pour line '$p'): $SPY_LOG"; fi
if [ "$(printf '%s\n' "$SPY_LOG" | grep -c '^GC bd ')" -gt 0 ] && [ "$(printf '%s\n' "$SPY_LOG" | grep '^GC bd ' | grep -c -F -- "-C $FAKE_RIG ")" -eq "$(printf '%s\n' "$SPY_LOG" | grep -c '^GC bd ')" ]; then
  ok "every gc bd call carries the -C pin"
else
  bad "a gc bd call went out without the -C pin: $SPY_LOG"
fi

# ── Group B: a next wisp already exists -> no pour ────────────────────────────
echo ""
echo "Group B: a next wisp is already there (this one plus a next one) -> no second pour"
world_new; printf 'ga-wisp-nxt|%s\n' "$FAKE_AGENT" >> "$W/rig"
run_block "$STEP2"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 1 ]; then
  ok "two live wisps of mine -> exit 0, no pour, no assign, no read-back, no burn"
else
  bad "existing next wisp did not stop the pour (exit $RC, pours=$(pours), updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
if printf '%s\n' "$OUT" | grep -F -q 'already' && printf '%s\n' "$OUT" | tail -n 1 | grep -F -q 'go on to step 3'; then ok "it says a next wisp already exists and to go on to step 3"; else bad "the reuse path is silent or does not say to go on to step 3: $OUT"; fi
world_new; printf 'ga-wisp-a|%s\nga-wisp-b|%s\n' "$FAKE_AGENT" "$FAKE_AGENT" >> "$W/rig"
run_block "$STEP2"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ]; then ok "three live wisps (leftovers from an old failure) -> still no pour, exit 0"; else bad "three live wisps: exit $RC, pours=$(pours) :: $OUT"; fi
world_new; printf 'ga-wisp-theirs|some/other.witness\n' >> "$W/rig"
run_block "$STEP2"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then ok "a live wisp that belongs to someone else does not count: this witness still pours its own"; else bad "someone else's wisp stopped the pour (exit $RC, pours=$(pours), assigned=$(assigned_next)) :: $OUT"; fi

# ── Group C: THE BUG — the pour worked, the next leg did not, then the block is run again ─
echo ""
echo "Group C: pour ok + verify/assign failed, then a re-run -> exactly one next wisp"
# C1: the read-back fails once (window a)
world_new; arm show fail 1
run_block "$STEP2"; rc1=$RC; out1="$OUT"; spy1="$SPY_LOG"
run_block "$STEP2"
if [ "$rc1" -eq 1 ] && [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then
  ok "THE BUG (a): read-back fails after a good pour -> exit 1; the re-run exits 0 and the WHOLE history has ONE pour and ONE next wisp, assigned"
else
  bad "THE BUG (a): after pour-ok + read-back-failed and a re-run: exit $rc1 then $RC, pours=$(pours) (want 1), next wisps=$(next_count) (want 1), assigned=$(assigned_next) (want 1) :: $out1 // $OUT"
fi
# the old code promised "safe to retry" in the BODY OF ITS MAIL (the spy), where the retry then poured a second wisp: look at outputs and mails alike
if ! printf '%s\n%s\n%s\n%s\n' "$out1" "$spy1" "$OUT" "$SPY_LOG" | grep -q 'safe to retry'; then ok "no 'safe to retry' promise in the output or the mail of that history (the retry of the old code was NOT safe)"; else bad "an output or mail still promises 'safe to retry' for a retry that pours again: $out1 $spy1"; fi
# C2: the assign fails once (window b)
world_new; arm update fail 1
run_block "$STEP2"; rc1=$RC; out1="$OUT"; left1="$(next_count)"; burn1="$(spy_n "^GC bd -C $FAKE_RIG mol burn ga-wisp-new1 --force\$")"; curburn1="$(spy_n 'mol burn ga-wisp-cur')"
run_block "$STEP2"
if [ "$rc1" -eq 1 ] && [ "$left1" -eq 0 ] && [ "$burn1" -eq 1 ] && [ "$curburn1" -eq 0 ]; then
  ok "THE BUG (b): assign fails -> exit 1, the wisp it just poured is burned (nothing left behind) and THIS wisp is not"
else
  bad "THE BUG (b): assign failed but exit=$rc1, next wisps left=$left1 (want 0), burn of the new wisp=$burn1 (want 1), burn of the current wisp=$curburn1 (want 0) :: $out1"
fi
if [ "$RC" -eq 0 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then ok "THE BUG (b): the re-run ends with exactly one next wisp, assigned"; else bad "THE BUG (b): re-run left next=$(next_count) assigned=$(assigned_next) (exit $RC) :: $OUT"; fi
# C3: the assign fails AND the burn fails (the one case the block cannot undo): loud, with the id
world_new; arm update fail 1; arm burn fail 1
run_block "$STEP2"
if [ "$RC" -eq 1 ] && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'ga-wisp-new1'; then
  ok "assign and burn both fail -> exit 1, the stray stays (it cannot be undone) and the mayor is mailed with ITS ID"
else
  bad "double failure not handled loudly (exit $RC, next=$(next_count), assigned=$(assigned_next), mails=$(spy_n "$MAIL_RE")) :: $OUT $SPY_LOG"
fi
if printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'mol burn ga-wisp-new1'; then ok "the mail says how to clean it (the burn command for that id)"; else bad "the mail does not say how to clean the stray"; fi
if printf '%s\n' "$OUT" | grep -F -q 'LEFT BEHIND' && ! printf '%s\n' "$OUT" | grep -q 'safe to retry'; then ok "the output says LEFT BEHIND and does not call a retry safe"; else bad "the stray is not announced as left behind, or still promises a safe retry: $OUT"; fi
# C4: the read-back keeps failing, the assign worked: the re-run does not need it (it finds the assigned wisp)
world_new; arm show fail 999
run_block "$STEP2"; rc1=$RC
run_block "$STEP2"
if [ "$rc1" -eq 1 ] && [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$POUR_RE")" -eq 0 ]; then
  ok "a read-back that never recovers does not block the loop: the re-run finds the assigned wisp (no pour, no read-back), exit 0"
else
  bad "persistent read-back failure: exit $rc1 then $RC, pours=$(pours), shows in the re-run=$(spy_n "$SHOW_RE") :: $OUT"
fi
# C5: this wisp is never burned by the block, whatever fails (that is step 4's job, after the sleep)
c5_runs=0; c5_bad=0
for armed in "show fail 1" "update fail 1" "update fail 1|burn fail 1" "pour noid 1" "pour fail 1" "pour wrongstore 1" "list fail 1"; do
  world_new
  IFS='|' read -r a1 a2 <<EOF
$armed
EOF
  # shellcheck disable=SC2086
  arm $a1
  # shellcheck disable=SC2086
  if [ -n "${a2:-}" ]; then arm $a2; fi
  run_block "$STEP2"
  c5_runs=$((c5_runs + 1))
  if [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ] && cur_alive; then :; else c5_bad=$((c5_bad + 1)); bad "the block burned or lost the CURRENT wisp when '$armed': $SPY_LOG"; fi
done
if [ "$c5_bad" -eq 0 ]; then ok "this wisp is never burned by the block: it survives each of $c5_runs injected failures"; fi

# ── Group D: the read of my live wisps — three states, only 'a clean answer' may pour ─
echo ""
echo "Group D: a read that fails or comes back unreadable is 'do not know' — no pour, exit 1"
read_inert() { # LABEL MODE
  world_new; arm list "$2" 999
  run_block "$STEP2"
  if [ "$RC" -eq 1 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 0 ] \
     && [ "$(spy_n "$MAIL_RE")" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q 'NOT pouring'; then
    ok "$1 -> no pour, no assign, no burn, exit 1, says NOT pouring"
  else
    bad "$1: expected the inert state (exit $RC, pours=$(pours), updates=$(spy_n "$UPDATE_RE"), burns=$(spy_n "$BURN_RE"), mails=$(spy_n "$MAIL_RE")) :: $OUT"
  fi
}
read_inert "THE BUG class: the read fails (exit 1, timed out)" fail
if printf '%s\n' "$OUT" | grep -F -q 'Error: timed out after 30s'; then ok "the failed read's own error line reaches the witness"; else bad "the read's error line is hidden: $OUT"; fi
read_inert "a failing read that still printed [] is not a clean empty" failjson
read_inert "exit 0 but no output at all (truncated read)" empty
read_inert "exit 0 with text instead of JSON" text
read_inert "exit 0 with a JSON object, not a list" object
world_new
run_block "$STEP2" GC_AGENT=
if [ "$RC" -eq 1 ] && [ -z "$SPY_LOG" ] && printf '%s\n' "$OUT" | grep -F -q 'GC_AGENT is empty'; then
  ok "GC_AGENT empty -> not a single gc call (an empty --assignee would match anything), exit 1, says so"
else
  bad "empty GC_AGENT was not refused up front (exit $RC) :: $OUT $SPY_LOG"
fi

# ── Group E: the pour itself does not answer ──────────────────────────────────
echo ""
echo "Group E: the pour fails, loses its answer, or lands in the wrong store"
world_new; arm pour fail 1
run_block "$STEP2"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(next_count)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ]; then
  ok "the pour fails outright -> exit 1, no assign / read-back / burn of anything, the mayor is told"
else
  bad "failed pour (exit $RC, updates=$(spy_n "$UPDATE_RE"), shows=$(spy_n "$SHOW_RE"), burns=$(spy_n "$BURN_RE"), mails=$(spy_n "$MAIL_RE")) :: $OUT"
fi
for m in noid garbage; do
  world_new; arm pour "$m" 1
  run_block "$STEP2"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] \
     && [ "$(next_count)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] \
     && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q -- '--no-assignee' && printf '%s\n' "$OUT" | grep -F -q 'MAY'; then
    ok "pour answered '$m' (the wisp exists, its id is unknown) -> exit 1, nothing assigned or burned by guess, says a wisp MAY exist, mails the read that finds it"
  else
    bad "pour answer '$m': exit $RC, next=$(next_count), mails=$(spy_n "$MAIL_RE"), blind calls=$(spy_n "$UPDATE_RE")/$(spy_n "$BURN_RE") :: $OUT"
  fi
done
world_new; arm pour wrongstore 1
run_block "$STEP2"
if [ "$RC" -eq 1 ] && cur_alive && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q 'ga-wisp-new1'; then
  ok "THE ga-3v2n4 case: the pour lands outside the pinned store -> exit 1, this wisp kept, the mayor is mailed with the id"
else
  bad "wrong-store pour not handled (exit $RC, mails=$(spy_n "$MAIL_RE")) :: $OUT $SPY_LOG"
fi

# ── Group F: the empty rig_root refusal survives ──────────────────────────────
echo ""
echo "Group F: the empty rig_root refusal (ga-3v2n4) is still first"
world_new
run_block "$STEP2_NORIG"
if [ "$RC" -eq 1 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n '^GC bd ')" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$OUT" | grep -F -q 'rig_root var not supplied'; then
  ok "empty rig_root -> exit 1, mails the mayor, not a single gc bd call"
else
  bad "empty rig_root not refused (exit $RC, pours=$(pours), bd calls=$(spy_n '^GC bd '), mails=$(spy_n "$MAIL_RE")) :: $OUT"
fi

# ── Group G: the delivered formula is still a formula, and says what the code does ─
echo ""
echo "Group G: structure and prose"
if [ "$(extract steps | tr '\n' ' ')" = "check-inbox recover-orphaned-beads check-refinery check-polecat-health next-iteration " ] && [ "$(extract needs)" = "check-polecat-health" ]; then
  ok "the step list and next-iteration's needs are unchanged"
else
  bad "the step list or the needs of next-iteration changed: $(extract steps | tr '\n' ' ') / $(extract needs)"
fi
undeclared=""
for t in $(extract tokens); do
  extract vars | grep -qx "$t" || undeclared="$undeclared $t"
done
if [ -z "$undeclared" ]; then ok "every {{variable}} the step uses is declared in [vars]"; else bad "the step uses undeclared {{variables}}:$undeclared"; fi
if printf '%s\n' "$STEP2_RAW" | grep -F -q '<this-wisp-id>'; then bad "the step-2 block names the CURRENT wisp (<this-wisp-id>): burning it is step 4's job, after the sleep"; else ok "the step-2 block never names the current wisp"; fi
if printf '%s\n' "$DESC" | grep -F -q 'safe to re-run'; then ok "the step tells the witness the block is safe to re-run"; else bad "the step does not say the block is safe to re-run"; fi
if printf '%s\n' "$DESC" | grep -F -q 'Exit 0'; then ok "the step says what exit 0 means"; else bad "the step does not say what exit 0 means"; fi
if printf '%s\n' "$DESC" | grep -F -q 'ga-jhsxo4p'; then ok "the step cites ga-jhsxo4p"; else bad "the step does not cite ga-jhsxo4p"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
