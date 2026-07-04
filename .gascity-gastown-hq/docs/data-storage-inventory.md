# Data Storage Inventory — Mac-mini Disk Pressure

**Created:** 2026-07-04 (triggered by near-DISK-HALT event at 97% full)
**DO NOT DELETE ANYTHING** based on this doc alone — it is a reference. Always confirm with Athos before deleting KEEP items.

---

## Quick Summary

| Verdict | Item | Size | Reclaimable |
|---------|------|------|-------------|
| SAFE-TO-DELETE | `shared/data/real_estate_backup.duckdb` + `.tmp.wal` | 7.5G + 18M | ~7.5G |
| SAFE-TO-DELETE | `~/.cache/huggingface/hub/models--BAAI--bge-m3/` | 4.2G | 4.2G |
| ASK-ATHOS | `gt/lexbh/` (suspended rig: venv + old db backups) | 3.1G | ~2.5G |
| KEEP | `gt/whatsapp_automation/processo_lookup/data/processos.db` | 3.7G | 0 |
| KEEP | `shared/data/contagem_lotes.db` | 2.4G | 0 |
| MOVE-OFF-DISK | `gt/.gascity-gastown-hq/.dolt-backup/` | 2.5G | TBD |
| DO NOT TOUCH | `gt/.gascity-gastown-hq/.beads/dolt/hq/.dolt/noms/oldgen/` | 2.1G | 0 |
| KEEP (small) | `shared/data/daemon_monitoring.db` | 116M | 0 |
| KEEP (small) | `shared/data/health.db` | 50M | 0 |
| NOT FOUND | `shared/data/whatsapp_conversations_cold.db` | — | — |

**Safely reclaimable now (zero risk): ~11.7G**
**Potential additional (needs Athos decision): ~2.5G**

---

## Detailed Inventory

### 1. `/Users/athos/shared/data/real_estate_backup.duckdb` — 7.5G (mtime Jun 30)

| Field | Value |
|-------|-------|
| **What** | Local copy of all user tables in MotherDuck `md:real_estate` DB. Excludes 3 oversized/rebuilable tables (`monitoramento_cpf_historico`, `rfb.cnpj_*`). |
| **Writer** | `whatsapp_automation/scripts/backup_motherduck.py` — runs via launchd at 02:30 AM daily |
| **Readers** | `backup_all_dbs.sh` — uploads to `s3://whatsapp-viewer-549710416969/backups/data/` at 03:00 AM |
| **Source of truth** | MotherDuck cloud (`md:real_estate`) |
| **Regenerable?** | YES — `backup_motherduck.py --dry-run` to verify, then run normally (copies ~2:30h) |
| **Type** | BACKUP |
| **Also present** | `real_estate_backup.duckdb.tmp.wal` (18M) — leftover WAL from the Jun 30 backup run; can also be deleted |
| **Verdict** | **SAFE-TO-DELETE** — This is a local backup whose purpose is to feed S3. The S3 copy (7 days retention) is the durable backup. MotherDuck is the source of truth. Deleting the local copy is safe as long as MotherDuck is accessible. The next launchd run (02:30 AM) will recreate it. |
| **Reclaimable** | ~7.5G |

---

### 2. `/Users/athos/gt/whatsapp_automation/processo_lookup/data/processos.db` — 3.7G (mtime Jun 29)

| Field | Value |
|-------|-------|
| **What** | SQLite accumulation of judicial processes scraped from TJSP, TJMG, TRF1, TRT3 and the PDPJ public API. Keyed by CPF. Built up incrementally via Playwright + REST scraping. |
| **Writer** | `processo_lookup/collect.py`, `processo_lookup/pdpj_api.py`, `processo_lookup/batch_collect.py` (all one-shot scripts, not continuous daemons). Scraping requires a valid PDPJ JWT token (~8h validity). |
| **Readers** | Active WA daemons: `daemons/demand_dashboard.py`, `daemons/routes/outreach_queue.py`, `daemons/routes/cls_media.py`, `daemons/admin_dashboard.py` |
| **Source of truth** | PDPJ / Tribunal public APIs (web-scraping; no direct export). Re-collection = hours/days of scraping. |
| **Regenerable?** | PARTIALLY — can re-scrape from public APIs, but requires time, a valid JWT, and no guarantee of getting the same historical records |
| **Type** | PROD data (actively consumed by running daemons) |
| **Backed up to S3?** | NO — `backup_all_dbs.sh` only covers `shared/data/*.db`; this file lives in a subdirectory |
| **Verdict** | **KEEP** — Active daemons query it. Losing it loses all accumulated judicial process data. No S3 backup exists. |
| **Reclaimable** | 0 |

---

### 3. `/Users/athos/.cache/huggingface/hub/models--BAAI--bge-m3/` — 4.2G (mtime Jun 5)

| Field | Value |
|-------|-------|
| **What** | BAAI BGE-M3 multilingual embedding model, downloaded from HuggingFace Hub. Used by the lexbh rig for legal document retrieval and similarity search. |
| **Writer** | HuggingFace Hub auto-download (triggered when lexbh embedding code runs) |
| **Readers** | `lexbh/crew/digo/tools/embedding_ab/index_local.py`, `persist_embeddings.py`, `chunk_index.py`, `lexbh/crew/.gc-worktrees/fix-ga-i5vt/tools/embedding_ab/` |
| **Source of truth** | HuggingFace Hub: `BAAI/bge-m3` (public, freely re-downloadable) |
| **Regenerable?** | YES — `huggingface-cli download BAAI/bge-m3` or any `from_pretrained("BAAI/bge-m3")` call; ~4.2G download |
| **Type** | CACHE (model weights; always re-downloadable) |
| **mtime note** | Last accessed Jun 5 — stale since lexbh was suspended |
| **Verdict** | **SAFE-TO-DELETE** — Pure cache. The lexbh rig is `suspended = true` in `city.toml`. Model will be re-downloaded automatically if/when lexbh resumes. |
| **Reclaimable** | 4.2G |

---

### 4. `/Users/athos/gt/.gascity-gastown-hq/.dolt-backup/` — 2.5G (updated daily)

| Field | Value |
|-------|-------|
| **What** | Dolt "backup sync" archives (.darc files) for all Gas City production databases. Breakdown: `hq/` 2.4G (dominant: one 2.3G base .darc from Jul 2 + smaller incrementals), `whatsapp_automation/` 38M, `gastown/` 26M, `property_scrapers/` 21M, `lexbh/` 640K, `marketing/` 136K, `dc/` 120K. |
| **Writer** | `plugins/dolt-backup/run.sh` + `.gc/system/packs/dolt/assets/scripts/mol-dog-backup.sh` — runs every 6h via `mol-dog-backup` exec order |
| **Readers** | Disaster recovery only (manual `dolt backup restore`) |
| **Source of truth** | Live Dolt server at `~/.dolt-data/` (port 3307) |
| **Regenerable?** | Can re-sync from live DB (but that means the backup is the live DB, losing the safety net) |
| **Type** | BACKUP |
| **Retention policy** | NO AUTO-ROTATION found. `.darc` files accumulate. `dolt backup sync` is append-only into the backup folder. |
| **Offsite path** | `GC_BACKUP_OFFSITE_PATH` env var (checked in mol-dog-backup.sh). Whether this is set is UNKNOWN — check `~/.gastown/config/global.json` or rig env. |
| **Verdict** | **MOVE-OFF-DISK** — Essential safety net; do not delete without a replacement. The 2.3G hq .darc is needed. Options: (a) configure `GC_BACKUP_OFFSITE_PATH` to an external drive/NAS so local copies can be pruned after offsite sync; (b) implement retention policy to keep only last N .darc files per DB. Ask Athos: "Is GC_BACKUP_OFFSITE_PATH set? If yes, are offsite backups confirmed?" |
| **Reclaimable** | TBD (0 until offsite strategy confirmed) |

---

### 5. `/Users/athos/gt/.gascity-gastown-hq/.beads/dolt/hq/.dolt/noms/oldgen/` — 2.1G

| Field | Value |
|-------|-------|
| **What** | Dolt internal storage layer for the `hq` database — "oldgen" contains older content-addressed data chunks in Dolt's NBS (Noms Block Store) format. This is normal operation: Dolt moves data from "newgen" to "oldgen" as it ages. |
| **Writer** | Dolt server (internal — completely automated) |
| **Readers** | Dolt server |
| **Source of truth** | This IS the source of truth for hq Dolt DB history |
| **Type** | PROD data (Dolt internal) |
| **Verdict** | **DO NOT TOUCH** — Removing any file under `.dolt/` causes unrecoverable data corruption. Dolt manages its own oldgen via garbage collection (`dolt gc`). If this grows unacceptably, run `gc dolt status` and consider `dolt gc` via the Dolt SQL shell — NOT by deleting files manually. |
| **Reclaimable** | 0 |

---

### 6. `/Users/athos/shared/data/contagem_lotes.db` — 2.4G (mtime Jul 4 — active today)

| Field | Value |
|-------|-------|
| **What** | SQLite store of Contagem municipality's full lot cadastre (~384k lots) ingested from the public ArcGIS FeatureServer. Contains fiscal index (`indice_cadastral`), owner name, zoning, GIS geometry (WKT), and enrichment fields. |
| **Writer** | `whatsapp_automation/.wt-pixdialer/scripts/contagem_bulk_load.py` (one-time ingestion from ArcGIS). Active enrichment writers: `contagem_restricoes_enrichment.py`, `contagem_gis_enrichment.py`, `contagem_edificacao_ingest.py`, `contagem_alvaras_scrape.py`. |
| **Readers** | `com.urblink.contagem-verify` launchd (daily 07:00); `com.urblink.contagem-owner-sweep` launchd (every 2h); `contagem_leads_map_build.py`, `contagem_build_mega_data_set.py`, `contagem_contatos_areas.py`. mtime Jul 4 = being actively written today. |
| **Source of truth** | Contagem ArcGIS public API (no auth, no captcha). Full reload: `contagem_bulk_load.py` (~2-4h, ~193 pages × 2000 rows, idempotent UPSERT). |
| **Regenerable?** | YES — fully re-downloadable from public API. Enrichment layers (restricoes, alvaras, edificacao) require additional scrape steps. |
| **Type** | PROD data (actively read/written by running daemons) |
| **Verdict** | **KEEP** — Two launchd daemons query it every 2h. Active enrichment writes seen today. If a disk emergency forces deletion: re-run `contagem_bulk_load.py` (2-4h) and then enrich scripts. Document this under "disk emergency playbook". |
| **Reclaimable** | 0 |

---

### 7. `/Users/athos/gt/lexbh/` — 3.1G total (suspended rig)

The `lexbh` rig is `suspended = true` in `city.toml`. Breakdown:

| Sub-item | Size | Type | Notes |
|----------|------|------|-------|
| `lexbh/crew/digo/.venv/` | ~1.3G | CACHE (venv) | PyTorch (486M libtorch_cpu.dylib), Playwright (265M), cv2/OpenCV (243M), transformers (210M). Fully recreatable via `pip install` |
| `lexbh/shared/data/lexbh.db` | 122M | PROD (if project resumes) | Live SQLite DB, last updated Jun 19 |
| `lexbh/shared/data/lexbh.db.bak.*` | ~1.3G | BACKUP copies | 10+ rolling weekly backups at 122M each, oldest May 25, newest Jul 3 |
| `lexbh/crew/batista/` | 86M | Source code + venv | |
| `lexbh/mayor/`, `refinery/`, etc. | ~12M | Source code | |

| Field | Value |
|-------|-------|
| **Writer** | Lexbh crew agents (suspended since ~Jun 19) |
| **Source of truth** | `lexbh.db` is the canonical DB for the lexbh legal assistant project; backups are derived |
| **Type** | STALE (suspended rig) |
| **Verdict** | **ASK-ATHOS** — Two questions: (a) "Is lexbh being resumed? If no, the whole directory can be archived/deleted." (b) "If resuming eventually: safe to delete the `.venv` (1.3G, re-installable) and all but the 2 most recent db backup files (~1.1G)?" Safe immediate reclaim: `.venv` (1.3G) + old backup files pre-Jun (4 files × 122M = ~490M) = ~1.8G. Requires Athos confirmation. |
| **Reclaimable** | ~1.8G (conservative) to 3.1G (if project abandoned) |

---

### 8. `/Users/athos/shared/data/daemon_monitoring.db` — 116M (active)

| Field | Value |
|-------|-------|
| **What** | SQLite DB written by `daemons/daemon_health_monitor.py` and `daemons/fuse_safe_monitor.py`. Stores daemon heartbeats, health events, error logs. |
| **Writer** | `daemon_health_monitor.py`, `fuse_safe_monitor.py` (continuously running daemons) |
| **Readers** | Dashboards, `drive_recovery_sweeper.py` |
| **Type** | PROD monitoring data |
| **Verdict** | **KEEP** — 116M is small; not worth disrupting monitoring to reclaim. If it grows >500M, consider adding a pruning query to `daemon_health_monitor.py`. |

---

### 9. `/Users/athos/shared/data/health.db` — 50M (active)

| Field | Value |
|-------|-------|
| **What** | Channel health metrics (ban risk, warmup state, health events per channel). |
| **Writer** | Health monitor daemon (likely `whatsapp_automation/daemons/`) |
| **Readers** | WA daemons that check channel health before sending |
| **Type** | PROD data |
| **Verdict** | **KEEP** — 50M is negligible. |

---

### 10. `whatsapp_conversations_cold.db` — NOT FOUND

This file was expected at `/Users/athos/shared/data/whatsapp_conversations_cold.db` but does not exist on disk as of Jul 4. The file `whatsapp_conversations.db` exists but is 0 bytes (mtime Mar 19). The "cold" variant may have been deleted in a prior cleanup or never materialized. No action needed.

---

## Disk Emergency Playbook

If disk approaches 95%+ again, in order of safety and impact:

1. **Delete `real_estate_backup.duckdb` + `.tmp.wal`** (free 7.5G, zero risk, recreated at 02:30 AM automatically)
2. **Delete `~/.cache/huggingface/hub/models--BAAI--bge-m3/`** (free 4.2G, re-downloaded when lexbh resumes)
3. **Ask Athos about lexbh:** delete `.venv` + old db backups = ~1.8G
4. **Configure dolt-backup offsite** then prune old local .darc files

**Never touch:** `.beads/dolt/*/noms/`, `.dolt/` directories, `processos.db` (no S3 backup), `contagem_lotes.db` (would disable running launchd daemons).

---

## Open Questions for Athos

| # | Item | Question |
|---|------|---------|
| A | `lexbh/` | Is the lexbh project being resumed? If no, the whole 3.1G directory can be archived to an external drive or S3 and removed. If yes, safe to delete `.venv` (1.3G) and old backup files (pre-Jun, ~490M)? |
| B | `.dolt-backup/` | Is `GC_BACKUP_OFFSITE_PATH` configured in your Gas Town env? If an external drive or NAS receives offsite rsync, the local `.dolt-backup/` copies could be managed to keep only the last 1-2 .darc files (saving ~2G) without losing the safety net. |
| C | `processos.db` | This 3.7G file has NO S3 backup. Should `backup_all_dbs.sh` be extended to include `whatsapp_automation/processo_lookup/data/processos.db`? |

---

*Last updated: 2026-07-04. Update this doc whenever a large file is added/removed from the system.*
