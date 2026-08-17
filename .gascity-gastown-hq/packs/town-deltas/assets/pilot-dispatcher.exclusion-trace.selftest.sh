#!/usr/bin/env bash
# pilot-dispatcher.exclusion-trace.selftest.sh — Prove the ga-yolmi PASSO 1 defense:
# every _filter_* stage in the Pilot's dispatch chain must log ONE line per bead it
# drops, naming the bead id, the filter, and the specific reason — WITHOUT changing
# what actually gets dispatched.
#
# Story ga-yolmi (PASSO 1 of épico ga-05604, class root-class:error-vs-empty): before
# this fix, an aggregate "dispatched=0" or a bead missing from the candidate pool gave
# no trail — diagnosis meant manually replaying the jq filter chain by hand (ga-f7bek:
# ~2h to find a single next-action: label veto; ga-kcda5 similarly).
#
# Acceptance criteria under test:
#   AC1. A bead that IS excluded produces a log line naming bead + filter + reason.
#        Concrete regression: the ga-f7bek scenario (next-action: label) — see
#        Scenario 3 below, which reproduces it against the CURRENT (already-fixed)
#        _filter_dispatch_gates semantics: a bare next-action:<actor> still vetoes
#        (must log), while next-action:<crew>-constroi/-reconstroi/-corrige-gate
#        (the ga-f7bek routing-label fix) must NOT veto and must NOT log (AC4).
#   AC2. Healthy sweep (nothing excluded) → zero exclusion-trace log lines.
#   AC3. ZERO dispatch-behavior change: every filter's JSON stdout, byte for byte,
#        is identical between the pre-patch (git HEAD) file and the patched file,
#        across the same fixtures used to exercise the new logging.
#   AC4. A bead that passes ALL filters (truly buildable) produces NO exclusion line
#        (never confuse "passed" with "was excluded by something").
#
# Runs entirely against extracted function bodies (via the same awk/sed-extraction
# idiom pilot-dispatcher.selftest.sh already uses for _filter_built etc.) with no
# live Dolt/bd/git required for the pure-jq filters; _filter_unblocked and
# _filter_explicit_deps get minimal PATH-shimmed `bd` fakes. Safe on a live host.
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"
ORIG_DISPATCHER="${ORIG_DISPATCHER:-}"   # optional: pre-patch file for AC3 differential

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-exclusion-trace-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$DISPATCHER")"
if [ -z "$LE_FN" ]; then
  echo "FATAL: _log_exclusions() not found in $DISPATCHER — has ga-yolmi PASSO 1 landed?" >&2
  exit 2
fi

extract_fn() { sed -n "/^$1() {/,/^}\$/p" "$DISPATCHER"; }

# ════════════════════════════════════════════════════════════════════════════
echo "Scenario 1: _filter_candidates — mixed drop reasons (AC1 + AC4)"
FC_FN="$(extract_fn _filter_candidates)"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
# ga-qt0mj: _filter_candidates' local _cf_engine_rebuild_re now references this
# script-level global (single source of truth, ga-ffop9) — omitting it here
# leaves the var unbound under set -u, aborting _filter_candidates entirely.
TVP="$(grep '^_PILOT_ENGINE_REBUILD_RE=' "$DISPATCHER")"
# ga-vmn7kv: same reason as PRE/CAP/TVP above — _filter_candidates' select now
# also references $framework_markers (--argjson), so the source line plus the
# derived JSON array both need extracting alongside it, or the whole jq call
# errors out (empty --argjson is invalid JSON) and every scenario below
# silently collapses to "[]" regardless of its own fixture. NOT a literal copy
# of the dispatcher's own source line: that one resolves
# $(dirname "${BASH_SOURCE[0]}") relative to itself, which is correct in the
# real dispatcher but resolves to $WORK (the extracted script's temp-file
# location) here instead of this directory — inject an absolute path using
# this harness's own already-correct $SELF_DIR instead.
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"
cat > "$WORK/s1.sh" <<EOF
$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$FC_FN
SELF_BEAD_ID=""
INPUT='[
  {"id":"ga-pass1","assignee":null,"labels":[],"description":"a real task with content"},
  {"id":"ga-assigned","assignee":"someone","labels":[],"description":"x"},
  {"id":"ga-blocked-human","assignee":null,"labels":["gate:needs-human:mayor-fixing"],"description":"x"},
  {"id":"ga-empty-desc","assignee":null,"labels":[],"description":""}
]'
printf '%s' "\$INPUT" | _filter_candidates
EOF
S1_OUT="$(bash "$WORK/s1.sh" 2>"$WORK/s1.stderr")"
S1_IDS="$(printf '%s' "$S1_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S1_IDS" = '["ga-pass1"]' ] \
  && ok "_filter_candidates keeps only the passing bead (dispatch output correct)" \
  || bad "_filter_candidates output wrong (got: '$S1_IDS')"

grep -qF '[pilot] EXCLUÍDO ga-assigned por _filter_candidates: assignee:someone' "$WORK/s1.stderr" \
  && ok "AC1: ga-assigned exclusion logged with id+filter+specific reason" \
  || bad "AC1: ga-assigned exclusion line missing/wrong"
grep -qF '[pilot] EXCLUÍDO ga-blocked-human por _filter_candidates: blocking-label:gate:needs-human:mayor-fixing' "$WORK/s1.stderr" \
  && ok "AC1: ga-blocked-human exclusion names the specific blocking label" \
  || bad "AC1: ga-blocked-human exclusion line missing/wrong"
grep -qF '[pilot] EXCLUÍDO ga-empty-desc por _filter_candidates: empty-description' "$WORK/s1.stderr" \
  && ok "AC1: ga-empty-desc exclusion logged" \
  || bad "AC1: ga-empty-desc exclusion line missing"
grep -qF 'ga-pass1' "$WORK/s1.stderr" \
  && bad "AC4: the PASSING bead ga-pass1 must not appear in the exclusion trace at all" \
  || ok "AC4: passing bead ga-pass1 produces no exclusion line"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 2: _filter_exec_manual (AC1 + AC4)"
EM_FN="$(extract_fn _filter_exec_manual)"
cat > "$WORK/s2.sh" <<EOF
$LOG_FN
$LE_FN
$EM_FN
INPUT='[{"id":"ga-manual","labels":["exec:manual"]},{"id":"ga-auto","labels":["exec:auto"]}]'
printf '%s' "\$INPUT" | _filter_exec_manual
EOF
S2_OUT="$(bash "$WORK/s2.sh" 2>"$WORK/s2.stderr")"
S2_IDS="$(printf '%s' "$S2_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S2_IDS" = '["ga-auto"]' ] \
  && ok "_filter_exec_manual keeps the exec:auto bead, drops exec:manual" \
  || bad "_filter_exec_manual output wrong (got: '$S2_IDS')"
grep -qF '[pilot] EXCLUÍDO ga-manual por _filter_exec_manual: label:exec:manual' "$WORK/s2.stderr" \
  && ok "AC1: ga-manual exclusion logged" || bad "AC1: ga-manual exclusion line missing"
grep -qF 'ga-auto' "$WORK/s2.stderr" \
  && bad "AC4: ga-auto must not appear in the exclusion trace" \
  || ok "AC4: passing bead ga-auto produces no exclusion line"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 3: _filter_dispatch_gates — ga-f7bek concrete regression (AC1 + AC4)"
# ga-f7bek: refino's crew-routing convention next-action:<crew>-constroi/-reconstroi/
# -corrige-gate means READY (routing, not blocking) and must NOT veto. A bare
# next-action:<actor> (no build-verb suffix) is the ORIGINAL, still-blocking meaning
# and MUST veto. This scenario proves the new trace fires on the real blocker and
# stays silent on the routing label — exactly the distinction ga-f7bek needed.
DG_FN="$(extract_fn _filter_dispatch_gates)"
cat > "$WORK/s3.sh" <<EOF
$LOG_FN
$LE_FN
$DG_FN
INPUT='[
  {"id":"ga-still-blocked","status":"open","description":"a real task with enough spec text here","labels":["next-action:mayor"]},
  {"id":"wa-lxe76","status":"open","description":"a real task with enough spec text here","labels":["next-action:batista-constroi"]},
  {"id":"ga-waiting","status":"open","description":"a real task with enough spec text here","labels":["waiting-on:athos"]}
]'
printf '%s' "\$INPUT" | _filter_dispatch_gates
EOF
S3_OUT="$(bash "$WORK/s3.sh" 2>"$WORK/s3.stderr")"
S3_IDS="$(printf '%s' "$S3_OUT" | jq -c '[.[].id] | sort' 2>/dev/null)"
[ "$S3_IDS" = '["wa-lxe76"]' ] \
  && ok "_filter_dispatch_gates: bare next-action vetoes, crew-routing next-action:*-constroi passes (ga-f7bek fix intact)" \
  || bad "_filter_dispatch_gates output wrong (got: '$S3_IDS')"
grep -qF '[pilot] EXCLUÍDO ga-still-blocked por _filter_dispatch_gates:' "$WORK/s3.stderr" \
  && grep -qF 'blocking-label:next-action:mayor' "$WORK/s3.stderr" \
  && ok "AC1 (ga-f7bek regression): bare next-action:mayor veto now names the exact label" \
  || bad "AC1: ga-still-blocked exclusion line missing/imprecise"
grep -qF '[pilot] EXCLUÍDO ga-waiting por _filter_dispatch_gates:' "$WORK/s3.stderr" \
  && grep -qF 'blocking-label:waiting-on:athos' "$WORK/s3.stderr" \
  && ok "AC1: waiting-on:athos veto names the exact label" \
  || bad "AC1: ga-waiting exclusion line missing/imprecise"
grep -qF 'wa-lxe76' "$WORK/s3.stderr" \
  && bad "AC4: wa-lxe76 (crew-routing label, NOT a real veto) must not appear in the exclusion trace" \
  || ok "AC4: routing-label bead wa-lxe76 produces no exclusion line (ga-f7bek fix not regressed)"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 4: _filter_built — branch-built + in-gate (AC1 + AC4)"
FB_FN="$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} /^_beadid_has_open_gate_marker\(\)/{f=1} /^_filter_built\(\)/{f=1} f{print} f&&/^}$/{f=0}' "$DISPATCHER")"
cat > "$WORK/s4.sh" <<EOF
$LOG_FN
$LE_FN
$FB_FN
export PILOT_TEST_BRANCH_BEADS="ga-built"
export PILOT_TEST_GATE_OPEN_BEADS=""
export PILOT_TEST_GATE_ACTIVE_BEADS=""
INPUT='[{"id":"ga-built","labels":[]},{"id":"ga-fresh","labels":[]},{"id":"ga-ingate","labels":["gate:reviewing"]}]'
printf '%s' "\$INPUT" | _filter_built
EOF
S4_OUT="$(bash "$WORK/s4.sh" 2>"$WORK/s4.stderr")"
S4_IDS="$(printf '%s' "$S4_OUT" | jq -c '[.[].id] | sort' 2>/dev/null)"
[ "$S4_IDS" = '["ga-fresh"]' ] \
  && ok "_filter_built drops the branch-built and in-gate beads, keeps the fresh one" \
  || bad "_filter_built output wrong (got: '$S4_IDS')"
grep -qF '[pilot] EXCLUÍDO ga-built por _filter_built:' "$WORK/s4.stderr" \
  && grep -qF 'branch exists (PILOT_TEST_BRANCH_BEADS test seam)' "$WORK/s4.stderr" \
  && ok "AC1: ga-built exclusion names the branch-exists reason" \
  || bad "AC1: ga-built exclusion line missing/imprecise"
grep -qF '[pilot] EXCLUÍDO ga-ingate por _filter_built:' "$WORK/s4.stderr" \
  && grep -qF 'gate:* lifecycle label present' "$WORK/s4.stderr" \
  && ok "AC1: ga-ingate exclusion names the gate-label reason" \
  || bad "AC1: ga-ingate exclusion line missing/imprecise"
grep -qF 'ga-fresh' "$WORK/s4.stderr" \
  && bad "AC4: ga-fresh must not appear in the exclusion trace" \
  || ok "AC4: fresh bead ga-fresh produces no exclusion line"

echo ""
echo "Scenario 4b: _filter_built — gate:needs-fix carve-out must stay silent (AC4, deadlock guard)"
cat > "$WORK/s4b.sh" <<EOF
$LOG_FN
$LE_FN
$FB_FN
export PILOT_TEST_BRANCH_BEADS="ga-refix"
export PILOT_TEST_GATE_OPEN_BEADS=""
export PILOT_TEST_GATE_ACTIVE_BEADS=""
INPUT='[{"id":"ga-refix","labels":["gate:needs-fix"]}]'
printf '%s' "\$INPUT" | _filter_built
EOF
S4B_OUT="$(bash "$WORK/s4b.sh" 2>"$WORK/s4b.stderr")"
S4B_IDS="$(printf '%s' "$S4B_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S4B_IDS" = '["ga-refix"]' ] \
  && ok "_filter_built KEEPS gate:needs-fix bead despite its own fix-branch (re-fix loop preserved)" \
  || bad "_filter_built gate:needs-fix carve-out broke (got: '$S4B_IDS')"
[ -s "$WORK/s4b.stderr" ] \
  && bad "AC4: gate:needs-fix carve-out bead must NOT be logged as excluded (it wasn't excluded)" \
  || ok "AC4: gate:needs-fix carve-out produces no exclusion line"

echo ""
echo "Scenario 4c: _filter_built — gate:prod-deploy:* is a post-deploy checklist item, NOT a gate-cycle state (ga-ds3bl)"
# Regression for ga-ds3bl: gate:prod-deploy:needs-athos-test shares the gate:
# prefix with real gate-cycle labels (gate:queued/reviewing/passed/...) but
# means something unrelated ("Athos tests in prod post-deploy"). Before the
# fix, _filter_built's prefix-match treated it as "already built" and starved
# the bead forever (label never clears). A REAL gate-cycle label (gate:reviewing)
# rides along in the same batch to prove the carve-out doesn't leak and mask
# a bead that IS actually in the gate.
cat > "$WORK/s4c.sh" <<EOF
$LOG_FN
$LE_FN
$FB_FN
export PILOT_TEST_BRANCH_BEADS=""
export PILOT_TEST_GATE_OPEN_BEADS=""
export PILOT_TEST_GATE_ACTIVE_BEADS=""
INPUT='[{"id":"ga-postdeploy","labels":["story:approved","gate:prod-deploy:needs-athos-test"]},{"id":"ga-ingate2","labels":["gate:reviewing"]}]'
printf '%s' "\$INPUT" | _filter_built
EOF
S4C_OUT="$(bash "$WORK/s4c.sh" 2>"$WORK/s4c.stderr")"
S4C_IDS="$(printf '%s' "$S4C_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S4C_IDS" = '["ga-postdeploy"]' ] \
  && ok "_filter_built KEEPS gate:prod-deploy:* bead (not a gate-cycle state) while still dropping the real gate:reviewing bead" \
  || bad "_filter_built gate:prod-deploy carve-out broke (got: '$S4C_IDS')"
grep -qF 'ga-postdeploy' "$WORK/s4c.stderr" \
  && bad "AC4: ga-postdeploy must NOT be logged as excluded (gate:prod-deploy is not a gate-cycle label)" \
  || ok "AC4: gate:prod-deploy:* carve-out produces no exclusion line"
grep -qF '[pilot] EXCLUÍDO ga-ingate2 por _filter_built:' "$WORK/s4c.stderr" \
  && grep -qF 'gate:* lifecycle label present' "$WORK/s4c.stderr" \
  && ok "AC1: ga-ingate2 (real gate:reviewing) still excluded — carve-out doesn't leak into true gate-cycle labels" \
  || bad "AC1: ga-ingate2 exclusion line missing/imprecise — gate:prod-deploy carve-out may have broken real gate detection"

echo ""
echo "Scenario 4d: gate-resident lane accounting — same ga-ds3bl carve-out, second (more subtle) occurrence"
# ga-ds3bl's own analysis: the identical prefix-match predicate is DUPLICATED
# at the IN_FLIGHT_GATE_RESIDENT_JSON computation (lane-cap accounting), and a
# missed carve-out there has a DIFFERENT effect than in _filter_built: a bead
# that is actually still BUILDING (only carrying gate:prod-deploy:*, never a
# real gate-cycle label) would be miscounted as "already in the gate" and have
# its lane slot freed for another bead — overbooking the lane while a builder
# is still working it. Extracted VERBATIM (not retyped) so this can't drift
# from the shipped statement.
GR_STMT="$(sed -n '/^IN_FLIGHT_GATE_RESIDENT_JSON=/,/2>\/dev\/null || echo "\[\]")/p' "$DISPATCHER")"
if [ -z "$GR_STMT" ]; then
  bad "Scenario 4d: could not extract IN_FLIGHT_GATE_RESIDENT_JSON statement from $DISPATCHER — has it been renamed/refactored?"
else
  S4D_RESULT="$(bash -c "
IN_FLIGHT_JSON='[{\"id\":\"ga-postdeploy\",\"labels\":[\"gate:prod-deploy:needs-athos-test\"]},{\"id\":\"ga-ingate3\",\"labels\":[\"gate:reviewing\"]},{\"id\":\"ga-plain\",\"labels\":[]}]'
$GR_STMT
printf '%s' \"\$IN_FLIGHT_GATE_RESIDENT_JSON\"
" 2>/dev/null)"
  S4D_IDS="$(printf '%s' "$S4D_RESULT" | jq -c '[.[].id]' 2>/dev/null)"
  [ "$S4D_IDS" = '["ga-ingate3"]' ] \
    && ok "gate-resident accounting excludes gate:prod-deploy:* (builder keeps its lane slot) while still counting the real gate:reviewing bead" \
    || bad "gate-resident accounting regression (got: '$S4D_IDS', want: '[\"ga-ingate3\"]') — a gate:prod-deploy:* bead would wrongly free its lane slot mid-build"
fi

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 5: _filter_unblocked (AC1 + AC4, fake bd shim)"
SHIMBIN="$WORK/bin"; mkdir -p "$SHIMBIN"
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "blocked" ] || { [ "$1" = "-C" ] && [ "$3" = "blocked" ]; }; then
  echo '[{"id":"ga-hasdep"}]'
  exit 0
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/bd"
UB_FN="$(extract_fn _filter_unblocked)"
cat > "$WORK/s5.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$UB_FN
INPUT='[{"id":"ga-hasdep"},{"id":"ga-clear"}]'
printf '%s' "\$INPUT" | _filter_unblocked /fake/db
EOF
S5_OUT="$(bash "$WORK/s5.sh" 2>"$WORK/s5.stderr")"
S5_IDS="$(printf '%s' "$S5_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S5_IDS" = '["ga-clear"]' ] \
  && ok "_filter_unblocked drops the blocked bead, keeps the clear one" \
  || bad "_filter_unblocked output wrong (got: '$S5_IDS')"
grep -qF '[pilot] EXCLUÍDO ga-hasdep por _filter_unblocked:' "$WORK/s5.stderr" \
  && ok "AC1: ga-hasdep exclusion logged" || bad "AC1: ga-hasdep exclusion line missing"
grep -qF 'ga-clear' "$WORK/s5.stderr" \
  && bad "AC4: ga-clear must not appear in the exclusion trace" \
  || ok "AC4: unblocked bead ga-clear produces no exclusion line"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 6: _filter_explicit_deps (AC1 + AC4, fake bd shim)"
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
# bd -C <db> show <dep> --json
if [ "$1" = "-C" ]; then
  dep="$4"
  case "$dep" in
    ga-openxyz) echo '[{"status":"open"}]' ;;
    *) echo '[{"status":"closed"}]' ;;
  esac
  exit 0
fi
echo '[]'
SHIM
chmod +x "$SHIMBIN/bd"
ED_FN="$(extract_fn _filter_explicit_deps)"
cat > "$WORK/s6.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$ED_FN
INPUT='[
  {"id":"ga-held-on-dep","metadata":{"story.depends_on_beads":"ga-openxyz"}},
  {"id":"ga-dep-closed","metadata":{"story.depends_on_beads":"ga-closedabc"}}
]'
printf '%s' "\$INPUT" | _filter_explicit_deps /fake/db
EOF
S6_OUT="$(bash "$WORK/s6.sh" 2>"$WORK/s6.stderr")"
S6_IDS="$(printf '%s' "$S6_OUT" | jq -c '[.[].id]' 2>/dev/null)"
[ "$S6_IDS" = '["ga-dep-closed"]' ] \
  && ok "_filter_explicit_deps holds the bead with an open dep, keeps the one with a closed dep" \
  || bad "_filter_explicit_deps output wrong (got: '$S6_IDS')"
grep -qF '[pilot] EXCLUÍDO ga-held-on-dep por _filter_explicit_deps:' "$WORK/s6.stderr" \
  && grep -qF 'ga-openxyz' "$WORK/s6.stderr" \
  && ok "AC1: ga-held-on-dep exclusion names the open dependency" \
  || bad "AC1: ga-held-on-dep exclusion line missing/imprecise"
grep -qF 'ga-dep-closed' "$WORK/s6.stderr" \
  && bad "AC4: ga-dep-closed must not appear in the exclusion trace" \
  || ok "AC4: satisfied-dep bead ga-dep-closed produces no exclusion line"

# ════════════════════════════════════════════════════════════════════════════
echo ""
echo "Scenario 7: full chain, healthy sweep — zero exclusion lines (AC2)"
PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$DISPATCHER")"
CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$DISPATCHER")"
TVP="$(grep '^_PILOT_ENGINE_REBUILD_RE=' "$DISPATCHER")"
# ga-vmn7kv: see the matching comment on Scenario 1's FMS/FML above — same
# fix, same reason (absolute $SELF_DIR path, not a literal copy of the
# dispatcher's own BASH_SOURCE-relative source line).
FMS="source \"$SELF_DIR/framework-marker-labels.sh\""
FML="$(grep '^_FILTER_FRAMEWORK_MARKER_LABELS=' "$DISPATCHER")"
cat > "$SHIMBIN/bd" <<'SHIM'
#!/usr/bin/env bash
echo '[]'
SHIM
chmod +x "$SHIMBIN/bd"
cat > "$WORK/s7.sh" <<EOF
export PATH="$SHIMBIN:\$PATH"
$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$FC_FN
$EM_FN
$DG_FN
$FB_FN
$UB_FN
$ED_FN
SELF_BEAD_ID=""
export PILOT_TEST_BRANCH_BEADS=""
export PILOT_TEST_GATE_OPEN_BEADS=""
export PILOT_TEST_GATE_ACTIVE_BEADS=""
INPUT='[{"id":"ga-healthy1","assignee":null,"labels":[],"description":"a real task with plenty of spec text right here","status":"open"},{"id":"ga-healthy2","assignee":null,"labels":[],"description":"another real task with plenty of spec text","status":"open"}]'
printf '%s' "\$INPUT" | _filter_exec_manual | _filter_candidates | _filter_dispatch_gates | _filter_built | _filter_unblocked /fake/db | _filter_explicit_deps /fake/db
EOF
S7_OUT="$(bash "$WORK/s7.sh" 2>"$WORK/s7.stderr")"
S7_IDS="$(printf '%s' "$S7_OUT" | jq -c '[.[].id] | sort' 2>/dev/null)"
[ "$S7_IDS" = '["ga-healthy1","ga-healthy2"]' ] \
  && ok "healthy sweep dispatches both eligible beads unchanged" \
  || bad "healthy sweep output wrong (got: '$S7_IDS')"
if [ -s "$WORK/s7.stderr" ] && grep -q 'EXCLUÍDO' "$WORK/s7.stderr"; then
  bad "AC2: healthy sweep must produce ZERO exclusion lines (got: $(cat "$WORK/s7.stderr")) — log volume would explode in normal operation"
else
  ok "AC2: healthy sweep (nothing excluded) produces zero exclusion-trace log lines"
fi

# ════════════════════════════════════════════════════════════════════════════
if [ -n "$ORIG_DISPATCHER" ] && [ -f "$ORIG_DISPATCHER" ]; then
  echo ""
  echo "Scenario 8: AC3 differential — patched filter JSON output byte-identical to pre-patch"
  extract_orig() { sed -n "/^$1() {/,/^}\$/p" "$ORIG_DISPATCHER"; }
  O_PRE="$(grep '^_FILTER_PREAPPROVAL_LABELS=' "$ORIG_DISPATCHER")"
  O_CAP="$(grep '^_FILTER_RECLAIM_CAP=' "$ORIG_DISPATCHER")"
  # ga-vmn7kv: the pre-patch side needs its OWN copies of the two deps the new
  # side already injects as $LE_FN/$TVP, extracted from $ORIG_DISPATCHER (never
  # borrowed from the patched file — a baseline built out of post-patch parts is
  # not a baseline). Pre-patch _filter_candidates calls _log_exclusions and
  # reads $_PILOT_ENGINE_REBUILD_RE (via local _cf_engine_rebuild_re); without
  # them old_out came back as literal `[]` for every filter. That empty baseline
  # is what made the AC3 differential pass vacuously — `[]` == `[]` whenever the
  # new side was ALSO crippled (see the FMS/FML note in diff_filter below).
  O_LE_FN="$(sed -n '/^_log_exclusions() {/,/^}$/p' "$ORIG_DISPATCHER")"
  O_TVP="$(grep '^_PILOT_ENGINE_REBUILD_RE=' "$ORIG_DISPATCHER")"
  O_FC_FN="$(extract_orig _filter_candidates)"
  O_EM_FN="$(extract_orig _filter_exec_manual)"
  O_DG_FN="$(extract_orig _filter_dispatch_gates)"
  O_FB_FN="$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} /^_beadid_has_open_gate_marker\(\)/{f=1} /^_filter_built\(\)/{f=1} f{print} f&&/^}$/{f=0}' "$ORIG_DISPATCHER")"

  FIXTURES='[
    {"id":"ga-pass1","assignee":null,"labels":[],"description":"a real task with content"},
    {"id":"ga-assigned","assignee":"someone","labels":[],"description":"x"},
    {"id":"ga-blocked-human","assignee":null,"labels":["gate:needs-human:mayor-fixing"],"description":"x"},
    {"id":"ga-empty-desc","assignee":null,"labels":[],"description":""},
    {"id":"ga-workflow","assignee":null,"labels":[],"description":"x","metadata":{"gc.kind":"workflow"}},
    {"id":"ga-preapp","assignee":null,"labels":["story:unrefined"],"description":"x"},
    {"id":"ga-heldnow","assignee":null,"labels":["pilot:held","pilot:held-until:9999999999"],"description":"x"},
    {"id":"ga-reclaimcap","assignee":null,"labels":["pilot:reclaim-count:3"],"description":"x"},
    {"id":"ga-engrebuild","assignee":null,"labels":[],"description":"needs a gascity engine rebuild"}
  ]'

  diff_filter() {
    local fname="$1" new_fn="$2" old_fn="$3"
    local new_out old_out
    # ga-vmn7kv (gate FAIL, run ga-77hyvo): $FMS/$FML MUST be injected here, the
    # same way Scenario 1 (~L81) and Scenario 7 (~L372) do it. Without them the
    # patched _filter_candidates still REFERENCES
    # _FILTER_FRAMEWORK_MARKER_LABELS (3 times) but the var is undefined in this
    # subshell — and there is no `set -u` here, so it expands to EMPTY instead of
    # aborting. The gt:* marker exclusion then matches nothing, the patched
    # filter behaves exactly like the pre-patch one, and this AC3 differential
    # passes VACUOUSLY: it would be comparing pre-patch against a patch whose
    # feature is switched off, i.e. asserting "behavior unchanged" about code
    # that was never exercised. The old_out side below must NOT get these lines —
    # the pre-patch function has no such var and injecting it there would be
    # fabricating a baseline that never existed.
    new_out=$(bash -c "$LOG_FN
$LE_FN
$PRE
$FMS
$FML
$CAP
$TVP
$new_fn
SELF_BEAD_ID=\"\"
printf '%s' '$FIXTURES' | $fname" 2>/dev/null | jq -S . 2>/dev/null)
    old_out=$(bash -c "$LOG_FN
$O_LE_FN
$O_PRE
$O_TVP
$O_CAP
$old_fn
SELF_BEAD_ID=\"\"
printf '%s' '$FIXTURES' | $fname" 2>/dev/null | jq -S . 2>/dev/null)
    if [ "$new_out" = "$old_out" ]; then
      ok "AC3: $fname JSON output identical pre/post patch"
    else
      bad "AC3: $fname JSON output DIFFERS pre/post patch — dispatch behavior changed!"
      diff <(echo "$old_out") <(echo "$new_out") | head -20
    fi
  }
  diff_filter "_filter_candidates" "$FC_FN" "$O_FC_FN"
  diff_filter "_filter_exec_manual" "$EM_FN" "$O_EM_FN"

  DG_FIXTURES='[
    {"id":"ga-still-blocked","status":"open","description":"a real task with enough spec text here","labels":["next-action:mayor"]},
    {"id":"wa-lxe76","status":"open","description":"a real task with enough spec text here","labels":["next-action:batista-constroi"]},
    {"id":"ga-waiting","status":"open","description":"a real task with enough spec text here","labels":["waiting-on:athos"]},
    {"id":"ga-blocked-status","status":"blocked","description":"a real task with enough spec text here","labels":[]},
    {"id":"ga-nospec","status":"open","description":"x","labels":[]}
  ]'
  new_out=$(bash -c "$LOG_FN
$LE_FN
$DG_FN
printf '%s' '$DG_FIXTURES' | _filter_dispatch_gates" 2>/dev/null | jq -S . 2>/dev/null)
  old_out=$(bash -c "$LOG_FN
$O_DG_FN
printf '%s' '$DG_FIXTURES' | _filter_dispatch_gates" 2>/dev/null | jq -S . 2>/dev/null)
  [ "$new_out" = "$old_out" ] \
    && ok "AC3: _filter_dispatch_gates JSON output identical pre/post patch" \
    || { bad "AC3: _filter_dispatch_gates JSON output DIFFERS pre/post patch"; diff <(echo "$old_out") <(echo "$new_out") | head -20; }

  FB_FIXTURES='[{"id":"ga-built","labels":[]},{"id":"ga-fresh","labels":[]},{"id":"ga-ingate","labels":["gate:reviewing"]},{"id":"ga-refix","labels":["gate:needs-fix"]}]'
  new_out=$(bash -c "$LOG_FN
$LE_FN
$FB_FN
export PILOT_TEST_BRANCH_BEADS='ga-built ga-refix'
export PILOT_TEST_GATE_OPEN_BEADS=''
export PILOT_TEST_GATE_ACTIVE_BEADS=''
printf '%s' '$FB_FIXTURES' | _filter_built" 2>/dev/null | jq -S . 2>/dev/null)
  old_out=$(bash -c "$LOG_FN
$O_FB_FN
export PILOT_TEST_BRANCH_BEADS='ga-built ga-refix'
export PILOT_TEST_GATE_OPEN_BEADS=''
export PILOT_TEST_GATE_ACTIVE_BEADS=''
printf '%s' '$FB_FIXTURES' | _filter_built" 2>/dev/null | jq -S . 2>/dev/null)
  [ "$new_out" = "$old_out" ] \
    && ok "AC3: _filter_built JSON output identical pre/post patch" \
    || { bad "AC3: _filter_built JSON output DIFFERS pre/post patch"; diff <(echo "$old_out") <(echo "$new_out") | head -20; }
else
  echo ""
  echo "Scenario 8: SKIPPED (set ORIG_DISPATCHER=<path to pre-patch pilot-dispatcher.sh> to run the AC3 differential)"
fi

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
