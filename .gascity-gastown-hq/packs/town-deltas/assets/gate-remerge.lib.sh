#!/usr/bin/env bash
# gate-remerge.lib.sh — ga-mzw9dt: content the reviewers APPROVED that failed only at the merge goes back in WITHOUT a new review.
#
# WHY. 12/10, .gc/quality-gate.jsonl: 75 reviews = 40 PASS, 28 rejected on the code, 7 APPROVED and then lost at the merge (push race,
# merge-time rebase, merge-time conflict). A PASS that failed at the merge came back as needs-fix/needs-rebase, and the re-submission paid a
# COMPLETE new review for content nobody had changed.
#
# WHAT. A run that had reviewers, ended ALL-PASS and failed at the merge stamps the approved commit on the source bead: label
# `gate-approved:<sha>:<epoch>`. At the next claim of that bead, before any reviewer is spawned, this lib asks one question: does the tip land,
# on today's main, exactly what that commit would land? Both are merged onto the current main with `git merge-tree --write-tree` (the three-way
# merge a rebase uses); the answer is yes only when both merge CLEANLY to the SAME TREE. That covers the tip being the approved commit and the
# tip being its mechanical rebase (dispatcher, author or autorebase), and nothing else: an added line, a moved line, a conflict a person resolved
# (a different tree), a commit on top — all a normal review. An approved commit that itself conflicts with main is the "real conflict" and
# hands off as it always did. (The fast lane's rebase-stable diff digest was NOT used: it drops hunk headers, so the same lines at another
# position read as equal — fine for a doc/test lane that runs its tests, not for code that was approved at a position.)
# On a yes the run asks for ZERO reviewers, re-runs only the tests the diff adds or changes (gate_fastlane_run_tests), and goes through the SAME
# gate_finalize_run as a reviewed run. Right before the push, do_merge_ff asks gate_remerge_confirm the same question about the commit that is
# about to land. The marker gets 'remerge sem nova revisão' (comment + metadata gate.remerge) and the jsonl a `gate_remerge` event for every
# bead that carried an approval, granted AND declined, with the code.
#
# TRUST. The label is writable by any agent (`bd label add`), and on its own it would grant a merge with no reviewer. So it is only a POINTER:
# gate_remerge_stamp first appends a `gate_approval` event {sha, epoch} to the dispatcher's own log (quality-gate.jsonl), and
# gate_remerge_decide grants only when that record exists for the label's exact sha + epoch. A label with no record is `approval-unverified`:
# the normal gate. Said plainly: every agent runs as the same OS user, so this raises the bar from one `bd` command to forging a line in the
# dispatcher's log; it is not a cryptographic barrier.
#
# THE ONE RULE (same as the fast lane): this only ever GRANTS, never a verdict. Three states — yes / no / could not tell — and the last
# one is the NO: a label that cannot be read, an approved commit git no longer has, a merge-tree that errors, a clock that cannot be
# read, a kill switch whose location is unknown, tests that cannot run: all end in the normal gate, which is today's behavior.
#
# Source-only: defines functions, runs NOTHING at source time. The dispatcher is `set -euo pipefail` on macOS bash 3.2: no arrays, no
# ${v,,}, every command that may fail is guarded. Needs gate-fastlane.lib.sh (classify_raw, run_tests) loaded first; without it
# gate_remerge_decide says so and declines.
#
# Outputs of gate_remerge_decide / gate_remerge_confirm (globals):
#   GATE_REMERGE         1 only for a clean yes; 0 otherwise
#   GATE_REMERGE_CODE    a short stable token (granted-exact | granted-rebase | no-approval | switched-off | expired | approval-unreadable |
#                        object-missing | real-conflict | content-changed | cannot-compare | approval-unverified | tests-failed | tests-unrunnable |
#                        tests-cannot-run | lib-missing) — what the tally buckets on; confirm adds revoked-* in GATE_REMERGE_CONFIRM_CODE
#   GATE_REMERGE_WHY     one line for people
#   GATE_REMERGE_SHA     the approved commit
#   GATE_REMERGE_LABEL   the approval label as read (so a revocation can remove exactly it)
#   GATE_REMERGE_AGE_S   seconds since the approval was stamped ("" when unknown)

GATE_REMERGE_LABEL_PREFIX="gate-approved:"

# gate_remerge_label <sha> <epoch> — the ONLY place the approval label's shape is spelled out (write and read sites cannot drift).
gate_remerge_label() {
  printf '%s%s:%s' "$GATE_REMERGE_LABEL_PREFIX" "$1" "$2"
}

# gate_remerge_parse_labels <space-joined labels> — pure. Looks for approval labels and takes the NEWEST well-formed one.
# Sets GATE_RM_LABEL / GATE_RM_SHA / GATE_RM_EPOCH. Returns 0 found, 1 none at all, 2 an approval label is present but none is well-formed
# (the sha is 40 or 64 hex, the epoch digits only) — "could not tell", which the caller treats as the normal gate.
gate_remerge_parse_labels() {
  local w best_e=-1 e sha seen=0
  GATE_RM_LABEL=""; GATE_RM_SHA=""; GATE_RM_EPOCH=""
  for w in $1; do
    case "$w" in "$GATE_REMERGE_LABEL_PREFIX"*) ;; *) continue ;; esac
    seen=1
    sha="${w#"$GATE_REMERGE_LABEL_PREFIX"}"; e="${sha#*:}"; sha="${sha%%:*}"
    case "$sha" in ''|*[!0-9a-f]*) continue ;; esac
    case "${#sha}" in 40|64) ;; *) continue ;; esac
    case "$e" in ''|*[!0-9]*|*:*) continue ;; esac
    if [ "$e" -gt "$best_e" ] 2>/dev/null; then
      best_e="$e"; GATE_RM_LABEL="$w"; GATE_RM_SHA="$sha"; GATE_RM_EPOCH="$e"
    fi
  done
  if [ -n "$GATE_RM_LABEL" ]; then return 0; fi
  if [ "$seen" = "1" ]; then return 2; fi
  return 1
}

# _gate_remerge_is_off — 0 (with GATE_RM_OFF_CODE / GATE_RM_OFF_WHY) when an operator switched this off, 1 when it is on. Same shape as the
# fast lane's switch: `touch <city>/.gc/gate-remerge.off` stops it instantly (the dispatcher is a fresh process every sweep) and removing
# the file re-enables it; GATE_REMERGE_ENABLED=0 does the same from the environment. A switch whose LOCATION cannot be found answers "off".
_gate_remerge_is_off() {
  local flag
  GATE_RM_OFF_CODE=""; GATE_RM_OFF_WHY=""
  if [ "${GATE_REMERGE_ENABLED:-1}" != "1" ]; then
    GATE_RM_OFF_CODE="disabled"; GATE_RM_OFF_WHY="remerge disabled (GATE_REMERGE_ENABLED=0)"; return 0
  fi
  flag="${GATE_REMERGE_OFF_FILE:-}"
  if [ -z "$flag" ] && [ -n "${GC_CITY:-}" ]; then flag="$GC_CITY/.gc/gate-remerge.off"; fi
  if [ -z "$flag" ]; then
    GATE_RM_OFF_CODE="switch-unreadable"; GATE_RM_OFF_WHY="remerge cannot find its kill switch (GC_CITY and GATE_REMERGE_OFF_FILE are both unset) — a switch that cannot be read is not a switch that is off, normal gate"; return 0
  fi
  if [ -e "$flag" ]; then
    GATE_RM_OFF_CODE="flag-file"; GATE_RM_OFF_WHY="remerge switched off by the flag file (.gc/gate-remerge.off) — normal gate"; return 0
  fi
  return 1
}

# _gate_remerge_merged_tree <git_fn> <main> <commit> — prints the tree git would produce merging <commit> onto <main>. Return 0 clean (tree
# printed), 1 conflict, 2 could not tell (git error, no tree printed).
_gate_remerge_merged_tree() {
  local git_fn="$1" main="$2" commit="$3" out rc=0 t
  out=$("$git_fn" merge-tree --write-tree "$main" "$commit" 2>/dev/null) || rc=$?
  case "$rc" in
    0) t=$(printf '%s\n' "$out" | head -n 1) || t=""
       case "$t" in ''|*[!0-9a-f]*) return 2 ;; esac
       case "${#t}" in 40|64) ;; *) return 2 ;; esac
       printf '%s' "$t"; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# gate_remerge_same_landing <git_fn> <main_ref> <approved_sha> <head_ref> — does the head land what the approved commit would land on
# <main_ref>? Sets GATE_RM_SAME to exact | rebase | real-conflict | content-changed | object-missing | cannot-compare. Returns 0 only for
# exact / rebase. Every other answer — including the ones that mean "could not tell" — is 1.
#   exact           the head IS the approved commit AND that commit merges cleanly onto main (identity alone is not a landing: an approved
#                   commit that conflicts with today's main lands nothing, and the conflict hand-off must stay what it always was)
#   rebase          both merge cleanly onto main and to the same tree (the head is the approved content, mechanically carried)
#   real-conflict   the approved commit itself conflicts with main: the hand-off case, a person resolves it and that is new content
#   content-changed the head merges to a different tree (or conflicts where the approved commit did not)
gate_remerge_same_landing() {
  local git_fn="$1" main="$2" approved="$3" head="$4" ac hc ta th rc=0
  GATE_RM_SAME="cannot-compare"
  if [ -z "$git_fn" ] || [ -z "$main" ] || [ -z "$approved" ] || [ -z "$head" ]; then return 1; fi
  ac=$("$git_fn" rev-parse --verify -q "${approved}^{commit}" 2>/dev/null) || ac=""
  if [ -z "$ac" ]; then GATE_RM_SAME="object-missing"; return 1; fi
  hc=$("$git_fn" rev-parse --verify -q "${head}^{commit}" 2>/dev/null) || hc=""
  if [ -z "$hc" ]; then return 1; fi
  ta=$(_gate_remerge_merged_tree "$git_fn" "$main" "$ac") || rc=$?
  case "$rc" in
    0) ;;
    1) GATE_RM_SAME="real-conflict"; return 1 ;;
    *) return 1 ;;
  esac
  if [ "$ac" = "$hc" ]; then GATE_RM_SAME="exact"; return 0; fi
  rc=0
  th=$(_gate_remerge_merged_tree "$git_fn" "$main" "$hc") || rc=$?
  case "$rc" in
    0) ;;
    1) GATE_RM_SAME="content-changed"; return 1 ;;
    *) return 1 ;;
  esac
  if [ -n "$ta" ] && [ "$ta" = "$th" ]; then GATE_RM_SAME="rebase"; return 0; fi
  GATE_RM_SAME="content-changed"
  return 1
}

_gate_remerge_no() {   # <code> <why> — the inert outcome. Always returns 0.
  GATE_REMERGE=0; GATE_REMERGE_CODE="$1"; GATE_REMERGE_WHY="$2"
  return 0
}

# _gate_remerge_approval_recorded <qg_log> <sha> <epoch> — 0 iff the dispatcher's log holds the gate_approval event for exactly this approval.
# A log that is missing, unreadable or without the event is 1: "not on record" and "could not read the record" are the same NO. Lines that are
# not JSON are skipped (`fromjson?`), so one bad line cannot blind the check.
_gate_remerge_approval_recorded() {
  [ -n "${1:-}" ] && [ -r "$1" ] || return 1
  grep -F -- "$2" "$1" 2>/dev/null | jq -R -e --arg s "$2" --argjson e "$3" 'fromjson? | select(.event == "gate_approval" and .sha == $s and .epoch == $e)' >/dev/null 2>&1
}

# gate_remerge_decide <git_fn> <main_ref> <head_sha> <labels> <now_epoch> [qg_log] — the claim-time decision. <labels> is the source bead's labels,
# space-joined, or the literal `?` when they could not be read. Always returns 0 (the answer is in the globals); GATE_REMERGE=1 only on a
# clean yes. A bead with no approval label is the ordinary first review: code no-approval, and the caller records nothing.
gate_remerge_decide() {
  local git_fn="$1" main="$2" head="$3" labels="$4" now="$5" qg_log="${6:-}" prc=0 age ttl raw raw_rc=0 saved_max saved_budget
  GATE_REMERGE=0; GATE_REMERGE_CODE="no-approval"; GATE_REMERGE_WHY="no approval is on record for this bead — the ordinary first review"
  GATE_REMERGE_SHA=""; GATE_REMERGE_LABEL=""; GATE_REMERGE_AGE_S=""; GATE_REMERGE_TEST_OUT=""
  if [ "$labels" = "?" ]; then
    _gate_remerge_no "approval-unreadable" "the source bead's labels could not be read — cannot tell whether an approval is on record, normal gate"; return 0
  fi
  gate_remerge_parse_labels "$labels" || prc=$?
  case "$prc" in
    0) ;;
    1) return 0 ;;
    *) _gate_remerge_no "approval-unreadable" "an approval label is on the bead but none is well-formed (gate-approved:<40|64 hex sha>:<epoch>) — cannot tell what was approved, normal gate"; return 0 ;;
  esac
  GATE_REMERGE_SHA="$GATE_RM_SHA"; GATE_REMERGE_LABEL="$GATE_RM_LABEL"
  # from here on an approval EXISTS: every outcome is recorded by the caller, granted or declined
  if _gate_remerge_is_off; then _gate_remerge_no "switched-off" "$GATE_RM_OFF_WHY"; return 0; fi
  if ! declare -F gate_fastlane_classify_raw >/dev/null 2>&1 || ! declare -F gate_fastlane_run_tests >/dev/null 2>&1; then
    _gate_remerge_no "lib-missing" "gate-fastlane.lib.sh (test classification and runner) is not loaded — the directed tests cannot be re-run, normal gate"; return 0
  fi
  case "$now" in ''|*[!0-9]*) _gate_remerge_no "cannot-compare" "the clock could not be read — the age of the approval is unknown, normal gate"; return 0 ;; esac
  if [ "$GATE_RM_EPOCH" -gt $((now + 300)) ] 2>/dev/null; then
    _gate_remerge_no "approval-unreadable" "the approval is stamped in the future (epoch $GATE_RM_EPOCH, now $now) — cannot tell, normal gate"; return 0
  fi
  age=$((now - GATE_RM_EPOCH)); [ "$age" -ge 0 ] 2>/dev/null || age=0
  GATE_REMERGE_AGE_S="$age"
  ttl="${GATE_REMERGE_TTL_SECS:-604800}"
  case "$ttl" in ''|*[!0-9]*) ttl=604800 ;; esac
  if [ "$age" -gt "$ttl" ] 2>/dev/null; then
    _gate_remerge_no "expired" "the approval is ${age}s old (limit ${ttl}s) — an approval is not forever, normal gate"; return 0
  fi
  if ! _gate_remerge_approval_recorded "$qg_log" "$GATE_REMERGE_SHA" "$GATE_RM_EPOCH"; then
    _gate_remerge_no "approval-unverified" "the approval label on the bead (${GATE_REMERGE_SHA:0:12}) has no matching gate_approval record in the dispatcher's log — a label alone is not proof the reviewers approved it, normal gate"; return 0
  fi

  if ! gate_remerge_same_landing "$git_fn" "$main" "$GATE_REMERGE_SHA" "$head"; then
    case "$GATE_RM_SAME" in
      object-missing)  _gate_remerge_no "object-missing"  "the approved commit ${GATE_REMERGE_SHA:0:12} is no longer in the repository — cannot compare, normal gate" ;;
      real-conflict)   _gate_remerge_no "real-conflict"   "the approved commit ${GATE_REMERGE_SHA:0:12} conflicts with $main — a real conflict is resolved by a person, and what they wrote was not reviewed; normal gate" ;;
      content-changed) _gate_remerge_no "content-changed" "what this tip would land on $main is not what the approved commit ${GATE_REMERGE_SHA:0:12} would land — the content changed since the approval; normal gate" ;;
      *)               _gate_remerge_no "cannot-compare"  "git could not compare the tip with the approved commit ${GATE_REMERGE_SHA:0:12} — cannot tell, normal gate" ;;
    esac
    return 0
  fi
  local landing="$GATE_RM_SAME"

  # The directed tests: the tests the diff itself adds or changes, run on the tip (the same runner and the same scrubbed environment as
  # the fast lane's). The full-suite check (.gate-full-suite.sh, opt-in per rig) still runs in gate_finalize_run, as for any reviewed run.
  raw=$("$git_fn" -c core.quotepath=off diff --raw --no-renames "$main...$head" 2>/dev/null) || raw_rc=$?
  if [ "$raw_rc" != "0" ] || [ -z "$raw" ]; then
    _gate_remerge_no "cannot-compare" "git diff --raw of the tip against $main failed or came back empty (rc=$raw_rc) — the tests to re-run cannot be listed, normal gate"; return 0
  fi
  gate_fastlane_classify_raw "$raw"
  if [ "${GATE_FL_STATE:-}" != "ok" ]; then
    _gate_remerge_no "cannot-compare" "the diff could not be classified (${GATE_FL_WHY:-no detail}) — the tests to re-run cannot be listed, normal gate"; return 0
  fi
  if [ -n "${GATE_FL_UNRUNNABLE:-}" ]; then
    _gate_remerge_no "tests-unrunnable" "a test this diff changes has no runner here ($(printf '%s' "$GATE_FL_UNRUNNABLE" | head -n 3 | tr '\n' ' ')) — it cannot be re-run, normal gate"; return 0
  fi
  saved_max="${GATE_FASTLANE_TEST_MAX_FILES-}"; saved_budget="${GATE_FASTLANE_TEST_BUDGET_SECS-}"
  GATE_FASTLANE_TEST_MAX_FILES="${GATE_REMERGE_TEST_MAX_FILES:-10}"
  GATE_FASTLANE_TEST_BUDGET_SECS="${GATE_REMERGE_TEST_BUDGET_SECS:-150}"
  gate_fastlane_run_tests "$git_fn" "$head" "${GATE_FL_RUN:-}"
  GATE_FASTLANE_TEST_MAX_FILES="$saved_max"; GATE_FASTLANE_TEST_BUDGET_SECS="$saved_budget"
  [ -n "$saved_max" ] || unset GATE_FASTLANE_TEST_MAX_FILES
  [ -n "$saved_budget" ] || unset GATE_FASTLANE_TEST_BUDGET_SECS
  GATE_REMERGE_TEST_OUT="${GATE_FL_TEST_OUT:-}"
  case "${GATE_FL_TEST_RC:-2}" in
    0) ;;
    1) _gate_remerge_no "tests-failed" "a directed test FAILED on the approved content as it stands now: ${GATE_REMERGE_TEST_OUT} — normal gate (the reviewers will see it)"; return 0 ;;
    *) _gate_remerge_no "tests-cannot-run" "the directed tests could not be run: ${GATE_REMERGE_TEST_OUT:-no detail} — normal gate"; return 0 ;;
  esac

  GATE_REMERGE=1
  if [ "$landing" = "exact" ]; then GATE_REMERGE_CODE="granted-exact"; else GATE_REMERGE_CODE="granted-rebase"; fi
  if [ "$landing" = "exact" ]; then
    GATE_REMERGE_WHY="the tip IS the commit the reviewers approved (${GATE_REMERGE_SHA:0:12}, approved ${GATE_REMERGE_AGE_S}s ago); directed tests: ${GATE_REMERGE_TEST_OUT:-none}."
  else
    GATE_REMERGE_WHY="the tip lands exactly what the approved commit ${GATE_REMERGE_SHA:0:12} lands on $main (approved ${GATE_REMERGE_AGE_S}s ago); directed tests: ${GATE_REMERGE_TEST_OUT:-none}."
  fi
  return 0
}

# gate_remerge_confirm <git_fn> <main_sha> <head_sha> — asked IMMEDIATELY before the push, with the commit that is about to be pushed and the
# main it fast-forwards from. Returns 0 only for a clean yes: remerge still on, and the commit lands what the approved commit lands. Anything
# else returns 1 with GATE_REMERGE=0 and the cause in GATE_REMERGE_CONFIRM_CODE / _WHY; the caller does NOT turn a no into a FAIL — it
# re-queues the marker to the normal gate.
gate_remerge_confirm() {
  local git_fn="$1" main="$2" head="$3"
  GATE_REMERGE_CONFIRM_CODE=""; GATE_REMERGE_CONFIRM_WHY=""
  if [ "${GATE_REMERGE:-0}" != "1" ] || [ -z "${GATE_REMERGE_SHA:-}" ]; then
    GATE_REMERGE=0; GATE_REMERGE_CONFIRM_CODE="cannot-confirm"; GATE_REMERGE_CONFIRM_WHY="no remerge decision with an approved commit is on record in this run"; return 1
  fi
  if _gate_remerge_is_off; then
    GATE_REMERGE=0; GATE_REMERGE_CONFIRM_CODE="switched-off"; GATE_REMERGE_CONFIRM_WHY="remerge was switched off after it was granted: ${GATE_RM_OFF_WHY}"; return 1
  fi
  if gate_remerge_same_landing "$git_fn" "$main" "$GATE_REMERGE_SHA" "$head"; then return 0; fi
  GATE_REMERGE=0
  case "$GATE_RM_SAME" in
    content-changed|real-conflict) GATE_REMERGE_CONFIRM_CODE="content-changed"; GATE_REMERGE_CONFIRM_WHY="the commit about to be pushed does not land what the approved commit ${GATE_REMERGE_SHA:0:12} lands on $main (${GATE_RM_SAME})" ;;
    object-missing)                GATE_REMERGE_CONFIRM_CODE="cannot-confirm"; GATE_REMERGE_CONFIRM_WHY="the approved commit ${GATE_REMERGE_SHA:0:12} is no longer in the repository" ;;
    *)                             GATE_REMERGE_CONFIRM_CODE="cannot-confirm"; GATE_REMERGE_CONFIRM_WHY="git could not compare the commit about to be pushed with the approved commit ${GATE_REMERGE_SHA:0:12}" ;;
  esac
  return 1
}

# gate_remerge_stamp <city> <bead> <sha> <epoch> <qg_log> — writes the dispatcher's own record of the approval FIRST (the label is only a
# pointer to it, see TRUST), then the label, and READS THE LABEL BACK ("the command ran" is not "the label is there"). Returns 0 iff both are
# there. A failed stamp costs only the optimization: the next submission is an ordinary review.
gate_remerge_stamp() {
  local city="$1" bead="$2" sha="$3" epoch="$4" qg_log="${5:-}" label back="" old
  [ -n "$city" ] && [ -n "$bead" ] && [ -n "$sha" ] && [ -n "$qg_log" ] || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$(dirname "$qg_log")" 2>/dev/null || true
  jq -c -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg bead "$bead" --arg sha "$sha" --argjson epoch "$epoch" \
    '{ts: $ts, event: "gate_approval", bead: $bead, sha: $sha, epoch: $epoch}' >> "$qg_log" 2>/dev/null || return 1
  label=$(gate_remerge_label "$sha" "$epoch")
  bd -C "$city" label add "$bead" "$label" -q >/dev/null 2>&1 || true
  back=$(bd -C "$city" show "$bead" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null) || back=""
  case " $back " in *" $label "*) ;; *) return 1 ;; esac
  # One approval at a time: an older one for another commit is superseded (decide would take the newest anyway; this only keeps the bead's
  # label list from growing with every failed merge). Best effort — a label that stays is harmless.
  for old in $back; do
    case "$old" in "$GATE_REMERGE_LABEL_PREFIX"*) ;; *) continue ;; esac
    [ "$old" = "$label" ] && continue
    bd -C "$city" label remove "$bead" "$old" -q >/dev/null 2>&1 || true
  done
  return 0
}

# gate_remerge_unstamp <city> <bead> <label> — takes the approval label off (a remerge that was granted and then revoked at the push CONSUMES
# the approval: the next claim is an ordinary review, which is what makes a revocation that keeps happening converge instead of looping).
# Reads back; returns 0 iff the label is gone. A label that cannot be removed costs a repeat revocation, never a wrong merge.
gate_remerge_unstamp() {
  local city="$1" bead="$2" label="$3" back=""
  [ -n "$city" ] && [ -n "$bead" ] && [ -n "$label" ] || return 1
  bd -C "$city" label remove "$bead" "$label" -q >/dev/null 2>&1 || true
  back=$(bd -C "$city" show "$bead" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' 2>/dev/null) || return 1
  case " $back " in *" $label "*) return 1 ;; esac
  return 0
}

# gate_remerge_record <city> <marker> <bead> <branch> <rig> <qg_log> <would_have_reviewers> <decision> [head_sha] — decision is granted | declined |
# revoked (granted, then withdrawn at the push). Observability only: a failed write is said on stderr and never changes the decision.
# Writes the marker's metadata (gate.remerge, gate.remerge_reason) and appends one `gate_remerge` event (decision, code, approved and claimed
# commit, approval age, reviewers a normal run would have used, dry_run) to the jsonl the count is read from. The comment is the caller's.
gate_remerge_record() {
  local city="$1" marker="$2" bead="$3" branch="$4" rig="$5" qg_log="$6" would="$7" decision="$8" head="${9:-}" back="" want
  case "$would" in ''|*[!0-9]*) would=null ;; esac
  # The marker is written for a grant (gate.remerge=1) and for a revocation at the push (gate.remerge=0: the grant it carried is withdrawn,
  # and neither the marker nor the count may keep saying "remerge" for a run that merged nothing). A plain decline never set anything.
  if [ -n "$marker" ] && { [ "$decision" = "granted" ] || [ "$decision" = "revoked" ]; }; then
    want=1; [ "$decision" = "granted" ] || want=0
    bd -C "$city" update "$marker" --set-metadata "gate.remerge=$want" -q >/dev/null 2>&1 || true
    if [ "$want" = "1" ]; then
      bd -C "$city" update "$marker" --set-metadata "gate.remerge_reason=remerge sem nova revisão: $(printf '%s' "$GATE_REMERGE_WHY" | cut -c1-280)" -q >/dev/null 2>&1 || true
    else
      bd -C "$city" update "$marker" --set-metadata "gate.remerge_reason=remerge revoked at the push: $(printf '%s' "$GATE_REMERGE_WHY" | cut -c1-270)" -q >/dev/null 2>&1 || true
    fi
    back=$(bd -C "$city" show "$marker" --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .metadata["gate.remerge"] // ""' 2>/dev/null) || back=""
    if [ "$back" != "$want" ]; then
      echo "[gate-remerge] WARN: gate.remerge=$want NOT confirmed on marker $marker after write (read back: '${back:-unreadable}') — the jsonl event below is still written" >&2
    fi
  fi
  if [ -n "$qg_log" ]; then
    mkdir -p "$(dirname "$qg_log")" 2>/dev/null || true
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg decision "$decision" --arg code "${GATE_REMERGE_CODE:-}" --arg reason "${GATE_REMERGE_WHY:-}" \
      --arg branch "$branch" --arg bead "$bead" --arg rig "${rig:-unknown}" --arg marker "$marker" \
      --arg approved "${GATE_REMERGE_SHA:-}" --arg head "$head" --arg age "${GATE_REMERGE_AGE_S:-}" \
      --arg dry_run "${DRY_RUN:-0}" --argjson would "$would" \
      '{ts: $ts, event: "gate_remerge", decision: $decision, code: $code, reason: $reason, branch: $branch, bead: $bead, rig: $rig,
        marker: $marker, approved_sha: $approved, head_sha: $head, approved_age_s: (if $age == "" then null else ($age | tonumber? // null) end),
        would_have_reviewers: $would, dry_run: $dry_run}' \
      >> "$qg_log" 2>/dev/null \
      || echo "[gate-remerge] WARN: could not append the gate_remerge event to $qg_log — the count will miss this decision" >&2
  fi
  return 0
}
