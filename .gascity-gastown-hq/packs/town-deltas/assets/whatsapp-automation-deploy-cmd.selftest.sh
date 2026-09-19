#!/usr/bin/env bash
# Selftest for the whatsapp_automation rig's deploy_cmd (ga-nh1muq).
#
# Mirrors lexbh-deploy-cmd.selftest.sh's approach: extracts the EXACT
# deploy_cmd string configured in delivery-runbooks.toml (via the same
# regex get_runbook_field() in story-delivery.sh uses) and runs it — with
# /Users/athos/gt/whatsapp_automation substituted for a disposable temp
# clone — to prove the three properties the bead's acceptance criteria
# require, PLUS that the runbook actually points at a real, executable
# script (the specific defect this bead's fix touches: a hardcoded absolute
# path to a NEW script that must exist and be runnable, not just a string
# that looks plausible):
#   0. deploy_cmd resolves to an existing, executable script.
#   A. behind origin by N commits, clean tree -> fast-forwards, exit 0.
#   B. local commit diverges from origin       -> refuses, exit != 0, HEAD untouched.
#   C. unrelated untracked file present         -> survives a real fast-forward.
# The RACE this bead actually reports is exercised exhaustively in
# scripts/git-deploy-pull.selftest.sh (the script this deploy_cmd delegates
# to) — not repeated here, this file's job is to prove the RUNBOOK WIRING
# itself (the literal configured string) hasn't drifted from that script.
# Never touches the real whatsapp_automation checkout — everything runs
# against throwaway git repos under a mktemp -d directory.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOML="$DIR/delivery-runbooks.toml"

RAW_CMD=$(python3 - "$TOML" <<'PYEOF'
import re, sys
content = open(sys.argv[1]).read()
blocks = re.split(r'\[\[rig\]\]', content)
for block in blocks:
    m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if m and m.group(1) == "whatsapp_automation":
        fm = re.search(r'deploy_cmd\s*=\s*"([^"]*)"', block)
        print(fm.group(1) if fm else "")
        sys.exit(0)
sys.exit(1)
PYEOF
) || { echo "FAIL: could not find a [[rig]] block named \"whatsapp_automation\" in $TOML"; exit 1; }

if [ -z "$RAW_CMD" ]; then
  echo "FAIL: whatsapp_automation deploy_cmd is empty in $TOML — nothing to test"
  exit 1
fi
case "$RAW_CMD" in
  *"/Users/athos/gt/whatsapp_automation"*) : ;;
  *) echo "FAIL: deploy_cmd does not reference /Users/athos/gt/whatsapp_automation — selftest cannot retarget it to a temp clone: $RAW_CMD"; exit 1 ;;
esac

pass=0; fail=0
must() { "$@" || { echo "SETUP FAILED: $*" >&2; exit 1; }; }  # unrecoverable — abort, don't cascade
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# ── 0. deploy_cmd resolves to a real, executable script ───────────────────────
DEPLOY_SCRIPT=$(printf '%s\n' "$RAW_CMD" | grep -oE '/[^ ]*git-deploy-pull\.sh' | head -1)
if [ -z "$DEPLOY_SCRIPT" ]; then
  bad "deploy_cmd no longer invokes git-deploy-pull.sh (or the path is no longer extractable): $RAW_CMD"
elif [ -x "$DEPLOY_SCRIPT" ]; then
  ok
else
  bad "deploy_cmd points at $DEPLOY_SCRIPT, which does not exist or is not executable"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ORIGIN="$WORK/origin.git"
must git init --quiet --bare -b main "$ORIGIN"

OTHER="$WORK/other"
must git clone --quiet "$ORIGIN" "$OTHER"
must git -C "$OTHER" checkout --quiet -B main
must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "seed"
must git -C "$OTHER" push --quiet origin HEAD:main

seed_runtime() { # $1 = target dir
  must git clone --quiet "$ORIGIN" "$1"
  must git -C "$1" checkout --quiet -B main
}
advance_origin() {
  must git -C "$OTHER" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "upstream work $RANDOM"
  must git -C "$OTHER" push --quiet origin HEAD:main
}
run_deploy() { # $1 = runtime dir; substitutes it for the real WA path in the real command and evals
  local rt="$1"
  local cmd="${RAW_CMD//\/Users\/athos\/gt\/whatsapp_automation/$rt}"
  eval "$cmd" >"$WORK/last-deploy-output.txt" 2>&1
}

# ── A. behind by one commit, clean tree -> fast-forwards, exit 0 ──────────────
RT_A="$WORK/rt-behind"
seed_runtime "$RT_A"
advance_origin
BEFORE=$(git -C "$RT_A" rev-parse HEAD)
run_deploy "$RT_A"; RC=$?
AFTER=$(git -C "$RT_A" rev-parse HEAD)
ORIGIN_TIP=$(git -C "$OTHER" rev-parse HEAD)
if [ "$RC" -eq 0 ] && [ "$AFTER" = "$ORIGIN_TIP" ] && [ "$AFTER" != "$BEFORE" ]; then
  ok
else
  bad "behind-by-one: expected exit 0 and HEAD advanced to $ORIGIN_TIP; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last-deploy-output.txt")"
fi

# ── B. local commit diverges from origin -> refuses, HEAD untouched ───────────
RT_B="$WORK/rt-diverged"
seed_runtime "$RT_B"
must git -C "$RT_B" -c user.name=test -c user.email=test@test commit --quiet --allow-empty -m "local-only work"
advance_origin   # origin now has commits RT_B never saw -> true divergence
BEFORE=$(git -C "$RT_B" rev-parse HEAD)
run_deploy "$RT_B"; RC=$?
AFTER=$(git -C "$RT_B" rev-parse HEAD)
if [ "$RC" -ne 0 ] && [ "$AFTER" = "$BEFORE" ]; then
  ok
else
  bad "diverged: expected non-zero refusal with HEAD unchanged; got rc=$RC head=$AFTER (was $BEFORE). Output: $(cat "$WORK/last-deploy-output.txt")"
fi

# ── C. unrelated untracked file survives a REAL fast-forward ──────────────────
RT_C="$WORK/rt-untracked"
seed_runtime "$RT_C"
echo "scratch-$RANDOM" > "$RT_C/untracked-scratch.txt"
UNTRACKED_CONTENT="$(cat "$RT_C/untracked-scratch.txt")"
advance_origin   # ensure there is a real ff to perform, not a no-op
run_deploy "$RT_C"; RC=$?
if [ "$RC" -eq 0 ] && [ -f "$RT_C/untracked-scratch.txt" ] && [ "$(cat "$RT_C/untracked-scratch.txt")" = "$UNTRACKED_CONTENT" ]; then
  ok
else
  bad "untracked-file: expected exit 0 with untracked-scratch.txt preserved; got rc=$RC. Output: $(cat "$WORK/last-deploy-output.txt")"
fi

echo "whatsapp-automation-deploy-cmd selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
