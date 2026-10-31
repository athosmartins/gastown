#!/usr/bin/env bash
# prod-tests/gascity/story-ga-d0hm85.4.sh -- prod test for ga-d0hm85.4 (slice 4/4, the one that completes the story). Runs the
# whole-story prod test (story-ga-d0hm85.sh: files deployed, selftests, the tier OFF-or-cited-authorization invariant, the real hook
# with the tier pinned OFF, the manifest check, the report with its Jev section) and exits with its exit code.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/story-ga-d0hm85.sh"
