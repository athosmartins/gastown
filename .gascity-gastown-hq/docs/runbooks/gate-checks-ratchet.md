# Catraca das checagens em teste (gate-checks-ratchet) · runbook

## Contents

• O que faz · Como rodar · O contrato da checagem · A decisão · Como ler · Limites

Fatia 3 do piloto «Recusas → checagens» (épico ga-mw5gdyu, Athos 26/11). Consome o registro da .2 (`docs/runbooks/gate-refusal-checks.md`) e as funções de 1ª tentativa do medidor da .1. Por padrão **só relata**; com `--apply` põe a checagem em teste, promove ou desliga. Não abre bead, não manda mail, não edita código nem o registro.

## O que faz
Para cada linha `em-teste` de `scripts/gate-refusal-checks.registry.tsv` cuja coluna `check` começa por `<dir>/<nome>-check.py`: **entra** (conf `.gc/<nome>.conf` = `mode=enforce` + `enforce_pct=50`: metade das beads é recusada de verdade e a outra metade, o `holdout`, roda a mesma checagem como `warn`), **decide** e **promove** (`enforce_pct=100`) ou **desliga** (`mode=off`) dizendo por quê. O estado é a própria conf: as linhas de configuração mais UMA linha `# ratchet {json}` (`fase`, `since`, `entrou` e, decidida, `em`, `why`, `evidence`), gravadas numa escrita atômica. Conf sem essa linha é de outra mão: NÃO SEI, nunca sobrescrita. Recomeçar uma classe = apagar a conf; parar de vez = `status` da linha para `desligada` **e** apagar a conf (sem conf a checagem não está ligada); `since` novo = teste novo.

## Como rodar
`python3 scripts/gate-checks-ratchet.py [--apply] [--json] [--days 14] [--min-submissions 30] [--cap-days 28] [--city DIR]`. Não se agenda sozinho (order/launchd é decisão do Mayor): antes, um `--apply` à mão e `cat .gc/<nome>.conf`. Saída: 0 relato · 1 escrita falhou · 2 NÃO SEI · 64 uso · 70 bug. Testes: `python3 -I scripts/test_gate_checks_ratchet.py` e `scripts/test_gate_check_trial.py` (este usa o `third-state-reads-check.py` real como oráculo do sorteio e da gramática da conf).

## O contrato da checagem
O construtor (a bead da .2 manda) entrega `<dir>/<nome>-check.py` + a linha `em-teste` (coluna `check` começando pelo caminho). O script usa `packs/town-deltas/assets/gate_check_trial.py`: `resolve(state, nome, bead)` diz se roda (`desligado` = conf ausente ou `mode=off`; `nao-sei` = conf ilegível; `eff` `enforce` recusa de verdade, `warn` é o braço `holdout`: avalia, grava e não recusa) e, a cada rodada com bead, `record_run(...)` acrescenta UMA linha a `.gc/<nome>-runs.jsonl` (`bead, ts, arm, verdict ok|achados|nao-sei, pontos, dispensados`): `pontos` = o que a checagem citou, `dispensados` = o que o autor dispensou por waiver. O construtor **não cria a conf**.

## A decisão
Depois de 14 dias **ou** 30 beads com rodada, nas rodadas desde a entrada: **promove** se a 1ª tentativa no braço `enforce` ≥ `holdout` (funções do medidor, beads cuja 1ª rodada veio antes do 1º veredito) **e** a recusa falsa ≤ 10% das beads recusadas; senão **desliga**. Recusa falsa = bead recusada no braço `enforce` cujo ponto citado reaparece **dispensado** numa rodada posterior da mesma bead (o medidor da .1 diz que não há gabarito: é o proxy de «recusa revertida sem mudar o ponto citado»). Com < 5 beads de 1ª tentativa por braço ou < 5 recusas **espera**; no teto (`--cap-days`, 28) desliga por `dados-insuficientes`. Leitura que falhou (log do gate, rodadas, conf, registro) nunca decide: NÃO SEI.

## Como ler
`entraria/entrou` · `em-andamento` · `aguardando-dados` · `promoveria/promovida` · `desligaria/desligada` · `ja-decidida` (final para o `since`; conf alterada por outra mão vira aviso, não é refeita) · `nao-sei` · `fora-do-contrato` (coluna `check` fora do padrão; rc 2) · `erro-ao-aplicar` (rc 1). `gaps` traz o que não foi medido.

## Limites
- «30 beads» fecha em ~1 dia no ritmo de ~50 beads/dia (~15 por braço, ruído de ±18 pp): é o que a bead pede; suba `--min-submissions` se quiser provar mais.
- O ciclo só usa as funções do medidor e não lê a checagem; **não impede** que alguém edite o medidor, a régua ou a checagem no meio do teste (isso é revisão do gate; a trava mecânica pelo `evaluator.sha256` fica para a fatia seguinte) e uma checagem editada no meio mistura versões.
- O porquê fica na conf e no relatório; **não** comenta na bead da checagem. Nada rodou ao vivo (o nó não tem Dolt nem `gc`); o 1º `--apply` real é o teste de campo.
