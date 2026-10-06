#!/usr/bin/env bash
# gate-q8tj7p-queue-order.selftest.sh (ga-q8tj7p, 2026-10-06)
#
# Proves the gate queue order Athos decided on 2026-10-06 (AskUserQuestion in the
# Mayor's session), verbatim: "A regra deve ser: prioridade > tipo (feature
# primeiro) > idade. ou seja, primeiro todas p0 feature, começando pelas mais
# antigas. Depois, todas p0 que nao sao feature, começando pelas mais antigas.
# Depois vai pra p1 revisando as features mais antigas. Quando terminar todas,
# vai pras p1 que nao sao feature começando pelas mais antigas. Assim por diante."
#
# Before: emergency >90min (FIFO) -> fresh slot every 10 sweeps -> priority
# authors -> aged -> smallest-diff -> rebase-fail. Measured 06/10: 9 of 14 markers
# were >90min old, so the queue was pure FIFO and gate:priority changed nothing
# (a P0 was 9th in line).
#
# Part A runs the LIVE marker-select block (extracted by its sentinels, never a
# hand copy) over markers carrying the `.src_class` annotation that Step 0b-1
# writes, and checks the complete order. Part B runs the LIVE gate-src-class
# block (the enrichment) against a stubbed `bd show`: one batched read per store,
# and the THREE states of a source-bead read — read / not-there / could-not-read —
# never collapse into one another (a bead that cannot be read must not become P2
# and above all must not become P0).
#
# ga-emgkvn (2026-10-06, Athos's decision in the ga-9t9acg thread, 22:29): ONE exception to
# that rule. A P0 *bug* whose source bead carries the label `impacto:dano-ao-vivo` (a customer
# is being hurt right now) goes BEFORE the P0 features. Classes inside a priority become
# [dano-ao-vivo] -> [feature] -> [other], oldest first inside each; P1 and below are untouched.
# Three states for the label, never collapsed: have it / do not have it / could not read the
# labels. The last one is treated as WITHOUT the label (no promotion) and is WARNed about.
# The label counts on a P0 bug only; on anything else it is ignored and the sweep logs that.
# Sections A18-A26 (the order) and B12-B17 (the enrichment) are the ga-emgkvn part.
#
# This file does not self-certify "fails before the fix": that is done externally
# by quality-gate-guard.sh's base-test harness, which runs it on a throwaway
# worktree of the base commit.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
hasnt() { if grep -qE "$2" "$1"; then bad "$3 — still present: $2"; else ok "$3"; fi; }

echo "== gate-q8tj7p-queue-order.selftest (ga-q8tj7p) =="

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

extract_block() {
  sed -n "/# SELFTEST-EXTRACT $2: BEGIN/,/# SELFTEST-EXTRACT $2: END/p" "$1"
}
SELECT_BLOCK="$(extract_block "$DISPATCHER" marker-select)"
[ -n "$SELECT_BLOCK" ] || { echo "FATAL: could not extract the marker-select block (sentinels missing?)" >&2; exit 2; }
ok "located the live marker-select block via sentinel extraction"

NOW_EPOCH=1782863814
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
ago() { iso "$((NOW_EPOCH - $1))"; }

# mk <id> <age-seconds> <class> [extra-labels-csv] [author-crew]
#   class: P<n>:<type>      read OK, priority n, issue_type <type>
#          Pnull:<type>     read OK, but the record carries no priority
#          Pstr:<type>      read OK, priority is not a number
#          P<n.m>:<type>    read OK, priority is not an integer (e.g. P2.5)
#          unreadable       the enrichment could not read the source bead
#          none             no `.src_class` at all (enrichment never ran for it)
#   a class may end in a verdict on the source bead's `impacto:dano-ao-vivo` label (ga-emgkvn):
#          P0:bug+dano      the label is on the source bead        (src_class.dano = "yes")
#          P0:bug+danox     its labels could not be read           (src_class.dano = "unreadable")
#          P0:bug+danono    the labels were read, no such label   (src_class.dano = "no")
#          (no suffix)      src_class carries no `dano` key at all — what the pre-ga-emgkvn enrichment wrote
mk() {
  local id="$1" age="$2" cls="$3" labels="${4:-}" crew="${5:-wa-worker}"
  local labarr='["gate-status:queued"]'
  [ -n "$labels" ] && labarr="$(printf '%s' "$labels" | jq -R 'split(",")')"
  local src="null" prio typ dano=""
  case "$cls" in
    *+dano)   dano="yes";        cls="${cls%+dano}" ;;
    *+danox)  dano="unreadable"; cls="${cls%+danox}" ;;
    *+danono) dano="no";         cls="${cls%+danono}" ;;
  esac
  case "$cls" in
    unreadable) src='{"state":"unreadable","why":"not-read"}' ;;
    none)       src="null" ;;
    Pnull:*)    typ="${cls#Pnull:}"; src=$(jq -cn --arg t "$typ" '{state:"ok",priority:null,type:$t}') ;;
    Pstr:*)     typ="${cls#Pstr:}";  src=$(jq -cn --arg t "$typ" '{state:"ok",priority:"high",type:$t}') ;;
    P*:*)       prio="${cls#P}"; prio="${prio%%:*}"; typ="${cls#*:}"
                src=$(jq -cn --argjson p "$prio" --arg t "$typ" '{state:"ok",priority:$p,type:$t}') ;;
  esac
  local created; created="$(ago "$age")"
  [ "$age" = "BADTS" ] && created="not-a-timestamp"
  jq -cn --arg id "$id" --arg ts "$created" --arg desc "branch: crew/${crew}/${id}" \
        --argjson labels "$labarr" --argjson src "$src" --arg dano "$dano" \
    '{id:$id, created_at:$ts, description:$desc, labels:$labels}
     + (if $src == null then {} else {src_class:($src + (if $dano != "" and $src.state == "ok" then {dano:$dano} else {} end))} end)'
}

# run_select <markers-json> [ENV=VAL ...] -> one record:
#   <selected-id> US <class> US <summary> US <ids whose dano label was ignored> US <full order json>
# (US = ASCII unit separator: a marker's text can hold any printable character, so no printable separator is safe)
US=$'\x1f'
run_select() {
  local markers="$1"; shift
  env MARKERS_JSON="$markers" GATE_MARKER_NOW_OVERRIDE_EPOCH="$NOW_EPOCH" "$@" \
    bash -c "$SELECT_BLOCK"$'\nprintf "%s\\037%s\\037%s\\037%s\\037%s" "${MARKER_ID:-}" "${MARKER_CLASS:-}" "${MARKER_ORDER_SUMMARY:-}" "${MARKER_DANO_IGNORED:-}" "${MARKER_ORDER_JSON:-[]}"' 2>/dev/null
}
sel_id()    { printf '%s' "$1" | cut -d"$US" -f1; }
sel_class() { printf '%s' "$1" | cut -d"$US" -f2; }
sel_summ()  { printf '%s' "$1" | cut -d"$US" -f3; }
sel_ignored() { printf '%s' "$1" | cut -d"$US" -f4; }
sel_order() { printf '%s' "$1" | cut -d"$US" -f5- | jq -r '[.[].id] | join(",")' 2>/dev/null; }
# order_is <label> <record> <expected comma-joined order>: the whole order AND the marker the dispatcher would
# actually claim (the head). The second half matters on its own: it is read from MARKER_ID, so it fails for the
# right reason against a dispatcher that has no MARKER_ORDER_JSON at all.
order_is() {
  eq "$1" "$(sel_order "$2")" "$3"
  eq "$1 — claimed marker" "$(sel_id "$2")" "${3%%,*}"
}
arr() { local out="[" first=1 m; for m in "$@"; do if [ $first = 1 ]; then first=0; else out="$out,"; fi; out="$out$m"; done; printf '%s]' "$out"; }

# ═══════════════════════════════════════════════════════════════════════════
# Part A — the order
# ═══════════════════════════════════════════════════════════════════════════
echo "── A1. Athos's rule end to end: P0 features (oldest first), P0 others, then P1 features, P1 others, ... ──"
# Fed in REVERSE of the expected order, with ages mixed, so a sort that merely keeps input order fails.
FIX=$(arr \
  "$(mk p4t     20   P4:task)" \
  "$(mk p3b_old 9000 P3:bug)" \
  "$(mk p2f     300  P2:feature)" \
  "$(mk p1t     7000 P1:task)" \
  "$(mk p1f_new 10   P1:feature)" \
  "$(mk p1f_old 4000 P1:feature)" \
  "$(mk p0b_new 50   P0:bug)" \
  "$(mk p0t_old 6000 P0:task)" \
  "$(mk p0f_new 100  P0:feature)" \
  "$(mk p0f_old 5000 P0:feature)")
R=$(run_select "$FIX")
order_is "full order" "$R" "p0f_old,p0f_new,p0t_old,p0b_new,p1f_old,p1f_new,p1t,p2f,p3b_old,p4t"
eq "selected = the oldest P0 feature" "$(sel_id "$R")" "p0f_old"

echo "── A2. priority outranks type: a P0 task beats a P1 feature ──"
R=$(run_select "$(arr "$(mk f1 600 P1:feature)" "$(mk t0 60 P0:task)")")
order_is "P0 task first" "$R" "t0,f1"

echo "── A3. age no longer promotes: a P0 submitted 10s ago beats a P3 that has waited 9000s (no >90min emergency tier) ──"
R=$(run_select "$(arr "$(mk old3 9000 P3:bug)" "$(mk new0 10 P0:task)")")
order_is "fresh P0 first" "$R" "new0,old3"

echo "── A4. ...and no fresh-slot reservation either: with the reservation due, order is unchanged ──"
R=$(run_select "$(arr "$(mk old3 9000 P3:bug)" "$(mk new0 10 P0:task)")" GATE_FRESH_SLOT_DUE=true)
order_is "GATE_FRESH_SLOT_DUE=true is inert" "$R" "new0,old3"

echo "── A5. gate:priority label and the oracle crew branch carry no weight any more ──"
R=$(run_select "$(arr "$(mk labeled 600 P3:task 'gate-status:queued,gate:priority')" "$(mk plain 60 P1:task)")")
order_is "unlabeled P1 beats labeled P3" "$R" "plain,labeled"
R=$(run_select "$(arr "$(mk orc 600 P3:task '' oracle)" "$(mk oth 60 P2:task '' mila)")" GATE_PRIORITY_AUTHORS=oracle)
order_is "P2 from another crew beats P3 from oracle, even with GATE_PRIORITY_AUTHORS=oracle" "$R" "oth,orc"

echo "── A6. retry cooldown still excludes a marker from every tier ──"
R=$(run_select "$(arr "$(mk cool 9000 P0:feature "gate-status:queued,gate:retry-cooldown-until:$((NOW_EPOCH + 600))")" "$(mk next 60 P4:task)")")
order_is "P0 feature inside its cooldown is not eligible" "$R" "next"
R=$(run_select "$(arr "$(mk cool 9000 P0:feature "gate-status:queued,gate:retry-cooldown-until:$((NOW_EPOCH - 5))")")")
order_is "an EXPIRED cooldown no longer excludes" "$R" "cool"
R=$(run_select "$(arr "$(mk cool 9000 P0:feature "gate-status:queued,gate:retry-cooldown-until:$((NOW_EPOCH + 600))")")")
eq "everything in cooldown selects nothing" "$(sel_id "$R")" ""

echo "── A7. a rebase-fail marker is LAST, however high its priority (ga-q3ig2) ──"
R=$(run_select "$(arr "$(mk broken 9000 P0:feature 'gate-status:queued,gate:exiled-tier5:1')" "$(mk fine 10 P4:task)")")
order_is "healthy P4 task before an exiled P0 feature" "$R" "fine,broken"
eq "class of a sunk marker says so" "$(sel_class "$(run_select "$(arr "$(mk broken 9000 P0:feature 'gate-status:queued,gate:exiled-tier5:1')")")")" "rebase-fail"

echo "── A8. THREE STATES: a source that could not be read goes AFTER every readable class and BEFORE rebase-fail — never first ──"
R=$(run_select "$(arr \
  "$(mk unread_old 9000 unreadable)" \
  "$(mk noclass    8000 none)" \
  "$(mk broken     7000 P0:feature 'gate-status:queued,gate:exiled-tier5:1')" \
  "$(mk p4         10   P4:task)" \
  "$(mk p0         20   P0:task)")")
order_is "readable by class, then unreadable oldest-first (state=unreadable and no src_class alike), then rebase-fail" "$R" "p0,p4,unread_old,noclass,broken"
eq "an unreadable marker is never classed P0" "$(sel_class "$(run_select "$(arr "$(mk u 9000 unreadable)")")")" "unreadable"

echo "── A9. a record that WAS read but carries no valid priority is P2 (bd's default) — not unreadable, not P0 ──"
R=$(run_select "$(arr \
  "$(mk p3  500 P3:task)" \
  "$(mk nul 500 Pnull:task)" \
  "$(mk str 500 Pstr:task)" \
  "$(mk big 500 P7:task)" \
  "$(mk neg 500 P-1:task)" \
  "$(mk frac 500 P2.5:task)" \
  "$(mk p1  500 P1:task)")")
order_is "P1, then the four invalid-priority-but-read markers as P2 (age tie -> id), then P3" "$R" "p1,big,frac,neg,nul,str,p3"
eq "class label of a defaulted priority is P2" "$(sel_class "$(run_select "$(arr "$(mk nul 500 Pnull:feature)")")")" "P2/feature"

echo "── A10. priority 0 is P0 — the falsy-zero trap (0 must not read as 'absent' and default to P2) ──"
R=$(run_select "$(arr "$(mk p2 9000 P2:feature)" "$(mk p0 60 P0:task)")")
order_is "numeric 0 outranks P2" "$R" "p0,p2"
eq "class of the P0 task" "$(sel_class "$R")" "P0/other"

echo "── A11. a malformed created_at sorts LAST inside its class (unknown age must not read as 'oldest') ──"
R=$(run_select "$(arr "$(mk bad BADTS P1:task)" "$(mk good 60 P1:task)")")
order_is "valid timestamp first" "$R" "good,bad"

echo "── A12. equal created_at is broken by id, whatever order bd listed them in ──"
R1=$(run_select "$(arr "$(mk bbb 500 P1:task)" "$(mk aaa 500 P1:task)")")
R2=$(run_select "$(arr "$(mk aaa 500 P1:task)" "$(mk bbb 500 P1:task)")")
eq "same order from both input orders" "$(sel_order "$R1")" "$(sel_order "$R2")"
eq "ties -> id ascending" "$(sel_order "$R1")" "aaa,bbb"

echo "── A13. the exile-overdue admission (ga-0ye7ar / ga-r5dsgp) is a different invariant and survives: bounded, and ahead of the order ──"
EX_OLD="gate-status:queued,gate:exiled-tier5:1,gate:exiled-since:$((NOW_EPOCH - 6000))"
R=$(run_select "$(arr "$(mk exiled 9000 P4:task "$EX_OLD")" "$(mk p0 60 P0:feature)")")
order_is "an exile older than GATE_EXILE_OVERDUE_SECONDS (5400s) with attempts left is re-tried first" "$R" "exiled,p0"
eq "class label says why" "$(sel_class "$R")" "exile-overdue"
EX_SPENT="gate-status:queued,gate:exiled-tier5:3,gate:exiled-since:$((NOW_EPOCH - 6000))"
R=$(run_select "$(arr "$(mk spent 9000 P4:task "$EX_SPENT")" "$(mk p0 60 P0:feature)")")
order_is "...but not once its retry budget is spent: it sinks to the back" "$R" "p0,spent"
EX_YOUNG="gate-status:queued,gate:exiled-tier5:1,gate:exiled-since:$((NOW_EPOCH - 600))"
R=$(run_select "$(arr "$(mk young 9000 P4:task "$EX_YOUNG")" "$(mk p0 60 P0:feature)")")
order_is "...and not while the exile is young" "$R" "p0,young"

echo "── A14. what the log line is built from: class of the selected marker + the head of the order ──"
R=$(run_select "$(arr "$(mk b 100 P1:task)" "$(mk a 100 P0:feature)" "$(mk c 100 Pnull:bug)")")
eq "class of the selected marker" "$(sel_class "$R")" "P0/feature"
eq "summary lists the order with each marker's class" "$(sel_summ "$R")" "a[P0/feature] b[P1/other] c[P2/other]"
MANY=$(arr "$(mk m1 900 P0:task)" "$(mk m2 800 P0:task)" "$(mk m3 700 P0:task)" "$(mk m4 600 P0:task)" "$(mk m5 500 P0:task)" "$(mk m6 400 P0:task)" "$(mk m7 300 P0:task)" "$(mk m8 200 P0:task)" "$(mk m9 100 P0:task)" "$(mk m10 50 P0:task)")
R=$(run_select "$MANY")
eq "a long queue is summarised, not dumped" "$(sel_summ "$R")" "m1[P0/other] m2[P0/other] m3[P0/other] m4[P0/other] m5[P0/other] m6[P0/other] m7[P0/other] m8[P0/other] (+2 more)"

echo "── A15. a description-less marker is still selectable (scan yields '' not an empty stream) ──"
NODESC='[{"id":"nd1","created_at":"'"$(ago 600)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":1,"type":"task"}},{"id":"nd2","created_at":"'"$(ago 60)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":1,"type":"task"}}]'
eq "oldest of the two" "$(sel_id "$(run_select "$NODESC")")" "nd1"

echo "── A16. the retired ordering machinery is really gone from the dispatcher, not just bypassed ──"
hasnt "$DISPATCHER" 'gate-fresh-slot-sweep-count'            "no fresh-slot counter file written every sweep"
hasnt "$DISPATCHER" 'gate_fresh_slot_should_reserve'          "no fresh-slot decision function"
hasnt "$DISPATCHER" 'GATE_DIFF_SIZE_ORDERING_ENABLED'         "no per-marker diff measurement for ordering (one git diff per marker per sweep)"
hasnt "$DISPATCHER" 'GATE_PRIORITY_AUTHORS="\$\{GATE_PRIORITY_AUTHORS' "no crew-priority allowlist"
has   "$DISPATCHER" 'gate_src_class_enrich "\$MARKERS_JSON"'  "the sweep enriches MARKERS_JSON before selecting"

echo "── A17. the dispatcher runs under set -euo pipefail: the block must survive it, with every knob unset and with garbage knobs ──"
STRICT_FIX=$(arr "$(mk s1 500 P1:task)" "$(mk s2 100 P0:feature)")
strict_select() { # <ENV=VAL>...
  env -u GATE_MARKER_NOW_OVERRIDE_EPOCH -u GATE_EXILE_OVERDUE_SECONDS -u GATE_EXILE_RETRY_CEILING MARKERS_JSON="$STRICT_FIX" "$@" \
    bash -c "set -euo pipefail; $SELECT_BLOCK"$'\necho "$MARKER_ID"' 2>/dev/null
  echo "rc=$?"
}
eq "no knob set at all"                          "$(strict_select | tr '\n' ' ')" "s2 rc=0 "
eq "malformed GATE_MARKER_NOW_OVERRIDE_EPOCH"    "$(strict_select GATE_MARKER_NOW_OVERRIDE_EPOCH=not-a-number | tr '\n' ' ')" "s2 rc=0 "
eq "empty GATE_MARKER_NOW_OVERRIDE_EPOCH"        "$(strict_select GATE_MARKER_NOW_OVERRIDE_EPOCH= | tr '\n' ' ')" "s2 rc=0 "
eq "malformed GATE_EXILE_OVERDUE_SECONDS"        "$(strict_select GATE_EXILE_OVERDUE_SECONDS=abc | tr '\n' ' ')" "s2 rc=0 "
eq "malformed GATE_EXILE_RETRY_CEILING"          "$(strict_select GATE_EXILE_RETRY_CEILING=abc | tr '\n' ' ')" "s2 rc=0 "

# ═══════════════════════════════════════════════════════════════════════════
# Part A, ga-emgkvn — the "dano ao vivo" exception
# ═══════════════════════════════════════════════════════════════════════════
echo "── A18. the exception end to end: P0 bug + label first, then P0 features, P0 others, then P1 (where the label means nothing) ──"
# Fed in reverse of the expected order. p0b_plain (9500s) is OLDER than every other P0, so a bug that was promoted
# without the label (or a sort that ignores the class) would put it first.
FIX=$(arr \
  "$(mk p1b_dano  100  P1:bug+dano)" \
  "$(mk p1f       4000 P1:feature)" \
  "$(mk p0t       50   P0:task)" \
  "$(mk p0b_plain 9500 P0:bug+danono)" \
  "$(mk p0f_old   9000 P0:feature)" \
  "$(mk d_new     10   P0:bug+dano)" \
  "$(mk d_old     300  P0:bug+dano)")
R=$(run_select "$FIX")
order_is "full order" "$R" "d_old,d_new,p0f_old,p0b_plain,p0t,p1f,p1b_dano"
eq "summary: the class says why" "$(sel_summ "$R")" "d_old[P0/dano-ao-vivo] d_new[P0/dano-ao-vivo] p0f_old[P0/feature] p0b_plain[P0/other] p0t[P0/other] p1f[P1/feature] p1b_dano[P1/other]"
eq "class of the selected marker" "$(sel_class "$R")" "P0/dano-ao-vivo"

echo "── A19. age does not matter across classes: a dano bug submitted 10s ago beats a P0 feature that has waited 9000s ──"
R=$(run_select "$(arr "$(mk feat 9000 P0:feature)" "$(mk dano 10 P0:bug+dano)")")
order_is "dano first" "$R" "dano,feat"

echo "── A20. ...but oldest-first still holds INSIDE the class, and ties go to the id ──"
R=$(run_select "$(arr "$(mk d_young 10 P0:bug+dano)" "$(mk d_old 900 P0:bug+dano)")")
order_is "older dano bug first" "$R" "d_old,d_young"
R1=$(run_select "$(arr "$(mk d_b 500 P0:bug+dano)" "$(mk d_a 500 P0:bug+dano)")")
eq "equal ages -> id ascending" "$(sel_order "$R1")" "d_a,d_b"

echo "── A21. the label counts on a P0 BUG only — anywhere else it is ignored, and the sweep can say which markers ──"
R=$(run_select "$(arr "$(mk p1b_dano 600 P1:bug+dano)" "$(mk p0t 60 P0:task)")")
order_is "a P1 bug with the label does not pass a P0 task" "$R" "p0t,p1b_dano"
R=$(run_select "$(arr "$(mk p1t 600 P1:task)" "$(mk p1b_dano 60 P1:bug+dano)" "$(mk p1f 10 P1:feature)")")
order_is "inside P1 the label changes nothing: feature, then the others by age" "$R" "p1f,p1t,p1b_dano"
eq "class of a P1 bug that carries the label" "$(sel_class "$(run_select "$(arr "$(mk b 60 P1:bug+dano)")")")" "P1/other"
R=$(run_select "$(arr "$(mk f_old 900 P0:feature)" "$(mk f_dano 100 P0:feature+dano)" "$(mk t_dano 5000 P0:task+dano)" "$(mk f_plain 50 P0:feature)")")
order_is "a P0 FEATURE or TASK with the label is not a bug: no promotion (features by age, then the task)" "$R" "f_old,f_dano,f_plain,t_dano"
eq "its class is its own" "$(sel_summ "$R")" "f_old[P0/feature] f_dano[P0/feature] f_plain[P0/feature] t_dano[P0/other]"
R=$(run_select "$(arr "$(mk d 60 P0:bug+dano)" "$(mk p1b 600 P1:bug+dano)" "$(mk p0f 100 P0:feature+dano)" "$(mk p2t 100 P2:task+dano)" "$(mk p0t 100 P0:task)")")
eq "the ignored label is listed, in queue order — and a promoted marker is not on the list" "$(sel_ignored "$R")" "p0f,p1b,p2t"
eq "nothing ignored when nothing carries the label" "$(sel_ignored "$(run_select "$(arr "$(mk a 60 P0:bug)" "$(mk b 60 P1:task)")")")" ""

echo "── A22. THREE STATES of the label: could not read the labels = treated as WITHOUT it (never promoted) ──"
R=$(run_select "$(arr "$(mk f 100 P0:feature)" "$(mk b_unreadable 9000 P0:bug+danox)")")
order_is "labels unreadable: the P0 bug stays behind the P0 feature" "$R" "f,b_unreadable"
eq "...and its class is the ordinary one, not the exception's" "$(sel_summ "$R")" "f[P0/feature] b_unreadable[P0/other]"
R=$(run_select "$(arr "$(mk f 100 P0:feature)" "$(mk b_nokey 9000 P0:bug)")")
order_is "src_class with no dano key at all (the enrichment of before ga-emgkvn): no promotion" "$R" "f,b_nokey"
R=$(run_select '[{"id":"f","created_at":"'"$(ago 100)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":0,"type":"feature"}},{"id":"b_str","created_at":"'"$(ago 9000)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":0,"type":"bug","dano":"true"}},{"id":"b_bool","created_at":"'"$(ago 9000)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":0,"type":"bug","dano":true}}]')
order_is "only the exact verdict \"yes\" promotes: \"true\" and boolean true do not" "$R" "f,b_bool,b_str"

echo "── A23. a source that could not be read is never promoted either, whatever else the marker says ──"
R=$(run_select "$(arr "$(mk unread 9000 unreadable)" "$(mk p4 10 P4:task)")")
order_is "unreadable source: after the readable class" "$R" "p4,unread"
R=$(run_select '[{"id":"u","created_at":"'"$(ago 9000)"'","labels":["gate-status:queued"],"src_class":{"state":"unreadable","priority":0,"type":"bug","dano":"yes"}},{"id":"f","created_at":"'"$(ago 10)"'","labels":["gate-status:queued"],"src_class":{"state":"ok","priority":0,"type":"feature"}}]')
order_is "state=unreadable wins over any stray priority/type/dano fields in the record" "$R" "f,u"
eq "its class" "$(sel_class "$R")" "P0/feature"

echo "── A24. the priority is re-checked at selection: no valid priority reads as P2, so the label cannot make a P0 of it ──"
R=$(run_select "$(arr "$(mk p1t 600 P1:task)" "$(mk nul 9000 Pnull:bug+dano)" "$(mk str 9000 Pstr:bug+dano)" "$(mk big 9000 P7:bug+dano)")")
order_is "invalid-priority bug+label sorts as P2, behind the P1" "$R" "p1t,big,nul,str"
eq "class says P2" "$(sel_class "$(run_select "$(arr "$(mk nul 9000 Pnull:bug+dano)")")")" "P2/other"

echo "── A25. the other tiers still outrank the exception: cooldown excludes it, a rebase-fail marker sinks, an overdue exile is still re-tried first ──"
R=$(run_select "$(arr "$(mk d_cool 9000 P0:bug+dano "gate-status:queued,gate:retry-cooldown-until:$((NOW_EPOCH + 600))")" "$(mk next 60 P4:task)")")
order_is "a dano bug inside its retry cooldown is not eligible" "$R" "next"
R=$(run_select "$(arr "$(mk d_broken 9000 P0:bug+dano 'gate-status:queued,gate:exiled-tier5:1')" "$(mk fine 10 P4:task)")")
order_is "a dano bug on a branch that cannot rebase is still LAST" "$R" "fine,d_broken"
eq "its class is rebase-fail, not the exception's" "$(sel_class "$(run_select "$(arr "$(mk d_broken 9000 P0:bug+dano 'gate-status:queued,gate:exiled-tier5:1')")")")" "rebase-fail"
R=$(run_select "$(arr "$(mk exiled 9000 P4:task "$EX_OLD")" "$(mk dano 60 P0:bug+dano)")")
order_is "the bounded exile-overdue admission is still ahead of the order" "$R" "exiled,dano"
eq "a rebase-fail marker is not reported as 'label ignored' (its class is not about the label)" "$(sel_ignored "$(run_select "$(arr "$(mk d_broken 9000 P1:bug+dano 'gate-status:queued,gate:exiled-tier5:1')" "$(mk fine 10 P4:task)")")")" ""

echo "── A26. under set -euo pipefail, with the exception in play, the block still selects and returns 0 ──"
STRICT_FIX=$(arr "$(mk s1 500 P0:feature)" "$(mk s2 100 P0:bug+dano)" "$(mk s3 50 P1:bug+dano)" "$(mk s4 50 P0:bug+danox)")
eq "dano bug selected, rc 0" "$(strict_select | tr '\n' ' ')" "s2 rc=0 "

# ═══════════════════════════════════════════════════════════════════════════
# Part B — the enrichment (Step 0b-1): batched, cross-store, three-state
# ═══════════════════════════════════════════════════════════════════════════
echo "── B0. the enrichment block exists ──"
SRC_BLOCK="$(extract_block "$DISPATCHER" gate-src-class)"
if [ -z "$SRC_BLOCK" ]; then
  bad "no SELFTEST-EXTRACT gate-src-class block in the dispatcher — the enrichment has not landed"
else
  ok "located the live gate-src-class block via sentinel extraction"

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/gate-q8tj7p.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  mkdir -p "$WORK/city" "$WORK/wa" "$WORK/stub"

  cat > "$WORK/show-stub.sh" <<'STUB'
#!/usr/bin/env bash
# Mimics `bd -C <store> show <id>... --json` exactly as measured on the live bd:
#   some ids found    -> rc 0, JSON array of ONLY the found ones (missing ids are silently absent)
#   none found        -> rc 1, a JSON ERROR OBJECT (not an array)
#   store unreachable -> rc 1, no JSON at all
store=""; ids=()
while [ $# -gt 0 ]; do
  case "$1" in -C) store="$2"; shift 2 ;; show|--json) shift ;; *) ids+=("$1"); shift ;; esac
done
echo "$(basename "$store") ${ids[*]}" >> "$STUB_LOG"
[ -f "$STUB_DIR/$(basename "$store").fail" ] && { echo "dolt: connection refused" >&2; exit 1; }
f="$STUB_DIR/$(basename "$store").json"
[ -f "$f" ] || { echo '{"error":"no issues found matching the provided IDs","schema_version":1}'; exit 1; }
out=$(jq -c --argjson want "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -sc .)" '[.[] | select(.id as $i | $want | index($i) != null)]' "$f")
[ "$out" = "[]" ] && { echo '{"error":"no issues found matching the provided IDs","schema_version":1}'; exit 1; }
echo "$out"
STUB
  chmod +x "$WORK/show-stub.sh"

  RIGS=$(jq -cn --arg c "$WORK/city" --arg w "$WORK/wa" \
    '{rigs:[{name:"gascity",prefix:"ga",path:$c},{name:"whatsapp_automation",prefix:"wa",path:$w}]}')

  # a queued marker as the dispatcher sees it: routing in the description, and labels
  mkq() { # <marker-id> <bead-id> <bead-rig> [desc|label|none]
    local mid="$1" bead="$2" brig="$3" where="${4:-desc}" desc="" labels='["gate-status:queued","type:quality-gate-marker"]'
    case "$where" in
      desc)  desc="branch: crew/x/$mid"$'\n'"bead_id: $bead"$'\n'"rig: $brig"$'\n'"bead_rig: $brig" ;;
      label) desc="prose only"; labels=$(jq -cn --arg b "$bead" --arg r "$brig" '["gate-status:queued","source-bead:"+$b,"bead-rig:"+$r]') ;;
      none)  desc="prose only, no routing at all" ;;
    esac
    jq -cn --arg id "$mid" --arg d "$desc" --argjson l "$labels" '{id:$id, created_at:"2026-10-06T10:00:00Z", description:$d, labels:$l}'
  }

  # run_enrich <markers-json>  -> stdout = enriched JSON ; stderr of the function -> $WORK/enrich.err
  run_enrich() {
    : > "$WORK/stub.log"
    GC_CITY="$WORK/city" GATE_SRC_SHOW_SCRIPT="$WORK/show-stub.sh" STUB_DIR="$WORK/stub" STUB_LOG="$WORK/stub.log" \
      _GATE_RIG_LIST_CACHE="${RIGS_OVERRIDE-$RIGS}" \
      bash -c 'log(){ echo "LOG $*" >&2; }; warn(){ echo "WARN $*" >&2; }; gc_json_or_unknown(){ return 1; }'$'\n'"$SRC_BLOCK"$'\ngate_src_class_enrich "$1"' _ "$1" 2>"$WORK/enrich.err"
  }
  cls() { printf '%s' "$1" | jq -c --arg id "$2" '.[] | select(.id == $id) | .src_class | {state, priority, type}'; }

  # ga-emgkvn: the wa-d* / ga-hq3 beads carry the label shapes of B12-B17. bd OMITS the `labels` key for a
  # bead that has none (measured 14/14 on the live bd) — wa-d2 is that shape, and it is a normal "no labels".
  printf '[{"id":"ga-hq1","priority":2,"issue_type":"bug"},{"id":"ga-hq2","priority":0,"issue_type":"feature"},{"id":"ga-hq3","priority":0,"issue_type":"bug","labels":["area:gate","impacto:dano-ao-vivo"]}]' > "$WORK/stub/city.json"
  printf '%s' '[{"id":"wa-1","priority":1,"issue_type":"task"},{"id":"wa-2","priority":0,"issue_type":"feature"},{"id":"wa-3","issue_type":"chore"},{"id":"wa-4","priority":null,"issue_type":"task"},
    {"id":"wa-d1","priority":0,"issue_type":"bug","labels":["x","impacto:dano-ao-vivo"]},
    {"id":"wa-d2","priority":0,"issue_type":"bug"},
    {"id":"wa-d3","priority":0,"issue_type":"bug","labels":["impacto:dano-ao-vivo2","x:impacto:dano-ao-vivo"]},
    {"id":"wa-d4","priority":0,"issue_type":"bug","labels":"impacto:dano-ao-vivo"},
    {"id":"wa-d5","priority":0,"issue_type":"bug","labels":null},
    {"id":"wa-d6","priority":0,"issue_type":"bug","labels":["impacto:dano-ao-vivo",7]},
    {"id":"wa-d7","priority":1,"issue_type":"bug","labels":["impacto:dano-ao-vivo"]},
    {"id":"wa-d8","priority":0,"issue_type":"feature","labels":["impacto:dano-ao-vivo"]},
    {"id":"wa-d9","priority":0,"issue_type":"bug","labels":[]},
    {"id":"wa-d10","priority":0,"issue_type":"bug","labels":["Impacto:Dano-ao-Vivo"]}]' > "$WORK/stub/wa.json"

  echo "── B1. one batched read per store — not one per marker (the N+1 the bead warns about) ──"
  IN=$(arr "$(mkq m1 wa-1 whatsapp_automation)" "$(mkq m2 wa-2 whatsapp_automation)" "$(mkq m3 ga-hq1 gascity)" "$(mkq m4 ga-hq2 gascity)" "$(mkq m5 wa-3 whatsapp_automation label)")
  OUT=$(run_enrich "$IN")
  eq "5 markers over 2 stores -> exactly 2 store reads" "$(wc -l < "$WORK/stub.log" | tr -d ' ')" "2"
  eq "classes read"      "$(cls "$OUT" m1)" '{"state":"ok","priority":1,"type":"task"}'
  eq "a P0 feature in the rig store"   "$(cls "$OUT" m2)" '{"state":"ok","priority":0,"type":"feature"}'
  eq "an HQ bead"        "$(cls "$OUT" m3)" '{"state":"ok","priority":2,"type":"bug"}'
  eq "a P0 feature in HQ" "$(cls "$OUT" m4)" '{"state":"ok","priority":0,"type":"feature"}'
  eq "routing taken from LABELS when the description has none" "$(cls "$OUT" m5)" '{"state":"ok","priority":null,"type":"chore"}'
  eq "marker count and ids preserved" "$(printf '%s' "$OUT" | jq -c '[.[].id]')" '["m1","m2","m3","m4","m5"]'
  eq "marker's own fields are untouched" "$(printf '%s' "$OUT" | jq -c '.[0] | {id, created_at, labels}')" "$(printf '%s' "$IN" | jq -c '.[0] | {id, created_at, labels}')"

  echo "── B2. three states: a record WITHOUT a priority is 'read, no priority' — it stays 'ok' (the block turns it into P2) ──"
  eq "wa-3: no priority key -> ok, priority null" "$(cls "$OUT" m5 | jq -c '.priority')" "null"
  OUT=$(run_enrich "$(arr "$(mkq m6 wa-4 whatsapp_automation)")")
  eq "wa-4: explicit priority null -> ok, priority null" "$(cls "$OUT" m6)" '{"state":"ok","priority":null,"type":"task"}'

  echo "── B3. not found anywhere -> unreadable (NOT ok, NOT a default priority) ──"
  OUT=$(run_enrich "$(arr "$(mkq m7 wa-ghost whatsapp_automation)")")
  eq "not-found" "$(cls "$OUT" m7)" '{"state":"unreadable","priority":null,"type":null}'
  has "$WORK/enrich.err" 'WARN.*1 of 1' "a WARN counts how many markers ended up unreadable"

  echo "── B4. a store that cannot be reached (rc 1, no JSON) degrades ITS markers only ──"
  : > "$WORK/stub/wa.fail"
  OUT=$(run_enrich "$(arr "$(mkq m8 wa-1 whatsapp_automation)" "$(mkq m9 ga-hq1 gascity)")")
  eq "rig-store marker -> unreadable" "$(cls "$OUT" m8 | jq -r .state)" "unreadable"
  eq "HQ marker unaffected"           "$(cls "$OUT" m9 | jq -r .state)" "ok"
  rm -f "$WORK/stub/wa.fail"

  echo "── B5. a bead whose bead-rig is wrong is still found by the bead-id prefix, then HQ ──"
  OUT=$(run_enrich "$(arr "$(mkq m10 wa-1 gascity)")")
  eq "bead-rig says gascity, bead lives in wa -> found via prefix" "$(cls "$OUT" m10 | jq -r .state)" "ok"
  eq "tried the claimed store first, then the prefix store" "$(awk '{print $1}' "$WORK/stub.log" | tr '\n' ',')" "city,wa,"

  echo "── B6. no source bead, or an id that could be mistaken for a flag: unreadable, and never handed to bd ──"
  OUT=$(run_enrich "$(arr "$(mkq m11 '' gascity none)" "$(mkq m12 '--all' gascity)")")
  eq "no routing at all"  "$(cls "$OUT" m11 | jq -r .state)" "unreadable"
  eq "flag-shaped id"     "$(cls "$OUT" m12 | jq -r .state)" "unreadable"
  eq "bd was not called at all for them" "$(wc -l < "$WORK/stub.log" | tr -d ' ')" "0"

  echo "── B7. two markers on one bead cost one id in the read ──"
  OUT=$(run_enrich "$(arr "$(mkq m13 wa-1 whatsapp_automation)" "$(mkq m14 wa-1 whatsapp_automation)")")
  eq "bead asked for once" "$(cat "$WORK/stub.log")" "wa wa-1"
  eq "both markers classed" "$(printf '%s' "$OUT" | jq -c '[.[].src_class.state]')" '["ok","ok"]'

  echo "── B8. rig list unavailable: only HQ can be tried, nothing crashes, the sweep goes on ──"
  OUT=$(RIGS_OVERRIDE="" run_enrich "$(arr "$(mkq m15 wa-1 whatsapp_automation)" "$(mkq m16 ga-hq1 gascity)")")
  eq "HQ marker still read"       "$(cls "$OUT" m16 | jq -r .state)" "ok"
  eq "rig-store marker unreadable" "$(cls "$OUT" m15 | jq -r .state)" "unreadable"

  echo "── B9. garbage in -> the input comes back unchanged and the function succeeds (a sweep is never aborted by this step) ──"
  OUT=$(run_enrich 'this is not json'); RC=$?
  eq "rc"     "$RC" "0"
  eq "echoed" "$OUT" "this is not json"
  OUT=$(run_enrich '[]')
  eq "empty queue" "$OUT" "[]"

  echo "── B11. the enrichment survives set -euo pipefail (the dispatcher's own mode) on the happy path AND on every failure above ──"
  run_enrich_strict() {
    : > "$WORK/stub.log"
    GC_CITY="$WORK/city" GATE_SRC_SHOW_SCRIPT="$WORK/show-stub.sh" STUB_DIR="$WORK/stub" STUB_LOG="$WORK/stub.log" \
      _GATE_RIG_LIST_CACHE="${RIGS_OVERRIDE-$RIGS}" \
      bash -c 'set -euo pipefail; log(){ echo "LOG $*" >&2; }; warn(){ echo "WARN $*" >&2; }; gc_json_or_unknown(){ return 1; }'$'\n'"$SRC_BLOCK"$'\ngate_src_class_enrich "$1"; echo "rc=$?" >&2' _ "$1" 2>"$WORK/enrich-strict.err"
  }
  OUT=$(run_enrich_strict "$(arr "$(mkq m1 wa-1 whatsapp_automation)" "$(mkq m3 ga-hq1 gascity)" "$(mkq m7 wa-ghost whatsapp_automation)" "$(mkq m11 '' gascity none)")")
  eq "classes under strict mode" "$(printf '%s' "$OUT" | jq -c '[.[].src_class.state]')" '["ok","ok","unreadable","unreadable"]'
  has "$WORK/enrich-strict.err" '^rc=0$' "returned 0 under strict mode"
  : > "$WORK/stub/wa.fail"
  OUT=$(run_enrich_strict "$(arr "$(mkq m8 wa-1 whatsapp_automation)")")
  eq "store down under strict mode: unreadable, not an abort" "$(printf '%s' "$OUT" | jq -r '.[0].src_class.state')" "unreadable"
  has "$WORK/enrich-strict.err" '^rc=0$' "returned 0 under strict mode with a store down"
  rm -f "$WORK/stub/wa.fail"

  echo "── B10. end to end: enrichment output through the real selection block ──"
  IN=$(arr "$(mkq m1 wa-1 whatsapp_automation)" "$(mkq m2 wa-2 whatsapp_automation)" "$(mkq m3 ga-hq1 gascity)" "$(mkq m4 ga-hq2 gascity)" "$(mkq m7 wa-ghost whatsapp_automation)")
  OUT=$(run_enrich "$IN")
  R=$(run_select "$OUT")
  order_is "P0 features first (oldest-first ties by id), then P1, P2, and the unreadable last" "$R" "m2,m4,m1,m3,m7"

  # ── ga-emgkvn: the source bead's labels ──────────────────────────────────────
  dano_of() { printf '%s' "$1" | jq -r --arg id "$2" '.[] | select(.id == $id) | (.src_class | if has("dano") then (.dano | tostring) else "absent" end)'; }

  echo "── B12. the label verdict, per source bead: have it / do not have it / could not read the labels ──"
  OUT=$(run_enrich "$(arr \
    "$(mkq e1 wa-d1 whatsapp_automation)" "$(mkq e2 wa-d2 whatsapp_automation)" "$(mkq e3 wa-d3 whatsapp_automation)" \
    "$(mkq e4 wa-d4 whatsapp_automation)" "$(mkq e5 wa-d5 whatsapp_automation)" "$(mkq e6 wa-d6 whatsapp_automation)" \
    "$(mkq e9 wa-d9 whatsapp_automation)" "$(mkq e10 wa-d10 whatsapp_automation)" "$(mkq e11 ga-hq3 gascity)" "$(mkq e12 ga-hq1 gascity)")")
  eq "the label among others -> yes"                          "$(dano_of "$OUT" e1)"  "yes"
  eq "an HQ source bead carries it too -> yes"                "$(dano_of "$OUT" e11)" "yes"
  eq "no labels key at all (bd omits it for a label-less bead) -> no, NOT unreadable" "$(dano_of "$OUT" e2)" "no"
  eq "an empty labels array -> no"                            "$(dano_of "$OUT" e9)"  "no"
  eq "a bead of another kind with no such label -> no"        "$(dano_of "$OUT" e12)" "no"
  eq "only a near miss (…-ao-vivo2, a prefix) -> no: exact match"   "$(dano_of "$OUT" e3)"  "no"
  eq "different case -> no: exact match"                      "$(dano_of "$OUT" e10)" "no"
  eq "labels is a string, not a list -> unreadable (not 'no', not 'yes')" "$(dano_of "$OUT" e4)" "unreadable"
  eq "labels is null -> unreadable"                           "$(dano_of "$OUT" e5)"  "unreadable"
  eq "a list with a non-string element -> unreadable"         "$(dano_of "$OUT" e6)"  "unreadable"
  eq "priority/type of those records are still carried"       "$(cls "$OUT" e4)" '{"state":"ok","priority":0,"type":"bug"}'

  echo "── B13. a source bead that could not be read at all has no label verdict either (the state says it) ──"
  OUT=$(run_enrich "$(arr "$(mkq g1 wa-ghost whatsapp_automation)")")
  eq "unreadable source: no dano key" "$(dano_of "$OUT" g1)" "absent"

  echo "── B14. the labels cost no extra read: still one batched call per store ──"
  OUT=$(run_enrich "$(arr "$(mkq h1 wa-d1 whatsapp_automation)" "$(mkq h2 wa-d7 whatsapp_automation)" "$(mkq h3 ga-hq3 gascity)" "$(mkq h4 ga-hq1 gascity)")")
  eq "4 markers over 2 stores -> 2 reads" "$(wc -l < "$WORK/stub.log" | tr -d ' ')" "2"

  echo "── B15. visibility: unreadable labels are WARNed (with the ids); a clean read stays quiet; the log counts the label ──"
  run_enrich "$(arr "$(mkq w1 wa-d4 whatsapp_automation)" "$(mkq w2 wa-d6 whatsapp_automation)" "$(mkq w3 wa-d1 whatsapp_automation)")" >/dev/null
  has "$WORK/enrich.err" 'WARN.*ga-emgkvn.*labels UNREADABLE for 2 of 3 queued marker' "WARN counts the markers whose source labels could not be read (2 of 3)"
  has "$WORK/enrich.err" 'WARN.*ga-emgkvn.*never promoted.*ids: w1,w2\)' "...says they are never promoted, and names them"
  hasnt "$WORK/enrich.err" 'WARN.*ga-emgkvn.*w3' "...and does not name the one that was read fine"
  has "$WORK/enrich.err" 'LOG.*1 carry impacto:dano-ao-vivo' "the sweep log counts the markers whose source bead carries the label"
  run_enrich "$(arr "$(mkq q1 wa-d1 whatsapp_automation)" "$(mkq q2 wa-d2 whatsapp_automation)" "$(mkq q3 ga-hq1 gascity)")" >/dev/null
  hasnt "$WORK/enrich.err" 'WARN.*ga-emgkvn' "no WARN when every label list was readable (absent key included)"
  run_enrich "$(arr "$(mkq q1 wa-ghost whatsapp_automation)")" >/dev/null
  hasnt "$WORK/enrich.err" 'WARN.*ga-emgkvn' "an unreadable SOURCE is already WARNed about by its own line — no second, misleading 'labels' warning"

  echo "── B16. end to end through the real selection: the label promotes a P0 bug, nothing else ──"
  # every mkq marker has the same created_at, so classes decide and the id breaks ties inside a class
  IN=$(arr \
    "$(mkq m_x wa-ghost whatsapp_automation)" \
    "$(mkq m_p1 wa-d7 whatsapp_automation)" \
    "$(mkq m_u wa-d4 whatsapp_automation)" \
    "$(mkq m_g wa-d8 whatsapp_automation)" \
    "$(mkq m_f wa-2 whatsapp_automation)" \
    "$(mkq m_d2 ga-hq3 gascity)" \
    "$(mkq m_d1 wa-d1 whatsapp_automation)" \
    "$(mkq m_n wa-d2 whatsapp_automation)")
  OUT=$(run_enrich "$IN")
  R=$(run_select "$OUT")
  order_is "dano bugs (HQ and rig) -> P0 features -> other P0 (no label, unreadable labels) -> P1 -> unreadable source" "$R" "m_d1,m_d2,m_f,m_g,m_n,m_u,m_p1,m_x"
  eq "classes" "$(sel_summ "$R")" "m_d1[P0/dano-ao-vivo] m_d2[P0/dano-ao-vivo] m_f[P0/feature] m_g[P0/feature] m_n[P0/other] m_u[P0/other] m_p1[P1/other] m_x[unreadable]"
  eq "the label on a P0 feature and on a P1 bug is reported as ignored; unreadable labels are not 'ignored'" "$(sel_ignored "$R")" "m_g,m_p1"

  echo "── B17. the enrichment with labels survives set -euo pipefail, on a clean read and on unreadable labels ──"
  OUT=$(run_enrich_strict "$(arr "$(mkq t1 wa-d1 whatsapp_automation)" "$(mkq t2 wa-d4 whatsapp_automation)" "$(mkq t3 wa-d2 whatsapp_automation)")")
  eq "verdicts under strict mode" "$(printf '%s' "$OUT" | jq -c '[.[].src_class.dano]')" '["yes","unreadable","no"]'
  has "$WORK/enrich-strict.err" '^rc=0$' "returned 0 under strict mode with unreadable labels"
fi

echo ""
echo "== gate-q8tj7p-queue-order: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
