package config

import (
	"strings"
	"testing"
)

func TestRemoteControlInjectedWhenSessionNameSet(t *testing.T) {
	// Session with a known name should get --remote-control injected
	envVars := AgentEnv(AgentEnvConfig{
		Role:        "crew",
		Rig:         "whatsapp_automation",
		AgentName:   "mila",
		TownRoot:    "/tmp/test-town",
		SessionName: "wa-crew-mila",
	})

	if envVars["GT_SESSION"] != "wa-crew-mila" {
		t.Fatalf("expected GT_SESSION=wa-crew-mila, got %q", envVars["GT_SESSION"])
	}

	cmd, err := BuildStartupCommandWithAgentOverride(envVars, "", "hello", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(cmd, "--remote-control wa-crew-mila") {
		t.Errorf("expected --remote-control wa-crew-mila in command, got: %s", cmd)
	}
	t.Logf("command: %s", cmd)
}

func TestRemoteControlNotInjectedWhenNoSessionName(t *testing.T) {
	// Without SessionName, no --remote-control should be added
	envVars := AgentEnv(AgentEnvConfig{
		Role:      "crew",
		Rig:       "whatsapp_automation",
		AgentName: "mila",
		TownRoot:  "/tmp/test-town",
		// SessionName intentionally omitted
	})

	cmd, err := BuildStartupCommandWithAgentOverride(envVars, "", "hello", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if strings.Contains(cmd, "--remote-control") {
		t.Errorf("expected no --remote-control in command without SessionName, got: %s", cmd)
	}
}

func TestRemoteControlNotInjectedForNonClaude(t *testing.T) {
	// Non-Claude agents should not get --remote-control
	envVars := AgentEnv(AgentEnvConfig{
		Role:        "crew",
		Rig:         "whatsapp_automation",
		AgentName:   "mila",
		TownRoot:    "/tmp/test-town",
		SessionName: "wa-crew-mila",
	})

	// Override with gemini agent
	cmd, err := BuildStartupCommandWithAgentOverride(envVars, "", "hello", "gemini")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if strings.Contains(cmd, "--remote-control") {
		t.Errorf("expected no --remote-control for gemini agent, got: %s", cmd)
	}
}
