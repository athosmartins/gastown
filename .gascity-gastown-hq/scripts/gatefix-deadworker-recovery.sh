#!/usr/bin/env bash
# gatefix-deadworker-recovery.sh — auto-recover gate:needs-fix beads whose worker DIED.
#
# PROBLEM (ga-pdrij sub-scope C, observed 2026-06-30 on wa-85iv8 + wa-5otq4): a worker
# dispatched for the autonomous gate-fix loop (gate:needs-fix) can DIE/drain mid-fix,
# leaving an orphan per-bead worktree (crew/worker-<bead> or /gt/worker-<bead>) plus a
# stale claim (gc.session_name/work_dir) on the bead. The orphan worktree + stale claim
# then BLOCK the Pilot from re-dispatching the bead — it sits gate:needs-fix forever (the
# worktree-reaper only reaps CLEAN worktrees >24h, so a dirty-from-dead one is skipped
# indefinitely). This janitor automates that recovery within one sweep.
#
# WHAT IT DOES: for each gate:needs-fix bead that is NOT story:in-flight, whose recorded
# worker session (gc.session_name) is PROVEN DEAD (see below), salvage then reap its orphan
# worktree (path-scoped — never touches any branch ref) + clear its stale claim metadata so
# the next Pilot sweep re-dispatches it fresh. A bead whose worker is alive, resumable, or
# merely not provably dead (or has no recorded session) is LEFT untouched.
#
# "DEAD" IS A PROOF, NOT AN ABSENCE (ga-fnmo63, 2026-10-01): this janitor used to call a worker
# dead when it was missing from the roster's "live" set — and that set excluded asleep/drained
# sessions. A pool worker that drains or sleeps RESUMES in the same worktree, so the janitor
# force-removed worker-ps-6cgb twice while its worker was alive, taking uncommitted edits with
# it (log: 499 worktree_reaped events, unknown how many were dirty). Death now needs ALL of:
#   1. not in `gc session list` in ANY state (asleep/drained are alive — they resume);
#   2. every session bead for that name is status=closed — the reconciler's own verdict
#      (`bd list --include-infra`: pool-worker session beads are wisps and `bd list` hides
#      them without it; "found nothing" is NOT "closed");
#   3. no tmux session of that name on the city socket (tmux -L gascity);
#   4. the worktree itself unwritten for GATEFIX_RECOVERY_IDLE_MIN minutes.
# Every source has three answers — yes / no / cannot tell — and "cannot tell" is inert.
#
# SALVAGE BEFORE REMOVAL (ga-fnmo63): `git worktree remove --force` discards uncommitted and
# untracked work. A worktree holding uncommitted changes, or commits that exist on no remote,
# is first snapshotted to refs/recovery/<bead>/<ts> (a WIP commit on top of HEAD built from a
# temporary index — no branch, index or file of the worktree is touched) and pushed to origin
# (a repo with no origin keeps the local ref only, and the log says "pushed":false).
# Only after that succeeds is the worktree removed. If the snapshot cannot be made or pushed
# (or is bigger than GATEFIX_RECOVERY_SALVAGE_MAX_MB), NOTHING is removed and the claim is NOT
# cleared: the bead stays as it was, a recovery_deferred event is logged and the operator is
# notified (throttled). The ref is recorded in the log and as a comment on the bead.
#
# NO BRANCH DELETION (ga-0re8j, 2026-07-17): this janitor used to also delete
# crew/*/<bead> branches (local + remote) on the theory that a gate:needs-fix branch is
# disposable "failed gate work". That premise was false, and the glob was worse than
# imprecise: refs/heads/crew/*/<bead> requires exactly two path segments (git ref globs
# never cross `/`), so it could ONLY match the crew's own crew/<owner>/<bead> PRIMARY
# submission branch — the gatefix-worker worktree at crew/worker-<bead> checks out that
# SAME ref, so there was never a distinct disposable branch to target. gate:needs-fix
# means the crew will keep fixing THIS branch, not abandon it. Result: 73 remote branch
# deletions over 17 days, 100% of them primary branches, zero permanent loss only by
# luck (objects not yet git-gc'd). Recovery never needed the branch gone — clearing the
# stale claim below is sufficient for the Pilot to re-dispatch. Do not re-add branch
# deletion here.
#
# SAFETY: only acts on gate:needs-fix beads with a PROVEN-dead worker. DRY_RUN default-off
# but easily toggled (would_recover is only logged for proven-dead workers); kill-switch
# GATEFIX_RECOVERY_ENABLED=0; per-sweep cap. Lib-only seam (GATEFIX_RECOVERY_LIB_ONLY=1)
# exposes the pure decision for the selftest.
set -uo pipefail

GT="${GATEFIX_RECOVERY_GT:-/Users/athos/gt}"
HQ="$GT/.gascity-gastown-hq"
LOG="${GATEFIX_RECOVERY_LOG:-$HQ/.gc/logs/gatefix-deadworker-recovery.jsonl}"
ENABLED="${GATEFIX_RECOVERY_ENABLED:-1}"
DRY_RUN="${GATEFIX_RECOVERY_DRY_RUN:-0}"
MAX_PER_SWEEP="${GATEFIX_RECOVERY_MAX_PER_SWEEP:-10}"
case "$MAX_PER_SWEEP" in ''|*[!0-9]*) MAX_PER_SWEEP=10 ;; esac
# a worktree written to within this many minutes is not an orphan (0 disables the gate)
IDLE_MIN="${GATEFIX_RECOVERY_IDLE_MIN:-30}"
case "$IDLE_MIN" in ''|*[!0-9]*) IDLE_MIN=30 ;; esac
# largest uncommitted payload the salvage will snapshot; bigger = defer, never delete
SALVAGE_MAX_MB="${GATEFIX_RECOVERY_SALVAGE_MAX_MB:-50}"
case "$SALVAGE_MAX_MB" in ''|*[!0-9]*) SALVAGE_MAX_MB=50 ;; esac
TMUX_SOCKET="${GATEFIX_RECOVERY_TMUX_SOCKET:-gascity}"   # the city's tmux server: tmux -L gascity
NOTIFY="${GATEFIX_RECOVERY_NOTIFY:-/Users/athos/.local/bin/notify}"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
notify_fail() { "$NOTIFY" -t "Gatefix Deadworker Recovery" -p 4 "🚨 $*" 2>/dev/null || true; }

# ── PURE DECISION (selftest-sourceable) ───────────────────────────────────────
# gatefix_recovery_decide <has_needs_fix 0|1> <in_flight 0|1> <session_name> <live_set> \
#                         <session_proof> <tmux_proof>
#   live_set      = space-delimited identifiers of every session in the roster, ANY state.
#   session_proof = closed | open | none | unknown   (gatefix_session_proof)
#   tmux_proof    = absent | present | unknown       (gatefix_tmux_proof)
# Echoes: "recover" | "skip:<reason>". A bead is recovered ONLY when it has gate:needs-fix,
# is NOT in-flight, has a NON-EMPTY recorded worker, that worker is NOT in the roster, every
# session bead for it is CLOSED and no tmux session of that name exists. A proof that is
# missing, unreadable or inconclusive is "unknown" and skips — absence is not death.
gatefix_recovery_decide() {
  local needs_fix="$1" in_flight="$2" sess="$3" live="$4" proof="${5:-unknown}" tmux_proof="${6:-unknown}"
  [ "$needs_fix" = "1" ] || { echo "skip:not-needs-fix"; return 0; }
  [ "$in_flight" = "0" ] || { echo "skip:in-flight-active-rework"; return 0; }
  [ -n "$sess" ] || { echo "skip:no-recorded-worker"; return 0; }   # can't prove dead → leave
  case " $live " in *" $sess "*) echo "skip:worker-still-live"; return 0 ;; esac
  case "$proof" in
    closed) ;;
    open)   echo "skip:session-bead-open"; return 0 ;;        # resumable — a drained/asleep worker wakes up
    none)   echo "skip:session-bead-not-found"; return 0 ;;   # nothing says it is dead
    *)      echo "skip:session-proof-unknown"; return 0 ;;
  esac
  case "$tmux_proof" in
    absent)  ;;
    present) echo "skip:tmux-session-present"; return 0 ;;
    *)       echo "skip:tmux-unknown"; return 0 ;;
  esac
  echo "recover"
}

# Lib-only: stop before the live sweep so the selftest can source the pure function.
[ "${GATEFIX_RECOVERY_LIB_ONLY:-0}" = "1" ] && return 0 2>/dev/null

command -v gc >/dev/null 2>&1 || { printf '{"ts":"%s","event":"noop","reason":"no_gc"}\n' "$(ts)" >> "$LOG" 2>/dev/null; notify_fail "gatefix-deadworker-recovery: comando 'gc' nao encontrado no PATH — recuperacao de worker morto parada"; exit 0; }
command -v bd >/dev/null 2>&1 || { printf '{"ts":"%s","event":"noop","reason":"no_bd"}\n' "$(ts)" >> "$LOG" 2>/dev/null; notify_fail "gatefix-deadworker-recovery: comando 'bd' nao encontrado no PATH — recuperacao de worker morto parada"; exit 0; }

# ── session identifiers present in the roster, in ANY state ───────────────────
# asleep/drained sessions are NOT dead — they resume in the same worktree (ga-fnmo63). The
# roster is only the cheap first filter; death is decided by gatefix_session_proof below.
LIVE_SESSIONS="$(gc session list --json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit()
sess = d.get("sessions", d) if isinstance(d, dict) else d
out = set()
for s in (sess or []):
    for k in ("session_name","name","alias","id","agent_name"):
        v = s.get(k)
        if v: out.add(str(v))
print(" ".join(sorted(out)))
' 2>/dev/null)"
# FAIL-SAFE: if we could not read the roster, do NOT reap anything (can't prove dead).
[ -n "$LIVE_SESSIONS" ] || { printf '{"ts":"%s","event":"noop","reason":"empty_roster_failsafe"}\n' "$(ts)" >> "$LOG" 2>/dev/null; exit 0; }

# ── proofs of death (ga-fnmo63) — each answers yes / no / cannot-tell ─────────

# gatefix_session_proof <session_name> → closed | open | none | unknown
#   closed  = at least one session bead exists and ALL are status=closed (reconciler's verdict)
#   open    = some session bead for that name is not closed → alive or resumable
#   none    = the lookup worked and found no session bead  → NOT proof of anything
#   unknown = the lookup failed or its output was unreadable
# --include-infra is load-bearing: pool-worker session beads are wisps and plain `bd list`
# never returns them, so without it a live worker looks like "no such session".
gatefix_session_proof() {
  local name="$1" out
  out="$(bd -C "$HQ" list --include-infra --metadata-field "session_name=$name" --all --limit 0 --json 2>/dev/null)" || { echo unknown; return 0; }
  printf '%s' "$out" | python3 -c '
import sys, json
name = sys.argv[1]
try: b = json.loads(sys.stdin.read(), strict=False)
except Exception: print("unknown"); sys.exit()
if not isinstance(b, list): print("unknown"); sys.exit()
if not b: print("none"); sys.exit()
# only rows that really are THIS session count: a lookup that ignored its filter (or answered
# about someone else) must not be able to vouch "closed" for the worker we are asking about
mine = [x for x in b if isinstance(x, dict) and (x.get("metadata") or {}).get("session_name") == name]
if not mine: print("unknown"); sys.exit()
print("open" if any(str(x.get("status", "")).lower() != "closed" for x in mine) else "closed")
' "$name" 2>/dev/null || echo unknown
}

# gatefix_tmux_proof <session_name> → present | absent | unknown
# rc 0 = the session is running; rc 1 + "can't find session" = the server answered and there
# is no such session; ANYTHING else (no tmux, socket unreachable...) = cannot tell.
gatefix_tmux_proof() {
  local name="$1" err rc
  command -v tmux >/dev/null 2>&1 || { echo unknown; return 0; }
  err="$(tmux -L "$TMUX_SOCKET" has-session -t "=$name" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then echo present
  elif [ "$rc" -eq 1 ] && printf '%s' "$err" | grep -q "can't find session"; then echo absent
  else echo unknown; fi
}

# gatefix_worktree_idle <worktree> — 0 only if nothing in it (and neither its index nor HEAD)
# was written within IDLE_MIN minutes. A worktree we cannot read is NOT idle.
gatefix_worktree_idle() {
  local wt="$1" hit gd f
  [ -d "$wt" ] && [ -r "$wt" ] || return 1
  # find's own exit status decides "could not look" (unreadable subdir...) — an empty result
  # from a find that failed must not read as "nothing was written"
  hit="$(find "$wt" \( -name .git -o -name node_modules -o -name .venv \) -prune -o -type f -mmin "-$IDLE_MIN" -print 2>/dev/null)" || return 1
  [ -z "$hit" ] || return 1
  gd="$(git -C "$wt" rev-parse --git-dir 2>/dev/null)" || return 1
  case "$gd" in /*) ;; *) gd="$wt/$gd" ;; esac
  for f in index HEAD; do
    [ -e "$gd/$f" ] || continue
    hit="$(find "$gd/$f" -mmin "-$IDLE_MIN" -print 2>/dev/null)" || return 1
    [ -z "$hit" ] || return 1
  done
  return 0
}

# gatefix_same_repo <repo> <worktree> — 0 if <worktree> is a worktree of <repo> (compared on
# resolved common git dirs, so /var vs /private/var and symlinks cannot cause a mismatch).
gatefix_same_repo() {
  local a b
  a="$(cd "$1" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  b="$(cd "$2" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

# gatefix_worktree_needs_salvage <worktree> — 0 = has uncommitted/untracked work or commits on
# no remote; 1 = nothing would be lost; 2 = cannot tell (callers treat 2 like 0, never like 1).
gatefix_worktree_needs_salvage() {
  local wt="$1" st ahead
  st="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" || return 2
  [ -z "$st" ] || return 0
  ahead="$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null)" || return 2
  case "$ahead" in ''|*[!0-9]*) return 2 ;; esac
  [ "$ahead" = "0" ] && return 1
  return 0
}

# gatefix_dirty_bytes <worktree> — total size of changed + untracked files (stdout). Computed
# BEFORE anything is hashed, so a multi-GB scrape dump is refused instead of stored.
gatefix_dirty_bytes() {
  # git runs INSIDE python so a failed `git status` is a failure (no output, non-zero exit),
  # never "0 bytes of dirt"; the caller treats anything but a number as "cannot tell → defer"
  python3 - "$1" <<'PYEOF' 2>/dev/null
import sys, os, subprocess
wt = sys.argv[1]
r = subprocess.run(["git", "-C", wt, "status", "--porcelain", "-z", "--untracked-files=all"],
                   capture_output=True)
if r.returncode != 0:
    sys.exit(1)
toks = r.stdout.split(b"\0")
tot = 0; i = 0
while i < len(toks):
    e = toks[i]; i += 1
    if len(e) < 4: continue
    if e[:1] in (b"R", b"C"): i += 1          # rename/copy carries the origin path next
    try: tot += os.lstat(os.path.join(wt, e[3:].decode("utf-8", "surrogateescape"))).st_size
    except OSError: pass                      # a path git lists but that is gone is not dirt
print(tot)
PYEOF
}

# gatefix_salvage_worktree <repo> <worktree> <bead> — snapshot the worktree's state to
# refs/recovery/<bead>/<ts> and push it. stdout on success: "<ref>\t<pushed true|false>".
# Non-zero = NOT salvaged (caller must not remove anything). Never touches the worktree's
# files, index or HEAD, and never moves a branch: the snapshot is built from a throwaway index.
gatefix_salvage_worktree() {
  local repo="$1" wt="$2" bid="$3" tmp idx parent tree commit ref bytes pushed=false rc=0
  bytes="$(gatefix_dirty_bytes "$wt")"
  case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bytes" -le $((SALVAGE_MAX_MB * 1048576)) ] || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/gatefix-salvage.XXXXXX")" || return 1
  idx="$tmp/index"
  ref="refs/recovery/$bid/$(date -u +%Y%m%dT%H%M%SZ)"
  git check-ref-format "$ref" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    if git -C "$wt" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      parent="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || rc=1
      [ "$rc" -eq 0 ] && { GIT_INDEX_FILE="$idx" git -C "$wt" read-tree HEAD >/dev/null 2>&1 || rc=1; }
    else parent=""; fi
  fi
  if [ "$rc" -eq 0 ]; then
    GIT_INDEX_FILE="$idx" git -C "$wt" add -A -- . >/dev/null 2>&1 || rc=1      # honors .gitignore
    tree="$(GIT_INDEX_FILE="$idx" git -C "$wt" write-tree 2>/dev/null)" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -n "$parent" ] && [ "$tree" = "$(git -C "$wt" rev-parse 'HEAD^{tree}' 2>/dev/null)" ]; then
      commit="$parent"            # clean tree: only unpushed commits to protect — keep them as-is
    elif [ -n "$parent" ]; then
      commit="$(printf '%s\n' "WIP salvage of $bid ($wt) — gatefix-deadworker-recovery, ga-fnmo63" \
        | GIT_AUTHOR_NAME=gatefix-recovery GIT_AUTHOR_EMAIL=gatefix-recovery@localhost \
          GIT_COMMITTER_NAME=gatefix-recovery GIT_COMMITTER_EMAIL=gatefix-recovery@localhost \
          git -C "$wt" commit-tree "$tree" -p "$parent" 2>/dev/null)" || rc=1
    else
      commit="$(printf '%s\n' "WIP salvage of $bid ($wt) — gatefix-deadworker-recovery, ga-fnmo63" \
        | GIT_AUTHOR_NAME=gatefix-recovery GIT_AUTHOR_EMAIL=gatefix-recovery@localhost \
          GIT_COMMITTER_NAME=gatefix-recovery GIT_COMMITTER_EMAIL=gatefix-recovery@localhost \
          git -C "$wt" commit-tree "$tree" 2>/dev/null)" || rc=1
    fi
  fi
  [ "$rc" -eq 0 ] && [ -n "${commit:-}" ] || rc=1
  [ "$rc" -eq 0 ] && { git -C "$repo" update-ref "$ref" "$commit" 2>/dev/null || rc=1; }
  if [ "$rc" -eq 0 ] && git -C "$repo" remote 2>/dev/null | grep -qx origin; then
    if command -v timeout >/dev/null 2>&1; then
      GIT_TERMINAL_PROMPT=0 timeout 120 git -C "$repo" push -q origin "$ref:$ref" >/dev/null 2>&1 || rc=1
    else
      GIT_TERMINAL_PROMPT=0 git -C "$repo" push -q origin "$ref:$ref" >/dev/null 2>&1 || rc=1
    fi
    [ "$rc" -eq 0 ] && pushed=true
  fi
  # a salvage that did not complete leaves no ref behind — the worktree is still there, and
  # retrying every sweep must not pile up half-made refs
  [ "$rc" -ne 0 ] && git -C "$repo" update-ref -d "$ref" >/dev/null 2>&1
  rm -rf "$tmp"
  [ "$rc" -eq 0 ] || return 1
  printf '%s\t%s\n' "$ref" "$pushed"
}

# deferred-recovery notice, at most once per hour (a stuck salvage must be heard, not spammed)
notify_deferred() {
  local stamp="$LOG.deferred-notify"
  if [ -e "$stamp" ] && [ -n "$(find "$stamp" -mmin -60 -print 2>/dev/null)" ]; then return 0; fi
  : > "$stamp" 2>/dev/null
  notify_fail "gatefix-deadworker-recovery: $1 NOT recovered ($2) — worktree and claim left untouched so no work is lost (ga-fnmo63)"
}

# ── rig repos (where the orphan worktrees live) ───────────────────────────────
RIGS="$(gc --city "$HQ" rig list --json 2>/dev/null | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
for r in d.get("rigs",[]):
    p=r.get("path")
    if p: print(p)
' 2>/dev/null)"
STORES="$HQ
$RIGS"

recovered=0; skipped=0; cap_hit=0; deferred=0
REAP_BLOCKED=0; REAP_BLOCK_REASON=""   # set by reap_orphans when it refused to remove something

# reap_orphans <rig_repo> <bead_id> <store> — salvage, then remove, the per-bead worktree.
# Never fatal. Does NOT touch any branch ref (see NO BRANCH DELETION in the file header).
# A worktree is removed only if it belongs to <rig_repo>, has been idle, and either held no
# work that could be lost or had that work snapshotted (see SALVAGE in the file header).
# Otherwise it sets REAP_BLOCKED=1 and leaves everything exactly as it found it.
reap_orphans() {
  local repo="$1" bid="$2" store="$3" wt rc salv ref pushed
  command -v git >/dev/null 2>&1 || return 0
  # candidate worktree paths — directory-scoped; removing a worktree never deletes the
  # branch ref it had checked out
  for wt in "$repo/crew/worker-$bid" "$GT/worker-$bid"; do
    [ -d "$wt" ] || continue
    gatefix_same_repo "$repo" "$wt" || continue     # not this repo's worktree: not ours to touch
    if ! gatefix_worktree_idle "$wt"; then
      REAP_BLOCKED=1; REAP_BLOCK_REASON="worktree-not-idle"
      printf '{"ts":"%s","event":"reap_blocked","bead":"%s","wt":"%s","reason":"worktree_not_provably_idle","idle_min":%s}\n' "$(ts)" "$bid" "$wt" "$IDLE_MIN" >> "$LOG" 2>/dev/null
      continue
    fi
    ref=""; pushed=""
    gatefix_worktree_needs_salvage "$wt"; rc=$?
    if [ "$rc" -ne 1 ]; then       # 0 = work to protect, 2 = cannot tell → both salvage first
      if salv="$(gatefix_salvage_worktree "$repo" "$wt" "$bid")"; then
        ref="${salv%%$'\t'*}"; pushed="${salv##*$'\t'}"
        printf '{"ts":"%s","event":"worktree_salvaged","bead":"%s","wt":"%s","ref":"%s","pushed":%s}\n' "$(ts)" "$bid" "$wt" "$ref" "$pushed" >> "$LOG" 2>/dev/null
        bd -C "$store" comment "$bid" "gatefix-deadworker-recovery: the dead worker's worktree held uncommitted work or unpushed commits. It was saved to git ref $ref (pushed to origin: $pushed) before the worktree was removed. Recover with: git fetch origin $ref && git checkout FETCH_HEAD (or: git checkout $ref in $repo)." >/dev/null 2>&1 || true
      else
        REAP_BLOCKED=1; REAP_BLOCK_REASON="salvage-failed-or-too-large"
        printf '{"ts":"%s","event":"reap_blocked","bead":"%s","wt":"%s","reason":"salvage_failed_or_over_%smb"}\n' "$(ts)" "$bid" "$wt" "$SALVAGE_MAX_MB" >> "$LOG" 2>/dev/null
        continue
      fi
    fi
    if git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
      if [ -n "$ref" ]; then
        printf '{"ts":"%s","event":"worktree_reaped","repo":"%s","bead":"%s","wt":"%s","salvage_ref":"%s"}\n' "$(ts)" "$(basename "$repo")" "$bid" "$wt" "$ref" >> "$LOG" 2>/dev/null
      else
        printf '{"ts":"%s","event":"worktree_reaped","repo":"%s","bead":"%s","wt":"%s"}\n' "$(ts)" "$(basename "$repo")" "$bid" "$wt" >> "$LOG" 2>/dev/null
      fi
    else
      # e.g. a locked worktree. The claim is still cleared below (unchanged behaviour), but the
      # orphan is still on disk and the log must say so rather than imply a clean recovery.
      printf '{"ts":"%s","event":"reap_failed","bead":"%s","wt":"%s","salvage_ref":"%s"}\n' "$(ts)" "$bid" "$wt" "$ref" >> "$LOG" 2>/dev/null
    fi
  done
  git -C "$repo" worktree prune 2>/dev/null || true
}

while IFS= read -r store; do
  [ -n "$store" ] && [ -d "$store" ] || continue
  beads="$(bd -C "$store" list -l "gate:needs-fix" --json 2>/dev/null || echo '[]')"
  ids="$(printf '%s' "$beads" | python3 -c '
import sys, json
try: b = json.loads(sys.stdin.read(), strict=False)
except Exception: b = []
for x in b:
    labs = x.get("labels", [])
    inflight = "1" if "story:in-flight" in labs else "0"
    sess = (x.get("metadata", {}) or {}).get("gc.session_name", "") or ""
    print("%s\t%s\t%s" % (x.get("id",""), inflight, sess))
' 2>/dev/null)"
  while IFS=$'\t' read -r bid inflight sess; do
    [ -n "$bid" ] || continue
    # PROOF OF DEATH (ga-fnmo63) — only looked up for beads that survive the cheap filters
    # (not in-flight, has a recorded worker, not in the roster); anything else stays "unknown".
    proof=unknown; tmux_proof=unknown
    if [ "$inflight" = "0" ] && [ -n "$sess" ]; then
      case " $LIVE_SESSIONS " in
        *" $sess "*) ;;
        *) proof="$(gatefix_session_proof "$sess")"
           [ "$proof" = "closed" ] && tmux_proof="$(gatefix_tmux_proof "$sess")" ;;
      esac
    fi
    decision="$(gatefix_recovery_decide 1 "$inflight" "$sess" "$LIVE_SESSIONS" "$proof" "$tmux_proof")"
    if [ "$decision" != "recover" ]; then
      skipped=$((skipped+1))
      case "$decision" in    # leave evidence for every worker we declined to call dead
        skip:session-*|skip:tmux-*)
          printf '{"ts":"%s","event":"skip_unproven","store":"%s","bead":"%s","worker":"%s","reason":"%s"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" "${decision#skip:}" >> "$LOG" 2>/dev/null ;;
      esac
      continue
    fi
    if [ "$recovered" -ge "$MAX_PER_SWEEP" ] 2>/dev/null; then
      [ "$cap_hit" = "0" ] && { cap_hit=1; printf '{"ts":"%s","event":"cap_hit","cap":%s}\n' "$(ts)" "$MAX_PER_SWEEP" >> "$LOG" 2>/dev/null; }
      continue
    fi
    if [ "$ENABLED" != "1" ] || [ "$DRY_RUN" = "1" ]; then
      printf '{"ts":"%s","event":"would_recover","store":"%s","bead":"%s","dead_worker":"%s"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" >> "$LOG" 2>/dev/null
      recovered=$((recovered+1)); continue
    fi
    # reap orphans in EVERY rig repo (the worktree could be in any)
    REAP_BLOCKED=0; REAP_BLOCK_REASON=""
    while IFS= read -r rig; do [ -n "$rig" ] && [ -d "$rig" ] && reap_orphans "$rig" "$bid" "$store"; done <<< "$RIGS"
    reap_orphans "$GT" "$bid" "$store"
    # a worktree we would not (or could not safely) remove defers the WHOLE recovery: clearing
    # the claim while the orphan stays would only get the Pilot to dispatch onto a dirty tree
    if [ "$REAP_BLOCKED" = "1" ]; then
      deferred=$((deferred+1))
      printf '{"ts":"%s","event":"recovery_deferred","store":"%s","bead":"%s","dead_worker":"%s","reason":"%s"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" "$REAP_BLOCK_REASON" >> "$LOG" 2>/dev/null
      case "$REAP_BLOCK_REASON" in worktree-not-idle) ;; *) notify_deferred "$bid" "$REAP_BLOCK_REASON" ;; esac
      continue
    fi
    # clear the DEAD worker's stale claim so the bead is a clean re-dispatch candidate
    # (orphan branch/worktree alone is not enough — the stale gc.session_name/work_dir +
    # any assignee left by the dead worker keep it looking "claimed"; wa-85iv8 only
    # re-dispatched + went on to PASS once its claim was also cleared, 2026-06-30).
    bd -C "$store" update "$bid" --unset-metadata "gc.session_name" -q 2>/dev/null || true
    bd -C "$store" update "$bid" --unset-metadata "gc.work_dir"     -q 2>/dev/null || true
    bd -C "$store" update "$bid" --unset-metadata "pilot.sling_bead" -q 2>/dev/null || true
    # only unassign if the assignee IS the dead worker (never touch a live owner)
    _cur_asg="$(bd -C "$store" show "$bid" --json 2>/dev/null | python3 -c 'import sys,json
try:
 d=json.loads(sys.stdin.read(),strict=False); d=d[0] if isinstance(d,list) else d
 print(d.get("assignee") or "")
except: print("")' 2>/dev/null)"
    if [ -n "$_cur_asg" ] && [ "$_cur_asg" = "$sess" ]; then
      bd -C "$store" assign "$bid" "" -q 2>/dev/null || true
    fi
    printf '{"ts":"%s","event":"recovered","store":"%s","bead":"%s","dead_worker":"%s","note":"orphans+claim cleared → re-dispatchable"}\n' "$(ts)" "$(basename "$store")" "$bid" "$sess" >> "$LOG" 2>/dev/null
    recovered=$((recovered+1))
  done <<< "$ids"
done <<< "$STORES"

printf '{"ts":"%s","event":"sweep","recovered":%s,"skipped":%s,"deferred":%s,"dry_run":%s}\n' "$(ts)" "$recovered" "$skipped" "$deferred" "$DRY_RUN" >> "$LOG" 2>/dev/null
exit 0
