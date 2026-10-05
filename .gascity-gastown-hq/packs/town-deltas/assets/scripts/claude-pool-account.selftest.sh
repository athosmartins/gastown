#!/usr/bin/env bash
# claude-pool-account.selftest.sh — ga-8hcnvb.1: the pool's Claude account is DATA in a Keychain item, and a single
# daemon decides which account that item holds.
#
# Two halves, one file, because either half alone is worth nothing:
#   A. WRAPPER (claude-lowprio.sh, the last hop before `claude`): a pool session is pointed at the pool item
#      (CLAUDE_SECURESTORAGE_CONFIG_DIR + USER) ONLY when the item exists, and never otherwise — fail-open.
#   B. DAEMON (claude-pool-account.py): failover when the active account is rejected, failback at the stored
#      reset time, the decision published for the WhatsApp services, no token ever in argv / logs.
#
# HERMETIC: a fake `security` (state in a temp dir), a fake `claude`, a fake probe and a fake vault. Nothing here
# touches the real Keychain, the real vault or the network.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${CLAUDE_POOL_WRAPPER:-$SELF_DIR/claude-lowprio.sh}"
DAEMON="${CLAUDE_POOL_DAEMON:-$SELF_DIR/claude-pool-account.py}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$WRAPPER" ] || { echo "FATAL: wrapper not found at $WRAPPER"; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-pool-account-selftest.XXXXXX")"
cleanup() { rm -rf "$W"; }
trap cleanup EXIT

field() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

# ── A. wrapper ─────────────────────────────────────────────────────────────────────────────────────
echo "A. wrapper (claude-lowprio.sh)"

BIN="$W/bin"; mkdir -p "$BIN" "$W/city/.gc/logs"
# fake claude: reports the two variables the wrapper may export, plus argv, one fact per line
cat > "$BIN/fake-claude" <<'EOF'
#!/bin/bash
echo "secstore=${CLAUDE_SECURESTORAGE_CONFIG_DIR-<unset>}"
echo "user=${USER-<unset>}"
echo "argc=$#"
i=0; for a in "$@"; do i=$((i+1)); printf 'arg%d=[%s]\n' "$i" "$a"; done
EOF
# fake security: `find-generic-password` succeeds iff $FAKE_KC/<service> exists; records every argv line
cat > "$BIN/security" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_KC/argv.log"
[ "$1" = "find-generic-password" ] || exit 1
svc=""; while [ $# -gt 0 ]; do [ "$1" = "-s" ] && svc="$2"; shift; done
[ -e "$FAKE_KC/items/$svc" ]
EOF
chmod +x "$BIN/fake-claude" "$BIN/security"

POOL_DIR="$W/home/.gastown/claude-pool-cred"
POOL_HASH="$(printf '%s' "$POOL_DIR" | shasum -a 256 | cut -c1-8)"
SVC="Claude Code-credentials-$POOL_HASH"

new_kc() { rm -rf "$W/kc"; mkdir -p "$W/kc/items"; export FAKE_KC="$W/kc"; : > "$W/city/.gc/logs/claude-pool-account.log"; rm -f "$W/city/.gc/no-pool-account"; }
run_wrapper() { # run_wrapper [env assignments...] -- args...
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -i HOME="$W/home" PATH="$BIN:/usr/bin:/bin" GC_CITY_PATH="$W/city" GC_LOWPRIO=0 \
      GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude" GC_POOL_CRED_DIR="$POOL_DIR" FAKE_KC="${FAKE_KC:-}" "${envs[@]}" \
      "$WRAPPER" "$@" 2>/dev/null
}

new_kc; touch "$FAKE_KC/items/$SVC"
out="$(run_wrapper USER=athos -- --model haiku)"
[ "$(field secstore "$out")" = "$POOL_DIR" ] && ok "A1 item present -> CLAUDE_SECURESTORAGE_CONFIG_DIR points at the pool dir" \
  || bad "A1 item present -> expected secstore=$POOL_DIR, got '$(field secstore "$out")'"
[ "$(field user "$out")" = "athos" ] && ok "A1b USER is passed through" || bad "A1b USER not exported ('$(field user "$out")')"
[ "$(field argc "$out")" = "2" ] && [ "$(field arg1 "$out")" = "[--model]" ] && ok "A1c argv untouched" || bad "A1c argv changed: $out"

new_kc
out="$(run_wrapper USER=athos -- --model haiku)"
[ "$(field secstore "$out")" = "<unset>" ] && ok "A2 item absent -> variable NOT exported (fail-open to the ambient login)" \
  || bad "A2 item absent but secstore='$(field secstore "$out")'"

new_kc; touch "$FAKE_KC/items/$SVC"
out="$(run_wrapper USER=athos GC_POOL_ACCOUNT=0 -- x)"
[ "$(field secstore "$out")" = "<unset>" ] && ok "A3 GC_POOL_ACCOUNT=0 -> not exported" || bad "A3 kill switch (env) ignored"

new_kc; touch "$FAKE_KC/items/$SVC" "$W/city/.gc/no-pool-account"
out="$(run_wrapper USER=athos -- x)"
[ "$(field secstore "$out")" = "<unset>" ] && ok "A4 .gc/no-pool-account -> not exported" || bad "A4 kill switch (file) ignored"

new_kc; touch "$FAKE_KC/items/$SVC"
out="$(run_wrapper USER=athos CLAUDE_SECURESTORAGE_CONFIG_DIR=/operator/choice -- x)"
[ "$(field secstore "$out")" = "/operator/choice" ] && ok "A5 an operator-set CLAUDE_SECURESTORAGE_CONFIG_DIR is left alone" \
  || bad "A5 operator value overwritten: '$(field secstore "$out")'"

new_kc; touch "$FAKE_KC/items/$SVC"
out="$(run_wrapper -- x)"   # no USER in the environment at all (tmux / launchd can do this)
[ -n "$(field user "$out")" ] && [ "$(field user "$out")" != "<unset>" ] && ok "A6 USER missing from env -> derived, never left empty" \
  || bad "A6 USER still unset: '$(field user "$out")'"

new_kc; touch "$FAKE_KC/items/$SVC"
run_wrapper USER=athos -- x >/dev/null
if [ ! -s "$FAKE_KC/argv.log" ]; then bad "A7 vacuous: the fake security was never called"
elif grep -qE '(^| )-[a-zA-Z]*[wg]( |$)' "$FAKE_KC/argv.log" 2>/dev/null; then bad "A7 wrapper asked security to PRINT the secret (-w/-g): $(cat "$FAKE_KC/argv.log")"
else ok "A7 wrapper only checks existence (never -w/-g)"; fi

new_kc; touch "$FAKE_KC/items/$SVC"
out="$(env -i HOME="$W/home" PATH="/usr/bin:/bin" USER=athos GC_CITY_PATH="$W/city" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude" GC_POOL_CRED_DIR="$POOL_DIR" "$WRAPPER" x 2>/dev/null)"
[ "$(field argc "$out")" = "1" ] && [ "$(field secstore "$out")" = "<unset>" ] && ok "A8 no \`security\` binary at all -> claude still launches, variable not exported" \
  || bad "A8 missing security broke the launch: $out"

new_kc; touch "$FAKE_KC/items/$SVC"
run_wrapper USER=athos -- x >/dev/null
grep -q "POOL-ACCT SET" "$W/city/.gc/logs/claude-pool-account.log" && ok "A9 one POOL-ACCT SET line in claude-pool-account.log" || bad "A9 no POOL-ACCT SET line: $(cat "$W/city/.gc/logs/claude-pool-account.log")"
[ "$(grep -c "POOL-ACCT" "$W/city/.gc/logs/claude-lowprio.log" 2>/dev/null || true)" = "0" ] && ok "A9a the lowprio log keeps its one-line-per-launch contract (no POOL-ACCT lines)" || bad "A9a POOL-ACCT lines leaked into claude-lowprio.log"
grep -q "sk-ant-" "$W/city/.gc/logs/claude-pool-account.log" && bad "A9b log carries a token shape" || ok "A9b log carries no token shape"

new_kc; touch "$FAKE_KC/items/$SVC"
mkdir -p "$W/hang"; cat > "$W/hang/security" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$W/hang/security"
t0=$(date +%s)
out="$(env -i HOME="$W/home" PATH="$W/hang:/usr/bin:/bin" USER=athos GC_CITY_PATH="$W/city" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude" GC_POOL_CRED_DIR="$POOL_DIR" GC_POOL_SECURITY_TIMEOUT=1 FAKE_KC="$FAKE_KC" "$WRAPPER" x 2>/dev/null)"
t1=$(date +%s)
[ "$(field argc "$out")" = "1" ] && [ "$(field secstore "$out")" = "<unset>" ] && [ $((t1 - t0)) -lt 15 ] \
  && ok "A10 a hanging \`security\` is cut off by the timeout -> claude launches without the variable ($((t1 - t0))s)" \
  || bad "A10 hanging security stalled or broke the launch (${t1}-${t0}): $out"
grep -q "POOL-ACCT SKIP.*rc=124" "$W/city/.gc/logs/claude-pool-account.log" \
  && ok "A10b ...and the SKIP line says WHY: security timed out (rc=124), which is not 'there is no item'" \
  || bad "A10b the SKIP line does not carry the timeout: $(tail -n 2 "$W/city/.gc/logs/claude-pool-account.log")"

# A11 the SKIP line carries the exit status of `security`: 'no item' (44, expected until the daemon seeds it) must not read the same
# as 'could not look' (locked keychain, wedged security, no binary) when someone asks why a pool session is on the ambient login.
for rc in 44 36; do
  new_kc; mkdir -p "$W/rc$rc"; printf '#!/bin/bash\nexit %s\n' "$rc" > "$W/rc$rc/security"; chmod +x "$W/rc$rc/security"
  out="$(env -i HOME="$W/home" PATH="$W/rc$rc:/usr/bin:/bin" USER=athos GC_CITY_PATH="$W/city" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude" GC_POOL_CRED_DIR="$POOL_DIR" "$WRAPPER" x 2>/dev/null)"
  [ "$(field secstore "$out")" = "<unset>" ] && grep -q "POOL-ACCT SKIP.*rc=$rc" "$W/city/.gc/logs/claude-pool-account.log" \
    && ok "A11 security exits $rc -> not exported, and the SKIP line says rc=$rc" \
    || bad "A11 security exits $rc: secstore='$(field secstore "$out")' log: $(tail -n 1 "$W/city/.gc/logs/claude-pool-account.log")"
done

# ── B. daemon ──────────────────────────────────────────────────────────────────────────────────────
echo
echo "B. daemon (claude-pool-account.py)"

PY3="${CLAUDE_POOL_PY:-/usr/bin/python3}"; [ -x "$PY3" ] || PY3="$(command -v python3)"   # the interpreter launchd runs (3.9), not whichever is first on PATH
ACCT_LIB="${CLAUDE_POOL_ACCOUNTS_LIB:-/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py}"
BB="$W/bbin"; mkdir -p "$BB"

# fake `security`: the subset the daemon uses. `-i` reads commands from stdin (so no secret is ever in argv);
# the item store is $FAKE_KC/items/<service> holding the hex the daemon wrote.
cat > "$BB/security" <<'EOF'
#!/bin/bash
KC="$FAKE_KC"; echo "ARGV: $*" >> "$KC/argv.log"
run_cmd() {
  local sub="$1" svc="" hex="" w=0; shift
  while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift ;; -X) hex="$2"; shift ;; -w) w=1 ;; esac; shift; done
  case "$sub" in
    add-generic-password) [ -e "$KC/refuse-writes" ] && { echo "security: write refused (selftest)" >&2; return 1; }
                          [ -n "$svc" ] && [ -n "$hex" ] || return 1
                          printf '%s' "$hex" > "$KC/items/$svc"; echo "WRITE $svc" >> "$KC/writes.log" ;;
    find-generic-password) [ -e "$KC/locked" ] && { echo "security: User interaction is not allowed." >&2; return 36; }
                           [ -e "$KC/items/$svc" ] || { echo "security: The specified item could not be found in the keychain." >&2; return 44; }
                           if [ "$w" = 1 ]; then xxd -r -p "$KC/items/$svc"; echo; fi ;;
    *) return 1 ;;
  esac
}
if [ "${1:-}" = "-i" ]; then
  while IFS= read -r line; do eval "set -- $line"; run_cmd "$@" || exit $?; done
else run_cmd "$@"; fi
EOF
# fake vault: `secret claude-oauth-token-<email>` -> $VAULT/<email>; absent -> exit 4 "Not found" (as the real one); every call is
# logged to $VAULT/.calls (dotfile: `rm $VAULT/*` leaves it); $VAULT/.broken makes the vault UNREADABLE (exit 1, not 'Not found')
cat > "$BB/secret" <<'EOF'
#!/bin/bash
e="${1#claude-oauth-token-}"
echo "$e" >> "$VAULT/.calls"
if [ -e "$VAULT/.broken" ]; then echo "secret: bw serve unreachable (selftest)" >&2; exit 1; fi
if [ -s "$VAULT/$e" ]; then cat "$VAULT/$e"; exit 0; fi
echo "secret: Not found." >&2; exit 4
EOF
chmod +x "$BB/security" "$BB/secret"

# mock Anthropic: behaviour per Bearer token from $W/srv.json = {token: {status, h:{header:value}}}; every request token logged
cat > "$W/mock_api.py" <<'EOF'
import http.server, json, sys
STATE, LOG, PORTF = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.do_POST()   # a redirect followed by urllib arrives as a GET: log its Bearer too
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        beh = json.load(open(STATE)).get(tok) or {"status": 401, "h": {}}
        with open(LOG, "a") as f: f.write(tok + "\n")
        self.send_response(beh["status"])
        for k, v in beh.get("h", {}).items(): self.send_header(k, v)
        body = b"{}"; self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTF, "w").write(str(srv.server_address[1])); srv.serve_forever()
EOF

# accounts a/b/c (order = a,b,c by weekly renewal; far-future dates so the order never depends on today's date)
EMAILS=(a@t.test b@t.test c@t.test)
TOKEN_a="sk-ant-oat01-TESTaaaaaaaaaaaaaaaaaaaaaaaa"; TOKEN_b="sk-ant-oat01-TESTbbbbbbbbbbbbbbbbbbbbbbbb"; TOKEN_c="sk-ant-oat01-TESTcccccccccccccccccccccccc"
tok_of() { case "$1" in a@t.test) echo "$TOKEN_a" ;; b@t.test) echo "$TOKEN_b" ;; c@t.test) echo "$TOKEN_c" ;; esac; }
fp_of() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }

D="$W/d"; STATE="$D/current.json"; SRV_PID=""
# A reset time is believed only if it is ahead of NOW and at most 31 days away (the daemon's _usable_reset). The scenarios below
# store reset times like 2000000000, so they run on a clock that makes them 11 days ahead - unless a test sets NOW_OVERRIDE itself
# (NOW_OVERRIDE= with an empty value = the real clock).
NOW_BASE=1999000000
HDR_OK='{"anthropic-ratelimit-unified-status":"allowed","anthropic-ratelimit-unified-5h-status":"allowed","anthropic-ratelimit-unified-7d-status":"allowed","anthropic-ratelimit-unified-5h-reset":"1900000000","anthropic-ratelimit-unified-7d-reset":"1900500000"}'
hdr_rejected() { # hdr_rejected <claim five_hour|seven_day> <reset-epoch>
  local w="7d"; [ "$1" = "five_hour" ] && w="5h"
  printf '{"anthropic-ratelimit-unified-status":"rejected","anthropic-ratelimit-unified-%s-status":"rejected","anthropic-ratelimit-unified-%s-reset":"%s","anthropic-ratelimit-unified-representative-claim":"%s","retry-after":"600"}' "$w" "$w" "$2" "$1"
}
set_srv() { set_srv_in "$D/srv.json" "$(tok_of "$1")" "$2" "$3"; }   # set_srv <email> <status> <headers-json>
set_srv_in() { # set_srv_in <state-file> <token> <status> <headers-json>
  "$PY3" - "$1" "$2" "$3" "$4" <<'EOF'
import json, sys
p, tok, status, hdr = sys.argv[1:5]
try: d = json.load(open(p))
except Exception: d = {}
d[tok] = {"status": int(status), "h": json.loads(hdr)}
json.dump(d, open(p, "w"))
EOF
}
new_d() { # fresh daemon world with all three accounts allowed
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$D"; mkdir -p "$D/kc/items" "$D/vault" "$D/city/.gc/logs" "$D/home"
  : > "$D/probes.log"; echo '{}' > "$D/srv.json"
  local i=0 e
  for e in "${EMAILS[@]}"; do printf '%s' "$(tok_of "$e")" > "$D/vault/$e"; set_srv "$e" 200 "$HDR_OK"; done
  "$PY3" - "$D/usage.json" <<'EOF'
import json, sys
accts = [{"email": e, "weekly_all": {"percent": 10, "resets_at": "203%d-01-01T00:00:00+00:00" % i}, "session": {"percent": 5}}
         for i, e in enumerate(["a@t.test", "b@t.test", "c@t.test"])]
json.dump({"accounts": accts}, open(sys.argv[1], "w"))
EOF
  "$PY3" "$W/mock_api.py" "$D/srv.json" "$D/probes.log" "$D/port" & SRV_PID=$!
  local n=0; while [ ! -s "$D/port" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  export FAKE_KC="$D/kc" VAULT="$D/vault"
}
run_d() { # run_d [env assignments...] -- <daemon args>   (always a clean environment)
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  env -i HOME="$D/home" USER=athos PATH="$BB:/usr/bin:/bin" GC_CITY_PATH="$D/city" FAKE_KC="$D/kc" VAULT="$D/vault" \
      CLAUDE_USAGE_STORE="$D/usage.json" CLAUDE_POOL_STATE="$STATE" CLAUDE_POOL_CRED_DIR="$POOL_DIR" \
      CLAUDE_POOL_ACCOUNTS_LIB="$ACCT_LIB" CLAUDE_POOL_PROBE_URL="http://127.0.0.1:$(cat "$D/port")/v1/messages" \
      CLAUDE_POOL_NOW="${NOW_OVERRIDE-$NOW_BASE}" "${envs[@]}" "$PY3" "$DAEMON" "$@" >"$D/out.txt" 2>&1
}
jget() { "$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1])); 
for k in sys.argv[2].split("."): d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1" "$2" 2>/dev/null; }
item_token() { # token stored in the pool item (decoded from the hex the daemon wrote)
  [ -e "$D/kc/items/$SVC" ] || { echo "<no-item>"; return; }
  "$PY3" -c 'import json,sys; print(json.loads(bytes.fromhex(open(sys.argv[1]).read()))["claudeAiOauth"]["accessToken"])' "$D/kc/items/$SVC"
}
writes() { [ -f "$D/kc/writes.log" ] && wc -l < "$D/kc/writes.log" | tr -d ' ' || echo 0; }

if [ ! -f "$DAEMON" ]; then
  bad "B0 daemon not found at $DAEMON"
elif [ ! -f "$ACCT_LIB" ]; then
  bad "B0 accounts lib not found at $ACCT_LIB"
else
  new_d
  run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && ok "B1 first run, no item/state -> the pool item is seeded with the first account in the order (a)" \
    || bad "B1 pool item holds '$(item_token | cut -c1-20)...' (rc out: $(head -c 300 "$D/out.txt"))"
  [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B1b the decision is published (current=a@t.test)" || bad "B1b state current='$(jget "$STATE" current)'"
  [ "$(jget "$STATE" fingerprint)" = "$(fp_of "$TOKEN_a")" ] && ok "B1c state carries the 8-hex fingerprint, not the token" || bad "B1c fingerprint '$(jget "$STATE" fingerprint)'"
  blob="$("$PY3" -c 'import json,sys; b=json.loads(bytes.fromhex(open(sys.argv[1]).read()))["claudeAiOauth"]; print(sorted(b.keys()), b["scopes"], b.get("refreshToken","<none>"))' "$D/kc/items/$SVC" 2>/dev/null)"
  [ "$blob" = "['accessToken', 'expiresAt', 'scopes', 'subscriptionType'] ['user:inference'] <none>" ] && ok "B1d item blob is inference-only: no refresh token" || bad "B1d blob shape: $blob"
  leak=""
  for t in "$TOKEN_a" "$TOKEN_b" "$TOKEN_c"; do
    grep -rqF "$t" "$D/kc/argv.log" "$D/city/.gc/logs" "$STATE" "$D/out.txt" 2>/dev/null && leak="$leak $(fp_of "$t")"
  done
  [ -z "$leak" ] && ok "B2 no token in security's argv, the daemon log, the state file or its output" || bad "B2 token leaked (fingerprints:$leak)"
  grep -rq "sk-ant-" "$D/city/.gc/logs" "$STATE" "$D/out.txt" 2>/dev/null && bad "B2b a token-shaped string reached log/state/output" || ok "B2b nothing token-shaped in log/state/output"
fi

  # ---- helpers for the scenarios below
  jex() { "$PY3" -c 'import json,sys; e=json.load(open(sys.argv[1])).get("exhausted",{}).get(sys.argv[2],{}); v=e.get(sys.argv[3]); print("" if v is None else v)' "$STATE" "$1" "$2" 2>/dev/null; }
  probes_of() { grep -cxF "$(tok_of "$1")" "$D/probes.log" 2>/dev/null || true; }
  edit_state() { "$PY3" - "$STATE" "$1" <<'EOF'
import json, sys
p, code = sys.argv[1:3]
st = json.load(open(p)); exec(code); json.dump(st, open(p, "w"))
EOF
  }
  seeded() { new_d; run_d -- run-once; }   # world where a is the seeded account

  # B1e: seed skips an account that is already rejected
  new_d; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_b" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B1e seed skips a rejected first account (a) and takes b" || bad "B1e seed picked '$(jget "$STATE" current)'"

  # B3 failover when the active account is rejected
  seeded; w0=$(writes); set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_b" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jget "$STATE" fingerprint)" = "$(fp_of "$TOKEN_b")" ] \
    && ok "B3 active account rejected -> pool item and decision move to the next account (b)" || bad "B3 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"
  [ "$(jex a@t.test reset_epoch)" = "2000000000.0" ] || [ "$(jex a@t.test reset_epoch)" = "2000000000" ] \
    && ok "B3b the rejection's reset time (7d-reset header) is stored" || bad "B3b exhausted[a].reset_epoch='$(jex a@t.test reset_epoch)'"
  [ "$(jex a@t.test claim)" = "seven_day" ] && ok "B3c the representative claim is stored" || bad "B3c claim='$(jex a@t.test claim)'"
  [ "$(writes)" = "$((w0 + 1))" ] && ok "B3d exactly one item write for the switch" || bad "B3d writes $w0 -> $(writes)"
  leak=""; for t in "$TOKEN_a" "$TOKEN_b" "$TOKEN_c"; do grep -rqF "$t" "$D/kc/argv.log" "$D/city/.gc/logs" "$STATE" "$D/out.txt" 2>/dev/null && leak="$leak $(fp_of "$t")"; done
  [ -z "$leak" ] && ok "B3e no token in argv/log/state/output after a FAILOVER run either" || bad "B3e token leaked on the failover path (fingerprints:$leak)"

  # B4 failover skips a rejected candidate
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; set_srv b@t.test 429 "$(hdr_rejected five_hour 1999500000)"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_c" ] && [ "$(jget "$STATE" current)" = "c@t.test" ] && ok "B4 the next account is probed BEFORE the item moves: rejected b is skipped, c wins" || bad "B4 current='$(jget "$STATE" current)'"
  [ -n "$(jex b@t.test reset_epoch)" ] && ok "B4b the skipped candidate's rejection is recorded too" || bad "B4b b not recorded as exhausted"

  # B5 everything rejected: stay put, do not write
  seeded; w0=$(writes)
  for e in a@t.test b@t.test c@t.test; do set_srv "$e" 429 "$(hdr_rejected seven_day 2000000000)"; done; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] \
    && ok "B5 all accounts rejected -> stays where it is, no item write" || bad "B5 current='$(jget "$STATE" current)' writes $w0 -> $(writes)"

  # B6 'could not tell' changes nothing (error != exhausted)
  seeded; w0=$(writes); set_srv a@t.test 500 '{}'; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex a@t.test reset_epoch)" ] && ok "B6 HTTP 500 on the active probe -> no switch, not marked exhausted" || bad "B6 current='$(jget "$STATE" current)' writes $w0 -> $(writes)"
  seeded; w0=$(writes); kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex a@t.test reset_epoch)" ] && ok "B6b network down -> no switch, not marked exhausted" || bad "B6b current='$(jget "$STATE" current)'"

  # B7 failback at the stored reset time, WITHOUT probing the recovered account
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once      # now on b, a exhausted until 2000000000
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B7a precondition: the failover to b really happened (else B7 would pass vacuously)" || bad "B7a precondition failed: current='$(jget "$STATE" current)'"
  pa0=$(probes_of a@t.test); NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B7 stored reset time passed and a outranks b -> back on a" || bad "B7 current='$(jget "$STATE" current)'"
  [ "$(probes_of a@t.test)" = "$pa0" ] && ok "B7b no balance/confirmation probe of the recovered account" || bad "B7b a was probed on the way back ($pa0 -> $(probes_of a@t.test))"
  [ -z "$(jex a@t.test reset_epoch)" ] && ok "B7c the recovered account leaves the exhausted registry" || bad "B7c a still registered as exhausted"
  leak=""; for t in "$TOKEN_a" "$TOKEN_b" "$TOKEN_c"; do grep -rqF "$t" "$D/kc/argv.log" "$D/city/.gc/logs" "$STATE" "$D/out.txt" 2>/dev/null && leak="$leak $(fp_of "$t")"; done
  [ -z "$leak" ] && ok "B7d no token in argv/log/state/output after a FAILBACK run either" || bad "B7d token leaked on the failback path (fingerprints:$leak)"

  # B8 not yet
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; NOW_OVERRIDE=1999999000 run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B8 before the stored reset time the pool stays on b" || bad "B8 current='$(jget "$STATE" current)'"

  # B9 it had not really renewed: the 429 refaz o failover (no loop inside one run)
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] || bad "B9 precondition: failover to b did not happen"
  NOW_OVERRIDE=2000000100 run_d -- run-once                                                    # failback to a (no probe)
  [ "$(jget "$STATE" current)" = "a@t.test" ] || bad "B9 precondition: failback to a did not happen"
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000090000)"; NOW_OVERRIDE=2000000200 run_d -- run-once   # a still rejected
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test reset_epoch)" = "2000090000.0" -o "$(jex a@t.test reset_epoch)" = "2000090000" ] \
    && ok "B9 failed failback -> a's 429 triggers the failover again and the new reset time is stored" || bad "B9 current='$(jget "$STATE" current)' reset='$(jex a@t.test reset_epoch)'"
  NOW_OVERRIDE=2000000300 run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B9b and it does not bounce back on the next run" || bad "B9b current='$(jget "$STATE" current)'"

  # B9c a rejection whose reset header is already in the past gets a cooldown, never an instant failback
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 1000)"; NOW_OVERRIDE=2000000000 run_d -- run-once
  r="$(jex a@t.test reset_epoch)"; "$PY3" -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 2000000000 else 1)' "${r:-0}" \
    && ok "B9c stale reset header (past) -> cooldown from now, not an instant failback" || bad "B9c reset_epoch=$r"

  # B10 a recovered account that does NOT outrank the active one is not a reason to move
  seeded; w0=$(writes); edit_state 'st["exhausted"]={"c@t.test":{"reset_epoch":2000000000.0,"claim":"seven_day"}}'; pc0=$(probes_of c@t.test)
  NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex c@t.test reset_epoch)" ] && [ "$(probes_of c@t.test)" = "$pc0" ] \
    && ok "B10 recovered c ranks below the active a -> stay, entry dropped, no probe of c" || bad "B10 current='$(jget "$STATE" current)' c-entry='$(jex c@t.test reset_epoch)'"

  # B11 nothing usable in the vault -> inert
  new_d; rm -f "$D/vault"/*; run_d -- run-once
  [ ! -e "$D/kc/items/$SVC" ] && [ ! -e "$STATE" ] && [ ! -s "$D/probes.log" ] && ok "B11 no key in the vault -> no item, no state, no probe (inert)" || bad "B11 something was created/probed"

  # B12 kill switch
  new_d; touch "$D/city/.gc/no-pool-account"; run_d -- run-once
  [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/probes.log" ] && ok "B12 .gc/no-pool-account -> the run does nothing" || bad "B12 kill switch ignored"
  new_d; run_d GC_POOL_ACCOUNT=0 -- run-once
  [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/probes.log" ] && ok "B12b GC_POOL_ACCOUNT=0 -> the run does nothing" || bad "B12b env kill switch ignored"

  # B13 single instance
  new_d; "$PY3" - "$D/city/.gc/claude-pool-account.lock" <<'EOF' &
import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(8)
EOF
  HOLD=$!; sleep 1; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ ! -s "$D/probes.log" ] && [ ! -e "$D/kc/items/$SVC" ] && grep -q "holds the lock" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B13 a second run while the lock is held exits 0 without probing or writing" || bad "B13 lock not respected (rc=$rc)"
  kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null

  # B14 the item drifted (someone wrote another account) / vanished: the single writer heals it
  seeded; "$PY3" - "$D/kc/items/$SVC" "$TOKEN_b" <<'EOF'
import json, sys
b = {"claudeAiOauth": {"accessToken": sys.argv[2], "expiresAt": 4102444800000, "scopes": ["user:inference"], "subscriptionType": None}}
open(sys.argv[1], "w").write(json.dumps(b).encode().hex())
EOF
  w0=$(writes); run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$((w0 + 1))" ] && ok "B14 item holds another account than the decision -> rewritten to the decision" || bad "B14 item=$(item_token | cut -c1-24) writes $w0 -> $(writes)"
  seeded; rm -f "$D/kc/items/$SVC"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && ok "B14b item deleted -> recreated for the decision" || bad "B14b item=$(item_token | cut -c1-24)"

  # B15 steady state is quiet: no rewrite, 'since' does not move
  seeded; s0="$(jget "$STATE" since)"; w0=$(writes); run_d -- run-once; run_d -- run-once
  [ "$(writes)" = "$w0" ] && [ "$(jget "$STATE" since)" = "$s0" ] && ok "B15 steady state: no item write, 'since' unchanged" || bad "B15 writes $w0 -> $(writes), since $s0 -> $(jget "$STATE" since)"

  # B16 account order unreadable -> inert (never invents an order)
  seeded; w0=$(writes); echo 'not json' > "$D/usage.json"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B16 usage store unreadable -> nothing changes" || bad "B16 current='$(jget "$STATE" current)'"

  # B17 a refused key (401) fails over, with a cooldown instead of a reset time
  seeded; set_srv a@t.test 401 '{}'; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] && ok "B17 revoked key (401) on the active account -> failover with a cooldown" || bad "B17 current='$(jget "$STATE" current)'"

  # B19 a locked keychain is 'could not tell', never 'missing': no rewrite
  seeded; rm -f "$D/kc/items/$SVC"; touch "$D/kc/locked"; w0=$(writes); run_d -- run-once
  [ "$(writes)" = "$w0" ] && grep -q "unreadable" "$D/city/.gc/logs/claude-pool-account.log" && ok "B19 keychain locked (exit 36) -> item NOT rewritten, reported as unreadable" || bad "B19 writes $w0 -> $(writes)"
  rm -f "$D/kc/locked"

  # B20 the read-back after a successful write 'could not tell' (keychain locked) -> the switch still stands
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; touch "$D/kc/locked"; run_d -- run-once; rm -f "$D/kc/locked"
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && grep -q "unverified" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B20 write ok + read-back unreadable -> decision follows the item (b), reported as unverified" || bad "B20 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"

  # B21 no usable city path -> no lock can be taken -> the run refuses to act (never runs unlocked). Exit 1, not 0:
  # 'refused because misconfigured' must not look like 'ran and had nothing to do'.
  new_d; run_d GC_CITY_PATH= -- run-once; rc=$?
  [ "$rc" = "1" ] && [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/probes.log" ] && grep -q "lock" "$D/out.txt" \
    && ok "B21 no city path -> inert (no probe, no item), exit 1, says why" || bad "B21 ran without a lock (rc=$rc): $(head -c 200 "$D/out.txt")"
  new_d; rm -rf "$D/city/.gc"; run_d -- run-once; rc=$?
  [ "$rc" = "1" ] && [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/probes.log" ] && ok "B21b city path without a .gc dir -> same refusal" || bad "B21b ran without a lock (rc=$rc)"
  new_d; mkdir -p "$D/city/.gc/claude-pool-account.lock"; run_d -- run-once; rc=$?   # lock path is a directory: open() fails, which is NOT 'someone else holds it'
  [ "$rc" = "1" ] && [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/probes.log" ] && ! grep -q "holds the lock" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B21c a lock file that cannot be opened is an error (exit 1), not contention" || bad "B21c rc=$rc: $(cat "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null | head -c 200)"

  # B22 a malformed exhausted entry is not 'recovered': no failback on a reset time nobody stored
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once        # on b, a exhausted
  edit_state 'st["exhausted"]["a@t.test"].pop("reset_epoch", None)'; pa0=$(probes_of a@t.test); run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(probes_of a@t.test)" = "$pa0" ] && [ -z "$(jex a@t.test why)" ] \
    && ok "B22 exhausted entry without reset_epoch -> dropped, NOT a failback to a" || bad "B22 current='$(jget "$STATE" current)'"
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  edit_state 'st["exhausted"]["a@t.test"]["reset_epoch"] = "soon"'; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "" ] && ok "B22b a non-numeric reset_epoch is dropped too (handled, not a crash)" || bad "B22b current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)'"
  grep -q "unhandled" "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null && bad "B22b the daemon crashed on it instead of handling it"
  seeded; edit_state 'st["exhausted"]=["a@t.test"]'; w0=$(writes); run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && ok "B22c an 'exhausted' that is not an object -> dropped, run carries on, no rewrite" || bad "B22c rc=$rc current='$(jget "$STATE" current)'"
  seeded; edit_state 'st["current"]=["a@t.test"]'; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B22d a garbled 'current' is not an account -> chosen again from the order" || bad "B22d rc=$rc current='$(jget "$STATE" current)'"

  # B22e/f 'present but null' (and every other wrong shape) in the registry is NOT 'absent'. Gate 1/3: {"exhausted": null} slipped
  # past the sanitizer (`.get() is None -> return` cannot tell an absent key from a null) and then every consumer crashed on it,
  # so the pool stayed on a REJECTED account, run after run. Each shape runs twice: steady (a answers) and failing over (a rejected).
  state_ok() { "$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if isinstance(d.get("exhausted", {}), dict) else 1)' "$STATE" 2>/dev/null; }
  no_crash() { ! grep -q "unhandled" "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null; }
  for shape in 'None' '[]' '"x"' '5' 'True' '{"a@t.test": None}' '{"a@t.test": []}' '{"a@t.test": {"reset_epoch": None}}' \
               '{"a@t.test": {"reset_epoch": True}}' '{"a@t.test": {"reset_epoch": float("nan")}}' '{"a@t.test": {"reset_epoch": float("inf")}}'; do
    seeded; edit_state "st[\"exhausted\"]=$shape"; w0=$(writes); run_d -- run-once; rc=$?
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && state_ok && no_crash \
      && ok "B22e exhausted=$shape, a answers -> handled: exit 0, stays on a, registry left well-formed" \
      || bad "B22e exhausted=$shape steady: rc=$rc current='$(jget "$STATE" current)' $(tail -c 200 "$D/city/.gc/logs/claude-pool-account.log")"
    seeded; edit_state "st[\"exhausted\"]=$shape"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; rc=$?
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && state_ok && no_crash \
      && ok "B22f exhausted=$shape, a rejected -> still fails over to b" \
      || bad "B22f exhausted=$shape failover: rc=$rc current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) $(tail -c 200 "$D/city/.gc/logs/claude-pool-account.log")"
  done
  seeded; edit_state 'st["current"]=None'; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && no_crash && ok "B22e2 current=null -> not an account, chosen again" || bad "B22e2 rc=$rc current='$(jget "$STATE" current)'"

  # B22g a reset_epoch that is a finite number but not an epoch (0, negative, centuries away) is garbled like any other: dropped.
  # Never read as 'already reset' (0 / -5 would fire an UNPROBED failback) nor as 'exhausted for ever' (1e30).
  # (10**400 is a JSON integer too big for a float: math.isfinite() raises OverflowError on it.)
  # 4000000000 (year 2096) and the clock-of-the-reading-run + 40 days are INSIDE 2001..2100 and pass for epochs: only the bound relative
  # to NOW (a stored reset is believed up to 31 days ahead) drops them. Without it the account is vetoed - unprobed - for decades.
  for junk in 0 -5 1e30 '10**400' 4000000000 '2000000100 + 40*86400'; do
    seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once          # on b, a exhausted
    edit_state "st[\"exhausted\"][\"a@t.test\"][\"reset_epoch\"]=$junk"; pa0=$(probes_of a@t.test); w0=$(writes); NOW_OVERRIDE=2000000100 run_d -- run-once
    [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(probes_of a@t.test)" = "$pa0" ] && [ -z "$(jex a@t.test why)" ] \
      && ok "B22g reset_epoch=$junk -> dropped: no unprobed failback, no for-ever exclusion" \
      || bad "B22g reset_epoch=$junk: current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)' writes $w0 -> $(writes)"
  done

  # B23 a USER that is not a plain account name never reaches a security command line (exit 1: misconfigured, not 'idle')
  for hostile in 'ath"os' $'athos\nadd-generic-password -a x' 'a b' '-x' 'athos\'; do
    new_d; run_d "USER=$hostile" -- run-once; rc=$?
    [ "$rc" = "1" ] && [ ! -e "$D/kc/items/$SVC" ] && [ ! -s "$D/kc/argv.log" ] && ok "B23 hostile USER $(printf '%q' "$hostile") -> nothing written, security never called, exit 1" || bad "B23 USER=$(printf '%q' "$hostile") rc=$rc argv=$(cat "$D/kc/argv.log" 2>/dev/null | head -c 120)"
  done

  # B27 no USER in the environment (launchd gives none unless the plist sets it): the login name comes from the passwd
  # database. os.getlogin() needs a controlling tty and raises without one — that used to crash the run.
  new_d; run_d USER= -- run-once < /dev/null; rc=$?
  [ "$rc" = "0" ] && [ "$(item_token)" = "$TOKEN_a" ] && ok "B27 USER unset -> pool item seeded (smoke: a tty-less run still gets a login name)" || bad "B27 rc=$rc item=$(item_token | cut -c1-24): $(head -c 200 "$D/out.txt")"
  # B27b the same, DETERMINISTIC: getlogin(3) works or not depending on the session that runs this test, so make it
  # fail the way it does under launchd (OSError) and require the passwd-database answer.
  got="$(env -i USER= GC_CITY_PATH="$D/city" "$PY3" -c '
import importlib.util, os, pwd, sys
def no_tty(): raise OSError(25, "Inappropriate ioctl for device")
os.getlogin = no_tty
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
n = m.login_name()
print("OK" if n and n == pwd.getpwuid(os.getuid()).pw_name and m.valid_user(n) else "BAD:" + repr(n))' "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B27b getlogin() raising (no tty, as under launchd) -> login name still comes from the passwd database" || bad "B27b login_name() -> $got"

  # B25 a state file that exists but cannot be READ: acting would overwrite a decision we cannot see -> refuse (exit 1)
  seeded; w0=$(writes); rm -f "$STATE"; mkdir "$STATE"; run_d -- run-once; rc=$?
  [ "$rc" = "1" ] && [ "$(writes)" = "$w0" ] && [ -d "$STATE" ] && ok "B25 unreadable state -> exit 1, no item write, nothing overwritten" || bad "B25 rc=$rc writes $w0 -> $(writes)"
  rmdir "$STATE" 2>/dev/null

  # B26 a state file that is not a JSON object is moved aside (evidence kept), then the daemon starts from empty
  seeded; echo 'not json {' > "$STATE"; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -n "$(ls "$D"/current.json.corrupt.* 2>/dev/null)" ] \
    && ok "B26 corrupt state -> moved to current.json.corrupt.*, decision re-seeded" || bad "B26 rc=$rc current='$(jget "$STATE" current)' aside='$(ls "$D" | tr '\n' ' ')'"

  # B28 a failback whose Keychain write is REFUSED is not a failback that happened: the pool stays on b, a stays in the
  # exhausted registry, and the next run (write allowed again) completes the failback. Dropping a from the registry on a
  # failed write would lose the failback for good - the pool would sit on the later-renewing account until b is rejected.
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once        # now on b, a exhausted until 2000000000
  [ "$(jget "$STATE" current)" = "b@t.test" ] || bad "B28 precondition: failover to b did not happen"
  set_srv a@t.test 200 "$HDR_OK"; touch "$D/kc/refuse-writes"; w0=$(writes)
  NOW_OVERRIDE=2000000100 run_d -- run-once; rc=$?
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$w0" ] \
    && ok "B28a refused write -> the pool stays on b (decision and item unchanged)" || bad "B28a rc=$rc current='$(jget "$STATE" current)' writes $w0 -> $(writes)"
  [ -n "$(jex a@t.test reset_epoch)" ] && ok "B28b ...and a is still registered as exhausted, so the failback is retried" || bad "B28b a was dropped from the registry although the failback did not happen"
  rm -f "$D/kc/refuse-writes"; NOW_OVERRIDE=2000000200 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] \
    && ok "B28c next run, write allowed -> the failback to a completes" || bad "B28c current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"

  # B29 a state file whose BYTES are not readable as text, or whose JSON nests deeper than the parser can follow, is corrupt like
  # any other garbage: moved aside, decision re-seeded, exit 0. (read_text() raising UnicodeDecodeError, or json.loads raising
  # RecursionError, used to escape every handler: the run crashed, run after run, and the garbage was never moved.)
  seeded; printf '\xff\xfe\x00{"current": "b@t.test"}\x80' > "$STATE"; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -n "$(ls "$D"/current.json.corrupt.* 2>/dev/null)" ] && no_crash \
    && ok "B29 non-UTF-8 state -> moved aside, decision re-seeded, exit 0" || bad "B29 rc=$rc current='$(jget "$STATE" current)' log: $(tail -c 160 "$D/city/.gc/logs/claude-pool-account.log")"
  seeded; "$PY3" -c 'import sys; sys.stdout.write("[" * 300000)' > "$STATE"; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -n "$(ls "$D"/current.json.corrupt.* 2>/dev/null)" ] && no_crash \
    && ok "B29b absurdly nested state -> moved aside, decision re-seeded, exit 0" || bad "B29b rc=$rc current='$(jget "$STATE" current)' log: $(tail -c 160 "$D/city/.gc/logs/claude-pool-account.log")"

  # B30 a CLAUDE_POOL_NOW that is a number but not a time (nan, inf) is not a clock: the real one is used. float('nan') parses, so
  # the old now() handed NaN to every comparison (all False -> 'not reset', 'not expired') and to fromtimestamp() (crash).
  for junk in nan inf -inf NaN 1e999; do
    seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d "CLAUDE_POOL_NOW=$junk" -- run-once; rc=$?
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && no_crash \
      && "$PY3" -c 'import sys,time; sys.exit(0 if abs(float(sys.argv[1]) - time.time()) < 300 else 1)' "$(jex a@t.test seen)" 2>/dev/null \
      && ok "B30 CLAUDE_POOL_NOW=$junk -> ignored (real clock), the run completes and fails over" \
      || bad "B30 CLAUDE_POOL_NOW=$junk rc=$rc current='$(jget "$STATE" current)' seen='$(jex a@t.test seen)'"
  done

  # B31 a reset header that is not a usable epoch (non-finite, absurd, far past/future) must not become the stored reset time.
  # NaN is TRUTHY, 'nan' <= now is False and datetime.fromtimestamp(nan) raises: the old code crashed in the very run that had
  # to fail over, and a huge one is 'exhausted for ever'. The stored time is an epoch in a sane range, else the cooldown.
  # 4000000000 (year 2096) and now+40d are valid epochs INSIDE 2001..2100 and still not believable: a reset header is usable only if
  # now < reset <= now + 31 days. They end where an unusable header always ends: the retry-after the 429 carries (600 s).
  R40=$(( $(date +%s) + 40 * 86400 ))
  for r in nan inf -inf 1e999 9e15 0 -5 9999-12-31T23:59:59Z 0001-01-01T00:00:00Z 4000000000 "$R40"; do
    seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day "$r")"; NOW_OVERRIDE= run_d -- run-once; rc=$?
    stored="$(jex a@t.test reset_epoch)"
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && no_crash \
      && "$PY3" -c 'import math,sys,time; v=float(sys.argv[1]); n=time.time(); sys.exit(0 if math.isfinite(v) and n < v < n + 86400 * 14 else 1)' "$stored" 2>/dev/null \
      && ok "B31 7d-reset='$r' -> failover done, stored reset is a finite near-future epoch (the cooldown)" \
      || bad "B31 7d-reset='$r' rc=$rc current='$(jget "$STATE" current)' stored='$stored' $(tail -c 160 "$D/city/.gc/logs/claude-pool-account.log")"
  done
  # ...and the same through the retry-after fallback path (no *-reset header at all)
  for r in nan inf 1e999 -5; do
    seeded; set_srv a@t.test 429 "{\"anthropic-ratelimit-unified-status\":\"rejected\",\"retry-after\":\"$r\"}"; NOW_OVERRIDE= run_d -- run-once; rc=$?
    stored="$(jex a@t.test reset_epoch)"
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && no_crash \
      && "$PY3" -c 'import math,sys,time; v=float(sys.argv[1]); n=time.time(); sys.exit(0 if math.isfinite(v) and n < v < n + 86400 else 1)' "$stored" 2>/dev/null \
      && ok "B31b retry-after='$r' -> failover done, stored reset is the cooldown" \
      || bad "B31b retry-after='$r' rc=$rc current='$(jget "$STATE" current)' stored='$stored'"
  done

  # B32 an account whose KEY was refused (401/403) is not failed back to on its timer: the failback does not probe, so it would put a
  # key that is STILL refused into the item and break every pool session until the next run - once an hour, for as long as the key
  # stays bad. It is probed again the normal way (pick_next, on a later failover).
  seeded; set_srv a@t.test 401 '{}'; run_d -- run-once                                   # a's key refused -> on b, a registered 'invalid'
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "invalid" ] || bad "B32 precondition: failover to b / a registered invalid (why='$(jex a@t.test why)')"
  w0=$(writes); NOW_OVERRIDE=2000000000 run_d -- run-once                                 # an hour later; a still refused
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$w0" ] \
    && ok "B32 invalid key past its cooldown -> NO unprobed failback (stays on b, item untouched)" \
    || bad "B32 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) writes $w0 -> $(writes)"
  set_srv b@t.test 429 "$(hdr_rejected five_hour 2000003600)"; set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B32b ...and once its key works again it is used the normal way: probed on the next failover (b rejected -> a)" \
    || bad "B32b current='$(jget "$STATE" current)'"

  # B33 what the active account just ANSWERED beats what was stored about it: if it is in the exhausted registry (all accounts had
  # been rejected, the pool stayed put, then it renewed) the entry is cleared now, not left to veto it in a later failover.
  seeded; for e in a b c; do set_srv "$e@t.test" 429 "$(hdr_rejected seven_day 2000000000)"; done; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] || bad "B33 precondition: all rejected -> stay on a, a registered"
  set_srv a@t.test 200 "$HDR_OK"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -z "$(jex a@t.test reset_epoch)" ] && [ -n "$(jex b@t.test reset_epoch)" ] \
    && ok "B33 the active account answers again -> its stale exhausted entry is cleared (the others are kept)" \
    || bad "B33 current='$(jget "$STATE" current)' a-entry='$(jex a@t.test reset_epoch)' b-entry='$(jex b@t.test reset_epoch)'"

  # ── B36..B43 (gate ga-qmdwdi): the vault is a WITNESS, not the truth; the reset bound; no redirect; lazy vault reads ─────────────
  hide_key() { rm -f "$D/vault/$1"; }
  show_key() { printf '%s' "$(tok_of "$1")" > "$D/vault/$1"; }
  vault_calls() { [ -f "$D/vault/.calls" ] && wc -l < "$D/vault/.calls" | tr -d ' ' || echo 0; }
  nlog() { local c; c="$(grep -c -- "$1" "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null)"; echo "${c:-0}"; }
  KEYMISS="its key did not come from the vault this run"
  item_set() { "$PY3" - "$D/kc/items/$SVC" "$1" <<'EOF'
import json, sys
b = {"claudeAiOauth": {"accessToken": sys.argv[2], "expiresAt": 4102444800000, "scopes": ["user:inference"], "subscriptionType": None}}
open(sys.argv[1], "w").write(json.dumps(b).encode().hex())
EOF
  }

  # B36 the vault gave no key for the CURRENT account, and for it alone (b and c readable), for ONE run. `token_da_conta` returns
  # None both for 'no key registered' and for 'vault unreadable just now', so that is not 'its key is gone': the item the daemon
  # wrote still holds the decision's credential (fingerprint = the state's), and the daemon keeps the decision and probes THAT.
  # (The old decide() re-seeded on b, and a - never registered as exhausted - was never failed back to.)
  seeded; s0="$(jget "$STATE" since)"; fp0="$(jget "$STATE" fingerprint)"; w0=$(writes); pa0=$(probes_of a@t.test)
  hide_key a@t.test; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(jget "$STATE" since)" = "$s0" ] \
    && [ "$(jget "$STATE" fingerprint)" = "$fp0" ] && [ "$(writes)" = "$w0" ] \
    && ok "B36 only the current account's key missing from the vault for 1 run -> item, decision and 'since' unchanged, no write" \
    || bad "B36 rc=$rc current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) since $s0 -> $(jget "$STATE" since) writes $w0 -> $(writes)"
  [ "$(nlog "$KEYMISS")" = "1" ] && ! grep -qE "choosing again|no usable key any more" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B36b ...with exactly one counted WARN that says only what is known (the key did not come from the vault this run)" \
    || bad "B36b WARN count=$(nlog "$KEYMISS"): $(tail -n 3 "$D/city/.gc/logs/claude-pool-account.log" | cut -c1-200)"
  [ "$(probes_of a@t.test)" = "$((pa0 + 1))" ] && ok "B36c ...and the probe went to the credential the ITEM holds (a), the only copy of the key left" || bad "B36c probes of a: $pa0 -> $(probes_of a@t.test)"
  hide_key a@t.test; run_d -- run-once; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(jget "$STATE" since)" = "$s0" ] && [ "$(nlog "$KEYMISS")" = "3" ] && [ "$(writes)" = "$w0" ] \
    && ok "B36d hidden for 3 runs in a row -> still a, one counted WARN per run (3), nothing written" || bad "B36d current='$(jget "$STATE" current)' warns=$(nlog "$KEYMISS") writes $w0 -> $(writes)"
  show_key a@t.test; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(nlog "$KEYMISS")" = "3" ] && [ -z "$(jex a@t.test why)" ] \
    && ok "B36e key back -> the pool never left a: no further WARN, a not registered as exhausted" || bad "B36e current='$(jget "$STATE" current)' warns=$(nlog "$KEYMISS")"

  # B37 the witness is probed like any active account: rejected / refused -> the normal failover (and a IS registered, which the old
  # re-seed never did); could not tell -> nothing.
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; hide_key a@t.test; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(jex a@t.test why)" = "rejected" ] \
    && ok "B37 key hidden + the item's credential REJECTED -> normal failover to b, and a is registered as exhausted" \
    || bad "B37 rc=$rc current='$(jget "$STATE" current)' a-why='$(jex a@t.test why)'"
  seeded; set_srv a@t.test 401 '{}'; hide_key a@t.test; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "invalid" ] \
    && ok "B37b key hidden + the item's credential REFUSED (401) -> failover to b, a registered invalid" || bad "B37b current='$(jget "$STATE" current)' a-why='$(jex a@t.test why)'"
  seeded; w0=$(writes); set_srv a@t.test 500 '{}'; hide_key a@t.test; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex a@t.test why)" ] \
    && ok "B37c key hidden + the probe could not tell (500) -> nothing changes" || bad "B37c current='$(jget "$STATE" current)' writes $w0 -> $(writes)"

  # B38 ...and when nothing corroborates the decision the pool IS chosen again: item deleted / holding another credential / no
  # fingerprint in the state to compare. (These end in the same place as the old code did; the counted WARN is what tells them
  # apart from it. B38d is the one that is not a re-seed: item unreadable = could not tell = inert.)
  seeded; hide_key a@t.test; rm -f "$D/kc/items/$SVC"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(nlog "$KEYMISS")" = "1" ] && grep -q "nothing corroborates" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B38 key hidden + item DELETED -> chosen again (b), the WARN says nothing corroborates the decision" || bad "B38 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) warns=$(nlog "$KEYMISS")"
  seeded; hide_key a@t.test; item_set "$TOKEN_c"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(nlog "$KEYMISS")" = "1" ] && grep -q "nothing corroborates" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B38b key hidden + item holds ANOTHER credential (fingerprint differs) -> chosen again (b)" || bad "B38b current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) warns=$(nlog "$KEYMISS")"
  seeded; hide_key a@t.test; edit_state 'st.pop("fingerprint")'; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(nlog "$KEYMISS")" = "1" ] && ok "B38c key hidden + the state has no fingerprint to compare -> chosen again (b)" || bad "B38c current='$(jget "$STATE" current)' warns=$(nlog "$KEYMISS")"
  seeded; w0=$(writes); hide_key a@t.test; touch "$D/kc/locked"; run_d -- run-once; rm -f "$D/kc/locked"
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(nlog "$KEYMISS")" = "1" ] && grep -q "left as it is" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B38d key hidden + the item cannot be read (locked) -> could not tell: decision and item left as they are" || bad "B38d current='$(jget "$STATE" current)' writes $w0 -> $(writes)"

  # B39 the whole vault unreadable (exit 1, not 'Not found') while the item corroborates: the pool keeps working on what it has, and a
  # rejection of the active account is still seen (the old run stopped at 'no account with a usable key', blind to it).
  seeded; w0=$(writes); touch "$D/vault/.broken"; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] \
    && ok "B39 vault down, a answers -> stays on a, nothing written" || bad "B39 rc=$rc current='$(jget "$STATE" current)' writes $w0 -> $(writes)"
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ "$(jex a@t.test why)" = "rejected" ] \
    && ok "B39b vault down, a REJECTED -> the rejection is recorded; no candidate has a key, so the item is not touched" || bad "B39b current='$(jget "$STATE" current)' a-why='$(jex a@t.test why)' writes $w0 -> $(writes)"
  rm -f "$D/vault/.broken"

  # B40 the account is missing from the ORDER this run (the usage store lacks its entry) - the same 'lookup found nothing' shape, from
  # another source. It is ranked last, not dropped: it still answers, so the pool stays on it (the old code re-seeded onto b).
  seeded; w0=$(writes)
  "$PY3" - "$D/usage.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["accounts"] = [a for a in d["accounts"] if a["email"] != "a@t.test"]; json.dump(d, open(sys.argv[1], "w"))
EOF
  run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && grep -q "not in the order of use this run" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B40 current account absent from the order of use -> kept (ranked last), not re-seeded" || bad "B40 current='$(jget "$STATE" current)' writes $w0 -> $(writes)"

  # B41 a key ROTATED in the vault: the item is rewritten to it (heal) and the decision's fingerprint follows - otherwise the next vault
  # miss would find an item that 'does not corroborate' the decision and re-seed.
  TOKEN_a2="sk-ant-oat01-TESTrotatedrotatedrotated00"
  seeded; set_srv_in "$D/srv.json" "$TOKEN_a2" 200 "$HDR_OK"; printf '%s' "$TOKEN_a2" > "$D/vault/a@t.test"; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a2" ] && [ "$(jget "$STATE" fingerprint)" = "$(fp_of "$TOKEN_a2")" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] \
    && ok "B41 vault key for the current account rotated -> item rewritten AND the decision's fingerprint follows it" || bad "B41 item=$(item_token | cut -c1-24) fp='$(jget "$STATE" fingerprint)'"
  s0="$(jget "$STATE" since)"; hide_key a@t.test; run_d -- run-once
  [ "$(item_token)" = "$TOKEN_a2" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(jget "$STATE" since)" = "$s0" ] \
    && ok "B41b ...so a vault miss right after still finds the item corroborating the decision" || bad "B41b current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"

  # B42 the vault is read for the CURRENT account every run and for candidates only when the pool has to move - not for every account.
  seeded; v0=$(vault_calls); run_d -- run-once
  [ "$(( $(vault_calls) - v0 ))" = "1" ] && ok "B42 steady run -> 1 vault read (the current account), not one per account" || bad "B42 vault reads in a steady run: $(( $(vault_calls) - v0 ))"
  new_d; v0=$(vault_calls); run_d -- run-once
  [ "$(( $(vault_calls) - v0 ))" = "1" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B42b seed -> reads only until the first account that answers (1)" || bad "B42b seed vault reads: $(( $(vault_calls) - v0 ))"
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; v0=$(vault_calls); run_d -- run-once
  [ "$(( $(vault_calls) - v0 ))" = "2" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B42c failover -> the current account + the candidate that answered (2), c never read" || bad "B42c failover vault reads: $(( $(vault_calls) - v0 ))"
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; set_srv a@t.test 200 "$HDR_OK"; v0=$(vault_calls); NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(( $(vault_calls) - v0 ))" = "2" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B42d failback -> the current account + the account failed back to (2), c never read" || bad "B42d failback vault reads: $(( $(vault_calls) - v0 )) current='$(jget "$STATE" current)'"
  # a recovered account whose key does not come back is KEPT (not judged), so a later run with its key still fails back to it
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; hide_key a@t.test; NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] && grep -q "failback to a@t.test not done: its key did not come from the vault" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B42e failback target's key not returned -> no failback, the entry is kept (not judged)" || bad "B42e current='$(jget "$STATE" current)' a-entry='$(jex a@t.test reset_epoch)'"
  show_key a@t.test; set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=2000000200 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B42f ...and the next run, key back, completes the failback" || bad "B42f current='$(jget "$STATE" current)'"

  # B43 the probe does not follow a redirect: urllib re-sends Authorization to wherever a 301/302/303 points (and turns the POST into a
  # GET). A second server stands for 'somewhere else'; its log must stay empty, and a redirect is 'could not tell' - it changes nothing.
  # (307 is a control: urllib refuses to redirect a POST on 307 by itself, so the old code did not leak there either.)
  start_srv2() { # answers 200 to every account; every Bearer it sees is logged to $D/probes2.log
    echo '{}' > "$D/srv2.json"; : > "$D/probes2.log"; rm -f "$D/port2"
    local e n=0; for e in "${EMAILS[@]}"; do set_srv_in "$D/srv2.json" "$(tok_of "$e")" 200 "$HDR_OK"; done
    "$PY3" "$W/mock_api.py" "$D/srv2.json" "$D/probes2.log" "$D/port2" & SRV2_PID=$!
    while [ ! -s "$D/port2" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  }
  stop_srv2() { kill "$SRV2_PID" 2>/dev/null; wait "$SRV2_PID" 2>/dev/null; }
  for code in 301 302 303 307; do
    seeded; start_srv2; w0=$(writes)
    set_srv a@t.test "$code" "{\"Location\":\"http://127.0.0.1:$(cat "$D/port2")/v1/messages\"}"; run_d -- run-once; rc=$?
    seen2="$(wc -l < "$D/probes2.log" | tr -d ' ')"; stop_srv2
    [ "$rc" = "0" ] && [ "$seen2" = "0" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex a@t.test why)" ] \
      && grep -q "redirect http=$code (not followed)" "$D/city/.gc/logs/claude-pool-account.log" \
      && ok "B43 active probe answered with a $code -> not followed (the other server saw no Bearer), 'could not tell', nothing changed" \
      || bad "B43 $code: rc=$rc other-server-saw=$seen2 current='$(jget "$STATE" current)' writes $w0 -> $(writes) a-why='$(jex a@t.test why)'"
  done
  new_d; start_srv2
  set_srv a@t.test 302 "{\"Location\":\"http://127.0.0.1:$(cat "$D/port2")/v1/messages\"}"; run_d -- run-once
  seen2="$(wc -l < "$D/probes2.log" | tr -d ' ')"; stop_srv2
  [ "$seen2" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] \
    && ok "B43b seed: a candidate that answers with a redirect is not a candidate -> b, and the other server saw nothing" \
    || bad "B43b other-server-saw=$seen2 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"

  # B44 the reset-time bound, table-driven on classify / register_exhausted / sanitize_state (clock t = 2000000000):
  # usable only if t < reset <= t + 31 days; anything else -> the 429's retry-after, then the 15-minute cooldown.
  got="$("$PY3" - "$DAEMON" <<'EOF' 2>&1
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
t = 2000000000.0; MAX = m.MAX_RETRY_AFTER_S; bad = []
def hdr(reset, ra=None):
    h = {"anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-7d-status": "rejected",
         "anthropic-ratelimit-unified-7d-reset": str(reset), "anthropic-ratelimit-unified-representative-claim": "seven_day"}
    if ra is not None: h["retry-after"] = str(ra)
    return h
cases = [("t+1", t + 1, True), ("t+7d", t + 7 * 86400, True), ("t+MAX (the edge)", t + MAX, True),
         ("t+MAX+1", t + MAX + 1, False), ("t+40d", t + 40 * 86400, False), ("4000000000 (2096)", 4000000000, False),
         ("t (not ahead)", t, False), ("t-1 (behind)", t - 1, False)]
for name, r, want in cases:
    try:
        want_ra = int(r) if want else t + 600                    # retry-after: 600 on the 429
        want_cd = int(r) if want else t + m.DEFAULT_COOLDOWN_S   # no retry-after at all
        got = m.classify(429, hdr(int(r), 600), t).reset_epoch
        if got != want_ra: bad.append(f"classify {name} + retry-after 600 -> {got} (want {want_ra})")
        got = m.classify(429, hdr(int(r)), t).reset_epoch
        if got != want_cd: bad.append(f"classify {name}, no retry-after -> {got} (want {want_cd})")
    except BaseException as e:
        bad.append(f"classify {name} raised {type(e).__name__}")
# the sink: a Probe that carries an out-of-bound time (any caller) is stored as the cooldown
for name, r, want in cases:
    st = {}; m.register_exhausted(st, "x@t.test", m.Probe("rejected", float(r), "seven_day", "http=429"), t)
    got = st["exhausted"]["x@t.test"]["reset_epoch"]; w = float(r) if want else t + m.DEFAULT_COOLDOWN_S
    if got != w: bad.append(f"register_exhausted {name} -> {got} (want {w})")
# sanitize_state: beyond t+MAX dropped; a time already behind t is KEPT (that is an account whose time has come)
st = {"exhausted": {"ok@t": {"reset_epoch": t + MAX}, "far@t": {"reset_epoch": t + MAX + 1}, "y2096@t": {"reset_epoch": 4000000000},
                    "past@t": {"reset_epoch": t - 5000}, "junk@t": {"reset_epoch": 0}}}
m.sanitize_state(st, t)
if sorted(st["exhausted"]) != ["ok@t", "past@t"]: bad.append(f"sanitize_state kept {sorted(st['exhausted'])} (want ['ok@t', 'past@t'])")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
)"
  [ "$got" = "OK" ] && ok "B44 reset bound: usable only if now < reset <= now+31d (edges included), else retry-after, else the cooldown; sink and sanitizer agree" || bad "B44 $got"

  # B34 the wrapper reads GC_POOL_CRED_DIR, the daemon CLAUDE_POOL_CRED_DIR (its test seam): the two must agree on the item, or the
  # daemon feeds an item nobody reads. The daemon honours the wrapper's name too (empty counts as unset).
  new_d; run_d CLAUDE_POOL_CRED_DIR= "GC_POOL_CRED_DIR=$POOL_DIR" -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(item_token)" = "$TOKEN_a" ] \
    && ok "B34 only GC_POOL_CRED_DIR set (as the wrapper reads it) -> the daemon writes the same item" || bad "B34 rc=$rc item=$(item_token | cut -c1-24) kc=$(ls "$D/kc/items" | tr '\n' ' ')"

  # B35 the epoch parser itself, table-driven: every shape of 'not an epoch' is None - never a float that is truthy-but-wrong
  # (nan), never an exception, never a number outside 2001..2100.
  got="$("$PY3" - "$DAEMON" <<'EOF' 2>&1
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
bad = []
for v in ["nan", "inf", "-inf", "1e999", "9e15", "0", "-5", "1000", "abc", "", "  ", "9999-12-31T23:59:59Z", "0001-01-01T00:00:00Z", "0001-01-01T00:00:00+14:00", "2000000000000000000"]:
    try: r = m._epoch(v)
    except BaseException as e: bad.append(f"{v!r} raised {type(e).__name__}"); continue
    if r is not None: bad.append(f"{v!r} -> {r!r} (want None)")
for v, want in [("2000000000", 2000000000.0), ("2000000000000", 2000000000.0), ("2033-05-18T03:33:20Z", 2000000000.0)]:
    try: r = m._epoch(v)
    except BaseException as e: bad.append(f"{v!r} raised {type(e).__name__}"); continue
    if r != want: bad.append(f"{v!r} -> {r!r} (want {want})")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
)"
  [ "$got" = "OK" ] && ok "B35 _epoch: junk -> None (no exception, no nan/inf, nothing outside 2001-2100); real epochs/ms/ISO survive" || bad "B35 $got"

  # B24 the log itself withholds a token-shaped message (defence in depth: a future f-string that interpolates a token)
  new_d
  got="$(GC_CITY_PATH="$D/city" "$PY3" -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.log("INFO", "oops " + sys.argv[2])' "$DAEMON" "$TOKEN_a" 2>&1; cat "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null)"
  printf '%s' "$got" | grep -qF "$TOKEN_a" && bad "B24 the log wrote a token-shaped message" || { printf '%s' "$got" | grep -q "withheld" && ok "B24 a token-shaped log message is withheld" || bad "B24 nothing logged: $got"; }


  # B18 the probe URL override only ever honours loopback (a token must not be aimable elsewhere by env)
  got="$(CLAUDE_POOL_PROBE_URL="https://evil.example/v1/messages" GC_CITY_PATH="$D/city" "$PY3" -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.probe_url())' "$DAEMON" 2>/dev/null)"
  [ "$got" = "https://api.anthropic.com/v1/messages" ] && ok "B18 a non-loopback CLAUDE_POOL_PROBE_URL is ignored" || bad "B18 probe_url() -> '$got'"

[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null

# ── C. wiring ──────────────────────────────────────────────────────────────────────────────────────
echo
echo "C. launchd wiring"
PLIST="${CLAUDE_POOL_PLIST:-$SELF_DIR/../claude-pool-account.plist}"
if [ ! -f "$PLIST" ]; then bad "C0 plist not found at $PLIST"
else
  plutil -lint "$PLIST" >/dev/null 2>&1 && ok "C1 plist is valid" || bad "C1 plutil -lint failed"
  pl() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
  [ "$(pl Label)" = "com.gascity.claude-pool-account" ] && ok "C2 label" || bad "C2 label '$(pl Label)'"
  [ "$(pl ProgramArguments:0)" = "/usr/bin/python3" ] && ok "C3 runs on /usr/bin/python3 (the interpreter B was tested on)" || bad "C3 interpreter '$(pl ProgramArguments:0)'"
  [ "$(pl ProgramArguments:2)" = "run-once" ] && ok "C4 argument is run-once" || bad "C4 args '$(pl ProgramArguments:2)'"
  case "$(pl ProgramArguments:1)" in */packs/town-deltas/assets/scripts/claude-pool-account.py) ok "C5 plist points at the daemon's repo path" ;; *) bad "C5 script path '$(pl ProgramArguments:1)'" ;; esac
  iv="$(pl StartInterval)"; [ -n "$iv" ] && [ "$iv" -ge 30 ] && [ "$iv" -le 120 ] && ok "C6 StartInterval=${iv}s: frequent enough for a <2 min absorb, longer than a run" || bad "C6 StartInterval='$iv'"
  [ "$(pl RunAtLoad)" = "false" ] && ok "C7 RunAtLoad=false (loading is the human step; first run <= StartInterval later)" || bad "C7 RunAtLoad '$(pl RunAtLoad)'"
  [ "$(pl EnvironmentVariables:USER)" != "" ] && [ "$(pl EnvironmentVariables:GC_CITY_PATH)" != "" ] && ok "C8 USER and GC_CITY_PATH are set for launchd" || bad "C8 launchd env incomplete"
fi

# C9 the doc names the item and the string it is derived from: the two must agree (it once said sha256("~/...") for a hash that is
# of the absolute path - an operator who deletes or inspects "the item" by recomputing it would have looked for the wrong one).
DOC="${CLAUDE_POOL_DOC:-$SELF_DIR/../../../../docs/claude-pool-account.md}"
if [ ! -f "$DOC" ]; then bad "C9 doc not found at $DOC"
else
  dhash="$(grep -o 'Claude Code-credentials-[0-9a-f]\{8\}' "$DOC" | head -1 | sed 's/.*-//')"
  dpath="$(grep -o 'sha256("[^"]*")' "$DOC" | head -1 | sed 's/^sha256("//; s/")$//')"
  case "$dpath" in /*) ;; *) dpath="" ;; esac
  [ -n "$dhash" ] && [ -n "$dpath" ] && [ "$(printf '%s' "$dpath" | shasum -a 256 | cut -c1-8)" = "$dhash" ] \
    && ok "C9 the doc's item name ($dhash) is the hash of the absolute path it names" \
    || bad "C9 the doc's item name '$dhash' is not sha256 of the path it names ('$dpath')"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
