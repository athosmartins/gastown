#!/bin/bash
# claude-pool-account.live-accept.sh — ga-8hcnvb.1 + ga-8hcnvb.2 acceptance against the REAL Claude API, the REAL Keychain and a
# REAL interactive `claude` session. Adapted from docs/research/ga-2yyitx-account-switch-spike/e1_live.sh.
# NOT part of the hermetic selftest (claude-pool-account.selftest.sh): it spends a few haiku tokens on the OK account (the wrapper
# check and the live session's answers) and needs two vault keys. Run it by hand after a change to the wrapper, the daemon, or claude.
#
# SAFE BY CONSTRUCTION: every Keychain item is a throwaway named for a scratch dir ("Claude Code-credentials-<h>",
# refused unless it is neither the production login item nor the production pool item); production state, the
# production pool item and ~/.claude are never written. The daemon under test is pointed at a SCRATCH tmux server
# (CLAUDE_POOL_TMUX_SOCKET=$SOCK), so it can see and press nothing but the one session this script starts: the city's own tmux
# server (Mayor, crews, the pool) is never reached. Tokens never reach argv, ps, a log, a file or the screen: this script
# holds them only in shell variables (read from the vault, hashed with the `printf` builtin) and the daemon reads them from the
# vault itself and writes them to the scratch Keychain item.
#
# IDENTITY ORACLE: OK  = terrenos.incorporacoes@ (0% used, answers).
#                  EXH = athosb85@ (weekly limit hit until 2026-10-07 ~22:00Z; can only answer with the limit
#                        error, and a rejected call costs nothing). After 2026-10-07 22:00Z pick another exhausted
#                        account (EMAIL_EXH=...), or the steps that need a REALLY exhausted account cannot tell the accounts apart.
#
# Nothing here is mocked: the failover is triggered by what the real exhausted account really does to a real claude session.
#   P1  seed: the pool item is created from a key that is ACCEPTED (count_tokens, never billed), with no balance call; and with no
#       session on the limit screen the daemon does not move and asks the API nothing - even though the account IS exhausted
#       (the pool moves at 100% = when the limit is hit, not before, and not on a guess).
#   P2  the pool wrapper path: claude-lowprio.sh -> claude uses the pool item; with no item it falls back to the
#       ambient login (AC: a pool session without the credential starts normally). The wrapper logs POOL-ACCT SET.
#   P3  one LIVE interactive session, launched through the wrapper, one pid, no restart, nobody typing for it:
#       the pool is on EXH -> the session hits the real limit (the screen the daemon looks for) -> the daemon asks EXH once (a real 429,
#       free) and moves the item to OK -> 45 s later it sends the session ONE Escape -> the session answers on OK
#       -> (d) the stored reset time passes: failback by the TIMER, with no call about EXH -> the session hits the limit again
#       -> the failover is done again -> the conversation is still there.
#       The limit screen is the MODAL on a session's first hit and the inline ENVELOPE ("You've hit your ... limit") on every later
#       one (measured, claude 2.1.291): the first failover is read off the modal and unstuck by one Escape; the second, after the
#       failback, off the envelope, which blocks nothing - there P3.9 asserts that NO key is sent.
#       Zero-credit proof: the daemon's only API calls are the evidence probes (every one a 429) and key checks; `claude` is never run by it.
set -u
umask 077   # whatever this script writes under $HOME is for this user only (the scratch dir is 0700 already; the files in it too)
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="${DAEMON:-$SD/claude-pool-account.py}"
LOWPRIO="$SD/claude-lowprio.sh"
PY=/usr/bin/python3
EMAIL_OK="${EMAIL_OK:-terrenos.incorporacoes@gmail.com}"
EMAIL_EXH="${EMAIL_EXH:-athosb85@gmail.com}"

W="$(mktemp -d "$HOME/.gastown/pool-live.XXXXXX")" || exit 1     # under $HOME (no /var -> /private symlink in the hash)
POOL_DIR="$W/pool-cred"; mkdir -p "$POOL_DIR" "$W/city/.gc/logs" "$W/cfg" "$W/work"
SVC="Claude Code-credentials-$(printf '%s' "$POOL_DIR" | shasum -a 256 | cut -c1-8)"
PROD_POOL_SVC="Claude Code-credentials-$(printf '%s' "$HOME/.gastown/claude-pool-cred" | shasum -a 256 | cut -c1-8)"
case "$SVC" in "Claude Code-credentials-"????????) ;; *) echo "REFUSING: not a hashed test item name"; exit 1 ;; esac
[ "$SVC" != "Claude Code-credentials" ] && [ "$SVC" != "$PROD_POOL_SVC" ] || { echo "REFUSING: would touch a production item"; exit 1; }
SOCK=poollive$$
[ "$SOCK" != "gascity" ] || { echo "REFUSING: the scratch tmux socket would be the city's"; exit 1; }
LOG="$W/city/.gc/logs/claude-pool-account.log"
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1
  timeout 10 security delete-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT
USER="${USER:-$(id -un)}"

# the two real keys: only fingerprints are ever printed
TOK_OK="$(secret "claude-oauth-token-$EMAIL_OK")" || { echo "vault: no key for $EMAIL_OK"; exit 1; }
TOK_EXH="$(secret "claude-oauth-token-$EMAIL_EXH")" || { echo "vault: no key for $EMAIL_EXH"; exit 1; }
fp() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
echo "OK account fp=$(fp "$TOK_OK")   EXH account fp=$(fp "$TOK_EXH")   scratch item=$SVC   scratch tmux socket=$SOCK"

usage_fixture() { # usage_fixture <file> <first-email> <second-email> [reading-epoch]   (both with balance; first renews earlier)
  # Both rows carry a GOOD reading stamped last_ok_at = <reading-epoch> (default: now), as the real collector writes it: the daemon
  # fails back only on a reading taken AFTER the stored reset, so the failback step must say when its 'collection' happened.
  "$PY" - "$1" "$2" "$3" "${4:-$(date +%s)}" <<'EOF'
import json, sys
from datetime import datetime, timezone
f, a, b, at = sys.argv[1:5]
iso = datetime.fromtimestamp(float(at), timezone.utc).isoformat()
accts = [{"email": e, "ok": True, "stale": False, "collected_at": iso, "last_ok_at": iso,
          "weekly_all": {"percent": 10, "resets_at": "203%d-01-01T00:00:00+00:00" % i}, "session": {"percent": 5}}
         for i, e in enumerate([a, b])]
json.dump({"updated_at": iso, "accounts": accts}, open(f, "w"))
EOF
}
daemon() { # daemon [ENV=val...]   (state/item/tmux server are the scratch ones; the API is the real one)
  env HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin" GC_CITY_PATH="$W/city" \
      CLAUDE_USAGE_STORE="$W/usage.json" CLAUDE_POOL_STATE="$W/state.json" CLAUDE_POOL_CRED_DIR="$POOL_DIR" \
      CLAUDE_POOL_TMUX_SOCKET="$SOCK" "$@" "$PY" "$DAEMON" run-once
}
jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], ""))' "$W/state.json" "$1" 2>/dev/null; }
exh_reset() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("exhausted",{}).get(sys.argv[2],{}).get("reset_epoch",""))' "$W/state.json" "$1" 2>/dev/null; }
nlog() { local c; c="$(grep -c -- "$1" "$LOG" 2>/dev/null)"; echo "${c:-0}"; }
reseed() { # reseed <first-email> <second-email>: no item, no state - the next daemon run seeds from the first key that is accepted
  timeout 10 security delete-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1; rm -f "$W/state.json"
  usage_fixture "$W/usage.json" "$1" "$2"
}

# ── P1: the seed and the 100% rule, on the real API ────────────────────────────────────────────────
echo; echo "== P1  seed from a key that is ACCEPTED (no balance call); no session on the limit modal -> no move, no question to the API"
reseed "$EMAIL_EXH" "$EMAIL_OK"
daemon >/dev/null 2>&1; echo "   daemon exit=$?"
[ "$(jget current)" = "$EMAIL_EXH" ] && [ "$(jget fingerprint)" = "$(fp "$TOK_EXH")" ] \
  && ok "P1a seed: the first account of the order whose KEY is accepted is the pool's (EXH, whose limit is hit: its key is still valid)" \
  || bad "P1a current='$(jget current)' fingerprint='$(jget fingerprint)' (count_tokens refused the EXH key, or the order differs)"
security find-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1 && ok "P1b the pool item exists (created by the daemon)" || bad "P1b no pool item"
for i in 1 2 3; do daemon >/dev/null 2>&1; done
[ "$(jget current)" = "$EMAIL_EXH" ] && [ "$(nlog "API-CALL messages")" = "0" ] && [ "$(nlog "API-CALL count_tokens")" -ge 1 ] \
  && ok "P1c 3 more runs with the account really exhausted but nobody on the limit modal: still EXH, ZERO balance calls (only key checks, never billed)" \
  || bad "P1c current='$(jget current)' messages-calls=$(nlog "API-CALL messages") count_tokens-calls=$(nlog "API-CALL count_tokens")"

# ── P2: the wrapper path ───────────────────────────────────────────────────────────────────────────
echo; echo "== P2  wrapper -> claude (the path a real pool session takes)"
reseed "$EMAIL_OK" "$EMAIL_EXH"; daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P2.0 the pool item now holds the OK account" || bad "P2.0 current='$(jget current)'"
cd "$W/work" || exit 1
ASK=(-p "Reply with exactly the single word: WRAPOK" --model haiku --no-session-persistence --strict-mcp-config --settings '{"remoteControlAtStartup":false}')
out="$(env GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$POOL_DIR" GC_LOWPRIO=0 "$LOWPRIO" "${ASK[@]}" 2>&1 | tail -3)"
printf '%s' "$out" | grep -q "WRAPOK" && ok "P2a pool wrapper + pool item -> claude answers (credential came from the pool item)" || bad "P2a no answer via the pool item: $(printf '%s' "$out" | head -c 200)"
grep -q "POOL-ACCT SET" "$LOG" && ok "P2b the wrapper logged POOL-ACCT SET" || bad "P2b no POOL-ACCT SET in the log"
out="$(env GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$W/no-such-pool" GC_LOWPRIO=0 "$LOWPRIO" "${ASK[@]}" 2>&1 | tail -3)"
printf '%s' "$out" | grep -q "WRAPOK" && ok "P2c NO pool item -> claude still starts and answers on the ambient login (fail-open)" || bad "P2c fail-open path broke: $(printf '%s' "$out" | head -c 200)"

# ── P3: one live interactive session, from the real limit to the next account and back, with nobody typing for it ─────────────────
echo; echo "== P3  ONE live session on a REALLY exhausted account: limit -> (daemon) -> OK -> (timer) -> EXH -> limit -> (daemon) -> OK, no restart"
reseed "$EMAIL_EXH" "$EMAIL_OK"; daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_EXH" ] && ok "P3.0 the pool is seeded on EXH, whose limit is really hit" || { bad "P3.0 current='$(jget current)' - cannot continue"; exit 1; }
M0=$(nlog "API-CALL messages")

printf '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"%s":{"hasTrustDialogAccepted":true,"allowedTools":[]}}}\n' "$W/work" > "$W/cfg/.claude.json"
cat > "$W/launch.sh" <<EOF
#!/bin/bash
cd "$W/work"
exec env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="/Users/athos/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" TERM=xterm-256color \\
  CLAUDE_CONFIG_DIR="$W/cfg" GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$POOL_DIR" GC_AGENT=gastown.dog-live GC_LOWPRIO=0 \\
  "$LOWPRIO" --model haiku --strict-mcp-config --settings '{"remoteControlAtStartup":false}'
EOF
chmod +x "$W/launch.sh"
tmux -L "$SOCK" new-session -d -s s1 -x 170 -y 40 "$W/launch.sh" || { echo "tmux failed"; exit 1; }
PANE_PID0="$(tmux -L "$SOCK" display-message -p -t s1 '#{pane_pid}')"
pane() { tmux -L "$SOCK" capture-pane -p -t s1 | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -"${1:-8}"; }
scrollback() { tmux -L "$SOCK" capture-pane -p -S -400 -t s1; }
ask() { tmux -L "$SOCK" send-keys -t s1 "$1"; sleep 1; tmux -L "$SOCK" send-keys -t s1 Enter; sleep "${2:-16}"; }
unstick_wait() { # run the daemon each ~15 s until it has pressed Escape (it waits 45 s after the rewrite), at most ~2 min
  local i; for i in 1 2 3 4 5 6 7 8; do sleep 15; daemon >/dev/null 2>&1; [ "$(nlog "UNSTICK: Escape sent")" -gt "${1:-0}" ] && return 0; done; return 1
}
sleep 14
grep -q "POOL-ACCT SET" "$LOG" && ok "P3.1 the live session was launched through the wrapper (POOL-ACCT SET in the log: this is what proves it is a pool session)" || bad "P3.1 no POOL-ACCT SET"

echo "   >>> the session asks something: the account it runs on really has no balance left"
ask "Reply with exactly: ALPHA" 16
if pane 14 | grep -q "Stop and wait for limit to reset"; then ok "P3.2 the REAL exhausted account puts the live session on claude's limit modal (the screen the daemon recognises)"
else bad "P3.2 no limit modal on the live session:"; pane 12; fi

daemon >/dev/null 2>&1
E1=$(nlog "EVIDENCE:"); M1=$(nlog "API-CALL messages")
[ "$(jget current)" = "$EMAIL_OK" ] && [ "$E1" = "1" ] && [ "$((M1 - M0))" = "1" ] && nlog_sw="$(grep -c "SWITCH .* failover: $EMAIL_EXH rejected" "$LOG")" && [ "$nlog_sw" = "1" ] \
  && ok "P3.3 ONE daemon run: the modal on a pool pane is evidence -> EXH asked once (a real 429) -> the pool item moves to OK (current=$EMAIL_OK)" \
  || bad "P3.3 current='$(jget current)' evidence-lines=$E1 messages-calls=$((M1 - M0)) log: $(grep -E 'EVIDENCE|SWITCH|WARN|ERROR' "$LOG" | tail -n 4 | cut -c1-200 | tr '\n' '|')"
R="$(exh_reset "$EMAIL_EXH")"
"$PY" -c 'import sys,time; r=float(sys.argv[1]); sys.exit(0 if time.time() < r < time.time()+14*86400 else 1)' "${R:-0}" 2>/dev/null \
  && ok "P3.3b EXH's real reset time was parsed from the API headers and stored: $(date -u -r "${R%.*}" +%Y-%m-%dT%H:%M:%SZ)" || bad "P3.3b EXH reset_epoch='$R' (header names/format differ from the assumption?)"
[ "$(nlog "UNSTICK: Escape sent")" = "0" ] && ok "P3.3c no key was sent in the run that moved the item (claude has not re-read it yet)" || bad "P3.3c an Escape was sent at once"

echo "   waiting for claude to re-read the item (~30 s) and for the daemon's 45 s settle time, then its ONE Escape"
if unstick_wait 0; then ok "P3.4 the daemon sent ONE Escape to the pool session on its own: $(grep 'UNSTICK: Escape sent' "$LOG" | tail -n 1 | cut -c1-160)"
else bad "P3.4 no Escape after ~2 min: $(grep -E 'waiting|UNSTICK|WARN' "$LOG" | tail -n 3 | cut -c1-200 | tr '\n' '|')"; pane 12; fi
sleep 3
pane 10 | grep -q "Stop and wait for limit to reset" && bad "P3.4b the limit modal is still on screen" || ok "P3.4b the modal is gone: the prompt is back"
ask "The name of my dog is MANGO. Now tell me: what is 17 plus 25? Reply with the number only." 18
pane 8 | grep -qE '(^|[^0-9])42([^0-9]|$)' && ok "P3.5 the SAME session (pane pid $PANE_PID0, never restarted) answers on the OK account - nobody typed a thing for it (17+25=42, a number the question does not contain)" || { bad "P3.5 no answer (42)"; pane 12; }
[ "$(tmux -L "$SOCK" display-message -p -t s1 '#{pane_pid}')" = "$PANE_PID0" ] && ok "P3.5b the pane's process is the one launched at the start: no restart" || bad "P3.5b the pane's process changed"

echo "   >>> the stored reset time of EXH passes (the collector reads the usage 30 s after it): failback by the TIMER, no probe of EXH"
M2=$(nlog "API-CALL messages")
RI="${R%.*}"   # the state stores the reset as a float (1791410400.0); shell arithmetic wants the integer part
usage_fixture "$W/usage.json" "$EMAIL_EXH" "$EMAIL_OK" $((RI + 30))
daemon CLAUDE_POOL_NOW=$((RI + 60)) >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_EXH" ] && [ "$(nlog "API-CALL messages")" = "$M2" ] && ! grep -q "answers - the limit " "$LOG" \
  && ok "P3.6 (d) failback to EXH at its stored reset time: current=$EMAIL_EXH, no call about it ($M2 -> $(nlog "API-CALL messages") balance calls)" \
  || bad "P3.6 current='$(jget current)' messages-calls $M2 -> $(nlog "API-CALL messages")"

echo "   waiting 40 s (claude re-reads the item): the session is on EXH again, which has not really renewed"
sleep 40
ask "Reply with exactly: BRAVO" 16
# MEASURED (claude 2.1.291): the limit modal opens on a session's FIRST hit only. After it was dismissed every later hit - minutes
# later too - is the inline envelope "⎿ You've hit your weekly limit · resets ..." with the prompt right under it. The daemon reads both.
SCREEN_KIND=none
if pane 14 | grep -q "Stop and wait for limit to reset"; then SCREEN_KIND=modal
elif pane 14 | grep -qE "^ *⎿.{1,6}You.{1,3}ve hit your .*limit"; then SCREEN_KIND=envelope; fi
[ "$SCREEN_KIND" != none ] && ok "P3.7 (d) the session hits the limit again: the 429 is what says the failback was wrong (the screen shows: $SCREEN_KIND - the modal is the first hit's, the envelope every later one's)" || { bad "P3.7 no limit screen after the failback"; pane 12; }
S0=$(nlog "UNSTICK: Escape sent")
usage_fixture "$W/usage.json" "$EMAIL_EXH" "$EMAIL_OK"   # readings stamped NOW again (the failback's were stamped ahead of the real clock)
daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && [ "$(nlog "API-CALL messages")" = "$((M2 + 1))" ] \
  && ok "P3.8 (d) the failover is done AGAIN by one daemon run (one real 429), with no human: current=$EMAIL_OK" \
  || bad "P3.8 current='$(jget current)' messages-calls $M2 -> $(nlog "API-CALL messages"): $(grep -E 'EVIDENCE|SWITCH|WARN|ERROR' "$LOG" | tail -n 4 | cut -c1-200 | tr '\n' '|')"
if [ "$SCREEN_KIND" = modal ]; then
  if unstick_wait "$S0"; then ok "P3.9 and the session is unstuck again by the daemon"; else bad "P3.9 no Escape"; pane 12; fi
else
  echo "   waiting 40 s (claude re-reads the item): the envelope blocks nothing, so the daemon must NOT press anything"
  sleep 40; daemon >/dev/null 2>&1
  [ "$(nlog "UNSTICK: Escape sent")" = "$S0" ] && ok "P3.9 no key was sent to a session that shows only the envelope (nothing to dismiss: its next prompt simply runs on the new credential)" || bad "P3.9 an Escape was sent to a pane that was not on the modal"
fi
sleep 3
ask "What is 9 times 8? Reply with the number only." 18
pane 8 | grep -qE '(^|[^0-9])72([^0-9]|$)' && ok "P3.9b the same session answers again on OK (72)" || { bad "P3.9b no answer (72)"; pane 12; }
W0=$(scrollback | grep -c MANGO)
ask "What is the name of my dog? Reply with that one word only." 18
W1=$(scrollback | grep -c MANGO)
[ "$W1" -gt "$W0" ] && ok "P3.10 conversation continuity across two switches: the session still remembers what it was told earlier (the dog is MANGO)" || { bad "P3.10 continuity lost ($W0 -> $W1)"; pane 12; }

echo; echo "== zero-credit proof (the daemon's own API calls, from its log - fingerprints only, no tokens):"
echo "   evidence probes (API-CALL messages): $(nlog "API-CALL messages")   (every one against the exhausted account: $(nlog "EVIDENCE:") EVIDENCE line(s))"
echo "   key checks      (API-CALL count_tokens, not billed): $(nlog "API-CALL count_tokens")"
[ "$(nlog "answers - the limit ")" = "0" ] && ok "P3.11 no evidence probe was ever ANSWERED (served = billed): every call the daemon made on a balance question was a rejected 429" || bad "P3.11 a probe was answered ($(nlog "answers - the limit ") times)"
! grep -rqE 'sk-ant-' "$LOG" "$W/state.json" && ok "P3.12 no token in the daemon's log or state" || bad "P3.12 a token-shaped string reached the log/state"
echo; echo "== daemon log (no tokens):"; grep -v 'POOL-ACCT' "$LOG" | sed -e 's/^/   /' | tail -24
echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
