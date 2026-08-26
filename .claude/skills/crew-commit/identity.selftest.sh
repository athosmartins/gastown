#!/usr/bin/env bash
# identity.selftest.sh — regression harness for ga-qpsen
#
# BUG: crew-commit's Step 5 (and the WA rig's per-agent prompt.template.md
# "Fluxo de conclusão") used to tell agents to finish with bare `gt commit`
# or bare `git commit`. `gt commit` only auto-detects agent identity when
# the legacy `GT_ROLE` env var is set; this city assigns agents
# `GC_AGENT`/`GC_ALIAS` instead (confirmed live: GT_ROLE is unset in every
# session env checked, dog and crew alike). So `gt commit` silently takes
# its "no GT_ROLE -> human passthrough" branch, and plain `git commit` never
# had any identity logic to begin with — both inherit whatever
# `user.name`/`user.email` is already sitting in that worktree/clone's
# `.git/config`, which for every named whatsapp_automation crew clone
# (batista, digo, mila, oracle, peter, thies — live-checked) is the human's
# own global identity, athosmartins <athosmartins@gmail.com>. Confirmed live
# in real git log output across all six clones on 2026-08-26.
#
# THE FIX: an explicit `-c user.name=... -c user.email=...` override, scoped
# to the single commit invocation (never mutates the shared .git/config,
# which worktrees/clones do not isolate), deriving identity from GC_ALIAS
# (crew-commit also falls back to GC_AGENT for the generic/human case).
#
# Extracts the real recipes from the shipped docs rather than re-typing
# them, so this test can't silently drift from what agents actually read.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_FILE="$HERE/SKILL.md"
AGENTS_DIR="$(cd "$HERE/../../../.gascity-gastown-hq/agents" && pwd)"

P=0; F=0
ok(){ echo "  ok: $*"; P=$((P+1)); }
bad(){ echo "  BAD: $*"; F=$((F+1)); }

echo "== crew-commit identity.selftest (ga-qpsen) =="

if ! command -v gt >/dev/null 2>&1; then
  echo "  (skipped entirely: gt binary not on PATH in this environment)"
  echo "Results: $P passed, $F failed"
  echo "SELFTEST PASS"
  exit 0
fi

# extract_identity_block <file> — prints the fenced ```bash ... ``` block
# containing the IDENTITY= assignment (crew-commit SKILL.md's Step 5).
extract_identity_block() {
  awk '
    /^```bash$/ { in_block=1; buf=""; next }
    /^```$/ {
      if (in_block && buf ~ /IDENTITY=/) { printf "%s", buf; found=1; exit }
      in_block=0; buf=""; next
    }
    in_block { buf = buf $0 "\n" }
    END { if (!found) exit 1 }
  ' "$1"
}

# extract_wa_commit_line <file> — prints the single `git -c user.name=...
# commit ...` line from a WA agent's prompt.template.md "Fluxo de conclusão".
extract_wa_commit_line() {
  grep -m1 'user\.name="\$GC_ALIAS"' "$1"
}

STEP5_SRC="$(extract_identity_block "$SKILL_FILE")"
if [ -z "$STEP5_SRC" ]; then
  echo "FATAL: could not extract the IDENTITY= commit recipe from $SKILL_FILE Step 5"
  exit 1
fi

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

git -C "$WORK" init -q
# Simulate the real-world starting state: a worktree/clone whose local
# .git/config already carries SOME OTHER identity — exactly what every named
# whatsapp_automation crew clone showed live (athosmartins, not the crew
# member's own alias).
git -C "$WORK" config user.name "athosmartins"
git -C "$WORK" config user.email "athosmartins@gmail.com"
git -C "$WORK" commit -q --allow-empty -m "seed"

# stage_change — writes a unique file and stages it, so the recipes under
# test (none of which pass --allow-empty, matching what's actually shipped)
# always have something real to commit. Without this, "nothing to commit"
# and "the fix silently failed" collapse into the same observed symptom:
# HEAD simply doesn't move, and a redirected-to-/dev/null failure looks
# identical to a no-op success.
_STAGE_N=0
stage_change() {
  _STAGE_N=$((_STAGE_N + 1))
  echo "change $_STAGE_N" > "$WORK/file_$_STAGE_N.txt"
  git -C "$WORK" add "file_$_STAGE_N.txt"
}

export GC_ALIAS="test-agent-alias"
export GC_AGENT="test-agent-alias"
unset GT_ROLE GT_AGENT GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# ═════════════════════════════════════════════════════════════════════════
# 1. THE BUG ITSELF — bare `gt commit` against the real binary, GC_ALIAS set,
#    GT_ROLE unset (this city's actual, permanent env shape for every dog
#    and crew session). Must NOT be the agent's own alias.
# ═════════════════════════════════════════════════════════════════════════
echo "-- reproduces the bug: bare 'gt commit' does not pick up GC_ALIAS --"
( cd "$WORK" && gt commit --allow-empty -m "old path" ) >/dev/null 2>&1
OLD_AUTHOR=$(git -C "$WORK" log -1 --format='%an <%ae>')
if [ "$OLD_AUTHOR" = "test-agent-alias <test-agent-alias@gascity.local>" ]; then
  bad "bare 'gt commit' unexpectedly picked up the agent identity — has gt commit's GT_ROLE detection changed upstream? (author: $OLD_AUTHOR)"
else
  ok "bare 'gt commit' reproduces the bug — commit landed as '$OLD_AUTHOR', not the agent's own identity"
fi

# ═════════════════════════════════════════════════════════════════════════
# 2. THE FIX (crew-commit skill) — the exact Step 5 recipe, same environment.
# ═════════════════════════════════════════════════════════════════════════
echo "-- crew-commit SKILL.md Step 5 recipe produces the agent's own identity --"
stage_change
( cd "$WORK" && eval "$STEP5_SRC" ) >/dev/null 2>&1
NEW_AUTHOR=$(git -C "$WORK" log -1 --format='%an <%ae>')
if [ "$NEW_AUTHOR" = "test-agent-alias <test-agent-alias@gascity.local>" ]; then
  ok "Step 5's recipe correctly authors the commit as 'test-agent-alias <test-agent-alias@gascity.local>'"
else
  bad "Step 5's recipe did not produce the agent identity — got '$NEW_AUTHOR'"
fi

echo "-- fix does not persist into the shared .git/config --"
PERSISTED_NAME=$(git -C "$WORK" config user.name)
if [ "$PERSISTED_NAME" = "athosmartins" ]; then
  ok "shared .git/config user.name is untouched ('athosmartins') — override was commit-scoped only"
else
  bad "shared .git/config user.name was mutated to '$PERSISTED_NAME' — the recipe must use -c, never 'git config user.name'"
fi

echo "-- human passthrough (no GC_ALIAS/GC_AGENT) falls through safely --"
stage_change
( unset GC_ALIAS GC_AGENT; cd "$WORK" && eval "$STEP5_SRC" ) >/dev/null 2>&1
HUMAN_AUTHOR=$(git -C "$WORK" log -1 --format='%an <%ae>')
if [ "$HUMAN_AUTHOR" = "athosmartins <athosmartins@gmail.com>" ]; then
  ok "with no GC_ALIAS/GC_AGENT, falls through to the ambient identity unchanged ('$HUMAN_AUTHOR')"
else
  bad "human passthrough produced an unexpected author: '$HUMAN_AUTHOR'"
fi

# ═════════════════════════════════════════════════════════════════════════
# 3. THE FIX (WA rig prompt templates) — the actual mechanism driving the
#    live bug: WA crew agents never invoked crew-commit/gt commit at all,
#    they followed their own prompt.template.md's "Fluxo de conclusão",
#    which said bare `git push origin HEAD` (implying a bare `git commit`
#    beforehand). Verify the fixed recipe in each of the 5 affected
#    per-agent templates (peter-wa is excluded: it never touches git).
# ═════════════════════════════════════════════════════════════════════════
echo "-- WA rig prompt.template.md recipes produce the agent's own identity --"
WA_AGENTS="mila oracle digo batista thies"
FIRST_WA_LINE=""
for a in $WA_AGENTS; do
  TPL="$AGENTS_DIR/${a}-wa/prompt.template.md"
  if [ ! -f "$TPL" ]; then
    bad "$a-wa: prompt.template.md not found at $TPL"
    continue
  fi
  LINE="$(extract_wa_commit_line "$TPL")"
  if [ -z "$LINE" ]; then
    bad "$a-wa: could not find the identity-aware commit line in prompt.template.md"
    continue
  fi
  if [ -z "$FIRST_WA_LINE" ]; then
    FIRST_WA_LINE="$LINE"
  elif [ "$LINE" != "$FIRST_WA_LINE" ]; then
    bad "$a-wa: commit recipe has DRIFTED from mila-wa's ('$LINE' vs '$FIRST_WA_LINE')"
  else
    ok "$a-wa: commit recipe is byte-identical to mila-wa's"
  fi

  stage_change
  ( cd "$WORK" && eval "$LINE" ) >/dev/null 2>&1
  TPL_AUTHOR=$(git -C "$WORK" log -1 --format='%an <%ae>')
  if [ "$TPL_AUTHOR" = "test-agent-alias <test-agent-alias@gascity.local>" ]; then
    ok "$a-wa: prompt.template.md recipe correctly authors as 'test-agent-alias <test-agent-alias@gascity.local>'"
  else
    bad "$a-wa: prompt.template.md recipe did not produce the agent identity — got '$TPL_AUTHOR'"
  fi
done

echo ""
echo "Results: $P passed, $F failed"
[ "$F" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; } || { echo "SELFTEST FAIL"; exit 1; }
