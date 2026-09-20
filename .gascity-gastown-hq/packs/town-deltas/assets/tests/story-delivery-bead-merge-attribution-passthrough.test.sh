#!/usr/bin/env bash
# story-delivery-bead-merge-attribution-passthrough.test.sh — regression test
# for ga-xz3ypu (extracts the real Step 5b block from story-delivery.sh, no
# duplication — same technique as story-delivery-step5b.test.sh and
# story-delivery-daemon-refresh-attribution.test.sh).
#
# THE BUG: daemon-refresh.sh's Step 1b (ga-agracx) only classifies a missing/
# unloaded scheduled-job plist as SJ_MISSING_UNATTRIB (another bead's gap —
# non-blocking) instead of SJ_MISSING (this bead's own fault — blocking) when
# it receives BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA and can prove THIS bead's own
# merge diff doesn't touch that plist. That guard logic is already correct
# and already covered by daemon-refresh-bead-attribution.test.sh — but BOTH
# of story-delivery.sh's calls into daemon-refresh.sh (the Step 5b DRY_RUN
# classification probe and the real call below) never set these two vars, so
# the guard's "unknown defaults to attributable" branch was the ONLY behavior
# that ever ran for a story-delivery.sh-driven deploy — see that test file's
# own T3 ("attribution inputs simply absent (uncalled caller, e.g. story-
# delivery.sh today)"). Confirmed live: wa-a7tca and wa-8urdy (2026-09-17)
# held on a plist from an unrelated bead's commit.
#
# THE FIX: the real (non-DRY_RUN) call site now passes
# BEAD_MERGE_PRE_SHA="${MERGE_PRE_MAIN:-}" BEAD_MERGE_SHA="${MERGE_SHA:-}" —
# the exact same convention quality-gate-dispatcher.sh's own call site
# already uses successfully (its MERGE_PRE_MAIN_SHA/MERGE_SHA are this file's
# MERGE_PRE_MAIN/MERGE_SHA). This file does NOT re-test daemon-refresh.sh's
# classification logic (already exhaustively covered elsewhere) — only that
# the two values actually reach the subprocess env correctly.
#
# T1 (the repro + fix proof, Path A — the common case): a real merge is known
#     (MERGE_PRE_MAIN/MERGE_SHA resolve to real commits) and this iteration's
#     own pull actually advanced (PRE_DEPLOY_SHA != POST_DEPLOY_SHA), so the
#     Step 5b elif above (which only assigns MERGE_OWN_BASE_SHA on the
#     PRE==POST no-op path) never runs. Asserts the block still completes
#     (rc=0 — no unbound-variable abort under this file's set -u) and the
#     daemon-refresh.sh subprocess receives BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA
#     exactly equal to MERGE_PRE_MAIN/MERGE_SHA.
# T2 (no merge info available at all — the pre-existing degraded case):
#     MERGE_SHA/MERGE_PRE_MAIN both empty (extract_gate_merge_pre_main found
#     nothing, or an older-format merge comment). Asserts the block still
#     completes (rc=0) and the subprocess receives both vars as the empty
#     string — never "unbound variable", never a stale guess.
# T3 (Path B — this iteration's own pull was a true no-op, PRE==POST): proves
#     the new pass-through and the pre-existing Step 5b MERGE_OWN_BASE_SHA
#     probe (ga-6zkhci) do not interfere with each other — both fire, both
#     get their expected values.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DELIVERY="$SCRIPT_DIR/../story-delivery.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

# Extract the Step 5b block (from its header up to, but excluding, Step 6) —
# identical technique to story-delivery-daemon-refresh-attribution.test.sh.
BLOCK="$(sed -n '/Step 5b: Daemon freshness refresh/,/# ── Step 6: Run prod test/p' "$DELIVERY" | sed '$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract Step 5b block"; exit 1; }

# run_block <path_kind>
# path_kind=A:   PRE_DEPLOY_SHA != POST_DEPLOY_SHA (Path A, elif above never
#                runs), MERGE_PRE_MAIN/MERGE_SHA set to real commits.
# path_kind=A0:  same Path A, but MERGE_PRE_MAIN/MERGE_SHA both empty.
# path_kind=B:   PRE_DEPLOY_SHA == POST_DEPLOY_SHA (Path B, the pre-existing
#                elif DOES run), MERGE_PRE_MAIN/MERGE_SHA set to real commits.
run_block() {
  local path_kind="$1"
  local T; T="$(mktemp -d)"
  GC_CITY="$T/city"
  mkdir -p "$GC_CITY/packs/town-deltas/assets"

  local REPO="$T/runtime"
  git init -q "$REPO"
  git -C "$REPO" config user.email t@t.local
  git -C "$REPO" config user.name t
  echo base > "$REPO/base.txt"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$REPO" rev-parse HEAD)"
  mkdir -p "$REPO/lib"
  echo own > "$REPO/lib/own.py"
  git -C "$REPO" add -A; git -C "$REPO" commit -q -m C1
  local SHA_C1; SHA_C1="$(git -C "$REPO" rev-parse HEAD)"

  # Stub records what it ACTUALLY received (GOT_*) to a file — not to its own
  # stdout, which the real block's own $(...) capture (into REFRESH_OUT, a
  # variable local to the eval'd block below) would otherwise swallow before
  # this test could ever see it — alongside a clean VERDICT=OK so the real
  # block's parsing/baseline-advance logic runs its simplest path. The
  # classification logic itself is daemon-refresh.sh's own, already covered
  # by daemon-refresh-bead-attribution.test.sh; this test only proves the two
  # env vars reach the real subprocess the real block actually invokes.
  # $T expands NOW (unquoted heredoc, fixed per run_block call); the
  # backslash-escaped ${BEAD_MERGE_*} expand LATER, inside the stub, when
  # daemon-refresh.sh's real call site (inside $BLOCK) actually runs it.
  GOT_ENV_FILE="$T/got-env.log"
  cat > "$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh" <<EOF
echo "VERDICT=OK"
echo "REASON="
echo "RESTARTED="
echo "GUARDED="
echo "FRESH_FAIL="
echo "PROOF=not_applicable"
{
  echo "GOT_BEAD_MERGE_PRE_SHA=\${BEAD_MERGE_PRE_SHA-<UNSET>}"
  echo "GOT_BEAD_MERGE_SHA=\${BEAD_MERGE_SHA-<UNSET>}"
} > "$GOT_ENV_FILE"
exit 0
EOF

  LOG_FILE="$T/log.log"; BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"
  bd()   { echo "bd $*" >> "$BD_LOG"; }
  gc()   { echo "gc $*" >> "$GC_LOG"; }
  log()  { echo "$*" >> "$LOG_FILE"; }
  warn() { echo "WARN: $*" >> "$LOG_FILE"; }
  err()  { echo "ERR: $*" >> "$LOG_FILE"; }
  export -f bd gc log warn err 2>/dev/null || true

  local RIG="whatsapp_automation"
  local RUNTIME_DIR="$REPO"
  local DEPLOY_EPOCH=1
  local DRY_RUN=0
  local STORY_ID="ga-test"
  local STORY='{"assignee":"crew/tester","created_by":"tester"}'
  local STORY_STORE="$GC_CITY"
  local PRE_DEPLOY_SHA POST_DEPLOY_SHA MERGE_SHA MERGE_PRE_MAIN
  case "$path_kind" in
    A)
      PRE_DEPLOY_SHA="$SHA_C0"; POST_DEPLOY_SHA="$SHA_C1"
      MERGE_PRE_MAIN="$SHA_C0"; MERGE_SHA="$SHA_C1"
      ;;
    A0)
      PRE_DEPLOY_SHA="$SHA_C0"; POST_DEPLOY_SHA="$SHA_C1"
      MERGE_PRE_MAIN=""; MERGE_SHA=""
      ;;
    B)
      PRE_DEPLOY_SHA="$SHA_C1"; POST_DEPLOY_SHA="$SHA_C1"
      MERGE_PRE_MAIN="$SHA_C0"; MERGE_SHA="$SHA_C1"
      ;;
  esac
  get_runbook_field() { echo ""; }

  rm -f "$GOT_ENV_FILE"
  ( eval "$BLOCK" ) >/dev/null 2>&1
  RUN_RC=$?
  LOG_OUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
  # What the REAL call site inside $BLOCK actually passed — written by the
  # stub itself (see above), so this is the genuine invocation, not a
  # reconstruction of what this test THINKS should have been passed.
  REFRESH_ECHO="$(cat "$GOT_ENV_FILE" 2>/dev/null || true)"
  EXPECT_C0="$SHA_C0"; EXPECT_C1="$SHA_C1"
  rm -rf "$T"
}

# ── T1: Path A, real merge known → subprocess receives it verbatim ─────────
run_block A
[ "$RUN_RC" -eq 0 ] && ok "T1 block completes clean under set -u (rc=0) on the common Path A" \
  || nok "T1 rc" "rc=$RUN_RC log=[$LOG_OUT]"
GOT_PRE="$(field GOT_BEAD_MERGE_PRE_SHA "$REFRESH_ECHO")"
GOT_SHA="$(field GOT_BEAD_MERGE_SHA "$REFRESH_ECHO")"
[ "$GOT_PRE" = "$EXPECT_C0" ] && ok "T1 daemon-refresh.sh receives BEAD_MERGE_PRE_SHA = this bead's own merge base" \
  || nok "T1 BEAD_MERGE_PRE_SHA" "got '$GOT_PRE' want '$EXPECT_C0' out=[$REFRESH_ECHO]"
[ "$GOT_SHA" = "$EXPECT_C1" ] && ok "T1 daemon-refresh.sh receives BEAD_MERGE_SHA = this bead's own merge sha" \
  || nok "T1 BEAD_MERGE_SHA" "got '$GOT_SHA' want '$EXPECT_C1' out=[$REFRESH_ECHO]"

# ── T2: Path A, no merge info at all → subprocess receives empty, not
#        unbound/crash ──────────────────────────────────────────────────────
run_block A0
[ "$RUN_RC" -eq 0 ] && ok "T2 block completes clean under set -u with no merge info available" \
  || nok "T2 rc" "rc=$RUN_RC log=[$LOG_OUT]"
GOT_PRE="$(field GOT_BEAD_MERGE_PRE_SHA "$REFRESH_ECHO")"
GOT_SHA="$(field GOT_BEAD_MERGE_SHA "$REFRESH_ECHO")"
[ -z "$GOT_PRE" ] && ok "T2 BEAD_MERGE_PRE_SHA passed as empty string (never unset, never a guess)" \
  || nok "T2 BEAD_MERGE_PRE_SHA" "got '$GOT_PRE' out=[$REFRESH_ECHO]"
[ -z "$GOT_SHA" ] && ok "T2 BEAD_MERGE_SHA passed as empty string (never unset, never a guess)" \
  || nok "T2 BEAD_MERGE_SHA" "got '$GOT_SHA' out=[$REFRESH_ECHO]"

# ── T3: Path B (this iteration's own pull was a true no-op) — new pass-
#        through coexists with the pre-existing MERGE_OWN_BASE_SHA probe ────
run_block B
[ "$RUN_RC" -eq 0 ] && ok "T3 block completes clean on Path B (no-op pull)" \
  || nok "T3 rc" "rc=$RUN_RC log=[$LOG_OUT]"
echo "$LOG_OUT" | grep "this-pull-structurally-inert=" >/dev/null \
  && ok "T3 pre-existing Path-B probe (ga-6zkhci) still runs unaffected" \
  || nok "T3 Path-B probe" "$LOG_OUT"
GOT_PRE="$(field GOT_BEAD_MERGE_PRE_SHA "$REFRESH_ECHO")"
GOT_SHA="$(field GOT_BEAD_MERGE_SHA "$REFRESH_ECHO")"
[ "$GOT_PRE" = "$EXPECT_C0" ] && ok "T3 BEAD_MERGE_PRE_SHA still correct alongside the Path-B probe" \
  || nok "T3 BEAD_MERGE_PRE_SHA" "got '$GOT_PRE' want '$EXPECT_C0' out=[$REFRESH_ECHO]"
[ "$GOT_SHA" = "$EXPECT_C1" ] && ok "T3 BEAD_MERGE_SHA still correct alongside the Path-B probe" \
  || nok "T3 BEAD_MERGE_SHA" "got '$GOT_SHA' want '$EXPECT_C1' out=[$REFRESH_ECHO]"

echo ""
echo "story-delivery bead-merge attribution passthrough tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
