#!/bin/bash
# jsonl-archive-history-cap.sh (ga-zfy8j4x) — keep only the last N days of the jsonl-archive git history.
#
# WHY: mol-dog-jsonl commits a fresh copy of the exported beads many times a day (every ~15 min). jsonl-archive-compact.sh packs the
# loose objects, but it NEVER shortens history, and the history is what grows: 12.969 commits were 2,9 GB of .git on 16/11/2026,
# which took the mini's disk down. The Mayor cut it by hand that day (new repo, same tree, tree hash checked, swap, old one deleted).
# Nothing reads that history back: the S3 mirror copies only the working tree (.git is excluded — no offsite copy of the history
# exists), no restore walks it, and the exporter's spike detection only compares against the PREVIOUS commit. So the ceiling is a
# policy of this city, not a loss: the commits older than JHC_KEEP_DAYS (3) are given up, on purpose, by this script and no other.
#
# WHAT: when the repo holds commits older than the window (and the oldest is more than JHC_SLACK_H (12h) past it — or the .git is
# already over the alarm size), it rebuilds the history the way the Mayor did, WITHOUT a gc/repack of the big repo:
#   1. every kept commit is re-written with the SAME tree, author, committer and message, and the oldest kept one loses its parent
#      (`git cat-file commit` -> `git hash-object -t commit -w`: a few hundred bytes each, trees and blobs are shared, nothing copied);
#   2. a NEW git dir (sibling of the repo, same filesystem) is filled with ONE `git fetch` of the new head from the live .git: the pack
#      holds only what the kept window reaches (git reuses the stored deltas — no recompression of the 41MB blobs), under a free-space
#      and size watch that kills the fetch before the disk can fall under JHC_ABORT_FLOOR_KIB;
#   3. verified BEFORE it is installed: the head is the re-written head, the commit count is the kept count, and EVERY kept commit has
#      the tree its original had (so the working tree and the content of each kept snapshot are unchanged), and
#      `git fsck --connectivity-only` passes;
#   4. config, hooks, info and the INDEX of the old .git are copied over (the index only matches its tree when nothing was committed
#      in between: the exporter must not be running, there must be no index.lock, the index must hold nothing staged that HEAD lacks
#      (git diff-index --cached; staged blobs live only in the old repo), and a commit that landed meanwhile is re-written
#      and fetched too — a bounded catch-up — or the run gives up and tries again next hour);
#   5. the swap is two `mv`s back to back: .git -> <repo>.history-cap-old, <repo>.history-cap-new -> .git. It is checked right after
#      (head tree, commit count, the old head still being the one that was re-written) and UNDONE if any of it differs;
#   6. only then the old .git is deleted — the one step that frees the disk. A delete that did not finish is picked up by the next run when the old
#      dir still reads as a repo whose head tree the live repo has (its head, or a commit in its history: the exporter commits every 15 min).
# Peak disk use is the size of the kept window's pack, not of the old repo.
#
# INERT ON DOUBT (three states for every read — has / has not / cannot know, and "cannot know" never acts): a remote (a push would
# diverge), more than one ref, a merge commit, a shallow or alternates file, a git dir with an entry this script does not know (an EMPTY .git/branches, which the Debian git template makes, is known), a staged-but-uncommitted index, a
# lock file of git, another repacker or the exporter running, a free-space reading that fails, a baseline-tree size that cannot be read, a log line that is not a sha and a
# time — each ends the run as skipped-<why>, exit 0, repo untouched. The jsonl-archive-compact lock ($RUNTIME/jsonl-archive-compact.lock)
# is the SAME lock: one repo writer at a time, and the exporter (which looks at it) starts no background maintenance while it is held.
#
# ALARM: the .git over JHC_ALARM_KIB (1GiB) after the run, or a run that failed / was rolled back / could not finish its swap, mails
# mayor/ (rate-limited: JHC_ALERT_EVERY_S, recorded BEFORE the send; a send that FAILS moves the clock back so the next try is JHC_ALERT_RETRY_S (1h) away, not 6h). A failed run before the swap leaves the live repo as it was
# (refs, index, packs, config: the only addition is the few small unreachable commit objects written in step 1, which git prunes later).
#
# Modes: (none) run | --check  measure only, print the plan, no lock, no write — exit 3 when .git is over the alarm size | --print-config
# Exit codes: 0 done / nothing to do / inert on doubt; 1 failure (the status says which); 2 bad usage or configuration; 3 (--check) over alarm size.

set -u
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_CEILING_DIRECTORIES

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
RUNTIME="${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}"
REPO="${JHC_REPO:-$RUNTIME/packs/maintenance/jsonl-archive}"
LOCK="${JHC_LOCK:-$RUNTIME/jsonl-archive-compact.lock}"
STATE="${JHC_STATE:-$RUNTIME/packs/town-deltas/jsonl-archive-history-cap-state.json}"
LOG="${JHC_LOG:-$CITY/.gc/logs/jsonl-archive-history-cap.log}"
GCBIN="${JHC_GC:-gc}"
GITBIN="${JHC_GIT:-git}"                             # test seam: a wrapper that can slow the fetch down
KEEP_DAYS="${JHC_KEEP_DAYS:-3}"                      # history kept: commits newer than this many days
KEEP_MIN="${JHC_KEEP_MIN:-2}"                        # ...and never fewer than this many commits (spike detection reads the previous one)
SLACK_H="${JHC_SLACK_H:-12}"                         # the oldest commit must be this many hours past the window before a run acts: a rebuild about every SLACK_H hours at most, not one an hour (right after a cap the oldest kept commit is ~3 d old and crosses window+SLACK_H again SLACK_H hours later)
ALARM_KIB="${JHC_ALARM_KIB:-1048576}"                # .git over 1GiB after the run = mail
FLOOR_KIB="${JHC_FLOOR_KIB:-1048576}"                # free space that must REMAIN after the new pack is built (need = estimate + this)
ABORT_FLOOR_KIB="${JHC_ABORT_FLOOR_KIB:-524288}"     # the fetch is killed when the free space falls under this
DEADLINE_S="${JHC_DEADLINE_S:-2400}"                 # whole run; the order's timeout is 3000s
FETCH_TIMEOUT_S="${JHC_FETCH_TIMEOUT_S:-1500}"
GIT_TIMEOUT_S="${JHC_GIT_TIMEOUT_S:-120}"
EXPORT_WAIT_S="${JHC_EXPORT_WAIT_S:-300}"            # how long to wait for a running jsonl-export.sh before the swap
EXPORT_RE="${JHC_EXPORT_RE:-jsonl-export\\.sh}"
POLL_S="${JHC_POLL_S:-2}"
CATCHUP_MAX="${JHC_CATCHUP_MAX:-3}"
ALERT_EVERY_S="${JHC_ALERT_EVERY_S:-21600}"
ALERT_RETRY_S="${JHC_ALERT_RETRY_S:-3600}"           # when the alarm mail itself FAILS, the next try is this many seconds later (not ALERT_EVERY_S)
MAIL_TIMEOUT_S="${JHC_MAIL_TIMEOUT_S:-45}"
LOCK_STALE_MIN="${JHC_LOCK_STALE_MIN:-90}"
LOCK_GRACE_S=600                                     # a lock holder that wrote its end time (the compactor's night gc) is alive this long after it
LOG_MAX_LINES=2000
NEWDIR="$REPO.history-cap-new"
OLDDIR="$REPO.history-cap-old"

MODE=run
case "${1:-}" in
  --check) MODE=check ;;
  --print-config) MODE=print ;;
  "") ;;
  *) echo "jsonl-archive-history-cap: unknown argument '$1' (use --check or --print-config)" >&2; exit 2 ;;
esac

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
for _v in KEEP_DAYS KEEP_MIN SLACK_H ALARM_KIB FLOOR_KIB ABORT_FLOOR_KIB DEADLINE_S FETCH_TIMEOUT_S GIT_TIMEOUT_S EXPORT_WAIT_S POLL_S CATCHUP_MAX ALERT_EVERY_S ALERT_RETRY_S MAIL_TIMEOUT_S LOCK_STALE_MIN; do
  if ! is_uint "${!_v}"; then echo "jsonl-archive-history-cap: $_v='${!_v}' is not a number — refusing to run on a misread configuration" >&2; exit 2; fi
done
if [ "$KEEP_DAYS" -lt 1 ] || [ "$KEEP_MIN" -lt 1 ] || [ "$POLL_S" -lt 1 ]; then
  echo "jsonl-archive-history-cap: JHC_KEEP_DAYS, JHC_KEEP_MIN and JHC_POLL_S must be at least 1 (a window of nothing would delete the whole history)" >&2; exit 2
fi

if [ "$MODE" = print ]; then
  cat <<EOF
repo=$REPO keep_days=$KEEP_DAYS keep_min=$KEEP_MIN slack_h=$SLACK_H
alarm_kib=$ALARM_KIB floor_kib=$FLOOR_KIB abort_floor_kib=$ABORT_FLOOR_KIB
deadline_s=$DEADLINE_S fetch_timeout_s=$FETCH_TIMEOUT_S git_timeout_s=$GIT_TIMEOUT_S export_wait_s=$EXPORT_WAIT_S catchup_max=$CATCHUP_MAX
alert_every_s=$ALERT_EVERY_S alert_retry_s=$ALERT_RETRY_S mail_timeout_s=$MAIL_TIMEOUT_S lock_stale_min=$LOCK_STALE_MIN
state=$STATE log=$LOG lock=$LOCK new_dir=$NEWDIR old_dir=$OLDDIR
EOF
  exit 0   # benign[print-config]: only prints the effective configuration — nothing ran, so there is no failure for this exit to hide
fi

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { if [ -n "${JHC_NOW:-}" ]; then echo "$JHC_NOW"; else date +%s; fi; }
log() {
  local line="[$(ts)] $*"
  echo "$line"
  [ "$MODE" = check ] && return 0
  # benign[log-mkdir]: the line is already on stdout (the order's own capture) — a log file that cannot be made must not stop the run it reports on
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  # benign[log-write]: same — stdout has the line; the run's outcome is its exit code and its state file, never this file
  echo "$line" >> "$LOG" 2>/dev/null || true
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
    # benign[log-trim]: trimming is housekeeping of a diagnostic file; when it fails the file only grows until a later trim works
    tail -n $((LOG_MAX_LINES / 2)) "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" 2>/dev/null || true
  fi
}

START="$(now)"
elapsed() { echo $(( $(now) - START )); }
fmt() { if is_uint "${1:-}"; then echo "$(( $1 / 1024 ))MiB"; else echo "?"; fi; }

_timeout_bin=""
for _t in ${JHC_TIMEOUT_CMDS:-timeout gtimeout}; do command -v "$_t" >/dev/null 2>&1 && { _timeout_bin="$_t"; break; }; done
_bounded() {  # _bounded <seconds> <cmd...> — nice 10 and, when the host has `timeout`, a cap (the order's own kill is the bound without it)
  local t="$1"; shift
  if [ -n "$_timeout_bin" ]; then "$_timeout_bin" "$t" nice -n 10 "$@"; else nice -n 10 "$@"; fi
}
G() { _bounded "$GIT_TIMEOUT_S" "$GITBIN" --git-dir="$REPO/.git" "$@"; }     # READS of the live repo (plus the commit objects of step 1)

free_kib() {  # free KiB on the filesystem holding $1; JHC_FREE_KIB (fixed) and JHC_FREE_KIB_FILE (read on every call) are the test seams. Prints nothing when df cannot say.
  if [ -n "${JHC_FREE_KIB_FILE:-}" ]; then cat "$JHC_FREE_KIB_FILE" 2>/dev/null; return; fi   # benign[free-seam]: a missing seam file reads as "df cannot say" — the callers treat that as unknown
  if [ -n "${JHC_FREE_KIB:-}" ]; then echo "$JHC_FREE_KIB"; return; fi
  df -k "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}
gitdir_kib() { du -sk "$1" 2>/dev/null | awk '{print $1}'; }
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -TERM "$1" 2>/dev/null; return 0; }   # benign[kill-tree]: a child that already ended is what we want

# ──────────────────────────────── measuring and planning (no writes) ────────────────────────────────
STATUS=""; WHY=""; BR=""; N=0; KEEP_N=0; DROP_N=0; G_KIB=""; EST_KIB=0
C_SHA=(); C_CT=()
skip() { STATUS="$1"; WHY="$2"; return 1; }

# The index is copied to the new repo as it is, which is right only when it equals HEAD's tree: a staged-but-uncommitted state (the exporter's commit failed, or it was
# killed between add and commit) points at blobs that sit loose in the OLD repo only, and the new pack does not hold them. 0 = clean (or no index file); 1 = STATUS/WHY say why not.
check_index() {
  local irc
  [ -f "$REPO/.git/index" ] || return 0   # no index file: nothing to copy, and git rebuilds it from HEAD
  # vazio/clean (rc 0) → fine; staged changes (rc 1) → inert; falhou/timeout (any other rc) → cannot know: inert too, never the same result as "clean"
  G diff-index --cached --quiet HEAD >/dev/null 2>&1; irc=$?
  case "$irc" in
    0) return 0 ;;
    1) skip skipped-staged "the index holds staged changes that are not in HEAD (an exporter commit that did not finish) — its blobs are not in the new pack" ; return 1 ;;
    *) skip skipped-unreadable "cannot compare the index with HEAD (git diff-index rc=$irc)"; return 1 ;;
  esac
}

inspect() {  # 0 = the repo can be evaluated (C_SHA/C_CT newest first, BR, N); 1 = STATUS/WHY say why not. Nothing here writes.
  local ent ref refs out line sha ct bo
  if [ -L "$REPO/.git" ]; then skip skipped-layout ".git is a symlink"; return 1; fi
  if [ ! -d "$REPO/.git" ]; then skip skipped-no-repo "no $REPO/.git (the exporter creates it)"; return 1; fi
  # vazio → an empty git dir is no repo and the rev-parse below says so; falhou (ls) → cannot know the layout: inert
  out="$(ls -A "$REPO/.git" 2>&1)" || { skip skipped-unreadable "cannot list $REPO/.git: $(printf '%s' "$out" | head -n 1)"; return 1; }
  for ent in $out; do
    case "$ent" in
      HEAD|config|description|hooks|info|index|logs|objects|refs|packed-refs|ORIG_HEAD|FETCH_HEAD|COMMIT_EDITMSG|gc.log|.DS_Store) ;;
      branches)  # the Debian/Ubuntu git template makes an EMPTY .git/branches (legacy, unused); a plain repo may carry it, anything inside (or a non-directory) is not the plain layout
        if [ -L "$REPO/.git/branches" ] || [ ! -d "$REPO/.git/branches" ]; then skip skipped-layout "'branches' in .git is not a plain directory"; return 1; fi
        # vazio → the template's empty dir, fine; falhou (ls) → cannot know the layout: inert; has → not the plain layout
        bo="$(ls -A "$REPO/.git/branches" 2>&1)" || { skip skipped-unreadable "cannot list $REPO/.git/branches: $(printf '%s' "$bo" | head -n 1)"; return 1; }
        if [ -n "$bo" ]; then skip skipped-layout "'branches' in .git holds entries"; return 1; fi ;;
      index.lock|HEAD.lock|config.lock|packed-refs.lock|gc.pid|maintenance.lock) skip skipped-busy "git's own lock $ent is present"; return 1 ;;
      *) skip skipped-layout "unknown entry '$ent' in .git (shallow, worktrees, modules...) — this script only knows a plain repo"; return 1 ;;
    esac
  done
  if [ -e "$REPO/.git/objects/info/alternates" ]; then skip skipped-layout "objects/info/alternates is present"; return 1; fi
  if [ -d "$REPO/.git/info" ]; then
    for ent in $(ls -A "$REPO/.git/info" 2>/dev/null); do   # benign[info-list]: an unlistable info dir ends the loop empty and the git reads below decide
      case "$ent" in exclude|attributes) ;; *) skip skipped-layout "unknown entry 'info/$ent'"; return 1 ;; esac
    done
  fi
  # falhou (symbolic-ref) → detached HEAD or unreadable: cannot know the branch, inert
  ref="$(G symbolic-ref -q HEAD 2>/dev/null)" || { skip skipped-unreadable "HEAD is not a branch (detached or unreadable)"; return 1; }
  case "$ref" in refs/heads/?*) BR="${ref#refs/heads/}" ;; *) skip skipped-unreadable "HEAD points to '$ref'"; return 1 ;; esac
  # vazio → no ref at all (a repo with no commit): nothing to cap; falhou → cannot know
  refs="$(G for-each-ref --format='%(refname)' 2>/dev/null)" || { skip skipped-unreadable "git for-each-ref failed"; return 1; }
  if [ -z "$refs" ]; then skip ok-empty "the repo has no commit yet"; return 1; fi
  if [ "$refs" != "$ref" ]; then skip skipped-refs "more refs than the one branch ($(printf '%s' "$refs" | tr '\n' ' ' | cut -c1-120))"; return 1; fi
  # vazio → no remote: truncating cannot diverge from anything; has → a push would diverge; falhou → cannot know
  out="$(G remote 2>/dev/null)" || { skip skipped-unreadable "git remote failed"; return 1; }
  if [ -n "$out" ]; then skip skipped-remote "the repo has a remote ($(printf '%s' "$out" | tr '\n' ' ')) — the history cannot be shortened under it"; return 1; fi
  # vazio → no merge commit; has → the linear rewrite would flatten it; falhou → cannot know
  out="$(G rev-list --merges --max-count=1 HEAD 2>/dev/null)" || { skip skipped-unreadable "git rev-list --merges failed"; return 1; }
  if [ -n "$out" ]; then skip skipped-merges "the history has a merge commit"; return 1; fi
  out="$(G log --format='%H %ct' HEAD 2>/dev/null)" || { skip skipped-unreadable "git log failed"; return 1; }
  C_SHA=(); C_CT=(); N=0
  while IFS= read -r line; do
    sha="${line%% *}"; ct="${line#* }"
    case "$sha" in *[!0-9a-f]*|'') skip skipped-unreadable "a log line that is not '<sha> <time>': '$line'"; return 1 ;; esac
    if [ "${#sha}" -ne 40 ] && [ "${#sha}" -ne 64 ]; then skip skipped-unreadable "bad commit id '$sha'"; return 1; fi
    if ! is_uint "$ct"; then skip skipped-unreadable "bad commit time in '$line'"; return 1; fi
    C_SHA[$N]="$sha"; C_CT[$N]="$ct"; N=$((N + 1))
  done <<EOF
$out
EOF
  if [ "$N" -eq 0 ]; then skip ok-empty "the branch has no commit"; return 1; fi
  check_index || return 1
  return 0
}

plan() {  # fills KEEP_N DROP_N CUTOFF ACT; sets STATUS to ok-* when there is nothing to do. 0 = something to cap.
  local i=0 root_ct
  CUTOFF=$(( $(now) - KEEP_DAYS * 86400 ))
  KEEP_N=0
  while [ "$i" -lt "$N" ]; do
    if [ "$i" -lt "$KEEP_MIN" ] || [ "${C_CT[$i]}" -ge "$CUTOFF" ]; then KEEP_N=$((i + 1)); else break; fi
    i=$((i + 1))
  done
  DROP_N=$((N - KEEP_N))
  root_ct="${C_CT[$((N - 1))]}"
  if [ "$DROP_N" -eq 0 ]; then STATUS=ok-within-window; WHY="$N commit(s), all within ${KEEP_DAYS}d or the last $KEEP_MIN"; return 1; fi
  if [ "$root_ct" -ge $(( CUTOFF - SLACK_H * 3600 )) ] && ! { is_uint "$G_KIB" && [ "$G_KIB" -gt "$ALARM_KIB" ]; }; then
    STATUS=ok-within-slack; WHY="$DROP_N commit(s) past the window, the oldest less than ${SLACK_H}h past it and .git is under the alarm size"; return 1
  fi
  return 0
}

# estimate of the NEW pack, in KiB: never more than the old .git, never more than the uncompressed baseline tree (a full copy of it is
# the worst a pack of that tree can be) plus 64MiB for the commits and trees. vazio/falhou → "" (cannot know: the caller stays inert)
estimate_kib() {
  local base="${C_SHA[$((KEEP_N - 1))]}" out tree
  # vazio → return 1 (a commit always has files: no listing = cannot know); falhou/timeout (ls-tree rc != 0) → return 1 (cannot know). The status is taken from ls-tree ITSELF,
  # not from a pipe: `ls-tree | awk` ends with awk's status and awk's END prints a number for an empty input, so a failed read used to size the tree at "0" (gate fix 1/3).
  out="$(G ls-tree -r -l "$base" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  # no line with a numeric size → no sum at all (tree stays empty and is_uint refuses it); a real 0 is only a tree whose files are all empty
  tree="$(printf '%s\n' "$out" | awk '$4 ~ /^[0-9]+$/ {s += $4; n++} END {if (n > 0) print int(s / 1024)}')"
  is_uint "$tree" || return 1
  EST_KIB=$(( tree + 65536 ))
  if is_uint "$G_KIB" && [ "$G_KIB" -lt "$EST_KIB" ]; then EST_KIB="$G_KIB"; fi
  return 0
}

if [ "$MODE" = check ]; then
  G_KIB="$(gitdir_kib "$REPO/.git")"
  echo "repo=$REPO gitdir_kib=${G_KIB:-?} alarm_kib=$ALARM_KIB keep_days=$KEEP_DAYS keep_min=$KEEP_MIN"
  if ! is_uint "$G_KIB"; then
    if [ -e "$REPO/.git" ]; then echo "check: cannot measure $REPO/.git"; exit 1; fi
  fi
  if inspect; then
    if plan; then
      estimate_kib || EST_KIB=""
      echo "check: commits=$N keep=$KEEP_N drop=$DROP_N would_cap=yes estimate_kib=${EST_KIB:-?} free_kib=$(free_kib "$REPO")"
    else
      echo "check: commits=$N keep=$KEEP_N drop=$DROP_N would_cap=no status=$STATUS ($WHY)"
    fi
  else
    echo "check: status=$STATUS ($WHY)"
  fi
  if [ -e "$OLDDIR" ] || [ -e "$NEWDIR" ]; then echo "check: LEFTOVER of an interrupted run: $( [ -e "$OLDDIR" ] && echo "$OLDDIR " )$( [ -e "$NEWDIR" ] && echo "$NEWDIR" )"; fi
  if is_uint "$G_KIB" && [ "$G_KIB" -gt "$ALARM_KIB" ]; then echo "check: .git is over the alarm size"; exit 3; fi
  case "$STATUS" in skipped-unreadable) exit 1 ;; esac
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "jsonl-archive-history-cap: jq is required but not found in PATH" >&2; exit 1; }

# ──────────────────────────────── state, alarm ────────────────────────────────
is_bad() { case "$1" in failed-*|rolled-back|conflict|leftover-kept) return 0 ;; esac; return 1; }
state_json() { if [ -f "$STATE" ] && jq -e 'type == "object"' "$STATE" >/dev/null 2>&1; then cat "$STATE"; else echo '{}'; fi; }   # vazio/ilegível → {}: starts fresh, the streak and the alert clock reset
ALARM_ERR=""
send_alarm() {  # send_alarm <why> — 0 only when the mail really went out
  local body out rc
  body="jsonl-archive history cap: $1
repo:    $REPO
.git:    $(fmt "$G_KIB") (alarm at $(fmt "$ALARM_KIB"))
status:  $STATUS${WHY:+ — $WHY}
policy:  this script KEEPS ONLY the last ${KEEP_DAYS} days of history (at least $KEEP_MIN commits) and deletes the rest on purpose (ga-zfy8j4x); nothing restores from it and S3 never had it.
Check:   bash $0 --check ; last lines of $LOG
Leftovers of an interrupted swap, if any: $OLDDIR (the old .git) and $NEWDIR (the new one) — look before deleting either."
  out="$(_bounded "$MAIL_TIMEOUT_S" "$GCBIN" mail send mayor/ -s "ESCALATION: jsonl-archive history cap [HIGH]" -m "$body" 2>&1)"; rc=$?
  ALARM_ERR="$(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-200)"
  return "$rc"
}
finish() {  # finish <status> [why] — records the run, rings the alarm when due, exits with the code the status maps to
  local st="$1" state last streak nowe new rc reason="" grew=0
  STATUS="$st"; [ $# -ge 2 ] && WHY="$2"
  nowe="$(now)"
  [ -e "$REPO/.git" ] && G_KIB="$(gitdir_kib "$REPO/.git")"
  state="$(state_json)"
  last="$(jq -r '.last_alert_epoch // 0' <<<"$state" 2>/dev/null)"; is_uint "$last" || last=0
  streak="$(jq -r '.bad_streak // 0' <<<"$state" 2>/dev/null)"; is_uint "$streak" || streak=0
  if is_bad "$STATUS"; then streak=$((streak + 1)); else streak=0; fi
  if is_bad "$STATUS"; then reason="the run ended $STATUS"; fi
  if is_uint "$G_KIB" && [ "$G_KIB" -gt "$ALARM_KIB" ]; then reason="${reason:+$reason; }the .git is over $(fmt "$ALARM_KIB")"; fi
  if [ -n "$reason" ] && [ $(( nowe - last )) -lt "$ALERT_EVERY_S" ]; then reason=""; fi   # rate limit: the clock is the LAST mail's, recorded below before the send (a send that fails moves it back, see the retry)
  [ -n "$reason" ] && grew=1
  [ "$grew" -eq 1 ] && last="$nowe"
  new="$(jq --arg st "$STATUS" --arg why "$WHY" --argjson now "$nowe" --argjson last "$last" --argjson streak "$streak" --arg g "${G_KIB:-}" --arg n "$N" --arg k "$KEEP_N" \
        'def n($x): (try ($x | tonumber) catch null);
         . + {last_run_epoch:$now, status:$st, why:$why, gitdir_kib:n($g), commits:n($n), kept:n($k), bad_streak:$streak, last_alert_epoch:$last}
         | if $st == "capped" then . + {last_capped_epoch:$now} else . end' <<<"$(state_json)" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e 'type == "object"' <<<"$new" >/dev/null 2>&1; then
    log "state update FAILED: jq rc=$rc — no alarm mail can be rate-limited until the state can be written, so none is sent"; grew=0
  else
    mkdir -p "$(dirname "$STATE")" 2>/dev/null   # benign[state-mkdir]: if the directory cannot be made the write right below fails and is reported
    if ! { printf '%s\n' "$new" > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE" 2>/dev/null; }; then
      log "state update FAILED: could not write $STATE — no alarm mail is sent (it could not be recorded, and an unrecorded mail repeats every run)"; grew=0
      rm -f "$STATE.tmp.$$" 2>/dev/null   # benign[state-tmp]: a leftover temp file after a write already reported as FAILED
    fi
  fi
  log "run end: status=$STATUS${WHY:+ ($WHY)} gitdir=$(fmt "$G_KIB") commits=${N} kept=${KEEP_N} elapsed=$(elapsed)s"
  if [ "$grew" -eq 1 ]; then
    log "ALARM: $reason — mailing mayor/"
    if send_alarm "$reason"; then log "alarm mail sent"; else
      # the mail is the only channel of this alert: a send that FAILED must not silence it for the whole ALERT_EVERY_S — move the recorded clock back so the next try is ALERT_RETRY_S away
      if [ "$ALERT_RETRY_S" -lt "$ALERT_EVERY_S" ]; then last=$(( nowe - ALERT_EVERY_S + ALERT_RETRY_S )); fi
      if new="$(jq --argjson last "$last" '.last_alert_epoch = $last' <<<"$(state_json)" 2>/dev/null)" && jq -e 'type == "object"' <<<"$new" >/dev/null 2>&1 \
         && printf '%s\n' "$new" > "$STATE.tmp.$$" 2>/dev/null && mv "$STATE.tmp.$$" "$STATE" 2>/dev/null; then
        log "alarm mail NOT sent: rc/err: ${ALARM_ERR:-none} (the next try is in ${ALERT_RETRY_S}s)"
      else
        rm -f "$STATE.tmp.$$" 2>/dev/null   # benign[state-tmp]: a leftover temp file after a write already reported below
        log "alarm mail NOT sent: rc/err: ${ALARM_ERR:-none}; the retry clock could NOT be recorded either — the next try is in ${ALERT_EVERY_S}s"
      fi
    fi
  fi
  if is_bad "$STATUS"; then exit 1; fi
  exit 0
}

# ──────────────────────────────── the shared lock (same protocol as jsonl-archive-compact.sh) ────────────────────────────────
lock_owner_alive() { local p; p="$(cat "$LOCK/pid" 2>/dev/null)"; is_uint "$p" && kill -0 "$p" 2>/dev/null; }
lock_within_budget() { local u; u="$(cat "$LOCK/until" 2>/dev/null)"; is_uint "$u" && [ "$(date +%s)" -le $(( u + LOCK_GRACE_S )) ]; }
lock_older_than() {  # 0 older, 1 not older, 2 could not tell
  local o
  o="$(find "$LOCK" -maxdepth 0 -mmin +"$1" 2>/dev/null)" || return 2
  [ -n "$o" ]
}
lock_is_stale() {  # 0 stale (reclaim), 1 a live run's lock, 2 cannot tell
  local old_hung old_dead
  lock_older_than "$LOCK_STALE_MIN"; old_hung=$?
  if [ "$old_hung" -eq 0 ] && ! lock_within_budget; then return 0; fi
  if ! lock_owner_alive; then
    lock_older_than 1; old_dead=$?
    if [ "$old_dead" -eq 0 ]; then return 0; fi
    if [ "$old_dead" -eq 2 ]; then return 2; fi
  fi
  if [ "$old_hung" -eq 2 ]; then return 2; fi
  return 1
}
lock_release() { rm -f "$LOCK/pid" "$LOCK/until" 2>/dev/null; rmdir "$LOCK" 2>/dev/null; [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; }   # benign[lock-release]: the result is the existence test on the last line
HAVE_LOCK=0
take_lock() {  # 0 = held; 10 = another run holds it (in flight); 11 = failure (WHY says which)
  local err st
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null   # benign[lock-parent]: if the parent cannot be made the mkdir below fails and says why
  if ! err="$(mkdir "$LOCK" 2>&1)"; then
    if [ ! -d "$LOCK" ]; then WHY="could not create the lock $LOCK: ${err:-no output}"; return 11; fi
    lock_is_stale; st=$?
    if [ "$st" -eq 1 ]; then WHY="the compaction (or another cap) run holds $LOCK"; return 10; fi
    if [ "$st" -ne 0 ]; then WHY="cannot tell whether the lock $LOCK is stale — a live run and a stale lock look the same from here"; return 11; fi
    log "stale lock (owner gone, or older than ${LOCK_STALE_MIN}m) — reclaiming"
    if ! lock_release; then WHY="could not remove the stale lock $LOCK"; return 11; fi
    if ! err="$(mkdir "$LOCK" 2>&1)"; then
      if [ -d "$LOCK" ]; then WHY="another run took the lock right after the stale one was removed"; return 10; fi
      WHY="could not create the lock after removing a stale one: ${err:-no output}"; return 11
    fi
  fi
  if ! printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null; then lock_release; WHY="could not record this run's pid in $LOCK/pid"; return 11; fi
  printf '%s\n' "$(( $(date +%s) + DEADLINE_S ))" > "$LOCK/until" 2>/dev/null   # benign[lock-until]: without it the lock is judged by age alone (90m), longer than any run of this script
  HAVE_LOCK=1
  return 0
}

# ──────────────────────────────── exit handling ────────────────────────────────
FETCH_PID=""; CONFLICT=0   # 1 = a human decides (swap conflict, or an old dir that does not match): the exit trap keeps both dirs as they are
rm_tree() {  # rm_tree <dir> — only the two directories this script names, never a symlink, never the repo itself
  local d="$1"
  case "$d" in "$NEWDIR"|"$OLDDIR") ;; *) log "rm_tree refuses '$d'"; return 1 ;; esac
  if [ -L "$d" ]; then log "rm_tree refuses the symlink '$d'"; return 1; fi
  [ -d "$d" ] || return 0
  find "$d" -mindepth 1 -delete 2>/dev/null; rmdir "$d" 2>/dev/null   # benign[rm-tree]: the result is whether the directory is gone, tested next
  [ ! -e "$d" ]
}
cleanup_at_exit() {
  trap - EXIT
  [ -n "$FETCH_PID" ] && kill_tree "$FETCH_PID"
  # a crash between the two mv's of the swap: the old repo is the only copy and the repo has no .git — put it back
  if [ -d "$OLDDIR" ] && [ ! -e "$REPO/.git" ] && [ ! -L "$REPO/.git" ] && [ "$CONFLICT" -eq 0 ]; then
    mv "$OLDDIR" "$REPO/.git" 2>/dev/null && log "exit: the swap was interrupted — the old .git is back in place"
  fi
  if [ -d "$NEWDIR" ] && [ "$CONFLICT" -eq 0 ]; then rm_tree "$NEWDIR" || log "WARNING: could not remove the partial $NEWDIR — the next run removes it"; fi
  [ -f "$NEWDIR.fetch.err" ] && [ ! -L "$NEWDIR.fetch.err" ] && rm -f "$NEWDIR.fetch.err" 2>/dev/null   # benign[fetch-err]: the fetch's stderr; its last lines are already in WHY and the log
  [ "$HAVE_LOCK" -eq 1 ] && { lock_release || log "WARNING: could not remove the lock $LOCK at exit — the next run reclaims it once this pid is gone"; }
}
trap 'cleanup_at_exit' EXIT
trap 'exit 143' TERM INT HUP

# ──────────────────────────────── the run ────────────────────────────────
log "run start: repo=$REPO keep_days=$KEEP_DAYS keep_min=$KEEP_MIN pid=$$"
take_lock; lrc=$?
if [ "$lrc" -eq 10 ]; then N=0; KEEP_N=0; finish skipped-lock "$WHY"; fi
if [ "$lrc" -ne 0 ]; then finish failed-lock "$WHY"; fi

# leftovers of an interrupted run (we hold the lock: nobody else is building)
if [ -e "$OLDDIR" ] || [ -L "$OLDDIR" ]; then
  if [ ! -e "$REPO/.git" ] && [ ! -L "$REPO/.git" ]; then
    mv "$OLDDIR" "$REPO/.git" && log "leftover $OLDDIR and no .git: the old repo is back in place (an interrupted swap)" || finish failed-leftover "could not move $OLDDIR back to .git"
  else
    # the old .git of a swap that did not get to delete it: safe to delete only when the live repo is readable and the old head's TREE is content the live repo holds —
    # the live head's tree, or (the exporter commits every 15 min, so by the next run the head has moved) the tree of a commit still in the live history
    # vazio/falhou (rev-parse, log: an unreadable or half-deleted old dir) → "" and same=0: cannot know, both dirs are kept for a human
    lt="$(G rev-parse 'HEAD^{tree}' 2>/dev/null)"
    ot="$("$GITBIN" --git-dir="$OLDDIR" rev-parse 'HEAD^{tree}' 2>/dev/null)"
    same=0
    if [ -n "$lt" ] && [ -n "$ot" ]; then
      if [ "$lt" = "$ot" ]; then same=1
      else
        hist="$(G log --format=%T HEAD 2>/dev/null)" && [ -n "$hist" ] && printf '%s\n' "$hist" | grep -q -x -F -- "$ot" && same=1
      fi
    fi
    if [ "$same" -eq 1 ] && G fsck --connectivity-only --no-dangling >/dev/null 2>&1; then
      log "leftover $OLDDIR holds a head tree the live repo has (its head or a commit in its history) — deleting it"
      rm_tree "$OLDDIR" || finish failed-leftover "could not delete the leftover $OLDDIR"
    else
      CONFLICT=1   # keep both dirs for a human: the exit trap must not remove the new one
      finish leftover-kept "$OLDDIR exists next to a live .git whose history does not hold the old head's tree (or one of them is unreadable) — a human decides which is the repo; no cap until then ($NEWDIR, if there, is kept too)"
    fi
  fi
fi
# the new dir is only ever a copy built from the old repo: removed once the old dir is settled (after a swap conflict it stays, with the old dir, until a human looks)
if [ -d "$NEWDIR" ] || [ -L "$NEWDIR" ]; then
  log "leftover $NEWDIR from an interrupted run — removing it (it was never installed)"
  rm_tree "$NEWDIR" || finish failed-leftover "could not remove the leftover $NEWDIR"
fi

if [ "$(elapsed)" -ge "$DEADLINE_S" ]; then finish failed-deadline "the run had no time left"; fi
G_KIB="$(gitdir_kib "$REPO/.git")"
if ! inspect; then finish "$STATUS" "$WHY"; fi
if ! plan; then finish "$STATUS" "$WHY"; fi
log "plan: $N commits, keep $KEEP_N (since $(date -u -r "$CUTOFF" +%FT%TZ 2>/dev/null || date -u -d "@$CUTOFF" +%FT%TZ 2>/dev/null)), drop $DROP_N; .git $(fmt "$G_KIB")"   # benign[plan-date]: the date only decorates the line (BSD date -r, GNU date -d)

# disk: the new pack must fit with FLOOR_KIB to spare. unreadable → inert.
if ! estimate_kib; then finish skipped-unreadable "cannot size the baseline tree"; fi
FREE="$(free_kib "$REPO")"
if ! is_uint "$FREE"; then finish skipped-low-disk "free space unreadable (df said '${FREE:-nothing}') — inert on doubt"; fi
if [ "$FREE" -lt $(( EST_KIB + FLOOR_KIB )) ]; then
  finish skipped-low-disk "free $(fmt "$FREE") < estimated pack $(fmt "$EST_KIB") + floor $(fmt "$FLOOR_KIB")"
fi

# ---- step 1: re-write the kept commits (oldest first), same tree/author/committer/message, no parent for the oldest
K_OLD=(); K_NEW=()
rewrite_commit() {  # rewrite_commit <old-sha> <new-parent-or-empty> — prints the new sha
  G cat-file commit "$1" | awk -v np="$2" '
    hdr == 0 && /^tree / { print; if (np != "") print "parent " np; next }
    hdr == 0 && /^parent / { next }
    hdr == 0 && /^$/ { hdr = 1 }
    { print }' | G hash-object -t commit -w --stdin
}
is_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]; }
append_chain() {  # append_chain <old-sha>... (oldest first) to K_OLD/K_NEW
  local o parent new
  for o in "$@"; do
    parent=""; [ "${#K_NEW[@]}" -gt 0 ] && parent="${K_NEW[$((${#K_NEW[@]} - 1))]}"
    new="$(rewrite_commit "$o" "$parent")" || return 1
    is_sha "$new" || return 1
    K_OLD[${#K_OLD[@]}]="$o"; K_NEW[${#K_NEW[@]}]="$new"
  done
}
i=$((KEEP_N - 1)); oldest_first=""
while [ "$i" -ge 0 ]; do oldest_first="$oldest_first ${C_SHA[$i]}"; i=$((i - 1)); done
# shellcheck disable=SC2086
append_chain $oldest_first || finish failed-build "could not re-write the kept commits"
log "step 1: ${#K_NEW[@]} commit(s) re-written; new head ${K_NEW[$((${#K_NEW[@]} - 1))]}"

# ---- step 2: fill the new git dir with one fetch, under a disk watch
init_new() {
  local ent
  "$GITBIN" init -q --bare "$NEWDIR" >/dev/null 2>&1 || return 1
  cp "$REPO/.git/config" "$NEWDIR/config" || return 1
  "$GITBIN" --git-dir="$NEWDIR" symbolic-ref HEAD "refs/heads/$BR" || return 1
  if [ -d "$REPO/.git/hooks" ]; then rm -rf "$NEWDIR/hooks" && cp -R "$REPO/.git/hooks" "$NEWDIR/hooks" || return 1; fi
  if [ -d "$REPO/.git/info" ]; then
    mkdir -p "$NEWDIR/info" || return 1
    for ent in exclude attributes; do [ -f "$REPO/.git/info/$ent" ] && { cp "$REPO/.git/info/$ent" "$NEWDIR/info/$ent" || return 1; }; done
  fi
  return 0
}
fetch_head() {  # fetch_head <new-sha> — 0 = fetched; 1 = failed or killed by the watch (WHY says which)
  local sha="$1" ferr rc fr sz blind=0 up
  ferr="$NEWDIR.fetch.err"
  up="$GITBIN -c uploadpack.allowAnySHA1InWant=true -c pack.threads=2 -c pack.windowMemory=256m -c pack.deltaCacheSize=64m upload-pack"
  # -u (--update-head-ok): the new git dir carries the old config (core.bare=false) and HEAD names the branch, so git would refuse to fetch into "the checked-out branch" — there is no work tree here
  _bounded "$FETCH_TIMEOUT_S" "$GITBIN" --git-dir="$NEWDIR" -c fetch.unpackLimit=1 -c transfer.unpackLimit=1 -c pack.threads=2 -c pack.windowMemory=256m -c pack.deltaCacheSize=64m \
    fetch -q -u --no-tags --no-write-fetch-head --upload-pack "$up" "$REPO/.git" "+${sha}:refs/heads/$BR" >"$ferr" 2>&1 &
  FETCH_PID=$!
  while kill -0 "$FETCH_PID" 2>/dev/null; do
    sleep "$POLL_S"
    fr="$(free_kib "$NEWDIR")"; sz="$(gitdir_kib "$NEWDIR")"
    # falhou (df/du unreadable) → the watch is blind this tick; blind for 15 ticks in a row is not "fine", it stops the fetch
    if ! is_uint "$fr" || ! is_uint "$sz"; then
      blind=$((blind + 1))
      if [ "$blind" -ge 15 ]; then kill_tree "$FETCH_PID"; wait "$FETCH_PID" 2>/dev/null; FETCH_PID=""; WHY="the disk watch was blind for 15 ticks (df/du unreadable) — fetch stopped, nothing installed"; return 1; fi
      continue
    fi
    blind=0
    if [ "$fr" -lt "$ABORT_FLOOR_KIB" ]; then
      kill_tree "$FETCH_PID"; wait "$FETCH_PID" 2>/dev/null; FETCH_PID=""
      WHY="free space fell to $(fmt "$fr") (< $(fmt "$ABORT_FLOOR_KIB")) during the fetch — stopped, nothing installed"; return 1
    fi
    if [ "$sz" -gt $(( EST_KIB * 3 + 262144 )) ]; then
      kill_tree "$FETCH_PID"; wait "$FETCH_PID" 2>/dev/null; FETCH_PID=""
      WHY="the new repo reached $(fmt "$sz"), over 3x the estimate $(fmt "$EST_KIB") — stopped, nothing installed"; return 1
    fi
  done
  wait "$FETCH_PID"; rc=$?; FETCH_PID=""
  if [ "$rc" -ne 0 ]; then WHY="fetch rc=$rc: $(tail -n 2 "$ferr" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; return 1; fi
  rm -f "$ferr" 2>/dev/null   # benign[fetch-err]: a diagnostic file of a fetch that succeeded
  return 0
}
init_new || finish failed-build "could not create the new git dir $NEWDIR"
fetch_head "${K_NEW[$((${#K_NEW[@]} - 1))]}" || finish failed-build "$WHY"
log "step 2: fetched; new repo $(fmt "$(gitdir_kib "$NEWDIR")")"

# ---- step 3: catch-up — commits the exporter added while the fetch ran are re-written and fetched too (bounded)
catch_up() {  # 0 = the new chain ends at the live head; 1 = the live head moved and could not be followed (WHY)
  local tries=0 head last add c np
  while :; do
    head="$(G rev-parse HEAD 2>/dev/null)" || { WHY="cannot read the live head"; return 1; }
    last="${K_OLD[$((${#K_OLD[@]} - 1))]}"
    [ "$head" = "$last" ] && return 0
    tries=$((tries + 1))
    if [ "$tries" -gt "$CATCHUP_MAX" ]; then WHY="the live repo kept moving through $CATCHUP_MAX catch-ups"; return 1; fi
    add="$(G rev-list --reverse "$last..$head" 2>/dev/null)" || { WHY="the live head is not a descendant of the one that was re-written"; return 1; }
    [ -n "$add" ] || { WHY="the live head $head is not a descendant of $last"; return 1; }
    for c in $add; do
      np="$(G rev-list --parents -n 1 "$c" 2>/dev/null | wc -w | tr -d ' ')"
      [ "$np" = 2 ] || { WHY="commit $c added meanwhile is not a plain child (parents field count $np)"; return 1; }
    done
    # shellcheck disable=SC2086
    append_chain $add || { WHY="could not re-write the commits added meanwhile"; return 1; }
    fetch_head "${K_NEW[$((${#K_NEW[@]} - 1))]}" || return 1
    log "catch-up $tries: $(printf '%s\n' $add | wc -l | tr -d ' ') commit(s) followed"
  done
}
catch_up || finish failed-build "$WHY"

# ---- the exporter must not be mid-commit when the index is copied and the swap happens
exporter_running() {  # 0 running (or unknown), 1 not running — "cannot tell" counts as running
  local pl
  pl="$(ps -U "$(id -u)" -o pid=,command= 2>/dev/null)" || return 0
  [ -n "$pl" ] || return 0
  printf '%s\n' "$pl" | awk -v me="$$" -v re="$EXPORT_RE" '$1 != me && $0 ~ re { f = 1 } END { exit f ? 0 : 1 }'
}
repacker_running() {  # 0 = another git repacker works in this repo (or unknown), 1 = none — the same ps/lsof rule jsonl-archive-debt-swap.sh uses
  local pl cands pids out real
  real="$(cd "$REPO" 2>/dev/null && pwd -P)" || return 0
  pl="$(ps -U "$(id -u)" -o pid=,command= 2>/dev/null)" || return 0
  cands="$(printf '%s\n' "$pl" | awk -v me="$$" '
    $1 == me { next }
    { g = 0
      for (i = 2; i <= NF; i++) {
        if (!g) { if ($i ~ /(^|\/)git$/) g = 1; continue }
        if ($i ~ /^(maintenance|repack|gc|pack-objects|multi-pack-index|index-pack|prune|prune-packed|commit-graph)$/) { print $1; break }
      }
    }')"
  [ -n "$cands" ] || return 1
  pids="$(printf '%s\n' "$cands" | tr '\n' ',' | sed 's/,$//')"
  command -v lsof >/dev/null 2>&1 || return 0
  out="$(lsof -w -a -d cwd -F n -p "$pids" 2>/dev/null)" || return 0
  printf '%s\n' "$out" | grep -q -E "^n$real(/|$)" && return 0
  return 1
}
waited=0
while exporter_running || repacker_running || [ -e "$REPO/.git/index.lock" ]; do
  if [ "$waited" -ge "$EXPORT_WAIT_S" ] || [ "$(elapsed)" -ge "$DEADLINE_S" ]; then
    finish skipped-busy "the exporter, another repacker or a git lock was still active after ${waited}s — nothing installed, the next run retries"
  fi
  sleep 5; waited=$((waited + 5))
done
catch_up || finish failed-build "$WHY"        # one more: a commit may have landed while we waited

# ---- verify the new repo BEFORE it is installed
verify_new() {  # 0 = the new repo is the old head's twin; 1 = not (WHY)
  local nh cnt a b oargs="" nargs="" j
  nh="$("$GITBIN" --git-dir="$NEWDIR" rev-parse "refs/heads/$BR" 2>/dev/null)" || { WHY="the new repo has no refs/heads/$BR"; return 1; }
  [ "$nh" = "${K_NEW[$((${#K_NEW[@]} - 1))]}" ] || { WHY="the new head $nh is not the re-written head"; return 1; }
  cnt="$("$GITBIN" --git-dir="$NEWDIR" rev-list --count "refs/heads/$BR" 2>/dev/null)" || { WHY="cannot count the new repo's commits"; return 1; }
  [ "$cnt" = "${#K_NEW[@]}" ] || { WHY="the new repo has $cnt commit(s), expected ${#K_NEW[@]}"; return 1; }
  for j in "${!K_OLD[@]}"; do oargs="$oargs ${K_OLD[$j]}^{tree}"; nargs="$nargs ${K_NEW[$j]}^{tree}"; done
  # shellcheck disable=SC2086
  a="$(G rev-parse $oargs 2>/dev/null)" || { WHY="cannot read the old trees"; return 1; }
  # shellcheck disable=SC2086
  b="$("$GITBIN" --git-dir="$NEWDIR" rev-parse $nargs 2>/dev/null)" || { WHY="cannot read the new trees"; return 1; }
  [ -n "$a" ] && [ "$a" = "$b" ] || { WHY="a kept commit's tree differs between the old and the new repo"; return 1; }
  "$GITBIN" --git-dir="$NEWDIR" fsck --connectivity-only --no-dangling >/dev/null 2>&1 || { WHY="fsck --connectivity-only failed on the new repo"; return 1; }
  return 0
}
verify_new || finish failed-verify "$WHY"
log "step 3: the new repo is verified: ${#K_NEW[@]} commit(s), every kept tree identical, connectivity ok"

# the index of the live repo matches its tree now (nothing is committing); the new repo takes it over as it is
check_index || finish "$STATUS" "$WHY"   # again, right before the copy: something may have been staged while the fetch ran
if [ -f "$REPO/.git/index" ]; then cp -p "$REPO/.git/index" "$NEWDIR/index" || finish failed-build "could not copy the index"; fi
if [ "$(elapsed)" -ge "$DEADLINE_S" ]; then finish failed-deadline "the run's budget ended before the swap — nothing installed"; fi

hook() {  # hook <stage> — JHC_HOOK is a test seam: a command run with <stage> <repo> <old dir> at the two points of the swap where a race could land. Unset in production.
  [ -n "${JHC_HOOK:-}" ] || return 0
  "$JHC_HOOK" "$1" "$REPO" "$OLDDIR" || true   # benign[hook]: a test seam; what it did (or failed to do) shows in the checks that follow
}
# ---- step 5: the swap. Two renames back to back; the guard before the second keeps us from nesting into a .git the exporter recreated.
BEFORE_KIB="$G_KIB"
LAST_OLD="${K_OLD[$((${#K_OLD[@]} - 1))]}"
mv "$REPO/.git" "$OLDDIR" || finish failed-swap "could not move the live .git aside — nothing changed"
hook between-mv
if [ -e "$REPO/.git" ] || [ -L "$REPO/.git" ] || ! mv "$NEWDIR" "$REPO/.git"; then
  if [ ! -e "$REPO/.git" ] && [ ! -L "$REPO/.git" ]; then
    mv "$OLDDIR" "$REPO/.git" && finish failed-swap "could not install the new .git — the old one is back"
    CONFLICT=1; finish conflict "could not install the new .git AND could not put the old one back: it is at $OLDDIR — move it to $REPO/.git by hand"
  fi
  CONFLICT=1
  finish conflict "something created $REPO/.git while it was swapped (the exporter?): the old repo is at $OLDDIR and the new one at $NEWDIR — a human decides which is the repo (compare their head trees)"
fi
hook after-swap
undo_swap() {  # puts the old .git back; 0 = done
  mv "$REPO/.git" "$NEWDIR" && mv "$OLDDIR" "$REPO/.git"
}
post_ok=1
nt="$(G rev-parse 'HEAD^{tree}' 2>/dev/null)"; ot="$("$GITBIN" --git-dir="$OLDDIR" rev-parse "${LAST_OLD}^{tree}" 2>/dev/null)"
[ -n "$nt" ] && [ "$nt" = "$ot" ] || post_ok=0
[ "$(G rev-list --count HEAD 2>/dev/null)" = "${#K_NEW[@]}" ] || post_ok=0
oh="$("$GITBIN" --git-dir="$OLDDIR" rev-parse "refs/heads/$BR" 2>/dev/null)"
[ "$oh" = "$LAST_OLD" ] || post_ok=0       # a commit landed in the old repo during the gap: it is not in the new one
if [ "$post_ok" -ne 1 ]; then
  if undo_swap; then finish rolled-back "the new .git did not pass the check right after the swap (head tree / count / a commit landed in the gap) — the old one is back in place"; fi
  CONFLICT=1
  finish conflict "the new .git failed its post-swap check AND the undo failed: the old repo is at $OLDDIR, the new one is the live .git (or $NEWDIR) — a human decides"
fi
log "step 5: swapped; the live .git is the new repo"

# ---- step 6: the old .git goes
if ! rm_tree "$OLDDIR"; then finish failed-cleanup "the cap is installed but the old .git at $OLDDIR could not be deleted — the next run deletes it if it still reads as a repo whose head tree the live history holds; if the delete got half-way and it no longer reads, that run ends leftover-kept and a human removes the directory"; fi
log "step 6: the old .git is deleted (was $(fmt "$BEFORE_KIB"))"
finish capped "dropped $DROP_N of $N commits; .git $(fmt "$BEFORE_KIB") -> $(fmt "$(gitdir_kib "$REPO/.git")")"
