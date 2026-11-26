## Contents
- O que faz
- Instalar e ativar
- Conferir num reboot real
- Botões
- O que NÃO está provado
- Fora desta fatia (.13b)

Camada 1 da missão ga-esorlre.12 (bead ga-esorlre.13). Script `scripts/boot-first-turn.py` · plist `packs/town-deltas/assets/boot-first-turn.plist` · testes `python3 -I scripts/test_boot_first_turn.py`.

## O que faz
Depois de um boot, sessão nova fica no prompt e o que chega por `gc session nudge` vira «deferred reminder» (só entra quando um turno começa). Só input digitado no pane acorda. A cada 60 s o job lê as sessões do tmux `-L gascity` e, para o Mayor e cada crew nomeada **criada há 2-20 min** (`BFT_MIN_AGE_S`, `BFT_WINDOW_S`) que tem **bead `in_progress`** (assignee = nome tmux, alias ou incarnação anterior `<alias>-gawisp…`; stores da cidade e do rig), confere o pane (prompt ocioso, caixa vazia, sem `esc to interrupt`, sem diálogo) e digita **uma** linha `[ga-esorlre.13 primeiro turno do boot] … retome a bead em andamento <ids> e o último handoff …` (`send-keys -l`, depois `Enter` em outra chamada). Uma vez por (sessão, hora de criação), guardado em `.gc/boot-first-turn.state.json`.
Não digita quando: pane ocupado, com diálogo ou rascunho; pane, `bd` ou tmux não responderam (conta `nao-sei`, nunca vira «ocioso» nem «sem trabalho»); a sessão não tem bead em andamento. Falha de `send-keys` não é gravada (tenta no passe seguinte) e manda `notify -p 4`.

## Instalar e ativar
Código no repo não é job vivo. No mini: (1) ensaio sem digitar: `BFT_WINDOW_S=604800 /usr/bin/python3 scripts/boot-first-turn.py --dry-run` — a linha `alvos=` soma o Mayor e as crews; `WOULD type` = pane ocioso com bead; (2) `cp packs/town-deltas/assets/boot-first-turn.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.boot-first-turn.plist`. Nunca rode sem `--dry-run` com janela grande: digitaria em toda crew ociosa.

## Conferir num reboot real
10-15 min depois do boot: `.gc/logs/boot-first-turn.jsonl` (uma linha `typed` por sessão) e `.gc/logs/boot-first-turn.log` (`TYPED`/`WAIT`/`UNKNOWN`); `gc session peek <crew>` mostra turno em andamento. O **efeito** (a crew andou) é conferido às 00:10 pela camada 3 (ga-esorlre.15); este job só garante que o turno foi pedido.

## Botões
`touch .gc/boot-first-turn.off` ou `BFT_ENABLED=0` (arquivo ilegível = desligado) · `launchctl bootout gui/$(id -u)/com.gascity.boot-first-turn`. Ajustes por env no plist: `BFT_MIN_AGE_S` 120 · `BFT_WINDOW_S` 1200 · `BFT_TIMEOUT_S` 20 · `BFT_TMUX_SOCKET` gascity.

## O que NÃO está provado
Provado em 26/11 13:30 no mini, só leitura (`--dry-run`, janela 7 d): `tmux list-sessions`, `capture-pane -t =<sessão>:` e os stores do `bd` respondem; 5 alvos (Mayor + crews), 1 «WOULD type» (oracle-wa, pane ocioso, 4 beads), 1 «WAIT … pane dialog» (peter-wa), 3 sem trabalho.
Não provado: **`send-keys` real** (o único passo que escreve; só roda no boot de verdade ou num teste com sessão descartável) e o pane de conversa **nova** (a sugestão `Try "…"` é tratada como caixa vazia por suposição; se for outra coisa o pane cai em `draft`/`unknown` e o job não digita, o que o `WAIT`/`UNKNOWN` no log mostra).

## Fora desta fatia (.13b)
Prova por registro/transcript, reenvio, alarme «sem prova», despacho pendente (bead `open` atribuída) como gatilho, e mini64 além da linha em `camadas.tsv`. A camada 2 (ga-esorlre.14) cobre sessão parada > 10 min.
