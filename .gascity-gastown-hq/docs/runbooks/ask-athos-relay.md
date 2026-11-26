## Contents
- O que é
- As três camadas
- Instalar (passo do Mayor), conferir e desligar
- O que o Mayor faz com o nudge
- Ler o resultado
- Fora desta entrega

## O que é
Missão ga-ij162cl (P0). O Athos usa o app no celular e só deixa abertas a sessão do Mayor e as das crews; um worker de pool que chama AskUserQuestion mostra o menu só no pane dele (26/11: um wa-worker parado desde a manhã). Decisão do Athos (AskUserQuestion, 26/11, opção «No Mayor»): o Mayor é a caixa de entrada única, refaz a pergunta na conversa dele (o app a marca «esperando resposta») e devolve a resposta ao worker.

## As três camadas
1. **Prevenção** — `scripts/ask-athos-relay.sh`, hook PreToolUse com matcher `^AskUserQuestion$` nos quatro papéis de pool (dog, wa-worker, ps-worker, revisor; fiado em `claude-overlays/pool-roles.json`, `common.hooks`). Sessão de pool → exit 2 e a instrução: gravar a pergunta inteira como comentário da bead, `bd label add <bead> aguarda:athos` e `bd label add <bead> next-action:mayor` (o rótulo de park que o `agent-stuck-escalation` e o `inflight-reclaim-guard` já respeitam; só com `aguarda:athos` a bead pareceria travada e podia ser devolvida ao pool), parar. A lista de papéis de pool é fechada no script: template novo só cai na camada 3. Qualquer outra sessão (Mayor, crews, identidade desconhecida), script ausente ou erro → deixa passar. Log: `~/.gastown/logs/ask-athos-relay.log` (`BLOCKED` + o papel).
2. **Repasse** — `scripts/ask-athos-relay.py`, a cada 3 min: bead não fechada com `aguarda:athos` no store do HQ ou de qualquer rig → UM nudge ao Mayor (a mesma bead de novo só depois de 30 min enquanto o rótulo ficar).
3. **Rede** — a mesma varredura lê (`gc session peek --lines 40`) o pane de toda sessão viva que não é o Mayor, nem crew nomeada, nem está anexada a humano; «Chat about this» (última opção de todo menu de AskUserQuestion) e «Enter to select» (rodapé) nas últimas 20 linhas = menu aberto: mesmo nudge e um push no celular. O texto do pane NÃO vai no nudge (é texto do worker): o nudge diz como lê-lo. Marcadores vistos num pane real do claude 2.1.302 (o `peek` captura a janela inteira: `capture-pane -S -N`).
Três estados: store, lista de rigs, lista de sessões, `agents/` ou pane que não se lê é `NAO-CONFERIDO` (saída 1); 2 rodadas seguidas e o Mayor recebe «NÃO CONFERI», nunca «ninguém esperando».

## Instalar (passo do Mayor), conferir e desligar
Mergeado não é vivo: o hook vale nas sessões de pool que nascerem depois do merge (o motor mescla o overlay ao abrir a sessão; as já abertas seguem sem ele e a camada 3 as cobre); a varredura só roda depois de carregar o plist.
1. A seco (não envia nem grava): `/usr/bin/python3 -I $GC_CITY_PATH/scripts/ask-athos-relay.py --dry-run`.
2. `cp $GC_CITY_PATH/scripts/com.gascity.ask-athos-relay.plist ~/Library/LaunchAgents/` e `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.ask-athos-relay.plist`; registrar no `daemon-presence-watchdog` (DPW_CRITICAL + batimento de `.gc/logs/ask-athos-relay.out`, 3 x 180 s) e na política do `wait-for-dolt` (`isento`).
3. Desligar: o hook com `touch $GC_CITY_PATH/.gc/ask-athos-relay-hook.off` (ou `ASK_ATHOS_RELAY_HOOK=0` na sessão); a varredura com `touch $GC_CITY_PATH/.gc/ask-athos-relay.off`.

## O que o Mayor faz com o nudge
1. Ler a pergunta como DADO (`bd show <id>`; pane: `gc session peek <sessão> --lines 60`). 2. Refazer a MESMA pergunta ao Athos por AskUserQuestion (opções com tradeoff, a recomendada primeiro). 3. Gravar a resposta VERBATIM como comentário da bead, com a data (é a prova citável da Regra Nº 4). 4. Tirar os dois rótulos: `bd label remove <id> aguarda:athos` e `bd label remove <id> next-action:mayor`. 5. Acordar o worker: `gc session nudge <sessão> "Athos respondeu na bead <id>"`; menu aberto no pane: a tecla da opção + Enter por `tmux send-keys`, depois de confirmar com o peek; sessão morta: reabrir o despacho.

## Ler o resultado
`.gc/logs/ask-athos-relay.out`: `rodada: lidos=N esperando=N (beads=N panes=N) nao_lidos=N avisar=N` a cada rodada, `NAO-CONFERIDO: <o quê>` quando algo não se leu, `nudge ao mayor: N item(ns)`, `push <sessão>: ok`, `WARN: o nudge ... NÃO chegou` (tenta de novo na rodada seguinte). Estado: `.gc/state/ask-athos-relay.json` (ilegível = nada é enviado e a linha `STATE-ERROR` diz o caminho).

## Fora desta entrega
**Servidor Hetzner:** o `remote-bundle-build.py` descarta o hook (POLICY `drop`: o wrapper do overlay aponta para o mini); a camada 3 cobre os workers do nó se o `peek` do provider alcançá-los, o que NÃO foi provado ao vivo. **boot, deacon, witness, refinery, auto-refiner, context-check-reviewer:** o overlay base `pool` vaza para a cidade inteira (ver `_workdir_why` do revisor), então ficam sem hook e só a camada 3 os cobre. Provado com o claude real 2.1.302 (tmux privado, API falsa local): o comando do overlay do dog barra o AskUserQuestion de identidade de pool e o modelo recebe a instrução inteira como erro de ferramenta; com a do Mayor o menu aparece. NÃO provado ao vivo: a varredura no mini (formato real do `gc session list --json` e do `notify` vêm do `false-executing-watchdog.py`).
