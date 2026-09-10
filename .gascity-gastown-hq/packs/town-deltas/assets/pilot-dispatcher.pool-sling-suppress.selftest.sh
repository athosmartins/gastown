#!/usr/bin/env bash
# pilot-dispatcher.pool-sling-suppress.selftest.sh — unit tests for
# _pilot_pool_target_has_live_session and its dispatch_one() call site
# (ga-hpc1x).
#
# Bug ga-hpc1x: gt-4st3n's _skip_reuse (~L8524) forces _DISPATCH_REUSE=0 for
# EPHEMERAL POOL targets (gastown.dog, wa-worker*, ps-worker*) — correct for
# the REUSE-vs-SPAWN *delivery-mechanism* decision (there can be MULTIPLE
# live instances of a pool template, so picking one to "reuse" is
# meaningless) — but it also means the ga-i58em REUSE-suppression fix
# (_pilot_suppress_reused_sling, only called when _DISPATCH_REUSE=1) never
# runs for pool targets. Their own delivery a few lines later — plain
# `gc session nudge $_SLING_TARGET` — can ALSO land directly on an
# already-live instance of the pool, exactly like `gc session submit` does
# for a REUSE dispatch: that instance acts on the nudge's embedded "Claim
# your work" block immediately (it only ever names STORY_ID, never the
# sling's own id) and never separately runs its own Step-1c self-serve
# probe, leaving the sling open+routed+unassigned for its entire work
# duration — indistinguishable from real unclaimed pool demand to a SECOND,
# genuinely-idle instance's own Step-1c. Live incident: gastown.dog-1
# (already active) claimed wrapped bug ga-skuoh via the embedded block but
# never sling ga-ts1i8; ~4 minutes later gastown.dog-2's normal Step-1c
# found the still-open sling and claimed it as fresh work, caught only by a
# manual liveness cross-check before any fix work began.
#
# The fix: _pilot_pool_target_has_live_session(target) checks (via a real
# `gc session list --json`, timeout-bounded) whether a live instance of an
# EPHEMERAL POOL template currently exists; when one does, dispatch_one()
# calls the SAME _pilot_suppress_reused_sling the REUSE branch already uses,
# right after it — a second, independent guard, not a replacement for the
# REUSE one. Deliberately gated on liveness, not unconditional: an idle pool
# with NO live instance must keep the sling bd-ready-visible for that
# instance's own fresh Step-1c, its real guaranteed discovery path,
# independent of this nudge.
#
# This harness extracts _pilot_pool_target_has_live_session verbatim from
# the live dispatcher (same awk-extraction pattern
# pilot-dispatcher.sling-reuse-suppress.selftest.sh already uses for its
# sibling helpers) and exercises it against a REAL fake `gc` executable on
# PATH — a plain shell-function fake will NOT do here, because the real
# code wraps the call in `timeout 10 gc ...` and `timeout` execs its
# argument directly, bypassing shell functions entirely (it would silently
# fall through to whatever real `gc` binary happens to be on PATH instead).
# This is the same PATH-sandbox convention
# pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh already established
# for exactly this class of timeout-wrapped external call.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Extract the helper verbatim from the live file ─────────────────────────
LIVE_FN="$(awk '/^_pilot_pool_target_has_live_session\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
if [ -z "$LIVE_FN" ]; then
  echo "FATAL: _pilot_pool_target_has_live_session() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi
eval "$LIVE_FN"

# ── Sandbox helpers ─────────────────────────────────────────────────────────
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-pool-sling-suppress-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# fake_gc <sessions-json-body> — writes a real executable `gc` to its own
# sandbox bin dir that answers ANY `... session list --json` with the given
# body and records that it was actually invoked (a marker file), so a
# scenario expecting the SHORT-CIRCUIT case-gate (no gc call at all) can
# prove it. Prints the sandbox bin dir on stdout.
fake_gc() {
  local _body="$1" _dir _marker
  _dir="$(mktemp -d "$WORK/bin.XXXXXX")"
  _marker="$_dir/.invoked"
  cat > "$_dir/gc" <<EOF
#!/usr/bin/env bash
touch "$_marker"
cat <<'JSON'
$_body
JSON
EOF
  chmod +x "$_dir/gc"
  printf '%s' "$_dir"
}

# fake_gc_failing — a `gc` that exits non-zero with no usable JSON.
fake_gc_failing() {
  local _dir
  _dir="$(mktemp -d "$WORK/bin.XXXXXX")"
  cat > "$_dir/gc" <<'EOF'
#!/usr/bin/env bash
echo "boom: not reachable" >&2
exit 1
EOF
  chmod +x "$_dir/gc"
  printf '%s' "$_dir"
}

was_invoked() { [ -e "$1/.invoked" ]; }

echo "pilot-dispatcher.pool-sling-suppress.selftest — ephemeral-pool sling suppression (ga-hpc1x)"

# ── Scenario A: gastown.dog has one ACTIVE instance → live (true) ──────────
echo "Scenario A: gastown.dog has an ACTIVE live instance — reports live"
BIN=$(fake_gc '{"sessions":[{"template":"gastown.dog","state":"active","alias":"gastown.dog-2"}]}')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"' ; then
  ok "ACTIVE gastown.dog instance -> live"
else
  bad "ACTIVE gastown.dog instance -> reported dead (should be live)"
fi

# ── Scenario B: CREATING counts as live too ─────────────────────────────────
echo "Scenario B: gastown.dog has a CREATING (not yet active) instance — still reports live"
BIN=$(fake_gc '{"sessions":[{"template":"gastown.dog","state":"creating","alias":"gastown.dog-9"}]}')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"'; then
  ok "CREATING gastown.dog instance -> live"
else
  bad "CREATING gastown.dog instance -> reported dead (should be live)"
fi

# ── Scenario C: sessions exist, none match template/state → dead ───────────
echo "Scenario C: sessions exist but none match (wrong template, or closed/asleep) — reports dead"
BIN=$(fake_gc '{"sessions":[
  {"template":"wa-worker","state":"active","alias":"wa-worker-1"},
  {"template":"gastown.dog","state":"asleep","alias":"gastown.dog-3"}
]}')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"'; then
  bad "no matching active/creating gastown.dog session -> reported live (should be dead)"
else
  ok "no matching active/creating session -> dead (asleep instance correctly excluded)"
fi

# ── Scenario D: empty sessions list → dead ──────────────────────────────────
echo "Scenario D: empty session list — reports dead"
BIN=$(fake_gc '{"sessions":[]}')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"'; then
  bad "empty session list -> reported live (should be dead)"
else
  ok "empty session list -> dead"
fi

# ── Scenario E: non-pool target short-circuits BEFORE any gc call ──────────
echo "Scenario E: named-crew target (not a pool template) — never calls gc at all"
BIN=$(fake_gc '{"sessions":[{"template":"mila-wa","state":"active"}]}')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "mila-wa"'; then
  bad "named-crew target 'mila-wa' -> reported live (should always be dead — not a pool template)"
else
  ok "named-crew target 'mila-wa' -> dead"
fi
if was_invoked "$BIN"; then
  bad "REGRESSION: gc was invoked for a non-pool target — the case-gate should short-circuit before any subprocess call"
else
  ok "case-gate short-circuits before any gc call for a non-pool target (zero probe cost for the common named-crew path)"
fi

# ── Scenario F: gc fails outright — fail-open to dead, never crashes ───────
echo "Scenario F: gc session list fails (non-zero exit, no JSON) — fails open to dead"
BIN=$(fake_gc_failing)
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "$LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"'; then
  bad "failing gc -> reported live (fail-open must mean 'do not suppress', i.e. dead)"
else
  ok "failing gc -> fails open to dead (never suppresses on a probe error)"
fi

# ── Scenario G: garbage/unparseable JSON — fail-open to dead, no crash ─────
echo "Scenario G: gc returns non-JSON garbage — fails open to dead, does not crash under set -u"
BIN=$(fake_gc 'not json at all')
if PATH="$BIN:$PATH" GC_CITY="hq" bash -c "set -u; $LIVE_FN"'
_pilot_pool_target_has_live_session "gastown.dog"'; then
  bad "garbage jq input -> reported live (should fail open to dead)"
else
  ok "garbage jq input -> fails open to dead without crashing"
fi

# ── Scenario H: drift-guards — helper + call site wiring in dispatch_one() ─
echo "Scenario H: drift-guard — helper defined, timeout-bounded, and wired independently of the REUSE branch"
has() { local pat="$1" desc="$2"; if grep -Eq "$pat" "$DISPATCHER"; then ok "$desc"; else bad "$desc — pattern not found: $pat"; fi; }
has '_pilot_pool_target_has_live_session\(\) \{'                          "helper _pilot_pool_target_has_live_session is defined"
has 'timeout 10 gc --city "\$GC_CITY" session list --json'                "gc session list call stays timeout-bounded (never blocks a sweep on a wedged gc)"
has '_pilot_pool_target_has_live_session "\$_SLING_TARGET"'               "dispatch_one() call site invokes the helper with \$_SLING_TARGET"

# The pool-template case list here must stay in sync with gt-4st3n's
# _skip_reuse gate — same set of templates, same reason (multi-instance
# pools where REUSE-style single-session semantics don't apply). A drift
# between the two (a new pool type added to one but not the other) would
# either suppress a named crew's sling for no reason, or leave a new pool
# type exposed to this exact bug again.
# NOTE: the `|` here must be ESCAPED (\|) — this is grep -E, where a bare
# `|` is regex alternation (would match ANY line mentioning e.g. just
# "wa-worker" alone, drastically over-counting). Escaped, it matches the
# literal pipe-joined case-pattern text as it appears verbatim in the source.
_POOL_CASE_LIST='gastown\.dog\|gastown\.dog-\*\|wa-worker\|wa-worker-\*\|ps-worker\|ps-worker-\*'
_pool_case_occurrences=$(grep -cE "$_POOL_CASE_LIST" "$DISPATCHER")
if [ "${_pool_case_occurrences:-0}" -ge 2 ]; then
  ok "pool-template case list appears in both _skip_reuse (gt-4st3n) and the new helper ($_pool_case_occurrences occurrences) — kept in sync"
else
  bad "pool-template case list found in fewer than 2 places ($_pool_case_occurrences) — helper's template set may have drifted from _skip_reuse's"
fi

# Call site must be a SEPARATE guard from the _DISPATCH_REUSE=1 branch, not
# nested inside it — an idle pool (no live instance) must still fall
# through and leave the sling untouched, independent of _DISPATCH_REUSE's
# value (which is always 0 for pool targets to begin with).
if grep -A2 '_pilot_pool_target_has_live_session "\$_SLING_TARGET"; then' "$DISPATCHER" | grep -q '_pilot_suppress_reused_sling "\$GC_CITY" "\$SLING_BEAD_ID"'; then
  ok "call site guards its OWN _pilot_suppress_reused_sling call (not reusing/nesting inside the REUSE branch's fi)"
else
  bad "call site does not visibly guard its own suppression call — wiring may have drifted"
fi
# The original REUSE-only block must remain textually intact (sibling
# selftest re-verifies this independently; this is a belt-and-suspenders
# check that THIS edit did not disturb it).
if grep -B1 '_pilot_suppress_reused_sling "\$GC_CITY" "\$SLING_BEAD_ID"' "$DISPATCHER" | grep -q 'if \[ "\$_DISPATCH_REUSE" = "1" \]; then'; then
  ok "original _DISPATCH_REUSE=1 REUSE branch is still intact and still calls _pilot_suppress_reused_sling"
else
  bad "REGRESSION: the original REUSE branch's call site no longer matches the expected shape"
fi
# Ordering: after the pilot.sling_for stamp (bead must exist+be tagged first).
if grep -A25 'set-metadata "pilot.sling_for=\$STORY_ID"' "$DISPATCHER" | grep -q '_pilot_pool_target_has_live_session'; then
  ok "call site comes after the pilot.sling_for stamp (bead confirmed to exist first)"
else
  bad "call site does not appear within a reasonable window after the pilot.sling_for stamp — ordering may have drifted"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.pool-sling-suppress.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1
