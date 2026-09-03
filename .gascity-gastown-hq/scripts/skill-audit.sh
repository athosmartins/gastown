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
#      Was the canonical skill changed WITHOUT going through an official path?
#      skill-deploy.sh records a manifest (sha256 per canonical file) on every
#      official deploy — that is the FIRST official path. The SECOND is a
#      gate-merged PR touching skills/<name>/: skill-deploy.sh is never re-run
#      for those, so the manifest goes stale immediately, but the change did
#      land on origin/main through review. A live canonical whose hashes
#      differ from the manifest (or that has no manifest entry at all,
#      "unmanaged") is flagged UNLESS its HEAD is both clean (no uncommitted
#      changes) AND already an ancestor of origin/main (see
#      canon_merged_to_origin_main below) — i.e. actually pushed and merged,
#      not merely committed somewhere local. A canonical with uncommitted
#      local changes, or with commits that never made it to origin/main, is
#      flagged as truly off-path (ga-aes6z; the origin/main requirement was
#      added after gate review ga-4rl78 demonstrated a local-commit-only
#      bypass in an earlier version of this check).
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

# canon_merged_to_origin_main <dir> — true iff <dir> sits inside a git working
# tree, has zero uncommitted/staged/untracked changes relative to HEAD, AND
# HEAD is already an ancestor of (or equal to) origin/main. skill-deploy.sh's
# manifest is the ORIGINAL official-publish record, but it is not the only
# legitimate one: a skill fix that lands via a gate-merged PR touching
# skills/<name>/ never runs skill-deploy.sh — there is no reason to, the gate
# already merges code — so the manifest goes stale immediately and every such
# change would otherwise be flagged as off-path forever (ga-aes6z).
#
# Being "clean at local HEAD" alone is NOT enough to accept as an alternate
# official path — a gate reviewer (run ga-4rl78) demonstrated the exact
# bypass an earlier version of this check missed: a direct, unreviewed edit
# to a canonical skill dir, followed by a plain LOCAL `git commit` (no push,
# no PR, no gate review at all), reads as "clean at HEAD" even though it
# never went through any review. Requiring HEAD to be an ancestor of
# origin/main closes that: an unpushed commit can never be an ancestor of a
# remote-tracking ref, so it still falls through to the manifest-only
# off-path flag below, exactly like any other unreviewed edit.
#
# Deliberately does NOT `git fetch` first — this auditor is documented and
# used as a fast, network-free, read-only check (skill-audit-emit.sh runs it
# on a schedule); it trusts whatever origin/main ref is already present
# locally. A stale local origin/main can only make this check MORE
# conservative (a just-landed legitimate change might still show a transient
# false OFFPATH until the ref catches up via the separate deploy-pull cron),
# never less — the same "flag when unsure" default the rest of this script
# already uses, not a new gap.
canon_merged_to_origin_main() {
    local dir="$1"
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local toplevel
    toplevel="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || return 1
    # Capture output and exit status separately: `git status` failing (corrupt
    # index, permission error, ...) must NOT be treated as "clean" just because
    # a failed call also prints nothing — that would silently exempt a real
    # off-path edit whenever the git check itself is broken. A failed status
    # call returns false here (falls through to the manifest-only flag below),
    # the same conservative default as "not a git repo at all".
    local status_out
    status_out="$(git -C "$toplevel" status --porcelain -- "$dir" 2>/dev/null)" || return 1
    [[ -z "$status_out" ]] || return 1
    # `git status --porcelain` is gitignore-aware: it never reports a file
    # that matches a .gitignore pattern, even when that file is uncommitted
    # and sitting directly in $dir. skilllib_tree_digest (what canon_digest
    # is built from) has no such awareness — it hashes every regular file
    # under $dir via a raw `find`, ignored or not. Those two facts combine
    # into a real bypass (ga-aes6z gate review): drop an uncommitted,
    # gitignored file straight into the canonical dir and `git status` still
    # reports clean while the live digest silently diverges from the
    # manifest baseline. `git clean -ndx -d` closes the gap — unlike status,
    # it reports ALL untracked content including ignored files/dirs, so any
    # such addition fails this check and falls through to the manifest-only
    # off-path flag below, same as any other unreviewed edit. Same
    # fail-closed contract as the status call above: a failed clean call
    # returns false rather than being mistaken for "nothing to report".
    local clean_out
    clean_out="$(git -C "$toplevel" clean -ndx -d -- "$dir" 2>/dev/null)" || return 1
    [[ -z "$clean_out" ]] || return 1
    # HEAD must already be part of origin/main's history — actually pushed and
    # merged, not just committed to a local/unpushed branch. Any failure here
    # (no origin/main ref at all, detached weirdness, HEAD not an ancestor)
    # returns false and falls through to the existing off-path flag.
    git -C "$toplevel" merge-base --is-ancestor HEAD origin/main 2>/dev/null
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
# manifest_digest <skill> — prints the recorded tree digest for a skill.
# Prints "" when the manifest (or this skill's entry in it) genuinely doesn't
# exist — "never went through skill-deploy.sh", which the git-merged
# exemption in audit_skill is allowed to override. Prints the literal string
# "ERROR" when the manifest FILE exists but couldn't be read/parsed (corrupt
# JSON, I/O error, permission denied, ...): that case must never collapse
# into the same "" bucket, because a corrupted manifest tells us nothing
# about this skill's real deploy history and can't be used as grounds to
# skip the off-path flag no matter what git says (ga-aes6z gate review — a
# broken manifest file used to make off-path detection go silently green).
manifest_digest() {
    [[ -f "$MANIFEST" ]] || { echo ""; return; }
    MANIFEST="$MANIFEST" python3 - "$1" <<'PY'
import json, os, sys
skill = sys.argv[1]
try:
    with open(os.environ["MANIFEST"]) as f:
        m = json.load(f)
except Exception:
    print("ERROR")
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
    if [[ "$mdigest" == "ERROR" ]]; then
        # Ambiguous by construction (see manifest_digest) — never let the
        # git-merged exemption paper over a manifest we can't even read.
        add_offpath "$name" "manifest at $MANIFEST is unreadable/corrupted — cannot verify off-path status"
    elif [[ -z "$mdigest" ]]; then
        if canon_merged_to_origin_main "$canon"; then
            info "  (no manifest entry, but canonical is merged to origin/main — accepted as official path)"
        else
            add_offpath "$name" "no manifest entry — skill never published through skill-deploy.sh (unmanaged)"
        fi
    elif [[ "$mdigest" != "$canon_digest" ]]; then
        if canon_merged_to_origin_main "$canon"; then
            info "  (canonical differs from manifest, but is merged to origin/main — accepted as gate-merged official path)"
        else
            add_offpath "$name" "canonical changed since last official deploy (manifest=$mdigest live=$canon_digest)"
        fi
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
