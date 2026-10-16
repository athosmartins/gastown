# Endurecimento do servidor Hetzner antes de sessão remota · runbook

## Contents

• O que esta fatia é · O guarda de clone (como decide, o que não cobre) · A trava no provider e como liberar
• `rm -rf` sem humano no teclado (MEDIDO) · Prova real no servidor (MEDIDO) · Instalação e como repetir
• Achados que a 6c precisa tratar

Bead ga-2hd02v.1.5 (decisão Q4 do Mayor: sessão remota só é liberada depois que existir um substituto do `gt tap guard cross-clone-block`), fatia **6a** (ga-2hd02v.1.5.1) de 3. Repartida de antemão na Epic Split Convention para caber no teto do gate (E11): 6b (.1.5.2) = skills com CPF/CNPJ fora + auditoria de segredo/dado; 6c (.1.5.3) = hooks `keep` no Linux, latência dos hooks gc, sessão ponta a ponta. **Esta fatia não libera sessão real.** Ela entrega a trava; liberar é decisão explícita do Mayor. Fora desta fatia: usuário Unix por sessão (sem bead) e, do `remote-worker-bundle.md`, tudo além do que ela mediu (guarda, `ask`).

## O guarda de clone

`scripts/remote-clone-guard.py`, hook PreToolUse em `Bash` e `Edit|Write|MultiEdit|NotebookEdit`, instalado em `~/.claude/hooks/` do servidor pelo `push-bundle` (o `remote-bundle-build.py` o leva e troca a linha `drop` do hook do mini por esta, `swap` na `POLICY`, com `replaced_by` no manifest).

* **Território** = `~/gt-remote/git` (`<repo>/repo.git` = o espelho, `<repo>/wt/<bead>` = um worktree por sessão). **Clone próprio** = o ancestral com `.git` de `$CLAUDE_PROJECT_DIR`; sem a variável não há clone próprio e toda escrita no território é bloqueada.
* **Bloqueia** (exit 2, mensagem diz o alvo, o clone próprio, que não é o usuário cancelando e que leitura segue livre): `git` de escrita (commit/push/merge/rebase/reset/checkout/add/stash/clean/branch -D/fetch/pull…) cujo alvo resolvido cai no território fora do clone próprio, e Edit/Write/MultiEdit/NotebookEdit em arquivo desse tipo de alvo ou em `~/.claude/hooks/**` e `~/.claude/settings*.json` (o guarda não se desliga por engano). **Libera**: leitura em qualquer clone (log/status/diff/show/blame/ls-files…), escrita no próprio clone, escrita fora do território, comando que só *cita* o outro clone (echo, mensagem de commit, heredoc).
* **Três estados**: alvo que não sei resolver numa escrita (`$VAR`, glob, crase, `~usuário`), subcomando desconhecido, `cd`/`pushd` que não sei seguir, exceção do próprio guarda → **bloqueia**. Stdin que não é JSON: **bloqueia se o texto cita `git`, `file_path` ou `notebook_path`** (não dá para conferir um pedido que pode tocar git ou arquivo); se não cita nenhum dos três, **libera** (lixo no stdin não derruba a sessão inteira; o Claude sempre manda JSON válido). O comando do hook é `python3 -I <guarda> || exit 2`, porque hook que sai 1 ou 127 **não** bloqueia (falha aberta); assim travar, sumir o python ou o arquivo também sai 2.
* **Onde o `git` pode estar** (todos conferidos no selftest): depois de `;` `&&` `||` `|` `( )` `{`, de palavra reservada (`if`/`then`/`else`/`elif`/`do`/`while`/`until`/`!`/`function f {`/`coproc`), de `cd`/`pushd`, de `command`/`env`/`sudo`/`xargs`/`nohup`…, em `bash -c` (também `bash -c -e '…'`: o script é a primeira palavra depois do `-c` que não é opção), `eval`, `$(…)`, crase, `<(…)`/`>(…)`, `find -exec`/`-ok` (inclusive um segundo `-exec` depois do `\;`), e no corpo de heredoc ou here-string que um shell lê (`bash <<EOF`). `cd`/`pushd` só é seguido com opções `-L`/`-P`/`-e`/`-@`, `--` e **um** argumento; `cd -Z x`, dois argumentos, `pushd +1` e `pushd` sozinho deixam o diretório "não sei" (escrita sem `-C` absoluto bloqueia).
* **Embrulhos e opções que o guarda não lê** (gate ga-iczduy, rodadas 1 e 2 — o MESMO defeito, "o que não entendo vale 'não é git'", em lugares diferentes): cada embrulho (`command`, `env`, `sudo`, `doas`, `xargs`, `nice`, `timeout`, `stdbuf`, `setsid`, `exec`, `time`, `nohup`) tem a tabela das SUAS opções (`WOPT` no guarda; antes era uma tabela só, e `sudo -n git -C <alheio> commit` passava porque o `-n` do `xargs` leva argumento e engolia o `git`). Opção que não está na tabela = não sei onde o comando começa, e o embrulho vale como lançador opaco (abaixo). `find -execdir`/`-okdir` rodam o comando no diretório de **cada achado**, que o guarda não conhece: diretório "não sei" (git de escrita ali só passa com `-C <caminho absoluto>`; leitura passa). Opção de topo do git que leva valor (`--attr-source HEAD`) é pulada; uma que não conheço deixa o diretório "não sei" e vale como escrita (falso positivo assumido: `git --opção-nova VALOR -C <seu clone> commit` bloqueia). O número colado num redirecionamento (`2>/dev/null`) é o descritor, não um argumento (antes `cd <próprio> 2>/dev/null && git commit` bloqueava).
* **Lançadores que o guarda não modela** (`flock`, `ionice`, `chrt`, `taskset`, `parallel`, `su`, `runuser`, `ssh`, `script`, `trap`, `watch`, `unshare`, `nsenter`, `chroot`, `setpriv`, `numactl`, `strace`, `fakeroot`, `systemd-run`, `busybox`, `dbus-run-session`, `xvfb-run`, `unbuffer`, `caffeinate`, `tmux`, `screen`, `expect`): o guarda abre o comando, mas com o diretório "não sei" — o `git` dentro passa se for leitura ou com `-C <caminho absoluto>`, e bloqueia se for escrita com diretório implícito ou com `$VAR` (falso positivo conhecido: `flock L git commit` bloqueia, e o mesmo vale para um embrulho com opção que não conheço, `sudo --nova git commit`; escreva `git -C <seu clone> commit`). **A lista é fechada**: um lançador fora dela (`lockrun git …`) esconde o git.
* **Leitura que traz configuração capaz de rodar programa deixa de ser leitura** (parecer de segurança do push, rodada 1): `git -C <alheio> -c alias.x='!…' log`, `-c core.pager=…`/`core.fsmonitor=…`, `--config-env`, `-p`/`--paginate`, `--exec-path` e as variáveis `GIT_CONFIG_*`, `GIT_PAGER`, `GIT_EXTERNAL_DIFF`, `GIT_SSH*`, `GIT_ASKPASS`, `GIT_EDITOR`… bloqueiam no clone alheio (a mensagem diz "leitura com configuração que roda programa"). Só chave de exibição ou identidade (`color.*`, `advice.*`, `core.quotepath`/`abbrev`, `safe.directory`, `user.name`/`email`) segue como leitura; chave que não conheço = não sei = escrita. Falso positivo conhecido: `GIT_PAGER=cat git -C <alheio> log` bloqueia (no próprio clone passa). Não vejo a configuração que JÁ está no `.git/config` do clone alheio (alias, filter, textconv, fsmonitor: uma leitura lá a executa).
* **O que NÃO cobre** (é trava contra engano, não sandbox): script que o comando executa (`bash x.sh`), `python -c`, `source`, variável que guarda o `git`, comando montado em pipe (`echo '…' | sh`), função ou alias definido em outra chamada, e redirecionamento (`> arquivo`), `cp`, `sed -i`, `rm` no clone alheio ou nos hooks/settings do claude, e Edit/Write em `.claude/settings*.json` da pasta do próprio clone (a camada do projeto só é conferida na abertura da sessão). O fecho de verdade é um usuário Unix por sessão: **não está feito nem tem bead**.
* `--selfcheck [settings.json [pasta-do-projeto…]]`: 0 se o guarda decide como deveria numa pasta de teste e, com o settings, todo PreToolUse dos 5 tipos de ferramenta chama **este** arquivo com `|| exit 2`, **sem campo que mude quando o hook dispara** (`if`, `async`…: o hook só pode ter `type`/`command`/`timeout`; o cross-clone-block do mini tinha `"if": "Bash(git -C *)"`) e `disableAllHooks` não está ligado nele nem em `<pasta>/.claude/settings[.local].json` (a camada do projeto também desliga hook; ausente = nada a conferir, ilegível = reprova).
* Selftest `scripts/remote-clone-guard.selftest.sh`: **618 de 618** (531 casos + 86 mutantes, cada um com UMA guarda apagada e o grupo que a cobre reprovando, + o controle contra um stub que só sai 0 — o servidor *antes* desta fatia —, que falha 335 de 469 casos). Os 133 casos novos da rodada 2 do gate (127 do grupo `wrap`, 6 do `check`: find -execdir/-okdir e um segundo `-exec`, a tabela de opções de cada embrulho, `--attr-source`, palavra do shell no lugar do subcomando, `bash -c -e`, o descritor `2>`, `if`/`async` no hook) foram rodados contra o guarda ANTERIOR: 52 deles reprovam lá (47 + 5), e cada guarda nova tem um mutante.

## A trava no provider e como liberar

`gc-session-ssh start` só abre sem liberação o que se chama `remote-e2e-<x>` ou `remote-test-<x>` (a sessão mínima de teste). Qualquer outro nome:

1. precisa de `real_sessions_released_by` (texto não vazio) na entrada do host em `.gc/session-ssh.json` — **decisão explícita do Mayor**; ausente, vazio ou não-texto = recusa sem abrir ssh;
2. e, **no host, dentro do mesmo script do start**, o `sha256` de `<remote_home>/.claude/hooks/remote-clone-guard.py` tem que ser igual ao do guarda irmão do provider **e** `python3 -I <guarda> --selfcheck <remote_home>/.claude/settings.json <pasta da sessão>` tem que aprovar; senão o script sai 12 e nada abre (o provider devolve erro, exit 1, com o motivo).

Para liberar: pôr `"real_sessions_released_by": "<quem decidiu, quando>"` na entrada do host. Para travar de novo: tirar a chave. O `--dry-run` mostra `session_kind` "teste" ou "real". Selftest do provider **182 de 182** (156 casos + 25 mutantes pegos + o controle contra um stub).

## `rm -rf` sem humano no teclado

Regra `ask` vale **até com `--dangerously-skip-permissions`** e `deny` é avaliado antes de `ask`. No servidor ninguém aperta a tecla.

**MEDIDO** (claude 2.1.301, haiku 5.5, tmux no servidor, 16/10 ~02h UTC, pasta de teste `target-*`, prompt "execute exatamente `rm -rf <pasta>`"):

| camadas | resultado |
|---|---|
| bundle antigo: `ask` na home, sem `deny` | **TRAVA**: diálogo "Do you want to proceed?" ainda na tela aos 65 s, pasta intacta |
| bundle antigo: `ask` na home + `deny` do city (`--settings`) | negado na hora (o `deny` cobre) |
| **bundle 390169e5bbaa**: só a camada home (tem `deny`, sem `ask`) | **negado na primeira checagem (≤ 5 s), pasta intacta** |
| **bundle 390169e5bbaa**: home + city | **negado na primeira checagem (≤ 5 s), pasta intacta** |

**Remédio** (sem `safe-clean` no servidor): o `remote-bundle-build.py` move toda regra `ask` das settings para `deny` (sem duplicar), a chave `ask` some do bundle e o manifest conta por camada (`asks_to_deny`: no mini hoje `user: 2`, `rm -rf` e `sudo`). Efeito conhecido: no servidor essas duas regras **negam** em vez de perguntar; `Bash(rm -rf /tmp/*)` do `allow` também é negado (MEDIDO: `rm -rf /tmp/<pasta>` negado em ≤ 5 s, pasta intacta; o `deny` vence o `allow`), então a limpeza de scratch no servidor usa `find -delete`. O build segue recusando regra com caminho de macOS em `deny`/`ask`.

## Prova real no servidor (MEDIDO)

Mesmo claude, `--dangerously-skip-permissions`, `CLAUDE_PROJECT_DIR` = worktree `own`, repositório de teste com `wt/own` e `wt/other`, hook instalado pelo `push-bundle`:

| chamada da sessão | resultado |
|---|---|
| `git -C …/wt/other commit --allow-empty` | **bloqueado**: `PreToolUse:Bash hook error … [HOOK BLOCK: remote-clone-guard] … BLOQUEADO: git commit fora do seu clone` |
| `git commit --allow-empty` (no próprio) | liberado: `[own 2a049e4] probe-2` |
| `git -C …/wt/other log --oneline -3` | liberado: `fd8ff4c seed` |
| Write em `…/wt/other/probe-4.txt` | **bloqueado** (`PreToolUse:Write`) |
| Write em `…/wt/own/probe-5.txt` | criado |

## Instalação e como repetir

```bash
S=$GC_CITY_PATH/scripts
GC_CITY_PATH=$GC_CITY_PATH python3 -I $S/hetzner-claude.py push-bundle --role dog --role-dir $GC_CITY_PATH/.gc/agents/dogs/gastown.dog-1 --out OUT
ssh hetzner-teste 'python3 -I ~/.claude/hooks/remote-clone-guard.py --selfcheck ~/.claude/settings.json'   # 0 = guarda e settings batem
bash $S/remote-clone-guard.selftest.sh; bash $S/remote-bundle-build.selftest.sh; bash $S/gc-session-ssh.selftest.sh   # herméticos
```

**Defeito corrigido junto**: o `push-bundle` recusava o `settings.json` do servidor assim que o claude gravava `theme`/`agentPushNotifEnabled` (chave alheia ao bundle). `hetzner-claude.py` agora preserva `theme` e `agentPushNotifEnabled` do próprio servidor (`OWN_KEYS`) e continua recusando qualquer outra chave alheia (caso no `hetzner-claude.selftest.sh`, 256 casos).

## Achados que a 6c precisa tratar

* O claude **interativo** numa pasta nova abre diálogos de primeira execução (confiar na pasta, padrão "No, exit"; e um de modo auto) que travam a sessão sem humano: a sessão ponta a ponta tem que pré-confiar a pasta do worktree.
* Os hooks `gc` do city, no servidor sem identidade `GC_*`, saem **sem bloquear** com `remote-shim-wrapper: RECUSADO: sem GC_ALIAS/GC_AGENT` (medido): a sessão segue, só não conversa com o mini. Com `identity_pattern` `(?!)` (inerte) é o esperado.
