# Teto de RAM do mini: o que ligar, como conferir, como desligar (ga-1p1i5jr.14) · runbook

## Contents

• O que entrega · Ligar o teto do Pilot (sombra primeiro) · Afinar e desligar · O guarda de passo (`--ram-mb`) · O que NÃO cobre · Prova e o que só o mini prova

## O que entrega

19/11 o mini passou a criar swapfiles de 1 GB em `/System/Volumes/VM` (o macOS só os devolve no reboot; o disco caía ~1 GB/h): um build LiDAR de 2,1 GB rodado à mão e, depois, a soma de 16 sessões Claude + Dolt + Chrome em 16 GB.
`ps` RSS e `vm.swapusage` não mostram a memória comprimida. Cinco peças, todas lendo a mesma coisa — a RAM livre que o kernel diz ter (`memory_pressure` × `hw.memsize`, `packs/town-deltas/assets/scripts/ram-headroom-lib.sh`):

| Peça | O que faz |
|---|---|
| `scripts/heavy-guard.sh --ram-mb N` | passo python/node/duckdb (ou com `--ram-mb`) volta com **rc 75 "rode no nó Hetzner"** se declara ≥ 1024 MB ou se a RAM livre < 2048 MB + N; rc 76 se não leu a RAM |
| Pilot, `PILOT_RAM_FLOOR_ENABLED` | com a RAM livre < 2048 MB o mini não abre sessão nova: passada só-nó (`PILOT_NODE_FIRST=on`) ou pausa da varredura |
| degrau de swap (`disk-recovery-swap-cut.sh`) | corta a sessão ociosa de maior **pegada** (`top` MEM, que já inclui o comprimido), não de maior RSS; o log diz a base (`ordem do corte por MEM` ou `RSS`) |
| foto de disco (`dolt-disk-floor-guard.sh`) | registra nº, tamanho e mtime dos swapfiles e os 10 maiores MEM/CMPRS (`SWAPFILES`/`TOPMEM` em `disk-growth-<ts>.txt`, e no texto do relatório) |
| doutrina (`town-deltas.template.md`, `td:ram-heavy-hetzner`) | build/backfill > 1 GB roda no Hetzner, pelo guarda |

## Ligar o teto do Pilot (sombra primeiro)

Nasce **desligado** (como `PILOT_NODE_FIRST`): mergeado ≠ vivo. O plist do repo traz `PILOT_RAM_FLOOR_ENABLED` = `shadow`. Ligar é do Mayor, e reversível.

1. `~/Library/LaunchAgents/com.gascity.pilot.plist`, em `EnvironmentVariables`: `PILOT_RAM_FLOOR_ENABLED` = `shadow`; `launchctl bootout` + `bootstrap` (o Pilot lê o ambiente na partida).
2. Na varredura seguinte o log do Pilot traz `RAM floor (sombra): <ok|low|unknown> ram_free=NNNNMB floor=2048MB`, **toda varredura** (inclusive `ok`). Compare com a mão: `sysctl -n hw.memsize` e `memory_pressure | tail -1` (a linha `System-wide memory free percentage: N%`): `ram_free` = N% × memsize. Se bater, siga. Se der `unknown`, o formato real do macOS não é o que o código lê: avise antes de ligar.
3. Trocar para `1`, mesmo `bootout`/`bootstrap`. Com RAM baixa o log diz `RAM floor: passada só-nó` (a pausa gravada é `ram-floor`) ou, sem o nó primeiro, `paused: memory floor`.

O piso inicial é uma estimativa sem dado do mini. Depois de ~24 h em `shadow`, veja quantas varreduras teriam agido: `grep -o 'RAM floor (sombra): [a-z]*' "$GC_CITY_PATH/.gc/logs/pilot-dispatcher.log" | sort | uniq -c` (`low` = a varredura teria ido só-nó).

## Afinar e desligar

`RAM_NEW_WORK_MIN_MB` (padrão 2048) e `RAM_JOB_MAX_MB` (padrão 1024), no plist do Pilot e no ambiente de quem chama o guarda; valor que não é inteiro >= 1 de até 9 dígitos = o padrão. Para decidir: `free_pct` em `.gc/ram-owner-samples.jsonl` nos horários em que apareceu swapfile novo (mtime em `SWAPFILE` da foto); piso alto manda tudo ao nó, baixo não segura nada. Desligar: tire a chave do plist (ou `0`) e `bootout`/`bootstrap`; valor desconhecido = desligado. `RAM_HEADROOM_ENABLED=0` desliga a lib inteira (só teste; vira aviso).

## O guarda de passo (`--ram-mb`)

`"$GC_CITY_PATH/scripts/heavy-guard.sh" --what "<job>" --ram-mb <MB> -- <comando>`. Um python/node/duckdb sem `--ram-mb` também entra (só a RAM livre decide; selftest, git, Go e push nunca). `--ram-mb 0` = "não é pesado". Só vale no macOS: no nó Linux não há o que recusar. `uv run`, `npm run build` e um script que chama python por dentro não são vistos: marque com `--ram-mb`.

## O que NÃO cobre

- A RAM é lida UMA vez por varredura (10 min): uma varredura que começa logo acima do piso ainda abre as sessões dela. Sessão que já roda não é tocada (quem corta é o degrau de swap, só pool/reviewer ocioso).
- O reconciliador (`approved-state-reconciler.py`) conta a passada só-nó por RAM como varredura normal (como já contava a do yield por memória, ga-2hd02v.13): o histórico de pausa não a mostra.
- O D3 (`disk-recovery-d3-ram-daemons.sh`, `mem_of`) SOMA MEM + CMPRS; o MEM já inclui o comprimido, então ele conta o comprimido em dobro (fora desta bead).

## Prova e o que só o mini prova

Selftests: `ram-headroom-lib`, `heavy-guard-ram`, `pilot-dispatcher.ram-floor`, `ram-owner-sampler`, `disk-recovery-swap-cut` (seção "a pegada") e `dolt-disk-floor-guard` (`SWAPFILES`/`TOPMEM`), com fixtures na forma que o código já lê em produção.
**Não provado do nó:** `memory_pressure`, `hw.memsize`, `top -l 1 -stats pid,mem,cmprs` e `stat -f '%z %m'` rodando de verdade no macOS do mini, e o aceite da bead (24 h sem swapfile novo criado por job de lote). Primeira conferência: o passo 2 acima.
