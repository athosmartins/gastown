# ga-lsmtq2e — the sticky ENOSPC refusal of the managed Dolt lifts once the disk has room again

## Contents

• State · What the patch does · Why it is not live (tried 28/11) · Applying
• Tests and what they prove · What is NOT covered

Patch: `ga-lsmtq2e-dolt-enospc-headroom.patch` (3 files, paths relative to `.gc/system/packs`, `patch -p1`).
Source: gascity #7976 / `e8547dc572`, the ENOSPC piece only (its `setsid` part is NOT in this patch).
NOT applied to the live packs. No build, no binary swap, no Dolt restart and no database was touched to produce it.

## State

`recovery_should_skip_due_to_enospc` refuses `gc dolt recover` / `gc dolt restart` when the last 1000 lines of
`dolt.log` show ENOSPC. A stopped server writes nothing, so that line stays in the tail **forever**: after one full
disk the city stays down until someone runs `gc dolt restart --force` by hand, even with the disk empty again. The
mini sits near 6.2 GB free, so this is a live risk. Upstream fixed it; the engine window has not brought it yet.

## What the patch does

* `dolt-enospc.sh` (new helper `enospc_disk_has_headroom`): the ENOSPC evidence only counts while the free space of
  the data dir (else the log's dir) is below `GC_DOLT_WARN_FREE_BYTES` (default 2 GiB). Free space comes from
  `df -Pk`; **unreadable free space keeps the refusal** (the inert state). The floor is sanitised: not digits,
  0 or more than 18 digits → default; leading zeros are decimal, not octal.
* `gc-beads-bd.sh`: the same two functions in the inline fallback (used when the sibling helper is not readable), and
  the `op_recover` comment says when the skip lifts.
* `restart/run.sh`: `DATA_DIR` is computed before the ENOSPC check (it measures that dir); the refusal message says
  the refusal lifts at `GC_DOLT_WARN_FREE_BYTES` free and that `--force` still overrides.

## Why it is not live (tried 28/11)

The Mayor decided to port it into the local pack copies now ("gc preserves a local pack edit"). That holds for the
`dolt` pack here and not for `bd`: in this city `bd` is a **required** pack, which `MaterializeBuiltinPacks`
(`cmd/gc/embed_builtin_packs.go`, ga-o99jf) refreshes and validates from the binary on every `gc` call that
materializes; only non-required packs keep operator edits (they carry a `.gc-pack-hashes.json` sidecar, and
`dolt` has one, `bd` does not). The two `bd` files (`dolt-enospc.sh`, `gc-beads-bd.sh`) were replaced atomically at
13:14 and were back to the original bytes at 13:14:48; `gc` itself says the `dolt` pack's `commands/restart/run.sh`
differs from the binary and "your edit is preserved" (that file's replacement did not complete: a temp file beside
it was removed, so a surviving edit there is inferred from that message, not tried). The core of the fix is in `bd`
(the helper `restart/run.sh` sources, and `op_recover`, the controller's path), so a port that sticks only in
`dolt` would protect `gc dolt restart` and leave the sticky refusal in recovery. Live is exactly as before.

## Applying

Only the engine window can make the `bd` part stick: take the ENOSPC hunks of `e8547dc572` (not its `setsid` hunks) or this
patch, which is that subset adapted to the packed layout. When the window lands, rename the patch to
`.APLICADO-<date>` like the others. A deliberate stopgap is `patch -p1 -d .gc/system/packs < <patch>`, which the next
`gc start` undoes. A restart-path edit stays Mayor-coordinated.

## Tests and what they prove

`packs/town-deltas/assets/prod-tests/gascity/story-ga-lsmtq2e.sh` (run by `story-delivery.sh` after deploy). `df` is a
stub on PATH, so no real disk pressure and no Dolt, `gc` or database is touched.

* Live packs carry the port → it tests them. They carry none → it applies this patch to a scratch copy of the live
  files and tests that (so it also proves the patch still applies to the deployed base). Half applied, or no port and
  an unapplicable patch → FAIL.
* The table, run on `dolt-enospc.sh` and on the inline fallback: ENOSPC + free ≥ floor → allowed (also exactly the
  floor); free below the floor → refuses; `df` failing or answering garbage → refuses; no ENOSPC → allowed; custom floor;
  floor `0` / `abc` / 19 digits / `02147483648` / `010` all handled; which dir was measured.
* `restart/run.sh` end to end with a stub `gc-beads-bd`: refuses before any stop below the floor and when unreadable,
  restarts at or above it, `--force` still overrides.
* Mutation: with the free-space return forced false (the old behaviour) the table fails on its first case.

## What is NOT covered

The `setsid` / detached-launch and fsync-probe parts of `e8547dc572`, and its Go tests. No test uses a real full disk.
