#!/usr/bin/env bash
# pool-probe-assigned.selftest.sh — ga-ica007 (P2).
#
# Proves scripts/pool-probe-assigned.sh is the SAME probe the engine renders as the dog's Steps 1a / 1b, and that where
# it deliberately differs it says so. The engine's own text (pool-probe-assigned.golden-1a.txt / -1b.txt: the exact
# `sh -c '...'` line, copied from `gc prime`) and the script run against the same fixtures behind a fake `bd`; for every
# scenario BOTH the stdout AND the argv of every bd call (flags and order) must be identical, and each scenario pins WHAT
# the golden answers (so "both printed []" cannot pass a check meant to select a bead). Exit code and stderr are compared
# too: equal to the engine's and EMPTY, except in the scenarios where the script deliberately says more — "could not
# tell" must not read as "no work" (the point of the bead) — and there the expected rc and stderr are pinned (WANT_RC/WANT_ERR).
# The acceptance case of ga-ica007 is section 7: ONE raw 0x08 byte in a description makes the engine's text answer `[]`
# (rc 0, silent) in 1a, 1b — the script answers `[]` + stderr + rc 3.
# Needs bash, jq, python3, sh. Runs under bash 3.2 (the mini's /bin/bash) as well as 5.x. Exit 0 iff every check holds.
#   --live   also compares the goldens with what `gc prime` renders NOW (drift check; run after an engine window).
#            Not in the default run: it needs a live gc and a dog-shaped environment. A gc that cannot be read is a FAIL
#            in this mode, never a pass — "could not compare" is not "equal".
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${PA_PROBE_UNDER_TEST:-$SELF_DIR/pool-probe-assigned.sh}"      # override = mutation checks
GOLDEN_DIR="${PA_GOLDEN_DIR:-$SELF_DIR}"
LIVE=0; [ "${1:-}" = "--live" ] && LIVE=1

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 1; }
[ -f "$PROBE" ] || { echo "FATAL: probe not found: $PROBE"; exit 1; }
for s in 1a 1b; do [ -f "$GOLDEN_DIR/pool-probe-assigned.golden-$s.txt" ] || { echo "FATAL: golden not found: $GOLDEN_DIR/pool-probe-assigned.golden-$s.txt"; exit 1; }; done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-assigned-selftest.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX"
# Both the engine's wo_pick and the script's read the ordering library from here; pinned so the ordering is the real one.
export WORK_ORDER_LIB="$SELF_DIR/work-order.sh"
[ -r "$WORK_ORDER_LIB" ] || { echo "FATAL: work-order.sh not readable: $WORK_ORDER_LIB"; exit 1; }

# ---- the engine's probe: unwrap `sh -c '<body>'` exactly as the shell would ----------------------------
unwrap() {
  local line; line="$(cat "$1")"
  case "$line" in "sh -c '"*"'") ;; *) echo "FATAL: golden is not a \`sh -c '...'\` line: $1" >&2; return 1 ;; esac
  line="${line#"sh -c '"}"; line="${line%"'"}"
  printf '%s' "$line" | sed "s/'\\\\''/'/g"                       # the shell's own '\'' -> ' unescape
}
body_1a="$(unwrap "$GOLDEN_DIR/pool-probe-assigned.golden-1a.txt")" || exit 1
body_1b="$(unwrap "$GOLDEN_DIR/pool-probe-assigned.golden-1b.txt")" || exit 1

# ---- a fake bd: logs its argv, answers from fixture files ----------------------------------------------
# keys: durable (bd list / bd ready), ephemeral (bd query). A fixture `<key>.<assignee>.json` wins over `<key>.json` for the
# durable calls (the argv carries --assignee=<id>). <key>.fail = exit 1; <key>.raw = verbatim bytes; <key>.empty = rc 0, no bytes.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
echo "Warning: fake bd noise on stderr (the script must keep this away from the dog)" >&2
as=""; for a in "$@"; do case "$a" in --assignee=*) as="${a#--assignee=}" ;; esac; done
case "$1" in
  list|ready) key=durable ;;
  query)      key=ephemeral ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
[ -n "$as" ] && [ -f "$BD_FIX/$key.$as.fail" ] && exit 1
[ -f "$BD_FIX/$key.fail" ] && exit 1
[ -f "$BD_FIX/$key.empty" ] && exit 0
if [ -n "$as" ] && [ -f "$BD_FIX/$key.$as.json" ]; then cat "$BD_FIX/$key.$as.json"
elif [ -f "$BD_FIX/$key.raw" ]; then cat "$BD_FIX/$key.raw"
elif [ -f "$BD_FIX/$key.json" ]; then cat "$BD_FIX/$key.json"
else printf '[]'; fi
EOF
chmod +x "$FAKE/bd"

reset_fix() { rm -f "$FIX"/*; }

# the three identities the engine's loop walks
export_ids() { ID1="${1-ga-x1}"; ID2="${2-dog-x2}"; ID3="${3-gastown.dog-x3}"; }
export_ids

# run_both <step> <name> <expected-ids-or-"-">   (WANT_RC / WANT_ERR as in pool-probe.selftest.sh; ARG = the script's argument, default = step;
# WANT_OUT = the script's stdout when the ENGINE's answer is the very hazard - it hands out a bead cut from a non-array answer, or stops on
# garbage - so neither its stdout nor its bd calls are the reference there; the engine's answer is still pinned by <expected-ids>)
WANT_RC=""; WANT_ERR=""; ARG=""; WANT_OUT=""
run_both() {
  local step="$1" name="$2" want="$3"
  local want_rc="$WANT_RC" want_err="$WANT_ERR" arg="${ARG:-$step}" want_out="$WANT_OUT"; WANT_RC=""; WANT_ERR=""; ARG=""; WANT_OUT=""
  local body; if [ "$step" = 1a ]; then body="$body_1a"; else body="$body_1b"; fi
  : > "$TMP/gold.log"; : > "$TMP/mine.log"
  local g m g_rc m_rc
  g="$(BD_LOG="$TMP/gold.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ID="$ID1" GC_SESSION_NAME="$ID2" GC_ALIAS="$ID3" sh -c "$body" 2>"$TMP/gold.err")"; g_rc=$?
  m="$(BD_LOG="$TMP/mine.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ID="$ID1" GC_SESSION_NAME="$ID2" GC_ALIAS="$ID3" sh "$PROBE" "$arg" 2>"$TMP/mine.err")"; m_rc=$?
  local gids
  gids="$(printf '%s' "$g" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ -z "$g" ] && gids="(no output)"
  [ "$gids" = "" ] && gids="-"
  eq "[$step] $name: the engine's probe answers" "$gids" "$want"
  if [ -n "$want_out" ]; then
    eq "[$step] $name: the script's stdout (deliberately not the engine's [$g])" "$m" "$want_out"
  else
    if [ "$g" = "$m" ]; then ok "[$step] $name: stdout identical"; else bad "[$step] $name: stdout differs — engine [$g] vs script [$m]"; fi
    if cmp -s "$TMP/gold.log" "$TMP/mine.log"; then ok "[$step] $name: bd calls identical ($(wc -l < "$TMP/gold.log" | tr -d ' ') call(s), same flags, same order)"
    else bad "[$step] $name: bd calls differ"; diff <(tr '\037' ' ' < "$TMP/gold.log") <(tr '\037' ' ' < "$TMP/mine.log") | sed 's/^/      /' | head -12; fi
  fi
  if [ -z "$want_rc" ]; then
    if [ "$g_rc" = "$m_rc" ]; then ok "[$step] $name: exit code identical (=$m_rc)"; else bad "[$step] $name: exit code differs — engine $g_rc vs script $m_rc"; fi
  else
    eq "[$step] $name: the script's exit code (deliberately not the engine's $g_rc)" "$m_rc" "$want_rc"
  fi
  if [ -z "$want_err" ]; then
    if [ ! -s "$TMP/mine.err" ]; then ok "[$step] $name: nothing on stderr"; else bad "[$step] $name: unexpected stderr: $(head -c 300 "$TMP/mine.err")"; fi
  else
    if grep -Eq "$want_err" "$TMP/mine.err"; then ok "[$step] $name: stderr says it (/$want_err/)"; else bad "[$step] $name: stderr lacks /$want_err/ — got: $(head -c 300 "$TMP/mine.err")"; fi
  fi
}

FUT=4102444800   # 2100-01-01
PAST=1000000000  # 2001

# bead <id> <assignee> <priority> <created_at> [labels-json] [extra-json-object-merged-in]
# EMPTY_OBJ, not "${6:-{\}}": bash 3.2 (the mini's /bin/bash) keeps the backslash there, jq refuses the "{\}" it gets, and every bead comes out EMPTY
EMPTY_OBJ='{}'
bead() { jq -nc --arg id "$1" --arg as "$2" --argjson p "$3" --arg c "$4" --argjson l "${5:-[]}" --argjson x "${6:-$EMPTY_OBJ}" \
  '{id:$id, title:("t "+$id), status:"open", assignee:$as, priority:$p, created_at:$c, updated_at:$c, issue_type:"task", labels:$l} + $x'; }
arr() { local first=1; printf '['; for b in "$@"; do [ $first = 1 ] || printf ','; printf '%s' "$b"; first=0; done; printf ']'; }

for STEP in 1a 1b; do
echo "######## step $STEP"
echo "== 1. nothing anywhere -> [] (the tiers are probed, in the engine's order: durable then ephemeral per identity)"
reset_fix
run_both $STEP "empty" "-"
tier_order="$(awk -F $'\037' '{print $1}' "$TMP/mine.log" | tr '\n' ' ')"
if [ "$STEP" = 1a ]; then want_order="list query list query list query "; else want_order="ready query ready query ready query "; fi
eq "[$STEP] tier order" "$tier_order" "$want_order"

echo "== 2. a durable bead of the FIRST identity ends the probe at once"
reset_fix
arr "$(bead ga-d1 "$ID1" 2 2026-01-01T00:00:00Z)" > "$FIX/durable.json"
run_both $STEP "durable first id" "ga-d1"
eq "[$STEP] bd calls (probe stopped at the first hit)" "$(wc -l < "$TMP/mine.log" | tr -d ' ')" "1"

echo "== 3. ordering: priority first (the newer P1 beats the older P2), through the real work-order.sh"
reset_fix
arr "$(bead ga-old "$ID1" 2 2026-01-01T00:00:00Z)" "$(bead ga-p1 "$ID1" 1 2026-03-01T00:00:00Z)" > "$FIX/durable.json"
run_both $STEP "priority beats age" "ga-p1"

echo "== 4. the veto filter (each vetoed bead is OLDER than the winner, so a missed veto changes the answer)"
reset_fix
arr "$(bead ga-refused "$ID1" 1 2026-01-01T00:00:00Z '["pool:refused:x"]')" \
    "$(bead ga-held "$ID1" 1 2026-01-02T00:00:00Z '["pilot:held"]')" \
    "$(bead ga-heldfut "$ID1" 1 2026-01-03T00:00:00Z "[\"pilot:held-until:$FUT\"]")" \
    "$(bead ga-noauto "$ID1" 1 2026-01-04T00:00:00Z '["pilot:no-auto-dispatch"]')" \
    "$(bead ga-heldpast "$ID1" 1 2026-02-01T00:00:00Z "[\"pilot:held-until:$PAST\"]")" \
    "$(bead ga-plain "$ID1" 1 2026-03-01T00:00:00Z)" > "$FIX/durable.json"
run_both $STEP "durable vetoes (held-until in the past is not a veto)" "ga-heldpast"
reset_fix
arr "$(bead ga-refused "$ID1" 1 2026-01-01T00:00:00Z '["pool:refused:x"]')" \
    "$(bead ga-held "$ID1" 1 2026-01-02T00:00:00Z '["pilot:held"]')" \
    "$(bead ga-noauto "$ID1" 1 2026-01-04T00:00:00Z '["pilot:no-auto-dispatch"]')" \
    "$(bead ga-plain "$ID1" 1 2026-03-01T00:00:00Z)" > "$FIX/ephemeral.json"
run_both $STEP "ephemeral vetoes" "ga-plain"

echo "== 5. the ephemeral tier: only the dog's own beads"
reset_fix
arr "$(bead ga-other "someone-else" 0 2026-01-01T00:00:00Z)" "$(bead ga-mine "$ID2" 3 2026-02-01T00:00:00Z)" > "$FIX/ephemeral.json"
run_both $STEP "ephemeral assignee select (the second identity)" "ga-mine"
if [ "$STEP" = 1b ]; then
  reset_fix
  arr "$(bead ga-epic "$ID1" 0 2026-01-01T00:00:00Z '[]' '{"issue_type":"epic"}')" \
      "$(bead ga-blocked "$ID1" 0 2026-01-02T00:00:00Z '[]' '{"dependencies":[{"type":"blocks","status":"open"}]}')" \
      "$(bead ga-unblocked "$ID1" 2 2026-01-03T00:00:00Z '[]' '{"dependencies":[{"type":"blocks","status":"closed"}]}')" > "$FIX/ephemeral.json"
  run_both $STEP "ephemeral: not an epic, not blocked by an open dependency" "ga-unblocked"
fi

echo "== 6. the ordering library cannot answer -> the engine's own WARN, same answer"
reset_fix
arr "$(bead ga-a "$ID1" 2 2026-01-01T00:00:00Z)" > "$FIX/durable.json"
SAVE_LIB="$WORK_ORDER_LIB"; export WORK_ORDER_LIB=/nonexistent/work-order.sh
WANT_ERR='work-order WARN: wo_pick: work-order.sh not readable' run_both $STEP "lib missing (WARN, previous order kept)" "ga-a"
export WORK_ORDER_LIB="$SAVE_LIB"

echo "== 7. could not tell must not read as no work (the bug)"
# 7a. bd fails in every call
reset_fix; : > "$FIX/durable.fail"; : > "$FIX/ephemeral.fail"
WANT_RC=3 WANT_ERR="could not read:.*durable@$ID1.*ephemeral@$ID1.*durable@$ID2.*ephemeral@$ID3" run_both $STEP "bd fails everywhere -> [] + rc 3 (the engine: [] rc 0)" "-"
# 7b. THE ACCEPTANCE CASE: one raw 0x08 inside a description of an otherwise well-formed answer
reset_fix
python3 -I - "$FIX" "$STEP" "$ID1" <<'PY'
import json, sys
fix, step, id1 = sys.argv[1:4]
good = json.dumps([{"id": "ga-wisp", "title": "t", "status": "in_progress" if step == "1a" else "open", "assignee": id1,
                    "priority": 1, "created_at": "2026-01-01T00:00:00Z", "issue_type": "task", "labels": [],
                    "description": "BELL\x08BYTE"}], ensure_ascii=False)
good = good.replace("\\b", "\x08")                           # json.dumps escapes the byte as \b; make it RAW
assert "\\b" not in good and "\x08" in good
open(f"{fix}/ephemeral.raw", "w", encoding="utf-8").write(good)
PY
if jq -e . "$FIX/ephemeral.raw" >/dev/null 2>&1; then bad "[$STEP] fixture sanity: this jq ACCEPTS a raw 0x08 — the scenario would prove nothing"; else ok "[$STEP] fixture sanity: this jq refuses the raw 0x08 document (that is the hazard)"; fi
WANT_RC=3 WANT_ERR="could not read:.*ephemeral@$ID1" run_both $STEP "raw 0x08 in a wisp -> [] + rc 3 + stderr (the engine: [] rc 0, silent)" "-"
# 7c. bd answers something that is not JSON, rc 0
reset_fix; printf 'Error: database is locked' > "$FIX/durable.raw"; printf 'Error: database is locked' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd prints prose -> rc 3" "-"
# 7d. bd answers an error OBJECT instead of an array
reset_fix; printf '{"error":"x"}' > "$FIX/durable.raw"; printf '{"error":"x"}' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers an error object -> rc 3" "-"
# 7e. bd prints nothing, rc 0
reset_fix; : > "$FIX/durable.empty"; : > "$FIX/ephemeral.empty"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd prints nothing -> rc 3" "-"
# 7e2. bd prints only whitespace, rc 0 (jq answers nothing and rc 0 for it: an empty ANSWER is not an empty queue)
reset_fix; printf '  \n ' > "$FIX/durable.raw"; printf '  \n ' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd prints only whitespace -> rc 3" "-"
# 7f. a failing tier BEFORE a hit: the hit is answered (same stdout) and the hidden-head risk is said
reset_fix; : > "$FIX/durable.fail"; arr "$(bead ga-e "$ID1" 2 2026-01-01T00:00:00Z)" > "$FIX/ephemeral.json"
WANT_RC=0 WANT_ERR='found work, but earlier tier\(s\) could not be read: durable@' run_both $STEP "durable fails, ephemeral hits -> the hit + a warning" "ga-e"
# 7g. a REAL empty is still a clean [] (the probe did not become a permanent alarm)
reset_fix; printf '[]' > "$FIX/durable.json"; printf '[]' > "$FIX/ephemeral.json"
run_both $STEP "real empty arrays stay a clean []" "-"
# 7h. only ONE identity can be read and it is empty; the others fail: still unreadable
reset_fix; : > "$FIX/durable.$ID2.fail"
WANT_RC=3 WANT_ERR="could not read: durable@$ID2" run_both $STEP "one identity's durable read fails -> rc 3" "-"
# 7i. bd answers VALID JSON that is not ONE array of objects (ga-df22sac). 7d's {"error":"x"} is only caught because jq happens to fail on
#     the string; an answer jq can walk is taken for a queue. The engine reads {} / null as `[]` rc 0, hands out [null], hands out the bead
#     inside {"a":<bead>} (an error envelope), and stops on two documents. The script reads none of them as a queue: `[]` + stderr + rc 3.
reset_fix; printf '{}' > "$FIX/durable.raw"; printf '{}' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers {} (valid JSON, no array) -> rc 3" "-"
reset_fix; printf 'null' > "$FIX/durable.raw"; printf 'null' > "$FIX/ephemeral.raw"
WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers null -> rc 3" "-"
reset_fix; printf '[null]' > "$FIX/durable.raw"; printf '[null]' > "$FIX/ephemeral.raw"
WANT_OUT='[]' WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers an array of non-objects ([null]) -> rc 3, nothing handed out" "-"
reset_fix; printf '[] []' > "$FIX/durable.raw"; printf '[] []' > "$FIX/ephemeral.raw"
WANT_OUT='[]' WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers two documents -> rc 3, one clean []" "-"
reset_fix; printf '{"a":%s}' "$(bead ga-env "$ID1" 2 2026-01-01T00:00:00Z)" > "$FIX/durable.raw"; cp "$FIX/durable.raw" "$FIX/ephemeral.raw"
WANT_OUT='[]' WANT_RC=3 WANT_ERR='could not read:' run_both $STEP "bd answers an object whose value is a bead -> not handed out, rc 3" "ga-env"
eq "[$STEP] ...and the script kept looking through every tier (6 bd calls)" "$(wc -l < "$TMP/mine.log" | tr -d ' ')" "6"
done

echo "== 8. nothing to probe with (deliberate: the engine answers [] rc 0, the script says it did not look)"
reset_fix
ID1=""; ID2=""; ID3=""
for STEP in 1a 1b; do
  WANT_RC=2 WANT_ERR='all empty.*nothing was probed' run_both $STEP "no identity -> rc 2" "-"
done
export_ids
: > "$TMP/mine.log"
bogus_out="$(BD_LOG="$TMP/mine.log" BD_FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ID="$ID1" sh "$PROBE" bogus 2>"$TMP/mine.err")"; bogus_rc=$?
eq "bad step: stdout" "$bogus_out" "[]"; eq "bad step: exit code" "$bogus_rc" "2"
if grep -q "bad <step> 'bogus'" "$TMP/mine.err"; then ok "bad step: stderr says it"; else bad "bad step: stderr lacks the message: $(head -c 200 "$TMP/mine.err")"; fi
eq "bad step: nothing asked of bd" "$(wc -l < "$TMP/mine.log" | tr -d ' ')" "0"
# the long names are accepted too
reset_fix; arr "$(bead ga-n "$ID1" 2 2026-01-01T00:00:00Z)" > "$FIX/durable.json"
ARG=in_progress run_both 1a "alias in_progress = 1a" "ga-n"
ARG=ready run_both 1b "alias ready = 1b" "ga-n"

echo "== 9. the probe is the engine's, verbatim where it counts"
python3 -I - "$PROBE" "$GOLDEN_DIR/pool-probe-assigned.golden-1a.txt" "$GOLDEN_DIR/pool-probe-assigned.golden-1b.txt" <<'PY'
import re, sys
probe = open(sys.argv[1], encoding="utf-8").read()
bad = 0
def unwrap(path):
    t = open(path, encoding="utf-8").read().strip()
    assert t.startswith("sh -c '") and t.endswith("'"), path
    return t[len("sh -c '"):-1].replace("'\\''", "'")
for path in sys.argv[2:]:
    body = unwrap(path); tag = path.rsplit("golden-", 1)[1]
    # (a) wo_pick: the whole function, byte for byte
    a = body.index("wo_pick() {"); b = body.index("2>/dev/null; }", a) + len("2>/dev/null; }")
    ok = body[a:b] in probe
    print(("  ✓" if ok else "  ✗"), f"[{tag}] wo_pick() is verbatim in the script"); bad += not ok
    # (b) every single-quoted program of 20+ characters in the loop is verbatim in the script
    loop = body[body.index("for id in"):]
    progs = [p for p in re.findall(r"'([^']*)'", loop) if len(p) >= 20]     # pair the quotes in order FIRST, then drop the short ones
    missing = [p for p in progs if p not in probe]
    print(("  ✓" if not missing else "  ✗"), f"[{tag}] {len(progs)} single-quoted program(s) in the loop, {len(missing)} not verbatim in the script"); bad += bool(missing)
    for p in missing: print("      missing:", p[:120])
    # (c) the bd calls: each `bd <verb> ...` argv (up to the pipe) appears in the script with the same flags
    for call in re.findall(r"\b(bd (?:list|ready|query)[^|]*?)(?= 2>/dev/null)", loop):
        norm = re.sub(r"\s+", " ", call.strip())
        want = norm.replace("'", "'")                       # the script writes the very same text
        okc = want in re.sub(r"\s+", " ", probe)
        print(("  ✓" if okc else "  ✗"), f"[{tag}] bd call verbatim: {norm[:90]}"); bad += not okc
sys.exit(1 if bad else 0)
PY
rc=$?; if [ $rc -eq 0 ]; then ok "verbatim checks"; else bad "verbatim checks (rc $rc)"; fi

if [ "$LIVE" = 1 ]; then
  echo "== 10. --live: the goldens against what \`gc prime\` renders NOW"
  prime="$(gc prime 2>/dev/null)" || prime=""
  if [ -z "$prime" ]; then bad "gc prime could not be read — cannot compare (that is a FAIL, not a pass)"
  else
    for s in 1a 1b; do
      live="$(printf '%s\n' "$prime" | awk -v s="# Step $s" 'index($0, s) == 1 { getline; print; exit }')"
      want="$(cat "$GOLDEN_DIR/pool-probe-assigned.golden-$s.txt")"
      if [ -z "$live" ]; then bad "[$s] no Step $s line in gc prime"
      elif [ "$live" = "$want" ]; then ok "[$s] golden == live gc prime"
      else bad "[$s] golden DIFFERS from live gc prime (engine window since? regenerate the golden and re-run)"; fi
    done
  fi
fi

echo; echo "pool-probe-assigned selftest: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
