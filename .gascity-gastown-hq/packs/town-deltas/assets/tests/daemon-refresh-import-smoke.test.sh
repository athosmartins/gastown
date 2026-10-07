#!/usr/bin/env bash
# daemon-refresh-import-smoke.test.sh — ga-n3czl1: daemon-refresh.sh must not restart a
# daemon whose merged code cannot import, and must not call a crash loop "fresh".
#
# THE INCIDENT (06/10, wa-acp18q): a route gained `from lib import dispensada`; the
# classification_dashboard's launchd sys.path (lib/ and daemons/, not the repo root)
# cannot resolve it, so it died at import and crash-looped; verify_fresh() saw a NEW
# pid started after the deploy on every respawn and reported VERDICT=OK PROOF=verified.
#
#   S1  the incident fixture: VERIFY_FAILED, the daemon is NOT kickstarted, and the
#       field/REASON say it was the import smoke (not "did not come up fresh")
#   S1b the control — the smoke switched off: the same fixture IS restarted and reported
#       OK/verified. This is what production did on 06/10, and why S1 is meaningful
#   S2  a healthy daemon is restarted and verified exactly as before
#   S3  DRY_RUN never runs the smoke (a freshness probe is not a restart)
#   S4  a sensitive daemon: the smoke runs BEFORE its drain command
#   S5  UNKNOWN (no usable interpreter) goes ahead as before and is NAMED, not hidden
#   S6  crash loop after a restart that verify_fresh called fresh -> VERIFY_FAILED
#   S7  a stable restart -> OK/verified;  S8 the documented one-time kickstart -k
#       bind race (the pid changes once, early) is NOT a crash loop;  S9 =0 turns it off
#   S10 two daemons: only the broken one is held back, the healthy one is restarted
#   S11 the JSON carries the new keys;  S12 a helper that exits 1 with no SMOKE= line is
#       UNKNOWN (an uncaught python error also exits 1 — it must not read as FAIL)
#   S13 a non-numeric RESTART_STABLE_SECS does not silently switch the check off
#
# daemon-refresh.sh runs as its own subprocess. No `pipefail` at file level: assertions
# are `X | grep` pipes and an early-exiting reader can SIGPIPE the writer under load.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"
REAL_PY3="$(command -v python3)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }
field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-import-smoke.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A plist that carries what the smoke reads: interpreter, entrypoint, WorkingDirectory
# (the repo root, as the real one has — pytest-from-root is the trap) and an env var
# that makes the entrypoint leave a footprint whenever it is imported.
make_plist() {  # make_plist <label> <entrypoint-relpath> [<interpreter>]
  local label="$1" entry="$2" interp="${3:-$RUNTIME/venv/bin/python3}"
  cat > "$AGENTS/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$interp</string>
    <string>$RUNTIME/$entry</string>
  </array>
  <key>WorkingDirectory</key><string>$RUNTIME</string>
  <key>EnvironmentVariables</key>
  <dict><key>SMOKE_SENTINEL</key><string>$CASE_DIR/imported.$label</string></dict>
</dict>
</plist>
EOF
}

# new_case <name>: a git work tree for the rig + a mock launchctl/ps.
# The mock launchctl `list` has a second mode used by S6-S9: once a label has been
# kickstarted and $MOCK/post_seq.<label> exists, each later `list` pops the first line of
# that file as the pid (the last line repeats). Deterministic — no sleeps, no races:
# the calls after a kickstart are, in order, verify_fresh, note_restart_baseline, the
# +half sample and the +full sample of verify_stable_all.
new_case() {
  CASE_DIR="$TMP_ROOT/$1"
  RUNTIME="$CASE_DIR/runtime"; AGENTS="$CASE_DIR/agents"; MOCK="$CASE_DIR/mock"; BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"
  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons/routes" "$RUNTIME/lib" "$RUNTIME/venv/bin"
  ln -sfn "$REAL_PY3" "$RUNTIME/venv/bin/python3"

  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && [ -f "$S/kicked.$label" ] && [ -f "$S/post_seq.$label" ]; then
      pid="$(head -1 "$S/post_seq.$label")"
      if [ "$(wc -l < "$S/post_seq.$label" | tr -d ' ')" -gt 1 ]; then
        tail -n +2 "$S/post_seq.$label" > "$S/post_seq.$label.tmp" && mv "$S/post_seq.$label.tmp" "$S/post_seq.$label"
      fi
      printf '\t"PID" = %s;\n' "$pid"
      exit 0
    fi
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    label="${last##*/}"
    echo "$label" >> "$S/kicks.log"
    : > "$S/kicked.$label"
    if [ -f "$S/restart_pid.$label" ]; then
      np="$(cat "$S/restart_pid.$label")"
      echo "$np" > "$S/pid.$label"
      [ -f "$S/restart_lstart.$label" ] && cat "$S/restart_lstart.$label" > "$S/start.$np"
    fi
    ;;
esac
exit 0
LCEOF
  chmod +x "$BIN/launchctl"
  cat > "$BIN/ps" <<'PSEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; pid=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && pid="$a"; prev="$a"; done
[ -n "$pid" ] && [ -f "$S/start.$pid" ] && cat "$S/start.$pid"
exit 0
PSEOF
  chmod +x "$BIN/ps"

  DEPLOY_EPOCH=$(( $(date +%s) - 600 ))
  STALE_LSTART="$(lstart_of $(( DEPLOY_EPOCH - 3600 )))"
  FRESH_LSTART="$(lstart_of $(( DEPLOY_EPOCH + 60 )))"
}

# mk_daemon <name> <route-module> <incident|healthy>: daemons/<name>.py imports the route
# the way classification_dashboard does (`from routes import <mod>`), with ONLY lib/ and
# daemons/ on its sys.path. `incident` is wa-acp18q's `from lib import ...`, which resolves
# from the repo root (a namespace package — why pytest passed) and from nowhere else.
mk_daemon() {
  local name="$1" mod="$2" kind="$3"
  echo 'FLAG = 1' > "$RUNTIME/lib/dispensada.py"
  : > "$RUNTIME/daemons/routes/__init__.py"
  if [ "$kind" = incident ]; then
    printf 'from lib import dispensada\nX = dispensada.FLAG\n' > "$RUNTIME/daemons/routes/$mod.py"
  else
    printf 'import dispensada\nX = dispensada.FLAG\n' > "$RUNTIME/daemons/routes/$mod.py"
  fi
  cat > "$RUNTIME/daemons/$name.py" <<EOF
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "lib"))
sys.path.insert(0, str(Path(__file__).parent))
if os.environ.get("SMOKE_SENTINEL"):
    open(os.environ["SMOKE_SENTINEL"], "a").write("imported\n")
from routes import $mod
if __name__ == "__main__":
    pass
EOF
  make_plist "com.test.$name" "daemons/$name.py"
  echo "$PID_SEQ" > "$MOCK/pid.com.test.$name"
  echo "$STALE_LSTART" > "$MOCK/start.$PID_SEQ"
  PID_SEQ=$((PID_SEQ + 1))
}

# seed what a restart of <label> produces; pids in $@ are what `list` returns afterwards.
seed_restart_seq() {  # seed_restart_seq <label> <pid...>
  local label="$1"; shift
  local p
  : > "$MOCK/post_seq.$label"
  for p in "$@"; do echo "$p" >> "$MOCK/post_seq.$label"; echo "$FRESH_LSTART" > "$MOCK/start.$p"; done
  echo "$1" > "$MOCK/restart_pid.$label"; echo "$FRESH_LSTART" > "$MOCK/restart_lstart.$label"
}

# deploy_and_run <changed-relpath...>: commit the fixture, change the listed files, commit again
# at DEPLOY_EPOCH and run the real daemon-refresh.sh against it.
deploy_and_run() {
  ( cd "$RUNTIME"; git add -A >/dev/null 2>&1; git commit -q -m base --allow-empty )
  PRE=$(git -C "$RUNTIME" rev-parse HEAD)
  local f
  for f in "$@"; do echo "_deploy_changed = $(date +%s%N)" >> "$RUNTIME/$f"; done
  ( cd "$RUNTIME"; git add -A >/dev/null 2>&1
    GIT_AUTHOR_DATE="@$DEPLOY_EPOCH" GIT_COMMITTER_DATE="@$DEPLOY_EPOCH" git commit -q -m deploy --allow-empty )
  POST=$(git -C "$RUNTIME" rev-parse HEAD)
  MOCK_DIR="$MOCK" RUNTIME_DIR="$RUNTIME" PRE_DEPLOY_SHA="$PRE" POST_DEPLOY_SHA="$POST" \
  DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="" \
  LAUNCH_AGENTS_DIR="$AGENTS" LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  RESTART_STABLE_SECS="${STABLE:-0}" DAEMON_SMOKE_TIMEOUT=20 \
  DAEMON_SMOKE_SCRIPT="${SMOKE_SCRIPT_OVERRIDE:-$SCRIPT_DIR/../daemon-import-smoke.py}" \
  DRY_RUN="${DRY_RUN:-0}" \
  bash "$HELPER" 2>"$CASE_DIR/stderr.log"
}
log_has() { grep -q -- "$1" "$CASE_DIR/stderr.log"; }
kicked() { grep -q "^$1\$" "$MOCK/kicks.log" 2>/dev/null; }

PID_SEQ=1100
STABLE=0

# ── S1: THE INCIDENT — import smoke blocks the restart ────────────────────────
new_case s1; STABLE=0
mk_daemon dash cls_contacts incident
seed_restart_seq com.test.dash 2001
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "VERIFY_FAILED" ] && ok "S1 VERDICT=VERIFY_FAILED" || nok "S1 verdict" "got '$(field VERDICT "$OUT")' out=[$OUT]"
[ "$RC" -ne 0 ] && ok "S1 non-zero exit (halts the delivery)" || nok "S1 exit" "rc=$RC"
kicked com.test.dash && nok "S1 daemon was kickstarted — the smoke did not block it" || ok "S1 the daemon was NOT kickstarted (the running process keeps serving the previous code)"
has "$(field IMPORT_SMOKE_FAIL "$OUT")" "com.test.dash" && ok "S1 IMPORT_SMOKE_FAIL names the daemon" || nok "S1 IMPORT_SMOKE_FAIL" "got '$(field IMPORT_SMOKE_FAIL "$OUT")'"
has "$(field FRESH_FAIL "$OUT")" "com.test.dash" && ok "S1 it is in FRESH_FAIL (the field every consumer already holds on)" || nok "S1 FRESH_FAIL" "got '$(field FRESH_FAIL "$OUT")'"
R="$(field REASON "$OUT")"
has "$R" "import smoke FAILED" && has "$R" "NOT restarted" && has "$R" "No module named 'lib'" && ok "S1 REASON says import smoke, not restarted, and why" || nok "S1 REASON" "$R"
has "$R" "did not come up fresh" && nok "S1 REASON must not claim a restart that never happened" "$R" || ok "S1 REASON does not say 'did not come up fresh'"
[ -z "$(field RESTARTED "$OUT")" ] && ok "S1 RESTARTED is empty" || nok "S1 RESTARTED" "got '$(field RESTARTED "$OUT")'"
[ "$(field PROOF "$OUT")" = "not_verified" ] && ok "S1 PROOF=not_verified" || nok "S1 proof" "got '$(field PROOF "$OUT")'"
[ -s "$CASE_DIR/imported.com.test.dash" ] && ok "S1 premise: the smoke really did import the entrypoint" || nok "S1 premise" "no import footprint"

# ── S1b: the control — smoke OFF: restarted, OK, verified (production, 06/10) ──
new_case s1b; STABLE=0
mk_daemon dash cls_contacts incident
seed_restart_seq com.test.dash 2001
OUT=$(SMOKE_SCRIPT_OVERRIDE=/nonexistent/smoke.py deploy_and_run daemons/routes/cls_contacts.py); RC=$?
kicked com.test.dash && ok "S1b control: with no smoke the broken daemon IS restarted" || nok "S1b control" "not kicked: $OUT"
[ "$(field VERDICT "$OUT")" = "OK" ] && [ "$(field PROOF "$OUT")" = "verified" ] && ok "S1b control: and reported OK / verified — the 06/10 false green" || nok "S1b control verdict" "got '$(field VERDICT "$OUT")'/'$(field PROOF "$OUT")'"
has "$(field IMPORT_SMOKE_UNKNOWN "$OUT")" "com.test.dash" && ok "S1b the missing smoke is NAMED in IMPORT_SMOKE_UNKNOWN" || nok "S1b UNKNOWN field" "got '$(field IMPORT_SMOKE_UNKNOWN "$OUT")'"

# ── S2: a healthy daemon is restarted and verified as before ──────────────────
new_case s2; STABLE=0
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "OK" ] && [ "$RC" -eq 0 ] && [ "$(field PROOF "$OUT")" = "verified" ] && ok "S2 healthy daemon: OK / verified / rc=0" || nok "S2" "got '$(field VERDICT "$OUT")' rc=$RC out=[$OUT]"
kicked com.test.dash && ok "S2 it was restarted" || nok "S2 restart" "not kicked"
[ -z "$(field IMPORT_SMOKE_FAIL "$OUT")" ] && [ -z "$(field IMPORT_SMOKE_UNKNOWN "$OUT")" ] && ok "S2 smoke fields are empty" || nok "S2 smoke fields" "fail='$(field IMPORT_SMOKE_FAIL "$OUT")' unknown='$(field IMPORT_SMOKE_UNKNOWN "$OUT")'"
log_has "import smoke com.test.dash: PASS" && ok "S2 the log says PASS" || nok "S2 log" "$(grep 'import smoke' "$CASE_DIR/stderr.log")"

# ── S3: DRY_RUN never runs the smoke ──────────────────────────────────────────
new_case s3; STABLE=0
mk_daemon dash cls_contacts incident
OUT=$(DRY_RUN=1 deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ ! -e "$CASE_DIR/imported.com.test.dash" ] && ok "S3 DRY_RUN: the entrypoint was never imported" || nok "S3 DRY_RUN ran the smoke"
[ ! -f "$MOCK/kicks.log" ] && ok "S3 DRY_RUN: nothing restarted" || nok "S3 kicked in DRY_RUN"
[ -z "$(field IMPORT_SMOKE_FAIL "$OUT")" ] && ok "S3 DRY_RUN: no smoke verdict recorded" || nok "S3 field" "got '$(field IMPORT_SMOKE_FAIL "$OUT")'"

# ── S4: sensitive daemon — the smoke comes BEFORE the drain ───────────────────
new_case s4; STABLE=0
mk_daemon dash cls_contacts incident
seed_restart_seq com.test.dash 2001
OUT=$(SENSITIVE_DAEMONS="dash" DRAIN_CMD_com_test_dash="touch $CASE_DIR/drained" deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "VERIFY_FAILED" ] && ok "S4 sensitive + broken: VERIFY_FAILED" || nok "S4 verdict" "got '$(field VERDICT "$OUT")' out=[$OUT]"
[ ! -e "$CASE_DIR/drained" ] && ok "S4 the drain command did NOT run (intake is never paused for code that cannot start)" || nok "S4 drain ran before the smoke"
kicked com.test.dash && nok "S4 kicked" "" || ok "S4 not kickstarted"
new_case s4b; STABLE=0
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001
OUT=$(SENSITIVE_DAEMONS="dash" DRAIN_CMD_com_test_dash="touch $CASE_DIR/drained" deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ -e "$CASE_DIR/drained" ] && kicked com.test.dash && [ "$(field VERDICT "$OUT")" = "OK" ] && ok "S4b control: healthy sensitive daemon drains, restarts, OK" || nok "S4b control" "verdict '$(field VERDICT "$OUT")' drained=$([ -e "$CASE_DIR/drained" ] && echo y || echo n)"

# ── S5: UNKNOWN (no usable interpreter) goes ahead — and is named ─────────────
new_case s5; STABLE=0
mk_daemon dash cls_contacts healthy
make_plist com.test.dash daemons/dash.py "$RUNTIME/venv/bin/no-such-python"
seed_restart_seq com.test.dash 2001
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
kicked com.test.dash && [ "$(field VERDICT "$OUT")" = "OK" ] && ok "S5 UNKNOWN does not block: restarted, OK (as before this change)" || nok "S5" "verdict '$(field VERDICT "$OUT")'"
has "$(field IMPORT_SMOKE_UNKNOWN "$OUT")" "com.test.dash" && ok "S5 IMPORT_SMOKE_UNKNOWN names it" || nok "S5 field" "got '$(field IMPORT_SMOKE_UNKNOWN "$OUT")'"
log_has "import smoke com.test.dash: UNKNOWN" && ok "S5 the log says UNKNOWN, not PASS" || nok "S5 log" "$(grep 'import smoke' "$CASE_DIR/stderr.log")"

# ── S6: crash loop AFTER a restart that verify_fresh called fresh ─────────────
# pids after the kickstart: verify_fresh=2001, baseline=2001, +half=2002, +full=2003.
new_case s6; STABLE=2
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001 2001 2002 2003
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "VERIFY_FAILED" ] && [ "$RC" -ne 0 ] && ok "S6 crash loop: VERIFY_FAILED, non-zero exit" || nok "S6 verdict" "got '$(field VERDICT "$OUT")' rc=$RC out=[$OUT]"
has "$(field RESTART_UNSTABLE "$OUT")" "com.test.dash" && has "$(field FRESH_FAIL "$OUT")" "com.test.dash" && ok "S6 RESTART_UNSTABLE and FRESH_FAIL name it" || nok "S6 fields" "unstable='$(field RESTART_UNSTABLE "$OUT")' fresh_fail='$(field FRESH_FAIL "$OUT")'"
has "$(field REASON "$OUT")" "did not STAY up" && ok "S6 REASON says it did not stay up" || nok "S6 REASON" "$(field REASON "$OUT")"
has "$(field RESTARTED "$OUT")" "com.test.dash" && ok "S6 it was restarted (RESTARTED lists it)" || nok "S6 RESTARTED" "got '$(field RESTARTED "$OUT")'"

# ── S7: a stable restart -> OK / verified ─────────────────────────────────────
new_case s7; STABLE=2
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "OK" ] && [ "$(field PROOF "$OUT")" = "verified" ] && ok "S7 stable restart: OK / verified" || nok "S7" "got '$(field VERDICT "$OUT")' out=[$OUT]"
log_has "STABLE" && ok "S7 the log records the stability verdict" || nok "S7 log" "$(grep stability "$CASE_DIR/stderr.log")"

# ── S8: the kickstart -k bind race — the pid changes ONCE, early — is not a loop ─
new_case s8; STABLE=2
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001 2001 2002 2002
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "OK" ] && ok "S8 one early pid change that then holds: OK (not a crash loop)" || nok "S8" "got '$(field VERDICT "$OUT")' reason='$(field REASON "$OUT")'"
log_has "changed once" && ok "S8 the log notes the pid changed once" || nok "S8 log" "$(grep stability "$CASE_DIR/stderr.log")"

# ── S9: RESTART_STABLE_SECS=0 turns the stability check off ───────────────────
new_case s9; STABLE=0
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001 2001 2002 2003
OUT=$(deploy_and_run daemons/routes/cls_contacts.py); RC=$?
[ "$(field VERDICT "$OUT")" = "OK" ] && ok "S9 RESTART_STABLE_SECS=0: a pid flip is not looked at" || nok "S9" "got '$(field VERDICT "$OUT")'"

# ── S10: two daemons — only the broken one is held back ───────────────────────
new_case s10; STABLE=0
mk_daemon bad cls_bad incident
mk_daemon good cls_good healthy
seed_restart_seq com.test.bad 2001
seed_restart_seq com.test.good 2101
OUT=$(deploy_and_run daemons/routes/cls_bad.py daemons/routes/cls_good.py); RC=$?
[ "$(field VERDICT "$OUT")" = "VERIFY_FAILED" ] && ok "S10 mixed batch: VERIFY_FAILED" || nok "S10 verdict" "got '$(field VERDICT "$OUT")' out=[$OUT]"
kicked com.test.good && ! kicked com.test.bad && ok "S10 the healthy daemon was restarted, the broken one was not" || nok "S10 kicks" "$(cat "$MOCK/kicks.log" 2>/dev/null)"
[ "$(field IMPORT_SMOKE_FAIL "$OUT")" = "com.test.bad" ] && [ "$(field RESTARTED "$OUT")" = "com.test.good" ] && ok "S10 IMPORT_SMOKE_FAIL=bad, RESTARTED=good" || nok "S10 fields" "fail='$(field IMPORT_SMOKE_FAIL "$OUT")' restarted='$(field RESTARTED "$OUT")'"
has "$(field REASON "$OUT")" "com.test.good" && nok "S10 REASON blames the healthy daemon" "$(field REASON "$OUT")" || ok "S10 REASON names only the broken daemon"

# ── S11: the trailing JSON carries the new keys ───────────────────────────────
JSON_LINE="$(echo "$OUT" | grep '^JSON=' | head -1 | sed 's/^JSON=//')"
echo "$JSON_LINE" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["import_smoke_fail"] == ["com.test.bad"], d["import_smoke_fail"]
assert d["import_smoke_unknown"] == [] and d["restart_unstable"] == [], (d["import_smoke_unknown"], d["restart_unstable"])
assert "com.test.bad" in d["fresh_fail"]
' 2>"$CASE_DIR/json.err" && ok "S11 JSON has import_smoke_fail / import_smoke_unknown / restart_unstable" || nok "S11 JSON" "$(cat "$CASE_DIR/json.err" | tail -2) json=[$JSON_LINE]"

# ── S12: a helper that exits 1 with no SMOKE= line is UNKNOWN, not FAIL ───────
new_case s12; STABLE=0
mk_daemon dash cls_contacts healthy
seed_restart_seq com.test.dash 2001
printf 'import sys\nsys.exit(1)\n' > "$CASE_DIR/crashing-smoke.py"
OUT=$(SMOKE_SCRIPT_OVERRIDE="$CASE_DIR/crashing-smoke.py" deploy_and_run daemons/routes/cls_contacts.py); RC=$?
kicked com.test.dash && [ "$(field VERDICT "$OUT")" = "OK" ] && ok "S12 a crashing smoke script does not hold a delivery (exit 1 is not a verdict)" || nok "S12" "verdict '$(field VERDICT "$OUT")'"
has "$(field IMPORT_SMOKE_UNKNOWN "$OUT")" "com.test.dash" && ok "S12 and it is listed as UNKNOWN" || nok "S12 field" "got '$(field IMPORT_SMOKE_UNKNOWN "$OUT")'"

# ── S13: a non-numeric RESTART_STABLE_SECS warns and falls back, not silent-off ─
new_case s13; STABLE=abc
mk_daemon dash cls_contacts healthy
OUT=$(deploy_and_run README.md 2>/dev/null); RC=$?
log_has "RESTART_STABLE_SECS='abc' is not a non-negative integer" && ok "S13 a bad RESTART_STABLE_SECS warns and falls back" || nok "S13" "stderr: $(head -3 "$CASE_DIR/stderr.log")"

echo
echo "daemon-refresh-import-smoke.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
