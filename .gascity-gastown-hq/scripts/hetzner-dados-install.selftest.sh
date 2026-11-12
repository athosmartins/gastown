#!/usr/bin/env bash
# hetzner-dados-install.selftest.sh — hermético: o instalador de root roda numa "raiz" de mentira ($T/r) com useradd, sshd, visudo, systemctl, mount, stat... como stubs; nada toca o sistema (ga-qg1dw5z.1).
#
# ## Contents
#   Casos · Mutantes · O que este teste NÃO prova
#
# CASOS: recusas antes de tocar em qualquer coisa (não é root, chave com opções/2 linhas/ilegível, entrypoint e tamanho inválidos, código sem sha limpo, runner no grupo, grupos extras) · instalação feliz (usuário, sudoers sem curinga,
#   chave de root com restrict, drop-in, fstab sem perder as outras linhas, árvore, timer) e `--check` com os 20 itens ok · idempotência · sshd reprovado desfaz o drop-in (-t, dados fora do arquivo de root, runner afetado) e restaura o anterior ·
#   visudo reprovado não troca o sudoers · fstab ilegível não é reescrito · link para fora da árvore · `--check` que FALHA / não consegue (cada item adulterado).
# O QUE NÃO PROVA: que useradd/sshd/sudo/mount se comportam assim no Ubuntu 24.04 do nó. Isso é o `--check` + `hetzner-dados-prove.sh` rodados no nó depois da instalação.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/hzdados-inst-selftest.XXXXXX"); R="$T/r"; LOG="$T/log"; OUT="$T/out"; ERR="$T/err"; ME=$(id -un)
trap 'chmod -R u+rwx "$T" 2>/dev/null; find "$T" -mindepth 1 -delete 2>/dev/null; rmdir "$T" 2>/dev/null' EXIT
mkdir -p "$T/stubs" "$T/own"
mk() { printf '%s\n' "$2" > "$T/stubs/$1"; chmod +x "$T/stubs/$1"; }
mk id '#!/usr/bin/env bash
case "$*" in "-u") echo "${ID_U:-0}" ;; "-u dados"|"-g dados") echo 1234 ;; "-nG dados") echo "${ID_G_DADOS:-dados}" ;; "-nG runner") echo "${ID_G_RUNNER:-runner}" ;; *) exec /usr/bin/id "$@" ;; esac'
mk getent '[ -f "$T/user" ] && echo "dados:x:1234:1234::/home/dados:${SHELL_DADOS:-/bin/bash}"; [ -f "$T/user" ]'
mk useradd 'echo "useradd $*" >> "$LOG"; touch "$T/user"'
mk usermod 'echo "usermod $*" >> "$LOG"'
mk passwd 'echo "dados ${PW_STATE:-L} 2026-11-11 0 99999 7 -1"'
mk ssh-keygen 'echo "ssh-keygen $*" >> "$LOG"; ! grep -q BADKEY "$3"'
mk sshd 'echo "sshd $*" >> "$LOG"
case "$1" in -t) [ -z "${SSHD_T_FAIL:-}" ] ;; -T) case "$3" in user=dados,*) [ -n "${SSHD_DADOS_WRONG:-}" ] && echo "authorizedkeysfile .ssh/authorized_keys" || { [ -f "$R/etc/ssh/sshd_config.d/50-gt-dados.conf" ] && sed -n "s#^ *AuthorizedKeysFile \(.*\)#authorizedkeysfile \1#p" "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"; } ;; *) echo "authorizedkeysfile ${SSHD_RUNNER_LEAK:-.ssh/authorized_keys}" ;; esac ;; esac'
mk systemctl 'echo "systemctl $*" >> "$LOG"'
mk visudo 'echo "visudo $*" >> "$LOG"; [ -z "${VISUDO_MISSING:-}" ] || exit 127; [ -z "${VISUDO_FAIL:-}" ]'
mk mountpoint '[ -f "$T/mounted" ]'
mk mount 'echo "mount $*" >> "$LOG"; touch "$T/mounted"; echo "dados dados 700" > "$T/own/$(echo "$R/srv/gtdados" | tr / _)"'
mk findmnt 'echo "${FS:-tmpfs} rw,nosuid,nodev,noexec,relatime"'
mk swapon '[ -z "${SWAP:-}" ] || echo "/dev/sda2 partition 1G"'
mk rsync 'echo "rsync $*" >> "$LOG"; for a; do d=$a; done; mkdir -p "$d"; cp -R "${@: -2:1}". "$d"'
mk git 'case "$3" in rev-parse) echo "${GIT_HEAD:-abc123}" ;; status) echo "${GIT_DIRTY:-}" ;; esac'
mk install 'a=(); u=""; g=""; m=""; d=0; while [ $# -gt 0 ]; do case "$1" in -o) u=$2; shift 2 ;; -g) g=$2; shift 2 ;; -m) m=$2; shift 2 ;; -d) d=1; shift ;; *) a+=("$1"); shift ;; esac; done
/usr/bin/install $([ $d = 1 ] && echo -d) ${m:+-m $m} "${a[@]}" || exit 1; [ $d = 1 ] && t=("${a[@]}") || t=("${a[${#a[@]}-1]}")
for p in "${t[@]}"; do echo "${u:-root} ${g:-root} ${m#0}" | sed "s/ $/ 755/" > "$T/own/$(echo "$p" | tr / _)"; done'
mk chown 'echo "${1%%:*} ${1##*:} $(cat "$T/own/$(echo "$2" | tr / _)" 2>/dev/null | cut -d" " -f3)" > "$T/own/$(echo "$2" | tr / _)"'
mk chmod 'if [ -f "$2" ] && [ ! -d "$2" ] || [ -d "$2" ]; then /bin/chmod "$@"; fi; f="$T/own/$(echo "$2" | tr / _)"; u=root g=root; [ -f "$f" ] && read -r u g _ < "$f"; echo "$u $g ${1#0}" > "$f"'
mk mv '/bin/mv "$@"; f="$T/own/$(echo "$1" | tr / _)"; [ -f "$f" ] && /bin/mv "$f" "$T/own/$(echo "$2" | tr / _)"; true'
mk stat '[ "$1" = -c ] || exit 2; f="$T/own/$(echo "$3" | tr / _)"; [ -e "$3" ] || exit 1; read -r u g m < "$f" 2>/dev/null || { u=root g=root m=644; }; case "$2" in "%U:%G %a") echo "$u:$g $m" ;; "%U %a") echo "$u $m" ;; esac'
export LOG T R
mkcopy() { sed -e "s#^PATH=/usr/sbin:/usr/bin:/sbin:/bin\$#PATH=$T/stubs:/usr/bin:/bin#" -e "s#^DU=dados; SBIN=/usr/local/sbin; ETC=/etc/gt-dados; OPT=/opt/gt-dados; STAGE=/srv/gtdados; DHOME=/home/dados; SSHD_D=/etc/ssh/sshd_config.d; AKDIR=/etc/ssh/authorized_keys.d\$#DU=dados; SBIN=$R/usr/local/sbin; ETC=$R/etc/gt-dados; OPT=$R/opt/gt-dados; STAGE=$R/srv/gtdados; DHOME=$R/home/dados; SSHD_D=$R/etc/ssh/sshd_config.d; AKDIR=$R/etc/ssh/authorized_keys.d#" \
  -e "s#^SUDOERS=/etc/sudoers.d/gt-dados-run; FSTAB=/etc/fstab; UNITS=/etc/systemd/system; LOGF=/var/log/gt-dados-sweep.log\$#SUDOERS=$R/etc/sudoers.d/gt-dados-run; FSTAB=$R/etc/fstab; UNITS=$R/etc/systemd/system; LOGF=$R/var/log/gt-dados-sweep.log#" -e "s#^SRC=.*; RUNNER=runner\$#SRC=$HERE; RUNNER=runner#" -e 's#-user root#-user '"$ME"'#g' ${2:+-e "$2"} "$1" > "$3"; chmod +x "$3"; }
mkcopy "$HERE/hetzner-dados-install.sh" "" "$T/inst.sh" 2>/dev/null; mkcopy "$HERE/hetzner-dados-install.sh" "" "$T/inst.sh"
n=0; fails=0; BAD=0; QUIET=0
ck() { local l=$1; shift; [ "$QUIET" = 1 ] || n=$((n+1)); if "$@"; then [ "$QUIET" = 1 ] || echo "ok   $l"; else [ "$QUIET" = 1 ] || { echo "FAIL $l"; fails=$((fails+1)); }; BAD=1; fi; }
rcis() { [ "$RC" = "$1" ]; }; has() { grep -q -E -- "$2" "$1"; }; hasnt() { ! grep -q -E -- "$2" "$1"; }
ck "a cópia testada só troca caminhos, PATH e -user" test "$(diff "$HERE/hetzner-dados-install.sh" "$T/inst.sh" | grep '^<' | grep -v -c -e 'PATH=' -e '^< DU=dados' -e '^< SUDOERS=' -e '^< SRC=' -e '-user root')" = 0
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestkey mini@gt" > "$T/mini.pub"
world() { chmod -R u+rwx "$T/r" 2>/dev/null; find "$T/r" "$T/own" -mindepth 1 -delete 2>/dev/null; rm -f "$T/user" "$T/mounted"
  mkdir -p "$R/etc/ssh/sshd_config.d" "$R/etc/sudoers.d" "$R/etc/systemd/system" "$R/var/log" "$R/opt/gt-dados/app/bin" "$R/srv" "$R/usr/local/sbin"; printf 'UUID=1 / ext4 defaults 0 1\n' > "$R/etc/fstab"; : > "$LOG"
  # a árvore de root já traz o entrypoint extra (como o `--code-dir` traria): o instalador RECUSA entrypoint que não está nela
  printf '#!/bin/sh\n' > "$R/opt/gt-dados/app/bin/build-x"; chmod 755 "$R/opt/gt-dados/app/bin/build-x"; }
inst() { local s=$1; shift; "$s" "$@" > "$OUT" 2> "$ERR"; RC=$?; }
ap() { inst "$1" apply --pubkey-file "$T/mini.pub" "${@:2}"; }
okc() { grep -c '^GTD-CHECK: .* ok$' "$OUT"; }
case_refuse() { local s=$1
  world; ID_U=1000 inst "$s" apply --pubkey-file "$T/mini.pub"; ck "não é root → 64" rcis 64; world; inst "$s"; ck "sem argumentos → 64" rcis 64; inst "$s" apply --nao-existe; ck "argumento desconhecido → 64" rcis 64
  world; ap "$s" --entrypoint 'A/../b'; ck "entrypoint inválido → 98" rcis 98; ap "$s" --entrypoint -x; ck "entrypoint '-x' → 98" rcis 98; ap "$s" --stage-size 8; ck "stage-size sem unidade → 98" rcis 98; ap "$s" --stage-size 0g; ck "stage-size 0g → 98" rcis 98
  ap "$s" --code-dir "$T"; ck "code-dir sem sha → 98" rcis 98; GIT_HEAD=outro ap "$s" --code-dir "$T" --code-sha abc123; ck "HEAD ≠ sha → 98" rcis 98; GIT_DIRTY=" M x" ap "$s" --code-dir "$T" --code-sha abc123; ck "árvore suja → 98" rcis 98
  for kc in "" 'restrict,command="x" ssh-ed25519 AAAAB3Nza k' 'ssh-ed25519 AAAAB3Nza k
ssh-ed25519 AAAAB3Nzb k2' 'lixo sem chave' 'ssh-ed25519 BADKEY'; do printf '%s\n' "$kc" > "$T/k.pub"; inst "$s" apply --pubkey-file "$T/k.pub"; ck "chave inválida ('$(printf %s "$kc" | head -c 20)') → 98 pubkey" rcis 98; done
  inst "$s" apply --pubkey-file "$T/nao-existe.pub"; ck "chave inexistente → 98" rcis 98; ck "recusas: nada foi criado/instalado" hasnt "$LOG" '^(useradd|usermod|mount|systemctl)'
  world; ID_G_RUNNER="runner dados" ap "$s"; ck "runner no grupo dados → 98" bash -c "[ $RC = 98 ] && grep -q 'runner-no-grupo-dados' '$ERR'"; world; ID_G_DADOS="dados sudo" ap "$s"; ck "dados com grupo extra → 98" has "$ERR" 'grupos-extras-do-dados'
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
  ap "$s" --entrypoint build-x --runner runner --stage-size 6g; ck "2ª instalação (idempotente): rc 0, 1 linha # gt-dados no fstab, 1 sudoers por entrypoint" bash -c "[ $RC = 0 ] && [ \"\$(grep -c '# gt-dados\$' '$R/etc/fstab')\" = 1 ] && [ \"\$(grep -c '^runner ' '$R/etc/sudoers.d/gt-dados-run')\" = 2 ] && [ \"\$(grep -c '^useradd' '$LOG')\" = 1 ]"; }
case_rollback() { local s=$1
  world; echo "# ANTERIOR" > "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"; SSHD_T_FAIL=1 ap "$s"; ck "sshd -t reprova → 98, drop-in ANTERIOR restaurado, sem reload" bash -c "[ $RC = 98 ] && grep -q ANTERIOR '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' && ! grep -q '^systemctl reload' '$LOG'"
  world; SSHD_T_FAIL=1 ap "$s"; ck "sshd -t reprova sem drop-in anterior → drop-in removido" test ! -e "$R/etc/ssh/sshd_config.d/50-gt-dados.conf"
  world; SSHD_DADOS_WRONG=1 ap "$s"; ck "dados fora do arquivo de root → 98, drop-in desfeito, sem reload" bash -c "[ $RC = 98 ] && [ ! -e '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' ] && ! grep -q '^systemctl reload' '$LOG'"
  world; SSHD_RUNNER_LEAK=/etc/ssh/authorized_keys.d/x ap "$s"; ck "runner afetado pelo drop-in → 98, desfeito, sem reload" bash -c "[ $RC = 98 ] && [ ! -e '$R/etc/ssh/sshd_config.d/50-gt-dados.conf' ] && ! grep -q '^systemctl reload' '$LOG'"
  world; echo "# SUDOERS ANTIGO" > "$R/etc/sudoers.d/gt-dados-run"; VISUDO_FAIL=1 ap "$s"; ck "visudo reprova → 98, sudoers ANTIGO intacto, sem .new" bash -c "[ $RC = 98 ] && grep -q 'SUDOERS ANTIGO' '$R/etc/sudoers.d/gt-dados-run' && [ ! -e '$R/etc/sudoers.d/gt-dados-run.new' ]"
  world; rm -f "$R/etc/fstab"; ap "$s"; ck "fstab ilegível → 98 fstab-leitura e NÃO cria fstab só com a nossa linha" bash -c "[ $RC = 98 ] && grep -q 'fstab-leitura' '$ERR' && [ ! -s '$R/etc/fstab' ]"; }
adult() { # <rótulo> <item esperado FALHOU/nao-consegui> <comando de adulteração>
  world; ap "$s_" --entrypoint build-x > /dev/null 2>&1; eval "$3"; inst "$s_" --check; ck "check: $1 → $2 e rc≠0" bash -c "[ $RC != 0 ] && grep -q '^GTD-CHECK: $2' '$OUT'"; }
case_check() { s_=$1; world; ap "$s_" > /dev/null 2>&1; inst "$s_" --check; ck "check: mundo recém-instalado → rc 0, 20 ok" bash -c "[ $RC = 0 ] && [ \"$(okc)\" = 20 ]"
  adult "home 755" "home-0700 FALHOU" "echo 'dados dados 755' > '$T/own/$(echo "$R/home/dados" | tr / _)'"; adult "chave 644" "chaves-de-root FALHOU" "echo 'root dados 644' > '$T/own/$(echo "$R/etc/ssh/authorized_keys.d/dados" | tr / _)'"
  adult "chave sem restrict" "chaves-de-root FALHOU" "sed -i.b 's/^restrict,//' '$R/etc/ssh/authorized_keys.d/dados'"; adult "sudoers com curinga" "sudoers-sem-curinga FALHOU" "chmod u+w '$R/etc/sudoers.d/gt-dados-run'; echo 'runner ALL=(root) NOPASSWD: $R/usr/local/sbin/gt-dados-run *' >> '$R/etc/sudoers.d/gt-dados-run'"
  adult "sudoers com (dados) ALL" "sudoers-sem-curinga FALHOU" "chmod u+w '$R/etc/sudoers.d/gt-dados-run'; echo 'runner ALL=(dados) NOPASSWD: ALL' >> '$R/etc/sudoers.d/gt-dados-run'"; adult "entrypoint fora do sudoers" "sudoers-igual-a-lista FALHOU" "echo evil >> '$R/etc/gt-dados/entrypoints'"
  adult "staging em ext4" "stage-tmpfs-proprio FALHOU" "export FS=ext4"; unset FS; adult "swap ligada" "sem-swap FALHOU" "export SWAP=1"; unset SWAP; adult "senha destravada" "senha-travada FALHOU" "export PW_STATE=P"; unset PW_STATE
  adult "shell nologin" "shell-real FALHOU" "export SHELL_DADOS=/usr/sbin/nologin"; unset SHELL_DADOS; adult "runner no grupo" "runner-fora-do-grupo FALHOU" "export ID_G_RUNNER='runner dados'"; unset ID_G_RUNNER
  adult "sshd: runner afetado" "sshd-runner-intacto FALHOU" "export SSHD_RUNNER_LEAK=/etc/ssh/authorized_keys.d/x"; unset SSHD_RUNNER_LEAK; adult "arquivo de root gravável" "arvore-de-root FALHOU" "chmod 777 '$R/opt/gt-dados/app/bin/synth'"
  adult "visudo ausente (127)" "sudoers-valido nao-consegui" "export VISUDO_MISSING=1"; unset VISUDO_MISSING; }
case_refuse "$T/inst.sh"; case_happy "$T/inst.sh"; case_rollback "$T/inst.sh"; case_check "$T/inst.sh"
mut() { local name=$1 expr=$2 fn=$3 mc="$T/mut-$1.sh"; mkcopy "$HERE/hetzner-dados-install.sh" "$expr" "$mc"; cmp -s "$mc" "$T/inst.sh" && { echo "FAIL mutante $name não alterou nada"; fails=$((fails+1)); return; }
  QUIET=1; BAD=0; "$fn" "$mc" > /dev/null 2>&1; QUIET=0; n=$((n+1)); if [ "$BAD" = 1 ]; then echo "ok   mutante $name reprovado"; else echo "FAIL mutante $name SOBREVIVEU"; fails=$((fails+1)); fi; }
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
mut I11-fstab-sem-noexec 's#,noexec,nosuid,nodev,nofail 0 0#,nosuid,nodev,nofail 0 0#' case_happy
mut I15-fstab-sem-nofail 's#,nodev,nofail 0 0#,nodev 0 0#' case_happy
mut I12-undo-nao-desfaz 's#^undo() { if.*#undo() { die "$1"; }#' case_rollback
mut I13-check-sudo-curinga-cego 's#^t_sudo_strict() {.*#t_sudo_strict() { true; }#' case_check
mut I14-check-127-vira-ok 's#127) echo "GTD-CHECK: \$n nao-consegui"#127) echo "GTD-CHECK: $n ok"#' case_check
echo "---"; echo "casos: $n, reprovados: $fails"; [ "$fails" -eq 0 ]
