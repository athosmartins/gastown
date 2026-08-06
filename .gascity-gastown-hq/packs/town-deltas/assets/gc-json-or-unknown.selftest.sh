#!/usr/bin/env bash
# gc-json-or-unknown.selftest.sh — regression harness for gc_json_or_unknown()
# (ga-07509: "gc <cmd> --json prints an ERROR ENVELOPE to stdout on failure —
# `|| echo ""` never protects, and 16 call sites read the failure as a valid
# empty response").
#
# ROOT BUG: the idiom `VAR=$(gc ... --json 2>/dev/null || echo "")` assumes a
# failing `gc` produces empty output. It does not: `gc` prints a JSON envelope
# to STDOUT even when it exits non-zero (`{"ok":false,"error":{...}}` for gc's
# own subcommands; a bare `{"error":"..."}` with no "ok" key at all for
# `gc bd <sub>`, which delegates to bd's own JSON shape). The command
# substitution captures that envelope before `|| echo` ever runs, it parses
# as valid JSON, and a downstream `.field | length` read on it silently
# returns 0 — indistinguishable from "queried successfully, zero results".
#
# This proves the THREE-STATE contract (AC1): valid data / legitimate-empty /
# FAILURE are never collapsed into each other, and that exit-code-alone
# detection is insufficient (AC2: some paths print an error envelope and
# still exit 0).
#
# Extracts the real function body from pilot-dispatcher.sh (the canonical
# copy) rather than re-typing it, so this test can't silently drift from the
# shipped code — same philosophy as
# gate-author-submitted-by-toctou.selftest.sh sections A/B/D/E. Also verifies
# the 3 other production copies (quality-gate-dispatcher.sh,
# quality-gate-guard.sh, auto-refino-dispatcher.sh) stay byte-identical to
# the canonical copy — AC1 asks for "um helper UNICO"; per-file duplication
# is this codebase's established pattern (see bead_field_grep, duplicated in
# quality-gate-dispatcher.sh and quality-gate-guard.sh), but a helper whose
# copies can silently diverge across files isn't really "one" helper, so any
# drift is a hard failure here, not a warning.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_FILE="$HERE/pilot-dispatcher.sh"

# extract_fn <name> <file> — prints a top-level `name() { ... }` function
# body (brace opens on the `name() {` line, closes on a bare `}` at column 0)
# or nothing if not found.
extract_fn() {
  awk -v fn="$1" '
    $0 == fn"() {" { p=1 }
    p { print; if ($0 == "}") exit }
  ' "$2"
}

FN_SRC="$(extract_fn gc_json_or_unknown "$CANONICAL_FILE")"
if [ -z "$FN_SRC" ]; then
  echo "FATAL: gc_json_or_unknown() not found in $CANONICAL_FILE — nothing to test yet"
  exit 1
fi
eval "$FN_SRC"
if ! type gc_json_or_unknown >/dev/null 2>&1; then
  echo "FATAL: extraction ran but did not define a callable gc_json_or_unknown"
  exit 1
fi

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== gc-json-or-unknown.selftest (ga-07509) =="

# ═════════════════════════════════════════════════════════════════════════
# 1. FAILURE must never be silently read as legitimate-empty (the bug itself)
# ═════════════════════════════════════════════════════════════════════════
echo "-- failure envelope (ga-07509 exact repro shape: ok:false, exit!=0) --"
mockgc() { echo '{"schema_version":"1","ok":false,"error":{"code":"command_failed","message":"boom","exit_code":1}}'; return 1; }
if out=$(gc_json_or_unknown mockgc --city /nonexistent session list --json); then
  bad "helper reported SUCCESS on a failing gc call (the exact ga-07509 bug): out='$out'"
else
  ok "helper reports FAILURE (rc=1) on a failing gc call"
fi
[ -z "${out:-}" ] && ok "stdout is empty on failure (nothing for a caller to mistake for data)" \
  || bad "on failure, stdout must be empty, got: '$out'"
unset -f mockgc

echo "-- exit 0 but envelope says ok:false (AC2: exit code alone is insufficient) --"
mockgc() { echo '{"schema_version":"1","ok":false,"error":{"code":"partial","message":"degraded"}}'; return 0; }
if out=$(gc_json_or_unknown mockgc --city X session list --json); then
  bad "helper reported SUCCESS despite ok:false in the envelope: out='$out'"
else
  ok "helper reports FAILURE on ok:false even when gc itself exited 0 (AC2)"
fi
unset -f mockgc

echo "-- bd-style failure: no 'ok' key at all, bare error string + nonzero exit --"
mockgc() { echo '{"error":"no issues found matching the provided IDs","schema_version":1}'; return 1; }
if out=$(gc_json_or_unknown mockgc --city X bd show ga-fake --json); then
  bad "helper reported SUCCESS on a bd-show-style failure (no ok key, exit!=0): out='$out'"
else
  ok "helper reports FAILURE on bd-show-style envelope via exit code, despite no 'ok' key"
fi
unset -f mockgc

echo "-- truly empty stdout + nonzero exit (e.g. a timeout killed it before any print) --"
mockgc() { return 124; }
if out=$(gc_json_or_unknown mockgc --city X dolt health --json); then
  bad "helper reported SUCCESS on empty stdout + nonzero exit: out='$out'"
else
  ok "helper reports FAILURE on empty stdout + nonzero exit (e.g. timeout rc=124)"
fi
unset -f mockgc

echo "-- malformed / truncated JSON on stdout, even with exit 0 --"
mockgc() { printf '{"sessions": [\n'; return 0; }
if out=$(gc_json_or_unknown mockgc --city X session list --json); then
  bad "helper reported SUCCESS on unparseable JSON: out='$out'"
else
  ok "helper reports FAILURE on unparseable JSON despite exit 0"
fi
unset -f mockgc

# ═════════════════════════════════════════════════════════════════════════
# 2. Legitimate empty results must still read as SUCCESS (AC5: non-regression)
# ═════════════════════════════════════════════════════════════════════════
echo "-- legitimate empty result (real ok:true envelope, zero items) --"
mockgc() { echo '{"schema_version":"1","ok":true,"sessions":[],"summary":{}}'; return 0; }
if out=$(gc_json_or_unknown mockgc --city X session list --json); then
  n=$(printf '%s' "$out" | jq '.sessions | length')
  [ "$n" = "0" ] && ok "genuinely-empty session list reads as SUCCESS with 0 sessions (not conflated with failure)" \
    || bad "unexpected session count: $n"
else
  bad "helper reported FAILURE on a genuinely successful, legitimately-empty response"
fi
unset -f mockgc

echo "-- legitimate empty/success, bd-show family (no 'ok' key, success shape) --"
mockgc() { echo '{"id":"ga-x","title":"t","assignee":"","status":"open"}'; return 0; }
if out=$(gc_json_or_unknown mockgc --city X bd show ga-x --json); then
  ok "successful bd-show-style response (no 'ok' key) reads as SUCCESS"
else
  bad "helper reported FAILURE on a successful bd-show response with no 'ok' key"
fi
unset -f mockgc

# ═════════════════════════════════════════════════════════════════════════
# 3. Valid non-empty data still flows through untouched
# ═════════════════════════════════════════════════════════════════════════
echo "-- valid non-empty data passes through intact --"
mockgc() { echo '{"schema_version":"1","ok":true,"sessions":[{"id":"s1"},{"id":"s2"}]}'; return 0; }
if out=$(gc_json_or_unknown mockgc --city X session list --json); then
  n=$(printf '%s' "$out" | jq '.sessions | length')
  [ "$n" = "2" ] && ok "valid data with 2 sessions passes through intact" || bad "expected 2 sessions, got $n"
else
  bad "helper reported FAILURE on valid non-empty data"
fi
unset -f mockgc

# ═════════════════════════════════════════════════════════════════════════
# 4. errexit-safety: the helper must not abort a `set -euo pipefail` caller
#    on ANY branch (failure or success) — every production file that will
#    carry this helper runs under exactly that mode.
# ═════════════════════════════════════════════════════════════════════════
echo "-- errexit-safety under set -euo pipefail (all 4 production files use it) --"
ERREXIT_OUT="$(bash -c '
  set -euo pipefail
  '"$FN_SRC"'
  failgc() { echo "{\"ok\":false}"; return 1; }
  if out=$(gc_json_or_unknown failgc); then
    echo "UNEXPECTED_SUCCESS"
  else
    echo "SURVIVED_FAILURE_BRANCH"
  fi
  okgc() { echo "{\"ok\":true,\"x\":1}"; return 0; }
  if out=$(gc_json_or_unknown okgc); then
    echo "SURVIVED_SUCCESS_BRANCH"
  else
    echo "UNEXPECTED_FAILURE"
  fi
' 2>&1)"
case "$ERREXIT_OUT" in
  *SURVIVED_FAILURE_BRANCH*SURVIVED_SUCCESS_BRANCH*)
    ok "helper does not trigger errexit abort on either branch under set -euo pipefail" ;;
  *)
    bad "helper aborts (or misbehaves) under set -euo pipefail — output: $ERREXIT_OUT" ;;
esac

# ═════════════════════════════════════════════════════════════════════════
# 5. Live repro — the EXACT command from the ga-07509 bug report, against
#    the real gc binary (not a mock). Proves the fix against reality.
# ═════════════════════════════════════════════════════════════════════════
echo "-- live repro against the real gc binary (bad city path) --"
if command -v gc >/dev/null 2>&1; then
  if out=$(gc_json_or_unknown gc --city /caminho/inexistente session list --json); then
    bad "LIVE repro: helper reported SUCCESS against the real gc binary on a bad city path: out='$out'"
  else
    ok "LIVE repro: helper reports FAILURE against the real gc binary on a bad city path (ga-07509's own repro command)"
  fi
else
  echo "  (skipped: gc binary not on PATH in this environment)"
fi

# ═════════════════════════════════════════════════════════════════════════
# 6. Drift guard — AC1 "um helper unico": the 3 other production copies
#    must stay byte-identical to the canonical one.
# ═════════════════════════════════════════════════════════════════════════
echo "-- drift guard across the 4 production copies --"
for f in quality-gate-dispatcher.sh quality-gate-guard.sh auto-refino-dispatcher.sh; do
  other_src="$(extract_fn gc_json_or_unknown "$HERE/$f")"
  if [ -z "$other_src" ]; then
    bad "$f: gc_json_or_unknown() not found (AC3 requires it in all 4 production files)"
  elif [ "$other_src" = "$FN_SRC" ]; then
    ok "$f: gc_json_or_unknown() is byte-identical to the canonical copy in pilot-dispatcher.sh"
  else
    bad "$f: gc_json_or_unknown() has DRIFTED from the canonical copy in pilot-dispatcher.sh"
  fi
done

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
