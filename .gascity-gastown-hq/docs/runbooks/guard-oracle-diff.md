# guard-oracle-diff · cc-safety-net como oráculo diferencial dos nossos guards (ga-nkfwixz)

## Contents
• Estado e o que o Mayor decide · Como foi medido · 1. O corpus do nosso fuzzer · 2. Formas que o runbook admite não cobrir · 3. rm -rf: a regra deny do nó · 4. Instalar o safety-net por cima? · 5. Segredo: o secret-read-guard · Como ligar o secret-read-guard · Limites e falsos positivos · Como repetir · O que fica para outra bead

Medido em 28/10/2026 no nó Hetzner (dog-remote-1), contra o **cc-safety-net 2.7.0** (MIT; repositório renomeado para `kenryu42/cc-safety-net`).

## Estado e o que o Mayor decide
- **Entregue, dormente:** `scripts/secret-read-guard.py` + `scripts/secret-read-guard.selftest.sh` (139 casos, 19 mutantes, fuzzer contra o bash real). Nenhum `settings.json` o chama.
- **Decisão do Mayor (risco):** ligar o secret-read-guard ou não, e onde. Recomendação: primeiro no nó Hetzner (login do claude, chave do mini e chave do espelho moram no mesmo disco da sessão), depois nos overlays `pool-*`. Trecho e custo em "Como ligar".
- **Não portado (vira bead, motivo em cada seção):** guard de `rm` por alvo (seção 3) e as 12 formas de interpretador/pipe no remote-clone-guard (seção 2).
- **Veredito sobre instalar o safety-net por cima: não.** Ele nega `git reset --hard origin/<branch>` e `git worktree remove --force`, dois passos que a nossa doutrina manda copiar (seção 4).

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
- **Contra o bash real** (fuzzer do selftest; 3 sementes × 1.500 comandos medidas fora dele): **0 bypass em 2.196 comandos em que o shell tocou segredo**. A primeira versão tinha 33 (xargs, `cd` + nome relativo, `\$` em aspas duplas); duas revisões de segurança automáticas do commit acharam mais 8 (código por stdin de `bash`, varredura de ancestral do HOME, teto da chave `{a,b}`, `find -exec`, valor colado na opção, verbo que escreve em `~/.ssh`, crase aninhada, `$'\x2eenv'`); todas viraram linha da tabela e têm mutante.

## Como ligar o secret-read-guard
Copiar o arquivo para `~/.claude/hooks/` (como o remote-clone-guard) e, no `settings.json` da camada, um grupo `PreToolUse`:
```json
{"matcher": "Bash|Read|Grep|Glob|Edit|Write|MultiEdit|NotebookEdit", "hooks": [{"type": "command", "command": "python3 -I /home/runner/.claude/hooks/secret-read-guard.py || exit 2"}]}
```
O `|| exit 2` faz travar ou sumir o python também sair 2 (hook que sai 1 ou 127 não bloqueia). Vale sob `--dangerously-skip-permissions`. Custo: ~50 ms por chamada (25 ms são o próprio python). Para os overlays `pool-*` (mini), o caminho é o do `scripts/` da cidade. Desligar: tirar o grupo.

## Limites e falsos positivos
- **Não vejo:** caminho montado em pedaços (`chr()`, concatenação, base64), variável que não é `HOME` nem atribuída na mesma chamada, script que o comando executa, o que um programa lê sozinho (`ssh`). A mitigação completa é permissão de arquivo por usuário Unix (não existe).
- **Falsos positivos conhecidos (lado fechado):** `ssh-copy-id -i ~/.ssh/id_rsa.pub` e `cp ~/.ssh/config x` (verbo que escreve não herda a leitura livre de `~/.ssh`); chave `{a,b}` com mais de 16 alternativas; `.pem` fora de `node_modules`/`site-packages`; `Grep`/`Glob` com raiz no HOME; glob que casa segredo (`.en*`). Falsos negativos deliberados: `credentials-prod` (só `credentials` e `credentials.bak|.key|.pem…` valem), `.envrc`.
- **Reexecução em comandos reais** (o guard sobre os 45.290 pedidos únicos das 978 transcrições deste nó, 15 a 28/10: Bash 31.664, Edit 6.080, Read 4.364, Write 2.598, Grep 570, Glob 14): **2 bloqueios, 0 erro do guard**, ambos o mesmo comando de uma sessão, `grep -il 'mbp' ~/.ssh/*` (varre as chaves privadas só para achar um apelido de host; o arquivo certo é `~/.ssh/config`, que passa). Não cobre as sessões do mini (as transcrições dele não estão aqui).

## Como repetir
1. Baixar `https://registry.npmjs.org/cc-safety-net/-/cc-safety-net-2.7.0.tgz` num diretório novo e vazio, conferir o sha512 do registro, extrair noutro diretório; nunca rodar de dentro dele.
2. Rodar só por `~/gt-remote/bin/gt-iso-run -- CC_SAFETY_NET_HOME=<dir> node <script> …`, importando `dist/api.js` (`checkCommand({command, cwd})`) ou chamando `node dist/bin/cc-safety-net.js hook --claude-code` com o JSON do PreToolUse no stdin.
3. A verdade: gerar os comandos, rodá-los num `bash -c` com `PATH` de programas falsos, comparar. O gerador da seção 1 é o `g_fuzz` do `remote-clone-guard.selftest.sh` (despejar os comandos em vez de contar); o da seção 2 são as famílias da tabela, uma linha de shell por forma (o script de 280 casos não coube no teto E11); o do segredo está no `secret-read-guard.selftest.sh` (`secret-read-guard.selftest.sh 3000` aumenta o fuzzer).

## O que fica para outra bead
1. Guard de `rm` por alvo e por flag normalizada (seção 3), com `find -delete` para scratch.
2. As 12 formas de interpretador/pipe no `remote-clone-guard` (seção 2).
3. Ligar o secret-read-guard (decisão do Mayor) e, se ligar, entrar no `remote-bundle-build.py` para o nó copiar o hook junto com o do clone.
4. Cortesia a montante: o bug do `$(case … esac)` no parser do safety-net (25 de 212 execuções reais de `reset --hard` passam).
