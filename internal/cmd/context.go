package cmd

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var contextUsageFlag bool

var contextCmd = &cobra.Command{
	Use:     "context",
	GroupID: GroupDiag,
	Short:   "Check Claude session context window usage",
	Long: `Check the current Claude session's context window usage.

Reads the Claude Code transcript JSONL to determine how much of the
context window is currently in use.

Exit codes (--usage flag):
  0  context OK      (<65%)
  1  context warn    (65–79%) — prepare for handoff
  2  context critical (>=80%) — handoff immediately`,
	RunE: runContextCmd,
}

func init() {
	contextCmd.Flags().BoolVar(&contextUsageFlag, "usage", false, "Print context usage percentage and exit with status (1=warn, 2=critical)")
	rootCmd.AddCommand(contextCmd)
}

func runContextCmd(cmd *cobra.Command, args []string) error {
	if !contextUsageFlag {
		return cmd.Help()
	}

	workDir, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "context: %v\n", err)
		os.Exit(1)
	}

	projectDir, err := getClaudeProjectDir(workDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "context: could not locate Claude project dir: %v\n", err)
		os.Exit(1)
	}

	transcriptPath, err := findLatestTranscript(projectDir)
	if err != nil {
		// No transcript yet — treat as 0% (safe to continue)
		fmt.Println("0.0% (0k/200k)")
		return nil
	}

	pct, model, err := readContextUsagePercent(transcriptPath)
	if err != nil {
		// Cannot parse — treat as 0%
		fmt.Fprintf(os.Stderr, "context: %v\n", err)
		fmt.Println("0.0% (0k/200k)")
		return nil
	}

	contextSize := contextWindowSizeForModel(model)
	usedTokens := int(float64(contextSize) * pct / 100.0)
	fmt.Printf("%.1f%% (%dk/%dk)\n", pct, usedTokens/1000, contextSize/1000)

	if pct >= 80.0 {
		os.Exit(2) // critical
	} else if pct >= 65.0 {
		os.Exit(1) // warn
	}
	return nil // exit 0: OK
}

// contextWindowSizeForModel returns the context window size in tokens for a
// given Claude model ID. All current Claude 3.x / 4.x models use 200k tokens.
func contextWindowSizeForModel(_ string) int {
	return 200_000
}

// readContextUsagePercent opens the transcript at path and returns the
// context window usage as a percentage based on the LAST assistant turn.
// It also returns the model name so callers can look up the window size.
//
// Using the last turn (rather than summing all turns) is correct because
// each Claude API call sends the entire conversation as input, so the
// most-recent turn's input_tokens + cache_read + cache_creation reflects
// the total context sent on the latest request.
func readContextUsagePercent(transcriptPath string) (pct float64, model string, err error) {
	f, err := os.Open(transcriptPath)
	if err != nil {
		return 0, "", err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	buf := make([]byte, 0, 256*1024)
	scanner.Buffer(buf, 1024*1024)

	var lastUsage *TranscriptUsage
	var lastModel string

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var msg TranscriptMessage
		if err := json.Unmarshal(line, &msg); err != nil {
			continue // skip malformed lines
		}

		if msg.Type != "assistant" || msg.Message == nil || msg.Message.Usage == nil {
			continue
		}

		lastUsage = msg.Message.Usage
		if msg.Message.Model != "" {
			lastModel = msg.Message.Model
		}
	}

	if scanErr := scanner.Err(); scanErr != nil {
		return 0, "", scanErr
	}

	if lastUsage == nil {
		return 0, "", fmt.Errorf("no assistant messages with usage data found in transcript")
	}

	// Total tokens in the current context window = everything sent as input on the last turn.
	totalUsed := lastUsage.InputTokens + lastUsage.CacheReadInputTokens + lastUsage.CacheCreationInputTokens
	size := contextWindowSizeForModel(lastModel)

	return float64(totalUsed) / float64(size) * 100.0, lastModel, nil
}
