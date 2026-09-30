#!/usr/bin/env bash
# reaper-selftest-path-leak.selftest.sh — ga-d21b40: prove that the reaper selftests can no longer reach the
# REAL `gc` / `bd`, even when the fixture dir holding their stubs disappears while the reaper is running.
#
# THE BUG: the selftests ran reaper.sh with PATH="$T/bin:$PATH", `$T/bin/gc` being a logging stub. When the
# harness died and $T went away mid-run, reaper.sh's `command -v gc` walked on down $PATH and found the real
# /opt/homebrew/bin/gc: `gc mail send mayor/` went out for real (29/09, two false "Reaper anomalies"
# escalations to the Mayor quoting selftest scratch paths).
#
#   A  the helper (selftest-sandbox-path.lib.sh) in isolation: the stub wins while it exists, NOTHING
#      resolves once it is gone, gc/bd can never be linked in as "harmless tools", a missing tool is refused
#   B  end to end, per reaper selftest (count / sweep / schema-purge): run the REAL selftest with SENTINEL
#      `gc` and `bd` placed first on the harness's own PATH (so they stand in for "the real ones" and the real
#      ones are never touched by this test), wait until the reaper is running, delete the stub dir out from
#      under it, let the reaper finish, and require that the sentinels were never called.
#      On the pre-fix selftests the reaper's final `gc session nudge deacon/ ...` lands on the sentinel: this
#      section FAILS there — the same leak, caught in a cage.
#
# Fail CLOSED: if the selftest never reaches the reaper, or the reaper never finishes, that is a FAIL, not a
# green run (an empty sentinel log proves nothing if the reaper did not run).
#
# Cost (this test is run by a reviewer with a wall-clock budget, on a box at load ~50): the three probes run IN
# PARALLEL, and each selftest harness is killed the moment its verdict is in — the verdict needs only the FIRST
# reaper run of each selftest, so the rest of the selftest (the part that takes minutes) is never waited for and
# never left running in the background to load the box. LEAK_ONLY=count|sweep|schema-purge runs a single probe.
# Bound on a slow box: B waits up to LEAK_WAIT_S (default 400) for the reaper to start and again for it to end.
# LEAK_ASSETS_DIR points the driver at another copy of the selftests (used to replay the pre-fix files).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="${LEAK_ASSETS_DIR:-$HERE}"
LEAK_WAIT_S="${LEAK_WAIT_S:-400}"
LIB="$HERE/selftest-sandbox-path.lib.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reaper-path-leak-selftest.XXXXXX")" || exit 1
kill_tree() {  # kill_tree <pid> — the pid and all its descendants, deepest first (by pid: no pattern kills)
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
  kill "$1" 2>/dev/null
  return 0
}
kill_harness() {  # kill_harness <pid> — only if it is STILL a selftest harness: a recycled pid is never touched
  if ps -o command= -p "${1:-0}" 2>/dev/null | grep -q '[.]selftest[.]sh'; then kill_tree "$1"; fi
  return 0
}
# The probes run in subshells, whose variables the parent cannot see: each records its harness pid in
# $ROOT/<tag>.hpid (removed once that harness has been killed) and the EXIT trap reaps whatever is left.
cleanup() {
  local f p
  for f in "$ROOT"/*.hpid; do
    [ -f "$f" ] || continue
    p="$(cat "$f" 2>/dev/null)"; [ -n "$p" ] && kill_harness "$p"
  done
  sleep 1; rm -rf "$ROOT"
}
trap cleanup EXIT

# ══ A: the helper in isolation ═══════════════════════════════════════════════════════════════════════════
echo "A: sandbox_path_init"
if [ ! -f "$LIB" ]; then
  nok "A0 the helper is missing ($LIB) — nothing to test, and the selftests it protects cannot start either"
else
  . "$LIB" || { echo "FATAL: cannot source $LIB" >&2; exit 2; }
  TA="$ROOT/a"; mkdir -p "$TA/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TA/bin/gc"; cp "$TA/bin/gc" "$TA/bin/bd"; chmod +x "$TA/bin/gc" "$TA/bin/bd"
  if sandbox_path_init "$TA" jq; then
    ok "A1 sandbox_path_init succeeds for a harmless tool"
    [ "$(PATH="$SANDBOX_PATH" command -v gc)" = "$TA/bin/gc" ] && [ "$(PATH="$SANDBOX_PATH" command -v bd)" = "$TA/bin/bd" ] \
      && ok "A2 while the stubs exist they are what gc/bd resolve to" || nok "A2 the stubs do not win" "gc=$(PATH="$SANDBOX_PATH" command -v gc) bd=$(PATH="$SANDBOX_PATH" command -v bd)"
    [ -L "$TA/tools/jq" ] && ok "A3 the harmless tool is a symlink INSIDE the fixture (it goes away with it)" || nok "A3 no link in tools/"
    rm -rf "$TA/bin" "$TA/tools"
    if PATH="$SANDBOX_PATH" command -v gc >/dev/null 2>&1 || PATH="$SANDBOX_PATH" command -v bd >/dev/null 2>&1; then
      nok "A4 after the fixture is gone gc/bd STILL resolve" "gc=$(PATH="$SANDBOX_PATH" command -v gc) bd=$(PATH="$SANDBOX_PATH" command -v bd)"
    else
      ok "A4 after the fixture is gone NEITHER gc nor bd resolves (the inert outcome)"
    fi
    # positive control: on a box that HAS a real gc, the OLD pattern would have found it — so A4 means something
    if command -v gc >/dev/null 2>&1; then
      [ -n "$(PATH="$TA/bin:$PATH" command -v gc)" ] && ok "A5 (control) the old PATH=\"\$T/bin:\$PATH\" pattern still reaches the real gc here — the hole was real" || nok "A5 control failed"
    else
      echo "  note - A5 skipped: no real gc on this box's PATH to use as the control"
    fi
  else
    nok "A1 sandbox_path_init failed for a harmless tool"
  fi
  TA2="$ROOT/a2"; mkdir -p "$TA2/bin"
  ( sandbox_path_init "$TA2" gc ) >/dev/null 2>&1 && nok "A6 gc was accepted as a 'harmless tool'" || ok "A6 gc cannot be linked in as a harmless tool"
  ( sandbox_path_init "$TA2" bd ) >/dev/null 2>&1 && nok "A7 bd was accepted as a 'harmless tool'" || ok "A7 bd cannot be linked in as a harmless tool"
  ( sandbox_path_init "$TA2" no-such-tool-ga-d21b40 ) >/dev/null 2>&1 && nok "A8 a missing tool was accepted" || ok "A8 a missing required tool is refused (fail closed)"
  ( sandbox_path_init "$ROOT/does-not-exist" jq ) >/dev/null 2>&1 && nok "A9 a missing stub dir was accepted" || ok "A9 a missing stub dir is refused"
fi

# ══ B: end to end, against the real reaper selftests ═════════════════════════════════════════════════════
reaper_main_pid() {  # reaper_main_pid <scratch-root> — the outermost process running <root>/**/scripts/reaper.sh
  local all p pp
  all="$(pgrep -f -- "$1/.*scripts/reaper[.]sh" 2>/dev/null | tr '\n' ' ')"
  [ -n "${all// /}" ] || return 1
  for p in $all; do
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    case " $all " in *" $pp "*) continue ;; esac
    echo "$p"; return 0
  done
  return 1
}

# leak_probe <tag> <selftest file> — sets PROBE_RESULT (ok|nok) and PROBE_WHY
leak_probe() {
  local tag="$1" st="$2" W="$ROOT/$tag" SENT="$ROOT/$tag-sentinel" LOG="$ROOT/$tag-sentinel.log" c hpid main cmd T t0 waited
  mkdir -p "$W" "$SENT"; : > "$LOG"
  for c in gc bd; do
    printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\nexit 0\n' "$c" "$LOG" > "$SENT/$c"; chmod +x "$SENT/$c"
  done
  [ -f "$ASSETS/$st" ] || { PROBE_RESULT=nok; PROBE_WHY="selftest not found: $ASSETS/$st"; return; }
  # SLOW_RE/SLOW_S: the harnesses that support it hold the reaper's first statement for a few seconds, so the
  # stub dir is deleted while the reaper is demonstrably mid-run (the others are simply fast enough to race it).
  ( cd "$ASSETS" && exec env TMPDIR="$W" PATH="$SENT:$PATH" SLOW_RE='SHOW DATABASES' SLOW_S=6 /bin/bash "$st" >"$ROOT/$tag.out" 2>&1 ) &
  hpid=$!; echo "$hpid" > "$ROOT/$tag.hpid"
  t0=$SECONDS; main=""
  while [ $((SECONDS - t0)) -lt "$LEAK_WAIT_S" ]; do
    main="$(reaper_main_pid "$W")" && [ -n "$main" ] && break
    main=""
    kill -0 "$hpid" 2>/dev/null || break
    sleep 0.1
  done
  if [ -z "$main" ]; then
    PROBE_RESULT=nok; PROBE_WHY="the selftest never reached its reaper run (rc/out: $(tail -n 3 "$ROOT/$tag.out" 2>/dev/null | tr '\n' '|'))"; return
  fi
  cmd="$(ps -o command= -p "$main" 2>/dev/null)"
  T="${cmd##* }"; T="${T%/scripts/reaper.sh}"
  if [ -z "$T" ] || [ ! -d "$T/bin" ]; then
    PROBE_RESULT=nok; PROBE_WHY="could not locate the stub dir of the running reaper (cmd: $cmd)"; return
  fi
  rm -rf "$T/bin" "$T/tools"          # the fixture vanishes under a running reaper
  [ -e "$T/bin" ] && { PROBE_RESULT=nok; PROBE_WHY="could not delete the stub dir $T/bin"; return; }
  waited=0
  while kill -0 "$main" 2>/dev/null; do
    [ "$waited" -ge $((LEAK_WAIT_S * 10)) ] && { PROBE_RESULT=nok; PROBE_WHY="the reaper (pid $main) never finished"; return; }
    sleep 0.1; waited=$((waited + 1))
  done
  sleep 3                             # the reaper's last act (the DOG_DONE nudge) follows its summary
  if [ -s "$LOG" ]; then
    PROBE_RESULT=nok; PROBE_WHY="the REAL-gc/bd stand-ins were called after the stubs vanished: $(head -n 3 "$LOG" | cut -c1-110 | tr '\n' '|')"
  else
    PROBE_RESULT=ok; PROBE_WHY=""
  fi
}

echo "B: the reaper selftests, stub dir deleted under a running reaper"
PAIRS="count:reaper-orphan-count.selftest.sh sweep:reaper-orphan-sweep.selftest.sh schema-purge:reaper-schema-purge.selftest.sh"
RAN=0
for pair in $PAIRS; do   # launch: one background probe per selftest; each writes its verdict to $ROOT/<tag>.result
  tag="${pair%%:*}"; st="${pair#*:}"
  case "${LEAK_ONLY:-}" in ""|"$tag") ;; *) continue ;; esac
  RAN=$((RAN+1))
  (
    leak_probe "$tag" "$st"
    # the verdict is in: stop the harness NOW, its remaining minutes of selftest prove nothing here
    hp="$(cat "$ROOT/$tag.hpid" 2>/dev/null)"; [ -n "$hp" ] && kill_harness "$hp"; rm -f "$ROOT/$tag.hpid"
    printf '%s\n%s\n' "$PROBE_RESULT" "$PROBE_WHY" > "$ROOT/$tag.result"
  ) &
done
[ "$RAN" -gt 0 ] || nok "B0 LEAK_ONLY='${LEAK_ONLY:-}' matches no probe (count | sweep | schema-purge) — nothing was tested"
wait
for pair in $PAIRS; do   # report in a fixed order; a probe that left no verdict is a FAIL, never a silent pass
  tag="${pair%%:*}"; st="${pair#*:}"
  case "${LEAK_ONLY:-}" in ""|"$tag") ;; *) continue ;; esac
  PROBE_RESULT="$(sed -n 1p "$ROOT/$tag.result" 2>/dev/null)"; PROBE_WHY="$(sed -n 2p "$ROOT/$tag.result" 2>/dev/null)"
  [ -n "$PROBE_RESULT" ] || { PROBE_RESULT=nok; PROBE_WHY="the probe left no verdict (its subshell died)"; }
  if [ "$PROBE_RESULT" = ok ]; then
    ok "B-$tag $st: no gc/bd call escaped after the stub dir vanished mid-run"
  else
    nok "B-$tag $st" "$PROBE_WHY"
  fi
done

echo ""
echo "reaper-selftest-path-leak selftest (ga-d21b40): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
