# Pool Claude account as data (ga-8hcnvb.1)

The headless pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner — ~90% of the spend)
changes Claude account by itself when the one in use hits its limit, and goes back when that account renews.
No restart, no lost conversation, no login asked of Athos (the 5 setup-tokens are already in the vault as
`claude-oauth-token-<email>`). Mayor and crews are **not** touched (phase 2).

## How it works

```
 claude-pool-account.py  (launchd, every 60 s, single instance)
   probe the ACTIVE account (1-token haiku call, anthropic-ratelimit-unified-* headers)
     rejected / 429  -> failover: next account of ordem_das_contas() that answers a probe; store the reset time
     answers         -> stay; failback ONLY to an account we saw exhausted, whose stored reset time has passed
                        and which outranks the active one — no probe of it on the way back
                        (not to one whose KEY was refused, 401/403: see Known limits)
     cannot tell     -> change nothing (network, 5xx: error is not exhaustion)
   writes ONE Keychain item  "Claude Code-credentials-50adeaf1"
                             (first 8 hex of sha256("/Users/athos/.gastown/claude-pool-cred") — the ABSOLUTE path, as
                              exported in CLAUDE_SECURESTORAGE_CONFIG_DIR; claude never sees a "~")
   publishes the decision    /Users/athos/shared/data/claude_pool_current_account.json  {"current": "<email>", ...}

 claude-lowprio.sh  (last hop of providers.claude-headless)
   item exists -> exports CLAUDE_SECURESTORAGE_CONFIG_DIR=~/.gastown/claude-pool-cred and USER, then exec claude
   item missing / security hangs / any doubt -> exports nothing: the session starts on the ambient login

 claude (live pool session) re-reads the item every ~30 s  =>  a rewritten item moves it to the other account

 whatsapp_automation lib/claude_account_pool.py: contas_utilizaveis() puts conta_decidida() first
```

The last line is a **separate delivery**: the whatsapp_automation branch `fix/ga-8hcnvb.1-wa-current-account` (same bead).
Until it merges the decision file is published but the WhatsApp services do not read it and keep their own order; the
headless pool itself follows the Keychain item either way. Merge both, or the two halves disagree.

Why the daemon never starts `claude`: the account that is exhausted is the one `claude` would run on. The probe is
plain HTTP; the switch is `security -i` with the new blob on **stdin** (hex), so no token is ever in argv, the
environment, a log, the state file or a notification. Accounts appear as e-mail + sha256[:8] fingerprint.

Mayor 04/10 (comment on the bead) overrides the original wording: **no utilization threshold** (fail over only when
the limit is actually hit) and **no confirmation probe on failback** (go back at the stored reset time; if it has not
really renewed, its 429 sends the pool to the next account again).

## Activation — merged is not live

The script path in the plist only exists after the merge. After the gate merges, **someone loads the plist**:

```bash
cp /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/claude-pool-account.plist ~/Library/LaunchAgents/com.gascity.claude-pool-account.plist
launchctl load ~/Library/LaunchAgents/com.gascity.claude-pool-account.plist      # first run <= 60 s later
tail -f /Users/athos/gt/.gascity-gastown-hq/.gc/logs/claude-pool-account.log
```

Until the first run creates the item nothing changes for anyone. Pool sessions **born before** the item existed keep
their ambient login (the variable is fixed at birth); every pool session born afterwards follows the item.

Check it is live (not just merged): `launchctl list | grep claude-pool-account` and
`jq . /Users/athos/shared/data/claude_pool_current_account.json` (current / since / reason / exhausted).

## Kill switches (no config reload)

| Want | Do |
|---|---|
| Stop the daemon acting AND new pool launches pointing at the item | `touch $GC_CITY_PATH/.gc/no-pool-account` (remove the file to resume) |
| One launch only | `GC_POOL_ACCOUNT=0` in that launch's environment |
| Remove the mechanism completely | `launchctl unload ~/Library/LaunchAgents/com.gascity.claude-pool-account.plist`, then `security delete-generic-password -a "$USER" -s "Claude Code-credentials-50adeaf1"` — new sessions fall back to the ambient login by themselves |

Live sessions that already follow the item keep the **last written** account when the daemon stops; that is a valid
login, not a broken state. What a LIVE session does when its item is deleted underneath it was not measured (a
session born with the variable pointing at a missing item starts "not logged in" — measured in ga-2yyitx) — so unload
first, delete last, and only when restarting the pool is acceptable.

## Files

| File | Role |
|---|---|
| `packs/town-deltas/assets/scripts/claude-pool-account.py` | the daemon (`run-once`) |
| `packs/town-deltas/assets/scripts/claude-lowprio.sh` | wrapper: points a pool launch at the item (fail-open) |
| `packs/town-deltas/assets/claude-pool-account.plist` | launchd job, not loaded by the merge |
| `packs/town-deltas/assets/scripts/claude-pool-account.selftest.sh` | hermetic tests (fake security / vault / API, real accounts lib) |
| `packs/town-deltas/assets/scripts/claude-pool-account.live-accept.sh` | acceptance on the real API + a live TUI session |
| `whatsapp_automation/lib/claude_account_pool.py` | services read `claude_pool_current_account.json` first |
| `.gc/logs/claude-pool-account.log` | daemon + wrapper events (`POOL-ACCT SET/SKIP/KEEP`, `SWITCH a -> b`) |

## Known limits

- `CLAUDE_SECURESTORAGE_CONFIG_DIR` is an undocumented claude variable: a claude release can rename the item. The
  live harness is the check to re-run after upgrading claude (a mismatch shows as P2a failing); the per-version
  self-test and the divergence alert are ga-8hcnvb.3.
- Only turn boundaries were measured; a switch in the middle of a long tool call is not guaranteed.
- A limit modal already open in a live TUI does not notice the restored credential by itself (needs Esc);
  unsticking such sessions is ga-8hcnvb.2.
- The verdict comes from a 1-token **haiku** call, while the pool runs mostly on Sonnet. If a window exists that limits
  Sonnet but not haiku, the probe says "allowed" while the pool's sessions are blocked, and no failover happens. Whether
  such a per-model window shows up in the `anthropic-ratelimit-unified-*` headers was not measured here; the live
  harness (`claude-pool-account.live-accept.sh`) is where to check it.
- A key the API **refuses** (401/403) is registered for an hour like a limit, but at that time it is **not** failed back
  to: the failback does not probe, and a key that is still refused would be written into the item and break every pool
  session until the next run — once an hour for as long as the key stays bad. It is dropped from the registry and probed
  the normal way when a later failover reaches it. Consequence: after such a key is fixed the pool does not return to
  that account on its own; it moves there the next time the account in use is rejected.
- The daemon depends on `whatsapp_automation/lib/claude_account_pool.py` for the order and the vault read
  (`CLAUDE_POOL_ACCOUNTS_LIB` overrides the path). If it is missing or fails to import the daemon does nothing.
- That library's `token_da_conta()` returns `None` both for "no key in the vault" and for "vault unreadable just
  now" (it logs the second). If the vault hiccups for the CURRENT account only, the daemon sees it as "no usable
  key", picks again and may move the pool to the next probed-good account; it is a valid account and the services
  follow the decision, but the pool then stays there until that one is exhausted (failback only goes back to an
  account the daemon saw exhausted). A vault outage that hides every key is inert. Telling the two apart needs a
  three-state return in the library — not done here.

## Exit codes (`launchctl list` → last exit status)

`0` = ran (or was legitimately idle: kill switch on, another run holds the lock, nothing usable in the vault).
`1` = **refused or failed**: no usable `GC_CITY_PATH/.gc` so the single-instance lock cannot be taken, the lock file
cannot be opened, the login name is not a plain name (`USER` is also read from the passwd database when launchd
gives none), or the state file exists but cannot be read. In every `1` case nothing was probed or written. A state
file that is not a JSON object (or is not UTF-8 text, or is nested too deep to parse) is moved to
`claude_pool_current_account.json.corrupt.<epoch>` and the daemon starts from empty. Inside a readable state, what
cannot be trusted is dropped, never defaulted: an `exhausted` that is not an object (`null` included — present-but-null
is not the same as absent), an entry without a usable `reset_epoch` (missing, null, not a number, non-finite, or outside
2001–2100), a `current` that is not an account name. A reset time in a rate-limit header that is not usable (same test)
is replaced by the 15-minute cooldown, so garbage can neither read as "already reset" nor as "exhausted for ever".
