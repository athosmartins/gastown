package rig

import (
	"os"
	"path/filepath"
	"testing"
)

// TestBeadsDir_PrefersMayorRig verifies that BeadsDir resolves to the
// canonical mayor/rig/.beads directory when it exists, regardless of what
// the rig-root .beads/metadata.json says.
func TestBeadsDir_PrefersMayorRig(t *testing.T) {
	t.Parallel()

	townRoot := t.TempDir()
	rigName := "wa"
	rigPath := filepath.Join(townRoot, rigName)

	// Create the canonical rig beads dir
	mayorBeads := filepath.Join(rigPath, "mayor", "rig", ".beads")
	if err := os.MkdirAll(mayorBeads, 0o755); err != nil {
		t.Fatalf("mkdir mayor/rig/.beads: %v", err)
	}

	// Also create a rig-root .beads (legacy / misconfigured)
	rigRootBeads := filepath.Join(rigPath, ".beads")
	if err := os.MkdirAll(rigRootBeads, 0o755); err != nil {
		t.Fatalf("mkdir rig-root .beads: %v", err)
	}

	r := &Rig{Name: rigName, Path: rigPath}
	got := r.BeadsDir()
	if got != mayorBeads {
		t.Errorf("BeadsDir() = %q, want %q (canonical mayor/rig/.beads)", got, mayorBeads)
	}
}

// TestBeadsDir_FallbackToRigRoot verifies that BeadsDir falls back to
// <rig>/.beads when mayor/rig/.beads does not exist.
func TestBeadsDir_FallbackToRigRoot(t *testing.T) {
	t.Parallel()

	townRoot := t.TempDir()
	rigName := "lc"
	rigPath := filepath.Join(townRoot, rigName)

	rigRootBeads := filepath.Join(rigPath, ".beads")
	if err := os.MkdirAll(rigRootBeads, 0o755); err != nil {
		t.Fatalf("mkdir rig-root .beads: %v", err)
	}

	r := &Rig{Name: rigName, Path: rigPath}
	got := r.BeadsDir()
	if got != rigRootBeads {
		t.Errorf("BeadsDir() = %q, want %q (rig-root fallback)", got, rigRootBeads)
	}
}

// TestBeadsDir_HQReturnsTownBeads verifies the special-cased "hq" rig name
// resolves to the town-level .beads directory.
func TestBeadsDir_HQReturnsTownBeads(t *testing.T) {
	t.Parallel()

	townRoot := t.TempDir()
	r := &Rig{Name: "hq", Path: filepath.Join(townRoot, "hq")}
	got := r.BeadsDir()
	want := filepath.Join(townRoot, ".beads")
	if got != want {
		t.Errorf("BeadsDir() = %q, want %q", got, want)
	}
}

// TestBeadsDir_EmptyForUnconfiguredRig verifies BeadsDir returns "" when
// the Rig is not properly configured (nil, empty Name, or empty Path).
func TestBeadsDir_EmptyForUnconfiguredRig(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name string
		rig  *Rig
	}{
		{"nil", nil},
		{"empty name", &Rig{Path: "/some/path"}},
		{"empty path", &Rig{Name: "rig"}},
		{"both empty", &Rig{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := tc.rig.BeadsDir()
			if got != "" {
				t.Errorf("BeadsDir() = %q, want \"\"", got)
			}
		})
	}
}
