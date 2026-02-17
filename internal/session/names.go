// Package session provides polecat session lifecycle management.
package session

import (
	"fmt"
)

// DefaultPrefix is the default beads prefix used when no rig-specific prefix is known.
const DefaultPrefix = "gt"

// HQPrefix is the prefix for town-level services (Mayor, Deacon).
const HQPrefix = "hq-"

// MayorSessionName returns the session name for the Mayor agent.
// One mayor per machine - multi-town requires containers/VMs for isolation.
func MayorSessionName() string {
	return HQPrefix + "mayor"
}

// DeaconSessionName returns the session name for the Deacon agent.
// One deacon per machine - multi-town requires containers/VMs for isolation.
func DeaconSessionName() string {
	return HQPrefix + "deacon"
}

// WitnessSessionName returns the session name for a rig's Witness agent.
// rigPrefix is the rig's beads prefix (e.g., "gt" for gastown, "bd" for beads).
func WitnessSessionName(rigPrefix string) string {
	return fmt.Sprintf("%s-witness", rigPrefix)
}

// RefinerySessionName returns the session name for a rig's Refinery agent.
// rigPrefix is the rig's beads prefix (e.g., "gt" for gastown, "bd" for beads).
func RefinerySessionName(rigPrefix string) string {
	return fmt.Sprintf("%s-refinery", rigPrefix)
}

// CrewSessionName returns the session name for a crew worker in a rig.
// rigPrefix is the rig's beads prefix (e.g., "gt" for gastown, "bd" for beads).
func CrewSessionName(rigPrefix, name string) string {
	return fmt.Sprintf("%s-crew-%s", rigPrefix, name)
}

// PolecatSessionName returns the session name for a polecat in a rig.
// rigPrefix is the rig's beads prefix (e.g., "gt" for gastown, "bd" for beads).
func PolecatSessionName(rigPrefix, name string) string {
	return fmt.Sprintf("%s-%s", rigPrefix, name)
}

// OverseerSessionName returns the session name for the human operator.
// The overseer is the human who controls Gas Town, not an AI agent.
func OverseerSessionName() string {
	return HQPrefix + "overseer"
}

// BootSessionName returns the session name for the Boot watchdog.
// Boot is town-level (launched by deacon), so it uses the hq- prefix.
// "hq-boot" avoids tmux prefix-matching collisions with "hq-deacon".
func BootSessionName() string {
	return HQPrefix + "boot"
}

// legacyGTPrefix is the old hardcoded prefix used before prefix-based naming (gt-gix74).
// Old format: "gt-{rigName}-{role}", new format: "{rigPrefix}-{role}".
const legacyGTPrefix = "gt-"

// LegacyWitnessSessionName returns the old-format witness session name from before
// the prefix-based naming change (gt-gix74). Used to detect and clean up zombie
// sessions that survive across upgrades.
// Old format: "gt-{rigName}-witness" (hardcoded gt- prefix + rig name).
// New format: "{rigPrefix}-witness" (rig-specific beads prefix).
func LegacyWitnessSessionName(rigName string) string {
	return legacyGTPrefix + rigName + "-witness"
}

// LegacyRefinerySessionName returns the old-format refinery session name from before
// the prefix-based naming change (gt-gix74). Used to detect and clean up zombie
// sessions that survive across upgrades.
// Old format: "gt-{rigName}-refinery" (hardcoded gt- prefix + rig name).
// New format: "{rigPrefix}-refinery" (rig-specific beads prefix).
func LegacyRefinerySessionName(rigName string) string {
	return legacyGTPrefix + rigName + "-refinery"
}
