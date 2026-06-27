# Pipeline Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the silent-stall gap (2026-06-27 5h outage) by adding **per-rig** stall detection and a **`[POOL-DEAD]`** Mayor alarm to existing watchdogs, with progress-based (not age-based) bounds.

**Architecture:** Surgical edits to two safety-critical Python daemons — `throughput-stall-watchdog.py` (per-rig STALL) and `inflight-reclaim-guard.py` (pool-dead alert) — plus a one-value window tune to `gate-throughput-stall-watchdog.sh`. No new daemon, no synthetic canary. All daemons re-read their script each launchd run (deploy = in-place), and all are already DPW-watched. TDD via each daemon's existing hermetic `--selftest`.

**Tech Stack:** Python 3 (stdlib only), bash, launchd, `bd`/`gc` CLIs.

## Global Constraints

- **Stdlib only** (no pip). Each daemon stays hermetic-testable via `--selftest` (stubbed I/O seams).
- **Fail-open invariant:** any read error → treat as flow-present, never a false stall. Preserve the existing `_SIGNAL_ERROR = (None, None)` convention in TSW.
- **Env kill-switches, default-on, revertible without redeploy:** `TSW_PER_RIG` (default `1`), `IRG_POOL_DEAD_MIN` (default `3`), gate-throughput window via existing env.
- **Data-derived bounds (verbatim from spec):** per-rig merge window = `STALL_HOURS` (4h, unchanged — TSW is already progress-based on `merge_count`); `POOL_DEAD_MIN=3` + **2-consecutive-cycle hysteresis** + **~30min per-pool cooldown**; gate-throughput-stall window **120 → 165 min**.
- **Detect-don't-reconcile** for the new signals: they `gc mail mayor` + `notify`; they do NOT kickstart/reclaim beyond what the daemon already does. Healing stays with the existing flow-authority-coordinated healers.
- **Commit footer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Sw4aUua6JnoyxYDpYasq2o
  ```
- **Each daemon's `--selftest` must pass before committing** (the TSW selftest had 1 known pre-existing failure unrelated to these changes — Scenario NEW-B's stale grep — do not let a NEW failure hide behind it; compare pass-count to baseline).
- Git root is `/Users/athos/gt`; daemons live under `.gascity-gastown-hq/scripts/`. Use `git -C /Users/athos/gt`.

---

### Task 1: TSW per-rig STALL decision (the keystone)

**Files:**
- Modify: `/Users/athos/gt/.gascity-gastown-hq/scripts/throughput-stall-watchdog.py`
  - `merge_signal` (~`:474-541`) and `backlog_signal` (~`:545-621`): produce **per-rig** results, not one summed count.
  - `run_tick` stall logic (~`:1037-1071`): STALL fires if **any** rig has `backlog[rig] >= BACKLOG_MIN AND merge[rig] == 0`.
  - Docstring (~`:44`) and the flow-authority `dimension` write (~`:982`): `throughput:<rig>`.
- Test: same file, `--selftest` block (scenarios start ~`:1270`).

**Interfaces:**
- Consumes: existing test seams `_git_log_count(root, since_iso)` and `_bd_backlog(root)` — both already **per-root**, so per-rig is testable without new seams. `RIG_ROOTS` (~`:79`) is the rig list.
- Produces: a per-rig STALL verdict. Keep `dispatch_signal` aggregate (context only — flow is already merge-based after the 2026-06-27 fix). Add env `TSW_PER_RIG` (default `1`); when `0`, fall back to the current global behaviour (safe revert).

- [ ] **Step 1: Write the failing selftest scenario** (add near the existing Scenario C, after the merge-flow scenarios). It stubs WA with backlog + zero git-merges and HQ with git-merges, and asserts a stall STILL escalates (cross-rig flow must NOT mask it):

```python
    # ── PR1 (ga-dbibq resilience): per-rig — one rig stalled while another merges → STALL ──
    print("\nScenario PR1: per-rig — WA backlog + 0 WA merges, HQ merging → STALL (no cross-rig mask)")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 2)      # dispatch aggregate irrelevant
    _read_gate_log_lines  = lambda: []                       # no gate-PASSED lines in the log tail
    # git merges only on the HQ root; WA root has zero:
    _git_log_count        = lambda root, since: (3 if ("gascity" in root or root.rstrip("/").endswith(".gascity-gastown-hq")) else 0)
    _bd_backlog           = lambda root: (_backlog(5) if "whatsapp" in root else [])   # only WA has ready backlog
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if st["escalations"] >= 1:
        _ok("PR1: WA stall (backlog + 0 merges) escalates despite HQ merging (cross-rig mask removed)")
    else:
        _bad("PR1", "pending=%d esc=%d — HQ merges masked the WA-rig stall" % (st["pending"], st["escalations"]))

    # ── PR2: per-rig — a rig with backlog but SUSPENDED must NOT false-alarm ──
    print("\nScenario PR2: per-rig — suspended rig with backlog → no alarm")
    _bd_backlog           = lambda root: (_backlog(5) if "whatsapp" in root else [])
    _git_log_count        = lambda root, since: 0            # nobody merging
    # mark WA suspended via the seam the impl must add (see Step 3): _suspended_rigs returns a set
    globals()["_suspended_rigs"] = lambda: {"whatsapp_automation"}
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["_suspended_rigs"] = None
    if not st["escalations"] and not mail_calls:
        _ok("PR2: suspended rig with backlog does not false-alarm")
    else:
        _bad("PR2", "esc=%d mails=%d — suspended rig false-alarmed" % (st["escalations"], len(mail_calls)))
```

- [ ] **Step 2: Run the selftest, verify PR1/PR2 FAIL** (current code is cross-rig + has no suspended-rig seam)

Run: `python3 /Users/athos/gt/.gascity-gastown-hq/scripts/throughput-stall-watchdog.py --selftest 2>&1 | grep -E 'PR1|PR2|passed, .* failed'`
Expected: PR1 fails (cross-rig merge masks the stall → no escalation) and/or PR2 errors (no `_suspended_rigs` seam yet).

- [ ] **Step 3: Implement per-rig.** Read the current `merge_signal`, `backlog_signal`, and the `run_tick` stall block, then:
  1. Add near the env block: `PER_RIG = os.environ.get("TSW_PER_RIG", "1") == "1"` and a `_suspended_rigs` seam: `_suspended_rigs = None` (module-level, like the other `_…` seams) and a helper `def suspended_rigs(): return _suspended_rigs() if _suspended_rigs is not None else _query_suspended_rigs_via_gc()` where the production query runs `gc rig list`/`gc rig status` and returns the set of suspended rig names (fail-open: on error return `set()`).
  2. `merge_signal` → return `(per_rig: dict[str,int] | None, last_epoch)`. Keep the gate-PASSED tally attributed per-rig **only if** a clean rig tag is available in the log line; otherwise fold gate-PASSED into a shared bucket AND keep the **per-root git-commit counts** (already per-root in the loop) as the authoritative per-rig merge signal. Map each `RIG_ROOTS` entry to a rig name (basename or a small lookup). Preserve the fail-open `_SIGNAL_ERROR` path (return `(None, None)` when nothing was readable).
  3. `backlog_signal` → return `(per_rig: dict[str,int], sample_beads)` keyed by the same rig names, using the existing per-root `_bd_backlog`/bd query.
  4. `run_tick` stall block: when `PER_RIG`, compute `stalled_rigs = [rig for rig in backlog_per_rig if backlog_per_rig[rig] >= BACKLOG_MIN and merge_per_rig.get(rig, 0) == 0 and rig not in suspended_rigs()]`. STALL iff `stalled_rigs` is non-empty (and dispatch fail-open guard unchanged). Set the flow-authority `dimension = "throughput:" + stalled_rigs[0]`. Include the rig list in the escalation body. When `not PER_RIG`, keep the existing global path.
  5. Update the docstring (~`:44`) to the per-rig condition.

- [ ] **Step 4: Run the selftest, verify ALL pass** (PR1, PR2, and no regression in the existing scenarios)

Run: `python3 /Users/athos/gt/.gascity-gastown-hq/scripts/throughput-stall-watchdog.py --selftest 2>&1 | tail -3`
Expected: PR1 ✓, PR2 ✓, and `passed` count ≥ baseline (baseline was 31 passed / a small number of pre-existing fails — no NEW failures).

- [ ] **Step 5: Commit**

```bash
git -C /Users/athos/gt add .gascity-gastown-hq/scripts/throughput-stall-watchdog.py
git -C /Users/athos/gt commit -m "$(printf 'fix(tsw): per-rig stall decision — cross-rig merge no longer masks a dead rig/pool (ga-dbibq)\n\nSTALL now fires if ANY rig has backlog>=MIN AND merge==0 (skipping suspended\nrigs), instead of summing merge_count cross-rig. A dead wa-worker pool ->\nwhatsapp_automation merge==0 with WA backlog -> fires even while HQ merges\n(the masking that hid the 2026-06-27 5h outage). TSW_PER_RIG=0 reverts.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01Sw4aUua6JnoyxYDpYasq2o')"
```

---

### Task 2: inflight-reclaim-guard `[POOL-DEAD]` Mayor alert

**Files:**
- Modify: `/Users/athos/gt/.gascity-gastown-hq/scripts/inflight-reclaim-guard.py`
  - `run_cycle` (~`:781`): before the per-bead reclaim loop, bucket zombie beads by pool and emit a pool-level alert.
  - Reuse existing primitives: zombie criteria (dead/stale session + `not has_recent_branch` + stranded > `RECLAIM_TTL`, ~`:28-39`,`:553`), `emit()` (notify), and add a `gc mail mayor` call (the daemon currently has notify-only).
- Test: same file `--selftest`.

**Interfaces:**
- Consumes: the per-bead zombie classification already computed in the cycle (a bead is zombie iff no live session + no recent branch + stranded past TTL). The bead's `assignee` (e.g. `wa-worker`, `wa-worker-adhoc-…`, `dog-…`, `gastown.dog`, a crew name).
- Produces: at most one `[POOL-DEAD]` alert per pool per cooldown window. Add env `IRG_POOL_DEAD_MIN` (default `3`), `IRG_POOL_DEAD_COOLDOWN_SEC` (default `1800`). Per-pool 2-cycle hysteresis state stored alongside the existing state files.

- [ ] **Step 1: Write the failing selftest scenario.** (Mirror the existing reclaim-guard selftest harness — it stubs `bd`/`gc`/session-liveness and asserts on emitted alerts/mail.) Add a pure-predicate test first, then a cycle test:

```python
  echo "Scenario POOL-DEAD-1: 3 same-pool zombies (no branch, dead session) → one [POOL-DEAD] mayor mail"
  # Arrange: 3 in_progress beads assignee=wa-worker, no live wa-worker session, no branch, stranded>TTL.
  # Across 2 cycles (hysteresis). Assert exactly one gc-mail-mayor with [POOL-DEAD] and pool=wa-worker.
  # (use the harness's DPW_TEST_*-style seams already present in this selftest)
```

(Implement using whatever stub mechanism the file's existing selftest already uses — read it first; the assertion is: `grep -c '\[POOL-DEAD\].*wa-worker' "$MAIL_LOG"` == 1 after two cycles, and 0 after one cycle / with a live session / with <3 zombies.)

- [ ] **Step 2: Run the selftest, verify the new scenario FAILS** (no POOL-DEAD logic yet)

Run: `bash -c 'cd /Users/athos/gt/.gascity-gastown-hq && python3 scripts/inflight-reclaim-guard.py --selftest 2>&1 | grep -iE "POOL-DEAD|passed|failed"'`
Expected: POOL-DEAD scenario FAILS (no such alert emitted).

- [ ] **Step 3: Implement the pool-dead aggregation.** Read `run_cycle`, then before the per-bead reclaim:
  1. Add env: `POOL_DEAD_MIN = int(os.environ.get("IRG_POOL_DEAD_MIN", "3"))`, `POOL_DEAD_COOLDOWN = int(os.environ.get("IRG_POOL_DEAD_COOLDOWN_SEC", "1800"))`.
  2. Normalize a bead's pool from its assignee: `wa-worker*` → `wa-worker`; `gastown.dog`/`dog-*` → `gastown.dog`; else the crew name. Helper `_pool_of(assignee)`.
  3. Bucket the **zombie** beads (already classified this cycle) by pool → `counts: dict[pool,int]`.
  4. Per-pool hysteresis: a state file `${STATE}.pool-dead/<pool>` storing `consecutive_cycles` + `last_alert_epoch`. Increment when `counts[pool] >= POOL_DEAD_MIN`, reset to 0 otherwise.
  5. When `consecutive_cycles >= 2` AND `now - last_alert_epoch > POOL_DEAD_COOLDOWN`: emit `[POOL-DEAD] pool=<pool> zombies=<n> (no branch + dead session, stranded > TTL)` via `emit()` **and** `gc mail mayor -s "[POOL-DEAD] <pool> producing nothing" -m "<n> beads dispatched to <pool> are in_progress with no branch and no live worker for >TTL: <ids>. The pool is not building. Existing healers notified via flow-authority."`. Record `last_alert_epoch`. Fail-open on mail failure (log, never crash the cycle).
  6. The existing per-bead reclaim proceeds unchanged afterward.

- [ ] **Step 4: Run the selftest, verify it PASSES** (POOL-DEAD fires after 2 cycles; not after 1; not with a live session; not with <3)

Run: `bash -c 'cd /Users/athos/gt/.gascity-gastown-hq && python3 scripts/inflight-reclaim-guard.py --selftest 2>&1 | tail -3'`
Expected: POOL-DEAD scenarios ✓, no regression in the existing reclaim scenarios.

- [ ] **Step 5: Commit**

```bash
git -C /Users/athos/gt add .gascity-gastown-hq/scripts/inflight-reclaim-guard.py
git -C /Users/athos/gt commit -m "$(printf 'feat(inflight-reclaim-guard): [POOL-DEAD] mayor alert when a whole pool produces nothing (ga-dbibq)\n\nThe guard already detects per-bead zombies (in-flight + dead session + no\nbranch) and reclaims them silently. Now, when >=IRG_POOL_DEAD_MIN (3) beads\nfrom the SAME pool are zombie for 2 consecutive cycles, it mails the Mayor\nONE [POOL-DEAD] alert before reclaim -- the missing "pool builds nothing"\nsignal that left the 2026-06-27 wa-worker outage silent. Per-pool cooldown.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01Sw4aUua6JnoyxYDpYasq2o')"
```

---

### Task 3: Tune gate-throughput-stall window 120 → 165 min

**Files:**
- Modify: `/Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.sh` (the `GTSW_STALL_HOURS`/minutes default) AND/OR the plist env `~/Library/LaunchAgents/com.gascity.gate-throughput-stall-watchdog.plist`.

**Interfaces:** none new — a single threshold value change. Basis: active inter-merge gap p95=127min, p99=240min → 165 clears p95, sits below p99.

- [ ] **Step 1: Find the current window value**

Run: `grep -nE 'STALL_HOURS|STALL_MIN|120|7200' /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.sh | head`
Expected: shows the 2h (120min/7200s) default.

- [ ] **Step 2: Change the default to 165 min** (preserve env override). If the script reads `GTSW_STALL_HOURS` (2), switch to a minutes-based `GTSW_STALL_MINUTES="${GTSW_STALL_MINUTES:-165}"` and update the comparison; if it already uses minutes/seconds, set 165min/9900s. Keep the existing reviewer-active + quota-limited + queue-nonempty guards intact (they suppress the real false alarms).

- [ ] **Step 3: Syntax-check + run the script's selftest if present**

Run: `bash -n /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.sh && echo OK; ls /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.selftest.sh 2>/dev/null && bash /Users/athos/gt/.gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.selftest.sh 2>&1 | tail -3`
Expected: syntax OK; selftest (if any) passes.

- [ ] **Step 4: Commit**

```bash
git -C /Users/athos/gt add .gascity-gastown-hq/packs/town-deltas/assets/gate-throughput-stall-watchdog.sh
git -C /Users/athos/gt commit -m "$(printf 'fix(gate-throughput-stall-watchdog): window 120->165min (data: inter-merge p95=127min)\n\nThe 120min window sat exactly at the active inter-merge p95 (127min), causing\nresidual false alarms on legitimately-deep gate queues. 165min clears p95 and\nsits below p99 (240min). Env override preserved.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01Sw4aUua6JnoyxYDpYasq2o')"
```

---

### Task 4 (optional): multi-store `-C` for the HQ-blind escalation tier

**Files:**
- Modify: `/Users/athos/gt/.gascity-gastown-hq/scripts/agent-stuck-escalation.sh` (~`:72`, the `bd list` with no `-C`)
- Modify: `/Users/athos/gt/.gascity-gastown-hq/scripts/quorum-convergence-watchdog.py` (~`:238`, the `bd list` with no `-C`)

**Interfaces:** none new. Mirror the multi-store loop in `lifecycle-coherence-janitor.sh:71` (iterate HQ + WA + PS store roots, run the existing query per store with `-C`, concatenate results).

- [ ] **Step 1:** Read both call sites + the `lifecycle-coherence-janitor.sh:71` multi-store pattern.
- [ ] **Step 2:** Wrap each `bd list` in a per-store loop (`for root in $HQ $WA $PS; do bd -C "$root" list … ; done`), dedup by bead id. Keep behaviour identical for HQ; just add WA/PS visibility.
- [ ] **Step 3:** Run each daemon's selftest if present (`*.selftest.sh`); else `bash -n` + a dry-run.
- [ ] **Step 4: Commit**

```bash
git -C /Users/athos/gt add .gascity-gastown-hq/scripts/agent-stuck-escalation.sh .gascity-gastown-hq/scripts/quorum-convergence-watchdog.py
git -C /Users/athos/gt commit -m "$(printf 'fix(escalation): make agent-stuck + quorum multi-store (-C HQ/WA/PS), were HQ-blind (ga-dbibq)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01Sw4aUua6JnoyxYDpYasq2o')"
```

---

### Task 5: Backtest acceptance — would these have fired on 2026-06-27?

**Files:** none modified. A throwaway verification script in the scratchpad.

**Interfaces:** none. This is the acceptance gate from the spec (§6).

- [ ] **Step 1: Backtest Change 1 (per-rig TSW).** From the historical gate log + WA bead history around the outage window (≈06-27 12:00–17:00 local), confirm: WA-rig `merge_count == 0` while WA had `story:approved` backlog ≥ 1 — i.e. the per-rig condition would have been TRUE while the global (HQ-including) condition was FALSE.

Run a python check over `.gc/quality-gate.jsonl` (filter `rig`/bead-prefix to WA, count PASS in 4h windows across the outage) + a WA backlog snapshot. Expected: at least one 4h window in the outage where WA PASS==0 AND WA backlog≥1.

- [ ] **Step 2: Backtest Change 2 (POOL-DEAD).** From the pilot log + WA bead history, confirm ≥3 `wa-worker`-assigned beads were simultaneously `in_progress` with no branch and no live `wa-worker` session during the outage (we already established this live earlier in the session — re-confirm from logs).

- [ ] **Step 3: Record the backtest result** as a comment on bead `ga-dbibq` (the WA-pipeline bead): "Resilience backtest: per-rig TSW + POOL-DEAD both would have fired during the 2026-06-27 window (evidence: <counts>)." This closes the loop and documents that the fix is validated against the real incident.

- [ ] **Step 4 (deploy):** Reload the two edited Python daemons so the changes go live (they re-read on next launchd tick, but force it): `launchctl kickstart -k gui/$(id -u)/com.gascity.throughput-stall-watchdog` and `…/com.gascity.inflight-reclaim-guard`. For the gate-throughput env (Task 3), if changed in the plist, `bootout`+`bootstrap`; if in the script, it's picked up on next run. Verify each is loaded + ran clean: `launchctl list | grep -E 'throughput-stall|inflight-reclaim|gate-throughput'`.

---

## Self-Review

- **Spec coverage:** Change 1 → Task 1; Change 2 → Task 2; Change 3 (progress bounds + gate window) → Task 3 (window) and the per-rig/pool logic in Tasks 1–2 (the bounds are realized as the merge-window + zombie criteria, not new age timers, per the data); Change 4 → Task 4; §6 backtest acceptance → Task 5. All covered.
- **Placeholder scan:** the selftest scenario bodies for Task 2 reference "the harness's existing stub mechanism" rather than transcribing it — this is deliberate (the implementer reads the file's selftest first); the *assertion* is concrete (`grep -c '[POOL-DEAD].*wa-worker' == 1`). Task 1 scenarios are complete code. No TBD/TODO.
- **Type/name consistency:** env names (`TSW_PER_RIG`, `IRG_POOL_DEAD_MIN`, `IRG_POOL_DEAD_COOLDOWN_SEC`, `GTSW_STALL_MINUTES`), helper names (`_pool_of`, `suspended_rigs`/`_suspended_rigs`), and the `[POOL-DEAD]` tag are used consistently across tasks and the commit messages.

## Notes for the implementer

- These daemons are **live and safety-critical**. A false `[POOL-DEAD]` pages Athos; a missed stall is a silent outage. Favor the fail-open path on every read error.
- Read each daemon's existing `--selftest` harness **before** writing a new scenario — match its stub style exactly.
- Do **not** refactor beyond the change. The files are large; keep edits surgical.
- After Task 1, the cross-rig masking is gone — but verify the existing 31 TSW scenarios still pass (the per-rig change must not break the global-fallback path when `TSW_PER_RIG=0`).
