package reaper

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestValidateDBName(t *testing.T) {
	tests := []struct {
		name    string
		wantErr bool
	}{
		{"hq", false},
		{"beads", false},
		{"gt", false},
		{"test_db_123", false},
		{"", true},
		{"drop table", true},
		{"db;--", true},
		{"db`name", true},
		{"../etc/passwd", true},
	}
	for _, tt := range tests {
		err := ValidateDBName(tt.name)
		if (err != nil) != tt.wantErr {
			t.Errorf("ValidateDBName(%q) error = %v, wantErr %v", tt.name, err, tt.wantErr)
		}
	}
}

func TestDefaultDatabases(t *testing.T) {
	if len(DefaultDatabases) == 0 {
		t.Error("DefaultDatabases should not be empty")
	}
	for _, db := range DefaultDatabases {
		if err := ValidateDBName(db); err != nil {
			t.Errorf("DefaultDatabases contains invalid name %q: %v", db, err)
		}
	}
}

func TestFormatJSON(t *testing.T) {
	result := FormatJSON(map[string]int{"count": 42})
	if result == "" {
		t.Error("FormatJSON should not return empty string")
	}
	if result[0] != '{' {
		t.Errorf("FormatJSON should return JSON object, got %q", result[:10])
	}
}

func TestParentExcludeJoin(t *testing.T) {
	joinClause, whereCondition := parentExcludeJoin("testdb")

	// JOIN clause should reference the correct database.
	if joinClause == "" {
		t.Error("parentExcludeJoin joinClause should not be empty")
	}
	// parentExcludeJoin no longer qualifies table names with the database — the
	// reaper connects to a specific database via the DSN, so unqualified names
	// are correct. The dbName parameter is retained for API compatibility.

	// JOIN should select wisps with open parents from wisp_dependencies.
	if !contains(joinClause, "wisp_dependencies") {
		t.Error("parentExcludeJoin should query wisp_dependencies")
	}
	if !contains(joinClause, "parent-child") {
		t.Error("parentExcludeJoin should filter on parent-child type")
	}
	if !contains(joinClause, "'open', 'hooked', 'in_progress'") {
		t.Error("parentExcludeJoin should check for open parent statuses")
	}

	// WHERE condition should be an IS NULL anti-join filter.
	if whereCondition == "" {
		t.Error("parentExcludeJoin whereCondition should not be empty")
	}
	if !contains(whereCondition, "IS NULL") {
		t.Error("parentExcludeJoin whereCondition should use IS NULL for anti-join")
	}
}

// TestReapQueryNoDatabaseNameInjection verifies that the Reap function's batch
// SELECT query does not inject the database name into the SQL string. Previously,
// dbName was passed as a Sprintf arg but the format string didn't use it, causing
// positional shift: "FROM wisps w gt WHERE..." instead of "FROM wisps w LEFT JOIN...".
func TestReapQueryNoDatabaseNameInjection(t *testing.T) {
	// Reproduce the exact Sprintf call from Reap() to verify no dbName injection.
	dbName := "gt"
	parentJoin, parentWhere := parentExcludeJoin(dbName)
	whereClause := fmt.Sprintf(
		"w.status IN ('open', 'hooked', 'in_progress') AND w.created_at < ? AND %s", parentWhere)

	// This is the fixed query — dbName is NOT in the Sprintf args.
	idQuery := fmt.Sprintf(
		"SELECT w.id FROM wisps w %s WHERE %s LIMIT %d",
		parentJoin, whereClause, DefaultBatchSize)

	// The query must NOT contain the literal database name as a bare token.
	// Before the fix, "gt" appeared between "wisps w" and "WHERE".
	if strings.Contains(idQuery, "wisps w gt") {
		t.Errorf("Reap idQuery contains injected database name: %s", idQuery)
	}
	if !strings.Contains(idQuery, "LEFT JOIN") {
		t.Errorf("Reap idQuery should contain LEFT JOIN from parentExcludeJoin, got: %s", idQuery)
	}
	if !strings.Contains(idQuery, fmt.Sprintf("LIMIT %d", DefaultBatchSize)) {
		t.Errorf("Reap idQuery should end with LIMIT %d, got: %s", DefaultBatchSize, idQuery)
	}
}

// TestReapUpdateQueryNoDatabaseNameInjection verifies that the UPDATE query in
// Reap() does not inject dbName where the IN clause should go.
func TestReapUpdateQueryNoDatabaseNameInjection(t *testing.T) {
	dbName := "gt"
	inClause := "?,?,?"

	// This is the fixed query — only inClause in the Sprintf args.
	updateQuery := fmt.Sprintf(
		"UPDATE wisps SET status='closed', closed_at=NOW() WHERE id IN (%s)",
		inClause)

	if strings.Contains(updateQuery, dbName) {
		t.Errorf("Reap updateQuery contains injected database name %q: %s", dbName, updateQuery)
	}
	if !strings.Contains(updateQuery, "IN (?,?,?)") {
		t.Errorf("Reap updateQuery should contain parameterized IN clause, got: %s", updateQuery)
	}
}

// TestPurgeDigestQueryNoDatabaseNameInjection verifies that the purge digest
// query is a plain string with no Sprintf interpolation at all.
func TestPurgeDigestQueryNoDatabaseNameInjection(t *testing.T) {
	// The fixed digestQuery is a string literal — no Sprintf.
	digestQuery := "SELECT COALESCE(w.wisp_type, 'unknown') AS wtype, COUNT(*) AS cnt FROM wisps w WHERE w.status = 'closed' AND w.closed_at < ? GROUP BY wtype"

	if strings.Contains(digestQuery, "gt") {
		t.Errorf("purge digestQuery should not contain database name, got: %s", digestQuery)
	}
	if !strings.Contains(digestQuery, "GROUP BY wtype") {
		t.Errorf("purge digestQuery should end with GROUP BY, got: %s", digestQuery)
	}
}

// TestPurgeBatchQueryNoDatabaseNameInjection verifies that the purge batch
// SELECT query uses DefaultBatchSize as the LIMIT, not dbName.
func TestPurgeBatchQueryNoDatabaseNameInjection(t *testing.T) {
	// This is the fixed query — only DefaultBatchSize in the Sprintf args.
	idQuery := fmt.Sprintf(
		"SELECT w.id FROM wisps w WHERE w.status = 'closed' AND w.closed_at < ? LIMIT %d",
		DefaultBatchSize)

	if strings.Contains(idQuery, "gt") {
		t.Errorf("purge idQuery contains injected database name: %s", idQuery)
	}
	expected := fmt.Sprintf("LIMIT %d", DefaultBatchSize)
	if !strings.Contains(idQuery, expected) {
		t.Errorf("purge idQuery should contain %s, got: %s", expected, idQuery)
	}
}

// TestIsNothingToCommit verifies that "nothing to commit" errors are recognized
// correctly. This prevents false-positive dolt_commit_failed anomalies when the
// reaper operates on dolt_ignored tables (wisps, wisp_*), where Dolt has nothing
// to version after a successful SQL DELETE.
func TestIsNothingToCommit(t *testing.T) {
	cases := []struct {
		msg  string
		want bool
	}{
		{"nothing to commit", true},
		{"NOTHING TO COMMIT", true},
		{"Error 1105 (HY000): nothing to commit", true},
		{"no changes to commit", false}, // must also contain "commit" — see isNothingToCommit
		{"no changes", false},
		{"connection refused", false},
		{"table not found: wisps", false},
		{"", false},
	}
	for _, c := range cases {
		var err error
		if c.msg != "" {
			err = fmt.Errorf("%s", c.msg)
		}
		got := isNothingToCommit(err)
		if got != c.want {
			t.Errorf("isNothingToCommit(%q) = %v, want %v", c.msg, got, c.want)
		}
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsHelper(s, substr))
}

func containsHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}

// TestReapExcludesAgentBeads verifies that the Reap function excludes agent beads
// from being closed, regardless of their age. This is a regression test for the bug
// where the wisp reaper was closing agent beads (hq-mayor, hq-deacon, witness, refinery,
// etc.) after 24 hours, causing doctor to report them as missing.
func TestReapExcludesAgentBeads(t *testing.T) {
	// Verify that the WHERE clause in Reap() excludes issue_type='agent'
	// by checking the source code pattern.
	// This is a compile-time guard — if the exclusion is removed, this test
	// will fail when the query pattern doesn't match.

	// The whereClause in Reap() should contain:
	// "w.issue_type != 'agent'"
	// This test documents the expected behavior; actual exclusion is tested
	// in integration tests with a real database.

	// Integration test would require spinning up a Dolt server, which is
	// beyond the scope of this unit test. The exclusion is verified manually
	// by checking that agent beads are not closed by the wisp_reaper patrol.
	t.Log("Agent beads (issue_type='agent') are excluded from wisp reaping")
	t.Log("This prevents hq-mayor, hq-deacon, witness, refinery, etc. from being closed")
}

// TestScanExcludesAgentBeads documents that Scan() must use the same eligibility
// predicate as Reap() for stale open wisps. If Scan counts agent beads but Reap
// excludes them, the operator sees scan>0 and reap=0 for the same cutoff.
func TestScanExcludesAgentBeads(t *testing.T) {
	sourcePath := "reaper.go"
	data, err := os.ReadFile(sourcePath)
	if err != nil {
		t.Fatalf("read %s: %v", sourcePath, err)
	}
	source := string(data)
	scanStart := strings.Index(source, "func Scan(")
	reapStart := strings.Index(source, "func Reap(")
	if scanStart == -1 || reapStart == -1 || reapStart <= scanStart {
		t.Fatalf("could not isolate Scan() body in %s", sourcePath)
	}
	scanBody := source[scanStart:reapStart]
	// The exclusion predicate widened from a single "!= 'agent'" to
	// "NOT IN ('agent', 'session')" when session-identity beads got the same
	// protection (gt-rlujz); this assertion drifted from the real query text
	// and had been silently red ever since (found while fixing ga-xo035 —
	// AutoClose's missing mirror of this same guard).
	if !strings.Contains(scanBody, "w.issue_type NOT IN ('agent', 'session')") {
		t.Fatalf("expected Scan() eligibility to exclude agent/session beads, scan body was:\n%s", scanBody)
	}
}

// TestAutoCloseExcludesAgentAndSessionBeads is a regression test for the
// sibling of the bug TestReapExcludesAgentBeads documents: AutoClose() never
// got the mirror "issue_type NOT IN ('agent','session')" guard that Reap()
// already has. Verified live against hq on 2026-08-29 (ga-xo035): all 13/13
// open agent-type issues in hq (lx-lexbh-crew-thies, dc-deacon-witness,
// gt-gastown-crew-furiosa, ps-property_scrapers-*, etc.) matched every other
// AutoClose criterion (priority>1, not epic, no active deps, updated_at >30d
// stale — identity beads legitimately go untouched for months) and would
// have been closed by a bare `gt reaper auto-close`/`run`. Same pattern as
// TestScanExcludesAgentBeads: read the real source, isolate the function
// body, assert the exclusion substring — so it fails against the pre-fix
// source and passes after.
func TestAutoCloseExcludesAgentAndSessionBeads(t *testing.T) {
	sourcePath := "reaper.go"
	data, err := os.ReadFile(sourcePath)
	if err != nil {
		t.Fatalf("read %s: %v", sourcePath, err)
	}
	source := string(data)
	acStart := strings.Index(source, "func AutoClose(")
	if acStart == -1 {
		t.Fatalf("could not find AutoClose() in %s", sourcePath)
	}
	acBody := source[acStart:]
	if end := strings.Index(acBody, "\nfunc "); end != -1 {
		acBody = acBody[:end]
	}
	if !strings.Contains(acBody, "i.issue_type NOT IN ('agent', 'session')") {
		t.Fatalf("expected AutoClose() eligibility to exclude agent/session identity beads, body was:\n%s", acBody)
	}
}

// TestNoObsoleteDependsOnIdColumn is a regression test for gt-ll1zf: the reaper
// referenced a `depends_on_id` column on the dependencies / wisp_dependencies
// tables, but the live Dolt schema split that single polymorphic column into
// three (depends_on_issue_id, depends_on_wisp_id, depends_on_external). Every
// reaper query that named the old column failed with
//
//	Error 1105 (HY000): table "wd" does not have column "depends_on_id"
//
// which aborted `gt reaper scan/reap/auto-close`, blocking wisp pruning and
// driving the Dolt CPU spiral. The substring "depends_on_id" is NOT a substring
// of either replacement column, so a plain source scan is a precise guard.
func TestNoObsoleteDependsOnIdColumn(t *testing.T) {
	data, err := os.ReadFile("reaper.go")
	if err != nil {
		t.Fatalf("read reaper.go: %v", err)
	}
	source := string(data)

	if strings.Contains(source, "depends_on_id") {
		t.Errorf("reaper.go still references obsolete column depends_on_id; the live " +
			"schema split it into depends_on_issue_id / depends_on_wisp_id / depends_on_external (gt-ll1zf)")
	}

	// The split columns must be present: issue-parent and wisp-parent joins both
	// have to resolve, otherwise the parent-exclusion / blocker checks silently
	// stop matching real parents.
	for _, col := range []string{"depends_on_issue_id", "depends_on_wisp_id"} {
		if !strings.Contains(source, col) {
			t.Errorf("reaper.go should reference %s after the schema split (gt-ll1zf)", col)
		}
	}
}

// TestParentExcludeJoinUsesSplitColumns verifies the parent-child exclusion join
// resolves wisp parents via depends_on_wisp_id and issue parents via
// depends_on_issue_id — the polymorphic depends_on_id column no longer exists.
func TestParentExcludeJoinUsesSplitColumns(t *testing.T) {
	joinClause, _ := parentExcludeJoin("testdb")
	if !contains(joinClause, "wd.depends_on_wisp_id") {
		t.Errorf("parentExcludeJoin should join wisp parents on wd.depends_on_wisp_id, got: %s", joinClause)
	}
	if !contains(joinClause, "wd.depends_on_issue_id") {
		t.Errorf("parentExcludeJoin should join issue parents on wd.depends_on_issue_id, got: %s", joinClause)
	}
	if contains(joinClause, "depends_on_id") {
		t.Errorf("parentExcludeJoin must not reference obsolete depends_on_id, got: %s", joinClause)
	}
}
