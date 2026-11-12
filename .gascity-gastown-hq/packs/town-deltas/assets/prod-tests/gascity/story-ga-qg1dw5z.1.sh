#!/usr/bin/env bash
# prod-tests/gascity/story-ga-qg1dw5z.1.sh — prod test para ga-qg1dw5z.1: Hetzner trava 1 (dado pessoal só no usuário `dados`, só enquanto o build roda).
# O que esta fatia ENTREGA é código versionado (instalador de root, wrapper, canal do mini, varredura, prova) e o runbook; a INSTALAÇÃO no nó é um passo de root separado (docs/runbooks/hetzner-dados.md).
# Por isso o teste confere a árvore viva: arquivos presentes e executáveis, sintaxe, e as garantias do contrato no TEXTO do que será instalado (sem curinga no sudoers, chave de root com restrict, tmpfs
# noexec/nosuid/nodev, recusa de swap e de staging fora do tmpfs, `dados` com shell real). Hermético: não fala com o nó, não chama gc/bd, não toca em .gc/. As baterias (242 + 118 casos e os mutantes) são a
# evidência do gate e rodam no nó Linux; aqui só se confere que existem.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
SC="$CITY/scripts"
RUNBOOK="$CITY/docs/runbooks/hetzner-dados.md"
log()  { echo "[prod-test:gascity ga-qg1dw5z.1] $*"; }
fail() { echo "[prod-test:gascity ga-qg1dw5z.1] FAIL: $*" >&2; exit 1; }

FILES=(install run ingest sweep synth prove)
for f in "${FILES[@]}"; do
  p="$SC/hetzner-dados-$f.sh"
  [[ -f "$p" ]] || fail "arquivo implantado ausente: $p"
  [[ -x "$p" ]] || fail "não é executável: $p"
  bash -n "$p" 2>/dev/null || fail "erro de sintaxe em $p"
done
for t in hetzner-dados.selftest.sh hetzner-dados-install.selftest.sh; do
  [[ -f "$SC/$t" ]] || fail "bateria ausente: $t"
  bash -n "$SC/$t" 2>/dev/null || fail "erro de sintaxe em $t"
done
[[ -f "$RUNBOOK" ]] || fail "runbook ausente: $RUNBOOK"
log "arquivos presentes, executáveis, sintaxe ok"

INST="$SC/hetzner-dados-install.sh"; RUN="$SC/hetzner-dados-run.sh"; ING="$SC/hetzner-dados-ingest.sh"; SWP="$SC/hetzner-dados-sweep.sh"
# vazio → grep rc 1 = a garantia não está no texto = FALHA; falhou/ilegível (rc 2) também falha: nunca "achei"
has() { grep -q -E -- "$2" "$1" 2>/dev/null; }

# ── instalador: as garantias que a trava 3 confere precisam estar no que será instalado
has "$INST" 'useradd -M -d "\$DHOME" -s /bin/bash -U'              || fail "instalador: dados sem shell real (nologin quebraria o forced command)"
has "$INST" 'usermod -L "\$DU"'                                    || fail "instalador: senha do dados não é travada"
has "$INST" 'restrict,command="%s/gt-dados-ingest"'                || fail "instalador: chave do mini sem restrict,command="
has "$INST" 'AuthorizedKeysFile %s/%s'                             || fail "instalador: dados não usa o arquivo de chaves de root"
has "$INST" 'visudo -cf "\$SUDOERS.new"'                           || fail "instalador: sudoers entra sem visudo -cf"
has "$INST" 'NOPASSWD: \$SBIN/gt-dados-run \$e"'                   || fail "instalador: sudoers não é uma linha por entrypoint"
has "$INST" 'noexec,nosuid,nodev,nofail 0 0 # gt-dados'            || fail "instalador: tmpfs sem noexec,nosuid,nodev,nofail"
has "$INST" 'sshd -t \|\| undo sshd-t'                             || fail "instalador: sshd recarrega sem 'sshd -t' (ou sem desfazer)"
has "$INST" 'opção sem valor'                                      || fail "instalador: opção sem valor gira para sempre"
has "$INST" 'die runner-ilegivel'                                  || fail "instalador: id do runner que falha vira 'fora do grupo'"
has "$INST" 'undo sshd-runner-ilegivel'                            || fail "instalador: sshd -T do runner que falha vira 'runner intacto'"
# vazio (instalador sem linha fora de comentário) ou falhou (ilegível) → recusa; só "li e não há regra larga" libera (contagem, não `grep -q` em pipe: SIGPIPE sob pipefail esconderia o achado)
body=$(grep -v '^#' "$INST") || fail "instalador ilegível ou vazio: $INST"
n=$(printf '%s\n' "$body" | grep -c -E 'ALL=\(dados\)|NOPASSWD: ALL')
[[ "$n" == 0 ]] || fail "instalador: sudoers com (dados) ALL / NOPASSWD: ALL ($n linhas)"
# o código de --code-dir vem do COMMIT (git archive), nunca da árvore de trabalho (rsync copiava arquivo ignorado e edição assume-unchanged); só comentário pode citar rsync
has "$INST" 'git -C "\$CODE" archive --format=tar "\$SHA"'         || fail "instalador: código de --code-dir não vem do commit (git archive)"
has "$INST" 'set -o pipefail'                                      || fail "instalador: git archive que morre no meio passaria pelo tar (sem pipefail)"
has "$INST" 'die "code-modo-inseguro'                              || fail "instalador: árvore de root extraída sem conferir modo (grupo/outros, setuid)"
nrs=$(grep -v '^#' "$INST" | grep -c 'rsync') || true
[[ "${nrs:-1}" == 0 ]] || fail "instalador: rsync da árvore de trabalho para a árvore de root ($nrs linhas)"
has "$INST" 'owned "\$AKDIR/\$DU" "root:\$DU 640"'                  || fail "instalador: --check não confere o grupo do arquivo de chaves"
log "instalador: shell real, senha travada, chave restrict, arquivo de root, sudoers por entrypoint e validado, tmpfs noexec/nosuid/nodev ✓"

# ── wrapper: recusa antes de rodar, sem rede, sem privilégio, apaga o dado
has "$RUN" 'fail stage-nao-e-tmpfs'                                || fail "wrapper: roda com staging fora do tmpfs"
has "$RUN" 'fail swap-ligada-ou-ilegivel'                          || fail "wrapper: roda com swap ligada"
has "$RUN" 'usage fora-da-lista'                                   || fail "wrapper: não recusa entrypoint fora da lista"
has "$RUN" 'setpriv .*--no-new-privs'                              || fail "wrapper: sem --no-new-privs"
has "$RUN" 'env -i'                                                || fail "wrapper: não limpa o ambiente"
has "$RUN" 'GTD-WIPE: falhou'                                      || fail "wrapper: apagar que falha não é reportado"
has "$RUN" 'reject'                                                || fail "wrapper: netns sem a regra reject"
has "$RUN" 'chown -h'                                              || fail "wrapper: root cria in/ e out/ sem chown -h (seguiria link do build)"
has "$RUN" 'fail stage-dirs'                                       || fail "wrapper: in/ ou out/ que virou link não é recusado"
has "$RUN" '\[ ! -L "\$STAGE/in" \]'                              || fail "wrapper: apagar in/ trocado por link viraria 'ok'"
# `install -d` como root SEGUE link simbólico do build e dá chown/chmod no alvo (dados → root); só comentário pode citá-lo (contagem, não `grep -q` em pipe)
nid=$(grep -v '^#' "$RUN" | grep -c -E '(^|[^-])install -d') || true
[[ "${nid:-1}" == 0 ]] || fail "wrapper: install -d como root em caminho do build ($nid linhas)"
log "wrapper: tmpfs, sem swap, lista exata, no-new-privs, env -i, apagar confirmado, netns sem saída ✓"

# ── canal do mini e varredura
has "$ING" 'no link-simbolico-ou-ilegivel 65'                      || fail "ingest: link simbólico no tar não é recusado"
has "$ING" 'no stage-nao-e-tmpfs 98'                               || fail "ingest: grava dado fora do tmpfs"
has "$ING" 'no put-sem-arquivos 67'                                || fail "ingest: put sem arquivo nenhum vira 'ok files=0'"
has "$ING" 'no stage-dirs 98'                                      || fail "ingest: in/ ou out/ trocado por link não é recusado (o dado iria para fora do tmpfs)"
has "$ING" 'no resultado-ilegivel 74'                              || fail "ingest: get com find que falha vira 'ausente'"
has "$SWP" 'cant awk-falhou'                                       || fail "varredura: awk que falha vira '0 processos vivos'"
has "$SWP" 'NAO-CONSEGUI'                                          || fail "varredura: não distingue 'não consegui' de 'limpo'"
has "$SWP" 'cant "stage-nao-e-tmpfs'                               || fail "varredura: não acusa staging fora do tmpfs"
has "$SWP" 'flock -w "\$LOCKWAIT" -E 75 8'                         || fail "varredura: não toma o lock do wrapper (um build no meio perderia o staging)"
has "$SWP" 'timeout -k 5 "\$SCANSECS" find'                        || fail "varredura: find sem prazo (no nó real a árvore do /tmp travou 40+ min sem escrever o log)"
has "$SWP" '-maxdepth 1'                                           || fail "varredura: /tmp inteiro em vez do 1º nível"
has "$SWP" 'chmod 0600 "\$LOCK"'                                  || fail "varredura: lock não é só de root (um usuário local o travaria e calaria a varredura)"
has "$RUN" 'chmod 0600 "\$LOCK"'                                  || fail "wrapper: lock não é só de root (um usuário local travaria todo build)"
has "$INST" 'timeout 900 systemctl start gt-dados-sweep.service \|\| die sweep-primeira' || fail "instalador: 1ª varredura sem prazo ou sem falhar alto"
log "ingest e varredura ✓"

# ── runbook: contrato, instalação, prova, ordem com a trava 2
for key in '## Contents' 'Contrato (o que a trava 3 confere)' 'Instalação (precisa de root, uma vez)' 'Prova (como runner)' 'Ordem com a trava 2' 'hetzner-dados-install.sh' 'hetzner-dados-prove.sh' 'GTD-CHECK' 'GTD-PROVE' 'NAO-CONSEGUI' '/srv/gtdados' 'gt-dados-run'; do
  grep -q -F -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

log "PASS"
exit 0
