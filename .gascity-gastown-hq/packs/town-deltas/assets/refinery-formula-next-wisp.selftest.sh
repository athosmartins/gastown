#!/usr/bin/env bash
# refinery-formula-next-wisp.selftest.sh — wiring guard for ga-d8dfjg9: the town-deltas override of mol-refinery-patrol.
#
# ## Contents
#   - What it proves
#   - Usage
#
# ## What it proves
# packs/town-deltas/formulas/mol-refinery-patrol.toml is the pack's refinery formula with five pour-then-burn blocks replaced by one call to
# scripts/patrol-next-wisp.sh (the script's own behaviour is proven by patrol-next-wisp.selftest.sh). An agent reads a formula's step text
# and types what it finds, so the unit under test is the text it is DELIVERED (the TOML parsed by tomllib, escapes consumed), never the raw
# source. This guard proves, against that text:
#   1. the file parses, has the same steps as the pack's formula (when the pack is readable here), and the five call sites are exactly
#      check-inbox / rebase / handle-failures / merge-push / next-iteration, each with the SAME pour flags the old blocks had;
#   2. none of the old defects is left in any step: no `CURRENT_WISP=` (GC_BEAD_ID, fixed at session start), no `--type=wisp` (invalid enum),
#      no inline pour (`mol wisp mol-refinery-patrol`) or burn of a shell variable in a step;
#   3. the self-contained blocks (check-inbox, next-iteration, the rebase conflict path, the handle-failures path) EXECUTE under a
#      stateful fake gc and the REAL script: healthy, assign fails, pour fails, read fails, re-run after each; a failure ends in drain-ack and
#      exit 1 and never in a restart request; success never drains; no scenario leaves an unowned wisp or two next wisps;
#   4. the function-embedded site (block_existing_pr) keeps its ending: the call, then the reason, STOP, drain-ack and exit 1, whatever the
#      script answered.
# Run against the PACK's formula (REFINERY_FORMULA_UNDER_TEST=$GC_CITY_PATH/.gc/system/packs/gastown/formulas/mol-refinery-patrol.toml) it
# fails: that is the "before" arm.
#
# ## Usage
#   bash refinery-formula-next-wisp.selftest.sh        (REFINERY_FORMULA_UNDER_TEST=<file> for another copy; PACK_FORMULA=<file> for the pack's)
# Exit 0 iff every check holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
FORMULA="${REFINERY_FORMULA_UNDER_TEST:-$HQ_ROOT/packs/town-deltas/formulas/mol-refinery-patrol.toml}"
PACK_FORMULA="${PACK_FORMULA:-${GC_CITY_PATH:+$GC_CITY_PATH/.gc/system/packs/gastown/formulas/mol-refinery-patrol.toml}}"
SCRIPT_REL="packs/town-deltas/assets/scripts/patrol-next-wisp.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$FORMULA" ] || { echo "FATAL: formula not found at $FORMULA" >&2; exit 2; }
[ -f "$HQ_ROOT/$SCRIPT_REL" ] || { echo "FATAL: script not found at $HQ_ROOT/$SCRIPT_REL" >&2; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }
# vazio → no candidate has tomllib: FATAL exit 2; falhou → a candidate that is missing or cannot import tomllib is skipped
PY=""
for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "FATAL: no python3 with tomllib (>= 3.11) found" >&2; exit 2; }

echo "refinery-formula-next-wisp.selftest — ga-d8dfjg9: the five pour/burn sites of mol-refinery-patrol call the script"

# extract FILE MODE [ARG]: modes: steps | sites | step-blocks STEPID (every ```bash fence of the step that holds the call, de-indented, NUL-free,
# separated by a line "=====") | step-text STEPID (the description, whole)
# vazio → prints nothing (the caller refuses to go on); falhou/ilegível → python exits non-zero
extract() {
  "$PY" -I - "$@" <<'PY'
import re, sys, tomllib
path, mode = sys.argv[1], sys.argv[2]
d = tomllib.load(open(path, "rb"))
if mode == "steps":
    print("\n".join(s["id"] for s in d["steps"]))
elif mode == "sites":
    for s in d["steps"]:
        n = len(re.findall(r"patrol-next-wisp\.sh", s["description"]))
        if n:
            print("%s %d" % (s["id"], n))
elif mode == "step-text":
    s = next((s for s in d["steps"] if s["id"] == sys.argv[3]), None)
    if s is None: sys.exit(3)
    sys.stdout.write(s["description"])
elif mode == "step-blocks":
    s = next((s for s in d["steps"] if s["id"] == sys.argv[3]), None)
    if s is None: sys.exit(3)
    out, cur, inb, ind = [], [], False, 0
    for l in s["description"].split("\n"):
        m = re.match(r"^(\s*)```bash\s*$", l)
        if not inb and m:
            inb, ind, cur = True, len(m.group(1)), []
            continue
        if inb and re.match(r"^\s*```\s*$", l):
            inb = False
            blk = "\n".join(cur)
            if "patrol-next-wisp.sh" in blk:
                out.append(blk)
            continue
        if inb:
            cur.append(l[ind:] if l[:ind].strip() == "" else l)
    sys.stdout.write("\n=====\n".join(out))
else:
    sys.exit(6)
PY
}
fill_vars() { sed -e "s|{{target_branch}}|main|g" -e "s|{{rig_name}}|wa|g" -e "s|{{binding_prefix}}|bp|g"; }

# ── 1. structure ──────────────────────────────────────────────────────────────
echo ""; echo "Group 1: structure"
STEPS="$(extract "$FORMULA" steps)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$STEPS" ]; then ok "the formula parses (tomllib): $(printf '%s\n' "$STEPS" | wc -l | tr -d ' ') steps"; else echo "FATAL: the formula does not parse (python exit $rc)" >&2; exit 2; fi
if [ -n "$PACK_FORMULA" ] && [ -f "$PACK_FORMULA" ]; then
  PSTEPS="$(extract "$PACK_FORMULA" steps)" || PSTEPS=""
  if [ "$STEPS" = "$PSTEPS" ]; then ok "same step ids, same order, as the pack's formula (no step lost or added by the override)"; else bad "step ids differ from the pack's formula: override [$(echo $STEPS)] vs pack [$(echo $PSTEPS)]"; fi
else
  echo "  - SKIP: the pack's formula is not readable here (no GC_CITY_PATH or no .gc): the step-id comparison was not made"
fi
SITES="$(extract "$FORMULA" sites | tr '\n' ',')"
WANT="check-inbox 1,rebase 1,handle-failures 1,merge-push 1,next-iteration 1,"
if [ "$SITES" = "$WANT" ]; then ok "exactly five call sites: check-inbox, rebase, handle-failures, merge-push, next-iteration (one each)"; else bad "call sites are [$SITES], want [$WANT]"; fi

CALL_RE='bash "\$GC_CITY_PATH/packs/town-deltas/assets/scripts/patrol-next-wisp\.sh" next mol-refinery-patrol --burn-current -- --var target_branch=\{\{target_branch\}\} --var rig_name=\{\{rig_name\}\} --var binding_prefix=\{\{binding_prefix\}\}'
ALLTXT=""
for sid in $STEPS; do ALLTXT="$ALLTXT
$(extract "$FORMULA" step-text "$sid")"; done
ncalls=$(printf '%s\n' "$ALLTXT" | grep -c -E -- "$CALL_RE")
if [ "$ncalls" -eq 5 ]; then ok "all five calls carry the pour flags the old blocks had (target_branch, rig_name, binding_prefix) and --burn-current"; else bad "$ncalls of 5 calls match the expected pour flags"; fi
if [ "$(printf '%s\n' "$ALLTXT" | grep -E -- "$CALL_RE" | grep -c -F -e '||')" -eq 5 ]; then ok "every call is followed by '||' (a failure is handled, never just the last line)"; else bad "a call is not followed by '||'"; fi

# ── 2. the old defects are gone from every step ──────────────────────────────
echo ""; echo "Group 2: no old pour/burn block is left in any step"
for pat in 'CURRENT_WISP=' '--type=wisp' "jq -r '.new_epic_id" 'mol burn "\$CURRENT_WISP"' 'mol wisp mol-refinery-patrol' '\$GC_BEAD_ID'; do
  n=$(printf '%s\n' "$ALLTXT" | grep -c -E -- "$pat")
  if [ "$n" -eq 0 ]; then ok "no '$pat' in any step"; else bad "'$pat' is still in $n line(s) of the steps"; fi
done

# ── 3. execute the self-contained blocks ─────────────────────────────────────
echo ""; echo "Group 3: the blocks, executed (fake gc, real script)"
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"
cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# fake gc with state ($WORLD: store "id|assignee|title|created_at", seq, spy, fault.<kind> "mode:count")
W="${WORLD:-}"
[ -n "$W" ] && [ -d "$W" ] || { echo "stub gc: WORLD is not set" >&2; exit 98; }
printf 'GC %s\n' "$*" >> "$W/spy"
sf="$W/store"
fault_mode() {
  local f="$W/fault.$1" line mode n
  [ -f "$f" ] || return 1
  line=$(cat "$f"); mode=${line%%:*}; n=${line##*:}
  [ "$n" -gt 0 ] 2>/dev/null || return 1
  n=$((n - 1))
  if [ "$n" -gt 0 ]; then printf '%s:%s\n' "$mode" "$n" > "$f"; else rm -f "$f"; fi
  printf '%s' "$mode"
}
has_id() { grep -q "^$1|" "$sf"; }
case "${1:-}" in
  mail|session) exit 0 ;;
  runtime) exit 0 ;;
  bd)
    shift
    case "${1:-}" in
      list)
        who=""; typ=""; infra=0
        for a in "$@"; do
          case "$a" in --assignee=*) who=${a#--assignee=} ;; --type=*) typ=${a#--type=} ;; --include-infra) infra=1 ;; esac
        done
        if m=$(fault_mode list); then
          case "$m" in
            fail) echo "Error: timed out after 30s" >&2; exit 1 ;;
            empty) exit 0 ;;
          esac
        fi
        [ "$infra" = 1 ] && [ "$typ" = molecule ] || { printf '[]'; exit 0; }
        out=""
        while IFS='|' read -r id as ti ca; do
          [ -n "$id" ] && [ "$as" = "$who" ] || continue
          out="$out${out:+,}{\"id\":\"$id\",\"assignee\":\"$as\",\"title\":\"$ti\",\"status\":\"open\",\"issue_type\":\"molecule\",\"created_at\":\"$ca\"}"
        done < "$sf"
        printf '[%s]' "$out"; exit 0 ;;
      update)
        id=${2:-}; who=""
        for a in "$@"; do case "$a" in --assignee=*) who=${a#--assignee=} ;; esac; done
        if fault_mode update >/dev/null; then echo "Error: 1 of 1 issues failed to update" >&2; exit 1; fi
        has_id "$id" || { echo "Error resolving $id" >&2; exit 1; }
        awk -F'|' -v id="$id" -v w="$who" 'BEGIN{OFS="|"} $1==id{$2=w} {print}' "$sf" > "$sf.new" && mv "$sf.new" "$sf"; exit 0 ;;
      mol)
        case "${2:-}" in
          wisp)
            n=$(cat "$W/seq"); n=$((n + 1)); echo "$n" > "$W/seq"; id="ga-wisp-new$n"
            if fault_mode pour >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
            echo "$id||${3:-}|2026-11-13T10:0$n:00Z" >> "$sf"
            printf '{"new_epic_id":"%s"}' "$id"; exit 0 ;;
          burn)
            id=${3:-}
            if fault_mode burn >/dev/null; then echo "Error: timed out after 30s" >&2; exit 1; fi
            has_id "$id" || { echo "Error: $id not found" >&2; exit 1; }
            grep -v "^$id|" "$sf" > "$sf.new"; mv "$sf.new" "$sf"; exit 0 ;;
        esac ;;
    esac
    echo "unstubbed gc bd call: $*" >&2; exit 99 ;;
esac
echo "unstubbed gc call: $*" >&2; exit 99
STUB
chmod +x "$STUBDIR/bin/gc"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2

AGENT="gastown/refinery"; F="mol-refinery-patrol"; W=""
world_new() { W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || exit 2; printf 'ga-wisp-cur|%s|%s|2026-11-13T09:00:00Z\n' "$AGENT" "$F" > "$W/store"; : > "$W/spy"; echo 0 > "$W/seq"; }
arm() { printf '%s:%s\n' "$2" "$3" > "$W/fault.$1"; }
# run_block CODE: one run of the delivered block, bash, clean env, the city path pointing at THIS tree (so the block's script path resolves)
run_block() {
  : > "$W/spy"
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" GC_AGENT="$AGENT" GC_CITY_PATH="$HQ_ROOT" bash -c "$1" 2>&1)"; RC=$?
  SPY_LOG="$(cat "$W/spy")"
}
spy_n()  { printf '%s\n' "$SPY_LOG" | grep -c -E -- "$1"; }
live_n() { grep -c . "$W/store"; }
unowned_n() { awk -F'|' '$1 != "" && $2 == "" { n++ } END { print n + 0 }' "$W/store"; }
has_live() { grep -q "^$1|" "$W/store"; }
DRAIN='^GC runtime drain-ack'; RESTART='^GC runtime request-restart'

# test_block LABEL STEP INDEX WANT_RESTART: the INDEXth call-bearing fence of STEP, executed in four worlds
test_block() {
  local label="$1" step="$2" idx="$3" restart="$4" raw code
  raw="$(extract "$FORMULA" step-blocks "$step")" || { bad "$label: could not extract the blocks of '$step'"; return; }
  code="$(printf '%s\n' "$raw" | awk -v want="$idx" 'BEGIN{n=1} /^=====$/{n++; next} n==want{print}' | fill_vars)"
  if [ -z "$code" ]; then bad "$label: no block number $idx in step '$step'"; return; fi
  if [ "$restart" = yes ]; then code="$code"; else code="$code
echo BLOCK-FELL-THROUGH"; fi
  # healthy
  world_new; run_block "$code"
  if [ "$RC" -eq 0 ] && [ "$(live_n)" -eq 1 ] && ! has_live ga-wisp-cur && [ "$(unowned_n)" -eq 0 ] && [ "$(spy_n "$DRAIN")" -eq 0 ]; then ok "$label: healthy: next wisp owned, current burned, no drain"; else bad "$label: healthy (exit $RC, live=$(live_n)) :: $OUT"; fi
  if [ "$restart" = yes ]; then
    if [ "$(spy_n "$RESTART")" -eq 1 ]; then ok "$label: the restart is requested AFTER the burn, once"; else bad "$label: restart not requested exactly once: $SPY_LOG"; fi
  else
    if [ "$(spy_n "$RESTART")" -eq 0 ]; then ok "$label: no restart request"; else bad "$label: asked for a restart: $SPY_LOG"; fi
  fi
  # assign fails -> drain-ack + exit 1, the wisp just poured is burned, the re-run converges
  world_new; arm update fail 1; run_block "$code"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$DRAIN")" -eq 1 ] && [ "$(spy_n "$RESTART")" -eq 0 ] && has_live ga-wisp-cur && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ]; then ok "$label: assign fails: drain-ack, exit 1, no restart request, nothing left behind, current wisp kept"; else bad "$label: assign failure (exit $RC, drains=$(spy_n "$DRAIN"), live=$(live_n), unowned=$(unowned_n)) :: $OUT"; fi
  run_block "$code"
  if [ "$RC" -eq 0 ] && [ "$(live_n)" -eq 1 ] && [ "$(unowned_n)" -eq 0 ]; then ok "$label: the re-run converges to ONE owned wisp"; else bad "$label: re-run (exit $RC, live=$(live_n)) :: $OUT"; fi
  # pour fails
  world_new; arm pour fail 1; run_block "$code"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$DRAIN")" -eq 1 ] && [ "$(spy_n "$RESTART")" -eq 0 ] && [ "$(spy_n '^GC bd update')" -eq 0 ] && has_live ga-wisp-cur; then ok "$label: pour fails: drain-ack, exit 1, no assign by guess, no restart, current kept"; else bad "$label: pour failure (exit $RC) :: $OUT"; fi
  # the live read fails: 'nao sei' never pours
  world_new; arm list fail 1; run_block "$code"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$DRAIN")" -eq 1 ] && [ "$(spy_n '^GC bd mol wisp')" -eq 0 ] && [ "$(live_n)" -eq 1 ] && [ "$(spy_n "$RESTART")" -eq 0 ]; then ok "$label: the live read fails: drain-ack, NO pour (a failed read is not 'no wisp'), no restart"; else bad "$label: read failure (exit $RC, pours=$(spy_n '^GC bd mol wisp')) :: $OUT"; fi
  # a next wisp already exists: no second pour
  world_new; printf 'ga-wisp-nxt|%s|%s|2026-11-13T09:05:00Z\n' "$AGENT" "$F" >> "$W/store"; run_block "$code"
  if [ "$RC" -eq 0 ] && [ "$(spy_n '^GC bd mol wisp')" -eq 0 ] && [ "$(live_n)" -eq 1 ] && has_live ga-wisp-nxt; then ok "$label: a next wisp already exists: no second pour, the older (current) one is burned"; else bad "$label: with a next wisp (exit $RC) :: $OUT $(cat "$W/store")"; fi
}
test_block "check-inbox" check-inbox 1 yes
test_block "next-iteration" next-iteration 1 no
test_block "rebase conflict path" rebase 1 no
test_block "handle-failures path" handle-failures 1 no

# ── 4. the function-embedded site keeps its ending ────────────────────────────
echo ""; echo "Group 4: block_existing_pr"
HT="$(extract "$FORMULA" step-text handle-failures)"; MP="$(extract "$FORMULA" step-text merge-push)"
FN="$(printf '%s\n' "$MP" | awk '/^block_existing_pr\(\) \{/{f=1} f{print} f&&/^\}$/{exit}')"
if [ -n "$FN" ] && printf '%s\n' "$FN" | grep -q 'patrol-next-wisp.sh'; then ok "block_existing_pr is found in merge-push and calls the script"; else bad "block_existing_pr not found / no call in it"; fi
tail_lines="$(printf '%s\n' "$FN" | awk '/patrol-next-wisp.sh/{f=1; next} f{print}' | grep -v '^$' | tr '\n' '~')"
if [ "$tail_lines" = '  echo "$reason"~  echo "STOP. Existing PR metadata needs human correction."~  gc runtime drain-ack~  exit 1~}~' ]; then ok "after the call: reason, STOP, drain-ack, exit 1 (the function still ends the session whatever the script answered)"; else bad "the tail of block_existing_pr changed: [$tail_lines]"; fi
if printf '%s\n' "$FN" | grep -E -q -- "$CALL_RE.* \|\| echo "; then ok "the call there does not 'exit' on failure: the human-correction ending always runs"; else bad "the call in block_existing_pr is not 'script || echo ...'"; fi
: "$HT"

echo ""
echo "== refinery-formula-next-wisp.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
