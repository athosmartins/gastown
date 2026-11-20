#!/bin/bash
# hetzner-dados-install.sh — instalador de ROOT (uma vez, idempotente) da trava 1: usuário `dados`, staging em tmpfs, wrapper, canal do mini e varredura (ga-qg1dw5z.1).
#
# ## Contents
#   Uso · Código por tar · O que instala · Códigos de saída
#
# USO (como root no nó, com este repo em $WA; sem comando de root improvisado: o que o runbook pede é este script):
#   hetzner-dados-install.sh apply --pubkey-file <mini.pub> [--entrypoint <nome>]... [--code-tar <tar> --code-manifest <manifesto> --code-sha <sha>] [--runner runner] [--stage-size 8g]
#   hetzner-dados-install.sh apply ... --code-dir <dir> --code-sha <sha>      LEGADO: exige NO NÓ um clone com TODOS os blobs do commit (o `git archive` os busca: dado de lead incluso, wa-4p38ls); o caminho do nó real é --code-tar
#   hetzner-dados-install.sh verify-code --code-tar <tar> --code-manifest <manifesto> --code-sha <sha> [--entrypoint <nome>]...      só CONFERE (qualquer usuário, nada no nó): o mini a roda no que exporta, antes de mandar
#   hetzner-dados-install.sh --check      confere o contrato inteiro como root e imprime `GTD-CHECK: <item> ok|FALHOU|nao-consegui` (rc 0 só com tudo ok)
# CÓDIGO POR TAR (ga-kwk6fcl): o MINI exporta (hetzner-dados-code-export.sh: `git archive` + `git ls-tree` do COMMIT, só a lista branca; a conferência de que o sha está em main é dele) e o nó só VERIFICA, sem repo. O manifesto é
#   `gt-dados-code-manifest 1`, `commit <sha>` e uma linha `<modo> <blob-id> <caminho>` por arquivo. O instalador confere: o commit contra --code-sha, o conjunto contra a lista branca, o bin/<ep> executável NO COMMIT, o tar (só arquivo e pasta,
#   só nome do manifesto: ANTES de extrair, nada de fora é gravado no nó) e cada arquivo extraído (`git hash-object --no-filters` = blob-id do manifesto, bit de execução = modo), além da mesma cauda do --code-dir (lista exata, dado, modo).
# O QUE INSTALA: usuário `dados` (senha travada, shell real, home 0700, grupo próprio, runner FORA dele) · /srv/gtdados tmpfs (fstab: size=, 0700 dados, noexec,nosuid,nodev) · /usr/local/sbin/gt-dados-{run,ingest,sweep}
#   · /opt/gt-dados/app/bin/<entrypoint> (árvore de ROOT, ninguém mais escreve; a de `--code-dir` só entra com o HEAD igual a `--code-sha` e árvore limpa, e é SÓ o fechamento dos entrypoints pedidos — os caminhos de hetzner-dados-code-allow.txt, lista branca
#     que fica AO LADO deste instalador (no nó, /root/gt-dados-src: o scp do runbook, passo 2, a entrega junto) — no conteúdo do COMMIT (`git archive -- <caminhos>`), nunca a árvore de trabalho nem o commit inteiro: o nó não pode receber dado de lead/conversa, então o apply RECUSA (98), antes de mexer no nó, lista ausente, entrypoint sem linha ou sem o próprio bin/<ep>, e depois do export o arquivo que case padrão de dado) + /etc/gt-dados/entrypoints
#   · /etc/ssh/authorized_keys.d/dados (de ROOT: `restrict,command="gt-dados-ingest"`) + drop-in sshd `Match User dados` · /etc/sudoers.d/gt-dados-run (UMA linha por entrypoint, sem curinga) · gt-dados-sweep.timer diário.
#   sshd só recarrega DEPOIS de `sshd -t` e de `sshd -T -C` provar que `dados` usa o arquivo de ROOT e o runner NÃO; qualquer reprovação desfaz o drop-in. sudoers só entra depois de `visudo -cf`.
# CÓDIGOS: 0 · 64 uso/não é root · 98 um passo falhou (`GTD-INSTALL: falhou:<passo>`; o que já estava no nó não é apagado, exceto o drop-in do sshd reprovado) · `verify-code`: 0 imprime `GTD-CODE: ok commit=<sha> arquivos=<n>`, recusa é 98 como no apply
set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
DU=dados; SBIN=/usr/local/sbin; ETC=/etc/gt-dados; OPT=/opt/gt-dados; STAGE=/srv/gtdados; DHOME=/home/dados; SSHD_D=/etc/ssh/sshd_config.d; AKDIR=/etc/ssh/authorized_keys.d
SUDOERS=/etc/sudoers.d/gt-dados-run; FSTAB=/etc/fstab; UNITS=/etc/systemd/system; LOGF=/var/log/gt-dados-sweep.log
SRC=$(cd "$(dirname "$0")" && pwd); RUNNER=runner
ALLOW=$SRC/hetzner-dados-code-allow.txt
die() { echo "GTD-INSTALL: falhou:$1" >&2; exit 98; }
chk() { local n=$1 rc; shift; "$@" > /dev/null 2>&1; rc=$?; case $rc in 0) echo "GTD-CHECK: $n ok" ;; 127) echo "GTD-CHECK: $n nao-consegui"; [ "$CH" = 1 ] || CH=2 ;; *) echo "GTD-CHECK: $n FALHOU"; CH=1 ;; esac; }
owned() { [ "$(stat -c '%U:%G %a' "$1" 2> /dev/null)" = "$2" ]; }
sshd_for() { sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" 2> /dev/null; }
# cada teste é uma função: rc 0 ok · 127 ferramenta ausente (nao-consegui) · outro rc = FALHOU
t_locked() { [ "$(passwd -S "$DU" | cut -d' ' -f2)" = L ]; }
t_shell() { case "$(getent passwd "$DU" | cut -d: -f7)" in ''|*nologin|*/false) return 1 ;; esac; }
t_grupos() { [ "$(id -nG "$DU")" = "$DU" ]; }
# vazio/falhou: `id` do runner que falha (nome errado, NSS) é "não consegui" (127), nunca "fora do grupo"
t_runner() { local g; g=$(id -nG "$RUNNER" 2> /dev/null) || return 127; ! printf '%s\n' $g | grep -qx "$DU"; }
t_keys() { owned "$AKDIR/$DU" "root:$DU 640" && grep -Eq "^restrict,command=\"$SBIN/gt-dados-ingest\" ssh-|^restrict,command=\"$SBIN/gt-dados-ingest\" ecdsa-" "$AKDIR/$DU"; }
t_sshd_d() { sshd_for "$DU" | grep -qx "authorizedkeysfile $AKDIR/$DU"; }
t_sshd_r() { local o; o=$(sshd_for "$RUNNER") || return 127; ! printf '%s\n' "$o" | grep -q '^authorizedkeysfile .*authorized_keys.d'; }
t_tree() { local x; x=$(find "$OPT" \( -not -user root -o \( ! -type l \( -perm -020 -o -perm -002 \) \) \) -print -quit 2> /dev/null) || return 127; [ -z "$x" ]; }
t_sudo_strict() { [ -r "$SUDOERS" ] || return 127; ! grep -E '^[^#]' "$SUDOERS" | grep -Ev "^$RUNNER ALL=\(root\) NOPASSWD: $SBIN/gt-dados-run [a-z0-9_.-]+\$" | grep -q .; }
t_sudo_list() { { [ -r "$SUDOERS" ] && [ -r "$ETC/entrypoints" ]; } || return 127; [ "$(grep -E '^[^#]' "$SUDOERS" | sed 's/.* //' | sort)" = "$(sort "$ETC/entrypoints")" ]; }
t_stage() { local o; mountpoint -q "$STAGE" && o=$(findmnt -no FSTYPE,OPTIONS "$STAGE") && [ "${o%% *}" = tmpfs ] && case ",${o#* }," in *,noexec,*) case ",${o#* }," in *,nosuid,*) case ",${o#* }," in *,nodev,*) return 0 ;; esac ;; esac ;; esac; return 1; }
t_swap() { local s; s=$(swapon --noheadings --show 2> /dev/null) || return 127; [ -z "$s" ]; }
t_timer() { systemctl is-enabled gt-dados-sweep.timer && systemctl is-active gt-dados-sweep.timer; }
check() {
  CH=0; local l
  chk usuario-dados-existe getent passwd "$DU"; chk senha-travada t_locked; chk shell-real t_shell; chk home-0700 owned "$DHOME" "$DU:$DU 700"
  chk grupo-so-dados t_grupos; chk runner-fora-do-grupo t_runner; chk chaves-de-root t_keys; chk sshd-dados-usa-arquivo-de-root t_sshd_d; chk sshd-runner-intacto t_sshd_r
  for l in run ingest sweep; do chk "gt-dados-$l-de-root" owned "$SBIN/gt-dados-$l" "root:root 755"; done
  chk arvore-de-root t_tree; chk sudoers-valido visudo -cf "$SUDOERS"; chk sudoers-sem-curinga t_sudo_strict; chk sudoers-igual-a-lista t_sudo_list
  chk stage-tmpfs-proprio t_stage; chk stage-0700-dados owned "$STAGE" "$DU:$DU 700"; chk sem-swap t_swap; chk timer-ativo t_timer
  return "$CH"
}
[ "${1:-}" = --check ] && { check; exit $?; }
# apply instala (só como root); verify-code só LÊ (tar, manifesto e lista branca, numa pasta temporária) e roda em qualquer usuário: o mini a roda no que exporta e o apply do nó refaz a mesma conferência
MODE=${1:-}
{ [ "$MODE" = apply ] && [ "$(id -u)" = 0 ]; } || [ "$MODE" = verify-code ] || { echo "uso (como root): $0 apply --pubkey-file <f.pub> [...] | verify-code --code-tar <t> --code-manifest <m> --code-sha <sha> [...] | --check" >&2; exit 64; }
shift; PUB=""; ENTS="synth"; CODE=""; SHA=""; SIZE=8g; CTAR=""; CMAN=""
while [ $# -gt 0 ]; do
  # opção sem valor (última palavra): `shift 2` falha sem deslocar nada e o laço giraria para sempre a 100% de CPU, sem saída (revisão do gate, 12/11) → recusa
  case $1 in --pubkey-file | --entrypoint | --code-dir | --code-sha | --runner | --stage-size | --code-tar | --code-manifest) [ $# -ge 2 ] || { echo "opção sem valor: $1" >&2; exit 64; } ;; esac
  # verify-code não instala nada: opção de instalação é RECUSADA, não ignorada em silêncio
  case $MODE:$1 in verify-code:--pubkey-file | verify-code:--code-dir | verify-code:--runner | verify-code:--stage-size) echo "opção não vale em verify-code: $1" >&2; exit 64 ;; esac
  case $1 in
    --pubkey-file) PUB=${2:-}; shift 2 ;; --entrypoint) ENTS="$ENTS ${2:-}"; shift 2 ;; --code-dir) CODE=${2:-}; shift 2 ;; --code-sha) SHA=${2:-}; shift 2 ;;
    --code-tar) CTAR=${2:-}; shift 2 ;; --code-manifest) CMAN=${2:-}; shift 2 ;;
    --runner) RUNNER=${2:-}; shift 2 ;; --stage-size) SIZE=${2:-}; shift 2 ;; *) echo "argumento desconhecido: $1" >&2; exit 64 ;; esac
done
if [ "$MODE" = apply ]; then
  # vazio → recusa (nunca "sem chave = qualquer chave"); chave com opções (command=, no-restrict) também: as opções são só as nossas
  [ -n "$PUB" ] && [ "$(grep -c . "$PUB" 2> /dev/null)" = 1 ] && grep -Eq '^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]+( .*)?$' "$PUB" && ssh-keygen -l -f "$PUB" > /dev/null 2>&1 || die pubkey
  # a linha validada (a única não-vazia) é a que é copiada: `$(cat)` levaria uma linha em branco antes da chave e a chave ficaria numa 2ª linha, SEM o restrict
  KEYLINE=$(grep -m1 . "$PUB") || die pubkey
fi
for e in $ENTS; do [[ $e =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] || die "entrypoint-invalido:$e"; done
[[ $SIZE =~ ^[1-9][0-9]*[mg]$ ]] || die stage-size
# duas fontes de código, nunca juntas: o clone do nó (`--code-dir`, LEGADO: o `git archive` pede a ele TODO blob do commit, dado de lead incluso) ou o tar + manifesto que o mini exporta (`--code-tar`); o tar não anda sem manifesto nem sha
[ -z "$CODE" ] || [ -z "$CTAR$CMAN" ] || { echo "--code-dir e --code-tar/--code-manifest não andam juntos" >&2; exit 64; }
[ -z "$CTAR$CMAN" ] || { [ -n "$CTAR" ] && [ -n "$CMAN" ] && [ -n "$SHA" ]; } || { echo "--code-tar exige --code-manifest e --code-sha (e o contrário)" >&2; exit 64; }
[ "$MODE" != verify-code ] || [ -n "$CTAR" ] || { echo "verify-code exige --code-tar, --code-manifest e --code-sha" >&2; exit 64; }
[ -z "$CODE" ] || { [ -n "$SHA" ] && [ "$(git -C "$CODE" rev-parse HEAD 2> /dev/null)" = "$SHA" ] && [ -z "$(git -C "$CODE" status --porcelain 2> /dev/null || echo ?)" ]; } || die code-dir-nao-e-o-sha-limpo
[ -z "$CODE" ] || echo "GTD-INSTALL: AVISO: --code-dir exige NO NÓ um clone com TODOS os blobs do commit (dado de lead incluso: wa-4p38ls); o caminho do nó real é --code-tar/--code-manifest (hetzner-dados-code-export.sh no mini)" >&2
# wa-4p38ls: o COMMIT inteiro não vai ao nó (levava hawkey_outbound_messages_48h.csv, contacts_auth/, docs/investigations/ para um nó sem dado de lead): só os caminhos da lista branca dos entrypoints pedidos.
# A lista (hetzner-dados-code-allow.txt) é lida AO LADO deste instalador — no nó, /root/gt-dados-src, entregue pelo scp do runbook (passo 2) — e nunca do commit exportado: um manifesto dentro do commit seria o próprio exportado se autorizando.
# Ela é lida e validada AQUI, antes de qualquer mudança no nó (usuário, árvore, sshd): lista ausente/ilegível, linha inválida, entrypoint sem linha ou sem o próprio bin/<ep> → recusa 98 sem tocar em nada. Três estados em cada leitura (E12).
if [ -n "$CODE$CTAR" ]; then
  # vazio/falhou: lista ausente ou ilegível → recusa 98 (nunca "sem lista = exporta tudo"); a dica diz onde ela tem de estar (o 1º envio esqueceu de entregá-la: gate de 19/11)
  [ -f "$ALLOW" ] && [ -r "$ALLOW" ] || { echo "GTD-INSTALL: lista branca ausente: $ALLOW (tem de estar AO LADO do instalador; runbook hetzner-dados.md, passo 2: o scp leva hetzner-dados-code-allow.txt junto, para /root/gt-dados-src)" >&2; die code-allow-ilegivel; }
  WL=""; FX=""; HAVE=""; BINS=""; allow_re='^[A-Za-z0-9_][A-Za-z0-9_./-]*$'
  while read -r k p x || [ -n "${k:-}" ]; do
    case ${k:-} in '' | '#'*) continue ;; esac
    [[ -n ${p:-} && -z ${x:-} && $p =~ $allow_re && $p != */ && $p != *..* && $p != *//* ]] || die "code-allow-linha-invalida:$k"
    if [ "$k" = @fixture ]; then FX="$FX$p"$'\n'; else HAVE="$HAVE $k"; [ "$p" != "bin/$k" ] || BINS="$BINS $k"; for e in $ENTS; do [ "$k" != "$e" ] || WL="$WL$p"$'\n'; done; fi
  done < "$ALLOW"
  for e in $ENTS; do [ "$e" = synth ] || case " $HAVE " in *" $e "*) ;; *) die "code-allow-sem-linha:$e" ;; esac; done
  # o entrypoint instalado é o bin/<ep> da árvore exportada: sem essa linha o export não o leva e o instalador só o notaria DEPOIS da troca (entrypoint-ausente, com a árvore antiga já removida)
  for e in $ENTS; do [ "$e" = synth ] || case " $BINS " in *" $e "*) ;; *) die "code-allow-sem-bin:$e" ;; esac; done
  WLS=$(printf '%s' "$WL" | LC_ALL=C sort -u); [ -n "$WLS" ] || die code-allow-vazia
  PSPEC=(); while IFS= read -r p; do PSPEC+=("$p"); done <<< "$WLS"
fi
# vazio/falhou: o `tr` que falha deixa `p` vazio, e vazio não casa nenhum padrão ("não é dado"): falhou → o arquivo conta como DADO (return 0, recusa), nunca como "não é dado"
data_path() { local p; p=$(printf %s "$1" | tr "[:upper:]" "[:lower:]") || return 0; case $p in *.csv | *.db | *.sqlite | *.sqlite3 | *.jsonl | *.parquet | *.duckdb | *.xlsx | *.xls | *.vcf | contacts_auth/* | */contacts_auth/* | docs/investigations/* | */docs/investigations/*) return 0 ;; esac; return 1; }
# wa-4p38ls: a lista branca já foi lida e validada lá em cima (WLS, FX); a pasta extraída $1 (nova, de root), de QUALQUER fonte (git archive do clone, tar do mini), tem de ser EXATAMENTE a lista (pasta na lista, arquivo ausente do commit ou export-ignore reprovam),
# sem arquivo que case padrão de dado (salvo `@fixture` explícito) nem modo inseguro. Qualquer reprovação apaga $1 e recusa 98 sem trocar nada; `die` sai do script, então ninguém chama isto dentro de `$( )`
code_tree_check() {
  local NEW=$1 GOT f bad
  GOT=$(cd "$NEW" && find . ! -type d -print) || { rm -rf -- "$NEW"; die code-find; }
  GOT=$(printf '%s\n' "$GOT" | sed 's#^\./##' | LC_ALL=C sort)
  [ "$GOT" = "$WLS" ] || { rm -rf -- "$NEW"; die code-fora-da-lista; }
  while IFS= read -r f; do
    ! data_path "$f" || printf '%s' "$FX" | grep -qxF -- "$f" || { rm -rf -- "$NEW"; die "code-dado-no-export:$f"; }
  done <<< "$GOT"
  # setuid, setgid ou escrita de grupo/outros em qualquer arquivo ou pasta que não seja elo. Só primárias POSIX (`-perm -modo` + `-o`): `-perm /modo` e `-quit` são extensões do GNU find, e o verify-code roda no mini (find BSD), que o selftest (Linux) não vê.
  # vazio/falhou: um find que falha → recusa (nunca "sem modo inseguro")
  bad=$(find "$NEW" ! -type l \( -perm -4000 -o -perm -2000 -o -perm -0020 -o -perm -0002 \) -print) || { rm -rf -- "$NEW"; die code-find; }
  [ -z "$bad" ] || { rm -rf -- "$NEW"; die "code-modo-inseguro:${bad%%$'\n'*}"; }
}
# ── código por TAR + MANIFESTO (ga-kwk6fcl): o mini exporta, o nó só verifica, sem repo ───────────────────────────────────────────────────────────────────────────────
# Tudo o que dá para recusar SEM extrair nada, e antes de mexer no nó. Deixa nos globais: MLINES (uma linha `<modo> <blob-id> <caminho>` por arquivo, já validada), MN (quantos), MPATHS, MDIRS (pastas-pai) e MEXEC (os 100755)
code_tar_prepare() {
  local MAN ml mn=0 mp mm mr d e h tn TT TN MANS odd man_re='^(100644|100755) [0-9a-f]{40} [A-Za-z0-9_][A-Za-z0-9_./-]*$' commit_re='^commit [0-9a-f]{40}$'
  # o id de commit é o de 40 hex minúsculos (o que `git ls-tree` e `git rev-parse` imprimem): nome de ref, abreviação ou maiúsculas não identificam um commit
  [[ $SHA =~ ^[0-9a-f]{40}$ ]] || die code-sha-invalido
  # vazio/falhou: tar ou manifesto ausente ou que não é arquivo comum (pasta, FIFO, dispositivo: a leitura travaria ou não teria fim) → recusa 98 antes de mexer no nó (nunca "sem manifesto = nada a conferir")
  [ -f "$CTAR" ] || die code-tar-ilegivel
  [ -f "$CMAN" ] || die code-manifesto-ilegivel
  # vazio → manifesto sem um byte: recusa (nunca "lista vazia a conferir"); falhou/ilegível (cat) → recusa
  MAN=$(cat "$CMAN") || die code-manifesto-ilegivel
  [ -n "$MAN" ] || die code-manifesto-vazio
  MLINES=""; MPATHS=""; MDIRS=""; MEXEC=""
  while IFS= read -r ml || [ -n "$ml" ]; do
    mn=$((mn + 1))
    case $mn in
      1) [ "$ml" = "gt-dados-code-manifest 1" ] || die "code-manifesto-invalido:1"; continue ;;
      2) [[ $ml =~ $commit_re ]] || die "code-manifesto-invalido:2"
         [ "$ml" = "commit $SHA" ] || die code-manifesto-commit-diferente; continue ;;
    esac
    # a linha INTEIRA casa o formato (um espaço entre os campos, sem tabulação nem CR) e o caminho segue as regras da lista branca
    [[ $ml =~ $man_re ]] || die "code-manifesto-invalido:$mn"
    mm=${ml%% *}; mr=${ml#* }; mp=${mr#* }
    [[ $mp != */ && $mp != *..* && $mp != *//* ]] || die "code-manifesto-invalido:$mn"
    MLINES="$MLINES$ml"$'\n'; MPATHS="$MPATHS$mp"$'\n'; [ "$mm" != 100755 ] || MEXEC="$MEXEC $mp"
    d=$mp; while [[ $d == */* ]]; do d=${d%/*}; MDIRS="$MDIRS$d"$'\n'; done
  done <<< "$MAN"
  MN=$((mn - 2)); [ "$MN" -ge 1 ] || die code-manifesto-vazio
  # vazio/falhou: um sort que falha deixa MANS vazio, que nunca é igual à lista (há ≥ 1 arquivo nela) → recusa. O conjunto do manifesto (com a linha duplicada, se houver) tem de ser IGUAL ao que a lista branca autoriza para os entrypoints pedidos
  MANS=$(printf '%s' "$MPATHS" | LC_ALL=C sort)
  # a dica (o 1º caminho que está só de um lado) é cosmética: o `apply` REESCREVE a lista de entrypoints, então o tar tem de ser do conjunto INTEIRO (os já instalados + o novo), e a causa comum é um export com menos entrypoints; sem dica a recusa é a mesma
  h=$(printf '%s\n%s\n' "$MANS" "$WLS" | LC_ALL=C sort | uniq -u | head -n 1)
  [ "$MANS" = "$WLS" ] || die "code-manifesto-fora-da-lista${h:+:$h}"
  # o bin/<ep> de cada entrypoint de código é executável NO COMMIT (modo 100755 do manifesto): o `gt-dados-run` o executa
  for e in $ENTS; do [ "$e" = synth ] || case " $MEXEC " in *" bin/$e "*) ;; *) die "code-bin-sem-exec:$e" ;; esac; done
  # o 1º caractere do `tar -tv` é o tipo do membro: `-` arquivo · `d` pasta · `l` elo simbólico · `h` elo duro · outros (dispositivo, fifo). vazio → tar sem membro nenhum: recusa (nunca "nada a extrair = ok"); falhou/ilegível (tar que não lê, arquivo cortado) → recusa
  TT=$(set -o pipefail; tar -tvf "$CTAR" | cut -c1 | LC_ALL=C sort -u) || die code-tar-ilegivel
  [ -n "$TT" ] || die code-tar-vazio
  odd=${TT//[d$'\n'-]/}; [ -z "$odd" ] || die "code-tar-tipo:${odd:0:1}"
  # falhou/ilegível → recusa. Cada nome é arquivo do manifesto ou pasta-pai de um: o que o manifesto não lista (o csv de lead, `../x`, nome absoluto) nem chega a ser gravado no nó
  TN=$(tar -tf "$CTAR") || die code-tar-ilegivel
  while IFS= read -r tn || [ -n "$tn" ]; do
    tn=${tn%/}
    [[ $tn =~ $allow_re && $tn != *..* && $tn != *//* ]] || die "code-tar-nome:$tn"
    case $'\n'$MPATHS$'\n'$MDIRS in *$'\n'"$tn"$'\n'*) ;; *) die "code-tar-fora-do-manifesto:$tn" ;; esac
  done <<< "$TN"
}
# extrai o tar em $1 (pasta nova e vazia, de root) e confere o que saiu CONTRA O MANIFESTO: a cauda comum (lista exata, dado, modo) e então cada arquivo não é elo, tem o blob-id do COMMIT e o bit de execução do modo dele.
# O `tar -t` de code_tar_prepare já aprovou tipos e nomes; o que ficou em $1 ainda é conferido (um tar que extrai diferente do que lista não passa)
code_from_tar() {
  local NEW=$1 ml mm mr mb mp got
  ( umask 022; tar -x --no-same-owner --no-same-permissions -C "$NEW" -f "$CTAR" ) || { rm -rf -- "$NEW"; die code-tar-extracao; }
  code_tree_check "$NEW"
  while IFS= read -r ml; do
    [ -n "$ml" ] || continue
    mm=${ml%% *}; mr=${ml#* }; mb=${mr%% *}; mp=${mr#* }
    [ ! -L "$NEW/$mp" ] || { rm -rf -- "$NEW"; die "code-elo-no-export:$mp"; }
    # vazio/falhou: `git hash-object` que falha ou não imprime blob-id deixa `got` vazio, que nunca é igual ao do manifesto → recusa; só o id IGUAL libera. `--no-filters`: o git do operador (core.autocrlf, filter) não pode converter o que o commit guardou
    got=$(cd "$NEW" && git hash-object --no-filters -- "$mp")
    [ "$got" = "$mb" ] || { rm -rf -- "$NEW"; die "code-hash:$mp"; }
    if [ "$mm" = 100755 ]; then [ -x "$NEW/$mp" ] || { rm -rf -- "$NEW"; die "code-modo-difere:$mp"; }
    else [ ! -x "$NEW/$mp" ] || { rm -rf -- "$NEW"; die "code-modo-difere:$mp"; }; fi
  done <<< "$MLINES"
}
[ -z "$CTAR" ] || code_tar_prepare
if [ "$MODE" = verify-code ]; then
  # só confere: extrai numa pasta temporária que some em QUALQUER saída (o `die` também sai por aqui). vazio/falhou: mktemp que falha → recusa, nunca "sem pasta = conferiu"
  VT=$(mktemp -d "${TMPDIR:-/tmp}/gt-dados-verify.XXXXXX") || die code-tmp
  trap 'rm -rf -- "$VT"' EXIT
  # vazio/falhou: um mkdir que falha deixa o `tar -x -C` sem pasta, que sai ≠ 0 → code-tar-extracao (recusa)
  mkdir -m 0755 "$VT/app.new"
  code_from_tar "$VT/app.new"
  echo "GTD-CODE: ok commit=$SHA arquivos=$MN"
  exit 0
fi
# 1. usuário: sem skel (-M), senha travada, shell REAL (nologin quebraria o forced command: o sshd roda o command= pelo shell), home 0700, grupo próprio
getent passwd "$DU" > /dev/null || useradd -M -d "$DHOME" -s /bin/bash -U -c "gt dados (trava 1)" "$DU" || die useradd
usermod -L "$DU" || die passwd-lock
install -d -o "$DU" -g "$DU" -m 0700 "$DHOME" || die home
[ "$(id -nG "$DU")" = "$DU" ] || die grupos-extras-do-dados
# vazio/falhou: `id` do runner que falha (nome errado, NSS) → recusa; só a lista lida e sem `dados` libera
RG=$(id -nG "$RUNNER" 2> /dev/null) || die runner-ilegivel
printf '%s\n' $RG | grep -qx "$DU" && die runner-no-grupo-dados
# 2. árvore de root: nada que o runner edite roda como dados
install -d -o root -g root -m 0755 "$OPT" "$OPT/app" "$OPT/app/bin" "$ETC" || die dirs
# o código de --code-dir vem do COMMIT (`git archive $SHA`), nunca da árvore de trabalho: o rsync copiava o que estivesse no disco, e `status --porcelain` não vê arquivo ignorado (.gitignore) nem edição escondida por `update-index --assume-unchanged`/`skip-worktree`:
# o HEAD==sha e a "árvore limpa" conferidos acima não descreviam o que ia para uma árvore que roda como `dados`. Extrai numa pasta nova (dono root, sem escrita de grupo/outros), confere os modos e só então troca a árvore de uma vez (falhou → a antiga fica)
# falhou (git archive, tar ou find) → recusa, nunca instala o que sobrou: pipefail faz um git que morre no meio da saída reprovar mesmo com um tar que aceita o que chegou
# ga-kwk6fcl: com `--code-tar` a árvore sai do tar do mini, conferido arquivo a arquivo (code_from_tar); com `--code-dir` (legado) sai do `git archive` do clone do nó. Nos dois a cauda é a mesma (code_tree_check) e a troca abaixo também.
if [ -n "$CODE$CTAR" ]; then
  NEW="$OPT/app.new"; OLD="$OPT/app.old"
  rm -rf -- "$NEW" "$OLD" && mkdir -m 0755 "$NEW" || die code-new
  if [ -n "$CTAR" ]; then
    code_from_tar "$NEW"
  else
    ( set -o pipefail; umask 022; git -C "$CODE" archive --format=tar "$SHA" -- "${PSPEC[@]}" | tar -x --no-same-owner --no-same-permissions -C "$NEW" ) || { rm -rf -- "$NEW"; die code-archive; }
    code_tree_check "$NEW"
  fi
  mv "$OPT/app" "$OLD" && mv "$NEW" "$OPT/app" || { [ -d "$OPT/app" ] || mv "$OLD" "$OPT/app"; rm -rf -- "$NEW"; die code-troca; }
  rm -rf -- "$OLD" || die code-old
  [ -z "$CTAR" ] || echo "GTD-INSTALL: código do commit $SHA ($MN arquivos, tar + manifesto) conferido arquivo a arquivo"
fi
install -d -o root -g root -m 0755 "$OPT/app/bin" && install -o root -g root -m 0755 "$SRC/hetzner-dados-synth.sh" "$OPT/app/bin/synth" || die synth
for e in $ENTS; do [ -f "$OPT/app/bin/$e" ] && [ ! -L "$OPT/app/bin/$e" ] || die "entrypoint-ausente:$e"; done
# link que aponta para fora da árvore de root deixaria o runner trocar o que roda como dados; find que falha → recusa, nunca "sem links"
LINKS=$(find "$OPT" -type l) || die find-links
while IFS= read -r l; do [ -z "$l" ] || case $(readlink -f "$l") in "$OPT"/*) ;; *) die "link-fora-da-arvore:$l" ;; esac; done <<< "$LINKS"
printf '%s\n' $ENTS | sort -u > "$ETC/entrypoints.new" && chmod 0644 "$ETC/entrypoints.new" && mv "$ETC/entrypoints.new" "$ETC/entrypoints" || die entrypoints
for p in run ingest sweep; do install -o root -g root -m 0755 "$SRC/hetzner-dados-$p.sh" "$SBIN/gt-dados-$p" || die "install-$p"; done
# 3. canal do mini: chave de ROOT (o dados não regrava a própria chave) + drop-in; só recarrega o sshd com a prova do `sshd -T`; reprovou → desfaz o drop-in
install -d -o root -g root -m 0755 "$AKDIR" || die akdir
printf 'restrict,command="%s/gt-dados-ingest" %s\n' "$SBIN" "$KEYLINE" > "$AKDIR/$DU.new" && chown "root:$DU" "$AKDIR/$DU.new" && chmod 0640 "$AKDIR/$DU.new" && mv "$AKDIR/$DU.new" "$AKDIR/$DU" || die authorized-keys
DROP="$SSHD_D/50-gt-dados.conf"; [ -f "$DROP" ] && cp -p "$DROP" "$DROP.prev"
printf 'Match User %s\n    AuthorizedKeysFile %s/%s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    AllowTcpForwarding no\n    AllowAgentForwarding no\n    X11Forwarding no\n    PermitTTY no\n    PermitUserRC no\n' "$DU" "$AKDIR" "$DU" > "$DROP" || die dropin
undo() { if [ -f "$DROP.prev" ]; then mv "$DROP.prev" "$DROP"; else rm -f "$DROP"; fi; die "$1 (drop-in do sshd desfeito)"; }
sshd -t || undo sshd-t
sshd_for "$DU" | grep -qx "authorizedkeysfile $AKDIR/$DU" || undo sshd-dados-nao-usa-o-arquivo-de-root
# vazio/falhou: sshd -T do runner que falha não prova "runner intacto" → desfaz o drop-in, nunca recarrega sem a prova
RO=$(sshd_for "$RUNNER") || undo sshd-runner-ilegivel
printf '%s\n' "$RO" | grep -q '^authorizedkeysfile .*authorized_keys.d' && undo sshd-runner-afetado
rm -f "$DROP.prev"; { systemctl reload ssh || systemctl reload sshd; } || die sshd-reload
# 4. sudoers: UMA linha por entrypoint, sem curinga; nada entra sem `visudo -cf`
{ echo "# gt-dados (ga-qg1dw5z.1): o runner dispara SÓ estes entrypoints; sem curinga, sem (dados) ALL"; for e in $(sort -u "$ETC/entrypoints"); do echo "$RUNNER ALL=(root) NOPASSWD: $SBIN/gt-dados-run $e"; done; } > "$SUDOERS.new" || die sudoers
visudo -cf "$SUDOERS.new" > /dev/null || { rm -f "$SUDOERS.new"; die visudo; }
chmod 0440 "$SUDOERS.new" && chown root:root "$SUDOERS.new" && mv "$SUDOERS.new" "$SUDOERS" || die sudoers-mv
# 5. staging em tmpfs dedicado (RAM: nada em bloco de disco, o reboot apaga) + varredura diária
# nofail: o nó não tem console; um tmpfs que falhasse no boot não pode levar o sistema ao modo de emergência (sem montagem, o wrapper e o ingest recusam: não são tmpfs)
# fstab ilegível → recusa (reescrevê-lo só com a nossa linha o destruiria); sem linha nossa ainda (grep rc 1) é normal
grep -v ' # gt-dados$' "$FSTAB" > "$FSTAB.new"; [ $? -le 1 ] || die fstab-leitura
echo "tmpfs $STAGE tmpfs size=$SIZE,mode=0700,uid=$(id -u "$DU"),gid=$(id -g "$DU"),noexec,nosuid,nodev,nofail 0 0 # gt-dados" >> "$FSTAB.new"; chmod 0644 "$FSTAB.new" && mv "$FSTAB.new" "$FSTAB" || die fstab
mkdir -p "$STAGE" && systemctl daemon-reload && { if mountpoint -q "$STAGE"; then mount -o remount "$STAGE"; else mount "$STAGE"; fi; } || die mount
printf '[Unit]\nDescription=gt-dados: varredura do dado que o trap nao apagou\n[Service]\nType=oneshot\nNice=10\nExecStart=%s/gt-dados-sweep\n' "$SBIN" > "$UNITS/gt-dados-sweep.service" || die unit
printf '[Unit]\nDescription=gt-dados: varredura diaria\n[Timer]\nOnCalendar=*-*-* 04:17:00 UTC\nPersistent=true\n[Install]\nWantedBy=timers.target\n' > "$UNITS/gt-dados-sweep.timer" || die unit
systemctl daemon-reload && systemctl enable --now gt-dados-sweep.timer || die timer
# a 1ª varredura roda AQUI e tem prazo: no nó real (/tmp com ~1,7 mi de entradas) a versão sem prazo ficou 40+ min presa sem escrever o log. Passou do prazo ou saiu ≠ 0 (NAO-CONSEGUI) → a instalação falha ALTO
timeout 900 systemctl start gt-dados-sweep.service || die sweep-primeira
echo "GTD-INSTALL: aplicado; conferindo (--check) e a varredura rodou uma vez (veja $LOGF)"
check
