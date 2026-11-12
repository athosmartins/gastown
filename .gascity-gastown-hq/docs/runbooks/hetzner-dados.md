# Trava 1 do Hetzner: dado pessoal só no usuário `dados`, e só enquanto o build roda (ga-qg1dw5z.1)

## Contents

• Por quê · **Contrato (o que a trava 3 confere)** · **Instalação (precisa de root, uma vez)** · Prova (como runner) · Como o mini usa (put, run, get) · Varredura e log · Ordem com a trava 2 · Limites honestos

## Por quê
Os agentes (usuário `runner`) e qualquer dado moram no mesmo usuário do nó. Um pacote npm/PyPI envenenado (ondas Shai-Hulud/CanisterSprawl 2026) ou uma injeção de prompt por página raspada leria o cadastro de lote e proprietário. A decisão do Athos (11/11, programa ga-qg1dw5z) é que esse dado só vai ao nó depois das 3 travas. Esta é a 1ª: o dado fica num usuário que o `runner` não lê, só existe enquanto o build roda, e o build roda sem rede.

## Contrato (o que a trava 3 confere)
Tudo isto é o que o instalador deixa no nó; `hetzner-dados-install.sh --check` (como root) confere os 20 itens e imprime `GTD-CHECK: <item> ok|FALHOU|nao-consegui`.

| O quê | Valor |
|---|---|
| Usuário | `dados`: senha travada (`passwd -l`), **shell real** (`/bin/bash`), home `/home/dados` 0700, grupo próprio, sem grupos extras; o `runner` **não** está no grupo `dados` |
| Staging | `/srv/gtdados`: **tmpfs dedicado** (linha `# gt-dados` no `/etc/fstab`: `size=8g,mode=0700,uid/gid dados,noexec,nosuid,nodev,nofail`), `in/` (o dado) e `out/` (o resultado), 0700 `dados:dados` |
| Código que roda como `dados` | `/opt/gt-dados/app/bin/<entrypoint>`: árvore de **root**, ninguém mais escreve, sem link para fora; lista em `/etc/gt-dados/entrypoints` |
| Wrapper de build | `/usr/local/sbin/gt-dados-run` (root:root 755) |
| Canal do mini | `/usr/local/sbin/gt-dados-ingest` (root:root 755), a única coisa que a chave do mini faz no usuário `dados` |
| Chave do canal | `/etc/ssh/authorized_keys.d/dados` (**root**:dados 0640): `restrict,command="/usr/local/sbin/gt-dados-ingest" <chave do mini>`; drop-in `/etc/ssh/sshd_config.d/50-gt-dados.conf` (`Match User dados`, sem senha, túnel, agente, X11, tty, rc) |
| sudoers | `/etc/sudoers.d/gt-dados-run`: **uma linha por entrypoint**, `runner ALL=(root) NOPASSWD: /usr/local/sbin/gt-dados-run <entrypoint>`; sem curinga, nunca `(dados) ALL` |
| Varredura | `/usr/local/sbin/gt-dados-sweep` (root:root 755) + `gt-dados-sweep.timer` (04:17 UTC, `Persistent=true`); log em `/var/log/gt-dados-sweep.log` |
| Swap | **desligada** (com swap ligada o tmpfs iria a disco: o wrapper e o `--check` recusam) |

Linha do log da varredura (a trava 3 lê a última e a idade dela): `<UTC> gt-dados-sweep: LIMPO removed=N killed=K` · `PULADO dados-vivo=N` · `NAO-CONSEGUI <motivo>`. `NAO-CONSEGUI` nunca significa "limpo".

O que o build enxerga (`gt-dados-run`): netns novo **sem saída** (`lo` aceito, o resto rejeitado com contador), uid/gid `dados` sem grupos extras nem capacidades (`setpriv --no-new-privs`), ambiente limpo (`env -i`), `GT_DADOS_STAGE=/srv/gtdados`, prazo de 2 h. Ao fim apaga `in/`, mata o que sobrou no netns e confere que `in/` ficou vazio (`GTD-WIPE: ok`; senão sai 99).

## Instalação (precisa de root, uma vez)
Sem comando de root improvisado: o que se instala vem de um commit, pelo instalador versionado `scripts/hetzner-dados-install.sh`. A chave de root do nó é `~/.ssh/hetzner_teste_urblink` (usuário `root`; **a trava 2 vai trocá-la, ver "Ordem com a trava 2"**).
```bash
CITY=/Users/athos/gt/.gascity-gastown-hq; NODE=root@2.31.41.222; KEY=~/.ssh/hetzner_teste_urblink
# 1. chave própria do canal mini -> dados (nunca a de root nem a do runner); sem frase porque o mini a usa sem humano
[ -e ~/.ssh/hetzner_dados_ingest ] || ssh-keygen -t ed25519 -N '' -C 'mini->dados (gt-dados-ingest)' -f ~/.ssh/hetzner_dados_ingest
# 2. os scripts de UM commit (não da árvore de trabalho) para uma pasta de root no nó
D=$(mktemp -d); git -C "$CITY/.." archive <sha> .gascity-gastown-hq/scripts | tar -x -C "$D"
S=$D/.gascity-gastown-hq/scripts
ssh -i $KEY $NODE 'install -d -m 0700 /root/gt-dados-src' \
  && scp -i $KEY $S/hetzner-dados-{install,run,ingest,sweep,synth}.sh ~/.ssh/hetzner_dados_ingest.pub $NODE:/root/gt-dados-src/
# 3. instalar (idempotente; --stage-size ajusta o tmpfs; --entrypoint acrescenta builds além do `synth` de prova)
ssh -i $KEY $NODE 'bash /root/gt-dados-src/hetzner-dados-install.sh apply --pubkey-file /root/gt-dados-src/hetzner_dados_ingest.pub'
# 4. conferir, ainda como root: tem de dar rc 0 e 20 linhas `ok`
ssh -i $KEY $NODE 'bash /root/gt-dados-src/hetzner-dados-install.sh --check'
```
O instalador só recarrega o sshd **depois** de `sshd -t` e de `sshd -T -C` provarem que o `dados` usa o arquivo de chaves de root e que o `runner` **não** foi afetado; se qualquer prova falha, o drop-in é desfeito e nada é recarregado. O sudoers só entra depois de `visudo -cf`. O fstab ilegível não é reescrito. Um passo que falha imprime `GTD-INSTALL: falhou:<passo>` e sai 98; o que já estava no nó não é apagado (exceto o drop-in reprovado).

Código de build real (a leva 2): `--code-dir <repo no nó> --code-sha <sha>` só entra com o HEAD igual ao sha **e** árvore limpa, e vai para a árvore de root; depois `--entrypoint <nome>` para cada executável em `bin/`. Reaplicar com a lista nova **substitui** o sudoers e a lista (uma linha por entrypoint).

## Prova (como runner)
No nó, como `runner` (sem root): `bash <repo>/scripts/hetzner-dados-prove.sh`, ou do mini `ssh hetzner-teste 'bash -s' < scripts/hetzner-dados-prove.sh`. Imprime `GTD-PROVE: <item> ok|FALHOU|nao-consegui` e `GTD-PROVE: resultado ...` (rc 0 todos ok · 1 algum FALHOU · 2 algum nao-consegui):

| Item | ok quando |
|---|---|
| `home-negado`, `stage-negado` | `ls /home/dados` e `ls /srv/gtdados/in` dão **Permission denied** (diretório que não existe = `nao-consegui`: trava não instalada, nunca ok) |
| `sem-grupo-dados` | `id -nG` não lista `dados` |
| `sudo-como-dados-recusado` | `sudo -n -u dados true` recusa |
| `fora-da-lista-recusado` | `sudo -n gt-dados-run <nome fora da lista>` recusa e não roda nada |
| `build-sintetico` | `sudo -n gt-dados-run synth` sai 0, imprime `synth: ok`, `GTD-WIPE: ok` e `GTD-EGRESS: attempts=<n>`; o dado é **sintético**, gerado na hora (nunca dado real) |

A conferência do staging **vazio** depois do build é de root: a linha `GTD-WIPE: ok` do wrapper (ele lê como root) e o `--check`.

## Como o mini usa (put, run, get)
O mini tem **uma** chave no usuário `dados` (`~/.ssh/hetzner_dados_ingest`), e ela só roda `gt-dados-ingest`. Os verbos vêm em `SSH_ORIGINAL_COMMAND`; o nome casa `^[a-z0-9][a-z0-9_.-]{0,63}$`:
```bash
tar -c -C <pasta> . | ssh -i ~/.ssh/hetzner_dados_ingest dados@2.31.41.222 put <nome>     # dado -> /srv/gtdados/in/<nome>/ (link simbólico no tar: apagado e rc 65)
ssh hetzner-teste 'sudo -n /usr/local/sbin/gt-dados-run <entrypoint>'                         # build (runner dispara; só entrypoint da lista)
ssh -i ~/.ssh/hetzner_dados_ingest dados@2.31.41.222 get <nome> | tar -x -C <destino>        # resultado -> mini (ausente: rc 66, nunca tar vazio)
ssh -i ~/.ssh/hetzner_dados_ingest dados@2.31.41.222 clean [<nome>]                          # apaga in/ e out/
ssh -i ~/.ssh/hetzner_dados_ingest dados@2.31.41.222 status                                  # tmpfs sim/não e itens em in/ e out/
```
Códigos do ingest: 0 ok · 64 verbo/nome recusado · 65 link simbólico · 66 resultado ausente · 73 não consegui criar o destino · 98 o staging não é tmpfs próprio (o dado **não** é gravado) · 99 apaguei mas sobrou. O resultado nunca sai por diretório legível ao `runner`.

## Varredura e log
O trap do wrapper cobre saída normal, `INT`, `TERM`, `HUP`; `kill -9` e reboot o pulam. A varredura diária apaga o staging, o home do `dados` e o que `dados` deixou em `/tmp`, `/var/tmp` e `/dev/shm`, **se não houver build vivo**: nenhum processo de `dados` com menos de 3 h **e** o lock do wrapper (`/run/gt-dados-run.lock`) livre. Processo de `dados` com 3 h ou mais não é build (o prazo do wrapper é 2 h): é morto e a varredura segue. A varredura **segura o lock até o fim**: um build que comece no meio recusa `ocupado` (`GTD-RUN: recusado:ocupado`, rc 98) em vez de ter o staging apagado. Roda uma vez na instalação, **com prazo de 15 min**: se estourar ou sair `NAO-CONSEGUI`, a instalação falha (`GTD-INSTALL: falhou:sweep-primeira`, rc 98).

Alcance em `/tmp`: só o **1º nível** (o que `dados` cria direto lá, com o que houver dentro). O `/tmp` do nó tem ~1,7 milhão de entradas (medido em 12/11: 17,8 mi de inodes no `/`); a primeira versão varria a árvore inteira, ficou 40+ min presa e **nunca escreveu o log**. `/var/tmp` e `/dev/shm` são varridos inteiros. Cada apagamento e cada leitura de verificação tem prazo de 15 min: a verificação que estourou = `NAO-CONSEGUI leitura-falhou`. Entrada que **sumiu** durante a leitura (`No such file or directory`: o `runner` apaga e cria em `/tmp` o tempo todo) não reprova; qualquer outro erro de leitura reprova.

Ler: `tail -3 /var/log/gt-dados-sweep.log` ou `journalctl -u gt-dados-sweep`. Rodar à mão: `systemctl start gt-dados-sweep.service` (leva ~1 min no nó real). Uma varredura **sem linha no log** (serviço `activating` por mais de ~15 min) é defeito, não "limpo".

## Ordem com a trava 2
A trava 2 (ga-qg1dw5z.2) troca a chave de root e a descreve como "não lida por agentes": depois dela nenhum dog aplica root no nó, só o Athos. Por isso:
1. **Aplicar a trava 1 ANTES de a 2 cortar o root.** Se a 2 já cortou, a instalação (e qualquer mudança de entrypoint) é do Athos, com este mesmo instalador.
2. A `ufw` da trava 2 precisa deixar o ssh do mini entrar também como `dados` (mesma origem do `runner`).
3. A trava 2 não pode mexer no `AuthorizedKeysFile` do `Match User dados`: se mudar o sshd globalmente, rode `hetzner-dados-install.sh --check` (`sshd-dados-usa-arquivo-de-root`, `sshd-runner-intacto`).

## Limites honestos
- **Os selftests usam stubs** (`hetzner-dados.selftest.sh`: wrapper, ingest, varredura, synth e prove, 24 mutantes; `hetzner-dados-install.selftest.sh`: instalador, 16 mutantes, numa "raiz" de mentira) e **não veem o tamanho do nó**: a varredura passou nos selftests e travou 40+ min no `/tmp` real (1,7 mi de entradas). A prova de que o kernel isola, de que o sshd aceita a chave, de que o sudo recusa e de que a varredura termina é o `--check`, o `hetzner-dados-prove.sh` e a 1ª varredura da instalação **no nó**, depois da instalação por root (feitos em 12/11, ver o comentário da bead ga-joysgpf).
- **`/tmp` só no 1º nível e `put` concorrente**: arquivo de `dados` dentro de pasta de OUTRO dono em `/tmp` não é visto pela varredura; e um `put` do canal do mini que comece depois da checagem de processos da varredura (o `ingest` não toma o lock) não é protegido: não rode `put` por volta de 04:17 UTC. Um build legítimo não deve gravar em `/tmp` (o wrapper não define `TMPDIR`; temporário do build iria ao disco, não ao tmpfs): lacuna conhecida, a tratar quando o 1º build real da leva 2 existir.
- **"Sem rede" é um netns**, o mesmo padrão do `gt-netns-run`: soquete unix do sistema de arquivos (D-Bus, `docker.sock`) não é coberto. O `dados` não tem home legível pelo `runner`, mas um build envenenado **roda como `dados`** e lê o que está no staging dele: a trava protege o dado do `runner` e do que ele instala, não de um entrypoint malicioso dentro da árvore de root (por isso a árvore é de root, de um commit fixado por sha).
- **Tmpfs usa RAM** (`--stage-size`, padrão 8g; o nó tem 30 GB, sem swap). Dado maior que o tmpfs falha o `put` (ENOSPC), não vai ao disco. A trava 3 deve acusar **swap ligada** enquanto houver dado.
- Reboot apaga o staging (é tmpfs); `shred` em ext4/SSD não garantiria, por isso não há staging em bloco de disco.
- O `dados` tem shell real **de propósito**: com `nologin` o `sshd` não roda o `command=` (ele o executa pelo shell do usuário). "Sem login" aqui é senha travada + chave com `restrict,command=` + `PermitTTY no`.
- O arquivo de chaves do `dados` é de **root** e não gravável por `dados`: senão um build envenenado gravaria a própria chave e ganharia acesso externo permanente.

Referências: `scripts/hetzner-dados-*.sh` (o que roda), `docs/runbooks/hetzner-nightly-tests.md` e `scripts/hetzner-netns-run.sh` (o padrão do netns e da instalação de root).
