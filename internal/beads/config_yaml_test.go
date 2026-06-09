package beads

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureConfigYAMLIfMissing_DoesNotOverwriteExisting(t *testing.T) {
	beadsDir := t.TempDir()
	configPath := filepath.Join(beadsDir, "config.yaml")
	original := "prefix: keep\nissue-prefix: keep\n"
	if err := os.WriteFile(configPath, []byte(original), 0644); err != nil {
		t.Fatalf("write config.yaml: %v", err)
	}

	if err := EnsureConfigYAMLIfMissing(beadsDir, "hq"); err != nil {
		t.Fatalf("EnsureConfigYAMLIfMissing: %v", err)
	}

	after, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("read config.yaml: %v", err)
	}
	if string(after) != original {
		t.Fatalf("config.yaml changed:\n got: %q\nwant: %q", string(after), original)
	}
}

func TestEnsureConfigYAMLFromMetadataIfMissing_UsesMetadataPrefix(t *testing.T) {
	beadsDir := t.TempDir()
	metadata := `{"backend":"dolt","dolt_mode":"server","dolt_database":"hq","issue_prefix":"foo"}`
	if err := os.WriteFile(filepath.Join(beadsDir, "metadata.json"), []byte(metadata), 0644); err != nil {
		t.Fatalf("write metadata.json: %v", err)
	}

	if err := EnsureConfigYAMLFromMetadataIfMissing(beadsDir, "hq"); err != nil {
		t.Fatalf("EnsureConfigYAMLFromMetadataIfMissing: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
	if err != nil {
		t.Fatalf("read config.yaml: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "prefix: foo\n") {
		t.Fatalf("config.yaml missing metadata prefix: %q", got)
	}
	if !strings.Contains(got, "issue-prefix: foo\n") {
		t.Fatalf("config.yaml missing metadata issue-prefix: %q", got)
	}
	if !strings.Contains(got, "export.auto: \"false\"\n") {
		t.Fatalf("config.yaml missing export.auto default: %q", got)
	}
}

func TestConfigDefaultsFromMetadata_FallsBackToDoltDatabase(t *testing.T) {
	beadsDir := t.TempDir()
	metadata := `{"backend":"dolt","dolt_mode":"server","dolt_database":"hq-custom"}`
	if err := os.WriteFile(filepath.Join(beadsDir, "metadata.json"), []byte(metadata), 0644); err != nil {
		t.Fatalf("write metadata.json: %v", err)
	}

	prefix := ConfigDefaultsFromMetadata(beadsDir, "hq")
	if prefix != "hq-custom" {
		t.Fatalf("prefix = %q, want %q", prefix, "hq-custom")
	}
}

func TestConfigDefaultsFromMetadata_StripsLegacyBeadsPrefixFromDoltDatabase(t *testing.T) {
	beadsDir := t.TempDir()
	metadata := `{"backend":"dolt","dolt_mode":"server","dolt_database":"beads_hq"}`
	if err := os.WriteFile(filepath.Join(beadsDir, "metadata.json"), []byte(metadata), 0644); err != nil {
		t.Fatalf("write metadata.json: %v", err)
	}

	prefix := ConfigDefaultsFromMetadata(beadsDir, "fallback")
	if prefix != "hq" {
		t.Fatalf("prefix = %q, want %q", prefix, "hq")
	}
}

func TestEnsureConfigYAMLFromMetadataIfMissing_StripsLegacyBeadsPrefixFromDoltDatabase(t *testing.T) {
	beadsDir := t.TempDir()
	metadata := `{"backend":"dolt","dolt_mode":"server","dolt_database":"beads_hq"}`
	if err := os.WriteFile(filepath.Join(beadsDir, "metadata.json"), []byte(metadata), 0644); err != nil {
		t.Fatalf("write metadata.json: %v", err)
	}

	if err := EnsureConfigYAMLFromMetadataIfMissing(beadsDir, "fallback"); err != nil {
		t.Fatalf("EnsureConfigYAMLFromMetadataIfMissing: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
	if err != nil {
		t.Fatalf("read config.yaml: %v", err)
	}
	got := string(data)
	if !strings.Contains(got, "prefix: hq\n") {
		t.Fatalf("config.yaml missing normalized prefix: %q", got)
	}
	if !strings.Contains(got, "issue-prefix: hq\n") {
		t.Fatalf("config.yaml missing normalized issue-prefix: %q", got)
	}
}

func TestEnsureConfigYAML_DisablesAutoExport(t *testing.T) {
	beadsDir := t.TempDir()
	configPath := filepath.Join(beadsDir, "config.yaml")
	original := "prefix: old\nissue-prefix: old\ndolt.idle-timeout: \"30\"\nexport.auto: true\nsync.mode: dolt-native\n"
	if err := os.WriteFile(configPath, []byte(original), 0644); err != nil {
		t.Fatalf("write config.yaml: %v", err)
	}

	if err := EnsureConfigYAML(beadsDir, "gt"); err != nil {
		t.Fatalf("EnsureConfigYAML: %v", err)
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatalf("read config.yaml: %v", err)
	}
	got := string(data)
	for _, want := range []string{
		"prefix: gt\n",
		"issue-prefix: gt\n",
		"dolt.idle-timeout: \"0\"\n",
		"export.auto: \"false\"\n",
		"sync.mode: dolt-native\n",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("config.yaml missing %q after repair:\n%s", want, got)
		}
	}
}

func TestMergeConfigYAMLCustomTypes(t *testing.T) {
	required := []string{"agent", "rig"}

	t.Run("quoted value is not corrupted", func(t *testing.T) {
		beadsDir := t.TempDir()
		// Simulates the corruption trigger: pre-existing quoted types.custom.
		existing := `prefix: gt
types.custom: "molecule,step"
`
		if err := os.WriteFile(filepath.Join(beadsDir, "config.yaml"), []byte(existing), 0644); err != nil {
			t.Fatalf("write: %v", err)
		}
		if err := MergeConfigYAMLCustomTypes(beadsDir, required); err != nil {
			t.Fatalf("MergeConfigYAMLCustomTypes: %v", err)
		}
		data, err := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		got := string(data)
		// Must produce a single, unquoted, deduped, sorted value.
		if !strings.Contains(got, "types.custom: agent,molecule,rig,step\n") {
			t.Fatalf("unexpected types.custom in config.yaml:\n%s", got)
		}
		// No append-after-quote corruption.
		if strings.Contains(got, `"`) {
			t.Fatalf("config.yaml still contains quotes (corruption not fixed):\n%s", got)
		}
	})

	t.Run("unquoted value merges cleanly", func(t *testing.T) {
		beadsDir := t.TempDir()
		existing := "prefix: gt\ntypes.custom: molecule,step\n"
		if err := os.WriteFile(filepath.Join(beadsDir, "config.yaml"), []byte(existing), 0644); err != nil {
			t.Fatalf("write: %v", err)
		}
		if err := MergeConfigYAMLCustomTypes(beadsDir, required); err != nil {
			t.Fatalf("MergeConfigYAMLCustomTypes: %v", err)
		}
		data, _ := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
		if !strings.Contains(string(data), "types.custom: agent,molecule,rig,step\n") {
			t.Fatalf("unexpected result:\n%s", string(data))
		}
	})

	t.Run("no-op when value already correct", func(t *testing.T) {
		beadsDir := t.TempDir()
		existing := "prefix: gt\ntypes.custom: agent,rig\n"
		if err := os.WriteFile(filepath.Join(beadsDir, "config.yaml"), []byte(existing), 0644); err != nil {
			t.Fatalf("write: %v", err)
		}
		if err := MergeConfigYAMLCustomTypes(beadsDir, required); err != nil {
			t.Fatalf("MergeConfigYAMLCustomTypes: %v", err)
		}
		data, _ := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
		if string(data) != existing {
			t.Fatalf("config.yaml changed unexpectedly:\n%s", string(data))
		}
	})

	t.Run("appends when key is absent", func(t *testing.T) {
		beadsDir := t.TempDir()
		existing := "prefix: gt\n"
		if err := os.WriteFile(filepath.Join(beadsDir, "config.yaml"), []byte(existing), 0644); err != nil {
			t.Fatalf("write: %v", err)
		}
		if err := MergeConfigYAMLCustomTypes(beadsDir, required); err != nil {
			t.Fatalf("MergeConfigYAMLCustomTypes: %v", err)
		}
		data, _ := os.ReadFile(filepath.Join(beadsDir, "config.yaml"))
		if !strings.Contains(string(data), "types.custom: agent,rig\n") {
			t.Fatalf("key not appended:\n%s", string(data))
		}
	})

	t.Run("no-op when file is missing", func(t *testing.T) {
		beadsDir := t.TempDir()
		if err := MergeConfigYAMLCustomTypes(beadsDir, required); err != nil {
			t.Fatalf("MergeConfigYAMLCustomTypes: %v", err)
		}
	})
}

func TestConfigYAMLDisablesAutoExport(t *testing.T) {
	tests := []struct {
		name    string
		content string
		want    bool
	}{
		{"double quoted false", "export.auto: \"false\"\n", true},
		{"single quoted false", "export.auto: 'false'\n", true},
		{"bare false", "export.auto: false\n", true},
		{"true", "export.auto: true\n", false},
		{"missing", "prefix: hq\n", false},
		{"comment only", "# export.auto: false\n", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ConfigYAMLDisablesAutoExport(tt.content); got != tt.want {
				t.Fatalf("ConfigYAMLDisablesAutoExport() = %v, want %v", got, tt.want)
			}
		})
	}
}
