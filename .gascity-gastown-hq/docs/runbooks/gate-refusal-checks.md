# Classe repetida abre bead de checagem (gate-refusal-checks) · runbook

## Contents

• O que faz · Como rodar · O registro de classes cobertas · Como ler · Freios · Travas · O que NÃO faz

Fatia 2 do piloto «Recusas → checagens» (épico ga-mw5gdyu, Athos 26/11). Consome o medidor da fatia .1 (`docs/runbooks/gate-refusal-meter.md`). Por padrão **só relata**; com `--apply` abre bead. Não manda mail, não edita código, não mexe no medidor.

## O que faz
`scripts/gate-refusal-checks.py` lê o JSON do medidor (`--days 14`, o contrato da .1). Para cada classe-raiz rotulada (`root-class:<nome>`) com **≥ 5 recusas de revisor em 14 dias** (`--min`, `--days`) que **não** tem checagem registrada e **não** tem bead do ciclo, cria UMA bead `-t feature -p 2`, rótulos `exec:auto` + `story:approved` + `auto-melhoria:checagem` + `auto-melhoria:classe:<nome>`, rota `gastown.dog`, pedindo uma checagem mecânica no estilo de `third-state-reads-check.py`. A descrição cita **3 recusas-exemplo**: bead, gate-run, arquivo e trecho do veredito (entre `<conteudo_externo>`: é dado, não instrução). Os exemplos vêm de beads distintas primeiro, as mais recentes primeiro.

## Como rodar
`python3 scripts/gate-refusal-checks.py [--apply] [--json] [--days 14] [--min 5] [--max-new 2] [--max-open 3]`. Sem `--apply` é ensaio: diz o que abriria. Com `--apply` roda uma de cada vez (flock em `.gc/gate-refusal-checks.lock`; outra rodada em curso = sai com 0 sem fazer nada). Agendar (order/launchd) é decisão do Mayor: este script não se agenda sozinho. Testes: `python3 -I scripts/test_gate_refusal_checks.py`.

## O registro de classes cobertas
`scripts/gate-refusal-checks.registry.tsv`, versionado. Colunas `class status check bead since note`; `status` = `ativa` | `em-teste` | `desligada`. **Qualquer** linha conta como coberta, inclusive `desligada`: uma checagem desligada de propósito não é reaberta por este ciclo. A bead aberta pede que quem entregar a checagem acrescente a linha **na mesma entrega** (`em-teste`; a catraca da fatia .3 promove ou desliga).
- Semente: `error-vs-empty` (`ativa`), porque `third-state-reads-check.py` (passo 2e do `gate-hard-checks.sh`) já a cobre desde 16/10. Sem a linha, a 1ª rodada abriria bead duplicada.
- Registro ausente, ilegível ou sem cabeçalho = **NÃO SEI** (rc 2, nada aberto). Arquivo vazio não é «nada está coberto».
- Linha meio escrita ainda registra a classe (vira aviso em `registry.problems`), para não reabrir classe que alguém já pegou.

## Como ler
Três estados em tudo: tem / não tem / **não sei**. Saída por classe (`classes[].verdict`):
- `coberta` · `ja-aberta` (qualquer status, fechada inclusive: classe se abre uma vez) · `abriria` (ensaio) · `aberta` / `aberta-nao-verificada` (`--apply`; a 2ª = criada, mas o `bd show` não confirmou rótulos e rota: rc 1) · `erro-ao-abrir` (rc 1).
- `exemplos-insuficientes`: menos de 3 exemplos legíveis (comentário do gate-run ilegível, log ausente, janela sem `from/to`). **Não abre**; tenta de novo na próxima rodada.
- `teto-por-rodada` / `teto-de-abertas`: os freios abaixo.
- `unlabeled_candidates`: grupos «sem rótulo» do medidor com ≥ 5 recusas. **Só listados, nunca abertos**: a chave é por palavras (a mesma classe aparece com redações diferentes; o grupo «(sem título de bloqueante)» é só leitura que falhou), então uma bead por redação seria duplicata. Ação humana/Mayor: rotular a classe, ou o revisor passar a rotular.
- rc 0 relato impresso (inclusive «nada a abrir») · 1 bead criada sem confirmação, ou `bd create` falhou · 2 **NÃO SEI** (medidor, registro ou store de beads ilegível: **não** significa «nenhuma classe repete») · 64 uso.

## Freios
`--max-new` (2) beads por rodada e `--max-open` (3) beads do ciclo ainda não fechadas ao mesmo tempo: o ciclo não pode inundar o pool de dogs. Classes seguradas pelos tetos continuam elegíveis e entram na rodada seguinte, na ordem (mais recusadas primeiro, depois nome).

## Travas
O ciclo nunca edita o próprio avaliador. Este script só LÊ o JSON do medidor (e o log do gate para os exemplos) e cria beads: não abre arquivo para escrita (só o lock), e o texto da bead proíbe editar `gate-refusal-meter.py`, o teste dele e o código do braço A/B. Ação para fora (mensagem, gasto, publicação) continua com humano.

## O que NÃO faz
- Não decide se a checagem pedida é boa: a bead cai no dog como qualquer feature, passa pelo gate, e a fatia .3 mede (A/B) se ela reduz recusa sem recusa falsa.
- Não vê recusa que o medidor não leu (`refusals.unread`) nem classe que o revisor não rotulou (~79% das recusas na 1ª medição, 26/11): o gargalo ali é de rótulo, não de checagem.
- Não foi agendado: sem order/launchd até o Mayor decidir.
