#!/usr/bin/env bash
# gate-marker-desc-bsd-sed.selftest.sh — ga-b1djxn: the gate reads `branch:` /
# `rig:` out of a marker DESCRIPTION with sed. On macOS (BSD sed) a bracket
# expression does NOT understand `\t`: `[ \t]` is the set {space, backslash, t},
# so `s/^rig:[ \t]*\(.*\)$/\1/p` also eats the LEADING "t"s of the value and
# never strips a real TAB:
#
#     rig: tmux        -> "mux"          branch: test/x  -> "est/x"
#     rig:<TAB>lexbh   -> "<TAB>lexbh"   (the tab survives)
#
# Only the sed sites are affected (awk, jq and bash $'\t' all treat \t as an
# escape correctly); three sed lines had the pattern:
#   quality-gate-guard.sh  gate_bead_sibling_status_lines  (branch fallback + rig)
#   scripts/gate-queue-composition.sh                      (rig)
# The fix is the POSIX class `[[:space:]]*` (BSD and GNU sed).
#
# Sections 2 and 3 drive the REAL code (the guard's function, sourced lib-only
# with a mock bd; the composition script as a subprocess with bd/gc shims and
# throwaway git repos). Section 4 is a static drift guard so the pattern cannot
# come back. Exit 0 iff every assertion holds.
#
# Red/green: on macOS sections 2, 3 and 4 FAIL against the pre-fix code. On GNU
# sed the behavioural cases cannot distinguish the two spellings (section 1 says
# which sed this is), but section 4 still fails pre-fix.

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
CITY_DIR="$(cd "$SELF_DIR/../../.." && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
QUEUE_COMP="$CITY_DIR/scripts/gate-queue-composition.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$(printf '%s' "$2" | tr '\t' '|'))"; else bad "$1: expected [$(printf '%s' "$3" | tr '\t' '|')], got [$(printf '%s' "$2" | tr '\t' '|')]"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gate-desc-sed.XXXXXX") || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── 1. Which sed is this? (informational: names the flavor the rest ran on) ──
echo "── 1. sed flavor ──"
_probe=$(printf 'k: test\n' | sed -n 's/^k:[ \t]*\(.*\)$/\1/p')
if [ "$_probe" = "est" ]; then
  echo "  · this sed is BSD-like: [ \\t] in a bracket = {space, \\, t} — the bug is live here"
else
  echo "  · this sed treats \\t in a bracket as TAB (GNU-like): behavioural cases cannot tell the spellings apart; section 4 still guards"
fi
_fixed=$(printf 'k: test\n' | sed -n 's/^k:[[:space:]]*\(.*\)$/\1/p')
eq "the POSIX class keeps a leading t on this sed" "$_fixed" "test"

# ── 2. The guard's gate_bead_sibling_status_lines (REAL function, mock bd) ───
echo "── 2. quality-gate-guard.sh gate_bead_sibling_status_lines ──"
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source the guard in lib-only mode"; exit 1; }
type gate_bead_sibling_status_lines >/dev/null 2>&1 \
  || { echo "FATAL: gate_bead_sibling_status_lines not defined by the guard (lib-only)"; exit 1; }
log()  { :; }
warn() { :; }
err()  { :; }

MOCK_LIST_JSON='[]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_LIST_JSON" ;;
    *) : ;;
  esac
  return 0
}

# A sibling OPEN marker with NO branch: label, so the description fallback runs.
sib_json() { # <description-json-string>
  printf '[{"id":"m1","status":"open","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-x"],"description":"%s"}]' "$1"
}

MOCK_LIST_JSON=$(sib_json 'branch: test/x\nrig: tmux\n')
eq "(a) branch 'test/x' + rig 'tmux' (both start with t) read whole" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'test/x\tqueued\ttmux')"

MOCK_LIST_JSON=$(sib_json 'branch:\ttest/x\nrig:\ttmux\n')
eq "(b) a real TAB after the colon is stripped (both fields)" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'test/x\tqueued\ttmux')"

MOCK_LIST_JSON=$(sib_json 'bead_id: ga-x\nbranch: tt/deep/name\nrig: ttt\ncommit: abc123\n')
eq "(c) several leading t's survive; first match wins over the other description lines" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'tt/deep/name\tqueued\tttt')"

MOCK_LIST_JSON=$(sib_json 'branch: feat/x\nrig: whatsapp_automation\n')
eq "(d) control: values that do not start with t were already right and stay right" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'feat/x\tqueued\twhatsapp_automation')"

MOCK_LIST_JSON=$(sib_json 'branch: test/x\n')
eq "(e) no rig: line at all -> empty third field (unchanged behaviour)" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'test/x\tqueued\t')"

# The branch: LABEL path (no sed on the description) must be untouched.
MOCK_LIST_JSON='[{"id":"m1","status":"open","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-x","branch:test/labelled"],"description":"rig: tmux\n"}]'
eq "(f) branch from the LABEL is used as-is; rig still read whole from the description" \
  "$(gate_bead_sibling_status_lines city ga-x 2>/dev/null)" \
  "$(printf 'test/labelled\tqueued\ttmux')"

# ── 3. scripts/gate-queue-composition.sh (REAL script, bd/gc shims, real git) ─
echo "── 3. scripts/gate-queue-composition.sh — a marker whose rig name starts with t ──"
BIN="$TMP/bin"; mkdir -p "$BIN"
HQ="$TMP/hq"; mkdir -p "$HQ/.beads"
cat > "$BIN/bd" <<'SHIM'
#!/bin/sh
case " $* " in
  *" list "*) cat "$SHIM_MARKERS_FILE" ;;
  *) exit 1 ;;
esac
SHIM
cat > "$BIN/gc" <<'SHIM'
#!/bin/sh
case " $* " in
  *" rig list "*) cat "$SHIM_RIGS_FILE" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$BIN/bd" "$BIN/gc"

G() { git -c user.name=selftest -c user.email=selftest@example.invalid "$@"; }
ORIGIN="$TMP/origin.git"; RIGREPO="$TMP/rigrepo"
G init -q --bare "$ORIGIN"
G init -q -b main "$RIGREPO"
G -C "$RIGREPO" remote add origin "$ORIGIN"
echo base > "$RIGREPO/f"; G -C "$RIGREPO" add f; G -C "$RIGREPO" commit -q -m base
G -C "$RIGREPO" push -q origin main
G -C "$RIGREPO" checkout -q -b fix/tt-branch
echo work >> "$RIGREPO/f"; G -C "$RIGREPO" commit -q -am work
G -C "$RIGREPO" push -q origin fix/tt-branch
G -C "$RIGREPO" checkout -q main

# The registry knows two rigs, both backed by the same throwaway repo: one whose
# name starts with t (the victim) and one that does not (the control).
printf '{"rigs":[{"name":"tmux","path":"%s"},{"name":"lexbh","path":"%s"}]}\n' "$RIGREPO" "$RIGREPO" > "$TMP/rigs.json"

marker_for_rig() { # <rig>
  printf '[{"id":"m1","description":"branch: fix/tt-branch\\nrig: %s\\n","labels":["type:quality-gate-marker","branch:fix/tt-branch","gate-status:queued"]}]' "$1"
}
run_comp() { # <rig> -> the --json counts line
  marker_for_rig "$1" > "$TMP/markers.json"
  # The script prepends ~/.local/bin, homebrew and /usr/local/bin to PATH when they
  # are absent; naming them AFTER the shim dir keeps the shims first.
  SHIM_MARKERS_FILE="$TMP/markers.json" SHIM_RIGS_FILE="$TMP/rigs.json" GC_CITY_PATH="$HQ" \
    PATH="$BIN:/Users/athos/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" \
    bash "$QUEUE_COMP" --json 2>"$TMP/comp.err"
}

eq "(g) control rig 'lexbh': the branch is REAL work (1 real, 0 unreadable)" \
  "$(run_comp lexbh)" '{"total":1,"real":1,"phantom":0,"unknown":0}'
eq "(h) rig 'tmux' (starts with t) resolves and is REAL work — not 'rig mux did not resolve'" \
  "$(run_comp tmux)" '{"total":1,"real":1,"phantom":0,"unknown":0}'

# The human-readable diagnostic must name the rig the marker actually declares.
marker_for_rig tmuxghost > "$TMP/markers.json"
_human=$(SHIM_MARKERS_FILE="$TMP/markers.json" SHIM_RIGS_FILE="$TMP/rigs.json" GC_CITY_PATH="$HQ" \
  PATH="$BIN:/Users/athos/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH" \
  bash "$QUEUE_COMP" 2>/dev/null || true)
case "$_human" in
  *"rig 'tmuxghost' não resolveu"*) ok "(i) an unknown t-rig is reported under its own name (tmuxghost), not a truncated one" ;;
  *) bad "(i) expected \"rig 'tmuxghost' não resolveu\" in the diagnostic, got: $(printf '%s' "$_human" | grep -F 'resolveu' | head -1)" ;;
esac

# ── 4. Drift guard: no sed line in the repo's shell scripts may bracket a \t ─
echo "── 4. no sed line with a backslash-t inside a bracket expression ──"
_lit='[ '"\\"'t]'
# Comment-only lines are skipped (an explanation may quote the pattern); this
# file is skipped because it quotes it on purpose.
_hits=$(cd "$CITY_DIR" && grep -rn --include='*.sh' -F -e "$_lit" scripts packs 2>/dev/null \
  | grep -F 'sed' | grep -vF "$(basename "$SELF")" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
if [ -z "$_hits" ]; then
  ok "no sed line in scripts/ or packs/ uses a bracketed backslash-t (use [[:space:]] / [[:blank:]])"
else
  bad "sed lines still bracketing backslash-t (BSD sed reads that as {space,\\,t}):"
  printf '%s\n' "$_hits" | sed 's/^/      /'
fi

echo
echo "gate-marker-desc-bsd-sed selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
