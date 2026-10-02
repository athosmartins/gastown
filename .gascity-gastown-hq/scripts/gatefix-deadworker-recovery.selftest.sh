#!/usr/bin/env bash
# Selftest for gatefix-deadworker-recovery.sh — proves the pure decision in isolation.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/gatefix-deadworker-recovery.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3] got [$2]"; fi; }
# backdate_wt <worktree> — make every file (and the worktree's own index/HEAD) look idle for
# years, so the "worktree written recently" gate (ga-fnmo63) sees a worker that really stopped.
backdate_wt() {
  local wt="$1" gd
  find "$wt" -exec touch -h -t 202001010000 {} + 2>/dev/null
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)"
  case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
  touch -t 202001010000 "$gd/index" "$gd/HEAD" 2>/dev/null
  return 0
}

GATEFIX_RECOVERY_LIB_ONLY=1 source "$J" || { echo "FATAL: cannot source lib-only"; exit 1; }
type gatefix_recovery_decide >/dev/null 2>&1 || { echo "FATAL: decide fn missing"; exit 1; }

LIVE="wa-worker-adhoc-LIVE mila-wa oracle-wa"

echo "── gatefix_recovery_decide ──"
# recover ONLY when: needs-fix=1, not in-flight, non-empty worker, worker NOT in the roster,
# AND positive proof of death (ga-fnmo63): every session bead for that name is closed
# (proof=closed) AND no tmux session by that name (tmux=absent). 5th/6th args = proof/tmux.
eq "dead worker, fully proven → RECOVER"              "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" closed absent)" "recover"
eq "live worker → skip"                               "$(gatefix_recovery_decide 1 0 mila-wa "$LIVE" closed absent)"             "skip:worker-still-live"
eq "in-flight (active rework) → skip"                 "$(gatefix_recovery_decide 1 1 wa-worker-adhoc-DEAD "$LIVE" closed absent)" "skip:in-flight-active-rework"
eq "no recorded worker → skip (cannot prove dead)"    "$(gatefix_recovery_decide 1 0 '' "$LIVE" closed absent)"                  "skip:no-recorded-worker"
eq "not needs-fix → skip"                             "$(gatefix_recovery_decide 0 0 wa-worker-adhoc-DEAD "$LIVE" closed absent)" "skip:not-needs-fix"
# the live-match is exact-token (a dead worker whose name is a substring of a live one is NOT spared)
eq "substring of a live name is NOT 'live' → recover" "$(gatefix_recovery_decide 1 0 wa-worker "$LIVE" closed absent)"           "recover"
# ga-fnmo63: "absent from the roster" is NOT proof of death. Three states, never two.
eq "session bead OPEN (resumable) → skip"             "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" open absent)"    "skip:session-bead-open"
eq "session bead not found → skip (cannot prove)"     "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" none absent)"    "skip:session-bead-not-found"
eq "session proof unknown (lookup failed) → skip"     "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" unknown absent)" "skip:session-proof-unknown"
eq "legacy 4-arg call (no proof at all) → skip"       "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE")"                "skip:session-proof-unknown"
eq "tmux session still present → skip"                "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" closed present)" "skip:tmux-session-present"
eq "tmux unreachable → skip (cannot prove)"           "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" closed unknown)" "skip:tmux-unknown"
eq "tmux proof missing → skip"                        "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE" closed)"         "skip:tmux-unknown"

echo ""
echo "── drift-guard: live wiring present ──"
grep -q 'gc session list --json' "$J" && ok "reads gc session roster" || bad "no roster read"
grep -q 'empty_roster_failsafe' "$J" && ok "FAIL-SAFE on empty roster (never reaps blind)" || bad "no empty-roster failsafe"
grep -q 'worktree remove --force' "$J" && ok "reaps orphan worktree" || bad "no worktree reap"
# NO BRANCH DELETION (ga-0re8j): the glob refs/heads|remotes/.../crew/*/<bead> can only
# ever match the crew's PRIMARY submission branch (git ref globs never cross '/', and the
# gatefix-worker worktree checks out that SAME ref) — never re-add branch deletion here.
grep -q 'branch -D' "$J" && bad "local branch deletion present — DATA-LOSS regression (ga-0re8j)" || ok "no local branch deletion (ga-0re8j)"
grep -q 'push origin --delete' "$J" && bad "remote branch deletion present — DATA-LOSS regression (ga-0re8j)" || ok "no remote branch deletion (ga-0re8j)"

echo ""
echo "── live-path: missing dependency → must notify, not die silently (ga-4zpf) ──"
LIVE_TMP="$(mktemp -d)"
NOTIFY_LOG="$LIVE_TMP/notify.log"
cat > "$LIVE_TMP/notify" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
EOF
chmod +x "$LIVE_TMP/notify"
env -i PATH=/usr/bin:/bin HOME="$HOME" \
    GATEFIX_RECOVERY_NOTIFY="$LIVE_TMP/notify" \
    GATEFIX_RECOVERY_LOG="$LIVE_TMP/run.log" \
    bash "$J" >/dev/null 2>&1
grep -qi 'gc' "$NOTIFY_LOG" 2>/dev/null && ok "live-path: missing gc dependency → notified (ga-4zpf)" || bad "live-path: missing gc dependency did NOT notify — silent failure (ga-4zpf regression)"
rm -rf "$LIVE_TMP"

echo ""
echo "── mutation guard: live sweep must NOT delete the crew's branch (ga-0re8j) ──"
MUT_TMP="$(mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

MUT_ORIGIN="$MUT_TMP/origin.git"; git init -q --bare "$MUT_ORIGIN"
MUT_GT="$MUT_TMP/gt"; mkdir -p "$MUT_GT/.gascity-gastown-hq"
git init -q -b main "$MUT_GT"
( cd "$MUT_GT"
  git remote add origin "$MUT_ORIGIN"
  echo a > a.txt; git add a.txt; git commit -qm "base"
  git push -q origin main
  # the crew's real submission branch — one commit AHEAD of main (unmerged, live rework)
  git checkout -qb crew/oracle/fx-bead main
  echo b > b.txt; git add b.txt; git commit -qm "fix in progress"
  git push -q origin crew/oracle/fx-bead
  git fetch -q origin
  git checkout -q main
  # an orphan gatefix-worker worktree, checked out to a THROWAWAY branch (never the
  # submission branch itself) — proves worktree reaping still works post-fix
  git branch scratch/fx-bead-wt main
  git worktree add -q "$MUT_GT/crew/worker-fx-bead" scratch/fx-bead-wt
) >/dev/null 2>&1

# fake gc/bd: report the bead as gate:needs-fix, worker dead (absent from the live
# roster), not in-flight — the exact shape ga-0re8j reproduces.
MUT_BIN="$MUT_TMP/bin"; mkdir -p "$MUT_BIN"
cat > "$MUT_BIN/gc" <<'FAKEGC'
#!/usr/bin/env bash
case "$*" in
  *"session list --json"*) echo '{"sessions":[{"session_name":"someone-else-live","state":"active"}]}' ;;
  *"rig list --json"*)     echo '{"rigs":[]}' ;;
  *)                        echo '{}' ;;
esac
FAKEGC
cat > "$MUT_BIN/bd" <<'FAKEBD'
#!/usr/bin/env bash
case "$*" in
  *"list -l gate:needs-fix"*) echo '[{"id":"fx-bead","labels":["gate:needs-fix"],"metadata":{"gc.session_name":"dead-worker-xyz"}}]' ;;
  *"--metadata-field session_name=dead-worker-xyz"*) echo '[{"id":"ga-wisp-xyz","status":"closed","metadata":{"session_name":"dead-worker-xyz"}}]' ;;
  *"show fx-bead"*)           echo '[{"assignee":"dead-worker-xyz"}]' ;;
  *)                           : ;;
esac
exit 0
FAKEBD
# fake tmux: the roster-absent worker also has no tmux session (positive proof, ga-fnmo63)
cat > "$MUT_BIN/tmux" <<'FAKETMUX'
#!/usr/bin/env bash
echo "can't find session: ${*: -1}" >&2; exit 1
FAKETMUX
chmod +x "$MUT_BIN/gc" "$MUT_BIN/bd" "$MUT_BIN/tmux"
backdate_wt "$MUT_GT/crew/worker-fx-bead"

PATH="$MUT_BIN:$PATH" \
GATEFIX_RECOVERY_GT="$MUT_GT" \
GATEFIX_RECOVERY_LOG="$MUT_TMP/run.jsonl" \
GATEFIX_RECOVERY_ENABLED=1 \
GATEFIX_RECOVERY_DRY_RUN=0 \
  bash "$J" >/dev/null 2>&1

if git -C "$MUT_GT" rev-parse --verify -q refs/heads/crew/oracle/fx-bead >/dev/null 2>&1; then
  ok "local crew/oracle/fx-bead branch SURVIVES the sweep"
else
  bad "local crew/oracle/fx-bead branch was DELETED by the sweep — DATA-LOSS regression (ga-0re8j)"
fi
if git -C "$MUT_ORIGIN" rev-parse --verify -q refs/heads/crew/oracle/fx-bead >/dev/null 2>&1; then
  ok "remote (origin) crew/oracle/fx-bead branch SURVIVES the sweep"
else
  bad "remote crew/oracle/fx-bead branch was DELETED by the sweep — DATA-LOSS regression (ga-0re8j)"
fi
grep -q '"event":"branch_deleted"' "$MUT_TMP/run.jsonl" 2>/dev/null && bad "run log recorded a branch_deleted event (ga-0re8j)" || ok "no branch_deleted event logged"
grep -q '"event":"remote_branch_deleted"' "$MUT_TMP/run.jsonl" 2>/dev/null && bad "run log recorded a remote_branch_deleted event (ga-0re8j)" || ok "no remote_branch_deleted event logged"
[ -d "$MUT_GT/crew/worker-fx-bead" ] && bad "orphan gatefix-worker worktree NOT reaped (regression)" || ok "orphan gatefix-worker worktree still reaped"

rm -rf "$MUT_TMP"

echo ""
echo "── ga-fnmo63: only a PROVEN-dead worker's worktree is reaped; dirty work is salvaged first ──"
# Incident 01/10: the janitor force-removed worker-ps-6cgb TWICE while its worker was alive
# (a pool session that drains/sleeps and resumes) and took uncommitted edits with it. Each
# scenario below runs the REAL script against a throwaway repo + fake gc/bd/tmux.
FN_TMP="$(mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
FN_BIN="$FN_TMP/bin"; mkdir -p "$FN_BIN"
cat > "$FN_BIN/gc" <<'FAKEGC'
#!/usr/bin/env bash
case "$*" in
  *"session list --json"*) cat "$FAKE_STATE/roster.json" ;;
  *"rig list --json"*)     echo '{"rigs":[]}' ;;
  *)                        echo '{}' ;;
esac
FAKEGC
cat > "$FN_BIN/bd" <<'FAKEBD'
#!/usr/bin/env bash
case "$*" in
  *"list -l gate:needs-fix"*) cat "$FAKE_STATE/beads.json" ;;
  *"--metadata-field session_name="*)
    all="$*"                                  # flatten first: ${*##x} strips per-argument, not per-line
    n="${all##*--metadata-field session_name=}"; n="${n%% *}"
    f="$FAKE_STATE/sess/$n.json"
    if [ -f "$f" ]; then
      if grep -q '^FAIL' "$f"; then echo "bd: simulated lookup failure" >&2; exit 1; fi
      cat "$f"
    else echo '[]'; fi ;;
  *"show fx-bead"*) echo '[{"assignee":"dead-worker-xyz"}]' ;;
  *) echo "$*" >> "$FAKE_STATE/bd.log" ;;
esac
exit 0
FAKEBD
cat > "$FN_BIN/tmux" <<'FAKETMUX'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/tmux.down" ] && { echo "error connecting to /tmp/tmux-0/gascity (No such file or directory)" >&2; exit 1; }
name="${*: -1}"; name="${name#=}"
grep -qx -- "$name" "$FAKE_STATE/tmux.sessions" 2>/dev/null && exit 0
echo "can't find session: $name" >&2; exit 1
FAKETMUX
printf '#!/usr/bin/env bash\necho "$*" >> "$FAKE_STATE/notify.log"\n' > "$FN_BIN/notify"
chmod +x "$FN_BIN"/*

# fn_world <name> — throwaway repo+origin; crew branch checked out in the orphan worktree
# (the real shape: the gatefix worktree checks out the crew's submission branch). Default
# state = a PROVEN-dead worker (session bead closed, absent from roster, no tmux session).
fn_world() {
  W="$FN_TMP/$1"; STATE="$W/state"; mkdir -p "$STATE/sess"
  ORIGIN_W="$W/origin.git"; GT_W="$W/gt"; WT_W="$GT_W/crew/worker-fx-bead"
  git init -q --bare "$ORIGIN_W"
  mkdir -p "$GT_W/.gascity-gastown-hq"; git init -q -b main "$GT_W"
  ( cd "$GT_W" && git remote add origin "$ORIGIN_W" && echo a > a.txt && git add a.txt \
      && git commit -qm base && git push -q origin main \
      && git checkout -qb crew/oracle/fx-bead main && echo b > b.txt && git add b.txt \
      && git commit -qm "fix in progress" && git push -q origin crew/oracle/fx-bead \
      && git checkout -q main && git worktree add -q "$WT_W" crew/oracle/fx-bead ) >/dev/null 2>&1
  [ -d "$WT_W" ] || { echo "FATAL: could not build scenario world $1"; exit 1; }
  echo '[{"id":"fx-bead","labels":["gate:needs-fix"],"metadata":{"gc.session_name":"dead-worker-xyz"}}]' > "$STATE/beads.json"
  echo '{"sessions":[{"session_name":"someone-else-live","state":"active"}]}' > "$STATE/roster.json"
  echo '[{"id":"ga-wisp-xyz","status":"closed","metadata":{"session_name":"dead-worker-xyz"}}]' > "$STATE/sess/dead-worker-xyz.json"
  : > "$STATE/tmux.sessions"
}
# fn_dirty — the three shapes of uncommitted work: tracked edit, untracked file, staged file
fn_dirty() {
  ( cd "$WT_W" && echo "wip edit" >> b.txt && echo "untracked work" > new.txt \
      && echo "staged work" > staged.txt && git add staged.txt ) >/dev/null 2>&1
}
fn_run() {   # fn_run [ENV=VAL ...] — one real sweep
  env PATH="$FN_BIN:$PATH" FAKE_STATE="$STATE" GATEFIX_RECOVERY_GT="$GT_W" \
      GATEFIX_RECOVERY_LOG="$W/run.jsonl" GATEFIX_RECOVERY_NOTIFY="$FN_BIN/notify" \
      GATEFIX_RECOVERY_ENABLED=1 GATEFIX_RECOVERY_DRY_RUN=0 "$@" bash "$J" >/dev/null 2>&1
}
fn_expect_kept() {   # the worker's worktree is intact and its claim untouched
  local why=""
  [ -d "$WT_W" ] || why="$why worktree-deleted"
  grep -q '"event":"worktree_reaped"' "$W/run.jsonl" 2>/dev/null && why="$why reaped-event"
  grep -q 'unset-metadata' "$STATE/bd.log" 2>/dev/null && why="$why claim-cleared"
  if [ -z "$why" ]; then ok "$1 → worktree kept, claim untouched"
  else bad "$1 → destroyed a worker's work ($why) — ga-fnmo63"; fi
}
fn_expect_log() {   # fn_expect_log <label> <regex> — the sweep log must say WHY it held back
  if grep -Eq "$2" "$W/run.jsonl" 2>/dev/null; then ok "$1 (guard that fired: $2)"
  else bad "$1 — kept for the wrong reason / no reason logged; expected /$2/ in: $(tr '\n' ' ' < "$W/run.jsonl" 2>/dev/null | cut -c1-240)"; fi
}
fn_recovery_refs() { git -C "$GT_W" for-each-ref --format='%(refname)' 'refs/recovery/fx-bead/'; }

echo " · (a) asleep ≠ dead: a sleeping/drained pool worker resumes in the same worktree"
fn_world s1; fn_dirty; backdate_wt "$WT_W"
echo '{"sessions":[{"session_name":"dead-worker-xyz","state":"asleep"},{"session_name":"someone-else-live","state":"active"}]}' > "$STATE/roster.json"
fn_run; fn_expect_kept "S1 worker is ASLEEP in the roster"
grep -q '"event":"skip_unproven"' "$W/run.jsonl" 2>/dev/null && bad "S1 held back by a proof lookup, not by the roster" || ok "S1 held back by the roster alone (asleep counted as present)"

echo " · roster is a single source — a partial roster must not be able to trigger a reap"
fn_world s2; fn_dirty; backdate_wt "$WT_W"
echo '[{"id":"ga-wisp-xyz","status":"open","metadata":{"session_name":"dead-worker-xyz"}}]' > "$STATE/sess/dead-worker-xyz.json"
fn_run; fn_expect_kept "S2 absent from roster but session bead is OPEN (resumable)"
fn_expect_log "S2" '"reason":"session-bead-open"'

fn_world s3; fn_dirty; backdate_wt "$WT_W"
echo 'FAIL' > "$STATE/sess/dead-worker-xyz.json"
fn_run; fn_expect_kept "S3 session-bead lookup FAILS (unknown ≠ dead)"
fn_expect_log "S3" '"reason":"session-proof-unknown"'

fn_world s4; fn_dirty; backdate_wt "$WT_W"; rm -f "$STATE/sess/dead-worker-xyz.json"
fn_run; fn_expect_kept "S4 no session bead found (absent ≠ dead)"
fn_expect_log "S4" '"reason":"session-bead-not-found"'

fn_world s5; fn_dirty; backdate_wt "$WT_W"; echo "dead-worker-xyz" > "$STATE/tmux.sessions"
fn_run; fn_expect_kept "S5 session bead closed but a tmux session with that name is running"
fn_expect_log "S5" '"reason":"tmux-session-present"'

fn_world s6; fn_dirty; backdate_wt "$WT_W"; : > "$STATE/tmux.down"
fn_run; fn_expect_kept "S6 tmux server unreachable (cannot prove absence)"
fn_expect_log "S6" '"reason":"tmux-unknown"'

fn_world s7; fn_dirty        # NOT backdated: files written just now
fn_run; fn_expect_kept "S7 worktree written to within the idle window"
fn_expect_log "S7" '"reason":"worktree_not_provably_idle"'

echo " · a lookup that answers about someone ELSE must not vouch for this worker"
fn_world s16; fn_dirty; backdate_wt "$WT_W"
echo '[{"id":"ga-wisp-other","status":"closed","metadata":{"session_name":"someone-else"}}]' > "$STATE/sess/dead-worker-xyz.json"
fn_run; fn_expect_kept "S16 session lookup returned rows for a different session"
fn_expect_log "S16" '"reason":"session-proof-unknown"'

echo " · cannot LOOK at the worktree (unreadable subdir) ≠ nothing was written"
fn_world s17; mkdir "$WT_W/locked-dir"; echo secret > "$WT_W/locked-dir/f.txt"; fn_dirty; backdate_wt "$WT_W"
chmod 000 "$WT_W/locked-dir"
fn_run; chmod 755 "$WT_W/locked-dir"
fn_expect_kept "S17 worktree has an unreadable subdirectory"
fn_expect_log "S17" '"reason":"worktree_not_provably_idle"'

echo " · a removal that fails (locked worktree) is logged, never reported as a reap"
fn_world s18; fn_dirty; backdate_wt "$WT_W"; git -C "$GT_W" worktree lock "$WT_W" >/dev/null 2>&1
fn_run
grep -q '"event":"reap_failed"' "$W/run.jsonl" 2>/dev/null && ok "S18 failed removal logged as reap_failed" || bad "S18 failed removal not logged"
grep -q '"event":"worktree_reaped"' "$W/run.jsonl" 2>/dev/null && bad "S18 logged worktree_reaped for a worktree that is still there" || ok "S18 no false worktree_reaped event"
git -C "$GT_W" worktree unlock "$WT_W" >/dev/null 2>&1

fn_world s7b; fn_dirty; backdate_wt "$WT_W"
fn_run GATEFIX_RECOVERY_DRY_RUN=1
fn_expect_kept "S7b DRY_RUN with a fully proven-dead worker"
[ -z "$(fn_recovery_refs)" ] && ok "S7b dry-run created no recovery ref" || bad "S7b dry-run wrote a recovery ref"

echo " · (b) dirty worktree of a PROVEN-dead worker: salvage to refs/recovery/<bead>/<ts>, THEN remove"
fn_world s8; fn_dirty; backdate_wt "$WT_W"
TIP_BEFORE="$(git -C "$GT_W" rev-parse refs/heads/crew/oracle/fx-bead)"
fn_run
REF="$(fn_recovery_refs | head -1)"
if [ -n "$REF" ]; then
  ok "S8 recovery ref created ($REF)"
  [ "$(git -C "$GT_W" show "$REF:b.txt" 2>/dev/null | tail -1)" = "wip edit" ] && ok "S8 tracked edit preserved in the ref" || bad "S8 tracked edit LOST"
  [ "$(git -C "$GT_W" show "$REF:new.txt" 2>/dev/null)" = "untracked work" ] && ok "S8 untracked file preserved in the ref" || bad "S8 untracked file LOST"
  [ "$(git -C "$GT_W" show "$REF:staged.txt" 2>/dev/null)" = "staged work" ] && ok "S8 staged file preserved in the ref" || bad "S8 staged file LOST"
  git -C "$ORIGIN_W" rev-parse --verify -q "$REF" >/dev/null 2>&1 && ok "S8 recovery ref PUSHED to origin" || bad "S8 recovery ref not on origin"
  [ "$(git -C "$GT_W" rev-parse "$REF^" 2>/dev/null)" = "$TIP_BEFORE" ] && ok "S8 WIP commit sits on top of the crew branch tip" || bad "S8 WIP commit parent is not the crew tip"
  grep -q '"event":"worktree_salvaged"' "$W/run.jsonl" 2>/dev/null && ok "S8 salvage logged" || bad "S8 no worktree_salvaged event"
  grep -q '"event":"worktree_reaped".*refs/recovery/fx-bead/' "$W/run.jsonl" 2>/dev/null && ok "S8 reap event records the salvage ref" || bad "S8 reap event lacks the salvage ref"
  grep -q "comment fx-bead.*refs/recovery/fx-bead/" "$STATE/bd.log" 2>/dev/null && ok "S8 salvage ref written on the bead" || bad "S8 bead not told where the work went"
else
  bad "S8 NO recovery ref — dirty work went straight to 'worktree remove --force' (ga-fnmo63)"
fi
[ "$(git -C "$GT_W" rev-parse refs/heads/crew/oracle/fx-bead 2>/dev/null)" = "$TIP_BEFORE" ] && ok "S8 crew branch tip NOT moved by the salvage" || bad "S8 salvage moved the crew branch"
[ ! -d "$WT_W" ] && ok "S8 worktree removed once salvaged" || bad "S8 recovery proceeded but worktree still there"
grep -q 'unset-metadata' "$STATE/bd.log" 2>/dev/null && ok "S8 claim cleared (bead re-dispatchable)" || bad "S8 claim not cleared"

echo " · clean worktree: removed, no recovery-ref noise"
fn_world s9; backdate_wt "$WT_W"; fn_run
[ ! -d "$WT_W" ] && ok "S9 clean worktree of a proven-dead worker removed" || bad "S9 clean worktree not reaped"
[ -z "$(fn_recovery_refs)" ] && ok "S9 no recovery ref for a clean worktree" || bad "S9 recovery ref created for nothing"

echo " · commits that exist nowhere but this worktree are salvaged too"
fn_world s10
( cd "$WT_W" && echo more >> b.txt && git commit -qam "unpushed fix" ) >/dev/null 2>&1
HEAD_BEFORE="$(git -C "$WT_W" rev-parse HEAD)"; backdate_wt "$WT_W"; fn_run
REF="$(fn_recovery_refs | head -1)"
if [ -n "$REF" ]; then
  [ "$(git -C "$GT_W" rev-parse "$REF")" = "$HEAD_BEFORE" ] && ok "S10 recovery ref points at the unpushed commit" || bad "S10 recovery ref points elsewhere"
  git -C "$ORIGIN_W" cat-file -e "$HEAD_BEFORE" 2>/dev/null && ok "S10 unpushed commit now on origin" || bad "S10 unpushed commit not on origin"
else bad "S10 NO recovery ref for an unpushed commit"; fi
[ ! -d "$WT_W" ] && ok "S10 worktree removed once salvaged" || bad "S10 worktree not removed"

echo " · salvage cannot complete → NOTHING is removed and the claim is NOT cleared"
fn_world s11; fn_dirty; backdate_wt "$WT_W"
git -C "$GT_W" remote set-url origin "$W/does-not-exist.git"
fn_run; fn_expect_kept "S11 recovery-ref push FAILS"
[ -z "$(fn_recovery_refs)" ] && ok "S11 failed attempt leaves no stray recovery ref (no pile-up across retries)" || bad "S11 stray recovery ref left behind"
grep -q '"event":"recovery_deferred"' "$W/run.jsonl" 2>/dev/null && ok "S11 deferral logged" || bad "S11 no recovery_deferred event"
[ -s "$STATE/notify.log" ] && ok "S11 operator notified" || bad "S11 silent failure — nobody told (ga-4zpf)"
N1="$(wc -l < "$STATE/notify.log" 2>/dev/null | tr -d ' ')"; fn_run; N2="$(wc -l < "$STATE/notify.log" 2>/dev/null | tr -d ' ')"
[ "$N1" = "$N2" ] && ok "S11 repeat deferral does not re-notify every sweep (throttled)" || bad "S11 notify spam: $N1 → $N2"

fn_world s12; fn_dirty; dd if=/dev/zero of="$WT_W/big.bin" bs=1048576 count=2 >/dev/null 2>&1; backdate_wt "$WT_W"
fn_run GATEFIX_RECOVERY_SALVAGE_MAX_MB=1; fn_expect_kept "S12 dirty payload larger than the salvage cap"
fn_expect_log "S12" '"reason":"salvage_failed_or_over_1mb"'

echo " · repo without an origin: local recovery ref is the safety net"
fn_world s14; fn_dirty; backdate_wt "$WT_W"; git -C "$GT_W" remote remove origin
fn_run; REF="$(fn_recovery_refs | head -1)"
[ -n "$REF" ] && ok "S14 local recovery ref created without an origin" || bad "S14 no recovery ref"
[ ! -d "$WT_W" ] && ok "S14 worktree removed once salvaged locally" || bad "S14 worktree not removed"
grep -q '"pushed":false' "$W/run.jsonl" 2>/dev/null && ok "S14 log says the ref was NOT pushed" || bad "S14 log does not say pushed:false"

echo " · drift-guard: the proofs and the salvage are wired in"
grep -q 'refs/recovery/' "$J" && ok "salvage ref namespace present" || bad "no refs/recovery salvage"
grep -q 'has-session' "$J" && ok "tmux proof present" || bad "no tmux proof"
grep -q -- '--include-infra' "$J" && ok "session-bead lookup sees wisps (--include-infra)" || bad "lookup would miss wisp session beads"

rm -rf "$FN_TMP"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1
