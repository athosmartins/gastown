#!/usr/bin/env bash
# pre-gate-review.sh — the builder rehearses the gate review on its own diff before /gate-done (ga-gnr3tw).
#
# E3 of the P0 ga-ufskhy (gate first-attempt approval fell to ~41%). Measured (E0, ga-5vi6cp): the drop is mostly
# the REVIEWER gaining recall — 7 of 10 re-judged diffs had a real behaviour defect, 0 of 10 were unfounded — so
# the rigor stays and the lever is the quality of what reaches the gate. ~48% of FAILs are edge cases / error≡empty /
# a third state, ~20% a comment promising more than the code, ~10% a test that never exercises the path: classes a
# builder can catch itself IF it looks with the reviewer's own eyes. This script gives it those eyes: it renders the
# SAME task the gate renders (gate-review-task.lib.sh, one source), runs it through `claude -p` with the gate-reviewer
# model and effort read from the live agent.toml / city.toml, and reports a verdict. It writes NOTHING to the gate:
# no marker, no verdict bead, no bd call.
#
# A/B (the reason `--bead` exists): the step is switched on for half the beads, by a deterministic hash of the bead id
# (pregate_arm_for_bead below — auditable, recomputable, not chosen by the builder). `run <branch> --bead <id>`
# on a control-arm bead prints SKIPPED and exits 0 without spending anything. Every assignment and every run is
# appended to <city>/.gc/logs/pre-gate-review/runs.jsonl for pre-gate-apuracao.sh, which reports approval on x off.
#
# THREE outcomes, never two (a check that cannot run must not read as a check that passed):
#   exit 0   PASS         no blocking defect found       (also: SKIPPED — control arm, or the per-bead run cap)
#   exit 10  FAIL         blocking defect(s) — printed; fix, commit, re-run (the cap is PRE_GATE_MAX_RUNS runs per bead)
#   exit 3   INCONCLUSIVE could not judge (machine guard, busy, timeout, no verdict line, dirty tree, ...) —
#                         reason printed. The builder submits anyway: an unavailable rehearsal is not a verdict.
#   exit 2   usage error
# Every `run` that gets past argument parsing ends its stdout with one machine-readable line (a usage error, exit 2,
# prints only usage on stderr):  PREGATE_RESULT arm=.. verdict=.. reason=.. attempt=.. record=..
#
# Usage:
#   pre-gate-review.sh [run] <branch> [--bead <id>] [--base <ref>] [--head <ref>] [--lens N] [--force]
#                                     [--no-fetch] [--dry-run] [--print-task]
#   pre-gate-review.sh arm <bead-id>          prints "on" or "off" (pure; no side effects)
#   pre-gate-review.sh roster <bead-id> <branch>   /gate-done Step 3: records the assignment, prints "on" or "off"
# Run it from inside the builder's checkout, with HEAD on the branch under review and a clean tree.
# The file can also be `source`d (the functions are reused by pre-gate-apuracao.sh and the selftest).
#
# Knobs (env): PRE_GATE_MODEL / PRE_GATE_EFFORT (override the live gate-reviewer config; recorded as such),
#   PRE_GATE_MAX_USD (3)  PRE_GATE_TIMEOUT_SECS (1500)  PRE_GATE_MAX_RUNS (3)  PRE_GATE_MAX_CONCURRENT (2)
#   PRE_GATE_MIN_DF_GIB (10)  PRE_GATE_MIN_SWAP_MB (300)  PRE_GATE_MIN_SYSTEM_CHARS (10000)
#   PRE_GATE_LOG_DIR  PRE_GATE_CITY  PRE_GATE_CLAUDE_BIN  GATE_DIFF_LINE_BUDGET (2000, same tunable as the gate)

set -uo pipefail   # deliberately NOT -e: every failing step is a named outcome below, never a silent abort

PG_SELF="${BASH_SOURCE[0]}"
PG_DIR="$(cd "$(dirname "$PG_SELF")" && pwd)"

# The shared render. Missing lib = nothing to render = INCONCLUSIVE at run time (checked in pg_run), not a crash here,
# so `arm` and sourcing still work on a partial checkout.
if [ -r "$PG_DIR/gate-review-task.lib.sh" ]; then
  # shellcheck source=gate-review-task.lib.sh
  source "$PG_DIR/gate-review-task.lib.sh"
fi

pg_log() { echo "[pre-gate-review] $*" >&2; }
pg_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── A/B arm ───────────────────────────────────────────────────────────────────────────────────────────────
# pregate_arm_for_bead <bead-id> — prints "on" or "off". Deterministic, recomputable by anyone:
#   on  <=>  the first 32 bits of SHA-256("pregate:<bead-id>") are even.
#   e.g.  printf '%s' "pregate:ga-abc123" | shasum -a 256 | cut -c1-8   (an even last hex digit means on)
# WHY SHA-256 and not the guard's 31-polynomial hash (even salted): ga-rstae already splits beads by that polynomial's
# parity (arm B gets the base-commit test check). Salting it does NOT decorrelate it — its parity is decided by how often
# the running value wraps modulo 100000007, which a prefix barely changes. Measured on 1220 real bead ids (2026-09-30):
# the salted-polynomial arm agreed with the ga-rstae arm on 43% (cells 347/286/238/349, chi-square ~28) — enough that
# "pre-gate on" and "base-test check on" would have been partly the same beads and the approval-rate difference could
# not have been attributed to either. SHA-256 shares no arithmetic with it.
#   Empty id      → prints nothing, returns 2: a bead we cannot identify has no arm, and "no arm" must not read as "off".
#   No sha tool   → prints nothing, returns 3: same reason; the caller skips the step and says so.
pregate_arm_for_bead() {
  local bead="${1:-}" tool digest="" first
  [ -z "$bead" ] && return 2
  # Fast C tools first: shasum is a perl script (~0.1s a call under load) and the apuracao asks for hundreds of arms.
  # They all compute the same standard digest; pre-gate-review.selftest.sh asserts the installed ones agree.
  for tool in "sha256sum" "openssl dgst -sha256 -r" "shasum -a 256"; do
    command -v "${tool%% *}" >/dev/null 2>&1 || continue
    digest="$(printf '%s' "pregate:$bead" | $tool 2>/dev/null | cut -c1-8)"
    case "$digest" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) break ;;
      *) digest="" ;;
    esac
  done
  [ -n "$digest" ] || return 3
  first=$(( 16#$digest ))
  if (( first % 2 == 0 )); then printf 'on'; else printf 'off'; fi
}

# ── paths / records ─────────────────────────────────────────────────────────────────────────────────────────
pg_city() {
  local c="${PRE_GATE_CITY:-${GC_CITY_PATH:-$PG_DIR/../../..}}"
  (cd "$c" 2>/dev/null && pwd) || printf '%s' "$c"
}
pg_log_dir() { printf '%s' "${PRE_GATE_LOG_DIR:-$(pg_city)/.gc/logs/pre-gate-review}"; }

PG_PY=""
pg_python() {
  # Needs tomllib (3.11+). Ask each candidate instead of assuming PATH's python3 has it.
  # PG_PY caches the answer for the run: pg_run_inner sets it once at top level, and every `$(pg_python)` subshell after
  # that inherits it (a probe is a full interpreter start, and a run makes about a dozen of these calls).
  local p
  [ -n "$PG_PY" ] && { printf '%s' "$PG_PY"; return 0; }
  for p in "${PRE_GATE_PYTHON:-}" python3 /opt/homebrew/bin/python3; do
    [ -z "$p" ] && continue
    if "$p" -c 'import tomllib' >/dev/null 2>&1; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# pg_record <event> key=value ... — append one JSON line to runs.jsonl. Values are strings except the numeric keys.
# Returns non-zero (and says so on stderr) if the record could not be written: the caller reports it, because a run
# that left no record is invisible to the measurement and must not look like a run that was never made.
PG_RECORD_FILE=""
pg_record() {
  local dir file py
  dir="$(pg_log_dir)"; file="$dir/runs.jsonl"
  py="$(pg_python)" || py="python3"
  mkdir -p "$dir" 2>/dev/null || { pg_log "WARN: cannot create $dir — record NOT written"; return 1; }
  "$py" - "$file" "$@" <<'PY' || { pg_log "WARN: record NOT written to $file"; return 1; }
import json, sys, time
path, event, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
NUM = {"attempt", "cost_usd", "turns", "duration_s", "task_bytes", "diff_lines", "exit_code", "prior_runs"}
BOOL = {"launched", "partial", "forced"}
d = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event}
for p in pairs:
    k, _, v = p.partition("=")
    if k in NUM:
        try:
            v = float(v) if "." in v else int(v)
        except ValueError:
            pass
    elif k in BOOL:
        v = (v == "true")
    d[k] = v
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(d, ensure_ascii=False, sort_keys=True) + "\n")
PY
  PG_RECORD_FILE="$file"
}

# pg_prior_runs <bead-or-branch-key> <field> — how many runs that actually launched claude were already made for it.
# A corrupt line is skipped, not fatal: the cap is a brake, not a ledger.
pg_prior_runs() {
  # No file yet = no run has ever been recorded = 0 (true). A file that EXISTS but cannot be read is a different thing:
  # we cannot know how much was already spent, and "0" would silently lift the per-bead cap on a spending path. That
  # case returns 1 with nothing printed and the caller refuses to launch.
  local file py
  file="$(pg_log_dir)/runs.jsonl"
  [ -e "$file" ] || { printf '0'; return 0; }
  [ -r "$file" ] || return 1
  py="$(pg_python)" || py="python3"
  "$py" - "$file" "$1" "$2" <<'PY' 2>/dev/null || return 1
import json, sys
path, key, field = sys.argv[1:4]
n = 0
for line in open(path, encoding="utf-8", errors="replace"):
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("event") == "run" and r.get("launched") is True and r.get(field) == key:
        n += 1
print(n)
PY
}

# ── machine guard (the E0 guard: never add a heavy job to a machine already short of disk/swap) ──────────────
pg_df_avail_gib() { df -Pk / 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ { printf "%d", $4 / 1048576 }'; }
# prints "<total_mb> <free_mb>" (macOS vm.swapusage), nothing if unreadable
pg_swap_mb() {
  # macOS prints e.g. "total = 6144.00M  used = 5259.19M  free = 884.81M  (encrypted)"; be ready for a K or G suffix too.
  sysctl -n vm.swapusage 2>/dev/null | awk '
    function mb(v,   u, n) { u = substr(v, length(v)); n = substr(v, 1, length(v) - 1) + 0
      if (u == "G") return n * 1024; if (u == "M") return n; if (u == "K") return n / 1024; return -1 }
    { for (i = 1; i <= NF; i++) { if ($i == "total") t = $(i + 2); if ($i == "free") f = $(i + 2) }
      if (t != "" && f != "" && mb(t) >= 0 && mb(f) >= 0) printf "%d %d", mb(t), mb(f) }'
}
# pg_machine_guard — returns 0 when it is fine to launch; otherwise prints the reason on stdout and returns 1.
# Unreadable is refusal: this guard exists to keep load OFF a struggling machine, so "cannot tell" is the inert answer.
pg_machine_guard() {
  local min_df="${PRE_GATE_MIN_DF_GIB:-10}" min_swap="${PRE_GATE_MIN_SWAP_MB:-300}" df_gib swap total free
  df_gib="$(pg_df_avail_gib)"
  if [ -z "$df_gib" ]; then echo "df-unreadable"; return 1; fi
  if [ "$df_gib" -lt "$min_df" ]; then echo "disk-low:${df_gib}GiB<${min_df}GiB"; return 1; fi
  swap="$(pg_swap_mb)"
  if [ -z "$swap" ]; then echo "swap-unreadable"; return 1; fi
  total="${swap%% *}"; free="${swap##* }"
  # total=0 means macOS has not allocated any swap yet: no swap pressure, so there is no floor to hold.
  if [ "$total" -gt 0 ] && [ "$free" -lt "$min_swap" ]; then echo "swap-low:${free}MB<${min_swap}MB"; return 1; fi
  return 0
}

# ── concurrency slots (each run is a multi-minute xhigh session on a machine that saturates) ───────────────
PG_SLOT_DIR=""
pg_slot_acquire() {
  local max="${PRE_GATE_MAX_CONCURRENT:-2}" root n pid
  root="$(pg_log_dir)/slots"
  mkdir -p "$root" 2>/dev/null || return 1
  n=1
  while [ "$n" -le "$max" ]; do
    if mkdir "$root/$n" 2>/dev/null; then echo $$ > "$root/$n/pid"; PG_SLOT_DIR="$root/$n"; return 0; fi
    pid="$(cat "$root/$n/pid" 2>/dev/null || true)"
    # A slot whose owner is gone (crash, kill -9) is reclaimed; an unreadable pid file counts as held.
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$root/$n/pid" 2>/dev/null; rmdir "$root/$n" 2>/dev/null
      if mkdir "$root/$n" 2>/dev/null; then echo $$ > "$root/$n/pid"; PG_SLOT_DIR="$root/$n"; return 0; fi
    fi
    n=$((n + 1))
  done
  return 1
}
pg_slot_release() {
  [ -n "$PG_SLOT_DIR" ] || return 0
  rm -f "$PG_SLOT_DIR/pid" 2>/dev/null; rmdir "$PG_SLOT_DIR" 2>/dev/null
  PG_SLOT_DIR=""
}

# ── live reviewer config ──────────────────────────────────────────────────────────────────────────────────
# pg_reviewer_config — prints "<model> <effort> <source>" from the LIVE files (agents/gate-reviewer/agent.toml for the model,
# city.toml patches.agent for the effort, agent.toml option_defaults as fallback). Empty + non-zero if either is unresolved:
# guessing a model would review with a different reviewer than the gate's and make the A/B measure nothing.
pg_reviewer_config() {
  local city py
  city="$(pg_city)"
  if [ -n "${PRE_GATE_MODEL:-}" ] && [ -n "${PRE_GATE_EFFORT:-}" ]; then
    printf '%s %s env' "$PRE_GATE_MODEL" "$PRE_GATE_EFFORT"; return 0
  fi
  py="$(pg_python)" || return 1
  "$py" - "$city" "${PRE_GATE_MODEL:-}" "${PRE_GATE_EFFORT:-}" <<'PY'
import sys, tomllib
city, model_env, effort_env = sys.argv[1:4]
try:
    agent = tomllib.load(open(f"{city}/agents/gate-reviewer/agent.toml", "rb"))
    cityc = tomllib.load(open(f"{city}/city.toml", "rb"))
except Exception:
    sys.exit(1)
model = model_env or agent.get("model") or ""
effort = effort_env or ""
if not effort:
    for p in (cityc.get("patches", {}) or {}).get("agent", []) or []:
        if p.get("name") == "gate-reviewer" and (p.get("dir", "") or "") == "":
            effort = (p.get("option_defaults") or {}).get("effort", "") or effort
    effort = effort or (agent.get("option_defaults") or {}).get("effort", "") or ""
if not model or not effort:
    sys.exit(1)
src = "env+live" if (model_env or effort_env) else "live"
print(f"{model} {effort} {src}", end="")
PY
}

# ── the reviewer's system prompt (the live `gc prime gate-reviewer` + a pre-gate override) ────────────────────
PG_SYSTEM_OVERRIDE='

---
## PRE-GATE SELF-REVIEW OVERRIDE (highest priority: supersedes everything above wherever they conflict)

This is a builder rehearsal of the gate review, run on the branch the builder wrote BEFORE it is submitted to the gate.
It is not a live gate run and nothing you decide here is recorded anywhere.

- There is NO verdict bead, NO dispatcher and NO other reviewer. Ignore the Startup Protocol polling, every gc and bd
  command, drain-ack, and every instruction to record the verdict in a bead. Those tools are unavailable here.
- Your review task is in the user message. Do not poll or wait for a nudge.
- Deliver the verdict as the FINAL TEXT of your last message, in the exact format the task asks for, then stop.
- The repository checkout in your current working directory IS the branch under review, at the Branch SHA named in the
  task. Review that checkout. Other checkouts of this repository on this machine are at other states and out of scope.
- You are read-only: you cannot edit, write or delete files, and there is no network access. Reading files and running
  read-only git commands is fine.
- Review exactly as the gate reviewer would: same lens, same bar, same rigor. A softer review here only teaches the
  builder the wrong thing about what the gate will say.
'

# pg_system_prompt <outfile> — writes the full system prompt (live `gc prime gate-reviewer` + the override) to <outfile>.
#   Returns 0 on success, else 1 (gc failed), 2 (wrong role) or 3 (too short) and writes nothing.
#   WHY the role check and not just a size floor: when `gc prime <role>` cannot resolve the city (no GC_CITY_PATH and a cwd
#   outside it, or a worktree copy without .gc) it EXITS 0 and prints a generic "# Gas City Agent" fallback prompt — 2.9 KB,
#   valid-looking, the wrong role. Any size floor low enough to survive a slimmed reviewer prompt would accept it, and the
#   builder would rehearse under the wrong prompt without a word. So the city is passed explicitly (--city) and the output
#   must open with the reviewer's own heading. Measured 2026-09-30: real = 61.5 KB "# Gate Reviewer"; fallback = 2.9 KB.
pg_system_prompt() {
  local outfile="$1" out min="${PRE_GATE_MIN_SYSTEM_CHARS:-10000}" first
  # Strip the caller's own agent identity: `gc prime <role>` must describe the ROLE, not whoever runs this script.
  out="$(env -u GC_SESSION_NAME -u GC_ALIAS -u GC_AGENT -u GC_SESSION_ID -u GC_TEMPLATE -u GC_SESSION_ORIGIN \
           -u BEADS_ACTOR -u BD_ACTOR -u BEADS_DIR gc --city "$(pg_city)" prime gate-reviewer 2>/dev/null)" || return 1
  first="$(printf '%s\n' "$out" | head -n 1)"
  case "$first" in "# Gate Reviewer"*) ;; *) return 2 ;; esac
  [ "${#out}" -ge "$min" ] || return 3
  printf '%s%s' "$out" "$PG_SYSTEM_OVERRIDE" > "$outfile"
}

# pg_settings_file <out> <repo> — the live gate-reviewer settings (deny list, memory/skills/plugins off) minus hooks,
# plus read-only denies and the repo CLAUDE.md excludes. Prints "live" or "fallback" (visible in the record).
pg_settings_file() {
  local out="$1" repo="$2" city py
  city="$(pg_city)"; py="$(pg_python)" || py="python3"
  "$py" - "$city/.gc/agents/gate-reviewer/.claude/settings.json" "$out" "$repo" <<'PY'
import json, sys
src, out, repo = sys.argv[1:4]
try:
    s = json.load(open(src)); kind = "live"
except Exception:
    s = {"autoMemoryEnabled": False, "remoteControlAtStartup": False}; kind = "fallback"
s.pop("hooks", None)   # guard/telemetry hooks write under ~/.gastown; they never shape a verdict
s["claudeMdExcludes"] = list(s.get("claudeMdExcludes", [])) + [f"{repo}/CLAUDE.md", f"{repo}/AGENTS.md", f"{repo}/**/CLAUDE.md", f"{repo}/**/AGENTS.md"]
deny = list((s.setdefault("permissions", {})).get("deny", []))
for t in ("Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Agent"):
    if t not in deny:
        deny.append(t)
s["permissions"]["deny"] = deny
json.dump(s, open(out, "w"), indent=1)
print(kind, end="")
PY
}

# ── run claude under a wall-clock limit ───────────────────────────────────────────────────────────────────────
# pg_with_timeout <secs> <cmd...> — exit 124 means it timed out; 127 means there is no way to bound it (then we do not run it).
pg_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout --kill-after=30 "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout --kill-after=30 "$secs" "$@"; return $?; fi
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
    local rc=$?
    [ "$rc" -eq 142 ] && rc=124   # SIGALRM
    return "$rc"
  fi
  return 127
}

# pg_parse_stream <stream.jsonl> <review-text-out> — prints KEY=VALUE lines: RESULT, VERDICT, COST, TURNS, MODELS, SUBTYPE, ISERR.
# VERDICT is the LAST line that starts with "VERDICT: PASS|FAIL" in the final result text; NONE if there is none.
pg_parse_stream() {
  local py; py="$(pg_python)" || py="python3"
  "$py" - "$1" "$2" <<'PY'
import json, re, sys
stream, outtxt = sys.argv[1:3]
res, models = None, set()
try:
    for line in open(stream, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "result":
            res = ev
        elif ev.get("type") == "system" and ev.get("subtype") == "init" and ev.get("model"):
            models.add(ev["model"])
except OSError:
    pass
if res is None:
    print("RESULT=none"); sys.exit(0)
for m in (res.get("modelUsage") or {}):
    models.add(m)
text = res.get("result") or ""
open(outtxt, "w", encoding="utf-8").write(text)
verdict = "NONE"
for m in re.finditer(r"^VERDICT:\s*(PASS|FAIL)\b", text, re.M):
    verdict = m.group(1)
print("RESULT=present")
print(f"VERDICT={verdict}")
print(f"COST={res.get('total_cost_usd', '')}")
print(f"TURNS={res.get('num_turns', '')}")
print(f"MODELS={','.join(sorted(models))}")
print(f"SUBTYPE={res.get('subtype', '')}")
print(f"ISERR={'true' if res.get('is_error') else 'false'}")
PY
}

# ── result reporting ────────────────────────────────────────────────────────────────────────────────────────
PG_ARM="manual"; PG_ATTEMPT="0"; PG_WORK=""
# pg_finish <verdict> <reason> <exit-code> — the one exit path: prints the machine line and returns the code.
pg_finish() {
  printf 'PREGATE_RESULT arm=%s verdict=%s reason=%s attempt=%s record=%s\n' \
    "$PG_ARM" "$1" "${2:-none}" "$PG_ATTEMPT" "${PG_RECORD_FILE:-none}"
  return "$3"
}

pg_usage() {
  sed -n '/^# Usage:/,/^# Run it from/p' "$PG_SELF" | sed 's/^# \{0,1\}//' >&2
}

# pg_cleanup — release the slot and remove the scratch dir. Idempotent; also runs from the EXIT trap in script mode.
pg_cleanup() {
  pg_slot_release
  if [ -n "$PG_WORK" ] && [ -d "$PG_WORK" ]; then rm -rf "$PG_WORK"; fi
  PG_WORK=""
}

# ── main: run ───────────────────────────────────────────────────────────────────────────────────────────────
pg_run() {
  local rc
  pg_run_inner "$@"; rc=$?
  pg_cleanup
  return "$rc"
}

pg_run_inner() {
  local branch="" bead="" bead_given=0 base="" head="" lens="1" force=0 fetch=1 dry=0 printtask=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --bead)       bead="${2:-}"; bead_given=1; shift 2 || break ;;
      --base)       base="${2:-}"; shift 2 || break ;;
      --head)       head="${2:-}"; shift 2 || break ;;
      --lens)       lens="${2:-}"; shift 2 || break ;;
      --force)      force=1; shift ;;
      --no-fetch)   fetch=0; shift ;;
      --dry-run)    dry=1; shift ;;
      --print-task) printtask=1; dry=1; shift ;;
      -h|--help)    pg_usage; return 2 ;;
      -*)           pg_log "unknown option: $1"; pg_usage; return 2 ;;
      *)            if [ -z "$branch" ]; then branch="$1"; shift; else pg_log "unexpected argument: $1"; pg_usage; return 2; fi ;;
    esac
  done
  [ -n "$branch" ] || { pg_log "missing <branch>"; pg_usage; return 2; }
  PG_PY="$(pg_python)" || PG_PY=""
  case "$lens" in 1|2|3) ;; *) pg_log "--lens must be 1, 2 or 3"; return 2 ;; esac
  # `--bead ""` is what an unset shell variable produces. Reading it as "no bead" would silently switch to manual mode,
  # which ALWAYS runs and sits outside the A/B — an unknown input answered like a valid one. Refuse it instead.
  if [ "$bead_given" -eq 1 ] && [ -z "$bead" ]; then pg_log "--bead was given an empty id (unset variable?) — refusing"; return 2; fi

  local repo sha ts key keyfield
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || { pg_log "not inside a git checkout"; return 2; }
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"

  # ── arm ──
  if [ -n "$bead" ]; then
    local arm_rc
    PG_ARM="$(pregate_arm_for_bead "$bead")"; arm_rc=$?
    if [ "$arm_rc" -ne 0 ]; then
      # No sha256 tool: the bead has no arm. Not "off" (that would silently join the control) and not "on" (that would run
      # unassigned): say so, spend nothing, and leave it out of the roster.
      PG_ARM="unknown"
      pg_log "cannot assign an arm to bead '$bead' (no sha256 tool) — not running, not on the roster"
      pg_finish INCONCLUSIVE arm-unavailable 3; return $?
    fi
    key="$bead"; keyfield="bead"
  else
    PG_ARM="manual"; key="$branch"; keyfield="branch"
  fi
  # The roster of who was assigned what, kept apart from the runs: the apuracao needs the control arm too, and a
  # control bead never produces a run. Dry runs assign nothing.
  if [ -n "$bead" ] && [ "$dry" -eq 0 ]; then
    pg_record assign bead="$bead" branch="$branch" sha="$sha" arm="$PG_ARM" >/dev/null || pg_log "WARN: assignment for $bead not recorded"
  fi
  if [ "$PG_ARM" = "off" ] && [ "$force" -eq 0 ]; then
    pg_log "bead $bead is in the control arm (pregate:off) — not running"
    pg_finish SKIPPED control-arm 0; return $?
  fi

  # inconclusive(<reason>) — record + report. Nothing was spent unless the caller passes launched=true.
  local _inc_extra=""
  pg_inconclusive() {
    local reason="$1"
    [ "$dry" -eq 0 ] && { pg_record run bead="$bead" branch="$branch" sha="$sha" arm="$PG_ARM" attempt="$PG_ATTEMPT" verdict=INCONCLUSIVE reason="$reason" launched=false $_inc_extra >/dev/null || true; }
    pg_log "INCONCLUSIVE: $reason"
    pg_finish INCONCLUSIVE "$reason" 3
  }

  # ── per-bead cap ──
  local prior
  prior="$(pg_prior_runs "$key" "$keyfield")" || { pg_inconclusive "runs-log-unreadable"; return $?; }
  PG_ATTEMPT=$((prior + 1))
  if [ "$prior" -ge "${PRE_GATE_MAX_RUNS:-3}" ] && [ "$force" -eq 0 ]; then
    pg_log "already ran $prior time(s) for $key (cap ${PRE_GATE_MAX_RUNS:-3}) — submit to the gate"
    [ "$dry" -eq 0 ] && { pg_record run bead="$bead" branch="$branch" sha="$sha" arm="$PG_ARM" attempt="$PG_ATTEMPT" verdict=SKIPPED reason=max-runs launched=false >/dev/null || true; }
    pg_finish SKIPPED max-runs 0; return $?
  fi

  command -v git >/dev/null 2>&1 || { pg_inconclusive no-git; return $?; }
  type gate_render_review_task >/dev/null 2>&1 || { pg_inconclusive "prompt-lib-missing"; return $?; }

  # ── guards ──
  local g
  if [ "$dry" -eq 0 ]; then
    g="$(pg_machine_guard)" || { pg_inconclusive "machine-guard:$g"; return $?; }
  fi

  # ── refs ──
  local base_ref head_ref fetch_state="skipped"
  if [ "$fetch" -eq 1 ]; then
    if pg_with_timeout 60 git -C "$repo" fetch --quiet origin >/dev/null 2>&1; then fetch_state="ok"; else fetch_state="failed"; pg_log "WARN: git fetch origin failed — reviewing against the local view of origin"; fi
  fi
  base_ref="${base:-$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)}"
  git -C "$repo" rev-parse --verify -q "$base_ref^{commit}" >/dev/null 2>&1 || { pg_inconclusive "base-unresolved:$base_ref"; return $?; }
  if [ -n "$head" ]; then head_ref="$head"
  elif git -C "$repo" rev-parse --verify -q "refs/heads/$branch^{commit}" >/dev/null 2>&1; then head_ref="$branch"
  else head_ref="origin/$branch"; fi
  local branch_sha; branch_sha="$(git -C "$repo" rev-parse --verify -q "$head_ref^{commit}" 2>/dev/null)" || { pg_inconclusive "head-unresolved:$head_ref"; return $?; }
  # The reviewer is told the checkout in its cwd IS the branch under review; make that true or do not run.
  [ "$branch_sha" = "$sha" ] || { pg_inconclusive "head-not-at-branch:HEAD=${sha:0:9},branch=${branch_sha:0:9}"; return $?; }
  if [ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]; then pg_inconclusive "dirty-worktree"; return $?; fi

  # ── the inputs the gate renders ──
  local changed_files file_count summary escape lines
  changed_files="$(git -C "$repo" diff --name-only "$base_ref...$head_ref" 2>/dev/null)" || { pg_inconclusive "diff-failed"; return $?; }
  file_count="$(printf '%s\n' "$changed_files" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$file_count" -gt 0 ] || { pg_inconclusive "empty-diff"; return $?; }
  gitc() { git -C "$repo" "$@"; }
  summary="$(gate_diff_summary gitc "$base_ref" "$head_ref")"
  escape="cd $repo && git diff $base_ref...$head_ref"
  gate_build_diff_payload gitc "$base_ref" "$head_ref" "$changed_files" "$file_count" "${GATE_DIFF_LINE_BUDGET:-2000}" "$escape"
  lines="$DIFF_RAW_TOTAL_LINES"
  local partial=false; case "$DIFF_HEADER" in PARTIAL*) partial=true ;; esac

  local author rig lens_text task
  author="${PRE_GATE_AUTHOR:-${GC_ALIAS:-${GC_AGENT:-$(git -C "$repo" config user.name 2>/dev/null)}}}"; author="${author:-unknown}"
  rig="${PRE_GATE_RIG:-$(basename "$repo")}"
  lens_text="$(gate_reviewer_lens "$lens")"
  task="$(gate_render_review_task "$lens" 1 "$branch" "$author" "$rig" "$branch_sha" "$lens_text" "$changed_files" "$summary" \
            "$DIFF_HEADER" "$DIFF_FULL" "" "" text)" || { pg_inconclusive "render-failed"; return $?; }

  if [ "$printtask" -eq 1 ]; then printf '%s\n' "$task"; pg_finish DRYRUN print-task 0; return $?; fi

  # ── reviewer identity: live model/effort, system prompt, settings ──
  local cfg model effort cfg_src
  cfg="$(pg_reviewer_config)" || { pg_inconclusive "reviewer-config-unresolved"; return $?; }
  read -r model effort cfg_src <<<"$cfg"
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/pre-gate-review.XXXXXX")" || { pg_inconclusive "no-tmpdir"; return $?; }
  PG_WORK="$work"   # removed by pg_run / pg_cleanup — never by a RETURN trap, which bash leaves armed after the function returns
  local sys_rc system
  pg_system_prompt "$work/system.txt"; sys_rc=$?
  case "$sys_rc" in
    0) ;;
    1) pg_inconclusive "system-prompt-unavailable:gc-prime-failed"; return $? ;;
    2) pg_inconclusive "system-prompt-unavailable:wrong-role (gc prime did not return the Gate Reviewer prompt — city unresolved?)"; return $? ;;
    *) pg_inconclusive "system-prompt-unavailable:too-short"; return $? ;;
  esac
  system="$(cat "$work/system.txt")"
  local settings_kind; settings_kind="$(pg_settings_file "$work/settings.json" "$repo")" || { pg_inconclusive "settings-unwritable"; return $?; }
  printf '%s' "$task" > "$work/task.txt"

  local max_usd="${PRE_GATE_MAX_USD:-3}" tmo="${PRE_GATE_TIMEOUT_SECS:-1500}" bin="${PRE_GATE_CLAUDE_BIN:-claude}"
  command -v "$bin" >/dev/null 2>&1 || { pg_inconclusive "claude-not-found"; return $?; }
  local allow="Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git blame:*),Bash(git grep:*),Bash(git ls-files:*),Bash(git cat-file:*),Bash(git rev-parse:*),Bash(git status:*)"
  local -a cmd
  cmd=(nice -n 15 env -u GC_SESSION_NAME -u GC_ALIAS -u GC_AGENT -u GC_SESSION_ID -u GC_TEMPLATE -u GC_CITY_PATH
       -u BEADS_DOLT_SERVER_PORT -u BEADS_ACTOR -u BD_ACTOR -u BEADS_DIR
       "$bin" -p --model "$model" --effort "$effort" --output-format stream-json --verbose
       --no-session-persistence --strict-mcp-config --setting-sources "" --settings "$work/settings.json"
       --append-system-prompt "$system" --permission-mode dontAsk --tools "Read,Grep,Glob,Bash"
       --allowedTools "$allow" --max-budget-usd "$max_usd")

  if [ "$dry" -eq 1 ]; then
    printf 'PREGATE_DRYRUN model=%s effort=%s config=%s settings=%s lens=%s task_bytes=%s system_bytes=%s diff_lines=%s partial=%s base=%s head=%s cwd=%s max_usd=%s timeout=%ss\n' \
      "$model" "$effort" "$cfg_src" "$settings_kind" "$lens" "${#task}" "${#system}" "$lines" "$partial" "$base_ref" "$head_ref" "$repo" "$max_usd" "$tmo"
    pg_finish DRYRUN dry-run 0; return $?
  fi

  pg_slot_acquire || { pg_inconclusive "busy:all-${PRE_GATE_MAX_CONCURRENT:-2}-slots-taken"; return $?; }
  _inc_extra="model=$model effort=$effort"

  pg_log "reviewing $branch@${branch_sha:0:9} vs $base_ref — lens $lens, $file_count file(s), $lines diff line(s)$([ "$partial" = true ] && echo ', PARTIAL'), model=$model effort=$effort, cap \$$max_usd / ${tmo}s, attempt $PG_ATTEMPT"
  local t0=$SECONDS rc
  ( cd "$repo" && pg_with_timeout "$tmo" "${cmd[@]}" < "$work/task.txt" > "$work/stream.jsonl" 2> "$work/stderr.txt" )
  rc=$?
  local dur=$((SECONDS - t0))

  local parsed verdict cost turns models subtype iserr result
  parsed="$(pg_parse_stream "$work/stream.jsonl" "$work/review.txt")"
  result="$(printf '%s\n' "$parsed" | sed -n 's/^RESULT=//p')"
  verdict="$(printf '%s\n' "$parsed" | sed -n 's/^VERDICT=//p')"; cost="$(printf '%s\n' "$parsed" | sed -n 's/^COST=//p')"
  turns="$(printf '%s\n' "$parsed" | sed -n 's/^TURNS=//p')";     models="$(printf '%s\n' "$parsed" | sed -n 's/^MODELS=//p')"
  subtype="$(printf '%s\n' "$parsed" | sed -n 's/^SUBTYPE=//p')"; iserr="$(printf '%s\n' "$parsed" | sed -n 's/^ISERR=//p')"

  # keep the raw review for the builder and for audit (small; the stream itself is not kept)
  local rdir review_file=""; rdir="$(pg_log_dir)/reviews"
  if mkdir -p "$rdir" 2>/dev/null && [ -f "$work/review.txt" ]; then
    review_file="$rdir/$(printf '%s' "${bead:-$branch}" | tr '/ ' '__')-$ts-a$PG_ATTEMPT.txt"
    cp "$work/review.txt" "$review_file" 2>/dev/null || review_file=""
  fi

  local out_verdict reason code
  if [ "$rc" -eq 124 ]; then out_verdict=INCONCLUSIVE; reason="timeout:${tmo}s"; code=3
  elif [ "$rc" -eq 127 ]; then out_verdict=INCONCLUSIVE; reason="no-timeout-tool"; code=3
  elif [ "$result" != "present" ]; then out_verdict=INCONCLUSIVE; reason="no-result:claude-exit-$rc:$(head -c 120 "$work/stderr.txt" 2>/dev/null | tr '\n' ' ')"; code=3
  elif [ "$iserr" = "true" ]; then out_verdict=INCONCLUSIVE; reason="claude-error:${subtype:-unknown}"; code=3
  elif [ "$verdict" = "PASS" ]; then out_verdict=PASS; reason="none"; code=0
  elif [ "$verdict" = "FAIL" ]; then out_verdict=FAIL; reason="blocking"; code=10
  else out_verdict=INCONCLUSIVE; reason="no-verdict-line"; code=3
  fi

  pg_record run bead="$bead" branch="$branch" sha="$branch_sha" arm="$PG_ARM" attempt="$PG_ATTEMPT" verdict="$out_verdict" reason="$reason" \
    launched=true forced="$([ "$force" -eq 1 ] && echo true || echo false)" cost_usd="${cost:-0}" turns="${turns:-0}" duration_s="$dur" model="$model" model_resolved="$models" effort="$effort" \
    config_source="$cfg_src" settings="$settings_kind" lens="$lens" exit_code="$rc" task_bytes="${#task}" diff_lines="$lines" partial="$partial" \
    fetch="$fetch_state" review_file="$review_file" >/dev/null || pg_log "WARN: this run was NOT recorded — the measurement will not see it"

  echo "── pre-gate review: $out_verdict (attempt $PG_ATTEMPT, ${dur}s, \$${cost:-?}, model ${models:-?}) ──"
  if [ -s "$work/review.txt" ]; then cat "$work/review.txt"; echo; fi
  [ -n "$review_file" ] && echo "(full text: $review_file)"
  if [ "$out_verdict" = FAIL ]; then
    echo "Fix the blocking issue(s), commit, and re-run — at most ${PRE_GATE_MAX_RUNS:-3} runs per bead, then submit."
  fi
  pg_finish "$out_verdict" "$reason" "$code"; return $?
}

pg_main() {
  case "${1:-}" in
    arm)
      shift
      [ -n "${1:-}" ] || { pg_log "usage: pre-gate-review.sh arm <bead-id>"; return 2; }
      pregate_arm_for_bead "$1" || return $?
      echo
      ;;
    roster)
      # /gate-done Step 3. Puts EVERY submission on the roster, whether or not the builder ran Step 2b: without this a bead
      # whose builder skipped the step is on neither arm, and the intention-to-treat comparison quietly becomes a
      # comparison among the builders who complied. Prints the arm (the marker label); a roster write that fails is
      # reported on stderr but never withholds the arm — the label and the roster then disagree, visibly.
      shift
      local rbead="${1:-}" rbranch="${2:-}" rarm rrc
      [ -n "$rbead" ] && [ -n "$rbranch" ] || { pg_log "usage: pre-gate-review.sh roster <bead-id> <branch>"; return 2; }
      rarm="$(pregate_arm_for_bead "$rbead")"; rrc=$?
      [ "$rrc" -eq 0 ] || return "$rrc"
      pg_record assign bead="$rbead" branch="$rbranch" sha="$(git rev-parse HEAD 2>/dev/null || true)" arm="$rarm" source=gate-done >/dev/null \
        || pg_log "WARN: the assignment of $rbead ($rarm) could NOT be written to the roster"
      printf '%s\n' "$rarm"
      ;;
    run) shift; pg_run "$@" ;;
    ""|-h|--help) pg_usage; return 2 ;;
    *) pg_run "$@" ;;
  esac
}

# Run only when executed; `source pre-gate-review.sh` just defines the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap pg_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  pg_main "$@"
  exit $?
fi
