// gt migrate freeze / thaw / status — town-wide write-freeze for dolt migrations.
//
// The freeze sentinel blocks gt write commands (mail send, nudge, sling, ...)
// town-wide until the operator runs `gt migrate thaw`. It is independent of
// `gt estop`, which freezes agent tmux sessions.
//
// See ~/gt/docs/guides/dolt-migration-playbook.md.
package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"github.com/steveyegge/gastown/internal/migration"
	"github.com/steveyegge/gastown/internal/style"
	"github.com/steveyegge/gastown/internal/workspace"
)

var (
	migrateFreezeReason   string
	migrateFreezeOperator string
)

var migrateCmd = &cobra.Command{
	Use:     "migrate",
	GroupID: GroupServices,
	Short:   "Migration tooling — freeze/thaw town writes during dolt migrations",
	Long: `Tooling for safe dolt database migrations.

Migration freeze blocks gt write commands (mail send, nudge, sling, ...)
town-wide. Use it during the active window of a dolt swap or merge to
prevent stranded writes. Independent of 'gt estop' (which freezes agent
tmux sessions — different concern).

See ~/gt/docs/guides/dolt-migration-playbook.md.

Subcommands:
  gt migrate freeze    Block gt writes town-wide
  gt migrate thaw      Resume gt writes (clear the freeze)
  gt migrate status    Show current freeze status`,
	RunE: requireSubcommand,
}

var migrateFreezeCmd = &cobra.Command{
	Use:   "freeze",
	Short: "Block gt write commands town-wide for a migration",
	Long: `Place the MIGRATION-FREEZE sentinel at the town root.

While the freeze is in effect, gt commands that mutate dolt state will
refuse with a clear error. The bd CLI is NOT gated by this freeze yet
(see dc-qcd2 follow-up) — rely on the playbook's plist-unload step to
stop continuous bd writers (mail-poller, daemon patrols) for now.

The 'thaw' command is always exempt so you can clear the freeze.`,
	RunE: runMigrateFreeze,
}

var migrateThawCmd = &cobra.Command{
	Use:   "thaw",
	Short: "Clear the migration freeze and resume writes",
	RunE:  runMigrateThaw,
}

var migrateStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show migration freeze status",
	RunE:  runMigrateStatus,
}

func init() {
	migrateFreezeCmd.Flags().StringVarP(&migrateFreezeReason, "reason", "r", "", "Reason for the freeze (recorded in the sentinel)")
	migrateFreezeCmd.Flags().StringVar(&migrateFreezeOperator, "operator", "", "Operator name (defaults to $USER or 'unknown')")
	migrateCmd.AddCommand(migrateFreezeCmd)
	migrateCmd.AddCommand(migrateThawCmd)
	migrateCmd.AddCommand(migrateStatusCmd)
	rootCmd.AddCommand(migrateCmd)
}

func runMigrateFreeze(cmd *cobra.Command, args []string) error {
	townRoot, err := workspace.FindFromCwdOrError()
	if err != nil {
		return fmt.Errorf("not in a Gas Town workspace: %w", err)
	}

	if migration.IsFrozen(townRoot) {
		info := migration.Read(townRoot)
		fmt.Printf("%s freeze already active (by %s at %s)\n",
			style.Warning.Render("!"),
			info.Operator,
			info.Timestamp.Local().Format("2006-01-02 15:04:05"))
		if info.Reason != "" {
			fmt.Printf("  Reason: %s\n", info.Reason)
		}
		return nil
	}

	operator := migrateFreezeOperator
	if operator == "" {
		// Prefer BD_ACTOR (Gas Town convention) then $USER.
		operator = os.Getenv("BD_ACTOR")
	}
	if operator == "" {
		operator = os.Getenv("USER")
	}
	if operator == "" {
		operator = "unknown"
	}

	if migrateFreezeReason == "" {
		fmt.Fprintf(os.Stderr, "%s no --reason given; empty reasons make post-mortems harder.\n",
			style.Warning.Render("!"))
	}

	if err := migration.Freeze(townRoot, operator, migrateFreezeReason); err != nil {
		return fmt.Errorf("failed to create freeze sentinel: %w", err)
	}

	fmt.Printf("%s MIGRATION FREEZE\n", style.Error.Render("⛔"))
	fmt.Printf("  Operator: %s\n", operator)
	if migrateFreezeReason != "" {
		fmt.Printf("  Reason:   %s\n", migrateFreezeReason)
	}
	fmt.Printf("  Sentinel: %s\n", migration.FilePath(townRoot))
	fmt.Println()
	fmt.Printf("  gt writes (mail send, nudge, sling, ...) will refuse until %s.\n",
		style.Bold.Render("gt migrate thaw"))
	fmt.Printf("  bd CLI is NOT gated yet — also unload writer plists per the playbook.\n")
	return nil
}

func runMigrateThaw(cmd *cobra.Command, args []string) error {
	townRoot, err := workspace.FindFromCwdOrError()
	if err != nil {
		return fmt.Errorf("not in a Gas Town workspace: %w", err)
	}

	if !migration.IsFrozen(townRoot) {
		fmt.Println("No migration freeze active.")
		return nil
	}

	if err := migration.Thaw(townRoot); err != nil {
		return fmt.Errorf("failed to remove freeze sentinel: %w", err)
	}

	fmt.Printf("%s freeze cleared — gt writes resumed.\n", style.Success.Render("✓"))
	return nil
}

func runMigrateStatus(cmd *cobra.Command, args []string) error {
	townRoot, err := workspace.FindFromCwdOrError()
	if err != nil {
		return fmt.Errorf("not in a Gas Town workspace: %w", err)
	}

	if !migration.IsFrozen(townRoot) {
		fmt.Println("○ No migration freeze active")
		return nil
	}

	info := migration.Read(townRoot)
	staleNote := ""
	if info.IsStale() {
		staleNote = style.Warning.Render(" [stale — operator process gone]")
	}
	fmt.Printf("%s Migration freeze ACTIVE%s\n", style.Error.Render("⛔"), staleNote)
	fmt.Printf("  Operator:  %s\n", info.Operator)
	fmt.Printf("  Since:     %s\n", info.Timestamp.Local().Format("2006-01-02 15:04:05"))
	if info.PID != 0 {
		fmt.Printf("  PID:       %d\n", info.PID)
	}
	if info.Reason != "" {
		fmt.Printf("  Reason:    %s\n", info.Reason)
	}
	fmt.Printf("  Sentinel:  %s\n", migration.FilePath(townRoot))
	fmt.Println()
	fmt.Printf("  Clear with: %s\n", style.Bold.Render("gt migrate thaw"))
	fmt.Printf("  Note: bd CLI is NOT gated — also unload writer plists per the playbook.\n")
	return nil
}

// freezeBlockedCommands enumerates the gt commands that should refuse to run
// while a migration freeze is active. Keep this list explicit (allowlist-of-
// blocks) rather than blocking everything by default — read commands and
// services-management commands must continue to work mid-migration so the
// operator can diagnose and recover.
//
// Inclusion criteria: any top-level gt command that writes a Dolt commit
// (creates/updates/closes beads, sends mail, hooks/unhooks work, or emits
// feed events). Commands that only read beads or manage local state (git,
// tmux, config) are excluded.
//
// Exclusions intentionally not in this list:
//   - migrate thaw / migrate status — always exempt (parent "migrate" is
//     listed in beadsExemptCommands and branchCheckExemptCommands)
//   - estop — freezes tmux sessions, no Dolt writes
//   - git-level commands (gt commit wraps git; no beads write on its own)
var freezeBlockedCommands = map[string]bool{
	// Communication — write beads or send tmux messages that create stranded state
	"mail send": true,
	"nudge":     true,
	"broadcast": true, // sends nudges to all workers; can recreate stranded-bead scenario

	// Work dispatch — write hook/assignment state to beads
	"sling":  true,
	"assign": true,

	// Work completion — close or unhook beads
	"unsling": true, // also catches alias "unhook"
	"done":    true,
	"wl done": true, // wasteland done: closes a wl bead with a Dolt commit

	// Persistent state writes
	"remember": true, // writes to the beads kv store
	"feed":     true, // emits structured events to the activity feed (Dolt writes)
	"commit":   true, // gt commit: git commit wrapper that may update bead state
}

// isFreezeBlocked reports whether the cobra command (and its full path) is on
// the freeze blocklist.
func isFreezeBlocked(cmd *cobra.Command) bool {
	path := strings.TrimPrefix(buildCommandPath(cmd), cmd.Root().Name()+" ")
	return freezeBlockedCommands[path]
}
