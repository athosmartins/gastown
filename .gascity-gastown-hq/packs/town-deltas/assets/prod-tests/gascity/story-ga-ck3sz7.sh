#!/usr/bin/env bash
# prod-tests/gascity/story-ga-ck3sz7.sh — prod test for ga-ck3sz7: the pack's selftests that stub gc/bd run the script
# under test on a PATH with no real gc/bd, and a guard keeps it that way.
#
# Origin: ga-d21b40 (29/09). A selftest ran the script under test with PATH="$T/bin:$PATH", `$T/bin/gc` being a stub.
# The harness died, $T went away with the stub, `command -v gc` walked down $PATH to /opt/homebrew/bin/gc — the REAL
# one — and two false "Reaper anomalies" mails reached the Mayor. ga-d21b40 fixed the 3 reaper selftests and left the
# helper (selftest-sandbox-path.lib.sh); ga-ck3sz7 converted the rest of the class (~30 selftests) and added
# selftest-path-sandbox-class.selftest.sh, which fails any pack selftest that stubs gc/bd in front of a PATH that
# still reaches the real ones.
#
# Verifies the DEPLOYED tree (the live town-deltas pack), not a copy:
#   1. the helper and the guard are deployed and parse under /bin/bash 3.2 (NOT a bare `bash -n`: Homebrew bash 5.x
#      accepts what the interpreter these selftests run under rejects — the ga-6aj348 lesson)
#   2. the deployed helper does what it says: while a stub exists it wins, and once the stub dir is GONE neither gc
#      nor bd resolves at all (the inert outcome) — measured here, not read off the comments
#   3. the deployed helper refuses to link gc/bd in as a "harmless tool"
#   4. the deployed class guard passes against the deployed pack (no leaky selftest outside its reasoned exemption
#      list, no stale exemption)
#
# Called by run.sh after deploy (STORY_ID=ga-ck3sz7). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
LIB="$ASSETS/selftest-sandbox-path.lib.sh"
GUARD="$ASSETS/selftest-path-sandbox-class.selftest.sh"
BASH32=/bin/bash

log()  { echo "[prod-test:gascity ga-ck3sz7] $*"; }
fail() { echo "[prod-test:gascity ga-ck3sz7] FAIL: $*" >&2; exit 1; }

[[ -f "$LIB" ]]   || fail "missing: $LIB"
[[ -f "$GUARD" ]] || fail "missing: $GUARD"
[[ -x "$BASH32" ]] || fail "$BASH32 not executable — cannot run the real-interpreter syntax check"
log "Deployed helper + class guard found."

# ── 1. Syntax under the interpreter the selftests run under ────────────────────
log "Checking syntax under $BASH32 ($("$BASH32" --version | head -n1 | sed 's/ (.*//'))..."
"$BASH32" -n "$LIB"   || fail "selftest-sandbox-path.lib.sh does not parse under $BASH32"
"$BASH32" -n "$GUARD" || fail "selftest-path-sandbox-class.selftest.sh does not parse under $BASH32"
log "  syntax OK ✓"

# ── 2 + 3. The deployed helper, measured ──────────────────────────────────────
T="$(mktemp -d "${TMPDIR:-/tmp}/ga-ck3sz7-prod.XXXXXX")" || fail "mktemp failed"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/gc"; cp "$T/bin/gc" "$T/bin/bd"; chmod +x "$T/bin/gc" "$T/bin/bd"

log "Exercising sandbox_path_init from the deployed helper..."
# A subshell: the helper is sourced into a throwaway shell so its globals never leak into this script.
RES="$( "$BASH32" -c '
  . "$1" || { echo "SOURCE-FAILED"; exit 0; }
  T="$2"
  sandbox_path_init "$T" cat >/dev/null 2>&1 || { echo "INIT-FAILED"; exit 0; }
  g="$(PATH="$SANDBOX_PATH" command -v gc)"; b="$(PATH="$SANDBOX_PATH" command -v bd)"
  [ "$g" = "$T/bin/gc" ] && [ "$b" = "$T/bin/bd" ] && echo "STUB-WINS" || echo "STUB-LOSES gc=$g bd=$b"
  # the fixture dir vanishes under a running child — the exact ga-d21b40 event
  mv "$T/bin" "$T/bin.gone"; mv "$T/tools" "$T/tools.gone"
  g="$(PATH="$SANDBOX_PATH" command -v gc 2>/dev/null)"; b="$(PATH="$SANDBOX_PATH" command -v bd 2>/dev/null)"
  [ -z "$g" ] && [ -z "$b" ] && echo "GONE-INERT" || echo "GONE-LEAKS gc=$g bd=$b"
  mv "$T/bin.gone" "$T/bin"; mv "$T/tools.gone" "$T/tools"
  sandbox_path_init "$T" gc >/dev/null 2>&1 && echo "GC-LINKABLE" || echo "GC-REFUSED"
  sandbox_path_init "$T" bd >/dev/null 2>&1 && echo "BD-LINKABLE" || echo "BD-REFUSED"
' _ "$LIB" "$T" 2>&1 )"
case "$RES" in *SOURCE-FAILED*) fail "the deployed helper cannot be sourced" ;; esac
case "$RES" in *INIT-FAILED*)   fail "sandbox_path_init failed on a plain fixture dir: $RES" ;; esac
case "$RES" in *STUB-WINS*)     log "  while the stub exists it is what gc/bd resolve to ✓" ;; *) fail "the stub does not win on the sandbox PATH: $RES" ;; esac
case "$RES" in *GONE-INERT*)    log "  once the stub dir is gone NEITHER gc nor bd resolves (inert outcome) ✓" ;; *) fail "gc/bd STILL resolve after the fixture dir is gone — the leak is back: $RES" ;; esac
case "$RES" in *GC-REFUSED*BD-REFUSED*) log "  gc/bd are refused as \"harmless tools\" ✓" ;; *) fail "the helper let gc/bd be linked in as a tool: $RES" ;; esac

# ── 4. The deployed class guard passes against the deployed pack ───────────────
# This is the real proof: it scans every *.selftest.sh in the live pack for the shape that caused ga-d21b40 and fails on
# any that is neither converted nor a reasoned exemption (and on any exemption that has gone stale).
log "Running selftest-path-sandbox-class.selftest.sh against the deployed pack..."
_to=""; command -v timeout >/dev/null 2>&1 && _to="timeout 600"
if $_to "$BASH32" "$GUARD" > "$T/guard.out" 2>&1; then
  log "  $(grep -E '^RESULT:' "$T/guard.out" | tail -n1) ✓"
else
  sed -n '/^C:/,$p' "$T/guard.out" | head -40 >&2
  fail "selftest-path-sandbox-class.selftest.sh reported a leaky selftest, a stale exemption or a detector regression"
fi

log "PASS"
exit 0
