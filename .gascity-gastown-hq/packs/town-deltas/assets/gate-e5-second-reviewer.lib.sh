#!/usr/bin/env bash
# gate-e5-second-reviewer.lib.sh — E5 (ga-syxaki, P0 ga-ufskhy): a 2nd independent gate
# reviewer, as an A/B experiment. Sourced (fail-soft) by quality-gate-dispatcher.sh;
# every function is bash 3.2 safe (the only bash on this host: no associative arrays, no
# ${x,,}, and "${arr[@]}" on an EMPTY array aborts under `set -u`).
#
# WHY (docs/reports/gate-e4-historico.md §6, Frente 6): 52.7% of the blocking issues of
# review round >= 2 were LATENT — already in the code of round 1 — and in 28% of those the
# round-1 verdict called the very passage OK. 1 reviewer, 1 pass, in 100% of the runs.
#
# WHAT (the arm is a PURE function of the bead id; arm A is today's gate, byte for byte):
#   arm B — a 2nd reviewer, in a SEPARATE session that never sees the 1st verdict, on the
#           SAME diff, when EITHER
#             (big-diff)   the diff has >= GATE_E5_SIZE_THRESHOLD_LINES (800) lines, spawned
#                          next to reviewer 1 at admission; OR
#             (first-fail) reviewer 1 returned the bead's FIRST judged FAIL, spawned before
#                          that FAIL is handed back to the builder.
#           The verdict returned to the builder is the UNION of the blocking issues
#           (gate-e5-union.py: dedupe by file+line+description; everything else is kept).
#   both arms — the verdict comment lists the files/passages the reviewer EXAMINED
#           ("Coverage:"), so the analysis can tell "latent" from "never looked".
#
# OFF BY DEFAULT. Switch: the flag FILE $GC_CITY/.gc/gate-e5-second-reviewer.on (touch to
# turn on, rm to turn off — no plist edit, no restart; takes effect on the next sweep) or
# GATE_E5_ENABLED=1|0 in the environment (wins over the file; used by the selftests).
# With the flag off NOTHING below runs and the reviewer prompt is byte-identical.
#
# INVARIANT THE WHOLE DESIGN HANGS ON: the extra reviewer can only ADD delivered blocking
# issues to a run. It never flips a FAIL to a PASS, and a PASS is only ever flipped by an
# extra verdict it actually DELIVERED. Everything the extra reviewer can get wrong — no
# session slot, a task it can't build, a timeout, a dead session, the daily spend cap, an
# unreadable bead — degrades to "arm A behaviour": the gate answers with reviewer 1's
# verdict alone, exactly as it does today. Three states, never collapsed: delivered /
# not-delivered / could-not-tell-(=not-delivered, logged with its reason).
#
# Observability: every decision is a line in quality-gate.jsonl (events e5_admit,
# e5_session, e5_extra_spawn, e5_extra_declined, e5_extra_abandoned, e5_run_end) — the
# apuração (scripts/gate-e5-apuracao.py) is a pure function of those lines.

GATE_E5_SIZE_THRESHOLD_LINES="${GATE_E5_SIZE_THRESHOLD_LINES:-800}"
case "$GATE_E5_SIZE_THRESHOLD_LINES" in ''|*[!0-9]*) GATE_E5_SIZE_THRESHOLD_LINES=800 ;; esac
# Spend guard. The per-review figure is the E0 measurement (~US$ 0.60 per Sonnet review);
# it is an ESTIMATE used only to bound the day's extra reviews — the apuração measures the
# real cost from the session transcripts.
GATE_E5_EST_COST_USD="${GATE_E5_EST_COST_USD:-0.60}"
GATE_E5_DAILY_CAP_USD="${GATE_E5_DAILY_CAP_USD:-30}"

# ── the flag ──────────────────────────────────────────────────────────────────
# gate_e5_enabled — prints 1 or 0. Anything unreadable/unrecognised is 0 (inert).
gate_e5_enabled() {
  case "${GATE_E5_ENABLED:-}" in
    1) printf '1'; return 0 ;;
    0) printf '0'; return 0 ;;
  esac
  local _f="${GATE_E5_FLAG_FILE:-${GC_CITY:-}/.gc/gate-e5-second-reviewer.on}"
  if [ -n "${GC_CITY:-}${GATE_E5_FLAG_FILE:-}" ] && [ -r "$_f" ]; then
    printf '1'
  else
    printf '0'
  fi
}

# ── the arm ───────────────────────────────────────────────────────────────────
# gate_e5_arm_for_bead <bead_id> — prints A or B: B <=> the first 32 bits of
# SHA-256("e5-second-reviewer:<bead-id>") are even. A pure function of the bead id (a bead that
# fails and re-submits under the same id can never change arm), recomputable by anyone:
#   printf '%s' "e5-second-reviewer:ga-abc123" | shasum -a 256 | cut -c1-8   (odd last hex digit = A)
# WHY SHA-256 and not the base-31 polynomial of ga-rstae (quality-gate-guard.sh), even salted:
# pre-gate-review.sh measured on 1220 real bead ids that a SALTED polynomial still agrees with the
# ga-rstae arm on 43% of beads (chi-square ~28) — the parity is decided by how often the running
# value wraps modulo 100000007, which a prefix barely changes. Two experiments sharing beads cannot
# be told apart. SHA-256 with a per-experiment salt shares no arithmetic with either.
#   Empty id      -> prints nothing, returns 2: a bead we cannot identify has no arm.
#   No sha tool   -> prints nothing, returns 3: same. "No arm" must never read as A — the callers
#                    add no reviewer and the e5_admit line says arm=?, so the apuração leaves it out.
gate_e5_arm_for_bead() {
  local bead="${1:-}" tool digest="" first
  [ -z "$bead" ] && return 2
  # Fast C tools first (shasum is a perl script: ~0.1s a call under load); all compute the same digest.
  for tool in "sha256sum" "openssl dgst -sha256 -r" "shasum -a 256"; do
    command -v "${tool%% *}" >/dev/null 2>&1 || continue
    digest="$(printf '%s' "e5-second-reviewer:$bead" | $tool 2>/dev/null | cut -c1-8)"
    case "$digest" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) break ;;
      *) digest="" ;;
    esac
  done
  [ -n "$digest" ] || return 3
  first=$(( 16#$digest ))
  if (( first % 2 == 0 )); then printf 'B'; else printf 'A'; fi
}

# gate_e5_size_state <raw_diff_lines> — yes | no | unknown. `unknown` (empty / not a
# number) is NOT "no": the caller logs it and adds no reviewer, but the log says we could
# not measure instead of claiming the diff was small.
gate_e5_size_state() {
  case "${1:-}" in
    ''|*[!0-9]*) printf 'unknown' ;;
    *) if [ "$1" -ge "$GATE_E5_SIZE_THRESHOLD_LINES" ]; then printf 'yes'; else printf 'no'; fi ;;
  esac
}

# ── structured events ─────────────────────────────────────────────────────────
# gate_e5_log_event <event> [key value]... — one compact JSON line appended to
# quality-gate.jsonl. All values are strings (the apuração parses numbers). Never fails
# the caller: a lost event is an observability gap, not a gate failure.
gate_e5_log_event() {
  local _ev="$1"; shift
  local _file="${QG_LOG:-}"
  [ -z "$_file" ] && return 0
  local _args=() _prog='{ts:$ts,event:$event' _k _v
  while [ "$#" -ge 2 ]; do
    _k="$1"; _v="$2"; shift 2
    _args+=(--arg "$_k" "$_v")
    _prog="${_prog},${_k}:\$${_k}"
  done
  _prog="${_prog}}"
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$_ev" \
    ${_args[@]+"${_args[@]}"} "$_prog" >> "$_file" 2>/dev/null || true
  return 0
}

# gate_e5_prompt_fingerprint <review_task> <verdict_bead> — cksum of the instruction part of
# a reviewer task (everything after "--- YOUR TASK ---"), with the per-run ids normalised, so
# the apuração can tell which prompt a run's reviewers were given (the E4 design asks for it).
gate_e5_prompt_fingerprint() {
  local _t="${1#*--- YOUR TASK ---}" _vb="${2:-}"
  [ -n "$_vb" ] && _t="${_t//$_vb/<VB>}"
  [ -n "${AUTHOR:-}" ] && _t="${_t//$AUTHOR/<AUTHOR>}"
  printf '%s' "$_t" | cksum 2>/dev/null | awk '{print $1}'
}

# gate_e5_log_admit <review_task_1> <verdict_bead_1> — the per-run record of the experiment
# (one line per run admitted while the flag is on, BOTH arms): the denominators of the
# apuração and the stratification keys (size, rig, tier), written before any reviewer runs.
gate_e5_log_admit() {
  gate_e5_log_event e5_admit gate_run "${GATE_RUN_ID:-}" bead "${BEAD_ID:-}" branch "${BRANCH:-}" \
    rig "${RIG:-}" tier "${TIER:-}" author "${AUTHOR:-}" arm "${GATE_E5_ARM:-A}" \
    trigger "${GATE_E5_TRIGGER:-none}" size_state "${GATE_E5_SIZE_STATE:-}" raw_lines "${GATE_E5_RAW_LINES:-}" \
    base_reviewers "${REQUIRED_REVIEWERS:-}" review_prompt_cksum "$(gate_e5_prompt_fingerprint "${1:-}" "${2:-}")"
}

# gate_e5_log_session <slot> <session_id> <session_name> <session_key> <verdict_bead> — which
# session reviewed under which verdict bead: the key to the session transcript, hence to the
# real cost of the run. session_key may be empty (gc new does not always return it).
gate_e5_log_session() {
  gate_e5_log_event e5_session gate_run "${GATE_RUN_ID:-}" bead "${BEAD_ID:-}" slot "$1" \
    session_id "$2" session_name "$3" session_key "${4:-}" verdict_bead "${5:-}"
}

# gate_e5_log_run_end — the outcome line for a run that ended with an E5 extra slot. Called
# from gate_finalize_run (a run with no extra slot is fully described by e5_admit plus the
# dispatcher's own dispatcher_complete line, joined on gate_run).
gate_e5_log_run_end() {
  [ "${GATE_E5_EXTRA_SEEN:-0}" = "1" ] || return 0
  gate_e5_log_event e5_run_end gate_run "${GATE_RUN_ID:-}" bead "${BEAD_ID:-}" result "${OVERALL_VERDICT:-}" \
    extra_verdict "${GATE_E5_EXTRA_VERDICT:--}" judged_fails "${GATE_COLLECT_JUDGED_FAILS:-0}" \
    reviewers "${REQUIRED_REVIEWERS:-}" union "${GATE_E5_UNION_STATS:-}"
}

# ── reviewer prompt pieces ────────────────────────────────────────────────────
# The dispatcher's REVIEW_TASK heredoc expands ${GATE_E5_COV_RULES} and ${GATE_E5_COV_PASS_LINE}.
# They are EMPTY unless the flag is on, and each sits at a line boundary so the empty
# expansion leaves the task byte-identical to today's. (No FAIL-template variable: bash 3.2
# parses the heredoc inside $(...) quote-aware and only the leading "#" of the commented FAIL
# example hides its lone quote — so that line cannot start with a ${VAR}. The rules paragraph
# tells the reviewer the Coverage line belongs in a FAIL comment too.)
gate_e5_task_vars() {
  GATE_E5_COV_RULES=""
  GATE_E5_COV_PASS_LINE=""
  [ "$(gate_e5_enabled)" = "1" ] || return 0
  GATE_E5_COV_RULES='

COVERAGE REPORT (required): add ONE line starting with "Coverage:" to your VERDICT comment — a FAIL comment as much as a PASS one — listing the files — and, for long files, the line ranges or functions — that you actually read, and naming every changed file or hunk you did NOT examine. It is a record of what you looked at, nothing more: listing less than the whole diff does not make any finding optional, and it never changes what counts as blocking.'
  GATE_E5_COV_PASS_LINE='Coverage: <files/passages you examined, and any changed file or hunk you did NOT examine>
'
  return 0
}

# gate_e5_extra_lens — the lens line of the 2nd reviewer. Same correctness bar, but a full
# sweep and a hunt for siblings: E4 found that "fixed the example, not the class" recurs
# (38.9% of the latent issues are siblings of one already pointed out).
gate_e5_extra_lens() {
  printf '%s' 'CORRECTNESS — INDEPENDENT FULL-COVERAGE PASS: you are a second, independent reviewer of this same diff. Apply the same correctness bar as any reviewer (logic errors, edge cases, null/empty handling, error propagation, incorrect assumptions) but sweep the WHOLE diff file by file instead of stopping at the first blocking defect, and when you find a defect look for its siblings: the same pattern elsewhere in this diff (other call sites, other branches, the same assumption repeated). The third-state check of the reviewer prompt applies to you as well.'
}

# gate_e5_extra_task <task_of_reviewer_1> <verdict_bead_1> <verdict_bead_2>
# Pure. Prints reviewer 2's task: reviewer 1's task with its slot ("reviewer 1 of 1" ->
# "reviewer 2 of 2"), its lens line and its verdict-bead id swapped. The task carries the
# diff and the instructions and NOTHING of reviewer 1's verdict, so the 2nd review is
# independent by construction. Returns 1 (and prints nothing) when any anchor is missing —
# the prompt template changed under us; the caller then declines, never guesses.
gate_e5_extra_task() {
  local t1="${1:-}" vb1="${2:-}" vb2="${3:-}" lens t2
  [ -n "$t1" ] && [ -n "$vb1" ] && [ -n "$vb2" ] || return 1
  case "$t1" in *"You are reviewer 1 of 1 for branch:"*) : ;; *) return 1 ;; esac
  case "$t1" in *"YOUR REVIEW LENS:"*) : ;; *) return 1 ;; esac
  case "$t1" in *"$vb1"*) : ;; *) return 1 ;; esac
  lens="$(gate_e5_extra_lens)"
  t2="${t1/You are reviewer 1 of 1 for branch:/You are reviewer 2 of 2 for branch:}"
  t2=$(printf '%s\n' "$t2" | awk -v lens="$lens" '
      !done && /^YOUR REVIEW LENS:/ { print "YOUR REVIEW LENS: " lens; done = 1; next }
      { print }') || return 1
  t2="${t2//$vb1/$vb2}"
  case "$t2" in *"You are reviewer 2 of 2 for branch:"*) : ;; *) return 1 ;; esac
  case "$t2" in *"YOUR REVIEW LENS: CORRECTNESS — INDEPENDENT FULL-COVERAGE PASS"*) : ;; *) return 1 ;; esac
  case "$t2" in *"$vb2"*) : ;; *) return 1 ;; esac
  case "$t2" in *"$vb1"*) return 1 ;; esac
  printf '%s' "$t2"
}

# ── the daily spend cap ───────────────────────────────────────────────────────
gate_e5_spend_file() { printf '%s/.gc/gate-e5-spend-%s.count' "${GC_CITY:-}" "$(date +%Y-%m-%d)"; }

# gate_e5_cap_max — the most extra reviews a day may add (cap / per-review estimate).
# Empty when either number is unusable -> the caller treats the cap as UNKNOWN and adds no
# reviewer (a misconfigured guard must never read as "no limit").
gate_e5_cap_max() {
  awk -v c="$GATE_E5_DAILY_CAP_USD" -v u="$GATE_E5_EST_COST_USD" 'BEGIN {
    if (c !~ /^[0-9]+([.][0-9]+)?$/ || u !~ /^[0-9]+([.][0-9]+)?$/) { exit }
    if (c + 0 <= 0 || u + 0 <= 0) { exit }
    printf "%d", c / u }' 2>/dev/null || true
}

# gate_e5_cap_state — ok | capped | unknown
gate_e5_cap_state() {
  local _max _f _n
  _max=$(gate_e5_cap_max)
  [ -z "$_max" ] && { printf 'unknown'; return 0; }
  _f=$(gate_e5_spend_file)
  if [ -e "$_f" ]; then
    _n=$(cat "$_f" 2>/dev/null || echo "")
    case "$_n" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  else
    _n=0
  fi
  if [ "$_n" -ge "$_max" ]; then printf 'capped'; else printf 'ok'; fi
}

# gate_e5_spend_record — counts one extra review against today's budget and pages (notify,
# once a day) the moment the estimated spend reaches the cap. The dispatcher is
# single-instance (the gate lock), so a read-modify-write needs no further locking.
gate_e5_spend_record() {
  local _f _n _max _tmp
  _f=$(gate_e5_spend_file)
  _n=$(cat "$_f" 2>/dev/null || echo 0)
  case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
  _n=$((_n + 1))
  _tmp="${_f}.tmp.$$"
  # A count that could not be persisted means the cap is NOT being enforced for the next spawn:
  # say so loudly instead of letting the day's spend go uncounted in silence.
  if printf '%s\n' "$_n" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_f" 2>/dev/null; then :; else
    rm -f "$_tmp" 2>/dev/null || true
    warn "  E5: could not write the daily spend counter ($_f) — the cap cannot see this extra review (count would have been $_n)."
  fi
  _max=$(gate_e5_cap_max)
  if [ -n "$_max" ] && [ "$_n" -ge "$_max" ] && [ ! -e "${_f}.alerted" ]; then
    : > "${_f}.alerted" 2>/dev/null || true
    if command -v notify >/dev/null 2>&1; then
      notify -t "Gate E5: daily cap reached" -p 4 \
        "Gate E5 (2nd reviewer): ${_n} extra reviews today ≈ US\$ $(awk -v n="$_n" -v u="$GATE_E5_EST_COST_USD" 'BEGIN{printf "%.2f", n*u}') (estimate) — cap US\$ ${GATE_E5_DAILY_CAP_USD}. No more extra reviewers until tomorrow; arm B beads run like arm A meanwhile." 2>/dev/null || true
    fi
  fi
  printf '%s' "$_n"
}

# ── the admission decision (Step 5/6 of the dispatcher) ───────────────────────
# gate_e5_admit_decision — call only when the flag is on. Needs git_rig + DEFAULT_BRANCH +
# BRANCH + BEAD_ID + REQUIRED_REVIEWERS. Sets GATE_E5_ARM, GATE_E5_SIZE_STATE,
# GATE_E5_RAW_LINES, GATE_E5_TRIGGER (none | big-diff). Measures the diff the same way the
# reviewer's header does (line count of the raw `git diff`), which is the basis of E4's
# 800-line threshold — NOT the numstat sum the timeout scaler uses.
GATE_E5_ARM="A"; GATE_E5_SIZE_STATE="no"; GATE_E5_RAW_LINES=""; GATE_E5_TRIGGER="none"
gate_e5_admit_decision() {
  GATE_E5_ARM=$(gate_e5_arm_for_bead "${BEAD_ID:-}") || GATE_E5_ARM="?"
  GATE_E5_SIZE_STATE="no"; GATE_E5_RAW_LINES=""; GATE_E5_TRIGGER="none"
  [ "$GATE_E5_ARM" = "B" ] || return 0
  local _out _rc=0
  _out=$(git_rig diff "origin/${DEFAULT_BRANCH}...origin/${BRANCH}" 2>/dev/null) || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    GATE_E5_SIZE_STATE="unknown"
    return 0
  fi
  if [ -z "$_out" ]; then
    GATE_E5_RAW_LINES=0
  else
    GATE_E5_RAW_LINES=$(printf '%s\n' "$_out" | wc -l | tr -d ' ')
  fi
  GATE_E5_SIZE_STATE=$(gate_e5_size_state "$GATE_E5_RAW_LINES")
  if [ "$GATE_E5_SIZE_STATE" = "yes" ] && [ "${REQUIRED_REVIEWERS:-1}" = "1" ]; then
    GATE_E5_TRIGGER="big-diff"
  fi
  return 0
}

# ── spawning the extra reviewer ───────────────────────────────────────────────
# gate_e5_spawn_extra <gate_run_id> <verdict_bead_1> <task_of_reviewer_1> <trigger>
# Returns 0 and sets GATE_E5_EXTRA_{VB,SID,SNAME,TASK,PEEK} when reviewer 2 is live and its
# task queued; returns 1 and sets GATE_E5_DECLINE_REASON otherwise (and logs the decline).
# Order matters: the SESSION is created first, the verdict bead second — so a failure at
# either step leaves at most one thing to clean up, and a bead that Phase C would wait on
# never exists without a session behind it.
GATE_E5_EXTRA_VB=""; GATE_E5_EXTRA_SID=""; GATE_E5_EXTRA_SNAME=""; GATE_E5_EXTRA_TASK=""; GATE_E5_EXTRA_PEEK=""
GATE_E5_DECLINE_REASON=""
gate_e5_decline() {
  GATE_E5_DECLINE_REASON="$1"
  warn "  E5: no extra reviewer for gate-run ${GATE_RUN_ID:-?} (bead ${BEAD_ID:-?}, trigger=${_e5_trig:-?}): $1 — the run proceeds exactly like arm A."
  gate_e5_log_event e5_extra_declined gate_run "${GATE_RUN_ID:-}" bead "${BEAD_ID:-}" trigger "${_e5_trig:-}" reason "$1"
  return 0   # always 0: a decline is a normal outcome, never an errexit trigger; callers `return 1` themselves
}
gate_e5_spawn_extra() {
  local _run="$1" _vb1="$2" _task1="$3" _e5_trig="$4"
  local _cap _errf _err _sjson _sid _sname _skey _vb2 _task2 _peek _vassign=0 _n
  GATE_E5_EXTRA_VB=""; GATE_E5_EXTRA_SID=""; GATE_E5_EXTRA_SNAME=""; GATE_E5_EXTRA_TASK=""; GATE_E5_EXTRA_PEEK=""
  GATE_E5_DECLINE_REASON=""

  [ -n "$_task1" ] || { gate_e5_decline "reviewer-1-task-unavailable"; return 1; }
  # Dry-run the task transformation BEFORE spending anything: a template that drifted away
  # from the anchors must cost nothing.
  gate_e5_extra_task "$_task1" "$_vb1" "ga-probe-probe" >/dev/null || { gate_e5_decline "task-anchor-missing"; return 1; }

  _cap=$(gate_e5_cap_state)
  case "$_cap" in
    ok) : ;;
    capped)  gate_e5_decline "daily-cap-reached"; return 1 ;;
    *)       gate_e5_decline "daily-cap-unreadable"; return 1 ;;
  esac

  # An optional extra review is the first thing to go when the Claude quota is exhausted (the
  # checker itself fails OPEN — an unreadable quota does not block; a wedged extra is retired later).
  if type gate_quota_limited >/dev/null 2>&1 && [ "$(gate_quota_limited)" = "1" ]; then
    gate_e5_decline "claude-quota-limited"; return 1
  fi

  _errf=$(mktemp "${TMPDIR:-/tmp}/gate-e5-spawn-err.XXXXXX" 2>/dev/null || echo "/dev/null")
  _sjson=$(gc --city "$GC_CITY" session new gate-reviewer --no-attach \
    --title "gate-reviewer-2: ${BRANCH:-?}" --json 2>"$_errf" || echo "{}")
  _err=""
  [ "$_errf" != "/dev/null" ] && { _err=$(tail -c 300 "$_errf" 2>/dev/null | tr '\n' ' '); rm -f "$_errf"; }
  _sid=$(printf '%s' "$_sjson" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  _sname=$(printf '%s' "$_sjson" | jq -r '.session_name // empty' 2>/dev/null || echo "")
  _skey=$(printf '%s' "$_sjson" | jq -r '.session_key // empty' 2>/dev/null || echo "")
  if [ -z "$_sid" ]; then
    gate_e5_decline "spawn-failed:${_err:-no-output}"
    return 1
  fi

  _vb2=$(bd -C "$GC_CITY" create \
    "reviewer-verdict: ${BRANCH:-?} (reviewer 2/2, E5 extra)" \
    -t chore \
    -l type:quality-gate-verdict \
    -l "gate-run:$_run" \
    -l "reviewer-index:2" \
    -l verdict:pending \
    -l e5-extra \
    -l "e5-trigger:$_e5_trig" \
    -d "E5 (ga-syxaki) extra verdict bead: reviewer 2 of 2 on branch ${BRANCH:-?}.
gate_run: $_run
trigger: $_e5_trig
lens: $(gate_e5_extra_lens)
Best-effort by design: if this reviewer does not deliver, the run is decided by reviewer 1 alone." \
    --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")
  if [ -z "$_vb2" ]; then
    gc --city "$GC_CITY" session close "$_sid" 2>/dev/null || true
    gate_e5_decline "verdict-bead-create-failed"
    return 1
  fi

  _task2=$(gate_e5_extra_task "$_task1" "$_vb1" "$_vb2") || _task2=""
  if [ -z "$_task2" ]; then
    gate_e5_abandon_bead "$_vb2" "$_sid" "task-build-failed"
    gate_e5_decline "task-build-failed"
    return 1
  fi

  gc --city "$GC_CITY" session wake "$_sid" 2>/dev/null || true
  gc --city "$GC_CITY" session pin "$_sid" 2>/dev/null || true
  if [ -n "$_sname" ]; then
    if type assign_verdict_bead_verified >/dev/null 2>&1 && assign_verdict_bead_verified "$_vb2" "$_sname" "E5 extra slot"; then _vassign=1; fi
    bd -C "$GC_CITY" comment "$_vb2" "$_task2" 2>/dev/null \
      || warn "  E5: could not embed the task on verdict bead $_vb2 — the durable pull has nothing to read; the queued nudge is the only channel (a reviewer that never starts is retired by the timeout)."
  else
    warn "  E5: extra reviewer spawn JSON had no session_name — durable pull channel NOT wired (nudge + timeout are the only channels)."
  fi
  _peek=$(gc --city "$GC_CITY" session peek "$_sid" --lines 40 2>/dev/null | cksum 2>/dev/null | awk '{print $1}' || echo "")
  if type gate_nudge >/dev/null 2>&1; then
    gate_nudge "$_sid" "$_task2" --delivery queue 2>/dev/null \
      || warn "  E5: initial queue of the extra reviewer's task failed (session $_sid) — the ACK pass / durable pull will retry"
  else
    gc --city "$GC_CITY" session nudge "$_sid" "$_task2" --delivery queue 2>/dev/null || true
  fi

  _n=$(gate_e5_spend_record)
  GATE_E5_EXTRA_VB="$_vb2"; GATE_E5_EXTRA_SID="$_sid"; GATE_E5_EXTRA_SNAME="${_sname:-$_sid}"
  GATE_E5_EXTRA_TASK="$_task2"; GATE_E5_EXTRA_PEEK="$_peek"
  log "  E5: extra reviewer spawned for gate-run $_run (trigger=$_e5_trig): session=$_sid verdict_bead=$_vb2 (extra review #$_n today; assign_verified=$_vassign)"
  gate_e5_log_event e5_extra_spawn gate_run "$_run" bead "${BEAD_ID:-}" trigger "$_e5_trig" \
    extra_vb "$_vb2" session_id "$_sid" session_name "${_sname:-}" session_key "${_skey:-}" \
    extras_today "$_n" est_cost_usd "$GATE_E5_EST_COST_USD"
  return 0
}

# gate_e5_abandon_bead <verdict_bead> <session_id_or_name> <reason> — retire an extra
# verdict bead for good: labelled e5-extra-abandoned (Phase C then ignores it on every
# later sweep), commented, closed, and its session closed. Idempotent; never fails.
gate_e5_abandon_bead() {
  local _vb="$1" _sid="$2" _why="$3"
  bd -C "$GC_CITY" label add "$_vb" "e5-extra-abandoned" -q 2>/dev/null \
    || warn "  E5: could not label $_vb e5-extra-abandoned — it stays counted as a live extra slot and is retired again on the next sweep."
  bd -C "$GC_CITY" label remove "$_vb" "verdict:pending" -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$_vb" "E5 (ga-syxaki): extra reviewer abandoned — $_why. The run is decided by reviewer 1 alone (arm-A behaviour); nothing about this slot counts toward the verdict." 2>/dev/null || true
  bd -C "$GC_CITY" close "$_vb" -r "E5 extra reviewer abandoned: $_why" 2>/dev/null || true
  [ -n "$_sid" ] && { gc --city "$GC_CITY" session close "$_sid" 2>/dev/null || true; }
  return 0
}

# gate_e5_step7_extra — Step 7 glue for the big-diff trigger. Runs right after the main
# spawn loop; appends the extra reviewer to the in-memory slot arrays (so the ACK pass
# covers it) and raises REQUIRED_REVIEWERS for THIS process. The persisted run record keeps
# required_reviewers: 1 — Phase C derives the +1 from the extra verdict bead itself.
gate_e5_step7_extra() {
  local _e5_trig="big-diff"
  if [ "${#VERDICT_BEAD_IDS[@]}" -ne 1 ] || [ "${#REVIEW_TASKS[@]}" -ne 1 ]; then
    gate_e5_decline "base-run-not-single-reviewer"
    return 0
  fi
  if [ "${GATE_SPAWN_STAGGER_SECS:-0}" -gt 0 ] 2>/dev/null; then
    log "  Spawn stagger: settling ${GATE_SPAWN_STAGGER_SECS}s before the E5 extra reviewer (ga-mepb0 boot-herd guard)"
    sleep "$GATE_SPAWN_STAGGER_SECS" || true
  fi
  if gate_e5_spawn_extra "$GATE_RUN_ID" "${VERDICT_BEAD_IDS[0]}" "${REVIEW_TASKS[0]}" "$_e5_trig"; then
    VERDICT_BEAD_IDS+=("$GATE_E5_EXTRA_VB")
    SESSION_IDS+=("$GATE_E5_EXTRA_SID")
    REVIEW_TASKS+=("$GATE_E5_EXTRA_TASK")
    REVIEWER_PEEK_BASELINE+=("$GATE_E5_EXTRA_PEEK")
    REVIEWER_ACKED+=(0)
    REQUIRED_REVIEWERS=2
  fi
  return 0
}

# ── Phase C (a later sweep finalizing the run) ────────────────────────────────
# gate_e5_rehydrate <verdict_beads_json> — right after the dispatcher re-reads the run's
# verdict beads: drop abandoned extra slots from VERDICT_BEAD_IDS and raise
# REQUIRED_REVIEWERS by the number of LIVE extra slots. The state lives on the verdict beads
# (labels), so it survives a dispatcher crash and needs no write to the run bead.
gate_e5_rehydrate() {
  local _vbj="$1" _abandoned _live _id _keep=() _i
  _abandoned=$(printf '%s' "$_vbj" | jq -r '[.[]? | select((.labels // []) | index("e5-extra-abandoned")) | .id] | .[]' 2>/dev/null || echo "")
  _live=$(printf '%s' "$_vbj" | jq -r '[.[]? | select((.labels // []) | index("e5-extra")) | select(((.labels // []) | index("e5-extra-abandoned")) | not)] | length' 2>/dev/null || echo 0)
  case "$_live" in ''|*[!0-9]*) _live=0 ;; esac
  if [ -n "$_abandoned" ] && [ "${#VERDICT_BEAD_IDS[@]}" -gt 0 ]; then
    for _i in "${!VERDICT_BEAD_IDS[@]}"; do
      _id="${VERDICT_BEAD_IDS[$_i]}"
      case "
$_abandoned
" in *"
$_id
"*) continue ;; esac
      _keep+=("$_id")
    done
    VERDICT_BEAD_IDS=()
    for _id in ${_keep[@]+"${_keep[@]}"}; do VERDICT_BEAD_IDS+=("$_id"); done
  fi
  REQUIRED_REVIEWERS=$((REQUIRED_REVIEWERS + _live))
  return 0
}

# gate_e5_bead_status <bead_id> — open|closed|unknown (unknown = could not read; never "open").
gate_e5_bead_status() {
  local _j
  _j=$(bd -C "$GC_CITY" show "$1" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  printf '%s' "$_j" | jq -r 'if type=="array" then .[0] else . end | .status // "unknown"' 2>/dev/null || printf 'unknown'
}

# gate_e5_drop_slot <verdict_bead> — remove one slot from the in-memory arrays (this sweep).
gate_e5_drop_slot() {
  local _vb="$1" _nv=() _ns=() _i
  for _i in "${!VERDICT_BEAD_IDS[@]}"; do
    [ "${VERDICT_BEAD_IDS[$_i]}" = "$_vb" ] && continue
    _nv+=("${VERDICT_BEAD_IDS[$_i]}")
    _ns+=("${SESSION_IDS[$_i]:-}")
  done
  VERDICT_BEAD_IDS=(); SESSION_IDS=()
  local _x
  for _x in ${_nv[@]+"${_nv[@]}"}; do VERDICT_BEAD_IDS+=("$_x"); done
  for _x in ${_ns[@]+"${_ns[@]}"}; do SESSION_IDS+=("$_x"); done
  REQUIRED_REVIEWERS=$((REQUIRED_REVIEWERS - 1))
  [ "$REQUIRED_REVIEWERS" -ge 1 ] || REQUIRED_REVIEWERS=1
}

# gate_e5_first_fail_state <bead_id> — yes | no | unknown: has this source bead had NO judged
# FAIL before? Uses the gate's own counter (gate:fix-attempt:N on the source bead — bumped
# only by a judged FAIL, never by a timeout / dead reviewer / stale sha; an explicit :0 is
# the human reset and wins, exactly as the finalize step reads it). Unreadable -> unknown.
gate_e5_first_fail_state() {
  local _j _labels _att
  _j=$(bd -C "${BEAD_CITY:-$GC_CITY}" show "$1" --json 2>/dev/null) || { printf 'unknown'; return 0; }
  # A not-found / error answer has no labels either — it must read as UNKNOWN, never as
  # "a bead with no fix-attempt label", i.e. never as "first FAIL".
  printf '%s' "$_j" | jq -e --arg id "$1" 'if type=="array" then .[0] else . end | (.id // "") == $id' >/dev/null 2>&1 \
    || { printf 'unknown'; return 0; }
  _labels=$(printf '%s' "$_j" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null) || { printf 'unknown'; return 0; }
  _att=$(printf '%s' "$_labels" | tr ' ' '\n' | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p')
  if [ -z "$_att" ]; then printf 'yes'; return 0; fi
  if printf '%s\n' "$_att" | grep -x 0 >/dev/null; then printf 'yes'; return 0; fi
  printf 'no'
}

# gate_e5_read_task <verdict_bead> — prints the review task the dispatcher embedded as a
# comment on that verdict bead (the first comment that is the task, not a verdict).
gate_e5_read_task() {
  bd -C "$GC_CITY" comments "$1" --json 2>/dev/null | jq -r '
      [ .[]? | (.text // .body // "") | select(test("^QUALITY GATE REVIEW — You are reviewer 1 of 1 for branch:")) ]
      | first // ""' 2>/dev/null || true
}

# gate_e5_phase_c_hook — runs in Phase C after gate_collect_verdicts and the PC_* time math,
# before the decision block. Two jobs, in this order:
#   1. retire an extra reviewer that can no longer help (timeout / dead session / run timed
#      out) so the decision below is taken on the reviewers that DID deliver;
#   2. for arm B, when reviewer 1 has just delivered the bead's first judged FAIL and no
#      extra slot exists yet, spawn reviewer 2 and keep the run in flight.
# Reads: VB_JSON VERDICT_BEAD_IDS SESSION_IDS VERDICTS_RECEIVED ANY_FAIL REQUIRED_REVIEWERS
# GATE_FAIL_NO_EVAL GATE_COLLECT_JUDGED_FAILS PC_ELAPSED PC_TIMEOUT_SECS BEAD_ID GATE_RUN_ID.
# Modifies the slot arrays / REQUIRED_REVIEWERS / collect results when it acts.
gate_e5_phase_c_hook() {
  local _extra_vb _extra_sid _extra_created _why="" _now _created_epoch _sess_json _i _e5_trig="first-fail"
  _extra_vb=$(printf '%s' "${VB_JSON:-[]}" | jq -r '[.[]? | select((.labels // []) | index("e5-extra")) | select(((.labels // []) | index("e5-extra-abandoned")) | not)] | first | .id // empty' 2>/dev/null || echo "")

  if [ -n "$_extra_vb" ]; then
    # ── job 1: is the extra slot still worth waiting for? ──
    local _closed=0
    case "$(gate_e5_bead_status "$_extra_vb")" in
      closed)
        # Closed WITH a verdict: delivered, the collect counted it — nothing to do. Closed
        # WITHOUT one (the collect flagged it undelivered): it can never deliver, retire it
        # so the run is decided on the reviewers that did.
        [ "${GATE_E5_EXTRA_UNDELIVERED:-0}" = "1" ] || return 0
        _closed=1 ;;
      open|in_progress|blocked|hooked|pinned) : ;;
      *) return 0 ;;                            # unreadable: leave it; nothing is decided on a guess
    esac
    _extra_created=$(printf '%s' "$VB_JSON" | jq -r --arg v "$_extra_vb" '[.[]? | select(.id==$v)] | first | .created_at // empty' 2>/dev/null || echo "")
    _created_epoch=""
    [ -n "$_extra_created" ] && _created_epoch=$(_ts_to_epoch "$_extra_created" 2>/dev/null || echo "")
    _now=$(date +%s)
    _extra_sid=""
    for _i in "${!VERDICT_BEAD_IDS[@]}"; do
      [ "${VERDICT_BEAD_IDS[$_i]}" = "$_extra_vb" ] && _extra_sid="${SESSION_IDS[$_i]:-}"
    done
    if [ "$_closed" = "1" ]; then
      _why="extra-closed-without-verdict"
    elif [ "${PC_ELAPSED:-0}" -gt "${PC_TIMEOUT_SECS:-0}" ] 2>/dev/null; then
      _why="run-timeout"
    else
      case "$_created_epoch" in
        ''|*[!0-9]*) _why="extra-age-unreadable" ;;
        *) if [ $((_now - _created_epoch)) -gt "${PC_TIMEOUT_SECS:-0}" ]; then _why="extra-timeout"; fi ;;
      esac
    fi
    if [ -z "$_why" ] && [ -n "$_extra_sid" ] && [ "$_extra_sid" != "__UNKNOWN__" ]; then
      _sess_json=$(gc_json_or_unknown gc --city "$GC_CITY" session list --json) || true
      if [ -n "$_sess_json" ] && [ "$(reviewer_session_confirmed_closed "$_extra_sid" "$_sess_json")" = "1" ]; then
        _why="extra-session-closed"
      fi
    fi
    if [ -n "$_why" ]; then
      warn "  E5: retiring the extra reviewer of gate-run ${GATE_RUN_ID:-?} ($_why) — deciding on the reviewer(s) that delivered, as arm A does."
      gate_e5_abandon_bead "$_extra_vb" "$_extra_sid" "$_why"
      gate_e5_log_event e5_extra_abandoned gate_run "${GATE_RUN_ID:-}" bead "${BEAD_ID:-}" extra_vb "$_extra_vb" reason "$_why"
      gate_e5_drop_slot "$_extra_vb"
      gate_collect_verdicts
    fi
    return 0
  fi

  # ── job 2: the first-fail trigger ──
  # Any e5-extra bead at all (even an abandoned one) means this run already had its one
  # attempt — never a second spawn for the same run.
  if [ -n "$(printf '%s' "${VB_JSON:-[]}" | jq -r '[.[]? | select((.labels // []) | index("e5-extra"))] | first | .id // empty' 2>/dev/null || echo "")" ]; then
    return 0
  fi
  [ "$(gate_e5_enabled)" = "1" ] || return 0
  [ "$(gate_e5_arm_for_bead "${BEAD_ID:-}")" = "B" ] || return 0
  [ "${#VERDICT_BEAD_IDS[@]}" -eq 1 ] || return 0
  # Only a run whose single reviewer delivered a real, judged FAIL. A no-verdict FAIL (dead
  # reviewer, timeout) is infrastructure, not a rejection, and gets its own requeue path.
  [ "${VERDICTS_RECEIVED:-0}" -eq "${REQUIRED_REVIEWERS:-1}" ] 2>/dev/null || return 0
  [ "${ANY_FAIL:-0}" = "1" ] || return 0
  [ "${GATE_FAIL_NO_EVAL:-0}" = "0" ] || return 0
  [ "${GATE_COLLECT_JUDGED_FAILS:-0}" -ge 1 ] 2>/dev/null || return 0

  case "$(gate_e5_first_fail_state "${BEAD_ID:-}")" in
    yes) : ;;
    no)  gate_e5_decline "not-first-fail"; return 0 ;;
    *)   gate_e5_decline "first-fail-unreadable"; return 0 ;;
  esac
  if [ "${PC_ELAPSED:-0}" -gt "${PC_TIMEOUT_SECS:-0}" ] 2>/dev/null; then
    gate_e5_decline "run-already-timed-out"; return 0
  fi
  local _task1
  _task1=$(gate_e5_read_task "${VERDICT_BEAD_IDS[0]}")
  if gate_e5_spawn_extra "${GATE_RUN_ID:-}" "${VERDICT_BEAD_IDS[0]}" "$_task1" "$_e5_trig"; then
    VERDICT_BEAD_IDS+=("$GATE_E5_EXTRA_VB")
    SESSION_IDS+=("$GATE_E5_EXTRA_SNAME")
    REQUIRED_REVIEWERS=$((REQUIRED_REVIEWERS + 1))
  fi
  return 0
}

# gate_e5_union_reasons — call at the end of gate_collect_verdicts. Takes the FAIL comments
# gathered in GATE_E5_FAIL_IDX / GATE_E5_FAIL_TXT (index-aligned) and, for a run that has an
# E5 extra slot and >= 2 judged FAIL comments, replaces FAIL_REASONS with the deduplicated
# union. ANY failure (no python, bad JSON, empty answer, answer that lost the
# "Reviewer N FAIL:" prefix the watchdogs parse) leaves FAIL_REASONS exactly as the legacy
# concatenation built it: duplicated text is noise, a lost finding is a defect.
GATE_E5_FAIL_IDX=(); GATE_E5_FAIL_TXT=(); GATE_E5_UNION_STATS=""
gate_e5_union_reasons() {
  GATE_E5_UNION_STATS=""
  [ "${#GATE_E5_FAIL_IDX[@]}" -ge 2 ] || return 0
  local _py _script _payload _out _text _i _lines=""
  _script="${GATE_E5_UNION_SCRIPT:-${GC_CITY:-}/packs/town-deltas/assets/gate-e5-union.py}"
  [ -r "$_script" ] || { warn "  E5: union script unreadable ($_script) — keeping the concatenated FAIL text."; return 0; }
  _py=$(command -v python3 2>/dev/null || echo "")
  [ -n "$_py" ] || { warn "  E5: python3 not found — keeping the concatenated FAIL text."; return 0; }
  _payload="[]"
  for _i in "${!GATE_E5_FAIL_IDX[@]}"; do
    _payload=$(printf '%s' "$_payload" | jq -c --argjson idx "${GATE_E5_FAIL_IDX[$_i]}" --arg txt "${GATE_E5_FAIL_TXT[$_i]}" '. + [{index: $idx, text: $txt}]' 2>/dev/null) || { warn "  E5: could not build the union payload — keeping the concatenated FAIL text."; return 0; }
  done
  _out=$(printf '%s' "{\"reviewers\": $_payload}" | "$_py" "$_script" 2>/dev/null) || { warn "  E5: union script failed — keeping the concatenated FAIL text."; return 0; }
  _text=$(printf '%s' "$_out" | jq -r '.text // empty' 2>/dev/null || echo "")
  case "$_text" in
    "Reviewer "[0-9]*" FAIL:"*) : ;;
    *) warn "  E5: union answer malformed — keeping the concatenated FAIL text."; return 0 ;;
  esac
  FAIL_REASONS="${_text}\n"
  GATE_E5_UNION_STATS=$(printf '%s' "$_out" | jq -c '.stats // {}' 2>/dev/null || echo "")
  log "  E5: union of ${#GATE_E5_FAIL_IDX[@]} independent FAIL verdicts: ${GATE_E5_UNION_STATS:-?}"
  return 0
}
