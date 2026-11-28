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
| 2 | executor por tarefa, critério reprova-na-base/passa-no-fix, teto de tokens com freio | ga-hyp55ss.1 | aberta |
| 3 | ordem noturna no Hetzner + gatilho em merge + relatório por papel com sha de config | ga-hyp55ss.3 | aberta (depende da 2) |
| 4 | alerta ao Mayor, marca do merge causador, controle negativo | ga-hyp55ss.4 | aberta (depende da 3) |

Pronto quando: 3 noites seguidas com relatório, e uma mudança de prompt deliberadamente ruim derruba a taxa e dispara o aviso.

## Fatia 1: o acervo (`agent-battery-corpus.py`)

Lê o histórico git já mergeado (`origin/main`, últimos 60 dias) e devolve até 40 tarefas em JSONL. Uma tarefa é uma bead `ga-*`
fechada cuja entrega trouxe código de produção (`scripts/`, `packs/`, `formulas/`, `commands/`) **e** um `*.selftest.sh`. O critério de
sucesso é o próprio selftest: reprova em `base_sha` (pai do primeiro commit da bead) e passa em `fix_sha` (último commit).

Entra: assunto de commit com a bead (`fix(ga-x): …`), no máximo 4 commits, 6 arquivos de produção, 3 selftests e 300 linhas de produção,
nenhum commit de outra bead mexendo nos mesmos arquivos entre o primeiro e o último da bead, bead fechada e com enunciado de 40+ caracteres.

Não entra, e cada exclusão é contada por motivo no resumo (nada some em silêncio): arquivo fora da allowlist (`city.toml`, `agents/`,
dados), binário, `revert`, bead aberta, e qualquer telefone, CPF ou e-mail no título ou enunciado (um acerto basta; é mais estrito que o
`hetzner-pii-scan.py`, que caça lista, porque o enunciado vai inteiro para o prompt do agente).

Saída: `$GC_CITY_PATH/.gc/agent-battery/tasks.jsonl` (fora do git) + `tasks.jsonl.meta.json` com sha256, parâmetros, contagens e a ponta lida.
Escrita atômica. A seleção é determinística (ordenada por sha256 de sal + bead), então duas rodadas sobre a mesma ponta dão o mesmo acervo.

Códigos de saída: 0 ok · 2 uso errado ou git ilegível · 3 menos tarefas que `--min` · 4 não consegui gravar · 5 `bd` não respondeu em
metade ou mais das leituras. Em 2, 3, 4 e 5 nada é escrito e o acervo anterior fica como está: não saber não vira "acervo vazio".

## Como rodar

```bash
python3 -I scripts/agent-battery-corpus.py --dry-run          # só o resumo, não grava
python3 -I scripts/agent-battery-corpus.py                    # grava o acervo
bash scripts/agent-battery-corpus.selftest.sh                 # ~4 s, repositório e bd de mentira
```

## O que NÃO garante

- A fatia 1 só **monta** o acervo. Ela não confere que o selftest reprova na base nem roda agente algum: isso é a fatia 2.
- O papel (`role`) vem do roteamento da bead; beads sem roteamento ficam `sem-papel`. Mapear tarefa a papel de reviewer é decisão da fatia 2.
- Selftest que depende de relógio, rede ou estado da cidade pode não reproduzir no nó; a fatia 2 descarta e conta essas tarefas.
