#!/bin/bash
# hetzner-node-reseed-order.sh (ga-zri39b) — what the `hetzner-node-reseed` order runs once a day (05:55 local).
#
# WHY: the Linux test node keeps its own copy of the WA tree (~/gt-remote/wa-base) and its own Python venv (venv-wa). Every battery rsyncs the caller's worktree over the
# slot mirror, so code never goes stale — but the venv does: a dependency added on the mini is missing on the node until someone reinstalls it, and until then tests that
# import it fail there (the gate re-runs them locally, correct but slow). `mbp-run.sh --host linux --seed wa` is the whole job: rsync the base through the security filter
# (--delete-excluded, so anything the filter excludes is also REMOVED from the node), audit the destination for secrets/data, and reinstall the filtered freeze when its hash
# changed. This wrapper only decides whether to run it and what to say when it fails.
#
# NOT MERGED WITH mbp-nightly-reseed.sh on purpose: that one is built around the MacBook's switch, pause and presence (PULADO when the Athos paused the MBP); the node has
# its own flag and is a dedicated machine, so it must keep refreshing while the MBP is off or paused.
#
# VERDICT (stdout, last line; one jsonl line per run in $CITY/.gc/logs/hetzner-node-reseed.jsonl):
#   OFF     the node flag ($CITY/.gc/hetzner-node.on) is absent: nothing to do, exit 0, silent. The trial ends by deleting the flag; this order then stops on its own.
#   OK      the seed returned 0.
#   FALHOU  the seed returned non-zero or timed out -> ONE notify (prio 4) naming the rc and its meaning; exit 1. A failed seed means the node base/venv may be stale,
#           and the chain still works (a stale node only costs a local re-run) — so this is a heads-up, not an emergency, EXCEPT:
#   ALARME  the seed's audit found a secret or data file on the node (the filter let something through): notify at prio 5 and exit 1. This is the security requirement of
#           the story (no customer data leaves the mini), so it is loud on purpose. The order does NOT turn the node off by itself (the flag stays on and batteries keep
#           cloning mirrors from the base the audit just flagged), so the notify tells the Mayor to run `mbp-offload.sh node off`.
# A missing mbp-run.sh is a FAILED run (FALHOU: exit 1, stderr line, jsonl line and ONE prio-4 notify like any other failed seed), never a quiet success.
#
# TEST: bash scripts/hetzner-node-reseed.selftest.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUN="${HETZNER_RESEED_RUN:-$CITY/scripts/mbp-run.sh}"
NOTIFY="${HETZNER_RESEED_NOTIFY:-$HOME/.local/bin/notify}"
FLAG="$CITY/.gc/hetzner-node.on"
LOG="$CITY/.gc/logs/hetzner-node-reseed.jsonl"
TIMEOUT_S="${HETZNER_RESEED_TIMEOUT_S:-900}"
TO=$(command -v timeout || command -v gtimeout || true)
T0=$(date +%s)

say() { printf '%s hetzner-node-reseed: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*"; }
record() { # verdict rc [detail]
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg v "$1" --argjson rc "$2" --arg d "${3:-}" --argjson secs "$(( $(date +%s) - T0 ))" \
    '{ts:$ts,verdict:$v,rc:$rc,detail:$d,secs:$secs}' >> "$LOG" 2>/dev/null || say "WARN: could not write $LOG"
}
note() { # prio message — a failed notify is said, never swallowed
  if [ -x "$NOTIFY" ]; then "$NOTIFY" -t "Hetzner node reseed" -p "$1" "$2" >/dev/null 2>&1 || say "WARN: notify failed"; else say "WARN: notify not found at $NOTIFY"; fi
}

if [ ! -f "$FLAG" ]; then say "node off (no $FLAG) — nothing to do"; record OFF 0; say "VERDICT: OFF"; exit 0; fi
if [ ! -f "$RUN" ]; then
  msg="mbp-run.sh not found at $RUN — nothing was seeded"
  echo "hetzner-node-reseed: $msg" >&2; record FALHOU 1 "$msg"; note 4 "Hetzner node reseed FAILED: $msg. The node base/venv is not being refreshed; gate and workers fall back to the MacBook/local as usual."
  say "VERDICT: FALHOU"; exit 1
fi

# --host linux --seed wa works whether or not the MacBook switch is on: the node has its own flag
# vazio → sem timeout/gtimeout no PATH (o do launchd é curto): a run NÃO tem o teto de ${TIMEOUT_S}s e isso é DITO; só o timeout da própria order (1000 s) a limita. Não é erro: o seed roda do mesmo jeito
if [ -n "$TO" ]; then out=$(MBP_CITY="$CITY" "$TO" "$TIMEOUT_S" bash "$RUN" --host linux --seed wa 2>&1); rc=$?
else say "WARN: no timeout/gtimeout in PATH — this run is NOT bounded by ${TIMEOUT_S}s (only the order's own timeout applies)"; out=$(MBP_CITY="$CITY" bash "$RUN" --host linux --seed wa 2>&1); rc=$?; fi
last=$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-300)

if [ $rc -eq 0 ]; then say "seed ok: $last"; record OK 0 "$last"; say "VERDICT: OK"; exit 0; fi
case $rc in
  97) why="configuration (filter without the safe order, local venv unreadable, base tree missing)" ;;
  98) why="node unreachable/unhealthy, rsync failed, uv install failed, or the audit refused the seed" ;;
  124) why="timed out after ${TIMEOUT_S}s" ;;
  *) why="unexpected" ;;
esac
if printf '%s\n' "$out" | grep -q 'ALARME: dado ou segredo no destino'; then
  say "ALARME — a secret or data file is on the node: $last"; record ALARME "$rc" "$last"; note 5 "ALARME: secret/data file found on the Hetzner node after seeding (rc=$rc). The rsync filter let it through. TURN THE NODE OFF NOW: mbp-offload.sh node off (this order does not do it: the flag stays on and batteries keep cloning mirrors from the contaminated base). See $LOG. $last"
  say "VERDICT: ALARME"; exit 1
fi
say "FAILED (rc=$rc: $why): $last"; record FALHOU "$rc" "$last"; note 4 "Hetzner node reseed FAILED (rc=$rc: $why). The node may have a stale venv/base; gate and workers fall back to the MacBook/local as usual. $last"
say "VERDICT: FALHOU"; exit 1
