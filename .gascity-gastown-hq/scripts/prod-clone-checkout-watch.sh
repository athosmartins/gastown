#!/usr/bin/env bash
# prod-clone-checkout-watch.sh (ga-eei1o4) — post-checkout hook of the LIVE whatsapp_automation clone.
#
# ## Contents
#   Why · What it records · Three states · What it never does · Install · Limits
#
# WHY. /Users/athos/gt/whatsapp_automation is where every WA daemon runs FROM. On 24/10 04:07:22-04:07:41 -03 a gate
# reviewer ran `git checkout --detach <unmerged sha>` in it (cwd had drifted there), looked at a file, and checked the
# old HEAD out again 19 s later: for those 19 s a restart of any daemon would have loaded unreviewed code, and the round
# trip rewrote file mtimes, which the swallowed-daemon-deploy-guard then read as "file changed after the process started".
# The reflog shows eight more such round trips since 08/10 — nobody knows who ran them, because a reflog records no
# identity. wa-root-main-guard polls every 114 s and only reads the branch NAME; the clone sits on a detached HEAD, so
# "detached at origin/main" (healthy) and "detached on unreviewed code" (the incident) print the same WARN line, 10149 times.
#
# WHAT IT RECORDS. Git runs this after every checkout/switch in the clone (and, because core.hooksPath is shared, in
# every linked worktree of it — those are skipped by the first test below). One tab-separated line per checkout in the
# LIVE clone itself, appended to $PCCW_LOG (default .gc/logs/prod-clone-checkout.log): kind (branch = HEAD moved,
# files = `git checkout -- path`), state of the new HEAD, state of the one it left, the two short shas, and WHO — the
# GC_SESSION_NAME / GC_AGENT / GC_ALIAS / BEADS_ACTOR / USER of the shell that ran git (the hook inherits them) plus the
# command lines of up to 8 ancestor processes (git's own command line included).
#
# THREE STATES (not two) for a commit against origin/main, the same answer the incident needed:
#   on-main   reachable from origin/main — what the updater leaves, or a rollback to older reviewed code. Logged, silent.
#   off-main  NOT reachable from origin/main — unreviewed code is live. Logged + alarm.
#   unknown   cannot tell (origin/main or the sha does not resolve, merge-base failed). Logged + alarm: "I do not know"
#             is never filed under on-main.
# The alarm is a background `gc mail send mayor` (a session nudge hangs when the Mayor's tmux is attached, ga-eldeu), at
# one per $PCCW_ALARM_TTL_MIN minutes (the log line then says alarm=suppressed, so a burst is counted, not hidden).
#
# WHAT IT NEVER DOES. It never restores, switches, resets or kills anything (a guard that repairs cannot tell a lost
# deploy from a deliberate rollback), and it ALWAYS exits 0 — a post-checkout hook's exit status becomes the exit
# status of `git checkout`, so a bug here must not break anybody's checkout. A log it cannot write is said on stderr.
#
# INSTALL. Not by hand: scripts/prod-clone-checkout-watch-activate.sh [--check|--remove] symlinks this file (main
# checkout path, never a worktree) into the clone's hooks dir. Kill switch: PROD_CLONE_WATCH=off (logged as DISABLED).
#
# LIMITS. Detection after the fact, not prevention: git has no pre-checkout hook, and aborting from reference-transaction
# would leave the worktree switched but HEAD not. `git -c core.hooksPath=... checkout` (wa-root-main-guard does that
# on purpose) skips it. Config knobs for the selftest: PCCW_ROOT, PCCW_LOG, PCCW_ALARM_CMD (called as CMD subject body), PCCW_GIT.
set -u
# exit 0 by construction: even a shell aborted by `set -u` leaves git checkout with status 0 (a fatal signal is not covered)
trap 'exit 0' EXIT

ROOT="${PCCW_ROOT:-/Users/athos/gt/whatsapp_automation}"
LOG="${PCCW_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/prod-clone-checkout.log}"
ALARM_TTL_MIN="${PCCW_ALARM_TTL_MIN:-10}"
GIT="${PCCW_GIT:-git}"   # a seam for the selftest only (it makes merge-base fail on demand)

# One TSV line. A log that cannot be written is reported on stderr — never swallowed, never fatal.
emit() {
  mkdir -p "${LOG%/*}" 2>/dev/null
  { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; } 2>/dev/null \
    || echo "prod-clone-checkout-watch: cannot write $LOG ($*)" >&2
}

alarm() {
  if [ -n "${PCCW_ALARM_CMD:-}" ]; then "$PCCW_ALARM_CMD" "$1" "$2"; else gc mail send mayor -s "$1" -m "$2"; fi
}

# on-main / off-main / unknown for one commit, against origin/main.
classify() {
  _c="${1:-}"
  # vazio → unknown (sem sha); falhou/ilegível → unknown (nunca on-main)
  [ -n "$_c" ] || { echo unknown; return; }
  # vazio → unknown (origin/main não existe aqui); falhou/ilegível → unknown
  "$GIT" rev-parse --verify -q "origin/main^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  # vazio → unknown (sha que o git não conhece); falhou/ilegível → unknown
  "$GIT" rev-parse --verify -q "${_c}^{commit}" >/dev/null 2>&1 || { echo unknown; return; }
  "$GIT" merge-base --is-ancestor "$_c" origin/main >/dev/null 2>&1
  case $? in 0) echo on-main ;; 1) echo off-main ;; *) echo unknown ;; esac
}

main() {
  old="${1:-}"; flag="${3:-}"

  # vazio → toplevel desconhecido, não sei se é o clone vivo: linha UNKNOWN-TOPLEVEL, sem alarme; falhou/ilegível → idem
  top=$("$GIT" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -z "$top" ]; then emit "result=UNKNOWN-TOPLEVEL cwd=$(pwd -P 2>/dev/null)"; return 0; fi
  top_real=$(cd "$top" 2>/dev/null && pwd -P) || top_real=""
  # vazio → ROOT não existe nesta máquina: linha UNKNOWN-ROOT, sem alarme; falhou/ilegível → idem
  root_real=$(cd "$ROOT" 2>/dev/null && pwd -P) || root_real=""
  if [ -z "$top_real" ] || [ -z "$root_real" ]; then
    emit "result=UNKNOWN-ROOT top=$top root=$ROOT"; return 0
  fi
  # A linked worktree of the clone (crew/*, .gc-worktrees/*, reviewer scratch) has its own toplevel: not the live tree.
  [ "$top_real" = "$root_real" ] || return 0

  if [ "${PROD_CLONE_WATCH:-on}" = off ]; then emit "result=DISABLED top=$top_real"; return 0; fi

  # vazio → HEAD sem commit (clone vazio): state=unknown; falhou/ilegível → head vazio, state=unknown
  head=$("$GIT" rev-parse -q --verify HEAD 2>/dev/null) || head=""
  state=$(classify "$head")
  case "$old" in ""|0000000000*) prev=none ;; *) prev=$(classify "$old") ;; esac

  kind=unknown-flag
  [ "$flag" = 1 ] && kind=branch
  [ "$flag" = 0 ] && kind=files

  chain=""; p="$PPID"; n=0
  while [ "$n" -lt 8 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    # vazio → processo sumiu: corta a cadeia aqui; falhou/ilegível (ps negado) → idem, sem inventar pai
    l=$(ps -o ppid= -o command= -p "$p" 2>/dev/null) || break
    [ -n "$l" ] || break
    read -r pp cmd <<EOF
$l
EOF
    cmd=$(printf '%s' "$cmd" | tr '\t\n' '  ' | cut -c1-110)
    chain="${chain:+$chain <- }[$p] $cmd"
    p="$pp"; n=$((n + 1))
  done

  who="session=${GC_SESSION_NAME:-} agent=${GC_AGENT:-} alias=${GC_ALIAS:-} actor=${BEADS_ACTOR:-} user=${USER:-}"
  al=none
  if [ "$kind" != files ] && [ "$state" != on-main ]; then
    mark="$LOG.alarm"
    # vazio → sem marca anterior: alarma; falhou/ilegível → find não leu: alarma (na dúvida, avisa)
    if [ -n "$(find "$mark" -mmin -"$ALARM_TTL_MIN" 2>/dev/null)" ]; then
      al="suppressed(<${ALARM_TTL_MIN}min)"
    else
      al=requested
      touch "$mark" 2>/dev/null
      subj="[prod-clone] clone vivo do WA em ${head:0:9} (${state}) — checkout por ${GC_SESSION_NAME:-${USER:-?}}"
      body="O clone de produção $top_real foi movido para ${head:0:9}, estado=${state} (anterior ${old:0:9}, ${prev}). Quem: ${who}. Cadeia: ${chain}. Linha no log: ${LOG}. O hook só detecta; o clone deve voltar a um commit de origin/main (git -C $top_real checkout --detach ${old:0:9})."
      ( alarm "$subj" "$body" </dev/null >/dev/null 2>&1 \
          || emit "result=ALARM-FAILED state=$state new=${head:0:9}" ) </dev/null >/dev/null 2>&1 &
    fi
  fi

  emit "result=CHECKOUT	kind=$kind	state=$state	prev=$prev	old=${old:0:9}	new=${head:0:9}	alarm=$al	$who	chain=$chain"
  return 0
}

main "$@" || true
exit 0
