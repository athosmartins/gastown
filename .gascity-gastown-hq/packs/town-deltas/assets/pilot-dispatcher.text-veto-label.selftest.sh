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
#   AC10. ga-fgdmol: reachability through the REAL production chain ORDER.
#        At all 19 real call sites, this function used to be chained AFTER
#        _filter_candidates (`_filter_candidates | _reconcile_text_veto_labels
#        "<db>"`) — but _filter_candidates' own select already drops a
#        text-veto-matching bead from its stdout before this function ever
#        saw it as stdin, making its "add" branch structurally unreachable in
#        production even though every scenario above (which invokes it
#        directly on raw fixtures) passed green. Fixed by reordering to
#        `_reconcile_text_veto_labels "<db>" | _filter_candidates` at all 19
#        sites — mirroring ga-iu3xc5's own Scenario 7/8, which proved the
#        identical shape for the sibling _reconcile_empty_description_signal.
#        Scenario 9 proves the FIXED order lets the label reach bd for real;
#        Scenario 10 is the negative control proving the OLD order does not
#        (documents why the reorder was necessary, not a bug in this fix).
#   AC11. Structural: the LIVE file itself has zero call sites remaining in
#        the old (unreachable) order and exactly 19 in the fixed order. AC10
#        proves the two orderings behave differently in principle; AC11 is
#        what actually proves the shipped script was edited — a passing AC10
#        alone would not have caught the original bug, since the functions
#        always composed correctly in isolation regardless of which order
#        production actually wired them in.
#
# ga-i00xl: the label above was the ONLY signal a text veto ever produced —
# diagnostic-only ON PURPOSE (see the design-trap comment directly above
# _reconcile_text_veto_labels in the shipped file), never surfaced to a
# human. Measured cost: ga-dv2gk/ga-42mlf sat 7+ days in Aprovadas with
# nothing visible but this label. AC12-AC17 prove the fix — mirroring
# _reconcile_empty_description_signal (ga-iu3xc5), this function's own
# sibling directly below it in the shipped file, which already solved this
# exact "label alone is invisible" problem the same way.
#   AC12. An ADD transition (new occurrence) posts a bd comment on the bead
#        explaining which pattern matched — the veto becomes visible ON THE
#        BEAD, not only in the Pilot's log.
#   AC13. A REMOVE transition (self-clear) stays silent — no comment, no
#        mail. Self-clearing is not a new problem; nothing to notice.
#   AC14. Already-correct steady state (AC3's shape) produces ZERO new
#        comment/mail calls — no repeat noise on a healthy sweep.
#   AC15. DRY_RUN=1 produces zero comment/mail calls, same as it produces
#        zero label calls (AC4) — a dry run must never have side effects.
#   AC16. Mail routes to the CREATOR when resolvable against the configured
#        agent roster (prefix match, same discipline as ga-iu3xc5), and
#        falls back to the Mayor when it is not — never both.
#   AC17. A bd label-write FAILURE skips comment+mail entirely — notifying
#        without the label actually landing would let the NEXT sweep see an
#        unlabeled-but-already-notified bead and fire a second notice for
#        the same occurrence (identical safeguard to ga-iu3xc5's).
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
# ga-vmn7kv: _filter_candidates' select now also references $framework_markers
# (--argjson) — without this, the whole jq call errors (empty --argjson is
# invalid JSON) and every scenario below silently collapses to "[]". Absolute
# $SELF_DIR path, not a literal copy of the dispatcher's own BASH_SOURCE-
# relative source line: BASH_SOURCE does not point at this directory inside
# a `bash -c "..."` subprocess.
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"

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
COMMENTLOG="$WORK/bd-comments.tsv"
MAILLOG="$WORK/gc-mail.tsv"
: > "$CALLLOG"
: > "$COMMENTLOG"
: > "$MAILLOG"

# ga-i00xl: factored into a function (not a one-shot heredoc) because
# Scenario 17 below needs to temporarily swap in a failing `bd` and then
# restore this exact shim afterward — a single source of truth avoids the
# two copies drifting apart the way ga-w3vn3/ga-ffop9 warn about elsewhere
# in this file for the real pattern literals.
install_bd_shim() {
  cat > "$SHIMBIN/bd" <<SHIM
#!/usr/bin/env bash
# Records every 'bd -C <db> label <verb> <id> <label> ...' call and every
# 'bd -C <db> comment <id> <text>' call instead of touching any real store.
# Anything else returns an empty JSON array.
if [ "\$1" = "-C" ]; then
  db="\$2"
  if [ "\$3" = "label" ]; then
    printf '%s\t%s\t%s\t%s\n' "\$db" "\$4" "\$5" "\$6" >> "$CALLLOG"
    exit 0
  fi
  if [ "\$3" = "comment" ]; then
    printf '%s\t%s\t%s\n' "\$db" "\$4" "\$5" >> "$COMMENTLOG"
    exit 0
  fi
fi
echo '[]'
SHIM
  chmod +x "$SHIMBIN/bd"
}
install_bd_shim

# ga-i00xl: fake `gc` — records 'gc agent list --json' (answered from a
# fixed roster fixture) and 'gc --city <city> mail send <target> -s <subj>
# -m <body>' calls, matching _reconcile_empty_description_signal's exact
# call shape (ga-iu3xc5) so both functions stay comparable under test.
AGENTS_JSON="$WORK/agents.json"
cat > "$AGENTS_JSON" <<'ROSTER'
{"agents":[{"name":"gastown.mayor"},{"name":"digo-wa"},{"name":"gastown.dog-3"}]}
ROSTER
cat > "$SHIMBIN/gc" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "agent" ] && [ "\$2" = "list" ]; then
  cat "$AGENTS_JSON"
  exit 0
fi
if [ "\$1" = "--city" ] && [ "\$3" = "mail" ] && [ "\$4" = "send" ]; then
  target="\$5"; shift 5
  subj=""; body=""
  while [ \$# -gt 0 ]; do
    case "\$1" in
      -s) subj="\$2"; shift 2 ;;
      -m) body="\$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s\t%s\t%s\n' "\$target" "\$subj" "\$body" >> "$MAILLOG"
  exit 0
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/gc"

run_rtv() {
  # run_rtv <db> <input-json> [extra-env-line]
  local db="$1" input="$2" extra="${3:-}"
  : > "$CALLLOG"
  : > "$COMMENTLOG"
  : > "$MAILLOG"
  cat > "$WORK/run.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
export GC_CITY="/fake/city"
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
$FMS
$FML
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
echo "Scenario 9: AC10 (the critical one) — reachable through the REAL production chain (fixed order)"
echo "  _reconcile_text_veto_labels \"<db>\" | _filter_candidates"
echo "  (this is the exact ordering shipped at all 19 real call sites, post ga-fgdmol)"
: > "$CALLLOG"
cat > "$WORK/chain.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$FC_FN
$RTV_FN
SELF_BEAD_ID=''
printf '%s' '$IN1' | _reconcile_text_veto_labels /fake/db | _filter_candidates
EOF
CHAIN_OUT="$(bash "$WORK/chain.sh" 2>"$WORK/chain.stderr")"
[ "$CHAIN_OUT" = "[]" ] \
  && ok "AC10: bead still correctly excluded from the dispatchable output through the real chain (transparent — never alters what dispatches)" \
  || bad "AC10: expected [] (excluded), got: $CHAIN_OUT"
grep -qF "$(printf '/fake/db\tadd\tga-add1\tpilot:text-veto:engine-rebuild-text-pattern')" "$CALLLOG" \
  && ok "AC10: label ADD reaches bd through the FIXED production pipe ordering" \
  || bad "AC10: expected label ADD call missing through the fixed chain (calllog: $(cat "$CALLLOG")) — if this fails, the wiring order regressed to AFTER _filter_candidates"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 10: AC10 negative control — the OLD order (_filter_candidates | _reconcile_text_veto_labels,"
echo "  i.e. this function's placement before the ga-fgdmol fix) reproduces the unreachable-add defect"
echo "  this fix's reordering was chosen specifically to avoid. Not testing a bug in THIS fix — proving"
echo "  the design rationale documented in this function's header."
: > "$CALLLOG"
cat > "$WORK/wrongorder.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$FC_FN
$RTV_FN
SELF_BEAD_ID=''
printf '%s' '$IN1' | _filter_candidates | _reconcile_text_veto_labels /fake/db
EOF
bash "$WORK/wrongorder.sh" >/dev/null 2>&1
[ ! -s "$CALLLOG" ] \
  && ok "AC10 negative control: confirms the OLD order (filter-then-reconcile) is unreachable — validates why ga-fgdmol reorders to reconcile-then-filter" \
  || bad "AC10 negative control: expected zero calls when wired filter-then-reconcile, got: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 11: AC11 — structural check: the LIVE file has ZERO call sites left in the old,"
echo "  unreachable order, and exactly 19 in the fixed order. This is what actually proves the"
echo "  shipped script was edited (Scenario 9/10 alone would pass regardless of live wiring, since"
echo "  the functions always compose correctly in isolation). Comment lines are excluded — this"
echo "  counts real code, not prose that happens to mention the pipe shape (this file's own header"
echo "  comment above _reconcile_text_veto_labels quotes the fixed order as an example)."
CODE_ONLY="$(grep -v '^[[:space:]]*#' "$DISPATCHER")"
OLD_ORDER_SITES="$(grep -c '_filter_candidates | _reconcile_text_veto_labels' <<<"$CODE_ONLY")"
NEW_ORDER_SITES="$(grep -c '_reconcile_text_veto_labels "[^"]*" | _filter_candidates' <<<"$CODE_ONLY")"
[ "$OLD_ORDER_SITES" = "0" ] \
  && ok "AC11: zero call sites remain wired in the old, unreachable order" \
  || bad "AC11: found $OLD_ORDER_SITES call site(s) still wired _filter_candidates | _reconcile_text_veto_labels — the bug ga-fgdmol addresses"
[ "$NEW_ORDER_SITES" = "19" ] \
  && ok "AC11: exactly 19 call sites confirmed wired in the fixed order (none lost, none duplicated)" \
  || bad "AC11: expected exactly 19 call sites in the fixed order, found $NEW_ORDER_SITES"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 12: AC12 — ga-i00xl: an ADD transition now posts a bd comment making the veto VISIBLE"
OUT12="$(run_rtv /fake/db "$IN1")"
[ "$OUT12" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
[ -s "$COMMENTLOG" ] \
  && ok "AC12: ADD transition posts a bd comment (was silent before ga-i00xl)" \
  || bad "AC12: expected a bd comment call, COMMENTLOG is empty"
grep -qF "ga-add1" "$COMMENTLOG" \
  && ok "AC12: the comment targets the right bead id" \
  || bad "AC12: comment id mismatch (commentlog: $(cat "$COMMENTLOG"))"
grep -qF "pilot:text-veto:engine-rebuild-text-pattern" "$COMMENTLOG" \
  && ok "AC12: the comment names the matched pattern's label" \
  || bad "AC12: comment does not mention the matched label (commentlog: $(cat "$COMMENTLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 13: AC13 — REMOVE (self-clear) stays silent: no comment, no mail — only ADD is a new occurrence"
run_rtv /fake/db "$IN2" > /dev/null
[ ! -s "$COMMENTLOG" ] \
  && ok "AC13: self-clearing REMOVE posts no comment (not a new problem, nothing to notice)" \
  || bad "AC13: unexpected comment on a REMOVE transition (commentlog: $(cat "$COMMENTLOG"))"
[ ! -s "$MAILLOG" ] \
  && ok "AC13: self-clearing REMOVE sends no mail" \
  || bad "AC13: unexpected mail on a REMOVE transition (maillog: $(cat "$MAILLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 14: AC14 — already-correct steady state produces ZERO comment/mail calls (extends AC3, no repeat noise)"
run_rtv /fake/db "$IN3" > /dev/null
[ ! -s "$COMMENTLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC14: healthy/already-reconciled beads produce zero comment/mail calls" \
  || bad "AC14: expected zero comment/mail, got commentlog=[$(cat "$COMMENTLOG")] maillog=[$(cat "$MAILLOG")]"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 15: AC15 — DRY_RUN=1 produces zero comment/mail calls too (extends AC4)"
run_rtv /fake/db "$IN1" "export DRY_RUN=1" >/dev/null 2>/dev/null
[ ! -s "$COMMENTLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC15: DRY_RUN=1 makes zero comment/mail calls" \
  || bad "AC15: DRY_RUN=1 still notified — commentlog=[$(cat "$COMMENTLOG")] maillog=[$(cat "$MAILLOG")]"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 16: AC16 — mail routes to the CREATOR when resolvable, else falls back to the Mayor"
IN16A='[{"id":"ga-creator-known","labels":[],"title":"x","description":"needs a gascity engine rebuild","created_by":"digo-wa-gawisp7iqcpw"}]'
run_rtv /fake/db "$IN16A" > /dev/null
grep -qF "$(printf 'digo-wa\t')" "$MAILLOG" \
  && ok "AC16: creator resolvable (prefix match) → mail routes to the creator, not the Mayor" \
  || bad "AC16: expected mail to digo-wa (maillog: $(cat "$MAILLOG"))"
grep -qF "gastown.mayor" "$MAILLOG" \
  && bad "AC16: mail should NOT also go to the Mayor when the creator resolved" \
  || ok "AC16: no duplicate Mayor mail when the creator resolved"

IN16B='[{"id":"ga-creator-unknown","labels":[],"title":"x","description":"needs a gascity engine rebuild","created_by":"someone-not-in-the-roster"}]'
run_rtv /fake/db "$IN16B" > /dev/null
# Fallback target is the literal recipient alias "mayor" (matches
# _reconcile_empty_description_signal's own `mail send mayor` call exactly
# — this path is a hardcoded alias, NOT resolved against the agent roster
# the way a matched creator is).
grep -qF "$(printf 'mayor\t')" "$MAILLOG" \
  && ok "AC16: unresolvable creator → mail falls back to the Mayor" \
  || bad "AC16: expected fallback mail to mayor (maillog: $(cat "$MAILLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 17: AC17 — a bd label FAILURE skips notification entirely (mirrors ga-iu3xc5's exact safeguard:"
echo "  never notify without the label actually landing, or the next sweep double-notifies the same occurrence)"
cat > "$SHIMBIN/bd" <<'SHIM2'
#!/usr/bin/env bash
exit 1
SHIM2
chmod +x "$SHIMBIN/bd"
run_rtv /fake/db "$IN1" >/dev/null 2>/dev/null
[ ! -s "$COMMENTLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC17: label write failure skips comment+mail (no notify-without-label)" \
  || bad "AC17: notified despite label failure — commentlog=[$(cat "$COMMENTLOG")] maillog=[$(cat "$MAILLOG")]"
install_bd_shim   # restore the real shim for anything that runs after this scenario

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
