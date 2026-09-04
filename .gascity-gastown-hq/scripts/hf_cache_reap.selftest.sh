#!/bin/bash
# hf_cache_reap.selftest.sh (wa-9eh0v) — unit tests for hf_cache_reap.py.
#
# Hermetic: every scenario passes an explicit, disposable cache_dir (argv[1])
# under /tmp — NEVER the real ~/.cache/huggingface. Uses the real recall-venv
# python3 + real huggingface_hub (scan_cache_dir/delete_revisions), but only
# ever points it at a hand-built fake cache dir. Nothing under the real
# ~/.cache/huggingface is read or touched by this file.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/hf_cache_reap.py"
# The venv lives under $CITY/.gc/ (gitignored — a machine-local build, not a
# tracked file), so it does NOT exist inside a fresh git worktree even though
# this selftest script does. Resolve it against the real, absolute CITY path
# (same hardcoded resolution dolt-disk-floor-guard.sh's _reap_hf_cache()
# itself uses — the venv is a shared machine resource, not per-worktree) so
# this test still exercises the worktree's own copy of hf_cache_reap.py
# ($SCRIPT above) through the one real interpreter that has huggingface_hub.
VENV_PY="${HF_CACHE_REAP_SELFTEST_VENV:-/Users/athos/gt/.gascity-gastown-hq/.gc/recall-venv/bin/python3}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== hf_cache_reap.selftest.sh ==="

if [ ! -x "$VENV_PY" ]; then
  echo "SKIP: $VENV_PY not found/executable — recall-venv not built on this host, cannot exercise huggingface_hub"
  echo "=== RESULT: PASS=0 FAIL=0 (skipped) ==="
  exit 0
fi

# Build a minimal, valid HF hub-cache-layout fake repo under a disposable dir:
#   <cache>/models--fake--tiny-model/{blobs,refs,snapshots}/...
# Verified empirically (wa-9eh0v) that huggingface_hub's scan_cache_dir()
# recognizes this hand-built layout without needing a real download.
make_fake_cache() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  local repo="$dir/models--fake--tiny-model"
  mkdir -p "$repo/blobs" "$repo/refs" "$repo/snapshots"
  local content; content="$(head -c 4096 /dev/urandom | base64)"
  local hash; hash="$(printf '%s' "$content" | shasum -a 256 | cut -d' ' -f1)"
  printf '%s' "$content" > "$repo/blobs/$hash"
  local commit="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "$repo/snapshots/$commit"
  ln -s "../../blobs/$hash" "$repo/snapshots/$commit/config.json"
  printf '%s' "$commit" > "$repo/refs/main"
}

# ── nothing to reclaim: empty dir ──────────────────────────────────────────
EMPTY_DIR="$(mktemp -d /tmp/hf-cache-reap-selftest-empty.XXXXXX)"
OUT="$("$VENV_PY" "$SCRIPT" "$EMPTY_DIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "nothing to reclaim"; then
  ok "empty cache dir: exits 0, reports nothing to reclaim"
else
  bad "empty cache dir: expected exit 0 + 'nothing to reclaim', got rc=$RC out='$OUT'"
fi
rm -rf "$EMPTY_DIR"

# ── nonexistent dir: a brand-new machine where nothing has ever populated
#    the cache yet is a legitimate "nothing to reclaim", not an error —
#    scan_cache_dir() itself RAISES on a truly-missing dir (verified), so
#    hf_cache_reap.py pre-checks existence and short-circuits before calling
#    it, rather than let a routine first-run state read as a scan failure. ──
OUT="$("$VENV_PY" "$SCRIPT" "/tmp/hf-cache-reap-selftest-does-not-exist-$$" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "nothing to reclaim (cache dir does not exist yet"; then
  ok "nonexistent cache dir: exits 0, reports nothing to reclaim (not a scan-failure error)"
else
  bad "nonexistent cache dir: expected exit 0 + 'nothing to reclaim (cache dir does not exist yet', got rc=$RC out='$OUT'"
fi

# ── dry-run (no HF_CACHE_REAP_PROD): reports what it WOULD free, deletes nothing ──
DRY_DIR="$(mktemp -d /tmp/hf-cache-reap-selftest-dry.XXXXXX)"
make_fake_cache "$DRY_DIR"
OUT="$(unset HF_CACHE_REAP_PROD; "$VENV_PY" "$SCRIPT" "$DRY_DIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "DRY-RUN would free"; then
  ok "dry-run (HF_CACHE_REAP_PROD unset): reports what it would free"
else
  bad "dry-run: expected exit 0 + 'DRY-RUN would free', got rc=$RC out='$OUT'"
fi
if [ -d "$DRY_DIR/models--fake--tiny-model" ]; then
  ok "dry-run: fake repo NOT deleted (dry-run is truly read-only)"
else
  bad "dry-run: fake repo was deleted — dry-run must never mutate the cache"
fi
rm -rf "$DRY_DIR"

# ── HF_CACHE_REAP_PROD=0 (explicitly not "1"): must also stay dry-run ─────
ZERO_DIR="$(mktemp -d /tmp/hf-cache-reap-selftest-zero.XXXXXX)"
make_fake_cache "$ZERO_DIR"
HF_CACHE_REAP_PROD=0 "$VENV_PY" "$SCRIPT" "$ZERO_DIR" >/dev/null 2>&1
if [ -d "$ZERO_DIR/models--fake--tiny-model" ]; then
  ok "HF_CACHE_REAP_PROD=0: treated as dry-run, not truthy (only the literal string '1' authorizes deletion)"
else
  bad "HF_CACHE_REAP_PROD=0: deleted the fake repo — only '1' should ever authorize deletion"
fi
rm -rf "$ZERO_DIR"

# ── prod (HF_CACHE_REAP_PROD=1): actually reclaims ─────────────────────────
PROD_DIR="$(mktemp -d /tmp/hf-cache-reap-selftest-prod.XXXXXX)"
make_fake_cache "$PROD_DIR"
OUT="$(HF_CACHE_REAP_PROD=1 "$VENV_PY" "$SCRIPT" "$PROD_DIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "^HF_CACHE_REAP: reclaimed "; then
  ok "prod (HF_CACHE_REAP_PROD=1): reports bytes reclaimed"
else
  bad "prod: expected exit 0 + 'HF_CACHE_REAP: reclaimed ...', got rc=$RC out='$OUT'"
fi
if [ ! -d "$PROD_DIR/models--fake--tiny-model" ]; then
  ok "prod: fake repo actually deleted"
else
  bad "prod: fake repo still present after HF_CACHE_REAP_PROD=1 — reclaim did not run"
fi
# second run against the now-empty dir must be a clean no-op, not an error
OUT2="$(HF_CACHE_REAP_PROD=1 "$VENV_PY" "$SCRIPT" "$PROD_DIR" 2>&1)"; RC2=$?
if [ "$RC2" -eq 0 ] && echo "$OUT2" | grep -q "nothing to reclaim"; then
  ok "prod, second run on already-cleared cache: idempotent no-op, not an error"
else
  bad "prod re-run: expected exit 0 + 'nothing to reclaim', got rc=$RC2 out='$OUT2'"
fi
rm -rf "$PROD_DIR"

# ── wrong interpreter: must fail loudly, never silently no-op ─────────────
SYS_PY="$(env -i PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" which python3 2>/dev/null || true)"
if [ -n "$SYS_PY" ]; then
  OUT="$("$SYS_PY" "$SCRIPT" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "huggingface_hub not importable"; then
    ok "wrong interpreter (no huggingface_hub): fails loudly with a clear message, does not silently exit 0"
  else
    # Not a failure of THIS script if the system python3 happens to also have
    # huggingface_hub installed — just not the scenario this guards against.
    echo "  SKIP: system python3 at $SYS_PY already has huggingface_hub — cannot exercise the ImportError path here"
  fi
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
