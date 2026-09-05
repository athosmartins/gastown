#!/bin/bash
# crew-pushguard-check.sh — detecta clone de crew cujo pre-push NÃO RODA
# (wa-a4np9). Detection-only: NÃO conserta, só grita.
#
# POR QUE ISTO EXISTE
# Em 04/09 descobrimos que 4 clones de crew estavam há ~8 SEMANAS sem o guard
# que bloqueia push direto na main — e ninguém percebeu, porque a falha é
# silenciosa por construção: `core.hooksPath` aponta pra um diretório cujo
# `pre-push` é symlink morto, o git substitui `.git/hooks` por esse caminho,
# não acha o hook e NÃO RODA NADA, sem erro. Um crew pousou commit em main sem
# revisão por causa disso.
#
# A ARMADILHA QUE ESTE CHECK EXISTE PRA EVITAR (batista-wa, 04/09)
# Havia DOIS formatos de quebra, e um conserto/checagem genérico só pega um:
#   - hooksPath aponta pra FORA (alvo inexistente)      -> `unset` resolve
#   - hooksPath aponta pro lugar CERTO e o ARQUIVO lá é que está morto
#     (symlink pra worktree apagada)                    -> `unset` NÃO resolve
# Por isso este check NUNCA olha o VALOR da config. Ele resolve o diretório
# efetivo de hooks e testa se o ARQUIVO pre-push existe seguindo symlink
# (`test -e`), que é a única pergunta que corresponde ao que o git faz.
# Verificar config e concluir "está tudo certo" foi exatamente o modo de falha
# que deixou a mila quebrada parecendo consertada.
#
# E NÃO PODE DEPENDER DO HOOK PRA DENUNCIAR QUE O HOOK NÃO RODA — seria
# circular. Por isso isto é um sweep externo, periódico, por clone.

set -uo pipefail

WA_REAL_ROOT="/Users/athos/gt/whatsapp_automation"
WA_ROOT="${WA_ROOT:-$WA_REAL_ROOT}"
CREW_DIR="${WA_ROOT}/crew"
HOOK_NAME="pre-push"

# ALERTA SÓ QUANDO ESTÁ OLHANDO O RIG DE VERDADE (achado 05/09, batista-wa).
# Validar este script contra fixture é o comportamento CERTO — e na primeira
# validação independente ele mandou 2 mails reais pro Mayor sobre clones falsos
# ("caso_batista", "caso_mila") que só existiam num scratchpad. Um detector que
# suja o canal de alerta quando alguém o testa treina todo mundo a ignorar o
# canal, e — pior, agora que ele manda PUSH — poderia acordar o Athos às 3h da
# manhã por causa de um teste. Fixture reprova no stdout e no exit code, que é
# o que um teste precisa; mail e push ficam para o rig real.
ALERT_ENABLED=1
[ "$WA_ROOT" = "$WA_REAL_ROOT" ] || ALERT_ENABLED=0

BROKEN=""
CHECKED=0

[ -d "$CREW_DIR" ] || { echo "crew-pushguard-check: sem $CREW_DIR — nada a checar"; exit 0; }

for clone in "$CREW_DIR"/*/; do
    [ -d "${clone}.git" ] || continue          # não é clone git — pula
    name=$(basename "$clone")

    # Diretório EFETIVO de hooks, exatamente como o git resolve:
    # core.hooksPath quando setado (relativo ao clone se não for absoluto),
    # senão .git/hooks.
    hp=$(git -C "$clone" config --get core.hooksPath 2>/dev/null || true)
    if [ -z "$hp" ]; then
        hooks_dir="${clone}.git/hooks"
    elif [ "${hp#/}" != "$hp" ]; then
        hooks_dir="$hp"                         # absoluto
    else
        hooks_dir="${clone}${hp}"               # relativo ao clone
    fi

    CHECKED=$((CHECKED + 1))

    # A ÚNICA pergunta que importa: o arquivo que o git vai executar EXISTE?
    # -e segue symlink de propósito — symlink morto tem que reprovar.
    if [ ! -e "${hooks_dir}/${HOOK_NAME}" ]; then
        BROKEN="${BROKEN}${BROKEN:+, }${name} (hooks_dir=${hooks_dir})"
        continue
    fi
    # Existe mas não é executável = também não roda.
    if [ ! -x "${hooks_dir}/${HOOK_NAME}" ]; then
        BROKEN="${BROKEN}${BROKEN:+, }${name} (não-executável: ${hooks_dir}/${HOOK_NAME})"
    fi
done

if [ -z "$BROKEN" ]; then
    echo "crew-pushguard-check: OK — ${CHECKED} clone(s), todos com ${HOOK_NAME} resolvendo"
    exit 0
fi

echo "crew-pushguard-check: GUARD AUSENTE em ${BROKEN}"

# PUSH pro Athos — NÃO só mail. Um guard ausente é falha de produção, e mail
# depende de existir sessão do Mayor viva pra ler; se os clones quebrarem às 3h
# da manhã o alerta espera até alguém acordar (a mesma dependência de atenção
# humana que deixou 4 clones quebrados por 8 semanas — batista-wa, 04/09).
#
# ⚠️ A FRASE "job falhou" É CARGA, NÃO ENFEITE. `scripts/notify` decide push vs
# digest por ALLOWLIST DE VOCABULÁRIO, não por prioridade: `-p 5` sozinho cai no
# digest EM SILÊNCIO. Medido aqui antes de confiar (NOTIFY_ROUTE_TEST=1):
#   com "job falhou"  -> push
#   sem a frase       -> digest
# Se editar esta mensagem, RE-MEÇA. Não presuma que continua roteando.
if [ "$ALERT_ENABLED" = "1" ] && command -v notify >/dev/null 2>&1; then
    notify -t "crew-pushguard-check" -p 5 \
        "job falhou: guard de push ausente em clone de crew (${BROKEN}) — push direto na main passa batido nesses clones. Ver wa-a4np9." \
        >/dev/null 2>&1 || true
fi

# Alerta por mail também (trilha durável pro Mayor, complementar ao push).
if [ "$ALERT_ENABLED" = "1" ] && command -v gc >/dev/null 2>&1; then
    gc mail send mayor/ --from controller \
        -s "Guard de push ausente em clone de crew (wa-a4np9)" \
        -m "Clone(s) de crew SEM pre-push que resolva — push direto na main passa batido nesses clones:

${BROKEN}

Checado: ${CHECKED} clone(s) em ${CREW_DIR}.

Como este check decide (e por que não olha a config): ele resolve o diretório
efetivo de hooks (core.hooksPath, ou .git/hooks) e testa se o ARQUIVO pre-push
existe SEGUINDO symlink. Config apontando pro lugar certo com arquivo morto
dentro é justamente o caso que passa numa conferência de config e reprova aqui.

Conserto depende do formato da quebra:
  - hooksPath aponta pra fora / alvo inexistente -> git -C <clone> config --unset core.hooksPath
  - arquivo dentro do hooks_dir é symlink morto  -> recriar o symlink pro
    scripts/hooks/pre-push do PRÓPRIO clone
Depois, PROVE comportamentalmente (não pela config):
  echo 'refs/heads/main a refs/heads/main b' | (cd <clone> && ./.git/hooks/pre-push origin <url>)
deve imprimir 'BLOQUEADO'. Atenção: 'git push --dry-run' NÃO serve de prova
quando o branch está atrás — o remoto rejeita antes do hook rodar e o teste dá
falso-inconclusivo (medido 04/09 no clone do digo)." >/dev/null 2>&1 || true
fi

exit 1
