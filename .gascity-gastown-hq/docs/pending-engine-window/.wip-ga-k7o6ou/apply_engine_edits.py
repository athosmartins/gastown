"""Applies the ga-k7o6ou engine edits to a checkout root given as argv[1].
Every replacement must match exactly once, or the whole script aborts before writing
anything (no partial application)."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
writes = []


def edit(rel, pairs):
    p = root / rel
    s = p.read_text()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"ABORT {rel}: expected exactly 1 match, got {s.count(old)} for:\n{old}")
        s = s.replace(old, new)
    writes.append((p, s))


# 1. The live path: the provider script's bind default.
edit("examples/bd/assets/scripts/gc-beads-bd.sh", [
    (
        '#   GC_DOLT_HOST  — dolt server host (empty = local server)\n',
        '#   GC_DOLT_HOST  — dolt server host (empty = local managed server on 127.0.0.1;\n'
        '#                   0.0.0.0 = local managed server on EVERY interface, explicit opt-in;\n'
        '#                   any other value = a REMOTE server this script never starts or stops)\n',
    ),
    (
        'DOLT_HOST="${GC_DOLT_HOST:-0.0.0.0}"\n',
        '# Bind host of the MANAGED server: loopback unless GC_DOLT_HOST names the wildcard on purpose.\n'
        '# The managed server runs as root with an empty password, so listening on every interface\n'
        '# exposes the whole beads/mail database to the LAN (ga-k7o6ou).\n'
        '# Do NOT "harden" this by exporting GC_DOLT_HOST=127.0.0.1: is_remote() below reads any value\n'
        '# other than 0.0.0.0 as a remote server, and op_start would then exit 2 without starting anything.\n'
        'DOLT_HOST="${GC_DOLT_HOST:-127.0.0.1}"\n',
    ),
])

# 2. The Go helper's own default, so a caller that omits --host cannot reopen the exposure.
edit("cmd/gc/dolt_start_managed.go", [
    (
        'func startManagedDoltProcess(cityPath, host, port, user, logLevel string, timeout time.Duration) (managedDoltStartReport, error) {\n',
        '// managedDoltDefaultBindHost is the listener host used when a caller names none. The managed\n'
        '// server runs as root with an empty password, so the default is loopback; listening on every\n'
        '// interface (0.0.0.0) has to be asked for by name (ga-k7o6ou).\n'
        'const managedDoltDefaultBindHost = "127.0.0.1"\n'
        '\n'
        'func startManagedDoltProcess(cityPath, host, port, user, logLevel string, timeout time.Duration) (managedDoltStartReport, error) {\n',
    ),
    (
        '\tif strings.TrimSpace(host) == "" {\n\t\thost = "0.0.0.0"\n\t}\n\tif strings.TrimSpace(user) == "" {\n',
        '\tif strings.TrimSpace(host) == "" {\n\t\thost = managedDoltDefaultBindHost\n\t}\n\tif strings.TrimSpace(user) == "" {\n',
    ),
    (
        '// The host argument matches the host dolt will bind to (typically "0.0.0.0"\n'
        '// in production); using the same host for the probe and the bind avoids',
        '// The host argument matches the host dolt will bind to (loopback unless the\n'
        '// caller asked for the wildcard); using the same host for the probe and the bind avoids',
    ),
])

# 3. Same default on the recover path.
edit("cmd/gc/dolt_recover_managed.go", [
    (
        '\tif strings.TrimSpace(host) == "" {\n\t\thost = "0.0.0.0"\n\t}\n',
        '\tif strings.TrimSpace(host) == "" {\n\t\thost = managedDoltDefaultBindHost\n\t}\n',
    ),
])

# 4. A comment that named the old default as "the bind default".
edit("cmd/gc/dolt_port_selection.go", [
    (
        '// and dolt is binding 0.0.0.0:X, which would fail). Blank host normalizes\n'
        '// to "0.0.0.0" inside managedDoltPortAvailableFn (the indirection over\n'
        '// managedDoltPortAvailableForHost) to match the bind default in\n'
        '// startManagedDoltProcessWithOptions.\n',
        '// and dolt is binding 0.0.0.0:X, which would fail). A blank host probes the\n'
        '// wildcard inside managedDoltPortAvailableFn (the indirection over\n'
        '// managedDoltPortAvailableForHost). startManagedDoltProcessWithOptions\n'
        '// resolves a blank BIND host to loopback before it reaches this probe, so\n'
        '// the start path always probes the host it is about to bind.\n',
    ),
])

for path, text in writes:
    path.write_text(text)
print("applied", len(writes), "files")
