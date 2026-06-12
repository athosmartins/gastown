# Claude auto-relog (ga-jf689)

Auto-swap to a Claude account with more quota when the active account hits the
**apex** of its 5h-window limit ("You've hit your session limit · resets HH:MM"),
so the Mayor / gate reviewers / dogs / workers keep going instead of stalling
the gate into a 45-min false-FAIL.

- **Detector:** `scripts/claude-quota-check.sh` (ga-wjlv9) — reads the real
  exhaustion event from the transcript, not a wall-clock guess.
- **Actuator:** `scripts/claude-account-relog.sh` — swaps the macOS Keychain
  credential (`Claude Code-credentials`) to a pool account with headroom.
- **Fallback:** if no pool account has headroom, it does **not** swap — it
  signals PAUSE and defers to ga-x3nmz (pause-until-reset).

## Security model (AC4: no credential ever hits a log)

- Account credential blobs live in **Bitwarden**, fetched at runtime via
  `secret claude-acct-<label>`. Nothing is hardcoded.
- The blob is read from / written to the Keychain and the secret store only —
  never echoed, logged, or written to a bead.
- Accounts are identified in logs by a **label** + an 8-hex **fingerprint**
  (sha256 prefix of the access token), never the token itself.
- Every line the script prints passes a redaction guard that **aborts** if it
  ever contains an `sk-ant-` token.

## Fail-closed by default

The launchd job (`com.gascity.claude-account-relog`, every 5 min) ships
**disabled**: `auto` no-ops and logs `disabled` unless `CLAUDE_RELOG_ENABLED=1`.
Loading the job never mutates live credentials before you've opted in.

## One-time setup (operator)

For each spare Claude account with headroom, capture its Keychain blob **while
logged in as that account** and store it in Bitwarden under `claude-acct-<label>`:

```bash
# While Claude Code is authenticated as the spare account "beta":
security find-generic-password -s "Claude Code-credentials" -w   # copy this JSON blob
# Store it in Bitwarden as a secret named: claude-acct-beta
```

Register the labels (and tag whichever account is currently active):

```bash
cd /Users/athos/gt/.gascity-gastown-hq
# Tag the account currently in the Keychain:
scripts/claude-account-relog.sh register alpha
# Declare the pool order (lower = preferred); persists via registry, or set
# CLAUDE_RELOG_POOL in the plist:
export CLAUDE_RELOG_POOL="alpha beta gamma"
```

Arm it: add to the plist's `EnvironmentVariables`:

```xml
<key>CLAUDE_RELOG_ENABLED</key><string>1</string>
```

then reload:

```bash
launchctl unload ~/Library/LaunchAgents/com.gascity.claude-account-relog.plist 2>/dev/null
cp packs/town-deltas/assets/claude-account-relog.plist ~/Library/LaunchAgents/com.gascity.claude-account-relog.plist
launchctl load ~/Library/LaunchAgents/com.gascity.claude-account-relog.plist
```

## Commands

| Command | What it does |
|---|---|
| `claude-account-relog.sh status` | active account + quota verdict + pool headroom (read-only) |
| `claude-account-relog.sh pool` | configured labels + cooldown state |
| `claude-account-relog.sh current` | label of the account currently in the Keychain |
| `claude-account-relog.sh select` | next label with headroom (or `none`) |
| `claude-account-relog.sh register <label>` | tag the current Keychain blob as `<label>` |
| `claude-account-relog.sh swap <label> [--dry-run]` | swap Keychain to `<label>` (gated) |
| `claude-account-relog.sh auto [--dry-run]` | detect apex → swap to headroom, or PAUSE |

Exit codes: `0` ok/no-op/swapped · `2` apex but no headroom (PAUSE) · `3` swap
failed (missing/invalid secret) · `1` internal/usage.

## How cooldown works

We can't query a candidate account's live quota without logging in as it. So
instead of polling, when we observe an apex event under the active account we
record it **limited-until-its-reset**; selection skips any account still in
cooldown. Cooldown clears automatically at the reset time (and on the next
successful `register`/swap onto that account).

## Tests

`scripts/claude-account-relog.selftest.sh` — fully hermetic (injected Keychain,
secret store, quota checker, notify). Covers apex→swap, no-headroom→pause,
cooldown, fingerprint identification, fail-closed gating, dry-run, missing
secret, and the credential-redaction guard. Run: `bash
scripts/claude-account-relog.selftest.sh` (expect `15 passed, 0 failed`).
