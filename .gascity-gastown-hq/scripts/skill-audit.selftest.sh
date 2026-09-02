#!/usr/bin/env bash
# skill-audit.selftest.sh — Prove the skill-publish integrity loop in isolation.
#
# Builds a THROWAWAY fixture city under a temp dir and drives skill-audit.sh
# against it via the SKILL_AUDIT_* env overrides. It NEVER touches the live city,
# never runs gc, and never runs gc reload — so it is safe to run on a live host
# (honors the "no live config edit" doctrine).
#
# Scenarios:
#   1. clean             — symlink consumer + manifest matching canonical -> drift=0, offpath=0, ok
#   2. unmanaged         — skill present, no manifest entry              -> offpath>=1
#   3. offpath edit      — canonical changed after manifest recorded    -> offpath>=1
#   4. real-copy drift   — a real (non-symlink) consumer copy differs    -> drift>=1
#   5. dangling symlink  — consumer symlink target removed               -> drift>=1
#   6. redirected symlink— consumer symlink points somewhere else        -> drift>=1
#   8. gate-merged change— canonical changed by a fix that landed on origin/main
#                          (manifest stale, no skill-deploy.sh run)     -> offpath=0
#   9. uncommitted edit  — same city, but change is NOT committed        -> offpath>=1
#  10. local-only commit — change IS committed, but never merged to origin/main
#                          (ga-4rl78 gate finding)                      -> offpath>=1
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="$SELF_DIR/skill-audit.sh"
LIB="$SELF_DIR/skill-lib.sh"
source "$LIB"

PASS=0
FAIL=0
note() { echo "  $*"; }
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

# json_field <json> <field> — pull a numeric/string field without jq.
json_field() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$2" 2>/dev/null
}

# Run the auditor against a fixture. Echoes the JSON (stdout); summary suppressed.
run_audit() { # CITY WA MANIFEST SKILLS_JSON
    SKILL_AUDIT_CITY="$1" SKILL_AUDIT_WA="$2" SKILL_AUDIT_MANIFEST="$3" \
    SKILL_AUDIT_SKILLS_JSON="$4" "$AUDIT" --json-only --quiet
}

# ── Build a fresh fixture city for each scenario ──────────────────────────────
# Layout mirrors the real city:
#   <root>/city/skills/demo/SKILL.md           (canonical source sink)
#   <root>/city/.claude/skills/demo -> canonical   (HQ vendor symlink)
#   <root>/city/.gc/agents/a1/.claude/skills/demo -> canonical (agent symlink)
#   <root>/wa/crew/m1/.claude/skills/demo -> canonical         (crew symlink)
#   <root>/city/.gc/state/skill-manifest.json
make_fixture() {
    local root="$1"
    local city="$root/city" wa="$root/wa"
    mkdir -p "$city/skills/demo" \
             "$city/.claude/skills" \
             "$city/.gc/agents/a1/.claude/skills" \
             "$city/.gc/state" \
             "$wa/crew/m1/.claude/skills"
    printf 'canonical v1\n' > "$city/skills/demo/SKILL.md"
    mkdir -p "$city/skills/demo/references"
    printf 'ref v1\n' > "$city/skills/demo/references/notes.md"
    # consumer symlinks -> canonical
    ln -s "$city/skills/demo" "$city/.claude/skills/demo"
    ln -s "$city/skills/demo" "$city/.gc/agents/a1/.claude/skills/demo"
    ln -s "$city/skills/demo" "$wa/crew/m1/.claude/skills/demo"
}

# Write a manifest entry for demo matching the CURRENT canonical digest.
write_manifest() { # city
    local city="$1"
    local digest
    digest="$(skilllib_tree_digest "$city/skills/demo")"
    cat > "$city/.gc/state/skill-manifest.json" <<JSON
{
  "schema_version": "1",
  "skills": {
    "demo": {
      "tree_digest": "$digest",
      "deployed_at": "2026-01-01T00:00:00Z",
      "deployed_by": "selftest",
      "source_dir": "fixture"
    }
  }
}
JSON
}

# gc skill list --json stand-in: demo is a city skill at skills/demo/SKILL.md
SKILLS_JSON='{"count":1,"entries":[{"name":"demo","source":"city","path":"skills/demo/SKILL.md"}],"ok":true,"schema_version":"1"}'

scenario() { echo; echo "── scenario: $1 ──"; }

# ══ 1. clean ══════════════════════════════════════════════════════════════════
scenario "clean (symlinks + matching manifest)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
write_manifest "$ROOT/city"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" drift_count)" == "0" ]]   && ok "drift_count=0"   || bad "expected drift_count=0"
[[ "$(json_field "$OUT" offpath_count)" == "0" ]] && ok "offpath_count=0" || bad "expected offpath_count=0"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "expected exit 0, got $RC"
rm -rf "$ROOT"

# ══ 2. unmanaged (no manifest) ════════════════════════════════════════════════
scenario "unmanaged (no manifest entry)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
# deliberately no manifest written
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" -ge 1 ]] && ok "offpath flagged (unmanaged)" || bad "expected offpath>=1"
[[ "$(json_field "$OUT" drift_count)" == "0" ]]  && ok "drift_count=0 (symlinks intact)" || bad "expected drift_count=0"
[[ "$RC" == "1" ]] && ok "exit 1" || bad "expected exit 1, got $RC"
rm -rf "$ROOT"

# ══ 3. off-path edit (canonical changed after manifest) ═══════════════════════
scenario "off-path edit (canonical changed without redeploy)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
write_manifest "$ROOT/city"
# simulate a direct write to canonical AFTER the official deploy baseline
printf 'sneaky off-path edit\n' >> "$ROOT/city/skills/demo/SKILL.md"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" -ge 1 ]] && ok "offpath flagged (canonical drifted from manifest)" || bad "expected offpath>=1"
# symlinks still resolve to canonical, so consumers are NOT drift — only off-path
[[ "$(json_field "$OUT" drift_count)" == "0" ]]  && ok "drift_count=0 (consumers still symlinked)" || bad "expected drift_count=0"
rm -rf "$ROOT"

# ══ 4. real-copy drift ════════════════════════════════════════════════════════
scenario "real-copy drift (a consumer is a stale real copy)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
write_manifest "$ROOT/city"
# replace the agent's symlink with a STALE real copy
rm "$ROOT/city/.gc/agents/a1/.claude/skills/demo"
mkdir -p "$ROOT/city/.gc/agents/a1/.claude/skills/demo"
printf 'STALE v0 — old version\n' > "$ROOT/city/.gc/agents/a1/.claude/skills/demo/SKILL.md"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" drift_count)" -ge 1 ]] && ok "drift flagged (stale real copy)" || bad "expected drift>=1"
[[ "$RC" == "1" ]] && ok "exit 1" || bad "expected exit 1, got $RC"
rm -rf "$ROOT"

# ══ 5. dangling symlink ═══════════════════════════════════════════════════════
scenario "dangling symlink (canonical target gone for one consumer)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
write_manifest "$ROOT/city"
# point the crew symlink at a now-missing path
rm "$ROOT/wa/crew/m1/.claude/skills/demo"
ln -s "$ROOT/city/skills/does-not-exist" "$ROOT/wa/crew/m1/.claude/skills/demo"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
note "json: $OUT"
[[ "$(json_field "$OUT" drift_count)" -ge 1 ]] && ok "drift flagged (dangling symlink)" || bad "expected drift>=1"
rm -rf "$ROOT"

# ══ 6. redirected symlink ═════════════════════════════════════════════════════
scenario "redirected symlink (consumer points away from canonical)"
ROOT="$(mktemp -d)"
make_fixture "$ROOT"
write_manifest "$ROOT/city"
# create a decoy skill dir and point the vendor symlink at it
mkdir -p "$ROOT/city/decoy/demo"
printf 'decoy content\n' > "$ROOT/city/decoy/demo/SKILL.md"
rm "$ROOT/city/.claude/skills/demo"
ln -s "$ROOT/city/decoy/demo" "$ROOT/city/.claude/skills/demo"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
note "json: $OUT"
[[ "$(json_field "$OUT" drift_count)" -ge 1 ]] && ok "drift flagged (redirected symlink)" || bad "expected drift>=1"
rm -rf "$ROOT"

# ══ 7. deploy→manifest→audit integration (real skill-deploy.sh) ═══════════════
# Proves the deploy side and audit side agree end-to-end: running the REAL
# skill-deploy.sh against a sandbox city must write a manifest that makes the
# auditor go green. gc is stubbed absent (GC=__no_gc__) so the deploy degrades
# gracefully past the session-list / reload steps without touching anything live.
scenario "deploy→audit integration (real skill-deploy.sh writes manifest)"
DEPLOY="$SELF_DIR/skill-deploy.sh"
ROOT="$(mktemp -d)"
CITYD="$ROOT/city"
mkdir -p "$CITYD/skills" "$CITYD/.claude/skills" "$CITYD/.gc/state"
# author a source skill outside the sinks, then deploy it
SRC="$ROOT/authoring/demo"
mkdir -p "$SRC/references"
printf 'deployed canonical v1\n' > "$SRC/SKILL.md"
printf 'deployed ref v1\n'       > "$SRC/references/notes.md"
DEPLOY_OUT="$(SKILL_DEPLOY_CITY="$CITYD" GC="__no_gc__" \
    SKILL_MANIFEST="$CITYD/.gc/state/skill-manifest.json" \
    "$DEPLOY" demo "$SRC" 2>&1)"
DRC=$?
note "deploy exit=$DRC"
[[ "$DRC" == "0" ]] && ok "skill-deploy.sh succeeded (gc absent, graceful)" || { bad "skill-deploy.sh failed: $DEPLOY_OUT"; }
[[ -f "$CITYD/.gc/state/skill-manifest.json" ]] && ok "manifest written" || bad "manifest not written"
# now audit the just-deployed city — vendor sink is a real copy identical to
# canonical, manifest matches -> fully green.
OUT="$(run_audit "$CITYD" "$ROOT/wa-empty" "$CITYD/.gc/state/skill-manifest.json" \
    '{"entries":[{"name":"demo","source":"city","path":"skills/demo/SKILL.md"}]}')"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" == "0" ]] && ok "offpath_count=0 after official deploy" || bad "expected offpath=0 post-deploy"
[[ "$(json_field "$OUT" drift_count)" == "0" ]]   && ok "drift_count=0 (vendor copy matches canonical)" || bad "expected drift=0 post-deploy"
[[ "$RC" == "0" ]] && ok "audit exit 0 (green)" || bad "expected exit 0, got $RC"
rm -rf "$ROOT"

# git_fixture_with_origin <root> — build a git-backed fixture city, commit v1
# (canonical + manifest baseline), and fabricate a origin/main remote-tracking
# ref pointing at that same commit via `git update-ref` — no real remote/push
# needed, just the ref the auditor's merge-base check reads. Mirrors a live
# city, which always has an origin/main ref reflecting the last landed state.
git_fixture_with_origin() {
    local root="$1"
    make_fixture "$root"
    write_manifest "$root/city"
    git -C "$root/city" init -q -b main
    git -C "$root/city" config user.email "selftest@example.com"
    git -C "$root/city" config user.name "selftest"
    git -C "$root/city" add -A
    git -C "$root/city" commit -q -m "v1: initial canonical + manifest baseline"
    git -C "$root/city" update-ref refs/remotes/origin/main "$(git -C "$root/city" rev-parse HEAD)"
}

# ══ 8. gate-merged change (pushed to origin/main, manifest stale) — accepted ═══
# Reproduces ga-aes6z: a skill fix lands via a git commit that actually landed
# on origin/main (simulating a gate-merged, pushed PR) touching the canonical
# dir WITHOUT ever running skill-deploy.sh. The manifest digest goes stale,
# but the change is on origin/main — that is a second legitimate publish path
# the auditor must also recognize, or every gate-merged skill fix becomes a
# permanent false OFFPATH (manifest=<v1 digest> live=<v2 digest> forever,
# since nothing ever re-runs skill-deploy.sh for a code-review-only change).
scenario "gate-merged change (on origin/main, manifest stale) -> accepted, not offpath"
ROOT="$(mktemp -d)"
git_fixture_with_origin "$ROOT"
# simulate a gate-merged, PUSHED fix: edit canonical, commit, and advance
# origin/main to that same commit — deliberately do NOT touch the manifest
# (nothing re-runs skill-deploy.sh here).
printf 'gate-merged fix content\n' >> "$ROOT/city/skills/demo/SKILL.md"
git -C "$ROOT/city" add -A
git -C "$ROOT/city" commit -q -m "fix(ga-demo): gate-merged change to demo skill"
git -C "$ROOT/city" update-ref refs/remotes/origin/main "$(git -C "$ROOT/city" rev-parse HEAD)"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
RC=$?
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" == "0" ]] && ok "offpath_count=0 (change merged to origin/main accepted as official path)" || bad "expected offpath_count=0, canonical is merged to origin/main"
[[ "$(json_field "$OUT" drift_count)" == "0" ]]  && ok "drift_count=0 (consumers still symlinked)" || bad "expected drift_count=0"
[[ "$RC" == "0" ]] && ok "exit 0" || bad "expected exit 0, got $RC"
rm -rf "$ROOT"

# ══ 9. uncommitted edit inside a git-backed city — still flagged ═══════════════
# Guards against scenario 8's exemption becoming a loophole: a canonical change
# that is NOT committed (a genuine direct SKILL.md write) must still be flagged
# off-path even when the city happens to be a git repo with an origin/main ref.
# Being inside a git repo is not itself a pass — only being CLEAN AND MERGED is.
scenario "uncommitted edit in a git-backed city -> still offpath"
ROOT="$(mktemp -d)"
git_fixture_with_origin "$ROOT"
# direct off-path edit, left UNCOMMITTED — this is the real bug the auditor exists to catch
printf 'sneaky uncommitted off-path edit\n' >> "$ROOT/city/skills/demo/SKILL.md"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" -ge 1 ]] && ok "offpath flagged (uncommitted edit, not git-clean)" || bad "expected offpath>=1 — the fix must not swallow real off-path edits"
rm -rf "$ROOT"

# ══ 10. committed locally but NEVER merged to origin/main — still flagged ═════
# The exact bypass a gate reviewer found in an earlier version of this fix
# (ga-aes6z, gate run ga-4rl78): a direct, unreviewed edit to a canonical
# skill dir followed by a plain LOCAL `git commit` — no push, no PR, no gate
# review at all — used to read as "clean at HEAD" and silently pass. Being
# committed is necessary but not sufficient; it must also have actually
# landed on origin/main (pushed + merged), or it never went through review.
scenario "committed locally but not on origin/main -> still offpath"
ROOT="$(mktemp -d)"
git_fixture_with_origin "$ROOT"
# direct off-path edit, committed LOCALLY ONLY — origin/main never advances
printf 'sneaky edit, committed locally, never pushed\n' >> "$ROOT/city/skills/demo/SKILL.md"
git -C "$ROOT/city" add -A
git -C "$ROOT/city" commit -q -m "looks legit but never left my laptop"
OUT="$(run_audit "$ROOT/city" "$ROOT/wa" "$ROOT/city/.gc/state/skill-manifest.json" "$SKILLS_JSON")"
note "json: $OUT"
[[ "$(json_field "$OUT" offpath_count)" -ge 1 ]] && ok "offpath flagged (committed but never merged to origin/main)" || bad "expected offpath>=1 -- a local-only commit must not be accepted as reviewed (ga-4rl78)"
rm -rf "$ROOT"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════"
echo "  skill-audit self-test: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════════"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
