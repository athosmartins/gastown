# E4 — scripts do estudo do histórico de reprovações do gate (ga-26k2y1)

Relatório: `../gate-e4-historico.md`. Estes scripts reproduzem TODOS os números dele a partir do Dolt vivo (somente leitura) e de chamadas `claude -p` em lote.
O dataset (`e4.db`, ≈120 MB — guarda os diffs completos que o revisor viu) NÃO vai pro repositório; ele nasce ao lado dos scripts (ver `.gitignore`).
Rode de uma cópia da pasta fora da árvore versionada, ex.: `.gc/agents/dogs/<você>/exp-e4/` (foi onde o estudo rodou).

## Ordem (cada passo lê só o anterior; `nice -n 10`, concorrência baixa — a máquina roda com load 40+)

| # | script | faz | tocam LLM? |
|---|---|---|---|
| 1 | `e4_extract.py` | Dolt (hq, whatsapp_automation, property_scrapers, gastown) → `x_*` no sqlite: comentários de gate por DIA (mês inteiro estoura o `read_timeout` de 30 s do hq), beads+labels, beads `gate-run` e cabeçalho da tarefa do revisor. Porta lida do `dolt-config.yaml` vivo. | não |
| 2 | `e4_parse.py` | `attempts` (uma linha por desfecho do gate), `bi` (um blocking issue por linha), `runs2` (registro de runs). PASS duplicado por (bead, sha de merge) colapsa; comentário que começa com `GATE-FEEDBACK` mas não abre com o cabeçalho `(gate_run=` (resposta de construtor, parecer postado à mão) não é veredito e fica fora — 5 casos, listados no fim da execução. | não |
| 3 | `e4_runs_aug.py` | tamanho EXATO do diff e flag de diff parcial (o cabeçalho `FULL DIFF`/`PARTIAL DIFF`; a linha de resumo vem cortada nos diffs grandes). | não |
| 4 | `e4_beads.py` | `bead_out`: desfecho por bead + traços do lado da história e do construtor. | não |
| 5 | `e4_sample.py` | censo de classificação (todos os blocking issues, ordem de prioridade) + amostra de 10% do 2º julgamento. | não |
| 6 | `e4_classify.py --tag primary --model sonnet --effort medium --batch 8` e `--tag second --model claude-opus-5-5 --ids-file second_ids.txt` | classificação com taxonomia FIXA (`taxonomy_prompt.md`), em lote, retomável. | sim (≈US$ 17) |
| 7 | `f6_fetch.py` → `f6_analyze.py` → `f6_judge.py --tag main` → `f6_git.py --tag git --audit 0` | Frente 6 (defeito latente): tarefas completas, visibilidade mecânica, juiz por bead, 2ª passada com `git show` e auditoria mecânica de todos os rótulos (arquivos citados + alterados nas rodadas 1 e N; `--audit-only` refaz só a auditoria, sem LLM). | sim (≈US$ 19) |
| 7b | `e4_backfill_tristate.py --raw-dir <pasta com raw_f6_main/ raw_f6git_git/ raw_pairs_main/>` | só para um dataset criado ANTES da correção dos tri-estados: reescreve como NULL os booleanos que o modelo deixou de preencher (antes gravados como 0) a partir da saída bruta guardada, e recalcula as flags de diff parcial dos pares. `--dry-run` só conta. Um dataset novo já nasce certo. | não |
| 8 | `pairs_select.py` → `pairs_judge.py --tag main` | pares reprovado→aprovado: o que a correção acrescentou. Grava as flags de diff parcial; `e4_final.py`, `e4_extras.py` e `e4_lint.py` analisam só os pares com diff completo nos dois lados (227 de 264). | sim (≈US$ 4,5) |
| 9 | `e4_stats.py`, `e4_stats2.py`, `e4_final.py`, `e4_ceilings.py`, `e4_extras.py`, `e4_lint.py` | todas as tabelas do relatório; cada percentual sai com n. | não |

## Notas de proveniência (o que o leitor precisa saber para não se enganar)

* **Fusos:** timestamps do Dolt são UTC. Corte de regime = 2026-09-25 16:04Z (25/09 13:04 -03, prompt v2 do revisor — ga-6aj348).
* **Ids curtos:** `e4_classify.py`/`f6_judge.py`/`f6_git.py` mostram ao modelo ids locais do lote (`1..N`, `q1..qN`), não os ids de 60 caracteres: numa execução anterior o modelo os encurtava (≈3% dos lotes falhavam com "missing ids"). Os lotes de repetição da classificação reiniciam a numeração (`primary-0000…`), então `raw_primary/primary-000x.txt` guarda o reprocesso, não o 1º passe.
* **Retomável:** re-rodar qualquer passo com LLM só refaz o que falta (tabelas `cls_*`, `f6_judge_*`, `f6_git_*`, `pair_out_*`).
* **Somente leitura:** nenhum script escreve no Dolt nem em repositórios; `git show`/`cat-file` apenas. Nenhum comenta/fecha bead.
* **Dataset pequeno por desenho:** o texto completo dos diffs só é baixado para as runs que a Frente 6 e os pares precisam (`task_full`, ≈30 MB); as demais guardam só os 6.000 primeiros caracteres da tarefa.
* **Anomalias achadas e corrigidas no caminho** (estão no relatório, seção "Limites"): a contagem por substring de `GATE-FEEDBACK` dobra os vereditos; 13% dos registros PASS eram a 2ª variante do comentário (`… but NOT closing …`) do mesmo merge; a linha de resumo do diff vem cortada nos diffs grandes; o delta dos pares com diff PARCIAL lê arquivos omitidos como mudança da correção (por isso só os pares de diff completo são analisados); um campo booleano ausente na resposta do modelo não pode virar 0 (`f6_analyze.tri`).
