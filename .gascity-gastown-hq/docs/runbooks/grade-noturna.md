## Contents

* Para que serve e como rodar
* Como ler a saída (e o que cada estado quer dizer)
* Retrato medido em 16/10/2026 08:06 (-03)
* O que a amostragem de RAM diz e o que NÃO diz
* Achados que a grade mostrou de graça
* Limites · Como isto vira prova das fatias .2 e .3

# Grade noturna (ga-sh8t23.1)

A revisão de arquitetura de 15/10 (ga-sh8t23) pede "nenhum minuto da madrugada com mais de 1 job de pico". Antes desta fatia isso não era verificável: a grade noturna só existia na cabeça e em ~410 plists. `scripts/nightly-grid.py` a lê de onde ela RODA.

## Para que serve e como rodar

```bash
python3 $GC_CITY_PATH/scripts/nightly-grid.py                      # 00:00-07:59, colisão = 3 ou mais inícios no mesmo minuto
python3 $GC_CITY_PATH/scripts/nightly-grid.py --from 03:50 --to 04:50 --min-collision 2
python3 $GC_CITY_PATH/scripts/nightly-grid.py --boot               # lista TODO o conjunto RunAtLoad
python3 $GC_CITY_PATH/scripts/nightly-grid.py --json               # a mesma coisa para outra ferramenta
```

* Lê `~/Library/LaunchAgents` (o que o launchd carregou), **não** os plists do repositório: fonte ≠ o que roda. O filtro `--match` olha o NOME do arquivo (padrão `gascity|whatsapp|gastown|urblink`, ou seja, o que é nosso).
* **Somente leitura**: não chama `launchctl load/unload`, não escreve nada, não move job. Roda quando alguém pede; não há launchd novo nem poll (detector tem custo de poll: se virar guarda, é outro bead, com `StartInterval` medido e lock de instância única).
* Códigos: 0 relatório feito (mesmo com colisão: é detecção, não bloqueio) · 2 uso errado · 3 não consegui ler a entrada (pasta, `--loaded-file` ou `--match` inválido).
* Selftest: `bash scripts/nightly-grid.selftest.sh` (hermético: plists falsos, `launchctl list` e `plutil` injetados).

## Como ler a saída (e o que cada estado quer dizer)

| Seção | O que é |
|---|---|
| Resumo | plists · ilegíveis · lidos via plutil · formato desconhecido · não carregados · RunAtLoad · calendário · StartInterval · KeepAlive |
| Minutos com N ou mais inícios | jobs **distintos** que disparam no mesmo minuto. O mesmo job em 5 dias da semana é UM (aparece `job [seg,ter,qua,qui,sex]`), não 5 colidindo |
| Grade | todo minuto da janela que tem início. `[seg]`, `[dom]`, `[dia 1]` = condicional: só vale nesse dia, mas num dia em que vale colide de verdade |
| A cada minuto por calendário | entrada sem `Minute` (curinga, como no launchd): fora das colisões |
| StartInterval por faixa | só resumo: a hora desses jobs depende de QUANDO foram carregados (depois do reboot noturno, todos juntos) |
| Sobe junto no boot | `RunAtLoad=true`, agrupado por prefixo do label |
| Ilegíveis / formato que não conheço / não carregados | os **três estados**: o que o comando não soube ler aparece com o motivo e é contado, nunca some |

Três estados que a saída NÃO mistura: **carregado: conhecido** (o `launchctl list` respondeu: plist em disco que não está carregado fica de fora das colisões e listado à parte) · **carregado: desconhecido** (o `launchctl list` falhou ou veio sem nenhum job: todos entram na grade e o relatório avisa; nunca "nada carregado") · **pasta ilegível** (exit 3, sem grade: não sei ≠ grade vazia).

## Retrato medido em 16/10/2026 08:06 (-03)

410 plists do nosso filtro: **223 com RunAtLoad**, 136 com calendário, 164 com StartInterval (11 até 1 min, 43 até 5 min, 47 até 15 min, 47 até 1 h, 16 acima), 99 KeepAlive; 8 em disco e não carregados; 2 lidos só via plutil; 1 ilegível. RunAtLoad por prefixo: whatsapp 93 · gascity 65 · urblink 47 · br.urblink 9 · gastown 8 · whatsapp-automation 1. (A bead dizia 271 RunAtLoad: o número vivo de hoje, depois de tirar os não carregados, é 223.)

Minutos com 4 ou mais jobs distintos (12 minutos têm 3 ou mais): **04:00 (5)**, **05:00 (5)**, 05:15 (4), 06:30 (4), 07:15 (4).

Janela 03:30-04:50 (a que a bead chama de pico), por minuto:

```
03:30 cpf-consolidado-freshness-check, dolthub-backup          04:15 sync-critical-dbs-hourly, ficha360-search-index-refresh
03:40 app-incorporador-purga                                    04:17 radar-viabilidade, cadastro-md-sync
03:42 backfill-display-name-hourly                              04:20 sucessao-censec-batch
03:45 itbi-drive-bridge                                         04:30 dolt-compact-routine
04:00 dolt-s3-backup, drive-cleanup, pbh-edificacao-pipeline,   04:35 lot-ficha-extra-projetos
      pipedrive-status-deadman, spe-alert-build                 04:40 pipedrive-lote-backfill-daily
04:07 ga-d81-hotpath-restart                                    04:42 backfill-display-name-hourly
04:10 sv-age-refresh, lot-docs-index-daily                      04:47 channel-health-retention
```

Onde vivem as fontes dos 5 jobs das 04:00 (para a fatia .3): `dolt-s3-backup` no HQ (`scripts/dolt-s3-backup.sh`); `spe-alert-build`, `pbh-edificacao-pipeline` e `pipedrive-status-deadman` no repositório do rig whatsapp_automation (`launchd/*-wrapper.sh`, `scripts/peter/`); `drive-cleanup.py` em `~/.gastown/scripts`, que é **um terceiro repositório git** (`~/.gastown`, nem o HQ nem o WA).

## O que a amostragem de RAM diz e o que NÃO diz

Fonte: `.gc/ram-owner-samples.jsonl` (`ram-owner-sampler`, uma amostra a cada ~5 min). Hoje há ~830 amostras, de 13/10 06:50 a 16/10 ~08:00, ou seja ~3 noites.

* Entre 03:50 e 05:00 o RSS total fica em **7,7 a 11,7 GB**, o mesmo patamar de outras horas do dia; o `dolt` sozinho é 1,1 a 2,7 GB. Swap usado de 3,0 a 7,5 GB, livre 35 a 75%. O volume tem só 3 a 6 GB livres e os arquivos de swap (4 a 5 GB) são o que o enche quando a RAM aperta: é por isso que RAM vira "disk critical".
* Donos não-Dolt que aparecem na janela: `sweep_street_view_age_bh` (até 920 MB, entre 04:11 e 04:36; **provavelmente** o `sv-age-refresh` das 04:10, mas o nome do processo não é o label do launchd: é inferência, não prova), `git pack-objects` (507 MB), Chrome e `gate-pytest` (740 MB), `compile`/`clang` (até 750 MB). Dos 5 jobs das 04:00, o maior RSS amostrado em TODAS as amostras (qualquer hora) foi `build_spe_alert` 221 MB, `sweep_pbh` 212 MB, `dolt-s3-backup` 41 MB e `drive-cleanup` 30 MB (nome de processo ≈ job: **provável**, não provado). Nenhum chega perto dos 4,5 GB que a bead cita para o `spe-alert-build` "até ontem": ou o pico foi corrigido, ou durou menos que o intervalo de 5 min e a amostra o perdeu. Os dados de hoje não decidem entre as duas.
* **Não dá para** atribuir RAM a um job do launchd: o amostrador agrupa por NOME DE PROCESSO. **Não dá para** ver job que dura menos que 5 min. **Não dá para** concluir "o pico das 04:00 é o de maior RAM" com 3 noites. Por isso a fatia .3 começa MEDINDO a pegada de cada job (label → processo → pico de RSS) e só depois move horário.

## Achados que a grade mostrou de graça

* `com.urblink.inbound-review-3d.plist` é um **symlink quebrado** (aponta para `whatsapp_automation/daemons/launchd/`, arquivo que não existe): o único ilegível de verdade. Dono: rig whatsapp_automation.
* `com.gascity.claude-crew-account.plist` e `com.gascity.mbp-nightly-reseed.plist` têm `--` dentro de comentário XML (`<!-- … --dry-run … -->`): o launchd e o `plutil` aceitam (os dois estão carregados; o mbp-nightly-reseed roda às 05:50), o `plistlib` do Python não. A primeira versão do gerador os dava como ilegíveis e os jobs sumiam da grade: agora o `plutil -convert xml1` é o plano B e eles contam em "lidos via plutil". Não é defeito do launchd; é aviso para quem for ler esses arquivos com ferramenta de XML estrito.
* 8 plists em disco e não carregados (`auto-refino-dispatcher`, `city-night-window`, `reconciler-stall-detector`, `refino-gate-dispatcher`, `property-scrapers-crew`, `contagem-verify`, `zapic-gost`, `crew-refino-sweep`). Podem estar desligados de propósito; a grade só avisa que não rodam.

## Limites

* Só entende `StartCalendarInterval` (dict ou lista de dict), `StartInterval`, `RunAtLoad` e `KeepAlive`; `WatchPaths`/`QueueDirectories` não têm horário e ficam fora.
* Horário que o launchd calcula com atraso, ou o `StartInterval` de job carregado em momentos diferentes, não aparece como colisão.
* É contagem de **inícios**, não de RAM: dois jobs no mesmo minuto não são necessariamente dois picos. Quais são "de pico" é decisão da fatia .3, com número medido.

## Como isto vira prova das fatias .2 e .3

* .3 (espalhar as 04:00): depois do deploy, `nightly-grid.py --from 03:50 --to 04:50 --min-collision 2` mostra no máximo 1 job de pico por minuto (a lista de "pico" sai da medição da .3) e o "disk critical" das 04:00-04:30 fica em zero por 7 dias, conferido no `disk-growth-*.txt` do `dolt-disk-floor-guard`, não por relato.
* .2 (`wait-for-dolt`): a lista de jobs que leem Dolt no boot sai de `--boot` + leitura do programa de cada um.
