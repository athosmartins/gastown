# Atalho bd/gc/gate-done do servidor Hetzner · lado do mini · runbook

## Contents

• O que esta fatia é — e o que não é · Como funciona · Lista permitida
• Como instalar no mini (nada foi instalado) · Medido, inferido, não testado
• Pontos em aberto · Limites

Bead ga-2hd02v.1.2.1 (fatia 3a do servidor Hetzner: divisão técnica de ga-2hd02v.1.2, que deu 1.326 linhas e o teto do gate é 1.000; desenho do estudo ga-ukxa3k; decisão do Mayor em 14/10: a lista cresce em EXATAMENTE `gc prime --hook`, `gc handoff --auto` e `gc nudge drain --inject`). Regra do Athos que vale aqui: nenhum dado de lead/cliente nem backup de bead sai do mini. O lado do servidor (o programa instalado como `bd`/`gc`/`gate-done` lá, e a prova da cadeia inteira) é a fatia 3b, ga-2hd02v.1.2.2, que acrescenta as suas seções a este runbook.

## O que esta fatia é — e o que não é

**É:** `scripts/remote-shim-wrapper.py`, que roda no **mini** como forced-command da chave do servidor, e `scripts/remote-shim.selftest.sh` (com o `remote-shim.selftest.lib.sh` que ele carrega), que o prova.

**Não é:** instalação. **Nenhuma chave foi criada, nenhuma linha entrou no `~/.ssh/authorized_keys` do mini e nada foi escrito no servidor** (o servidor é compartilhado com o ga-zri39b: instalar lá se combina antes). Dar a uma máquina alugada uma chave que entra no mini é uma mudança de postura de segurança; este runbook diz o comando exato e deixa o passo para quem tem a decisão.

## Como funciona

```
cliente ssh com a chave dedicada ─▶ mini: sshd ── authorized_keys: restrict,from=…,command="python3 -I remote-shim-wrapper.py serve --config …"
                                                    │ SSH_ORIGINAL_COMMAND = `rs1 <base64url>`  (não existe shell)
                                                    ▼
                       wrapper: decodifica → compara com a LISTA → grava auditoria → executa bd/gc SEM shell, ambiente do zero
```

* **A chave só roda o wrapper.** `restrict` desliga pty, encaminhamento de porta/agente/X11 e `~/.ssh/rc`; `command=` ignora o que o cliente pediu e entrega o pedido ao wrapper em `SSH_ORIGINAL_COMMAND`. Se o pedido não for `rs1 <base64>` o wrapper recusa (77): `ssh mini 'touch x'` e `ssh mini` (sem comando) não fazem nada.
* **O argv chega inteiro.** O ssh entrega a linha ao shell de login do mini; por isso o pedido vai em base64url, que não tem nenhum caractere que o shell interprete. O wrapper nunca monta uma string de shell: executa `[executável] + argv` direto.
* **Só identidade atravessa.** O `env` aceito é o das 7 variáveis da lista abaixo (a identidade da sessão e as duas do hook de início). `GC_SESSION_ID` **não** atravessa: nenhum padrão o liga ao alias, e o `gc handoff` aceita o alias no lugar dele. `GC_BIN`, `GC_HOME`, `GC_CITY_PATH`, `GC_DOLT_PORT`… são recusadas: apontariam o gc/bd do mini para outro lugar. O ambiente do filho é montado do zero (`HOME`, `USER`, `PATH` fixo, `BEADS_ACTOR` = alias), então `BASH_ENV`, `LD_PRELOAD` e afins do ambiente do sshd não chegam.
* **Código de saída e auditoria dizem se o comando RODOU** (está na lista / não está / não consegui saber — o último nunca vira "não rodou"): `77` = recusado e **nada** executou; `126` = o `exec` falhou, nada rodou; `127` = ferramenta não encontrada; `124` = passou de `timeout_s` e o grupo foi encerrado; **`125` = o comando FOI iniciado e o wrapper falhou antes de saber o desfecho — pode ter rodado (o wrapper encerra o grupo do filho, quando tem um filho para encerrar — se o `Popen` levantou algo que não é erro de exec, não há handle), não repita às cegas**; qualquer outro número é o do comando. O log de auditoria tem sempre duas linhas por pedido executado: `ok` (decidido e permitido, gravada ANTES de rodar) e `done …` (o desfecho: `rc=N`, `rc=126 nao-iniciado`, `killed sig=N filho-encerrado|filho-nao-iniciado` ou `unknown <erro>`); uma `ok` sem `done` só sobra se o wrapper morreu de `SIGKILL` ou a máquina caiu — desfecho **desconhecido**, não "rodou". A linha de uma recusa (`refused`) leva `declarado=<alias>` (o que o pedido DISSE ser, sem prova), `sem-alias` (decodificou e não trouxe) ou `?` (nem decodificou).
* **Tudo que diz QUEM é a sessão tem que casar com `identity_pattern`:** `GC_ALIAS`, `GC_AGENT`, `GC_SESSION_NAME` e `GC_TEMPLATE` (o gc resolve mail, drain e handoff por elas: um nome de sessão forjado com um alias bom mexeria na sessão errada). Pedido sem alias é recusado. A regex é o que impede o servidor de se declarar Mayor: deve listar só os papéis que existem **apenas** no servidor — um alias de pool que também existe no mini (ex.: o `gastown.dog-2` local) casaria, e o servidor poderia agir como ele. Isso é declaração do servidor, não prova (ver Limites).

## Lista permitida

É a tabela `RULES` do wrapper; o bloco abaixo é a saída de `python3 -I scripts/remote-shim-wrapper.py list` e o selftest **confere que os dois são idênticos** (a lista tem um só lugar de verdade: o código; este bloco é a cópia para auditoria). Fora dela: recusa com 77, a mensagem diz o motivo e o `bd`/`gc` de verdade nem é chamado.

<!-- allowlist:begin -->
```
bd [-C <rig>] show <id> [--json]
bd [-C <rig>] list [--json] [--status|-s <status>] [--assignee|-a <word>] [--label|-l <word>]... [--parent <id>] [--limit|-n <n>] [--id <ids>]
bd [-C <rig>] update <id> [--json] --set-metadata <key=value>...
bd [-C <rig>] comment <id> <text>...
bd [-C <rig>] comment <id> --stdin
bd [-C <rig>] close <id> [--json] [--reason|-r <text>]
gc prime --hook
gc prime --hook --hook-format codex
gc handoff --auto
gc handoff --auto 'context cycle'
gc nudge drain --inject
gc mail check [--inject]
gc mail inbox [--json]
gc mail read <id> [--json]
gc mail peek <id> [--json]
gc mail archive <id>...
gc mail send <word> [--subject|-s <text>] [--message|-m <text>]
gc mail reply <id> [--subject|-s <text>] [--message|-m <text>]
gc session nudge <word> <line>... [--delivery <delivery>]
gate-done
env GC_AGENT
env GC_ALIAS
env GC_HOOK_EVENT_NAME
env GC_MANAGED_SESSION_HOOK
env GC_SESSION_NAME
env GC_SESSION_ORIGIN
env GC_TEMPLATE
```
<!-- allowlist:end -->

Como ler: cada linha é uma forma EXATA. Flag fora da linha, flag repetida, valor fora do formato, argumento a mais ou a menos → recusa. Só se aceita `--flag valor` (nunca `--flag=valor`). `<id>` é um id de bead/mail: prefixo e um ou dois segmentos `-xxxx`, mais até três `.n` (`ga-2hd02v.1.2`, e `ga-wisp-0i6hr` — o formato de TODOS os 653 ids de mail/wisp medidos em 14/10; um id com três hífens ou mais é recusado); `<text>` é texto livre até 20 000 caracteres; texto que começa com `-` precisa vir depois de um `--`; `<line>` é texto que vira digitação no terminal de outra sessão e por isso **não aceita nenhum caractere de controle C0 ou C1 (TAB, ESC, CR e LF inclusive), o separador de linha Unicode (U+2028/U+2029) nem os controles de direção bidi (U+202A–U+202E, U+2066–U+2069)**; acento, travessão e pontuação comum passam; `<rig>` é a cidade, um rig da `.beads/routes.jsonl` (pelo nome ou pelo caminho real no mini) ou `.`. `env <NOME>` são as únicas variáveis aceitas do cliente.

Decisões que o Mayor pode reverter apagando UMA linha de `RULES` (e do bloco acima):

1. **As duas formas que o hook real manda.** A decisão do Mayor diz `gc prime --hook` e `gc handoff --auto`; as strings que o builder da fatia 1 (`remote-bundle-build.py`) lê dos hooks do mini, e que `manifest.json → shim_needs` lista, são `prime --hook --hook-format codex` e `handoff --auto "context cycle"`. Sem aceitá-las o hook de início e o de PreCompact dariam 77 no servidor. As quatro formas (as duas curtas e as duas do hook) são exatas: `gc prime` sem `--hook`, `gc prime --hook extra`, `--hook-format claude`, `gc handoff --auto "outra"`, `gc handoff --target …` e `gc nudge drain` sem `--inject` ou com argumento são recusados.
2. **`bd update` só escreve `--set-metadata`, e só chaves `athos.*` e `story.*`:** são as que fórmulas e agentes de worker escrevem (grep de 14/10); `gc.*`, `pilot.*`, `gate.*` e `delivery.*` são do plano de controle ou de daemons e o resto é desconhecido, então recusa (um prefixo novo é UM elemento de `ALLOW_META`). Sem `--status`, `--assignee`, `--unset-metadata`. `bd list` não varre (sem `--all`/`--limit 0`, `--limit` até 200); `bd --actor`, `--db` e outros flags globais não passam. Ver Pontos em aberto, item 1: isto bate no fecho de passo da fórmula de worker.
3. **`gc mail`**: `check`/`inbox` só sem argumento (a caixa do próprio alias), sem `--all`/`--from`/`--all-recipients`/`delete`. **`read`, `peek`, `archive` e `reply` recebem um `<id>` e agem em QUALQUER mensagem que o servidor nomear, de qualquer caixa** (o gc não separa por dono): aceito pela decisão original, ver Pontos em aberto, item 4, e Limites.
4. **`gc session nudge`** sem caractere de controle no texto (nudge é digitação no terminal do destino; com `\r` ele aprovaria um prompt de permissão; TAB também fica de fora, por autocompletar), só para alvos que casam com o `nudge_pattern` da config — **sem a chave, nudge não roda** — e `--delivery` só `queue`/`wait-idle`. O alvo é o PRIMEIRO argumento que não é flag (`--delivery <valor>` pode vir antes dele, como o `gc` aceita), e é esse que o `nudge_pattern` confere.

## Como instalar no mini (passos de quem decide — nada disto foi feito)

Antes: combinar com o ga-zri39b (servidor compartilhado) e confirmar com o Mayor quais papéis rodam no servidor (isso vira o `identity_pattern`).

1. **Config do wrapper**, fora do repo e sem segredo (`~/.gastown/remote-shim.json`):
   `{"city": "/Users/athos/gt/.gascity-gastown-hq", "identity_pattern": "(servidor-[a-z0-9-]+)", "nudge_pattern": "gastown\\.(mayor|deacon)", "gate_done_bin": null}`
   (`identity_pattern` é um **marcador**: `servidor-…` não casa com nenhum alias de hoje, então com ele o wrapper recusa tudo — o estado inerte. Quem instalar troca pelos papéis que a decisão do Mayor puser no servidor; tem de cobrir alias, agent, nome da sessão e template, e SÓ papéis que existem apenas no servidor — Pontos em aberto, item 3. O `nudge_pattern` é ponto de partida a confirmar; sem ele o nudge não roda). Log de auditoria: `~/.gastown/logs/remote-shim.log` (0600; ip, alias, regra, hash do argv, rc; o que foi EXECUTADO nunca grava o texto dos argumentos, mas uma RECUSA grava o motivo, que pode citar até 60 caracteres do argumento reprovado).
2. **No servidor**, gerar a chave dedicada (`ssh-keygen -t ed25519 -N '' -f ~/.ssh/mini_shim_ed25519`) e levar só a `.pub` ao mini.
3. **No mini**, gerar a linha (não grava nada) e **o Athos/Mayor decide** onde ela entra. **Não no `sshd` principal do mini**: o dog-3 mediu (comentário no ga-2hd02v.1.3, 14/10; não repeti a medição) que ele oferece `publickey,password,keyboard-interactive`, então um túnel do servidor até a porta 22 daria à máquina alugada um alvo de adivinhação de senha do usuário `athos`, mesmo com forced-command na chave. O caminho é o `sshd` só-chave em loopback que a fatia 4 está criando (`scripts/hetzner-mirror.sh sshd`): a chave do atalho é UMA linha a mais no `authorized_keys` DESSE sshd, com o wrapper desta fatia.
   `python3 -I scripts/remote-shim-wrapper.py authorized-line --config ~/.gastown/remote-shim.json --pubkey mini_shim_ed25519.pub --from <ip do servidor ou do túnel>`
   Use `--from`: a chave só vale a partir do endereço de onde o servidor chega (o `from=` sobrevive ao `sshd`: testado com um sshd sem privilégio, só-chave, em loopback). Dentro do `command="…"` o `sshd` só desfaz `\"`: o wrapper escapa só as aspas (uma barra invertida dobrada chegaria dobrada ao shell e o wrapper não acharia a config — medido num sshd real), e recusa caminho com caractere de controle (uma quebra de linha viraria uma SEGUNDA linha no `authorized_keys`).
4. O programa do lado do servidor (instalado como `bd`/`gc`/`gate-done`) e a verificação de ponta a ponta são da fatia 3b.

## Medido, inferido, não testado

**MEDIDO** (14/10, no mini; a máquina estava com load médio de ~138 em 10 núcleos — todo tempo abaixo é desse estado, não típico)

*Selftest hermético* (`bash scripts/remote-shim.selftest.sh`; cidade, rigs e `bd`/`gc`/`gate-done` falsos em `mktemp`): **280/280 ok, 0 pulados** na última rodada (inclui ids reais `ga-wisp-…` em todas as regras com `<id>`, o `nudge_pattern` de negação com a flag antes do alvo, e o que a 2ª rodada do gate achou: o fim do filho correndo com o prazo, falha do wrapper depois de o comando rodar, sinal, config em caminho com `\` e `"` num sshd de verdade). Os casos novos dessa rodada foram escritos ANTES da correção e **23 reprovaram no wrapper anterior** (251/274 então), com o sintoma literal do veredito: no `race` o `bd` falso RODOU e o wrapper saiu `77 RECUSADO: erro interno PermissionError`, com o log só com `ok`. Leva de 48 s a ~8 min conforme a disputa por CPU (load 48–160 em 10 núcleos): ~1 s por caso no pior, que é a partida de 2-3 `python3 -I` por caso; não há caso lento isolado.
* Cada forma da lista roda e o `bd`/`gc` falso recebe o argv canônico, com cwd certo (cidade, rig por nome ou por caminho), `BEADS_ACTOR` = alias e a identidade da sessão; código de saída, stderr e stdin passam. Inclui os 3 comandos da decisão do Mayor e as 2 formas que o hook real manda.
* 96 casos de comando recusado + 53 de protocolo, identidade e config: 77, a mensagem diz o motivo e o falso **não** é chamado (`bd sql`/`dolt`/`create`, `gc dolt`/`rig`/`config`/`session kill`, `gc prime` sem `--hook`, `gc prime --hook` com argumento a mais ou `--hook-format claude`, `gc handoff` sem `--auto`/com outra mensagem/`--target`, `gc nudge drain` sem `--inject` ou com sessão, `dolt`/`bw`/`security`/`sh`/`ssh`, id com `;`/`$()`, `-C` fora das rotas, chave de metadata fora de `athos.*`/`story.*` (`gc.`, `pilot.`, `gate.`, `delivery.`, `Story.`, desconhecida), nudge com ESC/CR/LF/C1, para alvo fora do `nudge_pattern`, sem `nudge_pattern` na config ou com `--delivery immediate`…); protocolo torto (vazio, base64 ruim, chave duplicada, NUL, surrogate solto, grande demais); identidade (sem alias, Mayor, casamento só em parte, `GC_SESSION_ID`, nome de sessão ou template do Mayor com alias bom); config ausente/ruim; log que não grava → não executa.
* **sshd de verdade** (sem privilégio, `127.0.0.1`, porta livre; some no fim): a chave **não** roda `touch`, **não** abre shell, **não** encaminha porta (`-R`), **não** ganha pty; `from=` que não casa nega a chave e `from=` que casa volta a rodar; uma chave **válida mas não listada** é negada, e a MESMA chave, listada, entra (o controle da negação); uma config em caminho com `"`, `\` ou `\"` entra e o wrapper a acha (a linha com a barra invertida DOBRADA, como o wrapper gerava antes, reprovou aqui: o `sshd` só desfaz `\"`).
* O bloco da lista deste runbook é igual à saída de `list` (o selftest compara). **Controles negativos dentro do selftest:** apagar a linha `gc prime --hook`, a guarda `gc.`/`pilot.`, o formato do id ou a lista de variáveis de ambiente faz o MESMO caso passar a se comportar diferente; o mesmo vale para as duas pontas da guarda do `kill_group` (EPERM de filho zumbi × EPERM de filho vivo) e para o `poll` depois do `TimeoutExpired`.
* **Campanha de mutantes** (RELATO do autor da fatia, **não reproduzível a partir desta fatia**: a ferramenta, `scripts/remote-shim.mutants.py`, entra na 3b e não está neste diff; o que esta fatia carrega são os controles negativos do próprio selftest, acima): 29 mutantes do wrapper (uma guarda apagada por vez), 29/29 mortos pelo caso esperado numa rodada anterior à última correção do gate, sobre os mesmos arquivos: forma da regra (argumento a mais, flag desconhecida/repetida/obrigatória, valor e posicional sem formato, prefixo basta), prefixos de metadata (3), identidade (sessão/template, `GC_SESSION_ID`, casamento só em parte), nudge (controle, alvo, sem chave, `immediate`), surrogate, `-C`, ambiente do sshd, timeout, `kill_group`, desfecho do log, log sem rastro, `restrict`, `--from`, pubkey. Numa rodada anterior dois mutantes morreram por acidente — um `pgrep` global enxergava o `sleep` órfão de outro mutante em paralelo — e isso não contou como morte; a checagem passou a olhar o PID do neto e a rodada foi refeita.

*Contra o `bd`/`gc` de verdade* (só leitura; o `serve` do wrapper chamado direto no mini com `SSH_ORIGINAL_COMMAND`, **sem** ssh no meio; config com `city` real e o alias `gastown.dog-1`; 14/10 23:22Z):
* `bd show ga-2hd02v.1.2 --json` → rc 0, 3,1 s · `bd list --json --status in_progress --assignee gastown.dog-1 --limit 5` → rc 0, 8,5 s · `gc mail check` → rc 1, 31 s — o **mesmo rc 1 e 26 s** rodando `gc mail check` direto (então o rc 1 não vem do wrapper); `gc mail check --help` diz "exits 0 if mail exists, 1 if empty", e eu li isso como "caixa vazia", mas **não separei "vazia" de uma falha genérica do `gc` (que também sai 1)**: INFERIDO, não medido · `bd sql 'select 1'` → recusado (77), nada executou.
* O ambiente montado do zero (sem `GC_CITY_PATH`, `GC_HOME`, `BEADS_DIR`; só cwd = cidade, `HOME`, `PATH`, `BEADS_ACTOR` e a identidade) basta para o `bd` e o `gc` do mini acharem a cidade. O tempo é a partida do `bd`/`gc` sob essa carga, não o wrapper: a auditoria mostra o `bd show` levando 3,1 s dentro dele. O wrapper acha `gc` em `/opt/homebrew/bin/gc` e `bd` em `~/.local/bin/bd`: os mesmos que o supervisor e as sessões rodam (resolve a cada chamada, então acompanha a troca de binário da janela do engine).
* Latência, o que domina: com load ~138, `gc mail check` leva ~26 s SOZINHO. Os 2 hooks de `UserPromptSubmit` (`nudge drain`, `mail check`) custam isso por prompt com ou sem atalho; o wrapper não é o gargalo.

**NÃO TESTADO**
* **`gc prime --hook`, `gc handoff --auto` e `gc nudge drain --inject` contra o `gc` DE VERDADE.** Só rodaram contra o `gc` falso. Têm efeito na sessão que os chama: `handoff` reinicia a sessão, `nudge drain` consome os nudges pendentes dela, `prime --hook` grava estado da sessão. Rodar com um alias de teste é o primeiro passo da fatia 6; o que foi provado no `gc` real é só o ambiente (`bd show`, `bd list`, `gc mail check`). `gc handoff` pede também "city context env" (`GC_CITY`, `GC_CITY_PATH`…) que o wrapper NÃO repassa do cliente de propósito; se o `gc` real exigir, o wrapper tem que preenchê-las a partir da config do mini, nunca do cliente (fatia 6).
* `gate-done`: **não existe hoje um executável `gate-done` no mini** — `/gate-done` é um comando de slash com ~900 linhas de bash embutidas, que faz `git push`/`fetch` no worktree e cria o marcador. A entrada da lista existe (`gate-done` sem argumento, executa o `gate_done_bin` da config, na cidade) e o selftest prova que chama o executável configurado; **sem `gate_done_bin` o wrapper recusa dizendo isso**. O executável de verdade depende do espelho git (fatia 4).
* `bd -C` pelo caminho do servidor (`/home/runner/gt-remote/work/<rig>`): o wrapper entende nome de rig e caminho do **mini**; o caminho do servidor não é traduzido. `bd comment <id> -- "- texto"` contra o `bd` de verdade: o `--` é passado adiante como o cliente mandou; que o `bd` o trate como fim das flags foi conferido só em `bd show -- <id>`, não num `comment` (que escreveria).

## Pontos em aberto

1. **A fórmula de worker (`formulas/mol-do-work.toml`) não cabe na lista decidida — decisão do Mayor, não minha.** Leitura estática do texto da fórmula, 14/10: ela chama `bd create`, `bd dep`, `bd heartbeat` (2×), `bd label` (2×), `gc runtime drain-ack` e `bd update … --set-metadata gc.outcome=pass|parked --status=closed --notes "…"` (3×: ao estacionar, ao fechar o passo da trilha de build e no fecho de reserva do passo de dreno). Nenhuma está na lista, e o fecho bate em DUAS guardas de propósito: `gc.outcome` (chave `gc.*`) e `--status`/`--notes` (não existem na regra de `bd update`). Uma sessão remota que rode essa fórmula não consegue fechar o próprio passo pelo atalho. A decisão do Mayor foi "exatamente 3 comandos novos e nada além", então **não ampliei a lista**; as opções (fecho estreito com `gc.outcome` como única chave `gc.*`, fórmula remota, ou só revisores no começo) e a recomendação estão no comentário do ga-2hd02v.1. Cada uma é UMA entrada em `RULES`.
2. **`gate-done` do mini.** Precisa de um executável que, dado o bead e o branch já empurrado ao espelho, cria o marcador na cidade (hoje isso é o corpo do slash command, dentro do worktree). Sem ele, `gate-done` no servidor recusa. Dono natural: a fatia 4 (espelho git) ou a 6.
3. **`identity_pattern`.** Quais papéis rodam no servidor? Decisão do Mayor; o passo 1 traz só um marcador inerte, justamente para não listar papéis que existem também no mini (um alias de pool que existe nos dois lados casaria, e o servidor poderia agir como ele). Medido: os aliases reais hoje são `gastown.dog-N` e `gate-reviewer-adhoc-<hex>`, os `agent` do `city.toml` têm `dir = ""` (sem `/` nem `_` no `GC_TEMPLATE`), então o formato aceito de `GC_ALIAS`/`GC_TEMPLATE` (sem `_`) não recusa nenhum papel do `city.toml` de hoje; um papel novo com `_` no nome seria recusado.
4. **`mail read`/`peek <id>`** leem qualquer id de mensagem, inclusive o de outra caixa; o gc não separa por dono. Aceito pela decisão original ("gc mail"); se incomodar, tirar as duas linhas da `RULES`.
5. **`bd update --set-metadata`** só aceita `athos.*` e `story.*` (decisão 2 acima). Escritores de `gc.*`/`pilot.*`/`gate.*`/`delivery.*` hoje (grep no repo): daemons e scripts do mini — `pilot-dispatcher.sh`, `quality-gate-*.sh`, `refino-gate-dispatcher.sh`, `lifecycle-coherence-janitor.sh`, `gatefix-deadworker-recovery.sh`, `pilot-missing-route-watchdog.sh`, `pilot-manual-reclaim.sh`, fora do atalho — e `mol-do-work.toml`/`mol-dog-backup.toml` (workers/dogs: item 1).
6. Limite de taxa por chave e rotação do log de auditoria (2 linhas por chamada, ~150-300 bytes cada; o wrapper só anexa).

## Limites

* **`<id>` aberto a qualquer bead/mensagem.** `bd update --set-metadata` (só `athos.*`/`story.*`), `bd close`, `bd comment` e `gc mail read`/`peek`/`archive`/`reply` agem sobre QUALQUER id que o servidor nomear, não só os do próprio alias: o wrapper valida o formato do id, não o dono. Quem não quiser isso tira a linha da `RULES`.
* **O código de saída do próprio comando pode coincidir com os do wrapper.** `bd`/`gc` podem sair 77, 124, 125, 126 ou 127 por conta própria; só a linha `remote-shim-wrapper: …` no stderr e o log de auditoria dizem de quem é o código. Quem decide repetir um pedido pelo código tem de olhar também essa linha.
* A identidade é **declarada pelo servidor**: quem o controla pode se passar por qualquer sessão cujo alias, agent, nome e template casem com o `identity_pattern` (por isso o padrão é estreito e só lista papéis que existem apenas no servidor), e o que `bd`/`gc` fazem em nome dela vale como se fosse dela. O wrapper garante que ele não vira o Mayor nem outra sessão fora do padrão, não roda nada fora da lista e deixa rastro. `bd update` não se limita a beads do próprio alias: o servidor pode escrever `story.*`/`athos.*` em qualquer bead.
* Texto livre (`bd comment`, `mail send/reply`, `--reason`) chega ao mini sem filtro de conteúdo: é a função dele. Quem lê mail/comentário tem que tratá-lo como dado (regra da cidade), não como ordem.
* A auditoria é do mini, no mesmo disco: não impede nada, só registra. O log guarda o hash do argv do que rodou; a linha de uma recusa pode trazer um trecho (até 60 caracteres) do argumento reprovado, no disco do mini, de onde nada sai.
* O wrapper confia no `bd`/`gc` do mini: se um flag permitido tiver um efeito que a regra não previu (por ex. um `--json` que mude de sentido numa versão nova), a regra não sabe.
