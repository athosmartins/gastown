package doctor

import (
	"testing"

	"github.com/steveyegge/gastown/internal/session"
)

func TestNewSessionNamesCheck(t *testing.T) {
	check := NewSessionNamesCheck()

	if check.Name() != "session-names" {
		t.Errorf("expected name 'session-names', got %q", check.Name())
	}

	if check.Description() != "Detect malformed session names from pre-Feb-15 code" {
		t.Errorf("expected description 'Detect malformed session names from pre-Feb-15 code', got %q", check.Description())
	}

	if !check.CanFix() {
		t.Error("expected CanFix to return true")
	}

	if check.Category() != CategoryCleanup {
		t.Errorf("expected category %q, got %q", CategoryCleanup, check.Category())
	}
}

func TestSessionNamesCheck_DetectMalformedSession(t *testing.T) {
	check := NewSessionNamesCheck()

	tests := []struct {
		name     string
		session  string
		wantNil  bool
		wantName string
	}{
		{
			name:    "correct witness session",
			session: "gt-witness",
			wantNil: true,
		},
		{
			name:    "correct refinery session",
			session: "gt-refinery",
			wantNil: true,
		},
		{
			name:    "correct polecat session",
			session: "gt-toast",
			wantNil: true,
		},
		{
			name:     "malformed witness session (old format)",
			session:  "gt-gastown-witness",
			wantNil:  false,
			wantName: "gt-witness",
		},
		{
			name:     "malformed refinery session (old format)",
			session:  "gt-gastown-refinery",
			wantNil:  false,
			wantName: "gt-refinery",
		},
		{
			name:    "correct crew session",
			session: "gt-crew-max",
			wantNil: true,
		},
		{
			name:    "town-level mayor session",
			session: "hq-mayor",
			wantNil: true,
		},
		{
			name:    "town-level deacon session",
			session: "hq-deacon",
			wantNil: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			identity, err := session.ParseSessionName(tt.session)
			if err != nil {
				t.Fatalf("failed to parse session %q: %v", tt.session, err)
			}

			info := check.detectMalformedSession(tt.session, identity)
			if tt.wantNil {
				if info != nil {
					t.Errorf("expected nil for %q, got %+v", tt.session, info)
				}
			} else {
				if info == nil {
					t.Errorf("expected non-nil for %q", tt.session)
				} else if info.correctName != tt.wantName {
					t.Errorf("expected correct name %q, got %q", tt.wantName, info.correctName)
				}
			}
		})
	}
}

func TestSessionNamesCheck_Run(t *testing.T) {
	// This test verifies the check runs without error.
	// Results depend on the test environment.
	check := NewSessionNamesCheck()
	ctx := &CheckContext{TownRoot: t.TempDir()}

	result := check.Run(ctx)

	// Should return OK or Warning depending on environment
	if result.Status != StatusOK && result.Status != StatusWarning {
		t.Errorf("expected StatusOK or StatusWarning, got %v: %s", result.Status, result.Message)
	}
}
