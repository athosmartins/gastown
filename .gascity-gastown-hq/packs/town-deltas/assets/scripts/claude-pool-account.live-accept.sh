#!/bin/bash
# claude-pool-account.live-accept.sh — ga-8hcnvb.1 acceptance against the REAL Claude API, the REAL Keychain and a
# REAL interactive `claude` session. Adapted from docs/research/ga-2yyitx-account-switch-spike/e1_live.sh.
# NOT part of the hermetic selftest (claude-pool-account.selftest.sh): it spends a few haiku tokens and needs two
# vault keys. Run it by hand after a change to the wrapper or the daemon.
#
# SAFE BY CONSTRUCTION: every Keychain item is a throwaway named for a scratch dir ("Claude Code-credentials-<h>",
# refused unless it is neither the production login item nor the production pool item); production state, the
# production pool item and ~/.claude are never written. Tokens never reach argv, ps, a log or the screen.
#
# IDENTITY ORACLE: OK  = terrenos.incorporacoes@ (0% used, answers).
#                  EXH = athosb85@ (weekly limit hit until 2026-10-07 ~22:00Z; can only answer with the limit
#                        error, and a rejected call costs nothing). After 2026-10-07 22:00Z pick another exhausted
#                        account, or this harness's step 2 cannot tell the accounts apart.
#
#   P1  real probes through the daemon: EXH is rejected (real 429 + real headers parsed), OK is picked.
#   P2  the pool wrapper path: claude-lowprio.sh -> claude uses the pool item; with no item it falls back to the
#       ambient login (AC: a pool session without the credential starts normally).
#   P3  one LIVE interactive session, one pid, no restart: OK -> daemon failover -> EXH (limit error, ~40 s) ->
#       daemon failback -> OK, and the conversation is still there ("what was the first thing I asked?" -> ALPHA).
set -u
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
PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
MOCK_PID=""
cleanup() {
  tmux -L "$SOCK" kill-server >/dev/null 2>&1
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  timeout 10 security delete-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT
USER="${USER:-$(id -un)}"

# the two real keys: only fingerprints are ever printed
TOK_OK="$(secret "claude-oauth-token-$EMAIL_OK")" || { echo "vault: no key for $EMAIL_OK"; exit 1; }
TOK_EXH="$(secret "claude-oauth-token-$EMAIL_EXH")" || { echo "vault: no key for $EMAIL_EXH"; exit 1; }
fp() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
echo "OK account fp=$(fp "$TOK_OK")   EXH account fp=$(fp "$TOK_EXH")   scratch item=$SVC"

usage_fixture() { # usage_fixture <file> <first-email> <second-email>   (both with balance; first renews earlier)
  "$PY" - "$1" "$2" "$3" <<'EOF'
import json, sys
f, a, b = sys.argv[1:4]
accts = [{"email": e, "weekly_all": {"percent": 10, "resets_at": "203%d-01-01T00:00:00+00:00" % i}, "session": {"percent": 5}}
         for i, e in enumerate([a, b])]
json.dump({"accounts": accts}, open(f, "w"))
EOF
}
daemon() { # daemon [ENV=val...]   (state/item are the scratch ones; probe URL only if MOCK_URL is exported)
  env HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin" GC_CITY_PATH="$W/city" \
      CLAUDE_USAGE_STORE="$W/usage.json" CLAUDE_POOL_STATE="$W/state.json" CLAUDE_POOL_CRED_DIR="$POOL_DIR" \
      ${MOCK_URL:+CLAUDE_POOL_PROBE_URL="$MOCK_URL"} "$@" "$PY" "$DAEMON" run-once
}
jget() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], ""))' "$W/state.json" "$1" 2>/dev/null; }
exh_reset() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("exhausted",{}).get(sys.argv[2],{}).get("reset_epoch",""))' "$W/state.json" "$1" 2>/dev/null; }

# ── P1: real probes, real headers ──────────────────────────────────────────────────────────────────
echo; echo "== P1  daemon with REAL probes (order: EXH first, then OK)"
usage_fixture "$W/usage.json" "$EMAIL_EXH" "$EMAIL_OK"
daemon >/dev/null 2>&1; echo "   daemon exit=$?"
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P1a EXH is skipped on a real rejection, OK account chosen (current=$EMAIL_OK)" || bad "P1a current='$(jget current)'"
r="$(exh_reset "$EMAIL_EXH")"
"$PY" -c 'import sys,time; r=float(sys.argv[1]); sys.exit(0 if time.time() < r < time.time()+14*86400 else 1)' "${r:-0}" 2>/dev/null \
  && ok "P1b EXH's real reset time was parsed from the API headers: $(date -u -r "${r%.*}" +%Y-%m-%dT%H:%M:%SZ)" || bad "P1b EXH reset_epoch='$r' (header names/format differ from the assumption?)"
[ "$(jget fingerprint)" = "$(fp "$TOK_OK")" ] && ok "P1c state fingerprint matches the OK key" || bad "P1c fingerprint '$(jget fingerprint)'"
security find-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1 && ok "P1d the pool item exists (created by the daemon)" || bad "P1d no pool item"

# ── P2: the wrapper path ───────────────────────────────────────────────────────────────────────────
echo; echo "== P2  wrapper -> claude (the path a real pool session takes)"
cd "$W/work" || exit 1
ASK=(-p "Reply with exactly the single word: WRAPOK" --model haiku --no-session-persistence --strict-mcp-config --settings '{"remoteControlAtStartup":false}')
out="$(env GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$POOL_DIR" GC_LOWPRIO=0 "$LOWPRIO" "${ASK[@]}" 2>&1 | tail -3)"
printf '%s' "$out" | grep -q "WRAPOK" && ok "P2a pool wrapper + pool item -> claude answers (credential came from the pool item)" || bad "P2a no answer via the pool item: $(printf '%s' "$out" | head -c 200)"
grep -q "POOL-ACCT SET" "$W/city/.gc/logs/claude-pool-account.log" && ok "P2b the wrapper logged POOL-ACCT SET" || bad "P2b no POOL-ACCT SET in the log"
out="$(env GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$W/no-such-pool" GC_LOWPRIO=0 "$LOWPRIO" "${ASK[@]}" 2>&1 | tail -3)"
printf '%s' "$out" | grep -q "WRAPOK" && ok "P2c NO pool item -> claude still starts and answers on the ambient login (fail-open)" || bad "P2c fail-open path broke: $(printf '%s' "$out" | head -c 200)"

# ── P3: live interactive session across daemon-driven switches ─────────────────────────────────────
echo; echo "== P3  ONE live session: OK -> (daemon failover) -> EXH -> (daemon failback) -> OK, no restart"
cat > "$W/mock.py" <<'EOF'
import http.server, json, sys
STATE, PORTF = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        beh = json.load(open(STATE)).get(tok) or {"status": 401, "h": {}}
        self.send_response(beh["status"])
        for k, v in beh.get("h", {}).items(): self.send_header(k, v)
        self.send_header("content-length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); open(PORTF, "w").write(str(s.server_address[1])); s.serve_forever()
EOF
mock_set() { # mock_set <ok-status> <ok-headers-json> <exh-status> <exh-headers-json>
  "$PY" - "$W/mock.json" "$TOK_OK" "$1" "$2" "$TOK_EXH" "$3" "$4" <<'EOF'
import json, sys
f, t1, s1, h1, t2, s2, h2 = sys.argv[1:8]
json.dump({t1: {"status": int(s1), "h": json.loads(h1)}, t2: {"status": int(s2), "h": json.loads(h2)}}, open(f, "w"))
EOF
}
NOW=$(date +%s); RESET=$((NOW + 7200))
H_ALLOW='{"anthropic-ratelimit-unified-status":"allowed"}'
H_REJ="{\"anthropic-ratelimit-unified-status\":\"rejected\",\"anthropic-ratelimit-unified-5h-status\":\"rejected\",\"anthropic-ratelimit-unified-5h-reset\":\"$RESET\",\"anthropic-ratelimit-unified-representative-claim\":\"five_hour\"}"
"$PY" "$W/mock.py" "$W/mock.json" "$W/mock.port" & MOCK_PID=$!
mock_set 200 "$H_ALLOW" 200 "$H_ALLOW"; n=0; while [ ! -s "$W/mock.port" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
export MOCK_URL="http://127.0.0.1:$(cat "$W/mock.port")/v1/messages"
usage_fixture "$W/usage.json" "$EMAIL_OK" "$EMAIL_EXH"
timeout 10 security delete-generic-password -a "$USER" -s "$SVC" >/dev/null 2>&1; rm -f "$W/state.json"
daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P3.0 daemon seeded the item with the OK account" || bad "P3.0 current='$(jget current)'"

printf '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"%s":{"hasTrustDialogAccepted":true,"allowedTools":[]}}}\n' "$W/work" > "$W/cfg/.claude.json"
cat > "$W/launch.sh" <<EOF
#!/bin/bash
cd "$W/work"
exec env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="/Users/athos/.local/bin:/opt/homebrew/bin:/usr/bin:/bin" TERM=xterm-256color \
  CLAUDE_CONFIG_DIR="$W/cfg" CLAUDE_SECURESTORAGE_CONFIG_DIR="$POOL_DIR" \
  claude --model haiku --strict-mcp-config --settings '{"remoteControlAtStartup":false}'
EOF
chmod +x "$W/launch.sh"
tmux -L "$SOCK" new-session -d -s s1 -x 170 -y 40 "$W/launch.sh" || { echo "tmux failed"; exit 1; }
pane() { tmux -L "$SOCK" capture-pane -p -t s1 | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -"${1:-8}"; }
ask() { tmux -L "$SOCK" send-keys -t s1 "$1"; sleep 1; tmux -L "$SOCK" send-keys -t s1 Enter; sleep "${2:-16}"; }
sleep 14
ask "Reply with exactly: ALPHA"
pane 8 | grep -q "ALPHA" && ok "P3.1 live session answers on the OK account (ALPHA)" || { bad "P3.1 no ALPHA"; pane 10; }

echo "   >>> OK account 'exhausted' (simulated); EXH reports allowed. Running the daemon -> failover"
mock_set 429 "$H_REJ" 200 "$H_ALLOW"
daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_EXH" ] && ok "P3.2 daemon failed over to the EXH account (current=$EMAIL_EXH)" || bad "P3.2 current='$(jget current)'"
echo "   waiting 40 s (claude re-reads the item every ~30 s)"; sleep 40
ask "Reply with exactly: BRAVO"
if pane 14 | grep -qiE "limit|usage"; then ok "P3.3 the SAME live session now hits the EXH account's limit error — switched with no restart"
else bad "P3.3 no limit message after the switch"; pane 12; fi

echo "   >>> stored reset time passes; daemon failback (no probe of the recovered account)"
daemon CLAUDE_POOL_NOW=$((RESET + 60)) >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P3.4 daemon failed back to the OK account" || bad "P3.4 current='$(jget current)'"
echo "   waiting 40 s"; sleep 40
tmux -L "$SOCK" send-keys -t s1 Escape; sleep 3          # the open limit modal does not notice the restored credential by itself
ask "Reply with exactly: CHARLIE"
pane 8 | grep -q "CHARLIE" && ok "P3.5 same session answers again on the OK account (CHARLIE)" || { bad "P3.5 no CHARLIE"; pane 12; }
ask "What was the first thing I asked you to reply with? One word." 18
pane 8 | grep -q "ALPHA" && ok "P3.6 conversation continuity: the session still remembers its first question (ALPHA)" || { bad "P3.6 continuity lost"; pane 12; }

echo; echo "== daemon log (no tokens):"; sed -e 's/^/   /' "$W/city/.gc/logs/claude-pool-account.log" | tail -14
echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
