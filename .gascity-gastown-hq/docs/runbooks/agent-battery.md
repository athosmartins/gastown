# Bateria noturna de agentes (ga-hyp55ss)

## Contents

- Para que serve
- Fatias e estado
- Fatia 1: o acervo (`agent-battery-corpus.py`)
- Como rodar
- O que NÃO garante

## Para que serve

Prompts, skills e CLAUDE.md mudam toda semana sem medição (a prosa do E12 não moveu a aprovação de primeira: 59% com, 62% sem).
A bateria roda 20–50 tarefas reais e fechadas, com critério verificável por máquina, antes e depois de cada mudança, e grava a taxa
de sucesso por papel (dog, wa-worker, reviewer) com o sha da configuração. Queda acima do limiar avisa o Mayor e marca o merge
causador. Na v1 só mede e avisa: não bloqueia merge. Sem dado de lead no nó Hetzner (allowlist de caminhos).

## Fatias e estado

| Fatia | O quê | Bead | Estado |
|---|---|---|---|
| 1 | acervo de tarefas a partir do histórico mergeado | ga-hyp55ss | esta entrega |
| 2 | executor por tarefa, critério reprova-na-base/passa-no-fix, teto de tokens com freio | ga-hyp55ss.1 | entregue (`agent-battery-run.py`, `agent-battery-run.md`) |
| 3 | ordem noturna no Hetzner + gatilho em merge + relatório por papel com sha de config | ga-hyp55ss.3 | entregue (`agent-battery-night.py`, `agent-battery-night.md`) |
| 4 | alerta ao Mayor, marca do merge causador, controle negativo | ga-hyp55ss.4 | esta entrega (`agent-battery-alert.py`, `agent-battery-alert.md`) |

Pronto quando: 3 noites seguidas com relatório, e uma mudança de prompt deliberadamente ruim derruba a taxa e dispara o aviso.

## Fatia 1: o acervo (`agent-battery-corpus.py`)

Lê o histórico git já mergeado (`origin/main`, últimos 60 dias) e devolve até 40 tarefas em JSONL. Uma tarefa é uma bead `ga-*`
fechada cuja entrega trouxe código de produção (`scripts/`, `packs/`, `formulas/`, `commands/`) **e** um `*.selftest.sh`. O critério de
sucesso é o próprio selftest: reprova em `base_sha` (pai do primeiro commit da bead) e passa em `fix_sha` (último commit).

Entra: assunto de commit com a bead (`fix(ga-x): …`), no máximo 4 commits, 6 arquivos de produção, 3 selftests e 300 linhas de produção,
nenhum commit de outra bead mexendo nos mesmos arquivos entre o primeiro e o último da bead, bead fechada e com enunciado de 40+ caracteres.

Não entra, e cada exclusão é contada por motivo no resumo (nada some em silêncio): arquivo fora da allowlist (`city.toml`, `agents/`,
dados), binário, bead aberta, `revert` (o do git, `Revert "…"`, e o convencional) e dado pessoal: telefone, CPF, e-mail ou qualquer
sequência de 10 a 13 dígitos no título, no enunciado ou no assunto dos commits. **É heurística de forma, não garantia**: não pega nome,
endereço, número solto de 8–9 dígitos nem número colado a letra, e uma faixa como `1000-1010` é lida como telefone (exclui a mais). Um
acerto basta; é mais estrito que o `hetzner-pii-scan.py`, que caça lista, porque o enunciado vai inteiro para o prompt do agente. Beads do
WA (`wa-*`) não entram nesta fatia: o filtro é só de forma, e o enunciado de uma bead do WA pode citar lead.

Saída: `$GC_CITY_PATH/.gc/agent-battery/tasks.jsonl` (fora do git) + `tasks.jsonl.meta.json` (sha256 do JSONL, parâmetros, contagens e a
ponta lida) + `tasks.jsonl.lock` (a trava, vazia, fica ali). `role` é o papel de quem **construiu** a bead (`dog`, `wa-worker`,
`ps-worker`, `outro`, `sem-papel`), lido de `gc.session_name`: a bead fechada perde o `assignee` (13 de 13 beads medidas em 28/11) e quase
sempre o `gc.routed_to` (12 de 13), e a sessão sobra em todas (13 de 13).

Publicação do par, em ordem: (1) a trava `<acervo>.lock` (outra rodada gravando: espera até 30 s e sai com rc 4); (2) os dois
temporários prontos e no disco; (3) cópia do acervo antigo; (4) troca do acervo; (5) troca do meta, por último, porque ele é o selo: o
executor confere o `sha256` e recusa (rc 2) um par que não bate. Se o passo 5 falha, o acervo antigo volta e nenhum `.tmp-corpus-*` fica:
o par anterior continua como estava. Só a **falha dupla** (o meta não troca *e* o antigo não volta) deixa par torto; a mensagem diz
`PAR TORTO` e onde o acervo antigo ficou guardado. Um `kill` do processo entre os passos 4 e 5 (milissegundos) também deixa par torto: o
executor o recusa pelo `sha256`, salvo na 1ª gravação, quando o meta ainda não existe e ele segue sem conferir (`meta: ausente`). Um
`kill -9` em qualquer ponto pode deixar `.tmp-corpus-*` (seguros de apagar com a trava livre). Nos dois casos, rode o script de novo.

A seleção é determinística (ordenada por sha256 de sal + bead), então duas rodadas sobre a mesma ponta **e as mesmas respostas do `bd`**
dão o mesmo acervo; com uma minoria de leituras do `bd` falhando (contada em `bead_ilegivel`) o acervo muda entre rodadas. A ponta é
resolvida uma vez: o `git log` lê esse sha e o meta grava o mesmo. A saída de `git` e `bd` é lida sempre como UTF-8, então o locale de
quem roda não muda o acervo.

Códigos de saída: 0 ok · 2 uso errado (inclui `--bd` vazio ou com aspas desbalanceadas) ou git ilegível · 3 menos tarefas que `--min` ·
4 não consegui gravar · 5 `bd` não respondeu em metade ou mais das leituras. Em 2, 3 e 5 nada é escrito; em 4 o par anterior continua
como estava (a falha dupla acima é a exceção, e ela é dita). Em todos o acervo anterior vale: não saber não vira "acervo vazio".

## Como rodar

```bash
python3 -I scripts/agent-battery-corpus.py --dry-run          # só o resumo, não grava
python3 -I scripts/agent-battery-corpus.py                    # grava o acervo
bash scripts/agent-battery-corpus.selftest.sh                 # ~5 s, repositório e bd de mentira
```

## O que NÃO garante

- A fatia 1 só **monta** o acervo. Ela não confere que o selftest reprova na base nem roda agente algum: isso é a fatia 2.
- O papel (`role`) é o de quem construiu a bead, não o de quem vai ser medido: a fatia 3 deve rodar o acervo sob cada papel com
  `--as-role` (ver `agent-battery-run.md`). Não há tarefa própria de reviewer: o acervo só tem tarefas de conserto.
- Selftest que depende de relógio, rede ou estado da cidade pode não reproduzir no nó; a fatia 2 descarta e conta essas tarefas.
- Selftest apagado ou renomeado pela entrega fica em `test_files` (renomear = apagar + criar): a fatia 2 descarta a tarefa com
  `selftest_ausente_no_fix`; `prod_files` só informa.
- O filtro de dado pessoal é de forma: reduz o risco de lead no nó, não o elimina.
