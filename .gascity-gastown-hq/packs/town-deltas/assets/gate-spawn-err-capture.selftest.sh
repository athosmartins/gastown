#!/usr/bin/env bash
# gate-spawn-err-capture.selftest.sh — ga-9e8nf regression test.
#
# CASO (reported by gastown.dog-adhoc-f5d56b5e4d in the ga-35ti4 repair,
# 2026-09-10): the reviewer-spawn failure in the "gascity" rig (the framework
# reviewing itself) repeated 5 times in one day with the same signature
# (13:46, 13:58, 14:15, 14:30, 20:35) and the REAL error never showed up in
# the dispatcher log — only "spawn_err=no output" or a truncated fragment.
#
# ROOT CAUSE: every `gc` invocation prints a "warning: builtin pack ... on
# disk differs from the copy embedded in this gc binary" pack-drift line to
# stderr FIRST whenever the on-disk town-deltas pack differs from the copy
# embedded in the binary (the routine, expected state in THIS city — see
# town-deltas-override-not-engine-rebuild). Measured live against the real
# `gc` binary: that single warning line alone is 620 bytes. The dispatcher's
# old capture, `head -c 300 "$_spawn_err_file"`, kept only the first 300
# bytes of stderr — i.e. a PREFIX of the warning, and NEVER any part of the
# actual error, since the warning alone already exceeded the cap.
#
# FIX (quality-gate-dispatcher.sh, both `gc session new gate-reviewer` call
# sites — the initial attempt and the in-process retry loop):
#   capture_spawn_err_tail() drops `^warning:` lines, then keeps the LAST
#   ~2000 bytes of what remains (not the first 300). The tail, not the head,
#   matters here for a second, independent reason: Go's error-wrapping
#   convention puts the root cause at the END of the message (see the live
#   incident string in is_transient_spawn_error's own doc comment, e.g.
#   "...search wisps: invalid connection") — the substrings the transient-
#   error classifier matches live at the tail, not the head, of a real
#   multi-layer error even once the warning noise is gone.
#
# ACEITE (from the bug's own PEDIDO): a stub `gc` that prints the pack-drift
# warning and then a real error on stderr — the captured spawn_err (what the
# dispatcher's "Aborting gate" log line renders) must show the real error,
# not the warning. Covered in section 3 below using the REAL warning text
# measured live (not a paraphrase), so this test would have failed against
# the pre-fix code and fails again if the warning text or byte budget drifts
# back to a shape that swallows real errors.
#
# This harness sources the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test capture_spawn_err_tail directly (pure — real temp files, no
# live Dolt/gc/launchd), same technique as gate-spawn-transient-retry.selftest.sh.
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

echo "== gate-spawn-err-capture.selftest (ga-9e8nf) =="

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type capture_spawn_err_tail >/dev/null 2>&1 \
  || { echo "FATAL: capture_spawn_err_tail not defined by dispatcher (ga-9e8nf fix missing?)"; exit 1; }

# The exact pack-drift warning text, measured live against the real `gc`
# binary on 2026-09-10 (620 bytes, single line, no embedded newline) — a
# golden fixture, not a paraphrase, so a future change to the warning's
# wording still exercises the real shape until this fixture is refreshed.
REAL_WARNING='warning: builtin pack "gastown" on disk differs from the copy embedded in this gc binary (20 files: agents/boot/prompt.template.md, agents/deacon/prompt.template.md, agents/mayor/prompt.template.md, agents/polecat/prompt.template.md, agents/refinery/prompt.template.md, +15 more). Non-required packs are never re-materialized, so the on-disk version is what runs — either a local edit or content left over from an older binary. To adopt the embedded copy: mv "/Users/athos/gt/.gascity-gastown-hq/.gc/system/packs/gastown" "/Users/athos/gt/.gascity-gastown-hq/.gc/system/packs/gastown.bak" && gc config show --validate'

# ── 1. capture_spawn_err_tail — pure function, real temp files ───────────────
echo "── 1. capture_spawn_err_tail (pure, real files) ──"

# (a) warning-only file (the successful-spawn shape, or a failure whose
# stderr is nothing but the warning) → fully filtered, empty result.
TMP_A=$(mktemp)
printf '%s\n' "$REAL_WARNING" > "$TMP_A"
RESULT_A=$(capture_spawn_err_tail "$TMP_A")
rm -f "$TMP_A"
eq "(a) warning-only stderr → empty after filtering (no real error present)" "$RESULT_A" ""

# (b) THE ACEITE CASE: warning line, then the real live-incident error line
# (same string is_transient_spawn_error's own test fixture uses) — the
# pre-fix `head -c 300` would return a truncated PREFIX of the warning alone
# and never reach this line.
TMP_B=$(mktemp)
printf '%s\n' "$REAL_WARNING" > "$TMP_B"
printf '%s\n' 'gc session new: listing sessions: search wisps (merge): search wisps: invalid connection' >> "$TMP_B"
RESULT_B=$(capture_spawn_err_tail "$TMP_B")
rm -f "$TMP_B"
case "$RESULT_B" in
  *"invalid connection"*) ok "(b) ACEITE: real error survives capture behind the pack-drift warning" ;;
  *) bad "(b) ACEITE FAILED: real error missing, got: $RESULT_B" ;;
esac
case "$RESULT_B" in
  *"warning:"*) bad "(b) pack-drift warning text leaked into the captured spawn_err: $RESULT_B" ;;
  *) ok "(b) pack-drift warning correctly filtered out of the captured spawn_err" ;;
esac

# (c) tail-not-head: a long error with no warning, where the actionable text
# sits at the END (mirrors real Go error-wrapping — see is_transient_spawn_error's
# doc comment). Build a >2000-byte line ending in a distinctive marker and
# confirm the marker survives while the distant head does not.
TMP_C=$(mktemp)
HEAD_FILLER=$(printf 'A%.0s' $(seq 1 2500))
printf '%s TAIL_MARKER_END_OF_ERROR\n' "$HEAD_FILLER" > "$TMP_C"
RESULT_C=$(capture_spawn_err_tail "$TMP_C")
rm -f "$TMP_C"
case "$RESULT_C" in
  *"TAIL_MARKER_END_OF_ERROR") ok "(c) tail-not-head: distinctive end-of-message marker survives" ;;
  *) bad "(c) tail-not-head FAILED: marker missing, got tail: ...${RESULT_C: -60}" ;;
esac
RESULT_C_LEN=${#RESULT_C}
if [ "$RESULT_C_LEN" -le 2000 ]; then
  ok "(c) captured spawn_err bounded at <=2000 bytes (got $RESULT_C_LEN)"
else
  bad "(c) captured spawn_err exceeds the 2000-byte budget (got $RESULT_C_LEN)"
fi

# (d) missing file → empty string, no crash (matches the old head -c 300's
# `2>/dev/null || echo ""` safety net for a never-created/already-removed file).
RESULT_D=$(capture_spawn_err_tail "/tmp/ga-9e8nf-does-not-exist-$$")
eq "(d) missing stderr file → empty, no crash" "$RESULT_D" ""

# (e) multiple warning lines (defensive: a future gc version emitting more
# than one distinct pack-drift/advisory line) → all filtered, only the real
# error line remains.
TMP_E=$(mktemp)
{
  printf '%s\n' "$REAL_WARNING"
  printf 'warning: some other advisory line\n'
  printf 'dial tcp 127.0.0.1:52756: connect: connection refused\n'
} > "$TMP_E"
RESULT_E=$(capture_spawn_err_tail "$TMP_E")
rm -f "$TMP_E"
case "$RESULT_E" in
  *"connection refused"*) ok "(e) real error survives multiple warning lines" ;;
  *) bad "(e) real error missing with multiple warnings present, got: $RESULT_E" ;;
esac
case "$RESULT_E" in
  *"warning:"*) bad "(e) a warning line leaked through with multiple warnings present: $RESULT_E" ;;
  *) ok "(e) all warning lines filtered, none leaked" ;;
esac

# ── 2. is_transient_spawn_error still classifies the filtered result ────────
# (integration sanity: the retry loop feeds capture_spawn_err_tail's OUTPUT
# straight into is_transient_spawn_error — confirm the filtered text still
# classifies correctly, i.e. the fix doesn't strip the substrings the
# classifier depends on.)
echo "── 2. filtered output still classifies correctly ──"
TMP_F=$(mktemp)
printf '%s\n' "$REAL_WARNING" > "$TMP_F"
printf '%s\n' 'gc session new: listing sessions: search wisps (merge): search wisps: invalid connection' >> "$TMP_F"
FILTERED=$(capture_spawn_err_tail "$TMP_F")
rm -f "$TMP_F"
eq "filtered spawn_err still classifies as transient" "$(is_transient_spawn_error "$FILTERED")" "1"

# ── 3. end-to-end stub — gc prints the pack-drift warning THEN a real error ──
# (the exact ACEITE shape named in the bug's own PEDIDO: "um stub de gc que
# imprime o aviso e depois um erro real no stderr")
echo "── 3. end-to-end stub gc (PEDIDO's own acceptance shape) ──"
gc() {
  printf '%s\n' "$REAL_WARNING" >&2
  printf '%s\n' 'gc session new: listing sessions: search wisps (merge): search wisps: invalid connection' >&2
  return 1
}
STUB_ERR_FILE=$(mktemp)
gc --city test-city session new gate-reviewer --no-attach --title "probe" --json 2>"$STUB_ERR_FILE" || true
STUB_SPAWN_ERR=$(capture_spawn_err_tail "$STUB_ERR_FILE")
rm -f "$STUB_ERR_FILE"
case "$STUB_SPAWN_ERR" in
  *"invalid connection"*) ok "end-to-end: dispatcher's spawn_err would show the REAL error, not the warning" ;;
  *) bad "end-to-end FAILED: spawn_err does not contain the real error, got: $STUB_SPAWN_ERR" ;;
esac
case "$STUB_SPAWN_ERR" in
  *"warning:"*) bad "end-to-end: pack-drift warning leaked into what the 'Aborting gate' log line would render" ;;
  *) ok "end-to-end: pack-drift warning absent from what the 'Aborting gate' log line would render" ;;
esac

# ── 4. drift-guards: shipped dispatcher still carries the ga-9e8nf fix ──────
echo "── 4. drift-guards ──"
has "$DISPATCHER" 'capture_spawn_err_tail\(\)' "capture_spawn_err_tail helper present"
has "$DISPATCHER" "grep -v '\\^warning:'" "helper filters \`^warning:\` lines before truncating"
has "$DISPATCHER" 'tail -c 2000' "helper keeps a TAIL slice (not head), sized ~2000 bytes"

HEAD300_COUNT=$(grep -c 'head -c 300' "$DISPATCHER" || true)
eq "old 'head -c 300' truncation fully removed from both call sites" "${HEAD300_COUNT:-0}" "0"

CALL_SITE_COUNT=$(grep -c 'capture_spawn_err_tail "\$_spawn_err_file"' "$DISPATCHER" || true)
eq "capture_spawn_err_tail wired into exactly 2 call sites (initial spawn + retry loop)" "${CALL_SITE_COUNT:-0}" "2"

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DEF_LN=$(grep -n '^capture_spawn_err_tail() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "capture_spawn_err_tail (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
else
  bad "capture_spawn_err_tail must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

# ── 5. syntax ────────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
