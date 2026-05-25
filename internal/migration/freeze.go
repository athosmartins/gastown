// Package migration provides a town-wide write-freeze mechanism used during
// dolt database migrations. Unlike estop (which freezes agent tmux sessions),
// the freeze sentinel only blocks gt write commands that would mutate town
// dolt state — agents are free to keep thinking, reading, and using non-gt
// tools.
//
// See ~/gt/docs/guides/dolt-migration-playbook.md for the operator workflow.
package migration

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// FileName is the freeze sentinel placed at the town root.
const FileName = "MIGRATION-FREEZE"

// Info is the parsed contents of a MIGRATION-FREEZE file.
type Info struct {
	Operator  string    // who initiated the freeze (e.g. "mayor", a username)
	Reason    string    // human-readable migration reason
	Timestamp time.Time // when the freeze was set
}

// FilePath returns the full path to the freeze sentinel file.
func FilePath(townRoot string) string {
	return filepath.Join(townRoot, FileName)
}

// IsFrozen reports whether a migration freeze is currently active.
func IsFrozen(townRoot string) bool {
	_, err := os.Stat(FilePath(townRoot))
	return err == nil
}

// Read parses the freeze sentinel. Returns nil if not frozen.
func Read(townRoot string) *Info {
	data, err := os.ReadFile(FilePath(townRoot))
	if err != nil {
		return nil
	}
	return parse(string(data))
}

// Freeze creates the freeze sentinel.
func Freeze(townRoot, operator, reason string) error {
	ts := time.Now().Format(time.RFC3339)
	content := fmt.Sprintf("%s\t%s\t%s\n", operator, ts, reason)
	return os.WriteFile(FilePath(townRoot), []byte(content), 0644)
}

// Thaw removes the freeze sentinel. Idempotent — returns nil if not frozen.
func Thaw(townRoot string) error {
	err := os.Remove(FilePath(townRoot))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func parse(content string) *Info {
	content = strings.TrimSpace(content)
	if content == "" {
		return &Info{Timestamp: time.Now()}
	}
	parts := strings.SplitN(content, "\t", 3)
	info := &Info{}
	if len(parts) >= 1 {
		info.Operator = parts[0]
	}
	if len(parts) >= 2 {
		if t, err := time.Parse(time.RFC3339, parts[1]); err == nil {
			info.Timestamp = t
		}
	}
	if len(parts) >= 3 {
		info.Reason = parts[2]
	}
	return info
}
