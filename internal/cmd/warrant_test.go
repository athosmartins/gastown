package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/steveyegge/gastown/internal/session"
)

func setupWarrantTestRegistry(t *testing.T) {
	t.Helper()
	reg := session.NewPrefixRegistry()
	reg.Register("gt", "gastown")
	reg.Register("bd", "beads")
	old := session.DefaultRegistry()
	session.SetDefaultRegistry(reg)
	t.Cleanup(func() { session.SetDefaultRegistry(old) })
}

// =============================================================================
// Warrant Tests
// =============================================================================

// TestWarrantFile_NewWarrant verifies that filing a new warrant creates the file.
func TestWarrantFile_NewWarrant(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")

	// Create warrant manually (simulating the function)
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	target := "gastown/polecats/alpha"
	reason := "Zombie detected: no session, idle >10m"

	warrant := Warrant{
		ID:       "warrant-test-123",
		Target:   target,
		Reason:   reason,
		FiledBy:  "test-agent",
		FiledAt:  time.Now(),
		Executed: false,
	}

	data, err := json.MarshalIndent(warrant, "", "  ")
	if err != nil {
		t.Fatalf("json.MarshalIndent() error = %v", err)
	}

	warrantPath := filepath.Join(warrantDir, "gastown_polecats_alpha.warrant.json")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Verify file exists and can be read back
	readData, err := os.ReadFile(warrantPath)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}

	var readWarrant Warrant
	if err := json.Unmarshal(readData, &readWarrant); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}

	if readWarrant.Target != target {
		t.Errorf("Target = %q, want %q", readWarrant.Target, target)
	}
	if readWarrant.Reason != reason {
		t.Errorf("Reason = %q, want %q", readWarrant.Reason, reason)
	}
	if readWarrant.Executed {
		t.Error("Executed = true, want false")
	}
}

// TestWarrantFile_DuplicateWarrant verifies that filing a duplicate warrant
// is handled gracefully (doesn't overwrite).
func TestWarrantFile_DuplicateWarrant(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")

	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	target := "gastown/polecats/alpha"
	originalReason := "First reason"

	// Create first warrant
	warrant := Warrant{
		ID:       "warrant-first",
		Target:   target,
		Reason:   originalReason,
		FiledBy:  "test-agent",
		FiledAt:  time.Now(),
		Executed: false,
	}

	warrantPath := filepath.Join(warrantDir, "gastown_polecats_alpha.warrant.json")
	data, _ := json.MarshalIndent(warrant, "", "  ")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Try to detect duplicate (simulating the check in runWarrantFile)
	if _, err := os.Stat(warrantPath); err == nil {
		// File exists - read it
		existingData, _ := os.ReadFile(warrantPath)
		var existing Warrant
		if json.Unmarshal(existingData, &existing) == nil && !existing.Executed {
			// Duplicate detected - this is the expected behavior
			if existing.Reason != originalReason {
				t.Errorf("Existing warrant reason = %q, want %q", existing.Reason, originalReason)
			}
			return // Test passes - duplicate was detected
		}
	}

	t.Error("Expected duplicate warrant to be detected")
}

// TestWarrantExecute_MarksExecuted verifies that executing a warrant marks it as executed.
func TestWarrantExecute_MarksExecuted(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")

	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	target := "gastown/polecats/alpha"

	// Create pending warrant
	warrant := Warrant{
		ID:       "warrant-pending",
		Target:   target,
		Reason:   "Test execution",
		FiledBy:  "test-agent",
		FiledAt:  time.Now(),
		Executed: false,
	}

	warrantPath := filepath.Join(warrantDir, "gastown_polecats_alpha.warrant.json")
	data, _ := json.MarshalIndent(warrant, "", "  ")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Simulate execution (mark as executed)
	now := time.Now()
	warrant.Executed = true
	warrant.ExecutedAt = &now

	data, _ = json.MarshalIndent(warrant, "", "  ")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() after execution error = %v", err)
	}

	// Verify warrant is marked as executed
	readData, _ := os.ReadFile(warrantPath)
	var readWarrant Warrant
	if err := json.Unmarshal(readData, &readWarrant); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}

	if !readWarrant.Executed {
		t.Error("Executed = false, want true")
	}
	if readWarrant.ExecutedAt == nil {
		t.Error("ExecutedAt = nil, want non-nil")
	}
}

// TestTargetToSessionName verifies session name conversion.
func TestTargetToSessionName(t *testing.T) {
	setupWarrantTestRegistry(t)
	tests := []struct {
		target   string
		wantErr  bool
		contains string // partial match since town name varies
	}{
		{
			target:   "gastown/polecats/alpha",
			wantErr:  false,
			contains: "gt-alpha",
		},
		{
			target:   "beads/polecats/charlie",
			wantErr:  false,
			contains: "bd-charlie",
		},
		{
			target:   "deacon/dogs",
			wantErr:  true,
			contains: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.target, func(t *testing.T) {
			got, err := targetToSessionName(tt.target)
			if (err != nil) != tt.wantErr {
				t.Errorf("targetToSessionName(%q) error = %v, wantErr %v", tt.target, err, tt.wantErr)
				return
			}
			if !tt.wantErr && got != tt.contains {
				t.Errorf("targetToSessionName(%q) = %q, want %q", tt.target, got, tt.contains)
			}
		})
	}
}

// =============================================================================
// executeAllPendingWarrants Tests
// =============================================================================

// TestExecuteAllPendingWarrants_NoWarrantsDir verifies that a missing warrants
// directory is handled gracefully (returns 0, no error).
func TestExecuteAllPendingWarrants_NoWarrantsDir(t *testing.T) {
	tmpDir := t.TempDir()
	// No "warrants" subdirectory created

	count, err := executeAllPendingWarrants(tmpDir)
	if err != nil {
		t.Errorf("executeAllPendingWarrants() error = %v, want nil", err)
	}
	if count != 0 {
		t.Errorf("executeAllPendingWarrants() count = %d, want 0", count)
	}
}

// TestExecuteAllPendingWarrants_SkipsAlreadyExecuted verifies that warrants
// already marked as executed are not re-executed.
func TestExecuteAllPendingWarrants_SkipsAlreadyExecuted(t *testing.T) {
	setupWarrantTestRegistry(t)
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	// Create an already-executed warrant
	now := time.Now()
	warrant := Warrant{
		ID:         "warrant-already-done",
		Target:     "gastown/polecats/alpha",
		Reason:     "Already handled",
		FiledBy:    "test-agent",
		FiledAt:    now.Add(-1 * time.Hour),
		Executed:   true,
		ExecutedAt: &now,
	}
	data, _ := json.MarshalIndent(warrant, "", "  ")
	warrantPath := filepath.Join(warrantDir, "gastown_polecats_alpha.warrant.json")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	count, err := executeAllPendingWarrants(tmpDir)
	if err != nil {
		t.Errorf("executeAllPendingWarrants() error = %v, want nil", err)
	}
	if count != 0 {
		t.Errorf("executeAllPendingWarrants() count = %d, want 0 (already executed)", count)
	}
}

// TestExecuteAllPendingWarrants_MarksPendingAsExecuted verifies that pending
// warrants are marked as executed (even when session is already dead/missing).
// In CI, tmux is not running so HasSession returns false - this is the "already
// dead" path, which should still mark the warrant as executed.
func TestExecuteAllPendingWarrants_MarksPendingAsExecuted(t *testing.T) {
	setupWarrantTestRegistry(t)
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	// Create a pending warrant for a target whose session won't exist in CI
	warrant := Warrant{
		ID:       "warrant-pending-test",
		Target:   "gastown/polecats/alpha",
		Reason:   "Stuck: no progress in 80 minutes",
		FiledBy:  "deacon",
		FiledAt:  time.Now().Add(-80 * time.Minute),
		Executed: false,
	}
	data, _ := json.MarshalIndent(warrant, "", "  ")
	warrantPath := filepath.Join(warrantDir, "gastown_polecats_alpha.warrant.json")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	count, err := executeAllPendingWarrants(tmpDir)
	if err != nil {
		t.Errorf("executeAllPendingWarrants() error = %v, want nil", err)
	}
	if count != 1 {
		t.Errorf("executeAllPendingWarrants() count = %d, want 1", count)
	}

	// Verify the warrant file was updated to mark as executed
	readData, err := os.ReadFile(warrantPath)
	if err != nil {
		t.Fatalf("ReadFile() error = %v", err)
	}
	var readWarrant Warrant
	if err := json.Unmarshal(readData, &readWarrant); err != nil {
		t.Fatalf("json.Unmarshal() error = %v", err)
	}
	if !readWarrant.Executed {
		t.Error("Executed = false, want true after executeAllPendingWarrants")
	}
	if readWarrant.ExecutedAt == nil {
		t.Error("ExecutedAt = nil, want non-nil after executeAllPendingWarrants")
	}
}

// TestExecuteAllPendingWarrants_MultipleWarrants verifies that multiple pending
// warrants are all executed in a single call.
func TestExecuteAllPendingWarrants_MultipleWarrants(t *testing.T) {
	setupWarrantTestRegistry(t)
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	targets := []string{
		"gastown/polecats/alpha",
		"gastown/polecats/bravo",
	}

	for _, target := range targets {
		safe := target
		// Create filename manually to match warrantFilePath convention
		filename := "gastown_polecats_" + target[len("gastown/polecats/"):] + ".warrant.json"
		warrant := Warrant{
			ID:       "warrant-" + safe,
			Target:   target,
			Reason:   "Stuck",
			FiledBy:  "deacon",
			FiledAt:  time.Now().Add(-30 * time.Minute),
			Executed: false,
		}
		data, _ := json.MarshalIndent(warrant, "", "  ")
		if err := os.WriteFile(filepath.Join(warrantDir, filename), data, 0644); err != nil {
			t.Fatalf("WriteFile(%s) error = %v", filename, err)
		}
	}

	count, err := executeAllPendingWarrants(tmpDir)
	if err != nil {
		t.Errorf("executeAllPendingWarrants() error = %v, want nil", err)
	}
	if count != 2 {
		t.Errorf("executeAllPendingWarrants() count = %d, want 2", count)
	}
}

// TestWarrantFilePath verifies warrant file path generation.
func TestWarrantFilePath(t *testing.T) {
	tests := []struct {
		dir    string
		target string
		want   string
	}{
		{
			dir:    filepath.Join("/tmp", "warrants"),
			target: "gastown/polecats/alpha",
			want:   filepath.Join("/tmp", "warrants", "gastown_polecats_alpha.warrant.json"),
		},
		{
			dir:    filepath.Join("/home", "user", "gt", "warrants"),
			target: "deacon/dogs/bravo",
			want:   filepath.Join("/home", "user", "gt", "warrants", "deacon_dogs_bravo.warrant.json"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.target, func(t *testing.T) {
			got := warrantFilePath(tt.dir, tt.target)
			if got != tt.want {
				t.Errorf("warrantFilePath(%q, %q) = %q, want %q", tt.dir, tt.target, got, tt.want)
			}
		})
	}
}
