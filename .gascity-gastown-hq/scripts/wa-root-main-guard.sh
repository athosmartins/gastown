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
# classified against the local origin/main ref, as of the last fetch (this path does not fetch; only the restore does):
#   on-main   HEAD is reachable from origin/main → silent: no line, no notify; an open episode is cleared
#   off-main  HEAD is NOT reachable → unreviewed code is live → OFF-MAIN-DETACHED
#   unknown   cannot tell (origin/main missing, HEAD unreadable, merge-base failed) → UNKNOWN-DETACHED, never "healthy"
# off-main/unknown alert (one log line + one notify) on the 2nd consecutive cycle (WA_ROOT_GUARD_CONFIRM_CYCLES), so a
# 19 s reviewer detour is not an alert, then once per WA_ROOT_GUARD_ALARM_WINDOW_MIN (60), not per cycle. The episode is
# kept in $CITY/.gc/wa-root-main-guard.state; when that cannot be written the alert fires at once, because a confirmation
# that can never be remembered would never come. The detached cases are DETECTION ONLY: a restore cannot tell a forgotten
# checkout from a deliberate one (a reviewer reading the files would suddenly read main's), so only a named non-main
# branch is still backed up and restored below. The alert window is spent only by an alert notify accepted (exit 0 — what it
# does with it afterwards, hold, digest or dedupe, this script cannot see): a notify that fails leaves a NOTIFY-FAILED line
# and the next cycle tries again; a clock that stepped back behind the last alert alerts again. Every git call is fenced to
# the root (g(), below): the production root sits INSIDE the HQ repo, and a root whose own .git is broken or missing would
# otherwise be read as the HQ's `main`. The two knobs are read as decimal (08 is 8; empty, non-numeric or past 12 digits is
# the default), and a state file field with a leading zero or past 12 digits makes it count as no episode.
# Test seams (selftest only): WA_ROOT_GUARD_{ROOT,CITY,HOOKS,NOW}.
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
# Every number below ends up in $(( )) or `[ -gt ]`. "Only digits" is not enough for either: bash reads 08/09 in $(( )) as an
# invalid octal (an ERROR that ends the enclosing command — see the guard after handle_detached), 010 as 8, and a string past
# 12 digits wraps silently in $(( )) while `[` refuses it (rc 2, read as false). plain() is the one test for that: 1-12 digits,
# no leading zero ("0" alone is fine). The two knobs are hand-typed, so they are normalised instead (10#): 08 means 8. (The
# clock is `date +%s`, or the selftest seam: neither is typed by hand.)
plain() { case "$1" in ''|0[0-9]*|*[!0-9]*|?????????????*) return 1 ;; esac; return 0; }
# vazio → o padrão (2 ciclos / 60 min); falhou/ilegível (não numérico, ou mais de 12 dígitos) → o padrão: um knob torto nunca cala o alerta
case "$CONFIRM" in ''|*[!0-9]*|?????????????*) CONFIRM=2 ;; esac
case "$WINDOW_MIN" in ''|*[!0-9]*|?????????????*) WINDOW_MIN=60 ;; esac
CONFIRM=$((10#$CONFIRM)); WINDOW_MIN=$((10#$WINDOW_MIN))
# vazio → o relógio real; falhou/ilegível → NOW=0 e CLOCK_OK=0: sem relógio não há janela, então o alerta, uma vez confirmado, sai a cada ciclo (visível)
NOW="${WA_ROOT_GUARD_NOW:-}"   # the epoch seam is for the selftest only
case "$NOW" in ''|*[!0-9]*) NOW="$(date +%s 2>/dev/null)" ;; esac
CLOCK_OK=1
case "$NOW" in ''|*[!0-9]*) NOW=0; CLOCK_OK=0 ;; esac

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
# note → 0 only when notify ran and exited 0; 1 when there is no `notify` on PATH; else notify's own rc. Callers that do
# not care about delivery ignore it (no `set -e` here); the detached alert reads it, because it spends a window.
note() {
  command -v notify >/dev/null 2>&1 || return 1
  notify "$@" >/dev/null 2>&1
}

# Fence for git: it must not climb out of the root. The production root lives INSIDE another repo (the HQ, /Users/athos/gt,
# on main); when the root's own .git is broken or gone, git silently keeps looking upward and every read answers for the
# HQ — `branch --show-current` prints the HQ's "main" and the guard files an error as "healthy". The ceiling is the parent
# of the REAL root (symlinks resolved): for a root reached through a symlink, the textual parent is not an ancestor of where
# git actually stands, and the fence would stand in the wrong place.
# vazio (ROOT não existe) → sem teto; git -C ROOT falha sozinho (rc 128) e o guard cai no "skip:" abaixo; falhou/ilegível
# (cd -P falha) → idem: sem como subir a partir de um diretório que o git também não consegue abrir
ROOT_REAL="$(cd -P "$ROOT" 2>/dev/null && pwd -P)" || ROOT_REAL=""
CEILING=""
if [ -n "$ROOT_REAL" ]; then CEILING="${ROOT_REAL%/*}"; CEILING="${CEILING:-/}"; fi

# git wrapper for the root, with hooks neutralised (mirrors the Mayor's manual recipe) and fenced to the root (see above).
g() { GIT_CEILING_DIRECTORIES="$CEILING" git -C "$ROOT" -c core.hooksPath="$HOOKS" "$@"; }

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
  # vazio (sem arquivo) → nenhum episódio aberto; falhou/ilegível (diretório, campo torto, zero à esquerda, número longo demais) → idem: a contagem recomeça, nunca confirma de graça
  # (só este script escreve o arquivo, e $(( )) nunca imprime zero à esquerda: um campo assim é corrupção, não "8" — e um alarm gigante calaria o alerta para sempre)
  [ -f "$STATE" ] || return 0
  read -r k c f a rest 2>/dev/null < "$STATE" || [ -n "$k" ] || return 0
  case "$k" in off-main|unknown) ;; *) return 0 ;; esac
  plain "$c" && plain "$f" && plain "$a" || return 0
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

# age_min <first_epoch> → "NNmin", or "?" without a usable clock, or when the episode began without one (first_epoch 0:
# NOW - 0 would print ~30 million minutes) or in the future (the clock stepped back).
age_min() {
  if [ "$CLOCK_OK" = 1 ] && [ "$1" -gt 0 ] && [ "$1" -le "$NOW" ]; then echo "$(( (NOW - $1) / 60 ))min"; else echo "?"; fi
}

# clear_episode <where> — the HEAD is no longer detached (on origin/main, or the root is on a branch again): the episode
# ends. One CLEARED line, no notify, and only when the episode had alerted — a blip nobody was told about stays
# unmentioned. <where> says what the root is now, because "no longer detached" is not "on reviewed code": a crew branch is
# not (the restore below deals with it). "Had alerted" is count >= CONFIRM, not last_alarm != 0: an alert sent with no
# clock records last_alarm 0. Limit: an episode whose state could not be written leaves no state to close, so no CLEARED.
clear_episode() {
  [ -e "$STATE" ] || return 0
  read_state
  rm -f "$STATE" 2>/dev/null
  # falhou (não removeu) → WARN visível; o episódio velho seria contado como continuação, no máximo um ciclo cedo demais
  if [ -e "$STATE" ]; then log "WARN: could not remove the episode state $STATE — a later blip may be counted as a continuation."; fi
  if [ -n "$PREV_KIND" ] && [ "$PREV_COUNT" -ge "$CONFIRM" ]; then
    log "CLEARED: production root is $1 (the '$PREV_KIND' episode lasted ~$(age_min "$PREV_FIRST"), $PREV_COUNT cycles)."
  fi
}

# No branch name: a detached HEAD (healthy when it sits on origin/main) or a HEAD git cannot read. Never restores; always exits 0.
handle_detached() {
  local rc=0 kind="" why="" head_sha="" om_sha="" count=0 first=0 alarm=0 alarm_before=0 fire=0 unwritable=0 nrc=0
  local age="" again="" h12="" o12="" line="" nmsg=""
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

  if [ "$kind" = on-main ]; then clear_episode "back on reviewed code (HEAD is contained in origin/main)"; exit 0; fi

  read_state
  if [ "$PREV_KIND" = "$kind" ]; then
    count=$((PREV_COUNT + 1)); first="$PREV_FIRST"; alarm="$PREV_ALARM"; alarm_before="$PREV_ALARM"
  else
    count=1; first="$NOW"; alarm=0; alarm_before=0
  fi
  if [ "$count" -ge "$CONFIRM" ]; then
    # alert when: never alerted, no clock, the window is spent — or the last alert lies in the FUTURE (the clock stepped
    # back; $NOW - $alarm would be negative and the next alert would wait for the clock to catch up plus a whole window)
    if [ "$alarm" = 0 ] || [ "$CLOCK_OK" = 0 ] || [ "$alarm" -gt "$NOW" ] || [ $((NOW - alarm)) -ge $((WINDOW_MIN * 60)) ]; then
      fire=1; alarm="$NOW"
    fi
  fi
  # what the alert says about the next one has to be what the code does
  again="Next alert in ${WINDOW_MIN}min if it persists."
  if [ "$CLOCK_OK" = 0 ]; then again="No usable clock, so no window: alerting on every cycle."; fi
  if ! write_state "$kind" "$count" "$first" "$alarm"; then
    unwritable=1; fire=1; again="Episode state unwritable ($STATE): alerting on every cycle until it is fixed."
  fi

  if [ "$fire" = 1 ]; then
    h12="${head_sha:0:12}"; o12="${om_sha:0:12}"; h12="${h12:-?}"; o12="${o12:-?}"
    age="$(age_min "$first")"
    if [ "$kind" = off-main ]; then
      line="OFF-MAIN-DETACHED: production root is on a DETACHED HEAD ($h12) that origin/main ($o12) does not contain — unreviewed code is live (cycles=$count, ~$age). Detection only, NOT restoring; who/when: git -C $ROOT reflog. $again"
      nmsg="WA root DETACHED on $h12, NOT in origin/main — unreviewed code is live ($count cycles, ~$age). Detection only, NEEDS HUMAN"
    else
      line="UNKNOWN-DETACHED: cannot tell whether the production root is on reviewed code — $why (HEAD $h12, origin/main $o12; cycles=$count, ~$age). NOT assuming healthy; detection only. $again"
      nmsg="WA root HEAD state UNKNOWN: $why — cannot confirm it is on origin/main, NEEDS HUMAN"
    fi
    log "$line"   # the log is the durable copy: written before notify, which may take long or fail
    # notify rc 0 → ele aceitou o alerta (o canal ainda pode segurar, agrupar ou deduplicar: isso este script não vê); falhou/ausente → ≠0: o alerta só está no log
    note -p 4 -t 'wa-root-guard' "$nmsg"; nrc=$?
    if [ "$nrc" != 0 ]; then
      # a window is spent only by an alert notify accepted (rc 0): put the previous last_alarm back, so the next cycle tries again.
      # (with no clock or no writable state the alert already repeats every cycle, and the line above says so)
      if [ "$unwritable" = 0 ] && [ "$CLOCK_OK" = 1 ] && write_state "$kind" "$count" "$first" "$alarm_before"; then
        log "NOTIFY-FAILED: notify did not take the alert above (rc=$nrc), so this log is its only copy — the window is NOT spent; trying again on the next cycle."
      else
        log "NOTIFY-FAILED: notify did not take the alert above (rc=$nrc), so this log is its only copy."
      fi
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
# handle_detached always ends in `exit 0`, so getting here with no branch name means it was ABORTED: an expansion error (a bad
# number in $(( ))) ends the whole enclosing command, this `if`, and bash resumes at the NEXT statement — which is the restore
# below, run with BRANCH='' (a CLEARED line, a backup tag, the root moved off its detached HEAD). A check written inside that
# `if`, after the call, would be skipped along with it; this has to be a statement of its own. The numbers are validated above,
# so this is the net under them.
# vazio → o handler não terminou; falhou/ilegível → idem: INERTE — uma linha WARN no log, o root intocado, nunca o restauro
if [ -z "$BRANCH" ]; then
  log "WARN: the detached-HEAD handler did not finish (an internal error) — the production root was NOT touched; bash's own error is in $CITY/.gc/logs/wa-root-main-guard-launchd.err."
  exit 0
fi

# On a branch: a detached episode, if one was open, is over — but "on a branch" is only "back on main" when it is main.
if [ "$BRANCH" = "main" ]; then
  clear_episode "back on main"
else
  clear_episode "no longer detached: it is on branch '$BRANCH' (handled below)"
fi

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

AFTER="$(g branch --show-current 2>/dev/null || echo '?')"
if [ "$AFTER" = "main" ]; then
  log "RESTORED: production root back on main (was '$BRANCH' @ $SHA, backed up to tag $BACKUP_TAG). Daemon RESTART likely needed (oracle's job — guard does NOT restart)."
  note -p 4 -t 'wa-root-guard' "WA root was OFF-MAIN on '$BRANCH' (@ $SHA) — RESTORED to main. Backup tag $BACKUP_TAG. Daemons likely need RESTART (oracle)."
else
  log "WARN: after restore attempt root is on '$AFTER' (expected main) — NEEDS HUMAN. Backup tag=$BACKUP_TAG."
  note -p 5 -t 'wa-root-guard' "WA root restore did NOT land on main (now '$AFTER') — NEEDS HUMAN (backup $BACKUP_TAG)"
fi
exit 0
