#!/usr/bin/env bash
# pilot-dispatcher.text-veto-label.selftest.sh — Prove the ga-qt0mj fix: when
# _filter_candidates' 4 TEXT-only vetoes (engine-rebuild / DECISAO-title /
# "só o Athos decide" / 🚨 compliance-marker) drop a bead, the reason must
# become visible ON THE BEAD via _reconcile_text_veto_labels, not only in the
# Pilot's log — and it must self-clear the moment the text stops matching.
#
# Acceptance criteria under test (bead ga-qt0mj):
#   AC1. A bead whose text currently matches a pattern, and lacks the
#        corresponding pilot:text-veto:<pattern> label, gets it ADDED.
#   AC2. A bead that carries a pilot:text-veto:<pattern> label but whose text
#        no longer matches gets it REMOVED (self-clearing — cannot regress).
#   AC3. Already-correct state (match+label, or no-match+no-label) produces
#        ZERO bd calls — idempotent, no log/API spam on a healthy sweep.
#   AC4. DRY_RUN=1 produces WOULD-* log lines only, zero real bd calls.
#   AC5. Empty/missing db argument is a complete no-op (opt-in, not opt-out)
#        — zero bd calls — while STILL passing input through unchanged.
#   AC6. Transparent pass-through: stdout is byte-identical to stdin in every
#        scenario, regardless of what labels get reconciled as a side effect
#        — this stage must never be able to alter what actually dispatches.
#   AC7. The DECISAO pattern is TITLE-ONLY (mirrors _filter_candidates' own
#        scope for that one clause, unlike the other 3 which scan title+body).
#   AC8. A bead matching multiple patterns at once gets multiple independent
#        add actions (one per pattern), not just the first.
#   AC9. Differential: for a shared fixture set, the patterns this function
#        matches are IDENTICAL to what _filter_candidates' own trace mirror
#        would report — guards against the two copies drifting apart, since
#        this function intentionally does not touch _filter_candidates itself.
#
# Runs entirely against extracted function bodies (same awk/sed-extraction
# idiom as pilot-dispatcher.exclusion-trace.selftest.sh) with a PATH-shimmed
# fake `bd` that records calls to a file instead of touching any real store.
# Safe on a live host — no live Dolt/bd/gc required.
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-text-veto-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
TVP="$(sed -n "/^_PILOT_ENGINE_REBUILD_RE=/,/^\]')\$/p" "$DISPATCHER")"
RTV_FN="$(sed -n '/^_reconcile_text_veto_labels() {/,/^}$/p' "$DISPATCHER")"
FC_FN="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$DISPATCHER")"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"

if [ -z "$TVP" ]; then
  echo "FATAL: _TEXT_VETO_PATTERNS not found in $DISPATCHER — has ga-qt0mj landed?" >&2
  exit 2
fi
if [ -z "$RTV_FN" ]; then
  echo "FATAL: _reconcile_text_veto_labels() not found in $DISPATCHER — has ga-qt0mj landed?" >&2
  exit 2
fi

SHIMBIN="$WORK/bin"; mkdir -p "$SHIMBIN"
CALLLOG="$WORK/bd-calls.tsv"
: > "$CALLLOG"
cat > "$SHIMBIN/bd" <<SHIM
#!/usr/bin/env bash
# Records every 'bd -C <db> label <verb> <id> <label> ...' call instead of
# touching any real store. Anything else returns an empty JSON array.
if [ "\$1" = "-C" ]; then
  db="\$2"
  if [ "\$3" = "label" ]; then
    printf '%s\t%s\t%s\t%s\n' "\$db" "\$4" "\$5" "\$6" >> "$CALLLOG"
    exit 0
  fi
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/bd"

run_rtv() {
  # run_rtv <db> <input-json> [extra-env-line]
  local db="$1" input="$2" extra="${3:-}"
  : > "$CALLLOG"
  cat > "$WORK/run.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$TVP
$RTV_FN
$extra
printf '%s' '$input' | _reconcile_text_veto_labels "$db"
EOF
  bash "$WORK/run.sh"
}

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1: AC1 — text matches, label absent → ADD"
IN1='[{"id":"ga-add1","labels":[],"title":"x","description":"needs a gascity engine rebuild"}]'
OUT1="$(run_rtv /fake/db "$IN1")"
[ "$OUT1" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input (got: $OUT1)"
grep -qF "$(printf '/fake/db\tadd\tga-add1\tpilot:text-veto:engine-rebuild-text-pattern')" "$CALLLOG" \
  && ok "AC1: engine-rebuild match with no label produces an ADD call" \
  || bad "AC1: expected ADD call missing (calllog: $(cat "$CALLLOG"))"
[ "$(wc -l < "$CALLLOG" | tr -d ' ')" = "1" ] \
  && ok "AC3: exactly one call for one matching pattern (no spurious extras)" \
  || bad "AC3: expected exactly 1 call, got: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2: AC2 — label present, text no longer matches → REMOVE (self-clears)"
IN2='[{"id":"ga-rm1","labels":["pilot:text-veto:athos-decide-phrase-text-pattern"],"title":"x","description":"this text was fixed and no longer mentions that phrase"}]'
OUT2="$(run_rtv /fake/db "$IN2")"
[ "$OUT2" = "$IN2" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
grep -qF "$(printf '/fake/db\tremove\tga-rm1\tpilot:text-veto:athos-decide-phrase-text-pattern')" "$CALLLOG" \
  && ok "AC2: stale label with no current match produces a REMOVE call (self-clears)" \
  || bad "AC2: expected REMOVE call missing (calllog: $(cat "$CALLLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3: AC3 — already-correct states produce ZERO calls"
IN3='[
  {"id":"ga-ok-match","labels":["pilot:text-veto:compliance-marker-text-pattern"],"title":"x","description":"🚨 still an open marker"},
  {"id":"ga-ok-clean","labels":[],"title":"a normal task","description":"nothing special here"}
]'
OUT3="$(run_rtv /fake/db "$IN3")"
[ "$OUT3" = "$IN3" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
[ ! -s "$CALLLOG" ] \
  && ok "AC3: healthy/already-reconciled beads produce ZERO bd calls" \
  || bad "AC3: expected zero calls, got: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4: AC4 — DRY_RUN=1 makes zero real bd calls, logs WOULD-* only"
OUT4="$(run_rtv /fake/db "$IN1" "export DRY_RUN=1" 2>"$WORK/s4.stderr")"
[ "$OUT4" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin under DRY_RUN" || bad "AC6: pass-through altered under DRY_RUN"
[ ! -s "$CALLLOG" ] \
  && ok "AC4: DRY_RUN=1 makes zero real bd calls" \
  || bad "AC4: DRY_RUN=1 still called bd: $(cat "$CALLLOG")"
grep -qF "WOULD add pilot:text-veto:engine-rebuild-text-pattern on ga-add1" "$WORK/s4.stderr" \
  && ok "AC4: DRY_RUN logs the intended action" \
  || bad "AC4: DRY_RUN log line missing/wrong (stderr: $(cat "$WORK/s4.stderr"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5: AC5 — empty db argument is a complete no-op, but still passes through"
OUT5="$(run_rtv "" "$IN1")"
[ "$OUT5" = "$IN1" ] && ok "AC6+AC5: empty db still passes input through unchanged" || bad "AC5: pass-through broke with empty db"
[ ! -s "$CALLLOG" ] \
  && ok "AC5: empty db makes zero bd calls (opt-in, not opt-out)" \
  || bad "AC5: empty db still called bd: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 6: AC7 — DECISAO pattern is TITLE-ONLY, does not scan description"
IN6='[
  {"id":"ga-decisao-in-desc","labels":[],"title":"normal title","description":"DECISAO: buried in the body, not the title"},
  {"id":"ga-decisao-in-title","labels":[],"title":"DECISAO: pricing change","description":"x"}
]'
OUT6="$(run_rtv /fake/db "$IN6")"
[ "$OUT6" = "$IN6" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
grep -qF "ga-decisao-in-desc" "$CALLLOG" \
  && bad "AC7: DECISAO in DESCRIPTION-only must NOT trigger (title-only scope) — calllog: $(cat "$CALLLOG")" \
  || ok "AC7: DECISAO text in description-only correctly ignored (title-only scope preserved)"
grep -qF "$(printf '/fake/db\tadd\tga-decisao-in-title\tpilot:text-veto:decisao-title-text-pattern')" "$CALLLOG" \
  && ok "AC7: DECISAO in the TITLE correctly triggers the add" \
  || bad "AC7: expected add for ga-decisao-in-title missing (calllog: $(cat "$CALLLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 7: AC8 — a bead matching multiple patterns gets multiple independent adds"
IN7='[{"id":"ga-multi","labels":[],"title":"DECISAO: x","description":"🚨 compliance issue also present"}]'
OUT7="$(run_rtv /fake/db "$IN7")"
[ "$OUT7" = "$IN7" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
grep -qF "$(printf '/fake/db\tadd\tga-multi\tpilot:text-veto:decisao-title-text-pattern')" "$CALLLOG" \
  && ok "AC8: multi-match bead gets the decisao-title add" \
  || bad "AC8: missing decisao-title add for multi-match bead"
grep -qF "$(printf '/fake/db\tadd\tga-multi\tpilot:text-veto:compliance-marker-text-pattern')" "$CALLLOG" \
  && ok "AC8: multi-match bead ALSO gets the compliance-marker add (independent, not first-match-wins)" \
  || bad "AC8: missing compliance-marker add for multi-match bead"
[ "$(wc -l < "$CALLLOG" | tr -d ' ')" = "2" ] \
  && ok "AC8: exactly 2 calls for 2 matching patterns (no missing, no duplicate)" \
  || bad "AC8: expected exactly 2 calls, got: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 8: AC9 — differential against _filter_candidates' own trace-mirror reasons"
# Reuses the SAME fixtures _filter_candidates' own exclusion-trace selftest is
# not concerned with — a fresh set covering all 4 patterns, each isolated so
# the trace mirror's single-string reason is unambiguous per bead.
D_FIXTURES='[
  {"id":"ga-d-engine","assignee":null,"labels":[],"description":"needs a gascity engine rebuild"},
  {"id":"ga-d-decisao","assignee":null,"labels":[],"title":"DECISAO: x","description":"y"},
  {"id":"ga-d-athos","assignee":null,"labels":[],"description":"só o athos decide isso"},
  {"id":"ga-d-marker","assignee":null,"labels":[],"description":"🚨 compliance gate"}
]'
FC_TRACE="$(bash -c "$LOG_FN
$LE_FN
$PRE
$CAP
$TVP
$FC_FN
SELF_BEAD_ID=''
printf '%s' '$D_FIXTURES' | _filter_candidates" 2>&1 >/dev/null)"
run_rtv /fake/db "$D_FIXTURES" > /dev/null
RTV_ADDS="$(awk -F'\t' '{print $3"\t"$4}' "$CALLLOG" | sort)"
EXPECTED_ADDS="$(printf 'ga-d-athos\tpilot:text-veto:athos-decide-phrase-text-pattern\nga-d-decisao\tpilot:text-veto:decisao-title-text-pattern\nga-d-engine\tpilot:text-veto:engine-rebuild-text-pattern\nga-d-marker\tpilot:text-veto:compliance-marker-text-pattern' | sort)"
[ "$RTV_ADDS" = "$EXPECTED_ADDS" ] \
  && ok "AC9: _reconcile_text_veto_labels' matches align with expectation for all 4 patterns" \
  || bad "AC9: mismatch — got: [$RTV_ADDS] want: [$EXPECTED_ADDS]"
for _id in ga-d-engine ga-d-decisao ga-d-athos ga-d-marker; do
  grep -qF "$_id" <<<"$FC_TRACE" \
    && ok "AC9: _filter_candidates' own trace also excludes $_id (both copies agree)" \
    || bad "AC9: _filter_candidates' trace does NOT mention $_id — drift between the two pattern copies? (trace: $FC_TRACE)"
done

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  echo "SELFTEST PASS"
  exit 0
else
  echo "SELFTEST FAIL"
  exit 1
fi
