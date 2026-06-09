package beads

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// EnsureConfigYAML ensures config.yaml has both prefix keys set for the given
// beads namespace. Existing non-prefix settings are preserved.
func EnsureConfigYAML(beadsDir, prefix string) error {
	return ensureConfigYAML(beadsDir, prefix, false)
}

// EnsureConfigYAMLIfMissing creates config.yaml with the required defaults when
// it is missing. Existing files are left untouched.
func EnsureConfigYAMLIfMissing(beadsDir, prefix string) error {
	return ensureConfigYAML(beadsDir, prefix, true)
}

// EnsureConfigYAMLFromMetadataIfMissing creates config.yaml when missing using
// metadata-derived defaults for prefix when available.
func EnsureConfigYAMLFromMetadataIfMissing(beadsDir, fallbackPrefix string) error {
	prefix := ConfigDefaultsFromMetadata(beadsDir, fallbackPrefix)
	return ensureConfigYAML(beadsDir, prefix, true)
}

// ConfigDefaultsFromMetadata derives config.yaml defaults from metadata.json.
// Falls back to fallbackPrefix when fields are absent.
func ConfigDefaultsFromMetadata(beadsDir, fallbackPrefix string) string {
	prefix := strings.TrimSpace(strings.TrimSuffix(fallbackPrefix, "-"))
	if prefix == "" {
		prefix = fallbackPrefix
	}

	data, err := os.ReadFile(filepath.Join(beadsDir, "metadata.json"))
	if err != nil {
		return prefix
	}

	var meta map[string]interface{}
	if err := json.Unmarshal(data, &meta); err != nil {
		return prefix
	}

	if derived := firstString(meta, "issue_prefix", "issue-prefix", "prefix"); derived != "" {
		prefix = strings.TrimSpace(strings.TrimSuffix(derived, "-"))
	} else if doltDB := firstString(meta, "dolt_database"); doltDB != "" {
		prefix = normalizeDoltDatabasePrefix(doltDB)
	}

	return prefix
}

func firstString(values map[string]interface{}, keys ...string) string {
	for _, key := range keys {
		raw, ok := values[key]
		if !ok {
			continue
		}
		s, ok := raw.(string)
		if !ok {
			continue
		}
		s = strings.TrimSpace(s)
		if s != "" {
			return s
		}
	}
	return ""
}

func normalizeDoltDatabasePrefix(dbName string) string {
	name := strings.TrimSpace(strings.TrimSuffix(dbName, "-"))
	if strings.HasPrefix(name, "beads_") {
		trimmed := strings.TrimPrefix(name, "beads_")
		if trimmed != "" {
			return trimmed
		}
	}
	return name
}

// ConfigYAMLDisablesAutoExport reports whether config.yaml content explicitly
// disables bd's post-run auto-export. Comments do not count as configuration.
func ConfigYAMLDisablesAutoExport(content string) bool {
	for _, line := range strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.HasPrefix(trimmed, "export.auto:") {
			value := strings.TrimSpace(strings.TrimPrefix(trimmed, "export.auto:"))
			value = strings.Trim(value, `"'`)
			return strings.EqualFold(value, "false")
		}
	}
	return false
}

// MergeConfigYAMLCustomTypes reads config.yaml, merges the existing types.custom
// value (if any) with requiredTypes, deduplicates, sorts, and writes back a clean
// unquoted comma-separated value. Calling this instead of "bd config set types.custom"
// avoids the append-after-quote corruption that older bd versions produce when the
// existing value is YAML-quoted (e.g. "molecule,...,step",newval is invalid YAML).
func MergeConfigYAMLCustomTypes(beadsDir string, requiredTypes []string) error {
	configPath := filepath.Join(beadsDir, "config.yaml")
	data, err := os.ReadFile(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // nothing to fix; EnsureConfigYAML will create the file
		}
		return err
	}

	content := strings.ReplaceAll(string(data), "\r\n", "\n")
	lines := strings.Split(content, "\n")

	typeSet := make(map[string]bool)
	for _, t := range requiredTypes {
		t = strings.TrimSpace(t)
		if t != "" {
			typeSet[t] = true
		}
	}

	found := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "types.custom:") {
			continue
		}
		found = true

		// Parse existing value — strip surrounding YAML quotes, then split on comma.
		val := strings.TrimSpace(strings.TrimPrefix(trimmed, "types.custom:"))
		val = strings.Trim(val, `"'`)
		for _, t := range strings.Split(val, ",") {
			t = strings.TrimSpace(t)
			if t != "" {
				typeSet[t] = true
			}
		}

		lines[i] = "types.custom: " + joinSorted(typeSet)
		break
	}

	if !found && len(typeSet) > 0 {
		lines = append(lines, "types.custom: "+joinSorted(typeSet))
	}

	newContent := strings.Join(lines, "\n")
	if !strings.HasSuffix(newContent, "\n") {
		newContent += "\n"
	}
	if newContent == content {
		return nil
	}
	return os.WriteFile(configPath, []byte(newContent), 0644)
}

func joinSorted(m map[string]bool) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return strings.Join(keys, ",")
}

func ensureConfigYAML(beadsDir, prefix string, onlyIfMissing bool) error {
	configPath := filepath.Join(beadsDir, "config.yaml")
	wantPrefix := "prefix: " + prefix
	wantIssuePrefix := "issue-prefix: " + prefix
	// Gas Town rigs should disable idle-monitor to use centralized Dolt server
	wantIdleTimeout := "dolt.idle-timeout: \"0\""
	// Gas Town stores beads in Dolt/server-mode runtime directories that are often
	// redirected or gitignored; bd's post-run auto-export git-add is noisy there.
	wantExportAuto := "export.auto: \"false\""

	data, err := os.ReadFile(configPath)
	if os.IsNotExist(err) {
		// New config: include all Gas Town defaults
		content := wantPrefix + "\n" + wantIssuePrefix + "\n" + wantIdleTimeout + "\n" + wantExportAuto + "\n"
		return os.WriteFile(configPath, []byte(content), 0644)
	}
	if err != nil {
		return err
	}
	if onlyIfMissing {
		return nil
	}

	content := strings.ReplaceAll(string(data), "\r\n", "\n")
	lines := strings.Split(content, "\n")
	foundPrefix := false
	foundIssuePrefix := false
	foundIdleTimeout := false
	foundExportAuto := false

	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "prefix:") {
			lines[i] = wantPrefix
			foundPrefix = true
			continue
		}
		if strings.HasPrefix(trimmed, "issue-prefix:") {
			lines[i] = wantIssuePrefix
			foundIssuePrefix = true
			continue
		}
		if strings.HasPrefix(trimmed, "dolt.idle-timeout:") {
			lines[i] = wantIdleTimeout
			foundIdleTimeout = true
			continue
		}
		if strings.HasPrefix(trimmed, "export.auto:") {
			lines[i] = wantExportAuto
			foundExportAuto = true
			continue
		}
	}

	if !foundPrefix {
		lines = append(lines, wantPrefix)
	}
	if !foundIssuePrefix {
		lines = append(lines, wantIssuePrefix)
	}
	if !foundIdleTimeout {
		lines = append(lines, wantIdleTimeout)
	}
	if !foundExportAuto {
		lines = append(lines, wantExportAuto)
	}

	newContent := strings.Join(lines, "\n")
	if !strings.HasSuffix(newContent, "\n") {
		newContent += "\n"
	}
	if newContent == content {
		return nil
	}

	return os.WriteFile(configPath, []byte(newContent), 0644)
}
