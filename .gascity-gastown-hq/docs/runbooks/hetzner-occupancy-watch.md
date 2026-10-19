# Vigia de ocupação do nó Hetzner (hetzner-occupancy-watch) · runbook

## Contents

• O que é · Como ler o número · Instalar · Provar · Medido, inferido, não testado

Bead ga-2hd02v.1.12 (filha da ga-2hd02v.1). Regra do Athos (14/10): "Hetzner pago trabalha sempre". Esta é a **fatia 1: MEDIR**. O aviso ao Mayor (nó ocioso com fila aprovada) é a fatia seguinte, empilhada nesta. **Mergeado ≠ vivo: nada aqui está instalado.**

## O que é
`scripts/hetzner-occupancy-watch.py`, a cada 900 s pelo launchd do mini (`com.gascity.hetzner-occupancy-watch.plist`). Duas leituras, cada uma com 3 estados (leu / não consegui ler / vale X):
- **sessões:** `gc --city <cidade> session list --json`; contam as com `-remote-` no nome e `state` active/awake (as `-remote-mbp-` são de outro host; host novo no provider entra em `HETZNER_OCC_OTHER_HOSTS`, padrão `mbp`, senão a sessão dele conta como ocupação do Hetzner e cala o aviso da fatia seguinte; o vocabulário de estados é o do `bead_state.py`, travado no selftest).
- **CPU:** `ssh hetzner-teste` lê o `/proc/stat`; núcleos ocupados na janela desde a leitura anterior (user+nice+system+irq+softirq; idle, iowait e steal não contam). Régua de 0,5 núcleo (`HETZNER_OCC_BUSY_CORES`), não uma %: o nó tem 16 vCPU e 10 % deixaria um teste de 1 núcleo contar como ocioso.

Estado: **ocupado** = sessão remota ativa OU CPU ≥ régua (uma prova basta) · **ocioso** = as duas lidas e as duas dizem ocioso · **desconhecido** = o resto (a 1ª leitura só semeia o baseline de CPU). Leitura que falha **nunca** vira ocioso nem ocupado.

## Como ler o número
Em `<cidade>/.gc/`: `hetzner-occupancy-daily.json` (por dia local: `ocupado`/`ocioso`/`desconhecido`/`leituras` e `ocupacao_pct = ocupado/(ocupado+ocioso)`, `null` quando nenhuma leitura decidiu: falta de leitura nunca vira 0 %) · `hetzner-occupancy.jsonl` (uma leitura por rodada) · `hetzner-occupancy.state.json` (baseline de CPU) · `hetzner-occupancy.lock`. Arquivo corrompido não some: a cópia fica em `<arquivo>.corrupt-<epoch>` e o stderr avisa. A tela do painel fica fora desta fatia; o painel lê o daily.

## Instalar (Mayor, depois do merge)
```bash
python3 scripts/hetzner-occupancy-watch.py --dry-run --print        # 1 leitura de verdade, não grava nada
launchctl bootout gui/$(id -u)/com.gascity.hetzner-occupancy-watch 2>/dev/null
cp scripts/com.gascity.hetzner-occupancy-watch.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.hetzner-occupancy-watch.plist
launchctl print gui/$(id -u)/com.gascity.hetzner-occupancy-watch | grep -E 'state|runs|last exit'
```
Registrar na mesma mudança (senão acende CRITICAL, ou o job morre sem ninguém ver): linha `isento` em `scripts/wait-for-dolt.policy.tsv` (sem o Dolt a leitura de sessões vira "desconhecido" e a de CPU segue valendo; o wrapper só adiaria a medição) e o job no `daemon-presence-watchdog.sh` (nome em `DPW_CRITICAL` e `com.gascity.hetzner-occupancy-watch|$HQ/.gc/logs/hetzner-occupancy-watch.out|2700` no mapa de batimento: o `.out` ganha uma linha por rodada). A 1ª rodada só semeia o baseline; a CPU passa a ser lida na 2ª, 15 min depois. Desligar: `launchctl bootout gui/$(id -u)/com.gascity.hetzner-occupancy-watch`.

## Provar
`bash scripts/hetzner-occupancy-watch.selftest.sh` (hermético: gc e ssh são stubs). Grupos `cfg sess cpu estado saida` e o controle negativo: cada mutante (um trecho do script trocado) TEM de reprovar o grupo que o pega. Duração: ~80 s no Linux; no mini, sob carga, ~7 min (medido pelo gate em 19/10). `HOCC_NO_MUTANTS=1` pula o controle negativo: 183 dos 236 casos, ~20 s no Linux.

## Medido, inferido, não testado
**Medido (19/10, no nó):** 16 vCPU, `/proc/stat` com 10 campos, 5 processos python de teste a ~100 % de 1 núcleo e 1 sessão claude a ~0,1 núcleo (daí a régua em núcleos). **Medido (hermético, Linux, bash 5.2 e Python 3.12):** selftest 236/236 casos ok em ~80 s, 52 mutantes reprovados, nenhum sobrevive; o script compila na gramática do Python 3.9 do mini. **Reproduzido no Linux com um `python3` de mentira que grava bytecode no HOME como o do macOS (CLT 3.9):** sem o conserto 232/234, as 2 falhas que o gate viu no mini (HOME não vazio e o controle de identidade dos mutantes); com `PYTHONDONTWRITEBYTECODE=1` no `W()`, 234/234, e 236/236 com os 2 controles novos (o python de mentira suja o HOME; a variável chega ao processo).
**Inferido:** `ssh hetzner-teste` sob o launchd acha o alias no `~/.ssh/config` pelo `HOME` do plist e usa `BatchMode` (nunca espera senha); o formato do `gc session list --json` é o que o `worktree-reaper` e o gate já leem; o pior caso de uma rodada, pelos timeouts, é 60 s do gc + 30 s do ssh + 5 s de espera após matar cada um (≈ 100 s), bem abaixo dos 900 s do intervalo, e o lock de instância única cobre o resto. **NÃO testado:** uma rodada pelo launchd de verdade (só depois da instalação), uma sessão remota ativa real na lista, e o selftest CONSERTADO no mini (bash 3.2, Python 3.9.6): o gate o rodou antes do conserto, 232 dos 234 casos passaram e as 2 falhas eram o bytecode no HOME (o `--dry-run --print` do passo de instalação é a 1ª rodada de verdade lá).
