package cmd

import (
	"fmt"
	"os"
	"strings"

	"github.com/steveyegge/gastown/internal/doltserver"
)

// dsnOpts captures the optional MySQL DSN query parameters used by gt's
// internal Dolt-server connections. Empty / zero values are omitted from
// the resulting query string.
type dsnOpts struct {
	ParseTime    bool
	Timeout      string // e.g. "5s"
	ReadTimeout  string // e.g. "10s"
	WriteTimeout string // e.g. "30s"
}

func (o dsnOpts) queryString() string {
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

// localDoltSocketPath returns the path to Dolt's local unix socket if one is
// listening, or "" if no socket can be found.
//
// Path-derivation: Dolt's source default is `/tmp/mysql.sock` regardless of
// port, unless the user explicitly sets `socket: /tmp/mysql.<port>.sock` in
// config.yaml. We try the port-suffixed path FIRST (so explicitly-configured
// setups still resolve correctly), then fall back to the unprefixed default.
// (dc-y69y) Earlier versions only tried the port-suffixed path, which caused
// every gt-CLI subcommand on a non-3306 Dolt to bypass the socket and fall
// back to TCP — recreating the TIME_WAIT pile-up the socket migration was
// supposed to eliminate.
//
// Declared as a var (not const) so unit tests can swap it for a temp-dir
// socket without depending on a real Dolt server.
// doltSocketCandidates returns the ordered list of paths the helper should
// try, with the explicitly-port-suffixed candidate first (so user-configured
// custom-port setups still work) and Dolt's source-default unprefixed path
// last (the actual fallback for vanilla servers on any port). Pure / no I/O
// — easy to unit-test the ordering invariants.
func doltSocketCandidates(port int) []string {
	out := make([]string, 0, 2)
	if port != 0 && port != 3306 {
		out = append(out, fmt.Sprintf("/tmp/mysql.%d.sock", port))
	}
	out = append(out, "/tmp/mysql.sock")
	return out
}

var localDoltSocketPath = func(port int) string {
	for _, p := range doltSocketCandidates(port) {
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

// buildDoltDSN produces a Go-MySQL-driver DSN that prefers the local
// Dolt unix domain socket when present, falling back to TCP loopback
// otherwise. The dbName, user, port, and query options are substituted
// into both forms.
//
// Rationale: short-lived gt-CLI subcommands over TCP loopback create a
// TIME_WAIT entry per close that lingers ~30s on macOS (2*MSL with
// MSL=15s). On busy rigs (background daemons, cron, periodic gt
// health/doctor/maintain invocations) the count climbs past
// port-monitor alert thresholds and risks port exhaustion. Unix-socket
// transport bypasses TIME_WAIT entirely.
//
// dc-fsue's metadata.json fix only covered the `bd` CLI side. wa-d6f
// tracks the remaining gt-CLI callsites that build their own DSNs
// inline (internal/cmd/health.go, maintain.go, dolt_flatten.go,
// dolt_rebase.go, install.go). This helper is the unified migration
// point so future callsites get socket-first transport for free.
//
// Conservative semantics: callers receive the TCP DSN whenever the
// default Dolt socket is not currently a unix socket at the expected
// path (Windows, no Dolt running, custom socket path). No behavior
// change for setups without a local Dolt.
func buildDoltDSN(user string, port int, dbName string, opts dsnOpts) string {
	if user == "" {
		user = "root"
	}
	qs := opts.queryString()
	if sock := localDoltSocketPath(port); sock != "" {
		if qs == "" {
			return fmt.Sprintf("%s@unix(%s)/%s", user, sock, dbName)
		}
		return fmt.Sprintf("%s@unix(%s)/%s?%s", user, sock, dbName, qs)
	}
	if qs == "" {
		return fmt.Sprintf("%s@tcp(127.0.0.1:%d)/%s", user, port, dbName)
	}
	return fmt.Sprintf("%s@tcp(127.0.0.1:%d)/%s?%s", user, port, dbName, qs)
}

// buildDoltDSNFromConfig is a convenience wrapper that pulls user + port
// from a *doltserver.Config (matches the maintain.go / dolt_flatten.go
// / dolt_rebase.go callsite pattern).
func buildDoltDSNFromConfig(c *doltserver.Config, dbName string, opts dsnOpts) string {
	return buildDoltDSN(c.User, c.Port, dbName, opts)
}
