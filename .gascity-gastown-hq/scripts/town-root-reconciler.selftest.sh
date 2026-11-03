#!/usr/bin/env bash
# town-root-reconciler.selftest.sh — Regression harness for reconcile_tracked_for_ffpull
# (gt-yjr20 — recurring "town root diverged" FF jam on an uncommitted tracked edit).
#
# ROOT CAUSE this pins: reconcile_tracked_for_ffpull used to block the FF for ANY
# dirty tracked file whose working-tree bytes differ from the incoming origin/main
# version — even when the incoming FF DOES NOT modify that file at all. So a single
# uncommitted crew edit to a tracked file (e.g. skills/refino/SKILL.md) froze EVERY
# subsequent unrelated framework FF until a human committed/resolved it. Git's own
# `pull --ff-only` happily preserves an ORTHOGONAL uncommitted edit (a file the FF
# does not touch) and still advances — the reconciler was over-blocking.
#
# THE FIX: an edit is a genuine conflict ONLY when the incoming FF actually changes
# that file (upstream blob != HEAD blob) AND the local edit differs from the incoming
# version. If the incoming FF leaves the file alone (upstream blob == HEAD blob), the
# edit is orthogonal — preserve it, do NOT block. The FF lands and the edit survives.
#
# These scenarios drive the helper against THROWAWAY real git repos (no live root, no
# live Dolt, no gc). Scenario 1 replays the exact gt-yjr20 shape and proves the FF now
# lands; Scenarios 2/3/4 pin the ga-y3tx behaviors the fix must NOT regress (identical
# dup restore, genuine conflict still blocks, deleted-upstream skip). Scenario 5 mixes
# orthogonal + identical-dup + clean-incoming in one FF.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILER="$SCRIPT_DIR/town-root-reconciler.sh"

# vazio/falhou → sai: nunca segue com TMP vazio (ROOT/LOG e os "$TMP/..." cairiam na raiz)
TMP="$(mktemp -d "${TMPDIR:-/tmp}/trr-selftest.XXXXXX")" || { echo "FATAL: mktemp falhou"; exit 1; }
[ -d "$TMP" ] || { echo "FATAL: mktemp nao criou $TMP"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Source the reconciler as a library (guard skips the daemon loop). Point ROOT/CITY/
# LOG at the throwaway dir so nothing touches the live root or its logs.
export TOWN_ROOT_RECONCILER_LIB=1
export ROOT="$TMP" CITY="$TMP" LOG_DIR="$TMP" LOG="$TMP/reconciler.log"
# shellcheck disable=SC1090
source "$RECONCILER"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok: $*"; }
bad() { FAIL=$((FAIL+1)); echo "  BAD: $*"; }

# mk_repo <dir> — fresh git repo with deterministic identity, isolated from any
# parent repo (the worktree we run inside) via a ceiling at the repo dir.
mk_repo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main   # force 'main' regardless of init.defaultBranch
  git -C "$d" config user.email "selftest@local"
  git -C "$d" config user.name  "selftest"
  git -C "$d" config commit.gpgsign false
}

# A clean "upstream" is modeled by a local branch `upstream` that is strictly
# AHEAD of HEAD (HEAD stays on `main`). reconcile_tracked_for_ffpull takes the
# upstream as a ref string, so a branch name works exactly like "origin/main".

# ── Scenario 1: ORTHOGONAL uncommitted edit — the gt-yjr20 fix ────────────────
# Local has an uncommitted edit to skills/refino/SKILL.md; the incoming FF only
# changes an UNRELATED file. The edit must be preserved, the FF must NOT be blocked,
# and a real `git merge --ff-only` must land while keeping the edit.
echo "Scenario 1: orthogonal uncommitted tracked edit — FF must land, edit preserved (gt-yjr20)"
R="$TMP/s1"; mk_repo "$R"
mkdir -p "$R/skills/refino" "$R/scripts"
printf 'skill v1\n'   > "$R/skills/refino/SKILL.md"
printf 'pilot v1\n'   > "$R/scripts/pilot.sh"
git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'pilot v2 (framework fix)\n' > "$R/scripts/pilot.sh"   # incoming changes ONLY pilot.sh
git -C "$R" commit -q -am c1
git -C "$R" checkout -q main
# crew leaves an uncommitted edit on the tracked skill file:
printf 'skill v1\n+ anti-overlap section (uncommitted crew edit)\n' > "$R/skills/refino/SKILL.md"
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                && ok "returns 0 (does not block the FF)"            || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ "${ORTHOGONAL_COUNT:-x}" -eq 1 ] && ok "ORTHOGONAL_COUNT=1 (edit recognised as untouched-by-FF)" || bad "expected ORTHOGONAL_COUNT=1, got '${ORTHOGONAL_COUNT:-unset}'"
[ "${TRACKED_COUNT:-x}" -eq 0 ]    && ok "TRACKED_COUNT=0 (nothing restored)"           || bad "expected TRACKED_COUNT=0, got '${TRACKED_COUNT:-unset}'"
[ -z "${TRACKED_DIFF_LIST// /}" ]  && ok "no conflict recorded"                          || bad "TRACKED_DIFF_LIST should be empty, got '$TRACKED_DIFF_LIST'"
grep -q "anti-overlap" "$R/skills/refino/SKILL.md" && ok "local edit NOT clobbered"      || bad "local edit was clobbered"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS (jam gone)" || bad "FF still blocked after reconcile (the recurring jam)"
grep -q "anti-overlap" "$R/skills/refino/SKILL.md" && ok "edit survives the FF"          || bad "edit lost across the FF"
grep -q "pilot v2"    "$R/scripts/pilot.sh"        && ok "framework fix landed (pilot v2)" || bad "incoming framework fix did not land"

# ── Scenario 2: byte-identical tracked modification (ga-y3tx) — must restore + land
echo "Scenario 2: incoming changes a file; local edit is byte-identical to incoming → restore + FF"
R="$TMP/s2"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'v2\n' > "$R/a.sh"; git -C "$R" commit -q -am c1   # incoming changes a.sh -> v2
git -C "$R" checkout -q main
printf 'v2\n' > "$R/a.sh"                                  # local edited a.sh to the SAME v2 (uncommitted)
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                  && ok "returns 0"                              || bad "expected rc 0, got $rc"
[ "${TRACKED_COUNT:-x}" -eq 1 ]  && ok "TRACKED_COUNT=1 (identical dup restored)" || bad "expected TRACKED_COUNT=1, got '${TRACKED_COUNT:-unset}'"
[ "${ORTHOGONAL_COUNT:-x}" -eq 0 ] && ok "ORTHOGONAL_COUNT=0 (file IS changed by FF)" || bad "expected ORTHOGONAL_COUNT=0, got '${ORTHOGONAL_COUNT:-unset}'"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS" || bad "FF blocked"
[ "$(cat "$R/a.sh")" = "v2" ]    && ok "a.sh advanced to v2"                    || bad "a.sh not at v2"

# ── Scenario 3: genuine conflict — incoming changes the file, local edit differs → BLOCK
echo "Scenario 3: incoming changes a file AND local edit differs → must BLOCK (never clobber)"
R="$TMP/s3"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'upstream-v2\n' > "$R/a.sh"; git -C "$R" commit -q -am c1   # incoming changes a.sh
git -C "$R" checkout -q main
printf 'local-different\n' > "$R/a.sh"                              # local changed it to something else
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 2 ]                              && ok "returns 2 (blocks)"                    || bad "expected rc 2, got $rc"
case " $TRACKED_DIFF_LIST " in *" a.sh "*) ok "a.sh recorded in TRACKED_DIFF_LIST";; *) bad "a.sh not in TRACKED_DIFF_LIST ('$TRACKED_DIFF_LIST')";; esac
[ "$(cat "$R/a.sh")" = "local-different" ]   && ok "local edit NOT clobbered"             || bad "local edit was clobbered"

# ── Scenario 4: incoming DELETES the file; local edit present → skip, leave alone
echo "Scenario 4: incoming deletes the file → skip (not our concern), do not block"
R="$TMP/s4"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; printf 'keep\n' > "$R/b.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
git -C "$R" rm -q a.sh; git -C "$R" commit -q -m c1   # incoming deletes a.sh
git -C "$R" checkout -q main
printf 'local edit\n' > "$R/a.sh"                      # local edited the (still-tracked-here) a.sh
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                          && ok "returns 0 (deleted-upstream skipped)"     || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ -z "${TRACKED_DIFF_LIST// /}" ]        && ok "no conflict recorded"                     || bad "TRACKED_DIFF_LIST should be empty, got '$TRACKED_DIFF_LIST'"
[ "$(cat "$R/a.sh")" = "local edit" ]    && ok "local edit left untouched"               || bad "local edit was touched"

# ── Scenario 5: mixed — orthogonal edit + identical-dup + clean incoming in ONE FF
echo "Scenario 5: orthogonal edit + byte-identical dup + unrelated clean change → land all"
R="$TMP/s5"; mk_repo "$R"
printf 'A v1\n' > "$R/orth.sh"; printf 'B v1\n' > "$R/dup.sh"; printf 'C v1\n' > "$R/clean.sh"
git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" checkout -q -b upstream
printf 'B v2\n' > "$R/dup.sh"; printf 'C v2\n' > "$R/clean.sh"   # incoming changes dup.sh + clean.sh, NOT orth.sh
git -C "$R" commit -q -am c1
git -C "$R" checkout -q main
printf 'A v1\n+ local orthogonal edit\n' > "$R/orth.sh"   # uncommitted, untouched by FF
printf 'B v2\n' > "$R/dup.sh"                              # uncommitted, identical to incoming
reconcile_tracked_for_ffpull "$R" "upstream"; rc=$?
[ "$rc" -eq 0 ]                    && ok "returns 0"                                  || bad "expected rc 0, got $rc (TRACKED_DIFF_LIST='$TRACKED_DIFF_LIST')"
[ "${ORTHOGONAL_COUNT:-x}" -eq 1 ] && ok "ORTHOGONAL_COUNT=1 (orth.sh preserved)"     || bad "expected ORTHOGONAL_COUNT=1, got '${ORTHOGONAL_COUNT:-unset}'"
[ "${TRACKED_COUNT:-x}" -eq 1 ]    && ok "TRACKED_COUNT=1 (dup.sh restored)"           || bad "expected TRACKED_COUNT=1, got '${TRACKED_COUNT:-unset}'"
git -C "$R" merge --ff-only upstream >/dev/null 2>&1 && ok "git merge --ff-only LANDS" || bad "FF blocked"
grep -q "orthogonal edit" "$R/orth.sh" && ok "orthogonal edit survives FF"            || bad "orthogonal edit lost"
[ "$(cat "$R/dup.sh")" = "B v2" ]      && ok "dup.sh at B v2"                          || bad "dup.sh wrong"
[ "$(cat "$R/clean.sh")" = "C v2" ]    && ok "clean.sh at C v2"                        || bad "clean.sh wrong"

# ── Escalation ladder scenarios (ga-k4uh) ─────────────────────────────────────
# Humans are NOT the first line of defense for town-root infra problems: infra
# (Mayor) is told first via durable mail; the human is only paged if the
# problem stays unresolved past ESCALATE_THRESHOLD_SECONDS, and even then at
# most once per NTFY_THROTTLE_SECONDS. Stub gc/notify as shell functions so
# these scenarios never touch real Dolt/ntfy — bash resolves unqualified
# command names against functions defined in the current shell before falling
# back to $PATH, so these shadow the real binaries for the rest of this script.
GC_MAIL_LOG="$TMP/gc-mail.log"
GC_CALLS="$TMP/gc-calls.log"
NOTIFY_LOG="$TMP/notify.log"
reset_stubs() { : > "$GC_MAIL_LOG"; : > "$GC_CALLS"; : > "$NOTIFY_LOG"; }
gc() {
  # Args (the -m body) can contain embedded newlines; normalize to ONE log
  # line per invocation so `wc -l` on the log counts calls, not text lines.
  # GC_MAIL_RC / GC_RELOAD_RC (default 0) make `mail send` / `reload` fail on demand (ga-qec2rdl).
  if [ "$1" = "mail" ] && [ "$2" = "send" ]; then
    printf 'mail-sent: %s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$GC_MAIL_LOG"
    return "${GC_MAIL_RC:-0}"
  fi
  if [ "$1" = "reload" ]; then
    printf 'reload: %s\n' "$*" >> "$GC_CALLS"
    return "${GC_RELOAD_RC:-0}"
  fi
  return 0
}
notify() { echo "notified: $*" >> "$NOTIFY_LOG"; return 0; }

# ── Scenario 6: tier 1 — first sight mails Mayor, does NOT page human ────────
echo "Scenario 6: escalation ladder tier 1 — first sight mails Mayor, does NOT page human"
rm -f "$ESCALATE_STAMP" "$NTFY_STAMP"
reset_stubs
maybe_ntfy "test divergence msg"
[ "$(wc -l < "$GC_MAIL_LOG" | tr -d ' ')" = "1" ] && ok "tier 1: Mayor mailed exactly once" || bad "tier 1: expected 1 Mayor mail, got $(wc -l < "$GC_MAIL_LOG")"
[ ! -s "$NOTIFY_LOG" ]   && ok "tier 1: human NOT paged"          || bad "tier 1: human was paged on first sight (should defer)"
[ -f "$ESCALATE_STAMP" ] && ok "tier 1: escalation stamp written" || bad "tier 1: no escalation stamp written"

# ── Scenario 7: tier 2 — still within grace window, no repeat mail/page ──────
echo "Scenario 7: escalation ladder tier 2 — within grace window, no repeat mail/page"
reset_stubs
maybe_ntfy "still diverged, second tick"
[ ! -s "$GC_MAIL_LOG" ] && ok "tier 2: no repeat Mayor mail within grace window" || bad "tier 2: Mayor mailed again within grace window"
[ ! -s "$NOTIFY_LOG" ]  && ok "tier 2: human still not paged"                    || bad "tier 2: human paged too early"

# ── Scenario 8: tier 3 — unresolved past threshold pages the human ───────────
echo "Scenario 8: escalation ladder tier 3 — unresolved past threshold pages human"
reset_stubs
echo "$(( $(date +%s) - ESCALATE_THRESHOLD_SECONDS - 5 ))" > "$ESCALATE_STAMP"
rm -f "$NTFY_STAMP"
maybe_ntfy "still diverged, past threshold"
[ ! -s "$GC_MAIL_LOG" ]  && ok "tier 3: no re-mail to Mayor (already escalated)" || bad "tier 3: unexpectedly re-mailed Mayor"
[ "$(wc -l < "$NOTIFY_LOG" | tr -d ' ')" = "1" ] && ok "tier 3: human paged exactly once" || bad "tier 3: expected 1 human page, got $(wc -l < "$NOTIFY_LOG")"
[ -f "$NTFY_STAMP" ]     && ok "tier 3: NTFY_STAMP written" || bad "tier 3: NTFY_STAMP not written"

# ── Scenario 9: daily human throttle — second tier-3 call same day no repeat ─
echo "Scenario 9: daily human throttle — second tier-3-eligible call same day does not re-page"
reset_stubs
maybe_ntfy "still diverged, third tick same day"
[ ! -s "$NOTIFY_LOG" ] && ok "daily throttle: human NOT paged again same day" || bad "daily throttle: human paged twice within throttle window"

# ── Scenario 10: clear_escalation resets the ladder for a fresh episode ──────
echo "Scenario 10: clear_escalation resets ladder — fresh divergence restarts at tier 1"
clear_escalation
[ ! -f "$ESCALATE_STAMP" ] && ok "clear_escalation removed the stamp" || bad "escalation stamp survived clear_escalation"
reset_stubs
maybe_ntfy "new divergence episode after resolve"
[ "$(wc -l < "$GC_MAIL_LOG" | tr -d ' ')" = "1" ] && ok "tier 1 restarts: Mayor mailed again for the NEW episode" || bad "tier 1 restarts: Mayor not mailed for new episode"
[ ! -s "$NOTIFY_LOG" ] && ok "tier 1 restarts: human not paged immediately on the fresh episode" || bad "tier 1 restarts: human paged immediately on fresh episode"

# ── Scenario 11: reconcile_once wiring — already-in-sync clears escalation ───
# Integration check that reconcile_once's healthy exit point actually CALLS
# clear_escalation (scenarios 6-10 test maybe_ntfy/clear_escalation directly;
# this pins the call site so a future edit can't silently drop the wiring).
echo "Scenario 11: reconcile_once wiring — already-in-sync clears a stale escalation stamp"
R="$TMP/s11"; mk_repo "$R"
printf 'v1\n' > "$R/a.sh"; git -C "$R" add -A; git -C "$R" commit -q -m c0
git -C "$R" remote add origin "$R"
echo "999999999" > "$ESCALATE_STAMP"   # simulate a stale outstanding escalation
_saved_ROOT="$ROOT"; _saved_REMOTE="$REMOTE"; _saved_BRANCH="$BRANCH"
ROOT="$R"; REMOTE="origin"; BRANCH="main"
reconcile_once >/dev/null 2>&1
rc_fetch=$?
ROOT="$_saved_ROOT"; REMOTE="$_saved_REMOTE"; BRANCH="$_saved_BRANCH"
[ "$rc_fetch" -eq 0 ]     && ok "reconcile_once completed without error"          || bad "reconcile_once returned $rc_fetch"
[ ! -f "$ESCALATE_STAMP" ] && ok "reconcile_once cleared escalation on already-in-sync" || bad "reconcile_once did NOT clear escalation on already-in-sync"

# ── Lastro hq-mutants (ga-qec2rdl): o resto do reconcile_once, os limites do maybe_ntfy, o untracked, o script ──
# Ate aqui o reconcile_once so rodava "ja em sincronia" (e sem distinguir de um FF que nao puxa nada), o
# reconcile_untracked_for_ffpull nao rodava em lugar nenhum e os limites exatos do maybe_ntfy (45 min, 1 dia)
# nunca eram tocados. Agora cada ramo roda contra um par de repositorios de brinquedo (origem + clone), com
# date e git de mentira definidos como funcoes deste shell, como gc e notify acima.
# EQUIVALENTES (lastro): 3bf5a69c5c 3ec1b3ce09 18e2ca9f08 8c15fc648f (`cmd || true` -> `cmd && true`:
# ninguem le o status e nao ha set -e); 4dd84a5bcb (o `|| true` que fecha a cadeia de cp do backup: ninguem le o status);
# d0372d9f4c 2a4dfbfe9d c3efbaf3cc 7990ceb751 d1fe4548ab 86e745f1c8 (`$(git ... || echo "")` -> `&&`: quando o git
# falha nao imprime nada e quando acerta a linha vazia a mais some no $(...)).
# NAO e' equivalente: 033544c743, o `rm -f` que fecha o clear_escalation, muda o status do PROPRIO ajudante; o caso do
# carimbo-diretorio no cenario 22 le esse status. Tambem nao e': 24909e7bf1 (o `||` entre os dois cp do backup virando `&&`): o 2o cp, depois de um `cp -p` que deu certo, troca o mtime do
# backup pela hora de agora (os bytes sao os mesmos); o cenario 21 le o mtime.
# date devolve $FAKE_NOW para `date +%s` quando ele esta definido; git falha quando "<subcomando> <1o arg>" comeca por $GITFAIL.
# EQUIVALENT 3bf5a69c5c 3ec1b3ce09 18e2ca9f08 8c15fc648f: `cmd || true` -> `cmd && true`: ninguem le o status e nao ha set -e
# EQUIVALENT 4dd84a5bcb: o `|| true` que fecha a cadeia de cp do backup: ninguem le o status
# EQUIVALENT 2a4dfbfe9d 7990ceb751 86e745f1c8 d0372d9f4c c3efbaf3cc d1fe4548ab: `$(git ... || echo "")` -> `&&`: quando o git falha nao imprime nada e quando acerta a linha vazia a mais some no $(...)
# EQUIVALENT 24909e7bf1: JAULA, nao equivalencia: o `||` entre os dois cp virando `&&` troca o mtime do backup pela hora de agora e o cenario 21 o mata fora da jaula (medido 03/11: fora FAIL=1, na jaula PASS=78 FAIL=0); no rodizio fica vivo porque o backup vai para /tmp e a jaula so grava no slot
date() { if [ "${1-}" = "+%s" ] && [ -n "${FAKE_NOW:-}" ]; then echo "$FAKE_NOW"; else command date "$@"; fi; }
git() { if [ -n "${GITFAIL:-}" ]; then case "${3-} ${4-}" in "$GITFAIL"*) return 1 ;; esac; fi; command git "$@"; }
fresh_stamps() { rm -f "$ESCALATE_STAMP" "$NTFY_STAMP"; }
has_log() { grep -F -- "$1" "$LOG" >/dev/null 2>&1; }   # arquivo ausente/ilegivel = nao achou = reprova
# arquivo ausente: o wc nao imprime numero e a comparacao com o esperado reprova, nunca conta 0
mails() { wc -l < "$GC_MAIL_LOG" | tr -d ' '; }
notified() { wc -l < "$NOTIFY_LOG" | tr -d ' '; }
mk_pair() { # <nome> — origem "$U" (a.sh b.sh o.sh) e clone "$W" em main com origin/main
  U="$TMP/$1-up"; W="$TMP/$1-w"
  mk_repo "$U"
  printf 'v1\n' > "$U/a.sh"; printf 'keep\n' > "$U/b.sh"; printf 'o1\n' > "$U/o.sh"
  git -C "$U" add -A; git -C "$U" commit -q -m c0
  git clone -q "$U" "$W" >/dev/null 2>&1
  git -C "$W" config user.email "selftest@local"; git -C "$W" config user.name "selftest"; git -C "$W" config commit.gpgsign false
}
up_commit() { printf '%s\n' "$2" > "$U/$1"; git -C "$U" add -A; git -C "$U" commit -q -m "up $1"; }   # <arquivo> <conteudo>
rco() { # reconcile_once contra $W (origin/main), log e stubs zerados; deixa $RC
  : > "$LOG"; reset_stubs
  local _r="$ROOT"; ROOT="$W"
  reconcile_once >/dev/null 2>&1; RC=$?
  ROOT="$_r"
}

echo "Scenario 12: reconcile_once — sem git / branch errada / fetch que falha / SHA local ilegivel"
fresh_stamps; W="$TMP/nogit"; mkdir "$W"; rco
[ "$RC" = "0" ] && has_log "is not a git work tree — skip" && [ "$(mails)" = "0" ] \
  && ok "raiz que nao e repo: erro registrado, sai 0, nao escala" || bad "raiz sem git: rc=$RC mails=$(mails)"
fresh_stamps; mk_pair s12b; git -C "$W" checkout -q -b other; rco
[ "$RC" = "0" ] && has_log "town root is on 'other', not 'main'" && [ "$(mails)" = "1" ] && [ -f "$ESCALATE_STAMP" ] && ! has_log "BEHIND" \
  && ok "branch errada: nao troca de branch, escala (1 mail) e sai 0" || bad "branch errada: rc=$RC mails=$(mails)"
fresh_stamps; W="$TMP/s12c"; mk_repo "$W"; printf 'x\n' > "$W/f"; git -C "$W" add -A; git -C "$W" commit -q -m c0; rco
[ "$RC" = "0" ] && has_log "fetch origin main failed (transient)" && [ "$(mails)" = "0" ] \
  && ok "fetch que falha (sem remoto): transitorio, sai 0 e nao escala" || bad "fetch falha: rc=$RC mails=$(mails)"
fresh_stamps; mk_pair s12d; up_commit c.sh new; GITFAIL="rev-parse main"; rco; GITFAIL=""
[ "$RC" = "0" ] && has_log "could not resolve SHAs" && [ "$(mails)" = "0" ] && ! has_log "DIVERGED" && [ ! -f "$W/c.sh" ] \
  && ok "SHA local ilegivel: erro registrado, nada e puxado nem escalado" || bad "SHA ilegivel: rc=$RC mails=$(mails)"

echo "Scenario 13: reconcile_once — em sincronia nao puxa nem recarrega e limpa a escalacao"
fresh_stamps; mk_pair s13; echo "999999999" > "$ESCALATE_STAMP"; rco
[ "$RC" = "0" ] && [ ! -f "$ESCALATE_STAMP" ] && has_log "divergence resolved" && ! has_log "BEHIND" && [ ! -s "$GC_CALLS" ] \
  && ok "em sincronia: escalacao limpa, nenhum FF, nenhum reload" || bad "em sincronia: rc=$RC"

echo "Scenario 14: reconcile_once — atrasado e limpo: o FF entra, o crew recarrega e a escalacao some"
fresh_stamps; mk_pair s14; up_commit c.sh new; echo "999999999" > "$ESCALATE_STAMP"; rco
[ "$RC" = "0" ] && has_log "town root BEHIND origin/main by 1 commit(s)" && has_log "FF pull OK" && [ -f "$W/c.sh" ] \
  && grep -F -- "reload: reload --soft --city $CITY" "$GC_CALLS" >/dev/null && has_log "gc reload --soft (sync) applied" \
  && ! has_log "(sync) failed" && ! has_log "reconciled" && ! has_log "preserved" && [ ! -f "$ESCALATE_STAMP" ] && [ "$(mails)" = "0" ] \
  && ok "atrasado e limpo: FF, reload --soft, sem contadores no log e sem escalar" || bad "atrasado e limpo: rc=$RC"
fresh_stamps; mk_pair s14b; up_commit c.sh new; GC_RELOAD_RC=1; rco; GC_RELOAD_RC=0
[ "$RC" = "0" ] && [ -f "$W/c.sh" ] && has_log "(sync) failed" && ! has_log "(sync) applied" \
  && ok "reload que falha: o FF ja entrou, o log diz que falhou e nao diz 'applied'" || bad "reload falha: rc=$RC"

echo "Scenario 15: reconcile_once — conta e registra edicao identica, edicao ortogonal e colisao untracked identica"
fresh_stamps; mk_pair s15
printf 'v2\n' > "$U/a.sh"; printf 'from-upstream\n' > "$U/trr-collide.sh"; git -C "$U" add -A; git -C "$U" commit -q -m c1
printf 'v2\n' > "$W/a.sh"; printf 'o1\n+ local\n' > "$W/o.sh"; printf 'from-upstream\n' > "$W/trr-collide.sh"
rco
[ "$RC" = "0" ] && has_log "reconciled 1 byte-identical tracked modification(s)" && has_log "preserved 1 orthogonal local edit(s)" \
  && has_log "reconciled 1 byte-identical untracked collision(s)" && has_log "FF pull OK" && [ "$(cat "$W/a.sh")" = "v2" ] \
  && grep -F -- "+ local" "$W/o.sh" >/dev/null && git -C "$W" ls-files --error-unmatch trr-collide.sh >/dev/null 2>&1 \
  && ok "tres tipos de arquivo sujo no mesmo FF: cada contador aparece uma vez e o FF entra" || bad "contadores: rc=$RC"

echo "Scenario 16: reconcile_once — conflito rastreado ou untracked: bloqueia, escala 1 vez e nao puxa"
fresh_stamps; mk_pair s16; up_commit a.sh v2; printf 'local-different\n' > "$W/a.sh"; rco
[ "$RC" = "0" ] && has_log "town root FF blocked: tracked modification(s) DIFFER" && has_log "a.sh" && [ "$(mails)" = "1" ] \
  && [ "$(cat "$W/a.sh")" = "local-different" ] && ! has_log "FF pull OK" && [ ! -s "$GC_CALLS" ] \
  && ok "edicao rastreada diferente: bloqueia, escala, nada e puxado nem sobrescrito" || bad "conflito rastreado: rc=$RC mails=$(mails)"
fresh_stamps; mk_pair s16b; up_commit trr-collide.sh from-upstream; printf 'mine\n' > "$W/trr-collide.sh"; rco
[ "$RC" = "0" ] && has_log "untracked working-tree file(s) DIFFER" && has_log "trr-collide.sh" && [ "$(mails)" = "1" ] \
  && [ "$(cat "$W/trr-collide.sh")" = "mine" ] && ! has_log "FF pull OK" && [ ! -s "$GC_CALLS" ] \
  && ok "arquivo untracked diferente: bloqueia, escala, nada e puxado nem apagado" || bad "conflito untracked: rc=$RC mails=$(mails)"

echo "Scenario 17: reconcile_once — DRY_RUN=1 so diz o que faria; pull que falha escala e nao recarrega"
fresh_stamps; mk_pair s17; up_commit c.sh new; DRY_RUN=1; rco; DRY_RUN=0
[ "$RC" = "0" ] && has_log "DRY_RUN=1 — WOULD: git pull --ff-only origin main" && [ ! -f "$W/c.sh" ] && ! has_log "FF pull OK" && [ ! -s "$GC_CALLS" ] \
  && ok "DRY_RUN=1: avisa, nao puxa, nao recarrega, sai 0" || bad "DRY_RUN: rc=$RC"
fresh_stamps; mk_pair s17b; up_commit c.sh new; GITFAIL="pull"; rco; GITFAIL=""
[ "$RC" = "0" ] && has_log "FF pull FAILED after tracked+untracked reconcile" && [ "$(mails)" = "1" ] && ! has_log "FF pull OK" \
  && [ ! -s "$GC_CALLS" ] && [ ! -f "$W/c.sh" ] \
  && ok "pull que falha: erro registrado, escala 1 vez, sem reload" || bad "pull falha: rc=$RC mails=$(mails)"

echo "Scenario 18: reconcile_once — a frente da origem nao puxa nem escala; divergencia escala e nao mexe"
fresh_stamps; mk_pair s18; printf 'w\n' > "$W/w.sh"; git -C "$W" add -A; git -C "$W" commit -q -m w; echo "999999999" > "$ESCALATE_STAMP"; rco
[ "$RC" = "0" ] && has_log "town root AHEAD of origin/main by 1 unpushed commit(s)" && [ ! -f "$ESCALATE_STAMP" ] && [ "$(mails)" = "0" ] \
  && [ ! -s "$GC_CALLS" ] && ! has_log "BEHIND" && ! has_log "DIVERGED" \
  && ok "commit local nao publicado: so registra e limpa a escalacao" || bad "adiantado: rc=$RC mails=$(mails)"
fresh_stamps; mk_pair s18b; up_commit c.sh new; printf 'w\n' > "$W/w.sh"; git -C "$W" add -A; git -C "$W" commit -q -m w; rco
[ "$RC" = "0" ] && has_log "town root DIVERGED from origin/main" && [ "$(mails)" = "1" ] && [ ! -f "$W/c.sh" ] && ! has_log "AHEAD" && ! has_log "BEHIND" \
  && ok "divergencia verdadeira: escala 1 vez e nao puxa" || bad "divergido: rc=$RC mails=$(mails)"

echo "Scenario 19: reconcile_once — contagem que o git nao consegue dar vira '?' no log, nunca vazio"
fresh_stamps; mk_pair s19; up_commit c.sh new; GITFAIL="rev-list"; rco; GITFAIL=""
[ "$RC" = "0" ] && has_log "BEHIND origin/main by ? commit(s)" && [ -f "$W/c.sh" ] \
  && ok "atrasado sem contagem: 'by ?' e o FF entra mesmo assim" || bad "atrasado sem contagem: rc=$RC"
fresh_stamps; mk_pair s19b; printf 'w\n' > "$W/w.sh"; git -C "$W" add -A; git -C "$W" commit -q -m w; GITFAIL="rev-list"; rco; GITFAIL=""
[ "$RC" = "0" ] && has_log "AHEAD of origin/main by ? unpushed commit(s)" \
  && ok "adiantado sem contagem: 'by ?'" || bad "adiantado sem contagem: rc=$RC"

echo "Scenario 20: reconcile_tracked/untracked_for_ffpull — guardas de entrada (sem dir, sem upstream, nao e git)"
mk_pair s20
for fn in reconcile_tracked_for_ffpull reconcile_untracked_for_ffpull; do
  : > "$LOG"; "$fn" "" "origin/main" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && has_log "no dir — skip" && ok "$fn: dir vazio sai 0 e registra" || bad "$fn dir vazio: rc=$rc"
  : > "$LOG"; "$fn" "$W" "" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && has_log "no upstream — skip" && ok "$fn: upstream vazio sai 0 e registra" || bad "$fn upstream vazio: rc=$rc"
  : > "$LOG"; "$fn" "$TMP/nogit" "origin/main" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && has_log "is not a git work tree — skip" && ok "$fn: pasta sem git sai 0 e registra" || bad "$fn sem git: rc=$rc"
done

echo "Scenario 21: reconcile_untracked_for_ffpull — identica sai, diferente fica e para, so-local fica, DRY_RUN so avisa"
mk_pair s21; up_commit trr-collide.sh from-upstream; git -C "$W" fetch -q origin
printf 'from-upstream\n' > "$W/trr-collide.sh"; printf 'mine only\n' > "$W/local-only.txt"
# (ga-tsi6ovl) mtime velho e fixo no arquivo e num arquivo de referencia: o backup tem de sair com ele (ver o caso do backup abaixo). Backups de outras passadas deste shell saem antes.
touch -t 200001020304 "$W/trr-collide.sh"; : > "$TMP/mtime.ref"; touch -t 200001020304 "$TMP/mtime.ref"; rm -f /tmp/trr-collide.sh.backup.*.$$ 2>/dev/null
: > "$LOG"; reconcile_untracked_for_ffpull "$W" origin/main >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && [ "$RECONCILE_COUNT" = "1" ] && [ -z "${RECONCILE_DIFF_LIST// /}" ] && [ ! -e "$W/trr-collide.sh" ] \
  && [ "$(cat "$W/local-only.txt")" = "mine only" ] && has_log "auto-reconciled identical untracked 'trr-collide.sh'" \
  && ok "colisao identica: removida (com backup) e contada; o arquivo so-local nao e tocado" \
  || bad "untracked identica: rc=$rc count=$RECONCILE_COUNT list='$RECONCILE_DIFF_LIST'"
# O backup e' feito por `cp -p ... || cp ...`: leva o mtime do arquivo, que diz de quando era o conteudo. Se o `cp` de reserva rodasse DEPOIS de um `cp -p` que deu certo
# (24909e7bf1, o `||` virando `&&`) os bytes seriam os mesmos e o backup ficaria com a hora de agora. Sem /tmp gravavel (jaula do gate) nao ha backup para medir: o caso diz isso e nao conta.
_bk=""; for _f in /tmp/trr-collide.sh.backup.*.$$; do [ -f "$_f" ] && _bk="$_f"; done
if [ -n "$_bk" ]; then
  { [ "$(cat "$_bk")" = "from-upstream" ] && [ ! "$_bk" -nt "$TMP/mtime.ref" ] && [ ! "$_bk" -ot "$TMP/mtime.ref" ]; } \
    && ok "colisao identica: o backup leva o mtime do arquivo (cp -p), nao a hora do backup" \
    || bad "backup da colisao identica: conteudo ou mtime errado ($(ls -l "$_bk"))"
else
  echo "  SKIP: sem backup em /tmp (sem /tmp gravavel, jaula do gate): o mtime do backup nao pode ser medido aqui"
fi
unset _bk _f
printf 'mine different\n' > "$W/trr-collide.sh"
: > "$LOG"; reconcile_untracked_for_ffpull "$W" origin/main >/dev/null 2>&1; rc=$?
[ "$rc" = "2" ] && [ "$RECONCILE_COUNT" = "0" ] && [ "$RECONCILE_DIFF_LIST" = " trr-collide.sh" ] \
  && [ "$(cat "$W/trr-collide.sh")" = "mine different" ] && has_log "CONFLICT — untracked 'trr-collide.sh' DIFFERS" \
  && ok "colisao diferente: nada e removido, sai 2 e a lista nomeia o arquivo" \
  || bad "untracked diferente: rc=$rc count=$RECONCILE_COUNT list='$RECONCILE_DIFF_LIST'"
printf 'from-upstream\n' > "$W/trr-collide.sh"
: > "$LOG"; DRY_RUN=1; reconcile_untracked_for_ffpull "$W" origin/main >/dev/null 2>&1; rc=$?; DRY_RUN=0
[ "$rc" = "0" ] && [ "$RECONCILE_COUNT" = "1" ] && [ -f "$W/trr-collide.sh" ] \
  && has_log "DRY_RUN — WOULD backup+remove identical untracked 'trr-collide.sh'" \
  && ok "DRY_RUN: conta e avisa, mas nao remove" || bad "untracked DRY_RUN: rc=$rc count=$RECONCILE_COUNT"

echo "Scenario 22: maybe_ntfy e clear_escalation — status, mail que falha, limites exatos (45 min, 1 dia) e log de limpeza"
fresh_stamps; reset_stubs; : > "$LOG"
maybe_ntfy "primeira vez"; rc1=$?
maybe_ntfy "ainda na janela"; rc2=$?
[ "$rc1" = "0" ] && [ "$rc2" = "0" ] && has_log "tier 1 — mailed Mayor" && [ "$(mails)" = "1" ] \
  && ok "degraus 1 e 2 saem 0 (o 1o manda mail e avisa, o 2o e no-op)" || bad "degraus 1/2: rc1=$rc1 rc2=$rc2 mails=$(mails)"
fresh_stamps; reset_stubs; : > "$LOG"; GC_MAIL_RC=1; maybe_ntfy "mail falha"; GC_MAIL_RC=0
has_log "gc mail send mayor FAILED" && ! has_log "tier 1 — mailed Mayor" && [ -f "$ESCALATE_STAMP" ] \
  && ok "mail ao Mayor que falha: avisa FAILED, nao diz 'mailed' e mantem o degrau" || bad "mail falha: log sem FAILED"
FAKE_NOW=2000000000
fresh_stamps; echo "$((FAKE_NOW - ESCALATE_THRESHOLD_SECONDS + 1))" > "$ESCALATE_STAMP"; reset_stubs; maybe_ntfy "1 s antes"
[ "$(notified)" = "0" ] && ok "1 s antes dos 45 min: ainda nao pagina" || bad "paginou 1 s antes do limite"
fresh_stamps; echo "$((FAKE_NOW - ESCALATE_THRESHOLD_SECONDS))" > "$ESCALATE_STAMP"; reset_stubs; maybe_ntfy "no limite"
[ "$(notified)" = "1" ] && ok "exatamente nos 45 min: pagina" || bad "nao paginou exatamente no limite"
fresh_stamps; echo "$((FAKE_NOW - ESCALATE_THRESHOLD_SECONDS))" > "$ESCALATE_STAMP"; echo "$((FAKE_NOW - NTFY_THROTTLE_SECONDS + 1))" > "$NTFY_STAMP"
reset_stubs; maybe_ntfy "1 s antes do dia"
[ "$(notified)" = "0" ] && ok "1 s antes de completar 1 dia desde a ultima pagina: nao repete" || bad "repetiu a pagina antes de 1 dia"
fresh_stamps; echo "$((FAKE_NOW - ESCALATE_THRESHOLD_SECONDS))" > "$ESCALATE_STAMP"; echo "$((FAKE_NOW - NTFY_THROTTLE_SECONDS))" > "$NTFY_STAMP"
reset_stubs; maybe_ntfy "no dia exato"
[ "$(notified)" = "1" ] && [ "$(cat "$NTFY_STAMP")" = "$FAKE_NOW" ] \
  && ok "exatamente 1 dia depois da ultima pagina: pagina e regrava o carimbo" || bad "nao paginou no dia exato"
FAKE_NOW=""
: > "$LOG"; echo 1 > "$ESCALATE_STAMP"; clear_escalation
[ ! -f "$ESCALATE_STAMP" ] && has_log "divergence resolved — clearing infra-escalation state" \
  && ok "clear_escalation com escalacao aberta: apaga e registra" || bad "clear_escalation nao registrou"
: > "$LOG"; clear_escalation
! has_log "divergence resolved" && ok "clear_escalation sem escalacao aberta: nao diz nada" || bad "clear_escalation falou sem escalacao"
mkdir -p "$ESCALATE_STAMP/sub"; rc=0; clear_escalation >/dev/null 2>&1 || rc=$?; rmdir "$ESCALATE_STAMP/sub" "$ESCALATE_STAMP"   # rm -f recusa um diretorio: a limpeza best-effort nao pode devolver o status dele
[ "$rc" = "0" ] && ok "clear_escalation com o carimbo impossivel de remover (um diretorio): devolve 0" || bad "clear_escalation devolveu $rc com o carimbo impossivel de remover"

echo "Scenario 23: o script executado — modo lib, uma passada (RECONCILE_ONCE) e o laco de verdade"
printf '%s\n' '#!/bin/bash' 'echo "$*" >> "$GCSTUB_LOG"' > "$TMP/gcstub"; chmod +x "$TMP/gcstub"
runtrr() { # <teto em segundos> [VAR=valor ...] — o script como programa; deixa $RC, $ALIVE e a saida em $TMP/trr.out
  local cap="$1" p n=0; shift
  # o topo deste selftest exporta TOWN_ROOT_RECONCILER_LIB=1: o filho precisa de =0, salvo no caso que o pede
  env ROOT="$W" CITY="$TMP/city23" LOG_DIR="$TMP/city23/logs" LOG="$TMP/city23/logs/t.log" GC="$TMP/gcstub" \
    GCSTUB_LOG="$TMP/gcstub.log" RECONCILE_INTERVAL=1 TOWN_ROOT_RECONCILER_LIB=0 "$@" bash "$RECONCILER" > "$TMP/trr.out" 2>&1 < /dev/null &
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt $((cap * 10)) ]; do sleep 0.1; n=$((n + 1)); done
  ALIVE=0; if kill -0 "$p" 2>/dev/null; then ALIVE=1; kill "$p" 2>/dev/null; fi
  wait "$p" 2>/dev/null; RC=$?
}
( . "$RECONCILER" ) >/dev/null 2>&1; rc=$?
[ "$rc" = "0" ] && ok "modo lib: source devolve 0" || bad "modo lib: source devolveu $rc"
mk_pair s23; up_commit c.sh new; : > "$TMP/gcstub.log"
runtrr 3 TOWN_ROOT_RECONCILER_LIB=1 RECONCILE_ONCE=1
[ "$RC" = "0" ] && [ "$ALIVE" = "0" ] && [ ! -s "$TMP/trr.out" ] && [ ! -e "$TMP/city23/.gc/state/town-root-reconciler.startup" ] && [ ! -f "$W/c.sh" ] \
  && ok "modo lib executado: sai 0 calado, sem marcador de partida e sem puxar nada" || bad "modo lib executado: rc=$RC alive=$ALIVE out='$(cat "$TMP/trr.out")'"
runtrr 5 RECONCILE_ONCE=1
[ "$RC" = "0" ] && [ "$ALIVE" = "0" ] && [ -f "$W/c.sh" ] && grep -F -- "town-root-reconciler started" "$TMP/trr.out" >/dev/null \
  && grep -E '^[0-9]+ [0-9]+$' "$TMP/city23/.gc/state/town-root-reconciler.startup" >/dev/null \
  && grep -F -- "reload --soft --city $TMP/city23" "$TMP/gcstub.log" >/dev/null \
  && ok "RECONCILE_ONCE=1: uma passada (puxa e recarrega), marcador de partida gravado e sai 0 sozinho" \
  || bad "RECONCILE_ONCE: rc=$RC alive=$ALIVE out='$(cat "$TMP/trr.out")'"
up_commit d.sh new2
runtrr 2
[ "$ALIVE" = "1" ] && [ -f "$W/d.sh" ] \
  && ok "sem RECONCILE_ONCE: o laco roda a 1a passada e continua vivo esperando o proximo ciclo" \
  || bad "laco: alive=$ALIVE d.sh=$([ -f "$W/d.sh" ] && echo sim || echo nao)"

# O subject grava o backup da colisao identica em /tmp/<arquivo>.backup.<data>.<pid>, caminho fixo; o pid e
# o deste shell. Sem /tmp gravavel (jaula do gate) a copia falha calada e este rm nao casa nada.
rm -f /tmp/trr-collide.sh.backup.*.$$

echo ""
echo "town-root-reconciler selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
