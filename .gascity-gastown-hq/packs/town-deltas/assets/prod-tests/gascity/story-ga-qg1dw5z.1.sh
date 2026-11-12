#!/usr/bin/env bash
# prod-tests/gascity/story-ga-qg1dw5z.1.sh — prod test para ga-qg1dw5z.1: Hetzner trava 1 (dado pessoal só no usuário `dados`, só enquanto o build roda).
# O que esta fatia ENTREGA é código versionado (instalador de root, wrapper, canal do mini, varredura, prova) e o runbook; a INSTALAÇÃO no nó é um passo de root separado (docs/runbooks/hetzner-dados.md).
# Por isso o teste confere a árvore viva: arquivos presentes e executáveis, sintaxe, e as garantias do contrato no TEXTO do que será instalado (sem curinga no sudoers, chave de root com restrict, tmpfs
# noexec/nosuid/nodev, recusa de swap e de staging fora do tmpfs, `dados` com shell real). Hermético: não fala com o nó, não chama gc/bd, não toca em .gc/. As baterias (119 + 73 casos e os mutantes) são a
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
# vazio (instalador sem linha fora de comentário) ou falhou (ilegível) → recusa; só "li e não há regra larga" libera (contagem, não `grep -q` em pipe: SIGPIPE sob pipefail esconderia o achado)
body=$(grep -v '^#' "$INST") || fail "instalador ilegível ou vazio: $INST"
n=$(printf '%s\n' "$body" | grep -c -E 'ALL=\(dados\)|NOPASSWD: ALL')
[[ "$n" == 0 ]] || fail "instalador: sudoers com (dados) ALL / NOPASSWD: ALL ($n linhas)"
log "instalador: shell real, senha travada, chave restrict, arquivo de root, sudoers por entrypoint e validado, tmpfs noexec/nosuid/nodev ✓"

# ── wrapper: recusa antes de rodar, sem rede, sem privilégio, apaga o dado
has "$RUN" 'fail stage-nao-e-tmpfs'                                || fail "wrapper: roda com staging fora do tmpfs"
has "$RUN" 'fail swap-ligada-ou-ilegivel'                          || fail "wrapper: roda com swap ligada"
has "$RUN" 'usage fora-da-lista'                                   || fail "wrapper: não recusa entrypoint fora da lista"
has "$RUN" 'setpriv .*--no-new-privs'                              || fail "wrapper: sem --no-new-privs"
has "$RUN" 'env -i'                                                || fail "wrapper: não limpa o ambiente"
has "$RUN" 'GTD-WIPE: falhou'                                      || fail "wrapper: apagar que falha não é reportado"
has "$RUN" 'reject'                                                || fail "wrapper: netns sem a regra reject"
log "wrapper: tmpfs, sem swap, lista exata, no-new-privs, env -i, apagar confirmado, netns sem saída ✓"

# ── canal do mini e varredura
has "$ING" 'no link-simbolico-ou-ilegivel 65'                      || fail "ingest: link simbólico no tar não é recusado"
has "$ING" 'no stage-nao-e-tmpfs 98'                               || fail "ingest: grava dado fora do tmpfs"
has "$SWP" 'NAO-CONSEGUI'                                          || fail "varredura: não distingue 'não consegui' de 'limpo'"
has "$SWP" 'cant "stage-nao-e-tmpfs'                               || fail "varredura: não acusa staging fora do tmpfs"
log "ingest e varredura ✓"

# ── runbook: contrato, instalação, prova, ordem com a trava 2
for key in '## Contents' 'Contrato (o que a trava 3 confere)' 'Instalação (precisa de root, uma vez)' 'Prova (como runner)' 'Ordem com a trava 2' 'hetzner-dados-install.sh' 'hetzner-dados-prove.sh' 'GTD-CHECK' 'GTD-PROVE' 'NAO-CONSEGUI' '/srv/gtdados' 'gt-dados-run'; do
  grep -q -F -- "$key" "$RUNBOOK" || fail "runbook não descreve '$key'"
done
log "runbook ✓"

log "PASS"
exit 0
