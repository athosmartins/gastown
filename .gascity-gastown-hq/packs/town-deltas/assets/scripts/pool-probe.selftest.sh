#!/usr/bin/env bash
# pool-probe.selftest.sh — ga-witezg (P0).
#
# Proves scripts/pool-probe.sh is the SAME probe the engine renders as the dog's Step 1c, not a look-alike.
# The engine's own text (pool-probe.golden-1c.txt: the exact `sh -c '...' -- gastown.dog` line, copied from
# `gc prime`) and the script are run against the same fixtures behind a fake `bd`, and for every scenario
# BOTH the stdout AND the argv of every bd call (flags and order) must be identical. Each scenario also
# pins WHAT the golden answers, so "both printed []" cannot pass a check that was meant to select a bead.
# The exit code and stderr are compared too (ga-iu0ms2): equal to the engine's and EMPTY, except in the few
# scenarios where the script deliberately says more than the engine's probe — "could not tell" must not
# read as "no work" — and there the expected exit code and stderr are pinned explicitly (WANT_RC/WANT_ERR).
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
GOOD_LIB="$SELF_DIR/disk-headroom-lib.sh"

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
# The real bd talks on stderr even when it works (e.g. "Warning: .../.beads has permissions 0755"). If the
# script ever lets that reach the dog, a clean run would look like a failing one — so the fake does it too.
echo "Warning: fake bd noise on stderr (the script must keep this away from the dog)" >&2
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)   key=tier1 ;;
  "ready --metadata-field gc.run_target="*)  key=legacy ;;
  "list --parent "*)                         key="children-$3" ;;
  "query --json "*)                          key=ephemeral ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
[ -f "$BD_FIX/$key.fail" ] && exit 1
# --limit=N (ga-nyug12): read off argv only for the scenarios that ask for it. $key.honour-limit makes the fake cut the
# fixture to N like the real bd (0 = unlimited); $key.limit0.fail / $key.limit0.raw script the answer to the unlimited call.
lim=""; for a in "$@"; do case "$a" in --limit=*) lim="${a#--limit=}" ;; esac; done
if [ "$lim" = 0 ]; then
  [ -f "$BD_FIX/$key.limit0.fail" ] && exit 1
  [ -f "$BD_FIX/$key.limit0.raw" ] && { cat "$BD_FIX/$key.limit0.raw"; exit 0; }
fi
if [ -f "$BD_FIX/$key.raw" ]; then cat "$BD_FIX/$key.raw"
elif [ -f "$BD_FIX/$key.json" ]; then
  if [ -f "$BD_FIX/$key.honour-limit" ] && [ -n "$lim" ]; then jq -c --argjson n "$lim" 'if $n > 0 then .[0:$n] else . end' "$BD_FIX/$key.json"
  else cat "$BD_FIX/$key.json"; fi
else printf '[]'; fi
EOF
chmod +x "$FAKE/bd"

reset_fix() { rm -f "$FIX"/*; }

# run_both <name> <expected-ids-or-"-"> [target...]   (ORIGIN env var picks GC_SESSION_ORIGIN)
# Unless told otherwise the script must exit like the engine's probe and print nothing on stderr. A scenario
# where it deliberately says more sets, for that one call: WANT_RC = the script's exit code, WANT_ERR = an
# extended regex its stderr must match (both are consumed by the call).
ORIGIN=ephemeral
WANT_RC=""; WANT_ERR=""
run_both() {
  local name="$1" want="$2"; shift 2
  local want_rc="$WANT_RC" want_err="$WANT_ERR"; WANT_RC=""; WANT_ERR=""
  : > "$TMP/gold.log"; : > "$TMP/mine.log"
  local g m g_rc m_rc
  g="$(BD_LOG="$TMP/gold.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN="$ORIGIN" sh -c "$body" -- "$@" 2>"$TMP/gold.err")"; g_rc=$?
  m="$(BD_LOG="$TMP/mine.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN="$ORIGIN" DISK_FREE_OVERRIDE_MB=100000 POOL_PROBE_LOG="$TMP/pp.log" sh "$PROBE" "$@" 2>"$TMP/mine.err")"; m_rc=$?
  local gids
  gids="$(printf '%s' "$g" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ -z "$g" ] && gids="(no output)"
  [ "$gids" = "" ] && gids="-"
  eq "$name: the engine's probe answers" "$gids" "$want"
  if [ "$g" = "$m" ]; then ok "$name: stdout identical"; else bad "$name: stdout differs — engine [$g] vs script [$m]"; fi
  if cmp -s "$TMP/gold.log" "$TMP/mine.log"; then ok "$name: bd calls identical ($(wc -l < "$TMP/gold.log" | tr -d ' ') call(s), same flags, same order)"
  else bad "$name: bd calls differ"; diff <(tr '\037' ' ' < "$TMP/gold.log") <(tr '\037' ' ' < "$TMP/mine.log") | sed 's/^/      /' | head -12; fi
  if [ -z "$want_rc" ]; then
    if [ "$g_rc" = "$m_rc" ]; then ok "$name: exit code identical (=$m_rc)"; else bad "$name: exit code differs — engine $g_rc vs script $m_rc"; fi
  else
    eq "$name: the script's exit code (deliberately not the engine's $g_rc)" "$m_rc" "$want_rc"
  fi
  if [ -z "$want_err" ]; then
    if [ ! -s "$TMP/mine.err" ]; then ok "$name: nothing on stderr"; else bad "$name: unexpected stderr: $(head -c 300 "$TMP/mine.err")"; fi
  else
    if grep -Eq "$want_err" "$TMP/mine.err"; then ok "$name: stderr says it (/$want_err/)"; else bad "$name: stderr lacks /$want_err/ — got: $(head -c 300 "$TMP/mine.err")"; fi
  fi
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
WANT_ERR='unreadable answer for the children of molecule M3' run_both "molecule: live child dropped, empty kept" "m-empty" gastown.dog
echo '[{"id":"child"}]' > "$FIX/children-M2.json"
WANT_ERR='unreadable answer for the children of molecule M3' run_both "molecule: unreadable answer is kept" "m-garbage" gastown.dog
printf '[{"id":"child"}]' > "$FIX/children-M3.json"; rm -f "$FIX/children-M3.raw"
WANT_ERR='unreadable answer for the children of molecule M4' run_both "molecule: '[...]' with a live child dropped; '[oops' kept" "m-bracket" gastown.dog
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
WANT_RC=2 WANT_ERR='no <target> given' run_both "no target -> [] on stdout, a line on stderr, exit 2, no bd call" "-"
if [ ! -s "$TMP/mine.log" ]; then ok "no target: the script made no bd call"; else bad "no target: the script called bd"; fi
touch "$FIX/tier1.fail"
WANT_RC=3 WANT_ERR='tier\(s\) 1 unreadable' run_both "bd ready failing -> [] but SAYS tier 1 was unreadable (exit 3)" "-" gastown.dog
reset_fix; printf 'not json at all' > "$FIX/tier1.raw"
WANT_RC=3 WANT_ERR='tier\(s\) 1 unreadable' run_both "tier 1 answer is not JSON -> [] but says so (exit 3)" "-" gastown.dog
reset_fix; touch "$FIX/ephemeral.fail"
WANT_RC=3 WANT_ERR='tier\(s\) 3 unreadable' run_both "bd query failing -> [] but says tier 3 was unreadable (exit 3)" "-" gastown.dog
reset_fix; printf 'garbage' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='tier\(s\) 3 unreadable' run_both "bd query answer is not JSON -> [] but says so (exit 3)" "-" gastown.dog
# ga-lxm9se: the shape "unreadable" really had. Not garbage: a well-formed answer with ONE raw control byte (0x08) inside a string,
# which is what a quoted `\b` run through `echo -e` left in two mail wisps. jq refuses the whole document, so the bead that is waiting
# is invisible, and the engine's own probe turns that into `[]` = "no work". The script must say it could not read.
reset_fix; printf '[{"id":"t1-bs","updated_at":"2026-01-01T00:00:00Z","description":"the regex \010 here","labels":[]}]' > "$FIX/tier1.raw"
WANT_RC=3 WANT_ERR='tier\(s\) 1 unreadable' run_both "tier 1: a raw 0x08 inside a string -> [] but says tier 1 was unreadable (exit 3), never a silent no-work" "-" gastown.dog
reset_fix; printf '[{"id":"lg-bs","description":"the regex \010 here","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]}]' > "$FIX/legacy.raw"
WANT_RC=3 WANT_ERR='tier\(s\) 2 unreadable' run_both "tier 2: a raw 0x08 inside a string -> [] but says tier 2 was unreadable (exit 3)" "-" gastown.dog
reset_fix; printf '[{"id":"e-bs","created_at":"2026-01-01T00:00:00Z","description":"the regex \010 here","metadata":{"gc.routed_to":"gastown.dog"},"labels":[]}]' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='tier\(s\) 3 unreadable' run_both "tier 3: a raw 0x08 inside a string -> [] but says tier 3 was unreadable (exit 3)" "-" gastown.dog
# the control: the same beads with the byte ESCAPED (\b in JSON, what bd itself writes) are read and picked as usual
reset_fix; printf '%s' '[{"id":"e-bs","created_at":"2026-01-01T00:00:00Z","description":"the regex \b here","metadata":{"gc.routed_to":"gastown.dog"},"labels":[]}]' > "$FIX/ephemeral.json"
run_both "control: the same bead with the byte escaped (\\b in the JSON) is picked, nothing on stderr" "e-bs" gastown.dog
reset_fix
echo '[{"id":"m-fail","updated_at":"2026-01-01T00:00:00Z","metadata":{"molecule_id":"M5"},"labels":[]}]' > "$FIX/tier1.json"
touch "$FIX/children-M5.fail"
WANT_ERR='could not read the children of molecule M5 \(bd exit 1\)' run_both "molecule lookup failing keeps the bead (as the engine does) and says so" "m-fail" gastown.dog
reset_fix; touch "$FIX/tier1.fail"
echo '[{"id":"lg-late","metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"},"labels":[]}]' > "$FIX/legacy.json"
run_both "a later tier still answers when tier 1 is unreadable (work was found: nothing to warn about)" "lg-late" gastown.dog
reset_fix; touch "$FIX/tier1.fail" "$FIX/legacy.fail" "$FIX/ephemeral.fail"
WANT_RC=3 WANT_ERR='tier\(s\) 1 2 3 unreadable' run_both "every tier unreadable names all three (exit 3)" "-" gastown.dog

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

echo "== 11. ga-vln2py: free disk under the floor -> tier 1 holds back new STORIES; formula work (molecules, steps, gc.kind) and tiers 2/3 keep flowing"
# The engine's probe knows nothing of disks, so these run the script alone. dprobe <disk> [VAR=val...] -> D_OUT D_RC D_ERR.
dprobe() {
  local disk="$1"; shift
  : > "$TMP/pp.log"
  D_OUT="$(env BD_LOG="$TMP/disk.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN=ephemeral DISK_FREE_OVERRIDE_MB="$disk" POOL_PROBE_LOG="$TMP/pp.log" "$@" sh "${DPROBE:-$PROBE}" gastown.dog 2>"$TMP/disk.err" </dev/null)"; D_RC=$?
  D_ERR="$(cat "$TMP/disk.err")"
  D_IDS="$(printf '%s' "$D_OUT" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"; [ "$D_IDS" = "" ] && D_IDS="-"
}
reset_fix
cat > "$FIX/tier1.json" <<'EOF'
[
 {"id":"st-old","issue_type":"bug","updated_at":"2026-01-01T00:00:00Z","labels":["story:approved"],"metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"wf-new","issue_type":"task","updated_at":"2026-01-05T00:00:00Z","labels":["order-run:digest-generate"],"metadata":{"gc.routed_to":"gastown.dog","gc.kind":"workflow","gc.pool_demand":"order"}}
]
EOF
dprobe 100000;  eq "roomy disk: the oldest bead (a story) is handed out, as before" "$D_IDS" "st-old"
dprobe 5120;    eq "exactly the floor (5120 MB) is not low" "$D_IDS" "st-old"
dprobe 5119;    eq "one MB under the floor: the story is held back, the workflow bead flows" "$D_IDS" "wf-new"
eq "…without a word on stderr (a hold is an answer, not a doubt)" "$D_ERR" ""
eq "…and exit 0" "$D_RC" "0"
grep -q 'held back 1 new story' "$TMP/pp.log" && ok "the hold is on the record in the pool-probe log" || bad "no 'held back 1 new story' line in the pool-probe log"
dprobe 3000 DISK_HEADROOM_ENABLED=0; eq "kill switch DISK_HEADROOM_ENABLED=0 -> as before even on a low reading" "$D_IDS" "st-old"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
dprobe 3000
eq "only stories waiting + low disk: []" "$D_OUT" "[]"
eq "…exit 0 and silent: a real 'nothing for you', the dog drains" "$D_RC:$D_ERR" "0:"
cat > "$FIX/legacy.json" <<'EOF'
[{"id":"lg-1","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.run_target":"gastown.dog","gc.kind":"workflow"}}]
EOF
dprobe 3000;    eq "low disk: tier 2 (legacy workflow) still answers when tier 1 has only stories" "$D_IDS" "lg-1"
rm -f "$FIX/legacy.json"

# The SHAPES of the real dog beads, copied from live ones on 17/10 (the gate measured 1683 of them): on a low disk the
# order molecule / step of the stale-db cleanup carry NO gc.kind and must still flow; only a bead of a story type with
# none of the formula marks is held; a type the classifier does not know flows (it leans to let work through).
# expect|id|issue_type ("-" = no such key)|labels|metadata
SHAPE_TABLE='flow|mol-stale|molecule|["order-run:mol-dog-stale-db"]|{"gc.pool_demand":"order","gc.routed_to":"gastown.dog","gc.var.max_orphans_for_sql":"20"}
flow|step-stale|step|[]|{"gc.routed_to":"gastown.dog","gc.step_ref":"mol-dog-stale-db.cleanup"}
flow|task-step|task|[]|{"gc.root_bead_id":"ga-uctnin","gc.routed_to":"gastown.dog","gc.step_ref":"mol-digest-generate.collect-data"}
flow|digest|task|["order-run:digest-generate"]|{"gc.formula_contract":"graph.v2","gc.kind":"workflow","gc.pool_demand":"order","gc.routed_to":"gastown.dog"}
flow|kind-only|task|[]|{"gc.kind":"workflow","gc.routed_to":"gastown.dog"}
flow|order-only|task|[]|{"gc.pool_demand":"order","gc.routed_to":"gastown.dog"}
flow|unknown-type|wisp|[]|{"gc.routed_to":"gastown.dog"}
flow|empty-type||[]|{"gc.routed_to":"gastown.dog"}
flow|no-type-key|-|[]|{"gc.routed_to":"gastown.dog"}
hold|story-bug|bug|["story:approved"]|{"gc.routed_to":"gastown.dog"}
hold|story-task|task|["ctx:ready","story:approved"]|{"gc.routed_to":"gastown.dog"}
hold|pilot-sling|task|[]|{"gc.routed_to":"gastown.dog","pilot.sling_for":"dc-4v71"}
hold|story-feature|feature|[]|{"gc.routed_to":"gastown.dog"}
hold|story-chore|chore|[]|{"gc.routed_to":"gastown.dog"}
hold|story-epic|epic|[]|{"gc.routed_to":"gastown.dog"}
hold|story-spike|spike|[]|{"gc.routed_to":"gastown.dog"}'
# shape_misses <lib> -> the ids whose answer at 3000 MB was not the expected one (empty = every shape went where it should)
shape_misses() {
  local miss="" expect id type labels meta tj want
  while IFS='|' read -r expect id type labels meta; do
    [ -n "$id" ] || continue
    if [ "$type" = "-" ]; then tj=""; else tj="\"issue_type\":\"$type\","; fi
    printf '[{"id":"%s",%s"updated_at":"2026-01-01T00:00:00Z","labels":%s,"metadata":%s}]' "$id" "$tj" "$labels" "$meta" > "$FIX/tier1.json"
    dprobe 3000 POOL_PROBE_DISK_LIB="$1"
    if [ "$expect" = flow ]; then want="$id"; else want="-"; fi
    [ "$D_IDS:$D_RC" = "$want:0" ] || miss="$miss $id"
  done <<EOF
$SHAPE_TABLE
EOF
  printf '%s' "$miss"
}
miss="$(shape_misses "$GOOD_LIB")"
eq "low disk, real dog shapes: the stale-db molecule/step and every formula mark flow, every story type is held (misses: none)" "${miss:-none}" "none"
# mutants of the classifier (the lib): each must send at least one real shape the wrong way
mutate_lib() { # <out> <literal old> <literal new>: the lib with ONE literal replaced (no such literal = not a mutant = loud)
  python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[3])==1, "mutation site not found"; open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' "${MUT_SRC:-$GOOD_LIB}" "$1" "$2" "$3" \
    || bad "mutation site not found in the lib: $2"
}
TYPE_CLAUSE='(((.issue_type // "") as $t | ["task","bug","feature","chore","epic","spike"] | any(. == $t)) | not) or '
# kindonly = the rule this slice first shipped (anything without a gc.kind is a story): three clauses gone
mutate_lib "$TMP/lib-m-k1.sh" "$TYPE_CLAUSE" ''
MUT_SRC="$TMP/lib-m-k1.sh" mutate_lib "$TMP/lib-m-k2.sh" ' or ((.metadata["gc.step_ref"] // "") != "")' ''
MUT_SRC="$TMP/lib-m-k2.sh" mutate_lib "$TMP/lib-m-kindonly.sh" ' or ((.metadata["gc.pool_demand"] // "") != "")' ''
mutate_lib "$TMP/lib-m-notype.sh" "$TYPE_CLAUSE" ''
mutate_lib "$TMP/lib-m-nostep.sh" ' or ((.metadata["gc.step_ref"] // "") != "")' ''
mutate_lib "$TMP/lib-m-noorder.sh" ' or ((.metadata["gc.pool_demand"] // "") != "")' ''
mutate_lib "$TMP/lib-m-nokind.sh" ' or ((.metadata["gc.kind"] // "") != "")' ''
mutate_lib "$TMP/lib-m-nospike.sh" '"epic","spike"]' '"epic"]'
for m in kindonly notype nostep noorder nokind nospike; do
  miss="$(shape_misses "$TMP/lib-m-$m.sh")"
  [ -n "$miss" ] && ok "classifier mutant '$m' is killed (sends$miss the wrong way)" || bad "classifier mutant '$m' SURVIVED: every real shape still went where it should"
done
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
dprobe garbage; eq "unreadable disk: fail OPEN, the story is handed out" "$D_IDS" "st-only"
grep -q 'free disk unreadable' "$TMP/pp.log" && ok "…and the blind reading is on the record (not the same as 'disk fine')" || bad "unreadable disk left no line in the pool-probe log"
dprobe 3000 POOL_PROBE_DISK_LIB=/nonexistent-lib; eq "lib missing: unknown -> fail OPEN (the story is handed out)" "$D_IDS" "st-only"
printf 'disk_headroom_state() { if then fi\n' > "$TMP/corrupt-lib.sh"
dprobe 3000 POOL_PROBE_DISK_LIB="$TMP/corrupt-lib.sh"; eq "lib with a syntax error: the probe survives and fails OPEN" "$D_IDS:$D_RC" "st-only:0"
printf 'DISK_NEW_WORK_MIN_MB=1\ndisk_headroom_state() { printf low; }\n' > "$TMP/nohold-lib.sh"
dprobe 3000 POOL_PROBE_DISK_LIB="$TMP/nohold-lib.sh"
eq "low but the hold text is unavailable: nothing handed out, tier 1 flagged, exit 3 (loud, not 'no work')" "$D_OUT:$D_RC" "[]:3"
case "$D_ERR" in *"tier(s) 1 unreadable"*) ok "…and stderr says tier 1 was unreadable" ;; *) bad "…stderr lacks 'tier(s) 1 unreadable': $D_ERR" ;; esac
# a bead the classifier cannot read (metadata is not an object): the hold program fails -> the same loud inert answer, never a story handed out
printf '[{"id":"odd","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":"not-an-object"}]' > "$FIX/tier1.json"
dprobe 3000 POOL_PROBE_DISK_LIB="$GOOD_LIB"
eq "low disk + a bead the hold program cannot read: nothing handed out, tier 1 flagged, exit 3" "$D_OUT:$D_RC" "[]:3"
grep -q 'hold could not be applied' "$TMP/pp.log" && ok "…and the failed hold is on the record" || bad "the failed hold left no line in the pool-probe log"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
# ga-nyug12 (item 1): the hold runs AFTER the engine's --limit=20 window. 20 stories older than a formula bead fill the window,
# the hold empties it, and tier 1 used to answer `[]` exit 0 ("drain") while formula work waited outside the window. Now: low
# disk + a full window + the hold removed everything -> ONE unlimited refetch (--limit=0), the same veto and hold over the whole
# list; a refetch that cannot be read is tier 1 unreadable (exit 3), never "no work". The fake bd honours --limit here.
mk_window() { # <stories> <formula 0|1> [story label] -> tier1.json, oldest first like `bd --sort oldest`, cut by --limit
  jq -n -c --argjson s "$1" --argjson f "$2" --arg lbl "${3:-}" '
    [range(0; $s) | . as $i | ("2026-01-01T00:" + ($i | tostring | if length < 2 then "0" + . else . end) + ":00Z") as $ts
      | {id: ("st-" + ($i + 100 | tostring)), issue_type: "task", created_at: $ts, updated_at: $ts,
         labels: (if $lbl == "" then [] else [$lbl] end), metadata: {"gc.routed_to": "gastown.dog"}}]
    + (if $f == 1 then [{id: "mol-late", issue_type: "molecule", created_at: "2026-01-02T00:00:00Z", updated_at: "2026-01-02T00:00:00Z",
         labels: ["order-run:mol-dog-stale-db"], metadata: {"gc.routed_to": "gastown.dog", "gc.pool_demand": "order"}}] else [] end)' > "$FIX/tier1.json"
  : > "$FIX/tier1.honour-limit"
}
t1_calls() { grep -a 'gc\.routed_to=gastown\.dog' "$TMP/disk.log" | wc -l | tr -d ' '; }
t1_unlimited() { grep -a 'gc\.routed_to=gastown\.dog' "$TMP/disk.log" | grep -a -c -e '--limit=0' || true; }
win() { : > "$TMP/disk.log"; dprobe "$@"; } # a dprobe with a fresh bd log
reset_fix; mk_window 20 1
win 3000
eq "window full of stories + a formula bead outside it, low disk: the formula bead is handed out (not [])" "$D_IDS:$D_RC" "mol-late:0"
eq "…silent on stderr, and tier 1 was asked twice: the 20-window, then ONE unlimited refetch" "$D_ERR|$(t1_calls)|$(t1_unlimited)" "|2|1"
grep -q 'refetch' "$TMP/pp.log" && ok "…and the refetch is on the record in the pool-probe log" || bad "the refetch left no line in the pool-probe log"
win 100000
eq "same window, roomy disk: the oldest story as before, one tier-1 call, no refetch" "$D_IDS|$(t1_calls)|$(t1_unlimited)" "st-100|1|0"
mk_window 19 1; win 3000
eq "window full (19 stories + the formula bead) but the hold left a bead: no refetch" "$D_IDS|$(t1_calls)|$(t1_unlimited)" "mol-late|1|0"
mk_window 5 0; win 3000
eq "window NOT full, hold empties it: [] exit 0 silent, no refetch (nothing waits outside)" "$D_OUT:$D_RC:$D_ERR|$(t1_calls)" "[]:0:|1"
mk_window 20 0; win 3000
eq "window full of stories and nothing else exists: the refetch finds the same, a real [] exit 0 silent" "$D_OUT:$D_RC:$D_ERR|$(t1_calls)|$(t1_unlimited)" "[]:0:|2|1"
mk_window 25 0; win 3000
eq "25 stories, no formula bead: [] exit 0, still ONE refetch (no loop)" "$D_OUT:$D_RC|$(t1_calls)|$(t1_unlimited)" "[]:0|2|1"
mk_window 20 1 "pool:refused"; win 3000
eq "window full but the VETO emptied it (not the hold): as the engine answers, [] and no refetch" "$D_OUT:$D_RC|$(t1_calls)" "[]:0|1"
mk_window 20 1; : > "$FIX/tier1.limit0.fail"; win 3000
eq "refetch fails: [] exit 3, never a quiet drain" "$D_OUT:$D_RC" "[]:3"
case "$D_ERR" in *"tier(s) 1 unreadable"*) ok "…and stderr says tier 1 was unreadable" ;; *) bad "…stderr lacks 'tier(s) 1 unreadable': $D_ERR" ;; esac
rm -f "$FIX/tier1.limit0.fail"; printf 'not json' > "$FIX/tier1.limit0.raw"; win 3000
eq "refetch answers something that is not JSON: [] exit 3" "$D_OUT:$D_RC" "[]:3"
rm -f "$FIX/tier1.limit0.raw"
# mutants of the refetch: each must flip one of the answers above (a mutant that changes nothing is itself a failure)
refetch_mutant() { # <name> <sed expr> <scenario: ok|fail> <want "ids:rc|calls" that the CORRECT script does NOT give>
  sed "$2" "$PROBE" > "$TMP/pp-m-$1.sh"
  cmp -s "$PROBE" "$TMP/pp-m-$1.sh" && { bad "refetch mutant '$1' did not change the script"; return; }
  rm -f "$FIX/tier1.limit0.fail"
  case "$3" in
    ok)     mk_window 20 1 ;;
    veto)   mk_window 20 1 "pool:refused" ;;
    fail)   mk_window 20 1; : > "$FIX/tier1.limit0.fail" ;;
  esac
  DPROBE="$TMP/pp-m-$1.sh" win 3000 POOL_PROBE_DISK_LIB="$GOOD_LIB"
  [ "$D_IDS:$D_RC|$(t1_calls)" != "$4" ] && ok "refetch mutant '$1' is killed (answers $D_IDS:$D_RC after $(t1_calls) tier-1 call(s))" || bad "refetch mutant '$1' SURVIVED"
}
refetch_mutant never-refetches 's/-ge 20 \]; then$/-ge 99999 ]; then/' ok "mol-late:0|2"
refetch_mutant ignores-the-refetch 's/^        t1_kept="\$t1_all_held"$/        t1_kept="$t1_kept"/' ok "mol-late:0|2"
refetch_mutant unreadable-refetch-is-nothing 's/^        mark 1; t1_kept="\[\]"$/        t1_kept="[]"/' fail "-:3|2"
refetch_mutant refetches-after-a-veto 's/\[ "\${n_before:-0}" -gt 0 \] \&\& //' veto "-:0|1"
rm -f "$FIX/tier1.limit0.fail"
cat > "$FIX/tier1.json" <<'EOF'
[{"id":"st-only","issue_type":"task","updated_at":"2026-01-01T00:00:00Z","labels":[],"metadata":{"gc.routed_to":"gastown.dog"}}]
EOF
rm -f "$FIX/tier1.honour-limit"
# mutants of the script: each must change at least one answer above (a hold that never fires, a hold that fails closed)
sed 's/\[ "\$disk_state" = low \]; then$/[ "$disk_state" = never ]; then/' "$PROBE" > "$TMP/pp-nohold.sh"
cmp -s "$PROBE" "$TMP/pp-nohold.sh" && bad "mutant 'hold never fires' did not change the script"
cp "$PROBE" "$TMP/pp-hold-copy.sh"
DPROBE="$TMP/pp-nohold.sh" POOL_PROBE_DISK_LIB="$GOOD_LIB" dprobe 3000 POOL_PROBE_DISK_LIB="$GOOD_LIB"
[ "$D_IDS" = "st-only" ] && ok "mutant 'hold never fires' is killed: the low-disk answer ([]) differs" || bad "mutant 'hold never fires' survived"
sed 's/^case "\$disk_state" in ok|low) ;; \*) disk_state=unknown ;; esac$/case "$disk_state" in ok|low) ;; *) disk_state=low ;; esac/' "$PROBE" > "$TMP/pp-failclosed.sh"
cmp -s "$PROBE" "$TMP/pp-failclosed.sh" && bad "mutant 'unknown becomes low' did not change the script"
DPROBE="$TMP/pp-failclosed.sh" dprobe garbage POOL_PROBE_DISK_LIB="$GOOD_LIB"
[ "$D_IDS" != "st-only" ] && ok "mutant 'unknown becomes low' is killed: the fail-open answer differs" || bad "mutant 'unknown becomes low' survived"
DPROBE=""
reset_fix

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
