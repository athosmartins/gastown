# guard-oracle-diff · cc-safety-net como oráculo diferencial dos nossos guards (ga-nkfwixz)

## Contents

• Estado e o que o Mayor decide · Gate: tentativa 1 e o que mudou · Como foi medido
• 1. O corpus do nosso fuzzer · 2. Formas que o runbook do remote-clone-guard admite não cobrir
• 3. rm -rf: a regra deny do nó · 4. Instalar o safety-net por cima?
• 5. Segredo: o secret-read-guard · Como ligar o secret-read-guard · Limites e falsos positivos
• Como repetir · O que fica para outra bead

## Estado e o que o Mayor decide
- **Entregue, dormente:** `scripts/secret-read-guard.py` + `scripts/secret-read-guard.selftest.sh` (229 casos, 39 mutantes, fuzzer contra o bash real). Nenhum `settings.json` o chama.
- **Decisão do Mayor (risco):** ligar o secret-read-guard ou não, e onde. Recomendação: primeiro no nó Hetzner (login do claude, chave do mini e chave do espelho moram no mesmo disco da sessão), depois nos overlays `pool-*`. Trecho e custo em "Como ligar".
- **Não portado (vira bead, motivo em cada seção):** guard de `rm` por alvo (seção 3) e as 12 formas de interpretador/pipe no remote-clone-guard (seção 2).
- **Veredito sobre instalar o safety-net por cima: não.** Ele nega `git reset --hard origin/<branch>` e `git worktree remove --force`, dois passos que a nossa doutrina manda copiar (seção 4).

## Gate: tentativa 1 e o que mudou
A revisão da tentativa 1 (ga-nkfwixz, gate_run ga-hyctgz0) reprovou por 4 defeitos reproduzidos, todos do mesmo formato: **o guarda tinha a informação, ou sabia que não sabia, e devolveu o mesmo "liberado" de "não é segredo"**. O que o docstring prometia ("falha do próprio guarda = bloqueado") e o runbook dizia ("0 bypass") não era o que o código fazia.
- **Aninhamento acima de 6 níveis** devolvia liberado; agora BLOQUEIA (`secret.nesting-too-deep`), como já fazia o teto da chave `{a,b}`.
- **Variável que é prefixo de outra** (`H=1; cat $HOME/…`) trocava `$H` dentro de `$HOME` e o caminho que o shell abre sumia da vista; a troca agora é por NOME INTEIRO, numa passada só.
- **Variável atribuída a vazio** (`X=; cat ~/.ssh/id_rsa$X`) era lida como "desconhecida" e pulada; vazio agora vale vazio.
- **`find -name .env | xargs cat`**: o valor de `-name` só é isento quando a saída do `find` não vira operando de outro comando; o código nunca consultava essa condição.

A classe, varrida no diff inteiro e no fuzzer (a gramática da tentativa 1 não gerava nenhuma dessas formas, por isso "0 bypass" era verdade só para ela), achou irmãos que a revisão não citou. Todos fechados, cada um com linha na tabela e mutante:
- `$( )` e crase em **atribuição** (`X=$(cat ~/.ssh/id_rsa)`), **alvo de redirecionamento**, **here-string** e **heredoc sem aspas** não eram varridos (só as palavras depois das atribuições).
- Valor **relativo** de variável era colado ao cwd da atribuição (`D=.gnupg; cd ~; cat $D/pubring.kbx`); agora vale onde é USADO. `export`/`declare`/`local` registram a variável.
- Caminho com pedaço que não sei resolver (`$X`, `$( )`) era pulado inteiro; agora valem a **pasta literal antes do pedaço** (`~/.ssh/$k`) e o **nome do fim** (`$(echo ~)/.ssh/id_rsa`). `${X:-padrão}` vale o padrão quando X é vazio ou desconhecido.
- `{~/.gnupg/x,y}`: o bash faz a chave ANTES do `~`; o guarda fazia o contrário. `git show :.env` e `:0:.env` (índice do git).
- Varredura recursiva (`grep -r`, `find`, `tar`, `cp -r`, Grep) sobre o **ancestral de um segredo do catálogo** (`~/.claude` guarda `.credentials.json`; `~/.config`, `~/.docker`, `~/.kube`, `~/.dolt`, `~/gt-remote`) lia o segredo sem nomeá-lo. Achado pelo fuzzer novo (`head $(find ~/.claude -name .credentials.json)`). O Glob só lista nomes e fica de fora.
- **Grep/Glob sem `path`** varrem o cwd da sessão: valem como se o cwd estivesse escrito.

## Como foi medido
- Pacote npm `cc-safety-net@2.7.0`, sha512 conferido com o registro, zero dependências de execução; o código de análise só chama `git` e `getconf`. Rodado **só** dentro de `gt-iso-run` (netns sem saída, ambiente limpo, sem capabilities; canário "isolado"), pela API `checkCommand` (análise estática, não executa o comando) e, para ferramentas de arquivo, por `hook --claude-code`. Uma corrida de 1.500 comandos registrou 1 tentativa de saída barrada; não reproduziu em duas repetições do mesmo lote nem nas demais corridas, e a origem não foi achada.
- **A verdade é o bash real**: `git` falso que registra argv e alvo, leitores falsos (`cat`, `head`, `cp`…) que registram o caminho FINAL que o shell entregou, e escrita por arquivo que mudou. É o método do fuzzer do `remote-clone-guard` (grupo `fuzz`), estendido.

## 1. O corpus do nosso fuzzer
Semente 7, 1.500 comandos: 1.098 escrevem no clone alheio no bash real. O `remote-clone-guard` bloqueia os 1.098 (0 bypass). O safety-net bloqueia 130, os `reset --hard` (ele não olha o alvo). **Nenhum caso em que ele pega e o nosso não**, a não ser `reset --hard` no clone PRÓPRIO (48), que é política, não furo.
Sentido inverso: dos 212 `reset --hard` que o bash real executou, o safety-net deixou passar 25, todos da forma `echo $(case a in a) git … reset --hard;; esac)` (o `)` do `case` fecha o `$( )` no parser dele). 88% de recall na própria especialidade.

## 2. Formas que o runbook do remote-clone-guard admite não cobrir
68 formas (alvo absoluto e relativo = 136 casos), todas executando `git reset --hard` no clone alheio no bash real. O nosso guard deixa passar 25 formas, o safety-net 14.

| quem pega | formas |
|---|---|
| **nenhum dos dois** (13) | alias; variável com o comando (`G=git; $G -C …`, `G='git -C x'; $G reset`); script escrito e rodado (`bash s.sh`, `source`, `. ./s.sh`, `./s.sh`); `node -e` com `spawnSync`; python com `subprocess.run([...])` em lista, `Popen`, `cwd=`, `os.chdir`, diretório em variável |
| **só o safety-net** (12) | `python -c` com `os.system` ou `shell=True`; `node -e` com `execSync`; `perl -e` com `system` e crase; `awk 'BEGIN{system(…)}'`; texto montado em pipe (`echo '…' \| sh`, `printf … \| bash -s`); base64 decodificado e `eval`; `eval "$(… \| rev)"`; `printf -v` + `eval` |
| **só o nosso** (1) | array expandido `"${a[@]}"` |
| os dois pegam | `sudo`, `xargs`, `find -exec/-execdir`, `env -S`, `nohup`, `timeout`, heredoc, here-string, `<(…)`, aspas partidas, `command`, `exec`, `time`, `( )`, `{ }`, `&&`/`\|\|`, `bash -c`, `eval` |

Os 12 de "só o safety-net" são o que dá para portar para dentro do `remote-clone-guard`: extrair o texto de shell dos literais de `-c`/`-e`/heredoc de python/node/perl/awk e conferir como comando, e tratar `echo|printf '<texto>' \| sh\|bash -s` como código. Não foi feito aqui: o arquivo tem 730 linhas já gateadas 8 vezes, o teto E11 da bead não comporta e o risco é de cada sessão do nó. Aceite da bead futura: as 12 formas viram `b 2` no selftest dele.

## 3. rm -rf: a regra deny do nó
Medido **ao vivo** nesta sessão (alvo inexistente, sem dano). `permissions.deny: Bash(rm -rf:*)` barrou 2 de 7 formas:

| forma | nó |
|---|---|
| `bash -c 'rm -rf X'`, `env rm -rf X` | negado |
| `rm -fr X`, `rm -r -f X`, `rm --recursive --force X`, `/bin/rm -rf X`, `python3 -c "subprocess.run(['rm','-rf',X])"` | **rodou** |

O safety-net, com alvo perigoso (`~`, `/home/runner`, `../outro-clone`): nega `-rf`, `-fr`, `-r -f`, `--recursive --force`, `/bin/rm`, `bash -c`, `env`, `find ~ -delete` e libera `rm -fr build/` e scratch em `/tmp` (decide pelo **alvo**, não pela ordem das flags). Ele também deixa passar a forma `subprocess.run(['rm','-rf',…])`. Hoje a "proteção contra `rm -rf`" do nó é um prefixo de texto que a ordem das flags desfaz. Porte recomendado, em bead própria: hook PreToolUse que normaliza as flags do `rm` e decide pelo alvo (raiz, HOME, fora do clone próprio), mais a limpeza de scratch por `find -delete`, que a doutrina do nó já manda.

## 4. Instalar o safety-net por cima?
Não. Dos 20 comandos que testei (fluxo documentado do dog e comandos comuns), ele nega 6: `git reset --hard origin/<branch>` e `git worktree remove --force` (os dois **literais** da doutrina de conserto de branch e do idioma de worktree) e, além deles, `git clean -fd`, `git checkout -- .`, `git branch -D`, `git reset --hard HEAD~1`. Dois guards em cima um do outro dobram o falso positivo sem fechar o que falta (seções 2 e 3). O catálogo dele no corpus de testes do repositório dele (`tests/fixtures/gate/harvested-verdicts.jsonl`: 6.983 literais, 63 regras que negam) é, em grande parte, política de outro público: git destrutivo no clone próprio, `rm`, `dd`, `mkfs`, `shred`.

## 5. Segredo: o secret-read-guard
Achado esperado, confirmado: **nenhum hook nosso olha caminho de segredo**; Read, Grep e Glob nem têm hook neste nó, e `cat ~/.ssh/id_ed25519` passa. O guard novo cobre Read/Grep/Glob/Edit/Write/MultiEdit/NotebookEdit e o Bash (catálogo portado de `secret.ts` do safety-net, cortado ao que existe nas nossas máquinas, mais `~/gt-remote/keys`).
- **Contra o safety-net** (veredito dele congelado na coluna SN da tabela do selftest, conferida linha a linha contra ele: 98 de 98): concorda em 94 de 104 sondas de Bash. As 13 divergências do selftest são escolha minha, todas marcadas `dev`: `~/.ssh/config`, `known_hosts` e `*.pub` legíveis (só nome; escrever neles continua bloqueado), a chave do espelho, nome com sufixo (`credentials_helper.py`), here-string é dado, `touch`/`wc` de `.env` e glob real (`~/.ssh/id_*`) que o safety-net não expande.
- **Contra o bash real** (fuzzer do selftest; `secret-read-guard.selftest.sh 1500 <semente>` no nó, sementes 7, 11 e 13): **0 bypass em 4.321 comandos válidos, 2.315 deles em que o shell tocou segredo** (semente 7: 1.435 válidos / 754 tocaram; semente 11: 1.445 / 783; semente 13: 1.441 / 778; bateria padrão N=150: 144 / 71). O N=1.500 achou o que o N=150 não achava (8 bypasses na semente 7, 11 na 11 e, depois do conserto, 1 na 13: `.cr*$X`), e cada um virou linha da tabela e mutante. Isto vale **para a gramática do fuzzer e só para ela**: leitores (`cat head tail less base64 xxd od sed awk grep`) × forma do caminho (absoluto, relativo, `~`, `$HOME`, `${HOME}`, glob, chave `{a,b}` e `{~/x,y}`, aspas partidas, `//`, `${UNSET:-…}`) × como o leitor chega ao arquivo (argumento, `F=…`, `export`, `<`, `$( )`, `xargs`, `find -exec`, `for`, `cd` + nome relativo, variável que guarda só a pasta, `A=$HOME; B=$A/…`, `find | xargs`, `$(find …)`, `tee`) × embrulho (`bash -c`, `eval`, `env`, `command`, `nohup`, `timeout`, `( )`, `&&`, `2>/dev/null`, heredoc) × atribuições antes (`H=1`, `HO=…`, `X=`, `export H=2`) × aninhamento de 7 a 9 níveis. A 1ª versão dizia "0 bypass em 2.196" e a revisão do gate achou 4 formas que aquela gramática não gerava; com a gramática de agora a versão antiga dá **bypass=28 em 144 comandos** (mesma semente, N=150) e o guarda atual dá 0. Fora da gramática o número não diz nada: o que ela não gera está em "Limites".

## Como ligar o secret-read-guard
Copiar o arquivo para `~/.claude/hooks/` (como o remote-clone-guard) e, no `settings.json` da camada, um grupo `PreToolUse`:
```json
{"matcher": "Bash|Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit|NotebookRead", "hooks": [{"type": "command", "command": "python3 -I /home/runner/.claude/hooks/secret-read-guard.py || exit 2"}]}
```
O `|| exit 2` faz travar ou sumir o python também sair 2 (hook que sai 1 ou 127 não bloqueia). Vale sob `--dangerously-skip-permissions`. Custo: ~50 ms por chamada (25 ms são o próprio python). Para os overlays `pool-*` (mini), o caminho é o do `scripts/` da cidade. Desligar: tirar o grupo.

## Limites e falsos positivos
- **Não vejo:** caminho montado em pedaços (`chr()`, concatenação, base64); variável que não é `HOME` nem atribuída na mesma chamada, e variável de laço (`for d in .gnupg; do cat ~/$d/…`); `~usuario` (`cat ~root/.aws/config` passa, o nome `id_rsa`/`.env` ainda vale); script que o comando executa; o que um programa lê sozinho (`ssh`). A mitigação completa é permissão de arquivo por usuário Unix (não existe).
- **Caminho com pedaço desconhecido não passa inteiro:** valem a pasta literal antes dele (`~/.ssh/$k` bloqueia) e o nome do fim (`$X/id_rsa` bloqueia). O que continua passando é raiz desconhecida + pasta de segredo + nome comum (`$X/.gnupg/pubring.kbx`).
- **Fora do catálogo (o guarda não olha, e o runbook antigo dizia "nenhum hook nosso olha caminho de segredo" sem dizer isto):** segredo no AMBIENTE (`env`, `printenv`, `cat /proc/self/environ`, `echo $TOKEN`); `~/.claude.json`, `~/.codex/auth.json`, `~/.gemini/oauth_creds.json`; histórico do shell; ajudantes de credencial que imprimem o segredo (`gh auth token`, `git credential fill`, `security find-generic-password`). `grep -r KEY .` num projeto que tem `.env` passa: a varredura larga só conhece o HOME, seus ancestrais e as pastas-mãe de segredo (`~/.claude`, `~/.config`, `~/.docker`, `~/.kube`, `~/.dolt`, `~/gt-remote`).
- **Fora do matcher:** leitores de arquivo de servidor MCP (`mcp__*`) não passam por este hook.
- **Aninhamento acima de 6 níveis** (`$( )`, `bash -c`, `eval`, heredoc) BLOQUEIA ("não consigo ler"); comando inocente tão fundo também cai aqui.
- **Grep/Glob sem `path`** valem como o cwd da sessão: com o cwd no HOME ou numa pasta de segredo, bloqueiam. Conferir antes de ligar no nó.
- **Falsos positivos conhecidos (lado fechado):** `ssh-copy-id -i ~/.ssh/id_rsa.pub` e `cp ~/.ssh/config x` (verbo que escreve não herda a leitura livre de `~/.ssh`); chave `{a,b}` com mais de 16 alternativas; `.pem` fora de `node_modules`/`site-packages`; `Grep`/`Glob` com raiz no HOME; glob que casa segredo (`.en*`); varredura recursiva (`grep -r`, `cp -r`, `tar`, `find` com pipe, Grep) sobre `~/.claude`, `~/.config`, `~/.docker`, `~/.kube`, `~/.dolt` (a subpasta passa: `~/.claude/projects`); `~/.ssh/$k` com `$k` desconhecido; `$(…)` e `bash -c` aninhados em mais de 6 níveis. Falsos negativos deliberados: `credentials-prod` (só `credentials` e `credentials.bak|.key|.pem…` valem), `.envrc`.
- **Reexecução em comandos reais** (este guarda sobre os pedidos únicos das 1.007 transcrições deste nó, 15 a 28/10: 47.799 pedidos — Bash 33.499, Edit 6.322, Read 4.652, Write 2.698, Grep 614, Glob 14): **22 bloqueios, 0 erro do guarda** (a 1ª versão: 2 em 45.290). 18 são comandos de teste da própria bead (transcrições que citam `ga-nkfwixz`: `cat .env`, `~/.ssh/…`; critério meu, não prova). Os 4 de fora são 2 comandos, cada um visto duas vezes: (1) `grep -il 'mbp' ~/.ssh/*`, o mesmo da 1ª versão (varre as chaves privadas só para achar um apelido de host; o arquivo certo é `~/.ssh/config`, que passa); (2) `grep -rIl "cdp-drive" ~/gt-remote/bin ~/.config ~/.local/bin` — **comportamento novo**: a varredura recursiva de `~/.config` (guarda gcloud, rclone e gh) é bloqueada como ancestral de segredo; com `-l` não imprime conteúdo, mas lê as credenciais, e a saída é apontar para a subpasta (`~/.config/<app>`). Falso positivo de uso real: esse comando (2 em 47.799). Não cobre as sessões do mini (as transcrições dele não estão aqui). Como repetir: um `*.selftest.sh` temporário no worktree, rodado por `mbp-run.sh --repo hq`, que lê `~/.claude/projects/**/*.jsonl` do nó, chama `decide()` em cada `tool_use` coberto e imprime só contagem, regra e nome do alvo (não foi commitado).

## Como repetir
1. Baixar `https://registry.npmjs.org/cc-safety-net/-/cc-safety-net-2.7.0.tgz` num diretório novo e vazio, conferir o sha512 do registro, extrair noutro diretório; nunca rodar de dentro dele.
2. Rodar só por `~/gt-remote/bin/gt-iso-run -- CC_SAFETY_NET_HOME=<dir> node <script> …`, importando `dist/api.js` (`checkCommand({command, cwd})`) ou chamando `node dist/bin/cc-safety-net.js hook --claude-code` com o JSON do PreToolUse no stdin.
3. A verdade: gerar os comandos, rodá-los num `bash -c` com `PATH` de programas falsos, comparar. O gerador da seção 1 é o `g_fuzz` do `remote-clone-guard.selftest.sh` (despejar os comandos em vez de contar); o da seção 2 são as famílias da tabela, uma linha de shell por forma (o script de 280 casos não coube no teto E11); o do segredo está no `secret-read-guard.selftest.sh` (`secret-read-guard.selftest.sh <N> <semente>` muda o tamanho e a semente do fuzzer; medir no nó com `scripts/mbp-run.sh --repo hq --dir <worktree>/.gascity-gastown-hq -- scripts/secret-read-guard.selftest.sh 1500 11`, porque o `mbp-run.sh` não repassa variável de ambiente). Para provar que a bateria pega o defeito, rode-a contra o guarda ANTERIOR (troque o `secret-read-guard.py` do worktree por `git show <sha-antigo>:…`): a tabela reprova e o fuzzer acusa bypass.

## O que fica para outra bead
1. Guard de `rm` por alvo e por flag normalizada (seção 3), com `find -delete` para scratch.
2. As 12 formas de interpretador/pipe no `remote-clone-guard` (seção 2).
3. Ligar o secret-read-guard (decisão do Mayor) e, se ligar, entrar no `remote-bundle-build.py` para o nó copiar o hook junto com o do clone.
4. Cortesia a montante: o bug do `$(case … esac)` no parser do safety-net (25 de 212 execuções reais de `reset --hard` passam).
