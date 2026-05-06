# Post-mortem: Fork sync athosmartins/gastown ← steveyegge/gastown

**Bead:** dc-bsza
**Operator:** crew/batista (whatsapp_automation rig)
**Started:** 2026-05-06
**Source clone:** ~/go/src/gastown
**Strategy:** merge (preserves history, no force-push)

## Pre-sync state

- `fork/main` @ `9c374c4e` (2026-05-06)
- 45 commits ahead of `origin/main` (all preserved — see audit below)
- 203 commits behind `origin/main`

## Backups

- Local branch: `backup-fork-main-pre-sync-2026-05-06` @ `9c374c4e`
- Fork remote: `fork/backup-fork-main-pre-sync-2026-05-06` @ `9c374c4e`

Recovery if needed:
```bash
cd ~/go/src/gastown
git checkout main
git reset --hard backup-fork-main-pre-sync-2026-05-06
git push fork main --force-with-lease  # only if main was already moved
```

## Audit of 45 local-only commits

All 45 are intentional customizations — none discarded. Categories:
- **Bug fixes (deacon, heartbeat, mail routing, sling, doctor, plugins, dolt-backup, rate-limit-watchdog)**
- **Features (crew sessions, dashboard panels, security/credential audit, mail poll-and-nudge, /crew-commit skill)**
- **Installers (launchd templates for dashboard)**
- **Test stability (macOS bash 3.2 compat, flakiness)**

Full list: `git log --no-merges fork/main ^origin/main --format='%h %s'` (committed at sync time)

## Conflicts

20 files conflicted in the merge. Resolutions:

### Trivial / version bumps (accept upstream)

- `CHANGELOG.md` — accepted upstream additions (1.0.0/1.0.1 release notes)
- `npm-package/package.json` — version 1.0.1 (was 0.12.1)
- `gt-model-eval/package-lock.json` — @xmldom/xmldom 0.8.13 (was 0.8.11)
- `internal/cmd/version.go` — Version = "1.0.1"

### Modify/delete (accept upstream delete)

- `plugins/rate-limit-watchdog/run.sh` — upstream deleted in #3550 (Max-incompatible
  plugin). Our local commit `c27568bf` (rate-limit-watchdog exits 0 when API key
  unset) is now obsolete; discarded.

### Auto-resolved with logic preserved (combine both sides)

- `internal/cmd/mail_check.go` — kept our defensive DeliveryState filter
  (defense-in-depth for crash recovery) layered on upstream's `filterUnreadMessages`
  refactor + upstream's `gt dog done` archive (#3541). Comment updated to reference
  both fixes. See: hq-lsoei.

### Refactor (accept upstream — GH#3468 multi-rig sling contexts)

- `internal/cmd/capacity_dispatch.go` — accepted upstream's `listAllSlingContexts`
  scanning all rig dirs + new `beadsForContext` helper. Updated `cleanupStaleContexts`
  to use per-context `beadsForContext` instead of single `townBeads` instance.
  Also added `doltserver` import.
- `internal/cmd/scheduler.go` — same refactor: `runSchedulerClear` now uses
  `beadsForContext` per-context. Removed unused `townBeads` local. Added new
  `countWorkingPolecats` helper from upstream.
- `internal/cmd/sling_schedule.go` — accepted upstream's `listAllSlingContexts`
  call, removed local error-returning `ListOpenSlingContexts` path.

### Pure additions (accept upstream)

- `internal/cmd/formula.go` — accepted upstream's new `executeWorkflowFormula`
  function (gt-jh68 workflow formulas).
- `internal/config/env.go` — accepted upstream's effort-level resolution
  (`ResolveRoleEffort` + CLAUDE_CODE_EFFORT_LEVEL deprecation notice).
- `internal/git/git.go` — accepted upstream's PR helpers (FindPRNumber,
  IsPRApproved, GhPrMerge, FindBitbucketPRNumber, IsBitbucketPRApproved,
  BitbucketPRMerge) + context/encoding/json imports.
- `internal/refinery/engineer.go` — accepted upstream's MergeStrategy/VCSProvider/
  RequireReview config fields, JSON unmarshal, doMerge PR-strategy branch, and
  `doMergePR` function (#3600 Bitbucket Cloud integration). Added NeedsApproval
  field to ProcessResult struct (was missing from upstream auto-merge).
- `internal/cmd/scheduler.go` (second hunk) — accepted upstream's
  `countWorkingPolecats` function.
- `internal/polecat/session_manager.go` — accepted upstream's
  `freshBranchName`/`parseFreshBranchName`/`canonicalSessionStartPoint`/
  `shouldCreateFreshSessionBranch`/`ensureCanonicalSessionBranch` helpers,
  changed Start to use `ensureCanonicalSessionBranch` for fresh-branch-per-session
  semantics. Added `strconv` import.

### Test cosmetics / line-shift conflicts

- `internal/cmd/compact_report_test.go` — kept our HEAD's named-test-case form
  (more thorough; superset of upstream's coverage).
- `plugins/stuck-agent-dog/run.sh` — accepted upstream's HOOK_BEAD extraction
  (only-first-line is more correct than awk-then-grep).
- `internal/cmd/sling_formula.go` — accepted upstream's typo fix (`gt-etc` → `gt-ect`).
- `internal/cmd/root.go` — accepted upstream's macOS-only unsigned-binary check
  (#3561), stronger ERROR wording.
- `internal/formula/formulas/mol-witness-patrol.formula.toml` — accepted upstream's
  effort-based patrol routing + template-variable conversion (`{{rig}}`/`{{prefix}}`
  instead of manual placeholders). Added the corresponding `[vars.rig]`,
  `[vars.prefix]`, `[vars.idle_effort_threshold]` declarations from upstream.
- `internal/tmux/tmux.go` — accepted upstream's `canonicalPaneTarget` helper
  (uses tmux display-message to resolve canonical session:window.pane format
  instead of inline `session+":"+pane`).

## Test fixes after merge

The merge surfaced four pre-existing test issues that needed addressing to validate
the merged tree:

- **`internal/beads.TestFindTownRoot/prefers_outermost_town_root`** — upstream
  commit `09a21802 fix(beads): FindTownRoot returns outermost town root for nested
  rigs` (April 1, 2026) had been silently lost during a prior fork merge
  (cb3306c1). The merge brought the test in but kept fork's regressed
  implementation. Re-applied the upstream fix manually to `internal/beads/beads_types.go`.
- **`internal/cmd.TestBuildBdInitArgs_AlwaysIncludesServerPort`** — upstream
  commit `84594d11` (May 2, 2026, #3829) added `--force` to `bd init` for bd 1.0+
  compatibility but didn't update the unit test. Updated the test to expect 7 args
  including `--force` on `args[6]`.
- **`internal/cmd.TestCreateAutoConvoy_BasicSuccess`** — upstream test compares
  `townRoot` with the path returned by `workspace.FindFromCwd`, which resolves
  symlinks. On macOS, `t.TempDir()` returns `/var/folders/...` but the resolved
  path is `/private/var/folders/...`. Added `filepath.EvalSymlinks` in the test
  helper to canonicalize the path before assertions.
- **`internal/doctor.TestDoltServerReachableCheck_*`** — our local commit
  `a4411056 fix(doctor): skip dolt-server-reachable check when daemon is not
  running` short-circuited the check before the test setup could simulate the
  scenarios. Indirected the daemon liveness probe through a package var
  `daemonIsRunning` and added a `stubDaemonRunning(t)` helper. The defensive
  skip-on-cold-start behavior is preserved in production.

## Verification

- Build: `go build ./...` passes after fixes
- Tests: `go test -count=1 -short ./...` passes except for two pre-existing
  flaky tmux integration tests (`TestNudgeSession_WithRetry`,
  `TestNudgeSession_WithStoredPaneID`) that also fail on
  `backup-fork-main-pre-sync-2026-05-06` — confirmed environmental, not
  caused by this merge.

## Recurrence prevention

The fork drifted because every prior `chore: merge upstream origin/main` commit
silently re-introduced fork-side regressions over upstream fixes (notably
`09a21802`, repeatedly). To prevent this:

1. **Monthly automated upstream sync** — schedule `gt mail send mayor/ -s "fork
   sync due"` in the daemon patrol formula or a launchd timer.
2. **Lint check on merge** — when merging upstream into fork, run `go test
   ./...` and `go build ./...` before pushing. Fail the merge if upstream tests
   that pass on origin/main fail on the merged tree (signals fork has regressed
   an upstream fix).
3. **Convert all 45 local commits into upstream PRs over time** — the further our
   fork stays from upstream, the higher the conflict cost. Long-term goal: zero
   permanent fork-only commits.
