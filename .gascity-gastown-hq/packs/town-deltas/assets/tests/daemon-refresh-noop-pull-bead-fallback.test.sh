#!/usr/bin/env bash
# daemon-refresh-noop-pull-bead-fallback.test.sh — regression test for ga-1ivcn4.
# Runs the REAL daemon-refresh.sh directly (same harness style as
# daemon-refresh-bead-attribution.test.sh — the helper is a standalone,
# env-var-driven script, no block-extraction needed).
#
# THE BUG (wa-ycyf8, P0, measured 2026-09-17): daemon-refresh.sh's own
# precondition treated PRE_DEPLOY_SHA==POST_DEPLOY_SHA ("this invocation's
# own git-pull found nothing new") as proof the DEPLOY changed nothing, and
# emitted VERDICT=SKIPPED/not_applicable unconditionally. But PRE==POST only
# proves THIS invocation's pull was a no-op — usually because some OTHER path
# (a rig's 5-min cron, town-root-reconciler, a manual pull) already advanced
# RUNTIME_DIR to the merge before this call's own deploy step ran. The merge
# itself can still be a real, daemon-relevant change that no live process has
# picked up — SKIPPED let the calling bead close as delivered with zero
# verification while the affected (notify_only_locked) daemon kept serving
# the old code.
#
# THE FIX: when PRE_DEPLOY_SHA==POST_DEPLOY_SHA, daemon-refresh.sh now checks
# for BEAD_MERGE_PRE_SHA/BEAD_MERGE_SHA (quality-gate-dispatcher.sh already
# threads these through at its daemon-refresh.sh call site, ~line 6246 — the
# same ga-agracx attribution inputs Step 1b already consumes below). When
# both resolve in RUNTIME_DIR and BEAD_MERGE_PRE_SHA is a confirmed ancestor
# of BEAD_MERGE_SHA (same guard chain ga-agracx/ga-6zkhci established — never
# trust the inputs blindly), PRE/POST_DEPLOY_SHA fall back to that range
# instead of declaring SKIPPED, so the rest of the script (CHANGED, Step 1b,
# AFFECTED, restart/guard, verdict) evaluates the bead's OWN merge exactly as
# it would for any genuine delta. Any guard failure — including a caller that
# simply doesn't pass the inputs at all (story-delivery.sh's own primary
# call, which has its own separate MERGE_OWN_* probe — see ga-6zkhci) — falls
# straight through to today's exact SKIPPED/not_applicable behavior: zero
# regression.
#
# T1 (bead ACEITE 1, the repro): no-op pull, bead's own range touches a
#     SENSITIVE hot-path daemon's file, that daemon is running code from
#     BEFORE the merge → verdict must NOT be SKIPPED — NEEDS_GUARDED_RESTART,
#     non-zero exit (delivery halts instead of closing blind).
# T2 (bead ACEITE 2): no-op pull, bead's own range touches only a docs file
#     (no daemon reaches it) → stays non-blocking (OK/SKIPPED), exit 0 — the
#     fallback must not manufacture holds for docs/tests-only merges.
# T3 (backward compatibility): no-op pull, BEAD_MERGE_PRE_SHA/SHA simply not
#     passed (every caller not yet updated, e.g. story-delivery.sh's primary
#     call today) → falls back to today's exact SKIPPED/not_applicable —
#     zero regression.
# T4 (control — scope of the fallback): a REAL delta (PRE_DEPLOY_SHA !=
#     POST_DEPLOY_SHA) whose own range is docs-only, while BEAD_MERGE_PRE_SHA/
#     SHA point at a DIFFERENT, earlier range that DOES touch a sensitive
#     daemon → the fallback must never be consulted outside the equal-SHA
#     branch, so the verdict comes from the real PRE..POST delta only (stays
#     non-blocking) — proves the fix can't misattribute an earlier bead's
#     change onto this delivery.
# T5 (guard fails closed): no-op pull, BEAD_MERGE_PRE_SHA is NOT an ancestor
#     of BEAD_MERGE_SHA (stale/inconsistent pair) → guard refuses the
#     fallback → falls through to SKIPPED, never guesses.

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# -style pipes (including the `field()` helper's `| head -1 |`), and under
# pipefail an early-exiting reader can SIGPIPE the writer mid-write, turning
# a PASSING assertion into a false FAIL under load (measured: 1.9% per
# assertion at load 45; see ga-uel7sb). daemon-refresh.sh under test runs as
# its own subprocess (bash "$HELPER"), with its own `set` options —
# unaffected by this file's.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

make_plist() {  # make_plist <dir> <label> <prog-arg> [<prog-arg>...]
  local dir="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args="$args      <string>$a</string>
"; done
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
</dict>
</plist>
EOF
}

# build a fresh mock environment for one case; sets globals:
#   RUNTIME, AGENTS, MOCK, BIN
new_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  RUNTIME="$CASE_DIR/runtime"; AGENTS="$CASE_DIR/agents"; MOCK="$CASE_DIR/mock"; BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"

  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons" "$RUNTIME/docs" "$RUNTIME/launchd"

  # mock launchctl: `list <label>` reports known/unknown per seeded state;
  # `kickstart` just logs the call (T1/T4 never expect a bounce — sensitive
  # daemons are never auto-kickstarted, matching daemon-refresh.test.sh's T4).
  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    label="${last##*/}"
    echo "$label" >> "$S/kicks.log"
    ;;
esac
exit 0
LCEOF
  chmod +x "$BIN/launchctl"

  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] && [ -f "$S/start.$pid" ] && cat "$S/start.$pid"
exit 0
PSEOF
  chmod +x "$BIN/ps"
}

seed_running() { echo "$2" > "$MOCK/pid.$1"; echo "$3" > "$MOCK/start.$2"; }

# invoke_helper <pre_deploy_sha> <post_deploy_sha> <deploy_epoch> <bead_pre_sha> <bead_sha>
# Globals consumed: RUNTIME AGENTS MOCK BIN SENSITIVE_DAEMONS
invoke_helper() {
  local pre="$1" post="$2" depoch="$3" bpre="$4" bpost="$5"
  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$pre" POST_DEPLOY_SHA="$post" \
  DEPLOY_EPOCH="$depoch" \
  SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  BEAD_MERGE_PRE_SHA="$bpre" BEAD_MERGE_SHA="$bpost" \
  DRY_RUN=0 bash "$HELPER" 2>/dev/null
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-noop-fallback.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ════════════════════════════════════════════════════════════════════════════
# T1: no-op pull, bead's own merge touches a SENSITIVE daemon, daemon is
#     running pre-merge code → must NOT be SKIPPED → NEEDS_GUARDED_RESTART
# ════════════════════════════════════════════════════════════════════════════
new_case t1
SENSITIVE_DAEMONS="central-sender"
NOW=$(date +%s)
MERGE_EPOCH=$((NOW - 300))            # bead's merge landed 5 min ago
STALE_LSTART="$(lstart_of $((MERGE_EPOCH - 3600)))"   # daemon up 1h before that

git -C "$RUNTIME" commit -q -m base --allow-empty
C0=$(git -C "$RUNTIME" rev-parse HEAD)

cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/launchd/central-sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
git -C "$RUNTIME" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="@$MERGE_EPOCH" GIT_COMMITTER_DATE="@$MERGE_EPOCH" \
  git -C "$RUNTIME" commit -q -m "bead merge: touch central_sender"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
# runtime is ALREADY at C1 — some other path (cron) pulled it before this
# invocation's own deploy step ran; PRE==POST==C1 (a true no-op pull).

make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central-sender-wrapper.sh"
seed_running com.test.central-sender 4001 "$STALE_LSTART"

OUT=$(invoke_helper "$C1" "$C1" "$NOW" "$C0" "$C1"); RC=$?
V=$(field VERDICT "$OUT")
[ "$V" != "SKIPPED" ] && ok "T1 verdict is NOT SKIPPED despite no-op pull (got '$V')" \
  || nok "T1 wrongly SKIPPED — the wa-ycyf8 bug" "out=[$OUT]"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T1 verdict NEEDS_GUARDED_RESTART (stale sensitive daemon caught)" \
  || nok "T1 verdict" "got '$V' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "T1 non-zero exit — delivery halts, bead does not close" \
  || nok "T1 exit" "rc=$RC (must be non-zero to hold the bead open)"
echo "$(field GUARDED "$OUT")" | grep "com.test.central-sender" >/dev/null \
  && ok "T1 GUARDED names the stale sensitive daemon" \
  || nok "T1 guarded" "$(field GUARDED "$OUT")"

# ════════════════════════════════════════════════════════════════════════════
# T2: no-op pull, bead's own merge touches ONLY a docs file (no daemon reaches
#     it) → stays non-blocking (bead ACEITE 2 — SKIPPED continues to apply)
# ════════════════════════════════════════════════════════════════════════════
new_case t2
SENSITIVE_DAEMONS="central-sender"
NOW=$(date +%s)
MERGE_EPOCH=$((NOW - 300))

git -C "$RUNTIME" commit -q -m base --allow-empty
C0=$(git -C "$RUNTIME" rev-parse HEAD)
echo "docs change" >> "$RUNTIME/docs/notes.md"
git -C "$RUNTIME" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="@$MERGE_EPOCH" GIT_COMMITTER_DATE="@$MERGE_EPOCH" \
  git -C "$RUNTIME" commit -q -m "bead merge: docs only"
C1=$(git -C "$RUNTIME" rev-parse HEAD)

OUT=$(invoke_helper "$C1" "$C1" "$NOW" "$C0" "$C1"); RC=$?
V=$(field VERDICT "$OUT")
[ "$RC" -eq 0 ] && ok "T2 exit 0 — docs-only merge does not hold the bead" \
  || nok "T2 exit" "rc=$RC verdict=$V out=[$OUT]"
{ [ "$V" = "OK" ] || [ "$V" = "SKIPPED" ]; } \
  && ok "T2 verdict is OK/SKIPPED, not a manufactured hold (got '$V')" \
  || nok "T2 verdict" "got '$V' out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T3: no-op pull, BEAD_MERGE_PRE_SHA/SHA simply not passed (caller not yet
#     updated, e.g. story-delivery.sh's own primary call) → zero regression,
#     today's exact SKIPPED/not_applicable
# ════════════════════════════════════════════════════════════════════════════
new_case t3
SENSITIVE_DAEMONS="central-sender"
NOW=$(date +%s)
git -C "$RUNTIME" commit -q -m base --allow-empty
C1=$(git -C "$RUNTIME" rev-parse HEAD)

OUT=$(invoke_helper "$C1" "$C1" "$NOW" "" ""); RC=$?
V=$(field VERDICT "$OUT")
P=$(field PROOF "$OUT")
[ "$V" = "SKIPPED" ] && [ "$P" = "not_applicable" ] \
  && ok "T3 no attribution inputs -> unchanged SKIPPED/not_applicable (zero regression)" \
  || nok "T3 verdict/proof" "V='$V' P='$P' out=[$OUT]"
[ "$RC" -eq 0 ] && ok "T3 exit 0" || nok "T3 exit" "rc=$RC"

# ════════════════════════════════════════════════════════════════════════════
# T4: control — a REAL delta whose own range is docs-only, while
#     BEAD_MERGE_PRE_SHA/SHA point at a DIFFERENT, earlier range that DOES
#     touch a sensitive daemon → fallback must never be consulted outside the
#     equal-SHA branch — proves the fix cannot misattribute an earlier bead's
#     change onto this delivery
# ════════════════════════════════════════════════════════════════════════════
new_case t4
SENSITIVE_DAEMONS="central-sender"
NOW=$(date +%s)
EARLIER_EPOCH=$((NOW - 3600))
STALE_LSTART="$(lstart_of $((EARLIER_EPOCH - 3600)))"

git -C "$RUNTIME" commit -q -m base --allow-empty
C0=$(git -C "$RUNTIME" rev-parse HEAD)
# C1: an EARLIER, already-merged bead's change — touches the sensitive daemon.
cat > "$RUNTIME/daemons/central_sender.py" <<<'print("send")'
cat > "$RUNTIME/launchd/central-sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
git -C "$RUNTIME" add -A >/dev/null 2>&1
GIT_AUTHOR_DATE="@$EARLIER_EPOCH" GIT_COMMITTER_DATE="@$EARLIER_EPOCH" \
  git -C "$RUNTIME" commit -q -m "earlier bead: touch central_sender"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
# C2: THIS call's own real delta — docs only.
echo "docs change" >> "$RUNTIME/docs/notes.md"
git -C "$RUNTIME" add -A >/dev/null 2>&1
git -C "$RUNTIME" commit -q -m "this delivery: docs only"
C2=$(git -C "$RUNTIME" rev-parse HEAD)

make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central-sender-wrapper.sh"
seed_running com.test.central-sender 4001 "$STALE_LSTART"

# PRE=C1 POST=C2 is a REAL, non-empty delta (docs-only). BEAD_MERGE_PRE_SHA/
# SHA=C0/C1 are a well-formed ancestor pair but describe a DIFFERENT range —
# if the fix wrongly consulted them here, central_sender.py would be
# misattributed to this delivery.
OUT=$(invoke_helper "$C1" "$C2" "$NOW" "$C0" "$C1"); RC=$?
V=$(field VERDICT "$OUT")
[ "$RC" -eq 0 ] && ok "T4 real docs-only delta stays non-blocking — BEAD_MERGE_* correctly ignored" \
  || nok "T4 exit" "rc=$RC verdict=$V out=[$OUT] (fallback leaked into a PRE!=POST call)"
{ [ "$V" = "OK" ] || [ "$V" = "SKIPPED" ]; } \
  && ok "T4 verdict OK/SKIPPED, not misattributed NEEDS_GUARDED_RESTART (got '$V')" \
  || nok "T4 verdict" "got '$V' out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T5: no-op pull, BEAD_MERGE_PRE_SHA NOT an ancestor of BEAD_MERGE_SHA (stale/
#     inconsistent pair) → guard fails closed → falls through to SKIPPED,
#     never guesses
# ════════════════════════════════════════════════════════════════════════════
new_case t5
SENSITIVE_DAEMONS="central-sender"
NOW=$(date +%s)
git -C "$RUNTIME" commit -q -m base --allow-empty
C0=$(git -C "$RUNTIME" rev-parse HEAD)
echo x >> "$RUNTIME/docs/notes.md"
git -C "$RUNTIME" add -A >/dev/null 2>&1
git -C "$RUNTIME" commit -q -m c1
C1=$(git -C "$RUNTIME" rev-parse HEAD)

# BEAD_MERGE_PRE_SHA=C1, BEAD_MERGE_SHA=C0 — PRE is a DESCENDANT of POST,
# i.e. NOT an ancestor — a stale/inconsistent pair.
OUT=$(invoke_helper "$C1" "$C1" "$NOW" "$C1" "$C0"); RC=$?
V=$(field VERDICT "$OUT")
P=$(field PROOF "$OUT")
[ "$V" = "SKIPPED" ] && [ "$P" = "not_applicable" ] \
  && ok "T5 non-ancestor pair -> guard fails closed -> SKIPPED (never guessed)" \
  || nok "T5 verdict/proof" "V='$V' P='$P' out=[$OUT]"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh-noop-pull-bead-fallback.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
