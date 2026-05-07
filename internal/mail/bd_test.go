package mail

import (
	"errors"
	"strings"
	"testing"
)

func TestBdError_Error(t *testing.T) {
	tests := []struct {
		name string
		err  *bdError
		want string
	}{
		{
			name: "stderr present",
			err: &bdError{
				Err:    errors.New("some error"),
				Stderr: "stderr output",
			},
			want: "stderr output",
		},
		{
			name: "no stderr, has error",
			err: &bdError{
				Err:    errors.New("some error"),
				Stderr: "",
			},
			want: "some error",
		},
		{
			name: "no stderr, no error",
			err: &bdError{
				Err:    nil,
				Stderr: "",
			},
			want: "unknown bd error",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.err.Error()
			if got != tt.want {
				t.Errorf("bdError.Error() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestBdError_Unwrap(t *testing.T) {
	originalErr := errors.New("original error")
	bdErr := &bdError{
		Err:    originalErr,
		Stderr: "stderr output",
	}

	unwrapped := bdErr.Unwrap()
	if unwrapped != originalErr {
		t.Errorf("bdError.Unwrap() = %v, want %v", unwrapped, originalErr)
	}
}

func TestBdError_UnwrapNil(t *testing.T) {
	bdErr := &bdError{
		Err:    nil,
		Stderr: "",
	}

	unwrapped := bdErr.Unwrap()
	if unwrapped != nil {
		t.Errorf("bdError.Unwrap() with nil Err should return nil, got %v", unwrapped)
	}
}

func TestBdError_ContainsError(t *testing.T) {
	tests := []struct {
		name     string
		err      *bdError
		substr   string
		contains bool
	}{
		{
			name: "substring present",
			err: &bdError{
				Stderr: "error: bead not found",
			},
			substr:   "bead not found",
			contains: true,
		},
		{
			name: "substring not present",
			err: &bdError{
				Stderr: "error: bead not found",
			},
			substr:   "permission denied",
			contains: false,
		},
		{
			name: "empty stderr",
			err: &bdError{
				Stderr: "",
			},
			substr:   "anything",
			contains: false,
		},
		{
			name: "case sensitive",
			err: &bdError{
				Stderr: "Error: Bead Not Found",
			},
			substr:   "bead not found",
			contains: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.err.ContainsError(tt.substr)
			if got != tt.contains {
				t.Errorf("bdError.ContainsError(%q) = %v, want %v", tt.substr, got, tt.contains)
			}
		})
	}
}

func TestBdError_ContainsErrorPartialMatch(t *testing.T) {
	err := &bdError{
		Stderr: "fatal: invalid bead ID format: expected prefix-#id",
	}

	// Test partial matches
	if !err.ContainsError("invalid bead ID") {
		t.Error("Should contain partial substring")
	}
	if !err.ContainsError("fatal:") {
		t.Error("Should contain prefix")
	}
	if !err.ContainsError("expected prefix") {
		t.Error("Should contain suffix")
	}
}

func TestBdError_ContainsErrorSpecialChars(t *testing.T) {
	err := &bdError{
		Stderr: "error: bead 'gt-123' not found (exit 1)",
	}

	if !err.ContainsError("'gt-123'") {
		t.Error("Should handle quotes in substring")
	}
	if !err.ContainsError("(exit 1)") {
		t.Error("Should handle parentheses in substring")
	}
}

func TestBdError_ImplementsErrorInterface(t *testing.T) {
	// Verify bdError implements error interface
	var err error = &bdError{
		Err:    errors.New("test"),
		Stderr: "test stderr",
	}

	_ = err.Error() // Should compile and not panic
}

func TestBdError_WithAllFields(t *testing.T) {
	originalErr := errors.New("original error")
	bdErr := &bdError{
		Err:    originalErr,
		Stderr: "command failed: bead not found",
	}

	// Test Error() returns stderr
	got := bdErr.Error()
	want := "command failed: bead not found"
	if got != want {
		t.Errorf("bdError.Error() = %q, want %q", got, want)
	}

	// Test Unwrap() returns original error
	unwrapped := bdErr.Unwrap()
	if unwrapped != originalErr {
		t.Errorf("bdError.Unwrap() = %v, want %v", unwrapped, originalErr)
	}

	// Test ContainsError works
	if !bdErr.ContainsError("bead not found") {
		t.Error("ContainsError should find substring in stderr")
	}
	if bdErr.ContainsError("not present") {
		t.Error("ContainsError should return false for non-existent substring")
	}
}

// TestBdSubprocessEnv_SuppressesAutoImport pins the dc-6cuw contract: every
// bd subprocess spawned from the mail package must inherit
// BEADS_NO_AUTO_IMPORT=1 so the auto-import-from-JSONL fallback that was
// added in bd 1.0.3 (dc-4dix) cannot fire on a `gt mail send` / `gt mail
// poll-and-nudge` hot path. Without this, crew sees a noisy banner on every
// invocation and the path can race into a timeout.
func TestBdSubprocessEnv_SuppressesAutoImport(t *testing.T) {
	got := bdSubprocessEnv([]string{"PATH=/usr/bin"}, "/tmp/.beads", nil)

	if !envContains(got, "BEADS_NO_AUTO_IMPORT=1") {
		t.Fatalf("expected BEADS_NO_AUTO_IMPORT=1 in env, got %v", got)
	}
	if !envContains(got, "BEADS_DIR=/tmp/.beads") {
		t.Fatalf("expected BEADS_DIR= passed through, got %v", got)
	}
	if !envContains(got, "PATH=/usr/bin") {
		t.Fatalf("expected baseEnv (PATH) preserved, got %v", got)
	}
}

func TestBdSubprocessEnv_ExtraEnvAppendedAfterCanonical(t *testing.T) {
	// Make sure caller-supplied extraEnv lands AFTER the canonical entries
	// so it can override BEADS_NO_AUTO_IMPORT if a specific call site needs
	// to (e.g. an explicit `bd init --from-jsonl` in mail tooling). Go's
	// exec uses the LAST occurrence of a given key, so order matters.
	got := bdSubprocessEnv(nil, "/tmp/.beads", []string{"BEADS_NO_AUTO_IMPORT=0"})

	// Both occurrences should be present, and the override (=0) must come
	// after the canonical (=1).
	canonicalIdx := envIndex(got, "BEADS_NO_AUTO_IMPORT=1")
	overrideIdx := envIndex(got, "BEADS_NO_AUTO_IMPORT=0")
	if canonicalIdx < 0 || overrideIdx < 0 {
		t.Fatalf("expected both canonical and override entries, got %v", got)
	}
	if overrideIdx < canonicalIdx {
		t.Fatalf("override should follow canonical so it wins; got canonical=%d override=%d", canonicalIdx, overrideIdx)
	}
}

func TestBdSubprocessEnv_DoesNotMutateBaseEnv(t *testing.T) {
	// Regression guard: bdSubprocessEnv must not append into the caller's
	// baseEnv slice, because that shares backing storage with cmd.Environ()
	// at the call site. Mutating it would be a pleasant action-at-a-distance
	// bug for anyone reusing the slice afterward.
	base := []string{"PATH=/usr/bin"}
	baseLen := len(base)
	_ = bdSubprocessEnv(base, "/tmp/.beads", nil)
	if len(base) != baseLen {
		t.Fatalf("baseEnv was mutated: len went from %d to %d", baseLen, len(base))
	}
}

func envContains(env []string, kv string) bool { return envIndex(env, kv) >= 0 }

func envIndex(env []string, kv string) int {
	for i, e := range env {
		if e == kv {
			return i
		}
	}
	// Fallback: prefix match for entries with appended segments (none of our
	// asserts use prefixes today, but let's keep this future-proof).
	for i, e := range env {
		if strings.HasPrefix(e, kv) && len(e) == len(kv) {
			return i
		}
	}
	return -1
}
