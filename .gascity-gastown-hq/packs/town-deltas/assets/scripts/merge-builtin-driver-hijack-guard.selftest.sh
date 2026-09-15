#!/usr/bin/env bash
# merge-builtin-driver-hijack-guard.selftest.sh (ga-grg42n)
#
# Hermetic selftest: never touches the live city, never touches ~/gt's real
# git config. Every assertion runs against throwaway repos under mktemp, and
# rig discovery is driven through GC_BIN (stubbed) rather than the real `gc`
# binary — same principle ga-dqfw10's test used ("no dependency on this
# checkout's live config").
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/merge-builtin-driver-hijack-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== merge-builtin-driver-hijack-guard.selftest =="

if [ ! -f "$GUARD" ]; then
  echo "COULD_NOT_FIND_GUARD: $GUARD" >&2
  exit 99
fi

# shellcheck source=/dev/null
. "$GUARD" --lib || { echo "COULD_NOT_SOURCE_GUARD_AS_LIB" >&2; exit 99; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mbdhg-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mk_repo() {
  # mk_repo <dir> -- bare-minimum real repo, quiet.
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t
  git -C "$d" config user.name t
}

# ── 1. mbdhg_is_builtin_name -- the semantics check the bead explicitly
#    demanded ("não assumir, verificar"): text/binary/union are git
#    built-ins (confirmed against https://git-scm.com/docs/gitattributes,
#    "the built-in 3-way merge driver can be explicitly specified by asking
#    for 'text' driver; the built-in take-the-current-branch driver can be
#    requested with 'binary'"; union is the third documented built-in).
#    "ours" is explicitly NOT a built-in -- it's the well-known idiom for a
#    user-defined driver (canonical setup: git config merge.ours.driver
#    true), so it must be excluded or every legitimate "ours" repo alarms.
for b in text binary union; do
  if mbdhg_is_builtin_name "$b"; then ok "'$b' recognized as builtin merge name"; else bad "'$b' should be recognized as builtin"; fi
done
for nb in ours deploydeps testdrv ""; do
  if mbdhg_is_builtin_name "$nb"; then bad "'$nb' incorrectly flagged as builtin (false-positive risk)"; else ok "'$nb' correctly NOT builtin"; fi
done

# ── 2. mbdhg_scan_git_dir -- mixed config: one hijacked builtin (union),
#    one legitimate custom driver (deploydeps-shaped), one legitimate "ours"
#    idiom. Only union may appear.
R1="$WORK/r1"; mk_repo "$R1"
git -C "$R1" config merge.union.driver true
git -C "$R1" config merge.deploydeps.driver 'python3 scripts/merge_deploy_deps.py %O %A %B'
git -C "$R1" config merge.ours.driver true
FOUND1="$(mbdhg_scan_git_dir "$R1/.git")"
if printf '%s\n' "$FOUND1" | grep -q '^union	true$'; then ok "scan flags merge.union.driver=true"; else bad "scan missed merge.union.driver=true (got: $FOUND1)"; fi
if printf '%s\n' "$FOUND1" | grep -q '^deploydeps'; then bad "scan false-positived on legitimate custom driver 'deploydeps'"; else ok "scan does not flag legitimate custom driver 'deploydeps'"; fi
if printf '%s\n' "$FOUND1" | grep -q '^ours'; then bad "scan false-positived on legitimate 'ours' idiom"; else ok "scan does not flag legitimate merge.ours.driver"; fi

# ── 3. binary + text builtins also caught (the bead's "vale checar" item,
#    resolved affirmatively for binary, and text included for completeness
#    since it's the third and first documented built-in names respectively).
R2="$WORK/r2"; mk_repo "$R2"
git -C "$R2" config merge.binary.driver true
git -C "$R2" config merge.text.driver true
FOUND2="$(mbdhg_scan_git_dir "$R2/.git")"
for b in binary text; do
  if printf '%s\n' "$FOUND2" | grep -q "^${b}	true$"; then ok "scan flags merge.${b}.driver=true"; else bad "scan missed merge.${b}.driver=true (got: $FOUND2)"; fi
done

# ── 4. clean repo, zero findings.
R3="$WORK/r3"; mk_repo "$R3"
FOUND3="$(mbdhg_scan_git_dir "$R3/.git")"
[ -z "$FOUND3" ] && ok "clean repo (no merge.*.driver) yields zero findings" || bad "clean repo should yield nothing, got: $FOUND3"

# ── 5. discover_git_dirs dedup -- reproduces the REAL topology measured live
#    in this city on 2026-09-15: /Users/athos/gt/gastown and .../deacon have
#    no .git of their own and silently resolve UPWARD to the container
#    repo's .git (confirmed via `git rev-parse --git-common-dir` against the
#    live tree). A naive per-rig-path scan would double/triple-count and
#    could alarm the same config entry once per rig name. Simulated here as
#    a plain (non-git) subdirectory of a real repo -- git's own upward
#    resolution is the exact mechanism being exercised, not a stand-in.
R4="$WORK/r4"; mk_repo "$R4"
mkdir -p "$R4/nested-rig-like-gastown"
DEDUP_OUT="$(mbdhg_discover_git_dirs "$R4" "$R4/nested-rig-like-gastown")"
DEDUP_COUNT=$(printf '%s\n' "$DEDUP_OUT" | grep -c .)
[ "$DEDUP_COUNT" = "1" ] && ok "two rig roots sharing one .git dedup to exactly 1 git-dir (matches live gastown/deacon topology)" \
  || bad "expected 1 deduped git-dir for two roots sharing a .git, got $DEDUP_COUNT: $DEDUP_OUT"

# ── 6. genuine second git-dir (.repo.git distinct from .git) -- the
#    whatsapp_automation/marketing shape (crew vs gate). Both must be
#    reported, not deduped away.
R5="$WORK/r5"; mk_repo "$R5"
git init -q --bare "$R5/.repo.git"
DUAL_OUT="$(mbdhg_discover_git_dirs "$R5")"
DUAL_COUNT=$(printf '%s\n' "$DUAL_OUT" | grep -c .)
[ "$DUAL_COUNT" = "2" ] && ok "genuinely distinct .git + .repo.git both discovered (2 git-dirs)" \
  || bad "expected 2 distinct git-dirs for .git+.repo.git shape, got $DUAL_COUNT: $DUAL_OUT"

# ── 7. .repo.git as a gitlink TARGET of .git (property_scrapers/lexbh shape:
#    .git is a FILE containing "gitdir: .../.repo.git", i.e. one identity,
#    not two) -- must dedup to exactly 1, not double-count.
R6="$WORK/r6"; mkdir -p "$R6"
git init -q --bare "$R6/.repo.git"
printf 'gitdir: %s/.repo.git\n' "$R6" > "$R6/.git"
LINKED_OUT="$(mbdhg_discover_git_dirs "$R6")"
LINKED_COUNT=$(printf '%s\n' "$LINKED_OUT" | grep -c .)
[ "$LINKED_COUNT" = "1" ] && ok "gitlink .git -> .repo.git (single identity) dedups to 1 git-dir" \
  || bad "expected 1 git-dir for gitlink-to-.repo.git shape, got $LINKED_COUNT: $LINKED_OUT"

# ── 8. End-to-end repro matching the bead's own acceptance criterion #3
#    verbatim: git config merge.union.driver true + .gitattributes
#    merge=union + a real conflicting merge. Demonstrates BOTH halves: (a)
#    the danger is real (git silently "resolves" via the bogus driver
#    instead of conflicting), and (b) the new scan catches the spurious key
#    before any merge exercises it.
R7="$WORK/r7"; mk_repo "$R7"
(
  cd "$R7" || exit 1
  git config merge.union.driver true
  printf 'victim.txt merge=union\n' > .gitattributes
  printf 'a\nb\nc\n' > victim.txt
  git add .gitattributes victim.txt
  git commit -qm base
  git branch -M main
  git checkout -qb theirs
  printf 'a\nb\nc\nTHEIRS\n' > victim.txt
  git commit -qam theirs
  git checkout -q main
  printf 'a\nb\nc\nOURS\n' > victim.txt
  git commit -qam ours
) >/dev/null 2>&1
MERGE_RC=0
( cd "$R7" && git merge --no-edit theirs ) >/dev/null 2>&1 || MERGE_RC=$?
MERGED_CONTENT="$(cat "$R7/victim.txt" 2>/dev/null)"
if [ "$MERGE_RC" = "0" ] && [ "$MERGED_CONTENT" = "a
b
c
OURS" ]; then
  ok "danger confirmed live: bogus merge.union.driver=true silently 'resolves' (rc=0) and DISCARDS theirs' content, no conflict reported"
else
  bad "expected the bogus driver to silently no-op the merge (rc=0, content=OURS only); got rc=$MERGE_RC content=[$MERGED_CONTENT] -- repro no longer matches the incident this bead documents"
fi
E2E_FOUND="$(mbdhg_scan_git_dir "$R7/.git")"
if printf '%s\n' "$E2E_FOUND" | grep -q '^union	true$'; then
  ok "guard scan flags the exact spurious key that just silently ate real content above"
else
  bad "guard scan MISSED the union hijack that was just proven to silently destroy content (got: $E2E_FOUND)"
fi

# ── 9. alarm_once cooldown/dedup -- ga-2uz59 doctrine (85 identical mails in
#    10h from an unthrottled guard). Stub the sender, count invocations.
CALL_LOG="$WORK/calls.log"
: > "$CALL_LOG"
ROUTER="$WORK/fake-router.sh"
cat > "$ROUTER" <<EOF
#!/usr/bin/env bash
echo "called" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$ROUTER"
SEEN_FILE="$WORK/seen.json"
echo '{}' > "$SEEN_FILE"
(
  MBDHG_SEEN_FILE="$SEEN_FILE" MBDHG_ROUTER="$ROUTER" MBDHG_ESCALATE_AFTER_S=3600 \
    bash -c '. "'"$GUARD"'" --lib; mbdhg_alarm_once_standalone "testkey" "subj" "body"'
) >/dev/null 2>&1
(
  MBDHG_SEEN_FILE="$SEEN_FILE" MBDHG_ROUTER="$ROUTER" MBDHG_ESCALATE_AFTER_S=3600 \
    bash -c '. "'"$GUARD"'" --lib; mbdhg_alarm_once_standalone "testkey" "subj" "body"'
) >/dev/null 2>&1
CALLS_WITHIN_COOLDOWN=$(grep -c . "$CALL_LOG" 2>/dev/null || echo 0)
[ "$CALLS_WITHIN_COOLDOWN" = "1" ] && ok "alarm_once fires exactly once for the same key within cooldown (no spam)" \
  || bad "expected exactly 1 alarm call within cooldown, got $CALLS_WITHIN_COOLDOWN"

# Simulate cooldown expiry: backdate the seen timestamp beyond the window.
OLD_TS=$(( $(date +%s) - 999999 ))
printf '{"testkey":%s}\n' "$OLD_TS" > "$SEEN_FILE"
(
  MBDHG_SEEN_FILE="$SEEN_FILE" MBDHG_ROUTER="$ROUTER" MBDHG_ESCALATE_AFTER_S=3600 \
    bash -c '. "'"$GUARD"'" --lib; mbdhg_alarm_once_standalone "testkey" "subj" "body"'
) >/dev/null 2>&1
CALLS_AFTER_EXPIRY=$(grep -c . "$CALL_LOG" 2>/dev/null || echo 0)
[ "$CALLS_AFTER_EXPIRY" = "2" ] && ok "alarm_once re-fires once the cooldown window has passed" \
  || bad "expected 2 total calls after cooldown expiry, got $CALLS_AFTER_EXPIRY"

# ── 10. erro != vazio -- if rig discovery itself is broken (GC_BIN fails),
#    the guard must exit with an ERROR status, never silently report "0
#    findings" as if the city were clean. This is the exact failure family
#    named repeatedly in this town's own doctrine.
FAKE_GC_BROKEN="$WORK/fake-gc-broken.sh"
cat > "$FAKE_GC_BROKEN" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_GC_BROKEN"
STATE_TMP="$WORK/state-broken"
set +e
GC_BIN="$FAKE_GC_BROKEN" GC_CITY_PATH="$WORK" GC_PACK_STATE_DIR="$STATE_TMP" \
  bash "$GUARD" >"$WORK/broken.out" 2>"$WORK/broken.err"
BROKEN_RC=$?
set -e 2>/dev/null || true
if [ "$BROKEN_RC" = "2" ] && grep -qi "erro" "$WORK/broken.err" 2>/dev/null; then
  ok "broken rig discovery (gc rig list fails) exits 2 with an explicit ERRO, not a silent clean report"
else
  bad "expected exit 2 + ERRO on stderr when gc rig list fails, got rc=$BROKEN_RC stderr=[$(cat "$WORK/broken.err" 2>/dev/null)]"
fi
if grep -qi "0 findings\|nenhum achado\|clean\|limpo" "$WORK/broken.out" 2>/dev/null; then
  bad "broken discovery must never print a clean/0-findings report (error collapsed into empty)"
else
  ok "broken discovery does not print a misleading clean report"
fi

# ── 11. healthy end-to-end run: stub GC_BIN to point at our throwaway repos
#    (R1 has the union hijack from test #2) and confirm the real CLI path
#    finds it and exits 0.
FAKE_GC_OK="$WORK/fake-gc-ok.sh"
cat > "$FAKE_GC_OK" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "rig" ] && [ "\$2" = "list" ]; then
  printf '{"rigs":[{"name":"r1","path":"%s"}]}\n' "$R1"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKE_GC_OK"
ROUTER_OK="$WORK/fake-router-ok.sh"
cat > "$ROUTER_OK" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ROUTER_OK"
STATE_TMP2="$WORK/state-ok"
JSON_OUT="$(GC_BIN="$FAKE_GC_OK" MBDHG_ROUTER="$ROUTER_OK" GC_CITY_PATH="$WORK" GC_PACK_STATE_DIR="$STATE_TMP2" bash "$GUARD" --json 2>"$WORK/ok.err")"
OK_RC=$?
if [ "$OK_RC" = "0" ] && printf '%s' "$JSON_OUT" | jq -e '.finding_count >= 1' >/dev/null 2>&1; then
  ok "end-to-end CLI run (stubbed gc rig list -> R1) reports finding_count >= 1 and exits 0"
else
  bad "end-to-end run failed to report the union hijack; rc=$OK_RC json=[$JSON_OUT] stderr=[$(cat "$WORK/ok.err" 2>/dev/null)]"
fi

echo "── drift-guards (shipped code still defines what this test sourced) ──"
grep -q 'mbdhg_is_builtin_name()' "$GUARD" && ok "guard still defines mbdhg_is_builtin_name" || bad "missing mbdhg_is_builtin_name"
grep -q 'mbdhg_scan_git_dir()' "$GUARD" && ok "guard still defines mbdhg_scan_git_dir" || bad "missing mbdhg_scan_git_dir"
grep -q 'mbdhg_discover_git_dirs()' "$GUARD" && ok "guard still defines mbdhg_discover_git_dirs" || bad "missing mbdhg_discover_git_dirs"
grep -qE '"text binary union"|MBDHG_BUILTIN_NAMES="text binary union"' "$GUARD" && ok "builtin list still exactly text/binary/union (no 'ours')" || bad "builtin list drifted from confirmed text/binary/union"
grep -q 'flock' "$GUARD" && ok "guard still self-locks (ga-y0g5x doctrine: never an unlocked periodic guard)" || bad "missing flock single-instance lock"
grep -qE '(git|--git-dir=).*config.*--write|config .*true[^-]' "$GUARD" && bad "guard appears to WRITE git config -- this must stay detection-only (aceite #2)" || ok "guard contains no git-config write calls (detection-only, matches aceite #2)"

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi
