#!/usr/bin/env bash
# daemon-presence-watchdog.sh — "who watches the watchers" (24/7 resilience).
#
# Detects when a CRITICAL gascity daemon has gone ABSENT (plist on disk but NOT loaded
# — after a reboot, a manual unload, or launchd giving up on a crash-loop) or is
# persistently CRASH-LOOPING (loaded but exiting nonzero on consecutive checks), and
# self-heals + alerts. Closes the 24/7 blind spot where a core pipeline daemon
# (pilot/gate/classify/refine/delivery/...) silently disappears and bead delivery
# stalls for hours with nobody noticing — machine-health-reporter is telemetry-only,
# and nothing checked daemon PRESENCE.
#
# Runs every 5 min via launchd (com.gascity.daemon-presence-watchdog, StartInterval),
# fresh each run (self-recovering by design). Fail-safe: any probe error is logged,
# never crashes the sweep.
#
# Action policy:
#   ABSENT critical daemon         → bootstrap (reload) it + ntfy + mail Mayor (self-heal).
#   CRASH-LOOP (loaded, nonzero exit on 2 consecutive checks) → ntfy + mail Mayor; do NOT
#       reload (it is loaded and failing — reloading would just re-loop; needs a human/Mayor).
#   PRESENCE-DRIFT (plist authored in scripts/ or packs/town-deltas/assets/, not loaded,
#       and not even in DPW_CRITICAL) → ntfy + mail Mayor ONLY — deliberately does NOT
#       auto-bootstrap (ga-u04vp: an un-curated daemon may need real per-daemon
#       evaluation before going live — e.g. config-drift-watcher had been disabled
#       after a prior incident; blindly reviving an unevaluated daemon is its own risk).
#   ALL HEALTHY                    → a single heartbeat line to the log (no noise).
#
# The CRITICAL set is the must-always-run pipeline + the watchdogs that protect it.
# One-shots (suavez-first-watch self-unloads by design) and deprecated jobs are
# deliberately ABSENT from this list — they are never auto-resurrected.
# Override the set with DPW_CRITICAL (space-list of labels).
#
# ga-u04vp — why PRESENCE-DRIFT exists (read before removing or "simplifying" it):
#   7 daemons had a reviewed, selftested plist sitting in scripts/ or
#   packs/town-deltas/assets/ for up to 6 weeks with ZERO launchd coverage, because
#   the fix for each one was "add it to DPW_CRITICAL" — a list that, by definition,
#   only contains what a human already remembered to add. That is precisely the
#   failure mode this class of bug needs closed: the gap is the thing NOT on
#   anyone's list. PRESENCE-DRIFT needs no curation — it scans the same source
#   directories a new daemon's plist would be authored into, and alerts on any
#   com.gascity.*/com.gastown.* Label found there that isn't currently loaded,
#   whether it was never bootstrapped (AC1 case) or silently fell off launchd
#   after being disabled/unloaded (AC2 case — see merged-bead-janitor, which
#   turned out to be `launchctl disable`d, a persistent bit that survives
#   bootout/bootstrap and isn't visible via `launchctl list`/`print`).
#   DOCTRINE (ga-u04vp AC4): a commit that claims "runs automatically via
#   com.gascity.X" is not a deploy — it is a claim. This sweep is what makes the
#   claim provable forever: an author no longer needs to remember to wire in
#   monitoring, because monitoring already scans where they authored the plist.
#   If a daemon is deliberately retired/disabled going forward, remove or rename
#   its SOURCE plist too (not just the deployed copy under ~/Library/LaunchAgents)
#   — otherwise this check will keep flagging it. That repeat false-flag is the
#   intended, cheaper failure mode; the alternative (silently trusting an
#   undocumented disable) is exactly what produced this bug.
#
# ga-vkjs — por que com.gascity.silent-ignorance-watch entrou nesta lista (não remova sem ler):
#   Ele é o monitor da Ignorância Silenciosa, e tem uma propriedade que o torna DEPENDENTE deste
#   watchdog: ele só ALERTA quando acha algo NOVO. Num dia saudável ele sai calado (exit 0, zero
#   ntfy) — de propósito, pra não virar ruído. Consequência: **o silêncio dele é ambíguo entre
#   "vivo e sem novidade" e "morto"**. Ele não consegue detectar a própria ausência — que é
#   exatamente a classe que ele existe pra caçar.
#   Precedente que prova o risco: o scanner do ga-p5q3 (thies) ficou 2 dias em main SEM ser
#   agendado e ninguém notou, porque "detector calado" parecia "sem bug". A city redescobriu a
#   classe do zero por causa disso.
#   ⇒ Este watchdog é o dono da liveness dele. Se o plist for descarregado, aqui dá ABSENT em
#     <5min, recarrega e alerta. É a única coisa que impede o monitor de morrer em silêncio.
#   Nota: é um job de CALENDÁRIO (09:20/dia), não StartInterval — o _loaded() usa
#   `launchctl list <label>`, que vale igual pra os dois.
set -uo pipefail

LAUNCH_DIR="${DPW_LAUNCH_DIR:-$HOME/Library/LaunchAgents}"
LOG="${DPW_LOG:-/Users/athos/gt/.gascity-gastown-hq/.gc/logs/daemon-presence-watchdog.log}"
STATE="${DPW_STATE:-/Users/athos/gt/.gascity-gastown-hq/.gc/daemon-presence-state}"
UID_NUM="$(id -u)"
DPW_RELOAD="${DPW_RELOAD:-1}"     # 1 = auto-reload absent critical daemons; 0 = alert only.
# 1 = suppress a heartbeat-WEDGE flag when the machine only just booted/woke (the
# staleness is then attributable to launchd suspending StartInterval timers during
# system sleep, NOT to a hung daemon); 0 = legacy behaviour (flag regardless).
DPW_WAKE_GRACE="${DPW_WAKE_GRACE:-1}"

DPW_CRITICAL="${DPW_CRITICAL:-com.gascity.pilot com.gascity.context-check-dispatcher com.gascity.quality-gate-dispatcher com.gascity.auto-refino-dispatcher com.gascity.refino-gate-dispatcher com.gascity.story-delivery com.gascity.supervisor com.gascity.supervisor-config-guard com.gascity.inflight-reclaim-guard com.gascity.gate-recovery-watchdog com.gascity.dolt-hang-watchdog com.gascity.production-stall-watchdog com.gascity.crew-hang-detector com.gascity.lifecycle-coherence-janitor com.gascity.crew-autopin-guard com.gascity.lifecycle-correctness-auditor com.gascity.throughput-stall-watchdog com.gascity.gate-throughput-stall-watchdog com.gascity.git-lock-hygiene com.gascity.crew-liveness-probe com.gascity.agent-stuck-escalation com.gascity.quorum-convergence-watchdog com.gascity.approved-state-reconciler com.gascity.auto-rehome-janitor com.gascity.sling-task-janitor com.gascity.gate-marker-rehome-janitor com.gascity.silent-ignorance-watch}"

HQ="${DPW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"

# Heartbeat-WEDGE config — "label|heartbeat-logfile|max-stale-seconds". A LOADED daemon
# whose heartbeat log has NOT advanced past max-stale is WEDGED: loaded + "running" but
# its sweep/loop is stuck (e.g. hung on a Dolt query) OR launchd/DAS never spawned the
# next cycle at all (ga-9wv5: DAS "pended nondemand spawn" — see script header). Either
# way launchd will NOT restart it on its own (it is either alive-but-stuck, or simply
# loaded-and-quiet) and the absent/crash-loop checks miss it (it IS loaded) — so it
# stalls delivery silently. Only daemons that emit a per-cycle heartbeat line are listed;
# thresholds are ≈5× the cycle so a merely slow cycle never trips. A wedge → launchctl
# kickstart -k (un-stick) + alert. Override via DPW_HEARTBEAT; a daemon NOT listed is
# wedge-unchecked.
#
# The heartbeat file does NOT need to be a dedicated touch-file — a script's normal
# launchd-captured stdout (StandardOutPath, "*.out") works too, PROVIDED the script logs
# unconditionally as its first action in main(), before any early-exit (kill-switch,
# lock-contention, no-work). The four *-janitor/*-reconciler entries below rely on this
# (verified: each logs before its ENABLED check can return) rather than adding a new
# heartbeat-touch line to each script — ga-9wv5 closes the coverage gap named in the bug
# (approved-state-reconciler + "the janitors") with a config-only change.
DPW_HEARTBEAT="${DPW_HEARTBEAT:-com.gascity.pilot|$HQ/.gc/logs/pilot-dispatcher.log|1500
com.gascity.inflight-reclaim-guard|$HQ/.gc/logs/inflight-reclaim-guard-launchd.out|1500
com.gascity.context-check-dispatcher|$HQ/.gc/logs/context-check-dispatcher.log|3000
com.gascity.quality-gate-dispatcher|$HQ/.gc/logs/quality-gate-dispatcher.heartbeat|600
com.gascity.auto-refino-dispatcher|$HQ/.gc/logs/auto-refino-dispatcher.log|1500
com.gascity.story-delivery|$HQ/.gc/logs/story-delivery.log|1500
com.gascity.approved-state-reconciler|$HQ/.gc/logs/approved-state-reconciler.out|3000
com.gascity.auto-rehome-janitor|$HQ/.gc/logs/auto-rehome-janitor.out|3000
com.gascity.sling-task-janitor|$HQ/.gc/logs/sling-task-janitor.out|4500
com.gascity.gate-marker-rehome-janitor|$HQ/.gc/logs/gate-marker-rehome-janitor.out|1600}"

# ── RECYCLER — memory-bounded restart of known-leaky Python dashboards ────────
# Knobs (override via env or the launchd plist EnvironmentVariables):
#   RECYCLE_ENABLED        1=on, 0=disabled entirely (default: 1)
#   RECYCLE_DRY_RUN        1=log only, no actual kickstart (default: 0)
#   RECYCLE_RSS_MB         RSS threshold in MiB above which a daemon is recycled (default: 350)
#   RECYCLE_CHRONIC_PER_HR if a daemon needs recycling more than this many times in 60 min
#                          it is "chronically leaking" → escalate to Mayor (default: 3)
#   RECYCLE_DAEMONS        space-separated list of launchd labels eligible for recycling.
#                          ONLY these labels are ever touched — never anything else.
#
# Safety contract: ONLY labels listed in RECYCLE_DAEMONS are ever inspected or recycled.
# Any error (ps failure, label not loaded, kickstart failure) is caught, logged, and skipped;
# the failure never propagates to the watchdog's main sweep.
RECYCLE_ENABLED="${RECYCLE_ENABLED:-1}"
RECYCLE_DRY_RUN="${RECYCLE_DRY_RUN:-0}"
RECYCLE_RSS_MB="${RECYCLE_RSS_MB:-350}"
RECYCLE_CHRONIC_PER_HR="${RECYCLE_CHRONIC_PER_HR:-3}"
# Known-leaky daemons (add more as discovered; frota leaks slowly, auto-response-v2 leaked 455MB/3.5d):
RECYCLE_DAEMONS="${RECYCLE_DAEMONS:-com.urblink.painel-visibilidade com.whatsapp.frota-dashboard com.whatsapp.auto-response-v2-listener}"
# State dir for per-daemon recycle-hour counters (one file per label, content = "EPOCH COUNT"):
RECYCLE_STATE_DIR="${RECYCLE_STATE_DIR:-$HQ/.gc/recycle-state}"

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ── imp05: exit-code failure tracking ────────────────────────────────────────
# A job is FAILING (not just crash-looping) when it exits nonzero on DPW_FAIL_THRESHOLD
# consecutive sweeps. This supplements crash-loop (which is 2 consecutive) with a named
# "FAILING" state so the alert message is unambiguous. Default threshold = 2 (same as
# crash-loop) but override-able for daemons that occasionally fail transiently.
DPW_FAIL_THRESHOLD="${DPW_FAIL_THRESHOLD:-2}"

# ── imp05: binary-provenance config (DEFAULT-OFF — false-positive under launchd) ─
# These check that a build marker is present in the gc/gt binary (gc: IsTransientDoltError,
# gt: BuiltProperly) via `strings`. Under launchd's LOW run priority `strings` on the big
# Go binary TIMES OUT → the marker reads "absent" when it is present → a false "binary
# provenance" alert that spams ntfy. Confirmed 2026-06-24: gc HAS IsTransientDoltError(×1),
# gt HAS BuiltProperly(×2) — both PASS a manual strings|grep; the alerts were ALL false.
# The deploy-time Makefile gate (gt rebuild requires BuiltProperly) already blocks a real
# reverted build, so this runtime check is redundant + unreliable → DEFAULTED OFF.
# Re-enable per-host with DPW_CHECK_G{C,T}_PROVENANCE=1 ONLY after a launchd-safe check is
# wired (e.g. nice'd strings with a long timeout, nm, or a precomputed checksum).
DPW_CHECK_GC_PROVENANCE="${DPW_CHECK_GC_PROVENANCE:-0}"
DPW_GC_PROVENANCE_MARKER="${DPW_GC_PROVENANCE_MARKER:-IsTransientDoltError}"
DPW_CHECK_GT_PROVENANCE="${DPW_CHECK_GT_PROVENANCE:-0}"
DPW_GT_PROVENANCE_MARKER="${DPW_GT_PROVENANCE_MARKER:-BuiltProperly}"

# ── imp17: crash-loop auto-heal tier ─────────────────────────────────────────
# On a crash-loop (2 consecutive nonzero exits), automatically attempt a targeted
# kickstart -k before paging a human. DPW_CRASHLOOP_HEAL_MAX attempts are made;
# if the daemon is still crash-looping after the budget is exhausted (or if
# kickstart itself fails), escalate to Mayor. DPW_CRASHLOOP_AUTOHEAL=0 reverts
# to legacy alert-only behaviour (no auto-restart, for testing/audit).
DPW_CRASHLOOP_AUTOHEAL="${DPW_CRASHLOOP_AUTOHEAL:-1}"   # 1=on, 0=alert-only
DPW_CRASHLOOP_HEAL_MAX="${DPW_CRASHLOOP_HEAL_MAX:-2}"   # max kickstart attempts before escalation

# A label is loaded iff `launchctl list <label>` succeeds.
_loaded()    { launchctl list "$1" >/dev/null 2>&1; }
# The last-exit-status column (2nd field) for a loaded label; empty if not listed.
_last_exit() { launchctl list 2>/dev/null | awk -v l="$1" '$3==l {print $2}'; }
# Previous exit recorded for a label (from the state file); empty if none.
_prev_exit() { awk -v l="$1" '$1==l {print $2}' "$STATE" 2>/dev/null; }
# ga-g92h: classify a launchctl exit code. 137 is SIGKILL (128+9) -- the exact
# code the kernel's OOM killer delivers, and on this host launchctl reports it
# as a POSITIVE 137, not the negative/signal form the crash-loop comment below
# assumes. A killed VICTIM (memory pressure -- needs capacity attention) and a
# genuine code FAILURE (exit=1 -- needs a code fix) were landing in the
# identical "exiting non-zero" bucket, indistinguishable to whoever reads the
# alert. This does not change any threshold/kickstart-heal DECISION -- a
# killed daemon needs restarting exactly like a crash-looping one -- it only
# changes which message a caller emits.
_exit_class() { [ "$1" = "137" ] && echo "oom-killed" || echo "failing"; }
# Seconds since <file> was last modified ("$2"=now epoch); empty if missing / stat fails.
_log_age()   { local f="$1" now="$2" m; [ -f "$f" ] || return 0; m=$(stat -f %m "$f" 2>/dev/null) && echo $(( now - m )); }

# Seconds the machine has actually been awake-and-up since it last became available,
# i.e. now − max(boot_epoch, wake_epoch). Used to suppress heartbeat-WEDGE false
# positives after a system sleep: while asleep, launchd suspends every StartInterval
# timer, so ALL daemon heartbeats go stale through no fault of the daemon.
#   • kern.boottime — on Apple Silicon this SHIFTS FORWARD across sleep (boottime is
#     derived as now − monotonic_uptime, and uptime freezes while asleep), so a recent
#     boottime captures BOTH a real reboot AND a wake-from-sleep.
#   • kern.waketime — populated on Intel-style sleep where boottime stays put; reads
#     "{ sec = 0 }" when unpopulated (Apple Silicon), which we ignore.
# Taking the MAX epoch (=min age) is the conservative "most recently available" moment.
# Echoes the age in seconds, or nothing if neither sysctl parses (caller fails safe).
_secs_since_avail() {
  local now="$1" bt wt latest=0
  # NB: the regex anchors a LEADING SPACE before "sec" (".* sec = ") so it captures
  # the `sec` field and NOT the `usec` field — ", usec = 355743" contains the literal
  # "sec = 355743", which an unanchored ".*sec = " would greedily match instead.
  bt="$(sysctl -n kern.boottime  2>/dev/null | sed -nE 's/.* sec = ([0-9]+).*/\1/p')"
  wt="$(sysctl -n kern.waketime  2>/dev/null | sed -nE 's/.* sec = ([0-9]+).*/\1/p')"
  [ -n "$bt" ] && [ "$bt" -gt "$latest" ] 2>/dev/null && latest="$bt"
  [ -n "$wt" ] && [ "$wt" -gt "$latest" ] 2>/dev/null && latest="$wt"
  [ "$latest" -gt 0 ] 2>/dev/null && echo $(( now - latest ))
}

# ── ga-2vf9b: in-flight gate-run guard (quality-gate-dispatcher-SPECIFIC) ────
# Defense-in-depth on top of the log()-driven heartbeat fix (quality-gate-
# dispatcher.sh, same bead): before kickstarting a WEDGED
# com.gascity.quality-gate-dispatcher, check whether a real gate-run is in
# flight. Phase B (ga-eqjo) intentionally leaves the dispatcher PROCESS
# exited between sweeps while a spawned reviewer works independently — the
# heartbeat can legitimately go stale during that gap even though nothing is
# wrong. Reuses the EXACT label pair Phase C itself uses to find its own
# in-flight runs (bd-list-cached.sh -l type:quality-gate-run -l
# gate-status:running), so this is the same source of truth, not a new
# heuristic.
#
# COUPLING WARNING (mirrors the identical note in quality-gate-dispatcher.sh):
# this suppression is defense-in-depth ON TOP OF that script's log()-driven
# heartbeat refresh, not a substitute for it. If THIS suppression is ever
# reverted while that refresh stays, nothing changes (the heartbeat already
# doesn't go stale during a genuinely active sweep). But if THAT refresh is
# reverted while THIS suppression stays, DPW's effective wedge-detection
# window for a genuinely hung dispatcher silently stretches from 600s to
# however long a gate-run bead's own verdict-timeout+margin window happens to
# be (commonly tens of minutes) — WORSE than the pre-fix baseline. The two
# fixes must be reverted together, never just the dispatcher-side one alone.
#
# Deliberately scoped to ONE label, not a generic mechanism for every
# wedge-checked daemon — this is bug-specific business logic, not an infra
# primitive; adding it here would be scope creep the other daemons never
# asked for.
#
# The freshness ceiling matters: a gate-run stuck at gate-status:running past
# its own timeout means something is ALREADY wrong (a dead reviewer, or a
# dispatcher that is genuinely dead and will never run Phase C again to notice)
# — in that case DPW must NOT suppress, because kickstarting the dispatcher is
# exactly what lets a fresh sweep's Phase C finally finalize the stale run.
# Suppressing on bead-existence alone, with no age bound, would convert "kills
# too eagerly" into "never recovers from a real hang".
#
# ga-2vf9b (adversarial review tweak): the ceiling is NOT a flat literal —
# an earlier version hardcoded 3600s as "comfortably above
# VERDICT_TIMEOUT_MAX_MINUTES=50m", but that constant lives in a DIFFERENT
# script/process with no shared runtime state, is itself env-overridable with
# no cap, and per-diff SCALING already produces a run-specific value (see
# gate_scaled_verdict_timeout in quality-gate-dispatcher.sh). A second,
# independently-edited copy of "the verdict-timeout window" is exactly the
# failure class this codebase has already been burned by once (multiple
# independent deadlines on one run; tightest wins wrongly, silently, until
# someone bumps one constant and forgets its sibling). quality-gate-guard.sh
# avoids this correctly (GATE_ZOMBIE_AGE_MINUTES = its verdict-timeout var +
# GATE_DEAD_REVIEWER_MARGIN_MINUTES, not a bare number) — this check follows
# the SAME pattern, but reads the run's OWN persisted `verdict_timeout_minutes`
# field (written into the gate-run bead's description by the dispatcher at
# spawn time — the exact field Phase C's own `extract "verdict_timeout_minutes"`
# already reads for this identical question) instead of a global constant, so
# it is correct per-run regardless of future scaling/ceiling changes in the
# dispatcher. Falls back to DPW_GATE_RUN_DEFAULT_TIMEOUT_MIN (mirrors the
# dispatcher's own VERDICT_TIMEOUT_MAX_MINUTES default) if the field is
# missing/unparseable — never a bare "3600" anywhere in this logic.
#
# Fail-safe in BOTH directions of the "what could go wrong" question: any
# error (bd/jq missing, Dolt unreachable, malformed JSON, timeout) makes this
# return 1 (not in flight) — the caller then falls through to the PRE-EXISTING
# kill behavior. A broken check must never leave a genuinely wedged daemon
# un-killed forever; it may only ADD a suppression on POSITIVE, VERIFIED
# evidence.
DPW_GATE_RUN_DEFAULT_TIMEOUT_MIN="${DPW_GATE_RUN_DEFAULT_TIMEOUT_MIN:-50}"  # mirrors dispatcher's VERDICT_TIMEOUT_MAX_MINUTES default
DPW_GATE_RUN_MARGIN_MIN="${DPW_GATE_RUN_MARGIN_MIN:-10}"                    # mirrors guard's GATE_DEAD_REVIEWER_MARGIN_MINUTES default
_gate_run_in_flight() {
  local now="$1" out
  # Selftest seam: DPW_TEST_GATE_INFLIGHT="1"/"0" bypasses bd/jq/Dolt entirely,
  # exactly like DPW_TEST_AVAIL_AGE bypasses the real sysctl call above — lets
  # the WEDGE-block scenarios test the WIRING (does the elif fire, does it log
  # correctly, is it scoped to the right label) without a live Dolt round-trip.
  # The jq/date MATH itself is unit-tested separately by calling this function
  # directly with a stubbed bd-list-cached.sh (Scenarios 7j–7o).
  if [ -n "${DPW_TEST_GATE_INFLIGHT+x}" ]; then
    [ "$DPW_TEST_GATE_INFLIGHT" = "1" ]
    return
  fi
  command -v bd >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$HQ/scripts/bd-list-cached.sh" ] || return 1
  out=$(timeout 8 bash "$HQ/scripts/bd-list-cached.sh" -C "$HQ" list --json \
          -l type:quality-gate-run -l gate-status:running 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  # Per-bead: created_at + (its OWN verdict_timeout_minutes, or the default,
  # plus the dead-reviewer margin) > now  ⇒  still legitimately in its window.
  printf '%s' "$out" | jq -e \
    --argjson now "$now" \
    --argjson marginmin "$DPW_GATE_RUN_MARGIN_MIN" \
    --argjson defaultmin "$DPW_GATE_RUN_DEFAULT_TIMEOUT_MIN" \
    'any(.[]?;
      (((.created_at // "") | fromdateiso8601?) // 0) as $created
      | ($created > 0) and
        ((((.description // "") | capture("(?m)^verdict_timeout_minutes: *(?<m>[0-9]+)"; "").m) // ($defaultmin | tostring) | tonumber) as $vtm
          | ($now - $created) < (($vtm + $marginmin) * 60))
    )' >/dev/null 2>&1
}

# ── imp05: count consecutive nonzero exits for a label ───────────────────────
# State files for consecutive-exit tracking live in STATE.fail-counts/; format "COUNT".
_fail_count_file() { echo "${STATE}.fail-counts/$1"; }
_fail_count_get()  { local f; f="$(_fail_count_file "$1")"; [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0; }
_fail_count_set()  { local f; f="$(_fail_count_file "$1")"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "$2" > "$f" 2>/dev/null || true; }
_fail_count_reset(){ local f; f="$(_fail_count_file "$1")"; rm -f "$f" 2>/dev/null || true; }

# ── imp17: crash-loop heal-attempt tracking ────────────────────────────────────
# Per-daemon heal-attempt counter living in ${STATE}.crashloop-heals/<label>.
# Content: single integer (attempt count). Resets on clean exit or daemon absence.
_cl_heal_file()  { echo "${STATE}.crashloop-heals/$1"; }
_cl_heal_get()   { local f; f="$(_cl_heal_file "$1")"; [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0; }
_cl_heal_set()   { local f; f="$(_cl_heal_file "$1")"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "$2" > "$f" 2>/dev/null || true; }
_cl_heal_reset() { rm -f "$(_cl_heal_file "$1")" 2>/dev/null || true; }

# ── imp05: ProgramArguments path extraction ───────────────────────────────────
# Parse the ProgramArguments from a launchd plist (XML). Returns the first
# non-interpreter path (skipping /bin/bash, /usr/bin/env, etc.).
# Uses only awk — no external deps. Handles both compact (<key>ProgramArguments</key><array>
# on the same line as the key) and expanded plist formats.
_plist_program_path() {
  local plist="$1"
  [ -f "$plist" ] || return 1
  awk '
    /<key>ProgramArguments<\/key>/,/<\/array>/ {
      if (/<string>/) {
        gsub(/.*<string>/, ""); gsub(/<\/string>.*/, "")
        # Skip common shell interpreters
        if ($0 !~ /^(\/bin\/bash|\/bin\/sh|\/usr\/bin\/env|\/bin\/zsh)$/ && $0 != "") {
          print; exit
        }
      }
    }
  ' "$plist" 2>/dev/null
}

# ── imp05: binary-provenance check ───────────────────────────────────────────
# Returns 0 if the marker is found, 1 if not, 2 if the binary is missing/unreadable (skip).
_binary_has_marker() {
  local bin="$1" marker="$2" resolved
  # Resolve symlink if possible
  resolved="$(readlink -f "$bin" 2>/dev/null)" || resolved="$bin"
  [ -f "$resolved" ] || return 2
  strings "$resolved" 2>/dev/null | grep -qF "$marker" && return 0 || return 1
}

# ── imp05: ledger append (wired by imp02/imp04 once gc_ledger_append lands) ──
_ledger_touch() {
  # imp02 wires the ledger — this call is a no-op until gc_ledger_append is on PATH.
  command -v gc_ledger_append >/dev/null 2>&1 && gc_ledger_append "dpw" "$*" 2>/dev/null || true
}

# ── ga-95bi4: generic mail cooldown — gates `gc mail send` ONLY ──────────────
# Measured incident: one persisting condition re-mailed the SAME subject every
# 5-min sweep for hours (194x "critical daemon absent/crash-looping..." alone),
# making mail wisps (issue_type=message, never archived) the single hottest
# hq.wisps query working-set and a real Dolt CPU contributor. Generalizes the
# per-label cooldown ga-4l2sn already proved out for PRESENCE-DRIFT (see
# _pd_last_get/_pd_last_set below) into a reusable keyed cooldown so callers
# added later don't reinvent the state-file bookkeeping.
# Deliberately gates mail ONLY — ntfy (no Dolt cost, Athos still wants the
# phone buzz) and the log (always full detail) stay unthrottled every sweep.
DPW_ALERT_WINDOW_SEC="${DPW_ALERT_WINDOW_SEC:-14400}"
_alert_cd_file() { echo "${STATE}.alert-cooldown/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
# _alert_cd_ok: READ-ONLY check — is this key currently OUT of cooldown?
# Does NOT write state. Callers must call _alert_cd_mark separately, and only
# after confirming the mail send it gates actually succeeded (gate feedback on
# ga-95bi4 attempt 1: marking unconditionally here made a FAILED/absent `gc
# mail send` indistinguishable from a delivered one, silently blacking out the
# mayor-facing mail channel for up to DPW_ALERT_WINDOW_SEC on the first failed
# attempt for a new failure shape).
_alert_cd_ok() {
  local key="$1" now="$2" f last
  f="$(_alert_cd_file "$key")"
  last="$([ -f "$f" ] && cat "$f" 2>/dev/null || echo 0)"
  if [ -n "$last" ] && [ "$last" -gt 0 ] 2>/dev/null && [ $(( now - last )) -lt "$DPW_ALERT_WINDOW_SEC" ] 2>/dev/null; then
    return 1
  fi
  return 0
}
# _alert_cd_mark: record that a send for <key> was CONFIRMED successful.
_alert_cd_mark() {
  local key="$1" now="$2" f
  f="$(_alert_cd_file "$key")"
  mkdir -p "$(dirname "$f")" 2>/dev/null || true
  printf '%s\n' "$now" > "$f" 2>/dev/null || true
}

# ── imp05: alert helper (ntfy primary, gc mail secondary, ledger best-effort) ─
# 3rd arg (optional, any non-empty value): skip the cooldown gate below —
# for a caller (presence-drift) that already deduped more precisely upstream
# (per-label, not per-subject); double-gating on top of that would let this
# coarser subject-level window mask a DIFFERENT label's already-warranted
# alert just because some other label used the same subject recently.
# _alert return code: 0 = mail sent (or correctly suppressed by cooldown),
# 1 = a send was attempted and failed (or gc was unavailable). Callers that
# keep their OWN send-independent state (e.g. run_presence_drift_sweep's
# per-label _pd_last_set) key off this to defer marking until delivery is
# confirmed, same reasoning as _alert_cd_mark above.
_alert() {
  local subject="$1" msg="$2" skip_cd="${3:-}" now rc=0
  now="$(date +%s)"
  log "ALERT $subject — $msg"
  command -v notify >/dev/null 2>&1 && notify -t "Daemon watchdog: $subject" -p 4 "$msg" 2>/dev/null || true
  if [ -n "$skip_cd" ] || _alert_cd_ok "$subject" "$now"; then
    if command -v gc >/dev/null 2>&1 && gc mail send mayor -s "Daemon-presence: $subject" -m "$msg" 2>/dev/null; then
      [ -n "$skip_cd" ] || _alert_cd_mark "$subject" "$now"
    else
      log "ALERT (mail send failed or gc unavailable — cooldown NOT marked, will retry next sweep): $subject"
      rc=1
    fi
  else
    log "ALERT-SUPPRESSED (mail, within ${DPW_ALERT_WINDOW_SEC}s cooldown): $subject"
  fi
  _ledger_touch "$subject" "$msg"
  return $rc
}

# _rss_mb <label> — return current RSS in MiB for the process running under <label>.
# Uses launchctl list to get the PID, then ps -o rss= to read RSS in KiB.
# Prints nothing and returns 1 on any failure (not loaded, no PID, ps error).
_rss_mb() {
  local lbl="$1" pid rss_kb
  # `launchctl list <label>` prints JSON; the PID is in "PID" field.
  # A dash ("-") in the PID column means not running.
  pid=$(launchctl list "$lbl" 2>/dev/null | awk -F'"' '/"PID"/{print $4}')
  [ -z "$pid" ] || [ "$pid" = "-" ] && return 1
  rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$rss_kb" ] && return 1
  echo $(( rss_kb / 1024 ))
}

# _recycle_count_increment <label> <now_epoch> — bump the per-daemon counter for the
# current rolling hour. Returns the new count. State file format: "HOUR_START COUNT".
_recycle_count_increment() {
  local lbl="$1" now="$2" sf hour_start count
  sf="$RECYCLE_STATE_DIR/$lbl"
  mkdir -p "$RECYCLE_STATE_DIR" 2>/dev/null || true
  # Round down to the start of the current hour
  hour_start=$(( now - (now % 3600) ))
  if [ -f "$sf" ]; then
    local prev_start prev_count
    read -r prev_start prev_count < "$sf" 2>/dev/null || { prev_start=0; prev_count=0; }
    if [ "$prev_start" -eq "$hour_start" ] 2>/dev/null; then
      count=$(( prev_count + 1 ))
    else
      count=1   # new hour — reset
    fi
  else
    count=1
  fi
  printf '%s %s\n' "$hour_start" "$count" > "$sf" 2>/dev/null || true
  echo "$count"
}

# _recycle_count_current <label> <now_epoch> — return count within the current hour (0 if none).
_recycle_count_current() {
  local lbl="$1" now="$2" sf hour_start
  sf="$RECYCLE_STATE_DIR/$lbl"
  hour_start=$(( now - (now % 3600) ))
  [ -f "$sf" ] || { echo 0; return; }
  local prev_start prev_count
  read -r prev_start prev_count < "$sf" 2>/dev/null || { echo 0; return; }
  if [ "$prev_start" -eq "$hour_start" ] 2>/dev/null; then
    echo "$prev_count"
  else
    echo 0
  fi
}

run_recycle_sweep() {
  [ "${RECYCLE_ENABLED:-1}" = "1" ] || return 0
  local now lbl rss_mb count
  now="$(date +%s)"

  for lbl in $RECYCLE_DAEMONS; do
    # Fail-safe wrapper: any error in this block is logged and we move on.
    {
      # 1. Must be loaded — skip silently if not (it may be intentionally stopped).
      if ! launchctl list "$lbl" >/dev/null 2>&1; then
        continue
      fi

      # 2. Read RSS; skip if we can't determine it.
      rss_mb=$(_rss_mb "$lbl" 2>/dev/null) || { log "RECYCLE skip $lbl: could not read RSS"; continue; }

      # 3. Check against threshold.
      if [ "$rss_mb" -le "${RECYCLE_RSS_MB:-350}" ] 2>/dev/null; then
        log "RECYCLE ok $lbl RSS=${rss_mb}MB (threshold=${RECYCLE_RSS_MB:-350}MB)"
        continue
      fi

      log "RECYCLE trigger $lbl RSS=${rss_mb}MB > threshold=${RECYCLE_RSS_MB:-350}MB"

      # 4. Dry-run gate.
      if [ "${RECYCLE_DRY_RUN:-0}" = "1" ]; then
        log "RECYCLE dry-run: would kickstart $lbl (RSS=${rss_mb}MB)"
        notify -t "Recycler dry-run" "Would recycle $lbl RSS=${rss_mb}MB" 2>/dev/null || true
        continue
      fi

      # 5. Actually recycle: kickstart -k stops-and-restarts the process.
      if launchctl kickstart -k "gui/$UID_NUM/$lbl" 2>/dev/null; then
        log "RECYCLED $lbl (RSS was ${rss_mb}MB)"
        notify -t "Daemon recycled" "$lbl RSS=${rss_mb}MB exceeded ${RECYCLE_RSS_MB:-350}MB — recycled" 2>/dev/null || true
      else
        log "RECYCLE kickstart FAILED for $lbl (RSS=${rss_mb}MB)"
        notify -t "Recycler error" "kickstart -k $lbl failed" 2>/dev/null || true
        continue
      fi

      # 6. Chronic-leak detection: bump counter, escalate if over threshold.
      count=$(_recycle_count_increment "$lbl" "$now")
      if [ "$count" -gt "${RECYCLE_CHRONIC_PER_HR:-3}" ] 2>/dev/null; then
        local msg="CHRONIC LEAK: $lbl recycled ${count}x this hour (threshold=${RECYCLE_CHRONIC_PER_HR:-3}/hr) — needs a code fix"
        log "ALERT $msg"
        notify -t "Chronic leak" "$msg" 2>/dev/null || true
        command -v gc >/dev/null 2>&1 && gc mail send mayor \
          -s "Recycler: chronic leak $lbl" \
          -m "$msg (RSS was ${rss_mb}MB)" 2>/dev/null || true
      fi
    } || log "RECYCLE unexpected error for $lbl — skipped (fail-safe)"
  done
  return 0   # recycler never fails the watchdog
}

# ── ga-u04vp: PRESENCE-DRIFT — catches "plist authored, never deployed" ──────
# See the header comment (top of file) for the full rationale. This needs no
# curated list: it scans the canonical "meant to be deployed" source locations
# (non-recursive — deliberately skips .gc-worktrees/ and .gc/agents/*/, which are
# per-session working copies, not deployment intent) for any com.gascity.*/
# com.gastown.* plist Label, and flags one that is not currently loaded. A label
# already in DPW_CRITICAL is skipped here — the main loop above already alerts on
# that one (and, unlike this sweep, will also attempt an auto-bootstrap).
DPW_PRESENCE_DRIFT_ENABLED="${DPW_PRESENCE_DRIFT_ENABLED:-1}"
DPW_PRESENCE_DIRS="${DPW_PRESENCE_DIRS:-$HQ/packs/town-deltas/assets $HQ/scripts}"

# Extract a plist's <key>Label</key> string value. Handles both the compact
# same-line style (<key>Label</key><string>X</string>, used by most repo-authored
# plists) and the expanded multi-line style a canonicalized (plutil/launchctl-
# rewritten) plist uses — `want` persists across lines so either shape resolves.
_plist_label() {
  awk '
    /<key>Label<\/key>/ { want=1 }
    want && /<string>/ {
      line=$0
      sub(/.*<string>/, "", line); sub(/<\/string>.*/, "", line)
      if (line != "") { print line; exit }
    }
  ' "$1" 2>/dev/null
}

# ── ga-4l2sn: PRESENCE-DRIFT cooldown/dedup ──────────────────────────────────
# Without this, every 5-min sweep re-alerted the SAME undeployed label with no
# memory of the last one — ga-4l2sn measured 10+ identical Mayor mails for one
# daemon in a single morning. Mirrors the agent-stuck-escalation.sh cooldown:
# one state file per label under ${STATE}.presence-drift/<label>, content = the
# epoch of the last alert; a label still undeployed inside the window is logged
# but not re-mailed. State clears the moment a label loads again, so a LATER
# drift on the same label alerts fresh instead of inheriting a stale cooldown
# from an unrelated earlier incident.
DPW_PRESENCE_DRIFT_COOLDOWN_SEC="${DPW_PRESENCE_DRIFT_COOLDOWN_SEC:-10800}"
_pd_state_file() { echo "${STATE}.presence-drift/$1"; }
_pd_last_get()   { local f; f="$(_pd_state_file "$1")"; [ -f "$f" ] && cat "$f" 2>/dev/null || echo 0; }
_pd_last_set()   { local f; f="$(_pd_state_file "$1")"; mkdir -p "$(dirname "$f")" 2>/dev/null || true; printf '%s\n' "$2" > "$f" 2>/dev/null || true; }
_pd_last_clear() { rm -f "$(_pd_state_file "$1")" 2>/dev/null || true; }

run_presence_drift_sweep() {
  [ "${DPW_PRESENCE_DRIFT_ENABLED:-1}" = "1" ] || return 0
  local dir f label undeployed="" alerted="" to_mark="" now last since remaining
  now="${DPW_TEST_NOW:-$(date +%s)}"
  for dir in $DPW_PRESENCE_DIRS; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.plist; do
      [ -f "$f" ] || continue
      label="$(_plist_label "$f")"
      case "$label" in
        com.gascity.*|com.gastown.*) ;;
        *) continue ;;
      esac
      case " $DPW_CRITICAL " in *" $label "*) continue ;; esac
      if _loaded "$label"; then
        _pd_last_clear "$label"
        continue
      fi
      undeployed="$undeployed $label"
      last="$(_pd_last_get "$label")"
      since=$(( now - last ))
      if [ "$since" -lt "$DPW_PRESENCE_DRIFT_COOLDOWN_SEC" ] 2>/dev/null; then
        remaining=$(( (DPW_PRESENCE_DRIFT_COOLDOWN_SEC - since) / 60 ))
        log "PRESENCE-DRIFT $label: already alerted ${since}s ago (cooldown ${remaining}min remaining, src=$dir)"
      else
        alerted="$alerted $label(src:$dir)"
        to_mark="$to_mark $label"
      fi
    done
  done
  if [ -n "$alerted" ]; then
    local msg="Daemon-presence watchdog: PRESENCE-DRIFT —${alerted} (each shown with its SOURCE directory — versioned source under scripts/ or packs/town-deltas/assets/, NOT the deployed ~/Library/LaunchAgents copy — found there but NOT loaded in launchd: never bootstrapped, or fell out silently — ga-u04vp)."
    log "ALERT $msg"
    # skip_cd=1: this label already passed its OWN per-label cooldown check
    # above (DPW_PRESENCE_DRIFT_COOLDOWN_SEC, ga-4l2sn) — the generic per-
    # subject cooldown in _alert would otherwise mask a DIFFERENT label's
    # already-warranted alert (ga-95bi4).
    # _pd_last_set is deferred until here — and only on a CONFIRMED send —
    # instead of inside the loop above: marking eagerly had the same
    # regression the gate caught in _alert_cd_ok (ga-95bi4 gate feedback,
    # fix round 2): a failed/absent gc would have recorded every drifted
    # label as "alerted" for DPW_PRESENCE_DRIFT_COOLDOWN_SEC (3h) despite no
    # mail ever going out.
    if _alert "presence-drift (undeployed plist)" "$msg" 1; then
      local _pd_label
      for _pd_label in $to_mark; do
        _pd_last_set "$_pd_label" "$now"
      done
    else
      log "PRESENCE-DRIFT: send failed — per-label cooldowns NOT marked for:$to_mark (will retry next sweep)"
    fi
  fi
  if [ -n "$undeployed" ]; then
    return 1
  fi
  log "OK: presence-drift sweep — every com.gascity.*/com.gastown.* plist in $DPW_PRESENCE_DIRS is loaded"
  return 0
}

run_sweep() {
  local absent="" reloaded="" crashloop="" failing="" oom_killed="" wedged="" path_missing="" healthy=0 newstate="" lbl plist ex prev _hb _hblog _hbmax _age fc prog heal_n healing_inflight=""
  local NOW; NOW="$(date +%s)"
  # How long the machine has been awake-and-up (for WEDGE sleep/boot suppression).
  # DPW_TEST_AVAIL_AGE lets the selftest inject a value without calling sysctl.
  local _AVAIL_AGE; _AVAIL_AGE="${DPW_TEST_AVAIL_AGE:-$(_secs_since_avail "$NOW")}"
  for lbl in $DPW_CRITICAL; do
    plist="$LAUNCH_DIR/$lbl.plist"

    # ── imp05 check 2: ProgramArguments PATH-EXISTS ───────────────────────────
    # Even before checking loaded state, verify the script the plist points to exists.
    # A rebuild or stale patch can silently leave a plist pointing at a missing file.
    if [ -f "$plist" ]; then
      prog="$(_plist_program_path "$plist" 2>/dev/null)" || prog=""
      if [ -n "$prog" ] && [ ! -f "$prog" ]; then
        path_missing="$path_missing $lbl(missing:$prog)"
        log "PATH-MISSING: $lbl ProgramArguments script not on disk: $prog"
      fi
    fi

    if _loaded "$lbl"; then
      ex="$(_last_exit "$lbl")"; ex="${ex:-0}"
      prev="$(_prev_exit "$lbl")"
      # CRASH-LOOP = a POSITIVE exit (a real error, not a negative=signal restart) seen
      # on TWO consecutive checks. One transient nonzero exit never alerts.
      if [ "$ex" -gt 0 ] 2>/dev/null && [ -n "$prev" ] && [ "$prev" -gt 0 ] 2>/dev/null; then
        # imp17: attempt auto-heal before paging a human
        if [ "${DPW_CRASHLOOP_AUTOHEAL:-1}" = "1" ]; then
          heal_n=$(( $(_cl_heal_get "$lbl") + 1 ))
          _cl_heal_set "$lbl" "$heal_n"
          if [ "$heal_n" -le "${DPW_CRASHLOOP_HEAL_MAX:-2}" ]; then
            log "CRASH-LOOP-AUTOHEAL: $lbl (exit=$ex) attempt $heal_n/${DPW_CRASHLOOP_HEAL_MAX:-2} — kickstart -k"
            if launchctl kickstart -k "gui/$UID_NUM/$lbl" 2>/dev/null; then
              log "CRASH-LOOP-AUTOHEAL: kickstart -k succeeded for $lbl (attempt $heal_n)"
              healing_inflight="$healing_inflight $lbl"
              command -v notify >/dev/null 2>&1 && notify -t "Daemon auto-heal" -p 3 \
                "Crash-loop auto-healed: $lbl attempt $heal_n/${DPW_CRASHLOOP_HEAL_MAX:-2}" 2>/dev/null || true
            else
              log "CRASH-LOOP-AUTOHEAL: kickstart -k FAILED for $lbl (attempt $heal_n) — escalating"
              crashloop="$crashloop $lbl(exit=$ex,heal-kickstart-failed:$heal_n)"
            fi
          else
            log "CRASH-LOOP-AUTOHEAL: $lbl heal budget exhausted ($heal_n/${DPW_CRASHLOOP_HEAL_MAX:-2}) — escalating to human"
            crashloop="$crashloop $lbl(exit=$ex,heals-exhausted:$heal_n)"
          fi
        else
          crashloop="$crashloop $lbl(exit=$ex)"
        fi
      else
        healthy=$((healthy + 1))
      fi

      # ── imp05 check 1: EXIT-CODE consecutive-failure tracking ─────────────
      # Independently from crash-loop (which uses the STATE file), track consecutive
      # nonzero exits in per-label fail-count files. This lets us raise a FAILING alert
      # even when the prev/cur approach in crash-loop might miss it (e.g. state file
      # cleared between checks). DPW_FAIL_THRESHOLD consecutive sweeps with exit>0.
      #
      # ga-nvef: imp05 and imp17 both key off "2 consecutive nonzero exits" by default,
      # so a daemon's first-ever crash-loop crosses BOTH thresholds on the same sweep.
      # imp05 keeps counting/logging unconditionally — it exists specifically to catch
      # failures imp17's prev/cur STATE mechanism might miss — but does NOT add the
      # label to $failing (and so does not trigger this sweep's mail-to-Mayor) when
      # THIS sweep's kickstart was a within-budget imp17 heal attempt for the SAME
      # label: imp17's own design is to heal silently first and escalate only once its
      # heal budget is exhausted (see heal-kickstart-failed / heals-exhausted below,
      # which add to $crashloop directly and so are never affected by this).
      if [ "$ex" -gt 0 ] 2>/dev/null; then
        fc=$(( $(_fail_count_get "$lbl") + 1 ))
        _fail_count_set "$lbl" "$fc"
        if [ "$fc" -ge "${DPW_FAIL_THRESHOLD:-2}" ]; then
          case " $healing_inflight " in
            *" $lbl "*)
              log "FAILING: $lbl exiting non-zero (exit=$ex) for $fc consecutive sweeps (mail suppressed: imp17 auto-heal in-budget attempt $heal_n)" ;;
            *)
              if [ "$(_exit_class "$ex")" = "oom-killed" ]; then
                oom_killed="$oom_killed $lbl(exit=$ex,sweeps=$fc)"
                log "OOM-KILLED: $lbl killed by kernel (SIGKILL, exit=$ex) for $fc consecutive sweeps — memory pressure, not a code failure (ga-g92h)"
              else
                failing="$failing $lbl(exit=$ex,sweeps=$fc)"
                log "FAILING: $lbl exiting non-zero (exit=$ex) for $fc consecutive sweeps"
              fi
              ;;
          esac
        fi
      else
        _fail_count_reset "$lbl"
        _cl_heal_reset "$lbl"   # imp17: daemon recovered — reset heal counter
      fi

      # WEDGE: loaded but its per-cycle heartbeat log went stale past threshold = stuck.
      _hb="$(printf '%s\n' "$DPW_HEARTBEAT" | awk -F'|' -v l="$lbl" '$1==l{print $2"\t"$3; exit}')"
      if [ -n "$_hb" ]; then
        _hblog="${_hb%%$'\t'*}"; _hbmax="${_hb##*$'\t'}"
        _age="$(_log_age "$_hblog" "$NOW")"
        if [ -n "$_age" ] && [ "$_age" -gt "$_hbmax" ] 2>/dev/null; then
          # Sleep/boot-aware suppression: during system sleep launchd suspends every
          # StartInterval timer, so this heartbeat is stale through no fault of the
          # daemon. If the machine has been awake-and-up for LESS than this daemon's
          # own stale threshold, the staleness cannot yet prove a hang (the daemon
          # could not have run before the machine woke). Grant a grace pass — it will
          # self-heal on its next coalesced launch. A daemon that is GENUINELY wedged
          # post-wake is re-flagged a cycle later, once avail-age exceeds the threshold.
          if [ "${DPW_WAKE_GRACE:-1}" = "1" ] && [ -n "$_AVAIL_AGE" ] && [ "$_AVAIL_AGE" -lt "$_hbmax" ] 2>/dev/null; then
            log "WEDGE-SUPPRESSED (recent wake/boot): $lbl heartbeat stale ${_age}s but system only up ${_AVAIL_AGE}s (< ${_hbmax}s) — expected post-sleep, self-heals on next launch"
          elif [ "$lbl" = "com.gascity.quality-gate-dispatcher" ] && [ "${DPW_GATE_INFLIGHT_GUARD:-1}" = "1" ] && _gate_run_in_flight "$NOW"; then
            # ga-2vf9b: a quality-gate-run bead is gate-status:running and still
            # within ITS OWN persisted verdict_timeout_minutes + margin (not a
            # flat ceiling — see _gate_run_in_flight's own docs). Phase B
            # legitimately leaves the dispatcher process exited between sweeps
            # while its spawned reviewer works independently. Heartbeat
            # staleness alone cannot prove a hang here; not killing, waiting
            # for a future sweep's Phase C to finalize naturally.
            log "WEDGE-SUPPRESSED (run in flight): $lbl heartbeat stale ${_age}s but a quality-gate-run bead is gate-status:running and still within its own verdict-timeout+margin window — Phase B (ga-eqjo) leaves the dispatcher process exited between sweeps by design; not killing, waiting for a future sweep's Phase C to finalize (ga-2vf9b, run in flight, waiting)"
          else
            wedged="$wedged $lbl(stale=${_age}s)"
            if [ "$DPW_RELOAD" = "1" ] && launchctl kickstart -k "gui/$UID_NUM/$lbl" 2>/dev/null; then
              log "KICKSTARTED wedged daemon: $lbl (heartbeat stale ${_age}s > ${_hbmax}s)"
            else
              log "WEDGED daemon NOT kickstarted: $lbl (stale ${_age}s, DPW_RELOAD=$DPW_RELOAD or kickstart failed)"
            fi
          fi
        fi
      fi
      newstate="$newstate$lbl $ex"$'\n'
    else
      newstate="$newstate$lbl absent"$'\n'
      _fail_count_reset "$lbl"   # reset on absence (will be loaded fresh)
      _cl_heal_reset "$lbl"      # imp17: will be reloaded fresh; reset heal counter
      if [ -f "$plist" ]; then
        absent="$absent $lbl"
        if [ "$DPW_RELOAD" = "1" ] && launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null; then
          reloaded="$reloaded $lbl"
          log "RELOADED absent critical daemon: $lbl"
        else
          log "ABSENT critical daemon NOT reloaded: $lbl (DPW_RELOAD=$DPW_RELOAD or bootstrap failed)"
        fi
      else
        log "WARN critical daemon $lbl is absent AND has no plist on disk ($plist)"
      fi
    fi
  done

  printf '%s' "$newstate" > "$STATE" 2>/dev/null || true

  # ── imp05 check 3: binary-provenance ─────────────────────────────────────
  local provenance_alerts=""
  if [ "${DPW_CHECK_GC_PROVENANCE:-1}" = "1" ]; then
    local _gc_bin; _gc_bin="$(command -v gc 2>/dev/null)" || _gc_bin=""
    if [ -n "$_gc_bin" ]; then
      local _pv_rc=0
      _binary_has_marker "$_gc_bin" "${DPW_GC_PROVENANCE_MARKER:-IsTransientDoltError}" || _pv_rc=$?
      if [ "$_pv_rc" -eq 1 ]; then
        local _pv_msg="gc rebuild reverted Dolt-resilience (marker '${DPW_GC_PROVENANCE_MARKER:-IsTransientDoltError}' absent from binary)"
        provenance_alerts="$provenance_alerts gc-missing-marker"
        log "PROVENANCE-FAIL: $_pv_msg"
        _alert "gc binary provenance" "$_pv_msg"
      elif [ "$_pv_rc" -eq 2 ]; then
        log "PROVENANCE-SKIP: gc binary not readable by strings — skipping"
      fi
    else
      log "PROVENANCE-SKIP: gc not on PATH — skipping gc provenance check"
    fi
  fi
  if [ "${DPW_CHECK_GT_PROVENANCE:-1}" = "1" ]; then
    local _gt_bin; _gt_bin="$(command -v gt 2>/dev/null)" || _gt_bin=""
    if [ -n "$_gt_bin" ]; then
      local _gtpv_rc=0
      _binary_has_marker "$_gt_bin" "${DPW_GT_PROVENANCE_MARKER:-BuiltProperly}" || _gtpv_rc=$?
      if [ "$_gtpv_rc" -eq 1 ]; then
        local _gtpv_msg="gt binary was NOT built with Makefile (marker '${DPW_GT_PROVENANCE_MARKER:-BuiltProperly}' absent) — plain go build silently breaks runtime"
        provenance_alerts="$provenance_alerts gt-missing-marker"
        log "PROVENANCE-FAIL: $_gtpv_msg"
        _alert "gt binary provenance" "$_gtpv_msg"
      elif [ "$_gtpv_rc" -eq 2 ]; then
        log "PROVENANCE-SKIP: gt binary not readable by strings — skipping"
      fi
    else
      log "PROVENANCE-SKIP: gt not on PATH — skipping gt provenance check"
    fi
  fi

  if [ -n "$absent" ] || [ -n "$crashloop" ] || [ -n "$failing" ] || [ -n "$oom_killed" ] || [ -n "$wedged" ] || [ -n "$path_missing" ]; then
    local msg="Daemon-presence watchdog:"
    [ -n "$absent" ]      && msg="$msg ABSENT:${absent} (reloaded:${reloaded:- none})."
    [ -n "$crashloop" ]   && msg="$msg CRASH-LOOP:${crashloop} (auto-heal exhausted or disabled — needs Mayor/human)."
    [ -n "$failing" ]     && msg="$msg FAILING:${failing} (nonzero exit ≥${DPW_FAIL_THRESHOLD} consecutive sweeps — investigate)."
    [ -n "$oom_killed" ]  && msg="$msg OOM-KILLED:${oom_killed} (SIGKILL by kernel under memory pressure, ≥${DPW_FAIL_THRESHOLD} consecutive sweeps — a capacity/RAM issue, not a code bug; ga-g92h)."
    [ -n "$wedged" ]      && msg="$msg WEDGED:${wedged} (loaded but heartbeat stale — kickstarted)."
    [ -n "$path_missing" ] && msg="$msg PATH-MISSING:${path_missing} (ProgramArguments script absent from disk — daemon will fail on restart)."
    log "ALERT $msg"
    command -v notify >/dev/null 2>&1 && notify -t "Daemon watchdog" -p 4 "$msg" 2>/dev/null || true
    # ga-95bi4: this was the dominant offender (194 identical mails measured in
    # one incident) — subject text is a FIXED constant regardless of which
    # daemon(s) triggered it, so it mailed unconditionally every 5-min sweep
    # for as long as ANY condition persisted. Cooldown key = which of the 6
    # buckets are firing (not raw $msg — its embedded counters like
    # sweeps=N/stale=Ns change every round even for the exact same ongoing
    # incident, which would defeat a content-hash key and never suppress
    # anything). A genuinely new failure SHAPE (e.g. WEDGED escalating to also
    # CRASH-LOOP) re-mails immediately; the same shape persisting is throttled
    # to once per DPW_ALERT_WINDOW_SEC. ntfy + log stay unthrottled above.
    local _shape=""
    [ -n "$absent" ]       && _shape="${_shape}A"
    [ -n "$crashloop" ]    && _shape="${_shape}C"
    [ -n "$failing" ]      && _shape="${_shape}F"
    [ -n "$oom_killed" ]   && _shape="${_shape}O"
    [ -n "$wedged" ]       && _shape="${_shape}W"
    [ -n "$path_missing" ] && _shape="${_shape}P"
    if _alert_cd_ok "sweep-shape-$_shape" "$NOW"; then
      if command -v gc >/dev/null 2>&1 && gc mail send mayor -s "Daemon-presence: critical daemon absent/crash-looping/failing/wedged/path-missing" -m "$msg" 2>/dev/null; then
        _alert_cd_mark "sweep-shape-$_shape" "$NOW"
      else
        log "ALERT (mail send failed or gc unavailable — cooldown NOT marked, will retry next sweep): sweep-shape-$_shape"
      fi
    else
      log "ALERT-SUPPRESSED (mail, failure shape [$_shape] within ${DPW_ALERT_WINDOW_SEC}s cooldown)"
    fi
    _ledger_touch "sweep-alert" "$msg"
    return 1
  fi
  log "OK: all $(echo $DPW_CRITICAL | wc -w | tr -d ' ') critical daemons loaded + healthy (heartbeat)"
  return 0
}

# ── selftest (hermetic; no launchctl/notify side effects) ─────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${DPW_SELFTEST:-0}" = "1" ]; then
  # Capture the REAL default DPW_HEARTBEAT (set at module load, line ~49) before any
  # scenario below overwrites it with hermetic test values — ga-9wv5's coverage-gap
  # scenario asserts against this snapshot, not a scenario-local override.
  _REAL_DEFAULT_HEARTBEAT="$DPW_HEARTBEAT"
  _REAL_DEFAULT_CRITICAL="$DPW_CRITICAL"
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  # Stub launchctl/notify/gc so the sweep is hermetic. SCEN drives loaded/exit per label.
  cat > "$TMP/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    if [ -n "${2:-}" ]; then
      # `launchctl list <label>` → success iff label is in DPW_TEST_LOADED.
      case " $DPW_TEST_LOADED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac
    fi
    # table form: emit "PID EXIT LABEL" for loaded labels (exit from DPW_TEST_EXIT map).
    for l in $DPW_TEST_LOADED; do
      e=0; for kv in $DPW_TEST_EXIT; do case "$kv" in "$l:"*) e="${kv#*:}";; esac; done
      printf '%s\t%s\t%s\n' "-" "$e" "$l"
    done ;;
  bootstrap) echo "$2 $3" >> "$DPW_TEST_BOOTSTRAPS"; exit 0 ;;
  kickstart) echo "$*" >> "$DPW_TEST_KICKSTARTS"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TMP/launchctl"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/notify"; chmod +x "$TMP/notify"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gc";     chmod +x "$TMP/gc"
  export PATH="$TMP:$PATH"
  # Override the SCRIPT vars directly — the top-level `LAUNCH_DIR=${DPW_LAUNCH_DIR:-…}`
  # already ran at load, so setting DPW_LAUNCH_DIR now would be too late.
  LAUNCH_DIR="$TMP/agents"; mkdir -p "$LAUNCH_DIR"
  LOG="$TMP/log"; STATE="$TMP/state"
  # ga-95bi4: STATE (and so ${STATE}.alert-cooldown/) is set ONCE for the whole
  # selftest run, not per-scenario — a nonzero window would let one scenario's
  # failure SHAPE (e.g. crash-loop → "C") silently suppress an unrelated LATER
  # scenario sharing the same shape, since real wall-clock barely advances across
  # the whole suite. Disable the gate by default so every pre-existing scenario
  # keeps its original always-mails behavior; the dedicated ga-95bi4 scenarios
  # near the end of this suite opt a nonzero window back in locally.
  DPW_ALERT_WINDOW_SEC=0
  DPW_CRITICAL="com.gascity.alpha com.gascity.beta com.gascity.gamma"
  export DPW_TEST_BOOTSTRAPS="$TMP/bootstraps"; : > "$DPW_TEST_BOOTSTRAPS"
  export DPW_TEST_KICKSTARTS="$TMP/kicks";      : > "$DPW_TEST_KICKSTARTS"
  DPW_HEARTBEAT=""   # scenarios 1–5 do not exercise the wedge check; 6–7 set it explicitly
  # Minimal valid plist for all 3 test labels (pointing at a real script for path checks)
  for _lbl in com.gascity.alpha com.gascity.beta com.gascity.gamma; do
    cat > "$LAUNCH_DIR/$_lbl.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$_lbl</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$TMP/fake-script.sh</string>
  </array>
</dict></plist>
PLIST
  done
  # A real script that exists (used for path-exists positive cases)
  printf '#!/bin/bash\nexit 0\n' > "$TMP/fake-script.sh"; chmod +x "$TMP/fake-script.sh"

  export DPW_TEST_LOADED DPW_TEST_EXIT DPW_RELOAD   # exported so the stub subprocess sees them
  ALL="com.gascity.alpha com.gascity.beta com.gascity.gamma"

  # Disable provenance checks for scenarios 1-12 (tested explicitly in scenarios 13-17)
  DPW_CHECK_GC_PROVENANCE=0; DPW_CHECK_GT_PROVENANCE=0

  echo "Scenario 1: all loaded + clean → OK (exit 0), no bootstrap"
  DPW_RELOAD=1; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  run_sweep && ok "all-healthy returns 0" || bad "all-healthy should return 0"
  [ ! -s "$DPW_TEST_BOOTSTRAPS" ] && ok "no bootstrap when all loaded" || bad "bootstrapped despite all loaded"

  echo "Scenario 2: beta ABSENT → reloaded + alert (exit 1)"
  : > "$DPW_TEST_BOOTSTRAPS"; DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""
  run_sweep && bad "absent should return 1" || ok "absent critical daemon returns 1 (alert)"
  grep -q "com.gascity.beta" "$DPW_TEST_BOOTSTRAPS" && ok "absent beta was reloaded (bootstrap)" || bad "absent beta NOT reloaded"

  echo "Scenario 3: DPW_RELOAD=0 → absent alerts but does NOT reload"
  : > "$DPW_TEST_BOOTSTRAPS"; DPW_RELOAD=0; DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""
  run_sweep; [ ! -s "$DPW_TEST_BOOTSTRAPS" ] && ok "DPW_RELOAD=0 suppresses auto-reload" || bad "reloaded despite DPW_RELOAD=0"
  DPW_RELOAD=1

  echo "Scenario 4: crash-loop needs TWO consecutive nonzero exits"
  # AUTOHEAL=0 isolates crash-loop DETECTION (this scenario's subject) from imp17's
  # heal-vs-escalate POLICY (covered explicitly by scenarios 18-20) — with the default
  # AUTOHEAL=1, a within-budget heal stays silent (ga-nvef) and this scenario's "alerts
  # on 2nd exit" would pass only via imp05's independent counter, not crash-loop itself.
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.beta:1"
  DPW_CRASHLOOP_AUTOHEAL=0
  run_sweep && ok "single nonzero exit does NOT alert (transient)" || bad "transient nonzero exit falsely alerted"
  run_sweep && bad "2nd consecutive nonzero should alert (return 1)" || ok "persistent crash-loop alerts on 2nd consecutive nonzero exit"
  DPW_CRASHLOOP_AUTOHEAL=1

  echo "Scenario 5: negative exit (signal restart) is NOT a crash-loop"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.beta:-15"
  run_sweep >/dev/null 2>&1
  run_sweep && ok "signal exit (-15) never treated as crash-loop" || bad "signal exit falsely flagged as crash-loop"

  echo "Scenario 6: loaded daemon with a STALE heartbeat log → WEDGED + kickstart"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  HB="$TMP/beta-hb.log"; DPW_HEARTBEAT="com.gascity.beta|$HB|300"
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$HB"   # mtime ~1h ago
  run_sweep && bad "wedged should return 1" || ok "wedged daemon (stale heartbeat) returns 1 (alert)"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "wedged beta was kickstarted" || bad "wedged beta NOT kickstarted"

  echo "Scenario 7: FRESH heartbeat log → not wedged, no kickstart"
  : > "$DPW_TEST_KICKSTARTS"; touch "$HB"   # mtime = now
  run_sweep && ok "fresh heartbeat → no wedge (return 0)" || bad "fresh heartbeat falsely wedged"
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "no kickstart when heartbeat fresh" || bad "kickstarted despite fresh heartbeat"

  echo "Scenario 7b: STALE heartbeat but machine recently woke/booted → WEDGE SUPPRESSED"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  DPW_HEARTBEAT="com.gascity.beta|$HB|300"
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$HB"   # stale ~1h
  DPW_TEST_AVAIL_AGE=120
  run_sweep && ok "recent wake (up 120s < 300s) suppresses WEDGE (return 0)" || bad "WEDGE not suppressed despite recent wake"
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "no kickstart when staleness explained by recent wake" || bad "kickstarted despite recent wake (false positive)"

  echo "Scenario 7c: STALE heartbeat AND machine up past threshold → genuine WEDGE still fires"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_TEST_AVAIL_AGE=999
  run_sweep && bad "genuine wedge (up 999s > 300s) should still alert" || ok "genuine wedge survives when machine up past threshold"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "genuine wedge still kickstarted" || bad "genuine wedge NOT kickstarted"

  echo "Scenario 7d: DPW_WAKE_GRACE=0 → legacy behaviour, wedge fires even right after wake"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_TEST_AVAIL_AGE=10; DPW_WAKE_GRACE=0
  run_sweep && bad "WAKE_GRACE=0 should not suppress" || ok "DPW_WAKE_GRACE=0 reverts to legacy (wedge fires)"
  DPW_WAKE_GRACE=1; unset DPW_TEST_AVAIL_AGE
  DPW_HEARTBEAT=""

  echo "Scenario 7e: _secs_since_avail parses kern.boottime 'sec' (NOT the usec collision)"
  cat > "$TMP/sysctl" <<'SYS'
#!/usr/bin/env bash
# Mimic macOS sysctl output, including the ", usec = N" trap a greedy regex mis-captures.
case "$2" in
  kern.boottime) echo "{ sec = 1000000000, usec = 999999 } Fake Boot Date" ;;
  kern.waketime) echo "{ sec = 0, usec = 0 } Thu Jan  1 00:00:00 1970" ;;
esac
SYS
  chmod +x "$TMP/sysctl"
  _av="$(_secs_since_avail 1000000500)"   # now = boot_epoch + 500s
  [ "$_av" = "500" ] && ok "_secs_since_avail returns 500s (parsed sec, ignored usec + waketime=0)" || bad "_secs_since_avail mis-parsed boottime (got '$_av'; expected 500 — usec-collision regex regression?)"
  rm -f "$TMP/sysctl"

  # ── ga-2vf9b: in-flight gate-run guard selftests (scenarios 7f–7o) ─────────
  # 7f–7i exercise the WEDGE-block WIRING via the DPW_TEST_GATE_INFLIGHT bypass
  # seam (no live bd/jq/Dolt call) — same style as 7b–7d using
  # DPW_TEST_AVAIL_AGE. 7j–7o unit-test _gate_run_in_flight's REAL jq/date
  # logic directly (including the per-bead verdict_timeout_minutes field, not
  # just the fallback default), with a stubbed bd-list-cached.sh under a FAKE
  # $HQ (restored immediately after) — never touches the real production
  # script. All of
  # 7f–7i pin DPW_TEST_AVAIL_AGE to a large value so they never depend on the
  # REAL machine's uptime (unlike 6/7, which tolerate that dependency because
  # a long-running Mac's uptime is comfortably > their thresholds anyway).

  echo "Scenario 7f (ga-2vf9b): WEDGE + gate-run genuinely in flight → SUPPRESSED, no kickstart"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_CRITICAL="com.gascity.quality-gate-dispatcher"; DPW_TEST_LOADED="com.gascity.quality-gate-dispatcher"; DPW_TEST_EXIT=""
  GATE_HB="$TMP/gate-hb.log"; DPW_HEARTBEAT="com.gascity.quality-gate-dispatcher|$GATE_HB|600"
  touch -t "$(date -v-20M +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$GATE_HB"   # stale ~20min > 600s
  DPW_TEST_AVAIL_AGE=99999; DPW_TEST_GATE_INFLIGHT=1
  run_sweep && ok "gate-run in flight suppresses WEDGE (return 0)" || bad "WEDGE not suppressed despite gate-run in flight"
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "no kickstart when a real gate-run is in flight" || bad "kickstarted despite gate-run in flight (regression)"
  grep -q "run in flight" "$LOG" && ok "log names the suppression reason (run in flight)" || bad "log missing 'run in flight' suppression message"

  echo "Scenario 7g (ga-2vf9b): WEDGE + NO gate-run in flight → still kickstarts (unchanged)"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_TEST_GATE_INFLIGHT=0
  run_sweep && bad "genuine wedge (no in-flight run) should still alert" || ok "genuine wedge still fires when no gate-run is in flight"
  grep -q "com.gascity.quality-gate-dispatcher" "$DPW_TEST_KICKSTARTS" && ok "genuine wedge still kickstarted (no in-flight run to protect)" || bad "genuine wedge NOT kickstarted — regression"

  echo "Scenario 7h (ga-2vf9b): in-flight guard is SCOPED — a different wedge-checked daemon is NOT protected"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_CRITICAL="com.gascity.beta"; DPW_TEST_LOADED="com.gascity.beta"
  OTHER_HB="$TMP/other-hb.log"; DPW_HEARTBEAT="com.gascity.beta|$OTHER_HB|300"
  touch -t "$(date -v-1H +%Y%m%d%H%M 2>/dev/null || echo 202601010000)" "$OTHER_HB"
  DPW_TEST_GATE_INFLIGHT=1   # even with a positive in-flight signal...
  run_sweep && bad "a DIFFERENT daemon's wedge should still fire (guard is gate-dispatcher-only)" || ok "in-flight guard does NOT leak to a different daemon's wedge check"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "unrelated daemon still kickstarted (scoping confirmed)" || bad "scoping leaked — unrelated daemon wrongly protected"

  echo "Scenario 7i (ga-2vf9b): DPW_GATE_INFLIGHT_GUARD=0 → escape hatch disables the new check"
  : > "$STATE"; rm -rf "${STATE}.fail-counts"; : > "$DPW_TEST_KICKSTARTS"
  DPW_CRITICAL="com.gascity.quality-gate-dispatcher"; DPW_TEST_LOADED="com.gascity.quality-gate-dispatcher"
  DPW_HEARTBEAT="com.gascity.quality-gate-dispatcher|$GATE_HB|600"
  DPW_TEST_GATE_INFLIGHT=1; DPW_GATE_INFLIGHT_GUARD=0
  run_sweep && bad "guard disabled + in-flight=1 should still wedge (escape hatch)" || ok "DPW_GATE_INFLIGHT_GUARD=0 reverts to legacy (wedge fires despite in-flight=1)"
  DPW_GATE_INFLIGHT_GUARD=1; unset DPW_TEST_GATE_INFLIGHT DPW_TEST_AVAIL_AGE
  DPW_HEARTBEAT=""; DPW_CRITICAL="$ALL"

  echo "Scenario 7j (ga-2vf9b): _gate_run_in_flight — fresh running gate-run bead → true"
  _REAL_HQ_FOR_TEST="$HQ"; _now7="$(date +%s)"
  HQ="$TMP/fake-hq-7j"; mkdir -p "$HQ/scripts"
  _fresh_iso="$(date -u -r "$((_now7 - 100))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$HQ/scripts/bd-list-cached.sh" <<EOF
#!/usr/bin/env bash
echo '[{"id":"ga-wisp-test1","created_at":"$_fresh_iso"}]'
EOF
  chmod +x "$HQ/scripts/bd-list-cached.sh"
  _gate_run_in_flight "$_now7" && ok "fresh (100s old) running gate-run → in flight (true)" || bad "fresh running gate-run wrongly read as NOT in flight"

  echo "Scenario 7k (ga-2vf9b): _gate_run_in_flight — no description field, PAST the 60min fallback ceiling (default 50min+10min margin) → false (do not suppress forever)"
  _stale_iso="$(date -u -r "$((_now7 - 4000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"   # 4000s ≈ 66.7min > 60min fallback
  cat > "$HQ/scripts/bd-list-cached.sh" <<EOF
#!/usr/bin/env bash
echo '[{"id":"ga-wisp-test2","created_at":"$_stale_iso"}]'
EOF
  _gate_run_in_flight "$_now7" && bad "gate-run older than the fallback ceiling should NOT count as in flight" || ok "gate-run past the fallback timeout+margin correctly does NOT suppress (avoids never-recovers regression)"

  echo "Scenario 7l (ga-2vf9b): _gate_run_in_flight — no running gate-run beads → false"
  cat > "$HQ/scripts/bd-list-cached.sh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
  _gate_run_in_flight "$_now7" && bad "empty result should not count as in flight" || ok "no gate-run beads → correctly not in flight"

  echo "Scenario 7m (ga-2vf9b): _gate_run_in_flight — bd-list-cached.sh errors → false (fail-safe)"
  cat > "$HQ/scripts/bd-list-cached.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  _gate_run_in_flight "$_now7" && bad "a failing bd-list-cached.sh should fail safe to NOT in flight" || ok "bd-list-cached.sh error correctly falls through to NOT in flight (fail-safe)"

  echo "Scenario 7n (ga-2vf9b): _gate_run_in_flight — PER-BEAD verdict_timeout_minutes governs, not a flat default"
  # A SHORT-lived run (verdict_timeout_minutes=15, +10min margin = 25min window).
  # 20min old: still within its OWN window → true, even though 20min would also
  # be within the 60min fallback default — this doesn't yet prove the field is
  # actually being read instead of ignored (7o proves that negatively).
  _20min_ago_iso="$(date -u -r "$((_now7 - 1200))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$HQ/scripts/bd-list-cached.sh" <<EOF
#!/usr/bin/env bash
printf '%s' '[{"id":"ga-wisp-test3","created_at":"$_20min_ago_iso","description":"source_bead: wa-1\nbranch: crew/x\nverdict_timeout_minutes: 15\nrig: whatsapp_automation"}]'
EOF
  _gate_run_in_flight "$_now7" && ok "20min-old run with its own 15min+10min-margin=25min window → in flight (true)" || bad "wrongly read as NOT in flight within its own window"

  echo "Scenario 7o (ga-2vf9b): _gate_run_in_flight — a SHORT run's own timeout EXPIRES sooner than the 60min fallback (proves the field is actually read, not ignored)"
  # Same verdict_timeout_minutes=15 (+10min margin=25min window), but now 30min
  # old: past ITS OWN window (30 > 25) even though 30min is still comfortably
  # inside the 60min fallback default. If this returned true, the field would
  # be getting silently ignored in favor of the flat default — the exact
  # regression the adversarial review flagged.
  _30min_ago_iso="$(date -u -r "$((_now7 - 1800))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  cat > "$HQ/scripts/bd-list-cached.sh" <<EOF
#!/usr/bin/env bash
printf '%s' '[{"id":"ga-wisp-test4","created_at":"$_30min_ago_iso","description":"verdict_timeout_minutes: 15"}]'
EOF
  _gate_run_in_flight "$_now7" && bad "30min-old run past its own 15min+10min=25min window should NOT count as in flight (field being ignored?)" || ok "short run's own timeout correctly expires before the 60min fallback would (field is genuinely read, not ignored)"

  HQ="$_REAL_HQ_FOR_TEST"

  # ── RECYCLER selftests (scenarios 8–12) ──────────────────────────────────
  # All recycler scenarios use seams: a stub `ps` that returns a controlled RSS,
  # a stub `launchctl` that handles both the watchdog list queries AND the recycler's
  # `list <label>` loaded-check + PID lookup, and the same stub `notify`/`gc`.
  # RECYCLE_DRY_RUN is forced to 0 so kickstart is tested; kickstart writes to
  # DPW_TEST_KICKSTARTS (the same file used by the main watchdog stubs above).
  # No real daemon is ever touched.

  echo "Scenario 8: RECYCLE_ENABLED=0 → recycler does nothing even when RSS exceeds threshold"
  RECYCLE_ENABLED=0 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=100 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    run_recycle_sweep
  ok "RECYCLE_ENABLED=0 returns 0 (no-op)" # always passes; would error if function missing

  echo "Scenario 9: DRY_RUN=1 — logs intent but does NOT kickstart"
  # Stub a loaded leaky daemon with RSS 400MB (above default 350 threshold).
  cat > "$TMP/launchctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list)
    if [ -n "${2:-}" ]; then
      case " $DPW_TEST_LOADED " in *" $2 "*) exit 0 ;; *) exit 1 ;; esac
    fi
    for l in $DPW_TEST_LOADED; do
      e=0; for kv in $DPW_TEST_EXIT; do case "$kv" in "$l:"*) e="${kv#*:}";; esac; done
      printf '%s\t%s\t%s\n' "-" "$e" "$l"
    done ;;
  bootstrap) echo "$2 $3" >> "$DPW_TEST_BOOTSTRAPS"; exit 0 ;;
  kickstart) echo "$*" >> "$DPW_TEST_KICKSTARTS"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$TMP/launchctl"
  # The recycler calls `launchctl list <label>` (uses the stub → succeeds if label in DPW_TEST_LOADED)
  # then `launchctl list <label>` JSON for PID. We stub _rss_mb directly by overriding the function.
  # Simpler: override _rss_mb to return a fixed value for the test label.
  _rss_mb() { echo 400; }   # stub: always 400 MB
  : > "$DPW_TEST_KICKSTARTS"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=1 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "DRY_RUN=1: no kickstart issued" || bad "DRY_RUN=1 unexpectedly kickstarted"
  grep -q "dry-run" "$LOG" 2>/dev/null && ok "DRY_RUN=1: logged dry-run intent" || bad "DRY_RUN=1: missing dry-run log entry"

  echo "Scenario 10: RSS below threshold → no recycle"
  _rss_mb() { echo 100; }   # stub: 100 MB — well under 350
  : > "$DPW_TEST_KICKSTARTS"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "RSS below threshold: no kickstart" || bad "RSS below threshold unexpectedly kickstarted"

  echo "Scenario 11: RSS above threshold, DRY_RUN=0 → kickstart issued"
  _rss_mb() { echo 500; }   # stub: 500 MB
  : > "$DPW_TEST_KICKSTARTS"; rm -f "$TMP/rstate/com.test.leaky"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  grep -q "com.test.leaky" "$DPW_TEST_KICKSTARTS" && ok "RSS above threshold: kickstart issued" || bad "RSS above threshold: kickstart NOT issued"
  grep -q "RECYCLED" "$LOG" 2>/dev/null && ok "RSS above threshold: RECYCLED logged" || bad "RSS above threshold: RECYCLED not logged"

  echo "Scenario 12: chronic-leak escalation — recycles > RECYCLE_CHRONIC_PER_HR times"
  _rss_mb() { echo 500; }
  rm -rf "$TMP/rstate"; mkdir -p "$TMP/rstate"
  # Simulate 3 previous recycles this hour by pre-seeding the state file.
  NOW_EPOCH="$(date +%s)"; HOUR_START=$(( NOW_EPOCH - (NOW_EPOCH % 3600) ))
  printf '%s %s\n' "$HOUR_START" "3" > "$TMP/rstate/com.test.leaky"
  # A 4th recycle (count=4 > RECYCLE_CHRONIC_PER_HR=3) should trigger mail.
  MAILSENT="$TMP/mailsent"; : > "$MAILSENT"
  cat > "$TMP/gc" <<GCSTUB
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT"
exit 0
GCSTUB
  chmod +x "$TMP/gc"
  RECYCLE_ENABLED=1 RECYCLE_DRY_RUN=0 RECYCLE_RSS_MB=350 RECYCLE_CHRONIC_PER_HR=3 \
    RECYCLE_DAEMONS="com.test.leaky" RECYCLE_STATE_DIR="$TMP/rstate" \
    DPW_TEST_LOADED="com.test.leaky" DPW_TEST_EXIT="" \
    run_recycle_sweep
  grep -q "mail" "$MAILSENT" && ok "chronic leak (4th recycle/hr): gc mail send issued" || bad "chronic leak: gc mail NOT sent"
  grep -q "CHRONIC" "$LOG" 2>/dev/null && ok "chronic leak: CHRONIC LEAK logged" || bad "chronic leak: CHRONIC LEAK not logged"

  # Restore _rss_mb to real implementation for subsequent use.
  unset -f _rss_mb

  # ── imp05 selftest scenarios 13–17 ───────────────────────────────────────
  # Re-enable provenance checks; use stub strings/gc/gt binaries.
  DPW_CHECK_GC_PROVENANCE=1; DPW_CHECK_GT_PROVENANCE=1
  DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""; : > "$STATE"; rm -rf "${STATE}.fail-counts"
  # Restore gc stub from the chronic-leak scenario back to silent-success.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gc"; chmod +x "$TMP/gc"

  echo "Scenario 13 (imp05): exit-code consecutive-failure tracking (FAILING alert after DPW_FAIL_THRESHOLD sweeps)"
  # Use threshold=3 and clear STATE before each sweep so crash-loop (which needs prev in STATE)
  # never fires independently — we isolate just the FAILING counter logic.
  rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.alpha:2"
  DPW_FAIL_THRESHOLD=3
  : > "$STATE"; run_sweep && ok "1st nonzero exit: no FAILING alert yet (threshold=3)" || bad "1st nonzero exit falsely triggered FAILING alert"
  : > "$STATE"; run_sweep && ok "2nd nonzero exit: still below threshold (threshold=3)" || bad "2nd nonzero exit falsely triggered FAILING alert"
  : > "$STATE"; run_sweep && bad "3rd consecutive nonzero: FAILING alert should fire" || ok "3rd consecutive nonzero triggers FAILING alert (return 1)"
  # Reset and confirm a clean sweep clears the counter
  DPW_TEST_EXIT=""; : > "$STATE"
  run_sweep && ok "clean exit after failure: clears counter (no alert)" || bad "clean sweep after failure returned non-zero unexpectedly"
  DPW_FAIL_THRESHOLD=2   # restore default

  echo "Scenario 14 (imp05): ProgramArguments PATH-EXISTS — script missing from disk → PATH-MISSING alert"
  rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  # Rewrite beta's plist to point at a non-existent script.
  MISSING_SCRIPT="$TMP/nonexistent-script.sh"
  cat > "$LAUNCH_DIR/com.gascity.beta.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gascity.beta</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$MISSING_SCRIPT</string>
  </array>
</dict></plist>
PLIST
  run_sweep && bad "PATH-MISSING beta: should return 1 (alert)" || ok "PATH-MISSING: plist pointing to absent script triggers alert (return 1)"
  grep -q "PATH-MISSING" "$LOG" && ok "PATH-MISSING: logged PATH-MISSING entry" || bad "PATH-MISSING: no log entry found"
  # Restore beta's plist to valid script
  cat > "$LAUNCH_DIR/com.gascity.beta.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gascity.beta</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>$TMP/fake-script.sh</string>
  </array>
</dict></plist>
PLIST

  echo "Scenario 15 (imp05): ProgramArguments PATH-EXISTS — script present → no PATH-MISSING alert"
  rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  run_sweep && ok "PATH-EXISTS: all scripts present → no alert (return 0)" || bad "PATH-EXISTS: falsely triggered PATH-MISSING"

  echo "Scenario 16 (imp05): binary-provenance — gc missing marker → PROVENANCE-FAIL alert"
  rm -rf "${STATE}.fail-counts"; : > "$LOG"; : > "$STATE"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  DPW_CHECK_GC_PROVENANCE=1; DPW_CHECK_GT_PROVENANCE=0   # isolate gc test
  DPW_GC_PROVENANCE_MARKER="IsTransientDoltError"
  # Override _binary_has_marker to simulate missing marker (return 1 = not found).
  # Provenance failures are logged via _alert but do NOT cause run_sweep to return non-zero.
  _binary_has_marker() { return 1; }
  run_sweep || true   # sweep may or may not return non-zero; we only check the log
  grep -q "PROVENANCE-FAIL" "$LOG" && ok "gc missing marker: PROVENANCE-FAIL logged" || bad "gc missing marker: PROVENANCE-FAIL not logged"
  # Also verify the log says "gc rebuild reverted" (the specific message)
  grep -q "gc rebuild reverted Dolt-resilience" "$LOG" && ok "gc missing marker: correct Dolt-resilience message logged" || bad "gc missing marker: Dolt-resilience message not found in log"
  unset -f _binary_has_marker

  echo "Scenario 17 (imp05): binary-provenance — gc has marker → no alert"
  rm -rf "${STATE}.fail-counts"; : > "$LOG"; : > "$STATE"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT=""
  DPW_CHECK_GC_PROVENANCE=1; DPW_CHECK_GT_PROVENANCE=0
  # Override _binary_has_marker to simulate marker present (return 0 = found).
  _binary_has_marker() { return 0; }
  run_sweep && ok "gc marker present: sweep returns 0 (no alert)" || bad "gc marker present: unexpected non-zero"
  grep -q "PROVENANCE-FAIL" "$LOG" && bad "gc marker present: PROVENANCE-FAIL wrongly logged" || ok "gc marker present: no PROVENANCE-FAIL in log"
  unset -f _binary_has_marker
  DPW_CHECK_GC_PROVENANCE=1; DPW_CHECK_GT_PROVENANCE=1

  # ── imp17 selftest scenarios 18–21 ───────────────────────────────────────
  # Re-disable provenance checks to isolate crash-loop-autoheal logic.
  DPW_CHECK_GC_PROVENANCE=0; DPW_CHECK_GT_PROVENANCE=0
  # Restore gc stub to silent-success (chronic-leak scenario may have changed it)
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gc"; chmod +x "$TMP/gc"

  echo "Scenario 18 (imp17): crash-loop + AUTOHEAL=1, first attempt → kickstart issued, no Mayor mail"
  : > "$STATE"; rm -rf "${STATE}.crashloop-heals" "${STATE}.fail-counts"
  : > "$DPW_TEST_KICKSTARTS"
  MAILSENT18="$TMP/mailsent18"; : > "$MAILSENT18"
  cat > "$TMP/gc" <<GCSTUB18
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT18"
exit 0
GCSTUB18
  chmod +x "$TMP/gc"
  DPW_CRASHLOOP_AUTOHEAL=1 DPW_CRASHLOOP_HEAL_MAX=2 DPW_TEST_LOADED="$ALL" DPW_TEST_EXIT="com.gascity.beta:1"
  run_sweep >/dev/null 2>&1    # first sweep: prev empty, no crash-loop yet
  run_sweep && ok "AUTOHEAL=1 first attempt: kickstart succeeded → sweep returns 0 (healing in progress)" || bad "AUTOHEAL=1 first attempt: unexpected non-zero return"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "AUTOHEAL=1: kickstart -k issued for crash-looping daemon" || bad "AUTOHEAL=1: kickstart NOT issued"
  [ ! -s "$MAILSENT18" ] && ok "AUTOHEAL=1: no Mayor mail on first auto-heal attempt" || bad "AUTOHEAL=1: Mayor mail sent prematurely before exhaustion"

  echo "Scenario 19 (imp17): crash-loop + AUTOHEAL=0 → no kickstart, immediate escalation"
  : > "$STATE"; rm -rf "${STATE}.crashloop-heals" "${STATE}.fail-counts"
  : > "$DPW_TEST_KICKSTARTS"
  MAILSENT19="$TMP/mailsent19"; : > "$MAILSENT19"
  cat > "$TMP/gc" <<GCSTUB19
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT19"
exit 0
GCSTUB19
  chmod +x "$TMP/gc"
  DPW_CRASHLOOP_AUTOHEAL=0 DPW_TEST_LOADED="$ALL" DPW_TEST_EXIT="com.gascity.beta:1"
  run_sweep >/dev/null 2>&1    # first sweep: no crash-loop yet
  : > "$DPW_TEST_KICKSTARTS"  # clear kickstarts from first sweep
  run_sweep && bad "AUTOHEAL=0: crash-loop should escalate (return 1)" || ok "AUTOHEAL=0: crash-loop immediately escalates (return 1)"
  [ ! -s "$DPW_TEST_KICKSTARTS" ] && ok "AUTOHEAL=0: no kickstart issued (legacy alert-only)" || bad "AUTOHEAL=0: kickstart unexpectedly issued"

  echo "Scenario 20 (imp17): heal budget exhausted → escalate to human"
  : > "$STATE"; rm -rf "${STATE}.crashloop-heals" "${STATE}.fail-counts"
  # Pre-seed heal counter to HEAL_MAX (simulate prior attempts already consumed)
  mkdir -p "${STATE}.crashloop-heals"
  printf '2\n' > "${STATE}.crashloop-heals/com.gascity.beta"
  # Pre-seed imp05's own counter too (ga-nvef): in real operation imp05 has been
  # counting every sweep right alongside imp17's heal attempts, so by the time the
  # heal budget is exhausted imp05 is already at/past its own threshold as well.
  mkdir -p "${STATE}.fail-counts"
  printf '1\n' > "${STATE}.fail-counts/com.gascity.beta"
  # STATE shows beta exited 1 previously (crash-loop condition requires prev>0)
  printf '%s\n' "com.gascity.alpha 0" "com.gascity.beta 1" "com.gascity.gamma 0" > "$STATE"
  MAILSENT20="$TMP/mailsent20"; : > "$MAILSENT20"
  cat > "$TMP/gc" <<GCSTUB20
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT20"
exit 0
GCSTUB20
  chmod +x "$TMP/gc"
  DPW_CRASHLOOP_AUTOHEAL=1 DPW_CRASHLOOP_HEAL_MAX=2 DPW_TEST_LOADED="$ALL" DPW_TEST_EXIT="com.gascity.beta:1"
  run_sweep && bad "heal budget exhausted: should escalate (return 1)" || ok "heal budget exhausted (3rd attempt > max=2): escalates to human (return 1)"
  grep -q "heals-exhausted" "$LOG" 2>/dev/null && ok "heal budget exhausted: 'heals-exhausted' in log" || bad "heal budget exhausted: missing log entry"
  grep -q "FAILING" "$MAILSENT20" 2>/dev/null && ok "heal budget exhausted (ga-nvef): FAILING still reaches Mayor once escalation is genuine (imp05 not permanently silenced)" || bad "heal budget exhausted: FAILING missing from mail — imp05 wrongly silenced permanently"

  echo "Scenario 21 (imp17): daemon recovers (clean exit) → heal counter reset"
  : > "$STATE"; rm -rf "${STATE}.crashloop-heals" "${STATE}.fail-counts"
  mkdir -p "${STATE}.crashloop-heals"
  printf '1\n' > "${STATE}.crashloop-heals/com.gascity.beta"
  DPW_CRASHLOOP_AUTOHEAL=1 DPW_TEST_LOADED="$ALL" DPW_TEST_EXIT=""  # all exit 0
  run_sweep && ok "daemon recovered (ex=0): sweep returns 0 (healthy)" || bad "clean exit after heal: unexpected non-zero"
  [ ! -f "${STATE}.crashloop-heals/com.gascity.beta" ] && ok "daemon recovered: heal counter file removed" || bad "daemon recovered: heal counter NOT reset"

  # Restore gc stub
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/gc"; chmod +x "$TMP/gc"
  DPW_CHECK_GC_PROVENANCE=1; DPW_CHECK_GT_PROVENANCE=1

  echo "Scenario 22 (ga-9wv5): real default DPW_HEARTBEAT covers approved-state-reconciler + the janitors"
  # Static assertion against the REAL default (captured before scenario 1 ran), not a
  # scenario-local override — proves the coverage gap named in ga-9wv5 stays closed even
  # if a future edit reorders/retypes the DPW_HEARTBEAT default string. Each label must
  # (a) appear in DPW_HEARTBEAT with a heartbeat file + numeric threshold, and (b) also be
  # a member of DPW_CRITICAL — a heartbeat entry for a label the sweep never iterates over
  # is silently dead code (see run_sweep's `for lbl in $DPW_CRITICAL`).
  for _gap_lbl in com.gascity.approved-state-reconciler com.gascity.auto-rehome-janitor \
                  com.gascity.sling-task-janitor com.gascity.gate-marker-rehome-janitor; do
    _gap_line="$(printf '%s\n' "$_REAL_DEFAULT_HEARTBEAT" | awk -F'|' -v l="$_gap_lbl" '$1==l{print; exit}')"
    if [ -n "$_gap_line" ]; then
      ok "DPW_HEARTBEAT default covers $_gap_lbl ($_gap_line)"
    else
      bad "DPW_HEARTBEAT default MISSING an entry for $_gap_lbl"
    fi
    case " $_REAL_DEFAULT_CRITICAL " in
      *" $_gap_lbl "*) ok "$_gap_lbl is also in DPW_CRITICAL (heartbeat entry is reachable)" ;;
      *) bad "$_gap_lbl has a heartbeat entry but is NOT in DPW_CRITICAL (dead config)" ;;
    esac
  done
  unset _gap_lbl _gap_line

  echo "Scenario 23 (ga-g92h): _exit_class distinguishes OOM-killed (137) from a real failure"
  # Provenance checks off (matches the imp17 block's own convention above) --
  # scenario 16/17 permanently `unset -f _binary_has_marker` to undo their
  # local override, which also erases the module's real definition for the
  # rest of this process (pre-existing selftest quirk, unrelated to ga-g92h).
  # Leaving provenance on here would call the now-missing function and print
  # "command not found" noise with no effect on any assertion below.
  DPW_CHECK_GC_PROVENANCE=0; DPW_CHECK_GT_PROVENANCE=0
  [ "$(_exit_class 137)" = "oom-killed" ] && ok "_exit_class(137) = oom-killed (SIGKILL)"      || bad "_exit_class(137) should be oom-killed"
  [ "$(_exit_class 1)" = "failing" ]      && ok "_exit_class(1) = failing (code error)"         || bad "_exit_class(1) should be failing"
  [ "$(_exit_class 2)" = "failing" ]      && ok "_exit_class(2) = failing (any other nonzero)"  || bad "_exit_class(2) should be failing"

  echo "Scenario 24 (ga-g92h): exit=137 crossing FAILING threshold alerts as OOM-KILLED, not FAILING"
  rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.alpha:137"
  : > "$STATE"; : > "$LOG"; run_sweep && ok "1st exit=137: no alert yet (threshold=2)" || bad "1st exit=137 falsely alerted"
  : > "$STATE"; run_sweep && bad "2nd consecutive exit=137: should alert (return 1)" || ok "2nd consecutive exit=137 alerts (return 1, OOM-KILLED bucket)"
  grep -q "OOM-KILLED: com.gascity.alpha" "$LOG" && ok "log contains OOM-KILLED for exit=137 (ga-g92h)" || bad "log missing OOM-KILLED line for exit=137"
  grep -q "FAILING: com.gascity.alpha" "$LOG" && bad "log wrongly contains FAILING for exit=137 (should be OOM-KILLED only)" || ok "log does NOT say FAILING for exit=137"

  echo "Scenario 25 (ga-g92h): exit=1 (plain code failure) still alerts as FAILING — regression guard"
  rm -rf "${STATE}.fail-counts"; DPW_TEST_LOADED="$ALL"; DPW_TEST_EXIT="com.gascity.alpha:1"
  : > "$STATE"; : > "$LOG"; run_sweep && ok "1st exit=1: no alert yet (threshold=2)" || bad "1st exit=1 falsely alerted"
  : > "$STATE"; run_sweep && bad "2nd consecutive exit=1: should alert (return 1)" || ok "2nd consecutive exit=1 alerts (return 1, FAILING bucket unchanged)"
  grep -q "FAILING: com.gascity.alpha" "$LOG" && ok "log contains FAILING for exit=1 (unchanged behavior)" || bad "log missing FAILING line for exit=1 regression"
  grep -q "OOM-KILLED: com.gascity.alpha" "$LOG" && bad "log wrongly contains OOM-KILLED for exit=1" || ok "log does NOT say OOM-KILLED for exit=1"

  echo "Scenario 26 (ga-nvef × ga-g92h): OOM-killed exit crash-looping with in-budget autoheal → mail stays suppressed, not reclassified as OOM-KILLED"
  # Neither original fix could test this interaction — ga-nvef's healing_inflight
  # suppression and ga-g92h's OOM classification were written against different
  # bases. This proves the merged ordering (suppression check wraps the
  # classification) holds: an in-budget heal silences imp05's mail regardless of
  # WHY the exit crossed threshold, exactly like a plain exit=1 in scenario 18.
  : > "$STATE"; rm -rf "${STATE}.crashloop-heals" "${STATE}.fail-counts"
  : > "$DPW_TEST_KICKSTARTS"
  MAILSENT26="$TMP/mailsent26"; : > "$MAILSENT26"
  cat > "$TMP/gc" <<GCSTUB26
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT26"
exit 0
GCSTUB26
  chmod +x "$TMP/gc"
  DPW_CRASHLOOP_AUTOHEAL=1 DPW_CRASHLOOP_HEAL_MAX=2 DPW_TEST_LOADED="$ALL" DPW_TEST_EXIT="com.gascity.beta:137"
  run_sweep >/dev/null 2>&1    # first sweep: prev empty, no crash-loop yet
  : > "$LOG"
  run_sweep && ok "OOM exit + in-budget heal: sweep returns 0 (healing in progress)" || bad "OOM exit + in-budget heal: unexpected non-zero return"
  grep -q "com.gascity.beta" "$DPW_TEST_KICKSTARTS" && ok "OOM exit: kickstart -k issued for crash-looping daemon" || bad "OOM exit: kickstart NOT issued"
  [ ! -s "$MAILSENT26" ] && ok "OOM exit + in-budget heal: no Mayor mail (imp05 suppressed same as a plain failure)" || bad "OOM exit + in-budget heal: Mayor mail sent prematurely"
  grep -q "mail suppressed" "$LOG" && ok "log shows imp05 suppression message for the OOM-classified exit" || bad "log missing suppression message for OOM exit"
  grep -q "OOM-KILLED: com.gascity.beta" "$LOG" && bad "log wrongly emitted OOM-KILLED while heal is in-budget (should stay suppressed)" || ok "log does NOT say OOM-KILLED while heal is in-budget"

  echo "Scenario 27 (ga-u04vp): presence-drift — plist LOADED (both compact + expanded plist styles) → no alert"
  PDIR="$TMP/presence-src"; mkdir -p "$PDIR"
  cat > "$PDIR/delta.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>com.gascity.delta</string>
</dict></plist>
PLIST
  cat > "$PDIR/epsilon.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.gascity.epsilon</string>
</dict>
</plist>
PLIST
  DPW_PRESENCE_DIRS="$PDIR"; DPW_TEST_LOADED="com.gascity.delta com.gascity.epsilon"
  run_presence_drift_sweep && ok "both compact + expanded plist styles resolve + loaded → no alert" || bad "loaded presence-dir plists falsely alerted"

  echo "Scenario 28 (ga-u04vp): presence-drift — one plist NOT loaded → alert names exactly that label"
  : > "$LOG"; DPW_TEST_LOADED="com.gascity.epsilon"
  run_presence_drift_sweep && bad "undeployed presence-dir plist should alert (return 1)" || ok "undeployed presence-dir plist alerts (return 1)"
  grep -q "com.gascity.delta" "$LOG" && ok "alert names the undeployed label (delta)" || bad "alert missing the undeployed label"
  grep -q "com.gascity.epsilon" "$LOG" && bad "alert wrongly mentions the still-loaded label (epsilon)" || ok "loaded label (epsilon) correctly absent from alert"

  echo "Scenario 29 (ga-u04vp): presence-drift skips a label already in DPW_CRITICAL (no double-alert)"
  : > "$LOG"; DPW_CRITICAL="com.gascity.delta"; DPW_TEST_LOADED="com.gascity.epsilon"
  run_presence_drift_sweep && ok "DPW_CRITICAL label deferred to main loop, not double-alerted here (return 0)" || bad "presence-drift double-alerted a DPW_CRITICAL label"
  DPW_CRITICAL="$ALL"

  echo "Scenario 30 (ga-u04vp): DPW_PRESENCE_DRIFT_ENABLED=0 → sweep no-ops even with an undeployed plist"
  : > "$LOG"; DPW_PRESENCE_DRIFT_ENABLED=0; DPW_TEST_LOADED="com.gascity.epsilon"
  run_presence_drift_sweep && ok "disabled presence-drift sweep returns 0 even with undeployed plist (delta)" || bad "disabled presence-drift sweep should not alert"
  DPW_PRESENCE_DRIFT_ENABLED=1

  echo "Scenario 31 (ga-4l2sn): presence-drift — first alert names source dir + disambiguates from ~/Library/LaunchAgents, dedup suppresses repeat"
  : > "$LOG"; rm -rf "${STATE}.presence-drift"; DPW_CRITICAL="$ALL"; DPW_PRESENCE_DIRS="$PDIR"; DPW_TEST_LOADED="com.gascity.epsilon"
  MAILSENT31="$TMP/mailsent31"; : > "$MAILSENT31"
  cat > "$TMP/gc" <<GCSTUB31
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT31"
exit 0
GCSTUB31
  chmod +x "$TMP/gc"
  DPW_TEST_NOW=1000000000
  run_presence_drift_sweep >/dev/null 2>&1
  [ -s "$MAILSENT31" ] && ok "first drift on delta: mail sent" || bad "first drift on delta: expected mail, none sent"
  grep -q "src:$PDIR" "$LOG" && ok "alert names the source directory ($PDIR)" || bad "alert missing the source-directory annotation"
  grep -q "LaunchAgents" "$LOG" && ok "alert disambiguates source dir from ~/Library/LaunchAgents" || bad "alert missing the LaunchAgents disambiguation"
  : > "$MAILSENT31"; : > "$LOG"
  DPW_TEST_NOW=1000000100   # 100s later — well inside the 10800s default cooldown
  run_presence_drift_sweep; rc31=$?
  [ "$rc31" -eq 1 ] && ok "repeat sweep within cooldown: still returns 1 (drift persists)" || bad "repeat sweep within cooldown: expected return 1"
  [ ! -s "$MAILSENT31" ] && ok "repeat sweep within cooldown: mail suppressed (dedup)" || bad "repeat sweep within cooldown: mail wrongly re-sent"
  grep -q "already alerted" "$LOG" && ok "repeat sweep within cooldown: suppression logged" || bad "repeat sweep within cooldown: missing suppression log line"

  echo "Scenario 32 (ga-4l2sn): presence-drift — cooldown EXPIRES → re-alerts"
  : > "$MAILSENT31"; : > "$LOG"
  DPW_TEST_NOW=$(( 1000000000 + DPW_PRESENCE_DRIFT_COOLDOWN_SEC + 1 ))
  run_presence_drift_sweep >/dev/null 2>&1
  [ -s "$MAILSENT31" ] && ok "sweep after cooldown expiry: re-alerts (mail sent)" || bad "sweep after cooldown expiry: expected fresh mail"

  echo "Scenario 33 (ga-4l2sn): presence-drift — label recovers (loaded) then drifts again → alerts fresh, no stale cooldown carried over"
  : > "$MAILSENT31"; : > "$LOG"
  DPW_TEST_LOADED="com.gascity.delta com.gascity.epsilon"
  run_presence_drift_sweep >/dev/null 2>&1
  [ ! -f "$(_pd_state_file com.gascity.delta)" ] && ok "recovered label: cooldown state file cleared" || bad "recovered label: stale cooldown state NOT cleared"
  DPW_TEST_LOADED="com.gascity.epsilon"
  run_presence_drift_sweep >/dev/null 2>&1
  [ -s "$MAILSENT31" ] && ok "same label drifts again post-recovery: alerts fresh (no inherited cooldown)" || bad "same label post-recovery: unexpectedly suppressed"
  unset DPW_TEST_NOW

  # ── ga-95bi4 selftest scenarios 34–38 ────────────────────────────────────
  # The acceptance bar from the bug report itself: running the watchdog N times
  # with the condition PERSISTING must produce 1 mail, not N — and the exact
  # test is running it twice in a row with the condition still true and
  # confirming the second call sent no new mail.
  DPW_CHECK_GC_PROVENANCE=0; DPW_CHECK_GT_PROVENANCE=0

  echo "Scenario 34 (ga-95bi4): persisting ABSENT condition — 2 sweeps mail ONCE, not every sweep"
  : > "$LOG"; rm -rf "${STATE}.alert-cooldown"; : > "$STATE"
  _fail_count_reset com.gascity.alpha; _cl_heal_reset com.gascity.alpha
  DPW_ALERT_WINDOW_SEC=3600
  DPW_CRASHLOOP_AUTOHEAL=0
  DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""   # beta absent
  : > "$DPW_TEST_BOOTSTRAPS"
  MAILSENT34="$TMP/mailsent34"; : > "$MAILSENT34"
  cat > "$TMP/gc" <<GCSTUB34
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT34"
exit 0
GCSTUB34
  chmod +x "$TMP/gc"
  run_sweep >/dev/null 2>&1
  [ -s "$MAILSENT34" ] && ok "1st sweep with beta ABSENT: mail sent" || bad "1st sweep with beta ABSENT: expected mail, none sent"
  : > "$MAILSENT34"
  run_sweep >/dev/null 2>&1   # beta still absent (bootstrap stub never changes DPW_TEST_LOADED) — identical failure shape
  [ ! -s "$MAILSENT34" ] && ok "2nd sweep, same persisting ABSENT: mail suppressed (ga-95bi4 fix — was the 194x-mail bug)" || bad "2nd sweep: mail wrongly re-sent for the exact same persisting condition"
  grep -q "ALERT-SUPPRESSED (mail, failure shape" "$LOG" && ok "2nd sweep: suppression logged with the failure shape" || bad "2nd sweep: missing shape-suppression log line"

  echo "Scenario 35 (ga-95bi4): ABSENT cooldown EXPIRES → re-alerts"
  : > "$MAILSENT34"
  printf '%s\n' "$(( $(date +%s) - DPW_ALERT_WINDOW_SEC - 1 ))" > "$(_alert_cd_file "sweep-shape-A")"
  run_sweep >/dev/null 2>&1
  [ -s "$MAILSENT34" ] && ok "sweep after cooldown expiry: re-alerts (mail sent)" || bad "sweep after cooldown expiry: expected fresh mail"

  echo "Scenario 36 (ga-95bi4): a NEW failure shape (escalation) re-mails immediately, even while the OLD shape is still cooling down"
  : > "$MAILSENT34"
  DPW_TEST_EXIT="com.gascity.alpha:1"
  run_sweep >/dev/null 2>&1   # 1st nonzero exit for alpha: not yet 2 consecutive, so shape is still "A"-only (beta absent) — still cooling down from scenario 35
  [ ! -s "$MAILSENT34" ] && ok "priming sweep (shape still A-only): mail correctly still suppressed" || bad "priming sweep: mail unexpectedly sent"
  : > "$MAILSENT34"
  run_sweep >/dev/null 2>&1   # 2nd consecutive nonzero exit for alpha → crash-loop bucket now also fires → shape becomes "AC", a brand-new key
  [ -s "$MAILSENT34" ] && ok "escalation to a NEW failure shape (AC) mails immediately despite the A-only shape still cooling down" || bad "escalation to a new failure shape was wrongly suppressed"
  grep -q "CRASH-LOOP" "$MAILSENT34" && ok "escalation mail body includes the new CRASH-LOOP bucket" || bad "escalation mail body missing CRASH-LOOP bucket"
  unset DPW_TEST_EXIT
  DPW_ALERT_WINDOW_SEC=0; DPW_CRASHLOOP_AUTOHEAL=1
  _fail_count_reset com.gascity.alpha; _cl_heal_reset com.gascity.alpha

  echo "Scenario 37 (ga-95bi4): _alert() cooldown — a 2nd identical provenance failure within the window does not re-mail"
  : > "$LOG"; rm -rf "${STATE}.alert-cooldown"
  DPW_ALERT_WINDOW_SEC=3600
  MAILSENT37="$TMP/mailsent37"; : > "$MAILSENT37"
  cat > "$TMP/gc" <<GCSTUB37
#!/usr/bin/env bash
[ "\$1" = "mail" ] && echo "\$*" >> "$MAILSENT37"
exit 0
GCSTUB37
  chmod +x "$TMP/gc"
  _alert "gc binary provenance" "first detection"
  [ -s "$MAILSENT37" ] && ok "_alert 1st call: mail sent" || bad "_alert 1st call: expected mail, none sent"
  : > "$MAILSENT37"
  _alert "gc binary provenance" "still absent next sweep"
  [ ! -s "$MAILSENT37" ] && ok "_alert 2nd call, same subject within window: mail suppressed" || bad "_alert 2nd call: mail wrongly re-sent"
  grep -q "ALERT-SUPPRESSED (mail, within" "$LOG" && ok "_alert 2nd call: suppression logged" || bad "_alert 2nd call: missing suppression log line"

  echo "Scenario 38 (ga-95bi4): _alert() skip_cd 3rd-arg bypasses the cooldown (presence-drift already deduped upstream, ga-4l2sn)"
  : > "$MAILSENT37"
  _alert "gc binary provenance" "still absent, caller opts out of the generic gate" 1
  [ -s "$MAILSENT37" ] && ok "_alert with skip_cd=1: mail sent despite same subject still within window" || bad "_alert with skip_cd=1: wrongly suppressed"
  DPW_ALERT_WINDOW_SEC=0

  # ── ga-95bi4 gate-fix regression scenarios 39-40 ─────────────────────────
  # Gate feedback on attempt 1: _alert_cd_ok used to WRITE the cooldown
  # timestamp as part of the "may I send" check, before the caller's `gc mail
  # send` was confirmed to succeed. A failed/absent gc was swallowed by
  # `2>/dev/null || true` with zero effect on control flow, but the cooldown
  # was already armed — silently blacking out the mail channel for up to
  # DPW_ALERT_WINDOW_SEC on exactly the first attempt for a new failure shape.
  # Every gc stub above unconditionally `exit 0`s, so none of them could have
  # caught this. These two scenarios use a gc stub whose FIRST `mail`
  # invocation fails and whose SECOND succeeds, to prove: (a) a failed send
  # does not arm the cooldown — the very next sweep retries and succeeds —
  # and (b) a confirmed successful send still arms it normally afterward.

  echo "Scenario 39 (ga-95bi4 gate-fix): run_sweep's shape-cooldown — a FAILED gc mail send must NOT mark cooldown"
  : > "$LOG"; rm -rf "${STATE}.alert-cooldown"; : > "$STATE"
  _fail_count_reset com.gascity.alpha; _cl_heal_reset com.gascity.alpha
  DPW_ALERT_WINDOW_SEC=3600
  DPW_CRASHLOOP_AUTOHEAL=0
  DPW_TEST_LOADED="com.gascity.alpha com.gascity.gamma"; DPW_TEST_EXIT=""   # beta absent
  : > "$DPW_TEST_BOOTSTRAPS"
  MAILSENT39="$TMP/mailsent39"; : > "$MAILSENT39"
  GCCALLS39="$TMP/gccalls39"; : > "$GCCALLS39"
  cat > "$TMP/gc" <<GCSTUB39
#!/usr/bin/env bash
if [ "\$1" = "mail" ]; then
  echo x >> "$GCCALLS39"
  n=\$(wc -l < "$GCCALLS39" | tr -d ' ')
  [ "\$n" -eq 1 ] && exit 1   # 1st send attempt fails (simulates Dolt down)
  echo "\$*" >> "$MAILSENT39"
  exit 0
fi
exit 0
GCSTUB39
  chmod +x "$TMP/gc"
  run_sweep >/dev/null 2>&1
  [ ! -s "$MAILSENT39" ] && ok "1st sweep, gc mail send FAILS: no mail recorded as sent" || bad "1st sweep: mail unexpectedly recorded despite stub failing"
  grep -q "cooldown NOT marked" "$LOG" && ok "1st sweep: failed send logged as NOT marking cooldown" || bad "1st sweep: missing 'cooldown NOT marked' log line"
  run_sweep >/dev/null 2>&1   # same persisting ABSENT condition; gc mail send now succeeds
  [ -s "$MAILSENT39" ] && ok "2nd sweep, same persisting condition: mail sent (prior FAILED attempt did not block the retry — the gate-fix)" || bad "2nd sweep: mail wrongly suppressed after a prior failed attempt (regression to gate-failed behavior)"
  : > "$MAILSENT39"
  run_sweep >/dev/null 2>&1   # same condition again; this time cooldown should be armed from the CONFIRMED successful 2nd send
  [ ! -s "$MAILSENT39" ] && ok "3rd sweep, same persisting condition: mail suppressed (cooldown correctly armed after a confirmed successful send)" || bad "3rd sweep: mail wrongly re-sent — cooldown not armed after a successful send"
  DPW_ALERT_WINDOW_SEC=0
  _fail_count_reset com.gascity.alpha; _cl_heal_reset com.gascity.alpha

  echo "Scenario 40 (ga-95bi4 gate-fix): _alert() cooldown — a FAILED gc mail send must NOT mark cooldown either"
  : > "$LOG"; rm -rf "${STATE}.alert-cooldown"
  DPW_ALERT_WINDOW_SEC=3600
  MAILSENT40="$TMP/mailsent40"; : > "$MAILSENT40"
  GCCALLS40="$TMP/gccalls40"; : > "$GCCALLS40"
  cat > "$TMP/gc" <<GCSTUB40
#!/usr/bin/env bash
if [ "\$1" = "mail" ]; then
  echo x >> "$GCCALLS40"
  n=\$(wc -l < "$GCCALLS40" | tr -d ' ')
  [ "\$n" -eq 1 ] && exit 1   # 1st send attempt fails
  echo "\$*" >> "$MAILSENT40"
  exit 0
fi
exit 0
GCSTUB40
  chmod +x "$TMP/gc"
  _alert "gc binary provenance" "first detection, send will fail"
  [ ! -s "$MAILSENT40" ] && ok "_alert 1st call, gc mail send FAILS: no mail recorded" || bad "_alert 1st call: mail unexpectedly recorded despite stub failing"
  grep -q "cooldown NOT marked" "$LOG" && ok "_alert 1st call: failed send logged as NOT marking cooldown" || bad "_alert 1st call: missing 'cooldown NOT marked' log line"
  _alert "gc binary provenance" "still absent, retry should succeed now"
  [ -s "$MAILSENT40" ] && ok "_alert 2nd call, same subject: mail sent (prior FAILED attempt did not block the retry)" || bad "_alert 2nd call: mail wrongly suppressed after a prior failed attempt"
  DPW_ALERT_WINDOW_SEC=0

  echo "Scenario 41 (ga-95bi4 gate-fix): presence-drift's OWN per-label cooldown (_pd_last_set) — same class of bug, same fix"
  : > "$LOG"; rm -rf "${STATE}.presence-drift"; DPW_CRITICAL="$ALL"; DPW_PRESENCE_DIRS="$PDIR"; DPW_TEST_LOADED="com.gascity.epsilon"   # delta undeployed
  MAILSENT41="$TMP/mailsent41"; : > "$MAILSENT41"
  GCCALLS41="$TMP/gccalls41"; : > "$GCCALLS41"
  cat > "$TMP/gc" <<GCSTUB41
#!/usr/bin/env bash
if [ "\$1" = "mail" ]; then
  echo x >> "$GCCALLS41"
  n=\$(wc -l < "$GCCALLS41" | tr -d ' ')
  [ "\$n" -eq 1 ] && exit 1   # 1st send attempt fails
  echo "\$*" >> "$MAILSENT41"
  exit 0
fi
exit 0
GCSTUB41
  chmod +x "$TMP/gc"
  DPW_TEST_NOW=2000000000
  run_presence_drift_sweep >/dev/null 2>&1
  [ ! -s "$MAILSENT41" ] && ok "1st drift sweep, gc mail send FAILS: no mail recorded as sent" || bad "1st drift sweep: mail unexpectedly recorded despite stub failing"
  grep -q "cooldown NOT marked" "$LOG" && ok "1st drift sweep: failed send logged as NOT marking per-label cooldown" || bad "1st drift sweep: missing 'cooldown NOT marked' log line"
  DPW_TEST_NOW=2000000010   # 10s later — still well inside the 10800s cooldown IF it had been (wrongly) marked
  run_presence_drift_sweep >/dev/null 2>&1
  [ -s "$MAILSENT41" ] && ok "2nd drift sweep, same persisting drift: mail sent (prior FAILED attempt did not block the retry)" || bad "2nd drift sweep: mail wrongly suppressed after a prior failed attempt"
  : > "$MAILSENT41"
  DPW_TEST_NOW=2000000020
  run_presence_drift_sweep >/dev/null 2>&1
  [ ! -s "$MAILSENT41" ] && ok "3rd drift sweep, same persisting drift: mail suppressed (per-label cooldown correctly armed after a confirmed successful send)" || bad "3rd drift sweep: mail wrongly re-sent — per-label cooldown not armed after a successful send"
  unset DPW_TEST_NOW
  DPW_PRESENCE_DIRS=""

  echo ""
  echo "daemon-presence-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep
run_recycle_sweep
run_presence_drift_sweep
