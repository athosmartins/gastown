#!/usr/bin/env bash
# pool-probe.selftest.sh — ga-witezg (P0).
#
# Proves scripts/pool-probe.sh is the SAME probe the engine renders as the dog's Step 1c, not a look-alike.
# The engine's own text (pool-probe.golden-1c.txt: the exact `sh -c '...' -- gastown.dog` line, copied from
# `gc prime`) and the script are run against the same fixtures behind a fake `bd`, and for every scenario
# BOTH the stdout AND the argv of every bd call (flags and order) must be identical. Each scenario also
# pins WHAT the golden answers, so "both printed []" cannot pass a check that was meant to select a bead.
# Needs bash, jq, python3, sh. Exit 0 iff every check holds.
#   --live   also compares the golden with what `gc prime` renders NOW (drift check; run after an engine
#            window). Not in the default run: it needs a live gc and a dog-shaped environment. A gc that
#            cannot be read is a FAIL in this mode, never a pass — "could not compare" is not "equal".
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${PP_PROBE_UNDER_TEST:-$SELF_DIR/pool-probe.sh}"        # override = mutation checks
GOLDEN="${PP_GOLDEN:-$SELF_DIR/pool-probe.golden-1c.txt}"
LIVE=0; [ "${1:-}" = "--live" ] && LIVE=1

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
[ -f "$PROBE" ] || { echo "FATAL: probe not found: $PROBE"; exit 1; }
[ -f "$GOLDEN" ] || { echo "FATAL: golden not found: $GOLDEN"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-selftest.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX"

# ---- the engine's probe: unwrap `sh -c '<body>' -- <target>` exactly as the shell would ----------------
golden_line="$(cat "$GOLDEN")"
case "$golden_line" in
  "sh -c '"*"' -- "*) ;;
  *) echo "FATAL: golden is not a \`sh -c '...' -- <target>\` line"; exit 1 ;;
esac
body="${golden_line#"sh -c '"}"
body="${body%"' -- "*}"
body="$(printf '%s' "$body" | sed "s/'\\\\''/'/g")"            # the shell's own '\'' -> ' unescape

# ---- a fake bd: logs its argv, answers from fixture files ----------------------------------------------
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)   key=tier1 ;;
  "ready --metadata-field gc.run_target="*)  key=legacy ;;
  "list --parent "*)                         key="children-$3" ;;
  "query --json "*)                          key=ephemeral ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
[ -f "$BD_FIX/$key.fail" ] && exit 1
if [ -f "$BD_FIX/$key.raw" ]; then cat "$BD_FIX/$key.raw"
elif [ -f "$BD_FIX/$key.json" ]; then cat "$BD_FIX/$key.json"
else printf '[]'; fi
EOF
chmod +x "$FAKE/bd"

reset_fix() { rm -f "$FIX"/*; }

# run_both <name> <expected-ids-or-"-"> [target...]   (ORIGIN env var picks GC_SESSION_ORIGIN)
ORIGIN=ephemeral
run_both() {
  local name="$1" want="$2"; shift 2
  : > "$TMP/gold.log"; : > "$TMP/mine.log"
  local g m
  g="$(BD_LOG="$TMP/gold.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN="$ORIGIN" sh -c "$body" -- "$@" 2>/dev/null)"
  m="$(BD_LOG="$TMP/mine.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN="$ORIGIN" sh "$PROBE" "$@" 2>/dev/null)"
  local gids
  gids="$(printf '%s' "$g" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ -z "$g" ] && gids="(no output)"
  [ "$gids" = "" ] && gids="-"
  eq "$name: the engine's probe answers" "$gids" "$want"
  if [ "$g" = "$m" ]; then ok "$name: stdout identical"; else bad "$name: stdout differs — engine [$g] vs script [$m]"; fi
  if cmp -s "$TMP/gold.log" "$TMP/mine.log"; then ok "$name: bd calls identical ($(wc -l < "$TMP/gold.log" | tr -d ' ') call(s), same flags, same order)"
  else bad "$name: bd calls differ"; diff <(tr '\037' ' ' < "$TMP/gold.log") <(tr '\037' ' ' < "$TMP/mine.log") | sed 's/^/      /' | head -12; fi
}

FUT=4102444800   # 2100-01-01
PAST=1000000000  # 2001

echo "== 1. nothing anywhere -> [] (and the three tiers are probed, in order)"
reset_fix
run_both "empty" "-" gastown.dog
tier_order="$(awk -F $'\037' '{print $1" "$3}' "$TMP/mine.log" | tr '\n' '|')"
if [ "$tier_order" = "ready gc.routed_to=gastown.dog|ready gc.run_target=gastown.dog|query ephemeral=true AND status=open AND assignee=none|" ]; then
  ok "tier order: routed ready -> legacy run_target -> ephemeral query"; else bad "tier order unexpected: $tier_order"; fi

echo "== 2. the veto filter (each vetoed bead is OLDER than the winner, so a missed veto changes the answer)"
reset_fix
cat > "$FIX/tier1.json" <<EOF
[
 {"id":"v-refused","updated_at":"2026-01-01T00:00:01Z","labels":["pool:refused:engine-rebuild-required"]},
 {"id":"v-held","updated_at":"2026-01-01T00:00:02Z","labels":["pilot:held"]},
 {"id":"v-held-future","updated_at":"2026-01-01T00:00:03Z","labels":["pilot:held-until:$FUT"]},
 {"id":"v-epic","updated_at":"2026-01-01T00:00:04Z","title":"EPIC: migrar tudo","labels":[]},
 {"id":"v-epico","updated_at":"2026-01-01T00:00:05Z","title":"ÉPICO: v55","labels":[]},
 {"id":"v-blocked","updated_at":"2026-01-01T00:00:06Z","labels":["blocked:dependency"]},
 {"id":"v-blocked-reason","updated_at":"2026-01-01T00:00:07Z","labels":["blocked-reason:decision"]},
 {"id":"v-gate-human","updated_at":"2026-01-01T00:00:08Z","labels":["gate:needs-human-decision"]},
 {"id":"v-refused-reason","updated_at":"2026-01-01T00:00:09Z","labels":["pilot:refused-reason:children-in-flight"]},
 {"id":"v-text-veto","updated_at":"2026-01-01T00:00:10Z","labels":["pilot:text-veto-merge"]},
 {"id":"ok-hold-expired","updated_at":"2026-01-02T00:00:00Z","title":"fix the epicenter map","labels":["pilot:held-until:$PAST"]},
 {"id":"ok-newer","updated_at":"2026-01-03T00:00:00Z","labels":[]}
]
EOF
run_both "veto filter" "ok-hold-expired" gastown.dog

echo "== 3. tier 1 molecule check (live child drops a bead; unreadable answer does NOT; no molecule is kept)"
reset_fix
cat > "$FIX/tier1.json" <<'EOF'
[
 {"id":"m-live","updated_at":"2026-01-01T00:00:01Z","metadata":{"molecule_id":"M1"},"labels":[]},
 {"id":"m-empty","updated_at":"2026-01-01T00:00:02Z","metadata":{"molecule_id":"M2"},"labels":[]},
 {"id":"m-garbage","updated_at":"2026-01-01T00:00:03Z","metadata":{"molecule_id":"M3"},"labels":[]},
 {"id":"m-bracket","updated_at":"2026-01-01T00:00:04Z","metadata":{"molecule_id":"M4"},"labels":[]},
 {"id":"m-none","updated_at":"2026-01-01T00:00:05Z","labels":[]}
]
EOF
echo '[{"id":"child"}]' > "$FIX/children-M1.json"
echo '[]' > "$FIX/children-M2.json"
printf 'Error: dolt unreachable' > "$FIX/children-M3.raw"
printf '[oops' > "$FIX/children-M4.raw"
run_both "molecule: live child dropped, empty kept" "m-empty" gastown.dog
echo '[{"id":"child"}]' > "$FIX/children-M2.json"
run_both "molecule: unreadable answer is kept" "m-garbage" gastown.dog
printf '[{"id":"child"}]' > "$FIX/children-M3.json"; rm -f "$FIX/children-M3.raw"
run_both "molecule: '[...]' with a live child dropped; '[oops' kept" "m-bracket" gastown.dog
printf '[{"id":"child"}]' > "$FIX/children-M4.json"; rm -f "$FIX/children-M4.raw"
run_both "molecule: no molecule_id is always kept" "m-none" gastown.dog
reset_fix
cat > "$FIX/tier1.json" <<'EOF'
[
 {"id":"s-newer","updated_at":"2026-03-01T00:00:00Z","labels":[]},
 {"id":"s-older","updated_at":"2026-01-01T00:00:00Z","labels":[]},
 {"id":"s-created-only","created_at":"2026-02-01T00:00:00Z","labels":[]}
]
EOF
run_both "tier 1 picks the oldest updated_at (falls back to created_at)" "s-older" gastown.dog

echo "== 4. tier 2 (legacy workflow beads): only gc.routed_to-less beads, the veto filter, first one"
reset_fix
cat > "$FIX/legacy.json" <<'EOF'
[
 {"id":"lg-routed","metadata":{"gc.routed_to":"someone-else","gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]},
 {"id":"lg-veto","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":["blocked:x"]},
 {"id":"lg-ok","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]},
 {"id":"lg-ok2","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]}
]
EOF
run_both "legacy tier" "lg-ok" gastown.dog

echo "== 5. tier 3 (ephemeral store): assignee, target, epic, blocking deps, the veto filter, created_at order"
reset_fix
cat > "$FIX/ephemeral.json" <<'EOF'
[
 {"id":"e-vetoed","created_at":"2026-01-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"},"labels":["pool:refused:x"]},
 {"id":"e-assigned","created_at":"2026-01-01T00:00:01Z","assignee":"someone","metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"e-other-target","created_at":"2026-01-01T00:00:02Z","metadata":{"gc.routed_to":"someone-else"}},
 {"id":"e-epic","created_at":"2026-01-01T00:00:03Z","issue_type":"epic","metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"e-blocks-open","created_at":"2026-01-01T00:00:04Z","metadata":{"gc.routed_to":"gastown.dog"},"dependencies":[{"type":"blocks","status":"open"}]},
 {"id":"e-waits-open","created_at":"2026-01-01T00:00:05Z","metadata":{"gc.routed_to":"gastown.dog"},"dependencies":[{"dep_type":"waits-for","depends_on_status":"in_progress"}]},
 {"id":"e-cond-open","created_at":"2026-01-01T00:00:06Z","metadata":{"gc.routed_to":"gastown.dog"},"dependencies":[{"type":"conditional-blocks","status":"open"}]},
 {"id":"e-related-open","created_at":"2026-01-01T00:00:07Z","metadata":{"gc.routed_to":"gastown.dog"},"dependencies":[{"type":"related","status":"open"}]},
 {"id":"e-blocks-closed","created_at":"2026-01-01T00:00:08Z","metadata":{"gc.routed_to":"gastown.dog"},"dependencies":[{"type":"blocks","status":"closed"}]}
]
EOF
run_both "ephemeral tier" "e-related-open" gastown.dog
reset_fix
cat > "$FIX/ephemeral.json" <<'EOF'
[
 {"id":"e-legacy-run-target","created_at":"2026-01-01T00:00:00Z","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}},
 {"id":"e-legacy-not-workflow","created_at":"2025-12-31T00:00:00Z","metadata":{"gc.run_target":"gastown.dog","gc.kind":"other"}}
]
EOF
run_both "ephemeral: run_target+workflow counts, run_target without workflow does not" "e-legacy-run-target" gastown.dog
# The engine slices the ephemeral candidates to the first 20 BEFORE the veto filter, so 20 vetoed beads
# hide a valid 21st. That is a quirk of the engine's probe, not a feature — pinned because the script must
# answer exactly what the engine's probe answers.
reset_fix
jq -n '[range(0;20) | {id: ("v\(.)"), created_at: ("2026-01-01T00:00:\(if . < 10 then "0\(.)" else "\(.)" end)Z"), metadata: {"gc.routed_to": "gastown.dog"}, labels: ["pool:refused:x"]}]
       + [{id: "valid-21st", created_at: "2026-02-01T00:00:00Z", metadata: {"gc.routed_to": "gastown.dog"}}]' > "$FIX/ephemeral.json"
run_both "ephemeral: the 20-candidate slice comes before the veto filter" "-" gastown.dog

echo "== 6. tier precedence: tier 1 wins over tier 2/3, tier 2 over tier 3"
reset_fix
echo '[{"id":"t1","labels":[]}]' > "$FIX/tier1.json"
echo '[{"id":"t2","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]}]' > "$FIX/legacy.json"
echo '[{"id":"t3","created_at":"2026-01-01T00:00:00Z","metadata":{"gc.routed_to":"gastown.dog"}}]' > "$FIX/ephemeral.json"
run_both "tier 1 first" "t1" gastown.dog
rm "$FIX/tier1.json"
run_both "then tier 2" "t2" gastown.dog
rm "$FIX/legacy.json"
run_both "then tier 3" "t3" gastown.dog

echo "== 7. edges: not an ephemeral session, no target, bd failing, unreadable answers"
reset_fix
echo '[{"id":"would-match","labels":[]}]' > "$FIX/tier1.json"
ORIGIN=crew     run_both "GC_SESSION_ORIGIN=crew prints nothing and calls nothing" "(no output)" gastown.dog
ORIGIN=ephemeral
ORIGIN=         run_both "empty GC_SESSION_ORIGIN is treated like ephemeral" "would-match" gastown.dog
ORIGIN=ephemeral
run_both "no target -> [] and no bd call" "-"
if [ ! -s "$TMP/mine.log" ]; then ok "no target: the script made no bd call"; else bad "no target: the script called bd"; fi
touch "$FIX/tier1.fail"
run_both "bd ready failing -> falls through to []" "-" gastown.dog
reset_fix; printf 'not json at all' > "$FIX/tier1.raw"
run_both "tier 1 answer is not JSON -> []" "-" gastown.dog
reset_fix; touch "$FIX/ephemeral.fail"
run_both "bd query failing -> []" "-" gastown.dog
reset_fix; printf 'garbage' > "$FIX/ephemeral.raw"
run_both "bd query answer is not JSON -> []" "-" gastown.dog

echo "== 8. every long jq/bd literal in the script is verbatim in the engine's probe (typos in a clause no fixture reaches)"
if python3 -I - "$PROBE" "$body" <<'PY'
import re, sys
script = open(sys.argv[1], encoding="utf-8").read()
body = sys.argv[2]
code = "\n".join(l for l in script.splitlines() if not l.lstrip().startswith("#"))
lits = re.findall(r"'([^'\n]{20,})'", code)
# Whole literal, quotes included: a truncated program is still a substring of the original.
missing = [l for l in lits if ("'" + l + "'") not in body]
print(f"{len(lits)} literals checked")
for l in missing:
    print("NOT IN ENGINE PROBE:", l[:120])
sys.exit(1 if missing or len(lits) < 6 else 0)
PY
then ok "all single-quoted programs (>=20 chars) occur verbatim in the golden"; else bad "a literal in the script is not in the engine's probe (or fewer than 6 were found)"; fi

echo "== 9. the call the dog makes is short and has nothing the removal check could read as a removal"
if grep -E '(^|[^[:alnum:]_])(rm|rmdir|unlink|shred|truncate)([^[:alnum:]_]|$)' <(grep -v '^[[:space:]]*#' "$PROBE") >/dev/null; then bad "the script mentions a removal command"; else ok "no rm/rmdir/unlink/shred/truncate outside comments"; fi
if bash -n "$PROBE" 2>/dev/null && sh -n "$PROBE" 2>/dev/null; then ok "parses under bash -n and sh -n"; else bad "syntax error"; fi
case "$(head -1 "$PROBE")" in "#!/bin/sh") ok "POSIX sh shebang (the engine's probe ran under sh -c)";; *) bad "shebang is not #!/bin/sh";; esac

if [ "$LIVE" = 1 ]; then
  echo "== 10. --live: the golden is what the live gc renders as Step 1c today"
  live="$(gc prime 2>/dev/null | awk '/^# Step 1c/{getline; print; exit}')"
  if [ -z "$live" ]; then bad "gc prime printed no Step 1c line — cannot compare (this is a FAIL, not a pass)"
  elif [ "$live" = "$golden_line" ]; then ok "golden == live gc prime Step 1c"
  else bad "the engine's probe changed since the golden was taken — update pool-probe.golden-1c.txt AND pool-probe.sh together"; fi
else
  skip "--live drift check not requested"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
