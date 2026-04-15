package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// makeTranscriptLine builds a minimal JSONL line for an assistant message with usage.
func makeTranscriptLine(model string, inputTokens, cacheRead, cacheCreate, outputTokens int) []byte {
	msg := TranscriptMessage{
		Type: "assistant",
		Message: &TranscriptMessageBody{
			Model: model,
			Role:  "assistant",
			Usage: &TranscriptUsage{
				InputTokens:              inputTokens,
				CacheReadInputTokens:     cacheRead,
				CacheCreationInputTokens: cacheCreate,
				OutputTokens:             outputTokens,
			},
		},
	}
	b, _ := json.Marshal(msg)
	return b
}

// writeTranscript writes JSONL lines to a temp file and returns its path.
func writeTranscript(t *testing.T, lines [][]byte) string {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "transcript-*.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range lines {
		f.Write(line)
		f.WriteString("\n")
	}
	f.Close()
	return f.Name()
}

func TestReadContextUsagePercent_Basic(t *testing.T) {
	// 130k tokens used, 200k window → 65.0%
	path := writeTranscript(t, [][]byte{
		makeTranscriptLine("claude-haiku-4-5-20251001", 40000, 80000, 10000, 500),
	})

	pct, model, err := readContextUsagePercent(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if model != "claude-haiku-4-5-20251001" {
		t.Errorf("model = %q, want %q", model, "claude-haiku-4-5-20251001")
	}
	// input(40k) + cacheRead(80k) + cacheCreate(10k) = 130k / 200k = 65%
	want := 65.0
	if pct < want-0.01 || pct > want+0.01 {
		t.Errorf("pct = %.2f, want %.2f", pct, want)
	}
}

func TestReadContextUsagePercent_UsesLastMessage(t *testing.T) {
	// Two assistant turns — should use the last one.
	path := writeTranscript(t, [][]byte{
		makeTranscriptLine("claude-haiku-4-5-20251001", 10000, 0, 0, 100), // early turn
		{'{', '}'},                                                          // non-assistant line (skipped)
		makeTranscriptLine("claude-haiku-4-5-20251001", 80000, 60000, 20000, 1000), // latest turn
	})

	pct, _, err := readContextUsagePercent(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// latest: 80k+60k+20k = 160k / 200k = 80%
	want := 80.0
	if pct < want-0.01 || pct > want+0.01 {
		t.Errorf("pct = %.2f, want %.2f (should use last turn)", pct, want)
	}
}

func TestReadContextUsagePercent_NoAssistantMessages(t *testing.T) {
	// A transcript with only a permission-mode line — no assistant messages.
	path := writeTranscript(t, [][]byte{
		[]byte(`{"type":"permission-mode","permissionMode":"bypassPermissions"}`),
	})

	_, _, err := readContextUsagePercent(path)
	if err == nil {
		t.Error("expected error for transcript with no assistant messages")
	}
}

func TestReadContextUsagePercent_EmptyFile(t *testing.T) {
	path := writeTranscript(t, nil)
	_, _, err := readContextUsagePercent(path)
	if err == nil {
		t.Error("expected error for empty transcript")
	}
}

func TestReadContextUsagePercent_MissingFile(t *testing.T) {
	_, _, err := readContextUsagePercent(filepath.Join(t.TempDir(), "nonexistent.jsonl"))
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestContextWindowSizeForModel_Always200k(t *testing.T) {
	cases := []string{
		"claude-haiku-4-5-20251001",
		"claude-sonnet-4-6",
		"claude-opus-4-6",
		"claude-3-5-haiku-20241022",
		"some-future-model",
		"",
	}
	for _, model := range cases {
		if got := contextWindowSizeForModel(model); got != 200_000 {
			t.Errorf("contextWindowSizeForModel(%q) = %d, want 200000", model, got)
		}
	}
}

func TestReadContextUsagePercent_SkipsMalformedLines(t *testing.T) {
	// Mix of malformed JSON and valid assistant messages.
	path := writeTranscript(t, [][]byte{
		[]byte(`not valid json at all`),
		makeTranscriptLine("claude-haiku-4-5-20251001", 100000, 0, 0, 0),
		[]byte(`{"broken": `), // truncated JSON
	})

	pct, _, err := readContextUsagePercent(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 100k / 200k = 50%
	want := 50.0
	if pct < want-0.01 || pct > want+0.01 {
		t.Errorf("pct = %.2f, want %.2f", pct, want)
	}
}
