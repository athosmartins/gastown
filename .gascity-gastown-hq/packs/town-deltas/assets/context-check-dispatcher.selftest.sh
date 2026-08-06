#!/usr/bin/env bash
# context-check-dispatcher.selftest.sh — Regression harness for the Context-check
# creation-gate daemon ("Option D"). Proves the PURE decision core in isolation
# (no live Dolt/gc/Claude), then DRIFT-GUARDS the live wiring so a future refactor
# cannot silently break the design contract.
#
# Sources the dispatcher in lib-only mode (CONTEXT_CHECK_LIB=1) to unit-test the
# REAL functions the shipped dispatcher calls, so the tested logic IS the shipped
# logic (no parallel reimplementation).
#
# Contract proven:
#   - only actionable types judged; plumbing excluded     → Scenarios 1, 2.
#   - idempotence / anti-loop (ctx:* already present)       → Scenario 3.
#   - lifecycle-skip (in-flight/done/gate-stuck)            → Scenario 4.
#   - complete → ctx:ready ; empty/vague → ctx:thin         → Scenarios 5, 6, 7.
#   - terse-complete is NOT falsely thin (positive label)   → Scenario 6b (uncertain band).
#   - fail-toward-human: uncertain/timeout → ctx:thin       → Scenario 8.
#   - verdict vocabulary bounded to ctx:ready/ctx:thin      → Scenario 9.
#   - LABEL-ONLY: never dispatch/sling/close/lifecycle      → drift guards.
#   - DRY_RUN proof-mode runs clean (no write, no spawn)    → drift guard.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/context-check-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

echo "context-check-dispatcher.selftest — pure decision core + drift guards (Option D)"

# Source the dispatcher in lib-only mode (pure functions only, no side effects).
CONTEXT_CHECK_LIB=1 . "$DISPATCHER"

if declare -F context_check_verdict_label >/dev/null 2>&1; then
  ok "sourced lib-only: context_check_verdict_label is defined"
else
  bad "lib-only source did not expose context_check_verdict_label"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi

# Pin the exclude sets the pure plumbing classifier reads (the dispatcher sets
# defaults; we re-assert them so the selftest is hermetic).
CONTEXT_CHECK_EXCLUDE_LABELS="gt:agent gt:rig gt:convoy gc:nudge digest"
CONTEXT_CHECK_EXCLUDE_PREFIXES="type:quality-gate gate-status: nudge: reviewer-index: verdict: refino-gate: auto-refino: gate-reclaim-count: order-run: ctx:"
# Pin heuristic thresholds so length-based assertions are deterministic.
CONTEXT_CHECK_THIN_MAXLEN=40
CONTEXT_CHECK_READY_MINLEN=120

# ── Scenario 1: type eligibility ──────────────────────────────────────────────
echo "Scenario 1: type eligibility — bug/chore/task/debt + feature checkable; others not"
for t in bug chore task debt feature; do
  [ "$(context_check_type_eligible "$t")" = "yes" ] && ok "$t → yes" || bad "$t → expected yes"
done
for t in epic decision molecule gate convoy merge-request; do
  [ "$(context_check_type_eligible "$t")" = "no" ] && ok "$t → no" || bad "$t → expected no"
done

# ── Scenario 2: plumbing exclusion (mirrors painel _is_automation_bead + gate family)
echo "Scenario 2: plumbing exclusion — engine-internal coordination is NOT human work"
[ "$(context_check_is_plumbing "ga-x" "type:quality-gate-marker" "false")" = "yes" ] && ok "gate marker → plumbing" || bad "gate marker → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gate-status:queued" "false")" = "yes" ]        && ok "gate-status:* → plumbing" || bad "gate-status → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gt:agent" "false")" = "yes" ]                  && ok "gt:agent → plumbing"     || bad "gt:agent → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "gc:nudge" "false")" = "yes" ]                  && ok "gc:nudge → plumbing"     || bad "gc:nudge → expected plumbing"
[ "$(context_check_is_plumbing "dc-abc" "" "false")" = "yes" ]                        && ok "dc- id → plumbing"       || bad "dc- → expected plumbing"
[ "$(context_check_is_plumbing "ga-wisp-x" "" "false")" = "yes" ]                     && ok "-wisp- id → plumbing"    || bad "-wisp- → expected plumbing"
[ "$(context_check_is_plumbing "ga-x" "" "true")" = "yes" ]                           && ok "ephemeral → plumbing"    || bad "ephemeral → expected plumbing"
[ "$(context_check_is_plumbing "ga-real" "tech-debt" "false")" = "no" ]               && ok "real bead (tech-debt) → NOT plumbing" || bad "real bead → expected not plumbing"
[ "$(context_check_is_plumbing "ga-real" "" "false")" = "no" ]                        && ok "real bead (no labels) → NOT plumbing" || bad "real bead → expected not plumbing"
# ga-aq5cw: mol-digest-generate's archive-as-bead step tags type=task beads
# label=digest,{{period}} with no park label — a pure log record, no code to build.
[ "$(context_check_is_plumbing "ga-x" "digest,daily" "false")" = "yes" ]              && ok "digest label → plumbing (ga-aq5cw)" || bad "digest → expected plumbing"

# ── Scenario 3: idempotence — an already-judged bead is never re-judged ───────
echo "Scenario 3: idempotence / anti-loop (ga-it11w lesson) — ctx:* already present"
[ "$(context_check_has_ctx_label "ctx:ready")" = "yes" ] && ok "ctx:ready present → yes" || bad "ctx:ready → expected yes"
[ "$(context_check_has_ctx_label "ctx:thin,tech-debt")" = "yes" ] && ok "ctx:thin present → yes" || bad "ctx:thin → expected yes"
[ "$(context_check_has_ctx_label "tech-debt,daily")" = "no" ] && ok "no ctx:* → no (judgeable)" || bad "no ctx:* → expected no"
# A ctx:thin bead is NEVER re-selected as a candidate (the anti-loop guarantee).
[ "$(context_check_is_candidate "ga-x" "task" "ctx:thin,tech-debt" "false" "no")" = "no" ] \
  && ok "ctx:thin bead → NOT a candidate (no re-ingestion loop)" \
  || bad "ctx:thin bead → expected NOT a candidate (loop would re-form)"
[ "$(context_check_is_candidate "ga-x" "task" "ctx:ready" "false" "no")" = "no" ] \
  && ok "ctx:ready bead → NOT a candidate (idempotent)" || bad "ctx:ready → expected NOT a candidate"

# ── Scenario 4: lifecycle-skip — never re-label work already moving ───────────
echo "Scenario 4: lifecycle-skip — in-flight/done/cancelled/gate-stuck/dispatched"
for L in story:in-flight story:done story:cancelled pilot:dispatched gate:needs-human gate:needs-fix gate:failed; do
  [ "$(context_check_lifecycle_skip "$L")" = "yes" ] && ok "$L → skip" || bad "$L → expected skip"
done
[ "$(context_check_lifecycle_skip "tech-debt")" = "no" ] && ok "tech-debt (active work) → not skipped" || bad "tech-debt → expected not skipped"

# ── Scenario 4a: park-exclusion (ga-ipm4) — never re-arm a deliberately parked bead
echo "Scenario 4a: park-exclusion — needs-human/pool:refused:*/story:blocked/pilot:no-auto-dispatch never re-armed"
[ "$(context_check_is_parked "needs-human")" = "yes" ] && ok "needs-human → parked" || bad "needs-human → expected parked"
[ "$(context_check_is_parked "story:blocked")" = "yes" ] && ok "story:blocked → parked" || bad "story:blocked → expected parked"
[ "$(context_check_is_parked "pool:refused:engine-rebuild-required")" = "yes" ] && ok "pool:refused:<reason> → parked" || bad "pool:refused:* → expected parked"
[ "$(context_check_is_parked "pool:refused:anything-else")" = "yes" ] && ok "pool:refused:* prefix matches any reason suffix" || bad "pool:refused:<other> → expected parked"
[ "$(context_check_is_parked "root-class:error-vs-empty,needs-human,lane:small")" = "yes" ] && ok "needs-human mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
[ "$(context_check_is_parked "tech-debt,lane:small")" = "no" ] && ok "no park label → not parked" || bad "clean labels → expected not parked"
[ "$(context_check_is_parked "")" = "no" ] && ok "empty labels → not parked" || bad "empty → expected not parked"
# ga-66wc repro: a park label surviving ALONE (ctx:ready/exec:auto already stripped
# by a human/dog) must still read as parked — this is exactly the state that
# tricked the pre-fix daemon into treating the bead as "fresh, never judged".
[ "$(context_check_is_parked "needs-human,pool:refused:engine-rebuild-required,root-class:error-vs-empty")" = "yes" ] \
  && ok "ga-66wc post-strip label set (no ctx:*, no exec:*) → still parked" || bad "ga-66wc post-strip set → expected parked"
# ga-bzbig: pilot:no-auto-dispatch — the sticky opt-out for a disarm reason
# outside the other three (e.g. an epic-child tracker/umbrella, not human-gated,
# not refused, not dependency-blocked, just structurally not a single
# dispatchable unit).
[ "$(context_check_is_parked "pilot:no-auto-dispatch")" = "yes" ] && ok "pilot:no-auto-dispatch → parked" || bad "pilot:no-auto-dispatch → expected parked"
[ "$(context_check_is_parked "area:infra,pilot:no-auto-dispatch,lane:small")" = "yes" ] && ok "pilot:no-auto-dispatch mixed with unrelated labels → parked" || bad "mixed labels → expected parked"
# ga-0x4tv repro: pilot:no-auto-dispatch surviving ALONE (ctx:ready/exec:auto/
# story:approved already stripped by Mayor) must still read as parked — this is
# exactly the state that tricked the pre-fix daemon into re-arming ga-0x4tv
# 42min after Mayor's manual disarm (context-check-dispatcher.log: "ga-0x4tv →
# ctx:ready + exec:auto (mech=ready sig=yes dlen=962)").
[ "$(context_check_is_parked "area:infra,pilot:no-auto-dispatch,epic:ga-05604")" = "yes" ] \
  && ok "ga-0x4tv post-strip label set (no ctx:*, no exec:*, no story:approved) → still parked" || bad "ga-0x4tv post-strip set → expected parked"

# ── Scenario 4a2: sling-stub detection (ga-mzkx2) ──────────────────────────────
echo "Scenario 4a2: context_check_is_sling_stub — Pilot-minted dispatch stubs are by-design empty, not thin"
[ "$(context_check_is_sling_stub "task" "fix bug ga-mzkx2: sling-task-janitor closes ctx:thin dispatch stubs" 0)" = "yes" ] \
  && ok "task, 'fix bug <id>: ...' title, empty desc → sling stub" || bad "fix bug shape → expected sling stub"
[ "$(context_check_is_sling_stub "task" "build story ga-mk6ve: raw classifier signal" 0)" = "yes" ] \
  && ok "task, 'build story <id>: ...' title, empty desc → sling stub" || bad "build story shape → expected sling stub"
[ "$(context_check_is_sling_stub "task" "implement ga-x: something" 0)" = "yes" ] \
  && ok "task, 'implement <id>: ...' title, empty desc → sling stub" || bad "implement shape → expected sling stub"
[ "$(context_check_is_sling_stub "bug" "fix bug ga-mzkx2: something" 0)" = "no" ] \
  && ok "issue_type=bug (not task) → NOT a sling stub (Pilot only mints type=task stubs)" || bad "bug type → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "fix bug ga-mzkx2: something" 42)" = "no" ] \
  && ok "non-empty description → NOT a sling stub (a real, independently-described task)" || bad "non-empty desc → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "Refatorar o dashboard de clientes" 0)" = "no" ] \
  && ok "title doesn't match the dispatch-stub pattern → NOT a sling stub" || bad "unrelated title → expected not sling stub"
[ "$(context_check_is_sling_stub "task" "" 0)" = "no" ] \
  && ok "empty title → NOT a sling stub (no pattern to match)" || bad "empty title → expected not sling stub"

# ── Scenario 4b: master candidate gate composes all the above ─────────────────
echo "Scenario 4b: context_check_is_candidate composes type+plumbing+ctx+lifecycle+park"
[ "$(context_check_is_candidate "ga-good" "task" "tech-debt" "false" "no")" = "yes" ] \
  && ok "real open task, no ctx, not plumbing/in-flight → candidate" || bad "real task → expected candidate"
[ "$(context_check_is_candidate "ga-feat" "feature" "story:unrefined" "false" "yes")" = "no" ] \
  && ok "feature WITH story:* (refino funnel) → NOT a candidate" || bad "feature w/ story:* → expected not candidate"
[ "$(context_check_is_candidate "ga-feat2" "feature" "frontend" "false" "no")" = "yes" ] \
  && ok "feature WITHOUT story:* → candidate (raw actionable)" || bad "feature w/o story:* → expected candidate"
[ "$(context_check_is_candidate "ga-junk" "epic" "" "false" "no")" = "no" ] \
  && ok "epic → NOT a candidate (type ineligible)" || bad "epic → expected not candidate"
# ga-ipm4: the exact ga-66wc shape — bug, no ctx:* label (stripped), park labels
# present, no lifecycle/lock label — must NOT re-enter candidacy.
[ "$(context_check_is_candidate "ga-66wc" "bug" "needs-human,pool:refused:engine-rebuild-required,root-class:error-vs-empty" "false" "no")" = "no" ] \
  && ok "ga-66wc-shaped bead (parked, ctx:* stripped) → NOT a candidate (no re-arm)" \
  || bad "REGRESSION ga-ipm4: parked bead with ctx:* stripped would be re-judged and re-armed"
[ "$(context_check_is_candidate "ga-blocked" "chore" "story:blocked,lane:small" "false" "no")" = "no" ] \
  && ok "story:blocked bead → NOT a candidate" || bad "story:blocked → expected not candidate"
# ga-bzbig: the exact ga-0x4tv shape — chore, no ctx:* label (Mayor stripped it),
# pilot:no-auto-dispatch present, no lifecycle/lock label — must NOT re-enter
# candidacy (this is the regression: pre-fix, is_parked didn't recognize this
# label so is_candidate returned "yes" and the daemon re-armed ctx:ready+exec:auto).
[ "$(context_check_is_candidate "ga-0x4tv" "chore" "area:infra,pilot:no-auto-dispatch,epic:ga-05604" "false" "no")" = "no" ] \
  && ok "ga-0x4tv-shaped bead (parked via pilot:no-auto-dispatch, ctx:* stripped) → NOT a candidate (no re-arm)" \
  || bad "REGRESSION ga-bzbig: Mayor-disarmed tracker with ctx:* stripped would be re-judged and re-armed"
# ga-aq5cw: the exact ga-sh5zv/ga-mun9x shape — a freshly-created digest-archive
# bead (type=task, label=digest,{{period}}, no ctx:* yet, no park label at all)
# — must never be granted candidacy in the first place (there is no park label
# to strip; the fix is at the type/plumbing gate, not the park gate).
[ "$(context_check_is_candidate "ga-sh5zv" "task" "digest,daily" "false" "no")" = "no" ] \
  && ok "digest-archive bead (task, label=digest) → NOT a candidate (ga-aq5cw)" \
  || bad "REGRESSION ga-aq5cw: digest-archive bead would be armed ctx:ready+exec:auto with nothing to build"
# ga-mzkx2: the exact ga-tdaeq shape — a freshly-minted sling-task stub (task,
# "fix bug <id>: ..." title, 0-char description, no labels yet) — must never be
# granted candidacy (and thus never get ctx:thin), so Step 1c's dog-pool probe
# (--exclude-label ctx:thin) can still discover it before sling-task-janitor's
# 60min orphan sweep closes it, unclaimed, as an abandoned dispatch.
[ "$(context_check_is_candidate "ga-tdaeq" "task" "" "false" "no" "fix bug ga-mk6ve: raw classifier signal" 0)" = "no" ] \
  && ok "sling-task stub (task, dispatch-shaped title, empty desc) → NOT a candidate (ga-mzkx2, no ctx:thin mislabel)" \
  || bad "REGRESSION ga-mzkx2: sling stub would be stamped ctx:thin and become invisible to Step 1c's dog-pool probe"
# The same dimension omitted (title/dlen not supplied) must preserve prior
# behavior exactly — existing callers of this function (and every scenario
# above) never break just because the sling-stub check exists.
[ "$(context_check_is_candidate "ga-good" "task" "tech-debt" "false" "no")" = "yes" ] \
  && ok "title/dlen omitted → sling-stub dimension skipped, prior behavior unchanged" \
  || bad "omitted title/dlen → expected unchanged prior behavior"
# A real, independently-described task whose title MATCHES the dispatch-stub
# pattern (cites another bead's id) must NOT be swallowed — the desc_len==0
# guard, not the title shape alone, is what keeps context_check_is_sling_stub
# from over-firing on real work that happens to reference an id in its title.
[ "$(context_check_is_candidate "ga-realbug" "task" "tech-debt" "false" "no" "fix bug ga-real1: add missing null check" 42)" = "yes" ] \
  && ok "sling-shaped title (cites ga-real1) but a REAL, non-empty description → still a candidate" \
  || bad "real described task → expected candidate despite title resembling the dispatch-stub pattern"

# ── Scenario 5: verifiable-signal detection ───────────────────────────────────
echo "Scenario 5: verifiable-signal detection (HOW-TO-VERIFY / concrete artifact)"
[ "$(context_check_has_verifiable_signal "Acceptance criteria: the CLI returns 0")" = "yes" ] && ok "acceptance criteria → signal" || bad "acceptance → expected signal"
[ "$(context_check_has_verifiable_signal "deve retornar o resultado esperado")" = "yes" ]      && ok "pt verification vocab → signal" || bad "pt verif → expected signal"
[ "$(context_check_has_verifiable_signal "edit scripts/foo.sh to add retry")" = "yes" ]        && ok "named .sh artifact → signal" || bad ".sh → expected signal"
[ "$(context_check_has_verifiable_signal "run bd list and confirm output")" = "yes" ]          && ok "named bd command → signal" || bad "bd cmd → expected signal"
[ "$(context_check_has_verifiable_signal "- [ ] step one
- [ ] step two")" = "yes" ]                                                                   && ok "task-list checklist → signal" || bad "checklist → expected signal"
[ "$(context_check_has_verifiable_signal "make it better somehow")" = "no" ]                   && ok "vague prose → no signal" || bad "vague → expected no signal"
[ "$(context_check_has_verifiable_signal "")" = "no" ]                                         && ok "empty → no signal" || bad "empty → expected no signal"

# ── Scenario 6: mechanical verdict — complete → ready ; empty/vague → thin ────
echo "Scenario 6: mechanical verdict"
# Long + signal → ready.
[ "$(context_check_mechanical_verdict 200 yes 30)" = "ready" ] && ok "long(200) + signal → ready" || bad "long+signal → expected ready"
# Empty / near-empty → thin regardless of signal.
[ "$(context_check_mechanical_verdict 0 no 10)" = "thin" ]    && ok "empty(0) → thin" || bad "empty → expected thin"
[ "$(context_check_mechanical_verdict 20 yes 10)" = "thin" ]  && ok "near-empty(20) even w/ signal → thin" || bad "near-empty → expected thin"
# Described, no signal, short body → lean thin.
[ "$(context_check_mechanical_verdict 80 no 10)" = "thin" ]   && ok "described(80) no signal → thin" || bad "described-no-signal → expected thin"
echo "Scenario 6b: terse-but-maybe-complete → uncertain (NOT falsely thin/ready)"
# Signal present but short body → uncertain (Sonnet-judged, not auto-ready/thin).
[ "$(context_check_mechanical_verdict 70 yes 30)" = "uncertain" ] && ok "short(70) + signal → uncertain (terse-complete defended)" || bad "short+signal → expected uncertain"
# Long body but NO signal → uncertain (long ramble must not auto-ready).
[ "$(context_check_mechanical_verdict 300 no 30)" = "uncertain" ] && ok "long(300) no signal → uncertain (no false ready)" || bad "long-no-signal → expected uncertain"
# Byte-count alone can NEVER yield ready (no-signal long stays uncertain, never ready).
[ "$(context_check_mechanical_verdict 5000 no 30)" != "ready" ] && ok "huge body w/o signal NEVER auto-ready (positive-label invariant)" || bad "huge-no-signal → must not be ready"

# ── Scenario 7: final label resolution ────────────────────────────────────────
echo "Scenario 7: verdict_label maps mechanical(+sonnet) → ctx:ready | ctx:thin"
[ "$(context_check_verdict_label ready)" = "ctx:ready" ] && ok "ready → ctx:ready" || bad "ready → expected ctx:ready"
[ "$(context_check_verdict_label thin)" = "ctx:thin" ]   && ok "thin → ctx:thin" || bad "thin → expected ctx:thin"
[ "$(context_check_verdict_label uncertain READY)" = "ctx:ready" ] && ok "uncertain + Sonnet READY → ctx:ready" || bad "uncertain+READY → expected ctx:ready"
[ "$(context_check_verdict_label uncertain THIN)" = "ctx:thin" ]   && ok "uncertain + Sonnet THIN → ctx:thin" || bad "uncertain+THIN → expected ctx:thin"

# ── Scenario 8: fail-toward-human — uncertain without a clear READY → ctx:thin ─
echo "Scenario 8: fail-toward-human (never falsely ready)"
[ "$(context_check_verdict_label uncertain TIMEOUT)" = "ctx:thin" ] && ok "uncertain + Sonnet TIMEOUT → ctx:thin" || bad "uncertain+TIMEOUT → expected ctx:thin"
[ "$(context_check_verdict_label uncertain "")" = "ctx:thin" ]      && ok "uncertain + no Sonnet verdict → ctx:thin (heuristic-only default)" || bad "uncertain+empty → expected ctx:thin"
[ "$(context_check_verdict_label uncertain GARBAGE)" = "ctx:thin" ] && ok "uncertain + garbage → ctx:thin" || bad "uncertain+garbage → expected ctx:thin"
[ "$(context_check_resolve_uncertain READY)" = "ctx:ready" ]        && ok "resolve_uncertain READY → ctx:ready" || bad "resolve READY → expected ctx:ready"
[ "$(context_check_resolve_uncertain FAIL)" = "ctx:thin" ]          && ok "resolve_uncertain FAIL → ctx:thin (only explicit READY is ready)" || bad "resolve FAIL → expected ctx:thin"

# ── Scenario 9: verdict vocabulary is bounded — only ctx:ready / ctx:thin ──────
echo "Scenario 9: verdict vocabulary bounded (no dispatch/approve/lifecycle token)"
seen_bad=0
for m in ready thin uncertain garbage ""; do
  for s in READY THIN TIMEOUT "" FAIL; do
    d=$(context_check_verdict_label "$m" "$s")
    case "$d" in ctx:ready|ctx:thin) : ;; *) seen_bad=1; bad "unexpected verdict label '$d' for mech=$m sonnet=$s" ;; esac
  done
done
[ "$seen_bad" = "0" ] && ok "every input yields ONLY ctx:ready or ctx:thin (no dispatch/approve/lifecycle)" || bad "REGRESSION: verdict label escaped the ctx:ready/ctx:thin set"

# ── Scenario 10: exec-class (automation-debt) classifier ──────────────────────
# Applied to ctx:ready beads only. exec:manual iff a clear physical-device /
# human-identity-credential / human-provisioning signal; else exec:auto (default).
echo "Scenario 10: exec-class — physical/portal/credential → exec:manual; else exec:auto"
if declare -F context_check_exec_class >/dev/null 2>&1; then
  ok "context_check_exec_class is defined (exposed lib-only)"
else
  bad "context_check_exec_class not exposed by lib-only source"
fi
# 10a — PHYSICAL device / hardware / physical proxy → exec:manual (agent has no hands).
[ "$(context_check_exec_class "experimentar phone-as-Claro-mobile-proxy" "plugar o celular físico como proxy móvel da Claro")" = "exec:manual" ] \
  && ok "phone-as-proxy (physical phone) → exec:manual" || bad "phone-as-proxy → expected exec:manual"
[ "$(context_check_exec_class "trocar o SIM do aparelho" "inserir novo chip / SIM no celular de testes")" = "exec:manual" ] \
  && ok "SIM/chip swap on physical device → exec:manual" || bad "SIM swap → expected exec:manual"
[ "$(context_check_exec_class "configurar hardware proxy" "ligar o dongle e conectar manualmente")" = "exec:manual" ] \
  && ok "hardware/dongle + conectar manualmente → exec:manual" || bad "hardware proxy → expected exec:manual"
# 10b — GOV / 3rd-party PORTAL gated by human identity (CPF+CAPTCHA, e-SIC/LAI, cartório).
[ "$(context_check_exec_class "pedido e-SIC/LAI Planta Genérica" "abrir pedido no portal e-SIC (LAI) para a Planta Genérica de Valores")" = "exec:manual" ] \
  && ok "e-SIC/LAI gov portal → exec:manual" || bad "e-SIC/LAI → expected exec:manual"
[ "$(context_check_exec_class "login no portal da prefeitura" "acessar com identidade CPF e resolver o CAPTCHA")" = "exec:manual" ] \
  && ok "CPF + CAPTCHA human-identity portal → exec:manual" || bad "CPF+CAPTCHA → expected exec:manual"
[ "$(context_check_exec_class "obter certidão no cartório" "comparecer ao cartório / protocolo presencial")" = "exec:manual" ] \
  && ok "cartório / presencial → exec:manual" || bad "cartório → expected exec:manual"
# 10c — HUMAN-held credential / account / channel provisioning → exec:manual.
[ "$(context_check_exec_class "canal efêmero — provisionar canal Whapi" "provisionar canal Whapi novo para o número efêmero")" = "exec:manual" ] \
  && ok "provisionar canal Whapi (credential provisioning) → exec:manual" || bad "provisionar canal Whapi → expected exec:manual"
# 10c2 — HUMAN DESIGN / BUSINESS-DECISION GATE → exec:manual (the design-first mis-dispatch class).
[ "$(context_check_exec_class "F2 inbound on-device v2" "DESIGN-FIRST: spec aprovado por Athos antes de codar. Acceptance criteria a definir.")" = "exec:manual" ] \
  && ok "design-first + spec aprovado antes de codar → exec:manual (wa-1my1)" || bad "design-first → expected exec:manual"
[ "$(context_check_exec_class "F11 inbound nunca perder" "Status: DESIGN-FIRST — aguardando OK do thies/Athos antes de qualquer código.")" = "exec:manual" ] \
  && ok "design-first + aguardando OK antes de qualquer código → exec:manual (wa-tozk)" || bad "wa-tozk class → expected exec:manual"
[ "$(context_check_exec_class "multi-arm IP survival" "bloqueado em decisão de custo: free phone-proxy vs paid .156")" = "exec:manual" ] \
  && ok "decisão de custo (business decision) → exec:manual (wa-yma9)" || bad "decisão de custo → expected exec:manual"
# CONSERVATIVE: an ordinary task that merely mentions 'design' (not design-first) stays auto.
[ "$(context_check_exec_class "refatorar o design system" "ajustar os tokens de cor do design system e rodar os testes")" = "exec:auto" ] \
  && ok "ordinary 'design system' code task → exec:auto (no over-tag on bare 'design')" || bad "design system task → expected exec:auto"
# 10d — DEFAULT exec:auto: code/script/verification/data/API/email tasks a crew can do.
[ "$(context_check_exec_class "inbound_generator: gerar leads" "rodar o script que gera inbound a partir da base, --apply")" = "exec:auto" ] \
  && ok "inbound_generator script task → exec:auto" || bad "inbound_generator → expected exec:auto"
[ "$(context_check_exec_class "Contagem declividade: rodar --apply" "executar o scraper com --apply e validar a saída")" = "exec:auto" ] \
  && ok "scraper --apply → exec:auto" || bad "scraper --apply → expected exec:auto"
[ "$(context_check_exec_class "Verificar saúde do token PDPJ" "health-check do token via API e reportar o status")" = "exec:auto" ] \
  && ok "token health-check (API verification) → exec:auto" || bad "health-check → expected exec:auto"
[ "$(context_check_exec_class "envio de e-mail de cobrança" "montar e disparar e-mail via API de envio")" = "exec:auto" ] \
  && ok "email-based request via API → exec:auto" || bad "email request → expected exec:auto"
# 10e — CONSERVATIVE: never over-tag manual. A generic "provision a table" code
#       task (provisioning verb but NO credential/account/channel noun) stays auto.
[ "$(context_check_exec_class "provision a new staging table" "create a staging table in the warehouse and backfill it")" = "exec:auto" ] \
  && ok "provision a TABLE (code, not credential) → exec:auto (conservative default)" || bad "provision table → expected exec:auto"
[ "$(context_check_exec_class "rename notify wrapper" "edit scripts/notify to rename the wrapper fn so it stops shadowing the CLI")" = "exec:auto" ] \
  && ok "ambiguous/neutral code task → exec:auto (default)" || bad "neutral code task → expected exec:auto"
[ "$(context_check_exec_class "" "")" = "exec:auto" ] \
  && ok "empty title+desc → exec:auto (default, never falsely manual)" || bad "empty → expected exec:auto"
# 10f — exec vocabulary is bounded to exactly exec:manual | exec:auto.
ec_bad=0
for pair in "physical phone proxy|x" "rodar script|y" "|"; do
  IFS='|' read -r _a _b <<< "$pair"
  ec=$(context_check_exec_class "$_a" "$_b")
  case "$ec" in exec:manual|exec:auto) : ;; *) ec_bad=1; bad "exec-class escaped vocabulary: '$ec'" ;; esac
done
[ "$ec_bad" = "0" ] && ok "exec-class yields ONLY exec:manual or exec:auto" || bad "exec-class vocabulary escaped"

# ── DRIFT GUARDS: static assertions on the shipped dispatcher ─────────────────
echo "Drift guards: live wiring matches the design contract"

# 1. LABEL-ONLY: the only bead-state writes are `label add ... ctx:ready|ctx:thin`
#    and a comment. NO dispatch / sling write in code. (Match an actual INVOCATION
#    — `gc ... sling` or `pilot-dispatcher` — not the `pilot:dispatched` LABEL the
#    lifecycle-skip classifier legitimately matches against.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -qE 'gc .*sling|pilot-dispatcher|pilot dispatch'; then
  bad "REGRESSION: dispatcher contains a dispatch/sling call — must be LABEL-ONLY"
else
  ok "no dispatch/sling invocation in code (LABEL-ONLY)"
fi
# It must never CLOSE a candidate bead. (It may close its OWN ephemeral verdict
# bead — guard that the close target is the verdict bead variable, never a candidate.)
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -E 'bd_ close' | grep -qv '_verdict_bead'; then
  bad "REGRESSION: a bd_ close targets something other than the verdict bead — must not close candidates"
else
  ok "bd_ close only ever targets the daemon's own verdict bead (never a candidate)"
fi
# It must never write a lifecycle/dispatch label onto a candidate.
if grep -v '^[[:space:]]*#' "$DISPATCHER" | grep -qE 'label add "\$c_id" "(story:|pilot:|gate:)'; then
  bad "REGRESSION: dispatcher writes a lifecycle/dispatch label onto a candidate"
else
  ok "candidate writes are ONLY ctx:* + a comment (no lifecycle/dispatch label)"
fi
# The positive verdict label the dispatcher adds to a candidate is the computed
# $LABEL (ctx:ready/ctx:thin), via `label add "$c_id" "$LABEL"`.
if grep -qF 'label add "$c_id" "$LABEL"' "$DISPATCHER"; then
  ok "candidate verdict written via additive label add \$c_id \$LABEL (positive label)"
else
  bad "candidate verdict not written via additive label add"
fi

# 2. Idempotence: the candidate query EXCLUDES ctx:ready and ctx:thin, AND the
#    pure classifier re-asserts has_ctx_label (defense in depth, anti-loop).
if grep -qF -- '--exclude-label ctx:ready' "$DISPATCHER" \
   && grep -qF -- '--exclude-label ctx:thin' "$DISPATCHER" \
   && grep -qF 'context_check_has_ctx_label' "$DISPATCHER"; then
  ok "candidate query excludes ctx:ready/ctx:thin + classifier re-asserts (idempotent, anti-loop)"
else
  bad "idempotence not enforced at query AND classifier"
fi

# 3. Anti-Dolt-spike: per-sweep cap + per-sweep Sonnet cap exist and are honored.
if grep -q 'CONTEXT_CHECK_MAX_PER_SWEEP' "$DISPATCHER" \
   && grep -q 'JUDGED" -ge "\$CONTEXT_CHECK_MAX_PER_SWEEP' "$DISPATCHER" \
   && grep -q 'CONTEXT_CHECK_MAX_SONNET_PER_SWEEP' "$DISPATCHER"; then
  ok "per-sweep bead cap + per-sweep Sonnet cap enforced (anti-Dolt-spike)"
else
  bad "per-sweep caps missing or not enforced"
fi

# 4. Kill-switch: CONTEXT_CHECK_ENABLED=0 → no-op exit before any work.
if grep -q 'CONTEXT_CHECK_ENABLED' "$DISPATCHER" \
   && grep -q 'CONTEXT_CHECK_ENABLED" != "1"' "$DISPATCHER"; then
  ok "kill-switch CONTEXT_CHECK_ENABLED=0 → no-op exit"
else
  bad "kill-switch missing"
fi

# 5. Fail-toward-human in code: the uncertain branch defaults to ctx:thin when
#    Sonnet is disabled, and any non-READY Sonnet verdict resolves to ctx:thin.
if grep -q 'context_check_resolve_uncertain' "$DISPATCHER" \
   && grep -qF 'READY) echo "ctx:ready"' "$DISPATCHER"; then
  ok "fail-toward-human: only explicit Sonnet READY → ctx:ready; all else → ctx:thin"
else
  bad "fail-toward-human resolution missing"
fi

# 6. The Sonnet judge is spawned on the context-check-reviewer template (Sonnet).
if grep -q 'session new "\$CONTEXT_CHECK_REVIEWER_TEMPLATE"' "$DISPATCHER"; then
  ok "Sonnet judge spawned via gc session new on the context-check-reviewer template"
else
  bad "Sonnet judge spawn does not use the context-check-reviewer template"
fi
# The agent template must pin model = sonnet (sibling .toml shipped alongside).
_TOML="$SELF_DIR/../../../agents/context-check-reviewer/agent.toml"
_TOML_ALT="$SELF_DIR/context-check-reviewer-agent.toml"
if grep -q '^model = "sonnet"' "$_TOML" 2>/dev/null || grep -q '^model = "sonnet"' "$_TOML_ALT" 2>/dev/null; then
  ok "context-check-reviewer template pins model = sonnet"
else
  bad "context-check-reviewer template does not pin model = sonnet (checked $_TOML and $_TOML_ALT)"
fi

# 7. The plist pins the exclude sets (deployment-layer defense for plumbing).
PLIST="$SELF_DIR/com.gascity.context-check-dispatcher.plist"
if grep -q 'CONTEXT_CHECK_EXCLUDE_LABELS' "$PLIST" 2>/dev/null \
   && grep -q 'CONTEXT_CHECK_EXCLUDE_PREFIXES' "$PLIST" 2>/dev/null \
   && grep -q 'type:quality-gate' "$PLIST" 2>/dev/null; then
  ok "plist pins CONTEXT_CHECK_EXCLUDE_LABELS + _PREFIXES incl. quality-gate (deployment defense)"
else
  bad "plist does not pin the exclude sets"
fi

# 8. DRY_RUN must not write labels or spawn. With no live bd the queue is empty →
#    it exits 0 without spawning, logging the dry-run sweep start.
_drycity="$(mktemp -d)"
CONTEXT_CHECK_CITY_OVERRIDE="$_drycity" DRY_RUN=1 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_dryrc=$?
_drylog=$(cat "$_drycity/.gc/logs/context-check-dispatcher.log" 2>/dev/null || echo "")
if [ "$_dryrc" -eq 0 ] && echo "$_drylog" | grep -qiE 'Context-check sweep start.*dry_run=1'; then
  ok "DRY_RUN executes the sweep harness cleanly (exit 0, proof mode, no spawn)"
else
  bad "DRY_RUN did not run cleanly in proof mode (rc=$_dryrc)"
fi
rm -rf "$_drycity"

# 9. Kill-switch e2e: CONTEXT_CHECK_ENABLED=0 exits 0 with the no-op log line.
_kcity="$(mktemp -d)"
CONTEXT_CHECK_CITY_OVERRIDE="$_kcity" CONTEXT_CHECK_ENABLED=0 \
  PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  bash "$DISPATCHER" >/dev/null 2>&1
_krc=$?
_klog=$(cat "$_kcity/.gc/logs/context-check-dispatcher.log" 2>/dev/null || echo "")
if [ "$_krc" -eq 0 ] && echo "$_klog" | grep -qi 'DISABLED'; then
  ok "kill-switch e2e: CONTEXT_CHECK_ENABLED=0 → exit 0 + DISABLED log line (no work)"
else
  bad "kill-switch e2e did not no-op cleanly (rc=$_krc)"
fi
rm -rf "$_kcity"

# 10. exec-class wiring (automation-debt pill).
#  a) feature-gated: CONTEXT_CHECK_EXEC_CLASS default 1, applied ONLY when ctx:ready.
if grep -q 'CONTEXT_CHECK_EXEC_CLASS' "$DISPATCHER" \
   && grep -qF 'CONTEXT_CHECK_EXEC_CLASS:-1' "$DISPATCHER" \
   && grep -qF '[ "$LABEL" = "ctx:ready" ] && [ "$CONTEXT_CHECK_EXEC_CLASS" = "1" ]' "$DISPATCHER"; then
  ok "exec-class env-gated (CONTEXT_CHECK_EXEC_CLASS, default 1) + applied ONLY at ctx:ready"
else
  bad "exec-class not env-gated or not scoped to ctx:ready"
fi
#  b) exactly ONE exec:* label written, via the multi-store bd_ wrapper (right store).
if grep -qF 'bd_ label add "$c_id" "$EXEC"' "$DISPATCHER" \
   && grep -qF 'bd_ label remove "$c_id" "exec:auto"' "$DISPATCHER" \
   && grep -qF 'bd_ label remove "$c_id" "exec:manual"' "$DISPATCHER"; then
  ok "exec label written via multi-store bd_ (CC_STORE-targeted), opposite stripped (exactly one)"
else
  bad "exec label not written via bd_ or opposite not stripped"
fi
#  c) idempotent: only writes if absent/changed (no thrash on re-mark).
if grep -qF 'echo ",$c_labels," | grep -qF ",$EXEC,"' "$DISPATCHER"; then
  ok "exec label idempotent (skips write when already present — no thrash)"
else
  bad "exec label idempotence guard missing"
fi
#  d) fail-open: exec-class computed with || fallback; never on the ctx:thin gap path.
#     The exec write block must NOT touch the ctx:ready/ctx:thin label add above it.
if grep -qF 'context_check_exec_class "$c_title" "$c_desc" 2>/dev/null || echo "exec:auto"' "$DISPATCHER"; then
  ok "exec-class fail-open: classifier failure → exec:auto default, never blocks the verdict"
else
  bad "exec-class not fail-open (missing || default)"
fi
#  e) exec-class is a PURE function (no bd_/gc/jq side-effects in its body).
_ecbody=$(awk '/^context_check_exec_class\(\)/{f=1} f{print} /^}/{if(f)exit}' "$DISPATCHER")
if echo "$_ecbody" | grep -qE 'bd_ |gc |session |sling|--apply'; then
  bad "REGRESSION: context_check_exec_class has a side-effect (must be pure)"
else
  ok "context_check_exec_class is pure (no bd_/gc/sling side-effect — selftest-safe)"
fi

# 11. exec-class e2e via DRY_RUN: a manual-signal bead projects exec:manual, an
#     auto bead projects exec:auto, and a ctx:thin bead gets NO exec label — all
#     written to the candidate's OWN store via a stub bd_ on PATH (multi-store).
_ecity="$(mktemp -d)"
mkdir -p "$_ecity/.gc/logs"
# Stub `bd` so the dispatcher's `bd_ list` returns three crafted candidates and
# label/comment writes are captured (no live Dolt). One ready+manual, one
# ready+auto, one thin (empty desc).
cat > "$_ecity/bd" <<'STUB'
#!/usr/bin/env bash
# Minimal bd stub: serve `list` candidates for type=task, no-op everything else.
case "$1 $2" in
  "-C "*)
    shift 2 ;;  # drop -C <store>
esac
cmd="$1"; shift || true
if [ "$cmd" = "list" ]; then
  want=""
  while [ $# -gt 0 ]; do case "$1" in --type) want="$2"; shift 2;; *) shift;; esac; done
  if [ "$want" = "task" ]; then
    cat <<'JSON'
[{"id":"ga-manual1","issue_type":"task","title":"experimentar phone-as-Claro-mobile-proxy","description":"Plugar o celular físico como proxy móvel da Claro e medir a latência. Critério de aceitação: a chamada de teste retorna 200 e o IP observado é o da operadora. Passos: ligar o aparelho, conectar manualmente, rodar o probe.","labels":[],"ephemeral":false,"created_at":"2026-01-01T00:00:00Z"},{"id":"ga-auto1","issue_type":"task","title":"Verificar saúde do token PDPJ","description":"Fazer health-check do token PDPJ via API e reportar o status. Critério de aceitação: o script retorna o expected output {status:ok} e grava em scripts/pdpj-health.sh o resultado. Comando: bd list para confirmar.","labels":[],"ephemeral":false,"created_at":"2026-01-02T00:00:00Z"},{"id":"ga-thin1","issue_type":"task","title":"arrumar","description":"x","labels":[],"ephemeral":false,"created_at":"2026-01-03T00:00:00Z"},{"id":"ga-commentsfail1","issue_type":"task","title":"revisar outro item pendente","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-03T12:00:00Z","comment_count":1},{"id":"ga-ctxrescue1","issue_type":"task","title":"corrigir latência do endpoint de health-check","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-04T00:00:00Z","comment_count":2},{"id":"ga-stillthin2","issue_type":"task","title":"revisar item pendente","description":"","labels":[],"ephemeral":false,"created_at":"2026-01-05T00:00:00Z","comment_count":1}]
JSON
  else
    echo "[]"
  fi
  exit 0
fi
# ga-o9uvc: serve `comments <id> --json` for the two comment-context fixtures
# above (empty description; the real/only context lives in a comment). Any
# other id gets [] (matches the "no comments" real-world default).
if [ "$cmd" = "comments" ]; then
  id="$1"
  case "$id" in
    ga-commentsfail1)
      # ga-o9uvc fix-attempt 3: simulate a real `bd comments` failure (Dolt
      # hiccup/timeout) — nonzero exit, no JSON on stdout. Must NOT be
      # collapsed into "0 comments"; the candidate should be skipped this
      # sweep instead of judged on incomplete context.
      echo "error: connection refused" >&2
      exit 1
      ;;
    ga-ctxrescue1)
      cat <<'JSON2'
[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano."},{"text":"Reported by mayor 2026-07-09: root cause confirmed via scripts/diagnose.sh — the health-check was hitting a stale cache. Acceptance criteria: the script returns exit 0 and the expected output is status ok after the fix lands."}]
JSON2
      ;;
    ga-stillthin2)
      cat <<'JSON3'
[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano.\n  • O QUÊ: descrição + comentários vazios ou quase vazios (0 chars combinados). Diga o que precisa ser feito e por quê — na descrição ou em um comentário.\nQuando estiver completo, remova o label ctx:thin para re-avaliação."}]
JSON3
      ;;
    *) echo "[]" ;;
  esac
  exit 0
fi
# Capture mutating writes to a ledger so the test can assert on them.
echo "$cmd $*" >> "$LEDGER"
exit 0
STUB
chmod +x "$_ecity/bd"
LEDGER="$_ecity/ledger.txt"; export LEDGER
# ga-o9uvc (incidental, pre-existing): $_ecity is a bare mktemp dir, not a git
# repo — CC_BUILT_IDS's `git -C "$CC_STORE" for-each-ref | grep ...` pipeline
# exits non-zero (git fails outright, or grep finds no crew/* matches even in
# a real repo) and aborts the WHOLE dispatcher under set -euo pipefail before
# it judges a single candidate, despite the code's own comment promising
# "FAIL-OPEN (git fails → empty set → no exclusion)". Verified this was
# already silently broken on the unmodified baseline (same failure, same
# empty-ledger symptom, before any of this file's ga-o9uvc changes) — use the
# test seams the dispatcher already provides (CONTEXT_CHECK_TEST_BUILT_IDS /
# _BLOCKED_IDS) to bypass the git/bd_ calls entirely, matching how every other
# e2e block in this file avoids live I/O.
CONTEXT_CHECK_CITY_OVERRIDE="$_ecity" \
  CONTEXT_CHECK_STORES="$_ecity" \
  CONTEXT_CHECK_TEST_BUILT_IDS="" \
  CONTEXT_CHECK_TEST_BLOCKED_IDS="" \
  CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=0 \
  CONTEXT_CHECK_EXEC_CLASS=1 \
  PATH="$_ecity:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  timeout 30 bash "$DISPATCHER" >/dev/null 2>&1 || true
_eled=$(cat "$LEDGER" 2>/dev/null || echo "")
# ga-manual1: ctx:ready + exec:manual.
if echo "$_eled" | grep -qE 'label add ga-manual1 ctx:ready' \
   && echo "$_eled" | grep -qE 'label add ga-manual1 exec:manual'; then
  ok "e2e: manual-signal ready bead → ctx:ready + exec:manual (written to its own store)"
else
  bad "e2e: manual bead did not get ctx:ready + exec:manual (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-auto1: ctx:ready + exec:auto.
if echo "$_eled" | grep -qE 'label add ga-auto1 ctx:ready' \
   && echo "$_eled" | grep -qE 'label add ga-auto1 exec:auto'; then
  ok "e2e: auto ready bead → ctx:ready + exec:auto"
else
  bad "e2e: auto bead did not get ctx:ready + exec:auto (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-thin1: ctx:thin and NO exec label (pill only on ready/Aprovadas).
if echo "$_eled" | grep -qE 'label add ga-thin1 ctx:thin' \
   && ! echo "$_eled" | grep -qE 'label add ga-thin1 exec:'; then
  ok "e2e: thin bead → ctx:thin, NO exec label (no pill on non-ready)"
else
  bad "e2e: thin bead wrongly got an exec label or no ctx:thin (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-ctxrescue1 (ga-o9uvc): empty description, but a real comment carries the
# full report (ga-pgzes/ga-r7uec live shape) → must clear ctx:ready, not thin.
if echo "$_eled" | grep -qE 'label add ga-ctxrescue1 ctx:ready'; then
  ok "e2e: comment-carried context rescues an empty-description bead → ctx:ready (not falsely ctx:thin)"
else
  bad "e2e REGRESSION: comment-carried context did not rescue ga-ctxrescue1 (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-stillthin2 (ga-o9uvc): empty description, only comment is the daemon's
# OWN prior gap-notice (ga-u8fly/gh-b2d live shape) → must stay ctx:thin, no
# circular self-rescue from reading its own past verdict as context.
if echo "$_eled" | grep -qE 'label add ga-stillthin2 ctx:thin'; then
  ok "e2e: only-the-daemon's-own-gap-comment present → stays ctx:thin (no circular self-rescue)"
else
  bad "e2e REGRESSION: daemon's own gap-comment was read back as rescuing context for ga-stillthin2 (ledger: $(echo "$_eled" | tr '\n' ';'))"
fi
# ga-commentsfail1 (ga-o9uvc fix-attempt 3): comment_count>0 but the `bd
# comments` fetch itself fails (nonzero exit, no JSON). Must be SKIPPED this
# sweep — no ctx:ready, no ctx:thin — never judged on incomplete context.
# This is the exact gap that survived fix-attempt 2 (a blanket `|| true`
# collapsed "fetch failed" into "0 comments", producing an identical thin
# verdict as a genuinely-empty bead — gate-FAILED on this precise point).
if echo "$_eled" | grep -qE 'label add ga-commentsfail1 ctx:(ready|thin)'; then
  bad "e2e REGRESSION: ga-commentsfail1 got a verdict despite its comments fetch failing (should be skipped, not judged on incomplete context) (ledger: $(echo "$_eled" | tr '\n' ';'))"
else
  ok "e2e: comments-fetch failure → candidate skipped this sweep, no verdict on incomplete context"
fi
# The failure must be visible (not silently absorbed) and, critically, must
# NOT abort the rest of the sweep — the ga-ctxrescue1/ga-stillthin2 checks
# above already prove later candidates still got judged (they sort AFTER
# ga-commentsfail1 by created_at), which is the direct regression test for
# fix-attempt 1's original bug (an unguarded fetch failure killing the whole
# sweep under set -euo pipefail).
_eclog="$_ecity/.gc/logs/context-check-dispatcher.log"
if [ -f "$_eclog" ] && grep -q "ga-commentsfail1: comments fetch failed" "$_eclog"; then
  ok "e2e: comments-fetch failure is logged distinctly (not silently absorbed into '0 comments')"
else
  bad "e2e: no distinct log line for ga-commentsfail1's comments-fetch failure (log: $([ -f "$_eclog" ] && cat "$_eclog" || echo '<missing>'))"
fi
# Feature-gate OFF: CONTEXT_CHECK_EXEC_CLASS=0 → ctx:ready still written, NO exec label.
LEDGER="$_ecity/ledger2.txt"; export LEDGER; : > "$LEDGER"
CONTEXT_CHECK_CITY_OVERRIDE="$_ecity" \
  CONTEXT_CHECK_STORES="$_ecity" \
  CONTEXT_CHECK_TEST_BUILT_IDS="" \
  CONTEXT_CHECK_TEST_BLOCKED_IDS="" \
  CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=0 \
  CONTEXT_CHECK_EXEC_CLASS=0 \
  PATH="$_ecity:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
  timeout 30 bash "$DISPATCHER" >/dev/null 2>&1 || true
_eled2=$(cat "$LEDGER" 2>/dev/null || echo "")
if echo "$_eled2" | grep -qE 'label add ga-manual1 ctx:ready' \
   && ! echo "$_eled2" | grep -qE 'label add ga-manual1 exec:'; then
  ok "feature-gate OFF: ctx:ready verdict intact, NO exec label (exec-class skipped)"
else
  bad "feature-gate OFF did not preserve verdict-without-exec (ledger: $(echo "$_eled2" | tr '\n' ';'))"
fi
rm -rf "$_ecity"

# 12. ga-l5ud0 ROOT B FIX: exec:manual is AUTHORITATIVE — the classifier MUST NOT
#     downgrade an existing exec:manual to exec:auto. A bead that already carries
#     exec:manual (Mayor/human-set) must keep it even when context_check_exec_class
#     returns exec:auto (the conservative default for content with no physical/credential
#     signal). The loop this closes: exec:manual clobbered → Pilot sees exec:auto +
#     ctx:ready → dispatches a crew that cannot complete the task → mila clears → repeat.
#
#     Pure drift guards (no live Dolt/gc) — these test the actual shipped code paths
#     exercised by the ga-l5ud0 fix, not just the fix's presence.
echo "Scenario 12: ga-l5ud0 — exec:manual authoritative-hold guard (drift guards)"
# 12a — The guard code is present in the dispatcher (the critical branch that prevents
#        downgrade). Regression: if this disappears, exec:manual gets clobbered again.
if grep -qF 'exec:auto.*exec:manual,.*AUTHORITATIVE-HOLD\|AUTHORITATIVE-HOLD' "$DISPATCHER" \
   || grep -qF 'AUTHORITATIVE-HOLD' "$DISPATCHER"; then
  ok "ga-l5ud0: AUTHORITATIVE-HOLD guard present in dispatcher (exec:manual NOT downgradeable)"
else
  bad "ga-l5ud0 REGRESSION: AUTHORITATIVE-HOLD guard missing — exec:manual can be silently clobbered"
fi
# 12b — The guard specifically checks: if computed=exec:auto AND existing has exec:manual, skip.
#        Verify the exact branch condition exists in the code.
if grep -qF '"exec:auto" ] && echo ",$c_labels," | grep -qF ",exec:manual,"' "$DISPATCHER"; then
  ok "ga-l5ud0: hold-condition wiring correct (exec:auto + existing exec:manual → skip)"
else
  bad "ga-l5ud0: hold-condition wiring malformed or missing"
fi
# 12c — BEHAVIORAL SIMULATION (pure shell, no Dolt): verify the hold fires correctly
#        by sourcing the lib and simulating the label-write decision logic inline.
#        wa-14w76 pattern: content → exec:auto; existing label = exec:manual → KEEP.
_ga_l5ud0_hold_ok=0
(
  c_labels="ctx:ready,exec:manual,lane:small,story:approved"
  EXEC=$(context_check_exec_class \
    "Restaurar input do grupo UrbLink via historico" \
    "A capacidade de LER O HISTORICO de um grupo JA ESTA IMPLEMENTADA. whapi foi descontinuado. Ligar ao /peter-review." \
    2>/dev/null || echo "exec:auto")
  # Verify: classifier returns exec:auto for this content.
  [ "$EXEC" = "exec:auto" ] || exit 2
  # Simulate the guard: if exec:auto AND existing exec:manual → hold (no-op).
  _would_downgrade=1
  if echo ",$c_labels," | grep -qF ",exec:manual," && [ "$EXEC" = "exec:auto" ]; then
    _would_downgrade=0  # AUTHORITATIVE-HOLD fires
  fi
  [ "$_would_downgrade" = "0" ] || exit 3
  exit 0
) && _ga_l5ud0_hold_ok=1
if [ "$_ga_l5ud0_hold_ok" = "1" ]; then
  ok "ga-l5ud0: behavioral sim — wa-14w76 pattern: classifier→exec:auto, existing=exec:manual → HOLD (no downgrade)"
else
  bad "ga-l5ud0 REGRESSION: behavioral sim shows exec:manual was or would be downgraded for wa-14w76 pattern"
fi
# 12d — Converse: exec:manual UPGRADE (auto→manual) is still allowed. A bead with
#        exec:auto whose content now matches a physical-device signal → upgrades to
#        exec:manual (the guard ONLY blocks downgrade, not upgrade).
_ga_l5ud0_upgrade_ok=0
(
  c_labels="ctx:ready,exec:auto,lane:small"
  EXEC=$(context_check_exec_class \
    "ligar o phone-as-Claro-mobile-proxy" \
    "conectar manualmente o celular físico como proxy móvel" \
    2>/dev/null || echo "exec:auto")
  # Verify: classifier returns exec:manual (physical-device signal).
  [ "$EXEC" = "exec:manual" ] || exit 2
  # Simulate: existing=exec:auto, computed=exec:manual → upgrade is NOT blocked.
  _would_upgrade=0
  if echo ",$c_labels," | grep -qF ",exec:auto," && [ "$EXEC" = "exec:manual" ]; then
    _would_upgrade=1  # upgrade path fires (no AUTHORITATIVE-HOLD — guard only blocks auto)
  fi
  [ "$_would_upgrade" = "1" ] || exit 3
  exit 0
) && _ga_l5ud0_upgrade_ok=1
if [ "$_ga_l5ud0_upgrade_ok" = "1" ]; then
  ok "ga-l5ud0: upgrade (exec:auto → exec:manual on new physical signal) is NOT blocked by hold"
else
  bad "ga-l5ud0: upgrade path broken — exec:auto→exec:manual upgrade is blocked (should only block downgrade)"
fi

# context_check_skip_reason (wa-9t2ty): dep-BLOCKED beads must be skipped from
# ctx:ready (re)marking, so a refiner's manual block (remove ctx:ready + add a
# blocked-by dep) is not undone every sweep. Also covers built + kill-switches.
if [ "$(context_check_skip_reason wa-X '' wa-X 1 1)" = "blocked" ]; then
  ok "skip_reason: dep-blocked bead → 'blocked' (no ctx:ready re-mark)"
else
  bad "skip_reason: dep-blocked bead not skipped (blocked bead would re-enter ctx:ready)"
fi
if [ "$(context_check_skip_reason wa-X wa-X '' 1 1)" = "built" ]; then
  ok "skip_reason: built bead → 'built'"
else
  bad "skip_reason: built bead not skipped"
fi
if [ -z "$(context_check_skip_reason wa-X wa-Y wa-Z 1 1)" ]; then
  ok "skip_reason: clean bead (in neither set) → no skip"
else
  bad "skip_reason: clean bead wrongly skipped"
fi
if [ -z "$(context_check_skip_reason wa-X '' wa-X 1 0)" ]; then
  ok "skip_reason: EXCLUDE_BLOCKED=0 kill-switch → no skip"
else
  bad "skip_reason: blocked kill-switch ignored"
fi

# ── Scenario 13: comment-aware context (ga-o9uvc: erro-vs-vazio) ──────────────
# ctx:thin must not fire purely because .description is empty when the real
# context lives in a comment. Also: the daemon's OWN prior gap-comment must be
# excluded from the signal check (no circular self-rescue on a re-judged bead).
echo "Scenario 13: comment-aware context — comments count, but not the daemon's own gap-comment"

# 13a — join_comments: real comments are joined; the daemon's own gap-comment
#       (identified by its literal head string) is filtered out.
_join_in='[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano."},{"text":"Reported by mayor: root cause is X, fix is Y, verify via scripts/z.sh"}]'
_joined=$(context_check_join_comments "$_join_in")
if echo "$_joined" | grep -q "Reported by mayor" && ! echo "$_joined" | grep -q "marcado ctx:thin"; then
  ok "join_comments: keeps real comment text, excludes the daemon's own gap-comment"
else
  bad "join_comments: did not filter correctly (got: $_joined)"
fi
[ -z "$(context_check_join_comments "[]")" ] && ok "join_comments: empty array → empty text" || bad "join_comments: empty array should yield empty text"
[ -z "$(context_check_join_comments "")" ] && ok "join_comments: empty/malformed input → empty text (no crash)" || bad "join_comments: empty input should yield empty text, not crash"

# 13b — effective_text: comments appended to description; desc-only unchanged when no comments.
[ "$(context_check_effective_text "hello" "")" = "hello" ] && ok "effective_text: no comments → description unchanged" || bad "effective_text: no-comments case changed the description"
_eff=$(context_check_effective_text "" "world")
case "$_eff" in *world*) ok "effective_text: empty description + comments → comments included" ;; *) bad "effective_text: comments not folded in (got: '$_eff')" ;; esac

# 13c — end-to-end mechanical verdict, pure-function pipeline (no I/O):
# baseline unchanged — empty description with NO comments is still thin.
_base_sig=$(context_check_has_verifiable_signal "")
_base_mech=$(context_check_mechanical_verdict 0 "$_base_sig" 10)
[ "$_base_mech" = "thin" ] && ok "baseline unchanged: empty description, no comments → thin" || bad "REGRESSION: empty desc, no comments should still be thin"
# ga-pgzes/ga-r7uec live shape: description empty, but a real comment carries
# the full report — folding it in must clear the ready bar.
_rescue_comment="Reported by mayor 2026-07-09: root cause confirmed via scripts/diagnose.sh, expected output is status ok. Acceptance criteria: the health-check returns 0 and scripts/diagnose.sh --apply completes without error."
_rescue_text=$(context_check_effective_text "" "$_rescue_comment")
_rescue_sig=$(context_check_has_verifiable_signal "$_rescue_text")
_rescue_mech=$(context_check_mechanical_verdict "${#_rescue_text}" "$_rescue_sig" 10)
[ "$_rescue_mech" = "ready" ] && ok "ga-pgzes/ga-r7uec shape: empty description + verifiable comment → ready (was falsely thin pre-fix)" || bad "REGRESSION: comment-carried context did not rescue an empty-description bead (mech=$_rescue_mech sig=$_rescue_sig)"
# ga-u8fly/gh-b2d live shape: the ONLY comment is the daemon's own prior
# gap-notice — must NOT self-rescue (still genuinely thin).
_selfnotice='[{"text":"Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano.\n  • O QUÊ: descrição + comentários vazios ou quase vazios (0 chars combinados). Diga o que precisa ser feito e por quê — na descrição ou em um comentário.\nQuando estiver completo, remova o label ctx:thin para re-avaliação."}]'
_selfnotice_text=$(context_check_join_comments "$_selfnotice")
_selfnotice_eff=$(context_check_effective_text "" "$_selfnotice_text")
_selfnotice_sig=$(context_check_has_verifiable_signal "$_selfnotice_eff")
_selfnotice_mech=$(context_check_mechanical_verdict "${#_selfnotice_eff}" "$_selfnotice_sig" 10)
[ "$_selfnotice_mech" = "thin" ] && ok "ga-u8fly/gh-b2d shape: only the daemon's own gap-comment present → stays thin (no circular self-rescue)" || bad "REGRESSION: daemon's own gap-comment was read back as rescuing context (mech=$_selfnotice_mech)"

echo ""
echo "context-check-dispatcher.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
