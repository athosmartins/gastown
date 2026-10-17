## Contents

* Para que serve e como rodar
* Como ler a saída (e o que cada estado quer dizer)
* Retrato medido em 16/10/2026 18:11 (-03)
* O que a amostragem de RAM diz e o que NÃO diz
* Medindo a pegada de RAM por job (`job-ram-probe.py`, ga-sh8t23.3)
* Achados que a grade mostrou de graça
* Limites · Como isto vira prova das fatias .2 e .3

# Grade noturna (ga-sh8t23.1)

A revisão de arquitetura de 15/10 (ga-sh8t23) pede "nenhum minuto da madrugada com mais de 1 job de pico". Antes desta fatia isso não era verificável: a grade noturna só existia na cabeça e em ~410 plists. `scripts/nightly-grid.py` a lê de onde ela RODA.

## Para que serve e como rodar

```bash
python3 $GC_CITY_PATH/scripts/nightly-grid.py                      # 00:00-07:59, colisão = 3 ou mais jobs no mesmo minuto E no mesmo dia da semana
python3 $GC_CITY_PATH/scripts/nightly-grid.py --from 03:50 --to 04:50 --min-collision 2
python3 $GC_CITY_PATH/scripts/nightly-grid.py --match 'gascity|whatsapp'   # recorte pelo NOME do arquivo; o que ficou de fora vem contado em "Fora do --match"
python3 $GC_CITY_PATH/scripts/nightly-grid.py --boot               # lista TODO o conjunto RunAtLoad
python3 $GC_CITY_PATH/scripts/nightly-grid.py --json               # a mesma coisa para outra ferramenta
```

* Lê `~/Library/LaunchAgents` (o que o launchd carregou), **não** os plists do repositório: fonte ≠ o que roda. **O padrão lê TODOS os plists da pasta.** O `--match REGEX` (sobre o NOME do arquivo) existe para recortar, e o que ele deixa de fora vem CONTADO na linha `Fora do --match` (quantos plists, quantos com início de calendário na janela, quantos com RunAtLoad, quantos não consegui avaliar, quantos em disco e não carregados), em texto e em `--json` (`fora_do_match`). Até a primeira versão o padrão era `gascity|whatsapp|gastown|urblink` e escondia, sem dizer, 45 dos 455 plists (ver o retrato abaixo): um filtro que esconde calado é uma grade que mente.
* **Somente leitura**: não chama `launchctl load/unload`, não escreve nada, não move job. Roda quando alguém pede; não há launchd novo nem poll (detector tem custo de poll: se virar guarda, é outro bead, com `StartInterval` medido e lock de instância única).
* Códigos: 0 relatório feito (mesmo com colisão: é detecção, não bloqueio) · 2 uso errado · 3 não consegui ler a entrada (pasta, `--loaded-file` ou `--match` inválido).
* Selftest: `bash scripts/nightly-grid.selftest.sh` (hermético: plists falsos, `launchctl list` e `plutil` injetados).

## Como ler a saída (e o que cada estado quer dizer)

| Seção | O que é |
|---|---|
| Resumo | plists · fora do --match · ilegíveis · lidos via plutil · formato desconhecido · não carregados · RunAtLoad · calendário · StartInterval · KeepAlive · sem horário |
| Fora do --match | só aparece quando o `--match` deixa plists de fora: quantos, quantos têm início de calendário na janela (inclusive "a cada minuto"), quantos têm RunAtLoad, quantos não consegui avaliar (ilegível, ou calendário/chave que não conheço), quantos estão em disco e não carregados (não rodam, mas entram na soma). Eles NÃO entram na grade nem nas contagens do resto da saída. Com o `launchctl list` conhecido só os carregados entram na conta; com ele desconhecido entram todos (limite superior, como na grade) |
| Minutos com N ou mais inícios | o **pico por dia da semana**: jobs distintos que podem começar nesse minuto no MESMO dia. O mesmo job em 5 dias é UM (`job [seg,ter,qua,qui,sex]`); três jobs em seg, ter e qua são 3 labels no minuto mas pico 1 (nunca rodam juntos). Quando o pico é menor que o total, a linha diz os dois: `05:00 — 4 no mesmo dia (5 jobs no total)`. Job só com `Day`/`Month` não se cruza com o dia da semana e conta em todos os dias: é o limite superior. `Weekday` E `Day` na mesma entrada: o launchd dispara se QUALQUER um casa (man launchd.plist), então a grade escreve `[seg ou dia 15]` e o job conta nos 7 dias |
| Grade | todo minuto da janela que tem início. `[seg]`, `[dom]`, `[dia 1]` = condicional: só vale nesse dia, mas num dia em que vale colide de verdade |
| A cada minuto por calendário | entrada sem `Minute` (curinga, como no launchd), com a hora quando tem `Hour` (`job [hora 3]`); só entra se a hora toca a janela (um `Hour: 12` sem `Minute` não é da madrugada). Fora das colisões |
| StartInterval por faixa | só resumo: a hora desses jobs depende de QUANDO foram carregados (depois do reboot noturno, todos juntos). A última faixa (`> 1 h`) pega qualquer inteiro, inclusive o `2147483647` ("nunca") |
| Sem horário | `WatchPaths`/`QueueDirectories`/`StartOnMount` disparam por evento, não por hora: ficam fora da grade e são contados em "sem horário" no resumo |
| Sobe junto no boot | `RunAtLoad=true`, agrupado por prefixo do label |
| Ilegíveis / formato que não conheço / não carregados | os **três estados**: o que o comando não soube ler aparece com o motivo e é contado, nunca some. "Formato que não conheço" cobre o calendário que não entendo **e** `StartInterval`/`RunAtLoad`/`KeepAlive` com tipo que o launchd não documenta (`"300"` em vez de `300`, `0`, booleano): a chave aparece, o valor malformado não conta como se fosse válido e as outras chaves do job seguem valendo |

Três estados que a saída NÃO mistura: **carregado: conhecido** (o `launchctl list` respondeu: plist em disco que não está carregado fica de fora das colisões e listado à parte) · **carregado: desconhecido** (o `launchctl list` falhou ou veio sem nenhum job: todos entram na grade e o relatório avisa; nunca "nada carregado") · **pasta ilegível** (exit 3, sem grade: não sei ≠ grade vazia).

## Retrato medido em 16/10/2026 18:11 (-03)

455 plists na pasta (padrão = todos; 0 ficaram fora): **241 com RunAtLoad**, 156 com calendário, 169 com StartInterval (12 até 1 min, 44 até 5 min, 49 até 15 min, 48 até 1 h, 16 acima), 111 KeepAlive, 2 sem horário (`WatchPaths`); 14 em disco e não carregados; 3 lidos só via plutil; 0 ilegíveis; 0 em formato desconhecido. RunAtLoad por prefixo (no formato da saída): `com.whatsapp: 92 · com.gascity: 66 · com.urblink: 47 · br.urblink: 9 · com.gastown: 8 · com.athos: 6 · com.phoneproxy: 5`, e 1 de cada em br.com, br.urbilink, com.claude, com.grammarly, com.lexbh, com.realestate, com.scrapers, com.whatsapp-automation.

**O que o recorte antigo escondia.** Com `--match 'gascity|whatsapp|gastown|urblink'` a mesma pasta dá 410 plists, 222 RunAtLoad e 137 com calendário, e a linha "Fora do --match" diz o que sumia: **45 plists, 11 deles com início de calendário na madrugada** (`com.athos.claude-history-backup`, os 3 `com.athos.mini-restic-*`, `com.lexbh.v_pipeline.weekly`, `com.realestate.pbh-corruption-recheck`, `com.scrapers.daily`, `daily-catchup`, `empreendimentos-refresh`, `motherduck-s3-backup` e `watchdog`) e 19 com RunAtLoad; 0 que não consegui avaliar; 5 em disco e não carregados (os outros 9 dos 14 não carregados estão dentro do recorte).

Sobre o "271 RunAtLoad" da bead: **não reproduzi**. A saída viva de hoje dá 241 (pasta inteira, só os carregados) e 222 com o recorte antigo; às 12:11 eu tinha medido 223 com o recorte antigo e 248 em disco na pasta toda. O 271 não sai de nenhum recorte meu e não sei de onde veio.

Minutos com **pico de 4 ou mais no mesmo dia da semana** (13 minutos têm pico 3 ou mais): **04:00 (6)**, 03:00 (4), **05:00 (4 no mesmo dia; 5 jobs no total)**, 05:15 (4), 06:30 (4), 07:00 (4), 07:15 (4). Pico 3: 00:15, 05:30, 06:00, 06:15, 07:17, 07:30. O 05:00 já foi contado como 5: dois dos cinco são só de segunda e um só de domingo, então o máximo de um dia é 4 (o gerador conta por dia da semana).

Com o recorte antigo eram 12 minutos e a conta era outra: 04:00 valia 5 (faltava `com.athos.claude-history-backup`), 03:00 e 07:00 valiam 3 (faltavam `com.scrapers.empreendimentos-refresh` e `com.scrapers.watchdog`) e o 05:30 nem aparecia (faltava `com.scrapers.motherduck-s3-backup [dom]`; com o `storage-inventory-monthly [dia 1]` e o `property-search-rebuild` são 3, no pior caso, porque `Day` conta em todos os dias).

Janela 03:30-04:50 (a que a bead chama de pico), por minuto:

```
03:30 cpf-consolidado-freshness-check, dolthub-backup          04:15 sync-critical-dbs-hourly, ficha360-search-index-refresh
03:40 app-incorporador-purga                                    04:17 radar-viabilidade, cadastro-md-sync
03:42 backfill-display-name-hourly                              04:20 sucessao-censec-batch
03:45 itbi-drive-bridge                                         04:30 dolt-compact-routine
04:00 claude-history-backup, dolt-s3-backup, drive-cleanup,     04:35 lot-ficha-extra-projetos
      pbh-edificacao-pipeline, pipedrive-status-deadman,        04:40 pipedrive-lote-backfill-daily
      spe-alert-build                                           04:42 backfill-display-name-hourly
04:07 ga-d81-hotpath-restart                                    04:47 mini-restic-backup, channel-health-retention
04:10 sv-age-refresh, lot-docs-index-daily
```

Onde vivem as fontes dos 6 jobs das 04:00 (para a fatia .3): `dolt-s3-backup` no HQ (`scripts/dolt-s3-backup.sh`); `spe-alert-build`, `pbh-edificacao-pipeline` e `pipedrive-status-deadman` no repositório do rig whatsapp_automation (`launchd/*-wrapper.sh`, `scripts/peter/`); `drive-cleanup.py` em `~/.gastown/scripts`, que é **um terceiro repositório git** (`~/.gastown`, nem o HQ nem o WA); e `claude-history-backup`, que o recorte antigo escondia: o plist (de 06/07) roda `/bin/bash ~/.claude/backup/backup.sh`, que pelo cabeçalho faz o backup diário do histórico do Claude Code para um S3 privado. `~/.claude/backup` **não é repositório git** (`git rev-parse` falha lá), então a fonte dele é um arquivo solto, sem histórico: mudar o horário é editar o plist e o script direto.

## O que a amostragem de RAM diz e o que NÃO diz

Fonte: `.gc/ram-owner-samples.jsonl` (`ram-owner-sampler`, uma amostra a cada ~5 min). Li 948 amostras (0 linhas ilegíveis), de 13/10 06:50 a 16/10 18:09; **41 delas caem na janela 03:50-05:00**, em 3 noites (14, 15 e 16/10; o arquivo começa em 13/10 às 06:50, então a noite de 13/10 não tem amostra). São ~14 pontos por noite.

* Na janela o RSS total fica em **7,5 a 11,4 GB**; nas outras 907 amostras, em 7,3 a 16,8 GB: a janela não é a hora mais pesada do dia. O `dolt` sozinho: 1,07 a 2,65 GB na janela (0 a 2,98 fora). Swap usado: 3,0 a 7,4 GB na janela (0 a 8,0 GB fora); memória livre 35 a 75% na janela (16 a 70% fora). O volume de dados está com 5,1 GB livres e 98% cheio (`df` às 18:1x de hoje); que o swap pese nesse mesmo volume e por isso a RAM vire "disk critical" é **inferência** minha: não medi arquivo de swap.
* Donos não-Dolt na janela (maior RSS de cada nome): `sweep_street_view_age_bh` 920 MB (04:11; **provavelmente** o `sv-age-refresh` das 04:10, mas o nome do processo não é o label do launchd: inferência, não prova), Chrome helper 797 MB (04:15), `compile` 751 MB, `gate-pytest` 741 MB, `clang` 606 MB, `git pack-objects` 508 MB (1,2 GB em outra hora). Dos 6 jobs das 04:00, o maior RSS amostrado em TODAS as amostras (qualquer hora) foi `build_spe_alert` 222 MB, `sweep_pbh` 212 MB, `dolt-s3-backup` 41 MB e `drive-cleanup` 30 MB (nome de processo ≈ job: **provável**, não provado). `pipedrive-status-deadman` e `claude-history-backup` **não têm medida**: nenhum nome de processo seguro para atribuir a eles (o `backup` de 52 MB é genérico demais). Sem medida não é "zero". Nenhum dos medidos chega perto dos 4,5 GB que a bead cita para o `spe-alert-build` "até ontem": ou o pico foi corrigido, ou durou menos que o intervalo de 5 min e a amostra o perdeu. Os dados de hoje não decidem entre as duas.
* **Não dá para** atribuir RAM a um job do launchd: o amostrador agrupa por NOME DE PROCESSO. **Não dá para** ver job que dura menos que 5 min. **Não dá para** concluir "o pico das 04:00 é o de maior RAM" com 41 amostras em 3 noites. Por isso a fatia .3 começa MEDINDO a pegada de cada job (label → processo → pico de RSS) e só depois move horário.

## Medindo a pegada de RAM por job (`job-ram-probe.py`, ga-sh8t23.3)

O `ram-owner-sampler` agrupa por NOME DE PROCESSO a cada 5 min; a decisão de mover um horário precisa de **label do launchd → processo → pico de RSS**. `scripts/job-ram-probe.py` amostra de 5 em 5 s, soma o RSS da ÁRVORE de cada job (o processo que o launchd iniciou e os filhos; `launchctl list` dá label → PID, `ps` dá a árvore) e grava uma linha por amostra com swap, % livre e disco livre. Só lê o sistema; a única escrita é o arquivo de saída (teto de tamanho, piso de disco de 1 GB, instância única por arquivo).

```bash
python3 -I $GC_CITY_PATH/scripts/job-ram-probe.py --start 03:30 --until 05:10 --out $GC_CITY_PATH/.gc/job-ram-probe-AAAAMMDD.jsonl   # uma noite (hora local)
python3 -I $GC_CITY_PATH/scripts/job-ram-probe.py --summary $GC_CITY_PATH/.gc/job-ram-probe-*.jsonl                                    # tabela + simultaneidade + saltos de swap
bash scripts/job-ram-probe.selftest.sh                                                                                                  # hermético, com mutantes por guarda
```

* O resumo traz: jobs da janela por pico da árvore (com o processo de maior RSS e quando), soma simultânea (`--big-mb`, padrão 150 MB = "de pico"), **saltos de swap** (`--swap-step`, 200 MB) com quem cresceu nos 60 s antes, quedas de disco (`--disk-step`, 300 MB) com os jobs rodando, e os persistentes (daemons KeepAlive) à parte.
* Três estados: `ps` ou `launchctl` que falham saem como `ps_ok:false`/`lc_ok:false` (RSS sem atribuição; **não** vira "nenhum job"), swap/% livre/disco que não li ficam `null` (não 0), linha ilegível é contada, arquivo vazio dá exit 3. Códigos: 0 · 2 uso · 3 não consegui ler/sem amostra · 4 outra instância · 5 teto de tamanho · 6 disco abaixo do piso.
* **Limites**: job que dura menos que 5 s pode passar entre duas amostras; processo que se desanexa do job sai da árvore; a soma de RSS conta página compartilhada uma vez por processo (superestima); RSS é o residente (o que já foi pro swap não aparece nele, por isso o salto de swap é lido à parte); a causa de um salto é INDÍCIO. Com a máquina saturada (load 90 após o boot de 17/10) uma amostra custou 1,4 s (mediana; `dt_ms` vem gravado), o que não é o passo de 5 s mas o aproxima: o resumo diz o passo mediano real.

## Achados que a grade mostrou de graça

* O recorte antigo do `--match` escondia 45 plists, 11 com início na madrugada, um deles às 04:00 (`com.athos.claude-history-backup`, plist de 06/07). Foi o próprio reviewer quem pegou; agora o padrão lê tudo e o que um recorte deixa de fora é contado.
* `com.urblink.inbound-review-3d.plist` era um **symlink quebrado** às 08:06 (apontava para `whatsapp_automation/daemons/launchd/`, arquivo que não existia): o único ilegível de verdade. Às 18:11 ele **continua fora** de `~/Library/LaunchAgents` (0 ilegíveis); não sei quem o tirou nem se foi de propósito. Se voltar, a grade o mostra em "Ilegíveis" com o motivo. Dono: rig whatsapp_automation.
* `com.gascity.claude-crew-account.plist`, `com.gascity.mbp-nightly-reseed.plist` e `com.athos.ckan_pbh.plist` o `plistlib` do Python recusa e o `plutil` aceita. Os dois primeiros têm `--` dentro de comentário XML (`<!-- … --dry-run … -->`; estão carregados, e o mbp-nightly-reseed roda às 05:50); do terceiro (não carregado) não investiguei o motivo. A primeira versão do gerador os dava como ilegíveis e os jobs sumiam da grade: agora o `plutil -convert xml1` é o plano B e eles contam em "lidos via plutil" (3). Não é defeito do launchd; é aviso para quem for ler esses arquivos com ferramenta de XML estrito.
* 14 plists em disco e não carregados no `launchctl list` do usuário: `com.athos.ckan_pbh`, `com.athos.clo-telegram`, `auto-refino-dispatcher`, `city-night-window`, `reconciler-stall-detector`, `refino-gate-dispatcher`, `property-scrapers-crew`, `com.google.keystone.agent`, `com.google.keystone.xpcservice`, `verify-browser-relocation`, `contagem-verify`, `zapic-gost`, `crew-refino-sweep` e `map-viewer`. "Não carregado" quer dizer "não está nesta lista", que é a do domínio do usuário (ver Limites): podem estar desligados de propósito ou carregados em outro domínio. A grade só avisa que não os conta.

## Limites

* Só entende `StartCalendarInterval` (dict ou lista de dict), `StartInterval`, `RunAtLoad` e `KeepAlive`. `WatchPaths`/`QueueDirectories`/`StartOnMount` disparam por evento, não por hora: ficam fora da grade e são contados em "sem horário" (hoje 2, os dois `WatchPaths`: `com.gascity.wa-beads-config-guard` e `com.whatsapp.demand-dashboard`).
* `launchctl list` mostra o domínio do launchd em que o comando roda (o do usuário); plist carregado em outro domínio aparece como "não carregado". Quando o `launchctl list` falha, o relatório diz "carregado: desconhecido" e conta tudo como podendo rodar.
* Horário que o launchd calcula com atraso, ou o `StartInterval` de job carregado em momentos diferentes, não aparece como colisão.
* É contagem de **inícios**, não de RAM: dois jobs no mesmo minuto não são necessariamente dois picos. Quais são "de pico" é decisão da fatia .3, com número medido.

## Como isto vira prova das fatias .2 e .3

* .3 (espalhar as 04:00): depois do deploy, `nightly-grid.py --from 03:50 --to 04:50 --min-collision 2` (sem `--match`: o padrão lê todos os plists, o `claude-history-backup` das 04:00 entra na conta) mostra no máximo 1 job de pico por minuto (a lista de "pico" sai da medição da .3) e o "disk critical" das 04:00-04:30 fica em zero por 7 dias, conferido no `disk-growth-*.txt` do `dolt-disk-floor-guard`, não por relato.
* .2 (`wait-for-dolt`): a lista de jobs que leem Dolt no boot sai de `--boot` + leitura do programa de cada um.
