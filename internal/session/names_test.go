package session

import (
	"testing"
)

func TestMayorSessionName(t *testing.T) {
	// Mayor session name is now fixed (one per machine), uses HQ prefix
	want := "hq-mayor"
	got := MayorSessionName()
	if got != want {
		t.Errorf("MayorSessionName() = %q, want %q", got, want)
	}
}

func TestDeaconSessionName(t *testing.T) {
	// Deacon session name is now fixed (one per machine), uses HQ prefix
	want := "hq-deacon"
	got := DeaconSessionName()
	if got != want {
		t.Errorf("DeaconSessionName() = %q, want %q", got, want)
	}
}

func TestOverseerSessionName(t *testing.T) {
	want := "hq-overseer"
	got := OverseerSessionName()
	if got != want {
		t.Errorf("OverseerSessionName() = %q, want %q", got, want)
	}
}

func TestWitnessSessionName(t *testing.T) {
	tests := []struct {
		rigPrefix string
		want      string
	}{
		{"gt", "gt-witness"},
		{"bd", "bd-witness"},
		{"hop", "hop-witness"},
		{"sky", "sky-witness"},
	}
	for _, tt := range tests {
		t.Run(tt.rigPrefix, func(t *testing.T) {
			got := WitnessSessionName(tt.rigPrefix)
			if got != tt.want {
				t.Errorf("WitnessSessionName(%q) = %q, want %q", tt.rigPrefix, got, tt.want)
			}
		})
	}
}

func TestRefinerySessionName(t *testing.T) {
	tests := []struct {
		rigPrefix string
		want      string
	}{
		{"gt", "gt-refinery"},
		{"bd", "bd-refinery"},
		{"hop", "hop-refinery"},
	}
	for _, tt := range tests {
		t.Run(tt.rigPrefix, func(t *testing.T) {
			got := RefinerySessionName(tt.rigPrefix)
			if got != tt.want {
				t.Errorf("RefinerySessionName(%q) = %q, want %q", tt.rigPrefix, got, tt.want)
			}
		})
	}
}

func TestCrewSessionName(t *testing.T) {
	tests := []struct {
		rigPrefix string
		name      string
		want      string
	}{
		{"gt", "max", "gt-crew-max"},
		{"bd", "alice", "bd-crew-alice"},
		{"hop", "bar", "hop-crew-bar"},
	}
	for _, tt := range tests {
		t.Run(tt.rigPrefix+"/"+tt.name, func(t *testing.T) {
			got := CrewSessionName(tt.rigPrefix, tt.name)
			if got != tt.want {
				t.Errorf("CrewSessionName(%q, %q) = %q, want %q", tt.rigPrefix, tt.name, got, tt.want)
			}
		})
	}
}

func TestPolecatSessionName(t *testing.T) {
	tests := []struct {
		rigPrefix string
		name      string
		want      string
	}{
		{"gt", "Toast", "gt-Toast"},
		{"gt", "Furiosa", "gt-Furiosa"},
		{"bd", "worker1", "bd-worker1"},
		{"hop", "ostrom", "hop-ostrom"},
	}
	for _, tt := range tests {
		t.Run(tt.rigPrefix+"/"+tt.name, func(t *testing.T) {
			got := PolecatSessionName(tt.rigPrefix, tt.name)
			if got != tt.want {
				t.Errorf("PolecatSessionName(%q, %q) = %q, want %q", tt.rigPrefix, tt.name, got, tt.want)
			}
		})
	}
}

func TestDefaultPrefix(t *testing.T) {
	want := "gt"
	if DefaultPrefix != want {
		t.Errorf("DefaultPrefix = %q, want %q", DefaultPrefix, want)
	}
}

func TestLegacyWitnessSessionName(t *testing.T) {
	tests := []struct {
		rigName string
		want    string
	}{
		{"gastown", "gt-gastown-witness"},
		{"beads", "gt-beads-witness"},
		{"whatsapp_automation", "gt-whatsapp_automation-witness"},
		{"hop", "gt-hop-witness"},
	}
	for _, tt := range tests {
		t.Run(tt.rigName, func(t *testing.T) {
			got := LegacyWitnessSessionName(tt.rigName)
			if got != tt.want {
				t.Errorf("LegacyWitnessSessionName(%q) = %q, want %q", tt.rigName, got, tt.want)
			}
		})
	}
}

func TestLegacyRefinerySessionName(t *testing.T) {
	tests := []struct {
		rigName string
		want    string
	}{
		{"gastown", "gt-gastown-refinery"},
		{"beads", "gt-beads-refinery"},
		{"whatsapp_automation", "gt-whatsapp_automation-refinery"},
		{"hop", "gt-hop-refinery"},
	}
	for _, tt := range tests {
		t.Run(tt.rigName, func(t *testing.T) {
			got := LegacyRefinerySessionName(tt.rigName)
			if got != tt.want {
				t.Errorf("LegacyRefinerySessionName(%q) = %q, want %q", tt.rigName, got, tt.want)
			}
		})
	}
}

// TestLegacyVsCurrentSessionNames verifies legacy names differ from current names
// for rigs where the prefix differs from the rig name (the typical upgrade scenario).
func TestLegacyVsCurrentSessionNames(t *testing.T) {
	tests := []struct {
		rigName   string
		rigPrefix string
	}{
		{"whatsapp_automation", "wa"},
		{"beads", "bd"},
		{"gastown", "gt"},
	}
	for _, tt := range tests {
		t.Run(tt.rigName, func(t *testing.T) {
			// Verify legacy differs from current when prefix != rig name
			legacyWitness := LegacyWitnessSessionName(tt.rigName)
			currentWitness := WitnessSessionName(tt.rigPrefix)

			legacyRefinery := LegacyRefinerySessionName(tt.rigName)
			currentRefinery := RefinerySessionName(tt.rigPrefix)

			// For rigs where prefix == rig name (e.g., "gastown" with prefix "gt"),
			// the names will differ (gt-gastown-witness vs gt-witness).
			// For any rig, they should never be equal.
			if legacyWitness == currentWitness {
				t.Errorf("LegacyWitnessSessionName(%q) == WitnessSessionName(%q) = %q; expected different names",
					tt.rigName, tt.rigPrefix, legacyWitness)
			}
			if legacyRefinery == currentRefinery {
				t.Errorf("LegacyRefinerySessionName(%q) == RefinerySessionName(%q) = %q; expected different names",
					tt.rigName, tt.rigPrefix, legacyRefinery)
			}
		})
	}
}
