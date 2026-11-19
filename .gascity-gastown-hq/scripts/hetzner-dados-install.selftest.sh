#!/usr/bin/env bash
# hetzner-dados-install.selftest.sh — hermético: o instalador de root roda numa "raiz" de mentira ($T/r) com useradd, sshd, visudo, systemctl, mount, stat... como stubs; nada toca o sistema (ga-qg1dw5z.1).
#
# ## Contents
#   Casos · Mutantes · O que este teste NÃO prova
#
# CASOS: recusas antes de tocar em qualquer coisa (não é root, chave com opções/2 linhas/ilegível, entrypoint e tamanho inválidos, código sem sha limpo, runner no grupo, grupos extras) · instalação feliz (usuário, sudoers sem curinga,
#   chave de root com restrict, drop-in, fstab sem perder as outras linhas, árvore, timer) e `--check` com os 20 itens ok · idempotência · sshd reprovado desfaz o drop-in (-t, dados fora do arquivo de root, runner afetado) e restaura o anterior ·
#   visudo reprovado não troca o sudoers · fstab ilegível não é reescrito · link para fora da árvore · `--check` que FALHA / não consegue (cada item adulterado, e cada leitura que falha: id do runner, swapon, árvore, sudoers, sshd -T) · opção sem valor (com prazo: nunca gira) · chave com linha em branco · sshd -T do runner que falha desfaz o drop-in · `--code-dir` com repo de verdade (git archive do COMMIT: arquivo ignorado e edição assume-unchanged não entram, árvore antiga some, extração com modo inseguro e git archive que morre no meio → 98 com a árvore antiga intacta) · chave de root com grupo errado · LISTA BRANCA do código (wa-4p38ls, P0): o commit do teste tem dado de lead (hawkey_outbound_messages_48h.csv, contacts_auth/, docs/investigations/, *.db/*.sqlite/*.jsonl) e o nó recebe SÓ o fechamento da lista (nenhum byte de dado, nem lib/other.py);
#   recusas 98 com o código certo e a árvore antiga intacta: lista ilegível/linha inválida/entrypoint sem linha/entrypoint sem o próprio bin/<ep>/lista vazia, arquivo fora do commit, pasta na lista (o archive leva mais que a lista), arquivo de dado na lista sem `@fixture` (cada extensão — csv/CSV, db, sqlite, sqlite3, jsonl, parquet, duckdb, xlsx, xls, vcf — e cada pasta, na raiz e aninhada: contacts_auth/, docs/investigations/), `tr` que falha lê o caminho como DADO, `@fixture` isenta só o arquivo dele; linha de outro entrypoint não entra ·
#   ENTREGA (gate de 19/11): o instalador roda NO NÓ de /root/gt-dados-src, que só tem o que o `scp` do runbook (docs/runbooks/hetzner-dados.md, passo 2) leva. O caso lê essa linha do PRÓPRIO runbook, monta uma pasta com SÓ esses arquivos, roda o instalador de lá (SRC e ALLOW como no original, não os do teste) com a lista de PRODUÇÃO e um commit com exatamente os arquivos dela → instala; e a mesma pasta SEM a lista → 98 code-allow-ilegivel com a dica, antes de mexer no nó. Runbook ilegível = o caso reprova (nunca "nada a entregar").
# O QUE NÃO PROVA: que useradd/sshd/sudo/mount se comportam assim no Ubuntu 24.04 do nó. Isso é o `--check` + `hetzner-dados-prove.sh` rodados no nó depois da instalação.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzdados-inst-selftest.XXXXXX"); R="$T/r"; LOG="$T/log"; OUT="$T/out"; ERR="$T/err"; ME=$(id -un)
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/stubs" "$T/own"
# a lista branca do código (wa-4p38ls): o instalador copiado lê $T/allow.txt (mkcopy), não a lista de produção; o entrypoint de teste é o build-x
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
# `timeout` (GNU) não existe no PATH hermético do macOS (/usr/bin:/bin): sem o stub a 1ª varredura "falhava" aqui por `command not found`, não pelo que o caso prova (SWEEP_FAIL é do systemctl)
mk timeout 'shift; exec "$@"'
mk mountpoint '[ -f "$T/mounted" ]'
mk mount 'echo "mount $*" >> "$LOG"; touch "$T/mounted"; echo "dados dados 700" > "$T/own/$(echo "$R/srv/gtdados" | tr / _)"'
mk findmnt 'echo "${FS:-tmpfs} rw,nosuid,nodev,noexec,relatime"'
mk swapon '[ -z "${SWAPON_FAIL:-}" ] || exit 1; [ -z "${SWAP:-}" ] || echo "/dev/sda2 partition 1G"'
mk rsync 'echo "rsync $*" >> "$LOG"; for a; do d=$a; done; mkdir -p "$d"; cp -R "${@: -2:1}". "$d"'
mk git 'if [ "${GIT_REAL:-}" = 1 ]; then
  # GIT_ARCHIVE_FAIL: um `git archive` que entrega um tar COMPLETO e válido de uma árvore parcial e só depois sai 1 (o tar da outra ponta do pipe aceita o que chegou: só o pipefail reprova)
  [ "$3" = archive ] && [ -n "${GIT_ARCHIVE_FAIL:-}" ] && { /usr/bin/tar -c -C "$T/partial" .; exit 1; }
  exec /usr/bin/git "$@"
fi
case "$3" in rev-parse) echo "${GIT_HEAD:-abc123}" ;; status) echo "${GIT_DIRTY:-}" ;; esac'
# TAR_LOOSE: um tar que, depois de extrair, deixa o que extraiu gravável pelo grupo (o instalador não pode confiar só no umask/--no-same-permissions)
mk tar 'a=("$@"); /usr/bin/tar "$@"; rc=$?; if [ -n "${TAR_LOOSE:-}" ]; then for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = -C ] && d=${a[i+1]}; done; [ -z "${d:-}" ] || /bin/chmod -R g+w "$d"/*; fi; exit $rc'
# TR_FAIL: o `tr` do `data_path` (minúsculas) que falha; só esse uso reprova, o `tr / _` dos outros stubs passa (wa-4p38ls: falhou → o arquivo conta como DADO, nunca como "não é dado")
mk tr '[ "${TR_FAIL:-}" = 1 ] && [ "$1" = "[:upper:]" ] && exit 1; exec /usr/bin/tr "$@"'
mk install 'a=(); u=""; g=""; m=""; d=0; while [ $# -gt 0 ]; do case "$1" in -o) u=$2; shift 2 ;; -g) g=$2; shift 2 ;; -m) m=$2; shift 2 ;; -d) d=1; shift ;; *) a+=("$1"); shift ;; esac; done
/usr/bin/install $([ $d = 1 ] && echo -d) ${m:+-m $m} "${a[@]}" || exit 1; [ $d = 1 ] && t=("${a[@]}") || t=("${a[${#a[@]}-1]}")
for p in "${t[@]}"; do echo "${u:-root} ${g:-root} ${m#0}" | sed "s/ $/ 755/" > "$T/own/$(echo "$p" | tr / _)"; done'
mk chown 'echo "${1%%:*} ${1##*:} $(cat "$T/own/$(echo "$2" | tr / _)" 2>/dev/null | cut -d" " -f3)" > "$T/own/$(echo "$2" | tr / _)"'
mk chmod 'if [ -f "$2" ] && [ ! -d "$2" ] || [ -d "$2" ]; then /bin/chmod "$@"; fi; f="$T/own/$(echo "$2" | tr / _)"; u=root g=root; [ -f "$f" ] && read -r u g _ < "$f"; echo "$u $g ${1#0}" > "$f"'
mk mv '/bin/mv "$@"; f="$T/own/$(echo "$1" | tr / _)"; [ -f "$f" ] && /bin/mv "$f" "$T/own/$(echo "$2" | tr / _)"; true'
mk stat '[ "$1" = -c ] || exit 2; f="$T/own/$(echo "$3" | tr / _)"; [ -e "$3" ] || exit 1; read -r u g m < "$f" 2>/dev/null || { u=root g=root m=644; }; case "$2" in "%U:%G %a") echo "$u:$g $m" ;; "%U %a") echo "$u $m" ;; esac'
export LOG T R
# NODE_LAYOUT=1: a cópia roda como no nó (SRC = a pasta onde o instalador está, ALLOW = o default ao lado dele): as duas linhas passam por uma substituição que não troca nada. Sem isso o teste lê a lista de $T/allow.txt e os scripts de $HERE,
# e nenhum caso vê o que a entrega leva ao nó (o gate de 19/11 achou a lista fora do scp do runbook; a cópia testada escondia isso)
mkcopy() { local s1="s#^SRC=.*; RUNNER=runner\$#SRC=$HERE; RUNNER=runner#" s2="s#^ALLOW=.*\$#ALLOW=$T/allow.txt#"; [ "${NODE_LAYOUT:-}" != 1 ] || { s1='s#^SRC=.*; RUNNER=runner$#&#'; s2='s#^ALLOW=.*$#&#'; }
  sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#^DU=dados; SBIN=/usr/local/sbin; ETC=/etc/gt-dados; OPT=/opt/gt-dados; STAGE=/srv/gtdados; DHOME=/home/dados; SSHD_D=/etc/ssh/sshd_config.d; AKDIR=/etc/ssh/authorized_keys.d\$#DU=dados; SBIN=$R/usr/local/sbin; ETC=$R/etc/gt-dados; OPT=$R/opt/gt-dados; STAGE=$R/srv/gtdados; DHOME=$R/home/dados; SSHD_D=$R/etc/ssh/sshd_config.d; AKDIR=$R/etc/ssh/authorized_keys.d#" \
  -e "s#^SUDOERS=/etc/sudoers.d/gt-dados-run; FSTAB=/etc/fstab; UNITS=/etc/systemd/system; LOGF=/var/log/gt-dados-sweep.log\$#SUDOERS=$R/etc/sudoers.d/gt-dados-run; FSTAB=$R/etc/fstab; UNITS=$R/etc/systemd/system; LOGF=$R/var/log/gt-dados-sweep.log#" -e "$s1" -e "$s2" -e 's#-user root#-user '"$ME"'#g' ${2:+-e "$2"} "$1" > "$3"; chmod +x "$3"; }
mkcopy "$HERE/hetzner-dados-install.sh" "" "$T/inst.sh" 2>/dev/null; mkcopy "$HERE/hetzner-dados-install.sh" "" "$T/inst.sh"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }; has() { grep -q -E -- "$2" "$1"; }; hasnt() { ! grep -q -E -- "$2" "$1"; }
ck "a cópia testada só troca caminhos, PATH e -user" test "$(diff "$HERE/hetzner-dados-install.sh" "$T/inst.sh" | grep '^<' | grep -v -c -e 'PATH=' -e '^< DU=dados' -e '^< SUDOERS=' -e '^< SRC=' -e '^< ALLOW=' -e '-user root')" = 0
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey mini@gt" > "$T/mini.pub"
world() { chmod -R u+rwx "$T/r" 2>/dev/null; find "$T/r" "$T/own" -mindepth 1 -delete 2>/dev/null; rm -f "$T/user" "$T/mounted"
  mkdir -p "$R/etc/ssh/sshd_config.d" "$R/etc/sudoers.d" "$R/etc/systemd/system" "$R/var/log" "$R/opt/gt-dados/app/bin" "$R/srv" "$R/usr/local/sbin"; printf 'UUID=1 / ext4 defaults 0 1\n' > "$R/etc/fstab"; : > "$LOG"
  # a árvore de root já traz o entrypoint extra (como o `--code-dir` traria): o instalador RECUSA entrypoint que não está nela
  printf '#!/bin/sh\n' > "$R/opt/gt-dados/app/bin/build-x"; chmod 755 "$R/opt/gt-dados/app/bin/build-x"; }
inst() { local s=$1; shift; "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
ap() { inst "$1" apply --pubkey-file "$T/mini.pub" "${@:2}"; }
# como inst, mas com prazo de 3 s: um instalador que GIRA (laço sem saída) vira RC=124, nunca trava a bateria
inst_t() { local s=$1 p i=0; shift; "$s" "$@" > "$OUT" 2> "$ERR" & p=$!; while kill -0 "$p" 2> /dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  if kill -0 "$p" 2> /dev/null; then kill -9 "$p" 2> /dev/null; wait "$p" 2> /dev/null; RC=124; else wait "$p"; RC=$?; fi; }
okc() { grep -c '^GTD-CHECK: .* ok$' "$OUT"; }
case_refuse() { local s=$1
  world; ID_U=1000 inst "$s" apply --pubkey-file "$T/mini.pub"; ck "não é root → 64" rcis 64; world; inst "$s"; ck "sem argumentos → 64" rcis 64; inst "$s" apply --nao-existe; ck "argumento desconhecido → 64" rcis 64
  world; ap "$s" --entrypoint 'A/../b'; ck "entrypoint inválido → 98" rcis 98; ap "$s" --entrypoint -x; ck "entrypoint '-x' → 98" rcis 98; ap "$s" --stage-size 8; ck "stage-size sem unidade → 98" rcis 98; ap "$s" --stage-size 0g; ck "stage-size 0g → 98" rcis 98
  ap "$s" --code-dir "$T"; ck "code-dir sem sha → 98" rcis 98; GIT_HEAD=outro ap "$s" --code-dir "$T" --code-sha abc123; ck "HEAD ≠ sha → 98" rcis 98; GIT_DIRTY=" M x" ap "$s" --code-dir "$T" --code-sha abc123; ck "árvore suja → 98" rcis 98
  for kc in "" 'restrict,command="x" ssh-ed25519 AAAAB3Nza k' 'ssh-ed25519 AAAAB3Nza k
ssh-ed25519 AAAAB3Nzb k2' 'lixo sem chave' 'ssh-ed25519 BADKEY'; do printf '%s\n' "$kc" > "$T/k.pub"; inst "$s" apply --pubkey-file "$T/k.pub"; ck "chave inválida ('$(printf %s "$kc" | head -c 20)') → 98 pubkey" rcis 98; done
  inst "$s" apply --pubkey-file "$T/nao-existe.pub"; ck "chave inexistente → 98" rcis 98; ck "recusas: nada foi criado/instalado" hasnt "$LOG" '^(useradd|usermod|mount|systemctl)'
  world; ID_G_RUNNER="runner dados" ap "$s"; ck "runner no grupo dados → 98" bash -c "[ $RC = 98 ] && grep -q 'runner-no-grupo-dados' '$ERR'"; world; ID_G_DADOS="dados sudo" ap "$s"; ck "dados com grupo extra → 98" has "$ERR" 'grupos-extras-do-dados'
  world; for o in --pubkey-file --entrypoint --code-dir --code-sha --runner --stage-size; do inst_t "$s" apply $o; ck "opção sem valor ($o, última palavra) → 64, não gira para sempre" rcis 64; done
  inst_t "$s" apply --pubkey-file "$T/mini.pub" --runner; ck "opção sem valor depois de uma opção boa → 64" rcis 64
  world; ID_RUNNER_FAIL=1 ap "$s"; ck "id do runner falha (nome errado/NSS) → 98 runner-ilegivel, nunca 'fora do grupo'" bash -c "[ $RC = 98 ] && grep -q 'runner-ilegivel' '$ERR'"
  world; ap "$s" --entrypoint fantasma; ck "entrypoint que não está na árvore → 98" has "$ERR" 'entrypoint-ausente:fantasma'; world; mkdir -p "$R/opt/gt-dados/app/bin"; ln -s /etc/passwd "$R/opt/gt-dados/app/bin/evil"; ap "$s"; ck "link para fora da árvore → 98" has "$ERR" 'link-fora-da-arvore'; }
case_happy() { local s=$1; world; ap "$s" --entrypoint build-x --runner runner --stage-size 6g; [ "$RC" = 0 ] || { echo "--- a instalação feliz saiu rc=$RC; stderr e itens do --check que não deram ok:"; cat "$ERR"; grep '^GTD-CHECK:' "$OUT" | grep -v ' ok$'; echo "--- fim"; }; ck "instalação feliz: rc 0" rcis 0; ck "feliz: os 20 itens do --check ok" test "$(okc)" = 20; ck "feliz: nenhum FALHOU/nao-consegui" hasnt "$OUT" 'FALHOU|nao-consegui'
  ck "feliz: useradd sem skel (-M), shell real, grupo próprio" has "$LOG" '^useradd -M -d .*/home/dados -s /bin/bash -U '; ck "feliz: senha travada (usermod -L)" has "$LOG" '^usermod -L dados$'
  ck "sudoers: exatamente 2 linhas (synth, build-x), uma por entrypoint" test "$(grep -c '^runner ALL=(root) NOPASSWD: .*/gt-dados-run \(synth\|build-x\)$' "$R/etc/sudoers.d/gt-dados-run")" = 2; ck "sudoers: sem curinga e sem (dados) (fora dos comentários)" bash -c "! grep -v '^#' '$R/etc/sudoers.d/gt-dados-run' | grep -E '\*|\(dados\)'"
  ck "chave: restrict + command do ingest + a chave do mini, numa linha" has "$R/etc/ssh/authorized_keys.d/dados" '^restrict,command=".*/gt-dados-ingest" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey mini@gt$'
  ck "drop-in: Match User dados + arquivo de ROOT + sem senha/túnel/tty" bash -c "grep -q '^Match User dados' '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' && grep -q 'AuthorizedKeysFile .*/authorized_keys.d/dados' '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' && grep -q 'AllowTcpForwarding no' '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' && grep -q 'PermitTTY no' '$R/etc/ssh/sshd_config.d/50-gt-dados.conf'"
  ck "fstab: a linha antiga ficou e a nossa tem tmpfs 6g, uid/gid numéricos, noexec,nosuid,nodev,nofail" bash -c "grep -q 'UUID=1 / ext4' '$R/etc/fstab' && grep -q 'tmpfs .*/srv/gtdados tmpfs size=6g,mode=0700,uid=1234,gid=1234,noexec,nosuid,nodev,nofail 0 0 # gt-dados\$' '$R/etc/fstab'"
  ck "lista de entrypoints (synth, build-x) e scripts do repo instalados" bash -c "[ \"\$(sort '$R/etc/gt-dados/entrypoints' | tr '\n' ' ')\" = 'build-x synth ' ] && [ -x '$R/usr/local/sbin/gt-dados-run' ] && cmp -s '$HERE/hetzner-dados-run.sh' '$R/usr/local/sbin/gt-dados-run' && cmp -s '$HERE/hetzner-dados-synth.sh' '$R/opt/gt-dados/app/bin/synth'"
  ck "sshd: -t e os dois -T ANTES do reload" bash -c "grep -n -E '^sshd -t|^sshd -T -C user=dados|^sshd -T -C user=runner|^systemctl reload' '$LOG' | cut -d: -f2 | tr '\n' '|' | grep -q '^sshd -t|sshd -T -C user=dados.*|sshd -T -C user=runner.*|systemctl reload ssh|'"
  ck "visudo -cf valida o arquivo .new (a 1ª chamada do visudo), e o sudoers final existe" bash -c "[ \"\$(grep '^visudo' '$LOG' | head -n 1)\" = 'visudo -cf $R/etc/sudoers.d/gt-dados-run.new' ] && [ -s '$R/etc/sudoers.d/gt-dados-run' ] && [ ! -e '$R/etc/sudoers.d/gt-dados-run.new' ]"
  ck "timer: enable --now e a varredura roda uma vez" bash -c "grep -q '^systemctl enable --now gt-dados-sweep.timer' '$LOG' && grep -q '^systemctl start gt-dados-sweep.service' '$LOG'"
  ap "$s" --entrypoint build-x --runner runner --stage-size 6g; ck "2ª instalação (idempotente): rc 0, 1 linha # gt-dados no fstab, 1 sudoers por entrypoint" bash -c "[ $RC = 0 ] && [ \"\$(grep -c '# gt-dados\$' '$R/etc/fstab')\" = 1 ] && [ \"\$(grep -c '^runner ' '$R/etc/sudoers.d/gt-dados-run')\" = 2 ] && [ \"\$(grep -c '^useradd' '$LOG')\" = 1 ]"
  world; printf '\n%s\n' "$(cat "$T/mini.pub")" > "$T/blank.pub"; inst "$s" apply --pubkey-file "$T/blank.pub"; ck "chave em arquivo com linha em branco antes: rc 0 e o authorized_keys tem UMA linha, a da chave, com restrict" bash -c "[ $RC = 0 ] && [ \"\$(wc -l < '$R/etc/ssh/authorized_keys.d/dados' | tr -d ' ')\" = 1 ] && grep -q '^restrict,command=\".*\" ssh-ed25519 ' '$R/etc/ssh/authorized_keys.d/dados'"; }
case_rollback() { local s=$1
  world; SWEEP_FAIL=1 ap "$s"; ck "1ª varredura falha ou passa do prazo → 98 sweep-primeira (nunca instalação 'ok' sem varredura)" bash -c "[ $RC = 98 ] && grep -q 'falhou:sweep-primeira' '$ERR'"
  world; echo "# ANTERIOR" > "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"; SSHD_T_FAIL=1 ap "$s"; ck "sshd -t reprova → 98, drop-in ANTERIOR restaurado, sem reload" bash -c "[ $RC = 98 ] && grep -q ANTERIOR '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' && ! grep -q '^systemctl reload' '$LOG'"
  world; SSHD_T_FAIL=1 ap "$s"; ck "sshd -t reprova sem drop-in anterior → drop-in removido" test ! -e "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"
  world; SSHD_DADOS_WRONG=1 ap "$s"; ck "dados fora do arquivo de root → 98, drop-in desfeito, sem reload" bash -c "[ $RC = 98 ] && [ ! -e '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' ] && ! grep -q '^systemctl reload' '$LOG'"
  world; SSHD_RUNNER_LEAK=/etc/ssh/authorized_keys.d/x ap "$s"; ck "runner afetado pelo drop-in → 98, desfeito, sem reload" bash -c "[ $RC = 98 ] && [ ! -e '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' ] && ! grep -q '^systemctl reload' '$LOG'"
  world; SSHD_RUNNER_FAIL=1 ap "$s"; ck "sshd -T do runner falha → 98 sshd-runner-ilegivel, drop-in desfeito, sem reload (silêncio não prova 'runner intacto')" bash -c "[ $RC = 98 ] && grep -q 'sshd-runner-ilegivel' '$ERR' && [ ! -e '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' ] && ! grep -q '^systemctl reload' '$LOG'"
  world; echo "# SUDOERS ANTIGO" > "$R/etc/sudoers.d/gt-dados-run"; VISUDO_FAIL=1 ap "$s"; ck "visudo reprova → 98, sudoers ANTIGO intacto, sem .new" bash -c "[ $RC = 98 ] && grep -q 'SUDOERS ANTIGO' '$R/etc/sudoers.d/gt-dados-run' && [ ! -e '$R/etc/sudoers.d/gt-dados-run.new' ]"
  world; rm -f "$R/etc/fstab"; ap "$s"; ck "fstab ilegível → 98 fstab-leitura e NÃO cria fstab só com a nossa linha" bash -c "[ $RC = 98 ] && grep -q 'fstab-leitura' '$ERR' && [ ! -s '$R/etc/fstab' ]"; }
# o código de --code-dir é o do COMMIT: repo de verdade (GIT_REAL=1) com um arquivo ignorado, uma edição escondida por assume-unchanged (nenhum dos dois aparece em `status --porcelain`) e tar.umask=0 (diretórios 0777 no archive)
# wa-4p38ls: o commit TAMBÉM tem o que não pode ir ao nó — dado de lead/conversa (todo conteúdo "LEAD-DATA"), um csv na raiz com o nome do vazamento real, contacts_auth/, docs/investigations/ — e código que nenhuma lista autoriza (lib/other.py).
# O `partial` (o que o git archive que morre entrega) é EXATAMENTE a lista base: só o pipefail o reprova
mkrepo() { rm -rf "$T/repo" "$T/partial"; mkdir -p "$T/repo/bin" "$T/repo/lib" "$T/repo/data" "$T/repo/contacts_auth" "$T/repo/docs/investigations" "$T/repo/lib/contacts_auth" "$T/repo/lib/docs/investigations" "$T/partial/bin" "$T/partial/lib"; echo partial > "$T/partial/bin/build-x"; echo partial > "$T/partial/lib/x.py"
  ( cd "$T/repo" && /usr/bin/git init -q . && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t && /usr/bin/git config commit.gpgsign false && /usr/bin/git config tar.umask 0 \
    && printf '#!/bin/sh\n' > bin/build-x && chmod 755 bin/build-x && echo good > lib/x.py && echo other > lib/other.py && echo junk > .gitignore \
    && for f in hawkey_outbound_messages_48h.csv lib/tabela.csv lib/outra.csv lib/PLANILHA.CSV lib/t.sqlite lib/t.sqlite3 lib/t.jsonl lib/t.parquet lib/t.duckdb lib/t.xlsx lib/t.xls lib/t.vcf data/contatos.db contacts_auth/helper.py contacts_auth/cookies.json docs/investigations/nota.py lib/contacts_auth/helper.py lib/docs/investigations/nota.py; do echo LEAD-DATA > "$f"; done \
    && /usr/bin/git add -A && /usr/bin/git commit -q -m c \
    && echo evil > lib/x.py && /usr/bin/git update-index --assume-unchanged lib/x.py && echo secret > junk ) > /dev/null 2>&1; }
case_code() { local s=$1 sha app="$R/opt/gt-dados/app"
  mkrepo; sha=$(/usr/bin/git -C "$T/repo" rev-parse HEAD); ck "code-dir (preparo): o repo de teste é 'limpo' para o git (o que o instalador confere) e tem a edição escondida" bash -c "[ -z \"\$(/usr/bin/git -C '$T/repo' status --porcelain)\" ] && [ \"\$(cat '$T/repo/lib/x.py')\" = evil ]"
  world; echo old > "$app/stale"; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  [ "$RC" = 0 ] || { echo "--- code-dir: rc=$RC"; cat "$ERR"; grep '^GTD-CHECK:' "$OUT" | grep -v ' ok$'; echo "--- fim"; }
  ck "code-dir: instala (rc 0, 20 itens do --check ok) e o entrypoint do commit está lá, executável" bash -c "[ $RC = 0 ] && [ \"\$(grep -c '^GTD-CHECK: .* ok\$' '$OUT')\" = 20 ] && [ -x '$app/bin/build-x' ]"
  ck "code-dir: o arquivo IGNORADO pelo .gitignore não é copiado" test ! -e "$app/junk"
  ck "code-dir: a edição escondida (assume-unchanged) não entra: o instalado é o conteúdo do COMMIT" bash -c "[ \"\$(cat '$app/lib/x.py')\" = good ]"
  ck "code-dir: o que havia na árvore e não está no commit some (como o --delete do rsync)" test ! -e "$app/stale"
  # wa-4p38ls (P0): o commit inteiro NÃO vai. A árvore do nó é exatamente o fechamento da lista (+ o synth do próprio instalador); nenhum byte de dado de lead, nem o csv do vazamento real
  ck "code-dir: o nó recebe SÓ a lista branca (bin/build-x, lib/x.py + o synth do instalador): nada de lib/other.py nem dos dados" bash -c "[ \"\$(cd '$app' && find . ! -type d | sed 's#^\./##' | sort | tr '\n' ' ')\" = 'bin/build-x bin/synth lib/x.py ' ]"
  ck "code-dir: hawkey_outbound_messages_48h.csv (o vazamento do wa-4p38ls) e todo dado de lead ficam FORA do nó" bash -c "[ ! -e '$app/hawkey_outbound_messages_48h.csv' ] && [ ! -e '$app/contacts_auth' ] && [ ! -e '$app/docs' ] && [ ! -e '$app/data' ] && [ -z \"\$(grep -rl LEAD-DATA '$app' 2> /dev/null)\" ]"
  ck "code-dir: sem .git na árvore de root e sem app.new/app.old de sobra" bash -c "[ ! -e '$app/.git' ] && [ ! -e '$R/opt/gt-dados/app.new' ] && [ ! -e '$R/opt/gt-dados/app.old' ]"
  ck "code-dir: nada gravável por grupo/outros nem setuid/setgid (o archive tinha diretórios 0777: tar.umask=0)" bash -c "[ -z \"\$(find '$app' ! -type l -perm /6022)\" ]"
  world; echo old > "$app/stale"; TAR_LOOSE=1 GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "code-dir: extração que deixa gravável pelo grupo → 98 code-modo-inseguro, árvore antiga INTACTA, sem app.new" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-modo-inseguro' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"
  world; echo old > "$app/stale"; GIT_ARCHIVE_FAIL=1 GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "code-dir: git archive que sai 1 depois de entregar um tar válido → 98 code-archive (pipefail), árvore antiga INTACTA, sem app.new" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-archive' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"
  world; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha 0000000000000000000000000000000000000000; ck "code-dir: sha que não é o HEAD → 98 e nada trocado" bash -c "[ $RC = 98 ] && grep -q 'code-dir-nao-e-o-sha-limpo' '$ERR' && [ -f '$app/bin/build-x' ] && [ ! -e '$app/lib' ]"; }
# wa-4p38ls: a lista branca e a recusa por padrão de dado. Cada recusa → 98 com o código certo (não basta o rc: outra guarda poderia ter reprovado), árvore antiga INTACTA e sem app.new.
# refuse_code enxerga $s/$sha/$app do caso que a chama (escopo dinâmico do bash) e devolve a lista base ao fim
refuse_code() { local rot=$1 msg=$2; shift 2; setallow "$@"; world; echo old > "$app/stale"; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "lista: $rot → 98 $msg, árvore antiga INTACTA, sem app.new" bash -c "[ $RC = 98 ] && grep -q 'falhou:$msg' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"; setallow "${ALLOW_BASE[@]}"; }
case_code_dado() { local s=$1 sha app="$R/opt/gt-dados/app" d
  mkrepo; sha=$(/usr/bin/git -C "$T/repo" rev-parse HEAD)
  # (a lista autoriza o arquivo de dado de PROPÓSITO: é o que a recusa tem de pegar; a maiúscula prova que o padrão não depende da caixa)
  # uma linha por extensão e por pasta, na raiz E aninhada (lib/contacts_auth/, lib/docs/investigations/): cada padrão do `data_path` tem o seu caso, e o mutante que o tira sozinho o reprova
  for d in hawkey_outbound_messages_48h.csv lib/tabela.csv lib/PLANILHA.CSV data/contatos.db lib/t.sqlite lib/t.sqlite3 lib/t.jsonl lib/t.parquet lib/t.duckdb lib/t.xlsx lib/t.xls lib/t.vcf contacts_auth/helper.py docs/investigations/nota.py lib/contacts_auth/helper.py lib/docs/investigations/nota.py; do
    refuse_code "arquivo de dado na lista, sem @fixture ($d)" "code-dado-no-export:$d" "${ALLOW_BASE[@]}" "build-x $d"; done
  # vazio/falhou: o `tr` do data_path que falha (TR_FAIL) → o caminho conta como DADO (98), nunca como "não é dado" (o `p` vazio não casava padrão nenhum e o export passava)
  setallow "${ALLOW_BASE[@]}"; world; echo old > "$app/stale"; TR_FAIL=1 GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "dado: o tr que falha lê o caminho como DADO → 98 code-dado-no-export (não instala), árvore antiga INTACTA, sem app.new" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-dado-no-export' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"
  refuse_code "@fixture isenta só o arquivo dela (lib/outra.csv segue recusado)" 'code-dado-no-export:lib/outra.csv' "${ALLOW_BASE[@]}" "@fixture lib/tabela.csv" "build-x lib/tabela.csv" "build-x lib/outra.csv"
  setallow "# fixture 100 % fictícia" "" "${ALLOW_BASE[@]}" "@fixture lib/tabela.csv" "build-x lib/tabela.csv"; world; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "lista: @fixture + linha do entrypoint (com comentário e linha em branco na lista) → instala, e o arquivo isento está lá" bash -c "[ $RC = 0 ] && [ -f '$app/lib/tabela.csv' ] && [ ! -e '$app/hawkey_outbound_messages_48h.csv' ]"; setallow "${ALLOW_BASE[@]}"; }
case_code_lista() { local s=$1 sha app="$R/opt/gt-dados/app" bad
  mkrepo; sha=$(/usr/bin/git -C "$T/repo" rev-parse HEAD)
  refuse_code "entrypoint sem linha na lista (só há linha de outro entrypoint)" 'code-allow-sem-linha:build-x' "other-ep lib/other.py"
  rm -f "$T/allow.txt"; world; echo old > "$app/stale"; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "lista: arquivo da lista ilegível/ausente → 98 code-allow-ilegivel (nunca 'sem lista = exporta tudo'), árvore antiga INTACTA" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-allow-ilegivel' '$ERR' && [ -f '$app/stale' ] && [ ! -e '$R/opt/gt-dados/app.new' ]"; setallow "${ALLOW_BASE[@]}"
  for bad in "build-x lib/" "build-x ../lib/x.py" 'build-x lib/*' "build-x" "build-x lib/x.py extra" "build-x /etc/passwd" "build-x lib/../bin/build-x"; do
    refuse_code "linha inválida na lista ('$bad')" 'code-allow-linha-invalida:build-x' "${ALLOW_BASE[@]}" "$bad"; done
  refuse_code "pasta na lista (lib: o archive leva mais do que a lista diz)" 'code-fora-da-lista' "${ALLOW_BASE[@]}" "build-x lib"
  # o entrypoint tem linhas, mas não a do próprio bin/<ep>: antes só o `entrypoint-ausente` o notava, DEPOIS da troca (árvore antiga já removida); agora a lista é recusada antes de mexer em qualquer coisa
  refuse_code "entrypoint com linhas, mas SEM a do próprio bin/build-x (recusa antes da troca)" 'code-allow-sem-bin:build-x' "build-x lib/x.py"
  refuse_code "arquivo da lista que não está no commit" 'code-archive' "${ALLOW_BASE[@]}" "build-x lib/nao-existe.py"
  world; echo old > "$app/stale"; GIT_REAL=1 ap "$s" --code-dir "$T/repo" --code-sha "$sha"
  ck "lista: --code-dir sem nenhum entrypoint de código (só o synth) → 98 code-allow-vazia, nada trocado" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-allow-vazia' '$ERR' && [ -f '$app/stale' ]"
  setallow "${ALLOW_BASE[@]}" "other-ep lib/other.py"; world; GIT_REAL=1 ap "$s" --entrypoint build-x --code-dir "$T/repo" --code-sha "$sha"
  ck "lista: a linha de OUTRO entrypoint (other-ep) não entra: só o fechamento do entrypoint pedido" bash -c "[ $RC = 0 ] && [ -f '$app/lib/x.py' ] && [ ! -e '$app/lib/other.py' ]"; setallow "${ALLOW_BASE[@]}"; }
# ENTREGA (gate de 19/11): o instalador roda NO NÓ de /root/gt-dados-src, que só tem o que o `scp` do runbook leva; o 1º envio da lista branca não a pôs nesse scp e todo `apply --code-dir` real teria recusado code-allow-ilegivel,
# sem que nenhum caso visse isso (o mkcopy trocava SRC e ALLOW pelo layout do teste). Aqui o layout é o do nó: uma pasta com SÓ os arquivos que a linha do scp do runbook entrega (lida do PRÓPRIO runbook, não repetida aqui).
# RBFILE = o runbook; RB (vazio, ou o runbook adulterado de um mutante) o substitui. `entrega` imprime um nome por linha: os tokens `$S/...` da linha do scp, com a chave `{a,b}` expandida.
# vazio/falhou: runbook ausente/ilegível ou sem a linha do scp → rc 1 e nenhum nome, e o caso reprova ("não consegui ler a entrega" nunca vira "nada a entregar = ok")
RBFILE="$HERE/../docs/runbooks/hetzner-dados.md"; RB=""
entrega() { local l t a pre alt post A; l=$(grep -E 'scp -i .*\$S/.*:/root/gt-dados-src/' "${RB:-$RBFILE}" 2> /dev/null) && [ -n "$l" ] || return 1
  for t in $l; do case $t in '$S/'*) t=${t#'$S/'}
    if [[ $t =~ ^([^{]*)\{([^}]*)\}(.*)$ ]]; then pre=${BASH_REMATCH[1]}; alt=${BASH_REMATCH[2]}; post=${BASH_REMATCH[3]}; IFS=, read -ra A <<< "$alt"; for a in ${A[@]+"${A[@]}"}; do echo "$pre$a$post"; done; else echo "$t"; fi ;; esac; done; }
case_entrega() { local ns="$T/nodesrc" names nome ok=1 ents="" want="" ep pa x e sha app="$R/opt/gt-dados/app" got eargs=()  # `nome`, não `n`: um `local n` esconderia o contador de casos que o `ck` incrementa (set -u: unbound variable)
  names=$(entrega); ck "entrega: a linha do scp do runbook é legível e leva arquivos" test -n "$names"
  rm -rf "$ns"; mkdir -p "$ns"
  for nome in $names; do if [ -f "$HERE/$nome" ]; then cp "$HERE/$nome" "$ns/$nome"; else ok=0; [ "$QUIET" = 1 ] || echo "  (o runbook entrega '$nome', que não existe em $HERE)"; fi; done
  ck "entrega: todo arquivo que o scp do runbook leva existe no repo" test "$ok" = 1
  # o instalador da entrega é o mesmo arquivo, só com os caminhos de root trocados pelos do mundo de mentira; SRC e ALLOW ficam como no original (NODE_LAYOUT): é a pasta dele que decide de onde vêm a lista e os scripts
  if [ -f "$ns/hetzner-dados-install.sh" ]; then NODE_LAYOUT=1; mkcopy "$HERE/hetzner-dados-install.sh" "${MUT_EXPR:-}" "$ns/hetzner-dados-install.sh"; NODE_LAYOUT=0; fi
  # a lista de PRODUÇÃO decide o commit: cada caminho dela vira um arquivo (bin/* executável) e a árvore do nó tem de sair igual a ela (+ o synth do instalador)
  # vazio/falhou: lista de produção ilegível → o laço não lê nada, `ents` fica vazio e o caso reprova abaixo (nunca "instalou sem entrypoint = ok")
  rm -rf "$T/repo2"; mkdir -p "$T/repo2"
  while read -r ep pa x || [ -n "${ep:-}" ]; do case ${ep:-} in '' | '#'* | @fixture) continue ;; esac
    mkdir -p "$T/repo2/$(dirname "$pa")"; printf '#!/bin/sh\n' > "$T/repo2/$pa"; case $pa in bin/*) chmod 755 "$T/repo2/$pa" ;; esac
    case " $ents " in *" $ep "*) ;; *) ents="$ents $ep" ;; esac; want="$want$pa"$'\n'
  done < "$HERE/hetzner-dados-code-allow.txt"
  ( cd "$T/repo2" && /usr/bin/git init -q . && /usr/bin/git config user.email t@t && /usr/bin/git config user.name t && /usr/bin/git config commit.gpgsign false && /usr/bin/git add -A && /usr/bin/git commit -q -m c ) > /dev/null 2>&1
  sha=$(/usr/bin/git -C "$T/repo2" rev-parse HEAD 2> /dev/null); want=$(printf '%sbin/synth\n' "$want" | LC_ALL=C sort -u)
  ck "entrega: a lista de produção tem entrypoints e o commit de teste foi criado" bash -c "[ -n '$ents' ] && [ -n '$sha' ]"
  for e in $ents; do eargs+=(--entrypoint "$e"); done
  world; echo old > "$app/stale"; GIT_REAL=1 ap "$ns/hetzner-dados-install.sh" ${eargs[@]+"${eargs[@]}"} --code-dir "$T/repo2" --code-sha "$sha"
  [ "$RC" = 0 ] || [ "$QUIET" = 1 ] || { echo "--- entrega: rc=$RC"; cat "$ERR"; echo "--- fim"; }
  ck "entrega: instalando da pasta do nó (SÓ o que o scp do runbook leva) com a lista de PRODUÇÃO → rc 0 e os 20 itens do --check ok" bash -c "[ $RC = 0 ] && [ \"\$(grep -c '^GTD-CHECK: .* ok\$' '$OUT')\" = 20 ]"
  got=$(cd "$app" 2> /dev/null && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort)
  ck "entrega: a árvore do nó é exatamente a lista de produção (+ o synth do instalador)" test "$got" = "$want"
  ck "entrega: o arquivo velho da árvore anterior sumiu na troca" test ! -e "$app/stale"
  ok=1; for e in $ents; do [ -x "$app/bin/$e" ] && grep -q "gt-dados-run $e\$" "$R/etc/sudoers.d/gt-dados-run" || ok=0; done
  ck "entrega: cada entrypoint da lista de produção está instalado, executável e no sudoers" test "$ok" = 1
  # a MESMA pasta sem a lista (a entrega antiga): recusa explícita (98 code-allow-ilegivel, com a dica do runbook), ANTES de mexer no nó (nenhum useradd/mount/systemctl) e com a árvore antiga intacta
  rm -f "$ns/hetzner-dados-code-allow.txt"; world; echo old > "$app/stale"; GIT_REAL=1 ap "$ns/hetzner-dados-install.sh" ${eargs[@]+"${eargs[@]}"} --code-dir "$T/repo2" --code-sha "$sha"
  ck "entrega: a pasta do nó SEM a lista → 98 code-allow-ilegivel COM a dica (gt-dados-src), antes de mexer no nó, árvore antiga INTACTA" bash -c "[ $RC = 98 ] && grep -q 'falhou:code-allow-ilegivel' '$ERR' && grep -q 'gt-dados-src' '$ERR' && ! grep -q -E '^(useradd|usermod|mount|systemctl)' '$LOG' && [ -f '$app/stale' ]"; }
adult() { # <rótulo> <item esperado FALHOU/nao-consegui> <comando de adulteração>
  world; ap "$s_" --entrypoint build-x > /dev/null 2>&1; eval "$3"; inst "$s_" --check; ck "check: $1 → $2 e rc≠0" bash -c "[ $RC != 0 ] && grep -q '^GTD-CHECK: $2' '$OUT'"; }
case_check() { s_=$1; world; ap "$s_" > /dev/null 2>&1; inst "$s_" --check; ck "check: mundo recém-instalado → rc 0, 20 ok" bash -c "[ $RC = 0 ] && [ \"$(okc)\" = 20 ]"
  adult "home 755" "home-0700 FALHOU" "echo 'dados dados 755' > '$T/own/$(echo "$R/home/dados" | tr / _)'"; adult "chave 644" "chaves-de-root FALHOU" "echo 'root dados 644' > '$T/own/$(echo "$R/etc/ssh/authorized_keys.d/dados" | tr / _)'"
  adult "chave root:root 640 (grupo errado: o dono e o modo conferem, o grupo não)" "chaves-de-root FALHOU" "echo 'root root 640' > '$T/own/$(echo "$R/etc/ssh/authorized_keys.d/dados" | tr / _)'"
  adult "chave sem restrict" "chaves-de-root FALHOU" "sed -i.b 's/^restrict,//' '$R/etc/ssh/authorized_keys.d/dados'"; adult "sudoers com curinga" "sudoers-sem-curinga FALHOU" "chmod u+w '$R/etc/sudoers.d/gt-dados-run'; echo 'runner ALL=(root) NOPASSWD: $R/usr/local/sbin/gt-dados-run *' >> '$R/etc/sudoers.d/gt-dados-run'"
  adult "sudoers com (dados) ALL" "sudoers-sem-curinga FALHOU" "chmod u+w '$R/etc/sudoers.d/gt-dados-run'; echo 'runner ALL=(dados) NOPASSWD: ALL' >> '$R/etc/sudoers.d/gt-dados-run'"; adult "entrypoint fora do sudoers" "sudoers-igual-a-lista FALHOU" "echo evil >> '$R/etc/gt-dados/entrypoints'"
  adult "staging em ext4" "stage-tmpfs-proprio FALHOU" "export FS=ext4"; unset FS; adult "swap ligada" "sem-swap FALHOU" "export SWAP=1"; unset SWAP; adult "senha destravada" "senha-travada FALHOU" "export PW_STATE=P"; unset PW_STATE
  adult "shell nologin" "shell-real FALHOU" "export SHELL_DADOS=/usr/sbin/nologin"; unset SHELL_DADOS; adult "runner no grupo" "runner-fora-do-grupo FALHOU" "export ID_G_RUNNER='runner dados'"; unset ID_G_RUNNER
  adult "sshd: runner afetado" "sshd-runner-intacto FALHOU" "export SSHD_RUNNER_LEAK=/etc/ssh/authorized_keys.d/x"; unset SSHD_RUNNER_LEAK; adult "arquivo de root gravável" "arvore-de-root FALHOU" "chmod 777 '$R/opt/gt-dados/app/bin/synth'"
  adult "visudo ausente (127)" "sudoers-valido nao-consegui" "export VISUDO_MISSING=1"; unset VISUDO_MISSING
  # 3º estado: leitura que FALHA nunca vira ok (o teste negado `! ...` e o `[ -z "$(...)" ]` liam o erro como "não tem nada")
  adult "id do runner falha" "runner-fora-do-grupo nao-consegui" "export ID_RUNNER_FAIL=1"; unset ID_RUNNER_FAIL; adult "swapon falha" "sem-swap nao-consegui" "export SWAPON_FAIL=1"; unset SWAPON_FAIL
  adult "árvore de root sumiu (find falha)" "arvore-de-root nao-consegui" "mv '$R/opt/gt-dados' '$R/opt/gt-dados.x'"; adult "sudoers ilegível" "sudoers-sem-curinga nao-consegui" "rm -f '$R/etc/sudoers.d/gt-dados-run'"
  adult "sshd -T do runner falha" "sshd-runner-intacto nao-consegui" "export SSHD_RUNNER_FAIL=1"; unset SSHD_RUNNER_FAIL
  # link simbólico DENTRO da árvore de root (o guarda do instalador aceita os que ficam na árvore): o modo 0777 do próprio link (Linux sempre) não é "arquivo gravável por outros" → arvore-de-root segue ok (o mundo adulterado acima prova que o teste ainda reprova de verdade)
  world; ap "$s_" --entrypoint build-x > /dev/null 2>&1; ln -s bin/synth "$R/opt/gt-dados/app/elo"; chmod -h 777 "$R/opt/gt-dados/app/elo" 2> /dev/null; inst "$s_" --check
  ck "check: link simbólico dentro da árvore de root (modo 0777 do link) → arvore-de-root ok, rc 0" bash -c "[ $RC = 0 ] && grep -q '^GTD-CHECK: arvore-de-root ok' '$OUT'"; }
case_refuse "$T/inst.sh"; case_happy "$T/inst.sh"; case_rollback "$T/inst.sh"; case_check "$T/inst.sh"; case_code "$T/inst.sh"; case_code_dado "$T/inst.sh"; case_code_lista "$T/inst.sh"; case_entrega "$T/inst.sh"
# MUT_EXPR: a mesma expressão do mutante, para o caso que monta a SUA cópia do instalador (case_entrega: layout do nó)
mut() { local name=$1 expr=$2 fn=$3 mc="$T/mut-$1.sh"; mkcopy "$HERE/hetzner-dados-install.sh" "$expr" "$mc"; cmp -s "$mc" "$T/inst.sh" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  MUT_EXPR=$expr; QUIET=1; BAD=0; "$fn" "$mc" > /dev/null 2>&1; QUIET=0; MUT_EXPR=""; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
# mutante do RUNBOOK: o que se adultera é a linha do scp (o que a entrega leva), não o instalador; o caso lê o runbook adulterado (RB)
mutrb() { local name=$1 expr=$2 fn=$3 rb="$T/rb-$1.md"; sed -e "$expr" "$RBFILE" > "$rb" 2> /dev/null; cmp -s "$rb" "$RBFILE" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  RB=$rb; QUIET=1; BAD=0; "$fn" "$T/inst.sh" > /dev/null 2>&1; QUIET=0; RB=""; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
mut I26-tree-reprova-link 's#! -type l ##' case_check
mut I1-sem-lock-da-senha 's#^usermod -L "\$DU" || die passwd-lock#true#' case_happy
mut I2-shell-nologin 's#-s /bin/bash#-s /usr/sbin/nologin#' case_happy
mut I3-sem-valida-chave 's#&& ssh-keygen -l -f "\$PUB" > /dev/null 2>&1 || die pubkey#|| die pubkey#' case_refuse
mut I4-sudoers-sem-visudo 's#visudo -cf "\$SUDOERS.new" > /dev/null || {#true || {#' case_rollback
mut I5-sshd-sem-prova-do-dados 's#| undo sshd-dados-nao-usa-o-arquivo-de-root#| true#' case_rollback
mut I6-sshd-sem-prova-do-runner 's#undo sshd-runner-afetado#true#' case_rollback
mut I7-fstab-ilegivel-vira-vazio 's#\[ \$? -le 1 \] || die fstab-leitura#true#' case_rollback
mut I8-sem-guarda-de-link 's#die "link-fora-da-arvore:\$l"#true#' case_refuse
mut I9-chave-sem-restrict 's#restrict,command=#command=#' case_happy
mut I10-sudoers-com-curinga 's#gt-dados-run \$e"#gt-dados-run *"#' case_happy
mut I16-1a-varredura-falha-vira-ok 's#|| die sweep-primeira#|| true#' case_rollback
mut I11-fstab-sem-noexec 's#,noexec,nosuid,nodev,nofail 0 0#,nosuid,nodev,nofail 0 0#' case_happy
mut I15-fstab-sem-nofail 's#,nodev,nofail 0 0#,nodev 0 0#' case_happy
mut I12-undo-nao-desfaz 's#^undo() { if.*#undo() { die "$1"; }#' case_rollback
mut I13-check-sudo-curinga-cego 's#^t_sudo_strict() {.*#t_sudo_strict() { true; }#' case_check
mut I14-check-127-vira-ok 's#127) echo "GTD-CHECK: \$n nao-consegui"#127) echo "GTD-CHECK: $n ok"#' case_check
mut I17-opcao-sem-valor-gira 's,\[ \$# -ge 2 \] || { echo "opção sem valor: \$1" >&2; exit 64; },true,' case_refuse
mut I18-runner-ilegivel-vira-fora-do-grupo 's#RG=\$(id -nG "\$RUNNER" 2> /dev/null) || die runner-ilegivel#RG=$(id -nG "$RUNNER" 2> /dev/null)#' case_refuse
mut I19-check-runner-127-vira-ok 's#g=\$(id -nG "\$RUNNER" 2> /dev/null) || return 127; ##' case_check
mut I20-check-swapon-127-vira-ok 's#s=\$(swapon --noheadings --show 2> /dev/null) || return 127; #s=$(swapon --noheadings --show 2> /dev/null); #' case_check
mut I21-check-arvore-127-vira-ok 's#-print -quit 2> /dev/null) || return 127;#-print -quit 2> /dev/null);#' case_check
mut I22-check-sudoers-ilegivel-vira-ok 's#t_sudo_strict() { \[ -r "\$SUDOERS" \] || return 127; #t_sudo_strict() { #' case_check
mut I23-sshd-runner-ilegivel-vira-intacto 's#RO=\$(sshd_for "\$RUNNER") || undo sshd-runner-ilegivel#RO=$(sshd_for "$RUNNER")#' case_rollback
mut I24-check-sshd-runner-127-vira-ok 's#o=\$(sshd_for "\$RUNNER") || return 127; #o=$(sshd_for "$RUNNER"); #' case_check
mut I25-chave-com-linha-em-branco 's#KEYLINE=\$(grep -m1 \. "\$PUB")#KEYLINE=$(cat "$PUB")#' case_happy
mut I27-code-da-arvore-de-trabalho 's#git -C "\$CODE" archive --format=tar "\$SHA" -- "\${PSPEC\[@\]}" | tar -x#tar -c -C "$CODE" -- "${PSPEC[@]}" | tar -x#' case_code
mut I28-code-sem-guarda-de-modo 's#\[ -z "\$bad" \] || {#true || {#' case_code
mut I29-code-sem-pipefail 's#set -o pipefail; ##' case_code
mut I30-chave-sem-grupo 's#owned "\$AKDIR/\$DU" "root:\$DU 640"#[ "$(stat -c "%U %a" "$AKDIR/$DU")" = "root 640" ]#' case_check
mut I31-code-modo-inseguro-deixa-app-new 's#\[ -z "\$bad" \] || { rm -rf -- "\$NEW"; die#[ -z "$bad" ] || { die#' case_code
mut I32-code-archive-deixa-app-new 's#|| { rm -rf -- "\$NEW"; die code-archive; }#|| die code-archive#' case_code
# wa-4p38ls: cada guarda da lista branca tem o seu mutante (desligada sozinha, o caso que a prova reprova)
mut I33-code-exporta-o-commit-inteiro 's#"\$SHA" -- "\${PSPEC\[@\]}" | tar#"$SHA" | tar#' case_code
mut I34-code-sem-conferir-o-export-com-a-lista 's#\[ "\$GOT" = "\$WLS" \] || {#true || {#' case_code_lista
mut I35-code-sem-recusa-de-dado 's#! data_path "\$f" || printf#true || printf#' case_code_dado
mut I36-code-fixture-isenta-tudo 's#grep -qxF -- "\$f"#test -n "$FX"#' case_code_dado
mut I37-code-padrao-de-dado-so-minusculo 's#tr "\[:upper:\]" "\[:lower:\]"#cat#' case_code_dado
mut I38-code-sem-padrao-csv 's#\*\.csv | ##' case_code_dado
mut I39-code-sem-padrao-db 's#\*\.db | ##' case_code_dado
mut I40-code-sem-padrao-sqlite 's#\*\.sqlite | ##' case_code_dado
mut I41-code-sem-padrao-jsonl 's#\*\.jsonl | ##' case_code_dado
mut I42-code-sem-padrao-contacts-auth 's# | contacts_auth/\* | \*/contacts_auth/\*##' case_code_dado
mut I43-code-sem-padrao-investigations 's# | docs/investigations/\* | \*/docs/investigations/\*##' case_code_dado
mut I44-code-lista-ilegivel-vira-vazia 's#\[ -f "\$ALLOW" \] && \[ -r "\$ALLOW" \] || {#true || {#' case_code_lista
mut I45-code-entrypoint-sem-linha-passa 's#\*) die "code-allow-sem-linha:\$e" ;; esac; done#*) ;; esac; done#' case_code_lista
mut I46-code-linha-invalida-aceita 's#|| die "code-allow-linha-invalida:\$k"#|| true#' case_code_lista
mut I47-code-lista-de-todos-os-entrypoints 's#\[ "\$k" != "\$e" \] || WL=#WL=#' case_code_lista
mut I48-code-lista-vazia-exporta 's#\[ -n "\$WLS" \] || die code-allow-vazia#true#' case_code_lista
# gate-fix 1/3 de wa-4p38ls: a recusa de entrypoint sem bin/<ep> (antes da troca), o `tr` que falha lido como DADO, cada padrão aninhado e cada extensão sozinhos (o I42/I43 tiram os dois de uma vez), a dica da lista ausente
mut I49-code-sem-bin-passa 's#\*) die "code-allow-sem-bin:\$e" ;; esac; done#*) ;; esac; done#' case_code_lista
mut I50-code-tr-que-falha-vira-nao-e-dado 's#"\[:lower:\]") || return 0;#"[:lower:]");#' case_code_dado
mut I51-code-sem-padrao-contacts-auth-aninhado 's# | \*/contacts_auth/\*##' case_code_dado
mut I52-code-sem-padrao-investigations-aninhado 's# | \*/docs/investigations/\*##' case_code_dado
mut I53-code-sem-padrao-sqlite3 's#\*\.sqlite3 | ##' case_code_dado
mut I54-code-sem-padrao-parquet 's#\*\.parquet | ##' case_code_dado
mut I55-code-sem-padrao-duckdb 's#\*\.duckdb | ##' case_code_dado
mut I56-code-sem-padrao-xlsx 's#\*\.xlsx | ##' case_code_dado
mut I57-code-sem-padrao-xls 's#\*\.xls | ##' case_code_dado
mut I58-code-sem-padrao-vcf 's#\*\.vcf | ##' case_code_dado
mut I59-code-lista-ausente-sem-a-dica 's#echo "GTD-INSTALL: lista branca ausente#: "#' case_entrega
# a entrega: cada mutante tira do scp do runbook o que o nó precisa (a lista, o synth, o sweep) ou a própria linha do scp (leitura que falha não pode virar "nada a entregar = ok")
mutrb R1-runbook-sem-a-lista-no-scp 's# \$S/hetzner-dados-code-allow\.txt##' case_entrega
mutrb R2-runbook-sem-o-synth-no-scp 's#,synth}#}#' case_entrega
mutrb R3-runbook-sem-o-sweep-no-scp 's#,sweep,#,#' case_entrega
mutrb R4-runbook-sem-linha-de-scp 's#scp -i \$KEY#rsync -e \$KEY#' case_entrega
echo "---"; echo "casos: $n, reprovados: $fails"; [ "$fails" -eq 0 ]
