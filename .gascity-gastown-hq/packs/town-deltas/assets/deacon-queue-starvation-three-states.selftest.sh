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
# It read "failed" and "empty" as the same thing in three places: the session list (`gc agents list`, a command this gc does not have: it exits 1
# with a JSON error object on stdout that the old jq turned into no lines, so the loop never ran), the per-agent bead read (two `gc bd list` calls, failures only on stderr:
# blank/blank when the read failed, "A ok, B blank" when only the second failed), and the identity of a session (gate-fix 1: a session the list
# returns without a readable name was dropped, so a list full of such sessions printed "0 active sessions"). The step's prose only says "A > 0 and stale",
# so a blank was free to be read as 0 (silencing a starving queue) or as "no signal" (a nudge and a warrant against a healthy session).
# A session is read under every name bd may hold its beads under (alias, name, session_name; NOT agent_name, which differs from name on pool instances).
# The block is DELIVERED text (the TOML parsed by tomllib, escapes consumed), so it is extracted that way and EXECUTED under a stateful fake gc
# on a sandbox PATH (no real gc/bd): `gc session list` and `gc bd list`, with faults armed per scenario and a spy that counts the calls.
#
# ## Cases
#   A the list and every read answer: one line per session, A and B summed over its names, ONE bd read per distinct name, a real empty queue prints 0 with a blank B
#   B a bd read (under ANY of a session's names) fails / is not JSON / is not an array: that session prints NAO-SEI NAO-SEI, the others are unaffected, exit 0
#   C rows without updated_at (A > 0, B blank): B is NAO-SEI, not blank
#   D the session list fails / is not JSON / says ok=false / has no sessions array: ONE NAO-SEI line, no bd call, never an empty output
#   E the session list answers with no session: prints "0 active sessions" (a real answer), no bd call
#   F the prose says what NAO-SEI means (never flagged; 3 cycles = nudge the mayor) and makes no absolute promise the code does not keep
#   G production shape: a pool instance (agent_name != name) is read under its name, never under agent_name; two instances of one agent are two lines
#   H sessions the list returns without a readable identity: one NAO-SEI line each (never "0 active sessions", never dropped); name-only sessions are read
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
sn_of() { printf '%s-gawisp1' "$(printf '%s' "$1" | tr '/ ' '__')"; }   # a session_name that differs from the name, as in production
sess_raw() { # sess_raw ROW...: the session list the stub answers, rows given as raw JSON
  local out="" a
  for a in "$@"; do out="$out${out:+,}$a"; done
  printf '{"ok":true,"schema_version":"1","sessions":[%s],"summary":{}}' "$out" > "$W/sessions.json"
}
sess() { # sess NAME... : production-shaped sessions (name == alias == agent_name, session_name different, an id)
  local rows=() a
  for a in "$@"; do rows+=("{\"id\":\"ga-$(printf '%s' "$a" | tr '/ ' '__')\",\"name\":\"$a\",\"alias\":\"$a\",\"session_name\":\"$(sn_of "$a")\",\"agent_name\":\"$a\",\"state\":\"active\"}"); done
  if [ "${#rows[@]}" -gt 0 ]; then sess_raw "${rows[@]}"; else sess_raw; fi
}
beads() { printf '%s' "$2" > "$W/beads.$(printf '%s' "$1" | tr '/ ' '__').json"; }
beads_sn() { beads "$(sn_of "$1")" "$2"; }   # beads held under the session_name of NAME
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
beads_sn gastown/refinery '[{"id":"b3","updated_at":"2026-11-12T12:15:00Z"}]'
beads gastown/witness '[]'
run_block
if [ "$RC" -eq 0 ] && [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}3${TAB}2026-11-12T12:15:00Z" ]; then ok "2 beads under the name + 1 under the session_name: A=3, B = the latest updated_at over both"; else bad "refinery line wrong (exit $RC): [$OUT]"; fi
if [ "$(line_of gastown/witness)" = "gastown/witness${TAB}0${TAB}" ]; then ok "a real empty queue: A=0 and a blank B (the only place a blank B is legitimate)"; else bad "witness line wrong: [$OUT]"; fi
if [ "$(spy_n '^GC bd list --status=open --assignee=gastown/refinery ')" -eq 1 ] && [ "$(spy_n "^GC bd list --status=open --assignee=$(sn_of gastown/refinery) ")" -eq 1 ] && [ "$(spy_n '^GC bd list ')" -eq 4 ]; then ok "ONE bd read per distinct name (alias == name is read once, plus the session_name): 4 reads for 2 sessions"; else bad "bd reads are not one per distinct name: $SPY_LOG"; fi
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

for m in fail text object empty; do
  world_new; sess gastown/refinery gastown/witness
  beads gastown/refinery '[{"id":"b1","updated_at":"2026-11-12T10:00:00Z"}]'; beads gastown/witness '[{"id":"w1","updated_at":"2026-11-12T12:00:00Z"}]'
  fault_bd "$(sn_of gastown/refinery)" "$m"
  run_block
  if [ "$RC" -eq 0 ] && [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}NAO-SEI${TAB}NAO-SEI" ]; then ok "session_name read '$m' (the name read answered with 1 bead): NAO-SEI, not a partial A=1"; else bad "session_name read '$m': refinery line [$(line_of gastown/refinery)] (exit $RC)"; fi
  if [ "$(line_of gastown/witness)" = "gastown/witness${TAB}1${TAB}2026-11-12T12:00:00Z" ]; then ok "session_name read '$m': the other session's line is unaffected"; else bad "session_name read '$m': witness line [$(line_of gastown/witness)]"; fi
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
if printf '%s' "$DESC" | grep -q -F 'cannot happen'; then bad "the step text still promises something 'cannot happen' (an absolute the code has to keep)"; else ok "the step text makes no 'cannot happen' promise"; fi

# ── G ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case G: production shape (a pool instance's agent_name is not its name)"
world_new
sess_raw '{"id":"ga-k1","name":"kimi-worker-remote-1","alias":"kimi-worker-remote-1","session_name":"kimi-worker-remote-gawisp9","agent_name":"kimi-worker-remote","state":"active"}' \
         '{"id":"ga-k2","name":"kimi-worker-remote-2","alias":"kimi-worker-remote-2","session_name":"kimi-worker-remote-gawispa","agent_name":"kimi-worker-remote","state":"active"}'
beads kimi-worker-remote-1 '[{"id":"k1","updated_at":"2026-11-12T09:00:00Z"}]'
beads kimi-worker-remote-gawispa '[{"id":"k2","updated_at":"2026-11-12T10:00:00Z"},{"id":"k3","updated_at":"2026-11-12T10:30:00Z"}]'
run_block
if [ "$(line_of kimi-worker-remote-1)" = "kimi-worker-remote-1${TAB}1${TAB}2026-11-12T09:00:00Z" ]; then ok "the beads under the instance's name are counted for that instance"; else bad "instance 1 line: [$(line_of kimi-worker-remote-1)]"; fi
if [ "$(line_of kimi-worker-remote-2)" = "kimi-worker-remote-2${TAB}2${TAB}2026-11-12T10:30:00Z" ]; then ok "two instances of one agent_name are two lines (not folded), the second found by its session_name"; else bad "instance 2 line: [$(line_of kimi-worker-remote-2)]"; fi
if [ "$(spy_n '--assignee=kimi-worker-remote --json')" -eq 0 ]; then ok "agent_name is never used as the assignee (a real 0 for the wrong key)"; else bad "the block queried by agent_name: $SPY_LOG"; fi

# ── H ─────────────────────────────────────────────────────────────────────────
echo ""; echo "Case H: sessions the list returns without a readable identity"
world_new; sess_raw '{"state":"active"}' '{"id":"x1","agent_name":"only-agent-name","state":"active"}'
run_block
if [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c "${TAB}NAO-SEI${TAB}NAO-SEI\$")" -eq 2 ] && ! printf '%s\n' "$OUT" | grep -q '^0 active sessions'; then ok "two sessions with no alias/name/session_name: TWO NAO-SEI lines, never '0 active sessions'"; else bad "identity-less sessions: out [$OUT]"; fi
if [ "$(spy_n '^GC bd ')" -eq 0 ]; then ok "no bd call for a session whose identity is unknown"; else bad "bd called for an unknown identity: $SPY_LOG"; fi
world_new; sess gastown/refinery; beads gastown/refinery '[{"id":"b1","updated_at":"2026-11-12T10:00:00Z"}]'
sess_raw "$(jq -c '.sessions[0]' "$W/sessions.json")" '{"name":"","alias":null,"session_name":"","state":"active"}'
run_block
if [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}1${TAB}2026-11-12T10:00:00Z" ] && [ "$(printf '%s\n' "$OUT" | grep -c "NAO-SEI${TAB}NAO-SEI")" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 2 ]; then ok "one readable + one identity-less (empty/null names): the real line AND a NAO-SEI line, nothing vanishes"; else bad "partial identities: out [$OUT]"; fi
world_new; sess_raw '{"name":"gastown/refinery","state":"active"}'; beads gastown/refinery '[{"id":"b1","updated_at":"2026-11-12T10:00:00Z"}]'
run_block
if [ "$(line_of gastown/refinery)" = "gastown/refinery${TAB}1${TAB}2026-11-12T10:00:00Z" ]; then ok "a session with only a name is read under that name (no agent_name needed)"; else bad "name-only session: out [$OUT]"; fi
world_new; sess_raw '"just-a-string"'
run_block
if [ "$OUT" = "NAO-SEI${TAB}NAO-SEI${TAB}NAO-SEI" ] && [ "$(spy_n '^GC bd ')" -eq 0 ]; then ok "a session element that is not an object: the list is unreadable: ONE NAO-SEI line, no bd call"; else bad "non-object element: out [$OUT]"; fi

echo ""
echo "== deacon-queue-starvation-three-states.selftest: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
