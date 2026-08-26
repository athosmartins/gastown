#!/usr/bin/env bash
# gate-needs-human-divergence-sweep.selftest.sh — prove the ga-u4yi divergence
# watch in isolation, with NO live Dolt/gc/launchd and NO network.
#
# Sources the sweep in lib-only mode for the REAL functions (one source of
# truth, no copy-drift), then:
#   • unit-tests branch_touched_files and files_diverged (the two functions
#     that implement ga-u4yi's suggested signal, `git log main -- <files>`)
#     across every case: no divergence yet, a colliding commit, an unrelated
#     commit that must NOT trigger, and unresolvable refs;
#   • unit-tests the retention/age helpers and in_list membership check;
#   • unit-tests the rig container/self git-dir resolution + git_in dispatch;
#   • DRIFT-GUARDS the live wiring in the sweep and the plist, and the
#     companion author-mail fix in quality-gate-dispatcher.sh.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SELF_DIR/gate-needs-human-divergence-sweep.sh"
PLIST="$SELF_DIR/gate-needs-human-divergence-sweep.plist"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
rc0() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d — expected rc0 from: $*"; fi; }
rc1() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d — expected non-zero from: $*"; else ok "$d"; fi; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
DIVERGENCE_LIB_ONLY=1 source "$SWEEP" \
  || { echo "FATAL: could not source sweep in lib-only mode"; exit 1; }
for fn in branch_touched_files files_diverged rig_gitdir git_in iso_to_epoch entry_within_retention in_list prune_decision; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by sweep"; exit 1; }
done

# ── Real-git fixture (local only, no network) ───────────────────────────────
T="$(mktemp -d 2>/dev/null || mktemp -d -t gau4yi)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
R="$T/repo"
git init -q -b main "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name  tester
echo a > "$R/a.txt"; echo b > "$R/b.txt"; git -C "$R" add .; git -C "$R" commit -q -m "C1 (a,b)"

# Feature branch off C1, touches ONLY c.txt (the file we'll watch).
git -C "$R" checkout -q -b feature
echo c > "$R/c.txt"; git -C "$R" add .; git -C "$R" commit -q -m "feature: add c"
FEATURE=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main

# Main advances touching a.txt (UNRELATED to feature's files) — must NOT count.
echo a2 >> "$R/a.txt"; git -C "$R" add .; git -C "$R" commit -q -m "main: touch a (unrelated)"
BASELINE=$(git -C "$R" rev-parse HEAD)

git -C "$R" update-ref refs/remotes/origin/main "$BASELINE"
git -C "$R" update-ref refs/remotes/origin/feature "$FEATURE"

# ── 1. branch_touched_files — the "what to watch" seed ──────────────────────
echo "── 1. branch_touched_files (triple-dot diff, same as dispatcher CHANGED_FILES) ──"
eq "feature vs main → touches exactly c.txt" \
   "$(branch_touched_files "$R" 0 "origin/main" "origin/feature")" "c.txt"

# ── 2. files_diverged — ga-u4yi's core signal ────────────────────────────────
echo "── 2. files_diverged (git log baseline..main -- files) ──"
eq "no new commits on main yet → empty (not diverging)" \
   "$(files_diverged "$R" 0 "$BASELINE" "origin/main" "c.txt")" ""

echo c2 >> "$R/c.txt"; git -C "$R" add .; git -C "$R" commit -q -m "main: touch c (COLLIDES with feature)"
COLLIDE_SHA=$(git -C "$R" rev-parse --short HEAD)
git -C "$R" update-ref refs/remotes/origin/main HEAD

case "$(files_diverged "$R" 0 "$BASELINE" "origin/main" "c.txt")" in
  "$COLLIDE_SHA"*"COLLIDES"*) ok "colliding commit on watched file → detected ($COLLIDE_SHA)" ;;
  *) bad "expected to detect colliding commit $COLLIDE_SHA, got: $(files_diverged "$R" 0 "$BASELINE" "origin/main" "c.txt")" ;;
esac

eq "unrelated file (never touched) → still empty" \
   "$(files_diverged "$R" 0 "$BASELINE" "origin/main" "z.txt")" ""

eq "no files given → empty (nothing to watch)" \
   "$(files_diverged "$R" 0 "$BASELINE" "origin/main")" ""

eq "unresolvable baseline → empty (fails safe, not error)" \
   "$(files_diverged "$R" 0 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "origin/main" "c.txt")" ""

eq "unresolvable main_ref → empty (fails safe, not error)" \
   "$(files_diverged "$R" 0 "$BASELINE" "origin/does-not-exist" "c.txt")" ""

# ── 2b. prune_decision — ga-u4yi gate-feedback attempt 1 blocking fix ───────
# The reviewer's blocking issue: `bd list ... || echo "[]"` conflated a FAILED
# discovery query with a confirmed-empty candidate set, so the PASS 1 primary
# pruner treated "query errored" the same as "bead resolved" and silently
# dropped still-live ledger entries (losing their baseline_sha on
# rediscovery). This simulates the failing `bd list` call the reviewer flagged
# as untested — not via a live Dolt/bd fake, but by directly driving the pure
# decision function with the (in_candidates, store_failed) inputs a real
# failure would produce, same style as verdict_count_from_query's selftest.
echo "── 2b. prune_decision (query-failure vs confirmed-empty, ga-u4yi attempt 1) ──"
eq "in candidates, store query ok → keep"                "$(prune_decision 1 0)" "keep"
eq "NOT in candidates, store query ok → prune (genuine resolve)" \
   "$(prune_decision 0 0)" "prune"
eq "NOT in candidates, store query FAILED → keep (fail-open, not a false-empty)" \
   "$(prune_decision 0 1)" "keep"
eq "in candidates, store query FAILED → keep" "$(prune_decision 1 1)" "keep"

# ── 3. age / retention + membership helpers ─────────────────────────────────
echo "── 3. age / retention / in_list helpers ──"
TS="2026-06-11T00:00:00Z"
EXP=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$TS" +%s 2>/dev/null || echo X)
eq "iso_to_epoch parses UTC ts" "$(iso_to_epoch "$TS")" "$EXP"
NOW=$(date -u +%s)
TS_RECENT=$(date -u -r $(( NOW - 86400 ))     +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
TS_OLD=$(date    -u -r $(( NOW - 45*86400 ))  +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
rc0 "1-day-old entry within 30d retention"    entry_within_retention "$TS_RECENT" "$NOW" 30
rc1 "45-day-old entry outside 30d retention"  entry_within_retention "$TS_OLD" "$NOW" 30
rc0 "unparseable ts FAILS OPEN (kept)"        entry_within_retention "garbage" "$NOW" 30
rc0 "in_list finds a present element"         in_list "wa-jbrjj" "ga-abc" "wa-jbrjj" "wa-xyz"
rc1 "in_list misses an absent element"        in_list "wa-nope" "ga-abc" "wa-jbrjj"

# ── 4. rig_gitdir + git_in dispatch ──────────────────────────────────────────
echo "── 4. rig container/self resolution ──"
mkdir -p "$T/crig/.repo.git" "$T/srig"
eq "container rig → .repo.git + flag 1" "$(rig_gitdir "$T/crig")" "$(printf '%s\t1' "$T/crig/.repo.git")"
eq "self rig → path + flag 0"           "$(rig_gitdir "$T/srig")" "$(printf '%s\t0' "$T/srig")"
eq "git_in self (container=0)"          "$(git_in "$R" 0 rev-parse --abbrev-ref HEAD)" "main"

# ── 5. drift-guard: sweep wiring ─────────────────────────────────────────────
echo "── 5. drift-guard: sweep wiring ──"
grep -q 'DIVERGENCE_LIB_ONLY'                "$SWEEP" && ok "sweep sourceable in lib-only mode"       || bad "missing lib-only hook"
grep -q 'files_diverged()'                   "$SWEEP" && ok "defines files_diverged"                  || bad "missing files_diverged def"
grep -q 'branch_touched_files()'             "$SWEEP" && ok "defines branch_touched_files"             || bad "missing branch_touched_files def"
grep -q 'escalate_diverging()'               "$SWEEP" && ok "defines escalate_diverging"               || bad "missing escalate_diverging def"
grep -q 'gate:needs-human:diverging'         "$SWEEP" && ok "labels escalated bead diverging"          || bad "diverging label missing"
grep -q 'mail send "\$author"'               "$SWEEP" && ok "escalates to the AUTHOR"                  || bad "author escalation missing"
grep -q 'mail send mayor'                    "$SWEEP" && ok "escalates to the Mayor"                   || bad "Mayor escalation missing"
grep -Eq 'label "gate:needs-human" --status=open' "$SWEEP" && ok "queries the live gate:needs-human candidate set" || bad "candidate query missing/changed"
grep -q -- '--all'                           "$SWEEP" && ok "marker lookup includes CLOSED markers (--all)"  || bad "marker lookup missing --all (would miss every parked marker)"
grep -q 'entry_within_retention'             "$SWEEP" && ok "retention backstop wired"                 || bad "retention backstop missing"
grep -q 'should_alert'                       "$SWEEP" && ok "per-bead escalation rate-limit wired"     || bad "rate-limit missing"
grep -q 'DIVERGENCE_DRY_RUN'                 "$SWEEP" && ok "dry-run supported"                        || bad "dry-run support missing"
grep -q 'date -u -j -f "%Y-%m-%dT%H:%M:%SZ"' "$SWEEP" && ok "iso_to_epoch uses -u (UTC age, ga-35zp1)"  || bad "missing -u UTC guard"
# The primary pruner MUST be presence-in-candidates, not just time — a bead
# that resolves in 10 minutes should stop being tracked in 10 minutes, not
# linger for the full retention window.
grep -q 'no longer gate:needs-human'         "$SWEEP" && ok "prunes on resolution (not just time)"      || bad "presence-based pruning missing"

# ga-u4yi gate-feedback attempt 1: candidate-discovery and marker-lookup
# queries must capture bd's exit status, not mask a FAILED query behind
# `|| echo "[]"` (which the PASS 1 primary pruner would then read as
# confirmed-resolved). Fixed-string greps against the exact live code so this
# can never silently regress back to the naive idiom.
grep -qF 'prune_decision()' "$SWEEP" \
  && ok "defines prune_decision" || bad "missing prune_decision def"
grep -qF 'prune_decision "$_in_cand" "$_store_failed"' "$SWEEP" \
  && ok "PASS 1 primary pruner calls prune_decision (not raw in_list)" \
  || bad "PASS 1 primary pruner does not call prune_decision — REGRESSION risk"
grep -qF 'FAILED_STORES+=("$_store")' "$SWEEP" \
  && ok "candidate-discovery tracks per-store query failures" \
  || bad "FAILED_STORES tracking missing"
grep -qF 'if ! _found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null); then' "$SWEEP" \
  && ok "candidate query captures rc without masking (no naive || echo fallback)" \
  || bad "candidate query regressed to masking rc — REGRESSION of ga-u4yi attempt 1 fix"
if grep -qF '_found=$(bd -C "$_store" list --label "gate:needs-human" --status=open --json 2>/dev/null || echo "[]")' "$SWEEP"; then
  bad "naive || echo \"[]\" candidate-query idiom is back — REGRESSION"
else
  ok "naive || echo \"[]\" candidate-query idiom removed"
fi
grep -qF 'if ! MARKERS=$(bd -C "$GC_CITY" list --label "source-bead:$BEAD_ID" --all --json 2>/dev/null); then' "$SWEEP" \
  && ok "PASS 2 marker query captures rc without masking" \
  || bad "PASS 2 marker query regressed to masking rc — REGRESSION of ga-u4yi attempt 1 fix"

# ── 6. drift-guard: plist ────────────────────────────────────────────────────
echo "── 6. drift-guard: plist ──"
if [ -f "$PLIST" ]; then
  grep -q 'com.gascity.gate-needs-human-divergence-sweep' "$PLIST" && ok "plist Label correct"     || bad "plist Label wrong"
  grep -q '<key>StartInterval</key>'                       "$PLIST" && ok "plist uses StartInterval" || bad "plist missing StartInterval"
  grep -q '<key>RunAtLoad</key><true/>'                    "$PLIST" && ok "plist RunAtLoad=true"     || bad "plist missing RunAtLoad"
  grep -q 'gate-needs-human-divergence-sweep.sh'           "$PLIST" && ok "plist points at the sweep script" || bad "plist ProgramArguments wrong"
else
  bad "plist not found at $PLIST"
fi

# ── 7. drift-guard: companion author-mail fix in the dispatcher (ga-u4yi) ───
echo "── 7. drift-guard: companion fix — dispatcher mails AUTHOR at needs-human transitions ──"
if [ -f "$DISPATCHER" ]; then
  # ga-4op40 (3rd occurrence of this exact drift: 4→5→6, now 8): a hardcoded
  # magic-number count needs a human to hand-bump it every time the dispatcher
  # legitimately grows a new gate:needs-human site. This file's own attempt at
  # a durable fix (comparing the AUTHOR-mail count against an independent
  # count of gate:needs-human label-add sites) was STILL a bidirectional
  # count match — and count matches break the moment either side gains an
  # UNRELATED occurrence. ga-6dpoa added an AUTHOR/NOTIFY_AUTHOR mail for the
  # scope-hold path (delivery:partial + scope:needs-review) that is
  # DELIBERATELY kept outside the gate:needs-human label family (it used to
  # collide with the lifecycle-coherence-janitor R7 rule — see that call
  # site's own comment) — a legitimate site with no gate:needs-human label at
  # all, which the mail-side count still picks up. 9 label-add sites, 10
  # mails: count equality can never distinguish that from a real silent site.
  #
  # ga-huaxo already solved this properly in gate-selfheal.selftest.sh's copy
  # of this same check: a one-directional BIJECTION, not a count match. Ported
  # here verbatim (same 40-line window, measured site→mail distance 9-21
  # lines across all current sites). This is immune to unrelated mail sends
  # anywhere else in the file, because it never counts total mails — it only
  # asks, per gate:needs-human site, "is there an AUTHOR mail nearby?".
  # ga-409f4: mail send "$AUTHOR" OR "$NOTIFY_AUTHOR" — the branch-author-aware
  # variable now used at some (not all) sites is the same durable-mail-to-a-
  # real-identity signal, just no longer always the bead-assignee-derived one
  # (see quality-gate-dispatcher.sh's gate_finalize_run header comment for why
  # the two variables coexist).
  #
  # ga-36ta4: site detection now looks for gate_apply_needs_human() calls, not
  # the raw `label add ... "gate:needs-human"` line — ga-55syh replaced every
  # site's inline label-add with a call to that shared verify-then-apply
  # helper, so the old pattern now matches ZERO sites (this check would have
  # gone from a real bijection proof to a silent "0 sites, vacuously fine" —
  # caught here specifically BECAUSE this check demands _n_sites >= 1, so it
  # would have failed loudly rather than passing quietly; fixed properly
  # instead of just re-lowering the bar).
  #
  # ga-36ta4 (found during that same fix, unrelated to the detection-pattern
  # change above): the AUTHOR-mail-nearby check ALSO only recognized a literal
  # `mail send "$AUTHOR"`/`"$NOTIFY_AUTHOR"` call, not the
  # notify_author_with_fallback() wrapper several sites (including the
  # long-standing ga-lxz5w one) already use — confirmed as a real
  # false-positive by running this exact check against a clean, unmodified
  # dispatcher.sh at HEAD before any ga-55syh/ga-36ta4 changes existed. Widened
  # to recognize either form.
  NEEDS_HUMAN_SITES=$(grep -nE '_NH_STATUS=\$\(gate_apply_needs_human "\$BEAD_CITY" "\$BEAD_ID"' "$DISPATCHER" \
    | cut -d: -f1)
  _bij_ok=1; _bij_bad_line=""
  for _site in $NEEDS_HUMAN_SITES; do
    if ! sed -n "${_site},$((_site + 40))p" "$DISPATCHER" | grep -Eq 'mail send "\$(AUTHOR|NOTIFY_AUTHOR)"|notify_author_with_fallback'; then
      _bij_ok=0; _bij_bad_line="$_site"; break
    fi
  done
  _n_sites=$(printf '%s\n' "$NEEDS_HUMAN_SITES" | grep -c .)
  if [ "$_bij_ok" = 1 ] && [ "$_n_sites" -ge 1 ]; then
    ok "every gate:needs-human site ($_n_sites) has an adjacent AUTHOR mail (ga-huaxo bijection, no magic count)"
  else
    bad "gate:needs-human site at line $_bij_bad_line has NO AUTHOR mail within 40 lines — a SILENT park (ga-u4yi/ga-huaxo)"
  fi
else
  bad "dispatcher not found at $DISPATCHER"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
