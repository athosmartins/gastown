## Contents

- O que isto resolve
- Os dois pisos
- Quem faz o quê (4 peças, entregues em fatias)
- heavy-guard.sh: uso e códigos de saída
- Trecho pronto para o pre-commit do repo beads
- Interruptores
- Como conferir que está vivo
- Limites conhecidos

# Disco do mini baixo: passo pesado não começa, bead nova não começa (ga-vln2py)

## O que isto resolve

17/10 12:40–12:56: três passos de agente (um `git repack` no jsonl-archive, um selftest copiando o `hq.jsonl` para `/tmp`, `go build` + `golangci-lint` do repo beads) rodaram com o disco já baixo e o encheram. O Dolt tomou ENOSPC ao escrever o journal do hq e a cidade ficou ~16 min sem dados. Os freios que existiam olhavam o lugar errado: o Pilot só segurava despacho NOVO com swap livre < 512 MB **e** disco < 4 GB (ga-9e446u) — o swap estava em 3–4,5 GB —, e o `dolt-disk-floor-guard` só limpava cache depois, sem avisar quem estava enchendo.

A ga-vln2py foi recusada pelo gate no teto de tamanho (E11) e entregue em 4 fatias, uma branch e um marker cada. Este runbook cresce com elas: cada fatia acrescenta o que entrega (peças, interruptores, como conferir).

## Os dois pisos

Uma fonte só: `packs/town-deltas/assets/scripts/disk-headroom-lib.sh` (MB livres no volume do swap e do Dolt).

| Piso | Valor | Abaixo dele |
|---|---|---|
| `DISK_HEAVY_MIN_MB` | 6144 (6 GB) | passo pesado não começa nesta máquina (`heavy-guard.sh` recusa) |
| `DISK_NEW_WORK_MIN_MB` | 5120 (5 GB) | nada NOVO deve começar. Quem lê este piso: as sondas do pool (peça 3, ga-09hfgh) e, em outra fatia, o Pilot (ga-ydaslo); o `heavy-guard.sh` não lê (usa o seu) |

O de passo pesado é mais alto de propósito: um passo precisa de folga para TERMINAR, o despacho só precisa de espaço para começar. Três estados, nunca dois: `ok`, `low`, `unknown` (df falhou ou não é número). O `heavy-guard.sh` falha FECHADO em `unknown` (o passo guardado falha por ENOSPC no banco). Quem decide sobre trabalho NOVO (fatias seguintes) deve falhar ABERTO e dizer isso no log: um soluço do df não pode parar a cidade.

## Quem faz o quê (4 peças, entregues em fatias)

Esta fatia entrega a peça 2 (o Pilot), em cima das peças 1 (ga-vln2py, o guarda) e 3 (ga-09hfgh, as sondas), já na main; a peça 4 está em bead própria.

1. **`scripts/heavy-guard.sh`** (ga-vln2py) — o guarda de passo pesado (abaixo). Já chamado por `jsonl-archive-compact.selftest.sh`; o texto do gate (`gate-review-task.lib.sh`, parágrafo HQ SELFTESTS) e a doutrina (`town-deltas.template.md`) mandam rodar localmente por ele a bateria que o `mbp-run.sh` devolveu com 96..99.
2. **Pilot** (`pilot-dispatcher.sh`, `_pilot_disk_floor`; esta fatia, ga-ydaslo) — com < 5 GB o sweep inteiro pausa: log `dispatched=0 (paused: disk floor)`, `pilot-sweep-pause-state.json` com `reason: disk-floor`. Pausa total, sem exceção (inclui `impacto:dano-ao-vivo`: um builder novo num disco desses é o que derruba o Dolt, e o dano ao vivo seria pior). Leitura ilegível falha ABERTA e visível no log ("Disk free UNREADABLE"). Não manda push por sweep; o alarme é do `dolt-disk-floor-guard`. Interruptor: `PILOT_DISK_FLOOR_ENABLED=0` (nunca em produção; só o gate do Pilot); SÓ o texto `0` desliga — `1` liga, e qualquer outra palavra (`true`, `yes`, `on`, `01`, `false`) mantém o gate LIGADO e deixa um WARN `PILOT_DISK_FLOOR_ENABLED='…' is neither 0 nor 1` (ga-nyug12; antes só o `1` ligava e essas grafias desligavam sem rastro). Variáveis de ambiente que entortam o gate também deixam rastro, a cada sweep, em um WARN `Disk floor gate bent by the environment — …`: `DISK_HEADROOM_ENABLED=0` (toda leitura vira `ok`, o gate nunca pausa) e `DISK_NEW_WORK_MIN_MB` diferente de 5120 (o WARN traz o piso em vigor e o padrão 5120). Com `PILOT_DISK_FLOOR_ENABLED=0` o gate está desligado de propósito e não diz nada. Conferir: `grep 'disk floor' $GC_CITY_PATH/.gc/logs/pilot-dispatcher.log` e `jq -r .reason ~/.gc/pilot-sweep-pause-state.json` durante uma pausa; cenários `20d-disk-*` de `pilot-dispatcher.selftest.sh`.
3. **Sondas de pool** (ga-09hfgh) — `scripts/pool-probe.sh` (dog: com < 5 GB segura só a bead de HISTÓRIA da camada 1: tipo task/bug/feature/chore/epic/spike SEM nenhuma marca de fórmula (`gc.kind`, `gc.step_ref`, `gc.pool_demand`); molécula e passos de ordem — a limpeza de bancos velhos `mol-dog-stale-db`, o digest — seguem, e um tipo que a regra não conhece também segue. A regra é uma só, `DISK_HOLD_NEW_STORIES_JQ` na lib. O hold roda depois da janela `--limit=20` da camada 1; se a janela veio cheia (20) e o hold esvaziou, o `pool-probe.sh` busca de novo SEM limite (`--limit=0`) para não deixar trabalho de fórmula esperando atrás de 20 histórias mais velhas — é a única chamada `bd` a mais, e só com o disco baixo; se essa segunda leitura falhar, a camada 1 vira ilegível (exit 3, `[]` NÃO é "sem trabalho", ga-nyug12)) e os blocos Step 1b2/1b3 de `agents/wa-worker` e `agents/ps-worker` (`[]`). Esse `[]` não tem exceção para a classe de CONSERTO (`gate:needs-fix`, `gate:fix-attempt:*`, `origem:auto-healer-notify`, `impacto:dano-ao-vivo`), como a pausa total do Pilot; mas o Step 1b2 agora escreve uma linha `NOTE disk floor` no stderr com os ids segurados e manda avisar o Mayor (`gc session nudge mayor "low disk holds …"`), que decide se roda. `[]` por disco baixo é um "nada para você" de verdade: drene, não procure bead por outro caminho. O Step 1b3 é mudo com disco `unknown` DE PROPÓSITO: o 1b2 roda antes, no mesmo turno, e é dele o aviso. Leitura ilegível = a sonda responde como antes e deixa uma linha no log (falha ABERTA: um soluço do df não pode secar o pool).
4. **`dolt-disk-floor-guard.sh`** — no CRITICAL, nudge "pare passos pesados" às sessões ativas do pool. Outra fatia, independente desta: ga-vln2py.3 (o estado é o da bead; quem é avisado, o cooldown e o interruptor estão no cabeçalho do próprio script). (O alerta CRITICAL pelo `notify` com `NOTIFY_FORCE_PUSH=1`, independente do Dolt, além do mail do Mayor, já existe desde a ga-ff6t9.)

## heavy-guard.sh: uso e códigos de saída

```
heavy-guard.sh [--min-free-mb N] [--wait-secs S] [--what RÓTULO] -- <comando> [args...]
heavy-guard.sh --check [--min-free-mb N] [--wait-secs S] [--what RÓTULO]
```

| rc | Significa | O que fazer |
|---|---|---|
| (o do comando) | rodou | — |
| 75 | disco abaixo do piso (6 GB), mesmo depois da espera | NÃO rode por outro caminho. Selftest do hq: `mbp-run.sh --repo hq` (nó Linux). `go build`/lint não vão ao nó hoje. Ou espere e tente de novo; se não voltar, avise o Mayor |
| 76 | não consegui ler o disco (df falhou, leitura com mais de 9 dígitos, ou a lib não carregou: esta última também vai ao log) | o passo também é recusado; tente de novo; se persistir, avise o Mayor |
| 64 | uso errado (inclui `--min-free-mb` ou `--wait-secs` com mais de 9 dígitos: acima do que `[ -lt ]` compara, um piso assim valeria "folga") | corrija a chamada |

75/76 ficam FORA da faixa 96..99 do `mbp-run.sh` ("rode local") de propósito: uma recusa nunca pode ser lida como licença para rodar aqui. Cada recusa vai (melhor esforço) para `$GC_CITY_PATH/.gc/logs/heavy-guard.log`.

## Trecho pronto para o pre-commit do repo beads

O repo do beads (onde o `golangci-lint` do pre-commit rodou na hora do incidente) NÃO é editado por esta bead. Para ligar o guarda lá, no hook de pre-commit (script git) ou como hook local do framework pre-commit:

```sh
# ga-vln2py: sem golangci-lint nem go build com o disco do mini abaixo do piso
GUARD="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/scripts/heavy-guard.sh"
if [ -x "$GUARD" ]; then "$GUARD" --check --what "pre-commit golangci-lint" || exit $?
else echo "pre-commit: disco NÃO checado ($GUARD ausente)" >&2; fi
```

```yaml
# .pre-commit-config.yaml (hook local que embrulha o comando)
- id: golangci-lint-guarded
  name: golangci-lint (guarda de disco)
  entry: /Users/athos/gt/.gascity-gastown-hq/scripts/heavy-guard.sh --what golangci-lint -- golangci-lint run
  language: system
  pass_filenames: false
```

Um commit recusado com 75 não é um commit falho: espere o disco ou rode o commit quando voltar. Não use `--no-verify` para contornar.

## Interruptores

| Interruptor | Efeito | Uso |
|---|---|---|
| `DISK_HEADROOM_ENABLED=0` | toda leitura da lib vira `ok` (guarda, sondas e Pilot). O guarda avisa no stderr ("NOTE: ... bypassed") e grava `BYPASS` no log quando deixa passar por este interruptor ou por `DISK_FREE_OVERRIDE_MB`; o Pilot deixa um WARN `Disk floor gate bent by the environment` a cada sweep | nunca em produção |
| `PILOT_DISK_FLOOR_ENABLED` | só o texto `0` desliga o gate do Pilot; `1` liga; outro valor mantém ligado e é nomeado no log (`neither 0 nor 1`) | nunca `0` em produção |
| `DISK_FREE_OVERRIDE_MB=<n>` | fixa a leitura (n = MB; não numérico = ilegível) | selftests |
| `DISK_NEW_WORK_MIN_MB` / `DISK_HEAVY_MIN_MB` | ajusta os pisos (valor não numérico volta ao padrão). No Pilot, `DISK_NEW_WORK_MIN_MB` diferente de 5120 vira o WARN `bent by the environment` com o piso em vigor | só com decisão registrada |

## Como conferir que está vivo

- Guarda: `scripts/heavy-guard.sh --check --what teste; echo rc=$?` (0 com folga; `DISK_FREE_OVERRIDE_MB=3000` dá 75).
- Recusas e bypass: `tail $GC_CITY_PATH/.gc/logs/heavy-guard.log` (`REFUSED ...` / `BYPASS ...`; uma linha `BYPASS` fora de selftest = um `export` esquecido).
- Pilot entortado por variável: `grep 'bent by the environment' $GC_CITY_PATH/.gc/logs/pilot-dispatcher.log` (uma linha por sweep enquanto a variável existir; vazio em produção normal).
- Sonda do dog: `DISK_FREE_OVERRIDE_MB=3000 sh packs/town-deltas/assets/scripts/pool-probe.sh gastown.dog` (só história some; exit 0 e nada no stderr; o trabalho de fórmula do dog continua saindo). Leitura ilegível: `grep 'free disk unreadable' $GC_CITY_PATH/.gc/logs/pool-probe.log`.
- Janela cheia no dog (ga-nyug12): com 20 histórias mais velhas na frente de uma bead de fórmula e o disco baixo, a camada 1 relê SEM limite em vez de responder `[]`; `grep 'refetched' $GC_CITY_PATH/.gc/logs/pool-probe.log` mostra cada vez que isso foi preciso, e `could not be read` na mesma linha de log indica que a segunda leitura falhou (exit 3, `[]` não é "sem trabalho").
- Baterias: `scripts/heavy-guard.selftest.sh`, `packs/town-deltas/assets/pool-probe-disk-floor.selftest.sh`, a seção 11 de `scripts/pool-probe.selftest.sh`, os cenários `20d-disk-*` de `pilot-dispatcher.selftest.sh` e `selftest-disk-pin-class.selftest.sh` (que agora enxerga `bash --norc "$X"`, `-o NAME`, `--rcfile`/`--init-file FILE` e `--` entre o shell e o script).

## Limites conhecidos

- O guarda só protege quem o chama. Hoje: o selftest do jsonl-archive, o fallback local das baterias (por doutrina) e o gate. O pre-commit do beads depende do trecho acima ser aplicado naquele repo.
- `go build` e `golangci-lint` não têm destino remoto hoje; com disco baixo eles esperam.
- O parágrafo do gate sobre baterias do hq (`gate_hq_selftest_rules`) só sai com o nó ligado (`.gc/hetzner-node.on`); com o nó desligado o revisor não recebe a instrução do guarda por ali (o pool recebe pela seção `hq-selftest-node`, sempre).
- Uma sessão que JÁ está dentro de um passo quando o disco cai não é interrompida por esta fatia.
- A sonda longa `sh -c '…'` que o ENGINE renderiza no prompt do dog não passa pelo hold (só o `pool-probe.sh` passa; é ele que a doutrina manda usar desde a ga-witezg). O risco são as beads já roteadas ao dog (por qualquer caminho) enquanto ele usa a sonda longa.
- As sondas do wa-worker e do ps-worker respondem `[]` sem separar fórmula de história, porque hoje não há fórmula nelas: medido em 17/10, as 1125 beads roteadas ao wa-worker e as 51 do ps-worker são todas de tipo história sem marca de fórmula, e nenhuma ordem do `city.toml` aponta para esses pools. Se um dia houver, aquelas duas sondas passam a usar `DISK_HOLD_NEW_STORIES_JQ`. Pelo mesmo motivo a classe de CONSERTO fica segurada ali com < 5 GB (sem exceção); o que existe é o aviso ao Mayor descrito na peça 3, não uma isenção.
- No dog, a bead de REPARO criada por agente (tipo task, sem marca de fórmula) também é segurada com < 5 GB: é trabalho novo. Quem precisar dela rodando com o disco baixo avisa o Mayor.
- A leitura é do volume do swap/Dolt (`/private/var/vm`, senão `/`). Um disco externo/montagem separada não conta.
