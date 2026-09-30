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
# T7: brand-new lib file (no old blob) -> still flagged.
# T8 (per-daemon precision, the incident's own shape): two daemons, one imports
#    only the comment-only file, the other a really-changed file -> only the
#    second is GUARDED.
# T9: the per-daemon baseline narrowing path (DAEMON_BASELINE_OVERRIDES) drops
#    the comment-only file too: a label whose OWN window since its last-clean
#    point contains only the comment-only edit is downgraded, not re-halted.
# T10: mode-only change (chmod +x, same bytes) -> still flagged.

# No `pipefail` at file level (ga-uel7sb): assertions below are `X | grep ...`
# pipes; under pipefail an early-exiting reader can SIGPIPE the writer and turn
# a PASSING assertion into a false FAIL under load. daemon-refresh.sh runs as
# its own subprocess with its own `set` options.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../daemon-refresh.sh"

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

# invoke_helper <pre_sha> <post_sha>   (DAEMON_BASELINE_OVERRIDES read from env)
invoke_helper() {
  MOCK_DIR="$MOCK" \
  RUNTIME_DIR="$RUNTIME" \
  PRE_DEPLOY_SHA="$1" POST_DEPLOY_SHA="$2" \
  DEPLOY_EPOCH="$NOW" \
  SENSITIVE_DAEMONS="${SENSITIVE_DAEMONS:-}" \
  DAEMON_BASELINE_OVERRIDES="${DAEMON_BASELINE_OVERRIDES:-}" \
  EXTRA_RUNTIME_ROOTS="" FORCE_RESTART_LABELS="" \
  LAUNCH_AGENTS_DIR="$AGENTS" \
  LAUNCHCTL_BIN="$BIN/launchctl" PS_BIN="$BIN/ps" \
  VERIFY_TIMEOUT=2 VERIFY_INTERVAL=0.2 \
  DRY_RUN=0 bash "$HELPER" 2>"$CASE_DIR/stderr.log"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/daemon-refresh-comment-only.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

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
  OUT=$(invoke_helper "$C0" "$C1"); RC=$?
  V=$(field VERDICT "$OUT"); P=$(field PROOF "$OUT"); G=$(field GUARDED "$OUT")
}

# ════════════════════════════════════════════════════════════════════════════
# T1: the incident — comment-only edit to an imported lib
# ════════════════════════════════════════════════════════════════════════════
run_lib_case t1 '# guard for human names
# wa-rhfeg: comentario novo explicando a lista abaixo,
# em varias linhas, sem mudar uma unica instrucao.
SEMPTY = ("sem nome", "")  # trailing comment too


def guard():
    """Return the verdict."""
    x = {"a": 1}
    return x["a"]
'
[ "$RC" -eq 0 ] && ok "T1 exit 0 — a comment-only lib edit does not hold the delivery" \
  || nok "T1 exit" "rc=$RC verdict=$V guarded=[$G]"
[ "$V" = "OK" ] && ok "T1 verdict OK (got '$V')" || nok "T1 verdict" "got '$V' out=[$OUT]"
[ "$P" = "not_applicable" ] && ok "T1 PROOF=not_applicable (no daemon code changed)" \
  || nok "T1 proof" "got '$P'"
[ -z "${G// /}" ] && ok "T1 GUARDED empty — the stale sensitive daemon is not flagged" \
  || nok "T1 guarded" "[$G]"
grep -q 'comment/format-only' "$CASE_DIR/stderr.log" \
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
# ════════════════════════════════════════════════════════════════════════════
new_case t7
printf '%s' "$LIB_V1" > "$RUNTIME/lib/other_guard.py"
add_daemon central_sender human_name_guard 4001
printf '%s' "$LIB_V1" > "$RUNTIME/lib/human_name_guard.py"
commit_at $((CHANGE_EPOCH - 7200)) base
C0=$(git -C "$RUNTIME" rev-parse HEAD)
# the daemon now imports a lib module that did not exist at C0
printf 'from lib.new_guard import guard\nprint(guard())\n' > "$RUNTIME/daemons/central_sender.py"
printf '%s' "$LIB_V1" > "$RUNTIME/lib/new_guard.py"
commit_at "$CHANGE_EPOCH" "new lib file"
C1=$(git -C "$RUNTIME" rev-parse HEAD)
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T7 added file stays flagged" \
  || nok "T7" "rc=$RC verdict=$V out=[$OUT]"

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
new_case t9
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
OUT=$(invoke_helper "$C0" "$C1"); RC=$?; V=$(field VERDICT "$OUT")
[ "$V" = "NEEDS_GUARDED_RESTART" ] && ok "T10 mode-only change stays flagged" \
  || nok "T10" "rc=$RC verdict=$V out=[$OUT]"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "daemon-refresh-comment-only-diff.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
