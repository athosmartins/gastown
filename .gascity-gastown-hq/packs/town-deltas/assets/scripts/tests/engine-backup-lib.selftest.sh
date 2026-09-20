#!/usr/bin/env bash
# engine-backup-lib.selftest.sh (ga-ta2w6r)
#
# Roda a lib REAL (nao uma reimplementacao) contra repos git descartaveis: um
# "engine" com origin apontando pra um repo bare local. Git roda de verdade; os
# estados OK/MISSING/ORPHAN/UNKNOWN saem de refs reais, nao de mocks. O foco sao
# as regras de HONESTIDADE que o incidente de 20/09/2026 ensinou:
#   * fetch que falhou nunca vira MISSING/ORPHAN (sem visao fresca do remoto,
#     "nao achei" nao prova "nao existe");
#   * ref velho de um branch apagado no remoto nao pode fingir backup (--prune);
#   * push so vale com o EFEITO verificado (rc=0 do git push nao basta);
#   * nunca force-push.
# Exit 0 iff toda assercao vale.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ENGINE_BACKUP_LIB_UNDER_TEST: so pra o teste de MUTACAO (rodar o selftest contra
# uma copia da lib com um comportamento neutralizado e ver a assercao certa cair).
LIB="${ENGINE_BACKUP_LIB_UNDER_TEST:-$SELF_DIR/../lib/engine-backup-lib.sh}"
# shellcheck source=engine-backup-fixture.sh
. "$SELF_DIR/engine-backup-fixture.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fx_init "$WORK"
E="$FX_ENGINE"

echo "── 1. sintaxe: a lib tem que carregar no bash 3.2 (macOS /bin/bash) E no bash do PATH ──"
for B in /bin/bash "$(command -v bash)"; do
    if "$B" -n "$LIB"; then ok "bash -n OK em $B ($("$B" -c 'echo $BASH_VERSION'))"; else bad "bash -n FALHOU em $B"; fi
done

# shellcheck source=../lib/engine-backup-lib.sh
. "$LIB"
EB_RETRY_SLEEP_S=0
EB_PUSH_TRIES=2
EB_FETCH_TIMEOUT_S=30

echo "── 2. eb_binary_commit: le o stamp DO BINARIO (main.commit / main.Build) ──"
fx_fake_gc "$WORK/gc1" "4f4837703-dirty"
assert_eq "gc: '4f4837703-dirty' -> so o hex (o -dirty e do repo ERRADO, ignorado)" "4f4837703" "$(eb_binary_commit "$WORK/gc1" gc)"
fx_fake_gc "$WORK/gc2" "042e965f0-ga165vq"
assert_eq "gc: sufixo de rotulo manual '-ga165vq' cai fora" "042e965f0" "$(eb_binary_commit "$WORK/gc2" gc)"
fx_fake_gc_unstamped "$WORK/gc3"
eb_binary_commit "$WORK/gc3" gc >/dev/null 2>&1
assert_eq "gc sem stamp ('commit: unknown') -> rc=1, nunca um commit vazio a consultar" "1" "$?"
fx_fake_bd "$WORK/bd1" "861fd98b9" "664a12b0299ada37d152e8f1d21581a992d3a0bd"
assert_eq "bd: usa .build (861fd98b9), NAO .commit (664a12b0... e do repo errado)" "861fd98b9" "$(eb_binary_commit "$WORK/bd1" bd)"
eb_binary_commit "$WORK/nao-existe" gc >/dev/null 2>&1
assert_eq "binario inexistente -> rc=1" "1" "$?"
out3=$(/bin/bash -c '. "$1"; eb_binary_commit "$2" gc' _ "$LIB" "$WORK/gc1")
assert_eq "o mesmo parse sob bash 3.2" "4f4837703" "$out3"

echo "── 3. eb_backup_state: os quatro estados, com fetch que funciona ──"
C_PUSHED=$(git -C "$E" rev-parse HEAD)
git -C "$E" checkout -q -b feature
C_LOCAL=$(fx_commit "$E" "so-local")
eb_fetch_all "$E"
assert_eq "fetch ok" "ok" "$EB_FETCH_STATE"
st=$(eb_backup_state "$E" "$C_PUSHED")
assert_eq "commit empurrado -> OK" "OK" "${st%%|*}"
assert_lacks "  visao fresca: sem a marca 'velhas'" "$st" "velhas"
st=$(eb_backup_state "$E" "$C_LOCAL")
assert_eq "commit so local -> MISSING (o incidente de 20/09)" "MISSING" "${st%%|*}"
st=$(eb_backup_state "$E" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
assert_eq "commit que nem existe no repo -> ORPHAN" "ORPHAN" "${st%%|*}"
st=$(/bin/bash -c '. "$1"; eb_fetch_all "$2"; eb_backup_state "$2" "$3"' _ "$LIB" "$E" "$C_LOCAL")
assert_eq "o mesmo MISSING sob bash 3.2" "MISSING" "${st%%|*}"

echo "── 4. um DESCENDENTE empurrado cobre o ancestral (git branch --contains) ──"
C_MID=$(fx_commit "$E" "meio")
C_TOP=$(fx_commit "$E" "topo")
git -C "$E" push -q origin "feature:refs/heads/so-o-topo"
eb_fetch_all "$E"
st=$(eb_backup_state "$E" "$C_MID")
assert_eq "so o topo foi empurrado; o commit do meio -> OK" "OK" "${st%%|*}"
assert_has "  e o detalhe cita o ref remoto" "$st" "origin/so-o-topo"

echo "── 5. --prune: branch APAGADO no remoto nao pode fingir backup ──"
git -C "$FX_REMOTE" branch -q -D so-o-topo
eb_fetch_all "$E"
st=$(eb_backup_state "$E" "$C_MID")
assert_eq "ref velho sumiu apos o fetch --prune -> MISSING (sem --prune daria OK falso)" "MISSING" "${st%%|*}"

echo "── 6. fetch FALHOU: honestidade (nunca MISSING/ORPHAN sem visao fresca) ──"
git -C "$E" push -q origin "main:main"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
eb_fetch_all "$E"
assert_eq "fetch contra remoto inexistente -> failed" "failed" "$EB_FETCH_STATE"
st=$(eb_backup_state "$E" "$C_PUSHED")
assert_eq "evidencia positiva ainda vale (main foi empurrado antes) -> OK" "OK" "${st%%|*}"
assert_has "  mas marcado como possivelmente velho" "$st" "velhas"
st=$(eb_backup_state "$E" "$C_LOCAL")
assert_eq "commit so-local SEM fetch confiavel -> UNKNOWN, NAO MISSING" "UNKNOWN" "${st%%|*}"
st=$(eb_backup_state "$E" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
assert_eq "commit inexistente SEM fetch confiavel -> UNKNOWN, NAO ORPHAN" "UNKNOWN" "${st%%|*}"
EB_NO_FETCH=1 eb_fetch_all "$E"
assert_eq "EB_NO_FETCH=1 -> skipped" "skipped" "$EB_FETCH_STATE"
st=$(eb_backup_state "$E" "$C_LOCAL")
assert_eq "modo sem fetch: so-local tambem e UNKNOWN (nunca acusa sem visao fresca)" "UNKNOWN" "${st%%|*}"
git -C "$E" remote set-url origin "$FX_REMOTE"

echo "── 7. eb_push_branch: empurra sem force e VERIFICA o efeito ──"
git -C "$E" worktree add -q "$WORK/wt1" -b consolidated/engine-window-X main
C_W=$(fx_commit "$WORK/wt1" "janela-X")
out=$(eb_push_branch "$WORK/wt1" consolidated/engine-window-X origin 2>&1); rc=$?
assert_eq "branch nao empurrado -> push OK (rc=0)" "0" "$rc"
assert_eq "  o remoto REALMENTE tem o commit (lido no repo bare, nao no retorno do push)" "$C_W" "$(git -C "$FX_REMOTE" rev-parse refs/heads/consolidated/engine-window-X)"
git -C "$WORK/wt1" commit -q --amend -m "historia reescrita"
out=$(eb_push_branch "$WORK/wt1" consolidated/engine-window-X origin 2>&1); rc=$?
assert_eq "historia divergente (amend) -> recusa (rc=1)" "1" "$rc"
assert_has "  diz que NAO faz force-push" "$out" "NAO faco force-push"
assert_eq "  e o remoto ficou INTACTO (nunca forcou)" "$C_W" "$(git -C "$FX_REMOTE" rev-parse refs/heads/consolidated/engine-window-X)"
out=$(eb_push_branch "$WORK/wt1" branch-que-nao-existe origin 2>&1); rc=$?
assert_eq "branch inexistente -> rc=1" "1" "$rc"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
out=$(eb_push_branch "$WORK/wt1" consolidated/engine-window-X origin 2>&1); rc=$?
assert_eq "remoto inalcancavel -> rc=1 apos as tentativas" "1" "$rc"
assert_has "  registra a tentativa 2/2" "$out" "tentativa 2/2"
git -C "$E" remote set-url origin "$FX_REMOTE"

echo "── 8. push que retorna 0 mas NAO pousou nada (o rc mente) ──"
git -C "$E" worktree add -q "$WORK/wt2" -b consolidated/engine-window-Y main
fx_commit "$WORK/wt2" "janela-Y" >/dev/null
REAL_GIT=$(command -v git)
mkdir -p "$WORK/shim"
cat > "$WORK/shim/git" <<EOF
#!/bin/sh
# finge que o push deu certo e nao faz nada
for a in "\$@"; do [ "\$a" = push ] && exit 0; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$WORK/shim/git"
out=$(PATH="$WORK/shim:$PATH" eb_push_branch "$WORK/wt2" consolidated/engine-window-Y origin 2>&1); rc=$?
assert_eq "push com rc=0 sem efeito -> a lib recusa (rc=1)" "1" "$rc"
assert_has "  explica que o commit NAO aparece em remoto nenhum" "$out" "NAO aparece"
assert_eq "  e de fato o remoto nao tem o branch" "" "$(git -C "$FX_REMOTE" for-each-ref refs/heads/consolidated/engine-window-Y)"

echo "── 9. eb_require_backed_up: o gate dos swaps (fail-closed) ──"
# commit novo so-local, e um empurrado, pra estampar nos binarios de mentira
git -C "$E" checkout -q main
C_OK=$(git -C "$E" rev-parse HEAD)
git -C "$E" checkout -q -b gate-case
C_BAD=$(fx_commit "$E" "gate-so-local")
fx_fake_gc "$WORK/gc-ok" "$(printf '%.9s' "$C_OK")"
fx_fake_gc "$WORK/gc-bad" "$(printf '%.9s' "$C_BAD")-dirty"
fx_fake_gc "$WORK/gc-orphan" "deadbeef1"
fx_fake_gc_unstamped "$WORK/gc-none"
out=$(eb_require_backed_up "$WORK/gc-ok" "$E" gc gc-ok 2>&1); rc=$?
assert_eq "binario de commit empurrado -> libera (rc=0)" "0" "$rc"
out=$(eb_require_backed_up "$WORK/gc-bad" "$E" gc gc-bad 2>&1); rc=$?
assert_eq "binario de commit so-local -> RECUSA (rc=1)" "1" "$rc"
assert_has "  diz que nenhum remoto contem" "$out" "NENHUM remoto contem"
assert_has "  e diz O QUE empurrar (o branch que contem o commit)" "$out" "push origin gate-case"
out=$(eb_require_backed_up "$WORK/gc-orphan" "$E" gc gc-orphan 2>&1); rc=$?
assert_eq "binario de commit que nao existe no repo -> recusa" "1" "$rc"
out=$(eb_require_backed_up "$WORK/gc-none" "$E" gc gc-none 2>&1); rc=$?
assert_eq "binario sem stamp -> recusa" "1" "$rc"
assert_has "  explica que nao da pra provar" "$out" "nao da pra provar"
git -C "$E" remote set-url origin "$WORK/nao-existe.git"
out=$(eb_require_backed_up "$WORK/gc-bad" "$E" gc gc-bad 2>&1); rc=$?
assert_eq "rede fora + sem prova -> recusa (fail-closed, nao 'provavelmente empurrado')" "1" "$rc"
assert_has "  e aponta o bypass deliberado" "$out" "ENGINE_WINDOW_SKIP_BACKUP_CHECK=1"
git -C "$E" remote set-url origin "$FX_REMOTE"

mkdir -p "$WORK/fakebin"
fx_fake_notify "$WORK/fakebin/notify" "$WORK/notify.log"
: > "$WORK/notify.log"
out=$(PATH="$WORK/fakebin:$PATH" ENGINE_WINDOW_SKIP_BACKUP_CHECK=1 eb_require_backed_up "$WORK/gc-bad" "$E" gc gc-bad 2>&1); rc=$?
assert_eq "bypass deliberado -> libera (rc=0)" "0" "$rc"
assert_has "  mas BARULHENTO no log" "$out" "IGNORADO"
assert_has "  e dispara notify de prioridade alta" "$(cat "$WORK/notify.log")" "-p 4"

echo "── 10. invariantes estaticos da lib ──"
FORCE=$(grep -nE 'push[^#]*(--force|-f |\+refs|--mirror|--delete)' "$LIB" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [ -z "$FORCE" ]; then ok "nenhuma linha de codigo da lib faz force/mirror/delete no push"; else bad "achei push perigoso: $FORCE"; fi
# Um fetch/push pendurado segura o lock do guard horario pra sempre (todas as execucoes
# seguintes saem "outra instancia rodando"). `timeout` pode nao existir no PATH do
# order; o limite de baixa velocidade do proprio git nao depende dele.
LOWSPEED=$(grep -vE '^[[:space:]]*#' "$LIB" | grep -c 'http.lowSpeedLimit' || true)
assert_eq "fetch E push carregam http.lowSpeedLimit (transferencia parada aborta sem depender de timeout)" "2" "$LOWSPEED"

fx_finish
