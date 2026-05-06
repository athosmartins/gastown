package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"
	"github.com/steveyegge/gastown/internal/session"
	"github.com/steveyegge/gastown/internal/style"
	"github.com/steveyegge/gastown/internal/tmux"
	"github.com/steveyegge/gastown/internal/workspace"
)

var (
	mailPollDryRun      bool
	mailPollRig         string
	mailPollQuietPeriod time.Duration
	mailPollStateFile   string
)

// nudgeState tracks the last nudge time per mail address.
type nudgeState map[string]time.Time

func loadNudgeState(path string) nudgeState {
	data, err := os.ReadFile(path)
	if err != nil {
		return make(nudgeState)
	}
	var raw map[string]string
	if err := json.Unmarshal(data, &raw); err != nil {
		return make(nudgeState)
	}
	state := make(nudgeState, len(raw))
	for k, v := range raw {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			state[k] = t
		}
	}
	return state
}

func saveNudgeState(path string, state nudgeState) {
	raw := make(map[string]string, len(state))
	for k, v := range state {
		raw[k] = v.UTC().Format(time.RFC3339)
	}
	data, err := json.MarshalIndent(raw, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(path, data, 0600)
}

var mailPollCmd = &cobra.Command{
	Use:   "poll-and-nudge",
	Short: "Nudge crew with unread mail (for launchd/cron)",
	Long: `Poll all active agent inboxes and nudge those with unread mail.

For each active crew or polecat session with unread messages, sends a
nudge via --mode=queue if the agent hasn't been nudged recently.

A quiet period (default 10 minutes) prevents repeated nudges while the
agent is reading mail but hasn't replied yet.

Only sessions with a running tmux session are nudged — dead sessions are
silently skipped.

Designed to be invoked by launchd every 5 minutes. Logs to stderr only;
no stdout noise when nothing needs nudging.

Examples:
  gt mail poll-and-nudge                    # Run once
  gt mail poll-and-nudge --dry-run          # List candidates only
  gt mail poll-and-nudge --rig=gastown      # Limit to one rig
  gt mail poll-and-nudge --quiet-period=5m  # Shorter quiet period`,
	RunE: runMailPollAndNudge,
}

func runMailPollAndNudge(cmd *cobra.Command, args []string) error {
	_, err := findMailWorkDir()
	if err != nil {
		return fmt.Errorf("not in a Gas Town workspace: %w", err)
	}

	townRoot, err := workspace.FindFromCwd()
	if err != nil {
		return fmt.Errorf("finding town root: %w", err)
	}
	_ = session.InitRegistry(townRoot)

	agents, err := getAgentSessions(true /* includePolecats */)
	if err != nil {
		return fmt.Errorf("listing sessions: %w", err)
	}

	t := tmux.NewTmux()
	state := loadNudgeState(mailPollStateFile)
	now := time.Now()
	stateUpdated := false

	for _, agent := range agents {
		if agent.Type != AgentCrew && agent.Type != AgentPolecat {
			continue
		}
		if mailPollRig != "" && agent.Rig != mailPollRig {
			continue
		}

		address := agentAddress(agent)
		if address == "" {
			continue
		}

		// Skip dead sessions.
		if alive, _ := t.HasSession(agent.Name); !alive {
			continue
		}

		// Check unread count.
		mb, err := getMailbox(address)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mail-poller: mailbox error for %s: %v\n", address, err)
			continue
		}
		unread, err := mb.ListUnread()
		if err != nil {
			fmt.Fprintf(os.Stderr, "mail-poller: list error for %s: %v\n", address, err)
			continue
		}
		if len(unread) == 0 {
			continue
		}

		// Check quiet period.
		if last, ok := state[address]; ok && now.Sub(last) < mailPollQuietPeriod {
			if mailPollDryRun {
				fmt.Printf("  %s %s: %d unread — quiet period active (last nudge %s ago)\n",
					style.Dim.Render("○"), address, len(unread), now.Sub(last).Truncate(time.Second))
			}
			continue
		}

		if mailPollDryRun {
			fmt.Printf("  %s %s: %d unread — would nudge\n", style.Bold.Render("●"), address, len(unread))
			continue
		}

		// Send the nudge.
		nudgeExec := exec.Command("gt", "nudge", address, "--mode=queue", "-m", "Mail aguardando — gt mail inbox") //nolint:gosec
		nudgeExec.Stderr = os.Stderr
		if err := nudgeExec.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "mail-poller: nudge failed for %s: %v\n", address, err)
			continue
		}

		fmt.Fprintf(os.Stderr, "mail-poller: nudged %s (%d unread)\n", address, len(unread))
		state[address] = now
		stateUpdated = true
	}

	if stateUpdated && !mailPollDryRun {
		saveNudgeState(mailPollStateFile, state)
	}

	return nil
}

// agentAddress returns the mail address for an AgentSession.
func agentAddress(agent *AgentSession) string {
	switch agent.Type {
	case AgentCrew:
		return fmt.Sprintf("%s/crew/%s", agent.Rig, agent.AgentName)
	case AgentPolecat:
		return fmt.Sprintf("%s/polecats/%s", agent.Rig, agent.AgentName)
	default:
		return ""
	}
}

// mailPollerInstallCmd installs the launchd job for the mail poller.
var mailPollerInstallCmd = &cobra.Command{
	Use:   "poller-install",
	Short: "Install launchd job for mail-poller (macOS only)",
	Long: `Install and load a launchd LaunchAgent that runs 'gt mail poll-and-nudge'
every 5 minutes.

The plist is written to ~/Library/LaunchAgents/com.gastown.mail-poller.plist
and loaded immediately. Logs go to ~/.gastown/logs/mail-poller.log.

Examples:
  gt mail poller-install    # Install and start the poller
  gt mail poller-uninstall  # Remove the poller`,
	RunE: runMailPollerInstall,
}

var mailPollerUninstallCmd = &cobra.Command{
	Use:   "poller-uninstall",
	Short: "Remove launchd job for mail-poller (macOS only)",
	RunE:  runMailPollerUninstall,
}

const mailPollerLabel = "com.gastown.mail-poller"

func mailPollerPlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", mailPollerLabel+".plist"), nil
}

func mailPollerLogPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".gastown", "logs", "mail-poller.log"), nil
}

func runMailPollerInstall(cmd *cobra.Command, args []string) error {
	plistPath, err := mailPollerPlistPath()
	if err != nil {
		return fmt.Errorf("finding home: %w", err)
	}
	logPath, err := mailPollerLogPath()
	if err != nil {
		return fmt.Errorf("finding log path: %w", err)
	}

	if err := os.MkdirAll(filepath.Dir(logPath), 0755); err != nil {
		return fmt.Errorf("creating log directory: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(plistPath), 0755); err != nil {
		return fmt.Errorf("creating LaunchAgents directory: %w", err)
	}

	gtPath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("finding gt executable: %w", err)
	}

	townRoot, _ := workspace.FindFromCwd()
	plistContent := buildMailPollerPlist(gtPath, townRoot, logPath)

	if err := os.WriteFile(plistPath, []byte(plistContent), 0644); err != nil {
		return fmt.Errorf("writing plist: %w", err)
	}

	_ = exec.Command("launchctl", "unload", plistPath).Run() //nolint:gosec
	if out, err := exec.Command("launchctl", "load", plistPath).CombinedOutput(); err != nil { //nolint:gosec
		return fmt.Errorf("loading launchd service: %s", string(out))
	}

	fmt.Printf("%s Installed %s\n", style.Bold.Render("✓"), mailPollerLabel)
	fmt.Printf("  Plist: %s\n", plistPath)
	fmt.Printf("  Logs:  %s\n", logPath)
	fmt.Println("  Runs every 5 minutes.")
	return nil
}

func runMailPollerUninstall(cmd *cobra.Command, args []string) error {
	plistPath, err := mailPollerPlistPath()
	if err != nil {
		return fmt.Errorf("finding home: %w", err)
	}

	if _, err := os.Stat(plistPath); os.IsNotExist(err) {
		fmt.Printf("%s %s not installed\n", style.Dim.Render("○"), mailPollerLabel)
		return nil
	}

	_ = exec.Command("launchctl", "unload", plistPath).Run() //nolint:gosec
	if err := os.Remove(plistPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("removing plist: %w", err)
	}

	fmt.Printf("%s Uninstalled %s\n", style.Bold.Render("✓"), mailPollerLabel)
	return nil
}

func buildMailPollerPlist(gtPath, townRoot, logPath string) string {
	envVars := fmt.Sprintf(`
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>%s</string>
        <key>PATH</key>
        <string>%s:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>%s
    </dict>`,
		os.Getenv("HOME"),
		filepath.Dir(gtPath),
		func() string {
			if townRoot != "" {
				return fmt.Sprintf("\n        <key>GT_TOWN_ROOT</key>\n        <string>%s</string>", townRoot)
			}
			return ""
		}(),
	)

	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>

    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>mail</string>
        <string>poll-and-nudge</string>
    </array>

    <key>StartInterval</key>
    <integer>300</integer>

    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>%s</string>

    <key>StandardErrorPath</key>
    <string>%s</string>%s
</dict>
</plist>
`, mailPollerLabel, gtPath, logPath, logPath, envVars)
}
