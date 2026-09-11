#!/usr/bin/env bash
# Selftest for pipeline-throughput-heartbeat.py — ga-4s4t6 regression only.
#
# BUG: REPAIR_HEADER carried a literal 🚨 in the text that becomes the repair
# bead's DESCRIPTION (build_repair_payload → `gc sling --stdin`, first line =
# title, rest = description). The Pilot's own compliance-marker-text-pattern
# veto (pilot-dispatcher.sh, _TEXT_VETO_PATTERNS, ga-qt0mj single source of
# truth) excludes any dispatch candidate whose title+description matches
# literal "🚨" — so EVERY autonomous repair bead this heartbeat ever generated
# was silently excluded from dispatch. The repair mechanism never ran, by
# construction. Seen 2026-09-11 via the new pilot:text-veto label alert
# (ga-i00xl, which made this class of veto visible on the bead for the first
# time instead of only in the Pilot's log).
#
# This test renders the ACTUAL repair-bead payload for all 4 kinds via the
# real build_repair_payload() (no re-implementation of the template text) and
# runs each rendered payload through the Pilot's REAL _TEXT_VETO_PATTERNS —
# extracted from the live pilot-dispatcher.sh with the same sed idiom
# pilot-dispatcher.text-veto-label.selftest.sh already uses (the ga-qt0mj
# single source of truth), not a hand-copied regex, so this test cannot drift
# from what the Pilot actually vetoes on. Checks ALL 5 patterns, not just
# compliance-marker — the ask is "no pattern may match", a general safety net
# against this whole class of bug, not just today's specific glyph.
#
# NOT a general test harness for this file — scoped narrowly to this one bug,
# same convention as the sibling pipeline-throughput-heartbeat.selftest.sh
# (ga-30xi3).
#
# Run: bash scripts/pipeline-throughput-heartbeat.compliance-marker-text-veto.selftest.sh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB="${HB_OVERRIDE:-$SELF_DIR/pipeline-throughput-heartbeat.py}"
DISPATCHER="$SELF_DIR/../packs/town-deltas/assets/pilot-dispatcher.sh"
[ -f "$HB" ] || { echo "FATAL: pipeline-throughput-heartbeat.py not found at $HB"; exit 1; }
[ -f "$DISPATCHER" ] || { echo "FATAL: pilot-dispatcher.sh not found at $DISPATCHER"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "  ok: $*"; PASS=$((PASS+1)); }
bad() { echo "  BAD: $*"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pth-compliance-marker-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ── Extract the LIVE _TEXT_VETO_PATTERNS (ga-qt0mj single source of truth) ────
# Same sed range pilot-dispatcher.text-veto-label.selftest.sh uses: from the
# first regex var this jq assignment depends on, through the closing `]')` of
# the _TEXT_VETO_PATTERNS=$(jq -n ...) assignment. Written to a FILE and run
# via `bash file` (not `bash -c "$TVP..."`) — embedding a multi-line, comment-
# and-quote-heavy extracted block into a second layer of double-quoting
# corrupts jq's program text; a real script file sidesteps that entirely.
TVP="$(sed -n "/^_PILOT_ENGINE_REBUILD_RE=/,/^\]')\$/p" "$DISPATCHER")"
if [ -z "$TVP" ]; then
  echo "FATAL: _TEXT_VETO_PATTERNS not found in $DISPATCHER — has ga-qt0mj landed?"
  exit 2
fi
cat > "$WORK/extract-tvp.sh" <<EOF
$TVP
printf '%s' "\$_TEXT_VETO_PATTERNS"
EOF
PATTERNS_JSON="$(bash "$WORK/extract-tvp.sh")"
if [ -z "$PATTERNS_JSON" ] || ! printf '%s' "$PATTERNS_JSON" | jq -e . >/dev/null 2>&1; then
  echo "FATAL: could not evaluate _TEXT_VETO_PATTERNS from the live dispatcher"
  exit 2
fi
echo "Extracted $(printf '%s' "$PATTERNS_JSON" | jq 'length') live Pilot text-veto patterns from $DISPATCHER"

# ── Render the real repair-bead payload for all 4 kinds ───────────────────────
# Imports the real module via importlib (main() is guarded by
# __name__=='__main__', so import does NOT start the daemon loop) and calls
# the real build_repair_payload() — the exact function spawn_repair_agent()
# uses — so this test renders precisely what would become bead content.
python3 - "$HB" "$WORK/payloads.json" <<'PY'
import importlib.util, sys, json
_hb_path, _out_path = sys.argv[1], sys.argv[2]   # capture before argv gets reset below
spec = importlib.util.spec_from_file_location("pth", _hb_path)
m = importlib.util.module_from_spec(spec)
sys.argv = ["pth"]
spec.loader.exec_module(m)

if not hasattr(m, "build_repair_payload"):
    print("FATAL: build_repair_payload() not found — has ga-4s4t6 landed?", file=sys.stderr)
    sys.exit(2)

out = {}
for kind in ("pilot", "gate-merge", "durable", "session-rot"):
    title, payload = m.build_repair_payload(
        kind, "motivo de teste (selftest ga-4s4t6)", "/tmp/diag-test.txt")
    out[kind] = {"title": title, "payload": payload}
with open(_out_path, "w") as f:
    json.dump(out, f)
PY
rc=$?
if [ "$rc" != "0" ] || [ ! -s "$WORK/payloads.json" ]; then
  echo "FATAL: failed to render repair payloads (rc=$rc) — has build_repair_payload() landed (ga-4s4t6)?"
  exit 2
fi

# ── Run every rendered payload through every live veto pattern ───────────────
# Scans the WHOLE rendered payload (title is already embedded at its start,
# so this covers title+description together, a superset of what any single
# pattern's own field scope would see) — proving ABSENCE of a match on the
# superset is the conservative direction: it can only ever produce a false
# BAD (a pattern matching body text that a title-only scope would have
# ignored), never a false ok, and none of the 5 live patterns match anything
# else in this template.
if ! jq -n --argjson pats "$PATTERNS_JSON" --slurpfile payloads "$WORK/payloads.json" '
  $payloads[0] as $p
  | [ $p | to_entries[] | . as $entry | {
        kind: $entry.key,
        matched: [ $pats[] | . as $pat | ($pat.re // "") as $re
                            | select(($re | length) > 0)
                            | select($entry.value.payload | test($re; "i"))
                            | $pat.slug ]
      } ]
' > "$WORK/results.json" 2>"$WORK/jq.stderr"; then
  echo "FATAL: jq failed evaluating veto patterns against rendered payloads:"
  cat "$WORK/jq.stderr"
  exit 2
fi

# A jq success with zero result rows is exactly the "error and empty produce the
# same value" trap — assert the expected row count explicitly so a broken query
# fails LOUDLY (FATAL) instead of silently reporting 0 passed/0 failed as PASS.
N_RESULTS="$(jq 'length' "$WORK/results.json")"
if [ "$N_RESULTS" != "4" ]; then
  echo "FATAL: expected 4 rendered kinds (pilot, gate-merge, durable, session-rot), got $N_RESULTS — results.json: $(cat "$WORK/results.json")"
  exit 2
fi

while IFS=$'\t' read -r kind matched; do
  if [ "$matched" = "[]" ]; then
    ok "kind=$kind — rendered repair-bead text matches ZERO Pilot text-veto patterns"
  else
    bad "kind=$kind — rendered repair-bead text MATCHES Pilot veto pattern(s): $matched (this bead would never dispatch)"
  fi
done < <(jq -r '.[] | [.kind, (.matched | tojson)] | @tsv' "$WORK/results.json")

if [ "$((PASS + FAIL))" != "4" ]; then
  echo "FATAL: expected 4 scenario checks to run, only $((PASS + FAIL)) did — the read-loop above silently ate rows"
  exit 2
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
