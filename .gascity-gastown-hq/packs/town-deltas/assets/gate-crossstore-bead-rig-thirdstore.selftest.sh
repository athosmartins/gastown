#!/usr/bin/env bash
# gate-crossstore-bead-rig-thirdstore.selftest.sh (wa-2ddr0)
#
# Proves the bead_rig third-candidate fix for gate PASS+merge cross-store close.
#
# ROOT BUG: ga-qw7y6/gt-gwng6 taught resolve_bead_city() to probe RIG_PATH (the
# CODE rig, from the marker's `rig:` field) then GC_CITY (HQ) as a 2-candidate
# loop. That works when the code rig and the bead's own rig genuinely differ as
# a PATH — e.g. an HQ ga- bead built on a rig branch (RIG_PATH=rig, GC_CITY=HQ:
# two distinct paths, one of them right). It silently FAILS when the code rig
# IS gascity itself: RIG_PATH resolves to $GC_CITY (gascity is a self-repo rig
# whose path equals the GC_CITY constant), so the "2-candidate" loop is
# actually probing the SAME store twice in disguise — a wa-* bead whose fix
# lives in the HQ/gascity repo (rig=gascity, bead_rig=whatsapp_automation) is
# never tried against its real store. The close/label writes silently no-op
# (bd -C <HQ> close wa-XXXX fails, swallowed by `2>/dev/null || true`), the
# ga-esbg post-merge verification probes the SAME wrong store and reports a
# false "absent, all clear", and the source bead re-surfaces to the routed
# pool forever (wa-muesb: 6 sessions/2h; wa-h9dc1: reclaimed by an unrelated
# reconciler before anyone noticed — see wa-2ddr0 comments for both repros).
#
# FIX: /gate-done already computes+persists a field independent of the code
# rig — `bead_rig:` (commands/gate-done.md Step 2/3) — recording which store
# the source bead ITSELF resolved to at submit time (by actually probing HQ
# then the code rig, the same way this selftest's section A does). Extract
# that field at every point a rig context gets (re)resolved (dispatcher Step
# 2 fast-path, Step 6 persistence into the gate-run bead, Phase C recovery
# for a run finalized in a LATER sweep, the Step 0a-4 needs-rebase reaper;
# mirrored into quality-gate-guard.sh Step 5b), resolve it to a path via the
# same RIG_LIST_JSON registry RIG_PATH itself uses (no special-casing needed:
# "gascity" is itself a registered self-repo rig whose path IS $GC_CITY), and
# probe it FIRST in resolve_bead_city — strictly additive, since the loop
# only ever trusts a candidate that a live `bd show` actually confirms.
#
# Covers:
#   A. resolve_bead_city — OLD (pre-fix, 2-candidate) vs NEW (post-fix,
#      3-candidate) run side-by-side against the exact wa-2ddr0 repro shape:
#        (1) THE FIX: rig=gascity (RIG_PATH==GC_CITY) + bead_rig=whatsapp_automation
#            → OLD resolves to HQ (WRONG); NEW resolves to the rig store (RIGHT)
#        (2) ga-qw7y6 preserved: HQ ga- bead, no bead_rig hint → HQ store
#        (3) wa-re77 preserved: rig-native wa- bead (bead_rig==rig) → rig store
#        (4) a WRONG/stale bead_rig hint never produces a wrong answer — the
#            probe fails there and falls through correctly (safety property)
#        (5) no bead_rig at all (pre-fix marker) → identical to OLD behavior
#            (full backward compatibility)
#        (6) empty bead-id → HQ store (unchanged trivial case)
#   B. BEAD_RIG → BEAD_RIG_PATH derivation (gate_resolve_rig_context) — proves
#      "gascity" round-trips through the SAME RIG_LIST_JSON lookup RIG_PATH
#      uses (no special case needed), a real rig name resolves to its path,
#      and "unknown"/empty skip the lookup entirely (never a spurious probe).
#   C. Drift-guards: bead_rig is threaded through all 3 dispatcher call sites
#      + the guard mirror, and the fix cannot silently revert.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SRC="$SELF_DIR/quality-gate-dispatcher.sh"
GUARD_SRC="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# ── Fixture store layout ────────────────────────────────────────────────────
# GC_CITY and RIG_PATH are made to COLLIDE (both "/fake/hq") — this is the
# exact wa-2ddr0 precondition: the marker's rig:=gascity, whose registered
# path IS the GC_CITY constant, so a plain [RIG_PATH, GC_CITY] loop is really
# a 1-distinct-candidate loop wearing a 2-candidate costume.
GC_CITY="/fake/hq"
RIG_PATH="/fake/hq"
RIG_NATIVE_PATH="/fake/rig/wa"
bd() {
  local store="" bead=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) store="$2"; shift 2 ;;
      show) bead="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$store/$bead" in
    "$GC_CITY/ga-hqbead")            echo '{"id":"ga-hqbead","status":"in_progress"}' ;;
    "$RIG_NATIVE_PATH/wa-rignative")  echo '{"id":"wa-rignative","status":"open"}' ;;
    "$RIG_NATIVE_PATH/wa-2ddr0-repro") echo '{"id":"wa-2ddr0-repro","status":"in_progress"}' ;;
    *) echo '{"error":"no issues found matching the provided IDs","schema_version":1}' ;;
  esac
}
log() { :; }

# ── OLD (pre-ga-qw7y6-fix... i.e. pre-THIS-fix) 2-candidate resolver ───────
resolve_bead_city_OLD() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}

# ── NEW (post-fix) 3-candidate resolver, replicated for direct unit testing ─
# (Structural presence in the live source is proven separately in section C's
# drift-guards — this copy exists so the exact matching/ordering logic can be
# exercised as pure input/output, the same convention gate-pilot-crossstore-
# close.selftest.sh and gate-guard-crossstore-detach.selftest.sh already use
# for this same function.)
resolve_bead_city_NEW() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${BEAD_RIG_PATH:-}" "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}

echo "A. resolve_bead_city — OLD (buggy) vs NEW (fixed), side by side:"

echo "── (1) THE FIX: rig=gascity (RIG_PATH==GC_CITY) + bead_rig=whatsapp_automation ──"
BEAD_RIG_PATH="$RIG_NATIVE_PATH"
old=$(resolve_bead_city_OLD "wa-2ddr0-repro")
new=$(resolve_bead_city_NEW "wa-2ddr0-repro")
[ "$old" = "$GC_CITY" ] && ok "OLD reproduces the bug: resolves to HQ ($old) — wrong store, close/labels would silently no-op" \
  || bad "OLD did not reproduce the bug as expected (got $old) — fixture may have drifted"
[ "$new" = "$RIG_NATIVE_PATH" ] && ok "NEW fixes it: resolves to the bead's real store ($new)" \
  || bad "NEW did not resolve to $RIG_NATIVE_PATH — got $new"

echo "── (2) ga-qw7y6 preserved: HQ ga- bead, no bead_rig hint ──"
BEAD_RIG_PATH=""
r=$(resolve_bead_city_NEW "ga-hqbead")
[ "$r" = "$GC_CITY" ] && ok "HQ ga- bead with empty BEAD_RIG_PATH → HQ store (unchanged)" \
  || bad "expected $GC_CITY, got $r"

echo "── (3) wa-re77 preserved: rig-native wa- bead (bead_rig==rig) ──"
RIG_PATH="$RIG_NATIVE_PATH"   # a genuine rig-native marker: rig=whatsapp_automation
BEAD_RIG_PATH="$RIG_NATIVE_PATH"   # bead_rig=whatsapp_automation too — same store
r=$(resolve_bead_city_NEW "wa-rignative")
[ "$r" = "$RIG_NATIVE_PATH" ] && ok "rig-native bead resolves to rig store ($r)" \
  || bad "expected $RIG_NATIVE_PATH, got $r"
RIG_PATH="$GC_CITY"   # restore the wa-2ddr0-shape fixture for subsequent cases

echo "── (4) a WRONG/stale bead_rig hint never produces a wrong answer ──"
BEAD_RIG_PATH="/fake/nonexistent/store"   # hand-crafted or stale marker lied
r=$(resolve_bead_city_NEW "ga-hqbead")
[ "$r" = "$GC_CITY" ] && ok "bad hint probe fails silently, falls through to the correct store ($r)" \
  || bad "bad hint corrupted resolution — got $r (expected fallthrough to $GC_CITY)"

echo "── (5) no bead_rig at all (pre-fix marker) → identical to OLD behavior ──"
BEAD_RIG_PATH=""
old=$(resolve_bead_city_OLD "wa-2ddr0-repro")
new=$(resolve_bead_city_NEW "wa-2ddr0-repro")
[ "$old" = "$new" ] && ok "empty BEAD_RIG_PATH: NEW matches OLD exactly ($new) — full backward compatibility" \
  || bad "backward-compat broken: OLD=$old NEW=$new"

echo "── (6) empty bead-id → HQ store (unchanged trivial case) ──"
r=$(resolve_bead_city_NEW "")
[ "$r" = "$GC_CITY" ] && ok "empty bead-id → HQ store" || bad "expected $GC_CITY, got $r"

# ── B. BEAD_RIG → BEAD_RIG_PATH derivation ──────────────────────────────────
echo "B. BEAD_RIG → BEAD_RIG_PATH derivation (gate_resolve_rig_context):"
RIG_LIST_JSON='{"rigs":[
  {"name":"gascity","prefix":"ga","path":"/fake/hq"},
  {"name":"whatsapp_automation","prefix":"wa","path":"/fake/rig/wa"}
]}'
derive() {
  local BEAD_RIG="$1" BEAD_RIG_PATH=""
  if [ -n "${BEAD_RIG:-}" ] && [ "$BEAD_RIG" != "unknown" ]; then
    BEAD_RIG_PATH=$(echo "$RIG_LIST_JSON" \
      | jq -r --arg r "$BEAD_RIG" '.rigs[] | select(.name == $r or .prefix == $r) | .path' 2>/dev/null | head -1 || echo "")
  fi
  echo "$BEAD_RIG_PATH"
}
r=$(derive "gascity")
[ "$r" = "/fake/hq" ] && ok "bead_rig='gascity' round-trips through the registry (no special-casing needed) → $r" \
  || bad "bead_rig='gascity' → expected /fake/hq, got '$r'"
r=$(derive "whatsapp_automation")
[ "$r" = "/fake/rig/wa" ] && ok "bead_rig='whatsapp_automation' → $r" \
  || bad "bead_rig='whatsapp_automation' → expected /fake/rig/wa, got '$r'"
r=$(derive "unknown")
[ "$r" = "" ] && ok "bead_rig='unknown' (gate-done's could-not-determine sentinel) → skipped, empty" \
  || bad "bead_rig='unknown' should skip the lookup — got '$r'"
r=$(derive "")
[ "$r" = "" ] && ok "bead_rig='' (predates this fix) → skipped, empty" \
  || bad "empty bead_rig should skip the lookup — got '$r'"
r=$(derive "no-such-rig")
[ "$r" = "" ] && ok "bead_rig names an unregistered rig → natural lookup miss, empty" \
  || bad "unregistered rig name should yield empty — got '$r'"

# ── C. Drift-guards on the live sources ─────────────────────────────────────
echo "C. Drift-guards (live sources still carry the fix):"
if [ -f "$GATE_SRC" ]; then
  n=$(grep -c 'extract "bead_rig"' "$GATE_SRC" 2>/dev/null || echo 0)
  [ "$n" -ge 3 ] && ok "dispatcher: bead_rig extracted at >=3 sites (Step 2 fast-path, Phase C, Step 0a-4 reaper) — got $n" \
    || bad "dispatcher: expected >=3 'extract \"bead_rig\"' call sites, found $n — a call site regressed?"
  grep -q 'for store in "\${BEAD_RIG_PATH:-}" "\${RIG_PATH:-}" "\$GC_CITY"; do' "$GATE_SRC" \
    && ok "dispatcher: resolve_bead_city probes BEAD_RIG_PATH first, in order" \
    || bad "dispatcher: resolve_bead_city candidate order/list REVERTED"
  grep -q 'BEAD_RIG_PATH=""' "$GATE_SRC" \
    && ok "dispatcher: BEAD_RIG_PATH derivation present in gate_resolve_rig_context" \
    || bad "dispatcher: BEAD_RIG_PATH derivation MISSING"
  grep -q 'bead_rig: \${BEAD_RIG:-}' "$GATE_SRC" \
    && ok "dispatcher: Step 6 persists bead_rig into the gate-run bead (Phase C recovery path)" \
    || bad "dispatcher: Step 6 no longer persists bead_rig — Phase C finalization of a deferred run would regress to the pre-fix bug"
  grep -q 'NR_BEAD_RIG=\$(extract "bead_rig")' "$GATE_SRC" \
    && ok "dispatcher: Step 0a-4 reaper extracts bead_rig for its candidate" \
    || bad "dispatcher: Step 0a-4 reaper no longer extracts bead_rig"
  grep -q 'BEAD_RIG="\$NR_BEAD_RIG"' "$GATE_SRC" \
    && ok "dispatcher: Step 0a-4 reaper threads bead_rig into gate_resolve_rig_context" \
    || bad "dispatcher: Step 0a-4 reaper no longer threads bead_rig through"
else
  bad "dispatcher source not found at $GATE_SRC"
fi
if [ -f "$GUARD_SRC" ]; then
  grep -q 'BEAD_RIG=\$(extract "bead_rig")' "$GUARD_SRC" \
    && ok "guard: bead_rig extracted at Step 3 (mirrors dispatcher Step 2)" \
    || bad "guard: bead_rig extraction MISSING"
  grep -q 'for store in "\${BEAD_RIG_PATH:-}" "\${RIG_PATH:-}" "\$GC_CITY"; do' "$GUARD_SRC" \
    && ok "guard: resolve_bead_city probes BEAD_RIG_PATH first, in order (mirrors dispatcher)" \
    || bad "guard: resolve_bead_city candidate order/list REVERTED"
  grep -q 'BEAD_RIG_PATH=""' "$GUARD_SRC" \
    && ok "guard: BEAD_RIG_PATH derivation present" \
    || bad "guard: BEAD_RIG_PATH derivation MISSING"
else
  bad "guard source not found at $GUARD_SRC"
fi

echo ""
echo "── wa-2ddr0 selftest: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
