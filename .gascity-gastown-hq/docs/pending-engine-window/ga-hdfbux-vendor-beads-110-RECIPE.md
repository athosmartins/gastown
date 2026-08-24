# ga-hdfbux: re-land the third_party/beads v1.1.0 vendor bump

## What this is

NOT a `git diff`-style patch — the actual change (vendored `third_party/beads`
v1.0.5 -> v1.1.0 content + the `go.mod` require line) touches 2897 files /
~397k lines (it's a full vendored copy of an external repo, including its own
docs site). A patch file that size doesn't fit this directory's convention and
isn't the safest way to carry it — a path-scoped `git checkout <ref> --
<paths>` from a pinned commit is smaller, faster, and guarantees
byte-identical content (a multi-MB patch risks a silent mis-apply nobody
would notice at review time).

## Context (full history in ga-hdfbux comments + ga-9ae7o, closed)

This is a REGRESSION, not a new bug. ga-9ae7o (2026-08-07/08) diagnosed and
fixed the identical symptom (gc compiled against a vendored beads copy stuck
at v1.0.5 via `go.mod`'s `replace github.com/steveyegge/beads =>
./third_party/beads`, causing `native_store_unavailable`/`version_compat` WARN
city-wide + Dolt connection-per-call multiplication). Mayor bumped
`third_party/beads` to a clean v1.1.0 (the local patch `gc-aov9u` /
`SetConnMaxIdleTime` had been absorbed upstream, so no re-patching needed),
rebuilt, and verified live: WARN 52/cycle -> 0, Dolt latency 30-74s ->
150-257ms. Bead closed 2026-08-08.

**The fix was never committed to `origin/main`.** Confirmed by direct
inspection (2026-08-24): `origin/main` tip (25145e6a8, 2026-07-02) predates
the fix event entirely and still reads `github.com/steveyegge/beads v1.0.5`.
The actual build lineage, `consolidated/engine-window-20260823` (tip
bacf46a83, 2026-08-22 — origin/main + cherry-picks, confirmed via
`git merge-base --is-ancestor`), also still reads v1.0.5. So the 2026-08-07
fix lived only in Mayor's local build tree at the time, got deployed straight
from there, and evaporated the next time the source tree was reset/rebuilt
from the real branch lineage. Today (2026-08-24) the identical symptom
reappeared and is tracked in ga-hdfbux — with two dog sessions and two Mayor
sessions independently re-investigating it from scratch, one of them (Mayor,
"fork" session) concluding the fix requires unscoped engineering (resolving
354 commits of upstream drift, go.mod/go.sum conflicts). **That conclusion
was reached without knowing about ga-9ae7o or the `replace =>
./third_party/beads` mechanism** — it does not hold; see below.

## Where the fix content is RIGHT NOW (2026-08-24, verified)

    Source tree: ~/gt/.local-patches/_src-hookfix
    Commit:      64dc28fcc76fe4bf57371a5253450773af3b49e2
                 ("wip: temp checkpoint for ga-hnn7l implementation worktree
                 (will be reset)", branch ftmci-incremental-hydration,
                 authored 2026-08-17)

Verified this commit's `third_party/beads/cmd/bd/version.go` says
`Version = "1.1.0"` — this is real v1.1.0 vendored content, not just a
relabeled require line. Verified the diff against `origin/main` is cleanly
isolated to `go.mod`, `go.sum`, and `third_party/beads/**` (2897 of the 2954
total files changed vs origin/main — the remaining ~57 are the unrelated
ga-hnn7l WIP work on top, which this recipe does not touch).

**This WIP commit is explicitly disposable** ("will be reset" — could be
force-moved or the branch deleted at any time). To stop it from vanishing
before someone lands this, I pinned it with a LOCAL git tag in that same
clone (not pushed to any remote — that's a judgment call for whoever picks
this up, see below):

    git -C ~/gt/.local-patches/_src-hookfix tag -l 'preserve/ga-hdfbux*'
    # -> preserve/ga-hdfbux-vendor-beads-v110 -> 64dc28fcc

This tag is LOCAL ONLY (protects against local `git gc` + this specific
branch being reset). It does NOT protect against the whole `_src-hookfix`
clone being deleted/recreated. If durability matters before someone actively
lands this, push the tag:
`git -C ~/gt/.local-patches/_src-hookfix push origin preserve/ga-hdfbux-vendor-beads-v110`
— did not do this myself (dog scope: local-only, non-destructive actions;
pushing to the shared gascity remote is a Mayor-level call).

## Recipe to land it (someone with engine-rebuild authority — Mayor)

    cd ~/gt/.local-patches/_src-hookfix
    git fetch origin   # refresh in case origin/main moved since 2026-07-02
    git checkout origin/main -b fix/ga-hdfbux-vendor-beads-110
    git checkout 64dc28fcc -- go.mod go.sum third_party/beads
    git status --short                    # only go.mod/go.sum/third_party/beads/** should be staged
    git diff --cached --stat | tail -5    # expect ~2897 files changed, third_party/beads only
    git commit -m "fix(ga-hdfbux): re-land third_party/beads v1.1.0 vendor bump (regression of ga-9ae7o)"

Then follow ga-9ae7o's own proven build + verification recipe (already
written down there — icu4c CGO flags via `PKG_CONFIG_PATH` +
`CGO_CPPFLAGS` + `CGO_LDFLAGS`, symbol-count check for `SetConnMaxIdleTime`
before/after, gradual symlink swap — don't force a city restart — and verify
`native_store_unavailable` drops to 0 same-day, not just "looks better").
**This time, push the commit to `origin/main` (or merge it through whatever
the real gate is) before closing the bead** — that step is what was skipped
in August and is why this regressed.

## What I did NOT do (dog scope boundary)

Did not build, did not swap any binary, did not touch `origin/main` or any
shared branch, did not push anything to a remote. Refusing ga-hdfbux again
with `pool:refused:engine-rebuild-required` (consistent with the existing
label taxonomy already on that bead) — this is the second independent
refusal, which per the reclaim-guard's own stated logic should escalate the
bead to `gate:needs-human` rather than keep bouncing through the dog pool.

— gastown.dog-1, 2026-08-24
