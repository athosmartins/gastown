# Mini 64: chave de espera e ordem de carga em camadas · runbook

Fatia .2 do programa ga-ke5w2ie (migrar a cidade para o Mac mini M5 Pro 64 GB). Risco que ela fecha: o Assistente de Migração copia ~540 plists para `~/Library/LaunchAgents` e todos carregam no 1º login do mini novo, que passaria a enviar WhatsApp e a fazer backup meio configurado, em paralelo com o antigo. Scripts em `scripts/mini64/`; os testes rodam com HOME e launchctl de mentira, nada aqui toca a produção.

## Contents

• Os comandos · As camadas · Quando rodar cada um · O que a espera não cobre · Saídas e o que fazer · Testes e como mexer na tabela

## Os comandos

Todos leem `~/Library/LaunchAgents` do usuário que roda (o `$HOME`). Quem muda algo exige `--aplicar`; sem ele mostra o que faria (rc 0).

| Comando | O que faz |
|---|---|
| `espera.sh status` | Só lê. 1ª linha `espera: desligada · ligada · em-carga · carga-completa · plists-soltos · inconsistente · nao-sei`. Com o marcador e plists da cidade fora da espera, pergunta ao launchd quais estão carregados: `plists-soltos` = algum NÃO está (um `ligar` que falhou ou parou no meio, ou um bootstrap que falhou), e a lista `SOLTOS` diz quais; `em-carga` e `carga-completa` só valem com todos carregados. Lista também o que a espera NÃO move (carrega no login) e o que está só pela família da tabela |
| `espera.sh ligar --aplicar --confirmo mini-novo` | Grava o marcador `~/.mini64-espera` e MOVE os plists da cidade para `~/Library/LaunchAgents.mini64-espera/`. Nada é apagado nem sobrescrito: uma cópia nova de um plist já parado vira o vigente e a antiga fica como `<nome>.plist.anterior-<epoch>`. Rodar de novo é seguro. Sem `--aplicar` é prévia (diz a máquina e traz o comando); sem a chave, recusa |
| `carregar-camada.sh <N> --aplicar [--confirmo <chave>]` | Devolve da espera e faz `launchctl bootstrap gui/<uid>` SÓ dos plists da camada N; o que já está carregado é pulado |
| `espera.sh desligar --aplicar` | Encerra a espera (o marcador vira `.encerrada-<epoch>`), e só quando a pasta da espera está vazia E todo plist da cidade solto está carregado (um `ligar` que não moveu nada tem o mesmo aspecto de uma carga completa). Nunca devolve tudo de uma vez |

O script não tem como saber em que máquina está: `--confirmo mini-novo` é você afirmando que esta é o mini 64 NOVO. No mini em produção o `ligar --aplicar` tira os plists do login, mover não descarrega o que está rodando, e no próximo reboot a cidade não sobe: nunca o rode lá. O `carregar-camada.sh` recusa sem o marcador.

## As camadas

A tabela é `scripts/mini64/camadas.tsv` (prefixo do label → camada; vale o prefixo mais longo). Ordem da bead: Dolt, motor, backups, painéis, cloudflared, envios por último.

| N | Nome | Entra | `--confirmo` |
|---|---|---|---|
| 0 | dolt | `com.gastown.dolt-server` | |
| 1 | motor | bd, supervisor, pilot, gate, crews e os guardas que só olham a cidade | |
| 2 | backups | S3, jsonl offsite, restore de prova, backups do WA e do próprio mini (`com.athos.mini-restic-*`, `claude-history-backup`) | `antigo-aposentado` |
| 3 | paineis | painéis só-leitura, apoio ao nó Hetzner, Chrome CDP | |
| 4 | cloudflared | o conector (`br.urblink.cloudflared.urblink-ops`) e o reconciliador de DNS | `conector-unico` |
| 5 | envios | WhatsApp, ligações, ingestão e tudo que o WA não classificou | `antigo-aposentado` |

- `antigo-aposentado`: a fatia .4 foi aplicada no antigo (`aposentar-servidor.sh aplicar`, e o `conferir` deu rc 0 ou 6, só o sudo pendente; `04-aposentar.md`): envios, backups que escrevem em produção, cloudflared e reboot noturno do antigo estão parados e desabilitados (Dolt, motor e painéis do antigo seguem). Backup escrito pelo 64 antes disso derruba o único rollback.
- `conector-unico`: o conector do mini antigo está parado (a .4 o aposenta), para o túnel (config `urblink-ops.yml`) ter UM conector só. Depois da camada 4 o go/no-go da .3 (`cloudflared-conectores`) confere que há exatamente 1.
- A ordem é imposta: a camada N recusa se sobrou plist de camada anterior na espera, ou se há plist de camada posterior solto em LaunchAgents.
- Na dúvida a camada é a 5. As famílias (`com.whatsapp`, `com.urblink`, `br.urblink`, `com.gascity`, `com.gastown`, `com.athos`, `com.phoneproxy`, `com.realestate`) são movidas pela espera mesmo sem linha própria e carregam na 5. Decisão desta fatia: a ingestão de conversa (lista antiga da bead) ficou na 5 junto dos envios; para separá-la, crie `@camada 6` na tabela e mova as linhas, sem mexer em código.

## Quando rodar cada um

1. **D-4, no mini antigo, só leitura:** `espera.sh status`. As seções "NÃO movidos" e "Sem linha própria" mostram o que a tabela ainda não sabe. O túnel já tem linha (camada 4: o label vem do `TUNNEL_LABEL` do `nightly-reboot-postcheck.sh`); se `ls ~/Library/LaunchAgents | grep -i cloudflare` mostrar outro label de cloudflared, acrescente a linha em `camadas.tsv` antes do D-3.
2. **D-3, no mini novo, com a rede isolada (fatia .5), logo depois do Assistente de Migração:** `espera.sh ligar` (prévia), conferir a lista, `espera.sh ligar --aplicar --confirmo mini-novo`. Se saiu rc 3, ou algum job já estava carregado (AVISO: reinicie o mini ainda sem rede) ou algum plist não foi movido (linhas "não consegui mover"). Rode `espera.sh status` até dar `ligada`: `plists-soltos` quer dizer que ficou plist fora da espera sem carregar, então rode o `ligar --aplicar --confirmo mini-novo` de novo. Rode-o de novo também depois de cada passada do Assistente.
3. **D0 (fatia .6), depois do delta e da fatia .4:** de dentro da sessão gráfica do usuário (o `gui/<uid>` precisa existir), `carregar-camada.sh 0 --aplicar`, confira o Dolt, depois 1, 2 (`--confirmo antigo-aposentado`), 3, 4 (`--confirmo conector-unico`) e 5 (`--confirmo antigo-aposentado`), cada uma só depois do go da anterior. Cada camada começa por `carregar-camada.sh <N>` sem `--aplicar`. Fim: `espera.sh status` dá `carga-completa` (todos os plists estão carregados), então `espera.sh desligar --aplicar`. Não rode o `ligar` depois de começar o D0: ele devolve à espera os plists já carregados (seguem rodando até o reboot) e o status volta a `ligada`; só serve para recomeçar do zero, com reboot.

## O que a espera não cobre

- Job que JÁ estava carregado: mover o plist não o descarrega. `ligar` avisa (rc 3); só o reboot resolve.
- Plist que o mini antigo tem em disco e NÃO carregado (a `grade-noturna.md` lista alguns, como `city-night-window` e `com.athos.clo-telegram`): a camada dele o carrega como qualquer outro. Antes do D0 confira contra o `launchctl list` do antigo (inventário da .1) e deixe fora da espera o que não deve subir.
- O marcador é lido por estes scripts e pelo go/no-go da .3, não pelos daemons. Fazer todo envio e todo backup testá-lo no início é mudança de código dos daemons, fora do escopo desta fatia: a barreira de hoje é o plist ausente.
- `/Library/LaunchAgents`, `/Library/LaunchDaemons`, brew services e processo iniciado à mão (inventário da fatia .1). TCC, driver serial, chaves e Bitwarden também não migram sozinhos.
- Camada sem nenhum plist nesta máquina (nem solto nem na espera): o script avisa e sai 0, inclusive a 0 (Dolt) e a 4 (túnel). Confira o job com `launchctl print gui/$(id -u)/<label>` e com o go/no-go da .3 antes de seguir.

## Saídas e o que fazer

| rc | Significa | O que fazer |
|---|---|---|
| 0 | feito, ou prévia | seguir |
| 1 | recusado, nada mudou | ler o motivo: camada inexistente, espera desligada, ordem, `--confirmo`, uso |
| 2 | não sei: uma leitura falhou (HOME, tabela, pasta, marcador, launchd) | nada mudou; consertar a leitura. Nunca vale como "desligada" nem como "carga completa" |
| 3 | feito com falha parcial ou aviso | reler a saída do próprio comando: as linhas `FALHA` (`carregar-camada`) e `AVISO` (`ligar`) saem no stderr na hora e o `espera.sh status` não as repete (ele mostra o estado e a lista `SOLTOS`). No `ligar`, rc 3 é job já carregado (AVISO) ou plist que não foi movido. Rodar a mesma camada de novo carrega só o que faltou |

## Testes e como mexer na tabela

`bash scripts/mini64/mini64.selftest.sh` (~10 s, bash 3.2 do mini). Cobre ligar, desligar, status (inclusive o terceiro estado: um `ligar` que não moveu nada não pode parecer carga completa), a chave `mini-novo`, ordem, `--confirmo`, idempotência e a regra de que nenhum script apaga nada nem chama o `launchctl` real. O teste falha se ficar sem linha PRÓPRIA em `camadas.tsv`: plist vivo ou template de plist do repo, job da política `wait-for-dolt.policy.tsv`, e o túnel que o `nightly-reboot-postcheck.sh` confere (lido do arquivo, nunca copiado; o sender dele tem de cair na camada 5). Ao criar um job novo, acrescente a linha na mesma entrega. Plist do WA que a tabela ainda não conhece carrega na 5 e aparece em "Sem linha própria" do `status`.
