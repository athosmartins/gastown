# Taxonomia de reprovacao do gate — medida, nao estimada

Fonte: `.gc/logs/quality-gate-dispatcher.log` (janela 2026-07-23 a 2026-08-12).
Gerado pelo Mayor em 2026-08-12. Reproduzivel: o script esta no bead ga-* que cita este arquivo.

## Taxa real

| medida | valor |
|---|---|
| gate-runs totais | 1524 |
| branches distintas | 1005 |
| branches que passaram | 931 |
| **passam na 1a tentativa** | **71%** (659/931) |
| nunca passaram | 74 |
| runs por branch entregue | 1.64 |
| **runs desperdicados em retrabalho** | **593** |

### Distribuicao de retrabalho

| FAILs antes do PASS | branches | % |
|---|---|---|
| 0 | 659 | 71% |
| 1 | 176 | 19% |
| 2 | 53 | 6% |
| 3 | 18 | 2% |
| 4 | 16 | 2% |
| 5 | 4 | 0% |
| 6 | 1 | 0% |
| 7 | 1 | 0% |
| 8 | 1 | 0% |
| 9 | 1 | 0% |
| 13 | 1 | 0% |

> A leitura ingenua ('39% dos runs reprovam') INFLA o problema:
> uma bead que reprova 3x e passa conta 3 FAIL + 1 PASS. A metrica honesta e
> aprovacao na PRIMEIRA tentativa, porque e ela que mede o custo de retrabalho.

## Familias de defeito (443 blocking issues distintos, 88% classificados)

Um issue pode cair em mais de uma familia (a media e ~2).

| familia | issues | % |
|---|---|---|
| comentario/docstring mente | 134 | 30% |
| 3o-estado colapsado | 132 | 30% |
| instancia vs classe | 117 | 26% |
| estado stale/contraditorio | 106 | 24% |
| teste nao pega o bug | 96 | 22% |
| escopo/scope errado | 94 | 21% |
| excecao incompleta | 84 | 19% |
| corrida/concorrencia | 39 | 9% |
| erro==vazio / fail-open | 38 | 9% |
| (sem familia reconhecida) | 51 | 12% |

## O achado que importa

Estas familias JA ESTAO na doutrina da cidade (town-deltas.template.md) e JA CHEGAM
ao prompt do builder: `gc prime` renderizado para `wa-worker` da 4 matches em
'terceiro estado' / 'Conserte a CLASSE' / 'Comentario que promete' / 'so passa nao prova'
— os MESMOS 4 do Mayor. Ou seja: **a instrucao existe, chega, e mesmo assim produziu
443 blocking issues nessas familias.** Prosa no prompt ja foi tentada; o proximo
degrau tem que ser verificacao MECANICA, nao mais texto.
