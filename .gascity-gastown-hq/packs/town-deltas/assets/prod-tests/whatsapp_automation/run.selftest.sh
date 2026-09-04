#!/usr/bin/env bash
# run.selftest.sh — regression + falsification harness for run.sh Check 4
# (ga-pbbs8: admin console check reproved on a single transient attempt and
# asserted a root cause — registration missing / daemon not restarted — that
# it never measured; curl-failure and empty-body also collapsed to the same
# value, so nobody could tell "unreachable" from "empty" from "measured but
# the string just isn't there").
#
# ga-pbbs8 acceptance criteria (all required):
#   1. FIXTURE: admin body missing the string on attempt 1, present on
#      attempt 2 -> check PASSES (retry worked), and logs that it retried.
#   2. CONTROL: admin body missing the string on ALL attempts -> check still
#      FAILS (retry did not become permissive).
#   3. CONTROL 2: curl-failed / empty-body / non-empty-without-string produce
#      three DIFFERENT fail messages (assert all three, not just one).
#   4. The fail message never asserts registration/restart as a measured
#      fact — only ever as an explicitly-labeled, unverified possible cause.
#   5. Smoke test: admin ok on the first attempt -> ALL PASS, no retry noise
#      (proves the fix didn't slow down or alter the common case).
#   6. REGRESSION ga-cjj3u (static): the SIGPIPE-vulnerable
#      `printf '%s' "$ADMIN_BODY" | grep -q "..."` pipe (under `set -uo
#      pipefail`, grep -q exiting at the first match SIGPIPEs printf mid-
#      write, and pipefail turns that into a false "string missing" — see
#      mail ga-wisp-3ws8wc8, oracle-wa) is gone from both call sites, the
#      file-based replacement is in place, and the file isn't deleted
#      before both checks read it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$SCRIPT_DIR/run.sh"

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

FIXDIR="$(mktemp -d)"
trap 'rm -rf "$FIXDIR"' EXIT

# ── fake curl: branches on port. Painel port always serves a trivial OK
# fixture (Checks 1/2 are not what this selftest is about). Admin port
# consults a per-call fixture "script" (one directive per line, one line
# consumed per curl invocation, pinned to the last line once exhausted) so
# each test case can dictate exactly what each retry attempt sees ──────────
FAKE_BIN="$FIXDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
outfile=""; wfmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s) shift ;;
    --max-time) shift 2 ;;
    -o) outfile="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

body=""; code="000"
if [[ "$url" == *":${PAINEL_PORT}/"* ]]; then
  body='<html><body>Kanban de histórias</body></html>'
  code="200"
elif [[ "$url" == *":${ADMIN_PORT}/"* ]]; then
  n=0
  [ -f "$FAKE_STATE_DIR/admin_counter" ] && n="$(cat "$FAKE_STATE_DIR/admin_counter")"
  n=$((n + 1))
  echo "$n" > "$FAKE_STATE_DIR/admin_counter"
  total="$(wc -l < "$FAKE_ADMIN_SCRIPT" | tr -d '[:space:]')"
  idx="$n"
  [ "$idx" -gt "$total" ] && idx="$total"
  directive="$(sed -n "${idx}p" "$FAKE_ADMIN_SCRIPT")"
  case "$directive" in
    curlfail) exit 7 ;;
    empty) body=""; code="200" ;;
    missing) body='<html><body>admin console content, no registration list here, padded so byte counts are non-trivial for assertions.</body></html>'; code="200" ;;
    ok) body="<html><body>Kanban de histórias (port ${PAINEL_PORT})</body></html>"; code="200" ;;
    *) echo "fake-curl: unknown directive '$directive'" >&2; exit 99 ;;
  esac
fi

if [ -n "$outfile" ]; then printf '%s' "$body" > "$outfile"; else printf '%s' "$body"; fi
[ -n "$wfmt" ] && printf '%s' "$code"
exit 0
FAKECURL
chmod +x "$FAKE_BIN/curl"

# ── fake painel source: Check 3 (SSTI-closed) must pass trivially — it is
# unrelated to what this selftest exercises ────────────────────────────────
cat > "$FIXDIR/painel_src.py" <<'EOF'
def index():
    html = "<html>Kanban de histórias</html>"
    return html
EOF

# run_admin_case SCRIPT — runs run.sh with the fake curl injected and the
# admin port driven by SCRIPT (one directive per line). Sets LAST_OUT/LAST_RC.
run_admin_case() {
  local script_content="$1"
  local state_dir; state_dir="$(mktemp -d)"
  printf '%s\n' "$script_content" > "$state_dir/admin_script"
  local out rc
  out=$(
    PATH="$FAKE_BIN:$PATH" \
    PAINEL_PORT=18202 ADMIN_PORT=18097 \
    PAINEL_SRC="$FIXDIR/painel_src.py" \
    FAKE_STATE_DIR="$state_dir" FAKE_ADMIN_SCRIPT="$state_dir/admin_script" \
    ADMIN_RETRY_DELAY=0 \
    bash "$RUN_SH" 2>&1
  )
  rc=$?
  rm -rf "$state_dir"
  LAST_OUT="$out"
  LAST_RC="$rc"
}

# ═════════════════════════════════════════════════════════════════════════
# 1. FIXTURE: missing on attempt 1, ok on attempt 2 -> retry saves it
# ═════════════════════════════════════════════════════════════════════════
echo "── Fixture: attempt1=missing attempt2=ok → retry saves it ──"
run_admin_case "missing
ok"
[ "$LAST_RC" -eq 0 ] && ok "exit 0 (retry worked)" || bad "expected exit 0, got $LAST_RC: $LAST_OUT"
echo "$LAST_OUT" | grep -qi "retry" && ok "log mentions it needed a retry" || bad "log does not mention retry: $LAST_OUT"
echo "$LAST_OUT" | grep -q "ALL PASS" && ok "suite reaches ALL PASS" || bad "suite did not reach ALL PASS: $LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════
# 2. CONTROL: missing on ALL attempts -> still fails (not permissive)
# ═════════════════════════════════════════════════════════════════════════
echo "── Control: missing on ALL attempts → still fails ──"
run_admin_case "missing"
[ "$LAST_RC" -ne 0 ] && ok "nonzero exit (retry did not become permissive)" || bad "expected nonzero exit, got 0: $LAST_OUT"
echo "$LAST_OUT" | grep -q "FAIL" && ok "FAIL is reported" || bad "no FAIL in output: $LAST_OUT"
echo "$LAST_OUT" | grep -q "3 attempt" && ok "ran the full retry budget (3 attempts) before giving up" || bad "message doesn't confirm 3 attempts: $LAST_OUT"

# ═════════════════════════════════════════════════════════════════════════
# 3. CONTROL 2: three distinct failure states -> three distinct messages
# ═════════════════════════════════════════════════════════════════════════
echo "── Control 2: curl-failed / empty-body / string-missing → different messages ──"
run_admin_case "curlfail"; MSG_CURLFAIL="$LAST_OUT"
run_admin_case "empty";    MSG_EMPTY="$LAST_OUT"
run_admin_case "missing";  MSG_MISSING="$LAST_OUT"

if [ "$MSG_CURLFAIL" != "$MSG_EMPTY" ] && [ "$MSG_EMPTY" != "$MSG_MISSING" ] && [ "$MSG_CURLFAIL" != "$MSG_MISSING" ]; then
  ok "three states produce three distinct messages"
else
  bad "two or more states produced the SAME message (still conflated)"
fi

echo "$MSG_CURLFAIL" | grep -qi "connect" && ok "curl-failed message names a connection failure" || bad "curl-failed message doesn't name a connection failure: $MSG_CURLFAIL"
echo "$MSG_EMPTY" | grep -qi "empty" && ok "empty-body message names an empty body" || bad "empty-body message doesn't say empty: $MSG_EMPTY"
echo "$MSG_MISSING" | grep -qi "does not contain" && ok "string-missing message names the missing string" || bad "string-missing message unclear: $MSG_MISSING"

# ═════════════════════════════════════════════════════════════════════════
# 4. registration/restart appears ONLY as an explicitly-labeled possible
#    cause, never as a measured fact — in every state, not just one
# ═════════════════════════════════════════════════════════════════════════
echo "── Criterion 4: registration/restart never asserted as measured fact ──"
for msg_name in MSG_CURLFAIL MSG_EMPTY MSG_MISSING; do
  msg="${!msg_name}"
  if echo "$msg" | grep -qi "registration\|restart"; then
    echo "$msg" | grep -q "Possible causes (not verified by this check)" \
      && ok "$msg_name: registration/restart mention is explicitly labeled as an unverified possible cause" \
      || bad "$msg_name: registration/restart asserted WITHOUT the unverified-possible-cause label: $msg"
  else
    ok "$msg_name: no registration/restart mention at all (fine — unrelated to this failure mode)"
  fi
done

# ═════════════════════════════════════════════════════════════════════════
# 5. Smoke test: first-attempt success -> ALL PASS, no retry noise
# ═════════════════════════════════════════════════════════════════════════
echo "── Smoke: admin ok on first attempt → ALL PASS, no retry noise ──"
run_admin_case "ok"
[ "$LAST_RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $LAST_RC: $LAST_OUT"
echo "$LAST_OUT" | grep -q "ALL PASS" && ok "reaches ALL PASS" || bad "did not reach ALL PASS: $LAST_OUT"
echo "$LAST_OUT" | grep -qi "retry" && bad "spurious retry-mention on a first-attempt success: $LAST_OUT" || ok "no spurious retry-mention when the first attempt already succeeds"

# ═════════════════════════════════════════════════════════════════════════
# 6. REGRESSION ga-cjj3u: SIGPIPE + pipefail false negative — static proof
#    against the shipped source, not the race itself. (A large-body dynamic
#    repro of the actual race was tried while writing this test: it
#    reproduced 20/20 in isolation but became timing-dependent enough to
#    HANG once exercised through the real run.sh + fake-curl harness under
#    load on this shared box. Shipping a race as a permanent gate check
#    would make the guard exactly as unreliable as the bug it guards
#    against, so this proves the fix structurally instead.)
#
#    Pre-fix, Check 4 and its WARN sibling ran
#        printf '%s' "$ADMIN_BODY" | grep -q "<pattern>"
#    under `set -uo pipefail` (run.sh line 18): grep -q exits at the first
#    match and closes the pipe; printf, still writing the remaining bytes,
#    dies of SIGPIPE, and pipefail promotes that into the pipeline's exit
#    status — `if ! pipeline; then` reads "string missing" from a pipeline
#    that failed because it found the string. Measured by oracle-wa (mail
#    ga-wisp-3ws8wc8): ~104KB body/~40KB offset, 19/20 reps wrong under
#    pipefail, 0/20 under a no-pipefail control.
# ═════════════════════════════════════════════════════════════════════════
echo "── Regression ga-cjj3u: SIGPIPE-vulnerable pipe gone, file-based grep in place ──"
if grep -Fq -- "printf '%s' \"\$ADMIN_BODY\" | grep" "$RUN_SH"; then
  bad "run.sh still pipes \$ADMIN_BODY through printf | grep — the SIGPIPE/pipefail race is still live"
else
  ok "no printf \"\$ADMIN_BODY\" | grep pipeline in run.sh"
fi
if grep -Fq -- "grep -q \"Kanban de histórias\" \"\$ADMIN_BODY_FILE\"" "$RUN_SH"; then
  ok "Check 4 FATAL greps \$ADMIN_BODY_FILE directly (no pipe, no SIGPIPE possible)"
else
  bad "Check 4 FATAL does not grep \$ADMIN_BODY_FILE directly"
fi
if grep -Fq -- "grep -q \"\${PAINEL_PORT}\" \"\$ADMIN_BODY_FILE\"" "$RUN_SH"; then
  ok "WARN sibling greps \$ADMIN_BODY_FILE directly (no pipe, no SIGPIPE possible)"
else
  bad "WARN sibling does not grep \$ADMIN_BODY_FILE directly"
fi
# The file must survive until the WARN sibling reads it — a fix that deletes
# it right after the curl+size step (like the pre-fix code did) would trade
# the SIGPIPE bug for an equally-wrong "grep: No such file" false negative.
curl_line=$(grep -n -F -- '-o "$ADMIN_BODY_FILE"' "$RUN_SH" | head -1 | cut -d: -f1) || true
warn_line=$(grep -n -F -- "grep -q \"\${PAINEL_PORT}\" \"\$ADMIN_BODY_FILE\"" "$RUN_SH" | head -1 | cut -d: -f1) || true
if [ -n "${curl_line:-}" ] && [ -n "${warn_line:-}" ]; then
  # A bare textual match would also flag the FATAL path's own
  # `rm -f "$ADMIN_BODY_FILE"` (immediately before `fail "$admin_detail"`)
  # as unsafe — but fail() is `{ echo ...; exit 1; }` above, so that branch
  # can never fall through to the WARN check in the same run. Only an rm
  # NOT paired with an immediately-following fail call is actually unsafe.
  unsafe_rm_line=$(awk -v lo="$curl_line" -v hi="$warn_line" '
    NR>lo && NR<hi {
      if (index($0, "rm -f \"$ADMIN_BODY_FILE\"") > 0) {
        if ($0 ~ /fail[ \t]/) { next }
        pending = NR
        next
      }
      if (pending) {
        if ($0 ~ /fail[ \t]/) { pending = 0 } else { print pending; exit }
      }
    }
    END { if (pending) print pending }
  ' "$RUN_SH")
  if [ -z "${unsafe_rm_line:-}" ]; then
    ok "\$ADMIN_BODY_FILE is not deleted before the WARN check (line $warn_line) can read it"
  else
    bad "\$ADMIN_BODY_FILE is deleted at line $unsafe_rm_line without an immediately-paired fail call — the WARN check (line $warn_line) could read a missing file"
  fi
else
  bad "could not locate both the curl fetch and the WARN grep to check \$ADMIN_BODY_FILE's lifetime (call sites moved?)"
fi

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
