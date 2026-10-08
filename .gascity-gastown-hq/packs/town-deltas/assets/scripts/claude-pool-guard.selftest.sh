#!/usr/bin/env bash
# claude-pool-guard.selftest.sh — ga-8hcnvb.3.1: the safety net under the pool's account switch (slice 1 of 3: divergence + the daemon's liveness).
#
#   G1-G4  DIVERGENCE: the account the pool really uses vs the account the rule dictates -> one phone alert in < 5 min naming both by
#          e-mail + 8-hex fingerprint, never the key; it stops repeating when fixed; 'could not tell' never alerts as a divergence.
#   G4g    the guard's OWN record (episode start, 'already alerted' stamp, the daemon watch) can be unusable - a 400-digit integer, NaN,
#          a string, a time in the future: that clock restarts; the check neither crashes nor goes silent.
#   G6     the daemon's heartbeat (a daemon that stopped completing runs); G6i: a heartbeat that cannot be read in ANY way (not UTF-8,
#          a 400-digit epoch, an epoch that is not a time) is 'could not tell', never a crash and never a verdict.
#   G10    the daemon's silence is judged only over time the guard was LOOKING: a stand-down (the operator's switches) or the guard's
#          own absence (reboot, sleep) is not a daemon death; a daemon that really stays silent is still told on time. The harness's
#          HB_AUTO=0 is the real daemon (no stamp while stood down); HB_AUTO=1 re-stamps every tick and hid this.
#
# HERMETIC: fake `security` (items in a temp dir), fake `secret` vault, fake `notify` (it models the router and the push cap: a quiet send
# gets rc 12 like the real one), and a clock the test moves (CLAUDE_POOL_NOW). Nothing here touches the real Keychain, vault, network or phone.
# The product under test can be swapped for an older copy: CLAUDE_POOL_GUARD / _DAEMON (see 'previous HEAD' in the doc).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${CLAUDE_POOL_GUARD:-$SELF_DIR/claude-pool-guard.py}"
DAEMON="${CLAUDE_POOL_DAEMON:-$SELF_DIR/claude-pool-account.py}"
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

for f in "$GUARD" "$DAEMON" "$ACCT_LIB"; do [ -f "$f" ] || { echo "FATAL: not found: $f"; exit 1; }; done

_t="${TMPDIR:-/tmp}"; W="$(mktemp -d "${_t%/}/claude-pool-guard-selftest.XXXXXX")"   # no "//" in it: the product hashes paths it normalised, the fakes hash the string they were given
cleanup() { for p in ${BG_PIDS:-}; do kill "$p" 2>/dev/null; done; chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
BG_PIDS=""

# ── the world ──────────────────────────────────────────────────────────────────────────────────────
WW="$W/w"; PROD="$WW/product"; CITY="$PROD/city"; DATA="$PROD/data"; STATE="$DATA/current.json"; GSTATE="$DATA/guard.json"
INFRA="$WW/infra"; SINKS="$WW/sinks"; CAP="$SINKS/cap"; BB="$W/bb"
POOL_DIR="$W/pool-cred"
SVC="Claude Code-credentials-$(printf '%s' "$POOL_DIR" | shasum -a 256 | cut -c1-8)"
NOW_BASE=1999000000
EMAILS=(a@t.test b@t.test c@t.test d@t.test e@t.test)
mkdir -p "$BB"

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
chmod +x "$BB/security" "$BB/secret" "$BB/notify"

NOW=$NOW_BASE; HB_AUTO=1; GRC=0; N_RUN=0
blob_of() { printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":null}}' "$1"; }
put_item() { blob_of "$1" | xxd -p | tr -d '\n' > "$INFRA/kc/items/$SVC"; }            # builtin printf: the key is never in an argv
put_decision() { printf '{"current":"%s","fingerprint":"%s","since":"2033-05-18T03:00:00Z","reason":"selftest","previous":null,"exhausted":{},"schema":1,"updated":"2033-05-18T03:00:00Z"}\n' "$1" "$2" > "$STATE"; }
hb_touch() { printf '{"epoch": %s, "updated": "selftest", "pid": 1}\n' "$NOW" > "$CITY/.gc/claude-pool-account.heartbeat"; }
ncalls() { [ -f "$SINKS/notify.log" ] && wc -l < "$SINKS/notify.log" | tr -d ' ' || echo 0; }
call_n() { sed -n "${1}p" "$SINKS/notify.log"; }
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
  chmod -R u+w "$WW" 2>/dev/null; rm -rf "$WW"
  mkdir -p "$CITY/.gc/logs" "$DATA" "$INFRA/kc/items" "$INFRA/vault" "$INFRA/home" "$SINKS" "$CAP" "$INFRA/home/.gastown"
  : > "$SINKS/kc-argv.log"; : > "$SINKS/kc-ops.log"
  local e; for e in "${EMAILS[@]}"; do key_of "$e" > "$INFRA/vault/$e"; done
  NOW=$NOW_BASE; HB_AUTO=1; N_RUN=0
  stamp_usage
}
BASE_ENV() {
  printf '%s\n' "HOME=$INFRA/home" "USER=athos" "PATH=$BB:/usr/bin:/bin" "GC_CITY_PATH=$CITY" "FAKE_KC=$INFRA/kc" "FAKE_SINKS=$SINKS" "VAULT=$INFRA/vault" \
    "CLAUDE_USAGE_STORE=$INFRA/usage.json" "CLAUDE_POOL_STATE=$STATE" "CLAUDE_POOL_CRED_DIR=$POOL_DIR" "GC_POOL_CRED_DIR=$POOL_DIR" "CLAUDE_POOL_ACCOUNTS_LIB=$ACCT_LIB" \
    "CLAUDE_POOL_NOW=$NOW" "CLAUDE_POOL_DAEMON=$DAEMON" "CLAUDE_POOL_GUARD_STATE=$GSTATE" "CLAUDE_POOL_NOTIFY_CMD=$BB/notify"
}
run_guard() { # run_guard [VAR=val ...] -- <guard args>; output in $LAST, status in $GRC
  local envs=() base=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  while IFS= read -r l; do base+=("$l"); done < <(BASE_ENV)
  N_RUN=$((N_RUN+1)); LAST="$CAP/guard-$N_RUN.txt"
  env -i "${base[@]}" "${envs[@]}" "$PY3" "$GUARD" "$@" > "$LAST" 2>&1; GRC=$?
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
new_w; active_world; gtick 0; printf '{"current": ' > "$STATE"; put_item "$KEY_b"; gtick 60; gtick 130; gtick 130; gtick 130
[ "$(ncalls)" = 0 ] && [ -s "$STATE" ] && ok "G4c unreadable decision file -> no alert, and the guard does not rewrite or move it (it is the daemon's)" || bad "G4c calls=$(ncalls)"
new_w; active_world; put_item "$KEY_b"; for _i in 1 2 3 4 5; do gtick 60 GC_POOL_ACCOUNT=0; done
{ [ "$(ncalls)" = 0 ] && [ ! -e "$GSTATE" ]; } && ok "G4d GC_POOL_ACCOUNT=0 (operator switched the mechanism off) -> the guard does nothing at all (no state, no alert)" || bad "G4d acted under the kill switch (calls=$(ncalls) state=$([ -e "$GSTATE" ] && echo yes || echo no))"
new_w; active_world; touch "$CITY/.gc/no-pool-account"; put_item "$KEY_b"; for _i in 1 2 3 4 5; do gtick 60; done
[ "$(ncalls)" = 0 ] && ok "G4e <city>/.gc/no-pool-account -> the guard does nothing" || bad "G4e acted under no-pool-account"
new_w; for _i in 1 2 3 4 5 6 7 8; do gtick 1200; done
[ "$(ncalls)" = 0 ] && [ "$(gj "$GSTATE" divergence)" = "<none>" ] && ok "G4f never activated (no decision, no item): hours of ticks, nothing said" || bad "G4f alerted on an inactive pool (calls=$(ncalls))"
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

# ═══ G10. a stand-down is not a daemon death ═══════════════════════════════════════════════════════
if want G10; then
echo "G10. the guard judges the daemon's silence only over time it was LOOKING: not over a stand-down, not over its own absence"
# While the mechanism is OFF the REAL daemon stamps no heartbeat (HB_AUTO=0 is that daemon; HB_AUTO=1 re-stamps every tick, stand-down included, and hid this).
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
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
