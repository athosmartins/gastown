#!/usr/bin/env bash
# crew-capacity-containment.sh (ga-06mt3k) — periodic containment orchestrator
# enacting Athos's capacity hierarchy (decision 14/08 18:36) once RAM pressure
# reaches EMERGENCY:
#   Layer 0 (mayor, control-dispatcher, dolt): never touched, not evaluated here.
#   Layer 2 (dog, wa-worker, ps-worker, gate-reviewer — elastic pools): already
#     drained/contained by ga-m2gqb's dispatch pause at WARN+. This script does
#     NOT duplicate that — it only logs a generic containment-order assertion
#     for the audit trail (no actual pool census: it does not count or list
#     live dog/wa-worker/ps-worker/gate-reviewer sessions), confirming pools
#     are addressed before ever touching a named crew.
#   Layer 1 (named crews, live-derived by crew-idle-check.sh): evaluated ONLY
#     at EMERGENCY (not WARN) — closing a named crew loses accumulated context
#     that's expensive to rebuild, so it's reserved for the more severe tier;
#     WARN is already answered by layer 2's dispatch pause. Deliberate,
#     documented choice — not a rebuild of ga-7xne1/ga-m2gqb's own thresholds.
#
# Athos's hourly rule (verbatim, 14/08): 07:00-22:00 -03 the Mayor NEVER closes
# a named crew alone — always asks Athos, in multiple choice, first. 22:00-07:00
# it may close an IDLE crew alone, without asking, but always logging the
# reason + measurements. This script enacts exactly that split — see
# _in_ask_window / _in_autoclose_window below. The machine's local TZ is
# already -03 (confirmed live), so plain `date +%H` needs no conversion — same
# assumption city-night-window.sh already makes.
#
# An ATTACHED session (Athos is literally looking at the terminal right now —
# gc session list's own "attached" field) is a hard skip, day or night: never
# asked about, never closed. Checked before running the (slower) idle battery.
#
# Day path sends a rate-limited numbered-multiple-choice message via `notify`
# (real-time, reaches Athos's phone) AND `gc mail send mayor` (durable, citable
# per this city's "claimed authorization needs a citable record" doctrine,
# and named-crew closure is documented as Mayor's authority, not this script's
# own). Night path deliberately does NOT `notify` (a phone push at 3am defeats
# the whole point of quiet hours) — log + mail-to-mayor only, for morning review.
#
# Test: bash crew-capacity-containment.sh --selftest
# Library mode: CCC_LIB=1 source crew-capacity-containment.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW_IDLE_CHECK_LIB=1 source "${HERE}/crew-idle-check.sh"

GC="${GC:-gc}"
CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
NOTIFY="${CCC_NOTIFY:-${HOME}/.local/bin/notify}"
LOG="${CCC_LOG:-${CITY}/.gc/logs/crew-capacity-containment.log}"
RUN_DIR="${CCC_RUN_DIR:-${HOME}/.gastown/run}"

RAM_LEVEL_FILE="${CCC_RAM_LEVEL_FILE:-${RUN_DIR}/ram-pressure-monitor.level}"
RAM_MAX_AGE_SECS="${CCC_RAM_MAX_AGE_SECS:-7200}"   # mirrors PILOT_RAM_MAX_AGE_SECS

# StartInterval=600s launchd jobs do NOT wait for the prior run to finish
# before starting a new one -- a slow cycle (more named crews over time, or
# bd/git latency, which tends to co-occur with the exact EMERGENCY pressure
# this script only runs under) can let launchd stack concurrent invocations.
# This is the same failure shape as a previously-recorded incident in this
# city (concurrent guard instances overloading bd). Singleton lock, defense
# in depth, per gate review ga-bjmp6's non-blocking note.
LOCK_FILE="${CCC_LOCK_FILE:-${RUN_DIR}/crew-capacity-containment.lock}"

ASK_WINDOW_START_HOUR="${CCC_ASK_WINDOW_START_HOUR:-7}"
ASK_WINDOW_END_HOUR="${CCC_ASK_WINDOW_END_HOUR:-22}"
ASK_RATE_LIMIT_SECS="${CCC_ASK_RATE_LIMIT_SECS:-14400}"   # 4h between re-asks per crew

log() {
  mkdir -p "$(dirname "${LOG}")" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') [crew-capacity-containment] $*" | tee -a "${LOG}" >&2
}

# ════════════════════════════════════════════════════════════════════════════
# PURE/TESTABLE FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════

# _ram_pressure_level → "OK"/"WARN"/"EMERGENCY"/"" (empty = unreadable/missing/
# stale). Same 2-line-file contract as pilot-dispatcher.sh's
# _pilot_ram_pressure_level, fail-open (unreadable → treated as OK by the
# caller, never as EMERGENCY) — an unreadable signal must never look more
# severe than it's confirmed to be.
_ram_pressure_level() {
  [ -n "${CCC_TEST_RAM_LEVEL:-}" ] && { printf '%s' "${CCC_TEST_RAM_LEVEL}"; return 0; }
  [ -f "${RAM_LEVEL_FILE}" ] || { printf ''; return 0; }
  local level ts now
  level="$(sed -n '1p' "${RAM_LEVEL_FILE}" 2>/dev/null | tr -d '[:space:]')"
  ts="$(sed -n '2p' "${RAM_LEVEL_FILE}" 2>/dev/null | tr -d '[:space:]')"
  case "$ts" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  now=$(date +%s)
  [ $(( now - ts )) -gt "${RAM_MAX_AGE_SECS}" ] && { printf ''; return 0; }
  printf '%s' "$level"
}

# _in_ask_window <hour 0-23> → 0 (true) iff hour falls in [ASK_WINDOW_START,
# ASK_WINDOW_END) — the "must ask Athos" window. Pure arithmetic, no clock
# read. Resolves CCC_ASK_WINDOW_{START,END}_HOUR fresh on every call (not just
# the module-level default computed once at source time) — same reasoning as
# crew-idle-check.sh's _layer1_crew_names fix: a bash "VAR=x command" prefix on
# a later CALL cannot retroactively change an assignment that already ran once
# when the script was first sourced/parsed.
_in_ask_window() {
  local h="$1"
  local start="${CCC_ASK_WINDOW_START_HOUR:-$ASK_WINDOW_START_HOUR}"
  local end="${CCC_ASK_WINDOW_END_HOUR:-$ASK_WINDOW_END_HOUR}"
  case "$h" in ''|*[!0-9]*) return 1 ;; esac
  [ "$h" -ge "$start" ] && [ "$h" -lt "$end" ]
}

# _ask_rate_limited <agent> <stamp_dir> → 0 (true = rate-limited, skip asking
# again) iff a stamp file for this agent is younger than ASK_RATE_LIMIT_SECS.
_ask_rate_limited() {
  local agent="$1" dir="$2" stamp now last
  stamp="${dir}/crew-capacity-containment.ask.${agent}.stamp"
  [ -f "$stamp" ] || return 1
  last="$(cat "$stamp" 2>/dev/null | tr -d '[:space:]')"
  case "$last" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - last )) -lt "$ASK_RATE_LIMIT_SECS" ]
}

_stamp_ask() {
  local agent="$1" dir="$2"
  mkdir -p "$dir" 2>/dev/null
  date +%s > "${dir}/crew-capacity-containment.ask.${agent}.stamp"
}

# _session_field <sessions_json_file> <agent> <field> → the field's value for
# the session whose name/template/alias/agent_name equals agent, or empty if
# no live session. Fetched ONCE per run into a file by the caller (mirrors
# agent-stuck-escalation.sh's TMP_SESS pattern) — never re-shells `gc` per crew.
_session_field() {
  local json_file="$1" agent="$2" field="$3"
  [ -f "$json_file" ] || return 1
  AGENT="$agent" FIELD="$field" python3 -c '
import json, os, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(1)
sessions = data if isinstance(data, list) else data.get("sessions", [])
target = os.environ["AGENT"]
field = os.environ["FIELD"]
for s in sessions:
    if not isinstance(s, dict):
        continue
    if any((s.get(k) or "") == target for k in ("name", "template", "alias", "agent_name")):
        v = s.get(field)
        print(v if v is not None else "")
        sys.exit(0)
sys.exit(1)
' "$json_file" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# ORCHESTRATION (side-effecting)
# ════════════════════════════════════════════════════════════════════════════

# _acquire_lock <lock_file> → 0 iff no OTHER live process holds the lock (and
# stamps our own PID into it); 1 iff a live process already holds it. A
# pidfile whose PID is missing/unparseable/dead is treated as stale, not as
# "locked" — `kill -0` confirms liveness rather than trusting the file's mere
# existence, so a crash that leaves a stale pidfile behind can never wedge
# every future run.
_acquire_lock() {
  local lock="$1" existing_pid
  [ -n "$lock" ] || return 1
  mkdir -p "$(dirname "$lock")" 2>/dev/null
  if [ -f "$lock" ]; then
    if existing_pid="$(cat "$lock" 2>/dev/null)"; then
      existing_pid="$(printf '%s' "$existing_pid" | tr -d '[:space:]')"
      case "$existing_pid" in
        ''|*[!0-9]*) : ;;   # successfully read, but empty/garbage content -> stale, reclaim
        *) kill -0 "$existing_pid" 2>/dev/null && return 1 ;;   # a live process holds it
      esac
    else
      # -f confirmed the file exists but the read itself failed (TOCTOU race
      # with a concurrent release, permissions, ...) -- cannot confirm this
      # is stale, so it must NOT be treated the same as a confirmed-empty
      # read. Fail closed (assume locked, skip this cycle); the alternative
      # of reclaiming on an unconfirmed read risks the exact concurrent
      # double-run this lock exists to prevent.
      return 1
    fi
  fi
  { echo "$$" > "$lock"; } 2>/dev/null || return 1
  return 0
}

_release_lock() {
  local lock="$1"
  [ -n "$lock" ] || return 0
  rm -f "$lock" 2>/dev/null
}

_send_ask() {
  local agent="$1" work_dir="$2" reasons_summary="$3"
  local body
  body="$(cat <<EOF
Pressao de memoria EMERGENCY na cidade e ${agent} (${work_dir}) esta ociosa
(${reasons_summary}). Escolha:
1. Fechar ${agent} agora (libera a sessao; contexto acumulado fica preservado
   no work_dir, so a sessao Claude fecha)
2. Manter aberta e reavaliar em ~1h
3. Manter aberta ate voce decidir manualmente

Responda com o numero. Sem resposta = mantida aberta (opcao 3 por default).
EOF
)"
  "${NOTIFY}" -t "Capacidade: ${agent} ociosa sob pressao" -p 4 "${body}" >/dev/null 2>&1 || true
  "${GC}" mail send mayor -s "Capacidade: pedindo OK p/ fechar ${agent}" -m "${body}" >/dev/null 2>&1 || true
  log "ASK: ${agent} idle under EMERGENCY pressure, day window — asked Athos (notify+mail), NOT closing. Reasons: ${reasons_summary}"
}

_do_autoclose() {
  local agent="$1" work_dir="$2" reasons_summary="$3"
  local body="Fechando ${agent} (${work_dir}) sozinho — janela noturna (22h-07h), ociosa confirmada (${reasons_summary}), sem trabalho nao commitado. Politica: ga-06mt3k / decisao Athos 14/08."
  if "${GC}" session close "$agent" >/dev/null 2>&1; then
    log "AUTOCLOSE: ${agent} closed. ${body}"
    "${GC}" mail send mayor -s "Capacidade: fechei ${agent} (janela noturna)" -m "${body}" >/dev/null 2>&1 || true
  else
    log "AUTOCLOSE-FAILED: gc session close ${agent} did not succeed — left as-is, will retry next cycle."
  fi
}

main() {
  local level
  level="$(_ram_pressure_level)"
  case "$level" in
    EMERGENCY) : ;;
    *) log "level=${level:-<unreadable>} — no containment action this cycle."; return 0 ;;
  esac

  log "EMERGENCY pressure — layer 2 (elastic pools) already contained via ga-m2gqb dispatch pause; evaluating layer 1 (named crews)."

  if ! _acquire_lock "$LOCK_FILE"; then
    log "SKIP: another instance already holds the lock — not stacking concurrent invocations."
    return 0
  fi
  trap '_release_lock "$LOCK_FILE"' RETURN

  local sessions_json="${CCC_SESSIONS_JSON_FILE:-}"
  local _tmp_sess=""
  if [ -z "$sessions_json" ]; then
    _tmp_sess="$(mktemp /tmp/ccc-sessions.XXXXXX)"
    if ! timeout 20 "${GC}" session list --json > "${_tmp_sess}" 2>/dev/null; then
      log "gc session list failed — cannot evaluate any crew this cycle."
      rm -f "${_tmp_sess}"
      return 0
    fi
    sessions_json="${_tmp_sess}"
  fi

  local hour; hour="$(date +%H)"; hour="${hour#0}"; hour="${hour:-0}"
  local ask_window; if _in_ask_window "$hour"; then ask_window=1; else ask_window=0; fi

  local agent attached work_dir rig
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    attached="$(_session_field "$sessions_json" "$agent" attached)"
    if [ -z "$attached" ]; then
      log "SKIP ${agent}: no live session."
      continue
    fi
    if [ "$attached" = "True" ] || [ "$attached" = "true" ]; then
      log "SKIP ${agent}: human attached — never asked about, never closed."
      continue
    fi
    # ga-ego18: derive work_dir from the agent's OWN agent.toml, not from `gc
    # session list`'s JSON. Gate review found that field is not schema-
    # guaranteed on the live-controller API code path this command normally
    # takes (only the no-controller local fallback is documented to carry
    # it) -- crew-idle-check.sh's own _agent_work_dir reads the same
    # first-party source _layer1_crew_names already trusts for identity.
    work_dir="$(_agent_work_dir "$agent")"
    [ -n "$work_dir" ] || { log "SKIP ${agent}: no work_dir in agent.toml — cannot evaluate."; continue; }
    rig="$(_rig_path_for_work_dir "$work_dir")" || { log "SKIP ${agent}: could not derive rig path from ${work_dir}."; continue; }

    local report idle reasons
    report="$(crew_idle_report "$agent" "$agent" "$work_dir" "$rig" "$agent")"
    idle="$(printf '%s' "$report" | python3 -c 'import json,sys; print(json.load(sys.stdin)["idle"])' 2>/dev/null)"
    reasons="$(printf '%s' "$report" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["reasons"]))' 2>/dev/null)"

    if [ "$idle" != "True" ]; then
      log "NOT-IDLE ${agent}: ${reasons}"
      continue
    fi

    if [ "$ask_window" = "1" ]; then
      if _ask_rate_limited "$agent" "$RUN_DIR"; then
        log "RATE-LIMITED ${agent}: idle+EMERGENCY but asked within the last ${ASK_RATE_LIMIT_SECS}s — not re-asking yet."
      else
        _send_ask "$agent" "$work_dir" "$reasons"
        _stamp_ask "$agent" "$RUN_DIR"
      fi
    else
      _do_autoclose "$agent" "$work_dir" "$reasons"
    fi
  done < <(_layer1_crew_names)

  [ -n "$_tmp_sess" ] && rm -f "$_tmp_sess"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# selftest
# ════════════════════════════════════════════════════════════════════════════

if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }

  _ST_ROOT="$(mktemp -d /tmp/ccc-selftest.XXXXXX)"
  trap 'rm -rf "${_ST_ROOT}"' EXIT
  export CCC_LOG="${_ST_ROOT}/log" CCC_RUN_DIR="${_ST_ROOT}/run" CCC_NOTIFY=/nonexistent
  LOG="${CCC_LOG}"; RUN_DIR="${CCC_RUN_DIR}"; LOCK_FILE="${_ST_ROOT}/run/crew-capacity-containment.lock"

  echo "S1: _ram_pressure_level — mirrors pilot-dispatcher.sh's fail-open contract"
  _ST_RAM="${_ST_ROOT}/ram.level"
  printf 'EMERGENCY\n%s\n' "$(date +%s)" > "${_ST_RAM}"
  [ "$(RAM_LEVEL_FILE="${_ST_RAM}" _ram_pressure_level)" = "EMERGENCY" ] && ok "fresh EMERGENCY reading" || bad "should read EMERGENCY"
  printf 'WARN\n%s\n' "$(( $(date +%s) - 99999 ))" > "${_ST_RAM}"
  [ "$(RAM_LEVEL_FILE="${_ST_RAM}" _ram_pressure_level)" = "" ] && ok "stale reading -> empty (unreadable)" || bad "stale should be empty"
  [ "$(RAM_LEVEL_FILE=/nonexistent _ram_pressure_level)" = "" ] && ok "missing file -> empty" || bad "missing file should be empty"
  rm -f "${_ST_RAM}"

  echo "S2: _in_ask_window — hourly boundary (07:00-22:00 = ask; else = autoclose)"
  _in_ask_window 7 && ok "07 -> ask window (inclusive start)" || bad "07 should be in ask window"
  _in_ask_window 21 && ok "21 -> ask window" || bad "21 should be in ask window"
  _in_ask_window 22 && bad "22 should NOT be in ask window (exclusive end)" || ok "22 -> autoclose window"
  _in_ask_window 6 && bad "06 should NOT be in ask window" || ok "06 -> autoclose window"
  _in_ask_window 0 && bad "00 should NOT be in ask window" || ok "00 -> autoclose window"
  _in_ask_window "" && bad "empty hour should fail-closed to autoclose-window classification" || ok "empty hour -> not ask window"

  echo "S3: _ask_rate_limited + _stamp_ask"
  _ST_STAMPS="${_ST_ROOT}/stamps"; mkdir -p "${_ST_STAMPS}"
  _ask_rate_limited agentZ "${_ST_STAMPS}" && bad "no stamp yet should not be rate-limited" || ok "no prior stamp -> not rate-limited"
  ASK_RATE_LIMIT_SECS=14400 _stamp_ask agentZ "${_ST_STAMPS}"
  ASK_RATE_LIMIT_SECS=14400 _ask_rate_limited agentZ "${_ST_STAMPS}" && ok "just stamped -> rate-limited" || bad "should be rate-limited right after stamping"
  echo "$(( $(date +%s) - 99999 ))" > "${_ST_STAMPS}/crew-capacity-containment.ask.agentOld.stamp"
  ASK_RATE_LIMIT_SECS=14400 _ask_rate_limited agentOld "${_ST_STAMPS}" && bad "old stamp should have expired" || ok "old (>ratelimit) stamp -> not rate-limited"

  echo "S4: _session_field — reads gc-session-list-shaped JSON fixture"
  _ST_SESS="${_ST_ROOT}/sessions.json"
  cat > "${_ST_SESS}" <<'JSON'
[
  {"name": "oracle-wa", "template": "oracle-wa", "attached": true, "work_dir": "/x/whatsapp_automation/crew/oracle"},
  {"name": "mila-wa", "template": "mila-wa", "attached": false, "work_dir": "/x/whatsapp_automation/crew/mila"}
]
JSON
  [ "$(_session_field "${_ST_SESS}" oracle-wa attached)" = "True" ] && ok "oracle-wa attached=True read correctly" || bad "should read attached=True"
  [ "$(_session_field "${_ST_SESS}" mila-wa work_dir)" = "/x/whatsapp_automation/crew/mila" ] && ok "mila-wa work_dir read correctly" || bad "should read mila-wa's work_dir"
  _session_field "${_ST_SESS}" nosuchagent attached >/dev/null 2>&1 && bad "unknown agent should fail (no live session)" || ok "unknown agent -> not found (rc=1)"

  echo "S5: main() end-to-end — EMERGENCY, day window, idle crew -> asks, does not close"
  _ST_AGENTS5="${_ST_ROOT}/agents5"; mkdir -p "${_ST_AGENTS5}/testcrew"
  # work_dir MUST contain a "/crew/<non-worker>" segment — that's the live
  # signal _layer1_crew_names filters on (see crew-idle-check.sh header); a
  # fixture path without it is silently excluded, same as a real pool config.
  printf 'max_active_sessions = 1\nwork_dir = "%s/crew/testcrew"\n' "${_ST_ROOT}" > "${_ST_AGENTS5}/testcrew/agent.toml"
  mkdir -p "${_ST_ROOT}/crew/testcrew"
  ( cd "${_ST_ROOT}/crew/testcrew" && git init -q && git config user.email t@t.local && git config user.name t \
      && GIT_AUTHOR_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         GIT_COMMITTER_DATE="$(date -v-10H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d '10 hours ago' '+%Y-%m-%dT%H:%M:%S')" \
         git commit -q --allow-empty -m old )
  _ST_SESS5="${_ST_ROOT}/sessions5.json"
  printf '[{"name":"testcrew","template":"testcrew","attached":false,"work_dir":"%s/crew/testcrew"}]' "${_ST_ROOT}" > "${_ST_SESS5}"
  _ST_BD5="${_ST_ROOT}/mock-bd5"
  cat > "${_ST_BD5}" <<'MOCKBD5'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in source-bead:*) echo '[]'; exit 0 ;; esac; done
echo '[]'
MOCKBD5
  chmod +x "${_ST_BD5}"
  _s5_mail_marker="${_ST_ROOT}/s5-mail-called"
  rm -f "${_s5_mail_marker}"
  # NOTE: main()'s `gc session list` fetch runs under `timeout`, which execs a
  # real binary and cannot see a shell function override — so session data is
  # injected via CCC_SESSIONS_JSON_FILE (a supported override seam) instead of
  # trying to mock that call. The gc() function below only needs to intercept
  # the NOT-timeout-wrapped calls: `mail send` and `session close`.
  gc() {
    case "$1" in
      session) echo "S5-REGRESSION: session ${2:-} should not be called in ask window" >> "${_ST_ROOT}/s5-unexpected-close" ;;
      mail) touch "${_s5_mail_marker}" ;;
    esac
  }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5}" BD="${_ST_BD5}" CREW_IDLE_SESSION_OVERRIDE=idle \
    CCC_TEST_RAM_LEVEL=EMERGENCY CCC_ASK_WINDOW_START_HOUR=0 CCC_ASK_WINDOW_END_HOUR=24 \
    CCC_SESSIONS_JSON_FILE="${_ST_SESS5}" \
    main >/dev/null 2>&1
  [ -f "${_s5_mail_marker}" ] && ok "day window, idle crew -> mail sent (asked)" || bad "should have sent a mail asking"
  [ -f "${_ST_ROOT}/s5-unexpected-close" ] && bad "REGRESSION: session close called during ask window" || ok "session close NOT called during ask window"
  unset -f gc

  echo "S6: main() end-to-end — EMERGENCY, autoclose window, idle crew -> closes, does not just ask"
  _s6_kill_marker="${_ST_ROOT}/s6-kill-called"
  _s6_mail_marker="${_ST_ROOT}/s6-mail-called"
  rm -f "${_s6_kill_marker}" "${_s6_mail_marker}"
  gc() {
    case "$1" in
      session) [ "${2:-}" = "close" ] && { touch "${_s6_kill_marker}"; return 0; } ;;
      mail) touch "${_s6_mail_marker}" ;;
    esac
  }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5}" BD="${_ST_BD5}" CREW_IDLE_SESSION_OVERRIDE=idle \
    CCC_TEST_RAM_LEVEL=EMERGENCY CCC_ASK_WINDOW_START_HOUR=25 CCC_ASK_WINDOW_END_HOUR=26 \
    CCC_SESSIONS_JSON_FILE="${_ST_SESS5}" \
    main >/dev/null 2>&1
  [ -f "${_s6_kill_marker}" ] && ok "autoclose window, idle crew -> gc session close called" || bad "should have called session close"
  [ -f "${_s6_mail_marker}" ] && ok "autoclose still sends a durable mail record" || bad "autoclose should still mail (log+comentario requirement)"
  unset -f gc

  echo "S7: main() end-to-end — attached session is NEVER touched, ask or autoclose"
  _ST_SESS7="${_ST_ROOT}/sessions7.json"
  printf '[{"name":"testcrew","template":"testcrew","attached":true,"work_dir":"%s/crew/testcrew"}]' "${_ST_ROOT}" > "${_ST_SESS7}"
  _s7_marker="${_ST_ROOT}/s7-any-action"
  rm -f "${_s7_marker}"
  gc() {
    case "$1" in
      session) touch "${_s7_marker}" ;;
      mail) touch "${_s7_marker}" ;;
    esac
  }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5}" BD="${_ST_BD5}" CREW_IDLE_SESSION_OVERRIDE=idle \
    CCC_TEST_RAM_LEVEL=EMERGENCY CCC_ASK_WINDOW_START_HOUR=25 CCC_ASK_WINDOW_END_HOUR=26 \
    CCC_SESSIONS_JSON_FILE="${_ST_SESS7}" \
    main >/dev/null 2>&1
  [ -f "${_s7_marker}" ] && bad "REGRESSION: attached session was asked-about or closed" || ok "attached session -> zero action taken"
  unset -f gc

  echo "S8: main() end-to-end — level=OK -> no evaluation loop runs at all"
  _s8_marker="${_ST_ROOT}/s8-any-action"
  rm -f "${_s8_marker}"
  gc() { touch "${_s8_marker}"; }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5}" CCC_TEST_RAM_LEVEL=OK main >/dev/null 2>&1
  [ -f "${_s8_marker}" ] && bad "REGRESSION: gc was called even though pressure is OK" || ok "level=OK -> gc never invoked, immediate no-op"
  unset -f gc

  echo "S8b: main() end-to-end — evaluates a crew even when the session JSON carries NO work_dir key at all (ga-ego18)"
  # Simulates the exact schema the gate review described for the live-
  # controller API code path: a session row with no work_dir field
  # whatsoever (not just empty -- ABSENT), unlike every other fixture above
  # which bakes work_dir into the session JSON itself. Before this fix,
  # main() read work_dir via _session_field on this JSON and would SKIP the
  # crew here ("no work_dir -- cannot evaluate"), never asking or closing --
  # the exact silently-dead-feature shape the review was concerned about.
  #
  # Uses a DISTINCT agent identity ("testcrew2") rather than reusing
  # "testcrew" -- S5 already asked about "testcrew" and _ask_rate_limited's
  # 4h stamp (keyed by agent name, in the same shared RUN_DIR every S5-S10
  # section reuses) would otherwise make this hit the RATE-LIMITED branch
  # instead of ASK, which looks identical from the "no mail sent" outside
  # view and silently tests the wrong thing (caught by first running this
  # with a raw log dump instead of trusting the pass/fail alone). Points at
  # the SAME already-initialized git repo/work_dir S5 set up, since the
  # underlying idle-check reads by work_dir content, not by agent name.
  _ST_AGENTS5_2="${_ST_ROOT}/agents5-2"; mkdir -p "${_ST_AGENTS5_2}/testcrew2"
  printf 'max_active_sessions = 1\nwork_dir = "%s/crew/testcrew"\n' "${_ST_ROOT}" > "${_ST_AGENTS5_2}/testcrew2/agent.toml"
  _ST_SESS8B="${_ST_ROOT}/sessions8b.json"
  printf '[{"name":"testcrew2","template":"testcrew2","attached":false}]' > "${_ST_SESS8B}"
  _s8b_mail_marker="${_ST_ROOT}/s8b-mail-called"
  rm -f "${_s8b_mail_marker}"
  gc() { case "$1" in mail) touch "${_s8b_mail_marker}" ;; esac; }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5_2}" BD="${_ST_BD5}" CREW_IDLE_SESSION_OVERRIDE=idle \
    CCC_TEST_RAM_LEVEL=EMERGENCY CCC_ASK_WINDOW_START_HOUR=0 CCC_ASK_WINDOW_END_HOUR=24 \
    CCC_SESSIONS_JSON_FILE="${_ST_SESS8B}" \
    main >/dev/null 2>&1
  [ -f "${_s8b_mail_marker}" ] && ok "crew evaluated and asked about despite work_dir being ABSENT from session JSON (sourced from agent.toml instead)" \
    || bad "REGRESSION: crew was skipped -- work_dir dependency on session JSON is back"
  unset -f gc

  echo "S9: _acquire_lock / _release_lock — singleton-run protection (defense in depth, gate review ga-bjmp6)"
  _ST_LOCK="${_ST_ROOT}/s9.lock"
  rm -f "${_ST_LOCK}"
  _acquire_lock "${_ST_LOCK}" && ok "no existing lock -> acquired" || bad "should acquire a fresh lock"
  [ "$(cat "${_ST_LOCK}" 2>/dev/null)" = "$$" ] && ok "lock file stamped with our own PID" || bad "lock file should contain our PID"
  _acquire_lock "${_ST_LOCK}" && bad "a live-held lock (our own PID, definitely alive) should NOT be acquirable" || ok "lock held by a live PID -> acquire fails"
  _release_lock "${_ST_LOCK}"
  [ -f "${_ST_LOCK}" ] && bad "release should remove the lock file" || ok "release -> lock file removed"
  _acquire_lock "${_ST_LOCK}" && ok "after release -> acquirable again" || bad "should reacquire after release"
  _release_lock "${_ST_LOCK}"
  # Stale lock: a PID that has genuinely exited (not just "a big unlikely
  # number", which is flaky) -- reclaimed, not treated as still-held.
  ( sleep 0 ) & _st_dead_pid=$!
  wait "${_st_dead_pid}" 2>/dev/null
  echo "${_st_dead_pid}" > "${_ST_LOCK}"
  _acquire_lock "${_ST_LOCK}" && ok "stale lock (dead PID) -> reclaimed, not blocked" || bad "dead PID should not block acquisition"
  _release_lock "${_ST_LOCK}"
  echo "not-a-pid" > "${_ST_LOCK}"
  _acquire_lock "${_ST_LOCK}" && ok "garbage lock content -> treated as stale, reclaimed" || bad "unparseable pidfile should not block acquisition"
  _release_lock "${_ST_LOCK}"
  _acquire_lock "/nonexistent-dir-xyz/sub/lock" && bad "unwritable lock path should fail closed" || ok "unwritable lock path -> acquire fails safely"
  # A lock file that -f confirms exists but whose CONTENT cannot actually be
  # read (permission race, TOCTOU) must NOT be treated the same as a
  # confirmed-empty/garbage read -- that would silently reclaim a lock we
  # never actually confirmed was stale. Mode 200 (write-only, no read)
  # isolates exactly this: unlike 000, it does NOT also block the reclaim
  # write, so a test relying on return-code-alone would pass for the WRONG
  # reason under the old (buggy) code too (both the read AND the writeback
  # would fail under 000, "fail closed" by accident of a second unrelated
  # permission failure, not because the fix's read/write distinction fired).
  # Skipped when running as root (uid 0 ignores unix file permissions).
  if [ "$(id -u)" != "0" ]; then
    echo "12345" > "${_ST_LOCK}"
    chmod 200 "${_ST_LOCK}"
    _acquire_lock "${_ST_LOCK}"
    _st_acquire_rc=$?
    chmod 644 "${_ST_LOCK}" 2>/dev/null
    _st_lock_content="$(cat "${_ST_LOCK}" 2>/dev/null)"
    [ "$_st_acquire_rc" -ne 0 ] && ok "existing lock file we cannot read -> acquire fails closed (rc=${_st_acquire_rc})" \
      || bad "unreadable-but-existing lock file should fail closed, not reclaim (rc=${_st_acquire_rc})"
    [ "$_st_lock_content" = "12345" ] && ok "lock content left untouched -> confirmed no silent reclaim happened" \
      || bad "REGRESSION: lock content changed to '${_st_lock_content}' -- reclaimed despite unreadable original"
    rm -f "${_ST_LOCK}"
  else
    log "S9: skipping unreadable-lock-file case — running as root, chmod has no effect"
  fi

  echo "S10: main() end-to-end — held lock skips evaluation entirely, even with an idle crew under EMERGENCY"
  echo "$$" > "${LOCK_FILE}"
  _s10_marker="${_ST_ROOT}/s10-any-action"
  rm -f "${_s10_marker}"
  gc() { touch "${_s10_marker}"; }
  CREW_IDLE_AGENTS_DIR="${_ST_AGENTS5}" BD="${_ST_BD5}" CREW_IDLE_SESSION_OVERRIDE=idle \
    CCC_TEST_RAM_LEVEL=EMERGENCY CCC_ASK_WINDOW_START_HOUR=0 CCC_ASK_WINDOW_END_HOUR=24 \
    CCC_SESSIONS_JSON_FILE="${_ST_SESS5}" \
    main >/dev/null 2>&1
  [ -f "${_s10_marker}" ] && bad "REGRESSION: gc was called despite an already-held lock" || ok "held lock -> main() skips this cycle entirely, no gc calls"
  unset -f gc
  rm -f "${LOCK_FILE}"

  echo ""; echo "crew-capacity-containment selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

if [ "${CCC_LIB:-0}" != "1" ] && [ "${1:-}" != "--selftest" ]; then
  main "$@"
fi
