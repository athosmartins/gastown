#!/usr/bin/env bash
# gate-remote-reviewers.selftest.sh (ga-2hd02v.1.9) — o gate abre o revisor no nó Hetzner primeiro e no mini só se o nó não puder
#
# Contents
#   0 compile-guard · 1 flag (3 estados) · 2 estado do nó (room/full/unready/unknown) · 3 Bash 3.2 sob set -euo pipefail
#   4 o dispatcher: bloco de carga, spawn node-first, re-convocação, ponteiro desligado no slot remoto
#   5 o template: agent.toml, prompt (terceiro estado byte a byte), nome casa com o híbrido e com o atalho
#   6 mutantes — cada regra tem que reprovar quando a regra é arrancada
#
# O que isto prova e o que NÃO prova. Prova a ESCOLHA e a COSTURA, com `gc`, `bd` e o `gc-session-ssh` de mentira: nada abre sessão,
# nada fala com o nó. NÃO prova que um revisor do nó termina uma revisão nem que o veredito dele bate com o do local: isso só se mede com
# o nó ligado (docs/runbooks/gate-reviewer-remote.md, "Provar").
#
# Roda sem Dolt, sem launchd, sem rede. Sai 0 sse toda asserção vale.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CITY_SRC="$(cd "$SELF_DIR/../../.." && pwd)"
LIB="$SELF_DIR/gate-remote-reviewers.lib.sh"
DISPATCHER="${DISPATCHER_UNDER_TEST:-$SELF_DIR/quality-gate-dispatcher.sh}"
LOCAL_PROMPT="$CITY_SRC/agents/gate-reviewer/prompt.template.md"
REMOTE_PROMPT="$CITY_SRC/agents/gate-reviewer-remote/prompt.template.md"
REMOTE_TOML="$CITY_SRC/agents/gate-reviewer-remote/agent.toml"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }
hasF() { if grep -qF -- "$2" "$1"; then ok "$3"; else bad "$3 — not found: $2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "── 0. compile-guard ──"
for _f in "$LIB" "$DISPATCHER"; do
  if bash -n "$_f" 2>/dev/null; then ok "$(basename "$_f"): bash -n clean"; else bad "$(basename "$_f"): bash -n FAILED"; fi
  if /bin/bash -n "$_f" 2>/dev/null; then ok "$(basename "$_f"): system bash -n clean"; else bad "$(basename "$_f"): system bash -n FAILED"; fi
done

# ── fixtures ───────────────────────────────────────────────────────────────────────────────────────────────────
# mkcity <dir>: a throwaway city with a good host config, the real agent.toml, a fake provider and NO flag.
mkcity() {
  local c="$1"
  mkdir -p "$c/.gc" "$c/scripts" "$c/agents/gate-reviewer-remote"
  cp "$REMOTE_TOML" "$c/agents/gate-reviewer-remote/agent.toml"
  cat > "$c/.gc/session-ssh.json" <<'JSON'
{"default_host":"hetzner","hosts":{"hetzner":{"ssh":"hetzner-teste","cap":4,"remote_root":"/r","remote_home":"/h","real_sessions_released_by":"mayor test","worktree_rigs":{"dog":"gascity","gate-reviewer":"gascity"}}}}
JSON
  cat > "$c/scripts/gc-session-ssh" <<'SH'
#!/bin/sh
echo "$*" >> "${FAKE_SSH_LOG:-/dev/null}"
case "${FAKE_SSH_MODE:-room}" in
  room)    echo dog-remote-adhoc-aaaaaaaaaa ;;
  empty)   : ;;
  full4)   printf 'dog-remote-adhoc-1\nwa-worker-remote-2\nx-3\ny-4\n' ;;
  rev2)    printf 'gate-reviewer-remote-adhoc-0000000001\ngate-reviewer-remote-adhoc-0000000002\n' ;;
  down)    echo "ssh: connect to host hetzner-teste port 22: Operation timed out" >&2; exit 1 ;;
  garbage) echo "Welcome to Ubuntu 24.04 - some banner" ;;
  partial) echo dog-remote-adhoc-aaaaaaaaaa; echo "second host unreachable" >&2; exit 1 ;;
  hang)    exec sleep 8 ;;
esac
SH
  chmod +x "$c/scripts/gc-session-ssh"
}
flag_on()  { : > "$1/.gc/gate-remote-reviewers.on"; }
cfg_edit() { python3 -I - "$1/.gc/session-ssh.json" "$2" <<'PY'
import json, sys
p, expr = sys.argv[1], sys.argv[2]
d = json.load(open(p)); h = d["hosts"]["hetzner"]
exec(expr)
json.dump(d, open(p, "w"))
PY
}

# pick <lib> <city> [KEY=VAL ...] → "<template>|<kind>|<why>" run under the dispatcher's own strict mode.
pick() {
  local lib="$1" city="$2"; shift 2
  ( env GC_CITY="$city" "$@" bash -c 'set -euo pipefail; source "$0"; gate_remote_pick_template; printf "%s|%s|%s" "$GATE_REMOTE_PICK_TEMPLATE" "$GATE_REMOTE_PICK_KIND" "$GATE_REMOTE_PICK_WHY"' "$lib" 2>&1 )
}
tpl()  { printf '%s' "${1%%|*}"; }
kind() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }

C="$TMP/city"; mkcity "$C"

echo "── 1. the flag: on / off / UNREADABLE (three states, only 'on' looks at the node) ──"
R="$(pick "$LIB" "$C")";                                   eq "no flag → local" "$(tpl "$R")" "gate-reviewer"; eq "…and says nothing (inert)" "$(kind "$R")" "inert"
flag_on "$C"
R="$(pick "$LIB" "$C")";                                   eq "flag on + node has room → the REMOTE template" "$(tpl "$R")" "gate-reviewer-remote"; eq "…kind=node" "$(kind "$R")" "node"
rm -f "$C/.gc/gate-remote-reviewers.on"; ln -s "$TMP/nowhere" "$C/.gc/gate-remote-reviewers.on"
R="$(pick "$LIB" "$C")";                                   eq "flag is a broken link (cannot tell) → local" "$(tpl "$R")" "gate-reviewer"; eq "…kind=fallback, not inert (the log must say it)" "$(kind "$R")" "fallback"; has "…and names the cause" "$R" "UNREADABLE"
rm -f "$C/.gc/gate-remote-reviewers.on"; flag_on "$C"
if [ "$(id -u)" != "0" ]; then
  chmod 000 "$C/.gc/gate-remote-reviewers.on"
  R="$(pick "$LIB" "$C")";                                 eq "flag exists but cannot be read → local, kind=fallback" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"
  chmod 644 "$C/.gc/gate-remote-reviewers.on"
else ok "(running as root: the chmod 000 case is not meaningful, skipped)"; fi
C2="$TMP/city-nogc"; mkcity "$C2"; flag_on "$C2"; rm -f "$C2/.gc/gate-remote-reviewers.on"; mv "$C2/.gc" "$C2/.gc.away"
R="$(pick "$LIB" "$C2")";                                  eq "the .gc folder cannot be seen → local, kind=fallback" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"
R="$(pick "$LIB" "" GATE_REMOTE_FLAG_FILE="")";            eq "GC_CITY empty and no override → local, kind=fallback" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"

echo "── 2. the node: room / full / unready / UNKNOWN (unknown is never room) ──"
SSHLOG="$TMP/ssh.log"; : > "$SSHLOG"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=room FAKE_SSH_LOG="$SSHLOG")"; eq "one session on the node (cap 4) → room → remote" "$(tpl "$R")" "gate-reviewer-remote"
eq "the question asked is exactly 'list-running'" "$(cat "$SSHLOG")" "list-running"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=empty)";   eq "empty list with rc 0 = nobody there = room" "$(tpl "$R")" "gate-reviewer-remote"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=full4)";   eq "4 of 4 sessions on the node → local" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"; has "…and says full" "$R" "full"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=rev2)";    eq "2 of 2 remote reviewers (host not full: 2 of 4) → local by the TEMPLATE cap" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"; has "…and says which cap" "$R" "gate-reviewer-remote sessions"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=down)";    eq "host unreachable (rc 1) → local, NOT room" "$(tpl "$R")" "gate-reviewer"; has "…says unknown" "$R" "unknown"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=partial)"; eq "partial list + rc 1 (one host answered, another did not) → local" "$(tpl "$R")" "gate-reviewer"
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=garbage)"; eq "a line that is not a session name → local" "$(tpl "$R")" "gate-reviewer"
T0=$(date +%s)
R="$(pick "$LIB" "$C" FAKE_SSH_MODE=hang GATE_REMOTE_PROBE_SECS=1)"; T1=$(date +%s)
eq "a probe that hangs → local" "$(tpl "$R")" "gate-reviewer"; has "…says it timed out" "$R" "timed out"
if [ $((T1 - T0)) -le 5 ]; then ok "…and the dispatcher waited $((T1 - T0))s, not the 8s the probe wanted"; else bad "the probe was not bounded: $((T1 - T0))s"; fi
case "$(sed -n 's/^GATE_REMOTE_PROBE_SECS="\${GATE_REMOTE_PROBE_SECS:-\([0-9]*\)}"/\1/p' "$LIB")" in 30) ok "default probe bound is 30 s" ;; *) bad "default probe bound changed or unreadable" ;; esac
rm -f "$C/scripts/gc-session-ssh"
R="$(pick "$LIB" "$C")";                       eq "the provider script is missing → local" "$(tpl "$R")" "gate-reviewer"; has "…says unknown" "$R" "unknown"
mkcity "$TMP/city-b"; flag_on "$TMP/city-b"; C="$TMP/city-b"
# the host config: every unreadable cap is unknown, never an invented one
for _case in "d['hosts']['hetzner'].pop('cap')|cap missing" "h.__setitem__('cap','4')|cap is text" "h.__setitem__('cap',-1)|cap negative" "h.__setitem__('cap',1.5)|cap fractional" \
             "d.__setitem__('hosts',{})|no hosts" "d.__setitem__('hosts',[1])|hosts is not an object" "d.__setitem__('default_host','nope')|default host not in config" \
             "d['hosts'].__setitem__('other',dict(h))|two hosts, no GC_SSH_HOST"; do
  mkcity "$TMP/c3"; flag_on "$TMP/c3"; cfg_edit "$TMP/c3" "${_case%%|*}"
  R="$(pick "$LIB" "$TMP/c3")"; eq "config: ${_case##*|} → local" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"
done
mkcity "$TMP/c3"; flag_on "$TMP/c3"; cfg_edit "$TMP/c3" "d['hosts'].__setitem__('other',dict(h))"
R="$(pick "$LIB" "$TMP/c3" GC_SSH_HOST=hetzner)"; eq "…but two hosts WITH GC_SSH_HOST naming one → that host's cap decides → remote" "$(tpl "$R")" "gate-reviewer-remote"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; printf '{not json' > "$TMP/c3/.gc/session-ssh.json"
R="$(pick "$LIB" "$TMP/c3")";                  eq "config is not JSON → local" "$(tpl "$R")" "gate-reviewer"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; rm -f "$TMP/c3/.gc/session-ssh.json"
R="$(pick "$LIB" "$TMP/c3")";                  eq "config is missing → local" "$(tpl "$R")" "gate-reviewer"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; cfg_edit "$TMP/c3" "h.pop('real_sessions_released_by')"
R="$(pick "$LIB" "$TMP/c3")";                  eq "host without real_sessions_released_by → local" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"; has "…says unready (the start would be refused)" "$R" "unready"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; cfg_edit "$TMP/c3" "h['worktree_rigs'].pop('gate-reviewer')"
R="$(pick "$LIB" "$TMP/c3")";                  eq "host whose worktree_rigs has no gate-reviewer → local, no spawn attempted" "$(tpl "$R")/$(kind "$R")" "gate-reviewer/fallback"; has "…says unready" "$R" "unready"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; rm -f "$TMP/c3/agents/gate-reviewer-remote/agent.toml"
R="$(pick "$LIB" "$TMP/c3")";                  eq "template agent.toml missing (cap not read) → local" "$(tpl "$R")" "gate-reviewer"
mkcity "$TMP/c3"; flag_on "$TMP/c3"; sed -i.bak 's/^max_active_sessions *=.*/max_active_sessions = 0/' "$TMP/c3/agents/gate-reviewer-remote/agent.toml"
R="$(pick "$LIB" "$TMP/c3")";                  eq "template max_active_sessions = 0 → local" "$(tpl "$R")" "gate-reviewer"
mkdir -p "$TMP/nobin"; for _t in jq sed head dirname sh env; do ln -sf "$(command -v "$_t")" "$TMP/nobin/$_t"; done; ln -sf /bin/bash "$TMP/nobin/bash"
R="$(pick "$LIB" "$C" PATH="$TMP/nobin")";     eq "no timeout/gtimeout on the PATH → local (the probe is never run unbounded)" "$(tpl "$R")" "gate-reviewer"; has "…says so" "$R" "timeout"

echo "── 3. Bash 3.2 under the dispatcher's own strict mode ──"
mkcity "$TMP/c4"; flag_on "$TMP/c4"
R="$(env GC_CITY="$TMP/c4" /bin/bash -c 'set -euo pipefail; source "$0"; gate_remote_pick_template; printf "%s" "$GATE_REMOTE_PICK_TEMPLATE"' "$LIB" 2>&1)"
eq "/bin/bash (3.2 on macOS) sources the lib and picks remote under set -euo pipefail" "$R" "gate-reviewer-remote"
R="$(env GC_CITY="$TMP/c4" FAKE_SSH_MODE=full4 /bin/bash -c 'set -euo pipefail; source "$0"; gate_remote_pick_template; printf "%s" "$GATE_REMOTE_PICK_TEMPLATE"' "$LIB" 2>&1)"
eq "…and picks local when the node is full" "$R" "gate-reviewer"
R="$(env GC_CITY="$TMP/c4" bash -c 'set -euo pipefail; source "$0"; echo SOURCED' "$LIB" 2>&1)"
eq "sourcing prints nothing but what the caller prints (no top-level output)" "$R" "SOURCED"

echo "── 4. the dispatcher: load block, node-first spawn, re-convene, no pointer for a node slot ──"
LOADBLK="$(sed -n '/# SELFTEST-EXTRACT remote-lib-load: BEGIN/,/# SELFTEST-EXTRACT remote-lib-load: END/p' "$DISPATCHER")"
if [ -z "$LOADBLK" ]; then bad "remote-lib-load block not found in the dispatcher"; else
  ok "located the lib-load block"
  mkdir -p "$TMP/lc/packs/town-deltas/assets"
  eq "lib present → GATE_REMOTE_LIB_OK=1" "$(GC_CITY="$TMP/lc" bash -c 'set -euo pipefail; cp "$1" "$GC_CITY/packs/town-deltas/assets/"; eval "$2"; echo $GATE_REMOTE_LIB_OK' _ "$LIB" "$LOADBLK" 2>&1)" "1"
  rm -f "$TMP/lc/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
  eq "lib ABSENT → GATE_REMOTE_LIB_OK=0 and the dispatcher lives" "$(GC_CITY="$TMP/lc" bash -c 'set -euo pipefail; eval "$1"; echo $GATE_REMOTE_LIB_OK' _ "$LOADBLK" 2>&1)" "0"
  printf 'false\n' > "$TMP/lc/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
  eq "lib whose top level FAILS → 0 and the dispatcher lives (set -e)" "$(GC_CITY="$TMP/lc" bash -c 'set -euo pipefail; eval "$1"; echo "$GATE_REMOTE_LIB_OK"' _ "$LOADBLK" 2>&1)" "0"
  printf 'return 1\n' > "$TMP/lc/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
  eq "lib that does a top-level 'return 1' → 0" "$(GC_CITY="$TMP/lc" bash -c 'set -euo pipefail; eval "$1"; echo "$GATE_REMOTE_LIB_OK"' _ "$LOADBLK" 2>&1)" "0"
  printf 'x=(\n' > "$TMP/lc/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
  eq "lib with a syntax error → 0" "$(GC_CITY="$TMP/lc" bash -c 'set -euo pipefail; eval "$1"; echo "$GATE_REMOTE_LIB_OK"' _ "$LOADBLK" 2>&1 | tail -n1)" "0"
fi

# Load the dispatcher's real functions (the same way the g3m45n selftest does) and put mocks around them.
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" || { echo "FATAL: could not source the dispatcher in lib-only mode"; exit 1; }
for _fn in gate_deliver_review_task gate_review_nudge_message respawn_reviewer_slot capture_spawn_err_tail gate_bounded_spawn; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn is not defined by the dispatcher"; exit 1; }
done
# The dispatcher hard-wires GC_CITY to the live city, which does not carry this lib until it is deployed. Load the lib under test directly.
# shellcheck disable=SC1090
source "$LIB"
LOGF="$TMP/dispatcher.log"; : > "$LOGF"
log()  { printf 'LOG %s\n' "$*" >> "$LOGF"; }
warn() { printf 'WARN %s\n' "$*" >> "$LOGF"; }
err()  { printf 'ERR %s\n' "$*" >> "$LOGF"; }

SPAWNLOG="$TMP/spawn.calls"
MOCK_NODE=ok       # ok | fail | empty | timeout
MOCK_LOCAL=ok      # ok | fail
gc() {
  [ "${1:-}" = "--city" ] && shift 2
  case "${1:-} ${2:-}" in
    "session new")
      local _tpl="${3:-}"
      printf '%s\n' "$_tpl" >> "$SPAWNLOG"
      case "$_tpl" in
        gate-reviewer-remote)
          case "$MOCK_NODE" in
            ok)      echo '{"session_id":"ga-NODE","session_name":"gate-reviewer-remote-adhoc-0123456789"}'; return 0 ;;
            fail)    echo "gc session new: host hetzner is at its cap" >&2; return 1 ;;
            empty)   return 0 ;;
            timeout) echo "spawn_timeout: 'gc session new' passed 150s (exit=124)" >&2; return 124 ;;
          esac ;;
        gate-reviewer)
          if [ "$MOCK_LOCAL" = "ok" ]; then echo '{"session_id":"ga-LOCAL","session_name":"gate-reviewer-LOCAL"}'; return 0; fi
          echo "gc session new: boom" >&2; return 1 ;;
      esac ;;
    "session wake"|"session pin") return 0 ;;
    "session peek") echo "peek"; return 0 ;;
  esac
  return 0
}

BD_ASSIGN_FILE="$TMP/assign"; : > "$BD_ASSIGN_FILE"; COMMENTS_FILE="$TMP/comments.json"; echo '[]' > "$COMMENTS_FILE"
bd() {
  local _t _prev="" _bead="" _assignee="" _upd=0 _show=0 _cm=0
  for _t in "$@"; do
    [ "$_prev" = "update" ] && _bead="$_t"; [ "$_prev" = "show" ] && _bead="$_t"; [ "$_prev" = "--assignee" ] && _assignee="$_t"
    [ "$_t" = "update" ] && _upd=1; [ "$_t" = "show" ] && _show=1; [ "$_t" = "comments" ] && _cm=1
    _prev="$_t"
  done
  if [ "$_cm" = "1" ]; then cat "$COMMENTS_FILE"; return 0; fi
  if [ "$_upd" = "1" ] && [ -n "$_bead" ] && [ -n "$_assignee" ]; then echo "$_bead $_assignee" >> "$BD_ASSIGN_FILE"; return 0; fi
  if [ "$_show" = "1" ] && [ -n "$_bead" ]; then echo "{\"assignee\":\"$(awk -v b="$_bead" '$1==b{v=$2} END{print v}' "$BD_ASSIGN_FILE")\"}"; return 0; fi
  return 0
}
NUDGED="$TMP/nudged"; mkdir -p "$NUDGED"
gate_nudge() { printf '%s' "${2:-}" > "$NUDGED/$1"; return 0; }   # the message handed to the queue, per session id

BRANCH="fix/ga-demo"; BRANCH_SHA="0123456789abcdef0123456789abcdef01234567"; REQUIRED_REVIEWERS=1
make_task() { printf 'QUALITY GATE REVIEW — You are reviewer %s of 1 for branch: %s\nlens: CORRECTNESS\n' "$1" "$BRANCH"; head -c 3000 /dev/zero | tr '\0' 'd'; printf '\nbd -C "x" close "%s"\n' "$2"; }
TASK="$(make_task 1 vb0)"
write_comments() { jq -n --arg t "$1" '[{"id":"c1","issue_id":"vb","author":"gate","text":$t,"created_at":"2026-10-10T00:00:00Z"}]' > "$COMMENTS_FILE"; }

echo "  · 4a. the node slot is never sent a pointer"
REVIEWER_POINTER_OK=(1 1 1); REVIEWER_NUDGE_SENT=(0 0 0); REVIEWER_TEMPLATE=("gate-reviewer-remote" "gate-reviewer")
rm -f "$NUDGED"/*
gate_deliver_review_task 0 sidR "$TASK" 1 vb0 send; rcR=$?
gate_deliver_review_task 1 sidL "$TASK" 1 vb1 send; rcL=$?
gate_deliver_review_task 2 sidU "$TASK" 1 vb2 send; rcU=$?
eq "remote slot: delivered (rc 0)" "$rcR" "0"
cmp -s "$NUDGED/sidR" <(printf '%s' "$TASK") && ok "remote slot with POINTER_OK=1: the nudge is the FULL task, byte for byte" || bad "remote slot got something other than the full task: $(head -c 80 "$NUDGED/sidR")"
case "$(cat "$NUDGED/sidL")" in "QUALITY GATE REVIEW — POINTER"*) ok "local slot with POINTER_OK=1: still a pointer (nothing changed for it)" ;; *) bad "local slot lost its pointer: $(head -c 80 "$NUDGED/sidL")" ;; esac
case "$(cat "$NUDGED/sidU")" in "QUALITY GATE REVIEW — POINTER"*) ok "a slot nobody filled (template empty) keeps the old pointer behaviour" ;; *) bad "unfilled slot changed behaviour: $(head -c 80 "$NUDGED/sidU")" ;; esac
rm -f "$NUDGED"/*; REVIEWER_POINTER_OK=(1); REVIEWER_NUDGE_SENT=(0); REVIEWER_TEMPLATE=("gate-reviewer-remote")
gate_deliver_review_task 0 sidR "$TASK" 1 vb0 retry
cmp -s "$NUDGED/sidR" <(printf '%s' "$TASK") && ok "…and the ACK-retry path to a node slot sends the full task too" || bad "retry to a node slot sent a pointer"

echo "  · 4b. Step 7 spawn: the real block, extracted"
SPAWNBLK="$(sed -n '/# SELFTEST-EXTRACT reviewer-spawn-node-first: BEGIN/,/# SELFTEST-EXTRACT reviewer-spawn-node-first: END/p' "$DISPATCHER")"
[ -n "$SPAWNBLK" ] && ok "located the node-first spawn block" || bad "node-first spawn block not found"
# run_spawn <city> [flag-on] — runs the block as slot i=1 under -e/-u (as the dispatcher does) and prints "sid|template|calls|log"
run_spawn() {
  local city="$1"; : > "$SPAWNLOG"; : > "$LOGF"; REVIEWER_TEMPLATE=(); SESSION_ID=""; SESSION_JSON=""
  ( set -eu
    GC_CITY="$city"; GATE_REMOTE_LIB_OK="${LIBOK:-1}"; i=1
    eval "$SPAWNBLK"
    printf '%s|%s' "$SESSION_ID" "${REVIEWER_TEMPLATE[0]:-}" ) > "$TMP/spawn.out" 2>"$TMP/spawn.err"
  local rc=$?
  printf '%s|calls=%s|rc=%s' "$(cat "$TMP/spawn.out")" "$(tr '\n' ',' < "$SPAWNLOG")" "$rc"
}
SC="$TMP/sc"; mkcity "$SC"; MOCK_NODE=ok; MOCK_LOCAL=ok; LIBOK=1
export FAKE_SSH_MODE=room
R="$(run_spawn "$SC")";           eq "flag off: ONE spawn, local, template slot untouched" "$R" "ga-LOCAL||calls=gate-reviewer,|rc=0"
flag_on "$SC"
R="$(run_spawn "$SC")";           eq "flag on + room + node spawns: ONE spawn, on the node, slot remembers it" "$R" "ga-NODE|gate-reviewer-remote|calls=gate-reviewer-remote,|rc=0"
has "…and the log names the choice" "$(cat "$LOGF")" "remote reviewer first"
MOCK_NODE=fail
R="$(run_spawn "$SC")";           eq "node spawn FAILS: falls back to local in the same step, slot stays local" "$R" "ga-LOCAL||calls=gate-reviewer-remote,gate-reviewer,|rc=0"
has "…and says so (warn)" "$(grep '^WARN' "$LOGF")" "falling back to the local reviewer"
MOCK_NODE=empty
R="$(run_spawn "$SC")";           eq "node spawn returns nothing: falls back to local" "$R" "ga-LOCAL||calls=gate-reviewer-remote,gate-reviewer,|rc=0"
MOCK_NODE=timeout
R="$(run_spawn "$SC")";           eq "node spawn TIMES OUT (outcome unknown): falls back to local (a stray node session idles out; never two reviewers for the slot)" "$R" "ga-LOCAL||calls=gate-reviewer-remote,gate-reviewer,|rc=0"
MOCK_NODE=ok; MOCK_LOCAL=fail
R="$(run_spawn "$SC")";           eq "node spawn works, local would not: the slot is the node's" "$R" "ga-NODE|gate-reviewer-remote|calls=gate-reviewer-remote,|rc=0"
MOCK_NODE=fail
R="$(run_spawn "$SC")";           eq "both fail: no session (the dispatcher's own abort path takes over), rc 0 from the block" "$R" "||calls=gate-reviewer-remote,gate-reviewer,|rc=0"
MOCK_NODE=ok; MOCK_LOCAL=ok
FAKE_SSH_MODE=full4 R="$(FAKE_SSH_MODE=full4 run_spawn "$SC")"; eq "node full: straight to local, the node spawn is never attempted" "$R" "ga-LOCAL||calls=gate-reviewer,|rc=0"
has "…and the log says why (full)" "$(cat "$LOGF")" "full"
R="$(FAKE_SSH_MODE=down run_spawn "$SC")"; eq "node unreachable: straight to local" "$R" "ga-LOCAL||calls=gate-reviewer,|rc=0"
LIBOK=0
R="$(run_spawn "$SC")";           eq "lib NOT loaded (flag on): local only, the old path" "$R" "ga-LOCAL||calls=gate-reviewer,|rc=0"
LIBOK=1
rm -f "$SC/.gc/gate-remote-reviewers.on"
R="$(run_spawn "$SC")";           eq "flag removed again: local only, the log stays silent about the node" "$R" "ga-LOCAL||calls=gate-reviewer,|rc=0"
eq "…(no remote-reviewer line in the log)" "$(grep -c 'remote reviewer\|Reviewer 1:' "$LOGF" | tr -d ' ')" "0"
unset FAKE_SSH_MODE

echo "  · 4c. re-convene (respawn_reviewer_slot, the real function)"
RC_="$TMP/rc"; mkcity "$RC_"; GC_CITY="$RC_"; export FAKE_SSH_MODE=room
run_respawn() { # $1=prev template of slot 0 ("" = local)  → "sid|template|calls|nudge-bytes"
  : > "$SPAWNLOG"; : > "$LOGF"; : > "$BD_ASSIGN_FILE"; rm -f "$NUDGED"/*; write_comments "$TASK"
  VERDICT_BEAD_IDS=(vb0); SESSION_IDS=(ga-old); REVIEW_TASKS=("$TASK"); REVIEWER_NUDGE_SENT=(1); REVIEWER_POINTER_OK=(1); REVIEWER_TASK_EMBEDDED=(1)
  REVIEWER_ACKED=(1); REVIEWER_PEEK_BASELINE=(x); REVIEWER_TEMPLATE=("$1")
  respawn_reviewer_slot 0 >/dev/null 2>&1; local rc=$?
  local sid="${SESSION_IDS[0]}" nb=0
  [ -f "$NUDGED/$sid" ] && nb="$(wc -c < "$NUDGED/$sid" | tr -d ' ')"
  printf '%s|%s|calls=%s|nudge=%s|rc=%s' "$sid" "${REVIEWER_TEMPLATE[0]:-}" "$(tr '\n' ',' < "$SPAWNLOG")" "$nb" "$rc"
}
TASKLEN="$(printf '%s' "$TASK" | wc -c | tr -d ' ')"
MOCK_NODE=ok; MOCK_LOCAL=ok; GATE_REMOTE_LIB_OK=1
R="$(run_respawn "")";            has "flag off: the replacement is local" "$R" "ga-LOCAL|gate-reviewer|calls=gate-reviewer,"
case "$R" in *"nudge=$TASKLEN|"*) bad "flag off: the local replacement got the FULL task instead of the pointer" ;; *) ok "…and it keeps the pointer (task proven on the bead)" ;; esac
flag_on "$RC_"
R="$(run_respawn "")";            has "flag on + room, slot was local: the replacement goes to the node" "$R" "ga-NODE|gate-reviewer-remote|calls=gate-reviewer-remote,"
has "…and gets the FULL task (no pointer to a bead the node cannot read)" "$R" "nudge=$TASKLEN|"
R="$(run_respawn "gate-reviewer-remote")"; has "slot was on the node and died: the replacement is LOCAL even with room on the node" "$R" "ga-LOCAL|gate-reviewer|calls=gate-reviewer,|"
has "…and says why" "$(cat "$LOGF")" "ran on the node and died"
MOCK_NODE=fail
R="$(run_respawn "")";            has "node spawn fails on re-convene: falls back to local" "$R" "ga-LOCAL|gate-reviewer|calls=gate-reviewer-remote,gate-reviewer,"
MOCK_NODE=ok; MOCK_LOCAL=fail; GATE_REMOTE_LIB_OK=1
R="$(run_respawn "gate-reviewer-remote")"; has "local spawn fails too: rc 1, slot unchanged (old id kept)" "$R" "ga-old|gate-reviewer-remote|calls=gate-reviewer,|nudge=0|rc=1"
MOCK_LOCAL=ok; GATE_REMOTE_LIB_OK=0
R="$(run_respawn "")";            has "lib not loaded: local replacement" "$R" "ga-LOCAL|gate-reviewer|calls=gate-reviewer,"
GATE_REMOTE_LIB_OK=1; unset FAKE_SSH_MODE

echo "  · 4d. static guards on the dispatcher text"
CODE_SPAWNS="$(grep -n 'session new[[:space:]]\+gate-reviewer[[:space:]]*\\' "$DISPATCHER" | wc -l | tr -d ' ')"
eq "exactly three LOCAL 'session new gate-reviewer' call sites remain (respawn, first spawn, retry loop)" "$CODE_SPAWNS" "3"
NODE_SPAWNS="$(grep -n 'session new "\$GATE_REMOTE_TEMPLATE"' "$DISPATCHER" | wc -l | tr -d ' ')"
eq "exactly two node spawn sites (Step 7 and re-convene), both through gate_bounded_spawn" "$NODE_SPAWNS" "2"
eq "…both capture stderr to a file, none mutes it" "$(grep -A4 'session new "\$GATE_REMOTE_TEMPLATE"' "$DISPATCHER" | grep -c '2>"\$_')" "2"
eq "…and no node spawn line is muted with 2>/dev/null" "$(grep -A4 'session new "\$GATE_REMOTE_TEMPLATE"' "$DISPATCHER" | grep -c '2>/dev/null')" "0"
eq "the review task is rendered ONCE per slot, before the template is chosen (one text for both templates)" "$(grep -c 'REVIEW_TASK=\$(gate_render_review_task' "$DISPATCHER" | tr -d ' ')" "1"
RENDER_LN="$(grep -n 'REVIEW_TASK=\$(gate_render_review_task' "$DISPATCHER" | head -1 | cut -d: -f1)"
PICK_LN="$(grep -n 'gate_remote_pick_template || true' "$DISPATCHER" | tail -n 1 | cut -d: -f1)"
[ -n "$RENDER_LN" ] && [ -n "$PICK_LN" ] && [ "$RENDER_LN" -lt "$PICK_LN" ] && ok "…the render line ($RENDER_LN) comes before the Step 7 pick ($PICK_LN): the pick cannot change the text" || bad "render/pick order is not what the byte-identity rests on"
eq "the E5 extra reviewer lib is untouched by the node (always local)" "$(grep -c 'GATE_REMOTE\|gate_remote' "$SELF_DIR/gate-e5-second-reviewer.lib.sh" | tr -d ' ')" "0"
if [ -f "$SELF_DIR/refino-gate-dispatcher.sh" ]; then eq "the refino dispatcher is untouched by the node (always local)" "$(grep -c 'GATE_REMOTE\|gate_remote' "$SELF_DIR/refino-gate-dispatcher.sh" | tr -d ' ')" "0"; fi
hasF "$DISPATCHER" 'the flag file exists but gate-remote-reviewers.lib.sh is NOT loaded' "flag on + lib missing is announced in the log (E5 precedent), not silent"

echo "── 5. the template: agent.toml, prompt, names ──"
get() { sed -n "s/^$1 *= *\"\{0,1\}\([^\"]*\)\"\{0,1\} *\$/\1/p" "$REMOTE_TOML" | head -n1; }
eq "max_active_sessions = 2 (not 1: crew-session-dedup would read 1 as a singleton and kill the second session)" "$(get max_active_sessions)" "2"
eq "min_active_sessions = 0 (no standing session: the slot is released when the review is done)" "$(get min_active_sessions)" "0"
eq "provider = claude-headless" "$(get provider)" "claude-headless"
eq "wake_mode = fresh" "$(get wake_mode)" "fresh"
eq "idle_timeout = 10m (returns the node slot)" "$(get idle_timeout)" "10m"
CITY_TOML="$CITY_SRC/city.toml"
RM="$(sed -n 's/^remote_match *= *"\([^"]*\)".*/\1/p' "$CITY_TOML" | head -n1)"
RM_SRC="city.toml"
if [ -z "$RM" ]; then RM="$(sed -n 's/^remote_match *= *"\([^"]*\)".*/\1/p' "$CITY_SRC/docs/runbooks/gc-session-ssh.md" | head -n1)"; RM_SRC="gc-session-ssh.md (the hybrid [session] block is not committed to city.toml yet)"; fi
[ -n "$RM" ] && ok "remote_match is readable (=$RM, from $RM_SRC)" || bad "remote_match not found in city.toml nor in gc-session-ssh.md: the name rule below cannot be checked"
case "gate-reviewer-remote-adhoc-0123456789" in *"$RM"*) [ -n "$RM" ] && ok "the engine's session name for this template carries remote_match, so the hybrid provider sends it to the node" ;; *) bad "the session name would NOT be routed to the node" ;; esac
RX="$(sed -n 's/^IDENTITY_PATTERN=//p' "$CITY_SRC/docs/runbooks/gc-session-ssh.md" | head -n1)"
python3 -I - "$RX" <<'PY' && ok "the shim's canonical identity_pattern accepts gate-reviewer-remote-adhoc-<10> and refuses the local reviewer's name" || bad "identity_pattern does not fit the node reviewer's name"
import re, sys
rx = re.compile(sys.argv[1])
sys.exit(0 if rx.fullmatch("gate-reviewer-remote-adhoc-0123456789") and not rx.fullmatch("gate-reviewer-adhoc-0123456789") else 1)
PY
blk() { awk '/^## Mandatory dimension: THE THIRD STATE/{p=1;print;next} /^## /{p=0} p' "$1" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
LB="$(blk "$LOCAL_PROMPT" | shasum | cut -d' ' -f1)"; RB="$(blk "$REMOTE_PROMPT" | shasum | cut -d' ' -f1)"
[ -n "$(blk "$LOCAL_PROMPT")" ] && ok "the local prompt still has the THIRD STATE block (the reference)" || bad "cannot find the THIRD STATE block in the local prompt"
eq "the remote prompt's THIRD STATE block is the local one, byte for byte (edit both or neither)" "$RB" "$LB"
PT="$(cat "$REMOTE_PROMPT")"
has "the remote prompt tells the reviewer to deliver by bd comment" "$PT" "bd -C"
has "…and to close the verdict bead" "$PT" "close"
has "…and knows label commands come back rc 77" "$PT" "rc 77"
case "$PT" in *"drain-ack && exit"*) bad "the remote prompt still tells the reviewer to run drain-ack && exit (the shim refuses it)" ;; *) ok "no 'drain-ack && exit' instruction (the shim refuses it)" ;; esac
case "$PT" in *"sleep 15"*) bad "the remote prompt has the local sleep-15 poll loop" ;; *) ok "no sleep-15 poll loop (the nudge wakes the session)" ;; esac
case "$PT" in *"--metadata-field gc.session_name"*) ok "(metadata fallback is mentioned only as refused)" ;; *) : ;; esac
case "$PT" in *"{{"*) bad "the remote prompt has template actions; the node has no use for them" ;; *) ok "no template actions in the remote prompt" ;; esac
eq "the pool-prompt skill-mention scan lists the remote template" "$(grep -c 'gate-reviewer-remote' "$SELF_DIR/pool-prompt-skill-mention.selftest.sh" | tr -d ' ')" "1"

echo "── 5b. the node shim lets the verdict through (the REAL task text, run through the shim's own decide()) ──"
# The node reviewer reaches the mini only through scripts/remote-shim-wrapper.py. Its allowlist is the reason the prompt tells the reviewer to
# deliver by `bd comment` + `bd close` and to expect rc 77 on `label`. This feeds the commands the dispatcher really renders into decide(), with the
# identity a node reviewer really has, so the prompt cannot drift away from what the shim does. Policy only: nothing is executed anywhere.
SHIMCITY="$TMP/shimcity"; mkdir -p "$SHIMCITY/.beads"; printf '{"prefix":"ga-","path":"."}\n' > "$SHIMCITY/.beads/routes.jsonl"
SHIMTASK="$(bash -c 'source "$1"; gate_render_review_task 1 1 fix/ga-demo someone gascity 0123456789abcdef0123456789abcdef01234567 CORRECTNESS a.sh "1 file" hdr diff "$2" ga-vb-demo bead' _ "$SELF_DIR/gate-review-task.lib.sh" "$SHIMCITY" 2>/dev/null)"
if [ -z "$SHIMTASK" ]; then bad "could not render the review task text"; else
  printf '%s' "$SHIMTASK" > "$TMP/shim-task.txt"
  python3 -I - "$CITY_SRC/scripts/remote-shim-wrapper.py" "$CITY_SRC/docs/runbooks/gc-session-ssh.md" "$SHIMCITY" "$TMP/shim-task.txt" "$TMP" <<'PY' > "$TMP/shim-check.out" 2>&1
import importlib.util, json, os, re, shlex, sys
wrapper, runbook, city, taskf, tmp = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("rsw", wrapper); rsw = importlib.util.module_from_spec(spec); spec.loader.exec_module(rsw)
rx = re.search(r"^IDENTITY_PATTERN=(.*)$", open(runbook, encoding="utf-8").read(), re.M).group(1)
cfgp = os.path.join(tmp, "shim-config.json")
json.dump({"city": city, "identity_pattern": rx, "log": os.path.join(tmp, "shim.log"), "bin_dirs": ["/usr/bin"]}, open(cfgp, "w"))
cfg = rsw.load_config(cfgp)
SESSION = "gate-reviewer-remote-adhoc-0123456789"
ENV = {"GC_ALIAS": SESSION, "GC_AGENT": "gate-reviewer-remote", "GC_SESSION_NAME": SESSION, "GC_TEMPLATE": "gate-reviewer-remote"}

def verdict(argv, env=ENV):
    try:
        rsw.decide(cfg, "bd" if argv[0] == "bd" else argv[0], argv[1:], dict(env)); return "accepted"
    except rsw.Refused as e:
        return f"refused rc={e.rc}"
def say(ok, what): print(("OK  " if ok else "BAD ") + what)

task = open(taskf, encoding="utf-8").read()
sec = task.split("record your verdict with EXACTLY these bash commands:", 1)[1].split("Run those commands and then exit", 1)[0]
lines, out, fail = sec.splitlines(), [], False
for ln in lines:
    if ln.startswith("# If FAIL"): fail = True; continue
    if ln.startswith("# If PASS"): continue
    out.append(ln[2:] if fail and ln.startswith("# ") else ln)
toks = shlex.split("\n".join(out))
cmds, cur = [], []
for t in toks:
    if t == "bd" and cur: cmds.append(cur); cur = []
    cur.append(t)
if cur: cmds.append(cur)
say(len(cmds) == 7, f"found 7 verdict commands in the task text (2 labels + comment + close for PASS, label + comment + close for FAIL; got {len(cmds)})")
for c in cmds:
    kind = c[3] if c[1] == "-C" else c[1]
    sub = c[4] if kind == "label" else ""
    r = verdict(c)
    if kind == "label":   say(r == "refused rc=77", f"label {sub} {c[-1]} -> {r} (the prompt says: rc 77 is expected, do not retry)")
    elif kind == "comment": say(r == "accepted", f"comment {c[5][:14]!r}… ({len(c[5])} chars, {c[5].count(chr(10))+1} lines) -> {r}")
    elif kind == "close": say(r == "accepted", f"close -> {r}")
    else: say(False, f"unexpected command in the verdict section: {c[:4]}")
for argv, want, what in [
    (["bd", "list", "--assignee", SESSION, "--label", "type:quality-gate-verdict", "--json", "--limit", "5"], "accepted", "the prompt's first-turn lookup"),
    (["bd", "show", "ga-vb-demo", "--json"], "accepted", "bd show <id> --json (metadata fallback)"),
    (["bd", "show", "ga-vb-demo", "--include-comments"], "refused rc=77", "bd show --include-comments (why the task is never a pointer on the node)"),
    (["bd", "comments", "ga-vb-demo"], "refused rc=77", "bd comments (same)"),
    (["gc", "runtime", "drain-ack"], "refused rc=77", "gc runtime drain-ack (why the remote prompt has no drain-ack)"),
    (["bd", "update", "ga-vb-demo", "--status", "closed"], "refused rc=77", "a status edit is not in the list"),
]:
    r = verdict(argv); say(r == want, f"{what}: {r}")
for k, v in [("GC_SESSION_NAME", "gate-reviewer-adhoc-0123456789"), ("GC_TEMPLATE", "gate-reviewer"), ("GC_ALIAS", "gastown.dog-4")]:
    r = verdict(["bd", "close", "ga-vb-demo"], {**ENV, k: v}); say(r == "refused rc=77", f"identity with {k}={v} (a LOCAL name) -> {r}")
r = verdict(["bd", "close", "ga-vb-demo"]); say(r == "accepted", "…and the node reviewer's own identity can close")
PY
  while IFS= read -r _l; do
    case "$_l" in "OK  "*) ok "${_l#OK  }" ;; "BAD "*) bad "${_l#BAD }" ;; *) bad "shim check output: $_l" ;; esac
  done < "$TMP/shim-check.out"
  [ -s "$TMP/shim-check.out" ] || bad "the shim check printed nothing"
fi

echo "── 6. mutants: each rule must fail when it is removed ──"
mutate_lib() { # $1=name $2=old $3=new → path of the mutated lib, or empty when 'old' is not in the lib (a mutation that mutated nothing proves nothing)
  python3 -I - "$LIB" "$TMP/mut-$1.lib.sh" "$2" "$3" <<'PY' || return 1
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if old not in s: sys.exit(f"mutation target not found: {old!r}")
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  printf '%s' "$TMP/mut-$1.lib.sh"
}
killed() { # $1=label $2=lib-path-or-empty $3=scenario-result-under-mutant $4=value that means 'survived'
  if [ -z "$2" ]; then bad "mutant '$1': the mutation did not apply"; return; fi
  if [ "$3" = "$4" ]; then bad "mutant '$1' SURVIVED (the suite does not notice the rule is gone)"; else ok "mutant '$1' killed"; fi
}
MC="$TMP/mc"
m_scen() { # <fake-mode> [city-edit]  → template picked by the given lib (global MLIB)
  mkcity "$MC"; flag_on "$MC"; [ -n "${2:-}" ] && cfg_edit "$MC" "$2"; tpl "$(pick "$MLIB" "$MC" FAKE_SSH_MODE="$1")"
}
MLIB="$(mutate_lib probe-rc 'if [ "$rc" -ne 0 ]; then' 'if false; then')";            killed "an unreachable node counts as room" "$MLIB" "$(m_scen down)" "gate-reviewer"
MLIB="$(mutate_lib full 'if [ "$total" -ge "$cap" ]; then' 'if false; then')";         killed "the host cap is ignored" "$MLIB" "$(m_scen full4)" "gate-reviewer"
MLIB="$(mutate_lib tcap 'if [ "$rem" -ge "$tcap" ]; then' 'if false; then')";          killed "the template cap is ignored" "$MLIB" "$(m_scen rev2)" "gate-reviewer"
MLIB="$(mutate_lib capread "*) printf 'unknown:host config unreadable or ambiguous (cap not read)'; return 0 ;;" '*) facts="cap=999 rig=1 rel=1" ;;')"
killed "an unreadable host cap is assumed to be huge" "$MLIB" "$(m_scen room "d.__setitem__('hosts',{})")" "gate-reviewer"
MLIB="$(mutate_lib garbage '*[!A-Za-z0-9_.-]*) printf '"'"'unknown:node probe returned a line that is not a session name'"'"'; return 0 ;;' '*[!A-Za-z0-9_.-]*) : ;;')"
killed "banner text on stdout is counted as a session" "$MLIB" "$(m_scen garbage)" "gate-reviewer"
MLIB="$(mutate_lib unready 'if [ "$rig" != "1" ]; then' 'if false; then')";             killed "a host with no worktree_rigs entry is tried anyway" "$MLIB" "$(m_scen room "h['worktree_rigs'].pop('gate-reviewer')")" "gate-reviewer"
MLIB="$(mutate_lib flagunread '    *) GATE_REMOTE_PICK_KIND="fallback"; GATE_REMOTE_PICK_WHY="remote-reviewer flag UNREADABLE - local reviewer"; return 0 ;;' '    *) : ;;')"
if [ -n "$MLIB" ]; then
  mkcity "$MC"; rm -f "$MC/.gc/gate-remote-reviewers.on"; ln -s "$TMP/nowhere" "$MC/.gc/gate-remote-reviewers.on"
  killed "an unreadable flag is read as 'on'" "$MLIB" "$(tpl "$(pick "$MLIB" "$MC")")" "gate-reviewer"
else killed "an unreadable flag is read as 'on'" "" "" ""; fi
MLIB="$(mutate_lib notimeout 'raw="$("$tbin" -k 5 "$secs" "$ssh_bin" list-running 2>/dev/null)"' 'raw="$("$ssh_bin" list-running 2>/dev/null)"')"
if [ -n "$MLIB" ]; then
  mkcity "$MC"; flag_on "$MC"; T0=$(date +%s); R="$(pick "$MLIB" "$MC" FAKE_SSH_MODE=hang GATE_REMOTE_PROBE_SECS=1)"; T1=$(date +%s)
  # with the bound removed a hanging probe holds the dispatcher for the whole 8 s the fake wants
  if [ $((T1 - T0)) -ge 6 ]; then ok "mutant 'the probe runs without a bound' killed (it held for $((T1 - T0))s)"; else bad "mutant 'the probe runs without a bound' SURVIVED ($((T1 - T0))s)"; fi
else bad "mutant 'the probe runs without a bound': the mutation did not apply"; fi

# dispatcher mutants: the same scenarios, run against a mutated copy of the dispatcher (sourced in lib-only mode in a subshell)
mutate_disp() { # $1=name $2=old $3=new → path or empty
  python3 -I - "$DISPATCHER" "$TMP/mutd-$1.sh" "$2" "$3" <<'PY' || return 1
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if s.count(old) != 1: sys.exit(f"mutation target found {s.count(old)} times: {old[:80]!r}")
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  printf '%s' "$TMP/mutd-$1.sh"
}
scen_pointer() { # $1=dispatcher path → "remote:<full|pointer> local:<full|pointer>"
  ( GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo "load-failed"; exit 0; }
    log() { :; }; warn() { :; }; err() { :; }
    gate_nudge() { printf '%s' "${2:-}" > "$TMP/mp.$1"; return 0; }
    BRANCH="fix/ga-demo"; BRANCH_SHA="0123456789abcdef0123456789abcdef01234567"; REQUIRED_REVIEWERS=1
    REVIEWER_POINTER_OK=(1 1); REVIEWER_NUDGE_SENT=(0 0); REVIEWER_TEMPLATE=("gate-reviewer-remote" "")
    gate_deliver_review_task 0 r "$TASK" 1 vb0 send; gate_deliver_review_task 1 l "$TASK" 1 vb1 send
    r=pointer; cmp -s "$TMP/mp.r" <(printf '%s' "$TASK") && r=full
    l=pointer; cmp -s "$TMP/mp.l" <(printf '%s' "$TASK") && l=full
    echo "remote:$r local:$l" )
}
eq "(control) the real dispatcher: remote gets the full task, local keeps the pointer" "$(scen_pointer "$DISPATCHER")" "remote:full local:pointer"
MD="$(mutate_disp pointer '    _ptr=0
  fi
  # vazio → n/a' '    _ptr=1
  fi
  # vazio → n/a')"
killed "a node slot is sent a pointer it cannot follow" "$MD" "$(scen_pointer "${MD:-/dev/null}")" "remote:full local:pointer"

scen_spawn() { # $1=dispatcher path; node fails, local ok → "sid|calls"
  local blk; blk="$(sed -n '/# SELFTEST-EXTRACT reviewer-spawn-node-first: BEGIN/,/# SELFTEST-EXTRACT reviewer-spawn-node-first: END/p' "$1")"
  [ -n "$blk" ] || { echo "no-block"; return; }
  : > "$SPAWNLOG"; MOCK_NODE=fail; MOCK_LOCAL=ok; mkcity "$MC"; flag_on "$MC"
  ( set -eu; GC_CITY="$MC"; GATE_REMOTE_LIB_OK=1; i=1; SESSION_ID=""; REVIEWER_TEMPLATE=(); export FAKE_SSH_MODE=room
    eval "$blk"; printf '%s' "$SESSION_ID" ) 2>/dev/null
}
eq "(control) node spawn fails → the slot still ends up with the local session" "$(scen_spawn "$DISPATCHER")" "ga-LOCAL"
MD="$(mutate_disp nofallback '  if [ -z "$SESSION_ID" ]; then
    _spawn_err_file="/tmp/gate-reviewer-spawn-err-$$.${i}"' '  if false; then
    _spawn_err_file="/tmp/gate-reviewer-spawn-err-$$.${i}"')"
killed "a failed node spawn leaves the slot without a reviewer (no local fallback)" "$MD" "$(scen_spawn "${MD:-/dev/null}")" "ga-LOCAL"
scen_slot() { # $1=dispatcher path; node ok -> which template does the slot remember? (a node slot must, or it is sent a pointer it cannot follow)
  local blk; blk="$(sed -n '/# SELFTEST-EXTRACT reviewer-spawn-node-first: BEGIN/,/# SELFTEST-EXTRACT reviewer-spawn-node-first: END/p' "$1")"
  [ -n "$blk" ] || { echo "no-block"; return; }
  : > "$SPAWNLOG"; MOCK_NODE=ok; MOCK_LOCAL=ok; mkcity "$MC"; flag_on "$MC"
  ( set -eu; GC_CITY="$MC"; GATE_REMOTE_LIB_OK=1; i=1; SESSION_ID=""; REVIEWER_TEMPLATE=(); export FAKE_SSH_MODE=room
    eval "$blk"; printf '%s' "${REVIEWER_TEMPLATE[0]:-}" ) 2>/dev/null
}
eq "(control) node spawn works → the slot remembers it is on the node" "$(scen_slot "$DISPATCHER")" "gate-reviewer-remote"
MD="$(mutate_disp noslot '        REVIEWER_TEMPLATE[$((i - 1))]="$GATE_REMOTE_TEMPLATE"' '        : # slot template not recorded')"
killed "the slot forgets it runs on the node (and gets a pointer)" "$MD" "$(scen_slot "${MD:-/dev/null}")" "gate-reviewer-remote"

echo
echo "gate-remote-reviewers selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
