#!/usr/bin/env bash
# prod-tests/whatsapp_automation/story-dc-4v71.sh
#
# Story-specific prod test for dc-4v71 — "Atlas freshness alert: stale-
# detector se data_dictionary.md não mudou em 30 dias (dc-9c0o E3 gap)".
# Invoked by run.sh when STORY_ID=dc-4v71.
#
# WHAT THIS PROVES (and what it deliberately does NOT):
#
#   PROVES — the code that actually DEPLOYED to WA_ROOT carries the feature
#   and it WORKS end-to-end against the real repo, not a mock:
#     1. scripts/check_atlas_freshness.py, scripts/atlas_freshness_cron.sh
#        and launchd/com.whatsapp.atlas-freshness.plist are present at the
#        deployed checkout — "merged" and "live" are different facts, and
#        this is the only thing worth asserting after a deploy since the
#        unit tests (tests/test_check_atlas_freshness_dc_4v71.py) already
#        ran green on the branch.
#     2. The plist parses (plistlib, the same parser the tooling actually
#        uses — plutil is more permissive and has hidden a bad plist before,
#        see tests/test_plists_parseiam.py / wa-z0e2g) and its PATH includes
#        ~/.local/bin, so `notify` resolves under launchd (wa-9gr39).
#     3. The checker RUNS against the real deployed repo (read-only, ~instant
#        — it's a couple of `git log` calls) and returns one of the three
#        contractual verdicts (FRESH/STALE/UNKNOWN) with well-formed JSON.
#        This is a real end-to-end exercise of the deployed code against
#        deployed data, not a synthetic fixture.
#
#   DOES NOT PROVE — that the daily 07:15 launchd job is loaded (that is a
#   deploy_daemons.sh concern, checked by its own auto-reinstall wiring and
#   tests/test_launchd_auto_reinstall_path.py) or that a real notification
#   would route correctly (that was verified by hand with NOTIFY_PREVIEW=1
#   during development — see scripts/atlas_freshness_cron.sh's header
#   comment — and is not something a prod-test should re-trigger, since a
#   real notify call is a side effect this test must not have).

set -uo pipefail

WA_ROOT="${WA_ROOT:-/Users/athos/gt/whatsapp_automation}"
PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON="$(command -v python3.11 || command -v python3)"

log()  { echo "[prod-test:dc-4v71] $*"; }
fail() { echo "[prod-test:dc-4v71] FAIL: $*" >&2; exit 1; }

CHECK="$WA_ROOT/scripts/check_atlas_freshness.py"
CRON="$WA_ROOT/scripts/atlas_freshness_cron.sh"
PLIST="$WA_ROOT/launchd/com.whatsapp.atlas-freshness.plist"

log "Check 1: deployed files present ..."
[ -f "$CHECK" ] || fail "checker not found at $CHECK — wrong WA_ROOT or deploy incomplete?"
[ -x "$CHECK" ] || fail "$CHECK exists but is not executable"
[ -f "$CRON" ] || fail "cron wrapper not found at $CRON"
[ -x "$CRON" ] || fail "$CRON exists but is not executable"
[ -f "$PLIST" ] || fail "launchd plist not found at $PLIST"
log "deployed files present OK"

log "Check 2: plist parses (plistlib) and PATH includes ~/.local/bin ..."
WA_PLIST="$PLIST" "$PYTHON" - <<'PY' || fail "plist check failed (see assertion above)"
import os
import plistlib
import sys

path = os.environ["WA_PLIST"]
with open(path, "rb") as fh:
    plist = plistlib.load(fh)

label = plist.get("Label", "")
assert label == "com.whatsapp.atlas-freshness", f"unexpected Label: {label!r}"

path_value = plist.get("EnvironmentVariables", {}).get("PATH", "")
local_bin = os.path.expanduser("~/.local/bin")
entries = path_value.split(":")
assert local_bin in entries, (
    f"PATH missing {local_bin} — notify would be invisible under launchd "
    f"(wa-9gr39). PATH={path_value!r}"
)
print("plist OK: label + PATH verified")
PY
log "plist OK"

log "Check 3: checker runs against the real deployed repo and returns a valid verdict ..."
OUT="$("$PYTHON" "$CHECK" --repo "$WA_ROOT" --json 2>&1)"
RC=$?
# The checker's OWN contract is exit 0/1/2 only (FRESH/STALE/UNKNOWN) — see
# check_atlas_freshness.py's module docstring. Anything else means the
# checker crashed in a way even its own UNKNOWN branch didn't catch.
case "$RC" in
  0|1|2) ;;
  *) fail "checker exited $RC (expected 0, 1, or 2) — output: $OUT" ;;
esac

VERDICT="$(WA_OUT="$OUT" "$PYTHON" - <<'PY'
import json
import os
try:
    result = json.loads(os.environ["WA_OUT"])
except Exception as e:
    print(f"BADJSON:{type(e).__name__}: {e}")
    raise SystemExit(0)
print(result.get("verdict", "MISSING"))
PY
)"

case "$VERDICT" in
  FRESH|STALE|UNKNOWN)
    log "checker returned well-formed JSON, verdict=$VERDICT (rc=$RC) OK"
    ;;
  *)
    fail "checker output was not well-formed JSON with a valid verdict field (got: $VERDICT). Raw: $OUT"
    ;;
esac

log "ALL PASS"
exit 0
