# Teto de sessões dinâmico por pool (ga-uywvsc)

**Estado:** entregue DESLIGADO (e, sozinho, só freia: ver "O teto do motor"). Merge não muda nada; liga-se com um arquivo (abaixo).
Cobre `wa-worker`, `ps-worker` (Pilot) e `gate-reviewer` (gate dispatcher).
**Não cobre** `gastown.dog` nem os revisores do refino — ver "Fora do escopo".
**O que sobe o teto do controller** (o freio abaixo só o segura) é o motor da fatia 2, em "O motor do teto do controller" mais abaixo: código entregue, **desligado e não instalado**.

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
| cota Claude | ok | limited | — (e **ilegível** = checker ausente, com erro ou estourou o tempo → "unknown": não sobe). O checker sai 0 também num limite só *semanal* de aviso, que portanto lê como `ok`: por desenho do checker, não detectado aqui |

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
desligamento duro que nem o `.on` sobrepõe. A **primeira** vez (estado ausente ou corrompido) parte do teto **fixo**;
com estado gravado, **retoma o último teto** (ver "Estado depois de um desligamento longo", abaixo). A sombra grava a simulação em `<pool>.shadow.state`, nunca no estado real, e marca
`applied=0` no TSV. Limite por construção: a simulação só enxerga sessões reais, então mostra "subiria
1 passo" mas não escala além do que `vivos` permite.

**Ligado mas a biblioteca não carregou não é "desligado".** A lib (`pool-ceiling.sh`) é opcional: ausente, ilegível ou
com erro de sintaxe, os dois dispatchers seguem no teto fixo (nunca morrem por falta de uma otimização). Mas, se o
teto está LIGADO (`.on` ou `POOL_CEILING_DYNAMIC=1`), cada varredura loga uma linha
`pool-ceiling: LIGADO … mas <motivo> — vale o teto FIXO` (a lib ausente e a lib que não carrega têm motivos distintos), e o
erro de sintaxe vai para o stderr do processo (não é suprimido: lib corrompida é falha de deploy). Desligado, fica silencioso como antes.

**Estado depois de um desligamento longo.** O estado (`<pool>.state`) guarda o último teto escolhido; ao religar depois de
um `.off`/`POOL_CEILING_DYNAMIC=0` longo, o teto **retoma esse valor gravado**, não o fixo (só estado ausente ou corrompido
reinicia no fixo). Para recomeçar do fixo, apague `$GC_CITY/.gc/pool-ceiling/<pool>.state` antes de religar. O `status` mostra
`modo: SOMBRA` ou `modo: APLICANDO` na primeira linha: "ligado: SIM" sozinho não diz se está agindo.

## Como ler

- Linha por varredura no log do dispatcher, ex.:
  `pool-ceiling: wa-worker 2→3 (up, queue+slack): fila 69, vivos 2/2, load5 31/10c [grow], mem 1 [grow], swap usado 412MB livre 5700MB [grow], disco 14.0GB [grow], dolt ok [grow], cota ok [grow] (fixo 2, faixa 1..4)`
- Série para a medição de 24h (um TSV por passo): `$GC_CITY/.gc/logs/pool-ceiling.log`
  — `ts pool fixed cur new action reason queue live load5 ncpu mem swap disco dolt quota`.
- Estado: `$GC_CITY/.gc/pool-ceiling/<pool>.state` (`ceiling=`, `at=`).

## Fonte da fila e da contagem

- **Pilot:** fila = itens por rig do `~/.gc/pilot-dispatchable.json` (já emitido a cada varredura;
  arquivo ausente, corrompido, mais velho que o próprio `ttl_seconds` **ou carimbado no futuro** (>60 s: relógio fora do
  lugar) → "ilegível", não zero).
  **Limite honesto:** se o próprio emit falha ao ler um rig (ex.: `gc rig list` caiu → emit só do HQ), ele grava
  um arquivo FRESCO com 0 itens para aquele store, e isso lê como "fila 0" conhecido (razão `idle`, que
  mantém — a direção é inerte: nunca sobe). Na série de 24h, essas varreduras contam como `idle`. Vivos = snapshot do `session list`
  da própria varredura (active+creating+start-pending).
- **Gate:** fila = markers na fila (`$COUNT`); vivos = `LIVE_REVIEWERS`. Esse passo só roda com
  marker esperando; o teto do gate cai só por squeeze e volta quando há fila + saturação + folga.

## Limites conhecidos (a registrar no bead que levantar o teto do motor)

Hoje o teto do motor (2/1/3) esconde estes dois pontos; viram reais quando ele subir.

- **Saturação do gate em unidades de run.** O gate chama o pool de "saturado" quando `vivos >= teto`, mas
  `gate_headroom_decision` admite em unidades de `GATE_REVIEWERS_PER_RUN` (`em-voo + por-run <= teto`). Com `por-run > 1` e um teto que não
  é múltiplo dele, o pool pode ficar em `vivos < teto` e nunca subir. Com `por-run = 1` o critério é exato; com a faixa atual 2..3 o efeito é desprezível.
- **Dolt do gate sem faixa "morna".** `pool_ceiling_dolt_class` só distingue ok/hot (cpu > 180 ou latência > 2500 ms); o freio do próprio gate já
  limita a 1 run na faixa 101–180% de cpu, e o teto lê essa faixa como `ok` (grow). Inofensivo — o freio do gate continua valendo — mas o teto pode
  subir com o Dolt morno.
- **`.off` e a biblioteca ausente.** Com `.on`, `.off` e a lib ausente, a linha "LIGADO … vale o teto FIXO" ainda aparece; a conclusão (teto fixo) está certa.
- **O `approved-state-reconciler` não conhece este teto.** `scripts/approved-state-reconciler.py` (`_pool_cap`) lê o cap do Pilot do plist instalado
  e usa a linha "pool at session cap … max=M" do log só como conferência. **Com o teto APLICADO (fora da sombra)**, `PILOT_*_WORKER_MAX` passa a ter uma segunda
  fonte que ele ignora: enquanto o teto estiver abaixo do valor do plist ele loga "DIVERGED … plist edited without reloading the Pilot job?" (enganoso) e,
  sem linha de cap fresca, pode ler um pool freado como "tem folga" e levantar alarme falso de fome (classe wa-ho1ol). A direção é conservadora (alarme a mais,
  nada escondido) e só aparece aplicando — **na sombra não há efeito**, que é mais uma razão para a sombra vir primeiro. Ensinar o reconciler a ler o teto
  efetivo (`.gc/pool-ceiling/<pool>.state`) é trabalho do bead que ligar o teto de verdade.
- **`POOL_CEILING_DYNAMIC` só aceita `0` ou `1`.** Qualquer outro valor (ex.: `true`) é tratado como não definido e cai no teste do arquivo `.on` — sem aviso.
  Use `0`/`1` (ou o arquivo `.on`).
- **Swap recém-criado.** `vm.swapusage` pode mostrar total 0 logo depois de um reboot (o macOS cria o swapfile sob demanda); "swap livre < 512 MB" lê como baixo mesmo
  assim. Com disco ≥ 4 GB isso dá `hold`, não `grow`: uma máquina calma e recém-iniciada só cresce depois que o swap existir (direção conservadora).
- **Teto fixo abaixo do mínimo do pool.** Se o teto fixo for menor que o mínimo (ex.: `GATE_MAX_REVIEWERS=1` contra o mínimo 2 do gate), o primeiro passo aplicado
  sobe `cur` até o mínimo, sem olhar fila nem folga. **Exceção: teto fixo `0`** — é a pausa do operador (com `vivos >= 0` o pool está sempre cheio) e passa
  intocado: sem passo, sem estado, sem linha na série de calibração; a linha de log diz `pausa do operador`. O estado gravado antes da pausa fica como estava
  e é retomado quando o fixo voltar a ser ≥ 1.
- **Com o teto APLICADO, o número do plist deixa de ser freio.** Depois que existe estado (`<pool>.state`), baixar `PILOT_*_WORKER_MAX` / `GATE_MAX_REVIEWERS`
  para um valor ≥ 1 **não** derruba o teto em vigor enquanto o teto do motor (agent.toml) é legível, que é o normal: o fixo só decide o ponto de partida quando não há
  estado, e o `fixo N` da linha de log é informativo. (Com o agent.toml ilegível o `max` é limitado ao fixo, e aí baixar o fixo derruba de fato.)
  Os freios que funcionam aplicando são `touch $GC_CITY/.gc/pool-ceiling.off` (volta ao fixo na hora), `.shadow` (para de aplicar) e o teto fixo `0` (pausa).
  Baixar o fixo continua certo ao desligar o teto dinâmico.
- **Fila só por store de rig.** O Pilot conta a fila pelo store do rig do pool; um bead guardado no HQ e roteado para um worker via `story.rig` não é contado
  para aquele pool — subestima a fila e portanto só inibe o crescimento.
- **Pilot sem rastro de cota ilegível com o teto desligado.** O gate loga `cota=ilegivel(fail-open)`; o freio de cota do próprio Pilot segue silencioso quando o
  checker está "unknown" e o teto está desligado (comportamento anterior, inalterado).

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
  Subir de verdade (o caso da fila de 69 com teto 2) exige o teto do MOTOR acompanhar o dinâmico. Isso **não** reescreve o
  agent.toml nem o city.toml (descartado pelo Mayor): é um fragmento gerado e não rastreado — ver "O motor do teto do
  controller" (ga-m9x0lb.2), logo abaixo.

## O motor do teto do controller (ga-m9x0lb.2)

**Estado:** código + selftest + plist (modelo) entregues. **Desligado por padrão, não instalado, e o `city.toml` ainda não inclui o
fragmento** — nada disto está vivo. Ativar é a fatia 3 (Mayor, supervisionada; checklist abaixo). Decisão do Mayor em 09/10 (ga-m9x0lb).

**O que é.** `packs/town-deltas/assets/pool-ceiling-engine.sh` é o **único escritor** de `$GC_CITY/.gc/pool-ceiling-engine.toml`, um
fragmento **gerado, não rastreado** (`.gc/` é gitignored) com blocos `[[patches.agent]] dir="" name=… max_active_sessions=N`, incluído **uma
vez** pelo `city.toml` (`include = [".gc/pool-ceiling-engine.toml"]`, 1ª linha, antes de `[workspace]`). O patch do fragmento sobrepõe o
`agent.toml` (medido no spike ga-m9x0lb.1). Escrita atômica (tmp+mv); ninguém reescreve arquivo rastreado, então a árvore fica limpa e o
`town-root-reconciler` não vê conflito. Roda num **job launchd próprio** a cada 5 min (`pool-ceiling-engine.plist`, modelo, **não instalado**):
o Pilot sai do passo em quota/RAM/quiet-hours e o gate só roda o teto com marker na fila — um teto que precisa DESCER sob swap não pode depender dos dois.

**A regra** (Athos 03/10, repassada pelo Mayor 09/10). O valor "fixo" de cada pool é o `max_active_sessions` de
`git show HEAD:agents/<pool>/agent.toml` — **nunca** a árvore de trabalho e nunca o estado do dispatcher; apagar as entradas restaura tudo.

| Pool | Faixa | Regra |
|---|---|---|
| `wa-worker` | commitado (2) … **3** | 3 por padrão (sobe de 2 após 2 varreduras claras); **cai para 2** se swap usado > 6 GB **ou** disco livre < 6 GB; **só volta a 3** depois de **2 varreduras** com swap ≤ 6 GB **e** disco ≥ 9 GB |
| `ps-worker`, `gate-reviewer` | piso (1 / 2) … commitado | **só BAIXAM**, na mesma pressão (gate-reviewer 3→2); voltam ao commitado pela mesma regra das 2 varreduras; **nunca** passam do commitado |

- Baixar é **imediato** (1 passo por execução). Subir é 1 passo, só após 2 varreduras **contadas** (duas execuções com < 4 min de intervalo valem 1) e
  no máximo **1 escrita por 10 min por pool**. A faixa 6–9 GB de disco não sobe nem desce (histerese).
- **Terceiro estado em tudo:** swap/disco que não pôde ser lido **nunca** conta como "claro" (pressão `unknown`: não sobe; cego por ≥ 3 varreduras
  enquanto acima do commitado → volta ao commitado). Valor commitado ilegível ou `0` (a pausa do operador) → o pool é pulado e a entrada some.
- **Orçamento:** um aumento nunca faz a **soma** dos tetos (wa-worker + ps-worker + gate-reviewer) passar de `GC_VARIABLE_SESSION_MAX` (o menor entre o env e o plist
  vivo do Pilot; ilegível → 6, o padrão dos dispatchers). Os dispatchers só aplicam esse limite a sessões **vivas**; o controller nunca.

**Salvaguardas** (cada uma tem um mutante no selftest que reprova sem ela):

| Salvaguarda | O que faz |
|---|---|
| **Kill switch = ESVAZIAR, nunca apagar** | `touch .gc/pool-ceiling-engine.off` esvazia o fragmento (só comentário = sem override, medido exit 0). **Apagar quebra a cidade**: com o include no `city.toml`, fragmento ausente é erro de *load* (`gc config show` exit 1). O texto original da fatia dizia "apaga o fragmento" — está errado (spike .1). |
| Leitura de volta | depois de **toda** escrita: `gc config show --json` e conferir que cada entrada resolveu para o valor pretendido. Chave com typo é só um *warning* no gc (exit 0, o teto não mexe): só isto pega. Divergência ou ilegível → esvazia na hora e dispara o disjuntor |
| Pré-checagem | antes de gravar entrada, o agente tem de existir na config (entrada para agente inexistente = erro de load) |
| Disjuntor diário | no máx. 10 escritas por dia local; a próxima vira "esvaziar" e o motor fica inerte até amanhã. Divergência da leitura de volta arma o disjuntor até `pool-ceiling-engine.sh reset` |
| Lock | uma instância por vez (mkdir + heartbeat + TTL 300 s); lock sem heartbeat envelhece pelo próprio diretório (nunca fica preso) |
| Include | com `.on` mas sem include no `city.toml` nada é gravado. Com include presente e fragmento **ausente** (clone limpo/DR) o motor o recria **vazio**, mesmo desligado |
| Estado ilegível | contador diário ou estado por pool que EXISTE mas não se lê **não** vale "zero": o contador vira "no limite" (dispara o disjuntor) e o estado do pool vira "acabou de escrever" (sem subir por 10 min); ambos são logados. Arquivo ausente é primeira execução, não corrupção |
| Fragmento estranho | o que não é exatamente o que o motor renderiza (edição à mão, versão antiga, agente fora da allowlist) é reescrito do modelo, nunca confiado |

**Allowlist:** `wa-worker`, `ps-worker`, `gate-reviewer`. **Fora, de propósito:** `gastown.dog` (o `eval-window-concurrency-guard` é o dono do max dele no `city.toml` e o fragmento
o sobreporia — o guard mudou o dog 6→1→6 em 09/10); `refino-gate-reviewer` e `auto-refiner` (agentes suspensos hoje).

**Como o fragmento chega ao controller.** Nem o `config-drift-watcher` nem o fsnotify do controller enxergam `.gc/` (spike .1): sem ajuda, a mudança só entraria no
reload de heartbeat, 30–60 min depois. O `compute_hash` do watcher agora inclui **só esse arquivo** (1 linha); o resto de `.gc/` continua fora (sem tempestade de reload).

**Operação** (`bash packs/town-deltas/assets/pool-ceiling-engine.sh <cmd>`): `plan` (avalia uma varredura e IMPRIME, não escreve nada, funciona sem `.on`),
`status`, `reset` (zera disjuntor/contador), `check` (só leitura: include presente ⇒ fragmento tem de existir e ser bem-formado). Log TSV: `$GC_CITY/.gc/logs/pool-ceiling-engine.log`;
estado por pool: `$GC_CITY/.gc/pool-ceiling-engine/`. Avisos (notify) só para anormal: disjuntor, leitura de volta falhou, kill switch esvaziando algo, fragmento recriado.

**Checklist da fatia 3 (Mayor, supervisionada) — a ORDEM importa:**
1. criar o fragmento **vazio** (`pool-ceiling-engine.sh` o recria sozinho se faltar e houver include; ou `touch`) — **antes** do include;
2. editar o `city.toml` (1 linha, 1ª, antes de `[workspace]`) e rodar `gc config show --validate`;
3. instalar/`bootstrap` o plist; **ainda sem** `.on`; conferir `status` e `plan`;
4. `touch .gc/pool-ceiling-engine.on`; acompanhar as primeiras varreduras no log;
5. **treino do kill switch**: `touch .off` → conferir que o valor do motor voltou (`gc config show`) → conferir que um spawn acima do commitado é recusado → `rm .off`;
6. **medir drain**: `max_active_sessions` entra no fingerprint do pool (por fonte, **não provado**): contar `session.stopped`/drain do pool tocado antes e depois da 1ª escrita;
7. subir `PILOT_WA_WORKER_MAX` do plist do Pilot só se quiser que o **Pilot** também use o 3º slot (hoje quem passa de 2 é o controller; o prod-test v2 aceita o Pilot até o teto efetivo).

**Limites conhecidos.** (a) O elo "mudar max ⇒ drain das sessões vivas" é por leitura de fonte, **não** medido: por isso o passo 6 e o limite de escritas. (b) `pool_ceiling_engine_cap` (a lib do freio) ainda lê o `agent.toml`, não o
fragmento: o freio dos dispatchers segue limitado ao valor commitado. (c) Os outros pools só baixam até haver série medida no `pool-ceiling.log`; subir qualquer um é decisão do Mayor (as variáveis `POOL_CEILING_ENGINE_<POOL>_CEIL`/`_FLOOR` existem para calibrar, não para o uso normal).
(d) `story-ga-o3o09z.sh` (v2, aprovado pelo Mayor) passou a exigir: Pilot ≤ teto **efetivo** do motor (agent.toml + fragmento), fragmento presente se incluído e bem-formado, outros pools nunca acima do commitado, soma ≤ `GC_VARIABLE_SESSION_MAX`.

## Verificação

`bash packs/town-deltas/assets/pool-ceiling-engine.selftest.sh` prova o motor (seção acima): cada cenário roda num repositório git descartável, o `gc` falso é provado contra o `gc` REAL (mesmos fragmentos, mesmas respostas)
e depois **30 regras são quebradas, uma por vez**, numa cópia do motor — cada mutante tem de deixar a suíte vermelha (`PCE_ST_NO_MUTANTS=1` pula essa parte numa rodada rápida; `PCE_ST_MUTANT_FILTER="nome1 nome2"` roda só alguns).

`bash packs/town-deltas/assets/pool-ceiling.selftest.sh` (292 asserts; passa em `/bin/bash` 3.2 e bash 5) — reprova sem a lib
e sem a fiação nos dois dispatchers; inclui a função de cola REAL do Pilot e o bloco REAL do teto do gate
(duas passadas, a 2ª emulando o re-exec do multi-admit ga-309v3, sob `set -euo pipefail`) extraídos dos
arquivos e rodados contra fixtures, e os produtores de cota dos dois dispatchers rodados contra um checker
falso (exit 0/2/1/124/3, morto por sinal, ausente, sem permissão, sem o binário `timeout`). Mutações que o teste pega (cada uma foi aplicada e o teste reprovou): sinal ilegível sobe,
fila ilegível lida como 0, squeeze não encolhe, sem limite de ritmo, ligado por padrão, fila velha
confiada, teto do motor ignorado, decaimento por fila vazia de volta, Dolt ilegível lido como ok,
DRY_RUN ignorado, sombra aplicando o teto, sombra gravando o estado real, relógio ilegível lido como época 0, estado corrompido reiniciado em silêncio,
**cota ilegível (checker ausente/com erro/estourou o tempo) entregue ao teto como `ok`** (o teste novo reprova no código anterior com o
sintoma literal `wa-worker 2→3 (up, queue+slack)`), limiar de swap/load com lixo lido como "não apertou", **sinalizador de Dolt do Pilot ausente/lixo lido como `ok`** (o padrão é "ilegível"),
**ligado + lib que não carrega = silêncio** (o loader REAL de cada dispatcher roda sob `set -euo pipefail` contra lib boa, corrompida, ausente e vazia),
fila carimbada no futuro lida como fresca, e **o próprio selftest escrevendo no log de produção** — a seção 11 conta, no log e no diretório de estado reais, as linhas/arquivos com
carimbo de tempo FALSO (os `POOL_CEILING_NOW` do teste, 100..3000; um passo real leva a época, ~1,79e9) antes e depois da execução inteira e fica
vermelha se qualquer seção esquecer de se isolar (sem isso, 57 execuções deixaram 114 linhas falsas na série de 24h). Conta só o que um TESTE
poderia ter escrito, não bytes: com o teto ligado em sombra, uma varredura real do dispatcher acrescenta linhas ao mesmo log durante a execução e isso não pode
deixar o teste vermelho (o próprio teste cobre o detector: a linha falsa conta, a de época real não).

Antes de ligar: `pool-ceiling.sh status` mostra o sinal agora. Ligue em SOMBRA e deixe 24h; confira em
`.gc/logs/pool-ceiling.log` quanto tempo cada sinal ficou em grow/hold/squeeze antes de tirar a sombra.
