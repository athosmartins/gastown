# framework-marker-labels.sh — single source of truth for "this bead is a
# FRAMEWORK/IDENTITY marker, never real dispatchable work" (ga-vmn7kv).
#
# Consumed by BOTH context-check-dispatcher.sh (CONTEXT_CHECK_EXCLUDE_LABELS)
# and pilot-dispatcher.sh (_FILTER_FRAMEWORK_MARKER_LABELS, _filter_candidates'
# single chokepoint). Before this file existed, context-check knew the full
# list (7 markers) and Pilot knew NONE of it — two consumers of the same
# concept with divergent vocabularies, so a rig/agent identity bead
# (gt:rig/gt:agent) got dispatched to a worker as buildable work
# (ps-v3o refused correctly via pool:refused:rig-identity-not-buildable;
# wa-rig-whatsapp_automation slipped through undetected until this bead).
#
# Add a new marker HERE and both consumers exclude it immediately — do not
# hand-copy it into context-check-dispatcher.sh or pilot-dispatcher.sh
# separately. That second hand-copied list is exactly the drift class this
# file exists to close (same lesson ga-3lsy1 already taught pilot-dispatcher.sh
# twice for its OWN two internal call sites — see the ga-nimyz comment near
# _filter_candidates' reason-trace mirror).
#
# Space-separated, matching context-check-dispatcher.sh's native format
# (its own $CONTEXT_CHECK_EXCLUDE_LABELS default, pre-this-fix). Consumers
# needing a JSON array (pilot-dispatcher.sh, for jq --argjson) convert at
# their own call site — see _FILTER_FRAMEWORK_MARKER_LABELS.
GC_FRAMEWORK_MARKER_LABELS="gt:agent gt:rig gt:convoy gc:nudge digest pinned gt:message"
