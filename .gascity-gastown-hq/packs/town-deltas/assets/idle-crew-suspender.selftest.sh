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
OWNERS=""   # pids of the stand-in lock owners (S16): killed on the way out
trap 'kill $OWNERS 2>/dev/null; rm -rf "$T"' EXIT

mkdir -p "$T/agents" "$T/mock" "$T/proj" "$T/run" "$T/nobin" "$T/bsdbin"
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
# `session suspend <id>` records the call. Switches are files next to it (reset_mock removes them):
#   gc.broken / gc.garbage      the list read fails / answers something that is not JSON
#   gc.nosuspend                suspend exits 1 and does nothing
#   gc.timeout-effective        suspend lands, then exits 124 (what `timeout 90` reports when gc hangs AFTER the hold was set)
#   gc.timeout-ineffective      suspend does nothing and exits 124
#   gc.statebroken              only the `--state all` read (the confirmation after a suspend) fails
#   gc.lag                      suspend exits 0 but the roster still says active (the managed path only sets the hold;
#                               the reconciler stops the runtime afterwards)
#   gc.slurp                    every call reads all of stdin (a command that eats its caller's loop list)
cat > "$T/mock/gc" <<'MOCKGC'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")" && pwd)"
[ -f "$M/gc.slurp" ] && cat > /dev/null
[ -f "$M/gc.broken" ] && exit 1
if [ "$1 $2" = "session list" ]; then
  [ -f "$M/gc.garbage" ] && { echo 'not json'; exit 0; }
  [ "${5:-}" = "all" ] && [ -f "$M/gc.statebroken" ] && exit 1
  python3 -I - "$M" <<'PY'
import json, sys, os
M = sys.argv[1]
d = json.load(open(M + "/sessions.json"))
sus = set(open(M + "/suspended.log").read().split()) if os.path.exists(M + "/suspended.log") and not os.path.exists(M + "/gc.lag") else set()
for s in d["sessions"]:
    if s["id"] in sus: s["state"] = "asleep"
print(json.dumps(d))
PY
  exit 0
fi
if [ "$1 $2" = "session suspend" ]; then
  [ -f "$M/gc.nosuspend" ] && exit 1
  [ -f "$M/gc.timeout-ineffective" ] && exit 124
  echo "$3" >> "$M/suspended.log"
  [ -f "$M/gc.timeout-effective" ] && exit 124
  exit 0
fi
exit 2
MOCKGC
chmod +x "$T/mock/gc"

# mock bd: the ONE call shape the SUT may make is
#   bd -C <store> list --status in_progress --assignee <name> --json --limit 0
# anything else exits 99 and is recorded in bd.unexpected (a mutant that changes the status, drops a flag or
# reorders the arguments must not get an answer). The file inprog.<store basename>.<name> holds the JSON answer
# (default []), so the rig store and the HQ store answer separately. Switches (reset_mock removes them):
#   bd.broken                   every call exits 1
#   bd.broken.<store>           calls for that store exit 1
#   bd.slurp                    every call reads all of stdin
cat > "$T/mock/bd" <<'MOCKBD'
#!/usr/bin/env bash
M="$(cd "$(dirname "$0")" && pwd)"
[ -f "$M/bd.slurp" ] && cat > /dev/null
[ -f "$M/bd.broken" ] && exit 1
if [ "$#" -ne 10 ] || [ "$1" != "-C" ] || [ "$3" != "list" ] || [ "$4" != "--status" ] || [ "$5" != "in_progress" ] \
   || [ "$6" != "--assignee" ] || [ "$8" != "--json" ] || [ "$9" != "--limit" ] || [ "${10}" != "0" ]; then
  echo "UNEXPECTED bd $*" >> "$M/bd.unexpected"; exit 99
fi
s="$(basename "$2")"; a="$7"
echo "$s $a" >> "$M/bd.calls"
[ -f "$M/bd.broken.$s" ] && exit 1
if [ -f "$M/inprog.$s.$a" ]; then cat "$M/inprog.$s.$a"; else echo '[]'; fi
MOCKBD
chmod +x "$T/mock/bd"

# sessions_json <tail> <alias> <template> <attached> ... → a roster in the REAL shape of `gc session list --json`:
# the envelope of cmd/gc/cmd_session.go (schema_version, filters, sessions, summary) and, per row, the 20 keys the
# gate reviewer read live from the mini on 12/11 (config-drift-wake.selftest.sh 14a pins the same list). A row is
# NOT built from the keys the SUT reads: `name` is the alias (the engine's sessionListJSONName: alias, else
# session_name, else id) and the session_name is <alias>-gawisp<tail of the id>, the form a crew's own beads are
# filed under (ga-v8p1tx.1.6 gate FAIL 14/11: wa-zmxywv.51 sat under thies-wa-gawisp3j5vr6, a name none of
# alias/name/id/template carried). ROW_OVERRIDE='{"s2":{"alias":"x"}}' replaces values (never keys) on the row of
# that tail.
sessions_json() {
  ROW_OVERRIDE="${ROW_OVERRIDE:-}" python3 -I - "$@" <<'PY'
import json, os, sys
REAL = ("agent_name alias attached closed command created_at id last_active last_nudge_delivered_at name provider "
        "resume_flag resume_style rig session_key session_name state template title work_dir").split()
over = json.loads(os.environ.get("ROW_OVERRIDE") or "{}")
a = sys.argv[1:]
rows = []
for i in range(0, len(a), 4):
    tail, alias, tpl, att = a[i:i+4]
    row = {"agent_name": tpl, "alias": alias, "attached": {"true": True, "false": False}.get(att), "closed": False,
           "command": "claude", "created_at": "2026-11-14T12:00:00Z", "id": "ga-wisp-" + tail,
           "last_active": "2026-11-14T12:00:00Z", "last_nudge_delivered_at": "", "name": alias,
           "provider": "claude", "resume_flag": "--resume", "resume_style": "flag", "rig": "whatsapp_automation",
           "session_key": "key-" + tail, "session_name": alias + "-gawisp" + tail, "state": "active",
           "template": tpl, "title": alias, "work_dir": "/x/whatsapp_automation/crew/" + alias.split("-")[0]}
    row.update(over.get(tail, {}))
    assert sorted(row) == sorted(REAL), sorted(set(row) ^ set(REAL))
    rows.append(row)
print(json.dumps({"schema_version": "1", "filters": {}, "sessions": rows,
                  "summary": {"total": len(rows), "active": len(rows), "suspended": 0, "closed": 0}}))
PY
}
reset_mock() { rm -f "$T/mock/suspended.log" "$T/mock"/gc.* "$T/mock"/bd.* "$T/mock"/inprog.* "$T/log"; rm -f "$T/run/lock/pid"; rmdir "$T/run/lock" 2>/dev/null; true; }
base_sessions() {
  sessions_json s1 oracle-wa oracle-wa false  s2 digo-wa digo-wa false  s3 peter-wa peter-wa false \
                s4 thies-wa thies-wa false   s5 batista-wa batista-wa false  s6 wa-worker-adhoc-1 wa-worker false > "$T/mock/sessions.json"
}
run_sut() { # extra env as args
  env GC="$T/mock/gc" BD="$T/mock/bd" GC_CITY_PATH="$T/city" CREW_IDLE_AGENTS_DIR="$T/agents" \
      ICS_LOG="$T/log" ICS_RUN_DIR="$T/run" ICS_LOCK_DIR="$T/run/lock" ICS_PROJECTS_DIR="$T/proj" \
      ICS_NOW_HOUR=14 ICS_VERIFY_SLEEP=0 "$@" bash "$SUT" >/dev/null 2>&1 </dev/null
}
suspended_ids() { sort "$T/mock/suspended.log" 2>/dev/null | tr '\n' ' '; }
RIG=whatsapp_automation   # the basename the mock bd sees for a crew's rig store (agent.toml work_dir /x/whatsapp_automation/crew/<c>)
HQ=city                   # ... and for the city (HQ) store (GC_CITY_PATH=$T/city)

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
# the mini's stat is BSD (`stat -f %m`), this node's and any Linux reviewer's is GNU (`stat -c %Y`, where `-f` prints
# the FILESYSTEM block on stdout and still exits 1): _mtime must return the bare epoch on either, never the block
printf '%s\n' '#!/bin/sh' 'case "$1" in -f) [ "$2" = "%m" ] && exec python3 -I -c '"'"'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))'"'"' "$3" ;; esac' 'echo "stat: illegal option -- c" >&2; exit 1' > "$T/bsdbin/stat"
chmod +x "$T/bsdbin/stat"
( ICS_LIB=1 source "$SUT"; f="$T/proj/-x-whatsapp-automation-crew-digo/s.jsonl"
  want="$(python3 -I -c 'import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$f")"
  gnu="$(_mtime "$f")"; bsd="$(PATH="$T/bsdbin:$PATH" _mtime "$f")"
  [ "$gnu" = "$want" ] && [ "$bsd" = "$want" ] || { echo "want=$want gnu=$gnu bsd=$bsd"; exit 1; } ) \
  && ok "_mtime: bare epoch with this system's stat AND with a BSD-style stat first in PATH" || bad "_mtime returned garbage on one stat flavour"

echo "S4: end-to-end — only the idle, bead-free, detached, non-oracle crews are suspended"
reset_mock; base_sessions
printf '[{"id":"wa-1"}]' > "$T/mock/inprog.$RIG.peter-wa"
run_sut; got="$(suspended_ids)"
[ "$got" = "ga-wisp-s2 ga-wisp-s5 " ] && ok "suspended exactly digo-wa(s2) + batista-wa(s5)" || bad "expected 'ga-wisp-s2 ga-wisp-s5 ', got '$got'"
grep -q 'SUSPENDED crew=digo-wa id=ga-wisp-s2 idle_min=9' "$T/log" && ok "log carries SUSPENDED line with idle_min + confirmed state" || bad "no SUSPENDED log line"
grep -q 'KEEP crew=oracle-wa .*excluded' "$T/log" && ok "oracle-wa kept (excluded)" || bad "oracle-wa not logged as excluded"
grep -q 'KEEP crew=peter-wa .*bead(in_progress=1' "$T/log" && ok "peter-wa kept (in_progress bead)" || bad "peter-wa bead skip missing"
grep -q 'KEEP crew=thies-wa .*transcript-recent' "$T/log" && ok "thies-wa kept (transcript 10 min)" || bad "thies-wa recent skip missing"
grep -q 'wa-worker' "$T/log" && bad "pool worker was evaluated" || ok "pool worker ignored"
grep -q 'RUN done evaluated=5 suspended=2 kept=3 dry_run=0' "$T/log" && ok "RUN done summary counts 5 evaluated / 2 suspended / 3 kept" || bad "RUN done summary wrong: $(grep 'RUN done' "$T/log")"
[ ! -s "$T/mock/bd.unexpected" ] && ok "bd was only ever asked: -C <store> list --status in_progress --assignee <name> --json --limit 0" || bad "bd called in another shape: $(head -1 "$T/mock/bd.unexpected")"
# digo-wa is idle with no bead anywhere: every distinct name (alias=name=agent_name=template digo-wa, session_name, id) is asked in BOTH stores, once each
want="$HQ digo-wa
$HQ digo-wa-gawisps2
$HQ ga-wisp-s2
$RIG digo-wa
$RIG digo-wa-gawisps2
$RIG ga-wisp-s2"
[ "$(grep -F -e " digo-wa" -e " ga-wisp-s2" "$T/mock/bd.calls" | sort)" = "$want" ] && ok "digo-wa: 3 distinct names x rig store + HQ store, each asked once" || bad "bd questions for digo-wa wrong: $(grep -F -e ' digo-wa' -e ' ga-wisp-s2' "$T/mock/bd.calls" | sort | tr '\n' '|')"

echo "S5: attached session is never suspended"
reset_mock
sessions_json s2 digo-wa digo-wa true s5 batista-wa batista-wa unknown > "$T/mock/sessions.json"
run_sut; [ -z "$(suspended_ids)" ] && ok "attached=true and attached=unknown both kept" || bad "suspended an attached/unknown session: $(suspended_ids)"

echo "S6: could-not-tell lands inert"
reset_mock; base_sessions; touch "$T/mock/bd.broken"; run_sut
[ -z "$(suspended_ids)" ] && ok "bd failing → nothing suspended (not read as 'no bead')" || bad "suspended with bd broken: $(suspended_ids)"
reset_mock; base_sessions; for c in digo-wa peter-wa batista-wa; do echo 'not json' > "$T/mock/inprog.$RIG.$c"; done; run_sut
[ -z "$(suspended_ids)" ] && ok "bd answering garbage → nothing suspended" || bad "suspended on garbage bd: $(suspended_ids)"
reset_mock; base_sessions; for c in digo-wa peter-wa batista-wa; do echo '{"error":"boom"}' > "$T/mock/inprog.$RIG.$c"; done; run_sut
[ -z "$(suspended_ids)" ] && ok "bd answering a JSON object (valid JSON, not a list) → nothing suspended" || bad "suspended on a non-list bd answer: $(suspended_ids)"
reset_mock; base_sessions; for c in digo-wa peter-wa batista-wa; do : > "$T/mock/inprog.$RIG.$c"; done; run_sut
[ -z "$(suspended_ids)" ] && ok "bd answering nothing at all (rc 0, empty output) → nothing suspended" || bad "suspended on an empty bd answer: $(suspended_ids)"
reset_mock; base_sessions; touch "$T/mock/gc.broken"; run_sut; rc=$?
[ -z "$(suspended_ids)" ] && grep -q 'ERR session list unreadable' "$T/log" && ok "gc session list failing → ERR, nothing suspended" || bad "gc broken not inert"
reset_mock; base_sessions; touch "$T/mock/gc.garbage"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'ERR session list unreadable' "$T/log" && ok "gc answering garbage → ERR, nothing suspended" || bad "gc garbage not inert"
reset_mock; base_sessions; rm -rf "$T/proj/-x-whatsapp-automation-crew-digo"; run_sut
[ "$(suspended_ids)" = "ga-wisp-s3 ga-wisp-s5 " ] && grep -q 'KEEP crew=digo-wa .*transcript-unknown' "$T/log" && ok "missing transcript dir → kept (unknown), others still evaluated" || bad "missing transcript handled wrong: $(suspended_ids)"
mk_transcript digo 90

echo "S7: window, dry-run, cap, failed suspend"
reset_mock; base_sessions; run_sut ICS_NOW_HOUR=3
[ -z "$(suspended_ids)" ] && grep -q OUTSIDE_WINDOW "$T/log" && ok "03:00 → nothing evaluated" || bad "ran outside the window"
reset_mock; base_sessions; run_sut ICS_DRY_RUN=1
[ -z "$(suspended_ids)" ] && grep -q 'WOULD_SUSPEND crew=digo-wa' "$T/log" && ok "dry-run logs WOULD_SUSPEND, calls nothing" || bad "dry-run suspended"
reset_mock; base_sessions; run_sut ICS_MAX_PER_RUN=1
[ "$(suspended_ids)" = "ga-wisp-s2 " ] && grep -q 'per-run-cap' "$T/log" && ok "cap=1 → one suspension, the rest logged per-run-cap" || bad "cap not enforced: $(suspended_ids)"
reset_mock; base_sessions; touch "$T/mock/gc.nosuspend"; run_sut
grep -q 'SUSPEND_FAILED crew=digo-wa' "$T/log" && ! grep -q ' SUSPENDED ' "$T/log" && ok "suspend rc!=0 → SUSPEND_FAILED, never reported as suspended" || bad "failed suspend mis-logged"

echo "S8: singleton lock"
reset_mock; base_sessions; mkdir -p "$T/run/lock"; echo $$ > "$T/run/lock/pid"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'SKIP another run holds the lock' "$T/log" && ok "live lock owner → this run exits without acting" || bad "lock ignored"
echo 999999 > "$T/run/lock/pid"; run_sut
[ -n "$(suspended_ids)" ] && ok "stale lock (dead pid) is taken over" || bad "stale lock blocked the run"

echo "S9: the roster fixture has the REAL shape (not the keys the SUT reads)"
reset_mock; base_sessions
python3 -I - "$T/mock/sessions.json" <<'PY' > "$T/shape.out"
import json, sys
REAL = set(("agent_name alias attached closed command created_at id last_active last_nudge_delivered_at name provider "
            "resume_flag resume_style rig session_key session_name state template title work_dir").split())
d = json.load(open(sys.argv[1]))
print("ok" if set(d) == {"schema_version", "filters", "sessions", "summary"} else "BAD envelope %s" % sorted(d))
print("ok" if all(set(r) == REAL for r in d["sessions"]) else "BAD row keys %s" % sorted(set(d["sessions"][0]) ^ REAL))
crew = [r for r in d["sessions"] if r["template"] != "wa-worker"]
print("ok" if crew and all(r["name"] == r["alias"] and r["session_name"] == r["alias"] + "-gawisp" + r["id"][len("ga-wisp-"):]
                           and r["session_name"] not in (r["name"], r["alias"], r["id"], r["template"], r["agent_name"]) for r in crew)
      else "BAD identity forms")
PY
[ "$(tr '\n' ' ' < "$T/shape.out")" = "ok ok ok " ] && ok "envelope + 20 real keys per row; a crew's session_name is its own form, distinct from alias/name/id/template/agent_name" || bad "fixture shape: $(tr '\n' ' ' < "$T/shape.out")"

echo "S10: a bead filed under the SESSION NAME alone keeps the crew (the gate FAIL of 14/11)"
reset_mock; base_sessions
printf '[{"id":"wa-2"}]' > "$T/mock/inprog.$RIG.digo-wa-gawisps2"
run_sut; got="$(suspended_ids)"
[ "$got" = "ga-wisp-s3 ga-wisp-s5 " ] && ok "digo-wa kept (its only bead is under digo-wa-gawisps2); peter-wa and batista-wa (no bead) suspended" || bad "expected peter(s3)+batista(s5) only, got '$got'"
grep -q "KEEP crew=digo-wa .*bead(in_progress=1 as=digo-wa-gawisps2 store=$RIG)" "$T/log" && ok "log names the identity the bead was found under" || bad "session_name bead skip not logged: $(grep 'crew=digo-wa' "$T/log")"

echo "S11: every name the roster gives a session is asked (id, session_name, name, alias, agent_name, template)"
# a real crew has alias == name == agent_name == template; here all six differ so each key is proven on its own
for form in id session_name name alias agent_name template; do
  reset_mock
  ROW_OVERRIDE='{"s2":{"alias":"digo-alias","name":"digo-name","agent_name":"digo-agent"}}' sessions_json s2 digo-wa digo-wa false > "$T/mock/sessions.json"
  case "$form" in
    id) v=ga-wisp-s2 ;; session_name) v=digo-wa-gawisps2 ;; name) v=digo-name ;; alias) v=digo-alias ;;
    agent_name) v=digo-agent ;; template) v=digo-wa ;;
  esac
  printf '[{"id":"wa-3"}]' > "$T/mock/inprog.$RIG.$v"
  run_sut
  [ -z "$(suspended_ids)" ] && grep -q "KEEP crew=digo-wa .*bead(in_progress=1 as=$v store=$RIG)" "$T/log" \
    && ok "bead filed under the session's $form ($v) keeps the crew" || bad "bead under $form ($v) did not keep digo-wa: suspended '$(suspended_ids)'"
done

echo "S12: both stores count, and either store failing is could-not-tell"
reset_mock; base_sessions
printf '[{"id":"ga-9"}]' > "$T/mock/inprog.$HQ.digo-wa"
run_sut; got="$(suspended_ids)"
[ "$got" = "ga-wisp-s3 ga-wisp-s5 " ] && grep -q "KEEP crew=digo-wa .*bead(in_progress=1 as=digo-wa store=$HQ)" "$T/log" && ok "bead only in the HQ store keeps digo-wa" || bad "HQ-only bead ignored: '$got'"
reset_mock; base_sessions; touch "$T/mock/bd.broken.$HQ"; run_sut
[ -z "$(suspended_ids)" ] && grep -q "KEEP crew=digo-wa .*bead(in_progress=? as=digo-wa store=$HQ)" "$T/log" && ok "HQ store unreadable → every idle crew kept (not read as 'no bead')" || bad "HQ store failure not inert: '$(suspended_ids)'"
reset_mock; base_sessions; touch "$T/mock/bd.broken.$RIG"; run_sut
[ -z "$(suspended_ids)" ] && ok "rig store unreadable → every idle crew kept" || bad "rig store failure not inert: '$(suspended_ids)'"

echo "S13: an unusable env value lands in the inert state, never in 'threshold off' / 'cap off' / 'real run'"
( ICS_LIB=1 source "$SUT"
  _is_uint 0 && _is_uint 60 && _is_uint 999999 && ! _is_uint '' && ! _is_uint abc && ! _is_uint -1 && ! _is_uint 1.5 && ! _is_uint 1000000 && ! _is_uint 99999999999999999999 ) \
  && ok "_is_uint: whole numbers up to 6 digits only" || bad "_is_uint wrong"
reset_mock; base_sessions; run_sut ICS_IDLE_MIN=abc
grep -q "WARN ICS_IDLE_MIN='abc'" "$T/log" && grep -q 'KEEP crew=thies-wa .*transcript-recent' "$T/log" && [ "$(suspended_ids)" = "ga-wisp-s2 ga-wisp-s3 ga-wisp-s5 " ] \
  && ok "ICS_IDLE_MIN=abc → WARN + the 60 min default (thies-wa at 10 min stays)" || bad "ICS_IDLE_MIN=abc: '$(suspended_ids)'"
reset_mock; base_sessions; run_sut ICS_IDLE_MIN=99999999999999999999
grep -q 'WARN ICS_IDLE_MIN=' "$T/log" && grep -q 'KEEP crew=thies-wa .*transcript-recent' "$T/log" \
  && ok "ICS_IDLE_MIN too big for [ -lt ] → WARN + default (thies-wa stays)" || bad "huge ICS_IDLE_MIN not defaulted: '$(suspended_ids)'"
reset_mock; base_sessions; mk_transcript thies 90; run_sut ICS_MAX_PER_RUN=abc
[ "$(suspended_ids)" = "ga-wisp-s2 ga-wisp-s3 ga-wisp-s4 " ] && grep -q "WARN ICS_MAX_PER_RUN='abc'" "$T/log" && grep -q 'KEEP crew=batista-wa .*per-run-cap(3)' "$T/log" \
  && ok "ICS_MAX_PER_RUN=abc → WARN + cap 3 (4 eligible, 3 suspended)" || bad "cap not defaulted: '$(suspended_ids)'"
reset_mock; base_sessions; run_sut ICS_MAX_PER_RUN=0
[ -z "$(suspended_ids)" ] && grep -q 'per-run-cap(0)' "$T/log" && ok "ICS_MAX_PER_RUN=0 is a real cap of zero (kill-switch), not replaced by the default" || bad "cap 0 not honoured: '$(suspended_ids)'"
mk_transcript thies 10
# the bad value goes into the log: it is cut to 40 characters and a newline in it must not forge a log line
long=""; for i in 1 2 3 4 5 6 7 8 9 10; do long="${long}xxxxxxxxxx"; done
nlval=$'bad\nFORGED line'
reset_mock; base_sessions; run_sut "ICS_IDLE_MIN=$long" "ICS_MAX_PER_RUN=$nlval"
grep -q "WARN ICS_MAX_PER_RUN='bad?FORGED?line'" "$T/log" && ! grep -q '^FORGED' "$T/log" && grep -q "WARN ICS_IDLE_MIN='x\{40\}'" "$T/log" \
  && ok "hostile env text: cut to 40 characters, the newline neutralised, no forged log line" || bad "env text reached the log raw: $(grep WARN "$T/log" | cut -c1-160 | tr '\n' '|')"
reset_mock; base_sessions; run_sut ICS_DRY_RUN=yes
[ -z "$(suspended_ids)" ] && grep -q "WARN ICS_DRY_RUN='yes'" "$T/log" && grep -q 'WOULD_SUSPEND crew=digo-wa' "$T/log" \
  && ok "ICS_DRY_RUN=yes → WARN + dry-run (nothing suspended)" || bad "ICS_DRY_RUN=yes suspended or did not warn: '$(suspended_ids)'"
reset_mock; base_sessions; run_sut ICS_DRY_RUN=0
[ -n "$(suspended_ids)" ] && ! grep -q 'WARN ICS_DRY_RUN' "$T/log" && ok "ICS_DRY_RUN=0 is the explicit real run (no WARN)" || bad "ICS_DRY_RUN=0 mishandled"

echo "S14: a gc that times out (rc 124) may still have suspended: read the state, count it toward the cap"
reset_mock; base_sessions; touch "$T/mock/gc.timeout-effective"; run_sut ICS_MAX_PER_RUN=1
grep -q 'SUSPENDED crew=digo-wa id=ga-wisp-s2 .*state_after=asleep (gc exited rc=124' "$T/log" && ! grep -q 'SUSPEND_FAILED' "$T/log" && grep -q 'KEEP crew=peter-wa .*per-run-cap(1)' "$T/log" \
  && ok "rc 124 but the state reads asleep → SUSPENDED (rc kept in the line), counted toward the cap" || bad "rc 124 + effective mis-logged: $(grep -E 'crew=(digo|peter)-wa' "$T/log" | tr '\n' '|')"
reset_mock; base_sessions; touch "$T/mock/gc.timeout-effective" "$T/mock/gc.statebroken"; run_sut ICS_MAX_PER_RUN=1
grep -q 'SUSPEND_UNKNOWN crew=digo-wa id=ga-wisp-s2 .*rc=124 state_after=?' "$T/log" && grep -q 'KEEP crew=peter-wa .*per-run-cap(1)' "$T/log" \
  && ok "rc 124 and the state unreadable → SUSPEND_UNKNOWN, counted toward the cap" || bad "rc 124 + unreadable state mis-logged: $(grep -E 'crew=(digo|peter)-wa' "$T/log" | tr '\n' '|')"
reset_mock; base_sessions; touch "$T/mock/gc.timeout-ineffective"; run_sut ICS_MAX_PER_RUN=1
grep -q 'SUSPEND_FAILED crew=digo-wa .*rc=124' "$T/log" && grep -q 'SUSPEND_FAILED crew=peter-wa .*rc=124' "$T/log" && ! grep -q 'per-run-cap' "$T/log" \
  && ok "rc 124 and still active → SUSPEND_FAILED, NOT counted (the next crew is still tried)" || bad "rc 124 + ineffective mis-logged: $(grep -E 'crew=(digo|peter)-wa' "$T/log" | tr '\n' '|')"

reset_mock; base_sessions; touch "$T/mock/gc.lag"; run_sut ICS_MAX_PER_RUN=1
grep -q 'SUSPEND_UNCONFIRMED crew=digo-wa id=ga-wisp-s2 .*state_after=active' "$T/log" && ! grep -q ' SUSPENDED ' "$T/log" && grep -q 'KEEP crew=peter-wa .*per-run-cap(1)' "$T/log" \
  && ok "rc 0 but the roster still says active (hold set, reconciler not done) → SUSPEND_UNCONFIRMED, never SUSPENDED, counted toward the cap" || bad "rc 0 + still active mis-logged: $(grep -E 'crew=(digo|peter)-wa' "$T/log" | tr '\n' '|')"

echo "S15: a session that answers to a crew name but not by template is reported, not silently skipped"
reset_mock; sessions_json s2 digo-wa crew-v2 false  s5 batista-wa crew-v2 false > "$T/mock/sessions.json"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'WARN 2 active session(s) answer to a Layer-1 crew name by alias/name/agent_name but not by template' "$T/log" \
  && ok "2 renamed-template sessions → WARN with the count, nothing suspended" || bad "template drift not reported: $(grep -E 'WARN|RUN done' "$T/log" | tr '\n' '|')"
reset_mock; sessions_json s6 wa-worker-adhoc-1 wa-worker false > "$T/mock/sessions.json"; run_sut
! grep -q 'WARN' "$T/log" && grep -q 'RUN done evaluated=0 ' "$T/log" && ok "only pool workers (every crew already asleep) → no WARN" || bad "healthy idle run warned: $(grep WARN "$T/log")"

echo "S16: singleton lock — a live pid holds it only while it IS an idle-crew-suspender run"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$T/nobin/ps"; chmod +x "$T/nobin/ps"
# a stand-in whose script NAME says idle-crew-suspender (ps shows `/bin/sh <path>`, on macOS too); the TERM trap takes its sleep with it
cat > "$T/idle-crew-suspender-standin.sh" <<'STANDIN'
#!/bin/sh
trap 'kill $c 2>/dev/null; exit 0' TERM
sleep 120 & c=$!
wait $c
STANDIN
chmod +x "$T/idle-crew-suspender-standin.sh"
# wait_cmd <pid> <text>: until the process has exec'd (between fork and exec ps still shows this selftest's own command line, which also says idle-crew-suspender)
wait_cmd() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do case "$(ps -p "$1" -o command= 2>/dev/null)" in *"$2"*) return 0 ;; esac; sleep 0.1; done; return 1; }
reset_mock; base_sessions; mkdir -p "$T/run/lock"
"$T/idle-crew-suspender-standin.sh" & ours=$!; OWNERS="$OWNERS $ours"; wait_cmd "$ours" standin || bad "stand-in lock owner never started"
echo "$ours" > "$T/run/lock/pid"; run_sut
[ -z "$(suspended_ids)" ] && grep -q 'SKIP another run holds the lock' "$T/log" && ok "live pid whose command is idle-crew-suspender → held" || bad "real owner not honoured: '$(suspended_ids)'"
reset_mock; base_sessions; mkdir -p "$T/run/lock"
sleep 120 & other=$!; OWNERS="$OWNERS $other"; wait_cmd "$other" "sleep 120" || bad "unrelated lock owner never started"
echo "$other" > "$T/run/lock/pid"; run_sut
[ -n "$(suspended_ids)" ] && ! grep -q 'SKIP another run holds the lock' "$T/log" && ok "live pid running something else (a reused pid) → lock taken over, the run proceeds" || bad "reused pid held the lock forever: '$(suspended_ids)'"
reset_mock; base_sessions; mkdir -p "$T/run/lock"; echo "$other" > "$T/run/lock/pid"
run_sut PATH="$T/nobin:$PATH"
[ -z "$(suspended_ids)" ] && grep -q 'SKIP another run holds the lock' "$T/log" && ok "ps unreadable → could not tell → the other instance keeps the lock" || bad "unreadable ps released the lock: '$(suspended_ids)'"
kill $ours $other 2>/dev/null; OWNERS=""

echo "S17: bd and gc inside the roster loop must not eat the loop's own list (the node's ssh shim of bd does read stdin)"
# peter-wa has a bead, so the crew that matters (batista-wa, s5) comes AFTER two crews whose bd/gc calls slurp stdin
reset_mock; base_sessions; printf '[{"id":"wa-1"}]' > "$T/mock/inprog.$RIG.peter-wa"; touch "$T/mock/bd.slurp"; run_sut
[ "$(suspended_ids)" = "ga-wisp-s2 ga-wisp-s5 " ] && ok "every bd call slurps stdin → both crews still evaluated" || bad "bd swallowed the roster: '$(suspended_ids)'"
reset_mock; base_sessions; printf '[{"id":"wa-1"}]' > "$T/mock/inprog.$RIG.peter-wa"; touch "$T/mock/gc.slurp"; run_sut
[ "$(suspended_ids)" = "ga-wisp-s2 ga-wisp-s5 " ] && ok "every gc call slurps stdin (suspend + the state read) → both crews still evaluated" || bad "gc swallowed the roster: '$(suspended_ids)'"

echo "S18: an empty field does not shift the ones after it (a session with no alias: the engine names it by its session_name)"
reset_mock
ROW_OVERRIDE='{"s2":{"alias":"","name":"digo-wa-gawisps2"}}' sessions_json s2 digo-wa digo-wa false s5 batista-wa batista-wa false > "$T/mock/sessions.json"
run_sut
[ "$(suspended_ids)" = "ga-wisp-s2 ga-wisp-s5 " ] && grep -q 'SUSPENDED crew=digo-wa id=ga-wisp-s2 ' "$T/log" && ok "empty alias in the middle of the row: template still read right, the crew is evaluated and suspended" || bad "empty field shifted the row: '$(suspended_ids)' / $(grep 'crew=digo' "$T/log" | head -2 | tr '\n' '|')"
reset_mock
ROW_OVERRIDE='{"s2":{"alias":"","name":"digo-wa-gawisps2"}}' sessions_json s2 digo-wa digo-wa false s5 batista-wa batista-wa false > "$T/mock/sessions.json"
printf '[{"id":"wa-4"}]' > "$T/mock/inprog.$RIG.digo-wa-gawisps2"; run_sut
[ "$(suspended_ids)" = "ga-wisp-s5 " ] && grep -q "KEEP crew=digo-wa .*as=digo-wa-gawisps2 " "$T/log" && ok "...and its bead (filed under the session name) still keeps it" || bad "alias-less crew lost its bead: '$(suspended_ids)'"

echo "S19: the oracle* floor looks at EVERY name the roster gives the session, not just template and alias"
for key in alias name agent_name session_name; do
  reset_mock
  ROW_OVERRIDE="{\"s2\":{\"$key\":\"oracle-spelled-$key\"}}" sessions_json s2 digo-wa digo-wa false s5 batista-wa batista-wa false > "$T/mock/sessions.json"
  run_sut
  [ "$(suspended_ids)" = "ga-wisp-s5 " ] && grep -q "KEEP crew=digo-wa id=ga-wisp-s2 reason=excluded(oracle\*) matched=oracle-spelled-$key" "$T/log" \
    && ok "a session whose $key is oracle-spelled-$key is never touched, the crew after it still is" || bad "oracle floor missed the $key name: '$(suspended_ids)' / $(grep 'crew=digo-wa' "$T/log" | head -1)"
done

echo "S20: a roster value carrying a newline and a forged row stays ONE session, never a second one"
reset_mock
ROW_OVERRIDE='{"s2":{"alias":"x\nga-wisp-forged\u001fbatista-wa\u001fbatista-wa\u001fbatista-wa\u001ffalse\u001f\u001f"}}' sessions_json s2 digo-wa digo-wa false > "$T/mock/sessions.json"
run_sut
[ "$(suspended_ids)" = "ga-wisp-s2 " ] && ! grep -q 'forged' "$T/log" && ok "the control characters became spaces: one session, no forged ga-wisp-forged row" || bad "forged row got through: '$(suspended_ids)' / $(grep -c forged "$T/log") log lines"

echo; echo "idle-crew-suspender selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
