package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/steveyegge/gastown/internal/migration"
)

// makeMigrateTownRoot creates a minimal fake Gas Town root in a temp dir,
// cds into it, and registers cleanup. Sets BuiltProperly so persistentPreRun
// doesn't os.Exit on macOS dev builds.
func makeMigrateTownRoot(t *testing.T) string {
	t.Helper()
	orig := BuiltProperly
	BuiltProperly = "1"
	t.Cleanup(func() { BuiltProperly = orig })

	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "mayor"), 0755); err != nil {
		t.Fatalf("makeMigrateTownRoot mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "mayor", "town.json"), []byte("{}"), 0644); err != nil {
		t.Fatalf("makeMigrateTownRoot write town.json: %v", err)
	}

	origDir, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatalf("makeMigrateTownRoot Chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(origDir) })
	return root
}

func TestMigrateFreeze_DoubleFreeze(t *testing.T) {
	// double-freeze should be a short-circuit no-op (returns nil, not an error).
	root := makeMigrateTownRoot(t)
	if err := migration.Freeze(root, "op1", "first freeze"); err != nil {
		t.Fatalf("initial Freeze: %v", err)
	}

	// Second freeze should not overwrite or error.
	if err := migration.Freeze(root, "op2", "second freeze"); err != nil {
		t.Errorf("second Freeze returned error: %v", err)
	}

	// The sentinel should still exist after the second freeze call.
	if !migration.IsFrozen(root) {
		t.Error("expected still frozen after double freeze")
	}

	// Verify the runMigrateFreeze command detects the already-active freeze.
	origDir, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(origDir) })

	// runMigrateFreeze should return nil (short-circuit, not an error).
	if err := runMigrateFreeze(migrateFreezeCmd, nil); err != nil {
		t.Errorf("runMigrateFreeze when already frozen: %v", err)
	}
}

func TestMigrateThaw_WhenNotFrozen(t *testing.T) {
	root := makeMigrateTownRoot(t)

	origDir, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(origDir) })

	// Thaw when not frozen should return nil (idempotent).
	if err := runMigrateThaw(migrateThawCmd, nil); err != nil {
		t.Errorf("runMigrateThaw when not frozen: %v", err)
	}
}
