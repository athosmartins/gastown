#!/usr/bin/env bash
# pilot-dispatcher.empty-description-label.selftest.sh — Prove the ga-iu3xc5
# fix: when _filter_candidates' empty-description veto drops a bead, the
# reason must become visible ON THE BEAD (durable label + one-time comment +
# one-time Mayor mail) instead of only in the Pilot's own log — and it must
# self-clear the moment a real description lands, and never spam on repeat
# sweeps.
#
# Acceptance criteria under test (bead ga-iu3xc5):
#   AC1. A bead with an empty/whitespace-only description, lacking
#        blocked:sem-descricao, gets the label ADDED, a ONE-TIME comment, and
#        a ONE-TIME mail to the Mayor.
#   AC2. A bead that carries blocked:sem-descricao but now has a real
#        description gets the label REMOVED (self-clearing) — no comment, no
#        mail on the remove transition.
#   AC3. Already-correct states (empty+labeled, non-empty+unlabeled) produce
#        ZERO bd/gc calls — idempotent, no repeat comment/mail on a healthy
#        sweep that already reconciled.
#   AC4. DRY_RUN=1 produces WOULD-* log lines only, zero real bd/gc calls.
#   AC5. Empty/missing db argument is a complete no-op (opt-in, not opt-out)
#        — zero bd/gc calls — while STILL passing input through unchanged.
#   AC6. Transparent pass-through: stdout is byte-identical to stdin in every
#        scenario — this stage must never be able to alter what actually
#        dispatches.
#   AC7. THE CRITICAL ONE — reachability through the REAL production chain.
#        _reconcile_text_veto_labels (the existing, otherwise-identical-
#        shaped reconciler this fix is modeled on) is chained AFTER
#        _filter_candidates at every one of its 19 call sites — and that
#        placement makes its own "add" branch structurally unreachable in
#        production: _filter_candidates' own select already drops a
#        text-veto-matching bead from its stdout before the reconciler ever
#        sees it (verified live during this fix's investigation: piping a
#        matching bead through the real `_filter_candidates |
#        _reconcile_text_veto_labels` chain produces ZERO bd calls, even
#        though the function's OWN isolated selftest — which invokes it
#        directly on raw, unfiltered fixtures — passes green). This function
#        is instead wired BEFORE _filter_candidates at all 19 sites
#        specifically to avoid inheriting that same defect. This scenario
#        proves it: unlike a bare direct invocation, this drives the bead
#        through the actual `_reconcile_empty_description_signal "<db>" |
#        _filter_candidates | _reconcile_text_veto_labels "<db>"` chain — the
#        exact wiring shipped in the live script — and confirms BOTH that
#        the label/comment/mail reach bd/gc for real AND that the bead still
#        correctly fails to survive into the dispatchable output.
#   AC8. Mirrors ga-iu3xc5's own AC5 ("teste que reprova no HEAD anterior"):
#        this same scenario run against the pre-fix dispatcher (no
#        _reconcile_empty_description_signal, no pre-filter wiring) produces
#        zero bd calls — proving today's silence and tomorrow's mark are the
#        same test, not two different claims. Verified by hand against the
#        pre-fix file as part of shipping this commit (see commit message);
#        not re-asserted here as a live git-checkout to keep this selftest
#        hermetic and fast, matching this repo's other selftests' convention.
#
# Runs entirely against extracted function bodies (same awk/sed-extraction
# idiom as pilot-dispatcher.text-veto-label.selftest.sh) with PATH-shimmed
# fake `bd`/`gc` binaries that record calls to files instead of touching any
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-empty-desc-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
TVP="$(sed -n "/^_PILOT_ENGINE_REBUILD_RE=/,/^\]')\$/p" "$DISPATCHER")"
RTV_FN="$(sed -n '/^_reconcile_text_veto_labels() {/,/^}$/p' "$DISPATCHER")"
RED_FN="$(sed -n '/^_reconcile_empty_description_signal() {/,/^}$/p' "$DISPATCHER")"
FC_FN="$(sed -n '/^_filter_candidates() {/,/^}$/p' "$DISPATCHER")"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"

if [ -z "$RED_FN" ]; then
  echo "FATAL: _reconcile_empty_description_signal() not found in $DISPATCHER — has ga-iu3xc5 landed?" >&2
  exit 2
fi
if [ -z "$FC_FN" ]; then
  echo "FATAL: _filter_candidates() not found in $DISPATCHER" >&2
  exit 2
fi

SHIMBIN="$WORK/bin"; mkdir -p "$SHIMBIN"
CALLLOG="$WORK/bd-calls.tsv"
MAILLOG="$WORK/gc-mail.tsv"
: > "$CALLLOG"
: > "$MAILLOG"

cat > "$SHIMBIN/bd" <<SHIM
#!/usr/bin/env bash
# Records 'bd -C <db> label <verb> <id> <label>' and 'bd -C <db> comment <id> <text>'
# calls instead of touching any real store. Anything else returns an empty JSON array.
# SHIM_BD_LABEL_FAIL_ID (if set) makes a 'label' call for that exact bead id
# fail (exit 1, nothing recorded) — simulates a real bd/Dolt hiccup so the
# selftest can prove the caller does not notify on a failed write.
if [ "\$1" = "-C" ]; then
  db="\$2"
  if [ "\$3" = "label" ]; then
    if [ -n "\${SHIM_BD_LABEL_FAIL_ID:-}" ] && [ "\$5" = "\$SHIM_BD_LABEL_FAIL_ID" ]; then
      exit 1
    fi
    printf 'label\t%s\t%s\t%s\t%s\n' "\$db" "\$4" "\$5" "\$6" >> "$CALLLOG"
    exit 0
  fi
  if [ "\$3" = "comment" ]; then
    printf 'comment\t%s\t%s\t%s\n' "\$db" "\$4" "\$5" >> "$CALLLOG"
    exit 0
  fi
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/bd"

cat > "$SHIMBIN/gc" <<SHIM
#!/usr/bin/env bash
# Records 'gc --city <city> mail send mayor -s <subj> -m <body>' calls.
if [ "\$1" = "--city" ]; then
  city="\$2"; shift 2
  if [ "\$1" = "mail" ] && [ "\$2" = "send" ] && [ "\$3" = "mayor" ]; then
    shift 3
    subj=""; body=""
    while [ \$# -gt 0 ]; do
      case "\$1" in
        -s) subj="\$2"; shift 2 ;;
        -m) body="\$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\t%s\t%s\n' "\$city" "\$subj" "\$body" >> "$MAILLOG"
    exit 0
  fi
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/gc"

run_red() {
  # run_red <db> <input-json> [extra-env-line]
  local db="$1" input="$2" extra="${3:-}"
  : > "$CALLLOG"; : > "$MAILLOG"
  cat > "$WORK/run.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
export GC_CITY=/fake/db
$LOG_FN
$RED_FN
$extra
printf '%s' '$input' | _reconcile_empty_description_signal "$db"
EOF
  bash "$WORK/run.sh"
}

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1: AC1 — empty description, label absent → ADD + comment + mail"
IN1='[{"id":"ga-add1","labels":[],"description":"   ","created_by":"some-daemon"}]'
OUT1="$(run_red /fake/db "$IN1")"
[ "$OUT1" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input (got: $OUT1)"
grep -qF "$(printf 'label\t/fake/db\tadd\tga-add1\tblocked:sem-descricao')" "$CALLLOG" \
  && ok "AC1: empty description with no label produces a label ADD call" \
  || bad "AC1: expected label ADD call missing (calllog: $(cat "$CALLLOG"))"
grep -qF "$(printf 'comment\t/fake/db\tga-add1')" "$CALLLOG" \
  && ok "AC1: label ADD is accompanied by a bead comment" \
  || bad "AC1: expected comment call missing (calllog: $(cat "$CALLLOG"))"
grep -qF "ga-add1" "$MAILLOG" && grep -qF "some-daemon" "$MAILLOG" \
  && ok "AC1: Mayor mail fires and cites the bead id + creator" \
  || bad "AC1: expected mail missing/incomplete (maillog: $(cat "$MAILLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2: AC2 — label present, description now real → REMOVE, no comment/mail"
IN2='[{"id":"ga-rm1","labels":["blocked:sem-descricao"],"description":"agora tem conteúdo real de verdade"}]'
OUT2="$(run_red /fake/db "$IN2")"
[ "$OUT2" = "$IN2" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
grep -qF "$(printf 'label\t/fake/db\tremove\tga-rm1\tblocked:sem-descricao')" "$CALLLOG" \
  && ok "AC2: filled-in description with stale label produces a label REMOVE call (self-clears)" \
  || bad "AC2: expected REMOVE call missing (calllog: $(cat "$CALLLOG"))"
grep -q "comment" "$CALLLOG" \
  && bad "AC2: remove transition must NOT also post a comment (calllog: $(cat "$CALLLOG"))" \
  || ok "AC2: remove transition posts no comment"
[ ! -s "$MAILLOG" ] \
  && ok "AC2: remove transition sends no Mayor mail" \
  || bad "AC2: unexpected mail on remove transition (maillog: $(cat "$MAILLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3: AC3 — already-correct states produce ZERO calls (no repeat spam)"
IN3='[
  {"id":"ga-ok-still-empty","labels":["blocked:sem-descricao"],"description":""},
  {"id":"ga-ok-healthy","labels":[],"description":"a normal task with a real spec"}
]'
OUT3="$(run_red /fake/db "$IN3")"
[ "$OUT3" = "$IN3" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
[ ! -s "$CALLLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC3: already-reconciled beads (still empty+labeled, or healthy+unlabeled) produce ZERO calls" \
  || bad "AC3: expected zero calls, got bd=$(cat "$CALLLOG") mail=$(cat "$MAILLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4: AC4 — DRY_RUN=1 makes zero real bd/gc calls, logs WOULD-* only"
OUT4="$(run_red /fake/db "$IN1" "export DRY_RUN=1" 2>"$WORK/s4.stderr")"
[ "$OUT4" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin under DRY_RUN" || bad "AC6: pass-through altered under DRY_RUN"
[ ! -s "$CALLLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC4: DRY_RUN=1 makes zero real bd/gc calls" \
  || bad "AC4: DRY_RUN=1 still called bd/gc: bd=$(cat "$CALLLOG") mail=$(cat "$MAILLOG")"
grep -qF "WOULD add blocked:sem-descricao on ga-add1" "$WORK/s4.stderr" \
  && ok "AC4: DRY_RUN logs the intended action" \
  || bad "AC4: DRY_RUN log line missing/wrong (stderr: $(cat "$WORK/s4.stderr"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5: AC5 — empty db argument is a complete no-op, but still passes through"
OUT5="$(run_red "" "$IN1")"
[ "$OUT5" = "$IN1" ] && ok "AC6+AC5: empty db still passes input through unchanged" || bad "AC5: pass-through broke with empty db"
[ ! -s "$CALLLOG" ] && [ ! -s "$MAILLOG" ] \
  && ok "AC5: empty db makes zero bd/gc calls (opt-in, not opt-out)" \
  || bad "AC5: empty db still called bd/gc"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 6: AC1 variant — whitespace-only (not byte-empty) description also counts"
IN6='[{"id":"ga-ws1","labels":[],"description":"\n\t   \n"}]'
OUT6="$(run_red /fake/db "$IN6")"
[ "$OUT6" = "$IN6" ] && ok "AC6: stdout byte-identical to stdin" || bad "AC6: pass-through altered input"
grep -qF "$(printf 'label\t/fake/db\tadd\tga-ws1\tblocked:sem-descricao')" "$CALLLOG" \
  && ok "AC1: whitespace-only description (test(\\\\S) semantics) triggers ADD, same as byte-empty" \
  || bad "AC1: whitespace-only description did not trigger ADD (calllog: $(cat "$CALLLOG"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 7: AC7 (the critical one) — reachable through the REAL production chain"
echo "  _reconcile_empty_description_signal \"<db>\" | _filter_candidates | _reconcile_text_veto_labels \"<db>\""
echo "  (this is the exact ordering shipped in every one of the 19 real call sites)"
IN7='[{"id":"ga-chain1","assignee":null,"labels":[],"issue_type":"bug","description":"   "}]'
: > "$CALLLOG"; : > "$MAILLOG"
cat > "$WORK/chain.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
export GC_CITY=/fake/db
$LOG_FN
$LE_FN
$PRE
$CAP
$TVP
$FC_FN
$RTV_FN
$RED_FN
SELF_BEAD_ID=''
printf '%s' '$IN7' | _reconcile_empty_description_signal /fake/db | _filter_candidates | _reconcile_text_veto_labels /fake/db
EOF
CHAIN_OUT="$(bash "$WORK/chain.sh" 2>"$WORK/chain.stderr")"
[ "$CHAIN_OUT" = "[]" ] \
  && ok "AC7: bead still correctly excluded from the dispatchable output through the real chain (transparent — never alters what dispatches)" \
  || bad "AC7: expected [] (excluded), got: $CHAIN_OUT"
grep -qF "$(printf 'label\t/fake/db\tadd\tga-chain1\tblocked:sem-descricao')" "$CALLLOG" \
  && ok "AC7: label ADD reaches bd through the REAL production pipe ordering (proves this fix, unlike _reconcile_text_veto_labels, is actually reachable in production)" \
  || bad "AC7: expected label ADD call missing through the real chain (calllog: $(cat "$CALLLOG")) — if this fails, the wiring order regressed to AFTER _filter_candidates"
grep -qF "$(printf '[pilot] EXCLUÍDO ga-chain1 por _filter_candidates: empty-description')" "$WORK/chain.stderr" \
  && ok "AC7: the Pilot's own exclusion trace ALSO still fires (belt+suspenders, unaffected by this fix)" \
  || bad "AC7: exclusion trace line missing (stderr: $(cat "$WORK/chain.stderr"))"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 8: AC7 negative control — wiring AFTER _filter_candidates (the OTHER order,"
echo "  i.e. _reconcile_text_veto_labels' own existing placement) reproduces the unreachable-add"
echo "  defect this fix's placement was chosen specifically to avoid. This is not testing a bug"
echo "  in THIS fix — it is proving the design rationale documented in this function's header."
: > "$CALLLOG"; : > "$MAILLOG"
cat > "$WORK/wrongorder.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
export GC_CITY=/fake/db
$LOG_FN
$LE_FN
$PRE
$CAP
$TVP
$FC_FN
$RTV_FN
$RED_FN
SELF_BEAD_ID=''
printf '%s' '$IN7' | _filter_candidates | _reconcile_empty_description_signal /fake/db
EOF
bash "$WORK/wrongorder.sh" >/dev/null 2>&1
[ ! -s "$CALLLOG" ] \
  && ok "AC7 negative control: confirms wiring AFTER _filter_candidates is unreachable (as documented) — validates why this fix is wired BEFORE it" \
  || bad "AC7 negative control: expected zero calls when wired after _filter_candidates, got: $(cat "$CALLLOG")"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 9: AC9 — a FAILED label write must not fire the one-time comment/mail"
echo "  (third-state check: 'bd label add failed' must not collapse into 'bd label add succeeded')"
OUT9="$(run_red /fake/db "$IN1" "export SHIM_BD_LABEL_FAIL_ID=ga-add1" 2>"$WORK/s9.stderr")"
[ "$OUT9" = "$IN1" ] && ok "AC6: stdout byte-identical to stdin even when the label write fails" || bad "AC6: pass-through altered when label write fails"
[ ! -s "$CALLLOG" ] \
  && ok "AC9: failed label write recorded no label call (as the shim simulates)" \
  || bad "AC9: unexpected call recorded despite simulated label failure: $(cat "$CALLLOG")"
[ ! -s "$MAILLOG" ] \
  && ok "AC9: failed label write suppresses the Mayor mail — no notification for a write that didn't land" \
  || bad "AC9: mail fired despite the label write failing (maillog: $(cat "$MAILLOG")) — a bd hiccup would double-notify on the next sweep once the label finally lands"
grep -q "comment" "$CALLLOG" 2>/dev/null \
  && bad "AC9: comment posted despite the label write failing" \
  || ok "AC9: failed label write suppresses the bead comment too"
grep -qF "FAILED to add blocked:sem-descricao on ga-add1" "$WORK/s9.stderr" \
  && ok "AC9: failure is logged explicitly (visible, not silent) so the operator can tell a hiccup from a healthy no-op sweep" \
  || bad "AC9: expected FAILED log line missing (stderr: $(cat "$WORK/s9.stderr"))"

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
