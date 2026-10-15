# Claude Code no servidor Hetzner (login, bundle, plugins, status) · runbook

## Contents

• Estado em uma linha · O que esta fatia é — e o que não é
• O que está no servidor agora (medido) · Comandos (`hetzner-claude.py`)
• O login — passo humano do Athos, guiado pelo Mayor · Depois do login: verificação, em ordem
• Como o provider e o Pilot usam o `gate` · Medido, inferido, não testado · Limites

Beads ga-2hd02v.1.4.1 (fatia 5a: o login) e ga-2hd02v.1.4.2 (fatia 5b: a instalação), partes da fatia 5 do ga-2hd02v (desenho do ga-ukxa3k). A história-mãe ga-2hd02v.1.4 foi dividida porque o gate recusou a entrega inteira por tamanho (E11).

## Estado em uma linha

`claude` 2.1.300 (a mesma versão do mini), 3 plugins e o bundle `0d204dbbebe6` estão instalados e conferidos no servidor `hetzner-teste`; **o servidor está logado** (Athos, 15/10 11:41Z, assinatura Claude Max) e `hetzner-claude.py status --fresh --probe` dá `state: ok`, saída 0; o `canary` passa e o Remote Control abre (medido, ver "Depois do login"). **Uma ressalva honesta:** o `fingerprint --compare` literal (hash antes×depois) dá `MUDOU` na conta do mini; a causa está medida e é anterior ao login (linha do tempo em "Depois do login"), mas o aceite "inalterada" fica provado por linha do tempo, não por hash igual.

## O que esta fatia é — e o que não é

É: instalar o Claude Code (build nativo) no usuário `runner` do servidor, levar o bundle de settings/hooks da fatia 1 e os plugins do papel de pool, e dar ao mini um comando que diz se o login do servidor vale (`gate`/`status`).

Não é: o login (OAuth interativo, passo do Athos), troca ou failover de conta (fora de escopo: uma conta só, decisão do Athos de 14/10 18:42, citada no comentário do Mayor em ga-2hd02v.1.4 de 2026-10-14T21:43Z), nem a fiação do `gate` no provider/Pilot (ver "Como o provider e o Pilot usam o gate"). Não copia credencial do mini, não guarda segredo em arquivo versionado, não leva credencial do GitHub nem dado de lead/cliente, e não toca em `wa-base`, `venv-wa`, `slots`, `traco-bim`, `mirror` nem `~/shared` do servidor.

## O que está no servidor agora (medido)

Medido por ssh em 14/10 (20h BRT), só leitura, depois das instalações:

* Linux 6.8.0-138 aarch64, usuário `runner`, 278 GB livres. **`node` e `npm` ausentes e o `claude --version` funciona**: o build nativo não precisa de `node` (o instalador baixa um binário de `downloads.claude.ai` e confere o checksum do manifesto; não usa `node`). Registrado como **"não precisa"**.
* `claude --version` no servidor = `2.1.300 (Claude Code)` = a do mini no mesmo dia. `~/.local/bin/claude -> ~/.local/share/claude/versions/2.1.300`.
* Instalador: `https://claude.ai/install.sh`, 260 linhas, `sha256 3a68d3406cf674e17bed1733a4dcf37805e2e47d87417700007d7e1aa766a944` em 14/10. O `install-claude` só roda o script cujo hash o chamador passou (hash diferente → recusa, exit 3).
* Plugins (`claude plugin list --json` no servidor): `superpowers@claude-plugins-official` 6.4.1, `security-guidance@claude-plugins-official` 2.0.13, `frontend-design@claude-plugins-official` c2bdb427efe8 — os três `enabled`. **Não instalados, de propósito:** `github` (exigiria credencial do GitHub, proibida), `playwright` (`npx @playwright/mcp@latest` sem versão fixa a cada sessão; precisa de `node` e de navegador) e `beads` (não está instalado nem no mini). `security-guidance` tem a mesma versão do mini, mas 5 arquivos diferentes (medido 14/10 por esta fatia).
* Bundle: `bundle_hash 0d204dbbebe6`, o mesmo do mini (build de hoje = o de 14/10 00h). 8 arquivos instalados: `~/.claude/settings.json`, 6 hooks em `~/.claude/hooks/` (modo 755) e `~/gt-remote/bundle/city/settings.json`; `role/*` fica em `~/gt-remote/bundle-out/` (quem monta o diretório da sessão o coloca). `remote-bundle-build.py verify` **rodado no servidor** sobre a cópia: saída 0, mesmo hash. Nenhum `/Users/` nos arquivos instalados. O `settings.json` do servidor tem as chaves do bundle mais `enabledPlugins` e `extraKnownMarketplaces` (a mesclagem é do `push-bundle`, o bundle em si não leva plugin).
* Login, **depois** (15/10 12h BRT, medido por esta rodada): `claude auth status --json` → `loggedIn=true`, `authMethod=claude.ai`, `apiProvider=firstParty`; `~/.claude/.credentials.json` `-rw-------` dono `runner`, escrito às 11:41:15Z (o instante do login). A sessão de teste mostrou o plano como "Claude Max".
* Login, **antes** (14/10): `claude auth status --json` → `loggedIn=false`, `authMethod=none`; `~/.claude/.credentials.json` não existia. `claude remote-control` sem login responde *"You must be logged in to use Remote Control. Remote Control is only available with claude.ai subscriptions"* — o login do servidor precisa ser pela **assinatura** (`--claudeai`, o padrão), não pelo Console.
* A credencial do mini, antes do login: `fingerprint --save` gravado em `<cidade>/.gc/hetzner-claude.fp-before.json` (14/10 20h22 BRT; `.gc/` não é versionado). É contra esse arquivo que o `--compare` roda depois.

Arquivos que esta fatia escreveu no servidor (tudo dentro de `/home/runner`): `~/.local/bin/claude`, `~/.local/share/claude/`, `~/.claude/` (settings, hooks, plugins, backups, projects de teste), `~/.claude.json`, `~/gt-remote/bundle/`, `~/gt-remote/bundle-out/`, `~/gt-remote/bin/remote-bundle-build.py`, `~/gt-remote/home-settings.merged.json`, `~/gt-remote/bundle-installed.json` e, na chamada de modelo do `status`/`gate` e no `canary`, as pastas de trabalho fixas `~/gt-remote/probe/` e `~/gt-remote/canary/` (fixas de propósito: o claude cria um projeto em `~/.claude/projects` por pasta, e uma pasta nova por chamada deixaria um por hora). O único `rsync --delete` é sobre `bundle-out/`.

## Comandos (`hetzner-claude.py`)

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/hetzner-claude.py gate                       # 0 só se o login está POSITIVAMENTE bom; senão 1 e "blocked: <estado>: <motivo>"
python3 -I $S/hetzner-claude.py status [--fresh] [--probe] # JSON do estado; --fresh ignora o cache, --probe força a chamada de modelo
python3 -I $S/hetzner-claude.py install-claude --installer-sha256 <hash> [--version V]
python3 -I $S/hetzner-claude.py plugins                    # instala o que falta e lista o resultado
python3 -I $S/hetzner-claude.py push-bundle --role dog --role-dir <dir do papel> --out <OUT novo ou do próprio builder>
python3 -I $S/hetzner-claude.py canary                     # sessão mínima com os argumentos do provider (--settings do bundle, --dangerously-skip-permissions) e SEM ferramenta (--tools "")
python3 -I $S/hetzner-claude.py fingerprint --save F | --compare F   # prova de que a credencial do MINI não mexeu
python3 -I $S/hetzner-claude.py leak-scan PATH...          # formato de token do claude em arquivos; imprime arquivo e contagem, nunca o texto
bash $S/hetzner-claude.selftest.sh                         # hermético (servidor = pasta mktemp, ssh falso que roda o comando de verdade)
```

`state` ∈ `ok | logged-out | expired | quota | unreachable | unknown`. **Três respostas, não duas:** "não consegui saber" (ssh fora, JSON ilegível, tipo errado, lock não obtido, estado velho que não deu para renovar) é `unreachable` ou `unknown` e o `gate` trata como bloqueado. `ok` exige `claude auth status` com `loggedIn == true` **e** uma chamada de modelo real (haiku, 1 turno) com `is_error == false` e saída 0 — a medição de 14/10 mostrou que um servidor deslogado responde `subtype: "success"` com `is_error: true`, então o subtipo não decide nada. A chamada de modelo se repete a cada 1 h enquanto `ok` e a cada 15 min enquanto `expired`/`quota`; o cache do estado vale 120 s.

Estado em `<cidade>/.gc/hetzner-claude.state.json`, log em `hetzner-claude.log` (uma linha por mudança), trava em `hetzner-claude.lock`. **Bandeira manual:** `touch <cidade>/.gc/hetzner-claude.off` bloqueia o servidor na hora (o `gate` diz que foi à mão); apague para devolver ao automático. **Aviso visível:** `notify` só quando `ok → logged-out` ou `ok → expired`; **nunca por cota** (regra da cidade: aviso de crédito/cota não vai para o celular do Athos) — cota fica no log e no `status`.

## O login — passo humano do Athos, guiado pelo Mayor

O que o Athos faz (cerca de 5 min, uma vez): abrir o servidor, entrar na conta da assinatura e colar um código de volta.

1. No mini: `ssh hetzner-teste` (entra como `runner`).
2. No servidor: `claude auth login` (assinatura é o padrão; **não** usar `--console`). O comando mostra um endereço: abrir no navegador, entrar na conta combinada (a mesma assinatura que o mini usa, decisão de 13/10), autorizar e colar o código de volta no terminal. A Anthropic pode pedir uma verificação humana no navegador.
3. Conferir: `claude auth status` mostra `loggedIn: true`; `ls -l ~/.claude/.credentials.json` mostra `-rw-------` e dono `runner`. Sair do ssh.

Não fazer: rodar o login dentro de sessão de agente, usar `claude setup-token` (imprime um token no terminal), copiar a credencial do mini (o mini usa o Keychain; copiar para duas máquinas arrisca o refresh token rotacionar e invalidar uma das cópias) ou colar token em arquivo versionado, bead, mail ou log.

O fluxo exato do `claude auth login` (o que aparece na tela) **não foi observado**: um agente não consegue fazê-lo. Se a tela for diferente do descrito, vale o que a tela disser; anote no bead.

## Depois do login: verificação, em ordem

Rodado em 15/10 (09h16–09h30 BRT = 12:16–12:30Z), na ordem, com o script da branch. Resultados logo abaixo do bloco.

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/hetzner-claude.py status --fresh --probe          # esperado: "state": "ok", saída 0
python3 -I $S/hetzner-claude.py canary                          # esperado: "canary: ok" (bundle como --settings, sonnet)
python3 -I $S/hetzner-claude.py fingerprint --compare $GC_CITY_PATH/.gc/hetzner-claude.fp-before.json   # oauthAccount "igual" decide; keychain_mdat só informa (o mini renova o token sozinho)
python3 -I $S/hetzner-claude.py leak-scan $S $GC_CITY_PATH/.gc/hetzner-claude.log <OUT do bundle> <export dos beads da fatia em arquivo>
ssh hetzner-teste 'ls -l ~/.claude/.credentials.json'           # -rw------- runner
```

**Resultados (MEDIDO, 15/10 12:16–12:30Z):**

* `status --fresh --probe` → `state: ok`, `loggedIn: true`, `authMethod: claude.ai`, saída 0.
* `canary` → `canary: ok`, saída 0.
* `ls -l ~/.claude/.credentials.json` → `-rw------- runner runner`, modo 600.
* `leak-scan` do que a rodada produziu → **0 achados em 25 arquivos**: o log e o estado do `hetzner-claude`, o `fp-before`, uma cópia dos arquivos que estão **instalados no servidor** (`bundle-out`, `bundle`, `~/.claude/settings.json`, `~/.claude/hooks`, os dois `.json` de controle; **sem** `.credentials.json`) e a exportação do bead e dos comentários. Varrendo também `scripts/` inteiro da cidade: 8 arquivos com "formato de token", **todos explicados**: a chave literal `claudeAiOauth` (a própria regex do detector, este runbook, `claude-account-relog.*`), a fixture sintética `AAAA…`/`ZZZZ…` do selftest, e fixtures curtas (23–35 caracteres; um token real é bem maior) em `test_claude_crew_account.py`, `jev_recomecar_experiment.selftest.py` e `claude-account-relog.selftest.sh`, que não fazem parte desta entrega. O `__pycache__` achado é gitignored.
* **Remote Control no servidor: FUNCIONA.** Em tmux, no `~/gt-remote/canary`, com os argumentos do provider (`--settings ~/gt-remote/bundle/city/settings.json --dangerously-skip-permissions --model sonnet --remote-control`): o painel mostrou `/rc active` no cabeçalho e `/remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_…`, e `~/.claude/sessions/<pid>.json` ganhou `bridgeSessionId` (a mesma assinatura medida no mini em 19/09). O endereço da sessão **não** foi gravado aqui nem no bead. A sessão de teste foi encerrada com `/exit`; o tmux do servidor ficou sem sessão e nenhum `claude` dela sobrou. O provider (.1.1) **não** precisa deixar de passar a flag nesse host.
* **O que o provider precisa saber da primeira partida do `claude` num host novo (MEDIDO, tela real):** antes de chegar na sessão aparecem **três diálogos** — (1) escolha do tema (Enter aceita "Dark mode"), (2) "Security notes" (Enter), (3) **"Is this a project you created or one you trust?" com a opção padrão "No, exit"** (precisa Down + Enter em "Yes, I trust this folder"). Esse terceiro vale para a pasta que a tela cita (`Accessing workspace: <pasta>`); que ele volte para cada pasta nova é **inferido**, não medido. O diálogo de "Bypass Permissions" **não** apareceu com `--dangerously-skip-permissions`. Depois dos diálogos o hook de `SessionStart` imprimiu `gc: not found` (esperado até o atalho da fatia .1.2). Os três diálogos já foram atendidos uma vez no servidor para o `canary`: `~/.claude.json` de lá agora tem `hasCompletedOnboarding: true` e `hasTrustDialogAccepted: true` **só** para `/home/runner/gt-remote/canary` (medido).
* **`fingerprint --compare` (credencial do MINI): o hash do `oauthAccount` deu `MUDOU`, saída 1** (`d4decdc9eda73e05` → `9104bfe9066ff574`); o `mdat` do Keychain andou (`23:13:41Z` → `08:59:41Z`, só informa). Isso **não** é o login do servidor mexendo no mini, e a prova é a linha do tempo, toda do lado do mini e toda **anterior** ao login das 11:41Z:

  | Quando (Z) | O que | Fonte |
  |---|---|---|
  | 14/10 23:22 | `fingerprint --save` (o "antes") | `fp-before.json` |
  | 14/10 23:22 → 15/10 01:00 | o daemon de contas das crews fez `SWITCH crews (unknown) -> athosb85 (heal)` 28 vezes (a cada 1–5 min), com o aviso "the default item holds no full login" | `.gc/logs/claude-crew-account.log` |
  | 15/10 01:04:26 | `profileFetchedAt` de `oauthAccount` (o `claude` regrava o objeto inteiro ao buscar o perfil) | `~/.claude.json` |
  | 15/10 08:59:41 | último `mdat` do item padrão do Keychain | `security find-generic-password` (só atributos) |
  | **15/10 11:41:15** | **login do servidor** | `.credentials.json` no servidor |
  | depois das 11:41 | **zero** `SWITCH` nos logs de conta de pool e de crew (último de crew 01:00:28; último de pool 14/10 22:32:17) | os dois logs |

  O servidor estava deslogado o tempo todo antes das 11:41 (`logged-out` às 23:24Z de 14/10 e às 00:25Z de 15/10), então ele não pode ter causado nada anterior; e nada na credencial do mini tem carimbo posterior ao login. O mini segue `loggedIn: true` (`claude auth status`) e as sessões de pool continuam abrindo com o item de pool (`POOL-ACCT SET`, 12:17Z). O que **não** dá para provar a posteriori: campo a campo, o que mudou entre 23:22 e 01:04 (só existia o hash do "antes", sem o objeto).
* **Defeito da prova, não do servidor:** `fingerprint` hasheia o `oauthAccount` inteiro, e o `claude` reescreve esse objeto sozinho (`profileFetchedAt`) quando o mini troca de conta; um "antes" tirado 15 h antes do login, numa máquina cujos daemons de conta trabalham o dia todo, não consegue dar "igual". A forma certa de repetir a prova (outro servidor, outra conta): `fingerprint --save` **imediatamente antes** do login e `--compare` logo depois, e conferir com `SWITCH` nos logs de conta no intervalo.
* **Ficou aberto, fora desta fatia:** o `claude auth login` do Athos continua vivo no terminal dele no servidor (`pts/0`, desde 10:42Z, escutando em `127.0.0.1`); o login que gravou a credencial foi às 11:41:15Z. É inofensivo hoje, mas se alguém colar um código nele depois ele pode regravar a credencial: o ideal é o Athos fechar aquele terminal.
* **Remote Control (procedimento):** abrir no servidor, em tmux, `claude --remote-control` com os mesmos argumentos do provider, olhar o painel (`tmux capture-pane`) e gravar **funciona / não funciona** com o texto da tela. Se não funcionar, avisar o provider (.1.1) para não repetir a flag nesse host. (Feito acima: funciona.)
* **`ask` × `deny` com `--dangerously-skip-permissions`** (ponto 7 do runbook do bundle): `claude -p` pedindo um `rm -rf` de um scratch, uma vez só com o `ask` do `~/.claude` e uma vez com o `deny` do city. Fora do aceite desta fatia, mas é o que o runbook do bundle manda medir antes de o provider construir em cima.
* **Cota:** o primeiro texto real de "sem cota" e de "login expirado" só aparece quando acontece; o classificador foi provado com texto sintético (ver abaixo). Quando acontecer, comparar com `QUOTA_RE`/`EXPIRED_RE` e ajustar.

## Como o provider e o Pilot usam o `gate`

Contrato: `python3 -I $GC_CITY_PATH/scripts/hetzner-claude.py gate` → saída 0 e a linha `ok`, ou saída 1 e `blocked: <estado>: <motivo>`. Exceção inesperada dentro do `gate` (inclusive gravação do estado que falha) também sai 1, como `blocked: unknown: erro interno: …`; configuração inválida (ex.: `HETZNER_STATE_TTL=abc`) sai 2 antes de medir qualquer coisa. Quem chama trata **qualquer saída ≠ 0** como bloqueado.

O ponto de chamada é o `start` do provider `gc-session-ssh` (fatia .1.1), antes de abrir a sessão: saída ≠ 0 → recusar o `start` com a mensagem do gate. **Só o `start` é segurado**: sessão já aberta e bead em andamento não são tocados (o gate não mata nem reclama nada). **Esta fatia não faz essa chamada** — o provider da .1.1 ainda não está mergeado e quem liga `[session] provider` é o Mayor —, então hoje o aceite "o Pilot deixa de abrir sessões novas no servidor até normalizar" está entregue como **mecanismo** (o `gate`), não como fiação. Comentário deixado no ga-2hd02v.1.1 com o ponto de chamada.

Não há poller periódico, de propósito: o estado se renova quando alguém pergunta (o `gate` antes de cada `start`, ou `status`). Um login que expira sem que ninguém abra sessão lá não avisa até a próxima pergunta; se isso incomodar, a saída é um plist de `status` a cada 15 min (o selftest e a trava já suportam), e não um detector novo.

## Medido, inferido, não testado

**MEDIDO**
* Tudo da seção "O que está no servidor agora".
* `gate`/`status` contra o servidor real, deslogado: `state: logged-out`, saída 1.
* Selftest: **248 casos, 0 falhas** (`bash scripts/hetzner-claude.selftest.sh`; medido em 15/10 depois do rebase da 5b sobre a main que já tem o conserto do gate da 5a e depois da varredura de auditoria abaixo, com a máquina em load 58-69; a parte do `fingerprint` que depende do Keychain imprime `SKIP` fora do macOS). Os casos novos da revisão do gate de 15/10 (abaixo) reprovam contra o script que o gate revisou: **125 ok, 22 falhas** (medido na 5a, quando o selftest tinha 147 casos, com `HETZNER_CLAUDE_UNDER_TEST` apontando para o script anterior), inclusive o `leak-scan` pendurado num FIFO e o aviso repetido 3 vezes com a gravação falhando. Os casos de 14/10 "sonda sempre na mesma pasta" e "canary sem ferramenta" reprovam contra o script do commit anterior (3 falhas; medido em 14/10, antes da divisão em fatias). O caso da 5b "destino fora das raízes" reprova contra o mutante que apaga a guarda (abaixo).
* Mutantes: a campanha de 24 cópias do script, cada uma com UMA guarda apagada, foi feita em 14/10 sobre o script inteiro, antes da divisão em fatias: 24 de 24 reprovam (as guardas do instalador e do `push-bundle` entre elas, que são da 5b). O código das guardas é o mesmo, linha por linha; a campanha inteira não foi repetida por fatia, mas uma amostra de 6 mutantes das guardas da 5a foi rodada depois da divisão (gate aceitando `unknown`, `is_error` ignorado, data no futuro como cache, canary com ferramenta, leak-scan tratando pasta vazia como limpa, fingerprint tratando `unknown` como igual): 6 de 6 reprovam. Das guardas da 5b, na 1ª rodada de 14/10 sobreviveu 1 — `inside(d)`, a recusa de destino fora das raízes: o caso não existia; sem a guarda o instalador ainda recusava, mas com um `StopIteration` em vez da mensagem. Ganhou caso e o mutante reprova. **Não refeito depois do rebase:** a campanha é anterior ao conserto do gate da 5a; o que foi medido depois do rebase é só o selftest inteiro (248 casos).
* Dois builds seguidos do bundle deram o mesmo `bundle_hash` (`0d204dbbebe6`), e o mesmo do de 14/10 00h. **Medido em 14/10 pela 5b; não refeito depois do rebase** (o build lê o `~/.claude` do mini, que mudou desde então, então um hash novo não provaria nada sobre esta entrega).
* **Varredura de "não sei" virando resposta, nas linhas da 5b (15/10, antes de submeter): 2 achados, os dois consertados.** (1) O `push-bundle` apagava, do registro do bundle anterior, com `inside()` só léxico: um symlink numa pasta do caminho (ex.: `~/.claude/hooks` virando link) levava o `os.remove` para FORA das raízes. Agora usa `linked()` como a instalação, e o que ficou sem remover é contado na saída (`N NAO removidos`), não calado. (2) O `plugins` lia a lista de DEPOIS de instalar com `or []`: lista ilegível saía como "faltam ou estão desligados"; agora diz que não conseguiu reler. Os 7 asserts novos reprovam contra o script de antes do conserto: **243 ok, 5 falhas** (medido, mesmo selftest, `HETZNER_CLAUDE_UNDER_TEST` apontando para a cópia anterior), inclusive o do symlink, em que o arquivo do outro lado de fato sumia; contra o script consertado: 248 ok, 0 falhas. Considerado e deixado como está: `install-claude` trata "não consegui ler a versão do servidor" como "não instalado" e segue para instalar; é idempotente (versão fixa, hash conferido) e, se o ssh está fora, o passo seguinte falha também.

**INFERIDO**
* Cada `gate` com cache vencido custa 1 ssh e, de hora em hora, 1 chamada haiku de 1 turno na cota da conta; ordem de grandeza desprezível, não medido.

**MEDIDO DEPOIS DO LOGIN (15/10)**
* `status --fresh --probe` `ok`, `canary` `ok`, credencial `-rw-------`, `leak-scan` 0 achados no que a rodada produziu, Remote Control funciona, e o `fingerprint --compare` literal dá `MUDOU` com causa anterior ao login (tudo em "Depois do login").

**REVISÃO DO GATE (15/10, tentativa 1 → conserto)** — o gate reprovou por dois bloqueios e eu varri a CLASSE de cada um, não só o exemplo citado:
* **"Não olhei" saía como "limpo" no `leak-scan`.** Symlink para PASTA (vem em `dirnames`, o `os.walk` não entra) não era lido nem contado; agora todo symlink é contado e, se o alvo não está dentro de uma raiz varrida, vira `NÃO CONSEGUI LER` e saída 3. Mesma família, achada na varredura: FIFO/dispositivo na árvore **pendurava** o scan (medido: `PENDUROU` contra o script antigo) e agora é recusado antes de abrir; raiz que não rendeu nenhum arquivo (pasta vazia entre raízes com arquivo) deixava o total "limpo"; arquivo dado na linha de comando que é symlink agora é lido.
* **O aviso dependia de uma gravação que pode falhar.** `notify`/log saíam antes de `write_state`; com a gravação falhando, cada chamada do `gate` repetia o aviso (medido: 3 chamadas, 3 avisos). Agora a transição só roda depois de o estado estar gravado, e o `.tmp` não fica para trás. O teste antigo apontava o estado para um arquivo e falhava na trava, antes de medir; os dois caminhos têm caso próprio (pasta de estado inutilizável; arquivo de estado que é uma pasta; pasta sem permissão de escrita).
* Da mesma revisão, sem bloqueio: `fingerprint --save` recusa gravar um "antes" desconhecido (3); `--compare` com "antes" que não é objeto, e `--save` onde não dá, saem 3 e não o 1 de `MUDOU`; o aviso passou a se apoiar no último estado **medido** (`known` no estado), então `ok → ssh fora → logged-out` avisa; quem esperou a trava herda a medida de quem a tinha (sem ssh repetido); `ssh`, `notify` e `security` não herdam o stdin do chamador; os absolutos do runbook foram corrigidos (saída 2 de configuração, ~170 s de pior caso, hooks do bundle rodam no canary, `status --fresh --probe` solta após re-login).
* Mutantes das guardas novas: 11 cópias do script, cada uma com UMA guarda apagada (symlink de pasta, aviso antes da gravação, `known`, stdin, releitura após a trava, arquivo comum, raiz vazia, `--save` com `unknown`, `.tmp`, alvo dentro da raiz, "antes" não-objeto): **11 de 11 reprovam** o selftest.
* **A varredura "0 achados em 25 arquivos" de 15/10 foi feita com a versão ANTIGA do `leak-scan`**, que não via symlink de pasta. Refeita com a nova no que ainda existe no mini: log, estado e `fp-before` → 3 arquivos, 0 achados, 0 symlinks; `scripts/` da branch → 344 arquivos, 0 ilegíveis, 3 symlinks (todos dentro da raiz, em `pytest-shim/bin`) e 6 arquivos com "formato de token", os mesmos explicados acima (regex do próprio detector, fixtures sintéticas). **Não refeita:** a cópia dos arquivos instalados no servidor (não foi guardada); aquela parte vale como prova sobre arquivos, não sobre symlinks de pasta dentro dela.

**NÃO TESTADO**
* Hooks do bundle rodando de verdade no Linux além do `SessionStart` (que rodou e deu `gc: not found`, esperado): os demais `keep` nunca foram exercitados lá.
* `ask` × `deny` com `--dangerously-skip-permissions` (fora do aceite desta fatia; segue pendente para o provider).
* Que o diálogo de confiança de pasta volte para cada pasta nova (inferido do texto da tela; medido só em uma pasta).
* O texto real de erro de cota e de login expirado (os casos do selftest são sintéticos; só o de "deslogado" foi medido em 14/10).
* Hooks `gc ...` do bundle no servidor: o atalho `gc` é da fatia .1.2; até lá cada `gc prime`/`gc nudge drain`/`gc mail check` dá "gc: não encontrado" (não derruba o prompt de teste, mas é ruído).

## Limites

* **Tempo do `gate`:** com o cache válido (120 s) é só leitura de arquivo. Com o cache vencido custa 1 ssh (`claude auth status`); a cada hora custa também a chamada de modelo (limite 90 s no servidor, 120 s no mini). Pior caso, calculado dos limites e não medido: ~170 s se o servidor estiver lento (espera da trava 20 s + `claude auth status` 30 s + chamada de modelo 120 s); quem esperou a trava e a encontra com o estado já renovado por quem a tinha não repete o ssh. O `start` do provider tem timeout próprio (60 s por padrão): quem chama o `gate` decide se espera ou trata timeout como bloqueado (o certo é bloqueado).
* **O `canary` mantém `--dangerously-skip-permissions`** porque o que ele prova é que o bundle carrega e a sessão responde com os argumentos que o provider vai usar; a revisão automática de segurança (14/10) apontou o flag, e a resposta foi tirar o que ele poderia soltar: `--tools ""` desliga toda ferramenta, então o modelo do canary não tem como rodar comando, editar arquivo nem abrir rede além da chamada ao modelo. **Os hooks do bundle, esses sim, rodam no canary** (o `SessionStart` rodou, ver "Depois do login"): o `canary` prova o bundle carregando, não um ambiente sem execução. `--tools ""` com esses flags foi medido no mini (`claude -p`, haiku): `is_error false`, resposta `OK`. A sonda de `status`/`gate` nem usa `--dangerously-skip-permissions`.
* **Re-login não é visto sozinho:** depois de `expired`/`quota` o `claude auth status` segue `loggedIn: true`, então o `gate` só mede de novo a chamada de modelo na janela de retry (15 min) mais o cache (120 s). Para soltar na hora depois de um novo login: `status --fresh --probe`.
* Uma conta só. Cota esgotada ou login expirado seguram `start` novo até normalizar; não há failover para outra conta (o mecanismo do mini usa o Keychain do macOS e não existe no Linux).
* O hash do instalador é conferido contra o que o chamador passou, não contra uma fonte independente: quem passa o hash é quem leu o script.
* `leak-scan` reconhece formatos conhecidos (`sk-ant-…`, `accessToken`/`refreshToken` em JSON, `claudeAiOauth`); formato que ele não conhece passa. **O que ele não leu nunca parece limpo** (sai 3 e lista cada item com `NÃO CONSEGUI LER`): arquivo ilegível ou maior que 20 MB, FIFO/socket/dispositivo na árvore (não abre: pendurava), symlink cujo alvo está **fora** das raízes varridas (de arquivo ou de pasta; contado em "N symlinks não seguidos"), e raiz que não rendeu nenhum arquivo (pasta vazia, caminho que não existe). Symlink cujo alvo está dentro de uma raiz varrida passa, porque o alvo foi lido de verdade; arquivo dado na linha de comando é lido mesmo sendo symlink.
* `fingerprint`: o hash do `oauthAccount` decide; o `mdat` do Keychain só informa, porque o mini renova o próprio token o dia todo (medido 14/10: 16:29Z → 22:32Z em 12 min, sem ninguém mexer). **O hash também anda sozinho** quando o `claude` busca o perfil de novo (`profileFetchedAt` está dentro do objeto) ou o mini troca de conta; por isso um "antes" velho dá `MUDOU` mesmo sem ninguém mexer na credencial (medido 15/10, ver "Depois do login"). Quem usar o `--compare` como prova deve tirar o `--save` logo antes do passo e conferir os logs de conta no intervalo; este script não filtra o campo volátil.
* Entrega: fatia 5a, `hetzner-claude.py` com 483 linhas (selftest 212, este runbook 134 + a seção da revisão: 836 no total). Limites do gate E11 por submissão: 800 linhas de produção e 1000 no total (selftest e este runbook contam no total); a entrega inteira passou de 1000 e por isso foi dividida em 5a e 5b.
* Entrega: fatia 5b (`install-claude`, `plugins`, `push-bundle`), medida com `git diff --numstat origin/main` em 15/10 depois do rebase sobre a 5a já em main: `hetzner-claude.py` +276/−3 (passa de 483 a 756 linhas), selftest +145/−2 (212 → 355), este runbook +22/−8 (155 linhas): 443 linhas acrescentadas, 276 de produção. Limites do gate E11 por submissão: 800 de produção e 1000 no total.
