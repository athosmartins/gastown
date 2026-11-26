## Contents
- Por que existe
- O que faz (e o que nunca faz)
- Instalar e ativar (ordem)
- Como conferir num reboot real
- Quando não digita, e os botões
- NÃO provado ao vivo
- As outras duas camadas

Missão ga-esorlre.12, camada 1 (ga-esorlre.13): depois de um reboot (ou de qualquer partida), o Mayor e cada crew nomeada recebem um **1º turno de verdade**, digitado no pane, mandando retomar a bead em andamento. Script: `scripts/boot-first-turn.py` · plist: `packs/town-deltas/assets/boot-first-turn.plist` · testes: `python3 -I scripts/test_boot_first_turn.py`.

## Por que existe
Noite de 25-26/11 (reboot 23:42): peter-wa e oracle-wa subiram em conversa nova e ficaram **6-8 h paradas no prompt**. Tudo que chega a uma sessão ociosa por `gc session nudge` (o aviso de retomada, 4 despachos do Pilot) vira «deferred reminder queued until a safe boundary»: só é entregue quando um turno começa, e a sessão ociosa não tem turno. O que acorda é só **input digitado no pane** (medido: 12/11, três crews paradas acordaram com um `--delivery immediate`; Mayor, ga-nrkh92: `tmux send-keys` acordou 3/3). Athos 26/11: «pecado capital, não pode acontecer em hipótese alguma».

## O que faz (e o que nunca faz)
A cada 60 s (launchd, `RunAtLoad`), para o Mayor e cada crew nomeada com sessão ativa:
- acha o **claude vivo** da sessão (`~/.claude/sessions/<pid>.json` + `ps`) e só age se ele subiu há **≤ 20 min** (`BFT_WINDOW_S`), está **ocioso há ≥ 120 s** (`BFT_IDLE_S`) e o **pane** (`tmux capture-pane`) é um prompt do Claude ocioso, **sem rascunho, sem diálogo, sem trabalho em segundo plano**;
- digita **uma** linha (`tmux send-keys -l`, depois `Enter` em outra chamada): `[ga-esorlre.13 primeiro turno do boot] … retome a bead em andamento <ids> e o último handoff; se não houver, pegue a próxima por prioridade …`. Os `<ids>` são as beads `in_progress` da sessão (nome tmux, alias ou incarnação anterior `<alias>-gawisp…`), lidas no store da cidade e no store do rig da crew; store ilegível não nomeia nada e a linha **não** diz «não há» (diz «a bead que estiver em andamento com você»);
- **uma vez por partida** do claude (registro = pid + hora de início: um pid reaproveitado depois de um reboot ganha a sua linha). Registro perdido: a nossa linha já no transcript desde o início do processo vale como feita.

Prova e falha (na passada seguinte): turno começou = registro `busy`/`waiting` ou status mudou depois da digitação, **ou** a linha aparece no transcript, **ou** o pane mostra trabalho, **ou** a conversa mudou. Sem prova em 90 s: **um** reenvio, só onde é seguro (pane ocioso e vazio → a linha de novo; **a nossa** linha parada na caixa de entrada → só o `Enter`; rascunho de pessoa, diálogo ou pane ilegível → nada). Sem prova 240 s depois do reenvio: `UNCONFIRMED` (log `ERROR`, linha no jsonl, **um** `notify -p 4`, repetido até 3 passadas se não chegar) e aquela partida não é tocada de novo.

Nunca: digita sob dúvida (registro, roster, `ps`, `tmux` ou pane que não responderam, dois claudes no mesmo pane, chave de desligar ilegível), digita duas vezes na mesma partida, lê `gc session peek/nudge` (levaram 22-60 s sob a carga do boot), escreve em bead, mail ou config.

## Instalar e ativar (ordem)
Código no repo **não** é job vivo: até o passo 2 nada roda.
1. No mini, ensaio com o pane de verdade, sem digitar nada: `BFT_WINDOW_S=604800 /usr/bin/python3 /Users/athos/gt/.gascity-gastown-hq/scripts/boot-first-turn.py --dry-run` — lista, por sessão, `WOULD type …` (pane ocioso e vazio), `WAIT …` (e o porquê) ou `UNKNOWN …`. A linha `alvos=` tem de somar o Mayor e todas as crews ativas; uma crew ociosa com pane normal que sai `UNKNOWN: no Claude Code prompt` quer dizer que a leitura do pane não casa com o que o mini mostra (ver «NÃO provado»). **Nunca** rode sem `--dry-run` com janela grande: digitaria em toda crew ociosa.
2. `cp packs/town-deltas/assets/boot-first-turn.plist ~/Library/LaunchAgents/com.gascity.boot-first-turn.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.boot-first-turn.plist`. O watchdog PRESENCE-DRIFT acusa o plist até ele estar carregado.
3. Passe parado (todas as crews com dias de vida) não chama `bd`/`gc`/`ps`/`tmux` e não escreve log: se `.gc/logs/boot-first-turn.log` não existe, é o estado normal.

## Como conferir num reboot real
- 10-15 min depois do boot: `.gc/logs/boot-first-turn.jsonl` tem uma linha por sessão (`result` `confirmed` ou `unconfirmed`, `via` `tmux|tmux+retry|tmux+enter`, `how` = o sinal de vida) e `.gc/logs/boot-first-turn.log` conta o caminho (`TYPED` → `CONFIRMED`). `.gc/boot-first-turn.state.json` guarda a fase de cada partida.
- Prova independente (a do aceite): `gc session peek <crew>` mostra a crew trabalhando logo depois da partida (a linha `[ga-esorlre.13 primeiro turno do boot]` rola para cima com o trabalho: o `peek` só vê o fim do pane); no transcript (`~/.claude/projects/*/<id>.jsonl`) há um registro `user` com a mesma marca.
- Ver o pane com os próprios olhos: `tmux -L gascity attach -t <sessão>` (o nome tmux é o `session_name` da bead de sessão; o alerta `UNCONFIRMED` já traz o comando pronto).
- Crew sem linha no jsonl: veja o `.log` (`WAIT`/`UNKNOWN`/`LATE`/`ABSENT` com o motivo, dito uma vez por mudança). `LATE` = o claude já tinha mais de 20 min: é do vigia ocioso (camada 2).

## Quando não digita, e os botões
`BFT_ENABLED=0` ou `touch .gc/boot-first-turn.off` (vale na próxima passada; chave ilegível = desligado) desligam tudo; `launchctl bootout gui/$(id -u)/com.gascity.boot-first-turn` tira o job. Ajustes: `BFT_WINDOW_S` 1200 · `BFT_IDLE_S` 120 · `BFT_RETRY_S` 90 · `BFT_GIVE_UP_S` 240 · `BFT_BUDGET_S` 100 · `BFT_TMUX_SOCKET` gascity · `BFT_NOTIFY` notify (no plist, em `EnvironmentVariables`).
Limites conhecidos: (1) uma crew acordada à mão que o Athos deixa 2 min parada com a caixa vazia, dentro dos 20 min da partida, recebe a linha — o custo de uma linha a mais, contra o de uma crew calada a noite inteira; (2) pane em modo de cópia do tmux engole as teclas: o resultado é `UNCONFIRMED` + alerta, nunca um falso «ok»; (3) se o motor ainda estiver digitando o prompt de partida quando a sessão já parece ociosa, a nossa linha poderia correr com ele; os 120 s de ociosidade mínima existem para isso (premissa sobre o motor, não medida).

## NÃO provado ao vivo
Escrito e testado fora do mini (nó Hetzner, Linux): testes herméticos com mundo falso + **um teste contra um tmux real** (servidor privado, ambiente vazio como o do launchd: a linha com acentos chega inteira e o `Enter` a envia; alvo `=nome:` vale para `capture-pane` e `send-keys`). Nunca rodou contra o claude, os panes e o `bd` do mini. O que conferir lá, nesta ordem:
- o **pane de conversa nova**: a leitura trata a sugestão `Try "…"` depois do `❯` como caixa vazia **por suposição** sobre a forma dela (os panes reais capturados no mini são de conversa com turnos: `❯` vazio). Se uma crew recém-subida sair `WAIT … input box holds text`, é isto;
- `send-keys`/`capture-pane` com `-t =<sessão>:` no tmux do mini: o capturador já usa o servidor `-L gascity` e o alvo `=<sessão>:` em produção, mas só com `list-panes`;
- os campos `status`/`statusUpdatedAt`/`kind` do registro (claude 2.1.310; o `/compact` noturno já lê os mesmos);
- o **efeito**: o que cada crew faz ao receber a linha. A ordem é a do Mayor; se uma crew a lê e volta a parar, o `confirmed` do jsonl prova só que o turno **começou**, não que o trabalho andou (isso é a camada 3, ga-esorlre.15).

## As outras duas camadas
Esta é a que dispara nos primeiros minutos. **Camada 2** (`crew-idle-wake`, ga-esorlre.14): sessão parada mais de 10 min com bead `in_progress` recebe a ordem como input. **Camada 3** (ga-esorlre.15): às 00:10 de cada reboot noturno, cada crew com bead em andamento tem de ter commit ou comentário novo, senão o celular do Athos vibra. Uma só não fecha; as três juntas, sim. O `boot-first-turn.jsonl` é do mesmo formato por linha (`target`, `result`, `how`, `ids`) para a camada 3 poder lê-lo.
