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
	got := LocalSocketPath(19999) // port with no server
	if got != "" {
		t.Errorf("expected empty for absent socket, got %q", got)
	}
}
