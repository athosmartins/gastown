# Pipeline Resilience — Per-Rig Stall Detection + Pool-Dead Alarm

**Date:** 2026-06-27
**Goal:** Make the Gas Town dev/build pipeline provably unstoppable 24/7 by closing the gap
that let it sit **silently** dead for 5h on 2026-06-27 — without the blast radius of a new
daemon or a synthetic canary.

**Scope:** the dev/build pipeline only (`story: approved → dispatched → built → /gate-done →
gate review → merged → done`). The WA domain collectors/scrapers keep their own ~20
`com.whatsapp.*` monitors. This spec does **not** touch them.

**Approach (validated):** 3 surgical edits (+1 optional) to **existing** watchdogs that are
already DPW-watched and already coordinate via `flow-authority.json`. **Not** a new daemon,
**not** a synthetic canary — both were designed, adversarially reviewed, and rejected (see
§ Alternatives Rejected).

---

## 1. The incident this prevents

On 2026-06-27 the ephemeral `wa-worker` pool spawned workers that **drained without building**
(beads dispatched, `in_progress`, no branch, for 5h). Roughly 25 resilience daemons missed it
because they watch **components** ("is the daemon alive?", "is the gate queue moving?") and
**proxies** ("dispatch count > 0"), never **end-to-end per-rig completion**. Athos had to
notice manually. "All organs healthy, patient dead."

## 2. Findings that shape the design (evidence-grounded)

**Coverage map (file:line verified):**
- **No daemon ALERTS "a worker pool is dispatched-but-producing-nothing."** `inflight-reclaim-guard.py`
  already computes the exact signal (in-flight + dead/stale session + **no branch**,
  `:28-39`, `:553-574`) but acts **per-bead and silently** (reclaims; only escalates ONE bead
  after 3 thrashes, notify-only, no Mayor mail `:730`). A whole pool dying reads as ordinary churn.
- **TSW's per-rig granularity is fake.** `throughput-stall-watchdog.py` iterates rig stores but
  **sums `merge_count` into one global count** (`:510`, `:530`); STALL keys on the global
  `merge_count == 0` (`:44`). Its own header documents today's outage (`:92-96`): *"the 2 merges
  from 5h ago kept merge_count>0 → no alarm."* The applied fix only tightened the window 6h→4h —
  the **cross-rig masking is still live** (any HQ merge masks a dead WA pool).
- `pool-autoscale-watchdog.py` is the only per-pool daemon, but it's **demand-driven** and
  explicitly drops `story:in-flight`/`pilot:dispatched` beads (`:138-153`) → structurally blind
  to "claimed work not progressing," and only manages `gastown.dog` (`:39`), not `wa-worker`.
- `flow-authority.json` is a **single global 2h mutex**; the `dimension` field is written
  (always `"throughput"`, `:982`) but never read — readers gate only on `expires_at`. No per-rig
  signal can be expressed.
- The escalation tier (`agent-stuck-escalation.sh:72`, `quorum-convergence-watchdog.py:238`)
  calls `bd list` with **no `-C`** → HQ-store-blind to WA/PS.

**Data (re-derived from 485 clean gate events, 2026-06-04…27):**
- Real `marker→merged` wall-clock: **p50 42min, p95 401min (6.7h), p99 570min** — NOT the
  ~13min cited earlier (that was the reviewer-compute slice `elapsed_s`; the *queue wait* is ~90%
  of the transit).
- Distributions are **non-stationary** — per-day medians swing ~80× (T3 daily median
  5min → 447min → 10min). **Any fixed AGE threshold false-alarms on backlog days or misses on
  fast days.**
- **Decisive finding:** on the worst backlog day (06-08) per-marker *age* p50 was 447min, yet the
  max gap between consecutive PASS merges was only **63min** — throughput never stalled, the queue
  was just deep. **→ The detector must watch PROGRESS (is the pipeline still completing things in a
  window?), demand-gated, with hysteresis — never per-bead AGE.**
- Cadence floor (sum of sweeps: pilot 300s + gate-guard 120s + gate-dispatcher 180s + delivery
  300s) = **15min worst-case, ~7.5min avg**. Nothing completes faster.

## 3. The changes

### Change 1 (keystone) — `scripts/throughput-stall-watchdog.py`: per-rig stall decision

- **Now:** `merge_signal` (`:510-530`), `backlog_signal`, `dispatch_signal` aggregate cross-rig
  into one count; `STALL = global backlog≥MIN AND merge_count==0` over `STALL_HOURS` (`:44`).
- **Change:** keep **per-rig dicts** `{rig: count}`. `STALL` fires if **ANY** rig has
  `backlog[rig] >= BACKLOG_MIN AND merge[rig] == 0` over the window. Tag the offending rig into the
  flow-authority `dimension` (`throughput:<rig>`) so the field finally carries signal.
- **Why:** a dead `wa-worker` pool → `whatsapp_automation` rig `merge==0` *with* WA backlog →
  fires even while HQ merges. **Would have caught 2026-06-27 at this edit alone.**
- **Window:** keep `STALL_HOURS=4` — TSW is *already* progress-based (`merge_count==0` over a
  window); the per-rig split is the fix, the window is sound.
- **Risk/mitigation:** a rig with legitimate approved backlog but intentionally **paused** must not
  false-alarm. Skip **suspended** rigs (`gc rig status`), keep the existing brake-label exclusions
  (`gate:needs-human`, `exec:manual`, `blocked`, `story:in-flight`), and only count a rig that has
  live builder demand. Keep `CONFIRM_SWEEPS=2` + cooldown unchanged.
- **Tests:** extend the existing selftest (31 scenarios today): (a) one rig stalls while another
  merges → STALL fires (cross-rig flow no longer masks); (b) suspended rig with backlog → no alarm;
  (c) all rigs merging → healthy.

### Change 2 — `scripts/inflight-reclaim-guard.py`: pool-level `[POOL-DEAD]` alert

- **Now:** per in-flight bead it computes `has_recent_branch` + session staleness (`:28-39`,
  `:553`), reclaims silently, escalates one bead after 3 thrashes (notify-only).
- **Change:** in `run_cycle` (`:781`), **bucket** the zombie beads (no branch + dead/stale session +
  stranded > `RECLAIM_TTL`) by **pool/assignee prefix** (`wa-worker`, `gastown.dog`/`dog-*`, named
  crews). If **≥ `IRG_POOL_DEAD_MIN` (default 3)** beads from the **same pool** are simultaneously
  zombie, emit **one** `[POOL-DEAD]` alert with **`gc mail mayor`** (+ notify p4) **before** the
  per-bead reclaim. Per-pool cooldown (~30min) so it doesn't re-alert every cycle.
- **Why:** the missing "pool produces nothing" alarm — today's exact failure, at pool altitude,
  reusing logic already in the file.
- **Bounds:** `IRG_POOL_DEAD_MIN=3` (a single slow bead ≠ a dead pool; 3 simultaneous from a
  4-slot pool is). Require the **existing** zombie criteria (a legit build has a live session OR a
  branch, so it's excluded). Hysteresis: alert only after the pool is zombie for **2 consecutive
  cycles**.
- **Tests:** extend the reclaim-guard selftest: 3 same-pool zombies → one POOL-DEAD mail; mixed
  pools below threshold → no alarm; live-session/branch beads → never counted.

### Change 3 — progress-based, demand-gated bounds (no age thresholds)

The data proves age thresholds are wrong. Codify progress-based bounds (env-tunable; data basis
recorded):
- **T1 approved→dispatched:** `>30min` approved + unblocked + no-builder while pilot alive and a
  builder idle. *(Basis: pilot 300s floor × ~6 + 2-sweep hysteresis; exact approved-ts is
  unmeasurable, so gate on "undispatched + capacity idle," not age.)*
- **T2 dispatched→built:** `>240min` in-flight + **no branch** + no new commits + crew dead/idle.
  *(Basis: healthy build p90≈48 / p95≈71min; full set contaminated — use a generous ceiling + the
  no-branch+dead-crew qualifier, which is the real signal. This is the same primitive as Change 2.)*
- **T3 gate marker→merged:** **0 PASS-merges in `165min` while a marker stays queued**, dispatcher
  alive, not quota-limited, no active reviewer — **progress, not age.** *(Basis: active inter-merge
  gap p95=127 / p99=240min → 165 clears p95, sits below p99.)* This is exactly the shape the
  deployed `gate-throughput-stall-watchdog.sh` already uses; **tune its window `120→165min`**.
- **T4 merged→closed:** `>60min` gate:passed-but-open while `story-delivery` alive. *(Basis:
  healthy p99≈92min; delivery 300s + janitor 900s.)*
- **T5 end-to-end:** no auto-alarm; `>24–48h` dispatched-not-done → human-review queue (SLO
  backstop, not a stall trigger).

### Change 4 (optional) — multi-store `-C` for `agent-stuck-escalation.sh` + `quorum-convergence-watchdog.py`

One-line-per-file: loop `bd list` over HQ/WA/PS stores (mirror the multi-store pattern in
`lifecycle-coherence-janitor.sh:71`). Closes the HQ-blind gap so the escalation tier sees WA/PS
stalls.

### Detection-latency layering (how the two main changes combine)

The two detectors fire at different speeds **by design** — fast specific + slow broad:
- **Change 2 `[POOL-DEAD]` is the FAST path (~15–45min):** it trips when ≥3 beads from one pool
  are zombie (no branch + dead session + stranded > `RECLAIM_TTL` ≈ 25min) for 2 cycles. This is
  today's exact failure class (a pool that claims but never builds) and it pages within tens of
  minutes — the real "imparável" win.
- **Change 1 per-rig STALL is the SLOW broad backstop (~4–5h):** `merge[rig]==0` over the 4h
  window catches *any* rig-level throughput death (not just a pool-build failure) — including modes
  Change 2 can't see (e.g. everything dispatched fine but the gate never merges for that rig). 4h
  is intentionally generous: the data's active inter-merge p99 is 240min, so a tighter per-rig
  merge window would false-alarm on a legitimately deep queue.

So today's outage is caught **fast by Change 2 (~30min)**; Change 1 is the cross-cutting net for
the failure modes a pool-build probe is blind to. Neither relies on per-bead age.

## 4. Self-heal + escalation (existing machinery, unchanged)

- **No new kickstarts.** The new signals are **detect-and-alert**; they feed the existing
  `flow-authority.json`-coordinated healer (`funnel-flow-healer.sh`), which performs bounded
  remediation and already escalates to Mayor after futile attempts.
- **Self-heal, alert-if-stuck** (the chosen policy) is preserved: existing healers self-recover;
  the per-rig STALL + `[POOL-DEAD]` provide the **hard silence ceiling** — Athos is always paged
  when the pipeline is not completing work for a rig/pool and it hasn't recovered.
- Per-rig flow-authority `dimension` lets the healer and the watchdogs avoid fighting on a
  *specific* rig instead of a single global mutex.

## 5. Alternatives rejected (so this isn't re-proposed)

- **Synthetic pipeline canary** (inject a throwaway bead through the real pipeline every ~30min):
  **REJECTED** after 3 independent adversarial reviews. (a) A trivial canary has no domain
  keywords → routes to the `gastown.dog` pool, **not** `wa-worker` → it would have ridden GREEN
  through today's outage. (b) Canary merges every 30min keep TSW's `merge_count > 0` **forever** →
  it *blinds* the very detectors it's meant to complement. (c) The "gate fast-path" trusts a
  forgeable `canary` label/branch/`created_by` → **unreviewed-merge-to-main security hole**.
  (d) Its stuck bead triggers a **heal-storm** across 5–6 existing guards (one *spawns a repair
  agent* for an `echo OK` bead); its own kickstarts can *cause* outages. (e) ~48 echo-OK merges/day
  pollute `main` forever. Not salvageable.
- **New "Pipeline-Sentinel" daemon:** **REJECTED.** Duplicates primitives that already exist
  (branch-existence, pool-session enumeration, per-rig loops), adds a new participant to an
  already-too-coarse coordination lock, and adds a new DPW crash-loop/heartbeat surface. The gaps
  close with edits to daemons that are **already** watched, **already** alert, and (TSW) **already**
  hold flow-authority.
- **Age-based per-stage SLAs:** **REJECTED** by the data — 80× daily swing means fixed age
  thresholds false-alarm on backlog days. Use progress/demand-gated detection.

## 6. Rollout & safety

- **Env kill-switches** on each new behavior (`TSW_PER_RIG=1` default-on, `IRG_POOL_DEAD_MIN=3`,
  `GTSW_STALL_MINUTES=165`). Fail-open; revert by env, no redeploy.
- Land **behind extended selftests** (TSW, reclaim-guard). Deploy in-place (daemons re-read their
  script each run; TSW/reclaim-guard already DPW-watched).
- **Backtest acceptance:** confirm both Change 1 (WA `merge==0` + WA backlog) and Change 2
  (wa-worker zombies ≥3) **would have fired** during the 2026-06-27 window from the historical logs.

## 7. Out of scope (explicit)

- The gate's own queue/ceiling problem (markers serialize behind a dispatcher ceiling; T3 p95=6.7h
  is mostly queue). It has its own watchdogs; a faster gate is a separate, data-justified follow-up.
- Speeding up the 15-min cumulative sweep floor (would tighten the silent ceiling; separate change).
- The WA domain daemons (their own monitors).
