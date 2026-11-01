## Contents
- [What this covers](#what-this-covers)
- [Pollers dir prune](#pollers-dir-prune)
- [Where to look](#where-to-look)
- [Not verified](#not-verified)

# Nudge pollers prune (ga-9uv1xps.2)

## What this covers
`<city>/.gc/nudges/pollers/` grew without bound (32,639 files on 2026-11-01), found while looking at `oracle-wa`
(5 PENDING items fenced to an old session) on 2026-10-31. This is point 2 of bead `ga-9uv1xps`; the stranded
PENDING nudges are `ga-9uv1xps.3` and the `ga-j96y0n` patch bookkeeping is `ga-9uv1xps.1`.

## Pollers dir prune
The engine writes `<stem>.pid`, `<stem>.pid.lock` (empty flock file) and `<stem>.log` per poller and nothing cleans
the dir up in practice (the measured 17,200 locks vs 15,069 pids fits the engine removing a `.pid` on a clean exit, and
never the lock). `assets/scripts/nudge-pollers-prune.py` removes a stem only when it is dead, untouched for 7 days and
unlocked:
- Liveness comes from `ps`, never from the files. Signal a: a live `gc nudge poll --session S <agent>` whose
  `sha256(S + "\0" + agent)[:8]` is the stem's 16-hex suffix (the engine's own `PollerFileStem`; checked against
  all live pollers on 2026-11-01). Signal b: the stem's `.pid` names a live process whose command line has
  `nudge poll`. Either keeps the stem.
- A `ps` that fails, is empty, or does not list the script itself, or a live `nudge poll` whose target cannot be
  parsed, makes the run delete nothing (exit 2). An empty process list is not "no pollers".
- A stem it cannot decide about is kept, counted in `kept_undecided` (never in `kept_live`) and named in a
  `WARN: kept undecided:` line on stderr (first 20 per run, then a "... and N more" line): its file times cannot be read,
  its `.pid` exists but cannot be read, or its `.pid.lock` can be neither opened nor locked. A run where many stems land
  there is a read problem, not a healthy run: check `kept_undecided` in the log.
- A garbled or empty `.pid` (including non-ASCII digits) is "no signal b", not "alive" and not a crash.
- `--min-age-days` must be a number >= 1 (`nan` and anything below 1 are refused, exit 2).
- Only names matching `<stem>-<16 hex>.(pid|pid.lock|log)` that are regular files are touched. `os.unlink`, no `rm`.
- The `.pid.lock` is unlinked while this run holds `LOCK_EX` on it. The engine keeps that file on purpose, as the stable
  mutex inode (gate reviewer's reading of upstream `cmd/gc/cmd_nudge.go`, `reapStaleNudgePoller`), because removing it can
  let a third acquirer create a new inode and double-spawn a poller. The race needs two concurrent starters of a stem that
  has been idle for 7+ days with no live poller, inside a window of about 100 microseconds; accepted, not closed.
- First run (2026-11-01): 14,862 stems / 27,147 files removed, 0 errors; 6 live pollers kept intact.
  Growth is about 700 files/day, so without the order the dir is back to ~30k in six weeks.

## Where to look
- Order `nudge-pollers-prune` (every 3 h) runs `assets/scripts/nudge-pollers-prune.sh`, which passes `--apply`.
- Log (one json line per run): `$GC_CITY_RUNTIME_DIR/packs/town-deltas/nudge-pollers-prune.jsonl`.
- Selftest: `assets/scripts/nudge-pollers-prune.selftest.sh` (macOS and the Linux test node: `date` and `mktemp` try the
  BSD form, then the GNU one); `NPP_PRUNE_UNDER_TEST` runs it against a mutated copy.

## Not verified
- The bead said `polecat-churn-watcher.sh` reads `polecat-*.pid` from the pollers dir. The script was not found
  in the known script dirs, `~/.gastown`, launchd or docs, and there are no `polecat-*` files in the dir today.
  The prune treats every stem the same, so a reader of those files would see them only after 7 days dead.
- The unreadable-times and unreadable-`.pid` branches are tested with a pollers dir of mode 400 (`scandir` lists the
  names, `lstat` and `open` fail). That fixture assumes a non-root user.
- The engine's rationale for keeping the lock, and "the engine removes the `.pid` on a clean exit", come from reading
  upstream main, not from the engine build installed on the mini.
- With `GC_CITY` unset and a working directory that is not the city, the wrapper refuses (`pollers dir missing`, exit 2)
  but the log line is still written under `./.gc/runtime/...` of that directory. The pollers dir itself is never created.
- Signal b is looser than the engine's matcher: a PID reused by another poller keeps the stem until that poller exits.
