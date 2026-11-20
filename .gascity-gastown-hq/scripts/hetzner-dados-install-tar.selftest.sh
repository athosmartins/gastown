#!/usr/bin/env bash
# hetzner-dados-install-tar.selftest.sh — hermético: o código chega ao nó EXPORTADO pelo mini (tar + manifesto) e o instalador de root só VERIFICA: `apply --code-tar/--code-manifest/--code-sha` e `verify-code` (ga-kwk6fcl).
#
# ## Contents
#   Por quê · Casos · Mutantes · O que este teste NÃO prova
#
# POR QUÊ: o `apply --code-dir` roda `git archive` NO NÓ, e o `git archive` pede ao repo TODO blob do commit (medido no nó, git 2.43: um pathspec de 2 arquivos num clone parcial buscou os 8 blobs do commit, dado de lead
#   incluso). Um clone com todos os blobs no nó é exatamente o que a wa-4p38ls proíbe. Aqui o mini exporta (`git archive` + `git ls-tree` do COMMIT, só a lista branca) e o nó confere cada arquivo contra o blob-id do manifesto
#   com `git hash-object`, sem repo: o `git` stub do teste (GIT_HASH_ONLY=1) sai 97 em qualquer subcomando que não seja `hash-object`, então um `apply` verde prova que o nó nunca precisou de um repo.
# CASOS: instalação feliz (a árvore do nó é a lista, do conteúdo do commit; nenhum dado de lead) · uso errado (64: fontes juntas, tar sem manifesto/sha, opção sem valor) · manifesto (cada defeito → 98 com o código certo,
#   ANTES de mexer no nó) · tar (tipo, nome, membro fora do manifesto: recusados ANTES de gravar um byte) · extração (hash diferente, bit de execução, CRLF escondido pelo git do operador, elo simbólico que passa no hash,
#   arquivo faltando, modo inseguro, tar que sai 1, dado na lista, @fixture) · `verify-code` (sem root, sem tocar no nó, pasta temporária sempre apagada).
# O QUE NÃO PROVA: que o `tar` do Ubuntu 24.04 e o do macOS listam os tipos assim em TODO caso (o `-tv` começa pelo tipo nos dois: é o que o instalador lê); isso é a instalação no nó + o `verify-code` rodado no mini.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzdados-tar-selftest.XXXXXX"); R="$T/r"; LOG="$T/log"; OUT="$T/out"; ERR="$T/err"; ME=$(id -un)
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/stubs" "$T/own" "$T/home" "$T/vtmp"
# o git do OPERADOR não pode entrar no teste (autocrlf, safecrlf...): HOME e config de sistema vazios; um caso põe o autocrlf de propósito
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
ALLOW_BASE=("build-x bin/build-x" "build-x lib/x.py"); setallow() { printf '%s\n' "$@" > "$T/allow.txt"; }; setallow "${ALLOW_BASE[@]}"
mk() { printf '%s\n' "$2" > "$T/stubs/$1"; chmod +x "$T/stubs/$1"; }
mk id '#!/usr/bin/env bash
case "$*" in "-u") echo "${ID_U:-0}" ;; "-u dados"|"-g dados") echo 1234 ;; "-nG dados") echo "${ID_G_DADOS:-dados}" ;; "-nG runner") [ -z "${ID_RUNNER_FAIL:-}" ] || exit 1; echo "${ID_G_RUNNER:-runner}" ;; *) exec /usr/bin/id "$@" ;; esac'
mk getent '[ -f "$T/user" ] && echo "dados:x:1234:1234::/home/dados:${SHELL_DADOS:-/bin/bash}"; [ -f "$T/user" ]'
mk useradd 'echo "useradd $*" >> "$LOG"; touch "$T/user"'
mk usermod 'echo "usermod $*" >> "$LOG"'
mk passwd 'echo "dados ${PW_STATE:-L} 2026-11-11 0 99999 7 -1"'
mk ssh-keygen 'echo "ssh-keygen $*" >> "$LOG"; ! grep -q BADKEY "$3"'
mk sshd 'echo "sshd $*" >> "$LOG"
case "$1" in -t) [ -z "${SSHD_T_FAIL:-}" ] ;; -T) case "$3" in user=dados,*) [ -n "${SSHD_DADOS_WRONG:-}" ] && echo "authorizedkeysfile .ssh/authorized_keys" || { [ -f "$R/etc/ssh/sshd_config.d/50-gt-dados.conf" ] && sed -n "s#^ *AuthorizedKeysFile \(.*\)#authorizedkeysfile \1#p" "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"; } ;; *) [ -z "${SSHD_RUNNER_FAIL:-}" ] || exit 1; echo "authorizedkeysfile ${SSHD_RUNNER_LEAK:-.ssh/authorized_keys}" ;; esac ;; esac'
mk systemctl 'echo "systemctl $*" >> "$LOG"; [ "${SWEEP_FAIL:-}" = 1 ] && [ "$1 $2" = "start gt-dados-sweep.service" ] && exit 1; exit 0'
mk visudo 'echo "visudo $*" >> "$LOG"; [ -z "${VISUDO_MISSING:-}" ] || exit 127; [ -z "${VISUDO_FAIL:-}" ]'
mk timeout 'shift; exec "$@"'
# o mktemp registra o que criou: o caso da pasta temporária do verify-code só vale se uma foi CRIADA e depois sumiu (TMPDIR vazio sem pasta nenhuma criada seria verde sem provar nada)
mk mktemp '[ -z "${MKTEMP_FAIL:-}" ] || exit 1; d=$(/usr/bin/mktemp "$@") || exit 1; echo "$d" >> "$T/mktemp.log"; echo "$d"'
# CAT_FAIL: o `cat` do manifesto que falha (leitura que falha não pode virar "manifesto vazio")
mk cat '[ -z "${CAT_FAIL:-}" ] || exit 1; exec /bin/cat "$@"'
mk mountpoint '[ -f "$T/mounted" ]'
mk mount 'echo "mount $*" >> "$LOG"; touch "$T/mounted"; echo "dados dados 700" > "$T/own/$(echo "$R/srv/gtdados" | tr / _)"'
mk findmnt 'echo "${FS:-tmpfs} rw,nosuid,nodev,noexec,relatime"'
mk swapon '[ -z "${SWAPON_FAIL:-}" ] || exit 1; [ -z "${SWAP:-}" ] || echo "/dev/sda2 partition 1G"'
# GIT_HASH_ONLY=1: o nó do tar NÃO tem repo. Só `git hash-object` (sem repo) passa para o git de verdade; qualquer outro subcomando (archive, rev-parse, status, ls-files...) sai 97 e o `apply` reprova
mk git 'if [ "${GIT_HASH_ONLY:-}" = 1 ]; then
  case " $* " in *" hash-object "*) exec /usr/bin/git "$@" ;; *) echo "git: so hash-object no no (GIT_HASH_ONLY): $*" >&2; exit 97 ;; esac
fi
case "$3" in rev-parse) echo "${GIT_HEAD:-abc123}" ;; status) echo "${GIT_DIRTY:-}" ;; esac'
# TAR_LOOSE: depois de extrair, deixa o extraído gravável pelo grupo · TAR_LINK: lib/x.py vira elo simbólico para uma cópia IDÊNTICA fora da árvore (o hash passa seguindo o elo: só o teste de arquivo comum reprova) ·
# TAR_X_FAIL: a extração entrega tudo e sai 1 · TAR_NAMES_FAIL: a listagem de NOMES (-tf) falha e a de tipos (-tvf) não · nas listagens nada disso roda: só o `-x` tem -C
mk tar '[ -z "${TAR_NAMES_FAIL:-}" ] || case " $* " in *" -tf "*) exit 1 ;; esac
a=("$@"); /usr/bin/tar "$@"; rc=$?; d=""; for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -C ] && d=${a[i+1]}; done
if [ -n "$d" ]; then
  [ -z "${TAR_LOOSE:-}" ] || /bin/chmod -R g+w "$d"/*
  [ -z "${TAR_LINK:-}" ] || { cp "$d/lib/x.py" "$T/linktarget" && rm -f "$d/lib/x.py" && ln -s "$T/linktarget" "$d/lib/x.py"; }
  [ -z "${TAR_X_FAIL:-}" ] || exit 1
fi
exit $rc'
# rede de segurança do TESTE: o instalador roda num mundo de mentira ($T) e nunca pode criar pasta fora dele; um mutante sem a guarda do `mktemp` (VT vazio) tentaria `/app.new` na raiz do disco, e como root conseguiria
mk mkdir 'for a in "$@"; do case "$a" in /*) case "$a" in "$T"/*) ;; *) echo "mkdir (stub do teste): recusado fora de $T: $a" >&2; exit 1 ;; esac ;; esac; done; exec /bin/mkdir "$@"'
mk install 'a=(); u=""; g=""; m=""; d=0; while [ $# -gt 0 ]; do case "$1" in -o) u=$2; shift 2 ;; -g) g=$2; shift 2 ;; -m) m=$2; shift 2 ;; -d) d=1; shift ;; *) a+=("$1"); shift ;; esac; done
/usr/bin/install $([ $d = 1 ] && echo -d) ${m:+-m $m} "${a[@]}" || exit 1; [ $d = 1 ] && t=("${a[@]}") || t=("${a[${#a[@]}-1]}")
for p in "${t[@]}"; do echo "${u:-root} ${g:-root} ${m#0}" | sed "s/ $/ 755/" > "$T/own/$(echo "$p" | tr / _)"; done'
mk chown 'echo "${1%%:*} ${1##*:} $(cat "$T/own/$(echo "$2" | tr / _)" 2>/dev/null | cut -d" " -f3)" > "$T/own/$(echo "$2" | tr / _)"'
mk chmod 'if [ -f "$2" ] && [ ! -d "$2" ] || [ -d "$2" ]; then /bin/chmod "$@"; fi; f="$T/own/$(echo "$2" | tr / _)"; u=root g=root; [ -f "$f" ] && read -r u g _ < "$f"; echo "$u $g ${1#0}" > "$f"'
mk mv '/bin/mv "$@"; f="$T/own/$(echo "$1" | tr / _)"; [ -f "$f" ] && /bin/mv "$f" "$T/own/$(echo "$2" | tr / _)"; true'
mk stat '[ "$1" = -c ] || exit 2; f="$T/own/$(echo "$3" | tr / _)"; [ -e "$3" ] || exit 1; read -r u g m < "$f" 2>/dev/null || { u=root g=root m=644; }; case "$2" in "%U:%G %a") echo "$u:$g $m" ;; "%U %a") echo "$u $m" ;; esac'
export LOG T R
# a cópia roda como a do selftest do instalador: SRC aponta para os scripts do repo (synth/run/ingest/sweep) e a lista branca é $T/allow.txt
mkcopy() { local s1="s#^SRC=.*; RUNNER=runner\$#SRC=$HERE; RUNNER=runner#" s2="s#^ALLOW=.*\$#ALLOW=$T/allow.txt#"
  sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#^DU=dados; SBIN=/usr/local/sbin; ETC=/etc/gt-dados; OPT=/opt/gt-dados; STAGE=/srv/gtdados; DHOME=/home/dados; SSHD_D=/etc/ssh/sshd_config.d; AKDIR=/etc/ssh/authorized_keys.d\$#DU=dados; SBIN=$R/usr/local/sbin; ETC=$R/etc/gt-dados; OPT=$R/opt/gt-dados; STAGE=$R/srv/gtdados; DHOME=$R/home/dados; SSHD_D=$R/etc/ssh/sshd_config.d; AKDIR=$R/etc/ssh/authorized_keys.d#" \
  -e "s#^SUDOERS=/etc/sudoers.d/gt-dados-run; FSTAB=/etc/fstab; UNITS=/etc/systemd/system; LOGF=/var/log/gt-dados-sweep.log\$#SUDOERS=$R/etc/sudoers.d/gt-dados-run; FSTAB=$R/etc/fstab; UNITS=$R/etc/systemd/system; LOGF=$R/var/log/gt-dados-sweep.log#" -e "$s1" -e "$s2" -e 's#-user root#-user '"$ME"'#g' ${2:+-e "$2"} "$1" > "$3"; chmod +x "$3"; }
mkcopy "$HERE/hetzner-dados-install.sh" "" "$T/inst.sh"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }; has() { grep -q -E -- "$2" "$1"; }; hasnt() { ! grep -q -E -- "$2" "$1"; }
ck "a cópia testada só troca caminhos, PATH e -user" test "$(diff "$HERE/hetzner-dados-install.sh" "$T/inst.sh" | grep '^<' | grep -v -c -e 'PATH=' -e '^< DU=dados' -e '^< SUDOERS=' -e '^< SRC=' -e '^< ALLOW=' -e '-user root')" = 0
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey mini@gt" > "$T/mini.pub"
world() { chmod -R u+rwx "$T/r" 2>/dev/null; find "$T/r" "$T/own" -mindepth 1 -delete 2>/dev/null; rm -f "$T/user" "$T/mounted"
  mkdir -p "$R/etc/ssh/sshd_config.d" "$R/etc/sudoers.d" "$R/etc/systemd/system" "$R/var/log" "$R/opt/gt-dados/app/bin" "$R/srv" "$R/usr/local/sbin"; printf 'UUID=1 / ext4 defaults 0 1\n' > "$R/etc/fstab"; : > "$LOG"; rm -f "$HOME/.gitconfig"; }
inst() { local s=$1; shift; "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
ap() { inst "$1" apply --pubkey-file "$T/mini.pub" "${@:2}"; }
# como inst, mas com prazo de 3 s: um instalador que GIRA (laço sem saída) vira RC=124, nunca trava a bateria
inst_t() { local s=$1 p i=0; shift; "$s" "$@" > "$OUT" 2> "$ERR" & p=$!; while kill -0 "$p" 2> /dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$p" 2> /dev/null; then kill -9 "$p" 2> /dev/null; wait "$p" 2> /dev/null; RC=124; else wait "$p"; RC=$?; fi; }
okc() { grep -c '^GTD-CHECK: .* ok$' "$OUT"; }
# o repo de teste (git de verdade: é o HARNESS que exporta, como o mini faz; o nó nunca o vê). A: o commit bom (dado de lead por toda parte + código que nenhuma lista autoriza). Variantes de A, cada uma com UM defeito:
# B conteúdo de lib/x.py · C bin/build-x sem bit de execução · D lib/x.py com bit de execução · E lib/x.py com CRLF · F lib/x.py é elo simbólico
mkrepo() { rm -rf "$T/repo"; mkdir -p "$T/repo/bin" "$T/repo/lib" "$T/repo/contacts_auth" "$T/repo/docs/investigations"
  ( cd "$T/repo" && g=/usr/bin/git && $g init -q . && $g config user.email t@t && $g config user.name t && $g config commit.gpgsign false && $g config core.autocrlf false \
    && printf '#!/bin/sh\n' > bin/build-x && chmod 755 bin/build-x && printf 'good\n' > lib/x.py && echo other > lib/other.py \
    && for f in hawkey_outbound_messages_48h.csv lib/tabela.csv contacts_auth/helper.py docs/investigations/nota.py; do echo LEAD-DATA > "$f"; done \
    && $g add -A && $g commit -q -m A && $g tag A \
    && $g checkout -q -f --detach A && printf 'changed\n' > lib/x.py && $g commit -q -am B && $g tag B \
    && $g checkout -q -f --detach A && $g update-index --chmod=-x bin/build-x && $g commit -q -m C && $g tag C \
    && $g checkout -q -f --detach A && $g update-index --chmod=+x lib/x.py && $g commit -q -m D && $g tag D \
    && $g checkout -q -f --detach A && printf 'good\r\n' > lib/x.py && $g commit -q -am E && $g tag E \
    && $g checkout -q -f --detach A && rm lib/x.py && ln -s /etc/passwd lib/x.py && $g add lib/x.py && $g commit -q -m F && $g tag F ) > /dev/null 2>&1
  for v in A B C D E F; do eval "s$v=\$(/usr/bin/git -C '$T/repo' rev-parse $v 2> /dev/null)"; done; }
# a EXPORTAÇÃO do mini: tar do COMMIT + manifesto (= ls-tree do commit: `<modo> <blob-id> <caminho>`) só dos caminhos dados → $T/<tag>.tar e $T/<tag>.man
mkexp() { local tag=$1 sha=$2; shift 2
  /usr/bin/git -C "$T/repo" archive --format=tar "$sha" -- "$@" > "$T/$tag.tar" 2> /dev/null
  { echo "gt-dados-code-manifest 1"; echo "commit $sha"; /usr/bin/git -C "$T/repo" ls-tree -r "$sha" -- "$@" | awk -F'\t' '{ split($1, m, " "); print m[1], m[3], $2 }' | LC_ALL=C sort -k 3,3; } > "$T/$tag.man"; }
# o apply do tar com o tar/manifesto/sha dados (padrão: a exportação boa de A); GIT_HASH_ONLY=1 sempre: o nó não tem repo
tap() { local s=$1 tar=$2 man=$3 sha=$4; shift 4; GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$tar" --code-manifest "$man" --code-sha "$sha" "$@"; }
# recusa de verdade: rc 98, o código CERTO no stderr (o rc sozinho não prova qual guarda reprovou), árvore antiga INTACTA e sem app.new; PRE=1: recusado ANTES de mexer no nó (nenhum useradd/mount/systemctl)
# (enxerga $app do caso que a chama: escopo dinâmico do bash)
refused() { local rot=$1 msg=$2 pre=${3:-0}
  ck "$rot → 98 $msg, árvore antiga INTACTA, sem app.new" bash -c "[ $RC = 98 ] && grep -q 'falhou:$msg' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"
  [ "$pre" != 1 ] || ck "$rot: recusado ANTES de mexer no nó (nenhum useradd/usermod/mount/systemctl)" hasnt "$LOG" '^(useradd|usermod|mount|systemctl)'; }
fresh() { world; echo old > "$app/stale"; }
# entrada que BLOQUEIA a leitura (FIFO sem escritor): o `[ -f ]` recusa SEM abrir; sem ele o `tar`/`cat` trava no open (o inst_t mata o instalador em 3 s e o `exec 9<>` solta o leitor que ficou preso, para não deixar processo para trás)
# which = tar | man; enxerga $s e $app do caso que a chama (escopo dinâmico do bash)
fifo_refused() { local rot=$1 msg=$2 which=$3 fifo="$T/in.fifo"
  rm -f "$fifo"; mkfifo "$fifo" || { ck "$rot: mkfifo" false; return; }
  fresh
  if [ "$which" = tar ]; then GIT_HASH_ONLY=1 inst_t "$s" apply --pubkey-file "$T/mini.pub" --entrypoint build-x --code-tar "$fifo" --code-manifest "$T/A.man" --code-sha "$sA"
  else GIT_HASH_ONLY=1 inst_t "$s" apply --pubkey-file "$T/mini.pub" --entrypoint build-x --code-tar "$T/A.tar" --code-manifest "$fifo" --code-sha "$sA"; fi
  ( exec 9<> "$fifo" ) 2> /dev/null
  refused "$rot" "$msg" 1; rm -f "$fifo"; }
# monta um manifesto de A com as linhas de arquivo dadas (cabeçalho e commit de A) em $T/m.man
man_with() { { echo "gt-dados-code-manifest 1"; echo "commit $sA"; printf '%s\n' "$@"; } > "$T/m.man"; }

case_happy() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py
  ck "preparo: o manifesto de A tem as 2 linhas da lista, com o bit de execução do bin e o commit de A" bash -c "[ \"\$(wc -l < '$T/A.man' | tr -d ' ')\" = 4 ] && grep -q '^commit $sA\$' '$T/A.man' && grep -q '^100755 [0-9a-f]\{40\} bin/build-x\$' '$T/A.man' && grep -q '^100644 [0-9a-f]\{40\} lib/x.py\$' '$T/A.man'"
  fresh; tap "$s" "$T/A.tar" "$T/A.man" "$sA" --runner runner --stage-size 6g
  [ "$RC" = 0 ] || { echo "--- tar feliz: rc=$RC"; cat "$ERR"; grep '^GTD-CHECK:' "$OUT" | grep -v ' ok$'; echo "--- fim"; }
  ck "tar: instala (rc 0) SEM repo no nó — o git do nó só fez hash-object (GIT_HASH_ONLY)" rcis 0
  ck "tar: os 20 itens do --check ok" test "$(okc)" = 20
  ck "tar: a árvore do nó é EXATAMENTE a lista (bin/build-x, lib/x.py + o synth do instalador)" bash -c "[ \"\$(cd '$app' && find . ! -type d | sed 's#^\./##' | sort | tr '\n' ' ')\" = 'bin/build-x bin/synth lib/x.py ' ]"
  ck "tar: o conteúdo é o do COMMIT e o entrypoint é executável" bash -c "[ \"\$(cat '$app/lib/x.py')\" = good ] && [ -x '$app/bin/build-x' ] && [ ! -x '$app/lib/x.py' ]"
  ck "tar: nenhum byte de dado de lead no nó (hawkey_outbound_messages_48h.csv, contacts_auth/, docs/investigations/ nem lib/other.py)" bash -c "[ ! -e '$app/hawkey_outbound_messages_48h.csv' ] && [ ! -e '$app/contacts_auth' ] && [ ! -e '$app/docs' ] && [ ! -e '$app/lib/other.py' ] && [ -z \"\$(grep -rl LEAD-DATA '$app' 2> /dev/null)\" ]"
  ck "tar: o arquivo velho da árvore anterior sumiu, sem .git e sem app.new/app.old" bash -c "[ ! -e '$app/stale' ] && [ ! -e '$app/.git' ] && [ ! -e '$R/opt/gt-dados/app.new' ] && [ ! -e '$R/opt/gt-dados/app.old' ]"
  ck "tar: nada gravável por grupo/outros nem setuid/setgid" bash -c "[ -z \"\$(find '$app' ! -type l -perm /6022)\" ]"
  ck "tar: a saída diz o commit instalado" has "$OUT" "código do commit $sA"
  fresh; echo old > "$app/stale"; tap "$s" "$T/A.tar" "$T/A.man" "$sA"; tap "$s" "$T/A.tar" "$T/A.man" "$sA"
  ck "tar: 2ª instalação (idempotente) rc 0" rcis 0; }
# uso errado → 64 E a mensagem diz o motivo (o instalador antigo também sai 64 para opção que não conhece: só a mensagem prova que a regra nova é a que reprovou)
usage_is() { ck "$1 → 64 e a mensagem diz o motivo" bash -c "[ $RC = 64 ] && grep -q -E -- '$2' '$ERR'"; }
case_usage() { local s=$1
  world; mkrepo; mkexp A "$sA" bin/build-x lib/x.py
  ap "$s" --code-dir "$T" --code-sha "$sA" --code-tar "$T/A.tar" --code-manifest "$T/A.man"; usage_is "--code-dir junto com --code-tar (uma fonte só)" 'não andam juntos'
  ap "$s" --code-dir "$T" --code-sha "$sA" --code-tar "$T/A.tar"; usage_is "--code-dir junto com --code-tar, sem o manifesto" 'não andam juntos'
  ap "$s" --code-tar "$T/A.tar" --code-sha "$sA"; usage_is "--code-tar sem --code-manifest" '--code-tar exige --code-manifest e --code-sha'
  ap "$s" --code-manifest "$T/A.man" --code-sha "$sA"; usage_is "--code-manifest sem --code-tar" '--code-tar exige --code-manifest e --code-sha'
  ap "$s" --code-tar "$T/A.tar" --code-manifest "$T/A.man"; usage_is "--code-tar sem --code-sha" '--code-tar exige --code-manifest e --code-sha'
  ck "uso errado: nada foi criado/instalado" hasnt "$LOG" '^(useradd|usermod|mount|systemctl)'
  for o in --code-tar --code-manifest; do inst_t "$s" apply "$o"; ck "opção sem valor ($o, última palavra) → 64, não gira para sempre" bash -c "[ $RC = 64 ] && grep -q 'opção sem valor: $o' '$ERR'"; done
  inst_t "$s" apply --pubkey-file "$T/mini.pub" --code-tar; ck "opção sem valor depois de uma opção boa (--code-tar) → 64" bash -c "[ $RC = 64 ] && grep -q 'opção sem valor: --code-tar' '$ERR'"; }
# manifesto: cada defeito → 98 com o código certo, ANTES de mexer no nó (o tar é o BOM de A; só o manifesto muda)
case_manifest() { local s=$1 app="$R/opt/gt-dados/app" idb idx z up
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py; idb=$(awk '$3 == "bin/build-x" { print $2 }' "$T/A.man"); idx=$(awk '$3 == "lib/x.py" { print $2 }' "$T/A.man"); z=$(printf '%040d' 0)
  mtry() { fresh; tap "$s" "$T/A.tar" "$T/m.man" "${1:-$sA}"; }
  man_with "100755 $idb bin/build-x" "100644 $idx lib/x.py"; mtry; ck "preparo: o manifesto montado à mão é aceito (rc 0)" rcis 0
  sed -e '1s/.*/gt-dados-code-manifest 2/' "$T/A.man" > "$T/m.man"; mtry; refused "cabeçalho de outra versão" 'code-manifesto-invalido:1' 1
  sed -e '2s/.*/ref main/' "$T/A.man" > "$T/m.man"; mtry; refused "2ª linha que não é commit" 'code-manifesto-invalido:2' 1
  sed -e "2s/.*/commit $z/" "$T/A.man" > "$T/m.man"; mtry; refused "commit do manifesto diferente do --code-sha" 'code-manifesto-commit-diferente' 1
  up=$(printf '%s' "$sA" | tr 'a-f' 'A-F'); mtry "$up"; refused "--code-sha em maiúsculas (o id é minúsculo)" 'code-sha-invalido' 1
  cp "$T/A.man" "$T/m.man"; mtry abc123; refused "--code-sha curto" 'code-sha-invalido' 1
  man_with "120000 $idb bin/build-x" "100644 $idx lib/x.py"; mtry; refused "modo 120000 (elo simbólico) na linha 3" 'code-manifesto-invalido:3' 1
  man_with "100755 $(printf '%s' "$idb" | tr 'a-f' 'A-F') bin/build-x" "100644 $idx lib/x.py"; mtry; refused "blob-id em maiúsculas" 'code-manifesto-invalido:3' 1
  man_with "100755 ${idb%?} bin/build-x" "100644 $idx lib/x.py"; mtry; refused "blob-id de 39 caracteres" 'code-manifesto-invalido:3' 1
  man_with "100755 $idb bin/build-x" "100644 $idx lib/../x.py"; mtry; refused "caminho com .. na linha 4" 'code-manifesto-invalido:4' 1
  man_with "100755 $idb bin/build-x" "100644 $idx /lib/x.py"; mtry; refused "caminho absoluto na linha 4" 'code-manifesto-invalido:4' 1
  man_with "100755 $idb bin/build-x" "100644 $idx lib/"; mtry; refused "caminho de pasta (barra no fim) na linha 4" 'code-manifesto-invalido:4' 1
  man_with "100755 $idb bin/build-x" "100644 $idx lib/x.py extra"; mtry; refused "campo a mais na linha 4" 'code-manifesto-invalido:4' 1
  { echo "gt-dados-code-manifest 1"; echo "commit $sA"; printf '100755\t%s\tbin/build-x\n' "$idb"; echo "100644 $idx lib/x.py"; } > "$T/m.man"; mtry; refused "tabulação no lugar de espaço na linha 3" 'code-manifesto-invalido:3' 1
  man_with "100755 $idb bin/build-x" "" "100644 $idx lib/x.py"; mtry; refused "linha em branco no meio" 'code-manifesto-invalido:4' 1
  awk '{ printf "%s\r\n", $0 }' "$T/A.man" > "$T/m.man"; mtry; refused "manifesto com CRLF" 'code-manifesto-invalido:1' 1
  man_with "100755 $idb bin/build-x" "100644 $idx lib/x.py" "100644 $idx lib/other.py"; mtry; refused "arquivo a mais no manifesto (lib/other.py não está na lista): a recusa nomeia o caminho" 'code-manifesto-fora-da-lista:lib/other.py' 1
  man_with "100755 $idb bin/build-x"; mtry; refused "arquivo da lista ausente do manifesto (export de MENOS entrypoints que o apply): a recusa nomeia o que falta" 'code-manifesto-fora-da-lista:lib/x.py' 1
  man_with "100755 $idb bin/build-x" "100644 $idx lib/x.py" "100644 $idx lib/x.py"; mtry; refused "linha duplicada" 'code-manifesto-fora-da-lista' 1
  man_with "100644 $idb bin/build-x" "100644 $idx lib/x.py"; mtry; refused "bin/build-x sem o bit de execução NO COMMIT" 'code-bin-sem-exec:build-x' 1
  : > "$T/m.man"; mtry; refused "manifesto vazio" 'code-manifesto-vazio' 1
  { echo "gt-dados-code-manifest 1"; echo "commit $sA"; } > "$T/m.man"; mtry; refused "manifesto só com cabeçalho e commit (nenhum arquivo)" 'code-manifesto-vazio' 1
  rm -f "$T/m.man"; mtry; refused "manifesto ausente" 'code-manifesto-ilegivel' 1
  rm -rf "$T/m.man"; mkdir "$T/m.man"; mtry; refused "manifesto que é uma pasta" 'code-manifesto-ilegivel' 1; rmdir "$T/m.man"
  # vazio/falhou: o `cat` do manifesto que falha (manifesto bom, leitura ruim) → ilegível, NUNCA "manifesto vazio"
  cp "$T/A.man" "$T/m.man"; fresh; CAT_FAIL=1 GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$T/A.tar" --code-manifest "$T/m.man" --code-sha "$sA"; refused "cat do manifesto que falha" 'code-manifesto-ilegivel' 1
  fifo_refused "manifesto que é um FIFO sem escritor (a leitura travaria)" 'code-manifesto-ilegivel' man; }
# o tar: tipo, nome e membro fora do manifesto são recusados ANTES de extrair (nada é gravado no nó); o manifesto é o BOM de A
case_tarfile() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py
  ttry() { fresh; tap "$s" "$T/t.tar" "$T/A.man" "$sA"; }
  rm -f "$T/t.tar"; ttry; refused "tar ausente" 'code-tar-ilegivel' 1
  rm -rf "$T/t.tar"; mkdir "$T/t.tar"; ttry; refused "tar que é uma pasta" 'code-tar-ilegivel' 1; rmdir "$T/t.tar"
  fifo_refused "tar que é um FIFO sem escritor (a leitura travaria)" 'code-tar-ilegivel' tar
  echo "isto nao e um tar" > "$T/t.tar"; ttry; refused "arquivo que não é tar" 'code-tar-ilegivel' 1
  head -c 10240 /dev/zero > "$T/t.tar"; ttry; refused "tar válido SEM membro nenhum (nunca 'nada a extrair = ok')" 'code-tar-vazio' 1
  mkexp F "$sF" bin/build-x lib/x.py; cp "$T/F.tar" "$T/t.tar"; ttry; refused "membro que é elo simbólico" 'code-tar-tipo:l' 1
  rm -rf "$T/hl"; mkdir -p "$T/hl/bin" "$T/hl/lib"; printf '#!/bin/sh\n' > "$T/hl/bin/build-x"; ln "$T/hl/bin/build-x" "$T/hl/lib/x.py"; ( cd "$T/hl" && tar -cf "$T/t.tar" bin/build-x lib/x.py ); ttry; refused "membro que é elo DURO" 'code-tar-tipo:h' 1
  ( cd "$T/hl" && tar -cPf "$T/t.tar" "$T/hl/lib/x.py" ) 2> /dev/null; ttry; refused "nome absoluto" 'code-tar-nome:' 1
  ( cd "$T/hl/lib" && tar -cPf "$T/t.tar" ../bin/build-x ) 2> /dev/null; ttry; refused "nome com .." 'code-tar-nome:..' 1
  ( cd "$T/hl" && tar -cf "$T/t.tar" ./bin/build-x ) 2> /dev/null; ttry; refused "nome com ./ na frente (só o layout do git archive vale)" 'code-tar-nome:' 1
  mkexp X "$sA" bin/build-x lib/x.py hawkey_outbound_messages_48h.csv; cp "$T/X.tar" "$T/t.tar"; ttry
  refused "membro FORA do manifesto (o csv de lead): recusado antes de extrair" 'code-tar-fora-do-manifesto:hawkey_outbound_messages_48h.csv' 1
  ck "o csv de lead que o tar trazia NÃO foi gravado no nó (nem a pasta app.new existe)" bash -c "[ ! -e '$R/opt/gt-dados/app.new' ] && [ -z \"\$(grep -rl LEAD-DATA '$R' 2> /dev/null)\" ]"
  mkexp X "$sA" bin/build-x lib/x.py docs/investigations/nota.py; cp "$T/X.tar" "$T/t.tar"; ttry; refused "pasta fora do manifesto (docs/)" 'code-tar-fora-do-manifesto:docs' 1
  # vazio/falhou: a listagem de NOMES que falha depois da de tipos passar: lista vazia de nomes NÃO pode virar "nada fora do manifesto" (a guarda pré-extração ficaria cega)
  cp "$T/A.tar" "$T/t.tar"; fresh; TAR_NAMES_FAIL=1 GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$T/t.tar" --code-manifest "$T/A.man" --code-sha "$sA"
  refused "a listagem de NOMES do tar falha (a de tipos passa)" 'code-tar-ilegivel' 1; }
# a extração: o que sai do tar é conferido arquivo a arquivo contra o manifesto de A (conteúdo e bit de execução)
case_ext_content() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py; setallow "${ALLOW_BASE[@]}"
  etry() { fresh; tap "$s" "$T/t.tar" "$T/A.man" "$sA"; }
  mkexp X "$sB" bin/build-x lib/x.py; cp "$T/X.tar" "$T/t.tar"; etry; refused "conteúdo de lib/x.py diferente do blob-id do manifesto" 'code-hash:lib/x.py'
  mkexp X "$sC" bin/build-x lib/x.py; cp "$T/X.tar" "$T/t.tar"; etry; refused "bin/build-x SEM bit de execução no tar, com 100755 no manifesto" 'code-modo-difere:bin/build-x'
  mkexp X "$sD" bin/build-x lib/x.py; cp "$T/X.tar" "$T/t.tar"; etry; refused "lib/x.py COM bit de execução no tar, com 100644 no manifesto" 'code-modo-difere:lib/x.py'
  mkexp X "$sE" bin/build-x lib/x.py; cp "$T/X.tar" "$T/t.tar"; etry; refused "lib/x.py com CRLF (bytes diferentes do blob)" 'code-hash:lib/x.py'
  # o git do OPERADOR converte CRLF→LF ao hashear (core.autocrlf=input): sem `--no-filters` o hash do arquivo com CRLF CASARIA com o blob de LF e o byte diferente passaria
  fresh; printf '[core]\n\tautocrlf = input\n' > "$HOME/.gitconfig"; tap "$s" "$T/t.tar" "$T/A.man" "$sA"
  refused "CRLF com o git do operador em autocrlf=input (o hash tem de ser dos bytes, sem filtro)" 'code-hash:lib/x.py'; rm -f "$HOME/.gitconfig"
  mkexp X "$sA" bin/build-x; cp "$T/X.tar" "$T/t.tar"; etry; refused "tar sem lib/x.py (está no manifesto e na lista)" 'code-fora-da-lista'; }
# o que um tar ruim faz DEPOIS de listar bem (stubs do tar): deixa modo inseguro, troca um arquivo por elo, sai 1 no meio
case_ext_mode() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py; setallow "${ALLOW_BASE[@]}"
  cp "$T/A.tar" "$T/t.tar"; fresh; TAR_LOOSE=1 GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$T/t.tar" --code-manifest "$T/A.man" --code-sha "$sA"; refused "extração que deixa gravável pelo grupo" 'code-modo-inseguro'
  fresh; TAR_LINK=1 GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$T/t.tar" --code-manifest "$T/A.man" --code-sha "$sA"; refused "lib/x.py vira elo simbólico para uma cópia idêntica (o hash passa seguindo o elo)" 'code-elo-no-export:lib/x.py'
  fresh; TAR_X_FAIL=1 GIT_HASH_ONLY=1 ap "$s" --entrypoint build-x --code-tar "$T/t.tar" --code-manifest "$T/A.man" --code-sha "$sA"; refused "tar -x que sai 1 depois de entregar tudo" 'code-tar-extracao'; }
# a lista branca e a recusa por padrão de dado valem no ramo do tar como no do --code-dir
case_ext_data() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py; setallow "${ALLOW_BASE[@]}"
  # dado na lista: o commit tem o csv de lead, a lista (adulterada de propósito) o autoriza, o tar e o manifesto o trazem COERENTES: só a recusa por padrão de dado o segura
  setallow "${ALLOW_BASE[@]}" "build-x lib/tabela.csv"; mkexp D2 "$sA" bin/build-x lib/x.py lib/tabela.csv; fresh; tap "$s" "$T/D2.tar" "$T/D2.man" "$sA"
  refused "arquivo de dado (lib/tabela.csv) na lista, sem @fixture" 'code-dado-no-export:lib/tabela.csv'
  setallow "${ALLOW_BASE[@]}" "build-x hawkey_outbound_messages_48h.csv"; mkexp D2 "$sA" bin/build-x lib/x.py hawkey_outbound_messages_48h.csv; fresh; tap "$s" "$T/D2.tar" "$T/D2.man" "$sA"
  refused "o csv do vazamento real (hawkey_outbound_messages_48h.csv) na lista" 'code-dado-no-export:hawkey_outbound_messages_48h.csv'
  setallow "${ALLOW_BASE[@]}" "build-x contacts_auth/helper.py"; mkexp D2 "$sA" bin/build-x lib/x.py contacts_auth/helper.py; fresh; tap "$s" "$T/D2.tar" "$T/D2.man" "$sA"
  refused "contacts_auth/ na lista" 'code-dado-no-export:contacts_auth/helper.py'
  setallow "@fixture lib/tabela.csv" "${ALLOW_BASE[@]}" "build-x lib/tabela.csv"; mkexp D2 "$sA" bin/build-x lib/x.py lib/tabela.csv; fresh; tap "$s" "$T/D2.tar" "$T/D2.man" "$sA"
  ck "@fixture isenta o arquivo dela no tar também: instala (rc 0) e o arquivo está lá" bash -c "[ $RC = 0 ] && [ -f '$app/lib/tabela.csv' ] && [ ! -e '$app/hawkey_outbound_messages_48h.csv' ]"
  setallow "${ALLOW_BASE[@]}"
  # a lista branca vale no ramo do tar como no do --code-dir: ausente/ilegível → 98 com a dica; entrypoint sem linha → 98; ANTES de mexer no nó
  rm -f "$T/allow.txt"; fresh; tap "$s" "$T/A.tar" "$T/A.man" "$sA"; refused "lista branca ausente (nunca 'sem lista = exporta tudo')" 'code-allow-ilegivel' 1
  ck "a recusa da lista ausente diz onde ela tem de estar (gt-dados-src)" has "$ERR" 'gt-dados-src'
  setallow "outro-ep lib/other.py"; fresh; tap "$s" "$T/A.tar" "$T/A.man" "$sA"; refused "entrypoint sem linha na lista" 'code-allow-sem-linha:build-x' 1; setallow "${ALLOW_BASE[@]}"; }
# `verify-code`: a MESMA conferência, sem root e sem tocar no nó, numa pasta temporária que sempre some (o mini a roda antes de mandar o tar)
# uma pasta foi criada (o mktemp registrou) e NENHUMA das criadas existe mais
gone() { local d; [ -s "$T/mktemp.log" ] || return 1; while IFS= read -r d; do [ ! -e "$d" ] || return 1; done < "$T/mktemp.log"; }
case_verify() { local s=$1 app="$R/opt/gt-dados/app"
  mkrepo; mkexp A "$sA" bin/build-x lib/x.py; setallow "${ALLOW_BASE[@]}"
  vinst() { world; echo old > "$app/stale"; rm -rf "$T/vtmp"; mkdir -p "$T/vtmp"; : > "$T/mktemp.log"; TMPDIR="$T/vtmp" ID_U=1000 GIT_HASH_ONLY=1 inst "$s" verify-code "$@"; }
  vinst --code-tar "$T/A.tar" --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x
  ck "verify-code (como NÃO-root): rc 0 e diz GTD-CODE: ok com o commit e o nº de arquivos" bash -c "[ $RC = 0 ] && grep -q '^GTD-CODE: ok commit=$sA arquivos=2' '$OUT'"
  ck "verify-code não toca no nó: nenhum useradd/mount/systemctl, a árvore antiga intacta e sem app.new" bash -c "! grep -q -E '^(useradd|usermod|mount|systemctl)' '$LOG' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ] && [ ! -e '$R/etc/gt-dados/entrypoints' ]"
  ck "verify-code criou uma pasta temporária (em TMPDIR) e ela SUMIU" gone
  mkexp B "$sB" bin/build-x lib/x.py; vinst --code-tar "$T/B.tar" --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x
  ck "verify-code: conteúdo diferente do manifesto → 98 code-hash:lib/x.py (o mini RECUSA exportar)" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-hash:lib/x.py' '$ERR'"
  ck "verify-code reprovado também apaga a pasta temporária (criada e sumiu)" gone
  vinst --code-tar "$T/A.tar" --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x --pubkey-file "$T/mini.pub"; usage_is "verify-code recusa --pubkey-file (não instala nada)" 'opção não vale em verify-code: --pubkey-file'
  vinst --code-tar "$T/A.tar" --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x --code-dir "$T"; usage_is "verify-code recusa --code-dir" 'opção não vale em verify-code: --code-dir'
  vinst --code-sha "$sA" --entrypoint build-x; usage_is "verify-code sem --code-tar nem --code-manifest" 'verify-code exige --code-tar, --code-manifest e --code-sha'
  vinst --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x; usage_is "verify-code só com o manifesto" '--code-tar exige --code-manifest e --code-sha'
  vinst --code-tar "$T/A.tar" --code-manifest "$T/A.man" --code-sha "$sA"; ck "verify-code sem entrypoint de código (só o synth) → 98 code-allow-vazia" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-allow-vazia' '$ERR'"
  setallow "${ALLOW_BASE[@]}" "build-x hawkey_outbound_messages_48h.csv"; mkexp D2 "$sA" bin/build-x lib/x.py hawkey_outbound_messages_48h.csv
  vinst --code-tar "$T/D2.tar" --code-manifest "$T/D2.man" --code-sha "$sA" --entrypoint build-x
  ck "verify-code: arquivo de dado na lista → 98 code-dado-no-export (o dado nunca sai do mini)" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-dado-no-export:hawkey_outbound_messages_48h.csv' '$ERR'"; setallow "${ALLOW_BASE[@]}"
  # vazio/falhou: o mktemp que falha → recusa (nunca "sem pasta = conferiu", e nunca extrair numa pasta de nome vazio, que cairia na raiz do disco)
  : > "$T/mktemp.log"; world; echo old > "$app/stale"; MKTEMP_FAIL=1 ID_U=1000 GIT_HASH_ONLY=1 inst "$s" verify-code --code-tar "$T/A.tar" --code-manifest "$T/A.man" --code-sha "$sA" --entrypoint build-x
  ck "verify-code: mktemp que falha → 98 code-tmp" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-tmp' '$ERR'"
  world; ID_U=1000 inst "$s" apply --pubkey-file "$T/mini.pub"; ck "apply continua exigindo root (não é root → 64)" rcis 64; }
# o --code-dir (LEGADO) segue valendo, mas avisa que exige no nó um clone com TODOS os blobs do commit (dado de lead incluso) e aponta o --code-tar
case_legacy_warn() { local s=$1 app="$R/opt/gt-dados/app"
  fresh; ap "$s" --code-dir "$T" --code-sha abc123
  ck "--code-dir (legado) avisa no stderr: exige NO NÓ um clone com todos os blobs e o caminho do nó real é --code-tar" bash -c "grep -q 'AVISO: --code-dir exige NO NÓ um clone com TODOS os blobs' '$ERR' && grep -q -- '--code-tar/--code-manifest' '$ERR'"; }
# a lista de PRODUÇÃO (hetzner-dados-code-allow.txt) pelo ramo do tar: um commit com exatamente os arquivos dela, exportado como o mini faz e instalado com TODOS os entrypoints dela
# vazio/falhou: lista de produção ilegível → `ents` fica vazio e o caso reprova (nunca "instalou sem entrypoint = ok")
case_prod() { local s=$1 app="$R/opt/gt-dados/app" ents="" want="" ep pa x e sha eargs=() paths=() ok=1
  rm -rf "$T/repo"; mkdir -p "$T/repo"; cp "$HERE/hetzner-dados-code-allow.txt" "$T/allow.txt"
  while read -r ep pa x || [ -n "${ep:-}" ]; do case ${ep:-} in '' | '#'* | @fixture) continue ;; esac
    mkdir -p "$T/repo/$(dirname "$pa")"; printf '#!/bin/sh\n' > "$T/repo/$pa"; case $pa in bin/*) chmod 755 "$T/repo/$pa" ;; esac
    case " $ents " in *" $ep "*) ;; *) ents="$ents $ep" ;; esac; paths+=("$pa"); want="$want$pa"$'\n'
  done < "$HERE/hetzner-dados-code-allow.txt"
  ( cd "$T/repo" && /usr/bin/git init -q . && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t && /usr/bin/git config commit.gpgsign false && /usr/bin/git add -A && /usr/bin/git commit -q -m c ) > /dev/null 2>&1
  sha=$(/usr/bin/git -C "$T/repo" rev-parse HEAD 2> /dev/null); want=$(printf '%sbin/synth\n' "$want" | LC_ALL=C sort -u)
  ck "prod: a lista de produção tem entrypoints e o commit de teste foi criado" bash -c "[ -n '$ents' ] && [ -n '$sha' ]"
  mkexp P "$sha" ${paths[@]+"${paths[@]}"}
  for e in $ents; do eargs+=(--entrypoint "$e"); done
  fresh; GIT_HASH_ONLY=1 ap "$s" ${eargs[@]+"${eargs[@]}"} --code-tar "$T/P.tar" --code-manifest "$T/P.man" --code-sha "$sha"
  [ "$RC" = 0 ] || [ "$QUIET" = 1 ] || { echo "--- prod: rc=$RC"; cat "$ERR"; echo "--- fim"; }
  ck "prod: a lista de PRODUÇÃO instala pelo tar (rc 0, 20 itens do --check ok)" bash -c "[ $RC = 0 ] && [ \"\$(grep -c '^GTD-CHECK: .* ok\$' '$OUT')\" = 20 ]"
  ck "prod: a árvore do nó é exatamente a lista de produção (+ o synth do instalador)" test "$(cd "$app" 2> /dev/null && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort)" = "$want"
  for e in $ents; do [ -x "$app/bin/$e" ] && grep -q "gt-dados-run $e\$" "$R/etc/sudoers.d/gt-dados-run" || ok=0; done
  ck "prod: cada entrypoint da lista de produção está instalado, executável e no sudoers" test "$ok" = 1
  setallow "${ALLOW_BASE[@]}"; }
case_happy "$T/inst.sh"; case_usage "$T/inst.sh"; case_legacy_warn "$T/inst.sh"; case_manifest "$T/inst.sh"; case_tarfile "$T/inst.sh"; case_ext_content "$T/inst.sh"; case_ext_mode "$T/inst.sh"; case_ext_data "$T/inst.sh"; case_prod "$T/inst.sh"; case_verify "$T/inst.sh"
# ── mutantes: cada guarda do código novo tirada SOZINHA tem de reprovar o caso que a prova (um mutante vivo = guarda que nenhum teste distingue: apague o código ou escreva o teste)
mut() { local name=$1 expr=$2 fn=$3 mc="$T/mut-$1.sh"; mkcopy "$HERE/hetzner-dados-install.sh" "$expr" "$mc"; cmp -s "$mc" "$T/inst.sh" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  QUIET=1; BAD=0; "$fn" "$mc" > /dev/null 2>&1; QUIET=0; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
# uso
mut T01-code-dir-e-tar-juntos 's#^\[ -z "\$CODE" \] || \[ -z "\$CTAR\$CMAN" \] || {#true || {#' case_usage
mut T02-tar-sem-manifesto-ou-sha 's#^\[ -z "\$CTAR\$CMAN" \] || { \[ -n "\$CTAR" \] && \[ -n "\$CMAN" \] && \[ -n "\$SHA" \]; } || {#true || {#' case_usage
mut T03-verify-sem-tar 's#^\[ "\$MODE" != verify-code \] || \[ -n "\$CTAR" \] || {#true || {#' case_verify
mut T04-verify-aceita-opcao-de-instalacao 's#echo "opção não vale em verify-code: \$1" >&2; exit 64#true#' case_verify
mut T05-opcao-sem-valor-do-tar-gira 's,--stage-size | --code-tar | --code-manifest) \[ \$# -ge 2 \],--stage-size) [ $# -ge 2 ],' case_usage
mut T38-apply-sem-exigir-root 's#{ \[ "\$MODE" = apply \] && \[ "\$(id -u)" = 0 \]; }#{ [ "$MODE" = apply ]; }#' case_verify
mut T41-code-dir-sem-aviso 's#GTD-INSTALL: AVISO: --code-dir exige NO NÓ#GTD-INSTALL: ok: --code-dir exige NO NÓ#' case_legacy_warn
# manifesto
mut T06-sha-sem-forma 's#\[\[ \$SHA =~ ^\[0-9a-f\]{40}\$ \]\] || die code-sha-invalido#true#' case_manifest
mut T08-manifesto-que-nao-e-arquivo-trava 's#\[ -f "\$CMAN" \] || die code-manifesto-ilegivel#true#' case_manifest
mut T09-cat-que-falha-vira-vazio 's#MAN=\$(cat "\$CMAN") || die code-manifesto-ilegivel#MAN=$(cat "$CMAN")#' case_manifest
mut T10-manifesto-vazio-passa 's#\[ -n "\$MAN" \] || die code-manifesto-vazio#true#' case_manifest
mut T11-sem-conferir-o-cabecalho 's#\[ "\$ml" = "gt-dados-code-manifest 1" \] || die "code-manifesto-invalido:1"#true#' case_manifest
mut T12-sem-forma-da-linha-commit 's#\[\[ \$ml =~ \$commit_re \]\] || die "code-manifesto-invalido:2"#true#' case_manifest
mut T13-commit-do-manifesto-livre 's#\[ "\$ml" = "commit \$SHA" \] || die code-manifesto-commit-diferente#true#' case_manifest
mut T14-sem-forma-da-linha-de-arquivo 's#\[\[ \$ml =~ \$man_re \]\] || die "code-manifesto-invalido:\$mn"#true#' case_manifest
mut T15-caminho-do-manifesto-sem-guarda 's#\[\[ \$mp != \*/ && \$mp != \*\.\.\* && \$mp != \*//\* \]\] || die "code-manifesto-invalido:\$mn"#true#' case_manifest
mut T16-manifesto-sem-arquivo-passa 's#\[ "\$MN" -ge 1 \] || die code-manifesto-vazio#true#' case_manifest
mut T17-manifesto-fora-da-lista-passa 's#\[ "\$MANS" = "\$WLS" \] ||#true ||#' case_manifest
mut T18-bin-sem-exec-passa 's#\*) die "code-bin-sem-exec:\$e" ;; esac; done#*) ;; esac; done#' case_manifest
# tar (antes de extrair)
mut T07-tar-que-nao-e-arquivo-trava 's#\[ -f "\$CTAR" \] || die code-tar-ilegivel#true#' case_tarfile
mut T19-listagem-que-falha-vira-vazia 's#tar -tvf "\$CTAR" | cut -c1 | LC_ALL=C sort -u) || die code-tar-ilegivel#tar -tvf "$CTAR" | cut -c1 | LC_ALL=C sort -u)#' case_tarfile
mut T20-listagem-sem-pipefail 's#TT=\$(set -o pipefail; #TT=$(#' case_tarfile
mut T21-tar-vazio-passa 's#\[ -n "\$TT" \] || die code-tar-vazio#true#' case_tarfile
mut T22-tipo-do-membro-livre 's#\[ -z "\$odd" \] || die "code-tar-tipo:\${odd:0:1}"#true#' case_tarfile
mut T23-nomes-que-falham-viram-vazios 's#TN=\$(tar -tf "\$CTAR") || die code-tar-ilegivel#TN=$(tar -tf "$CTAR")#' case_tarfile
mut T24-nome-do-membro-livre 's#\[\[ \$tn =~ \$allow_re && \$tn != \*\.\.\* && \$tn != \*//\* \]\] || die "code-tar-nome:\$tn"#true#' case_tarfile
mut T25-membro-fora-do-manifesto-passa 's#\*) die "code-tar-fora-do-manifesto:\$tn" ;; esac#*) ;; esac#' case_tarfile
# extração
mut T26-tar-x-que-falha-passa 's#|| { rm -rf -- "\$NEW"; die code-tar-extracao; }#|| true#' case_ext_mode
mut T27-tar-sem-a-cauda-comum 's#^  code_tree_check "\$NEW"$#  true#' case_ext_mode
mut T28-elo-no-export-passa 's#\[ ! -L "\$NEW/\$mp" \] || {#true || {#' case_ext_mode
mut T29-hash-com-filtro-do-operador 's# hash-object --no-filters -- # hash-object -- #' case_ext_content
mut T30-hash-diferente-passa 's#\[ "\$got" = "\$mb" \] || {#true || {#' case_ext_content
mut T31-exec-do-manifesto-sem-conferir 's#then \[ -x "\$NEW/\$mp" \] || {[^}]*}#then true#' case_ext_content
mut T32-nao-exec-do-manifesto-sem-conferir 's#else \[ ! -x "\$NEW/\$mp" \] || {[^}]*}; fi#else true; fi#' case_ext_content
mut T33-linha-vazia-do-manifesto-vira-arquivo 's#\[ -n "\$ml" \] || continue#true#' case_happy
# apply / verify-code
mut T37-apply-sem-preparar-o-tar 's#^\[ -z "\$CTAR" \] || code_tar_prepare#true#' case_happy
mut T39-apply-sem-dizer-o-commit 's#código do commit \$SHA (\$MN arquivos, tar + manifesto) conferido arquivo a arquivo#ok#' case_happy
mut T40-tar-pelo-ramo-do-git-archive 's#^  if \[ -n "\$CTAR" \]; then#  if false; then#' case_happy
mut T42-lista-e-export-so-para-o-code-dir 's#^if \[ -n "\$CODE\$CTAR" \]; then$#if [ -n "$CODE" ]; then#' case_happy
mut T34-mktemp-que-falha-vira-pasta-vazia 's#\(VT=\$(mktemp -d "\${TMPDIR:-/tmp}/gt-dados-verify.XXXXXX")\) || die code-tmp#\1#' case_verify
mut T35-verify-deixa-a-pasta-temporaria 's#^  trap .* EXIT$#  true#' case_verify
mut T36-verify-sem-extrair 's#^  code_from_tar "\$VT/app.new"#  true#' case_verify
echo "---"; echo "casos: $n, reprovados: $fails"; [ "$fails" -eq 0 ]
