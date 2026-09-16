#!/usr/bin/env bash
# witness-patrol-wisp-store.selftest.sh — drift-guard for the ga-3v2n4 fix.
#
# Bug ga-3v2n4: the witness's native Startup Protocol Step 1 and its
# "CRITICAL: No Idle State" fallback block never see their own already-
# assigned patrol wisp, for three combined reasons:
#   (1) `bd list --status=in_progress` (no --include-infra) can't see
#       ephemeral wisp/molecule beads at all.
#   (2) the fallback's `--type=wisp` is an invalid bd enum (errors out);
#       the correct type is `molecule`.
#   (3) `gc bd`'s database auto-discovery is cwd-based, and a witness whose
#       agent-home sits under the HQ city path (lexbh, whatsapp_automation,
#       deacon) silently resolves to the HQ database instead of its own
#       rig's — so even a fully-fixed (1)+(2) still pours into, and reads
#       from, the wrong store.
#
# This is a text-fix (a prompt-template ADDITIVE correction plus a vendored
# formula override), not executable application code, so there is no
# runnable "before/after" binary to invoke. The test instead proves the
# structural properties the fix depends on are present in the shipped
# files, scoped to the actual bash the witness would run (not to prose that
# legitimately quotes the old broken pattern while explaining the bug —
# a naive whole-file grep for "--type=wisp" or "bd mol wisp" false-positives
# on that prose; see the ga-3v2n4 comment thread for how this was caught).
#
# Exit 0 iff all assertions hold.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOWN_DELTAS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FORMULA="$TOWN_DELTAS_ROOT/formulas/mol-witness-patrol.toml"
TEMPLATE="$TOWN_DELTAS_ROOT/template-fragments/town-deltas.template.md"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$FORMULA" ]; then
  echo "FATAL: formula override not found at $FORMULA" >&2
  exit 2
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "FATAL: template fragment not found at $TEMPLATE" >&2
  exit 2
fi

echo "witness-patrol-wisp-store.selftest — ga-3v2n4 wrong-store / bd-list drift guards"

# ── Scenario 1: formula's [vars.rig_root] is declared ────────────────────────
echo ""
echo "Scenario 1: formula declares a rig_root variable"
if grep -q '^\[vars\.rig_root\]$' "$FORMULA"; then
  ok "[vars.rig_root] declared in mol-witness-patrol.toml"
else
  bad "[vars.rig_root] MISSING from mol-witness-patrol.toml"
fi

# ── Scenario 2: the next-iteration step actually pins -C on every gc bd call ──
echo ""
echo "Scenario 2: next-iteration step pins -C '{{rig_root}}' on every gc bd call"

# Isolate just the next-iteration step body (from its id line to EOF — it's
# the last [[steps]] block in the file).
STEP_BODY="$(sed -n '/^id = "next-iteration"$/,$p' "$FORMULA")"

if [ -z "$STEP_BODY" ]; then
  bad "could not locate the next-iteration step body at all"
else
  PIN_COUNT=$(printf '%s\n' "$STEP_BODY" | grep -c -- "-C '{{rig_root}}'")
  if [ "$PIN_COUNT" -ge 4 ]; then
    ok "next-iteration step pins -C '{{rig_root}}' $PIN_COUNT times (pour, verify, assign, burn)"
  else
    bad "next-iteration step only pins -C '{{rig_root}}' $PIN_COUNT times, expected >=4"
  fi

  UNPINNED_WISP=$(printf '%s\n' "$STEP_BODY" | grep -c 'bd mol wisp')
  UNPINNED_BURN=$(printf '%s\n' "$STEP_BODY" | grep -c 'bd mol burn')
  UNPINNED_UPDATE=$(printf '%s\n' "$STEP_BODY" | grep -c 'bd update "\$NEXT"')
  if [ "$UNPINNED_WISP" -eq 0 ] && [ "$UNPINNED_BURN" -eq 0 ] && [ "$UNPINNED_UPDATE" -eq 0 ]; then
    ok "no unpinned (bare, no -C) pour/burn/assign calls remain in next-iteration"
  else
    bad "found unpinned calls in next-iteration: wisp=$UNPINNED_WISP burn=$UNPINNED_BURN update=$UNPINNED_UPDATE"
  fi

  if printf '%s\n' "$STEP_BODY" | grep -q 'show "\$NEXT" --json'; then
    ok "next-iteration verifies the pour landed in the right store before assign/burn"
  else
    bad "next-iteration MISSING the post-pour same-store verification"
  fi

  if printf '%s\n' "$STEP_BODY" | grep -q 'rig_root var not supplied'; then
    ok "next-iteration fails safe (mails mayor, exits) when rig_root is empty"
  else
    bad "next-iteration MISSING the empty-rig_root fail-safe guard"
  fi
fi

# ── Scenario 3: template fragment carries the ga-3v2n4 witness correction ────
echo ""
echo "Scenario 3: town-deltas.template.md carries the witness-scoped correction"

NEW_SECTION="$(sed -n '/WITNESS: o Startup Protocol/,$p' "$TEMPLATE")"

if [ -z "$NEW_SECTION" ]; then
  bad "ga-3v2n4 witness correction section not found in town-deltas.template.md"
else
  if printf '%s\n' "$NEW_SECTION" | grep -q 'ga-3v2n4'; then
    ok "correction section cites ga-3v2n4"
  else
    bad "correction section present but doesn't cite ga-3v2n4"
  fi

  if printf '%s\n' "$NEW_SECTION" | grep -q 'gc hook'; then
    ok "Step 1 replacement uses gc hook (agent-identity resolution, not cwd)"
  else
    bad "Step 1 replacement MISSING gc hook"
  fi
fi

# ── Scenario 4: the fallback-block CODE (not the prose describing it) is fixed ─
echo ""
echo "Scenario 4: fallback-block replacement code is actually correct"

# Anchor on the exact first and last lines of the fallback code block, so
# this only inspects the bash the witness will run — not the prose above it
# that legitimately quotes the old broken --type=wisp pattern while
# explaining the bug (a whole-section grep false-positives on that prose).
FALLBACK_CODE="$(sed -n "/^BD_C=(); \[ -n '{{ \.RigRoot }}' \]/,/^gc hook\$/p" "$TEMPLATE")"

if [ -z "$FALLBACK_CODE" ]; then
  bad "could not isolate the fallback-block code (anchors not found — did the block change shape?)"
else
  TYPE_MOLECULE_COUNT=$(printf '%s\n' "$FALLBACK_CODE" | grep -c -- '--type=molecule --include-infra')
  if [ "$TYPE_MOLECULE_COUNT" -ge 2 ]; then
    ok "fallback code uses --type=molecule --include-infra $TYPE_MOLECULE_COUNT times (CURRENT_WISP + ASSIGNED_WISP)"
  else
    bad "fallback code uses --type=molecule --include-infra only $TYPE_MOLECULE_COUNT times, expected >=2"
  fi

  if printf '%s\n' "$FALLBACK_CODE" | grep -q -- '--type=wisp'; then
    bad "fallback code REGRESSION: still contains the invalid --type=wisp enum"
  else
    ok "fallback code contains no bare --type=wisp (invalid enum) usage"
  fi

  # Every gc bd invocation in this block must route through the optional
  # -C array (BD_C), which degrades gracefully to no -C only when RigRoot
  # is genuinely empty (Scenario 5 checks that guard exists). A call is
  # "unpinned" iff "gc bd " is followed by something other than the array
  # expansion's opening quote — matching the bare substring "gc bd " alone
  # (as an earlier draft of this check did) false-positives on every PINNED
  # call too, since `gc bd "${BD_C[@]}" list` also contains "gc bd ".
  PINNED_CALLS=$(printf '%s\n' "$FALLBACK_CODE" | grep -c 'gc bd "\${BD_C\[@\]}"')
  UNPINNED_CALLS=$(printf '%s\n' "$FALLBACK_CODE" | grep -c 'gc bd [^"]')
  if [ "$PINNED_CALLS" -ge 5 ] && [ "$UNPINNED_CALLS" -eq 0 ]; then
    ok "all $PINNED_CALLS gc bd calls in the fallback block route through \${BD_C[@]}, none unpinned"
  else
    bad "fallback block gc bd calls not fully routed through \${BD_C[@]} (pinned=$PINNED_CALLS, unpinned=$UNPINNED_CALLS)"
  fi
fi

# ── Scenario 5: the -C pin degrades gracefully instead of hard-failing ───────
echo ""
echo "Scenario 5: BD_C is built defensively (empty RigRoot -> no -C, not a crash)"
if printf '%s\n' "$NEW_SECTION" | grep -q "BD_C=(); \[ -n '{{ \.RigRoot }}' \] && BD_C=(-C '{{ \.RigRoot }}')"; then
  ok "BD_C falls back to no -C when {{ .RigRoot }} is empty, instead of passing -C ''"
else
  bad "BD_C construction MISSING or changed shape — verify the empty-RigRoot fallback still holds"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
