# Vigia de ocupação do nó Hetzner (hetzner-occupancy-watch) · runbook

## Contents

• O que é · Como ler o número · Avisar o Mayor · Instalar · Provar · Medido, inferido, não testado

Bead ga-2hd02v.1.12 (filha da ga-2hd02v.1). Regra do Athos (14/10): "Hetzner pago trabalha sempre". Cobre a **fatia 1 (MEDIR)** e a **fatia 2 (AVISAR o Mayor: nó ocioso com fila aprovada)**, empilhada na 1: a 2 só entra no gate depois da 1 mergeada. **Mergeado ≠ vivo: nada aqui está instalado, e o aviso nasce DESLIGADO.**

## O que é
`scripts/hetzner-occupancy-watch.py`, a cada 900 s pelo launchd do mini (`com.gascity.hetzner-occupancy-watch.plist`). Três leituras (a da fila é da fatia 2), cada uma com 3 estados (leu / não consegui ler / vale X):
- **sessões:** `gc --city <cidade> session list --json`; contam as com `-remote-` no nome e `state` active/awake (as `-remote-mbp-` são de outro host; o vocabulário de estados é o do `bead_state.py`, travado no selftest).
- **CPU:** `ssh hetzner-teste` lê o `/proc/stat`; núcleos ocupados na janela desde a leitura anterior (user+nice+system+irq+softirq; idle, iowait e steal não contam). Régua de 0,5 núcleo (`HETZNER_OCC_BUSY_CORES`), não uma %: o nó tem 16 vCPU e 10 % deixaria um teste de 1 núcleo contar como ocioso.
- **fila:** `~/.gc/pilot-dispatchable.json` (o Pilot o grava a cada rodada); conta só a loja `hq` (`HETZNER_OCC_STORES`), com `generated_at` e `ttl_seconds` conferidos: ausente, velho, no futuro ou ilegível é "não consegui ler", nunca "fila vazia".

Estado: **ocupado** = sessão remota ativa OU CPU ≥ régua (uma prova basta) · **ocioso** = as duas lidas e as duas dizem ocioso · **desconhecido** = o resto (a 1ª leitura só semeia o baseline de CPU). Leitura que falha **nunca** vira ocioso nem ocupado.

## Como ler o número
Em `<cidade>/.gc/`: `hetzner-occupancy-daily.json` (por dia local: `ocupado`/`ocioso`/`desconhecido`/`leituras` e `ocupacao_pct = ocupado/(ocupado+ocioso)`, `null` quando nenhuma leitura decidiu: falta de leitura nunca vira 0 %) · `hetzner-occupancy.jsonl` (uma leitura por rodada) · `hetzner-occupancy.state.json` (baseline de CPU) · `hetzner-occupancy.lock`. Arquivo corrompido não some: a cópia fica em `<arquivo>.corrupt-<epoch>` e o stderr avisa. A tela do painel fica fora desta fatia; o painel lê o daily.

## Avisar o Mayor (fatia 2)
Só avisa: não atribui nem despacha nada. Por `gc mail send mayor` (não nudge: o nudge ao Mayor trava com a sessão anexada, ga-eldeu). **Nasce DESLIGADO:** só sai mail com `<cidade>/.gc/hetzner-occupancy-alarm.on` presente (e sem `HETZNER_OCC_ALARM=0`); sem a chave é só-medir: mede, grava e a leitura mostra `alarme.ocioso: desligado`. Cada leitura do JSONL ganha `fila`, `foco`, `ociosas_seguidas`, `cegas_seguidas` e `alarme`.
- **ocioso:** estado ocioso por ≥ 30 min (3 leituras seguidas, com 2 min de folga para o jitter do launchd) COM fila > 0 → 1 mail; cooldown de 3 h; o mail que falha não gasta o cooldown. A fila é a do Pilot ANTES dos vetos de pool e do freio de top-up: o número é um teto, e o mail diz isso.
- **cego:** nenhuma leitura decidiu há ≥ 1 h (sessões, CPU ou fila ilegíveis; a 1ª leitura, que só semeia o baseline, não conta) → 1 mail; cooldown de 6 h. Ocioso com fila ilegível também é cego: sem fila não há como dizer "ocioso COM fila".
- **foco do gate ligado** (`gate-focus.state`; a regra de 3 estados é a da `gate-focus-lib.sh`, e o selftest compara as duas): só conserto é despachado, então o aviso de ocioso se cala (`alarme.ocioso: foco`). Foco ilegível é tratado como desligado, igual à lib.
- **vigia que cai ou não grava** (exit 1 ou 3): NÃO avisa ninguém. O traceback fica no `.err` e quem vê um vigia parado é o daemon-presence-watchdog (passo de instalação abaixo); um aviso próprio tocaria o celular do Athos mesmo com o aviso desligado.
- Ajustes por env (opcionais): `HETZNER_OCC_IDLE_AFTER_S` (1800), `HETZNER_OCC_BLIND_AFTER_S` (3600), `HETZNER_OCC_IDLE_COOLDOWN_S` (10800), `HETZNER_OCC_BLIND_COOLDOWN_S` (21600), `HETZNER_OCC_STORES` (hq), `HETZNER_OCC_OTHER_HOSTS` (mbp), `GATE_FOCUS_STALE_S` (7200).

## Instalar (Mayor, depois do merge)
```bash
python3 scripts/hetzner-occupancy-watch.py --dry-run --print        # 1 leitura de verdade, não grava nada
launchctl bootout gui/$(id -u)/com.gascity.hetzner-occupancy-watch 2>/dev/null
cp scripts/com.gascity.hetzner-occupancy-watch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.hetzner-occupancy-watch.plist
launchctl print gui/$(id -u)/com.gascity.hetzner-occupancy-watch | grep -E 'state|runs|last exit'
```
Registrar na mesma mudança (senão acende CRITICAL, ou o job morre sem ninguém ver): linha `isento` em `scripts/wait-for-dolt.policy.tsv` (sem o Dolt a leitura de sessões vira "desconhecido" e a de CPU segue valendo; o wrapper só adiaria a medição) e o job no `daemon-presence-watchdog.sh` (nome em `DPW_CRITICAL` e `com.gascity.hetzner-occupancy-watch|$HQ/.gc/logs/hetzner-occupancy-watch.out|2700` no mapa de batimento: o `.out` ganha uma linha por rodada). A 1ª rodada só semeia o baseline; a CPU passa a ser lida na 2ª, 15 min depois. Desligar: `launchctl bootout gui/$(id -u)/com.gascity.hetzner-occupancy-watch`.

**Ligar o aviso** (passo à parte, só depois do flip da ga-2hd02v.1.6 provado: antes dele o nó está ocioso por desenho e o Mayor receberia mail à toa): confira com `python3 scripts/hetzner-occupancy-watch.py --dry-run --print` (`alarme.ocioso` diz `nao`, `cooldown`, `foco`, `desligado` ou `enviaria`, e nada é enviado), depois `touch <cidade>/.gc/hetzner-occupancy-alarm.on`. Voltar a só-medir: apague a chave. O número por dia acumula com ou sem a chave.

## Provar
`bash scripts/hetzner-occupancy-watch.selftest.sh` (hermético: gc e ssh são stubs; ~1,5 min). Grupos `cfg sess cpu fila estado alarme saida` e o controle negativo: cada mutante (um trecho do script trocado) TEM de reprovar o grupo que o pega.

## Medido, inferido, não testado
**Medido (19/10, no nó):** 16 vCPU, `/proc/stat` com 10 campos, 5 processos python de teste a ~100 % de 1 núcleo e 1 sessão claude a ~0,1 núcleo (daí a régua em núcleos). **Medido (hermético, Linux, bash 5.2 e Python 3.12):** selftest 366/366 ok em 98 s (`HOCC_JOBS=6`): 288 casos, 77 mutantes reprovados (nenhum sobrevive) e o controle de identidade; o script compila na gramática do Python 3.9 do mini.
**Inferido:** `ssh hetzner-teste` sob o launchd acha o alias no `~/.ssh/config` pelo `HOME` do plist e usa `BatchMode` (nunca espera senha); o formato do `gc session list --json` é o que o `worktree-reaper` e o gate já leem; o `pilot-dispatchable.json` é o que o `pilot-dispatcher.sh` grava (campos conferidos no código do Pilot, não num arquivo vivo do mini); a chamada `gc --city <c> mail send mayor -s … -m …` é a do `city-health-sentinel.sh`; o pior caso de uma rodada, pelos timeouts, é 60 s do gc + 30 s do ssh + 45 s do mail (só na rodada que avisa, e por construção uma rodada manda no máximo 1: ocioso exige leitura que decidiu, cego exige que não) + 5 s de espera após matar cada um (≈ 150 s), bem abaixo dos 900 s do intervalo, e o lock de instância única cobre o resto. **NÃO testado:** uma rodada pelo launchd de verdade (só depois da instalação), uma sessão remota ativa real na lista, um `gc mail send mayor` de verdade a partir do vigia (o selftest usa um stub que grava os argumentos), o aviso com a chave `.on` posta contra um `pilot-dispatchable.json` vivo, e o selftest no bash 3.2 e no Python 3.9 do mini (o `--dry-run --print` do passo de instalação é a 1ª rodada de verdade lá).
