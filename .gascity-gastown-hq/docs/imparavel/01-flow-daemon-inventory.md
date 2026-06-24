# Flow-Daemon Inventory — imp01

> Bead: **imp01** | Epic: imparável (99%-unstoppable pipeline)
> Purpose: ground-truth map for imp14 (consolidation into a single flow-authority)
> Written: 2026-06-23

---

## 1. Daemon Inventory

### 1.1 throughput-stall-watchdog.py
**Script:** `.gascity-gastown-hq/scripts/throughput-stall-watchdog.py`
**Plist:** `com.gascity.throughput-stall-watchdog`
**Cadence (launchd):** KeepAlive=true, ThrottleInterval=600s; **internal loop: POLL_SEC=1800s (30min)**
**Born:** 2026-06-23 (written specifically to fix the 13h stall blind spot)

#### Trigger condition
```
backlog_count >= TSW_BACKLOG_MIN  AND  dispatch_count == 0  AND  merge_count == 0
```
All three signals evaluated over a rolling `TSW_STALL_HOURS` window (default 6h):
- **Backlog signal:** `bd list -l story:approved --status open` + `bd list -l ctx:ready --status open` across all `TSW_RIG_ROOTS` (HQ + WA + PS), minus beads carrying `gate:needs-human | exec:manual | blocked | story:in-flight | pilot:dispatched | pilot:dispatching | story:done`.
- **Dispatch signal:** count of `"Pilot sweep complete: dispatched=N"` (N>0) lines in `pilot-dispatcher.log` within the window.
- **Merge signal:** count of `"Gate PASSED"` lines in `quality-gate-dispatcher.log` + `git log --since` commits to `origin/main` on each rig root.

#### Constants / env-knobs
| Variable | Default | Meaning |
|---|---|---|
| `TSW_ENABLED` | `1` | Kill switch |
| `TSW_DRY_RUN` | `0` | Dry-run mode |
| `TSW_STALL_HOURS` | `6` | Rolling window (hours) |
| `TSW_BACKLOG_MIN` | `1` | Min ready beads to consider a stall |
| `TSW_CONFIRM_SWEEPS` | `2` | Consecutive stall sweeps before escalating |
| `TSW_COOLDOWN_SEC` | `21600` | 6h re-escalation cooldown |
| `TSW_POLL_SEC` | `1800` | Internal sleep cadence |
| `TSW_BD_TIMEOUT` | `25` | bd subprocess timeout (s) |
| `TSW_GIT_TIMEOUT` | `30` | git subprocess timeout (s) |
| `TSW_LOG_TAIL` | `3000` | Log lines to tail |
| `TSW_MAYOR_ADDR` | `mayor` | Escalation recipient |
| `TSW_RIG_ROOTS` | `gt:gt/whatsapp_automation:gt/property_scrapers` | Rigs for backlog + git scan |

**State:** persisted in `.gc/throughput-stall-watchdog-state.json` (keys: `pending`, `last_escalate`, `escalations`).

#### Escalation targets
1. `gc mail send mayor` — durable mail with backlog count, hours since last dispatch/merge, top-5 starved bead ids
2. `notify -p 4` — high-priority ntfy to Athos

#### Actions vs observe-only
**ACTIONS:** escalates (mail + notify) on confirmed stall. No kickstart, no data mutations.

#### Fail-open / fail-closed on each signal
- Pilot log empty/missing → **fail-open** (treated as dispatched, stall counter reset)
- Gate log + git both unreadable → **fail-open** (treated as merged, stall counter reset)
- All bd queries fail → **fail-open** (treated as backlog=0, stall counter reset)
- Any single rig bd failure → skip that rig, continue (not fatal)

---

### 1.2 production-stall-watchdog.py
**Script:** `.gascity-gastown-hq/scripts/production-stall-watchdog.py`
**Plist:** `com.gascity.production-stall-watchdog`
**Cadence (launchd):** KeepAlive=true, ThrottleInterval=300s; **internal loop: POLL_SEC=1500s (25min)**
**Born:** 2026-06-18 (WA root AHEAD of origin/main silently stalled deploys for 2h)

#### Trigger conditions (3 independent dimensions)
**dim-1 DEPLOY-BLOCK:** `git rev-list --left-right --count origin/main...HEAD` → ahead >= `PROD_STALL_MIN_AHEAD` (default 1) on any rig root. Also flags true divergence (ahead > 0 AND behind > 0).

**dim-2 MERGE-STALL:** `quality-gate-dispatcher.log` has no `"Gate PASSED"` or `"merged sha="` line within `PROD_STALL_MERGE_SEC` (default 3h = 10800s) AND the latest `"Found N queued marker(s)"` shows `queued > 0`. Requires dispatcher log is fresh (within `LOG_FRESH_SEC` = 1800s).

**dim-3 STUCK-EXEC:** any bead returned by `bd list --status in_progress` has `updated_at` older than `PROD_STALL_STUCK_SEC` (default 8h = 28800s).

#### Constants / env-knobs
| Variable | Default | Meaning |
|---|---|---|
| `PROD_STALL_WATCHDOG_ENABLED` | `1` | Kill switch |
| `PROD_STALL_POLL_SEC` | `1500` | Internal cadence (25min) |
| `PROD_STALL_MIN_AHEAD` | `1` | Min unpushed commits for deploy-block |
| `PROD_STALL_MERGE_SEC` | `10800` | 3h merge stall threshold |
| `PROD_STALL_LOG_FRESH_SEC` | `1800` | Dispatcher log freshness window |
| `PROD_STALL_STUCK_SEC` | `28800` | 8h stuck-exec threshold |
| `PROD_STALL_CONFIRM_TICKS` | `2` | Consecutive detections before escalating |
| `PROD_STALL_COOLDOWN_SEC` | `10800` | Per-dimension 3h re-escalation cooldown |
| `PROD_STALL_FETCH_TIMEOUT` | `30` | git fetch timeout (s) |
| `PROD_STALL_MAYOR_ADDR` | `mayor` | Escalation recipient |
| `PROD_STALL_RIG_ROOTS` | same 3 rig roots | For deploy-block dimension |

**State:** in-memory dict per-dimension (`last_escalate`, `escalations`, `pending`) — lost on process restart.

#### Escalation targets
1. `gc mail send mayor` — durable mail with dimension, reason, and runbook
2. `notify -p 4` — ntfy to Athos

#### Actions vs observe-only
**ACTIONS:** escalates (mail + notify). No kickstart, no data mutations.

#### Fail-open / fail-closed on each signal
- git fetch/rev-list fails on a rig → skip that rig (not flagged — **fail-open**)
- Dispatcher log missing or stale → **fail-open** (merge-stall dimension returns None)
- `bd list in_progress` fails → **fail-open** (stuck-exec returns None)
- Any dimension check throws an exception → treated as healthy (**fail-open**)
- MERGE-STALL: `queued == 0` → explicitly **no alert** ("starved/idle, not merge-stalled")

---

### 1.3 funnel-flow-healer.sh
**Script:** `.gascity-gastown-hq/scripts/funnel-flow-healer.sh`
**Plist:** `com.gascity.funnel-flow-healer`
**Cadence (launchd):** StartInterval=600s (10min). Not KeepAlive — exits and relaunches each run.
**Born:** 2026-06-15 (refino funnel stalled for DAYS with daemons "LOADED, LastExitStatus=0, firing but NO-OP")

#### Trigger conditions (4 "signatures")
A signature fires when: `demand == 1 AND log_frozen == 1` (i.e., the relevant dispatcher log has not been modified in more than its freeze threshold AND there is positive demand upstream).

| Sig | Demand predicate | Log watched | Freeze threshold env-var | Default |
|---|---|---|---|---|
| `auto-refino` | raw-Triagem > 0 OR unrefined > 0 | auto-refino-dispatcher.log | `AUTO_REFINO_FREEZE_MIN` | 15 min |
| `refino-gate` | refino-review > 0 | refino-gate-dispatcher.log | `REFINO_GATE_FREEZE_MIN` | 15 min |
| `gate` | gate-status:queued > 0 | quality-gate-dispatcher.log | `GATE_FREEZE_MIN` | 10 min |
| `pilot` | needs-approval > 0 | pilot-dispatcher.log | `PILOT_FREEZE_MIN` | 15 min |

**NOTE on pilot signature:** demand is `story:needs-approval > 0` — this is the post-approval queue label, NOT `story:approved`. This differs from how throughput-stall-watchdog measures backlog (story:approved + ctx:ready).

#### Constants / env-knobs
| Variable | Default | Meaning |
|---|---|---|
| `FLOW_HEALER_ENABLED` | `1` | Kill switch (census still runs, no remediation verbs) |
| `STALL_CONFIRM_STRIKES` | `2` | Consecutive runs before any kickstart |
| `REMEDIATION_COOLDOWN` | `1800` | Seconds between kickstarts of same component |
| `MAX_REMEDIATIONS` | `3` | Kickstarts before STOP + escalate to Mayor |
| `ESCALATION_NTFY_WINDOW` | `7200` | Seconds post-escalation before human ntfy (2h) |
| `AUTO_REFINO_FREEZE_MIN` | `15` | Auto-refino log freeze threshold |
| `REFINO_GATE_FREEZE_MIN` | `15` | Refino-gate log freeze threshold |
| `GATE_FREEZE_MIN` | `10` | Gate log freeze threshold |
| `PILOT_FREEZE_MIN` | `15` | Pilot log freeze threshold |
| `BD_TIMEOUT` | `25` | bd subprocess timeout |

**State:** persisted in files under `FLOW_HEALER_STATE_DIR` (default `/tmp/funnel-flow-healer.state`): per-sig `strikes`, `remediations`, `last_kick`, `escalated_at`, `ntfyd`. NOTE: `/tmp` is cleared on reboot — state is lost on restart.

#### Escalation targets (ordered: auto-heal first)
1. `launchctl kickstart -k gui/<uid>/<label>` — up to `MAX_REMEDIATIONS` (3) times per sig, with `REMEDIATION_COOLDOWN` between each
2. `gc mail send mayor` — after exhausting kickstarts (durable escalation)
3. `notify -p 5` — last resort, only after Mayor escalation AND `ESCALATION_NTFY_WINDOW` (2h) elapsed without recovery

#### Actions vs observe-only
**ACTIONS (primary):** `launchctl kickstart -k` on each stalled dispatcher daemon. This is the ONLY daemon that takes autonomous remediation actions. Also: `gc mail send mayor` + `notify -p 5` (last resort only).

Also emits observability events to `funnel-flow-healer.jsonl` (census + decisions every 10min).

#### Fail-open / fail-closed on each signal
- bd count returns `"?"` (non-numeric) → treated as **no demand** (fail-safe toward no-action)
- Log file missing → log_age_min returns `999999` (treated as frozen, but demand must also be positive)
- `FLOW_HEALER_ENABLED=0` → census runs, all action verbs suppressed

---

### 1.4 pipeline-throughput-heartbeat.py
**Script:** `.gascity-gastown-hq/scripts/pipeline-throughput-heartbeat.py`
**Plist:** `com.gascity.pipeline-throughput-heartbeat`
**Cadence (launchd):** KeepAlive=true; **internal loop: POLL_SEC=300s (5min)**
**Born:** 2026-06-11 (ga-kcb2b — pilot dispatching-zero + bare-main false-fail + session-rot blind spots)

#### Trigger conditions (4 "kinds")
All checks use **append-only log timestamps and runtime sessions — NOT live Dolt queries** (by design: monitor must not wedge on the data-plane it polices).

**kind `pilot`:** Within `FLOW_WINDOW_SEC` (30min): every completed sweep `dispatched=0` (>= `MIN_PILOT_SWEEPS` = 2), the most recent sweep had `"Dispatch tier: X (N candidate(s))"` with N>0, AND lane slots were free (`small_slots > 0 OR big_slots > 0`). Requires pilot log fresh within `LOG_FRESH_SEC` (600s).

**kind `gate-merge`:** No `"Gate PASSED"` line in `FLOW_WINDOW_SEC` (30min), latest `"Found N queued marker(s)"` shows N>0, no fresh review in progress (`REVIEW_FRESH_SEC` = 2700s), gate headroom decision is not `"DEFER"`. Requires gate log fresh within `LOG_FRESH_SEC` (600s).

**kind `durable`:** Any `"Durable-landing.*(FAILED|not ancestor)"` pattern in gate log within `DURABLE_FAIL_WINDOW_SEC` (30min).

**kind `session-rot`:** Any `gate-reviewer` or `gastown.dog` session with `state=active`, not attached, `last_active` older than `SESSION_ROT_SEC` (7200s = 2h).

#### Constants / env-knobs
All are module-level constants (not env-overridable in production):

| Constant | Value | Meaning |
|---|---|---|
| `POLL_SEC` | `300` | Internal cadence (5min) |
| `FLOW_WINDOW_SEC` | `1800` | Rolling window for flow checks (30min) |
| `MIN_PILOT_SWEEPS` | `2` | Min all-zero sweeps before pilot stall |
| `REVIEW_FRESH_SEC` | `2700` | A review < this old is "legitimately running" |
| `LOG_FRESH_SEC` | `600` | Log freshness threshold for engine-alive check |
| `DURABLE_FAIL_WINDOW_SEC` | `1800` | Lookback for durable-landing failures |
| `SESSION_ROT_SEC` | `7200` | Active-but-frozen session threshold (2h) |
| `REPAIR_COOLDOWN_SEC` | `1200` | Per-kind cooldown between repair spawns (20min) |
| `GLOBAL_SPAWN_COOLDOWN_SEC` | `300` | Anti-swarm: min gap between any two spawns (5min) |
| `ESCALATE_AFTER` | `2` | Unresolved cycles before escalating to Athos |
| `CONFIRM_TICKS` | `2` | Consecutive detections before spawning repair dog |

**State:** in-memory (`state` dict + `tracked` set + `last_global_spawn`) — lost on process restart.

#### Escalation targets (ordered)
1. `gc sling gastown.dog --stdin --json` — routes runbook to dog pool
2. `gc session new gastown.dog --no-attach` — spawns autonomous repair dog
3. `notify -p 3` — info-level ntfy ("repair dog dispatched, you don't need to act")
4. `notify -p 5` — escalation ntfy to Athos after `ESCALATE_AFTER` (2) unresolved cycles

**NOTE:** No `gc mail send mayor`. Mayor is NOT in the escalation path. Athos is the terminal escalation.

#### Actions vs observe-only
**ACTIONS (secondary):** spawns repair dog + routes runbook to gastown.dog pool. The repair dog does the actual fixing (kickstarts, diagnostics). Guarded by: CONFIRM_TICKS (2), live-sibling guard (only 1 repair dog at a time), REPAIR_COOLDOWN_SEC, GLOBAL_SPAWN_COOLDOWN_SEC.

#### Fail-open / fail-closed on each signal
- Pilot log missing/stale → **fail-open** (`pilot_dispatch_stall` returns None)
- Gate log missing/stale → **fail-open** (`gate_merge_stall` returns None)
- `gc session list` fails → returns `[]` → session-rot check returns nothing (fail-open)
- Headroom DEFER in gate log → explicitly suppresses gate-merge stall (conservative)
- Fresh review in progress → explicitly suppresses gate-merge stall

---

## 2. Authority-Election Decision

### 2.1 Authority pick: throughput-stall-watchdog.py

**Elected owner of all "flow stall" escalations.**

**Justification:**
1. **Designed for exactly this purpose.** It was written on 2026-06-23 specifically because the other three daemons all fired on the same 13h stall and produced no escalation — its docstring enumerates each peer's blind spot and closes it.
2. **Most comprehensive stall predicate.** The only daemon that independently cross-checks actual dispatchable backlog (via `bd list` across all 3 rigs) against both dispatch and merge signals. This is the "Pilot can't see the backlog" gap the others all miss.
3. **Correct escalation target.** Mails the Mayor (durable, an active agent) + notify to Athos. The Mayor can investigate and act.
4. **Single shared state file** (`.gc/throughput-stall-watchdog-state.json`) survives restarts. Other Python daemons lose state on restart.
5. **Correctly scoped.** Covers ALL pipeline stages (dispatch + merge) via a single unified predicate, avoiding the partial-stage fragmentation in the others.
6. **Best-designed fail-open semantics.** Every signal independently fails open; it never false-alarms on empty backlog.

### 2.2 Demotions of the other 3

**production-stall-watchdog.py → observability-only, retain deploy-block + stuck-exec dimensions ONLY**
- The `merge-stall` dimension OVERLAPS with throughput-stall-watchdog's merge signal on the same gate log. Demote: strip merge-stall dimension from prod-stall-watchdog, convert it to emit census + JSONL only for that dimension.
- **RETAIN** as observability for: deploy-block (unique: checks git ahead/diverged on rig roots, not covered by TSW) and stuck-exec (unique: checks `bd list --status in_progress` for staleness, not covered by TSW).
- No escalation actions from this daemon for merge-stall after imp14.

**funnel-flow-healer.sh → observability-only census + JSONL; retain kickstart for upstream-only stages**
- The `gate` signature (gate-status:queued + gate log frozen) OVERLAPS with TSW's merge signal AND heartbeat's gate-merge check. The `pilot` signature (needs-approval + pilot log frozen) OVERLAPS with TSW's dispatch signal.
- **Retain kickstart-only** for: `auto-refino` and `refino-gate` signatures — these are UPSTREAM of TSW's window (raw-Triagem → unrefined → refino-review) and TSW has no visibility into them.
- Demote `gate` and `pilot` signatures to NONE/OBSERVE — suppress kickstarts for those two, keep census emission for observability.

**pipeline-throughput-heartbeat.py → observability-only for pilot/gate-merge kinds; retain durable + session-rot**
- The `pilot` kind OVERLAPS with TSW's dispatch signal.
- The `gate-merge` kind OVERLAPS with TSW's merge signal.
- **RETAIN** as active for: `durable` (unique: bare-main durable-landing FAIL pattern, no other daemon watches this) and `session-rot` (unique: live session staleness, not covered by TSW).
- Demote `pilot` and `gate-merge` kinds to emit JSONL observations but suppress repair-dog spawning.

### 2.3 Overlap/dedup problem — top 3 risks

**Risk 1 (highest): double-escalation to Mayor on identical stall — gate-merge + dispatch == 0**
- throughput-stall-watchdog escalates via `gc mail send mayor` after 2 sweeps × 30min = ~60min latency
- production-stall-watchdog (merge-stall dim) escalates via `gc mail send mayor` after 2 ticks × 25min = ~50min latency
- funnel-flow-healer (gate signature) escalates via `gc mail send mayor` after 3 kickstarts × 30min cooldown + 2 strike confirms = ~90min+ latency
- **All three fire at different times on the same 6h stall.** The Mayor receives 2-3 mail threads for the same root cause with no dedup key. Cooldowns are per-daemon and DESYNCED (6h TSW vs 3h prod-stall vs escalate-after-3-kickstarts). A Mayor working the first mail gets spammed by the second and third.

**Risk 2: stacked kickstarts on pilot and gate from two daemons with desynced cooldowns**
- funnel-flow-healer kicks `com.gascity.pilot` (REMEDIATION_COOLDOWN=1800s between kicks, MAX_REMEDIATIONS=3)
- pipeline-throughput-heartbeat spawns a repair dog that also kickstarts the pilot (REPAIR_COOLDOWN_SEC=1200s per-kind)
- These are completely unaware of each other. On a 6h pilot stall: healer kicks 3× over ~90min then escalates; meanwhile heartbeat spawns 1-2 repair dogs that also kickstart it. Up to 5 pilot restarts in the same stall window, each with different cooldown epoch baselines, with no shared state.

**Risk 3: gate-merge false-suppression when both heartbeat and TSW coexist**
- heartbeat's gate-merge check has a `CONFIRM_TICKS=2` guard AND a headroom-DEFER suppressor AND a live-review suppressor (all correct engineering). TSW's merge signal is simpler: just counts "Gate PASSED" lines in window. On a slow-but-draining gate (Dolt CPU 247%, 12min/run), heartbeat's richer guards prevent false fire; TSW may fire because `Gate PASSED` count == 0 in the 6h window is not suppressed by a headroom-DEFER check. This creates a false-positive TSW escalation on a throttled-but-healthy gate while heartbeat is correctly silent.

### 2.4 Shared dedup design for imp14

**Single dedup key:** `flow-stall/<dimension>` where dimension ∈ `{dispatch, merge, deploy-block, stuck-exec, durable, session-rot, auto-refino, refino-gate}`.

**Single strike-counter in TSW state file** (already has `.gc/throughput-stall-watchdog-state.json`): extend to include per-dimension keys so all daemons can read and increment the same counter before escalating. Alternatively: TSW becomes the SOLE escalator; all others write to a shared JSONL observation stream that TSW reads as input signals.

**Single cooldown clock:** TSW's `TSW_COOLDOWN_SEC` (21600s = 6h) becomes the canonical cooldown for Mayor escalations. Other daemons must either defer to TSW or be stripped of their escalation actions.

**Recommended implementation for imp14:**
- TSW state file gains dimension-keyed entries: `{"dispatch": {...}, "merge": {...}, "deploy-block": {...}, "stuck-exec": {...}}`.
- prod-stall-watchdog writes its deploy-block and stuck-exec findings to a shared observation JSONL and TSW reads/merges them.
- funnel-flow-healer continues census JSONL emission for auto-refino/refino-gate; TSW adds those upstream stages to its backlog predicate.
- heartbeat continues emitting durable/session-rot findings; TSW adds those as input signals.
- One escalation path: TSW → Mayor mail + notify. All others: observe-only.

### 2.5 Coverage TSW is currently missing (must not lose in imp14)

| Signal | Current owner | Missing from TSW |
|---|---|---|
| **Deploy-block** (git root ahead/diverged) | production-stall-watchdog.py dim-1 | Yes — TSW reads git log for merge signal but does NOT check `rev-list --left-right HEAD vs origin/main` ahead-count |
| **Stuck-exec** (in_progress bead staleness) | production-stall-watchdog.py dim-3 | Yes — TSW has no `bd list --status in_progress` check |
| **Durable-landing FAIL** (bare-main storm) | pipeline-throughput-heartbeat.py kind=durable | Yes — TSW reads "Gate PASSED" but not `"Durable-landing.*(FAILED\|not ancestor)"` |
| **Session-rot** (frozen ephemeral worker) | pipeline-throughput-heartbeat.py kind=session-rot | Yes — TSW has no `gc session list` check |
| **Auto-refino upstream** (raw-Triagem / unrefined backlog) | funnel-flow-healer.sh sig=auto-refino | Yes — TSW backlog only counts story:approved + ctx:ready, not raw-Triagem |
| **Refino-gate upstream** (story:refino-review backlog) | funnel-flow-healer.sh sig=refino-gate | Yes — TSW backlog doesn't include story:refino-review |
| **Kickstart as first-line auto-remediation** | funnel-flow-healer.sh | TSW has NO kickstart action — it only escalates. TSW must either gain auto-kickstart capability (for auto-refino/refino-gate/gate/pilot) or retain funnel-flow-healer's kickstart for upstream stages |

---

*Document written for imp14 (consolidation). Do not implement changes here — this is read-only inventory.*
