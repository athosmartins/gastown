#!/usr/bin/env bash
# gate-recycled-session-author-fallback.selftest.sh (ga-pyzo)
#
# ga-pyzo (residual of ga-ipf6, which fixed the FIELD used for the liveness
# check; this bug is the GRANULARITY): author_is_alive() matches AUTHOR's
# LITERAL recorded string — session_name form, e.g. batista-wa-gawispc8tmbq —
# against CURRENTLY live `gc session list` entries. AUTHOR is recorded once,
# at gate-submit time, and is tied to ONE session incarnation. When that
# specific session later recycles (restart/crash/reap), the string can NEVER
# match a live session again — even though the durable agent (batista-wa) is
# up and running under a brand-new session id. author_is_alive() then reads a
# LIVE agent as DEAD forever, so retries are impossible (auto-rebase refuses:
# branches are 134+ commits behind, envelope=50), the marker parks, and the
# bead rots while main diverges further and nobody tells the live owner.
#
# EVIDENCE (2026-07-14, 3 parked markers with a live owner):
#   marker ga-wisp-kt795c | autor=batista-wa-gawispc8tmbq | VIVO: batista-wa-gawispiwq9sj
#   marker ga-wisp-13knzo | autor=oracle-wa-gae6ss        | VIVO: oracle-wa (ga-nav3)
#   marker ga-wisp-6x4o86 | autor=peter-wa-awisp63fsp14   | VIVO: peter-wa (ga-2gnr)
#
# FIX (option (a) from the bug — explicit data over suffix-parsing, since
# session-suffix forms vary: -ga2gnr, -gawispiwq9sj, -adhoc-e346188199, with
# no reliable single delimiter):
#   - quality-gate-guard.sh Step 5 resolves the durable agent alias behind
#     AUTHOR via resolve_author_agent_alias() (best-effort, while the
#     submitting session is still very likely alive) and Step 7 persists it
#     as gate.submitted_by_agent metadata, alongside the existing
#     gate.submitted_by (ga-tkvsa) — which remains the sole trusted
#     self-review-exclusion identity, unaffected.
#   - quality-gate-dispatcher.sh reads gate.submitted_by_agent back (Step 3)
#     and both call sites (rebase-path AUTHOR_ALIVE, FAIL-path
#     FAIL_AUTHOR_ALIVE) run it through the SHARED resolve_recycled_author()
#     helper immediately after computing *_ALIVE — if AUTHOR's own session is
#     dead but the recorded agent alias resolves to a LIVE session, the
#     identity is upgraded to the agent and *_ALIVE flips to 1, so every
#     downstream nudge/mail/assign in that call site targets the reachable
#     agent instead of a session string that can never resolve again.
#   - SCOPE GUARD: pool/ephemeral builders (dog-pool, wa-worker, ps-worker)
#     never get an agent fallback (resolve_author_agent_alias refuses to
#     resolve one at the source) — their template alias churns through
#     unrelated occupants constantly, so "the alias is alive" would NOT mean
#     "the same worker is back", unlike a named crew agent's durable identity.
#
# Single shared helper for BOTH dispatcher call sites — the ga-ipf6 lesson
# applied to itself: an earlier version of THIS exact liveness check was
# fixed at one call site and not the other, and a live author's work rotted
# for hours before anyone noticed. This fallback must not be allowed to
# re-diverge the same way.
#
# Acceptance (NB-VERIFY-ARTIFACT — two senses + mutation-test):
#   1. AUTHOR recorded from a RECYCLED session, agent LIVE => alive => bounce
#      +nudge the AGENT.                                            (B1, B7)
#   2. AUTHOR of a genuinely-drained adhoc pool-worker (agent doesn't exist
#      either) => DEAD (do not regress).                                (B5)
#   3. MUTATION-TEST: reverting resolve_recycled_author's fallback body to a
#      pure passthrough (`printf '%s' "$author"`) turns B1's key assertion
#      red — confirms the test actually exercises the fallback, not a
#      tautology. Performed during development (see git history for this
#      file); not re-run automatically on every invocation, matching the
#      gate-author-alive-predicate-unify.selftest.sh (ga-ipf6) convention.
#   4. Non-regression: ga-ipf6 (B8), ga-jyox (B9), ga-tkvsa (A7) all intact.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Mock `gc session list --json` — swappable via $_MOCK_SESS_JSON_CURRENT,
# so the SAME gc() definition can model two different POINTS IN TIME: the
# guard resolves AUTHOR_AGENT at SUBMIT time (author's own session still
# live); the dispatcher's fallback is consulted later, at DISPATCH time
# (after that specific session may have recycled). Using one static mock for
# both would be wrong: resolve_author_agent_alias must NEVER be expected to
# resurrect an already-dead identity — it only captures the alias WHILE it is
# still fresh, for the dispatcher to use after the fact.
gc() {
  case " $* " in
    *" session list "*) echo "$_MOCK_SESS_JSON_CURRENT" ;;
    *) : ;;
  esac
  return 0
}
GC_CITY="/fake/hq"

# Mock 1 — AT SUBMIT TIME: batista-wa's session is batista-wa-gawispc8tmbq,
# STILL LIVE (matches the bug's own marker evidence for what was live when
# the marker was created). This is what quality-gate-guard.sh Step 5/7 sees.
MOCK_SESS_JSON_AT_SUBMIT='[
  {"session_name":"peter-wa-ga2gnr","alias":"peter-wa","name":"peter-wa","agent_name":null,"id":"ga2gnr","closed":false},
  {"session_name":"batista-wa-gawispc8tmbq","alias":"batista-wa","name":"batista-wa","agent_name":null,"id":"gawispc8tmbq","closed":false},
  {"session_name":"wa-worker-adhoc-drained01","alias":"wa-worker","name":"wa-worker","agent_name":null,"id":"drained01","closed":true}
]'

# Mock 2 — AFTER RECYCLE (later, at dispatch time): the SAME
# batista-wa-gawispc8tmbq session is now GONE (no entry at all —
# restart/crash/reap), replaced by a brand-new session
# (batista-wa-gawispiwq9sj) under the SAME durable alias. This is what
# quality-gate-dispatcher.sh sees: the literal recorded AUTHOR can never
# match again, but the alias captured back at submit time (Mock 1) still
# resolves to this new session. wa-worker-adhoc-drained01 stays closed in
# both mocks — a genuinely drained adhoc pool worker, never resurrected.
MOCK_SESS_JSON_AFTER_RECYCLE='[
  {"session_name":"peter-wa-ga2gnr","alias":"peter-wa","name":"peter-wa","agent_name":null,"id":"ga2gnr","closed":false},
  {"session_name":"batista-wa-gawispiwq9sj","alias":"batista-wa","name":"batista-wa","agent_name":null,"id":"gawispiwq9sj","closed":false},
  {"session_name":"wa-worker-adhoc-drained01","alias":"wa-worker","name":"wa-worker","agent_name":null,"id":"drained01","closed":true}
]'

# ═══ PART A: guard — resolve_author_agent_alias ═════════════════════════════
echo "=== PART A: quality-gate-guard.sh resolve_author_agent_alias ==="
_MOCK_SESS_JSON_CURRENT="$MOCK_SESS_JSON_AT_SUBMIT"

GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type resolve_author_agent_alias >/dev/null 2>&1 \
  || { echo "FATAL: resolve_author_agent_alias not defined by guard (ga-pyzo missing?)"; exit 1; }

log() { :; }  # quiet noise from sourced helpers

echo "── A1. author's own session, still live at submit time → resolves to its durable alias ──"
eq "batista-wa-gawispc8tmbq (live NOW, at submit time) → alias 'batista-wa'" \
  "$(resolve_author_agent_alias "batista-wa-gawispc8tmbq")" "batista-wa"

echo "── A2. author already IS the alias (no session suffix) → empty (no new info) ──"
eq "batista-wa (already the alias) → empty" \
  "$(resolve_author_agent_alias "batista-wa")" ""

echo "── A3. genuinely-dead adhoc pool worker → empty (closed session) ──"
eq "wa-worker-adhoc-drained01 → empty" \
  "$(resolve_author_agent_alias "wa-worker-adhoc-drained01")" ""

echo "── A4. no-such-session → empty ──"
eq "no-such-session-anywhere → empty" \
  "$(resolve_author_agent_alias "no-such-session-anywhere")" ""

echo "── A5. empty author → empty (no crash under set -e) ──"
eq "empty author → empty" \
  "$(resolve_author_agent_alias "")" ""

echo "── A6. SCOPE GUARD: pool/ephemeral authors never get an agent fallback ──"
eq "gastown.dog (bare alias) → empty (pool, excluded by design)" \
  "$(resolve_author_agent_alias "gastown.dog")" ""
eq "gastown.dog-3 (template alias form) → empty (pool, excluded by design)" \
  "$(resolve_author_agent_alias "gastown.dog-3")" ""
eq "dog-gabjtm (session_name form) → empty (pool, excluded by design)" \
  "$(resolve_author_agent_alias "dog-gabjtm")" ""
eq "wa-worker-adhoc-a1b60f0190 → empty (pool, excluded by design)" \
  "$(resolve_author_agent_alias "wa-worker-adhoc-a1b60f0190")" ""
eq "ps-worker-adhoc-deadbeef → empty (pool, excluded by design)" \
  "$(resolve_author_agent_alias "ps-worker-adhoc-deadbeef")" ""
eq "mayor → empty (routing sentinel, excluded by design)" \
  "$(resolve_author_agent_alias "mayor")" ""

echo "── A7. drift guard: guard's Step 5/7 wiring on the live shipped source ──"
grep -qF 'AUTHOR_AGENT=$(resolve_author_agent_alias "$AUTHOR")' "$GUARD" \
  && ok "guard Step 5 calls resolve_author_agent_alias" \
  || bad "guard Step 5 does NOT call resolve_author_agent_alias — wiring missing/renamed"
grep -qF -- '--set-metadata "gate.submitted_by_agent=$AUTHOR_AGENT"' "$GUARD" \
  && ok "guard Step 7 persists gate.submitted_by_agent" \
  || bad "guard Step 7 gate.submitted_by_agent write MISSING"
grep -qF -- '--set-metadata "gate.submitted_by=$AUTHOR"' "$GUARD" \
  && ok "guard Step 7 STILL persists gate.submitted_by unchanged (ga-tkvsa non-regression)" \
  || bad "guard Step 7 gate.submitted_by write missing/changed — ga-tkvsa regressed?"

# ═══ PART B: dispatcher — resolve_recycled_author + author_is_alive ═════════
echo ""
echo "=== PART B: quality-gate-dispatcher.sh resolve_recycled_author ==="
_MOCK_SESS_JSON_CURRENT="$MOCK_SESS_JSON_AFTER_RECYCLE"

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type resolve_recycled_author >/dev/null 2>&1 \
  || { echo "FATAL: resolve_recycled_author not defined by dispatcher (ga-pyzo missing?)"; exit 1; }
type author_is_alive >/dev/null 2>&1 \
  || { echo "FATAL: author_is_alive not defined by dispatcher (ga-ipf6 missing?)"; exit 1; }

log()  { :; }
warn() { :; }
err()  { :; }

echo "── B1. THE bug scenario: recycled session, live agent → redirects to agent ──"
eq "author_is_alive of the OLD dead session_name → 0 (genuinely gone)" \
  "$(author_is_alive "batista-wa-gawispc8tmbq")" "0"
eq "author_is_alive of the durable alias → 1 (agent IS live, under a new session)" \
  "$(author_is_alive "batista-wa")" "1"
eq "resolve_recycled_author(dead-session, alive-agent, 0) → the agent (THE FIX)" \
  "$(resolve_recycled_author "batista-wa-gawispc8tmbq" "batista-wa" "0")" \
  "batista-wa"

echo "── B2. already alive → no-op (fallback never consulted) ──"
eq "already alive (1) → author unchanged even if agent differs" \
  "$(resolve_recycled_author "peter-wa-ga2gnr" "some-other-agent" "1")" \
  "peter-wa-ga2gnr"

echo "── B3. no agent recorded → no-op, stays dead (legacy markers / pool workers) ──"
eq "no AUTHOR_AGENT (empty) → author unchanged" \
  "$(resolve_recycled_author "batista-wa-gawispc8tmbq" "" "0")" \
  "batista-wa-gawispc8tmbq"

echo "── B4. agent identical to author → no-op (no new info) ──"
eq "agent == author → author unchanged" \
  "$(resolve_recycled_author "batista-wa" "batista-wa" "0")" \
  "batista-wa"

echo "── B5. genuinely drained: neither session NOR agent alive → stays dead (ACCEPT-2) ──"
eq "dead session + dead/closed agent alias → author unchanged (still dead)" \
  "$(resolve_recycled_author "wa-worker-adhoc-drained01" "wa-worker" "0")" \
  "wa-worker-adhoc-drained01"
eq "dead session + nonexistent agent → author unchanged (still dead)" \
  "$(resolve_recycled_author "no-such-session" "also-no-such-agent" "0")" \
  "no-such-session"

echo "── B6. author_alive input sanitization: garbage → treated as dead, fallback tried ──"
eq "alive='' (garbage) + live agent → falls back to agent (sanitized to 0)" \
  "$(resolve_recycled_author "batista-wa-gawispc8tmbq" "batista-wa" "")" \
  "batista-wa"
eq "alive='xx' (garbage) + live agent → falls back to agent (sanitized to 0)" \
  "$(resolve_recycled_author "batista-wa-gawispc8tmbq" "batista-wa" "xx")" \
  "batista-wa"

# ── B7. drift guard: BOTH call sites wired to the SAME shared fallback ──────
# (ga-ipf6 lesson: a predicate fixed at one call site and not the other
# stranded a live author for hours — the exact class of bug this guards.)
echo "── B7. drift guard: both dispatcher call sites wired to resolve_recycled_author ──"
if grep -qF '_RESOLVED_AUTHOR=$(resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" "$AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "rebase-path wired to resolve_recycled_author"
else
  bad "rebase-path NOT wired to resolve_recycled_author — fallback missing on this call site?"
fi
if grep -qF '_RESOLVED_AUTHOR=$(resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" "$FAIL_AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "FAIL-path wired to resolve_recycled_author"
else
  bad "FAIL-path NOT wired to resolve_recycled_author — fallback missing on this call site?"
fi

# ── B8. ga-ipf6 non-regression: original AUTHOR_ALIVE/FAIL_AUTHOR_ALIVE lines
#    are UNCHANGED verbatim — this fix must layer ON TOP of author_is_alive,
#    never replace its call sites (drift-guarded independently by
#    gate-author-alive-predicate-unify.selftest.sh too — belt and suspenders).
echo "── B8. ga-ipf6 non-regression: original AUTHOR_ALIVE/FAIL_AUTHOR_ALIVE lines intact ──"
if grep -qF 'AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")' "$DISPATCHER"; then
  ok 'rebase-path AUTHOR_ALIVE=$(author_is_alive "$AUTHOR") still present verbatim'
else
  bad "rebase-path AUTHOR_ALIVE computation missing/changed — ga-ipf6 regressed?"
fi
if grep -qF 'FAIL_AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")' "$DISPATCHER"; then
  ok 'FAIL-path FAIL_AUTHOR_ALIVE=$(author_is_alive "$AUTHOR") still present verbatim'
else
  bad "FAIL-path FAIL_AUTHOR_ALIVE computation missing/changed — ga-ipf6 regressed?"
fi

# ── B9. ga-jyox non-regression: decision wiring UNCHANGED verbatim ──────────
echo "── B9. ga-jyox non-regression: GATE_FAIL_ASSIGNEE_ACTION wiring intact ──"
if grep -qF 'GATE_FAIL_ASSIGNEE_ACTION=$(gate_fail_assignee_action "$AUTHOR" "$FAIL_AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "GATE_FAIL_ASSIGNEE_ACTION still fed by \$AUTHOR/\$FAIL_AUTHOR_ALIVE — ga-jyox intact"
else
  bad "GATE_FAIL_ASSIGNEE_ACTION wiring missing/changed — ga-jyox regressed?"
fi
eq "ga-jyox: recycled-but-live author (post-fallback) → keep (unaffected downstream)" \
  "$(gate_fail_assignee_action "batista-wa" "1")" \
  "keep"

# ── B10. drift guard: dispatcher reads gate.submitted_by_agent ─────────────
echo "── B10. drift guard: dispatcher Step 3 reads gate.submitted_by_agent ──"
grep -q 'metadata\["gate.submitted_by_agent"\]' "$DISPATCHER" \
  && ok "dispatcher reads gate.submitted_by_agent from the marker" \
  || bad "dispatcher gate.submitted_by_agent read MISSING"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-recycled-session-author-fallback selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-recycled-session-author-fallback selftest"
  exit 1
fi
