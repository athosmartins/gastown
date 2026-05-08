package cmd

import (
	"strings"
	"testing"

	"github.com/steveyegge/gastown/internal/mail"
)

func TestParseMinPriorityThreshold(t *testing.T) {
	tests := []struct {
		input string
		want  int
	}{
		{"P0", 0}, {"p0", 0}, {"urgent", 0}, {"URGENT", 0}, {"0", 0},
		{"P1", 1}, {"p1", 1}, {"high", 1}, {"HIGH", 1}, {"1", 1},
		{"P2", 2}, {"p2", 2}, {"normal", 2}, {"NORMAL", 2}, {"2", 2},
		{"P3", 3}, {"p3", 3}, {"low", 3}, {"LOW", 3}, {"3", 3},
		{"", 2}, {"invalid", 2}, {"P4", 2},
	}
	for _, tt := range tests {
		got := parseMinPriorityThreshold(tt.input)
		if got != tt.want {
			t.Errorf("parseMinPriorityThreshold(%q) = %d, want %d", tt.input, got, tt.want)
		}
	}
}

func TestInjectThresholdMet(t *testing.T) {
	mkMsg := func(from, subject string, priority mail.Priority) *mail.Message {
		return &mail.Message{From: from, Subject: subject, Priority: priority}
	}

	tests := []struct {
		name        string
		msgs        []*mail.Message
		minPriority string
		want        bool
	}{
		{
			name:        "no messages",
			msgs:        nil,
			minPriority: "P2",
			want:        false,
		},
		{
			name:        "normal message, P2 threshold (default behavior)",
			msgs:        []*mail.Message{mkMsg("gastown/toast", "FYI", mail.PriorityNormal)},
			minPriority: "P2",
			want:        true,
		},
		{
			name:        "normal message, P1 threshold — suppressed",
			msgs:        []*mail.Message{mkMsg("gastown/toast", "convoy ack", mail.PriorityNormal)},
			minPriority: "P1",
			want:        false,
		},
		{
			name:        "low message, P1 threshold — suppressed",
			msgs:        []*mail.Message{mkMsg("gastown/nux", "backlog", mail.PriorityLow)},
			minPriority: "P1",
			want:        false,
		},
		{
			name:        "high message, P1 threshold — passes",
			msgs:        []*mail.Message{mkMsg("gastown/wolf", "review needed", mail.PriorityHigh)},
			minPriority: "P1",
			want:        true,
		},
		{
			name:        "urgent message, P1 threshold — passes",
			msgs:        []*mail.Message{mkMsg("mayor/", "fire", mail.PriorityUrgent)},
			minPriority: "P1",
			want:        true,
		},
		{
			name:        "urgent message, P0 threshold — passes",
			msgs:        []*mail.Message{mkMsg("mayor/", "fire", mail.PriorityUrgent)},
			minPriority: "P0",
			want:        true,
		},
		{
			name:        "high message, P0 threshold — suppressed",
			msgs:        []*mail.Message{mkMsg("mayor/", "important", mail.PriorityHigh)},
			minPriority: "P0",
			want:        false,
		},
		{
			name:        "overseer sender always passes regardless of priority",
			msgs:        []*mail.Message{mkMsg("overseer", "check in", mail.PriorityLow)},
			minPriority: "P0",
			want:        true,
		},
		{
			name:        "escalation subject always passes regardless of priority",
			msgs:        []*mail.Message{mkMsg("gastown/toast", "[ESCALATION-HIGH] infra down", mail.PriorityNormal)},
			minPriority: "P0",
			want:        true,
		},
		{
			name: "mixed: normal below threshold + high at threshold",
			msgs: []*mail.Message{
				mkMsg("gastown/toast", "convoy done", mail.PriorityNormal),
				mkMsg("gastown/wolf", "review needed", mail.PriorityHigh),
			},
			minPriority: "P1",
			want:        true,
		},
		{
			name: "mixed: all below threshold",
			msgs: []*mail.Message{
				mkMsg("gastown/toast", "convoy done", mail.PriorityNormal),
				mkMsg("gastown/nux", "fyi", mail.PriorityLow),
			},
			minPriority: "P1",
			want:        false,
		},
		{
			name:        "nil message in slice skipped",
			msgs:        []*mail.Message{nil, mkMsg("gastown/wolf", "review", mail.PriorityHigh)},
			minPriority: "P1",
			want:        true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := injectThresholdMet(tt.msgs, tt.minPriority)
			if got != tt.want {
				t.Errorf("injectThresholdMet(..., %q) = %v, want %v", tt.minPriority, got, tt.want)
			}
		})
	}
}

func TestFormatInjectOutput(t *testing.T) {
	// Helper to build test messages with a given priority.
	msg := func(id, from, subject string, priority mail.Priority) *mail.Message {
		return &mail.Message{
			ID:       id,
			From:     from,
			Subject:  subject,
			Priority: priority,
		}
	}

	tests := []struct {
		name     string
		messages []*mail.Message
		// Strings that MUST appear in the output.
		wantContains []string
		// Strings that must NOT appear in the output.
		wantAbsent []string
	}{
		{
			name: "urgent only",
			messages: []*mail.Message{
				msg("m1", "mayor/", "Deploy now", mail.PriorityUrgent),
			},
			wantContains: []string{
				"<system-reminder>",
				"</system-reminder>",
				"URGENT: 1 urgent message(s)",
				"m1 from mayor/: Deploy now",
				"gt mail read <id>",
			},
			wantAbsent: []string{
				"high-priority",
				"additional",
			},
		},
		{
			name: "high only",
			messages: []*mail.Message{
				msg("m2", "gastown/wolf", "Review PR", mail.PriorityHigh),
			},
			wantContains: []string{
				"<system-reminder>",
				"1 high-priority message(s)",
				"m2 from gastown/wolf: Review PR",
				"process these messages",
				"before going idle",
			},
			wantAbsent: []string{
				"URGENT",
				"additional",
			},
		},
		{
			name: "normal only",
			messages: []*mail.Message{
				msg("m3", "gastown/toast", "FYI update", mail.PriorityNormal),
			},
			wantContains: []string{
				"<system-reminder>",
				"1 unread message(s)",
				"m3 from gastown/toast: FYI update",
				"check these messages",
				"before going idle",
			},
			wantAbsent: []string{
				"URGENT",
				"high-priority",
			},
		},
		{
			name: "low priority treated as normal tier",
			messages: []*mail.Message{
				msg("m4", "gastown/nux", "Backlog item", mail.PriorityLow),
			},
			wantContains: []string{
				"1 unread message(s)",
				"m4 from gastown/nux: Backlog item",
				"check these messages",
			},
			wantAbsent: []string{
				"URGENT",
				"high-priority",
			},
		},
		{
			name: "urgent + high: high listed separately",
			messages: []*mail.Message{
				msg("m5", "mayor/", "Emergency", mail.PriorityUrgent),
				msg("m6", "gastown/wolf", "Important review", mail.PriorityHigh),
			},
			wantContains: []string{
				"URGENT: 1 urgent message(s)",
				"m5 from mayor/: Emergency",
				"1 high-priority message(s)",
				"m6 from gastown/wolf: Important review",
				"process before going idle",
				"gt mail read <id>",
			},
			wantAbsent: []string{
				// High-priority should NOT be folded into a generic "non-urgent" count.
				"non-urgent",
			},
		},
		{
			name: "urgent + high + normal: all tiers shown",
			messages: []*mail.Message{
				msg("m7", "mayor/", "Fire", mail.PriorityUrgent),
				msg("m8", "gastown/wolf", "Review ASAP", mail.PriorityHigh),
				msg("m9", "gastown/toast", "Newsletter", mail.PriorityNormal),
			},
			wantContains: []string{
				"URGENT: 1 urgent message(s)",
				"m7 from mayor/: Fire",
				"1 high-priority message(s)",
				"m8 from gastown/wolf: Review ASAP",
				"1 additional message(s)",
			},
			wantAbsent: []string{
				"normal-priority",
				"non-urgent",
			},
		},
		{
			name: "urgent + normal (no high): normal shown as additional",
			messages: []*mail.Message{
				msg("m10", "mayor/", "Alert", mail.PriorityUrgent),
				msg("m11", "gastown/nux", "Low item", mail.PriorityLow),
				msg("m12", "gastown/toast", "Info", mail.PriorityNormal),
			},
			wantContains: []string{
				"URGENT: 1 urgent message(s)",
				"2 additional message(s)",
			},
			wantAbsent: []string{
				"high-priority",
				"normal-priority",
			},
		},
		{
			name: "high + normal: normal shown as additional",
			messages: []*mail.Message{
				msg("m13", "gastown/wolf", "Review", mail.PriorityHigh),
				msg("m14", "gastown/toast", "FYI", mail.PriorityNormal),
				msg("m15", "gastown/nux", "Backlog", mail.PriorityLow),
			},
			wantContains: []string{
				"1 high-priority message(s)",
				"2 additional message(s)",
			},
			wantAbsent: []string{
				"URGENT",
				"normal-priority",
			},
		},
		{
			name: "multiple urgent messages",
			messages: []*mail.Message{
				msg("m16", "mayor/", "Fire 1", mail.PriorityUrgent),
				msg("m17", "deacon/", "Fire 2", mail.PriorityUrgent),
			},
			wantContains: []string{
				"URGENT: 2 urgent message(s)",
				"m16 from mayor/: Fire 1",
				"m17 from deacon/: Fire 2",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			output := formatInjectOutput(tt.messages)

			for _, want := range tt.wantContains {
				if !strings.Contains(output, want) {
					t.Errorf("output should contain %q\n\nGot:\n%s", want, output)
				}
			}
			for _, absent := range tt.wantAbsent {
				if strings.Contains(output, absent) {
					t.Errorf("output should NOT contain %q\n\nGot:\n%s", absent, output)
				}
			}
		})
	}
}
