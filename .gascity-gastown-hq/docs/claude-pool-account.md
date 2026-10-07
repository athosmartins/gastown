# Pool Claude account as data (ga-8hcnvb.1, ga-8hcnvb.2)

The headless pool (dog, wa-worker, ps-worker, gate-reviewer, boot, deacon, auto-refiner — ~90% of the spend)
changes Claude account by itself **when the one in use hits its limit — at 100%, not before** — and goes back to the
account it left once that account has renewed **and a usage collection taken after the renewal confirms it ranks ahead**
— so up to about one collector period (30 min) after the renewal, not at the instant of it (see "The way back waits for a
fresh collection"). No restart, no lost conversation, no login asked of Athos (the 5 setup-tokens are already in the vault
as `claude-oauth-token-<email>`), and **no credit spent doing it**: the whole switch is this script, with no `claude`, no
LLM and no agent in the path. Mayor and crews are **not** touched by it as it stands (they never go through the wrapper that
points a session at the pool item, and their panes are never looked at or pressed); putting them on the pool is phase 2, a
decision that is still pending and would have to be made on purpose, because once they follow the item a switch moves them
too: see "Mayor and the crews".

> **There is deliberately no threshold.** Athos 04/10: *"tem que trocar no 100%. A gente não quer ficar com 5% sem usar."*
> A utilization trigger (the old "95%" of this bead's `acceptance_criteria`, with its single tunable parameter) would leave
> the last 5% of every window unused, and it is **revoked**: those structured fields are stale, the description is the
> binding text. The pool moves when the limit was actually **hit**, and that is known from a pool session sitting on
> claude's limit screen, not from a percentage.

## How it works

```
 claude-pool-account.py  (launchd, every 60 s, single instance)
   1. LOOK at the pool's own tmux panes (no API call): is a POOL session showing claude's limit screen? That is
        - the MODAL ("What do you want to do?" / "1. Stop and wait for limit to reset" / "Enter to confirm · Esc to cancel",
          as the LAST thing on the screen) - claude opens it on a session's FIRST hit only; or
        - the ENVELOPE ("⎿ You've hit your weekly limit · resets ..." as the LAST turn on the screen, the prompt box under it)
          - every later hit of that session, after the modal was dismissed; it blocks nothing.
        in a pane the wrapper proved to be a pool session - see "What counts as evidence"
   2. no pool pane on the limit screen -> no EVIDENCE probe (the only call that can cost), so no switch for the limit, no key.
                                          (failback below aside)
      a pool pane on the limit screen -> ask the ACTIVE account ONCE (1-token haiku call, anthropic-ratelimit-unified-* headers)
          rejected / 429  -> failover in the SAME run: next account of ordem_das_contas() that is not known-exhausted and whose
                             KEY is accepted (count_tokens, never billed); store the reset time of the one that was hit
          answers         -> the screen is not about this account (another model's limit, a modal about to go away...):
                             stay; the same MODAL is not asked about again for 10 min (CLAUDE_POOL_EVIDENCE_COOLDOWN_S);
                             an ENVELOPE that was answered is never asked about again (a NEW hit is a new envelope)
          cannot tell     -> change nothing (network, 5xx, a redirect: error is not exhaustion)
      could not look (tmux down, ps unreadable, the wrapper's log unreadable) -> nothing concluded about the limit screens:
                                          no evidence probe, no failback, no key
   2b. EVERY run that did not make the evidence probe also asks the ACTIVE account, for FREE (count_tokens: never billed, it
      never serves a generation), whether its KEY is still accepted - with or without panes, tmux readable or not:
          refused (401/403) -> failover in the SAME run, to the first account whose key is accepted. This needs no pane:
                               a revoked or expired setup-token shows inside a session as a 401 "API Error" line, which is
                               NOT a limit screen, so nothing on screen would ever say it - and the whole pool would stop
          accepted          -> nothing (a healthy answer is logged about every 30 min, see "Proof that the switch costs no credit")
          cannot tell       -> nothing moves, and the log says so while it lasts (`KEY-CHECK ... unknown`, every 5th minute)
      (it says nothing about BALANCE: a key can be accepted by an account that has hit its limit - that stays with the evidence)
   3. failback ONLY when no evidence stands unanswered: to an account we saw exhausted, whose stored reset time has passed,
      whose usage reading in the usage store was taken AFTER that reset, and which that reading ranks ahead of the active
      one - at the stored reset time, with NO probe of it (not to one whose KEY was refused, 401/403: see Known limits).
      If it has not really renewed, its 429 shows up on a pool pane again (the envelope, or the modal) and the failover
      above runs again.
   4. UNSTICK: sessions that were on the MODAL of the credential just replaced do not notice the new one by themselves;
      once the item has been in place for 45 s the daemon sends each of them ONE Escape - see "The Escape exception"
      (a session that shows only the envelope is not blocked: its prompt answers on the new credential, no key is sent)
   vault (Bitwarden) read lazily: the ACTIVE account's key every run, the other accounts' only when the pool moves
   a key the vault does not return for the active account is NOT "its key is gone": the item is the second witness
   writes ONE Keychain item  "Claude Code-credentials-50adeaf1"   (the POOL's item only - never the plain
                             "Claude Code-credentials" of Mayor and the crews: a setup-token there kills their Remote
                             Control, so write_item refuses any service name that is not "...-<8 hex>")
                             (first 8 hex of sha256("/Users/athos/.gastown/claude-pool-cred") - the ABSOLUTE path, as
                              exported in CLAUDE_SECURESTORAGE_CONFIG_DIR; claude never sees a "~")
   publishes the decision    /Users/athos/shared/data/claude_pool_current_account.json  {"current": "<email>", ...}

 claude-lowprio.sh  (last hop of providers.claude-headless)
   item exists -> exports CLAUDE_SECURESTORAGE_CONFIG_DIR=~/.gastown/claude-pool-cred and USER, logs
                  "POOL-ACCT SET item=..." with its pid, then exec claude (so that pid IS the claude)
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

Mayor 04/10 (comment on the bead) and Athos 04/10 (ga-8hcnvb.2) override the original wording: **no utilization threshold**
(fail over only when the limit is actually hit) and **no confirmation probe on failback** (go back at the stored reset
time; if it has not really renewed, its 429 sends the pool to the next account again).

## What counts as evidence that the limit was hit

The one call that can cost - a `messages` call - is made about an account **only when a pool session already shows the
limit**, so that the switch costs nothing: a call that is *rejected* (429) is free, a call that is *served* costs tokens
(and may open an idle 5 h window), and `count_tokens` (the key checks: a candidate's before the item moves, the active
account's on every run) is never billed. Measured on claude 2.1.291 with a really exhausted account,
the limit shows in a pane in **two forms**, and which one depends on how many times that session has hit it:

1. **The modal - a session's FIRST hit only.** In place of the prompt box, and until a key is pressed (identical 20 s later):

```
 What do you want to do?
 ❯ 1. Stop and wait for limit to reset
   2. Wait here, then continue automatically at Oct 7 at 7pm
   3. Upgrade your plan
 Enter to confirm · Esc to cancel
```

2. **The envelope - every later hit.** Once the modal has been dismissed, claude does not open it again (measured: not
   even 150 s later). Each further hit is an inline error turn, with the prompt box under it and nothing blocking:

```
 ❯ Reply with exactly: BRAVO
 ⎿ You've hit your weekly limit · resets Oct 7 at 7pm (America/Sao_Paulo)
   /upgrade to increase your usage limit.
 ✻ Brewed for 1s · done 7:39 AM
```

Looking only for the modal would therefore see a session's first hit and nothing after it - measured live: after a
failback and a second exhaustion the modal never came back, and the pool would have stayed on the exhausted account. So
the limit screen is the modal **or the envelope as the last turn on the screen**.

A pane is **evidence** only if all of these hold (each is a reason *not* to act, so a doubt means "no"):

- the wrapper logged `POOL-ACCT SET item=<the pool item>` for a pid that is **alive**, whose `ps` start time agrees with the
  log line's time (a recycled pid is another process), and that is the pane's own process or a descendant of it; the pane
  is not dead;
- the agent name on that line is a **pool role** (the allow-list `POOL_AGENT_RE` in the daemon: `gastown.dog`, `gastown.boot`,
  `gastown.deacon`, `wa-worker`, `ps-worker`, `gate-reviewer`, `refino-gate-reviewer`, `context-check-reviewer`,
  `auto-refiner`, each optionally followed by `-<suffix>` such as `gastown.dog-3` or `gate-reviewer-adhoc-ab12cd` - the pool and
  autonomous roles, which `city.toml` keeps on the `claude-headless` provider), or is the wrapper's own `?` for an unset
  `GC_AGENT`. Measured on the wrapper's real log on 2026-10-07 (and still true of the day of it that is left after the log was
  trimmed): `gastown.dog`, `gate-reviewer`, `wa-worker`, `refino-gate-reviewer` and `auto-refiner` have `SET` lines. `gastown.boot`, `gastown.deacon` and `ps-worker` are in the
  list because `city.toml` names them as `claude-headless` roles (the comment on that provider); `context-check-reviewer`
  because it is a pool-style reviewer, with neither a `SET` line nor a `city.toml` line saying so. A name in the list that
  never has a `SET` line costs nothing - the list is only consulted for pids the wrapper put on the pool item - so the gap
  to watch is the other direction, a pool role missing from it. Anything else - Mayor, a crew, a role nobody listed yet, a name
  that is no name - is not even looked at, whatever else says it follows the item (see "Mayor and the crews" for why this is
  an allow-list and not a deny-list);
- **the modal:** the footer `Enter to confirm · Esc to cancel` is the **last** line of the screen, and
  `What do you want to do?` precedes `1. Stop and wait for limit to reset` in the lines above it (an agent that merely
  *quotes* those words has its prompt box under the quote and does not match);
- **the envelope:** a line that starts with `⎿` and says `You've hit your ... limit` (claude's own error turn, not a
  line an agent printed in the middle of its work) is the **last turn** on the screen, in the last 24 lines: no later `⏺`
  or `⎿` turn, no `esc to interrupt` (the session is working again), no later prompt with text typed after it. A session
  that answered after the envelope - its conversation went on - is no longer showing the limit and is not evidence;
- the screen is **new**: the daemon keeps a signature of the limit turn it last looked at in each pane (the prompt line, the
  envelope, up to the next separator - the modal and the same screen after an Escape share it, a *new* hit does not,
  because it has another prompt and another time). An envelope that was answered once is never asked about again; a modal
  at most once per cooldown (600 s);
- the screen is **not stale**: a session that was already running when the item was rewritten and is first seen on the limit
  screen within 90 s of the rewrite is on the *replaced* credential's screen and says nothing about the account in use now
  (for the modal, that is what the Escape is for). A hit that was already on the screen before the rewrite stays stale for as
  long as it is the last turn. A session launched after the rewrite never had the old credential, so its screen is evidence.

Three states, as everywhere in this daemon: **evidence** (make the evidence probe once), **no evidence** (make none; a
failback is allowed), **could not look** (`tmux` down or not runnable, `ps` unreadable, the wrapper's log unreadable): nothing
is concluded about the limit screens - no evidence probe, no failback, no key, and what was remembered about the panes is left
as it was. The free key check of the active account (step 2b) is outside these three states: it looks at the key, not at the
panes, so it runs in all of them. The same holds for one pane
inside a scan that otherwise worked: a pool pane whose screen cannot be read this run (`capture-pane` failed) is logged
(`n pool pane(s) could not be read this run`) and is neither evidence nor "gone" - its first-seen time, tries and answered
question are kept, so a stale modal does not come back looking fresh.

## The Escape exception

The send-keys doctrine of this city is "never send keys to a session". This daemon makes **one scoped, documented
exception**: after it rewrites the pool item it sends the key **Escape**, and only Escape, to a pool pane that is still on
the limit modal of the credential it replaced - because that modal does not notice the new credential by itself (measured,
ga-2yyitx), and without the key the session would wait for a human. Escape on the modal returns the session to its prompt and
the conversation goes on with the account the item holds now. **Only the modal is ever pressed**: the envelope (a later hit
of a session) blocks nothing - the prompt under it is live and the next message goes out on the new credential - so a pane
that shows only the envelope gets no key, whatever else is true of it. Every condition below is a reason **not** to send:

| Guard | What it protects |
|---|---|
| never in the run that rewrote the item, and not before it has been in place for **45 s** | claude re-reads the item every ~30 s: an Escape earlier would land the session on the *old* credential's modal again |
| only pool panes proven as above, **whose agent name is a pool role** (allow-list on the raw name in the log reader, and again on the tidied name in the scan; anything else is dropped and, if its process is alive, named in the log on a due minute) | Mayor's / the crews' Remote Control must never be disturbed (Athos 05/10). The first fence is that they run `claude-rc` / `claude-rc-crew`, not the wrapper, so no `SET` line exists for them; the list is the second, and it fails closed |
| the pane has an **agent name**: the wrapper logs `agent=?` when it cannot tell who the session is, and such a pane is still evidence (it follows the item, so the pool moves for it) but is never pressed | a session that cannot be told from Mayor or a crew is not pressed; the log says `no agent name ... no Escape for them` |
| the item still holds the credential of the decision (fingerprint), is readable, and the account in use is not registered exhausted | an Escape into a credential that is itself exhausted would land on the modal again |
| the pane's process and the modal are re-read **immediately before** the key (the scan is seconds old) | a pane that changed or went back to working is not interrupted |
| at most **3 tries per pane**, counted *before* the attempt and kept in the state file (junk there reads as "already tried"); at most **20 keys per run** | an Escape that does not take is not repeated for ever; a burst is never unbounded |
| `GC_POOL_UNSTICK=0` or `touch $GC_CITY_PATH/.gc/no-pool-unstick` | the key can be turned off alone; the daemon still decides and switches |
| a failure in this step is logged by type and the run goes on to publish the decision | the item was already rewritten; the decision must follow it |

## Proof that the switch costs no credit

Every call that could be billed leaves a log line **before** it is made, so "it spent nothing" can be read off the log:

- `API-CALL messages (1-token haiku) with the key fp=...` - the evidence probe. Against an exhausted account it is a **429,
  which is free**. This is the *only* call that could ever be served (and so billed): when a screen is about another model's
  limit and the account answers it costs a few tokens, **bounded** to once per cooldown per screen (600 s; a *new* screen is
  asked about at once), and never on a pane that is not proven to be a pool pane.
- `API-CALL count_tokens (not billed) with the key fp=...` - a candidate's key check, one line per call.
- `KEY-CHECK <account> fp=... (count_tokens, not billed): valid|invalid|unknown (http=...)` - the key check of the ACTIVE
  account (step 2b). It is made on every run that did not make the evidence probe, and `count_tokens` never serves a
  generation, so it costs nothing. It is **not** one line per call: the shared log is also where the wrapper's `POOL-ACCT SET`
  lines are read from (its last 1 MiB), and a line a minute would push them out within days - also when the check keeps
  failing. So `invalid` is logged every time (it is acted on: it is the reason line for the switch), an `unknown` ("could not
  tell") only on the clock minutes that are a multiple of 5 (`KEY_CHECK_UNKNOWN_LOG_EVERY_MIN`), and a `valid` one only on
  those that are a multiple of 30 (`KEY_CHECK_LOG_EVERY_MIN`) - a heartbeat. "About every N minutes", not promises: a run that
  does not land in that minute logs nothing, so one isolated `unknown` may go unlogged while one that lasts is logged within
  minutes. Silence of a few minutes between `KEY-CHECK` lines therefore says nothing; silence much longer than half an hour
  means the check is not running.
  What the zero-credit proof needs is unaffected: it is the absence of `API-CALL messages` lines and of served calls.
- `EVIDENCE: n pool pane(s) on the limit modal|message (...)` (`message` = the envelope), `SWITCH a -> b ...`,
  `UNSTICK: Escape sent to pane ...`.
- `pane scan: N live pool process(es) in no tmux pane ..., M ps row(s) not understood ...` and `N pool pane(s) on a limit screen
  judged STALE ...` - what a run left out without acting; only on the clock minutes that are a multiple of 10 and only when
  there is something to say (see Known limits). They are not proof of anything on their own, and the zero-credit proof does not
  read them.

No `claude` is started by the daemon (a static check in the selftest keeps `claude` out of every subprocess call, and a
`claude` stub on its PATH proves none is ever run); no token appears in argv, env, log, state or output (the selftest
greps for them after the failover, the failback and the unstick paths). The selftest's end-to-end cycle (B71) asserts: hit ->
failover, unstuck by one Escape, back by the timer with **no call about the account that renewed**, hit again -> failover
again, **zero calls served by the API**, `claude` never run.

## Mayor and the crews

The daemon only ever touches the pool's hashed item (`Claude Code-credentials-<hash of the pool dir>`), never the plain
`Claude Code-credentials` of Mayor and the crews. Two fences keep it away from their sessions:

1. **The provider (the real one).** Mayor runs on `claude-rc` and the crews on `claude-rc-crew`; neither goes through
   `claude-lowprio.sh`, the wrapper that points a session at the pool item and logs `POOL-ACCT SET`. The daemon learns which
   pids follow the item only from those lines, so for Mayor and the crews there is nothing to find: no evidence, no probe,
   no Escape, and no failover moves them. (The wrapper has no enrolment list for the pool: every `claude-headless` session
   follows the item. The `enroll=` list in `.gc/context-ab.conf` belongs to the effort A/B, not to the pool.)
2. **The agent name, as an allow-list.** If a `SET` line ever did exist for one of them (a misconfigured template, a hand
   edit), the daemon still acts only on lines whose agent is a pool role (`POOL_AGENT_RE`). A deny-list on `mayor` / `crew`
   does not hold: the crews are called `oracle-wa`, `mila-wa`, `thies-wa`, `batista-wa`, `digo-wa`, `peter-wa` (and
   session-suffixed forms such as `oracle-wa-ga25kuos`), and Mayor is `gastown.mayor` - names that a pattern for the word
   "crew" never matched. The list names what may be pressed, so a name nobody thought of is out. Its cost is the opposite
   gap: a **new pool role** that is not in the list is never unstuck. That gap is not silent: a live session of an unknown
   role on the pool item is named in the log (`... agent name that is no pool role (<name>) - not looked at, no Escape; a new
   pool role belongs in POOL_AGENT_RE`), on clock minutes that are a multiple of 10.

Putting Mayor and the crews on the pool is phase 2 (decision pending). That decision is not something either fence can make
for it: they keep them out of the *evidence* and out of the *Escape*, not out of the item - once phase 2 puts them behind the
wrapper they follow the item, and every switch moves them too (and a setup-token, which is all the pool's item holds, cannot
serve their Remote Control).

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
| Keep deciding and switching, but never press a key in a pane | `touch $GC_CITY_PATH/.gc/no-pool-unstick` (or `GC_POOL_UNSTICK=0` in the daemon's environment) |
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
| `.gc/logs/claude-pool-account.log` | daemon + wrapper events (`POOL-ACCT SET/SKIP/KEEP`, `EVIDENCE`, `API-CALL ...`, `KEY-CHECK ...`, `SWITCH a -> b`, `UNSTICK`, `pane scan`, `judged STALE`) |

## Known limits

- `CLAUDE_SECURESTORAGE_CONFIG_DIR` is an undocumented claude variable: a claude release can rename the item. The
  live harness is the check to re-run after upgrading claude (a mismatch shows as P2a failing); the per-version
  self-test and the divergence alert are ga-8hcnvb.3.
- Only turn boundaries were measured; a switch in the middle of a long tool call is not guaranteed.
- A limit modal already open in a live TUI does not notice the restored credential by itself: that is what the Escape is
  for (ga-8hcnvb.2, "The Escape exception"). A session that is not a pool session is never pressed.
- **Evidence comes from the panes, so what the panes cannot show is not seen.** (1) A headless `claude -p` call that hits the
  limit prints an error envelope and exits - there is no pane to show it in, so it is *not* evidence on its own; it is
  carried along by the next switch that a pane triggers (any interactive pool session on the same account will show the
  modal or the envelope), and a usage-store signal at >= 100% is a possible follow-up, not built here. (2) If `tmux` itself is permanently broken, no limit-driven failover and
  no failback can happen (they are evidence-driven by design; the log says `the pool's panes could not be looked at this
  run` every minute until it is fixed). A key that is *refused* still fails over then: that is the free key check (step 2b),
  which needs no pane. (3) The modal and envelope texts are claude's (measured on 2.1.291): if a release
  rewords them the daemon sees no evidence and does not move - the live harness is the check to re-run after upgrading
  claude, like the item name. (4) A screen that looks like the limit but belongs to something else costs one bounded served call per cooldown
  (see the proof above), never more.
- **What the free key check proves, and what it does not.** `count_tokens` answering 2xx means the key is *accepted*; it says
  nothing about balance (that stays with the evidence) and nothing about whether a session using it works. That it answers
  401/403 for a *revoked or expired* setup-token - the case step 2b exists for - is the endpoint's documented behaviour and
  was **not measured here against a really revoked token** (none was to hand): the selftest proves what the daemon does when
  it gets a 401/403 (B17b-B17g, against a mock), not what the endpoint answers for a token that was revoked. A 429 or a 5xx
  from it is "cannot tell": logged, never acted on. If it is rate-limited it simply stops finding things - and says `unknown`.
  Also not measured: what a session that is already printing 401 errors does once the item changes. No key is sent to it (a 401
  is not the limit modal, so the Escape does not apply); it is expected to pick the new credential up on its next re-read of
  the item (~30 s, measured at turn boundaries), but that was not observed for this failure.
- **Two things the pane scan leaves out without acting, said in the log only now and then.** On the clock minutes that are a
  multiple of 10 (`SILENT_DROP_LOG_EVERY_MIN`; not every run - this log is shared, see below) the daemon says what it
  dropped, so that "no evidence" can be told from "there was something and it could not be used". (1) `pane scan: N live pool
  process(es) in no tmux pane (nothing to look at), M ps row(s) not understood (...); K pane(s) looked at`: a pool process
  that is alive but sits in no pane of this tmux server (a headless `claude -p`, or a wrong `CLAUDE_POOL_TMUX_SOCKET`) has no
  screen to look at and reads as "not on the limit screen"; a `ps` row that did not parse is a pid missing from the table, which
  reads as "not running". The line is a **count, not a diagnosis**: it cannot tell a process that is legitimately in no pane (a
  headless run) from a wrong socket. Read it as a trend: a `N` that is above 0 while the pool's sessions are known to be in
  tmux means the socket is wrong or the panes are not found, and the daemon is then blind to every limit screen - which is
  exactly the case that used to be silent. (2) `N pool pane(s) on a limit screen judged STALE - the pool item was rewritten at
  ...`: a limit screen that the credential just replaced produced (it was first seen less than 90 s after the rewrite,
  `STALE_WINDOW_S`, on a session that was started before it) is not evidence, and used to be mentioned in the log only on the
  Escape path - which is the modal's. A genuine hit on the *new* credential 30-90 s after a rewrite is still ignored for as
  long as it stays the last turn, and a failover through a chain of exhausted accounts can lose about that much per hop; what
  changed is that the log now says a screen was judged and why.
- **The wrapper's `POOL-ACCT SET` lines are read from the last 1 MiB of the shared log**, and `log-reaper.sh` does not list
  `claude-pool-account.log` today. That is why the daemon keeps this log quiet (the healthy `KEY-CHECK` heartbeat is once per
  30 minutes, not per run). If the log is ever truncated in place (`copytruncate`) or renamed away, the reader sees nothing of the
  sessions that launched before that, which reads as "no session follows the item" - no evidence, and a failback allowed -
  and neither a rename nor a truncation makes it better: the live sessions' `SET` lines are in the file that went away. What
  the daemon does about it is to say it: a log that is not there (or no `GC_CITY_PATH`) is a `no pool launch read: ...`
  line on clock minutes that are a multiple of 10. There is no rotation that is safe with live pool sessions; if the file
  must be cut, cut it only when none is running (or keep its tail), and restart the sessions that were.
- The verdict comes from a 1-token **haiku** call, while the pool runs mostly on Sonnet. If a window exists that limits
  Sonnet but not haiku, the probe says "allowed" while the pool's sessions are blocked, and no failover happens (the log says
  `answers - the limit modal|message on screen is not about this account`, which is how this case would show up). Whether
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
  that log line (the divergence alert of ga-8hcnvb.3 is about the account in use, not about the collector). The library's `_faixa` ignores the session
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
  the decision it keeps the decision and asks about that very credential - the evidence probe when a pane shows the limit,
  and otherwise the free key check of step 2b, on every run (accepted / answers → stay; rejected or refused → the normal
  failover; cannot tell → nothing). If the item itself cannot be read (locked keychain) nothing changes. Only when the
  item is missing, holds another credential, or the state has no fingerprint to compare is the pool chosen again from
  the order (log: `nothing corroborates`). Every run in which the current key did not come from the vault logs one
  WARN, `its key did not come from the vault this run`; a stretch of them means the vault is failing — or that the key
  was deliberately removed, in which case the pool keeps using the copy in the item until that credential is refused (which
  the next run's key check finds, with no pane needed).
  While the vault is down no candidate's key can be read either, so a failover cannot complete: the rejection is
  recorded and the pool stays where it is (the item is not touched). A three-state return in the library would still be
  cleaner; the daemon no longer depends on it to be safe.
- An account that is absent from `ordem_das_contas()` for a run (the usage store lacks its entry) gets the same
  treatment: it is ranked last, not dropped, and the pool stays on it while it answers.
- The failback target's key is read only when a failback is due; if the vault does not return it that run, the
  failback is not done and the account stays registered as exhausted, so a later run that has its key completes it.

## Exit codes (`launchctl list` → last exit status)

`0` = ran (or was legitimately idle: kill switch on, another run holds the lock, the usage store gave no order of use).
**Also `0`, and not idle in any good sense:** the accounts library is missing or does not import. That run logs one `WARN`
(`accounts library not found …` / `failed to import …`) and exits 0 having decided nothing, so `launchctl list` shows the
same `0` as for a healthy run. Only the log tells them apart; a liveness signal that does not depend on reading it is
ga-8hcnvb.3.
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
