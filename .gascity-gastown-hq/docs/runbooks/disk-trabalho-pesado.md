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
| `DISK_NEW_WORK_MIN_MB` | 5120 (5 GB) | nada NOVO deve começar. Quem lê este piso: o Pilot (ga-ydaslo) e as sondas do pool (ga-09hfgh), fatias próprias; o `heavy-guard.sh` não lê (usa o seu) |

O de passo pesado é mais alto de propósito: um passo precisa de folga para TERMINAR, o despacho só precisa de espaço para começar. Três estados, nunca dois: `ok`, `low`, `unknown` (df falhou ou não é número). O `heavy-guard.sh` falha FECHADO em `unknown` (o passo guardado falha por ENOSPC no banco). Quem decide sobre trabalho NOVO (fatias seguintes) deve falhar ABERTO e dizer isso no log: um soluço do df não pode parar a cidade.

## Quem faz o quê (4 peças, entregues em fatias)

Esta fatia entrega só a peça 1; as outras três estão em beads próprias.

1. **`scripts/heavy-guard.sh`** (esta fatia, ga-vln2py) — o guarda de passo pesado (abaixo). Já chamado por `jsonl-archive-compact.selftest.sh`; o texto do gate (`gate-review-task.lib.sh`, parágrafo HQ SELFTESTS) e a doutrina (`town-deltas.template.md`) mandam rodar localmente por ele a bateria que o `mbp-run.sh` devolveu com 96..99.
2. **Pilot** — com < 5 GB o sweep pausa. Outra fatia: ga-ydaslo (o estado é o da bead).
3. **Sondas de pool** (dog, wa-worker, ps-worker) — com < 5 GB não entregam bead nova. Outra fatia: ga-09hfgh (o estado é o da bead).
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
| `DISK_HEADROOM_ENABLED=0` | toda leitura da lib vira `ok` (hoje: o guarda) | nunca em produção |
| `DISK_FREE_OVERRIDE_MB=<n>` | fixa a leitura (n = MB; não numérico = ilegível) | selftests |
| `DISK_NEW_WORK_MIN_MB` / `DISK_HEAVY_MIN_MB` | ajusta os pisos (valor não numérico volta ao padrão) | só com decisão registrada |

## Como conferir que está vivo

- Guarda: `scripts/heavy-guard.sh --check --what teste; echo rc=$?` (0 com folga; `DISK_FREE_OVERRIDE_MB=3000` dá 75).
- Recusas: `tail $GC_CITY_PATH/.gc/logs/heavy-guard.log`.
- Bateria: `scripts/heavy-guard.selftest.sh`.

## Limites conhecidos

- O guarda só protege quem o chama. Hoje: o selftest do jsonl-archive, o fallback local das baterias (por doutrina) e o gate. O pre-commit do beads depende do trecho acima ser aplicado naquele repo.
- `go build` e `golangci-lint` não têm destino remoto hoje; com disco baixo eles esperam.
- Uma sessão que JÁ está dentro de um passo quando o disco cai não é interrompida por esta fatia.
- A leitura é do volume do swap/Dolt (`/private/var/vm`, senão `/`). Um disco externo/montagem separada não conta.
