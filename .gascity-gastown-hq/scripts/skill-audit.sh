#!/usr/bin/env bash
# skill-audit.sh — Verify skill-publish integrity for a Gas City (story ga-5lx).
#
# Answers two questions the "single publish path" story (ga-5lx) requires:
#
#   1. DRIFT (criterion #1, guiding star "drift = 0"):
#      Does every consumer copy of a city skill match the canonical version?
#      - Consumer copies are normally symlinks into the canonical source sink
#        ($CITY/skills/<name>). A symlink that dangles or points anywhere other
#        than canonical is drift. A *real* copy (not a symlink) is hash-compared
#        file-by-file against canonical; any mismatch / missing / extra file is
#        drift.
#
#   2. OFF-PATH (criterion #3, "publishing outside the official path is flagged"):
#      Was the canonical skill changed WITHOUT going through skill-deploy.sh?
#      skill-deploy.sh records a manifest (sha256 per canonical file) on every
#      official deploy. If the live canonical hashes differ from the manifest,
#      the canonical was edited off-path (a direct SKILL.md write) — flag it.
#      A skill with no manifest entry at all is "unmanaged" (never published
#      through the official path) and is also flagged.
#
# This is a READ-ONLY auditor. It never writes to any skill sink, city.toml,
# pack.toml, or runs gc reload — so it is drain-safe and cannot interrupt crew.
#
# Output:
#   - Human-readable summary on stderr.
#   - Machine JSON on stdout (always, even on failure):
#       {"ok":bool,"drift_count":N,"offpath_count":N,"skills_checked":N,
#        "divergences":[{"skill","sink","reason"}],
#        "offpath":[{"skill","reason"}],"checked_at":"<iso8601>"}
#   - Exit 0 iff drift_count == 0 AND offpath_count == 0; else exit 1.
#     (Exit 2 = internal/usage error.)
#
# Usage:
#   skill-audit.sh [--json-only] [--quiet]
#
# Env overrides (used by the self-test to point at a throwaway fixture tree;
# default to the live city so production callers need no configuration):
#   SKILL_AUDIT_CITY   city root           (default: $CITY autodetected from script)
#   SKILL_AUDIT_WA     whatsapp rig root   (default: <gt>/whatsapp_automation)
#   SKILL_AUDIT_MANIFEST  manifest path    (default: $CITY/.gc/state/skill-manifest.json)
#   SKILL_AUDIT_SKILLS_JSON  path to a file containing `gc skill list --json` output,
#                            OR the literal string to bypass calling gc (test hook).
#   GC                 gc binary           (default: gc)

set -uo pipefail

# ── Shared digest helpers ─────────────────────────────────────────────────────
# skilllib_tree_digest / skilllib_sha256_file — single canonical implementation
# shared with skill-deploy.sh so the audit and the manifest can never disagree.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=skill-lib.sh
source "$_SELF_DIR/skill-lib.sh"

# ── Roots ─────────────────────────────────────────────────────────────────────
CITY="${SKILL_AUDIT_CITY:-$(cd "$_SELF_DIR/.." && pwd)}"
# <gt> is the parent of the city dir; whatsapp_automation is a sibling of the city.
GT_ROOT="$(cd "$CITY/.." && pwd)"
WA="${SKILL_AUDIT_WA:-$GT_ROOT/whatsapp_automation}"
MANIFEST="${SKILL_AUDIT_MANIFEST:-$CITY/.gc/state/skill-manifest.json}"
GC="${GC:-gc}"

JSON_ONLY=false
QUIET=false
for arg in "$@"; do
    case "$arg" in
        --json-only) JSON_ONLY=true ;;
        --quiet)     QUIET=true ;;
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo >&2 "skill-audit: unknown arg: $arg"; exit 2 ;;
    esac
done

info() { $QUIET && return 0; echo >&2 "$@"; }

# ── Path helpers ──────────────────────────────────────────────────────────────
# (content digests come from skill-lib.sh: skilllib_tree_digest)

# realpath_of <path> — resolve symlinks to an absolute physical path.
realpath_of() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null
    else
        # macOS fallback
        python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null
    fi
}

# ── JSON emit helpers (no jq dependency) ──────────────────────────────────────
_json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

DIVERGENCES_JSON=""   # comma-joined object list
OFFPATH_JSON=""
DRIFT_COUNT=0
OFFPATH_COUNT=0
SKILLS_CHECKED=0

add_divergence() { # skill sink reason
    local obj
    obj="{\"skill\":$(_json_escape "$1"),\"sink\":$(_json_escape "$2"),\"reason\":$(_json_escape "$3")}"
    if [[ -z "$DIVERGENCES_JSON" ]]; then DIVERGENCES_JSON="$obj"; else DIVERGENCES_JSON="$DIVERGENCES_JSON,$obj"; fi
    DRIFT_COUNT=$((DRIFT_COUNT+1))
    info "  DRIFT  [$1] $2 — $3"
}

add_offpath() { # skill reason
    local obj
    obj="{\"skill\":$(_json_escape "$1"),\"reason\":$(_json_escape "$2")}"
    if [[ -z "$OFFPATH_JSON" ]]; then OFFPATH_JSON="$obj"; else OFFPATH_JSON="$OFFPATH_JSON,$obj"; fi
    OFFPATH_COUNT=$((OFFPATH_COUNT+1))
    info "  OFFPATH[$1] — $2"
}

# ── Enumerate city skills ─────────────────────────────────────────────────────
# Uses `gc skill list --json` as the authoritative source of what the city
# publishes. We audit only source:"city" skills (pack/core skills are managed by
# the pack mechanism, out of scope for ga-5lx). Returns lines: "<name>\t<canonical-dir>".
list_city_skills() {
    local raw
    if [[ -n "${SKILL_AUDIT_SKILLS_JSON:-}" ]]; then
        if [[ -f "$SKILL_AUDIT_SKILLS_JSON" ]]; then
            raw="$(cat "$SKILL_AUDIT_SKILLS_JSON")"
        else
            raw="$SKILL_AUDIT_SKILLS_JSON"
        fi
    else
        raw="$("$GC" skill list --json --city "$CITY" 2>/dev/null)"
    fi
    [[ -z "$raw" ]] && return 0
    CITY="$CITY" python3 - "$raw" <<'PY'
import json, os, sys
raw = sys.argv[1]
city = os.environ["CITY"]
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
for e in data.get("entries", []):
    if e.get("source") != "city":
        continue
    name = e.get("name", "")
    path = e.get("path", "")  # e.g. "skills/refino/SKILL.md" (relative to city)
    if not name or not path:
        continue
    # canonical dir = directory containing SKILL.md, resolved under city root
    d = os.path.dirname(path)
    if not os.path.isabs(d):
        d = os.path.join(city, d)
    print(f"{name}\t{d}")
PY
}

# ── Manifest lookup (off-path baseline) ───────────────────────────────────────
# manifest_digest <skill> — prints the recorded tree digest for a skill, or empty.
manifest_digest() {
    [[ -f "$MANIFEST" ]] || { echo ""; return; }
    MANIFEST="$MANIFEST" python3 - "$1" <<'PY'
import json, os, sys
skill = sys.argv[1]
try:
    with open(os.environ["MANIFEST"]) as f:
        m = json.load(f)
except Exception:
    print("")
    sys.exit(0)
entry = (m.get("skills") or {}).get(skill) or {}
print(entry.get("tree_digest", ""))
PY
}

# ── Consumer-sink enumeration ─────────────────────────────────────────────────
# Emit every place a consumer copy of <skill> could live (one path per line).
# These are the dirs AGENTS actually load skills from. city-local is authoring
# staging (agents consume via the HQ symlink, not city-local), so it is reported
# separately as informational, not as drift.
consumer_sinks() {
    local name="$1"
    # HQ vendor sink
    echo "$CITY/.claude/skills/$name"
    # Every agent provider dir under the city
    find "$CITY/.gc/agents" -type d -path "*/.claude/skills" 2>/dev/null | while IFS= read -r d; do
        echo "$d/$name"
    done
    # WA crew member provider dirs
    find "$WA/crew" -type d -path "*/.claude/skills" 2>/dev/null | while IFS= read -r d; do
        echo "$d/$name"
    done
}

# ── Audit one skill ───────────────────────────────────────────────────────────
audit_skill() {
    local name="$1" canon="$2"
    SKILLS_CHECKED=$((SKILLS_CHECKED+1))
    info "skill: $name  (canonical: $canon)"

    if [[ ! -d "$canon" ]]; then
        add_offpath "$name" "canonical dir missing: $canon"
        return
    fi

    local canon_digest
    canon_digest="$(skilllib_tree_digest "$canon")"

    # --- off-path check vs manifest ---
    local mdigest
    mdigest="$(manifest_digest "$name")"
    if [[ -z "$mdigest" ]]; then
        add_offpath "$name" "no manifest entry — skill never published through skill-deploy.sh (unmanaged)"
    elif [[ "$mdigest" != "$canon_digest" ]]; then
        add_offpath "$name" "canonical changed since last official deploy (manifest=$mdigest live=$canon_digest)"
    fi

    # --- drift check across consumer sinks ---
    local sink
    while IFS= read -r sink; do
        [[ -z "$sink" ]] && continue
        # Does the consumer have this skill at all?
        if [[ -L "$sink" ]]; then
            # symlink — must resolve to canonical
            local target
            target="$(realpath_of "$sink")"
            if [[ -z "$target" || ! -e "$sink" ]]; then
                add_divergence "$name" "$sink" "dangling symlink -> $(readlink "$sink" 2>/dev/null)"
            elif [[ "$target" != "$(realpath_of "$canon")" ]]; then
                add_divergence "$name" "$sink" "symlink resolves to $target, not canonical $(realpath_of "$canon")"
            fi
            # symlink to canonical => identical by construction; no hash needed.
        elif [[ -e "$sink" ]]; then
            # real copy — hash-compare against canonical
            local sdigest
            sdigest="$(skilllib_tree_digest "$sink")"
            if [[ "$sdigest" != "$canon_digest" ]]; then
                add_divergence "$name" "$sink" "real copy content differs from canonical (copy=$sdigest canon=$canon_digest)"
            fi
        fi
        # If sink doesn't exist, the agent simply doesn't have the skill
        # materialized — that is absence, not stale drift, so not flagged.
    done < <(consumer_sinks "$name")
}

# ── Main ──────────────────────────────────────────────────────────────────────
info "=== skill-audit (city: $CITY) ==="
info "manifest: $MANIFEST"

skills="$(list_city_skills)"
if [[ -n "$skills" ]]; then
    while IFS=$'\t' read -r name canon; do
        [[ -z "$name" ]] && continue
        audit_skill "$name" "$canon"
    done <<< "$skills"
fi

CHECKED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ok=true
if (( DRIFT_COUNT > 0 || OFFPATH_COUNT > 0 )); then ok=false; fi

printf '{"ok":%s,"drift_count":%d,"offpath_count":%d,"skills_checked":%d,"divergences":[%s],"offpath":[%s],"checked_at":"%s"}\n' \
    "$ok" "$DRIFT_COUNT" "$OFFPATH_COUNT" "$SKILLS_CHECKED" "$DIVERGENCES_JSON" "$OFFPATH_JSON" "$CHECKED_AT"

if $JSON_ONLY; then :; else
    info ""
    info "=== summary: skills_checked=$SKILLS_CHECKED drift_count=$DRIFT_COUNT offpath_count=$OFFPATH_COUNT (ok=$ok) ==="
fi

$ok && exit 0 || exit 1
