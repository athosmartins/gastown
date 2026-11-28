# Bateria noturna de agentes — executor por tarefa (ga-hyp55ss.1, fatia 2)

## Contents

- Onde se encaixa
- O que faz
- Como rodar
- O que NÃO garante

## Onde se encaixa

Fatia 2 da bateria (ga-hyp55ss: prompts, skills e CLAUDE.md mudam sem medição; a bateria mede a taxa de sucesso por papel com o sha da
configuração). A fatia 1 (`agent-battery-corpus.py`, runbook `agent-battery.md`) monta o acervo; esta fatia roda cada tarefa. A fatia 3
agenda a rodada noturna e o relatório; a 4 avisa o Mayor. O executor só lê o **formato** do acervo (JSONL + `.meta.json` com `sha256`),
não importa código da fatia 1.

## O que faz

Lê o acervo da fatia 1 e roda cada tarefa num worktree descartável (sempre removido). Grava um JSONL por rodada em
`<state-dir>/runs/run-<UTC>.jsonl` (+ `.summary.json`), uma linha por tarefa: `{task, papel, config_sha, estado, ok, tokens, motivo}`.

Por tarefa: (1) valida os campos; (2) confere que o selftest **passa em `fix_sha` e reprova em `base_sha`** (com só os `test_files` do fix
copiados para cima da base), senão descarta e conta o motivo; (3) põe por cima do checkout a configuração sob teste (`--config-ref`,
padrão `origin/main`: `.claude/`, `CLAUDE.md`, `<prefixo>/CLAUDE.md`) e roda `claude -p` com o enunciado da bead e o prompt do papel
(`--append-system-prompt-file`); (4) restaura os selftests do fix (o agente não passa editando o teste) e roda: passou = `ok`.
`config_sha` = hash dessa configuração + do prompt do papel; muda quando qualquer um deles muda.

**Segurança.** `success.commands` do acervo é uma string `bash <caminho>` e **nunca** vai a um shell: o argv `['bash', caminho]` é montado
aqui. `test_files` precisa casar `^[A-Za-z0-9._/-]+\.selftest\.sh$` (sob `scripts/ packs/ formulas/ commands/ docs/`, sem `..`, `//`, `/./`),
`prod_files` o equivalente sem o sufixo, `task_id`/shas/papel têm regex própria. Linha que não casa vira `descartada` com motivo
`argumento_invalido:<campo>` e é contada no resumo. O ambiente do agente é montado por **lista de permitidos**
(`PATH LANG LC_* TERM USER LOGNAME CLAUDE_CONFIG_DIR` + `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_API_KEY`); `SSH_AUTH_SOCK`, `GIT_*`, strings
de conexão e o resto não passam. Com credencial em env, `HOME` e `TMPDIR` são um diretório descartável; sem ela (login guardado no
`HOME`) o `HOME` é o real, porque senão o claude não autentica. O agente só pode **rodar o selftest da própria tarefa**
(`--allowedTools Bash(bash <test_file>:*)`); ler e editar dentro do checkout vem de `--permission-mode acceptEdits`. Sem `bash scripts/*`,
`cat`, `git`, rede (`WebFetch`/`WebSearch` negados). O selftest roda com ambiente mínimo e limite de tamanho de arquivo.

**Limite que fica.** Isto restringe as ferramentas do claude, não é sandbox do sistema: o selftest da tarefa executa o código que o
agente acabou de escrever, com os privilégios do operador. As tarefas vêm do histórico mergeado do próprio repositório (acervo com
allowlist e checagem de sha), não de entrada externa. Para rodar com credencial de outra conta ou fora do mini, use a credencial em env
(`HOME` descartável) e, se o risco mudar, um contêiner/VM em volta do executor. As flags de permissão **não foram exercitadas contra o
claude real** (login expirado no mini em 28/11/2026: a chamada devolve `is_error` e o executor a conta como `infra`); a primeira rodada
real deve ser vigiada.

**Estados.** `medida` (rodou o agente e conferiu o selftest: só ela entra na taxa) · `descartada` (tarefa não serve; motivo) ·
`pulada` (freio, ou papel sem prompt) · `infra` (login, cota, API ou saída ilegível: não é falha do prompt, não entra na taxa) ·
`verificada` (só com `--verify-only`). Timeout do agente e `error_max_turns` são falha **medida**: um prompt que faz o agente girar
sem parar é exatamente a regressão que a bateria tem de ver.

**Teto de tokens.** `--token-cap` por noite (padrão 2 000 000; tokens = entrada + saída + cache_creation, `cache_read` vai à parte no
registro) e `--task-budget-usd` por tarefa (`--max-budget-usd` do CLI). O ledger é `<state-dir>/spend-<dia UTC>.json` e soma entre
rodadas do mesmo dia. Antes de cada tarefa: gasto + `--task-reserve-tokens` (padrão 400 000) > teto → a rodada **para limpa**, o resto
vira `pulada` (`teto_de_tokens`) e sai rc 6. Saída do agente ilegível, ou sem o bloco de uso, é gasto *desconhecido* e é cobrado como a
reserva, nunca como zero. Três tarefas `infra` seguidas também param a rodada (rc 8). O teto é de **admissão**: uma tarefa que já
começou pode passar dele (no máximo pela reserva), e o resumo diz `teto_excedido`.

Códigos de saída: 0 ok · 2 uso errado, acervo ou git ilegível (inclui sha256 do acervo que não bate com o `.meta.json`) · 3 nenhuma tarefa ·
4 não consegui gravar saída ou ledger · 5 ledger ilegível (não sei quanto já gastei: nada roda) · 6 freio de tokens (parcial gravado) ·
7 outra rodada em andamento · 8 `claude` ausente ou infra repetida. Em 2, 3, 5, 7 e 8-na-largada nada é gravado.

## Como rodar

```bash
python3 -I scripts/agent-battery-run.py --dry-run             # plano: nº de tarefas, config_sha por papel, gasto do dia
python3 -I scripts/agent-battery-run.py --verify-only         # só confere reprova-na-base/passa-no-fix; sem claude, sem token
python3 -I scripts/agent-battery-run.py --limit 3 --token-cap 300000   # rodada curta de verdade
scripts/heavy-guard.sh --what selftest-battery-run --max-file-mb 512 -- bash scripts/agent-battery-run.selftest.sh   # ~1 min, claude de mentira
```

## O que NÃO garante

- O papel (`role`) vem do roteamento da bead; beads sem roteamento ficam `sem-papel` e são puladas (`papel_sem_prompt`). Mapa papel → prompt:
  `dog` → `agents/dog-remote`, `wa-worker`, `ps-worker`, `reviewer` → `agents/gate-reviewer` (`--role-prompt PAPEL=CAMINHO` troca).
  **Reviewer não tem tarefa própria**: o acervo só tem tarefas de conserto, então `--as-role reviewer` aplica o prompt de revisão a uma
  tarefa de conserto e mede se aquele prompt ainda deixa o agente consertar. Uma bateria de revisão de verdade (achar defeito plantado)
  é decisão de produto adiada para a fatia 3.
- O `claude -p` roda dentro do prefixo da cidade num checkout; `.claude/` e `CLAUDE.md` vêm da raiz do git. Quem decide se o CLI carrega
  as configurações de um diretório acima é o CLI, não este script: confirmar na primeira rodada real no Hetzner (fatia 3).
- Selftest que depende de relógio, rede ou estado da cidade pode não reproduzir no nó: é descartado e contado, não esconde taxa.
  Selftest que não consegue rodar (126/127) ou estoura `--selftest-timeout` (padrão 600 s; há selftests reais de 3+ min) é `descartada`
  (`selftest_nao_rodou_*`), nunca "reprovou".
- No acervo real de 28/11, 39 de 40 tarefas vêm `sem-papel` (a bead fechada perdeu o roteamento). Sem `--as-role` elas são `puladas`; a fatia 3
  deve rodar o acervo sob cada papel com `--as-role` (a taxa é do prompt sob teste, não do papel original da bead).
  Verificação real em 6 tarefas desse acervo: 4 reprovam na base e passam no fix, 2 estouraram o prazo de 120 s antigo (daí o novo padrão).
- A taxa de uma noite com poucas tarefas `medida` é ruído; o relatório e o limiar de queda são da fatia 3/4.
- `ok` mede "o selftest da bead passa", não "a mudança é boa": o agente pode passar o teste com uma solução feia.
