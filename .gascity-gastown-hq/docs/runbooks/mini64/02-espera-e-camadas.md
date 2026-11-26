# Mini 64: chave de espera e ordem de carga em camadas · runbook

Fatia .2 do programa ga-ke5w2ie (migrar a cidade para o Mac mini M5 Pro 64 GB). Risco que ela fecha: o Assistente de Migração copia ~540 plists para `~/Library/LaunchAgents` e todos carregam no 1º login do mini novo, que passaria a enviar WhatsApp e a fazer backup meio configurado, em paralelo com o antigo. Scripts em `scripts/mini64/`; os testes rodam com HOME e launchctl de mentira, nada aqui toca a produção.

## Contents

• Os três comandos · As camadas · Quando rodar cada um · O que a espera não cobre · Saídas e o que fazer · Testes e como mexer na tabela

## Os três comandos

Todos leem `~/Library/LaunchAgents` do usuário que roda (o `$HOME`). Quem muda algo exige `--aplicar`; sem ele mostra o que faria (rc 0).

| Comando | O que faz |
|---|---|
| `espera.sh status` | Só lê. 1ª linha `espera: desligada · ligada · em-carga · carga-completa · inconsistente · nao-sei`. Lista o que a espera NÃO move (carrega no login) e o que está só pela família da tabela |
| `espera.sh ligar --aplicar` | Grava o marcador `~/.mini64-espera` e MOVE os plists da cidade para `~/Library/LaunchAgents.mini64-espera/`. Nada é apagado nem sobrescrito: uma cópia nova de um plist já parado vira o vigente e a antiga fica como `<nome>.plist.anterior-<epoch>`. Rodar de novo é seguro |
| `carregar-camada.sh <N> --aplicar [--confirmo <chave>]` | Devolve da espera e faz `launchctl bootstrap gui/<uid>` SÓ dos plists da camada N; o que já está carregado é pulado |
| `espera.sh desligar --aplicar` | Encerra a espera (o marcador vira `.encerrada-<epoch>`), e só quando a pasta da espera está vazia. Nunca devolve tudo de uma vez |

Nunca rode `ligar --aplicar` nem `carregar-camada.sh --aplicar` no mini ANTIGO: mover os plists não descarrega o que está rodando, e no próximo reboot a cidade não sobe.

## As camadas

A tabela é `scripts/mini64/camadas.tsv` (prefixo do label → camada; vale o prefixo mais longo). Ordem da bead: Dolt, motor, backups, painéis, cloudflared, envios por último.

| N | Nome | Entra | `--confirmo` |
|---|---|---|---|
| 0 | dolt | `com.gastown.dolt-server` | |
| 1 | motor | bd, supervisor, pilot, gate, crews e os guardas que só olham a cidade | |
| 2 | backups | S3, jsonl offsite, restore de prova, backups do WA | `antigo-aposentado` |
| 3 | paineis | painéis só-leitura, apoio ao nó Hetzner, Chrome CDP | |
| 4 | cloudflared | o conector e o reconciliador de DNS | `conector-unico` |
| 5 | envios | WhatsApp, ligações, ingestão e tudo que o WA não classificou | `antigo-aposentado` |

- `antigo-aposentado`: a fatia .4 terminou (o antigo teve bootout e disable de gascity/whatsapp/urblink, sem nightly-reboot, cloudflared, Wi-Fi e chave AWS). Backup escrito pelo 64 antes disso derruba o único rollback.
- `conector-unico`: o conector do mini antigo está parado, para o túnel (config `urblink-ops.yml`) ter UM conector só.
- A ordem é imposta: a camada N recusa se sobrou plist de camada anterior na espera, ou se há plist de camada posterior solto em LaunchAgents.
- Na dúvida a camada é a 5. As famílias (`com.whatsapp`, `com.urblink`, `br.urblink`, `com.gascity`, `com.gastown`, `com.athos`, `com.phoneproxy`, `com.realestate`) são movidas pela espera mesmo sem linha própria e carregam na 5. Decisão desta fatia: a ingestão de conversa (lista antiga da bead) ficou na 5 junto dos envios; para separá-la, crie `@camada 6` na tabela e mova as linhas, sem mexer em código.

## Quando rodar cada um

1. **D-4, no mini antigo, só leitura:** `espera.sh status`. As seções "NÃO movidos" e "Sem linha própria" mostram o que a tabela ainda não sabe, inclusive o label real do cloudflared (ele não está em nenhum repo; a tabela tem `com.cloudflare.cloudflared` e `homebrew.mxcl.cloudflared` como palpite). Ajuste `camadas.tsv` antes do D-3.
2. **D-3, no mini novo, com a rede isolada (fatia .5), logo depois do Assistente de Migração:** `espera.sh ligar` (prévia), conferir a lista, `espera.sh ligar --aplicar`. Se saiu rc 3, algum job já estava carregado: reinicie o mini ainda sem rede e rode `espera.sh status` até dar `ligada`. Rode `ligar --aplicar` de novo depois de cada passada do Assistente.
3. **D0 (fatia .6), depois do delta e da fatia .4:** de dentro da sessão gráfica do usuário (o `gui/<uid>` precisa existir), `carregar-camada.sh 0 --aplicar`, confira o Dolt, depois 1, 2 (`--confirmo antigo-aposentado`), 3, 4 (`--confirmo conector-unico`) e 5 (`--confirmo antigo-aposentado`), cada uma só depois do go da anterior. Cada camada começa por `carregar-camada.sh <N>` sem `--aplicar`. Fim: `espera.sh status` dá `carga-completa`, então `espera.sh desligar --aplicar`.

## O que a espera não cobre

- Job que JÁ estava carregado: mover o plist não o descarrega. `ligar` avisa (rc 3); só o reboot resolve.
- O marcador é lido por estes scripts, não pelos daemons. Fazer todo envio e todo backup testá-lo no início é mudança de código dos daemons, fora do escopo desta fatia: a barreira de hoje é o plist ausente.
- `/Library/LaunchAgents`, `/Library/LaunchDaemons`, brew services e processo iniciado à mão (inventário da fatia .1). TCC, driver serial, chaves e Bitwarden também não migram sozinhos.
- Camada vazia nesta máquina (ex.: cloudflared que sobe por brew services): o script avisa e sai 0; suba à mão.

## Saídas e o que fazer

| rc | Significa | O que fazer |
|---|---|---|
| 0 | feito, ou prévia | seguir |
| 1 | recusado, nada mudou | ler o motivo: camada inexistente, espera desligada, ordem, `--confirmo`, uso |
| 2 | não sei: uma leitura falhou (HOME, tabela, pasta, marcador) | nada mudou; consertar a leitura. Nunca vale como "desligada" |
| 3 | feito com falha parcial ou aviso | `espera.sh status`, ler a linha FALHA ou AVISO; rodar a mesma camada de novo carrega só o que faltou |

## Testes e como mexer na tabela

`bash scripts/mini64/mini64.selftest.sh` (~10 s, bash 3.2 do mini). Cobre ligar, desligar, status, ordem, `--confirmo`, idempotência, terceiro estado e a regra de que nenhum script apaga nada nem chama o `launchctl` real. O teste falha se algum plist vivo do repo ficar sem linha PRÓPRIA em `camadas.tsv`: ao criar um plist novo, acrescente a linha na mesma entrega. Plist do WA que a tabela ainda não conhece carrega na 5 e aparece em "Sem linha própria" do `status`.
