# Post-mortem: gastown clones FF audit (dc-yxgb)

**Bead:** dc-yxgb
**Operator:** crew/batista (whatsapp_automation rig)
**Started:** 2026-05-07
**Strategy:** fast-forward each stale clone to fork/main (= `c027bd38`)

## Background

After dc-bsza (gastown fork sync), dc-kwgc (refinery rig-DB fix),
dc-w7zc (deacon rig sync), and dc-6cuw (gastown-side BEADS_NO_AUTO_IMPORT
follow-up), `fork/main` advanced to `c027bd38`. Several local clones of
the same fork remained on pre-sync state. This bead cleans them up.

## Audit results

| Clone path | Pre-sync HEAD | Dirty | Result |
|---|---|---|---|
| `~/gt/gastown/mayor/rig` | `2cef69ef` (post-dc-kwgc) | clean | FF → `c027bd38` |
| `~/gt/gastown/crew/witness` | `7927d6823` (pre-dc-bsza) | 1 file | wip + FF → `c027bd38` |
| `~/gt/gastown/crew/furiosa` | `42f9d568` (pre-dc-bsza, March 28) | 3 files | wip + FF → `c027bd38` |
| `~/gt/gastown/crew/deacon` | `7927d6823` (pre-dc-bsza) | 1 file | wip + FF → `c027bd38` |

Already aligned (verified, no action taken):
- `~/gt/deacon` — `43d49a26` post dc-w7zc (synced separately)
- `~/go/src/gastown` — `c027bd38` (canonical source clone)
- `~/gt/beads` — `6d2e4843` post dc-4sks (separate fork, not gastown)

## Dirty-file analysis

All three dirty crew clones had **the same obsolete change**:
`plugins/stuck-agent-dog/run.sh` updating `gt hook` → `gt hook show` with
awk+grep parsing. The same fix (with a slightly different but equivalent
implementation — `head -1 → grep -v → awk` instead of
`awk → grep -v → head -1`) already exists in `fork/main` via the dc-bsza
merge resolution. Discarding the local versions in favor of fork/main is
safe and intentional.

`crew/furiosa` additionally had:
- `D .beads/backup/issues.jsonl` — file removed; expected, since fork/main
  added `.beads/backup/` to `.gitignore` and stops tracking the dir
- `M .gitignore` — local addition of `# Gas Town (added by gt)` +
  `CLAUDE.local.md` line; superseded by fork/main's larger gitignore
  rewrite which already includes `CLAUDE.local.md`

All dirty changes preserved on per-clone wip branches (local only, not
pushed):

- `~/gt/gastown/crew/witness` → `wip-2026-05-07-witness-stuck-agent-dog`
- `~/gt/gastown/crew/furiosa` → `wip-2026-05-07-furiosa-dirty`
- `~/gt/gastown/crew/deacon` → `wip-2026-05-07-crew-deacon-stuck-agent-dog`

If any of these turn out to contain real WIP, cherry-pick from the wip
branch onto current main. Otherwise the branches can be deleted as
landfill cleanup once verified.

## Backup

No new backup branches needed. All four clones share the same fork
(`athosmartins/gastown`), so the existing
`fork/backup-fork-main-pre-sync-2026-05-06` @ `9c374c4e` (created during
dc-bsza) covers any rollback scenario.

## Verification per clone

For each FF'd clone:
- `git log -1 --oneline` returns `c027bd386 fix(mail): set
  BEADS_NO_AUTO_IMPORT=1 on bd subprocess env (dc-6cuw)`
- `git rev-list HEAD..fork/main --count` returns 0 (fully aligned)
- Working tree clean (or dirty only with untracked runtime artifacts
  like heartbeat.json, dogs/, embeddeddolt/, etc, which are local
  state and not version-controlled)

## Constraints met

- ✅ No real work destroyed — every dirty file was either (a) obsolete
  (superseded by fork/main) or (b) preserved on a wip branch
- ✅ No backup needed beyond the existing dc-bsza backup
- ✅ No daemon restart performed; agents pick up the new state on
  natural session boundaries

## Refs

- dc-bsza (fork sync that started the cascade)
- dc-kwgc (refinery fix)
- dc-w7zc (deacon clone sync)
- dc-6cuw (BEADS_NO_AUTO_IMPORT gastown-side)
- This bead (dc-yxgb) cleans up stragglers
