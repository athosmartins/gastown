#!/usr/bin/env bash
# patrol-next-wisp.sh — ga-d8dfjg9 (same class as ga-jhsxo4p, mol-witness-patrol, and ga-x9jivyf, mol-deacon-patrol).
#
# ## Contents
#   - What it does
#   - Usage and exit codes
#   - The three states
#   - Why one script
#
# ## What it does
# A patrol agent (the refinery, the deacon) keeps ONE live patrol wisp per iteration and pours the next one before it burns the
# current one. The native text for that was a copy of the same ~20 lines in 8 places (5 steps of mol-refinery-patrol, 2 blocks of the
# refinery prompt, the deacon prompt's bootstrap and its "No Idle" fallback), and every copy had at least one of these holes:
#   - it POURED WITHOUT READING FIRST, so a re-run after "the pour worked, the next leg did not" poured a second next wisp;
#   - an assign that failed left the wisp it had just poured with NO OWNER (no `--assignee` read finds it, and the wisp reaper only
#     closes a wisp whose parent is closed; a root-only patrol wisp has none), and the block went on or stopped without cleaning it;
#   - the "which wisp is mine" read used `--type=wisp` (an INVALID enum, ga-3v2n4) without `--include-infra`, and read a FAILED
#     read as "I have no wisp", so a Dolt timeout under load looked like an empty hook;
#   - the bootstrap in the prompts poured unconditionally (`WISP=$(... | jq -r '.new_epic_id')`, no `// empty`, then an update whose
#     exit code nobody read), so every session start poured one more wisp whether or not it already had one;
#   - the current wisp came from `GC_BEAD_ID`, which is fixed when the session starts: from the second iteration on it names a wisp
#     that is already burned, and the real current one was never burned.
# Measured 2026-11-13 on the live city: 4 unassigned mol-deacon-patrol wisps (ga-wisp-fpvuw5e, -tfbf9fg, -i855mog, -28dfmg) sit open
# with no owner: the shape of leak this class leaves (what produced those four was not traced).
#
# ## Usage and exit codes
#   patrol-next-wisp.sh next      <formula> [--burn-current] [-- <pour args>...]
#   patrol-next-wisp.sh bootstrap <formula>                   [-- <pour args>...]
#   <pour args> go to `gc bd mol wisp <formula> --root-only <pour args> --json` as given (e.g. --var k=v), each one a single word.
#   Environment: GC_AGENT (the identity every other read of the agent uses; required), GC_BEAD_ID (optional, see below), PATH with gc and jq.
#   next       a NEXT wisp must exist and be assigned to $GC_AGENT. Reads first; pours only when at most one wisp of mine is live.
#              --burn-current: afterwards also burn the wisp this session is executing (what the 5 steps of the refinery formula
#              and the refinery's two prompt blocks did in the same breath).
#   bootstrap  the session has no wisp yet: pour and assign one ONLY when none of mine is live (the prompts' Startup Protocol).
#   exit 0     next: a next wisp exists and is assigned (and, with --burn-current, the current one is gone or there was none to burn).
#              bootstrap: a live wisp exists (poured now, or already there).
#   exit 1     the block could not confirm that, and it says why on stderr. Nothing is assigned or burned by guess. Safe to re-run.
#   exit 2     usage error / harness problem (no jq, no GC_AGENT, unknown mode): nothing was called.
#
# ## The three states
# Every read here has three answers, never two: tem (the read answered with rows) / não tem (it answered, and it is empty) /
# não sei (it failed, or came back unreadable). Only "não tem" lets the script pour. "Não sei" never pours, never assigns, never burns:
# the inert state, exit 1.
#   live wisps of mine (read: `gc bd list --assignee=$GC_AGENT --type=molecule --include-infra --limit=0 --json`, the rows whose
#   title is the formula's name; ids only come from this read):
#     next:       2 or more -> a next wisp already exists (this one plus a next one): no pour.   0 or 1 -> pour.
#     bootstrap:  1 or more -> I already have one: no pour.                                       0 -> pour.
#   After a pour: the id must come back (`.new_epic_id`, no id = exit 1 and mail to the mayor, nothing assigned by guess), the assign's
#   exit code is READ, and an assign that fails burns the wisp just poured (never the current one) so a re-run starts clean; when that
#   burn fails too the id goes to the mayor by mail.
#   What a re-run does NOT cover: after a COMPLETE success (next poured, assigned, current burned) exactly one wisp of mine is live, and
#   "one live" reads as "this one is the current": a second `next` run would pour again. exit 0 means "go on, do not run it again";
#   a re-run is for exit 1 only (every exit-1 path leaves the world so that the re-run converges).
#   GC_BEAD_ID is believed only while that id is in the live read: it is set once at session start, so after the first iteration it
#   names a burned wisp. A GC_BEAD_ID that is not live is ignored (not an error).
#   --burn-current picks the wisp to burn: GC_BEAD_ID when live; else, when the script just poured, the one wisp that was live before the
#   pour; else (a re-run after a failed burn) the OLDER of exactly two live wisps (created_at, both readable and different). Just
#   poured with NONE live before = nothing to burn (exit 0, it says so). Anything else is "não sei which one is current": nothing is
#   burned, exit 1, and the ids are printed.
# No `-C` pin: like mol-deacon-patrol, this uses the store the session's cwd resolves to (the refinery runs in its rig checkout, the
# deacon in the city), the same store its other `gc bd` calls use.
#
# ## Why one script
# One tested copy instead of 8 pasted ones that drift (the witness/deacon fixes each had to be re-applied by hand to its own copy).
# Proof: packs/town-deltas/assets/patrol-next-wisp.selftest.sh runs this script under a stateful fake gc with faults armed per step,
# re-running it after each failure. Works under /bin/bash 3.2.

set -uo pipefail

usage() {
  echo "usage: $0 next <formula> [--burn-current] [-- <pour args>...] | $0 bootstrap <formula> [-- <pour args>...]" >&2
  exit 2
}

MODE="${1:-}"
FORMULA="${2:-}"
[ -n "$MODE" ] && [ -n "$FORMULA" ] || usage
shift 2
case "$MODE" in next | bootstrap) ;; *) usage ;; esac

BURN_CURRENT=0
POUR_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --burn-current)
      [ "$MODE" = next ] || { echo "patrol-next-wisp: --burn-current only makes sense with 'next'" >&2; exit 2; }
      BURN_CURRENT=1
      shift
      ;;
    --)
      shift
      POUR_ARGS=("$@")
      break
      ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "patrol-next-wisp: jq is required; nothing was called." >&2; exit 2; }
[ -n "${GC_AGENT:-}" ] || { echo "patrol-next-wisp: GC_AGENT is empty -- cannot tell which wisps are mine; NOT pouring." >&2; exit 2; }

say() { echo "patrol-next-wisp: $*"; }
err() { echo "patrol-next-wisp: $*" >&2; }

# mail_mayor SUBJECT BODY: a mail that fails is said, not assumed
mail_mayor() {
  gc mail send mayor/ -s "$1" -m "$2" || err "the mail to the mayor failed too -- read the lines above, they carry the ids."
}

# vazio → a live list with no row (state "não tem"); falhou/ilegível → read_live returns 1 (state "não sei"): the caller stops, nothing is poured
# LIVE_JSON = compact array of {id, created_at} (only rows titled like the formula); N = its length
read_live() {
  local raw
  raw=$(gc bd list --assignee="$GC_AGENT" --type=molecule --include-infra --limit=0 --json) || return 1
  LIVE_JSON=$(printf '%s' "$raw" | jq -ec --arg f "$FORMULA" '
    if type != "array" then error("not an array")
    else [ .[] | select(.title == $f) | {id: (.id // error("row without id")), created_at: (.created_at // "")} ] end') || return 1
  N=$(printf '%s' "$LIVE_JSON" | jq -er 'length') || return 1
}

cant_tell() {
  err "cannot tell which patrol wisps of $GC_AGENT are live (the read failed or came back unreadable) -- NOT pouring, nothing assigned or burned; wait a minute and re-run."
  exit 1
}

# pour_and_assign: pours one wisp, assigns it to $GC_AGENT; sets NEXT. Exits 1 on any failure, after cleaning what it can.
pour_and_assign() {
  # vazio → no wisp id: a wisp MAY exist (the answer can be lost after the commit), so nothing is assigned or burned by guess and the mayor is told; falhou/ilegível → the same
  NEXT=$(gc bd mol wisp "$FORMULA" --root-only ${POUR_ARGS[@]+"${POUR_ARGS[@]}"} --json | jq -r '.new_epic_id // empty')
  case "$NEXT" in
    "" | *[!A-Za-z0-9._-]*)
      err "the pour of $FORMULA returned no usable wisp id -- a wisp MAY have been created and left unassigned; nothing assigned, nothing burned."
      mail_mayor "PATROL: $FORMULA pour returned no wisp id" "patrol-next-wisp poured $FORMULA for $GC_AGENT and got no usable wisp id back (the pour failed, or its answer was lost after the wisp was created). A stray unassigned wisp may exist; look with: gc bd list --no-assignee --type=molecule --include-infra --status=open --limit=0 --json -- and burn a $FORMULA wisp you find there with: gc bd mol burn <id> --force."
      exit 1
      ;;
  esac
  # a write, not a read: when the assign fails, burn the wisp just poured (never the current one) so a re-run starts clean; when the burn fails too, say so and mail the id
  if ! gc bd update "$NEXT" --assignee="$GC_AGENT"; then
    if gc bd mol burn "$NEXT" --force; then
      err "could not assign $NEXT to $GC_AGENT -- burned it, nothing left behind; wait a minute and re-run."
    else
      err "could not assign $NEXT to $GC_AGENT and could not burn it either -- $NEXT is LEFT BEHIND (probably unassigned); the mayor is mailed with its id."
      mail_mayor "PATROL: $FORMULA left a stray wisp $NEXT" "patrol-next-wisp poured $NEXT for $GC_AGENT but could neither assign nor burn it. If it is unassigned, no assignee read finds it, and the wisp reaper only closes a wisp whose parent is closed (a root-only patrol wisp has no parent). Clean up with: gc bd mol burn $NEXT --force."
    fi
    exit 1
  fi
}

read_live || cant_tell

if [ "$MODE" = bootstrap ]; then
  if [ "$N" -ge 1 ]; then
    say "bootstrap: I already have $N live $FORMULA wisp(s) ($(printf '%s' "$LIVE_JSON" | jq -r 'map(.id) | join(" ")')) -- NOT pouring another; follow the formula."
    exit 0
  fi
  pour_and_assign
  say "bootstrap: wisp $NEXT is poured and assigned to $GC_AGENT; follow the formula."
  exit 0
fi

# ---- next ----
CUR=""
if [ -n "${GC_BEAD_ID:-}" ] && printf '%s' "$LIVE_JSON" | jq -e --arg id "$GC_BEAD_ID" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
  CUR="$GC_BEAD_ID"
fi

POURED=0
if [ "$N" -ge 2 ]; then
  say "next: a next wisp already exists ($N live $FORMULA wisps are assigned to $GC_AGENT, the current one included) -- NOT pouring another."
else
  [ "$N" -eq 1 ] && ONLY_LIVE=$(printf '%s' "$LIVE_JSON" | jq -r '.[0].id') || ONLY_LIVE=""
  pour_and_assign
  POURED=1
  say "next: next wisp $NEXT is poured and assigned to $GC_AGENT."
fi

[ "$BURN_CURRENT" -eq 1 ] || exit 0

# ---- --burn-current: which wisp is the one this session is executing? ----
TO_BURN="$CUR"
if [ -z "$TO_BURN" ]; then
  if [ "$POURED" -eq 1 ]; then
    # 0 live before the pour -> there was nothing to burn (the "not found" this used to be an error for); 1 -> that one is the current
    TO_BURN="$ONLY_LIVE"
  else
    # a re-run after a failed burn: exactly two live, the older one is the current (the next is always poured after it)
    TO_BURN=$(printf '%s' "$LIVE_JSON" | jq -r 'if length == 2 and all(.[]; .created_at != "") and (.[0].created_at != .[1].created_at) then (sort_by(.created_at) | .[0].id) else empty end')
    if [ -z "$TO_BURN" ]; then
      err "next wisp exists, but I cannot tell which of the live wisps is the CURRENT one ($(printf '%s' "$LIVE_JSON" | jq -r 'map(.id) | join(" ")')): GC_BEAD_ID is not one of them and created_at does not settle it. Nothing burned; burn the one you are executing by hand: gc bd mol burn <id> --force"
      exit 1
    fi
  fi
fi
if [ -z "$TO_BURN" ]; then
  say "no current wisp to burn (none was live before the pour)."
  exit 0
fi
if ! gc bd mol burn "$TO_BURN" --force; then
  err "next wisp is ready, but burning the current wisp $TO_BURN failed -- it is NOT burned; wait a minute and re-run (the re-run will not pour again)."
  exit 1
fi
say "burned the current wisp $TO_BURN."
exit 0
