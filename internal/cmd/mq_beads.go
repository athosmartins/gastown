package cmd

import (
	"github.com/steveyegge/gastown/internal/beads"
	"github.com/steveyegge/gastown/internal/rig"
)

// newRigBeadsClient returns a beads wrapper bound to the rig's actual database.
//
// Prefers r.BeadsDir() (resolved by name via doltserver.FindRigBeadsDir) over
// rig-root .beads/metadata.json so MR queries reach the same database that
// upstream PR #3540 routes writes to. Rigs whose rig-root metadata still
// points at the HQ database (e.g., legacy WA setup with dolt_database = "hq")
// would otherwise have their MR list/scan operations silently miss every
// rig-prefixed MR. Falls back to beads.New(r.BeadsPath()) when BeadsDir() is
// unavailable (defensive — should not happen for a configured rig). (gt-7y7)
func newRigBeadsClient(r *rig.Rig) *beads.Beads {
	if dir := r.BeadsDir(); dir != "" {
		return beads.NewWithBeadsDir(r.Path, dir)
	}
	return beads.New(r.BeadsPath())
}
