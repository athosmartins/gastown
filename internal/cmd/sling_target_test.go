package cmd

import (
	"testing"
)

// TestResolveTargetSelfSlingDetection verifies that resolveTarget sets IsSelfSling=true
// when the resolved pane matches the current TMUX_PANE environment variable.
// This prevents gt sling deacon (when run from inside the deacon session) from
// nudging its own pane, which interrupts the running Bash tool and prompts for retry.
func TestResolveTargetSelfSlingDetection(t *testing.T) {
	tests := []struct {
		name          string
		resolvedPane  string
		tmuxPane      string
		wantSelfSling bool
	}{
		{
			name:          "pane matches TMUX_PANE → IsSelfSling true",
			resolvedPane:  "%42",
			tmuxPane:      "%42",
			wantSelfSling: true,
		},
		{
			name:          "pane differs from TMUX_PANE → IsSelfSling false",
			resolvedPane:  "%42",
			tmuxPane:      "%99",
			wantSelfSling: false,
		},
		{
			name:          "TMUX_PANE unset → IsSelfSling false",
			resolvedPane:  "%42",
			tmuxPane:      "",
			wantSelfSling: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("TMUX_PANE", tt.tmuxPane)

			// Override the resolveTargetAgentFn seam to return controlled values
			old := resolveTargetAgentFn
			resolveTargetAgentFn = func(target string) (string, string, string, error) {
				return "deacon/", tt.resolvedPane, "/tmp/workdir", nil
			}
			defer func() { resolveTargetAgentFn = old }()

			// Also stub spawnPolecatForSling so rig targets don't fail
			oldSpawn := spawnPolecatForSling
			defer func() { spawnPolecatForSling = oldSpawn }()

			result, err := resolveTarget("deacon", ResolveTargetOptions{})
			if err != nil {
				t.Fatalf("resolveTarget() unexpected error: %v", err)
			}
			if result.IsSelfSling != tt.wantSelfSling {
				t.Errorf("resolveTarget() IsSelfSling = %v, want %v (pane=%q, TMUX_PANE=%q)",
					result.IsSelfSling, tt.wantSelfSling, tt.resolvedPane, tt.tmuxPane)
			}
		})
	}
}
