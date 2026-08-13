#!/usr/bin/env bash
# digest-sweep — close past-day "Digest: YYYY-MM-DD" beads that are still open.
#
# Runs as an exec order (no LLM, no agent, no wisp). Backstop for
# mol-digest-generate's source-level fix (packs/town-deltas/formulas/
# mol-digest-generate.toml, ga-8f40w): that fix makes new digests archive as
# --type=message and close immediately, but this sweep is independent of
# issue_type on purpose — it catches ANY open "Digest: YYYY-MM-DD" bead
# (old producer, manual creation, a future regression in the formula) as a
# true safety net, not a mirror of the source fix.
#
# Daily cadence only — a digest is a daily object, no need to poll faster
# (see ga-y0g5x: a guard that outruns its own interval stacks concurrent
# runs and can take down Dolt).
#
# Safety: a title that doesn't parse as "Digest: YYYY-MM-DD", or whose date
# is today or in the future, is left untouched. Closing by mistake destroys
# information; the asymmetric cost means erring toward keep (a failed/absent
# parse must KEEP, never CLOSE).
#
# --include-infra (ga-4tt37, 2026-08-13): plain `bd list`, even with
# --status open, silently hides issue_type=message beads (an "infra" type)
# — confirmed live, 774 open message-type beads invisible without this
# flag. Digests are supposed to archive as message (ga-8f40w). Without
# --include-infra this sweep could only ever "catch" digests left open with
# the WRONG type, making the "independent of issue_type, true safety net"
# claim above false for exactly the type this fix produces. Add the flag or
# the header comment lies about what this script actually does.
set -euo pipefail

__SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$__SCRIPT_DIR/_bd_trace.sh" "digest-sweep"

TODAY="$(date -u +%Y-%m-%d)"

bd list --status open --include-infra --json --limit 0 2>/dev/null \
  | jq -r --arg today "$TODAY" '
      .[]
      | select(.title | test("^Digest: [0-9]{4}-[0-9]{2}-[0-9]{2}$"))
      | {id, date: (.title | capture("^Digest: (?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})$").d)}
      | select(.date < $today)
      | .id
    ' \
  | while IFS= read -r id; do
      [ -z "$id" ] && continue
      # No `|| true` here on purpose (ga-8f40w self-audit): a close failure
      # (race, DB hiccup) must abort visibly under set -e so the order-dispatch
      # controller log records it (it only logs on non-zero exit — see
      # gate-sweep.sh's header comment for the same convention), not disappear
      # silently while the sweep reports a clean run.
      bd close "$id" --reason "digest-sweep: past-day digest archived, informational artifact with no pending action"
    done
