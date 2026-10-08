# Pool Claude account as data (ga-8hcnvb.1) and its guard (ga-8hcnvb.3)

The headless pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner — ~90% of the spend)
changes Claude account by itself when the one in use hits its limit, and goes back to the account it left once that
account has renewed **and a usage collection taken after the renewal confirms it ranks ahead** — so up to about one
collector period (30 min) after the renewal, not at the instant of it (see "The way back waits for a fresh collection").
No restart, no lost conversation, no login asked of Athos (the 5 setup-tokens are already in the vault as
`claude-oauth-token-<email>`). Mayor and crews are **not** touched (phase 2).

## How it works

```
 claude-pool-account.py  (launchd, every 60 s, single instance)
   probe the ACTIVE account (1-token haiku call, anthropic-ratelimit-unified-* headers)
     rejected / 429  -> failover: next account of ordem_das_contas() that answers a probe; store the reset time
     answers         -> stay; failback ONLY to an account we saw exhausted, whose stored reset time has passed,
                        whose usage reading in the usage store was taken AFTER that reset, and which that reading
                        ranks ahead of the active one — no probe of it on the way back
                        (not to one whose KEY was refused, 401/403: see Known limits)
                        a reading from BEFORE the reset is no evidence: the entry is kept and the log says it waits
     cannot tell     -> change nothing (network, 5xx, a redirect: error is not exhaustion)
   vault (Bitwarden) read lazily: the ACTIVE account's key every run, the other accounts' only when the pool moves
   a key the vault does not return for the active account is NOT "its key is gone": the item is the second witness
   writes ONE Keychain item  "Claude Code-credentials-50adeaf1"   (the POOL's item only — never the plain
                             "Claude Code-credentials" of Mayor and the crews: a setup-token there kills their Remote
                             Control, so write_item refuses any service name that is not "...-<8 hex>")
                             (first 8 hex of sha256("/Users/athos/.gastown/claude-pool-cred") — the ABSOLUTE path, as
                              exported in CLAUDE_SECURESTORAGE_CONFIG_DIR; claude never sees a "~")
   publishes the decision    /Users/athos/shared/data/claude_pool_current_account.json  {"current": "<email>", ...}
   stamps a heartbeat        <city>/.gc/claude-pool-account.heartbeat — ONLY at the end of a run that logged no ERROR
                             (a clean run that had nothing to decide counts; a refused Keychain write, a read-back that
                              does not match or an unpublished decision does not). The guard reads it: see "The guard".
                             A run the operator's switches stood down stamps NO heartbeat (the guard knows: see LIVENESS).

 claude-lowprio.sh  (last hop of providers.claude-headless)
   item exists -> exports CLAUDE_SECURESTORAGE_CONFIG_DIR=~/.gastown/claude-pool-cred and USER, then exec claude
   item missing / security hangs / any doubt -> exports nothing: the session starts on the ambient login

 claude (live pool session) re-reads the item every ~30 s  =>  a rewritten item moves it to the other account

 whatsapp_automation lib/claude_account_pool.py: contas_utilizaveis() puts conta_decidida() first
```

The last line is a **separate delivery**: the whatsapp_automation branch `fix/ga-8hcnvb.1-wa-current-account` (same bead).
Until it merges the decision file is published but the WhatsApp services do not read it and keep their own order; the
headless pool itself follows the Keychain item either way. Merge both, or the two halves disagree.

The probe never follows a redirect (urllib would re-send the Bearer to wherever a 30x points): a 30x is "cannot tell".

Why the daemon never starts `claude`: the account that is exhausted is the one `claude` would run on. The probe is
plain HTTP; the switch is `security -i` with the new blob on **stdin** (hex), so no token is ever in argv, the
environment, a log, the state file or a notification. Accounts appear as e-mail + sha256[:8] fingerprint.

Mayor 04/10 (comment on the bead) overrides the original wording: **no utilization threshold** (fail over only when
the limit is actually hit) and **no confirmation probe on failback** (go back at the stored reset time; if it has not
really renewed, its 429 sends the pool to the next account again).

## The guard — divergence alert and the daemon's liveness (ga-8hcnvb.3)

`claude-pool-guard.py` (launchd, every 60 s, single instance, its own plist) is what makes the silent failures of the switch loud.
It writes **none** of the pool's credentials and corrects nothing; it looks, records and alerts. (Delivered in slices: this one is the
divergence alert and the liveness watch - ga-8hcnvb.3.1; the per-version test and the proof that no key leaks are the next two.)

```
 claude-pool-guard.py run-once
   1 DIVERGENCE   the account whose key is in the pool item   vs   the decision file's current + fingerprint
                  different for 2 min (the daemon writes the item and THEN the file: a shorter disagreement is normal)
                    -> ONE push, priority 4, forced:  "Pool Claude: conta em uso diverge da regra (regra xxxxxxxx, em uso yyyyyyyy)"
                       expected: <email> (fp xxxxxxxx)   in use: <email> (fp yyyyyyyy)   — names and 8-hex fingerprints, never a key
                    -> repeated only every 6 h while nobody fixes it ("Lembrete: ..."); nothing when it is fixed (the episode
                       closes in the state file and the log says "divergence over")
                  the in-use account is named from the item's fingerprint: the vault is asked (keys in the memory of a child
                  process only); if the vault does not answer, from what the guard saw match earlier; if neither, the message says
                  exactly that ("o cofre não respondeu" / "não é nenhuma das chaves" / "item ausente" / "sem decisão") — no guess
   2 LIVENESS     no clean daemon run (heartbeat) for 10 min -> one push "Pool Claude: o daemon de troca não está fechando rodadas
                  (última: <stamp>)" (not while the mechanism is off; not for a pool that was never activated).
                  The silence is judged only over time the guard was LOOKING: a stamp that went stale while the guard was not there
                  (reboot, sleep, launchd unloaded: two looks more than 5 min apart) or while the daemon was stood down on purpose
                  (`no-pool-account`, GC_POOL_ACCOUNT=0 - the real daemon stamps nothing then) is no evidence of a
                  death: after any of those the 10 minutes start again from the first look. A daemon that really stays silent is still
                  told 10 minutes after that. A heartbeat that cannot be read (garbled, no time in it, stamped in the future, not a
                  file) or a pool whose activation cannot be told (Keychain locked, no decision) is "could not tell": no verdict, and
                  the 30-minute "guarda sem enxergar (<what>)" notice instead.
```

Every push carries what makes its condition different IN THE TITLE (the two fingerprints of a divergence, what the guard cannot see, the
last heartbeat): `notify` drops a push whose title already went out in the last 30 minutes, whatever the body says (exit 11), and the guard
counts that as delivered - so two conditions sharing a title would lose the second one.

Three answers, never two: every check is yes / no / could not tell, and "could not tell" never acts.

State: `/Users/athos/shared/data/claude_pool_guard.json` (`divergence`, `blind`, `daemon`). Log: `<city>/.gc/logs/claude-pool-guard.log`.

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

**The guard is a second plist, a second human step, and nothing in this merge loads either.** Load the daemon's first (the guard
watches that daemon: with no daemon and no item the guard stays silent, by design — a pool that was never activated is not "dead"):

```bash
cp /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/claude-pool-guard.plist ~/Library/LaunchAgents/com.gascity.claude-pool-guard.plist
launchctl load ~/Library/LaunchAgents/com.gascity.claude-pool-guard.plist     # first run <= 60 s later
tail -f /Users/athos/gt/.gascity-gastown-hq/.gc/logs/claude-pool-guard.log
```

Until it is loaded there is no divergence alert and no liveness alert: the daemon works the same, unwatched.

## Kill switches (no config reload)

| Want | Do |
|---|---|
| Stop the daemon acting AND new pool launches pointing at the item | `touch $GC_CITY_PATH/.gc/no-pool-account` (remove the file to resume) |
| One launch only | `GC_POOL_ACCOUNT=0` in that launch's environment |
| Stop the guard too | the same two (`no-pool-account` / `GC_POOL_ACCOUNT=0`): the guard then does nothing — no alert, no state written |
| Remove the mechanism completely | `launchctl unload` both `~/Library/LaunchAgents/com.gascity.claude-pool-guard.plist` and `~/Library/LaunchAgents/com.gascity.claude-pool-account.plist`, then `security delete-generic-password -a "$USER" -s "Claude Code-credentials-50adeaf1"` — new sessions fall back to the ambient login by themselves |

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
| `packs/town-deltas/assets/scripts/claude-pool-account.selftest.sh` | hermetic tests (fake security / vault / API, real accounts lib); it also repoints every path it inherits (`GC_CITY_PATH`, `HOME`, the state / cred-dir / accounts-lib seams) at scratch, and D1 fails if a fixture line reached the log of the city it was launched from; it refuses to start (exit 2) without a scratch directory, or when `security` on its PATH is not the fake - otherwise B49b writes a fixture token into the REAL Keychain (found there 06/10: `Claude Code-credentials-0123abcd` holding `sk-ant-oat01-ALLOWED`) |
| `packs/town-deltas/assets/scripts/claude-pool-account.live-accept.sh` | acceptance on the real API + a live TUI session |
| `packs/town-deltas/assets/scripts/claude-pool-guard.py` | the guard (`run-once`) |
| `packs/town-deltas/assets/claude-pool-guard.plist` | the guard's launchd job, not loaded by the merge |
| `packs/town-deltas/assets/scripts/claude-pool-guard.selftest.sh` | hermetic tests of the guard (G1-G4 divergence, G6 liveness, G10 stand-down vs. death) |
| `/Users/athos/shared/data/claude_pool_guard.json` | the guard's state: open episodes |
| `.gc/claude-pool-account.heartbeat` | the daemon's last clean run |
| `.gc/logs/claude-pool-guard.log` | guard events (`divergence seen/over`, `alert sent`) |
| `whatsapp_automation/lib/claude_account_pool.py` | services read `claude_pool_current_account.json` first |
| `.gc/logs/claude-pool-account.log` | daemon + wrapper events (`POOL-ACCT SET/SKIP/KEEP`, `SWITCH a -> b`) |

## The item holds a credential the daemon did not write (ga-xknkke)

The daemon is the only script that writes the item, but it is not the only thing that CAN: a `claude` session whose
`CLAUDE_SECURESTORAGE_CONFIG_DIR` points at the item (every pool session does) writes there on a `/login` or a token
refresh. When that happens the daemon sees a different `accessToken`, logs `pool item holds fp=<x> but the decision is
<email> fp=<y> - rewriting`, and puts the decision back. Since ga-xknkke the line is followed — **before** the rewrite
erases the evidence — by

```
foreign write to the pool item (fp=<x>): blob keys=[...] top=[...] refreshToken=yes|no expiresAt=<iso> scopes=[...]
  subscriptionType=<t>; item modified <UTC>; young claude processes: pid=<n> age=<mm:ss> tty=<t>; ...
```

How to read it: the daemon's own blob has **no** refresh token, scope `['user:inference']` and an expiry in 2100; a `claude`
login or refresh leaves a refresh token, more scopes and an expiry hours away. `item modified` is the Keychain's own
mtime (UTC), and the processes are the `claude` ones younger than 15 minutes (pid / age / tty only — never argv). Key
NAMES and those few scalars are all that is logged: no token, no refresh token, no value of any other field. Each part
that could not be read says `unreadable`; it never says `none` for something it could not tell, and a field the blob simply lacks
says `absent` (a JSON null says `null`, as this daemon's own blob has for the tier). A missing item gets no
such line (nobody wrote anything). The daemon still rewrites in every case: one decision file is what the services read.

## Known limits

- `CLAUDE_SECURESTORAGE_CONFIG_DIR` is an undocumented claude variable: a claude release can rename the item. The
  live harness is the check to re-run after upgrading claude (a mismatch shows as P2a failing); a per-version
  self-test is the next slice of the guard (ga-8hcnvb.3.2), the divergence alert is already in (ga-8hcnvb.3.1).
- Only turn boundaries were measured; a switch in the middle of a long tool call is not guaranteed.
- A limit modal already open in a live TUI does not notice the restored credential by itself (needs Esc);
  unsticking such sessions is ga-8hcnvb.2.
- The verdict comes from a 1-token **haiku** call, while the pool runs mostly on Sonnet. If a window exists that limits
  Sonnet but not haiku, the probe says "allowed" while the pool's sessions are blocked, and no failover happens. Whether
  such a per-model window shows up in the `anthropic-ratelimit-unified-*` headers was not measured here; the live
  harness (`claude-pool-account.live-accept.sh`) is where to check it.
- A key the API **refuses** (401/403) is registered for an hour like a limit, but at that time it is **not** failed back
  to: the failback does not probe, and a key that is still refused would be written into the item and break every pool
  session until the next run — once an hour for as long as the key stays bad. It is dropped from the registry (with a
  `dropped: its key was refused` log line) and probed the normal way when a later failover reaches it. Consequence: after such a key is fixed the pool does not return to
  that account on its own; it moves there the next time the account in use is rejected.
  The same rule covers an `exhausted` entry that does not say why it was registered (`why` missing or not
  `rejected`/`invalid` — the daemon always records it, so only a state file edited by hand or written by something else
  lacks it): only an entry that says `rejected` is failed back to. The other is dropped at its time, with one `WARN`
  (`does not say why it was registered`) and a `dropped:` line, and probed the normal way if a later failover reaches it.
- **The way back waits for a fresh collection.** The order of use comes from the usage store
  (`claude_usage.json`), which the collector rewrites every 30 min (`com.urblink.claude-usage-collector`,
  `StartInterval=1800`) while this daemon runs every 60 s: at the reset tick the order can be half an hour old, and a
  reading taken *before* the reset says nothing about the account *after* it. So an expired entry — the only evidence
  that the account renewed — is never judged by the order alone. The daemon reads each account's `last_ok_at` (the
  time its numbers were real) from the store, **before** asking the library for the order, and acts on an entry only if
  that account has a good reading (not `stale`, `ok` not false, a timestamp with a zone that is not ahead of the
  clock) taken *after* its stored reset:
  - no such reading → the entry is **kept**, one INFO line per run says so
    (`waiting for a usage collection of <account> taken after its reset … Entry kept`, with the reason: the last good
    reading predates the reset / the last collection failed / no row / no usable `last_ok_at` / stamped ahead of the
    clock) and the next run asks again. The pool stays on the account in use meanwhile — the cost of not guessing;
  - a good reading after the reset → the order decides: ranked ahead of the active account → failback; otherwise the
    entry is dropped with a line that says it ranks behind the active one.
  An account whose collection keeps failing is therefore never gone back to (and its entry sits in the registry, one
  log line per run) until the collector reads it again; it is still probed the normal way if a failover reaches it. A
  collector that stopped altogether leaves every expired entry waiting, and nothing here alerts on it: the only trace is
  that log line (the guard's divergence alert is about the account in use, not about the collector). The library's `_faixa` ignores the session
  window's own `resets_at` (that is where a stale "esgotada" comes from); it is not changed here, the daemon just does
  not rely on the order for what the order cannot know.
- **Nothing leaves the registry in silence.** Every removal of an exhausted entry has a `dropped:` line with the reason
  (the active account answered; a refused key at its time; no `why`; ranked behind the active account on a fresh
  reading; ranked behind a better recovered account that took the pool; the account became the pool's account). When the
  Keychain write of a failback is refused, the recovered accounts that were **not tried** stay in the registry too
  (the log counts them); when a recovered account's key does not come from the vault that run, its entry stays and the
  next candidate is still tried.
- The daemon depends on `whatsapp_automation/lib/claude_account_pool.py` for the order and the vault read
  (`CLAUDE_POOL_ACCOUNTS_LIB` overrides the path). If it is missing or fails to import the daemon does nothing.
- That library's `token_da_conta()` returns `None` both for "no key in the vault" and for "vault unreadable just
  now" (it logs the second). The daemon therefore never reads a `None` for the CURRENT account as "its key is gone":
  it reads the Keychain item it wrote, and if the item holds a credential whose sha256[:8] equals the `fingerprint` of
  the decision it keeps the decision and probes that very credential (answers → stay; rejected or refused → the normal
  failover; cannot tell → nothing). If the item itself cannot be read (locked keychain) nothing changes. Only when the
  item is missing, holds another credential, or the state has no fingerprint to compare is the pool chosen again from
  the order (log: `nothing corroborates`). Every run in which the current key did not come from the vault logs one
  WARN, `its key did not come from the vault this run`; a stretch of them means the vault is failing — or that the key
  was deliberately removed, in which case the pool keeps using the copy in the item until that credential is refused.
  While the vault is down no candidate's key can be read either, so a failover cannot complete: the rejection is
  recorded and the pool stays where it is (the item is not touched). A three-state return in the library would still be
  cleaner; the daemon no longer depends on it to be safe.
- An account that is absent from `ordem_das_contas()` for a run (the usage store lacks its entry) gets the same
  treatment: it is ranked last, not dropped, and the pool stays on it while it answers.
- The failback target's key is read only when a failback is due; if the vault does not return it that run, the
  failback is not done and the account stays registered as exhausted, so a later run that has its key completes it.

- **What the guard's "in use" means.** The account in use is the credential in the pool **item** — what every new pool session and every
  live one (they re-read it every ~30 s) will use. It is not the account a given running session holds this second, and a session born
  before the item existed (ambient login) is invisible to it. A divergence is the item against the decision file.
- **Quiet hours.** `notify` holds every push from 22:00 to 07:00 (BRT) and delivers them at 07:00 in one push. The guard counts that as
  delivered (notify's exit 10) and does not resend. So "alert within 5 minutes" holds outside quiet hours; at night the alert is
  recorded and reaches the phone at 07:00. An alert that must wake someone at night needs `NOTIFY_NO_QUIET=1` on that call — a
  decision for Athos, not made here.
- **Nothing here is live until the plists are loaded** — the daemon's and the guard's (see Activation). A merged guard that is not loaded
  alerts nobody.

## Exit codes (`launchctl list` → last exit status)

`0` = ran (or was legitimately idle: kill switch on, another run holds the lock, the usage store gave no order of use).
**Also `0`, and not idle in any good sense:** the accounts library is missing or does not import. That run logs one `WARN`
(`accounts library not found …` / `failed to import …`) and exits 0 having decided nothing, so `launchctl list` shows the
same `0` as for a healthy run. The log tells them apart, and so does the heartbeat: that run does not stamp
`.gc/claude-pool-account.heartbeat` (only a run that reaches its end without an ERROR does), and once the guard is loaded 10 minutes
without a stamp is a push ("o daemon de troca não está fechando rodadas").
`1` = **refused or failed**. Two different things share this code, and the log tells them apart:

- *Refused* before the run started any work: no usable `GC_CITY_PATH/.gc` so the single-instance lock cannot be taken,
  the lock file cannot be opened, the lock call fails for a reason other than another run holding it (that is the quiet
  `0`), the login name is not a plain name (`USER` is also read from the passwd database when launchd gives none), or
  the state file exists but cannot be read. In these refusals nothing was probed or written.
- *Failed* after the run had started, and **here the pool may already have moved**:
  - the decision could not be published (the state directory is full or not writable). The Keychain item is written
    before the decision file is, so the run may have switched the pool while the file the WhatsApp services read still
    names the account just left. The log says which: `decision NOT published (<ExcType>) but the pool item was switched
    to <email> fp=<fp>; the decision file and the item disagree until a run publishes`, or, when the run moved nothing,
    `decision NOT published (<ExcType>); this run did not move the pool item to another account`. The next run that can
    publish brings the two back together: it repeats the switch (the item write is idempotent), or, if the old account
    answers again, heals the item back to the decision.
  - any other unexpected exception: `ERROR unhandled <ExcType> in run-once`. It can come from any point of the run, so
    exit `1` with this line does **not** mean nothing happened; read the log lines before it.

A state file that is not a JSON object (or is not UTF-8 text, or is nested too deep to parse) is moved to
`claude_pool_current_account.json.corrupt.<epoch>` and the daemon starts from empty. Inside a readable state, what
cannot be trusted is dropped, never defaulted: an `exhausted` that is not an object (`null` included — present-but-null
is not the same as absent), an entry without a usable `reset_epoch` (missing, null, not a number, non-finite, outside
2001–2100, or more than 31 days ahead of now), a `current` that is not an account name. A reset time already behind
now is kept: that account's time has come, and the failback is what it is for. A reset time in a rate-limit header is
believed only if `now < reset <= now + 31 days` (the same bound is applied again where it is stored); anything else
falls back to the `retry-after` duration if that is usable (a finite number of seconds, at most 31 days), else to the
15-minute cooldown — so a bad header can neither read as "already reset" nor veto an account for longer than 31 days.
(A value like year 2096 passes as an epoch; only this bound relative to now stops it.)
