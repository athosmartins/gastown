package doltserver

import (
	"net"
	"os"
	"runtime"
	"strings"
	"testing"
)

// withMockSocket replaces LocalSocketPath for the duration of the test.
func withMockSocket(t *testing.T, sockPath string) {
	t.Helper()
	orig := LocalSocketPath
	LocalSocketPath = func(int) string { return sockPath }
	t.Cleanup(func() { LocalSocketPath = orig })
}

// withNoSocket forces LocalSocketPath to return "" so tests assert the TCP branch.
func withNoSocket(t *testing.T) {
	t.Helper()
	orig := LocalSocketPath
	LocalSocketPath = func(int) string { return "" }
	t.Cleanup(func() { LocalSocketPath = orig })
}

func TestBuildDSN_Socket_LocalHost(t *testing.T) {
	withMockSocket(t, "/tmp/mysql.3307.sock")
	got := BuildDSN("root", "127.0.0.1", 3307, "hq", DSNOpts{
		ParseTime: true, Timeout: "5s", ReadTimeout: "10s",
	})
	want := "root@unix(/tmp/mysql.3307.sock)/hq?parseTime=true&timeout=5s&readTimeout=10s"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestBuildDSN_Socket_EmptyHost(t *testing.T) {
	withMockSocket(t, "/tmp/mysql.3307.sock")
	got := BuildDSN("root", "", 3307, "hq", DSNOpts{})
	want := "root@unix(/tmp/mysql.3307.sock)/hq"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestBuildDSN_TCPFallback_LocalNoSocket(t *testing.T) {
	withNoSocket(t)
	got := BuildDSN("root", "127.0.0.1", 3307, "hq", DSNOpts{
		ParseTime: true, Timeout: "5s", ReadTimeout: "10s",
	})
	want := "root@tcp(127.0.0.1:3307)/hq?parseTime=true&timeout=5s&readTimeout=10s"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestBuildDSN_TCPFallback_RemoteHost(t *testing.T) {
	// Remote host must never use socket, even if socket path "exists".
	withMockSocket(t, "/tmp/mysql.3307.sock")
	got := BuildDSN("root", "10.0.0.5", 3307, "hq", DSNOpts{Timeout: "5s"})
	if !strings.HasPrefix(got, "root@tcp(10.0.0.5:3307)") {
		t.Errorf("expected TCP DSN for remote host, got %q", got)
	}
}

func TestBuildDSN_DefaultUser(t *testing.T) {
	withNoSocket(t)
	got := BuildDSN("", "127.0.0.1", 3307, "hq", DSNOpts{})
	if !strings.HasPrefix(got, "root@") {
		t.Errorf("empty user should default to root, got %q", got)
	}
}

func TestBuildDSN_EmptyDBName(t *testing.T) {
	withNoSocket(t)
	got := BuildDSN("root", "127.0.0.1", 3307, "", DSNOpts{Timeout: "5s"})
	want := "root@tcp(127.0.0.1:3307)/?timeout=5s"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestBuildDSN_NoQueryParams(t *testing.T) {
	withNoSocket(t)
	got := BuildDSN("root", "127.0.0.1", 3307, "", DSNOpts{})
	want := "root@tcp(127.0.0.1:3307)/"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLocalSocketPath_RealSocket(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("unix sockets not available on Windows")
	}
	dir, err := os.MkdirTemp("/tmp", "gtdsn")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	sockPath := dir + "/mysql.sock"
	l, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()

	orig := LocalSocketPath
	LocalSocketPath = func(port int) string {
		p := sockPath
		info, err := os.Stat(p)
		if err != nil || info.Mode()&os.ModeSocket == 0 {
			return ""
		}
		return p
	}
	defer func() { LocalSocketPath = orig }()

	got := BuildDSN("root", "127.0.0.1", 3307, "hq", DSNOpts{})
	if !strings.Contains(got, "@unix(") {
		t.Errorf("expected unix DSN with real socket, got %q", got)
	}
}

func TestLocalSocketPath_AbsentReturnsEmpty(t *testing.T) {
	// dc-y69y: helper now falls back to DefaultDoltSocketPath when the
	// port-suffixed candidate is missing. On dev machines that have a Dolt
	// instance running with the default socket path, this test would
	// otherwise return that fallback and fail. Skip when the fallback exists.
	if info, err := os.Stat(DefaultDoltSocketPath); err == nil && info.Mode()&os.ModeSocket != 0 {
		t.Skipf("skipping: %s exists as a unix socket — fallback would resolve", DefaultDoltSocketPath)
	}
	got := LocalSocketPath(19999) // port with no server
	if got != "" {
		t.Errorf("expected empty for absent socket, got %q", got)
	}
}

// TestSocketCandidates_Ordering covers dc-y69y: the candidate list must
// include DefaultDoltSocketPath as a final fallback, otherwise every non-3306
// Dolt setup bypasses the socket and creates TIME_WAIT churn.
func TestSocketCandidates_Ordering(t *testing.T) {
	tests := []struct {
		name string
		port int
		want []string
	}{
		{
			name: "non_3306_includes_port_suffixed_then_unprefixed_fallback",
			port: 3307,
			want: []string{"/tmp/mysql.3307.sock", DefaultDoltSocketPath},
		},
		{
			name: "port_3306_only_unprefixed",
			port: 3306,
			want: []string{DefaultDoltSocketPath},
		},
		{
			name: "zero_port_only_unprefixed",
			port: 0,
			want: []string{DefaultDoltSocketPath},
		},
		{
			name: "non_default_port_4567",
			port: 4567,
			want: []string{"/tmp/mysql.4567.sock", DefaultDoltSocketPath},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := SocketCandidates(tt.port)
			if len(got) != len(tt.want) {
				t.Fatalf("got %v, want %v", got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("position %d: got %q, want %q", i, got[i], tt.want[i])
				}
			}
		})
	}
}
