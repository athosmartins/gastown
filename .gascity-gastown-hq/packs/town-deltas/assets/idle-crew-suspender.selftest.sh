#!/usr/bin/env bash
# idle-crew-suspender.selftest.sh (ga-v8p1tx.1.6) — hermetic: mock gc/bd, temp
# projects dir, temp agents dir. Nothing touches the real city.
# Run: bash idle-crew-suspender.selftest.sh   (exit 0 = all pass)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="${ICS_SUT:-${HERE}/idle-crew-suspender.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ics-selftest.XXXXXX")"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/agents" "$T/mock" "$T/proj" "$T/run"
# five named crews (oracle must never be touched) + one pool agent that must be ignored
for c in oracle-wa digo-wa peter-wa thies-wa batista-wa; do
  rig=whatsapp_automation; wd="/x/${rig}/crew/${c%-*}"
  mkdir -p "$T/agents/$c"
  printf 'max_active_sessions = 1\nwork_dir = "%s"\n' "$wd" > "$T/agents/$c/agent.toml"
done
mkdir -p "$T/agents/wa-worker"
printf 'max_active_sessions = 4\nwork_dir = "/x/whatsapp_automation/crew/worker"\n' > "$T/agents/wa-worker/agent.toml"

# transcript dir per crew, with an mtime N minutes ago
mk_transcript() { # <crew-dir-name> <minutes-ago>
  local d="$T/proj/-x-whatsapp-automation-crew-$1"; mkdir -p "$d"
  : > "$d/s.jsonl"
  touch -t "$(date -v-"$2"M +%Y%m%d%H%M.%S 2>/dev/null || date -d "$2 minutes ago" +%Y%m%d%H%M.%S)" "$d/s.jsonl"
}
mk_transcript oracle 600; mk_transcript digo 90; mk_transcript peter 90; mk_transcript thies 10; mk_transcript batista 90

# mock gc: `session list --json [--state all]` reads sessions.json and marks suspended ids asleep;
# `session suspend <id>` records the call.
cat > "$T/mock/gc" <<'MOCKGC'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")" && pwd)"
[ -f "$M/gc.broken" ] && exit 1
if [ "$1 $2" = "session list" ]; then
  [ -f "$M/gc.garbage" ] && { echo 'not json'; exit 0; }
  python3 - "$M" <<'PY'
import json, sys, os
M = sys.argv[1]
d = json.load(open(M + "/sessions.json"))
sus = set(open(M + "/suspended.log").read().split()) if os.path.exists(M + "/suspended.log") else set()
for s in d["sessions"]:
    if s["id"] in sus: s["state"] = "asleep"
print(json.dumps(d))
PY
  exit 0
fi
if [ "$1 $2" = "session suspend" ]; then
  [ -f "$M/gc.nosuspend" ] && exit 1
  echo "$3" >> "$M/suspended.log"; exit 0
fi
exit 2
MOCKGC
chmod +x "$T/mock/gc"

# mock bd: `-C <store> list --status in_progress --assignee <id> ...` → files inprog.<id> (JSON list)
cat > "$T/mock/bd" <<'MOCKBD'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")" && pwd)"
[ -f "$M/bd.broken" ] && exit 1
a=""; prev=""
for x in "$@"; do [ "$prev" = "--assignee" ] && a="$x"; prev="$x"; done
if [ -f "$M/inprog.$a" ]; then cat "$M/inprog.$a"; else echo '[]'; fi
MOCKBD
chmod +x "$T/mock/bd"

sessions_json() { # id name template attached
  python3 - "$@" <<'PY'
import json, sys
rows = []
a = sys.argv[1:]
for i in range(0, len(a), 4):
    sid, name, tpl, att = a[i:i+4]
    rows.append({"id": sid, "name": name, "alias": name, "template": tpl, "state": "active",
                 "attached": {"true": True, "false": False}.get(att), "closed": False})
print(json.dumps({"ok": True, "sessions": rows}))
PY
}
reset_mock() { rm -f "$T/mock/suspended.log" "$T/mock"/*.broken "$T/mock"/gc.garbage "$T/mock"/gc.nosuspend "$T/mock"/inprog.* "$T/log"; rm -f "$T/run/lock/pid"; rmdir "$T/run/lock" 2>/dev/null; true; }
base_sessions() {
  sessions_json s1 oracle-wa oracle-wa false  s2 digo-wa digo-wa false  s3 peter-wa peter-wa false \
                s4 thies-wa thies-wa false   s5 batista-wa batista-wa false  s6 wa-worker-adhoc-1 wa-worker false > "$T/mock/sessions.json"
}
run_sut() { # extra env as args
  env GC="$T/mock/gc" BD="$T/mock/bd" GC_CITY_PATH="$T/city" CREW_IDLE_AGENTS_DIR="$T/agents" \
      ICS_LOG="$T/log" ICS_RUN_DIR="$T/run" ICS_LOCK_DIR="$T/run/lock" ICS_PROJECTS_DIR="$T/proj" \
      ICS_NOW_HOUR=14 ICS_VERIFY_SLEEP=0 "$@" bash "$SUT" >/dev/null 2>&1
}
suspended_ids() { sort "$T/mock/suspended.log" 2>/dev/null | tr '\n' ' '; }

echo "S1: window 06:00-24:00 (library mode)"
( ICS_LIB=1 CREW_IDLE_AGENTS_DIR="$T/agents" source "$SUT"
  r=""; for h in 05 06 14 23 00; do ICS_NOW_HOUR=$h _in_window && r="${r}$h:in " || r="${r}$h:out "; done
  [ "$r" = "05:out 06:in 14:in 23:in 00:out " ] && exit 0 || { echo "$r"; exit 1; } ) \
  && ok "05→out 06→in 14→in 23→in 00→out" || bad "window boundaries wrong"
( ICS_LIB=1 source "$SUT"; ICS_NOW_HOUR=xx _in_window && exit 1 || exit 0 ) \
  && ok "unreadable clock → outside (inert)" || bad "unreadable clock counted as inside"

echo "S2: exclusion (oracle* floor, extras additive)"
( ICS_LIB=1 source "$SUT"
  _is_excluded oracle-wa && _is_excluded oracle-ma && ! _is_excluded digo-wa || exit 1
  ICS_EXTRA_EXCLUDE="peter*" EXCLUDE_GLOBS="oracle* peter*"; _is_excluded peter-wa && _is_excluded oracle-wa ) \
  && ok "oracle-* excluded, digo-wa not, extra glob adds without dropping oracle" || bad "exclusion wrong"

echo "S3: transcript idle minutes (3 states)"
( ICS_LIB=1 ICS_PROJECTS_DIR="$T/proj" source "$SUT"
  a="$(_transcript_idle_min /x/whatsapp_automation/crew/digo)"; rc_a=$?
  _transcript_idle_min /x/whatsapp_automation/crew/nobody >/dev/null; rc_b=$?
  mkdir -p "$T/proj/-x-whatsapp-automation-crew-empty"; _transcript_idle_min /x/whatsapp_automation/crew/empty >/dev/null; rc_c=$?
  [ "$rc_a" = 0 ] && [ "$a" -ge 89 ] && [ "$a" -le 92 ] && [ "$rc_b" = 2 ] && [ "$rc_c" = 2 ] ) \
  && ok "90 min → ~90; missing dir → unknown(2); dir without jsonl → unknown(2)" || bad "transcript idle wrong"

echo "S4: end-to-end — only the idle, bead-free, detached, non-oracle crews are suspended"
reset_mock; base_sessions
printf '[{"id":"wa-1"}]' > "$T/mock/inprog.peter-wa"
run_sut; got="$(suspended_ids)"
[ "$got" = "s2 s5 " ] && ok "suspended exactly digo-wa(s2) + batista-wa(s5)" || bad "expected 's2 s5 ', got '$got'"
grep -q 'SUSPENDED crew=digo-wa id=s2 idle_min=9' "$T/log" && ok "log carries SUSPENDED line with idle_min + confirmed state" || bad "no SUSPENDED log line"
grep -q 'KEEP crew=oracle-wa .*excluded' "$T/log" && ok "oracle-wa kept (excluded)" || bad "oracle-wa not logged as excluded"
grep -q 'KEEP crew=peter-wa .*bead(in_progress=1' "$T/log" && ok "peter-wa kept (in_progress bead)" || bad "peter-wa bead skip missing"
grep -q 'KEEP crew=thies-wa .*transcript-recent' "$T/log" && ok "thies-wa kept (transcript 10 min)" || bad "thies-wa recent skip missing"
grep -q 'wa-worker' "$T/log" && bad "pool worker was evaluated" || ok "pool worker ignored"

echo "S5: attached session is never suspended"
reset_mock
sessions_json s2 digo-wa digo-wa true s5 batista-wa batista-wa unknown > "$T/mock/sessions.json"
run_sut; [ -z "$(suspended_ids)" ] && ok "attached=true and attached=unknown both kept" || bad "suspended an attached/unknown session: $(suspended_ids)"

echo "S6: could-not-tell lands inert"
reset_mock; base_sessions; touch "$T/mock/bd.broken"; run_sut
[ -z "$(suspended_ids)" ] && ok "bd failing → nothing suspended (not read as 'no bead')" || bad "suspended with bd broken: $(suspended_ids)"
reset_mock; base_sessions; for c in digo-wa peter-wa batista-wa; do echo 'not json' > "$T/mock/inprog.$c"; done; run_sut
[ -z "$(suspended_ids)" ] && ok "bd answering garbage → nothing suspended" || bad "suspended on garbage bd: $(suspended_ids)"
reset_mock; base_sessions; touch "$T/mock/gc.broken"; run_sut; rc=$?
[ -z "$(suspended_ids)" ] && grep -q 'ERR session list unreadable' "$T/log" && ok "gc session list failing → ERR, nothing suspended" || bad "gc broken not inert"
reset_mock; base_sessions; touch "$T/mock/gc.garbage"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'ERR session list unreadable' "$T/log" && ok "gc answering garbage → ERR, nothing suspended" || bad "gc garbage not inert"
reset_mock; base_sessions; rm -rf "$T/proj/-x-whatsapp-automation-crew-digo"; run_sut
[ "$(suspended_ids)" = "s3 s5 " ] && grep -q 'KEEP crew=digo-wa .*transcript-unknown' "$T/log" && ok "missing transcript dir → kept (unknown), others still evaluated" || bad "missing transcript handled wrong: $(suspended_ids)"
mk_transcript digo 90

echo "S7: window, dry-run, cap, failed suspend"
reset_mock; base_sessions; run_sut ICS_NOW_HOUR=3
[ -z "$(suspended_ids)" ] && grep -q OUTSIDE_WINDOW "$T/log" && ok "03:00 → nothing evaluated" || bad "ran outside the window"
reset_mock; base_sessions; run_sut ICS_DRY_RUN=1
[ -z "$(suspended_ids)" ] && grep -q 'WOULD_SUSPEND crew=digo-wa' "$T/log" && ok "dry-run logs WOULD_SUSPEND, calls nothing" || bad "dry-run suspended"
reset_mock; base_sessions; run_sut ICS_MAX_PER_RUN=1
[ "$(suspended_ids)" = "s2 " ] && grep -q 'per-run-cap' "$T/log" && ok "cap=1 → one suspension, the rest logged per-run-cap" || bad "cap not enforced: $(suspended_ids)"
reset_mock; base_sessions; touch "$T/mock/gc.nosuspend"; run_sut
grep -q 'SUSPEND_FAILED crew=digo-wa' "$T/log" && ! grep -q ' SUSPENDED ' "$T/log" && ok "suspend rc!=0 → SUSPEND_FAILED, never reported as suspended" || bad "failed suspend mis-logged"

echo "S8: singleton lock"
reset_mock; base_sessions; mkdir -p "$T/run/lock"; echo $$ > "$T/run/lock/pid"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'SKIP another run holds the lock' "$T/log" && ok "live lock owner → this run exits without acting" || bad "lock ignored"
echo 999999 > "$T/run/lock/pid"; run_sut
[ -n "$(suspended_ids)" ] && ok "stale lock (dead pid) is taken over" || bad "stale lock blocked the run"

echo; echo "idle-crew-suspender selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
