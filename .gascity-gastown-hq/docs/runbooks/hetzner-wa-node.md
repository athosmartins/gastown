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

Códigos de saída do despachante (o chamador que não entende um código trata como "fica no mini"): **0** feito · **10** fica no mini · **11** não consegui ler ou decidir · **12** não elegível agora (já tem dono ou rota, slot do nó ocupado, perdeu a corrida) · **13** escrita não confirmada (a releitura não achou nada nosso, mas um `bd update` morto por prazo ainda pode entrar no servidor depois; o gancho do Pilot segura a bead) · **2** uso. O `apply` recusa (12) toda bead que já tem rota, inclusive `wa-worker` carimbada numa varredura anterior (por exemplo, na espera do teto de sessões do pool): essa bead não migra para o nó sozinha. É a direção inerte, ela fica no mini.

**O que o despachante faz com o classificador (terceiro estado, ga-9636op).** O exit code do classificador só vale junto com o JSON que ele imprime: `0` exige `verdict: node`, `10` exige `mini`, `11` exige `unknown`. Classificador que caiu, foi morto, não imprimiu, imprimiu o que não se lê, saiu com outro código ou cujo código e veredito discordam vira **11**, sem escrita, com uma linha `classify:11` no log; o código cru dele nunca chega ao chamador (o Pilot leria 12, 13, 124 e 137 como "não elegível" ou "a escrita pode ter acontecido"). Quando a conferência depois da escrita reprova, o despachante tenta desfazer e **relê** a bead: só diz "desfeita" se não sobrou nem dono nem rota do nó; senão o log registra `conferencia-falhou-NAO-desfeito`, a mensagem pede conferência à mão e a bead pode estar atribuída ao nó. O mesmo vale quando o próprio `bd update` da escrita falha (rc diferente de 0 e de 13: prazo 124, morto 137, resposta perdida): o rc não diz o estado, porque o servidor pode ter gravado. O despachante relê como na conferência: bead inteira do nó = a escrita pegou e só a resposta se perdeu (segue, sai 0, o log anota o rc do `bd`); algo nosso = desfaz e relê; nada nosso = **13** "nada garantido" (um update morto por prazo ainda pode entrar depois, só uma releitura posterior resolve, e o gancho do Pilot segura a bead). Nunca diz "desfeita" sem ter relido.

Log de cada decisão: `$GC_CITY/.gc/wa-node-route.jsonl` (uma linha por chamada, tanto do despachante quanto do gancho).

## Como o classificador decide

A primeira regra que casa vale. O texto da bead nunca é gravado de volta.

1. Entrada que não é bead (JSON ilegível, sem id/título, grande demais) → `unknown`.
2. Etiqueta `node:mini` (decisão humana) ou bead do tipo epic → `mini`.
3. **Duras** (nem `node:ok` vence) → `mini`: caminho citado que o **filtro real do rsync** (`scripts/hetzner-rsync-filter.wa.txt`, medido com `rsync -n` sobre uma árvore temporária, com 3 canários) ou a lista mac-only (`scripts/hetzner-mac-only.txt`) não deixa chegar ao nó; caminho absoluto, `..` ou fora do formato; telefone ou CPF no texto da bead (formas copiadas de `scripts/hetzner-pii-scan.py`), porque o texto da bead viaja ao nó.
   **Exceção do espelho (ga-2hd02v.3).** O worker do nó recebe a árvore pelo **espelho git** (`hetzner-git-mirror.md`), não pelo rsync de teste; o espelho entrega tudo menos Seção 1 do filtro, `.beads/ data/ logs/` e os arquivos que a varredura de **conteúdo** sinalizou (≥20 telefones ou ≥3 CPFs). Por isso um `.md` que o rsync não lista (`docs/…`, `DESIGN.md`) deixa de ser "fora do filtro" quando, ao mesmo tempo: o filtro do rsync não o **nega por regra** (a visão "só negações" do mesmo arquivo, com o `- *` final trocado por `+ *`, segura `shared/`, `logs/`, `data/` e os formatos de dado) e o filtro que o espelho serve (`hetzner-mirror.sh spec-out whatsapp_automation`, que só responde com a varredura cobrindo as pontas) também não o nega. Só `.md`: json/txt/yaml com nome neutro seguem fora (é onde mora `docs/auto_response/ab_results/*.json`). O `.md` entregue entra em `info` como `via-espelho:<caminho>` e **não conta como prova** (não é código nem teste). Espelho em atualização (rc 75), ilegível, filtro cortado ou canário errado → volta à regra anterior (mini) com `espelho-ilegivel:<motivo>` em `info`: o espelho ilegível nunca vira "o espelho entrega". `docs/data_dictionary.md` e os planos/investigações que a varredura sinalizou continuam `mini`.
4. **Moles** (palavras de recurso vivo: banco real, credencial, host Mac) → `mini`, a menos que a etiqueta humana `node:ok` esteja na bead; nesse caso o motivo `moles-ignoradas` fica na resposta.
5. **Prova positiva**: ao menos um teste citado e ao menos um arquivo de código citado, ambos pelo filtro → `node` com `basis: text`. A etiqueta `node:ok` dispensa a prova → `node` com `basis: label`. Sem nenhuma das duas → `unknown`.

Palavras só informativas (produção, deploy, tela, lead, cliente, terreno...) não bloqueiam; vão para o campo `info`, que o jsonl guarda para medir.

**Três estados, sempre.** Filtro ilegível, `rsync` mudo, canário errado, lista mac-only ilegível, exceção qualquer → `unknown`, que roda no mini. Nenhuma falha de leitura vira `node`.

**Medido com a exceção do espelho (20/10, 167 beads WA abertas e `story:approved`):** antes 4 `node` / 110 `mini` / 53 `unknown`; depois 5 / 99 / 63. 21 beads citam algum `.md` entregue pelo espelho; 10 saíram de `mini` para `unknown` (citam doc, não citam código nem teste) e 1 para `node` (`wa-h5dd0l.2`: código + teste + runbook). O ganho em `node` é pequeno de propósito: o que segura os `unknown` não é o caminho, é a **falta de prova** (63 `unknown`: 33 citam código sem teste, 25 não citam caminho; os 5 restantes não foram classificados nesta medição) e, nos `mini`, as **moles** (46 dos 99 `mini`: palavra de banco/credencial/host Mac; os demais `mini` não foram detalhados aqui).

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

O gancho só age quando o alvo é o pool `wa-worker` e o id é `wa-*`. Retorno: **0** atribuída ao nó (o despacho troca o alvo para `wa-worker-remote`, que tem braço próprio no `case` do spawn: **sem** `gc session new`, **sem** carimbar `gc.routed_to=wa-worker`); **1** nada foi escrito, segue no mini; **2** a escrita pode ter acontecido e não sei dizer (rc 13, estouro de prazo no meio, ou o despachante morto por sinal: 124, 137, 143 e qualquer rc de 128 a 255; 125–127 e os demais códigos são "nada rodou" e voltam 1): o Pilot solta a claim e **não despacha nessa varredura**, e a próxima varredura lê de novo. No evento `pilot_sweep` isso aparece como `results.wa_node_unknown` e conta em `failed_other` (falha a olhar, não recusa de política).

**Com o mini no piso de disco (ga-8okir7).** A varredura pausada por disk floor com `PILOT_NODE_FIRST=on` faz a passada só-nó (`hetzner-capacity.md`, ga-2hd02v.1.20), que antes só deixava passar bead de dog do HQ e por isso soltava toda bead de WA com o nó ocioso. Com `label` ou `auto` ela agora leva ao gancho a bead de WA do store do WA, no pool `wa-worker`. Antes da claim, `_pilot_node_only_wa_pre` lê o JSON da candidata (sem dono, sem rota, `node:ok` no modo `label`) e faz UMA sonda `wa-node-dispatch.sh apply --dry-run` por candidata: a mesma conferência do `apply` (classificador, slot do nó = 1, sessões), sem escrever na bead; só o rc 0 vale, e no máximo `PILOT_WA_NODE_ONLY_PROBES` (padrão 6) por varredura, porque a sonda leva de 1 a ~26 s. Cada sonda acrescenta uma linha curta em `.gc/wa-node-route.jsonl` (é o log do despachante). Depois da claim o gancho decide como sempre; se devolve **1** (não levou, nada escrito) a passada **solta a claim e encerra a tentativa com o desfecho `disk_floor_node_only`** (a bead segue aberta e livre, e é reavaliada na próxima varredura) em vez de seguir ao caminho do pool do mini (carimbo `wa-worker` + `gc session new`), que é o que o piso pausa. `ps-worker` não tem agente no nó (não existe `ps-worker-remote`): a bead de PS segue solta na passada. `off`, `shadow`, `DRY_RUN` e a varredura sem disk floor não mudam. Prova: `pilot-dispatcher.disk-floor-node-only-wa.selftest.sh`.

**Leitura da bead antes do despachante (ga-9636op, gate-fix 1).** Em `label` e `auto` o gancho lê a bead ele mesmo (`bd show --json`, na loja certa, uma vez) ANTES de chamar o script, em três estados: **é do nó** (dono ou rota `wa-worker-remote*`) → **2**, e o script nem roda; **não consegui ler** (o `bd` falhou, saída vazia ou que não é JSON, bead de outro id) → **2**; **lida e não é do nó** → o caminho de sempre, e o rc do script manda. Por quê: o `apply` sai 12 para a bead que já é do nó (in_progress, dono `wa-worker-remote-1`, rota `wa-worker-remote`), e esse 12 lido como "nada escrito" (1) fazia o despacho seguir o caminho do pool do mini, carimbar `gc.routed_to=wa-worker` por cima da rota do nó e criar sessão do mini, a bead nas duas filas. Essa bead chega ao gancho na varredura seguinte a uma escrita que pegou e não deu para confirmar (rc 13 ou 124): a listagem do Pilot não filtra por status e o filtro de dono inativo readmite um dono sem sessão viva. A regra é "bead que já é do nó nunca segue o caminho do pool", qualquer que seja o rc do script (126 e 127, "nem rodou", incluídos). Em `shadow` nada muda no despacho e em `off` nada é lido. As parecidas (dono `wa-worker-1`, rota `wa-worker`, crew `mila-wa`) não são tomadas por do nó. Em `DRY_RUN` o log diz "WOULD route" só quando o `apply --dry-run` sai 0.

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
* A passada só-nó com bead de WA (ga-8okir7) só foi provada com o dispatcher extraído e `wa-node-dispatch.sh` e `bd` falsos: nenhuma varredura viva com o disco do mini abaixo do piso e `PILOT_WA_NODE_ROUTE=label|auto`. A sonda `apply --dry-run` por candidata não foi cronometrada na mini carregada, e o teto de 6 sondas por varredura é palpite a ajustar com o `wa-node-route.jsonl`. O custo em disco do mini de uma sessão remota **não foi medido** (o atalho do servidor não passa `du` nem `ps`): pelo que o runbook do provider descreve, o `start`, o lançador, o tmux e o worktree ficam no host, e no mini ficam o metadado da sessão e as escritas da bead; para medir, `du -sk` no mini antes e depois de uma sessão `wa-worker-remote` em `.gc/agents/wa-worker-remote` (o `work_dir` do agente) e no estado do provider (`<estado>/<host>/running/`, ver `gc-session-ssh.md`).
* O `bd` real não foi exercitado com `--assignee ""` / `--if-assignee ""` (passo 4).
* Não se provou que o pool cria a sessão para uma bead da loja do WA (passo 3). É o ponto que mais pode obrigar a mudar o desenho.
* A auditoria do Pilot acima é de leitura, não de execução; o `shadow` com tráfego real é o teste.
* **Leitura das sessões (`gc session list --json`)**: devolve um objeto `{"ok":…,"sessions":[…]}` (medido em 19/10), não um array solto; o despachante só aceita esse formato e trata qualquer outro como ilegível (sai 11, a bead fica no mini). Na mini carregada a chamada levou 14–22 s, mais que os 20 s do prazo geral, então ela tem prazo próprio (`WA_NODE_SESSION_TIMEOUT`, padrão 60 s). Um `apply --dry-run` real de ponta a ponta (classificador de mentira, bead WA real aberta) levou ~26 s e saiu 0 sem escrever nada; o `apply` de verdade soma a escrita, a releitura e o comentário, e o prazo do Pilot (`PILOT_WA_NODE_TIMEOUT`, 90 s) cobre isso com folga. Se a mini ficar ainda mais lenta e o `apply` passar de 90 s, o Pilot trata como resultado desconhecido (`wa_node_unknown`), solta a própria reivindicação e não despacha para o mini. Se o corte cair depois da escrita, a bead já ficou atribuída ao nó (o `release` do despachante a devolve); se cair antes, ela só espera o próximo ciclo.
* Selftests (a contagem "N/N ok" inclui os mutantes): classificador 133 itens, 40 deles mutantes (20/10, ga-2hd02v.3: 41 itens reprovam no classificador anterior); despachante 121 itens, 20 mutantes; gancho do Pilot 254 itens, 29 mutantes (medidos em 19/10, ga-9636op gate-fix 1). Todos com `bd`/`gc`/`rsync` de mentira ou o filtro real em árvore temporária, nunca contra o nó.
