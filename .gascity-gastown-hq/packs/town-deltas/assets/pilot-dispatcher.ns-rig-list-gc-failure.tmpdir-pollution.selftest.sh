#!/usr/bin/env bash
# pilot-dispatcher.ns-rig-list-gc-failure.tmpdir-pollution.selftest.sh —
# regression harness for wa-x02jx / ga-bdebb0: running
# pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh must NEVER turn the raw
# OS temp directory into a git repository.
#
# ROOT BUG: that selftest built its fixture as
#     GC_CITY="$(mktemp -d)"            # -> $TMPDIR/tmp.XXXXXX
#     TOWNROOT="$(dirname "$GC_CITY")"  # -> $TMPDIR  (the shared OS temp root)
#     git -C "$TOWNROOT" init / config user.email t@t / commit --allow-empty -m init
# (TOWNROOT is dirname($GC_CITY) on purpose — pilot-dispatcher.sh builds its repo
# list as `{ dirname "$GC_CITY"; gc rig list ... }` — the bug is only that the
# fixture's GC_CITY sat DIRECTLY under the shared temp root instead of under a
# private parent). Every run therefore planted <tmp>/.git (author `t <t@t>`,
# empty commit "init"), and the WA pytest guard (tests/conftest.py, wa-cfjod)
# then REFUSED TO RUN for every agent on the machine until someone noticed.
#
# HOW THIS TESTS IT WITHOUT POLLUTING THE REAL TEMP ROOT: macOS /usr/bin/mktemp
# IGNORES $TMPDIR (even with -t), so `TMPDIR=<scratch> bash <selftest>` does NOT
# sandbox it — the first repro of this very bug escaped exactly that way and
# planted a live <tmp>/.git. Instead a `mktemp` shim on PATH redirects every
# template-less `mktemp [-d]` into a scratch "OS temp root" this harness owns, so
# even the UNFIXED selftest can only pollute that scratch dir.
#
#   A. positive control — the OLD fixture idiom, run under the same shim, DOES
#      create <tmproot>/.git. Without it a green B could just mean "the shim
#      redirected nothing" (a blind detector says the same thing as a clean run).
#   B. the real selftest, under the shim: still passes, and leaves NO .git at the
#      (fake) temp root.
#   C. the fail-closed tripwire (_refuse_if_townroot_is_os_tmp, defined in
#      selftest-tmproot-tripwire.lib.sh): refuses an OS-temp-root / empty /
#      unresolvable TOWNROOT, accepts a private directory.
#   D. the selftest REFUSES TO START when the tripwire lib is missing (copied alone
#      next to pilot-dispatcher.sh, no lib): non-zero exit, the reason is the missing
#      lib, and NOT ONE fixture dir is built. This is also exactly what the gate's
#      base-commit check (quality-gate-guard.sh, ga-rstae) sees: it overlays only the
#      `*.selftest.sh` files a branch changes onto the pre-fix base, the lib is not
#      one of them, so on the base the fix is absent and this harness fails for that
#      real reason (ga-bdebb0) instead of passing because the fix rode along.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/pilot-dispatcher.ns-rig-list-gc-failure.selftest.sh"
LIB="$HERE/selftest-tmproot-tripwire.lib.sh"

if [ ! -f "$TARGET" ]; then
  echo "FATAL: target selftest not found at $TARGET" >&2
  exit 2
fi
if [ ! -f "$LIB" ]; then
  echo "FATAL: tripwire lib not found at $LIB — the fix under test is not present" >&2
  exit 2
fi

# Resolve the real mktemp to an ABSOLUTE path before any PATH shimming.
REAL_MKTEMP="$(command -v mktemp)"
if [ -z "$REAL_MKTEMP" ] || [ ! -x "$REAL_MKTEMP" ]; then
  echo "FATAL: cannot resolve a real mktemp" >&2
  exit 2
fi

WORK="$("$REAL_MKTEMP" -d)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
  echo "FATAL: could not create the harness work dir" >&2
  exit 2
fi
trap 'rm -rf "$WORK"' EXIT

# extract_fn <name> <file> — prints a top-level `name() { ... }` function body
# (brace opens on the `name() {` line, closes on a bare `}` at column 0), or
# nothing if not found. Same helper as gc-json-or-unknown.selftest.sh.
extract_fn() {
  awk -v fn="$1" '
    $0 == fn"() {" { p=1 }
    p { print; if ($0 == "}") exit }
  ' "$2"
}

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

mkdir -p "$WORK/shim" "$WORK/fake-tmproot" "$WORK/ctl-tmproot"
cat > "$WORK/shim/mktemp" <<'EOF'
#!/bin/sh
# Test shim (see the harness header): send template-less `mktemp [-d]` into the
# scratch temp root instead of the real OS one; pass everything else through.
: "${SHIM_TMPROOT:?shim needs SHIM_TMPROOT}" "${SHIM_REAL_MKTEMP:?shim needs SHIM_REAL_MKTEMP}"
case "$#:${1:-}" in
  0:)   exec "$SHIM_REAL_MKTEMP" "$SHIM_TMPROOT/tmp.XXXXXXXX" ;;
  1:-d) exec "$SHIM_REAL_MKTEMP" -d "$SHIM_TMPROOT/tmp.XXXXXXXX" ;;
  *)    exec "$SHIM_REAL_MKTEMP" "$@" ;;
esac
EOF
chmod +x "$WORK/shim/mktemp"

# run_under_shim <scratch-tmproot> <cmd...>
run_under_shim() {
  local root="$1"; shift
  env SHIM_TMPROOT="$root" SHIM_REAL_MKTEMP="$REAL_MKTEMP" PATH="$WORK/shim:$PATH" "$@"
}

echo "== pilot-dispatcher.ns-rig-list-gc-failure.tmpdir-pollution.selftest (wa-x02jx / ga-bdebb0) =="

# ── A. positive control: the OLD idiom must be visible to this detector ──────
echo "-- A. control: the OLD fixture idiom pollutes the scratch temp root (detector is not blind) --"
run_under_shim "$WORK/ctl-tmproot" bash -c '
  GC_CITY="$(mktemp -d)"
  TOWNROOT="$(dirname "$GC_CITY")"
  git -C "$TOWNROOT" init -q
  git -C "$TOWNROOT" config user.email t@t
  git -C "$TOWNROOT" config user.name t
  git -C "$TOWNROOT" commit -q --allow-empty -m init
' >/dev/null 2>&1
if [ -d "$WORK/ctl-tmproot/.git" ]; then
  ok "control: old idiom under the shim planted <tmproot>/.git — the check in B can see this bug"
else
  bad "control: old idiom did NOT create <tmproot>/.git — the shim/detector is blind, B proves nothing"
fi

# ── B. the real selftest must leave the temp root alone ─────────────────────
echo "-- B. the real selftest leaves no .git at the (scratch) OS temp root --"
OUT="$WORK/target.out"
run_under_shim "$WORK/fake-tmproot" bash "$TARGET" > "$OUT" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  ok "target selftest still passes under the shim (rc=0)"
else
  bad "target selftest failed under the shim (rc=$rc) — tail of its output follows"
  tail -15 "$OUT" | sed 's/^/      | /'
fi
if [ -e "$WORK/fake-tmproot/.git" ]; then
  bad "target selftest planted <tmproot>/.git — it made the OS temp root a git repo (wa-x02jx)"
else
  ok "no <tmproot>/.git after the target selftest ran"
fi

# ── C. the fail-closed tripwire ─────────────────────────────────────────────
echo "-- C. tripwire _refuse_if_townroot_is_os_tmp: refuses a temp-root TOWNROOT, accepts a private dir --"
TW_SRC="$(extract_fn _refuse_if_townroot_is_os_tmp "$LIB")"
if [ -z "$TW_SRC" ]; then
  bad "_refuse_if_townroot_is_os_tmp() not found in the tripwire lib — no tripwire guards the fixture"
else
  mkdir -p "$WORK/ostmp/private"
  ( eval "$TW_SRC"; TMPDIR="$WORK/ostmp" _refuse_if_townroot_is_os_tmp "$WORK/ostmp" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "refuses TOWNROOT == \$TMPDIR (rc=$rc)"; else bad "accepted TOWNROOT == \$TMPDIR"; fi

  ( eval "$TW_SRC"; TMPDIR="$WORK/ostmp/" _refuse_if_townroot_is_os_tmp "$WORK/ostmp" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "refuses it even when \$TMPDIR carries a trailing slash (macOS shape) (rc=$rc)"; else bad "a trailing slash on \$TMPDIR defeated the comparison"; fi

  ( eval "$TW_SRC"; _refuse_if_townroot_is_os_tmp /tmp ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "refuses literal /tmp regardless of \$TMPDIR (rc=$rc)"; else bad "accepted /tmp as TOWNROOT"; fi

  ( eval "$TW_SRC"; TMPDIR="$WORK/ostmp" _refuse_if_townroot_is_os_tmp "$WORK/ostmp/private" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then ok "accepts a private child of the temp root (rc=0)"; else bad "refused a private child dir (rc=$rc) — the tripwire over-triggers"; fi

  ( eval "$TW_SRC"; TMPDIR="$WORK/ostmp" _refuse_if_townroot_is_os_tmp "" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "refuses an EMPTY TOWNROOT (rc=$rc) — an empty target must not fall through to cwd"; else bad "accepted an empty TOWNROOT"; fi

  ( eval "$TW_SRC"; TMPDIR="$WORK/ostmp" _refuse_if_townroot_is_os_tmp "$WORK/no-such-dir" ) >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then ok "refuses an UNRESOLVABLE TOWNROOT (rc=$rc) — can't-tell is not 'safe'"; else bad "accepted an unresolvable TOWNROOT"; fi
fi

# ── D. no tripwire lib -> the selftest must refuse to start ─────────────────
echo "-- D. the selftest refuses to start without the tripwire lib (what the gate's base overlay sees) --"
mkdir -p "$WORK/no-lib/dir" "$WORK/no-lib-tmproot"
cp "$TARGET" "$WORK/no-lib/dir/"
# The target loads pilot-dispatcher.sh from its own directory BEFORE it reaches the
# lib check; copy it too, or the target would abort on that first and this case would
# "pass" for the wrong reason (a missing dispatcher, not a missing lib).
cp "$HERE/pilot-dispatcher.sh" "$WORK/no-lib/dir/"
run_under_shim "$WORK/no-lib-tmproot" bash "$WORK/no-lib/dir/$(basename "$TARGET")" > "$WORK/no-lib.out" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then ok "target selftest exits non-zero without the lib (rc=$rc)"; else bad "target selftest ran to completion with NO tripwire lib — the fix is optional, not load-bearing"; fi
if grep -q "tripwire lib not found" "$WORK/no-lib.out"; then
  ok "and it says why: the tripwire lib is missing (not some earlier, unrelated failure)"
else
  bad "no 'tripwire lib not found' in the output — it stopped for some other reason, this case proves nothing"
  tail -8 "$WORK/no-lib.out" | sed 's/^/      | /'
fi
if [ -z "$(ls -A "$WORK/no-lib-tmproot" 2>/dev/null)" ]; then
  ok "no fixture dir was built at the (scratch) temp root before it stopped"
else
  bad "the selftest built something under the temp root before refusing: $(ls -A "$WORK/no-lib-tmproot" | tr '\n' ' ')"
fi

echo
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ]
