#!/usr/bin/env bash
# daemon-refresh-bead-attribution.test.sh — regression test for ga-agracx.
# Runs the REAL daemon-refresh.sh directly (it is already a standalone,
# env-var-driven script — no block-extraction needed, unlike the
# story-delivery-*.test.sh files, which extract Step 5b because it is
# embedded deep inside a much larger function).
#
# THE BUG (sibling of ga-3bdttu, same class, different file/caller):
# daemon-refresh.sh's Step 1b marks VERDICT=JOB_NOT_INSTALLED for any *.plist
# inside `git diff --name-only $PRE_DEPLOY_SHA $POST_DEPLOY_SHA` that isn't
# actually installed+loaded. PRE/POST_DEPLOY_SHA are the RUNTIME checkout's
# own HEAD immediately before/after quality-gate-dispatcher.sh's `git pull
# --ff-only` for ONE bead's deploy (ga-l7n3v call site, ~line 6178) — not that
# bead's own merge commit. If the runtime fell behind (a previous deploy
# failed/skipped, or two merges landed before a deploy ran), the next pull
# advances the runtime by SEVERAL beads' commits at once, and the PRE..POST
# diff includes commits from OTHER beads. Effect: a plist committed-but-
# never-installed by an EARLIER bead sticks to the NEXT bead whose deploy
# happens to close the window — never the bead that actually introduced it.
#
# THE FIX: Step 1b now ALSO accepts optional BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA
# — the CALLING bead's own merge range (quality-gate-dispatcher.sh passes its
# already-computed MERGE_PRE_MAIN_SHA/MERGE_SHA). When both resolve in
# RUNTIME_DIR and BEAD_MERGE_PRE_SHA is a real ancestor of BEAD_MERGE_SHA
# (same guard chain ga-6zkhci established for story-delivery.sh's own
# MERGE_PRE_MAIN fallback — never trust the inputs blindly), a missing/
# unloaded plist is only blamed (SJ_PENDING_REASON, which forces the
# blocking JOB_NOT_INSTALLED verdict) when THIS bead's own narrow range
# actually touched that exact file. Otherwise the gap is recorded as
# UNATTRIBUTED_JOB_GAP (a new emit() field, never folded into REASON or
# forced into VERDICT) — the alert never disappears, only the false block
# does. Any guard failure (inputs absent/unresolvable/not-an-ancestor) leaves
# attribution UNKNOWN, which defaults to "attributable" — i.e. today's exact
# behavior — never guessing an exemption.
#
# T1 (Mayor's ACEITE 1, the repro): runtime behind, pull advances 2 merges —
#     bead A's commit introduces launchd/com.test.strayjob.plist (never
#     installed), bead B's own commit (later, unrelated file) is what
#     finally pulls the runtime past both. BEAD_MERGE_PRE_SHA/SHA = bead B's
#     own range only → does NOT contain the plist → NOT blocked, but the gap
#     is still reported (ACEITE 2: alert never disappears).
# T2 (control): same wide window, but the plist is introduced INSIDE bead B's
#     own range this time (bead B is the true cause) → blocked exactly as
#     before, UNATTRIBUTED_JOB_GAP empty.
# T3 (ACEITE 4 shape — backward compatibility): identical fixture to T1, but
#     BEAD_MERGE_PRE_SHA/SHA are simply not passed at all (every caller that
#     hasn't been updated, e.g. story-delivery.sh's own call) → attribution
#     stays unknown → falls back to today's exact blame behavior.
# T4: BEAD_MERGE_PRE_SHA/SHA passed but BEAD_MERGE_PRE_SHA is NOT an ancestor
#     of BEAD_MERGE_SHA (a stale/inconsistent pair) → guard fails closed →
#     unknown → existing blame behavior, never guessed.
# T5: BEAD_MERGE_PRE_SHA is a syntactically-plausible but unresolvable SHA
#     (never fetched into this RUNTIME_DIR) → guard fails closed → unknown →
#     existing blame behavior.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

make_plist() {  # make_plist <dir> <label>
  local dir="$1" label="$2"
  mkdir -p "$dir"
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/true</string>
  </array>
</dict>
</plist>
EOF
}

# run_case <own_range_touches_plist 0|1> <pass_attribution 0|1|garbage>
#
# Builds a real 3-commit fixture in a fresh RUNTIME_DIR:
#   C0 (base) -> C_A ("bead A") -> C_B ("bead B")
# own_range_touches_plist=0: C_A adds the never-installed plist, C_B adds an
#   unrelated file (lib/harmless.py) — bead B's own range (C_A..C_B) does NOT
#   contain the plist (T1/T3/T4/T5 shape).
# own_range_touches_plist=1: swapped — C_A adds the unrelated file, C_B adds
#   the plist — bead B's own range DOES contain it (T2 control shape).
# The plist is deliberately never copied into LAUNCH_AGENTS_DIR (AGENTS) —
# same "never installed" omission T37 in daemon-refresh.test.sh uses.
#
# pass_attribution:
#   1       -> BEAD_MERGE_PRE_SHA=C_A BEAD_MERGE_SHA=C_B (bead B's real own range)
#   0       -> both left empty (simulates a caller that doesn't pass them)
#   garbage -> BEAD_MERGE_PRE_SHA=C_B (NOT an ancestor of BEAD_MERGE_SHA=C_B — use
#              C0 as BEAD_MERGE_SHA instead, so PRE is a DESCENDANT of POST)
#   unresolvable -> BEAD_MERGE_PRE_SHA=40 zeros (never fetched), BEAD_MERGE_SHA=C_B
run_case() {
  local own_range_touches_plist="$1" pass_attribution="$2"
  local T; T="$(mktemp -d)"
  local RUNTIME="$T/runtime" AGENTS="$T/agents" BIN="$T/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$BIN"

  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/lib" "$RUNTIME/launchd"
  echo base > "$RUNTIME/base.txt"
  git -C "$RUNTIME" add -A >/dev/null 2>&1
  git -C "$RUNTIME" commit -q -m C0
  local SHA_C0; SHA_C0="$(git -C "$RUNTIME" rev-parse HEAD)"

  if [ "$own_range_touches_plist" = "0" ]; then
    make_plist "$RUNTIME/launchd" com.test.strayjob
  else
    echo harmless > "$RUNTIME/lib/harmless.py"
  fi
  git -C "$RUNTIME" add -A >/dev/null 2>&1
  git -C "$RUNTIME" commit -q -m C_A
  local SHA_CA; SHA_CA="$(git -C "$RUNTIME" rev-parse HEAD)"

  if [ "$own_range_touches_plist" = "0" ]; then
    echo harmless > "$RUNTIME/lib/harmless.py"
  else
    make_plist "$RUNTIME/launchd" com.test.strayjob
  fi
  git -C "$RUNTIME" add -A >/dev/null 2>&1
  git -C "$RUNTIME" commit -q -m C_B
  local SHA_CB; SHA_CB="$(git -C "$RUNTIME" rev-parse HEAD)"
  # deliberately do NOT copy launchd/com.test.strayjob.plist into $AGENTS —
  # that omission is the bug this test proves gets caught (and correctly
  # attributed, or not, depending on the case).

  # mock launchctl: unconditionally "not found" — nothing is ever installed
  # or loaded in this fixture, matching T37's "never installed" shape.
  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
if [ "${1:-}" = "list" ]; then
  echo "Could not find service \"${2:-}\" in domain for port" >&2
  exit 1
fi
exit 0
LCEOF
  chmod +x "$BIN/launchctl"
  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
exit 0
PSEOF
  chmod +x "$BIN/ps"

  local BEAD_PRE="" BEAD_POST=""
  case "$pass_attribution" in
    1) BEAD_PRE="$SHA_CA"; BEAD_POST="$SHA_CB" ;;
    0) BEAD_PRE=""; BEAD_POST="" ;;
    garbage) BEAD_PRE="$SHA_CB"; BEAD_POST="$SHA_CA" ;;  # PRE is a DESCENDANT of POST — not-an-ancestor
    unresolvable) BEAD_PRE="0000000000000000000000000000000000000000"; BEAD_POST="$SHA_CB" ;;
  esac

  OUT=$(RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$SHA_C0" POST_DEPLOY_SHA="$SHA_CB" \
    DEPLOY_EPOCH="$(date +%s)" SENSITIVE_DAEMONS="" EXTRA_RUNTIME_ROOTS="" \
    FORCE_RESTART_LABELS="" LAUNCH_AGENTS_DIR="$AGENTS" \
    LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
    BEAD_MERGE_PRE_SHA="$BEAD_PRE" BEAD_MERGE_SHA="$BEAD_POST" \
    DRY_RUN=0 bash "$HELPER" 2>/dev/null)
  RUN_RC=$?
  RUN_OUT="$OUT"
  rm -rf "$T"
}

# ── T1: wide window spans 2 merges, own range (bead B) does NOT contain the
#        plist → NOT blocked, gap still reported ───────────────────────────
run_case 0 1
V="$(field VERDICT "$RUN_OUT")"
UJG="$(field UNATTRIBUTED_JOB_GAP "$RUN_OUT")"
AFF="$(field AFFECTED "$RUN_OUT")"
[ "$V" != "JOB_NOT_INSTALLED" ] && ok "T1 verdict NOT blocked by an earlier bead's uninstalled job (got '$V')" \
  || nok "T1 verdict wrongly blocked" "got '$V' out=[$RUN_OUT]"
[ "$RUN_RC" -eq 0 ] && ok "T1 exit 0 (not held)" || nok "T1 exit" "rc=$RUN_RC out=[$RUN_OUT]"
echo "$UJG" | grep -q "com.test.strayjob" \
  && ok "T1 UNATTRIBUTED_JOB_GAP names the label — alert not silenced" \
  || nok "T1 unattributed gap wording" "UJG=[$UJG] out=[$RUN_OUT]"
echo "$AFF" | grep -q "com.test.strayjob" \
  && ok "T1 AFFECTED still names the label (visibility preserved)" \
  || nok "T1 affected" "AFF=[$AFF] out=[$RUN_OUT]"

# ── T2: control — plist introduced INSIDE bead B's own range → blocked
#        exactly as before ──────────────────────────────────────────────────
run_case 1 1
V="$(field VERDICT "$RUN_OUT")"
UJG="$(field UNATTRIBUTED_JOB_GAP "$RUN_OUT")"
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T2 verdict JOB_NOT_INSTALLED — this bead's own merge IS the cause" \
  || nok "T2 verdict" "got '$V' out=[$RUN_OUT]"
[ "$RUN_RC" -ne 0 ] && ok "T2 non-zero exit (held)" || nok "T2 exit" "rc=$RUN_RC"
[ -z "${UJG// /}" ] && ok "T2 UNATTRIBUTED_JOB_GAP empty — correctly attributed, not double-reported" \
  || nok "T2 unattributed gap should be empty" "UJG=[$UJG]"

# ── T3: attribution inputs simply absent (uncalled caller, e.g. story-
#        delivery.sh today) → unknown → existing blame behavior ────────────
run_case 0 0
V="$(field VERDICT "$RUN_OUT")"
UJG="$(field UNATTRIBUTED_JOB_GAP "$RUN_OUT")"
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T3 no attribution inputs → falls back to blame (zero regression for callers not yet updated)" \
  || nok "T3 verdict" "got '$V' out=[$RUN_OUT]"
[ -z "${UJG// /}" ] && ok "T3 UNATTRIBUTED_JOB_GAP empty — unknown never guesses an exemption" \
  || nok "T3 unattributed gap should be empty" "UJG=[$UJG]"

# ── T4: BEAD_MERGE_PRE_SHA not an ancestor of BEAD_MERGE_SHA → guard fails
#        closed → unknown → existing blame behavior, never guessed ─────────
run_case 0 garbage
V="$(field VERDICT "$RUN_OUT")"
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T4 non-ancestor pair → guard fails closed → blame (never guessed)" \
  || nok "T4 verdict" "got '$V' out=[$RUN_OUT]"

# ── T5: BEAD_MERGE_PRE_SHA unresolvable in RUNTIME_DIR → guard fails closed
#        → unknown → existing blame behavior ────────────────────────────────
run_case 0 unresolvable
V="$(field VERDICT "$RUN_OUT")"
[ "$V" = "JOB_NOT_INSTALLED" ] && ok "T5 unresolvable pre-sha → guard fails closed → blame (never guessed)" \
  || nok "T5 verdict" "got '$V' out=[$RUN_OUT]"

echo ""
echo "daemon-refresh bead attribution tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
