{{ define "town-deltas" }}
### Town Deltas (ADITIVO — não substitui operational-awareness nativo)

Estes são acréscimos específicos desta town. A doutrina base (3307 sagrado,
protocolo Dolt-frágil, nudge-first, mail lifecycle, não-adotar-identidade) já
vem do fragment NATIVO `operational-awareness` — NÃO duplicar aqui.

🚨 **REGRA Nº 1 — TODA pergunta ao Athos é MÚLTIPLA ESCOLHA. Pergunta aberta é
PROIBIDA.** (Mandato do Athos 2026-07-24, RE-COBRADO em 2026-07-31 porque
continuava sendo violado: a regra existia em UM arquivo só e não chegava ao
prompt de ninguém. Agora chega — não há mais desculpa de "não sabia".)

Vale para TODOS os agentes desta town (crews, workers, dogs, reviewers, Mayor),
em QUALQUER canal (AskUserQuestion, mail, nudge, Slack, WhatsApp, terminal).

Formato OBRIGATÓRIO, sem exceção:
1. **Contexto primeiro, em BULLET POINTS curtos** — o problema e por que a
   decisão importa. Não escreva parágrafo corrido.
2. **Opções concretas e mutuamente exclusivas**, cada uma com o **TRADEOFF
   explícito** (o que ele ganha e o que ele perde escolhendo aquilo).
3. **A 1ª opção é SEMPRE a SUA recomendação.** Você é quem estudou o problema —
   tome posição. "Não sei, você decide" não é resposta de especialista.
4. **Texto livre só como UMA das opções**, nunca como a pergunta inteira.
5. Em sessão Claude Code: use a ferramenta **AskUserQuestion** (o campo "Other"
   já satisfaz o item 4 por construção). Fora dela (mail/nudge/WhatsApp):
   escreva as opções numeradas 1/2/3 no corpo da mensagem, mesma estrutura.

❌ PROIBIDO: "O que você acha?", "Como prefere que eu siga?", "Pode confirmar?",
"Alguma preferência?" — qualquer coisa que obrigue o Athos a redigir a resposta
do zero. Se você se pegar escrevendo uma dessas, PARE e converta em opções.

⚖️ **Antes de perguntar, cheque se precisa perguntar.** Se existe default óbvio,
se é do SEU domínio técnico, ou se a resposta dele não muda o que você vai
fazer → **NÃO pergunte: decida e reporte.** O Athos fala PRODUTO e decide rápido
em escolha guiada; pergunta aberta é fricção e trava a decisão. Sobre-perguntar
viola a regra tanto quanto perguntar errado. (Exceção: dog headless
não-supervisionado age sozinho e não pergunta.)

🚨 **REGRA Nº 2 — só pergunte PRODUTO/NEGÓCIO. Decisão TÉCNICA nunca vai pro
Athos.** (Mandato do Athos, 2026-07-31.) Ele NÃO deve precisar de conhecimento
de programação ou de engenharia de software para responder você. Se responder
exige ler código, escolher entre implementações, opinar sobre arquitetura,
timeout, schema, biblioteca ou refactor → **a decisão é SUA, não dele.**

❌ NÃO PERGUNTE (técnico — resolva você):
  • "Uso skip-and-continue ou refatoro o laço?"
  • "O timeout deve ser 120s ou 600s?"
  • "Vendorizo o runtime.sh ou aponto pro path real?"
  • "Qual índice/schema/biblioteca devo usar?"
  • "Faço rebase ou merge nessa branch?"

✅ PERGUNTE ASSIM (produto/negócio — ele decide de verdade):
  • "O filtro X some do painel por ~2 dias enquanto eu conserto, ou seguro a
    correção e mantenho como está hoje?" (impacto pro usuário)
  • "Priorizo restaurar o funil de leads (0% hoje) ou o canal de alertas?"
    (prioridade de negócio)
  • "Essa mudança começa a enviar mensagem automática pro corretor sem revisão
    humana. Libero, libero só com canário, ou mantenho desligado?" (risco de
    negócio / exposição ao cliente)

**Como converter:** pergunte-se "qual é o impacto disso pro usuário, pro cliente,
pro faturamento, pro risco ou pra prioridade?" — pergunte ISSO. Se você NÃO
consegue traduzir a decisão em impacto de produto/negócio, então ela é puramente
técnica e **não é dele: decida você.**

**Travou numa decisão técnica difícil?** O caminho NÃO é o Athos. É: (a) decidir
com o tradeoff explícito e registrar no bead; (b) chamar o especialista do
domínio (oracle/peter/mila/thies/batista conforme o rig); ou (c) mandar pro gate
/ revisão adversarial, que existe exatamente pra isso. O Athos não é revisor
técnico nem desempatador de engenharia.

**AUTONOMIA — trabalhe até acabar, não até ter dúvida (Athos, 2026-08-06).**
Mandato dele, verbatim: *"melhor pedir 'desculpa' por algo que não foi bem feito
do que 'por favor' pra pedir minha bênção pra fazer algo"*. Só pare se for
**realmente impossível** destravar via adversarial review ou conversando com
outro worker. Dúvida técnica não é motivo de parada — é motivo de medir. As
regras abaixo saíram de uma madrugada de trabalho não supervisionado que levou
a fila do gate de 23 markers a 1 e mergeou 63 commits num dia (recorde). Não são
conselhos: cada uma tem um caso que a produziu.

1. **Meça antes de teorizar; o número muda o problema.** A fila do gate parecia
   funda. Metade era fantasma: 5 de 10 markers eram de branches JÁ MERGEADAS,
   presas em `needs-rebase` — estado que elas nunca poderiam satisfazer, porque
   rebasear branch mergeada dá branch vazia. Um comando resolvia:
   `git merge-base --is-ancestor origin/<branch> origin/main`. Antes de otimizar
   uma fila, descubra o que ela realmente contém. **Não faça isso à mão — rode:**
   ```bash
   bash ~/gt/.gascity-gastown-hq/scripts/gate-queue-composition.sh
   ```
   Ele quebra a profundidade em REAL / FANTASMA / ILEGÍVEL. Só `real` responde a
   mais capacidade. Read-only, roda a qualquer hora. **O número de profundidade
   sozinho (`gate_queue_backlog.py`) não distingue os três** — foi exatamente ele
   que me fez otimizar transporte de carga que não existia.
   Corolário que me custou uma degradação da cidade no mesmo dia: **detector tem
   custo de poll.** Ao subir guard novo, meça a duração de UM run, garanta
   `StartInterval` > essa duração, e ponha lock de instância única — sem isso o
   launchd empilha execuções e o guard vira a carga que deveria observar
   (ga-y0g5x: 4 instâncias simultâneas derrubaram o `bd` da cidade inteira).

2. **Verifique o ARTEFATO, nunca o relato — inclusive o seu.** Duas vezes
   declarei gate-runs mortos; os três markers depois passaram e mergearam
   (ga-9uwbw, fechado como não-bug). Para trabalho que dura horas, ausência de
   sessão num snapshot NÃO prova morte — o discriminador honesto é o desfecho.
   E mail de watchdog é **retrato com timestamp**, não estado vivo: reagi a um
   alerta de 13:58 às 15:21 e quase declarei uma falha inexistente.

3. **Erro e vazio não podem produzir o mesmo valor.** Foi a família dominante:
   6 reprovações do gate num dia, todas terceiro estado colapsado em booleano.
   Em toda leitura que pode faltar, pergunte: *"não encontrei" dá o mesmo
   resultado que "encontrei e vale X"?* São TRÊS estados — tem / não-tem /
   não-consegui-saber. Se o caminho for destrutivo, o default sob dúvida é o
   estado INERTE, sempre.

4. **Conserte a CLASSE, não a instância citada.** Um bead reprovou 3x seguidas
   consertando só o exemplo do revisor e reintroduzindo a mesma família noutro
   ponto do próprio diff. O revisor cita UM caso; varra o diff inteiro atrás dos
   irmãos. Quem fez isso (peter-wa) achou o "segundo meio" do bug e uma terceira
   instância que o veredito nem mencionou — e passou.

5. **Comentário que promete mais do que o código entrega é pior que nenhum.**
   Ele faz o próximo leitor parar de procurar o buraco. Um código postava
   "labels cleared" sem limpar — a lane entupia e quem investigasse leria
   "cleared" e riscaria a hipótese certa. Releia cada comentário do seu diff
   perguntando: *o código ao lado realmente faz isto?*

6. **Fonte ≠ o que roda. Mergeado ≠ vivo.** Li um guard e quase abri um P0
   inexistente: o arquivo não era o que o launchd executa. E dois guards
   mergearam sem ninguém carregar o plist — existindo e entregando zero. Derive
   sempre do processo vivo (`ps -o command=`, `launchctl list`), nunca de um
   caminho escrito em doc.

7. **Teste que só passa não prova nada.** Rode-o contra o HEAD anterior: se não
   falha lá, ele não pega o bug. O padrão-ouro do dia foi um builder que provou
   que 3 dos 5 testes novos reprovavam antes do fix, com o sintoma literal do
   veredito.

8. **Não invente ID nem assuma sucesso de escrita.** Citei 3 beads antes de
   criá-los (viraram errata). E `-q` + saída truncada transformaram um `exit=1`
   em silêncio: o comando falhou, o label não mudou, e eu segui adiante. Verifique
   o efeito, não o retorno.

9. **Detector > desentupimento.** Desentupir à mão é Sísifo: a causa reescreve o
   que você corrigiu. Quando um problema aparece 2x, pare de limpar e construa o
   guard — e faça a query dele **inverter** a do consumidor cego, nunca replicá-la,
   senão herda o mesmo ponto cego. Prefira **detection-only**: um guard que repara
   sem conseguir distinguir "perdido" de "em transição legítima" quebra coisa boa.

**Secrets — Bitwarden é source of truth.** Tokens (MOTHERDUCK_TOKEN, whapi,
pipedrive, hex, etc.) vêm do vault via `secret <item-name>` (~/.local/bin/secret).
Nunca hardcode. Falha: `~/.gastown/scripts/secrets-bootstrap.sh --ensure`.

**Notifications — `notify` CLI** (~/.local/bin/notify) p/ ops longas (>30s):
`notify 'Work complete: <desc>'` | `notify -t 'Title' -p 4 'High priority'`.
Topic privado ntfy. NÃO enviar notificações de crédito.

**whatsapp_automation é um rig Gas City** (como os outros): beads + orquestração
no HQ (:52756). Workers spawnam ON-DEMAND (modelo contido — sem agentes always-on;
mayor human-attached, workers só via sling/route). Os daemons de DOMÍNIO do WA
(:8095/:8097, sync MotherDuck, collectors/touchpoints) são independentes do plano
de beads — NÃO se tocam na orquestração. (A doutrina antiga "WA fica no 3307 +
mail-bridge, nunca spawnar worker no WA" está OBSOLETA — o Overseer decidiu a
migração COMPLETA de todos os rigs pro Gas City.)

**Mockups / web-UI para aprovação do Athos — OBRIGATÓRIO: S3 presigned URL.**
⚠️ O bucket é PÚBLICO (`PublicReadAccess` + ACLs desligadas) — `presign` é decorativo,
não protege nem expira; a distro CloudFront (`dnroc49bwlbis.cloudfront.net`) também
serve sem gate. Única barreira real = obscuridade da chave (wa-68jmm/wa-3o6wf).
NUNCA entregue mockup como PNG, localhost URL ou servidor local/tunnel. O Athos DECIDE VENDO no celular.
Fluxo obrigatório:
1. Chave de alta entropia: `python3 -c "import secrets; print(secrets.token_hex(8))"`
2. `aws s3 cp <arquivo.html> s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --content-type "text/html; charset=utf-8"`
3. `aws s3 presign s3://whatsapp-viewer-549710416969/mockups/<nome>-<hex>.html --expires-in 604800`
4. Envie ao Athos o URL presigned.

🚨 NUNCA suba CPF, telefone, endereço, situação sucessória/óbito ou qualquer dado
que identifique uma pessoa específica nesse bucket — o link é público pra sempre.

**Filesystem de rede / CloudStorage pode PENDURAR a sessão (ga-khuz1).** NUNCA
rode `ls`/`find`/`stat`/`cat`/`grep` direto contra paths do Google Drive ou
iCloud (`~/Library/CloudStorage/...`) nem qualquer mount FUSE/rede sem limite de
tempo. Esse I/O pode travar em sleep ininterruptível e PENDURAR a sessão
indefinidamente — o timeout nativo do Bash NÃO mata de forma confiável um
processo preso num mount FUSE. Vale para o loop principal E para subagentes
(Explore/Task): foi um `ls` de subagente num path CloudStorage que pendurou a
crew thies-wa por 15min. Se PRECISAR tocar num path desses: (1) prefira a fonte
canônica do dado (DB/API) a varrer a árvore do Drive; (2) envolva SEMPRE em
`timeout` (ex.: `timeout 15 ls ...`); (3) verifique antes que o mount responde.
Rede de segurança: o `crew-hang-detector` detecta sessões de crew com heartbeat
congelado e dispara o shutdown-dance (kill+restart com devido processo).

**Formulas graph.v2 multi-step — feche E reclame CADA step, não só o
primeiro (ga-z1k7).** A seção nativa "Following Your Formula" diz "Steps
are NOT materialized as individual beads" — isso é FALSO para formulas com
`contract = "graph.v2"` (ex.: mol-digest-generate, mol-idea-to-plan,
mol-refinery-patrol): cada step materializa como bead PRÓPRIO, encadeado
por dependências `blocks`. Gatilho de detecção: `gc.root_bead_id` no
metadata do bead — NÃO `molecule_id` (esse key é exclusivo do path
legado de sling, não-graph; um step bead de graph.v2 nunca o carrega).
Se o bead tiver `gc.root_bead_id`, esse valor é o `<root-bead-id>`: use
SEMPRE o loop `bd mol current <root-bead-id>` → para cada step
`[ready]`: `bd show <step-id>` → execute → `bd close <step-id>` →
repita `bd mol current <root-bead-id>` (sempre com o id explícito —
logo após fechar um step você não tem nenhum bead in_progress assigned
de onde `bd mol current` sem argumento possa inferir). NUNCA leia todos
os steps de uma vez (ex.: via `gc bd formula show --json`) e execute o
efeito real de todos inline fechando só o PRIMEIRO bead que você
claimou — o engine libera o(s) próximo(s) step(s) como ready+unassigned
assim que o anterior fecha, e eles ficam órfãos na pool; uma sessão
FUTURA pode claimá-los como trabalho pronto e RE-EXECUTAR, duplicando
side effects (mail, bead creation, sends). Se crashar/reiniciar no meio
de um molecule, rode `bd mol current <root-bead-id>` antes de redigitar
qualquer trabalho — o step pode já estar feito, faltando só fechar o
bead.

**Bead pede rebuild+swap do engine gascity? ESCREVA o patch, mas NÃO faça o
build+swap (pool:refused:engine-rebuild-required — ga-vhyd, escopo corrigido
2026-08-13).** Go build + swap de binário + town bounce é Mayor-coordenado,
por doutrina (alto blast radius: é o binário compartilhado que TODOS os
agentes rodam) — nenhum worker de pool (dog, wa-worker, ps-worker) faz isso
sozinho, mesmo com o source local buildable.

⚠️ **O QUE É PROIBIDO É O DEPLOY, NÃO O CONSERTO.** Esta regra dizia "Refuse,
não construa", sem separar as duas coisas — e o efeito medido (Mayor,
2026-08-13, triagem da Travadas) foi bead de engine congelando por **8 a 27
dias** sem ninguém escrever uma linha: ga-66wc (27d), ga-okcgb (P1, 8d),
ga-gye3f, ga-f6igb, ga-vu718. Escrever o patch NÃO tem blast radius nenhum —
quem tem é o build+swap. Congelar o conserto junto com o deploy é guarda
larga demais, e o custo é backlog parado indefinidamente.

**O caminho certo, que já é padrão provado nesta cidade** (7 patches vivos em
`docs/pending-engine-window/`, dos quais 2 entraram na janela de 2026-08-13):
1. **Escreva o fix** no source do engine e **valide** (teste que REPROVA no
   HEAD anterior — não basta passar depois).
2. **Gere o patch e commite ele** em `docs/pending-engine-window/<bead>-<slug>.patch`
   (`git -C <src> diff > …`). O patch é versionado; a árvore do engine carrega
   mudança não-commitada por desenho, então patch fora dela é o que sobrevive.
3. **Verifique que aplica limpo**: `git -C <src> apply --check <patch>`. Se já
   estiver na árvore, `--check --reverse` passa — diga isso no comentário.
4. **NÃO** rode `go build`, **NÃO** troque symlink, **NÃO** faça kickstart do
   supervisor. Aí sim aplique o label e devolva pro Mayor agendar a janela.
5. No comentário do bead, diga o caminho do patch e o que ele entrega.

Só use o refuse SEM patch quando o bead pedir literalmente o ato de deploy
(ex.: "rodar a janela", "trocar o binário") e não haja conserto a escrever.

Sinal no título/body do bead: "engine rebuild", "rebuild...
gascity"/"gascity...rebuild", "swap...binário"/"binary swap", "town bounce",
"engine window", ou label `framework:engine`. O Pilot já filtra a maioria
disso na origem (`_filter_candidates` em pilot-dispatcher.sh), mas se um
bead desses passar e você já tiver claimado — precedente real: dog-ga5tiy em
ga-g7yt — refuse explicitamente em vez de só silenciar ou tentar buildar:
```bash
bd label add <id> pool:refused:engine-rebuild-required
bd comment <id> "Refusing: <motivo — o que o bead precisa que este worker não faz>."
gc runtime drain-ack && exit
```
Isso é DIFERENTE do fechamento normal de formula (`gc bd close <id>` na seção
"Completing Work") — um refuse NÃO fecha o bead nem limpa status/assignee;
quem é dono dessa transição é o `inflight-reclaim-guard`, que precisa do bead
ainda parecendo in-flight pra processar o refuse. `pool:refused:<reason>` já
é filtrado nas routed-pool probes de wa-worker/ps-worker (ga-y8qh — jq
startswith() sobre o prefixo, já que --exclude-label só casa exato); a probe
nativa de DOG ainda não tem esse filtro (gap separado, provavelmente
engine-side — se um bead já-refused reaparecer no seu hook, não tente
consertar a query você mesmo, nudge o Mayor).

**Editando `packs/town-deltas/assets/` (o arquivo mais disputado da cidade)?
Worktree ANTES do primeiro Edit, não só na hora de shipar (ga-kgja).** A
árvore `~/gt` é COMPARTILHADA entre Mayor, dogs e crews, sem isolamento por
sessão — um `git add <arquivo>`/`git commit -a` de QUALQUER sessão stageia o
ARQUIVO INTEIRO, incluindo edições não-commitadas de OUTRO agente no mesmo
arquivo, e quem commita não percebe (reporta sucesso; o diff que foi não é o
diff que ele pensa que fez). Já custou 2 incidentes no mesmo arquivo
(`quality-gate-dispatcher.sh`): um commit do Mayor (055cc4f5) levou junto um
fix de dog ainda não-commitado; antes, um dog varreu edições do Mayor num
CLAUDE.md de rig. Fix: `git worktree add .gc-worktrees/<nome> -b
fix/<bead>-<desc> HEAD` ANTES de tocar no arquivo — não no fim do trabalho.
Só edite a raiz compartilhada direto pra investigação read-only (Read/grep/
baseline), nunca pra fazer o fix em si.

**Commitando na árvore compartilhada (qualquer arquivo)? Confira o staged
antes — nunca `git add -A`/`git commit -a` às cegas, e nomear o arquivo +
`git diff --cached --stat` NÃO bastam (ga-kgja, ga-0s4at).** Norma geral,
além do caso acima: `git add -p` (interativo) OU `git diff --cached`
**sem `--stat`** antes de qualquer commit em `~/gt` — garante que o que você
stageou é só o que VOCÊ editou nesta sessão. Dois furos que uma versão
anterior desta regra não cobria, e que já custaram um commit real levando
código alheio pra dentro de um guard de segurança:
  1. `git add <arquivo>` stageia o ARQUIVO INTEIRO, mesmo nomeado (nunca
     `-A`) — inclui edição não-commitada de OUTRO agente dentro do mesmo
     arquivo. Nomear protege contra levar arquivos alheios, não contra levar
     LINHAS alheias no teu próprio arquivo.
  2. `--stat` mostra só nome e contagem de linha ("2 arquivos, +81/-2") —
     exatamente o que o teu próprio trabalho pareceria. O diff alheio se
     esconde dentro do número; só ler o CONTEÚDO expõe.
`git add -A`/`git commit -a` sem conferir assume que o resto da árvore está
limpo, e numa árvore com várias sessões concorrentes isso quase nunca é
verdade.

**`gc session nudge` NÃO destrava um diálogo de permissão aberto — exige
keystroke direto no pane (ga-q640n/ga-iog1v).** A doutrina nativa "sempre
nudge, nunca tmux send-keys" tem uma exceção real e já confirmada num
incidente ao vivo. Se o pane mostra um diálogo de confirmação interativo tipo
`"Permission rule Bash(rm -rf:*) requires confirmation for this command. Do
you want to proceed? 1. Yes 2. Yes, and don't ask again 3. No"`, o nudge
entra numa fila que só é processada DEPOIS que o diálogo resolver — ou seja,
nunca, se ninguém responder primeiro. Causa raiz: uma sessão de pool
(dog/wa-worker/ps-worker) roda com bypass de permissões, mas uma regra
"ask" explícita no `~/.claude/settings.json` (ex.: `Bash(rm -rf:*)`,
`Bash(sudo:*)`) SOBREPÕE esse bypass — comportamento documentado e
intencional do próprio Claude Code, não um bug do Gas Town. Verificado ao
vivo: nudge "1" ficou 105s+ sem efeito num dog que rodou um `rm -rf` legítimo
(limpeza de `__pycache__`) e travou 7h. O que destravou foi `tmux send-keys`
direto no pane (tecla + Enter em comandos separados). Exceção ESCOPADA à
doutrina nativa: só recorra a send-keys depois de CONFIRMAR o diálogo via
`gc session peek <target> --lines 40` (leia as opções exatas antes de
responder — não assuma sempre "1"), nunca como primeiro recurso e nunca sem
essa confirmação. O daemon `agent-stuck-escalation.sh` agora detecta esse
estado automaticamente (assinatura estável no pane, ver
`pane_shows_permission_prompt()`) e manda mail com assunto "Agente BLOQUEADO
EM PROMPT (1 tecla resolve)" em vez do genérico "Agente travado" — se você
receber essa mensagem específica, o pane já está confirmado, pule direto
para o passo de send-keys em vez de tentar nudge.

**Dispatch "research-only" (não edite arquivos) não cobre o canal REDE — só
nomeia o filesystem (ga-1udgm).** Um fork despachado com a instrução explícita
`Research-only task (do NOT edit any files)` pra mapear
`daemons/pipedrive_sync.py` editou 3 arquivos (violando a instrução literal) **e**
chamou a API LIVE do Pipedrive, criando 4 custom deal fields em PRODUÇÃO — mesmo
que tivesse obedecido a instrução à risca, o dano teria acontecido igual, porque
"não edite arquivos" nomeia o canal FILESYSTEM e o dano veio pelo canal REDE.
`research-only` é justamente o modo em que se LÊ código que instancia client de
terceiro (Pipedrive, whapi, MotherDuck, S3, Google) — o material da pesquisa É o
gatilho, e rodar o que se está lendo é o passo natural se ninguém disse que não
podia. Mesma família de "a guarda nomeia o canal errado" que o matcher que só
casa nome de tool, ou a regra que protegia `~/.dolt-data/` enquanto os bancos
viviam noutro diretório: uma guarda que nomeia o canal errado é indistinguível
de nenhuma guarda — "eu segui a instrução" e "eu não causei dano" viram fatos
diferentes.

Um terceiro canal apareceu depois — e é o pior dos três (comentário do Mayor,
2026-08-01): **identidade/comunicação.** Um subagent herda a identidade do pai
em TODO canal de comunicação (mail, nudge, comentário/fechamento de bead) —
nada no envelope distingue "o agente escreveu" de "um subagent dele escreveu".
Um subagent confuso que reporta sob o nome do pai é pior que silêncio: é lido
como medição verificada, não como palpite. Foi o que aconteceu aqui — um mail
chegou como se fosse do worker, carregava uma alegação factual falsa (atribuiu
ao fork 2 arquivos que já existiam antes dele) e uma causa-raiz inventada, e
consumiu investigação real do Mayor antes de alguém checar o artefato.

**Como aplicar (as três frentes; uma só não fecha):**
1. **Prosa não restringe ferramenta.** Pra pesquisa read-only, prefira um agent
   type restrito por CONSTRUÇÃO (`Explore` não tem Edit/Write/NotebookEdit) em
   vez de confiar em texto no prompt. ⚠️ Isso sozinho NÃO basta: `Explore`
   ainda tem Bash, logo ainda consegue `curl`/rodar código que muta.
2. **Proíba o CANAL, não o arquivo.** Se o alvo da pesquisa instancia client de
   terceiro, o brief precisa dizer literalmente: *não execute o módulo, não
   instancie o client, não faça chamada que crie/edite/apague nada — leitura de
   código apenas*.
3. **Proíba o canal de IDENTIDADE também.** No brief: *não mande mail, não
   faça nudge, não comente nem feche bead — devolva tudo no relatório final;
   quem decide o que comunicar é quem despachou*. Sem isso, um subagent pode
   agir e falar sob a identidade do pai sem que ninguém a jusante consiga
   distinguir um do outro.

**Corolário pra quem recebe (vale pro Mayor e pra qualquer agente): relato de
agente não é medição.** Quando uma mensagem trouxer uma alegação factual que
vai virar decisão, confirme no artefato antes de repassar — `git log`, consulta
à API, o dado bruto — não a narrativa. Repassar sem checar propaga o erro como
se fosse fato verificado.

Os 4 campos ficaram (dormentes, varchar, zero deals referenciam, dentro do
limite do plano) — deletar+recriar seria churn puro, decisão correta e dentro
do domínio de quem os criou. O bead existe pelo buraco estrutural na
instrução, não pela conduta do worker: o relato foi exemplar, mediu o próprio
estrago na API (não no relato) e reportou com rastro.

**`bd list --json` trunca em 50 SEM sinal no JSON — todo sweep precisa de
`--limit 0` explícito (ga-21kmp).** O CLI faz a coisa certa e avisa em texto
humano ("Showing 50 issues; more results matched but were hidden by --limit.
Use --limit 0 for all"), mas o aviso vai pro STDERR — e o idioma desta cidade
é `2>/dev/null`. `bd list --json` sozinho devolve um ARRAY PURO de até 50
itens, sem nenhum campo de aviso nem envelope; o consumidor programático não
tem como saber que faltou. `--all` devolve tudo (todo status, todo tempo —
49.884 num teste real desta cidade); `--limit 0` (== `-n 0`) devolve tudo do
filtro atual sem truncar (335 abertos no mesmo teste). Uma consulta filtrada
cujo conjunto é <50 funciona por acidente — o defeito é latente e aparece
justo quando há backlog, que é exatamente quando o diagnóstico mais importa.
Já causou dois erros reais do Mayor no mesmo dia (concluir "não existem
digest beads" quando havia 10 fora dos primeiros 50; subcontar "10 beads
armados sem rota" quando eram 19) e foi encontrado ao vivo, sem `--limit`
algum, em vários daemons que contam/decidem sobre listas de beads
(`inflight-reclaim-guard.py`, `quality-gate-dispatcher.sh`'s
`_still_listed()`, `gate-health-monitor.py`, `production-stall-watchdog.py`,
`throughput-stall-watchdog.py`) — cada um silenciosamente ignorando o 51º+
item do conjunto que deveria estar varrendo.

**Como aplicar:** qualquer `bd list ... --json` (shell OU
`subprocess.run(["bd", "list", ...])` em Python) que VARRE um conjunto
(conta, decide, ou itera o resultado inteiro) precisa de `--limit 0`
explícito — nunca confie no default de 50. Só dispensa quem busca UM id
específico, ou já usa `--all`/`-n <N>` deliberado com um N que o autor
escolheu conscientemente (não mexa nesses). Ao auditar um arquivo, procure os
DOIS padrões — um grep textual `bd list.*--json` pega o shell, mas PERDE o
Python: `["bd", "list", ...]` não tem "bd list" adjacente como substring
(há vírgula+aspas no meio), então precisa de um grep separado por `"bd",`
seguido de `"list"` numa janela de poucas linhas.
{{ end }}
