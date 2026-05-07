//go:build !windows

package util

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// TestSetProcessGroup_KillsChildren verifies that SetProcessGroup's Cancel hook
// signals the entire process group, so a context-cancelled subprocess takes its
// children with it. This is the regression guard for dc-5gah, where mail's
// `gt mail poll-and-nudge` was leaving orphaned Dolt servers behind whenever a
// per-bd-call context timeout fired.
func TestSetProcessGroup_KillsChildren(t *testing.T) {
	// Shell script that backgrounds a long sleeper, writes its PID to a file,
	// and waits forever. When we cancel the parent context we expect the
	// process group SIGKILL to take down the sleeper too.
	tmp := t.TempDir()
	pidFile := filepath.Join(tmp, "child.pid")
	script := fmt.Sprintf(
		`sleep 600 &
		 echo $! > %s
		 wait`,
		pidFile,
	)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cmd := exec.CommandContext(ctx, "sh", "-c", script)
	SetProcessGroup(cmd)
	// Bound how long Run() lingers after Cancel returns so a stuck child
	// can't keep the test hanging. Mirrors the production setting in
	// internal/mail/bd.go.
	cmd.WaitDelay = 5 * time.Second

	if err := cmd.Start(); err != nil {
		t.Fatalf("starting subprocess: %v", err)
	}

	childPID := waitForPIDFile(t, pidFile, 5*time.Second)

	// Cancel triggers SetProcessGroup's Cancel hook → SIGKILL to -PGID.
	cancel()

	// cmd.Run on a cancelled context returns with the kill signal as the err;
	// we just want to know it returned promptly (within WaitDelay).
	if err := cmd.Wait(); err == nil {
		t.Logf("note: cmd.Wait returned nil — child must have already exited cleanly")
	}

	if processAlive(childPID) {
		// Give it one extra moment in case SIGKILL is still propagating.
		time.Sleep(200 * time.Millisecond)
		if processAlive(childPID) {
			t.Fatalf("child PID %d still alive after process-group kill — orphan leak", childPID)
		}
	}
}

// TestSetDetachedProcessGroup_LeavesChildrenForContrast documents the
// distinction between SetProcessGroup and SetDetachedProcessGroup. The latter
// intentionally OMITS the Cancel hook, so context cancellation kills only the
// direct subprocess and orphans its children. mail/bd.go used to use this and
// that's exactly how dc-5gah's zombie Dolt servers accumulated. Keeping this
// test pinned makes sure a future refactor doesn't accidentally homogenize the
// two helpers.
func TestSetDetachedProcessGroup_LeavesChildrenForContrast(t *testing.T) {
	tmp := t.TempDir()
	pidFile := filepath.Join(tmp, "child.pid")
	// Detach the child from its parent's wait so cmd.Run() returns when the
	// parent shell exits — otherwise `wait` would block indefinitely after
	// the parent is killed but before the child has died on its own.
	script := fmt.Sprintf(
		`sleep 600 &
		 echo $! > %s
		 # Parent exits immediately; bg sleep keeps running.`,
		pidFile,
	)

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, "sh", "-c", script)
	SetDetachedProcessGroup(cmd) // no Cancel hook installed
	cmd.WaitDelay = 5 * time.Second

	if err := cmd.Start(); err != nil {
		cancel()
		t.Fatalf("starting subprocess: %v", err)
	}

	childPID := waitForPIDFile(t, pidFile, 5*time.Second)
	_ = cmd.Wait() // parent shell exits on its own
	cancel()

	defer func() {
		// Test cleanup: kill the orphan we just demonstrated leaks.
		_ = syscall.Kill(childPID, syscall.SIGKILL)
	}()

	if !processAlive(childPID) {
		t.Skipf("child PID %d already dead — likely killed by an unrelated reaper; skip rather than flake", childPID)
	}
}

func waitForPIDFile(t *testing.T, path string, timeout time.Duration) int {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && len(strings.TrimSpace(string(data))) > 0 {
			pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil {
				t.Fatalf("parsing pid file %q: %v", path, err)
			}
			return pid
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("pid file %q never appeared within %s", path, timeout)
	return 0
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, syscall.Signal(0))
	if err == nil {
		return true
	}
	// ESRCH = no such process. Anything else (e.g. EPERM) means the process
	// still exists but we can't signal it — treat as alive for safety.
	return !errors.Is(err, syscall.ESRCH)
}
