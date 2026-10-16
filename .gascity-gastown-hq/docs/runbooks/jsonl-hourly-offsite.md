## Contents
- Ver o estado · O que cada código e alerta significa · Custo e desligar · Ainda não coberto

# Upload horário do dump JSONL ao S3 (ga-c0939v.2)

A cada hora o order `jsonl-hourly-offsite` roda `assets/scripts/jsonl-hourly-offsite.sh`: empacota o HEAD do repo do `jsonl-export`, confere o pacote lendo-o
tabela por tabela, sobe para `s3://urblink-dolt-backups/jsonl-hourly/` e só então move `latest.json`. Meta do Athos (15/10): perder no máximo 1 h de beads
(RPO real = idade do dump na captura + 60 min + a duração do run: pior caso ~1h40, típico ~1h05).

## Ver o estado
- `bash $GC_CITY_PATH/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh --status` — lê `latest.json` do S3. `STATUS: OK` quando o último ponto batido tem
  menos de 2h30 (`checked_at`); `data_as_of` diz até quando o dump enxerga. Só leitura.
- Log: `tail -5 $GC_CITY_PATH/.gc/logs/jsonl-hourly-offsite.log` (`OK`, `FALHOU:`, `UNKNOWN:`, `AVISO:`). O `RESULT: ok new|ok unchanged|fail|unknown` sai só na saída do run: não fica no log nem em `gc order history` (que mostra só quando o order disparou).
- Estado local: `$GC_CITY_PATH/.gc/runtime/packs/town-deltas/jsonl-hourly-offsite-state.json` (`consecutive_not_ok`, `last_not_ok_reason`, `last_success_at`).
- "Mergeado" não é "vivo": `gc order list` tem que listar o order e `gc order history jsonl-hourly-offsite` tem que mostrar runs.

## O que cada código e alerta significa
| Código do run | Quer dizer | O que fazer |
|---|---|---|
| `rc 0` `ok new` | snapshot novo verificado (sha256 conferido pelo S3) e `latest.json` movido | nada |
| `rc 0` `ok unchanged` | o HEAD é o mesmo do último verificado e o objeto ainda existe; só `checked_at` andou | nada (o exporter não gravou nada novo) |
| `rc 1` `fail` | upload ou conferência falhou, ou o snapshot ficou `broken` (banco obrigatório ausente/vazio, tabela ilegível): **nada sobe e `latest.json` não anda** | ler o motivo no log; um banco real com export quebrado barra o snapshot inteiro, de propósito |
| `rc 2` `unknown` | não deu para avaliar (sem `aws`/`git`/`python3`/`jq`, archive ilegível, pouco disco, estado sem como gravar) | nada foi tentado; ver o log. Conta como run sem snapshot (alerta no 2º seguido) |
| `rc 3` | uso errado da linha de comando | só em chamada manual |
- `--status`: rc 0 `OK`, rc 1 `STALE` (ponto com mais de 2h30), rc 2 `UNKNOWN` (S3 ou `latest.json` ilegível: **não** é "tudo bem"). `OK` olha só `checked_at`:
  com o exporter parado o `data_as_of` envelhece e o status segue `OK`; confira a idade do `data_as_of` impressa na mesma linha.
- Alerta: no 2º run seguido sem snapshot novo (`fail`, `unknown` ou run morto pelo timeout do order/kill/reboot, que o run seguinte conta) o script chama o `notify`
  com push forçado (`NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1`, "Jsonl hourly offsite", prioridade 4). Só conta como enviado se o `notify` sair `rc 0`: senão o log diz
  `AVISO: alerta NÃO entregue (rc=N)` e o run seguinte tenta de novo; se entregou, no máximo 1 a cada 6 h. Sem como gravar o estado, o alerta não espera o 2º run e, sem registro do último aviso, sai a cada run.
  Credencial do `aws` ausente no ambiente do order aparece assim, no 2º run: não inventar credencial, escalar para o Mayor.
- Retenção (só `jsonl-hourly/snap/`, formato exato de chave): últimas 48 h, o primeiro snapshot de cada dia UTC por 14 dias, os 6 mais novos e o apontado por `latest.json`.
  Listagem do S3 ilegível ou helper falhando => `AVISO: retenção pulada (...)`, nada é apagado e o run segue `rc 0`; se o aviso se repetir por horas, o bucket só cresce.

## Custo e desligar
~98 MB gzip por snapshot (medido): com a retenção, ~60 guardados, ordem de 6 GB. `interval = "30m"` no order leva o pior caso a ~1h10 e dobra o tráfego (decisão de produto).
Desligar: remover `packs/town-deltas/orders/jsonl-hourly-offsite.toml` (o `gc order` recarrega); os objetos em `jsonl-hourly/` podem ficar (expiram em 30 dias pela regra do bucket) ou sair com `aws s3 rm --recursive`.

## Ainda não coberto
Provar que o restore funciona (`jsonl-hourly-restore.sh`) entra nas fatias 3 e 4 de ga-c0939v. Até lá, um snapshot fresco no S3 é upload verificado, não RPO provado.
