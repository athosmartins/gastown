#!/bin/bash
# claude-pool-account.live-accept.sh — ga-8hcnvb.1 acceptance against the REAL Claude API, the REAL Keychain and a
# REAL interactive `claude` session. Adapted from docs/research/ga-2yyitx-account-switch-spike/e1_live.sh.
# NOT part of the hermetic selftest (claude-pool-account.selftest.sh): it spends a few haiku tokens and needs two
# vault keys. Run it by hand after a change to the wrapper or the daemon.
#
# SAFE BY CONSTRUCTION: every Keychain item is a throwaway named for a scratch dir ("Claude Code-credentials-<h>",
# refused unless it is neither the production login item nor the production pool item); production state, the
# production pool item and ~/.claude are never written. Tokens never reach argv, ps, a log, a file or the screen: this script
# holds them only in shell variables (read from the vault, hashed with the `printf` builtin), the daemon reads them from the
# vault itself and writes them to the scratch Keychain item, and the mock API is keyed by the 8-hex fingerprint, so the real
# tokens are not in mock.json either.
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
#   P4  (ga-8hcnvb.3) the guard on the real claude: the per-version test passes on the installed version and is queryable; a divergence
#       (rule says EXH, item holds OK) gives ONE alert naming both accounts by e-mail + fingerprint and stops once fixed; the drill that
#       makes claude 'lose' the credential fails the test, writes the degraded marker, a launch answers on the ambient login, and the
#       next passing test lifts the marker; then the real leak scan (all 5 vault keys, control first) over this run's files and ps.
#       The phone is never used: pushes go to a recorder. The guard's scratch item is its own throwaway ("claude-pool-guard-scratch").
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
import hashlib, http.server, json, sys
STATE, PORTF = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        # the table is keyed by the token's 8-hex fingerprint (the same one this script prints), never by the token itself
        beh = json.load(open(STATE)).get(hashlib.sha256(tok.encode()).hexdigest()[:8]) or {"status": 401, "h": {}}
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

echo "   >>> stored reset time passes, the collector reads the usage again 30 s after it; daemon failback (no probe of the recovered account)"
usage_fixture "$W/usage.json" "$EMAIL_OK" "$EMAIL_EXH" $((RESET + 30))
daemon CLAUDE_POOL_NOW=$((RESET + 60)) >/dev/null 2>&1
[ "$(jget current)" = "$EMAIL_OK" ] && ok "P3.4 daemon failed back to the OK account" || bad "P3.4 current='$(jget current)'"
echo "   waiting 40 s"; sleep 40
tmux -L "$SOCK" send-keys -t s1 Escape; sleep 3          # the open limit modal does not notice the restored credential by itself
ask "Reply with exactly: CHARLIE"
pane 8 | grep -q "CHARLIE" && ok "P3.5 same session answers again on the OK account (CHARLIE)" || { bad "P3.5 no CHARLIE"; pane 12; }
ask "What was the first thing I asked you to reply with? One word." 18
pane 8 | grep -q "ALPHA" && ok "P3.6 conversation continuity: the session still remembers its first question (ALPHA)" || { bad "P3.6 continuity lost"; pane 12; }

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
