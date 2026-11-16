#!/bin/bash
# jsonl-archive-history-cap.selftest.sh (ga-zfy8j4x) — proves jsonl-archive-history-cap.sh on throw-away repos.
#
# What it proves (each case builds its own repo under a mktemp dir; nothing here touches the city's real archive):
#   S1  a repo with 40 days of commits is cut to the window: the commit count is the window's, every kept commit has the tree, author, committer, time and message
#       it had, the oldest kept one has no parent, .git is a fraction of what it was, the work tree is still clean (the index came along), fsck --full --strict passes,
#       a commit after the cap works, the config survived, no leftover dir, no lock, no mail; a second run changes nothing
#   S2  slack: a root just past the window is left alone (ok-within-slack) until the .git is over the alarm size, and then it is cut
#   S3  KEEP_MIN: commits that are ALL older than the window still leave KEEP_MIN of them
#   S4  inert on doubt, the repo byte-for-byte untouched: remote, second branch, merge commit, shallow file, unknown .git entry, git's own lock files, detached HEAD,
#       corrupt object, not enough free space, free space that cannot be read, a baseline-tree read that fails or comes back empty (gate fix 1/3: it used to size
#       the tree at 0 and go on to rewrite, fetch, swap and delete), a non-empty .git/branches, a staged-but-uncommitted index (before the build and while it runs),
#       no repo, empty repo, a lock held by a live run, a running exporter
#   S5  a stale lock (dead owner, old) is reclaimed and the run goes on; a live exporter that finishes during the wait lets the run go on
#   S6  failures leave the live repo as it was: fetch failing, the disk watch killing the fetch (no process left), a wrong head fetched (verify), a commit landing in the gap
#       (rolled-back, the old .git back WITH that commit), something recreating .git in the gap (conflict: both dirs kept, nothing deleted), SIGTERM between the two
#       renames (the old .git put back by the exit trap); and each of them mails once (rate-limited), a failing mail command is logged and not fatal
#   S7  leftovers of an interrupted run: a stale new dir is removed, an old dir with no .git is moved back, an old dir with the same head tree is deleted, an old dir
#       whose head tree is in the live history (the exporter committed since) is deleted too, an old dir with a tree the live repo does not have (or next to a new
#       dir) is KEPT and the run ends leftover-kept
#   S8  a commit that lands while the fetch runs is followed (catch-up) and is in the result
#   S9  the alarm: .git over the alarm size mails once and is rate-limited; a mail that FAILS is tried again after JHC_ALERT_RETRY_S, not after the full rate limit;
#       --check exits 3 over it and 0 under it
#   S10 BOUNDED: 20 days of 4 commits a day, one run a day — .git stays under a fixed bound all along while the same history without the cap grows past it, and the
#       tree never changes
#   S11 configuration and order: a non-number or a window of 0 is refused (exit 2); the order file's interval/timeout/exec agree with the script's deadline
#   M1  the S1 assertions FAIL against a mutant that does not cut (so they can fail), and against a mutant that cuts the wrong number of commits
#
# Run it under the disk guard:  scripts/heavy-guard.sh --what selftest-jsonl-archive-history-cap --max-file-mb 512 -- bash <this file>
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${JHC_SCRIPT:-$HERE/jsonl-archive-history-cap.sh}"
ORDER="${JHC_ORDER:-$HERE/../../orders/jsonl-archive-history-cap.toml}"
COMPACT_ORDER="${JHC_COMPACT_ORDER:-$HERE/../../orders/jsonl-archive-compact.toml}"
ulimit -f 262144 2>/dev/null || { echo "selftest: cannot set ulimit -f (512-byte blocks) — refusing to run without a file-size cap" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq is required" >&2; exit 2; }
# a repo built here must not read the operator's git config (hooks, templates, signing)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
# a repo built here must not depend on the host's git template either: this one is the Debian/Ubuntu shape (an empty .git/branches), so every case below runs on a
# repo that has it (and a macOS git without it is covered by the same script path: an absent entry is simply not listed)
# GIT_TEMPLATE_DIR is exported below, once ROOT exists
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=t@example.invalid

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jhc-selftest.XXXXXX")" || exit 2
: > "$ROOT/.jhc-selftest-root"
BIN="$ROOT/bin"; mkdir -p "$BIN"
TPL="$ROOT/git-template"; mkdir -p "$TPL/branches"; export GIT_TEMPLATE_DIR="$TPL"
BGPIDS=""
cleanup() {
  local p
  for p in $BGPIDS; do kill "$p" 2>/dev/null; done   # benign[selftest-bg]: a helper that already ended
  case "$ROOT" in */jhc-selftest.*) [ -f "$ROOT/.jhc-selftest-root" ] && find "$ROOT" -mindepth 1 -delete 2>/dev/null && rmdir "$ROOT" 2>/dev/null ;; esac   # benign[selftest-clean]: scratch dir of this run, under the marker check above
}
trap cleanup EXIT

PASS=0; FAILN=0; MUT=0; MUT_FAIL=0
ok()  { if [ "$MUT" -eq 1 ]; then return 0; fi; PASS=$((PASS + 1)); }
bad() {
  if [ "$MUT" -eq 1 ]; then MUT_FAIL=$((MUT_FAIL + 1)); return 0; fi
  FAILN=$((FAILN + 1)); echo "FAIL [$CASE] $*"; echo "----- script output (tail):"; printf '%s\n' "${OUT:-}" | tail -n 22; echo "-----"
}
eq()     { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', want '$3'"; fi; }
expect() { local d="$1"; shift; if "$@"; then ok; else bad "$d"; fi; }
has()    { if printf '%s\n' "$OUT" | grep -q -F -- "$2"; then ok; else bad "$1: output lacks '$2'"; fi; }

# ── fixtures ──
cat > "$BIN/gc" <<'EOF'
#!/bin/bash
# stub of `gc mail send mayor/ -s SUBJECT -m BODY`: one line per mail
printf 'MAIL %s\n' "$5" >> "${MAILLOG:-/dev/null}"
exit "${GC_STUB_RC:-0}"
EOF
cat > "$BIN/git-wrap" <<'EOF'
#!/bin/bash
# GITBIN wrapper: misbehaves on `fetch` when told to, passes everything else through
is_fetch=0; is_lstree=0; for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; [ "$a" = ls-tree ] && is_lstree=1; done
if [ "$is_lstree" = 1 ]; then
  if [ -n "${WRAP_LSTREE_FAIL:-}" ]; then echo "wrapper: ls-tree refused" >&2; exit 9; fi
  if [ -n "${WRAP_LSTREE_EMPTY:-}" ]; then exit 0; fi
fi
if [ "$is_fetch" = 1 ]; then
  if [ -n "${WRAP_FETCH_FAIL:-}" ]; then echo "wrapper: fetch refused" >&2; exit 9; fi
  if [ -n "${WRAP_PRE_FETCH:-}" ] && [ ! -e "${WRAP_MARK:-/nonexistent}" ]; then : > "$WRAP_MARK"; bash -c "$WRAP_PRE_FETCH"; fi
  if [ -n "${WRAP_SLEEP:-}" ]; then sleep "$WRAP_SLEEP"; fi
  if [ -n "${WRAP_FAKE_SHA:-}" ]; then
    args=(); for a in "$@"; do case "$a" in +*:refs/heads/*) a="+${WRAP_FAKE_SHA}:${a#*:}" ;; esac; args[${#args[@]}]="$a"; done
    exec git "${args[@]}"
  fi
fi
exec git "$@"
EOF
cat > "$BIN/hook" <<'EOF'
#!/bin/bash
# JHC_HOOK: stage repo olddir
stage="$1"; repo="$2"; old="$3"
case "${HOOK_MODE:-}:$stage" in
  late-commit:after-swap)
    t="$(git --git-dir="$old" rev-parse 'HEAD^{tree}')"; p="$(git --git-dir="$old" rev-parse HEAD)"
    c="$(echo gap | git --git-dir="$old" commit-tree "$t" -p "$p")"; git --git-dir="$old" update-ref refs/heads/master "$c" ;;
  recreate:between-mv) mkdir -p "$repo/.git" ;;
  term:between-mv) kill -TERM "$PPID" ;;
esac
exit 0
EOF
FAKE="JHCFAKEX$$n${RANDOM}"   # the exporter stand-in is found by this name; made at run time so that no other process (a shell quoting this file, say) can carry it
printf '#!/bin/bash\nsleep "${FAKE_EXPORT_S:-60}"\n' > "$BIN/$FAKE.sh"
chmod +x "$BIN"/*

newcase() { CASE="$1"; C="$ROOT/$1"; mkdir -p "$C/rt/packs/maintenance"; REPO="$C/rt/packs/maintenance/jsonl-archive"; : > "$C/mail.log"; OUT=""; RC=""; }
gl() { git --git-dir="$REPO/.git" "$@"; }
kib() { du -sk "$REPO/.git" | awk '{print $1}'; }
mails() { grep -c . "$C/mail.log"; }
st() { jq -r .status "$C/state.json" 2>/dev/null; }

# mk_repo <days> <per_day> [blob_kb] — <days>*<per_day> commits, one every 86400/<per_day> s, the newest 600 s old; hq.jsonl is fresh random bytes in every
# commit (incompressible: the size of .git tells how many commits it holds), static.jsonl never changes
mk_repo() {
  local days="$1" per="$2" kb="${3:-60}" total k t now step
  step=$((86400 / per)); total=$((days * per)); now="$(date +%s)"
  mkdir -p "$REPO" && git init -q -b master "$REPO" || return 1
  git -C "$REPO" config pack.threads 2; git -C "$REPO" config pack.windowMemory 256m; git -C "$REPO" config gc.auto 0; git -C "$REPO" config maintenance.auto false
  head -c 100000 /dev/urandom > "$REPO/static.jsonl"
  k=0
  while [ "$k" -lt "$total" ]; do
    t=$(( now - ( (total - 1 - k) * step + 600 ) ))
    head -c $((kb * 1000)) /dev/urandom > "$REPO/hq.jsonl"; echo "$k" > "$REPO/meta.txt"
    git -C "$REPO" add -A >/dev/null
    GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000" git -C "$REPO" commit -q -m "backup $k exported=8/8"
    k=$((k + 1))
  done
}
expected_kept() {  # expected_kept <days> <per_day> <keep_days> <keep_min> — commits whose age (600 + j*step) is under the window, at least keep_min
  local per="$2" total=$(( $1 * $2 )) step=$((86400 / $2)) j=0 n=0
  while [ "$j" -lt "$total" ]; do [ $(( 600 + j * step )) -lt $(( $3 * 86400 )) ] && n=$((n + 1)); j=$((j + 1)); done
  [ "$n" -lt "$4" ] && n="$4"; [ "$n" -gt "$total" ] && n="$total"
  echo "$n"
}
run_cap() {  # run_cap [VAR=val ...] — the later assignments win. Sets OUT and RC.
  OUT="$(env JHC_REPO="$REPO" JHC_LOCK="$C/lock" JHC_STATE="$C/state.json" JHC_LOG="$C/cap.log" JHC_GC="$BIN/gc" MAILLOG="$C/mail.log" \
      JHC_FREE_KIB=50000000 JHC_FLOOR_KIB=1024 JHC_ABORT_FLOOR_KIB=1 JHC_EXPORT_RE="NO-SUCH-EXPORTER-$$" JHC_POLL_S=1 JHC_EXPORT_WAIT_S=6 \
      "$@" /bin/bash "$SCRIPT" 2>&1)"; RC=$?
}
snap() { echo "$(gl rev-parse HEAD 2>&1) $(gl rev-list --count HEAD 2>&1) $(ls -A "$REPO/.git" | tr '\n' ,) $(find "$REPO/.git/refs" "$REPO/.git/index" "$REPO/.git/HEAD" "$REPO/.git/config" -type f -exec cksum {} + 2>/dev/null | sort | tr '\n' ' ')"; }
objn() { find "$REPO/.git/objects" -type f | wc -l | tr -d ' '; }   # a failed run leaves at most the kept commits re-written in step 1 (small, unreachable, pruned by git later); nothing else
objs_ok() { [ "$(objn)" -le $(( $1 + 13 )) ]; }
no_leftovers() { [ ! -e "$REPO.history-cap-old" ] && [ ! -e "$REPO.history-cap-new" ] && [ ! -e "$REPO.history-cap-new.fetch.err" ]; }

# ── S1 ──
case_cap() {  # case_cap <name> — the S1 assertions; used by M1 against mutants
  newcase "$1"; mk_repo 40 4 60 || { bad "fixture"; return; }
  local before count kept ref_trees ref_meta head_tree after
  before="$(kib)"; count="$(gl rev-list --count HEAD)"; kept="$(expected_kept 40 4 3 2)"
  ref_trees="$(gl log -n "$kept" --format=%T)"; ref_meta="$(gl log -n "$kept" --format='%an|%ae|%at|%cn|%ce|%ct|%s')"; head_tree="$(gl rev-parse 'HEAD^{tree}')"
  eq "fixture commits" "$count" 160; eq "fixture kept" "$kept" 12
  run_cap
  eq "rc" "$RC" 0; eq "status" "$(st)" capped
  eq "commit count" "$(gl rev-list --count HEAD)" "$kept"
  eq "head tree unchanged" "$(gl rev-parse 'HEAD^{tree}')" "$head_tree"
  eq "kept trees unchanged" "$(gl log -n "$kept" --format=%T)" "$ref_trees"
  eq "kept author/committer/time/message unchanged" "$(gl log --format='%an|%ae|%at|%cn|%ce|%ct|%s')" "$ref_meta"
  eq "oldest kept has no parent" "$(gl log --format=%P | tail -n 1)" ""
  eq "exactly one root" "$(gl rev-list --max-parents=0 HEAD | wc -l | tr -d ' ')" 1
  after="$(kib)"
  expect ".git shrank to a fraction ($before -> $after KiB)" test $((after * 4)) -lt "$before"
  expect ".git holds about the window ($after KiB <= $(( kept * 70 + 600 )))" test "$after" -le $(( kept * 70 + 600 ))
  eq "work tree clean (the index came along)" "$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')" 0
  expect "fsck --full --strict" gl fsck --full --strict --no-dangling
  eq "config survived (pack.threads)" "$(gl config pack.threads)" 2
  eq "config survived (gc.auto)" "$(gl config gc.auto)" 0
  expect "no leftover dirs" no_leftovers
  expect "lock released" test ! -e "$C/lock"
  eq "no mail" "$(mails)" 0
  head -c 60000 /dev/urandom > "$REPO/hq.jsonl"; git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -q -m "after the cap"
  eq "a commit after the cap works" "$(gl rev-list --count HEAD)" $((kept + 1))
  git -C "$REPO" reset -q --hard HEAD~1 2>/dev/null
}
newcase s1; case_cap s1
has "log says step 6" "step 6"
H="$(gl rev-parse HEAD)"; run_cap
eq "second run: status" "$(st)" ok-within-window; eq "second run: head unchanged" "$(gl rev-parse HEAD)" "$H"

# ── S2 slack ──
newcase s2; mk_repo 4 1 5
H="$(gl rev-parse HEAD)"
run_cap; eq "slack: status" "$(st)" ok-within-slack; eq "slack: untouched" "$(gl rev-parse HEAD)" "$H"; eq "slack: 4 commits" "$(gl rev-list --count HEAD)" 4
run_cap JHC_ALARM_KIB=1
eq "slack + .git over the alarm size: capped" "$(st)" capped; eq "...to 3 commits" "$(gl rev-list --count HEAD)" 3

# ── S3 KEEP_MIN ──
newcase s3; mk_repo 3 1 5
T2="$(gl log -n 2 --format=%T)"
run_cap JHC_NOW=$(( $(date +%s) + 864000 ))
eq "keep_min: status" "$(st)" capped; eq "keep_min: 2 commits" "$(gl rev-list --count HEAD)" 2; eq "keep_min: trees" "$(gl log --format=%T)" "$T2"
run_cap JHC_NOW=$(( $(date +%s) + 864000 )) JHC_KEEP_MIN=1
eq "keep_min=1: status" "$(st)" capped; eq "keep_min=1: 1 commit" "$(gl rev-list --count HEAD)" 1

# ── S4 inert on doubt ──
inert() {  # inert <name> <expected status> [VAR=val...] — a fresh 6-day repo that WOULD be cut, after <setup> ran; nothing may change
  local name="$1" want="$2" before; shift 2
  newcase "s4-$name"; mk_repo 6 4 5
  [ -n "${SETUP:-}" ] && eval "$SETUP"
  before="$(snap)"
  run_cap "$@"
  eq "$name: status" "$(st)" "$want"; eq "$name: rc" "$RC" 0; eq "$name: repo untouched" "$(snap)" "$before"; expect "$name: no leftover dirs" no_leftovers
  SETUP=""
}
SETUP='git -C "$REPO" remote add origin /nonexistent/remote.git'; inert remote skipped-remote
SETUP='git -C "$REPO" branch other'; inert refs skipped-refs
SETUP='git -C "$REPO" checkout -q -b side HEAD~3 && echo s > "$REPO/side.txt" && git -C "$REPO" add -A && git -C "$REPO" commit -q -m side && git -C "$REPO" checkout -q master && git -C "$REPO" merge -q --no-ff -m merge side && git -C "$REPO" branch -q -d side'; inert merges skipped-merges
SETUP='echo "$(git -C "$REPO" rev-parse HEAD)" > "$REPO/.git/shallow"'; inert shallow skipped-layout
SETUP='mkdir "$REPO/.git/worktrees"'; inert unknown-entry skipped-layout
SETUP=': > "$REPO/.git/index.lock"'; inert index-lock skipped-busy
SETUP=': > "$REPO/.git/gc.pid"'; inert gc-pid skipped-busy
SETUP='git -C "$REPO" checkout -q --detach'; inert detached skipped-unreadable
SETUP='h="$(git -C "$REPO" rev-parse HEAD)"; rm -f "$REPO/.git/objects/${h%"${h#??}"}/${h#??}"'; inert corrupt skipped-unreadable
SETUP=''; inert lstree-fails skipped-unreadable JHC_GIT="$BIN/git-wrap" WRAP_LSTREE_FAIL=1
has "ls-tree fails: the log says why (a failure is not a success)" "cannot size the baseline tree"
eq "ls-tree fails: no rewrite, fetch or swap was logged" "$(grep -c -E 'step [1256]' "$C/cap.log" 2>/dev/null)" 0
SETUP=''; inert lstree-empty skipped-unreadable JHC_GIT="$BIN/git-wrap" WRAP_LSTREE_EMPTY=1
eq "ls-tree empty: no rewrite, fetch or swap was logged" "$(grep -c -E 'step [1256]' "$C/cap.log" 2>/dev/null)" 0
SETUP='mkdir -p "$REPO/.git/branches" && echo x > "$REPO/.git/branches/x"'; inert branches-nonempty skipped-layout
SETUP='echo x > "$REPO/staged.txt" && git -C "$REPO" add staged.txt'; inert staged-index skipped-staged
SETUP=''; inert low-disk skipped-low-disk JHC_FREE_KIB=100
SETUP=''; inert free-unreadable skipped-low-disk JHC_FREE_KIB=garbage
newcase s4-norepo; run_cap; eq "no repo: status" "$(st)" skipped-no-repo; eq "no repo: rc" "$RC" 0
newcase s4-empty; mkdir -p "$REPO"; git init -q -b master "$REPO"; run_cap; eq "empty repo: status" "$(st)" ok-empty; eq "empty repo: rc" "$RC" 0
# a lock held by a live run
newcase s4-lock; mk_repo 6 4 5; sleep 120 & LP=$!; disown "$LP"; BGPIDS="$BGPIDS $LP"; mkdir "$C/lock"; echo "$LP" > "$C/lock/pid"
B="$(snap)"; run_cap
eq "live lock: status" "$(st)" skipped-lock; eq "live lock: rc" "$RC" 0; eq "live lock: repo untouched" "$(snap)" "$B"
eq "live lock: the other run's lock is still there, with its pid" "$(cat "$C/lock/pid" 2>/dev/null)" "$LP"; kill "$LP" 2>/dev/null
# a running exporter that does not finish within the wait
newcase s4-exporter; mk_repo 6 4 5; FAKE_EXPORT_S=60 bash "$BIN/$FAKE.sh" & XP=$!; disown "$XP"; BGPIDS="$BGPIDS $XP"; sleep 1
B="$(snap)"; run_cap JHC_EXPORT_RE=$FAKE JHC_EXPORT_WAIT_S=1
eq "exporter running: status" "$(st)" skipped-busy; eq "exporter running: rc" "$RC" 0; eq "exporter running: repo untouched" "$(snap)" "$B"; expect "exporter running: no leftover dirs" no_leftovers
expect "exporter running: lock released" test ! -e "$C/lock"
kill "$XP" 2>/dev/null

# ── S5 stale lock, exporter that ends during the wait ──
newcase s5-stale; mk_repo 6 4 5; true & DP=$!; wait "$DP"; mkdir "$C/lock"; echo "$DP" > "$C/lock/pid"; touch -t 202001010000 "$C/lock"
run_cap; eq "stale lock: status" "$(st)" capped; has "stale lock" "reclaiming"
newcase s5-export; mk_repo 6 4 5; FAKE_EXPORT_S=3 bash "$BIN/$FAKE.sh" & XP=$!; disown "$XP"; BGPIDS="$BGPIDS $XP"; sleep 1
run_cap JHC_EXPORT_RE=$FAKE JHC_EXPORT_WAIT_S=40
eq "exporter that ends: status" "$(st)" capped; while kill -0 "$XP" 2>/dev/null; do sleep 1; done

# ── S6 failures ──
failcase() {  # failcase <name> <expected status> <expected rc> [VAR=val...]
  local name="$1" want="$2" wrc="$3"; shift 3
  newcase "s6-$name"; mk_repo 6 4 5; FB="$(snap)"; FO="$(objn)"
  run_cap "$@"
  eq "$name: status" "$(st)" "$want"; eq "$name: rc" "$RC" "$wrc"
}
failcase fetch-fails failed-build 1 JHC_GIT="$BIN/git-wrap" WRAP_FETCH_FAIL=1
eq "fetch fails: repo untouched" "$(snap)" "$FB"; expect "fetch fails: only the re-written commits were added to objects" objs_ok "$FO"; expect "fetch fails: no leftover dirs" no_leftovers; eq "fetch fails: one mail" "$(mails)" 1
run_cap JHC_GIT="$BIN/git-wrap" WRAP_FETCH_FAIL=1; eq "fetch fails again: still one mail (rate limit)" "$(mails)" 1
run_cap JHC_GIT="$BIN/git-wrap" WRAP_FETCH_FAIL=1 JHC_ALERT_EVERY_S=0; eq "rate limit 0: second mail" "$(mails)" 2
run_cap JHC_GIT="$BIN/git-wrap" WRAP_FETCH_FAIL=1 JHC_ALERT_EVERY_S=0 GC_STUB_RC=1; has "failing mail command is logged" "alarm mail NOT sent"; eq "a failing mail command is not fatal: status" "$(st)" failed-build
# the disk watch
newcase s6-disk; mk_repo 6 4 5; B="$(snap)"; O0="$(objn)"; echo 50000000 > "$C/free"; ( sleep 3; echo 100 > "$C/free" ) & BGPIDS="$BGPIDS $!"; disown
T0="$(date +%s)"; run_cap JHC_GIT="$BIN/git-wrap" WRAP_SLEEP=19.37 JHC_FREE_KIB_FILE="$C/free" JHC_ABORT_FLOOR_KIB=1000; T1="$(date +%s)"
eq "disk watch: status" "$(st)" failed-build; has "disk watch" "free space fell"; expect "disk watch: stopped well before the wrapper's sleep ($((T1 - T0))s)" test $((T1 - T0)) -lt 15
sleep 1; expect "disk watch: no process left" test -z "$(pgrep -f 'sleep 19.37')"; eq "disk watch: repo untouched" "$(snap)" "$B"; expect "disk watch: only the re-written commits were added to objects" objs_ok "$O0"; expect "disk watch: no leftover dirs" no_leftovers
# wrong head fetched
newcase s6-verify; mk_repo 6 4 5; B="$(snap)"; O0="$(objn)"; run_cap JHC_GIT="$BIN/git-wrap" WRAP_FAKE_SHA="$(gl rev-parse HEAD)"
eq "verify: status" "$(st)" failed-verify; eq "verify: repo untouched" "$(snap)" "$B"; expect "verify: only the re-written commits were added to objects" objs_ok "$O0"; expect "verify: no leftover dirs" no_leftovers; eq "verify: one mail" "$(mails)" 1
# a commit lands in the old repo during the gap
newcase s6-gap; mk_repo 6 4 5; N0="$(gl rev-list --count HEAD)"; run_cap JHC_HOOK="$BIN/hook" HOOK_MODE=late-commit
eq "gap: status" "$(st)" rolled-back; eq "gap: rc" "$RC" 1; eq "gap: the old repo is back WITH the commit that landed" "$(gl rev-list --count HEAD)" $((N0 + 1)); eq "gap: its message" "$(gl log -n 1 --format=%s)" gap
expect "gap: no leftover dirs" no_leftovers; eq "gap: one mail" "$(mails)" 1; expect "gap: lock released" test ! -e "$C/lock"
# .git recreated between the two renames
newcase s6-conflict; mk_repo 6 4 5; run_cap JHC_HOOK="$BIN/hook" HOOK_MODE=recreate
eq "conflict: status" "$(st)" conflict; eq "conflict: rc" "$RC" 1
expect "conflict: old dir kept" test -d "$REPO.history-cap-old/objects"; expect "conflict: new dir kept" test -d "$REPO.history-cap-new/objects"; eq "conflict: one mail" "$(mails)" 1
eq "conflict: the old repo is intact" "$(git --git-dir="$REPO.history-cap-old" rev-list --count HEAD)" 24
run_cap; eq "after a conflict the next run is inert: leftover-kept" "$(st)" leftover-kept
expect "after a conflict nothing was deleted (old)" test -d "$REPO.history-cap-old/objects"; expect "after a conflict nothing was deleted (new)" test -d "$REPO.history-cap-new/objects"
# SIGTERM between the two renames
newcase s6-term; mk_repo 6 4 5; B="$(snap)"; O0="$(objn)"; run_cap JHC_HOOK="$BIN/hook" HOOK_MODE=term
eq "term: rc 143" "$RC" 143; eq "term: the old .git is back, untouched" "$(snap)" "$B"; expect "term: only the re-written commits were added to objects" objs_ok "$O0"; expect "term: no leftover dirs" no_leftovers; expect "term: lock released" test ! -e "$C/lock"

# ── S7 leftovers ──
newcase s7-new; mk_repo 6 4 5; mkdir -p "$REPO.history-cap-new/junk"; echo x > "$REPO.history-cap-new/junk/f"
run_cap; eq "stale new dir: status" "$(st)" capped; expect "stale new dir: gone" no_leftovers
newcase s7-old-nogit; mk_repo 6 4 5; mv "$REPO/.git" "$REPO.history-cap-old"
run_cap; eq "old dir and no .git: status" "$(st)" capped; has "old dir and no .git" "back in place"; expect "old dir and no .git: no leftover dirs" no_leftovers; eq "...cut" "$(gl rev-list --count HEAD)" "$(expected_kept 6 4 3 2)"
newcase s7-old-same; mk_repo 6 4 5; cp -R "$REPO/.git" "$REPO.history-cap-old"
run_cap; eq "old dir, same head tree: status" "$(st)" capped; expect "old dir, same head tree: deleted" no_leftovers
# the exporter commits every 15 min: by the next run the live head has moved on, and the old dir's head tree is only a commit in the live history (gate fix 1/3)
newcase s7-old-history; mk_repo 6 4 5; cp -R "$REPO/.git" "$REPO.history-cap-old"; echo more > "$REPO/more.txt"; git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -q -m more
run_cap; eq "old dir, head tree in the live history: status" "$(st)" capped; expect "old dir, head tree in the live history: deleted" no_leftovers; eq "old dir, head tree in the live history: the live commit survived" "$(gl log -n 1 --format=%s)" more
# the other way: the old dir holds a tree the live repo does NOT have — never deleted by a script
newcase s7-old-other; mk_repo 6 4 5; echo more > "$REPO/more.txt"; git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -q -m more; cp -R "$REPO/.git" "$REPO.history-cap-old"; git -C "$REPO" reset -q --hard HEAD~1; B="$(snap)"
run_cap; eq "old dir, other tree: status" "$(st)" leftover-kept; eq "old dir, other tree: rc" "$RC" 1; expect "old dir, other tree: kept" test -d "$REPO.history-cap-old/objects"; eq "old dir, other tree: live repo untouched" "$(snap)" "$B"

# ── S8 catch-up ──
newcase s8; mk_repo 6 4 5; N0="$(gl rev-list --count HEAD)"; K0="$(expected_kept 6 4 3 2)"
PRE="t=\$(git --git-dir='$REPO/.git' rev-parse 'HEAD^{tree}'); p=\$(git --git-dir='$REPO/.git' rev-parse HEAD); c=\$(echo landed | git --git-dir='$REPO/.git' commit-tree \"\$t\" -p \"\$p\"); git --git-dir='$REPO/.git' update-ref refs/heads/master \"\$c\""
run_cap JHC_GIT="$BIN/git-wrap" WRAP_PRE_FETCH="$PRE" WRAP_MARK="$C/mark"
eq "catch-up: status" "$(st)" capped; has "catch-up" "catch-up 1"; eq "catch-up: the landed commit is in the result" "$(gl log -n 1 --format=%s)" landed; eq "catch-up: count" "$(gl rev-list --count HEAD)" $((K0 + 1))
eq "catch-up: work tree clean" "$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')" 0

# ── S9 alarm ──
newcase s9; mk_repo 2 2 5
run_cap JHC_ALARM_KIB=1; eq "over the alarm size: mail" "$(mails)" 1; run_cap JHC_ALARM_KIB=1; eq "rate limited" "$(mails)" 1
run_cap JHC_ALARM_KIB=1 JHC_ALERT_EVERY_S=0; eq "rate limit 0" "$(mails)" 2
OUT="$(env JHC_REPO="$REPO" JHC_ALARM_KIB=1 /bin/bash "$SCRIPT" --check 2>&1)"; RC=$?
eq "--check over the alarm size: exit 3" "$RC" 3; has "--check" "over the alarm size"
OUT="$(env JHC_REPO="$REPO" /bin/bash "$SCRIPT" --check 2>&1)"; RC=$?; eq "--check under it: exit 0" "$RC" 0; has "--check says what it would do" "would_cap=no"
# the alarm mail is the only channel of the HIGH alert: a send that FAILS must come back after JHC_ALERT_RETRY_S, not after the full rate limit (gate fix 1/3)
newcase s9c; mk_repo 2 2 5
run_cap JHC_ALARM_KIB=1 GC_STUB_RC=1; eq "failing mail: attempted once" "$(mails)" 1; has "failing mail: logged" "alarm mail NOT sent"
run_cap JHC_ALARM_KIB=1; eq "failing mail, default retry (1h): a run right after is still held back" "$(mails)" 1
newcase s9d; mk_repo 2 2 5
run_cap JHC_ALARM_KIB=1 GC_STUB_RC=1 JHC_ALERT_RETRY_S=0; eq "failing mail, retry 0: attempted once" "$(mails)" 1
run_cap JHC_ALARM_KIB=1 JHC_ALERT_RETRY_S=0; eq "failing mail, retry 0: the next run tries again" "$(mails)" 2
run_cap JHC_ALARM_KIB=1 JHC_ALERT_RETRY_S=0; eq "a mail that went out: the clock is the full rate limit again" "$(mails)" 2
newcase s9b; mk_repo 40 4 5; B="$(snap)"; OUT="$(env JHC_REPO="$REPO" /bin/bash "$SCRIPT" --check 2>&1)"; RC=$?; eq "--check changes nothing" "$(snap)" "$B"; has "--check plan" "would_cap=yes"; eq "--check on a cuttable repo: exit 0" "$RC" 0

# ── S10 bounded over time ──
newcase s10; REPO="$C/rt/packs/maintenance/jsonl-archive"; REPO_CTRL="$C/ctrl"
mkdir -p "$REPO" "$REPO_CTRL"; git init -q -b master "$REPO"; git init -q -b master "$REPO_CTRL"
head -c 100000 /dev/urandom > "$REPO/static.jsonl"; cp "$REPO/static.jsonl" "$REPO_CTRL/static.jsonl"
SIM0=$(( $(date +%s) - 21 * 86400 )); MAXK=0; TREEOK=1; CLEANOK=1; day=0
while [ "$day" -lt 20 ]; do
  slot=0
  while [ "$slot" -lt 4 ]; do
    t=$(( SIM0 + day * 86400 + slot * 21600 ))
    head -c 100000 /dev/urandom > "$REPO/hq.jsonl"; cp "$REPO/hq.jsonl" "$REPO_CTRL/hq.jsonl"; echo "$day.$slot" > "$REPO/meta.txt"; cp "$REPO/meta.txt" "$REPO_CTRL/meta.txt"
    for r in "$REPO" "$REPO_CTRL"; do git -C "$r" add -A >/dev/null; GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000" git -C "$r" commit -q -m "backup $day.$slot"; done
    slot=$((slot + 1))
  done
  HT="$(gl rev-parse 'HEAD^{tree}')"
  run_cap JHC_NOW=$(( SIM0 + day * 86400 + 86400 ))
  [ "$(gl rev-parse 'HEAD^{tree}')" = "$HT" ] || TREEOK=0
  [ "$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')" = 0 ] || CLEANOK=0
  [ "$RC" -eq 0 ] || { bad "bounded: run on day $day failed (rc $RC)"; break; }
  k="$(kib)"; [ "$k" -gt "$MAXK" ] && MAXK="$k"
  day=$((day + 1))
done
CK="$(du -sk "$REPO_CTRL/.git" | awk '{print $1}')"; BOUND=$(( 24 * 105 + 600 ))
expect "bounded: max .git over 20 days ($MAXK KiB) stays under $BOUND KiB" test "$MAXK" -le "$BOUND"
expect "bounded: the same history WITHOUT the cap ($CK KiB) is over that bound" test "$CK" -gt "$BOUND"
eq "bounded: the tree never changed" "$TREEOK" 1; eq "bounded: the work tree was always clean" "$CLEANOK" 1
expect "bounded: the history is no longer than the window plus a day ($(gl rev-list --count HEAD) commits)" test "$(gl rev-list --count HEAD)" -le 24

# ── S11 configuration, order ──
CASE=s11
OUT="$(env JHC_KEEP_DAYS=abc /bin/bash "$SCRIPT" --print-config 2>&1)"; eq "keep_days=abc refused" "$?" 2
OUT="$(env JHC_KEEP_DAYS=0 /bin/bash "$SCRIPT" --print-config 2>&1)"; eq "keep_days=0 refused (a window of nothing would delete everything)" "$?" 2
OUT="$(env JHC_KEEP_MIN=0 /bin/bash "$SCRIPT" --print-config 2>&1)"; eq "keep_min=0 refused" "$?" 2
OUT="$(/bin/bash "$SCRIPT" --bogus 2>&1)"; eq "unknown argument refused" "$?" 2
OUT="$(env -u JHC_KEEP_DAYS /bin/bash "$SCRIPT" --print-config 2>&1)"
DL="$(printf '%s\n' "$OUT" | sed -n 's/.*deadline_s=\([0-9]*\).*/\1/p' | head -n 1)"; KD="$(printf '%s\n' "$OUT" | sed -n 's/.*keep_days=\([0-9]*\).*/\1/p' | head -n 1)"
eq "default window is 3 days (the bead)" "$KD" 3
if [ -f "$ORDER" ]; then
  OT="$(sed -n 's/^timeout *= *"\([0-9]*\)s".*/\1/p' "$ORDER")"; OI="$(sed -n 's/^interval *= *"\([0-9]*\)h".*/\1/p' "$ORDER")"
  expect "order: timeout ($OT s) covers the script's deadline ($DL s)" test -n "$OT" -a "$OT" -gt "$DL"
  expect "order: interval ($OI h) is not shorter than the timeout" test -n "$OI" -a $(( OI * 3600 )) -ge "${OT:-0}"
  expect "order: exec is this script" grep -q 'exec = "\$PACK_DIR/assets/scripts/jsonl-archive-history-cap.sh"' "$ORDER"
  expect "order: cooldown trigger" grep -q '^trigger = "cooldown"' "$ORDER"
else bad "the order file $ORDER does not exist"; fi
if [ -f "$COMPACT_ORDER" ]; then
  expect "compact order points to the cap (its comment used to say history is never shortened, with no word of who bounds it)" grep -q 'jsonl-archive-history-cap' "$COMPACT_ORDER"
else bad "the compact order file $COMPACT_ORDER does not exist"; fi

# ── M1 mutants: the S1 assertions must be able to fail ──
CASE=m1
sed 's/^  DROP_N=\$((N - KEEP_N))$/  KEEP_N=$N; DROP_N=0/' "$SCRIPT" > "$BIN/mutant-nocut.sh"
sed 's/^  DROP_N=\$((N - KEEP_N))$/  KEEP_N=$((KEEP_N + 1)); DROP_N=$((N - KEEP_N))/' "$SCRIPT" > "$BIN/mutant-offbyone.sh"
for m in nocut offbyone; do
  if cmp -s "$SCRIPT" "$BIN/mutant-$m.sh"; then bad "mutant $m is identical to the script (the sed matched nothing)"; continue; fi
  MUT=1; MUT_FAIL=0; SAVE="$SCRIPT"; SCRIPT="$BIN/mutant-$m.sh"; case_cap "m1-$m" >/dev/null 2>&1; SCRIPT="$SAVE"; MUT=0
  CASE=m1; expect "the S1 assertions catch the '$m' mutant ($MUT_FAIL failed checks)" test "$MUT_FAIL" -gt 0
done

echo "jsonl-archive-history-cap selftest: $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
