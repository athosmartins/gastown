#!/usr/bin/env bash
# gate-merge-survival-sweep.selftest.sh — prove the ga-lzj2e survival sweep in
# isolation, with NO live Dolt/gc/launchd and NO network.
#
# Sources the sweep in lib-only mode for the REAL functions (one source of
# truth, no copy-drift), then:
#   • unit-tests the pure classifier survival_classify across EVERY verdict
#     (survived / ff_heal / content_equivalent / divergent / unresolved) on a
#     real local git repo;
#   • unit-tests the retention/age helpers (iso_to_epoch, entry_within_retention)
#     including the fail-open-on-unparseable guard;
#   • unit-tests the rig container/self git-dir resolution + git_in dispatch;
#   • DRIFT-GUARDS the live wiring in the sweep, the plist, AND the producer
#     edit in quality-gate-dispatcher.sh (the ledger append).
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SELF_DIR/gate-merge-survival-sweep.sh"
PLIST="$SELF_DIR/gate-merge-survival-sweep.plist"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
# rc0/rc1 take a leading human description, then the command + args to run.
rc0() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d — expected rc0 from: $*"; fi; }
rc1() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d — expected non-zero from: $*"; else ok "$d"; fi; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
SURVIVAL_LIB_ONLY=1 source "$SWEEP" \
  || { echo "FATAL: could not source sweep in lib-only mode"; exit 1; }
for fn in survival_classify rig_gitdir git_in iso_to_epoch entry_within_retention \
          raw_fetch recheck_divergent divergent_surge parse_entry_fields; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by sweep"; exit 1; }
done

# ── Real-git fixture (local only, no network) ───────────────────────────────
T="$(mktemp -d 2>/dev/null || mktemp -d -t galzj2e)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
R="$T/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name  tester
echo a > "$R/a"; git -C "$R" add .; git -C "$R" commit -q -m "C1"
C1=$(git -C "$R" rev-parse HEAD)
echo b > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "C2"
C2=$(git -C "$R" rev-parse HEAD)
echo c > "$R/c"; git -C "$R" add .; git -C "$R" commit -q -m "C3"
C3=$(git -C "$R" rev-parse HEAD)
# Divergent branch off C1: D1 shares no descendancy with C2/C3.
git -C "$R" checkout -q -b other "$C1"
echo d > "$R/d"; git -C "$R" add .; git -C "$R" commit -q -m "D1"
D1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

# ── 1. survival_classify — every verdict, real ancestry ─────────────────────
echo "── 1. survival_classify (pure verdict, real git) ──"
git -C "$R" update-ref refs/remotes/origin/main "$C2"
eq "merge == origin → survived"            "$(survival_classify "$R" 0 "$C2" origin/main)" "survived"
eq "merge ancestor of origin → survived"   "$(survival_classify "$R" 0 "$C1" origin/main)" "survived"
eq "merge ahead of origin → ff_heal"       "$(survival_classify "$R" 0 "$C3" origin/main)" "ff_heal"
git -C "$R" update-ref refs/remotes/origin/main "$D1"
eq "neither ancestor → divergent"          "$(survival_classify "$R" 0 "$C3" origin/main)" "divergent"
eq "bogus merge sha → unresolved"          "$(survival_classify "$R" 0 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" origin/main)" "unresolved"
git -C "$R" update-ref -d refs/remotes/origin/main 2>/dev/null || true
eq "missing origin ref → unresolved"       "$(survival_classify "$R" 0 "$C2" origin/main)" "unresolved"

# ── 1b. content_equivalent — wa-k8l0m (2026-09-22, 3 recurrences): a merge sha
# that is divergent by raw ancestry, but whose touched file(s) already match
# byte-for-byte on the other side (same fix, landed under a different sha —
# e.g. a rebase/re-commit) must classify content_equivalent, NOT divergent, so
# the sweep stops re-escalating an already-resolved case every single run.
echo "── 1b. content_equivalent (same fix, different sha) ──"
git -C "$R" checkout -q -b ce-branch "$C1"
echo "REBASED-B" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "same fix as CE2, different sha/branch"
CE1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b ce-other "$C1"
echo "REBASED-B" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "same fix as CE1, re-landed independently"
CE2=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b ce-diff "$C1"
echo "ACTUALLY-DIFFERENT-CONTENT" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "genuinely different change to the same file"
CE3=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

eq "neither ancestor, byte-identical touched files → content_equivalent" \
  "$(survival_classify "$R" 0 "$CE1" "$CE2")" "content_equivalent"
eq "content_equivalent is symmetric (CE2 vs CE1)" \
  "$(survival_classify "$R" 0 "$CE2" "$CE1")" "content_equivalent"
eq "CONTROL: neither ancestor, touched file content DIFFERS → still plain divergent" \
  "$(survival_classify "$R" 0 "$CE1" "$CE3")" "divergent"
rc0 "_survival_content_equivalent true for the CE1/CE2 pair directly" \
  _survival_content_equivalent "$R" 0 "$CE1" "$CE2"
rc1 "_survival_content_equivalent false for the CE1/CE3 pair directly" \
  _survival_content_equivalent "$R" 0 "$CE1" "$CE3"
# Merge-commit guard: a 2-parent commit must never take the equivalence
# shortcut, even if its content happens to match -- which "the" touched-file
# set a merge represents is ambiguous across parents, so this stays
# conservative (falls through to ordinary ancestry-based divergent).
# Built directly via commit-tree (deterministic, no conflict-resolution
# heuristics to go wrong): a real 2-parent commit whose tree is BYTE-IDENTICAL
# to CE2's, so the only variable under test is the parent count.
CE_MERGE=$(git -C "$R" commit-tree "${CE2}^{tree}" -p "$CE3" -p "$CE2" -m "merge (2 parents), tree matches CE2 exactly" 2>/dev/null || echo "")
if [ -n "$CE_MERGE" ] && [ "$(git -C "$R" rev-parse "${CE_MERGE}^@" 2>/dev/null | grep -c .)" = "2" ]; then
  rc1 "_survival_content_equivalent false for a 2-parent (merge) commit, even with matching content" \
    _survival_content_equivalent "$R" 0 "$CE_MERGE" "$CE2"
else
  bad "merge-commit fixture did not actually produce 2 parents -- skipped guard assertion"
fi

# Provably-lossless direction check: ff_heal ⟹ origin IS ancestor of merge.
git -C "$R" update-ref refs/remotes/origin/main "$C2"
rc0 "ff_heal precondition: origin ancestor-of merge" git -C "$R" merge-base --is-ancestor "$C2" "$C3"

# ── 2. iso_to_epoch + entry_within_retention ────────────────────────────────
echo "── 2. age / retention helpers ──"
TS="2026-06-11T00:00:00Z"
EXP=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s 2>/dev/null || echo X)
eq "iso_to_epoch parses UTC ts"            "$(iso_to_epoch "$TS")" "$EXP"
eq "iso_to_epoch empty on junk"            "$(iso_to_epoch 'not-a-date')" ""
NOW=$(date -u +%s)
TS_RECENT=$(date -u -r $(( NOW - 86400 ))      +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
TS_OLD=$(date    -u -r $(( NOW - 30*86400 ))   +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
rc0 "1-day-old entry within 14d retention"  entry_within_retention "$TS_RECENT" "$NOW" 14
rc1 "30-day-old entry outside 14d retention" entry_within_retention "$TS_OLD" "$NOW" 14
rc0 "unparseable ts FAILS OPEN (kept)"       entry_within_retention "garbage" "$NOW" 14
rc0 "empty ts FAILS OPEN (kept)"             entry_within_retention "" "$NOW" 14

# ── 3. rig_gitdir + git_in dispatch ─────────────────────────────────────────
echo "── 3. rig container/self resolution ──"
mkdir -p "$T/crig/.repo.git" "$T/srig"
eq "container rig → .repo.git + flag 1"    "$(rig_gitdir "$T/crig")" "$(printf '%s\t1' "$T/crig/.repo.git")"
eq "self rig → path + flag 0"              "$(rig_gitdir "$T/srig")" "$(printf '%s\t0' "$T/srig")"
# git_in self-repo path (container=0) and container path (container=1 against .git).
eq "git_in self (container=0)"             "$(git_in "$R" 0 rev-parse --abbrev-ref HEAD)" "main"
eq "git_in container (container=1)"        "$(git_in "$R/.git" 1 rev-parse HEAD)" "$C3"

# ── 4. drift-guard: sweep wiring ────────────────────────────────────────────
echo "── 4. drift-guard: sweep wiring ──"
grep -q 'SURVIVAL_LIB_ONLY' "$SWEEP"            && ok "sweep sourceable in lib-only mode"  || bad "missing lib-only hook"
grep -q 'survival_classify()' "$SWEEP"          && ok "defines survival_classify"          || bad "missing survival_classify def"
grep -q 'escalate_divergent()' "$SWEEP"         && ok "defines escalate_divergent"         || bad "missing escalate_divergent def"
grep -q 'escalate_unresolved()' "$SWEEP"        && ok "defines escalate_unresolved"        || bad "missing escalate_unresolved def"
grep -q 'push origin "${SHA}:refs/heads/$RDEFAULT"' "$SWEEP" && ok "ff_heal does FF-only re-push" || bad "ff_heal re-push missing"
grep -q 'merge-base --is-ancestor "\$mref" "\$sha"' "$SWEEP" && ok "ff_heal direction is origin-ancestor-of-merge (lossless)" || bad "ff_heal ancestry direction wrong/missing"
grep -q 'bd -C "\$beadcity" reopen "\$bead"' "$SWEEP" && ok "divergent reopens source bead (re-enqueue)" || bad "reopen missing"
grep -q 'gate:merge-orphan' "$SWEEP"            && ok "labels orphan bead gate:merge-orphan" || bad "orphan label missing"
grep -q 'mail send mayor' "$SWEEP"              && ok "escalates divergent to Mayor"         || bad "Mayor escalation missing"
grep -q 'entry_within_retention' "$SWEEP"       && ok "retention prune wired"                || bad "retention prune missing"
grep -q 'should_alert' "$SWEEP"                 && ok "per-sha escalation rate-limit wired"  || bad "rate-limit missing"
grep -q 'SURVIVAL_DRY_RUN' "$SWEEP"             && ok "dry-run supported"                    || bad "dry-run support missing"
# -u -j -f UTC guard (ga-35zp1: never omit -u with -j -f).
grep -q 'date -u -j -f "%Y-%m-%dT%H:%M:%SZ"' "$SWEEP" && ok "iso_to_epoch uses -u (UTC age, ga-35zp1)" || bad "missing -u UTC guard"

# ── 5. drift-guard: producer edit in quality-gate-dispatcher.sh ─────────────
echo "── 5. drift-guard: dispatcher ledger producer ──"
grep -q 'merge-survival-ledger.jsonl' "$DISPATCHER"   && ok "dispatcher writes the survival ledger" || bad "dispatcher ledger append missing"
grep -q 'ga-lzj2e' "$DISPATCHER"                       && ok "dispatcher edit tagged ga-lzj2e"       || bad "dispatcher edit untagged"
# ga-wvdl6: the ledger write is gated on NEEDS_SURVIVAL_LEDGER, not the
# narrower IS_CONTAINER_RIG -- a self-repo rig embedded in a DIFFERENT
# repo's working tree (gascity, deacon) shares that outer repo's remote
# with a container rig and needs the same protection. See section 6 below
# for the functional proof of the classification itself.
grep -q 'NEEDS_SURVIVAL_LEDGER:-0' "$DISPATCHER"       && ok "ledger guarded by NEEDS_SURVIVAL_LEDGER (ga-wvdl6)" || bad "survival-ledger gate missing/reverted to IS_CONTAINER_RIG-only"
grep -Eq 'grep -E .\^\[0-9a-f\]\{7,40\}' "$DISPATCHER" && ok "ledger guarded to a real merge SHA"   || bad "sha guard missing"

# ── 6. functional: NEEDS_SURVIVAL_LEDGER classification (ga-wvdl6) ─────────
# PROBLEM: IS_CONTAINER_RIG is a pure ".repo.git exists" structural fact.
# gascity/deacon are self-repo (no .repo.git) but are actually SUBDIRECTORIES
# of the shared town-root repo, whose origin IS the same remote a container
# rig (gastown) pushes to -- so they carry the exact clobber vector this
# ledger exists to catch, yet were silently excluded. Extract the live
# classification block VERBATIM (same technique
# gate-dispatcher-rig-resolve-noabort.selftest.sh uses for its sibling
# block) and prove it against three REAL git shapes. Pure git+shell, no
# bd/gc/network dependency.
echo "── 6. NEEDS_SURVIVAL_LEDGER classification (ga-wvdl6) ──"
NS_BLOCK="$(sed -n '/# SELFTEST-EXTRACT needs-survival-ledger-classify: BEGIN/,/# SELFTEST-EXTRACT needs-survival-ledger-classify: END/p' "$DISPATCHER" | sed '1d;$d')"
if [ -z "$NS_BLOCK" ]; then
  bad "needs-survival-ledger-classify block not found in $DISPATCHER"
else
  ok "needs-survival-ledger-classify block extracted"
  ns_classify() {
    bash -c '
      set -uo pipefail
      RIG_PATH="$1"; IS_CONTAINER_RIG="$2"
      '"$NS_BLOCK"'
      printf "%s" "$NEEDS_SURVIVAL_LEDGER"
    ' _ "$1" "$2"
  }

  # (a) container rig: passthrough, always 1 regardless of git shape.
  eq "container rig -> needs ledger (passthrough)" "$(ns_classify "$T/crig" 1)" "1"

  # (b) isolated self-repo: own repo root == own path -> genuinely no
  #     shared-remote vector, stays 0 (no behavior change for this shape).
  #     Resolve to the PHYSICAL path (pwd -P) before comparing: macOS
  #     mktemp -d returns a path under /var/folders/... which is itself a
  #     symlink to /private/var/folders/..., and `git rev-parse
  #     --show-toplevel` always returns the resolved physical path -- an
  #     unresolved RIG_PATH would spuriously mismatch its own toplevel here
  #     (a tmpdir symlink artifact, not the real-repo scenario this test
  #     exercises; verified production RIG_PATHs under /Users/athos/gt have
  #     no such indirection, so production code deliberately does NOT
  #     realpath-resolve -- only this fixture needs to).
  mkdir -p "$T/isolated_self_rig"
  git init -q -b main "$T/isolated_self_rig" >/dev/null 2>&1
  ISOLATED_RESOLVED="$(cd "$T/isolated_self_rig" && pwd -P)"
  eq "isolated self-repo rig -> no ledger needed" "$(ns_classify "$ISOLATED_RESOLVED" 0)" "0"

  # (c) embedded self-repo: a subdirectory of a DIFFERENT repo's working
  #     tree (the gascity/deacon shape -- own git toplevel != own path) ->
  #     shares that outer repo's remote, same clobber vector as a container
  #     rig. THIS is the bug: pre-fix, only IS_CONTAINER_RIG gated the
  #     ledger, and this shape is IS_CONTAINER_RIG=0 -- silently unledgered.
  #     Same physical-resolution reasoning as (b) above.
  mkdir -p "$R/embedded_subrig"
  EMBEDDED_RESOLVED="$(cd "$R/embedded_subrig" && pwd -P)"
  eq "embedded self-repo rig (gascity/deacon shape) -> needs ledger" "$(ns_classify "$EMBEDDED_RESOLVED" 0)" "1"

  # (d) third state: git can't answer at all (a real directory that isn't
  #     inside any git repo -- not expected in production, since RIG_PATH is
  #     already validated to exist by gate_resolve_rig_context before this
  #     point runs, but the classify block is defensive). "Undeterminable"
  #     must NOT collapse into "confirmed isolated" (0) -- this is a
  #     best-effort safety net where one extra harmless ledger entry costs
  #     nothing, so unknown fails toward protection (1), same as embedded.
  mkdir -p "$T/no_git_at_all"
  NOGIT_RESOLVED="$(cd "$T/no_git_at_all" && pwd -P)"
  eq "undeterminable (not a git repo at all) -> fails toward protection" "$(ns_classify "$NOGIT_RESOLVED" 0)" "1"
fi

# ── 7. drift-guard: plist ───────────────────────────────────────────────────
echo "── 7. drift-guard: plist ──"
grep -q 'com.gascity.gate-merge-survival-sweep' "$PLIST" && ok "plist Label correct"     || bad "plist Label wrong"
grep -q '<key>StartInterval</key>' "$PLIST"              && ok "plist uses StartInterval" || bad "plist missing StartInterval"
grep -q '<key>RunAtLoad</key><true/>' "$PLIST"           && ok "plist RunAtLoad=true"     || bad "plist missing RunAtLoad"
grep -q 'gate-merge-survival-sweep.sh' "$PLIST"          && ok "plist points at the sweep script" || bad "plist ProgramArguments wrong"

# ── 8. ga-8hm65g: divergent_surge (pure predicate) ──────────────────────────
echo "── 8. ga-8hm65g: divergent_surge threshold predicate ──"
rc1 "0 confirmed never surges, any threshold"        divergent_surge 0 5
rc1 "3 confirmed under threshold 5 -> not a surge"   divergent_surge 3 5
rc0 "10 confirmed over threshold 5 -> surge"         divergent_surge 10 5
rc1 "5 confirmed == threshold 5 -> not a surge (strict >)" divergent_surge 5 5
rc1 "0 confirmed never surges even vs a negative threshold (misconfig guard)" divergent_surge 0 -1

# ── 9. ga-8hm65g: recheck_divergent — invariant (a)+(b) ─────────────────────
# Acceptance criterion 1: "ref local velho + commit presente no remoto ->
# re-check com fetch classifica survived." Build a real local "origin" (a
# bare repo) + a rig clone whose CACHED local origin/main is stale, then
# advance the real remote past that stale point, and prove recheck_divergent
# (a) actually re-fetches and (b) reports the verdict and the value it was
# computed against as the SAME single reading (never two separate resolutions
# that could disagree, which is the split-read bug ga-8hm65g was filed
# against).
echo "── 9. ga-8hm65g: recheck_divergent (fresh-fetch re-verify) ──"
T9="$T/ga8hm65g_recheck"; mkdir -p "$T9"
RO9="$T9/origin.git"; git init -q --bare -b main "$RO9" >/dev/null 2>&1
RR9="$T9/rig"; git clone -q "$RO9" "$RR9" >/dev/null 2>&1
git -C "$RR9" config user.email t@example.com
git -C "$RR9" config user.name  tester
echo base > "$RR9/base"; git -C "$RR9" add .; git -C "$RR9" commit -q -m base
git -C "$RR9" push -q origin main
BASE9=$(git -C "$RR9" rev-parse HEAD)
# SIDE9 = the sha we'll recheck: a SIBLING of the stale ref (common ancestor
# BASE9, neither a descendant of the other) — genuinely divergent from it,
# not just "behind" it (a direct-descendant fixture would classify ff_heal,
# not divergent, and never exercise this path).
git -C "$RR9" checkout -q -b side "$BASE9"
echo side > "$RR9/side"; git -C "$RR9" add .; git -C "$RR9" commit -q -m side
SIDE9=$(git -C "$RR9" rev-parse HEAD)
git -C "$RR9" checkout -q main
# MSTALE9 = a second commit on main, sibling to SIDE9. Push it so origin/main
# advances to MSTALE9 — this is the value the rig's cache will hold as
# "stale" once fetched.
echo mstale > "$RR9/mstale"; git -C "$RR9" add .; git -C "$RR9" commit -q -m mstale
MSTALE9=$(git -C "$RR9" rev-parse HEAD)
git -C "$RR9" push -q origin main
# Populate the rig's cached origin/main (== MSTALE9) — this is the "ref local
# velho" precondition: stale relative to what origin is ABOUT to become.
git -C "$RR9" fetch -q origin
eq "fixture: cached origin/main starts at MSTALE9" "$(git -C "$RR9" rev-parse origin/main)" "$MSTALE9"
eq "fixture (precondition): SIDE9 genuinely divergent from stale cached origin/main" \
  "$(survival_classify "$RR9" 0 "$SIDE9" "$(git -C "$RR9" rev-parse origin/main)")" "divergent"
# Advance the REAL remote past SIDE9 (merge commit, so SIDE9 becomes an
# ancestor) — simulates an async push landing on the shared remote, same
# shape as the live incident. Done via a separate clone so RR9's own cached
# refs are untouched by this push.
RO9_WORK="$T9/origin_work"; git clone -q "$RO9" "$RO9_WORK" >/dev/null 2>&1
git -C "$RO9_WORK" fetch -q "$RR9" side:refs/remotes/origin/side >/dev/null 2>&1
git -C "$RO9_WORK" merge -q --no-ff -m "land side" refs/remotes/origin/side >/dev/null 2>&1
git -C "$RO9_WORK" push -q origin main
HEALED9=$(git -C "$RO9_WORK" rev-parse HEAD)
# RR9's LOCAL cached origin/main is still stale (MSTALE9) — no fetch since.
eq "fixture: rig's cached origin/main is still stale (no fetch yet)" "$(git -C "$RR9" rev-parse origin/main)" "$MSTALE9"

RECHECK9=$(recheck_divergent "$RR9" 0 "$SIDE9" "main")
RV9="${RECHECK9%%$'\t'*}"; RO9_NOW="${RECHECK9#*$'\t'}"
eq "recheck_divergent: fresh fetch reclassifies stale-divergent as survived" "$RV9" "survived"
eq "recheck_divergent: reported origin_now is the FRESH value (not the stale cached one)" "$RO9_NOW" "$HEALED9"
eq "recheck_divergent: rig's local cache is now updated by the recheck's own fetch" "$(git -C "$RR9" rev-parse origin/main)" "$HEALED9"

# Invariant (b) directly: verdict and reported value must be a single
# consistent read. Prove it against the classifier itself, using EXACTLY the
# value recheck_divergent reported.
eq "invariant (b): the reported origin_now, re-classified, agrees with the reported verdict" \
  "$(survival_classify "$RR9" 0 "$SIDE9" "$RO9_NOW")" "$RV9"

# Genuinely-still-divergent case: recheck must NOT falsely downgrade.
git -C "$RR9" checkout -q -b other9 "$BASE9"
echo other > "$RR9/other"; git -C "$RR9" add .; git -C "$RR9" commit -q -m other9
OTHER9=$(git -C "$RR9" rev-parse HEAD)
git -C "$RR9" checkout -q main
RECHECK9B=$(recheck_divergent "$RR9" 0 "$OTHER9" "main")
eq "recheck_divergent: a genuinely still-divergent sha stays divergent (no false downgrade)" "${RECHECK9B%%$'\t'*}" "divergent"

# ── 10. drift-guard: ga-8hm65g PASS 2 wiring ────────────────────────────────
echo "── 10. drift-guard: ga-8hm65g PASS-2 wiring ──"
grep -q 'declare -a PENDING_DIVERGENT' "$SWEEP" && ok "divergent candidates are queued, not escalated inline" || bad "PENDING_DIVERGENT array missing"
grep -q 'PENDING_DIVERGENT+=("\$entry")' "$SWEEP" && ok "first-pass divergent) case defers instead of calling escalate_divergent" || bad "divergent) case no longer defers"
grep -q 'recheck_divergent "\$RGITDIR" "\$RCONTAINER" "\$SHA" "\$RDEFAULT"' "$SWEEP" && ok "PASS 2 calls recheck_divergent before deciding" || bad "PASS 2 recheck call missing"
grep -q 'if divergent_surge "\${#CONFIRMED_DIVERGENT\[@\]}" "\$SURGE_THRESHOLD"; then' "$SWEEP" && ok "surge threshold gates the escalation branch" || bad "surge-threshold branch missing"
grep -q 'escalate_surge "\${#CONFIRMED_DIVERGENT\[@\]}"' "$SWEEP" && ok "over-threshold path calls escalate_surge" || bad "escalate_surge call missing"
# escalate_surge itself must never call bd (reopen/label are exactly the
# destructive actions invariant (d) suspends) — extract its body and assert.
SURGE_BODY="$(sed -n '/^escalate_surge() {/,/^}/p' "$SWEEP")"
[ -n "$SURGE_BODY" ] && ok "escalate_surge body extracted" || bad "could not extract escalate_surge body"
printf '%s' "$SURGE_BODY" | grep 'bd -C' >/dev/null \
  && bad "escalate_surge touches bd (reopen/label) — invariant (d) requires it never does" \
  || ok "escalate_surge never calls bd — no reopen/label during a surge"
printf '%s' "$SURGE_BODY" | grep 'mail send mayor' >/dev/null && ok "escalate_surge still mails Mayor (aggregated, once)" || bad "escalate_surge missing Mayor mail"

# ── 11. full-sweep integration (DRY_RUN): invariant (d) surge threshold ────
# Acceptance criterion 2: "10 divergentes numa rodada -> acoes destrutivas
# suspensas, um alarme agregado." Ten ledger entries, each on its own branch
# off a shared base, each genuinely divergent from the FINAL state of origin
# (unrelated commits keep advancing origin/main so nothing self-heals) — runs
# the REAL script end-to-end under SURVIVAL_DRY_RUN=1 (so a would-be bug can
# never touch a real bd/mail — dry-run is the safety net, not the thing under
# test) and inspects the log for what WOULD have happened.
echo "── 11. full-sweep integration: invariant (d) surge threshold (10 divergent) ──"
TB="$T/ga8hm65g_surge"; mkdir -p "$TB"
ROB="$TB/origin.git"; git init -q --bare -b main "$ROB" >/dev/null 2>&1
RRB="$TB/rig"; git clone -q "$ROB" "$RRB" >/dev/null 2>&1
git -C "$RRB" config user.email t@example.com
git -C "$RRB" config user.name  tester
echo base > "$RRB/base"; git -C "$RRB" add .; git -C "$RRB" commit -q -m base
git -C "$RRB" push -q origin main
BASEB=$(git -C "$RRB" rev-parse HEAD)
LEDGERB="$TB/ledger.jsonl"; : > "$LEDGERB"
for i in $(seq 1 10); do
  git -C "$RRB" checkout -q -b "side$i" "$BASEB" >/dev/null 2>&1
  echo "s$i" > "$RRB/s$i"; git -C "$RRB" add .; git -C "$RRB" commit -q -m "S$i"
  SHAI=$(git -C "$RRB" rev-parse HEAD)
  git -C "$RRB" checkout -q main >/dev/null 2>&1
  printf '{"ts":"%s","rig":"rigB","rig_path":"%s","default_branch":"main","branch":"side%s","bead":"","bead_city":"","gate_run":"","merge_sha":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RRB" "$i" "$SHAI" >> "$LEDGERB"
  # Advance origin/main with an UNRELATED commit each round so every side
  # branch stays genuinely divergent from origin's final tip either way.
  echo "m$i" > "$RRB/m$i"; git -C "$RRB" add .; git -C "$RRB" commit -q -m "M$i"
  git -C "$RRB" push -q origin main
done

OUTB=$(GC_CITY_PATH="$TB/city" SURVIVAL_LEDGER_FILE="$LEDGERB" SURVIVAL_ALERT_DIR="$TB/alerted" \
  SURVIVAL_DIVERGENT_SURGE_THRESHOLD=5 SURVIVAL_DRY_RUN=1 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)

printf '%s\n' "$OUTB" | grep 'WOULD-ESCALATE(divergent)' >/dev/null \
  && bad "surge: an individual per-sha escalation fired during a 10-divergent surge — output:
$OUTB" \
  || ok "surge: no individual per-sha escalation fired during a 10-divergent surge"
SURGE_LINES_B=$(printf '%s\n' "$OUTB" | grep -c 'WOULD-ESCALATE(surge)')
[ "$SURGE_LINES_B" = "1" ] \
  && ok "surge: exactly ONE aggregated surge alarm for 10 confirmed-divergent" \
  || bad "surge: expected exactly 1 aggregated alarm, got $SURGE_LINES_B — output:
$OUTB"
printf '%s\n' "$OUTB" | grep '10 confirmed-divergent' >/dev/null \
  && ok "surge alarm reports the true confirmed count (10)" \
  || bad "surge alarm does not report the count 10 — output:
$OUTB"
RECHECK_LINES_B=$(printf '%s\n' "$OUTB" | grep -c '^\[.*\] \[survival-sweep\] RECHECK ')
[ "$RECHECK_LINES_B" = "10" ] \
  && ok "surge: all 10 candidates were independently rechecked before the surge decision" \
  || bad "surge: expected 10 RECHECK log lines, got $RECHECK_LINES_B"

# ── 12. full-sweep integration (DRY_RUN): under threshold escalates normally
# Companion to #11 — proves the threshold gate works BOTH directions: a small
# number of genuinely-confirmed divergences still escalates individually
# (invariant a/c confirm-then-reopen, not "never reopen anything").
echo "── 12. full-sweep integration: under-threshold divergence still escalates individually ──"
TC="$T/ga8hm65g_small"; mkdir -p "$TC"
ROC="$TC/origin.git"; git init -q --bare -b main "$ROC" >/dev/null 2>&1
RRC="$TC/rig"; git clone -q "$ROC" "$RRC" >/dev/null 2>&1
git -C "$RRC" config user.email t@example.com
git -C "$RRC" config user.name  tester
echo base > "$RRC/base"; git -C "$RRC" add .; git -C "$RRC" commit -q -m base
git -C "$RRC" push -q origin main
BASEC=$(git -C "$RRC" rev-parse HEAD)
LEDGERC="$TC/ledger.jsonl"; : > "$LEDGERC"
for i in 1 2; do
  git -C "$RRC" checkout -q -b "side$i" "$BASEC" >/dev/null 2>&1
  echo "s$i" > "$RRC/s$i"; git -C "$RRC" add .; git -C "$RRC" commit -q -m "S$i"
  SHAI=$(git -C "$RRC" rev-parse HEAD)
  git -C "$RRC" checkout -q main >/dev/null 2>&1
  printf '{"ts":"%s","rig":"rigC","rig_path":"%s","default_branch":"main","branch":"side%s","bead":"","bead_city":"","gate_run":"","merge_sha":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RRC" "$i" "$SHAI" >> "$LEDGERC"
  echo "m$i" > "$RRC/m$i"; git -C "$RRC" add .; git -C "$RRC" commit -q -m "M$i"
  git -C "$RRC" push -q origin main
done

OUTC=$(GC_CITY_PATH="$TC/city" SURVIVAL_LEDGER_FILE="$LEDGERC" SURVIVAL_ALERT_DIR="$TC/alerted" \
  SURVIVAL_DIVERGENT_SURGE_THRESHOLD=5 SURVIVAL_DRY_RUN=1 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)

INDIV_LINES_C=$(printf '%s\n' "$OUTC" | grep -c 'WOULD-ESCALATE(divergent)')
[ "$INDIV_LINES_C" = "2" ] \
  && ok "under threshold: both genuinely-divergent entries escalate individually" \
  || bad "under threshold: expected 2 individual escalations, got $INDIV_LINES_C — output:
$OUTC"
printf '%s\n' "$OUTC" | grep 'WOULD-ESCALATE(surge)' >/dev/null \
  && bad "under threshold: surge path fired for only 2 confirmed-divergent (should not)" \
  || ok "under threshold: surge path did not fire for only 2 confirmed-divergent"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
