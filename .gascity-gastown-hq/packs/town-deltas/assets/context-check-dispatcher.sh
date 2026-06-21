#!/usr/bin/env bash
# context-check-dispatcher.sh — Creation-Gate Context-Check daemon ("Option D").
#
# THE CORE OF THE CREATION GATE. Where the Pilot's empty-description veto
# (DEPLOYED, empty-only) rejects beads with NO description at dispatch time, THIS
# daemon judges context-COMPLETENESS for every actionable bead and writes a
# POSITIVE verdict label so thin beads are VISIBLE and HELD — moving Gas City
# toward ~100% auto-dispatchable. It runs UPSTREAM of dispatch and only LABELS;
# it changes NO dispatch behaviour (the later phase wires ctx:ready→dispatchable).
#
# Runs every ~10 min via launchd (com.gascity.context-check-dispatcher.plist).
#
#   open bug/chore/task/debt (+ feature w/o story:*)        ← THIS DAEMON's INPUT
#     │  no ctx:* label yet; not plumbing; not in-flight/done/gate-stuck
#     ▼  judge: does a GENERIC agent have enough to build it WITHOUT a human?
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │  3-field rubric:  WHAT  ·  HOW-TO-VERIFY  ·  SCOPE                     │
#   └──────────────────────────────────────────────────────────────────────┘
#     ├─ MECHANICALLY complete (no product decision) ──► ctx:ready  (positive)
#     ├─ MECHANICALLY thin (empty / near-empty / vague) ─► ctx:thin + gap comment
#     └─ UNCERTAIN (terse but maybe complete) ──► tiny Sonnet check
#                                                   PASS → ctx:ready
#                                                   FAIL → ctx:thin + gap comment
#
# WHY A POSITIVE LABEL (adversarial review): the verdict must be set BY A REVIEWER
# (heuristic or Sonnet), NOT inferred from byte-count. A terse-but-complete bead
# ("rename notify wrapper so it stops shadowing the external notify CLI", with a
# clear verifiable outcome) must NOT be falsely flagged thin. So the heuristic
# only ever self-sets ctx:ready on UNAMBIGUOUS mechanical completeness; the
# ambiguous middle band is escalated to a cheap Sonnet judge. When neither can
# tell, the daemon defaults to ctx:thin — FAIL TOWARD "needs human", never
# falsely "ready".
#
# DESIGN INVARIANTS:
#   - LABEL-ONLY. Never dispatches, never slings, never closes, never changes a
#     bead's lifecycle. The ONLY writes are: add ctx:ready | add ctx:thin + a
#     gap comment. (Drift-guarded.)
#   - IDEMPOTENT. A bead that already carries ctx:ready or ctx:thin is excluded at
#     the query AND re-asserted by the pure classifier — re-judged only if a human
#     strips the label (re-judging a fresh bead is safe and cheap).
#   - ga-it11w LESSON: a terminal ctx:thin bead must NOT loop. ctx:thin is itself
#     the exclusion key (a thin bead already has a ctx:* label → never re-ingested),
#     so there is no re-ingestion loop. ctx:thin is NOT stripped by this daemon.
#   - ANTI-DOLT-SPIKE: cap beads-judged-per-sweep (CONTEXT_CHECK_MAX_PER_SWEEP),
#     and at most ONE Sonnet spawn per sweep (the heuristic resolves the majority).
#   - DRY_RUN=1 → no label writes / no spawn; logs "WOULD …" + a ready/thin tally.
#   - KILL-SWITCH: CONTEXT_CHECK_ENABLED=0 → exit 0 immediately (no work).
#   - DRAIN-SAFE: this file + its plist + the context-check-reviewer template are
#     the ONLY artifacts. Touches no other daemon, city.toml, or skill.
#
# Usage:
#   bash context-check-dispatcher.sh            # normal run
#   DRY_RUN=1 bash context-check-dispatcher.sh  # dry-run (proof mode + projection)

set -euo pipefail

GC_CITY="${CONTEXT_CHECK_CITY_OVERRIDE:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/context-check-dispatcher.log"
CC_LOG="$GC_CITY/.gc/context-check.jsonl"

# ── Identity ──────────────────────────────────────────────────────────────────
CONTEXT_CHECK_ACTOR="${CONTEXT_CHECK_ACTOR:-context-check}"

# ── Kill-switch ────────────────────────────────────────────────────────────────
# 1 = run (default). 0 = no-op exit (the Mayor's instant brake without unloading).
CONTEXT_CHECK_ENABLED="${CONTEXT_CHECK_ENABLED:-1}"

# ── Tunables (env-overridable for the selftest) ────────────────────────────────
# Max beads judged per sweep (Dolt-load cap; the launchd interval drains the rest).
CONTEXT_CHECK_MAX_PER_SWEEP="${CONTEXT_CHECK_MAX_PER_SWEEP:-8}"
case "$CONTEXT_CHECK_MAX_PER_SWEEP" in ''|*[!0-9]*) CONTEXT_CHECK_MAX_PER_SWEEP=8 ;; esac
# Max Sonnet reviewer spawns per sweep (the heuristic resolves the majority; the
# Sonnet judge is reserved for the ambiguous middle band). 0 = heuristic-only mode
# (never spawn; ambiguous beads default to ctx:thin — cheapest, fully autonomous).
CONTEXT_CHECK_MAX_SONNET_PER_SWEEP="${CONTEXT_CHECK_MAX_SONNET_PER_SWEEP:-1}"
case "$CONTEXT_CHECK_MAX_SONNET_PER_SWEEP" in ''|*[!0-9]*) CONTEXT_CHECK_MAX_SONNET_PER_SWEEP=1 ;; esac
# Wall-clock minutes to wait for a Sonnet verdict before timing out (→ ctx:thin,
# fail-toward-human). Floor 8m.
CONTEXT_CHECK_VERDICT_TIMEOUT_MINUTES="${CONTEXT_CHECK_VERDICT_TIMEOUT_MINUTES:-12}"
if [ "$CONTEXT_CHECK_VERDICT_TIMEOUT_MINUTES" -lt 8 ] 2>/dev/null; then
  CONTEXT_CHECK_VERDICT_TIMEOUT_MINUTES=8
fi
CONTEXT_CHECK_VERDICT_POLL_INTERVAL="${CONTEXT_CHECK_VERDICT_POLL_INTERVAL:-30}"
# Sonnet reviewer template (model = Sonnet; see agents/context-check-reviewer/agent.toml).
CONTEXT_CHECK_REVIEWER_TEMPLATE="${CONTEXT_CHECK_REVIEWER_TEMPLATE:-context-check-reviewer}"

# Heuristic thresholds (env-overridable). These gate the MECHANICAL verdict; the
# ambiguous band between them is what the Sonnet judge (or, if disabled, the
# fail-toward-thin default) resolves.
#   - A description shorter than MIN is mechanically thin (near-empty).
#   - A description with a verifiable-criterion signal AND length >= READY_MIN is
#     mechanically ready.
CONTEXT_CHECK_THIN_MAXLEN="${CONTEXT_CHECK_THIN_MAXLEN:-40}"
case "$CONTEXT_CHECK_THIN_MAXLEN" in ''|*[!0-9]*) CONTEXT_CHECK_THIN_MAXLEN=40 ;; esac
CONTEXT_CHECK_READY_MINLEN="${CONTEXT_CHECK_READY_MINLEN:-120}"
case "$CONTEXT_CHECK_READY_MINLEN" in ''|*[!0-9]*) CONTEXT_CHECK_READY_MINLEN=120 ;; esac

# ── exec-class (automation-debt) feature gate ──────────────────────────────────
# 1 = when a bead is judged ctx:ready, ALSO classify exec:manual vs exec:auto and
# apply exactly one of those labels (feeds the painel "Aprovadas" pill + Athos's
# 100%-autonomy goal; bead wa-u5r1). 0 = skip exec-class entirely (ctx:ready/thin
# verdict is untouched). Fail-OPEN: a classification failure NEVER blocks the
# readiness verdict. Default ON.
CONTEXT_CHECK_EXEC_CLASS="${CONTEXT_CHECK_EXEC_CLASS:-1}"

# Labels that mark a bead as PLUMBING / engine-internal coordination — NOT human
# work to be context-checked. A candidate carrying ANY of these is excluded even
# if its type is bug/chore/task. Mirrors the painel's _is_automation_bead set plus
# the quality-gate marker/run/verdict family that pollutes the open chore/task
# population. Env-overridable so the Mayor can tune without a code edit.
CONTEXT_CHECK_EXCLUDE_LABELS="${CONTEXT_CHECK_EXCLUDE_LABELS:-gt:agent gt:rig gt:convoy gc:nudge}"
# Label PREFIXES that mark plumbing (matched as startswith). Covers the gate
# marker/run/verdict family, gate-status:*, nudge:*, reviewer-index:*, source:*,
# and the ctx:* family itself (idempotence).
CONTEXT_CHECK_EXCLUDE_PREFIXES="${CONTEXT_CHECK_EXCLUDE_PREFIXES:-type:quality-gate gate-status: nudge: reviewer-index: verdict: refino-gate: auto-refino: gate-reclaim-count: order-run: ctx:}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { echo "[$(ts)] $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] $*"; }
warn() { echo "[$(ts)] WARN: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] WARN: $*"; }
err()  { echo "[$(ts)] ERROR: $*" | tee -a "$LOG" >/dev/null 2>&1 || echo "[$(ts)] ERROR: $*"; }

DRY_RUN="${DRY_RUN:-0}"

# ── PURE DECISION CORE (unit-tested by context-check-dispatcher.selftest.sh) ───
# Side-effect-free: they take a bead's type/labels/id/description and emit a single
# token. The selftest drives them directly and the dispatcher body calls them, so
# the tested logic IS the shipped logic (no parallel reimplementation).

# context_check_type_eligible <issue_type> — emit "yes" iff a context-checkable
#   actionable work type: bug / chore / task / debt. (feature is handled by the
#   feature-without-story:* path, judged the same once selected — see
#   context_check_is_candidate.) epic / decision / molecule / gate / convoy / etc.
#   are NEVER context-checked here.
context_check_type_eligible() {
  case "$1" in
    bug|chore|task|debt) echo "yes" ;;
    feature) echo "yes" ;;
    *) echo "no" ;;
  esac
}

# context_check_label_is_excluded <label> — emit "yes" iff this single label is a
#   plumbing/exclusion label (exact match in EXCLUDE_LABELS or prefix match in
#   EXCLUDE_PREFIXES). Pure; reads the two exclude env vars.
context_check_label_is_excluded() {
  local lbl="$1" e p
  for e in $CONTEXT_CHECK_EXCLUDE_LABELS; do
    [ -z "$e" ] && continue
    [ "$lbl" = "$e" ] && { echo "yes"; return; }
  done
  for p in $CONTEXT_CHECK_EXCLUDE_PREFIXES; do
    [ -z "$p" ] && continue
    case "$lbl" in "$p"*) echo "yes"; return ;; esac
  done
  echo "no"
}

# context_check_has_ctx_label <labels_csv> — emit "yes" iff the bead already
#   carries ANY ctx:* label (ctx:ready / ctx:thin / future ctx:*). IDEMPOTENCE +
#   the ga-it11w anti-loop key: a bead with a verdict is never re-judged.
context_check_has_ctx_label() {
  local l IFS=,
  for l in $1; do
    case "$l" in ctx:*) echo "yes"; return ;; esac
  done
  echo "no"
}

# context_check_is_plumbing <id> <labels_csv> <ephemeral true|false>
#   emit "yes" iff this bead is engine-internal plumbing (NOT human work):
#   ephemeral, dc-/-wisp-/convoy-/nudge- id, OR any excluded label/prefix.
#   Mirrors the painel's _is_automation_bead, extended with the gate/ctx families.
context_check_is_plumbing() {
  local id="$1" labels="$2" ephemeral="$3" l
  [ "$ephemeral" = "true" ] && { echo "yes"; return; }
  case "$id" in
    dc-*|convoy-*|nudge-*) echo "yes"; return ;;
  esac
  case "$id" in *-wisp-*) echo "yes"; return ;; esac
  # Split the CSV on commas WITHOUT leaking IFS into the callee: a leaked IFS=,
  # would break context_check_label_is_excluded's space-separated `for e in $...`
  # word-split. Use a subshell-local IFS via `read -ra` instead.
  [ -z "$labels" ] && { echo "no"; return; }
  local -a _lbls=()
  IFS=',' read -ra _lbls <<< "$labels"
  for l in "${_lbls[@]+"${_lbls[@]}"}"; do
    [ -z "$l" ] && continue
    [ "$(context_check_label_is_excluded "$l")" = "yes" ] && { echo "yes"; return; }
  done
  echo "no"
}

# context_check_lifecycle_skip <labels_csv>
#   emit "yes" iff the bead is in a state where a context verdict is pointless /
#   harmful: already in-flight, done, cancelled, gate-stuck, or pilot-dispatched.
#   These are excluded so the daemon never re-labels work already moving (or
#   already escalated to a human via the gate). Pure.
context_check_lifecycle_skip() {
  local csv=",$1,"
  case "$csv" in
    *,story:in-flight,*|*,story:done,*|*,story:cancelled,*|\
*,pilot:dispatched,*|*,gate:needs-human,*|*,gate:needs-fix,*|\
*,gate:failed,*|*,gate:in-progress,*)
      echo "yes"; return ;;
  esac
  echo "no"
}

# context_check_is_candidate <id> <issue_type> <labels_csv> <ephemeral> <has_story_lifecycle yes|no>
#   The master per-bead gate. emit "yes" iff this bead should be context-judged:
#     - type-eligible (bug/chore/task/debt, OR feature WITHOUT a story:* label);
#     - NOT plumbing;
#     - NOT already carrying a ctx:* verdict (idempotence / anti-loop);
#     - NOT in a lifecycle-skip state (in-flight/done/gate-stuck/dispatched).
#   <has_story_lifecycle> is the caller's precomputed answer to "does it carry any
#   story:* label" (a feature WITH a story:* label is in the refino funnel — leave
#   it; only feature WITHOUT story:* is a raw actionable item we judge).
context_check_is_candidate() {
  local id="$1" itype="$2" labels="$3" ephemeral="$4" has_story="$5"
  [ "$(context_check_type_eligible "$itype")" = "yes" ] || { echo "no"; return; }
  # A feature in the refino funnel (carries a story:* label) is NOT ours.
  if [ "$itype" = "feature" ] && [ "$has_story" = "yes" ]; then echo "no"; return; fi
  [ "$(context_check_is_plumbing "$id" "$labels" "$ephemeral")" = "no" ] || { echo "no"; return; }
  [ "$(context_check_has_ctx_label "$labels")" = "no" ] || { echo "no"; return; }
  [ "$(context_check_lifecycle_skip "$labels")" = "no" ] || { echo "no"; return; }
  echo "yes"
}

# context_check_has_verifiable_signal <text> — emit "yes" iff the description
#   carries a HOW-TO-VERIFY / concrete-artifact signal: an acceptance-criteria
#   marker, a checklist, a named file/path/command, an expected/observable
#   outcome, or an error/repro signature. Case-insensitive. Pure (no I/O).
#   This is a SIGNAL, not a verdict — it feeds the mechanical classifier, which
#   combines it with length to decide ready / thin / uncertain.
context_check_has_verifiable_signal() {
  local t
  t=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  # acceptance/verification + observable-outcome vocabulary (en + pt). No comments
  # inside the alternation: bash forbids a comment line between `\`-joined patterns.
  case "$t" in
    *"accept"*|*"criteri"*|*"critério"*|*"criterio"*|*"verif"*|\
*"expected"*|*"esperado"*|*"should "*|*"deve "*|*"so that"*|*"para que"*|\
*"reproduce"*|*"repro:"*|*"steps to"*|*"passos"*|\
*"done when"*|*"pronto quando"*|*"resultado"*|*"output"*|*"returns"*|*"retorna"*)
      echo "yes"; return ;;
  esac
  # Checklist / bullet markers (markdown task lists or dash bullets on their own
  # lines) signal an enumerated, checkable spec.
  case "$1" in
    *"- ["*|*"* ["*) echo "yes"; return ;;          # - [ ] / * [ ] task list
  esac
  # A named concrete artifact: a file path or a code identifier with an extension,
  # or a fenced/inline command. These let a generic agent locate the work.
  case "$1" in
    *.sh*|*.py*|*.go*|*.js*|*.ts*|*.json*|*.toml*|*.yaml*|*.yml*|*.md*|*"/"*"."*|\
*'`'*|*'$('*|*"bd "*|*"gc "*|*"git "*|*"launchctl"*)
      echo "yes"; return ;;
  esac
  echo "no"
}

# context_check_mechanical_verdict <desc_len> <has_signal yes|no> <title_len>
#   emit one of: ready | thin | uncertain. The MECHANICAL judge (no LLM):
#     thin       — description shorter than THIN_MAXLEN (near-empty / one-liner
#                  with no spec) → a generic agent cannot build it. ALSO thin if
#                  there is no verifiable signal at all AND the description is not
#                  long enough to plausibly carry an implicit spec.
#     ready      — has a verifiable signal AND description >= READY_MINLEN: a
#                  generic agent has a what + a how-to-verify. Self-set ONLY here
#                  (unambiguous mechanical completeness, no product decision).
#     uncertain  — everything in between (terse-but-maybe-complete): hand to the
#                  Sonnet judge, or — if Sonnet is disabled/budget-spent — default
#                  to thin (fail toward human, never falsely ready).
#   GUARANTEE: the only path to "ready" requires BOTH a verifiable signal AND
#   sufficient length — a bare byte-count can never yield ready, and a long but
#   signal-less ramble is uncertain (Sonnet-judged), never auto-ready.
context_check_mechanical_verdict() {
  local dlen="$1" sig="$2" tlen="${3:-0}"
  case "$dlen" in ''|*[!0-9]*) dlen=0 ;; esac
  case "$tlen" in ''|*[!0-9]*) tlen=0 ;; esac
  # Near-empty description → thin regardless of signal.
  if [ "$dlen" -lt "$CONTEXT_CHECK_THIN_MAXLEN" ]; then echo "thin"; return; fi
  # Has a verifiable signal AND enough body → mechanically ready.
  if [ "$sig" = "yes" ] && [ "$dlen" -ge "$CONTEXT_CHECK_READY_MINLEN" ]; then
    echo "ready"; return
  fi
  # Described but no verifiable signal at all, and not long enough to plausibly
  # carry an implicit spec → lean thin (still below the Sonnet band).
  if [ "$sig" = "no" ] && [ "$dlen" -lt "$CONTEXT_CHECK_READY_MINLEN" ]; then
    echo "thin"; return
  fi
  # Terse-but-maybe-complete (signal present but short, OR long but signal-less):
  # the ambiguous middle band → Sonnet (or fail-toward-thin if disabled).
  echo "uncertain"
}

# context_check_resolve_uncertain <sonnet_verdict READY|THIN|TIMEOUT|"">
#   Map a Sonnet verdict (or its absence) onto the final label token. Anything
#   that is not an explicit READY becomes thin — fail toward "needs human".
context_check_resolve_uncertain() {
  case "$1" in
    READY) echo "ctx:ready" ;;
    *) echo "ctx:thin" ;;   # THIN, TIMEOUT, empty, garbage → thin
  esac
}

# context_check_verdict_label <mechanical> <sonnet_verdict>
#   The single final-label function the dispatcher calls. mechanical is one of
#   ready/thin/uncertain; sonnet_verdict only consulted when mechanical=uncertain.
#   emit ctx:ready | ctx:thin. GUARANTEE: the only two possible outputs are
#   ctx:ready and ctx:thin — never a dispatch/approve/lifecycle token.
context_check_verdict_label() {
  local mech="$1" sonnet="${2:-}"
  case "$mech" in
    ready) echo "ctx:ready" ;;
    thin)  echo "ctx:thin" ;;
    uncertain|*) context_check_resolve_uncertain "$sonnet" ;;
  esac
}

# ── EXEC-CLASS (automation-debt) classifier ───────────────────────────────────
# Applied ONLY to a bead that has just been judged ctx:ready. Answers: can a crew
# agent fully execute this WITHOUT a human/physical action, or does it need a
# real-world/human-only step an autonomous agent CANNOT perform?
#
#   exec:manual — the task needs a physical device or a human-held identity/
#     credential an agent cannot supply: plug in a phone/SIM/hardware/physical
#     proxy; log into a government / 3rd-party portal gated by human identity
#     (CPF + CAPTCHA, e-SIC/LAI, cartório); provision a credential/account/channel
#     a human must hold. This set = VISIBLE automation-debt to eliminate (Athos's
#     bead wa-u5r1: drive the system to 100% autonomy).
#   exec:auto  — a crew agent can do it end-to-end: write/run code, run a script
#     or command (--apply), a health-check/verification, a data task, an API- or
#     email-based request. THE DEFAULT.
#
# DESIGN: conservative — default exec:auto (optimistic; let a crew TRY; if it hits
# a real human/physical blocker it reports an automation-gap). Only an UNAMBIGUOUS
# physical / human-credential signal tips it to exec:manual. Pure (no I/O), so it
# is unit-tested by the selftest and the tested logic IS the shipped logic.

# context_check_exec_class <title> <desc> — emit "exec:manual" iff title+desc
#   carry a clear physical-device / human-identity-credential / human-provisioning
#   signal; else "exec:auto" (default). Case-insensitive (en + pt). Conservative:
#   never over-tag manual (that would wrongly suppress autonomy).
context_check_exec_class() {
  local t
  t=$(printf '%s\n%s' "${1:-}" "${2:-}" | tr 'A-Z' 'a-z')
  # 1. PHYSICAL device / hardware / physical proxy — an agent has no hands.
  #    "phone-as-Claro-mobile-proxy" (physical phone), SIM swaps, hardware proxies.
  case "$t" in
    *" sim "*|*" sim-"*|*"-sim "*|*" sim/"*|*"chip "*|\
*"physical"*|*"físic"*|*"fisic"*|*"hardware"*|*"dispositivo"*|\
*"plug in"*|*"plug-in"*|*"plugar"*|*"conectar manualmente"*|*"ligar o aparelho"*|\
*"aparelho"*|*"celular"*|*"smartphone"*|*"phone-as"*|*"phone as"*|\
*"proxy físic"*|*"proxy fisic"*|*"hardware proxy"*|*"dongle"*|*"roteador físic"*)
      echo "exec:manual"; return ;;
  esac
  # 2. GOV / 3rd-party PORTAL gated by HUMAN identity (CPF + CAPTCHA, e-SIC/LAI,
  #    cartório). An agent cannot pass a human-identity / CAPTCHA gate.
  case "$t" in
    *"e-sic"*|*"esic"*|*" lai "*|*" lai)"*|*"(lai"*|*"lei de acesso"*|\
*"captcha"*|*"cartório"*|*"cartorio"*|*"planta genérica"*|*"planta generica"*|\
*"pedido de informa"*|*"protocolo presencial"*|*"presencial"*)
      echo "exec:manual"; return ;;
  esac
  # 3. HUMAN-held CREDENTIAL / account / channel PROVISIONING (a secret/identity
  #    a human must create or hold). "provisionar canal Whapi", "criar conta",
  #    "credencial". Kept tight: pair provisioning verbs with credential/account/
  #    channel nouns so a generic "provision a table" code task stays exec:auto.
  case "$t" in
    *"provisionar canal"*|*"provisionar conta"*|*"provisionar credencial"*|\
*"provisionar número"*|*"provisionar numero"*|\
*"provision a channel"*|*"provision an account"*|*"provision credential"*|\
*"provision a number"*|*"criar conta"*|*"nova conta"*|*"new account"*|\
*"cadastrar conta"*|*"canal whapi"*)
      echo "exec:manual"; return ;;
  esac
  # 4. HUMAN DESIGN / BUSINESS-DECISION GATE — the work itself is gated on a human
  #    design approval or a cost/business decision BEFORE any code (not physical, not
  #    a credential — the spec needs a human call first). A crew that auto-builds these
  #    wastes the build and produces unreviewed design. Phrases are deliberate gate
  #    markers (low false-positive), paired where a lone word would be too broad.
  #    Caught the recurring design-first mis-dispatch: wa-tozk ("DESIGN-FIRST —
  #    aguardando OK do thies/Athos antes de qualquer código"), wa-1my1 ("spec aprovado
  #    por Athos antes de codar"), wa-yma9 ("bloqueado em decisão de custo").
  case "$t" in
    *"design-first"*|*"design first"*|\
*"antes de qualquer código"*|*"antes de qualquer codigo"*|\
*"aprovad"*"antes de codar"*|*"aprovad"*"antes de programar"*|\
*"aguardando ok do"*|*"aguardando aprovação"*|*"aguardando aprovacao"*|\
*"aguardando review humano"*|*"aguardando decisão"*|*"aguardando decisao"*|\
*"aprovação do design"*|*"aprovacao do design"*|\
*"decisão de custo"*|*"decisao de custo"*|*"cost decision"*|*"business decision"*)
      echo "exec:manual"; return ;;
  esac
  # Default: a crew agent can try it.
  echo "exec:auto"
}

# If sourced by the selftest, stop here — expose the pure functions only.
if [ "${CONTEXT_CHECK_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ── Kill-switch gate ────────────────────────────────────────────────────────────
if [ "$CONTEXT_CHECK_ENABLED" != "1" ]; then
  log "Context-check DISABLED (CONTEXT_CHECK_ENABLED=$CONTEXT_CHECK_ENABLED) — no-op exit."
  exit 0
fi

# ── bd/gc wrappers ────────────────────────────────────────────────────────────
bd_() { bd -C "${CC_STORE:-$GC_CITY}" "$@"; }
_labels_csv() { echo "$1" | jq -r '(.labels // []) | join(",")'; }

# ── context_check_gap_comment <desc_len> <has_signal> <mechanical> <sonnet> ────
# Build the ctx:thin gap comment (the actionable artifact a human/agent reads to
# know WHAT to add). Names the failing rubric dimension(s). Pure string-building.
context_check_gap_comment() {
  local dlen="$1" sig="$2" mech="$3" sonnet="${4:-}"
  local head="Context-check: marcado ctx:thin — falta contexto para um agente genérico construir sem um humano."
  local body=""
  if [ "$dlen" -lt "$CONTEXT_CHECK_THIN_MAXLEN" ] 2>/dev/null; then
    body="  • O QUÊ: descrição vazia ou quase vazia (${dlen} chars). Diga o que precisa ser feito e por quê."
  elif [ "$sig" = "no" ]; then
    body="  • COMO-VERIFICAR: nenhum critério verificável ou artefato concreto (arquivo/comando/resultado esperado). Adicione ≥1 critério de aceitação observável."
  elif [ "$mech" = "uncertain" ] && [ "$sonnet" != "READY" ]; then
    body="  • ESCOPO/CRITÉRIOS: a revisão (Sonnet) não conseguiu confirmar que o quê + como-verificar + escopo estão completos. Acrescente detalhe ou ≥1 critério de aceitação verificável."
  else
    body="  • Contexto insuficiente nas dimensões QUÊ / COMO-VERIFICAR / ESCOPO."
  fi
  printf '%s\n%s\nQuando estiver completo, remova o label ctx:thin para re-avaliação.' "$head" "$body"
}

# ── context_check_sonnet_judge <id> <title> <desc> <type> ───────────────────────
# Spawn ONE independent Sonnet reviewer to judge the ambiguous-band bead against
# the 3-field rubric (WHAT / HOW-TO-VERIFY / SCOPE), poll a verdict bead, and echo
# READY | THIN | TIMEOUT. Modeled on the refino-gate's reviewer pattern (genuine
# gc session, durable-pull verdict bead, outer timeout). Fail-toward-thin: any
# non-READY outcome (FAIL, spawn failure, timeout) → THIN/TIMEOUT (→ ctx:thin).
context_check_sonnet_judge() {
  local _id="$1" _title="$2" _desc="$3" _type="$4"
  local _run_id="ctxcheck-$(date -u +%Y%m%dT%H%M%SZ)-$_id"
  local _verdict_bead
  _verdict_bead=$(bd_ create \
    "ctx-verdict: $_id" \
    -t chore --ephemeral \
    -l type:context-check-verdict \
    -l "ctx-run:$_run_id" \
    -l "ctx-bead:$_id" \
    -l verdict:pending \
    -d "Verdict bead for context-check of $_id. Reviewer closes with verdict:READY or verdict:THIN." \
    --json 2>/dev/null | jq -r '.id // empty')
  if [ -z "$_verdict_bead" ]; then
    warn "  ctx Sonnet judge: failed to create verdict bead for $_id → THIN (fail-toward-human)."
    echo "THIN"; return
  fi

  local _task
  _task=$(cat <<TASK
CONTEXT-CHECK (creation gate) — Judge whether a GENERIC agent could implement this
bead WITHOUT a human, using the 3-field rubric. You do NOT build it and you do NOT
dispatch it. You only attest context-completeness. Be strict but fair: a terse
bead that nonetheless names a clear WHAT + a verifiable outcome + a coherent SCOPE
is READY; default to THIN whenever you are unsure.

BEAD: $_id ($_type) — $_title
Description:
$_desc

RUBRIC — answer all three:
  1. WHAT: is the intent/goal unambiguous (a generic agent knows what to change)?
  2. HOW-TO-VERIFY: is there ≥1 verifiable acceptance criterion OR a concrete
     named artifact (file/command/expected output) to confirm done-ness?
  3. SCOPE: is it bounded and free of an unmade product/priority decision?

READY only if ALL three hold AND building it needs NO product decision a human
must make. Otherwise THIN. When in doubt → THIN.

RECORD YOUR VERDICT with EXACTLY these commands, then exit:
bd -C "$GC_CITY" label remove "$_verdict_bead" "verdict:pending"
# If complete enough for a generic agent:
bd -C "$GC_CITY" label add "$_verdict_bead" "verdict:READY"
bd -C "$GC_CITY" comment "$_verdict_bead" "VERDICT: READY — <1 frase do porquê>"
bd -C "$GC_CITY" close "$_verdict_bead"
# If under-specified (default when unsure):
# bd -C "$GC_CITY" label add "$_verdict_bead" "verdict:THIN"
# bd -C "$GC_CITY" comment "$_verdict_bead" "VERDICT: THIN — <qual dimensão falta: QUÊ/COMO-VERIFICAR/ESCOPO>"
# bd -C "$GC_CITY" close "$_verdict_bead"
Do not start other work. Record the verdict and exit.
TASK
)

  local _spawn_err_file="/tmp/ctxcheck-reviewer-spawn-err-$$"
  local _sess_json
  _sess_json=$(gc --city "$GC_CITY" session new "$CONTEXT_CHECK_REVIEWER_TEMPLATE" \
    --no-attach --title "ctx-check: $_id" --json 2>"$_spawn_err_file" || echo "{}")
  rm -f "$_spawn_err_file" 2>/dev/null || true
  local _sid _sname
  _sid=$(echo "$_sess_json" | jq -r '.session_id // empty')
  if [ -z "$_sid" ]; then
    warn "  ctx Sonnet judge: spawn failed for $_id → THIN (fail-toward-human)."
    bd_ close "$_verdict_bead" 2>/dev/null || true
    echo "THIN"; return
  fi
  gc --city "$GC_CITY" session wake "$_sid" 2>/dev/null || true
  _sname=$(echo "$_sess_json" | jq -r '.session_name // empty')
  if [ -n "$_sname" ]; then
    bd_ update "$_verdict_bead" --assignee "$_sname" --status in_progress -q 2>/dev/null || true
    bd_ comment "$_verdict_bead" "$_task" 2>/dev/null || true
  fi
  gc --city "$GC_CITY" session nudge "$_sid" "$_task" --delivery queue 2>/dev/null \
    || gc --city "$GC_CITY" session submit "$_sid" "$_task" 2>/dev/null || true

  local _deadline=$(( $(date +%s) + CONTEXT_CHECK_VERDICT_TIMEOUT_MINUTES * 60 ))
  local _verdict="TIMEOUT" _vb _vl
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    _vb=$(bd_ show "$_verdict_bead" --json 2>/dev/null || echo "[]")
    _vl=$(echo "$_vb" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")')
    if echo "$_vl" | grep -q "verdict:READY"; then _verdict="READY"; break
    elif echo "$_vl" | grep -q "verdict:THIN"; then _verdict="THIN"; break; fi
    sleep "$CONTEXT_CHECK_VERDICT_POLL_INTERVAL"
  done
  echo "$_verdict"
}

log "Context-check sweep start (actor=$CONTEXT_CHECK_ACTOR, max/sweep=$CONTEXT_CHECK_MAX_PER_SWEEP, max-sonnet/sweep=$CONTEXT_CHECK_MAX_SONNET_PER_SWEEP, dry_run=$DRY_RUN)"

# ── Step 1: Gather candidates ──────────────────────────────────────────────────
# Actionable work types: bug / chore / task / debt + feature (feature is filtered
# to those WITHOUT a story:* label by the pure classifier). bd has no
# missing-label filter, so we exclude ctx:* at the query AND re-assert every rule
# in the pure classifier (defense in depth). One union, dedup, oldest-first.
# Multi-store: judge actionable beads across ALL rig stores (HQ + WA + PS). The
# labeling pass is store-scoped (bd_ honors $CC_STORE). Only the optional Sonnet
# reviewer spawn is city-coupled (uses $GC_CITY = the HQ city) — it stays on HQ.
# Per-sweep caps are GLOBAL across stores (one shared Dolt-load budget).
CONTEXT_CHECK_STORES="${CONTEXT_CHECK_STORES:-$GC_CITY /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers}"

_fetch_type() {
  bd_ list --type "$1" --status open \
    --exclude-label ctx:ready \
    --exclude-label ctx:thin \
    --json 2>/dev/null || echo "[]"
}

# ── Step 2: Classify + judge across all stores, up to the GLOBAL per-sweep caps ─
JUDGED=0
SONNET_USED=0
N_READY=0
N_THIN=0
N_SONNET=0
N_MANUAL=0
N_AUTO=0

for CC_STORE in $CONTEXT_CHECK_STORES; do
  [ "$JUDGED" -ge "$CONTEXT_CHECK_MAX_PER_SWEEP" ] 2>/dev/null && { log "Global per-sweep cap ($CONTEXT_CHECK_MAX_PER_SWEEP) reached — skipping remaining stores."; break; }
  log "── store: $CC_STORE ──"
  BUG_JSON=$(_fetch_type bug)
  CHORE_JSON=$(_fetch_type chore)
  TASK_JSON=$(_fetch_type task)
  DEBT_JSON=$(_fetch_type debt)
  FEATURE_JSON=$(_fetch_type feature)
  CANDIDATES=$(jq -s 'add | unique_by(.id)' \
    <(echo "$BUG_JSON") <(echo "$CHORE_JSON") <(echo "$TASK_JSON") \
    <(echo "$DEBT_JSON") <(echo "$FEATURE_JSON") 2>/dev/null || echo "[]")
  CCOUNT=$(echo "$CANDIDATES" | jq 'length' 2>/dev/null || echo 0)
  if [ "$CCOUNT" -eq 0 ] 2>/dev/null; then
    log "  no open actionable beads in this store."
    continue
  fi
  log "  $CCOUNT open actionable bead(s) fetched (pre-classification)."

# Iterate oldest-first (FIFO) so the backlog drains in arrival order.
while IFS= read -r row; do
  [ -z "$row" ] && continue
  [ "$JUDGED" -ge "$CONTEXT_CHECK_MAX_PER_SWEEP" ] 2>/dev/null && { log "Per-sweep cap ($CONTEXT_CHECK_MAX_PER_SWEEP) reached — remaining beads next sweep."; break; }

  c_id=$(echo "$row" | jq -r '.id // empty')
  [ -z "$c_id" ] && continue
  c_type=$(echo "$row" | jq -r '.issue_type // .type // "task"')
  c_labels=$(_labels_csv "$row")
  c_ephemeral=$(echo "$row" | jq -r 'if (.ephemeral // false)==true then "true" else "false" end')
  c_has_story=$(echo "$row" | jq -r 'if ((.labels // []) | any(type=="string" and startswith("story:"))) then "yes" else "no" end')

  # Master candidacy gate (pure).
  if [ "$(context_check_is_candidate "$c_id" "$c_type" "$c_labels" "$c_ephemeral" "$c_has_story")" != "yes" ]; then
    continue
  fi

  c_title=$(echo "$row" | jq -r '.title // ""')
  c_desc=$(echo "$row" | jq -r '.description // ""')
  c_dlen=${#c_desc}
  c_tlen=${#c_title}
  c_sig=$(context_check_has_verifiable_signal "$c_desc")
  MECH=$(context_check_mechanical_verdict "$c_dlen" "$c_sig" "$c_tlen")

  SONNET_VERDICT=""
  if [ "$MECH" = "uncertain" ]; then
    # Ambiguous middle band. Three sub-cases:
    if [ "$CONTEXT_CHECK_MAX_SONNET_PER_SWEEP" -eq 0 ] 2>/dev/null; then
      # (a) Heuristic-only mode (Sonnet disabled): default to ctx:thin — fail
      #     toward "needs human", NEVER falsely ready. SONNET_VERDICT stays empty
      #     → context_check_verdict_label resolves uncertain+"" to ctx:thin.
      log "  $c_id uncertain; Sonnet disabled (MAX_SONNET=0) → ctx:thin (fail-toward-human)."
    elif [ "$SONNET_USED" -lt "$CONTEXT_CHECK_MAX_SONNET_PER_SWEEP" ] 2>/dev/null; then
      # (b) Sonnet enabled + budget remains → spawn one Sonnet judge.
      if [ "$DRY_RUN" = "1" ]; then
        log "  WOULD spawn Sonnet context-judge for $c_id (uncertain) — DRY_RUN; projecting as ctx:thin (conservative default)."
        SONNET_VERDICT="TIMEOUT"   # projection: treat as the conservative default
      else
        SONNET_VERDICT=$(context_check_sonnet_judge "$c_id" "$c_title" "$c_desc" "$c_type")
      fi
      SONNET_USED=$((SONNET_USED+1))
      N_SONNET=$((N_SONNET+1))
    else
      # (c) Sonnet enabled but this sweep's budget is spent. Do NOT thin-flag a
      #     possibly-ready bead purely for a budget miss — SKIP it (no label) so a
      #     later sweep with budget Sonnet-judges it properly.
      log "  $c_id uncertain but Sonnet budget spent this sweep → skipped (no label; re-judged next sweep)."
      continue
    fi
  fi

  LABEL=$(context_check_verdict_label "$MECH" "$SONNET_VERDICT")
  JUDGED=$((JUDGED+1))
  case "$LABEL" in
    ctx:ready) N_READY=$((N_READY+1)) ;;
    ctx:thin)  N_THIN=$((N_THIN+1)) ;;
  esac

  # ── exec-class (automation-debt): ONLY for ctx:ready beads. Pure + conservative
  # (defaults exec:auto). Fail-OPEN: a classifier failure must NEVER block the
  # ctx:ready verdict above. Empty EXEC when not ready or feature-gated off — the
  # verdict path below is unconditional. (A ctx:thin bead isn't dispatchable, so
  # it carries no exec pill; the painel only shows the pill in Aprovadas.)
  EXEC=""
  if [ "$LABEL" = "ctx:ready" ] && [ "$CONTEXT_CHECK_EXEC_CLASS" = "1" ]; then
    EXEC=$(context_check_exec_class "$c_title" "$c_desc" 2>/dev/null || echo "exec:auto")
    case "$EXEC" in exec:manual|exec:auto) : ;; *) EXEC="exec:auto" ;; esac
    case "$EXEC" in
      exec:manual) N_MANUAL=$((N_MANUAL+1)) ;;
      exec:auto)   N_AUTO=$((N_AUTO+1)) ;;
    esac
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "  WOULD label $c_id → $LABEL${EXEC:+ + $EXEC} (mech=$MECH sig=$c_sig dlen=$c_dlen) — $c_title"
    jq -c -n --arg ts "$(ts)" --arg id "$c_id" --arg label "$LABEL" \
      --arg exec "$EXEC" \
      --arg mech "$MECH" --arg sig "$c_sig" --argjson dlen "$c_dlen" \
      '{ts:$ts, event:"dry_run_judge", id:$id, label:$label, exec_class:$exec, mechanical:$mech, signal:$sig, desc_len:$dlen}' \
      >> "$CC_LOG" 2>/dev/null || true
    continue
  fi

  # ── Write the verdict (positive label). Idempotent (add is a no-op if present).
  bd_ label add "$c_id" "$LABEL" -q 2>/dev/null || true
  if [ "$LABEL" = "ctx:thin" ]; then
    # Name the gap so a human (or the painel pill) knows WHAT is missing. The
    # comment is the actionable artifact — a generic agent / Athos reads it to
    # know what to add before this bead can become ctx:ready.
    GAP=$(context_check_gap_comment "$c_dlen" "$c_sig" "$MECH" "$SONNET_VERDICT")
    bd_ comment "$c_id" "$GAP" 2>/dev/null || true
  fi
  # ── exec-class label: exactly ONE of exec:manual | exec:auto on a ctx:ready
  # bead (automation-debt pill). Idempotent: only write if absent/changed, and
  # strip the opposite so a re-judge can't leave both. Fail-OPEN — every bd_ here
  # is best-effort (|| true); a failure can NEVER unwind the ctx:ready verdict.
  if [ -n "$EXEC" ]; then
    if echo ",$c_labels," | grep -qF ",$EXEC,"; then
      : # already correctly labeled — no thrash
    else
      case "$EXEC" in
        exec:manual) bd_ label remove "$c_id" "exec:auto"   -q 2>/dev/null || true ;;
        exec:auto)   bd_ label remove "$c_id" "exec:manual" -q 2>/dev/null || true ;;
      esac
      bd_ label add "$c_id" "$EXEC" -q 2>/dev/null || true
    fi
  fi
  log "  $c_id → $LABEL${EXEC:+ + $EXEC} (mech=$MECH sig=$c_sig dlen=$c_dlen)"
  jq -c -n --arg ts "$(ts)" --arg id "$c_id" --arg label "$LABEL" \
    --arg exec "$EXEC" \
    --arg mech "$MECH" --arg sig "$c_sig" --argjson dlen "$c_dlen" \
    '{ts:$ts, event:"judge", id:$id, label:$label, exec_class:$exec, mechanical:$mech, signal:$sig, desc_len:$dlen}' \
    >> "$CC_LOG" 2>/dev/null || true

done < <(echo "$CANDIDATES" | jq -c 'sort_by(.created_at // .id) | .[]')
done  # end per-store loop

log "Context-check sweep done. judged=$JUDGED ctx:ready=$N_READY ctx:thin=$N_THIN sonnet=$N_SONNET exec:manual=$N_MANUAL exec:auto=$N_AUTO (dry_run=$DRY_RUN)"
jq -c -n --arg ts "$(ts)" --argjson judged "$JUDGED" --argjson ready "$N_READY" \
  --argjson thin "$N_THIN" --argjson sonnet "$N_SONNET" \
  --argjson manual "$N_MANUAL" --argjson auto "$N_AUTO" --arg dry "$DRY_RUN" \
  '{ts:$ts, event:"sweep_summary", judged:$judged, ready:$ready, thin:$thin, sonnet:$sonnet, exec_manual:$manual, exec_auto:$auto, dry_run:$dry}' \
  >> "$CC_LOG" 2>/dev/null || true
exit 0
