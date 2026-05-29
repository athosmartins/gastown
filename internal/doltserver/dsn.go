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

// LocalSocketPath returns the path to Dolt's local unix socket if one is
// listening, or "" if no socket can be found.
//
// Path derivation: Dolt's source default is /tmp/mysql.sock regardless of
// port, unless the user explicitly sets `socket: /tmp/mysql.<port>.sock` in
// config.yaml. We try the port-suffixed path FIRST (so explicitly-configured
// setups still resolve correctly), then fall back to the unprefixed default.
// (dc-y69y) Earlier versions only tried the port-suffixed path, which caused
// every gt-CLI subcommand on a non-3306 Dolt to bypass the socket and fall
// back to TCP — recreating the TIME_WAIT pile-up the socket migration was
// supposed to eliminate.
//
// Declared as var so tests can swap it without requiring a real Dolt server.
// SocketCandidates returns the ordered list of paths LocalSocketPath should
// try, with the explicitly-port-suffixed candidate first (so user-configured
// custom-port setups still work) and Dolt's source-default unprefixed path
// last (the actual fallback for vanilla servers on any port). Pure / no I/O
// — easy to unit-test the ordering invariants.
func SocketCandidates(port int) []string {
	out := make([]string, 0, 2)
	if port != 0 && port != 3306 {
		out = append(out, fmt.Sprintf("/tmp/mysql.%d.sock", port))
	}
	out = append(out, DefaultDoltSocketPath)
	return out
}

var LocalSocketPath = func(port int) string {
	for _, p := range SocketCandidates(port) {
		info, err := os.Stat(p)
		if err != nil {
			continue
		}
		if info.Mode()&os.ModeSocket == 0 {
			continue
		}
		return p
	}
	return ""
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
// custom socket path). No behavior change for remote setups.
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
