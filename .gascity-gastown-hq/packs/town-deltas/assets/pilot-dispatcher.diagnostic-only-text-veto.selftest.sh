#!/usr/bin/env bash
# pilot-dispatcher.diagnostic-only-text-veto.selftest.sh — Prove the ga-4lsu7
# fix: the filler/Tier-2 path (story:approved, dispatched only when no open
# bugs/tech-debt exist) can select a bead whose OWN body explicitly scopes
# itself as non-buildable ("só diagnóstico", "não propõe implementação",
# "decisão de arquitetura") and dispatch it as an ordinary build story with
# empty Acceptance Criteria/Estrela Guia/Equilíbrios — burning a dispatch +
# investigation cycle before a worker reads the body and refuses by hand.
#
# Measured incident: ga-9n9z7 (AC/Estrela Guia/Equilíbrios all empty,
# dispatched via sling ga-r11bw as tier=feature P3 "filler Tier-2 por falta
# de bugs/tech-debt"; correctly refused by dog-ga8co7e with
# pool:refused:needs-architecture-decision only after the sling+investigation
# cost was already paid).
#
# Acceptance criteria under test (bead ga-4lsu7):
#   AC1. A bead whose title+description matches the diagnostic-only-text
#        pattern is excluded by _filter_candidates — same standalone-
#        sufficient shape as this function's 4 existing text-only vetoes
#        (engine-rebuild / DECISAO-title / "só o Athos decide" / 🚨).
#        Deliberately does NOT gate on empty acceptance_criteria/
#        story.criterios ALONE — see Scenario 3 (AC4) for why.
#   AC2. Regression proof: this test runs the SAME _filter_candidates body
#        extracted LIVE from the shipped script (sed-extraction, same idiom
#        as every sibling selftest) — so re-running this file unmodified
#        before vs. after the fix lands is the RED/GREEN proof: it fails
#        against pre-fix code (the ga-9n9z7 fixture survives filtering,
#        i.e. dispatches) and passes post-fix (excluded).
#   AC3. Property of the BODY, not an id/title lookup: Scenario 2 uses a
#        DIFFERENT id and a DIFFERENT, unrelated title from ga-9n9z7's own,
#        with only the disclaiming phrase carried over in the description —
#        still excluded. Proves the check cannot be an id-list or a
#        title-regex (the next diagnostic-only bead, with any title, is
#        caught the same way).
#   AC4. No regression: a legitimate small-bug bead with NO formal
#        acceptance_criteria and an ordinary actionable description (no
#        disclaiming phrase) is NOT excluded — stays dispatchable. The
#        criterion this fix uses is never "has AC or doesn't pass".
#   AC5. When _filter_candidates excludes a bead for this reason, the
#        reason-trace mirror (feeding _log_exclusions, per ga-yolmi) reports
#        it as "diagnostic-only-text-pattern" — exclusion is never silent.
#   Bonus/precision: Scenario 4 proves both accented (não propõe
#        implementação) and unaccented (nao propoe implementacao) forms
#        match — both appear in the wild (ga-9n9z7's own body used the
#        unaccented form; this very bead's own AC text uses the accented
#        one). Scenario 6 proves a bare, unrelated mention of "arquitetura"
#        alone (not the full "decisão de arquitetura" phrase) does NOT
#        false-positive on an otherwise ordinary, actionable bug body.
#        Scenario 7 proves the new pattern flows through the EXISTING
#        _TEXT_VETO_PATTERNS → _reconcile_text_veto_labels side-channel for
#        free (single source of truth, ga-qt0mj's established shape) —
#        the bead also gets a visible pilot:text-veto:diagnostic-only-
#        text-pattern label, not just a log line nobody reads.
#
# Runs entirely against extracted function bodies (same sed-extraction idiom
# as pilot-dispatcher.text-veto-label.selftest.sh / .exclusion-trace.selftest.sh)
# with a PATH-shimmed fake `bd` that records calls instead of touching any
# real store. Safe on a live host — no live Dolt/bd/gc required.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-diag-veto-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
DIAGRE="$(grep '^_PILOT_DIAGNOSTIC_ONLY_RE=' "$DISPATCHER")"
TVP="$(sed -n "/^_PILOT_ENGINE_REBUILD_RE=/,/^\]')\$/p" "$DISPATCHER")"
RTV_FN="$(sed -n '/^_reconcile_text_veto_labels() {/,/^}$/p' "$DISPATCHER")"
FC_FN="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$DISPATCHER")"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"

if [ -z "$DIAGRE" ]; then
  echo "FATAL: _PILOT_DIAGNOSTIC_ONLY_RE not found in $DISPATCHER — has ga-4lsu7 landed yet? (expected on RED run)" >&2
fi
if [ -z "$FC_FN" ]; then
  echo "FATAL: _filter_candidates() not found in $DISPATCHER" >&2
  exit 2
fi

SHIMBIN="$WORK/bin"; mkdir -p "$SHIMBIN"
CALLLOG="$WORK/bd-calls.tsv"
: > "$CALLLOG"
cat > "$SHIMBIN/bd" <<SHIM
#!/usr/bin/env bash
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

# run_fc <input-json> -> sets $FC_STDOUT (surviving JSON array) and $FC_STDERR
# (the reason-trace log lines), neither printed to the caller's terminal.
run_fc() {
  local input="$1"
  cat > "$WORK/run_fc.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$DIAGRE
$TVP
$FC_FN
SELF_BEAD_ID=''
printf '%s' '$input' | _filter_candidates
EOF
  FC_STDOUT="$(bash "$WORK/run_fc.sh" 2>"$WORK/fc.stderr")"
  FC_STDERR="$(cat "$WORK/fc.stderr")"
}

# run_rtv <db> <input-json>
run_rtv() {
  local db="$1" input="$2"
  : > "$CALLLOG"
  cat > "$WORK/run_rtv.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$DIAGRE
$TVP
$RTV_FN
printf '%s' '$input' | _reconcile_text_veto_labels "$db"
EOF
  bash "$WORK/run_rtv.sh"
}

# ── build the ga-9n9z7-fidelity fixture safely (real text, real newlines/
# accents) via jq -Rs instead of hand-escaping a multi-line JSON literal.
G9N9Z7_DESC_RAW='ESCOPO DESTE BEAD: so diagnostico/rastreamento -- nao propoe
implementacao. Se algum dia valer a pena um mecanismo de override pra
commands/, e trabalho de engine Go, nao HQ shell -- decisao de arquitetura
do Mayor, nao de um dog.'
G9N9Z7_DESC_JSON="$(printf '%s' "$G9N9Z7_DESC_RAW" | jq -Rs .)"
G9N9Z7_FIXTURE="$(jq -nc --arg id "ga-9n9z7" \
  --arg title "town-deltas não tem mecanismo de override para packs/*/commands/*/run.sh" \
  --argjson desc "$G9N9Z7_DESC_JSON" \
  '[{id:$id, assignee:null, labels:["area:infra","ctx:ready","exec:auto"], title:$title, description:$desc}]')"

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1: AC1+AC2 — ga-9n9z7's real body is excluded (RED pre-fix / GREEN post-fix)"
run_fc "$G9N9Z7_FIXTURE"
if echo "$FC_STDOUT" | jq -e '[.[].id] | index("ga-9n9z7")' >/dev/null 2>&1; then
  bad "AC1: ga-9n9z7's fixture (empty AC, explicit 'nao propoe implementacao') was NOT excluded — still dispatchable (output: $FC_STDOUT)"
else
  ok "AC1: ga-9n9z7's fixture correctly excluded from dispatchable output"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2: AC3 — different id AND different title, same disclaiming phrase in body → still excluded"
IN2='[{"id":"ga-totally-different-id","assignee":null,"labels":[],"title":"completely unrelated title about something else entirely","description":"Body text explaining a finding. Escopo: apenas diagnostico -- nao propoe implementacao nenhuma aqui. Decisao de arquitetura pendente."}]'
run_fc "$IN2"
if echo "$FC_STDOUT" | jq -e '[.[].id] | index("ga-totally-different-id")' >/dev/null 2>&1; then
  bad "AC3: a bead with an unrelated id/title but the same disclaiming phrase was NOT excluded — check is keyed off id/title, not body (output: $FC_STDOUT)"
else
  ok "AC3: exclusion follows the BODY phrase regardless of id/title — not an id-list or title-regex"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3: AC4 — legit small-bug bead, NO formal AC, ordinary actionable body → still dispatchable"
IN3='[{"id":"ga-legit-bug","assignee":null,"labels":["area:infra"],"title":"bd list --json truncates at 50 without warning","description":"bd list --json silently caps output at 50 rows with no signal in the JSON. Fix: add --limit 0 to the affected call sites and add a regression test that feeds 60+ fixture rows."}]'
run_fc "$IN3"
if echo "$FC_STDOUT" | jq -e '[.[].id] | index("ga-legit-bug")' >/dev/null 2>&1; then
  ok "AC4: legit AC-less bug bead (no disclaiming phrase) stays dispatchable — no regression"
else
  bad "AC4: REGRESSION — a legit small-bug bead with no formal AC was wrongly excluded (output: $FC_STDOUT). The criterion must never be bare AC-absence."
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4: accent tolerance — both accented and unaccented phrase forms match"
IN4A='[{"id":"ga-unaccented","assignee":null,"labels":[],"title":"x","description":"nao propoe implementacao, e so diagnostico"}]'
IN4B='[{"id":"ga-accented","assignee":null,"labels":[],"title":"x","description":"não propõe implementação, é só diagnóstico"}]'
for pair in "IN4A:ga-unaccented:unaccented" "IN4B:ga-accented:accented"; do
  varname="${pair%%:*}"; rest="${pair#*:}"; expect_id="${rest%%:*}"; label="${rest#*:}"
  fixture="${!varname}"
  run_fc "$fixture"
  if echo "$FC_STDOUT" | jq -e --arg id "$expect_id" '[.[].id] | index($id)' >/dev/null 2>&1; then
    bad "accent-tolerance ($label): expected exclusion, bead survived (output: $FC_STDOUT)"
  else
    ok "accent-tolerance: $label phrase form correctly excluded"
  fi
done

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5: AC5 — exclusion reason is logged (never silent), via the _log_exclusions trace mirror"
run_fc "$G9N9Z7_FIXTURE"
if grep -qF "ga-9n9z7" <<<"$FC_STDERR" && grep -qF "diagnostic-only-text-pattern" <<<"$FC_STDERR"; then
  ok "AC5: exclusion of ga-9n9z7 is logged with reason 'diagnostic-only-text-pattern' (not silent)"
else
  bad "AC5: expected a logged exclusion reason mentioning ga-9n9z7 + diagnostic-only-text-pattern — stderr: $FC_STDERR"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 6: precision — bare 'arquitetura' mention (not the full phrase) does NOT false-positive"
IN6='[{"id":"ga-arch-word","assignee":null,"labels":[],"title":"refactor module architecture for testability","description":"This bug fixes a real defect in the arquitetura of the retry loop. Fix: extract the retry helper into its own function and add a unit test."}]'
run_fc "$IN6"
if echo "$FC_STDOUT" | jq -e '[.[].id] | index("ga-arch-word")' >/dev/null 2>&1; then
  ok "precision: bare 'arquitetura'/'architecture' mention (not the full disclaiming phrase) does NOT false-positive"
else
  bad "precision: OVER-MATCH — a legit bug merely mentioning architecture was wrongly excluded (output: $FC_STDOUT)"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 7: the new pattern flows through _TEXT_VETO_PATTERNS -> _reconcile_text_veto_labels for free"
IN7='[{"id":"ga-diag-label","labels":[],"title":"x","description":"nao propoe implementacao nenhuma, so diagnostico"}]'
run_rtv /fake/db "$IN7"
grep -qF "$(printf '/fake/db\tadd\tga-diag-label\tpilot:text-veto:diagnostic-only-text-pattern')" "$CALLLOG" \
  && ok "diagnostic label side-channel: pilot:text-veto:diagnostic-only-text-pattern ADDED via the existing single-source-of-truth mechanism" \
  || bad "diagnostic label side-channel missing — new pattern not wired into _TEXT_VETO_PATTERNS (calllog: $(cat "$CALLLOG"))"

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
