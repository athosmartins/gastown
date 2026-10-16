## Contents
- Como rodar · Como ler uma célula · Ler os 7 dias contra a meta · Limites conhecidos · Manter o ledger manual

# Relatório do 3º estado (ga-57e7l0.2)

Mede, por **caminho de entrega** e por **braço**, os dois números da história ga-57e7l0: % de beads aprovadas na **1ª tentativa** e % das
**reprovações** cujo bloqueio é "3º estado" (leitura que falhou tratada como vazio/zero/"não novo"). Somente leitura: não escreve bead nem manda mail.

## Como rodar
- Manual: `python3 packs/town-deltas/assets/third-state-report.py` (janela padrão 7 dias; `--days N`, `--now <ISO Z>`, `--no-classify` para não chamar o `bd`).
  Primeira rodada ~25 s (uma leitura de `bd comments` por gate-run reprovado); as seguintes ~2 s, porque respostas lidas ficam em
  `.gc/third-state-report.cache.json` (só respostas — gate-run que não pôde ser lido é perguntado de novo).
- Diário: a order `third-state-report` (cooldown 24h) roda com `--save` e deixa o texto em `.gc/third-state-report.last.txt`. Ninguém é avisado: o relatório é lido, não empurrado.
- Código de saída: `0` imprimiu; `2` = **NÃO SEI** (o `quality-gate.jsonl` não existe, não abriu ou está vazio — nunca vira "0 beads"); `64` = uso errado.

## Como ler uma célula
Toda célula tem três estados, nunca dois:

| o que aparece | significa |
|---|---|
| `58% (198/341)` | dado: percentual e contagem |
| `sem dado` | a janela não tem nenhuma observação nessa célula (≠ 0%) |
| `n<5, sem conclusão (n=3)` | há observações, mas poucas demais para um percentual |
| `· sem leitura: 4` | 4 reprovações cujo comentário do gate-run não pôde ser lido; **não** contam como "não é 3º estado" |
| `53% (123/230), faixa 53–54%` | com reprovações sem leitura, o percentual vem com a faixa: mínimo (nenhuma sem leitura é 3º estado) a máximo (todas são) |
| `NÃO SEI …` | a fonte não pôde ser lida (arquivo ausente/ilegível) |

Cabeçalho: `N linhas ilegíveis` é a contagem das linhas do log que não parsearam (**contadas, nunca descartadas em silêncio**), com quantas ainda têm `ts`
dentro da janela — se houver, os números podem estar incompletos. O log real tem 20 linhas ilegíveis de junho (registros antigos em várias linhas); é esperado.

Definições: **1ª tentativa** = o 1º veredito real (`dispatcher_complete`, `dry_run≠1`, PASS/FAIL) de cada bead em todo o log; a bead entra na janela se esse veredito caiu nela.
**Reprovação** = FAIL de revisor na janela. FAIL por "Merge failed after all-PASS" ou "bead fechada" aparece à parte e fica fora do %.
**3º estado** = o rótulo `root-class:error-vs-empty` na parte **bloqueante** do comentário do gate-run (entre "Blocking reasons:" e "Non-blocking findings:"), ou o ledger manual.
O cabeçalho mostra quantas vieram de cada fonte.

## Ler os 7 dias contra a meta
Linha de base 14/10: 1ª tentativa 36% (4/11); FAIL em 52% dos vereditos; ~85% das reprovações por 3º estado (6 de 7).
Meta da história (7 dias): reprovações por 3º estado **< 30%** e 1ª tentativa **≥ 60%**. A coluna `meta` de cada célula já compara; leia assim:
1. **Só vale célula com `n ≥ 5`.** `n<5` e `sem leitura` alto (faixa larga) não provam nem desprovam: espere mais dias ou rode com `--days 14`.
2. **Meta atingida** = a linha `todos` com `atinge` nas duas colunas, em rodada com poucas `sem leitura` (a faixa inteira abaixo de 30%).
3. **Caminho**: compare `Pilot sling` com `fora do roster`. Se só o Pilot melhora, o bloco E12 funciona onde chega e falta chegar aos outros caminhos (hipótese 1 da história).
   Se nenhum melhora, o texto sozinho não muda o comportamento (hipótese 2): o freio mecânico é a fatia 2.
4. **Braço da fatia 2**: só compara quando a conf existe **e** há registro por bead (abaixo). `com a checagem` melhor que `sem a checagem` com `n≥5` nos dois = a checagem funciona.
   O braço E12 é só histórico (`treated_pct=100` desde 07/10: não há controle novo).
5. A 1ª tentativa só sobe se a causa dos FAIL for mesmo o 3º estado; se o % de 3º estado cai mas a 1ª tentativa não, outra classe de erro tomou o lugar — olhe os FAIL `outro`.

## Limites conhecidos
- **Crew não é separável.** Nenhum registro liga a bead ao construtor; só o roster `.gc/e12-roster.jsonl` (o que o Pilot despacha) é prova. `fora do roster` junta top-up, gate-fix, self-serve e crew.
  Para ganhar a linha `crew`, quem despacha precisa gravar o caminho no roster.
- **Braço da fatia 2**: a conf `.gc/third-state-reads.conf` ausente = "fatia 2 não ligada" (todo veredito é sem a checagem). Com a conf, o relatório lê `.gc/third-state-reads-arms.jsonl`,
  uma linha por bead (`{"bead":"<id>","arm":"enforce"|"holdout"}`, a 1ª linha da bead vale); conf sem esse arquivo = `NÃO SEI`, e bead sem linha vai para `sem registro de braço`.
- O rótulo **subconta**: o revisor nem sempre escreve `root-class:error-vs-empty` (gate-run ga-91m4ga não tem e é 3º estado). Por isso o ledger manual vence o rótulo.
- Uma bead que passou nos revisores e falhou no merge tem 1º veredito FAIL e entra na conta da 1ª tentativa como FAIL (é o que o gate registrou), mas não na do 3º estado.

## Manter o ledger manual
`packs/town-deltas/assets/third-state-manual.tsv`: uma linha por (bead, dia UTC) — `bead<TAB>AAAA-MM-DD<TAB>3o-estado|outro<TAB>fonte`. Vale para todo FAIL de revisor da bead naquele dia.
Linha que não parseia é contada ("N linhas ilegíveis no ledger") e **não** é aplicada. Ledger ausente = `NÃO SEI: ledger manual ausente`; só o rótulo decide. Edite por commit, nunca em produção.
