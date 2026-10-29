# Revisor do gate no nó Hetzner (gate-reviewer-remote) · runbook

## Contents

O que é · Desenho · Escritas do revisor × allowlist do atalho (ga-6auslu, pré-condição iii do degrau b da 1.6) · Ligar · Provar · Diferenças conhecidas (revisor do nó × local) · A admissão não espera o Phase C (ga-yjrg7n6) · Medido, inferido, não testado

Bead ga-2hd02v.1.9 (filha da ga-2hd02v.1). Mayor, 19/10: construir e provar no nó com sessão de teste ou dry-run **já**; a ATIVAÇÃO viva (flag, config do host) só depois do flip da 1.6 provado. **A 1.6 estava aberta quando esta fatia terminou: tudo aqui está pronto e INERTE.**

## O que é

O gate abre N revisores por rodada, todos no mini (`gate-reviewer`). O template `gate-reviewer-remote` tem `-remote-` no nome da sessão, e o `remote_match` do provider híbrido o manda ao nó. A cada revisor o dispatcher escolhe: **nó primeiro; local só se o nó estiver cheio, fora do ar, ilegível, ou se abrir a sessão no nó falhar.**

Peças: `agents/gate-reviewer-remote/` · `packs/town-deltas/assets/gate-remote-reviewers.lib.sh` (só ESCOLHE; só pergunta ao nó o `list-running`) · `quality-gate-dispatcher.sh` (Step 7 e re-convocação) · `gate-remote-reviewers.selftest.sh` (hermético) · a flag `$GC_CITY/.gc/gate-remote-reviewers.on`, que **NÃO existe**: sem ela o gate roda como antes.

## Desenho

* **Flag em 3 estados:** ligada, desligada, **ilegível** (pasta/link/arquivo que não se lê, `GC_CITY` vazio). Ilegível = local, e o log diz `flag UNREADABLE`.
* **Nó em 4 respostas:** `room`, `full`, `unready`, `unknown`. Só `room` vai ao nó; `unknown` (ssh caiu, `list-running` passou de 30 s, linha estranha, config ilegível, `timeout` ausente) **não é `room`**.
  `room` = vivas no nó < `cap` do host (`.gc/session-ssh.json`) **e** revisores remotos vivos < `max_active_sessions` do template (3; era 2 até ga-yjrg7n6). `unready` = o host não tem `real_sessions_released_by` (start sairia 12) ou `worktree_rigs["gate-reviewer"]` (sairia 13).
* **Uma tentativa no nó**; falhou, voltou vazio ou estourou → a MESMA etapa abre o local. Um estouro tem desfecho desconhecido: no pior caso sobra uma sessão ociosa no nó até o `idle_timeout` (10 min). Nunca dois revisores para o mesmo slot.
* **Slot que morreu no nó é substituído no LOCAL.** Slot que era local é oferecido ao nó como spawn novo.
* **Tarefa idêntica, palavra por palavra** (um texto por slot, renderizado antes de escolher o template). O revisor do nó recebe sempre a tarefa INTEIRA no nudge, nunca o ponteiro: o atalho do nó não devolve corpo de comentário (`bd comments` e `--include-comments` voltam rc 77).
* **Veredito por `bd comment` + `bd close`.** `bd label add|remove` e `drain-ack` voltam rc 77; o prompt manda não repetir e entregar `VERDICT: PASS|FAIL …` no comentário, que o dispatcher já lê (ga-86l90a8, ga-w7pm55). O atalho NÃO foi alargado.
* **Não mexe em** janitor, 2º revisor E5 e `refino-gate-dispatcher` (locais). O `cleanup_reviewer_sessions` do fim da rodada fecha as remotas pelos ids.
* **Headroom do mini: o revisor do nó já não gasta o teto local, e há UM desvio (ga-n4ql4ur).** O teto que o gate admite (`GATE_MAX_REVIEWERS`, preso ao cap do motor para o template `gate-reviewer`) e a contagem `LIVE_REVIEWERS` são só do template LOCAL, então sessão `gate-reviewer-remote` nunca os consome. O que faltava: com o teto local cheio e vaga no nó, `gate_headroom_decision` dava `defer … dolt-calm-cap-reached` mesmo assim. `gate_headroom_node_admit` vira ESSE defer em admit, e só quando `gate_remote_pick_template` responde `node` (a sonda do nó só é paga nesse caso). Continuam em defer: qualquer outra razão (Dolt morno/quente, cota, memória, swap, sem sinal), a pausa do operador (`GATE_MAX_REVIEWERS=0`) e run de mais de 1 revisor. Resíduo: o spawn pergunta ao nó de novo; se o nó recusar nesse instante, o revisor abre local ACIMA do teto e pode esperar em `start-pending` com o prazo do veredito correndo. O log diz `Headroom NODE: …` na admissão e `run admitted on the NODE's room … opening LOCAL above the local ceiling` nesse resíduo. Prova: `quality-gate-headroom-node.selftest.sh` (função, bloco real e mutantes) e os casos do aviso em `gate-remote-reviewers.selftest.sh`. NÃO provado aqui: o log ao vivo com mais de 2 runs ao mesmo tempo (precisa do daemon recarregado depois do merge).

## Escritas do revisor × allowlist do atalho (ga-6auslu, pré-condição iii do degrau b da 1.6)

Conferido por leitura de código, nada rodou contra produção. TUDO que um revisor do gate grava é o rodapé do texto da tarefa (`gate-review-task.lib.sh::_gate_review_task_verdict_bead`), na bead de veredito `<VB>`. O revisor NÃO grava metadata (`gate.*`/`gc.*`/`athos.*`), NÃO manda mail (os dois prompts proíbem) e o prompt do nó não manda nudge. A fórmula `mol-quality-gate-runner` é do runner, não do revisor.

| Escrita do revisor | No atalho do nó | Como o veredito chega ao dispatcher |
|---|---|---|
| `bd comment <VB> "VERDICT: PASS\|FAIL …"` | coberta, **com trava de dono** (`bd comment <id> <texto>` `+dono`: só passa se o assignee da bead de veredito for o alias do nó) | comentário ancorado `^VERDICT: PASS\|FAIL`: PASS ga-86l90a8, FAIL ga-w7pm55 (`gate_collect_verdicts`) |
| `bd close <VB>` | coberta, **com trava de dono** (`bd close <id>` `+dono`) | a bead FECHA; só bead fechada conta pelo comentário (ver abaixo) |
| `bd label remove <VB> verdict:pending` | **rc 77, de propósito** | dispensável: o dispatcher decide pelo comentário, o rótulo fica na bead fechada |
| `bd label add <VB> verdict:PASS` | **rc 77, de propósito** | o comentário carrega o PASS |
| `bd label add <VB> verdict:FAIL` | **rc 77, de propósito** | o comentário carrega o FAIL e o motivo |
| `gc runtime drain-ack` (só no prompt LOCAL) | rc 77 | o nó sai pelo `idle_timeout` (10 min); não é escrita de dado |
| metadata · mail · nudge | o revisor não escreve | — |

**Por que o rótulo fica FORA da lista (não é "a allowlist ainda não foi alargada").** O `bd label add` não confere dono; o `bd close` confere (recusa quem não é o assignee, ga-9ophv2). O dispatcher lê `verdict:PASS` ANTES de `verdict:FAIL` (um PASS forjado vence o FAIL real) e o resgate ga-7lz1 fecha bead ABERTA que já tem rótulo e revisor drenado: um `label add <bead alheia> verdict:PASS` vindo do nó (ou de um revisor do nó induzido por texto dentro de um diff) aprovaria código sem revisão. Alargar a lista com as 2 formas exatas foi feito e REVERTIDO no mesmo dia (a revisão de segurança do commit achou isto). Travado por teste, por chave: `remote-shim.selftest.sh` (as 3 chaves + 9 vizinhas, nas 2 formas `bd …` e `bd -C … `), o mutante `rotulo-do-veredito-passa` em `remote-shim.mutants.py` (uma regra `bd label` reprova o 1º caso por chave) e `gate-remote-reviewers.selftest.sh` 5b (as chaves de rótulo do texto REAL da tarefa são exatamente as 3). Chave nova no texto da tarefa reprova até alguém decidir.

**O lado do mini conta o veredito só por comentário?** Sim, para bead FECHADA sem rótulo `verdict:PASS|FAIL`: PASS ancorado → PASS, FAIL ancorado → rejeição real de código com o motivo ao builder (provado em `gate-no-verdict-infra-not-code-fail.selftest.sh`, 31/31, com mutantes que desligam cada resgate). **Bead ABERTA só com comentário NÃO conta:** o resgate ga-7lz1 exige rótulo + revisor drenado. Logo o `close` do revisor do nó é a escrita que carrega o veredito; ele só passa se o `BEADS_ACTOR` (o alias declarado pelo nó) for o assignee da bead de veredito (nome da sessão): **isto só se prova na sessão de teste do nó** (passo 2 de "Provar"). Close recusado = bead aberta = a rodada espera o orçamento de tempo e re-revisa (lento, seguro).

**Resíduo anterior, FECHADO (ga-2hd02v.1.16).** `bd comment <id>` e `bd close <id>` não conferiam de quem era a bead: em bead de veredito FECHADA e SEM rótulo (revisor que morreu), um `VERDICT: PASS` ancorado escrito por OUTRA sessão do nó era lido como PASS, e o dispatcher olha o PASS antes do FAIL (preferir FAIL no dispatcher não bastaria: bead de revisor morto não tem FAIL). Agora as 3 regras de escrita em bead levam a trava `+dono` no wrapper (`scripts/remote-shim-wrapper.py`, `read_bead` + `owner_gate`): antes de gravar o `ok` ele lê `bd show <id> --json` no mesmo cwd e ambiente (`BD_READONLY=true`, stdin fechado, prazo `min(timeout_s, 60)`) e, se a bead tem o rótulo EXATO `type:quality-gate-verdict`, só deixa passar quando o `assignee` é o alias declarado da sessão (o mesmo que vira `BEADS_ACTOR`). Bead sem esse rótulo passa como antes (o dog remoto comenta e fecha a própria bead por aqui). Três estados: `assignee`/`labels` AUSENTES = "não tem" (o bd omite a chave; 55 de 60 beads fechadas medidas não têm assignee), e bead de veredito sem dono é recusada; leitura que falhou, estourou o prazo, veio com rc≠0 ou fora da forma (lista de UMA bead, `labels` lista de texto, `assignee` texto) = "não consegui ler" → 77 `nada foi executado, pode repetir`; bead de outro dono → 77 `não repita`. Travado por teste (`remote-shim.selftest.sh`, seção "trava de dono") e por mutantes em `remote-shim.mutants.py` (`dono-sem-checagem`, `trava-so-sem-comment|stdin|close`, `tipo-sempre-casa`, `rotulo-por-substring`, `assignee-vazio-passa`, `leitura-*`). **Custo aceito:** bead de veredito SEM assignee (ga-6wel0o viu assignee e metadata vazios em ~30% dos casos antes do ga-qqtoo) → o revisor do nó não consegue comentar nem fechar nela: a rodada espera o orçamento de tempo e re-revisa (lento, seguro; mesma semântica do `bd close` real). **Corrida:** a leitura e o comando são duas chamadas, e o dono pode mudar entre elas (janela de milissegundos). Extensão possível, NÃO feita (decisão do Mayor): aceitar `metadata gc.session_name == alias` quando o assignee falta.

## Ligar

**Não antes do flip da 1.6 provado e do OK do Mayor.**

1. `[session] provider = "hybrid"` e `remote_match = "-remote-"` no `city.toml` vivo, e um dog remoto já rodou de ponta a ponta (sem o híbrido a sessão abriria no mini).
2. Implantar esta fatia (merge + deploy). O dispatcher segue local: a flag não existe.
3. `gc session new gate-reviewer-remote --no-attach` precisa achar o template (se pedir reload da config, fazer; inferido). Se não achar, o log diz `node spawn gave no session` e cai no local.
4. O `identity_pattern` em `~/.gastown/remote-shim.json` já aceita `gate-reviewer-remote-adhoc-<10>` (medido 19/10).
5. **Decisão do Mayor:** `"gate-reviewer": "gascity"` em `worktree_rigs` do host `hetzner` (o provider relê a cada chamada):
   ```bash
   cp "$GC_CITY/.gc/session-ssh.json" "$GC_CITY/.gc/session-ssh.json.bak-$(date +%Y%m%d-%H%M)"
   jq '.hosts.hetzner.worktree_rigs["gate-reviewer"]="gascity"' "$GC_CITY/.gc/session-ssh.json" > /tmp/ssh.new && mv /tmp/ssh.new "$GC_CITY/.gc/session-ssh.json"
   ```
6. `touch "$GC_CITY/.gc/gate-remote-reviewers.on"` vale na próxima rodada. **Desligar:** `rm` da flag; rodadas em curso terminam onde estão.

**São do Mayor:** ligar a flag e quando · editar `worktree_rigs` do host (passo 5) · dar paridade de rótulo ao nó (não feito, e não é acerto de lista: ver "Escritas do revisor × allowlist do atalho", o `label add` forja veredito sem checagem de dono) ou ler comentários · o teto do template (2) e o transbordo (ga-2hd02v.1.11) · o critério de aceite das 3 revisões.

## Provar

Critério: **3 revisões reais concluídas no nó, cada uma com veredito igual ao de uma revisão local da mesma sha.**

1. **Dry-run (feito em 19/10).** Pergunta ao nó de verdade, só leitura, com flag temporária e uma CÓPIA da config:
   ```bash
   W=<árvore com a lib>; L="$GC_CITY"; D=$(mktemp -d); : > "$D/flag.on"
   jq '.hosts.hetzner.worktree_rigs["gate-reviewer"]="gascity"' "$L/.gc/session-ssh.json" > "$D/ssh-ready.json"
   GC_CITY="$L" GATE_REMOTE_FLAG_FILE="$D/flag.on" GATE_REMOTE_AGENT_TOML="$W/agents/gate-reviewer-remote/agent.toml" \
     GATE_REMOTE_SSH_CONFIG="$D/ssh-ready.json" bash -c 'source "$0"; gate_remote_pick_template; echo "$GATE_REMOTE_PICK_TEMPLATE $GATE_REMOTE_PICK_KIND — $GATE_REMOTE_PICK_WHY"' "$W/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
   ```
   Contra o nó real: config viva → `gate-reviewer fallback — unready`; cópia que mapeia o rig → `gate-reviewer-remote node — node has room`.
2. **Sessão de teste no nó (depois do passo 5, ANTES da flag).** `gc session new gate-reviewer-remote --no-attach --json`, bead de veredito de brinquedo atribuída ao nome da sessão e uma tarefa curta no nudge. Conferir (ga-2hd02v.1.16): `bd comment` e `bd close` NESSA bead passam (o alias do nó é o assignee), e o mesmo comando contra uma bead de veredito atribuída a OUTRO alias volta 77 `não repita`. Conferir: o `bd list --assignee` achou a bead; o `label` voltou rc 77 sem repetir; `VERDICT: …` entrou e a bead fechou; depois do `idle_timeout` a sessão sumiu do `scripts/gc-session-ssh list-running`.
3. **As 3 revisões reais (com a flag).** Por revisão: sha, tempo até o 1º turno e até o veredito, canal (rótulo ou só comentário), veredito e achados. Rodar **a mesma sha** pelo caminho local e comparar PASS/FAIL e, no FAIL, os bloqueios. Quem decide se 3 de 3 bastam é o Mayor.

Log do dispatcher: `Reviewer N: node has room - remote reviewer first` (nó) · `Reviewer N: full|unready|unknown (…) - local reviewer` (motivo na linha) · `node spawn gave no session … falling back` · `Re-convene: slot N ran on the node and died` · `remote-reviewer flag UNREADABLE` · `flag file exists but … lib.sh is NOT loaded`. Depois de uma rodada `list-running` não deve listar `gate-reviewer-remote-*`.

## Diferenças conhecidas (revisor do nó × local)

1. **Sem o overlay `pool-reviewer`** (o provider ignora `overlay_dir` e `env`): a diferença mais provável de mudar um veredito. O bloco "THE THIRD STATE" do prompt é idêntico ao do local (comparado no selftest).
2. **Worktree do rig `gascity` vem do espelho:** o branch em revisão pode não estar lá (o prompt manda dizer no veredito).
3. **Canal de volta só por comentário**, sem rótulo `verdict:*`; a 1ª linha tem de ser `VERDICT: PASS|FAIL`.
4. **Sem `drain-ack`:** a sessão ociosa fecha pelo `idle_timeout` de 10 min (local: 1 h) e segura uma vaga do nó até lá.
5. **`start` mais lento:** o `wt-add` puxa o espelho (piso de 150 s) e segura o `flock` do host; com o teto do template em 3, o 2º e o 3º revisor podem estourar `GATE_SPAWN_TIMEOUT_SECS` (150 s) e deixar uma sessão ociosa no nó até o `idle_timeout`. **Não medido por este runbook.** Relato do Mayor com o teto 3 no ar (29/10, comentário da ga-yjrg7n6 às 07:39Z; contagem dele, não conferida aqui): 3 `gate-reviewer-remote` ativos ao mesmo tempo às 04:38 e 0 linhas de `spawn timeout` / `unknown outcome` / `spawn_err` no log do dispatcher desde 04:07. Janela curta: o risco segue a observar.
6. **1º turno de procura:** `bd list --assignee` pode voltar vazio com a bead certa (ga-mo7q); o prompt manda confirmar por `bd show <id> --json`.

## A admissão não espera o Phase C (ga-yjrg7n6)

Medido em 29/10 (00:48–02:02, log do dispatcher): a rodada 2 abriu às 00:49:47 e só chegou a "Found 9 queued marker(s)" às 01:03:04, **13 min sem admitir nada**. O tempo era o Phase C (cada run ainda em voo custa ~35–48 s de `bd list`/`bd show`/`gc rig list`; cada run que fechou custa 2,5–4 min de finalize) mais as passadas filhas do mid-sweep (3m46s e 2m47s), tudo ANTES do "Found". Nas rodadas seguintes o Phase C levou 1,5–2,5 min e do "Found" ao "Run admitted" passaram 3,9–8,7 min.

**Orçamento pré-admissão:** `GATE_PREADMIT_BUDGET_SECS` (padrão **150** s por rodada, contados do banner `=== Dispatcher sweep start`; **`0` desliga** e volta ao comportamento antigo; não numérico = 150). Dois efeitos:

* **Phase C não COMEÇA run novo depois do orçamento.** Sempre começa pelo menos um (a rodada nunca fica sem progresso) e nunca corta um finalize em andamento. Os que sobraram vão para `$GC_CITY/.gc/gate-phase-c-deferred` (um id por blank, gravado por tmp+mv) e a rodada seguinte os confere **primeiro**, na ordem do arquivo: as rodadas viram um rodízio, nenhum run fica atrás da cabeça da lista. Arquivo ausente = ordem natural. Arquivo **ilegível** (uma pasta no lugar, sem permissão) = ordem natural nessa rodada, e o log diz `… exists but cannot be read`. Gravação que falha = o log diz `could not record the deferred run(s)` e a lista anterior é apagada (senão a rodada seguinte partiria de ids velhos); se nem apagar der, o aviso diz que ela parte da lista anterior. Os avisos dos três auxiliares (ler, gravar, reordenar) saem em **stderr**: quem os chama captura o stdout, e um aviso lá seria entregue ao `jq` como se fosse um id e nunca chegaria ao log (foi o furo da 1ª tentativa no gate). Num diretório de estado quebrado a cauda de uma lista longa não é alcançada enquanto os runs da cabeça seguem em voo (o finalize e o timeout dela esperam): é um atraso, visível no log a cada rodada, não um run perdido.
* **A passada filha do mid-sweep espera.** Com um marker aguardando admissão (do `Found N` até o run dele ter a bead; com outros markers ainda na fila, até o fim da rodada) ou, **antes** da admissão, com o orçamento gasto, os candidatos ficam pendentes. Quem os coleta é um ponto seguro posterior da mesma rodada — só depois que o ÚLTIMO marker da fila foi admitido: aí o orçamento deixa de valer e o ACK wait (`step-7b-ack`) volta a coletar como antes — ou, senão, o Phase C da rodada seguinte. A filha do Phase C-only (a que recebe os ids) **não** aplica o orçamento.

**Detecção de revisor morto não muda:** ela é guiada por timeout do run (`VERDICT_TIMEOUT_MINUTES`, 22 min, até 50) ou por sessão primária confirmada fechada, e só dispara quando o run é CONFERIDO. O run adiado é conferido na rodada seguinte; os que estão atrás dele na lista esperam uma rodada a mais cada. Com k runs alcançados por rodada (vários quando cada um é só "ainda em voo"; **um** quando um finalize de 2,5–4 min vem primeiro) o último de N espera até ceil(N/k) rodadas — **por leitura do código, não medido**: "o atraso é de uma rodada" vale só para a cabeça da lista. O custo é latência de finalize/merge de um run que já podia fechar, não perda.

Log: `Phase C: pre-admission budget of Ns spent after Ms — K of N in-flight run(s) left for the next round, which checks them first: IDS` · `Mid-sweep (…): … NOT collecting now; kept for a later safe point of this round or the next round's Phase C` · `Pre-admission: reached admission Ns after the sweep start (budget Ns; Phase C left IDS|none for the next round)` (o intervalo antes/depois da admissão) · avisos: `… exists but cannot be read` · `could not record the deferred run(s)` · `the list of in-flight runs could not be reordered` · `the list of runs still to check could not be listed` (o orçamento fica sem efeito no resto da rodada). Prova: `gate-yjrg7n6-preadmit-budget.selftest.sh` (processo de verdade numa cidade de rascunho com um marker na fila: a linha de medição, uma pasta no lugar do arquivo, um jq que falha; mais os mutantes de cada guarda).

**Custo conhecido:** um revisor REMOTO que já terminou, num run adiado, segura a vaga do nó por mais uma rodada (o Step 0a-2 só tira do headroom os revisores LOCAIS terminados; o remoto sai no finalize ou no `idle_timeout` de 10 min). Com o teto do template em 3, isso consome uma das 3 vagas, no pior caso, por uma rodada.

## Medido, inferido, não testado

**Medido (19/10, hermético):** o selftest cobre a escolha (flag em 3 estados; nó room/full/unready/unknown; sonda presa; config ruim; `/bin/bash` 3.2 sob `set -euo pipefail`), a costura no dispatcher (lib ausente/quebrada; spawn node-first em 11 desfechos; re-convocação; ponteiro desligado no slot do nó), o template (bloco THIRD STATE idêntico; nome casa com `remote_match` e `identity_pattern`), o `decide()` REAL do `remote-shim-wrapper.py` (aceita `comment`/`close` do texto real da tarefa; recusa `label`, `drain-ack`, `--include-comments`) e 4 mutantes da escolha (sonda com rc≠0 lida como room, teto ilegível lido como enorme, linha de banner contada como sessão, flag ilegível lida como ligada); os do dispatcher (ponteiro no slot do nó, bloco local, template do slot) foram conferidos à mão com `DISPATCHER_UNDER_TEST`. Os selftests vizinhos que contam pontos de spawn foram atualizados de propósito (`session-new-bounded` 3→5, `gate-spawn-err-capture` 2→3); o `pool-prompt-skill-mention` mantém as 10 falhas da main.

**Inferido:** o engine só enxerga o template novo após recarregar a config; o `idle_timeout` recolhe a sessão ociosa do nó. **NÃO testado (só com a flag, depois da 1.6):** revisão de verdade no nó; tempo do `wt-add`; o `claude-headless` do nó abrindo o prompt; o resgate por comentário com texto real; a equivalência de veredito; o efeito da falta do overlay. A lib só olha o `list-running`: não vê CPU/memória do nó (a medição é a ga-2hd02v.1.11).
