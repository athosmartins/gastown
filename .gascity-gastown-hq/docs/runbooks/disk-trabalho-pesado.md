## Contents

- O que isto resolve
- Os pisos (três, mais o par do push)
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

## Os pisos (três, mais o par do push)

Uma fonte só: `packs/town-deltas/assets/scripts/disk-headroom-lib.sh` (MB livres no volume do swap e do Dolt).

| Piso | Valor | Abaixo dele |
|---|---|---|
| `DISK_HEAVY_MIN_MB` | 6144 (6 GB) | passo pesado não começa nesta máquina (`heavy-guard.sh` recusa) |
| `DISK_GO_MIN_MB` | 13312 (13 GB) | `go build/test/vet/install` não começa nesta máquina (ga-edkfip). O `heavy-guard.sh` usa o MAIOR entre este e o de passo pesado; a recusa manda o passo ao MBP (`mbp-run.sh --exec --go`, receita em `mbp-offload.md`, "Go no MBP") |
| `DISK_NEW_WORK_MIN_MB` | 5120 (5 GB) | nada NOVO deve começar. Quem lê este piso: as sondas do pool (peça 3, ga-09hfgh) e, em outra fatia, o Pilot (ga-ydaslo); o `heavy-guard.sh` não lê (usa o seu) |
| `DISK_PUSH_MIN_MB` | 5000 (~5 GB) | um `git push` (e o pre-push atrás dele) não começa sob o `heavy-guard.sh` (ga-pwd2h6). MENOR que o de passo pesado de propósito: em 24/10 o disco do mini oscilou entre 4,8 e 6,1 GB o dia todo, um push só escreve ~0-200 MB (worktree e tmp; mínimo visto durante 5 pushes: 5052 MB) e, a 6144, todo push de worker WA parava e pedia exceção ao Mayor (5 vezes naquele dia) |
| `DISK_PUSH_STOP_MB` | 4000 (~4 GB) | um push EM CURSO sob o guarda é interrompido (rc 78) se o livre cair abaixo disso. É a margem sobre o piso CRÍTICO do Dolt (3 GB). Nunca fica acima do de início: o valor maior é puxado para ele |

O de Go (ga-edkfip) existe porque 6 GB não bastou: 19/10 06:03-06:09 um build frio de `cmd/gc` começou com o disco logo acima de 6 GB, escreveu ~4 GB de cache em 6 minutos e deixou 2 GB — o Dolt ficou no piso CRÍTICO por dois ciclos até alguém matar o build à mão. Um build/teste frio do engine escreve 4–10 GB (medido) e o `dolt-disk-floor-guard` vai a CRÍTICO com 3 GB: 10 + 3 = 13. Com ~7 GB livres (19/10) isso significa "Go não roda no mini": roda no MBP.

O de passo pesado é mais alto de propósito: um passo precisa de folga para TERMINAR, o despacho só precisa de espaço para começar. Três estados, nunca dois: `ok`, `low`, `unknown` (df falhou ou não é número). O `heavy-guard.sh` falha FECHADO em `unknown` (o passo guardado falha por ENOSPC no banco). Quem decide sobre trabalho NOVO (fatias seguintes) deve falhar ABERTO e dizer isso no log: um soluço do df não pode parar a cidade.

## Quem faz o quê (4 peças, entregues em fatias)

Esta fatia entrega a peça 2 (o Pilot), em cima das peças 1 (ga-vln2py, o guarda) e 3 (ga-09hfgh, as sondas), já na main; a peça 4 está em bead própria.

1. **`scripts/heavy-guard.sh`** (ga-vln2py) — o guarda de passo pesado (abaixo). Já chamado por `jsonl-archive-compact.selftest.sh`; o texto do gate (`gate-review-task.lib.sh`, parágrafo HQ SELFTESTS) e a doutrina (`town-deltas.template.md`) mandam rodar localmente por ele a bateria que o `mbp-run.sh` devolveu com 96..99.
2. **Pilot** (`pilot-dispatcher.sh`, `_pilot_disk_floor`; esta fatia, ga-ydaslo) — com < 5 GB o sweep inteiro pausa: log `dispatched=0 (paused: disk floor)`, `pilot-sweep-pause-state.json` com `reason: disk-floor`. Pausa total, sem exceção (inclui `impacto:dano-ao-vivo`: um builder novo num disco desses é o que derruba o Dolt, e o dano ao vivo seria pior). Leitura ilegível falha ABERTA e visível no log ("Disk free UNREADABLE"). Não manda push por sweep; o alarme é do `dolt-disk-floor-guard`. Interruptor: `PILOT_DISK_FLOOR_ENABLED=0` (nunca em produção; só o gate do Pilot); SÓ o texto `0` desliga — `1` liga, e qualquer outra palavra (`true`, `yes`, `on`, `01`, `false`) mantém o gate LIGADO e deixa um WARN `PILOT_DISK_FLOOR_ENABLED='…' is neither 0 nor 1` (ga-nyug12; antes só o `1` ligava e essas grafias desligavam sem rastro). Duas variáveis de ambiente que entortam o gate deixam rastro, a cada sweep, em um WARN `Disk floor gate bent by the environment — …`: `DISK_HEADROOM_ENABLED=0` (toda leitura vira `ok`, o gate nunca pausa) e `DISK_NEW_WORK_MIN_MB` diferente do TEXTO `5120` (o WARN traz o piso em vigor e o padrão 5120; `05120` vale o mesmo número mas é um texto diferente, então também avisa). **Não deixam rastro nenhum** no log do Pilot: `PILOT_DISK_FREE_OVERRIDE_MB` e `DISK_FREE_OVERRIDE_MB` (fixam a leitura do disco; os selftests as fixam em toda corrida), `DISK_HEADROOM_PATH` (muda o volume lido) e um `DISK_NEW_WORK_MIN_MB` que não é número (`abc`, `2GB`, vazio, mais de 9 dígitos): a lib o troca por 5120 sem dizer, o que protege, mas a intenção de quem o pôs se perde sem rastro. Com `PILOT_DISK_FLOOR_ENABLED=0` o gate está desligado de propósito e não diz nada. Conferir: `grep 'disk floor' $GC_CITY_PATH/.gc/logs/pilot-dispatcher.log` e `jq -r .reason ~/.gc/pilot-sweep-pause-state.json` durante uma pausa; cenários `20d-disk-*` de `pilot-dispatcher.selftest.sh`.
3. **Sondas de pool** (ga-09hfgh) — `scripts/pool-probe.sh` (dog: com < 5 GB segura só a bead de HISTÓRIA da camada 1: tipo task/bug/feature/chore/epic/spike SEM nenhuma marca de fórmula (`gc.kind`, `gc.step_ref`, `gc.pool_demand`); molécula e passos de ordem — a limpeza de bancos velhos `mol-dog-stale-db`, o digest — seguem, e um tipo que a regra não conhece também segue. A regra é uma só, `DISK_HOLD_NEW_STORIES_JQ` na lib. O hold roda depois da janela `--limit=20` da camada 1; se a janela veio cheia (20) e o hold esvaziou, o `pool-probe.sh` busca de novo SEM limite (`--limit=0`) para não deixar trabalho de fórmula esperando atrás de 20 histórias mais velhas — é a única chamada `bd` a mais, e só com o disco baixo; se essa segunda leitura falhar, a camada 1 vira ilegível (exit 3, `[]` NÃO é "sem trabalho", ga-nyug12)) e os blocos Step 1b2/1b3 de `agents/wa-worker` e `agents/ps-worker` (`[]`). Esse `[]` não tem exceção para a classe de CONSERTO (`gate:needs-fix`, `gate:fix-attempt:*`, `origem:auto-healer-notify`, `impacto:dano-ao-vivo`), como a pausa total do Pilot; mas o Step 1b2 agora escreve uma linha `NOTE disk floor` no stderr com os ids segurados e manda avisar o Mayor (`gc session nudge mayor "low disk holds …"`), que decide se roda. `[]` por disco baixo é um "nada para você" de verdade: drene, não procure bead por outro caminho. O Step 1b3 é mudo com disco `unknown` DE PROPÓSITO: o 1b2 roda antes, no mesmo turno, e é dele o aviso. Leitura ilegível = a sonda responde como antes e deixa uma linha no log (falha ABERTA: um soluço do df não pode secar o pool).
4. **`dolt-disk-floor-guard.sh`** — no CRITICAL, nudge "pare passos pesados" às sessões ativas do pool. Outra fatia, independente desta: ga-vln2py.3 (o estado é o da bead; quem é avisado, o cooldown e o interruptor estão no cabeçalho do próprio script). (O alerta CRITICAL pelo `notify` com `NOTIFY_FORCE_PUSH=1`, independente do Dolt, além do mail do Mayor, já existe desde a ga-ff6t9.)

## heavy-guard.sh: uso e códigos de saída

```
heavy-guard.sh [--min-free-mb N] [--wait-secs S] [--max-file-mb M] [--max-disk-drop-mb D] [--what RÓTULO] -- <comando> [args...]
heavy-guard.sh --check [--min-free-mb N] [--wait-secs S] [--what RÓTULO]
```

| rc | Significa | O que fazer |
|---|---|---|
| (o do comando) | rodou | — |
| 75 | disco abaixo do piso (6 GB; 13 GB para um passo Go), mesmo depois da espera | NÃO rode por outro caminho. Selftest do hq: `mbp-run.sh --repo hq` (nó Linux). `go test/build/vet/install`: MBP, `mbp-run.sh --exec --go` (a mensagem da recusa traz o comando). `golangci-lint` não tem destino remoto hoje. Ou espere e tente de novo; se não voltar, avise o Mayor |
| 76 | não consegui ler o disco (df falhou, leitura com mais de 9 dígitos, ou a lib não carregou: esta última também vai ao log). No push, também: a trava não pôde ser criada (nenhum push roda sem trava) | o passo também é recusado; tente de novo; se persistir, avise o Mayor |
| 78 | (push e selftest/bateria de mutantes) o disco caiu abaixo do piso de PARADA (4 GB), ou, no selftest/mutante, caiu `--max-disk-drop-mb` (2048) desde o início do passo, com o passo em curso, e o guarda o interrompeu | NÃO repita e NÃO contorne (nem `--no-verify`, nem outro caminho): avise o Mayor. No selftest/mutante o que o passo gravou FICA no disco: ache (o `TMPDIR` dele) e limpe com `safe-clean` |
| 79 | (só push) outro push segurou a trava durante toda a espera | não é disco e o push NÃO começou: tente de novo em um minuto; se a trava não solta e o dono sumiu, avise o Mayor |
| 64 | uso errado (inclui `--min-free-mb` ou `--wait-secs` com mais de 9 dígitos: acima do que `[ -lt ]` compara, um piso assim valeria "folga") | corrija a chamada |

**Passo Go (ga-edkfip).** Conta como Go o passo cujo `--what` começa com `go` + `-`, `_` ou espaço + `test|build|vet|install` (maiúsculas não importam: `go-test`, `Go build ./cmd/gc`; `go-testdata` e `gopher-build` não são Go), ou cujo comando traz `go <verbo>` como palavra — também dentro de `sh -c '…'`, depois de `;`, `&&`, `|`, `(`, e atrás de `env K=V` ou de um caminho (`/opt/homebrew/bin/go test`). Um script que roda go por dentro (`bash scripts/x.sh`) NÃO é visto: rotule `--what go-test`. Também NÃO são vistos `go -C <dir> test`, `go run`, `go generate` (builds frios também) e rótulos no plural (`go-tests`). Falso positivo (um `echo go test`, um `git commit -m "fix go test"`) só aplica o piso mais alto, nunca o mais baixo; a recusa então aponta uma receita que não serve — ponha esse texto fora da linha de comando (num arquivo de script) para voltar ao piso de 6 GB. O reconhecedor é bash puro, sem comando externo: nada nele pode "não rodar" e virar "não é Go" (a primeira versão separava o comando com `tr`, e com o fork falhando um `cd /tmp;go test` passava no piso de 6 GB; gate ga-7dd84s). `--min-free-mb` pode SUBIR o piso de uma chamada Go, nunca baixá-lo. Lib sem `DISK_GO_MIN_MB` (mais velha que o guarda) recusa o passo Go com 76 e diz por quê; ela não cai para o piso de 6 GB. O log da recusa leva `class=go`.

**Push (ga-pwd2h6).** `heavy-guard.sh --what pre-push --wait-secs 600 -- git push origin HEAD`: com o disco entre 5000 e 6144 MB o push passa sem exceção do Mayor; abaixo de 5000 espera (`--wait-secs`) e, se não voltar, recusa com 75 (a mensagem diz para não usar `--no-verify`). Enquanto o push roda, uma vigia lê o `df` a cada 3 s: abaixo de 4000 MB ela manda TERM ao grupo de processos do push (KILL 5 s depois, para o que sobrar) e o guarda sai com **78**. Uma leitura que a vigia não consegue fazer (df falhou) NUNCA mata o push: ele segue, e o log ganha UMA linha `WATCH_UNREADABLE`. **Um pre-push por vez:** trava em `$GC_CITY_PATH/.gc/heavy-guard-push.lock` (diretório com `owner` = `<pid> <epoch>`); o segundo push espera até 15 min (`HEAVY_GUARD_PUSH_LOCK_WAIT_SECS`) e, se a trava não soltar, sai com **79**. A trava é retomada quando o dono morreu, quando passou de 2 h (pid reaproveitado, push pendurado) ou quando o diretório está sem `owner` e tem mais de ~1 min (o dono morreu entre o `mkdir` e a escrita); uma trava que o guarda não consegue ler ou julgar é respeitada, nunca retomada. É push o comando `git [-C dir] [-c k=v] … push …` (git puro ou por caminho); com `--check`, sem comando, vale o rótulo `push`, `git push` ou `pre-push`. Com comando, só o comando conta: o rótulo não faz de outro passo um push. **NÃO é visto:** `sh -c 'git push'`, `env git push`, alias do git — ficam no piso de 6144, o lado seguro (a classe do push é a ÚNICA que BAIXA um piso, então toda dúvida cai no piso mais alto). `--min-free-mb` pode subir o piso do push, nunca baixar; um passo Go nunca é push; uma lib sem `DISK_PUSH_*` (mais velha que o guarda) deixa o push no piso de 6144 e num `exec` simples, como antes. `--check` na classe é só o piso: sem trava e sem vigia (nada roda sob o guarda), então quem dá `git push` depois de um `--check` não está coberto por 78/79.

**Selftest e bateria de mutantes (ga-e6ug8gq, ga-2d14tow).** É da classe o passo cujo `--what` ou cuja linha de comando traz `selftest`, `mutant` ou `mutat…` (maiúsculas não importam; comando que começa com `git` e passo Go ficam de fora). Em 27/10 um awk de mutante em laço gravou 4,2 e 5,6 GB em `$TMPDIR`, o disco zerou duas vezes e o Dolt ficou com ENOSPC até `gc dolt restart --force`: o piso lido ANTES do passo não basta. Dois limites, os dois no kernel ou no `df`, nenhum depende do passo se comportar: (1) teto de CADA arquivo, `ulimit -f` de 512 MB (`--max-file-mb M`, 0 tira; `HEAVY_GUARD_SELFTEST_MAX_FILE_MB`): o laço que só enche UM arquivo morre pelo teto; (2) a vigia do push, que lê o `df` a cada 3 s e manda TERM ao grupo do passo (KILL 5 s depois) quando o livre cai abaixo de 4000 MB (`DISK_PUSH_STOP_MB`, puxado para baixo até o piso de partida em vigor, para não matar quem o chamador deixou partir baixo) OU cai 2048 MB desde o início do passo (`--max-disk-drop-mb D`; `HEAVY_GUARD_SELFTEST_MAX_DROP_MB`; 0 na linha de comando tira só a regra de queda, 0 ou lixo no ambiente cai em 2048 e NÃO destampa), e o guarda sai com **78**. É a vigia que pega o laço que grava MUITOS arquivos pequenos: cada um passa por baixo do teto por arquivo. Leitura que a vigia não consegue fazer (df falhou) NUNCA mata o passo (uma linha `WATCH_UNREADABLE` no log). Limites: a queda é do volume inteiro, então outro processo gravando ao mesmo tempo também conta (só rode de novo com `--max-disk-drop-mb` maior se souber que o passo escreve tanto); o passo roda como filho do guarda, sem terminal de entrada; um descendente que saiu do grupo (`setsid`) não recebe o TERM do grupo. Passo lançado SEM o guarda não tem nenhum dos dois limites.

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
| `DISK_NEW_WORK_MIN_MB` / `DISK_HEAVY_MIN_MB` / `DISK_GO_MIN_MB` / `DISK_PUSH_MIN_MB` / `DISK_PUSH_STOP_MB` | ajusta os pisos (valor não numérico volta ao padrão). No Pilot, `DISK_NEW_WORK_MIN_MB` diferente de 5120 vira o WARN `bent by the environment` com o piso em vigor | só com decisão registrada |

| `HEAVY_GUARD_SELFTEST_MAX_FILE_MB` · `HEAVY_GUARD_SELFTEST_MAX_DROP_MB` | classe selftest/mutante: teto por arquivo (512 MB) e queda do livre que para o passo (2048 MB). Em ambos o ambiente com `0` ou lixo cai no padrão e NÃO tira o limite; só a linha de comando (`--max-file-mb 0`, `--max-disk-drop-mb 0`) tira. A vigia usa o intervalo e a graça da linha de baixo |
| `HEAVY_GUARD_WATCH_SECS` · `HEAVY_GUARD_KILL_GRACE_SECS` · `HEAVY_GUARD_PUSH_LOCK_DIR` · `_WAIT_SECS` · `_POLL_SECS` · `_MAXAGE_SECS` | classe do push: intervalo da vigia (3), graça do TERM antes do KILL (5), onde fica a trava, quanto o segundo push espera (900), de quanto em quanto confere (2) e a idade a partir da qual uma trava é velha (7200). Número com zero à esquerda vale como decimal; texto, negativo ou 0 fora de hora volta ao padrão | selftests; em produção só com decisão registrada |

## Como conferir que está vivo

- Guarda: `scripts/heavy-guard.sh --check --what teste; echo rc=$?` (0 com folga; `DISK_FREE_OVERRIDE_MB=3000` dá 75).
- Push: `DISK_FREE_OVERRIDE_MB=5500 scripts/heavy-guard.sh --check --what pre-push; echo rc=$?` dá 0 (a 5500 o push passa e outro passo pesado não); com `4999` dá 75. No log: `INTERRUPTED …` (a vigia parou um push), `WATCH_UNREADABLE …` (a vigia ficou cega, o push seguiu), `REFUSED … push_lock_busy …` (79) e `PUSH_LOCK_TAKEOVER …` (trava velha retomada). `ls $GC_CITY_PATH/.gc/heavy-guard-push.lock` fora de um push em curso = trava que sobrou (o próximo push a retoma se o dono estiver morto).
- Selftest/mutante: `DISK_FREE_OVERRIDE_MB=20000 scripts/heavy-guard.sh --what selftest-x -- bash -c 'ulimit -f'` imprime 524288 (o teto por arquivo, em KB); `HEAVY_GUARD_ST_ONLY=watch bash scripts/heavy-guard.selftest.sh` roda só os casos da vigia (~30 s, escritor de verdade e `df` falso). No log: `INTERRUPTED … class=step …` (a vigia parou um selftest/mutante).
- Recusas e bypass: `tail $GC_CITY_PATH/.gc/logs/heavy-guard.log` (`REFUSED ...` / `BYPASS ...`; uma linha `BYPASS` fora de selftest = um `export` esquecido).
- Pilot entortado por variável: `grep 'bent by the environment' $GC_CITY_PATH/.gc/logs/pilot-dispatcher.log` (uma linha por sweep enquanto a variável existir; vazio em produção normal).
- Sonda do dog: `DISK_FREE_OVERRIDE_MB=3000 POOL_PROBE_LOG=/dev/null sh packs/town-deltas/assets/scripts/pool-probe.sh gastown.dog` (só história some; exit 0 e nada no stderr; o trabalho de fórmula do dog continua saindo). O `POOL_PROBE_LOG=/dev/null` é para a conferência não deixar uma linha "tier 1 held back" no `pool-probe.log` de produção, que pareceria disco baixo de verdade. Leitura ilegível: `grep 'free disk unreadable' $GC_CITY_PATH/.gc/logs/pool-probe.log`.
- Janela cheia no dog (ga-nyug12): com 20 histórias mais velhas na frente de uma bead de fórmula e o disco baixo, a camada 1 relê SEM limite em vez de responder `[]`; `grep 'refetch' $GC_CITY_PATH/.gc/logs/pool-probe.log` mostra cada vez que isso foi preciso: a linha com `refetched without a limit` é a segunda leitura que deu certo; a linha com `refetch could not be read` é a que falhou (exit 3, `[]` não é "sem trabalho"). Um número que o `jq` não conseguiu contar aparece como `?` nessas linhas (nunca como `0`), e uma contagem ilegível que DECIDE o refetch marca a camada 1 como ilegível: a sonda responde `[]` com exit 3 e a linha `tier(s) 1 unreadable` no stderr, nunca `[]` exit 0.
- Baterias: `scripts/heavy-guard.selftest.sh`, `packs/town-deltas/assets/pool-probe-disk-floor.selftest.sh`, a seção 11 de `scripts/pool-probe.selftest.sh`, os cenários `20d-disk-*` de `pilot-dispatcher.selftest.sh` e `selftest-disk-pin-class.selftest.sh` (que agora enxerga `bash --norc "$X"`, `-o NAME`, `--rcfile`/`--init-file FILE` e `--` entre o shell e o script).

## Limites conhecidos

- O guarda só protege quem o chama. Hoje: o selftest do jsonl-archive, o fallback local das baterias (por doutrina) e o gate. O pre-commit do beads depende do trecho acima ser aplicado naquele repo.
- `go test/build/vet/install` têm destino remoto: o MBP, por `mbp-run.sh --exec --go` (não o nó Linux: `--exec` roda só no MBP). Com o MBP fora (rc 96..99) o passo ESPERA, não volta ao mini. `golangci-lint` não tem destino remoto hoje; com disco baixo ele espera.
- A detecção de passo Go olha o rótulo e a linha de comando, não o que um script faz por dentro; um build disparado por `make`, `bash x.sh` ou um hook só é guardado se quem chama rotular o passo `go-…`. Fora do reconhecimento também: `go -C <dir> test`, `go run`, `go generate`, rótulo no plural.
- O parágrafo do gate sobre baterias do hq (`gate_hq_selftest_rules`) só sai com o nó ligado (`.gc/hetzner-node.on`); com o nó desligado o revisor não recebe a instrução do guarda por ali (o pool recebe pela seção `hq-selftest-node`, sempre).
- Uma sessão que JÁ está dentro de um passo quando o disco cai não é interrompida por esta fatia. Exceção: o push e o selftest/bateria de mutantes lançados pelo guarda, que levam a sua própria vigia (acima). O `hq-mutate.py` (motor do nó Hetzner) tem a dele, por slot.
- A trava do push é exclusão mútua de MELHOR ESFORÇO: dois que esperam podem julgar a mesma trava velha e disputar a retomada (o `mv` atômico deixa só um passar, mas um terceiro pode ter criado uma trava nova no meio). Quem protege o disco é o piso de PARADA, não a trava. Se o `fork` da vigia falhar (máquina sem processos), o push roda sem ela.
- A sonda longa `sh -c '…'` que o ENGINE renderiza no prompt do dog não passa pelo hold (só o `pool-probe.sh` passa; é ele que a doutrina manda usar desde a ga-witezg). O risco são as beads já roteadas ao dog (por qualquer caminho) enquanto ele usa a sonda longa.
- As sondas do wa-worker e do ps-worker respondem `[]` sem separar fórmula de história, porque hoje não há fórmula nelas: medido em 17/10, as 1125 beads roteadas ao wa-worker e as 51 do ps-worker são todas de tipo história sem marca de fórmula, e nenhuma ordem do `city.toml` aponta para esses pools. Se um dia houver, aquelas duas sondas passam a usar `DISK_HOLD_NEW_STORIES_JQ`. Pelo mesmo motivo a classe de CONSERTO fica segurada ali com < 5 GB (sem exceção); o que existe é o aviso ao Mayor descrito na peça 3, não uma isenção.
- No dog, a bead de REPARO criada por agente (tipo task, sem marca de fórmula) também é segurada com < 5 GB: é trabalho novo. Quem precisar dela rodando com o disco baixo avisa o Mayor.
- O compactador do jsonl-archive (`jsonl-archive-compact.sh`) NÃO passa pelo `heavy-guard.sh`: é ele quem devolve disco, com regras próprias. O passo dele que mais lembra o incidente de 17/10 (um `git repack` com o disco baixo) é o passe do rabo no disco apertado (ga-ft1iv6): só começa se os packs que leva cabem, inteiros, acima do piso dele (`JAC_TAIL_TIGHT_FLOOR_GB`, padrão = o `DOLT_DISK_FLOOR_CRITICAL_GB` do guard, 3 GiB, 1 GiB abaixo dos 4 GiB em que a classe CRÍTICA começa; nunca abaixo de 1 GiB), roda com `pack.*` magros sob um vigia de disco e swap que o para antes do piso, e espera 2 h depois de uma parada. Ele pode, por alguns minutos, levar o disco de cima dos 4 GiB para a classe CRÍTICA: é a exceção deliberada, sem ela o impasse não sai. Sem ele, com o mini em 3-4,7 GB livres, nenhuma consolidação rodava e cada backup deixava um pack-semente de ~200 MB. Desligar: `JAC_TAIL_TIGHT=0` no ambiente do order (volta ao `skipped-low-disk`). Detalhe e medição: cabeçalho do script, "2a-tight".
- A leitura é do volume do swap/Dolt (`/private/var/vm`, senão `/`). Um disco externo/montagem separada não conta.
