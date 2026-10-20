#!/usr/bin/env bash
# pilot-dispatcher.exec-manual-batch.selftest.sh — ga-it7qiq: _filter_exec_manual asks bead_state.derive() about the
# whole list in ONE python3, not one python3 per bead.
#
# Why. The filter bridged every candidate to bead_state.derive() with its own `python3 -c` (ga-10co2 shipped it per
# candidate on purpose, "to MEASURE" the cost before anyone built the batched form). Measured 20/10 at load 44: 0.095 s
# per bead — 30.6 s for the 322 beads of the WA rig, paid once per pass of the candidate chain, ~6 passes per sweep.
#
# What is proved (the CONTRACT is unchanged — only the number of processes):
#   (1) the same beads come out as a per-bead reference model (derive() state + the exec:manual label), and the literal
#       exec:manual set is excluded — including exec:manual + needs-label-review, which derive() alone would keep (ga-0kqjl);
#   (2) python3 is started at most ONCE for any list, and not at all for an empty list;
#   (3) THREE states, none of them collapsed into another: python3 failing, crashing after printing part of its output,
#       or answering fewer lines than it was asked, switches the bridge OFF as a whole and the label check serves the
#       list — exactly what one failing bead did before; a half-bridged answer is never used;
#   (4) a list element that is not an object is still isolated by the fallback with its WARN (ga-fesw8n), not fatal;
#   (5) negative control: the per-bead reference implementation DOES start one python3 per bead, so the counter can tell.
#
# Runs the REAL function text cut out of the dispatcher (sed idiom of pilot-dispatcher.filter-jq-failure.selftest.sh)
# in a child bash under `set -euo pipefail`, with a counting python3 shim first on PATH. No Dolt, bd or gc needed.
# Env: EMB_DISPATCHER_UNDER_TEST points at a mutant; EMB_SKIP_MUTATION=1 skips (6). Exit 0 iff every check holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${EMB_DISPATCHER_UNDER_TEST:-$HERE/pilot-dispatcher.sh}"
BSP="$HERE/../../../scripts/bead_state.py"
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$BSP" ] || { echo "FATAL: bead_state.py not found at $BSP" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 missing" >&2; exit 2; }
REALPY="$(command -v python3)"

P=0; F=0
ok()  { echo "  ok: $*"; P=$((P+1)); }
bad() { echo "  BAD: $*"; F=$((F+1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ga-it7qiq-emb.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }
warn() { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
EM_FN="$(sed -n '/^_filter_exec_manual() {/,/^}$/p' "$DISPATCHER")"
[ -n "$LE_FN" ] && [ -n "$EM_FN" ] || { echo "FATAL: could not cut _log_exclusions/_filter_exec_manual out of $DISPATCHER" >&2; exit 2; }

# python3 shim: counts starts; PYMODE picks the behaviour
BIN="$TMP/bin"; mkdir -p "$BIN"; COUNT="$TMP/py.count"
cat > "$BIN/python3" <<EOF
#!/bin/bash
echo x >> "$COUNT"
case "\${PYMODE:-real}" in
  real)    exec "$REALPY" "\$@" ;;
  fail)    exit 1 ;;
  partial) printf 'plain\tmanual_unrouted\n'; exit 1 ;;
  short)   printf 'plain\tmanual_unrouted\n'; exit 0 ;;
esac
EOF
chmod +x "$BIN/python3"
pycount() { if [ -f "$COUNT" ]; then wc -l < "$COUNT" | tr -d ' '; else echo 0; fi; }

# ── fixture: 12 beads, ids chosen so the intent is readable ───────────────────────────────
CORPUS="$(jq -c . <<'JSON'
[
 {"id":"plain",     "status":"open",        "assignee":"",       "labels":[],                                   "metadata":{}},
 {"id":"auto",      "status":"open",        "assignee":"",       "labels":["exec:auto"],                        "metadata":{}},
 {"id":"man-free",  "status":"open",        "assignee":"",       "labels":["exec:manual"],                      "metadata":{}},
 {"id":"man-owned", "status":"open",        "assignee":"athos",  "labels":["exec:manual"],                      "metadata":{}},
 {"id":"man-park",  "status":"open",        "assignee":"",       "labels":["exec:manual","needs-label-review"], "metadata":{}},
 {"id":"park-only",  "status":"open",       "assignee":"",       "labels":["needs-label-review"],               "metadata":{}},
 {"id":"running",   "status":"in_progress", "assignee":"dog-1",  "labels":["story:in-flight"],                  "metadata":{}},
 {"id":"nolabels",  "status":"open",        "assignee":"",       "labels":null,                                 "metadata":{}},
 {"id":"routed",    "status":"open",        "assignee":"",       "labels":[],                                   "metadata":{"gc.routed_to":"gastown.dog"}},
 {"id":"nextact",   "status":"open",        "assignee":"",       "labels":["next-action:mayor"],                "metadata":{}},
 {"id":"blocked",   "status":"blocked",     "assignee":"",       "labels":[],                                   "metadata":{}},
 {"id":"needsfix",  "status":"open",        "assignee":"",       "labels":["gate:needs-fix"],                   "metadata":{}}
]
JSON
)"
EXPECT_EXCLUDED='["man-free","man-owned","man-park"]'   # LITERAL: the exec:manual beads, nothing else

# reference MODEL (independent of the function under test): derive() per bead in one process + the label rule
model_kept() {
  printf '%s' "$1" | PYTHONPATH="$(dirname "$BSP")" "$REALPY" -c '
import sys, json
from bead_state import derive
keep = []
for b in json.load(sys.stdin):
    st = derive({"status": b.get("status",""), "labels": b.get("labels") or [], "assignee": b.get("assignee") or "", "metadata": b.get("metadata") or {}})["state"]
    if "exec:manual" in (b.get("labels") or []) or st in ("manual_assigned", "manual_unrouted"):
        continue
    keep.append(b["id"])
print(json.dumps(sorted(keep)))'
}

# run the real stage in a child bash with the dispatcher's own strictness
run_stage() { # <json> [PYMODE]
  printf '%s' "$1" > "$TMP/in.json"; : > "$COUNT"
  PYMODE="${2:-real}" PATH="$BIN:$PATH" bash -c "
set -euo pipefail
$LOG_FN
$LE_FN
$EM_FN
SELF_BEAD_ID=''
PILOT_BEAD_STATE_PY_OVERRIDE='$BSP'
_out=\$(cat '$TMP/in.json' | _filter_exec_manual)
printf '%s' \"\$_out\"" > "$TMP/out" 2> "$TMP/err"
  RC=$?; OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
ids() { jq -c '[.[].id] | sort' <<<"$1" 2>/dev/null; }

echo "== pilot-dispatcher.exec-manual-batch.selftest (ga-it7qiq) =="

echo "-- 1. same beads as the per-bead reference model; the exec:manual set is excluded --"
run_stage "$CORPUS"
WANT="$(model_kept "$CORPUS" | jq -c .)"; GOT="$(ids "$OUT")"
if [ "$RC" = 0 ] && [ "$GOT" = "$WANT" ]; then ok "output equals the reference model ($(jq 'length' <<<"$GOT") of 12 kept)"; else bad "rc=$RC got=$GOT want=$WANT err=$ERR"; fi
EXCL="$(jq -c --argjson kept "$GOT" '[.[].id | select(. as $i | $kept | index($i) | not)] | sort' <<<"$CORPUS")"
if [ "$EXCL" = "$EXPECT_EXCLUDED" ]; then ok "excluded exactly the literal exec:manual set $EXCL (incl. exec:manual + needs-label-review)"; else bad "excluded $EXCL, want $EXPECT_EXCLUDED"; fi

echo "-- 2. python3 starts at most once per list, never for an empty list --"
run_stage "$CORPUS"; N="$(pycount)"
if [ "$N" -le 1 ] 2>/dev/null && [ "$N" -ge 1 ]; then ok "12 beads -> $N python3 start"; else bad "12 beads -> $N python3 starts (want exactly 1)"; fi
run_stage '[]'; N="$(pycount)"
if [ "$N" = "0" ] && [ "$OUT" = "[]" ]; then ok "empty list -> 0 python3 starts, output []"; else bad "empty list -> $N starts, out=[$OUT]"; fi
run_stage "$(jq -c '[.[0]]' <<<"$CORPUS")"; N="$(pycount)"
[ "$N" = "1" ] && ok "one bead -> 1 python3 start" || bad "one bead -> $N starts"

echo "-- 3. a failed / half / short python3 answer switches the bridge OFF as a whole; the label check serves the list --"
for mode in fail partial short; do
  run_stage "$CORPUS" "$mode"; N="$(pycount)"; GOT="$(ids "$OUT")"
  WANT_FB="$(jq -c '[.[] | select(((.labels // []) | index("exec:manual")) == null) | .id] | sort' <<<"$CORPUS")"
  if [ "$RC" = 0 ] && [ "$GOT" = "$WANT_FB" ] && [ "$N" -le 1 ] && jq -e 'index("plain")' <<<"$GOT" >/dev/null; then ok "PYMODE=$mode: the lying/partial answer was rejected, label-check result served ($GOT), $N python3 start"
  else bad "PYMODE=$mode: rc=$RC got=$GOT want=$WANT_FB starts=$N err=$ERR"; fi
done

echo "-- 4. a list element that is not an object is isolated by the fallback (ga-fesw8n), not fatal --"
MIX="$(jq -c '[.[0], 5, .[2]]' <<<"$CORPUS")"   # plain, a bare number, an exec:manual bead
run_stage "$MIX"
if [ "$RC" = 0 ] && [ "$(ids "$OUT")" = '["plain"]' ] && grep -q 'WARN' <<<"$ERR"; then ok "kept [plain], dropped the number and the exec:manual bead, WARN on stderr"; else bad "rc=$RC out=$OUT err=$ERR"; fi

echo "-- 5. negative control: the per-bead reference implementation starts one python3 per bead --"
OLD_FN='_old_per_bead() { local l; while IFS= read -r l; do [ -z "$l" ] && continue; printf "%s" "$l" | PYTHONPATH="$(dirname "$PILOT_BEAD_STATE_PY_OVERRIDE")" python3 -c "import sys,json; json.load(sys.stdin)" >/dev/null; done < <(printf "%s" "$1" | jq -c ".[]"); }'
: > "$COUNT"; PATH="$BIN:$PATH" PYMODE=real bash -c "$OLD_FN; PILOT_BEAD_STATE_PY_OVERRIDE='$BSP'; _old_per_bead '$CORPUS'"
N="$(pycount)"
if [ "$N" = "12" ]; then ok "per-bead shape = 12 starts for 12 beads — the counter can tell the difference"; else bad "negative control counted $N starts (want 12)"; fi

if [ "${EMB_SKIP_MUTATION:-0}" != "1" ] && [ -z "${EMB_DISPATCHER_UNDER_TEST:-}" ]; then
  echo "-- 6. mutation control: extra python3 starts inside the real function; THIS file must fail --"
  python3 -I - "$DISPATCHER" "$TMP/mut.sh" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
# two extra python3 starts at the top of the stage: the list is still answered, but with 3 processes instead of 1
t2 = t.replace("_filter_exec_manual() {", "_filter_exec_manual() {\n  python3 -c 'pass' </dev/null; python3 -c 'pass' </dev/null", 1)
assert t2 != t
open(sys.argv[2], "w", encoding="utf-8").write(t2)
PY
  EMB_DISPATCHER_UNDER_TEST="$TMP/mut.sh" EMB_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mut.out" 2>&1 \
    && bad "mutant (extra python3 starts) was NOT rejected" || ok "mutant (extra python3 starts) is rejected"
  python3 -I - "$DISPATCHER" "$TMP/mut2.sh" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
t2 = t.replace('if [ "$_em_n_in" != "$_em_n_out" ]; then', 'if false; then', 1)
assert t2 != t, "count-check anchor not found"
open(sys.argv[2], "w", encoding="utf-8").write(t2)
PY
  EMB_DISPATCHER_UNDER_TEST="$TMP/mut2.sh" EMB_SKIP_MUTATION=1 bash "$HERE/$(basename "${BASH_SOURCE[0]}")" >"$TMP/mut2.out" 2>&1 \
    && bad "mutant (line-count check disabled) was NOT rejected" || ok "mutant (line-count check disabled) is rejected"
fi

echo
echo "== exec-manual-batch: $P passed, $F failed =="
[ "$F" -eq 0 ]
