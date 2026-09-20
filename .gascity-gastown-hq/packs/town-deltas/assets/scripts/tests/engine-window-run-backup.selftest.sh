#!/usr/bin/env bash
# engine-window-run-backup.selftest.sh (ga-ta2w6r)
#
# Roda o scripts/engine-window-run.sh REAL (via /bin/bash, o interprete do shebang
# = bash 3.2 no macOS) num sandbox: engine descartavel com origin -> repo bare local,
# um Makefile de mentira que estampa main.commit como o de verdade, e um "symlink
# vivo" que e so um arquivo dentro de $WORK. Prova que o push virou passo da janela
# ANTES do build, que o swap recusa fonte sem backup SEM tocar o symlink, que o
# rollback nunca e barrado, e que o bypass e deliberado e barulhento.
#
# SEGURANCA (este teste dirige a fase que troca o gc da cidade inteira): todo
# caminho que o script toca e apontado pra dentro de $WORK por env, PATH ganha um
# notify de mentira na frente (nenhuma notificacao real), e no fim o teste PROVA
# que o symlink vivo /opt/homebrew/bin/gc nao mudou. Se qualquer caminho do
# sandbox escapar de $WORK o teste aborta antes de rodar qualquer fase.
# Exit 0 iff toda assercao vale.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ENGINE_WINDOW_RUN_SCRIPT_UNDER_TEST: so pro teste de MUTACAO (copia com o gate neutralizado).
RUN="${ENGINE_WINDOW_RUN_SCRIPT_UNDER_TEST:-$SELF_DIR/../../../../../scripts/engine-window-run.sh}"
SWAP="$SELF_DIR/../engine-window-swap.sh"
# ENGINE_BACKUP_LIB_UNDER_TEST: idem, pra mutar a lib e rodar por aqui.
LIBPATH="${ENGINE_BACKUP_LIB_UNDER_TEST:-$SELF_DIR/../lib/engine-backup-lib.sh}"
# shellcheck source=engine-backup-fixture.sh
. "$SELF_DIR/engine-backup-fixture.sh"

[ -f "$RUN" ] || { echo "ABORTA: script sob teste nao existe: $RUN"; exit 2; }
LIVE_LINK=/opt/homebrew/bin/gc
LIVE_BEFORE=$(readlink "$LIVE_LINK" 2>/dev/null || echo "<sem-symlink>")

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fx_init "$WORK"
E="$FX_ENGINE"
WT="$WORK/wt/engine-window-t1"
LIBEXEC="$WORK/libexec"
GCLINK="$WORK/gc-link"
PREV="$WORK/prev-target"
WLOG="$WORK/window.log"
NOTIFY_LOG="$WORK/notify.log"
mkdir -p "$WORK/wt" "$LIBEXEC" "$WORK/fakebin" "$WORK/home"

# ---- trava de seguranca: NADA do sandbox pode apontar pra fora de $WORK ----
for p in "$WT" "$LIBEXEC" "$GCLINK" "$PREV" "$WLOG" "$E"; do
    case "$p" in "$WORK"/*) ;; *) echo "ABORTA: caminho do sandbox fora de \$WORK: $p"; exit 2 ;; esac
done
[ "$GCLINK" != "$LIVE_LINK" ] || { echo "ABORTA: o sandbox apontou pro symlink VIVO"; exit 2; }

fx_fake_notify "$WORK/fakebin/notify" "$NOTIFY_LOG"
: > "$NOTIFY_LOG"
printf '#!/bin/bash\necho "preflight stub: ok"\nexit 0\n' > "$WORK/preflight-stub.sh"
fx_fake_gc "$WORK/old-gc" "0ld0ld0"       # o "gc vivo" anterior do sandbox
ln -s "$WORK/old-gc" "$GCLINK"

# Makefile de mentira que estampa main.commit = git rev-parse --short HEAD, como o de verdade.
{
    printf 'BUILD_DIR ?= bin\nBINARY ?= gc\n'
    printf 'build:\n'
    printf '\t@mkdir -p $(BUILD_DIR)\n'
    printf '\t@printf '"'"'#!/bin/sh\\necho "engwin-fixture (commit: %%s, built: 2026-01-01T00:00:00Z)"\\n'"'"' "$$(git rev-parse --short HEAD)" > $(BUILD_DIR)/$(BINARY)\n'
    printf '\t@chmod +x $(BUILD_DIR)/$(BINARY)\n'
} > "$E/Makefile"
git -C "$E" add Makefile
git -C "$E" commit -q -m "makefile de mentira"
git -C "$E" push -q origin main

git -C "$E" worktree add -q "$WT" -b consolidated/engine-window-T1 main
T1_TIP=$(fx_commit "$WT" "janela-T1")
T1_BRANCH=consolidated/engine-window-T1
remote_tip() { git -C "$FX_REMOTE" rev-parse --verify --quiet "refs/heads/$T1_BRANCH" 2>/dev/null || echo "<ausente>"; }
short() { printf '%.9s' "$1"; }
notify_count() { wc -l < "$NOTIFY_LOG" | tr -d ' '; }

# run_win [env=VAL ...] -- args...  -> OUT, RC. O script roda sob /bin/bash (3.2).
run_win() {
    local extra=""
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do extra="$extra $1"; shift; done
    [ "${1:-}" = "--" ] && shift
    # shellcheck disable=SC2086
    OUT=$(env PATH="$WORK/fakebin:$PATH" HOME="$WORK/home" \
        ENGINE_WINDOW=T1 ENGINE_WINDOW_BRANCH="$T1_BRANCH" ENGINE_WINDOW_WORKTREE="$WT" \
        ENGINE_WINDOW_SRC="$E" ENGINE_WINDOW_LIBEXEC="$LIBEXEC" ENGINE_WINDOW_SYMLINK="$GCLINK" \
        ENGINE_WINDOW_PREV_FILE="$PREV" ENGINE_WINDOW_LOG="$WLOG" \
        ENGINE_WINDOW_PREFLIGHT="$WORK/preflight-stub.sh" ENGINE_WINDOW_LABEL=gc-fixture \
        ENGINE_WINDOW_TAG=engwin-T1 ENGINE_BACKUP_LIB="$LIBPATH" EB_RETRY_SLEEP_S=0 EB_PUSH_TRIES=2 \
        $extra /bin/bash "$RUN" "$@" 2>&1)
    RC=$?
}

echo "── 1. sintaxe do script sob teste e do swap (bash 3.2 e o do PATH) ──"
for f in "$RUN" "$SWAP"; do
    for B in /bin/bash "$(command -v bash)"; do
        if "$B" -n "$f"; then ok "bash -n OK: $(basename "$f") em $B"; else bad "bash -n FALHOU: $(basename "$f") em $B"; fi
    done
done

echo "── 2. 'check' e SOMENTE-LEITURA e ja mostra o estado do backup ──"
run_win -- check
assert_has "check (branch ainda so local) diz PENDENTE" "$OUT" "backup ....... PENDENTE"
assert_eq "  e o remoto continua SEM o branch (o check nao empurrou)" "<ausente>" "$(remote_tip)"

echo "── 3. push RECUSA worktree sujo (o binario carregaria conteudo que nenhum commit descreve) ──"
printf 'sujeira\n' >> "$WT/f.txt"
run_win -- push
assert_eq "worktree com mudanca nao-commitada -> rc=1" "1" "$RC"
assert_has "  explica o motivo" "$OUT" "mudancas nao-commitadas"
assert_eq "  e nada foi empurrado" "<ausente>" "$(remote_tip)"
git -C "$WT" checkout -q -- f.txt

echo "── 4. push RECUSA worktree fora do commit da branch (o build compilaria outra coisa) ──"
git -C "$WT" checkout -q --detach HEAD~1
run_win -- push
assert_eq "HEAD do worktree != ponta da branch -> rc=1" "1" "$RC"
assert_has "  explica que compilaria algo diferente" "$OUT" "compilaria algo diferente"
assert_eq "  e nada foi empurrado" "<ausente>" "$(remote_tip)"
git -C "$WT" checkout -q "$T1_BRANCH"

echo "── 5. push NUNCA forca: historia divergente no remoto -> recusa e o remoto fica intacto ──"
git clone -q "$FX_REMOTE" "$WORK/other"
git -C "$WORK/other" checkout -q -b "$T1_BRANCH" origin/main
DIVERGENT=$(fx_commit "$WORK/other" "alguem-empurrou-outra-coisa")
git -C "$WORK/other" push -q origin "$T1_BRANCH"
run_win -- push
assert_eq "remoto com historia divergente -> rc=1" "1" "$RC"
assert_has "  diz que NAO faz force-push" "$OUT" "NAO faco force-push"
assert_eq "  e o remoto ficou EXATAMENTE como estava (o commit do outro)" "$DIVERGENT" "$(remote_tip)"
git -C "$FX_REMOTE" branch -q -D "$T1_BRANCH"

echo "── 6. push feliz: empurra e verifica o EFEITO ──"
run_win -- push
assert_eq "push -> rc=0" "0" "$RC"
assert_eq "  o remoto tem a ponta da branch (lido no repo bare)" "$T1_TIP" "$(remote_tip)"
assert_has "  log diz OK" "$OUT" "backup ....... OK"
run_win -- check
assert_has "  e o check agora mostra OK" "$OUT" "backup ....... OK"

echo "── 7. build empurra ANTES de compilar e o binario nasce com o commit certo ──"
git -C "$FX_REMOTE" branch -q -D "$T1_BRANCH"      # remoto vazio de novo: o build tem que empurrar sozinho
run_win -- build --force
assert_eq "build --force -> rc=0" "0" "$RC"
assert_eq "  o remoto agora tem a ponta (o BUILD empurrou)" "$T1_TIP" "$(remote_tip)"
assert_eq "  binario compilado existe" "yes" "$([ -x "$LIBEXEC/gc-fixture" ] && echo yes || echo no)"
assert_has "  e declara o commit da ponta (stamp main.commit)" "$("$LIBEXEC/gc-fixture" version --long)" "$(git -C "$WT" rev-parse --short HEAD)"
PUSH_LINE=$(grep -n '=== PUSH' "$WLOG" | tail -1 | cut -d: -f1)
BUILD_LINE=$(grep -n '=== BUILD' "$WLOG" | tail -1 | cut -d: -f1)
assert_eq "  no log, a fase PUSH vem antes da fase BUILD" "yes" "$([ -n "$PUSH_LINE" ] && [ -n "$BUILD_LINE" ] && [ "$PUSH_LINE" -lt "$BUILD_LINE" ] && echo yes || echo no)"

echo "── 8. swap com binario de fonte EMPURRADA -> troca, guarda o anterior ──"
run_win -- swap
assert_eq "swap -> rc=0" "0" "$RC"
assert_eq "  symlink agora aponta pro binario novo" "$LIBEXEC/gc-fixture" "$(readlink "$GCLINK")"
assert_eq "  e o alvo anterior ficou guardado (rollback)" "$WORK/old-gc" "$(cat "$PREV")"
assert_has "  o gate registrou 'backup ....... OK'" "$OUT" "backup ....... OK"

echo "── 9. rollback funciona sempre ──"
run_win -- rollback
assert_eq "rollback -> rc=0" "0" "$RC"
assert_eq "  symlink voltou ao anterior" "$WORK/old-gc" "$(readlink "$GCLINK")"

echo "── 10. o INCIDENTE: swap de binario cuja fonte so existe no disco -> RECUSA e NAO toca o symlink ──"
git -C "$E" checkout -q -b scratch-so-local main
C_LOCAL=$(fx_commit "$E" "so-existe-neste-disco")
git -C "$E" checkout -q main
fx_fake_gc "$LIBEXEC/gc-fixture" "$(short "$C_LOCAL")-dirty"
rm -f "$PREV"
run_win -- swap
assert_eq "swap de binario de commit so-local -> rc=1" "1" "$RC"
assert_has "  diz SWAP RECUSADO" "$OUT" "SWAP RECUSADO"
assert_has "  e que nenhum remoto contem o commit" "$OUT" "NENHUM remoto contem"
assert_eq "  o symlink NAO foi tocado" "$WORK/old-gc" "$(readlink "$GCLINK")"
assert_eq "  e o alvo anterior NAO foi (re)gravado" "<ausente>" "$([ -f "$PREV" ] && cat "$PREV" || echo '<ausente>')"

echo "── 11. bypass DELIBERADO: funciona, e e barulhento ──"
: > "$NOTIFY_LOG"
run_win ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 -- swap
assert_eq "swap com ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 -> rc=0" "0" "$RC"
assert_has "  o log grita IGNORADO" "$OUT" "IGNORADO"
assert_has "  e o notify de prioridade 4 saiu" "$(cat "$NOTIFY_LOG")" "-p 4"
assert_eq "  symlink trocado (era deliberado)" "$LIBEXEC/gc-fixture" "$(readlink "$GCLINK")"
run_win -- rollback
assert_eq "  e o rollback do bypass tambem funciona" "$WORK/old-gc" "$(readlink "$GCLINK")"

echo "── 12. build SEM rede: nada e compilado (sem backup nada nasce) ──"
rm -f "$LIBEXEC/gc-fixture"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
run_win -- build --force
assert_eq "remoto inalcancavel -> build rc=1" "1" "$RC"
assert_has "  diz BUILD NAO INICIADO" "$OUT" "BUILD NAO INICIADO"
assert_eq "  e NENHUM binario foi produzido" "no" "$([ -e "$LIBEXEC/gc-fixture" ] && echo yes || echo no)"
git -C "$E" remote set-url origin "$FX_REMOTE"

echo "── 13. swap SEM rede e sem prova -> recusa (fail-closed), com o bypass no aviso ──"
fx_fake_gc "$LIBEXEC/gc-fixture" "$(short "$C_LOCAL")"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
run_win -- swap
assert_eq "rede fora + commit so-local -> rc=1" "1" "$RC"
assert_has "  aponta o bypass" "$OUT" "ENGINE_WINDOW_SKIP_BACKUP_CHECK=1"
assert_eq "  symlink intacto" "$WORK/old-gc" "$(readlink "$GCLINK")"
git -C "$E" remote set-url origin "$FX_REMOTE"

echo "── 14. arm: so arma com a fonte ja empurrada (o push acontece com humano por perto, nao no pos-boot) ──"
printf 'sujeira\n' >> "$WT/f.txt"
run_win -- arm
assert_eq "arm com worktree sujo -> rc=1" "1" "$RC"
assert_has "  diz 'nao armo'" "$OUT" "nao armo"
assert_eq "  e nenhum plist foi escrito" "no" "$([ -e "$WORK/home/Library/LaunchAgents/com.gascity.engine-window-postboot.plist" ] && echo yes || echo no)"
git -C "$WT" checkout -q -- f.txt

echo "── 15. subcomando desconhecido lista o novo 'push' no uso ──"
run_win -- nao-existe
assert_eq "rc=2" "2" "$RC"
assert_has "  o uso lista push" "$OUT" "push"

echo "── 16. ORDEM no codigo: o gate vem ANTES de qualquer mutacao (em ambos os swaps) ──"
first_line() { grep -nE "$2" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
G=$(first_line "$SWAP" 'eb_require_backed_up')
M=$(first_line "$SWAP" '^install -m|codesign -f|^ln -sfn|launchctl kickstart')
assert_eq "engine-window-swap.sh: gate (linha $G) antes da 1a mutacao (linha $M)" "yes" "$([ -n "$G" ] && [ -n "$M" ] && [ "$G" -lt "$M" ] && echo yes || echo no)"
SW_START=$(grep -n '^phase_swap()' "$RUN" | head -1 | cut -d: -f1)
GS=$(awk -v s="$SW_START" 'NR>s && /eb_require_backed_up/ {print NR; exit}' "$RUN")
LS=$(awk -v s="$SW_START" 'NR>s && /ln -sfn "\$out" "\$SYMLINK"/ {print NR; exit}' "$RUN")
assert_eq "engine-window-run.sh: gate do swap (linha $GS) antes do 'ln -sfn' (linha $LS)" "yes" "$([ -n "$GS" ] && [ -n "$LS" ] && [ "$GS" -lt "$LS" ] && echo yes || echo no)"
BLD_START=$(grep -n '^phase_build()' "$RUN" | head -1 | cut -d: -f1)
GP=$(awk -v s="$BLD_START" 'NR>s && /ensure_backed_up/ {print NR; exit}' "$RUN")
MK=$(awk -v s="$BLD_START" 'NR>s && /make build/ {print NR; exit}' "$RUN")
assert_eq "engine-window-run.sh: push do build (linha $GP) antes do 'make build' (linha $MK)" "yes" "$([ -n "$GP" ] && [ -n "$MK" ] && [ "$GP" -lt "$MK" ] && echo yes || echo no)"
RB_START=$(grep -n '^phase_rollback()' "$RUN" | head -1 | cut -d: -f1)
RB=$(awk -v s="$RB_START" 'NR>s && /^}/ {print NR; exit}' "$RUN")
RB_GATE=$(awk -v s="$RB_START" -v e="$RB" 'NR>s && NR<e && /eb_require_backed_up|ensure_backed_up/ {print NR; exit}' "$RUN")
assert_eq "engine-window-run.sh: o rollback NAO passa por gate nenhum" "" "$RB_GATE"

echo "── 17. o symlink VIVO da cidade nao foi tocado por nenhum teste ──"
LIVE_AFTER=$(readlink "$LIVE_LINK" 2>/dev/null || echo "<sem-symlink>")
assert_eq "readlink $LIVE_LINK igual antes e depois" "$LIVE_BEFORE" "$LIVE_AFTER"

fx_finish
