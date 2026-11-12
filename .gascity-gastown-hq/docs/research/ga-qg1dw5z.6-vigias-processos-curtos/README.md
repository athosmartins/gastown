# ga-qg1dw5z.6 · quem cria processo curto no mini, e o primeiro corte

## Contents

Estado do mundo · O que a lista de "aparições" não diz · Corte entregue: `compute_hash` do config-drift-watcher · Prova (no nó, antes/depois) · Quanto vale no mini (previsão, a confirmar) · Fila dos próximos cortes · Como medir no mini depois do deploy · Limites

## Estado do mundo

- O `config-drift-watcher.sh` (KeepAlive, tick de 3 s) iniciava **um `stat` por arquivo vigiado** e um `find` por pasta de skills, a cada tick. Medido no nó com `strace -f`: **1086 processos por tick para 1061 arquivos**, ~360 por segundo só dele. Agora são **13 por tick, não importa quantos arquivos** (por iteração do laço, `sleep` e `date` incluídos: 1119 → 21).
- O valor do hash é o mesmo byte a byte (19 árvores nos dois bash, mais o selftest novo com o laço antigo como oráculo). O vigia detecta o mesmo que detectava e o estado "não sei" (`hash-error`) não mudou.
- **Não medido:** spawns/s e load1 do mini antes/depois. Só o mini mede; os comandos estão no fim. Este slice não diz que a saturação acabou, diz que o maior criador de processo que o código mostra deixou de crescer com o número de arquivos.

## O que a lista de "aparições" não diz

- `spawn-origin.py` amostra o `ps` a cada 1 s e conta **aparições**: um `stat` de 2 ms aparece em ~0,2% das amostras, um `bd` de 3 s sob load 54 aparece em ~3. A lista da bead (config-drift-watcher 4,9%, janitors 3-4% cada) mede **tempo vivo**, não **criação**. Um vigia que cria mil processos de 2 ms por tick pesa pouco nela e muito no kernel (47% sys).
- Para ranquear criação: forks por ciclo ÷ intervalo (conta no código ou `strace -f -c -e trace=clone,clone3`), e para o total da máquina o contador de pid (`spawn-rate.sh`, nesta pasta). Validado no nó com um gerador conhecido: 6 pares janela-com-1000-processos × janela-ociosa, sobra média 956 (esperado ~1000); a criação ambiente do nó é ~50-130/s.

## Corte entregue: `compute_hash` do config-drift-watcher

`scripts/config-drift-watcher.sh`, função `compute_hash` (chamada a cada `POLL_INTERVAL`=3 s):

- antes: `find` por pasta (9+) → `sort` → `while read f; do stat -f '%N %m %z' "$f"; done` → `md5 -q`: um `stat` por arquivo;
- agora: um `find` com todas as pastas de árvore, um `find` para `scripts/` (o último do grupo, de propósito: o status dele é o do grupo sob `pipefail`, então um `scripts/` ilegível continua terminando em `hash-error`), `sort`, `tr '\n' '\0'`, **um** `xargs -0 stat -f '%N %m %z'` (com `|| true`: arquivo que sumiu entre o `find` e o `stat` perde a linha dele e não vira erro, como antes) e `md5 -q`.
- A cadência não mudou (3 s) e a detecção também não: o valor é persistido (`covered_hash`) e comparado após reinício, então preservá-lo byte a byte evita um reload espúrio a cada deploy. `config-drift-watcher-fork-cost.selftest.sh` guarda o laço antigo como oráculo e prova: A) saída idêntica e stderr vazio em 12 árvores (nomes com espaço/aspas/glob/`-`/unicode, os 5 tipos de pasta de crew, raízes ausentes, símbolos), B) os estados "não sei" (sem `scripts/` ou sem `md5` → `hash-error`; arquivo que sumiu → descartado, nada no stderr), C) detecção (alterar, criar, apagar em cada lugar vigiado; o que não é vigiado não mexe), D) o número de `stat`/`find` não cresce com os arquivos (controle: o laço antigo inicia um `stat` por arquivo). 49 asserções, verdes em bash 5.2 e 3.2.57; contra o vigia ANTIGO as 5 de D reprovam; 16 mutantes do código novo, 16 mortos.

## Prova (no nó, antes/depois)

Árvore: os 556 arquivos do HQ (494 `scripts/*.{sh,py}` + 47 `agents` + 15 `skills`) mais um WA de teste (12 crews × 40 arquivos de skill + 25 em `city-local`) = 1061 arquivos. `strace -f -c -e trace=clone,clone3` conta processos criados (o `stat`/`md5` do nó são GNU com emulação BSD, por isso a estrutura vale e o tempo absoluto não).

| | arquivos | processos por chamada de `compute_hash` | por iteração do laço (`sleep` + tick) |
|---|---|---|---|
| antes | 1061 | 1086 | 1119 |
| depois | 1061 | 13 | 21 |
| antes | 593 | 608 | — |
| depois | 593 | 12 | — |

Bash 3.2.57 de verdade (a do launchd) e bash 5.2: mesmos números e mesma saída. O selftest antigo do vigia (`config-drift-watcher-reload-policy.selftest.sh`, 379 asserções, `compute_hash` real nas seções F, H e I) dá o mesmo resultado no vigia antigo e no novo, nos dois bash (376 ok; as 3 que falham no nó são `chflags uchg`, do macOS).

## Quanto vale no mini (previsão, a confirmar)

- Processos por segundo do vigia ≈ N ÷ 3, com N = arquivos vigiados no mini: 556 do HQ rastreados no git (mais os não rastreados) e as skills de cada crew do WA (`whatsapp_automation/crew/*/.claude/skills`, que o nó não vê). N = 556 → ~185/s; N = 1061 → ~360/s. Contagem no mini, 1 s: `find <city>/skills <city>/.claude/skills <wa>/crew/*/.claude/skills <wa>/city-local/skills <city>/agents -type f | wc -l`, mais `find <city>/scripts -type f \( -name '*.sh' -o -name '*.py' \) | wc -l`.
- Os 246 spawns/s da bead vieram de amostras de 1 s: se foram criação real, o vigia era a maior parte deles; se foram aparições, a criação real era maior. O contador de pid decide.

## Fila dos próximos cortes

Custo por ciclo lido do código (contagem de pontos de chamada, não execução); "forks/s" é ordem de grandeza.

| origem | intervalo | o que cria por ciclo | forks/s | corte proposto e prova exigida (E12: vazio/falhou não vira "ok") |
|---|---|---|---|---|
| config-drift-watcher.sh | 3 s | era 1 `stat` por arquivo | era ~190-370, agora ~7 (laço inteiro) | **feito aqui** |
| wa-beads-config-guard.sh | 15 s | um `python3 -c 'import yaml'` por tick | ~0,07 interpretador | ler `stat` (mtime/tamanho) e só validar se mudou; o mesmo caso (config corrompida) tem de ser pego no tick seguinte à mudança. Baixo retorno em forks, alto em CPU por interpretador |
| town-root-reconciler.sh | 25 s | `git fetch` (com ssh) + ~6 `git` | ~0,7 | `git ls-remote`/comparar o ref antes do fetch; só vale com a prova de que divergência continua sendo vista |
| lifecycle-coherence-janitor.sh | 600 s | 16 pontos de chamada de `bd list` por store × ~6 stores, cada um com seu `jq` | ~0,4 processo/s, mas cada `bd list --json -n 0` varre o Dolt | um `bd list` por store e filtrar com `jq` por regra em vez de um por regra; a carga que sai é a do Dolt, não a de processo |
| merged-bead-janitor.sh | 900 s | por bead em voo: 6 `jq` só para ler campos do JSON que já tem, mais marcadores e git | ~1 | um `jq` por bead extraindo todos os campos de uma vez (~10 processos a menos por bead) |
| lifecycle-correctness-auditor.sh | 900 s | `git fetch` por rig e 3 sinais por bead (ancestral, patch-id, subject), segundo o comentário do lifecycle-coherence-janitor.sh | não lido | **não está no espelho do nó** (filtro de dados): só li as menções a ele; não li o script nem editei. Memoizar o veredito por (bead, tip do branch, tip da main) e só reavaliar se algum mudou; mesmo veredito em 2 ciclos seguidos como prova. Dono: dog do mini |
| dolt-disk-floor-guard.sh | 300 s | com o disco abaixo de 8 GB cada ciclo roda as alavancas de reclaim (`gc dolt cleanup`, scratchpad e transcrições de sessão morta) e a medição de uso por raiz | depende do disco | **não mexer na cadência**: é a última guarda contra disco cheio do Dolt. O custo é consequência do disco em WARN; tirar o disco do WARN resolve os dois |
| daemon-refresh.sh | por deploy (chamado pelo quality-gate-dispatcher) | descoberta de plists e grafo de imports por deploy | não medido | contar por execução com `strace` num deploy real; sem número não proponho corte |
| inbound_generator.py (WA) | por ciclo | chromium headless | não lido | outro repo (WA); fora deste slice |

O que sobra de "vigia que consulta a mesma coisa" (`gc session list`, `bd list` do mesmo store por vários jobs de 5-10 min) é um corte maior e de outro tipo: um instantâneo compartilhado, atualizado por um produtor, lido por quem tolera dado de ~60 s. Cada consumidor teria de declarar a idade máxima que tolera; fica como proposta, sem código.

## Como medir no mini depois do deploy

1. Mesma hora do dia do "antes" (a bead pede isso; o load do mini varia 39..65 de um dia para o outro): `sh spawn-rate.sh 30 10` (10 janelas de 30 s) e o `spawn-origin.py` (150 s, 1 s) do dog-1. O número que decide é processos/s do contador de pid; o `spawn-origin.py` diz quem.
2. Confirmar o vigia novo no ar: `startup` em `.gc/state/config-drift-watcher.startup` depois do deploy (o delivery reinicia o vigia) e `Initial hash:` no `.gc/logs/config-drift-watcher.log`. O deploy muda `scripts/*.sh`, que é vigiado: um reload de arquivo logo após o reinício é esperado, uma vez.
3. Previsão a bater ou refutar: queda de ~N÷3 processos/s no contador de pid.

## Limites

- Medido no nó (Linux, `stat`/`md5sum` GNU com emulação BSD). Os comportamentos do `xargs -0`, do `tr '\n' '\0'` e do `stat -f` com vários operandos no macOS foram lidos nas páginas de manual, não executados; a prova de lá é o gate rodar no mini as seções F, H e I do selftest antigo e o selftest novo com as ferramentas reais.
- `compute_hash` continua dando o hash de "nada" se o `stat` falhar para todos os arquivos (como o laço antigo dava): não mudei esse comportamento de propósito, para manter o valor idêntico. É uma fraqueza antiga, não nova.
- Só o primeiro corte foi feito. A tabela é fila, não entrega.
