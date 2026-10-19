# Revisor do gate no nó Hetzner (gate-reviewer-remote) · runbook

## Contents

• O que é — e o estado hoje (CONSTRUÍDO E INERTE) · Desenho (quem escolhe, quando cai no local, a tarefa é a mesma, o veredito volta por comentário)
• **Ligar** (pré-condições, ordem, desligar) · **Provar** (dry-run sem ligar · sessão de teste · as 3 revisões contra o local) · O que olhar no log
• Diferenças conhecidas entre o revisor do nó e o local · Decisões que são do Mayor · Medido, inferido, não testado · Limites

Bead ga-2hd02v.1.9 (filha da ga-2hd02v.1, P0): "revisores do gate rodando no nó (gate-reviewer-remote), depois do dog-remote provado". Mayor, em 19/10: construir e provar no nó com sessão de teste ou dry-run **já**, em paralelo à ga-2hd02v.1.6; a ATIVAÇÃO viva (flag, config do host) só depois do flip da 1.6 provado. **A 1.6 estava aberta quando esta fatia terminou, então tudo aqui está pronto e inerte.**

## O que é — e o estado hoje

O quality gate abre N revisores independentes por rodada. Até aqui todos rodam no mini (template `gate-reviewer`). Esta fatia põe um segundo template, `gate-reviewer-remote`, cuja sessão tem `-remote-` no nome: o `remote_match` do provider híbrido a manda para o nó Hetzner. O dispatcher escolhe a cada revisor: **nó primeiro; local só se o nó estiver cheio, fora do ar, ilegível, ou se abrir a sessão no nó falhar.**

| peça | arquivo | estado |
|---|---|---|
| template | `agents/gate-reviewer-remote/{agent.toml,prompt.template.md}` | no repositório; o engine só o usa se o dispatcher pedir |
| escolha | `packs/town-deltas/assets/gate-remote-reviewers.lib.sh` | só ESCOLHE; não abre nada e só pergunta ao nó o `list-running` |
| costura | `packs/town-deltas/assets/quality-gate-dispatcher.sh` | carrega a lib com o idioma à prova de falha; Step 7 e re-convocação tentam o nó uma vez |
| teste | `packs/town-deltas/assets/gate-remote-reviewers.selftest.sh` | hermético, sem rede; 140+ asserções e mutantes |
| flag | `$GC_CITY/.gc/gate-remote-reviewers.on` | **NÃO existe.** Sem ela o dispatcher nunca escolhe o nó |

Sem a flag o gate roda byte a byte como antes. Com a flag e qualquer dúvida (nó cheio, `list-running` falhou, config ilegível, teto não lido) também: local.

## Desenho

* **Quem escolhe.** `gate_remote_pick_template`, chamada pelo dispatcher antes de cada `gc session new` de revisor (Step 7 e `respawn_reviewer_slot`). Devolve por globais `GATE_REMOTE_PICK_TEMPLATE|KIND|WHY`; `KIND` é `inert` (flag desligada, o log não diz nada), `node` ou `fallback` (a flag está ligada e o nó não serve; o log diz por quê).
* **A flag tem 3 estados:** ligada, desligada e **ilegível** (pasta que não se enxerga, link quebrado, arquivo sem leitura, `GC_CITY` vazio). Ilegível = local e o log diz `flag UNREADABLE`; nunca é lida como "ligada".
* **O nó tem 4 respostas:** `room`, `full`, `unready`, `unknown`. Só `room` vai ao nó. `unknown` (ssh caiu, `list-running` estourou 30 s, linha estranha, config ilegível, `timeout` ausente) **não é `room`**.
  * `room` = (sessões vivas no nó) < `cap` do host em `.gc/session-ssh.json` **e** (revisores remotos vivos) < `max_active_sessions` do template (2). Os dois tetos são LIDOS; teto que não leu é `unknown`.
  * `unready` = o host não tem `real_sessions_released_by` (o start sairia 12) ou não tem `worktree_rigs["gate-reviewer"]` (o start sairia 13). Nem tenta abrir.
  * O `list-running` do provider devolve rc≠0 em qualquer erro de host (nunca "vazio"); rc 0 com saída vazia é "nenhuma sessão".
* **Uma tentativa no nó.** Se o `gc session new gate-reviewer-remote` falhar, voltar vazio ou estourar, a MESMA etapa abre o revisor local, pelo caminho de sempre (com o laço de repetição transitória intacto). Custo de um estouro: o desfecho é desconhecido, a sessão pode ter nascido; fica no máximo uma sessão ociosa no nó até o `idle_timeout` (10 min), segurando uma vaga do nó. Nunca dois revisores para o mesmo slot (o slot só conhece o id do spawn que deu certo).
* **Slot que morreu no nó é substituído no LOCAL**, sem nova tentativa no nó: o que o matou (nó, sessão perdida, boot preso) é o motivo mais provável do veredito atrasado, e o local é o caminho que sempre funcionou. Slot que era local é oferecido ao nó como um spawn novo.
* **A tarefa é a mesma, palavra por palavra.** O dispatcher renderiza UM texto por slot (`gate_render_review_task`) antes de escolher o template; local e nó recebem o mesmo. O que muda é onde o Claude roda e o canal de volta. Equivalência de veredito, portanto, vale por construção; o que pode diferir é o contexto em volta (ver "Diferenças").
* **O revisor do nó sempre recebe a tarefa INTEIRA no nudge, nunca o ponteiro.** O atalho do nó não devolve o corpo de comentário (`bd show --json` o omite; `bd comments` e `bd show --include-comments` voltam rc 77), então um ponteiro "a tarefa está na bead" o deixaria sem tarefa. Está em `gate_deliver_review_task` (ponteiro forçado a 0 para o slot do template remoto).
* **O veredito volta por `bd comment` + `bd close`.** O atalho recusa `bd label add|remove` (rc 77) e `gc runtime drain-ack`. O prompt do nó diz para rodar os comandos de rótulo da tarefa, esperar o rc 77 sem repetir, e entregar `VERDICT: PASS|FAIL …` no comentário, depois fechar a bead. O dispatcher já lê o veredito desse comentário quando o rótulo não chegou (ga-86l90a8 para PASS, ga-w7pm55 para FAIL). Nada disso foi alargado no atalho.
* **Não mexe em:** o janitor (`template=="gate-reviewer"` só), o teto/headroom do local, o 2º revisor E5 e o `refino-gate-dispatcher` (sempre locais). Sessões remotas não entram na conta de headroom do mini e não são recolhidas pelo janitor; o `cleanup_reviewer_sessions` do fim da rodada as fecha pelos ids.
* **Por que `max_active_sessions = 2` e não 1.** O nó tem teto 4 no total e o dog-remote ocupa 1. O run de código usa 1 revisor, então 2 = dois runs ao mesmo tempo no nó, com 1 vaga de folga. E 1 seria lido pelo guarda `crew-session-dedup` como sessão única (mataria o segundo `gc session new`).

## Ligar

**Não ligar antes do flip da 1.6 provado e do OK do Mayor.** Ordem:

1. **A 1.6 provada.** `[session] provider = "hybrid"` e `remote_match = "-remote-"` no `city.toml` vivo; um dog remoto já rodou de ponta a ponta. Sem o híbrido, a sessão `gate-reviewer-remote-adhoc-…` não iria ao nó (inferido: abriria no mini, com nome estranho e sem o overlay), e a lib ainda responderia `room`.
2. **Implantar esta fatia** (merge + deploy): lib, dispatcher, template. O dispatcher segue local, porque a flag não existe. Conferir, depois de ligar a flag (passo 6), que o log do gate NÃO tem a linha `Remote reviewers: the flag file exists but gate-remote-reviewers.lib.sh is NOT loaded` (a lib carregou).
3. **O engine enxerga o template.** `gc session new gate-reviewer-remote --no-attach` precisa achar `agents/gate-reviewer-remote`. Se o engine pedir reload da config, fazer (inferido: um template novo só aparece depois). Se não achar, o dispatcher cai no local e o log diz `node spawn gave no session (spawn_err=…)`: seguro, mas o nó não é usado.
4. **Identidade do atalho.** O `identity_pattern` vivo em `~/.gastown/remote-shim.json` já aceita `gate-reviewer-remote-adhoc-<10>` (medido em 19/10: é a linha `IDENTITY_PATTERN=` de `gc-session-ssh.md`). Nada a mudar.
5. **Config do host** (decisão do Mayor, ver abaixo). Em `<cidade>/.gc/session-ssh.json`, no host `hetzner`, acrescentar `"gate-reviewer": "gascity"` a `worktree_rigs`:

   ```bash
   cp "$GC_CITY/.gc/session-ssh.json" "$GC_CITY/.gc/session-ssh.json.bak-$(date +%Y%m%d-%H%M)"
   jq '.hosts.hetzner.worktree_rigs["gate-reviewer"]="gascity"' "$GC_CITY/.gc/session-ssh.json" > /tmp/ssh.new && mv /tmp/ssh.new "$GC_CITY/.gc/session-ssh.json"
   ```

   Sem isso o start do revisor sai 13 e a lib já responde `unready` (o gate fica local). O provider lê a config a cada chamada (é um script), então não há reinício.
6. **A flag:** `touch "$GC_CITY/.gc/gate-remote-reviewers.on"`. Vale na próxima rodada do gate.

**Desligar:** `rm "$GC_CITY/.gc/gate-remote-reviewers.on"`. Rodadas em curso terminam onde estão (um slot já no nó segue lá; se morrer, é substituído no local). Para desligar também a lib: nada; sem a flag ela só responde `inert`.

## Provar

O critério da história: **3 revisões reais concluídas no nó, cada uma com veredito igual ao de uma revisão local da mesma sha.** Em três degraus, do mais barato ao que precisa da flag.

**1. Dry-run, sem ligar nada (feito em 19/10, repetível).** Pergunta ao nó de verdade, só leitura (`list-running`), com uma flag temporária e uma CÓPIA da config:

```bash
W=<worktree ou cidade com a lib>; L="$GC_CITY"; D=$(mktemp -d); : > "$D/flag.on"
jq '.hosts.hetzner.worktree_rigs["gate-reviewer"]="gascity"' "$L/.gc/session-ssh.json" > "$D/ssh-ready.json"
GC_CITY="$L" GATE_REMOTE_FLAG_FILE="$D/flag.on" GATE_REMOTE_AGENT_TOML="$W/agents/gate-reviewer-remote/agent.toml" \
  GATE_REMOTE_SSH_CONFIG="$D/ssh-ready.json" bash -c 'source "$0"; gate_remote_pick_template; echo "$GATE_REMOTE_PICK_TEMPLATE $GATE_REMOTE_PICK_KIND — $GATE_REMOTE_PICK_WHY"' "$W/packs/town-deltas/assets/gate-remote-reviewers.lib.sh"
```

Resultado de 19/10 contra o nó real: com a config viva → `gate-reviewer fallback — unready (host worktree_rigs has no "gate-reviewer" …)`; com a cópia que mapeia o rig → `gate-reviewer-remote node — node has room` (o nó tinha 1 sessão: `dog-remote-gawispnw7x21`). Nenhum arquivo vivo foi tocado; a flag não existe.

**2. Sessão de teste no nó (depois do passo 5 de "Ligar", ANTES da flag).** À mão, para ver o revisor nascer e entregar sem o dispatcher:

1. `gc session new gate-reviewer-remote --no-attach --title "teste 1.9" --json` → o `session_name` tem de ser `gate-reviewer-remote-adhoc-<10>` e `scripts/gc-session-ssh list-running` tem de listá-lo.
2. Criar uma bead de veredito de brinquedo (`type:quality-gate-verdict`, `verdict:pending`) atribuída a esse nome, e um nudge com uma tarefa curta (renderizar com `gate_render_review_task` sobre um diff pequeno).
3. Conferir, no `session-ssh.log` e na saída da sessão: (a) o `bd list --assignee` do primeiro turno achou a bead; (b) o `label` voltou rc 77 e o revisor NÃO repetiu; (c) o comentário `VERDICT: …` entrou e a bead fechou; (d) a sessão parou e `list-running` não a mostra mais depois do `idle_timeout`.
4. `gc session close` se sobrar. Fechar a bead de brinquedo.

**3. As 3 revisões reais (com a flag).** Por revisão, registrar numa bead de evidência: sha, lente, template (`remote reviewer first` no log), tempo até o 1º turno, tempo até o veredito, canal (rótulo ou só comentário), se `--assignee` voltou vazio, e o veredito com os achados. Depois rodar **a mesma sha** pelo caminho local (flag desligada e a rodada refeita pelo caminho normal do gate) e comparar: PASS/FAIL iguais e, no FAIL, os mesmos bloqueios. Divergência não é falha da fatia por si só: pode ser a diferença de contexto (abaixo), e é isso que a prova mede. Quem decide se 3 de 3 bastam é o Mayor.

## O que olhar no log do dispatcher

| linha | quer dizer |
|---|---|
| `Reviewer N: node has room - remote reviewer first` | escolheu o nó e vai abrir lá |
| `Reviewer N: full (…)` / `unready (…)` / `unknown (…)` `- local reviewer` | a flag está ligada e o nó não serviu; o motivo está na linha |
| `Reviewer N: node spawn gave no session (spawn_err=…) - falling back to the local reviewer` | o `session new` no nó falhou/estourou; o revisor foi aberto local |
| `Re-convene: slot N ran on the node and died - replacement goes to the local reviewer` | slot do nó substituído no local |
| `remote-reviewer flag UNREADABLE - local reviewer` | não deu para ler a flag; ficou local |
| `Remote reviewers: the flag file exists but gate-remote-reviewers.lib.sh is NOT loaded` | flag ligada e a lib não carregou: nenhum revisor vai ao nó |

Depois de uma rodada: `scripts/gc-session-ssh list-running` não deve listar `gate-reviewer-remote-*` (se listar, é a sessão perdida de um estouro; some no `idle_timeout`).

## Diferenças conhecidas entre o revisor do nó e o local

1. **Sem o overlay `pool-reviewer`.** O provider ignora `overlay_dir` e `env` do template, então o revisor do nó não tem o preâmbulo do overlay nem `TD_ROLE=reviewer`. Ele tem o prompt próprio (com o bloco "THE THIRD STATE" idêntico ao do local, comparado byte a byte no selftest) e o texto da tarefa. É a diferença de contexto mais provável de mudar um veredito: a prova mede.
2. **Worktree do rig `gascity` no nó**, criado pelo `wt-add` no start, a partir do espelho do mini. O branch em revisão pode não estar lá; o prompt manda dizer isso no veredito em vez de supor. O `CLAUDE.md` do repositório pode ser carregado.
3. **Canal de volta só por comentário** (sem rótulo `verdict:*`): depende do resgate do dispatcher; o comentário tem de começar com `VERDICT: PASS|FAIL` na primeira linha.
4. **Sem `drain-ack`:** a sessão ociosa se encerra pelo `idle_timeout` de 10 min (o local usa 1 h e sai por `drain-ack`). Entre o veredito e o fim ela segura uma vaga do nó.
5. **O `start` demora mais:** o `wt-add` puxa o espelho (piso de 150 s no `start_timeout`), segura o `flock` do host (dois starts de papéis com worktree esperam um pelo outro) e o `gate_bounded_spawn` espera 150 s. Se o `wt-add` passar disso, o gate cai no local e deixa uma sessão perdida no nó (ver "Desenho"). **Não medido para este papel.**
6. **O primeiro turno é de procura.** `bd list --assignee` pode voltar vazio mesmo com a bead certa (ga-mo7q); o prompt manda confirmar por `bd show <id> --json` e `metadata["gc.session_name"]`, e a bead que não for sua não se toca.

## Decisões que são do Mayor

1. **Ligar** (a flag) e **quando**: depois do flip da 1.6 provado.
2. **Editar `worktree_rigs` do host `hetzner`** (passo 5). Mexe na config viva do provider.
3. **Alargar o atalho do nó** para `bd label add verdict:*` e para ler comentários (`bd comments` ou `bd show --include-comments`). Hoje NÃO está feito; com isso o canal de volta seria o mesmo do local e o ponteiro poderia voltar. É decisão de segurança (a allowlist é a fronteira do nó) e fica fora desta fatia.
4. **O teto do template** (2) e a regra de transbordo, que se cruzam com a ga-2hd02v.1.11 (capacidade e preferência: nó primeiro, mini só no transbordo).
5. **O critério de aceite** das 3 revisões (3 de 3 iguais? aceitar divergência explicada pelo contexto?).

## Medido, inferido, não testado

**Medido em 19/10 (hermético):**
* `gate-remote-reviewers.selftest.sh`: lib (flag 3 estados, nó room/full/unready/unknown, probe preso, config ruim, `/bin/bash` 3.2 sob `set -euo pipefail`), dispatcher (bloco de carga com lib ausente/quebrada, spawn node-first com o `gc` de mentira em 7 desfechos, re-convocação, ponteiro desligado no slot do nó), template (`agent.toml`, bloco THIRD STATE idêntico, nome casa com `remote_match` e com o `identity_pattern`), **o atalho de verdade** (`decide()` do `remote-shim-wrapper.py`) aceitando `comment`/`close` do texto REAL da tarefa e recusando `label`, `drain-ack`, `bd comments` e `--include-comments` com a identidade de um revisor do nó, e **mutantes** que reprovam: sonda que falha lida como "cabe", teto do host ou do template ignorado, teto ilegível suposto grande, linha-lixo contada como sessão, host sem `worktree_rigs` tentado, flag ilegível lida como ligada, sonda sem limite de tempo, ponteiro no slot do nó, sem fallback local, slot que esquece que está no nó.
* Dry-run contra o nó real (acima).
* Os testes vizinhos que contam pontos de spawn foram atualizados de propósito: `session-new-bounded.selftest.sh` (3→5: +2 spawns do nó) e `gate-spawn-err-capture.selftest.sh` (2→3). `pool-prompt-skill-mention.selftest.sh` mantém as 10 falhas que já existem na main (batista-*, thies-*, fragmento town-deltas); o template novo passa.

**Inferido:** o engine só enxerga o template novo depois de recarregar a config; o dispatcher é lido a cada rodada; o `idle_timeout` de 10 min recolhe a sessão ociosa do nó.

**NÃO testado (só com a flag, depois da 1.6):** uma revisão de verdade no nó; o tempo do `wt-add` para este papel; o `claude-headless` do nó abrindo o prompt; o resgate por comentário com o texto real de um revisor do nó; a equivalência de veredito (o critério da história); o efeito da falta do overlay.

## Limites

* A lib só olha o `list-running` do provider: não vê CPU, memória nem a carga do nó. A ocupação por medição é a ga-2hd02v.1.11.
* Um estouro do `session new` no nó deixa, no pior caso, uma sessão ociosa por até 10 min.
* Sessões remotas não entram no headroom do mini nem no janitor.
* O teste de equivalência exige a flag: antes dela não há como medir.
