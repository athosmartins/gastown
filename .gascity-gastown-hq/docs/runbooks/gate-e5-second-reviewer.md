# E5 — 2º revisor independente no gate (A/B) · runbook

Bead ga-syxaki (P0 ga-ufskhy). Motivo e números: `docs/reports/gate-e4-historico.md` §6 (Frente 6: 52,7% dos blocking issues de rodada ≥ 2 já estavam no código da rodada 1; 1 revisor, 1 passada, em 100% das runs).

**Estado de fábrica: DESLIGADO.** Com a chave desligada o gate roda byte a byte como antes (nenhum revisor extra, nenhuma linha nova no prompt). O Mayor liga em **01/10/2026 ~21h -03** (fim do E2; ligar antes confunde os dois efeitos).

## Ligar / desligar / olhar

```bash
~/gt/.gascity-gastown-hq/scripts/gate-e5-switch.sh status
~/gt/.gascity-gastown-hq/scripts/gate-e5-switch.sh on "Mayor, bead ga-syxaki #<comentário>, 2026-10-01T21:05-03"   # autorização CITÁVEL (Regra Nº 4)
~/gt/.gascity-gastown-hq/scripts/gate-e5-switch.sh off
```

A chave é o arquivo `$GC_CITY/.gc/gate-e5-second-reviewer.on`; o dispatcher o lê a cada varredura (~1 min) — sem reinício, sem plist. `on` recusa sem citação e antes de 01/10 21:00 -03 (`GATE_E5_FORCE_EARLY=1` antecipa, com o porquê na citação). `off` não mata revisores já em voo; só nada novo nasce.

## O que muda quando está ligado

* **Braço** = paridade do SHA-256 de `e5-second-reviewer:<bead-id>` (par = B). Função pura do id — uma bead que reprova e reenvia nunca troca de braço. SHA-256 e não o polinômio do ga-rstae: o E3 mediu que polinômio com sal ainda concorda com o braço do ga-rstae em 43% das beads; aqui, em 4.758 beads reais: E5×ga-rstae 50,9% de concordância (χ² 1,50), E5×pré-gate do E3 χ² 0,06, B = 48,5%.
* **Braço A** = o gate de hoje. **Braço B** ganha um 2º revisor, em sessão separada (não vê o parecer do 1º), no mesmo diff, quando **(big-diff)** o `git diff` tem ≥ 800 linhas (mesma medida do cabeçalho do prompt, base do corte do E4) — nasce junto do revisor 1 — ou **(first-fail)** o revisor 1 devolveu o **1º FAIL julgado** da bead (`gate:fix-attempt` ausente ou `:0`) — nasce antes de o FAIL voltar ao construtor (custa ~10–15 min de espera nesse FAIL). Lente do 2º: a mesma de correção, varredura completa e caça a irmãos do mesmo defeito.
* O veredito devolvido ao construtor é a **união** dos blocking issues (`gate-e5-union.py`): issues do mesmo arquivo+linha e da mesma descrição viram um só ("confirmado independentemente"); tudo o mais fica, e as notas não-bloqueantes e o `Coverage:` de cada revisor vão verbatim. Dúvida → mantém os dois (colapsar errado esconde um defeito; duplicar só repete).
* **A run é admitida uma vez só** (Passo 5 do dispatcher): uma única leitura da chave decide se ela entra no experimento; o braço medido é gravado na descrição do gate-run (`e5_arm: A|B`) e a Fase C lê essa linha de volta — não relê a chave nem recalcula o braço para decidir o que a run *é*. Braço não medido é `?`, nunca `A`. Uma run admitida com a chave desligada, ou anterior a este código (sem a linha), fica **fora do experimento**: não ganha 2º revisor no 1º FAIL mesmo que a chave seja ligada depois.
* **Os dois braços** passam a listar no parecer os arquivos/trechos examinados (`Coverage:`), para a apuração separar latente de não-examinado.

## A regra que segura tudo

O extra só pode **acrescentar** um veredito que ele *entregou*. Sem vaga de sessão, tarefa que não monta, teto de gasto, timeout, sessão morta, bead ilegível → a run decide com o revisor 1 sozinho, exatamente como no braço A, e o motivo vai para o log (`e5_extra_declined` / `e5_extra_abandoned`). Um extra que fecha sem veredito **não conta e não reprova** (o `gate_collect_verdicts` o trata como "não entregue").

## Teto de gasto

`GATE_E5_DAILY_CAP_USD` (30) ÷ `GATE_E5_EST_COST_USD` (0,60, medido no E0) = 50 extras/dia. Ao atingir, o dispatcher manda `notify` uma vez e recusa novos extras até o dia seguinte (o braço B roda como A nesse intervalo — aparece na apuração como `recusado:daily-cap-reached`). O teto é sobre **estimativa por contagem**; o custo real sai da apuração. Contador: `$GC_CITY/.gc/gate-e5-spend-AAAA-MM-DD.count`.

## Apuração

`scripts/gate-e5-apuracao.py [--since AAAA-MM-DD]` — só leitura; fonte: `quality-gate.jsonl` (eventos `e5_admit`, `e5_session`, `e5_extra_spawn|declined|abandoned`, `e5_run_end` + a linha `dispatcher_complete` de cada run) e as transcrições dos revisores.

* **Primária (binária, por bead):** a bead com 1º FAIL de revisor precisou de uma 2ª rodada de FAIL? (36,0% hoje; meta −15 pp; ≈139 beads com 1º FAIL por braço, ≈11 dias.) Três estados: 2ª-FAIL / resolveu-sem-2ª / **ainda não se sabe** (fora da taxa, contado ao lado).
* Secundária: aprovação na 1ª tentativa (no braço B, nos diffs ≥ 800 linhas, tende a **cair** — o 2º revisor roda em paralelo e pode reprovar o que 1 aprovaria; custo esperado, não defeito) e estratos por tamanho e rig.
* **Custo com 3 estados por sessão** (sabido / desconhecido / sem registro): nunca "exato" com sessão sem custo final; preços de lista ASSUMIDOS (`--price-json` sobrescreve).
* Audita o braço gravado contra a função viva da lib; divergência aborta.

## Limites conhecidos (não escondidos)

* "Classe" no dedupe é a **descrição** do defeito (o revisor não emite classe; o E4 a atribui depois, com LLM); tag explícita `class:` diferente separa.
* O caminho first-fail não faz `git fetch` na Fase C: se o construtor empurrou commit novo entre o revisor 1 e o extra, o extra revê o diff **embutido** (mesmo sha do revisor 1), mas o diff parcial manda rodar `git diff` na ref atual.
* `max_active_sessions=3` do `gate-reviewer`: o extra compete por vaga com runs concorrentes; sem vaga é recusa (arm-A), não abort.
* Não feito aqui (proposta 2 do E4, à parte): "nunca entregar diff parcial sem revisor extra para o resto".
* Runs em voo no instante em que a chave é ligada (admitidas antes) ficam fora do experimento, de **nenhum** braço: as primeiras horas depois do "on" têm menos runs medidas do que o volume sugere. É a consequência de decidir uma vez só, e a apuração não as conta.
* "1º FAIL" = `gate:fix-attempt` da bead; um reset manual `:0` a torna "primeira" de novo.
* A chave liga para **todas** as runs: o `Coverage:` muda o prompt dos dois braços desde então (o prompt do construtor no pré-gate do E3 não muda: só o dispatcher define as variáveis).

## Reverter o código

`git revert` do commit do E5: os labels `e5-*` nas beads de veredito ficam inofensivos. Nada aqui altera o plist do dispatcher.
