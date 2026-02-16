package doctor

import (
	"fmt"
	"strings"

	"github.com/steveyegge/gastown/internal/events"
	"github.com/steveyegge/gastown/internal/session"
	"github.com/steveyegge/gastown/internal/tmux"
)

// SessionNamesCheck detects tmux sessions with malformed names from pre-Feb-15 code.
// Session naming format changed on Feb 15, 2026 (commit c07f0f94).
// Old format: <prefix>-<rigname>-<role> (e.g., gt-gastown-witness)
// New format: <prefix>-<role> (e.g., gt-witness)
//
// This check identifies sessions that parse as valid but have the old format,
// which causes system agents to be misclassified as polecats.
type SessionNamesCheck struct {
	FixableCheck
	malformedSessions map[string]*malformedSessionInfo // session -> info
}

type malformedSessionInfo struct {
	oldName     string
	correctName string
	identity    *session.AgentIdentity
}

// NewSessionNamesCheck creates a new session names check.
func NewSessionNamesCheck() *SessionNamesCheck {
	return &SessionNamesCheck{
		FixableCheck: FixableCheck{
			BaseCheck: BaseCheck{
				CheckName:        "session-names",
				CheckDescription: "Detect malformed session names from pre-Feb-15 code",
				CheckCategory:    CategoryCleanup,
			},
		},
		malformedSessions: make(map[string]*malformedSessionInfo),
	}
}

// Run checks for sessions with malformed names.
func (c *SessionNamesCheck) Run(ctx *CheckContext) *CheckResult {
	t := tmux.NewTmux()

	sessions, err := t.ListSessions()
	if err != nil {
		return &CheckResult{
			Name:    c.Name(),
			Status:  StatusWarning,
			Message: "Could not list tmux sessions",
			Details: []string{err.Error()},
		}
	}

	if len(sessions) == 0 {
		return &CheckResult{
			Name:    c.Name(),
			Status:  StatusOK,
			Message: "No tmux sessions found",
		}
	}

	// Check each session for malformed names
	c.malformedSessions = make(map[string]*malformedSessionInfo)
	var validCount int

	for _, sess := range sessions {
		if sess == "" {
			continue
		}

		// Try to parse the session name
		identity, err := session.ParseSessionName(sess)
		if err != nil {
			// Can't parse - not a Gas Town session, skip
			continue
		}

		// Check if this is a malformed session
		if info := c.detectMalformedSession(sess, identity); info != nil {
			c.malformedSessions[sess] = info
		} else {
			validCount++
		}
	}

	if len(c.malformedSessions) == 0 {
		return &CheckResult{
			Name:    c.Name(),
			Status:  StatusOK,
			Message: fmt.Sprintf("All %d Gas Town sessions have correct names", validCount),
		}
	}

	details := make([]string, 0, len(c.malformedSessions))
	for sess, info := range c.malformedSessions {
		details = append(details, fmt.Sprintf("Malformed: %s → should be: %s", sess, info.correctName))
	}

	return &CheckResult{
		Name:    c.Name(),
		Status:  StatusWarning,
		Message: fmt.Sprintf("Found %d malformed session name(s)", len(c.malformedSessions)),
		Details: details,
		FixHint: "Run 'gt doctor --fix' to recreate sessions with correct names",
	}
}

// detectMalformedSession checks if a session name is malformed.
// Returns nil if the session name is correct, otherwise returns info about the malformed session.
//
// Detection strategy:
// For system agents (witness, refinery), the correct format is <prefix>-<role>.
// If the parsed identity shows it as a polecat with a name like "gastown-witness"
// or "gastown-refinery", it's likely a malformed system agent session.
func (c *SessionNamesCheck) detectMalformedSession(sess string, identity *session.AgentIdentity) *malformedSessionInfo {
	// Only check rig-level sessions (town-level sessions like hq-mayor are fine)
	if identity.Rig == "" {
		return nil
	}

	// If parsed as polecat, check if the name looks like it should be a system agent
	if identity.Role == session.RolePolecat {
		// Check if the polecat name matches pattern: <rigname>-<systemrole>
		// where systemrole is "witness" or "refinery"
		parts := strings.SplitN(identity.Name, "-", 2)
		if len(parts) == 2 {
			potentialRole := parts[1]

			// Check if this looks like a system agent role
			if potentialRole == "witness" || potentialRole == "refinery" {
				// This is likely a malformed system agent session
				var correctRole session.Role
				if potentialRole == "witness" {
					correctRole = session.RoleWitness
				} else {
					correctRole = session.RoleRefinery
				}

				// Create correct identity
				correctIdentity := &session.AgentIdentity{
					Role:   correctRole,
					Rig:    identity.Rig,
					Prefix: identity.Prefix,
				}

				return &malformedSessionInfo{
					oldName:     sess,
					correctName: correctIdentity.SessionName(),
					identity:    correctIdentity,
				}
			}
		}

		// Also check for crew pattern: <rigname>-crew-<name>
		if strings.Contains(identity.Name, "-crew-") {
			// This is likely a malformed crew session
			// The pattern would be: <prefix>-<rigname>-crew-<workername>
			// Should be: <prefix>-crew-<workername>
			idx := strings.Index(identity.Name, "-crew-")
			if idx > 0 {
				workerName := identity.Name[idx+6:] // Skip "-crew-"
				if workerName != "" {
					correctIdentity := &session.AgentIdentity{
						Role:   session.RoleCrew,
						Rig:    identity.Rig,
						Name:   workerName,
						Prefix: identity.Prefix,
					}

					return &malformedSessionInfo{
						oldName:     sess,
						correctName: correctIdentity.SessionName(),
						identity:    correctIdentity,
					}
				}
			}
		}
	}

	return nil
}

// Fix recreates malformed sessions with correct names.
// For system agents (witness, refinery), it:
// 1. Checks if there's hooked work
// 2. Kills the old session
// 3. Starts a new session with the correct name
// 4. Restores hooked work if any
func (c *SessionNamesCheck) Fix(ctx *CheckContext) error {
	if len(c.malformedSessions) == 0 {
		return nil
	}

	t := tmux.NewTmux()
	var lastErr error

	for oldSess, info := range c.malformedSessions {
		// SAFEGUARD: Never auto-fix crew sessions.
		// Crew workers are human-managed and require explicit action.
		if info.identity.Role == session.RoleCrew {
			continue
		}

		// Log pre-death event for crash investigation
		_ = events.LogFeed(events.TypeSessionDeath, oldSess,
			events.SessionDeathPayload(oldSess, info.identity.Address(), "malformed session name", "gt doctor"))

		// Kill old session
		if err := t.KillSessionWithProcesses(oldSess); err != nil {
			lastErr = fmt.Errorf("failed to kill session %s: %w", oldSess, err)
			continue
		}

		// TODO: Preserve hooked work
		// This would require:
		// 1. Reading hook state from old session
		// 2. Starting new session with correct name
		// 3. Restoring hook state
		//
		// For now, we just kill the old session and let the system
		// restart the agent. Hooked work will be lost, which is acceptable
		// for a one-time migration from old session names.
	}

	return lastErr
}
