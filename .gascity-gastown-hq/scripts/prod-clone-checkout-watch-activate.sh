#!/usr/bin/env bash
# prod-clone-checkout-watch-activate.sh (ga-eei1o4) — idempotently installs prod-clone-checkout-watch.sh as the
# post-checkout hook of the LIVE whatsapp_automation clone (a symlink in the clone's hooks dir, the same way its
# pre-push hook is wired).
#
# WHY A SCRIPT: the hooks dir lives inside .git, so the hook can never be a commit; this git-tracked, re-runnable
# script is the substitute (same reasoning as home-scan-guard-activate.sh). MERGED != LIVE: `--check` proves it.
#
# USAGE: prod-clone-checkout-watch-activate.sh [--check | --remove]      (default: install)
#   env PCCW_ROOT    the clone (default /Users/athos/gt/whatsapp_automation)
#   env PCCW_SCRIPT  the hook to link to (default: the MAIN checkout's copy, /Users/athos/gt/.gascity-gastown-hq/scripts/...;
#                    a path under /.gc-worktrees/ is refused — the link would die with the worktree)
#
# STATES (four, not two — "a link exists" is not "the hook runs"):
#   ACTIVE   the hook path is a symlink to PCCW_SCRIPT and that file exists and is executable
#   INERT    symlink to PCCW_SCRIPT but the target is missing / not executable: registered, does nothing. Installing
#            BEFORE the script has merged lands here on purpose (harmless; becomes ACTIVE when the file lands).
#   FOREIGN  something else is already at <hooks>/post-checkout: never overwritten or removed
#   ABSENT   nothing there
# EXIT: --check 0 only for ACTIVE (1 INERT/ABSENT, 3 FOREIGN, 2 cannot tell); install 0 for ACTIVE/INERT, 3 FOREIGN, 2 cannot tell.
set -u

ROOT="${PCCW_ROOT:-/Users/athos/gt/whatsapp_automation}"
SCRIPT="${PCCW_SCRIPT:-/Users/athos/gt/.gascity-gastown-hq/scripts/prod-clone-checkout-watch.sh}"
MODE=install
case "${1:-}" in
  "") ;;
  --check) MODE=check ;;
  --remove) MODE=remove ;;
  *) echo "usage: $0 [--check|--remove]" >&2; exit 64 ;;
esac

case "$SCRIPT" in
  */.gc-worktrees/*) echo "refused: $SCRIPT is inside a worktree; the link would die with it. Use the main checkout's copy." >&2; exit 2 ;;
esac

# vazio → git não devolve o diretório de hooks: não sei onde instalar, sai 2; falhou/ilegível → idem
HOOKS=$(git -C "$ROOT" rev-parse --git-path hooks 2>/dev/null) || HOOKS=""
if [ -z "$HOOKS" ]; then echo "cannot tell: no hooks dir for $ROOT (not a git clone?)" >&2; exit 2; fi
case "$HOOKS" in /*) ;; *) HOOKS="$ROOT/$HOOKS" ;; esac
if [ ! -d "$HOOKS" ]; then echo "cannot tell: hooks dir $HOOKS does not exist" >&2; exit 2; fi
H="$HOOKS/post-checkout"

state() {
  if [ ! -e "$H" ] && [ ! -L "$H" ]; then echo ABSENT; return; fi
  # vazio → não é symlink ou não lê o destino: FOREIGN (nunca "é nosso" sem prova); falhou/ilegível → idem
  tgt=$(readlink "$H" 2>/dev/null) || tgt=""
  if [ "$tgt" != "$SCRIPT" ]; then echo FOREIGN; return; fi
  if [ -f "$SCRIPT" ] && [ -x "$SCRIPT" ]; then echo ACTIVE; else echo INERT; fi
}

S=$(state)
case "$MODE" in
  check)
    echo "$S $H"
    case "$S" in ACTIVE) exit 0 ;; FOREIGN) exit 3 ;; *) exit 1 ;; esac ;;
  remove)
    case "$S" in
      FOREIGN) echo "FOREIGN $H is not ours — left alone" >&2; exit 3 ;;
      ABSENT) echo "ABSENT $H — nothing to remove"; exit 0 ;;
      *) rm -f "$H" && echo "REMOVED $H"; exit $? ;;
    esac ;;
  install)
    case "$S" in
      FOREIGN) echo "FOREIGN $H already exists and is not ours — left alone" >&2; exit 3 ;;
      ABSENT)
        ln -s "$SCRIPT" "$H" || { echo "could not create $H" >&2; exit 2; }
        S=$(state) ;;
    esac
    echo "$S $H -> $SCRIPT"
    [ "$S" = INERT ] && echo "note: INERT until $SCRIPT exists and is executable (merge it, then re-run with --check)"
    exit 0 ;;
esac
