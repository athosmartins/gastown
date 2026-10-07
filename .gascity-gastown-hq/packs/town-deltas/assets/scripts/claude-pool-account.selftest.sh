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
# HERMETIC means two things here, and both are checked rather than claimed:
#   - the WORLD is fake: a fake `security` (state in a temp dir), a fake `claude`, a fake probe and a fake vault, so nothing
#     here reaches the real Keychain, the real vault or the network;
#   - the ENVIRONMENT is not the caller's: every variable the daemon or the wrapper reads is unset and GC_CITY_PATH /
#     CLAUDE_POOL_STATE are pinned to scratch paths (see the block below). An agent session exports the REAL city path, and the
#     in-process bodies write through it: H0 proves the pin, and H1/H1b prove at the end that the real launch log and the real
#     state file did not grow a fixture. H1/H1b can only look when GC_CITY_PATH was set on entry; run it once with and once
#     under `env -i` (what a bare launchd/CI shell gives) - the verdict must be the same.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${CLAUDE_POOL_WRAPPER:-$SELF_DIR/claude-lowprio.sh}"
DAEMON="${CLAUDE_POOL_DAEMON:-$SELF_DIR/claude-pool-account.py}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$WRAPPER" ] || { echo "FATAL: wrapper not found at $WRAPPER"; exit 1; }
PY3="${CLAUDE_POOL_PY:-/usr/bin/python3}"; [ -x "$PY3" ] || PY3="$(command -v python3)"   # the interpreter launchd runs (3.9), not whichever is first on PATH

W="$(mktemp -d "${TMPDIR:-/tmp}/claude-pool-account-selftest.XXXXXX")"
cleanup() { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }   # B50 makes a directory read-only: undo it if the run is interrupted there
trap cleanup EXIT

# HERMETIC MEANS THE ENVIRONMENT TOO. The daemon reads its whole world from environment variables (GC_CITY_PATH, CLAUDE_POOL_*), and in an
# agent session GC_CITY_PATH is the REAL city: an in-process body that imports the daemon and calls log() would append fixture lines to the
# real wrapper log - the very file the daemon reads its pool launches from. So: remember where the real log is (to prove at the end
# that nothing reached it), drop every variable the daemon or the wrapper reads, and pin the ones that matter to scratch paths for the whole
# suite. Bodies that run through `env -i` (run_d, run_wrapper) start from nothing anyway; the ones that do not inherit THIS pin.
REAL_LOG=""; [ -n "${GC_CITY_PATH:-}" ] && REAL_LOG="$GC_CITY_PATH/.gc/logs/claude-pool-account.log"
REAL_OFF=0;  [ -n "$REAL_LOG" ] && [ -f "$REAL_LOG" ] && REAL_OFF="$(wc -c < "$REAL_LOG" | tr -d ' ')"
REAL_STATE="$(sed -n 's/^DEFAULT_STATE = "\(.*\)".*/\1/p' "$DAEMON" | head -1)"
for v in GC_CITY_PATH GC_POOL_ACCOUNT GC_POOL_CRED_DIR GC_POOL_UNSTICK CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_POOL_STATE CLAUDE_POOL_NOW \
         CLAUDE_POOL_CRED_DIR CLAUDE_POOL_PROBE_URL CLAUDE_POOL_TMUX CLAUDE_POOL_TMUX_SOCKET CLAUDE_POOL_EVIDENCE_COOLDOWN_S; do
  unset "$v"
done
INPROC_CITY="$W/inproc-city"; INPROC_STATE="$W/inproc-state.json"; mkdir -p "$INPROC_CITY/.gc/logs"
PIN=("GC_CITY_PATH=$INPROC_CITY" "CLAUDE_POOL_STATE=$INPROC_STATE")   # for `env -i`: put it first, a later assignment wins. (CLAUDE_POOL_ACCOUNTS_LIB is not pinned: B0 uses it to find the accounts library the daemon runs against)
export "${PIN[@]}"

field() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }

# H0 canary: the pin holds. A body that imports the daemon and logs writes into the SCRATCH city, reads the scratch state path, and the real
# log (if this run was started from a session that has one) does not grow by that line. If this fails, nothing below can be trusted to be hermetic.
CANARY="canary-$(basename "$W")"
cat > "$W/py_canary.py" <<'EOF'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.log("INFO", sys.argv[2])
print("OK" if str(m.city()) == os.path.normpath(sys.argv[3]) and str(m.state_path()) == os.path.normpath(sys.argv[4]) and not os.environ.get("CLAUDE_POOL_NOW") else "BAD city=%s state=%s" % (m.city(), m.state_path()))
EOF
got="$("$PY3" "$W/py_canary.py" "$DAEMON" "$CANARY" "$INPROC_CITY" "$INPROC_STATE" 2>&1)"
in_real=0; [ -n "$REAL_LOG" ] && [ -f "$REAL_LOG" ] && tail -c +"$((REAL_OFF + 1))" "$REAL_LOG" | grep -aqF "$CANARY" && in_real=1
if [ "$got" = "OK" ] && grep -qF "$CANARY" "$INPROC_CITY/.gc/logs/claude-pool-account.log" && [ "$in_real" = "0" ]; then
  ok "H0 hermetic: an in-process body's log line lands in the scratch city (state path scratch too), not in the real wrapper log${REAL_LOG:+ ($REAL_LOG)}"
else bad "H0 NOT hermetic: body said '$got', scratch log has it: $(grep -cF "$CANARY" "$INPROC_CITY/.gc/logs/claude-pool-account.log"), real log has it: $in_real"; fi

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

# A8 no `security` binary at all. PATH=/usr/bin:/bin is NOT that on macOS (`security` is /usr/bin/security): this test
# used to run the REAL security against the REAL login Keychain and pass on its answer (44, "no such item"), so the
# no-binary path (rc=127) was never reached and no test could see 127 being read as "the item exists" (gate ga-rtavdh).
# So: a PATH directory holding exactly what the wrapper runs here (date, ps, shasum, sleep, id) and no `security`; proof
# that this PATH really cannot resolve `security`; and the SKIP line must say rc=127 - 44, 124 and 36 also launch
# claude without the variable, so the launch alone cannot tell which path ran.
NOSEC="$W/nosec"; mkdir -p "$NOSEC"; nosec_ok=1
for t in date ps shasum sleep id; do
  for d in /bin /usr/bin; do [ -x "$d/$t" ] && { ln -sf "$d/$t" "$NOSEC/$t"; break; }; done
  [ -x "$NOSEC/$t" ] || nosec_ok=0
done
env -i PATH="$NOSEC" /bin/bash -c 'command -v security' >/dev/null 2>&1 && nosec_ok=0
new_kc
out="$(env -i HOME="$W/home" PATH="$NOSEC" USER=athos GC_CITY_PATH="$W/city" GC_LOWPRIO=0 GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude" GC_POOL_CRED_DIR="$POOL_DIR" "$WRAPPER" x 2>/dev/null)"
if [ "$nosec_ok" != "1" ]; then bad "A8 vacuous: could not build a PATH that has the wrapper's tools and no \`security\`"
elif [ "$(field argc "$out")" = "1" ] && [ "$(field secstore "$out")" = "<unset>" ] \
     && grep -q "POOL-ACCT SKIP.*security rc=127;" "$W/city/.gc/logs/claude-pool-account.log"; then
  ok "A8 no \`security\` binary at all -> claude still launches, variable not exported, and the SKIP line says rc=127"
else bad "A8 no security binary: out='$(printf '%s' "$out" | tr '\n' ' ')' log: $(tail -n 1 "$W/city/.gc/logs/claude-pool-account.log")"; fi

new_kc; touch "$FAKE_KC/items/$SVC"
run_wrapper USER=athos -- x >/dev/null
grep -q "POOL-ACCT SET" "$W/city/.gc/logs/claude-pool-account.log" && ok "A9 one POOL-ACCT SET line in claude-pool-account.log" || bad "A9 no POOL-ACCT SET line: $(cat "$W/city/.gc/logs/claude-pool-account.log")"
[ "$(grep -c "POOL-ACCT" "$W/city/.gc/logs/claude-lowprio.log" 2>/dev/null || true)" = "0" ] && ok "A9a the lowprio log keeps its one-line-per-launch contract (no POOL-ACCT lines)" || bad "A9a POOL-ACCT lines leaked into claude-lowprio.log"
grep -q "sk-ant-" "$W/city/.gc/logs/claude-pool-account.log" && bad "A9b log carries a token shape" || ok "A9b log carries no token shape"

# A9c the line the wrapper really writes is the line the daemon really parses, and its pid is the pid of the claude that was exec'd
# (the daemon proves "this pane runs a pool-account claude" from that pid; a drift on either side makes every pane look unproven and
# the whole unstick path silently inert - the one failure the other tests cannot see because they write the line themselves).
cat > "$BIN/fake-claude-pid" <<'EOF'
#!/bin/bash
echo "claudepid=$$"
EOF
chmod +x "$BIN/fake-claude-pid"
new_kc; touch "$FAKE_KC/items/$SVC"
out="$(run_wrapper USER=athos GC_AGENT=gastown.dog-9 GC_LOWPRIO_CLAUDE_BIN="$BIN/fake-claude-pid" -- x)"
cat > "$W/py_setre.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
n = 0
for line in open(sys.argv[2], encoding="utf-8"):
    mt = m.SET_RE.fullmatch(line.strip())
    if mt:
        n += 1
        print("MATCH", mt.group(2), mt.group(3), mt.group(4))
print("COUNT", n)
EOF
got="$(PYTHONDONTWRITEBYTECODE=1 "$PY3" "$W/py_setre.py" "$DAEMON" "$W/city/.gc/logs/claude-pool-account.log" 2>&1)"
cpid="$(field claudepid "$out")"
if [ -n "$cpid" ] && [ "$(printf '%s\n' "$got" | tail -n 1)" = "COUNT 1" ] && [ "$(printf '%s\n' "$got" | sed -n 1p)" = "MATCH $cpid gastown.dog-9 $SVC" ]; then
  ok "A9c the wrapper's real SET line matches the daemon's SET_RE; its pid is the exec'd claude's \$\$ ($cpid), agent and item as launched"
else bad "A9c wrapper SET line vs daemon SET_RE: claude pid='$cpid' parsed: $(printf '%s' "$got" | tr '\n' '|') log: $(tail -n 1 "$W/city/.gc/logs/claude-pool-account.log")"; fi

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
                          # two ways a write can report success and still not leave the credential that was asked for
                          [ -e "$KC/write-lands-nothing" ] && { echo "DROPPED $svc" >> "$KC/dropped.log"; return 0; }
                          [ -e "$KC/write-lands-other" ] && hex="$(printf '%s' '{"claudeAiOauth":{"accessToken":"selftest-some-other-credential"}}' | xxd -p | tr -d '\n')"
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

# fake `tmux` (ga-8hcnvb.2): the pool's panes are FILES under $TMUXD - panes.txt ("<id> <pid> <dead>"), screen.<n> (what `capture-pane`
# prints), keys.log (every `send-keys`, the only thing this daemon sends). The daemon is always pointed at it (CLAUDE_POOL_TMUX), so
# no scenario can reach the real city's tmux server. Knobs: `down` = no server; `send-fails`; `clear-on-esc` = Escape brings the prompt
# back (what claude does); `screen2.<n>` = what the pane shows from the SECOND capture on (the screen changing between the scan and
# the key); `pid2.<n>` = the pane's process as `display-message` answers it (the pane being recycled between the scan and the key).
cat > "$BB/tmux" <<'EOF'
#!/bin/bash
echo "$*" >> "$TMUXD/calls.log"
[ "${1:-}" = "-L" ] && { echo "$2" > "$TMUXD/socket"; shift 2; }
cmd="${1:-}"; shift
[ -e "$TMUXD/down" ] && { echo "no server running" >&2; exit 1; }
t=""; prev=""; for a in "$@"; do [ "$prev" = "-t" ] && t="$a"; prev="$a"; done
n="${t#%}"
case "$cmd" in
  list-panes) [ -f "$TMUXD/panes.txt" ] && cat "$TMUXD/panes.txt"; exit 0 ;;
  capture-pane)
    [ -f "$TMUXD/screen.$n" ] || exit 1
    c=$(( $(cat "$TMUXD/cap.$n" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$TMUXD/cap.$n"
    if [ "$c" -ge 2 ] && [ -f "$TMUXD/screen2.$n" ]; then cat "$TMUXD/screen2.$n"; else cat "$TMUXD/screen.$n"; fi ;;
  display-message)
    if [ -f "$TMUXD/pid2.$n" ]; then cat "$TMUXD/pid2.$n"; else awk -v id="$t" '$1 == id { print $2 }' "$TMUXD/panes.txt"; fi ;;
  send-keys)
    [ -e "$TMUXD/send-fails" ] && exit 1
    echo "$t ${*: -1}" >> "$TMUXD/keys.log"
    [ -e "$TMUXD/clear-on-esc" ] && cp "$TMUXD/prompt.txt" "$TMUXD/screen.$n"
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$BB/tmux"

# mock Anthropic: behaviour per Bearer token from $W/srv.json = {token: {status, h:{header:value}}}; every request token logged
cat > "$W/mock_api.py" <<'EOF'
import http.server, json, sys
STATE, LOG, PORTF = sys.argv[1:4]
DETAIL = sys.argv[4] if len(sys.argv) > 4 else None
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.do_POST()   # a redirect followed by urllib arrives as a GET: log its Bearer too
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        beh = json.load(open(STATE)).get(tok) or {"status": 401, "h": {}}
        with open(LOG, "a") as f: f.write(tok + "\n")
        if DETAIL:
            with open(DETAIL, "a") as f: f.write("%s %s %s %s\n" % (self.command, self.path, beh["status"], tok[-4:]))
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

D="$W/d"; STATE="$D/current.json"; SRV_PID=""; TMUXD="$D/tmux"

# ── the pool's panes (ga-8hcnvb.2). A pane is a REAL process (`sleep`, standing for the claude the wrapper exec'd) plus the wrapper's
# POOL-ACCT SET line for its pid, plus a screen file the fake tmux serves. That is what the daemon's proof of 'a pool pane' looks at.
PANE_PIDS=(); pane_n=10
pane_kill_all() { local p; for p in "${PANE_PIDS[@]:-}"; do [ -n "$p" ] && { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }; done; PANE_PIDS=(); }
trap 'pane_kill_all; cleanup' EXIT
set_line() { # set_line <pid> <agent> [seconds to add to now for the line's time]  - what claude-lowprio.sh logs just before it exec's claude
  printf '%s pid=%s agent=%s wrapper POOL-ACCT SET item=%s\n' "$(date -u -r $(( $(date +%s) + ${3:-0} )) +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${SET_ITEM:-$SVC}" >> "$D/city/.gc/logs/claude-pool-account.log"
}
MODAL_SCREEN='● Working on the bead...

  You hit your weekly limit · resets Oct 7, 7pm

 What do you want to do?

 ❯ 1. Stop and wait for limit to reset
   2. Wait here, then continue automatically at Oct 7 at 7pm
   3. Upgrade your plan

 Enter to confirm · Esc to cancel'
PROMPT_SCREEN='  You hit your weekly limit · resets Oct 7, 7pm

╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts'
QUOTED_SCREEN='● The bead says the screen reads:
    What do you want to do?
    ❯ 1. Stop and wait for limit to reset
    Enter to confirm · Esc to cancel
  and that is what the script has to recognise.

╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts'
WORKING_SCREEN='● Reading the file...
  ✻ Thinking… (12s · esc to interrupt)

╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯'
# The REAL shapes (claude 2.1.291, an account whose weekly limit is hit; captured live by the acceptance probe). The modal opens on a session's
# FIRST hit only; after it is dismissed every later hit is just the envelope, with the prompt box right under it.
RULE='──────────────────────────────────────────────────────────────────────'
BOX="$RULE
❯ 
$RULE
  ⏸ manual mode on · ? for shortcuts · ← for agents"
BANNER=' ▐▛███▛█   Claude Code v2.1.291
▝▜██████▀  Haiku 4.5 · Claude API
 ▝▝   ▝▝   ~/work'
HIT1="❯ Reply with exactly: ALPHA
  ⎿  You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)
✻ Sautéed for 3s · done 7:35 AM"
HIT2="❯ Reply with exactly: BRAVO
  ⎿  You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)
     /upgrade to increase your usage limit.
✻ Crunched for 0s · done 7:36 AM"
HIT3="❯ Reply with exactly: CHARLIE
  ⎿  You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)
     /upgrade to increase your usage limit.
✻ Brewed for 1s · done 7:39 AM"
MODALBLK='▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   What do you want to do?
   ❯ 1. Stop and wait for limit to reset
     2. Wait here, then continue automatically at Oct 7 at 7pm
     3. Upgrade your plan
   Enter to confirm · Esc to cancel'
INLINE1_SCREEN="$BANNER
$HIT1
$BOX"
INLINE2_SCREEN="$BANNER
$HIT1
$HIT2
$BOX"
INLINE3_SCREEN="$BANNER
$HIT1
$HIT2
$HIT3
$BOX"
MODALREAL_SCREEN="$BANNER
$HIT1
$MODALBLK"
pane_screen() { # pane_screen <pane id> <modal|prompt|quoted|working|inline1|inline2|inline3|modalreal>
  local s; case "$2" in modal) s="$MODAL_SCREEN" ;; prompt) s="$PROMPT_SCREEN" ;; quoted) s="$QUOTED_SCREEN" ;; working) s="$WORKING_SCREEN" ;;
    inline1) s="$INLINE1_SCREEN" ;; inline2) s="$INLINE2_SCREEN" ;; inline3) s="$INLINE3_SCREEN" ;; modalreal) s="$MODALREAL_SCREEN" ;; *) s="$2" ;; esac
  printf '%s\n' "$s" > "$TMUXD/screen.${1#%}"; printf '%s\n' "$PROMPT_SCREEN" > "$TMUXD/prompt.txt"
}
pane_add() { # pane_add <agent> <screen> [line-time offset] -> $PANE (id) and $PANE_PID. The pane's own process IS the claude.
  pane_n=$((pane_n + 1)); PANE="%$pane_n"
  sleep 900 & PANE_PID=$!; PANE_PIDS+=("$PANE_PID")
  echo "$PANE $PANE_PID 0" >> "$TMUXD/panes.txt"
  set_line "$PANE_PID" "$1" "${3:-0}"
  pane_screen "$PANE" "$2"
}
pane_add_child() { # pane_add_child <agent> <screen>: the pane's process is a shell and claude (the pid on the SET line) is its child
  pane_n=$((pane_n + 1)); PANE="%$pane_n"; rm -f "$D/childpid"
  bash -c 'sleep 900 & echo $! > "$0"; wait' "$D/childpid" & PANE_PID=$!; PANE_PIDS+=("$PANE_PID")
  local n=0; while [ ! -s "$D/childpid" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
  CHILD_PID="$(cat "$D/childpid")"; PANE_PIDS+=("$CHILD_PID")
  echo "$PANE $PANE_PID 0" >> "$TMUXD/panes.txt"
  set_line "$CHILD_PID" "$1"
  pane_screen "$PANE" "$2"
}
unset_line() { grep -v " pid=$1 " "$D/city/.gc/logs/claude-pool-account.log" > "$D/log.tmp"; cp "$D/log.tmp" "$D/city/.gc/logs/claude-pool-account.log"; }   # a pane the wrapper never launched onto the pool item
keys_sent() { [ -f "$TMUXD/keys.log" ] && wc -l < "$TMUXD/keys.log" | tr -d ' ' || echo 0; }
keys_to() { local c; c="$(grep -c "^$1 " "$TMUXD/keys.log" 2>/dev/null)"; echo "${c:-0}"; }   # grep -c prints 0 AND exits 1 when nothing matches: no `|| echo 0` here, it would print a second 0
rearm() { edit_state 'st.pop("panes", None)'; }   # the session hit the limit AGAIN: a modal the daemon has not seen before
# A reset time is believed only if it is ahead of NOW and at most 31 days away (the daemon's _usable_reset). The scenarios below
# store reset times like 2000000000, so they run on a clock that makes them 11 days ahead - unless a test sets NOW_OVERRIDE itself
# (NOW_OVERRIDE= with an empty value = the real clock).
NOW_BASE=1999000000
T10=$(( (NOW_BASE / 600 + 1) * 600 ))   # the next clock minute that is a multiple of 10: what a run drops without acting is said then (B55d, B82-B84)
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
  pane_kill_all
  rm -rf "$D"; mkdir -p "$D/kc/items" "$D/vault" "$D/city/.gc/logs" "$D/home" "$TMUXD"
  : > "$D/probes.log"; echo '{}' > "$D/srv.json"
  local i=0 e
  for e in "${EMAILS[@]}"; do printf '%s' "$(tok_of "$e")" > "$D/vault/$e"; set_srv "$e" 200 "$HDR_OK"; done
  # The default usage store: all three accounts 'com saldo' AND with a good reading stamped last_ok_at, as the real collector
  # writes it. `_selftest_fresh` marks it as the store run_d re-stamps (see restamp_store); a store a scenario writes itself has
  # no such key and is never touched.
  "$PY3" - "$D/usage.json" "$NOW_BASE" <<'EOF'
import json, sys
from datetime import datetime, timezone
iso = datetime.fromtimestamp(float(sys.argv[2]) - 1, timezone.utc).isoformat()
accts = [{"email": e, "ok": True, "stale": False, "collected_at": iso, "last_ok_at": iso,
          "weekly_all": {"percent": 10, "resets_at": "203%d-01-01T00:00:00+00:00" % i}, "session": {"percent": 5}}
         for i, e in enumerate(["a@t.test", "b@t.test", "c@t.test"])]
json.dump({"_selftest_fresh": True, "updated_at": iso, "accounts": accts}, open(sys.argv[1], "w"))
EOF
  "$PY3" "$W/mock_api.py" "$D/srv.json" "$D/probes.log" "$D/port" "$D/served.log" & SRV_PID=$!
  local n=0; while [ ! -s "$D/port" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  export FAKE_KC="$D/kc" VAULT="$D/vault"
}
# The scenarios written before the usage store carried reading times all assume a store that never lags the clock. restamp_store
# keeps that true for the DEFAULT store (the one marked `_selftest_fresh`): before every run its readings are stamped one second
# before that run's clock, i.e. 'the collector ran just now'. The scenarios that are about a store that LAGS (B45+) write their
# own store without the mark, and this leaves it alone.
restamp_store() { # restamp_store <clock epoch; empty = the real clock>
  [ -f "$D/usage.json" ] || return 0
  "$PY3" - "$D/usage.json" "${1:-$(date +%s)}" <<'EOF'
import json, sys
from datetime import datetime, timezone
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
if not (isinstance(d, dict) and d.get("_selftest_fresh")): sys.exit(0)
iso = datetime.fromtimestamp(float(sys.argv[2]) - 1, timezone.utc).isoformat()
d["updated_at"] = iso
for a in d.get("accounts", []): a["collected_at"] = a["last_ok_at"] = iso
json.dump(d, open(sys.argv[1], "w"))
EOF
}
run_d() { # run_d [env assignments...] -- <daemon args>   (always a clean environment)
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  restamp_store "${NOW_OVERRIDE-$NOW_BASE}"
  rm -f "$TMUXD"/cap.* 2>/dev/null
  env -i HOME="$D/home" USER=athos PATH="$BB:/usr/bin:/bin" GC_CITY_PATH="$D/city" FAKE_KC="$D/kc" VAULT="$D/vault" \
      TMUXD="$TMUXD" CLAUDE_POOL_TMUX="$BB/tmux" CLAUDE_POOL_TMUX_SOCKET=selftest \
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
  nlog() { local c; c="$(grep -c -- "$1" "$D/city/.gc/logs/claude-pool-account.log" 2>/dev/null)"; echo "${c:-0}"; }
  probes_of() { grep -cxF "$(tok_of "$1")" "$D/probes.log" 2>/dev/null || true; }
  # the calls that CAN cost (/v1/messages, the evidence probe) with <email>'s key. probes_of counts every hit on the mock, the free
  # count_tokens key checks included: a test that means "nothing billed was asked" must not move when a free check runs.
  msg_probes_of() { local c; c="$(grep -c " /v1/messages [0-9]* $(printf '%s' "$(tok_of "$1")" | tail -c 4)\$" "$D/served.log" 2>/dev/null)"; echo "${c:-0}"; }
  served() { local c; c="$(grep -c ' /v1/messages 200 ' "$D/served.log" 2>/dev/null)"; echo "${c:-0}"; }   # calls the API SERVED: the only ones that cost
  edit_state() { "$PY3" - "$STATE" "$1" <<'EOF'
import json, sys
p, code = sys.argv[1:3]
st = json.load(open(p)); exec(code); json.dump(st, open(p, "w"))
EOF
  }
  # world where a is the seeded account (item rewritten long ago) and one pool session is sitting on the limit modal: the evidence
  # every failover needs. The pane is added AFTER the seed run, so the daemon sees the modal for the first time in the run under test.
  seeded() { new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 modal; }
  LOG="$D/city/.gc/logs/claude-pool-account.log"   # the daemon's log (D never changes: new_d recreates the same path)

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
  [ -z "$(jex b@t.test reset_epoch)" ] && [ "$(nlog "API-CALL count_tokens")" = "3" ] && [ "$(nlog "API-CALL messages")" = "1" ] \
    && ok "B4b a candidate is asked only whether its KEY is accepted (count_tokens: seed a, then b and c), never for balance: b's 429 there is 'could not tell' - skipped this run, not registered; the one messages call is the evidence probe of a" \
    || bad "B4b b-entry='$(jex b@t.test reset_epoch)' count_tokens=$(nlog "API-CALL count_tokens") messages=$(nlog "API-CALL messages")"

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
  rearm; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000090000)"; NOW_OVERRIDE=2000000200 run_d -- run-once   # a still rejected: the session hits the limit again (a modal not seen before)
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test reset_epoch)" = "2000090000.0" -o "$(jex a@t.test reset_epoch)" = "2000090000" ] \
    && ok "B9 failed failback -> a's 429 triggers the failover again and the new reset time is stored" || bad "B9 current='$(jget "$STATE" current)' reset='$(jex a@t.test reset_epoch)'"
  NOW_OVERRIDE=2000000300 run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B9b and it does not bounce back on the next run" || bad "B9b current='$(jget "$STATE" current)'"

  # B9c a rejection whose reset header is already in the past gets a cooldown, never an instant failback
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 1000)"; NOW_OVERRIDE=2000000000 run_d -- run-once
  r="$(jex a@t.test reset_epoch)"; "$PY3" -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 2000000000 else 1)' "${r:-0}" \
    && ok "B9c stale reset header (past) -> cooldown from now, not an instant failback" || bad "B9c reset_epoch=$r"

  # B10 a recovered account that does NOT outrank the active one is not a reason to move
  # (why=rejected: the entry must be one the failback WOULD go to - without it c is kept out by B32c's rule, and the rank rule this
  # test is about is never what decided)
  seeded; w0=$(writes); edit_state 'st["exhausted"]={"c@t.test":{"reset_epoch":2000000000.0,"claim":"seven_day","why":"rejected"}}'; pc0=$(probes_of c@t.test)
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
  # The holder signals AFTER it owns the lock and keeps it until killed: a fixed sleep(8)+sleep(1) made B13 depend on
  # how fast python starts, and under load (~70) the lock was not held yet, or already gone, when the run began.
  new_d; rm -f "$D/held"; "$PY3" - "$D/city/.gc/claude-pool-account.lock" "$D/held" <<'EOF' &
import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(300)
EOF
  HOLD=$!
  for _i in $(seq 1 120); do [ -e "$D/held" ] && break; sleep 0.25; done
  [ -e "$D/held" ] || bad "B13 setup: the lock holder never took the lock"
  run_d -- run-once; rc=$?
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
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] && ok "B17 revoked key (401) on the active account, GIVEN a limit screen -> failover with a cooldown" || bad "B17 current='$(jget "$STATE" current)'"

  # B17b..B17g (gate ga-8hcnvb.2, round 1): a key REFUSED on the active account is found on its own. A revoked or expired setup-token
  # answers 401 inside the sessions - an "API Error" line, NOT a limit screen (B73) - so no pane ever shows evidence for it, and seeded()
  # above manufactures a limit screen that this failure never produces. Here there is NO pane at all: the only thing that can notice is
  # the daemon asking, for free (count_tokens), whether the key it put in the item is still accepted.
  unseen() { new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; }   # the seed run only: a is in the item, no pane anywhere
  unseen; [ "$(jget "$STATE" current)" = "a@t.test" ] || bad "B17b precondition: the seed run did not put a in the item (current='$(jget "$STATE" current)')"
  w0=$(writes); set_srv a@t.test 401 '{}'; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$((w0 + 1))" ] && [ "$(jex a@t.test why)" = "invalid" ] \
    && ok "B17b the active key is refused (401) and NO pane shows a limit screen -> the pool item moves to b in the same run, a is registered as invalid" \
    || bad "B17b current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) writes $w0 -> $(writes) a.why='$(jex a@t.test why)'"
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(nlog "API-CALL messages")" = "0" ] && [ "$(served)" = "0" ] && [ "$(msg_probes_of a@t.test)" = "0" ] \
    && ok "B17c ...and it cost nothing: no messages call at all (the key check is count_tokens, which is never billed), nothing served" \
    || bad "B17c messages-calls=$(nlog "API-CALL messages") served=$(served) a-messages=$(msg_probes_of a@t.test)"
  grep -q "KEY-CHECK .*invalid" "$LOG" && grep -q "SWITCH a@t.test -> b@t.test.*failover: a@t.test invalid" "$LOG" \
    && ok "B17d the log says what was found (the key check: invalid) and the switch (from, to, why)" || bad "B17d log: $(grep -E 'KEY-CHECK|SWITCH' "$LOG" | tail -n 3 | tr '\n' '|')"
  # the key check does not depend on the panes: tmux that cannot be read must not hide a refused key. (A pool pane that is only WORKING is
  # there so that tmux is actually asked: with no pool process alive the scan does not ask it, and nothing would be unreadable.)
  unseen; pane_add gastown.dog-2 working; w0=$(writes); touch "$TMUXD/down"; set_srv a@t.test 401 '{}'; run_d -- run-once; rm -f "$TMUXD/down"
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$((w0 + 1))" ] && grep -q "the pool's panes could not be looked at this run" "$LOG" \
    && ok "B17e tmux unreadable AND the active key refused -> still moves to b (the key check does not need the panes), and the log says the panes could not be read" \
    || bad "B17e current='$(jget "$STATE" current)' writes $w0 -> $(writes): $(tail -n 3 "$LOG" | tr '\n' '|')"
  # every other answer is 'could not tell' (or fine): it never moves the pool - and it is SAID, not silent
  # (clock minute 33316680 = 5 x 6663336: a multiple of 5, the minutes on which a 'could not tell' is logged; and of 30, the heartbeat)
  unseen; w0=$(writes); set_srv a@t.test 500 '{}'; NOW_OVERRIDE=1999000800 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ -z "$(jex a@t.test why)" ] && grep -q "KEY-CHECK .*unknown" "$LOG" \
    && ok "B17f the key check could not tell (HTTP 500) -> nothing moves, a is not registered, and the log SAYS it could not tell" \
    || bad "B17f current='$(jget "$STATE" current)' writes $w0 -> $(writes) a.why='$(jex a@t.test why)': $(tail -n 2 "$LOG" | tr '\n' '|')"
  # a check that KEEPS failing (the endpoint changed, no egress) is visible but is not a line a minute: five consecutive minutes -> one line
  unseen; w0=$(writes); set_srv a@t.test 500 '{}'; for s in 0 60 120 180 240; do NOW_OVERRIDE=$((1999000800 + s)) run_d -- run-once; done
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(nlog "KEY-CHECK")" = "1" ] \
    && ok "B17f2 a key check that keeps failing for 5 minutes -> nothing moves, and ONE log line (not one a minute: this log is also read for pool membership)" \
    || bad "B17f2 current='$(jget "$STATE" current)' writes $w0 -> $(writes) key-check-lines=$(nlog "KEY-CHECK"): $(grep KEY-CHECK "$LOG" | tail -n 3 | cut -c1-120 | tr '\n' '|')"
  unseen; w0=$(writes); for e in a@t.test b@t.test c@t.test; do set_srv "$e" 401 '{}'; done; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && grep -q "staying on a@t.test" "$LOG" \
    && ok "B17g the active key is refused but no other account has an accepted key -> stays on a, no item write, and the log says so" \
    || bad "B17g current='$(jget "$STATE" current)' writes $w0 -> $(writes): $(tail -n 3 "$LOG" | tr '\n' '|')"
  # a healthy account with no pane: still not one billed call, nothing moves, and the log is not fed one line per minute for it (the
  # wrapper's POOL-ACCT SET lines share this file and are read from its last 1 MiB: a line a minute would push them out in days)
  unseen; w0=$(writes); run_d -- run-once; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(nlog "API-CALL messages")" = "0" ] && [ "$(served)" = "0" ] && [ "$(nlog "KEY-CHECK")" = "0" ] \
    && ok "B17h healthy key, no pane (2 runs, clock minute not a multiple of 30) -> nothing moves, nothing billed, and the log stays quiet" \
    || bad "B17h current='$(jget "$STATE" current)' writes $w0 -> $(writes) messages=$(nlog "API-CALL messages") served=$(served) key-check-lines=$(nlog "KEY-CHECK")"
  NOW_OVERRIDE=1999000800 run_d -- run-once   # minute 33316680 = 30 x 1110556: the heartbeat minute
  [ "$(nlog "KEY-CHECK")" = "1" ] && grep -q "KEY-CHECK .*valid" "$LOG" \
    && ok "B17i ...and on a clock minute that is a multiple of 30 it logs ONE heartbeat line saying the key was checked and is accepted" \
    || bad "B17i key-check lines=$(nlog "KEY-CHECK"): $(tail -n 2 "$LOG" | tr '\n' '|')"

  # B19 a locked keychain is 'could not tell', never 'missing': no rewrite
  seeded; rm -f "$D/kc/items/$SVC"; touch "$D/kc/locked"; w0=$(writes); run_d -- run-once
  [ "$(writes)" = "$w0" ] && grep -q "unreadable" "$D/city/.gc/logs/claude-pool-account.log" && ok "B19 keychain locked (exit 36) -> item NOT rewritten, reported as unreadable" || bad "B19 writes $w0 -> $(writes)"
  rm -f "$D/kc/locked"

  # B20 the read-back after a successful write 'could not tell' (keychain locked) -> the switch still stands
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; touch "$D/kc/locked"; run_d -- run-once; rm -f "$D/kc/locked"
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && grep -q "unverified" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B20 write ok + read-back unreadable -> decision follows the item (b), reported as unverified" || bad "B20 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24)"

  # B20b/B20c the two read-back guards in switch_to: the write reported success but the item does not hold what was asked
  # for. B20 covers only 'could not read it back'; these are the checks behind "the credential decided on is the one the
  # item holds", and without a test deleting either one left the whole suite green (gate ga-rtavdh, non-blocking).
  # B20b: it lands ANOTHER credential -> the decision must not move to b.
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; touch "$D/kc/write-lands-other"; run_d -- run-once; rm -f "$D/kc/write-lands-other"
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(jget "$STATE" fingerprint)" = "$(fp_of "$TOKEN_a")" ] \
    && grep -q "holds another credential" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B20b write ok but the item holds ANOTHER credential -> decision NOT changed (still a), says so" \
    || bad "B20b current='$(jget "$STATE" current)' fp='$(jget "$STATE" fingerprint)': $(grep -E 'ERROR|SWITCH' "$D/city/.gc/logs/claude-pool-account.log" | tail -n 2 | tr '\n' '|')"
  # B20c: it lands NOTHING (first run, so there was no item before) -> the seed must not be recorded.
  new_d; touch "$D/kc/write-lands-nothing"; run_d -- run-once; rm -f "$D/kc/write-lands-nothing"
  [ -z "$(jget "$STATE" current)" ] && [ ! -e "$D/kc/items/$SVC" ] && grep -q "not found afterwards" "$D/city/.gc/logs/claude-pool-account.log" \
    && ok "B20c write ok but the item is NOT THERE afterwards -> no decision recorded, says so" \
    || bad "B20c current='$(jget "$STATE" current)': $(grep -E 'ERROR|SWITCH|WARN' "$D/city/.gc/logs/claude-pool-account.log" | tail -n 2 | tr '\n' '|')"

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
  got="$(env -i "${PIN[@]}" USER= GC_CITY_PATH="$D/city" "$PY3" -c '
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
  [ -z "$(jex a@t.test why)" ] && grep -q "exhausted entry for a@t.test dropped: its key was refused" "$LOG" \
    && ok "B32d the refused key's entry leaves the registry at its time WITH a line saying why (it used to go in silence)" \
    || bad "B32d a-entry='$(jex a@t.test why)': $(grep -E 'dropped' "$LOG" | tail -n 1)"
  rearm; set_srv b@t.test 429 "$(hdr_rejected five_hour 2000003600)"; set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=2000000100 run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B32b ...and once its key works again it is used the normal way: probed on the next failover (b rejected -> a)" \
    || bad "B32b current='$(jget "$STATE" current)'"

  # B32c the same for an exhausted entry that does not say WHY it was registered (this daemon always records `why`; a state file edited
  # by hand or written by something else may not, or may say something else). The failback does not probe, so 'unknown why' must not
  # read as 'a rate limit that renews': only an entry that says "rejected" is failed back to. Not acted on, dropped at its time, and said.
  for edit in 'st["exhausted"]["a@t.test"].pop("why", None)' 'st["exhausted"]["a@t.test"]["why"]=None' \
              'st["exhausted"]["a@t.test"]["why"]="limit"' 'st["exhausted"]["a@t.test"]["why"]=["rejected"]'; do
    seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once        # on b, a registered 'rejected'
    [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "rejected" ] || bad "B32c precondition: failover to b / a registered rejected (why='$(jex a@t.test why)')"
    edit_state "$edit"; pa0=$(probes_of a@t.test); w0=$(writes); NOW_OVERRIDE=2000000100 run_d -- run-once; rc=$?   # a's time has passed, a outranks b
    [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$w0" ] \
      && [ "$(probes_of a@t.test)" = "$pa0" ] && [ -z "$(jex a@t.test reset_epoch)" ] \
      && grep -q "exhausted entry for a@t.test does not say why it was registered" "$D/city/.gc/logs/claude-pool-account.log" \
      && ok "B32c entry [$edit] -> NO unprobed failback (stays on b, item untouched), dropped, and a WARN says so" \
      || bad "B32c [$edit]: rc=$rc current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) writes $w0 -> $(writes) a-entry='$(jex a@t.test reset_epoch)'"
  done

  # B33 what the active account just ANSWERED beats what was stored about it: if it is in the exhausted registry (all accounts had
  # been rejected, the pool stayed put, then it renewed) the entry is cleared now, not left to veto it in a later failover.
  seeded; for e in a b c; do set_srv "$e@t.test" 429 "$(hdr_rejected seven_day 2000000000)"; done; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] || bad "B33 precondition: all rejected -> stay on a, a registered"
  # (b and c are only asked whether their KEY works, so "all rejected" registers just the probed account: b's entry is put there directly)
  edit_state 'st["exhausted"]["b@t.test"]={"reset_epoch":2000000000.0,"claim":"seven_day","why":"rejected"}'
  set_srv a@t.test 200 "$HDR_OK"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -z "$(jex a@t.test reset_epoch)" ] && [ -n "$(jex b@t.test reset_epoch)" ] \
    && ok "B33 the active account answers again -> its stale exhausted entry is cleared (the others are kept)" \
    || bad "B33 current='$(jget "$STATE" current)' a-entry='$(jex a@t.test reset_epoch)' b-entry='$(jex b@t.test reset_epoch)'"

  # ── B36..B43 (gate ga-qmdwdi): the vault is a WITNESS, not the truth; the reset bound; no redirect; lazy vault reads ─────────────
  hide_key() { rm -f "$D/vault/$1"; }
  show_key() { printf '%s' "$(tok_of "$1")" > "$D/vault/$1"; }
  vault_calls() { [ -f "$D/vault/.calls" ] && wc -l < "$D/vault/.calls" | tr -d ' ' || echo 0; }
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
  rearm; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
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

  # ── B45..B49 (gate ga-j6393n): the order of use comes from a usage store that LAGS the clock (the collector runs every ~30 min,
  # this daemon every minute). An expired exhausted entry is the ONLY evidence that an account renewed, so it is never consumed on
  # the strength of that order alone: 'a reading from before the reset' is the third state, not 'does not outrank'. ───────────────
  # usage_store <letter>:<session%>:<weekly%>:<reading> ...  - a store the scenario writes itself (no _selftest_fresh: run_d leaves
  # it alone). reading = the epoch at which the numbers were REAL (last_ok_at) | stale@<epoch> (failed collection, old numbers carried
  # forward, flagged) | nostamp (a good reading with no last_ok_at). An account left out of the arguments has NO ROW.
  usage_store() {
    "$PY3" - "$D/usage.json" "$@" <<'EOF'
import json, sys
from datetime import datetime, timezone
iso = lambda e: datetime.fromtimestamp(float(e), timezone.utc).isoformat()
accts = []; newest = 0.0
for spec in sys.argv[2:]:
    who, sess, week, rd = spec.split(":")
    a = {"email": who + "@t.test", "weekly_all": {"percent": float(week), "resets_at": "203%d-01-01T00:00:00+00:00" % (ord(who) - ord("a"))},
         "session": {"percent": float(sess)}}
    if rd.startswith("stale@"):
        a.update(ok=False, stale=True, last_ok_at=iso(rd[6:]), collected_at=iso(float(rd[6:]) + 1800))
    elif rd == "nostamp":
        a.update(ok=True, stale=False)
    else:
        a.update(ok=True, stale=False, last_ok_at=iso(rd), collected_at=iso(rd)); newest = max(newest, float(rd))
    accts.append(a)
json.dump({"updated_at": iso(newest), "accounts": accts}, open(sys.argv[1], "w"))
EOF
  }
  R=2000000000
  # onb: the world the reviewer reproduced - a seeded, then rejected on its 5h window (reset R) -> the pool is on b, a is in the registry.
  onb() { seeded; set_srv a@t.test 429 "$(hdr_rejected five_hour $R)"; NOW_OVERRIDE=$((R - 3600)) run_d -- run-once; }

  # B45 THE REVIEWER'S SCRIPT. The store was collected while a's 5h window was exhausted (a at session 100% -> banded last, order
  # b,c,a), 10 min BEFORE the reset. The window renews, the daemon ticks 60 s after the reset: the store cannot know that, so a's
  # entry - the only evidence a recovered - must survive the tick (and say it is waiting). The collector then runs (a at 0%, order
  # a,b,c) and the next tick fails back. At ad18b45 the entry was dropped in silence at the first tick and the pool never went back.
  onb
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "rejected" ] && ok "B45a precondition: failed over to b, a registered 'rejected' (reset R)" \
    || bad "B45a precondition: current='$(jget "$STATE" current)' a-why='$(jex a@t.test why)'"
  usage_store a:100:10:$((R - 600)) b:5:10:$((R - 600)) c:5:10:$((R - 600))
  set_srv a@t.test 200 "$HDR_OK"; w0=$(writes); pa0=$(probes_of a@t.test); NOW_OVERRIDE=$((R + 60)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(probes_of a@t.test)" = "$pa0" ] && [ "$(jex a@t.test why)" = "rejected" ] \
    && ok "B45 reset passed, store collected BEFORE it -> a's entry is KEPT (and a is not probed, the pool does not move)" \
    || bad "B45 current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)' writes $w0 -> $(writes)"
  grep -q "waiting for a usage collection of a@t.test taken after its reset" "$LOG" && ok "B45b ...and the log says what it is waiting for" || bad "B45b no 'waiting' line: $(tail -n 3 "$LOG" | tr '\n' '|')"
  usage_store a:0:10:$((R + 600)) b:5:10:$((R + 600)) c:5:10:$((R + 600))
  NOW_OVERRIDE=$((R + 660)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ -z "$(jex a@t.test why)" ] && grep -q "SWITCH b@t.test -> a@t.test.*failback" "$LOG" \
    && ok "B45c the next collection (a at 0%, after the reset) -> the pool goes back to a" \
    || bad "B45c current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) a-entry='$(jex a@t.test why)'"

  # B45d the CONTROL: the same lag, but the old reading says a is healthy (it was taken before a ran out). Ranking by it would fail back
  # at once - and be right by luck. A reading from before the reset says nothing about after it either way: it waits for a collection.
  onb; usage_store a:5:10:$((R - 600)) b:5:10:$((R - 600)) c:5:10:$((R - 600)); set_srv a@t.test 200 "$HDR_OK"; w0=$(writes); NOW_OVERRIDE=$((R + 60)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(jex a@t.test why)" = "rejected" ] \
    && ok "B45d a reading from before the reset that says 'com saldo' is no evidence either: kept, no failback yet" \
    || bad "B45d current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)'"

  # B45e the store collected AFTER the reset, and it ranks a behind the account in use (a still at session 100%): known, so the entry
  # is dropped - and the drop says why (every removal has a line).
  onb; usage_store a:100:10:$((R + 300)) b:5:10:$((R + 300)) c:5:10:$((R + 300)); set_srv a@t.test 200 "$HDR_OK"; w0=$(writes); pa0=$(probes_of a@t.test); NOW_OVERRIDE=$((R + 360)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(probes_of a@t.test)" = "$pa0" ] && [ -z "$(jex a@t.test why)" ] \
    && grep -q "exhausted entry for a@t.test dropped: the usage collected .* ranks it behind b@t.test" "$LOG" \
    && ok "B45e fresh store ranks the recovered a behind b -> entry dropped WITH a log line saying why; no move, no probe" \
    || bad "B45e current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)': $(grep -E 'dropped|waiting' "$LOG" | tail -n 2 | tr '\n' '|')"

  # B45f..h what is not a good reading of THAT account taken after its reset is not evidence, whatever the order says:
  #   f: the collection of a failed (stale / ok=false) - the library bands it 'unknown', the numbers are carried over from before
  #   g: the store has no row for a at all
  #   h: a reading stamped far ahead of the clock (not taken yet: not a time we can compare)
  #   i: a good reading with no last_ok_at
  # In every case the entry is KEPT and the log says why; a would otherwise be failed back to by an order that is guessing.
  for row in 'f|a:5:10:stale@'$((R + 300))' b:5:10:'$((R + 300))' c:5:10:'$((R + 300))'|its last collection failed' \
              'g|b:5:10:'$((R + 300))' c:5:10:'$((R + 300))'|has no row for it' \
              'h|a:5:10:'$((R + 3 * 86400))' b:5:10:'$((R + 300))' c:5:10:'$((R + 300))'|ahead of the clock' \
              'i|a:5:10:nostamp b:5:10:'$((R + 300))' c:5:10:'$((R + 300))'|no usable last_ok_at'; do
    id="${row%%|*}"; rest="${row#*|}"; spec="${rest%|*}"; want="${rest##*|}"
    onb; usage_store $spec; set_srv a@t.test 200 "$HDR_OK"; w0=$(writes); NOW_OVERRIDE=$((R + 360)) run_d -- run-once
    [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(jex a@t.test why)" = "rejected" ] && grep -q "waiting for a usage collection of a@t.test.*$want" "$LOG" \
      && ok "B45$id no good post-reset reading of a ($want) -> entry kept, no failback, the log says why" \
      || bad "B45$id current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)': $(grep -E 'waiting|dropped' "$LOG" | tail -n 1)"
  done

  # B46 two recovered accounts outrank the active one (c), and the write for the first is REFUSED. The failback did not happen, so the one
  # that was not even tried (b) must stay in the registry like the one that failed (a): at ad18b45 b was dropped in silence, only a kept.
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day $R)"; NOW_OVERRIDE=$((R - 3600)) run_d -- run-once                         # a -> b
  rearm; set_srv b@t.test 429 "$(hdr_rejected seven_day $R)"; NOW_OVERRIDE=$((R - 3500)) run_d -- run-once                         # b -> c
  [ "$(jget "$STATE" current)" = "c@t.test" ] && [ -n "$(jex a@t.test reset_epoch)" ] && [ -n "$(jex b@t.test reset_epoch)" ] || bad "B46 precondition: on c, a and b registered (current='$(jget "$STATE" current)')"
  set_srv a@t.test 200 "$HDR_OK"; set_srv b@t.test 200 "$HDR_OK"; touch "$D/kc/refuse-writes"; w0=$(writes); NOW_OVERRIDE=$((R + 60)) run_d -- run-once; rm -f "$D/kc/refuse-writes"
  [ "$(jget "$STATE" current)" = "c@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(jex a@t.test why)" = "rejected" ] && [ "$(jex b@t.test why)" = "rejected" ] \
    && grep -q "failback to a@t.test not done.*the 1 not tried" "$LOG" \
    && ok "B46 write refused for the best recovered account -> BOTH entries stay (the failed one and the one never tried), the log counts the untried" \
    || bad "B46 current='$(jget "$STATE" current)' a='$(jex a@t.test why)' b='$(jex b@t.test why)' writes $w0 -> $(writes): $(grep -E 'failback|dropped' "$LOG" | tail -n 2 | tr '\n' '|')"
  NOW_OVERRIDE=$((R + 120)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ -z "$(jex a@t.test why)" ] && [ -z "$(jex b@t.test why)" ] \
    && grep -q "exhausted entry for b@t.test dropped: recovered, but ranks behind a@t.test, which took the pool" "$LOG" \
    && ok "B46b writes work again -> back on a; b, ranked behind it, is dropped WITH a line saying why" \
    || bad "B46b current='$(jget "$STATE" current)' a='$(jex a@t.test why)' b='$(jex b@t.test why)': $(grep -E 'failback|dropped' "$LOG" | tail -n 2 | tr '\n' '|')"

  # B47 a recovered account whose key does NOT come from the vault this run is kept, not judged.
  onb; hide_key a@t.test; set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=$((R + 60)) run_d -- run-once; show_key a@t.test
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(jex a@t.test why)" = "rejected" ] && grep -q "failback to a@t.test not done: its key did not come from the vault this run" "$LOG" \
    && ok "B47 recovered a, no key from the vault this run -> entry kept for the next run (and the log says so)" \
    || bad "B47 current='$(jget "$STATE" current)' a-entry='$(jex a@t.test why)'"
  # B47b ...and it does not stop the failback: with a and b both recovered and ahead of c, a's missing key leaves a in the registry and the
  # next candidate (b) is still gone back to.
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day $R)"; NOW_OVERRIDE=$((R - 3600)) run_d -- run-once                         # a -> b
  rearm; set_srv b@t.test 429 "$(hdr_rejected seven_day $R)"; NOW_OVERRIDE=$((R - 3500)) run_d -- run-once                         # b -> c
  set_srv a@t.test 200 "$HDR_OK"; set_srv b@t.test 200 "$HDR_OK"; hide_key a@t.test; NOW_OVERRIDE=$((R + 60)) run_d -- run-once; show_key a@t.test
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(jex a@t.test why)" = "rejected" ] && [ -z "$(jex b@t.test why)" ] \
    && ok "B47b a (no key) is kept and the failback goes on to b" \
    || bad "B47b current='$(jget "$STATE" current)' a='$(jex a@t.test why)' b='$(jex b@t.test why)'"

  # B48 nothing leaves the registry in silence. Each way an entry is removed has its own line:
  #  - the active account answered (B33's case)         - a refused key at its time (B32's case)
  # (the others - ranks behind, took the pool, no why - are asserted in B45e / B46b / B32c.)
  seeded; for e in a b c; do set_srv "$e@t.test" 429 "$(hdr_rejected seven_day $R)"; done; NOW_OVERRIDE=$((R - 3600)) run_d -- run-once
  set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=$((R - 3500)) run_d -- run-once
  grep -q "exhausted entry for a@t.test dropped: it answered the probe" "$LOG" && ok "B48 the active account answers -> its entry is dropped WITH a line" || bad "B48 no line: $(grep -E 'dropped' "$LOG" | tail -n 2)"

  # B49 THE POOL ITEM ONLY (Athos 05/10: a setup-token in the default item kills Mayor's / the crews' Remote Control).
  #  1. across a whole failover + failback run, every service name security was asked for - read or write - is the pool's hashed one,
  #     and the only item that exists is that one;
  #  2. the writer itself refuses any service name that is not "Claude Code-credentials-<8 hex>", the bare default one included.
  onb; usage_store a:0:10:$((R + 600)) b:5:10:$((R + 600)) c:5:10:$((R + 600)); NOW_OVERRIDE=$((R + 660)) run_d -- run-once
  svcs="$(grep -o 'Claude Code-credentials[^ ]*' "$D/kc/argv.log" | sort -u)"; wr="$(sed 's/^WRITE //' "$D/kc/writes.log" | sort -u)"; has="$(ls "$D/kc/items")"
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$svcs" = "$SVC" ] && [ "$wr" = "$SVC" ] && [ "$has" = "$SVC" ] \
    && ok "B49 a full failover+failback: security was only ever asked for the pool's hashed item, and only that item exists" \
    || bad "B49 current='$(jget "$STATE" current)' asked-for='$svcs' written='$wr' items='$has' (want '$SVC')"
  new_d
  got="$(env -i "${PIN[@]}" HOME="$D/home" PATH="$BB:/usr/bin:/bin" FAKE_KC="$D/kc" "$PY3" - "$DAEMON" <<'EOF' 2>&1
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.item_service = lambda: "Claude Code-credentials"           # the default item, owned by Mayor and the crews
r1 = m.write_item("athos", "sk-ant-oat01-NEVERWRITTEN")
m.item_service = lambda: "Claude Code-credentials-0123abcz"   # a suffix, but not 8 hex
r2 = m.write_item("athos", "sk-ant-oat01-NEVERWRITTEN")
m.item_service = lambda: "Claude Code-credentials-0123abcd"   # a name in the pool shape: the guard is not a blanket refusal
r3 = m.write_item("athos", "sk-ant-oat01-ALLOWED")
print("RESULT", r1, r2, r3)
EOF
)"
  [ "$(printf '%s' "$got" | tail -n 1)" = "RESULT False False True" ] && [ "$(ls "$D/kc/items")" = "Claude Code-credentials-0123abcd" ] && [ "$(wc -l < "$D/kc/argv.log" | tr -d ' ')" = "1" ] \
    && ok "B49b write_item refuses the default item and any non-8-hex name (security never called for them), and still writes a pool-shaped one" \
    || bad "B49b $(printf '%s' "$got" | tail -n 3 | tr '\n' '|') items='$(ls "$D/kc/items" | tr '\n' '|')' argv-lines=$(wc -l < "$D/kc/argv.log" 2>/dev/null)"

  # B50 the decision cannot be PUBLISHED (full disk, a read-only state dir). decide() has already run, so the pool item may already hold
  # the new account while the file the WhatsApp services read still names the old one. Exit 1 either way, but the log must say WHICH:
  # a bare 'unhandled PermissionError' reads as 'nothing happened' (gate ga-aozw8x). $D holds the state file's directory, and the
  # temp file for the atomic replace is created there, so a read-only $D is exactly 'the state cannot be written'.
  ro_state_run() { # ro_state_run  -> runs the daemon with the state dir read-only; sets rc; prints nothing; skips (rc=skip) if that is not enforceable (root)
    grep -F "wrapper POOL-ACCT SET" "$LOG" > "$W/set-proof.keep" 2>/dev/null; cp "$W/set-proof.keep" "$LOG"; chmod a-w "$D"   # $LOG is also the wrapper's log: its SET lines are the proof a pane is a pool pane
    if ( : > "$D/.rotest" ) 2>/dev/null; then rm -f "$D/.rotest"; chmod u+w "$D"; rc=skip; return 0; fi
    run_d -- run-once; rc=$?; chmod u+w "$D"
  }
  seeded; set_srv a@t.test 429 "$(hdr_rejected five_hour 2000000000)"; ro_state_run
  if [ "$rc" = "skip" ]; then echo "  - B50 skipped: cannot make the state dir read-only for this user (root?)"
  else
    [ "$rc" = "1" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] \
      && ok "B50 publish fails after the failover: exit 1, the item holds b, the published decision still says a" \
      || bad "B50 rc=$rc item=$(item_token | cut -c1-24) published current='$(jget "$STATE" current)'"
    grep -qF "decision NOT published (PermissionError) but the pool item was switched to b@t.test fp=$(fp_of "$TOKEN_b")" "$LOG" \
      && ok "B50b the log says the pool item WAS switched (to whom, which fingerprint) and that the decision file disagrees" \
      || bad "B50b log: $(tail -n 3 "$LOG" | tr '\n' '|')"
    grep -qF "$TOKEN_b" "$LOG" && bad "B50c a token reached the log" || ok "B50c no token in that log"
    # the other branch: the run only recorded exhausted accounts and moved nothing - the line must not claim a switch
    seeded; set_srv a@t.test 429 "$(hdr_rejected five_hour 2000000000)"; set_srv b@t.test 429 "$(hdr_rejected five_hour 2000000000)"
    set_srv c@t.test 429 "$(hdr_rejected five_hour 2000000000)"; ro_state_run
    [ "$rc" = "1" ] && [ "$(item_token)" = "$TOKEN_a" ] \
      && ok "B50d publish fails on a run that moved nothing: exit 1, the item still holds a" || bad "B50d rc=$rc item=$(item_token | cut -c1-24)"
    grep -qF "decision NOT published (PermissionError); this run did not move the pool item to another account" "$LOG" && ! grep -q "was switched to" "$LOG" \
      && ok "B50e ...and the log does not claim a switch" || bad "B50e log: $(tail -n 3 "$LOG" | tr '\n' '|')"
  fi

  # ══ B51..B81 (ga-8hcnvb.2): the switch happens when the limit was HIT, on EVIDENCE from the pool's own panes, by this script alone ══
  # (Athos 04/10: "tem que trocar no 100%. A gente não quer ficar com 5% sem usar" - no preventive threshold, no agent, no credit.)
  #   B51..B54  no evidence / could not look  -> nothing asked, nothing moved      B55..B57  whose panes count at all (never Mayor / crews)
  #   B52       evidence -> failover in the same run, nothing that costs            B53       evidence the account answers -> bounded cost
  #   B60..B66  the Escape: when, to whom, how often, how it is guarded             B67..B69  the bookkeeping behind it
  #   B70       failback by timer and the evidence                                  B71       the whole cycle, with the zero-credit proof
  #   B72       no failback before the stored reset                                  B73..B79  the limit screen after the modal is gone (envelope only)
  #   B80       a pane with no agent name is evidence, never pressed                 B81       a pane that could not be read keeps its bookkeeping
  cat > "$BB/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_KC/claude-invoked"
EOF
  chmod +x "$BB/claude"   # on the daemon's PATH: if anything in it ever ran `claude`, this is what it would reach
  msgs() { nlog "API-CALL messages"; }
  cts() { nlog "API-CALL count_tokens"; }
  later() { local s="$1"; shift; NOW_OVERRIDE=$((NOW_BASE + s)) run_d "$@" -- run-once; }                     # one more run, <s> seconds after the failover
  failed_over() { seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; }   # a rejected, the dog pane on the modal -> the pool is on b
  addressed() { local n=0 c x; for x in "$@"; do c="$(grep -cE -- "-t $x( |\$)" "$TMUXD/calls.log" 2>/dev/null)"; n=$((n + ${c:-0})); done; echo "$n"; }   # tmux calls aimed at those panes
  pane_tries() { "$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted(e.get("tries") for e in d.get("panes", {}).values()))' "$STATE" 2>/dev/null; }

  # B51 NO EVIDENCE, NO MESSAGES CALL. a is rejected on the server, but no pool session is on the limit modal (nobody is working, the
  # modal is only QUOTED in a transcript, the prompt is back after an Escape with the old 'hit your limit' line still above it, the only
  # modal is on a pane the wrapper never launched onto the item, or there is no pane at all): the evidence probe (a messages call, the
  # only one that can cost) is not made, nothing moves, no key. What IS asked, every run, is the free key check (count_tokens): a's 429
  # there is 'cannot tell' - a limit is not a refused key - so it moves nothing either. (Counted separately: pa0 = billed-capable calls,
  # pr0 = every hit on the mock, the key checks included - exactly one per run.)
  for kind in none working quoted prompt nonpool; do
    new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once
    case "$kind" in none) ;; nonpool) pane_add gastown.dog-2 modal; unset_line "$PANE_PID" ;; *) pane_add gastown.dog-2 "$kind" ;; esac
    set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; w0=$(writes); pa0=$(msg_probes_of a@t.test); pr0=$(probes_of a@t.test)
    run_d -- run-once; later 60; later 120
    extra=1
    case "$kind" in
      none) [ ! -e "$TMUXD/calls.log" ] || extra=0 ;;                                                        # nothing follows the item: tmux is not even asked
      nonpool) [ "$(addressed "$PANE")" = "0" ] || extra=0 ;;   # ...and a pane that is not the pool's is not even looked at
    esac
    [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ "$(msg_probes_of a@t.test)" = "$pa0" ] \
      && [ "$(( $(probes_of a@t.test) - pr0 ))" = "3" ] && [ "$(msgs)" = "0" ] && [ "$(keys_sent)" = "0" ] && [ "$extra" = "1" ] \
      && ok "B51 ($kind) a is rejected but no pool session is on the limit modal -> no messages call (only the free key check, once a run), no switch, no key (3 runs)" \
      || bad "B51 ($kind): current='$(jget "$STATE" current)' messages-capable calls of a $pa0 -> $(msg_probes_of a@t.test), hits $pr0 -> $(probes_of a@t.test) (want +3) messages-calls=$(msgs) keys=$(keys_sent) extra=$extra"
  done
  # B51e 100%, not before: the usage store ranks a LAST (session 100%, week 99%) and the key is still accepted - without the modal it is
  # not a reason to move (the old preventive design moved at 95%).
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 working
  usage_store a:100:99:$((NOW_BASE - 1)) b:5:10:$((NOW_BASE - 1)) c:5:10:$((NOW_BASE - 1)); w0=$(writes); run_d -- run-once; run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(item_token)" = "$TOKEN_a" ] && [ "$(writes)" = "$w0" ] && [ "$(msgs)" = "0" ] \
    && ok "B51e a at 99%/100% of its windows but nobody on the modal -> no switch: the pool moves when the limit is HIT, not before" \
    || bad "B51e current='$(jget "$STATE" current)' writes $w0 -> $(writes) messages-calls=$(msgs)"

  # B52 EVIDENCE -> one question to the account in use; rejected (free) -> the pool item moves in the same run; nothing that costs.
  seeded; m0=$(msgs); c0=$(cts); w0=$(writes); pa0=$(probes_of a@t.test); pb0=$(probes_of b@t.test); pc0=$(probes_of c@t.test)
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$((w0 + 1))" ] \
    && ok "B52 a pool session on the limit modal + a rejected -> the pool item holds b after ONE run, with no human and no restart" \
    || bad "B52 current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) writes $w0 -> $(writes)"
  [ "$(msgs)" = "$((m0 + 1))" ] && [ "$(cts)" = "$((c0 + 1))" ] && [ "$(probes_of a@t.test)" = "$((pa0 + 1))" ] && [ "$(probes_of b@t.test)" = "$((pb0 + 1))" ] && [ "$(probes_of c@t.test)" = "$pc0" ] \
    && ok "B52b exactly two calls: the evidence probe of a (a rejection), and the KEY check of b (count_tokens, not billed); c was never asked" \
    || bad "B52b messages $m0 -> $(msgs), count_tokens $c0 -> $(cts), probes a $pa0 -> $(probes_of a@t.test) b $pb0 -> $(probes_of b@t.test) c $pc0 -> $(probes_of c@t.test)"
  [ "$(served)" = "0" ] && [ ! -e "$D/kc/claude-invoked" ] && [ "$(keys_sent)" = "0" ] \
    && ok "B52c the zero-credit proof for the switch: the API SERVED nothing (the one messages call was a 429), no claude was ever run, no key sent in the run that rewrote the item" \
    || bad "B52c served=$(served) claude-invoked=$(cat "$D/kc/claude-invoked" 2>/dev/null | head -c 80) keys=$(keys_sent)"
  grep -q "EVIDENCE: 1 pool pane(s) on the limit modal (gastown.dog-2)" "$LOG" && grep -q "SWITCH a@t.test -> b@t.test.*failover: a@t.test rejected" "$LOG" \
    && ok "B52d the log names the evidence (which sessions) and the switch (from, to, why)" || bad "B52d log: $(grep -E 'EVIDENCE|SWITCH' "$LOG" | tail -n 2 | tr '\n' '|')"
  # B52e the daemon cannot run claude: no subprocess call in its source names it (the stub above is the dynamic half of this)
  n="$(grep -E 'subprocess\.(run|Popen|call|check_output|check_call)\(|os\.system|shell *= *True' "$DAEMON" | grep -ciE 'claude|anthropic')"
  [ "$n" = "0" ] && ok "B52e no subprocess call in the daemon names claude (it runs security, ps and tmux, nothing else)" || bad "B52e $n subprocess line(s) mention claude"
  # B52f twenty-five sessions on the modal cost ONE question, not twenty-five
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; for i in $(seq 1 25); do pane_add "gastown.dog-$i" modal; done
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(msgs)" = "1" ] \
    && ok "B52f 25 pool sessions on the modal -> ONE evidence probe, one switch" || bad "B52f current='$(jget "$STATE" current)' messages-calls=$(msgs)"

  # B53 evidence the account ANSWERS (the screen is about another limit, a modal about to go away...): nothing moves, no key, and the
  # cost is bounded - a served call is a few tokens, at most once per cooldown per screen; a NEW screen is asked about at once.
  seeded; pa0=$(msg_probes_of a@t.test); w0=$(writes); run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(msg_probes_of a@t.test)" = "$((pa0 + 1))" ] && [ "$(writes)" = "$w0" ] && [ "$(keys_sent)" = "0" ] \
    && grep -q "answers - the limit modal on screen is not about this account" "$LOG" \
    && ok "B53 modal on screen but a ANSWERS -> one probe, no switch, no key, and the log says the screen is not about this account" \
    || bad "B53 current='$(jget "$STATE" current)' probes of a $pa0 -> $(msg_probes_of a@t.test) keys=$(keys_sent)"
  run_d -- run-once; later 599; p1=$(msg_probes_of a@t.test)
  [ "$p1" = "$((pa0 + 1))" ] && ok "B53b the same screen is not asked about again inside the cooldown (600 s): still 1 probe" || bad "B53b probes of a: $pa0 -> $p1"
  later 601; p2=$(msg_probes_of a@t.test)
  [ "$p2" = "$((pa0 + 2))" ] && ok "B53c ...and once the cooldown has passed it is asked again (2)" || bad "B53c probes of a: $pa0 -> $p2"
  rearm; NOW_OVERRIDE=$((NOW_BASE + 602)) run_d -- run-once
  [ "$(msg_probes_of a@t.test)" = "$((pa0 + 3))" ] && [ "$(keys_sent)" = "0" ] && ok "B53d a NEW screen is evidence at once, whatever was answered about the old one (3); and no key through any of it" || bad "B53d probes of a: $pa0 -> $(msg_probes_of a@t.test) keys=$(keys_sent)"
  for cd in 0 abc -5 nan 999999; do
    seeded; pa0=$(msg_probes_of a@t.test); run_d CLAUDE_POOL_EVIDENCE_COOLDOWN_S=$cd -- run-once; run_d CLAUDE_POOL_EVIDENCE_COOLDOWN_S=$cd -- run-once
    case "$cd" in 0) want=2 ;; *) want=1 ;; esac
    [ "$(( $(msg_probes_of a@t.test) - pa0 ))" = "$want" ] && ok "B53e CLAUDE_POOL_EVIDENCE_COOLDOWN_S=$cd -> $want probe(s) in two runs (0 = every run; junk/out of range = the default 600 s)" \
      || bad "B53e cooldown=$cd: probes of a $pa0 -> $(msg_probes_of a@t.test) (want +$want)"
  done

  # B54 COULD NOT LOOK concludes nothing about the limit screens: not 'no evidence' (which allows a failback), not 'evidence' (which makes
  # the evidence probe), no key. (The free key check of the active credential is not about the panes and still runs: B17e.)
  for how in down no-binary; do
    seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; w0=$(writes); pa0=$(msg_probes_of a@t.test)
    if [ "$how" = "down" ]; then touch "$TMUXD/down"; run_d -- run-once; else run_d CLAUDE_POOL_TMUX="$W/no-such-tmux" -- run-once; fi
    [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(msg_probes_of a@t.test)" = "$pa0" ] && [ "$(msgs)" = "0" ] && [ "$(keys_sent)" = "0" ] \
      && grep -q "the pool's panes could not be looked at this run - nothing concluded" "$LOG" \
      && ok "B54 tmux $how -> panes could not be looked at: no evidence probe, nothing moved, no key - and the log says so" \
      || bad "B54 ($how) current='$(jget "$STATE" current)' writes $w0 -> $(writes) messages-calls=$(msgs): $(tail -n 2 "$LOG" | tr '\n' '|')"
    rm -f "$TMUXD/down"; run_d -- run-once
    [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B54b ...and when it can look again the modal that was there all along is found, and the pool moves" || bad "B54b ($how) current='$(jget "$STATE" current)'"
  done
  seeded; pa0=$(msg_probes_of a@t.test); run_d -- run-once; s0="$(jget "$STATE" panes)"; touch "$TMUXD/down"; run_d -- run-once; s1="$(jget "$STATE" panes)"; rm -f "$TMUXD/down"; run_d -- run-once
  [ "$s0" = "$s1" ] && [ -n "$s0" ] && [ "$(msg_probes_of a@t.test)" = "$((pa0 + 1))" ] \
    && ok "B54c a run that could not look leaves the bookkeeping as it was: the screen a answered about is not asked about again afterwards" || bad "B54c panes '$s0' / '$s1', probes of a $pa0 -> $(msg_probes_of a@t.test)"
  # B54d the wrapper's log is there but cannot be READ -> could not look (None); no log at all -> nothing follows the item ({}), and says so.
  # Then WHO is in the launches: the REAL names of this town (city.toml), not invented ones - the pool roles are in, Mayor and every crew are
  # out (and counted in `off`), a name that is no name is out, and the wrapper's own "?" (GC_AGENT unset) is in as evidence that is never pressed.
  mkdir -p "$W/plcity/.gc/logs"; rm -f "$W/plcity/.gc/logs/claude-pool-account.log"
  cat > "$W/py_launches.py" <<'EOF'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
p = sys.argv[2]; bad = []
logs = []; m.log = lambda lvl, msg: logs.append(msg)   # the log IS the file under test: nothing may be appended to it while it is read
DUE = 600 * 3331667.0
m.now = lambda: DUE + 60                                # a quiet clock minute
if m.pool_launches() != {}: bad.append("no file -> not {}")
if logs: bad.append(f"a quiet minute logged: {logs}")
m.now = lambda: DUE                                     # a due one: the missing log is SAID
if m.pool_launches() != {} or not any("no pool launch read: the wrapper's log is not there yet" in x for x in logs): bad.append(f"no file on a due minute: logs={logs}")
logs.clear(); c = os.environ.pop("GC_CITY_PATH")        # no city at all reads the same way - and is said the same way
if m.pool_launches() != {} or not any("no pool launch read: no city is set" in x for x in logs): bad.append(f"no city on a due minute: logs={logs}")
os.environ["GC_CITY_PATH"] = c
os.mkdir(p)                                             # a directory where the file should be: open() fails, and it is not 'not found'
if m.pool_launches() is not None: bad.append("unreadable log -> not None")
os.rmdir(p)
IT = m.item_service()
POOL = ["gastown.dog-1", "gastown.dog-12", "wa-worker-adhoc-k1x9", "ps-worker", "gate-reviewer-adhoc-ab12cd", "refino-gate-reviewer-adhoc-ef34",
        "auto-refiner-adhoc-gh56", "context-check-reviewer", "gastown.boot", "gastown.deacon"]
OFF = ["gastown.mayor", "oracle-wa", "oracle-wa-ga25kuos", "mila-wa", "thies-wa", "batista-wa", "peter-wa", "digo-wa", "a/Crew", "gastown.dogs",
       "wa-workers", "gate-reviewers", "gastown.dog-", "gastown.dog-x/y", "we!rd", "mayor", "gastown.crew-1", "claude-rc", ""]
lines, pid, want, wantoff = [], 100, {}, []
for n in POOL + ["?"]:
    pid += 1; want[pid] = n; lines.append(f"2033-05-18T03:33:{pid % 60:02d}Z pid={pid} agent={n} wrapper POOL-ACCT SET item={IT}")
for n in OFF:
    pid += 1; wantoff.append(pid); lines.append(f"2033-05-18T03:33:{pid % 60:02d}Z pid={pid} agent={n} wrapper POOL-ACCT SET item={IT}")
lines.append("2033-05-18T03:33:23Z pid=80 agent=gastown.dog-2 wrapper POOL-ACCT SET item=Claude Code-credentials-deadbeef")   # another item
lines.append(f"2033-05-18T03:33:24Z pid=81 agent=gastown.dog-2 wrapper POOL-ACCT SKIP item={IT}")                              # not a SET
open(p, "w").write("\n".join(lines) + "\n")
off = {}
got = m.pool_launches(off)
if {k: v[1] for k, v in got.items()} != want: bad.append(f"allowed: {sorted((k, v[1]) for k, v in got.items())} != {sorted(want.items())}")
if sorted(off) != wantoff: bad.append(f"off-list pids {sorted(off)} != {wantoff}")
if sorted(m.pool_launches()) != sorted(want): bad.append("without `off` the answer differs")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$(env -i "${PIN[@]}" HOME="$W/home" GC_CITY_PATH="$W/plcity" CLAUDE_POOL_CRED_DIR="$POOL_DIR" "$PY3" "$W/py_launches.py" "$DAEMON" "$W/plcity/.gc/logs/claude-pool-account.log" 2>&1)"
  [ "$got" = "OK" ] && ok "B54d no wrapper log -> {} and SAID on a due minute (also with no city); unreadable log -> None; only a SET line for THIS item counts; the 10 pool roles + '?' are in, Mayor (gastown.mayor) and every real crew name (oracle-wa, mila-wa, thies-wa, batista-wa, peter-wa, digo-wa) are out and counted" \
    || bad "B54d pool_launches -> $got"

  # B55 MAYOR AND THE CREWS are never looked at, never counted as evidence and never pressed (Athos 05/10: their Remote Control must not
  # be disturbed) - whatever their screen says and even if their launch line said they follow the pool item. REAL names: gastown.mayor, and the
  # crews, which share no stem with the word "crew" (oracle-wa, mila-wa, thies-wa, batista-wa, peter-wa, digo-wa, a session-suffixed one).
  OTHERS="gastown.mayor oracle-wa oracle-wa-ga25kuos mila-wa thies-wa batista-wa peter-wa digo-wa weird/mayor hq/Crew-x gastown.dogs"
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once
  others=(); for nm in $OTHERS; do pane_add "$nm" modal; others+=("$PANE"); done
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; w0=$(writes); run_d -- run-once; later 60; later 120
  touched=$(addressed "${others[@]}")
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(msgs)" = "0" ] && [ "$(keys_sent)" = "0" ] && [ "$touched" = "0" ] \
    && ok "B55 Mayor and 7 crews (real names) + 3 odd names on the modal (their launch lines even say SET) are no evidence, are not even looked at, and get no key" \
    || bad "B55 current='$(jget "$STATE" current)' messages-calls=$(msgs) keys=$(keys_sent) tmux-calls-addressed-to-them=$touched"
  # B55b ...and with a real pool session on the modal among them: the pool moves, and the one key goes to the pool session alone.
  seeded; dog1=$PANE
  pane_add gastown.dog-3 working; pane_add gastown.dog-4 quoted; pane_add gastown.dog-5 prompt
  others=(); for nm in $OTHERS; do pane_add "$nm" modal; others+=("$PANE"); done
  pane_add gastown.dog-9 modal; nopool=$PANE; unset_line "$PANE_PID"
  touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; later 120
  touched=$(addressed "${others[@]}" "$nopool")
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(keys_sent)" = "1" ] && [ "$(keys_to "$dog1")" = "1" ] && [ "$touched" = "0" ] \
    && ok "B55b one pool session on the modal among 15 panes (Mayor, crews, a stranger, a working one...) -> the pool moves and the ONE Escape goes to that session" \
    || bad "B55b current='$(jget "$STATE" current)' keys=$(keys_sent) to-dog=$(keys_to "$dog1") tmux-calls-addressed-to-the-others=$touched: $(cat "$TMUXD/keys.log" 2>/dev/null | tr '\n' '|')"
  # B55c the other side of the same list: every role of the claude-headless pool IS looked at and unstuck - a list that is too tight would
  # make a pool session wait for a human. One Escape each, to its own pane, and nobody else's.
  ROLES="gastown.dog-1 wa-worker-adhoc-k1x9 ps-worker gate-reviewer-adhoc-ab12cd refino-gate-reviewer-adhoc-ef34 auto-refiner-adhoc-gh56 context-check-reviewer gastown.boot gastown.deacon"
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once
  roles=(); for nm in $ROLES; do pane_add "$nm" modal; roles+=("$PANE"); done
  others=(); for nm in $OTHERS; do pane_add "$nm" modal; others+=("$PANE"); done
  touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; later 120
  each=0; for r in "${roles[@]}"; do [ "$(keys_to "$r")" = "1" ] && each=$((each + 1)); done
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$each" = "9" ] && [ "$(keys_sent)" = "9" ] && [ "$(addressed "${others[@]}")" = "0" ] \
    && ok "B55c the 9 pool roles on the modal -> the pool moves, ONE Escape to each of them (9 in all) and none to the 11 Mayor/crew/odd panes beside them" \
    || bad "B55c current='$(jget "$STATE" current)' roles-with-one-key=$each keys=$(keys_sent) others-touched=$(addressed "${others[@]}"): $(cat "$TMUXD/keys.log" 2>/dev/null | tr '\n' '|')"
  # B55d a pool role that is not on the list yet (a new template) is not silent: it is counted in the log, on a due minute, by name.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add brand-new-worker modal
  NOW_OVERRIDE=$T10 run_d -- run-once
  grep -q "live process(es) on the pool item with an agent name that is no pool role (brand-new-worker) - not looked at, no Escape; a new pool role belongs in POOL_AGENT_RE" "$LOG" && [ "$(keys_sent)" = "0" ] \
    && ok "B55d a live session of a role the list does not know is not looked at and gets no key - and the log names it, so the gap is visible" \
    || bad "B55d no off-list line: $(grep -E 'pane scan|no pool role' "$LOG" | tail -n 2 | cut -c1-200 | tr '\n' '|')"

  # B56 what makes a pane a POOL pane: the wrapper's SET line for the item, for a pid that is alive and STARTED when the line says.
  # Each of these has a modal on screen and a rejected a, and none is evidence (B52 is the positive control for the same world).
  for how in other-item recycled-pid late-line dead-process dead-pane; do
    new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once
    case "$how" in
      other-item) SET_ITEM="Claude Code-credentials-deadbeef" pane_add gastown.dog-2 modal ;;                  # launched onto ANOTHER item
      recycled-pid) pane_add gastown.dog-2 modal -3600 ;;                                                       # the line is an hour older than this process: it is another one's
      late-line) pane_add gastown.dog-2 modal 300 ;;                                                            # the process started minutes before the line that claims it
      dead-process) pane_add gastown.dog-2 modal; kill "$PANE_PID"; wait "$PANE_PID" 2>/dev/null ;;
      dead-pane) pane_add gastown.dog-2 modal; sed -i '' 's/ 0$/ 1/' "$TMUXD/panes.txt" ;;
    esac
    set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; w0=$(writes); run_d -- run-once; later 60
    [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(msgs)" = "0" ] && [ "$(keys_sent)" = "0" ] \
      && ok "B56 ($how) not proven to be a pool session -> not evidence, no probe, no key" \
      || bad "B56 ($how) current='$(jget "$STATE" current)' messages-calls=$(msgs) keys=$(keys_sent)"
  done
  # B56b the positive controls of the proof: claude may be a DESCENDANT of the pane's process (the wrapper's shell), and a line whose
  # second is a little BEFORE the process start (both are whole seconds) is still that process.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add_child gastown.dog-2 modal
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B56b claude is a child of the pane's process -> the pane is found through its ancestors, and it is evidence" || bad "B56b current='$(jget "$STATE" current)'"

  # B60 THE ESCAPE. After a failover the session that was on the modal is on the REPLACED credential's modal; it does not notice the new
  # one by itself. Nothing is pressed in the run that rewrites the item, nor before claude has had time to re-read it (45 s: it
  # re-reads every ~30 s); then ONE Escape, to that session, and the prompt is back.
  failed_over; touch "$TMUXD/clear-on-esc"; w0=$(writes); k0=$(keys_sent)
  later 30; k30=$(keys_sent)
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$k0" = "0" ] && [ "$k30" = "0" ] && grep -q "waiting 45 s for claude to re-read it before sending Escape" "$LOG" \
    && ok "B60 no key in the run that rewrote the item, none 30 s later - the log says it is waiting for claude to re-read the item" || bad "B60 keys $k0 / $k30 current='$(jget "$STATE" current)'"
  later 60; k60=$(keys_sent); later 120; k120=$(keys_sent)
  [ "$k60" = "1" ] && [ "$(keys_to "$PANE")" = "1" ] && [ "$k120" = "1" ] && [ "$(writes)" = "$w0" ] && grep -q "UNSTICK: Escape sent to pane $PANE (gastown.dog-2)" "$LOG" \
    && grep -q '? for shortcuts' "$TMUXD/screen.${PANE#%}" \
    && ok "B60b 60 s after the rewrite: ONE Escape to that pool session (the prompt is back), and not again; the item is not written again" \
    || bad "B60b keys 60s=$k60 120s=$k120 to-pane=$(keys_to "$PANE") writes $w0 -> $(writes): $(grep -E 'UNSTICK|waiting' "$LOG" | tail -n 2 | tr '\n' '|')"
  # B60c an Escape that does not take is not repeated for ever: 3 tries per pane, counted in the state.
  failed_over; for s in 60 120 180 240 300; do later $s; done
  [ "$(keys_sent)" = "3" ] && [ "$(pane_tries)" = "[3]" ] && [ "$(nlog "UNSTICK: Escape sent")" = "3" ] \
    && ok "B60c the modal does not go away -> 3 Escapes in 5 runs, then no more (tries=3 in the state)" || bad "B60c keys=$(keys_sent) tries=$(pane_tries)"
  # B60d the off switches: the env var and the file stop the keys (and spend no try); the general kill switch stops the whole run.
  failed_over; later 60 GC_POOL_UNSTICK=0; later 120 GC_POOL_UNSTICK=0; k1=$(keys_sent)
  touch "$D/city/.gc/no-pool-unstick"; later 180; k2=$(keys_sent)
  grep -q "unstick disabled by GC_POOL_UNSTICK=0 - no key sent" "$LOG" && grep -q "unstick disabled by .*no-pool-unstick - no key sent" "$LOG" && [ "$k1" = "0" ] && [ "$k2" = "0" ] \
    && ok "B60d GC_POOL_UNSTICK=0 and .gc/no-pool-unstick each stop the Escape (and the log says which)" || bad "B60d keys $k1 / $k2: $(grep -E 'disabled' "$LOG" | tail -n 2 | tr '\n' '|')"
  later 240 GC_POOL_ACCOUNT=0; k3=$(keys_sent); rm -f "$D/city/.gc/no-pool-unstick"; later 300; k4=$(keys_sent)
  [ "$k3" = "0" ] && [ "$k4" = "1" ] && ok "B60e GC_POOL_ACCOUNT=0 stops the whole run, keys included; and with the switches off, no try was spent: the Escape goes out once they are on again" || bad "B60e keys $k3 / $k4"

  # B61 the Escape is re-verified IMMEDIATELY before it is sent (the scan is some seconds old): the pane must still hold the same
  # process, and the modal must still be the last thing on its screen.
  failed_over; echo 424242 > "$TMUXD/pid2.${PANE#%}"; later 60
  [ "$(keys_sent)" = "0" ] && grep -q "is not the process it was a moment ago - nothing sent" "$LOG" && ok "B61 the pane's process changed between the scan and the key -> no key" || bad "B61 keys=$(keys_sent): $(tail -n 2 "$LOG" | tr '\n' '|')"
  failed_over; printf '%s\n' "$PROMPT_SCREEN" > "$TMUXD/screen2.${PANE#%}"; later 60
  [ "$(keys_sent)" = "0" ] && grep -q "no longer shows the limit modal - nothing sent" "$LOG" && ok "B61b the modal went away between the scan and the key -> no key" || bad "B61b keys=$(keys_sent): $(tail -n 2 "$LOG" | tr '\n' '|')"
  failed_over; touch "$TMUXD/send-fails"; later 60
  [ "$(keys_sent)" = "0" ] && [ "$(pane_tries)" = "[1]" ] && grep -q "tmux send-keys failed" "$LOG" && ok "B61c send-keys fails -> reported, the try is spent (1), nothing breaks" || bad "B61c keys=$(keys_sent) tries=$(pane_tries)"

  # B62 only the item that holds the decision's credential, settled, not exhausted: otherwise no key.
  failed_over; touch "$TMUXD/clear-on-esc"; item_set "$TOKEN_c"; later 60; k1=$(keys_sent); k1i=$(item_token); later 90; k2=$(keys_sent); later 120; k3=$(keys_sent)
  [ "$k1i" = "$TOKEN_b" ] && [ "$k1" = "0" ] && [ "$k2" = "0" ] && [ "$k3" = "1" ] \
    && ok "B62 the item was rewritten AGAIN (healed back to b at 60 s) -> the wait starts over: no key at 60 s nor 90 s, one at 120 s" || bad "B62 item=$(item_token | cut -c1-24) keys $k1 / $k2 / $k3"
  failed_over; touch "$TMUXD/clear-on-esc" "$D/kc/locked"; later 60; k1=$(keys_sent); rm -f "$D/kc/locked"; later 120; k2=$(keys_sent)
  [ "$k1" = "0" ] && [ "$k2" = "1" ] && grep -q "the pool item could not be read - no Escape sent" "$LOG" \
    && ok "B62b the item cannot be read (locked keychain) -> no key; the next run that can read it sends it" || bad "B62b keys $k1 / $k2: $(grep -E 'Escape' "$LOG" | tail -n 2 | tr '\n' '|')"
  failed_over; edit_state 'st.setdefault("exhausted", {})["b@t.test"] = {"reset_epoch": 2000000000.0, "claim": "seven_day", "seen": 1.0, "why": "rejected"}'; later 60
  [ "$(keys_sent)" = "0" ] && grep -q "b@t.test is registered as exhausted - no Escape into it" "$LOG" \
    && ok "B62c the account the item holds is itself registered exhausted -> no key (it would land on the modal again)" || bad "B62c keys=$(keys_sent): $(grep -E 'Escape|exhausted' "$LOG" | tail -n 2 | tr '\n' '|')"
  # B62d the guard that the item holds the DECISION'S credential, tested where heal cannot run first: heal would put b back (B62), and
  # editing the decision's fingerprint instead is healed too (the daemon re-derives it from the vault). So the item holds another
  # credential AND the write that would repair it is refused: only the guard is left between that item and a key.
  failed_over; touch "$D/kc/refuse-writes"; item_set "$TOKEN_c"; later 60; k1=$(keys_sent); k1i=$(item_token); rm -f "$D/kc/refuse-writes"
  [ "$k1" = "0" ] && [ "$k1i" = "$TOKEN_c" ] && grep -q "does not hold the credential of the decision - no Escape sent" "$LOG" \
    && ok "B62d the item holds another credential and cannot be put back -> no key, and the log says why" || bad "B62d keys=$k1 item=$(printf '%s' "$k1i" | cut -c1-24): $(tail -n 3 "$LOG" | tr '\n' '|')"

  # B63 at most 20 keys in a run: a burst is never unbounded (25 sessions were on the modal; each Escape clears its screen).
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; for i in $(seq 1 25); do pane_add "gastown.dog-$i" modal; done
  touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; k1=$(keys_sent); later 120; k2=$(keys_sent)
  [ "$k1" = "20" ] && [ "$k2" = "25" ] && grep -q "20 Escapes sent this run - the rest wait for the next one" "$LOG" \
    && ok "B63 25 pool sessions stuck -> 20 Escapes in one run, the other 5 in the next" || bad "B63 keys $k1 / $k2"

  # B64 the clock is the REAL one here (the rewrite is 'now'): a session that STARTED after the rewrite never had the old credential, so
  # its modal is evidence at once; one that was already running and is first seen within 90 s of the rewrite is on the old credential's.
  new_d; NOW_OVERRIDE= run_d -- run-once; sleep 2; pane_add gastown.dog-2 modal
  set_srv a@t.test 429 "$(hdr_rejected seven_day $(( $(date +%s) + 7200 )))"; NOW_OVERRIDE= run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(msgs)" = "1" ] \
    && ok "B64 a session launched AFTER the rewrite and on the modal 2 s later -> evidence: it was asked, and the pool moved" || bad "B64 current='$(jget "$STATE" current)' messages-calls=$(msgs)"
  new_d; pane_add gastown.dog-2 modal; NOW_OVERRIDE= run_d -- run-once
  set_srv a@t.test 429 "$(hdr_rejected seven_day $(( $(date +%s) + 7200 )))"; NOW_OVERRIDE= run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(msgs)" = "0" ] \
    && ok "B64b a session that was already running (launched before the rewrite) and first seen on the modal right after it -> the OLD credential's modal: no probe" || bad "B64b current='$(jget "$STATE" current)' messages-calls=$(msgs)"

  # B65 the stale-modal rule itself, as a table (item rewritten at 1000): stale iff launched <= rewrite AND first seen <= rewrite + 90 s.
  cat > "$W/py_stale.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
bad = []
B = 2000000000   # item_at is only believed inside MIN_EPOCH..MAX_EPOCH: the table is relative to a real epoch
def stale(item_at, launched, first):
    p = m.PanePeek("%1", 1, 2, "gastown.dog-2", True, B + launched)
    return m.stale_modal({"item_at": item_at}, p, {"first": B + first, "tries": 0})
for launched, first, want in [(900, 1000, True), (900, 1090, True), (900, 1091, False), (1000, 1000, True), (1001, 1000, False), (1001, 1091, False), (500, 5000, False)]:
    got = stale(B + 1000.0, launched, first)
    if got != want: bad.append(f"launched={launched} first={first} -> {got} (want {want})")
for junk in (None, "x", float("nan"), -5, 0, True):
    if stale(junk, 900, 1000): bad.append(f"item_at={junk!r} counted as a rewrite")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$("$PY3" "$W/py_stale.py" "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B65 stale_modal: stale iff launched <= rewrite and first seen <= rewrite+90 s (edges included); no usable rewrite time = nothing is stale" || bad "B65 $got"

  # B66 the screen recogniser, as a table: only the LAST lines of the screen count, and only the modal in full.
  cat > "$W/py_modal.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
Q = " What do you want to do?\n\n ❯ 1. Stop and wait for limit to reset\n   2. Wait here, then continue automatically at Oct 7 at 7pm\n   3. Upgrade your plan\n\n"
F = " Enter to confirm · Esc to cancel"
cases = [
  ("the modal", "● work\n" + Q + F, True),
  ("trailing blank lines and spaces", "● work\n" + Q + F + "   \n\n\n", True),
  ("no footer", Q, False),
  ("footer first", F + "\n" + Q, False),
  ("option before the question", " ❯ 1. Stop and wait for limit to reset\n What do you want to do?\n" + F, False),
  ("question, no option", " What do you want to do?\n" + F, False),
  ("option, no question", " ❯ 1. Stop and wait for limit to reset\n" + F, False),
  ("quoted, prompt box below", "● quote:\n" + Q + F + "\n╭────╮\n│ >  │\n╰────╯\n  ? for shortcuts", False),
  ("the limit line and a prompt", "  You've hit your weekly limit · resets Oct 7, 7pm\n╭────╮\n│ >  │\n╰────╯", False),
  ("empty", "", False), ("blank", "\n\n   \n", False),
]
bad = [f"{n}: {m.modal_stuck(t)} (want {w})" for n, t, w in cases if m.modal_stuck(t) != w]
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$("$PY3" "$W/py_modal.py" "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B66 modal_stuck: the full modal at the END of the screen only - quoted, scrolled-up, partial and prompt-with-old-limit-line screens are not it" || bad "B66 $got"

  # B67 the pane bookkeeping in the state file is a witness, not a command: every wrong shape is dropped or read as 'already tried'.
  cat > "$W/py_sanitize.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
t = 2000000000.0; bad = []
st = {"panes": {"ok": {"first": t - 10, "tries": 1}, "badfirst": {"first": "x", "tries": 0}, "future": {"first": t + 99999, "tries": 0},
                "neg": {"first": t - 5, "tries": -1}, "bool": {"first": t - 5, "tries": True}, "str": {"first": t - 5, "tries": "0"},
                "none": {"first": t - 5}, "askfuture": {"first": t - 5, "tries": 0, "asked": t + 99999}, "askok": {"first": t - 5, "tries": 0, "asked": t - 7},
                "notdict": 5},
      "item_at": t + 99999, "evidence_probe": {"a@t.test": t}}
m.sanitize_state(st, t)
p = st.get("panes", {})
if sorted(p) != ["askfuture", "askok", "bool", "neg", "none", "ok", "str"]: bad.append(f"kept {sorted(p)}")
for k in ("neg", "bool", "str", "none"):
    if p.get(k, {}).get("tries") != m.MAX_ESC_TRIES: bad.append(f"{k}: tries={p.get(k, {}).get('tries')!r} (want {m.MAX_ESC_TRIES}: garbled = already tried)")
if p.get("ok", {}).get("tries") != 1: bad.append("a good entry was changed")
if "asked" in p.get("askfuture", {}): bad.append("an 'asked' in the future was kept")
if p.get("askok", {}).get("asked") != t - 7: bad.append("a good 'asked' was dropped")
if "item_at" in st: bad.append("an item_at in the future was kept")
if "evidence_probe" in st: bad.append("the old per-account bookkeeping was kept")
for shape in (None, [], "x", 5, True):
    st = {"panes": shape}; m.sanitize_state(st, t)
    if "panes" in st: bad.append(f"panes={shape!r} kept")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$("$PY3" "$W/py_sanitize.py" "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B67 sanitize_state: garbled pane marks are dropped, garbled 'tries' read as already tried (junk never buys a fresh Escape), a future item_at is no rewrite" || bad "B67 $got"
  # B67b ...end to end: a state whose tries are junk never gets a key
  failed_over; edit_state 'st["panes"][list(st["panes"])[0]]["tries"] = "0"'; later 60; later 120
  [ "$(keys_sent)" = "0" ] && ok "B67b tries='0' (a string) in the state file -> read as already tried: no key" || bad "B67b keys=$(keys_sent)"

  # B68 a failure INSIDE the unstick step must not cost the decision: the item was already rewritten by the time it runs, and the
  # published decision (what the WhatsApp services read) must follow it.
  cat > "$W/break_escape.py" <<'EOF'
import importlib.util, os, sys
sp = importlib.util.spec_from_file_location("d", os.environ["REAL_DAEMON"]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def boom(p): raise RuntimeError("selftest: send_escape blew up")
m.send_escape = boom
sys.exit(m.main(["x", "run-once"]))
EOF
  seeded; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; DAEMON="$W/break_escape.py" run_d REAL_DAEMON="$DAEMON" -- run-once; rc=$?
  [ "$rc" = "0" ] && [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] \
    && ok "B68 (control) the wrapper script runs the real daemon: failover to b, exit 0" || bad "B68 control: rc=$rc current='$(jget "$STATE" current)': $(head -c 200 "$D/out.txt")"
  failed_over; w0=$(writes); DAEMON="$W/break_escape.py" run_d REAL_DAEMON="$DAEMON" -- run-once   # same clock: waiting, send_escape not reached
  NOW_OVERRIDE=$((NOW_BASE + 60)) DAEMON="$W/break_escape.py" run_d REAL_DAEMON="$DAEMON" -- run-once; rc=$?
  [ "$rc" = "0" ] && grep -q "unstick failed (RuntimeError) - no further key sent this run" "$LOG" && [ "$(pane_tries)" = "[1]" ] && [ "$(keys_sent)" = "0" ] \
    && ok "B68b send_escape raising -> logged by type, exit 0, the try is recorded and published, no key" || bad "B68b rc=$rc tries=$(pane_tries) keys=$(keys_sent): $(tail -n 2 "$LOG" | tr '\n' '|')"

  # B70 the failback runs on silence - or on an ANSWER - never over evidence that was not answered (a is back at its reset time; b is in use
  # and its own sessions are on the modal).
  R=2000000000
  failed_over; set_srv a@t.test 200 "$HDR_OK"; rearm; pa0=$(probes_of a@t.test); NOW_OVERRIDE=$((R + 100)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(probes_of a@t.test)" = "$pa0" ] \
    && ok "B70 b's sessions on the modal and b ANSWERS -> that screen is not about b, a's time has passed: back to a, still with no probe of a" || bad "B70 current='$(jget "$STATE" current)' probes of a $pa0 -> $(probes_of a@t.test)"
  failed_over; set_srv a@t.test 200 "$HDR_OK"; set_srv b@t.test 429 "$(hdr_rejected five_hour 2000003600)"; rearm; NOW_OVERRIDE=$((R + 100)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(jex b@t.test why)" = "rejected" ] && grep -q "SWITCH b@t.test -> a@t.test.*failover: b@t.test rejected" "$LOG" \
    && ok "B70b b is rejected too while a's time has passed -> the failover (not a failback) takes the pool to a; b is registered" || bad "B70b current='$(jget "$STATE" current)' b='$(jex b@t.test why)': $(grep SWITCH "$LOG" | tail -n 1)"
  failed_over; set_srv a@t.test 200 "$HDR_OK"; set_srv b@t.test 500 '{}'; rearm; NOW_OVERRIDE=$((R + 100)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && ok "B70c evidence that the API could not answer (500) -> nothing concluded: the pool stays on b even though a's time has passed" || bad "B70c current='$(jget "$STATE" current)'"

  # B71 THE WHOLE CYCLE, and the proof that it cost nothing (acceptance a-d): a is hit -> b; the sessions are unstuck; a's reset time
  # passes -> back to a by the TIMER, with no call about a; a is hit again -> the failover again. Whole thing: no claude, nothing SERVED.
  seeded; touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day $R)"; run_d -- run-once; later 60; later 120
  c1="$(jget "$STATE" current)"; k1=$(keys_sent); pa1=$(probes_of a@t.test)
  set_srv a@t.test 200 "$HDR_OK"; NOW_OVERRIDE=$((R + 100)) run_d -- run-once
  c2="$(jget "$STATE" current)"; pa2=$(probes_of a@t.test)
  set_srv a@t.test 429 "$(hdr_rejected seven_day $((R + 86400)))"; pane_screen "$PANE" modal; rearm; NOW_OVERRIDE=$((R + 300)) run_d -- run-once
  c3="$(jget "$STATE" current)"
  [ "$c1" = "b@t.test" ] && [ "$k1" = "1" ] && [ "$c2" = "a@t.test" ] && [ "$pa2" = "$pa1" ] && [ "$c3" = "b@t.test" ] \
    && ok "B71 hit -> b, unstuck (1 key), reset time -> back to a with NO call about a, hit again -> b: $c1 / $c2 / $c3" \
    || bad "B71 current $c1 / $c2 / $c3 keys=$k1 probes of a $pa1 -> $pa2"
  [ "$(served)" = "0" ] && [ ! -e "$D/kc/claude-invoked" ] && [ "$(msgs)" = "2" ] && ! grep -rqE 'sk-ant-' "$LOG" \
    && ok "B71b the zero-credit proof for the whole cycle: 2 evidence probes (both 429s), nothing SERVED by the API, claude never run, no token in the log" \
    || bad "B71b served=$(served) messages-calls=$(msgs) claude-invoked=$(cat "$D/kc/claude-invoked" 2>/dev/null | head -c 80)"

  # B72 no failback BEFORE the stored reset: a reading stamped after it (the usage store may run a little ahead of the clock, up to the
  # skew the daemon tolerates) is not the reset itself. At R+60 - the control - the same store does fail back.
  onb; usage_store a:0:10:$((R + 50)) b:5:10:$((R + 50)) c:5:10:$((R + 50)); set_srv a@t.test 200 "$HDR_OK"; w0=$(writes)
  NOW_OVERRIDE=$((R - 100)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(writes)" = "$w0" ] && [ "$(jex a@t.test why)" = "rejected" ] \
    && ok "B72 100 s BEFORE a's stored reset, with a reading stamped after it -> the pool stays on b, a stays registered" \
    || bad "B72 current='$(jget "$STATE" current)' writes $w0 -> $(writes) a-entry='$(jex a@t.test why)'"
  NOW_OVERRIDE=$((R + 60)) run_d -- run-once
  [ "$(jget "$STATE" current)" = "a@t.test" ] && ok "B72b (control) 60 s after the reset the same store fails back to a" || bad "B72b current='$(jget "$STATE" current)'"

  # B73 the limit screen recogniser, as a table. The modal opens on a session's FIRST hit only (measured); every later hit is the envelope
  # "⎿ You've hit your ... limit" with the prompt under it. It is evidence only as the LAST turn on screen; the modal and the envelope of
  # the same hit share one signature, a new hit has another; whatever the user half-typed in the prompt box changes nothing.
  cat > "$W/py_limit.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
RULE = "─" * 70
BOX = RULE + "\n❯ \n" + RULE + "\n  ⏸ manual mode on · ? for shortcuts · ← for agents"
ENV = "  ⎿  You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)"
HIT = "❯ Reply with exactly: ALPHA\n" + ENV + "\n✻ Sautéed for 3s · done 7:35 AM"
MODAL = "▔" * 40 + "\n   What do you want to do?\n   ❯ 1. Stop and wait for limit to reset\n     2. Wait here, then continue automatically at Oct 7 at 7pm\n     3. Upgrade your plan\n   Enter to confirm · Esc to cancel"
def sig(t):
    return m.limit_hit(t, m.modal_stuck(t))
inline = sig("banner\n" + HIT + "\n" + BOX)
bad = []
def chk(name, got, want):
    if (got is not None and got != "modal") != want and not (want == "modal" and got == "modal"):
        bad.append(f"{name}: {got!r} (want {want})")
chk("envelope as the last turn", inline, True)
chk("the modal of the same hit", sig("banner\n" + HIT + "\n" + MODAL), True)
if sig("banner\n" + HIT + "\n" + MODAL) != inline: bad.append("the modal and the envelope of the SAME hit differ in signature")
if not m.modal_stuck("banner\n" + HIT + "\n" + MODAL): bad.append("the real modal is not seen as a modal")
chk("modal with no envelope above it", sig("● work\n" + MODAL), "modal")
if sig("● work\n" + MODAL) != "modal": bad.append("modal with no envelope: signature is not 'modal'")
chk("with the continuation line", sig("banner\n" + HIT.replace("\n✻", "\n     /upgrade to increase your usage limit.\n✻") + "\n" + BOX), True)
if sig("banner\n" + HIT + "\n❯ Reply with exactly: BRAVO\n" + ENV + "\n✻ Crunched for 0s · done 7:36 AM\n" + BOX) in (None, inline): bad.append("a new hit has the signature of the old one")
if sig("banner\n" + HIT + "\n" + RULE + "\n❯ half typed\n" + RULE + "\n  ? for shortcuts") != inline: bad.append("a half-typed prompt changed the signature")
chk("a later assistant answer", sig("banner\n" + HIT + "\n❯ again\n⏺ 72\n✻ Worked for 2s · done 7:40 AM\n" + BOX), False)
chk("a later user turn with no answer yet", sig("banner\n" + HIT + "\n❯ again\n" + BOX), False)
chk("a turn running", sig("banner\n" + HIT + "\n❯ again\n✻ Pondering… (3s · esc to interrupt)\n" + BOX), False)
chk("an interrupted later turn", sig("banner\n" + HIT + "\n❯ again\n  ⎿  Interrupted · What should Claude do instead?\n" + BOX), False)
chk("a later tool result", sig("banner\n" + HIT + "\n⏺ Bash(ls)\n  ⎿  a b c\n" + BOX), False)
chk("quoted by the assistant (no tool-result glyph)", sig("⏺ It printed: You've hit your weekly limit · resets Oct 7\n" + BOX), False)
chk("inside the output of a tool, not its first line", sig("⏺ Bash(cat log)\n  ⎿  line one\n     You've hit your weekly limit\n" + BOX), False)
chk("the envelope scrolled far above", sig("banner\n" + HIT + "\n" + "\n".join("  line %d" % i for i in range(30)) + "\n" + BOX), False)
chk("no envelope at all", sig("banner\n" + BOX), False)
# the real bytes (measured live, claude 2.1.291): the glyph, a space and a NO-BREAK SPACE (U+00A0) before "You've", an ASCII apostrophe
chk("the real bytes: a no-break space after the glyph", sig("banner\n❯ x\n  ⎿  You've hit your weekly limit · resets Oct 7 at 7pm\n     /upgrade to increase your usage limit.\n✻ Brewed for 1s · done 7:38 AM\n" + BOX), True)
chk("empty", sig(""), False)
chk("a quoted modal under the envelope", sig("banner\n" + HIT + "\n❯ 1. Stop and wait for limit to reset\n" + BOX), False)
for name, line in [("session limit", "You've hit your session limit · resets 3am"), ("Opus limit", "You've hit your Opus limit"),
                   ("bare limit", "You've hit your limit"), ("curly apostrophe", "You’ve hit your weekly limit · resets Oct 7")]:
    chk(name, sig("banner\n❯ x\n  ⎿  " + line + "\n✻ Brewed for 1s · done 7:38 AM\n" + BOX), True)
for name, line in [("another message", "API Error: 500"), ("a limit that is not 'hit'", "Your weekly limit is 80% used")]:
    chk(name, sig("banner\n❯ x\n  ⎿  " + line + "\n" + BOX), False)
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$("$PY3" "$W/py_limit.py" "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B73 limit screen table: the modal; the envelope as the LAST turn (any limit kind); the same signature for a hit's modal and envelope; nothing for history, quotes, running or later turns" || bad "B73 $got"

  # B74 a session that already dismissed the modal once (the envelope is all it shows): the same evidence. One probe (a 429, free), the
  # pool item moves, and NO key is ever sent to it - the envelope blocks nothing, the next prompt just uses the new credential.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 inline1; il=$PANE
  w0=$(writes); set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; later 120; later 900
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(item_token)" = "$TOKEN_b" ] && [ "$(writes)" = "$((w0 + 1))" ] && [ "$(msgs)" = "1" ] \
    && ok "B74 a pane showing only the envelope + a rejected -> the pool item holds b after ONE run, one question, with no human and no restart" \
    || bad "B74 current='$(jget "$STATE" current)' writes $w0 -> $(writes) messages-calls=$(msgs)"
  [ "$(keys_sent)" = "0" ] && [ "$(addressed "$il")" -ge 1 ] && ! grep -q "UNSTICK" "$LOG" && [ "$(served)" = "0" ] && [ ! -e "$D/kc/claude-invoked" ] \
    && ok "B74b ...and no key at any time (an envelope blocks nothing), nothing SERVED, claude never run" || bad "B74b keys=$(keys_sent) served=$(served): $(grep -E 'UNSTICK|WARN' "$LOG" | tail -n 2 | tr '\n' '|')"
  grep -q "EVIDENCE: 1 pool pane(s) on the limit message (gastown.dog-2)" "$LOG" \
    && ok "B74c the log names it a limit MESSAGE (not a modal)" || bad "B74c log: $(grep EVIDENCE "$LOG" | tail -n 1)"

  # B75 an envelope that was ANSWERED (the account answers: the line is history, or another model's limit) is never asked about again -
  # a modal gets asked again after the cooldown, a line of history does not; a NEW hit is another screen and is asked at once.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 inline1; pa0=$(msg_probes_of a@t.test)
  run_d -- run-once; later 601; later 5000; later 90000
  [ "$(( $(msg_probes_of a@t.test) - pa0 ))" = "1" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(keys_sent)" = "0" ] \
    && ok "B75 the account answers for the envelope -> ONE probe in 25 hours of runs (the cooldown does not apply to a line of history), no switch, no key" \
    || bad "B75 probes of a: $pa0 -> $(msg_probes_of a@t.test) current='$(jget "$STATE" current)' keys=$(keys_sent)"
  pane_screen "$PANE" inline2; NOW_OVERRIDE=$((NOW_BASE + 90100)) run_d -- run-once
  [ "$(( $(msg_probes_of a@t.test) - pa0 ))" = "2" ] && ok "B75b a NEW hit (another prompt, another summary line) is new evidence at once (2 probes)" || bad "B75b probes of a: $pa0 -> $(msg_probes_of a@t.test)"
  later 90200; [ "$(( $(msg_probes_of a@t.test) - pa0 ))" = "2" ] && ok "B75c ...and then it is history too (still 2)" || bad "B75c probes of a: $pa0 -> $(msg_probes_of a@t.test)"

  # B76 the modal that is dismissed (our own Escape) leaves the envelope of the SAME hit on screen: that must not look like a new hit - or
  # every unstick would cost one more question to the account that was just moved to.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 modalreal
  printf '%s\n' "$INLINE1_SCREEN" > "$TMUXD/prompt.txt"; touch "$TMUXD/clear-on-esc"
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; pb1=$(msg_probes_of b@t.test); later 60; later 120; later 300; later 3000
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(keys_sent)" = "1" ] && [ "$(msgs)" = "1" ] && [ "$(msg_probes_of b@t.test)" = "$pb1" ] \
    && ok "B76 modal -> failover -> ONE Escape -> the envelope of the same hit stays on screen: no new evidence (1 question in all, and b was never asked a messages call - its free key checks are not questions)" \
    || bad "B76 current='$(jget "$STATE" current)' keys=$(keys_sent) messages-calls=$(msgs) probes of b $pb1 -> $(msg_probes_of b@t.test): $(grep -E 'EVIDENCE|UNSTICK' "$LOG" | tail -n 3 | cut -c1-140 | tr '\n' '|')"

  # B77 acceptance (d) for a session that no longer gets the modal: a is hit -> b (no key); the session answers on b and later hits b's limit
  # too (a NEW envelope) -> the failover again, to c, with no human. A hit that lands inside the 90 s the old credential may still be
  # in use (claude re-reads the item every ~30 s) is the OLD credential's: not evidence - and stays history, the next hit is the evidence.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 inline1
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once
  pane_screen "$PANE" inline2; set_srv b@t.test 429 "$(hdr_rejected five_hour 2000000500)"; later 30
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(msgs)" = "1" ] \
    && ok "B77 a new hit 30 s after the rewrite is the old credential's: not evidence (b not asked)" || bad "B77 current='$(jget "$STATE" current)' messages-calls=$(msgs)"
  pane_screen "$PANE" inline3; later 200
  [ "$(jget "$STATE" current)" = "c@t.test" ] && [ "$(item_token)" = "$TOKEN_c" ] && [ "$(msgs)" = "2" ] && [ "$(keys_sent)" = "0" ] && [ "$(served)" = "0" ] \
    && ok "B77b a new hit 200 s after it -> b asked once (a 429) -> the pool item holds c; no key, nothing SERVED" \
    || bad "B77b current='$(jget "$STATE" current)' item=$(item_token | cut -c1-24) messages-calls=$(msgs) keys=$(keys_sent) served=$(served)"

  # B78 Mayor and the crews, again, for the envelope: never looked at (not a single tmux call aimed at them), never counted. Real names.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once
  pane_add gastown.mayor inline1; may=$PANE; pane_add oracle-wa inline2; crew=$PANE; pane_add thies-wa inline3; crew2=$PANE; pane_add weird/mayor modalreal; weird=$PANE
  set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60
  [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(msgs)" = "0" ] && [ "$(addressed "$may" "$crew" "$crew2" "$weird")" = "0" ] && [ "$(keys_sent)" = "0" ] \
    && ok "B78 Mayor / crew panes (gastown.mayor, oracle-wa, thies-wa) showing the limit envelope (or the modal) are no evidence, are not even looked at, get no key" \
    || bad "B78 current='$(jget "$STATE" current)' messages-calls=$(msgs) tmux-calls-aimed=$(addressed "$may" "$crew" "$crew2" "$weird") keys=$(keys_sent)"

  # B79 the new bookkeeping fields are witnesses too: a garbled signature or flag is dropped (a new sighting, at worst one more question) and
  # never crashes the run or buys a key.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 inline1; pk="$PANE:$PANE_PID"
  edit_state "st['panes']={'$pk': {'first': $((NOW_BASE - 50)), 'tries': 0, 'sig': 12345, 'modal': 'yes'}}"
  set_srv a@t.test 200 "$HDR_OK"; run_d -- run-once; rc=$?
  [ "$rc" = "0" ] && no_crash && [ "$(keys_sent)" = "0" ] && [ "$("$PY3" -c 'import json,sys; e=list(json.load(open(sys.argv[1]))["panes"].values())[0]; print(isinstance(e.get("sig"),str) and e.get("modal") is False)' "$STATE")" = "True" ] \
    && ok "B79 a state with a non-string signature and a non-boolean flag -> read as a new sighting, rewritten sane, no key" || bad "B79 rc=$rc keys=$(keys_sent) panes=$("$PY3" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("panes"))' "$STATE")"

  # B80 a pool pane whose agent name the wrapper could not log ("agent=?": GC_AGENT unset) is still evidence - it follows the item, so the
  # pool moves for it - but it cannot be told from Mayor or a crew, so it is never pressed. A name that is no name ('we!rd') is not "?": it is no
  # pool role, so it is no evidence and not even looked at. With a named pool pane beside it, the one key goes to the named one alone.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add '?' modal; un=$PANE; pane_add 'we!rd' modal; un2=$PANE
  touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; later 120; later 300
  [ "$(jget "$STATE" current)" = "b@t.test" ] && [ "$(msgs)" = "1" ] && [ "$(keys_sent)" = "0" ] && [ "$(addressed "$un2")" = "0" ] && grep -q "1 pool pane(s) on the limit modal of a replaced credential have no agent name - not told apart from Mayor/crew, no Escape for them" "$LOG" \
    && ok "B80 a pane with no agent name (\"?\") on the modal: the pool moves (it is evidence), no Escape goes to it, and the log says why; a name that is no name is not even looked at" \
    || bad "B80 current='$(jget "$STATE" current)' messages-calls=$(msgs) keys=$(keys_sent): $(grep -E 'UNSTICK|no agent name' "$LOG" | tail -n 2 | cut -c1-140 | tr '\n' '|')"
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add '?' modal; un=$PANE; pane_add gastown.dog-2 modal; named=$PANE
  touch "$TMUXD/clear-on-esc"; set_srv a@t.test 429 "$(hdr_rejected seven_day 2000000000)"; run_d -- run-once; later 60; later 120
  [ "$(keys_sent)" = "1" ] && [ "$(keys_to "$named")" = "1" ] && [ "$(keys_to "$un")" = "0" ] \
    && ok "B80b ...beside a named pool pane: the one Escape goes to the named one, none to the nameless one" || bad "B80b keys=$(keys_sent) to-named=$(keys_to "$named") to-nameless=$(keys_to "$un")"

  # B81 a pane whose screen cannot be READ in a scan that otherwise worked is not 'a pane that left the limit screen': what is known about it
  # is kept. Forgotten, it would come back with a new first-seen time - a stale modal looking fresh, never unstuck, and asking b a question.
  failed_over; touch "$TMUXD/clear-on-esc"; mv "$TMUXD/screen.${PANE#%}" "$TMUXD/screen.hidden"
  later 100; k1=$(keys_sent); m1=$(msgs); pn1="$(jget "$STATE" panes)"
  mv "$TMUXD/screen.hidden" "$TMUXD/screen.${PANE#%}"; later 110
  [ "$k1" = "0" ] && [ -n "$pn1" ] && [ "$(keys_sent)" = "1" ] && [ "$(keys_to "$PANE")" = "1" ] && [ "$m1" = "1" ] && [ "$(msgs)" = "1" ] && grep -q "could not be read this run - nothing concluded about them" "$LOG" \
    && ok "B81 a pane that could not be read for one run keeps its bookkeeping: still the replaced credential's stale modal when it is read again -> ONE Escape, b never asked" \
    || bad "B81 keys while unreadable=$k1 after=$(keys_sent) messages-calls $m1 -> $(msgs) panes-kept='$pn1': $(grep -E 'UNSTICK|EVIDENCE|could not be read' "$LOG" | tail -n 3 | cut -c1-140 | tr '\n' '|')"

  # B82-B84 what a run leaves out without acting is said, now and then (every 10th clock minute), instead of nothing: 'no evidence' must be
  # tellable from 'there was a screen / a process and it could not be used'. T10: see NOW_BASE.
  # B82 a limit screen judged STALE (the credential it was about has been replaced) is no evidence - and says so, once on a due minute.
  failed_over; s0=$(nlog "judged STALE"); m0=$(msgs)
  NOW_OVERRIDE=$T10 run_d -- run-once; s1=$(nlog "judged STALE")
  NOW_OVERRIDE=$((T10 + 60)) run_d -- run-once; s2=$(nlog "judged STALE")
  [ "$s0" = "0" ] && [ "$s1" = "1" ] && [ "$s2" = "1" ] && [ "$(msgs)" = "$m0" ] && grep -q "pool pane(s) on a limit screen judged STALE - the pool item was rewritten at .*not evidence against b@t.test" "$LOG" \
    && ok "B82 a limit screen judged stale logs ONE line on a due clock minute (none on the next), and it is still no evidence: no messages call" \
    || bad "B82 STALE lines $s0 -> $s1 -> $s2 (want 0,1,1) messages-calls $m0 -> $(msgs): $(grep 'judged STALE' "$LOG" | tail -n 1 | cut -c1-200)"
  # B83 a live pool process that sits in no tmux pane has no screen to look at: counted in the log, on a due minute only.
  new_d; NOW_OVERRIDE=$((NOW_BASE - 100000)) run_d -- run-once; pane_add gastown.dog-2 modal; : > "$TMUXD/panes.txt"
  NOW_OVERRIDE=$T10 run_d -- run-once; n1=$(nlog "live pool process(es) in no tmux pane")
  NOW_OVERRIDE=$((T10 + 60)) run_d -- run-once; n2=$(nlog "live pool process(es) in no tmux pane")
  [ "$n1" = "1" ] && [ "$n2" = "1" ] && [ "$(jget "$STATE" current)" = "a@t.test" ] && [ "$(keys_sent)" = "0" ] && grep -q "pane scan: 1 live pool process(es) in no tmux pane" "$LOG" \
    && ok "B83 a proven pool process in no pane is counted in the log (once on a due minute), and nothing moves and no key is sent for it" \
    || bad "B83 lines $n1 -> $n2 (want 1,1) current='$(jget "$STATE" current)' keys=$(keys_sent): $(grep 'pane scan' "$LOG" | tail -n 1 | cut -c1-200)"
  # B84 ps rows the daemon cannot read are counted, not silently dropped (a pid missing from the table reads as 'not running'): the table
  # itself, and what the scan says about it - on a due minute only, including when that leaves no proven process at all.
  cat > "$W/py_ps.py" <<'EOF'
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
bad = []
class R:
    returncode = 0
    stdout = "  101     1 Mon Sep 28 10:00:00 2026\n\nnot a ps row\n  102     1 Xxx Foo 99 99:99:99 2026\n  103   101 Tue Sep 29 11:00:00 2026\n"
m.subprocess.run = lambda *a, **k: R()
tab, dropped = m.process_table()
if sorted(tab) != [101, 103] or dropped != 2: bad.append(f"table={sorted(tab)} dropped={dropped} (want [101, 103] and 2: a blank line is not a row)")
logs = []
m.log = lambda lvl, msg: logs.append(msg)
m.pool_launches = lambda off=None: {99999: (1.0, "gastown.dog-2")}
m.process_table = lambda: ({}, 3)
DUE = 600 * 3331667.0
m.now = lambda: DUE
sc = m.scan_panes()
if not sc.ok or sc.panes or not any("3 ps row(s) not understood" in x for x in logs): bad.append(f"due minute: ok={sc.ok} logs={logs}")
logs.clear(); m.now = lambda: DUE + 60
m.scan_panes()
if logs: bad.append(f"quiet minute logged: {logs}")
m.process_table = lambda: ({}, 0); m.now = lambda: DUE
m.scan_panes()
if logs: bad.append(f"nothing dropped, still logged: {logs}")
print("OK" if not bad else "BAD: " + "; ".join(bad))
EOF
  got="$("$PY3" "$W/py_ps.py" "$DAEMON" 2>&1)"
  [ "$got" = "OK" ] && ok "B84 unreadable ps rows are counted (blank lines are not), and the scan says so on a due minute only - also when no proven process is left" || bad "B84 $got"

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

# C10 the written design is the one that runs: 100% (no threshold), the Escape exception named, and the plist comment says so.
# The bead's structured acceptance_criteria still say 95%; Athos 04/10 revoked that. A doc or plist drifting back would mislead the next operator.
if [ -f "$DOC" ]; then
  if grep -q "The Escape exception" "$DOC" && grep -qi "no threshold" "$DOC" && grep -q "100%" "$DOC"; then
    ok "C10 the doc names the Escape exception and states there is no threshold (switch at the 100% limit hit)"
  else bad "C10 the doc lost 'The Escape exception' / 'no threshold' / '100%'"; fi
else bad "C10 doc not found at $DOC"; fi
if [ -f "$PLIST" ]; then
  if grep -q "The Escape exception" "$PLIST" && grep -q "100%" "$PLIST"; then
    ok "C10b the plist comment describes the 100% evidence design and points at the Escape exception"
  else bad "C10b the plist comment does not mention the 100% rule / the Escape exception"; fi
fi

# H1 nothing of this run reached the real log or the real state. Not a line count: the live daemon and the wrapper legitimately append to
# the real log while a 10-40 minute run goes on. What is looked for is what only a fixture says - the fixtures' accounts (@t.test), this run's
# scratch directory name, the item hash derived from it, the canary - in the bytes appended since the run started.
H1_MARK="@t\.test|$(basename "$W")|Claude Code-credentials-$POOL_HASH|$CANARY"
if [ -n "$REAL_LOG" ] && [ -f "$REAL_LOG" ]; then
  leaked="$(tail -c +"$((REAL_OFF + 1))" "$REAL_LOG" | grep -aE "$H1_MARK" | head -n 3 | cut -c1-200)"
  [ -z "$leaked" ] && ok "H1 the real wrapper log ($REAL_LOG) took no fixture line during this run" || bad "H1 fixture lines reached the real log: $leaked"
else
  echo "  - H1 skipped: no real log to compare (the run was not started from a session with GC_CITY_PATH)"
fi
if [ -n "$REAL_STATE" ] && [ -f "$REAL_STATE" ]; then
  grep -aqE "@t\.test" "$REAL_STATE" && bad "H1b a fixture account is in the real state file ($REAL_STATE)" || ok "H1b the real state file holds no fixture account"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
