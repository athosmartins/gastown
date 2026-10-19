# wa-worker no nó Hetzner: só bead de código, sem dado de lead/cliente · runbook

## Contents

• Regra e estado (INERTE) · O que há no repositório · Como o classificador decide · A escada de modos do Pilot · Auditoria dos `wa-worker*` do Pilot
• Como ligar, passo a passo · Como desligar · O que depende de outras histórias (1.6, 1.13) · O que não foi provado

Bead ga-2hd02v.1.10 (história de ga-2hd02v.1, "sessão remota no servidor Hetzner"). Regra do Athos (18/10): **nenhum dado de lead/cliente no nó**. Por isso a bead do WhatsApp Automation só vai ao nó quando é "código + teste sem banco real"; o resto roda no mini, como hoje.

## Regra e estado (INERTE)

**Estado desta entrega: construído, testado, e desligado.** Nada aqui muda o despacho até alguém seguir "Como ligar". Sem ligar: nenhuma bead é classificada pelo Pilot, nenhuma leva `gc.routed_to=wa-worker-remote`, o agente `wa-worker-remote` tem `min_active_sessions = 0` (não nasce sessão) e o host não tem o papel `wa-worker` em `worktree_rigs`.

O Mayor liberou a construção em paralelo à 1.6 (18/10 20:45) e pediu a ativação viva só depois do flip da 1.6 provado. As duas provas que a história pede, **3 beads reais entregues pelo nó** e **varredura do nó sem arquivo de dado de lead**, dependem disso e da 1.13, então estão aqui como passos de ligar, não como feitas.

## O que há no repositório

| Peça | Arquivo | O que faz |
|---|---|---|
| Classificador | `scripts/wa-node-classify.py` (+ `.selftest.sh`) | Lê o `bd show --json` de uma bead no stdin e responde `node`, `mini` ou `unknown`. Só lê. |
| Despachante | `scripts/wa-node-dispatch.sh` (+ `.selftest.sh`) | `check`, `apply`, `release`: classifica e, no `apply`, atribui a bead ao nó numa escrita só, com comparação atômica e conferência. |
| Agente | `agents/wa-worker-remote/` | O pool do nó: 0..1 sessão, `idle_timeout` 15 min, prompt de worker remoto. |
| Gancho do Pilot | `_pilot_wa_node_decide` em `packs/town-deltas/assets/pilot-dispatcher.sh` (+ `pilot-dispatcher.wa-node-route.selftest.sh`) | Chama o despachante. **Padrão `off`.** |
| Prod test | `packs/town-deltas/assets/prod-tests/gascity/story-ga-2hd02v.1.10.sh` | Roda os três selftests contra a árvore viva e confere que tudo está inerte. Não prova entrega nenhuma. |

Códigos de saída do despachante (o chamador que não entende um código trata como "fica no mini"): **0** feito · **10** fica no mini · **11** não consegui ler ou decidir · **12** não elegível agora (já tem dono ou rota, slot do nó ocupado, perdeu a corrida) · **13** escrita não confirmada · **2** uso.

**O que o despachante faz com o classificador (terceiro estado, ga-9636op).** O exit code do classificador só vale junto com o JSON que ele imprime: `0` exige `verdict: node`, `10` exige `mini`, `11` exige `unknown`. Classificador que caiu, foi morto, não imprimiu, imprimiu o que não se lê, saiu com outro código ou cujo código e veredito discordam vira **11**, sem escrita, com uma linha `classify:11` no log; o código cru dele nunca chega ao chamador (o Pilot leria 12, 13, 124 e 137 como "não elegível" ou "a escrita pode ter acontecido"). Quando a conferência depois da escrita reprova, o despachante tenta desfazer e **relê** a bead: só diz "desfeita" se não sobrou nem dono nem rota do nó; senão o log registra `conferencia-falhou-NAO-desfeito`, a mensagem pede conferência à mão e a bead pode estar atribuída ao nó.

Log de cada decisão: `$GC_CITY/.gc/wa-node-route.jsonl` (uma linha por chamada, tanto do despachante quanto do gancho).

## Como o classificador decide

A primeira regra que casa vale. O texto da bead nunca é gravado de volta.

1. Entrada que não é bead (JSON ilegível, sem id/título, grande demais) → `unknown`.
2. Etiqueta `node:mini` (decisão humana) ou bead do tipo epic → `mini`.
3. **Duras** (nem `node:ok` vence) → `mini`: caminho citado que o **filtro real do rsync** (`scripts/hetzner-rsync-filter.wa.txt`, medido com `rsync -n` sobre uma árvore temporária, com 3 canários) ou a lista mac-only (`scripts/hetzner-mac-only.txt`) não deixa chegar ao nó; caminho absoluto, `..` ou fora do formato; telefone ou CPF no texto da bead (formas copiadas de `scripts/hetzner-pii-scan.py`), porque o texto da bead viaja ao nó.
4. **Moles** (palavras de recurso vivo: banco real, credencial, host Mac) → `mini`, a menos que a etiqueta humana `node:ok` esteja na bead; nesse caso o motivo `moles-ignoradas` fica na resposta.
5. **Prova positiva**: ao menos um teste citado e ao menos um arquivo de código citado, ambos pelo filtro → `node` com `basis: text`. A etiqueta `node:ok` dispensa a prova → `node` com `basis: label`. Sem nenhuma das duas → `unknown`.

Palavras só informativas (produção, deploy, tela, lead, cliente, terreno...) não bloqueiam; vão para o campo `info`, que o jsonl guarda para medir.

**Três estados, sempre.** Filtro ilegível, `rsync` mudo, canário errado, lista mac-only ilegível, exceção qualquer → `unknown`, que roda no mini. Nenhuma falha de leitura vira `node`.

**Calibração (19/10, 400 beads WA já fechadas):** 12 `node`, 221 `mini`, 167 `unknown`. Só ~4% das beads citam teste e código no texto. Para o gargalo real, o caminho prático é a etiqueta `node:ok`, posta por humano; o modo `shadow` mede quantas mais passariam.

**O limite.** É heurística de texto. O texto pode omitir que um teste abre um banco. O resíduo cai no nó como teste vermelho (o banco não existe lá) e a bead volta ao mini: custo de tempo, não vazamento, porque o dado não chega ao nó de qualquer forma (o filtro de sincronização segura).

## A escada de modos do Pilot

`PILOT_WA_NODE_ROUTE`, lida a cada chamada. Qualquer valor fora destes quatro (vazio, "on", "AUTO") vale `off`.

| Modo | O que faz |
|---|---|
| `off` (padrão) | Nada roda. O gancho volta antes de ler qualquer coisa. |
| `shadow` | Chama `wa-node-dispatch.sh check` e grava a linha no jsonl. **Nunca muda o despacho.** |
| `label` | Como `shadow`, e a bead que o classificador manda ao nó **por causa de `node:ok`** é atribuída ao nó (`apply --basis label`). |
| `auto` | Como `label`, e também a que se prova só pelo texto (`apply --basis any`). |

O gancho só age quando o alvo é o pool `wa-worker` e o id é `wa-*`. Retorno: **0** atribuída ao nó (o despacho troca o alvo para `wa-worker-remote`, que tem braço próprio no `case` do spawn: **sem** `gc session new`, **sem** carimbar `gc.routed_to=wa-worker`); **1** nada foi escrito, segue no mini; **2** a escrita pode ter acontecido e não sei dizer (rc 13 ou estouro de prazo no meio): o Pilot solta a claim e **não despacha nessa varredura**, e a próxima varredura lê de novo. No evento `pilot_sweep` isso aparece como `results.wa_node_unknown` e conta em `failed_other` (falha a olhar, não recusa de política).

A sessão do nó é criada pelo **pool**, não pelo Pilot: é a receita da 1.6 (`bd update --assignee <alias>-1 --status in_progress --set-metadata gc.routed_to=<template>`). Um `gc session new` manual faria duas sessões e o `crew-session-dedup` mataria uma.

## Auditoria dos `wa-worker*` do Pilot

`wa-worker-remote-1` casa com `wa-worker-*` e `wa-worker*`; o pool do mini não pode contá-lo nem re-carimbá-lo por engano. Resultado da leitura de `pilot-dispatcher.sh` (por grep dos padrões, com leitura do entorno só nos três pontos de risco; os demais foram classificados pela linha do padrão e pelo comentário vizinho, **não** seguidos de ponta a ponta):

* **Certo como está** (o nó é pool efêmero, não crew nomeada): os `case` de dono que tratam `wa-worker|wa-worker-*` como "não é crew" (exclusão de sinal de domínio, guarda de dono, `_skip_reuse`, reclamação de bead, filtro de assignee explícito).
* **Certo como está** (nome exato `wa-worker`, então o nó **não** entra na conta do mini): contagem de sessões por `.template=="wa-worker"`, demanda de pool por `.routed_to == "wa-worker"`, teto `PILOT_WA_WORKER_MAX`, `_pilot_pool_topup`. Uma bead no nó não pede nem consome vaga do pool do mini.
* **Risco, e por que não é alcançado**: `_pilot_priority_yield_release` re-carimba `gc.routed_to=wa-worker` para `wa-worker|wa-worker-*`; `_pilot_pool_rig` e `_pilot_pool_store_verdict` mapeiam `wa-worker*` para o pool do mini. Os três só são chamados **antes** do gancho, com o alvo ainda `wa-worker` (chamadas nas linhas ~12983 e ~13410, o gancho está em ~13584). Depois do gancho, o `_SLING_TARGET` só aparece no `case` do spawn e no log de conclusão.
* **A observar nas primeiras beads reais** (não provado aqui): o `inflight-reclaim-guard` e o teste de dono ativo (`_session_is_active_owner`) com o assignee `wa-worker-remote-1`, cuja sessão roda no host remoto; e o limite de 25 min sem sessão viva e sem commit. Se o Pilot reclamar uma bead do nó cedo demais, a primeira suspeita é esta.

## Como ligar, passo a passo

Pré-condição: o flip da ga-2hd02v.1.6 provado (o `dog-remote` entregando de verdade). Decisão do Mayor, não de quem constrói.

1. **Host.** Em `.gc/session-ssh.json`, no host `hetzner`, acrescentar `"wa-worker": "whatsapp_automation"` a `worktree_rigs` (papel → rig; o papel é o que vem antes de `-remote-`). Conferir antes que o espelho do WA existe no nó (`docs/runbooks/hetzner-git-mirror.md`). Sem isto a sessão `wa-worker-remote-1` não ganha worktree e o provider recusa o `start`.
2. **Agente.** Conferir que o `wa-worker-remote` aparece entre os agentes da cidade, do mesmo jeito que se conferiu o `dog-remote` na 1.6. `min_active_sessions = 0` deixa a sessão só nascer quando uma bead for atribuída.
3. **Prova que falta, a mais importante: o pool enxerga a bead do repositório do WA?** Um agente de pool sem `dir=` lê só a loja da cidade (HQ); a bead do WA mora na loja `whatsapp_automation`. Os comentários do Pilot dizem que o `wa-worker` do mini opta por não ser criado pelo supervisor e é lançado pelo Pilot. Atribuir a bead ao `wa-worker-remote-1` pode, por isso, **não** criar a sessão. Teste: com `PILOT_WA_NODE_ROUTE=off`, rodar `scripts/wa-node-dispatch.sh apply <bead node:ok de prioridade baixa> --basis label` à mão e esperar a sessão nascer em até uma varredura do pool. Se não nascer: (a) dar `dir = "whatsapp_automation"` ao agente (conferir o nome de sessão que isso produz: o `remote_match` exige `-remote-`), ou (b) criar a sessão pelo mesmo caminho que o Pilot usa para o `wa-worker`, mas só se (a) falhar e com o `crew-session-dedup` em mente. Desfazer com `release`.
4. **Semântica de `--assignee ""` e `--if-assignee ""` no `bd` real.** O selftest usa um `bd` de mentira; o `bd` de verdade não foi exercitado (criar uma loja descartável foi negado neste ambiente). A conferência de leitura do `apply` e do `release` desfaz e sai 13 se o `bd` não se comportar como o esperado, então o passo 3 já serve de prova; registrar o que o `bd` real fez.
5. **`shadow`.** Pôr `PILOT_WA_NODE_ROUTE=shadow` no `EnvironmentVariables` do plist do Pilot (`~/Library/LaunchAgents/com.gascity.pilot.plist`, o mesmo lugar do `PILOT_WA_WORKER_MAX`) e recarregar o Pilot. Deixar rodar alguns dias. Ler `$GC_CITY/.gc/wa-node-route.jsonl`: quantas `node`, quantas por `label` e por `text`, e o campo `info` das que passaram. Nenhuma bead muda de rota neste modo.
6. **`label`.** Alguém (Athos ou Mayor) põe `node:ok` em **3 beads reais de código e baixo risco**. Pôr `PILOT_WA_NODE_ROUTE=label`. Acompanhar cada uma até o branch no espelho e o `gate-done`. **Hoje o `gate-done` remoto e a liberação da bead dependem da 1.13**: enquanto ela não existir, quem fecha o ciclo é o Mayor, com `scripts/wa-node-dispatch.sh release <bead>` depois de entregue (solta assignee e rota; sem isso uma sessão nova renasce a cada ~15 a 20 min).
7. **Varredura do nó.** Depois das 3 entregas: `scripts/hetzner-remote-git.sh scan` e `scripts/hetzner-audit.sh` (ver `docs/runbooks/hetzner-hardening.md`). Critério da história: nenhum arquivo de dado de lead/cliente. Registrar a saída na bead.
8. **`auto`** só depois de várias entregas sem `athos.node_recusa` (a marca que o worker remoto põe quando a bead não cabe) e com a taxa de acerto medida no `shadow`.

## Como desligar

`PILOT_WA_NODE_ROUTE=off` (ou tirar a variável) e recarregar o Pilot. Para cada bead ainda no nó: `scripts/wa-node-dispatch.sh release <bead>`; só toca bead cujo assignee é `wa-worker-remote-1` **e** cuja rota é `wa-worker-remote`, nunca a de outro dono. A sessão ociosa se encerra em 15 min. Tirar `"wa-worker"` de `worktree_rigs` fecha também o caminho do provider.

## O que depende de outras histórias

* **1.6** (flip do `dog-remote`): pré-condição para ligar. A receita de atribuição vem dela.
* **1.13** (`gate-done` remoto e liberação do assignee e da rota depois da entrega): o `release` daqui é a ponte manual. O worker remoto roda `gate-done` pelo atalho; que o gate aceite uma bead entregue pelo nó, e libere a rota sozinho, é da 1.13.

## O que não foi provado

Dito sem enfeite, porque o selftest passa sem nenhuma destas:

* Nenhuma bead real foi ao nó. As "3 beads" e a varredura da história são os passos 6 e 7 acima.
* O `bd` real não foi exercitado com `--assignee ""` / `--if-assignee ""` (passo 4).
* Não se provou que o pool cria a sessão para uma bead da loja do WA (passo 3). É o ponto que mais pode obrigar a mudar o desenho.
* A auditoria do Pilot acima é de leitura, não de execução; o `shadow` com tráfego real é o teste.
* **Leitura das sessões (`gc session list --json`)**: devolve um objeto `{"ok":…,"sessions":[…]}` (medido em 19/10), não um array solto; o despachante só aceita esse formato e trata qualquer outro como ilegível (sai 11, a bead fica no mini). Na mini carregada a chamada levou 14–22 s, mais que os 20 s do prazo geral, então ela tem prazo próprio (`WA_NODE_SESSION_TIMEOUT`, padrão 60 s). Um `apply --dry-run` real de ponta a ponta (classificador de mentira, bead WA real aberta) levou ~26 s e saiu 0 sem escrever nada; o `apply` de verdade soma a escrita, a releitura e o comentário, e o prazo do Pilot (`PILOT_WA_NODE_TIMEOUT`, 90 s) cobre isso com folga. Se a mini ficar ainda mais lenta e o `apply` passar de 90 s, o Pilot trata como resultado desconhecido (`wa_node_unknown`), solta a própria reivindicação e não despacha para o mini. Se o corte cair depois da escrita, a bead já ficou atribuída ao nó (o `release` do despachante a devolve); se cair antes, ela só espera o próximo ciclo.
* Selftests (a contagem "N/N ok" inclui os mutantes): classificador 67 itens, 17 deles mutantes; despachante 104 itens, 20 mutantes; gancho do Pilot 92 itens, 18 mutantes. Todos com `bd`/`gc`/`rsync` de mentira ou o filtro real em árvore temporária, nunca contra o nó.
