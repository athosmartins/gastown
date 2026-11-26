# Mini64 04 — aposentar o servidor antigo sem volta acidental (ga-ke5w2ie.4)

## Contents

• O que isto faz e por quê · Quando e quem roda · Passo a passo da noite do corte · A lista: o que aposenta e o que fica
• O marcador e quem o respeita · Conferir depois de um reboot · Passos manuais (sudo, rede, chave AWS) · Desfazer · Limites conhecidos (não escondidos)

Programa: migração para o Mac mini M5 Pro 64 GB (épico `ga-ke5w2ie`). O índice `README.md` desta pasta é da fatia .1 e ainda não lista esta página.

## O que isto faz e por quê

Risco nº 1 do épico: **dois servidores vivos** = WhatsApp em dobro, Dolt divergente, backup S3 sobrescrito pela máquina errada. Na noite do corte o mini 16 para de **enviar**, de **escrever** no que é de produção e de **fazer backup** — e não pode voltar sozinho num reboot (o launchd recarrega no login tudo o que não estiver *desabilitado*). `scripts/mini64/aposentar-servidor.sh`, em três defesas:

• **`launchctl disable` + `bootout`** em cada rótulo a aposentar: o `disable` sobrevive ao reboot (vai primeiro), o `bootout` para o processo agora.
• **O marcador `~/.servidor-aposentado`**, gravado *antes* de mexer no launchd: os scripts deste repo que sobem para o S3 recusam enquanto ele existir (run à mão, *order* do engine, plist que volta por engano).
• **A conferência do efeito**: carregado/habilitado vêm do `launchctl`, nunca do `rc` do comando (um `launchctl` que devolve 0 sem fazer nada é caso de teste).

Saída: **0** tudo feito e conferido · **2** uso errado ou configuração inválida (nada foi alterado) · **4** pendência (`[FALHA]`, `[NAO SEI]` ou plist ilegível; no `aplicar` o marcador já foi gravado) · **6** o que dá sem root está feito, faltam os passos com `sudo` (impressos; o script **nunca** roda `sudo`). "Não sei" nunca vira "descarregado" nem "ok".

## Quando e quem roda

`plano` (o padrão) só lista: não chama o `launchctl` nem escreve nada; rode em D-3 e de novo antes do corte, no mini de verdade. `aplicar`, `desfazer` e `conferir` chamam o `launchctl`: **`aplicar` só na noite do corte, pelo Mayor, ANTES do go/no-go da fatia .3** (que roda na máquina nova, até 04:30; a ordem exata da noite é da fatia .6) — nunca no mini em produção fora dela; um dog nunca o roda (derrubaria o envio de produção). O `desfazer` é o rollback se o go/no-go der NO-GO, e só vale até o go. Os testes usam um `launchctl` de mentira, uid falso e HOME falso.

## Passo a passo da noite do corte

```bash
cd ~/gt/.gascity-gastown-hq
bash scripts/mini64/aposentar-servidor.sh plano | less     # RESUMO, MANTER e FICAM RODANDO antes de seguir
bash scripts/mini64/aposentar-servidor.sh aplicar           # marcador, disable + bootout, e a CONFERENCIA
# rc 6: rode os comandos com sudo que ele imprimiu (reboot noturno); depois
bash scripts/mini64/aposentar-servidor.sh conferir          # rc 0 = nada voltou
```
No `plano`: **RESUMO** (rótulos por camada), **APOSENTAR** (um por linha, na ordem do `aplicar`), **MANTER**, **FICAM RODANDO** (da família da cidade e **sem regra nenhuma** — leia esta: se algum envia, ingere ou sobe backup, acrescente uma linha), **ILEGIVEIS** (o `aplicar` termina com rc 4 por causa deles; link simbólico quebrado não conta). Ordem do `aplicar`: **envios → cloudflared → backups → reboot-noturno** (a inversa da carga da .2). Um erro não para o laço; a conferência diz o que não pegou.

## A lista: o que aposenta e o que fica

`scripts/mini64/aposentar-camadas.tsv` (formato no cabeçalho de `aposentar-classifica.py`, que lê o `Label` de dentro do plist com `plistlib`, nunca o nome do arquivo). Camadas **pelo nome**, os do `camadas.tsv` da fatia .2 (`envios`, `backups`, `cloudflared`, `paineis`) mais `reboot-noturno` (só daqui). Vale a regra mais específica. A bead pedia "envio, ingestão, backup e cloudflared": na .2 a ingestão **não é camada** (cai no padrão da família = `envios`); aqui, **família do WhatsApp sem regra própria = aposentar**.

Medido em 26/11 contra os `Label` dos plists do repo da cidade e do repo do WA (`origin/main`): 418 rótulos → **290 a aposentar** (276 `envios`, 9 `backups`, 3 `cloudflared`, 2 `reboot-noturno`; 3 sem plist no disco: os dois palpites do cloudflared e o LaunchDaemon), **28 mantidos**, **103 ficam rodando**. Entre os `backups` está o `mbp-nightly-reseed` (não é backup do S3: faz `rsync --delete` da base de teste para o MBP — estado remoto compartilhado que dois minis sobrescreveriam alternadamente). A evidência de cada bloco está nos comentários do arquivo; `aposentar-servidor.selftest.sh` (bloco T) confere cada `com.gascity.*` citado contra os plists do repo e que Dolt e motor nunca são aposentados.

**Ficam de propósito:** o **Dolt** (`com.gastown.dolt-server`) e os **painéis só-leitura** (fora do escopo da bead; camada `paineis` da .2, como prefixos: `classification-dashboard` cobre o `-auth-watchdog`); o que só **lê** o S3 (`com.gascity.dolt-restore-*`, os alarmes de idade e o export local do `jsonl-*` — a .2 os põe em `backups`, aqui são `manter`: o restore de prova faz do 16 uma reserva de verdade); os **backups por máquina** (`com.athos.claude-history-backup`, `mini-restic-*`: protegem o estado do próprio 16, sem chave compartilhada para sobrescrever; o script deles vive fora de qualquer repo).

**Pergunta aberta (Mayor / fatia .8):** o **motor da cidade** (`com.gascity.*` da camada 1 da .2: pilot, gate, supervisor, guardas) **não** é aposentado aqui — a bead não pede — e aparece em FICAM RODANDO; se o 16 deve deixar de ter motor próprio, basta acrescentar linhas `aposentar` com prefixo. **Cruzamento com a .2:** conferido à mão em 26/11 contra a branch dela (`@ 8337306920`, no gate): 56 checagens, 0 divergências, 1 nota — `br.urblink.cloudflared.*` (o conector) cai em `envios` na .2 por falta de linha própria; aqui é `cloudflared`. Automatizar esse cruzamento quando o `camadas.tsv` da .2 estiver na `main` é follow-up.

## O marcador e quem o respeita

`~/.servidor-aposentado` (texto `chave=valor`). **O que vale é existir.** Três estados: **presente** → recusa; **ausente** (pasta legível) → segue; **não sei** (sem `HOME`, pasta sem acesso, link quebrado) → **recusa**, como se houvesse marcador. Os scripts inteiros saem com `rc 69` sem criar nada (nem log, lock ou estado):

| Onde | O que escreve no S3 | Com o marcador |
|---|---|---|
| `scripts/dolt-s3-backup.sh` | `sync --delete` por banco, `_meta/latest.json`, `jsonl-archive/` | `rc 69` antes do `mkdir` e do lock |
| `scripts/dolt-backup-s3-proof.sh` (`_s3proof_mirror_up`) | espelho aditivo do staging (o `dolt-gc-maintenance.sh` e o reseed chegam aqui por conta própria) | `return 1`: "não provado", o staging não é liberado |
| `scripts/dolt-backup-reseed.sh` (`_publish_db_fingerprint`) | `sync --delete` + `_meta/latest.json` | `return 1`, não fatal; o reseed **local** segue |
| `packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh` (modo `run`) | `put-object` e `delete-object` em `jsonl-hourly/` | `rc 69`; `--status`, `--age-check`, `--table-age` (leitura) **não** recusam |

**Em outro repo — candidatos ao mesmo check (3 linhas; bead para o dono do rig WA; só li os rótulos e os nomes de bucket, não o código deles):** os backups do WA (`com.whatsapp.backup-all-dbs`, `dolthub-backup`, `pipedrive-recents-backup`, `com.urblink.backup-health-db-6h`, `sync-critical-dbs-hourly`), o que sobe para `urblink-motherduck-backups` e o publicador do bucket `whatsapp-viewer-*`; até lá o `disable` os cobre. `dolt-s3-lifecycle-apply.sh` e `transcript-s3-backup-lifecycle-setup.sh` só mexem em ciclo de vida do bucket, à mão. **Convenção:** selftest que roda um desses caminhos contra um `aws` de mentira exporta `SERVIDOR_APOSENTADO_FILE` para um caminho inexistente (senão quebra no 16 aposentado); `aposentar-guards.selftest.sh` confere os três que existem.

## Conferir depois de um reboot

`aposentar-servidor.sh conferir` (só leitura; rc 0 tudo ok, 4 algo voltou ou não sei, 6 só faltam os passos com sudo): `[ok]`/`[FALHA]`/`[NAO SEI]` por rótulo (descarregado **e** desabilitado) e o marcador. Independente do script: `ls -l ~/.servidor-aposentado`; `launchctl print-disabled gui/$(id -u) | grep -c disabled`; `launchctl list | grep -E 'central-sender|campaign|voicebot'` (nada); `sudo launchctl print-disabled system | grep nightly-reboot` (`disabled`); `pmset -g sched` (nada no repo agenda isto). Depois de um reboot de verdade, rode `conferir` **antes** de qualquer outra coisa: `[FALHA] … CARREGADO` é um job que voltou.

## Passos manuais (sudo, rede, chave AWS)

1. **Reboot noturno** (`/Library/LaunchDaemons/com.gascity.nightly-reboot.plist`, root, 23:00): `sudo launchctl bootout system/com.gascity.nightly-reboot` e `sudo launchctl disable system/com.gascity.nightly-reboot`. Sem root o `conferir` pode não ler o domínio `system` (`[NAO SEI]`, rc 6). O postcheck (LaunchAgent) o script desabilita.
2. **cloudflared — um conector só.** O túnel `urblink-ops` é `br.urblink.cloudflared.urblink-ops` (default do `TUNNEL_LABEL` em `nightly-reboot-postcheck.sh`; o plist dele não está em repo nenhum). `com.cloudflare.cloudflared` e `homebrew.mxcl.cloudflared` são **palpites** da .2: rode `ls ~/Library/LaunchAgents | grep -i cloudflare` e ajuste a lista.
3. **Wi-Fi/rede do antigo** (só documentado; o motivo não está na bead). Antes de tirar rede, confirme que o 16 segue acessível por ssh por outro caminho (cabo): continua construtor. `networksetup -listallhardwareports`; `networksetup -setairportpower <interface> off` (reversível com `on`).
4. **Chave AWS do antigo** (só documentado, **não revogar**). O 16 como reserva precisa de **leitura** em `urblink-dolt-backups` (restore semanal) e o `claude-history-backup` dele **escreve** em `urblink-claude-history-backup/projects/`. Opções: **(a)** chave de política mínima — leitura no de produção, escrita só no prefixo do próprio histórico (recomendado: nem um script perdido escreve no bucket de produção); **(b)** manter a chave e confiar no marcador + `disable`; **(c)** revogar (quebra o restore da reserva e o backup de transcritos do 16). Decisão do Mayor/Athos.

## Desfazer

`aposentar-servidor.sh desfazer --sim-tenho-certeza` — **só antes do go**: depois dele, religar o antigo manda WhatsApp em dobro e sobrescreve o backup. Sem a flag (ou com variante dela) recusa sem ler nem tocar em nada. Ordem: **todos** os `enable` primeiro; se algum falhar o **marcador fica** e nada é religado; só então o marcador sai e o `bootstrap` religa na **ordem de carga** (`backups` → `cloudflared` → `envios`, o WhatsApp por último), pelo caminho real do plist; a conferência pede carregado **e** habilitado. O que tem `sudo` vem impresso (`enable` e `bootstrap system /Library/LaunchDaemons/<rótulo>.plist`).

## Limites conhecidos (não escondidos)

• Só age sobre rótulo com **plist em** `~/Library/LaunchAgents` (e sobre regras `exato`, que valem sem plist); job carregado de outro caminho não é visto.
• `bootout` envia TERM e espera (até ~20 s por rótulo): ~290 rótulos podem levar minutos; envio em voo é cortado, a fila fica no banco.
• `print-disabled`/`list` no formato do macOS 12+ (`=> disabled`/`enabled`; o antigo `true`/`false` também é lido); o que não for legível vira `[NAO SEI]`.
• A lista é uma foto de 26/11: plist novo do WA cai na família (`envios`); painel novo só-leitura precisa de uma linha `manter`.
• Precisa de `python3` (o do Command Line Tools serve); sem ele: rc 2. O script é bash 3.2 (`/bin/bash` do macOS); os selftests rodam sob 3.2.57 e 5.x.
