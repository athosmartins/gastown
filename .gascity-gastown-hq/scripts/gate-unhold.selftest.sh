#!/usr/bin/env bash
# gate-unhold.selftest.sh — Prove the ga-6qbgy fix in isolation, no live Dolt.
#
# THE BUG: `bd label remove <id> <label>` only removes an EXACT name, but the
# guards that VETO on these labels (quality-gate-guard.sh Step 5a and others)
# match a whole PREFIX FAMILY (gate:needs-human, gate:needs-human:technical,
# gate:needs-human:refused, ...). An operator who removes the bare label and
# re-verifies by exact name sees a clean list and declares the veto cleared,
# while a sibling variant silently keeps vetoing. Real incident: wa-vcd01,
# 2026-08-06 — ~4h of blocked crew work plus a dead marker.
#
# THE FALSIFIABLE TEST THE BUG REPORT ASKS FOR (verbatim from ga-6qbgy's
# ACEITE): "bead com gate:needs-human E gate:needs-human:technical; apos a
# liberacao, a consulta por PREFIXO volta vazia (um teste que so cheque o
# nome exato passa com o bug intacto)." Section 2 below is exactly this test,
# plus a CONTROL (section 3) that proves it discriminates: an exact-name-only
# removal (the pre-fix manual procedure) leaves the sibling variant behind,
# and this harness's own prefix-based verification catches that — where a
# verification that only checked the exact name removed would not.
#
# This harness sources gate-unhold.sh in lib-only mode (GATE_UNHOLD_LIB_ONLY=1)
# with `bd`/`gc` replaced by file-backed mocks (bash 3.2 has no associative
# arrays — same pattern as gate-marker-dedup-by-branch.selftest.sh's
# BD_LABELS_FILE), so it exercises the REAL removal-loop-then-verify logic
# without ever touching production Dolt.
#
# THE MOCKS MODEL THE REAL TOPOLOGY (ga-sa4jcb). Until 2026-10-06 `gc` was
# mocked as "always down", so every bead — wa-* included — was served by the
# `bd -C` mock and the suite could not see that the real `bd -C <HQ city>`
# only reaches the HQ store ("no issue found" for a wa-* id) while the
# removal was hard-wired to it. Now:
#   gc --city C bd ...  routes by bead-id prefix -> reaches HQ (ga-*) AND rig (wa-*)
#   bd -C C ...         HQ store ONLY            -> a wa-* id is "no issue found"
#
# ga-iu0fvlo: the exit CODES and the "which branch said it" of the failure paths now have a case each (section 10), with embedded mutants (one loose edit of
# the tool, the case must FAIL): no prefix at all = usage error rc 2 · a bead that cannot be read = rc 1 "could not read" (NEVER "nothing to do", rc 0) ·
# a failed removal is summarised by "FAILED — could not remove from <bead>: <labels>" (not by the verify step's "still present") · a re-fetch that fails after
# the removals = rc 1 "UNVERIFIED" (never "verified clear"). Sections 2-9 only looked at "non-zero" or at the message text, so an `exit 1` -> `exit 0` went unseen.
# EQUIVALENT (dd375a676b, L113 `… | sed 's/ *$//' || true` with `||` -> `&&`): _one_line is only ever called inside a `$( )` (errexit is off there) and when the pipeline
#   fails it is because grep -v printed nothing, so `out` is empty either way and "no output" is printed either way; the only thing that changes is an rc nobody reads.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SELF_DIR/gate-unhold.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

[ -f "$TOOL" ] || { echo "FATAL: $TOOL not found"; exit 1; }

# ── Load the pure functions from the tool (no live bead) ─────────────────────
GATE_UNHOLD_LIB_ONLY=1 source "$TOOL" \
  || { echo "FATAL: could not source gate-unhold.sh in lib-only mode"; exit 1; }

type matching_veto_labels >/dev/null 2>&1 \
  || { echo "FATAL: matching_veto_labels not defined (lib-only sourcing broken?)"; exit 1; }
type gate_unhold_main >/dev/null 2>&1 \
  || { echo "FATAL: gate_unhold_main not defined (lib-only sourcing broken?)"; exit 1; }

# ── 1. matching_veto_labels — same matching-rule unit coverage as the guard's ─
#      copy (kept in sync by inspection; this drift-guards THIS file's copy).
echo "── 1. matching_veto_labels: bare-or-colon-suffixed prefix match ──"
eq "bare + sibling variant both present -> echoes BOTH" \
  "$(matching_veto_labels 'gate:needs-human gate:needs-human:technical lane:small' 'gate:needs-human')" \
  "gate:needs-human gate:needs-human:technical"
eq "no match -> empty" \
  "$(matching_veto_labels 'gate:needs-fix lane:small' 'gate:needs-human')" \
  ""
eq "does not false-match a mere substring" \
  "$(matching_veto_labels 'gate:needs-human-ish' 'gate:needs-human')" \
  ""

# ── Mock bd/gc: file-backed label state, no live Dolt ─────────────────────────
GC_UP=1               # 0 = `gc` itself is unavailable (exercises the bd -C fallback)
BD_LABELS_FILE="$(mktemp)"
BD_REMOVE_LOG="$(mktemp)"   # one line per `label remove` attempt: "<route> <id> <label>"
BD_REMOVE_IS_NOOP=0   # when 1, `label remove` reports success but does NOT mutate state
REMOVE_FAIL_LABEL=""  # when set, `label remove` of exactly this label exits 1 ("boom")
SHOW_FAIL_FROM=""     # when set to N, the Nth `show` and every later one print nothing and exit 1 (counter in SHOW_COUNT_FILE)
SHOW_COUNT_FILE="$(mktemp)"

seed_labels() {
  : > "$BD_LABELS_FILE"
  local lbl
  for lbl in "$@"; do echo "$lbl" >> "$BD_LABELS_FILE"; done
}

labels_now() { paste -sd' ' "$BD_LABELS_FILE" 2>/dev/null || true; }

current_labels_json() {
  jq -R -s -c 'split("\n") | map(select(length > 0))' < "$BD_LABELS_FILE"
}

# The store itself. <route> is who reached it (gc|bd); only used for the log.
fake_store() {
  local route="$1"; shift
  local -a A=("$@")
  local n=${#A[@]} i verb=""
  for ((i = 0; i < n; i++)); do
    case "${A[i]}" in
      show|label) [ -z "$verb" ] && verb="${A[i]}" ;;
    esac
  done
  case "$verb" in
    show)
      if [ -n "${SHOW_FAIL_FROM:-}" ]; then   # the counter is a file: fetch_labels runs inside $( )
        local k; k=$(( $(cat "$SHOW_COUNT_FILE" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$SHOW_COUNT_FILE"
        if [ "$k" -ge "$SHOW_FAIL_FROM" ]; then echo "Error: show failed" >&2; return 1; fi
      fi
      printf '{"labels": %s}\n' "$(current_labels_json)"
      ;;
    label)
      for ((i = 0; i < n; i++)); do
        if [ "${A[i]}" = "remove" ]; then
          local id="${A[i+1]}" lbl="${A[i+2]}"
          echo "$route $id $lbl" >> "$BD_REMOVE_LOG"
          if [ -n "$REMOVE_FAIL_LABEL" ] && [ "$lbl" = "$REMOVE_FAIL_LABEL" ]; then
            echo "Error: boom: dolt unavailable" >&2
            return 1
          fi
          if [ "$BD_REMOVE_IS_NOOP" = "1" ]; then
            return 0   # reports success but leaves BD_LABELS_FILE untouched
          fi
          grep -vxF "$lbl" "$BD_LABELS_FILE" > "$BD_LABELS_FILE.tmp" 2>/dev/null || true
          mv "$BD_LABELS_FILE.tmp" "$BD_LABELS_FILE"
          break
        fi
      done
      ;;
  esac
  return 0
}

# gc --city C bd <args>: prefix-routed, reaches every store.
gc() {
  [ "$GC_UP" = "1" ] || return 1
  [ "${1:-}" = "--city" ] && shift 2
  [ "${1:-}" = "bd" ] && shift
  fake_store gc "$@"
}

# bd [-C dir] <args>: the HQ store only. A non-ga-* id is what the real bd says
# for a rig bead looked up in the HQ store — and the attempt is logged as a
# "bd-miss" so a test can assert the HQ-only path was never asked to write.
bd() {
  [ "${1:-}" = "-C" ] && shift 2
  local -a A=("$@")
  local n=${#A[@]} i id="" is_remove=0 lbl=""
  for ((i = 0; i < n; i++)); do
    case "${A[i]}" in
      show) id="${A[i+1]:-}" ;;
      remove) id="${A[i+1]:-}"; lbl="${A[i+2]:-}"; is_remove=1 ;;
    esac
  done
  case "$id" in
    ga-*) fake_store bd "$@" ;;
    *)
      [ "$is_remove" = "1" ] && echo "bd-miss $id $lbl" >> "$BD_REMOVE_LOG"
      echo "Error: resolving issue ID \"$id\": no issue found matching \"$id\"" >&2
      return 1
      ;;
  esac
}

# ── 2. THE test the bug report asks for: bare + :technical -> prefix query empty ─
#      On a RIG bead (wa-*) — the case ga-sa4jcb found broken: the read went
#      through `gc bd` (prefix-routed) but the removal went to `bd -C <HQ>`,
#      which cannot see a wa-* id.
echo "── 2. AC1/AC2: rig bead (wa-*) with gate:needs-human AND gate:needs-human:technical ──"
seed_labels "lane:small" "gate:needs-human" "gate:needs-human:technical" "story:approved"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=0

RC=0
gate_unhold_main "wa-test" "gate:needs-human" || RC=$?
eq "gate_unhold_main exits 0 (cleared+verified)" "$RC" "0"

eq "BOTH the bare label and the :technical sibling were removed, through gc (prefix-routed)" \
  "$(grep -c '^gc wa-test ' "$BD_REMOVE_LOG" || true)" \
  "2"

eq "the HQ-only bd -C store was never asked to remove a rig bead's label (ga-sa4jcb)" \
  "$(grep -c '^bd-miss ' "$BD_REMOVE_LOG" || true)" \
  "0"

REMAINING_MATCH=$(matching_veto_labels "$(labels_now)" "gate:needs-human")
eq "a PREFIX query afterward returns EMPTY (the exact AC1 acceptance check)" \
  "$REMAINING_MATCH" \
  ""

eq "unrelated labels (lane:small, story:approved) are left untouched" \
  "$(labels_now)" \
  "lane:small story:approved"

# ── 3. CONTROL — exact-name-only removal (the pre-fix manual procedure) ──────
#      leaves the sibling variant behind. This proves the test in section 2
#      is falsifiable: it fails if run against the OLD behavior.
echo "── 3. CONTROL: exact-name-only removal reproduces the original incident ──"
seed_labels "gate:needs-human" "gate:needs-human:technical"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=0
gc --city x bd label remove "wa-test" "gate:needs-human" -q   # the pre-fix manual step: remove ONLY the bare name
EXACT_NAME_VERIFY=$(labels_now | grep -c '^gate:needs-human$' || true)
PREFIX_VERIFY=$(matching_veto_labels "$(labels_now)" "gate:needs-human")
if [ "$EXACT_NAME_VERIFY" = "0" ] && [ -n "$PREFIX_VERIFY" ]; then
  ok "control: exact-name check says 'clear' while prefix check still sees $PREFIX_VERIFY (the false-positive this bug report describes)"
else
  bad "control: could not reproduce the exact-name-vs-prefix divergence — test may no longer discriminate"
fi

# ── 4. Silent-failure detection: `bd label remove` ACKs but doesn't mutate ───
#      state (e.g. a Dolt hiccup that returns success without committing).
#      gate_unhold_main must catch this via its post-remove verify, not trust
#      the exit code alone (ga-6qbgy's own sibling doctrine: verify the
#      effect, not the return).
echo "── 4. verify-after-remove catches a silently-failed bd label remove ──"
seed_labels "gate:needs-human" "gate:needs-human:technical"
: > "$BD_REMOVE_LOG"
BD_REMOVE_IS_NOOP=1
RC=0
OUT_FILE="$(mktemp)"
gate_unhold_main "wa-test" "gate:needs-human" >"$OUT_FILE" 2>&1 || RC=$?
eq "gate_unhold_main exits non-zero when a matching label survives verification" \
  "$([ "$RC" != "0" ] && echo nonzero || echo zero)" \
  "nonzero"
grep -qi "FAILED" "$OUT_FILE" \
  && ok "failure output names the survival explicitly" \
  || bad "failure output does not explain what survived"
rm -f "$OUT_FILE"
BD_REMOVE_IS_NOOP=0

# ── 5. No match -> no-op, exit 0, no remove calls issued ─────────────────────
echo "── 5. no matching label -> no-op ──"
seed_labels "lane:small" "story:approved"
: > "$BD_REMOVE_LOG"
RC=0
gate_unhold_main "wa-test" "gate:needs-human" || RC=$?
eq "exits 0 when nothing matches" "$RC" "0"
eq "issues zero remove calls when nothing matches" "$(grep -c . "$BD_REMOVE_LOG" || true)" "0"

# ── 6. Multiple prefixes cleared in ONE call (real incident used 4 families) ─
echo "── 6. multiple veto families cleared in a single invocation ──"
seed_labels "gate:needs-human" "gate:needs-human:technical" "pilot:no-auto-dispatch" "lane:small"
: > "$BD_REMOVE_LOG"
RC=0
gate_unhold_main "wa-test" "gate:needs-human" "pilot:no-auto-dispatch" || RC=$?
eq "exits 0" "$RC" "0"
eq "all 3 veto labels removed, lane:small untouched" "$(labels_now)" "lane:small"

# ── 7. HQ bead with gc unavailable -> falls back to bd -C for read AND write ─
#      Same fallback order fetch_labels always had; the write must follow the
#      read so a bead is cleared in the store it was read from.
echo "── 7. gc down: HQ bead (ga-*) still cleared via the bd -C fallback ──"
seed_labels "gate:needs-human" "gate:needs-human:technical" "lane:small"
: > "$BD_REMOVE_LOG"
GC_UP=0
RC=0
gate_unhold_main "ga-test" "gate:needs-human" || RC=$?
eq "exits 0 through the fallback" "$RC" "0"
eq "both removals went through bd -C (the only store reachable)" \
  "$(grep -c '^bd ga-test ' "$BD_REMOVE_LOG" || true)" "2"
eq "labels cleared, unrelated label kept" "$(labels_now)" "lane:small"
GC_UP=1

# ── 8. A removal that FAILS is reported and exits non-zero (ga-sa4jcb) ───────
#      The bug report's second ask: "erro de remocao tem de sair != 0 com
#      mensagem clara". The message must say the REMOVAL failed (not merely
#      that a label 'survived', which is what the verify step says), name the
#      label and bead, and carry the store's own error. The remaining labels
#      are still attempted — partial progress beats stopping at the first error.
echo "── 8. a failed removal -> non-zero, clear message, the rest still attempted ──"
seed_labels "gate:needs-human" "gate:needs-human:technical" "lane:small"
: > "$BD_REMOVE_LOG"
REMOVE_FAIL_LABEL="gate:needs-human"
OUT_FILE="$(mktemp)"
RC=0
gate_unhold_main "wa-test" "gate:needs-human" >"$OUT_FILE" 2>&1 || RC=$?
REMOVE_FAIL_LABEL=""
eq "exits non-zero when a removal fails" \
  "$([ "$RC" != "0" ] && echo nonzero || echo zero)" "nonzero"
grep -q "could not remove gate:needs-human from wa-test" "$OUT_FILE" \
  && ok "message names the label and the bead that could not be cleared" \
  || bad "no 'could not remove <label> from <bead>' message; output was: $(cat "$OUT_FILE")"
grep -q "boom: dolt unavailable" "$OUT_FILE" \
  && ok "message carries the store's own error text" \
  || bad "store's error text was swallowed; output was: $(cat "$OUT_FILE")"
eq "the sibling variant was still attempted and removed" "$(labels_now)" "gate:needs-human lane:small"
rm -f "$OUT_FILE"

# ── 9. Same failure through the REAL entrypoint (set -e is live there) ───────
#      Sections 2-8 call gate_unhold_main under `|| RC=$?`, where bash turns
#      `set -e` OFF — so they cannot see what the script does when it is run
#      for real. Run it as a child process (mock functions exported) and check
#      the operator gets the clear message, not a bare bd error and a silent exit.
echo "── 9. failed removal via the real entrypoint (set -e active) ──"
seed_labels "gate:needs-human" "lane:small"
: > "$BD_REMOVE_LOG"
REMOVE_FAIL_LABEL="gate:needs-human"
export -f gc bd fake_store current_labels_json
export BD_LABELS_FILE BD_REMOVE_LOG BD_REMOVE_IS_NOOP REMOVE_FAIL_LABEL GC_UP
OUT_FILE="$(mktemp)"
RC=0
env -u GATE_UNHOLD_LIB_ONLY bash "$TOOL" wa-test gate:needs-human >"$OUT_FILE" 2>&1 || RC=$?
REMOVE_FAIL_LABEL=""
eq "entrypoint exits 1 on a failed removal" "$RC" "1"
grep -q "could not remove gate:needs-human from wa-test" "$OUT_FILE" \
  && ok "entrypoint prints the clear failure message" \
  || bad "entrypoint gave no clear message; output was: $(cat "$OUT_FILE")"
rm -f "$OUT_FILE"

# ── 10. ga-iu0fvlo: exit codes and failure branches, each with its own case ──────
#      A case that cannot be measured (no output at all) is a FAIL here, never a silent pass:
#      every assertion compares a captured rc/text, and an empty capture does not equal the expected one.
case_sem_prefixo() {   # no prefix at all -> usage error, rc 2, nothing read or removed
  local RC=0 OUT
  seed_labels "gate:needs-human"; : > "$BD_REMOVE_LOG"
  OUT=$(gate_unhold_main "wa-test" 2>&1) || RC=$?
  eq "no prefix: usage error rc 2" "$RC" "2"
  case "$OUT" in *"usage: gate-unhold.sh"*) ok "no prefix: prints the usage" ;; *) bad "no prefix: no usage line; output was: $OUT" ;; esac
  eq "no prefix: nothing was removed" "$(grep -c . "$BD_REMOVE_LOG" || true)" "0"
}
case_bead_ilegivel() {   # gc down and bd -C cannot reach the bead: the labels are UNKNOWN -> rc 1 "could not read", never "nothing to do" (rc 0)
  local RC=0 OUT
  seed_labels "gate:needs-human"; : > "$BD_REMOVE_LOG"; GC_UP=0
  OUT=$(gate_unhold_main "wa-test" "gate:needs-human" 2>&1) || RC=$?
  GC_UP=1
  eq "unreadable bead: rc 1" "$RC" "1"
  case "$OUT" in *"could not read bead wa-test"*) ok "unreadable bead: says it could not read it" ;; *) bad "unreadable bead: no 'could not read bead' line; output was: $OUT" ;; esac
  case "$OUT" in *"nothing to do"*) bad "unreadable bead reported 'nothing to do' (unknown read as 'no veto')" ;; *) ok "unreadable bead: never reported as 'nothing to do'" ;; esac
  eq "unreadable bead: nothing was removed" "$(grep -c . "$BD_REMOVE_LOG" || true)" "0"
}
case_falha_remocao_resumo() {   # a failed removal ends in the removal summary, not in the verify step's "still present"
  local RC=0 OUT
  seed_labels "gate:needs-human" "lane:small"; : > "$BD_REMOVE_LOG"; REMOVE_FAIL_LABEL="gate:needs-human"
  OUT=$(gate_unhold_main "wa-test" "gate:needs-human" 2>&1) || RC=$?
  REMOVE_FAIL_LABEL=""
  eq "failed removal: rc 1" "$RC" "1"
  case "$OUT" in *"FAILED — could not remove from wa-test: gate:needs-human"*) ok "failed removal: the summary names bead and label" ;; *) bad "failed removal: no removal summary; output was: $OUT" ;; esac
  case "$OUT" in *"still present"*) bad "failed removal went on to the verify step ('still present')" ;; *) ok "failed removal: stops before the verify step" ;; esac
}
case_refetch_falha() {   # the removals worked but the verify re-fetch fails -> rc 1 UNVERIFIED, never "verified clear"
  local RC=0 OUT
  seed_labels "gate:needs-human" "lane:small"; : > "$BD_REMOVE_LOG"; echo 0 > "$SHOW_COUNT_FILE"; SHOW_FAIL_FROM=2
  OUT=$(gate_unhold_main "wa-test" "gate:needs-human" 2>&1) || RC=$?
  SHOW_FAIL_FROM=""
  eq "re-fetch fails: rc 1" "$RC" "1"
  case "$OUT" in *"could not re-fetch wa-test to verify"*) ok "re-fetch fails: says UNVERIFIED" ;; *) bad "re-fetch fails: no 'could not re-fetch' line; output was: $OUT" ;; esac
  case "$OUT" in *"verified clear"*) bad "re-fetch fails but the run said 'verified clear'" ;; *) ok "re-fetch fails: never 'verified clear'" ;; esac
  eq "re-fetch fails: the removal itself did happen" "$(labels_now)" "lane:small"
}
echo "── 10. exit codes and failure branches (ga-iu0fvlo) ──"
case_sem_prefixo; case_bead_ilegivel; case_falha_remocao_resumo; case_refetch_falha

echo "── 10b. mutants: one loose edit of the tool, the case must FAIL ──"
mutant() {   # name · original piece (\n = newline) · loose piece · case that must catch it
  local name="$1" old="$2" new="$3" case_fn="$4" res mut
  mut="$(mktemp)"
  if ! python3 - "$TOOL" "$old" "$new" > "$mut" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[2].replace("\\n", "\n"), sys.argv[3].replace("\\n", "\n")
if src.count(old) != 1:
    sys.exit(3)
sys.stdout.write(src.replace(old, new))
PY
  then bad "mutant $name: the original piece does not appear exactly once in the tool (did the tool change?)"; rm -f "$mut"; return; fi
  res=$( ( GATE_UNHOLD_LIB_ONLY=1 source "$mut"; $case_fn ) 2>&1 ) || true
  rm -f "$mut"
  if printf '%s\n' "$res" | grep -q '^  FAIL'; then ok "mutant $name killed by $case_fn"; else bad "mutant $name SURVIVED $case_fn"; fi
}
mutant uso-vira-ok            'return 2' 'return 0' case_sem_prefixo
mutant leitura-ilegivel-ok    '[ -n "$raw" ] || return 1' '[ -n "$raw" ] || return 0' case_bead_ilegivel
mutant leitura-sem-return     '[ -n "$raw" ] || return 1' '[ -n "$raw" ]' case_bead_ilegivel
mutant main-ilegivel-rc-0     'both failed/empty)" >&2\n    return 1' 'both failed/empty)" >&2\n    return 0' case_bead_ilegivel
mutant remocao-falha-rc-0     'bd -C fallback: $(_one_line "$bd_err")" >&2\n  return 1' 'bd -C fallback: $(_one_line "$bd_err")" >&2\n  return 0' case_falha_remocao_resumo
mutant refetch-falha-rc-0     'treat as UNVERIFIED, check manually" >&2\n    return 1' 'treat as UNVERIFIED, check manually" >&2\n    return 0' case_refetch_falha

rm -f "$BD_LABELS_FILE" "$BD_LABELS_FILE.tmp" "$BD_REMOVE_LOG" "$SHOW_COUNT_FILE"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
