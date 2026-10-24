#!/usr/bin/env bash
# wa-root-main-guard.sh — STOPGAP: keep the whatsapp_automation PRODUCTION root on `main`.
#
# WHY: /Users/athos/gt/whatsapp_automation is the production root — the live daemons
# run FROM it, so it MUST stay on `main`. A recurring bug (crews slung wa- beads build
# IN the rig root and `/crew-commit` branches it in-place) keeps checking it out onto
# crew branches (twice on 2026-06-14: crew/...claude-5/wa-tnl5, crew/...claude-1/wa-tdx5).
# Until the real fix lands (crew-commit / Pilot worktree isolation — separate work) the
# Mayor hand-restores it each time. This guard automates that restore + alerts.
#
# WHAT: every interval, read the root's current branch. If it's `main` → silent exit 0.
# If it's a crew branch → back up the divergent HEAD to a tag (so in-progress crew work
# is NEVER lost — recoverable), then run the EXACT restore recipe the Mayor uses by hand
# (stash daemon syncs, switch main, fetch, ff-only merge, drop stash), then log + notify.
# Daemons likely need a RESTART afterwards — this guard does NOT restart them (oracle's job).
#
# DETACHED HEAD (ga-a7mti1). Since 10/10 the live clone sits on a detached HEAD at origin/main (the updater merges
# origin/main onto it), so "no branch name" is the HEALTHY state: the old WARN fired every cycle (10161 lines in
# October) and hid the one case that matters, a HEAD on code origin/main does not contain. A detached HEAD is now
# classified against the local origin/main ref (as of the last fetch; this guard does not fetch):
#   on-main   HEAD is reachable from origin/main → silent: no line, no notify; an open episode is cleared
#   off-main  HEAD is NOT reachable → unreviewed code is live → OFF-MAIN-DETACHED
#   unknown   cannot tell (origin/main missing, HEAD unreadable, merge-base failed) → UNKNOWN-DETACHED, never "healthy"
# off-main/unknown alert (one log line + one notify) on the 2nd consecutive cycle (WA_ROOT_GUARD_CONFIRM_CYCLES), so a
# 19 s reviewer detour is not an alert, then once per WA_ROOT_GUARD_ALARM_WINDOW_MIN (60), not per cycle. The episode is
# kept in $CITY/.gc/wa-root-main-guard.state; when that cannot be written the alert fires at once, because a confirmation
# that can never be remembered would never come. The detached cases are DETECTION ONLY: a restore cannot tell a forgotten
# checkout from a deliberate one (a reviewer reading the files would suddenly read main's), so only a named non-main
# branch is still backed up and restored below. Test seams (selftest only): WA_ROOT_GUARD_{ROOT,CITY,HOOKS,NOW}.
#
# SAFETY: conservative. Never `git checkout -f` / `reset --hard`. If the root is in a
# genuine merge-conflict / dirty-unswitchable state or the switch fails, do NOT force —
# log + notify "needs human" and LEAVE it untouched.
#
# STOPGAP: this masks the bug, it does not fix it. Remove once crew-commit / Pilot
# worktree isolation lands. Committed under scripts/ since ga-qb6yg (before that it ran live with no commit).
#
# Kill switch: WA_ROOT_GUARD_ENABLED=0 → check + log only, never restore.
set -uo pipefail

CITY="${WA_ROOT_GUARD_CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ROOT="${WA_ROOT_GUARD_ROOT:-/Users/athos/gt/whatsapp_automation}"
LOG="$CITY/.gc/logs/wa-root-main-guard.log"
STATE="$CITY/.gc/wa-root-main-guard.state"   # the open detached episode: kind count first_epoch last_alarm_epoch
ENABLED="${WA_ROOT_GUARD_ENABLED:-1}"
HOOKS="${WA_ROOT_GUARD_HOOKS:-/tmp/empty-hooks}"   # bypass any in-root hooks that could block the switch/merge
CONFIRM="${WA_ROOT_GUARD_CONFIRM_CYCLES:-2}"
WINDOW_MIN="${WA_ROOT_GUARD_ALARM_WINDOW_MIN:-60}"
# vazio → o padrão (2 ciclos / 60 min); falhou/ilegível (não numérico) → o padrão: um knob torto nunca cala o alerta
case "$CONFIRM" in ''|*[!0-9]*) CONFIRM=2 ;; esac
case "$WINDOW_MIN" in ''|*[!0-9]*) WINDOW_MIN=60 ;; esac
# vazio → o relógio real; falhou/ilegível → NOW=0 e CLOCK_OK=0: sem relógio não há janela, o alerta sai a cada ciclo (visível)
NOW="${WA_ROOT_GUARD_NOW:-}"   # the epoch seam is for the selftest only
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s 2>/dev/null)" ;; esac
CLOCK_OK=1
case "$NOW" in ''|*[!0-9]*) NOW=0; CLOCK_OK=0 ;; esac

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
note() { command -v notify >/dev/null 2>&1 && notify "$@" >/dev/null 2>&1 || true; }

# git wrapper for the root, with hooks neutralised (mirrors the Mayor's manual recipe).
g() { git -C "$ROOT" -c core.hooksPath="$HOOKS" "$@"; }

mkdir -p "$HOOKS" 2>/dev/null || true

# Root must be a git repo.
if [ ! -d "$ROOT/.git" ] && ! g rev-parse --git-dir >/dev/null 2>&1; then
  log "skip: $ROOT is not a git repo (or unreadable)."
  exit 0
fi

# ── Detached HEAD (ga-a7mti1) ────────────────────────────────────────────────────────────────────────────────────
# Loads PREV_KIND/PREV_COUNT/PREV_FIRST/PREV_ALARM from $STATE; PREV_KIND empty = no episode open.
read_state() {
  PREV_KIND=""; PREV_COUNT=0; PREV_FIRST=0; PREV_ALARM=0
  local k="" c="" f="" a="" rest=""
  # vazio (sem arquivo) → nenhum episódio aberto; falhou/ilegível (diretório, campo torto) → idem: a contagem recomeça, nunca confirma de graça
  [ -f "$STATE" ] || return 0
  read -r k c f a rest 2>/dev/null < "$STATE" || [ -n "$k" ] || return 0
  case "$k" in off-main|unknown) ;; *) return 0 ;; esac
  case "$c" in ''|*[!0-9]*) return 0 ;; esac
  case "$f" in ''|*[!0-9]*) return 0 ;; esac
  case "$a" in ''|*[!0-9]*) return 0 ;; esac
  PREV_KIND="$k"; PREV_COUNT="$c"; PREV_FIRST="$f"; PREV_ALARM="$a"
}

# write_state <kind> <count> <first> <alarm> → 0 only when the file reads back exactly as written.
write_state() {
  local want="$1 $2 $3 $4" got=""
  mkdir -p "${STATE%/*}" 2>/dev/null
  printf '%s\n' "$want" > "$STATE.tmp" 2>/dev/null && mv -f "$STATE.tmp" "$STATE" 2>/dev/null
  # vazio/falhou/ilegível (caminho que é diretório, disco cheio) → não bate com o escrito → rc 1 e o chamador alerta já
  got="$(cat "$STATE" 2>/dev/null)" || got=""
  [ "$got" = "$want" ]
}

# age_min <first_epoch> → "NNmin", or "?" without a usable clock.
age_min() {
  if [ "$CLOCK_OK" = 1 ] && [ "$1" -le "$NOW" ]; then echo "$(( (NOW - $1) / 60 ))min"; else echo "?"; fi
}

# A healthy cycle (HEAD on origin/main, or the root back on a branch) ends the episode: one CLEARED line, no notify, and
# only when the episode had alerted — a blip nobody was told about stays unmentioned.
clear_episode() {
  [ -e "$STATE" ] || return 0
  read_state
  rm -f "$STATE" 2>/dev/null
  # falhou (não removeu) → WARN visível; o episódio velho seria contado como continuação, no máximo um ciclo cedo demais
  if [ -e "$STATE" ]; then log "WARN: could not remove the episode state $STATE — a later blip may be counted as a continuation."; fi
  if [ -n "$PREV_KIND" ] && [ "$PREV_ALARM" != 0 ]; then
    log "CLEARED: production root is back on reviewed code (the '$PREV_KIND' episode lasted ~$(age_min "$PREV_FIRST"), $PREV_COUNT cycles)."
  fi
}

# No branch name: a detached HEAD (healthy when it sits on origin/main) or a HEAD git cannot read. Never restores; always exits 0.
handle_detached() {
  local rc=0 kind="" why="" head_sha="" om_sha="" count=0 first=0 alarm=0 fire=0 age="" again="" h12="" o12=""
  # symbolic-ref -q: 0 = still a branch (only its name was unreadable), 1 = detached, >=128 = git failed → unknown, nunca saudável
  g symbolic-ref -q HEAD >/dev/null 2>&1; rc=$?
  case "$rc" in
    1)
      # vazio (HEAD sem commit) → unknown; falhou/ilegível → unknown (nunca on-main)
      head_sha="$(g rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || head_sha=""
      # vazio (sem origin/main neste clone) → unknown; falhou/ilegível → unknown (nunca on-main)
      om_sha="$(g rev-parse -q --verify 'origin/main^{commit}' 2>/dev/null)" || om_sha=""
      if [ -z "$head_sha" ]; then
        kind=unknown; why="the detached HEAD does not resolve to a commit"
      elif [ -z "$om_sha" ]; then
        kind=unknown; why="origin/main does not resolve (never fetched, or deleted)"
      else
        # 0 → on-main; 1 → off-main; qualquer outro rc (git falhou) → unknown
        g merge-base --is-ancestor "$head_sha" "$om_sha" >/dev/null 2>&1; rc=$?
        case "$rc" in
          0) kind=on-main ;;
          1) kind=off-main ;;
          *) kind=unknown; why="git merge-base --is-ancestor failed (rc=$rc)" ;;
        esac
      fi ;;
    0) kind=unknown; why="HEAD is a branch whose name could not be read" ;;
    *) kind=unknown; why="HEAD is unreadable (git rc=$rc)" ;;
  esac

  if [ "$kind" = on-main ]; then clear_episode; exit 0; fi

  read_state
  if [ "$PREV_KIND" = "$kind" ]; then
    count=$((PREV_COUNT + 1)); first="$PREV_FIRST"; alarm="$PREV_ALARM"
  else
    count=1; first="$NOW"; alarm=0
  fi
  if [ "$count" -ge "$CONFIRM" ]; then
    if [ "$alarm" = 0 ] || [ "$CLOCK_OK" = 0 ] || [ $((NOW - alarm)) -ge $((WINDOW_MIN * 60)) ]; then
      fire=1; alarm="$NOW"
    fi
  fi
  # what the alert says about the next one has to be what the code does
  again="Next alert in ${WINDOW_MIN}min if it persists."
  if [ "$CLOCK_OK" = 0 ]; then again="No usable clock, so no window: alerting on every cycle."; fi
  if ! write_state "$kind" "$count" "$first" "$alarm"; then
    fire=1; again="Episode state unwritable ($STATE): alerting on every cycle until it is fixed."
  fi

  if [ "$fire" = 1 ]; then
    h12="${head_sha:0:12}"; o12="${om_sha:0:12}"; h12="${h12:-?}"; o12="${o12:-?}"
    age="$(age_min "$first")"
    if [ "$kind" = off-main ]; then
      log "OFF-MAIN-DETACHED: production root is on a DETACHED HEAD ($h12) that origin/main ($o12) does not contain — unreviewed code is live (cycles=$count, ~$age). Detection only, NOT restoring; who/when: git -C $ROOT reflog. $again"
      note -p 4 -t 'wa-root-guard' "WA root DETACHED on $h12, NOT in origin/main — unreviewed code is live ($count cycles, ~$age). Detection only, NEEDS HUMAN"
    else
      log "UNKNOWN-DETACHED: cannot tell whether the production root is on reviewed code — $why (HEAD $h12, origin/main $o12; cycles=$count, ~$age). NOT assuming healthy; detection only. $again"
      note -p 4 -t 'wa-root-guard' "WA root HEAD state UNKNOWN: $why — cannot confirm it is on origin/main, NEEDS HUMAN"
    fi
  fi
  exit 0
}

# vazio → sem nome de branch (HEAD destacado, ou git falhou): handle_detached separa os dois; falhou/ilegível → idem, nunca "main"
BRANCH="$(g branch --show-current 2>/dev/null || true)"

# No branch name: never restored here (see DETACHED HEAD above).
if [ -z "$BRANCH" ]; then
  handle_detached
fi

# On a branch: a detached episode, if one was open, is over.
clear_episode

# Clean: already on main → silent success.
if [ "$BRANCH" = "main" ]; then
  exit 0
fi

# Off-main: a crew branch is checked out in the production root.
SHA="$(g rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "OFF-MAIN: production root is on '$BRANCH' (HEAD $SHA) — restore required."

if [ "$ENABLED" != "1" ]; then
  log "WA_ROOT_GUARD_ENABLED=0 — check-only, NOT restoring (branch=$BRANCH HEAD=$SHA)."
  note -p 4 -t 'wa-root-guard' "WA root OFF-MAIN on '$BRANCH' but guard DISABLED — restore skipped, NEEDS HUMAN"
  exit 0
fi

# 1. Back up the divergent HEAD first so a crew's in-progress commit is never lost.
BACKUP_TAG="wa-root-guard-backup-${SHA}"
if g tag -f "$BACKUP_TAG" HEAD >/dev/null 2>&1; then
  log "backed up divergent HEAD ($BRANCH @ $SHA) to tag $BACKUP_TAG (recover: git -C $ROOT checkout $BACKUP_TAG)."
else
  log "WARN: could not create backup tag $BACKUP_TAG — ABORTING restore to avoid data loss (needs human)."
  note -p 5 -t 'wa-root-guard' "WA root OFF-MAIN on '$BRANCH' but backup tag FAILED — restore aborted, NEEDS HUMAN"
  exit 0
fi

# 2. Restore to main — the exact recipe the Mayor uses by hand. Conservative, no force.
# ga-sdkrl gate-feedback: `git stash push -- <clean-path>` is a NO-OP — creates NO
# stash entry, just prints "No local changes to save" — whenever daemons/ has no
# local changes (the common case). The old code then did an UNCONDITIONAL `stash
# drop` below regardless, which always drops whatever sits at the TOP of the stash
# stack. ROOT is a shared production root crews/Mayor operate in directly — if any
# unrelated stash (a human's `git stash`, another process's) already sat at
# stash@{0} when this guard fired and daemons/ happened to be clean, that unrelated
# work was silently destroyed. Reproduced end-to-end in a throwaway repo before
# fixing: pre-existing stash -> scoped push on a clean path (no-op, stash list
# unchanged) -> unconditional drop -> pre-existing stash gone. Fix: capture the
# stash ref before/after and only drop if it actually changed — i.e. only if THIS
# push genuinely created a new entry, never someone else's.
STASH_BEFORE="$(g rev-parse -q --verify refs/stash 2>/dev/null || echo '')"
g stash push -- daemons/ >/dev/null 2>&1 || true   # redundant staged daemon syncs, if any
STASH_AFTER="$(g rev-parse -q --verify refs/stash 2>/dev/null || echo '')"

if ! g switch main >/dev/null 2>&1; then
  log "WARN: 'git switch main' FAILED (dirty/conflict?) — NOT forcing. Left on '$BRANCH'. Backup tag=$BACKUP_TAG. NEEDS HUMAN."
  note -p 5 -t 'wa-root-guard' "WA root switch to main FAILED on '$BRANCH' (conflict?) — NOT forced, NEEDS HUMAN (backup $BACKUP_TAG)"
  exit 0
fi

g fetch origin main >/dev/null 2>&1 || log "WARN: 'git fetch origin main' returned nonzero (offline?) — continuing with local main."

if ! g merge --ff-only origin/main >/dev/null 2>&1; then
  log "WARN: 'git merge --ff-only origin/main' FAILED — root is on main but may be behind origin. Not forcing. NEEDS HUMAN."
  note -p 4 -t 'wa-root-guard' "WA root back on main but ff-only merge from origin FAILED — may be behind, NEEDS HUMAN"
  # We are on main now (the dangerous off-main state is resolved), so do not exit nonzero.
fi

# Only drop if OUR push above genuinely created a new stash entry (ref changed).
# If it was a no-op (daemons/ was clean), STASH_AFTER == STASH_BEFORE (both empty,
# or both pointing at whatever unrelated stash already existed) — never drop in
# that case, so an unrelated pre-existing stash is never touched.
if [ -n "$STASH_AFTER" ] && [ "$STASH_AFTER" != "$STASH_BEFORE" ]; then
  g stash drop >/dev/null 2>&1 || true
fi

NOW="$(g branch --show-current 2>/dev/null || echo '?')"
if [ "$NOW" = "main" ]; then
  log "RESTORED: production root back on main (was '$BRANCH' @ $SHA, backed up to tag $BACKUP_TAG). Daemon RESTART likely needed (oracle's job — guard does NOT restart)."
  note -p 4 -t 'wa-root-guard' "WA root was OFF-MAIN on '$BRANCH' (@ $SHA) — RESTORED to main. Backup tag $BACKUP_TAG. Daemons likely need RESTART (oracle)."
else
  log "WARN: after restore attempt root is on '$NOW' (expected main) — NEEDS HUMAN. Backup tag=$BACKUP_TAG."
  note -p 5 -t 'wa-root-guard' "WA root restore did NOT land on main (now '$NOW') — NEEDS HUMAN (backup $BACKUP_TAG)"
fi
exit 0
