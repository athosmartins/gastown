# Teto de sessões dinâmico por pool (ga-uywvsc)

**Estado:** entregue DESLIGADO (e, sozinho, só freia: ver "O teto do motor"). Merge não muda nada; liga-se com um arquivo (abaixo).
Cobre `wa-worker`, `ps-worker` (Pilot) e `gate-reviewer` (gate dispatcher).
**Não cobre** `gastown.dog` nem os revisores do refino — ver "Fora do escopo".

## O que faz

Hoje o teto de cada pool é um número digitado (`PILOT_WA_WORKER_MAX=2`,
`PILOT_PS_WORKER_MAX=1`, `GATE_MAX_REVIEWERS=6`). Ligado, cada varredura recalcula o
teto, **no máximo 1 passo por varredura**, dentro de `[min, max]` do pool:

| Situação | Efeito |
|---|---|
| há fila **e** o pool está no teto (`vivos >= teto`) **e** todo sinal de folga está "grow" | **sobe 1** |
| qualquer sinal **aperta** (squeeze) | **desce 1** — só para de ABRIR sessão; nunca mata uma aberta |
| fila vazia | **mantém** — decair na fila vazia só custa vazão (o Pilot varre a cada ~20 min: recuperar 1 passo leva uma varredura) e, dentro do teto do motor, não protege de rajada |
| sinal ilegível (**inclui a cota**), fila ilegível, contagem de vivos ilegível | **não sobe** (terceiro estado: "não consegui saber" ≠ "folga infinita" e ≠ "fila 0") |
| sinal em zona intermediária (hold) | mantém |

`min..max` padrão: wa-worker 1..4 (4 = decisão do Athos em 19/09), ps-worker 1..2,
gate-reviewer 2..6 (o min sobe até `GATE_REVIEWERS_PER_RUN`, para uma run caber sob o teto — salvo se o
teto do **motor** for menor que isso: aí nenhuma run sai inteira de qualquer jeito, e o "motor N" da linha de
log mostra por quê) — **sempre limitados ao `max_active_sessions` do agent.toml do pool** (ver "O teto do motor").
Override: `POOL_CEILING_<POOL>_MIN` / `_MAX` (pool em maiúsculas, `-` vira `_`).

`GC_VARIABLE_SESSION_MAX` (9, decisão do Athos) continua um teto **fixo** por cima dos três.

### Sinais (limiares são estimativas iniciais — o log existe para calibrá-los)

| Sinal | grow | hold | squeeze |
|---|---|---|---|
| load5 / núcleos | ≤ 5,0 | entre | ≥ 8,0 (`POOL_CEILING_LOAD_{GROW,SQUEEZE}_PER_CORE`) |
| pressão de memória do kernel | 1 | 2 | 4 |
| swap (livre, usado, disco livre) | usado ≤ 4 GB | usado > 4 GB, ou swap baixo mas o disco deixa crescer | swap livre < 512 MB **e** disco < 4 GB (swap não pode crescer — ga-q4fkxa) |
| disco livre | ≥ 12 GB | 3–12 GB | < 3 GB (pisos do `dolt-disk-floor-guard`: WARN 8 + margem 4, CRITICAL 3) |
| Dolt (leitura do próprio dispatcher) | ok | hot | — (cada dispatcher já tem freio próprio) |
| cota Claude | ok | limited | — (e **ilegível** = checker ausente, com erro ou estourou o tempo → "unknown": não sobe) |

**Catraca:** depois de um squeeze, voltar a subir exige que TODO sinal esteja em grow, e as faixas hold
(load 5–8/núcleo, disco 3–12 GB, swap usado > 4 GB) são onde a máquina vive hoje. Um teto que desceu pode
ficar baixo por longos períodos — esperado, e é por isso que se calibra em sombra antes de aplicar.

Medido em 01/10: load5 69,3 em 10 núcleos (6,9/núcleo → hold), disco 7,7 GB (hold),
swap 4,8 GB usado (hold). Ou seja: com a máquina como está hoje ligar isto **não sobe nada**
— e é a resposta correta; só sobe quando houver folga de fato.

## Ligar / desligar (instantâneo, sem editar plist, sem bootout)

**Ordem recomendada: sombra primeiro.** Com a máquina em load5 ~70-88 em 10 núcleos (7-9/núcleo)
os limiares atuais classificam "squeeze": ligar já aplicando derrubaria wa-worker 2→1 e o gate 3→2
— o contrário do que o Athos pediu — antes de os limiares terem sido calibrados.

```bash
touch  $GC_CITY/.gc/pool-ceiling.on        # liga
touch  $GC_CITY/.gc/pool-ceiling.shadow    # SOMBRA: decide, grava e LOGA, mas o dispatcher segue no teto FIXO
rm     $GC_CITY/.gc/pool-ceiling.shadow    # sai da sombra: passa a APLICAR (parte do teto fixo, não da simulação)
touch  $GC_CITY/.gc/pool-ceiling.off       # DESLIGA — volta ao teto fixo, nada lido/gravado
bash   packs/town-deltas/assets/pool-ceiling.sh status   # estado + sinais agora
```
(ou `POOL_CEILING_DYNAMIC=1` / `POOL_CEILING_SHADOW=1` no plist). Os pisos de swap do gate seguem o próprio
gate: salvo se `POOL_CEILING_SWAP_*` for definido explicitamente, o teto do gate lê `GATE_SWAP_FREE_FLOOR_MB` /
`GATE_SWAP_GROW_DISK_MIN_MB` (os mesmos números do freio `gate_headroom_decision`), então ajustar um ajusta
o outro. **`GATE_HEADROOM_ENABLED=0` também deixa o teto do gate sem avaliar** (ele roda dentro do bloco de
headroom); o gate loga uma linha dizendo isso em vez de ficar "ligado" sem rastro. `POOL_CEILING_DYNAMIC=0` é um
desligamento duro que nem o `.on` sobrepõe. Começa sempre do teto **fixo** (estado ausente/corrompido
→ reinicia no fixo). A sombra grava a simulação em `<pool>.shadow.state`, nunca no estado real, e marca
`applied=0` no TSV. Limite por construção: a simulação só enxerga sessões reais, então mostra "subiria
1 passo" mas não escala além do que `vivos` permite.

## Como ler

- Linha por varredura no log do dispatcher, ex.:
  `pool-ceiling: wa-worker 2→3 (up, queue+slack): fila 69, vivos 2/2, load5 31/10c [grow], mem 1 [grow], swap usado 412MB livre 5700MB [grow], disco 14.0GB [grow], dolt ok [grow], cota ok [grow] (fixo 2, faixa 1..4)`
- Série para a medição de 24h (um TSV por passo): `$GC_CITY/.gc/logs/pool-ceiling.log`
  — `ts pool fixed cur new action reason queue live load5 ncpu mem swap disco dolt quota`.
- Estado: `$GC_CITY/.gc/pool-ceiling/<pool>.state` (`ceiling=`, `at=`).

## Fonte da fila e da contagem

- **Pilot:** fila = itens por rig do `~/.gc/pilot-dispatchable.json` (já emitido a cada varredura;
  arquivo ausente, corrompido ou mais velho que o próprio `ttl_seconds` → "ilegível", não zero).
  **Limite honesto:** se o próprio emit falha ao ler um rig (ex.: `gc rig list` caiu → emit só do HQ), ele grava
  um arquivo FRESCO com 0 itens para aquele store, e isso lê como "fila 0" conhecido (razão `idle`, que
  mantém — a direção é inerte: nunca sobe). Na série de 24h, essas varreduras contam como `idle`. Vivos = snapshot do `session list`
  da própria varredura (active+creating+start-pending).
- **Gate:** fila = markers na fila (`$COUNT`); vivos = `LIVE_REVIEWERS`. Esse passo só roda com
  marker esperando; o teto do gate cai só por squeeze e volta quando há fila + saturação + folga.

## Fora do escopo (próximo passo, outro bead)

- `gastown.dog` e `refino-gate-reviewer`: não passam por estes dois dispatchers; o teto deles é
  `max_active_sessions` do engine (dog: bloco gerido pelo `eval-window-concurrency-guard` no
  `city.toml`). Torná-los dinâmicos exige reescrever esse valor + `gc reload --soft` — outro mecanismo.
- `auto-refiner`: roda sob lock de instância única (no máximo 1 em voo), não há o que dimensionar.
- **O teto do motor.** O controller aplica `max_active_sessions` de `agents/<pool>/agent.toml` por conta
  própria, sem olhar o dispatcher (25/09: agent.toml=4, plist do Pilot=2 → 4 workers ativos, ga-o3o09z;
  `prod-tests/gascity/story-ga-o3o09z.sh` fixa que o teto do Pilot nunca pode ser MAIOR que o do motor).
  Por isso o teto dinâmico é **limitado ao `max_active_sessions` do agent.toml** (ilegível → limitado ao
  teto fixo conhecido). Hoje isso dá faixa efetiva wa-worker 1..2, ps-worker 1..1, gate-reviewer 2..3:
  **esta entrega só FREIA e religa dentro do teto do motor; não sobe acima dele.**
  **NÃO suba o `max_active_sessions` do agent.toml esperando que o dinâmico segure**: o controller
  admite até esse valor sozinho, e o dispatcher não o impede.
  Subir de verdade (o caso da fila de 69 com teto 2) exige o teto do MOTOR acompanhar o dinâmico
  (reescrever o valor + `gc reload --soft`, com reversão no kill switch) — mecanismo à parte, que mexe
  na decisão "agent.toml é a fonte única" do Mayor; ver o bead de continuação.

## Verificação

`bash packs/town-deltas/assets/pool-ceiling.selftest.sh` (240 asserts; passa em `/bin/bash` 3.2 e bash 5) — reprova sem a lib
e sem a fiação nos dois dispatchers; inclui a função de cola REAL do Pilot e o bloco REAL do teto do gate
(duas passadas, a 2ª emulando o re-exec do multi-admit ga-309v3, sob `set -euo pipefail`) extraídos dos
arquivos e rodados contra fixtures, e os produtores de cota dos dois dispatchers rodados contra um checker
falso (exit 0/2/1/124/3, morto por sinal, ausente, sem permissão, sem o binário `timeout`). Mutações que o teste pega (cada uma foi aplicada e o teste reprovou): sinal ilegível sobe,
fila ilegível lida como 0, squeeze não encolhe, sem limite de ritmo, ligado por padrão, fila velha
confiada, teto do motor ignorado, decaimento por fila vazia de volta, Dolt ilegível lido como ok,
DRY_RUN ignorado, sombra aplicando o teto, sombra gravando o estado real, relógio ilegível lido como época 0, estado corrompido reiniciado em silêncio,
**cota ilegível (checker ausente/com erro/estourou o tempo) entregue ao teto como `ok`** (o teste novo reprova no código anterior com o
sintoma literal `wa-worker 2→3 (up, queue+slack)`), limiar de swap/load com lixo lido como "não apertou", **sinalizador de Dolt do Pilot ausente/lixo lido como `ok`** (o padrão é "ilegível").

Antes de ligar: `pool-ceiling.sh status` mostra o sinal agora. Ligue em SOMBRA e deixe 24h; confira em
`.gc/logs/pool-ceiling.log` quanto tempo cada sinal ficou em grow/hold/squeeze antes de tirar a sombra.
