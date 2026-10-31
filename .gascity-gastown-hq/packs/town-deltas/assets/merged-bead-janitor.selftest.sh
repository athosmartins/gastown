#!/usr/bin/env bash
# merged-bead-janitor.selftest.sh — prove the ga-tijv5 janitor in isolation,
# with NO live Dolt/gc/launchd and NO network.
#
# Sources the janitor in lib-only mode for the REAL functions (one source of
# truth, no copy-drift), unit-tests the pure decision across every branch and
# every guard, runs a real-git integration test for the merge-evidence helpers
# (commit-msg scan with token boundaries + branch ancestry), exercises the
# marker JSON helpers against synthetic fixtures, then DRIFT-GUARDS the live
# wiring. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR="$SELF_DIR/merged-bead-janitor.sh"
PLIST="$SELF_DIR/merged-bead-janitor.plist"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { if "$@" >/dev/null 2>&1; then ok "rc0: $*"; else bad "expected rc0: $*"; fi; }
rc1() { if "$@" >/dev/null 2>&1; then bad "expected non-zero: $*"; else ok "rc!=0: $*"; fi; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
JANITOR_LIB_ONLY=1 source "$JANITOR" \
  || { echo "FATAL: could not source janitor in lib-only mode"; exit 1; }
for fn in janitor_decide janitor_story_decide token_bounded scan_commit_for_bead \
          scan_commit_subject_for_bead subject_impl_scopes_bead branch_merged content_in_main \
          crew_branches_for_bead unmerged_crew_branches_for_bead \
          has_open_marker has_terminal_passed_marker has_terminal_superseded_marker \
          branch_label_from_markers rig_gitdir \
          janitor_branch_decide normalize_bead_status branch_is_fresh \
          bead_lookup_one resolve_bead_state \
          commit_epoch commit_evidence_stale comments_for_bead commit_touches_only_pending_patch \
          terminal_passed_marker_epoch marker_evidence_stale \
          sling_beads_from_show sling_signals_for_id sling_fallback_eligible_reason \
          iso_epoch story_gate_passed_grace_state; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by janitor"; exit 1; }
done

# ── 1. janitor_decide — pure decision, every branch + guard precedence ──────
# Args: <is_epic> <has_open_marker> <sig_commit> <sig_marker> <sig_branch>
echo "── 1. janitor_decide (pure verdict) ──"
eq "no signals → keep"                  "$(janitor_decide 0 0 0 0 0)" "keep:no-merge-evidence"
eq "commit signal → close"              "$(janitor_decide 0 0 1 0 0 | cut -d: -f1)" "close"
eq "marker signal → close"              "$(janitor_decide 0 0 0 1 0 | cut -d: -f1)" "close"
eq "branch signal → close"              "$(janitor_decide 0 0 0 0 1 | cut -d: -f1)" "close"
eq "commit reason"                      "$(janitor_decide 0 0 1 0 0)" "close:commit-in-origin-main"
eq "marker reason"                      "$(janitor_decide 0 0 0 1 0)" "close:terminal-gate-marker-passed"
eq "branch reason"                      "$(janitor_decide 0 0 0 0 1)" "close:branch-ancestor-of-origin-main"
# Guard precedence: epic ALWAYS keep, even with every signal set.
eq "epic beats all signals → keep"      "$(janitor_decide 1 0 1 1 1 | cut -d: -f1)" "keep"
eq "epic reason"                        "$(janitor_decide 1 0 0 0 0)" "keep:epic-parent-never-autoclosed"
# Open marker beats signals (protects wa-lstd: queued + branch present).
eq "open-marker beats commit → keep"    "$(janitor_decide 0 1 1 0 0 | cut -d: -f1)" "keep"
eq "open-marker beats branch → keep"    "$(janitor_decide 0 1 0 0 1 | cut -d: -f1)" "keep"
eq "open-marker reason"                 "$(janitor_decide 0 1 0 0 0)" "keep:active-open-gate-marker"
# Epic precedence over open-marker (both 'keep' but epic wins the label).
eq "epic+open → epic reason"            "$(janitor_decide 1 1 0 0 0)" "keep:epic-parent-never-autoclosed"

# ── 1a2. janitor_decide sig_commit_stale — joint/split-bead false-close guard (ga-2zp4h) ──
# wa-d3136 shape: mila's half was delivered+gated under her OWN sibling bead (wa-eda28),
# but her commit's subject still scoped the shared PARENT id (`chore(wa-d3136): …`) — a
# legitimate Signal-A match, yet the bead was reassigned to a second owner the day AFTER
# that commit landed, and his half was never built. sig_commit_stale=1 means a bead
# comment postdates the matched commit — it suppresses signal A ALONE; signals B/C are
# bead-specific and authoritative, so they still close normally even when stale=1.
echo "── 1a2. janitor_decide sig_commit_stale (joint/split-bead guard, ga-2zp4h) ──"
eq "backward-compat: 5 args, no 6th → commit still closes" \
   "$(janitor_decide 0 0 1 0 0)" "close:commit-in-origin-main"
eq "6th arg omitted defaults to 0 (not stale) → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 | cut -d: -f1)" "close"
eq "stale commit alone → KEEP (the wa-d3136 false-close this fix prevents)" \
   "$(janitor_decide 0 0 1 0 0 1)" "keep:commit-evidence-superseded-by-newer-comment"
eq "stale commit + marker also fires → marker still closes (signal B unaffected)" \
   "$(janitor_decide 0 0 1 1 0 1)" "close:terminal-gate-marker-passed"
eq "stale commit + branch also fires → branch still closes (signal C unaffected)" \
   "$(janitor_decide 0 0 1 0 1 1)" "close:branch-ancestor-of-origin-main"
eq "stale=1 but no commit signal at all → falls through to no-merge-evidence" \
   "$(janitor_decide 0 0 0 0 0 1)" "keep:no-merge-evidence"
eq "stale=0 explicit (not just omitted) → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 0)" "close:commit-in-origin-main"
# Guard precedence unchanged: epic/open-marker still beat a stale-flagged commit too.
eq "epic beats stale commit → keep (epic reason, not stale reason)" \
   "$(janitor_decide 1 0 1 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats stale commit → keep (open-marker reason)" \
   "$(janitor_decide 0 1 1 0 0 1)" "keep:active-open-gate-marker"

# ── 1a3. janitor_decide sig_marker_superseded — superseded ≠ merged (ga-v8ui5) ──
# gate-status:superseded means the branch was REPLACED (rebase/recreate — the
# documented procedure when the gate rejects a stale base) — the OPPOSITE of
# passed. It must NEVER assert delivery by itself; only real merge evidence
# (signal A commit-in-main, or signal C branch-ancestor — e.g. a REPLACEMENT
# branch that genuinely merged) may close a bead with a superseded marker.
echo "── 1a3. janitor_decide sig_marker_superseded (superseded ≠ merged, ga-v8ui5) ──"
eq "backward-compat: 6 args, no 7th → unaffected (defaults to 0)" \
   "$(janitor_decide 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "superseded alone → KEEP with a distinguishable reason (the wa-c3qsr false-close this fix prevents)" \
   "$(janitor_decide 0 0 0 0 0 0 1)" "keep:superseded-marker-needs-merge-evidence"
eq "superseded + commit signal → commit still closes (replacement branch merged, verified by content)" \
   "$(janitor_decide 0 0 1 0 0 0 1)" "close:commit-in-origin-main"
eq "superseded + branch signal → branch still closes (replacement branch is an origin/main ancestor)" \
   "$(janitor_decide 0 0 0 0 1 0 1)" "close:branch-ancestor-of-origin-main"
eq "superseded + passed marker also present → passed still wins (signal B, distinct marker)" \
   "$(janitor_decide 0 0 0 1 0 0 1)" "close:terminal-gate-marker-passed"
# Guard precedence unchanged: epic/open-marker still beat a superseded-only marker too.
eq "epic beats superseded-only → keep (epic reason, not superseded reason)" \
   "$(janitor_decide 1 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats superseded-only → keep (open-marker reason)" \
   "$(janitor_decide 0 1 0 0 0 0 1)" "keep:active-open-gate-marker"

# ── 1a4. janitor_decide is_delivery_partial — partial scope ≠ delivered (ga-f54ui) ──
# ga-k2wjn's own heuristic (gate_delivery_looks_partial, quality-gate-dispatcher.sh)
# already proved this bead's body enumerates MULTIPLE approved deliverables of which
# only one diff was gated — that is why the delivery:partial label exists at all. A
# merge signal here proves the SAME single diff merged; it says nothing about the rest
# of the bead's scope. Live incident: ga-f54ui carried delivery:partial (root-cause
# investigation still open) yet Signal B (a terminal gate-status:passed marker for its
# FIRST deliverable only) closed it the moment it was re-claimed in_progress. Applies
# uniformly to all three signals — same precedence class as is_epic/has_open_marker.
echo "── 1a4. janitor_decide is_delivery_partial (partial scope ≠ delivered, ga-f54ui) ──"
eq "backward-compat: 7 args, no 8th → unaffected (defaults to 0)" \
   "$(janitor_decide 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "backward-compat: 7 args + marker signal, no 8th → still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0)" "close:terminal-gate-marker-passed"
eq "partial + marker signal → KEEP (the ga-f54ui false-close this fix prevents)" \
   "$(janitor_decide 0 0 0 1 0 0 0 1)" "keep:delivery-partial-unresolved-scope"
eq "partial + commit signal → KEEP (one diff merging proves nothing about the rest)" \
   "$(janitor_decide 0 0 1 0 0 0 0 1)" "keep:delivery-partial-unresolved-scope"
eq "partial + branch signal → KEEP (branch-ancestor is the same single-diff evidence)" \
   "$(janitor_decide 0 0 0 0 1 0 0 1)" "keep:delivery-partial-unresolved-scope"
eq "partial + every signal at once → KEEP (guard beats all three uniformly)" \
   "$(janitor_decide 0 0 1 1 1 0 0 1 | cut -d: -f1)" "keep"
# Guard precedence unchanged: epic/open-marker still beat a partial-delivery bead too
# (their own reason wins — delivery:partial does not need to be checked at all).
eq "epic beats partial+signals → keep (epic reason, not partial reason)" \
   "$(janitor_decide 1 0 1 1 1 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats partial+signals → keep (open-marker reason)" \
   "$(janitor_decide 0 1 1 1 1 0 0 1)" "keep:active-open-gate-marker"
# Fixture CONTROLE (mirrors ga-k2wjn's own control fixture): NOT partial (0) → every
# signal closes exactly as before. The fix must not turn every close into a hold.
eq "not-partial + marker signal → still closes normally" \
   "$(janitor_decide 0 0 0 1 0 0 0 0)" "close:terminal-gate-marker-passed"

# ── 1a5. janitor_decide is_daemon_hold — pending-restart ≠ delivered (ga-l7n3v) ──
# quality-gate-dispatcher.sh's BUG/TASK close path closes the GATE MARKER as
# gate-status:passed (terminal) BEFORE it decides whether to close or hold the
# SOURCE bead — so by the time a daemon-verification failure holds the source bead
# (labels it delivery:pending-restart, leaves it in_progress+unassigned), the
# has_open_marker guard above can no longer protect it: the marker isn't open
# anymore. Every real merge signal (the fix's own commits citing the bead id;
# the now-closed gate-status:passed marker) fires normally on the very next
# 15-minute sweep — reproducing the ga-f54ui shape verbatim via a different
# dispatcher-side hold label. Same fix, same precedence tier as is_delivery_partial.
echo "── 1a5. janitor_decide is_daemon_hold (pending-restart ≠ delivered, ga-l7n3v) ──"
eq "backward-compat: 8 args, no 9th → unaffected (defaults to 0)" \
   "$(janitor_decide 0 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "backward-compat: 8 args + marker signal, no 9th → still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0)" "close:terminal-gate-marker-passed"
eq "daemon-hold + marker signal → KEEP (the ga-l7n3v false-close this fix prevents)" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 1)" "keep:daemon-verification-pending-restart"
eq "daemon-hold + commit signal → KEEP (the fix's own commits merging proves nothing about daemon liveness)" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 1)" "keep:daemon-verification-pending-restart"
eq "daemon-hold + branch signal → KEEP (branch-ancestor is the same merged-code evidence)" \
   "$(janitor_decide 0 0 0 0 1 0 0 0 1)" "keep:daemon-verification-pending-restart"
eq "daemon-hold + every signal at once → KEEP (guard beats all three uniformly)" \
   "$(janitor_decide 0 0 1 1 1 0 0 0 1 | cut -d: -f1)" "keep"
# Guard precedence unchanged: epic/open-marker/delivery-partial still beat a
# daemon-hold bead too (their own reason wins — is_daemon_hold does not need
# to be checked at all).
eq "epic beats daemon-hold+signals → keep (epic reason, not daemon-hold reason)" \
   "$(janitor_decide 1 0 1 1 1 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats daemon-hold+signals → keep (open-marker reason)" \
   "$(janitor_decide 0 1 1 1 1 0 0 0 1)" "keep:active-open-gate-marker"
eq "delivery-partial beats daemon-hold+signals → keep (partial reason, checked first)" \
   "$(janitor_decide 0 0 1 1 1 0 0 1 1)" "keep:delivery-partial-unresolved-scope"
# Fixture CONTROLE (mirrors ga-f54ui's own control fixture): NOT daemon-hold (0) →
# every signal closes exactly as before. The fix must not turn every close into a hold.
eq "not-daemon-hold + marker signal → still closes normally" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0)" "close:terminal-gate-marker-passed"

# ── 1a6. janitor_decide sig_commit_docs_only — patch-staged ≠ fix-applied (ga-fbycg) ──
# The docs/pending-engine-window queue's own convention is a commit like
# "docs(<id>): pending-engine-window patch ..." that STAGES a *.patch file for a later
# engine build+swap window — it never applies the fix. Two confirmed false-closes
# (ga-soxi9, ga-9n9z7) matched Signal A on exactly this shape: the bead's ONLY trace in
# origin/main was the patch-staging commit. Same precedence tier as sig_commit_stale
# (both suppress signal A ALONE; signals B/C are bead-specific and stay authoritative).
echo "── 1a6. janitor_decide sig_commit_docs_only (patch-staged ≠ fix-applied, ga-fbycg) ──"
eq "backward-compat: 9 args, no 10th → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 0)" "close:commit-in-origin-main"
eq "backward-compat: 9 args + marker signal, no 10th → still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0)" "close:terminal-gate-marker-passed"
eq "docs-only commit alone → KEEP (the ga-soxi9/ga-9n9z7 false-close this fix prevents)" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 0 1)" "keep:commit-evidence-docs-only-patch-staged"
eq "docs-only + marker also fires → marker still closes (signal B unaffected)" \
   "$(janitor_decide 0 0 1 1 0 0 0 0 0 1)" "close:terminal-gate-marker-passed"
eq "docs-only + branch also fires → branch still closes (signal C unaffected)" \
   "$(janitor_decide 0 0 1 0 1 0 0 0 0 1)" "close:branch-ancestor-of-origin-main"
eq "docs-only=1 but no commit signal at all → falls through to no-merge-evidence" \
   "$(janitor_decide 0 0 0 0 0 0 0 0 0 1)" "keep:no-merge-evidence"
eq "docs-only=0 explicit (not just omitted) → commit still closes" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 0 0)" "close:commit-in-origin-main"
# Guard precedence: epic/open-marker/delivery-partial/daemon-hold still beat a
# docs-only-flagged commit too (their own reason wins, checked before signal A at all).
eq "epic beats docs-only commit → keep (epic reason, not docs-only reason)" \
   "$(janitor_decide 1 0 1 0 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats docs-only commit → keep (open-marker reason)" \
   "$(janitor_decide 0 1 1 0 0 0 0 0 0 1)" "keep:active-open-gate-marker"
eq "delivery-partial beats docs-only commit → keep (partial reason, checked first)" \
   "$(janitor_decide 0 0 1 0 0 0 0 1 0 1)" "keep:delivery-partial-unresolved-scope"
eq "daemon-hold beats docs-only commit → keep (daemon-hold reason, checked first)" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 1 1)" "keep:daemon-verification-pending-restart"
# Interaction with sig_commit_stale: both suppress signal A alone; docs-only is checked
# first in the fallback chain, so when a commit is BOTH stale and docs-only the reason
# is the docs-only one (cosmetic only — either way the verdict is keep).
eq "stale AND docs-only together → docs-only reason wins (both suppress the same close)" \
   "$(janitor_decide 0 0 1 0 0 1 0 0 0 1)" "keep:commit-evidence-docs-only-patch-staged"
# Fixture CONTROLE (mirrors ga-f54ui/ga-l7n3v's own control fixtures): NOT docs-only (0)
# → every signal closes exactly as before. The fix must not turn every close into a keep.
eq "not-docs-only + marker signal → still closes normally" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0)" "close:terminal-gate-marker-passed"

# ── 1a7. janitor_decide sig_marker_stale — reverted-merge stale-marker guard (ga-tysvjp) ──
# ga-nkqook shape: the Mayor reopened the bead with fresh, narrow, still-open scope; 18
# minutes later the ga-hcj4 stranded-wrapper sweep found the bead's OLD terminal-passed
# marker (whose underlying merge had since been reverted, wa-h2kp5 — nothing relabeled it
# to gate-status:superseded) and closed the bead anyway. sig_marker_stale=1 means a bead
# comment postdates the marker's own closed_at — it suppresses signal B ALONE; signals A/C
# are bead-specific and authoritative, so they still close normally even when stale=1.
echo "── 1a7. janitor_decide sig_marker_stale (reverted-merge stale-marker guard, ga-tysvjp) ──"
eq "backward-compat: 10 args, no 11th → marker still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0)" "close:terminal-gate-marker-passed"
eq "stale marker alone → KEEP (the ga-nkqook false-close this fix prevents)" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0 1)" "keep:marker-evidence-superseded-by-newer-comment"
eq "stale marker + commit also fires → commit still closes (signal A unaffected)" \
   "$(janitor_decide 0 0 1 1 0 0 0 0 0 0 1)" "close:commit-in-origin-main"
eq "stale marker + branch also fires → branch still closes (signal C unaffected)" \
   "$(janitor_decide 0 0 0 1 1 0 0 0 0 0 1)" "close:branch-ancestor-of-origin-main"
eq "stale=1 but no marker signal at all → falls through to no-merge-evidence" \
   "$(janitor_decide 0 0 0 0 0 0 0 0 0 0 1)" "keep:no-merge-evidence"
eq "stale=0 explicit (not just omitted) → marker still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0 0)" "close:terminal-gate-marker-passed"
# Guard precedence unchanged: epic/open-marker still beat a stale-flagged marker too.
eq "epic beats stale marker → keep (epic reason, not marker-stale reason)" \
   "$(janitor_decide 1 0 0 1 0 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats stale marker → keep (open-marker reason)" \
   "$(janitor_decide 0 1 0 1 0 0 0 0 0 0 1)" "keep:active-open-gate-marker"
# Interaction with ga-v8ui5's sig_marker_superseded: the stale-marker fallback reason wins
# (same precedence as sig_commit_stale's own fallback over sig_marker_superseded above) —
# these are independent booleans (a bead can carry one stale-passed marker and a SEPARATE
# superseded marker at once), and the stale-passed marker is the more specific finding.
eq "stale marker + a separate superseded marker → stale-marker reason wins" \
   "$(janitor_decide 0 0 0 1 0 0 1 0 0 0 1)" "keep:marker-evidence-superseded-by-newer-comment"

# ── 1a8. janitor_decide is_vm_hold — merged ≠ running on the dialer VM (ga-wye9vt) ──
# The dispatcher's PASS path now holds a bug/task that touches the voicebot when the dialer VM
# is not proven current: label delivery:pending-vm, bead left open. The gate marker is already
# closed as gate-status:passed by then and the merge is in origin/main, so EVERY merge signal
# (A commit, B marker, C branch) fires on the janitor's next sweep and it would close the bead —
# "done with the VM old", quietly, 15 minutes after the dispatcher refused to. Same precedence
# tier as is_delivery_partial / is_daemon_hold: the dispatcher already judged the bead is NOT done.
echo "── 1a8. janitor_decide is_vm_hold (merged ≠ running on the dialer VM, ga-wye9vt) ──"
eq "backward-compat: 11 args, no 12th → marker still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0 0)" "close:terminal-gate-marker-passed"
eq "vm-hold=0 explicit → marker still closes" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0 0 0)" "close:terminal-gate-marker-passed"
eq "vm-hold + terminal marker (the dispatcher's own closed marker) → KEEP" \
   "$(janitor_decide 0 0 0 1 0 0 0 0 0 0 0 1)" "keep:dialer-vm-pending-vm-hold"
eq "vm-hold + commit in main → KEEP" \
   "$(janitor_decide 0 0 1 0 0 0 0 0 0 0 0 1)" "keep:dialer-vm-pending-vm-hold"
eq "vm-hold + branch merged → KEEP" \
   "$(janitor_decide 0 0 0 0 1 0 0 0 0 0 0 1)" "keep:dialer-vm-pending-vm-hold"
eq "vm-hold + every signal → KEEP (a guard, not a per-signal carve-out)" \
   "$(janitor_decide 0 0 1 1 1 0 0 0 0 0 0 1 | cut -d: -f1)" "keep"
eq "vm-hold with no signal at all → still names the hold (not the generic no-merge-evidence)" \
   "$(janitor_decide 0 0 0 0 0 0 0 0 0 0 0 1)" "keep:dialer-vm-pending-vm-hold"
# Guard precedence: the guards ahead of the hold keep their own, more specific reasons.
eq "epic beats the vm hold → epic reason" \
   "$(janitor_decide 1 0 1 1 1 0 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "open-marker beats the vm hold → open-marker reason" \
   "$(janitor_decide 0 1 1 1 1 0 0 0 0 0 0 1)" "keep:active-open-gate-marker"
eq "delivery:partial + vm hold → partial reason (earlier tier wins)" \
   "$(janitor_decide 0 0 1 1 1 0 0 1 0 0 0 1)" "keep:delivery-partial-unresolved-scope"
eq "daemon hold + vm hold → daemon reason (earlier tier wins)" \
   "$(janitor_decide 0 0 1 1 1 0 0 0 1 0 0 1)" "keep:daemon-verification-pending-restart"
# The ga-vokwv sling-name fallback may only override the two "FID's own signals were empty"
# reasons. The hold reason must stay ineligible, or a sibling wrapper's evidence closes the bead.
eq "the vm-hold keep reason is NOT eligible for the sling-name fallback" \
   "$(sling_fallback_eligible_reason "dialer-vm-pending-vm-hold")" "0"

# ── 1b. janitor_story_decide — merged story:approved → story:done (ga-gosfs) ──
# Args: <is_epic> <has_open_marker> <already_done> <in_flight> <has_builder>
#       <delivery_active> <sig_commit> <sig_marker> <sig_branch>
# Echoes "done:<reason>" (transition story:approved → story:done) or "keep:<reason>".
# This is the SECOND sweep: stories sit OPEN + story:approved after a gate PASS
# (handed off to delivery). If delivery never fires (cross-store missing gate:passed,
# superseded path, rig-store delivery never scans, delivery crash) the merged story
# is stranded story:approved and the Kanban shows false backlog. With merge evidence
# AND no active rework, the janitor drives it to story:done.
echo "── 1b. janitor_story_decide (merged story → story:done) ──"
# Happy paths: a merge signal + no active rework + not already done → done.
eq "commit signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" "done:commit-in-origin-main"
eq "marker signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 0 1 0)" "done:terminal-gate-marker-passed"
eq "branch signal → done"               "$(janitor_story_decide 0 0 0 0 0 0 0 0 1)" "done:branch-ancestor-of-origin-main"
eq "any-signal verb is done"            "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 | cut -d: -f1)" "done"
# No merge evidence → keep (a genuinely-pending approved story is NOT touched: AC2).
eq "no merge evidence → keep"           "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
# Guard precedence — each guard beats every merge signal (all signals = 1):
eq "epic beats signals → keep"          "$(janitor_story_decide 1 0 0 0 0 0 1 1 1)" "keep:epic-parent-never-autoclosed"
eq "already-done idempotent → keep"     "$(janitor_story_decide 0 0 1 0 0 0 1 1 1)" "keep:already-story-done"
eq "open-marker (mid-gate) → keep"      "$(janitor_story_decide 0 1 0 0 0 0 1 1 1)" "keep:active-open-gate-marker"
eq "in-flight (active build) → keep"    "$(janitor_story_decide 0 0 0 1 0 0 1 1 1)" "keep:story-in-flight-active-rework"
eq "live builder assignee → keep"       "$(janitor_story_decide 0 0 0 0 1 0 1 1 1)" "keep:live-builder-assignee"
eq "delivery owns it → keep"            "$(janitor_story_decide 0 0 0 0 0 1 1 1 1)" "keep:delivery-owns-it"
# Guard ORDER (first match wins; ACTIVE-WORK guards precede already_done — security fix):
eq "epic > already-done"                "$(janitor_story_decide 1 0 1 0 0 0 0 0 0)" "keep:epic-parent-never-autoclosed"
# SECURITY: a bead with a STALE story:done AND an active open gate-marker must keep as
# active-open-gate-marker (NOT already-story-done) — else the orphan-close backstop false-closes it.
eq "open-marker > already-done"         "$(janitor_story_decide 0 1 1 0 0 0 0 0 0)" "keep:active-open-gate-marker"
eq "open-marker > in-flight"            "$(janitor_story_decide 0 1 0 1 0 0 0 0 0)" "keep:active-open-gate-marker"
eq "in-flight > builder"                "$(janitor_story_decide 0 0 0 1 1 0 0 0 0)" "keep:story-in-flight-active-rework"
eq "builder > delivery"                 "$(janitor_story_decide 0 0 0 0 1 1 0 0 0)" "keep:live-builder-assignee"
# Signal precedence among the three (commit > marker > branch), cosmetic only.
eq "commit beats marker+branch"         "$(janitor_story_decide 0 0 0 0 0 0 1 1 1)" "done:commit-in-origin-main"
eq "marker beats branch"                "$(janitor_story_decide 0 0 0 0 0 0 0 1 1)" "done:terminal-gate-marker-passed"

# ── 1b2. janitor_story_decide sig_commit_stale — same joint/split-bead guard (ga-2zp4h) ──
# A story can be a joint/split bead too; the suppression mirrors janitor_decide exactly.
echo "── 1b2. janitor_story_decide sig_commit_stale (joint/split-bead guard, ga-2zp4h) ──"
eq "backward-compat: 9 args, no 10th → commit still done" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" "done:commit-in-origin-main"
eq "stale commit alone → KEEP (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 1)" "keep:commit-evidence-superseded-by-newer-comment"
eq "stale commit + marker also fires → marker still drives done (signal B unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 1 0 1)" "done:terminal-gate-marker-passed"
eq "stale commit + branch also fires → branch still drives done (signal C unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 1 1)" "done:branch-ancestor-of-origin-main"
eq "in-flight guard still beats a stale-flagged commit" \
   "$(janitor_story_decide 0 0 0 1 0 0 1 0 0 1)" "keep:story-in-flight-active-rework"

# ── 1b3. janitor_story_decide sig_marker_superseded — superseded ≠ merged (ga-v8ui5) ──
# Same parity as janitor_decide §1a3: a superseded marker alone must never drive
# a story to story:done — only real merge evidence (commit or branch-ancestor,
# e.g. a genuinely-merged REPLACEMENT branch) may.
echo "── 1b3. janitor_story_decide sig_marker_superseded (superseded ≠ merged, ga-v8ui5) ──"
eq "backward-compat: 9 args, no 10th/11th → unaffected" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" "keep:no-merge-evidence"
eq "superseded alone → KEEP with a distinguishable reason (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0 0 1)" "keep:superseded-marker-needs-merge-evidence"
eq "superseded + commit signal → commit still drives done (replacement branch merged)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 0 1)" "done:commit-in-origin-main"
eq "superseded + branch signal → branch still drives done (replacement branch ancestor)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 1 0 1)" "done:branch-ancestor-of-origin-main"
eq "epic beats superseded-only → keep (epic reason)" \
   "$(janitor_story_decide 1 0 0 0 0 0 0 0 0 0 1)" "keep:epic-parent-never-autoclosed"
eq "already-done beats superseded-only → keep (idempotent, not re-driven by a stale marker)" \
   "$(janitor_story_decide 0 0 1 0 0 0 0 0 0 0 1)" "keep:already-story-done"
eq "in-flight beats superseded-only → keep (active rework not masked as done)" \
   "$(janitor_story_decide 0 0 0 1 0 0 0 0 0 0 1)" "keep:story-in-flight-active-rework"

# ── 1b4. janitor_story_decide sig_commit_docs_only — patch-staged ≠ fix-applied (ga-fbycg) ──
# A story can land its ONLY origin/main trace as a docs/pending-engine-window
# patch-staging commit too — nothing about the phenomenon is bug/task-specific. The
# suppression mirrors janitor_decide §1a6 exactly (12th arg here vs 10th there, since
# janitor_story_decide already carries the 6 story-specific guard args up front).
echo "── 1b4. janitor_story_decide sig_commit_docs_only (patch-staged ≠ fix-applied, ga-fbycg) ──"
eq "backward-compat: 11 args, no 12th → commit still done" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 0 0)" "done:commit-in-origin-main"
eq "docs-only commit alone → KEEP (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 0 0 1)" "keep:commit-evidence-docs-only-patch-staged"
eq "docs-only + marker also fires → marker still drives done (signal B unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 1 0 0 0 1)" "done:terminal-gate-marker-passed"
eq "docs-only + branch also fires → branch still drives done (signal C unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 1 0 0 1)" "done:branch-ancestor-of-origin-main"
eq "in-flight guard still beats a docs-only-flagged commit" \
   "$(janitor_story_decide 0 0 0 1 0 0 1 0 0 0 0 1)" "keep:story-in-flight-active-rework"
eq "already-done beats docs-only-only → keep (idempotent)" \
   "$(janitor_story_decide 0 0 1 0 0 0 1 0 0 0 0 1)" "keep:already-story-done"
# Fixture CONTROLE: NOT docs-only (0) → commit still drives done exactly as before.
eq "not-docs-only + commit signal → still done normally" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0 0 0 0)" "done:commit-in-origin-main"

# ── 1b5. janitor_story_decide sig_marker_stale — reverted-merge stale-marker guard (ga-tysvjp) ──
# Same parity as janitor_decide §1a7: a story's terminal gate-status:passed marker can be
# just as stale as a bug/task bead's (a revert after PASS that never relabeled the marker
# to gate-status:superseded). The suppression mirrors janitor_decide §1a7 exactly (13th arg
# here vs 11th there, since janitor_story_decide already carries the 6 story-specific guard
# args up front).
echo "── 1b5. janitor_story_decide sig_marker_stale (reverted-merge stale-marker guard, ga-tysvjp) ──"
eq "backward-compat: 12 args, no 13th → marker still done" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 1 0 0 0 0)" "done:terminal-gate-marker-passed"
eq "stale marker alone → KEEP (not forced to story:done)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 1 0 0 0 0 1)" "keep:marker-evidence-superseded-by-newer-comment"
eq "stale marker + commit also fires → commit still drives done (signal A unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 1 0 0 0 0 1)" "done:commit-in-origin-main"
eq "stale marker + branch also fires → branch still drives done (signal C unaffected)" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 1 1 0 0 0 1)" "done:branch-ancestor-of-origin-main"
eq "in-flight guard still beats a stale-flagged marker" \
   "$(janitor_story_decide 0 0 0 1 0 0 0 1 0 0 0 0 1)" "keep:story-in-flight-active-rework"
eq "already-done beats stale-marker-only → keep (idempotent)" \
   "$(janitor_story_decide 0 0 1 0 0 0 0 1 0 0 0 0 1)" "keep:already-story-done"
# Fixture CONTROLE: NOT stale (0) → marker still drives done exactly as before.
eq "not-stale + marker signal → still done normally" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 1 0 0 0 0 0)" "done:terminal-gate-marker-passed"

# ── 1c. janitor_branch_decide — crew-branch prune (ga-tijv5 extension) ──────
# Args: <ahead> <content_in_main> <bead_state> <live_worktree> <is_fresh>. A branch
# is prunable iff its CONTENT is fully in main — either ahead==0 (strict ancestor;
# cim trivially 1) OR ahead>0 but cim==1 (squash / re-commit, the wa-fvxj1 class) —
# AND bead closed|gone AND no worktree AND not fresh. A branch with a unique patch
# NOT in main (ahead>0 AND cim!=1) must NEVER prune. Every uncertain state → KEEP.
echo "── 1c. janitor_branch_decide (crew-branch prune, squash-aware) ──"
# Strict-ancestor prune paths (ahead==0 ⟹ cim==1): fully-merged + bead closed / gone.
eq "merged + bead closed → prune"       "$(janitor_branch_decide 0 1 closed 0 0)" "prune:merged-and-bead-closed"
eq "merged + bead gone → prune"         "$(janitor_branch_decide 0 1 gone   0 0)" "prune:merged-and-bead-gone"
eq "prune verb (closed)"                "$(janitor_branch_decide 0 1 closed 0 0 | cut -d: -f1)" "prune"
# SQUASH-MERGE prune paths (ahead>0 by sha BUT content patch-present in main, cim==1):
# the wa-fvxj1 class — now prunable (was the systemic blind spot). Distinct reason.
eq "squash-merged + bead closed → prune" "$(janitor_branch_decide 1 1 closed 0 0)" "prune:squash-merged-and-bead-closed"
eq "squash-merged + bead gone → prune"   "$(janitor_branch_decide 3 1 gone   0 0)" "prune:squash-merged-and-bead-gone"
eq "squash prune verb"                   "$(janitor_branch_decide 1 1 closed 0 0 | cut -d: -f1)" "prune"
# CRITICAL negative direction — genuinely-unique content (ahead>0 AND cim!=1) is the
# destructive case: NEVER pruned, whatever the bead state. A false merged-verdict here
# would DELETE real work off the remote.
eq "unmerged content → keep"            "$(janitor_branch_decide 5 0 closed 0 0)" "keep:has-unmerged-commits"
eq "unmerged even if bead gone → keep"  "$(janitor_branch_decide 1 0 gone   0 0)" "keep:has-unmerged-commits"
# bad ahead read (ERR) with unverified content (cim=0) → keep (fail-safe).
eq "bad ahead read + cim=0 → keep"      "$(janitor_branch_decide ERR 0 closed 0 0)" "keep:has-unmerged-commits"
# bad ahead read BUT content verified in main (cim=1) → still lossless → squash prune.
eq "bad ahead read + cim=1 → prune"     "$(janitor_branch_decide ERR 1 closed 0 0)" "prune:squash-merged-and-bead-closed"
# Live worktree wins over everything (active agent), even fully merged + closed.
eq "live worktree → keep"               "$(janitor_branch_decide 0 1 closed 1 0)" "keep:live-worktree"
eq "worktree beats prune (gone)"        "$(janitor_branch_decide 0 1 gone   1 0)" "keep:live-worktree"
eq "worktree beats squash prune"        "$(janitor_branch_decide 2 1 closed 1 0)" "keep:live-worktree"
# Freshness grace: a just-merged branch is kept even with a closed bead.
eq "fresh branch → keep"                "$(janitor_branch_decide 0 1 closed 0 1)" "keep:fresh-branch-grace-window"
eq "fresh squash branch → keep"         "$(janitor_branch_decide 2 1 closed 0 1)" "keep:fresh-branch-grace-window"
# Open/active bead → keep (courtesy; content already in main loses nothing but we don't touch it).
eq "open/active bead → keep"            "$(janitor_branch_decide 0 1 active 0 0)" "keep:bead-open-or-active"
eq "open/active bead (squash) → keep"   "$(janitor_branch_decide 2 1 active 0 0)" "keep:bead-open-or-active"
# FAIL-OPEN: an unreadable bead status must never be pruned (transient Dolt).
eq "bead read error → keep (failopen)"  "$(janitor_branch_decide 0 1 readerror 0 0)" "keep:bead-read-error-failopen"
# Guard precedence: worktree > unmerged-content > fresh > readerror > active > closed/gone.
eq "worktree > unmerged"                "$(janitor_branch_decide 9 0 closed 1 0)" "keep:live-worktree"
eq "unmerged > fresh"                   "$(janitor_branch_decide 3 0 closed 0 1)" "keep:has-unmerged-commits"
eq "fresh > readerror"                  "$(janitor_branch_decide 0 1 readerror 0 1)" "keep:fresh-branch-grace-window"
eq "readerror > active"                 "$(janitor_branch_decide 0 1 active 0 0)" "keep:bead-open-or-active"

# ── 1d. normalize_bead_status — raw bd status → coarse closed|active ─────────
echo "── 1d. normalize_bead_status ──"
eq "closed → closed"                    "$(normalize_bead_status closed)" "closed"
eq "open → active"                      "$(normalize_bead_status open)" "active"
eq "in_progress → active"               "$(normalize_bead_status in_progress)" "active"
eq "blocked → active"                   "$(normalize_bead_status blocked)" "active"
eq "deferred → active"                  "$(normalize_bead_status deferred)" "active"
eq "empty → active (safe)"              "$(normalize_bead_status '')" "active"

# ── 2. token_bounded — whole-token id match (no substring false-positives) ──
echo "── 2. token_bounded ──"
rc0 token_bounded "wa-1or2" "feat(wa-1or2): add simplified mode"
rc0 token_bounded "wa-1or2" "Mirrors WA bead wa-1or2; the artifact is HQ-local"
rc0 token_bounded "wa-1or2" "Source bead: ga-piycl (mirror of wa-1or2)"
rc1 token_bounded "wa-1"    "feat(wa-1or2): unrelated longer id"      # wa-1 must NOT match wa-1or2
rc1 token_bounded "wa-1or2" "see commit wa-1or2x for details"          # trailing alnum breaks boundary
rc1 token_bounded "wa-1or2" "totally unrelated message"

# ── 2b. subject_impl_scopes_bead — THE DISCRIMINATOR (ga-wisp-ld35wuw) ───────
# rc0 iff the bead id is the IMPLEMENTING conventional-commit SCOPE (header before the
# first colon), rc1 if it is only a trailing context/motivation reference. This is the
# exact test that separates a genuine delivery from a framework commit that merely names
# the bead. The two load-bearing cases are the REAL commits from the wa-iy9s8 false-close.
echo "── 2b. subject_impl_scopes_bead (impl-scope vs trailing context) ──"
# THE REGRESSION (real subjects): 286cb29c7-HQ mentioned wa-iy9s8 in a TRAILING context
# paren "(ga-4aree/wa-iy9s8)"; d0219063-WA is the genuine fix(wa-iy9s8): delivery. The OLD
# scanner token-bounded the WHOLE subject and matched BOTH → false-closed the P1 bug.
rc1 subject_impl_scopes_bead "fix(pilot): rig-native scan no longer excludes gate:needs-fix — rig re-fix bugs dispatch (ga-4aree/wa-iy9s8)" "wa-iy9s8"   # trailing context → NOT delivery
rc0 subject_impl_scopes_bead "fix(wa-iy9s8): auto-deploy viewer/ to S3 on merge — done != deployed" "wa-iy9s8"                                          # scope → delivery
# Implementing-scope forms all MATCH (rc0):
rc0 subject_impl_scopes_bead "feat(wa-iy9s8): add thing" "wa-iy9s8"                       # feat(<id>):
rc0 subject_impl_scopes_bead "feat(warming/wa-iy9s8): re-land squashed lane" "wa-iy9s8"   # path-segment scope
rc0 subject_impl_scopes_bead "Merge crew/mila/wa-iy9s8: painel column-selector" "wa-iy9s8" # genuine merge landing
rc0 subject_impl_scopes_bead "wa-iy9s8: fix the crash" "wa-iy9s8"                          # bare-id lead
rc0 subject_impl_scopes_bead "fix bug wa-iy9s8: retry logic" "wa-iy9s8"                    # "fix bug <id>:" lead
rc0 subject_impl_scopes_bead "merge(wa-86jr+wa-o3zs): Contagem cadastre bulk-load" "wa-o3zs" # multi-id scope (real wa-o3zs landing)
# Trailing-context / body-ish / wrong-scope forms all REJECTED (rc1):
rc1 subject_impl_scopes_bead "tune(gate): VERDICT_TIMEOUT 45→22min (interim until gt-x2xin Phase-2)" "gt-x2xin" # explicitly FUTURE work
rc1 subject_impl_scopes_bead "fix(pilot): fixes dispatch for wa-iy9s8 stranded beads" "wa-iy9s8"               # id after colon = description
rc1 subject_impl_scopes_bead "feat(wa-ab6z): São João Batista 5 donos (ITBI)" "wa-y2lk"                        # sibling under parent → per-bead unproven
rc1 subject_impl_scopes_bead "docs(wa-e34v): doc-mestre de data-mastery de Contagem" "wa-qjym"                 # unrelated scope, no id
rc1 subject_impl_scopes_bead "chore: see also refs wa-iy9s8" "wa-iy9s8"                                        # trailing reference
# FAIL-CLOSED edges:
rc1 subject_impl_scopes_bead "merge wa-iy9s8 into main" "wa-iy9s8"                         # NO colon → no locatable scope → reject
rc1 subject_impl_scopes_bead 'Revert "fix(wa-iy9s8): add thing"' "wa-iy9s8"                # git default revert → undo, not delivery
rc1 subject_impl_scopes_bead "revert: fix(wa-iy9s8): add thing" "wa-iy9s8"                 # conventional revert → reject
rc1 subject_impl_scopes_bead "fix(wa-1or2): unrelated longer id" "wa-1"                    # token boundary: wa-1 ≠ wa-1or2

# ── 3. merge-evidence helpers — real git, no network ────────────────────────
echo "── 3. scan_commit_for_bead + branch_merged (real repo) ──"
export GIT_AUTHOR_NAME=selftest  GIT_AUTHOR_EMAIL=selftest@local
export GIT_COMMITTER_NAME=selftest GIT_COMMITTER_EMAIL=selftest@local
T="$(mktemp -d 2>/dev/null || mktemp -d -t gatijv5)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
R="$T/repo"
git init -q -b main "$R"
( cd "$R" && echo a > a.txt && git add a.txt && git commit -q -m "C1 base" )
# A mirror-style commit: subject says feat(refino), body references the WA bead.
( cd "$R" && echo b > b.txt && git add b.txt && \
  git commit -q -m "feat(refino): add simplified mode" -m "Mirrors WA bead tt-1or2 (source ga-mirror)." )
MIRROR_SHA=$(git -C "$R" rev-parse --short=9 HEAD)
# A short-id commit to test the boundary (tt-1 is its own token here).
( cd "$R" && echo c > c.txt && git add c.txt && git commit -q -m "fix(tt-1): boundary token" )

# scan: bead id present in body (mirror) → found, prints the sha.
GOT=$(scan_commit_for_bead "$R" 0 "main" "tt-1or2" 2>/dev/null || true)
if [ -n "$GOT" ]; then ok "scan finds mirror-body id tt-1or2 (sha=${GOT:0:9})"; else bad "scan missed mirror-body id tt-1or2"; fi
# boundary: tt-1 is a real token in 'fix(tt-1)' → found; but must NOT match inside tt-1or2.
rc0 scan_commit_for_bead "$R" 0 "main" "tt-1"
# absent id → not found.
rc1 scan_commit_for_bead "$R" 0 "main" "tt-zzzz"
# bad ref → rc1 (never crashes the sweep).
rc1 scan_commit_for_bead "$R" 0 "refs/heads/does-not-exist" "tt-1or2"

# branch_is_fresh (ga-tijv5 extension) — HEAD was committed "now" by this test.
eq "just-committed tip is fresh (7d)"   "$(branch_is_fresh "$R" 0 "main" 7)" "1"
eq "zero-day window → not fresh"        "$(branch_is_fresh "$R" 0 "main" 0)" "0"
eq "unknown ref date → not fresh"       "$(branch_is_fresh "$R" 0 "refs/heads/does-not-exist" 7)" "0"

# ── 3b. scan_commit_subject_for_bead — STRICT (subject only), ga-gosfs ───────
# Rejects incidental BODY mentions of a still-open story (the ga-r471 / wa-qggy
# false-positive class) while still finding genuine implementing-commits whose
# id is in the conventional-commit SUBJECT scope.
echo "── 3b. scan_commit_subject_for_bead (strict subject scope) ──"
# tt-1or2 lives ONLY in the mirror commit's BODY → strict scan must NOT find it.
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-1or2"
# tt-1 is in the SUBJECT 'fix(tt-1): …' → strict scan FINDS it (genuine impl commit).
rc0 scan_commit_subject_for_bead "$R" 0 "main" "tt-1"
GOTS=$(scan_commit_subject_for_bead "$R" 0 "main" "tt-1" 2>/dev/null || true)
if [ -n "$GOTS" ]; then ok "strict scan prints sha for subject-scoped tt-1 (sha=${GOTS:0:9})"; else bad "strict scan missed subject-scoped tt-1"; fi
# absent id → not found; bad ref → rc1 (never crashes the sweep).
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-zzzz"
rc1 scan_commit_subject_for_bead "$R" 0 "refs/heads/does-not-exist" "tt-1"
# Regression: a commit that names the bead in its body as STILL-OPEN/future work
# (verbatim shape of the ga-r471 + wa-qggy false positives) → strict scan REJECTS.
( cd "$R" && echo e > e.txt && git add e.txt && \
  git commit -q -m "fix(tt-other): rescope budget cap" \
                -m "enforcement moves to tt-future (after tt-acct); remains open in tt-future engine window" )
rc1 scan_commit_subject_for_bead "$R" 0 "main" "tt-future"   # body-only future mention → NOT done
rc0 scan_commit_for_bead         "$R" 0 "main" "tt-future"   # body scan WOULD match (shows why strict is needed)

# branch_merged: topic branch that IS an ancestor of main vs one that is not.
git -C "$R" branch merged-topic HEAD~1     # points at the mirror commit (ancestor of main)
git -C "$R" checkout -q -b ahead-topic main
( cd "$R" && echo d > d.txt && git add d.txt && git commit -q -m "ahead-only commit" )
git -C "$R" checkout -q main
rc0 branch_merged "$R" 0 "merged-topic" "main"     # ancestor → merged
rc1 branch_merged "$R" 0 "ahead-topic"  "main"     # has commit not in main → not merged
rc1 branch_merged "$R" 0 "no-such-branch" "main"   # missing branch → not merged (safe)
# ga-tijv5 regression: the degenerate self-referential check (bref == mref) must NOT
# count as merged. A bad marker-label / fold-linkage that resolved the branch to "main"
# itself made "main ⊑ main" trivially true and FALSE-closed an in_progress bead whose
# real crew branch was AHEAD of main, unmerged (wa-85iv8 2026-06-30).
rc1 branch_merged "$R" 0 "main" "main"             # main vs main → degenerate, NOT merged
rc1 branch_merged "$R" 0 ""     "main"             # empty bref → not merged (safe)

# ── 3c. content_in_main — SQUASH-AWARE merge detection (the wa-fvxj1 fix) ────
# A crew branch whose tip is NOT a git ancestor of main (a new sha) but whose
# entire diff is already in main via a SQUASH / re-commit. branch_merged (strict
# ancestry) says "not merged"; content_in_main correctly says "merged" (lossless to
# prune). The NEGATIVE direction — a branch with a UNIQUE patch not in main — MUST
# return "not merged" so the janitor never green-lights deleting real work.
echo "── 3c. content_in_main (squash-aware merge detection) ──"
# Build the squash case: crew branch commits a change; main RE-COMMITS the same diff
# under a new sha (exactly what a squash-merge / re-land produces — cf. wa-fvxj1's
# feat(warming/wa-fvxj1) re-commit). Tip != ancestor, but content present in main.
git -C "$R" checkout -q -b crew/x/tt-squash main
( cd "$R" && printf 'squash-feature\n' > squash.txt && git add squash.txt && git commit -q -m "work(tt-squash): feature on crew branch" )
git -C "$R" checkout -q main
( cd "$R" && printf 'squash-feature\n' > squash.txt && git add squash.txt && git commit -q -m "feat(warm/tt-squash): re-land squashed lane" )
# Sanity: strict ancestry says NOT merged (tip is a different sha) …
rc1 branch_merged   "$R" 0 "crew/x/tt-squash" "main"    # strict ancestry → NOT merged
# … but the CONTENT is fully in main (patch-equivalent) → content_in_main rc0.
rc0 content_in_main "$R" 0 "crew/x/tt-squash" "main"    # squash-aware → MERGED (lossless)
# strict ahead is >0 — this is precisely why the ahead==0 gate ALONE never pruned it.
eq "squash branch strict-ahead > 0" "$(git -C "$R" rev-list --count main..crew/x/tt-squash)" "1"
# NEGATIVE direction (the destructive case): a branch with a UNIQUE patch not in main
# must be reported NOT merged — content_in_main must NEVER green-light a delete of it.
# ahead-topic (built in §3b) carries a unique "ahead-only commit" (d.txt) not in main.
rc1 content_in_main "$R" 0 "ahead-topic" "main"         # unique patch → NOT merged (KEEP)
# A strict-ancestor branch is trivially content-in-main.
rc0 content_in_main "$R" 0 "merged-topic" "main"        # ancestor → merged
# Degenerate / bad inputs → NOT merged (fail-closed); never crash the sweep.
rc1 content_in_main "$R" 0 "main" "main"                # self-check (bref==mref) rejected
rc1 content_in_main "$R" 0 ""     "main"                # empty bref
rc1 content_in_main "$R" 0 "no-such-branch" "main"      # unresolvable ref

# ── 3d. commit_epoch — live-git committer-date lookup (ga-2zp4h) ───────────
# Feeds commit_evidence_stale: the sha Signal A matched must resolve to ITS OWN
# committer-date epoch so the janitor can compare it against the bead's comments.
echo "── 3d. commit_epoch (real git, feeds commit_evidence_stale) ──"
WANT_EPOCH=$(git -C "$R" log -1 --format='%ct' "$MIRROR_SHA")
eq "commit_epoch matches raw git %ct for a real sha" \
   "$(commit_epoch "$R" 0 "$MIRROR_SHA")" "$WANT_EPOCH"
rc1 commit_epoch "$R" 0 "0000000000000000000000000000000000000000"   # unresolvable sha
rc1 commit_epoch "$R" 0 ""                                            # empty sha

# ── 3e. commit_touches_only_pending_patch — patch-staged ≠ fix-applied (ga-fbycg) ──
# `git show --name-only` always reports paths relative to the REPO ROOT, never the
# `-C` directory — verified live 2026-08-29 (the exact assumption this function relies
# on). Two confirmed false-closes (ga-soxi9, ga-9n9z7) both matched Signal A on a commit
# that ONLY added a docs/pending-engine-window/*.patch file; this proves the guard
# recognizes BOTH real path forms (canonical nested + historically-misfiled top-level)
# and rejects any commit that touches so much as one file outside that convention.
echo "── 3e. commit_touches_only_pending_patch (patch-staged ≠ fix-applied, real repo) ──"
mkdir -p "$R/.gascity-gastown-hq/docs/pending-engine-window" "$R/docs/pending-engine-window"
( cd "$R" && printf 'patch content\n' > .gascity-gastown-hq/docs/pending-engine-window/ga-nested.patch && \
  git add .gascity-gastown-hq/docs/pending-engine-window/ga-nested.patch && \
  git commit -q -m "docs(tt-nested): pending-engine-window patch -- nested convention" )
NESTED_SHA=$(git -C "$R" rev-parse HEAD)
( cd "$R" && printf 'patch content\n' > docs/pending-engine-window/ga-toplevel.patch && \
  git add docs/pending-engine-window/ga-toplevel.patch && \
  git commit -q -m "docs(tt-toplevel): pending-engine-window patch -- misfiled top-level form" )
TOPLEVEL_SHA=$(git -C "$R" rev-parse HEAD)
( cd "$R" && printf 'fix content\n' > .gascity-gastown-hq/real_fix.sh && \
  printf 'patch content v2\n' > .gascity-gastown-hq/docs/pending-engine-window/ga-nested.patch && \
  git add .gascity-gastown-hq/real_fix.sh .gascity-gastown-hq/docs/pending-engine-window/ga-nested.patch && \
  git commit -q -m "fix(tt-mixed): actually applies the fix" -m "touches both a patch file and the real source" )
MIXED_SHA=$(git -C "$R" rev-parse HEAD)
# Positive: a commit whose ONLY changed files are patch files (either valid path form).
rc0 commit_touches_only_pending_patch "$R" 0 "$NESTED_SHA"     # nested .gascity-gastown-hq/docs/... form
rc0 commit_touches_only_pending_patch "$R" 0 "$TOPLEVEL_SHA"   # top-level misfiled docs/... form
# Negative: a commit that touches even ONE file outside the convention must NOT count,
# even when it ALSO touches a patch file (the mixed case — a real fix landing alongside
# a patch-queue cleanup must never be suppressed).
rc1 commit_touches_only_pending_patch "$R" 0 "$MIXED_SHA"
# Negative: a genuine non-patch commit from §3 (touches b.txt only).
rc1 commit_touches_only_pending_patch "$R" 0 "$MIRROR_SHA"
# FAIL-CLOSED edges: never invent "docs-only" from bad input (mirrors commit_evidence_stale's
# own fail-open-to-preserve-prior-behaviour idiom — here prior behaviour is "not docs-only").
rc1 commit_touches_only_pending_patch "$R" 0 ""                                            # empty sha
rc1 commit_touches_only_pending_patch "$R" 0 "0000000000000000000000000000000000000000"   # unresolvable sha

# ── 4. marker JSON helpers — synthetic fixtures ─────────────────────────────
echo "── 4. marker helpers ──"
M_OPEN='[{"status":"open","labels":["gate-status:queued","source-bead:wa-lstd","branch:crew/mila/wa-lstd"]}]'
M_PASSED='[{"status":"closed","labels":["gate-status:passed","source-bead:x"]}]'
M_SUPER='[{"status":"closed","labels":["gate-status:superseded","source-bead:x"]}]'
M_FAILED='[{"status":"closed","labels":["gate-status:failed","source-bead:x"]}]'
M_MIXED='[{"status":"open","labels":["gate-status:ready"]},{"status":"closed","labels":["gate-status:superseded"]}]'
M_EMPTY='[]'
rc0 has_open_marker "$M_OPEN"
rc1 has_open_marker "$M_PASSED"
rc1 has_open_marker "$M_EMPTY"
rc0 has_open_marker "$M_MIXED"                       # wa-ab6z shape: open ready + closed superseded → kept
rc0 has_terminal_passed_marker "$M_PASSED"
rc1 has_terminal_passed_marker "$M_SUPER"            # ga-v8ui5: superseded is NOT passed — the opposite (branch discarded)
rc1 has_terminal_passed_marker "$M_FAILED"           # closed-FAILED is NOT merged → no close signal
rc1 has_terminal_passed_marker "$M_OPEN"
rc1 has_terminal_passed_marker "$M_EMPTY"
# has_terminal_superseded_marker (ga-v8ui5) — distinguishable, NON-closing signal.
rc0 has_terminal_superseded_marker "$M_SUPER"
rc1 has_terminal_superseded_marker "$M_PASSED"
rc1 has_terminal_superseded_marker "$M_FAILED"
rc1 has_terminal_superseded_marker "$M_OPEN"
rc1 has_terminal_superseded_marker "$M_EMPTY"
eq "branch label extracted" "$(branch_label_from_markers "$M_OPEN")" "crew/mila/wa-lstd"
eq "no branch label → empty" "$(branch_label_from_markers "$M_PASSED")" ""

# ── 4b. commit_evidence_stale — synthetic comment fixtures (ga-2zp4h) ───────
# The real wa-d3136 shape: the false-closing commit landed 2026-07-24T22:29:53-03:00
# (epoch 1784942993); mila's reassignment comment landed 2026-07-26T03:13:51Z (epoch
# 1785035631) — a full day later. These are the ACTUAL production timestamps that
# reproduced the false-close (verified live against wa-d3136 + commit cd4c6f058).
echo "── 4b. commit_evidence_stale (comment-postdates-commit guard) ──"
CWA='[{"created_at":"2026-07-26T03:13:51Z"}]'
rc0 commit_evidence_stale "$CWA" 1784942993          # real wa-d3136 timestamps → STALE
rc1 commit_evidence_stale "$CWA" 1785200000          # comment BEFORE commit epoch → not stale
# Multiple comments: ANY one newer than the commit epoch is enough to flag stale.
CMULTI='[{"created_at":"2026-07-20T00:00:00Z"},{"created_at":"2026-07-27T00:00:00Z"}]'
rc0 commit_evidence_stale "$CMULTI" 1785000000
# No comments at all (the comment_count=0 shape: `bd comments <id> --json` → []).
rc1 commit_evidence_stale "[]" 1784942993
# FAIL-OPEN directions (ga-2zp4h design: never invent a false "stale" from bad input —
# preserves today's Signal-A behaviour rather than a new way to go silent on a merge).
rc1 commit_evidence_stale "$CWA" ""                                    # empty commit_epoch
rc1 commit_evidence_stale "$CWA" "not-a-number"                        # non-numeric commit_epoch
rc1 commit_evidence_stale "not json" 1784942993                        # unparseable comments blob
rc1 commit_evidence_stale '[{"created_at":"not-a-date"}]' 1784942993   # unparseable created_at

# ── 4c. terminal_passed_marker_epoch + marker_evidence_stale — synthetic fixtures (ga-tysvjp) ──
# marker_evidence_stale is a thin wrapper around commit_evidence_stale (already
# exhaustively fixture-tested in §4b for the comment-parsing side) — these tests cover
# the NEW selection logic: closed_at vs updated_at fallback, filtering by
# status=closed+gate-status:passed, and picking the MAX epoch across multiple markers.
echo "── 4c. terminal_passed_marker_epoch + marker_evidence_stale (ga-tysvjp) ──"
MP_CLOSED_AT='[{"status":"closed","labels":["gate-status:passed"],"closed_at":"2026-01-01T00:00:00Z","updated_at":"2026-02-01T00:00:00Z"}]'
eq "prefers closed_at over updated_at when both present" \
   "$(terminal_passed_marker_epoch "$MP_CLOSED_AT")" "1767225600"
MP_UPDATED_ONLY='[{"status":"closed","labels":["gate-status:passed"],"updated_at":"2026-02-01T00:00:00Z"}]'
eq "falls back to updated_at when closed_at absent" \
   "$(terminal_passed_marker_epoch "$MP_UPDATED_ONLY")" "1769904000"
MP_TWO='[{"status":"closed","labels":["gate-status:passed"],"closed_at":"2026-01-01T00:00:00Z"},{"status":"closed","labels":["gate-status:passed"],"closed_at":"2026-03-01T00:00:00Z"}]'
eq "picks the MAX epoch across multiple matching markers" \
   "$(terminal_passed_marker_epoch "$MP_TWO")" "1772323200"
MP_IGNORES_OTHERS='[{"status":"open","labels":["gate-status:passed"],"closed_at":"2026-03-01T00:00:00Z"},{"status":"closed","labels":["gate-status:superseded"],"closed_at":"2026-03-01T00:00:00Z"},{"status":"closed","labels":["gate-status:passed"],"closed_at":"2026-01-01T00:00:00Z"}]'
eq "ignores open markers and non-passed labels, uses only the matching one" \
   "$(terminal_passed_marker_epoch "$MP_IGNORES_OTHERS")" "1767225600"
eq "no matching marker at all → -1 (fail-open sentinel, non-numeric-safe)" \
   "$(terminal_passed_marker_epoch "$M_EMPTY")" "-1"
eq "unparseable closed_at → -1 (fail-open, not a crash)" \
   "$(terminal_passed_marker_epoch '[{"status":"closed","labels":["gate-status:passed"],"closed_at":"not-a-date"}]')" "-1"
# marker_evidence_stale — delegates to commit_evidence_stale. Reusing the exact same
# $CWA fixture + epochs as §4b proves the delegation is exact, not just "similar".
rc0 marker_evidence_stale "$CWA" 1784942993          # same fixture/epoch as §4b's stale case
rc1 marker_evidence_stale "$CWA" 1785200000          # same fixture/epoch as §4b's not-stale case

# ── 5. rig_gitdir — container (.repo.git) vs self-repo selection ────────────
echo "── 5. rig_gitdir ──"
SR="$T/selfrepo"; mkdir -p "$SR/.git"
CR="$T/container"; mkdir -p "$CR/.repo.git"
eq "self-repo → working tree, container=0" "$(rig_gitdir "$SR")" "$(printf '%s\t0' "$SR")"
eq "container → bare .repo.git, container=1" "$(rig_gitdir "$CR")" "$(printf '%s/.repo.git\t1' "$CR")"

# ── 6. Drift-guard: the live janitor wires the contract ─────────────────────
echo "── 6. drift-guard: janitor + plist wiring ──"
grep -q 'JANITOR_LIB_ONLY' "$JANITOR"            && ok "janitor sourceable in lib-only mode"     || bad "missing lib-only hook"
grep -q 'janitor_decide()' "$JANITOR"            && ok "defines janitor_decide"                  || bad "missing janitor_decide def"
grep -q 'scan_commit_for_bead()' "$JANITOR"      && ok "defines scan_commit_for_bead"            || bad "missing scan_commit_for_bead def"
grep -q 'epic-parent-never-autoclosed' "$JANITOR" && ok "epic guard present"                     || bad "epic guard missing"
grep -q 'active-open-gate-marker' "$JANITOR"     && ok "open-marker guard present"               || bad "open-marker guard missing"
grep -q 'label remove "$BID" "story:in-flight"' "$JANITOR" && ok "drops story:in-flight on close" || bad "story:in-flight removal missing"
grep -q 'JANITOR_DRY_RUN' "$JANITOR"             && ok "dry-run supported"                       || bad "dry-run support missing"
grep -q 'gate-status:passed' "$JANITOR"          && ok "terminal signal checks passed"           || bad "passed marker label missing"
# ga-v8ui5: superseded must NOT be OR'd into has_terminal_passed_marker — it is the
# opposite of passed (a discarded/replaced branch), not a merge signal. Assert the negative.
grep -qF 'or . == "gate-status:superseded"' "$JANITOR" \
  && bad "has_terminal_passed_marker still ORs in gate-status:superseded (ga-v8ui5 regression)" \
  || ok "has_terminal_passed_marker no longer treats superseded as passed"
# Branch-prune extension (ga-tijv5, 2026-07-01) — wired, conservative, and STAGED (off by default).
grep -q 'janitor_branch_decide()' "$JANITOR"     && ok "defines janitor_branch_decide"           || bad "missing janitor_branch_decide def"
grep -q 'PRUNE_BRANCHES="${JANITOR_PRUNE_BRANCHES:-0}"' "$JANITOR" && ok "branch-prune is OPT-IN, default OFF (staged)" || bad "branch-prune not default-off"
grep -q 'if \[ "$PRUNE_BRANCHES" = "1" \]' "$JANITOR" && ok "branch-prune sweep gated behind PRUNE_BRANCHES" || bad "branch-prune sweep not gated"
grep -q 'has-unmerged-commits' "$JANITOR"        && ok "never prunes unique content (ahead>0 & cim!=1)" || bad "unmerged-commits guard missing"
grep -q 'bead-read-error-failopen' "$JANITOR"    && ok "fail-open on bad bead read"              || bad "fail-open guard missing"
grep -q 'recheck content-in-main' "$JANITOR"     && ok "re-verifies content-in-main at delete time" || bad "delete-time content-in-main recheck missing"
grep -q 'BRANCH_PRUNE_MAX_PER_SWEEP' "$JANITOR"  && ok "per-sweep deletion cap present"          || bad "deletion cap missing"
# Squash-aware merge detection (the wa-fvxj1 fix): content_in_main via patch-id
# equivalence recognises a squash/re-commit (ahead>0 by sha, content in main).
grep -q 'content_in_main()' "$JANITOR"           && ok "defines content_in_main (squash-aware)"  || bad "missing content_in_main def"
grep -q 'cherry-pick --right-only' "$JANITOR"    && ok "uses git patch-id equivalence (--cherry-pick)" || bad "cherry-pick content check missing"
grep -q 'squash-merged-and-bead-closed' "$JANITOR" && ok "squash-merged prune reason wired"      || bad "squash prune reason missing"
grep -q 'janitor_branch_decide "\$AHEAD" "\$CIM"' "$JANITOR" && ok "branch decider fed content-in-main (CIM) signal" || bad "branch decider not passed CIM"
grep -q 'prune="--prune"' "$JANITOR" && grep -q 'PRUNE_BRANCHES" = "1" \] && prune' "$JANITOR" \
  && ok "fetch --prune gated behind PRUNE_BRANCHES (staged; no stale refs when active)" || bad "fetch prune gating missing"
grep -q 'remote moved since decision' "$JANITOR" && ok "delete-time remote-SHA CAS guard present" || bad "remote-SHA CAS guard missing"
# STAGED, not deployed: the plist must NOT enable branch pruning (the Mayor's deploy step).
if grep -q 'JANITOR_PRUNE_BRANCHES' "$PLIST" 2>/dev/null; then bad "plist must NOT enable branch prune (staging violated)"; else ok "plist does NOT enable branch prune (correctly staged)"; fi
# Cross-store: own-rig repo scan falls back to HQ repo (mirror case) using strict subject scan.
grep -q 'scan_commit_subject_for_bead "$HQ_GITDIR"' "$JANITOR" && ok "cross-store HQ-repo mirror scan wired (strict)" || bad "HQ-repo mirror scan missing or not strict"
# The in_progress sweep MUST use the strict subject scanner (not the body scanner) for
# signal A — guards against the wa-oxkg false-positive class: an unrelated commit that
# merely MENTIONS a bead id in its body (incident description, cross-ref) must NOT close
# that bead. Only a conventional-commit scoped as feat(<id>)/fix(<id>)/etc. in the SUBJECT
# qualifies as delivery evidence.
grep -q 'scan_commit_subject_for_bead "\$RGITDIR" "\$RCONTAINER" "origin/\$RDEFAULT" "\$BID"' "$JANITOR" \
  && ok "in_progress sweep uses strict subject scan for BID" || bad "in_progress sweep not using strict scanner for BID"
# ga-wisp-ld35wuw (2026-07-01): SCOPE discriminator + own-rig-repo scoping (the wa-iy9s8 fix).
# The false-close was an HQ `fix(pilot): … (ga-4aree/wa-iy9s8)` commit whose SUBJECT carried the
# rig id in a TRAILING context paren; the whole-subject scanner matched it and auto-closed the P1
# bug. Signal A now (a) requires the id to be the SUBJECT SCOPE (header before the first colon)
# via subject_impl_scopes_bead, and (b) matches a RIG-NATIVE bead ONLY against its own rig repo.
grep -q 'subject_impl_scopes_bead()' "$JANITOR" \
  && ok "defines subject_impl_scopes_bead (scope discriminator)" || bad "missing subject_impl_scopes_bead def"
grep -qF 'if subject_impl_scopes_bead "$subj" "$id"' "$JANITOR" \
  && ok "scan_commit_subject_for_bead gated on subject SCOPE (not whole-subject token)" || bad "scanner not using subject_impl_scopes_bead"
grep -qF '[ "${BID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "in_progress HQ fallback prefix-guarded (rig-native bead never matched vs HQ)" || bad "in_progress HQ fallback not prefix-guarded"
grep -qF '[ "${SID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "story HQ fallback prefix-guarded (rig-native story never matched vs HQ)" || bad "story HQ fallback not prefix-guarded"
# set -e/pipefail safety: no `set -e` (sweep tolerates per-bead failures) but
# the close path guards its mutation with `|| { err ...; continue; }`.
grep -q 'close failed for' "$JANITOR" && ok "close failure is non-fatal (continue)" || bad "close failure not guarded"
# ga-gosfs: story:done reconciliation sweep wiring.
grep -q 'janitor_story_decide()' "$JANITOR" && ok "defines janitor_story_decide"     || bad "missing janitor_story_decide def"
grep -q 'scan_commit_subject_for_bead()' "$JANITOR" && ok "defines strict subject scanner" || bad "missing scan_commit_subject_for_bead def"
# The story sweep MUST use the strict subject scanner (not the body scanner) for
# signal A — guards against the ga-r471/wa-qggy incidental-body-mention class.
grep -q 'scan_commit_subject_for_bead "\$RGITDIR" "\$RCONTAINER" "origin/\$RDEFAULT" "\$SID"' "$JANITOR" \
  && ok "story sweep uses strict subject scan for SID" || bad "story sweep not using strict scanner"
grep -q 'label add "\$SID" "story:done"' "$JANITOR" && ok "story sweep sets story:done" || bad "story:done transition missing"
grep -q 'already-story-done' "$JANITOR"          && ok "story idempotency guard present" || bad "story already-done guard missing"
grep -q 'delivery-owns-it' "$JANITOR"            && ok "delivery-active guard present"   || bad "delivery guard missing"
grep -q 'story-in-flight-active-rework' "$JANITOR" && ok "story in-flight guard present" || bad "story in-flight guard missing"
# The story sweep must select OPEN story:approved beads (the stuck-merged shape),
# distinct from the in_progress sweep above.
grep -q 'list --status open --limit 0 --json -l story:approved' "$JANITOR" \
  && ok "story sweep selects open story:approved" || bad "story sweep selector missing"
# ga-<story-close>: durable terminal — story sweep must also remove story:approved and CLOSE
# the bead (not just add story:done label). Absence of close left wa-7nz9l + wa-14w76 in
# Aprovadas for 36h+ even after story:done was added. story-delivery.sh L886 explicitly
# delegates the close to the janitor: "merged-bead-janitor backstops the close".
grep -q 'label remove "\$SID" "story:approved"' "$JANITOR" \
  && ok "story sweep removes story:approved (exits Aprovadas)" || bad "story:approved removal missing from story sweep"
grep -q 'close "\$SID" -r "\$JCLOSE_MSG"' "$JANITOR" \
  && ok "story sweep closes bead with delivery close_reason" || bad "story sweep missing close (bead stays open = Aprovadas inflation)"
# Orphan-close backstop: beads that already have story:done but are still open (prior janitor
# pass added the label but missed the close) must also be driven to the durable terminal.
grep -q 'ORPHAN-CLOSED' "$JANITOR" \
  && ok "orphan-close backstop present (already-story-done + open → close)" || bad "orphan-close backstop missing"
grep -q "S_REASON.*already-story-done.*S_EPIC.*0\|already-story-done.*S_EPIC" "$JANITOR" \
  && ok "orphan-close guards epic exclusion" || bad "orphan-close missing epic guard"
# plist drift.
grep -q 'com.gascity.merged-bead-janitor' "$PLIST" && ok "plist Label correct"        || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"        && ok "plist uses StartInterval"    || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"     && ok "plist RunAtLoad=true"        || bad "plist missing RunAtLoad"

# ── 7. Signal A tightening: body-only mention must NOT close; scoped subject MUST ──
# Regression scenario for the wa-oxkg false-positive (2026-06-22):
#   commit 2adc87e3f had subject fix(pilot): … and mentioned "wa-oxkg" only in the
#   BODY (incident description). The original scan_commit_for_bead (body-wide) matched
#   it and falsely closed wa-oxkg. The fix: Signal A now uses scan_commit_subject_for_bead
#   which requires the bead id to be the conventional-commit SCOPE in the SUBJECT line.
echo "── 7. Signal A tightening: body-mention → KEEP; subject-scoped → CLOSE ──"
# Build a fresh repo with two commits that model the wa-oxkg incident:
#   C_INCIDENT: unrelated fix, body MENTIONS the bead id — must NOT trigger close.
#   C_DELIVERY: scoped feat(<id>): …  — MUST trigger close.
T7="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t7)"
trap 'rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R7="$T7/repo7"
git init -q -b main "$R7"
# Baseline commit.
( cd "$R7" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# Incident commit: subject is about pilot, body mentions tt-oxkg as context only.
# This models fix(pilot): … whose body says "a tt-oxkg dispatch surfaced mid-conversation".
( cd "$R7" && echo pilot > pilot.txt && git add pilot.txt && \
  git commit -q -m "fix(pilot): never dispatch into a human-attached crew" \
               -m "TWO dispatch-protection fixes from an incident where a tt-oxkg dispatch surfaced mid-conversation in peter-wa's session while Athos was working WITH peter." )
INCIDENT_SHA=$(git -C "$R7" rev-parse HEAD)
# Delivery commit: subject IS scoped to tt-oxkg — this is the genuine delivery.
( cd "$R7" && echo delivery > delivery.txt && git add delivery.txt && \
  git commit -q -m "feat(tt-oxkg): implement whatsapp automation component" )
DELIVERY_SHA=$(git -C "$R7" rev-parse HEAD)

# Assertion A: strict subject scan must NOT match the incident commit for tt-oxkg
#   (id appears only in body — unrelated commit). This is the wa-oxkg false-positive class.
rc1 scan_commit_subject_for_bead "$R7" 0 "$INCIDENT_SHA" "tt-oxkg"   # body-only — must NOT close

# Assertion B: strict subject scan MUST match the delivery commit for tt-oxkg
#   (id is the conventional-commit scope in the subject line — genuine delivery).
rc0 scan_commit_subject_for_bead "$R7" 0 "main" "tt-oxkg"   # subject-scoped — MUST close
GOTT=$(scan_commit_subject_for_bead "$R7" 0 "main" "tt-oxkg" 2>/dev/null || true)
WANT_SHA=$(git -C "$R7" rev-parse --short=9 "$DELIVERY_SHA")
if [ "${GOTT:0:9}" = "$WANT_SHA" ]; then
  ok "strict scan returns DELIVERY sha for tt-oxkg (${GOTT:0:9}), not incident sha"
else
  bad "strict scan returned wrong sha for tt-oxkg: got [${GOTT:0:9}], want [$WANT_SHA]"
fi

# Assertion C: the LOOSE body scan WOULD match (shows why strict is needed and
#   why the old code was broken — this assertion validates the test setup).
rc0 scan_commit_for_bead "$R7" 0 "main" "tt-oxkg"   # body scan finds incident mention (loose)

# Assertion D: a different bead id mentioned only in the incident commit body is
#   also rejected by the strict scan (cross-contamination guard).
( cd "$R7" && echo extra > extra.txt && git add extra.txt && \
  git commit -q -m "chore(housekeeping): tidy up" \
               -m "see also: tt-other bead that was incidentally referenced here" )
rc1 scan_commit_subject_for_bead "$R7" 0 "main" "tt-other"   # body-only in chore body → keep

# Assertion E: signal C (branch ancestor) still works alongside the tightened signal A —
#   a crew/<rig>/<id> branch that is merged qualifies via branch_merged independent of
#   whether any commit subject is scoped to the bead. This ensures the tightened signal A
#   does not blind us to real merges that lack a scoped-subject commit.
git -C "$R7" checkout -q -b "crew/mila/tt-oxkg" HEAD~2   # points at base+incident (pre-delivery)
git -C "$R7" checkout -q main
rc0 branch_merged "$R7" 0 "crew/mila/tt-oxkg" "main"   # crew branch IS ancestor of main → signal C fires

# ── 7b. wa-iy9s8 REGRESSION: trailing-context SUBJECT paren must NOT close (ga-wisp-ld35wuw) ──
# The wa-iy9s8 false-close (2026-07-01) was NOT a body mention — the id was in the SUBJECT, but
# as a TRAILING context paren "(ga-4aree/wa-iy9s8)" of a fix(pilot): framework commit in HQ. The
# then-current scan_commit_subject_for_bead token-bounded the WHOLE subject → it matched and the
# in_progress sweep auto-closed the P1 bug. The fix requires the id to be the SUBJECT SCOPE
# (header before the first colon). This section builds the exact shape in a real repo.
echo "── 7b. trailing-context subject paren (wa-iy9s8 shape) → KEEP; scoped → CLOSE ──"
T7B="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t7b)"
trap 'rm -rf "$T7B" 2>/dev/null || true; rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R7B="$T7B/repo7b"
git init -q -b main "$R7B"
( cd "$R7B" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# CONTEXT commit — models 286cb29c7-HQ: fix(pilot): … with the rig bead-id in a TRAILING paren.
( cd "$R7B" && echo pilot > pilot.txt && git add pilot.txt && \
  git commit -q -m "fix(pilot): rig-native scan no longer excludes gate:needs-fix — rig re-fix bugs dispatch (ga-4aree/tt-iy9s8)" )
CTX_SHA=$(git -C "$R7B" rev-parse HEAD)
# DELIVERY commit — models d0219063-WA: the genuine fix(tt-iy9s8): implementing commit.
( cd "$R7B" && echo deliver > deliver.txt && git add deliver.txt && \
  git commit -q -m "fix(tt-iy9s8): auto-deploy viewer/ to S3 on merge — done != deployed" )
DLV_SHA=$(git -C "$R7B" rev-parse --short=9 HEAD)
# STRICT scanner: the trailing-context paren commit must NOT be treated as delivery …
rc1 scan_commit_subject_for_bead "$R7B" 0 "$CTX_SHA" "tt-iy9s8"   # trailing "(…/tt-iy9s8)" → KEEP (the bug)
# … but the genuine fix(tt-iy9s8): scope commit MUST be, and returns ITS sha (not the context one).
rc0 scan_commit_subject_for_bead "$R7B" 0 "main" "tt-iy9s8"
GOTB=$(scan_commit_subject_for_bead "$R7B" 0 "main" "tt-iy9s8" 2>/dev/null || true)
if [ "${GOTB:0:9}" = "$DLV_SHA" ]; then ok "strict scan returns DELIVERY sha (${GOTB:0:9}), not the context commit"; else bad "strict scan wrong sha: got [${GOTB:0:9}] want [$DLV_SHA]"; fi
# The OLD loose behaviour (token-bounded WHOLE subject) WOULD have matched the context commit —
# this asserts the test setup reproduces the real false-positive that the fix removes.
ctx_subj=$(git -C "$R7B" log -1 --format='%s' "$CTX_SHA")
rc0 token_bounded "tt-iy9s8" "$ctx_subj"                          # loose whole-subject match (why the fix was needed)


# ── 8. story:done + close: subject-scoped commit in main → DONE verdict; body-only → KEEP ──
# Regression scenario for wa-7nz9l / wa-14w76 (2026-06-26):
#   Beads had fix(wa-7nz9l): / fix(wa-14w76): commits in origin/main.
#   janitor_story_decide correctly returned "done:commit-in-origin-main" — the pure
#   function was fine. The sweep ACTION then added story:done label but did NOT close
#   the bead or remove story:approved → beads stayed open + story:approved in Aprovadas
#   for 36h+ until Mayor fixed manually. Fix: sweep now does story:done + remove
#   story:approved + close (mirrors story-delivery ga-i53ua).
#   These tests confirm:
#   (A) subject-scoped commit (genuine delivery) → janitor_story_decide returns "done"
#   (B) body-only mention (incidental) → janitor_story_decide returns "keep"
#   (C) already-story-done bead (open, prior pass) → janitor_story_decide still
#       returns "keep:already-story-done" (pure fn unchanged); orphan-close fires in sweep
echo "── 8. story:done scenario: subject-scoped in main → done; body-only → keep; already-done → keep ──"

# (A) no open-marker, no rework, sig_commit=1 → should be done
eq "wa-7nz9l shape: sig_commit + no guards → done" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 0 0)" \
   "done:commit-in-origin-main"

# (B) no merge evidence at all → keep
eq "body-only mention (not in subject) → keep:no-merge-evidence" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0)" \
   "keep:no-merge-evidence"

# (C) already has story:done (S_DONE=1) even with all sig_* set → "keep:already-story-done"
#     The sweep detects this and fires orphan-close (covered by drift-guard above).
eq "already-story-done beats merge signals → keep (orphan-close covers terminal)" \
   "$(janitor_story_decide 0 0 1 0 0 0 1 1 1)" \
   "keep:already-story-done"

# (D) SECURITY: has story:done + an ACTIVE open gate-marker → active-open-gate-marker WINS
#     (NOT already-story-done). A stale story:done label must NOT let the orphan-close backstop
#     close a bead that is back under active review. Active-work guards precede already_done.
eq "open-marker beats stale already-done (no false-close)" \
   "$(janitor_story_decide 0 1 1 0 0 0 0 0 0)" \
   "keep:active-open-gate-marker"
eq "in-flight beats stale already-done (rework not false-closed)" \
   "$(janitor_story_decide 0 0 1 1 0 0 0 0 0)" \
   "keep:story-in-flight-active-rework"

# (E) in-flight guard must NOT be bypassed by story:done when NOT already done
#     (a bead currently being built: in-flight=1, done=0, sig_commit=1 — mid-gate).
eq "in-flight active (not yet done): in-flight guard wins over commit signal" \
   "$(janitor_story_decide 0 0 0 1 0 0 1 0 0)" \
   "keep:story-in-flight-active-rework"

# ── 9. Drift-guard: ga-hcj4 stranded open+story:in-flight sweep ─────────────
# Pilot's "fix bug X" sling-wrapper convention leaves the underlying bug/task
# bead (or a story whose gate-PASS handoff never stripped the label) stuck
# status=open + story:in-flight FOREVER — it is never itself in_progress and
# never carries story:approved, so it fell into NEITHER sweep above no matter
# how long its own scoped commit sat merged in origin/main (ga-ap7od: confirmed
# merged 1h48m past a healthy 15min sweep cadence, invisible because the
# WRAPPER, not the bead, was the in_progress row). This bucket reuses
# janitor_decide UNCHANGED (already exhaustively covered by §1 above) — these
# assertions confirm the LIVE script wires a THIRD candidate query into that
# same pure decision, with the same false-close defenses (strict subject-scope,
# repo-scoping, branch self-guard) as the in_progress sweep, not a fresh or
# looser decision path.
echo "── 9. Drift-guard: ga-hcj4 stranded open+story:in-flight sweep ──"
grep -qF 'list --status open --limit 0 --json -l story:in-flight' "$JANITOR" \
  && ok "queries open+story:in-flight beads (third bucket), unbounded (--limit 0, ga-26jevvc)" || bad "open+story:in-flight query missing or lost --limit 0"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH"' "$JANITOR" \
  && ok "in-flight bucket reuses janitor_decide unchanged (no parallel decision fn)" || bad "in-flight bucket does not call janitor_decide"
grep -qF 'scan_commit_subject_for_bead "$RGITDIR" "$RCONTAINER" "origin/$RDEFAULT" "$FID"' "$JANITOR" \
  && ok "in-flight signal A uses the STRICT subject scanner (not the loose one)" || bad "in-flight bucket not using strict subject scanner"
grep -qF 'sha=$(scan_commit_subject_for_bead "$HQ_GITDIR" "$HQ_CONTAINER" "origin/$HQ_DEFAULT" "$FID")' "$JANITOR" \
  && ok "in-flight signal A falls back to HQ mirror scan" || bad "in-flight HQ mirror fallback missing"
grep -qF '[ "${FID%%-*}" != "$RPREFIX" ]' "$JANITOR" \
  && ok "in-flight commit signal is rig-scoped (HQ fallback only for foreign ids)" || bad "in-flight repo-scoping guard missing"
grep -qF 'case "$br" in */"$FID") : ;; *) continue ;; esac' "$JANITOR" \
  && ok "in-flight branch signal keeps the final-path-segment self-guard" || bad "in-flight branch self-guard missing"
grep -qF 'CLOSED-INFLIGHT' "$JANITOR" && ok "in-flight close action logs CLOSED-INFLIGHT" || bad "in-flight close logging missing"
grep -qF 'label remove "$FID" "story:in-flight"' "$JANITOR" \
  && ok "in-flight close drops story:in-flight (mirrors in_progress sweep)" || bad "in-flight story:in-flight removal missing"
grep -qF 'INFLIGHT_CLOSED_COUNT=$((INFLIGHT_CLOSED_COUNT+1))' "$JANITOR" \
  && ok "in-flight closes counted" || bad "in-flight close counter missing"
grep -qF 'INFLIGHT_CLOSED_COUNT" -gt 0' "$JANITOR" && ok "in-flight closes surfaced via notify_athos" || bad "in-flight notify wiring missing"
grep -qF 'WOULD-CLOSE-INFLIGHT' "$JANITOR" && ok "in-flight bucket honors DRY_RUN" || bad "in-flight dry-run path missing"

# ── 10. Drift-guard: ga-2zp4h joint/split-bead stale-comment guard ──────────
# wa-d3136 false-close: Signal A matched a LEGITIMATE subject-scoped commit that was
# actually the delivery of a DIFFERENT (split-off sibling) bead (wa-eda28) — the bead
# was reassigned to a second owner via a comment a full day AFTER that commit landed,
# and his half was never built, yet the janitor closed the shared parent anyway. The
# guard: a bead comment postdating the matched commit suppresses signal A ALONE. It
# must be wired into ALL THREE call sites that use janitor_decide/janitor_story_decide
# (in_progress, ga-hcj4 stranded-wrapper, story:approved) — missing even one leaves
# that bucket vulnerable to the exact same false-close.
echo "── 10. Drift-guard: ga-2zp4h joint/split-bead stale-comment guard ──"
grep -q 'commit_epoch()' "$JANITOR" && ok "defines commit_epoch" || bad "missing commit_epoch def"
grep -q 'commit_evidence_stale()' "$JANITOR" && ok "defines commit_evidence_stale" || bad "missing commit_evidence_stale def"
grep -q 'comments_for_bead()' "$JANITOR" && ok "defines comments_for_bead" || bad "missing comments_for_bead def"
grep -qF 'sig_commit_stale="${6:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional sig_commit_stale (backward-compatible default)" || bad "janitor_decide missing sig_commit_stale param"
grep -qF 'sig_commit_stale="${10:-0}"' "$JANITOR" \
  && ok "janitor_story_decide accepts optional sig_commit_stale (backward-compatible default)" || bad "janitor_story_decide missing sig_commit_stale param"
grep -qF 'commit-evidence-superseded-by-newer-comment' "$JANITOR" \
  && ok "stale-suppression keep reason present" || bad "stale-suppression keep reason missing"
# All THREE call sites must thread SIG_COMMIT_STALE into janitor_decide/janitor_story_decide.
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE"' "$JANITOR" \
  && ok "in_progress sweep threads sig_commit_stale into janitor_decide" || bad "in_progress sweep not threading sig_commit_stale"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads sig_commit_stale into janitor_decide" || bad "ga-hcj4 sweep not threading sig_commit_stale"
grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE"' "$JANITOR" \
  && ok "story sweep threads sig_commit_stale into janitor_story_decide" || bad "story sweep not threading sig_commit_stale"
# Signal C must gate on a TRUSTED flag (not raw SIG_COMMIT) at all three call sites, so a
# stale signal A never blinds the sweep to an independent, genuinely-merged crew branch.
grep -qF '[ "$SIG_COMMIT_TRUSTED" = "0" ] && [ "$SIG_MARKER" = "0" ]' "$JANITOR" \
  && ok "in_progress signal C gates on SIG_COMMIT_TRUSTED (not raw SIG_COMMIT)" || bad "in_progress signal C not using TRUSTED gate"
grep -qF '[ "$F_SIGCOMMIT_TRUSTED" = "0" ] && [ "$F_SIGMARKER" = "0" ]' "$JANITOR" \
  && ok "ga-hcj4 signal C gates on F_SIGCOMMIT_TRUSTED (not raw F_SIGCOMMIT)" || bad "ga-hcj4 signal C not using TRUSTED gate"
grep -qF 'if [ "$S_SIGCOMMIT_TRUSTED" = "0" ] && [ "$S_SIGMK" = "0" ]' "$JANITOR" \
  && ok "story signal C gates on S_SIGCOMMIT_TRUSTED (not raw S_SIGCOMMIT)" || bad "story signal C not using TRUSTED gate"
# comments_for_bead must be fetched at all three call sites (once per BID/FID/SID).
grep -qF 'comments_for_bead "$RPATH" "$BID"' "$JANITOR" && ok "in_progress sweep fetches bead comments" || bad "in_progress sweep missing comments_for_bead call"
grep -qF 'comments_for_bead "$RPATH" "$FID"' "$JANITOR" && ok "ga-hcj4 sweep fetches bead comments" || bad "ga-hcj4 sweep missing comments_for_bead call"
grep -qF 'comments_for_bead "$RPATH" "$SID"' "$JANITOR" && ok "story sweep fetches bead comments" || bad "story sweep missing comments_for_bead call"
# ── 11. ga-vokwv: sling-bead-name fallback (sling_beads_from_show / sling_signals_for_id) ──
# The ga-hcj4 sweep's three signals key strictly off the stranded bead's OWN id.
# Pilot's "fix bug X" dispatch convention creates a ROTATING sling-task WRAPPER
# bead per (re)dispatch attempt; if a fix branch/commit is named after the
# WRAPPER instead of the PARENT bug (the ga-0jcit incident this bead fixes),
# the sweep never finds it — confirmed live: 5+ post-merge sweeps all logged
# "no-merge-evidence" for a bead whose fix had already landed. This bucket
# hardens the sweep: when FID's own id carries no evidence, it re-probes every
# sling-task wrapper id ever dispatched for FID (via metadata + comment
# history) with the SAME three signals before giving up.
echo "── 11. ga-vokwv: sling-bead-name fallback ──"

echo "  -- 11a. sling_beads_from_show (pure JSON, no live Dolt) --"
# Real shape captured live off ga-vokwv itself (2026-07-26): TWO dispatch
# attempts, each leaving a "Sling task bead: <id>" comment; metadata carries
# only the MOST RECENT wrapper. Both must surface, deduplicated — an earlier
# wrapper can be the one that actually shipped (ga-0jcit's real fix landed
# under its FIRST wrapper ga-w4ah2, while later re-dispatches carried nothing).
SHOW_MULTI='{
  "metadata": {"pilot.dispatched_at": 1785070184, "pilot.sling_bead": "ga-803hq"},
  "comments": [
    {"text": "Pilot dispatched builder gastown.dog at 2026-07-26T11:42:20Z.\nSling task bead: ga-2rp0x\nBuilder doctrine: fix bug -> gate-done -> autonomous gate+delivery.", "created_at": "2026-07-26T11:42:28Z"},
    {"text": "inflight-reclaim-guard: reclaimed - no live builder and no recent branch progress for 32min.", "created_at": "2026-07-26T12:23:47Z"},
    {"text": "Pilot dispatched builder gastown.dog at 2026-07-26T12:49:37Z.\nSling task bead: ga-803hq\nBuilder doctrine: fix bug -> gate-done -> autonomous gate+delivery.", "created_at": "2026-07-26T12:49:47Z"}
  ]
}'
GOT_SLING=$(sling_beads_from_show "$SHOW_MULTI" | sort | tr '\n' ',')
eq "extracts both wrapper ids across dispatch history, deduplicated" "$GOT_SLING" "ga-2rp0x,ga-803hq,"

# `bd show` sometimes wraps the object in a single-element array — must normalize identically.
SHOW_MULTI_ARR="[$SHOW_MULTI]"
GOT_SLING_ARR=$(sling_beads_from_show "$SHOW_MULTI_ARR" | sort | tr '\n' ',')
eq "array-wrapped bd show output normalizes the same as bare object" "$GOT_SLING_ARR" "$GOT_SLING"

# No metadata, no matching comments → nothing found (a never-redispatched bead).
SHOW_NONE='{"metadata": {}, "comments": [{"text": "just a status update, no sling reference here", "created_at": "2026-07-26T00:00:00Z"}]}'
eq "no metadata + no matching comments → empty" "$(sling_beads_from_show "$SHOW_NONE")" ""

# Missing comments field entirely (bd show WITHOUT --include-comments) → metadata-only, no crash.
SHOW_META_ONLY='{"metadata": {"pilot.sling_bead": "ga-onlyone"}}'
eq "metadata-only (no comments key) → the one wrapper id" "$(sling_beads_from_show "$SHOW_META_ONLY")" "ga-onlyone"

# Malformed comment (id char class doesn't match, e.g. non-lowercase) must NOT
# crash the extraction of its siblings — jq's capture() no-ops on a non-match,
# it does not raise (unlike the (?P<id>...) syntax error this regex avoids).
SHOW_MIXED='{"metadata": {}, "comments": [{"text": "Sling task bead: NOTLOWER", "created_at": "x"}, {"text": "Sling task bead: ga-good1", "created_at": "y"}]}'
eq "malformed sibling comment does not block a valid match" "$(sling_beads_from_show "$SHOW_MIXED")" "ga-good1"

echo "  -- 11b. sling_signals_for_id (real git + synthetic marker JSON) --"
T10="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t10)"
trap 'rm -rf "$T10" 2>/dev/null || true; rm -rf "$T7B" 2>/dev/null || true; rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R10="$T10/repo10"
git init -q -b main "$R10"
( cd "$R10" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# The genuine fix, subject-scoped to the SLING WRAPPER id (the ga-0jcit shape:
# the branch/commit names the wrapper, not the parent).
( cd "$R10" && echo fix > fix.txt && git add fix.txt && git commit -q -m "fix(tt-wrap1): the real fix, named after the wrapper" )
SLING_FIX_SHA=$(git -C "$R10" rev-parse --short=9 HEAD)
# sling_signals_for_id operates on FETCHED origin/* refs (the live sweep never
# reads local branches) — stand up remote-tracking refs without a real remote.
git -C "$R10" update-ref refs/remotes/origin/main refs/heads/main

M_OPEN_MK='[{"status":"open","labels":["gate-status:queued"]}]'
M_PASSED_MK='[{"status":"closed","labels":["gate-status:passed"]}]'

# Commit signal: the wrapper id IS the subject scope of a commit in main.
eq "subject-scoped commit → sig_commit=1 with sha evidence" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-wrap1" "$M_EMPTY")" \
   "1 0 0 ${SLING_FIX_SHA} -"

# No evidence at all for an unrelated id.
eq "no evidence → all-zero, no evidence strings" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-nothing" "$M_EMPTY")" \
   "0 0 0 - -"

# OPEN marker suppresses ALL signals, even though commit evidence exists for
# this SAME id — still-active work on a candidate must never read as evidence
# either way (mirrors has_open_marker's role in the direct FID path).
eq "open marker on the CANDIDATE suppresses its own commit evidence" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-wrap1" "$M_OPEN_MK")" \
   "0 0 0 - -"

# Terminal passed marker alone is sufficient — no git evidence required.
eq "terminal passed marker → sig_marker=1, no git lookup needed" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-passed-only" "$M_PASSED_MK")" \
   "0 1 0 - -"

# Branch-ancestor signal via the crew/*/<id> convention fallback, same
# final-path-segment self-guard as the in_progress/ga-hcj4 sweeps.
git -C "$R10" branch crew/x/tt-branchy main
git -C "$R10" update-ref refs/remotes/origin/crew/x/tt-branchy refs/heads/crew/x/tt-branchy
eq "branch-ancestor signal fires via crew/*/<id> convention" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-branchy" "$M_EMPTY")" \
   "0 0 1 - crew/x/tt-branchy"

# Self-guard: a branch whose FINAL segment != the candidate id must never
# match (mirrors the in_progress/ga-hcj4 sweeps' */"$FID" guard — a
# differently-named branch that merely CONTAINS the id string must not count).
git -C "$R10" branch "crew/x/tt-branchy-longer" main
git -C "$R10" update-ref refs/remotes/origin/crew/x/tt-branchy-longer refs/heads/crew/x/tt-branchy-longer
eq "branch self-guard rejects a final-segment mismatch" \
   "$(sling_signals_for_id "$R10" 0 "main" "zz" "$R10" 0 "main" "tt-branchy-lon" "$M_EMPTY")" \
   "0 0 0 - -"

echo "  -- 11b2. sling_fallback_eligible_reason (ga-v8ui5 gate-feedback follow-up) --"
# GATE-FEEDBACK (2026-07-30, gate_run=ga-wisp-617q8ra): janitor_decide's new
# keep:superseded-marker-needs-merge-evidence reason (§12 below) is a SECOND
# "FID's own signals came up empty" bucket, distinct from the original
# no-merge-evidence string. Before this predicate existed, the fallback gate
# matched no-merge-evidence ONLY — so a bead superseded under its current
# wrapper, whose real merge lived under a sibling wrapper id, silently never
# got the cross-check attempted (verdict stayed "keep", indistinguishable in
# the log from "checked and found nothing"). This exercises the actual
# predicate the sweep calls, not just a grep for its source text — the gap
# the gate feedback called out was exactly that no test exercised the
# end-to-end F_REASON branch.
eq "no-merge-evidence is fallback-eligible" \
   "$(sling_fallback_eligible_reason "no-merge-evidence")" "1"
eq "superseded-marker-needs-merge-evidence is fallback-eligible (the fix)" \
   "$(sling_fallback_eligible_reason "superseded-marker-needs-merge-evidence")" "1"
# Every guard/suppression reason a "keep" verdict can carry must stay
# ineligible — the fallback may NEVER second-guess an epic, an actively-gated
# bead, or a deliberately-suppressed stale-comment commit signal.
for guard_reason in epic-parent-never-autoclosed active-open-gate-marker \
                    commit-evidence-superseded-by-newer-comment \
                    story-in-flight-active-rework live-builder-assignee \
                    delivery-owns-it already-story-done; do
  eq "guard reason '$guard_reason' stays fallback-ineligible" \
     "$(sling_fallback_eligible_reason "$guard_reason")" "0"
done

echo "  -- 11c. drift-guard: live wiring in the ga-hcj4 sweep --"
grep -q 'sling_beads_from_show()' "$JANITOR"  && ok "defines sling_beads_from_show"  || bad "missing sling_beads_from_show def"
grep -q 'sling_signals_for_id()' "$JANITOR"   && ok "defines sling_signals_for_id"   || bad "missing sling_signals_for_id def"
grep -qF 'capture("Sling task bead: (?<id>[a-z][a-z0-9-]+)")' "$JANITOR" \
  && ok "uses the WORKING jq named-group syntax (?<id>...), not the P-form quality-gate-guard.sh uses" \
  || bad "sling id capture regex missing or reverted to the broken (?P<id>...) form"
grep -qF 'if [ "$F_VERDICT" = "keep" ] && [ "$(sling_fallback_eligible_reason "$F_REASON")" = "1" ]; then' "$JANITOR" \
  && ok "fallback gated via sling_fallback_eligible_reason (never overrides epic/open-marker keeps)" \
  || bad "fallback gating condition missing, loosened, or reverted to the single-string no-merge-evidence check"
grep -qF 'sling_fallback_eligible_reason()' "$JANITOR" \
  && ok "defines sling_fallback_eligible_reason" \
  || bad "missing sling_fallback_eligible_reason def"
grep -qF '[ "$F_SLING_ID" = "$FID" ] && continue' "$JANITOR" \
  && ok "skips self-referential sling id (rig-native beads already scanned as FID itself)" \
  || bad "sling self-reference skip missing"
grep -qF 'bd -C "$RPATH" show "$FID" --json --include-comments' "$JANITOR" \
  && ok "fetches comment history (not just metadata) to resolve sling wrapper ids" \
  || bad "--include-comments show call missing"
grep -qF 'F_VERDICT="close"' "$JANITOR" && grep -qF 'F_REASON="sling-bead-evidence"' "$JANITOR" \
  && ok "sling evidence flips the verdict to close with a distinguishable reason" \
  || bad "sling-bead-evidence verdict flip missing"
grep -qF '[ -n "$F_SLING_EVID" ] && F_EVID="$F_EVID $F_SLING_EVID"' "$JANITOR" \
  && ok "sling evidence is surfaced in the close comment/log line" \
  || bad "sling evidence not appended to F_EVID"

# ── 12. Drift-guard: ga-v8ui5 superseded is NOT a merge signal ──────────────
# gate-status:superseded means the branch was REPLACED (rebase/recreate — the
# documented procedure when the gate rejects a stale base) — the OPPOSITE of
# passed. Treating it as terminal-delivered on the marker signal ALONE let the
# janitor assert delivery for discarded work (wa-c3qsr: closed "work merged to
# origin/main" while the code was NOT in origin/main — 0 content hits, branch
# not an ancestor, the page still 404). Must be wired into ALL THREE call
# sites, exactly like the ga-2zp4h stale-comment guard above — missing even
# one leaves that bucket vulnerable to the same false-close.
echo "── 12. Drift-guard: ga-v8ui5 superseded-not-merged ──"
grep -q 'has_terminal_superseded_marker()' "$JANITOR" \
  && ok "defines has_terminal_superseded_marker (distinguishable, non-closing signal)" \
  || bad "missing has_terminal_superseded_marker def"
grep -qF 'sig_marker_superseded="${7:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional sig_marker_superseded (backward-compatible default)" \
  || bad "janitor_decide missing sig_marker_superseded param"
grep -qF 'sig_marker_superseded="${11:-0}"' "$JANITOR" \
  && ok "janitor_story_decide accepts optional sig_marker_superseded (backward-compatible default)" \
  || bad "janitor_story_decide missing sig_marker_superseded param"
grep -qF 'keep:superseded-marker-needs-merge-evidence' "$JANITOR" \
  && ok "superseded-only keep reason is distinguishable from generic no-merge-evidence" \
  || bad "superseded-marker-needs-merge-evidence reason missing"
# All THREE call sites must compute the signal AND thread it into the decision fns.
grep -qF 'SIG_MK_SUPER=0; has_terminal_superseded_marker "$MK" && SIG_MK_SUPER=1' "$JANITOR" \
  && ok "in_progress sweep computes SIG_MK_SUPER from has_terminal_superseded_marker" \
  || bad "in_progress sweep not computing SIG_MK_SUPER"
grep -qF 'F_SIGMK_SUPER=0; has_terminal_superseded_marker "$FMK" && F_SIGMK_SUPER=1' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_SIGMK_SUPER" \
  || bad "ga-hcj4 sweep not computing F_SIGMK_SUPER"
grep -qF 'S_SIGMK_SUPER=0; has_terminal_superseded_marker "$SMK" && S_SIGMK_SUPER=1' "$JANITOR" \
  && ok "story sweep computes S_SIGMK_SUPER" \
  || bad "story sweep not computing S_SIGMK_SUPER"
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE" "$SIG_MK_SUPER"' "$JANITOR" \
  && ok "in_progress sweep threads sig_marker_superseded into janitor_decide" \
  || bad "in_progress sweep not threading sig_marker_superseded"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE" "$F_SIGMK_SUPER"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads sig_marker_superseded into janitor_decide" \
  || bad "ga-hcj4 sweep not threading sig_marker_superseded"
grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE" "$S_SIGMK_SUPER"' "$JANITOR" \
  && ok "story sweep threads sig_marker_superseded into janitor_story_decide" \
  || bad "story sweep not threading sig_marker_superseded"

# ── 13. crew_branches_for_bead + unmerged_crew_branches_for_bead (wa-1jk89) ──
# The measured real-world shape: wa-a7e98 had a PRIMARY branch (merged) and a
# follow-up "-fix" branch (unmerged) — the janitor closed the bead anyway
# because ITS signal (a terminal gate marker) only ever looked at ONE branch.
echo "── 13. crew_branches_for_bead + unmerged_crew_branches_for_bead (wa-1jk89) ──"
T11="$(mktemp -d 2>/dev/null || mktemp -d -t janitor-t11)"
trap 'rm -rf "$T11" 2>/dev/null || true; rm -rf "$T10" 2>/dev/null || true; rm -rf "$T7B" 2>/dev/null || true; rm -rf "$T7" 2>/dev/null || true; rm -rf "$T" 2>/dev/null || true' EXIT
R11="$T11/repo11"
git init -q -b main "$R11"
( cd "$R11" && echo base > base.txt && git add base.txt && git commit -q -m "base commit" )
# unmerged_crew_branches_for_bead operates on FETCHED origin/* refs (the live
# sweep never reads local branches) — stand up the remote-tracking main ref
# without a real remote, same idiom §11b already uses for R10.
git -C "$R11" update-ref refs/remotes/origin/main refs/heads/main

# Primary branch for tt-multi: identical to main at creation time → merged.
git -C "$R11" branch crew/x/tt-multi main
git -C "$R11" update-ref refs/remotes/origin/crew/x/tt-multi refs/heads/crew/x/tt-multi

# Follow-up "-fix" branch for the SAME bead: a real commit not yet in main.
git -C "$R11" checkout -q -b crew/y/tt-multi-fix main
( cd "$R11" && echo fixup > fixup.txt && git add fixup.txt && git commit -q -m "fix(tt-multi): follow-up not yet merged" )
git -C "$R11" update-ref refs/remotes/origin/crew/y/tt-multi-fix refs/heads/crew/y/tt-multi-fix
git -C "$R11" checkout -q main

# A DIFFERENT, similarly-prefixed bead's branch must never be mistaken for a
# tt-multi follow-up — the exact false-match this helper must reject: no
# hyphen boundary after the shared prefix (tt-multi9 vs tt-multi-fix).
git -C "$R11" branch crew/z/tt-multi9 main
git -C "$R11" update-ref refs/remotes/origin/crew/z/tt-multi9 refs/heads/crew/z/tt-multi9

echo "  -- crew_branches_for_bead --"
GOT_CANDS=$(crew_branches_for_bead "$R11" 0 "tt-multi" | sort | tr '\n' ',')
eq "finds primary + -fix follow-up, excludes the tt-multi9 near-miss" \
   "$GOT_CANDS" "crew/x/tt-multi,crew/y/tt-multi-fix,"
eq "unrelated id → no candidates at all" \
   "$(crew_branches_for_bead "$R11" 0 "tt-nothing")" ""

echo "  -- unmerged_crew_branches_for_bead (the wa-1jk89 AC) --"
# Both branches present, one pending → the AC's first half: "uma branch mergeada
# E outra pendente NÃO é fechado" — this must report the pending one.
eq "primary merged + follow-up pending → follow-up reported pending" \
   "$(unmerged_crew_branches_for_bead "$R11" 0 "main" "tt-multi")" "crew/y/tt-multi-fix"

# Merge the follow-up into main → the AC's second half: "todas mergeadas continua
# sendo fechado" — once every candidate lands, nothing blocks the close.
git -C "$R11" merge -q --no-ff -m "merge follow-up" crew/y/tt-multi-fix
git -C "$R11" update-ref refs/remotes/origin/main refs/heads/main
eq "once the follow-up merges too, nothing is pending (close may proceed)" \
   "$(unmerged_crew_branches_for_bead "$R11" 0 "main" "tt-multi")" ""

# A bead with NO crew branches at all (delivered purely by commit/marker signal)
# must never be blocked by this veto just for lacking a branch to check.
eq "no candidate branches at all → empty (never blocks a commit/marker-only close)" \
   "$(unmerged_crew_branches_for_bead "$R11" 0 "main" "tt-nobranch")" ""

echo "── 14. Drift-guard: wa-1jk89 pending-crew-branch veto wired into the close path ──"
grep -q 'crew_branches_for_bead()' "$JANITOR" \
  && ok "defines crew_branches_for_bead" \
  || bad "missing crew_branches_for_bead def"
grep -q 'unmerged_crew_branches_for_bead()' "$JANITOR" \
  && ok "defines unmerged_crew_branches_for_bead" \
  || bad "missing unmerged_crew_branches_for_bead def"
grep -qF 'PENDING_BRANCHES=$(unmerged_crew_branches_for_bead "$RGITDIR" "$RCONTAINER" "$RDEFAULT" "$BID")' "$JANITOR" \
  && ok "in_progress close path computes the pending-crew-branch veto before closing" \
  || bad "in_progress close path not computing the pending-crew-branch veto"
grep -qF 'if [ -n "$PENDING_BRANCHES" ]; then' "$JANITOR" \
  && ok "a non-empty pending list is checked before the actual close call" \
  || bad "pending-branch check missing/loosened"
# The veto must run BEFORE the real close call, not after — a textual ordering
# check (the close call's line number must be greater than the veto's).
VETO_LINE=$(grep -n 'PENDING_BRANCHES=\$(unmerged_crew_branches_for_bead' "$JANITOR" | head -1 | cut -d: -f1)
CLOSE_LINE=$(grep -n 'bd -C "\$RPATH" close "\$BID" -r "\$REASON_MSG"' "$JANITOR" | head -1 | cut -d: -f1)
if [ -n "$VETO_LINE" ] && [ -n "$CLOSE_LINE" ] && [ "$VETO_LINE" -lt "$CLOSE_LINE" ] 2>/dev/null; then
  ok "veto check (line $VETO_LINE) precedes the real close call (line $CLOSE_LINE)"
else
  bad "veto check does not precede the real close call (veto=$VETO_LINE close=$CLOSE_LINE)"
fi

# ── 14b. Drift-guard: ga-02nlo — the SAME veto on the story `done` path ─────
# wa-1jk89 (section 14 above) installed the pending-crew-branch veto on the CLOSE
# path only. The story `done` path drives a bead to the very same durable terminal
# (story:done + bd close) and had NO veto — so a bead whose sibling branch was still
# unmerged got closed there instead, and the asymmetry between two paths reaching one
# terminal WAS the bug.
#
# MEASURED (2026-08-07 13:14:13, live log):
#   "DONE wa-uhbqb (whatsapp_automation) — branch-ancestor-of-origin-main
#    [origin/crew/mila/wa-uhbqb ⊑ origin/main]"
#   sweep summary: `closed=0 ... story_done=1`  ⟹ never entered the guarded path.
# Sibling origin/crew/mila/wa-uhbqb-hero (1 commit, tests green, no gate marker) was
# left out of main with its bead CLOSED — nothing left in the system to push it. Same
# day, wa-ylzhs closed on crew/batista/wa-ylzhs and stranded crew/mila/wa-ylzhs-data
# (2 commits): CROSS-AGENT, so not "someone superseded their own work".
echo "── 14b. Drift-guard: ga-02nlo pending-crew-branch veto wired into the story done path ──"
grep -qF 'S_PENDING=$(unmerged_crew_branches_for_bead "$RGITDIR" "$RCONTAINER" "$RDEFAULT" "$SID")' "$JANITOR" \
  && ok "story done path computes the pending-crew-branch veto before finishing" \
  || bad "story done path not computing the pending-crew-branch veto (ga-02nlo regression)"
grep -qF 'if [ -n "$S_PENDING" ]; then' "$JANITOR" \
  && ok "a non-empty story pending list is checked before the done/close call" \
  || bad "story pending-branch check missing/loosened"
# Ordering: the veto must precede the story close, exactly as section 14 asserts for
# the close path. A veto computed AFTER the close would read as guarded and do nothing.
S_VETO_LINE=$(grep -n 'S_PENDING=\$(unmerged_crew_branches_for_bead' "$JANITOR" | head -1 | cut -d: -f1)
S_CLOSE_LINE=$(grep -n 'bd -C "\$RPATH" close "\$SID" -r "\$JCLOSE_MSG"' "$JANITOR" | head -1 | cut -d: -f1)
if [ -n "$S_VETO_LINE" ] && [ -n "$S_CLOSE_LINE" ] && [ "$S_VETO_LINE" -lt "$S_CLOSE_LINE" ] 2>/dev/null; then
  ok "story veto (line $S_VETO_LINE) precedes the story close call (line $S_CLOSE_LINE)"
else
  bad "story veto does not precede the story close (veto=$S_VETO_LINE close=$S_CLOSE_LINE)"
fi
# The veto must also gate the LABEL writes, not just the close: story:approved being
# removed while the sibling is unmerged would strand the bead out of Aprovadas even if
# the close itself were skipped.
S_LABEL_LINE=$(grep -n 'bd -C "\$RPATH" label add "\$SID" "story:done"' "$JANITOR" | head -1 | cut -d: -f1)
if [ -n "$S_VETO_LINE" ] && [ -n "$S_LABEL_LINE" ] && [ "$S_VETO_LINE" -lt "$S_LABEL_LINE" ] 2>/dev/null; then
  ok "story veto (line $S_VETO_LINE) precedes the story:done label write (line $S_LABEL_LINE)"
else
  bad "story veto does not precede the label writes (veto=$S_VETO_LINE label=$S_LABEL_LINE)"
fi
# Both terminal paths must be guarded — count the call sites so adding a THIRD
# terminal path without a veto trips this too.
N_VETO_CALLS=$(grep -c '=\$(unmerged_crew_branches_for_bead' "$JANITOR")
if [ "$N_VETO_CALLS" -ge 2 ] 2>/dev/null; then
  ok "both terminal paths (close + story done) compute the veto ($N_VETO_CALLS call sites)"
else
  bad "only $N_VETO_CALLS veto call site(s) — a terminal path is unguarded again"
fi

# ── 15. Drift-guard: ga-f54ui delivery:partial not a merge signal ───────────
# ga-k2wjn already proved (at gate-PASS time, quality-gate-dispatcher.sh) that a
# delivery:partial bead's body enumerates multiple approved deliverables of which
# only one diff was reviewed. This janitor is a SEPARATE, independent close path
# (periodic sweep, not gate-PASS time) that never consulted the label — a
# delivery:partial bead re-claimed in_progress got silently re-closed the moment
# ANY merge signal fired (live incident: ga-f54ui, Signal B). Must be wired into
# BOTH bug/task-shaped call sites (in_progress sweep + ga-hcj4 stranded-wrapper
# sweep) — the story sweep is deliberately UNTOUCHED: ga-k2wjn's own heuristic
# only ever runs "if IS_STORY != 1" (quality-gate-dispatcher.sh), so a story bead
# never receives the delivery:partial label in the first place — there is
# nothing for janitor_story_decide to consult.
echo "── 15. Drift-guard: ga-f54ui delivery:partial not a merge signal ──"
grep -qF 'is_delivery_partial="${8:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional is_delivery_partial (backward-compatible default)" \
  || bad "janitor_decide missing is_delivery_partial param"
grep -qF 'keep:delivery-partial-unresolved-scope' "$JANITOR" \
  && ok "delivery-partial keep reason is distinguishable from generic no-merge-evidence" \
  || bad "delivery-partial-unresolved-scope reason missing"
# Both bug/task call sites must compute the label read AND thread it into janitor_decide.
grep -qF 'printf '"'"'%s'"'"' "$b" | jq -e '"'"'(.labels // []) | index("delivery:partial")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "in_progress sweep computes IS_DELIV_PARTIAL from the bead's own labels" \
  || bad "in_progress sweep not computing IS_DELIV_PARTIAL"
grep -qF 'printf '"'"'%s'"'"' "$f" | jq -e '"'"'(.labels // []) | index("delivery:partial")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_DELIV_PARTIAL from the bead's own labels" \
  || bad "ga-hcj4 sweep not computing F_DELIV_PARTIAL"
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE" "$SIG_MK_SUPER" "$IS_DELIV_PARTIAL"' "$JANITOR" \
  && ok "in_progress sweep threads is_delivery_partial into janitor_decide" \
  || bad "in_progress sweep not threading is_delivery_partial"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE" "$F_SIGMK_SUPER" "$F_DELIV_PARTIAL"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads is_delivery_partial into janitor_decide" \
  || bad "ga-hcj4 sweep not threading is_delivery_partial"
# Negative check: the story sweep's own janitor_story_decide call must end in
# gate_passed_grace (ga-botvu2 legitimately extended it past sig_marker_stale, which ga-tysvjp
# had extended past sig_commit_docs_only, ga-fbycg — see §18 below) and NOT grow a
# delivery:partial-shaped arg beyond that —
# confirms this fix deliberately left THIS label alone (see header above) rather than
# silently drifting it out of sync with a copy-paste that half-applies. (Was a two-grep
# AND-NOT before ga-fbycg added a real 12th arg, then an exact-tail match ending at
# sig_commit_docs_only before ga-tysvjp added a real 13th arg; only "no
# delivery-partial/daemon-hold-shaped arg" holds across all of these, never "no further
# arg at all".)
if grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE" "$S_SIGMK_SUPER" "$S_SIGCOMMIT_DOCS_ONLY" "$S_SIGMK_STALE" "$S_GRACE")' "$JANITOR"; then
  ok "story sweep's janitor_story_decide call ends at gate_passed_grace (no delivery:partial label ever reaches a story bead)"
else
  bad "story sweep's janitor_story_decide call signature changed unexpectedly — re-check ga-f54ui's story-sweep-exclusion rationale"
fi

# ── 16. Drift-guard: ga-l7n3v delivery:pending-restart not a merge signal ────
# quality-gate-dispatcher.sh's BUG/TASK close path closes the gate MARKER as
# gate-status:passed (terminal) BEFORE deciding whether to close or hold the
# SOURCE bead on a daemon-verification failure — so has_open_marker (the guard
# that already protects a delivery:partial-shaped hold) can never fire for a
# daemon-hold bead: the marker isn't open by the time the hold label lands.
# Must be wired into BOTH bug/task-shaped call sites, same as ga-f54ui — the
# story sweep is deliberately UNTOUCHED: delivery:pending-restart is only ever
# stamped inside quality-gate-dispatcher.sh's `else` branch, reached only when
# IS_STORY != 1, so a story bead never receives it in the first place.
echo "── 16. Drift-guard: ga-l7n3v delivery:pending-restart not a merge signal ──"
grep -qF 'is_daemon_hold="${9:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional is_daemon_hold (backward-compatible default)" \
  || bad "janitor_decide missing is_daemon_hold param"
grep -qF 'keep:daemon-verification-pending-restart' "$JANITOR" \
  && ok "daemon-hold keep reason is distinguishable from generic no-merge-evidence" \
  || bad "daemon-verification-pending-restart reason missing"
grep -qF 'printf '"'"'%s'"'"' "$b" | jq -e '"'"'(.labels // []) | index("delivery:pending-restart")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "in_progress sweep computes IS_DAEMON_HOLD from the bead's own labels" \
  || bad "in_progress sweep not computing IS_DAEMON_HOLD"
grep -qF 'printf '"'"'%s'"'"' "$f" | jq -e '"'"'(.labels // []) | index("delivery:pending-restart")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_DAEMON_HOLD from the bead's own labels" \
  || bad "ga-hcj4 sweep not computing F_DAEMON_HOLD"
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE" "$SIG_MK_SUPER" "$IS_DELIV_PARTIAL" "$IS_DAEMON_HOLD"' "$JANITOR" \
  && ok "in_progress sweep threads is_daemon_hold into janitor_decide" \
  || bad "in_progress sweep not threading is_daemon_hold"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE" "$F_SIGMK_SUPER" "$F_DELIV_PARTIAL" "$F_DAEMON_HOLD"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads is_daemon_hold into janitor_decide" \
  || bad "ga-hcj4 sweep not threading is_daemon_hold"
# Same exact-tail check as §15 above (see that comment for why this is no longer a
# two-grep AND-NOT): ga-fbycg's sig_commit_docs_only and ga-tysvjp's sig_marker_stale are
# legitimate 12th/13th args, but still no daemon-hold-shaped arg beyond them
# (delivery:pending-restart is stamped only in quality-gate-dispatcher.sh's non-story
# branch, so a story bead never carries it).
if grep -qF '"$S_BUILDER" "$S_DELIV" "$S_SIGCOMMIT" "$S_SIGMK" "$S_SIGBRANCH" "$S_SIGCOMMIT_STALE" "$S_SIGMK_SUPER" "$S_SIGCOMMIT_DOCS_ONLY" "$S_SIGMK_STALE" "$S_GRACE")' "$JANITOR"; then
  ok "story sweep's janitor_story_decide call ends at gate_passed_grace (no delivery:pending-restart label ever reaches a story bead)"
else
  bad "story sweep's janitor_story_decide call signature changed unexpectedly — re-check ga-l7n3v's story-sweep-exclusion rationale"
fi

# ── 16b. Drift-guard: ga-wye9vt delivery:pending-vm is a keep-guard in BOTH non-story sweeps ──
# The pure-function tests (§1a8) prove the verdict; they say nothing about whether the live
# sweeps read the label and pass it in. A guard that exists as a function argument nobody
# supplies is indistinguishable from no guard — and here the failure is silent: the janitor
# closes the VM-held bead on the next 15-minute pass. The story:approved sweep needs nothing
# new (story_delivery_owns_labels already covers the label, ga-2kaan2).
echo "── 16b. Drift-guard: ga-wye9vt delivery:pending-vm not a merge signal (non-story sweeps) ──"
grep -qF 'is_vm_hold="${12:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional is_vm_hold (backward-compatible default)" \
  || bad "janitor_decide missing is_vm_hold param"
grep -qF 'keep:dialer-vm-pending-vm-hold' "$JANITOR" \
  && ok "vm-hold keep reason is distinguishable from generic no-merge-evidence" \
  || bad "dialer-vm-pending-vm-hold reason missing"
grep -qF 'printf '"'"'%s'"'"' "$b" | jq -e '"'"'(.labels // []) | index("delivery:pending-vm")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "in_progress sweep computes IS_VM_HOLD from the bead's own labels" \
  || bad "in_progress sweep not computing IS_VM_HOLD"
grep -qF 'printf '"'"'%s'"'"' "$f" | jq -e '"'"'(.labels // []) | index("delivery:pending-vm")'"'"' >/dev/null 2>&1 \' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_VM_HOLD from the bead's own labels" \
  || bad "ga-hcj4 sweep not computing F_VM_HOLD"
grep -qF '"$SIG_COMMIT_DOCS_ONLY" "$SIG_MARKER_STALE" "$IS_VM_HOLD")' "$JANITOR" \
  && ok "in_progress sweep threads is_vm_hold into janitor_decide" \
  || bad "in_progress sweep not threading is_vm_hold"
grep -qF '"$F_SIGCOMMIT_DOCS_ONLY" "$F_SIGMARKER_STALE" "$F_VM_HOLD")' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads is_vm_hold into janitor_decide" \
  || bad "ga-hcj4 sweep not threading is_vm_hold"
# Unreadable rows: both sweeps take .labels off the bead JSON they already fetched, the same
# source as the bead id. A row jq cannot parse yields an empty id and is skipped before the
# label read (`[ -z "$BID" ] && continue`), so "could not read the labels" never reaches the
# flag as "no hold". The story sweep's own unreadable-list case is pinned further down (ga-2kaan2).

# ── 17. Drift-guard: ga-fbycg docs-only-patch guard (sig_commit_docs_only) ──────
# The pure-function tests (§1a6/§1b4) and the real-git helper test (§3e) prove the
# LOGIC is correct in isolation — they say nothing about whether the live sweep
# actually WIRES it in. This is the exact gap that let ga-soxi9/ga-9n9z7 false-close
# in the first place: a guard that exists as a function but is never threaded into
# the call site it's supposed to protect is indistinguishable from no guard at all.
# Must be wired into ALL THREE call sites that use janitor_decide/janitor_story_decide
# (in_progress, ga-hcj4 stranded-wrapper, story:approved) — missing even one leaves
# that bucket vulnerable to the exact same false-close this bead fixes.
echo "── 17. Drift-guard: ga-fbycg docs-only-patch guard (sig_commit_docs_only) ──"
grep -qF 'commit_touches_only_pending_patch() {' "$JANITOR" \
  && ok "defines commit_touches_only_pending_patch" || bad "missing commit_touches_only_pending_patch def"
grep -qF 'sig_commit_docs_only="${10:-0}"' "$JANITOR" \
  && ok "janitor_decide accepts optional sig_commit_docs_only (backward-compatible default)" \
  || bad "janitor_decide missing sig_commit_docs_only param"
grep -qF 'sig_commit_docs_only="${12:-0}"' "$JANITOR" \
  && ok "janitor_story_decide accepts optional sig_commit_docs_only (backward-compatible default)" \
  || bad "janitor_story_decide missing sig_commit_docs_only param"
grep -qF 'keep:commit-evidence-docs-only-patch-staged' "$JANITOR" \
  && ok "docs-only-suppression keep reason present" || bad "docs-only-suppression keep reason missing"
# All THREE call sites must COMPUTE the signal via the real helper (not just default it).
grep -qF 'commit_touches_only_pending_patch "$MATCH_GITDIR" "$MATCH_CONTAINER" "$sha" && SIG_COMMIT_DOCS_ONLY=1' "$JANITOR" \
  && ok "in_progress sweep computes SIG_COMMIT_DOCS_ONLY via the real helper" || bad "in_progress sweep not computing SIG_COMMIT_DOCS_ONLY"
grep -qF 'commit_touches_only_pending_patch "$F_MATCH_GITDIR" "$F_MATCH_CONTAINER" "$sha" && F_SIGCOMMIT_DOCS_ONLY=1' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep computes F_SIGCOMMIT_DOCS_ONLY via the real helper" || bad "ga-hcj4 sweep not computing F_SIGCOMMIT_DOCS_ONLY"
grep -qF 'commit_touches_only_pending_patch "$S_MATCH_GITDIR" "$S_MATCH_CONTAINER" "$sha" && S_SIGCOMMIT_DOCS_ONLY=1' "$JANITOR" \
  && ok "story sweep computes S_SIGCOMMIT_DOCS_ONLY via the real helper" || bad "story sweep not computing S_SIGCOMMIT_DOCS_ONLY"
# All THREE call sites must thread the signal into janitor_decide/janitor_story_decide.
grep -qF 'janitor_decide "$IS_EPIC" "$HAS_OPEN" "$SIG_COMMIT" "$SIG_MARKER" "$SIG_BRANCH" "$SIG_COMMIT_STALE" "$SIG_MK_SUPER" "$IS_DELIV_PARTIAL" "$IS_DAEMON_HOLD" "$SIG_COMMIT_DOCS_ONLY"' "$JANITOR" \
  && ok "in_progress sweep threads sig_commit_docs_only into janitor_decide" || bad "in_progress sweep not threading sig_commit_docs_only"
grep -qF 'janitor_decide "$F_EPIC" "$F_HASOPEN" "$F_SIGCOMMIT" "$F_SIGMARKER" "$F_SIGBRANCH" "$F_SIGCOMMIT_STALE" "$F_SIGMK_SUPER" "$F_DELIV_PARTIAL" "$F_DAEMON_HOLD" "$F_SIGCOMMIT_DOCS_ONLY"' "$JANITOR" \
  && ok "ga-hcj4 stranded-wrapper sweep threads sig_commit_docs_only into janitor_decide" || bad "ga-hcj4 sweep not threading sig_commit_docs_only"
grep -qF '"$S_SIGBRANCH" "$S_SIGCOMMIT_STALE" "$S_SIGMK_SUPER" "$S_SIGCOMMIT_DOCS_ONLY" "$S_SIGMK_STALE" "$S_GRACE")' "$JANITOR" \
  && ok "story sweep threads sig_commit_docs_only into janitor_story_decide" || bad "story sweep not threading sig_commit_docs_only"
# Signal C must gate on a TRUSTED flag that ALSO requires docs_only!=1 at all three call
# sites, so a docs-only-flagged signal A never blinds the sweep to an independent,
# genuinely-merged crew branch for this same bead (same shape as the ga-2zp4h stale gate).
grep -qF '[ "$SIG_COMMIT" = "1" ] && [ "$SIG_COMMIT_STALE" != "1" ] && [ "$SIG_COMMIT_DOCS_ONLY" != "1" ] && SIG_COMMIT_TRUSTED=1' "$JANITOR" \
  && ok "in_progress SIG_COMMIT_TRUSTED requires docs_only!=1" || bad "in_progress SIG_COMMIT_TRUSTED not gated on docs_only"
grep -qF '[ "$F_SIGCOMMIT" = "1" ] && [ "$F_SIGCOMMIT_STALE" != "1" ] && [ "$F_SIGCOMMIT_DOCS_ONLY" != "1" ] && F_SIGCOMMIT_TRUSTED=1' "$JANITOR" \
  && ok "ga-hcj4 F_SIGCOMMIT_TRUSTED requires docs_only!=1" || bad "ga-hcj4 F_SIGCOMMIT_TRUSTED not gated on docs_only"
grep -qF '[ "$S_SIGCOMMIT" = "1" ] && [ "$S_SIGCOMMIT_STALE" != "1" ] && [ "$S_SIGCOMMIT_DOCS_ONLY" != "1" ] && S_SIGCOMMIT_TRUSTED=1' "$JANITOR" \
  && ok "story S_SIGCOMMIT_TRUSTED requires docs_only!=1" || bad "story S_SIGCOMMIT_TRUSTED not gated on docs_only"
# All three initializers must reset the flag to 0 per-bead (never carry a stale value
# from the previous loop iteration's bead into this one).
grep -qF 'SIG_COMMIT=0; COMMIT_EVID=""; SIG_COMMIT_STALE=0; SIG_COMMIT_DOCS_ONLY=0' "$JANITOR" \
  && ok "in_progress sweep resets SIG_COMMIT_DOCS_ONLY per bead" || bad "in_progress sweep missing SIG_COMMIT_DOCS_ONLY reset"
grep -qF 'F_SIGCOMMIT=0; F_COMMIT_EVID=""; F_SIGCOMMIT_STALE=0; F_SIGCOMMIT_DOCS_ONLY=0' "$JANITOR" \
  && ok "ga-hcj4 sweep resets F_SIGCOMMIT_DOCS_ONLY per bead" || bad "ga-hcj4 sweep missing F_SIGCOMMIT_DOCS_ONLY reset"
grep -qF 'S_SIGCOMMIT=0; S_SIGBRANCH=0; S_COMMIT_EVID=""; S_BRANCH_EVID=""; S_SIGCOMMIT_STALE=0; S_SIGCOMMIT_DOCS_ONLY=0' "$JANITOR" \
  && ok "story sweep resets S_SIGCOMMIT_DOCS_ONLY per bead" || bad "story sweep missing S_SIGCOMMIT_DOCS_ONLY reset"

# ── ga-2kaan2: delivery:pending-vm is DELIVERY-OWNED ─────────────────────────
# story-delivery holds a story whose merge touches the voicebot while the dialer
# VM still runs old code (label delivery:pending-vm; the story is NOT closed). That
# story has the strongest possible merge evidence — it is in origin/main — so the
# story:done sweep would force story:done + close it on its next pass, defeating the
# hold one sweep later. The sweep's delivery_active input must therefore be true for
# the label, like it already is for delivery:running / delivery:failed.
echo ""
echo "── ga-2kaan2: delivery:pending-vm keeps the story delivery-owned ──"
if type story_delivery_owns_labels >/dev/null 2>&1; then
  rc0 story_delivery_owns_labels "delivery:running"
  rc0 story_delivery_owns_labels "delivery:failed"
  rc0 story_delivery_owns_labels "delivery:pending-vm"
  rc0 story_delivery_owns_labels "ctx:ready story:approved gate:passed delivery:pending-vm"
  rc1 story_delivery_owns_labels ""
  rc1 story_delivery_owns_labels "ctx:ready story:approved gate:passed"
  rc1 story_delivery_owns_labels "delivery:tested delivery:daemon-unverified"
else
  bad "story_delivery_owns_labels is not defined — the janitor cannot tell a VM-held story from a stranded one"
fi
deliv_active() { if type story_delivery_owns_labels >/dev/null 2>&1 && story_delivery_owns_labels "$1"; then echo 1; else echo 0; fi; }
# END TO END, the exact shape that bites: commit in origin/main (sig_commit=1) + the hold label.
eq "VM-held story with merge evidence in main -> keep, NOT force-closed" \
   "$(janitor_story_decide 0 0 0 0 0 "$(deliv_active 'ctx:ready story:approved gate:passed delivery:pending-vm')" 1 1 1)" \
   "keep:delivery-owns-it"
eq "the same story without the hold label -> done (the sweep itself is unchanged)" \
   "$(janitor_story_decide 0 0 0 0 0 "$(deliv_active 'ctx:ready story:approved gate:passed')" 1 1 1)" \
   "done:commit-in-origin-main"
# The sweep must actually call the function (a correct helper nobody calls guards nothing).
grep -qF 'if story_delivery_owns_labels "$SLABELS"; then S_DELIV=1; fi' "$JANITOR" \
  && ok "story sweep derives S_DELIV from story_delivery_owns_labels" \
  || bad "story sweep does not call story_delivery_owns_labels — delivery:pending-vm would not be honoured"

# ── ga-2kaan2 (gate fix-attempt 2): an UNREADABLE label list is not "no labels" ──
# The sweep's `SLABELS=$(jq ... || true)` turns a jq failure into "". With "" the hold's
# protection vanishes silently (story_delivery_owns_labels "" is rc1) and a VM-held story
# with merge evidence is forced story:done. The sweep selects on story:approved, so a row
# whose labels do not name it is the "could not read" signal and must be skipped.
echo ""
echo "── ga-2kaan2: an unreadable label list is skipped, never decided on ──"
if type story_labels_readable >/dev/null 2>&1; then
  rc0 story_labels_readable "ctx:ready story:approved gate:passed"
  rc0 story_labels_readable "ctx:ready story:approved gate:passed delivery:pending-vm"
  rc1 story_labels_readable ""
  rc1 story_labels_readable "ctx:ready gate:passed delivery:pending-vm"
else
  bad "story_labels_readable is not defined — a jq failure would read as 'no delivery label' and release a VM-held story"
fi
# The shape that bites: what jq yields on a row it cannot parse is "" — and "" must NOT be
# delivery-owned (that is the bug), so the only thing standing between it and story:done is
# the readability check before the decision.
rc1 story_delivery_owns_labels ""
# The sweep must call it, on the labels it just read, BEFORE it derives delivery ownership
# from them (a correct helper nobody calls guards nothing; one called after is too late).
RL_LN=$(grep -n 'if ! story_labels_readable "\$SLABELS"; then' "$JANITOR" | head -1 | cut -d: -f1)
OW_LN=$(grep -n 'if story_delivery_owns_labels "\$SLABELS"; then S_DELIV=1; fi' "$JANITOR" | head -1 | cut -d: -f1)
if [ -n "$RL_LN" ] && [ -n "$OW_LN" ] && [ "$RL_LN" -lt "$OW_LN" ]; then
  ok "story sweep checks story_labels_readable (L$RL_LN) before deriving S_DELIV (L$OW_LN)"
else
  bad "story sweep does not check story_labels_readable before story_delivery_owns_labels (readable=L${RL_LN:-none}, owns=L${OW_LN:-none})"
fi
# And the skip must be a skip: a `continue` right after the log, no S_* decision in between.
RL_BLOCK=$(sed -n "${RL_LN:-1},$((${RL_LN:-1}+4))p" "$JANITOR" 2>/dev/null)
printf '%s' "$RL_BLOCK" | grep -q 'continue' \
  && ok "an unreadable story row is skipped with 'continue' (no decision, no mutation)" \
  || bad "the unreadable-row branch does not 'continue' — it would fall through to the decision"

# ── ga-botvu2: a gate-passed story WAITS for story-delivery before the janitor closes it ──
# The gate hands a story off OPEN as story:approved + gate:passed and story-delivery deploys and
# prod-tests it. Merge evidence is in origin/main from the first second, so the story sweep used to
# close it as story:done before the deploy ran. Now it keeps the story for a grace after its last
# update; past the grace it closes it as an explicit BACKSTOP (delivery:janitor-backstop, close
# reason says deploy was NOT verified). An age that cannot be computed keeps the story.
#
# GATE-FIX 1: "last update" cannot be bd's `updated_at` ALONE. `bd label add/remove` and `bd comment` do
# not advance it (only `bd update` does), so the hand-off (label remove x2, label add gate:passed, a
# comment) left it at some earlier, unrelated write, the first sweep read that as an old story and closed
# it as a BACKSTOP seconds after the gate passed it. The hand-off now STAMPS gate.passed_at (epoch) and
# the grace counts from max(updated_at, stamp). A gate:passed story with NO stamp is `unstamped`: kept, and
# the janitor writes gate.passed_seen_at on first sight so the wait starts then.
echo ""
echo "── ga-botvu2: iso_epoch ──"
# 2026-10-15T17:51:50Z = 1792086710 (checked against `date -u -j -f` / jq on the day this was written).
E0=1792086710
eq "iso_epoch Z timestamp"                    "$(iso_epoch 2026-10-15T17:51:50Z)"        "$E0"
eq "iso_epoch tolerates fractional seconds"   "$(iso_epoch 2026-10-15T17:51:50.123456Z)" "$E0"
eq "iso_epoch empty -> nothing"               "$(iso_epoch '')"                          ""
eq "iso_epoch garbage -> nothing"             "$(iso_epoch 'not-a-date')"                ""
eq "iso_epoch +hh:mm offset form -> nothing (never a guess)" "$(iso_epoch 2026-10-15T17:51:50-03:00)" ""
eq "iso_epoch +00:00 is UTC, the same instant as Z" "$(iso_epoch 2026-10-15T17:51:50+00:00)" "$E0"
eq "iso_epoch +00:00 with fractional seconds"       "$(iso_epoch 2026-10-15T17:51:50.5+00:00)" "$E0"

echo ""
echo "── ga-botvu2: story_gate_passed_grace_state (none|waiting|elapsed|unstamped|unknown) ──"
# args: labels updated_at now grace [gate.passed_at epoch] [gate.passed_seen_at epoch]. The clock is the
# LATEST of updated_at / the hand-off stamp / the janitor's first-seen stamp; updated_at alone is not a clock.
GL="ctx:ready story:approved gate:passed"
U="2026-10-15T17:51:50Z"
gs()  { story_gate_passed_grace_state "$1" "$2" "$3" "$4" "${5-}" "${6-}"; }
gsp() { gs "$1" "$2" "$3" "$4" "$E0"; }     # the hand-off stamped at the same moment as updated_at ($E0)
eq "60 s old,  grace 600  -> waiting"   "$(gsp "$GL" "$U" $((E0+60))   600)"  "waiting"
eq "599 s old, grace 600  -> waiting"   "$(gsp "$GL" "$U" $((E0+599))  600)"  "waiting"
eq "600 s old, grace 600  -> elapsed (boundary is >=)" "$(gsp "$GL" "$U" $((E0+600))  600)"  "elapsed"
eq "900 s old, grace 600  -> elapsed"   "$(gsp "$GL" "$U" $((E0+900))  600)"  "elapsed"
eq "900 s old, grace 1800 -> waiting"   "$(gsp "$GL" "$U" $((E0+900))  1800)" "waiting"
eq "1799 s old, grace 1800 -> waiting"  "$(gsp "$GL" "$U" $((E0+1799)) 1800)" "waiting"
eq "1800 s old, grace 1800 -> elapsed"  "$(gsp "$GL" "$U" $((E0+1800)) 1800)" "elapsed"
eq "grace 0 -> elapsed at once (an operator's explicit choice)" "$(gsp "$GL" "$U" "$E0" 0)" "elapsed"
eq "no gate:passed, ancient -> none (the wait does not apply)" "$(gs "ctx:ready story:approved" "$U" $((E0+99999)) 1800)" "none"
eq "...stamps on a story with no gate:passed change nothing" "$(gs "ctx:ready story:approved" "$U" $((E0+99999)) 1800 "$E0" "$E0")" "none"
eq "empty labels -> none"               "$(gs "" "$U" $((E0+60)) 1800)" "none"
eq "gate:passed-warn is a different label -> none (whole-token match)" "$(gs "story:approved gate:passed-warn" "$U" $((E0+60)) 1800)" "none"
eq "empty updated_at -> unknown, NOT elapsed"      "$(gsp "$GL" ""            $((E0+99999)) 1800)" "unknown"
eq "garbage updated_at -> unknown, NOT elapsed"    "$(gsp "$GL" "yesterday"   $((E0+99999)) 1800)" "unknown"
eq "offset-form updated_at -> unknown"             "$(gsp "$GL" "2026-10-15T14:51:50-03:00" $((E0+99999)) 1800)" "unknown"
eq "updated_at in the future (clock skew) -> unknown" "$(gsp "$GL" "$U" $((E0-5)) 1800)" "unknown"
eq "empty now -> unknown"               "$(gsp "$GL" "$U" "" 1800)" "unknown"
eq "non-numeric now -> unknown"         "$(gsp "$GL" "$U" "abc" 1800)" "unknown"
eq "empty grace -> unknown"             "$(gsp "$GL" "$U" $((E0+99999)) "")" "unknown"
eq "non-numeric grace -> unknown (a typo holds the story, it does not drop the wait)" "$(gsp "$GL" "$U" $((E0+99999)) "10min")" "unknown"

echo ""
echo "── ga-botvu2 gate-fix 1: the clock starts at the HAND-OFF, not at some earlier write ──"
# THE reviewed bug. updated_at is an hour-plus old (bd does not move it on label add/remove/comment); the
# gate handed the story off 60 s ago and stamped it. The story must WAIT.
HO=$((E0+5000))     # the hand-off moment; updated_at is still $E0, 5000 s older
eq "hand-off 60 s ago, updated_at 5000 s old -> waiting (counted from the hand-off)" "$(gs "$GL" "$U" $((HO+60)) 1800 "$HO")" "waiting"
eq "hand-off 1799 s ago -> waiting"                   "$(gs "$GL" "$U" $((HO+1799)) 1800 "$HO")" "waiting"
eq "hand-off 1800 s ago -> elapsed (boundary is >=)"  "$(gs "$GL" "$U" $((HO+1800)) 1800 "$HO")" "elapsed"
eq "hand-off long ago and updated_at old too -> elapsed" "$(gs "$GL" "$U" $((HO+99999)) 1800 "$E0")" "elapsed"
U_NEW="$(date -u -r $((E0+5000)) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$((E0+5000))" +%Y-%m-%dT%H:%M:%SZ)"
eq "a LATER write (updated_at 60 s ago) postpones an old stamp -> waiting" "$(gs "$GL" "$U_NEW" $((E0+5060)) 1800 "$E0")" "waiting"
eq "...updated_at can only postpone: stamp 6799 s old, updated_at 1799 s old -> waiting" "$(gs "$GL" "$U_NEW" $((E0+5000+1799)) 1800 "$E0")" "waiting"
eq "...and 1800 s after that later write -> elapsed" "$(gs "$GL" "$U_NEW" $((E0+5000+1800)) 1800 "$E0")" "elapsed"
# No stamp = the janitor does not know when the story was handed off.
eq "gate:passed, NO stamp, updated_at ancient -> unstamped, NOT elapsed" "$(gs "$GL" "$U" $((E0+99999)) 1800)" "unstamped"
eq "...empty stamp strings are 'no stamp' too" "$(gs "$GL" "$U" $((E0+99999)) 1800 "" "")" "unstamped"
eq "first seen 60 s ago (no hand-off stamp) -> waiting"  "$(gs "$GL" "$U" $((HO+60)) 1800 "" "$HO")" "waiting"
eq "first seen 1800 s ago -> elapsed"                    "$(gs "$GL" "$U" $((HO+1800)) 1800 "" "$HO")" "elapsed"
eq "hand-off stamp and first-seen both present: the LATER one counts (stamp later)" "$(gs "$GL" "$U" $((HO+60)) 1800 "$HO" "$E0")" "waiting"
eq "...(first-seen later)"                               "$(gs "$GL" "$U" $((HO+60)) 1800 "$E0" "$HO")" "waiting"
eq "...both old -> elapsed"                              "$(gs "$GL" "$U" $((HO+99999)) 1800 "$E0" "$E0")" "elapsed"
# A stamp that is there but cannot be read is not 'no stamp': unknown, and it does not fall back.
eq "garbage hand-off stamp -> unknown"                   "$(gs "$GL" "$U" $((HO+99999)) 1800 "soon")" "unknown"
eq "...and it does not fall back to a good first-seen"   "$(gs "$GL" "$U" $((HO+99999)) 1800 "soon" "$E0")" "unknown"
eq "garbage first-seen (no hand-off stamp) -> unknown"   "$(gs "$GL" "$U" $((HO+99999)) 1800 "" "later")" "unknown"
eq "hand-off stamp in the future (clock skew) -> unknown" "$(gs "$GL" "$U" $((HO+60)) 1800 $((HO+9999)))" "unknown"
eq "first-seen in the future -> unknown"                 "$(gs "$GL" "$U" $((HO+60)) 1800 "" $((HO+9999)))" "unknown"
eq "a good stamp does not rescue an unreadable updated_at (row not trusted) -> unknown" "$(gs "$GL" "" $((HO+99999)) 1800 "$E0")" "unknown"
eq "non-numeric grace with a stamp -> unknown"           "$(gs "$GL" "$U" $((HO+99999)) "10min" "$E0")" "unknown"

echo ""
echo "── ga-botvu2: janitor_story_decide honours the grace ──"
# Strongest merge evidence (commit + marker + branch), no other guard: only the grace can hold it.
gd() { janitor_story_decide 0 0 0 0 0 0 1 1 1 0 0 0 0 "$@"; }
eq "waiting -> keep"                    "$(gd waiting)"  "keep:gate-passed-awaiting-delivery-grace"
eq "unknown -> keep (unreadable)"       "$(gd unknown)"  "keep:gate-passed-grace-unreadable"
eq "unstamped -> keep (the clock has not started; never closed on an age nobody measured)" "$(gd unstamped)" "keep:gate-passed-grace-not-started"
eq "empty state -> keep (unreadable)"   "$(gd '')"       "keep:gate-passed-grace-unreadable"
eq "unrecognised state -> keep (allowlist, not denylist)" "$(gd bogus)" "keep:gate-passed-grace-unreadable"
eq "elapsed -> done (the backstop)"     "$(gd elapsed)"  "done:commit-in-origin-main"
eq "none -> done (not a gate-passed story: behaviour unchanged)" "$(gd none)" "done:commit-in-origin-main"
eq "13-arg call (state omitted) -> done: the old signature still works" \
   "$(janitor_story_decide 0 0 0 0 0 0 1 1 1 0 0 0 0)" "done:commit-in-origin-main"
# The guards that were already there still outrank the grace, in both directions.
eq "epic is still kept when elapsed"            "$(janitor_story_decide 1 0 0 0 0 0 1 1 1 0 0 0 0 elapsed)" "keep:epic-parent-never-autoclosed"
eq "open marker is still kept when elapsed"    "$(janitor_story_decide 0 1 0 0 0 0 1 1 1 0 0 0 0 elapsed)" "keep:active-open-gate-marker"
eq "in-flight rework is still kept when elapsed" "$(janitor_story_decide 0 0 0 1 0 0 1 1 1 0 0 0 0 elapsed)" "keep:story-in-flight-active-rework"
eq "delivery-owned (running/failed/pending-vm) is still kept when elapsed" \
   "$(janitor_story_decide 0 0 0 0 0 1 1 1 1 0 0 0 0 elapsed)" "keep:delivery-owns-it"
eq "already story:done keeps its own reason while waiting (the orphan-close needs it)" \
   "$(janitor_story_decide 0 0 1 0 0 0 1 1 1 0 0 0 0 waiting)" "keep:already-story-done"
eq "unstamped with the strongest evidence is still kept"    "$(janitor_story_decide 0 0 0 0 0 0 1 1 1 0 0 0 0 unstamped | cut -d: -f1)" "keep"
eq "waiting with no merge evidence -> still keep" "$(janitor_story_decide 0 0 0 0 0 0 0 0 0 0 0 0 0 waiting | cut -d: -f1)" "keep"
eq "elapsed with no merge evidence -> keep: elapsed alone closes nothing" \
   "$(janitor_story_decide 0 0 0 0 0 0 0 0 0 0 0 0 0 elapsed)" "keep:no-merge-evidence"

# The default is a number a reader can check, and it is not the 600 s first proposed (see the comment
# on STORY_DELIVERY_GRACE_SECONDS: one delivery pass measured up to 1546 s).
DEF_GRACE=$(env -u JANITOR_STORY_DELIVERY_GRACE_SECONDS bash -c 'JANITOR_LIB_ONLY=1 source "$1" && printf %s "$STORY_DELIVERY_GRACE_SECONDS"' _ "$JANITOR" 2>/dev/null)
eq "default story-delivery grace is 1800 s" "$DEF_GRACE" "1800"
OVR_GRACE=$(JANITOR_STORY_DELIVERY_GRACE_SECONDS=600 bash -c 'JANITOR_LIB_ONLY=1 source "$1" && printf %s "$STORY_DELIVERY_GRACE_SECONDS"' _ "$JANITOR" 2>/dev/null)
eq "JANITOR_STORY_DELIVERY_GRACE_SECONDS overrides it" "$OVR_GRACE" "600"

echo ""
echo "── ga-botvu2: drift-guards on the live sweep ──"
grep -qF -- '--status open --limit 0 --json -l story:approved' "$JANITOR" \
  && ok "story sweep lists ALL approved stories (--limit 0), so none is cut off before it ages through the grace" \
  || bad "story sweep's bd list lost --limit 0 — a story past bd's default cutoff would never be reconciled"
grep -qF 'story_gate_passed_grace_state "$SLABELS" "$S_UPDATED" "$S_NOW" "$STORY_DELIVERY_GRACE_SECONDS" "$S_PASSED_AT" "$S_SEEN_AT")' "$JANITOR" \
  && ok "story sweep derives S_GRACE from the row's labels, updated_at, the clock, the grace AND the stamps" \
  || bad "story sweep does not compute S_GRACE from story_gate_passed_grace_state with the hand-off stamps"
# The two halves of one contract: what the guard WRITES is what the janitor READS.
GUARD_LIB="$SELF_DIR/quality-gate-guard.sh"
grep -qF 'gate.passed_at' "$GUARD_LIB" && grep -qF '"gate.passed_at"' "$JANITOR" \
  && ok "the hand-off stamp key (gate.passed_at) is the same in the guard that writes it and the janitor that reads it" \
  || bad "gate.passed_at is not named by both quality-gate-guard.sh and merged-bead-janitor.sh — the clock would never start"
grep -qF 'gate.passed_seen_at' "$JANITOR" \
  && ok "the janitor stamps gate.passed_seen_at on first sight of an unstamped gate:passed story" \
  || bad "the janitor never writes gate.passed_seen_at — an unstamped story could never age out"
grep -qF '"$S_SIGCOMMIT_DOCS_ONLY" "$S_SIGMK_STALE" "$S_GRACE")' "$JANITOR" \
  && ok "story sweep passes S_GRACE as janitor_story_decide's last arg (an omitted arg means 'no wait')" \
  || bad "story sweep does not pass S_GRACE to janitor_story_decide — the wait would never be applied"
grep -qF '[ "$S_GRACE_OPEN" = "1" ]; then' "$JANITOR" \
  && ok "story sweep skips the git scans while the grace holds the story" \
  || bad "story sweep scans git for a story the grace already holds"
BL_LN=$(grep -n 'label add "\$SID" "delivery:janitor-backstop"' "$JANITOR" | head -1 | cut -d: -f1)
CL_LN=$(grep -n 'if bd -C "\$RPATH" close "\$SID" -r "\$JCLOSE_MSG"' "$JANITOR" | head -1 | cut -d: -f1)
if [ -n "$BL_LN" ] && [ -n "$CL_LN" ] && [ "$BL_LN" -lt "$CL_LN" ]; then
  ok "the backstop label is added (L$BL_LN) BEFORE the story is closed (L$CL_LN), so it survives a failed close"
else
  bad "backstop label is not added before the close (label=L${BL_LN:-none}, close=L${CL_LN:-none})"
fi
grep -qF 'DEPLOY AND PROD-TEST WERE NOT VERIFIED' "$JANITOR" \
  && ok "the backstop close reason says deploy and prod-test were NOT verified" \
  || bad "the backstop close reason does not say the deploy was unverified"
grep -qF '[ "$S_GRACE" = "elapsed" ] && S_BACKSTOP=1' "$JANITOR" \
  && ok "only an ELAPSED grace makes a close a backstop" \
  || bad "backstop condition changed — a story that never was gate-passed could be labelled (or the reverse)"

echo ""
echo "── ga-botvu2: the REAL sweep, stubbed bd/gc + a real git fixture (the acceptance scenarios) ──"
# One origin with a commit "feat(ga-fixture1): …" on main, one rig clone of it; per scenario a fresh
# stories.json, stub bd (logs every call, serves the story list, answers `[]` otherwise) and stub gc
# (serves the rig list). The janitor runs end to end; we read what it asked bd to do. Lives under
# $T, which the EXIT trap above already cleans.
BV="$T/botvu2"; mkdir -p "$BV"
git init -q --bare -b main "$BV/origin.git"
git init -q -b main "$BV/rig"
( cd "$BV/rig" && echo a > a && git add a && git commit -q -m "base" \
  && echo b > b && git add b && git commit -q -m "feat(ga-fixture1): the story" \
  && git remote add origin "$BV/origin.git" && git push -q origin main ) >/dev/null 2>&1
BV_N=0; BV_K=0
epoch_iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# bv_fixture <age_seconds|EMPTY|GARBAGE> <labels> <hand-off stamp age_seconds|GARBAGE|-> <first-seen age_seconds|GARBAGE|->
# — a fresh run dir $BV_D holding ONE open story and a STATEFUL stub bd. The stub is bd 1.1.0 as MEASURED on
# the live store: `label add/remove` and `comment` do NOT advance updated_at, `update` does, `close` closes.
# That is the whole point of the gate-fix: a stub that served a frozen updated_at, or moved it on every write,
# could not tell a janitor that reads the right clock from one that reads the wrong one.
bv_fixture() {
  local age="$1" labels="$2" pa="${3:--}" sa="${4:--}" now upd meta='{}'
  BV_N=$((BV_N+1)); BV_K=0; BV_D="$BV/run$BV_N"; mkdir -p "$BV_D/bin" "$BV_D/city/.gc/logs"
  now=$(date +%s)
  case "$age" in
    EMPTY)   upd="" ;;
    GARBAGE) upd="sometime last week" ;;
    *)       upd=$(epoch_iso $((now - age))) ;;
  esac
  case "$pa" in -) ;; GARBAGE) meta=$(jq -c '. + {"gate.passed_at":"soon"}' <<<"$meta") ;;
    *) meta=$(jq -c --arg v "$((now - pa))" '. + {"gate.passed_at":$v}' <<<"$meta") ;; esac
  case "$sa" in -) ;; GARBAGE) meta=$(jq -c '. + {"gate.passed_seen_at":"later"}' <<<"$meta") ;;
    *) meta=$(jq -c --arg v "$((now - sa))" '. + {"gate.passed_seen_at":$v}' <<<"$meta") ;; esac
  jq -n --arg id ga-fixture1 --arg upd "$upd" --arg labels "$labels" --argjson meta "$meta" \
    '[{id:$id, title:"fixture story", issue_type:"feature", status:"open", assignee:"", updated_at:$upd, labels:($labels|split(" ")), metadata:$meta}]' > "$BV_D/stories.json"
  cat > "$BV_D/bin/gc" <<STUB
#!/usr/bin/env bash
if [ "\$3" = "rig" ] && [ "\$4" = "list" ]; then
  printf '{"rigs":[{"name":"fixrig","prefix":"ga","path":"$BV/rig","default_branch":"main","hq":false}]}'
fi
exit 0
STUB
  cat > "$BV_D/bin/bd" <<'STUB'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$D/bd.log"
[ "${1:-}" = "-C" ] && shift 2
cmd="${1:-}"; sub="${2:-}"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
mut() { jq "$@" "$D/stories.json" > "$D/stories.tmp" && mv "$D/stories.tmp" "$D/stories.json"; }
case "$cmd" in
  list)
    case " $* " in
      *"story:approved"*)
        if [ -n "${BV_LIST_FAILS:-}" ]; then echo "Error: database is unavailable" >&2; exit 1; fi
        jq '[.[] | select(.status == "open")]' "$D/stories.json" ;;
      *) printf '[]' ;;
    esac ;;
  show)     cat "$D/stories.json" ;;
  comments) printf '[]' ;;
  label)
    case "$sub" in
      add)    mut --arg l "$4" '.[0].labels |= ((. + [$l]) | unique)' ;;
      remove) mut --arg l "$4" '.[0].labels |= map(select(. != $l))' ;;
    esac ;;
  update)
    [ -n "${BV_UPDATE_FAILS:-}" ] && exit 1
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --set-metadata)   mut --arg k "${2%%=*}" --arg v "${2#*=}" --arg now "$now" '.[0].metadata[$k] = $v | .[0].updated_at = $now'; shift ;;
        --unset-metadata) mut --arg k "$2" --arg now "$now" 'del(.[0].metadata[$k]) | .[0].updated_at = $now'; shift ;;
      esac
      shift
    done ;;
  close)    mut '.[0].status = "closed"' ;;
esac
exit 0
STUB
  chmod +x "$BV_D/bin/gc" "$BV_D/bin/bd"; : > "$BV_D/bd.log"
}
# bv_sweep <grace seconds | -> — one janitor run against $BV_D; the state persists across sweeps. BV_LOG is
# the bd calls of THIS run only (truncated first). BV_DRY / BV_UPDATE_FAILS / BV_LIST_FAILS opt in per call.
bv_sweep() {
  local grace="$1"
  BV_K=$((BV_K+1)); BV_OUT="$BV_D/out$BV_K.log"; BV_LOG="$BV_D/bd.log"; : > "$BV_LOG"
  if [ "$grace" = "-" ]; then
    env -u JANITOR_STORY_DELIVERY_GRACE_SECONDS GC_CITY_PATH="$BV_D/city" JANITOR_LOG_STDOUT=1 JANITOR_DRY_RUN="${BV_DRY:-0}" \
      BV_UPDATE_FAILS="${BV_UPDATE_FAILS:-}" BV_LIST_FAILS="${BV_LIST_FAILS:-}" PATH="$BV_D/bin:$PATH" bash "$JANITOR" > "$BV_OUT" 2>&1
  else
    env JANITOR_STORY_DELIVERY_GRACE_SECONDS="$grace" GC_CITY_PATH="$BV_D/city" JANITOR_LOG_STDOUT=1 JANITOR_DRY_RUN="${BV_DRY:-0}" \
      BV_UPDATE_FAILS="${BV_UPDATE_FAILS:-}" BV_LIST_FAILS="${BV_LIST_FAILS:-}" PATH="$BV_D/bin:$PATH" bash "$JANITOR" > "$BV_OUT" 2>&1
  fi
}
# bv_run <age|EMPTY|GARBAGE> <labels> <grace|-> [stamp age|GARBAGE|-] [first-seen age|GARBAGE|-] — fixture + sweep.
# The hand-off stamp defaults to the SAME age as updated_at (the hand-off was the last write); `-` = unstamped.
bv_run() {
  local pa="${4-}"
  if [ -z "$pa" ]; then case "$1" in EMPTY|GARBAGE) pa=- ;; *) pa="$1" ;; esac; fi
  bv_fixture "$1" "$2" "$pa" "${5:--}"; bv_sweep "$3"
}
# bv_handoff — the REAL gap2_apply_pass_verdict (quality-gate-guard.sh's lib) against the stub bd, in its own
# process: label remove x2, label add gate:passed, gate_passed_confirm, comment. BV_LOG = its bd calls.
bv_handoff() {
  BV_LOG="$BV_D/bd.log"; : > "$BV_LOG"
  env PATH="$BV_D/bin:$PATH" GATE_GUARD_LIB_ONLY=1 \
    bash -c 'source "$1" >/dev/null 2>&1; gap2_apply_pass_verdict ga-fixture1 ga-sling1 1 close:merge-verified' _ "$GUARD_LIB" > "$BV_D/handoff.out" 2>&1
}
# bv_age_all <seconds> — time passes: updated_at and the stamps move back to <seconds> ago (the janitor reads `date`).
bv_age_all() {
  local t=$(( $(date +%s) - $1 ))
  jq --argjson t "$t" '.[0].updated_at = ($t|todate) | .[0].metadata |= with_entries(if (.key=="gate.passed_at" or .key=="gate.passed_seen_at") then .value = ($t|tostring) else . end)' \
    "$BV_D/stories.json" > "$BV_D/stories.tmp" && mv "$BV_D/stories.tmp" "$BV_D/stories.json"
}
bv_closed()   { grep -qE ' close ga-fixture1 ' "$BV_LOG"; }
bv_backstop() { grep -qE ' label add ga-fixture1 delivery:janitor-backstop' "$BV_LOG"; }
bv_unverified() { grep -E ' close ga-fixture1 ' "$BV_LOG" | grep -qF 'NOT VERIFIED'; }
bv_updates()  { grep -cE ' update ga-fixture1 ' "$BV_LOG" || true; }
bv_meta()     { jq -r --arg k "$1" '.[0].metadata[$k] // ""' "$BV_D/stories.json"; }
bv_labels()   { jq -r '.[0].labels | join(" ")' "$BV_D/stories.json"; }
bv_upd()      { jq -r '.[0].updated_at' "$BV_D/stories.json"; }
PASSED="story:approved gate:passed"

echo ""
echo "── the stub bd is honest about bd 1.1.0 (the premise of every scenario below) ──"
bv_fixture 7200 "story:approved story:in-flight pilot:dispatched" - -
UPD0=$(bv_upd)
( PATH="$BV_D/bin:$PATH"; bd -C x label remove ga-fixture1 story:in-flight -q; bd -C x label add ga-fixture1 gate:passed -q; bd -C x comment ga-fixture1 "hand-off" )
eq "label add/remove and comment do NOT advance updated_at" "$(bv_upd)" "$UPD0"
( PATH="$BV_D/bin:$PATH"; bd -C x update ga-fixture1 --set-metadata k=v -q )
if [ "$(bv_upd)" != "$UPD0" ] && [ "$(bv_meta k)" = "v" ]; then ok "update --set-metadata advances updated_at and stores the value"; else bad "stub: update did not move updated_at / store k=v"; fi

echo ""
echo "── gate-fix 1, END TO END: the real hand-off, then the real sweep ──"
# A story whose LAST write was 2 h ago (a builder comment, the Pilot dispatch). The gate passes it: the real
# gap2_apply_pass_verdict runs against the stub. Then the real janitor sweeps, seconds later, with the
# merge evidence already in origin/main. Before the fix: updated_at (2 h old) read as an old story -> the
# janitor closed it as a BACKSTOP seconds after the gate passed it, with a false "never ran or crashed".
bv_fixture 7200 "story:approved story:in-flight pilot:dispatched" - -
bv_handoff
case " $(bv_labels) " in *" gate:passed "*) ok "hand-off: the story wears gate:passed" ;; *) bad "hand-off: gate:passed missing (labels: $(bv_labels))" ;; esac
case " $(bv_labels) " in *" story:in-flight "*) bad "hand-off: story:in-flight still there" ;; *) ok "hand-off: story:in-flight cleared" ;; esac
HOP=$(bv_meta gate.passed_at)
case "$HOP" in
  ''|*[!0-9]*) bad "hand-off: no gate.passed_at stamp on the story (got [$HOP]) — nothing records WHEN the gate handed it off" ;;
  *) if [ "$HOP" -ge $(( $(date +%s) - 60 )) ]; then ok "hand-off: gate.passed_at is the hand-off moment ($HOP)"; else bad "hand-off: gate.passed_at $HOP is not recent"; fi ;;
esac
bv_sweep -
if bv_closed; then bad "the sweep CLOSED the story seconds after the gate passed it (hand-off left updated_at 2 h old) — the bug"; else ok "sweep seconds after the hand-off: story NOT closed"; fi
if bv_backstop; then bad "...and it was labelled delivery:janitor-backstop"; else ok "...and not labelled as a backstop"; fi
grep -qF 'gate-passed-awaiting-delivery-grace' "$BV_OUT" && ok "...the log says it is waiting for delivery" || bad "...the log does not say why it was kept"
eq "...the stamped story needs no first-seen stamp from the janitor" "$(bv_meta gate.passed_seen_at)" ""
bv_age_all 2000
bv_sweep -
if bv_closed && bv_backstop; then ok "2000 s after the hand-off (default grace 1800): closed as a BACKSTOP — the wait is a wait, not a veto"; else bad "2000 s after the hand-off: not closed as a backstop (closed=$(bv_closed && echo y || echo n), label=$(bv_backstop && echo y || echo n))"; fi

echo ""
echo "── gate-fix 1: a gate:passed story with NO stamp (handed off before this fix, or the stamp write failed) ──"
bv_fixture 5000 "$PASSED" - -
bv_sweep -
if bv_closed; then bad "unstamped gate:passed story, updated_at 5000 s old: CLOSED on an age nobody measured"; else ok "unstamped, updated_at 5000 s old -> NOT closed (the clock starts when the janitor first sees it)"; fi
SEEN=$(bv_meta gate.passed_seen_at)
case "$SEEN" in ''|*[!0-9]*) bad "...the janitor wrote no gate.passed_seen_at (got [$SEEN])" ;; *) ok "...the janitor stamped gate.passed_seen_at=$SEEN" ;; esac
grep -qF 'state=unstamped' "$BV_OUT" || grep -qF 'stamp-story ga-fixture1' "$BV_OUT" && ok "...and the log says it started the clock" || bad "...the log does not say the clock started"
bv_sweep -
if bv_closed; then bad "second sweep, seconds later: closed"; else ok "second sweep, seconds later -> still NOT closed"; fi
eq "...and it does not re-stamp (the first sight is the start)" "$(bv_updates)" "0"
bv_age_all 2000
bv_sweep -
if bv_closed && bv_backstop; then ok "2000 s after first sight: closed as a BACKSTOP"; else bad "2000 s after first sight: not closed as a backstop"; fi

BV_DRY=1; bv_fixture 5000 "$PASSED" - -; bv_sweep -; BV_DRY=0
if bv_closed; then bad "dry-run closed an unstamped story"; else ok "dry-run: unstamped story NOT closed"; fi
eq "dry-run writes nothing to the story (no update call)" "$(bv_updates)" "0"
eq "...no first-seen stamp stored"        "$(bv_meta gate.passed_seen_at)" ""
grep -qF 'WOULD-STAMP-STORY ga-fixture1' "$BV_OUT" && ok "...the log says what it would have stamped" || bad "...dry-run is silent about the stamp"

BV_UPDATE_FAILS=1; bv_fixture 5000 "$PASSED" - -; bv_sweep -; BV_UPDATE_FAILS=
if bv_closed; then bad "stamp write failed (bd update refuses): the story was closed anyway"; else ok "first-seen stamp cannot be written -> story NOT closed (no clock = no close)"; fi
grep -qF 'could not write gate.passed_seen_at' "$BV_OUT" && ok "...and the log says the stamp failed" || bad "...the failed stamp is invisible in the log"

echo ""
echo "── gate-fix 1: the sweep's story list failing is not invisible ──"
BV_LIST_FAILS=1; bv_fixture 5000 "$PASSED" - -; bv_sweep -; BV_LIST_FAILS=
if bv_closed; then bad "story list failed: a story was closed"; else ok "story list fails -> nothing closed"; fi
grep -qF 'could not list open story:approved' "$BV_OUT" && ok "...and the log says the list failed" || bad "...a failed story list is silent in the log (looks like 'no stories')"

echo ""
echo "── gate-fix 1: the sweep against stamped fixtures ──"
# The decisive pair: updated_at is OLD (5000 s), the hand-off stamp is NEW (60 s). Before the fix: closed.
bv_run 5000 "$PASSED" 600 60
if bv_closed; then bad "stamp 60 s old, updated_at 5000 s old, grace 600: CLOSED (counted from the unrelated earlier write)"; else ok "stamp 60 s old, updated_at 5000 s old, grace 600 -> NOT closed"; fi
bv_run 5000 "$PASSED" 600 900
if bv_closed && bv_backstop; then ok "stamp 900 s old, updated_at 5000 s old, grace 600 -> closed as a backstop"; else bad "stamp 900 s old, grace 600: not closed as a backstop"; fi
bv_run 60 "$PASSED" 600 900
if bv_closed; then bad "updated_at 60 s old, stamp 900 s old, grace 600: closed (a later write must postpone, never hasten)"; else ok "updated_at 60 s old, stamp 900 s old, grace 600 -> NOT closed (updated_at can only postpone)"; fi
bv_run 5000 "$PASSED" 600 GARBAGE
if bv_closed; then bad "unreadable hand-off stamp: closed"; else ok "garbage gate.passed_at -> NOT closed"; fi
grep -qF 'state=unknown' "$BV_OUT" && ok "...the log names the unreadable state" || bad "...an unreadable stamp is kept silently"
bv_run 5000 "$PASSED" 600 - 60
if bv_closed; then bad "first-seen 60 s ago, grace 600: closed"; else ok "no hand-off stamp, first seen 60 s ago, grace 600 -> NOT closed"; fi
bv_run 5000 "$PASSED" 600 - 900
if bv_closed && bv_backstop; then ok "no hand-off stamp, first seen 900 s ago, grace 600 -> closed as a backstop"; else bad "first seen 900 s ago, grace 600: not closed as a backstop"; fi
bv_run GARBAGE "$PASSED" 600 5000
if bv_closed; then bad "unreadable updated_at with an old stamp: closed"; else ok "garbage updated_at + old stamp -> NOT closed (an unreadable row is not decided on)"; fi

echo ""
echo "── ga-botvu2: the REAL sweep, stubbed bd/gc + a real git fixture (the acceptance scenarios) ──"
# The bead's own numbers (grace 600): 60 s -> the janitor leaves it; 900 s -> it closes it, marked.
bv_run 60 "$PASSED" 600
if bv_closed; then bad "approved+passed, 60 s old, grace 600: the janitor CLOSED the story before delivery (the bug)"; else ok "approved+passed, 60 s old, grace 600 -> NOT closed"; fi
grep -qF 'gate-passed-awaiting-delivery-grace' "$BV_OUT" && ok "...and the log says why (awaiting delivery grace)" || bad "the keep is not explained in the log"
bv_run 900 "$PASSED" 600
if bv_closed; then ok "approved+passed, 900 s old, grace 600 -> closed"; else bad "approved+passed, 900 s old, grace 600: not closed (the backstop never fires)"; fi
if bv_backstop; then ok "...with the delivery:janitor-backstop label"; else bad "...but WITHOUT the delivery:janitor-backstop label"; fi
if bv_unverified; then ok "...and a close reason that says the deploy was NOT verified"; else bad "...but the close reason does not say the deploy was unverified"; fi
grep -qE ' label add ga-fixture1 story:done' "$BV_LOG" && ok "...story:done is still set (consumers that route on it keep working)" || bad "story:done not set on the backstop close"

# The shipped default (1800 s): 900 s is still inside one delivery pass's worst case -> keep.
bv_run 900 "$PASSED" -
if bv_closed; then bad "default grace: 900 s old story closed — a delivery pass can legitimately take 1546 s"; else ok "default grace (1800 s): 900 s old -> NOT closed"; fi
bv_run 2000 "$PASSED" -
if bv_closed && bv_backstop; then ok "default grace: 2000 s old -> closed as a backstop"; else bad "default grace: 2000 s old story not closed as a backstop (closed=$(bv_closed && echo y || echo n), label=$(bv_backstop && echo y || echo n))"; fi

# Not gate-passed -> the story was never queued for delivery: unchanged behaviour, no backstop mark.
bv_run 60 "story:approved" 600 -
if bv_closed; then ok "approved WITHOUT gate:passed + merge evidence, 60 s old -> closed as before"; else bad "approved without gate:passed no longer closes (regression of ga-gosfs)"; fi
if bv_backstop; then bad "a story that was never gate-passed got the backstop label"; else ok "...and without the backstop label"; fi
eq "...and the janitor wrote nothing to it that it would not have before (no stamp)" "$(bv_updates)" "0"

# Delivery owns it -> kept at any age.
bv_run 5000 "$PASSED delivery:running" 600
if bv_closed; then bad "delivery:running story closed at 5000 s"; else ok "gate:passed + delivery:running, 5000 s old -> NOT closed (delivery owns it)"; fi

# An age the janitor cannot compute keeps the story, however old it may really be.
bv_run EMPTY "$PASSED" 600
if bv_closed; then bad "story with an EMPTY updated_at was closed (empty read as 'old')"; else ok "gate:passed + empty updated_at -> NOT closed"; fi
bv_run GARBAGE "$PASSED" 600
if bv_closed; then bad "story with an unparseable updated_at was closed"; else ok "gate:passed + unparseable updated_at -> NOT closed"; fi
grep -qF 'state=unknown' "$BV_OUT" && ok "...and the log names the unreadable state" || bad "an unreadable age is kept silently"
bv_run 5000 "$PASSED" "ten-minutes"
if bv_closed; then bad "an unparseable grace setting dropped the wait and closed the story"; else ok "gate:passed + non-numeric grace setting -> NOT closed (the typo holds, loudly)"; fi

echo ""
echo "── ga-26jevvc: the sweeps read EVERY in_progress / open story:in-flight bead — bd list cuts at 50 ──"
# `bd list` returns at most 50 rows unless told otherwise, and says so only on stderr (ga-21kmp), so a sweep that
# lists without --limit 0 never sees the 51st bead of a rig. Three layers: a class guard over the janitor's text,
# one pin per sweep read, and the REAL sweep against a stub bd that has bd's real cut-off with the merged bead
# sitting at position 51. `--all` is exempt: measured on the live store, `bd list --all` returns everything
# (5642 gate markers, no --limit), which is why markers_for_bead is not on the list.
# vazio → the janitor has no bd list line the pattern knows (the guard would pass having looked at nothing):
# that is its own failure below, never an "ok"; falhou/ilegível → same empty, same failure.
LIST_LINES=$(grep -nE 'bd -C [^|]*[[:space:]]list[[:space:]]' "$JANITOR" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
LIST_N=$(printf '%s\n' "$LIST_LINES" | grep -c . || true)
UNBOUNDED=$(printf '%s\n' "$LIST_LINES" | grep -e '--json' | grep -vE -e '--limit 0|--all' || true)
if [ "${LIST_N:-0}" -lt 3 ]; then
  bad "class guard looked at only ${LIST_N:-0} bd list line(s) (the janitor has 5 today): the pattern no longer matches how the janitor calls bd, so a pass here would prove nothing"
elif [ -z "$UNBOUNDED" ]; then ok "class guard: all $LIST_N bd list --json lines in the janitor carry --limit 0 (or --all)"
else bad "class guard: bd list --json without --limit 0/--all (cut at 50, silently): $UNBOUNDED"; fi
grep -qF 'list --status in_progress --limit 0 --json' "$JANITOR" \
  && ok "the in_progress read is unbounded (--limit 0)" || bad "the in_progress read lost --limit 0"

LIM="$T/ga26jevvc"; mkdir -p "$LIM"; LIM_N=0
# lim_fixture <inflight|inprog> <total> <merged_index> — a fresh run dir $LIM_D: a rig clone whose origin/main holds
# "fix(<merged id>): merged work", and <total> beads ga-lm001.. all in the bucket under test. ONLY bead number
# <merged_index> has merge evidence (a bug), so the janitor closes exactly that one iff it gets to see it. The
# others are EPICS: they exist to push the merged bead past the cut, so the janitor never closes one by accident
# (it never closes an epic) and skips the commit/branch scans for them. A 51-bead sweep still costs ~35 s on the
# mini under its usual load (measured 31/10: ~60 s with bugs as filler, ~35 s with epics) — process forks per
# bead, which the scenarios below pay twice; the controls use 5 beads for that reason.
# The stub bd cuts `list` at 50 unless --limit 0 / --all (bd 1.1.0 as measured), and the stub notify keeps THESE
# sweeps from pushing a real notification to the Athos (the older botvu2 scenarios above stub gc and bd but not
# notify, so a run without a notify stub in the caller's PATH can still push one from there).
lim_fixture() {
  local bucket="$1" total="$2" idx="$3" status labels
  LIM_N=$((LIM_N+1)); LIM_D="$LIM/run$LIM_N"; LIM_MID=$(printf 'ga-lm%03d' "$idx")
  mkdir -p "$LIM_D/bin" "$LIM_D/city/.gc/logs"
  case "$bucket" in
    inflight) status="open";        labels='["story:in-flight"]' ;;
    inprog)   status="in_progress"; labels='[]' ;;
  esac
  git init -q --bare -b main "$LIM_D/origin.git"
  git init -q -b main "$LIM_D/rig"
  ( cd "$LIM_D/rig" && echo a > a && git add a \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m base \
    && echo b > b && git add b \
    && git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q -m "fix($LIM_MID): merged work" \
    && git remote add origin "$LIM_D/origin.git" && git push -q origin main ) >/dev/null 2>&1
  jq -n --argjson n "$total" --argjson mi "$idx" --arg st "$status" --argjson lb "$labels" \
    '[range(1; $n+1) | {id: ("ga-lm" + ((1000+.)|tostring|.[1:])), title: "fixture bead", issue_type: (if . == $mi then "bug" else "epic" end), status: $st, assignee: "", labels: $lb}]' > "$LIM_D/beads.json"
  cat > "$LIM_D/bin/gc" <<STUB
#!/usr/bin/env bash
if [ "\$3" = "rig" ] && [ "\$4" = "list" ]; then
  printf '{"rigs":[{"name":"limrig","prefix":"ga","path":"$LIM_D/rig","default_branch":"main","hq":false}]}'
fi
exit 0
STUB
  printf '#!/bin/sh\nexit 0\n' > "$LIM_D/bin/notify"
  cat > "$LIM_D/bin/bd" <<'STUB'
#!/usr/bin/env bash
D="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s\n' "$*" >> "$D/bd.log"
[ "${1:-}" = "-C" ] && shift 2
cmd="${1:-}"
case "$cmd" in
  list)
    # The fixture holds no gate markers, and markers_for_bead asks once per bead: answer without the jq forks.
    case " $* " in *" type:quality-gate-marker "*) printf '[]'; exit 0 ;; esac
    shift; st=""; lim=""; all=0; lbl=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --status)   st="$2"; shift ;;
        --limit|-n) lim="$2"; shift ;;
        -l)         lbl+=("$2"); shift ;;
        --all)      all=1 ;;
      esac
      shift
    done
    if [ -z "$lim" ]; then if [ "$all" = "1" ]; then lim=0; else lim=50; fi; fi
    lj=$(printf '%s\n' "${lbl[@]:-}" | jq -R . | jq -sc 'map(select(length > 0))')
    jq -c --arg st "$st" --argjson all "$all" --argjson want "$lj" --argjson lim "$lim" '
      [.[] | . as $b | select(($all == 1 or $b.status != "closed") and ($st == "" or $b.status == $st)
                              and ($want | all(. as $l | (($b.labels // []) | index($l)) != null)))]
      | if $lim == 0 then . else .[0:$lim] end' "$D/beads.json" ;;
  show)     jq -c --arg id "${2:-}" '[.[] | select(.id == $id)]' "$D/beads.json" ;;
  comments) printf '[]' ;;
  close)    jq --arg id "${2:-}" 'map(if .id == $id then .status = "closed" else . end)' "$D/beads.json" > "$D/beads.tmp" \
              && mv "$D/beads.tmp" "$D/beads.json" ;;
esac
exit 0
STUB
  chmod +x "$LIM_D/bin/gc" "$LIM_D/bin/bd" "$LIM_D/bin/notify"; : > "$LIM_D/bd.log"
}
# lim_sweep — one real janitor run against $LIM_D. LIM_LOG = the bd calls of this run; LIM_OUT = the janitor's log.
lim_sweep() {
  LIM_OUT="$LIM_D/out.log"; LIM_LOG="$LIM_D/bd.log"; : > "$LIM_LOG"
  env GC_CITY_PATH="$LIM_D/city" JANITOR_LOG_STDOUT=1 JANITOR_DRY_RUN=0 PATH="$LIM_D/bin:$PATH" bash "$JANITOR" > "$LIM_OUT" 2>&1
}
lim_closed() { grep -qE " close $LIM_MID( |\$)" "$LIM_LOG"; }
lim_closes() { grep -cE ' close ga-lm' "$LIM_LOG" || true; }

# The control first: a merged bead inside the first 50 closes in any version — proves the fixture, stub and sweep work.
lim_fixture inflight 5 3; lim_sweep
if lim_closed; then ok "control: 5 in-flight beads, the merged one is #3 -> closed"; else bad "control: in-flight fixture does not close its merged bead (#3) — the harness is broken, not the janitor"; fi
eq "...and only that one was closed" "$(lim_closes)" "1"
lim_fixture inprog 5 3; lim_sweep
if lim_closed; then ok "control: 5 in_progress beads, the merged one is #3 -> closed"; else bad "control: in_progress fixture does not close its merged bead (#3) — the harness is broken, not the janitor"; fi
eq "...and only that one was closed" "$(lim_closes)" "1"

# The bug: the merged bead is #51 — past the cut. Only an unbounded read reaches it.
lim_fixture inflight 51 51; lim_sweep
grep -qF 'rig limrig (ga): 51 open story:in-flight bead(s)' "$LIM_OUT" \
  && ok "in-flight sweep counted all 51 beads" || bad "in-flight sweep did not see 51 beads (bd list cut at 50): $(grep -F 'story:in-flight bead(s)' "$LIM_OUT" | head -1)"
if lim_closed; then ok "the 51st open story:in-flight bead (merged) is closed"; else bad "the 51st open story:in-flight bead was never swept — bd list cut at 50"; fi
eq "...and only that one was closed" "$(lim_closes)" "1"
lim_fixture inprog 51 51; lim_sweep
grep -qF 'rig limrig (ga): 51 in_progress bead(s)' "$LIM_OUT" \
  && ok "in_progress sweep counted all 51 beads" || bad "in_progress sweep did not see 51 beads (bd list cut at 50): $(grep -F 'in_progress bead(s)' "$LIM_OUT" | head -1)"
if lim_closed; then ok "the 51st in_progress bead (merged) is closed"; else bad "the 51st in_progress bead was never swept — bd list cut at 50"; fi
eq "...and only that one was closed" "$(lim_closes)" "1"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
