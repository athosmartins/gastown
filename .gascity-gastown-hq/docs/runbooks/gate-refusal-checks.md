# Classe repetida abre bead de checagem (gate-refusal-checks) · runbook

## Contents

• O que faz · Como rodar · O registro de classes cobertas · Como ler · Freios · Travas · O que NÃO faz

Fatia 2 do piloto «Recusas → checagens» (épico ga-mw5gdyu, Athos 26/11). Consome o medidor da fatia .1 (`docs/runbooks/gate-refusal-meter.md`). Por padrão **só relata**; com `--apply` abre bead. Não manda mail, não edita código, não mexe no medidor.

## O que faz
`scripts/gate-refusal-checks.py` lê o JSON do medidor (`--days 14`, o contrato da .1). Para cada classe-raiz rotulada (`root-class:<nome>`) com **≥ 5 recusas de revisor em 14 dias** (`--min`, `--days`) que **não** tem checagem registrada e **não** tem bead do ciclo, cria UMA bead `-t feature -p 2`, rótulos `exec:auto` + `story:approved` + `auto-melhoria:checagem` + `auto-melhoria:classe:<nome>`, rota `gastown.dog`, pedindo uma checagem mecânica no estilo de `third-state-reads-check.py`. A descrição cita **3 recusas-exemplo**: bead, gate-run, arquivo e trecho do veredito (entre `<conteudo_externo>`: é dado, não instrução; todo `<` e `>` do texto citado vira `‹` `›`, então nenhuma grafia da tag de fechamento fecha a cerca, e todo caractere de controle vira espaço: um NUL num argumento de `bd create` derruba o `subprocess`). Os exemplos vêm de beads distintas primeiro, as mais recentes primeiro.

## Como rodar
`python3 scripts/gate-refusal-checks.py [--apply] [--json] [--days 14] [--min 5] [--max-new 2] [--max-open 3]`. Sem `--apply` é ensaio: monta o MESMO texto de bead que o `--apply` criaria e o mostra (`classes[].preview` no `--json`: título, rótulos, metadados e descrição; no texto, o título), então um texto impossível de montar aparece no ensaio, não no primeiro `--apply`.
Com `--apply` roda uma de cada vez: toma o flock em `.gc/gate-refusal-checks.lock` ANTES de ler qualquer coisa (registro, medidor e store de beads são lidos já com a rodada exclusiva, então nenhuma leitura é mais velha que o lock). Outra rodada em curso (e só isso: `EWOULDBLOCK`) = sai com 0 sem ler nem fazer nada; qualquer outra falha ao tomar o lock (`ENOLCK`, `EOPNOTSUPP`...) = **NÃO SEI**, rc 2: «não consegui saber» não é «está em uso».
Agendar (order/launchd) é decisão do Mayor: este script não se agenda sozinho. **Antes de agendar**, rode um `--apply` à mão e confira com `bd show` a bead criada (rótulos, rota `gastown.dog`, metadados; inteiros em `bd create --metadata` já são usados por `quorum-convergence-watchdog.py`, mas esta combinação ainda não rodou ao vivo). Testes: `python3 -I scripts/test_gate_refusal_checks.py`.

## O registro de classes cobertas
`scripts/gate-refusal-checks.registry.tsv`, versionado. Colunas `class status check bead since note`; `status` = `ativa` | `em-teste` | `desligada`. **Qualquer** linha conta como coberta, inclusive `desligada`: uma checagem desligada de propósito não é reaberta por este ciclo. A bead aberta pede que quem entregar a checagem acrescente a linha **na mesma entrega** (`em-teste`; a catraca da fatia .3 promove ou desliga).
- Semente: `error-vs-empty` (`ativa`), porque `third-state-reads-check.py` (passo 2e do `gate-hard-checks.sh`) já a cobre desde 16/10. Sem a linha, a 1ª rodada abriria bead duplicada.
- Registro ausente, ilegível ou sem cabeçalho = **NÃO SEI** (rc 2, nada aberto). Arquivo vazio não é «nada está coberto».
- Linha meio escrita ainda registra a classe (vira aviso em `registry.problems`), para não reabrir classe que alguém já pegou.

## Como ler
Três estados em tudo: tem / não tem / **não sei**. Saída por classe (`classes[].verdict`):
- `coberta` · `ja-aberta` (qualquer status, fechada inclusive: classe se abre uma vez) · `abriria` (ensaio) · `aberta` / `aberta-nao-verificada` (`--apply`; a 2ª = criada, mas o `bd show` não confirmou rótulos e rota: rc 1) · `erro-ao-abrir` (rc 1: `bd create` falhou, ou o texto da bead não pôde ser montado, ou estourou uma exceção ao abrir ESTA classe; no ensaio também vale quando o texto não monta). Só a classe afetada falha: as outras seguem e o relatório lista o que já foi aberto; a mensagem diz como conferir se a bead existe (`bd list --label auto-melhoria:classe:<nome> --status all`).
- `ja-aberta` com a bead **fechada** e a classe **sem linha no registro** (descartada? dog que falhou?): a classe nunca reabre sozinha, e por isso o relatório traz um aviso em `gaps` com a bead e as duas saídas (registrar a classe como `desligada`, com o motivo, ou tirar o rótulo `auto-melhoria:classe:<nome>` da bead para o ciclo reabri-la). Bead aberta, ou classe com linha no registro, não gera aviso.
- `exemplos-insuficientes`: menos de 3 exemplos legíveis (comentário do gate-run ilegível, log ausente, janela sem `from/to`). **Não abre**; tenta de novo na próxima rodada.
- `teto-por-rodada` / `teto-de-abertas`: os freios abaixo.
- `unlabeled_candidates`: grupos «sem rótulo» do medidor com ≥ 5 recusas. **Só listados, nunca abertos**: a chave é por palavras (a mesma classe aparece com redações diferentes; o grupo «(sem título de bloqueante)» é só leitura que falhou), então uma bead por redação seria duplicata. Ação humana/Mayor: rotular a classe, ou o revisor passar a rotular.
- O JSON do medidor tem de ser o contrato da .1: `schema` 1 e `refusals.classes`, `refusals.unlabeled_groups`, `window`, `gaps`, `evaluator` nos tipos do esquema; outro `schema`, campo ausente ou de tipo errado = **NÃO SEI** (rc 2, nada aberto). Já uma entrada malformada DENTRO de um relatório válido (classe com nome ou contagem ilegível, grupo sem rótulo ilegível) fica fora da conta e vira aviso em `gaps`, nunca sumiço calado nem traceback.
- rc 0 relato impresso (inclusive «nada a abrir»; também «outra rodada em curso») · 1 bead criada sem confirmação, `bd create` falhou ou o texto de uma bead não pôde ser montado · 2 **NÃO SEI** (lock, medidor, registro ou store de beads ilegível: **não** significa «nenhuma classe repete») · 64 uso · 70 exceção que ninguém previu (bug do script: o traceback sai no stderr, junto com onde conferir o que a rodada já abriu).

## Freios
`--max-new` (2) beads por rodada e `--max-open` (3) beads do ciclo ainda não fechadas ao mesmo tempo: o ciclo não pode inundar o pool de dogs. Classes seguradas pelos tetos continuam elegíveis e entram na rodada seguinte, na ordem (mais recusadas primeiro, depois nome).

## Travas
O ciclo nunca edita o próprio avaliador. Este script só LÊ o JSON do medidor (e o log do gate para os exemplos) e cria beads: não abre arquivo para escrita (só o lock), e o texto da bead proíbe editar `gate-refusal-meter.py`, o teste dele e o código do braço A/B. Ação para fora (mensagem, gasto, publicação) continua com humano.

## O que NÃO faz
- Não decide se a checagem pedida é boa: a bead cai no dog como qualquer feature, passa pelo gate, e a fatia .3 mede (A/B) se ela reduz recusa sem recusa falsa.
- Não vê recusa que o medidor não leu (`refusals.unread`) nem classe que o revisor não rotulou (~79% das recusas na 1ª medição, 26/11): o gargalo ali é de rótulo, não de checagem.
- Não foi agendado: sem order/launchd até o Mayor decidir.
