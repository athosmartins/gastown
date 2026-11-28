## Contents
- O que existe hoje
- Como ver o que as faixas fazem
- O que cada faixa entrega (mode: live)
- Instalar o tick do disco
- Onde fica cada coisa
- O que NÃO faz ainda

# Alarmes por faixa estatística (alarm-bands) · runbook

Bead-mãe ga-4mzkfj9 (Athos, 28/11). Fatia 1 (ga-qhs5frj): núcleo estatístico. Fatia 2a (ga-wagjc6w): leitor do `bands.yaml`, episódio, estado, silêncio 22-07 h e `tick` do disco em sombra. **Fatia 2b (ga-75uvbfa, este runbook)**: a entrega (diagnóstico de só leitura, mail, bead) e `mode: live`. Fatia 2c (ga-7a3sf7u): dispensar alarme e relatório antes/depois. Fatia 3 (ga-85l5sa9): piloto no `gate-throughput-meter`.

## O que existe hoje
Limite fixo fala do **nível** («gate abaixo de 8,0/h»); a faixa fala de **mudança**: cada métrica é julgada contra o comportamento recente dela mesma. Hoje uma métrica anda sozinha, `disk_free_delta` (queda do espaço livre do volume do Dolt e do swap, MiB/h), em `mode: shadow`: o `tick` mede, julga, abre o episódio e **conta** o que uma rodada ao vivo teria entregue (`would_deliver` no ledger), sem mandar nada. Os pisos fixos do disco seguem agindo, intocados.
- Cada faixa age **uma vez por episódio**. Episódio abre na 1ª faixa ≥ 1σ e fecha depois de `recover_after_h` em faixa 0; faixa maior no mesmo episódio sobe (`escalate`), repetição só é contada. 1σ só vai ao log; 2σ e 3σ ficam **devidas** (`actions` por faixa).
- Silêncio `22-07` (BRT): métrica com `evaluate_in_silence: false` nem é julgada; com `true` (o disco) é julgada e só a entrega espera a manhã.
- Série curta, constante, velha, vazia ou corrompida **nunca** vira «faixa 0»: sai `aprendendo`, `sem ponto novo`, `sem série` ou `WARN` (rc 1 quando é problema).

## Como ver o que as faixas fazem
Da raiz da cidade, `python3 -I packs/town-deltas/assets/scripts/bands.py <cmd>`:
- `check`: valida o `bands.yaml`. **rc 2 = inválido**: as faixas ficam inertes e a linha diz qual. Nunca «sem alarme».
- `tick --dry-run`: julga o que já foi medido; não mede, não grava, não entrega. `tick`: uma rodada de verdade (o launchd faz a cada 10 min); linhas `FAIXA`, `SILÊNCIO`, `DIAGNÓSTICO`, `BEAD`, `MAIL`, `WARN`. rc 0 feito · 1 problema que não se ignora · 2 config inválida · 64 uso · 70 bug.
- Sombra: `grep would_deliver .gc/state/bands/ledger.jsonl`. Live: `grep -E '"ev": "(deliver|bead_open|diagnose_start)"' .gc/state/bands/ledger.jsonl`.

## O que cada faixa entrega (mode: live)
Pôr uma métrica ao vivo é um commit no `bands.yaml` (`mode: live`) e `bands.py check`. Faixa 2σ: diagnóstico + mail ao Mayor. Faixa 3σ: diagnóstico + **bead** + mail (por último, porque cita os dois).
- **Diagnóstico**: um `claude -p` sem **nenhuma** ferramenta (`--tools ""`), sem identidade (`GC_*`/`BD_*` fora do ambiente), sem memória e sem CLAUDE.md; o motor lê os trechos de log que a métrica pede (`Driver.excerpts`) e os entrega como dado em `<conteudo_externo>`. Teto `max_per_day` por dia e `max_usd` por chamada; o gasto entra no ledger **antes** (sem gravar, não gasta). `BANDS_DIAGNOSE=0` desliga na hora.
- **Bead**: nasce **estacionada para o Mayor** (`pilot:no-auto-dispatch`, dono `gastown.mayor`) com o rótulo `bands:ep:<episódio>`; o motor procura esse rótulo antes de criar, então uma resposta perdida ou uma nova tentativa acha a bead em vez de abrir outra. Com `exec:auto` ou `story:approved` em `bead.labels` ela é despachada sozinha, e aí o texto do modelo **não** vai nela.
- **Mail** ao Mayor: sem carimbo se falhar, a próxima rodada tenta de novo; diagnóstico ou bead que falham não seguram o aviso. Mail e bead que falham são refeitos na rodada seguinte (a bead até `bead.max_attempts`); o diagnóstico que falha só é refeito enquanto a faixa continuar devida por causa de um deles (até `diagnose.max_attempts`); o que deu certo não repete. Ledger ilegível = nenhum gasto novo, mas o aviso sai.

## Instalar o tick do disco
Decisão do Mayor (nada se carrega sozinho). Antes, `check` e `tick --dry-run`. Instalar: `cp packs/town-deltas/assets/bands-tick.plist ~/Library/LaunchAgents/com.gascity.bands-tick.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.bands-tick.plist`. Conferir: `.gc/state/bands/series/disk_free_delta.jsonl` ganha uma linha a cada ~10 min. O volume lido é `/private/var/vm`, **sem queda para outro volume**; se a leitura falha, a rodada diz `WARN` e **não grava zero**. A base precisa de ~2,5 dias de leitura: até lá sai `aprendendo`.

## Onde fica cada coisa
- `packs/town-deltas/assets/scripts/bands.yaml`: o que se julga e como (versionado). Leitor estrito de subconjunto de YAML; o resto é recusado com a linha. Os blocos `diagnose` e `bead` valem para todas as métricas.
- `.gc/state/bands/<métrica>.json`: episódio aberto (diagnóstico, bead, avisos entregues) e histórico; corrompido vai para `.corrupt-<epoch>`; ilegível ou não gravável = **nenhuma ação** (rc 1). `ledger.jsonl` ao lado: trilha de auditoria. `series/<métrica>.jsonl`: leituras do coletor.
- Selftests (`python3 -I <arquivo>`): `bands.selftest.py` (núcleo), `bands_engine.selftest.py` (leitor, episódio, estado, sombra, coletor), `bands_delivery.selftest.py` (entrega e adaptadores, com `claude`, `bd` e `gc` falsos).

## O que NÃO faz ainda
- **Sem dispensar alarme, `status` nem relatório antes/depois**: fatia 2c (ga-7a3sf7u). Até lá o σ não se alarga sozinho.
- **Não migra vigia nenhum**: o `gate-throughput-meter` segue com a regra fixa até a fatia 3, e a única métrica do `bands.yaml` segue em sombra. Nada foi carregado: **a 1ª rodada ao vivo, com o claude de verdade, é o teste de campo**.
