package migration_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/steveyegge/gastown/internal/migration"
)

func TestFreezeReadThawRoundtrip(t *testing.T) {
	dir := t.TempDir()

	if migration.IsFrozen(dir) {
		t.Fatal("expected not frozen initially")
	}
	if info := migration.Read(dir); info != nil {
		t.Fatal("expected Read to return nil when not frozen")
	}

	if err := migration.Freeze(dir, "operator1", "test reason"); err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if !migration.IsFrozen(dir) {
		t.Fatal("expected frozen after Freeze")
	}

	info := migration.Read(dir)
	if info == nil {
		t.Fatal("expected Read to return non-nil after Freeze")
	}
	if info.Operator != "operator1" {
		t.Errorf("Operator = %q, want %q", info.Operator, "operator1")
	}
	if info.Reason != "test reason" {
		t.Errorf("Reason = %q, want %q", info.Reason, "test reason")
	}
	if info.Timestamp.IsZero() {
		t.Error("expected non-zero Timestamp")
	}
	if time.Since(info.Timestamp) > 5*time.Second {
		t.Errorf("Timestamp too old: %v", info.Timestamp)
	}
	if info.PID == 0 {
		t.Error("expected non-zero PID after Freeze")
	}

	if err := migration.Thaw(dir); err != nil {
		t.Fatalf("Thaw: %v", err)
	}
	if migration.IsFrozen(dir) {
		t.Fatal("expected not frozen after Thaw")
	}
	if info := migration.Read(dir); info != nil {
		t.Fatal("expected Read to return nil after Thaw")
	}
}

func TestReadMissingFileReturnsNil(t *testing.T) {
	dir := t.TempDir()
	info := migration.Read(dir)
	if info != nil {
		t.Errorf("Read on missing file = %v, want nil", info)
	}
}

func TestThawIdempotent(t *testing.T) {
	dir := t.TempDir()

	// Thaw when not frozen should be a no-op.
	if err := migration.Thaw(dir); err != nil {
		t.Errorf("Thaw when not frozen: %v", err)
	}

	// Freeze then thaw twice.
	if err := migration.Freeze(dir, "op", ""); err != nil {
		t.Fatalf("Freeze: %v", err)
	}
	if err := migration.Thaw(dir); err != nil {
		t.Fatalf("first Thaw: %v", err)
	}
	if err := migration.Thaw(dir); err != nil {
		t.Errorf("second Thaw (idempotent): %v", err)
	}
}

func TestParseMalformedContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, migration.FileName)

	cases := []struct {
		name    string
		content string
	}{
		{"empty file", ""},
		{"only operator", "op"},
		{"bad timestamp", "op\tnot-a-time\treason"},
		{"extra tabs", "op\t2026-01-01T00:00:00Z\treason\textra"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.WriteFile(path, []byte(tc.content), 0600); err != nil {
				t.Fatalf("WriteFile: %v", err)
			}
			// Should not panic; returns a non-nil Info
			info := migration.Read(dir)
			if info == nil && tc.content != "" {
				t.Errorf("Read(%q) = nil, want non-nil", tc.content)
			}
		})
	}
}
