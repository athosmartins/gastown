// Package deacon provides the Deacon agent infrastructure.
package deacon

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/steveyegge/gastown/internal/beads"
	"github.com/steveyegge/gastown/internal/git"
	"github.com/steveyegge/gastown/internal/session"
	"github.com/steveyegge/gastown/internal/tmux"
)

// StaleHookConfig holds configurable parameters for stale hook detection.
type StaleHookConfig struct {
	// MaxAge is how long a bead can be hooked before being considered stale.
	MaxAge time.Duration `json:"max_age"`
	// DryRun if true, only reports what would be done without making changes.
	DryRun bool `json:"dry_run"`
}

// DefaultStaleHookConfig returns the default stale hook config.
func DefaultStaleHookConfig() *StaleHookConfig {
	return &StaleHookConfig{
		MaxAge: 1 * time.Hour,
		DryRun: false,
	}
}

// HookedBead represents a bead in hooked status from bd list output.
type HookedBead struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Status    string    `json:"status"`
	Assignee  string    `json:"assignee"`
	UpdatedAt time.Time `json:"updated_at"`
}

// StaleHookResult represents the result of processing a stale hooked bead.
type StaleHookResult struct {
	BeadID     string `json:"bead_id"`
	Title      string `json:"title"`
	Assignee   string `json:"assignee"`
	Age        string `json:"age"`
	AgentAlive bool   `json:"agent_alive"`
	Unhooked   bool   `json:"unhooked"`
	Error      string `json:"error,omitempty"`
	// PartialWork indicates uncommitted changes or unpushed commits were found
	// in the agent's worktree before unhooking.
	PartialWork   bool   `json:"partial_work,omitempty"`
	WorktreeDirty bool   `json:"worktree_dirty,omitempty"`
	UnpushedCount int    `json:"unpushed_count,omitempty"`
	WorktreeError string `json:"worktree_error,omitempty"`
	// CompletedWork indicates the hooked bead's molecule was fully complete
	// despite the hook not being cleared. The bead is auto-closed rather than
	// re-opened, preventing the "1500+ retry loop" anti-pattern (dc-u98d).
	CompletedWork bool `json:"completed_work,omitempty"`
}

// StaleHookScanResult contains the full results of a stale hook scan.
type StaleHookScanResult struct {
	ScannedAt   time.Time          `json:"scanned_at"`
	TotalHooked int                `json:"total_hooked"`
	StaleCount  int                `json:"stale_count"`
	Unhooked    int                `json:"unhooked"`
	Results     []*StaleHookResult `json:"results"`
}

// ScanStaleHooks finds hooked beads with dead agents and optionally unhooks them.
// Session liveness is checked for ALL hooked beads regardless of age (gt-pqf9x).
// A hooked bead is considered stale if:
//  1. The assignee's tmux session is dead (immediate unhook), OR
//  2. The bead is older than MaxAge AND we can't determine session liveness
//     (e.g., unknown assignee format), OR
//  3. The bead has a fully-complete molecule (all steps closed), even when the
//     agent is alive — prevents the "1500+ retry loop" where a live agent keeps
//     picking up completed work after a crash (dc-u98d)
func ScanStaleHooks(townRoot string, cfg *StaleHookConfig) (*StaleHookScanResult, error) {
	if cfg == nil {
		cfg = DefaultStaleHookConfig()
	}

	result := &StaleHookScanResult{
		ScannedAt: time.Now().UTC(),
		Results:   make([]*StaleHookResult, 0),
	}

	// Get all hooked beads
	hookedBeads, err := listHookedBeads(townRoot)
	if err != nil {
		return nil, fmt.Errorf("listing hooked beads: %w", err)
	}

	result.TotalHooked = len(hookedBeads)

	threshold := time.Now().Add(-cfg.MaxAge)
	t := tmux.NewTmux()

	for _, bead := range hookedBeads {
		hookResult := &StaleHookResult{
			BeadID:   bead.ID,
			Title:    bead.Title,
			Assignee: bead.Assignee,
			Age:      time.Since(bead.UpdatedAt).Round(time.Minute).String(),
		}

		// Check if assignee agent is still alive (regardless of age)
		sessionChecked := false
		if bead.Assignee != "" {
			sessionName := assigneeToSessionName(bead.Assignee)
			if sessionName != "" {
				alive, _ := t.HasSession(sessionName)
				hookResult.AgentAlive = alive
				sessionChecked = true
			}
		}

		// Determine if this hook is stale:
		// - Agent confirmed dead → stale (regardless of age)
		// - Can't check session + older than MaxAge → stale (fallback)
		// - Agent alive → not stale (unless molecule is complete; see below)
		isStale := false
		if sessionChecked && !hookResult.AgentAlive {
			// Session confirmed dead — unhook immediately regardless of age
			isStale = true
		} else if !sessionChecked && bead.UpdatedAt.Before(threshold) {
			// Can't determine session liveness (unknown assignee format)
			// Fall back to age-based check
			isStale = true
		}

		// Check for completed molecule even when the agent is alive.
		// A live agent can be stuck re-executing finished work across restarts
		// when the session crashed after completing all formula steps but before
		// burning/closing the root bead. The hook persists; every restart picks
		// up the same completed work and hits the same dead end. (dc-u98d)
		if !isStale && isMoleculeComplete(townRoot, bead.ID) {
			isStale = true
			hookResult.CompletedWork = true
		}

		if !isStale {
			continue
		}

		result.StaleCount++

		if hookResult.CompletedWork {
			// All formula steps are done: close the bead rather than re-opening it.
			// Unhooking to "open" would re-dispatch the same finished work.
			if !cfg.DryRun {
				if err := closeCompleteBead(townRoot, bead.ID); err != nil {
					hookResult.Error = err.Error()
				} else {
					hookResult.Unhooked = true
					result.Unhooked++
				}
			}
		} else if !hookResult.AgentAlive {
			// Agent is dead/gone: check worktree state before unhooking
			checkWorktreeState(townRoot, bead.Assignee, hookResult)

			if !cfg.DryRun {
				if err := unhookBead(townRoot, bead.ID); err != nil {
					hookResult.Error = err.Error()
				} else {
					hookResult.Unhooked = true
					result.Unhooked++
				}
			}
		}

		result.Results = append(result.Results, hookResult)
	}

	return result, nil
}

// listHookedBeads returns all beads with status=hooked.
func listHookedBeads(townRoot string) ([]*HookedBead, error) {
	cmd := beads.Command(townRoot, townBeadsDir(townRoot), beads.ReadOnlyRouting, "list", "--status=hooked", "--json", "--flat", "--limit=0")

	output, err := cmd.Output()
	if err != nil {
		// No hooked beads is not an error
		if strings.Contains(string(output), "no issues found") {
			return nil, nil
		}
		return nil, err
	}

	trimmed := bytes.TrimSpace(output)
	if len(trimmed) == 0 || string(trimmed) == "null" || (trimmed[0] != '[' && trimmed[0] != '{') {
		return nil, nil
	}

	var beads []*HookedBead
	if err := json.Unmarshal(output, &beads); err != nil {
		return nil, fmt.Errorf("parsing hooked beads: %w", err)
	}

	return beads, nil
}

// assigneeToSessionName converts an assignee address to a tmux session name.
// Delegates to session.ParseAddress for consistent parsing across the codebase.
func assigneeToSessionName(assignee string) string {
	identity, err := session.ParseAddress(assignee)
	if err != nil {
		return ""
	}
	return identity.SessionName()
}

// checkWorktreeState checks an agent's worktree for uncommitted changes or
// unpushed commits and populates the result fields. This is best-effort;
// errors are recorded but do not prevent unhooking.
func checkWorktreeState(townRoot, assignee string, result *StaleHookResult) {
	worktreePath := assigneeToWorktreePath(townRoot, assignee)
	if worktreePath == "" {
		return
	}

	g := git.NewGit(worktreePath)
	workStatus, err := g.CheckUncommittedWork()
	if err != nil {
		result.WorktreeError = fmt.Sprintf("checking worktree: %v", err)
		return
	}

	if !workStatus.CleanExcludingBeads() {
		result.PartialWork = true
		result.WorktreeDirty = workStatus.HasUncommittedChanges
		result.UnpushedCount = workStatus.UnpushedCommits
	}
}

// assigneeToWorktreePath resolves an assignee address to its git worktree path.
// Returns "" if the assignee format is unrecognized or the worktree doesn't exist.
// Supports polecat format "rig/polecats/name" and crew format "rig/crew/name".
func assigneeToWorktreePath(townRoot, assignee string) string {
	parts := strings.Split(assignee, "/")
	if len(parts) != 3 {
		return ""
	}

	rigName, agentType, name := parts[0], parts[1], parts[2]
	if agentType != "polecats" && agentType != "crew" {
		return ""
	}

	rigPath := filepath.Join(townRoot, rigName)

	// New structure: rig/polecats/<name>/<rigname>/
	newPath := filepath.Join(rigPath, agentType, name, rigName)
	if info, err := os.Stat(newPath); err == nil && info.IsDir() {
		if _, err := os.Stat(filepath.Join(newPath, ".git")); err == nil {
			return newPath
		}
	}

	// Old structure: rig/polecats/<name>/
	oldPath := filepath.Join(rigPath, agentType, name)
	if info, err := os.Stat(oldPath); err == nil && info.IsDir() {
		if _, err := os.Stat(filepath.Join(oldPath, ".git")); err == nil {
			return oldPath
		}
	}

	return ""
}

// unhookBead sets a bead's status back to 'open'.
func unhookBead(townRoot, beadID string) error {
	cmd := beads.Command(townRoot, townBeadsDir(townRoot), beads.MutationRouting, "update", beadID, "--status=open")
	return cmd.Run()
}

// isMoleculeComplete returns true when beadID has formula children AND all of
// them are closed (none are open). Two bd list calls are used: one to check for
// open children (fast-path: any open → not complete) and one to confirm any
// children exist at all (no children → plain task, not a molecule). Returns
// false on any query failure — safe to skip when uncertain.
func isMoleculeComplete(townRoot, beadID string) bool {
	// Fast path: any open children means work is not done yet.
	openCmd := beads.Command(townRoot, townBeadsDir(townRoot), beads.ReadOnlyRouting,
		"list", "--parent="+beadID, "--status=open", "--json", "--flat", "--limit=1")
	openOut, err := openCmd.Output()
	if err != nil {
		return false
	}
	openTrimmed := bytes.TrimSpace(openOut)
	if hasItems(openTrimmed) {
		return false
	}

	// Confirm there are children at all — a bead with no children is a plain
	// task, not a molecule, and we must not close it here.
	allCmd := beads.Command(townRoot, townBeadsDir(townRoot), beads.ReadOnlyRouting,
		"list", "--parent="+beadID, "--all", "--json", "--flat", "--limit=1")
	allOut, err := allCmd.Output()
	if err != nil {
		return false
	}
	return hasItems(bytes.TrimSpace(allOut))
}

// hasItems returns true when a bd list JSON output contains at least one item.
func hasItems(trimmed []byte) bool {
	return len(trimmed) > 0 && string(trimmed) != "null" && string(trimmed) != "[]" && trimmed[0] == '['
}

// closeCompleteBead closes a bead whose molecule is fully complete but whose
// hook was never cleared (e.g., the agent crashed before burning the wisp).
// Uses --force because the bead is still in "hooked" status.
func closeCompleteBead(townRoot, beadID string) error {
	cmd := beads.Command(townRoot, townBeadsDir(townRoot), beads.MutationRouting,
		"close", beadID, "--force",
		"--reason=stale-hook: molecule complete, auto-closed by stale-hooks scan (dc-u98d)")
	return cmd.Run()
}
