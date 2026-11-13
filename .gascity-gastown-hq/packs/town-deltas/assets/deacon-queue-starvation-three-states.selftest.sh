#!/usr/bin/env bash
# deacon-queue-starvation-three-states.selftest.sh — behavioral guard for ga-d8dfjg9, part (2): the queue-starvation-check step of
# formulas/mol-deacon-patrol.toml.
#
# ## Contents
#   - What it proves
#   - Cases
#   - Usage
#
# ## What it proves
# The Step 1 block of that step printed, per active session, "agent<TAB>A<TAB>B" (A = open beads assigned to it, B = the latest updated_at).
# It read "failed" and "empty" as the same thing in two places: the session list (`gc agents list`, a command this gc does not have: it exits 1
# with a JSON error object on stdout that the old jq turned into no lines, so the loop never ran) and the per-agent bead read (two `gc bd list` calls, failures only on stderr:
# blank/blank when the read failed, "A ok, B blank" when only the second failed). The step's prose only says "A > 0 and stale", so a blank was
# free to be read as 0 (silencing a starving queue) or as "no signal" (a nudge and a warrant against a healthy session).
# The block is DELIVERED text (the TOML parsed by tomllib, escapes consumed), so it is extracted that way and EXECUTED under a stateful fake gc
# on a sandbox PATH (no real gc/bd): `gc session list` and `gc bd list`, with faults armed per scenario and a spy that counts the calls.
#
# ## Cases
#   A the list and every read answer: one line per agent, A and B right, ONE bd read per agent, a real empty queue prints 0 with a blank B
#   B a bd read for one agent fails / is not JSON / is not an array: that agent prints NAO-SEI NAO-SEI, the others are unaffected, exit 0
#   C rows without updated_at (A > 0, B blank): B is NAO-SEI, not blank
#   D the session list fails / is not JSON / says ok=false / has no sessions array: ONE NAO-SEI line, no bd call, never an empty output
#   E the session list answers with no session: prints "0 active sessions" (a real answer), no bd call
#   F the prose says what NAO-SEI means (never flagged; 3 cycles = nudge the mayor)
# Run with QSC_FORMULA_UNDER_TEST=<the formula as it was on main> it fails: that is the "before" arm.
#
# ## Usage
#   bash deacon-queue-starvation-three-states.selftest.sh     (QSC_FORMULA_UNDER_TEST=<file> for another copy)
# Exit 0 iff every case holds; 2 when the harness cannot run (never read as a pass).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HQ_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
FORMULA="${QSC_FORMULA_UNDER_TEST:-$HQ_ROOT/formulas/mol-deacon-patrol.toml}"
PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$FORMULA" ] || { echo "FATAL: formula not found at $FORMULA" >&2; exit 2; }
command -v jq >/dev/null || { echo "FATAL: jq required" >&2; exit 2; }
# vazio → no candidate has tomllib: FATAL exit 2; falhou → a candidate that is missing or cannot import tomllib is skipped
PY=""
for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import tomllib' 2>/dev/null; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "FATAL: no python3 with tomllib (>= 3.11) found" >&2; exit 2; }

echo "deacon-queue-starvation-three-states.selftest — ga-d8dfjg9: a failed read is NAO-SEI, never 0, never 'no session'"

# extract MODE: desc = the step's whole text; block = its first ```bash fence
extract() {
  "$PY" -I - "$FORMULA" "$1" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
step = next((s for s in d["steps"] if s["id"] == "queue-starvation-check"), None)
if step is None: sys.exit(3)
desc = step["description"]
if sys.argv[2] == "desc":
    sys.stdout.write(desc)
else:
    out, inb = [], False
    for l in desc.split("\n"):
        if not inb and l == "```bash": inb = True; continue
        if inb and l == "```": break
        if inb: out.append(l)
    else:
        sys.exit(5)
    print("\n".join(out))
PY
}
BLOCK="$(extract block)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$BLOCK" ]; then ok "the formula parses and the step's first bash block is found"; else echo "FATAL: could not isolate the block (python exit $rc)" >&2; exit 2; fi
DESC="$(extract desc)" || { echo "FATAL: could not read the step text" >&2; exit 2; }

STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"
cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# fake gc. $WORLD holds: sessions.json (what `gc session list --json --state active` answers), beads.<sanitised agent>.json (what
# `gc bd list --status=open --assignee=<agent> ...` answers), fault.session / fault.bd.<sanitised agent> (a mode), spy (one line per call).
W="${WORLD:-}"
[ -n "$W" ] && [ -d "$W" ] || { echo "stub gc: WORLD is not set" >&2; exit 98; }
printf 'GC %s\n' "$*" >> "$W/spy"
san() { printf '%s' "$1" | tr '/ ' '__'; }
case "${1:-}" in
  session)
    if [ "${2:-}" = list ] && [ "${3:-}" = "--json" ] && [ "${4:-}" = "--state" ] && [ "${5:-}" = active ]; then
      m=""; [ -f "$W/fault.session" ] && m=$(cat "$W/fault.session")
      case "$m" in
        fail)   echo "Error: timed out after 30s" >&2; exit 1 ;;
        text)   echo "Error: database is locked"; exit 0 ;;
        empty)  exit 0 ;;
      esac
      cat "$W/sessions.json"; exit 0
    fi
    echo "unstubbed gc session call: $*" >&2; exit 99 ;;
  bd)
    shift
    if [ "${1:-}" = list ]; then
      who=""; for a in "$@"; do case "$a" in --assignee=*) who=${a#--assignee=} ;; esac; done
      k=$(san "$who")
      m=""; [ -f "$W/fault.bd.$k" ] && m=$(cat "$W/fault.bd.$k")
      case "$m" in
        fail)   echo "Error: timed out after 30s" >&2; exit 1 ;;
        text)   echo "Error: database is locked"; exit 0 ;;
        object) printf '{"error":"x"}'; exit 0 ;;
        empty)  exit 0 ;;
      esac
      if [ -f "$W/beads.$k.json" ]; then cat "$W/beads.$k.json"; else printf '[]'; fi
      exit 0
    fi
    echo "unstubbed gc bd call: $*" >&2; exit 99 ;;
esac
# `gc agents list ...` (the old block's call) lands here: this gc has no such command
echo "unknown command \"$1\" for \"gc\"" >&2
exit 1
STUB
chmod +x "$STUBDIR/bin/gc"
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2

W=""
sess() { # sess NAME... : the session list the stub answers
  local out="" a
  for a in "$@"; do out="$out${out:+,}{\"agent_name\":\"$a\",\"alias\":\"$a\",\"state\":\"active\"}"; done
  printf '{"ok":true,"schema_version":"1","sessions":[%s],"summary":{}}' "$out" > "$W/sessions.json"
}
beads() { printf '%s' "$2" > "$W/beads.$(printf '%s' "$1" | tr '/ ' '__').json"; }
fault_bd() { printf '%s' "$2" > "$W/fault.bd.$(printf '%s' "$1" | tr '/ ' '__')"; }
world_new() { W="$(mktemp -d "$STUBDIR/world.XXXXXX")" || exit 2; : > "$W/spy"; sess; }
run_block() {
  : > "$W/spy"
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" WORLD="$W" bash -c "$BLOCK" 2>/dev/null)"; RC=$?
  ERR_UNUSED=""
  SPY_LOG="$(cat "$W/spy")"
}
spy_n() { printf '%s\n' "$SPY_LOG" | grep -c -E -- "$1"; }
line_of() { printf '%s\n' "$OUT" | awk -F'\t' -v a="$1" '$1 == a { print; exit }'; }
TAB="$(printf '\t')"

# ── A ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case A: everything answers"
world_new; sess gastown/refinery gastown/witness
beads gastown/refinery '[{"id":"b1","updated_at":"2026-11-12T10:00:00Z"},{"id":"b2","updated_at":"2026-11-12T11:30:00Z"}]'
beads gastown/witness '[]'
run_block
if [ "$RC" -eq 0 ] && [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}2${TAB}2026-11-12T11:30:00Z" ]; then ok "an agent with 2 open beads: A=2, B = the latest updated_at"; else bad "refinery line wrong (exit $RC): [$OUT]"; fi
if [ "$(line_of gastown/witness)" = "gastown/witness${TAB}0${TAB}" ]; then ok "a real empty queue: A=0 and a blank B (the only place a blank B is legitimate)"; else bad "witness line wrong: [$OUT]"; fi
if [ "$(spy_n '^GC bd list --status=open --assignee=gastown/refinery ')" -eq 1 ] && [ "$(spy_n '^GC bd list --status=open --assignee=gastown/witness ')" -eq 1 ]; then ok "ONE bd read per agent (A and B come from the same JSON)"; else bad "bd reads per agent are not 1 each: $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q -x 'GC session list --json --state active'; then ok "the session list is 'gc session list --json --state active'"; else bad "the session list call is not the expected one: $SPY_LOG"; fi
if printf '%s\n' "$SPY_LOG" | grep -q 'GC agents'; then bad "the block still calls 'gc agents ...' (no such command)"; else ok "no call to the non-existent 'gc agents'"; fi

# ── B ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case B: one agent's bd read is 'nao sei'"
for m in fail text object empty; do
  world_new; sess gastown/refinery gastown/witness
  beads gastown/refinery '[{"id":"b1","updated_at":"2026-11-12T10:00:00Z"}]'; beads gastown/witness '[{"id":"w1","updated_at":"2026-11-12T12:00:00Z"}]'
  fault_bd gastown/refinery "$m"
  run_block
  if [ "$RC" -eq 0 ] && [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}NAO-SEI${TAB}NAO-SEI" ]; then ok "read '$m': NAO-SEI on both columns (not blank, not 0)"; else bad "read '$m': refinery line [$(line_of gastown/refinery)] (exit $RC)"; fi
  if [ "$(line_of gastown/witness)" = "gastown/witness${TAB}1${TAB}2026-11-12T12:00:00Z" ]; then ok "read '$m': the other agent's line is unaffected"; else bad "read '$m': witness line [$(line_of gastown/witness)]"; fi
done

# ── C ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case C: rows without updated_at"
world_new; sess gastown/refinery; beads gastown/refinery '[{"id":"b1"},{"id":"b2"}]'
run_block
if [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}2${TAB}NAO-SEI" ]; then ok "A=2 with no readable updated_at: B is NAO-SEI (every bead has one: blank would read as 'no signal')"; else bad "rows without updated_at: [$(line_of gastown/refinery)]"; fi

# ── D ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case D: the session list is 'nao sei'"
for m in fail text empty; do
  world_new; sess gastown/refinery; printf '%s' "$m" > "$W/fault.session"
  run_block
  if [ "$RC" -eq 0 ] && [ "$OUT" = "NAO-SEI${TAB}NAO-SEI${TAB}NAO-SEI" ] && [ "$(spy_n '^GC bd ')" -eq 0 ]; then ok "list '$m': ONE NAO-SEI line, no bd call (never an empty output that reads as 'no session')"; else bad "list '$m': out [$OUT] exit $RC bd-calls=$(spy_n '^GC bd ')"; fi
done
for body in '{"ok":false,"sessions":[]}' '{"ok":true}' '[]' '{"ok":true,"sessions":{"a":1}}'; do
  world_new; printf '%s' "$body" > "$W/sessions.json"
  run_block
  if [ "$OUT" = "NAO-SEI${TAB}NAO-SEI${TAB}NAO-SEI" ] && [ "$(spy_n '^GC bd ')" -eq 0 ]; then ok "list body $body: NAO-SEI, no bd call"; else bad "list body $body: out [$OUT]"; fi
done

# ── E ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case E: the list answers and is empty"
world_new; sess
run_block
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^0 active sessions' && [ "$(spy_n '^GC bd ')" -eq 0 ]; then ok "a real empty list prints '0 active sessions' (distinguishable from NAO-SEI), no bd call"; else bad "empty list: out [$OUT]"; fi
if [ -n "$OUT" ]; then ok "the output is never empty (silence is not an answer)"; else bad "empty output"; fi

# ── F ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case F: the prose"
for pat in 'NAO-SEI' 'never flagged' 'three cycles in a row' 'NAO-SEI. is not 0'; do
  if printf '%s' "$DESC" | grep -q -E -- "$pat"; then ok "the step text says: $pat"; else bad "the step text lacks: $pat"; fi
done

echo ""
echo "== deacon-queue-starvation-three-states.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
