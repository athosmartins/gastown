#!/usr/bin/env bash
# daemon-refresh-comment-only-diff.test.sh — regression test for ga-jjgcaw.
# Runs the REAL daemon-refresh.sh (same harness style as
# daemon-refresh-noop-pull-bead-fallback.test.sh: a standalone, env-var-driven
# script, mock launchctl/ps, throwaway git repo as RUNTIME_DIR).
#
# THE BUG (measured 29/09, wa-7oqxq): commit 36146a6ba changed lib/
# human_name_guard.py ONLY in comment lines (`ast.dump` of the old and new file
# is identical). daemon-refresh.sh still counted the file as changed, matched it
# against every daemon that imports it, and HALTED the delivery asking for a
# guarded restart of three daemons — one of them conversation-monitor, which
# processes inbound messages — for a restart that changes nothing: the running
# process already executes the identical AST. The Mayor released four such
# halts by hand that day, each time proving the AST equality manually.
#
# THE FIX: a changed *.py file whose old and new versions parse to the SAME AST
# (comments, blank lines, formatting) is dropped from the changed set before any
# closure/import matching. Everything else stays in — added/deleted files,
# docstring edits, shebang edits, files that do not parse, mode-only changes.
# "Could not tell" keeps the file: the halt is the inert direction here.
#
# T1 (the incident): comment-only lib edit, sensitive daemon imports it, daemon
#    is stale -> OK/not_applicable, exit 0, nothing GUARDED.
# T2: blank-line + quote-style + wrapping changes only (AST-identical) -> OK.
# T3 (control): a real code change to the same lib -> still NEEDS_GUARDED_RESTART.
# T4: docstring-only change -> still flagged (docstrings are served at runtime by
#    click/argparse/FastAPI, and __doc__ is readable; not provably cosmetic).
# T5: shebang-only change -> still flagged (a restart is the only way a running
#    process picks up a different interpreter).
# T6: new version does not parse -> still flagged (cannot tell).
# T7: brand-new lib file (no old blob) -> still flagged. The daemon file is
#    byte-identical across the deploy, so the ADDED lib is the only changed path.
# T8 (per-daemon precision, the incident's own shape): two daemons, one imports
#    only the comment-only file, the other a really-changed file -> only the
#    second is GUARDED.
# T9: the per-daemon baseline narrowing path (DAEMON_BASELINE_OVERRIDES) drops
#    the comment-only file too: a label whose OWN window since its last-clean
#    point contains only the comment-only edit is downgraded, not re-halted.
# T10: mode-only change (chmod +x, same bytes) -> still flagged.
# T11: DELETED lib file (no new blob), daemon file unchanged -> still flagged.
# T12: lib path whose blob is unreadable on BOTH sides (a gitlink) -> still flagged.
# T13: comment-only edit on a file over the 2 MiB cap -> still flagged.
# T14: the classifier itself fails (T1's exact fixture) -> the raw list is kept,
#    the delivery is still flagged, and the failure is logged.
# T15: same for the per-daemon narrowing path (T9's exact fixture): a failed
#    classifier must not downgrade the label, and the failure must be logged.
# T16-T31 (gate ga-yxz43u): the same fix with the rig-owned detector PRESENT — the
#    branch production takes for every WA daemon, which T1-T15 never ran (the
#    fixture had no scripts/detect_stale_daemons.py, so RIG_DETECTOR_USED was 0 in
#    every case). The case list and why the stub is not seeded are in the block
#    before T16. Held to account the same way: each keep-branch of
#    rig_detector_cosmetic_only, and each line that applies the downgrade, was
#    mutated on a copy of the script and the suite re-run — 17 mutants, all killed
#    (E1 not-all-covered -> T24, template -> T25, no pid -> T26, start unreadable
#    -> T20, no base commit -> T29, diff fails -> T30, empty file set -> T21,
#    unparsable entry -> T27, classifier fails -> T22, non-cosmetic file ->
#    T18/T19/T31, FORCE label -> T23, assets -> T19, closure -> T31, imports ->
#    T16, window instead of process start -> T17/T18, AFFECTED / AFFECTED_RIG_
#    DETECTOR not updated -> T16). Against the script without Step 3b, T16, T17
#    and T28 fail on behavior; the rest fail on the logged reason.
#
# HOW THESE TESTS ARE HELD TO ACCOUNT (gate ga-w1cl44): a keep-case is only worth
# having if it FAILS when the branch that keeps the file is inverted; a keep-case
# whose fixture also changes something else passes through that other change
# (the first T7 did — it rewrote the daemon's own import as well). So (1) each
# case asserts its premise — the deploy diff is exactly the path under test — and
# (2) each "could not tell -> keep" branch of cosmetic_py_classify was mutated to
# "drop" on a copy of the script and the suite re-run: added -> T7, deleted ->
# T11, both blobs unreadable -> T12, oversize -> T13, shebang -> T5, unparsable ->
# T6, mode-only (identical bytes) -> T10, docstring -> T4, classifier failure ->
# T14/T15, narrowing -> T9. T14/T15 reuse the T1/T9 fixtures byte for byte, so the
# ONLY variable is whether the classifier works.

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# pipes; under pipefail an early-exiting reader can SIGPIPE the writer and turn
# a PASSING assertion into a false FAIL under load. daemon-refresh.sh runs as
# its own subprocess with its own `set` options.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"
# ga-n3czl1: this suite tests restart/verify behaviour, not the post-restart stability
# window (default 60 s per restart) — off here; tests/daemon-refresh-import-smoke.test.sh
# (S6-S9) is the suite that turns it on.
export RESTART_STABLE_SECS="${RESTART_STABLE_SECS:-0}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

field() { echo "$2" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

lstart_of() { date -r "$1" "+%a %b %e %T %Y"; }

make_plist() {  # make_plist <dir> <label> <prog-arg> [<prog-arg>...]
  local dir="$1" label="$2"; shift 2
  local args="" a
  for a in "$@"; do args="$args      <string>$a</string>
"; done
  cat > "$dir/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
</dict>
</plist>
EOF
}

new_case() {
  local name="$1"
  CASE_DIR="$TMP_ROOT/$name"
  RUNTIME="$CASE_DIR/runtime"; AGENTS="$CASE_DIR/agents"; MOCK="$CASE_DIR/mock"; BIN="$CASE_DIR/bin"
  mkdir -p "$RUNTIME" "$AGENTS" "$MOCK" "$BIN"

  git -C "$RUNTIME" init -q
  git -C "$RUNTIME" config user.email t@t.t
  git -C "$RUNTIME" config user.name t
  mkdir -p "$RUNTIME/daemons" "$RUNTIME/lib" "$RUNTIME/launchd"

  cat > "$BIN/launchctl" <<'LCEOF'
#!/usr/bin/env bash
S="$MOCK_DIR"; cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    label="${1:-}"
    if [ -n "$label" ] && { [ -f "$S/pid.$label" ] || [ -f "$S/loaded.$label" ]; }; then
      [ -f "$S/pid.$label" ] && printf '\t"PID" = %s;\n' "$(cat "$S/pid.$label")"
      exit 0
    fi
    echo "Could not find service \"$label\" in domain for port" >&2
    exit 1
    ;;
  kickstart)
    last=""; for a in "$@"; do last="$a"; done
    echo "${last##*/}" >> "$S/kicks.log"
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
}

seed_running() { echo "$2" > "$MOCK/pid.$1"; echo "$3" > "$MOCK/start.$2"; }

# a daemon <name> (file daemons/<name>.py) that imports lib/<module>.py, plus
# its launchd wrapper and plist. Sensitive by SENSITIVE_DAEMONS substring
# match, running since long before any commit in the case (i.e. STALE).
add_daemon() {  # add_daemon <name> <lib-module> <pid>
  local name="$1" mod="$2" pid="$3"
  printf 'from lib.%s import guard\nprint(guard())\n' "$mod" > "$RUNTIME/daemons/$name.py"
  cat > "$RUNTIME/launchd/$name-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/$name.py"
EOF
  make_plist "$AGENTS" "com.test.${name//_/-}" /bin/bash "$RUNTIME/launchd/$name-wrapper.sh"
  seed_running "com.test.${name//_/-}" "$pid" "$STALE_LSTART"
}

commit_at() {  # commit_at <epoch> <message>
  git -C "$RUNTIME" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="@$1" GIT_COMMITTER_DATE="@$1" git -C "$RUNTIME" commit -q -m "$2"
}

# commit_index_at <epoch> <message>: commit the index AS IS. commit_at's `add -A`
# would drop a gitlink staged with update-index (its path is not in the worktree).
commit_index_at() {
  GIT_AUTHOR_DATE="@$1" GIT_COMMITTER_DATE="@$1" git -C "$RUNTIME" commit -q -m "$2"
}

# only_changed <label> <pre> <post> <path>: the case's PREMISE — the deploy diff
# is exactly <path>. A keep-case whose fixture also changes another file (the
# daemon's own, say) is flagged through that file whatever the classifier does
# with <path>, and passes without testing anything (gate ga-w1cl44, first T7).
only_changed() {
  local got; got="$(git -C "$RUNTIME" diff --name-only "$2" "$3")"
  [ "$got" = "$4" ] && ok "$1 premise: the deploy diff is exactly $4" \
    || nok "$1 premise: the deploy diff is not just $4" "got [$got]"
}

# invoke_helper <pre_sha> <post_sha>   (DAEMON_BASELINE_OVERRIDES, HELPER_PATH read from env)
invoke_helper() {
  PATH="${HELPER_PATH:-$PATH}" \
  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$1" POST_DEPLOY_SHA="$2" \
  DEPLOY_EPOCH="$NOW" \
  SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}" \
  DAEMON_BASELINE_OVERRIDES="${DAEMON_BASELINE_OVERRIDES:-}" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="${FORCE_RESTART_LABELS:-}" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>"$CASE_DIR/stderr.log"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-comment-only.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# A python3 that fails ONLY when daemon-refresh.sh runs its cosmetic classifier
# (`python3 - <pre> <post>` with COSMETIC_CHANGED in the environment) and defers
# to the real one for everything else. Put it first on PATH with HELPER_PATH.
REAL_PY3="$(command -v python3)"
FAILING_CLASSIFIER_DIR="$TMP_ROOT/failing-classifier"
mkdir -p "$FAILING_CLASSIFIER_DIR"
cat > "$FAILING_CLASSIFIER_DIR/python3" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "-" ] && [ -n "\${COSMETIC_CHANGED+x}" ]; then exit 1; fi
exec "$REAL_PY3" "\$@"
EOF
chmod +x "$FAILING_CLASSIFIER_DIR/python3"

NOW=$(date +%s)
CHANGE_EPOCH=$((NOW - 300))
STALE_LSTART="$(lstart_of $((CHANGE_EPOCH - 3600)))"   # daemon up 1h BEFORE the change
SENSITIVE_DAEMONS="central-sender webhook-receiver"

LIB_V1='# guard for human names
SEMPTY = ("sem nome", "")


def guard():
    """Return the verdict."""
    x = {"a": 1}
    return x["a"]
'

# run_lib_case <case-name> <lib-v2-content> -> sets OUT RC V P G
run_lib_case() {
  local name="$1" v2="$2"
  new_case "$name"
  printf '%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
  add_daemon central_sender human_name_guard 4001
  commit_at $((CHANGE_EPOCH - 7200)) base
  C0=$(git -C "$RUNTIME" rev-parse HEAD)
  printf '%s' "$v2" > "$RUNTIME/lib/human_name_guard.py"
  commit_at "$CHANGE_EPOCH" "lib change"
  C1=$(git -C "$RUNTIME" rev-parse HEAD)
  only_changed "$(echo "$name" | tr a-z A-Z)" "$C0" "$C1" lib/human_name_guard.py
  OUT=$(invoke_helper "$C0" "$C1"); RC=$?
  V=$(field VERDICT "$OUT"); P=$(field PROOF "$OUT"); G=$(field GUARDED "$OUT")
}

# ════════════════════════════════════════════════════════════════════════════
# T1: the incident — comment-only edit to an imported lib
# ════════════════════════════════════════════════════════════════════════════
COMMENT_ONLY_V2='# guard for human names
# wa-rhfeg: comentario novo explicando a lista abaixo,
# em varias linhas, sem mudar uma unica instrucao.
SEMPTY = ("sem nome", "")  # trailing comment too


def guard():
    """Return the verdict."""
    x = {"a": 1}
    return x["a"]
'
run_lib_case t1 "$COMMENT_ONLY_V2"
[ "$RC" -eq 0 ] && ok "T1 exit 0 — a comment-only lib edit does not hold the delivery" \
  || nok "T1 exit" "rc=$RC verdict=$V guarded=[$G]"
[ "$V" = "OK" ] && ok "T1 verdict OK (got '$V')" || nok "T1 verdict" "got '$V' out=[$OUT]"
[ "$P" = "not_applicable" ] && ok "T1 PROOF=not_applicable (no daemon code changed)" \
  || nok "T1 proof" "got '$P'"
[ -z "${G// /}" ] && ok "T1 GUARDED empty — the stale sensitive daemon is not flagged" \
  || nok "T1 guarded" "[$G]"
# Anchored on the drop line itself: 'comment/format-only' ALSO appears in the
# classifier-failure WARN and in the early-OK line, so matching it could not tell
# a real drop from a failed classifier.
grep -q 'ignoring [0-9]* python file' "$CASE_DIR/stderr.log" \
  && ok "T1 the drop is logged (a hidden filter that changes a verdict must be visible)" \
  || nok "T1 log" "$(tail -5 "$CASE_DIR/stderr.log")"

# ════════════════════════════════════════════════════════════════════════════
# T2: blank lines, quote style and wrapping only (AST-identical)
# ════════════════════════════════════════════════════════════════════════════
run_lib_case t2 '# guard for human names
SEMPTY = (
    '"'"'sem nome'"'"',


    '"'"''"'"',
)



def guard():
    """Return the verdict."""
    x = {
        "a": 1,
    }
    return x['"'"'a'"'"']
'
[ "$V" = "OK" ] && [ "$RC" -eq 0 ] && ok "T2 reformat-only edit (blank lines, quotes, wrapping) -> OK" \
  || nok "T2" "rc=$RC verdict=$V guarded=[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T3: control — a REAL code change must still be caught
# ════════════════════════════════════════════════════════════════════════════
run_lib_case t3 '# guard for human names
SEMPTY = ("sem nome", "")


def guard():
    """Return the verdict."""
    x = {"a": 1}
    return x["a"] + 1
'
[ "$V" = "NEEDS_GUARDED_RESTART" ] && [ "$RC" -ne 0 ] \
  && ok "T3 real change still NEEDS_GUARDED_RESTART (the filter does not hide real changes)" \
  || nok "T3" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T3 GUARDED names the stale sensitive daemon" \
  || nok "T3 guarded" "[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T4: docstring-only change is NOT treated as cosmetic
# ════════════════════════════════════════════════════════════════════════════
run_lib_case t4 '# guard for human names
SEMPTY = ("sem nome", "")


def guard():
    """Return the verdict, now with a longer docstring."""
    x = {"a": 1}
    return x["a"]
'
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T4 docstring-only change stays flagged" \
  || nok "T4" "rc=$RC verdict=$V out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T5: shebang change is NOT cosmetic
# ════════════════════════════════════════════════════════════════════════════
new_case t5
printf '#!/usr/bin/env python3\n%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
add_daemon central_sender human_name_guard 4001
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
printf '#!/usr/bin/python3\n%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
commit_at "$CHANGE_EPOCH" "shebang"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T5 "$C0" "$C1" lib/human_name_guard.py
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T5 shebang-only change stays flagged" \
  || nok "T5" "rc=$RC verdict=$V out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T6: new version does not parse -> cannot tell -> keep the file
# ════════════════════════════════════════════════════════════════════════════
run_lib_case t6 '# guard for human names
def guard(:
    return 1
'
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T6 unparsable new version stays flagged (cannot tell != cosmetic)" \
  || nok "T6" "rc=$RC verdict=$V out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T7: brand-new lib file (no old blob) stays flagged
#   The daemon file is BYTE-IDENTICAL at C0 and C1 — it already imports
#   lib.new_guard at C0, where the module does not exist yet — so the ADDED
#   lib/new_guard.py is the only changed path and the daemon can only be flagged
#   because the classifier KEPT it. (The first version of this test also rewrote
#   the daemon's import at C1: a real AST change to the daemon's own entrypoint
#   flagged it whatever the classifier did with the lib, so a classifier that
#   dropped every added file left the suite green — gate ga-w1cl44.)
# ════════════════════════════════════════════════════════════════════════════
new_case t7
add_daemon central_sender new_guard 4001
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
printf '%s' "$LIB_V1" > "$RUNTIME/lib/new_guard.py"
commit_at "$CHANGE_EPOCH" "new lib file"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T7 "$C0" "$C1" lib/new_guard.py
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T7 added file stays flagged" \
  || nok "T7" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T7 GUARDED names the daemon that imports the added file" \
  || nok "T7 guarded" "[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T8: per-daemon precision — only the daemon importing the REAL change is flagged
# ════════════════════════════════════════════════════════════════════════════
new_case t8
printf '%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
add_daemon central_sender cosmetic_guard 4001
add_daemon webhook_receiver real_guard 4002
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
printf '# only a comment\n%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
sed 's/return x\["a"\]/return x["a"] * 2/' <<<"$LIB_V1" > "$RUNTIME/lib/real_guard.py"
commit_at "$CHANGE_EPOCH" "one comment-only, one real"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T8 verdict NEEDS_GUARDED_RESTART (one daemon really is stale)" \
  || nok "T8 verdict" "got '$V' out=[$OUT]"
echo "$G" | grep -q 'com.test.webhook-receiver' && ok "T8 GUARDED names the daemon importing the real change" \
  || nok "T8 guarded (real)" "[$G]"
echo "$G" | grep -q 'com.test.central-sender' \
  && nok "T8 GUARDED wrongly names the daemon that imports only the comment-only file" "[$G]" \
  || ok "T8 the comment-only importer is NOT flagged"

# ════════════════════════════════════════════════════════════════════════════
# T9: per-daemon baseline narrowing sees the same filtered set.
#   C0 base; C1 really changes real_guard.py; C2 edits cosmetic_guard.py's
#   comments. One daemon imports BOTH. Its last-clean point is C1 (it was
#   restarted after C1), so its OWN window is C1..C2 = only the comment edit.
#   The wide window (C0..C2) flags it because of C1; the narrowing must then
#   downgrade it — which it can only do if the narrow set drops the comment-only
#   file too.
# ════════════════════════════════════════════════════════════════════════════
# run_narrowing_case <case-name> -> sets OUT RC V G  (T9's scenario, reused by T15)
run_narrowing_case() {
  new_case "$1"
  printf '%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
  printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
  printf 'from lib.cosmetic_guard import guard\nfrom lib.real_guard import guard as g2\nprint(guard(), g2())\n' \
    > "$RUNTIME/daemons/central_sender.py"
  cat > "$RUNTIME/launchd/central_sender-wrapper.sh" <<EOF
#!/usr/bin/env bash
exec "\$BASEDIR/venv/bin/python3" "\$BASEDIR/daemons/central_sender.py"
EOF
  make_plist "$AGENTS" com.test.central-sender /bin/bash "$RUNTIME/launchd/central_sender-wrapper.sh"
  commit_at $((CHANGE_EPOCH - 7200)) base
  C0=$(git -C "$RUNTIME" rev-parse HEAD)
  sed 's/return x\["a"\]/return x["a"] * 2/' <<<"$LIB_V1" > "$RUNTIME/lib/real_guard.py"
  commit_at $((CHANGE_EPOCH - 600)) "real change"
  C1=$(git -C "$RUNTIME" rev-parse HEAD)
  printf '# only a comment\n%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
  commit_at "$CHANGE_EPOCH" "comment-only change"
  C2=$(git -C "$RUNTIME" rev-parse HEAD)
  # the daemon was restarted AFTER C1 but BEFORE C2 landed
  seed_running com.test.central-sender 4001 "$(lstart_of $((CHANGE_EPOCH - 300)))"
  DAEMON_BASELINE_OVERRIDES="com.test.central-sender $C1"
  OUT=$(invoke_helper "$C0" "$C2"); RC=$?; V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT")
  DAEMON_BASELINE_OVERRIDES=""
}
run_narrowing_case t9
[ "$V" = "OK" ] && [ "$RC" -eq 0 ] \
  && ok "T9 narrowing downgrades the label: its own window holds only a comment-only edit" \
  || nok "T9" "rc=$RC verdict=$V guarded=[$G] out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T10: mode-only change (same bytes) stays flagged
# ════════════════════════════════════════════════════════════════════════════
new_case t10
printf '%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
add_daemon central_sender human_name_guard 4001
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
chmod +x "$RUNTIME/lib/human_name_guard.py"
commit_at "$CHANGE_EPOCH" "chmod +x"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T10 "$C0" "$C1" lib/human_name_guard.py
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T10 mode-only change stays flagged" \
  || nok "T10" "rc=$RC verdict=$V out=[$OUT]"

# ════════════════════════════════════════════════════════════════════════════
# T11: a DELETED lib file (no new blob) stays flagged
#   Mirror of T7: the daemon file is untouched, only the lib disappears.
# ════════════════════════════════════════════════════════════════════════════
new_case t11
printf '%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
add_daemon central_sender human_name_guard 4001
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
rm -f "$RUNTIME/lib/human_name_guard.py"
commit_at "$CHANGE_EPOCH" "delete lib"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T11 "$C0" "$C1" lib/human_name_guard.py
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T11 deleted file stays flagged" \
  || nok "T11" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T11 GUARDED names the daemon that imports the deleted file" \
  || nok "T11 guarded" "[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T12: a path whose blob cannot be read on EITHER side stays flagged
#   A gitlink (mode 160000) at lib/vendored_guard.py: `git diff --name-only`
#   lists it when the recorded commit moves, but `git cat-file blob <sha>:<path>`
#   fails at both ends — the "missing blob" the classifier comment promises to keep.
# ════════════════════════════════════════════════════════════════════════════
new_case t12
add_daemon central_sender vendored_guard 4001
git -C "$RUNTIME" add daemons launchd >/dev/null 2>&1
git -C "$RUNTIME" update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,lib/vendored_guard.py
commit_index_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
git -C "$RUNTIME" update-index --cacheinfo 160000,2222222222222222222222222222222222222222,lib/vendored_guard.py
commit_index_at "$CHANGE_EPOCH" "move the gitlink"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T12 "$C0" "$C1" lib/vendored_guard.py
git -C "$RUNTIME" cat-file blob "$C0:lib/vendored_guard.py" >/dev/null 2>&1 \
  && nok "T12 premise: the blob at C0 should be unreadable" \
  || ok "T12 premise: the blob at C0 is unreadable (a gitlink, not a blob)"
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT"); G=$(field GUARDED "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T12 unreadable blob stays flagged (cannot tell != cosmetic)" \
  || nok "T12" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T12 GUARDED names the daemon that imports the unreadable path" \
  || nok "T12 guarded" "[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T13: a comment-only edit on a file over the 2 MiB cap stays flagged
#   T1's edit plus 2.2 MB of comment: still AST-identical, so ONLY the size cap
#   keeps it. Without the cap this would be dropped — the parse of an arbitrarily
#   large blob is exactly what the cap exists to bound.
# ════════════════════════════════════════════════════════════════════════════
BIG_V2="$(printf '# '; head -c 2200000 /dev/zero | tr '\0' x; printf '\n%s' "$LIB_V1")"
run_lib_case t13 "$BIG_V2"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T13 oversize comment-only edit stays flagged (cannot afford to tell != cosmetic)" \
  || nok "T13" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T13 GUARDED names the stale sensitive daemon" \
  || nok "T13 guarded" "[$G]"

# ════════════════════════════════════════════════════════════════════════════
# T14: the classifier ITSELF fails -> the raw list is kept (fail toward flagging)
#   T1's exact fixture, which T1 shows is dropped when the classifier works. Here
#   python3 fails for the classifier only, so the ONLY difference is whether it
#   could answer. "Could not tell" must not collapse into "nothing changed".
# ════════════════════════════════════════════════════════════════════════════
HELPER_PATH="$FAILING_CLASSIFIER_DIR:$PATH" run_lib_case t14 "$COMMENT_ONLY_V2"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && [ "$RC" -ne 0 ] \
  && ok "T14 a failed classifier leaves the delivery flagged (raw list kept)" \
  || nok "T14" "rc=$RC verdict=$V out=[$OUT]"
echo "$G" | grep -q 'com.test.central-sender' && ok "T14 GUARDED names the stale sensitive daemon" \
  || nok "T14 guarded" "[$G]"
grep -q 'could not classify' "$CASE_DIR/stderr.log" \
  && ok "T14 the classifier failure is logged" \
  || nok "T14 log" "$(tail -5 "$CASE_DIR/stderr.log")"

# ════════════════════════════════════════════════════════════════════════════
# T15: the classifier fails on the per-daemon narrowing path
#   T9's exact fixture (which T9 shows is downgraded when the classifier works).
#   A failed classifier must leave the raw window list — the label stays flagged
#   — and the failure must be visible, not a silent fall-through.
# ════════════════════════════════════════════════════════════════════════════
HELPER_PATH="$FAILING_CLASSIFIER_DIR:$PATH" run_narrowing_case t15
[ "$V" = "NEEDS_GUARDED_RESTART" ] && [ "$RC" -ne 0 ] \
  && ok "T15 a failed classifier does not downgrade the label (raw narrowing window kept)" \
  || nok "T15" "rc=$RC verdict=$V guarded=[$G] out=[$OUT]"
grep -q 'could not classify.*narrowing window' "$CASE_DIR/stderr.log" \
  && ok "T15 the narrowing-path classifier failure is logged" \
  || nok "T15 log" "$(grep -i 'classif' "$CASE_DIR/stderr.log" | tail -5)"

# ════════════════════════════════════════════════════════════════════════════
# The rig-owned detector (gate ga-yxz43u).
#
# Step 3 trusts scripts/detect_stale_daemons.py EXCLUSIVELY for every entry it
# covers — in production that is every WA daemon, the three importers of
# lib/human_name_guard.py in the incident among them — and its --mode own rule
# is a bare timestamp test, so the Step 1c filter alone never reaches those
# daemons. T1-T15 all ran with NO detector in the fixture (RIG_DETECTOR_USED=0),
# i.e. only ever through the fallback branch production does not take.
#
# The stub below is NOT control-file-driven like the one in daemon-refresh.test.sh:
# it re-derives "stale" from git with the same rule as find_stale('own') (newest
# commit touching own file + registered assets + top-level own imports is newer
# than the process start), so a case cannot pass because the test told the
# detector what to say. Each case asserts as a PREMISE that the detector really
# does flag the daemon, and that RIG_DETECTOR_USED=1 in the run.
#   T16 the reviewer's reproduction: T8's two daemons, detector present.
#   T17 the detector is stateless: the NEXT deploy (a real change to someone
#       else, no cosmetic file in its own window) must not re-flag the importer
#       of an old comment-only edit.
#   T18 the opposite: a REAL change from an earlier, unrestarted deploy must stay
#       flagged when the current window holds only a comment-only edit to it.
#   T19 a registered asset that really changed keeps the label flagged.
#   T20-T27 every "could not tell" keeps the label, with the reason logged.
#   T28 everything flagged is cosmetic -> OK, nothing halted.
# ════════════════════════════════════════════════════════════════════════════
STALE_EPOCH=$((CHANGE_EPOCH - 3600))

install_rsd_stub() {
  mkdir -p "$RUNTIME/scripts"
  cat > "$RUNTIME/scripts/detect_stale_daemons.py" <<'RSDEOF'
#!/usr/bin/env python3
# Test double for whatsapp_automation/scripts/detect_stale_daemons.py --mode own.
import ast, json, os, subprocess, sys
REPO = os.path.realpath(os.path.join(os.path.dirname(__file__), ".."))
cfg = json.load(open(os.path.join(os.environ["MOCK_DIR"], "rsd_daemons.json")))
deps_path = os.path.join(REPO, "daemons", "deploy_deps.json")
deps = json.load(open(deps_path))["daemons"] if os.path.exists(deps_path) else {}

def last_commit_ts(files):
    out = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%ct", "HEAD", "--"] + files,
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else 0

def own_direct_imports(rel):          # module-level imports only, one hop (wa-rixb9)
    alvos = set()
    try:
        tree = ast.parse(open(os.path.join(REPO, rel), encoding="utf-8", errors="ignore").read())
    except (OSError, SyntaxError):
        return alvos
    def reg(nome):
        r = nome.replace(".", "/")
        if r.startswith("lib/"):
            r = r[len("lib/"):]
        for base in ("lib", "daemons", "utils"):
            cand = os.path.join(REPO, base, r + ".py")
            if os.path.exists(cand):
                alvos.add(os.path.relpath(cand, REPO)); break
    def desce(corpo):
        for node in corpo:
            if isinstance(node, ast.Import):
                for a in node.names: reg(a.name)
            elif isinstance(node, ast.ImportFrom):
                if node.module and node.level == 0: reg(node.module)
            elif isinstance(node, (ast.If, ast.Try, ast.With, ast.For, ast.While)):
                for campo in ("body", "orelse", "finalbody", "handlers"):
                    for f in getattr(node, campo, None) or []:
                        desce(f.body if campo == "handlers" else [f])
    desce(tree.body)
    return alvos

known, affected = [], []
for d in cfg:
    rel = d["file"]
    known.append(rel)
    assets = [a for a in (deps.get(rel) or {}).get("assets") or [] if a]
    alvo = [rel] + assets + sorted(own_direct_imports(rel))
    # "force": a flag whose cause this script cannot see (models an unexplained flag)
    if d.get("force") or last_commit_ts(alvo) > d["start"]:
        affected.append(rel)
print(json.dumps({"known": sorted(set(known)), "affected": affected}))
RSDEOF
}

seed_rsd() {  # seed_rsd <file>:<start-epoch>[:force] ...
  local first=1 spec f s force out="$MOCK/rsd_daemons.json"
  printf '[' > "$out"
  for spec in "$@"; do
    IFS=: read -r f s force <<<"$spec"
    [ "$first" -eq 1 ] || printf ',' >> "$out"; first=0
    printf '{"file":"%s","start":%s,"force":%s}' "$f" "$s" "$([ "${force:-}" = force ] && echo true || echo false)" >> "$out"
  done
  printf ']' >> "$out"
}

rsd_flags() {  # what the stub itself says is stale right now
  MOCK_DIR="$MOCK" python3 "$RUNTIME/scripts/detect_stale_daemons.py" --mode own --no-fetch --json 2>/dev/null \
    | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["affected"]))'
}

in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }   # in_list <word> <space-separated list>

# premise <case> <file>...: the detector flags each file. Without this a case
# could pass with the detector deciding nothing.
premise() {
  local cn="$1" got f; shift; got="$(rsd_flags)"
  for f in "$@"; do
    in_list "$f" "$got" && ok "$cn premise: the detector flags $f" \
      || nok "$cn premise: the detector does not flag $f" "got [$got]"
  done
}

LIB_REAL_V2="$(sed 's/return x\["a"\]/return x["a"] * 2/' <<<"$LIB_V1")"

# rsd_two_daemons <case>: central_sender -> lib/cosmetic_guard.py, webhook_receiver
# -> lib/real_guard.py, both processes up since STALE_EPOCH, the stub installed,
# base committed -> C0.
rsd_two_daemons() {
  new_case "$1"
  printf '%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
  printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
  add_daemon central_sender cosmetic_guard 4001
  add_daemon webhook_receiver real_guard 4002
  install_rsd_stub
  seed_rsd "daemons/central_sender.py:$STALE_EPOCH" "daemons/webhook_receiver.py:$STALE_EPOCH"
  commit_at $((CHANGE_EPOCH - 7200)) base
  C0=$(git -C "$RUNTIME" rev-parse HEAD)
}
edit_cosmetic()    { printf '# only a comment\n%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"; }
edit_real()        { printf '%s\n' "$LIB_REAL_V2" > "$RUNTIME/lib/$1.py"; }
# rsd_run <pre> <post> -> OUT RC V P G AR (AFFECTED_RIG_DETECTOR) USED
rsd_run() {
  OUT=$(invoke_helper "$1" "$2"); RC=$?
  V=$(field VERDICT "$OUT"); P=$(field PROOF "$OUT"); G=$(field GUARDED "$OUT")
  AR=$(field AFFECTED_RIG_DETECTOR "$OUT"); USED=$(field RIG_DETECTOR_USED "$OUT")
}
log_has() { grep -qF "$1" "$CASE_DIR/stderr.log"; }
CS=com.test.central-sender; WH=com.test.webhook-receiver

# ── T16: the reviewer's reproduction — T8's fixture WITH the detector ─────────
rsd_two_daemons t16
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T16 daemons/central_sender.py daemons/webhook_receiver.py
rsd_run "$C0" "$C1"
[ "$USED" = 1 ] && ok "T16 RIG_DETECTOR_USED=1 — this run took the production branch" \
  || nok "T16 RIG_DETECTOR_USED" "got '$USED'"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T16 verdict NEEDS_GUARDED_RESTART (webhook-receiver really is stale)" \
  || nok "T16 verdict" "got '$V' out=[$OUT]"
in_list "$WH" "$G" && ok "T16 GUARDED names the daemon importing the real change" || nok "T16 guarded (real)" "[$G]"
in_list "$CS" "$G" && nok "T16 GUARDED wrongly names the comment-only importer the detector flagged" "[$G]" \
  || ok "T16 the comment-only importer is NOT guarded although the detector flagged it"
in_list "$CS" "$AR" && nok "T16 AFFECTED_RIG_DETECTOR still lists the downgraded label" "[$AR]" \
  || ok "T16 AFFECTED_RIG_DETECTOR no longer lists the downgraded label"
in_list "$WH" "$AR" && ok "T16 AFFECTED_RIG_DETECTOR keeps the really-stale label" || nok "T16 AR (real)" "[$AR]"
log_has "rig-detector cosmetic check: $CS downgraded" && ok "T16 the downgrade is logged" \
  || nok "T16 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T17: the detector is stateless — an OLD comment-only edit must not come back
#   C1 (already delivered, comment-only, nobody restarted anything) then C2 (a
#   real change for the OTHER daemon). The deploy window C1..C2 holds no cosmetic
#   file at all, but the detector still flags central-sender by timestamp.
rsd_two_daemons t17
edit_cosmetic
commit_at $((CHANGE_EPOCH - 1800)) "earlier deploy: comment-only"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
edit_real real_guard
commit_at "$CHANGE_EPOCH" "later deploy: real change elsewhere"; C2=$(git -C "$RUNTIME" rev-parse HEAD)
only_changed T17 "$C1" "$C2" lib/real_guard.py
premise T17 daemons/central_sender.py daemons/webhook_receiver.py
rsd_run "$C1" "$C2"
[ "$USED" = 1 ] && [ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T17 verdict NEEDS_GUARDED_RESTART on the production branch" \
  || nok "T17 verdict" "used=$USED got '$V' out=[$OUT]"
in_list "$WH" "$G" && ok "T17 GUARDED names the daemon importing the real change" || nok "T17 guarded (real)" "[$G]"
in_list "$CS" "$G" && nok "T17 GUARDED re-flags the importer of an old comment-only edit (attributed to an unrelated deploy)" "[$G]" \
  || ok "T17 the importer of the old comment-only edit is not re-flagged by a later deploy"

# ── T18: a REAL change from an earlier deploy must NOT be hidden ──────────────
#   C1 really changes real_guard.py (delivered, central-sender never restarted);
#   C2 edits its comments; C3 really changes other_lib.py for the other daemon.
#   The window C1..C3 holds only the comment-only edit for central-sender — a
#   downgrade judged on the window alone would drop it, hiding the C1 change.
new_case t18
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/other_lib.py"
add_daemon central_sender real_guard 4001
add_daemon webhook_receiver other_lib 4002
install_rsd_stub
seed_rsd "daemons/central_sender.py:$STALE_EPOCH" "daemons/webhook_receiver.py:$STALE_EPOCH"
commit_at $((CHANGE_EPOCH - 7200)) base
edit_real real_guard
commit_at $((CHANGE_EPOCH - 1800)) "earlier deploy: REAL change to real_guard"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
printf '# later comment\n%s\n' "$LIB_REAL_V2" > "$RUNTIME/lib/real_guard.py"
commit_at $((CHANGE_EPOCH - 900)) "comment-only edit to real_guard"
edit_real other_lib
commit_at "$CHANGE_EPOCH" "real change to other_lib"; C3=$(git -C "$RUNTIME" rev-parse HEAD)
premise T18 daemons/central_sender.py daemons/webhook_receiver.py
rsd_run "$C1" "$C3"
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T18 verdict NEEDS_GUARDED_RESTART" || nok "T18 verdict" "got '$V' out=[$OUT]"
in_list "$CS" "$G" && ok "T18 GUARDED keeps the daemon whose earlier REAL change was never restarted" \
  || nok "T18 the earlier real change was hidden by a window that only shows the comment edit" "guarded=[$G]"
log_has "$CS stays AFFECTED" && ok "T18 the keep is logged with its reason" \
  || nok "T18 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T19: a registered asset that really changed keeps the label flagged ───────
#   The detector counts assets of ANY extension; only *.py can be classified.
rsd_two_daemons t19
printf '%s\n' '{"daemons":{"daemons/central_sender.py":{"closure":["daemons/central_sender.py","lib/cosmetic_guard.py"],"assets":["daemons/static/app.js"],"label":"com.test.central-sender"}}}' \
  > "$RUNTIME/daemons/deploy_deps.json"
mkdir -p "$RUNTIME/daemons/static"; echo 'var v = 1;' > "$RUNTIME/daemons/static/app.js"
commit_at $((CHANGE_EPOCH - 7100)) "register the asset"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; echo 'var v = 2;' > "$RUNTIME/daemons/static/app.js"; edit_real real_guard
commit_at "$CHANGE_EPOCH" "comment-only lib + real asset + real lib"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T19 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T19 GUARDED keeps the daemon whose registered asset really changed" \
  || nok "T19 the changed asset was hidden behind a comment-only import" "guarded=[$G] out=[$OUT]"
log_has "daemons/static/app.js changed since its start" && ok "T19 the log names the asset" \
  || nok "T19 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T20: the process start time cannot be read -> keep ────────────────────────
rsd_two_daemons t20
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
rm -f "$MOCK/start.4001"
premise T20 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$AR" && ok "T20 the label stays flagged when its start time cannot be read" || nok "T20 AR" "[$AR]"
log_has "the start time of pid 4001 could not be read" && ok "T20 the reason is logged" \
  || nok "T20 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T21: the flag is NOT explained by any changed file -> keep ────────────────
#   real_guard.py is changed and changed BACK (net zero since the process
#   started), so the detector flags it by timestamp while nothing since start
#   reaches it. "Unexplained" is not "cosmetic".
new_case t21
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/other_lib.py"
add_daemon central_sender real_guard 4001
add_daemon webhook_receiver other_lib 4002
install_rsd_stub
seed_rsd "daemons/central_sender.py:$STALE_EPOCH" "daemons/webhook_receiver.py:$STALE_EPOCH"
commit_at $((CHANGE_EPOCH - 7200)) base; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_real real_guard;  commit_at $((CHANGE_EPOCH - 1800)) "change"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"; commit_at $((CHANGE_EPOCH - 900)) "change back"
edit_real other_lib;   commit_at "$CHANGE_EPOCH" "real change to other_lib"; C3=$(git -C "$RUNTIME" rev-parse HEAD)
premise T21 daemons/central_sender.py daemons/webhook_receiver.py
rsd_run "$C0" "$C3"
in_list "$CS" "$AR" && ok "T21 an unexplained flag stays flagged" || nok "T21 AR" "[$AR]"
log_has "the detector's flag is not explained by one" && ok "T21 the reason is logged" \
  || nok "T21 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T22: the classifier fails on this path -> keep, visibly ───────────────────
HELPER_PATH="$FAILING_CLASSIFIER_DIR:$PATH" rsd_two_daemons t22
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T22 daemons/central_sender.py
HELPER_PATH="$FAILING_CLASSIFIER_DIR:$PATH" rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T22 a failed classifier does not downgrade the rig-detector label" || nok "T22 guarded" "[$G]"
log_has "the comment/format-only classifier failed or timed out" && ok "T22 the failure is logged" \
  || nok "T22 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T23: FORCE_RESTART_LABELS is never reconsidered ───────────────────────────
rsd_two_daemons t23
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T23 daemons/central_sender.py
FORCE_RESTART_LABELS="$CS" rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T23 a FORCE_RESTART label stays flagged although it is comment-only" \
  || nok "T23 guarded" "[$G] out=[$OUT]"
log_has "rig-detector cosmetic check: $CS downgraded" \
  && nok "T23 a forced label was downgraded" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)" \
  || ok "T23 the forced label is not even considered for the downgrade"

# ── T24: a label with an entry the detector does NOT cover is not eligible ────
#   central-sender's plist also runs daemons/extra.py, which the detector does
#   not know; extra.py reaches real_guard (really changed) only through a
#   routes/ blueprint, a path the downgrade's own file scan does not follow —
#   so another matcher is flagging the label and the detector cannot vouch for it.
rsd_two_daemons t24
printf 'from routes import bp\nprint(bp)\n' > "$RUNTIME/daemons/extra.py"
mkdir -p "$RUNTIME/daemons/routes"
printf 'from lib.real_guard import guard\n' > "$RUNTIME/daemons/routes/bp.py"
make_plist "$AGENTS" "$CS" /bin/bash "$RUNTIME/launchd/central_sender-wrapper.sh" "$RUNTIME/daemons/extra.py"
commit_at $((CHANGE_EPOCH - 7100)) "extra entrypoint"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T24 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T24 the label with an uncovered entry stays flagged" || nok "T24 guarded" "[$G] out=[$OUT]"
log_has "is not covered by the rig detector" && ok "T24 the reason is logged" \
  || nok "T24 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T25: a template the daemon renders changed -> keep ────────────────────────
#   Step 3's template matcher runs for every entry but is skipped once the
#   detector has already flagged the label, so the downgrade must check it.
rsd_two_daemons t25
printf 'from lib.cosmetic_guard import guard\nrender_template("page.html")\nprint(guard())\n' > "$RUNTIME/daemons/central_sender.py"
mkdir -p "$RUNTIME/templates"; echo '<p>v1</p>' > "$RUNTIME/templates/page.html"
commit_at $((CHANGE_EPOCH - 7100)) "daemon renders a template"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; echo '<p>v2</p>' > "$RUNTIME/templates/page.html"
commit_at "$CHANGE_EPOCH" "comment-only lib + real template"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T25 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T25 the label stays flagged when a template it renders changed" || nok "T25 guarded" "[$G] out=[$OUT]"
# ga-0bw1ic: this entrypoint has no Flask(...) app, so the daemon is matched to the template by FILE NAME
# only — a guess. The log must say so, not state "changed" as a fact.
log_has "a template it renders MAY have changed in this deploy (matched by file name only" && ok "T25 the reason is logged, worded as a name-only guess" \
  || nok "T25 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T25b (ga-0bw1ic): same, but the daemon's Flask app resolves the template to a path ──
#   A path match IS a fact about this daemon: the log states it as one.
rsd_two_daemons t25b
printf 'from flask import Flask, render_template\nfrom lib.cosmetic_guard import guard\napp = Flask(__name__)\nrender_template("page.html")\nprint(guard())\n' > "$RUNTIME/daemons/central_sender.py"
mkdir -p "$RUNTIME/daemons/templates"; echo '<p>v1</p>' > "$RUNTIME/daemons/templates/page.html"
commit_at $((CHANGE_EPOCH - 7100)) "daemon renders its own template"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; echo '<p>v2</p>' > "$RUNTIME/daemons/templates/page.html"
commit_at "$CHANGE_EPOCH" "comment-only lib + the template it loads"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T25b daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T25b the label stays flagged when the template it loads changed" || nok "T25b guarded" "[$G] out=[$OUT]"
log_has "a template it renders changed in this deploy (" && ok "T25b the reason is stated as fact (path match)" \
  || nok "T25b log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"
log_has "MAY have changed" && nok "T25b a path match must not be worded as a guess" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)" \
  || ok "T25b ...and not worded as a guess"

# ── T25c (ga-0bw1ic): a SAME-NAMED template elsewhere changed; the one it loads did not ──
#   The template check must not keep the label flagged, and the dismissal must be
#   visible HERE (this site can take the label out of AFFECTED), not only at Step 3.
rsd_two_daemons t25c
printf 'from flask import Flask, render_template\nfrom lib.cosmetic_guard import guard\napp = Flask(__name__)\nrender_template("page.html")\nprint(guard())\n' > "$RUNTIME/daemons/central_sender.py"
mkdir -p "$RUNTIME/daemons/templates" "$RUNTIME/templates"
echo '<p>own</p>' > "$RUNTIME/daemons/templates/page.html"; echo '<p>other v1</p>' > "$RUNTIME/templates/page.html"
commit_at $((CHANGE_EPOCH - 7100)) "daemon renders its own template"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; echo '<p>other v2</p>' > "$RUNTIME/templates/page.html"
commit_at "$CHANGE_EPOCH" "comment-only lib + a same-named template elsewhere"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T25c daemons/central_sender.py
rsd_run "$C0" "$C1"
log_has "a changed template was set aside (rig-detector cosmetic check)" && ok "T25c the dismissal is logged at the cosmetic check" \
  || nok "T25c log" "$(grep -E 'rig-detector|set aside' "$CASE_DIR/stderr.log" | tail -4)"
in_list "$CS" "$G" && nok "T25c the same-named template elsewhere must not keep the label flagged" "[$G] out=[$OUT]" \
  || ok "T25c the label is NOT kept flagged by a same-named template it does not load"

# ── T26: loaded but no live pid -> keep ───────────────────────────────────────
rsd_two_daemons t26
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
rm -f "$MOCK/pid.$CS"; : > "$MOCK/loaded.$CS"
premise T26 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$AR" && ok "T26 the label stays flagged without a live pid" || nok "T26 AR" "[$AR]"
log_has "no live pid, so the code it loaded cannot be identified" && ok "T26 the reason is logged" \
  || nok "T26 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T27: an entrypoint that does not parse -> keep ────────────────────────────
#   (a flag whose cause the script cannot see: the stub's "force")
rsd_two_daemons t27
printf 'def broken(:\n' > "$RUNTIME/daemons/central_sender.py"
seed_rsd "daemons/central_sender.py:$STALE_EPOCH:force" "daemons/webhook_receiver.py:$STALE_EPOCH"
commit_at $((CHANGE_EPOCH - 7100)) "entrypoint that does not parse"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T27 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$AR" && ok "T27 an unparsable entrypoint keeps the label flagged" || nok "T27 AR" "[$AR]"
log_has "could not work out which changed files reach it" && ok "T27 the reason is logged" \
  || nok "T27 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T28: everything the detector flagged is cosmetic -> OK, nothing halted ────
#   A comment-only lib edit next to an unrelated real file (so the deploy is not
#   the early-OK shape): the detector flags central-sender, the downgrade clears
#   it, nothing is affected.
rsd_two_daemons t28
edit_cosmetic; printf 'X = 1\n' > "$RUNTIME/lib/unused.py"
commit_at "$CHANGE_EPOCH" "comment-only lib + an unrelated new module"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T28 daemons/central_sender.py
rsd_run "$C0" "$C1"
[ "$USED" = 1 ] && [ "$V" = "OK" ] && [ "$RC" -eq 0 ] \
  && ok "T28 a deploy whose only flagged daemon is cosmetic-only is OK on the production branch" \
  || nok "T28" "used=$USED rc=$RC verdict=$V guarded=[$G] out=[$OUT]"
[ -z "${G// /}" ] && ok "T28 nothing GUARDED" || nok "T28 guarded" "[$G]"

# ── T29: no commit at or before the process start -> keep ─────────────────────
#   Every commit is newer than the process, so there is no "code it loaded" to
#   compare against.
new_case t29
printf '%s' "$LIB_V1" > "$RUNTIME/lib/cosmetic_guard.py"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
add_daemon central_sender cosmetic_guard 4001
add_daemon webhook_receiver real_guard 4002
install_rsd_stub
seed_rsd "daemons/central_sender.py:$STALE_EPOCH" "daemons/webhook_receiver.py:$STALE_EPOCH"
commit_at $((CHANGE_EPOCH - 1000)) "first commit, AFTER the processes started"; C0=$(git -C "$RUNTIME" rev-parse HEAD)
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T29 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$AR" && ok "T29 the label stays flagged when nothing predates its process" || nok "T29 AR" "[$AR]"
log_has "no commit at or before its start" && ok "T29 the reason is logged" \
  || nok "T29 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T30: the diff since the process start cannot be computed -> keep ──────────
#   T16's exact fixture (downgraded when git works). A git that refuses only the
#   diff this check runs must leave the label flagged, and say so.
REAL_GIT="$(command -v git)"
FAILING_DIFF_DIR="$TMP_ROOT/failing-diff"
mkdir -p "$FAILING_DIFF_DIR"
cat > "$FAILING_DIFF_DIR/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--no-renames" ] && exit 1; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$FAILING_DIFF_DIR/git"
rsd_two_daemons t30
edit_cosmetic; edit_real real_guard
commit_at "$CHANGE_EPOCH" "one comment-only, one real"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T30 daemons/central_sender.py
HELPER_PATH="$FAILING_DIFF_DIR:$PATH" rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T30 a failed diff leaves the rig-detector label flagged" || nok "T30 guarded" "[$G]"
log_has "failed" && log_has "rig-detector cosmetic check: $CS stays AFFECTED — git diff" \
  && ok "T30 the failure is logged" || nok "T30 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── T31: a REAL change reaching the daemon only through its closure -> keep ───
#   The detector flags central-sender for a comment-only edit to its direct
#   import (mid). deep.py, which mid imports, really changed in the same deploy:
#   not something the detector's own rule looks at, but the daemon does run
#   stale transitive code, so the label is not cosmetic-only.
new_case t31
printf '%s' "$LIB_V1" > "$RUNTIME/lib/deep.py"
printf 'from lib.deep import guard as g\n\n\ndef guard():\n    return g()\n' > "$RUNTIME/lib/mid.py"
add_daemon central_sender mid 4001
printf '%s' "$LIB_V1" > "$RUNTIME/lib/real_guard.py"
add_daemon webhook_receiver real_guard 4002
printf '%s\n' '{"daemons":{"daemons/central_sender.py":{"closure":["daemons/central_sender.py","lib/mid.py","lib/deep.py"],"assets":[],"label":"com.test.central-sender"}}}' \
  > "$RUNTIME/daemons/deploy_deps.json"
install_rsd_stub
seed_rsd "daemons/central_sender.py:$STALE_EPOCH" "daemons/webhook_receiver.py:$STALE_EPOCH"
commit_at $((CHANGE_EPOCH - 7200)) base; C0=$(git -C "$RUNTIME" rev-parse HEAD)
printf '# only a comment\nfrom lib.deep import guard as g\n\n\ndef guard():\n    return g()\n' > "$RUNTIME/lib/mid.py"
edit_real deep
commit_at "$CHANGE_EPOCH" "comment-only mid + real deep"; C1=$(git -C "$RUNTIME" rev-parse HEAD)
premise T31 daemons/central_sender.py
rsd_run "$C0" "$C1"
in_list "$CS" "$G" && ok "T31 a real closure-only change keeps the label flagged" \
  || nok "T31 the real change to lib/deep.py was hidden behind a comment-only direct import" "guarded=[$G] out=[$OUT]"
log_has "lib/deep.py changed since its start" && ok "T31 the log names the closure member" \
  || nok "T31 log" "$(grep 'rig-detector' "$CASE_DIR/stderr.log" | tail -3)"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh-comment-only-diff.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
