// Beads-related rig methods. Lives in its own file so internal/rig/types.go
// (the canonical Rig struct) doesn't need to import internal/doltserver.
package rig

import (
	"path/filepath"

	"github.com/steveyegge/gastown/internal/doltserver"
)

// BeadsDir returns the canonical .beads directory for the rig's database.
//
// Unlike BeadsPath (which returns the rig root and depends on the redirect
// system at <rig>/.beads/redirect), BeadsDir resolves directly to
// <townRoot>/<rig>/mayor/rig/.beads (or <townRoot>/<rig>/.beads as fallback)
// via doltserver.FindRigBeadsDir.
//
// Read paths (refinery scans, gt mq next, gt mq list) should prefer
//
//	beads.NewWithBeadsDir(r.Path, r.BeadsDir())
//
// over beads.New(r.BeadsPath()). The latter relies on rig-root metadata.json
// pointing at the rig's database; rigs with stale or misconfigured rig-root
// metadata (dolt_database == "hq") silently route MR queries to the wrong
// database. After upstream PR #3540 (commit 37c2b382) routed writes via
// `bd create --rig <name>` rather than via the redirect chain, that
// asymmetry caused MRs to land in the rig DB while the refinery kept
// scanning the HQ DB. (gt-7y7 follow-up)
func (r *Rig) BeadsDir() string {
	if r == nil || r.Path == "" || r.Name == "" {
		return ""
	}
	townRoot := filepath.Dir(r.Path)
	return doltserver.FindRigBeadsDir(townRoot, r.Name)
}
