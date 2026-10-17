## Contents

- O que isto resolve
- Os dois pisos
- Quem faz o quê (4 peças)
- heavy-guard.sh: uso e códigos de saída
- Trecho pronto para o pre-commit do repo beads
- Interruptores
- Como conferir que está vivo
- Limites conhecidos

# Disco do mini baixo: passo pesado não começa, bead nova não começa (ga-vln2py)

## O que isto resolve

17/10 12:40–12:56: três passos de agente (um `git repack` no jsonl-archive, um selftest copiando o `hq.jsonl` para `/tmp`, `go build` + `golangci-lint` do repo beads) rodaram com o disco já baixo e o encheram. O Dolt tomou ENOSPC ao escrever o journal do hq e a cidade ficou ~16 min sem dados. Os freios que existiam olhavam o lugar errado: o Pilot só segurava despacho NOVO com swap livre < 512 MB **e** disco < 4 GB (ga-9e446u) — o swap estava em 3–4,5 GB —, e o `dolt-disk-floor-guard` só limpava cache depois, sem avisar quem estava enchendo.

## Os dois pisos

Uma fonte só: `packs/town-deltas/assets/scripts/disk-headroom-lib.sh` (MB livres no volume do swap e do Dolt).

| Piso | Valor | Abaixo dele |
|---|---|---|
| `DISK_NEW_WORK_MIN_MB` | 5120 (5 GB) | nada NOVO começa: o Pilot pausa o sweep; as sondas do dog, wa-worker e ps-worker devolvem `[]` para bead nova |
| `DISK_HEAVY_MIN_MB` | 6144 (6 GB) | passo pesado não começa nesta máquina (`heavy-guard.sh` recusa) |

O de passo pesado é mais alto de propósito: um passo precisa de folga para TERMINAR, o despacho só precisa de espaço para começar. Três estados, nunca dois: `ok`, `low`, `unknown` (df falhou ou não é número). Quem decide sobre trabalho NOVO falha ABERTO em `unknown` (um soluço do df não pode parar a cidade) e diz isso no log; o `heavy-guard.sh` falha FECHADO (o passo guardado falha por ENOSPC no banco).

## Quem faz o quê (4 peças)

1. **`scripts/heavy-guard.sh`** — o guarda de passo pesado (abaixo). Já chamado por `jsonl-archive-compact.selftest.sh`; o texto do gate (`gate-review-task.lib.sh`, parágrafo HQ SELFTESTS) e a doutrina (`town-deltas.template.md`) mandam rodar localmente por ele a bateria que o `mbp-run.sh` devolveu com 96..99.
2. **Pilot** (`pilot-dispatcher.sh`, `_pilot_disk_floor`) — com < 5 GB o sweep inteiro pausa: log `dispatched=0 (paused: disk floor)`, `pilot-sweep-pause-state.json` com `reason: disk-floor`. Pausa total, sem exceção (inclui `impacto:dano-ao-vivo`: um builder novo num disco desses é o que derruba o Dolt, e o dano ao vivo seria pior). Não manda push por sweep; o alarme é do `dolt-disk-floor-guard`.
3. **Sondas de pool** — `scripts/pool-probe.sh` (dog: segura só a bead de HISTÓRIA da camada 1, sem `gc.kind`; trabalho de fórmula do próprio dog — shutdown dance, reaper — segue) e os blocos Step 1b2/1b3 de `agents/wa-worker` e `agents/ps-worker` (`[]`). `[]` por disco baixo é um "nada para você" de verdade: drene, não procure bead por outro caminho.
4. **`dolt-disk-floor-guard.sh`** (`_nudge_pool_heavy_stop`) — no CRITICAL, antes da foto e das alavancas, um `gc session nudge` para cada sessão ATIVA de `gastown.dog`, `wa-worker`, `ps-worker`, `gate-reviewer` ("DISK CRITICAL … pare passos pesados"). Cooldown de 15 min; lista que não pôde ser lida = log + tenta de novo no próximo ciclo (nunca vira "ninguém aí"). Crews não são avisadas (pode ter gente na frente). O nudge usa a entrega padrão (`wait-idle`): não interrompe um passo em andamento, mas barra o PRÓXIMO.

## heavy-guard.sh: uso e códigos de saída

```
heavy-guard.sh [--min-free-mb N] [--wait-secs S] [--what RÓTULO] -- <comando> [args...]
heavy-guard.sh --check [--min-free-mb N] [--wait-secs S] [--what RÓTULO]
```

| rc | Significa | O que fazer |
|---|---|---|
| (o do comando) | rodou | — |
| 75 | disco abaixo do piso (6 GB), mesmo depois da espera | NÃO rode por outro caminho. Selftest do hq: `mbp-run.sh --repo hq` (nó Linux). `go build`/lint não vão ao nó hoje. Ou espere e tente de novo; se não voltar, avise o Mayor |
| 76 | não consegui ler o disco (df falhou, ou a lib não carregou) | o passo também é recusado; tente de novo; se persistir, avise o Mayor |
| 64 | uso errado | corrija a chamada |

75/76 ficam FORA da faixa 96..99 do `mbp-run.sh` ("rode local") de propósito: uma recusa nunca pode ser lida como licença para rodar aqui. Cada recusa vai (melhor esforço) para `$GC_CITY_PATH/.gc/logs/heavy-guard.log`.

## Trecho pronto para o pre-commit do repo beads

O repo do beads (onde o `golangci-lint` do pre-commit rodou na hora do incidente) NÃO é editado por esta bead. Para ligar o guarda lá, no hook de pre-commit (script git) ou como hook local do framework pre-commit:

```sh
# ga-vln2py: sem golangci-lint nem go build com o disco do mini abaixo do piso
GUARD="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}/scripts/heavy-guard.sh"
if [ -x "$GUARD" ]; then "$GUARD" --check --what "pre-commit golangci-lint" || exit $?; fi
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
| `DISK_HEADROOM_ENABLED=0` | toda leitura vira `ok` (guarda, Pilot, sondas) | nunca em produção |
| `PILOT_DISK_FLOOR_ENABLED=0` | só o gate do Pilot | nunca em produção |
| `DOLT_DISK_FLOOR_POOL_NUDGE=0` | só o nudge do guard | nunca em produção |
| `DISK_FREE_OVERRIDE_MB=<n>` | fixa a leitura (n = MB; não numérico = ilegível) | selftests |
| `DISK_NEW_WORK_MIN_MB` / `DISK_HEAVY_MIN_MB` | ajusta os pisos | só com decisão registrada |

## Como conferir que está vivo

- Guarda: `scripts/heavy-guard.sh --check --what teste; echo rc=$?` (0 com folga; `DISK_FREE_OVERRIDE_MB=3000` dá 75).
- Pilot: `grep 'disk floor' $GC_CITY_PATH/.gc/logs/pilot-dispatcher.log` e `jq -r .reason ~/.gc/pilot-sweep-pause-state.json` durante uma pausa.
- Sonda do dog: `DISK_FREE_OVERRIDE_MB=3000 sh packs/town-deltas/assets/scripts/pool-probe.sh gastown.dog` (só história some; exit 0 e nada no stderr).
- Nudge: `grep 'pool nudge' $GC_CITY_PATH/.gc/logs/dolt-disk-floor-guard.log`.
- Baterias: `scripts/heavy-guard.selftest.sh`, `scripts/dolt-disk-floor-guard.pool-nudge.selftest.sh`, `packs/town-deltas/assets/pool-probe-disk-floor.selftest.sh`, os cenários `20d-disk-*` de `pilot-dispatcher.selftest.sh` e a seção 11 de `scripts/pool-probe.selftest.sh`.

## Limites conhecidos

- Uma sessão que JÁ está dentro de um passo quando o disco cai não é interrompida; o nudge chega no próximo idle.
- O guarda só protege quem o chama. Hoje: o selftest do jsonl-archive, o fallback local das baterias (por doutrina) e o gate. O pre-commit do beads depende do trecho acima ser aplicado naquele repo.
- `go build` e `golangci-lint` não têm destino remoto hoje; com disco baixo eles esperam.
- A sonda longa `sh -c '…'` que o ENGINE renderiza no prompt do dog não passa pelo hold (só o `pool-probe.sh` passa; é ele que a doutrina manda usar desde a ga-witezg). O risco são as beads já roteadas ao dog (por qualquer caminho, inclusive o gate devolvendo uma reprovada) enquanto ele usa a sonda longa; o Pilot, por sua vez, não despacha nada com o disco baixo (o sweep pausa).
- A leitura é do volume do swap/Dolt (`/private/var/vm`, senão `/`). Um disco externo/montagem separada não conta.
