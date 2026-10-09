#!/bin/bash
# claude-pool-account.live-accept.sh — ga-8hcnvb.1 acceptance against the REAL Claude API, the REAL Keychain and a
# REAL interactive `claude` session. Adapted from docs/research/ga-2yyitx-account-switch-spike/e1_live.sh.
# NOT part of the hermetic selftest (claude-pool-account.selftest.sh): it spends a few haiku tokens (the sessions) and 1-token
# probes on the model the pool runs (the daemon's PROBE_MODEL: P1 is where a wrong model ID shows up), and needs two vault keys.
# Run it by hand after a change to the wrapper or the daemon.
#
# SAFE BY CONSTRUCTION: every Keychain item is a throwaway named for a scratch dir ("Claude Code-credentials-<h>",
# refused unless it is neither the production login item nor the production pool item); production state, the
# production pool item and ~/.claude are never written. Tokens never reach argv, ps, a log, a file or the screen: this script
# holds them only in shell variables (read from the vault, hashed with the `printf` builtin), the daemon reads them from the
# vault itself and writes them to the scratch Keychain item - and, since ga-6gat1o, to the credentials file beside it in the
# scratch pool dir (0600, inside the 0700 scratch dir; P1e looks at its fingerprint only and it is removed before the P4k
# scan, because it is the one place a key belongs) - and the mock API is keyed by the 8-hex fingerprint, so the real tokens are
# not in mock.json either.
#
# IDENTITY ORACLE: OK  = terrenos.incorporacoes@ (0% used, answers).
#                  EXH = an account whose limit is hit NOW (it can only answer with the limit error, and a rejected call costs
#                        nothing). The default, athosb85@, had its weekly limit until 2026-10-07 ~22:00Z: after that it is not known to be
#                        exhausted, and if it answers P1a / P3.2 fail ("cannot tell the accounts apart") - name an exhausted one in EMAIL_EXH.
#
#   P1  real probes through the daemon: EXH is rejected (real 429 + real headers parsed), OK is picked, and the pool dir's
#       credentials file holds the OK key (fingerprint equal to the decision's).
#   P2  the pool wrapper path: claude-lowprio.sh -> claude uses the pool item; with no item it falls back to the
#       ambient login (AC: a pool session without the credential starts normally).
#   P3  one LIVE interactive session, one pid, no restart: OK -> daemon failover -> EXH (limit error, ~40 s) ->
#       daemon failback -> OK, and the conversation is still there ("what was the first thing I asked?" -> ALPHA).
#   P4  (ga-8hcnvb.3) the guard on the real claude: the per-version test passes on the installed version and is queryable; a divergence
#       (rule says EXH, item holds OK) gives ONE alert naming both accounts by e-mail + fingerprint and stops once fixed; the drill that
#       makes claude 'lose' the credential fails the test, writes the degraded marker, a launch answers on the ambient login, and the
#       next passing test lifts the marker; then the real leak scan (all 5 vault keys, control first) over this run's files and ps.
#       The phone is never used: pushes go to a recorder. The guard's scratch item is its own throwaway ("claude-pool-guard-scratch").
#   (ga-8hcnvb.2.2) the cost and the "script only" claims, counted and not left to prose: P1f / P1g (the daemon spawns no `claude` - by its
#       source, and by a `claude` on its PATH that writes down every start - and a made-up key gets a REAL 401 that it calls 'invalid'),
#       P3.1b (a warning at 99% moves nothing), P3.2b / P3.4b (the mock API logs every request the daemon makes: a steady run is 1, a
#       failover is 2 - the rejected account and the one that answers -, a failback is 1 and NONE to the account it returns to, and
#       nothing is ever sent to an endpoint but POST /v1/messages), P3.7 (the shim's count at the end: zero, beside the SWITCH lines in the
#       log, and the live session's pid never changed). The ledger it prints says what the probes cost: one 1-token call to the account in
#       use per run (a refused one is free), one more to the account a failover lands on, and none for a failback.
set -u
umask 077   # whatever this script writes under $HOME is for this user only (the scratch dir is 0700 already; the files in it too)
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="${DAEMON:-$SD/claude-pool-account.py}"
LOWPRIO="$SD/claude-lowprio.sh"
GUARD="${GUARD:-$SD/claude-pool-guard.py}"
LEAKSCAN="${LEAKSCAN:-$SD/claude-pool-leakscan.py}"
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
# A `claude` that writes down every start and does nothing else, first on the DAEMON's PATH (not on the live session's, nor the wrapper's):
# the daemon is a script and starts no claude on any path - the count at the end of P3 is how that is shown, not claimed.
mkdir -p "$W/shim"
cat > "$W/shim/claude" <<'EOF'
#!/bin/bash
echo "claude $*" >> "$SHIM_LOG"
exit 99
EOF
chmod +x "$W/shim/claude"; : > "$W/shim.calls"
shim_calls() { wc -l < "$W/shim.calls" | tr -d ' '; }
daemon() { # daemon [ENV=val...]   (state/item are the scratch ones; probe URL only if MOCK_URL is exported)
  env HOME="$HOME" USER="$USER" SHIM_LOG="$W/shim.calls" PATH="$W/shim:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin" GC_CITY_PATH="$W/city" \
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
# P1e (ga-6gat1o) the credentials file a session reads when it cannot read the item. Only the fingerprint leaves python. An empty answer
# (no file, unreadable, another shape) is "could not tell" and FAILS - it never counts as equal to the decision's fingerprint.
cf_fp() { "$PY" -c 'import json,hashlib,sys; print(hashlib.sha256(json.load(open(sys.argv[1]))["claudeAiOauth"]["accessToken"].encode()).hexdigest()[:8])' "$POOL_DIR/.credentials.json" 2>/dev/null; }
cf_mode="$(stat -f '%Lp' "$POOL_DIR/.credentials.json" 2>/dev/null || stat -c '%a' "$POOL_DIR/.credentials.json" 2>/dev/null)"
[ -n "$(cf_fp)" ] && [ "$(cf_fp)" = "$(jget fingerprint)" ] && [ "$cf_mode" = 600 ] \
  && ok "P1e the pool credentials file holds the decision's credential (fp=$(cf_fp)), mode 0600" \
  || bad "P1e credentials file fp='$(cf_fp)' mode='$cf_mode' vs the decision's fp '$(jget fingerprint)' (missing, unreadable, or another account)"
# P1f  the daemon starts no claude: by its source (every process it can spawn is named there) and by the shim's count after the real run above
spawn_set() { # every program the daemon's source can start: the first word of each subprocess / os spawn call (a variable is shown as <name>)
  "$PY" - "$DAEMON" <<'EOF'
import ast, sys
t = ast.parse(open(sys.argv[1]).read())
out = set()
for n in ast.walk(t):
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and isinstance(n.func.value, ast.Name) and n.func.value.id in ("subprocess", "os") \
       and n.func.attr in ("run", "Popen", "call", "check_call", "check_output", "system", "popen", "execv", "execvp", "execl", "spawnv"):
        a = n.args[0] if n.args else None
        while isinstance(a, ast.BinOp):   # [b, "-L", sock] + args: the program is in the list on the left
            a = a.left
        f = a.elts[0] if isinstance(a, ast.List) and a.elts else a
        out.add(f.value if isinstance(f, ast.Constant) else "<" + (ast.unparse(f) if f is not None else "?") + ">")
print(" ".join(sorted(out)))
EOF
}
spawns="$(spawn_set)"
[ "$spawns" = "<b> ps security" ] && [ "$(shim_calls)" = "0" ] \
  && ok "P1f the daemon's source spawns only: $spawns (<b> = the tmux / ps binary it resolves; never claude), and the claude on its PATH was started $(shim_calls) times by the real run" \
  || bad "P1f spawns='$spawns' shim starts=$(shim_calls) (want '<b> ps security' and 0)"
# P1g  a REAL 401: a made-up key through the daemon's own probe(), on the real API. A refused call costs nothing; "invalid" is what the pool acts on.
kind="$(env HOME="$HOME" LIVE_BOGUS="sk-ant-oat01-LIVEBOGUS$(date +%s)-not-a-key" "$PY" -c 'import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
p = m.probe(os.environ["LIVE_BOGUS"]); print(p.verdict, p.detail)' "$DAEMON" 2>&1 | tail -1)"
case "$kind" in invalid*) ok "P1g a made-up key gets a real refusal from the real API and the daemon reads it as: $kind" ;; *) bad "P1g a made-up key was read as '$kind' (want invalid: the real API's answer to a bad key is not what the daemon expects)" ;; esac

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
import hashlib, http.server, json, sys
STATE, PORTF = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def note(self, fp, status):   # one line per request, whatever it was: method, path, answer, the account's fingerprint (never the token)
        open(STATE + ".reqs", "a").write("%s %s %s %s\n" % (self.command, self.path.split("?")[0], status, fp))
    def other(self):              # anything but the probe: logged, refused
        self.note("-", 404); self.send_response(404); self.send_header("content-length", "0"); self.end_headers()
    do_GET = do_PUT = do_DELETE = do_PATCH = do_HEAD = other
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        # the table is keyed by the token's 8-hex fingerprint (the same one this script prints), never by the token itself
        fp = hashlib.sha256(tok.encode()).hexdigest()[:8]
        beh = json.load(open(STATE)).get(fp) or {"status": 401, "h": {}}
        self.note(fp, beh["status"])
        self.send_response(beh["status"])
        for k, v in beh.get("h", {}).items(): self.send_header(k, v)
        self.send_header("content-length", "2"); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); open(PORTF, "w").write(str(s.server_address[1])); s.serve_forever()
EOF
mock_set() { # mock_set <ok-status> <ok-headers-json> <exh-status> <exh-headers-json>
  # Only the two fingerprints go to the interpreter (argv) and into mock.json: the real tokens are not on a command line and not on disk.
  "$PY" - "$W/mock.json" "$(fp "$TOK_OK")" "$1" "$2" "$(fp "$TOK_EXH")" "$3" "$4" <<'EOF'
import json, sys
f, k1, s1, h1, k2, s2, h2 = sys.argv[1:8]
json.dump({k1: {"status": int(s1), "h": json.loads(h1)}, k2: {"status": int(s2), "h": json.loads(h2)}}, open(f, "w"))
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
# What the daemon sent to the (mock) API, one line each: "METHOD PATH STATUS FINGERPRINT" - the fingerprint names the account the call was made AS.
reqs_n() { if [ -f "$W/mock.json.reqs" ]; then wc -l < "$W/mock.json.reqs" | tr -d ' '; else echo 0; fi; }
req_lines() { tail -n +"$(( $1 + 1 ))" "$W/mock.json.reqs" 2>/dev/null; }          # req_lines <n0>: every request after the first n0
switches() { # how many SWITCH lines the daemon has logged; NA when the log cannot be read or grep could not count (never an empty answer that two reads would agree on)
  local n
  [ -r "$W/city/.gc/logs/claude-pool-account.log" ] || { echo NA; return; }
  n="$(grep -c "SWITCH " "$W/city/.gc/logs/claude-pool-account.log" 2>/dev/null)"   # grep -c prints 0 for "none" (rc 1); it prints nothing when it could not read
  case "$n" in ''|*[!0-9]*) echo NA ;; *) echo "$n" ;; esac
}
isnum() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }      # a count that was READ: NA / empty / junk is not a count, and two of them are not "the same count"
SW0="$(switches)"
case "$SW0" in ''|*[!0-9]*) bad "P3.0a the daemon's log cannot be read ('$SW0'): the no-SWITCH checks (P3.0b, P3.1b) and the SWITCH count (P3.7) below cannot tell" ;; *) ok "P3.0a the daemon's log is readable ($SW0 SWITCH line(s) logged before the P3 runs)" ;; esac
n0="$(reqs_n)"; daemon >/dev/null 2>&1
r="$(req_lines "$n0")"
[ "$r" = "POST /v1/messages 200 $(fp "$TOK_OK")" ] && [ "$(jget current)" = "$EMAIL_OK" ] && isnum "$SW0" && [ "$(switches)" = "$SW0" ] \
  && ok "P3.0b a steady run: ONE request, a POST /v1/messages as the account in use (answered 200), no switch" \
  || bad "P3.0b a steady run sent: $(printf '%s' "$r" | tr '\n' '|') (want exactly one POST /v1/messages 200 as the OK account); switches $SW0 -> $(switches)"

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
PANE_PID0="$(tmux -L "$SOCK" display-message -p -t s1 '#{pane_pid}' 2>/dev/null)"      # launch.sh exec's into claude: this IS the claude's pid
ask "Reply with exactly: ALPHA"
pane 8 | grep -q "ALPHA" && ok "P3.1 live session answers on the OK account (ALPHA)" || { bad "P3.1 no ALPHA"; pane 10; }

# P3.1b  nothing short of the limit moves the pool: the OK account answers 200 but the API says "warning" at 99% on both windows
H_WARN='{"anthropic-ratelimit-unified-status":"allowed_warning","anthropic-ratelimit-unified-5h-status":"allowed_warning","anthropic-ratelimit-unified-5h-utilization":"0.99","anthropic-ratelimit-unified-7d-status":"allowed_warning","anthropic-ratelimit-unified-7d-utilization":"0.99"}'
mock_set 200 "$H_WARN" 200 "$H_ALLOW"; n0="$(reqs_n)"; sw1="$(switches)"
daemon >/dev/null 2>&1; daemon >/dev/null 2>&1; daemon >/dev/null 2>&1
r="$(req_lines "$n0")"
if [ "$(jget current)" = "$EMAIL_OK" ] && isnum "$sw1" && [ "$(switches)" = "$sw1" ] && [ "$(req_lines "$n0" | grep -c .)" = 3 ] && [ -z "$(printf '%s\n' "$r" | grep -v "^POST /v1/messages 200 $(fp "$TOK_OK")$")" ]; then
  ok "P3.1b a WARNING at 99% (5h and 7d) on the account in use moves nothing over 3 runs: still the OK account, no SWITCH, one request per run, none to EXH"
else bad "P3.1b current='$(jget current)' switches $sw1 -> $(switches) (NA = the log could not be read: no SWITCH cannot be concluded); requests: $(printf '%s' "$r" | tr '\n' '|')"; fi
mock_set 200 "$H_ALLOW" 200 "$H_ALLOW"

echo "   >>> OK account 'exhausted' (simulated); EXH reports allowed. Running the daemon -> failover"
mock_set 429 "$H_REJ" 200 "$H_ALLOW"
n0="$(reqs_n)"
daemon >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_EXH" ] && ok "P3.2 daemon failed over to the EXH account (current=$EMAIL_EXH)" || bad "P3.2 current='$(jget current)'"
r="$(req_lines "$n0")"
[ "$r" = "POST /v1/messages 429 $(fp "$TOK_OK")
POST /v1/messages 200 $(fp "$TOK_EXH")" ] \
  && ok "P3.2b the failover is TWO requests: the account in use (rejected, 429 - costs nothing) and the one it lands on (answered - a 1-token call); no usage / balance endpoint, no claude" \
  || bad "P3.2b the failover sent: $(printf '%s' "$r" | tr '\n' '|')"
echo "   waiting 40 s (claude re-reads the item every ~30 s)"; sleep 40
ask "Reply with exactly: BRAVO"
if pane 14 | grep -qiE "limit|usage"; then ok "P3.3 the SAME live session now hits the EXH account's limit error — switched with no restart"
else bad "P3.3 no limit message after the switch"; pane 12; fi

echo "   >>> stored reset time passes, the collector reads the usage again 30 s after it; daemon failback (no probe of the recovered account)"
usage_fixture "$W/usage.json" "$EMAIL_OK" "$EMAIL_EXH" $((RESET + 30))
n0="$(reqs_n)"
daemon CLAUDE_POOL_NOW=$((RESET + 60)) >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P3.4 daemon failed back to the OK account" || bad "P3.4 current='$(jget current)'"
r="$(req_lines "$n0")"
[ "$r" = "POST /v1/messages 200 $(fp "$TOK_EXH")" ] \
  && ok "P3.4b the failback is ONE request - the probe of the account in use (EXH, answered) - and NOTHING as the OK account it returned to (the mock still has OK at 429: a probe would have kept the pool away)" \
  || bad "P3.4b the failback sent: $(printf '%s' "$r" | tr '\n' '|') (want one POST as EXH and none as OK)"
echo "   waiting 40 s"; sleep 40
tmux -L "$SOCK" send-keys -t s1 Escape; sleep 3          # the open limit modal does not notice the restored credential by itself
ask "Reply with exactly: CHARLIE"
pane 8 | grep -q "CHARLIE" && ok "P3.5 same session answers again on the OK account (CHARLIE)" || { bad "P3.5 no CHARLIE"; pane 12; }
ask "What was the first thing I asked you to reply with? One word." 18
pane 8 | grep -q "ALPHA" && ok "P3.6 conversation continuity: the session still remembers its first question (ALPHA)" || { bad "P3.6 continuity lost"; pane 12; }
PANE_PID1="$(tmux -L "$SOCK" display-message -p -t s1 '#{pane_pid}' 2>/dev/null)"
{ [ -n "$PANE_PID0" ] && [ "$PANE_PID0" = "$PANE_PID1" ] && kill -0 "$PANE_PID0" 2>/dev/null; } \
  && ok "P3.6b one process the whole way: the session's pid is $PANE_PID0 before the first switch and after the last, and it is alive (no restart)" \
  || bad "P3.6b the session's pid went '$PANE_PID0' -> '$PANE_PID1' (or it is gone)"
# P3.7  the switch path never started a claude: the shim saw no start across P1 and P3 - the failover, the failback and every steady run - beside the SWITCH lines it logged
SW_END="$(switches)"; SW_DELTA=NA      # a log that cannot be read now (or could not at P3.0a) is NA, not an arithmetic error that aborts the harness and not a count of 0
case "$SW0" in ''|*[!0-9]*) ;; *) case "$SW_END" in ''|*[!0-9]*) ;; *) SW_DELTA=$(( SW_END - SW0 )) ;; esac ;; esac
[ "$(shim_calls)" = "0" ] && [ "$SW_DELTA" = 2 ] \
  && ok "P3.7 $SW_DELTA SWITCH lines (failover, failback) and the claude on the daemon's PATH was started $(shim_calls) times by any daemon run in this harness - the switch is a script, no claude, no LLM" \
  || bad "P3.7 shim starts=$(shim_calls) (want 0), SWITCH lines since the seed=$SW_DELTA (want 2; NA = the log could not be read): $(head -3 "$W/shim.calls" 2>/dev/null | tr '\n' '|')"
echo "   cost ledger, P3 (the mock logged every request the daemon made): $(reqs_n) requests = $(grep -c ' 429 ' "$W/mock.json.reqs") rejected (a refused call costs nothing) + $(grep -c ' 200 ' "$W/mock.json.reqs") answered (a 1-token call each: max_tokens=1)"
echo "   a daemon run = one call as the account in use; a failover = one more as the account it lands on; a failback = none as the account it returns to. P1's real calls: 1 rejected + 1 answered, by the decision (not metered here)."

# ── P4: the guard (ga-8hcnvb.3) on the REAL claude, the REAL Keychain (scratch items only) and the REAL vault ───────────────────────
echo; echo "== P4  claude-pool-guard: per-version test on the real claude, divergence alert, degrade + recover, key-leak scan"
tmux -L "$SOCK" kill-server >/dev/null 2>&1                              # P3's session is done; P4 does not need it
GSCR="$W/claude-pool-guard-scratch"                                      # the guard refuses a scratch dir not named for itself
: > "$W/notify.rec"
cat > "$W/notify-rec.sh" <<'EOF2'
#!/bin/bash
# the PHONE IS NOT USED by this harness: a recorder with notify's argv shape (-t title -p prio message), one CALL line per push
printf 'CALL %s\n' "$*" >> "$REC_FILE"
exit 0
EOF2
chmod +x "$W/notify-rec.sh"
pushes() { grep -c "^CALL .* -p ${1:-4} " "$W/notify.rec" 2>/dev/null || true; }
stamp_hb() { # the daemon's own write_heartbeat() at <clock-epoch>: what the real daemon leaves every minute. P1-P3 ran the daemon on a SIMULATED
  # clock (RESET+60, 2 h ahead), so its last stamp is in the guard's future - which the guard rightly reads as 'cannot tell', not as a live daemon.
  env HOME="$HOME" USER="$USER" GC_CITY_PATH="$W/city" CLAUDE_POOL_NOW="$1" "$PY" -c 'import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); m.write_heartbeat()' "$DAEMON" >/dev/null 2>&1
}
guard() { # guard <clock-epoch> <command...>   (GX="A=b C=d" adds env; the clock is the guard's own seam, the claude is the real one)
  local now="$1"; shift
  stamp_hb "$now"
  env HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin:/opt/homebrew/bin:$HOME/.local/bin" GC_CITY_PATH="$W/city" \
      CLAUDE_POOL_STATE="$W/state.json" CLAUDE_POOL_CRED_DIR="$POOL_DIR" CLAUDE_POOL_GUARD_STATE="$W/guard.json" \
      CLAUDE_POOL_GUARD_SCRATCH="$GSCR" CLAUDE_POOL_NOTIFY_CMD="$W/notify-rec.sh" REC_FILE="$W/notify.rec" \
      CLAUDE_POOL_GUARD_RETRY_WAIT_S=2 CLAUDE_POOL_NOW="$now" ${GX:-} "$PY" "$GUARD" "$@"
}
gjson() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); 
for k in sys.argv[2].split("/"): d = d.get(k, "") if isinstance(d, dict) else ""
print(d)' "$W/guard.json" "$1" 2>/dev/null; }
REAL_VER="$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -1)"
echo "   claude under test: ${REAL_VER:-?}"
T0=$(date +%s)

# P4a-b  the per-version test, on the real claude: scratch item, fake credential, `claude auth status --json`
guard "$T0" run-once >/dev/null 2>&1
[ "$(gjson "versions/$REAL_VER/result")" = pass ] && ok "P4a the real claude $REAL_VER PASSES the per-version test (logged in with the scratch credential, not without it)" \
  || bad "P4a result for $REAL_VER: '$(gjson "versions/$REAL_VER/result")' ($(gjson "versions/$REAL_VER/detail"))"
guard "$T0" status --json 2>/dev/null | grep -q "\"$REAL_VER\"" && ok "P4b the result is queryable: status --json names the version and its verdict" || bad "P4b status --json does not show $REAL_VER"
[ ! -e "$W/city/.gc/pool-account-degraded" ] && [ ! -d "$GSCR" ] && ok "P4b2 no degraded marker, and the scratch dir is gone" || bad "P4b2 marker or scratch left behind"

# P4c  divergence: the rule says EXH, the pool item holds OK. Debounced 120 s, then ONE alert; fixed -> it stops
"$PY" - "$W/state.json" "$EMAIL_EXH" "$(fp "$TOK_EXH")" <<'EOF2'
import json, sys
f, email, fp = sys.argv[1:4]
d = json.load(open(f)); d["current"], d["fingerprint"] = email, fp; json.dump(d, open(f, "w"))
EOF2
T1=$((T0 + 100)); guard "$T1" run-once >/dev/null 2>&1; guard $((T1 + 60)) run-once >/dev/null 2>&1
[ "$(pushes 4)" = 0 ] && ok "P4c the divergence is not alerted before the debounce (60 s in)" || bad "P4c alerted too early: $(pushes 4) pushes"
guard $((T1 + 180)) run-once >/dev/null 2>&1; guard $((T1 + 240)) run-once >/dev/null 2>&1; guard $((T1 + 300)) run-once >/dev/null 2>&1
alert="$(grep "^CALL .* -p 4 " "$W/notify.rec" | head -1)"
[ "$(pushes 4)" = 1 ] && ok "P4d ONE phone alert (priority 4) for the episode, 3 min after the first sighting, not repeated on the next ticks" || bad "P4d pushes=$(pushes 4)"
if printf '%s' "$alert" | grep -q "$EMAIL_EXH" && printf '%s' "$alert" | grep -q "$EMAIL_OK" && printf '%s' "$alert" | grep -q "$(fp "$TOK_EXH")" && printf '%s' "$alert" | grep -q "$(fp "$TOK_OK")"; then
  ok "P4e the alert names the expected AND the in-use account, each by e-mail + fingerprint"
else bad "P4e the alert misses an account name: $(printf '%s' "$alert" | head -c 300)"; fi
"$PY" - "$W/state.json" "$EMAIL_OK" "$(fp "$TOK_OK")" <<'EOF2'
import json, sys
f, email, fp = sys.argv[1:4]
d = json.load(open(f)); d["current"], d["fingerprint"] = email, fp; json.dump(d, open(f, "w"))
EOF2
before="$(pushes 4)"; guard $((T1 + 360)) run-once >/dev/null 2>&1; guard $((T1 + 3600)) run-once >/dev/null 2>&1; guard $((T1 + 7200)) run-once >/dev/null 2>&1
[ "$(pushes 4)" = "$before" ] && ok "P4f the account fixed -> the alert does not repeat (even an hour and two hours later)" || bad "P4f pushes went $before -> $(pushes 4): $(grep '^CALL' "$W/notify.rec" | cut -c1-110 | tr '\n' '|')"

# P4g-i  the real claude 'changes its internals': the drill makes the test see the credential removed -> degrade, answer on the ambient login, recover
GX="CLAUDE_POOL_GUARD_FAULT=remove" guard $((T1 + 400)) selftest >/dev/null 2>&1
[ "$(gjson "versions/$REAL_VER/result")" = fail ] && [ -e "$W/city/.gc/pool-account-degraded" ] && ok "P4g with the credential 'removed' the per-version test FAILS on the real claude and the degraded marker is written" \
  || bad "P4g result='$(gjson "versions/$REAL_VER/result")' marker=$([ -e "$W/city/.gc/pool-account-degraded" ] && echo yes || echo no)"
grep "^CALL .* -p 4 " "$W/notify.rec" | grep -qi "DESLIGADA" && ok "P4h an alert says automatic switching is OFF" || bad "P4h no 'DESLIGADA' push: $(tail -2 "$W/notify.rec" | head -c 300)"
n0="$(grep -c "POOL-ACCT SET" "$W/city/.gc/logs/claude-pool-account.log")"
out="$(env GC_CITY_PATH="$W/city" GC_POOL_CRED_DIR="$POOL_DIR" GC_LOWPRIO=0 "$LOWPRIO" "${ASK[@]}" 2>&1 | tail -3)"
if printf '%s' "$out" | grep -q "WRAPOK" && [ "$(grep -c "POOL-ACCT SET" "$W/city/.gc/logs/claude-pool-account.log")" = "$n0" ] && grep -q "POOL-ACCT SKIP disabled by .*pool-account-degraded" "$W/city/.gc/logs/claude-pool-account.log"; then
  ok "P4i an agent started while degraded answers normally on the current login (the wrapper skipped the pool item and said why)"
else bad "P4i degraded launch: $(printf '%s' "$out" | head -c 200)"; fi
guard $((T1 + 500)) selftest >/dev/null 2>&1
[ "$(gjson "versions/$REAL_VER/result")" = pass ] && [ ! -e "$W/city/.gc/pool-account-degraded" ] && ok "P4j the next passing test removes the marker by itself" || bad "P4j result='$(gjson "versions/$REAL_VER/result")' marker still there?"

# P4k-m  zero occurrences of ANY of the 5 keys (the vault's, via --keys-vault) where it must not be; the control runs first and a failed control is exit 3
# The scratch pool dir's credentials file is where the daemon puts the OK key on purpose (the item's twin, ga-6gat1o; P1e looked at it): the scan walks
# all of $W, so the file is removed first - what it checks is every OTHER place. (vazio -> already gone: nothing to remove; falhou -> the scan below
# finds the key in it and FAILS: a failed removal is never a pass.)
rm -f "$POOL_DIR/.credentials.json"
out="$("$PY" "$LEAKSCAN" --keys-vault --ps --path "$W" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep "^SUMMARY" | sed -e 's/^/   /'
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q "control=ok" && ok "P4k scan of this run's files (logs, state, decision, guard state, recorded pushes) + ps argv/env: no key anywhere, control saw its plant" || { bad "P4k leakscan rc=$rc"; printf '%s\n' "$out" | head -6 | cut -c1-200; }
plant="sk-ant-oat01-LIVEPLANT$(date +%s)abcdefghij"; printf '%s\n' "$plant" > "$W/planted.txt"
printf '{"plant@control.test":"%s"}' "$plant" | "$PY" "$LEAKSCAN" --keys-stdin --path "$W/planted.txt" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "P4l control: the same scan finds a key planted on purpose (exit 1)" || bad "P4l the planted key was not found (rc=$rc)"
rm -f "$W/planted.txt"; unset plant

echo; echo "== daemon log (no tokens):"; sed -e 's/^/   /' "$W/city/.gc/logs/claude-pool-account.log" | tail -14
echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
