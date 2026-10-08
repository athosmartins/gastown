#!/usr/bin/env bash
# claude-pool-guard.selftest.sh — ga-8hcnvb.3: the safety net under the pool's account switch.
#
#   G1-G4  DIVERGENCE: the account the pool really uses vs the account the rule dictates -> one phone alert in < 5 min naming both by
#          e-mail + 8-hex fingerprint, never the key; it stops repeating when fixed; 'could not tell' never alerts as a divergence.
#   G4g    the guard's OWN record (episode start, 'already alerted' stamp, the daemon watch) can be unusable - a 400-digit integer, NaN,
#          a string, a time in the future: that clock restarts; the check neither crashes nor goes silent. G4l-G4o: the same for slice 2's
#          stamps (a failed version's 'checked_epoch', the 'alerted_at' of the degradation and of 'marker not writable', 'notice_since').
#   G5     PER-VERSION TEST: claude is asked (on a scratch item) whether it still reads the credential the pool writes. Pass/fail is
#          recorded per claude version, queryable, and redone when the version changes. A fail -> alert 'auto-switch OFF', the daemon and
#          the wrapper stand down, an agent started in that state answers on the current login, nothing is deleted or interrupted.
#   G6     the daemon's heartbeat (a daemon that stopped completing runs); G6i: a heartbeat that cannot be read in ANY way (not UTF-8,
#          a 400-digit epoch, an epoch that is not a time) is 'could not tell', never a crash and never a verdict.
#   G7     NO KEY LEAKS (AC4): a full account switch, a degradation and a set of forced errors run under a background process sampler;
#          then claude-pool-leakscan.py searches argv, env, logs, the decision file, error output and sent notifications for the 5
#          keys (zero findings), finds a key planted on purpose (the control), and FAILS on a deliberately leaky daemon and a leaky guard.
#          (G7 runs last: it is the slowest.)
#   G8     the self-test's scratch item: never the pool's, never trusted if left behind.
#   G9     `status`: 'not tested yet' is not 'cannot tell'; 'auto-switch: on' is not what a shell with no city answers.
#   G10    the daemon's silence is judged only over time the guard was LOOKING: a stand-down (marker, operator switches) or the guard's
#          own absence (reboot, sleep) is not a daemon death; a daemon that really stays silent is still told on time. The harness's
#          HB_AUTO=0 is the real daemon (no stamp while stood down); HB_AUTO=1 re-stamps every tick and hid this.
#   G11    one title per condition: the fake notify drops a repeated TITLE within 30 min like the real one (rc 11), so two different
#          conditions that shared a title would lose the second push.
#   G12    the self-test failed and the marker cannot be written: said out loud, pool still ON, not recorded as a degradation.
#   G13    a pass while a marker the guard did not write is still up: no 'religada' until the marker is really gone.
#   G14    `selftest` says what it did: rc 0 pass / 3 fail / 4 inconclusive / 1 NOT run (lock held, kill switch, no claude).
#   G15    leakscan and symlinks: a link to a file is read through, a link to a directory is covered by another --path or BLIND,
#          a dangling one is BLIND - never skipped in silence.
#   G16    the quiet 'troca automática religada' notice: notify's router files it in the digest (rc 12) and that counts as delivered (sent
#          once, the episode closes); a FORCED push that meets the cap (rc 12) is retried until it goes out; a notice notify keeps
#          refusing is given up on after 30 min, said in the log; a blind record of a superseded claude version is dropped.
#   G17    leakscan exit 1 means 'a key was found' and nothing else: the --watch-max deadline, an unreadable directory or path, a FIFO,
#          an error nobody planned for are BLIND (3); a bad --interval is a usage error (2); a stop file in time is a clean end (0);
#          a stranger straddling two chunks is still fingerprinted.
#
# HERMETIC: fake `security` (items in a temp dir), fake `claude` (several behaviours), fake `secret` vault, fake `notify` (it models the
# router and the push cap: a quiet send gets rc 12 like the real one), a mock probe
# API, and a clock the test moves (CLAUDE_POOL_NOW). Nothing here touches the real Keychain, vault, network or phone.
# The product under test can be swapped for an older copy: CLAUDE_POOL_GUARD / _DAEMON / _WRAPPER / _LEAKSCAN (see 'previous HEAD' in the doc).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${CLAUDE_POOL_GUARD:-$SELF_DIR/claude-pool-guard.py}"
DAEMON="${CLAUDE_POOL_DAEMON:-$SELF_DIR/claude-pool-account.py}"
WRAPPER="${CLAUDE_POOL_WRAPPER:-$SELF_DIR/claude-lowprio.sh}"
LEAKSCAN="${CLAUDE_POOL_LEAKSCAN:-$SELF_DIR/claude-pool-leakscan.py}"
ACCT_LIB="${CLAUDE_POOL_ACCOUNTS_LIB:-/Users/athos/gt/whatsapp_automation/lib/claude_account_pool.py}"
PY3="${CLAUDE_POOL_PY:-/usr/bin/python3}"; [ -x "$PY3" ] || PY3="$(command -v python3)"   # the interpreter launchd runs (3.9)
ONLY="${GUARD_SELFTEST_ONLY:-}"   # e.g. G1 or G5,G7: run only these groups

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() {
  echo "  ✗ $*"; FAIL=$((FAIL+1))
  if [ -n "${GUARD_SELFTEST_VERBOSE:-}" ]; then   # what the product said, for whoever is looking at the failure
    echo "    --- guard log:"; tail -n 12 "$CITY/.gc/logs/claude-pool-guard.log" 2>/dev/null | sed 's/^/    | /'
    echo "    --- last output ($LAST):"; tail -n 8 "${LAST:-/dev/null}" 2>/dev/null | sed 's/^/    | /'
  fi
}
want() { [ -z "$ONLY" ] || case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

for f in "$GUARD" "$DAEMON" "$WRAPPER" "$LEAKSCAN" "$ACCT_LIB"; do [ -f "$f" ] || { echo "FATAL: not found: $f"; exit 1; }; done

_t="${TMPDIR:-/tmp}"; W="$(mktemp -d "${_t%/}/claude-pool-guard-selftest.XXXXXX")"   # no "//" in it: the product hashes paths it normalised, the fakes hash the string they were given
cleanup() { [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null; for p in ${BG_PIDS:-}; do kill "$p" 2>/dev/null; done; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
BG_PIDS=""

# ── the world ──────────────────────────────────────────────────────────────────────────────────────
WW="$W/w"; PROD="$WW/product"; CITY="$PROD/city"; DATA="$PROD/data"; STATE="$DATA/current.json"; GSTATE="$DATA/guard.json"
INFRA="$WW/infra"; SINKS="$WW/sinks"; CAP="$SINKS/cap"; FAKEBIN="$W/fakebin"; BB="$W/bb"
POOL_DIR="$W/pool-cred"
SCR="$INFRA/claude-pool-guard-scratch"     # the guard's scratch directory (CLAUDE_POOL_GUARD_SCRATCH)
SVC="Claude Code-credentials-$(printf '%s' "$POOL_DIR" | shasum -a 256 | cut -c1-8)"
PLAIN="Claude Code-credentials"
NOW_BASE=1999000000
EMAILS=(a@t.test b@t.test c@t.test d@t.test e@t.test)
mkdir -p "$BB" "$FAKEBIN"

rnd() { "$PY3" -c 'import secrets; print("sk-ant-oat01-TEST" + secrets.token_hex(20))'; }
KEY_a="$(rnd)"; KEY_b="$(rnd)"; KEY_c="$(rnd)"; KEY_d="$(rnd)"; KEY_e="$(rnd)"; KEY_x="$(rnd)"     # shell variables only: never exported, never in argv
key_of() { case "$1" in a@t.test) printf '%s' "$KEY_a" ;; b@t.test) printf '%s' "$KEY_b" ;; c@t.test) printf '%s' "$KEY_c" ;; d@t.test) printf '%s' "$KEY_d" ;; e@t.test) printf '%s' "$KEY_e" ;; esac; }
fp_of() { printf '%s' "$1" | shasum -a 256 | cut -c1-8; }
FP_a="$(fp_of "$KEY_a")"; FP_b="$(fp_of "$KEY_b")"; FP_c="$(fp_of "$KEY_c")"; FP_x="$(fp_of "$KEY_x")"
keys_json() { printf '{"a@t.test":"%s","b@t.test":"%s","c@t.test":"%s","d@t.test":"%s","e@t.test":"%s"}' "$KEY_a" "$KEY_b" "$KEY_c" "$KEY_d" "$KEY_e"; }
# bash-only 'does this file contain that secret': the secret never goes through an argv
contains() { local f="$1" n="$2" t; t="$(<"$f")" 2>/dev/null || return 1; [[ "$t" == *"${!n}"* ]]; }

# fake security: the subset the daemon, the guard and the wrapper use. `-i` reads commands from stdin (so no credential is in argv).
cat > "$BB/security" <<'EOF'
#!/bin/bash
KC="$FAKE_KC"; SK="$FAKE_SINKS"; echo "ARGV: $*" >> "$SK/kc-argv.log"
run_cmd() {
  local sub="$1" svc="" hex="" w=0; shift
  while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift ;; -X) hex="$2"; shift ;; -w) w=1 ;; esac; shift; done
  echo "OP $sub $svc" >> "$SK/kc-ops.log"
  case "$sub" in
    add-generic-password) [ -e "$KC/refuse-writes" ] && { echo "security: write refused (selftest)" >&2; return 1; }
                          [ -n "$svc" ] && [ -n "$hex" ] || return 1
                          [ -e "$KC/write-lands-other" ] && hex="$(printf '%s' '{"claudeAiOauth":{"accessToken":"selftest-some-other-credential"}}' | xxd -p | tr -d '\n')"
                          printf '%s' "$hex" > "$KC/items/$svc" ;;
    find-generic-password) [ -e "$KC/locked" ] && { echo "security: User interaction is not allowed." >&2; return 36; }
                           [ -e "$KC/items/$svc" ] || { echo "security: The specified item could not be found in the keychain." >&2; return 44; }
                           if [ "$w" = 1 ]; then xxd -r -p "$KC/items/$svc"; echo; fi ;;
    delete-generic-password) [ -e "$KC/locked" ] && return 36
                             [ -e "$KC/items/$svc" ] || return 44
                             rm -f "$KC/items/$svc" ;;
    *) return 1 ;;
  esac
}
if [ "${1:-}" = "-i" ]; then
  while IFS= read -r line; do eval "set -- $line"; run_cmd "$@"; rc=$?; [ $rc -eq 0 ] || exit $rc; done
else run_cmd "$@"; fi
EOF
cat > "$BB/secret" <<'EOF'
#!/bin/bash
e="${1#claude-oauth-token-}"
echo "$e" >> "$VAULT/.calls"
if [ -e "$VAULT/.broken" ]; then echo "secret: bw serve unreachable (selftest)" >&2; exit 1; fi
if [ -s "$VAULT/$e" ]; then cat "$VAULT/$e"; exit 0; fi
echo "secret: Not found." >&2; exit 4
EOF
# fake notify: records the call as the guard makes it (title, priority, message, and the two environment switches that route it)
cat > "$BB/notify" <<'EOF'
#!/bin/bash
{ printf 'CALL force=%s strict=%s argv:' "${NOTIFY_FORCE_PUSH:-}" "${NOTIFY_STRICT_EXIT:-}"; for a in "$@"; do printf ' [%s]' "$a"; done; echo; } >> "$FAKE_SINKS/notify.log"
[ -f "$FAKE_SINKS/notify.rc" ] && exit "$(cat "$FAKE_SINKS/notify.rc")"
# The router, as the real notify has it under NOTIFY_STRICT_EXIT=1 (gate ga-rtps35: this fake used to answer 0 to everything, so a quiet notice
# that the real notify sends to the digest - exit 12 - looked delivered): a call that is NOT forced (NOTIFY_FORCE_PUSH=1) from a source that is
# not on its allowlist goes to the muted digest: exit 12, a row in its history, nothing on the phone. notify.cap switches on the rate cap, which
# answers 12 to a FORCED push too (nothing on the phone either).
if [ "${NOTIFY_STRICT_EXIT:-}" = 1 ] && { [ "${NOTIFY_FORCE_PUSH:-}" != 1 ] || [ -e "$FAKE_SINKS/notify.cap" ]; }; then exit 12; fi
# notify.titledup switches on what the real notify does (title_pushed_recently): a push whose TITLE went out in the last 30 min is dropped,
# whatever its body - exit 11, nothing reaches the phone. The clock is the test's (the guard hands notify its CLAUDE_POOL_NOW).
if [ -e "$FAKE_SINKS/notify.titledup" ]; then
  touch "$FAKE_SINKS/notify.seen"; now="${CLAUDE_POOL_NOW:-0}"
  while IFS=$'\t' read -r ep ti; do [ "$ti" = "$2" ] && [ $((now - ep)) -lt 1800 ] && exit 11; done < "$FAKE_SINKS/notify.seen"
  printf '%s\t%s\n' "$now" "$2" >> "$FAKE_SINKS/notify.seen"
fi
printf '%s\n' "$2" >> "$FAKE_SINKS/notify.delivered"      # the titles that really reached the phone
exit 0
EOF
# fake claude (the binary baked with the world's paths: the guard hands claude a clean environment, so the mode lives in files)
cat > "$W/claude.tmpl" <<'EOF'
#!/bin/bash
IN="@INFRA@"; SK="@SINKS@"
MODE="$(cat "$IN/claude.mode" 2>/dev/null || echo ok)"; VER="$(cat "$IN/claude.version" 2>/dev/null || echo 1.0.0)"
echo "$*" >> "$SK/claude-calls.log"
case "${1:-}" in
  --version) echo "$VER (Claude Code)"; exit 0 ;;
  auth)
    [ "${2:-}" = "status" ] || exit 2
    case "$MODE" in
      hang) exec sleep 60 ;;
      garbage) echo "something that is not json"; exit 0 ;;
    esac
    dir="${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}"
    if [ -z "$dir" ]; then svc="Claude Code-credentials"
    elif [ "$MODE" = renamed ]; then svc="Claude Code-credentials-$(printf '%s' "$dir/v2" | shasum -a 256 | cut -c1-8)"   # a release that derives the name differently
    else svc="Claude Code-credentials-$(printf '%s' "$dir" | shasum -a 256 | cut -c1-8)"; fi
    present=0; [ -e "$IN/kc/items/$svc" ] && present=1
    [ "$MODE" = ignores ] && present=1                                                                                    # a release that stopped looking at the item
    if [ -e "$IN/flaky.once" ] && [ "$present" = 1 ]; then rm -f "$IN/flaky.once"; present=0; fi
    if [ "$present" = 1 ]; then echo '{"loggedIn":true,"authMethod":"claude.ai"}'; exit 0; fi
    echo '{"loggedIn":false,"authMethod":"none"}'; exit 1 ;;
  *)
    { echo "ARGV: $*"; echo "SECDIR=${CLAUDE_SECURESTORAGE_CONFIG_DIR:-<unset>}"; echo "USER=${USER:-<unset>}"; } >> "$SK/claude-launch.log"
    env | sort >> "$SK/claude-env.log"
    if [ -n "${CLAUDE_SECURESTORAGE_CONFIG_DIR:-}" ]; then echo "answer: ok (pool item)"; else echo "answer: ok (ambient login)"; fi
    exit 0 ;;
esac
EOF
chmod +x "$BB/security" "$BB/secret" "$BB/notify"
cat > "$W/mock_api.py" <<'EOF'
import http.server, json, sys
STATE, LOG, PORTF = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.do_POST()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length") or 0))
        tok = (self.headers.get("authorization") or "").replace("Bearer ", "")
        beh = json.load(open(STATE)).get(tok) or {"status": 401, "h": {}}
        with open(LOG, "a") as f: f.write("probe\n")      # the token is NOT logged here: the mock is not a channel under test
        self.send_response(beh["status"])
        for k, v in beh.get("h", {}).items(): self.send_header(k, v)
        body = b"{}"; self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORTF, "w").write(str(srv.server_address[1])); srv.serve_forever()
EOF

HDR_OK='{"anthropic-ratelimit-unified-status":"allowed","anthropic-ratelimit-unified-5h-status":"allowed","anthropic-ratelimit-unified-7d-status":"allowed","anthropic-ratelimit-unified-5h-reset":"1900000000","anthropic-ratelimit-unified-7d-reset":"1900500000"}'
HDR_REJ='{"anthropic-ratelimit-unified-status":"rejected","anthropic-ratelimit-unified-5h-status":"rejected","anthropic-ratelimit-unified-5h-reset":"1999003600","anthropic-ratelimit-unified-representative-claim":"five_hour","retry-after":"600"}'

NOW=$NOW_BASE; HB_AUTO=1; GRC=0; N_RUN=0; SRV_PID=""
blob_of() { printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":null}}' "$1"; }
put_item() { blob_of "$1" | xxd -p | tr -d '\n' > "$INFRA/kc/items/$SVC"; }            # builtin printf: the key is never in an argv
put_decision() { printf '{"current":"%s","fingerprint":"%s","since":"2033-05-18T03:00:00Z","reason":"selftest","previous":null,"exhausted":{},"schema":1,"updated":"2033-05-18T03:00:00Z"}\n' "$1" "$2" > "$STATE"; }
hb_touch() { printf '{"epoch": %s, "updated": "selftest", "pid": 1}\n' "$NOW" > "$CITY/.gc/claude-pool-account.heartbeat"; }
set_mode() { printf '%s' "$1" > "$INFRA/claude.mode"; }
set_ver() { printf '%s' "$1" > "$INFRA/claude.version"; }
ncalls() { [ -f "$SINKS/notify.log" ] && wc -l < "$SINKS/notify.log" | tr -d ' ' || echo 0; }
call_n() { sed -n "${1}p" "$SINKS/notify.log"; }
claude_auth_calls() { [ -f "$SINKS/claude-calls.log" ] && grep -c '^auth status' "$SINKS/claude-calls.log" || echo 0; }
gv() { "$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("versions",{}).get(sys.argv[2],{}).get(sys.argv[3],""))' "$GSTATE" "$1" "$2" 2>/dev/null; }
gj() { "$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("/"): d=d.get(k) if isinstance(d,dict) else None
print("<none>" if d is None else d)' "$1" "$2" 2>/dev/null; }

stamp_usage() { # the usage store the daemon orders accounts by: readings one second before the clock, 5 accounts a..e in order
  "$PY3" - "$INFRA/usage.json" "${1:-$NOW}" <<'EOF'
import json, sys
from datetime import datetime, timezone
iso = datetime.fromtimestamp(float(sys.argv[2]) - 1, timezone.utc).isoformat()
accts = [{"email": e, "ok": True, "stale": False, "collected_at": iso, "last_ok_at": iso,
          "weekly_all": {"percent": 10, "resets_at": "203%d-01-01T00:00:00+00:00" % i}, "session": {"percent": 5}}
         for i, e in enumerate(["a@t.test", "b@t.test", "c@t.test", "d@t.test", "e@t.test"])]
json.dump({"_selftest_fresh": True, "updated_at": iso, "accounts": accts}, open(sys.argv[1], "w"))
EOF
}

new_w() {
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; SRV_PID=""; }
  chmod -R u+w "$WW" 2>/dev/null; rm -rf "$WW"
  mkdir -p "$CITY/.gc/logs" "$DATA" "$INFRA/kc/items" "$INFRA/vault" "$INFRA/home" "$SINKS" "$CAP" "$INFRA/home/.gastown"
  : > "$SINKS/kc-argv.log"; : > "$SINKS/kc-ops.log"
  sed "s|@INFRA@|$INFRA|g; s|@SINKS@|$SINKS|g" "$W/claude.tmpl" > "$FAKEBIN/claude"; chmod +x "$FAKEBIN/claude"
  set_mode ok; set_ver 1.0.0
  local e; for e in "${EMAILS[@]}"; do key_of "$e" > "$INFRA/vault/$e"; done
  NOW=$NOW_BASE; HB_AUTO=1; N_RUN=0
  stamp_usage
}
BASE_ENV() {
  printf '%s\n' "HOME=$INFRA/home" "USER=athos" "PATH=$BB:$FAKEBIN:/usr/bin:/bin" "GC_CITY_PATH=$CITY" "FAKE_KC=$INFRA/kc" "FAKE_SINKS=$SINKS" "VAULT=$INFRA/vault" \
    "CLAUDE_USAGE_STORE=$INFRA/usage.json" "CLAUDE_POOL_STATE=$STATE" "CLAUDE_POOL_CRED_DIR=$POOL_DIR" "GC_POOL_CRED_DIR=$POOL_DIR" "CLAUDE_POOL_ACCOUNTS_LIB=$ACCT_LIB" \
    "CLAUDE_POOL_NOW=$NOW" "CLAUDE_POOL_DAEMON=$DAEMON" "CLAUDE_POOL_GUARD_STATE=$GSTATE" "CLAUDE_POOL_NOTIFY_CMD=$BB/notify" \
    "CLAUDE_POOL_GUARD_SCRATCH=$INFRA/claude-pool-guard-scratch" "CLAUDE_POOL_GUARD_RETRY_WAIT_S=0" "CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=20" \
    "GC_LOWPRIO_CLAUDE_BIN=$FAKEBIN/claude" "CLAUDE_POOL_PROBE_URL=http://127.0.0.1:$(cat "$INFRA/port" 2>/dev/null || echo 9)/v1/messages"
}
run_guard() { # run_guard [VAR=val ...] -- <guard args>; output in $LAST, status in $GRC
  local envs=() base=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  while IFS= read -r l; do base+=("$l"); done < <(BASE_ENV)
  N_RUN=$((N_RUN+1)); LAST="$CAP/guard-$N_RUN.txt"
  env -i "${base[@]}" "${envs[@]}" "$PY3" "$GUARD" "$@" > "$LAST" 2>&1; GRC=$?
}
run_d() { # run_d [VAR=val ...] -- <daemon args>
  local envs=() base=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  while IFS= read -r l; do base+=("$l"); done < <(BASE_ENV)
  N_RUN=$((N_RUN+1)); LAST="$CAP/daemon-$N_RUN.txt"
  stamp_usage "$NOW"
  env -i "${base[@]}" "${envs[@]}" "$PY3" "$DAEMON" "$@" > "$LAST" 2>&1; GRC=$?
}
run_wrapper() { # run_wrapper [VAR=val ...] -- <claude args>
  local envs=() base=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  while IFS= read -r l; do base+=("$l"); done < <(BASE_ENV)
  N_RUN=$((N_RUN+1)); LAST="$CAP/wrapper-$N_RUN.txt"
  env -i "${base[@]}" GC_LOWPRIO=0 "${envs[@]}" "$WRAPPER" "$@" > "$LAST" 2>&1; GRC=$?
}
gtick() { # gtick <advance-seconds> [VAR=val ...]: move the clock, stamp the daemon's heartbeat (unless HB_AUTO=0), run one guard pass
  NOW=$((NOW + $1)); shift
  [ "$HB_AUTO" = 1 ] && hb_touch
  run_guard "$@" -- run-once
}
gwalk() { # gwalk <seconds> [VAR=val ...]: the same stretch of time as ONE tick per minute (launchd's cadence) - for what depends on the guard having been watching
  local n=$(($1 / 60)) i; shift
  for ((i = 0; i < n; i++)); do gtick 60 "$@"; done
}
div3() { gtick 60; gtick 130; gtick 130; }      # a divergence that has lasted long enough to be alerted (2 min of persistence + the tick that sees it)
scan() { keys_json | "$PY3" "$LEAKSCAN" --keys-stdin "$@" > "$SINKS/scan2.out" 2>&1; S_RC=$?; }
ndelivered() { [ -f "$SINKS/notify.delivered" ] && wc -l < "$SINKS/notify.delivered" | tr -d ' ' || echo 0; }   # pushes that reached the phone (needs notify.titledup to differ from ncalls)
gl() { cat "$CITY/.gc/logs/claude-pool-guard.log" 2>/dev/null; }
active_world() { # item = a's key, decision = a, a clean heartbeat: the pool as the daemon leaves it
  put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch
}
title_n() { call_n "$1" | sed -E 's/^.*argv: \[-t\] \[([^]]*)\].*$/\1/'; }   # the TITLE of the Nth notify call (the body is a different argument)
utc_min() { "$PY3" -c 'import sys; from datetime import datetime, timezone; print(datetime.fromtimestamp(int(sys.argv[1]), timezone.utc).strftime("%Y-%m-%dT%H:%M"))' "$1"; }
BIG="$("$PY3" -c 'print("1" + "0" * 400)')"      # a 400-digit integer: float() and math.isfinite() raise OverflowError on it (json.loads takes it happily)
spoil_gs() { # spoil_gs <a/b/c: where in the guard's own state file> <JSON literal>: the record as a hand edit, a bad disk or a stepped-back clock would leave it
  "$PY3" - "$GSTATE" "$1" "$2" <<'EOF'
import json, sys
p, path, lit = sys.argv[1:4]
d = json.load(open(p))
o, ks = d, path.split("/")
for k in ks[:-1]:
    o = o[k]
o[ks[-1]] = json.loads(lit)
open(p, "w").write(json.dumps(d))
EOF
}
marker="$CITY/.gc/pool-account-degraded"

# ═══ G1. AC1: a divergence is alerted within 5 min, then stops ═════════════════════════════════════
if want G1; then
echo "G1. divergence: alert in < 5 min naming expected and in-use account, never the key; stops when fixed"
new_w; active_world
gtick 0; gtick 60
[ "$(ncalls)" = 0 ] && [ "$(gj "$GSTATE" divergence)" = "<none>" ] && ok "G1 item matches the decision -> no alert, no episode" || bad "G1 alert/episode with a matching item (calls=$(ncalls))"
T0=$NOW; put_item "$KEY_b"                                  # provoke: the pool item now holds b while the rule says a
gtick 60; n1=$(ncalls)
gtick 60; n2=$(ncalls)
[ "$n1" = 0 ] && [ "$n2" = 0 ] && ok "G1a the divergence is NOT alerted at once (the daemon writes the item and then the file: 2 min of persistence first)" || bad "G1a alerted too soon (calls $n1,$n2)"
[ "$(gj "$GSTATE" divergence/exp_fp)" = "$FP_a" ] && ok "G1b ...but the episode is open and remembers what it expected" || bad "G1b episode: $(gj "$GSTATE" divergence/exp_fp)"
gtick 60; T_ALERT=$NOW
[ "$(ncalls)" = 1 ] && [ $((T_ALERT - T0)) -le 300 ] && ok "G1c ONE alert, $((T_ALERT - T0)) s after the divergence began (budget 300 s)" || bad "G1c calls=$(ncalls) after $((T_ALERT - T0)) s"
c="$(call_n 1)"
{ [[ "$c" == *"a@t.test"* ]] && [[ "$c" == *"$FP_a"* ]] && [[ "$c" == *"b@t.test"* ]] && [[ "$c" == *"$FP_b"* ]]; } && ok "G1d the alert names the expected AND the in-use account by e-mail + 8-hex fingerprint" || bad "G1d alert text: $c"
{ ! contains "$SINKS/notify.log" KEY_a && ! contains "$SINKS/notify.log" KEY_b && [[ "$c" != *"sk-ant"* ]]; } && ok "G1e ...and contains no key (not in any form the pool knows)" || bad "G1e a key reached the notification"
{ [[ "$c" == *"[-p] [4]"* ]] && [[ "$c" == "CALL force=1 "* ]]; } && ok "G1f priority 4 and NOTIFY_FORCE_PUSH=1 (an unlisted source would otherwise go to the muted digest topic)" || bad "G1f routing: ${c:0:60}"
gtick 60; gtick 60; gtick 60
[ "$(ncalls)" = 1 ] && ok "G1g still diverged for 3 more minutes -> no second alert (once per episode)" || bad "G1g repeated alert (calls=$(ncalls))"
put_item "$KEY_a"                                            # fix the account
gtick 60
[ "$(gj "$GSTATE" divergence)" = "<none>" ] && [ "$(ncalls)" = 1 ] && ok "G1h fixed -> the episode closes and nothing is sent about it" || bad "G1h after the fix: episode=$(gj "$GSTATE" divergence) calls=$(ncalls)"
for _i in 1 2 3 4 5 6 7 8 9 10; do gtick 60; done
[ "$(ncalls)" = 1 ] && ok "G1i ...and 10 minutes later the alert has still not come back (stops repeating)" || bad "G1i alerts after the fix (calls=$(ncalls))"
# reminder: a divergence nobody fixes is repeated every 6 h, not every tick
put_item "$KEY_b"; gtick 60; gtick 130; gtick 130; n=$(ncalls)
gtick 21000; n_a=$(ncalls); gtick 700; n_b=$(ncalls)
{ [ "$n" = 2 ] && [ "$n_a" = 2 ] && [ "$n_b" = 3 ]; } && ok "G1j a NEW episode alerts again; unfixed, it is repeated after 6 h (not before)" || bad "G1j calls after new episode/5h50/6h01: $n/$n_a/$n_b"
[[ "$(call_n 3)" == *"Lembrete"* ]] && ok "G1k ...and the repeat says it is a reminder" || bad "G1k: $(call_n 3)"
# notify drops a push whose TITLE went out in the last 30 min (exit 11, which the guard counts as delivered): what tells two divergences apart has to be IN the title
t1="$(title_n 1)"
{ [[ "$t1" == *"$FP_a"* ]] && [[ "$t1" == *"$FP_b"* ]]; } && ok "G1l the TITLE (not only the body) carries both fingerprints" || bad "G1l title: $t1"
new_w; active_world; : > "$SINKS/notify.titledup"; gtick 0; put_item "$KEY_b"; div3; put_item "$KEY_a"; gtick 60; put_item "$KEY_c"; div3
{ [ "$(ncalls)" = 2 ] && [ "$(wc -l < "$SINKS/notify.delivered" | tr -d ' ')" = 2 ]; } && ok "G1m a DIFFERENT divergence within 30 min of the last one still reaches the phone (its title differs), not dropped as a duplicate" || bad "G1m calls=$(ncalls) delivered=$(wc -l < "$SINKS/notify.delivered" 2>/dev/null | tr -d ' ')"
# CLAUDE_POOL_GUARD_DEBOUNCE_S=nan parses; min()/max() on a NaN answer 0 s, so a typo in the seam would alert on the first look
new_w; active_world; gtick 0; put_item "$KEY_b"; gtick 60 CLAUDE_POOL_GUARD_DEBOUNCE_S=nan; gtick 60 CLAUDE_POOL_GUARD_DEBOUNCE_S=nan
[ "$(ncalls)" = 0 ] && ok "G1n a NaN debounce seam is not a zero debounce (the default 120 s holds: no alert after 1 min of disagreement)" || bad "G1n alerted at once with CLAUDE_POOL_GUARD_DEBOUNCE_S=nan (calls=$(ncalls))"
fi

# ═══ G2. who is the in-use account? ════════════════════════════════════════════════════════════════
if want G2; then
echo "G2. naming the in-use account (and saying so when it cannot be named)"
new_w; active_world; gtick 0; put_item "$KEY_x"; div3
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"$FP_x"* ]] && [[ "$c" == *"não é nenhuma das chaves"* ]]; } && ok "G2a the item holds a key that is none of the accounts' -> says exactly that, with the fingerprint" || bad "G2a: $c"
contains "$SINKS/notify.log" KEY_x && bad "G2a2 the stranger's key reached the notification" || ok "G2a2 ...without the stranger's key"
new_w; active_world; gtick 0; put_item "$KEY_b"; : > "$INFRA/vault/.broken"; div3
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"$FP_b"* ]] && [[ "$c" == *"o cofre não respondeu"* ]]; } && ok "G2b vault unreadable -> 'the vault did not answer', not a guess and not 'none of the 5'" || bad "G2b: $c"
new_w; active_world; gtick 0; rm -f "$INFRA/kc/items/$SVC"; div3
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"a@t.test"* ]] && [[ "$c" == *"item ausente"* ]]; } && ok "G2c the pool item is gone -> alert: expected a, in use: none" || bad "G2c: $c"
new_w; active_world; gtick 0; gtick 60; put_decision b@t.test "$FP_b"; : > "$INFRA/vault/.broken"; div3     # a was seen to match: the guard learned whose key a is
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"a@t.test (fp $FP_a)"* ]] && [[ "$c" == *"b@t.test"* ]]; } && ok "G2d the in-use account is named from what the guard saw match earlier (no vault needed)" || bad "G2d: $c"
new_w; rm -f "$STATE"; put_item "$KEY_a"; hb_touch; gtick 0; div3
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"sem decisão"* ]] && [[ "$c" == *"a@t.test"* ]]; } && ok "G2e item present, no decision published -> alerted as a divergence" || bad "G2e: $c"
new_w; active_world; gtick 0; put_item ""; div3     # the item exists, its accessToken is the empty string: that is not 'absent'
c="$(call_n 1)"
{ [ "$(ncalls)" = 1 ] && [[ "$c" == *"a@t.test"* ]] && [[ "$c" == *"sem credencial"* ]] && [[ "$c" != *"item ausente"* ]]; } && ok "G2f an item that exists but holds no credential is reported as empty, not as 'absent' (a different fault, a different fix)" || bad "G2f: $c"
fi

# ═══ G3. transient divergences, and an alert that did not go out ══════════════════════════════════
if want G3; then
echo "G3. a window shorter than the debounce is not an alert; a failed push is retried; a held push is not repeated"
new_w; active_world; gtick 0
put_item "$KEY_b"; gtick 60; put_item "$KEY_a"; gtick 60; for _i in 1 2 3 4; do gtick 60; done
[ "$(ncalls)" = 0 ] && ok "G3 one tick of disagreement (the daemon's write window) -> no alert" || bad "G3 alerted on a transient (calls=$(ncalls))"
new_w; active_world; gtick 0; put_item "$KEY_b"; printf 1 > "$SINKS/notify.rc"
gtick 60; gtick 60; gtick 60; gtick 60; n_fail=$(ncalls)
printf 0 > "$SINKS/notify.rc"; gtick 60; n_ok=$(ncalls); gtick 60; gtick 60; n_end=$(ncalls)
{ [ "$n_fail" = 2 ] && [ "$n_ok" = 3 ] && [ "$n_end" = 3 ]; } && ok "G3a notify fails -> the alert is retried every tick until it is accepted, then never again" || bad "G3a calls: failing=$n_fail accepted=$n_ok later=$n_end"
new_w; active_world; gtick 0; put_item "$KEY_b"; printf 10 > "$SINKS/notify.rc"; gtick 60; gtick 60; gtick 60; gtick 60; gtick 60
[ "$(ncalls)" = 1 ] && ok "G3b notify says 'held until 07:00' (rc 10) -> counted as sent, not hammered every minute" || bad "G3b calls=$(ncalls)"
new_w; active_world; gtick 0; put_item "$KEY_b"; gtick 60 CLAUDE_POOL_NOTIFY_CMD="$W/no-such-notify"; gtick 60 CLAUDE_POOL_NOTIFY_CMD="$W/no-such-notify"; gtick 60 CLAUDE_POOL_NOTIFY_CMD="$W/no-such-notify"
{ [ "$GRC" = 0 ] && [ "$(gj "$GSTATE" divergence/alerted_at)" = "<none>" ]; } && ok "G3c no notify command at all -> no crash, the episode stays un-alerted (retried when notify is back)" || bad "G3c rc=$GRC alerted_at=$(gj "$GSTATE" divergence/alerted_at)"
# what notify answers when NOTHING reached the phone, other than a plain failure: the cap (12 on a FORCED push - the digest legs are not reached by a forced one) and the codes after 12
retry_case() { # retry_case <label> <how notify refuses: a shell snippet using $SINKS>
  new_w; active_world; gtick 0; put_item "$KEY_b"; eval "$2"
  gtick 60; gtick 60; gtick 60; gtick 60; n_fail=$(ncalls)
  rm -f "$SINKS/notify.rc" "$SINKS/notify.cap"; gtick 60; n_ok=$(ncalls); gtick 60; gtick 60; n_end=$(ncalls)
  { [ "$n_fail" = 2 ] && [ "$n_ok" = 3 ] && [ "$n_end" = 3 ] && [ "$(gj "$GSTATE" divergence/alerted_at)" != "<none>" ]; } && ok "G3d/$1 nothing reached the phone -> the alert is retried every tick until it is accepted, then never again" || bad "G3d/$1 calls: refused=$n_fail accepted=$n_ok later=$n_end"
}
retry_case rate-cap 'touch "$SINKS/notify.cap"'
retry_case rc13     'printf 13 > "$SINKS/notify.rc"'
retry_case rc14     'printf 14 > "$SINKS/notify.rc"'
fi

# ═══ G4. 'could not tell' never acts ══════════════════════════════════════════════════════════════
if want G4; then
echo "G4. three answers, never two: a check that could not be done never raises (or clears) a divergence"
new_w; active_world; gtick 0; put_item "$KEY_b"; : > "$INFRA/kc/locked"
gtick 60; gtick 130; gtick 130; gtick 130
[ "$(ncalls)" = 0 ] && ok "G4 Keychain locked (cannot read the item) -> no divergence alert, however long" || bad "G4 alerted while blind (calls=$(ncalls))"
gtick 1500; gtick 300
{ [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"guarda sem enxergar"* ]]; } && ok "G4a ...but after 30 min of not being able to tell, ONE 'guard blind' alert says so" || bad "G4a calls=$(ncalls): $(call_n 1)"
[ ! -e "$marker" ] && ok "G4b ...and a locked Keychain during the self-test is inconclusive, never a degradation" || bad "G4b degraded because the Keychain was locked"
new_w; active_world; gtick 0; printf '{"current": ' > "$STATE"; put_item "$KEY_b"; gtick 60; gtick 130; gtick 130; gtick 130
[ "$(ncalls)" = 0 ] && [ -s "$STATE" ] && ok "G4c unreadable decision file -> no alert, and the guard does not rewrite or move it (it is the daemon's)" || bad "G4c calls=$(ncalls)"
new_w; active_world; put_item "$KEY_b"; for _i in 1 2 3 4 5; do gtick 60 GC_POOL_ACCOUNT=0; done
{ [ "$(ncalls)" = 0 ] && [ ! -e "$GSTATE" ] && [ "$(claude_auth_calls)" = 0 ] && [ ! -e "$marker" ]; } && ok "G4d GC_POOL_ACCOUNT=0 (operator switched the mechanism off) -> the guard does nothing at all (no state, no claude run, no alert)" || bad "G4d acted under the kill switch (calls=$(ncalls) state=$([ -e "$GSTATE" ] && echo yes || echo no) claude=$(claude_auth_calls))"
new_w; active_world; touch "$CITY/.gc/no-pool-account"; put_item "$KEY_b"; for _i in 1 2 3 4 5; do gtick 60; done
[ "$(ncalls)" = 0 ] && ok "G4e <city>/.gc/no-pool-account -> the guard does nothing" || bad "G4e acted under no-pool-account"
new_w; for _i in 1 2 3 4 5 6 7 8; do gtick 1200; done
[ "$(ncalls)" = 0 ] && [ "$(gj "$GSTATE" divergence)" = "<none>" ] && ok "G4f never activated (no decision, no item): hours of ticks, nothing said" || bad "G4f alerted on an inactive pool (calls=$(ncalls))"
new_w; active_world; set_mode renamed; gtick 0; put_item "$KEY_b"; for _i in 1 2 3 4 5; do gtick 60; done
{ [ -s "$marker" ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"DESLIGADA"* ]] && [ "$(gj "$GSTATE" divergence)" = "<none>" ]; } && ok "G4g while auto-switch is OFF (failed self-test, marker) the item is not expected to follow the decision -> no divergence alert, no open episode; the only push is the one that says it is off" || bad "G4g under the degraded marker: calls=$(ncalls) episode=$(gj "$GSTATE" divergence)"
set_mode ok; gtick 1900
{ [ ! -e "$marker" ] && [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"religada"* ]]; } && ok "G4h ...and when it comes back the stale divergence does NOT alert at once (only the 'back on' notice went out)" || bad "G4h calls=$(ncalls) marker=$([ -e "$marker" ] && echo yes || echo no)"
gtick 60; gtick 60; gtick 60
{ [ "$(ncalls)" = 3 ] && [[ "$(call_n 3)" == *"diverge"* ]]; } && ok "G4i ...it does alert if the item is STILL wrong 2+ min after auto-switch came back (a new episode)" || bad "G4i calls=$(ncalls) $(call_n 3)"
fi

# ═══ G5. the per-version test ══════════════════════════════════════════════════════════════════════
if want G5; then
echo "G5. per-version test: recorded, queryable, redone on a new version; a fail turns auto-switch off, safely"
new_w; active_world
cat "$INFRA/kc/items/$SVC" > "$W/item.before"
gtick 0
{ [ "$(gv 1.0.0 result)" = pass ] && [ ! -e "$marker" ] && [ "$(ncalls)" = 0 ]; } && ok "G5 first tick: claude 1.0.0 is tested -> pass, recorded; no marker, no alert" || bad "G5 result='$(gv 1.0.0 result)' marker=$([ -e "$marker" ] && echo yes || echo no) calls=$(ncalls) :: $(gl | tail -3)"
{ [ "$(ls "$INFRA/kc/items" | tr '\n' ' ')" = "$SVC " ] && [ ! -e "$SCR" ]; } && ok "G5a the scratch item and directory are gone afterwards; the pool item is the only item left" || bad "G5a leftovers: $(ls "$INFRA/kc/items") / scratch=$([ -e "$SCR" ] && echo yes || echo no)"
if grep -E "^OP (add|delete)-generic-password ($SVC|$PLAIN)$" "$SINKS/kc-ops.log" >/dev/null; then bad "G5b the self-test wrote or deleted the pool item or the plain login item"; else ok "G5b the self-test never wrote or deleted the pool item or Mayor's/crews' plain item (only its own scratch item)"; fi
cmp -s "$INFRA/kc/items/$SVC" "$W/item.before" && ok "G5c the pool item is byte-for-byte what it was" || bad "G5c the pool item changed"
contains "$CITY/.gc/logs/claude-pool-guard.log" KEY_a; grep -rq "GUARDSELFTEST" "$SINKS/kc-argv.log" "$CITY/.gc/logs" "$GSTATE" 2>/dev/null && bad "G5d the self-test's fake credential reached argv/log/state" || ok "G5d the self-test's credential went to the Keychain on stdin only: not in security's argv, the log or the state"
run_guard -- status --json
{ [ "$(gj "$LAST" installed_claude)" = "1.0.0" ] && [ "$(gj "$LAST" installed_result)" = pass ] && [ "$(gj "$LAST" versions/1.0.0/result)" = pass ]; } && ok "G5e AC3 queryable: status --json says installed claude 1.0.0 -> pass, with when it was checked" || bad "G5e status: $(head -c 300 "$LAST")"
[ -n "$(gj "$LAST" versions/1.0.0/checked_at | grep -E '^[0-9]{4}-')" ] && ok "G5f ...with a timestamp" || bad "G5f no checked_at"
run_guard -- status; grep -q "PASS" "$LAST" && grep -q "1.0.0" "$LAST" && ok "G5g the human-readable status shows the same" || bad "G5g status text: $(head -c 300 "$LAST")"
c0=$(claude_auth_calls); gtick 60; gtick 60; gtick 60
[ "$(claude_auth_calls)" = "$c0" ] && ok "G5h same claude version -> the test is NOT run again" || bad "G5h re-ran the test on an unchanged version ($c0 -> $(claude_auth_calls))"
set_ver 1.0.1; gtick 60
{ [ "$(gv 1.0.1 result)" = pass ] && [ "$(gv 1.0.0 result)" = pass ] && [ "$(claude_auth_calls)" -gt "$c0" ]; } && ok "G5i AC3: claude updated to 1.0.1 -> the test re-ran by itself on the next tick; both versions are on record" || bad "G5i 1.0.1='$(gv 1.0.1 result)' calls $c0 -> $(claude_auth_calls)"
# the release that changed the internals
( sleep 600 ) & SESSION_PID=$!; BG_PIDS="$BG_PIDS $SESSION_PID"     # stands for a live session: nothing may signal it
set_ver 1.0.2; set_mode renamed; gtick 60
{ [ "$(gv 1.0.2 result)" = fail ] && [ "$(gv 1.0.2 attempts)" = 2 ] && [ -s "$marker" ]; } && ok "G5j AC2: a claude that derives the item name differently -> FAIL (twice), degraded marker written" || bad "G5j result='$(gv 1.0.2 result)' attempts='$(gv 1.0.2 attempts)' marker=$([ -s "$marker" ] && echo yes || echo no) :: $(gl | tail -3)"
[ "$(ncalls)" = 1 ] && c="$(call_n 1)" || c=""
{ [[ "$c" == *"DESLIGADA"* ]] && [[ "$c" == *"1.0.2"* ]] && [[ "$c" == *"[-p] [4]"* ]] && [[ "$c" == "CALL force=1 "* ]]; } && ok "G5k ...ONE push, priority 4, forced: 'troca automática DESLIGADA', naming the claude version" || bad "G5k alert: calls=$(ncalls) $c"
"$PY3" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="claude-pool-guard" and d["claude"]=="1.0.2"' "$marker" 2>/dev/null && ok "G5l the marker says who wrote it and for which version (so only the guard lifts it)" || bad "G5l marker: $(cat "$marker")"
gtick 60; gtick 60; gtick 60
[ "$(ncalls)" = 1 ] && ok "G5m the next ticks do not repeat the alert" || bad "G5m calls=$(ncalls)"
cmp -s "$INFRA/kc/items/$SVC" "$W/item.before" && kill -0 "$SESSION_PID" 2>/dev/null && ok "G5n NOTHING was deleted or interrupted: the pool item is untouched and the 'live session' is still running" || bad "G5n the item changed or the session is gone"
# the daemon stands down
cp "$STATE" "$W/state.before"; run_d -- run-once
{ cmp -s "$STATE" "$W/state.before" && cmp -s "$INFRA/kc/items/$SVC" "$W/item.before" && grep -q "disabled by .*pool-account-degraded" "$CITY/.gc/logs/claude-pool-account.log"; } && ok "G5o the daemon stands down under the marker (no switch, says why in its log)" || bad "G5o daemon under marker: $(tail -2 "$CITY/.gc/logs/claude-pool-account.log" 2>/dev/null)"
# an agent started in that state answers normally
: > "$SINKS/claude-launch.log"; run_wrapper -- -p hello
{ [ "$GRC" = 0 ] && [ "$(cat "$LAST")" = "answer: ok (ambient login)" ] && grep -q "^SECDIR=<unset>$" "$SINKS/claude-launch.log"; } && ok "G5p AC2: an agent started in that state answers normally, on the current login (rc 0, no pool item pointed at)" || bad "G5p rc=$GRC out='$(head -c 200 "$LAST")'"
# it comes back by itself
set_ver 1.0.3; set_mode ok; gtick 60
{ [ "$(gv 1.0.3 result)" = pass ] && [ ! -e "$marker" ] && [ "$(ncalls)" = 2 ]; } && ok "G5q a claude that passes again -> marker removed, auto-switch back ON" || bad "G5q result='$(gv 1.0.3 result)' marker=$([ -e "$marker" ] && echo yes || echo no) calls=$(ncalls)"
c="$(call_n 2)"; { [[ "$c" == *"religada"* ]] && [[ "$c" == *"[-p] [2]"* ]] && [[ "$c" != "CALL force=1 "* ]]; } && ok "G5r ...announced quietly (priority 2, not forced)" || bad "G5r: $c"
# the real notify answers a quiet notice with 12 (the digest): that is where it was meant to go, so the episode closes and the notice is not sent again
n_q=$(ncalls); gtick 60; gtick 60; gtick 60
{ [ "$(gj "$GSTATE" degraded)" = "<none>" ] && [ "$(ncalls)" = "$n_q" ] && [ "$(ndelivered)" = 1 ]; } && ok "G5r2 ...notify's router sends it to the digest (exit 12): the episode is closed, it is not repeated every minute, and only the forced 'OFF' push reached the phone" || bad "G5r2 degraded=$(gj "$GSTATE" degraded) calls $n_q -> $(ncalls) delivered=$(ndelivered)"
run_wrapper -- -p hello; [ "$(cat "$LAST")" = "answer: ok (pool item)" ] && ok "G5s ...and a new launch follows the pool item again" || bad "G5s: $(cat "$LAST")"
kill "$SESSION_PID" 2>/dev/null
# same version, fixed later: retried every 30 min
set_ver 1.0.4; set_mode renamed; gtick 60; c1=$(claude_auth_calls); set_mode ok; gtick 600
{ [ -s "$marker" ] && [ "$(claude_auth_calls)" = "$c1" ]; } && ok "G5t degraded, then claude is fixed in place: 10 min later it is NOT yet retested" || bad "G5t marker=$([ -s "$marker" ] && echo yes || echo no) calls $c1 -> $(claude_auth_calls)"
gtick 1300
{ [ "$(gv 1.0.4 result)" = pass ] && [ ! -e "$marker" ]; } && ok "G5u ...30 min after the failure it is retested, passes, and the marker goes" || bad "G5u result='$(gv 1.0.4 result)' marker=$([ -e "$marker" ] && echo yes || echo no)"
# a marker the guard did not write is not the guard's to remove
set_ver 1.0.5; printf '{"by":"someone-else"}\n' > "$marker"; gtick 60
{ [ -s "$marker" ] && gl | grep -q "not written by this guard"; } && ok "G5v a marker written by someone else is left alone (and the log says so)" || bad "G5v foreign marker removed or unexplained"
rm -f "$marker"

# a flaky first answer is not a failure
new_w; active_world; : > "$INFRA/flaky.once"; gtick 0
{ [ "$(gv 1.0.0 result)" = pass ] && [ "$(gv 1.0.0 attempts)" = 2 ] && [ ! -e "$marker" ] && [ "$(ncalls)" = 0 ]; } && ok "G5w one wrong answer, right on the retry -> pass (attempts=2), nothing degraded, nothing sent" || bad "G5w result='$(gv 1.0.0 result)' attempts='$(gv 1.0.0 attempts)'"
# a claude that stopped looking at the item: still logged in with it gone
new_w; active_world; set_mode ignores; gtick 0
{ [ "$(gv 1.0.0 result)" = fail ] && [ -s "$marker" ]; } && ok "G5x a claude that is logged in whether or not the item exists is a FAIL too (it is not reading the pool item)" || bad "G5x result='$(gv 1.0.0 result)'"
# the drills: the pool credential removed / renamed as claude sees it
for f in remove rename; do
  new_w; active_world; gtick 0 CLAUDE_POOL_GUARD_FAULT=$f
  { [ "$(gv 1.0.0 result)" = fail ] && [ -s "$marker" ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"DESLIGADA"* ]]; } && ok "G5y AC2 drill: credential $f -> the per-version test fails, an alert says auto-switch is OFF" || bad "G5y drill $f: result='$(gv 1.0.0 result)' calls=$(ncalls)"
  cmp -s <(blob_of "$KEY_a" | xxd -p | tr -d '\n') "$INFRA/kc/items/$SVC" && ok "G5y2 ...the real pool item is untouched by the drill ($f)" || bad "G5y2 drill $f changed the pool item"
done
# inconclusive is not a failure
new_w; active_world; set_mode hang; gtick 0 CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=1
{ [ "$(gv 1.0.0 result)" = inconclusive ] && [ ! -e "$marker" ] && [ "$(ncalls)" = 0 ]; } && ok "G5z a claude that hangs -> inconclusive: no degradation, no alert (yet)" || bad "G5z result='$(gv 1.0.0 result)' calls=$(ncalls)"
for _i in 1 2 3 4 5 6 7; do gtick 300 CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=1; done
{ [ ! -e "$marker" ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"guarda sem enxergar"* ]]; } && ok "G5z2 ...still inconclusive after 30 min -> ONE 'cannot verify' alert, and STILL no degradation" || bad "G5z2 marker=$([ -e "$marker" ] && echo yes || echo no) calls=$(ncalls) $(call_n 1)"
new_w; active_world; set_mode garbage; gtick 0
{ [ "$(gv 1.0.0 result)" = inconclusive ] && [ ! -e "$marker" ]; } && ok "G5z3 a claude that prints something that is not JSON -> inconclusive, not a failure" || bad "G5z3 result='$(gv 1.0.0 result)'"
fi

# ═══ G8. the scratch item ═══════════════════════════════════════════════════════════════════════════
if want G8; then
echo "G8. the self-test's scratch item: never the pool's, never trusted if left behind"
# the scratch item can never be the pool's
new_w; active_world; gtick 0 CLAUDE_POOL_CRED_DIR="$SCR/cred" GC_POOL_CRED_DIR="$SCR/cred"
{ [ "$(gv 1.0.0 result)" = inconclusive ] && ! grep -q "^OP delete-generic-password" "$SINKS/kc-ops.log"; } && ok "G8 a scratch item that would BE the pool item is refused (inconclusive; nothing deleted or written)" || bad "G8 result='$(gv 1.0.0 result)' ops: $(grep -c '^OP' "$SINKS/kc-ops.log")"
# a leftover scratch item from a killed run is cleared, not trusted
new_w; active_world; LEFT="Claude Code-credentials-$(printf '%s' "$SCR/cred" | shasum -a 256 | cut -c1-8)"; printf 'aa' > "$INFRA/kc/items/$LEFT"; gtick 0
{ [ ! -e "$INFRA/kc/items/$LEFT" ] && [ "$(gv 1.0.0 result)" = pass ]; } && ok "G8a a scratch item left by a killed run is cleared before the test, and gone after it" || bad "G8a leftover=$([ -e "$INFRA/kc/items/$LEFT" ] && echo yes || echo no) result='$(gv 1.0.0 result)'"
# its own state file
new_w; active_world; gtick 0; printf 'not json at all' > "$GSTATE"; gtick 60
{ [ "$GRC" = 0 ] && [ "$(gv 1.0.0 result)" = pass ] && ls "$DATA"/guard.json.corrupt.* >/dev/null 2>&1; } && ok "G8b a corrupt guard state is moved aside and rebuilt (no crash, the self-test is redone)" || bad "G8b rc=$GRC $(ls "$DATA")"
fi

# ═══ G4g. the guard's OWN record can be wrong too ═════════════════════════════════════════════════
if want G4g; then
echo "G4g. a time in the guard's own state that cannot be used (a hand edit, a bad disk, a clock that stepped back) restarts that clock: it neither crashes the check nor silences the alert"
gs_case() { # gs_case <label> <JSON literal for the open episode's start>
  new_w; active_world; gtick 0; put_item "$KEY_b"; gtick 60; spoil_gs divergence/since "$2"
  gtick 60; rc1=$GRC; n_mid=$(ncalls); gtick 130; rc2=$GRC
  if gl | grep -q "unhandled"; then bad "G4g/$1 a spoiled start of the episode crashed the check ($(gl | grep unhandled | head -1 | cut -c1-110))"
  elif [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$n_mid" = 0 ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"conta em uso diverge"* ]]; then ok "G4g/$1 spoiled 'since' -> the episode's clock restarts (no alert on the repairing tick, ONE alert 2 min later; rc $rc1/$rc2)"
  else bad "G4g/$1 rc=$rc1/$rc2 calls=$n_mid/$(ncalls) since=$(gj "$GSTATE" divergence/since | cut -c1-30)"; fi
}
gs_case 400-digits "$BIG"
gs_case nan        'NaN'
gs_case string     '"soon"'
gs_case bool       'true'
gs_case negative   '-5'
gs_case future     "$((NOW + 5000000))"      # a real time, just one that has not happened yet: it would hold the alert back until the clock caught up
# the same for the 30-min 'could not tell' notice, the daemon's watch and the 'already alerted' stamp
new_w; active_world; gtick 0; put_item "$KEY_b"; : > "$INFRA/kc/locked"; gtick 60; spoil_gs blind/divergence/since "$BIG"
gtick 60; rc1=$GRC; gtick 1500; n1=$(ncalls); gtick 400; n2=$(ncalls)
{ ! gl | grep -q "unhandled" && [ "$rc1" = 0 ] && [ "$n1" = 0 ] && [ "$n2" = 1 ] && [[ "$(title_n 1)" == *"guarda sem enxergar (divergence)"* ]]; } && ok "G4h spoiled start of a 'could not tell' episode -> its 30 min restart; ONE 'guard blind' notice after that (calls at 25/32 min: $n1/$n2)" || bad "G4h rc=$rc1 calls=$n1/$n2 $(gl | grep unhandled | head -1 | cut -c1-110)"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; gtick 60; gtick 60; spoil_gs daemon/checked_at "$BIG"
gtick 60; rc1=$GRC; gwalk 540; n1=$(ncalls); gwalk 120; n2=$(ncalls)
{ ! gl | grep -q "unhandled" && [ "$rc1" = 0 ] && [ "$n1" = 0 ] && [ "$n2" = 1 ] && [[ "$(call_n 1)" == *"não está fechando rodadas"* ]]; } && ok "G4i spoiled 'checked_at' -> the guard cannot tell it was looking: the 10 min restart, and a daemon that stays silent is still told (calls at 9/11 min: $n1/$n2)" || bad "G4i rc=$rc1 calls=$n1/$n2 $(gl | grep unhandled | head -1 | cut -c1-110)"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; gtick 60; gtick 60; spoil_gs daemon/watch_since '"x"'
gtick 60; rc1=$GRC; gwalk 540; n1=$(ncalls); gwalk 120; n2=$(ncalls)
{ ! gl | grep -q "unhandled" && [ "$rc1" = 0 ] && [ "$n1" = 0 ] && [ "$n2" = 1 ]; } && ok "G4j spoiled 'watch_since' -> the same (calls at 9/11 min: $n1/$n2)" || bad "G4j rc=$rc1 calls=$n1/$n2"
new_w; active_world; gtick 0; put_item "$KEY_b"; div3; spoil_gs divergence/alerted_at "$BIG"
gtick 60; rc1=$GRC; gtick 60; gtick 60
{ ! gl | grep -q "unhandled" && [ "$rc1" = 0 ] && [ "$(ncalls)" = 2 ] && [ "$(gj "$GSTATE" divergence/alerted_at)" != "<none>" ] && [ "$(gj "$GSTATE" divergence/alerted_at)" != "$BIG" ]; } && ok "G4k spoiled 'alerted_at' reads as 'never alerted': the alert is said once more and the stamp is rewritten (calls=$(ncalls))" || bad "G4k rc=$rc1 calls=$(ncalls) alerted_at=$(gj "$GSTATE" divergence/alerted_at | cut -c1-30)"
# slice 2's own stamps. The one that used to pass for a good time is the time that has not happened yet: it held back the retest of a failed
# version, the 'auto-switch OFF' pushes and the end of the 'back ON' notice's retries until the clock caught up (months, with a hand edit)
fut=$((NOW + 5000000))
chk_case() { # chk_case <label> <JSON literal for the failed version's 'checked_epoch'>
  new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60; spoil_gs versions/1.0.2/checked_epoch "$2"
  set_mode ok; gtick 60
  if gl | grep -q "unhandled"; then bad "G4l/$1 a spoiled 'checked_epoch' crashed the check ($(gl | grep unhandled | head -1 | cut -c1-110))"
  elif [ "$(gv 1.0.2 result)" = pass ] && [ ! -e "$marker" ] && [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"religada"* ]]; then ok "G4l/$1 spoiled 'checked_epoch' of a failed version reads as 'never checked': it is tested again at once, passes, the marker is lifted, 'religada' goes out"
  else bad "G4l/$1 result='$(gv 1.0.2 result)' marker=$([ -e "$marker" ] && echo yes || echo no) calls=$(ncalls)"; fi
}
chk_case future "$fut"
chk_case 400-digits "$BIG"
chk_case string '"later"'
if [ "$(id -u)" != 0 ]; then
  new_w; active_world; gtick 0; chmod 555 "$CITY/.gc"; set_ver 1.0.2; set_mode renamed; gtick 60; spoil_gs marker_failed/alerted_at "$fut"
  gtick 60; chmod 755 "$CITY/.gc"
  { ! gl | grep -q "unhandled" && [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"NÃO foi desligada"* ]] && [ "$(gj "$GSTATE" marker_failed/alerted_at)" != "$fut" ]; } && ok "G4m spoiled 'alerted_at' of 'could not write the marker' (in the future) reads as 'never alerted': the worst state is said again, not withheld, and the stamp is rewritten (calls=$(ncalls))" || bad "G4m calls=$(ncalls) alerted_at=$(gj "$GSTATE" marker_failed/alerted_at | cut -c1-30)"
else
  ok "G4m skipped (root can write anywhere)"
fi
new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60; spoil_gs degraded/alerted_at "$fut"
gtick 60
{ ! gl | grep -q "unhandled" && [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"DESLIGADA"* ]] && [ "$(gj "$GSTATE" degraded/alerted_at)" != "$fut" ]; } && ok "G4n spoiled 'alerted_at' of the degradation reads as 'never alerted': 'auto-switch OFF' is said again and the stamp is rewritten (calls=$(ncalls))" || bad "G4n calls=$(ncalls) alerted_at=$(gj "$GSTATE" degraded/alerted_at | cut -c1-30)"
new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60
set_ver 1.0.3; set_mode ok; printf 14 > "$SINKS/notify.rc"; gtick 60; spoil_gs degraded/notice_since "$fut"
gtick 600; gtick 600; gtick 600; gtick 600; n_g=$(ncalls); d_g=$(gj "$GSTATE" degraded); gtick 600; gtick 600
{ ! gl | grep -q "unhandled" && [ "$d_g" = "<none>" ] && [ "$(ncalls)" = "$n_g" ] && gl | grep -q "gave up announcing"; } && ok "G4o spoiled 'notice_since' (in the future) restarts the notice's 30 min: a notice notify keeps refusing is still given up on, once (calls=$n_g, stable after)" || bad "G4o degraded=$d_g calls=$n_g/$(ncalls) notice_since=$(gj "$GSTATE" degraded/notice_since | cut -c1-30)"
fi

# ═══ G6. is the daemon doing its job? ══════════════════════════════════════════════════════════════
if want G6; then
echo "G6. the daemon's heartbeat"
new_w; HB_AUTO=0
for _i in 1 2 3 4 5; do gtick 600; done
[ "$(ncalls)" = 0 ] && ok "G6 a pool that was never activated has no daemon to be dead" || bad "G6 alerted on an inactive pool"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"
gtick 0; gwalk 540; n1=$(ncalls); gwalk 120; n2=$(ncalls); gwalk 1200; n3=$(ncalls)
{ [ "$n1" = 0 ] && [ "$n2" = 1 ] && [ "$n3" = 1 ]; } && ok "G6a activated pool, the daemon never stamps: ONE alert once 10 min have passed (not before, not again)" || bad "G6a calls at 9min/11min/31min: $n1/$n2/$n3"
{ [[ "$(call_n 1)" == *"não está fechando rodadas"* ]] && [[ "$(call_n 1)" == *"nunca"* ]]; } && ok "G6b ...and it says the daemon has never completed a run" || bad "G6b: $(call_n 1)"
# the REAL daemon's stamp is what the guard reads (one contract, both sides)
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; : > "$SINKS/notify.titledup"
env -i HOME="$INFRA/home" PATH="/usr/bin:/bin" GC_CITY_PATH="$CITY" CLAUDE_POOL_NOW="$NOW" "$PY3" -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("d", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m); m.write_heartbeat()' "$DAEMON"
[ -s "$CITY/.gc/claude-pool-account.heartbeat" ] && ok "G6c the daemon's write_heartbeat() leaves the file the guard reads" || bad "G6c no heartbeat file from the daemon's own function"
gtick 300; gtick 290; [ "$(ncalls)" = 0 ] && ok "G6d a stamp 9.9 min old is a live daemon" || bad "G6d alerted on a fresh heartbeat"
gtick 20; [ "$(ncalls)" = 1 ] && ok "G6e ...and one 10.2 min old is not" || bad "G6e calls=$(ncalls)"
[[ "$(title_n 1)" == *"(última: $(utc_min "$NOW_BASE")Z)"* ]] && ok "G6e2 the TITLE (not only the body) carries the last stamp" || bad "G6e2 title: $(title_n 1)"
hb_touch; gtick 1; gwalk 650
[ "$(ncalls)" = 2 ] && ok "G6f a daemon that comes back and stops again is a NEW episode (alerted again)" || bad "G6f calls=$(ncalls)"
# notify drops a repeated TITLE within 30 min (exit 11, which counts as delivered): the second episode reached the phone only because its title has a different stamp
[ "$(wc -l < "$SINKS/notify.delivered" | tr -d ' ')" = 2 ] && ok "G6f2 ...and the second alert really reached the phone (not dropped as a duplicate title: calls=$(ncalls) delivered=2)" || bad "G6f2 delivered=$(wc -l < "$SINKS/notify.delivered" | tr -d ' ') of $(ncalls)"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; for _i in 1 2 3 4 5 6; do gtick 600 GC_POOL_ACCOUNT=0; done
[ "$(ncalls)" = 0 ] && ok "G6g an operator who switched the mechanism off is not told the daemon stopped" || bad "G6g alerted under the kill switch"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; set_mode renamed; for _i in 1 2 3 4 5 6; do gtick 600; done
{ [ -s "$marker" ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"DESLIGADA"* ]]; } && ok "G6h degraded (marker): the daemon is stood down on purpose, so it is not 'dead' (the only push is the one that says auto-switch is off)" || bad "G6h under the marker: calls=$(ncalls) $(call_n 2)"
# a heartbeat that cannot be READ (garbled, no time in it, stamped in the future, not a file) says nothing about the daemon: no 'dead' verdict, and after 30 min the guard says it is blind
hb_case() { # hb_case <label> <how to spoil the heartbeat: a shell snippet using $hbf>; the pool is activated and the daemon never stamps again
  new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; local hbf="$CITY/.gc/claude-pool-account.heartbeat"; eval "$2"
  gtick 600; gtick 600; gtick 600; n1=$(ncalls); gtick 600; gtick 600; gtick 600; n2=$(ncalls)
  if grep -q "não está fechando rodadas" "$SINKS/notify.log" 2>/dev/null; then bad "G6i/$1 a heartbeat that cannot be read was judged 'the daemon is dead' ($(call_n 1))"
  elif [ "$n1" = 0 ] && [ "$n2" = 1 ] && [[ "$(call_n 1)" == *"guarda sem enxergar"* ]] && [[ "$(call_n 1)" == *"daemon-heartbeat"* ]]; then ok "G6i/$1 unreadable heartbeat -> no 'dead' verdict; ONE 'guard is blind' alert after 30 min (calls at 30min/60min: $n1/$n2)"
  else bad "G6i/$1 calls at 30min/60min: $n1/$n2 $(call_n 1)"; fi
}
hb_case garbled      'printf "this is not json" > "$hbf"'
hb_case no-epoch     'printf "{\"updated\": \"x\", \"pid\": 1}" > "$hbf"'
hb_case non-object   'printf "[1, 2, 3]" > "$hbf"'
hb_case future       'printf "{\"epoch\": %s, \"updated\": \"stuck clock\", \"pid\": 1}" "$((NOW + 100000))" > "$hbf"'
hb_case a-directory  'mkdir "$hbf"'
# a time that is not a finite number is not a time (json.loads takes NaN and Infinity; the day-count arithmetic on them raises)
hb_case nan          'printf "{\"epoch\": NaN, \"pid\": 1}" > "$hbf"'
hb_case minus-inf    'printf "{\"epoch\": -Infinity, \"pid\": 1}" > "$hbf"'
hb_case plus-inf     'printf "{\"epoch\": Infinity, \"pid\": 1}" > "$hbf"'
# ...nor is a file that is not text at all, an integer too big for a float (float() and math.isfinite() raise OverflowError), or a number that cannot be a time
hb_case not-utf8     'printf "\377\376\200{\"epoch\": 1}" > "$hbf"'
hb_case 400-digits   'printf "{\"epoch\": %s, \"pid\": 1}" "$BIG" > "$hbf"'
hb_case epoch-zero   'printf "{\"epoch\": 0, \"pid\": 1}" > "$hbf"'
hb_case epoch-one    'printf "{\"epoch\": 1, \"pid\": 1}" > "$hbf"'
hb_case a-bool       'printf "{\"epoch\": true, \"pid\": 1}" > "$hbf"'
# ...and when it can be read again the blindness ends by itself, and a real silence is judged on the real time
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; printf 'garbage' > "$CITY/.gc/claude-pool-account.heartbeat"; gtick 60
grep -q "cannot verify daemon-heartbeat" "$CITY/.gc/logs/claude-pool-guard.log" && [ "$(gj "$GSTATE" blind/daemon-heartbeat/why | grep -c 'cannot be read')" = 1 ] && ok "G6j the guard records that it cannot read the heartbeat (state + log)" || bad "G6j nothing recorded: $(gl | tail -3)"
hb_touch; gtick 1
[ "$(gj "$GSTATE" blind/daemon-heartbeat)" = "<none>" ] && grep -q "can verify daemon-heartbeat again" "$CITY/.gc/logs/claude-pool-guard.log" && ok "G6k a readable heartbeat ends the blindness (recorded)" || bad "G6k blindness not cleared: $(gj "$GSTATE" blind)"
# a locked Keychain and no decision: whether the pool was ever switched on cannot be told -> no 'the daemon never ran' verdict
new_w; HB_AUTO=0; put_item "$KEY_a"; : > "$INFRA/kc/locked"
for _i in 1 2 3 4 5 6; do gtick 600; done
if grep -q "não está fechando rodadas" "$SINKS/notify.log" 2>/dev/null; then bad "G6l a pool whose activation cannot be told (Keychain locked, no decision) was judged 'the daemon is dead'"
else ok "G6l Keychain locked + no heartbeat + no decision -> no 'daemon is dead' verdict (it cannot be told whether the daemon was ever meant to run)"; fi
rm -f "$INFRA/kc/locked"
fi

# ═══ G9. `status` is a way to ask, so it must not turn "I could not look" into an answer ═════════════
if want G9; then
echo "G9. status: 'not tested yet' is not 'cannot tell'"
new_w; run_guard -- status
{ [ "$GRC" = 0 ] && grep -q "per-version self-test: not tested yet" "$LAST"; } && ok "G9 no state file yet -> 'not tested yet' (that one IS the true answer), rc 0" || bad "G9 rc=$GRC: $(head -c 300 "$LAST")"
new_w; printf 'not json at all' > "$GSTATE"; run_guard -- status
{ [ "$GRC" = 1 ] && grep -q "unknown (the guard's state file is corrupt)" "$LAST" && ! grep -q "not tested yet" "$LAST"; } && ok "G9a a corrupt state file -> 'unknown (... corrupt)', rc 1 - not 'not tested yet'" || bad "G9a rc=$GRC: $(head -c 300 "$LAST")"
{ [ -f "$GSTATE" ] && [ "$(cat "$GSTATE")" = "not json at all" ] && ! ls "$DATA"/guard.json.corrupt.* >/dev/null 2>&1; } && ok "G9b ...and asking did not move or change the file (status only looks)" || bad "G9b the state file was touched: $(ls "$DATA")"
run_guard -- status --json
{ [ "$GRC" = 1 ] && [ "$(gj "$LAST" state_file)" = corrupt ] && [[ "$(gj "$LAST" installed_result)" == "unknown (the guard's state file is corrupt)" ]]; } && ok "G9c status --json says the same (state_file=corrupt, installed_result unknown)" || bad "G9c rc=$GRC: $(head -c 300 "$LAST")"
if [ "$(id -u)" != 0 ]; then
  new_w; echo '{}' > "$GSTATE"; chmod 000 "$GSTATE"; run_guard -- status; chmod 600 "$GSTATE"
  { [ "$GRC" = 1 ] && grep -q "unknown (the guard's state file is unreadable)" "$LAST"; } && ok "G9d a state file that cannot be read -> 'unknown (... unreadable)', rc 1" || bad "G9d rc=$GRC: $(head -c 300 "$LAST")"
fi
new_w; active_world; gtick 0
run_guard GC_LOWPRIO_CLAUDE_BIN=no-such-claude-binary-xyz -- status
{ [ "$GRC" = 0 ] && grep -q "unknown (the installed claude version could not be read)" "$LAST" && ! grep -q "self-test: pass" "$LAST" && ! grep -q "not tested yet" "$LAST"; } && ok "G9e claude cannot be run -> the installed version's result is 'unknown', never the last recorded one or 'not tested yet'" || bad "G9e rc=$GRC: $(head -c 400 "$LAST")"
run_guard GC_LOWPRIO_CLAUDE_BIN=no-such-claude-binary-xyz -- status --json
{ [[ "$(gj "$LAST" installed_result)" == "unknown (the installed claude version could not be read)" ]] && [ "$(gj "$LAST" versions/1.0.0/result)" = pass ]; } && ok "G9f ...while the recorded history is still shown (status --json: versions/1.0.0 = pass)" || bad "G9f: $(head -c 400 "$LAST")"
run_guard -- status
grep -q "per-version self-test: pass" "$LAST" && ok "G9g and with claude readable and tested, the answer is the recorded result" || bad "G9g: $(head -c 300 "$LAST")"
# the marker is looked for under GC_CITY_PATH (only the plist and agent sessions export it: a plain shell does not). No city to look in is
# not "no marker": the documented way to ask 'is auto-switch OFF?' must not answer 'on' exactly when it cannot look.
new_w; active_world; gtick 0; run_guard -- status
{ [ "$GRC" = 0 ] && grep -q "^auto-switch      : on$" "$LAST"; } && ok "G9h city readable, no marker -> 'auto-switch: on', rc 0" || bad "G9h rc=$GRC: $(head -c 300 "$LAST")"
printf '{"by":"claude-pool-guard"}\n' > "$marker"; run_guard -- status
{ [ "$GRC" = 0 ] && grep -q "^auto-switch      : OFF (degraded marker present)$" "$LAST"; } && ok "G9i city readable, marker there -> OFF" || bad "G9i rc=$GRC: $(head -c 300 "$LAST")"
run_guard GC_CITY_PATH= -- status
{ [ "$GRC" = 1 ] && grep -q "^auto-switch      : unknown (GC_CITY_PATH is not set" "$LAST" && ! grep -q "auto-switch      : on" "$LAST"; } && ok "G9j the SAME marker, no GC_CITY_PATH -> 'unknown (GC_CITY_PATH is not set ...)', rc 1 - not 'on'" || bad "G9j rc=$GRC: $(head -c 300 "$LAST")"
run_guard GC_CITY_PATH= -- status --json
{ [ "$GRC" = 1 ] && [ "$(gj "$LAST" degraded)" = "<none>" ] && [[ "$(gj "$LAST" auto_switch)" == "unknown (GC_CITY_PATH is not set"* ]]; } && ok "G9k status --json: degraded is null (not false) and auto_switch says 'unknown (...)', rc 1" || bad "G9k rc=$GRC: $(head -c 300 "$LAST")"
run_guard -- status --json
{ [ "$GRC" = 0 ] && [ "$(gj "$LAST" degraded)" = "True" ] && [ "$(gj "$LAST" auto_switch)" = OFF ]; } && ok "G9l ...and with the city, --json says degraded=true / auto_switch=OFF" || bad "G9l rc=$GRC: $(head -c 300 "$LAST")"
rm -f "$marker"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$CITY/.gc"; run_guard -- status; chmod 755 "$CITY/.gc"
  { [ "$GRC" = 1 ] && grep -q "^auto-switch      : unknown (" "$LAST" && ! grep -q "auto-switch      : on" "$LAST"; } && ok "G9m a city whose .gc cannot be looked into -> 'unknown (...)', rc 1 (not a crash, not 'on')" || bad "G9m rc=$GRC: $(head -c 400 "$LAST")"
fi
new_w; active_world; gtick 0; rm -rf "$CITY/.gc"; run_guard -- status
{ [ "$GRC" = 1 ] && grep -q "^auto-switch      : unknown (" "$LAST"; } && ok "G9n a GC_CITY_PATH with no .gc in it (a mistyped path) -> unknown, not 'on'" || bad "G9n rc=$GRC: $(head -c 300 "$LAST")"
fi

# ═══ G10. a stand-down is not a daemon death ═══════════════════════════════════════════════════════
if want G10; then
echo "G10. the guard judges the daemon's silence only over time it was LOOKING: not over a stand-down, not over its own absence"
# While auto-switch is OFF the REAL daemon stamps no heartbeat (HB_AUTO=0 is that daemon; HB_AUTO=1 re-stamps every tick, stand-down included, and hid this).
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch
set_ver 1.0.2; set_mode renamed; gtick 60
{ [ -s "$marker" ] && [ "$(ncalls)" = 1 ] && [[ "$(call_n 1)" == *"DESLIGADA"* ]]; } && ok "G10 degraded at +60 s (the daemon last stamped before that and, stood down, stamps no more)" || bad "G10 marker=$([ -s "$marker" ] && echo yes || echo no) calls=$(ncalls)"
set_ver 1.0.3; set_mode ok; gtick 1900
{ [ ! -e "$marker" ] && [[ "$(call_n 2)" == *"religada"* ]]; } && ok "G10a 31 min on the retest passes and the marker is lifted ('religada' went out)" || bad "G10a marker=$([ -e "$marker" ] && echo yes || echo no) calls=$(ncalls)"
if grep -q "não está fechando rodadas" "$SINKS/notify.log"; then bad "G10b the daemon was called dead the moment it was switched back on (its last stamp was 32 min old: it had been stood down, not dead): $(sed -n 3p "$SINKS/notify.log" | cut -c1-200)"
else ok "G10b ...and nobody is told the daemon 'is not closing rounds' at the moment of the lift (calls=$(ncalls): DESLIGADA, religada)"; fi
gwalk 540; n1=$(ncalls)
gwalk 120; n2=$(ncalls)
{ [ "$n1" = 2 ] && [ "$n2" = 3 ] && [[ "$(call_n 3)" == *"não está fechando rodadas"* ]]; } && ok "G10c a daemon that is STILL silent 10 min after the lift is told (calls at 9 min/11 min after the lift: $n1/$n2) - the grace is 10 minutes, not forever" || bad "G10c calls=$n1/$n2: $(call_n 3 | cut -c1-200)"
# the same for the operator's switches: the daemon (and the guard) do nothing while they are on
g10_off() { # g10_off <file|env>: the mechanism is switched off for 30 min by <city>/.gc/no-pool-account or by GC_POOL_ACCOUNT=0, then back on
  local kind="$1"
  new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; gtick 60
  if [ "$kind" = file ]; then
    touch "$CITY/.gc/no-pool-account"; gtick 600; gtick 600; gtick 600; rm -f "$CITY/.gc/no-pool-account"; gtick 60
  else
    gtick 600 GC_POOL_ACCOUNT=0; gtick 600 GC_POOL_ACCOUNT=0; gtick 600 GC_POOL_ACCOUNT=0; gtick 60
  fi
  if grep -q "não está fechando rodadas" "$SINKS/notify.log" 2>/dev/null; then bad "G10d/$kind the mechanism was switched back on and the daemon was called dead at once (its last stamp was 31 min old: it had been switched off)"
  else ok "G10d/$kind switched off for 30 min ($kind), then on: no 'daemon is dead' at the first tick after"; fi
  gwalk 540; n1=$(ncalls); gwalk 120; n2=$(ncalls)
  { [ "$n1" = 0 ] && [ "$n2" = 1 ]; } && ok "G10e/$kind ...and a daemon that really stays silent is told 10 min later (calls at 9/11 min: $n1/$n2)" || bad "G10e/$kind calls=$n1/$n2"
}
g10_off file
g10_off env
# the guard itself was not there (a reboot, a sleep, launchd unloaded): neither was the daemon
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; gtick 60; gtick 60
gtick 7200
[ "$(ncalls)" = 0 ] && ok "G10f the guard's first tick after 2 h of its own absence (reboot/sleep) does not blame the daemon for the heartbeat that went stale meanwhile" || bad "G10f alerted after the guard's own absence: $(call_n 1 | cut -c1-200)"
hb_touch; gtick 60; gwalk 300
[ "$(ncalls)" = 0 ] && ok "G10g ...and a daemon that stamps again is alive" || bad "G10g calls=$(ncalls)"
# a guard that has been watching all along still alerts on the real silence, on time (the old behaviour, unchanged)
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; gwalk 540; n1=$(ncalls); gwalk 120; n2=$(ncalls)
{ [ "$n1" = 0 ] && [ "$n2" = 1 ]; } && ok "G10h a guard that was watching: a stamp 10 min old is alerted at 10 min, not later (calls at 9/11 min: $n1/$n2)" || bad "G10h calls=$n1/$n2"
# 'could not tell' counters do not run through a stand-down either
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; printf 'garbage' > "$CITY/.gc/claude-pool-account.heartbeat"; gtick 60
set_ver 1.0.2; set_mode renamed; gtick 60                                    # degraded: the liveness and divergence checks are not asked any more
[ "$(gj "$GSTATE" blind/daemon-heartbeat)" = "<none>" ] && ok "G10i under the marker the 'cannot read the heartbeat' record is dropped (the check was not asked, its 30 minutes must not run on)" || bad "G10i blind record kept under the marker: $(gj "$GSTATE" blind)"
fi

# ═══ G11. every condition gets its own push ═════════════════════════════════════════════════════════
if want G11; then
echo "G11. notify drops a push whose TITLE went out in the last 30 min (exit 11, whatever the body): two different conditions must not share one"
new_w; active_world; : > "$SINKS/notify.titledup"; gtick 0
put_item "$KEY_b"; div3                                                       # a is the rule, the pool is on b
put_item "$KEY_a"; gtick 60                                                   # fixed: the episode closes
put_item "$KEY_c"; div3                                                       # NEW episode, 6 min later: the pool is on c
{ [ "$(ncalls)" = 2 ] && [ "$(ndelivered)" = 2 ]; } && ok "G11 two divergences 6 min apart, a->b then a->c: BOTH reached the phone (they carry different fingerprints in the title)" || bad "G11 asked notify $(ncalls)x, delivered $(ndelivered): $(cat "$SINKS/notify.delivered" 2>/dev/null | cut -c1-120 | tr '\n' '|')"
new_w; HB_AUTO=0; put_item "$KEY_a"; put_decision a@t.test "$FP_a"; hb_touch; : > "$SINKS/notify.titledup"
printf 'garbage' > "$CITY/.gc/claude-pool-account.heartbeat"; : > "$INFRA/kc/locked"          # three things the guard cannot see, one cause
gtick 0; for _i in 1 2 3 4 5 6 7; do gtick 300; done
{ [ "$(ncalls)" = 3 ] && [ "$(ndelivered)" = 3 ]; } && ok "G11a three 'guard is blind' alerts at 30 min (divergence, daemon-heartbeat, the self-test): all THREE reached the phone" || bad "G11a asked notify $(ncalls)x, delivered $(ndelivered): $(cat "$SINKS/notify.delivered" 2>/dev/null | cut -c1-100 | tr '\n' '|')"
miss=""; for w in "divergence" "daemon-heartbeat" "self-test of claude 1.0.0"; do grep -qF "guarda sem enxergar ($w)" "$SINKS/notify.delivered" 2>/dev/null || miss="$miss [$w]"; done
[ -z "$miss" ] && ok "G11b ...each title says WHAT the guard cannot see" || bad "G11b the title does not say what the guard cannot see:$miss"
rm -f "$INFRA/kc/locked"
new_w; active_world; : > "$SINKS/notify.titledup"; set_ver 1.0.2; set_mode renamed; gtick 60; set_ver 1.0.3; gtick 60
{ [ "$(ncalls)" = 2 ] && [ "$(ndelivered)" = 2 ]; } && ok "G11c claude 1.0.2 fails and a minute later 1.0.3 fails too: both 'auto-switch OFF' pushes reached the phone (the version is in the title)" || bad "G11c asked $(ncalls)x, delivered $(ndelivered): $(cat "$SINKS/notify.delivered" 2>/dev/null | cut -c1-100 | tr '\n' '|')"
# an identical repeat is still ONE push (that is what rc 11 is for)
new_w; active_world; : > "$SINKS/notify.titledup"; gtick 0; put_item "$KEY_b"; div3; put_item "$KEY_a"; gtick 60; put_item "$KEY_b"; div3
{ [ "$(ncalls)" = 2 ] && [ "$(ndelivered)" = 1 ]; } && ok "G11d the SAME divergence again within 30 min -> the phone gets it once (notify's dedup is respected, and counted as 'already pushed')" || bad "G11d asked $(ncalls)x, delivered $(ndelivered)"
fi

# ═══ G12. a failed test the guard cannot act on is said out loud ════════════════════════════════════
if want G12; then
echo "G12. the self-test failed but the marker cannot be written: that is the worst state, so it is told, not just logged"
if [ "$(id -u)" != 0 ]; then
  new_w; active_world; gtick 0                                                 # the lock file exists now
  chmod 555 "$CITY/.gc"; set_ver 1.0.2; set_mode renamed; gtick 60; gtick 60; gtick 60
  { [ ! -e "$marker" ] && [ "$(gv 1.0.2 result)" = fail ] && [ "$(ncalls)" = 1 ]; } && ok "G12 .gc not writable: the test FAILS, no marker can be written, and ONE push says so (3 ticks)" || bad "G12 marker=$([ -e "$marker" ] && echo yes || echo no) result='$(gv 1.0.2 result)' calls=$(ncalls)"
  c="$(call_n 1)"
  { [[ "$c" == *"NÃO foi desligada"* ]] && [[ "$c" == *"1.0.2"* ]] && [[ "$c" == *"[-p] [4]"* ]] && [[ "$c" != *"DESLIGADA"* ]]; } && ok "G12a ...it says the switch is still ON (not 'OFF'), names the version, priority 4" || bad "G12a: $c"
  [ "$(gj "$GSTATE" degraded)" = "<none>" ] && ok "G12b ...and the guard does not record a degradation it never made" || bad "G12b degraded recorded: $(gj "$GSTATE" degraded)"
  gtick 60; gtick 60
  { [ "$(ncalls)" = 1 ] && [ ! -e "$marker" ]; } && ok "G12c still unwritable 2 ticks later: the push is not repeated every minute" || bad "G12c calls=$(ncalls)"
  chmod 755 "$CITY/.gc"; gtick 60
  { [ -s "$marker" ] && [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"DESLIGADA"* ]]; } && ok "G12d once .gc is writable again the marker is written on the next tick and the normal 'auto-switch OFF' push goes out" || bad "G12d marker=$([ -s "$marker" ] && echo yes || echo no) calls=$(ncalls)"
  [ "$(gj "$GSTATE" marker_failed)" = "<none>" ] && ok "G12e ...and the 'could not write' record is closed" || bad "G12e record kept: $(gj "$GSTATE" marker_failed)"
else
  ok "G12 skipped (root can write anywhere)"
fi
fi

# ═══ G13. a marker that is not the guard's ══════════════════════════════════════════════════════════
if want G13; then
echo "G13. a self-test that passes while someone else's marker is still up does not announce that auto-switch is back"
new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60                 # degraded by the guard: DESLIGADA
printf '{"by":"someone-else"}\n' > "$marker"                                   # ...and the marker is replaced by one the guard did not write
set_ver 1.0.3; set_mode ok; gtick 60
{ [ -s "$marker" ] && [ "$(ncalls)" = 1 ] && [ "$(gj "$GSTATE" degraded/version)" = "1.0.2" ]; } && ok "G13 the test passes, the foreign marker stays, and NO 'religada' goes out (calls=$(ncalls)); the guard still knows it had degraded" || bad "G13 marker=$([ -s "$marker" ] && echo yes || echo no) calls=$(ncalls) degraded=$(gj "$GSTATE" degraded/version): $(call_n 2 | cut -c1-160)"
gl | grep -q "not written by this guard" && ok "G13a ...and the log says why" || bad "G13a no explanation in the log"
gtick 60; gtick 60; [ "$(ncalls)" = 1 ] && ok "G13b the next ticks do not announce it either" || bad "G13b calls=$(ncalls)"
[ "$(gl | grep -c "not written by this guard")" = 1 ] && ok "G13b2 ...and 'left alone' is said once, not on every tick of the next hours" || bad "G13b2 said $(gl | grep -c "not written by this guard") times"
rm -f "$marker"; gtick 60
{ [ "$(ncalls)" = 2 ] && [[ "$(call_n 2)" == *"religada"* ]] && [ "$(gj "$GSTATE" degraded)" = "<none>" ]; } && ok "G13c when the foreign marker is gone, THEN 'religada' goes out and the record closes" || bad "G13c calls=$(ncalls) degraded=$(gj "$GSTATE" degraded): $(call_n 2 | cut -c1-160)"
fi

# ═══ G14. `selftest` says what it did ═══════════════════════════════════════════════════════════════
if want G14; then
echo "G14. claude-pool-guard.py selftest: the operator can tell 'it ran, and this is the verdict' from 'it did nothing'"
new_w; active_world
run_guard -- selftest
{ [ "$GRC" = 0 ] && grep -q "claude 1.0.0: pass" "$LAST"; } && ok "G14 a passing claude -> says 'claude 1.0.0: pass', rc 0" || bad "G14 rc=$GRC out='$(head -c 300 "$LAST")'"
set_ver 1.0.2; set_mode renamed; run_guard -- selftest
{ [ "$GRC" = 3 ] && grep -q "claude 1.0.2: fail" "$LAST" && grep -q "auto-switch is now OFF" "$LAST" && [ -s "$marker" ]; } && ok "G14a a failing claude -> says 'fail' and that auto-switch is OFF, rc 3, marker written" || bad "G14a rc=$GRC out='$(head -c 400 "$LAST")'"
set_mode ok; run_guard -- selftest
{ [ "$GRC" = 0 ] && grep -q "claude 1.0.2: pass" "$LAST" && grep -q "auto-switch is now on" "$LAST" && [ ! -e "$marker" ]; } && ok "G14b it passes again -> says so, 'auto-switch is now on', rc 0, marker lifted" || bad "G14b rc=$GRC out='$(head -c 400 "$LAST")'"
set_mode hang; run_guard CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=1 -- selftest
{ [ "$GRC" = 4 ] && grep -q "inconclusive" "$LAST"; } && ok "G14c a claude that hangs -> 'inconclusive', rc 4 (neither pass nor fail)" || bad "G14c rc=$GRC out='$(head -c 300 "$LAST")'"
set_mode ok
# the launchd tick holds the single-instance lock: the operator must not be told nothing
"$PY3" -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(40)' "$CITY/.gc/claude-pool-guard.lock" > "$W/held.out" &
HOLD_PID=$!; BG_PIDS="$BG_PIDS $HOLD_PID"; n=0; while [ ! -s "$W/held.out" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
c0=$(claude_auth_calls); run_guard -- selftest
{ [ "$GRC" = 1 ] && grep -q "NOT run" "$LAST" && grep -q "another guard run" "$LAST" && [ "$(claude_auth_calls)" = "$c0" ]; } && ok "G14d the lock is held -> 'the self-test was NOT run (another guard run holds the lock)', rc 1, claude not asked" || bad "G14d rc=$GRC out='$(head -c 300 "$LAST")'"
run_guard -- run-once; [ "$GRC" = 0 ] && ok "G14e ...while the launchd tick (run-once) keeps its quiet rc 0 under the same contention" || bad "G14e run-once rc=$GRC"
kill "$HOLD_PID" 2>/dev/null; wait "$HOLD_PID" 2>/dev/null
run_guard GC_POOL_ACCOUNT=0 -- selftest
{ [ "$GRC" = 1 ] && grep -q "NOT run" "$LAST" && grep -q "GC_POOL_ACCOUNT=0" "$LAST"; } && ok "G14f the operator's kill switch is on -> 'NOT run: disabled by GC_POOL_ACCOUNT=0', rc 1" || bad "G14f rc=$GRC out='$(head -c 300 "$LAST")'"
run_guard GC_LOWPRIO_CLAUDE_BIN=no-such-claude-binary-xyz -- selftest
{ [ "$GRC" = 1 ] && grep -q "NOT run" "$LAST"; } && ok "G14g no claude to ask -> 'NOT run', rc 1" || bad "G14g rc=$GRC out='$(head -c 300 "$LAST")'"
fi

# ═══ G15. the leak scanner does not walk past a link ════════════════════════════════════════════════
if want G15; then
echo "G15. leakscan: a symlink is read through, provably covered, or reported - never skipped in silence"
new_w; LK="$W/lk"; rm -rf "$LK"; mkdir -p "$LK/tree/sub" "$LK/outside/dir"
printf 'clean\n' > "$LK/tree/a.txt"; printf 'x %s y\n' "$KEY_c" > "$LK/outside/secret.txt"; printf 'x %s y\n' "$KEY_d" > "$LK/outside/dir/inner.txt"
scan --path "$LK/tree"; [ "$S_RC" = 0 ] && grep -q "control=ok" "$SINKS/scan2.out" && ok "G15 baseline: the tree is clean (control ok)" || bad "G15 baseline rc=$S_RC: $(head -c 300 "$SINKS/scan2.out")"
ln -s "$LK/outside/secret.txt" "$LK/tree/sub/log-link"
scan --path "$LK/tree"
{ [ "$S_RC" = 1 ] && grep -q "location=$LK/tree/sub/log-link account=c@t.test" "$SINKS/scan2.out"; } && ok "G15a a symlink INSIDE the scanned tree to a file with a key in it -> found, under the link's name (exit 1), not 'clean'" || bad "G15a rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$LK/tree/sub/log-link"; ln -s "$LK/outside/dir" "$LK/tree/dir-link"
scan --path "$LK/tree"
{ [ "$S_RC" = 3 ] && grep -q "BLIND $LK/tree/dir-link: is a symlink to a directory that is not scanned" "$SINKS/scan2.out"; } && ok "G15b a symlink to a directory that is NOT among the scanned paths -> BLIND (exit 3), naming it and what to add" || bad "G15b rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
scan --path "$LK/tree" --path "$LK/outside"
{ [ "$S_RC" = 1 ] && grep -q "dir/inner.txt account=d@t.test" "$SINKS/scan2.out" && ! grep -q "^BLIND" "$SINKS/scan2.out"; } && ok "G15c ...and naming that directory as well covers the link: not blind, and what is in it is found" || bad "G15c rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$LK/tree/dir-link"; ln -s "$LK/tree" "$LK/tree/self"
scan --path "$LK/tree"
{ [ "$S_RC" = 0 ] && ! grep -q "^BLIND" "$SINKS/scan2.out"; } && ok "G15d a link back to the scanned tree itself (the real shared/data/data -> shared/data) is covered, not blind and not followed into a loop" || bad "G15d rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$LK/tree/self"; ln -s "$LK/does-not-exist" "$LK/tree/dangling"
scan --path "$LK/tree"
{ [ "$S_RC" = 3 ] && grep -q "BLIND $LK/tree/dangling: " "$SINKS/scan2.out"; } && ok "G15e a dangling symlink -> BLIND (exit 3): it cannot be looked at" || bad "G15e rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$LK/tree/dangling"; ln -s "$LK/outside/secret.txt" "$LK/top-link"
scan --path "$LK/top-link"
{ [ "$S_RC" = 1 ] && grep -q "account=c@t.test" "$SINKS/scan2.out"; } && ok "G15f a top-level --path that is a symlink to a file is read through the same way" || bad "G15f rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
# --watch-ps samples the process list only. A --path given with it used to be dropped without a word while the file control still ran: a key
# planted in that file came back as 'clean', the same green as a file that was read.
: > "$W/stop-now"
scan --watch-ps "$W/stop-now" --path "$LK/outside/secret.txt"
{ [ "$S_RC" = 2 ] && grep -q -- "--watch-ps" "$SINKS/scan2.out" && ! grep -q "^SUMMARY" "$SINKS/scan2.out"; } && ok "G15g --watch-ps with --path is refused (exit 2, says why), not answered 'clean' for files it never read" || bad "G15g rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
fi

# ═══ G16. the quiet notice follows notify's router; a record of a superseded version goes ═══════════
if want G16; then
echo "G16. 'religada' is accepted where notify's router sends it (digest, 12) and not retried for ever; a forced push the router did not take IS retried; a blind record of a version that is gone is dropped"
# gate ga-rtps35 B1: the real notify answers the unforced notice with 12. The episode used to stay open and the notice went out every minute for ever.
new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60
set_ver 1.0.3; set_mode ok; gtick 60; n1=$(ncalls)
for _i in 1 2 3 4 5 6 7 8 9 10; do gtick 60; done
{ [ "$n1" = 2 ] && [ "$(ncalls)" = 2 ] && [ "$(gj "$GSTATE" degraded)" = "<none>" ] && [[ "$(call_n 2)" == *"religada"* ]] && [[ "$(call_n 2)" == *"strict=1"* ]]; } && ok "G16 B1: the notice is sent ONCE (exit 12 = the digest, where a quiet notice is meant to go), the episode closes, 10 ticks later no repeat" || bad "G16 calls $n1 -> $(ncalls) degraded=$(gj "$GSTATE" degraded)"
# the same exit 12 on a FORCED push is the rate cap: nothing reached the phone, so it is NOT delivered and is tried again
new_w; active_world; : > "$SINKS/notify.cap"; set_ver 1.0.2; set_mode renamed; gtick 60; gtick 60; gtick 60; n_cap=$(ncalls)
rm -f "$SINKS/notify.cap"; gtick 60; n_after=$(ncalls); gtick 60; gtick 60
{ [ "$n_cap" = 3 ] && [ "$n_after" = 4 ] && [ "$(ncalls)" = 4 ] && [ "$(ndelivered)" = 1 ] && [[ "$(call_n 4)" == *"DESLIGADA"* ]]; } && ok "G16a a FORCED 'auto-switch OFF' that meets the rate cap (12) is retried every tick until it goes out, then not again" || bad "G16a calls under the cap=$n_cap, after=$n_after, end=$(ncalls), delivered=$(ndelivered)"
# a notice notify will not take (any other exit): tried for a while, then given up with a line in the log - never for ever
new_w; active_world; set_ver 1.0.2; set_mode renamed; gtick 60
set_ver 1.0.3; set_mode ok; printf 14 > "$SINKS/notify.rc"; gtick 60; gtick 600; n_a=$(ncalls); d_a=$(gj "$GSTATE" degraded)
gtick 600; gtick 600; gtick 600; n_b=$(ncalls); d_b=$(gj "$GSTATE" degraded); gtick 600; gtick 600; n_c=$(ncalls)
{ [ "$n_a" = 3 ] && [ "$d_a" != "<none>" ] && [ "$d_b" = "<none>" ] && [ "$n_c" = "$n_b" ]; } && ok "G16b a notice notify keeps refusing: retried for 30 min, then the record is closed and it stops (calls $n_a -> $n_b -> $n_c)" || bad "G16b calls $n_a/$n_b/$n_c degraded $d_a / $d_b"
gl | grep -q "gave up announcing" && ok "G16c ...and the log says it gave up" || bad "G16c no 'gave up' line: $(gl | tail -3)"
# B-low: the blind record of a self-test of a claude that is no longer the installed one is dropped, not kept for ever
new_w; active_world; set_ver 1.0.0; set_mode hang
for _i in 1 2 3 4 5 6 7; do gtick 300 CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=1; done
b_before="$(gj "$GSTATE" "blind/self-test of claude 1.0.0")"
set_ver 1.0.1; set_mode ok; gtick 60
{ [ "$b_before" != "<none>" ] && [ "$(gj "$GSTATE" "blind/self-test of claude 1.0.0")" = "<none>" ] && [ "$(gv 1.0.1 result)" = pass ]; } && ok "G16d a claude update drops the 'cannot verify' record of the old version (it would otherwise stay in the state and in 'status' for ever)" || bad "G16d before=$b_before after=$(gj "$GSTATE" blind) 1.0.1=$(gv 1.0.1 result)"
# whether the marker is up cannot be told (on Python 3.9 Path.exists raises PermissionError): a traceback is no answer, and neither is 'no marker'
new_w; active_world; base=(); while IFS= read -r l; do base+=("$l"); done < <(BASE_ENV)
env -i "${base[@]}" "$PY3" -I -c '
import importlib.util, pathlib, sys
sp = importlib.util.spec_from_file_location("g", sys.argv[1]); g = importlib.util.module_from_spec(sp); sp.loader.exec_module(g)
g.D = g.load_daemon(); real = pathlib.Path.exists
def exists(self):
    if self.name == g.D.DEGRADED_MARKER: raise PermissionError(13, "selftest")
    return real(self)
pathlib.Path.exists = exists
gs = {}; print(g.apply_result(gs, g.D.now(), "1.0.3", "pass", ""), sorted(gs.get("blind", {})), gs.get("degraded"))' "$GUARD" > "$SINKS/inproc.out" 2>&1
{ [ "$(cat "$SINKS/inproc.out")" = "unchanged ['degraded-marker'] None" ] && [ "$(ncalls)" = 0 ]; } && ok "G16e a marker whose presence cannot be told: nothing changed, nothing announced ('religada' needs a marker known to be gone), the guard records that it is blind" || bad "G16e: $(head -c 300 "$SINKS/inproc.out")"
fi

# ═══ G17. leakscan: 'could not look' is exit 3 ═══════════════════════════════════════════════════════
if want G17; then
echo "G17. leakscan: what could not be looked at ends BLIND (3) - never as 'a key was found' (1), never as a clean end (0), never hangs"
new_w; LK="$W/lk17"; rm -rf "$LK"; mkdir -p "$LK/tree/sub"; printf 'clean\n' > "$LK/tree/a.txt"
# B2a: the sampling window ended by --watch-max, not by the stop file: the scenario may have run past it
rm -f "$W/never-stop"
scan --watch-ps "$W/never-stop" --interval 0.1 --watch-max 1
{ [ "$S_RC" = 3 ] && grep -q "^BLIND .*--watch-max" "$SINKS/scan2.out" && grep -q "^SUMMARY .*blind=1" "$SINKS/scan2.out"; } && ok "G17 B2a: --watch-ps that ran out at --watch-max without the stop file is BLIND (exit 3, says so), not a clean end" || bad "G17 B2a rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$W/stop-late"; ( sleep 1; : > "$W/stop-late" ) & BG_PIDS="$BG_PIDS $!"
scan --watch-ps "$W/stop-late" --interval 0.1 --watch-max 30
{ [ "$S_RC" = 0 ] && ! grep -q "^BLIND" "$SINKS/scan2.out"; } && ok "G17a ...a stop file that appears in time still ends it clean (exit 0)" || bad "G17a rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
: > "$W/stop-now"; scan --watch-ps "$W/stop-now" --interval 0.1 --watch-max 1
{ [ "$S_RC" = 0 ] && ! grep -q "^BLIND" "$SINKS/scan2.out"; } && ok "G17b ...and so does one that was there from the start" || bad "G17b rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
# B2b: a stat that fails (Python 3.9's Path.is_dir/is_symlink raise PermissionError) was a traceback and exit 1 - the code for 'a key was found'
if [ "$(id -u)" != 0 ]; then
  mkdir -p "$LK/tree/noexec" "$LK/locked"; printf 'x\n' > "$LK/tree/noexec/f.txt"; printf 'x\n' > "$LK/locked/f.txt"
  chmod 644 "$LK/tree/noexec"; scan --path "$LK/tree"; rc1=$S_RC; out1="$(cat "$SINKS/scan2.out")"
  { [ "$rc1" = 3 ] && [[ "$out1" == *"BLIND $LK/tree/noexec/f.txt"* ]] && [[ "$out1" != *Traceback* ]]; } && ok "G17c B2b: a directory that lists but cannot be entered -> BLIND naming the file (exit 3), no traceback, not 'a key was found'" || bad "G17c rc=$rc1: $(printf '%s' "$out1" | head -c 400)"
  printf 'x %s y\n' "$KEY_c" > "$LK/tree/sub/leak.txt"; scan --path "$LK/tree"; rc1=$S_RC; out1="$(cat "$SINKS/scan2.out")"; chmod 755 "$LK/tree/noexec"; rm -f "$LK/tree/sub/leak.txt"
  { [ "$rc1" = 1 ] && [[ "$out1" == *"location=$LK/tree/sub/leak.txt account=c@t.test"* ]] && [[ "$out1" == *"BLIND $LK/tree/noexec/f.txt"* ]]; } && ok "G17c2 ...and what could not be entered does not stop the rest of the tree from being read: a key elsewhere is still found (exit 1 wins over 3)" || bad "G17c2 rc=$rc1: $(printf '%s' "$out1" | head -c 400)"
  chmod 000 "$LK/locked"; scan --path "$LK/locked/f.txt"; rc2=$S_RC; out2="$(cat "$SINKS/scan2.out")"; chmod 755 "$LK/locked"
  { [ "$rc2" = 3 ] && [[ "$out2" == *"BLIND $LK/locked/f.txt"* ]] && [[ "$out2" != *Traceback* ]]; } && ok "G17d B2b: a --path that cannot be reached -> BLIND (exit 3), no traceback" || bad "G17d rc=$rc2: $(printf '%s' "$out2" | head -c 400)"
else
  ok "G17c-d skipped (root can read anywhere)"
fi
# a FIFO in the tree: opening it for reading would wait for a writer for ever
TMO="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TMO" ]; then ok "G17e-f skipped (no timeout(1) to stop a scan that hangs)"; else
mkfifo "$LK/tree/sub/pipe"
keys_json | "$TMO" 20 "$PY3" "$LEAKSCAN" --keys-stdin --path "$LK/tree" > "$SINKS/scan2.out" 2>&1; S_RC=$?
{ [ "$S_RC" = 3 ] && grep -q "BLIND $LK/tree/sub/pipe: is not a regular file" "$SINKS/scan2.out"; } && ok "G17e a FIFO in the scanned tree -> BLIND (exit 3) naming it, and the scan does not hang" || bad "G17e rc=$S_RC (124 = hung): $(head -c 400 "$SINKS/scan2.out")"
keys_json | "$TMO" 20 "$PY3" "$LEAKSCAN" --keys-stdin --path "$LK/tree/sub/pipe" > "$SINKS/scan2.out" 2>&1; S_RC=$?
{ [ "$S_RC" = 3 ] && grep -q "BLIND $LK/tree/sub/pipe: is not a regular file" "$SINKS/scan2.out"; } && ok "G17f ...also as a top-level --path (and it is not called 'does not exist')" || bad "G17f rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$LK/tree/sub/pipe"
fi
# whatever else goes wrong inside the scan: exit 3 and a BLIND line, never a traceback with exit 1
keys_json | "$PY3" -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("ls", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def boom(*a, **k): raise RuntimeError("selftest: an error nobody planned for")
m.scan_paths = boom
sys.exit(m.run(["x", "--keys-stdin", "--path", sys.argv[2]]))' "$LEAKSCAN" "$LK/tree" > "$SINKS/scan2.out" 2>&1; S_RC=$?
{ [ "$S_RC" = 3 ] && grep -q "^BLIND .*RuntimeError" "$SINKS/scan2.out" && ! grep -q Traceback "$SINKS/scan2.out"; } && ok "G17g an unexpected error inside the scan -> BLIND naming its type, exit 3 (exit 1 is only ever 'a key was found')" || bad "G17g rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
# a key-shaped stranger cut by a read boundary is reported by the fingerprint of the WHOLE text (the first read only saw the beginning of it)
stranger="sk-ant-oat01-STRANGERabcdefghij0123456789ABCD"; fp_s="$(printf '%s' "$stranger" | shasum -a 256 | cut -c1-8)"
printf '%040d%s\n' 0 "$stranger" > "$LK/straddle.txt"
scan --path "$LK/straddle.txt" --chunk 64
{ [ "$S_RC" = 1 ] && grep -q "form=shape:$fp_s " "$SINKS/scan2.out"; } && ok "G17i a stranger that straddles a read boundary carries its own fingerprint ($fp_s), not the one of the half the first read saw" || bad "G17i rc=$S_RC want shape:$fp_s: $(head -c 300 "$SINKS/scan2.out")"
scan --watch-ps "$W/stop-now" --interval -1
{ [ "$S_RC" = 2 ]; } && ok "G17h a negative --interval is a usage error (exit 2), not a crash in the sampler" || bad "G17h rc=$S_RC: $(head -c 300 "$SINKS/scan2.out")"
fi

# ═══ G7. AC4: no key leaks, proven with a scanner that is proven to see ═════════════════════════════
e2e() { # e2e <label> <daemon> <guard>: a switch, a divergence, forced errors, a degradation; then the scan. Sets E_RC, E_OUT, E_WATCH_RC, E_WATCH_OUT
  local label="$1" dmn="$2" grd="$3" DAEMON_SAVE="$DAEMON" GUARD_SAVE="$GUARD"
  DAEMON="$dmn"; GUARD="$grd"
  new_w
  "$PY3" "$W/mock_api.py" "$INFRA/srv.json" "$SINKS/probes.log" "$INFRA/port" & SRV_PID=$!
  keys_json | "$PY3" -c '
import json, sys
keys = json.load(sys.stdin); ok = json.loads(sys.argv[3]); rej = json.loads(sys.argv[4])
allowed = {t: {"status": 200, "h": ok} for t in keys.values()}
a_rej = dict(allowed); a_rej[keys["a@t.test"]] = {"status": 429, "h": rej}
b_rej = dict(allowed); b_rej[keys["b@t.test"]] = {"status": 429, "h": rej}
for name, d in (("srv.json", allowed), ("srv.ok.json", allowed), ("srv.a-rej.json", a_rej), ("srv.b-rej.json", b_rej)):
    json.dump(d, open(sys.argv[1] + "/" + name, "w"))' "$INFRA" "-" "$HDR_OK" "$HDR_REJ"
  local n=0; while [ ! -s "$INFRA/port" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  rm -f "$W/stop" "$W/ready"
  # the sampler: every process's argv and environment, every 0.1 s, from before the first run to after the last; only hits are kept
  keys_json | "$PY3" "$LEAKSCAN" --keys-stdin --watch-ps "$W/stop" --ready-file "$W/ready" --interval 0.1 --watch-max 900 > "$SINKS/watch.out" 2>&1 &
  WATCH_PID=$!; BG_PIDS="$BG_PIDS $WATCH_PID"
  n=0; while [ ! -e "$W/ready" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n+1)); done
  # 1. a complete account switch through the real daemon: seed a, then a is rejected -> the pool moves to b
  run_d -- run-once
  NOW=$((NOW + 600)); cp "$INFRA/srv.a-rej.json" "$INFRA/srv.json"; run_d -- run-once
  # 2. a pool session launched through the wrapper (its whole environment is recorded)
  run_wrapper -- -p hello
  # 3. the guard: healthy pass, then a divergence that gets alerted (the item is tampered to c's key), then fixed
  hb_touch; gtick 0
  cp "$INFRA/kc/items/$SVC" "$W/item.b"; put_item "$KEY_c"; gtick 60; gtick 130; gtick 130
  cp "$W/item.b" "$INFRA/kc/items/$SVC"; gtick 60
  # 4. forced errors, every path that prints something about a credential
  cp "$INFRA/srv.b-rej.json" "$INFRA/srv.json"
  touch "$INFRA/kc/refuse-writes"; NOW=$((NOW + 600)); run_d -- run-once; rm -f "$INFRA/kc/refuse-writes"
  touch "$INFRA/kc/write-lands-other"; NOW=$((NOW + 600)); run_d -- run-once; rm -f "$INFRA/kc/write-lands-other"
  : > "$INFRA/vault/.broken"; NOW=$((NOW + 600)); run_d -- run-once; gtick 60; rm -f "$INFRA/vault/.broken"
  : > "$INFRA/kc/locked"; NOW=$((NOW + 600)); run_d -- run-once; gtick 60; run_wrapper -- -p hello; rm -f "$INFRA/kc/locked"
  cp "$STATE" "$W/state.good"; printf '{"current": ' > "$STATE"; NOW=$((NOW + 600)); run_d -- run-once; gtick 60; cp "$W/state.good" "$STATE"
  chmod 555 "$DATA"; NOW=$((NOW + 600)); run_d -- run-once; chmod 755 "$DATA"
  NOW=$((NOW + 600)); run_d CLAUDE_POOL_ACCOUNTS_LIB="$W/no-such-lib.py" -- run-once
  printf 1 > "$SINKS/notify.rc"; put_item "$KEY_c"; gtick 60; gtick 130; gtick 130; gtick 400 CLAUDE_POOL_NOTIFY_CMD="$W/no-such-notify"; rm -f "$SINKS/notify.rc"; cp "$W/item.b" "$INFRA/kc/items/$SVC"
  printf 'garbage' > "$GSTATE"; gtick 60
  set_mode garbage; set_ver 1.0.1; gtick 60; gtick 2000 CLAUDE_POOL_GUARD_CLAUDE_TIMEOUT_S=1; set_mode ok
  # 5. a degradation (a claude release that changed the internals), then the daemon and a launch under it
  set_ver 1.0.2; set_mode renamed; gtick 60
  NOW=$((NOW + 600)); run_d -- run-once; run_wrapper -- -p hello
  gtick 60 CLAUDE_POOL_GUARD_FAULT=rename
  # 6. the end of the sampling window; the scan of everything the product wrote
  touch "$W/stop"; wait "$WATCH_PID"; E_WATCH_RC=$?; E_WATCH_OUT="$SINKS/watch.out"
  [ -n "$SRV_PID" ] && { kill "$SRV_PID" 2>/dev/null; SRV_PID=""; }
  DAEMON="$DAEMON_SAVE"; GUARD="$GUARD_SAVE"
  E_OUT="$SINKS/scan.out"
  keys_json | "$PY3" "$LEAKSCAN" --keys-stdin --ps --path "$PROD" --path "$SINKS" > "$E_OUT" 2>&1; E_RC=$?
}

if want G7; then
echo "G7. AC4: after a full switch, a degradation and forced errors, no key is anywhere it must not be"
e2e real "$DAEMON" "$GUARD"
# the scenario really happened (a scan of a world where nothing ran proves nothing)
{ [ "$(gj "$STATE" current)" = "b@t.test" ] || [ "$(gj "$STATE" previous)" = "a@t.test" ] || [ "$(gj "$STATE" current)" != "a@t.test" ]; } && ok "G7 the account really switched (decision: $(gj "$STATE" current), previous: $(gj "$STATE" previous))" || bad "G7 the pool never left a: nothing to scan"
{ [ -s "$marker" ] && [ "$(ncalls)" -ge 3 ] && grep -q "DESLIGADA" "$SINKS/notify.log" && grep -q "diverge" "$SINKS/notify.log"; } && ok "G7a the guard degraded and alerted about a divergence ($(ncalls) notifications were sent)" || bad "G7a marker=$([ -s "$marker" ] && echo yes || echo no) notifications=$(ncalls)"
{ grep -q "ERROR" "$CITY/.gc/logs/claude-pool-account.log" && ls "$DATA"/current.json.corrupt.* >/dev/null 2>&1 && grep -q "answer\|ARGV" "$SINKS/claude-launch.log"; } && ok "G7b the forced errors happened (daemon ERRORs logged, a corrupt state moved aside, agents launched)" || bad "G7b the error paths did not run: $(grep -c ERROR "$CITY/.gc/logs/claude-pool-account.log" 2>/dev/null) errors"
if [ "$E_RC" = 0 ] && grep -q "keys=5 " "$E_OUT" && grep -q "control=ok" "$E_OUT"; then ok "G7c ZERO occurrences of any of the 5 keys in argv, env, logs, the decision file, error output, notifications (control ok, 5 keys searched): $(tail -1 "$E_OUT")"; else bad "G7c scan rc=$E_RC: $(head -c 800 "$E_OUT")"; fi
{ [ "$E_WATCH_RC" = 0 ] && grep -q "control=ok" "$E_WATCH_OUT" && ! grep -q "samples=0" "$E_WATCH_OUT"; } && ok "G7d the process sampler ran during the whole scenario and saw no key in any argv/env: $(tail -1 "$E_WATCH_OUT")" || bad "G7d sampler rc=$E_WATCH_RC: $(head -c 600 "$E_WATCH_OUT")"
for ch in "$SINKS/notify.log" "$SINKS/kc-argv.log" "$SINKS/claude-env.log" "$CITY/.gc/logs/claude-pool-account.log" "$CITY/.gc/logs/claude-pool-guard.log" "$STATE" "$GSTATE"; do [ -s "$ch" ] || bad "G7e channel is empty, so scanning it proves nothing: ${ch#$W/}"; done; ok "G7e every channel the scan covers had content (nothing was clean because it was empty)"

# the control: the same scan, a key planted on purpose in each kind of place
echo "G7f. the control: the same scan finds a key planted on purpose"
cp "$CITY/.gc/logs/claude-pool-account.log" "$W/log.orig"; printf 'planted %s\n' "$KEY_e" >> "$CITY/.gc/logs/claude-pool-account.log"
scan --ps --path "$PROD" --path "$SINKS"
{ [ "$S_RC" = 1 ] && grep -q "channel=file location=$CITY/.gc/logs/claude-pool-account.log account=e@t.test (fp $(fp_of "$KEY_e")) form=raw" "$SINKS/scan2.out"; } && ok "G7f a key planted in the daemon log -> exit 1, naming the file, the account (e-mail + fingerprint) and the form" || bad "G7f rc=$S_RC: $(head -c 500 "$SINKS/scan2.out")"
contains "$SINKS/scan2.out" KEY_e && bad "G7f2 the scanner printed the key it found" || ok "G7f2 ...and its report does not contain the key"
cp "$W/log.orig" "$CITY/.gc/logs/claude-pool-account.log"
printf '%s' "$KEY_d" | xxd -p | tr -d '\n' > "$DATA/current.json.corrupt.1"
scan --path "$PROD"; { [ "$S_RC" = 1 ] && grep -q "account=d@t.test .* form=hex" "$SINKS/scan2.out"; } && ok "G7g the hex of a key left in a leftover state file -> found (form=hex)" || bad "G7g rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$DATA/current.json.corrupt.1"
cp "$SINKS/notify.log" "$W/notify.orig"; printf 'x%s' "$KEY_c" | base64 >> "$SINKS/notify.log"
scan --path "$SINKS"; { [ "$S_RC" = 1 ] && grep -q "account=c@t.test .* form=b64" "$SINKS/scan2.out"; } && ok "G7h a key base64-encoded into a sent notification -> found (form=b64)" || bad "G7h rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
cp "$W/notify.orig" "$SINKS/notify.log"
LEAK_PLANT="$KEY_a" "$PY3" -c 'import time; time.sleep(60)' & P1=$!
"$PY3" -c 'import time; time.sleep(60)' "$KEY_b" & P2=$!; BG_PIDS="$BG_PIDS $P1 $P2"; sleep 1
scan --ps; { [ "$S_RC" = 1 ] && grep -q "channel=ps-env location=pid $P1 .* var=LEAK_PLANT account=a@t.test" "$SINKS/scan2.out" && grep -q "channel=ps-argv location=pid $P2 .* account=b@t.test" "$SINKS/scan2.out"; } && ok "G7i a key in a live process's environment and in another's argv -> both found, by pid (and the variable's NAME for the environment one)" || bad "G7i rc=$S_RC: $(head -c 600 "$SINKS/scan2.out")"
contains "$SINKS/scan2.out" KEY_a || contains "$SINKS/scan2.out" KEY_b && bad "G7i2 the scanner printed a key" || ok "G7i2 ...and printed no key doing it"
kill "$P1" "$P2" 2>/dev/null; wait "$P1" "$P2" 2>/dev/null
LEAK_PLANT_X="$KEY_x" "$PY3" -c 'import time; time.sleep(60)' & P3=$!; BG_PIDS="$BG_PIDS $P3"; sleep 1
scan --ps; { [ "$S_RC" = 0 ] && grep -q "^NOTE channel=ps-env location=pid $P3 .* var=LEAK_PLANT_X form=shape:$FP_x" "$SINKS/scan2.out"; } && ok "G7i3 key-shaped text that is NOT one of the 5 keys, in a process (another service's API key, say) -> a NOTE, not a failed scan" || bad "G7i3 rc=$S_RC: $(head -c 500 "$SINKS/scan2.out")"
kill "$P3" 2>/dev/null; wait "$P3" 2>/dev/null
printf 'x %s y\n' "$KEY_x" > "$SINKS/stranger.txt"; scan --path "$SINKS/stranger.txt"
{ [ "$S_RC" = 1 ] && grep -q "form=shape:$FP_x" "$SINKS/scan2.out"; } && ok "G7i4 the same stranger in a FILE the product wrote -> a finding (exit 1)" || bad "G7i4 rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
rm -f "$SINKS/stranger.txt"
scan --ps --path "$PROD" --path "$SINKS"; [ "$S_RC" = 0 ] && ok "G7j with the plants removed the same scan is clean again (the findings were the plants)" || bad "G7j rc=$S_RC: $(head -c 400 "$SINKS/scan2.out")"
# a scanner that cannot see is not a green scan
echo "G7k. a scan that cannot look is reported as blind, not clean"
scan --path "$W/does-not-exist"; { [ "$S_RC" = 3 ] && grep -q "BLIND" "$SINKS/scan2.out"; } && ok "G7k a path that does not exist -> exit 3 (blind), not 0" || bad "G7k rc=$S_RC"
printf '{"a@t.test":"short"}' | "$PY3" "$LEAKSCAN" --keys-stdin --path "$PROD" > "$SINKS/scan2.out" 2>&1; S_RC=$?
[ "$S_RC" = 3 ] && ok "G7l a key too short to search for -> exit 3, not a clean result" || bad "G7l rc=$S_RC"

# the mutations: a daemon that leaks, and a guard that leaks, must FAIL the same scenario
echo "G7m. mutations: a daemon and a guard that deliberately leak a key must fail the scan"
mkdir -p "$W/mut"
"$PY3" - "$DAEMON" "$W/mut/claude-pool-account.py" "$GUARD" "$W/mut/claude-pool-guard.py" <<'EOF'
import sys
src = open(sys.argv[1]).read()
anchor = "def write_item(user: str, token: str) -> bool:\n"
assert anchor in src, "mutation anchor missing in the daemon"
src = src.replace(anchor, anchor + '    subprocess.run(["security", "find-generic-password", "-a", user, "-s", item_service(), "-j", token], capture_output=True)   # MUTATION: key in argv\n', 1)
open(sys.argv[2], "w").write(src)
g = open(sys.argv[3]).read()
anchor = "    for text in (title, msg):\n"
assert anchor in g, "mutation anchor missing in the guard"
leak = ('    try:\n'
        '        msg = msg + " " + subprocess.run(["security", "find-generic-password", "-a", "athos", "-s", D.item_service(), "-w"], capture_output=True, text=True).stdout.strip()   # MUTATION: the pool credential in the notification\n'
        '    except Exception:\n        pass\n'
        '    for text in ():   # MUTATION: and the refusal switched off\n')
g = g.replace(anchor, leak, 1)
open(sys.argv[4], "w").write(g)
EOF
cp "$DAEMON" "$W/mut/real-daemon.py"
e2e leaky-daemon "$W/mut/claude-pool-account.py" "$GUARD"
{ [ "$E_RC" = 1 ] && grep -q "kc-argv.log" "$E_OUT"; } && ok "G7m a daemon that puts the key in security's argv -> the scan FAILS (exit 1), naming kc-argv.log" || bad "G7m leaky daemon not caught: rc=$E_RC $(head -c 400 "$E_OUT")"
e2e leaky-guard "$DAEMON" "$W/mut/claude-pool-guard.py"
{ [ "$E_RC" = 1 ] && grep -q "notify.log" "$E_OUT"; } && ok "G7n a guard that puts the key in the push notification -> the scan FAILS (exit 1), naming notify.log" || bad "G7n leaky guard not caught: rc=$E_RC $(head -c 400 "$E_OUT")"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
