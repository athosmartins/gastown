#!/usr/bin/env bash
# witness-prompt-pour-idempotent.selftest.sh — behavioral drift-guard for ga-5cl2vvn (daughter of ga-jhsxo4p).
#
# Bug ga-5cl2vvn: the witness prompt (town-deltas.template.md, section WITNESS) has two blocks that POUR a witness wisp: Step 3
# (the bootstrap) and pour_next() inside the "CRITICAL: No Idle State" block. Both read the new wisp back BEFORE assigning it, and
# neither burned the wisp it had just poured when a later leg failed. When the pour SUCCEEDED (the wisp exists, with no owner) and
# the read-back or the assign failed, the block ended with exit 1 and the wisp stayed in the store with no assignee: the guard read
# of the next run asks "which wisps are assigned to me?" and cannot see it, so the re-run poured AGAIN. Two wisps, and the first
# one stays for good (an unassigned wisp is found by no `--assignee` read, and the reaper only closes a wisp whose parent is
# closed: a root-only patrol wisp has none). The same window ga-jhsxo4p closed in the formula's `next-iteration` step; the prompt's
# own pours were the follow-up that bead asked for. Step 3 also assigned with $GC_ALIAS while its guard reads by $GC_AGENT, so
# even a clean bootstrap could be invisible to the guard of the next run whenever the two differ.
#
# The fix is the formula's design in both blocks: read first (Step 3 and the No-Idle block already did, in three states), assign
# BEFORE the read-back (what a later failure leaves behind is a wisp the re-run finds by its assignee), read the assign's exit
# code, burn the wisp just poured when it cannot be assigned (never the current one), and say loudly what cannot be undone (the
# burn fails too, or the pour's answer is lost) with a mail to the mayor carrying the wisp's id, or the read that finds it when no
# id came back; the mail is a write too, so when it fails the block says so instead of claiming the mayor was told. Step 3
# assigns to $GC_AGENT.
#
# The two blocks are EXTRACTED from the template and EXECUTED (never compared as text) under a stub `gc` on a sandbox PATH. The
# stub is stateful: two tiny stores on disk (what `-C <rig root>` sees, and another one where a wrong-store pour lands), faults
# armed per scenario (`mode:count`), and a spy that logs every call. The proof is to RUN THE BLOCK AGAIN in the same world after
# each failure and count: pours, live wisps, assigned wisps, burns, mails. The healthy scenarios prove the spy sees a pour, an
# assign, a read-back and a burn. GC_ALIAS differs from GC_AGENT in every run, on purpose.
#
# Sibling guards on the same section: witness-startup-three-states.selftest.sh (the three-state reads, Step 1, the prose),
# witness-patrol-wisp-store.selftest.sh (-C pins; its sed range runs from the `BD_C=()` line to the `gc hook` line that ends the
# No-Idle block) and witness-next-iteration-idempotent.selftest.sh (the same rule in the formula's step).
#
# WITNESS_TEMPLATE_UNDER_TEST overrides the template (mutant runs, see the delivery of ga-5cl2vvn).
# Exit 0 iff every scenario holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
TEMPLATE="${WITNESS_TEMPLATE_UNDER_TEST:-$TOWN_DELTAS_ROOT/template-fragments/town-deltas.template.md}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$TEMPLATE" ] || { echo "FATAL: template fragment not found at $TEMPLATE" >&2; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }

echo "witness-prompt-pour-idempotent.selftest — ga-5cl2vvn: a re-run after pour-ok + read-back/assign-failed ends with ONE wisp"

FAKE_RIG="/fake/rig"
FAKE_AGENT="property_scrapers/gastown.witness"
FAKE_ALIAS="some-other-alias"   # never equal to GC_AGENT: an assign by the alias would be invisible to a read by the agent

# ── Extract the two blocks ────────────────────────────────────────────────────
# extract_block HEADING [RIGROOT]: the first ```bash fence after the line that starts with HEADING, up to its closing fence,
# with the Go-template fields filled in the way the engine renders a rig (RigRoot = $FAKE_RIG unless a second argument,
# possibly empty, says otherwise).
# vazio → prints nothing (the caller refuses to run an empty block); falhou → awk/sed rc is not read, an empty block is the same refusal
extract_block() {
  local rig="${2-$FAKE_RIG}"
  awk -v head="$1" '
    index($0, head) == 1 { seen = 1; next }
    seen && /^```bash$/ { inb = 1; next }
    inb && /^```$/ { exit }
    inb { print }
  ' "$TEMPLATE" | sed -e "s|{{ \.RigRoot }}|$rig|g" -e "s|{{ \.BindingPrefix }}|bp|g"
}
H3='**Step 3 substituto**'
HN='**Bloco "CRITICAL: No Idle State" substituto**'
for h in "$H3" "$HN"; do
  n="$(grep -c -F -- "$h" "$TEMPLATE")"
  if [ "$n" = 1 ]; then ok "anchor found exactly once: $h"; else bad "anchor '$h' found $n times in the template (expected 1) — the extraction cannot be trusted"; fi
done
STEP3="$(extract_block "$H3")"
STEPN="$(extract_block "$HN")"
STEPN_NORIG="$(extract_block "$HN" "")"
for pair in "Step 3:mol wisp:$STEP3" "No-Idle:pour_next:$STEPN"; do
  label="${pair%%:*}"; rest="${pair#*:}"; marker="${rest%%:*}"; code="${rest#*:}"
  if [ -n "$code" ] && printf '%s\n' "$code" | grep -F -q -- "$marker"; then
    ok "$label block extracted (carries '$marker')"
  else
    echo "FATAL: could not isolate the $label block (anchor moved or block empty) — nothing below can be trusted" >&2
    exit 2
  fi
done

# ── Stub gc + sandbox PATH ────────────────────────────────────────────────────
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# A fake gc with state. $WORLD holds: rig and other (one wisp per line, "id|assignee|status"), seq (how many pours were attempted),
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
  mail)
    if fault_mode mail >/dev/null; then echo "Error: mail failed" >&2; exit 1; fi   # the spy has logged the attempt either way
    exit 0
    ;;
  session|hook) exit 0 ;;   # what `gc hook` prints is not under test
  bd)
    shift
    store=other
    if [ "${1:-}" = "-C" ]; then
      [ "${2:-}" = "/fake/rig" ] && store=rig
      shift 2
    else
      store=rig   # no pin: the cwd store (only the empty-RigRoot fallback of the No-Idle block goes here)
    fi
    sf="$W/$store"
    case "${1:-}" in
      list)
        who=""; lim=50; st=""
        for a in "$@"; do
          case "$a" in
            --assignee=*) who=${a#--assignee=} ;;
            --limit=*) lim=${a#--limit=} ;;
            --status=*) st=${a#--status=} ;;
          esac
        done
        if m=$(fault_mode list); then
          case "$m" in
            fail)     echo "Error: timed out after 30s" >&2; exit 1 ;;
            failjson) echo "Error: timed out after 30s" >&2; printf '[]'; exit 1 ;;
            empty)    exit 0 ;;
            text)     echo "Error: database is locked"; exit 0 ;;
          esac
        fi
        out=""; n=0
        while IFS='|' read -r id as stt; do
          [ -n "$id" ] || continue
          [ "$as" = "$who" ] || continue
          [ -z "$st" ] || [ "$stt" = "$st" ] || continue
          [ "$n" -lt "$lim" ] || break
          out="$out${out:+,}{\"id\":\"$id\",\"assignee\":\"$as\",\"status\":\"$stt\",\"issue_type\":\"molecule\"}"
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
        sed "s#^$id|[^|]*|#$id|$who|#" "$sf" > "$sf.new" && mv "$sf.new" "$sf"
        exit 0
        ;;
      mol)
        case "${2:-}" in
          wisp)
            pm=$(fault_mode pour) || pm=ok
            n=$(cat "$W/seq"); n=$((n + 1)); echo "$n" > "$W/seq"; id="ga-wisp-new$n"
            case "$pm" in
              fail)       echo "Error: timed out after 30s" >&2; exit 1 ;;                                    # nothing was created
              noid)       echo "$id||open" >> "$W/rig"; exit 1 ;;                                            # created, the answer was lost
              garbage)    echo "$id||open" >> "$W/rig"; echo "Created wisp"; exit 0 ;;                       # created, the answer is not JSON
              wrongstore) echo "$id||open" >> "$W/other"; printf '{"new_epic_id":"%s","created":1,"phase":"vapor"}' "$id"; exit 0 ;;
            esac
            echo "$id||open" >> "$sf"
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
# The blocks run on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh): a vanished stub is "command not found", never the real town.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2   # jq: the parse the blocks do; gc is the stub above

# ── World + runner ────────────────────────────────────────────────────────────
W=""
# world_new KIND: a fresh world, nothing armed. step3 = a witness with no wisp at all (the bootstrap); noidle = the wisp being
# executed (ga-wisp-cur, in progress, assigned to this witness) is live and there is no next one.
world_new() {
  W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
  : > "$W/rig"; : > "$W/other"; : > "$W/spy"; echo 0 > "$W/seq"
  if [ "$1" = noidle ]; then printf 'ga-wisp-cur|%s|in_progress\n' "$FAKE_AGENT" > "$W/rig"; fi
}
arm() { printf '%s:%s\n' "$2" "$3" > "$W/fault.$1"; }   # arm KIND MODE COUNT

# run_block CODE [VAR=value ...] — one run of the block in a clean environment (env -i: none of this session's GC_* leaks in).
# Sets OUT (stdout+stderr), RC and SPY_LOG (the gc calls of THIS run, one per line). The world persists between runs: that is the point.
run_block() {
  local code="$1"
  shift
  : > "$W/spy"
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" GC_AGENT="$FAKE_AGENT" GC_ALIAS="$FAKE_ALIAS" "$@" bash -c "$code" 2>&1)"
  RC=$?
  # vazio → no gc call was made (a legitimate answer for a refusal that runs before any call); falhou → the spy file is ours, cat cannot fail short of a dead disk
  SPY_LOG="$(cat "$W/spy")"
  # the world's state files are ours: were they gone, every "= 0" check below would pass for the wrong reason, so refuse to go on (exit 2: never read as a pass)
  [ -f "$W/rig" ] && [ -f "$W/seq" ] || { echo "FATAL: the world $W lost its state files — nothing below can be trusted" >&2; exit 2; }
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
live_next()     { grep -v '^ga-wisp-cur|' "$W/rig" | grep -c .; }                       # live wisps in the rig store besides the one being executed
assigned_next() { grep -v '^ga-wisp-cur|' "$W/rig" | grep -F -c "|$FAKE_AGENT|"; }      # ... of those, assigned to this witness (by GC_AGENT, not by the alias)
cur_alive()     { grep -q '^ga-wisp-cur|' "$W/rig"; }

# one scenario table for both blocks: code and world kind per block
block_code() { case "$1" in step3) printf '%s' "$STEP3" ;; noidle) printf '%s' "$STEPN" ;; esac; }
mail_with() { printf '%s\n' "$SPY_LOG" | grep '^GC mail send mayor/ -s ' | grep -F -q -- "$1"; }   # a mail of THIS run, to mayor/ (the address the formula uses), that carries the text

for BLOCK in step3 noidle; do
CODE="$(block_code "$BLOCK")"
echo ""
echo "══ $BLOCK ══"

# ── Group A: the healthy cycle ────────────────────────────────────────────────
echo "Group A [$BLOCK]: healthy cycle"
world_new "$BLOCK"
run_block "$CODE"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && [ "$(spy_n "$MAIL_RE")" -eq 0 ]; then
  ok "exit 0, ONE pour, one wisp, assigned to GC_AGENT (GC_ALIAS differs), no mail"
else
  bad "healthy cycle (exit $RC, pours=$(pours), live=$(live_next), assigned to the agent=$(assigned_next), mails=$(spy_n "$MAIL_RE")) :: $OUT"
fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -- "update ga-wisp-new1 --assignee=$FAKE_AGENT"; then ok "the assign names the identity the guard reads with (--assignee=GC_AGENT)"; else bad "the assign does not go to GC_AGENT: $SPY_LOG"; fi
r="$(spy_first "$LIST_RE")"; p="$(spy_first "$POUR_RE")"; u="$(spy_first "$UPDATE_RE")"; s="$(spy_first "$SHOW_RE")"
if [ -n "$r" ] && [ -n "$p" ] && [ "$r" -lt "$p" ]; then ok "the read comes BEFORE the pour"; else bad "the read does not precede the pour (read line '$r', pour line '$p'): $SPY_LOG"; fi
if [ -n "$p" ] && [ -n "$u" ] && [ -n "$s" ] && [ "$p" -lt "$u" ] && [ "$u" -lt "$s" ]; then ok "pour, then ASSIGN, then read-back (the assign comes before the read-back)"; else bad "wrong order (pour line '$p', assign line '$u', read-back line '$s'): $SPY_LOG"; fi
nbd="$(printf '%s\n' "$SPY_LOG" | grep -c '^GC bd ')"; npin="$(printf '%s\n' "$SPY_LOG" | grep '^GC bd ' | grep -c -F -- "-C $FAKE_RIG ")"
if [ "$nbd" -gt 0 ] && [ "$nbd" -eq "$npin" ]; then ok "every gc bd call carries the -C pin ($npin of $nbd)"; else bad "a gc bd call went out without the -C pin ($npin of $nbd pinned): $SPY_LOG"; fi
if [ "$BLOCK" = step3 ]; then
  if printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-new1'; then ok "the output names the wisp"; else bad "the output does not name the wisp: $OUT"; fi
fi
if [ "$BLOCK" = noidle ]; then
  b="$(spy_first "$BURN_RE")"
  if [ "$(spy_n "$BURN_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q 'mol burn ga-wisp-cur --force' && [ -n "$b" ] && [ -n "$s" ] && [ "$s" -lt "$b" ] && ! cur_alive; then
    ok "the current wisp is burned once, AFTER the next one was assigned and read back"
  else
    bad "burn of the current wisp (burns=$(spy_n "$BURN_RE"), burn line '$b', read-back line '$s', current alive=$(cur_alive && echo yes || echo no)): $SPY_LOG"
  fi
  if [ "$(printf '%s\n' "$SPY_LOG" | tail -n 1)" = "GC hook" ]; then ok "the block still ends with gc hook"; else bad "the block no longer ends with gc hook: $SPY_LOG"; fi
else
  if [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "nothing is burned in a healthy bootstrap"; else bad "a healthy bootstrap burned something: $SPY_LOG"; fi
fi
# a second run right after a good one is a no-op for the pours
run_block "$CODE"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(spy_n "$POUR_RE")" -eq 0 ]; then ok "running the block again after a good run pours nothing"; else bad "second run after a good one (exit $RC, pours=$(pours), live=$(live_next)) :: $OUT"; fi

# ── Group C: THE BUG — the pour worked, the next leg did not, then the block is run again ─
echo "Group C [$BLOCK]: pour ok + read-back/assign failed, then a re-run -> exactly one next wisp"
# C1: the read-back fails once (the assign worked)
world_new "$BLOCK"; arm show fail 1
run_block "$CODE"; rc1=$RC; out1="$OUT"; cur1="$(cur_alive && echo yes || echo no)"
run_block "$CODE"
if [ "$rc1" -eq 1 ] && [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then
  ok "THE BUG (a): read-back fails after a good pour -> exit 1; the re-run exits 0 and the WHOLE history has ONE pour and ONE wisp, assigned"
else
  bad "THE BUG (a): after pour-ok + read-back-failed and a re-run: exit $rc1 then $RC, pours=$(pours) (want 1), wisps=$(live_next) (want 1), assigned=$(assigned_next) (want 1) :: $out1 // $OUT"
fi
if [ "$BLOCK" = noidle ]; then
  if [ "$cur1" = yes ] && ! cur_alive && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 1 ]; then ok "THE BUG (a): the current wisp survives the failed run and is burned by the re-run, which finds the next wisp by its assignee"; else bad "THE BUG (a): current wisp alive after run 1: $cur1; after the re-run: $(cur_alive && echo yes || echo no); burns of it in the re-run: $(spy_n 'mol burn ga-wisp-cur')"; fi
fi
# C2: the assign fails once
world_new "$BLOCK"; arm update fail 1
run_block "$CODE"; rc1=$RC; out1="$OUT"; left1="$(live_next)"; burn1="$(spy_n "^GC bd -C $FAKE_RIG mol burn ga-wisp-new1 --force\$")"; curburn1="$(spy_n 'mol burn ga-wisp-cur')"; mails1="$(spy_n "$MAIL_RE")"
run_block "$CODE"
if [ "$rc1" -eq 1 ] && [ "$left1" -eq 0 ] && [ "$burn1" -eq 1 ] && [ "$curburn1" -eq 0 ] && [ "$mails1" -eq 0 ]; then
  ok "THE BUG (b): assign fails -> exit 1, the wisp it just poured is burned (nothing left behind), the current wisp is not, no mail needed"
else
  bad "THE BUG (b): assign failed but exit=$rc1, wisps left=$left1 (want 0), burn of the new wisp=$burn1 (want 1), burn of the current wisp=$curburn1 (want 0), mails=$mails1 (want 0) :: $out1"
fi
if [ "$RC" -eq 0 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then ok "THE BUG (b): the re-run ends with exactly one wisp, assigned"; else bad "THE BUG (b): re-run left wisps=$(live_next) assigned=$(assigned_next) (exit $RC) :: $OUT"; fi
# C3: the assign fails AND the burn fails (the one case the block cannot undo): loud, with the id
world_new "$BLOCK"; arm update fail 1; arm burn fail 1
run_block "$CODE"
if [ "$RC" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && mail_with 'ga-wisp-new1'; then
  ok "assign and burn both fail -> exit 1, the stray stays (it cannot be undone) and the mayor is mailed with ITS ID"
else
  bad "double failure not handled loudly (exit $RC, wisps=$(live_next), assigned=$(assigned_next), mails=$(spy_n "$MAIL_RE")) :: $OUT $SPY_LOG"
fi
if mail_with 'mol burn ga-wisp-new1 --force'; then ok "the mail says how to clean it (the burn command for that id)"; else bad "the mail does not say how to clean the stray: $SPY_LOG"; fi
if printf '%s\n' "$OUT" | grep -F -q 'LEFT BEHIND' || printf '%s\n' "$OUT" | grep -F -q 'FICOU PARA TRÁS'; then ok "the output announces the stray as left behind"; else bad "the stray is not announced as left behind: $OUT"; fi
if ! printf '%s\n' "$OUT" | grep -q -e 'mail ao mayor FALHOU' -e 'mail to the mayor FAILED'; then ok "the mail went out: the output does not say it failed"; else bad "the output says the mail failed although it went out: $OUT"; fi
if [ "$BLOCK" = noidle ]; then
  if cur_alive && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ]; then ok "the current wisp is not burned when the next one could not be assigned"; else bad "the current wisp was burned or lost after a failed assign: $SPY_LOG"; fi
fi
# C3b: the same double failure, and the mail to the mayor fails too: the block must not claim the mayor was told
world_new "$BLOCK"; arm update fail 1; arm burn fail 1; arm mail fail 1
run_block "$CODE"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$OUT" | grep -q -e 'mail ao mayor FALHOU' -e 'mail to the mayor FAILED' && printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-new1' && ! printf '%s\n' "$OUT" | grep -q -e 'foi avisado' -e 'is mailed'; then
  ok "assign, burn and the mail all fail -> exit 1, the output says the MAIL failed (the witness must tell the mayor), still names the stray, and claims no mail"
else
  bad "double failure + failed mail (exit $RC, mail attempts=$(spy_n "$MAIL_RE")) :: $OUT"
fi
# C4: the read-back keeps failing, the assign worked: the re-run does not need it (it finds the assigned wisp)
world_new "$BLOCK"; arm show fail 999
run_block "$CODE"; rc1=$RC
run_block "$CODE"
if [ "$rc1" -eq 1 ] && [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$POUR_RE")" -eq 0 ]; then
  ok "a read-back that never recovers does not block the loop: the re-run finds the assigned wisp (no pour, no read-back), exit 0"
else
  bad "persistent read-back failure: exit $rc1 then $RC, pours=$(pours), shows in the re-run=$(spy_n "$SHOW_RE") :: $OUT"
fi

# ── Group D: the pour's own answer is lost, or the pour itself fails ─────────
echo "Group D [$BLOCK]: the pour fails, loses its answer, or lands in the wrong store"
world_new "$BLOCK"; arm pour fail 1
run_block "$CODE"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$(live_next)" -eq 0 ]; then
  ok "the pour fails outright -> exit 1, no assign / read-back / burn of anything"
else
  bad "failed pour (exit $RC, updates=$(spy_n "$UPDATE_RE"), shows=$(spy_n "$SHOW_RE"), burns=$(spy_n "$BURN_RE"), wisps=$(live_next)) :: $OUT"
fi
if [ "$BLOCK" = noidle ]; then if cur_alive; then ok "the current wisp is untouched when the pour fails"; else bad "the current wisp was lost when the pour failed: $SPY_LOG"; fi; fi
for m in noid garbage; do
  world_new "$BLOCK"; arm pour "$m" 1
  run_block "$CODE"
  if [ "$RC" -eq 1 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && [ "$(spy_n "$SHOW_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] \
     && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && mail_with '--no-assignee' && printf '%s\n' "$OUT" | grep -q -e 'MAY' -e 'PODE'; then
    ok "pour answered '$m' (the wisp exists, its id is unknown) -> exit 1, nothing assigned or burned by guess, says a wisp MAY exist, mails the read that finds it"
  else
    bad "pour answer '$m': exit $RC, wisps=$(live_next), mails=$(spy_n "$MAIL_RE"), blind calls=$(spy_n "$UPDATE_RE")/$(spy_n "$SHOW_RE")/$(spy_n "$BURN_RE") :: $OUT"
  fi
  if [ "$BLOCK" = noidle ]; then if cur_alive && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ]; then :; else bad "pour answer '$m': the current wisp was burned or lost"; fi; fi
  if ! printf '%s\n' "$OUT" | grep -q -e 'mail ao mayor FALHOU' -e 'mail to the mayor FAILED'; then :; else bad "pour answer '$m': the output says the mail failed although it went out: $OUT"; fi
done
world_new "$BLOCK"; arm pour noid 1; arm mail fail 1
run_block "$CODE"
if [ "$RC" -eq 1 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && printf '%s\n' "$OUT" | grep -q -e 'mail ao mayor FALHOU' -e 'mail to the mayor FAILED' && ! printf '%s\n' "$OUT" | grep -q -e 'foi avisado' -e 'is mailed'; then
  ok "pour without id + a failing mail -> exit 1, the output says the MAIL failed and claims no mail"
else
  bad "pour without id + failed mail (exit $RC, mail attempts=$(spy_n "$MAIL_RE")) :: $OUT"
fi
world_new "$BLOCK"; arm pour wrongstore 1
run_block "$CODE"
if [ "$RC" -eq 1 ] && [ "$(live_next)" -eq 0 ] && [ "$(spy_n "$MAIL_RE")" -eq 1 ] && mail_with 'ga-wisp-new1' && mail_with 'mol burn ga-wisp-new1 --force'; then
  ok "THE ga-3v2n4 case: the pour lands outside the pinned store -> exit 1, nothing of it in the pinned store, the mayor is mailed with the id and the burn command"
else
  bad "wrong-store pour not handled (exit $RC, wisps in the pinned store=$(live_next), mails=$(spy_n "$MAIL_RE")) :: $OUT $SPY_LOG"
fi
if [ "$BLOCK" = noidle ]; then if cur_alive && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ]; then ok "the wrong-store pour does not cost the current wisp"; else bad "the current wisp was burned or lost after a wrong-store pour: $SPY_LOG"; fi; fi
done

# ── Group E: the current wisp is never burned unless a next one exists and is assigned (No-Idle only) ──
echo ""
echo "Group E: the No-Idle block never burns the current wisp behind a failed next wisp"
e_runs=0; e_bad=0
for armed in "show fail 1" "update fail 1" "update fail 1|burn fail 1" "pour noid 1" "pour fail 1" "pour garbage 1" "pour wrongstore 1"; do
  world_new noidle
  IFS='|' read -r a1 a2 <<EOF
$armed
EOF
  # shellcheck disable=SC2086
  arm $a1
  # shellcheck disable=SC2086
  if [ -n "${a2:-}" ]; then arm $a2; fi
  run_block "$STEPN"
  e_runs=$((e_runs + 1))
  if [ "$RC" -eq 1 ] && [ "$(spy_n 'mol burn ga-wisp-cur')" -eq 0 ] && cur_alive; then :; else e_bad=$((e_bad + 1)); bad "the block burned or lost the CURRENT wisp (or did not exit 1) when '$armed': exit $RC :: $SPY_LOG"; fi
done
if [ "$e_bad" -eq 0 ]; then ok "the current wisp survives each of $e_runs injected failures of the next wisp, and the block exits 1"; fi

# ── Group E2: the third branch of the No-Idle block — no current wisp and no next one: it pours, it burns nothing ──
echo ""
echo "Group E2: No-Idle with no wisp at all -> pours one, burns nothing, and a failure there is re-runnable too"
world_new noidle; : > "$W/rig"
run_block "$STEPN"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then
  ok "no current and no next wisp -> exit 0, one pour, one wisp assigned to GC_AGENT, nothing burned"
else
  bad "no-wisp branch (exit $RC, pours=$(pours), live=$(live_next), assigned=$(assigned_next), burns=$(spy_n "$BURN_RE")) :: $OUT"
fi
world_new noidle; : > "$W/rig"; arm show fail 1
run_block "$STEPN"; rc1=$RC
run_block "$STEPN"
if [ "$rc1" -eq 1 ] && [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(live_next)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then
  ok "no-wisp branch: read-back fails once -> exit 1, then the re-run finds the assigned wisp (ONE pour in the whole history)"
else
  bad "no-wisp branch, read-back failure: exit $rc1 then $RC, pours=$(pours), wisps=$(live_next), assigned=$(assigned_next) :: $OUT"
fi
world_new noidle; : > "$W/rig"; arm update fail 1
run_block "$STEPN"
if [ "$RC" -eq 1 ] && [ "$(live_next)" -eq 0 ] && [ "$(spy_n 'mol burn ga-wisp-new1 --force')" -eq 1 ]; then
  ok "no-wisp branch: assign fails -> exit 1 (the block does not go on to gc hook) and the wisp just poured is burned"
else
  bad "no-wisp branch, assign failure: exit $RC, wisps left=$(live_next), burns of the new wisp=$(spy_n 'mol burn ga-wisp-new1 --force') :: $OUT"
fi

# ── Group F: the guard reads still decide who may pour ───────────────────────
echo ""
echo "Group F: a wisp that is already mine stops the pour; someone else's does not"
world_new step3; printf 'ga-wisp-live|%s|open\n' "$FAKE_AGENT" >> "$W/rig"
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$UPDATE_RE")" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-live'; then ok "Step 3: a wisp of mine already exists -> no pour, names it, exit 0"; else bad "Step 3: existing wisp did not stop the pour (exit $RC, pours=$(pours)) :: $OUT"; fi
world_new step3; printf 'ga-wisp-theirs|some/other.witness|open\n' >> "$W/rig"
run_block "$STEP3"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ]; then ok "Step 3: a wisp that belongs to someone else does not count: this witness still bootstraps its own"; else bad "Step 3: someone else's wisp stopped the bootstrap (exit $RC, pours=$(pours), assigned=$(assigned_next)) :: $OUT"; fi
world_new noidle; printf 'ga-wisp-nxt|%s|open\n' "$FAKE_AGENT" >> "$W/rig"
run_block "$STEPN"
if [ "$RC" -eq 0 ] && [ "$(pours)" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ] && ! cur_alive; then ok "No-Idle: current wisp and a next one -> burns only the current, no second pour"; else bad "No-Idle: next wisp already there but pours=$(pours), burns=$(spy_n "$BURN_RE") :: $OUT"; fi

# ── Group G: a rig without RigRoot keeps the documented fallback, and the same rules hold there ─
echo ""
echo "Group G: empty RigRoot (the cwd-store fallback of the No-Idle block)"
world_new noidle
run_block "$STEPN_NORIG"
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'WARNING:.*is empty' && [ "$(spy_n '^GC bd -C ')" -eq 0 ] && [ "$(pours)" -eq 1 ] && [ "$(assigned_next)" -eq 1 ] && ! cur_alive; then
  ok "empty RigRoot: warns, goes without -C, still pours, assigns, reads back and burns the current wisp"
else
  bad "empty-RigRoot healthy path (exit $RC, pinned calls=$(spy_n '^GC bd -C '), pours=$(pours), assigned=$(assigned_next)) :: $OUT $SPY_LOG"
fi
world_new noidle; arm update fail 1; arm burn fail 1
run_block "$STEPN_NORIG"
if [ "$RC" -eq 1 ] && mail_with 'ga-wisp-new1' && ! printf '%s\n' "$SPY_LOG" | grep '^GC mail send' | grep -F -q -- "-C ''" && cur_alive; then
  ok "empty RigRoot + assign and burn failing: the mail carries the id and does not tell the mayor to use an empty -C"
else
  bad "empty-RigRoot double failure (exit $RC) :: $OUT $SPY_LOG"
fi

# ── Group H: the prose says what the blocks do ───────────────────────────────
echo ""
echo "Group H: the section agrees with the blocks"
SECTION="$(sed -n '/WITNESS: o Startup Protocol/,$p' "$TEMPLATE")"
if printf '%s\n' "$SECTION" | grep -F -q 'ga-5cl2vvn'; then ok "the section cites ga-5cl2vvn"; else bad "the section does not cite ga-5cl2vvn"; fi
STALE=""
for s in 'e verificação pós-pour antes de assign/burn' 'confere o pour antes de' 'sem verificação) até ser queimada'; do
  printf '%s\n' "$SECTION" | grep -F -q -- "$s" && STALE="$STALE [$s]"
done
if [ -z "$STALE" ]; then ok "the section no longer says the pour is verified BEFORE the assign"; else bad "the section still carries the verify-before-assign claim:$STALE"; fi
NEWPHRASE="lendo os seus wisps antes do pour e atribuindo o novo antes de"
n="$(printf '%s\n' "$SECTION" | grep -c -F -- "$NEWPHRASE")"
if [ "$n" = 1 ] && printf '%s\n' "$SECTION" | grep -F -- "$NEWPHRASE" | grep -F -q "{{ .RigRoot }}"; then
  ok "the guard paragraph describes the formula's step as reading before the pour and assigning before the read-back, on the line that carries the RigRoot pin"
else
  bad "the guard paragraph's sentence about the formula's step is missing, duplicated ($n times) or off the RigRoot line (the lint guard's Case 3 anchors on it)"
fi
for w in 'Se o Step 3 saiu 1' 'O pour é seguro de repetir'; do
  if printf '%s\n' "$SECTION" | grep -F -q -- "$w"; then ok "the section tells the witness what to do on a failed pour: '$w'"; else bad "the section lost the paragraph '$w'"; fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
