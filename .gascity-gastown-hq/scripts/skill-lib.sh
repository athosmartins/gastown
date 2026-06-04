#!/usr/bin/env bash
# skill-lib.sh — shared digest helpers for the skill-publish integrity tools
# (skill-deploy.sh writes the manifest; skill-audit.sh verifies against it).
#
# Both the deploy side and the audit side MUST compute a skill's content digest
# identically, or the off-path check would produce false positives. Keeping the
# one canonical implementation here is the only way to guarantee that — source
# this file rather than re-implementing tree_digest.
#
# Usage:  source "$(dirname "$0")/skill-lib.sh"

# sha256 of one file (portable: shasum on macOS, sha256sum on Linux).
skilllib_sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    else
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    fi
}

# sha256 of stdin.
skilllib_sha256_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    else
        sha256sum 2>/dev/null | awk '{print $1}'
    fi
}

# skilllib_tree_digest <dir> — deterministic digest of a directory's CONTENT:
# every regular file's relative path + its sha256, LC_ALL=C-sorted, then hashed.
# Two directories with identical file trees and identical bytes yield the same
# digest; any added/removed/changed file changes it. Prints "MISSING" if absent.
skilllib_tree_digest() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "MISSING"; return; }
    {
        cd "$dir" || { echo "MISSING"; return; }
        find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r rel; do
            printf '%s  %s\n' "$rel" "$(skilllib_sha256_file "$rel")"
        done
    } | skilllib_sha256_stdin
}
