# worktree-reaper — árvores de worker do pool que não saem (ga-1p1i5jr.15)

## Contents

• O que aconteceu e o que mudou · Como conferir o aceite · O que cada motivo de `worker_tree_overdue` pede · Interruptores · O que não mudou e o que não foi provado

## O que aconteceu e o que mudou

Em 19/11 o Mayor achou 22 árvores `crew/worker-wa-<bead>` (4,1 GB, a mais velha de 16/09) no disco do mini, com a bead já fechada. O reaper (`scripts/worktree-reaper.sh`) já varre `<rig>/crew/worker-*`; quem as segurava, pelo que o código mostra e uma árvore sintética reproduz (não foi medido no mini), é a trava de dados ignorados (ga-xpoj67): um worker deixa `logs/`, `.gc/`, `.runtime/`, `CLAUDE.md` e afins, o `.gitignore` os esconde e a lista de lixo não os nomeava, então a árvore ficava com `kept_ignored_data` em toda passada. Ninguém lia esse evento.

Duas regras, só para árvore de pool (`<rig>/crew/worker-*` e `$GT/worker-*`):

- **Lixo de worker** (`WORKER_JUNK_RE`): `logs/`, `.logs/`, `.gc/`, `.runtime/`, `.gemini/`, `coverage/`, `htmlcov/`, `.vitest-cache/`, `.playwright-mcp/`, `.superpowers/`, `CLAUDE.md`, `CLAUDE.local.md`, `.crew-active-pid`, `.coverage*`, `*.log`, `*.db-shm`, `*.db-wal` não seguram mais a árvore. Qualquer outra árvore (traco-bim, `.gc-worktrees`, clone de crew) continua com a regra do ga-xpoj67 como era.
- **Liberação do resto**: uma árvore LIMPA, com todas as beads que a nomeiam fechadas há 12 h ou mais, solta o dado ignorado que sobrar se ele foi medido entrada por entrada e soma no máximo 64 MiB. O evento `ignored_data_released` diz o que foi (beads, `size_kb`, os 5 maiores caminhos) antes de a remoção ser tentada. Árvore suja, bead aberta ou desconhecida, dado maior que o teto ou não medido (um `du` que falhou, mais de 200 entradas) continua segurada.

Depois da passada, a **auditoria** (`audit_pool_workers`) lê o que sobrou: árvore de worker cujas beads estão todas fechadas há 24 h ou mais vira `worker_tree_overdue` no log e entra no relatório ao lado dele. Ela não remove nada.

## Como conferir o aceite

O reaper roda do `scripts/` da cidade: depois do merge, o próximo tick do launchd já usa o código novo (o script é relido a cada batida; não há o que recarregar). Passada normal a cada ~2 h, a cada 30 min sob pressão de disco.

```bash
LOG=$GC_CITY_PATH/.gc/logs/worktree-reaper.jsonl
jq -c 'select(.event=="sweep") | {ts,worker_audit,worker_trees,worker_overdue,worker_overdue_kb,worker_audit_unknown}' "$LOG" | tail -3
cat ${LOG%.jsonl}.workers.jsonl      # um objeto por árvore atrasada da última passada; vazio = nenhuma
```

Aceite atendido (`crew/worker-*` só com bead aberta ou fechada há menos de 24 h) = uma passada com `worker_audit` 1, `worker_overdue` 0 e `worker_audit_unknown` 0. `worker_audit` 0 ou `worker_audit_unknown` maior que 0 NÃO é "nenhuma atrasada": o primeiro é auditoria desligada, o segundo é "não deu para ler", e cada caso vem com um evento `worker_audit_unknown` (`repo`, `wt`, `why`) dizendo qual: o `bd` falhou ou estourou o prazo (o reaper desiste de perguntar naquele repo depois da primeira falha; o evento é o `bead_lookup_failed`), uma bead da árvore voltou sem status ou fechada sem `closed_at` legível (`why` = `bead_row_unreadable`: não se sabe há quanto tempo fechou), a atividade da árvore não pôde ser lida (`activity_unreadable`), ou a própria lista de worktrees do repo falhou na auditoria (`worktree_list_failed`, sem `wt`: as árvores do repo não foram olhadas e `worker_trees` não as conta). `worker_overdue` conta toda árvore dita atrasada, qualquer que seja o motivo: a coluna `beads` diz quais beads foram lidas e fechadas (vazia = nenhuma foi lida; é o caso de `op_in_progress` e de `bead_not_found`).

## O que cada motivo de `worker_tree_overdue` pede

Cada linha traz `repo`, `wt`, `branch`, `beads`, `closed_h`, `size_kb`, `reason`, `detail`, `locked` e `last_event` (o último evento que a passada registrou para a árvore). O `reason` é o primeiro que vale, na ordem em que a própria passada decide (o portão de idade vem antes do guarda de dado ignorado):

| reason | quer dizer | o que fazer |
|---|---|---|
| `locked` | trava do git (`detail` = o motivo escrito) | ver se a sessão dona vive; o contrato de trava do reaper (zumbi, sessão morta, bead fechada) é o que a solta |
| `op_in_progress` | rebase/merge/cherry-pick a meio | trabalho largado a meio: decisão humana (retomar ou descartar) |
| `in_use` | um processo tem a árvore como cwd ou arquivo aberto | achar o processo (`lsof +D <árvore>`) |
| `status_unreadable` | `git status` falhou | olhar o repo (disco cheio, índice corrompido) |
| `dirty` | mudança não commitada (`detail` = quantos caminhos) | decisão humana; o que o reaper faz com árvore suja não mudou (abaixo) |
| `young` | algo tocou a árvore dentro do portão de idade | normal por algumas horas; se persistir, achar quem escreve nela |
| `ignored_data` / `ignored_data_unknown` | dado ignorado fora da lista que a regra de liberação NÃO solta: maior que o teto, não medido, ou liberação desligada (`detail` = KiB). Dado pequeno e medido numa árvore de bead fechada há 12 h ou mais não é motivo: a passada o solta, e a árvore cai em `unknown` se ainda está lá | ler `top` no evento `kept_ignored_data` da árvore; se for lixo regenerável, acrescentar o nome a `WORKTREE_REAPER_WORKER_JUNK_RE`; se for dado, decisão humana |
| `bead_not_found` | o nome da árvore não acha bead e ela está parada há 24 h ou mais | árvore órfã: conferir e remover à mão com `git worktree remove` (nunca `rm -rf`) |
| `unknown` | nada do que a auditoria enxerga a segura | ler `last_event`: vazio = a passada não chegou nela (teto por passada, `bead_lookup_failed`); senão o nome do evento diz a prova que falhou; em simulação (`dry_run` true) ela está ali porque a simulação não remove nada |

## Interruptores

Todos por ambiente do job (`WORKTREE_REAPER_…`). `WORKER_AUDIT`: só o valor `0` desliga a auditoria. `CLOSED_WORKER_IGNORED_RELEASE`: só o valor `1` deixa a liberação ligada, qualquer outro (`0`, `off`, `true`, `2`) a desliga (o lado seguro: o dado ignorado volta a segurar a árvore). Número inválido de horas ou de KiB vale o padrão, nunca menos.

- `CLOSED_WORKER_IGNORED_RELEASE` (1; qualquer outro valor = só a lista de lixo, a regra do ga-xpoj67 para o resto), `CLOSED_WORKER_IGNORED_HOURS` (12), `CLOSED_WORKER_IGNORED_MAX_KB` (65536).
- `SHIPPED_CLOSED_HOURS`: quanto tempo a bead fica fechada antes de a árvore ENTREGUE ao `main` por patch (todo commit dela lá, `git cherry`) poder sair. Padrão = `CLOSED_BEAD_HOURS` (6), o mesmo de antes; `WORKTREE_REAPER_SHIPPED_CLOSED_HOURS=1` (ou 0) é o botão do "fim da entrega".
- `WORKER_JUNK_RE` (substitui a lista de lixo de worker), `WORKER_OVERDUE_HOURS` (24), `WORKER_AUDIT` (1; 0 desliga a auditoria e a linha `sweep` passa a dizer `worker_audit` 0).
- `WORKERS_REPORT` (caminho do relatório; padrão: o log trocando `.jsonl` por `.workers.jsonl`).

## O que não mudou e o que não foi provado

- **Árvore suja**: nenhuma regra nova remove árvore suja. O que já existia continua: árvore suja, sem trava e sem dado ignorado fora da lista passa pelo "preserve-then-reap" (ga-xv78c: o WIP vai ao origin antes de a árvore sair). Árvore suja com dado ignorado, ou cujo push falhou, fica e aparece no relatório com `reason` `dirty`.
- **"No fim da entrega"**: não há gancho no gate. A árvore sai quando as provas do reaper fecham: HEAD no `main` (30 min parada), ou bead fechada há 6 h com todo commit no `main` por patch (`git cherry`), ou há 12 h se a árvore tem dado ignorado fora da lista; mais a cadência do job. No pior caso fica bem abaixo das 24 h do aceite. Para encurtar: `WORKTREE_REAPER_SHIPPED_CLOSED_HOURS` (árvore entregue), `…_CLOSED_BEAD_HOURS` (árvore de bead fechada sem prova de entrega) e `…_CLOSED_WORKER_IGNORED_HOURS` (árvore com dado ignorado).
- **Não medido no mini**: este arquivo e o código foram feitos e testados no nó Linux, sobre árvores sintéticas com o `.gitignore` do WA. A causa no mini (se foi mesmo a trava de dados ignorados, ou se alguma das outras: `origin/main` desatualizado, `bd` falhando, trava) só a primeira passada depois do deploy mostra; por isso a auditoria existe.
