#!/usr/bin/env bash
# template-fragment-lint-guard.sh — Parse-validate changed prompt templates
# and template-fragments before the gate can mark tests:passed.
#
# ga-8fwusw: a Go text/template fragment can be textually correct (passes
# every grep-based selftest, diffs clean against origin/main) yet FAIL TO
# PARSE. A parse failure on a shared/global fragment silently drops the
# ENTIRE fragment from every prompt that injects it — and nothing in the
# normal render path (`gc prime`, agent spawn) turns that into a non-zero
# exit; the error is printed to stderr and swallowed. Root cause: line 825
# of town-deltas.template.md wrote `{{rig_root}}` (Go template function-call
# syntax) inside a PROSE sentence describing formula-variable syntax,
# instead of the field form `{{ .RigRoot }}` used everywhere else in the
# file. Every other agent in the town silently lost the entire ~52KB
# fragment — including REGRA No. 1 — until this was caught by a witness
# patrol reading `gc prime`'s own stderr by hand.
# See memory: town-deltas-fragment-merged-selftest-green-not-in-prompt.md
#
# This guard is the pre-merge counterpart: `gc lint <pack>` parses every
# prompt template plus every shared/fragment template it loads (same
# precedence chain as runtime rendering) and — verified empirically,
# 2026-09-16 — DOES exit non-zero and report `error_count>0` on exactly
# this class of failure (parse error, execute error, or an
# inject_fragment/append_fragment name with no matching template).
#
# Usage:
#   template-fragment-lint-guard.sh <worktree_path> [changed-file ...]
#
# <worktree_path> is the repo root the changed-file paths are relative to
# (e.g. the gate reviewer's $WORKTREE_PATH). Changed files are typically
# passed via `git diff --name-only`, one per arg or newline-split by the
# caller — this script only cares about the ones matching a template/
# fragment/pack.toml pattern; everything else is ignored.
#
# Exit 0: no changed file matches a template/fragment/pack.toml pattern,
#         OR every pack owning a matched file lints clean,
#         OR the ONLY error-severity diagnostics are the four known
#         lint-context artifacts in KNOWN_LINT_ARTIFACTS_JSON below (printed
#         as "tolerated" so a reader sees them; see that block for what this
#         does and does not cover).
# Exit 1: at least one owning pack has an error-severity `gc lint` diagnostic
#         that is not on that list -- including any case where the list
#         cannot be applied (gc lint output is not parseable, jq is missing,
#         the declared error_count does not match the diagnostics found, or a
#         pack reports ok:false with no diagnostic to explain it).
# Exit 2: usage error (missing/bad worktree path).
#
# Read-only. No bd/dolt/git mutation, safe to run any number of times
# against any worktree.

set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: template-fragment-lint-guard.sh <worktree_path> [changed-file ...]" >&2
  exit 2
fi

WORKTREE_PATH="$1"
shift

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "template-fragment-lint-guard: worktree path not found: $WORKTREE_PATH" >&2
  exit 2
fi

# ga-7x28kl: four `gc lint` errors exist on main that no change to a prompt
# template can cause or cure, and they hard-failed every bead that touched an
# agents/*/prompt.template.md (mol-quality-gate-runner turns exit!=0 into
# tests:failed). Each is an artifact of linting the repo pack ON ITS OWN, not
# a defect in what the city renders:
#   - agents/gate-reviewer and agents/refino-gate-reviewer call
#     {{ template "propulsion-dog" . }}. That fragment is defined in the
#     builtin `gastown` system pack (.gc/system/packs/gastown/template-
#     fragments/propulsion.template.md), which the CITY imports
#     (city.toml [imports.gastown]) and this pack deliberately does not
#     (pack.toml: "contido ... herda system gastown via city.toml"). A
#     standalone lint cannot see it. Importing it here would change the
#     pack's design, so the lint is what gets taught, not the pack.
#   - internal/templates/messages/{escalation,handoff}.md.tmpl range over
#     .Suggestions / .NextSteps. The lint renders with no data, so the range
#     has nothing to iterate. No reference to either file was found in this
#     repo's go/sh/py/toml sources.
# The list is keyed on (path relative to the pack, message with gc's
# "template: prompt:LINE:COL:" position prefix stripped), so a line shift is
# tolerated but a different file or a different message is not. What this
# does NOT do: it cannot tell a real runtime break of one of these four from
# the artifact -- e.g. propulsion-dog genuinely disappearing from the system
# pack still reads as "not defined" here, exactly as it did before this list.
# A new agent prompt that calls a system-pack fragment gets the same lint
# error and must be added here on purpose; that friction is intended.
KNOWN_LINT_ARTIFACTS_JSON=$(cat <<'JSON'
[
  {"rel": ".gascity-gastown-hq/agents/gate-reviewer/prompt.template.md",
   "msg": "executing \"prompt\" at <{{template \"propulsion-dog\" .}}>: template \"propulsion-dog\" not defined"},
  {"rel": ".gascity-gastown-hq/agents/refino-gate-reviewer/prompt.template.md",
   "msg": "executing \"prompt\" at <{{template \"propulsion-dog\" .}}>: template \"propulsion-dog\" not defined"},
  {"rel": "internal/templates/messages/escalation.md.tmpl",
   "msg": "executing \"prompt\" at <.Suggestions>: range can't iterate over"},
  {"rel": "internal/templates/messages/handoff.md.tmpl",
   "msg": "executing \"prompt\" at <.NextSteps>: range can't iterate over"}
]
JSON
)

# classify_lint_failure <gc-lint-json>
# Returns 0 only when the failure is fully explained by KNOWN_LINT_ARTIFACTS_JSON.
# Every uncertain case returns 1 (the caller then fails the guard): the
# question is "is this failure ONLY the known artifacts?", and "I could not
# tell" must not answer yes. Sets CLASSIFY_WHY (reason on 1) and
# CLASSIFY_REPORT (human lines, always).
CLASSIFY_WHY=""
CLASSIFY_REPORT=""
classify_lint_failure() {
  local json="$1" verdict
  CLASSIFY_WHY=""
  CLASSIFY_REPORT=""
  if ! command -v jq >/dev/null 2>&1; then
    CLASSIFY_WHY="jq not on PATH, so the known-artifact list cannot be applied"
    return 1
  fi
  if ! verdict=$(printf '%s' "$json" | jq -c --argjson known "$KNOWN_LINT_ARTIFACTS_JSON" '
      def norm: sub("^template: prompt:[0-9]+:[0-9]+: "; "");
      [ (.packs // [])[] as $p
        | ($p.diagnostics // [])[]
        | select(.severity == "error")
        | {rel: (.path | ltrimstr($p.path + "/")), msg: (.message | norm)} ] as $errs
      | ($errs | map(. as $e | select($known | any(.rel == $e.rel and .msg == $e.msg)))) as $isknown
      | ($errs | map(. as $e | select($known | any(.rel == $e.rel and .msg == $e.msg) | not))) as $isnew
      | { declared: .error_count,
          found: ($errs | length),
          silent_packs: ([ (.packs // [])[] | select(.ok == false)
                           | select(([(.diagnostics // [])[] | select(.severity == "error")] | length) == 0) ] | length),
          known: $isknown,
          unknown: $isnew }
      | .tolerable = (.declared == .found and .found > 0 and .silent_packs == 0 and (.unknown | length) == 0)
    ' 2>/dev/null) || [ -z "$verdict" ]; then
    # jq exits 0 with NO output on empty input, so an empty report is checked
    # for explicitly -- it is "could not tell", not "no errors".
    CLASSIFY_WHY="gc lint output is empty or not parseable JSON, so its errors cannot be matched against the known-artifact list"
    return 1
  fi
  CLASSIFY_REPORT=$(printf '%s' "$verdict" | jq -r '
      (.known[]   | "  tolerated (known lint-context artifact, ga-7x28kl): \(.rel) -- \(.msg)"),
      (.unknown[] | "  NEW (not on the known list): \(.rel) -- \(.msg)")')
  if printf '%s' "$verdict" | jq -e '.tolerable' >/dev/null 2>&1; then
    return 0
  fi
  CLASSIFY_WHY=$(printf '%s' "$verdict" | jq -r '
      "declared error_count=\(.declared), error diagnostics found=\(.found), " +
      "NEW=\(.unknown | length), packs ok:false with no diagnostic=\(.silent_packs)"')
  return 1
}

# Matches the file classes gc's prompt renderer treats as Go text/template
# input (renderPromptWithMeta in cmd/gc/prompt.go): canonical/legacy prompt
# templates, anything under a template-fragments/ or prompts/shared/ dir,
# plus pack.toml itself (declares inject_fragments/append_fragments — a
# rename/typo there can point at a fragment name that no longer exists).
MATCH_RE='(^|/)template-fragments/|(^|/)prompts/shared/|\.template\.md$|\.md\.tmpl$|(^|/)pack\.toml$'

RELEVANT=()
for f in "$@"; do
  [ -z "$f" ] && continue
  if printf '%s\n' "$f" | grep -E "$MATCH_RE" >/dev/null; then
    RELEVANT+=("$f")
  fi
done

if [ "${#RELEVANT[@]}" -eq 0 ]; then
  echo "template-fragment-lint-guard: no changed file matches a template/fragment/pack.toml pattern -- skipping gc lint."
  exit 0
fi

if ! command -v gc >/dev/null 2>&1; then
  echo "template-fragment-lint-guard: WARNING: 'gc' not on PATH -- cannot lint changed template files (${RELEVANT[*]}). NOT blocking, but this check did NOT run." >&2
  exit 0
fi

echo "template-fragment-lint-guard: template/fragment/pack.toml files changed:"
printf '  %s\n' "${RELEVANT[@]}"

# Resolve each relevant file to its owning pack (nearest ancestor directory
# containing pack.toml, never searching above $WORKTREE_PATH) and collect
# the unique pack roots to lint. Avoids bash4-only associative arrays (this
# runs inside a gate-reviewer worktree of unknown bash version) by spooling
# candidates to a tempfile and deduping with `sort -u`.
PACK_ROOTS_FILE=$(mktemp)
LINT_ERR_FILE=$(mktemp)
trap 'rm -f "$PACK_ROOTS_FILE" "$LINT_ERR_FILE"' EXIT

for f in "${RELEVANT[@]}"; do
  dir="$WORKTREE_PATH/$(dirname -- "$f")"
  pack=""
  while :; do
    if [ -f "$dir/pack.toml" ]; then
      pack="$dir"
      break
    fi
    if [ "$dir" = "$WORKTREE_PATH" ] || [ "$dir" = "/" ]; then
      break
    fi
    dir="$(dirname -- "$dir")"
  done
  if [ -z "$pack" ]; then
    echo "template-fragment-lint-guard: WARNING: no pack.toml found above changed file $f -- skipping (nothing to gc lint against)." >&2
    continue
  fi
  echo "$pack" >> "$PACK_ROOTS_FILE"
done

FAILED=0
if [ -s "$PACK_ROOTS_FILE" ]; then
  while IFS= read -r pack; do
    [ -z "$pack" ] && continue
    echo "template-fragment-lint-guard: gc lint $pack"
    # stdout (the JSON report) and stderr (gc's loader warnings) are captured
    # apart: merged, a single warning line makes the report unparseable and
    # the known-artifact list could never be applied.
    if LINT_JSON=$(gc lint "$pack" --json 2>"$LINT_ERR_FILE"); then
      echo "template-fragment-lint-guard: OK -- $pack"
    elif classify_lint_failure "$LINT_JSON"; then
      echo "template-fragment-lint-guard: OK (only known lint-context artifacts) -- $pack"
      echo "$CLASSIFY_REPORT"
    else
      echo "template-fragment-lint-guard: FAIL -- $pack"
      echo "template-fragment-lint-guard: not tolerated: $CLASSIFY_WHY"
      [ -n "$CLASSIFY_REPORT" ] && echo "$CLASSIFY_REPORT"
      echo "$LINT_JSON"
      cat "$LINT_ERR_FILE"
      FAILED=1
    fi
  done < <(sort -u "$PACK_ROOTS_FILE")
fi

exit "$FAILED"
