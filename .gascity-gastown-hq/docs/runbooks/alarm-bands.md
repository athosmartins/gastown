## Contents
- O que existe hoje (fatia 2a)
- Como ver o que as faixas fazem
- Instalar o tick do disco
- Onde fica cada coisa
- O que NÃO faz ainda

# Alarmes por faixa estatística (alarm-bands) · runbook

Bead-mãe ga-4mzkfj9 (melhoria escolhida pelo Athos em 28/11). Fatia 1 (ga-qhs5frj): o núcleo estatístico (`bands.py`: baseline, regras de Western Electric, faixa 0-3σ). **Fatia 2a (ga-wagjc6w, este runbook)**: a leitura do `bands.yaml`, o estado e o episódio de cada alarme, o silêncio 22-07 h e o `tick` do disco, tudo **em sombra**. Fatia 2b (ga-75uvbfa): a entrega (diagnóstico de só leitura, mail, bead) e o contador antes/depois. Fatia 3 (ga-85l5sa9): o piloto no `gate-throughput-meter`.

## O que existe hoje (fatia 2a)
Um vigia com limite fixo fala do **nível** («gate abaixo de 8,0/h»); a faixa fala de **mudança**: cada métrica é julgada contra o comportamento recente dela mesma. Hoje uma métrica anda sozinha, `disk_free_delta` (queda do espaço livre do volume do Dolt e do swap, MiB/h), com `mode: shadow`: o `tick` mede, julga, abre o episódio e **conta** o que uma rodada ao vivo teria entregue (`would_deliver` no ledger), sem mandar nada. Os pisos fixos do disco (`dolt-disk-floor-guard` e cia.) seguem agindo, intocados.
- Cada faixa age **uma vez por episódio**. Episódio abre na 1ª faixa ≥ 1σ e fecha depois de `recover_after_h` em faixa 0; faixa maior no mesmo episódio sobe (`escalate`), repetição só é contada.
- 1σ só vai ao log; 2σ e 3σ ficam **devidas** (`actions` por faixa no `bands.yaml`) e, em sombra, são carimbadas como `shadow` e contadas.
- Silêncio `22-07` (hora local, UTC-3 fixo): métrica com `evaluate_in_silence: false` nem é julgada; com `true` (o disco) é julgada e só a contagem da entrega espera a manhã.
- Série curta, constante, velha (`fresh_for_h`), vazia ou corrompida **nunca** vira «faixa 0»: sai `aprendendo`, `sem ponto novo`, `sem série` ou `WARN: série corrompida` e o código de saída 1 quando é um problema.

## Como ver o que as faixas fazem
Da raiz da cidade (`$GC_CITY_PATH`):
- `python3 -I packs/town-deltas/assets/scripts/bands.py check`: valida o `bands.yaml`. **rc 2 = inválido**: as faixas ficam inertes e a linha diz qual (chave desconhecida, valor fora da faixa, `mode: live`...). Nunca «sem alarme».
- `python3 -I packs/town-deltas/assets/scripts/bands.py tick --dry-run`: julga o que já foi medido; não mede, não grava.
- `python3 -I packs/town-deltas/assets/scripts/bands.py tick`: uma rodada de verdade (o launchd faz isto a cada 10 min). Linhas `FAIXA ok|1σ|aprendendo|sem ponto novo`, `SILÊNCIO`, `WARN`. rc 0 feito · 1 um problema que não se pode ignorar (leitura do disco falhou, série ou estado ilegível, estado que não grava) · 2 config inválida · 64 uso · 70 bug do script.
- O que as faixas teriam enviado: `grep would_deliver .gc/state/bands/ledger.jsonl`. O relatório antes/depois com a contagem do log antigo chega na 2b.

## Instalar o tick do disco
Decisão do Mayor (nada se carrega sozinho). Antes, `bands.py check` e `tick --dry-run`. Instalar: `cp packs/town-deltas/assets/bands-tick.plist ~/Library/LaunchAgents/com.gascity.bands-tick.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.bands-tick.plist`. Conferir: `.gc/state/bands/series/disk_free_delta.jsonl` ganha uma linha a cada ~10 min. O volume lido é `/private/var/vm` (o Data do macOS, o mesmo de `disk-headroom-lib.sh`): **sem queda para outro volume** (`/` é o volume selado e conta outra história); se a leitura falha, a rodada diz `WARN` e **não grava zero**. A base precisa de ~2,5 dias de leitura (`min_baseline_points: 48` mais os 8 pontos em teste, um por hora): até lá sai `aprendendo`.

## Onde fica cada coisa
- `packs/town-deltas/assets/scripts/bands.yaml`: o que se julga e como (versionado: mudar uma faixa é um commit). Leitor estrito de subconjunto de YAML (o `/usr/bin/python3` do mini não tem PyYAML): mapas com 2 espaços, escalares, listas em linha; o resto é recusado com a linha.
- `.gc/state/bands/<métrica>.json`: o episódio aberto e o histórico. Estado corrompido é guardado ao lado como `.corrupt-<epoch>` e a métrica recomeça; estado que não se consegue ler ou gravar = **nenhuma ação** (rc 1).
- `.gc/state/bands/ledger.jsonl`: trilha de auditoria (`open`, `escalate`, `recover`, `would_deliver`). `.gc/state/bands/series/<métrica>.jsonl`: as leituras do coletor (guarda `baseline_days`+3 dias).
- Selftests: `python3 -I bands.selftest.py` (núcleo) e `python3 -I bands_engine.selftest.py` (leitor, silêncio, episódio, estado, sombra, coletor).

## O que NÃO faz ainda
- **Não entrega nada**: sem diagnóstico, mail ou bead; `mode: live` é recusado pelo leitor até a 2b (ga-75uvbfa) trazer a entrega. Sem comando de dispensar alarme nem de estado/relatório.
- **Não migra vigia nenhum**: o `gate-throughput-meter` segue com a regra fixa até a fatia 3.
- Testado em diretório temporário e com leitura injetada, e a leitura do volume real foi conferida à mão; **a 1ª rodada do launchd é o teste de campo** (nada foi carregado).
