#!/bin/bash
# claude-ctxcap-ab.selftest.sh — hermetic test for ga-55vrxw (E10 of P0 ga-ufskhy).
#
# Runs the REAL claude-ctxcap-ab.sh against a fake city under a temp dir, with a stub standing in for the
# next hop (claude-lowprio.sh -> claude), and checks the argv the stub receives. Nothing here starts claude.
#
# ISOLATION: every launch goes through `env -i`. A pool session running this test has its own GC_TEMPLATE /
# GC_SESSION_NAME / GC_CITY_PATH exported, and the wrapper reads exactly those — letting them leak would make
# a "no session name" case pass or fail on who happens to be running the test.
#
# WHAT THE CASES PROTECT. This wrapper sits on the launch path of EVERY pool session, and `claude` EXITS on an
# --autocompact value outside auto|100k-1M (measured, claude 2.1.286), so the dangerous failure is not "the
# arm did not apply" but "a typo in a conf file stopped every dog, wa-worker and gate-reviewer from starting".
# Hence: bad conf -> argv untouched (T6), conf text can never add a flag (T6 injection), the flag lands before
# any `--` (T9), and a missing next hop still launches claude (T13). The same launch path also carries the guard that
# refuses a remote-only role (dog-remote, gate-reviewer-remote, ...) on the mini unless someone overrides it on purpose
# (ga-pshalqe, T15-T21): it refuses out loud, and it must refuse NOTHING else, so T16 sweeps every template under agents/ both ways.
# It also hands the engine-synthesized <rig>/claude-headless agent its session name as the bd actor (ga-znmm7w1, T22-T30), and must
# touch NO other role: T25 sweeps every template under agents/ plus the near-miss names a substring match would swallow.
#
# MUTATION CONTROLS (bottom): the selftest is re-run against copies of the script with one guard removed each;
# every copy must make it FAIL. A test that stays green when the guard is gone proves nothing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CTXCAP_SCRIPT:-$HERE/claude-ctxcap-ab.sh}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

CITY="$WORKDIR/city"
mkdir -p "$CITY/.gc/logs"
CONF="$CITY/.gc/context-ab.conf"
LOG="$CITY/.gc/logs/claude-lowprio.log"
OUT="$WORKDIR/argv.out"
STUB="$WORKDIR/stub-next.sh"
ACTOR_OUT="$WORKDIR/actor.out"
cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${STUB_OUT:?}"
# What the next hop (and so claude, and so every `bd update --claim` it runs) would see as the bd actor: ga-znmm7w1.
printf '%s\n' "${BEADS_ACTOR-UNSET}" > "${STUB_ACTOR_OUT:-/dev/null}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"

UUID="11111111-2222-3333-4444-555555555555"
ARGS=(--model sonnet --strict-mcp-config --effort xhigh --session-id "$UUID")
joined() { local IFS='|'; echo "$*"; }
ARGS_J="$(joined "${ARGS[@]}")"

# run_wrapper [ENV=val ...] -- args...   (later ENV wins; GC_SESSION_NAME= empties it)
run_wrapper() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$OUT"; : > "$ACTOR_OUT"
  env -i PATH="$PATH" HOME="$WORKDIR" GC_CITY_PATH="$CITY" GC_CTXCAP_NEXT_BIN="$STUB" STUB_OUT="$OUT" STUB_ACTOR_OUT="$ACTOR_OUT" \
    GC_TEMPLATE=gastown.dog GC_AGENT=gastown.dog-1 GC_SESSION_NAME=dog-aaa111 \
    ${envs[@]+"${envs[@]}"} /bin/bash "$SCRIPT" "$@"   # /bin/bash = the script's shebang = bash 3.2 on macOS, not the PATH bash
}
reset() { rm -f "$CONF" "$CITY/.gc/no-ctx-ab" "$CITY/.gc/no-remote-local-guard" "$CITY/.gc/no-claim-as-session"; : > "$LOG"; }
conf()  { printf '%s\n' "$@" > "$CONF"; }
got_argv() { paste -sd'|' "$OUT"; }
expect_argv() { # name want
  local g; g="$(got_argv)"
  if [ "$g" = "$2" ]; then ok "$1"; else bad "$1 — got [$g] want [$2]"; fi
}
expect_log()   { if grep -q -- "$2" "$LOG"; then ok "$1"; else bad "$1 — no /$2/ in log: $(tr '\n' ';' < "$LOG")"; fi; }
expect_nolog() { if grep -q -- "$2" "$LOG"; then bad "$1 — unexpected /$2/ in log"; else ok "$1"; fi; }

GOOD=(salt=t1 "enroll=gastown.dog wa-worker" treat_window=200000)

echo "T1 inert without a conf"
reset
run_wrapper -- "${ARGS[@]}"
expect_argv "T1 argv untouched" "$ARGS_J"
expect_nolog "T1 no CTX-AB line" "CTX-AB"

echo "T2 treated arm (pct=100): flag prepended, uuid logged"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}"
expect_argv "T2 --autocompact 200000 + original argv" "--autocompact|200000|$ARGS_J"
expect_log "T2 arm=treat with uuid and window" "CTX-AB arm=treat .*uuid=$UUID.* window=200000"

echo "T3 control arm (pct=0): argv untouched, decision still logged"
reset; conf "${GOOD[@]}" treat_pct=0
run_wrapper -- "${ARGS[@]}"
expect_argv "T3 argv untouched" "$ARGS_J"
expect_log "T3 arm=control logged" "CTX-AB arm=control .*uuid=$UUID"

echo "T4 not enrolled"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_TEMPLATE=gate-reviewer GC_AGENT=gate-reviewer-7 -- "${ARGS[@]}"
expect_argv "T4 argv untouched" "$ARGS_J"
expect_nolog "T4 no arm line" "CTX-AB arm="

echo "T5 enrolled by GC_AGENT prefix when GC_TEMPLATE differs"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_TEMPLATE=other GC_AGENT=wa-worker-3 -- "${ARGS[@]}"
expect_argv "T5 treated via agent prefix" "--autocompact|200000|$ARGS_J"

echo "T6 bad conf never reaches claude (claude exits on an invalid --autocompact)"
n=0
# The 20-digit values are the third-state cases: `[ N -lt 100000 ]` cannot compare a number that overflows
# (it returns 2, an ERROR), and "could not compare" must never read as "in range".
for bad_line in "treat_window=50000" "treat_window=2000000" "treat_window=abc" "treat_window=200k" "treat_window=" \
                "treat_window=99999999999999999999" "treat_window=0200000" "treat_window=00000000000200000" \
                "treat_window=200000 --permission-mode bypassPermissions" "treat_window=200000;touch /tmp/x" \
                "treat_pct=101" "treat_pct=abc" "treat_pct=-1" "treat_pct=99999999999999999999" "treat_pct=1000" "bogus_key=1"; do
  n=$((n+1)); reset
  conf salt=t1 "enroll=gastown.dog" treat_window=200000 treat_pct=100
  case "$bad_line" in
    treat_window=*) conf salt=t1 "enroll=gastown.dog" "$bad_line" treat_pct=100 ;;
    treat_pct=*)    conf salt=t1 "enroll=gastown.dog" treat_window=200000 "$bad_line" ;;
    *)              conf salt=t1 "enroll=gastown.dog" treat_window=200000 treat_pct=100 "$bad_line" ;;
  esac
  run_wrapper -- "${ARGS[@]}"
  expect_argv "T6.$n [$bad_line] argv untouched" "$ARGS_J"
  expect_log  "T6.$n [$bad_line] WARN logged" "CTX-AB WARN"
done
reset; conf "enroll=gastown.dog" treat_window=200000 treat_pct=100          # salt missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.salt missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 treat_window=200000 treat_pct=100                       # enroll missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.enroll missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=200000                # pct missing
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.pct missing -> argv untouched" "$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=100000 treat_pct=100  # exact floor is valid
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.floor 100000 accepted" "--autocompact|100000|$ARGS_J"
reset; conf salt=t1 "enroll=gastown.dog" treat_window=1000000 treat_pct=100 # exact ceiling is valid
run_wrapper -- "${ARGS[@]}"
expect_argv "T6.ceiling 1000000 accepted" "--autocompact|1000000|$ARGS_J"

echo "T7 kill switches"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_CTX_AB=0 -- "${ARGS[@]}"
expect_argv "T7 GC_CTX_AB=0 argv untouched" "$ARGS_J"
reset; conf "${GOOD[@]}" treat_pct=100; : > "$CITY/.gc/no-ctx-ab"
run_wrapper -- "${ARGS[@]}"
expect_argv "T7 .gc/no-ctx-ab argv untouched" "$ARGS_J"
expect_nolog "T7 kill switch is silent (no arm line)" "CTX-AB arm="

echo "T8 argv that already carries --autocompact is left alone"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}" --autocompact 150k
expect_argv "T8 separate-value form" "$ARGS_J|--autocompact|150k"
run_wrapper -- "${ARGS[@]}" --autocompact=150k
expect_argv "T8 =value form" "$ARGS_J|--autocompact=150k"
expect_log "T8 SKIP logged" "CTX-AB SKIP"

echo "T9 flag lands before a -- separator and a trailing prompt"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- --model sonnet -- "do the thing"
expect_argv "T9 prepended" "--autocompact|200000|--model|sonnet|--|do the thing"

echo "T10 no session name -> left alone"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_SESSION_NAME= -- "${ARGS[@]}"
expect_argv "T10 argv untouched" "$ARGS_J"
expect_log "T10 WARN logged" "CTX-AB WARN"

# T11 launches the wrapper 180 times (a few minutes when the box is loaded) and no mutation below needs it,
# so the mutation re-runs skip it.
if [ -z "${CTXCAP_NO_MUTATE:-}" ]; then
echo "T11 the split is deterministic, honours pct, and the salt matters"
reset; conf "${GOOD[@]}" treat_pct=50
treat=0; vec_a=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then treat=$((treat+1)); vec_a="${vec_a}1"; else vec_a="${vec_a}0"; fi
done
if [ "$treat" -ge 17 ] && [ "$treat" -le 43 ]; then ok "T11 pct=50 over 60 sessions -> $treat treated"; else bad "T11 pct=50 over 60 sessions -> $treat treated (want 17..43)"; fi
vec_b=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then vec_b="${vec_b}1"; else vec_b="${vec_b}0"; fi
done
if [ "$vec_a" = "$vec_b" ]; then ok "T11 same session name -> same arm on a second launch"; else bad "T11 arms changed between two identical passes"; fi
conf salt=t2 "enroll=gastown.dog" treat_window=200000 treat_pct=50
vec_c=""
for i in $(seq 1 60); do
  run_wrapper GC_SESSION_NAME="dog-s$i" -- "${ARGS[@]}"
  if [ "$(head -1 "$OUT")" = "--autocompact" ]; then vec_c="${vec_c}1"; else vec_c="${vec_c}0"; fi
done
if [ "$vec_a" != "$vec_c" ]; then ok "T11 a new salt reshuffles the split"; else bad "T11 salt t1 and t2 gave the identical split"; fi
fi

echo "T12 exit status of the next hop is the wrapper's exit status (exec, not a child)"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper STUB_RC=7 -- "${ARGS[@]}"; rc=$?
if [ "$rc" -eq 7 ]; then ok "T12 rc=7 propagated"; else bad "T12 rc=$rc, want 7"; fi

echo "T13 next hop missing -> claude is still launched (fail-open), arm still applied"
reset; conf "${GOOD[@]}" treat_pct=100
run_wrapper GC_CTXCAP_NEXT_BIN="$WORKDIR/does-not-exist" GC_LOWPRIO_CLAUDE_BIN="$STUB" -- "${ARGS[@]}"
expect_argv "T13 fell back to the real claude with the arm applied" "--autocompact|200000|$ARGS_J"
expect_log "T13 WARN logged" "CTX-AB WARN"

echo "T14 no log directory -> still launches"
rm -rf "$CITY/.gc/logs"; conf "${GOOD[@]}" treat_pct=100
run_wrapper -- "${ARGS[@]}"
expect_argv "T14 treated without a log dir" "--autocompact|200000|$ARGS_J"
mkdir -p "$CITY/.gc/logs"

# ---- ga-pshalqe: a remote-only role is refused on the mini, out loud ----------------------------------------------
# WHAT BROKE (27/10 13:18Z). dog-remote-1 (session ga-wisp-8u7ite) ran as a claude on the MINI. The hybrid session provider
# sends a session to the server only when its NAME contains remote_match ("-remote-"); this session's name was the engine's
# legacy s-<bead> default, so the mini's own tmux started it. Every local claude-headless session passes through this
# launcher, and the server never runs it (gc-session-ssh swaps it for plain `claude` there), so a remote-only role that
# reaches it is on the wrong machine by definition. T15-T21 run the REAL launcher with that identity.
ERR="$WORKDIR/stderr.out"
REMOTE_ID=(GC_TEMPLATE=dog-remote GC_AGENT=dog-remote-1 GC_ALIAS=dog-remote-1 GC_SESSION_NAME=s-ga-wisp-8u7ite GC_SESSION_ID=ga-wisp-8u7ite)
expect_refused() { # name rc — nothing was launched: a non-zero exit and the next hop never ran
  if [ "$2" -ne 0 ] && [ ! -s "$OUT" ]; then ok "$1"; else bad "$1 — rc=$2 argv=[$(got_argv)] (want a non-zero exit and no launch)"; fi
}
expect_launched() { # name rc — the next hop ran with the argv untouched and its exit status came back
  if [ "$2" -eq 0 ] && [ "$(got_argv)" = "$ARGS_J" ]; then ok "$1"; else bad "$1 — rc=$2 argv=[$(got_argv)] (want rc 0 and the original argv)"; fi
}
expect_refusal_line() { # name token — the REFUSED line carries what an operator needs to find and close the session
  if grep -- 'REMOTE-ONLY REFUSED' "$LOG" | grep -q -- "$2"; then ok "$1"; else bad "$1 — no REFUSED line with /$2/: $(tr '\n' ';' < "$LOG")"; fi
}

echo "T15 the incident: dog-remote with a legacy s-<bead> name reaches the mini's launcher"
reset
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} -- "${ARGS[@]}" 2> "$ERR"; rc=$?
expect_refused "T15 refused, claude never started" "$rc"
expect_refusal_line "T15 the log line names the template" "template=dog-remote"
expect_refusal_line "T15 the log line names the session" "session=s-ga-wisp-8u7ite"
expect_refusal_line "T15 the log line carries the id to close" "id=ga-wisp-8u7ite"
if [ -s "$ERR" ]; then ok "T15 the refusal is visible on stderr (the session pane)"; else bad "T15 nothing on stderr: a refusal nobody can see is a silent failure"; fi

echo "T16 class sweep over the city's real templates (agents/): every remote-only role is refused, every other role launches"
AGENTS_DIR="$HERE/../../../../agents"
if [ ! -d "$AGENTS_DIR" ]; then
  bad "T16 agents dir not found ($AGENTS_DIR): the sweep cannot say which templates are remote-only"
else
  n_remote=0; n_local=0
  for dir in "$AGENTS_DIR"/*/; do
    t="${dir%/}"; t="${t##*/}"
    reset
    run_wrapper GC_TEMPLATE="$t" GC_AGENT="$t-1" GC_ALIAS="$t-1" GC_SESSION_NAME="s-ga-wisp-t16$n_remote$n_local" -- "${ARGS[@]}" 2>/dev/null; rc=$?
    case "$t" in
      *remote*) n_remote=$((n_remote+1)); expect_refused "T16 remote-only template $t" "$rc" ;;
      *)        n_local=$((n_local+1));   expect_launched "T16 local template $t" "$rc" ;;
    esac
  done
  if [ "$n_remote" -ge 1 ] && [ "$n_local" -ge 1 ]; then ok "T16 swept $n_remote remote-only and $n_local local templates"; else bad "T16 empty sweep (remote=$n_remote local=$n_local): the agents/ listing came back empty"; fi
fi
# Roles that come from packs or the engine, not from agents/ (the named crews are in agents/, so the sweep above has them):
# all local, all must still launch.
for t in gastown.dog gastown.mayor gastown.witness lexbh/gastown.witness control-dispatcher; do
  reset
  run_wrapper GC_TEMPLATE="$t" GC_AGENT="$t" GC_ALIAS= GC_SESSION_NAME=gastown__t16 -- "${ARGS[@]}" 2>/dev/null; rc=$?
  expect_launched "T16 pack role $t" "$rc"
done

echo "T17 identity: one of GC_TEMPLATE / GC_AGENT / GC_ALIAS naming a remote-only role is enough; no identity at all is not"
reset; run_wrapper GC_TEMPLATE= GC_AGENT= GC_ALIAS=dog-remote-2 GC_SESSION_NAME=s-ga-wisp-t17a -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T17 the alias alone" "$rc"
reset; run_wrapper GC_TEMPLATE= GC_AGENT=wa-worker-remote-3 GC_ALIAS= GC_SESSION_NAME=s-ga-wisp-t17b -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T17 the agent alone" "$rc"
reset; run_wrapper GC_TEMPLATE=gate-reviewer-remote GC_AGENT= GC_ALIAS= GC_SESSION_NAME=s-ga-wisp-t17c -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T17 the template alone" "$rc"
reset; run_wrapper GC_TEMPLATE= GC_AGENT= GC_ALIAS= GC_SESSION_NAME= -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_launched "T17 no identity at all is not a remote-only role: launches (fail-open)" "$rc"
expect_nolog "T17 and says nothing" "REMOTE-ONLY"

echo "T18 kill switches: a deliberate override launches, and says so in the log"
reset; run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_REMOTE_LOCAL_GUARD=0 -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_launched "T18 GC_REMOTE_LOCAL_GUARD=0 launches" "$rc"
expect_log "T18 the override leaves a line" "REMOTE-ONLY OVERRIDE"
reset; : > "$CITY/.gc/no-remote-local-guard"
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_launched "T18 .gc/no-remote-local-guard launches" "$rc"
expect_log "T18 the file override leaves a line" "REMOTE-ONLY OVERRIDE"
reset
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_REMOTE_LOCAL_GUARD=1 -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T18 any value but 0 keeps the guard on" "$rc"
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_REMOTE_LOCAL_GUARD= -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T18 an empty value keeps the guard on" "$rc"
reset; run_wrapper GC_TEMPLATE=gastown.dog GC_REMOTE_LOCAL_GUARD=0 -- "${ARGS[@]}" 2>/dev/null
expect_nolog "T18 a local role with the switch on says nothing" "REMOTE-ONLY"

echo "T19 a log that cannot be written never turns a refusal into a launch"
rm -rf "$CITY/.gc/logs"
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} -- "${ARGS[@]}" 2> "$ERR"; rc=$?
expect_refused "T19 no log directory" "$rc"
if [ -s "$ERR" ]; then ok "T19 stderr still carries the refusal"; else bad "T19 no log directory and nothing on stderr: the refusal is invisible"; fi
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_CITY_PATH= -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T19 no city path" "$rc"
mkdir -p "$CITY/.gc/logs"

echo "T20 the refusal comes before the context A/B and before the fail-open next-hop fallback"
reset; conf salt=t1 "enroll=dog-remote" treat_window=200000 treat_pct=100
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T20 an enrolled remote-only role is refused, not armed" "$rc"
expect_nolog "T20 no arm line" "CTX-AB arm="
reset
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_CTXCAP_NEXT_BIN="$WORKDIR/does-not-exist" GC_LOWPRIO_CLAUDE_BIN="$STUB" -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T20 a missing next hop does not fall through to launching claude directly" "$rc"

echo "T21 a readable remote name on the mini is just as wrong (hybrid off or misrouted): refused too"
reset
run_wrapper ${REMOTE_ID[@]+"${REMOTE_ID[@]}"} GC_SESSION_NAME=dog-remote-gawisp302f1x -- "${ARGS[@]}" 2>/dev/null; rc=$?
expect_refused "T21 dog-remote-<tail> on the mini" "$rc"

# ---- ga-znmm7w1: the engine-synthesized <rig>/claude-headless agent claims AS ITS SESSION --------------------------
# WHAT BROKE (19/11, wa-fj2lqh): 5 claude-headless sessions in ~35 min, 0 commits, each one ended by "drain acknowledged" a few
# minutes after it claimed. The engine stamps BEADS_ACTOR with the POOL ALIAS of a slot (whatsapp_automation/claude-headless-1), so the
# `bd update <id> --claim` of the builtin worker prompt recorded the alias, while the prompt's very next step ("the assignee must be
# $GC_SESSION_NAME") and the controller's assigned-work match both read the SESSION NAME (claude-headless-ga7bku77s): the claim never
# "landed on you". T22-T30 run the REAL launcher with that identity and read the BEADS_ACTOR the next hop receives.
IMPL_TPL=whatsapp_automation/claude-headless
IMPL_SESS=claude-headless-ga7bku77s
IMPL_ID=(GC_TEMPLATE="$IMPL_TPL" GC_AGENT="$IMPL_TPL-1" GC_ALIAS="$IMPL_TPL-1" GC_SESSION_NAME="$IMPL_SESS" GC_SESSION_ID=ga-7bku77s BEADS_ACTOR="$IMPL_TPL-1")
# vazio → "" (the next hop never ran: every comparison below fails, none passes by accident); falhou/ilegível → the same ""
got_actor() { cat "$ACTOR_OUT" 2>/dev/null; }
expect_actor() { # name want
  local g; g="$(got_actor)"
  if [ "$g" = "$2" ]; then ok "$1"; else bad "$1 — the next hop saw BEADS_ACTOR=[$g], want [$2]"; fi
}

echo "T22 the incident: a pool slot's BEADS_ACTOR is its alias; the launch hands claude the SESSION name instead"
reset
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} -- "${ARGS[@]}"; rc=$?
expect_actor "T22 BEADS_ACTOR is the session name" "$IMPL_SESS"
expect_argv "T22 argv untouched (only the environment moves)" "$ARGS_J"
expect_log "T22 the log line says what moved" "CLAIM-AS-SESSION template=$IMPL_TPL session=$IMPL_SESS was=$IMPL_TPL-1"
if [ "$rc" -eq 0 ]; then ok "T22 launched"; else bad "T22 rc=$rc, want 0"; fi

echo "T23 the city-scope implicit agent, and a launch where BEADS_ACTOR was never set"
reset
run_wrapper GC_TEMPLATE=claude-headless GC_AGENT=claude-headless-1 GC_ALIAS=claude-headless-1 GC_SESSION_NAME=claude-headless-abc123 BEADS_ACTOR=claude-headless-1 -- "${ARGS[@]}"
expect_actor "T23 city scope (a template with no rig in front)" "claude-headless-abc123"
reset
run_wrapper GC_TEMPLATE="$IMPL_TPL" GC_SESSION_NAME=claude-headless-def456 -- "${ARGS[@]}"
expect_actor "T23 BEADS_ACTOR unset: bd would fall back to git user.name / \$USER, so the session name is set too" "claude-headless-def456"
expect_log "T23 the log says was=<unset>" "CLAIM-AS-SESSION .*was=<unset>"

echo "T24 BEADS_ACTOR is already the session name (alias deferred): nothing moves, nothing is logged"
reset
run_wrapper GC_TEMPLATE="$IMPL_TPL" GC_SESSION_NAME="$IMPL_SESS" BEADS_ACTOR="$IMPL_SESS" -- "${ARGS[@]}"
expect_actor "T24 unchanged" "$IMPL_SESS"
expect_nolog "T24 silent" "CLAIM-AS-SESSION"

echo "T25 class sweep: ONLY the implicit claude-headless agent moves; every explicit role and every near-miss name keeps what the engine stamped"
n_kept=0
if [ -d "$AGENTS_DIR" ]; then
  for dir in "$AGENTS_DIR"/*/; do
    t="${dir%/}"; t="${t##*/}"
    case "$t" in *remote*) continue ;; esac   # a remote-only role is refused before it gets here (T15-T21)
    reset
    run_wrapper GC_TEMPLATE="$t" GC_AGENT="$t-1" GC_ALIAS="$t-1" GC_SESSION_NAME="s-ga-wisp-t25a$n_kept" BEADS_ACTOR="$t-1" -- "${ARGS[@]}" 2>/dev/null
    expect_actor "T25 explicit template $t keeps BEADS_ACTOR=$t-1" "$t-1"
    n_kept=$((n_kept+1))
  done
fi
for t in gastown.dog gastown.mayor gastown.witness lexbh/gastown.witness control-dispatcher whatsapp_automation/wa-worker \
         claude-headless-extra foo-claude-headless claude-headless2 "$IMPL_TPL-extra" whatsapp_automation/my-claude-headless claude-headless/x; do
  reset
  run_wrapper GC_TEMPLATE="$t" GC_AGENT="$t-1" GC_ALIAS="$t-1" GC_SESSION_NAME="s-ga-wisp-t25b$n_kept" BEADS_ACTOR="$t-1" -- "${ARGS[@]}" 2>/dev/null
  expect_actor "T25 template $t keeps BEADS_ACTOR=$t-1" "$t-1"
  n_kept=$((n_kept+1))
done
if [ "$n_kept" -ge 12 ]; then ok "T25 swept $n_kept templates"; else bad "T25 empty sweep ($n_kept): the agents/ listing came back empty"; fi

echo "T26 a session name that is empty or not a plain token never reaches the environment (fail-open: the engine's value stays)"
reset
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_SESSION_NAME= -- "${ARGS[@]}"; rc=$?
expect_actor "T26 no session name -> the alias stays" "$IMPL_TPL-1"
expect_log "T26 WARN logged" "CLAIM-AS-SESSION WARN"
if [ "$rc" -eq 0 ]; then ok "T26 and the session still launches"; else bad "T26 rc=$rc: a doubtful name must never stop a launch"; fi
n=0
for evil in "a b" "a;touch /tmp/x" 'a$(id)' "-rf" "a/b" "$(printf 'a\nb')" "$(printf 'x%.0s' $(seq 1 201))"; do
  n=$((n+1)); reset
  run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_SESSION_NAME="$evil" -- "${ARGS[@]}"
  expect_actor "T26.$n [${evil:0:12}] the alias stays" "$IMPL_TPL-1"
  expect_log "T26.$n WARN logged" "CLAIM-AS-SESSION WARN"
done
reset
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_SESSION_NAME="$(printf 'x%.0s' $(seq 1 200))" -- "${ARGS[@]}"
expect_actor "T26 the 200-character bound itself is accepted" "$(printf 'x%.0s' $(seq 1 200))"

echo "T27 kill switches: a deliberate override leaves the engine's identity alone, and says so"
reset; run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_CLAIM_AS_SESSION=0 -- "${ARGS[@]}"
expect_actor "T27 GC_CLAIM_AS_SESSION=0 keeps the alias" "$IMPL_TPL-1"
expect_log "T27 the override leaves a line" "CLAIM-AS-SESSION OVERRIDE"
reset; : > "$CITY/.gc/no-claim-as-session"
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} -- "${ARGS[@]}"
expect_actor "T27 .gc/no-claim-as-session keeps the alias" "$IMPL_TPL-1"
expect_log "T27 the file override leaves a line" "CLAIM-AS-SESSION OVERRIDE"
reset
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_CLAIM_AS_SESSION=1 -- "${ARGS[@]}"
expect_actor "T27 any value but 0 keeps the fix on" "$IMPL_SESS"
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_CLAIM_AS_SESSION= -- "${ARGS[@]}"
expect_actor "T27 an empty value keeps the fix on" "$IMPL_SESS"
reset; run_wrapper GC_TEMPLATE=gastown.dog BEADS_ACTOR=gastown.dog-1 GC_CLAIM_AS_SESSION=0 -- "${ARGS[@]}"
expect_nolog "T27 an explicit role with the switch on says nothing" "CLAIM-AS-SESSION"

echo "T28 a log that cannot be written, or no city path at all, never undoes the fix"
rm -rf "$CITY/.gc/logs"
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} -- "${ARGS[@]}"
expect_actor "T28 no log directory" "$IMPL_SESS"
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_CITY_PATH= -- "${ARGS[@]}"
expect_actor "T28 no city path (the kill-switch file cannot be tested, it reads as absent: the fix stays on)" "$IMPL_SESS"
mkdir -p "$CITY/.gc/logs"

echo "T29 the context A/B and the claim identity are independent: one launch gets both"
# The A/B conf only takes [A-Za-z0-9._ -] (a "/" would make it ignore the whole file), so a rig-scoped template cannot be enrolled by
# name: this case uses the city-scope implicit agent, which can.
reset; conf salt=t1 "enroll=claude-headless" treat_window=200000 treat_pct=100
run_wrapper GC_TEMPLATE=claude-headless GC_AGENT=claude-headless-1 GC_ALIAS=claude-headless-1 GC_SESSION_NAME=claude-headless-abc123 BEADS_ACTOR=claude-headless-1 -- "${ARGS[@]}"
expect_argv "T29 the arm landed" "--autocompact|200000|$ARGS_J"
expect_actor "T29 and so did the claim identity" "claude-headless-abc123"

echo "T30 the fail-open launch of claude itself (next hop missing) carries the same environment"
reset
run_wrapper ${IMPL_ID[@]+"${IMPL_ID[@]}"} GC_CTXCAP_NEXT_BIN="$WORKDIR/does-not-exist" GC_LOWPRIO_CLAUDE_BIN="$STUB" -- "${ARGS[@]}"
expect_actor "T30 the direct claude exec sees the session name" "$IMPL_SESS"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"

# ---- MUTATION CONTROLS ---------------------------------------------------------------------------------------
# Each mutation removes ONE guard from a copy of the script; the selftest re-run against that copy must FAIL.
# A sed that changes nothing is itself a failure (the pattern went stale), never a silent pass.
if [ "$FAIL" -eq 0 ] && [ -z "${CTXCAP_NO_MUTATE:-}" ]; then
  echo
  echo "MUTATION CONTROLS"
  MFAIL=0
  mutate() { # name sed-expr
    local name="$1" expr="$2" copy="$WORKDIR/mut-$1.sh"
    sed -e "$expr" "$SCRIPT" > "$copy"
    if cmp -s "$SCRIPT" "$copy"; then
      echo "  FAIL: mutation $name did not change the script (stale pattern)"; MFAIL=$((MFAIL+1)); return
    fi
    if CTXCAP_SCRIPT="$copy" CTXCAP_NO_MUTATE=1 bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
      echo "  FAIL: mutation $name was NOT caught — the selftest passes without that guard"; MFAIL=$((MFAIL+1))
    else
      echo "  PASS: mutation $name caught"
    fi
  }
  mutate window-floor     's/-lt 100000/-lt 1/'
  mutate window-ceiling   's/-gt 1000000/-gt 99999999999/'
  mutate window-digits    's/ab_win" in \(.*\)\*\[!0-9\]\*)/ab_win" in \1NEVER)/'
  mutate pct-ceiling      's/"\$ab_pct" -gt 100/"$ab_pct" -gt 9999/'
  mutate window-overflow  's/"\${#ab_win}" -gt 7/"${#ab_win}" -gt 70/'
  mutate pct-overflow     's/"\${#ab_pct}" -gt 3/"${#ab_pct}" -gt 30/'
  mutate window-leading-0 's/\x27\x27|0\*|\*\[!0-9\]\*)/\x27\x27|*[!0-9]*)/'
  mutate arm-inverted     's/"\$ab_n" -lt "\$ab_pct"/"$ab_n" -ge "$ab_pct"/'
  mutate append-not-prepend 's/argv=(--autocompact "\$ab_win" \${argv\[@\]+"\${argv\[@\]}"})/argv=(${argv[@]+"${argv[@]}"} --autocompact "$ab_win")/'
  mutate already-set      's/--autocompact|--autocompact=\*)/--autocompact-never)/'
  mutate no-session-name  's/\[ -z "\$ab_sn" \]/[ -z "never" ]/'
  mutate kill-env         's/"\${GC_CTX_AB:-}" != "0"/"${GC_CTX_AB:-}" != "never"/'
  mutate kill-file        's/! -e "\$city\/.gc\/no-ctx-ab"/! -e "$city\/.gc\/never"/'
  mutate fail-open-next   's/\[ -x "\$next" \]/[ -n "$next" ]/'
  # ga-pshalqe: the remote-only guard (T15-T21)
  mutate remote-pattern-none      's/\*-remote|\*-remote-\*) rl_hit=1/*-never-matches) rl_hit=1/'
  mutate remote-pattern-no-infix  's/\*-remote|\*-remote-\*) rl_hit=1/*-remote) rl_hit=1/'
  mutate remote-pattern-no-suffix 's/\*-remote|\*-remote-\*) rl_hit=1/*-remote-*) rl_hit=1/'
  mutate remote-template-only     's/for rl_v in "\${GC_TEMPLATE:-}" "\${GC_AGENT:-}" "\${GC_ALIAS:-}"; do/for rl_v in "${GC_TEMPLATE:-}"; do/'
  mutate remote-session-name-only 's/for rl_v in "\${GC_TEMPLATE:-}" "\${GC_AGENT:-}" "\${GC_ALIAS:-}"; do/for rl_v in "${GC_SESSION_NAME:-}"; do/'
  mutate remote-empty-is-hit      's/\*-remote|\*-remote-\*) rl_hit=1/*-remote|*-remote-*|"") rl_hit=1/'
  mutate remote-exit-zero         's/exit 78/exit 0/'
  mutate remote-falls-through     's/exit 78/:/'
  mutate remote-no-log            's/note "REMOTE-ONLY REFUSED \$rl_id"/:/'
  mutate remote-silent            's/"\${GC_SESSION_ID:-\${GC_ALIAS:-?}}" >&2/"${GC_SESSION_ID:-${GC_ALIAS:-?}}" >\/dev\/null/'
  mutate remote-kill-env-any      's/"\${GC_REMOTE_LOCAL_GUARD:-}" = "0"/"${GC_REMOTE_LOCAL_GUARD:-}" != ""/'
  mutate remote-kill-file         's/-e "\$city\/.gc\/no-remote-local-guard"/-e "$city\/.gc\/never"/'
  mutate remote-override-unlogged 's/note "REMOTE-ONLY OVERRIDE \$rl_id - starting on the mini on purpose"/:/'
  # ga-znmm7w1: the claim identity (T22-T30)
  mutate claim-pattern-none       's/  claude-headless|\*\/claude-headless)/  never-matches)/'
  mutate claim-pattern-no-city    's/  claude-headless|\*\/claude-headless)/  *\/claude-headless)/'
  mutate claim-pattern-no-rig     's/  claude-headless|\*\/claude-headless)/  claude-headless)/'
  mutate claim-pattern-substring  's/  claude-headless|\*\/claude-headless)/  *claude-headless*)/'
  mutate claim-pattern-all        's/  claude-headless|\*\/claude-headless)/  *)/'
  mutate claim-no-export          's/export BEADS_ACTOR="\$cs_sn"/BEADS_ACTOR="$cs_sn"/'
  mutate claim-wrong-name         's/export BEADS_ACTOR="\$cs_sn"/export BEADS_ACTOR="${GC_ALIAS:-x}"/'
  mutate claim-wrong-source       's/cs_sn="\${GC_SESSION_NAME:-}"/cs_sn="${GC_AGENT:-}"/'
  mutate claim-empty-name-ok      's/elif \[ -z "\$cs_sn" \]; then/elif [ -z "never" ]; then/'
  mutate claim-length-unbounded   's/"\${#cs_sn}" -gt 200/"${#cs_sn}" -gt 20000/'
  mutate claim-charset-off        's#\[ -n "\${cs_sn//\[A-Za-z0-9._:@-\]/}" \]#[ -n "" ]#'
  mutate claim-leading-dash-ok    's|\[ "\${cs_sn#-}" != "\$cs_sn" \]|[ -n "" ]|'
  mutate claim-noisy-unchanged    's/elif \[ "\${BEADS_ACTOR-}" != "\$cs_sn" \]; then/elif true; then/'
  mutate claim-kill-env-any       's/"\${GC_CLAIM_AS_SESSION:-}" = "0"/"${GC_CLAIM_AS_SESSION:-}" != ""/'
  mutate claim-kill-env-ignored   's/"\${GC_CLAIM_AS_SESSION:-}" = "0"/"never" = "0"/'
  mutate claim-kill-file          's/-e "\$city\/.gc\/no-claim-as-session"/-e "$city\/.gc\/never"/'
  mutate claim-override-unlogged  's/note "CLAIM-AS-SESSION OVERRIDE /: "CLAIM-AS-SESSION OVERRIDE /'
  mutate claim-change-unlogged    's/note "CLAIM-AS-SESSION template=/: "CLAIM-AS-SESSION template=/'
  mutate claim-warn-empty-silent  's/note "CLAIM-AS-SESSION WARN template=\$cs_tpl has no/: "CLAIM-AS-SESSION WARN template=$cs_tpl has no/'
  mutate claim-warn-token-silent  's/note "CLAIM-AS-SESSION WARN template=\$cs_tpl session name is not/: "CLAIM-AS-SESSION WARN template=$cs_tpl session name is not/'
  if [ "$MFAIL" -ne 0 ]; then FAIL=$((FAIL+MFAIL)); fi
fi

[ "$FAIL" -eq 0 ]
