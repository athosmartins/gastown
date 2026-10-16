## Contents
- Ver o estado · O que cada código e alerta significa · Custo e desligar · Ainda não coberto

# Upload horário do dump JSONL ao S3 (ga-c0939v.2)

A cada hora o order `jsonl-hourly-offsite` roda `assets/scripts/jsonl-hourly-offsite.sh`: empacota o HEAD do repo do `jsonl-export`, confere o pacote lendo-o
tabela por tabela, sobe para `s3://urblink-dolt-backups/jsonl-hourly/` e só então move `latest.json`. Meta do Athos (15/10): perder no máximo 1 h de beads.
RPO real = intervalo entre runs do `jsonl-export` + 60 min + duração do run. Medido em 48 h (78 runs, 14-16/10): intervalo mediana 27 min, p90 73, máx 189 =>
típico ~1h35, p90 ~2h20, pior medido ~4h15. **Só este order não entrega 1 h**: o gargalo é a cadência do exporter (decisão de produto).

## Ver o estado
- `bash $GC_CITY_PATH/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh --status` — lê `latest.json` do S3. `STATUS: OK` quando o último ponto batido tem
  menos de 2h30 (`checked_at`) e o script só bate o ponto se o exporter reescreveu os bancos obrigatórios nas últimas 6 h. `data_as_of` é quando o dado MUDOU
  pela última vez: cidade ociosa o envelhece sem defeito (o exporter só comita quando o dado muda; 7 intervalos > 6 h em 12 dias, até 10 h 22, com ele rodando). Só leitura.
- Log: `tail -5 $GC_CITY_PATH/.gc/logs/jsonl-hourly-offsite.log` (`OK`, `FALHOU:`, `UNKNOWN:`, `AVISO:`). O `RESULT: ok new|ok unchanged|fail|unknown` sai só na saída do run: não fica no log nem em `gc order history` (que mostra só quando o order disparou).
- Estado local: `$GC_CITY_PATH/.gc/runtime/packs/town-deltas/jsonl-hourly-offsite-state.json` (`consecutive_not_ok`, `last_not_ok_reason`, `last_success_at`).
- "Mergeado" não é "vivo": `gc order list` tem que listar o order e `gc order history jsonl-hourly-offsite` tem que mostrar runs.

## O que cada código e alerta significa
| Código do run | Quer dizer | O que fazer |
|---|---|---|
| `rc 0` `ok new` | snapshot novo verificado (sha256 conferido pelo S3) e `latest.json` movido | nada |
| `rc 0` `ok unchanged` | o HEAD é o mesmo do último verificado, o objeto ainda existe e o exporter segue escrevendo; só `checked_at` andou | nada (o dado não mudou) |
| `rc 1` `fail fonte parada` | o exporter não reescreve `<db>/issues.jsonl` dos bancos obrigatórios há mais de 6 h, ou reescreve e não comita (árvore do archive adiante do HEAD, que tem mais de 6 h), ou mtime/`git diff` não puderam ser lidos: `checked_at` NÃO anda (STALE em 2h30) e conta para o alerta; HEAD novo ainda sobe, mas não zera a contagem | `gc order history jsonl-export`, o label `exec-failed` dos beads do order e `git -C .gc/runtime/packs/maintenance/jsonl-archive status --short` (sujo + HEAD velho = não comita) |
| `rc 1` `fail` | upload ou conferência falhou, ou o snapshot ficou `broken` (banco obrigatório ausente/vazio, tabela ilegível): **nada sobe e `latest.json` não anda** | ler o motivo no log; um banco real com export quebrado barra o snapshot inteiro, de propósito |
| `rc 2` `unknown` | não deu para avaliar (sem `aws`/`git`/`python3`/`jq`, archive ilegível, pouco disco, estado sem como gravar) | nada foi tentado; ver o log. Conta como run sem snapshot (alerta no 2º seguido) |
| `rc 3` | uso errado da linha de comando | só em chamada manual |
- `--status`: rc 0 `OK`, rc 1 `STALE` (ponto com mais de 2h30), rc 2 `UNKNOWN` (S3 ou `latest.json` ilegível, ou `checked_at` no futuro: **não** é "tudo bem").
  Limite: "fonte viva" é o mtime dos arquivos; export que falha e restaura do HEAD deixa mtime novo com dado velho, e isso este order não vê.
- Alerta: no 2º run seguido sem snapshot novo (`fail`, `unknown` ou run morto pelo timeout do order/kill/reboot, que o run seguinte conta) o script chama o `notify`
  com push forçado (`NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1`, "Jsonl hourly offsite", prioridade 4). Só conta como enviado se o `notify` sair `rc 0`: senão o log diz
  `AVISO: alerta NÃO entregue (rc=N)` e o run seguinte tenta de novo; se entregou, no máximo 1 a cada 6 h. Sem como gravar o estado, o alerta não espera o 2º run e, sem registro do último aviso, sai a cada run.
  Credencial do `aws` ausente no ambiente do order aparece assim, no 2º run: não inventar credencial, escalar para o Mayor.
- Retenção (só `jsonl-hourly/snap/`, formato exato de chave): últimas 48 h, o primeiro snapshot de cada dia UTC por 14 dias, os 6 mais novos e o apontado por `latest.json`.
  Listagem do S3 ilegível ou helper falhando => `AVISO: retenção pulada (...)`, nada é apagado e o run segue `rc 0`; se o aviso se repetir por horas, o bucket só cresce.

## Custo e desligar
~75 MB gzip por snapshot e build de ~4 min (medido em 16/10, local; o upload não foi medido): com a retenção, ~60 guardados, ordem de 4,5 GB. `interval = "30m"` tira 30 min do RPO
(típico ~1h05, pior ~3h45) e dobra o tráfego (decisão de produto).
Desligar: remover `packs/town-deltas/orders/jsonl-hourly-offsite.toml` (o `gc order` recarrega); os objetos em `jsonl-hourly/` podem ficar (expiram em 30 dias pela regra do bucket) ou sair com `aws s3 rm --recursive`.

## Ainda não coberto
Provar que o restore funciona (`jsonl-hourly-restore.sh`) entra nas fatias 3 e 4 de ga-c0939v. Até lá, um snapshot fresco no S3 é upload verificado, não RPO provado.
