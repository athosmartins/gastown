#!/bin/bash
# engine-window-reboot-noon.selftest.sh — hermetic behavioral test for
# engine-window-reboot-noon.sh (ga-8v5t2: PEND read the wrong top-level
# directory AND doubled into "0\n0" whenever the canonical queue was empty,
# so the Athos-facing reboot-confirmation message always undercounted).
#
# Hermetic: everything happens under a mktemp -d WORKDIR, including a fake
# HOME, and mocked `notify`/`gc` binaries on PATH so no real notification or
# mail send ever fires. Runs the REAL script as a subprocess (not a
# reimplementation of its logic), so this exercises the actual code path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/engine-window-reboot-noon.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1 -- $2"; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

MOCKBIN="$WORKDIR/bin"
mkdir -p "$MOCKBIN"

cat > "$MOCKBIN/notify" <<'EOF'
#!/bin/bash
echo "$@" > "$MOCK_CAPTURE_DIR/notify.args"
EOF
chmod +x "$MOCKBIN/notify"

cat > "$MOCKBIN/gc" <<'EOF'
#!/bin/bash
case "$1" in
  session) printf 'NAME STATUS ACTIVITY\n' ;;   # header only -> 0 active sessions
  mail)    echo "$@" > "$MOCK_CAPTURE_DIR/gc-mail.args" ;;
  *)       exit 0 ;;
esac
EOF
chmod +x "$MOCKBIN/gc"

# run_case <n_canonical_patches> <n_decoy_patches> <label> — fresh FAKE_HOME
# per call so the one-shot MARKER never carries over between cases, and
# fresh capture dir so gc-mail.args isn't stale from a prior case (e.g. an
# early exit before reaching the mail-send step would otherwise leave a
# PREVIOUS case's file readable and silently pass).
run_case() {
  local n_canonical="$1" n_decoy="$2" label="$3"
  local case_home="$WORKDIR/home-$label"
  local capture="$WORKDIR/capture-$label"
  mkdir -p "$capture" \
    "$case_home/Library/LaunchAgents" \
    "$case_home/gt/.gascity-gastown-hq/docs/pending-engine-window" \
    "$case_home/gt/docs/pending-engine-window"
  touch "$case_home/Library/LaunchAgents/com.gascity.engine-window-postboot.plist"
  # C-style loop, not `seq 1 "$n"` -- BSD seq (macOS default) emits "1\n0"
  # for `seq 1 0` instead of nothing, silently creating 2 files for an
  # intended-zero count.
  for ((i = 1; i <= n_canonical; i++)); do
    touch "$case_home/gt/.gascity-gastown-hq/docs/pending-engine-window/ga-fake$i.patch"
  done
  for ((i = 1; i <= n_decoy; i++)); do
    touch "$case_home/gt/docs/pending-engine-window/ga-decoy$i.patch"
  done
  HOME="$case_home" MOCK_CAPTURE_DIR="$capture" PATH="$MOCKBIN:$PATH" \
    bash "$SCRIPT" > "$capture/stdout" 2>&1
  echo "$capture"
}

echo "=== engine-window-reboot-noon.selftest.sh ==="

# ── T1: canonical dir has 3 patches, decoy top-level dir has 99 — the
# ── message must report 3 (the canonical count), never 99. Path-correctness
# ── half of ga-8v5t2. ───────────────────────────────────────────────────────
CAP1=$(run_case 3 99 t1)
MSG1=$(cat "$CAP1/gc-mail.args" 2>/dev/null)
if echo "$MSG1" | grep -qE '\(3 patch pendente\)'; then
  ok "T1 reports canonical count (3), ignoring the 99-file decoy directory"
else
  bad "T1 expected '(3 patch pendente)' in mail body" "$MSG1"
fi
if echo "$MSG1" | grep -qE '\(99 patch pendente\)'; then
  bad "T1 leaked the decoy top-level directory's count (99) into the message" "$MSG1"
else
  ok "T1 does not leak the decoy directory's count"
fi

# ── T2: canonical dir empty — pre-fix, a redundant '|| echo 0' doubled
# ── grep -c's own correct "0" output into "0\n0". Must read a clean "0".
# ── Doubling half of ga-8v5t2. ──────────────────────────────────────────────
CAP2=$(run_case 0 5 t2)
MSG2=$(cat "$CAP2/gc-mail.args" 2>/dev/null)
if echo "$MSG2" | grep -qE '\(0 patch pendente\)'; then
  ok "T2 reports a clean single '0' when the canonical queue is empty"
else
  bad "T2 expected '(0 patch pendente)', got a possibly-doubled/corrupted value" "$MSG2"
fi
if printf '%s' "$MSG2" | grep -qE '0[[:space:]]*$[[:space:]]*0'; then
  bad "T2 message contains a doubled-zero artifact" "$MSG2"
else
  ok "T2 message has no doubled-zero artifact"
fi

# ── T3: BOTH directories empty — isolates the doubling artifact precisely.
# ── Pre-fix, grep -c on the (wrong) top-level dir also finds nothing, so
# ── grep -c's own "0" plus the redundant `|| echo 0` both land in PEND,
# ── producing the literal "0\n0" this bug is named for. ─────────────────────
CAP3=$(run_case 0 0 t3)
MSG3=$(cat "$CAP3/gc-mail.args" 2>/dev/null)
if echo "$MSG3" | grep -qE '\(0 patch pendente\)'; then
  ok "T3 reports a clean single '0' when both directories are empty"
else
  bad "T3 expected '(0 patch pendente)' with both dirs empty" "$MSG3"
fi

echo ""
echo "engine-window-reboot-noon tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
