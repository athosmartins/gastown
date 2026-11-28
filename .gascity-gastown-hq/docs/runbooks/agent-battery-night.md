# Bateria noturna de agentes — ordem no Hetzner e gatilho de merge (ga-hyp55ss.3, fatia 3)

## Contents

- O que faz
- Ligar
- Vereditos
- Onde grava
- Gatilho de merge
- Tetos de tokens
- Medido e NÃO verificado

## O que faz

Fatia 3 da bateria (ga-hyp55ss): a 1 monta o acervo (`agent-battery.md`), a 2 roda cada tarefa (`agent-battery-run.md`), **esta agenda**. Toda manhã (06:40 local, ordem `hetzner-agent-battery`) e a cada
mudança de configuração (ordem `hetzner-agent-battery-merge`, sondagem a cada 20 min), `scripts/agent-battery-night.py` manda o acervo ao nó e roda o executor uma vez por papel (dog, wa-worker, reviewer),
em paralelo, cada um com estado e teto de tokens próprios. Grava a taxa por papel com o `config_sha`, escreve o relatório e avisa o Mayor. Na v1 só mede e avisa: não bloqueia merge e não compara com a
noite anterior (fatia 4).

## Ligar

Sem o 1 ou o 2 a noite é **INERTE** (exit 0) e o e-mail diz qual falta; sem o 3, **PULADO**:
1. **Acervo** em `$GC_CITY_PATH/.gc/agent-battery/tasks.jsonl` + `.meta.json` (fatia 1: `python3 -I scripts/agent-battery-corpus.py`; no dia desta entrega ela ainda está no branch `feat/ga-hyp55ss-bateria-agentes-corpus`, que o gate não passou).
2. **Chave do claude para o nó**: `ABN_TOKEN_CMD` no ambiente das ordens, um comando cujo stdout é a chave. Para seguir a conta atual do pool do mini (decisão do Athos de 20/10, `hetzner-claude-login.md`; é o que o
   `gc-session-ssh` faz: `current` do arquivo do pool → item `claude-oauth-token-<e-mail>`):
   `sh -c '"$HOME"/.local/bin/secret claude-oauth-token-$(jq -r .current /caminho/claude_pool_current_account.json)'` (o `current_file` está em `.gc/session-ssh.json`, bloco `claude_account` do host). O selftest roda esta forma
   com `secret` e arquivo de mentira; **a chave real nunca foi lida**. A chave vai ao nó só pela entrada padrão do ssh e é escondida de relatório, jsonl, e-mail e stdout.
3. **Nó ligado**: `$GC_CITY_PATH/.gc/hetzner-node.on`. Sem ele: PULADO.

Depois de carregar as ordens: `gc order show hetzner-agent-battery`; a 1ª noite à mão: `python3 -I scripts/agent-battery-night.py --mode night` (`--help` lista as opções; cada uma vem também de `ABN_<NOME>`).

## Vereditos

Última linha do stdout: `VEREDITO: <x>`. Um papel nunca vira taxa 0 por não ter sido medido (`taxa: null`).

| Veredito | Quando | Exit | E-mail ao Mayor |
|---|---|---|---|
| COMPLETO | todo papel com ao menos `--min-medidas` (5) tarefas medidas (parar no teto de tokens com amostra suficiente conta) | 0 | noite sim, merge não |
| INERTE | nada pôde rodar por falta de pré-requisito: sem acervo, sem `ABN_TOKEN_CMD`, `claude` ausente no nó, acervo sem tarefa utilizável | 0 | noite sim (diz o que falta), merge não |
| FALHOU | não dá para dizer o que aconteceu: nó fora, executor ausente ou morto pelo prazo, resumo ilegível, papel com poucas medidas, resultados misturados (inclui "um papel INERTE e outro não"), erro do driver | 1 | sim (no merge, só se um papel chegou a rodar) |
| PULADO | por escolha: nó desligado, outra rodada em andamento (um lock por modo) | 0 | não (a noite deixa a linha no jsonl) |

E-mail que falha = exit 1 e `mail_failed: 1` no jsonl. Merge: o papel pulado (bateu no teto do dia, ou o executor dele estava ocupado) fica de fora e os outros decidem.

## Onde grava

- `$GC_CITY_PATH/.gc/logs/agent-battery.jsonl`: uma linha por rodada (noite: sempre; merge: só se um papel chegou a rodar). Campos: `ts, mode, dia, verdict, reason, wall_s, min_medidas, mail_failed` e
  `papeis.<papel>.{cat, motivo, rc, config_sha, config_ref_sha, medidas, ok, taxa, por_estado, descartes, freio, tokens}`. **É isto que a fatia 4 lê.**
- `.gc/logs/agent-battery/<dia>.md` (noite) e `<dia>-merge-<HHMMSS>.md`: relatório (tabela por papel, motivo de cada problema); os `.md` com mais de 14 dias (`--keep-days`) são apagados.
- `.gc/agent-battery/`: `merge-last.json` (o `config_sha` por papel que o gatilho compara), `night.lock`, `merge.lock`. No nó: `~/gt-remote/agent-battery/` (acervo, e `night/<papel>/` e `merge/<papel>/` com o ledger de tokens e os `runs/` do executor).

## Gatilho de merge

A sondagem não olha o git do mini: pergunta ao nó, por `--dry-run` do executor (sem token, sem gasto), o `config_sha` de cada papel no `origin/main` do **espelho** do nó (atrasa até 5 min) e mede só o papel cujo sha difere do último
medido. A noite grava o que mediu em `merge-last.json`, então merge logo depois não repete. 1ª sondagem só grava a base. Uma mudança é tentada **uma vez** (falhou? a noite repete; papel pulado por teto ou por executor ocupado não conta
como tentado). Sondagem sem resposta do nó, falha antes de rodar um papel, INERTE e PULADO viram uma linha de stdout, sem relatório nem e-mail.

## Tetos de tokens

`--night-cap` e `--merge-cap`: 1 200 000 **por papel** (palpite, não medido: 5 tarefas a ~200 mil cabem com a reserva de 400 mil do executor). Pior caso da noite: ≈ 3 × 1,2 M (o teto é de admissão: uma tarefa já começada pode passar dele); o merge tem teto próprio por dia UTC (estado separado).
A 1ª noite real diz quanto custa uma tarefa: ajuste por `ABN_NIGHT_CAP`/`ABN_MERGE_CAP`. Quanto da cota da conta do pool isto pode gastar é decisão de custo do Athos; a bateria só respeita o teto. Teto baixo demais aparece como FALHOU
"N medidas (mínimo 5)", com `estados` e `descartes` no motivo.

## Medido e NÃO verificado

**Medido (28/11, neste nó):** o driver rodou contra o `agent-battery-run.py` REAL do espelho: `--dry-run` aceito com todas as flags, `config_sha` distinto para os 3 papéis, e uma noite inteira com tarefa de SHA falso (descartada, sem chamada
de modelo) gerou resumo lido, relatório e jsonl. As flags do `claude` que o executor usa (`--append-system-prompt-file`, `--setting-sources`, `--max-budget-usd`, `--no-session-persistence`, `--allowedTools`) constam no `claude --help` do nó (2.1.302).

**NÃO verificado:** nenhuma rodada chamou o `claude` de verdade (sem chave nesta sessão): custo por tarefa, se o CLI carrega `.claude/` e `CLAUDE.md` do checkout no prefixo da cidade, e a receita do `ABN_TOKEN_CMD` com a chave real.

**Limites que ficam:**
- O que o `config_sha` enxerga é só `.claude/` (com as skills de projeto), `CLAUDE.md`, `<cidade>/CLAUDE.md` e o `prompt.template.md` do papel. **Não** entram `packs/town-deltas/template-fragments/` (1500 linhas de doutrina da cidade),
  `<cidade>/skills/` nem os `claude-overlays`: o executor passa o template cru, sem os `global_fragments` do `city.toml` que o gc acrescenta ao prompt de verdade. Um merge só nisso não dispara o gatilho e não é medido. Fechar isso é mudar o executor (fatia 2): follow-up.
- O papel `reviewer` mede se o prompt de revisão ainda deixa o agente **consertar** uma tarefa do acervo, não se ele acha defeito (acervo só tem tarefas de conserto; ver `agent-battery-run.md`).
- O executor roda do `origin/main` do nó e o prazo (`--run-timeout-s`, 9000) o mata no nó: o parcial dele (`*.partial`) fica lá e a noite sai FALHOU "estourou o prazo".
- Os 3 executores rodam ao mesmo tempo no nó, junto com o que mais ele fizer; a ordem da noite fica fora da janela do WA (05:00-08:40Z) e do reseed (08:55Z), o gatilho de merge não tem janela.
- A taxa de uma noite com poucas medidas é ruído (o relatório avisa abaixo de 10); `ok` mede "o selftest da bead passa", não "a mudança é boa".

Teste: `bash scripts/agent-battery-night.selftest.sh` (~15 s parado, ~25 s com o nó carregado; ssh de mentira que executa o comando remoto de verdade contra um repositório local com um executor de mentira).
