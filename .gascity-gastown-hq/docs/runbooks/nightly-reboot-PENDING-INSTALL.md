# Nightly reboot — PREPARED, NOT INSTALLED (ga-i9q44)

Status: 2026-09-03, gastown.dog-1. Script written and syntax-checked
(`scripts/nightly-reboot.sh`), plist drafted below and `plutil -lint` clean.
**Not copied to `/Library/LaunchDaemons`, not `launchctl load`ed.** Nothing
in this doc runs on its own.

## Why this exists

`/System/Volumes/VM` (macOS virtual memory) shares the Dolt data-plane's APFS
container, grows in ~1GB blocks under agent-fleet RAM pressure, and does not
reliably shrink without a reboot (see memory
`macos-swap-ratchet-recurring-disk-crisis`). This is the recurring ~2x/week
disk-crisis root cause. A reboot is the only fully reliable lever, it's
already been authorized in principle ("Athos já autorizou reboot diário de
madrugada" — cited in several beads), but no mechanism that actually causes a
reboot has ever been built. ga-i9q44 asks for that mechanism.

## Correction to ga-i9q44's triggering evidence

The bead says the scheduled restore-verify "recusou por disco às 03:17"
(needs ~8.8GB). The actual log
(`.gc/logs/dolt-restore-verify.log`, line for 2026-09-03 03:17) says:

```
2026-09-03 03:17:00 [restore-verify] 'hq': nao consegui ler a contagem viva — sem baseline nao ha verificacao possivel
2026-09-03 03:17:00 [restore-verify] === resumo: hq=SKIP(sem-baseline)  ===
```

That's a **different** failure mode (`sem-baseline`, i.e. the GC_CITY_PATH
export bug just fixed today in ga-ymsl0/055089a4a), not a disk-space refusal.
The genuine disk-refusal precedent is a **different** date: 2026-08-30 05:00
(`'hq': disco insuficiente AGORA — pulando`). The underlying swap-ratchet
problem and the "no reboot mechanism exists" gap are both still real and
independently well-documented — this correction only affects which specific
event should be cited as the trigger, not whether the work is needed.

## What's already on this machine (checked before writing anything new)

- `/Library/LaunchDaemons/com.athos.reboot-once-0700.plist` — a **one-shot**,
  self-disarming reboot LaunchDaemon armed 2026-08-07 for a single date
  (2026-08-08 07:00), for ps-y5nt/ga-dnc2m disk work. Currently unloaded
  (fired once, deleted itself). Its script,
  `~/.property-scrapers/reboot_once_0700.sh`, is the template this new
  script follows: runs as root via LaunchDaemon (no `UserName` key), calls
  `/sbin/shutdown -r now` directly — no sudo/TCC ambiguity.
- `docs/runbooks/reboot-20260829-pre.txt` — the pre-flight snapshot for the
  one other reboot on record (2026-08-29, human-authorized: "Athos autorizou
  29/08 00:53 'pode fazer o reboot pelo qual estava esperando'"). Its
  checklist is what this script's Guards 2-3 encode: gate markers in flight
  = 0, hq beads in_progress = 0 (non-hq in-progress was treated as
  non-blocking there too — inflight-reclaim-guard cleans it up regardless).
- Both prior reboots recovered cleanly: auto-login is set to `athos`
  (`defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser`
  → `athos`) and **FileVault is Off**, confirmed live 2026-09-03 — so a
  reboot does NOT require anyone to type a password at the console. This
  matters because an earlier incident (memory
  `panic-reboot-blackout-launchagents-gated`, 2026-07-05) found an
  *unattended* reboot left the whole town dark for ~7.3h because the
  orchestration daemons are user LaunchAgents that only run inside a login
  session — that gap looks closed now (auto-login + no FileVault), but it
  has not been proven by an actual unattended nightly firing yet.
- `scripts/city-night-window.sh` — the mechanism that would guarantee the
  whole city quiet 00:00-08:00 — is **permanently off** since 2026-08-20, by
  Athos's own explicit decision (token cost). So no calendar hour is
  structurally guaranteed idle; nothing here should assume one is. That's
  why the script re-checks real state every time instead of trusting the
  clock alone.

## Chosen window: 01:00-01:19

Surveyed every `StartCalendarInterval` job across `~/Library/LaunchAgents`
(2026-09-03). Night is busier than expected; the widest clear gap is
00:30-01:30 (WhatsApp campaign jobs end ~21:00-21:xx, a 00:00-00:30 cluster,
then nothing until `whatsapp.anuncios-refresh` at 01:30, then a dense
03:00-04:47 backup/compaction cluster). 01:00 sits centered in that gap; the
script's own late-replay guard only tolerates up to 01:19, staying clear of
the 01:30 job even if the box was down and this fires late on recovery.

## The plist (drafted, `plutil -lint` clean, NOT installed)

Save as `/Library/LaunchDaemons/com.gascity.nightly-reboot.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gascity.nightly-reboot</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/athos/gt/.gascity-gastown-hq/scripts/nightly-reboot.sh</string>
    </array>

    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>1</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <!-- Must NOT run at load: loading this at any time of day would fire
         the script immediately (it self-guards on hour, so a load outside
         01:00-01:19 would just no-op-skip and log — safe either way, but
         RunAtLoad=false is the correct intent regardless). -->
    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>/Users/athos/gt/.gascity-gastown-hq/.gc/logs/nightly-reboot-launchd.out</string>
    <key>StandardErrorPath</key>
    <string>/Users/athos/gt/.gascity-gastown-hq/.gc/logs/nightly-reboot-launchd.err</string>
</dict>
</plist>
```

## Install commands (privileged — NOT run by this session)

```bash
sudo cp /Users/athos/gt/.gascity-gastown-hq/docs/runbooks/<extract-plist-above> \
    /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
sudo chown root:wheel /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
sudo chmod 644 /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
sudo launchctl load /Library/LaunchDaemons/com.gascity.nightly-reboot.plist
```

Verify same night: `.gc/logs/nightly-reboot.log` should show either a clean
SKIP (with reason) or a full pre-reboot state dump followed by an actual
`uptime` reset the next morning.

## What this is parked on

A dog session cannot run `sudo` (blocked in this sandbox) — so the install
step above is structurally out of reach here regardless of policy. Separately
from that mechanical fact: this is a **permanent, recurring, unattended**
reboot of the sole shared machine running the entire operation, every night,
forever, with its first firing inherently unverified until it happens. That's
categorically bigger than either precedent found on this box (both one-shot,
both individually authorized in the moment by a citable Athos message). Per
this city's own doctrine on citable authorization for consequential
irreversible-in-effect actions, activating this needs a specific go — not
inferred from "reboot has been authorized in principle" language in other
beads (that's exactly the pattern the doctrine warns against).

**The decision isn't technical** — the script and plist are done and can be
installed in under a minute by anyone with sudo. What's open is: who signs
off on flipping a standing, unattended, nightly reboot switch for the shared
box, and does the auto-login recovery (looks solid on paper, unproven live
unattended) get a supervised first run before going fully hands-off. Handed
to Mayor via ga-i9q44 comment + nudge rather than decided here.
