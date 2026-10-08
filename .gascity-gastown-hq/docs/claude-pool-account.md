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
   stands down               while <city>/.gc/pool-account-degraded exists (written by the guard, never by the daemon),
                             or the operator's switches are on - and stamps NO heartbeat while it does (the guard knows: see LIVENESS)

 claude-lowprio.sh  (last hop of providers.claude-headless)
   item exists -> exports CLAUDE_SECURESTORAGE_CONFIG_DIR=~/.gastown/claude-pool-cred and USER, then exec claude
   item missing / security hangs / any doubt -> exports nothing: the session starts on the ambient login
   kill switch or the degraded marker present -> exports nothing either (log: POOL-ACCT SKIP disabled by ...)

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

## The guard — divergence alert, per-version test and the daemon's liveness (ga-8hcnvb.3)

`claude-pool-guard.py` (launchd, every 60 s, single instance, its own plist) is what makes the silent failures of the switch loud.
It writes **none** of the pool's credentials and corrects nothing; it looks, records, alerts, and — for one case — turns the
mechanism off. (Delivered in slices: the divergence alert and the liveness watch are ga-8hcnvb.3.1, the per-version test and the
degradation are ga-8hcnvb.3.2; the proof that no key leaks is the last one.)

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
   2 PER-VERSION  `claude --version` not yet tested (or tested and failed: again after 30 min; or inconclusive: again after 5 min)
                    -> self-test on a SCRATCH item (never the pool's, never the plain "Claude Code-credentials"): write a fake
                       credential there, ask `claude auth status --json` with CLAUDE_SECURESTORAGE_CONFIG_DIR pointing at it
                       (must say loggedIn:true), delete the item, ask again (must say loggedIn:false). Local: no inference, no
                       network, ~3 s each. A wrong answer is repeated once; two in a row = FAIL.
                    -> the result per claude version is recorded in the guard's state file and is what `status` shows
                    -> FAIL: writes <city>/.gc/pool-account-degraded. The daemon stops switching (log: disabled by ...), the wrapper
                       stops pointing NEW launches at the pool item (they answer normally on the current login). Nothing is deleted,
                       no running session is touched (it keeps the last account written: a valid login).
                       ONE push, priority 4, forced: "Pool Claude: troca automática DESLIGADA (claude <version>)" (and why)
                    -> FAIL but the marker cannot be written (<city>/.gc not writable, no city): the worst state, so it is said, not just
                       logged: ONE push "Pool Claude: troca automática NÃO foi desligada (claude <version>)" - the pool is still ON.
                       Retried every tick; the normal DESLIGADA push goes out when the marker finally lands.
                    -> PASS after a FAIL: the marker is removed and a quiet notice (priority 2, not forced) "troca automática religada"
                       says it is back on. If the marker is NOT the guard's (`by` says so) it is left alone and nothing is announced:
                       it is still off, and "religada" goes out only once the marker is really gone.
                       The notice is quiet, so `notify`'s router files it in the digest (exit 12): that is where it is meant to go and it
                       counts as delivered (what reaches the phone are the forced alerts: divergence, "DESLIGADA", "guarda sem enxergar", the daemon's silence). If `notify` refuses it any other way it
                       is retried every tick for 30 min, then dropped with a `gave up announcing` line in the log - never for ever.
                       The same exit 12 on a FORCED push is a rate cap: nothing reached the phone, so it is not delivered and is retried.
                    -> INCONCLUSIVE (claude hangs, Keychain locked, output that is not JSON): changes nothing; after 30 min of it, one
                       "Pool Claude: guarda sem enxergar (self-test of claude <version>)" says the guard cannot verify. It never
                       degrades on "could not tell". A claude update drops the "cannot verify" record of the version that is gone.
   3 LIVENESS     no clean daemon run (heartbeat) for 10 min -> one push "Pool Claude: o daemon de troca não está fechando rodadas
                  (última: <stamp>)" (not while the mechanism is off or degraded; not for a pool that was never activated).
                  The silence is judged only over time the guard was LOOKING: a stamp that went stale while the guard was not there
                  (reboot, sleep, launchd unloaded: two looks more than 5 min apart) or while the daemon was stood down on purpose
                  (the degraded marker, `no-pool-account`, GC_POOL_ACCOUNT=0 - the real daemon stamps nothing then) is no evidence of a
                  death: after any of those the 10 minutes start again from the first look. A daemon that really stays silent is still
                  told 10 minutes after that. A heartbeat that cannot be read (not text, not JSON, no time in it or a number that cannot
                  be a time - NaN, a 400-digit integer, 0 -, stamped in the future, not a file) or a pool whose activation cannot be
                  told (Keychain locked, no decision) is "could not tell": no verdict, and the 30-minute
                  "guarda sem enxergar (<what>)" notice instead.
```

Every push carries what makes its condition different IN THE TITLE (the claude version, the two fingerprints of a divergence, what the
guard cannot see, the last heartbeat): `notify` drops a push whose title already went out in the last 30 minutes, whatever the body says
(exit 11), and the guard counts that as delivered - so two conditions sharing a title would lose the second one.

Three answers, never two: every check is yes / no / could not tell, and "could not tell" never acts.

The guard's OWN state file gets the same treatment. A time in it that cannot be used (not a number, a number too big for a float, outside
what can be an epoch, or in the future) is not a crash and not a silence: the start of an episode (`divergence`, a `blind` entry) or the
daemon watch (`checked_at`, `watch_since`) is counted again from this look, and the log says so; an `alerted_at` that cannot be used reads as
"never alerted", so the alert is said once more and the stamp is rewritten. The per-version self-test's stamps follow the same rule: a failed
version's `checked_epoch` that cannot be used reads as "never checked" (the test runs again at once and rewrites it, instead of waiting for
a clock that may be months away); the `alerted_at` of `degraded` and of `marker_failed` reads as "never alerted"; a `notice_since` that
cannot be used restarts the 30 minutes in which the "back ON" notice is retried. What counts as a time is the daemon's own `_sane_epoch`, one
definition for both.

One divergence is ONE episode. If the key in use changes to another wrong one while it lasts, nothing new is sent before the 6 h reminder (which
names whatever is in use then); a new push for a new condition needs the episode to close first. And an open episode is not restarted by the
guard's own absence the way the daemon watch is: after a long gap, a disagreement already there on the first look is judged on the first look,
without the 2 min of persistence. Both are deliberate limits of this slice, not oversights.

**Query it** (the result for the installed claude, and the history per version):

```bash
G=/Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/scripts/claude-pool-guard.py
python3 $G status          # human
python3 $G status --json   # installed_claude, installed_result, versions{<ver>: {result, checked_at, detail, attempts}}, auto_switch, degraded, divergence
                           # installed_result is "unknown (...)" when the state file is corrupt/unreadable or claude's version cannot be read;
                           # "not tested yet" only when nothing is recorded. auto_switch is "on" | "OFF" | "unknown (why)" and degraded is
                           # true | false | null: the marker is looked for under GC_CITY_PATH, which only the plist and agent sessions export -
                           # in a plain shell (or with a city that has no .gc, or a .gc that cannot be read) the answer is "unknown", never "on".
                           # status exits 1 for a bad state file OR an unknown auto_switch. status changes no file.
python3 $G selftest        # run the per-version test now, whatever was recorded, act on the result, and SAY what happened:
                           #   rc 0  "claude X: pass"          (+ "auto-switch is now on" if it lifted the marker)
                           #   rc 3  "claude X: fail"          (+ "auto-switch is now OFF", or "is NOT off: ... marker could not be written")
                           #   rc 4  "claude X: inconclusive"  (nothing changed)
                           #   rc 1  "the self-test was NOT run: <why>"  (kill switch on, another guard run holds the lock, no claude, no city)
                           # (`run-once`, the launchd tick, stays quiet and keeps its rc 0 when it has nothing to do.)
```

State: `/Users/athos/shared/data/claude_pool_guard.json` (`versions`, `divergence`, `degraded`, `blind`, `daemon`). Log:
`<city>/.gc/logs/claude-pool-guard.log`. The test **re-runs by itself** when `claude --version` changes (the next tick, ≤ 60 s).

**The degraded marker** `<city>/.gc/pool-account-degraded` is JSON `{"by": "claude-pool-guard", "claude": "<version>", "since": ..., "reason": ...}`.
Only the guard writes it and only the guard removes it, and only if `by` says so: a marker someone else put there is left alone (the log
says so). To turn the mechanism off by hand use `no-pool-account` (below), not this file.

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
launchctl load ~/Library/LaunchAgents/com.gascity.claude-pool-guard.plist     # first run <= 60 s later: tests the installed claude
python3 /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/scripts/claude-pool-guard.py status
tail -f /Users/athos/gt/.gascity-gastown-hq/.gc/logs/claude-pool-guard.log
```

Until it is loaded there is no divergence alert, no per-version result and no liveness alert: the daemon works the same, unwatched.

## Kill switches (no config reload)

| Want | Do |
|---|---|
| Stop the daemon acting AND new pool launches pointing at the item | `touch $GC_CITY_PATH/.gc/no-pool-account` (remove the file to resume) |
| One launch only | `GC_POOL_ACCOUNT=0` in that launch's environment |
| Stop the guard too | the same two (`no-pool-account` / `GC_POOL_ACCOUNT=0`): the guard then does nothing — no test, no alert, no state written |
| Auto-switch turned OFF by the guard | `<city>/.gc/pool-account-degraded` exists: the daemon stands down and new launches use the ambient login. It lifts itself when the self-test passes again (≤ 30 min, or at once on a new claude version); `claude-pool-guard.py selftest` retests now. Do not delete the file to "fix" it: if the test still fails the guard writes it again |
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
| `packs/town-deltas/assets/scripts/claude-pool-guard.py` | the guard (`run-once` / `status [--json]` / `selftest`) |
| `packs/town-deltas/assets/claude-pool-guard.plist` | the guard's launchd job, not loaded by the merge |
| `packs/town-deltas/assets/scripts/claude-pool-guard.selftest.sh` | hermetic tests of the guard (G1–G14, G16: divergence, per-version test, scratch item, liveness, `status`, stand-down vs. death, one title per condition, marker that cannot be written / is not the guard's, `selftest` output, the quiet notice vs. notify's router) |
| `/Users/athos/shared/data/claude_pool_guard.json` | the guard's state: per-version results, open episodes |
| `.gc/claude-pool-account.heartbeat`, `.gc/pool-account-degraded` | the daemon's last clean run; the guard's "auto-switch is off" marker |
| `.gc/logs/claude-pool-guard.log` | guard events (`SELFTEST claude=… result=…`, `DEGRADED`, `divergence seen/over`, `alert sent`) |
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
  live harness is the check to re-run after upgrading claude (a mismatch shows as P2a failing); the guard re-checks it by
  itself on every new claude version ("The guard", item 2) and turns auto-switch off, with an alert, if it fails.
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
- The guard names the account in use by hashing the keys of the accounts `lib.ordem_das_contas()` lists - the usage store's accounts,
  not the vault's. A vault account the usage store does not know yet is therefore reported as "não é nenhuma das chaves do cofre" (a
  stranger) when it is in fact ours. The message is the only thing that is wrong (the guard changes nothing either way); the push
  carries the fingerprint, so the operator can check it. The same `None` below makes ONE keyless account turn every unknown key into
  "o cofre não respondeu".
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
- **The per-version test approximates the real read.** `claude auth status --json` is the cheapest local way to ask claude "which
  credential do you read for this CLAUDE_SECURESTORAGE_CONFIG_DIR" (measured: it reads that item and nothing else, no fallback to the
  ambient login, no inference). A release could in principle keep that command's behaviour and change the interactive path — the guard
  would pass and the pool break. The live harness (`claude-pool-account.live-accept.sh`, P2a) remains the end-to-end check; the guard is
  what runs the cheap version, every version, unattended.
- **Quiet hours.** `notify` holds every push from 22:00 to 07:00 (BRT) and delivers them at 07:00 in one push. The guard counts that as
  delivered (notify's exit 10) and does not resend. So "alert within 5 minutes" holds outside quiet hours; at night the alert is
  recorded and reaches the phone at 07:00. An alert that must wake someone at night needs `NOTIFY_NO_QUIET=1` on that call — a
  decision for Athos, not made here.
- **Nothing here is live until the plists are loaded** — the daemon's and the guard's (see Activation). A merged guard that is not loaded
  alerts nobody.
- **The leak scan proves what it covers.** Argv and environment are sampled (10 Hz in the test; one snapshot by hand), so a process that
  lives and dies between two samples is not seen; files and logs are scanned in full. A key-shaped string in a process list that is none of
  the five keys (another service's API key, say) is a NOTE, not a failure; in a file the product wrote it is a finding. The scan covers the
  channels it names: a leak into a place it was not told about is not found.

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
