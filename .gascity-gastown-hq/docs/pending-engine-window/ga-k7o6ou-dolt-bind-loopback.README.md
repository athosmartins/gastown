# ga-k7o6ou — the managed Dolt binds 127.0.0.1, not every interface

## Contents

• State · What the patch does · The trap it avoids
• Evidence gate (48 h) · Tests · Applying in the window · Verifying · Rolling back
• What this does NOT change

Patch: `ga-k7o6ou-dolt-bind-loopback.patch` (4 files, plus 2 tests inside it).
NOT applied. No build, no binary swap, no supervisor kickstart and no Dolt restart was done to
produce it. The engine window stays Mayor-coordinated. **Do not apply it before the evidence
gate below prints LIMPO.**

## State

* Dolt (pid 77955, up since 15/10 16:19) listens on `*:52756` as `root` with an empty password:
  anyone on the LAN can read or drop the beads/mail database.
* Nothing needs that. 15/10 afternoon: all 48 established peers on :52756 were `127.0.0.1`
  (plain `lsof`), and three runs of the new sampler saw 20/20, 11/11 and 20/20 loopback.
  The Hetzner link is an ssh reverse tunnel for the mirror's sshd (port 2293,
  `hetzner-mirror.sh:273`), not for Dolt, plus a shim that runs bd/gc over ssh on the mini.
* That is a snapshot, not the 48 h the bead asked for. See the gate.

## What the patch does

* `examples/bd/assets/scripts/gc-beads-bd.sh`: `DOLT_HOST="${GC_DOLT_HOST:-127.0.0.1}"` (was
  `0.0.0.0`). This is the live path: the supervisor lifecycle and launchd
  `com.gastown.dolt-server` (`gc dolt start`) both end in this script, which passes
  `--host "$DOLT_HOST"` to `gc dolt-state start-managed`, and that is what lands in
  `dolt-config.yaml`.
* `cmd/gc/dolt_start_managed.go`, `dolt_recover_managed.go`: a blank `--host` now resolves to
  the new const `managedDoltDefaultBindHost = "127.0.0.1"` instead of `0.0.0.0`. The script
  always passes a host, so this is not the live path; it stops a direct
  `gc dolt-state start-managed` from reopening the exposure.
* `cmd/gc/dolt_port_selection.go`: one comment that named the old default.
* `0.0.0.0` stays reachable as an explicit value of `GC_DOLT_HOST` at the script level.

## The trap it avoids

The generated `dolt-config.yaml` header says "To customize, set GC_DOLT_HOST". Do **not** export
`GC_DOLT_HOST=127.0.0.1` to get loopback: `is_remote()` treats every value except `0.0.0.0` as
a remote server, so `op_start` exits 2 ("nothing to start locally") and `op_stop_impl` returns 0.
gc would stop managing Dolt at its next restart. Two more dead ends, both checked:

* `city.toml [dolt] host` is the connection host of `gc beads city use-external`, not the bind.
* A hand edit of the on-disk script is wiped: `bd` is a *required* builtin pack, rewritten from
  the binary's embedded copy on every gc start and config load (`embed_builtin_packs.go`). The
  fix has to be in the binary.

## Evidence gate (48 h)

`dolt-load-attributor` cannot answer "is there a remote client?": `conn_pids()` drops every
`lsof` line whose COMMAND is `dolt` and counts only client-side sockets with a local PID, and a
remote client has none. `scripts/dolt-remote-peer-audit.sh` asks the inverted question: it reads
the Dolt process's own sockets, keeps only those on a port Dolt listens on (its outbound
connections, e.g. S3 backup, are not clients), and classifies each peer as `loopback`,
`self_lan` (a client on this machine using the LAN IP; breaks under a loopback bind too) or
`remote`. Each sample is `clean`, `nonloopback` or `unknown`; a failed `lsof` or a missing pid
is `unknown`, never `clean`.

* It runs from `packs/town-deltas/assets/com.gascity.dolt-remote-peer-audit.plist` (60 s,
  ~0.17 s CPU per sample). The deploy installer loads new `com.gascity.*` plists from that
  directory on the first deploy after merge. Merged is not alive: confirm with
  `launchctl list | grep dolt-remote-peer-audit` and a growing
  `.gc/logs/dolt-remote-peers.jsonl`.
* Verdict: `scripts/dolt-remote-peer-audit.sh report 48`. Exit 0 `LIMPO`; exit 1 `BLOQUEADO`
  (lists the peers); exit 2 `INSUFICIENTE` (under 48 h of coverage, a gap above 15 min, more
  than 10% `unknown`, or unreadable lines). A `BLOQUEADO` answer restarts the clock: deal with
  that client, then wait for 48 h of clean samples.
* Limit: it is a snapshot every 60 s. A client that connects for milliseconds once a day can
  slip past it. `LIMPO` means "no non-loopback connection in N samples over H hours".
* Retire it after the bind is live and proven (`launchctl bootout` + `launchctl disable`, then
  delete the plist): a remote client is then refused, not seen.

## Tests

**The two Go tests below were written but NOT RUN.** At 15/10 21:09 the Dolt server crashed on a
full data volume (`no space left on device`), and a cold build of `cmd/gc` can peak near 2.5 GiB
there, so I did not compile Go. Run them on the engine tree before the window:

```
git -C <engine> apply ga-k7o6ou-dolt-bind-loopback.patch
go test ./cmd/gc -count=1 -v -run 'TestGcBeadsBdStartBindHost|TestStartManagedDoltProcessWithOptions_BlankHostBindsLoopback'
```

Check `df` first: the test binary needs roughly 1.5-2.5 GiB of temp plus build cache. To see
the tests fail on the base, apply the patch and then revert only the four non-test files
(`git checkout HEAD -- examples/bd cmd/gc/dolt_start_managed.go cmd/gc/dolt_recover_managed.go
cmd/gc/dolt_port_selection.go`) before running them.

* `TestGcBeadsBdStartBindHost` runs the real script with a fake `gc` that renders `host:` from
  `--host`: unset renders `127.0.0.1`; explicit `GC_DOLT_HOST=0.0.0.0` renders `0.0.0.0`.
* `TestStartManagedDoltProcessWithOptions_BlankHostBindsLoopback` asserts the written
  `dolt-config.yaml` and the readiness-probe host for a blank host. It covers the Go default,
  which is not the live path; nothing below exercises it.

What *was* run, for the live path (the shell script), without compiling anything: the fake `gc`
and `dolt` scripts were lifted verbatim out of `beads_provider_lifecycle_test.go` and the REAL
`gc-beads-bd.sh` was started against a throwaway city (fake `gc` allocates port 3311; the live
Dolt on :52756 was untouched), unpatched vs patched:

| script | `GC_DOLT_HOST` | `start` rc | listener host rendered |
|---|---|---|---|
| unpatched | unset | 0 | `0.0.0.0` (the bug) |
| unpatched | `0.0.0.0` | 0 | `0.0.0.0` |
| unpatched | `127.0.0.1` | 2 | none (the trap: nothing started) |
| patched | unset | 0 | `127.0.0.1` |
| patched | `0.0.0.0` | 0 | `0.0.0.0` (opt-in kept) |
| patched | `127.0.0.1` | 2 | none (trap unchanged; now documented) |

Also done without a build: `gofmt -l` clean on the 5 changed Go files, `sh -n` on the script,
`git apply --check` clean on the tree of the live binary (`engine-window-1011b`).

Sampler: `scripts/dolt-remote-peer-audit.selftest.sh` (43 checks: classification, the three
states, lock, log cap, the report verdicts). Seven deliberately broken copies (unknown
collapsed to clean, port filter removed, self_lan read as loopback, report blind to
`nonloopback`, report accepting `unknown`, a lock that ignores dead owners, the `lsof`-failure /
no-LISTEN guard removed) are each caught by at least one check.

## Applying in the window

1. `git -C <engine> apply --check ga-k7o6ou-dolt-bind-loopback.patch`, then the two Go tests above.
2. Normal engine window. The first gc command that materializes the packs after the swap
   rewrites the script; confirm what will actually run with
   `grep -n '^DOLT_HOST=' $GC_CITY_PATH/.gc/system/packs/bd/assets/scripts/gc-beads-bd.sh`
   (expect `127.0.0.1`).
3. Dolt rebinds only when it restarts (the config is rewritten on each server start). Restart
   it in the 00-06 window with drain, as the bead says.

## Verifying

* `lsof -nP -a -p <dolt pid> -iTCP -sTCP:LISTEN` shows `127.0.0.1:52756`, not `*:52756`.
* The property that matters: from the mini, `nc -z <the mini's LAN IP> 52756` is refused.
* `bd list` and `gc dolt health` work; `dolt-remote-peer-audit.sh sample` ends clean.

## Rolling back

Swap the previous binary back (the live one today is `gc-1.1.1-engwin1011b`). `bd` is a
required pack, so the old binary's first materialize puts the `0.0.0.0` script back; Dolt
rebinds at its next restart.

Not verified: `GC_DOLT_HOST=0.0.0.0` as a rollback knob in production. At script level it works
(`TestGcBeadsBdStartBindHost`), but whether a value set in the supervisor or launchd
environment survives the engine's env projection to the lifecycle op is unchecked, and that
projection deletes `GC_DOLT_HOST` for managed-local targets in places
(`bd_env.go`, `applyCanonicalDoltTargetEnv`). Do not rely on it without testing the real path.

## What this does NOT change

* The `dolt-config.yaml` header (written in `cmd_dolt_config.go` and in the script heredoc)
  still advertises `GC_DOLT_HOST` as the way to customize; see the trap above.
* `root` with an empty password. Loopback shrinks who can reach it to local processes; it does
  not authenticate them. Setting a password is a separate hardening bead.
* IPv6: a `127.0.0.1` bind drops the dual-stack wildcard. No client was seen on `::1`, and
  gc's own connect host is `127.0.0.1` (`connect_host`, `managedDoltConnectHost`).
