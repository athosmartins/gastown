package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBootSpawnAgentFlag(t *testing.T) {
	flag := bootSpawnCmd.Flags().Lookup("agent")
	if flag == nil {
		t.Fatal("expected boot spawn to define --agent flag")
	}
	if flag.DefValue != "" {
		t.Errorf("expected default agent override to be empty, got %q", flag.DefValue)
	}
	if !strings.Contains(flag.Usage, "overrides town default") {
		t.Errorf("expected --agent usage to mention overrides town default, got %q", flag.Usage)
	}
}

// TestSlotShowJSONParsing verifies the JSON schema for bd slot show output.
// This catches schema changes that would break getDeaconHookBead().
func TestSlotShowJSONParsing(t *testing.T) {
	// Sample output from: bd slot show hq-deacon --json
	sampleJSON := `{
		"agent": "hq-deacon",
		"slots": {
			"hook": "hq-wisp-0laki",
			"role": null
		}
	}`

	var result struct {
		Slots struct {
			Hook *string `json:"hook"`
		} `json:"slots"`
	}

	if err := json.Unmarshal([]byte(sampleJSON), &result); err != nil {
		t.Fatalf("failed to parse slot show JSON: %v", err)
	}

	if result.Slots.Hook == nil {
		t.Fatal("expected hook to be non-nil")
	}
	if *result.Slots.Hook != "hq-wisp-0laki" {
		t.Errorf("expected hook to be 'hq-wisp-0laki', got %q", *result.Slots.Hook)
	}
}

// TestSlotShowJSONParsingNoHook verifies parsing when no hook is set.
func TestSlotShowJSONParsingNoHook(t *testing.T) {
	sampleJSON := `{
		"agent": "hq-deacon",
		"slots": {
			"hook": null,
			"role": null
		}
	}`

	var result struct {
		Slots struct {
			Hook *string `json:"hook"`
		} `json:"slots"`
	}

	if err := json.Unmarshal([]byte(sampleJSON), &result); err != nil {
		t.Fatalf("failed to parse slot show JSON: %v", err)
	}

	if result.Slots.Hook != nil {
		t.Errorf("expected hook to be nil, got %q", *result.Slots.Hook)
	}
}

// TestDeaconBackoffJSONParsing verifies the JSON schema for bd show hq-deacon output.
// This catches schema changes that would break isDeaconInBackoff().
func TestDeaconBackoffJSONParsing(t *testing.T) {
	// Sample output from: bd show hq-deacon --json
	sampleJSON := `[{
		"id": "hq-deacon",
		"title": "Deacon (daemon beacon)",
		"labels": ["gt:agent", "idle:4"]
	}]`

	var result []struct {
		Labels []string `json:"labels"`
	}

	if err := json.Unmarshal([]byte(sampleJSON), &result); err != nil {
		t.Fatalf("failed to parse bd show JSON: %v", err)
	}

	if len(result) == 0 {
		t.Fatal("expected at least one result")
	}

	// Check for idle:N label
	found := false
	for _, label := range result[0].Labels {
		if len(label) >= 5 && label[:5] == "idle:" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected to find idle:N label in labels")
	}
}

// TestDeaconBackoffJSONParsingNoIdleLabel verifies parsing when no idle label is set.
func TestDeaconBackoffJSONParsingNoIdleLabel(t *testing.T) {
	sampleJSON := `[{
		"id": "hq-deacon",
		"title": "Deacon (daemon beacon)",
		"labels": ["gt:agent"]
	}]`

	var result []struct {
		Labels []string `json:"labels"`
	}

	if err := json.Unmarshal([]byte(sampleJSON), &result); err != nil {
		t.Fatalf("failed to parse bd show JSON: %v", err)
	}

	if len(result) == 0 {
		t.Fatal("expected at least one result")
	}

	// Check that no idle:N label is found
	for _, label := range result[0].Labels {
		if len(label) >= 5 && label[:5] == "idle:" {
			t.Errorf("expected no idle:N label, but found %q", label)
		}
	}
}

// TestMolCurrentJSONParsing verifies the JSON schema for bd mol current output.
// This catches schema changes that would break getMoleculeLastActivity().
func TestMolCurrentJSONParsing(t *testing.T) {
	// Sample output from: bd mol current hq-wisp-0laki --json (simplified)
	sampleJSON := `[
		{
			"molecule_id": "hq-wisp-0laki",
			"steps": [
				{
					"status": "done",
					"issue": {
						"id": "hq-step1",
						"closed_at": "2026-02-02T05:50:55Z"
					}
				},
				{
					"status": "done",
					"issue": {
						"id": "hq-step2",
						"closed_at": "2026-02-03T05:29:21Z"
					}
				},
				{
					"status": "pending",
					"issue": {
						"id": "hq-step3",
						"closed_at": null
					}
				}
			]
		}
	]`

	var molecules []struct {
		Steps []struct {
			Status string `json:"status"`
			Issue  struct {
				ClosedAt *time.Time `json:"closed_at"`
			} `json:"issue"`
		} `json:"steps"`
	}

	if err := json.Unmarshal([]byte(sampleJSON), &molecules); err != nil {
		t.Fatalf("failed to parse mol current JSON: %v", err)
	}

	if len(molecules) != 1 {
		t.Fatalf("expected 1 molecule, got %d", len(molecules))
	}
	if len(molecules[0].Steps) != 3 {
		t.Fatalf("expected 3 steps, got %d", len(molecules[0].Steps))
	}

	// Find latest closed_at among done steps
	var latest time.Time
	for _, step := range molecules[0].Steps {
		if step.Status == "done" && step.Issue.ClosedAt != nil {
			if step.Issue.ClosedAt.After(latest) {
				latest = *step.Issue.ClosedAt
			}
		}
	}

	expected, _ := time.Parse(time.RFC3339, "2026-02-03T05:29:21Z")
	if !latest.Equal(expected) {
		t.Errorf("expected latest closed_at to be %v, got %v", expected, latest)
	}
}

// =============================================================================
// executeWarrants Tests
// =============================================================================

// TestExecuteWarrants_NonExistentDir verifies graceful handling of missing warrants dir.
func TestExecuteWarrants_NonExistentDir(t *testing.T) {
	count := executeWarrants("/nonexistent/warrant/town/root")
	if count != 0 {
		t.Errorf("expected 0 executed for non-existent dir, got %d", count)
	}
}

// TestExecuteWarrants_EmptyDir verifies that an empty warrants dir returns 0.
func TestExecuteWarrants_EmptyDir(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	count := executeWarrants(tmpDir)
	if count != 0 {
		t.Errorf("expected 0 executed for empty dir, got %d", count)
	}
}

// TestExecuteWarrants_SkipsExecutedWarrants verifies already-executed warrants are ignored.
func TestExecuteWarrants_SkipsExecutedWarrants(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	now := time.Now()
	warrant := Warrant{
		ID:         "warrant-already-done",
		Target:     "gastown/polecats/test",
		Reason:     "Already handled",
		FiledBy:    "test-agent",
		FiledAt:    time.Now(),
		Executed:   true,
		ExecutedAt: &now,
	}
	data, _ := json.MarshalIndent(warrant, "", "  ")
	warrantPath := filepath.Join(warrantDir, "gastown_polecats_test.warrant.json")
	if err := os.WriteFile(warrantPath, data, 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Should skip the already-executed warrant (gt won't be called)
	count := executeWarrants(tmpDir)
	if count != 0 {
		t.Errorf("expected 0 for already-executed warrant, got %d", count)
	}
}

// TestExecuteWarrants_SkipsNonWarrantFiles verifies only .warrant.json files are processed.
func TestExecuteWarrants_SkipsNonWarrantFiles(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	// Write a non-warrant file to the directory
	if err := os.WriteFile(filepath.Join(warrantDir, "README.txt"), []byte("not a warrant"), 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	if err := os.WriteFile(filepath.Join(warrantDir, "some.json"), []byte(`{}`), 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	count := executeWarrants(tmpDir)
	if count != 0 {
		t.Errorf("expected 0 for non-warrant files, got %d", count)
	}
}

// TestExecuteWarrants_SkipsMalformedJSON verifies malformed JSON files are silently skipped.
func TestExecuteWarrants_SkipsMalformedJSON(t *testing.T) {
	tmpDir := t.TempDir()
	warrantDir := filepath.Join(tmpDir, "warrants")
	if err := os.MkdirAll(warrantDir, 0755); err != nil {
		t.Fatalf("MkdirAll() error = %v", err)
	}

	// Write malformed JSON as a .warrant.json file
	if err := os.WriteFile(filepath.Join(warrantDir, "bad.warrant.json"), []byte("not json {{{"), 0644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	// Should not panic or return an error
	count := executeWarrants(tmpDir)
	if count != 0 {
		t.Errorf("expected 0 for malformed JSON, got %d", count)
	}
}
