#!/usr/bin/env bash
# witness-startup-three-states.selftest.sh — behavioral drift-guard for ga-6zrshxb.
#
# Bug ga-6zrshxb: the witness prompt's Startup Protocol read `gc hook` as two states. `gc hook` exits 1 for "nothing in
# the hook" AND for an error ("gc hook: agent ... not found in config", "timed out after 30s" at load 45-71: 4 cases on
# 12/11, the wisp alive each time). The old Step 1 (`if gc hook ...; then ...; else : ...; fi`) read every failure as
# "empty", fell through to Step 3 and poured a duplicate wisp. The same collapse sat in the "CRITICAL: No Idle State"
# block: `$(gc bd ... list ... | jq -r '.[0].id // empty')` is empty when the read FAILS too, so a failed read of the
# next wisp poured one more (and burned the current one).
#
# The fix is three states (has / has not / do not know) at every decision point, and only "has not" may pour. The three
# bash blocks of the prompt (Step 1, Step 3, No-Idle) are EXTRACTED from town-deltas.template.md and EXECUTED under a stub
# `gc` on a sandbox PATH (never compared as text). The stub answers `gc hook` and `gc bd list|mol|show|update` from the
# scenario and logs every call (the spy), so "no pour" and "no burn" are asserted as the ABSENCE of the call, and the
# healthy scenarios prove the spy does see a pour/burn when one happens.
#
# Sibling guards that read the same section: witness-patrol-wisp-store.selftest.sh (structure: -C pins, anchors on the
# first `BD_C=()` and the last `gc hook` line of the No-Idle block) and witness-patrol-liveness-read-failure.selftest.sh
# (the session-bead overlay read). This file owns the behavior of the three blocks.
#
# WITNESS_TEMPLATE_UNDER_TEST overrides the template (mutant runs, see the delivery of ga-6zrshxb).
# Exit 0 iff every scenario holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
TEMPLATE="${WITNESS_TEMPLATE_UNDER_TEST:-$TOWN_DELTAS_ROOT/template-fragments/town-deltas.template.md}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$TEMPLATE" ]; then
  echo "FATAL: template fragment not found at $TEMPLATE" >&2
  exit 2
fi

echo "witness-startup-three-states.selftest — ga-6zrshxb: gc hook error is not empty, and only 'has not' may pour"

FAKE_RIG="/fake/rig"
FAKE_AGENT="property_scrapers/gastown.witness"

# ── Extract the three bash blocks ─────────────────────────────────────────────
# extract_block HEADING [RIGROOT]: the first ```bash fence after the line that starts with HEADING, up to its closing fence,
# with the Go-template fields filled in the way the engine renders a rig (RigRoot = $FAKE_RIG unless a second argument,
# possibly empty, says otherwise).
# vazio → prints nothing (the caller refuses to run an empty block); falhou → awk/sed rc is not read, an empty block is the same refusal
extract_block() {
  local rig="${2-$FAKE_RIG}"
  awk -v head="$1" '
    index($0, head) == 1 { seen = 1; next }
    seen && /^```bash$/ { inb = 1; next }
    inb && /^```$/ { exit }
    inb { print }
  ' "$TEMPLATE" | sed -e "s|{{ \.RigRoot }}|$rig|g" -e "s|{{ \.BindingPrefix }}|bp|g"
}
H1='**Step 1 substituto**'
H3='**Step 3 substituto**'
HN='**Bloco "CRITICAL: No Idle State" substituto**'

# The anchors must be unique, or the extraction could pick another block and the scenarios would test the wrong code.
for h in "$H1" "$H3" "$HN"; do
  n="$(grep -c -F -- "$h" "$TEMPLATE")"
  if [ "$n" = 1 ]; then ok "anchor found exactly once: $h"; else bad "anchor '$h' found $n times in the template (expected 1) — the extraction cannot be trusted"; fi
done
STEP1="$(extract_block "$H1")"
STEP3="$(extract_block "$H3")"
STEPN="$(extract_block "$HN")"
for pair in "Step 1:gc hook:$STEP1" "Step 3:mol wisp:$STEP3" "No-Idle:pour_next:$STEPN"; do
  label="${pair%%:*}"; rest="${pair#*:}"; marker="${rest%%:*}"; code="${rest#*:}"
  if [ -n "$code" ] && printf '%s\n' "$code" | grep -F -q -- "$marker"; then
    ok "$label block extracted (carries '$marker')"
  else
    bad "FATAL-ish: could not isolate the $label block (anchor moved or block empty) — nothing below can be trusted"
  fi
done

# ── Stub gc + sandbox PATH ────────────────────────────────────────────────────
STUBDIR="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$STUBDIR"' EXIT
mkdir -p "$STUBDIR/bin"

cat > "$STUBDIR/bin/gc" <<'STUB'
#!/usr/bin/env bash
# Every call goes to the spy ($SPY, one line); the answer comes from the scenario's STUB_* variables.
printf 'GC %s\n' "$*" >> "${SPY:-/dev/null}"
case "${1:-}" in
  hook)
    [ -n "${STUB_HOOK_OUT:-}" ] && printf '%s\n' "$STUB_HOOK_OUT"
    [ -n "${STUB_HOOK_ERR:-}" ] && printf '%s\n' "$STUB_HOOK_ERR" >&2
    exit "${STUB_HOOK_RC:-0}"
    ;;
  bd)
    shift
    [ "${1:-}" = "-C" ] && shift 2   # the pin is in the spy line; every store answers alike
    case "${1:-}" in
      list)
        # --status picks the scenario's answer: in_progress, open, or none at all (the Step 3 guard)
        key=ANY
        for a in "$@"; do
          case "$a" in
            --status=in_progress) key=INPROG ;;
            --status=open) key=OPEN ;;
          esac
        done
        eval "body=\${STUB_${key}_BODY:-}; err=\${STUB_${key}_ERR:-}; rc=\${STUB_${key}_RC:-0}"
        [ -n "$body" ] && printf '%s' "$body"
        [ -n "$err" ] && printf '%s\n' "$err" >&2
        exit "$rc"
        ;;
      mol)
        case "${2:-}" in
          wisp) [ "${STUB_POUR_RC:-0}" -eq 0 ] && printf '{"new_epic_id":"ga-wisp-new"}'; exit "${STUB_POUR_RC:-0}" ;;   # a failing pour prints nothing
          burn) exit 0 ;;
        esac
        ;;
      show) exit "${STUB_SHOW_RC:-0}" ;;
      update) exit 0 ;;
    esac
    echo "unstubbed gc bd call: $*" >&2
    exit 99
    ;;
esac
echo "unstubbed gc call: $*" >&2
exit 99
STUB
chmod +x "$STUBDIR/bin/gc"
# The Step 1 block makes its own temp file; this stub lets a scenario make that fail.
cat > "$STUBDIR/bin/mktemp" <<'STUB'
#!/bin/sh
[ -n "${STUB_MKTEMP_FAIL:-}" ] && { echo "mktemp: stub failure" >&2; exit 1; }
exec /usr/bin/mktemp "$@"
STUB
chmod +x "$STUBDIR/bin/mktemp"
# The blocks run on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh): a vanished stub is "command not found", never the real town.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$STUBDIR" jq || exit 2   # jq: the parse the blocks do; gc and mktemp are the stubs above

# run_block CODE [VAR=value ...] — runs one block in a clean environment (env -i: none of this session's GC_* leaks in).
# Sets OUT (stdout+stderr of the block), RC and SPY_LOG (every gc call it made, one per line).
run_block() {
  local code="$1" spy
  shift
  spy="$(mktemp)" || { bad "scenario harness: mktemp failed"; OUT=""; RC=99; SPY_LOG=""; return 1; }
  OUT="$(env -i HOME="$STUBDIR" PATH="$SANDBOX_PATH" SPY="$spy" GC_AGENT="$FAKE_AGENT" GC_ALIAS="$FAKE_AGENT" "$@" bash -c "$code" 2>&1)"
  RC=$?
  # vazio → no gc call was made (a legitimate answer for the "no read" scenarios); falhou → the spy file is ours, cat cannot fail short of a dead disk
  SPY_LOG="$(cat "$spy")"
  rm -f "$spy"
}
spy_n()     { printf '%s\n' "$SPY_LOG" | grep -c -E -- "$1"; }
spy_first() { printf '%s\n' "$SPY_LOG" | grep -n -E -- "$1" | head -n 1 | cut -d: -f1; }
POUR_RE='^GC bd .*mol wisp'
ASSIGN_RE='^GC bd .*update ga-wisp-new --assignee='
BURN_RE='^GC bd .*mol burn'
LIST_RE='^GC bd .* list '
ANYBD_RE='^GC bd '

# ── Group A: Step 1 — gc hook is classified in three states ───────────────────
# step1_case LABEL RC STDOUT STDERR WANT_STATE WANT_RC
step1_case() {
  local label="$1" rc="$2" out="$3" err="$4" want="$5" want_rc="$6"
  run_block "$STEP1" STUB_HOOK_RC="$rc" STUB_HOOK_OUT="$out" STUB_HOOK_ERR="$err"
  if printf '%s\n' "$OUT" | grep -q "^HOOK=$want " && [ "$RC" -eq "$want_rc" ]; then
    ok "$label -> HOOK=$want, exit $RC"
  else
    bad "$label: wanted HOOK=$want with exit $want_rc, got exit $RC :: $OUT"
  fi
  if [ "$(spy_n "$ANYBD_RE")" -eq 0 ]; then :; else bad "$label: Step 1 made a gc bd call (it must only ask gc hook): $SPY_LOG"; fi
}
echo ""
echo "Group A: Step 1 — gc hook has work / is empty / could not answer"
WARN='warning: builtin pack "gastown" on disk differs from the copy embedded in this gc binary (1 file: x)'
step1_case "healthy: exit 0 with a work list"                      0   '[{"id":"ga-wisp-abc"}]' ""                                                         tem     0
step1_case "empty: exit 1 with []"                                 1   '[]'                     ""                                                         vazio   0
step1_case "empty and silent (no-work cache hit): exit 1, no output" 1 ""                       ""                                                         vazio   0
step1_case "empty list with whitespace around it"                  1   $'\n  []  \n'            ""                                                         vazio   0
step1_case "empty with a stderr warning is still empty"            1   '[]'                     "$WARN"                                                    vazio   0
step1_case "stderr line that only MENTIONS gc hook: mid-line is not an error" 1 '[]'           "retry note: slow gc hook: retried"                        vazio   0
step1_case "THE BUG: agent not found (exit 1, gc hook: line)"      1   ""                       'gc hook: agent "property_scrapers/gastown.witness" not found in config' nao-sei 1
step1_case "THE BUG: timed out after 30s under load"               1   ""                       'gc hook: work query timed out after 30s'                  nao-sei 1
step1_case "suspended agent"                                       1   ""                       'gc hook: agent "x" is suspended'                          nao-sei 1
step1_case "error line beats a [] body"                            1   '[]'                     'gc hook: bd: connection refused'                          nao-sei 1
step1_case "usage error (exit 2)"                                  2   ""                       'usage: gc hook [agent]'                                   nao-sei 1
step1_case "killed by a timeout wrapper (exit 124)"                124 ""                       ""                                                         nao-sei 1
step1_case "gc not executable (exit 127)"                          127 ""                       ""                                                         nao-sei 1
step1_case "exit 0 without a body is not an answer"                0   ""                       ""                                                         nao-sei 1
step1_case "exit 1 with a body that is not a list"                 1   'Error: boom'            ""                                                         nao-sei 1
step1_case "exit 1 with a non-empty list (not a clean empty)"      1   '[{"id":"x"}]'           ""                                                         nao-sei 1
# the error text must reach the witness, or "nao-sei" cannot be told from a flaky run
run_block "$STEP1" STUB_HOOK_RC=1 STUB_HOOK_ERR='gc hook: work query timed out after 30s'
if printf '%s\n' "$OUT" | grep -F -q 'timed out after 30s'; then ok "nao-sei carries the hook's own error line"; else bad "nao-sei hides WHY gc hook failed: $OUT"; fi
# mktemp is the block's own read of the world: if it fails the block cannot tell, so it says nao-sei
run_block "$STEP1" STUB_MKTEMP_FAIL=1 STUB_HOOK_RC=1 STUB_HOOK_OUT='[]'
if printf '%s\n' "$OUT" | grep -q '^HOOK=nao-sei' && [ "$RC" -eq 1 ] && [ "$(spy_n '^GC hook')" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q 'mktemp falhou'; then
  ok "mktemp fails -> HOOK=nao-sei, exit 1, gc hook not even asked, and the witness is told it was mktemp"
else
  bad "mktemp failure was not handled as nao-sei (exit $RC, spy: $SPY_LOG) :: $OUT"
fi

# ── Group B: Step 3 — the pour is guarded by a pinned read ────────────────────
# step3_nopour LABEL [VAR=value ...]: runs Step 3 and asserts no pour, no assign, rc 1 and the "NÃO SEI" line
step3_nopour() {
  local label="$1"; shift
  run_block "$STEP3" "$@"
  if [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$(spy_n "$ASSIGN_RE")" -eq 0 ] && [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'NÃO SEI\|GC_AGENT vazio'; then
    ok "$label -> no pour, exit 1, says it does not know"
  else
    bad "$label: expected no pour / no assign / exit 1 (got pours=$(spy_n "$POUR_RE"), assigns=$(spy_n "$ASSIGN_RE"), exit $RC) :: $OUT"
  fi
}
echo ""
echo "Group B: Step 3 — only a clean empty read may pour"
# GC_ALIAS differs from GC_AGENT here on purpose: the read must go by GC_AGENT (what the bead and the No-Idle block use), not by the alias Step 3 assigns with
run_block "$STEP3" STUB_ANY_BODY='[]' GC_ALIAS=some-other-alias
if [ "$(spy_n "$POUR_RE")" -eq 1 ] && [ "$(spy_n "$ASSIGN_RE")" -eq 1 ] && [ "$RC" -eq 0 ]; then
  ok "clean empty read ([] and exit 0) -> exactly one pour and one assign, exit 0"
else
  bad "clean empty read did not bootstrap (pours=$(spy_n "$POUR_RE"), assigns=$(spy_n "$ASSIGN_RE"), exit $RC) :: $OUT"
fi
if printf '%s\n' "$SPY_LOG" | grep -F -q "GC bd -C $FAKE_RIG list --assignee=$FAKE_AGENT --type=molecule --include-infra --limit=1 --json"; then
  ok "the guard reads the pinned store, by this witness's identity, molecules incl. infra, limit 1"
else
  bad "the guard read is not the pinned one (-C rig root, --assignee=GC_AGENT, --type=molecule --include-infra --limit=1 --json): $SPY_LOG"
fi
g_read="$(spy_first "$LIST_RE")"; g_pour="$(spy_first "$POUR_RE")"
if [ -n "$g_read" ] && [ -n "$g_pour" ] && [ "$g_read" -lt "$g_pour" ]; then ok "the read comes BEFORE the pour"; else bad "the read does not precede the pour (read line '$g_read', pour line '$g_pour'): $SPY_LOG"; fi

run_block "$STEP3" STUB_ANY_BODY='[{"id":"ga-wisp-live","title":"patrol"}]'
if [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -F -q 'ga-wisp-live'; then
  ok "a wisp of mine already exists -> no pour, names it, exit 0"
else
  bad "existing wisp did not stop the pour (pours=$(spy_n "$POUR_RE"), exit $RC) :: $OUT"
fi

step3_nopour "THE BUG: the read fails (exit 1)" STUB_ANY_RC=1 STUB_ANY_ERR='Error: timed out after 30s'
if printf '%s\n' "$OUT" | grep -F -q 'Error: timed out after 30s'; then ok "the failed read's own error line reaches the witness"; else bad "the read's error line is hidden: $OUT"; fi
step3_nopour "a failing read that still printed [] is not a clean empty" STUB_ANY_RC=1 STUB_ANY_BODY='[]'
step3_nopour "exit 0 but no output at all (truncated read)" STUB_ANY_RC=0 STUB_ANY_BODY=""
step3_nopour "exit 0 with text instead of JSON" STUB_ANY_BODY='Error: database is locked'
step3_nopour "exit 0 with a JSON object, not a list" STUB_ANY_BODY='{"error":"x"}'
step3_nopour "a list element without an id" STUB_ANY_BODY='[{"title":"no id"}]'
step3_nopour "a list element with an empty id" STUB_ANY_BODY='[{"id":""}]'
step3_nopour "GC_AGENT empty: no identity to look for" GC_AGENT= STUB_ANY_BODY='[]'
if [ "$(spy_n "$ANYBD_RE")" -eq 0 ]; then ok "GC_AGENT empty -> the read is not even attempted (an empty --assignee would match anything)"; else bad "a gc bd call went out with an empty GC_AGENT: $SPY_LOG"; fi

# the pour's own checks survive the guard: a pour that fails still stops the bootstrap
run_block "$STEP3" STUB_ANY_BODY='[]' STUB_POUR_RC=1
if [ "$RC" -eq 1 ] && [ "$(spy_n "$ASSIGN_RE")" -eq 0 ]; then ok "a pour that fails after a clean guard still stops before the assign (exit 1)"; else bad "failed pour not handled (exit $RC, assigns=$(spy_n "$ASSIGN_RE")) :: $OUT"; fi

# ── Group C: the No-Idle block — both reads in three states ───────────────────
# noidle_inert LABEL [VAR=value ...]: no pour and no burn, exit 1, says it does not know
noidle_inert() {
  local label="$1"; shift
  run_block "$STEPN" "$@"
  if [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$RC" -eq 1 ] && printf '%s\n' "$OUT" | grep -q 'NÃO SEI\|GC_AGENT vazio'; then
    ok "$label -> no pour, no burn, exit 1"
  else
    bad "$label: expected the inert state (got pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE"), exit $RC) :: $OUT"
  fi
}
CUR='[{"id":"ga-wisp-cur"}]'
NXT='[{"id":"ga-wisp-next"}]'
echo ""
echo "Group C: No-Idle block — a read that fails is not 'empty'"
run_block "$STEPN" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY='[]'
if [ "$(spy_n "$POUR_RE")" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q 'mol burn ga-wisp-cur --force'; then
  ok "current wisp, no next one -> pours the next and burns the current"
else
  bad "baseline broken: current wisp + no next (pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE")) :: $OUT $SPY_LOG"
fi
p="$(spy_first "$POUR_RE")"; b="$(spy_first "$BURN_RE")"
if [ -n "$p" ] && [ -n "$b" ] && [ "$p" -lt "$b" ]; then ok "the pour comes BEFORE the burn"; else bad "burn does not follow the pour (pour line '$p', burn line '$b'): $SPY_LOG"; fi
last="$(printf '%s\n' "$SPY_LOG" | tail -n 1)"
if [ "$last" = "GC hook" ]; then ok "the block still ends with gc hook"; else bad "the block no longer ends with gc hook (last call: '$last')"; fi
if printf '%s\n' "$SPY_LOG" | grep -F -q "GC bd -C $FAKE_RIG list --assignee=$FAKE_AGENT --status=in_progress --type=molecule --include-infra --limit=1 --json" \
   && printf '%s\n' "$SPY_LOG" | grep -F -q "GC bd -C $FAKE_RIG list --assignee=$FAKE_AGENT --status=open --type=molecule --include-infra --limit=1 --json"; then
  ok "both reads keep the pinned shape (-C rig root, by identity, molecule incl. infra, limit 1)"
else
  bad "a read lost its pin/filters: $SPY_LOG"
fi

run_block "$STEPN" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY="$NXT"
if [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ]; then ok "current wisp and a next one -> burns only, no second pour"; else bad "next wisp already there but pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE") :: $OUT"; fi
run_block "$STEPN" STUB_INPROG_BODY='[]' STUB_OPEN_BODY='[]'
if [ "$(spy_n "$POUR_RE")" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ]; then ok "no current and no next -> pours one, burns nothing"; else bad "empty store: pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE") :: $OUT"; fi
run_block "$STEPN" GC_BEAD_ID=ga-wisp-env STUB_OPEN_BODY='[]'
if [ "$(spy_n 'status=in_progress')" -eq 0 ] && [ "$(spy_n "$POUR_RE")" -eq 1 ] && printf '%s\n' "$SPY_LOG" | grep -F -q 'mol burn ga-wisp-env --force'; then
  ok "GC_BEAD_ID names the current wisp: no in_progress read, pours the next, burns that one"
else
  bad "GC_BEAD_ID path changed (in_progress reads=$(spy_n 'status=in_progress'), pours=$(spy_n "$POUR_RE")) :: $OUT $SPY_LOG"
fi

noidle_inert "THE BUG: the next-wisp read fails, a current wisp exists" STUB_INPROG_BODY="$CUR" STUB_OPEN_RC=1 STUB_OPEN_ERR='Error: timed out'
noidle_inert "the next-wisp read fails, no current wisp" STUB_INPROG_BODY='[]' STUB_OPEN_RC=1 STUB_OPEN_ERR='Error: timed out'
noidle_inert "the current-wisp read fails" STUB_INPROG_RC=1 STUB_INPROG_ERR='Error: timed out' STUB_OPEN_BODY='[]'
noidle_inert "a failing read that still printed [] (next wisp)" STUB_INPROG_BODY="$CUR" STUB_OPEN_RC=1 STUB_OPEN_BODY='[]'
noidle_inert "a failing read that still printed [] (current wisp)" STUB_INPROG_RC=1 STUB_INPROG_BODY='[]' STUB_OPEN_BODY='[]'
noidle_inert "next-wisp read: exit 0 with text instead of JSON" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY='Error: database is locked'
noidle_inert "next-wisp read: exit 0, no output" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY=""
noidle_inert "next-wisp read: exit 0 with a JSON object, not a list" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY='{"error":"x"}'
noidle_inert "current-wisp read: a list element without an id" STUB_INPROG_BODY='[{"title":"x"}]' STUB_OPEN_BODY='[]'
noidle_inert "GC_AGENT empty" GC_AGENT= STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY='[]'
if [ "$(spy_n "$LIST_RE")" -eq 0 ]; then ok "GC_AGENT empty -> no read attempted"; else bad "a list read went out with an empty GC_AGENT: $SPY_LOG"; fi
if printf '%s\n' "$OUT" | grep -F -q 'GC_AGENT vazio'; then ok "GC_AGENT empty is reported as such"; else bad "empty GC_AGENT is not named: $OUT"; fi

# a rig without RigRoot keeps the documented graceful fallback (no -C, said out loud), and the three states still hold there
STEPN_NORIG="$(extract_block "$HN" "")"
run_block "$STEPN_NORIG" STUB_INPROG_BODY="$CUR" STUB_OPEN_BODY='[]'
if [ "$(spy_n "$POUR_RE")" -eq 1 ] && [ "$(spy_n "$BURN_RE")" -eq 1 ] && [ "$(spy_n '^GC bd list ')" -eq 2 ] && printf '%s\n' "$OUT" | grep -q 'WARNING:.*is empty'; then
  ok "empty RigRoot: warns, reads without -C (cwd store), still pours the next and burns the current"
else
  bad "empty-RigRoot fallback broke (pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE"), unpinned reads=$(spy_n '^GC bd list ')) :: $OUT $SPY_LOG"
fi
run_block "$STEPN_NORIG" STUB_INPROG_BODY="$CUR" STUB_OPEN_RC=1 STUB_OPEN_ERR='Error: timed out'
if [ "$(spy_n "$POUR_RE")" -eq 0 ] && [ "$(spy_n "$BURN_RE")" -eq 0 ] && [ "$RC" -eq 1 ]; then
  ok "empty RigRoot: a failing read is still the inert state (no pour, no burn, exit 1)"
else
  bad "empty RigRoot + failing read was not inert (pours=$(spy_n "$POUR_RE"), burns=$(spy_n "$BURN_RE"), exit $RC) :: $OUT"
fi

# ── Group D: the section keeps saying what the code does ──────────────────────
echo ""
echo "Group D: the prompt text agrees with the blocks"
SECTION="$(sed -n '/WITNESS: o Startup Protocol/,$p' "$TEMPLATE")"
if printf '%s\n' "$SECTION" | grep -F -q 'ga-6zrshxb' && printf '%s\n' "$SECTION" | grep -F -q 'HOOK=nao-sei'; then
  ok "the section cites ga-6zrshxb and tells the witness what HOOK=nao-sei means"
else
  bad "the section does not explain HOOK=nao-sei / cite ga-6zrshxb"
fi
if printf '%s\n' "$SECTION" | grep -F -q '/tmp/witness-hook.json'; then
  bad "the shared /tmp/witness-hook.json is back (every witness on the machine wrote the same file, stdout and stderr mixed)"
else
  ok "no shared /tmp/witness-hook.json (the block makes its own temp file and keeps stderr apart)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
