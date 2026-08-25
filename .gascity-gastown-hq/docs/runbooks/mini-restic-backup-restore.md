# Mini machine backup & restore (restic -> Google Drive)

Daily offsite backup of the mini's irreplaceable local config/state, per
Athos's storage decision 2026-08-25 (bead `ga-qu9us`, epic `ga-sfj3i`,
option C: restic -> the user's own Google Drive, R$0/month, offsite,
encrypted, versioned — an external HD was explicitly declined again, see
the epic for measured prices).

This is **not** a full-machine image backup. It covers exactly the
config/state that (a) is not already in git or the S3 transcript backup,
and (b) is not reinstallable from a package manager. Total size is a few
MiB — small and cheap by design, so the daily/weekly/monthly cadence below
is fast enough to actually run unattended every time.

## What's backed up, and why

| Path | Why |
|---|---|
| `~/Library/LaunchAgents` | Every scheduled job on the machine — not in any git repo |
| `~/.gastown` (curated, see excludes below) | Gas Town CLI's own config/state/certs; `git remote -v` shows **no remote** — this is the only copy |
| `~/.gc` (curated) | Gas City engine's global config (`cities.toml`, `registries.toml`, pilot state, installed pack snapshots) |
| `~/.claude/{settings.json,settings.local.json,keybindings.json,.credentials.json,skills/}` | Claude Code config + the OAuth credential that authenticates the CLI itself. **Not** `~/.claude/projects/` (session transcripts) — those are already covered by the existing `com.athos.claude-history-backup` -> S3 job, and are excluded here on purpose to avoid a second, redundant multi-GB copy |
| Dotfiles at `$HOME` (top level, `.{name}`) | `.zshrc`, `.gitconfig`, `.claude.json` (Claude Code's top-level config, MCP servers etc.), shell history, and the various small backup/bak files already sitting there — see "Dotfile selection" below for the exact filter |
| `crontab -l`, `brew list --versions`, `pipx list --short` | Snapshotted as generated text files (`~/.gastown/state/mini-restic-backup/staging/`) — not reinstall targets themselves, but the exact list needed to reinstall/recreate them |
| 3 Bitwarden bootstrap Keychain items | See "Keychain" section below |

### Excluded, and why

| Path / pattern | Why |
|---|---|
| `~/.gastown/bin/` (510 MiB), `~/.gastown/binary-backups/` (167 MiB) | Reinstallable binaries — not config |
| `~/.gastown/logs/` (89 MiB), `**/*.log` anywhere in scope | Ephemeral, high-churn. **This one caught a real bug during setup**: `~/.gc/supervisor.log` alone was 145 MiB and wasn't covered by any of the other excludes — the blanket `*.log` pattern is the actual safety net, not a specific path |
| `~/.gastown/run/`, `~/.gastown/sockets/`, `~/.gastown/.bw-session` | Runtime/session state, meaningless without the live process |
| `~/.gc/cache/` | Content-addressed pack cache (`.packman-cache.lock` confirms it), rebuildable |
| `**/.beads` (catches `~/.gastown/town/.beads/embeddeddolt`) | Structurally the same case the bead's own scope explicitly excludes ("`.beads/dolt` — backup próprio já existe"). This is a *dormant* local dolt store under `~/.gastown/town/` (a template/reference tree, untouched since Feb 2026) — **not** the live production Dolt, which lives at `~/gt/.gascity-gastown-hq/.beads/dolt/` and is out of this backup's scope entirely (see `com.gascity.dolt-s3-backup` for that) |
| `**/__pycache__` | Python bytecode cache |
| `.DS_Store`, `*.lock`, `.claude.json.tmp.*` | macOS/atomic-write cruft, zero restore value |

### Dotfile selection

```bash
find "$HOME" -maxdepth 1 -type f -name '.*' \
  ! -name '.DS_Store' ! -name '*.lock' ! -name '*.log' ! -name '.claude.json.tmp.*'
```

Deliberately permissive (include unless clearly junk) rather than a
hand-maintained allowlist — the false-inclusion cost is near-zero for
KB-sized files, while a hand-typed list silently misses new dotfiles as
they appear. Re-run the `find` above any time to see exactly what the next
backup will pick up.

### Keychain — why there's no full export

macOS has no safe, non-interactive way to export an entire login keychain:
`security dump-keychain` lists metadata only, and pulling actual secret
material per-item triggers a per-item authorization prompt (Touch
ID/password) that can't be scripted unattended. A full export was
evaluated and rejected on that basis.

What *is* backed up — piped straight into restic via `--stdin-from-command`,
never touching local disk — is the 3 Keychain items `SECRETS.md` itself
names as "the only secrets allowed outside the vault":
`BitwardenAPIClientId`, `BitwardenAPIClientSecret`, `BitwardenMasterPassword`
(all under account `athosmartins@gmail.com`). These are the one piece of
Keychain content that can't be recovered *from* a Bitwarden backup — they're
what unlocks Bitwarden in the first place — so they're the actual
chicken-and-egg risk, and the only keychain content worth this treatment.
Everything else the keychain holds is, by this environment's own doctrine
(`SECRETS.md`), supposed to live in Bitwarden anyway.

## Where the secrets live

Two new Bitwarden items, created 2026-08-25 (`secret <name>` to read):

- **`rclone-gdrive-athosmartins`** — JSON: `client_id`, `client_secret`,
  `refresh_token`, `scope`, `account`. The client_id/secret are the *same*
  Google Cloud OAuth app `drive-cleanup.py`'s `--auth-mode=oauth` path
  uses (`~/shared/data/oauth_credentials.json`); the refresh_token is a
  copy of the grant already sitting in `~/.gastown/state/oauth_token.json`
  at the time this was set up (verified live: same account
  `athosmartins@gmail.com`, same `drive` scope, 2049 GB quota / ~984 GB
  free). It's an independent copy, not a shared live file — if
  `drive-cleanup.py`'s token ever gets revoked/rotated, this backup's
  auth is unaffected, and vice versa. Rendered into
  `~/.config/rclone/rclone.conf` by `render-rclone-config.sh` before every
  run (regenerable local cache — the vault item is the source of truth).
- **`restic-mini-backup-password`** — the restic repository's encryption
  password. Never touches disk: every restic invocation gets it via
  `RESTIC_PASSWORD_COMMAND="secret restic-mini-backup-password"`.

**If you ever need to rotate or revoke the rclone credential**, do it
independently of `drive-cleanup.py` — see the `note` field on the
`rclone-gdrive-athosmartins` vault item.

### The rclone config gotcha (read this before touching `render-rclone-config.sh`)

rclone's `drive` backend, on first load of a config whose `token` JSON has
an **empty** `access_token`, re-saves the token to `rclone.conf` and drops
`refresh_token` in the process — permanently breaking auth until the config
is re-rendered from the vault. Reproduced live, rclone v1.75.0. The fix:
`access_token` must be a non-empty placeholder (already done in
`render-rclone-config.sh` — see its inline comment). If `rclone lsd
gdrive-athos-backup:` ever fails with *"token expired and there's no
refresh token"*, this is almost certainly the cause — re-run
`render-rclone-config.sh` and don't run any other rclone/restic command
against this remote until you've confirmed `grep refresh_token
~/.config/rclone/rclone.conf` finds it.

## Cadence (all via launchd, `com.athos.mini-restic-*`)

| Job | Schedule | Script | Does |
|---|---|---|---|
| `com.athos.mini-restic-backup` | daily 04:47 | `mini-restic-backup.sh` | Re-renders rclone config, snapshots (main tree + keychain, 2 restic snapshots), then `restic forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 6` |
| `com.athos.mini-restic-check` | Sundays 05:13 | `mini-restic-check.sh` | `restic check --read-data` — full integrity check (repo is small enough that a full check, not a `--read-data-subset`, is cheap weekly) |
| `com.athos.mini-restic-restore-test` | 1st of month, 05:37 | `mini-restic-restore-test.sh` | Restores latest snapshot of both groups to `/tmp/mini-restic-restore-test`, sanity-checks specific files, discards, files an audit bead |

Logs: `~/.gastown/state/mini-restic-backup/{backup,check,restore-test}.log`
(script-level) and `*-launchd.{out,err}.log` alongside them (launchd-level,
should normally be empty).

Check job status any time: `launchctl print gui/$(id -u)/com.athos.mini-restic-backup`.
Run any of the three manually: `~/.gastown/scripts/mini-restic-{backup,check,restore-test}.sh`
(each is single-flight-locked, safe to run even if a scheduled run is
about to fire — the second invocation just skips).

### Digest visibility

The monthly restore-test's *failure* path labels its bead `incident` —
`mol-digest-generate`'s existing data-gathering step already scans every
rig for that label in-window, so a real restore failure surfaces in the
next digest with **zero changes** to that shared formula. Routine monthly
success does not get digest airtime (digests summarize activity/issues,
not routine green checkmarks) — it still gets a closed, findable
`type=message` bead (`label=mini-restic-restore-test`, same archival
pattern the digest formula uses on itself), so "when did we last verify a
restore" stays answerable:
`bd list --all --include-infra --label=mini-restic-restore-test`.

Making a routine monthly *success* narratively appear in the digest too
would need a small additive change to `mol-digest-generate.formula.toml`'s
data-gathering step (one more label scan, same shape as the incident one).
Deliberately **not** bundled into this work — that formula is shared,
actively iterated, and city-wide; a drive-by edit as part of an unrelated
backup task is more risk than this bead's scope warrants. File a follow-up
bead if that visibility is ever actually wanted.

## Restore procedure (new machine -> operational)

1. **Install restic + rclone**: `brew install restic rclone`
2. **Get the two Bitwarden items onto the new machine.** This is the one
   bootstrapping circularity: `secret` itself needs Bitwarden unlocked,
   which needs the 3 Keychain bootstrap items this same backup captured.
   If you still have *any* working device logged into the
   `athosmartins@gmail.com` Bitwarden account (phone, another Mac, the
   web vault at vault.bitwarden.com), read `rclone-gdrive-athosmartins`
   and `restic-mini-backup-password` from there directly — you don't
   strictly need the new machine's own Bitwarden CLI working yet for
   *this* step. If Bitwarden access itself is gone everywhere, you need
   Bitwarden account recovery first (out of scope here); the
   keychain-item restore in step 5 only helps once a new mini already has
   a keychain to write into.
3. **Render rclone.conf by hand** using those two values (skip
   `render-rclone-config.sh`'s Bitwarden dependency for this bootstrap
   case — just build the file directly, same shape as
   `render-rclone-config.sh` writes):
   ```
   [gdrive-athos-backup]
   type = drive
   client_id = <from rclone-gdrive-athosmartins>
   client_secret = <from rclone-gdrive-athosmartins>
   scope = drive
   token = {"access_token":"placeholder","token_type":"Bearer","refresh_token":"<from rclone-gdrive-athosmartins>","expiry":"2020-01-01T00:00:00Z"}
   team_drive =
   ```
   at `~/.config/rclone/rclone.conf` (`chmod 600` it). Verify with
   `rclone lsd gdrive-athos-backup: --max-depth 1` — you should see
   Athos's real Drive folders.
4. **Restore everything**:
   ```bash
   export RESTIC_REPOSITORY="rclone:gdrive-athos-backup:restic-mini-backup"
   export RESTIC_PASSWORD_COMMAND="secret restic-mini-backup-password"   # or paste the password via RESTIC_PASSWORD if secret isn't up yet
   restic restore latest --tag mini-machine --target /
   restic restore latest --tag mini-machine-keychain --target /tmp/kc-restore
   ```
   The first command writes straight back to the original absolute paths
   (`~/Library/LaunchAgents`, `~/.gastown`, `~/.claude/...`, dotfiles) —
   safe on a fresh machine with nothing there yet; **on a machine that
   already has files at those paths, restic will overwrite them** with
   the snapshot's versions, so don't run it against a machine you still
   care about without checking first.
5. **Re-seed the 3 Keychain bootstrap items** from `/tmp/kc-restore/bitwarden-bootstrap-keychain.json`:
   ```bash
   python3 -c "
   import json, subprocess
   items = json.load(open('/tmp/kc-restore/bitwarden-bootstrap-keychain.json'))
   for svc, val in items.items():
       subprocess.run(['security', 'add-generic-password', '-U',
                        '-s', svc, '-a', 'athosmartins@gmail.com', '-w', val])
   "
   ```
   This unblocks `bw-serve-foreground.sh` -> `secret` on the new machine.
6. **Reinstall packages** from the snapshotted lists:
   `~/.gastown/state/mini-restic-backup/staging/brew-list.txt` and
   `pipx-list.txt` (both plain text, one package per line — reinstall by
   hand or script over them, there's no automated replay here by design).
7. **Reinstall crontab**: `crontab ~/.gastown/state/mini-restic-backup/staging/crontab.txt`
8. **Reload LaunchAgents**: for each `~/Library/LaunchAgents/*.plist`,
   `launchctl bootstrap gui/$(id -u) <plist>`.
9. Sanity-check: `gc doctor`, `bw serve` status, and spot-check a few
   restored dotfiles/configs against what you remember being there.

## Verifying this setup is still healthy

- `restic snapshots` should show a `mini-machine` and a
  `mini-machine-keychain` entry from within the last day.
- `bd list --all --include-infra --label=mini-restic-restore-test --limit 5`
  should show a `message`-typed, closed bead from within the last ~35 days.
  If not, check `~/.gastown/state/mini-restic-backup/restore-test.log` and
  whether `launchctl print gui/$(id -u)/com.athos.mini-restic-restore-test`
  shows it actually firing.
