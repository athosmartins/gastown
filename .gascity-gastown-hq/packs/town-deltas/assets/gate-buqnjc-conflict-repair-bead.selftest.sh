#!/usr/bin/env bash
# gate-buqnjc-conflict-repair-bead.selftest.sh (ga-buqnjc, 2026-10-12)
#
# CLASS: a genuine merge conflict with NO live author ended in a mail to the Mayor, and the Mayor rebased by
# hand — four times on 12/10 (ga-wuwuk7 x2, ga-pfc2ww, ga-atsahv.3), every one a text-only conflict in a runbook
# or a comment. The dead-author park now opens ONE repair bead for the dog pool instead (gate_open_conflict_
# repair_bead); the dog rebases keeping both sides, tests the touched files and re-submits. The Mayor is mailed
# only when no repair bead covers the branch.
#
# What this file locks:
#   1. the helper, on its own, against a STATEFUL bd stub (state lives in files — `$(bd create ...)` runs the stub in
#      a subshell, so a variable would be lost):
#        * opens exactly one bead: routed gc.routed_to=gastown.dog, labelled for dedup (branch + repo + marker), carrying
#          the branch, the conflicting files, the marker and the rule "manter o comportamento dos DOIS lados"
#        * no duplicates: an OPEN repair bead for the branch IN THIS REPO -> `existing`, nothing created, and the new
#          marker is linked to that bead (the watchdog finds a bead by marker)
#        * IDENTITY (gate-fix 1): a branch NAME is not an identity — the same name in another repo is not "a dog is on it",
#          for the open-bead lookup AND the attempt cap; a repo that is empty/"unknown" is never a match (-> the mail)
#        * attempt cap: a branch that already spent MAX_ATTEMPTS repair beads in this repo (closed ones count) -> fallback
#        * open cap: MAX_OPEN dogs already queued (city-wide, on purpose) -> fallback
#        * every state it cannot confirm falls back to the MAIL, never to silence: list failed / non-JSON / error
#          envelope / empty, create failed / empty / not a bead id (worded "unconfirmed": a bead may exist), the link
#          to an existing bead failed, kill switch, merge-commit-in-range, a branch/marker that cannot be a label, a
#          repo that cannot be confirmed, a bad cap setting
#        * the bd stub models --all / -l / --limit (closed hidden without --all, -l ANDed, cut at 50 without --limit 0),
#          and the source is drift-guarded on those three flags: dropping one is a failing test, not a silent pass
#        * returns 0 under `set -eu` in every one of those, and tolerates missing arguments
#   2. the dead-conflict park block extracted from the LIVE dispatcher (sentinel ga-8dehbc-park-dead-conflict):
#        * repair bead opened/existing -> NO mail to the Mayor; marker comment names the bead; source bead still
#          wears gate:needs-rebase; event/verdict keep their names
#        * the same marker swept twice -> ONE create (the acceptance: "no duplicates")
#        * no repair bead -> the Mayor mail, with the reason in it
#        * the park itself skipped (external transition respected) -> no bead, no mail, no comment
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-buqnjc-conflict-repair-bead.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

if /bin/bash -n "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher does NOT parse under /bin/bash 3.2"
fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

declare -F gate_open_conflict_repair_bead >/dev/null 2>&1 \
  || { echo "FATAL: gate_open_conflict_repair_bead is not defined (ga-buqnjc missing?)" >&2; exit 2; }

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/buqnjc.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
ROWS="$WORK/rows.json"; CREATES="$WORK/creates"; BDLOG="$WORK/bd.log"; COMMENTS="$WORK/comments"; GCLOG="$WORK/gc.log"
WARNS="$WORK/warn.log"; LABELS_BEAD="$WORK/bead-labels"; STATUS_LOG="$WORK/status.log"; REPAIR_ADDS="$WORK/repair-adds"

# ── the stateful bd stub ──────────────────────────────────────────────────────────
GC_CITY="test-city"; BEAD_CITY="bead-city"
MARKER_ID="m-buqnjc"; BEAD_ID="bead-buqnjc"; BRANCH="fix/ga-buqnjc-fixture"
LIST_MODE=ok; CREATE_MODE=ok; LABEL_MODE=ok; MARK_LABELS="type:quality-gate-marker gate-status:dispatching"; MARK_STATUS=open
labs_json() { local l first=1 out=""; for l in $1; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$l\""; done; printf '%s' "$out"; }
bd() {
  printf '%s\n' "$*" | head -1 >> "$BDLOG"
  case "${3:-}" in
    list)
      case "$LIST_MODE" in
        fail)     return 1 ;;
        garbage)  echo "bd: something broke"; return 0 ;;
        envelope) echo '{"error":"database is locked"}'; return 0 ;;
        empty)    return 0 ;;
        *)
          # Models the three bd behaviours the helper's correctness hangs on (gate-fix 1, ga-buqnjc): closed beads are HIDDEN
          # unless --all is given, repeated -l filters are ANDed, and the result is cut at 50 rows unless --limit 0 (bd's default).
          # A stub that returned everything for any flags is what let a dropped --all / --limit pass the old suite.
          local _all=0 _limit=50 _filters="" _a _prev=""
          shift 3
          for _a in "$@"; do
            case "$_prev" in --limit) _limit="$_a" ;; -l) _filters="$_filters $_a" ;; esac
            [ "$_a" = "--all" ] && _all=1
            _prev="$_a"
          done
          jq -c --argjson all "$_all" --argjson limit "$_limit" --arg filters "$_filters" '
            ($filters | split(" ") | map(select(length > 0))) as $f
            | [ .[] | select($all == 1 or .status != "closed")
                    | select(. as $r | all($f[]; . as $x | (($r.labels // []) | index($x)) != null)) ]
            | if $limit == 0 then . else .[0:$limit] end' "$ROWS"
          return 0 ;;
      esac ;;
    create)
      case "$CREATE_MODE" in
        fail)    return 1 ;;
        empty)   return 0 ;;
        garbage) echo "Error: could not create issue"; return 0 ;;
      esac
      local n id args=() a want_l=0 want_d=0 labs="" desc="" title="${4:-}"
      n=$(( $(ls "$CREATES" 2>/dev/null | wc -l) + 1 ))
      id="ga-rep$n"
      shift 4   # drop: -C <city> create <title>
      for a in "$@"; do
        if [ "$want_l" = 1 ]; then labs="$labs $a"; want_l=0; continue; fi
        if [ "$want_d" = 1 ]; then desc="$a"; want_d=0; continue; fi
        case "$a" in -l) want_l=1 ;; -d) want_d=1 ;; esac
      done
      { printf 'ID=%s\nTITLE=%s\nARGS=%s\nLABELS=%s\n----DESC----\n%s\n' "$id" "$title" "$*" "${labs# }" "$desc"; } > "$CREATES/$id"
      jq -c --arg id "$id" --arg t "$title" --argjson labels "$(printf '%s\n' $labs | jq -R . | jq -sc .)" \
        '. + [{id:$id,title:$t,status:"open",created_at:"2026-10-12T20:00:00Z",labels:$labels}]' "$ROWS" > "$ROWS.new" && mv "$ROWS.new" "$ROWS"
      echo "$id"; return 0 ;;
    show)
      if [ "${4:-}" = "$MARKER_ID" ]; then
        printf '[{"id":"%s","status":"%s","labels":[%s]}]' "$MARKER_ID" "$MARK_STATUS" "$(labs_json "$MARK_LABELS")"; return 0
      fi
      printf '[{"id":"%s","status":"open","labels":[]}]' "${4:-}"; return 0 ;;
    label)
      if [ "${5:-}" = "$BEAD_ID" ] && [ "${4:-}" = "add" ]; then echo "${6:-}" >> "$LABELS_BEAD"; fi
      # a label added to a REPAIR bead (anything but the source bead): recorded and written into the row, or refused
      if [ "${4:-}" = "add" ] && [ "${5:-}" != "$BEAD_ID" ]; then
        [ "$LABEL_MODE" = "fail" ] && return 1
        echo "${5:-} ${6:-}" >> "$REPAIR_ADDS"
        jq -c --arg id "${5:-}" --arg l "${6:-}" 'map(if .id == $id then .labels += [$l] else . end)' "$ROWS" > "$ROWS.new" && mv "$ROWS.new" "$ROWS"
      fi
      return 0 ;;
    comment)
      printf '%s\t%s\n' "${4:-}" "$(printf '%s' "${5:-}" | tr '\n' ' ')" >> "$COMMENTS"; return 0 ;;
  esac
  return 0
}
gc() { printf '%s\n' "$*" | tr '\n' ' ' >> "$GCLOG"; echo >> "$GCLOG"; return 0; }
set_gate_status() {
  echo "$1:$2" >> "$STATUS_LOG"
  if [ "$1" = "$MARKER_ID" ]; then
    local out="" l; for l in $MARK_LABELS; do case "$l" in gate-status:*) ;; *) out="$out $l" ;; esac; done
    MARK_LABELS="${out# } gate-status:$2"
  fi
  return 0
}
warn() { echo "$*" >> "$WARNS"; return 0; }
log()  { return 0; }
err()  { echo "ERR:$*" >> "$WARNS"; return 0; }

reset_world() { # reset_world [rows-json]
  rm -rf "$CREATES"; mkdir -p "$CREATES"
  : > "$BDLOG"; : > "$COMMENTS"; : > "$GCLOG"; : > "$WARNS"; : > "$LABELS_BEAD"; : > "$STATUS_LOG"; : > "$REPAIR_ADDS"
  printf '%s' "${1:-[]}" > "$ROWS"
  LIST_MODE=ok; CREATE_MODE=ok; LABEL_MODE=ok
  MARK_LABELS="type:quality-gate-marker gate-status:dispatching"; MARK_STATUS=open
  GATE_CONFLICT_REPAIR_ENABLED=1; GATE_CONFLICT_REPAIR_MAX_ATTEMPTS=3; GATE_CONFLICT_REPAIR_MAX_OPEN=3
  REBASE_EVENT="PRESET-EVENT"; REBASE_VERDICT="PRESET-VERDICT"; _REQUEUE_RESPECTED=""
}
creates_n() { ls "$CREATES" 2>/dev/null | wc -l | tr -d ' '; }
row() { # row <id> <status> <branch> [repo=/repo/fixture] [marker=m-old]   (a repair bead as the dispatcher labels it)
  printf '{"id":"%s","status":"%s","created_at":"2026-10-12T19:00:00Z","labels":["gate-conflict-repair","conflict-repair-of:%s","conflict-repair-branch:%s","conflict-repair-repo:%s"]}' \
    "$1" "$2" "${5:-m-old}" "$3" "${4:-/repo/fixture}"
}
unrelated() { # unrelated <id> <status> — an open bead that is NOT a repair bead (no gate-conflict-repair label)
  printf '{"id":"%s","status":"%s","created_at":"2026-10-12T19:00:00Z","labels":["story:in-flight"]}' "$1" "$2"
}
adds_n() { grep -c . "$REPAIR_ADDS" 2>/dev/null || true; }
call_helper() { gate_open_conflict_repair_bead "$MARKER_ID" "$BRANCH" "$BEAD_ID" "rig-fixture" "/repo/fixture" "docs/a.md scripts/b.sh" "abc1234" "trace-xyz" "main" "${1:-0}"; }

# ── 1. the helper on its own ──────────────────────────────────────────────────────
echo "── 1. gate_open_conflict_repair_bead ──"
reset_world "[]"
call_helper; RC=$?
CF="$CREATES/ga-rep1"
if [ "$RC" = 0 ] && [ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && [ "$GATE_CONFLICT_REPAIR_BEAD" = "ga-rep1" ] && [ "$(creates_n)" = 1 ]; then
  ok "no repair bead yet → opened exactly one (ga-rep1), rc 0"
else
  bad "expected opened/ga-rep1/1 create, got result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] creates=$(creates_n) rc=$RC"
fi
CT="$(cat "$CF" 2>/dev/null)"
if has "$CT" "ARGS=-t task -p 2" && has "$CT" '--metadata {"gc.routed_to":"gastown.dog"}' && has "$CT" "--silent"; then
  ok "the bead is a task routed gc.routed_to=gastown.dog (the dog pool's probe key) and asks bd for the bare id"
else
  bad "create args wrong: $(grep '^ARGS=' "$CF" | cut -c1-300)"
fi
if has "$CT" "LABELS=gate-conflict-repair conflict-repair-of:$MARKER_ID conflict-repair-branch:$BRANCH conflict-repair-repo:/repo/fixture"; then
  ok "labels carry the dedup keys: gate-conflict-repair, conflict-repair-of:<marker>, conflict-repair-branch:<branch>, conflict-repair-repo:<path> (the branch's identity is branch AND repo)"
else
  bad "labels wrong: $(grep '^LABELS=' "$CF")"
fi
if has "$CT" "TITLE=gate-conflict-repair: $BRANCH"; then ok "title names the branch"; else bad "title wrong: $(grep '^TITLE=' "$CF")"; fi
MISSING=""
for needle in "branch: $BRANCH" "repo: /repo/fixture" "marker (parkeado em gate-status:needs-rebase): $MARKER_ID" "bead de origem: $BEAD_ID" \
              "docs/a.md scripts/b.sh" "origin/main quando o conflito foi visto: abc1234" "trace-xyz" "manter o comportamento dos DOIS lados" \
              "Conflito só de texto/doc/comentário = juntar os dois lados" "git rebase origin/main" "force-with-lease" "docs/gate-marker-recipe.md" \
              "ESCALAR" "gc runtime drain-ack" "git -C <repo> worktree remove --force <dir-scratch>" "branch -D repair/<id-deste-bead>"; do
  has "$CT" "$needle" || MISSING="$MISSING [$needle]"
done
[ -z "$MISSING" ] && ok "the description carries the branch, repo, marker, source bead, conflicting files, the 'keep both sides' rule, the rebase/test/push/re-submit steps, the worktree+branch cleanup (no rm -rf) and the escalation exit" \
  || bad "description is missing:$MISSING"
if ! has "$CT" 'gc bd close <este-bead>' ; then bad "description lost its close instruction"; else ok "the dog is told to close the bead and drain-ack"; fi

# dedup: the next sweep over the same branch
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "existing" ] && [ "$GATE_CONFLICT_REPAIR_BEAD" = "ga-rep1" ] && [ "$(creates_n)" = 1 ]; then
  ok "NO DUPLICATES: a second call for the same branch finds the open bead → existing (ga-rep1), nothing created"
else
  bad "second call must not create: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] creates=$(creates_n)"
fi
# the re-submission mints a NEW marker for the same branch: still one bead
if [ "$(adds_n)" = 0 ]; then
  ok "the SAME marker swept again needs no link: no label written (it is already on the bead)"
else
  bad "same marker must not be re-linked: adds=[$(cat "$REPAIR_ADDS")]"
fi
MARKER_BEFORE="$MARKER_ID"; MARKER_ID="m-new-marker"
call_helper
MARKER_ID="$MARKER_BEFORE"
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "existing" ] && [ "$(creates_n)" = 1 ]; then
  ok "dedup is per BRANCH+REPO, not per marker: a new marker for the same branch still finds the open bead"
else
  bad "a new marker on the same branch must reuse the open bead: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi
if [ "$(cat "$REPAIR_ADDS")" = "ga-rep1 conflict-repair-of:m-new-marker" ]; then
  ok "the new marker is LINKED to the existing bead (conflict-repair-of:m-new-marker) — the watchdog finds a bead by marker, so it holds its escalation for this marker too"
else
  bad "the new marker must be linked to ga-rep1: adds=[$(cat "$REPAIR_ADDS")]"
fi

reset_world "[$(row ga-oldc closed "$BRANCH")]"
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && [ "$(creates_n)" = 1 ]; then
  ok "a CLOSED repair bead (1 of 3 attempts) does not block a new one → opened"
else
  bad "closed bead must not block: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi

# ── identity: a branch NAME is not an identity (gate-fix 1) ──
# The reviewer's probe, verbatim: ONE open repair bead for branch X in repo B; a marker from repo A with the same branch name.
reset_world "[$(row ga-repWA open "$BRANCH" /repo/other m-wa)]"
call_helper; RC=$?
if [ "$RC" = 0 ] && [ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && [ "$GATE_CONFLICT_REPAIR_BEAD" = "ga-rep1" ] && [ "$(creates_n)" = 1 ] && [ "$(adds_n)" = 0 ]; then
  ok "IDENTITY: an open bead for the SAME branch name in ANOTHER repo is not 'a dog is on it' → this repo gets its OWN bead (ga-rep1), and the other repo's bead is not touched"
else
  bad "same branch name, other repo must open its own bead: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] creates=$(creates_n) adds=[$(cat "$REPAIR_ADDS")]"
fi
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "existing" ] && [ "$GATE_CONFLICT_REPAIR_BEAD" = "ga-rep1" ] && [ "$(creates_n)" = 1 ]; then
  ok "…and the next sweep of that repo's marker reuses ITS bead (ga-rep1), never the other repo's (ga-repWA)"
else
  bad "second sweep must find this repo's own bead: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] creates=$(creates_n)"
fi
reset_world "[$(row ga-x1 closed "$BRANCH" /repo/other),$(row ga-x2 closed "$BRANCH" /repo/other),$(row ga-x3 closed "$BRANCH" /repo/other)]"
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && [ "$(creates_n)" = 1 ]; then
  ok "IDENTITY: the attempt cap is per branch+repo — 3 closed beads of the same branch NAME in another repo do not spend this repo's attempts"
else
  bad "attempts of another repo must not count: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi
for r in "" "unknown" "/repo/with space" "/repo/with,comma"; do
  reset_world "[]"
  gate_open_conflict_repair_bead "$MARKER_ID" "$BRANCH" "$BEAD_ID" "rig-fixture" "$r" "docs/a.md" "abc1234" "trace" "main" "0"
  if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:repo-unconfirmed" ] && [ ! -s "$BDLOG" ] && [ -z "$GATE_CONFLICT_REPAIR_BEAD" ]; then
    ok "repo [$r] is not a confirmed identity → fallback:repo-unconfirmed (the Mayor), no bd call, nothing looked up or opened"
  else
    bad "repo [$r] must fall back: result=[$GATE_CONFLICT_REPAIR_RESULT] bdlog=[$(cat "$BDLOG")]"
  fi
done
reset_world "[]"; MK_SAVE="$MARKER_ID"; MARKER_ID=""; call_helper; MARKER_ID="$MK_SAVE"
[ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:marker-not-label-safe" ] && [ ! -s "$BDLOG" ] \
  && ok "an empty marker id cannot be linked or labelled → fallback:marker-not-label-safe, no bd call" || bad "empty marker: result=[$GATE_CONFLICT_REPAIR_RESULT]"

# ── the three bd flags the lookup hangs on (the review's medium finding: the old stub ignored all three) ──
reset_world "[$(row ga-oldc closed "$BRANCH"),$(row ga-oldd closed "$BRANCH"),$(row ga-olde closed "$BRANCH")]"
call_helper
if has "$GATE_CONFLICT_REPAIR_RESULT" "fallback:attempts-exhausted" && [ "$(creates_n)" = 0 ]; then
  ok "--all matters: the 3 CLOSED beads are only visible with --all, and they are what stops a branch cycling through dogs forever"
else
  bad "closed beads invisible → cap never trips: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi
FILLER=""; i=0; while [ "$i" -lt 60 ]; do FILLER="$FILLER$(row "ga-fill$i" closed "fix/filler-$i" /repo/filler),"; i=$((i+1)); done
reset_world "[${FILLER}$(row ga-late open "$BRANCH")]"
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "existing" ] && [ "$GATE_CONFLICT_REPAIR_BEAD" = "ga-late" ] && [ "$(creates_n)" = 0 ]; then
  ok "--limit 0 matters: the open bead is row 61 behind 60 closed ones — found, no duplicate (bd cuts at 50 rows without --limit 0)"
else
  bad "row 61 not seen → a duplicate dog: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] creates=$(creates_n)"
fi
reset_world "[$(unrelated ga-u1 open),$(unrelated ga-u2 open),$(unrelated ga-u3 open)]"
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && [ "$(creates_n)" = 1 ]; then
  ok "-l matters: 3 open beads that are NOT repair beads do not count toward the open cap → opened"
else
  bad "unrelated beads counted as repair beads: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi
HELPER_SRC="$(sed -n '/^gate_open_conflict_repair_bead() {/,/^}/p' "$DISPATCHER")"
LIST_LINE="$(printf '%s\n' "$HELPER_SRC" | grep 'bd -C "\$GC_CITY" list ' | head -1)"
if has "$LIST_LINE" "--json" && has "$LIST_LINE" "--all" && has "$LIST_LINE" "--limit 0" && has "$LIST_LINE" '-l "$GATE_CONFLICT_REPAIR_LABEL"'; then
  ok "source drift-guard: the helper's bd list call still carries --json --all --limit 0 -l \$GATE_CONFLICT_REPAIR_LABEL"
else
  bad "the helper's bd list call lost a flag it depends on: [$LIST_LINE]"
fi

# a bead that is open but whose id cannot be read back is not 'a dog is on it'
reset_world '[{"id":"","status":"open","created_at":"2026-10-12T19:00:00Z","labels":["gate-conflict-repair","conflict-repair-of:m-old","conflict-repair-branch:'"$BRANCH"'","conflict-repair-repo:/repo/fixture"]}]'
call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:repair-beads-unreadable" ] && [ -z "$GATE_CONFLICT_REPAIR_BEAD" ] && [ "$(creates_n)" = 0 ]; then
  ok "an open repair bead whose id is empty/unreadable → fallback:repair-beads-unreadable (never 'existing' with no bead to point at)"
else
  bad "open bead with no id: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD]"
fi
# linking a second marker to the existing bead fails → the dispatcher cannot make 'a dog is on this marker' true → the mail
reset_world "[$(row ga-rep1 open "$BRANCH")]"; LABEL_MODE=fail; MK_SAVE="$MARKER_ID"; MARKER_ID="m-second"; call_helper; MARKER_ID="$MK_SAVE"
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:marker-link-failed" ] && [ -z "$GATE_CONFLICT_REPAIR_BEAD" ] && has "$(cat "$WARNS")" "linking marker m-second"; then
  ok "the link to the existing bead fails → fallback:marker-link-failed (no bead claimed, a warning says why): the Mayor is mailed, not left to wait for a hold that will not come"
else
  bad "link failure must fall back: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD] warns=[$(cat "$WARNS")]"
fi

reset_world "[$(row ga-c1 closed "$BRANCH"),$(row ga-c2 closed "$BRANCH"),$(row ga-c3 closed "$BRANCH")]"
call_helper
if has "$GATE_CONFLICT_REPAIR_RESULT" "fallback:attempts-exhausted" && [ "$(creates_n)" = 0 ] && [ -z "$GATE_CONFLICT_REPAIR_BEAD" ]; then
  ok "ATTEMPT CAP: 3 closed repair beads on the branch → fallback (the Mayor decides), nothing created"
else
  bad "attempt cap not honoured: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi
reset_world "[$(row ga-c1 closed "$BRANCH"),$(row ga-c2 closed "$BRANCH"),$(row ga-c3 closed "$BRANCH")]"
GATE_CONFLICT_REPAIR_MAX_ATTEMPTS=4; call_helper
[ "$GATE_CONFLICT_REPAIR_RESULT" = "opened" ] && ok "the attempt cap is a setting (MAX_ATTEMPTS=4 lets a 4th bead open)" || bad "MAX_ATTEMPTS setting ignored: [$GATE_CONFLICT_REPAIR_RESULT]"

reset_world "[$(row ga-o1 open fix/a),$(row ga-o2 in_progress fix/b),$(row ga-o3 open fix/c)]"
call_helper
if has "$GATE_CONFLICT_REPAIR_RESULT" "fallback:open-cap" && [ "$(creates_n)" = 0 ]; then
  ok "OPEN CAP: 3 repair beads already open (open + in_progress count) on other branches → fallback, nothing created"
else
  bad "open cap not honoured: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
fi

for mode in fail garbage envelope empty; do
  reset_world "[]"; LIST_MODE="$mode"; call_helper
  if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:repair-beads-unreadable" ] && [ "$(creates_n)" = 0 ] && has "$(cat "$WARNS")" "could not read them"; then
    ok "list $mode → fallback:repair-beads-unreadable, NOTHING created (cannot tell whether a dog is on it), and it says so in the log"
  else
    bad "list $mode must fall back and not create: result=[$GATE_CONFLICT_REPAIR_RESULT] creates=$(creates_n)"
  fi
done
reset_world '{"not":"an array"}'; call_helper
[ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:repair-beads-unreadable" ] && ok "a JSON object (not an array) is unreadable too" || bad "object read as [$GATE_CONFLICT_REPAIR_RESULT]"

for mode in fail empty garbage; do
  reset_world "[]"; CREATE_MODE="$mode"; call_helper
  if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:create-unconfirmed" ] && [ -z "$GATE_CONFLICT_REPAIR_BEAD" ] && has "$(cat "$WARNS")" "could not CONFIRM" && has "$(cat "$WARNS")" "a bead may still exist" && has "$(cat "$WARNS")" "Mayor is mailed instead"; then
    ok "create $mode → fallback:create-unconfirmed with NO bead id claimed, and a warning that says 'could not CONFIRM' and that a bead may still exist (not 'no bead was opened')"
  else
    bad "create $mode must fall back: result=[$GATE_CONFLICT_REPAIR_RESULT] bead=[$GATE_CONFLICT_REPAIR_BEAD]"
  fi
done

reset_world "[]"; GATE_CONFLICT_REPAIR_ENABLED=0; call_helper
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:disabled" ] && [ ! -s "$BDLOG" ]; then
  ok "kill switch GATE_CONFLICT_REPAIR_ENABLED=0 → fallback:disabled, and bd is not even called"
else
  bad "kill switch: result=[$GATE_CONFLICT_REPAIR_RESULT] bdlog=[$(cat "$BDLOG")]"
fi
reset_world "[]"; call_helper 1
if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:merge-commit-in-range" ] && [ ! -s "$BDLOG" ]; then
  ok "a branch carrying a merge commit not on main (ga-kyxih: re-anchor is 'git merge', a Mayor decision) → fallback, no bd call"
else
  bad "merge-in-range: result=[$GATE_CONFLICT_REPAIR_RESULT]"
fi
for b in "fix/with,comma" "fix/with space" ""; do
  reset_world "[]"; BR_SAVE="$BRANCH"; BRANCH="$b"; call_helper; BRANCH="$BR_SAVE"
  if [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:branch-not-label-safe" ] && [ ! -s "$BDLOG" ]; then
    ok "branch [$b] cannot be a dedup label → fallback, no bd call"
  else
    bad "branch [$b]: result=[$GATE_CONFLICT_REPAIR_RESULT]"
  fi
done
for v in "x" "" "-1" "2.5"; do
  reset_world "[]"; GATE_CONFLICT_REPAIR_MAX_ATTEMPTS="$v"; call_helper
  [ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:bad-cap-setting" ] && [ ! -s "$BDLOG" ] \
    && ok "MAX_ATTEMPTS=[$v] is not a number → fallback:bad-cap-setting (never a crash, never a silent open)" || bad "MAX_ATTEMPTS=[$v]: result=[$GATE_CONFLICT_REPAIR_RESULT]"
done
reset_world "[]"; GATE_CONFLICT_REPAIR_MAX_OPEN="many"; call_helper
[ "$GATE_CONFLICT_REPAIR_RESULT" = "fallback:bad-cap-setting" ] && ok "MAX_OPEN=[many] → fallback:bad-cap-setting" || bad "MAX_OPEN bad: [$GATE_CONFLICT_REPAIR_RESULT]"

# rc 0 under set -eu in every path, even with no arguments at all.
# (a subshell writing to a file, not $(...): bash 3.2 mis-parses a `case` arm's `)` inside $(...))
seteu_scenarios() {
  set -eu
  local scenario
  for scenario in ok existing linkfail exhausted unreadable createfail disabled; do
    reset_world "[]"
    if [ "$scenario" = existing ]; then printf '%s' "[$(row ga-x open "$BRANCH" /r)]" > "$ROWS"; fi
    if [ "$scenario" = linkfail ]; then printf '%s' "[$(row ga-x open "$BRANCH" /r m-other)]" > "$ROWS"; LABEL_MODE=fail; fi
    if [ "$scenario" = exhausted ]; then printf '%s' "[$(row ga-1 closed "$BRANCH" /r),$(row ga-2 closed "$BRANCH" /r),$(row ga-3 closed "$BRANCH" /r)]" > "$ROWS"; fi
    if [ "$scenario" = unreadable ]; then LIST_MODE=fail; fi
    if [ "$scenario" = createfail ]; then CREATE_MODE=fail; fi
    if [ "$scenario" = disabled ]; then GATE_CONFLICT_REPAIR_ENABLED=0; fi
    gate_open_conflict_repair_bead "$MARKER_ID" "$BRANCH" "$BEAD_ID" "r" "/r" "f" "s" "t" "main" "0"
    echo "$scenario:$GATE_CONFLICT_REPAIR_RESULT"
  done
  gate_open_conflict_repair_bead "$MARKER_ID" "$BRANCH" "$BEAD_ID" "r" "" "f" "s" "t" "main" "0"
  echo "norepo:$GATE_CONFLICT_REPAIR_RESULT"
  gate_open_conflict_repair_bead
  echo "noargs:$GATE_CONFLICT_REPAIR_RESULT"
  echo DONE
}
( seteu_scenarios ) > "$WORK/seteu.out" 2>&1
SETEU_OUT="$(cat "$WORK/seteu.out")"
if has "$SETEU_OUT" "DONE" && ! has "$SETEU_OUT" "unbound variable"; then
  ok "returns 0 under set -eu in every path, and with no arguments at all (no unbound variable) — the dispatcher runs under set -e"
else
  bad "set -eu run did not finish cleanly: [$SETEU_OUT]"
fi

# ── 2. the live dead-conflict park block ───────────────────────────────────────────
echo "── 2. the dead-author genuine-conflict block of the LIVE dispatcher ──"
SRC="$(extract_block "$DISPATCHER" "ga-8dehbc-park-dead-conflict")"
[ -n "$SRC" ] || { echo "FATAL: sentinel block ga-8dehbc-park-dead-conflict not found (moved/renamed?)" >&2; exit 2; }
eval "run_dead_conflict() {
$SRC
}"
DEFAULT_BRANCH="main"; MAIN_HEAD_SHA="abc1234"; CONFLICT_FILES="docs/a.md scripts/b.sh"; BRANCH_HAS_MERGE_IN_RANGE=0
REBASE_LIVENESS_TRACE="trace-xyz"; RIG="rig-fixture"; RIG_PATH="/repo/fixture"
run_block() { OUT=$( set -e; run_dead_conflict; echo "RC=$?"; echo "EVENT=$REBASE_EVENT"; echo "VERDICT=$REBASE_VERDICT"; echo "RESP=${_REQUEUE_RESPECTED:-}" ) 2>&1; }
# the block runs in a $(...) subshell above, so everything it writes goes to files — read them back
mail_count() { grep -c 'mail send mayor' "$GCLOG" 2>/dev/null || true; }
marker_comment() { grep "^$MARKER_ID	" "$COMMENTS" | head -1; }
getl() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }

reset_world "[]"
run_block
MC="$(marker_comment)"
if has "$OUT" "RC=0" && [ "$(mail_count)" = 0 ] && [ "$(creates_n)" = 1 ]; then
  ok "repair bead opened → block returns 0 under set -e, ONE bead created, ZERO mails to the Mayor"
else
  bad "opened path: mails=$(mail_count) creates=$(creates_n) out=[$OUT]"
fi
if has "$MC" "Gate SKIPPED + ESCALATED (ga-q3ig2)" && has "$MC" "Repair bead ga-rep1 (opened) routed to the dog pool (ga-buqnjc)" && has "$MC" "The Mayor is NOT mailed"; then
  ok "the marker comment keeps its ga-q3ig2 head and names the repair bead and that the Mayor is not mailed"
else
  bad "marker comment wrong: [$MC]"
fi
if [ "$(cat "$LABELS_BEAD")" = "gate:needs-rebase" ] && [ "$(getl EVENT)" = "dispatcher_needs_rebase_immediate" ] \
   && has "$(getl VERDICT)" "NEEDS_REBASE (genuine conflict, dead author — immediate skip)" && has "$(getl VERDICT)" "repair bead ga-rep1"; then
  ok "the source bead still wears gate:needs-rebase; event name unchanged; verdict keeps its NEEDS_REBASE head and names the repair bead"
else
  bad "park effects changed: labels=[$(cat "$LABELS_BEAD")] event=[$(getl EVENT)] verdict=[$(getl VERDICT)]"
fi
if [ "$(cat "$STATUS_LOG")" = "$MARKER_ID:needs-rebase" ]; then ok "the marker is parked at needs-rebase exactly once"; else bad "status writes: [$(cat "$STATUS_LOG")]"; fi

# the same marker swept AGAIN (the dispatcher re-reads it every sweep until the dog re-submits)
MARK_LABELS="type:quality-gate-marker gate-status:dispatching"; : > "$GCLOG"; : > "$COMMENTS"
run_block
MC="$(marker_comment)"
if [ "$(creates_n)" = 1 ] && [ "$(mail_count)" = 0 ] && has "$MC" "Repair bead ga-rep1 (existing)"; then
  ok "THE ACCEPTANCE (no duplicates): the same marker swept twice → still ONE repair bead, still no mail; the second comment says 'existing'"
else
  bad "second sweep must reuse the bead: creates=$(creates_n) mails=$(mail_count) comment=[$MC]"
fi

reset_world "[]"; LIST_MODE=fail
run_block
MC="$(marker_comment)"; MAIL="$(cat "$GCLOG")"
if has "$OUT" "RC=0" && [ "$(mail_count)" = 1 ] && [ "$(creates_n)" = 0 ] \
   && has "$MAIL" "Gate escalation: $BRANCH genuine conflict (no live author)" && has "$MAIL" "No repair bead is CONFIRMED for the dog pool (fallback:repair-beads-unreadable, ga-buqnjc)"; then
  ok "repair beads unreadable → NO bead and the Mayor IS mailed (same subject as before), with the reason in the mail"
else
  bad "fallback path wrong: mails=$(mail_count) creates=$(creates_n) mail=[$MAIL]"
fi
if has "$MC" "Gate SKIPPED + ESCALATED (ga-q3ig2)" && has "$MC" "No repair bead confirmed (fallback:repair-beads-unreadable) — escalated to the Mayor by mail" \
   && has "$MC" "Needs re-anchor/rebuild or a Mayor decision." && ! has "$(getl VERDICT)" "repair bead"; then
  ok "fallback marker comment says the Mayor was mailed and keeps the re-anchor advice; the verdict does not claim a repair bead"
else
  bad "fallback comment/verdict wrong: [$MC] verdict=[$(getl VERDICT)]"
fi

# the repo the park block hands the helper is RIG_PATH: an unresolved one must reach the Mayor, not a dog
reset_world "[]"; RIG_PATH_SAVE="$RIG_PATH"; RIG_PATH=""
run_block
MC="$(marker_comment)"; MAIL="$(cat "$GCLOG")"
if [ "$(mail_count)" = 1 ] && [ "$(creates_n)" = 0 ] && has "$MAIL" "fallback:repo-unconfirmed" && has "$MC" "No repair bead confirmed (fallback:repo-unconfirmed)"; then
  ok "no repo path (RIG_PATH empty) → NO bead, the Mayor IS mailed, and both the mail and the marker comment say why (fallback:repo-unconfirmed)"
else
  bad "unconfirmed repo in the block: mails=$(mail_count) creates=$(creates_n) mail=[$MAIL] comment=[$MC]"
fi
RIG_PATH="$RIG_PATH_SAVE"

# a SECOND marker of the same branch+repo is swept while the first one's bead is still open (the dog has not closed it yet)
reset_world "[]"
run_block
MK_SAVE="$MARKER_ID"; MARKER_ID="m-second"; MARK_LABELS="type:quality-gate-marker gate-status:dispatching"; : > "$GCLOG"; : > "$COMMENTS"
run_block
MC="$(grep "^m-second	" "$COMMENTS" | head -1)"
MARKER_ID="$MK_SAVE"
if [ "$(creates_n)" = 1 ] && [ "$(mail_count)" = 0 ] && has "$MC" "Repair bead ga-rep1 (existing)" && [ "$(cat "$REPAIR_ADDS")" = "ga-rep1 conflict-repair-of:m-second" ]; then
  ok "a second marker of the same branch+repo → still ONE bead, no mail, and the second marker is linked to it (so the watchdog holds ITS escalation too)"
else
  bad "second marker: creates=$(creates_n) mails=$(mail_count) comment=[$MC] adds=[$(cat "$REPAIR_ADDS")]"
fi

reset_world "[]"; CREATE_MODE=garbage
run_block
MAIL="$(cat "$GCLOG")"
if [ "$(mail_count)" = 1 ] && has "$MAIL" "No repair bead is CONFIRMED" && has "$MAIL" "create-unconfirmed" && has "$MAIL" "one may still exist" \
   && has "$MAIL" "bd list --all -l gate-conflict-repair -l conflict-repair-branch:$BRANCH"; then
  ok "create unconfirmed → the Mayor's mail says a bead MAY exist and gives the exact lookup to run before rebasing by hand (a dog and the Mayor must not both start the same rebase)"
else
  bad "create-unconfirmed mail wording: [$MAIL]"
fi

reset_world "[]"; BRANCH_HAS_MERGE_IN_RANGE=1
run_block
MC="$(marker_comment)"
if [ "$(mail_count)" = 1 ] && [ "$(creates_n)" = 0 ] && has "$MC" "re-anchoring means 'git merge origin/main'"; then
  ok "a branch with a merge commit in range → Mayor mail, and the comment keeps the ga-kyxih 'git merge, not a rebase' advice"
else
  bad "merge-in-range block: mails=$(mail_count) creates=$(creates_n) comment=[$MC]"
fi
BRANCH_HAS_MERGE_IN_RANGE=0

for ext in deferred error passed failed superseded; do
  reset_world "[]"; MARK_LABELS="type:quality-gate-marker gate-status:dispatching gate-status:$ext"
  run_block
  if [ "$(creates_n)" = 0 ] && [ "$(mail_count)" = 0 ] && [ -z "$(marker_comment)" ] && [ ! -s "$LABELS_BEAD" ] && has "$(getl VERDICT)" "PARK-SKIPPED"; then
    ok "external gate-status:$ext respected → the park is skipped: NO repair bead, NO mail, NO comment, NO source-bead label (nothing was parked)"
  else
    bad "external $ext must skip everything: creates=$(creates_n) mails=$(mail_count) comment=[$(marker_comment)] labels=[$(cat "$LABELS_BEAD")] verdict=[$(getl VERDICT)]"
  fi
done
reset_world "[]"; MARK_STATUS=closed
run_block
if [ "$(creates_n)" = 0 ] && [ "$(mail_count)" = 0 ] && [ -z "$(marker_comment)" ]; then
  ok "marker closed mid-sweep → no repair bead, no mail, no comment"
else
  bad "closed marker: creates=$(creates_n) mails=$(mail_count)"
fi

# ── 3. drift guards ───────────────────────────────────────────────────────────────
echo "── 3. source drift-guards ──"
case "$SRC" in
  *'mail send mayor'*) ok "the block still carries the Mayor mail (the fallback arm)" ;;
  *) bad "the block lost its fallback mail — an unreadable or exhausted repair path would be SILENT" ;;
esac
N_CALLS="$(printf '%s\n' "$SRC" | grep -c '^ *gate_open_conflict_repair_bead ')"
eq "the block calls the helper exactly once (comment mentions excluded)" "$N_CALLS" "1"
# the mail must sit inside the case arm that handles "no repair bead" — i.e. after the helper call and inside a `*)` arm
AWK_OUT="$(printf '%s\n' "$SRC" | awk '/gate_open_conflict_repair_bead/{seen=1} seen && /^ *\*\)/{arm=1} arm && /mail send mayor/{print "IN-FALLBACK-ARM"; exit} /mail send mayor/ && !arm{print "OUTSIDE"; exit}')"
eq "the Mayor mail is only reachable from the fallback arm of the case on the helper's result" "$AWK_OUT" "IN-FALLBACK-ARM"
if grep -q 'GATE_CONFLICT_REPAIR_ENABLED:-1' "$DISPATCHER"; then ok "the helper is ON by default (the acceptance: the next real case is resolved without the Mayor)"; else bad "GATE_CONFLICT_REPAIR_ENABLED must default to 1"; fi
if grep -q 'conflict_repair_state' "$SELF_DIR/../../../scripts/gate-recovery-watchdog.py" 2>/dev/null; then
  ok "the watchdog (FIX 9) reads the same repair beads — it holds its own Mayor escalation while one is open"
else
  bad "gate-recovery-watchdog.py has no conflict_repair_state — FIX 9 would mail the Mayor ~15min after the dispatcher opened the bead"
fi
WD_FILE="$SELF_DIR/../../../scripts/gate-recovery-watchdog.py"
if grep -q 'want = "conflict-repair-of:%s" % marker_id' "$WD_FILE" 2>/dev/null && ! grep -q 'want = "conflict-repair-branch' "$WD_FILE" 2>/dev/null; then
  ok "the watchdog looks a repair bead up by MARKER (conflict-repair-of:<marker>), not by branch name — and the dispatcher writes that label at create and when it reuses a bead"
else
  bad "gate-recovery-watchdog.py conflict_repair_state must key on conflict-repair-of:<marker> (a branch name recurs across repos)"
fi
LBL_D="$(sed -n 's/^GATE_CONFLICT_REPAIR_LABEL="\(.*\)"/\1/p' "$DISPATCHER" | head -1)"
LBL_W="$(sed -n 's/^CONFLICT_REPAIR_LABEL = "\(.*\)"/\1/p' "$SELF_DIR/../../../scripts/gate-recovery-watchdog.py" | head -1)"
if [ -n "$LBL_D" ] && [ "$LBL_D" = "$LBL_W" ]; then ok "dispatcher and watchdog use the SAME repair label ($LBL_D)"; else bad "label drift: dispatcher=[$LBL_D] watchdog=[$LBL_W]"; fi

echo
echo "gate-buqnjc-conflict-repair-bead.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
