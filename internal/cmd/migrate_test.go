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
	// NOTE: cannot use t.Parallel() — mutates cwd.
	makeMigrateTownRoot(t)

	// First freeze succeeds.
	migrateFreezeReason = "test"
	migrateFreezeOperator = "op1"
	t.Cleanup(func() {
		migrateFreezeReason = ""
		migrateFreezeOperator = ""
	})
	if err := runMigrateFreeze(migrateFreezeCmd, nil); err != nil {
		t.Fatalf("first freeze: %v", err)
	}

	// Second freeze should short-circuit and return nil (not an error).
	if err := runMigrateFreeze(migrateFreezeCmd, nil); err != nil {
		t.Errorf("double freeze returned error: %v", err)
	}
}

func TestMigrateThaw_WhenNotFrozen(t *testing.T) {
	// Thaw when not frozen should be a no-op (returns nil).
	// NOTE: cannot use t.Parallel() — mutates cwd.
	makeMigrateTownRoot(t)

	if err := runMigrateThaw(migrateThawCmd, nil); err != nil {
		t.Errorf("thaw when not frozen: %v", err)
	}
}

func TestMigrateStatus_ShowsFreezeInfo(t *testing.T) {
	// migrate status should reflect current freeze state.
	// NOTE: cannot use t.Parallel() — mutates cwd.
	root := makeMigrateTownRoot(t)

	// Not frozen: status should return nil.
	if err := runMigrateStatus(migrateStatusCmd, nil); err != nil {
		t.Errorf("status when not frozen: %v", err)
	}

	// Freeze and check status returns nil (it prints, doesn't error).
	if err := migration.Freeze(root, "testop", "schema swap"); err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if err := runMigrateStatus(migrateStatusCmd, nil); err != nil {
		t.Errorf("status when frozen: %v", err)
	}
}
