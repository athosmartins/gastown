package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestDoneUnhooksClosedBead verifies that gt done unhooks a closed bead to prevent
// infinite retry loops (dc-u98d). When a hooked bead is closed via bd close, it must
// also be unhooked (assignee cleared) to prevent Deacon from getting stuck trying to
// attach work to a closed bead.
func TestDoneUnhooksClosedBead(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("shell script bd stub not supported on Windows")
	}

	townRoot := t.TempDir()

	// Workspace marker
	if err := os.MkdirAll(filepath.Join(townRoot, "mayor"), 0755); err != nil {
		t.Fatalf("mkdir mayor: %v", err)
	}

	// .beads directory
	beadsDir := filepath.Join(townRoot, ".beads")
	if err := os.MkdirAll(filepath.Join(beadsDir, "locks"), 0755); err != nil {
		t.Fatalf("mkdir .beads/locks: %v", err)
	}

	// Create routes for rig lookup
	if err := os.MkdirAll(filepath.Join(townRoot, "gastown"), 0755); err != nil {
		t.Fatalf("mkdir gastown: %v", err)
	}
	routes := strings.Join([]string{
		`{"prefix":"gt-","path":"gastown"}`,
		"",
	}, "\n")
	if err := os.WriteFile(filepath.Join(beadsDir, "routes.jsonl"), []byte(routes), 0644); err != nil {
		t.Fatalf("write routes.jsonl: %v", err)
	}

	// Stub bd binary
	binDir := filepath.Join(townRoot, "bin")
	if err := os.MkdirAll(binDir, 0755); err != nil {
		t.Fatalf("mkdir bin: %v", err)
	}
	closesLog := filepath.Join(townRoot, "closes.log")
	updatesLog := filepath.Join(townRoot, "updates.log")

	// The stub simulates:
	// - Agent bead (gt-gastown-polecat-nux) with hook_bead pointing to base bead
	// - Base bead (gt-base-123) hooked and with acceptable state for closing
	bdScript := fmt.Sprintf(`#!/bin/sh
while [ "$1" = "--allow-stale" ]; do shift; done
cmd="$1"
shift || true
case "$cmd" in
  show)
    beadID="$1"
    case "$beadID" in
      gt-gastown-polecat-nux)
        echo '[{"id":"gt-gastown-polecat-nux","title":"Polecat nux","status":"open","hook_bead":"gt-base-123","agent_state":"working"}]'
        ;;
      gt-base-123)
        echo '[{"id":"gt-base-123","title":"Base bead","status":"hooked","assignee":"gastown/polecats/nux"}]'
        ;;
    esac
    ;;
  close)
    # Log close operations
    for arg in "$@"; do
      case "$arg" in --*) continue ;; esac
      echo "$arg" >> "%s"
    done
    ;;
  update)
    # Log update operations (bead ID and flags)
    beadID="$1"
    shift || true
    echo "update $beadID" >> "%s"
    for flag in "$@"; do
      if [[ "$flag" == --* ]]; then
        echo "  $flag" >> "%s"
      fi
    done
    ;;
  agent|slot)
    exit 0
    ;;
esac
exit 0
`, closesLog, updatesLog, updatesLog)

	bdPath := filepath.Join(binDir, "bd")
	if err := os.WriteFile(bdPath, []byte(bdScript), 0755); err != nil {
		t.Fatalf("write bd stub: %v", err)
	}

	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("GT_ROLE", "polecat")
	t.Setenv("GT_RIG", "gastown")
	t.Setenv("GT_POLECAT", "nux")
	t.Setenv("GT_CREW", "")
	t.Setenv("TMUX_PANE", "")

	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(filepath.Join(townRoot, "gastown")); err != nil {
		t.Fatalf("chdir: %v", err)
	}

	// Call updateAgentStateOnDone directly
	updateAgentStateOnDone(filepath.Join(townRoot, "gastown"), townRoot, ExitCompleted, "gt-base-123")

	// Verify close and update calls
	closesBytes, err := os.ReadFile(closesLog)
	if err != nil {
		t.Fatalf("no closes logged: %v", err)
	}
	closesText := strings.TrimSpace(string(closesBytes))
	if !strings.Contains(closesText, "gt-base-123") {
		t.Errorf("hooked bead gt-base-123 was not closed (closes log: %q)", closesText)
	}

	updatesBytes, _ := os.ReadFile(updatesLog)
	updatesText := strings.TrimSpace(string(updatesBytes))

	// Verify that gt done called 'bd update gt-base-123 --assignee='
	if !strings.Contains(updatesText, "update gt-base-123") {
		t.Errorf("hooked bead gt-base-123 was not unhooked after close\nupdates log: %q", updatesText)
	}
	if !strings.Contains(updatesText, "--assignee=") {
		t.Errorf("assignee was not cleared during unhook\nupdates log: %q", updatesText)
	}
}
