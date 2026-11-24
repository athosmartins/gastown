# bd nunca sobe um Dolt por conta própria — plists, Pilot e o que o mini ainda tem de fazer (ga-d3ryi7k)

## Contents

• O que aconteceu em 23–24/11 · O que o repositório faz agora · O que o mini ainda tem de fazer (mergeado não é vivo) · Como provar · Faixa não medida no Pilot: o que o log diz e os botões · O que isto não cobre

## O que aconteceu em 23–24/11
1. Reboot de 23/11 23:41. O Dolt de produção voltou numa porta e as rigs com `.beads/redirect` (gastown, lexbh, marketing) ainda guardavam a porta antiga em `dolt-server.port`.
2. 23:43: um `bd` sob o launchd, sem `BEADS_DOLT_AUTO_START=0` no plist, não achou servidor naquela porta e **subiu um Dolt local** (o isca) no lugar. Sem banco nenhum: toda leitura dessas rigs respondeu «database not found». Detalhe medido pelo Mayor em `docs/runbooks/child-priority-janitor.md`, seção «O Dolt isca de 23–24/11».
3. A consulta de `story:in-flight` do Pilot falhou. A trava da ga-1fssl (`inflight_slots_from_query`) pôs as duas pistas em 0 vaga, e o Pilot saiu em «Both lanes full … backing off» **antes** da passada do nó: o Hetzner ficou ocioso ~12 h. Conserto manual de 24/11 ~11:5x (arquivos de porta trocados, isca encerrada).

A ga-u4z4hwb fechou só o job que travou primeiro (o janitor). Esta bead fecha a classe no que o repositório controla.

## O que o repositório faz agora
- **Todo plist que a cidade carrega traz `BEADS_DOLT_AUTO_START=0`** em `EnvironmentVariables`: 103 plists editados (37 em `scripts/`, 65 em `packs/town-deltas/assets/`, 1 em `…/pending-activation/`), cada um com 1 a 5 linhas ACRESCENTADAS e nenhuma tocada. Antes: 103 de 104 plists vivos sem a variável (o 104º é o do janitor, da ga-u4z4hwb); depois: 0 de 104. Os 3 que não tinham `EnvironmentVariables` nenhum (`bd-metrics-disable-env`, `cloudflared-dns-reconcile`, `crew-pushguard-check`) ganharam o bloco inteiro: a regra não tem exceção porque decidir «este job nunca chama bd, nem por outro script» é a mesma leitura que falhou em 23/11. É o mesmo botão que o `gc` já liga em todo `bd` que ele roda; sem ele o `bd` não tem servidor próprio para recorrer, e uma porta que não responde vira erro no log, não um processo ouvindo.
- **`scripts/plist-bd-env-lint.py`**: o veredito é do `plistlib` (não de grep: o nome dentro de um comentário XML ou de uma string de `ProgramArguments` é menção, não ajuste). Só vale a string `"0"` em `EnvironmentVariables` do nível de cima. Sem argumento: todo plist que o git rastreia na cidade, menos `docs/launchd-archive/` e `internal/templates/`. `--fix` insere a chave **no texto** (comentários, indentação e CRLF ficam), grava de forma atômica e só se o resultado lido for exatamente o original mais aquela chave; nunca reescreve um valor que alguém pôs, nunca toca plist binário ou que não parseia, e nunca recarrega job.
- **`.githooks/pre-push`** recusa o push que adiciona ou altera um plist sem a variável (rc 1 bloqueia; rc 2, «não consegui decidir», avisa e deixa passar, como o `plist-comment-lint`). `GT_SKIP_ORPHAN_TREE_GUARD=1` é o desvio de sempre.
- **Pilot** (`pilot-dispatcher.sh`): faixa que não foi MEDIDA deixa de ser chamada de CHEIA e deixa de segurar o nó. Detalhe na seção «Faixa não medida no Pilot».

## O que o mini ainda tem de fazer (mergeado não é vivo)
Nada disto foi (nem podia ser) feito do nó Hetzner; o dog do mini ou o Mayor faz depois do merge, nesta ordem:
1. **Plists instalados.** O merge muda os arquivos do repositório; os que o launchd lê estão em `~/Library/LaunchAgents/` e só mudam quando alguém os troca. `--installed` acha a cópia de cada plist do repositório **pelo `Label`** (`~/Library/LaunchAgents/<Label>.plist`; `PLIST_LINT_AGENTS_DIR` troca o diretório) e não lê nem toca nenhum outro arquivo dali (o diretório tem plists que não são nossos). Contagem antes/depois, direto dos instalados:
   ```bash
   python3 .gascity-gastown-hq/scripts/plist-bd-env-lint.py --installed | tail -3         # antes: «N file(s), F fail» (os sem cópia saem em «not installed», e isso não é falha)
   python3 .gascity-gastown-hq/scripts/plist-bd-env-lint.py --installed --fix | tail -2
   python3 .gascity-gastown-hq/scripts/plist-bd-env-lint.py --installed | tail -2         # depois: 0 fail
   ```
   **O que o merge faz sozinho no mini, sem ninguém reinstalar:** o `production-drift-guard.sh` (ga-cv0dv, `scan_plist_env`) compara o `EnvironmentVariables` de cada plist de `packs/town-deltas/assets/` com o implantado (a cópia é achada pelo `Label`, a mesma convenção do `--installed`) e passa a acusar `env-drift` em todo plist já implantado até a cópia ser consertada: um resumo por rodada («Production drift: N job(s) …», o texto fala de «off-main/crew/worktree» mas o tipo é `env-drift`), não um aviso por plist. É o sinal certo de «mergeado, não vivo» e some depois do `--fix`; os de `scripts/` ele não olha. Nada recarrega job: o `daemon-refresh.sh` só confere que plist alterado está instalado e carregado.
   Se nenhuma cópia for achada no diretório o comando sai 2 («refusing to call that clean»): é diretório errado, não «tudo certo». O `--fix` só edita o arquivo. O job só passa a ter a variável quando for recarregado (`launchctl bootout` + `bootstrap`) ou no próximo reboot; recarregar ~100 jobs de uma vez é decisão do Mayor, e o próprio reboot da noite (`nightly-reboot-drain-cutover.md`) já resolve se o `--fix` rodar antes dele. Plist em formato binário vira «could not be fixed» com a instrução (`plutil -convert xml1`).
2. **`dolt.auto-start: false` nas rigs com redirect** (gastown, lexbh, marketing). Fecha pela raiz o `bd` que NÃO vem de plist (shell de pessoa, tmux, cron). A chave se escreve `dolt.auto-start: false` no README da ga-3risy2; esse arquivo mora nos repositórios das rigs, não aqui, e o nó não tem `bd` (o atalho recusa `bd config`). **Confira a forma exata com `bd config --help` no mini antes de rodar qualquer comando; nada aqui foi executado.** A prova é a leitura da config de cada rig depois.
3. **Reboot.** Depois do próximo reboot real: nenhum `dolt-server.port` de rig com a porta do isca (`52756`) nem com qualquer porta que não seja a viva. O detector já existe e é só leitura: `scripts/dolt-port-pin-guard.sh` (ga-3v2zt00), se estiver carregado.

## Como provar
```bash
python3 .gascity-gastown-hq/scripts/plist-bd-env-lint.py | tail -2                 # a árvore do repositório: 0 fail
bash .gascity-gastown-hq/scripts/plist-bd-env-lint.selftest.sh | tail -2            # 97 casos; 39 mutantes escritos à mão sobre o lint (bateria à parte), 39 pegos
bash .gascity-gastown-hq/packs/town-deltas/assets/pilot-dispatcher.lanes-unmeasured.selftest.sh | tail -2   # 77 asserções + 27 mutantes embutidos (cada guarda desligada numa cópia do dispatcher reprova o arquivo)
bash .githooks/pre-push_test.sh | tail -2                                           # 67 asserções (9 novas, nos testes 52 a 58)
```
O selftest do lint inclui um **ida e volta sobre os 104 plists reais**: tira a chave de cada um, roda `--fix` e exige os bytes originais de volta, então o que foi commitado é exatamente o que o `--fix` escreve. Cada edição também foi conferida por fora: o parse do `HEAD` mais a chave é igual ao parse do arquivo novo, em 103 de 103, e nenhum byte antigo mudou.

## Faixa não medida no Pilot: o que o log diz e os botões
Quando a leitura de `story:in-flight` falha em qualquer loja (HQ ou rig), `IN_FLIGHT_QUERY_OK=0`. A trava da ga-1fssl **continua**: o mini fica com 0 vaga (um número que ninguém leu nunca libera lugar lá). O que mudou é o resto:
- O log diz **«ga-d3ryi7k: faixas NÃO MEDIDAS …»** (e, se recuar, «Lanes NOT MEASURED … Pilot backing off»). Nunca «Both lanes full»: essa frase fica só para a pista lida e cheia, com o texto de sempre.
- Com `PILOT_NODE_FIRST=on`, fora do DRY_RUN e **com a leitura do próprio HQ respondendo** (`IN_FLIGHT_HQ_QUERY_OK`; foi o caso de 23/11: o HQ lia bem e só as rigs com redirect falhavam) a varredura **segue na passada só-nó** (a mesma do disk floor e do RAM floor: nada vai ao mini) com **1 vaga de sondagem por pista** se o que foi lido ainda deixa folga. Quem decide o que vai ao nó é a própria passada (veredito node, vaga do nó, rc 12 do apply). Se foi o **HQ** que não leu, o Dolt dele não está respondendo e as claims do nó são escritas lá: o Pilot recua, e o motivo dito no log é «a leitura do próprio HQ falhou». O top-up dos pools do mini roda antes, como sempre, porque não depende dessa contagem.
- **Alarme** (`notify`, prioridade 4): na 2ª varredura seguida sem medida e a cada 6ª (~30 min). Uma leitura que falha uma vez só aparece no log. Quando volta, o contador é apagado e, se já tinha havido alarme, sai o aviso de recuperação (prioridade 2). DRY_RUN não grava nem avisa.
- Botões (ambiente do Pilot): `PILOT_LANES_UNMEASURED_NODE_PASS=off` volta ao recuo de antes (com a frase honesta), `PILOT_LANES_UNMEASURED_ALERT_AFTER` (2), `PILOT_LANES_UNMEASURED_ALERT_EVERY` (6), `PILOT_LANES_UNMEASURED_STATE` (o contador, `$GC_CITY/.gc/pilot-lanes-unmeasured.count`). Nenhum precisa estar no plist: os padrões estão no código.
- Ler no log: `grep -E 'NÃO MEDIDAS|NOT MEASURED|voltaram a ser MEDIDAS' .gc/logs/pilot-dispatcher.log`.

## O que isto não cobre
- **Não foi rodado no mini nem contra um `bd`/Dolt de verdade.** O nó Hetzner não tem `bd` real, Dolt nem launchd. Os testes provam o texto, a ordem e as decisões do código (funções e região do dispatcher extraídas verbatim e executadas, o lint sobre os 104 plists reais e sobre fixtures); a varredura inteira do Pilot com `DRY_RUN=0` e a consulta falhando não foi reproduzida ao vivo.
- Um `bd` que **não** vem de um plist do repositório (um plist instalado à mão fora do repo, cron, shell) só fecha pela config da rig (item 2 acima).
- Um plist novo que passe pelo `--no-verify` ou por `GT_SKIP_ORPHAN_TREE_GUARD=1` volta ao estado de antes até o selftest do lint ser rodado; ele é a rede de segurança de quem roda as suítes.
- Considerado e **não feito**: um `launchctl setenv BEADS_DOLT_AUTO_START 0` global no login (como o do `bd-metrics-disable-env`). Não é determinístico: o job que sobe junto no boot pode largar antes do `setenv`, e foi exatamente o boot o que falhou em 23/11.
