# Flow Ledger + Stall-Episode Schema — imp04

> Bead: **imp04** | Epic: imparável (99%-unstoppable pipeline)
> Purpose: append-only on-disk flow ledger + stall-episode schema — the measurement
> backbone that MUST survive a Dolt outage.
> Written: 2026-06-23

---

## 1. Why This Exists

The unstoppability metric must be measured from **outside** the bead substrate (Dolt)
so a Dolt hang never blinds or stalls the instrument itself. This bead builds the
shared append-only JSONL infrastructure and the episode schema. Later beads reuse it:
- **imp02** — human-touch events via `gc_ledger_append("flow-ledger", ...)`
- **imp24** — heal-wiring reads episodes to decide actions
- **imp25** — 7-day soak reads aggregated snapshots for the unstoppability metric

---

## 2. Ledger Location (STABLE — do not change)

```
/Users/athos/gt/.gascity-gastown-hq/.gc/logs/flow-ledger.jsonl
```

Environment override: `GC_LEDGER_DIR` (default: the path above minus the filename).

---

## 3. Shared Ledger Helper (imp02/imp24/imp25 import by these exact names)

### 3.1 Bash

**Script:** `scripts/gc-ledger.sh`

```bash
# Source:
source /Users/athos/gt/.gascity-gastown-hq/scripts/gc-ledger.sh

# Append one line:
gc_ledger_append "flow-ledger" '{"ts":"2026-06-23T10:00:00Z","event":"test"}'

# Or as a standalone binary:
gc-ledger.sh flow-ledger '{"ts":"2026-06-23T10:00:00Z","event":"test"}'
```

Public function signature:
```
gc_ledger_append <ledger-name> <json-string>  →  0 on success, 1 on error
```

### 3.2 Python

**Module:** `scripts/gc_ledger.py`

```python
# Import:
import sys
sys.path.insert(0, "/Users/athos/gt/.gascity-gastown-hq/scripts")
from gc_ledger import gc_ledger_append, LEDGER_DIR, ledger_path

# Append:
gc_ledger_append("flow-ledger", {"ts": "2026-06-23T10:00:00Z", "event": "test"})

# Or with pre-serialized JSON string:
gc_ledger_append("flow-ledger", '{"ts":"2026-06-23T10:00:00Z","event":"test"}')

# fail_open mode (never raises):
gc_ledger_append("flow-ledger", {...}, fail_open=True)
```

Public API:
- `gc_ledger_append(ledger_name, data, *, fail_open=False) -> None`
- `LEDGER_DIR: str`
- `ledger_path(ledger_name: str) -> str`

### 3.3 Atomicity Guarantee

Both implementations use a **single O_APPEND write** per call. On POSIX/macOS,
`write()` to an `O_APPEND` fd is atomic for sizes ≤ PIPE_BUF (64KiB). JSON lines
are well under 4KiB. No lock files, no partial lines possible under concurrent callers.

### 3.4 Dolt Independence

The WRITE path **never calls** `bd`, `gc`, `dolt`, or any network service. The ledger
survives total Dolt outages.

---

## 4. Line Schemas

### 4.1 Per-Interval Snapshot (written by flow-ledger-collector.sh)

```json
{
  "ts":         "2026-06-23T10:00:00Z",
  "kind":       "interval_snapshot",
  "dispatched": 3,
  "merged":     1,
  "refined":    2,
  "backlog":    7
}
```

Fields:
| Field        | Type | Meaning |
|--------------|------|---------|
| `ts`         | ISO8601Z | Snapshot timestamp |
| `kind`       | `"interval_snapshot"` | Fixed discriminator |
| `dispatched` | int ≥ 0 | # Pilot dispatch events in window (from pilot log) |
| `merged`     | int ≥ 0 | # Gate PASSED events in window (from gate log) |
| `refined`    | int ≥ 0 | # Refino APPROVED events in window (from refino log) |
| `backlog`    | int ≥ 0 | Most recent candidate count from pilot log |

Count method: log-file grep only. **Never from Dolt.** Unreadable log = 0 (fail-open).

### 4.2 Per-Bead Transition (written by imp02, imp24, and other daemons)

```json
{
  "ts":            "2026-06-23T10:05:30Z",
  "kind":          "bead_transition",
  "bead_id":       "ga-abc1",
  "stage":         "executa",
  "from_state":    "in-flight",
  "to_state":      "open",
  "actor":         "mayor",
  "source_daemon": "funnel-flow-healer",
  "resolution":    "human_technical"
}
```

Fields:
| Field           | Type | Meaning |
|-----------------|------|---------|
| `ts`            | ISO8601Z | Transition timestamp |
| `kind`          | `"bead_transition"` | Fixed discriminator |
| `bead_id`       | str | Bead identifier (e.g. `ga-abc1`) |
| `stage`         | str | Pipeline stage (see valid values below) |
| `from_state`    | str | Previous state label |
| `to_state`      | str | New state label |
| `actor`         | str | Agent/human who triggered it |
| `source_daemon` | str | Daemon or script that wrote this line |
| `resolution`    | str? | If present, closes the open episode for this stage |

---

## 5. Stall-Episode Schema

Produced by `flow-episode-reconstruct.py` — reads ONLY the flat ledger (zero Dolt).

```json
{
  "episode_id":   "ep-executa-1750672800",
  "stage":        "executa",
  "start_ts":     "2026-06-23T10:00:00Z",
  "end_ts":       "2026-06-23T10:10:00Z",
  "duration_sec": 600,
  "resolution":   "auto_resolved"
}
```

Fields:
| Field          | Type | Meaning |
|----------------|------|---------|
| `episode_id`   | str  | Stable ID: `ep-<stage>-<start_epoch_sec>` |
| `stage`        | str  | Pipeline stage where the stall occurred |
| `start_ts`     | ISO8601Z | First observation of the stall |
| `end_ts`       | ISO8601Z or null | When resolved; null = still_open |
| `duration_sec` | int or null | Duration in seconds; null = still_open |
| `resolution`   | str  | How it resolved |

### 5.1 Valid stage values

| Stage           | Meaning |
|-----------------|---------|
| `tria`          | Intake / triage |
| `refina`        | Refinement (refino gate) |
| `aprova`        | Approval (story:approved) |
| `executa`       | Execution / dispatch stall |
| `revisa`        | Review / gate stall |
| `delivery`      | Merge / delivery stall |
| `crew-liveness` | A crew is unreachable |
| `dolt`          | Dolt data-plane stall |
| `disk`          | Disk pressure |
| `quota`         | Claude quota limit |

### 5.2 Valid resolution values

| Resolution         | Meaning |
|--------------------|---------|
| `auto_resolved`    | Flow resumed on its own (metric went non-zero) |
| `human_product`    | Athos made a product decision |
| `human_technical`  | Mayor or Athos fixed an infra issue |
| `agent_healed`     | A healing daemon (imp24) fixed it |
| `still_open`       | Episode is ongoing at ledger read time |
| `external`         | External factor (network, GitHub, etc.) |

---

## 6. Components

| File | Location | Purpose |
|------|----------|---------|
| `gc-ledger.sh` | `scripts/` | Bash ledger helper |
| `gc_ledger.py` | `scripts/` | Python ledger helper |
| `flow-ledger-collector.sh` | `scripts/` | Per-interval snapshot collector |
| `flow-ledger-collector.plist` | `scripts/` | launchd descriptor |
| `flow-episode-reconstruct.py` | `scripts/` | Episode reconstruction |

### 6.1 Launchd Job

Label: `com.gascity.flow-ledger-collector`
Cadence: every 300s (5 min)
Log output: `.gc/logs/flow-ledger-collector-launchd.{out,err}`

To install:
```bash
CITY=/Users/athos/gt/.gascity-gastown-hq
cp "$CITY/scripts/flow-ledger-collector.plist" \
   "$HOME/Library/LaunchAgents/com.gascity.flow-ledger-collector.plist"
launchctl bootstrap gui/$(id -u) \
   "$HOME/Library/LaunchAgents/com.gascity.flow-ledger-collector.plist"
```

Add `com.gascity.flow-ledger-collector` to `DPW_CRITICAL` after Mayor deploys.

---

## 7. Episode Reconstruction Usage

```bash
# Show all episodes (human table):
python3 scripts/flow-episode-reconstruct.py

# Show only open episodes:
python3 scripts/flow-episode-reconstruct.py --open-only

# JSON output (for imp24/imp25):
python3 scripts/flow-episode-reconstruct.py --json

# Custom ledger path:
python3 scripts/flow-episode-reconstruct.py --ledger /path/to/flow-ledger.jsonl

# Self-test:
python3 scripts/flow-episode-reconstruct.py --selftest
```

---

## 8. Selftest Results (as of 2026-06-23)

| Script | PASS | FAIL |
|--------|------|------|
| `gc-ledger.sh --selftest` | 9 | 0 |
| `gc_ledger.py --selftest` | 9 | 0 |
| `flow-ledger-collector.sh --selftest` | 8 | 0 |
| `flow-episode-reconstruct.py --selftest` | 10 | 0 |

---

## 9. Design Decisions

**Why a flat JSONL file?** It survives Dolt outages, is appendable from bash and Python
without a driver, is readable with `tail -f` and `jq`, and can be rotated by logrotate.

**Why O_APPEND?** POSIX guarantees atomicity for single writes ≤ PIPE_BUF. No locking
needed. Both bash (`printf >> file`) and Python (`os.open(..., os.O_APPEND)`) use this.

**Why log-file grep for counts?** The pilot/gate logs are written independently of Dolt
and are always available. This keeps the write path 100% Dolt-independent.

**Why no heal actions here?** imp04 is measurement only. imp24 is heal-wiring. Mixing
them would couple the instrument to the actuator.

**define-before-use discipline:** All shell variables declared before first use. This
was learned from the Pilot crash on 2026-06-23 (ga-yx2d1: `set -u` + define-after-use
caused a crash loop when `_ttl_recover_db` was called before its variables were set).
