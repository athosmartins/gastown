# Como reproduzir (ga-kp9vbf)

Relatório: `../prompt-inicial-ga-kp9vbf.md`. Tudo roda daqui (`cd` para esta pasta). Só leitura, exceto os passos 4–5, que chamam `claude -p`.

| passo | comando | o que produz |
|---|---|---|
| 1 | `bash render_primes.sh` | `primes/<papel>.md` — o `gc prime` real de cada papel |
| 2 | `python3 usage_scan.py 600 > sessions.json` | 1 registro por sessão de `~/.claude/projects/*/*.jsonl`: 1º turno (input/escrita/leitura de cache), turnos, tokens por categoria, tools, procedimentos e detectores de violação (14 s) |
| 3 | `python3 procs.py` / `python3 skillfire.py` / `python3 psw.py ps-worker 4` | uso por procedimento, taxa de disparo de skill, o que as sessões ociosas do ps-worker fazem |
| 4 | `python3 count_roles.py dog wa-worker ps-worker gate-reviewer refino-gate-reviewer auto-refiner mayor peter-wa` | tokens EXATOS de cada prime (diferença de uso contra um baseline de 2.602 tokens). **Gasta ≈ 320 mil tokens** |
| 5 | `python3 cache_probe.py P0 P1 P2 P3 P4 P5 P6 P7` | a prova de cache (doutrina na mensagem × no system prompt). **Gasta ≈ 330 mil tokens.** Escreve `sys_D*.txt` e `probe_cwd/` aqui (apague depois) |
| 6 | `python3 hitrate.py` → `python3 cost2.py` → `python3 breakdown.py` → `python3 projection.py` | taxa de acerto de cache pelos intervalos entre sessões, custo em WTE, de onde vem o gasto, projeção por alavanca e tabela de poder |
| 7 | `python3 inventory.py` / `python3 dup2.py` / `python3 skeleton.py primes/dog.md 2` | seções por papel, repetição dentro do prime, esqueleto por título |

`examples.py <papel> x '<regex>' '<regex a excluir>' [N]` imprime comandos reais que casam um detector — foi assim que os detectores foram validados (dois deles estavam errados na 1ª versão: ver "Limites" no relatório).

Os JSON desta pasta (`role_tokens`, `hitrate`, `cost2`, `projection`, `td_sections`) são as saídas usadas nas tabelas. `sessions.json` e `primes/` não foram commitados: são regeneráveis (o 1º tem 320 KB).

**Janela dos dados:** os transcritos retidos só cobrem 23–26/09 (revisores) e 30/09–01/10 (dog, wa-worker, ps-worker, refinadores). Rodar de novo mais tarde dá números diferentes; compare o `usage_scan.py` por data, nunca valores entre janelas.

**Unidade de custo — WTE** (weighted token-equivalents; preço de entrada = 1): entrada 1×, escrita de cache de 1 h 2×, leitura de cache 0,1×, saída 5×. Os multiplicadores são os preços públicos, **não foram medidos aqui**; toda escrita observada (2 transcrições de dog inspecionadas + as 16 sondas) é do nível de 1 h.
