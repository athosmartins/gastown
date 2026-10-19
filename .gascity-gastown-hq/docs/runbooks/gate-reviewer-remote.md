# Revisor do gate no nó Hetzner (gate-reviewer-remote) · runbook

Bead ga-2hd02v.1.9 (filha da ga-2hd02v.1). Mayor, 19/10: construir e provar no nó com sessão de teste ou dry-run **já**; a ATIVAÇÃO viva (flag, config do host) só depois do flip da 1.6 provado. **A 1.6 estava aberta quando esta fatia terminou: tudo aqui está pronto e INERTE.**

## O que é

O gate abre N revisores por rodada, todos no mini (`gate-reviewer`). O template `gate-reviewer-remote` tem `-remote-` no nome da sessão, e o `remote_match` do provider híbrido o manda ao nó. A cada revisor o dispatcher escolhe: **nó primeiro; local só se o nó estiver cheio, fora do ar, ilegível, ou se abrir a sessão no nó falhar.**

Peças: `agents/gate-reviewer-remote/` · `packs/town-deltas/assets/gate-remote-reviewers.lib.sh` (só ESCOLHE; só pergunta ao nó o `list-running`) · `quality-gate-dispatcher.sh` (Step 7 e re-convocação) · `gate-remote-reviewers.selftest.sh` (hermético) · a flag `$GC_CITY/.gc/gate-remote-reviewers.on`, que **NÃO existe**: sem ela o gate roda como antes.

## Desenho

* **Flag em 3 estados:** ligada, desligada, **ilegível** (pasta/link/arquivo que não se lê, `GC_CITY` vazio). Ilegível = local, e o log diz `flag UNREADABLE`.
* **Nó em 4 respostas:** `room`, `full`, `unready`, `unknown`. Só `room` vai ao nó; `unknown` (ssh caiu, `list-running` passou de 30 s, linha estranha, config ilegível, `timeout` ausente) **não é `room`**.
  `room` = vivas no nó < `cap` do host (`.gc/session-ssh.json`) **e** revisores remotos vivos < `max_active_sessions` do template (2). `unready` = o host não tem `real_sessions_released_by` (start sairia 12) ou `worktree_rigs["gate-reviewer"]` (sairia 13).
* **Uma tentativa no nó**; falhou, voltou vazio ou estourou → a MESMA etapa abre o local. Um estouro tem desfecho desconhecido: no pior caso sobra uma sessão ociosa no nó até o `idle_timeout` (10 min). Nunca dois revisores para o mesmo slot.
* **Slot que morreu no nó é substituído no LOCAL.** Slot que era local é oferecido ao nó como spawn novo.
* **Tarefa idêntica, palavra por palavra** (um texto por slot, renderizado antes de escolher o template). O revisor do nó recebe sempre a tarefa INTEIRA no nudge, nunca o ponteiro: o atalho do nó não devolve corpo de comentário (`bd comments` e `--include-comments` voltam rc 77).
* **Veredito por `bd comment` + `bd close`.** `bd label add|remove` e `drain-ack` voltam rc 77; o prompt manda não repetir e entregar `VERDICT: PASS|FAIL …` no comentário, que o dispatcher já lê (ga-86l90a8, ga-w7pm55). O atalho NÃO foi alargado.
* **Não mexe em** janitor, headroom do mini, 2º revisor E5 e `refino-gate-dispatcher` (locais). O `cleanup_reviewer_sessions` do fim da rodada fecha as remotas pelos ids.

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

**São do Mayor:** ligar a flag e quando · editar `worktree_rigs` do host (passo 5) · alargar o atalho do nó para `bd label add verdict:*`/ler comentários (não feito; a allowlist é a fronteira de segurança) · o teto do template (2) e o transbordo (ga-2hd02v.1.11) · o critério de aceite das 3 revisões.

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
2. **Sessão de teste no nó (depois do passo 5, ANTES da flag).** `gc session new gate-reviewer-remote --no-attach --json`, bead de veredito de brinquedo atribuída ao nome da sessão e uma tarefa curta no nudge. Conferir: o `bd list --assignee` achou a bead; o `label` voltou rc 77 sem repetir; `VERDICT: …` entrou e a bead fechou; depois do `idle_timeout` a sessão sumiu do `scripts/gc-session-ssh list-running`.
3. **As 3 revisões reais (com a flag).** Por revisão: sha, tempo até o 1º turno e até o veredito, canal (rótulo ou só comentário), veredito e achados. Rodar **a mesma sha** pelo caminho local e comparar PASS/FAIL e, no FAIL, os bloqueios. Quem decide se 3 de 3 bastam é o Mayor.

Log do dispatcher: `Reviewer N: node has room - remote reviewer first` (nó) · `Reviewer N: full|unready|unknown (…) - local reviewer` (motivo na linha) · `node spawn gave no session … falling back` · `Re-convene: slot N ran on the node and died` · `remote-reviewer flag UNREADABLE` · `flag file exists but … lib.sh is NOT loaded`. Depois de uma rodada `list-running` não deve listar `gate-reviewer-remote-*`.

## Diferenças conhecidas (revisor do nó × local)

1. **Sem o overlay `pool-reviewer`** (o provider ignora `overlay_dir` e `env`): a diferença mais provável de mudar um veredito. O bloco "THE THIRD STATE" do prompt é idêntico ao do local (comparado no selftest).
2. **Worktree do rig `gascity` vem do espelho:** o branch em revisão pode não estar lá (o prompt manda dizer no veredito).
3. **Canal de volta só por comentário**, sem rótulo `verdict:*`; a 1ª linha tem de ser `VERDICT: PASS|FAIL`.
4. **Sem `drain-ack`:** a sessão ociosa fecha pelo `idle_timeout` de 10 min (local: 1 h) e segura uma vaga do nó até lá.
5. **`start` mais lento:** o `wt-add` puxa o espelho (piso de 150 s) e segura o `flock` do host. **Não medido para este papel.**
6. **1º turno de procura:** `bd list --assignee` pode voltar vazio com a bead certa (ga-mo7q); o prompt manda confirmar por `bd show <id> --json`.

## Medido, inferido, não testado

**Medido (19/10, hermético):** o selftest cobre a escolha (flag em 3 estados; nó room/full/unready/unknown; sonda presa; config ruim; `/bin/bash` 3.2 sob `set -euo pipefail`), a costura no dispatcher (lib ausente/quebrada; spawn node-first em 7 desfechos; re-convocação; ponteiro desligado no slot do nó), o template (bloco THIRD STATE idêntico; nome casa com `remote_match` e `identity_pattern`), o `decide()` REAL do `remote-shim-wrapper.py` (aceita `comment`/`close` do texto real da tarefa; recusa `label`, `drain-ack`, `--include-comments`) e 4 mutantes da escolha (sonda com rc≠0 lida como room, teto ilegível, config lixo, flag ilegível). Os selftests vizinhos que contam pontos de spawn foram atualizados de propósito (`session-new-bounded` 3→5, `gate-spawn-err-capture` 2→3); o `pool-prompt-skill-mention` mantém as 10 falhas da main.

**Inferido:** o engine só enxerga o template novo após recarregar a config; o `idle_timeout` recolhe a sessão ociosa do nó. **NÃO testado (só com a flag, depois da 1.6):** revisão de verdade no nó; tempo do `wt-add`; o `claude-headless` do nó abrindo o prompt; o resgate por comentário com texto real; a equivalência de veredito; o efeito da falta do overlay. A lib só olha o `list-running`: não vê CPU/memória do nó (a medição é a ga-2hd02v.1.11).
