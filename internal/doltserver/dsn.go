package doltserver

import (
	"fmt"
	"os"
	"strings"
)

// DSNOpts holds optional MySQL DSN query parameters for Dolt connections.
// Zero values are omitted from the resulting query string.
type DSNOpts struct {
	ParseTime    bool
	Timeout      string // e.g. "5s"
	ReadTimeout  string // e.g. "10s"
	WriteTimeout string // e.g. "30s"
}

func (o DSNOpts) queryString() string {
	var parts []string
	if o.ParseTime {
		parts = append(parts, "parseTime=true")
	}
	if o.Timeout != "" {
		parts = append(parts, "timeout="+o.Timeout)
	}
	if o.ReadTimeout != "" {
		parts = append(parts, "readTimeout="+o.ReadTimeout)
	}
	if o.WriteTimeout != "" {
		parts = append(parts, "writeTimeout="+o.WriteTimeout)
	}
	return strings.Join(parts, "&")
}

// LocalSocketPath returns Dolt's unix socket path for a given port if a socket
// is currently present at that path; otherwise returns "". The path derivation
// matches Dolt's own logic: /tmp/mysql.sock on port 3306, /tmp/mysql.{port}.sock
// for any other port.
//
// Declared as var so tests can swap it without requiring a real Dolt server.
var LocalSocketPath = func(port int) string {
	p := DefaultDoltSocketPath
	if port != 0 && port != 3306 {
		p = fmt.Sprintf("/tmp/mysql.%d.sock", port)
	}
	info, err := os.Stat(p)
	if err != nil {
		return ""
	}
	if info.Mode()&os.ModeSocket == 0 {
		return ""
	}
	return p
}

// isLocalHost reports whether host is a local loopback address.
func isLocalHost(host string) bool {
	return host == "" || host == "127.0.0.1" || host == "localhost"
}

// BuildDSN produces a Go-MySQL-driver DSN that prefers the local Dolt unix
// socket when host is local and the socket exists, falling back to TCP
// loopback otherwise.
//
// Rationale: short-lived gt-CLI subcommands over TCP loopback create a
// TIME_WAIT entry per close that lingers ~30s on macOS (2*MSL, MSL=15s). On
// busy rigs the count climbs past port-monitor alert thresholds. Unix-socket
// transport bypasses TIME_WAIT entirely.
//
// Conservative semantics: callers receive the TCP DSN whenever the default
// Dolt socket is absent or when host is non-local (Windows, remote Dolt,
// custom socket path). No behaviour change for remote setups.
func BuildDSN(user, host string, port int, dbName string, opts DSNOpts) string {
	if user == "" {
		user = "root"
	}
	qs := opts.queryString()
	if isLocalHost(host) {
		if sock := LocalSocketPath(port); sock != "" {
			if qs == "" {
				return fmt.Sprintf("%s@unix(%s)/%s", user, sock, dbName)
			}
			return fmt.Sprintf("%s@unix(%s)/%s?%s", user, sock, dbName, qs)
		}
	}
	h := host
	if h == "" {
		h = "127.0.0.1"
	}
	if qs == "" {
		return fmt.Sprintf("%s@tcp(%s:%d)/%s", user, h, port, dbName)
	}
	return fmt.Sprintf("%s@tcp(%s:%d)/%s?%s", user, h, port, dbName, qs)
}
