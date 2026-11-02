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

# ── HERMETIC section (ga-eedg7fw, hq-mutants): the script's OWN logic against a stub huggingface_hub ──────────────
# Why it exists: the sections below need the real recall-venv under /Users/athos/..., which a host without it (the
# Hetzner node's mutation jail: env -i, no /Users/athos) does not have — there the old selftest SKIPPED and exited 0, so
# every mutant of hf_cache_reap.py "survived" (15 of them in the hq-mutants lastro) no matter how good the assertions were.
# Here the interpreter is whatever `python3` is on PATH and `huggingface_hub` is a small stand-in (about 60 lines) on PYTHONPATH that
# logs each call (scan cache_dir=…, delete_revisions …, execute …) and can be told to fail (import, scan) or warn. What
# this proves: which dir reaches scan_cache_dir, the existence pre-check, the three outcomes (nothing / dry-run / prod)
# and their exit codes + exact messages, that PROD unset / 0 / true / empty stay dry-run while 1 deletes, and that failures (import, scan) exit 1
# and say so. What it cannot prove: that the real huggingface_hub API still has these names/shapes — that is the real-hub
# section further down (venv hosts only).
T="$(mktemp -d "${TMPDIR:-/tmp}/hf-cache-reap-selftest.XXXXXX")" || { echo "FAIL: no temp dir"; exit 1; }
trap 'rm -rf "$T" 2>/dev/null' EXIT
PY3="$(command -v python3 || true)"
if [ -z "$PY3" ]; then
  bad "hermetic section: no python3 on PATH"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi
mkdir -p "$T/stub/huggingface_hub"
cat > "$T/stub/huggingface_hub/constants.py" <<'PYEOF'
import os
HF_HUB_CACHE = os.environ.get("HF_HUB_CACHE", "/nonexistent-stub-hf-hub-cache")
PYEOF
cat > "$T/stub/huggingface_hub/__init__.py" <<'PYEOF'
import os
import shutil
from pathlib import Path


def _log(line):
    p = os.environ.get("FAKE_HF_LOG")
    if p:
        with open(p, "a") as f:
            f.write(line + "\n")


if os.environ.get("FAKE_HF_IMPORT_FAIL") == "1":
    raise ImportError("stub: huggingface_hub removed")


class _Rev:
    def __init__(self, commit_hash, size, path):
        self.commit_hash, self.size, self.path = commit_hash, size, path


class _Repo:
    def __init__(self, revisions):
        self.revisions = revisions


class _Strategy:
    def __init__(self, revs):
        self._revs = revs
        self.expected_freed_size = sum(r.size for r in revs)

    def execute(self):
        _log("execute " + ",".join(r.commit_hash for r in self._revs))
        for r in self._revs:
            shutil.rmtree(r.path)


class _Info:
    def __init__(self, repos, warnings):
        self.repos, self.warnings = repos, warnings
        self.size_on_disk = sum(rv.size for rp in repos for rv in rp.revisions)

    def delete_revisions(self, *hashes):
        _log("delete_revisions " + ",".join(hashes))
        want = set(hashes)
        return _Strategy([rv for rp in self.repos for rv in rp.revisions if rv.commit_hash in want])


def scan_cache_dir(cache_dir=None):
    _log("scan cache_dir=%s" % cache_dir)
    if os.environ.get("FAKE_HF_SCAN_RAISE") == "1":
        raise RuntimeError("stub: corrupt cache")
    from . import constants
    root = Path(cache_dir if cache_dir is not None else constants.HF_HUB_CACHE)
    if not root.is_dir():   # the real scan_cache_dir raises on a dir that does not exist
        raise FileNotFoundError("stub: cache dir missing: %s" % root)
    repos = []
    for rd in sorted(p for p in root.iterdir() if p.is_dir()):
        revs = []
        for cd in sorted(p for p in rd.iterdir() if p.is_dir()):
            revs.append(_Rev(cd.name, sum(f.stat().st_size for f in cd.iterdir() if f.is_file()), cd))
        repos.append(_Repo(revs))
    return _Info(repos, [w for w in os.environ.get("FAKE_HF_WARNINGS", "").split("|") if w])
PYEOF

# stub cache: repo-a has two revisions (100 B + 50 B), repo-b has one (25 B) → 2 repos, 3 revisions, 175 B
mk_stub_cache() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/repo-a/c1" "$d/repo-a/c2" "$d/repo-b/c3"
  head -c 100 /dev/zero > "$d/repo-a/c1/payload"
  head -c 50  /dev/zero > "$d/repo-a/c2/payload"
  head -c 25  /dev/zero > "$d/repo-b/c3/payload"
}
# hrun [VAR=val ...] [-- script args...]  → OUT (stdout), ERR (stderr), RC, FLOG (what the stub logged)
hrun() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  : > "$T/fake.log"
  OUT="$(env -u HF_CACHE_REAP_PROD -u HF_HUB_CACHE PYTHONPATH="$T/stub" FAKE_HF_LOG="$T/fake.log" ${envs[@]+"${envs[@]}"} "$PY3" "$SCRIPT" "$@" 2>"$T/err")"; RC=$?
  # vazio → "" (uma rodada sem stderr / sem chamada ao stub é um resultado válido, e as asserções distinguem "" de uma mensagem);
  # falhou/ilegível → os dois arquivos são criados por mim neste mesmo hrun (redirecionamento acima e `: >` antes), então não há "ausente" a tratar
  ERR="$(cat "$T/err")"; FLOG="$(cat "$T/fake.log")"
}
# hexpect <label> <want_rc> <want_stdout|-> <want_stderr_fragment> : rc, EXACT stdout ("-" = not checked), and a stderr fragment that must appear ("" or "-" = stderr not checked here)
hexpect() {
  local _l="$1" _rc="$2" _out="$3" _err="$4" _okk=1
  [ "$RC" = "$_rc" ] || _okk=0
  if [ "$_out" != "-" ] && [ "$OUT" != "$_out" ]; then _okk=0; fi
  if [ "$_err" != "-" ] && [ -n "$_err" ] && ! printf '%s' "$ERR" | grep -F -- "$_err" >/dev/null; then _okk=0; fi
  if [ "$_okk" = 1 ]; then ok "$_l"; else bad "$_l: want rc=$_rc out='$_out' err~'$_err'; got rc=$RC out='$OUT' err='$ERR'"; fi
}
hhas() { printf '%s\n' "$FLOG" | grep -Fx -- "$1" >/dev/null; }   # the stub log has exactly this line
hno()  { ! printf '%s\n' "$FLOG" | grep -F -- "$1" >/dev/null; }  # the stub log has no line containing this

echo "--- hermetic (stub huggingface_hub): the script's own logic ---"
HC="$T/cache"

# nothing to reclaim: the dir exists and holds no repo → rc 0, the repos=0 message, scan got THAT dir, nothing deleted
mkdir -p "$HC"; hrun -- "$HC"
hexpect "hermetic: existing empty dir → rc 0, 'nothing to reclaim (repos=0 size_on_disk=0)'" 0 "HF_CACHE_REAP: nothing to reclaim (repos=0 size_on_disk=0)" ""
hhas "scan cache_dir=$HC" && ok "hermetic: scan_cache_dir received the dir given as argv[1]" || bad "hermetic: scan_cache_dir did not get argv[1] ($FLOG)"
hno "delete_revisions" && ok "hermetic: nothing to reclaim → delete_revisions never called" || bad "hermetic: delete_revisions called on an empty cache"

# nonexistent dir: the pre-check answers BEFORE scan_cache_dir (which would raise) → rc 0, scan never called
hrun -- "$T/never-created"
hexpect "hermetic: nonexistent dir → rc 0 and the 'does not exist yet' message names the dir" 0 "HF_CACHE_REAP: nothing to reclaim (cache dir does not exist yet: $T/never-created)" ""
hno "scan cache_dir" && ok "hermetic: nonexistent dir → scan_cache_dir not even called (pre-check)" || bad "hermetic: scan_cache_dir was called on a missing dir ($FLOG)"
[ ! -e "$T/never-created" ] && ok "hermetic: nonexistent dir is not created" || bad "hermetic: the missing dir was created"

# no argv[1]: scan_cache_dir(cache_dir=None) and the default location comes from huggingface_hub.constants.HF_HUB_CACHE
mkdir -p "$T/default-cache"; hrun "HF_HUB_CACHE=$T/default-cache" --
hexpect "hermetic: no argument + default cache empty → rc 0, nothing to reclaim" 0 "HF_CACHE_REAP: nothing to reclaim (repos=0 size_on_disk=0)" ""
hhas "scan cache_dir=None" && ok "hermetic: no argument → scan_cache_dir(cache_dir=None) (hub resolves its own default)" || bad "hermetic: no-argument run did not scan with None ($FLOG)"
hrun "HF_HUB_CACHE=$T/default-missing" --
hexpect "hermetic: no argument + default cache missing → the message names the hub's default dir" 0 "HF_CACHE_REAP: nothing to reclaim (cache dir does not exist yet: $T/default-missing)" ""

# dry-run: only the literal string "1" deletes; unset, 0, true and empty all stay dry
for pv in UNSET 0 true ""; do
  mk_stub_cache "$HC"
  if [ "$pv" = UNSET ]; then hrun -- "$HC"; else hrun "HF_CACHE_REAP_PROD=$pv" -- "$HC"; fi
  hexpect "hermetic: PROD=${pv:-<empty>} → dry-run: rc 0 and the exact DRY-RUN line (175 bytes, 2 repo(s)/3 revision(s)), stderr empty" 0 "HF_CACHE_REAP: DRY-RUN would free 175 bytes across 2 repo(s)/3 revision(s) (set HF_CACHE_REAP_PROD=1 to actually delete)" ""
  [ -z "$ERR" ] && ok "hermetic: PROD=${pv:-<empty>} → nothing on stderr when the scan has no warnings" || bad "hermetic: PROD=${pv:-<empty>} → unexpected stderr: $ERR"
  hhas "delete_revisions c1,c2,c3" && ok "hermetic: PROD=${pv:-<empty>} → every revision hash was handed to delete_revisions, in scan order" || bad "hermetic: PROD=${pv:-<empty>} → delete_revisions got: $FLOG"
  hno "execute" && ok "hermetic: PROD=${pv:-<empty>} → strategy.execute() NOT called" || bad "hermetic: PROD=${pv:-<empty>} → execute() ran in a dry-run"
  [ -d "$HC/repo-a/c1" ] && [ -d "$HC/repo-a/c2" ] && [ -d "$HC/repo-b/c3" ] && ok "hermetic: PROD=${pv:-<empty>} → all revision dirs still on disk" || bad "hermetic: PROD=${pv:-<empty>} → a revision dir was deleted"
done

# prod: PROD=1 deletes, rc 0, the 'reclaimed' line says what was freed, execute() ran after delete_revisions
mk_stub_cache "$HC"; hrun HF_CACHE_REAP_PROD=1 -- "$HC"
hexpect "hermetic: PROD=1 → rc 0 and the exact 'reclaimed 175 bytes across 2 repo(s)/3 revision(s)' line" 0 "HF_CACHE_REAP: reclaimed 175 bytes across 2 repo(s)/3 revision(s)" ""
hhas "execute c1,c2,c3" && ok "hermetic: PROD=1 → strategy.execute() ran for all three revisions" || bad "hermetic: PROD=1 → execute log: $FLOG"
[ "$(printf '%s\n' "$FLOG" | sed -n 2p)" = "delete_revisions c1,c2,c3" ] && [ "$(printf '%s\n' "$FLOG" | sed -n 3p)" = "execute c1,c2,c3" ] && ok "hermetic: PROD=1 → order is scan, delete_revisions, execute" || bad "hermetic: PROD=1 → wrong call order: $FLOG"
[ ! -e "$HC/repo-a/c1" ] && [ ! -e "$HC/repo-a/c2" ] && [ ! -e "$HC/repo-b/c3" ] && ok "hermetic: PROD=1 → the revisions are gone from disk" || bad "hermetic: PROD=1 → a revision survived the reclaim"
hrun HF_CACHE_REAP_PROD=1 -- "$HC"
hexpect "hermetic: PROD=1 on the already-cleared cache → rc 0 and 'nothing to reclaim' (the repo dirs are still there, their revisions are not)" 0 "HF_CACHE_REAP: nothing to reclaim (repos=0 size_on_disk=0)" ""
hno "execute" && hno "delete_revisions" && ok "hermetic: PROD=1 on the already-cleared cache → no delete_revisions, no second execute" || bad "hermetic: the cleared cache was reclaimed again ($FLOG)"

# a scan that fails must exit 1 and say so (never "nothing to reclaim", never a delete)
mk_stub_cache "$HC"; hrun FAKE_HF_SCAN_RAISE=1 HF_CACHE_REAP_PROD=1 -- "$HC"
hexpect "hermetic: scan_cache_dir raises → rc 1, stdout empty, stderr 'ERROR scan_cache_dir failed (stub: corrupt cache)'" 1 "" "HF_CACHE_REAP: ERROR scan_cache_dir failed (stub: corrupt cache)"
hno "delete_revisions" && [ -d "$HC/repo-a/c1" ] && ok "hermetic: scan failure → nothing handed to delete_revisions, nothing deleted" || bad "hermetic: scan failure still reached delete_revisions or deleted ($FLOG)"

# no huggingface_hub (wrong interpreter) must fail loudly
mk_stub_cache "$HC"; hrun FAKE_HF_IMPORT_FAIL=1 -- "$HC"
hexpect "hermetic: huggingface_hub not importable → rc 1, stdout empty, stderr says so and names the cause" 1 "" "HF_CACHE_REAP: ERROR huggingface_hub not importable (stub: huggingface_hub removed) — wrong interpreter?"

# scan warnings are logged to stderr, one line each, and never block the reclaim
mk_stub_cache "$HC"; hrun "FAKE_HF_WARNINGS=w one|w two" -- "$HC"
hexpect "hermetic: warning 1 reaches stderr with its prefix" 0 "-" "HF_CACHE_REAP: WARNING during scan: w one"
printf '%s' "$ERR" | grep -Fx -- "HF_CACHE_REAP: WARNING during scan: w two" >/dev/null && ok "hermetic: warning 2 is its own stderr line" || bad "hermetic: warning 2 missing/merged: $ERR"
case "$OUT" in "HF_CACHE_REAP: DRY-RUN would free 175 bytes"*) ok "hermetic: warnings do not block the reclaim (the DRY-RUN line still comes out on stdout)" ;; *) bad "hermetic: warnings changed stdout: '$OUT'" ;; esac
echo "--- real huggingface_hub (needs the recall-venv) ---"

if [ ! -x "$VENV_PY" ]; then
  echo "SKIP: real-hub section: $VENV_PY not found/executable — recall-venv not built on this host, cannot exercise huggingface_hub (the hermetic section above ran)"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL (real-hub section skipped) ==="
  [ "$FAIL" -eq 0 ]
  exit
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
if [ "$RC" -eq 0 ] && echo "$OUT" | grep "nothing to reclaim" >/dev/null; then
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
if [ "$RC" -eq 0 ] && echo "$OUT" | grep "nothing to reclaim (cache dir does not exist yet" >/dev/null; then
  ok "nonexistent cache dir: exits 0, reports nothing to reclaim (not a scan-failure error)"
else
  bad "nonexistent cache dir: expected exit 0 + 'nothing to reclaim (cache dir does not exist yet', got rc=$RC out='$OUT'"
fi

# ── dry-run (no HF_CACHE_REAP_PROD): reports what it WOULD free, deletes nothing ──
DRY_DIR="$(mktemp -d /tmp/hf-cache-reap-selftest-dry.XXXXXX)"
make_fake_cache "$DRY_DIR"
OUT="$(unset HF_CACHE_REAP_PROD; "$VENV_PY" "$SCRIPT" "$DRY_DIR" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep "DRY-RUN would free" >/dev/null; then
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
if [ "$RC" -eq 0 ] && echo "$OUT" | grep "^HF_CACHE_REAP: reclaimed " >/dev/null; then
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
if [ "$RC2" -eq 0 ] && echo "$OUT2" | grep "nothing to reclaim" >/dev/null; then
  ok "prod, second run on already-cleared cache: idempotent no-op, not an error"
else
  bad "prod re-run: expected exit 0 + 'nothing to reclaim', got rc=$RC2 out='$OUT2'"
fi
rm -rf "$PROD_DIR"

# ── wrong interpreter: must fail loudly, never silently no-op ─────────────
SYS_PY="$(env -i PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" which python3 2>/dev/null || true)"
if [ -n "$SYS_PY" ]; then
  OUT="$("$SYS_PY" "$SCRIPT" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && echo "$OUT" | grep "huggingface_hub not importable" >/dev/null; then
    ok "wrong interpreter (no huggingface_hub): fails loudly with a clear message, does not silently exit 0"
  else
    # Not a failure of THIS script if the system python3 happens to also have
    # huggingface_hub installed — just not the scenario this guards against.
    echo "  SKIP: system python3 at $SYS_PY already has huggingface_hub — cannot exercise the ImportError path here"
  fi
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
