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
          raw_fetch recheck_divergent divergent_surge parse_entry_fields \
          _git_in_bounded _survival_patch_equivalent _bead_closed_state _bead_snapshot _orphan_write_report; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by sweep"; exit 1; }
done

# ── Real-git fixture (local only, no network) ───────────────────────────────
T="$(mktemp -d 2>/dev/null || mktemp -d -t galzj2e)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
# ga-ck3sz7: every full-sweep child below (`bash "$SWEEP"`) runs on a PATH with NO real gc/bd
# (selftest-sandbox-path.lib.sh). The sweep reopens/labels/comments beads and mails the Mayor; SURVIVAL_DRY_RUN=1 is
# the only thing standing between it and the real town, and a fake bd earlier in PATH only holds while $T exists.
# Here "command not found" is the only outcome. The fake `bd` (used by sections 13/14) lives in $T/bin from the start.
# ga-cqnm73: an UNKNOWN bead gets an EMPTY answer, which the sweep now reads as "could not tell" (inert), no longer
# as "not closed". The surge tests (11/12) never reach it: their ledger entries carry no bead id.
. "$SELF_DIR/selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/selftest-sandbox-path.lib.sh" >&2; exit 2; }
FAKE_BD_DIR="$T/bin"; mkdir -p "$FAKE_BD_DIR"
FAKE_BD_STATE="$T/bdstate"; mkdir -p "$FAKE_BD_STATE"; export FAKE_BD_STATE
FAKE_GC_DIR="$T/gcmail"; mkdir -p "$FAKE_GC_DIR"; export FAKE_GC_DIR
cat > "$FAKE_BD_DIR/bd" <<'FAKEBD'
#!/usr/bin/env bash
# invoked as: bd -C <city> show <bead> --json | reopen <bead> | comment <bead> <text> | label add <bead> <label> -q
verb="$3"; bead="$4"; S="${FAKE_BD_STATE:-/nonexistent}"
calls() { local f="$S/$1.calls" n=0; [ -f "$f" ] && n=$(cat "$f"); n=$((n+1)); echo "$n" > "$f"; echo "$n"; }
case "$verb" in
  show)
    case "$bead" in
      closed-story) echo '{"id":"closed-story","status":"closed"}' ;;
      closed-story-array) echo '[{"id":"closed-story-array","status":"closed"}]' ;;
      open-story) echo '{"id":"open-story","status":"open"}' ;;
      failing-story) echo "Error: dolt connection refused" >&2; exit 1 ;;          # bd FAILED
      hanging-story) sleep 5; echo '{"id":"hanging-story","status":"closed"}' ;;   # bd HUNG (caller times out)
      garbage-story) echo "not json at all" ;;
      nostatus-story) echo '{"id":"nostatus-story"}' ;;
      empty-array-story) echo '[]' ;;
      nonexistent-story)                                                          # bd's real "no such bead" answer
        echo '{"error":"no issues found matching the provided IDs","schema_version":1}'
        echo "Error fetching nonexistent-story: no issue found matching" >&2; exit 1 ;;
      wr-fail) echo '{"id":"wr-fail","status":"open","labels":[],"comment_count":7}' ;;   # every write below is a silent no-op
      wr-blind)                                                                    # readable twice, then bd drops
        if [ "$(calls wr-blind)" -le 2 ]; then echo '{"id":"wr-blind","status":"open","labels":[],"comment_count":3}'
        else echo "Error: connection lost" >&2; exit 1; fi ;;
      wr-ok*)                                                                      # stateful: the writes really land
        st="$(cat "$S/$bead.status" 2>/dev/null || echo open)"; cnt="$(cat "$S/$bead.count" 2>/dev/null || echo 7)"
        if grep -qx 'gate:merge-orphan' "$S/$bead.labels" 2>/dev/null; then lbl='["gate:merge-orphan"]'; else lbl='[]'; fi
        echo "{\"id\":\"$bead\",\"status\":\"$st\",\"labels\":$lbl,\"comment_count\":$cnt}" ;;
      *) echo "" ;;  # not found / empty response
    esac ;;
  reopen)  case "$bead" in wr-ok*) echo open > "$S/$bead.status" ;; esac ;;
  comment) case "$bead" in wr-ok*) c="$(cat "$S/$bead.count" 2>/dev/null || echo 7)"; echo $((c+1)) > "$S/$bead.count" ;; esac ;;
  label)   case "$5" in wr-ok*) echo "$6" >> "$S/$5.labels" ;; esac ;;
esac
exit 0
FAKEBD
chmod +x "$FAKE_BD_DIR/bd"
# Fake `gc`: records each `mail send` as one file of one-arg-per-line. A stub in $T/bin only (sandbox lib: gc/bd may
# ONLY ever be stubs) — when $T goes away the child has no gc at all.
cat > "$FAKE_BD_DIR/gc" <<'FAKEGC'
#!/usr/bin/env bash
n=$(ls "${FAKE_GC_DIR:-/nonexistent}" 2>/dev/null | wc -l | tr -d ' ')
{ for a in "$@"; do printf '%s\n' "$a"; done; } > "${FAKE_GC_DIR:-/nonexistent}/call.$n" 2>/dev/null
exit 0
FAKEGC
chmod +x "$FAKE_BD_DIR/gc"
sandbox_path_init "$T" git jq timeout || exit 2   # git: the sweep's ancestry checks; jq: ledger parse; timeout: bounds fetch; bd is the fake above
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

# ── 1c. ga-kj7fpt: a `git merge-base --is-ancestor` command that itself FAILS
# (rc>1 — corrupt commit-graph, lock contention, transient object-store error)
# must NOT be treated as "not an ancestor" (rc1). The pre-fix code ran the
# is-ancestor calls as a bare `if ...; then`, which only distinguishes rc0
# from "anything else" — a real git failure on EITHER direction check was
# silently swallowed and fell through to content-equivalence and then plain
# "divergent", exactly the false-positive class that produced 97 bogus
# divergent verdicts in one live sweep (28/09, 14:57-14:58). A fake `git`
# on PATH that returns 128 ONLY for merge-base --is-ancestor (passing every
# other invocation through to the real binary unchanged) isolates the one
# failure mode under test without faking the whole git surface.
echo "── 1c. ga-kj7fpt: git error on is-ancestor must not misclassify as divergent ──"
REAL_GIT="$(command -v git)"
FAKE_GIT_ERR_DIR="$T/fakegit_err"; mkdir -p "$FAKE_GIT_ERR_DIR"
cat > "$FAKE_GIT_ERR_DIR/git" <<FAKEGIT
#!/usr/bin/env bash
case " \$* " in
  *" merge-base --is-ancestor "*)
    echo "fatal: simulated git error (e.g. corrupt commit-graph)" >&2
    exit 128
    ;;
esac
exec "$REAL_GIT" "\$@"
FAKEGIT
chmod +x "$FAKE_GIT_ERR_DIR/git"

git -C "$R" update-ref refs/remotes/origin/main "$D1"
eq "sanity: with a healthy git, this pair is genuinely divergent" \
  "$(survival_classify "$R" 0 "$C3" origin/main)" "divergent"
eq "is-ancestor rc=128 (git failure) on the FIRST direction checked -> unresolved, NOT divergent" \
  "$(PATH="$FAKE_GIT_ERR_DIR:$PATH" survival_classify "$R" 0 "$C3" origin/main)" "unresolved"

# ── 1d. ga-kj7fpt gate-review finding: the 1c test above passes vacuously.
# `$(...)` makes `[ -t 1 ]` false and SURVIVAL_LOG_STDOUT defaults to 0, so
# _log_emit() never echoes and _is_ancestor's `res` is a clean "error" even
# WITHOUT the fix. gate-merge-survival-sweep.plist sets SURVIVAL_LOG_STDOUT=1
# unconditionally in production, so THIS is the config that must be tested:
# under it, warn()'s log line used to land inside `res=$(_is_ancestor ...)`
# ahead of the "error" token, a two-line value the exact-match
# `case "$res" in error)` can't match — falling through silently toward
# content-equivalence/divergent, reproducing the original bug. The fix pins
# warn()'s output to fd2 for this one call so it can never enter the
# captured return channel, regardless of SURVIVAL_LOG_STDOUT.
echo "── 1d. ga-kj7fpt: same failure, but under the ACTUAL production config (SURVIVAL_LOG_STDOUT=1) ──"
eq "is-ancestor rc=128 UNDER PRODUCTION LOGGING CONFIG -> still unresolved, NOT divergent" \
  "$(SURVIVAL_LOG_STDOUT=1 PATH="$FAKE_GIT_ERR_DIR:$PATH" survival_classify "$R" 0 "$C3" origin/main)" "unresolved"

# ── 1e. ga-cqnm73: patch-equivalence (git cherry) — the fix landed under a
# different sha AND a later commit then touched the same file. wa-k8l0m
# 5963c0c23 (21/09) vs 5c30b3a62 + 1255 later commits (03/10): the byte check in
# _survival_content_equivalent compares the file as it is on main NOW, so it can
# no longer match, and the sweep mailed the Mayor a false "orphaned" alarm.
# git cherry matches by patch-id, which does not move when the file does.
echo "── 1e. ga-cqnm73: patch-equivalence when the file evolved after the patch ──"
PE_BLOB_PATCH="PATCH-B"
git -C "$R" checkout -q -b pe-sha "$C1"
echo "$PE_BLOB_PATCH" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "the gate-merged sha"
PE1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b pe-main "$C1"
echo "$PE_BLOB_PATCH" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "same patch, landed under a different sha"
PE2=$(git -C "$R" rev-parse HEAD)
echo "later unrelated evolution of the same file" >> "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "a later commit touches the same file"
PE3=$(git -C "$R" rev-parse HEAD)
# Controls: a DIFFERENT patch; a sha whose only twin is one of its two commits; a hidden merge.
git -C "$R" checkout -q -b pe-diff "$C1"
echo "A-GENUINELY-DIFFERENT-PATCH" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "different patch"
PEX=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q -b pe-partial "$C1"
echo "$PE_BLOB_PATCH" > "$R/b"; git -C "$R" add .; git -C "$R" commit -q -m "twin of PE2 (patch present on main)"
echo "z" > "$R/z"; git -C "$R" add .; git -C "$R" commit -q -m "second commit, NO twin on main"
PEP=$(git -C "$R" rev-parse HEAD)
# 2-parent commit whose tree is PE1's, second parent C1 (already in mref's history, so the merge adds no commit
# to mref..sha besides itself and PE1): every non-merge commit in the range HAS a twin, only the merge could hide
# unreviewed conflict-resolution content — `git cherry` skips merges silently.
PEM=$(git -C "$R" commit-tree "${PE1}^{tree}" -p "$PE1" -p "$C1" -m "merge hiding from git cherry" 2>/dev/null || echo "")
git -C "$R" checkout -q main

# Prove the fixture is the real shape: neither ancestor, and the byte check CANNOT see the equivalence.
rc1 "fixture: PE1 is not an ancestor of PE3"  git -C "$R" merge-base --is-ancestor "$PE1" "$PE3"
rc1 "fixture: PE3 is not an ancestor of PE1"  git -C "$R" merge-base --is-ancestor "$PE3" "$PE1"
rc1 "fixture: the BYTE check alone fails (file evolved after the patch)" _survival_content_equivalent "$R" 0 "$PE1" "$PE3"
eq  "_survival_patch_equivalent: every commit has a patch-id twin -> yes" "$(_survival_patch_equivalent "$R" 0 "$PE1" "$PE3")" "yes"
eq  "survival_classify: patch twin on main, file evolved since -> content_equivalent (was divergent)" \
  "$(survival_classify "$R" 0 "$PE1" "$PE3")" "content_equivalent"
eq  "CONTROL: a different patch has no twin -> no" "$(_survival_patch_equivalent "$R" 0 "$PEX" "$PE3")" "no"
eq  "CONTROL: a different patch -> still plain divergent" "$(survival_classify "$R" 0 "$PEX" "$PE3")" "divergent"
eq  "CONTROL: only ONE of the sha's two commits has a twin -> no" "$(_survival_patch_equivalent "$R" 0 "$PEP" "$PE3")" "no"
eq  "CONTROL: partial twin -> still divergent" "$(survival_classify "$R" 0 "$PEP" "$PE3")" "divergent"
if [ -n "$PEM" ] && [ "$(git -C "$R" rev-parse "${PEM}^@" 2>/dev/null | grep -c .)" = "2" ]; then
  eq "merge commit in mref..sha -> no, even though every non-merge commit has a twin" "$(_survival_patch_equivalent "$R" 0 "$PEM" "$PE3")" "no"
  eq "merge commit in mref..sha -> divergent (never takes the equivalence shortcut)" "$(survival_classify "$R" 0 "$PEM" "$PE3")" "divergent"
else
  bad "merge fixture did not produce 2 parents — merge guard unasserted"
fi
# Container layout (the rigs live in <rig>/.repo.git): same answer through --git-dir.
BARE="$T/pe-bare.git"; git clone -q --bare "$R" "$BARE" >/dev/null 2>&1
eq "container (bare --git-dir) layout gives the same answer" "$(_survival_patch_equivalent "$BARE" 1 "$PE1" "$PE3")" "yes"

# Failure injection: git cherry (or the rev-list merge counter) FAILS. That is not "no" — "no" ends in a bead reopen and
# a Mayor mail. It must surface as unresolved (the ga-kj7fpt rule), under the production logging config too: warn()
# echoes to stdout there, and must not land inside the captured return value.
FAKE_GIT_CHERRY_DIR="$T/fakegit_cherry"; mkdir -p "$FAKE_GIT_CHERRY_DIR"
cat > "$FAKE_GIT_CHERRY_DIR/git" <<FAKEGIT
#!/usr/bin/env bash
case " \$* " in
  *" cherry "*) echo "fatal: simulated git failure (cherry)" >&2; exit 128 ;;
esac
exec "$REAL_GIT" "\$@"
FAKEGIT
chmod +x "$FAKE_GIT_CHERRY_DIR/git"
FAKE_GIT_COUNT_DIR="$T/fakegit_count"; mkdir -p "$FAKE_GIT_COUNT_DIR"
cat > "$FAKE_GIT_COUNT_DIR/git" <<FAKEGIT
#!/usr/bin/env bash
case " \$* " in
  *" rev-list --count --no-merges "*) echo "fatal: simulated git failure (rev-list)" >&2; exit 128 ;;
esac
exec "$REAL_GIT" "\$@"
FAKEGIT
chmod +x "$FAKE_GIT_COUNT_DIR/git"
eq "git cherry fails -> patch check says error, not no" \
  "$(PATH="$FAKE_GIT_CHERRY_DIR:$PATH" _survival_patch_equivalent "$R" 0 "$PE1" "$PE3")" "error"
eq "git cherry fails -> classify says unresolved, NOT divergent" \
  "$(PATH="$FAKE_GIT_CHERRY_DIR:$PATH" survival_classify "$R" 0 "$PE1" "$PE3")" "unresolved"
eq "git cherry fails UNDER PRODUCTION LOGGING CONFIG -> still unresolved (warn must not leak into the value)" \
  "$(SURVIVAL_LOG_STDOUT=1 PATH="$FAKE_GIT_CHERRY_DIR:$PATH" survival_classify "$R" 0 "$PE1" "$PE3")" "unresolved"
eq "only the rev-list merge counter fails -> error, not a silent no" \
  "$(PATH="$FAKE_GIT_COUNT_DIR:$PATH" _survival_patch_equivalent "$R" 0 "$PE1" "$PE3")" "error"
eq "CONTROL: git cherry failing does not touch pairs decided by ancestry" \
  "$(PATH="$FAKE_GIT_CHERRY_DIR:$PATH" survival_classify "$R" 0 "$C1" "$C3")" "survived"

# ── 1f. ga-cqnm73: the same shape through the REAL sweep (dry-run) — a divergent-by-ancestry sha whose patch is on
# main must be logged as content-equivalent, not escalated. This is the "the sha stops generating mail" proof.
echo "── 1f. ga-cqnm73: full sweep — patch-equivalent sha is not escalated ──"
TP="$T/ga_cqnm73_pe"; mkdir -p "$TP"
ROP="$TP/origin.git"; git init -q --bare -b main "$ROP" >/dev/null 2>&1
RRP="$TP/rig"; git clone -q "$ROP" "$RRP" >/dev/null 2>&1
git -C "$RRP" config user.email t@example.com; git -C "$RRP" config user.name tester
echo base > "$RRP/f"; git -C "$RRP" add .; git -C "$RRP" commit -q -m base; git -C "$RRP" push -q origin main
BASEP=$(git -C "$RRP" rev-parse HEAD)
git -C "$RRP" checkout -q -b fixbranch "$BASEP" >/dev/null 2>&1
echo "the fix" > "$RRP/f"; git -C "$RRP" add .; git -C "$RRP" commit -q -m "fix (ledger sha)"
SHAP=$(git -C "$RRP" rev-parse HEAD)
git -C "$RRP" checkout -q main >/dev/null 2>&1
echo "the fix" > "$RRP/f"; git -C "$RRP" add .; git -C "$RRP" commit -q -m "fix (re-landed under another sha)"
echo "later change to the same file" >> "$RRP/f"; git -C "$RRP" add .; git -C "$RRP" commit -q -m "file evolves afterwards"
git -C "$RRP" push -q origin main
LEDGERP="$TP/ledger.jsonl"
printf '{"ts":"%s","rig":"rigP","rig_path":"%s","default_branch":"main","branch":"fixbranch","bead":"","bead_city":"","gate_run":"","merge_sha":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RRP" "$SHAP" > "$LEDGERP"
OUTP=$(PATH="$SANDBOX_PATH" GC_CITY_PATH="$TP/city" SURVIVAL_LEDGER_FILE="$LEDGERP" SURVIVAL_ALERT_DIR="$TP/alerted" \
  SURVIVAL_DRY_RUN=1 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)
printf '%s\n' "$OUTP" | grep -q "content-equivalent $SHAP" \
  && ok "patch-equivalent sha is logged content-equivalent" \
  || bad "patch-equivalent sha was not logged content-equivalent — output:
$OUTP"
printf '%s\n' "$OUTP" | grep -q 'WOULD-ESCALATE\|DIVERGENT\|queued for recheck' \
  && bad "patch-equivalent sha was queued/escalated as divergent — the false alarm ga-cqnm73 removes — output:
$OUTP" \
  || ok "patch-equivalent sha is never queued or escalated"
printf '%s\n' "$OUTP" | grep -q 'content_equivalent=1 .*divergent=0' \
  && ok "summary line: content_equivalent=1 divergent=0" \
  || bad "summary line does not show content_equivalent=1 divergent=0 — output:
$OUTP"

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
# ga-kj7fpt: the raw `merge-base --is-ancestor` call moved into the
# _is_ancestor helper (so its rc can be checked properly) — the direction
# guard now asserts on the call SITE (mref then sha = origin-ancestor-of-
# merge), not the git invocation itself.
grep -q '_is_ancestor "\$gdir" "\$container" "\$mref" "\$sha"' "$SWEEP" && ok "ff_heal direction is origin-ancestor-of-merge (lossless)" || bad "ff_heal ancestry direction wrong/missing"
grep -q '_is_ancestor()' "$SWEEP" && ok "defines _is_ancestor helper (ga-kj7fpt)" || bad "missing _is_ancestor def"
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

OUTB=$(PATH="$SANDBOX_PATH" GC_CITY_PATH="$TB/city" SURVIVAL_LEDGER_FILE="$LEDGERB" SURVIVAL_ALERT_DIR="$TB/alerted" \
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

OUTC=$(PATH="$SANDBOX_PATH" GC_CITY_PATH="$TC/city" SURVIVAL_LEDGER_FILE="$LEDGERC" SURVIVAL_ALERT_DIR="$TC/alerted" \
  SURVIVAL_DIVERGENT_SURGE_THRESHOLD=5 SURVIVAL_DRY_RUN=1 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)

INDIV_LINES_C=$(printf '%s\n' "$OUTC" | grep -c 'WOULD-ESCALATE(divergent)')
[ "$INDIV_LINES_C" = "2" ] \
  && ok "under threshold: both genuinely-divergent entries escalate individually" \
  || bad "under threshold: expected 2 individual escalations, got $INDIV_LINES_C — output:
$OUTC"
printf '%s\n' "$OUTC" | grep 'WOULD-ESCALATE(surge)' >/dev/null \
  && bad "under threshold: surge path fired for only 2 confirmed-divergent (should not)" \
  || ok "under threshold: surge path did not fire for only 2 confirmed-divergent"


# ── 13. _bead_closed_state (ga-f7czjc, three-state since ga-cqnm73) — unit + full-sweep ────
# wa-k8l0m re-escalated 4 times: content_equivalent (already tested above)
# correctly handles a FRESH rebase, but is structurally unable to prove
# equivalence once the repo keeps evolving for unrelated reasons after the
# duplicate fix lands. _bead_closed_state is the independent second net:
# a CLOSED bead means a human already resolved this exact concern, so the
# sweep must not reopen it just because a point-in-time file diff no longer
# matches. ga-cqnm73: that net used to be rc0/rc1, so a bd that FAILED or
# TIMED OUT read as "not closed" and fell through to a reopen + Mayor mail on
# a bead that was closed all along (03/10 11:38 skipped, 12:11 escalated, same
# sha, same closed bead). It now answers closed | open | none | unknown, and
# the sweep treats anything but open/none as inert.
echo "── 13. _bead_closed_state (closed-bead escalation skip, three states) ──"

# 13a. Unit tests via a fake `bd` on PATH (this file hardcodes the `bd`
# command name throughout, no BD_BIN-style override exists to inject
# through, so PATH-prepending a fake executable is the standard way to test
# it without touching a real Dolt store -- matches this file's own stated
# "NO live Dolt" testing philosophy).
OLDPATH="$PATH"; PATH="$SANDBOX_PATH"   # fake bd is $T/bin/bd (defined at the top, with the sandbox)

eq "closed bead -> closed"                          "$(_bead_closed_state anycity closed-story)" "closed"
eq "closed bead, array-shaped bd output -> closed"  "$(_bead_closed_state anycity closed-story-array)" "closed"
eq "open bead -> open"                              "$(_bead_closed_state anycity open-story)" "open"
eq "bd answers 'no issue found' (rc1 + error JSON) -> none (a real answer: nothing to defer to)" \
  "$(_bead_closed_state anycity nonexistent-story)" "none"
eq "empty bead id -> none (no bd call needed)"      "$(_bead_closed_state anycity "")" "none"
eq "empty beadcity -> none (no bd call needed)"     "$(_bead_closed_state "" closed-story)" "none"
# The class this bead is about: a failed read must be a third answer, never a second one.
eq "bd FAILS (rc1, connection refused) -> unknown, NOT open"  "$(_bead_closed_state anycity failing-story)" "unknown"
eq "bd returns an empty answer -> unknown, NOT open"          "$(_bead_closed_state anycity empty-story)" "unknown"
eq "bd returns non-JSON -> unknown"                           "$(_bead_closed_state anycity garbage-story)" "unknown"
eq "bd returns JSON with no status -> unknown"                "$(_bead_closed_state anycity nostatus-story)" "unknown"
eq "bd returns [] -> unknown"                                 "$(_bead_closed_state anycity empty-array-story)" "unknown"
eq "bd HANGS past the timeout -> unknown (bounded, never blocks the sweep)" \
  "$(BD_TIMEOUT=1 _bead_closed_state anycity hanging-story)" "unknown"
eq "bd fails UNDER PRODUCTION LOGGING CONFIG -> still exactly 'unknown' (warn must not leak into the value)" \
  "$(SURVIVAL_LOG_STDOUT=1 _bead_closed_state anycity failing-story)" "unknown"

PATH="$OLDPATH"

# 13b. Full-sweep integration (DRY_RUN): a closed-bead sha must show
# WOULD-SKIP(closed-bead) and must NOT show WOULD-ESCALATE(divergent); an
# open-bead sha with equally-divergent content must still escalate normally
# (control -- guards against this fix silently swallowing real escalations).
TD="$T/ga_f7czjc"; mkdir -p "$TD"
ROD="$TD/origin.git"; git init -q --bare -b main "$ROD" >/dev/null 2>&1
RRD="$TD/rig"; git clone -q "$ROD" "$RRD" >/dev/null 2>&1
git -C "$RRD" config user.email t@example.com
git -C "$RRD" config user.name  tester
echo base > "$RRD/base"; git -C "$RRD" add .; git -C "$RRD" commit -q -m base
git -C "$RRD" push -q origin main
BASED=$(git -C "$RRD" rev-parse HEAD)
LEDGERD="$TD/ledger.jsonl"; : > "$LEDGERD"
# side1/closed-story: will end up divergent from origin/main, ledger points
# at bead=closed-story (fake bd says closed).
# side2/open-story: identical shape, ledger points at bead=open-story (fake
# bd says open) -- the control.
# side3/failing-story (ga-cqnm73): equally divergent, but bd FAILS on the status read -> neither "closed" nor "open":
# it must NOT be escalated this sweep (no reopen, no Mayor mail), and must be counted in the summary.
declare -A STORY_FOR=( [1]="closed-story" [2]="open-story" [3]="failing-story" )
for i in 1 2 3; do
  git -C "$RRD" checkout -q -b "side$i" "$BASED" >/dev/null 2>&1
  echo "s$i" > "$RRD/s$i"; git -C "$RRD" add .; git -C "$RRD" commit -q -m "S$i"
  SHAD=$(git -C "$RRD" rev-parse HEAD)
  git -C "$RRD" checkout -q main >/dev/null 2>&1
  printf '{"ts":"%s","rig":"rigD","rig_path":"%s","default_branch":"main","branch":"side%s","bead":"%s","bead_city":"anycity","gate_run":"","merge_sha":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RRD" "$i" "${STORY_FOR[$i]}" "$SHAD" >> "$LEDGERD"
  echo "m$i" > "$RRD/m$i"; git -C "$RRD" add .; git -C "$RRD" commit -q -m "M$i"
  git -C "$RRD" push -q origin main
done

OUTD=$(PATH="$SANDBOX_PATH" GC_CITY_PATH="$TD/city" SURVIVAL_LEDGER_FILE="$LEDGERD" SURVIVAL_ALERT_DIR="$TD/alerted" \
  SURVIVAL_DIVERGENT_SURGE_THRESHOLD=5 SURVIVAL_DRY_RUN=1 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)

printf '%s\n' "$OUTD" | grep -q 'WOULD-SKIP(closed-bead) .*bead=closed-story' \
  && ok "closed-bead sha logs WOULD-SKIP(closed-bead), not escalated" \
  || bad "closed-bead sha did not log the expected WOULD-SKIP(closed-bead) line — output:
$OUTD"
printf '%s\n' "$OUTD" | grep 'WOULD-ESCALATE(divergent)' | grep -q 'closed-story' \
  && bad "closed-bead sha WAS escalated via WOULD-ESCALATE(divergent) — the exact regression ga-f7czjc fixes"
INDIV_LINES_D=$(printf '%s\n' "$OUTD" | grep -c 'WOULD-ESCALATE(divergent)')
[ "$INDIV_LINES_D" = "1" ] \
  && ok "CONTROL: the open-bead sha still escalates normally (exactly 1 WOULD-ESCALATE)" \
  || bad "CONTROL: expected exactly 1 WOULD-ESCALATE(divergent) (the open-bead sha only), got $INDIV_LINES_D — output:
$OUTD"
printf '%s\n' "$OUTD" | grep 'WOULD-ESCALATE(divergent)' | grep -q 'failing-story' \
  && bad "failing-bd sha WAS escalated — a failed bd read was read as 'not closed' (the ga-cqnm73 bug)" \
  || ok "failing-bd sha is NOT escalated (an unreadable bead state is not 'not closed')"
printf '%s\n' "$OUTD" | grep -q 'state of bead failing-story could not be read' \
  && ok "failing-bd sha logs that the bead state could not be read, and that it will re-check next sweep" \
  || bad "failing-bd sha did not log the could-not-read-state warning — output:
$OUTD"
printf '%s\n' "$OUTD" | grep -q 'bead_state_unknown=1' \
  && ok "summary line carries bead_state_unknown=1 (visible counter)" \
  || bad "summary line does not show bead_state_unknown=1 — output:
$OUTD"

# ── 14. ga-cqnm73: the Mayor mail states only what the bead re-read confirms ──
# The mail used to say "The sweep reopened + labelled gate:merge-orphan + commented the source bead" unconditionally,
# above three `bd` writes that are all `2>/dev/null || true`. wa-k8l0m was still closed and unlabelled when that mail
# arrived. Now every claim comes from a bd re-read taken AFTER the writes.
echo "── 14. ga-cqnm73: escalation mail reports verified bead state ──"
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain [$3], got: $2" ;; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1 — must NOT contain [$3], got: $2" ;; *) ok "$1" ;; esac; }

# 14a. _orphan_write_report (pure): every claim is conditional on the after-snapshot.
R_UNK="$(_orphan_write_report "closed|0|5" "unknown")"
has   "re-read failed -> WRITES UNVERIFIED"                    "$R_UNK" "WRITES UNVERIFIED"
hasnt "re-read failed -> never claims a reopen"                "$R_UNK" "reopened ("
R_OK="$(_orphan_write_report "closed|0|5" "open|1|6")"
has   "closed->open: reopened (was closed, now open)"          "$R_OK" "reopened (was closed, now open)"
has   "label present after the write"                          "$R_OK" "gate:merge-orphan label present"
has   "comment count rose -> comment added"                    "$R_OK" "comment added"
R_STILL="$(_orphan_write_report "closed|0|5" "closed|0|5")"
has   "still closed -> NOT reopened"                           "$R_STILL" "NOT reopened (bead is still closed)"
hasnt "still closed -> never claims it was reopened"           "$R_STILL" "reopened (was closed"
has   "label missing -> NOT applied"                           "$R_STILL" "gate:merge-orphan label NOT applied"
has   "comment count flat -> NOT confirmed"                    "$R_STILL" "comment NOT confirmed (comment count did not increase)"
R_ALREADY="$(_orphan_write_report "open|0|7" "open|0|7")"
has   "was already open -> says so instead of claiming a reopen" "$R_ALREADY" "no reopen needed (bead was already open)"
R_BLIND="$(_orphan_write_report "unknown" "open|1|8")"
has   "state before unreadable -> reopen not confirmed"         "$R_BLIND" "a reopen is not confirmed"
R_BADCNT="$(_orphan_write_report "open|0|" "open|1|8")"
has   "one unreadable comment count -> NOT confirmed (not mistaken for an increase)" "$R_BADCNT" "comment count unreadable"

# 14b. _bead_snapshot against the fake bd.
OLDPATH="$PATH"; PATH="$SANDBOX_PATH"
eq "snapshot of a readable bead: status|label|count"   "$(_bead_snapshot anycity wr-fail)" "open|0|7"
eq "snapshot when bd fails -> unknown"                  "$(_bead_snapshot anycity failing-story)" "unknown"
eq "snapshot of an empty answer -> unknown"             "$(_bead_snapshot anycity empty-story)" "unknown"
eq "snapshot with no bead id -> unknown"                "$(_bead_snapshot anycity "")" "unknown"
PATH="$OLDPATH"

# 14c. Real (NON-dry-run) sweep against stub bd/gc only: three divergent entries whose bd behaves differently.
#   wr-fail  — every write is a silent no-op (the 03/10 shape): the mail must say so.
#   wr-ok    — the writes land: the mail may say so.
#   wr-blind — readable until the escalation, unreadable after it: the mail must say UNVERIFIED.
TW="$T/ga_cqnm73_mail"; mkdir -p "$TW"
ROW="$TW/origin.git"; git init -q --bare -b main "$ROW" >/dev/null 2>&1
RRW="$TW/rig"; git clone -q "$ROW" "$RRW" >/dev/null 2>&1
git -C "$RRW" config user.email t@example.com; git -C "$RRW" config user.name tester
echo base > "$RRW/base"; git -C "$RRW" add .; git -C "$RRW" commit -q -m base; git -C "$RRW" push -q origin main
BASEW=$(git -C "$RRW" rev-parse HEAD)
LEDGERW="$TW/ledger.jsonl"; : > "$LEDGERW"
declare -A WR_SHA
for wb in wr-fail wr-ok wr-blind; do
  git -C "$RRW" checkout -q -b "side-$wb" "$BASEW" >/dev/null 2>&1
  echo "$wb" > "$RRW/s-$wb"; git -C "$RRW" add .; git -C "$RRW" commit -q -m "S $wb"
  WR_SHA[$wb]=$(git -C "$RRW" rev-parse HEAD)
  git -C "$RRW" checkout -q main >/dev/null 2>&1
  printf '{"ts":"%s","rig":"rigW","rig_path":"%s","default_branch":"main","branch":"side-%s","bead":"%s","bead_city":"anycity","gate_run":"","merge_sha":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RRW" "$wb" "$wb" "${WR_SHA[$wb]}" >> "$LEDGERW"
  echo "m-$wb" > "$RRW/m-$wb"; git -C "$RRW" add .; git -C "$RRW" commit -q -m "M $wb"; git -C "$RRW" push -q origin main
done
rm -f "$FAKE_GC_DIR"/call.* 2>/dev/null; rm -f "$FAKE_BD_STATE"/wr-* 2>/dev/null
OUTW=$(PATH="$SANDBOX_PATH" GC_CITY_PATH="$TW/city" SURVIVAL_LEDGER_FILE="$LEDGERW" SURVIVAL_ALERT_DIR="$TW/alerted" \
  SURVIVAL_DIVERGENT_SURGE_THRESHOLD=5 SURVIVAL_DRY_RUN=0 SURVIVAL_LOG_STDOUT=1 bash "$SWEEP" 2>&1)
mail_for() { local f; for f in "$FAKE_GC_DIR"/call.*; do [ -f "$f" ] && grep -q "$1" "$f" && { cat "$f"; return 0; }; done; return 1; }
MAIL_FAIL="$(mail_for "${WR_SHA[wr-fail]}")";  MAIL_OK="$(mail_for "${WR_SHA[wr-ok]}")";  MAIL_BLIND="$(mail_for "${WR_SHA[wr-blind]}")"
[ -n "$MAIL_FAIL" ] && [ -n "$MAIL_OK" ] && [ -n "$MAIL_BLIND" ] \
  && ok "all three confirmed-divergent entries mailed the Mayor" \
  || bad "expected one Mayor mail per entry (fail/ok/blind) — got fail=${#MAIL_FAIL} ok=${#MAIL_OK} blind=${#MAIL_BLIND} bytes; sweep output:
$OUTW"
hasnt "silently-failing writes: mail never claims 'The sweep reopened + labelled'" "$MAIL_FAIL" "The sweep reopened + labelled"
has   "silently-failing writes: mail says the label was NOT applied"          "$MAIL_FAIL" "gate:merge-orphan label NOT applied"
has   "silently-failing writes: mail says the comment is NOT confirmed"       "$MAIL_FAIL" "comment NOT confirmed"
has   "landed writes: mail confirms the label from the re-read"               "$MAIL_OK" "gate:merge-orphan label present"
has   "landed writes: mail confirms the comment from the re-read"             "$MAIL_OK" "comment added"
hasnt "landed writes: still no unconditional old sentence"                    "$MAIL_OK" "The sweep reopened + labelled"
has   "unreadable after the writes: mail says WRITES UNVERIFIED"              "$MAIL_BLIND" "WRITES UNVERIFIED"
hasnt "unreadable after the writes: never claims a reopen"                    "$MAIL_BLIND" "reopened ("

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0
