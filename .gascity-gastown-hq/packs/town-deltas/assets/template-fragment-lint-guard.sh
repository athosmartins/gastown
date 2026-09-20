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
#         OR every pack owning a matched file lints clean.
# Exit 1: at least one owning pack has an error-severity `gc lint` diagnostic.
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
trap 'rm -f "$PACK_ROOTS_FILE"' EXIT

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
    if ! LINT_OUT=$(gc lint "$pack" --json 2>&1); then
      echo "template-fragment-lint-guard: FAIL -- $pack"
      echo "$LINT_OUT"
      FAILED=1
    else
      echo "template-fragment-lint-guard: OK -- $pack"
    fi
  done < <(sort -u "$PACK_ROOTS_FILE")
fi

exit "$FAILED"
