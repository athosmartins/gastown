package cmd

import (
	"os"
	"testing"
)

// clearAgentContextEnv zeroes every env var isGasTownAgentContext checks, so
// each test controls its own signal instead of inheriting whatever the
// process happens to be running under (e.g. GC_AGENT is set for real when
// these tests run inside a live Gas Town/Gas City agent session).
func clearAgentContextEnv(t *testing.T) {
	t.Helper()
	for _, env := range []string{
		"GT_POLECAT", "GT_CREW", "GT_WITNESS", "GT_REFINERY", "GT_MAYOR", "GT_DEACON",
		"GC_AGENT", "GC_ROLE",
	} {
		t.Setenv(env, "")
	}
}

// chdirNeutral moves the process to a tmp dir containing neither "/crew/"
// nor "/polecats/" in its path, so the cwd-based fallback in
// isGasTownAgentContext never fires as a side channel in these tests.
func chdirNeutral(t *testing.T) {
	t.Helper()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
}

// TestIsGasTownAgentContext_GCAgentOnly is the regression case for ga-4k548:
// a Gas City-migrated agent (measured live in a dog-pool session) sets only
// GC_AGENT and leaves every legacy GT_* var and GC_ROLE empty. Before this
// fix, isGasTownAgentContext (shared by the pr-workflow, bd-init, and
// mol-patrol guards) had no signal to key off and returned false, so all
// three guards silently allowed the operations they exist to block.
func TestIsGasTownAgentContext_GCAgentOnly(t *testing.T) {
	clearAgentContextEnv(t)
	chdirNeutral(t)

	t.Setenv("GC_AGENT", "gastown.dog-5")

	if !isGasTownAgentContext() {
		t.Fatal("expected true with only GC_AGENT set (Gas City agent identity), got false")
	}
}

// TestIsGasTownAgentContext_LegacyGTVarsStillWork guards against the fix
// narrowing detection instead of only widening it.
func TestIsGasTownAgentContext_LegacyGTVarsStillWork(t *testing.T) {
	for _, env := range []string{"GT_POLECAT", "GT_CREW", "GT_WITNESS", "GT_REFINERY", "GT_MAYOR", "GT_DEACON"} {
		t.Run(env, func(t *testing.T) {
			clearAgentContextEnv(t)
			chdirNeutral(t)
			t.Setenv(env, "1")

			if !isGasTownAgentContext() {
				t.Fatalf("expected true with %s set, got false", env)
			}
		})
	}
}

// TestIsGasTownAgentContext_NoSignal confirms the negative case is
// unaffected: no legacy var, no GC_AGENT, and a neutral cwd must still
// allow (return false), so humans and non-agent tooling are not swept in.
func TestIsGasTownAgentContext_NoSignal(t *testing.T) {
	clearAgentContextEnv(t)
	chdirNeutral(t)

	if isGasTownAgentContext() {
		t.Fatal("expected false with no agent signal set, got true")
	}
}
