#!/bin/bash
# ask-athos-relay.sh (ga-ij162cl, camada 1): hook PreToolUse:AskUserQuestion dos papéis de POOL (dog, wa-worker, ps-worker, revisores; fiado em claude-overlays/pool-roles.json).
# O menu de AskUserQuestion de um worker de pool só existe no pane dele, e o Athos só abre o Mayor e as crews: a pergunta ficava invisível (26/11: um wa-worker parado desde a manhã).
# Em sessão de pool: exit 2 + «ask-athos-relay: BLOCKED …» no stderr (o claude devolve o texto ao modelo: gravar a pergunta na bead com aguarda:athos e parar). A varredura
# ask-athos-relay.py leva a bead ao Mayor, que refaz a pergunta ao Athos no app. Qualquer outra sessão, ou identidade que não conheço: exit 0. Um hook que barra a pergunta do Mayor
# é pior que o vazamento, e o vazamento a camada 3 pega. Desligar: ASK_ATHOS_RELAY_HOOK=0 (esta sessão) ou touch $GC_CITY_PATH/.gc/ask-athos-relay-hook.off.
# Contrato e leitura do log: docs/runbooks/ask-athos-relay.md
cat >/dev/null 2>&1 || true
[ "${ASK_ATHOS_RELAY_HOOK:-1}" = 0 ] && exit 0
# vazio (arquivo ausente) → o hook segue LIGADO; falhou (sem GC_CITY_PATH, sem permissão) → idem: um -e que não consegue testar lê «ausente», e o guarda continua de pé
[ -e "${GC_CITY_PATH:-/nonexistent}/.gc/ask-athos-relay-hook.off" ] && exit 0
# decide pela PRIMEIRA que existe (o template é o que o engine garante; agente e alias só entram se ele faltar), nunca por qualquer uma das três: identidade incoerente passa
# vazio (nenhum GC_*) → não sei quem é e deixa passar; falhou/ilegível (valor que não é nome de pool conhecido) → idem
who=${GC_TEMPLATE:-${GC_AGENT:-${GC_ALIAS:-}}}
who=${who##*/}
who=${who#gastown.}
case "$who" in
  dog|dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*|kimi-worker|kimi-worker-*|gate-reviewer|gate-reviewer-*|refino-gate-reviewer|refino-gate-reviewer-*|claude-headless|claude-headless-*) ;;
  *) exit 0 ;;
esac
L="${ASK_ATHOS_RELAY_LOG:-${HOME:-/tmp}/.gastown/logs/ask-athos-relay.log}"
{ mkdir -p "${L%/*}" && printf '%s\tBLOCKED\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$who" >> "$L"; } 2>/dev/null
cat >&2 <<EOF
ask-athos-relay: BLOCKED — AskUserQuestion não vale em sessão de pool ($who): o menu só existe neste pane, o Athos só abre o Mayor e as crews, e a pergunta ficaria invisível (ga-ij162cl). NÃO repita a chamada. Faça agora:
1. Grave a pergunta INTEIRA como comentário da bead que você executa (contexto em bullets curtos, opções numeradas com o tradeoff de cada uma, a SUA recomendação como 1ª, links): bd comment <bead> "<pergunta>".
2. Marque a bead com os DOIS rótulos (o 2º é o «turno do Mayor» que os vigias respeitam; sem ele a bead parece travada): bd label add <bead> aguarda:athos && bd label add <bead> next-action:mayor
3. Pare e termine o turno, sem trabalhar em cima de palpite: o Mayor refaz a MESMA pergunta ao Athos no app, grava a resposta na bead, tira o rótulo e te acorda por nudge; aí releia bd show <bead> e siga.
Sem bead atribuída: gc session nudge mayor "<pergunta em opções 1/2/3, a recomendada primeiro>".
EOF
exit 2
