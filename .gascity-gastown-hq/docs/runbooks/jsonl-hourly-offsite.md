## Contents
- Ver o estado · O que cada código e alerta significa · Provar o restore · Custo e desligar

# Upload horário do dump JSONL ao S3 (ga-c0939v.2)

A cada hora o order `jsonl-hourly-offsite` roda `assets/scripts/jsonl-hourly-offsite.sh`: empacota o HEAD do repo do `jsonl-export`, confere o pacote lendo-o
tabela por tabela, sobe para `s3://urblink-dolt-backups/jsonl-hourly/` e só então move `latest.json`. Meta do Athos (15/10): perder no máximo 1 h de beads.
RPO real = intervalo entre runs do `jsonl-export` + 60 min + duração do run. Medido em 48 h (78 runs, 14-16/10): intervalo mediana 27 min, p90 73, máx 189 =>
típico ~1h35, p90 ~2h20, pior medido ~4h15. **Só este order não entrega 1 h**: o gargalo é a cadência do exporter (decisão de produto).
Que o restore funciona se prova com `jsonl-hourly-restore.sh` (seção "Provar o restore"): sem essa rodada, um snapshot fresco no S3 é upload verificado, não RPO provado.

## Ver o estado
- `bash $GC_CITY_PATH/packs/town-deltas/assets/scripts/jsonl-hourly-offsite.sh --status` — só leitura, lê `latest.json` do S3: rc 0 `OK` (ponto batido há menos de 2h30, `checked_at`), rc 1 `STALE`,
  rc 2 `UNKNOWN` (S3 ou `latest.json` ilegível, ou `checked_at` no futuro: **não** é "tudo bem"). Num run de HEAD igual o ponto só é batido se o exporter reescreveu os bancos obrigatórios nas últimas 6 h;
  um snapshot novo com a fonte parada move o ponto uma vez, mas o run sai rc 1 e conta. `data_as_of` é quando o dado MUDOU: cidade ociosa o envelhece sem defeito (o exporter só comita quando o dado muda; 7 intervalos > 6 h em 12 dias, até 10 h 22, com ele rodando).
  Limite: "fonte viva" é o mtime dos arquivos; export que falha e restaura do HEAD deixa mtime novo com dado velho, e isso este order não vê.
- Log: `tail -5 $GC_CITY_PATH/.gc/logs/jsonl-hourly-offsite.log` (`OK`, `FALHOU:`, `UNKNOWN:`, `AVISO:`). O `RESULT: ok new|ok unchanged|fail|unknown` sai só na saída do run: não fica no log nem em `gc order history` (que mostra só quando o order disparou).
- Estado local: `$GC_CITY_PATH/.gc/runtime/packs/town-deltas/jsonl-hourly-offsite-state.json` (`consecutive_not_ok`, `last_not_ok_reason`, `last_success_at`).
- "Mergeado" não é "vivo": `gc order list` tem que listar o order e `gc order history jsonl-hourly-offsite` tem que mostrar runs.

## O que cada código e alerta significa
| Código do run | Quer dizer | O que fazer |
|---|---|---|
| `rc 0` `ok new` | snapshot novo verificado (sha256 conferido pelo S3) e `latest.json` movido | nada |
| `rc 0` `ok unchanged` | o HEAD é o mesmo do último verificado, o objeto ainda existe e o exporter segue escrevendo; só `checked_at` andou | nada (o dado não mudou) |
| `rc 1` `fail fonte parada` | o exporter não reescreve `<db>/issues.jsonl` dos bancos obrigatórios há mais de 6 h, ou reescreve e não comita (árvore do archive adiante do HEAD, que tem mais de 6 h), ou mtime/`git diff` não puderam ser lidos: num run de HEAD igual `checked_at` NÃO anda (STALE em 2h30); HEAD novo ainda sobe e move `latest.json` (um `checked_at` novo, uma vez); nos dois a contagem do alerta não zera | `gc order history jsonl-export`, o label `exec-failed` dos beads do order e `git -C .gc/runtime/packs/maintenance/jsonl-archive status --short` (sujo + HEAD velho = não comita) |
| `rc 1` `fail` | upload ou conferência falhou, ou o snapshot ficou `broken` (banco obrigatório ausente/vazio, tabela ilegível): **nada sobe e `latest.json` não anda** | ler o motivo no log; um banco real com export quebrado barra o snapshot inteiro, de propósito |
| `rc 2` `unknown` | não deu para avaliar (sem `aws`/`git`/`python3`/`jq`, archive ilegível, pouco disco, estado ou lock sem como criar/gravar) | nada foi tentado; ver o log. Conta como run sem snapshot (alerta no 2º seguido) |
| `rc 3` | uso errado da linha de comando | só em chamada manual |
- Alerta: no 2º run seguido sem snapshot novo (`fail`, `unknown` ou run morto pelo timeout do order/kill/reboot, que o run seguinte conta) o script chama o `notify`
  com push forçado (`NOTIFY_FORCE_PUSH=1 NOTIFY_STRICT_EXIT=1`, "Jsonl hourly offsite", prioridade 4). Só conta como enviado se o `notify` sair `rc 0`: senão o log diz
  `AVISO: alerta NÃO entregue (rc=N)` e o run seguinte tenta de novo; se entregou, no máximo 1 a cada 6 h. Sem como gravar o estado, o alerta não espera o 2º run e, sem registro do último aviso, sai a cada run.
  Credencial do `aws` ausente no ambiente do order aparece assim, no 2º run: não inventar credencial, escalar para o Mayor.
- Retenção (só `jsonl-hourly/snap/`, formato exato de chave): últimas 48 h, o primeiro snapshot de cada dia UTC por 14 dias, os 6 mais novos e o apontado por `latest.json`.
  Listagem do S3 ilegível ou helper falhando => `AVISO: retenção pulada (...)`, nada é apagado e o run segue `rc 0`; se o aviso se repetir por horas, o bucket só cresce.

## Provar o restore
`bash $GC_CITY_PATH/packs/town-deltas/assets/scripts/jsonl-hourly-restore.sh --db NOME --from-s3 latest [--report-out F.json]` (opções e motivos: `--help`). Baixa o snapshot, confere o sha256 contra o manifest,
converte as tabelas, importa num store `bd` EMBUTIDO descartável (`env -i`, sem `.beads` em ancestral: nada fala com o Dolt de produção), exporta de volta e reconcilia: `manifest − exclusões por desenho = esperado = restaurado`.
rc 0 provado · rc 1 não reproduz · rc 2 sem veredito (pouco disco, import estourou o tempo, sem `bd`/`aws`...) · rc 3 uso. **rc 2 não é "ok" nem "quebrado"**; o `--disk-factor` e o piso de 2048 MB existem porque o volume é o do Dolt da cidade: não os afrouxe para passar.
Smoke com o `bd` real, sem S3 (3 issues): `prod-tests/gascity/story-ga-c0939v.4.sh`.

Rodada real de 17/10 (snapshot `20261017T033008Z`, dado de 03:07Z, `bd` 1.1.0, `nice -n 10`, máquina com load ~50):
| banco | rc | issues | labels | dependências | comentários | import | store | tempo |
|---|---|---|---|---|---|---|---|---|
| gastown | 0 | 2560/2560 | 881/881 (947 − 66 órfãos) | 11/11 (14 − 3 órfãs) | 429/429 (444 − 1 órfão − 14 idênticos fundidos) | 3 MB, 354 s | 168 MB | 8 min 18 s |
| whatsapp_automation | 0 | 6777/6777 | 25087/25087 (25204 − 117 órfãos) | 1966/1966 (2382 − 414 órfãs − 2 sem alvo) | 40470/40470 (40560 − 89 órfãos − 1 idêntico fundido) | 79 MB, 2698 s | 2945 MB | 48 min 30 s |
| hq | **2** | não rodou | não rodou | não rodou | não rodou | 401 MB (só convertido) | — | 95 s |
Cada célula é restaurado/esperado, com o manifest e as exclusões entre parênteses. Todo "esperado" bateu com o restaurado; issue por issue (status, título, prioridade, tipo, descrição) e filho por filho também bateram, `problems` vazio.
**hq NÃO está provado.** O guarda parou antes do import: 401 MB × 60 + 512 = ~24,6 GB exigidos contra 5,6 GB livres (o mini tem um só disco, com o volume de dados a 97%). Duas medições não dizem o hq: o store cresceu 17× de um banco para o outro (2,6× mais issues) e o import, 7,6×; extrapolado, é ordem de horas a mais de um dia e dezenas de GB, **extrapolação, não medida**. Acompanhamento: ga-c0939v.5.
Até o hq ter veredito, "restore provado" vale só para gastown e whatsapp_automation. A rodada prova que o snapshot volta e que as contas fecham; que o RPO de 1 h seja entregue é outra conta (cadência do exporter, linha 9) e continua não entregue.
Exclusões por desenho (o que o relatório conta e não esconde): tombstones (o importer pula), filhos órfãos (label/dependência/comentário de issue que o dump não traz, como wisp escrubbado), arestas cujo alvo não está no store e comentários de conteúdo idêntico que o `bd import` funde.
Fora da prova: histórico de commits do Dolt, branches, issues escrubbadas e as colunas que o importer não recebe (`unmapped_columns` no relatório; `row_lock`, `wisp_type`, `work_type`, `mol_type`, `closed_by_session`). O backup completo continua sendo o nightly (DOLT_BACKUP -> S3).
Disco: o store embutido cresce dezenas de vezes o import (~38-57× nos dois bancos medidos) e ocupa o volume do Dolt; rode um banco por vez e confira `df -h /` antes.

## Custo e desligar
~75 MB gzip por snapshot e build de ~4 min (medido em 16/10, local; o upload não foi medido): com a retenção, ~60 guardados, ordem de 4,5 GB. `interval = "30m"` tira 30 min do RPO
(típico ~1h05, pior ~3h45) e dobra o tráfego (decisão de produto).
Desligar: remover `packs/town-deltas/orders/jsonl-hourly-offsite.toml` (o `gc order` recarrega); os objetos em `jsonl-hourly/` podem ficar (expiram em 30 dias pela regra do bucket) ou sair com `aws s3 rm --recursive`.
