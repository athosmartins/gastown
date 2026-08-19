#!/usr/bin/env bash
# crew-idle-check.sh (ga-06mt3k) — "is this named crew idle-eligible for an
# autonomous close" check. Part of the city capacity-containment story
# (ga-06mt3k), which draws the line the Mayor now enforces between Layer 1
# (named crews — Athos's persistent "people": oracle, mila, digo, thies,
# peter, batista, one instance per rig they're staffed on) and Layer 2
# (elastic pools: dog, wa-worker, ps-worker, gate-reviewer, already contained
# by ga-m2gqb's dispatch pause under RAM pressure).
#
# Athos's own decision (14/08 18:36, baked into ga-06mt3k's acceptance
# criteria) requires FOUR measured conditions, ALL of them — not any one —
# before a named crew counts as idle, PLUS no uncommitted work:
#   1. no bd issue in_progress assigned to the crew
#   2. no recent commit in the crew's own work_dir
#   3. no session activity (tmux pane CPU time genuinely flat)
#   4. no live quality-gate marker for the crew's recently-closed work
#   + no uncommitted (dirty) changes in the crew's work_dir
# "Sem escrita há N minutos sozinho NAO basta" — Athos's own words, because a
# weaker single-signal check produced 4 false positives in one day elsewhere
# in this city (see bead-stalled-at-gate-triage-tree class of bug). Every
# condition here defaults FAIL-CLOSED (idle=false) on any read error — an
# unreadable check must never look like a confirmed-idle reading, because the
# reading feeds an AUTONOMOUS close of a named crew's persistent session.
#
# Layer-1 membership is LIVE-DERIVED from agents/*/agent.toml, never a static
# name list: work_dir matching "…/crew/<slug>" where <slug> != "worker" (the
# generic pool work_dir), AND max_active_sessions <= 1 (singleton — the
# structural signature of a persistent named identity vs. an elastic pool).
# Confirmed live 2026-08-18 this correctly separates all 10 current named-crew
# instances (oracle-wa, mila-wa, mila-ma, digo-wa, thies-wa, thies-ps,
# peter-wa, batista-lx, batista-ps, batista-wa) from every pool/reviewer
# config (wa-worker, ps-worker, gate-reviewer, refino-gate-reviewer,
# context-check-reviewer, auto-refiner — none have a "crew/<non-worker>"
# work_dir) without hardcoding either list — a name list would need a human to
# remember to update it every time a rig gains a new named-crew instance.
#
# Library mode: `CREW_IDLE_CHECK_LIB=1 source crew-idle-check.sh` defines the
# functions below without running the CLI flow at the bottom. Used by
# crew-capacity-containment.sh.
# CLI mode: `crew-idle-check.sh <agent-name>` prints one JSON line.
# Test: `bash crew-idle-check.sh --selftest`
set -uo pipefail

BD="${BD:-bd}"
GIT="${GIT:-git}"
TMUX="${TMUX:-tmux}"
GC="${GC:-gc}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
AGENTS_DIR="${CREW_IDLE_AGENTS_DIR:-${CITY}/agents}"

RECENT_GIT_LOOKBACK_HOURS="${CREW_IDLE_GIT_LOOKBACK_HOURS:-4}"
GATE_MARKER_LOOKBACK_HOURS="${CREW_IDLE_GATE_LOOKBACK_HOURS:-48}"
IDLE_CPU_SAMPLE_SEC="${CREW_IDLE_CPU_SAMPLE_SEC:-5}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [crew-idle-check] $*" >&2; }

# ════════════════════════════════════════════════════════════════════════════
# PURE/TESTABLE CONDITION FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════

# _layer1_crew_names → one agent name per line (see header for the derivation
# rule). Reads only agents/*/agent.toml — no bd, no gc, no network.
_layer1_crew_names() {
  local dir name wd max dir_root="${CREW_IDLE_AGENTS_DIR:-$AGENTS_DIR}"
  for dir in "${dir_root}"/*/; do
    [ -d "$dir" ] || continue
    [ -f "${dir}agent.toml" ] || continue
    name="$(basename "$dir")"
    wd="$(grep -E '^work_dir[[:space:]]*=' "${dir}agent.toml" 2>/dev/null \
          | sed -E 's/^work_dir[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
    [ -n "$wd" ] || continue
    case "$wd" in
      */crew/worker) continue ;;
      */crew/*) : ;;
      *) continue ;;
    esac
    max="$(grep -E '^max_active_sessions[[:space:]]*=' "${dir}agent.toml" 2>/dev/null \
           | sed -E 's/^max_active_sessions[[:space:]]*=[[:space:]]*([0-9]+).*/\1/')"
    case "$max" in ''|*[!0-9]*) max=1 ;; esac
    [ "$max" -le 1 ] || continue
    printf '%s\n' "$name"
  done
}

# _agent_work_dir <agent_name> → prints the agent's work_dir straight from
# its own agent.toml (same file+field _layer1_crew_names already trusts to
# derive Layer-1 identity in the first place), or nothing + return 1 if the
# agent.toml is missing/unreadable or has no work_dir line. Deliberately
# does NOT read `gc session list`: gate review ga-ego18 found that field is
# not schema-guaranteed on the live-controller API code path (only the
# no-controller local fallback path is documented to populate it) --
# crew-capacity-containment.sh's own per-crew loop used to depend on it via
# `gc session list --json`, which is exactly the fragile external
# dependency this reads around. Re-checks CREW_IDLE_AGENTS_DIR fresh on
# every call (not just AGENTS_DIR's parse-time default) for the same reason
# _layer1_crew_names does two lines below -- a caller overriding the agents
# dir on a later call needs that to take effect immediately.
_agent_work_dir() {
  local agent="$1" dir_root="${CREW_IDLE_AGENTS_DIR:-$AGENTS_DIR}" dir wd
  [ -n "$agent" ] || return 1
  dir="${dir_root}/${agent}"
  [ -f "${dir}/agent.toml" ] || return 1
  wd="$(grep -E '^work_dir[[:space:]]*=' "${dir}/agent.toml" 2>/dev/null \
        | sed -E 's/^work_dir[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
  [ -n "$wd" ] || return 1
  printf '%s' "$wd"
}

# _rig_path_for_work_dir <work_dir> → the rig root ("/Users/.../gt/<rig>"),
# derived by stripping the "/crew/<name>" suffix. A crew's own beads live in
# ITS RIG's bd store, not HQ's (confirmed live: bd -C HQ --assignee=oracle-wa
# returns [] while bd -C whatsapp_automation --assignee=oracle-wa has 29 closed
# hits) — gate MARKERS are the one exception, always in HQ (see
# _crew_no_open_gate_marker).
_rig_path_for_work_dir() {
  local wd="$1"
  case "$wd" in
    */crew/*) printf '%s' "${wd%/crew/*}" ;;
    *) return 1 ;;
  esac
}

# _crew_no_inprogress_bead <identity> <rig_path> → 0 (pass) iff zero in_progress
# beads assigned to identity in that rig's store. FAIL-CLOSED (return 1) on any
# bd/parse error.
_crew_no_inprogress_bead() {
  local identity="$1" rig="$2" out n
  [ -n "$identity" ] && [ -n "$rig" ] || return 1
  out="$(timeout 20 "$BD" -C "$rig" list --status in_progress --assignee "$identity" --json --limit 0 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  n="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit(0)
print(len(d) if isinstance(d, list) else -1)
' 2>/dev/null)"
  [ "$n" = "0" ]
}

# _crew_no_recent_git_activity <work_dir> <lookback_hours> → 0 (pass) iff
# HEAD's own commit time is older than lookback_hours. Deliberately checks
# HEAD only, not --all: --all would also pick up ref updates from a background
# fetch of shared branches the crew never touched itself. FAIL-CLOSED on any
# git error (not a repo, missing dir, timeout, unparseable timestamp).
_crew_no_recent_git_activity() {
  local work_dir="$1" lookback_hours="${2:-$RECENT_GIT_LOOKBACK_HOURS}" last_ts now
  [ -n "$work_dir" ] && [ -d "$work_dir" ] || return 1
  last_ts="$(timeout 15 "$GIT" -C "$work_dir" log -1 --format=%ct 2>/dev/null)" || return 1
  case "$last_ts" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - last_ts )) -gt $(( lookback_hours * 3600 )) ]
}

# _crew_no_uncommitted_work <work_dir> → 0 (pass) iff `git status --porcelain`
# is empty. FAIL-CLOSED on any git error.
_crew_no_uncommitted_work() {
  local work_dir="$1" out
  [ -n "$work_dir" ] && [ -d "$work_dir" ] || return 1
  out="$(timeout 15 "$GIT" -C "$work_dir" status --porcelain 2>/dev/null)" || return 1
  [ -z "$out" ]
}

# _bead_has_open_gate_marker <bead_id> → 0 iff an OPEN type:quality-gate-marker
# in the HQ store names bead_id via source-bead:<id>. Adapted directly from
# agent-stuck-escalation.sh's bead_has_open_gate_marker (ga-n937) — same query
# shape, not reinvented. Gate artifacts always live in HQ regardless of the
# bead's own rig. FAIL-CLOSED (return 1 = "no marker found") on any bd/parse
# error — deliberately the OPPOSITE fail direction from
# agent-stuck-escalation.sh's own copy, because that one only SUPPRESSES a
# stall escalation (fail-open is safe there), while this one gates an
# AUTONOMOUS CLOSE (fail-closed — "couldn't tell" must count as "assume a
# marker exists," never as "confirmed none").
_bead_has_open_gate_marker() {
  local bid="$1" arts bd_rc hit
  # Every non-confirmed path below returns 0 ("assume a marker exists") — the
  # ONLY path that returns 1 ("no marker") is a positively parsed, confirmed
  # zero count. Caught in gate-done's own mandatory third-state self-audit:
  # an earlier version of this function returned 1 (its "no marker" value) on
  # bid-empty, bd-exec-failure, AND python-parse-failure — exactly backwards
  # from the fail-closed intent stated in this function's own header comment
  # above, and never caught by the selftest because every mocked scenario
  # returned well-formed JSON, never simulating a raw bd/parse failure. Fixed
  # by making "confirmed zero" the single narrow path to 1, everything else 0.
  [ -n "$bid" ] || return 0
  arts="$(timeout 15 "$BD" -C "$CITY" list --include-infra -l "source-bead:$bid" --json --limit 0 2>/dev/null)"
  bd_rc=$?
  [ "$bd_rc" -eq 0 ] || return 0
  # Empty stdout on a successful exit is itself anomalous, not a confirmed
  # zero-result read — every other bd-JSON reader in this file (e.g.
  # _crew_no_inprogress_bead) already treats a genuinely empty string as
  # unreadable rather than "confirmed empty list", since a real zero-match
  # `bd list --json` prints "[]" (2 bytes), not nothing.
  [ -n "$arts" ] || return 0
  hit="$(printf '%s' "$arts" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(-1); sys.exit(0)
if isinstance(d, dict):
    d = [d]
if not isinstance(d, list):
    print(-1); sys.exit(0)
n = 0
for b in d:
    if not isinstance(b, dict):
        continue
    if b.get("status") != "open":
        continue
    if "type:quality-gate-marker" in (b.get("labels") or []):
        n += 1
print(n)
' 2>/dev/null)"
  case "$hit" in
    0) return 1 ;;        # CONFIRMED zero open markers — the only "no marker" path
    ''|-1) return 0 ;;    # parse failure — unconfirmed, assume marker exists
    *) return 0 ;;        # N>0 confirmed open markers
  esac
}
# NOTE on the inversion above: this function's own return convention is
# "0 = a marker WAS found", matching agent-stuck-escalation.sh's original
# naming (bead_has_open_gate_marker → true means "has one"). The caller,
# _crew_no_open_gate_marker below, inverts it — its OWN name promises "0 =
# pass = none found", so it flips the sense once, in one place, rather than
# every call site re-deriving which direction is "good."

# _crew_no_open_gate_marker <identity> <rig_path> <lookback_hours> → 0 (pass)
# iff none of identity's beads closed within lookback_hours (in rig_path's
# store) has an open gate marker. FAIL-CLOSED on any bd/parse error.
_crew_no_open_gate_marker() {
  local identity="$1" rig="$2" lookback_hours="${3:-$GATE_MARKER_LOOKBACK_HOURS}" closed cutoff ids id
  [ -n "$identity" ] && [ -n "$rig" ] || return 1
  cutoff=$(( $(date +%s) - lookback_hours * 3600 ))
  closed="$(timeout 20 "$BD" -C "$rig" list --status closed --assignee "$identity" --json --limit 0 2>/dev/null)" || return 1
  [ -n "$closed" ] || return 1
  ids="$(CUTOFF="$cutoff" printf '%s' "$closed" | CUTOFF="$cutoff" python3 -c '
import json, sys, os, datetime
cutoff = int(os.environ["CUTOFF"])
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, list):
    sys.exit(1)
for b in d:
    if not isinstance(b, dict):
        continue
    ca = b.get("closed_at") or b.get("updated_at") or ""
    try:
        ts = datetime.datetime.fromisoformat(ca.replace("Z", "+00:00")).timestamp()
    except Exception:
        # Unparseable/missing date: cannot confirm this bead is OUTSIDE the
        # lookback window, so it must be included (checked) -- same
        # fail-toward-inclusion contract as _bead_has_open_gate_marker
        # above. A ts=0 fallback would silently exclude it instead (0 never
        # satisfies ">= cutoff"), which is the exact bug this branch was
        # gate-rejected for (ga-bjmp6).
        print(b.get("id") or "")
        continue
    if ts >= cutoff:
        print(b.get("id") or "")
' 2>/dev/null)" || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if _bead_has_open_gate_marker "$id"; then
      return 1
    fi
  done <<< "$ids"
  return 0
}

# _crew_session_idle <session_name> → tri-state via two-sample tmux-pane CPU
# TIME comparison (raw `ps -o time=` string, never converted to int — the
# string itself already carries centisecond precision, so comparing it
# directly cannot lose precision the way a naive int-seconds conversion would
# — see agent-stuck-escalation.sh's pane_cpu_time_secs comment for the
# measured failure mode this sidesteps by construction, not by porting its
# conversion code):
#   0 = idle CONFIRMED (identical TIME across two samples IDLE_CPU_SAMPLE_SEC apart)
#   1 = NOT idle (TIME changed)
#   2 = UNKNOWN (pane/PID unresolved) — the CALLER must treat this as
#       not-idle-eligible. This is the opposite fail direction from
#       agent-stuck-escalation.sh's own pane_truly_idle(), which only
#       corroborates an ALREADY-established stall verdict; here the session
#       check is a PRIMARY gate on an autonomous close, so "unknown" must
#       never read as "confirmed idle."
# Override seam (selftest / manual override): CREW_IDLE_SESSION_OVERRIDE=idle|active|unknown
_crew_session_idle() {
  local sess="$1" pid t1 t2
  case "${CREW_IDLE_SESSION_OVERRIDE:-}" in
    idle) return 0 ;;
    active) return 1 ;;
    unknown) return 2 ;;
  esac
  pid="$(timeout 10 "$TMUX" list-panes -t "$sess" -F '#{pane_pid}' 2>/dev/null | head -1)"
  [ -n "$pid" ] || return 2
  t1="$(ps -o time= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$t1" ] || return 2
  sleep "$IDLE_CPU_SAMPLE_SEC"
  t2="$(ps -o time= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$t2" ] || return 2
  [ "$t1" = "$t2" ] && return 0
  return 1
}

# crew_idle_report <agent> <session> <work_dir> <rig_path> [identity]
# → prints one JSON line: {"agent","idle","attached","reasons":[...]}.
# ALL conditions must pass (AC: "todas, nao qualquer uma"). Does not itself
# check "attached" (the live-session "human is watching" flag) — the
# orchestrator checks that separately and skips evaluation entirely rather
# than folding it into this report, since an attached session should never
# even be ASKED about, day or night.
crew_idle_report() {
  local agent="$1" session="$2" work_dir="$3" rig="$4" identity="${5:-$2}"
  local idle=1 reasons=""

  if _crew_no_inprogress_bead "$identity" "$rig"; then reasons="${reasons}no_inprogress_bead:pass,"
  else idle=0; reasons="${reasons}no_inprogress_bead:fail,"; fi

  if _crew_no_recent_git_activity "$work_dir" "$RECENT_GIT_LOOKBACK_HOURS"; then reasons="${reasons}no_recent_git:pass,"
  else idle=0; reasons="${reasons}no_recent_git:fail,"; fi

  if _crew_no_uncommitted_work "$work_dir"; then reasons="${reasons}no_uncommitted:pass,"
  else idle=0; reasons="${reasons}no_uncommitted:fail,"; fi

  if _crew_no_open_gate_marker "$identity" "$rig" "$GATE_MARKER_LOOKBACK_HOURS"; then reasons="${reasons}no_gate_marker:pass,"
  else idle=0; reasons="${reasons}no_gate_marker:fail,"; fi

  _crew_session_idle "$session"
  case $? in
    0) reasons="${reasons}session_idle:pass," ;;
    1) idle=0; reasons="${reasons}session_idle:fail," ;;
    2) idle=0; reasons="${reasons}session_idle:unknown," ;;
  esac

  AGENT="$agent" IDLE="$idle" REASONS="$reasons" python3 -c '
import json, os
reasons = [r for r in os.environ["REASONS"].split(",") if r]
print(json.dumps({
    "agent": os.environ["AGENT"],
    "idle": os.environ["IDLE"] == "1",
    "reasons": reasons,
}))
'
}

# ════════════════════════════════════════════════════════════════════════════
# CLI / selftest
# ════════════════════════════════════════════════════════════════════════════

# Guarded on CREW_IDLE_CHECK_LIB too (not just $1): a caller that sources this
# file in library mode (`CREW_IDLE_CHECK_LIB=1 source crew-idle-check.sh`)
# inherits the CALLER's own positional params during the source call — if the
# caller's own $1 happens to be "--selftest" (e.g. crew-capacity-containment.sh
# invoked as `... --selftest`), this block would otherwise run THIS file's
# selftest (which exit()s) instead of just defining functions. Caught live
# composing crew-capacity-containment.sh's own selftest.
if [ "${1:-}" = "--selftest" ] && [ "${CREW_IDLE_CHECK_LIB:-0}" != "1" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }

  _ST_ROOT="$(mktemp -d /tmp/cic-selftest.XXXXXX)"
  trap 'rm -rf "${_ST_ROOT}"' EXIT

  echo "S1: _layer1_crew_names — derives from agent.toml, not a hardcoded list"
  _ST_AGENTS="${_ST_ROOT}/agents"
  mkdir -p "${_ST_AGENTS}/oracle-wa" "${_ST_AGENTS}/wa-worker" "${_ST_AGENTS}/gate-reviewer" "${_ST_AGENTS}/thies-ps" "${_ST_AGENTS}/broken"
  printf 'max_active_sessions = 1\nmin_active_sessions = 1\nwork_dir = "/x/whatsapp_automation/crew/oracle"\n' > "${_ST_AGENTS}/oracle-wa/agent.toml"
  printf 'max_active_sessions = 4\nmin_active_sessions = 0\nwork_dir = "/x/whatsapp_automation/crew/worker"\n' > "${_ST_AGENTS}/wa-worker/agent.toml"
  printf 'max_active_sessions = 6\nmin_active_sessions = 0\n' > "${_ST_AGENTS}/gate-reviewer/agent.toml"
  printf 'max_active_sessions = 1\nwork_dir = "/x/property_scrapers/crew/thies"\n' > "${_ST_AGENTS}/thies-ps/agent.toml"
  # broken/ has no agent.toml at all — must be silently skipped, not error
  _st_names="$(CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _layer1_crew_names | sort)"
  [ "$_st_names" = "$(printf 'oracle-wa\nthies-ps')" ] && ok "layer1 = {oracle-wa, thies-ps}; wa-worker/gate-reviewer/broken excluded" \
    || bad "wrong layer1 set — got: $_st_names"

  echo "S2: _rig_path_for_work_dir"
  [ "$(_rig_path_for_work_dir '/Users/athos/gt/whatsapp_automation/crew/oracle')" = "/Users/athos/gt/whatsapp_automation" ] \
    && ok "strips /crew/<name> suffix" || bad "wrong rig path"
  _rig_path_for_work_dir '/no/such/segment/nope' >/dev/null 2>&1 && bad "path with no /crew/ substring should fail" \
    || ok "no /crew/ segment anywhere in path -> return 1"
  _rig_path_for_work_dir '' >/dev/null 2>&1 && bad "empty input should fail" || ok "empty work_dir -> return 1"

  echo "S2b: _agent_work_dir — reads agent.toml directly, no gc/session dependency (ga-ego18)"
  # Reuses S1's _ST_AGENTS fixture: oracle-wa has a real work_dir line,
  # gate-reviewer has an agent.toml with NO work_dir line, broken/ has no
  # agent.toml at all -- covers both failure shapes, not just the happy path.
  [ "$(CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _agent_work_dir oracle-wa)" = "/x/whatsapp_automation/crew/oracle" ] \
    && ok "reads work_dir straight from agent.toml" || bad "should read oracle-wa's work_dir"
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _agent_work_dir gate-reviewer >/dev/null 2>&1 \
    && bad "agent.toml with no work_dir line should fail" || ok "agent.toml present but no work_dir line -> return 1"
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _agent_work_dir broken >/dev/null 2>&1 \
    && bad "missing agent.toml should fail" || ok "no agent.toml at all -> return 1"
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _agent_work_dir nosuchagent >/dev/null 2>&1 \
    && bad "nonexistent agent should fail" || ok "agent directory doesn't exist -> return 1"
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS}" _agent_work_dir '' >/dev/null 2>&1 \
    && bad "empty agent name should fail" || ok "empty agent name -> return 1"

  echo "S3: _crew_no_inprogress_bead — mocked BD"
  _ST_BD="${_ST_ROOT}/mock-bd"
  cat > "${_ST_BD}" <<'MOCKBD'
#!/usr/bin/env bash
case "$MOCK_BD_MODE" in
  empty) echo '[]' ;;
  one) echo '[{"id":"x-1"}]' ;;
  error) exit 1 ;;
  garbage) echo 'not json' ;;
esac
MOCKBD
  chmod +x "${_ST_BD}"
  BD="${_ST_BD}" MOCK_BD_MODE=empty _crew_no_inprogress_bead ident /rig && ok "zero in_progress -> pass" || bad "should pass on empty list"
  BD="${_ST_BD}" MOCK_BD_MODE=one _crew_no_inprogress_bead ident /rig && bad "one in_progress should NOT pass" || ok "one in_progress -> fail"
  BD="${_ST_BD}" MOCK_BD_MODE=error _crew_no_inprogress_bead ident /rig && bad "bd error should fail-closed" || ok "bd error -> fail-closed"
  BD="${_ST_BD}" MOCK_BD_MODE=garbage _crew_no_inprogress_bead ident /rig && bad "garbage json should fail-closed" || ok "garbage json -> fail-closed"
  _crew_no_inprogress_bead "" /rig && bad "empty identity should fail-closed" || ok "empty identity -> fail-closed"

  echo "S4: _crew_no_recent_git_activity + _crew_no_uncommitted_work — real temp git repo"
  _ST_REPO="${_ST_ROOT}/repo"
  mkdir -p "${_ST_REPO}"
  ( cd "${_ST_REPO}" && "${GIT:-git}" init -q && "${GIT:-git}" config user.email t@t.local && "${GIT:-git}" config user.name t \
      && echo one > f.txt && "${GIT:-git}" add f.txt \
      && GIT_AUTHOR_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         GIT_COMMITTER_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         "${GIT:-git}" commit -q -m old )
  _crew_no_recent_git_activity "${_ST_REPO}" 4 && ok "10h-old commit, 4h lookback -> no recent activity (pass)" || bad "should pass, commit is old"
  _crew_no_uncommitted_work "${_ST_REPO}" && ok "clean tree -> no uncommitted (pass)" || bad "should pass, tree is clean"
  ( cd "${_ST_REPO}" && echo dirty >> f.txt )
  _crew_no_uncommitted_work "${_ST_REPO}" && bad "dirty tree should NOT pass" || ok "dirty tree -> fail"
  ( cd "${_ST_REPO}" && "${GIT:-git}" checkout -q -- f.txt \
      && "${GIT:-git}" commit -q --allow-empty -m recent )
  _crew_no_recent_git_activity "${_ST_REPO}" 4 && bad "just-made commit should count as recent" || ok "fresh commit, 4h lookback -> recent activity (fail)"
  _crew_no_recent_git_activity "/nonexistent/path" 4 && bad "missing dir should fail-closed" || ok "missing work_dir -> fail-closed"
  _crew_no_uncommitted_work "/nonexistent/path" && bad "missing dir should fail-closed" || ok "missing work_dir (uncommitted check) -> fail-closed"

  echo "S5: _bead_has_open_gate_marker + _crew_no_open_gate_marker — mocked BD"
  _ST_BD2="${_ST_ROOT}/mock-bd2"
  cat > "${_ST_BD2}" <<'MOCKBD2'
#!/usr/bin/env bash
# args land in "$@"; find the -l source-bead:<id> or --assignee/--status combo
for a in "$@"; do
  case "$a" in
    source-bead:marked-bead) echo '[{"status":"open","labels":["type:quality-gate-marker"]}]'; exit 0 ;;
    source-bead:clean-bead) echo '[]'; exit 0 ;;
    source-bead:error-bead) exit 1 ;;
    source-bead:empty-stdout-bead) exit 0 ;;
    source-bead:garbage-bead) echo 'not json'; exit 0 ;;
    source-bead:unparseable-with-marker) echo '[{"status":"open","labels":["type:quality-gate-marker"]}]'; exit 0 ;;
    source-bead:unparseable-no-marker) echo '[]'; exit 0 ;;
  esac
done
case "$MOCK_BD2_MODE" in
  has_marked) echo '[{"id":"marked-bead","closed_at":"2026-08-18T10:00:00Z"}]' ;;
  all_clean) echo '[{"id":"clean-bead","closed_at":"2026-08-18T10:00:00Z"}]' ;;
  old_only) echo '[{"id":"marked-bead","closed_at":"2020-01-01T00:00:00Z"}]' ;;
  empty) echo '[]' ;;
  unparseable_date_has_marker) echo '[{"id":"unparseable-with-marker","closed_at":"not-a-valid-date"}]' ;;
  unparseable_date_no_marker) echo '[{"id":"unparseable-no-marker"}]' ;;
esac
MOCKBD2
  chmod +x "${_ST_BD2}"
  BD="${_ST_BD2}" _bead_has_open_gate_marker marked-bead && ok "open marker found -> rc=0 (has one)" || bad "should find the marker"
  BD="${_ST_BD2}" _bead_has_open_gate_marker clean-bead && bad "no marker should be rc=1" || ok "no marker -> rc=1 (none found)"
  # These four assert the gate-done self-audit fix directly: every
  # non-confirmed read must fail toward "assume a marker exists" (rc=0), the
  # bug this fixed had these returning rc=1 ("no marker") instead — silently
  # collapsing "couldn't tell" into "confirmed none" on the path that gates
  # an autonomous crew close.
  BD="${_ST_BD2}" _bead_has_open_gate_marker '' && ok "empty bid -> rc=0 (assume has marker, can't identify what to check)" || bad "empty bid should fail toward 'has marker'"
  BD="${_ST_BD2}" _bead_has_open_gate_marker error-bead && ok "bd exec failure -> rc=0 (assume has marker)" || bad "bd failure should fail toward 'has marker', not 'no marker'"
  BD="${_ST_BD2}" _bead_has_open_gate_marker empty-stdout-bead && ok "empty stdout on success -> rc=0 (assume has marker, anomalous not confirmed-zero)" || bad "empty stdout should fail toward 'has marker'"
  BD="${_ST_BD2}" _bead_has_open_gate_marker garbage-bead && ok "malformed JSON -> rc=0 (assume has marker)" || bad "parse failure should fail toward 'has marker'"
  BD="${_ST_BD2}" MOCK_BD2_MODE=has_marked _crew_no_open_gate_marker ident /rig 999999 && bad "recent closed bead WITH open marker should NOT pass" \
    || ok "recent bead has open marker -> fail (not idle-eligible)"
  BD="${_ST_BD2}" MOCK_BD2_MODE=all_clean _crew_no_open_gate_marker ident /rig 999999 && ok "recent closed bead with no marker -> pass" \
    || bad "should pass, no markers"
  BD="${_ST_BD2}" MOCK_BD2_MODE=old_only _crew_no_open_gate_marker ident /rig 1 && ok "marked bead OUTSIDE lookback window -> pass (not counted)" \
    || bad "old bead should be excluded by lookback cutoff"
  BD="${_ST_BD2}" MOCK_BD2_MODE=empty _crew_no_open_gate_marker ident /rig 999999 && ok "no closed beads at all -> pass" || bad "empty list should pass"
  # Regression coverage for the gate-rejected bug (ga-bjmp6): a per-bead date
  # parse failure used to fall back to ts=0, which can never satisfy ">=
  # cutoff" -- silently excluding the bead from the checked set instead of
  # including it. These two cases fail against that old behavior (the marker
  # case would wrongly report "pass") and pass against the fix.
  # NOTE: lookback_hours must be a realistic value here (48, matching the
  # real GATE_MARKER_LOOKBACK_HOURS default), NOT the 999999 used by the
  # other cases above -- at that magnitude cutoff=now-999999*3600 goes
  # NEGATIVE, and ts=0 >= a negative cutoff is true, which accidentally
  # masks this exact bug instead of exercising it (caught via mutation
  # testing: reverting the fix to ts=0 still passed with 999999).
  BD="${_ST_BD2}" MOCK_BD2_MODE=unparseable_date_has_marker _crew_no_open_gate_marker ident /rig 48 && bad "bead with unparseable closed_at that HAS an open marker should NOT pass" \
    || ok "unparseable date -> bead still gets checked, its open marker is found -> fail (not idle-eligible)"
  BD="${_ST_BD2}" MOCK_BD2_MODE=unparseable_date_no_marker _crew_no_open_gate_marker ident /rig 48 && ok "bead with unparseable/missing date but no marker -> pass" \
    || bad "should still pass when the checked bead genuinely has no marker"

  echo "S6: _crew_session_idle — override seam"
  CREW_IDLE_SESSION_OVERRIDE=idle _crew_session_idle whatever && ok "override=idle -> rc=0" || bad "override=idle should give rc=0"
  CREW_IDLE_SESSION_OVERRIDE=active _crew_session_idle whatever; [ $? -eq 1 ] && ok "override=active -> rc=1" || bad "override=active should give rc=1"
  CREW_IDLE_SESSION_OVERRIDE=unknown _crew_session_idle whatever; [ $? -eq 2 ] && ok "override=unknown -> rc=2" || bad "override=unknown should give rc=2"
  CREW_IDLE_SESSION_OVERRIDE='' _crew_session_idle nonexistent-tmux-session-xyz; [ $? -eq 2 ] && ok "unresolvable real session -> rc=2 (unknown)" || bad "should be unknown, not a hard fail"

  echo "S7: crew_idle_report — end-to-end, all-pass and one-fail cases"
  _ST_REPO2="${_ST_ROOT}/repo2"
  mkdir -p "${_ST_REPO2}"
  ( cd "${_ST_REPO2}" && "${GIT:-git}" init -q && "${GIT:-git}" config user.email t@t.local && "${GIT:-git}" config user.name t \
      && GIT_AUTHOR_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         GIT_COMMITTER_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         "${GIT:-git}" commit -q --allow-empty -m old )
  # A discriminating mock: distinguishes the in-progress query (always empty)
  # from the closed-beads query (one clean bead, no marker) by inspecting
  # which --status value it was called with — S3/S5's mocks each only needed
  # to answer ONE query shape; this end-to-end test exercises both in the same
  # crew_idle_report() call, so it needs to tell them apart.
  _ST_BD3="${_ST_ROOT}/mock-bd3"
  cat > "${_ST_BD3}" <<'MOCKBD3'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    source-bead:*) echo '[]'; exit 0 ;;
  esac
done
prev=""
for a in "$@"; do
  if [ "$prev" = "--status" ]; then
    case "$a" in
      in_progress) echo '[]'; exit 0 ;;
      closed) echo '[{"id":"clean-bead","closed_at":"2026-08-18T10:00:00Z"}]'; exit 0 ;;
    esac
  fi
  prev="$a"
done
echo '[]'
MOCKBD3
  chmod +x "${_ST_BD3}"
  _st_report="$(BD="${_ST_BD3}" CREW_IDLE_SESSION_OVERRIDE=idle crew_idle_report agentX sessX "${_ST_REPO2}" /rig identX)"
  echo "$_st_report" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['idle'] is True and d['agent']=='agentX' else 1)" \
    && ok "all conditions pass -> idle=true" || bad "expected idle=true, got: $_st_report"
  _st_report2="$(BD="${_ST_BD3}" CREW_IDLE_SESSION_OVERRIDE=active crew_idle_report agentX sessX "${_ST_REPO2}" /rig identX)"
  echo "$_st_report2" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d['idle'] is False else 1)" \
    && ok "session NOT idle alone flips overall idle=false (AC: all 4, not any)" || bad "expected idle=false, got: $_st_report2"

  echo ""; echo "crew-idle-check selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

if [ "${CREW_IDLE_CHECK_LIB:-0}" != "1" ] && [ "${1:-}" != "--selftest" ]; then
  agent="${1:?usage: crew-idle-check.sh <agent-name>}"
  dir="${AGENTS_DIR}/${agent}"
  [ -f "${dir}/agent.toml" ] || { echo "ERROR: no agent.toml for '${agent}' under ${AGENTS_DIR}" >&2; exit 2; }
  work_dir="$(grep -E '^work_dir[[:space:]]*=' "${dir}/agent.toml" 2>/dev/null | sed -E 's/^work_dir[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
  [ -n "$work_dir" ] || { echo "ERROR: '${agent}' has no work_dir — not a layer-1 crew identity" >&2; exit 2; }
  rig="$(_rig_path_for_work_dir "$work_dir")" || { echo "ERROR: could not derive rig path from ${work_dir}" >&2; exit 2; }
  crew_idle_report "$agent" "$agent" "$work_dir" "$rig" "$agent"
fi
