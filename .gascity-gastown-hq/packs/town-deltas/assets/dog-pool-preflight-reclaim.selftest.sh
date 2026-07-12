#!/usr/bin/env bash
# dog-pool-preflight-reclaim.selftest.sh — gt-fppb0 end-to-end hermetic test.
#
# Drives the REAL preflight (scripts/dog-pool-preflight-reclaim.py) with
# PATH-stubbed bd/gc/git/notify + a stub quota-check, proving the full chain
#   preflight -> reclaim_liveness shim -> guard driver -> do_reclaim
# reclaims a PROVABLY-DEAD dog claim (bd assign ""/update --status open) in ONE
# preflight, and leaves a LIVE sling-protected claim untouched. No live
# bd/gc/Dolt/git is ever touched. Falsifiable: against the pre-fix guard (no
# provably-dead fast-path) the DEAD case logs NO mutation and the first check
# fails.
#
# Run:  bash packs/town-deltas/assets/dog-pool-preflight-reclaim.selftest.sh
set -u

CITY="/Users/athos/gt/.gascity-gastown-hq"
PREFLIGHT="$CITY/scripts/dog-pool-preflight-reclaim.py"
PASS=0; FAIL=0
ck() { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (want=$2 got=$3)"; FAIL=$((FAIL+1)); fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dogpf.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BINS="$WORK/bin"; MUT="$WORK/mutations.log"; mkdir -p "$BINS"; : >"$MUT"
export DOG_PREFLIGHT_MUT="$MUT"

# fresh timestamp (now-60s) so a stubbed live session reads healthy
FRESH="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=60)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
export DOG_FRESH="$FRESH"

# --- stub: bd (emits scenario JSON; logs every mutation to $DOG_PREFLIGHT_MUT) ---
cat >"$BINS/bd" <<'EOF'
#!/usr/bin/env bash
sub="$1"; joined="$*"
case "$sub" in
  list)
    if printf '%s' "$joined" | grep -qF -- '--assignee gastown.dog'; then
      case "${DOG_SCENARIO:-}" in
        dead|live) echo '[{"id":"ga-zomb1","title":"chronic Dolt handle","assignee":"gastown.dog","labels":["story:in-flight"],"updated_at":""}]' ;;
        *)         echo '[]' ;;
      esac
      exit 0
    fi
    if printf '%s' "$joined" | grep -qF 'type:quality-gate-marker'; then echo '[]'; exit 0; fi
    if printf '%s' "$joined" | grep -qF 'in_progress'; then
      if [ "${DOG_SCENARIO:-}" = "live" ]; then
        echo '[{"id":"ga-sling1","title":"fix bug ga-zomb1: chronic","assignee":"dog-ga5e06","updated_at":""}]'
      else
        echo '[]'
      fi
      exit 0
    fi
    echo '[]'; exit 0 ;;
  show)    echo '[]'; exit 0 ;;
  label|assign|update|comment) echo "MUT $*" >>"${DOG_PREFLIGHT_MUT}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

# --- stub: gc (session/agent/rig list) ---
cat >"$BINS/gc" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "session list")
    if [ "${DOG_SCENARIO:-}" = "live" ]; then
      echo "{\"sessions\":[{\"id\":\"d9\",\"name\":\"gastown.dog-2\",\"session_name\":\"dog-ga5e06\",\"alias\":\"gastown.dog-2\",\"agent_name\":\"dog-ga5e06\",\"template\":\"\",\"state\":\"active\",\"last_active\":\"${DOG_FRESH}\"}]}"
    else
      echo "{\"sessions\":[{\"id\":\"ga-nav3\",\"name\":\"oracle-wa\",\"session_name\":\"oracle-wa-x\",\"alias\":\"oracle-wa\",\"agent_name\":\"oracle-wa\",\"template\":\"oracle-wa\",\"state\":\"active\",\"last_active\":\"${DOG_FRESH}\"}]}"
    fi ;;
  "agent list") echo '{"agents":[]}' ;;
  "rig list")   echo '{"rigs":[]}' ;;
  *) : ;;
esac
exit 0
EOF

# --- stub: git (no fetch expected in preflight; for-each-ref returns nothing) ---
cat >"$BINS/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# --- stub: notify + quota-check (exit 0 = not rate-limited) ---
printf '#!/usr/bin/env bash\nexit 0\n' >"$BINS/notify"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BINS/quota-stub"
chmod +x "$BINS"/*

run_preflight() {
  DOG_SCENARIO="$1" PATH="$BINS:$PATH" IRG_QUOTA_CHECK="$BINS/quota-stub" \
    DOG_PREFLIGHT_BUDGET_SEC=30 python3 "$PREFLIGHT" >/dev/null 2>&1
}

# DEAD: provably-dead claim → reclaim (assign "" + status open logged)
: >"$MUT"; run_preflight dead
if grep -q '^MUT assign ga-zomb1' "$MUT" && grep -q '^MUT update ga-zomb1 --status open' "$MUT"; then dead_ok=1; else dead_ok=0; fi
ck "DEAD dog claim reclaimed in ONE preflight (bd assign '' + update --status open)" 1 "$dead_ok"

# LIVE: sling-protected (ga-qfo3) → NO mutation
: >"$MUT"; run_preflight live
if [ -s "$MUT" ]; then live_noop=0; else live_noop=1; fi
ck "LIVE sling-protected claim → noop (no bd mutation)" 1 "$live_noop"

# NONE: no candidate dog beads → NO mutation (fast healthy path)
: >"$MUT"; run_preflight none
if [ -s "$MUT" ]; then none_noop=0; else none_noop=1; fi
ck "no candidate dog beads → noop (fast healthy path)" 1 "$none_noop"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
