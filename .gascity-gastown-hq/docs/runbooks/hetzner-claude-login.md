# Claude Code no servidor Hetzner (login, bundle, plugins, status) · runbook

## Contents

• Estado em uma linha · O que esta fatia é — e o que não é
• O que está no servidor agora (medido) · Comandos (`hetzner-claude.py`)
• O login — passo humano do Athos, guiado pelo Mayor · Depois do login: verificação, em ordem
• Como o provider e o Pilot usam o `gate` · Medido, inferido, não testado · Limites

Bead ga-2hd02v.1.4 (fatia 5 do ga-2hd02v, desenho do ga-ukxa3k).

## Estado em uma linha

`claude` 2.1.300 (a mesma versão do mini), 3 plugins e o bundle `0d204dbbebe6` estão instalados e conferidos no servidor `hetzner-teste`; **o servidor NÃO está logado** (o login é do Athos) e por isso `hetzner-claude.py gate` sai 1 (`blocked: logged-out`). Tudo que só se mede depois do login está em "Depois do login" e **não foi testado**.

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
* Login: `claude auth status --json` → `loggedIn=false`, `authMethod=none`; `~/.claude/.credentials.json` não existe. `claude remote-control` sem login responde *"You must be logged in to use Remote Control. Remote Control is only available with claude.ai subscriptions"* — o login do servidor precisa ser pela **assinatura** (`--claudeai`, o padrão), não pelo Console.
* A credencial do mini, antes do login: `fingerprint --save` gravado em `<cidade>/.gc/hetzner-claude.fp-before.json` (14/10 20h22 BRT; `.gc/` não é versionado). É contra esse arquivo que o `--compare` roda depois.

Arquivos que esta fatia escreveu no servidor (tudo dentro de `/home/runner`): `~/.local/bin/claude`, `~/.local/share/claude/`, `~/.claude/` (settings, hooks, plugins, backups, projects de teste), `~/.claude.json`, `~/gt-remote/bundle/`, `~/gt-remote/bundle-out/`, `~/gt-remote/bin/remote-bundle-build.py`, `~/gt-remote/home-settings.merged.json`, `~/gt-remote/bundle-installed.json` e, no `canary`, `~/gt-remote/canary/`. O único `rsync --delete` é sobre `bundle-out/`.

## Comandos (`hetzner-claude.py`)

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/hetzner-claude.py gate                       # 0 só se o login está POSITIVAMENTE bom; senão 1 e "blocked: <estado>: <motivo>"
python3 -I $S/hetzner-claude.py status [--fresh] [--probe] # JSON do estado; --fresh ignora o cache, --probe força a chamada de modelo
python3 -I $S/hetzner-claude.py install-claude --installer-sha256 <hash> [--version V]
python3 -I $S/hetzner-claude.py plugins                    # instala o que falta e lista o resultado
python3 -I $S/hetzner-claude.py push-bundle --role dog --role-dir <dir do papel> --out <OUT novo ou do próprio builder>
python3 -I $S/hetzner-claude.py canary                     # sessão mínima do jeito do provider (--settings do bundle, --dangerously-skip-permissions)
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

Nada abaixo foi executado ainda; cada item grava o resultado no bead.

```bash
S=$GC_CITY_PATH/scripts
python3 -I $S/hetzner-claude.py status --fresh --probe          # esperado: "state": "ok", saída 0
python3 -I $S/hetzner-claude.py canary                          # esperado: "canary: ok" (bundle como --settings, sonnet)
python3 -I $S/hetzner-claude.py fingerprint --compare $GC_CITY_PATH/.gc/hetzner-claude.fp-before.json   # oauthAccount "igual" decide; keychain_mdat só informa (o mini renova o token sozinho)
python3 -I $S/hetzner-claude.py leak-scan $S $GC_CITY_PATH/.gc/hetzner-claude.log <OUT do bundle> <export dos beads da fatia em arquivo>
ssh hetzner-teste 'ls -l ~/.claude/.credentials.json'           # -rw------- runner
```

* **Remote Control:** abrir no servidor, em tmux, `claude --remote-control` com os mesmos argumentos do provider, olhar o painel (`tmux capture-pane`) e gravar aqui **funciona / não funciona** com o texto da tela. Se não funcionar, avisar o provider (.1.1) para não repetir a flag nesse host.
* **`ask` × `deny` com `--dangerously-skip-permissions`** (ponto 7 do runbook do bundle): `claude -p` pedindo um `rm -rf` de um scratch, uma vez só com o `ask` do `~/.claude` e uma vez com o `deny` do city. Fora do aceite desta fatia, mas é o que o runbook do bundle manda medir antes de o provider construir em cima.
* **Cota:** o primeiro texto real de "sem cota" e de "login expirado" só aparece quando acontece; o classificador foi provado com texto sintético (ver abaixo). Quando acontecer, comparar com `QUOTA_RE`/`EXPIRED_RE` e ajustar.

## Como o provider e o Pilot usam o `gate`

Contrato: `python3 -I $GC_CITY_PATH/scripts/hetzner-claude.py gate` → saída 0 e a linha `ok`, ou saída 1 e `blocked: <estado>: <motivo>`. Qualquer falha interna também é 1.

O ponto de chamada é o `start` do provider `gc-session-ssh` (fatia .1.1), antes de abrir a sessão: saída ≠ 0 → recusar o `start` com a mensagem do gate. **Só o `start` é segurado**: sessão já aberta e bead em andamento não são tocados (o gate não mata nem reclama nada). **Esta fatia não faz essa chamada** — o provider da .1.1 ainda não está mergeado e quem liga `[session] provider` é o Mayor —, então hoje o aceite "o Pilot deixa de abrir sessões novas no servidor até normalizar" está entregue como **mecanismo** (o `gate`), não como fiação. Comentário deixado no ga-2hd02v.1.1 com o ponto de chamada.

Não há poller periódico, de propósito: o estado se renova quando alguém pergunta (o `gate` antes de cada `start`, ou `status`). Um login que expira sem que ninguém abra sessão lá não avisa até a próxima pergunta; se isso incomodar, a saída é um plist de `status` a cada 15 min (o selftest e a trava já suportam), e não um detector novo.

## Medido, inferido, não testado

**MEDIDO**
* Tudo da seção "O que está no servidor agora".
* `gate`/`status` contra o servidor real, deslogado: `state: logged-out`, saída 1.
* Selftest: 185 casos, 0 falhas. Mutantes (cópias do script com UMA guarda apagada, o selftest rodado contra cada uma): `MUTANTES_PLACEHOLDER`.
* Dois builds seguidos do bundle, mesmo `bundle_hash` (`0d204dbbebe6`), e o mesmo do de 14/10 00h.

**INFERIDO**
* Cada `gate` com cache vencido custa 1 ssh e, de hora em hora, 1 chamada haiku de 1 turno na cota da conta; ordem de grandeza desprezível, não medido.

**NÃO TESTADO**
* Tudo que depende do login: `ok`, `canary`, Remote Control, `fingerprint --compare`, `leak-scan` do que o login produz, hooks do bundle rodando de verdade no Linux (os `keep` nunca foram executados lá).
* O texto real de erro de cota e de login expirado (os casos do selftest são sintéticos; só o de "deslogado" foi medido em 14/10).
* Hooks `gc ...` do bundle no servidor: o atalho `gc` é da fatia .1.2; até lá cada `gc prime`/`gc nudge drain`/`gc mail check` dá "gc: não encontrado" (não derruba o prompt de teste, mas é ruído).

## Limites

* Uma conta só. Cota esgotada ou login expirado seguram `start` novo até normalizar; não há failover para outra conta (o mecanismo do mini usa o Keychain do macOS e não existe no Linux).
* O hash do instalador é conferido contra o que o chamador passou, não contra uma fonte independente: quem passa o hash é quem leu o script.
* `leak-scan` reconhece formatos conhecidos (`sk-ant-…`, `accessToken`/`refreshToken` em JSON, `claudeAiOauth`); formato que ele não conhece passa. Arquivo que não lê ou maior que 20 MB sai 3 ("não consegui ler" nunca vira "limpo").
* `fingerprint`: o hash do `oauthAccount` decide; o `mdat` do Keychain só informa, porque o mini renova o próprio token o dia todo (medido 14/10: 16:29Z → 22:32Z em 12 min, sem ninguém mexer).
* Entrega: `hetzner-claude.py` com 692 linhas (limite do gate E11: 800 de produção; o selftest e este runbook não contam).
