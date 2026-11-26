# Medidor de recusas do portão por classe-raiz (gate-refusal-meter) · runbook

## Contents

• O que mede · Como rodar · Como ler · O avaliador é travado · O que NÃO mede

Fatia 1 do piloto «Recusas → checagens» (épico ga-mw5gdyu, Athos 26/11). Somente leitura: não abre bead, não manda mail, não edita nada. Generaliza `scripts/root-class-count.sh`, que contava só `root-class:error-vs-empty` e por rótulo (quantas foram ETIQUETADAS, não quantas recusas houve).

## O que mede
`scripts/gate-refusal-meter.py`, na janela `--days` (padrão 7) que termina em `--now`. Mesmas definições de 1ª tentativa e de recusa do `third-state-report.py` (uma diferença: veredito com bead vazia é `unusable`, não «uma bead anônima»).
- **1ª tentativa:** o 1º veredito real de cada bead no `.gc/quality-gate.jsonl` inteiro; a bead conta se esse veredito caiu na janela.
- **Recusa:** FAIL de revisor na janela. FAIL de merge ou de bead fechada fica em `other_fail`, fora da conta.
- **Classe:** cada `root-class:<nome>` na parte bloqueante do comentário do gate-run (loja do HQ). Uma recusa que cita duas classes conta uma vez em cada. Sem nenhuma: **sem rótulo**, agrupada pelo título de cada «Blocking issue N:» (o `[nome entre colchetes]` ou as 8 primeiras palavras, sem acento/caixa/dígito/caminho); exemplo = a 1ª recusa do grupo.
- **Inventário:** beads com o rótulo por store do `gc rig list` (nunca lista fixa), para as classes vistas + `error-vs-empty` + `--class NOME`. São beads rotuladas, **não** recusas.

## Como rodar
`python3 scripts/gate-refusal-meter.py [--days 14] [--json] [--save] [--class NOME]`. O JSON (`--json`) é o contrato de quem consome (a fatia .2 usa `--days 14`); sem ele sai a linha legível e o detalhe. `--save` troca `.gc/gate-refusal-meter.last.json|txt` (também num NÃO SEI: o arquivo nunca guarda o número da semana passada). Saída: `0` imprimiu · `1` `--save` não gravou · `2` NÃO SEI · `64` uso. **Não há order nem launchd**: agendar é do Mayor (fatia .4).

## Como ler
Três estados em tudo, nunca dois: dado / `sem dado` / **NÃO MEDIDO**. `complete=false` e `gaps` dizem o que faltou.
- `gate_log.state` ≠ `ok` (log ausente, ilegível ou sem linha utilizável) = NÃO SEI, rc 2, nada é contado. `bad_maybe_in_window` e `unusable` são linhas/vereditos que podem ser da janela e ficaram fora.
- `refusals.unread` = recusas cujo comentário do gate-run não foi lido (bd falhou, JSON ruim, sem parte bloqueante, sem `gate_run`): **sem leitura**, nem rotuladas nem sem rótulo. `total = labeled + unlabeled + unread`. Número alto costuma ser gate-run já recolhido pelo wisp-compact (hipótese do código; confira no 1º run real com `unread_runs`).
- `inventory.classes[classe][store] = null` = célula NÃO MEDIDA (store sem diretório, bd falhou, resposta ilegível), nunca 0. `undated` = beads sem `created_at` legível.
- `first_attempt.state`: `n<5` ou `sem dado` não é percentual.

## O avaliador é travado
O ciclo nunca edita o próprio avaliador. `evaluator.sha256` é o hash deste script: duas rodadas só se comparam com o hash igual; hash `null` (arquivo não lido) é lacuna. Esta fatia só EXPÕE o hash; recusar edição automática de `scripts/gate-refusal-meter.py` e do seu teste é trabalho das fatias seguintes.

## O que NÃO mede
- A taxa de recusa falsa (não há gabarito). Recusa que o revisor não rotulou só aparece como grupo de texto: o agrupamento é por palavras, não por significado.
- Classe rotulada em bead mas nunca citada numa recusa da janela fica fora do inventário, salvo com `--class`.
- Não foi rodado ao vivo no nó (sem Dolt nem `gc`): a suíte `scripts/test_gate_refusal_meter.py` usa `gc`/`bd` falsos; o 1º run real no mini é o teste de campo.
